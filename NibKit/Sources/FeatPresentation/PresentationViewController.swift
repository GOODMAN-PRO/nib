import UIKit
import SwiftUI
import Combine
import os
import NibContracts
import NibDesign

private let logger = Logger(subsystem: "app.nib", category: "presentation")

// MARK: - Page source

/// The active session's current page, as the external display needs it.
struct PresentedPage: Equatable {
    var doc: DocumentID
    var page: PageID
    /// 0-based position among the live pages, and how many there are.
    var index: Int
    var count: Int
    /// The whole page in page points (a whiteboard board: its content bounds).
    var bounds: Rect
    /// What the presenter sees of the page, in page points; nil = the whole page.
    var visibleRect: Rect? = nil
    /// Changes whenever the page's content changes (commits, undo, sync).
    var version = 0
    var hiddenLayers: Set<Int> = []
    /// A whiteboard board: an infinite world (`PageRecord.size == nil`).
    var isBoard = false
}

/// Where the presentation gets its page, renders and window snapshots (live: `LivePageSource`; tests: a fake).
@MainActor
protocol PresentationPageSource: AnyObject {
    var current: PresentedPage? { get }
    /// Called whenever `current` may have changed.
    var onChange: (() -> Void)? { get set }
    /// Called for every `laser.moved` event.
    var onLaser: ((LaserEvent) -> Void)? { get set }
    func render(doc: DocumentID, page: PageID, region: Rect, scale: Double, hiddenLayers: Set<Int>) async throws -> CGImage
    /// A picture of the main window, at most `maxPixelWidth` pixels wide (nil when there is no window).
    func snapshot(maxPixelWidth: CGFloat) -> CGImage?
    func stop()
}

/// One `laser.moved` event (F040). Payload {page, point: [x, y], mode: "dot" | "trail", color?}; no point = lifted.
struct LaserEvent: Equatable {
    var page: PageID?
    var point: Point?
    var trail = false
    var color: RGBA? = nil

    init(page: PageID?, point: Point?, trail: Bool = false, color: RGBA? = nil) {
        self.page = page
        self.point = point
        self.trail = trail
        self.color = color
    }

    init(payload: JSONValue?) {
        let ref = payload?["page"]?.stringValue ?? ""
        page = ref.isEmpty ? nil : (NodeRef(ref)?.pageID ?? NibID(ref))
        if let xy = payload?["point"]?.arrayValue, xy.count >= 2, let x = xy[0].doubleValue, let y = xy[1].doubleValue {
            point = Point(x, y)
        } else {
            point = nil
        }
        trail = payload?["mode"]?.stringValue == "trail"
        color = payload?["color"]?.stringValue.flatMap { RGBA(hex: $0) }
    }
}

// MARK: - Camera

enum PresentationCamera {
    /// Page points → display points: `viewport` aspect-fitted and centred in `size` (letterboxed).
    static func transform(showing viewport: Rect, in size: CGSize) -> CGAffineTransform {
        let w = Double(size.width), h = Double(size.height)
        guard viewport.width > 0, viewport.height > 0, w > 0, h > 0 else { return .identity }
        let s = min(w / viewport.width, h / viewport.height)
        let tx = (w - s * viewport.width) / 2 - s * viewport.x
        let ty = (h - s * viewport.height) / 2 - s * viewport.y
        return CGAffineTransform(a: CGFloat(s), b: 0, c: 0, d: CGFloat(s), tx: CGFloat(tx), ty: CGFloat(ty))
    }
}

// MARK: - View model

struct RenderedImage {
    struct Key: Equatable {
        var doc: DocumentID
        var page: PageID
        var version: Int
        var hiddenLayers: Set<Int>
        var region: Rect
        var scale: Double
    }

    let image: CGImage
    let key: Key
    var region: Rect { key.region }
}

/// One frame of a page mode: a whole-page base image, an optional sharp render of the viewport, and the camera.
struct PageFrame {
    var doc: DocumentID
    var page: PageID
    var index: Int
    var count: Int
    var base: RenderedImage
    var detail: RenderedImage?
    /// The part of the page the display shows, in page points.
    var viewport: Rect
    /// Move the camera with an animation (Presenter Page following zoom and scroll on the same page).
    var animated: Bool
}

enum PresentationDisplay {
    /// No page to show (library, a text document, a locked document): the empty dark desk.
    case idle
    case blank
    case mirror(CGImage)
    case page(PageFrame)
}

