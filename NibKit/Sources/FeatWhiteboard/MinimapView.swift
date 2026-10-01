import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Geometry (pure)

/// Maps a page-space `world` region into a minimap of `size` points, letterboxed and centred.
struct MinimapGeometry: Equatable {
    let world: Rect
    let size: CGSize

    /// Map points per page point.
    var scale: Double {
        min(Double(size.width) / max(world.width, 1), Double(size.height) / max(world.height, 1))
    }

    /// Top-left of the world inside the map.
    var inset: CGPoint {
        CGPoint(x: CGFloat((Double(size.width) - world.width * scale) / 2),
                y: CGFloat((Double(size.height) - world.height * scale) / 2))
    }

    func map(_ p: Point) -> CGPoint {
        CGPoint(x: CGFloat(Double(inset.x) + (p.x - world.x) * scale), y: CGFloat(Double(inset.y) + (p.y - world.y) * scale))
    }

    func map(_ r: Rect) -> CGRect {
        let o = map(Point(r.x, r.y))
        return CGRect(x: o.x, y: o.y, width: CGFloat(r.width * scale), height: CGFloat(r.height * scale))
    }

    func page(_ m: CGPoint) -> Point {
        let s = max(scale, 1e-9)
        return Point(world.x + (Double(m.x) - Double(inset.x)) / s, world.y + (Double(m.y) - Double(inset.y)) / s)
    }

    static let padding = 0.08
    static let minimumSide = 400.0

    /// What the minimap shows: the board's content and the viewport together, padded 8 %, at least 400 pt a side.
    static func world(content: Rect?, visible: Rect?) -> Rect {
        let parts = [content, visible].compactMap { $0 }.filter { $0.width > 0 || $0.height > 0 }
        guard var r = parts.first else {
            return Rect(x: -minimumSide / 2, y: -minimumSide / 2, width: minimumSide, height: minimumSide)
        }
        for p in parts.dropFirst() { r = r.union(p) }
        let pad = max(r.width, r.height) * padding
        r = Rect(x: r.x - pad, y: r.y - pad, width: r.width + 2 * pad, height: r.height + 2 * pad)
        if r.width < minimumSide {
            r.x -= (minimumSide - r.width) / 2
            r.width = minimumSide
        }
        if r.height < minimumSide {
            r.y -= (minimumSide - r.height) / 2
            r.height = minimumSide
        }
        return r
    }

    /// The map's size: 208 × 144, smaller in compact windows (iPhone, Slide Over).
    static func mapSize(compact: Bool) -> CGSize {
        compact ? NibMetrics.minimapSizeCompact : NibMetrics.minimapSize
    }
}

/// Dragging the viewport: the map's geometry is frozen when the drag starts, so every finger position maps through
/// the same world. (The live world is the union of content and viewport, and moving the viewport changes it; mapping
/// through it would feed each move back into the next and the canvas would run away from the finger.)
struct MinimapDrag {
    private(set) var frozen: MinimapGeometry?

    var isActive: Bool { frozen != nil }

    /// The board point under `location`, in the geometry the drag started with (`current` when it starts now).
    mutating func target(for location: CGPoint, current: MinimapGeometry) -> Point {
        let geometry = frozen ?? current
        frozen = geometry
        return geometry.page(location)
    }

    mutating func end() { frozen = nil }
}

/// Panning the window from the minimap.
enum MinimapPan {
    /// The board point in the middle of the window now: under the canvas's centre (always current), else the middle of
    /// the session's visible rect.
    @MainActor
    static func windowCentre(_ host: CanvasHost, board: PageID?) -> Point? {
        let b = host.canvasView.bounds
        if let hit = host.pagePoint(CGPoint(x: b.midX, y: b.midY)), board == nil || hit.page == board { return hit.point }
        if let r = host.session.visibleRect, !r.isEmpty { return r.center }
        return nil
    }
}

