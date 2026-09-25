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
    static let detailDelay: Double = 0.15
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
        Task { [weak self] in await self?.drain(detailDelay: PresentationViewModel.detailDelay) }
    }

    /// Brings `display` up to date now. Tests pass `detailDelay: 0` so the viewport's sharp render happens inline.
    func update(detailDelay: Double = PresentationViewModel.detailDelay) async {
        while draining { await Task.yield() }
        dirty = true
        await drain(detailDelay: detailDelay)
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
            if dirty { return }                  // superseded while rendering: the next pass shows the latest state
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
        laser.reproject(page: page.page, camera: camera)
        guard mode == .presenter, needsDetail(viewport: viewport, page: page, baseScale: key.scale),
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

    /// Pixels per point that fill the display with `rect`, capped so no render is larger than `maxPixels`.
    func fitScale(for rect: Rect) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 1 }
        let px = Double(canvasSize.width * pixelScale), py = Double(canvasSize.height * pixelScale)
        let s = min(px / rect.width, py / rect.height, Self.maxPixels / max(rect.width, rect.height))
        return (max(s, 0.05) * 64).rounded() / 64         // 1/64 steps: a resize by a point never re-renders
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

/// The presenter's laser on the external display, in display points (DESIGN.md §14.12).
@MainActor
final class LaserModel: ObservableObject {
    struct Segment: Identifiable {
        let id: Int
        let from: CGPoint
        let to: CGPoint
        let color: UIColor
    }

    /// Fading segments kept at most (a 30 Hz trail fades in 600 ms, so about 18 are ever alive).
    static let maxSegments = 64

    @Published private(set) var dot: CGPoint?
    @Published private(set) var segments: [Segment] = []
    private(set) var color: UIColor = NibUIColor.destructive
    private var page: PageID?
    private var pagePoint: Point?
    private var nextID = 0

    func move(page: PageID, to point: Point, camera: CGAffineTransform, trail: Bool, color: UIColor) {
        let p = point.cg.applying(camera)
        if trail, let from = dot, from != p {
            segments.append(Segment(id: nextID, from: from, to: p, color: color))
            nextID += 1
            if segments.count > Self.maxSegments { segments.removeFirst(segments.count - Self.maxSegments) }
        }
        self.page = page
        pagePoint = point
        self.color = color
        dot = p
    }

    /// The camera moved: keep the dot on the same spot of the page.
    func reproject(page: PageID, camera: CGAffineTransform) {
        guard dot != nil else { return }
        guard page == self.page, let point = pagePoint else {
            lift()
            return
        }
        let p = point.cg.applying(camera)
        if dot != p { dot = p }
    }

    func lift() {
        if dot != nil { dot = nil }
        page = nil
        pagePoint = nil
    }

    func clear() {
        lift()
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

struct LaserOverlayView: View {
    @ObservedObject var laser: LaserModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(laser.segments) { segment in
                LaserTrailSegment(segment: segment) { laser.remove(segment.id) }
            }
            if let dot = laser.dot {
                LaserDot(color: Color(uiColor: laser.color))
                    .position(dot)
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
    let onFaded: () -> Void
    @State private var faded = false

    var body: some View {
        Path { path in
            path.move(to: segment.from)
            path.addLine(to: segment.to)
        }
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
    private var boardCache: (doc: DocumentID, page: PageID, version: Int, bounds: Rect?)?

    init(app: NibApp) {
        self.app = app
        subscriptions.append(app.bus.observeCommits { [weak self] changeset in self?.committed(changeset) })
        subscriptions.append(app.events.subscribe { [weak self] event in self?.received(event) })
        // The shell activates a window's session when the window becomes active; re-read then.
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in self?.onChange?() }
            .store(in: &watches)
    }

    var current: PresentedPage? {
        rebindIfNeeded()
        guard let session = session, let doc = session.document, let pid = session.page else { return nil }
        if app.services.lock?.isLocked(doc) == true { return nil }
        guard let content = try? app.workspace.content(doc), let record = content.page(pid), !record.deleted,
              let index = content.pageIndex(pid) else { return nil }
        let bounds: Rect
        if let size = record.size {
            bounds = Rect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            bounds = boardBounds(doc: doc, page: pid) ?? session.visibleRect ?? .zero
        }
        return PresentedPage(doc: doc, page: pid, index: index, count: content.livePages.count, bounds: bounds,
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

    private func committed(_ changeset: Changeset) {
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
        case NibEventType.sessionDocument, NibEventType.pageChanged, NibEventType.docClosed:
            onChange?()
        default:
            break
        }
    }

    /// A board has no page size: Full Page shows its content (cached per content version).
    private func boardBounds(doc: DocumentID, page: PageID) -> Rect? {
        if let c = boardCache, c.doc == doc, c.page == page, c.version == version { return c.bounds }
        var union: Rect?
        for item in (try? app.workspace.items(doc, page: page)) ?? [] {
            union = union.map { $0.union(item.bounds) } ?? item.bounds
        }
        let bounds = union.map { $0.insetBy(-LivePageSource.boardMargin) }
        boardCache = (doc, page, version, bounds)
        return bounds
    }
}