/// Decides what the external display shows for the current mode and page. The scene and its view controller live
/// as long as the display is connected; switching modes only changes `display`.
@MainActor
final class PresentationViewModel: ObservableObject {
    /// The viewport has to rest this long before its sharp render is made (scrolling re-renders nothing).
    static let defaultDetailDelay: Double = 0.15
    /// Mirror snapshots: at most every 100 ms, and never more than a fifth of the main thread.
    /// ponytail: drawHierarchy on main; move to a render-server snapshot if mirroring ever costs ink latency.
    static let mirrorInterval: Double = 0.1
    static let mirrorCostFactor: Double = 5
    /// Longest edge of any render, in pixels.
    static let maxPixels: Double = 4096

    @Published private(set) var display: PresentationDisplay = .idle
    let laser = LaserModel()
    let source: PresentationPageSource
    var mode: ExternalDisplayMode
    var blank: Bool
    /// How long the viewport rests before its sharp render (tests lengthen it to watch a pending one get cancelled).
    var detailDelay = PresentationViewModel.defaultDetailDelay
    /// The display's size in points and its pixels per point (set by the view controller on layout).
    private(set) var canvasSize = CGSize(width: 1920, height: 1080)
    private(set) var pixelScale: CGFloat = 1
    private(set) var lastFrame: PageFrame?
    private var base: RenderedImage?
    private var detail: RenderedImage?
    private var dirty = false
    private var draining = false
    private var detailTask: Task<Void, Never>?
    private var mirrorTask: Task<Void, Never>?

    init(source: PresentationPageSource, mode: ExternalDisplayMode, blank: Bool = false) {
        self.source = source
        self.mode = mode
        self.blank = blank
        source.onChange = { [weak self] in self?.setNeedsUpdate() }
        source.onLaser = { [weak self] event in self?.handleLaser(event) }
    }

    /// Page points → display points for the frame on screen.
    var camera: CGAffineTransform {
        lastFrame.map { PresentationCamera.transform(showing: $0.viewport, in: canvasSize) } ?? .identity
    }

    func apply(mode: ExternalDisplayMode, blank: Bool) {
        guard mode != self.mode || blank != self.blank else { return }
        self.mode = mode
        self.blank = blank
        setNeedsUpdate()
    }

    func setCanvas(size: CGSize, scale: CGFloat) {
        let scale = max(1, scale)
        guard size.width > 0, size.height > 0, size != canvasSize || scale != pixelScale else { return }
        canvasSize = size
        pixelScale = scale
        setNeedsUpdate()
    }

    /// Coalesced: many changes in one run-loop turn (a scroll frame, a commit) make one update.
    func setNeedsUpdate() {
        dirty = true
        guard !draining else { return }
        Task { [weak self] in
            guard let self = self else { return }
            await self.drain(detailDelay: self.detailDelay)
        }
    }

    /// Brings `display` up to date now. Tests pass `detailDelay: 0` so the viewport's sharp render happens inline.
    func update(detailDelay: Double? = nil) async {
        while draining { await Task.yield() }
        dirty = true
        await drain(detailDelay: detailDelay ?? self.detailDelay)
    }

    func stop() {
        detailTask?.cancel()
        mirrorTask?.cancel()
        mirrorTask = nil
        source.stop()
        laser.clear()
    }

    /// Updates run one at a time, so a render in flight is never started twice; changes meanwhile set `dirty`.
    private func drain(detailDelay: Double) async {
        guard !draining else { return }
        draining = true
        while dirty {
            dirty = false
            await performUpdate(detailDelay: detailDelay)
        }
        draining = false
    }