/// Board zoom steps for the minimap's − / + (boards zoom 5–400 %, D-028).
enum MinimapZoom {
    static let range: ClosedRange<Double> = 0.05...4
    static let stops: [Double] = [0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    static func step(from zoom: Double, zoomIn: Bool) -> Double {
        if zoomIn { return stops.first { $0 > zoom * 1.001 } ?? range.upperBound }
        return stops.last { $0 < zoom * 0.999 } ?? range.lowerBound
    }
}

/// "Fit all content": the zoom that shows the whole board with a 10 % margin (100 % on an empty board).
enum MinimapFit {
    static let margin = 0.9

    static func scale(content: Rect?, canvas: CGSize) -> Double {
        guard let c = content, canvas.width > 0, canvas.height > 0 else { return 1 }
        let s = min(Double(canvas.width) / max(c.width, 1), Double(canvas.height) / max(c.height, 1)) * margin
        return min(max(s, MinimapZoom.range.lowerBound), MinimapZoom.range.upperBound)
    }
}

/// Live item count and content bounds of the board, kept up to date from commits without rescanning the board.
struct BoardContentTally: Equatable {
    private(set) var count = 0
    private(set) var bounds: Rect?

    init() {}

    init(items: [Item]) {
        count = items.count
        bounds = TemplatePlacement.union(items)
    }

    /// Applies one item write. Returns true when the bounds may have shrunk (a live item on their edge moved or went
    /// away), which only a rescan can settle.
    mutating func apply(before: Item?, after: Item) -> Bool {
        let wasLive = before.map { !$0.deleted } ?? false
        let isLive = !after.deleted
        count += (isLive ? 1 : 0) - (wasLive ? 1 : 0)
        var shrinks = false
        if wasLive, let old = before?.bounds, let current = bounds { shrinks = Self.touchesEdge(old, of: current) }
        if isLive { bounds = bounds.map { $0.union(after.bounds) } ?? after.bounds }
        return shrinks
    }

    static func touchesEdge(_ r: Rect, of bounds: Rect, tolerance: Double = 0.5) -> Bool {
        r.minX <= bounds.minX + tolerance || r.minY <= bounds.minY + tolerance
            || r.maxX >= bounds.maxX - tolerance || r.maxY >= bounds.maxY - tolerance
    }
}

/// D-030 "block at 100 %" on the canvas: `BoardLimitGuard` vetoes every item-creating command on a full board, and the
/// minimap also takes the touches that would ink it, so the pen never draws a stroke that is then refused. Only a
/// touch that draws is taken: the Pencil, and a finger when fingers draw (`NibSettings.stylusMode` anyInput); other
/// fingers still pan and zoom. The remedies keep working: erasing, selecting items to move them to another board, and
/// the laser pointer.
enum BoardLimitGate {
    static let removalTools: Set<String> = ["eraser", "lasso", "laser"]

    static func blocksWriting(_ limit: BoardLimitStatus, tool: String, isPencil: Bool = true,
                              fingersDraw: Bool = false) -> Bool {
        limit == .full && !removalTools.contains(tool) && (isPencil || fingersDraw)
    }
}

enum MinimapLayout {
    /// Join the page HUD's stack, after its order of 100. The chrome measures both views and leaves
    /// `NibMetrics.minimumRestingGap` above the HUD's actual frame, in the region already cleared of the
    /// palette, fused options and keyboard. No second size-class-specific clearance calculation.
    static let placement = ChromePlacement.bottomTrailing
    static let order = 101
}

/// The parts of the overlay that take touches; the gaps between them stay canvas.
enum MinimapPart: Hashable {
    case banner, map, controls
}

/// Frames of the overlay's parts in `NibLiquid.space`, as SwiftUI lays them out (written from layout callbacks,
/// read by hit testing; both on the main thread).
final class MinimapHitFrames {
    private(set) var frames: [MinimapPart: CGRect] = [:]