    private func performUpdate(detailDelay: Double) async {
        detailTask?.cancel()
        detailTask = nil
        if blank {
            show(.blank)
            return
        }
        if mode == .mirror {
            lastFrame = nil
            laser.clear()
            _ = captureMirror()
            startMirroring()
            return
        }
        stopMirroring()
        guard let page = source.current, !page.bounds.isEmpty else {
            show(.idle)
            return
        }
        let key = RenderedImage.Key(doc: page.doc, page: page.page, version: page.version, hiddenLayers: page.hiddenLayers,
                                    region: page.bounds, scale: fitScale(for: page.bounds))
        if base?.key != key {
            let image = await render(key)
            if let image = image {
                base = RenderedImage(image: image, key: key)
            } else if base?.key.doc != page.doc || base?.key.page != page.page {
                base = nil
            }
            // Changed while rendering. A newer version of the same page still shows this render now (the next pass
            // renders the newer one), so a stream of commits never freezes the display; a page, mode or blank change
            // drops it.
            if dirty {
                guard !blank, mode != .mirror, let now = source.current, now.doc == page.doc, now.page == page.page else {
                    return
                }
            }
        }
        guard let base = base else {
            show(.idle)
            return
        }
        if let d = detail, d.key.doc != page.doc || d.key.page != page.page || d.key.version != page.version
            || d.key.hiddenLayers != page.hiddenLayers {
            detail = nil
        }
        let viewport = self.viewport(for: page)
        let samePage = lastFrame.map { $0.doc == page.doc && $0.page == page.page } ?? false
        let frame = PageFrame(doc: page.doc, page: page.page, index: page.index, count: page.count, base: base,
                              detail: detail, viewport: viewport, animated: mode == .presenter && samePage)
        lastFrame = frame
        display = .page(frame)
        laser.reproject(page: page.page, camera: camera, animated: frame.animated)
        guard !dirty, mode == .presenter, needsDetail(viewport: viewport, page: page, baseScale: key.scale),
              detail?.region != viewport else { return }
        if detailDelay <= 0 {
            await renderDetail(page: page, viewport: viewport)
        } else {
            detailTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(detailDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.renderDetail(page: page, viewport: viewport)
            }
        }
    }

    private func show(_ empty: PresentationDisplay) {
        stopMirroring()
        lastFrame = nil
        laser.clear()
        display = empty
    }

    private func render(_ key: RenderedImage.Key) async -> CGImage? {
        do {
            return try await source.render(doc: key.doc, page: key.page, region: key.region, scale: key.scale,
                                           hiddenLayers: key.hiddenLayers)
        } catch {
            logger.error("render of \(key.page.raw, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A sharp render of exactly what the presenter is looking at, laid over the base image.
    private func renderDetail(page: PresentedPage, viewport: Rect) async {
        let key = RenderedImage.Key(doc: page.doc, page: page.page, version: page.version, hiddenLayers: page.hiddenLayers,
                                    region: viewport, scale: fitScale(for: viewport))
        guard let image = await render(key), !Task.isCancelled, var frame = lastFrame, frame.doc == page.doc,
              frame.page == page.page, frame.viewport == viewport, frame.base.key.version == page.version else { return }
        detail = RenderedImage(image: image, key: key)
        frame.detail = detail
        frame.animated = false
        lastFrame = frame
        display = .page(frame)
    }

    private func viewport(for page: PresentedPage) -> Rect {
        guard mode == .presenter, let visible = page.visibleRect, !visible.isEmpty else { return page.bounds }
        if page.isBoard { return visible }
        let clipped = visible.cg.intersection(page.bounds.cg)
        return clipped.isNull || clipped.isEmpty ? page.bounds : Rect(clipped)
    }

    /// Pixels per point that fill the display with `rect`, never below 0.05 but always capped last, so no render is
    /// larger than `maxPixels` on its longest edge (a board with an item a million points away stays 4096 px).
    func fitScale(for rect: Rect) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 1 }
        let px = Double(canvasSize.width * pixelScale), py = Double(canvasSize.height * pixelScale)
        let fit = min(px / rect.width, py / rect.height)
        let cap = Self.maxPixels / max(rect.width, rect.height)
        let s = min(max(fit, 0.05), cap)
        let stepped = (s * 64).rounded(.down) / 64         // 1/64 steps: a resize by a point never re-renders
        return stepped > 0 ? stepped : s                  // rounding down never passes the cap, nor reaches 0
    }

    private func needsDetail(viewport: Rect, page: PresentedPage, baseScale: Double) -> Bool {
        let covered = page.bounds.cg.insetBy(dx: -0.5, dy: -0.5).contains(viewport.cg)
        return !covered || fitScale(for: viewport) > baseScale * 1.15
    }

    // MARK: Mirror

    /// Returns how long the snapshot took.
    private func captureMirror() -> Double {
        let started = CACurrentMediaTime()
        if let image = source.snapshot(maxPixelWidth: canvasSize.width * pixelScale) {
            display = .mirror(image)
        } else if case .mirror = display {
            // keep the last picture (the window is being rebuilt)
        } else {
            display = .idle
        }
        return CACurrentMediaTime() - started
    }

    private func startMirroring() {
        guard mirrorTask == nil else { return }
        mirrorTask = Task { [weak self] in
            var wait = PresentationViewModel.mirrorInterval
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let cost = self?.mirrorTick() else { return }
                wait = max(PresentationViewModel.mirrorInterval, cost * PresentationViewModel.mirrorCostFactor)
            }
        }
    }

    private func mirrorTick() -> Double? {
        guard mode == .mirror, !blank else {
            mirrorTask = nil
            return nil
        }
        return captureMirror()
    }

    private func stopMirroring() {
        mirrorTask?.cancel()
        mirrorTask = nil
    }

    // MARK: Laser

    func handleLaser(_ event: LaserEvent) {
        guard !blank, mode != .mirror, let frame = lastFrame, event.page.map({ $0 == frame.page }) ?? true,
              let point = event.point else {
            laser.lift()
            return
        }
        laser.move(page: frame.page, to: point, camera: camera, trail: event.trail,
                   color: event.color?.uiColor ?? NibUIColor.destructive)
    }
}

// MARK: - Laser overlay

/// The presenter's laser on the external display (DESIGN.md §14.12). The dot and the trail are kept in page points and
/// drawn through `camera`, which glides with the same spring as the stage when the presenter scrolls, so they stay on
/// their spot of the page while the camera moves.
@MainActor
final class LaserModel: ObservableObject {
    struct Segment: Identifiable {
        let id: Int
        /// Page points.
        let from: Point
        let to: Point
        let color: UIColor
    }

    /// Fading segments kept at most (a 30 Hz trail fades in 600 ms, so about 18 are ever alive).
    static let maxSegments = 64

    /// Page points → display points (the stage's camera).
    @Published private(set) var camera: CGAffineTransform = .identity
    /// The dot in page points; nil = lifted.
    @Published private(set) var point: Point?
    @Published private(set) var segments: [Segment] = []
    private(set) var color: UIColor = NibUIColor.destructive
    /// The page the dot and the trail are on.
    private(set) var page: PageID?
    private var nextID = 0

    /// The dot in display points, where the camera ends up.
    var dot: CGPoint? { point.map { $0.cg.applying(camera) } }

    func move(page: PageID, to point: Point, camera: CGAffineTransform, trail: Bool, color: UIColor) {
        if page != self.page, !segments.isEmpty { segments.removeAll() }
        if self.camera != camera { self.camera = camera }
        if trail, page == self.page, let from = self.point, from != point {
            segments.append(Segment(id: nextID, from: from, to: point, color: color))
            nextID += 1
            if segments.count > Self.maxSegments { segments.removeFirst(segments.count - Self.maxSegments) }
        }
        self.page = page
        self.color = color
        self.point = point
    }

    /// The camera moved. On the same page the dot and trail ride along (gliding with the stage when `animated`);
    /// another page clears them.
    func reproject(page: PageID, camera: CGAffineTransform, animated: Bool) {
        if page != self.page { clear() }
        guard camera != self.camera else { return }
        if animated && (point != nil || !segments.isEmpty) {
            NibMotion.animate(NibMotion.glide) { self.camera = camera }
        } else {
            self.camera = camera
        }
    }

    func lift() {
        if point != nil { point = nil }
    }

    func clear() {
        lift()
        page = nil
        if !segments.isEmpty { segments.removeAll() }
    }

    func remove(_ id: Int) {
        segments.removeAll { $0.id == id }
    }
}

/// DESIGN.md §14.12: a 12 pt dot with a 45 % 12 pt glow; the trail is a 4 pt line fading linearly over 600 ms.
enum LaserStyle {
    static let dot: CGFloat = 12
    static let glow: CGFloat = 12
    static let glowOpacity: Double = 0.45
    static let trailWidth: CGFloat = 4
}

/// The camera as SwiftUI animates it: `PresentationCamera` only scales uniformly and translates, so three numbers
/// interpolate exactly like the stage's `transform` does in UIKit.
struct LaserCamera: Equatable {
    var scale: CGFloat
    var tx: CGFloat
    var ty: CGFloat

    init(_ t: CGAffineTransform) {
        scale = t.a
        tx = t.tx
        ty = t.ty
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(scale, AnimatablePair(tx, ty)) }
        set {
            scale = newValue.first
            tx = newValue.second.first
            ty = newValue.second.second
        }
    }

    func apply(_ p: Point) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * scale + tx, y: CGFloat(p.y) * scale + ty)
    }
}