    func set(_ part: MinimapPart, _ frame: CGRect?) { frames[part] = frame }
    func clear() { frames.removeAll() }
}

// MARK: - Model

/// State of one canvas's minimap: the board's content bounds and a small render of it, the viewport, zoom, and the
/// board's item-limit status. Every action is a command (view.zoom, view.scrollBy, settings.set, board.add,
/// panel.open).
@MainActor
final class MinimapModel: ObservableObject {
    @Published private(set) var showsMap: Bool
    @Published private(set) var zoom: Double = 1
    @Published private(set) var geometry = MinimapGeometry(world: MinimapGeometry.world(content: nil, visible: nil),
                                                           size: MinimapGeometry.mapSize(compact: false))
    @Published private(set) var viewport: Rect?
    @Published private(set) var image: CGImage?
    /// The region `image` shows (it stays drawn, re-mapped, while a newer render is on its way).
    @Published private(set) var imageWorld: Rect?
    /// Item boxes, when no renderer is installed.
    @Published private(set) var sketch: [Rect] = []
    @Published private(set) var limit: BoardLimitStatus = .ok
    @Published private(set) var itemCount = 0
    @Published private(set) var paper: RGBA = .white
    /// Faded to 22 % while the Pencil (or a drawing finger) is down in this window, back 450 ms after it lifts
    /// (DESIGN §10.8, `EditorSession.inking`).
    @Published private(set) var receding = false
    /// Bumped each time a touch is refused because the board is full (the banner's glyph answers it).
    @Published private(set) var refusals = 0
    @Published var compact = false {
        didSet { if oldValue != compact { updateGeometry() } }
    }
    /// Where the overlay's parts are, so only they (not the gaps between them) take touches.
    let hitFrames = MinimapHitFrames()

    let app: NibApp
    let doc: DocumentID
    let session: EditorSession
    weak var host: CanvasHost?
    var displayScale: CGFloat = 2
    private(set) var board: PageID?
    private(set) var tally = BoardContentTally()
    private var dragState = MinimapDrag()
    private var pendingRescan = false
    private var pendingHead = false
    private var lastAnnouncement = Date.distantPast
    private var renderTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var recedeTask: Task<Void, Never>?
    /// The latest point the viewport should centre on while a `view.scrollBy` is on its way (a drag coalesces).
    private var pendingCentre: Point?
    private var isScrolling = false

    init(app: NibApp, doc: DocumentID, session: EditorSession) {
        self.app = app
        self.doc = doc
        self.session = session
        showsMap = app.settings.get(Whiteboard.minimapVisible)
    }

    // MARK: Content

    /// A full rescan of the board: on attach and board switches, and when a commit may have shrunk the content.
    func reloadContent() {
        board = session.document == doc ? session.page : nil
        pendingRescan = false
        pendingHead = false
        guard let board, let items = try? app.workspace.items(doc, page: board) else {
            tally = BoardContentTally()
            publishTally()
            sketch = []
            image = nil
            imageWorld = nil
            updateGeometry()
            return
        }
        tally = BoardContentTally(items: items)
        publishTally()
        paper = Self.paper(of: (try? app.workspace.content(doc).page(board))?.background)
        sketch = app.services.renderer == nil ? Self.sketch(items) : []
        updateGeometry(forceRender: true)
    }

    /// A commit touched this document: the count and bounds follow each item write at once, and the map refreshes when
    /// the burst settles (a stroke burst is many commits). Only a write that may shrink the content rescans the board.
    func committed(_ changes: Changeset) {
        guard changes.documents.contains(doc) else { return }
        var touched = false
        if let board {
            for mutation in changes.mutations {
                guard case let .item(d, p, before, after) = mutation, d == doc, p == board else { continue }
                touched = true
                if tally.apply(before: before, after: after) { pendingRescan = true }
            }
        }
        // Without a renderer the map draws item boxes, which need every item.
        if touched && app.services.renderer == nil { pendingRescan = true }
        let head = changes.headChanged(doc)
        guard touched || head else { return }
        if head { pendingHead = true }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.settle()
        }
    }

    private func settle() {
        if pendingRescan {
            reloadContent()
            return
        }
        if pendingHead, let board {
            paper = Self.paper(of: (try? app.workspace.content(doc).page(board))?.background)
            pendingHead = false
        }
        publishTally()
        updateGeometry(forceRender: true)
    }

    private func publishTally() {
        if itemCount != tally.count { itemCount = tally.count }
        let status = BoardLimit.status(count: tally.count)
        if limit != status { limit = status }
    }

    /// How long after the Pencil lifts the minimap comes back (DESIGN §10.8).
    static let returnDelay = NibMotion.recedeDelay

    /// The minimap sits over the board, so it recedes while the Pencil is down in this window and comes back
    /// `returnDelay` after it lifts (the canvas writes `session.inking`; updates while writing change nothing).
    func inkingChanged(_ isInking: Bool) {
        if isInking {
            recedeTask?.cancel()
            recedeTask = nil
            if !receding { receding = true }
            return
        }
        guard receding, recedeTask == nil else { return }
        recedeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.returnDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.receding = false
            self.recedeTask = nil
        }
    }

    func viewChanged(zoom: Double, visible: Rect?) {
        if self.zoom != zoom { self.zoom = zoom }
        if viewport != visible { viewport = visible }
        let current = session.document == doc ? session.page : nil
        if current != board {
            reloadContent()
        } else {
            updateGeometry()
        }
    }

    func settingsChanged() {
        let shown = app.settings.get(Whiteboard.minimapVisible)
        guard shown != showsMap else { return }
        showsMap = shown
        if shown { updateGeometry(forceRender: true) }
    }

    private func updateGeometry(forceRender: Bool = false) {
        // While the viewport is dragged the map keeps the geometry the drag started with (the viewport still moves).
        guard !dragState.isActive else { return }
        let g = MinimapGeometry(world: MinimapGeometry.world(content: tally.bounds, visible: viewport),
                                size: MinimapGeometry.mapSize(compact: compact))
        let changed = g != geometry
        if changed { geometry = g }
        if changed || forceRender { scheduleRender() }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard showsMap, let renderer = app.services.renderer, let board else { return }
        let world = geometry.world
        let scale = max(geometry.scale * Double(displayScale), 0.001)
        let request = RenderRequest(doc: doc, page: board, region: world, scale: scale, background: true, annotations: true)
        renderTask = Task { @MainActor [weak self] in
            // Renders after the viewport or the content stops changing, never per frame.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let result = try? await renderer.render(request), !Task.isCancelled else { return }
            self?.image = result.image
            self?.imageWorld = result.region
        }
    }

    /// Every n-th item's box, at most `limit` of them.
    static func sketch(_ items: [Item], limit: Int = 2_000) -> [Rect] {
        let step = max(1, items.count / max(limit, 1))
        return stride(from: 0, to: items.count, by: step).map { items[$0].bounds }
    }

    /// The board's paper colour (templates carry it as the `TemplateParamNames.paper` parameter).
    static func paper(of background: Background?) -> RGBA {
        guard let background else { return .white }
        switch background.kind {
        case .color:
            return background.color ?? .white
        case .template:
            return background.template?.params[TemplateParamNames.paper]?.stringValue.flatMap { RGBA(hex: $0) } ?? .white
        case .pdf, .image:
            return .white
        }
    }

    // MARK: Board limit

    /// True when a touch on the canvas must not reach the active tool: the board is full, the tool adds items, and
    /// this touch draws (the Pencil, or a finger when fingers draw).
    func blocksWriting(isPencil: Bool) -> Bool {
        guard limit == .full else { return false }
        return BoardLimitGate.blocksWriting(limit, tool: session.tool, isPencil: isPencil,
                                            fingersDraw: app.settings.get(NibSettings.stylusMode) == .anyInput)
    }

    /// A touch was refused on the full board: the banner's glyph answers, and VoiceOver hears why (once a burst).
    func refusedWrite() {
        refusals += 1
        let now = Date()
        guard now.timeIntervalSince(lastAnnouncement) > 3 else { return }
        lastAnnouncement = now
        AccessibilityNotification.Announcement(
            String(localized: "This board is full. Add a board, or erase or move items, to keep writing.")).post()
    }

    // MARK: Actions

    func zoomIn() { perform(CommandIDs.viewZoom, ["scale": .number(MinimapZoom.step(from: zoom, zoomIn: true))]) }
    func zoomOut() { perform(CommandIDs.viewZoom, ["scale": .number(MinimapZoom.step(from: zoom, zoomIn: false))]) }

    /// Zooms so the whole board fits the window (100 % on an empty one), then centres it.
    func fit() {
        guard let host else { return }
        let content = tally.bounds
        let scale = MinimapFit.scale(content: content, canvas: host.canvasView.bounds.size)
        let target = content?.center ?? .zero
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.app.bus.execute(Invocation(command: CommandIDs.viewZoom, params: ["scale": .number(scale)],
                                                              principal: .user, session: self.session))
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: self.app,
                                                userInfo: ["command": CommandIDs.viewZoom, "error": NibError.wrap(error)])
                return
            }
            self.centre(on: target)
        }
    }

    func toggleMap() {
        perform(CommandIDs.settingsSet, ["name": .string(Whiteboard.minimapVisible.name), "value": .bool(!showsMap)])
    }

    func showBoards() { perform(CommandIDs.panelOpen, ["id": .string(Whiteboard.boardsPanel)]) }

    func addBoard() {
        Task { @MainActor in
            do {
                let added = try await app.bus.execute(Invocation(command: CommandIDs.boardAdd,
                                                                 params: ["doc": .string(NodeRef.document(doc).description)],
                                                                 principal: .user, session: session))
                if let ref = added.value["ref"] { app.perform(CommandIDs.viewGoToPage, ["page": ref], session: session) }
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": CommandIDs.boardAdd, "error": NibError.wrap(error)])
            }
        }
    }

    /// Tap on the map: centre there.
    func centre(onMap point: CGPoint) { centre(on: geometry.page(point)) }

    /// Drag on the map: the viewport follows the finger 1:1 (see `MinimapDrag`).
    func drag(to location: CGPoint) { centre(on: dragState.target(for: location, current: geometry)) }

    func endDrag() {
        guard dragState.isActive else { return }
        dragState.end()
        updateGeometry(forceRender: true)
    }

    /// Moves the viewport by a fraction of its own size (VoiceOver and keyboard equivalents of dragging it).
    func pan(dx: Double, dy: Double) {
        guard let v = viewport else { return }
        centre(on: Point(v.midX + dx * v.width / 2, v.midY + dy * v.height / 2))
    }

    /// Scrolls the canvas so the board point `p` is in the middle of the window, with `view.scrollBy` (page points,
    /// §6.1; the canvas grows a board ahead of the pan). While one scroll is on its way, newer targets coalesce and
    /// each delta is measured from where the window is when it runs, so a fast drag never overshoots.
    func centre(on p: Point) {
        pendingCentre = p
        guard !isScrolling else { return }
        isScrolling = true
        Task { @MainActor [weak self] in
            while let self, let target = self.pendingCentre {
                self.pendingCentre = nil
                guard let host = self.host, let middle = MinimapPan.windowCentre(host, board: self.board) else { continue }
                let delta = target - middle
                guard abs(delta.x) > 1e-6 || abs(delta.y) > 1e-6 else { continue }
                do {
                    _ = try await self.app.bus.execute(Invocation(
                        command: CommandIDs.viewScrollBy, params: ["dx": .number(delta.x), "dy": .number(delta.y)],
                        principal: .user, session: self.session))
                } catch {
                    self.pendingCentre = nil
                    NotificationCenter.default.post(name: .nibCommandFailed, object: self.app,
                                                    userInfo: ["command": CommandIDs.viewScrollBy, "error": NibError.wrap(error)])
                }
            }
            self?.isScrolling = false
        }
    }

    private func perform(_ command: String, _ params: JSONValue) {
        app.perform(command, params, session: session)
    }
}