/// Centres a view on a page point through the camera. Only the camera animates: a new point lands at once, on the
/// camera as it is right now.
struct LaserPlacement: GeometryEffect {
    var point: Point
    var camera: LaserCamera

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { camera.animatableData }
        set { camera.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = camera.apply(point)
        return ProjectionTransform(CGAffineTransform(translationX: p.x - size.width / 2, y: p.y - size.height / 2))
    }
}

/// One trail segment between two page points, stroked in display points (the line keeps its 4 pt width at any zoom).
struct LaserSegmentShape: Shape {
    var from: Point
    var to: Point
    var camera: LaserCamera

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { camera.animatableData }
        set { camera.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: camera.apply(from))
        path.addLine(to: camera.apply(to))
        return path
    }
}

struct LaserOverlayView: View {
    @ObservedObject var laser: LaserModel

    var body: some View {
        let camera = LaserCamera(laser.camera)
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(laser.segments) { segment in
                LaserTrailSegment(segment: segment, camera: camera) { laser.remove(segment.id) }
            }
            if let point = laser.point {
                LaserDot(color: Color(uiColor: laser.color))
                    .modifier(LaserPlacement(point: point, camera: camera))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LaserDot: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(LaserStyle.glowOpacity))
                .frame(width: LaserStyle.dot + 2 * LaserStyle.glow, height: LaserStyle.dot + 2 * LaserStyle.glow)
                .blur(radius: LaserStyle.glow / 2)
            Circle()
                .fill(color)
                .frame(width: LaserStyle.dot, height: LaserStyle.dot)
        }
    }
}

struct LaserTrailSegment: View {
    let segment: LaserModel.Segment
    let camera: LaserCamera
    let onFaded: () -> Void
    @State private var faded = false

    var body: some View {
        LaserSegmentShape(from: segment.from, to: segment.to, camera: camera)
            .stroke(Color(uiColor: segment.color), style: StrokeStyle(lineWidth: LaserStyle.trailWidth, lineCap: .round))
            .opacity(faded ? 0 : 1)
            .onAppear {
                withAnimation(NibMotion.laserFade) { faded = true } completion: { onFaded() }
            }
    }
}

// MARK: - View controller

/// Root of the external display scene (`ui.externalDisplay`). Only the page, letterboxed on the dark desk: no chrome,
/// cursor or selection; the laser is the exception. It lives as long as the display is connected: modes switch by
/// swapping what `stage` and `mirrorView` show, never by recreating the scene.
final class PresentationViewController: UIViewController {
    let model: PresentationViewModel
    /// Page space: subviews are laid out in page points and `transform` is the camera.
    private let stage = UIView()
    private let baseView = UIImageView()
    private let detailView = UIImageView()
    private let mirrorView = UIImageView()
    private var laserHost: UIHostingController<LaserOverlayView>?
    private var cancellables = Set<AnyCancellable>()
    private var shownPage: (doc: DocumentID, page: PageID)?

    init(model: PresentationViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark           // the desk behind the page is the dark desk: near black
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.desk
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false

        stage.layer.anchorPoint = .zero
        stage.layer.position = .zero
        stage.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        stage.isHidden = true
        for imageView in [baseView, detailView] {
            imageView.contentMode = .scaleToFill
            imageView.layer.minificationFilter = .trilinear
            imageView.isHidden = true
            stage.addSubview(imageView)
        }
        view.addSubview(stage)

        mirrorView.contentMode = .scaleAspectFit
        mirrorView.isHidden = true
        mirrorView.frame = view.bounds
        mirrorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mirrorView)

        let host = UIHostingController(rootView: LaserOverlayView(laser: model.laser))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.isUserInteractionEnabled = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        laserHost = host