// MARK: - Canvas attachment

/// "whiteboard.minimap" (D-028, D-116): an overview of the board with the viewport, drag or tap to pan, double-tap to
/// fit all content, − / + (5–400 %), a show/hide button, and the board's item-limit warning (D-030).
/// The page HUD owns the zoom readout (§14.17).
/// Pinned to the bottom trailing corner of the visible canvas, above the page HUD; it claims the touches on its parts
/// so they never reach the active tool, and on a full board every touch that would ink it (`BoardLimitGate`).
@MainActor
final class MinimapAttachment: CanvasAttachment {
    static let id = "whiteboard.minimap"
    /// Attachments in different windows must not replace each other's overlay registrations.
    let overlayID = MinimapAttachment.id + "." + UUID().uuidString
    private(set) var model: MinimapModel?
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []
    private var sessionChanges: AnyCancellable?
    private weak var host: CanvasHost?
    private weak var floatingHost: FloatingHosting?

    func attach(to host: CanvasHost) {
        self.host = host
        let model = MinimapModel(app: host.app, doc: host.documentID, session: host.session)
        model.host = host
        self.model = model
        host.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: overlayID, owner: FeatWhiteboardFeature.id, placement: MinimapLayout.placement,
            surface: .none, order: MinimapLayout.order,
            // Each part already has its own droplet: no enclosing glass body or second recede opacity.
            recedesWhileWriting: false, docKinds: [.whiteboard],
            isVisible: { [weak self, weak model] context in
                guard let self, let model, self.model === model else { return false }
                return context.session === model.session && context.session.document == model.doc
            },
            makeView: { [weak model] _ in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(MinimapOverlay(model: model))
            }))
        subscriptions.append(host.app.bus.observeCommits { [weak model] changes in model?.committed(changes) })
        subscriptions.append(host.session.inking.observe { [weak model] signal in model?.inkingChanged(signal.isInking) })
        observers.append(NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: host.app.settings,
                                                                queue: .main) { [weak model] note in
            guard (note.userInfo?["name"] as? String) == Whiteboard.minimapVisible.name else { return }
            Task { @MainActor in model?.settingsChanged() }
        })
        // The chrome owns placement; the attachment only tracks canvas traits and coordinate conversion.
        sessionChanges = host.session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        model.reloadContent()
        canvasDidChange(host)
        // Attachments can be installed before the document container publishes its floating host.
        Task { @MainActor [weak self] in self?.layout() }
    }

    func detach(from host: CanvasHost) {
        host.app.ui.chromeOverlays.unregister(id: overlayID)
        floatingHost = nil
        model?.hitFrames.clear()
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        sessionChanges = nil
        model = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        model?.viewChanged(zoom: host.zoomScale, visible: Self.visibleRect(host))
        layout()
    }

    func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool {
        guard let model else { return false }
        if model.blocksWriting(isPencil: isPencil) { return true }
        guard host.session.document == model.doc, let floatingHost,
              floatingHost === host.session.floatingHost,
              let point = floatingHost.containerRect(CGRect(origin: viewPoint, size: .zero), from: host.canvasView)?.origin
        else { return false }
        let parts = Array(model.hitFrames.frames.values).filter { !$0.isEmpty }
        // Until SwiftUI reports the parts, native hit testing still handles the floating controls. Never claim canvas.
        return !parts.isEmpty && Self.overlayTakes(point, parts: parts)
    }

    /// A canvas that does not say which input it is: treated as the Pencil, so a full board never takes ink.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        hitTest(viewPoint, isPencil: true, host: host)
    }

    /// Whether a point in the overlay's coordinates lands on one of its parts. Until SwiftUI has reported the parts,
    /// the whole overlay counts.
    static func overlayTakes(_ point: CGPoint, parts: [CGRect]) -> Bool {
        let laidOut = parts.filter { !$0.isEmpty }
        return laidOut.isEmpty || laidOut.contains { $0.contains(point) }
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        guard let model, model.blocksWriting(isPencil: sample.isPencil) else { return }
        model.refusedWrite()
    }

    /// The visible part of the board in page coordinates: the session's, else the canvas bounds mapped to the page.
    static func visibleRect(_ host: CanvasHost) -> Rect? {
        if let r = host.session.visibleRect, !r.isEmpty { return r }
        let b = host.canvasView.bounds
        guard let a = host.pagePoint(CGPoint(x: b.minX, y: b.minY)),
              let c = host.pagePoint(CGPoint(x: b.maxX, y: b.maxY)) else { return nil }
        return Rect.bounding([a.point, c.point])
    }

    /// The shared chrome stack positions this overlay above the measured page HUD, including the palette's
    /// fused options clearance. Keep only sizing and hit-test conversion here; panning never changes placement.
    private func layout() {
        guard let host, let model else { return }
        let canvas = host.canvasView
        let compactHeight = canvas.traitCollection.verticalSizeClass == .compact
        let compact = canvas.traitCollection.horizontalSizeClass == .compact || compactHeight
            || canvas.bounds.width < NibMetrics.compactBreakpoint
        if model.compact != compact { model.compact = compact }
        if canvas.traitCollection.displayScale > 0 { model.displayScale = canvas.traitCollection.displayScale }
        if floatingHost !== host.session.floatingHost {
            model.hitFrames.clear()
            floatingHost = host.session.floatingHost
        }
    }
}

// MARK: - Views

/// Measured by the same chrome layout as the page HUD. Only the parts take touches; gaps stay canvas.
struct MinimapOverlay: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        VStack(alignment: .trailing, spacing: NibSpacing.l) {
            if model.limit != .ok { MinimapLimitBanner(model: model).minimapPart(.banner, model.hitFrames) }
            if model.showsMap { MinimapMap(model: model).minimapPart(.map, model.hitFrames) }
            MinimapControls(model: model).minimapPart(.controls, model.hitFrames)
        }
        .fixedSize()
    }
}

private extension View {
    /// Reports this part's frame, so only the parts (not the gaps between them) take touches.
    func minimapPart(_ part: MinimapPart, _ frames: MinimapHitFrames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: NibLiquid.space) } action: { frames.set(part, $0) }
            .onDisappear { frames.set(part, nil) }
    }
}

/// The overview: a render of the board (item boxes without a renderer) and the viewport washed in accent. Content, not
/// chrome, sits inside the Deep surface; the viewport is a precision affordance and never deforms.
struct MinimapMap: View {
    @ObservedObject var model: MinimapModel
    /// Resets when the drag ends or is cancelled, so the map never stays frozen.
    @GestureState private var dragging = false

    var body: some View {
        let g = model.geometry
        ZStack(alignment: .topLeading) {
            Color(uiColor: model.paper.uiColor)
            if let image = model.image, let world = model.imageWorld {
                let r = g.map(world)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            } else {
                Canvas { context, _ in
                    for box in model.sketch {
                        context.fill(Path(g.map(box)), with: .color(NibColor.labelTertiary))
                    }
                }
            }
            if let viewport = model.viewport {
                let r = g.map(viewport)
                Rectangle()
                    .fill(NibColor.accentWash)
                    .overlay(Rectangle().strokeBorder(NibColor.accent, lineWidth: NibSpacing.xxs))
                    .frame(width: max(r.width, NibSpacing.s), height: max(r.height, NibSpacing.s))
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        // The droplet clips to its own body; the board render has no inset card or separate rounded bezel.
        .clipped()
        .contentShape(Rectangle())
        // Panning the viewport takes priority over the floating-panel preset's pickup gesture.
        .highPriorityGesture(DragGesture(minimumDistance: 3)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { model.drag(to: $0.location) }
            .onEnded { _ in model.endDrag() })
        .onChange(of: dragging) { _, isDragging in
            if !isDragging { model.endDrag() }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.fit() }
            .exclusively(before: SpatialTapGesture().onEnded { model.centre(onMap: $0.location) }))
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Board overview"))
        .accessibilityValue(Text(model.zoom, format: .percent.precision(.fractionLength(0))))
        .accessibilityHint(String(localized: "Drag or tap to move the view. Double-tap to fit all content."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.zoomIn()
            case .decrement: model.zoomOut()
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(String(localized: "Fit All Content"))) { model.fit() }
        .accessibilityAction(named: Text(String(localized: "Move View Left"))) { model.pan(dx: -1, dy: 0) }
        .accessibilityAction(named: Text(String(localized: "Move View Right"))) { model.pan(dx: 1, dy: 0) }
        .accessibilityAction(named: Text(String(localized: "Move View Up"))) { model.pan(dx: 0, dy: -1) }
        .accessibilityAction(named: Text(String(localized: "Move View Down"))) { model.pan(dx: 0, dy: 1) }
        .droplet("whiteboard.minimap", style: .floatingPanel)
    }
}

/// Show/hide, − / +, fit: a Clear HUD, 40 pt tall like every HUD. Zoom is shown by the page HUD.
struct MinimapControls: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        HStack(spacing: 0) {
            NibIconButton(.minimap,
                          label: model.showsMap ? String(localized: "Hide Minimap") : String(localized: "Show Minimap"),
                          size: .bar, isOn: model.showsMap, shortcut: KeyboardShortcut("m", modifiers: [.command, .option])) {
                model.toggleMap()
            }
            NibBarSeparator()
            NibIconButton(.minus, label: String(localized: "Zoom Out"), size: .bar) { model.zoomOut() }
                .disabled(model.zoom <= MinimapZoom.range.lowerBound * 1.001)
            NibIconButton(.plus, label: String(localized: "Zoom In"), size: .bar) { model.zoomIn() }
                .disabled(model.zoom >= MinimapZoom.range.upperBound * 0.999)
            NibIconButton(.fitToContent, label: String(localized: "Fit All Content"), size: .bar) { model.fit() }
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .droplet("whiteboard.minimapControls", style: .hud)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Board zoom"))
    }
}

/// The board's item limit (D-030): a warning from 80 %, and at 100 % writing on the board is paused (the minimap takes
/// the touches of tools that add items) with the remedies: a new board, or the Boards sidebar to move content.
struct MinimapLimitBanner: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Image(nib: .warningTriangle)
                    .foregroundStyle(NibColor.warning)
                    .symbolEffect(.bounce, value: model.refusals)
                    .accessibilityHidden(true)
                Text(message)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.limit == .full {
                HStack(spacing: NibSpacing.s) {
                    NibButton(String(localized: "Add Board"), symbol: .plus, kind: .secondary, size: .compact) {
                        model.addBoard()
                    }
                    NibButton(String(localized: "Show Boards"), kind: .plain, size: .compact) { model.showBoards() }
                }
            }
        }
        .padding(NibSpacing.m)
        .frame(width: MinimapGeometry.mapSize(compact: model.compact).width, alignment: .leading)
        .droplet("whiteboard.minimapLimit", style: .panel)
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch model.limit {
        case .full:
            return String(localized: "This board is full, so writing on it is paused. Add a board, or erase items or move them to another board.")
        case .warning:
            return String(localized: "This board holds \(model.itemCount.formatted()) of \(NibLimits.boardItemLimit.formatted()) items.")
        case .ok:
            return ""
        }
    }
}