        model.$display
            .sink { [weak self] display in self?.apply(display) }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        model.setCanvas(size: view.bounds.size, scale: traitCollection.displayScale)
        if case .page(let frame) = model.display {
            stage.transform = PresentationCamera.transform(showing: frame.viewport, in: view.bounds.size)
        }
    }

    // Read by tests: what is on screen.
    var showsMirror: Bool { !mirrorView.isHidden }
    var showsPage: Bool { !stage.isHidden }
    var cameraTransform: CGAffineTransform { stage.transform }
    var shownBaseImage: CGImage? { baseView.image?.cgImage }

    private func apply(_ display: PresentationDisplay) {
        switch display {
        case .idle, .blank:
            showPage(nil)
            showMirror(nil)
        case .mirror(let image):
            showPage(nil)
            showMirror(image)
        case .page(let frame):
            showMirror(nil)
            showPage(frame)
        }
    }

    private func showMirror(_ image: CGImage?) {
        mirrorView.isHidden = image == nil
        if mirrorView.image?.cgImage !== image { mirrorView.image = image.map { UIImage(cgImage: $0) } }
    }

    private func showPage(_ frame: PageFrame?) {
        guard let frame = frame else {
            stage.isHidden = true
            show(nil, in: baseView)
            show(nil, in: detailView)
            shownPage = nil
            return
        }
        let samePage = shownPage?.doc == frame.doc && shownPage?.page == frame.page
        stage.isHidden = false
        show(frame.base, in: baseView)
        show(frame.detail, in: detailView)
        let camera = PresentationCamera.transform(showing: frame.viewport, in: view.bounds.size)
        if frame.animated, samePage, view.window != nil, stage.transform != camera {
            NibMotion.animateUIKit(NibMotion.glide, animations: { self.stage.transform = camera })
        } else {
            stage.transform = camera                   // Full Page and page flips: no animation
        }
        shownPage = (frame.doc, frame.page)
    }

    private func show(_ rendered: RenderedImage?, in imageView: UIImageView) {
        imageView.isHidden = rendered == nil
        guard let rendered = rendered else {
            imageView.image = nil
            return
        }
        if imageView.image?.cgImage !== rendered.image { imageView.image = UIImage(cgImage: rendered.image) }
        imageView.frame = rendered.region.cg
    }
}

// MARK: - Live source

/// The union of a board's live items, kept current from commits: a commit costs only its own items' bounds, and the
/// board is walked again only when an item on the union's edge moved inwards or went away.
struct BoardExtent {
    let doc: DocumentID
    let page: PageID
    /// nil = an empty board.
    private(set) var union: Rect?

    init(doc: DocumentID, page: PageID, items: [Item]) {
        self.doc = doc
        self.page = page
        for item in items where !item.deleted { grow(item.bounds) }
    }

    /// Applies one item write. False: the union may have shrunk, so the caller has to rebuild it.
    mutating func apply(before: Item?, after: Item) -> Bool {
        let afterBounds = after.deleted ? nil : after.bounds
        if let before = before, !before.deleted, let u = union {
            let b = before.bounds
            let inside = b.minX > u.minX && b.minY > u.minY && b.maxX < u.maxX && b.maxY < u.maxY
            if !inside && !(afterBounds?.contains(b) ?? false) { return false }
        }
        if let a = afterBounds { grow(a) }
        return true
    }

    private mutating func grow(_ r: Rect) {
        union = union.map { $0.union(r) } ?? r
    }
}

/// The active window's session, the workspace, the renderer and the main window.
@MainActor
final class LivePageSource: PresentationPageSource {
    /// Margin around a board's content in Full Page.
    static let boardMargin: Double = 48

    var onChange: (() -> Void)?
    var onLaser: ((LaserEvent) -> Void)?
    private unowned let app: NibApp
    private weak var session: EditorSession?
    private var sessionWatches = Set<AnyCancellable>()
    private var watches = Set<AnyCancellable>()
    private var subscriptions: [EventSubscription] = []
    private var version = 0
    /// The current page's position among the live pages (sorting them is O(n log n), and `current` runs on every
    /// scroll frame): dropped whenever that document's head changes or it closes.
    private var place: (doc: DocumentID, page: PageID, index: Int, count: Int)?
    private var board: BoardExtent?

    init(app: NibApp) {
        self.app = app
        subscriptions.append(app.bus.observeCommits { [weak self] changeset in self?.committed(changeset) })
        subscriptions.append(app.events.subscribe { [weak self] event in self?.received(event) })
        // The shell activates a window's session when the window becomes active, or (Split View, Stage Manager: both
        // scenes stay active) when the other window becomes key; re-read then.
        let center = NotificationCenter.default
        center.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in self?.onChange?() }
            .store(in: &watches)
        center.publisher(for: UIWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.onChange?() }
            .store(in: &watches)
    }

    var current: PresentedPage? {
        rebindIfNeeded()
        guard let session = session, let doc = session.document, let pid = session.page else { return nil }
        if app.services.lock?.isLocked(doc) == true { return nil }
        guard let content = try? app.workspace.content(doc), let record = content.page(pid), !record.deleted,
              let place = placeOf(doc: doc, page: pid, content: content) else { return nil }
        let bounds: Rect
        if let size = record.size {
            bounds = Rect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            bounds = boardBounds(doc: doc, page: pid) ?? session.visibleRect ?? .zero
        }
        return PresentedPage(doc: doc, page: pid, index: place.index, count: place.count, bounds: bounds,
                             visibleRect: session.visibleRect, version: version, hiddenLayers: session.hiddenLayers,
                             isBoard: record.size == nil)
    }

    func render(doc: DocumentID, page: PageID, region: Rect, scale: Double, hiddenLayers: Set<Int>) async throws -> CGImage {
        let renderer = try app.services.require(app.services.renderer, "the page renderer")
        let layers: Set<Int>? = hiddenLayers.isEmpty ? nil : Set(0...4).subtracting(hiddenLayers)
        let request = RenderRequest(doc: doc, page: page, region: region, scale: scale, layers: layers)
        return try await renderer.render(request).image
    }

    func snapshot(maxPixelWidth: CGFloat) -> CGImage? {
        guard let window = app.ui.activeNavigator?.rootViewController?.view.window, window.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(max(1, window.traitCollection.displayScale), max(1, maxPixelWidth / window.bounds.width))
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.cgImage
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        watches.removeAll()
        sessionWatches.removeAll()
        onChange = nil
        onLaser = nil
    }

    /// Follows whichever window is active (Split View, Stage Manager).
    private func rebindIfNeeded() {
        let active = app.services.sessions.active
        guard active !== session else { return }
        session = active
        sessionWatches.removeAll()
        guard let s = active else { return }
        s.$document.dropFirst().sink { [weak self] _ in self?.onChange?() }.store(in: &sessionWatches)
        s.$page.dropFirst().sink { [weak self] _ in self?.onChange?() }.store(in: &sessionWatches)
        s.$visibleRect.dropFirst().sink { [weak self] _ in self?.onChange?() }.store(in: &sessionWatches)
        s.$hiddenLayers.dropFirst().sink { [weak self] _ in self?.onChange?() }.store(in: &sessionWatches)
    }

    private func placeOf(doc: DocumentID, page: PageID, content: DocumentContent) -> (index: Int, count: Int)? {
        if let p = place, p.doc == doc, p.page == page { return (p.index, p.count) }
        let pages = content.livePages                      // one filter and sort for both numbers
        guard let index = pages.firstIndex(where: { $0.id == page }) else { return nil }
        place = (doc, page, index, pages.count)
        return (index, pages.count)
    }

    private func committed(_ changeset: Changeset) {
        if let p = place, changeset.headChanged(p.doc) { place = nil }
        if var b = board, changeset.itemPages[b.doc]?.contains(b.page) == true {
            var intact = true
            for case let .item(d, p, before, after) in changeset.mutations where d == b.doc && p == b.page {
                if !b.apply(before: before, after: after) {
                    intact = false
                    break
                }
            }
            board = intact ? b : nil                     // nil: rebuilt on the next read
        }
        guard let s = session, let doc = s.document, let pid = s.page, changeset.documents.contains(doc) else { return }
        if changeset.itemPages[doc]?.contains(pid) == true || changeset.headChanged(doc) {
            version += 1
            onChange?()
        }
    }

    private func received(_ event: NibEvent) {
        switch event.type {
        case NibEventType.laserMoved:
            onLaser?(LaserEvent(payload: event.payload))
        case NibEventType.docClosed:
            // A document merges from disk when it opens again: its cached numbers may be stale.
            if let doc = event.doc {
                if place?.doc == doc { place = nil }
                if board?.doc == doc { board = nil }
            }
            onChange?()
        case NibEventType.sessionDocument, NibEventType.pageChanged:
            onChange?()
        default:
            break
        }
    }

    /// A board has no page size: Full Page shows its content, plus a margin.
    private func boardBounds(doc: DocumentID, page: PageID) -> Rect? {
        if board?.doc != doc || board?.page != page {
            board = BoardExtent(doc: doc, page: page, items: (try? app.workspace.items(doc, page: page)) ?? [])
        }
        return board?.union.map { $0.insetBy(-LivePageSource.boardMargin) }
    }
}
