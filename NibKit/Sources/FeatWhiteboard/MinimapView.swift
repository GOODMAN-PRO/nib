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

    /// The map's size: smaller in compact windows (iPhone, Slide Over).
    static func mapSize(compact: Bool) -> CGSize {
        compact ? CGSize(width: 168, height: 116) : CGSize(width: 208, height: 144)
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

enum MinimapLayout {
    /// Space kept free below the minimap: the page HUD (bottom-right, 16 pt in) on iPad; the palette's canvas inset on
    /// iPhone.
    static func bottomClearance(compact: Bool) -> CGFloat {
        compact ? NibMetrics.canvasBottomInsetCompact + NibSpacing.s
            : NibMetrics.chromeInset + NibMetrics.hudHeight + NibMetrics.minimumRestingGap
    }
}

enum MinimapSymbols {
    static let map = NibSymbol(systemName: "map") ?? .pages
    static let fit = NibSymbol(systemName: "arrow.up.left.and.arrow.down.right") ?? .search
}

// MARK: - Model

/// State of one canvas's minimap: the board's content bounds and a small render of it, the viewport, zoom, and the
/// board's item-limit status. Discrete actions are commands (view.zoom, settings.set, board.add, panel.open); dragging
/// the viewport is direct manipulation of the canvas, like scrolling it.
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
    @Published var compact = false {
        didSet { if oldValue != compact { updateGeometry() } }
    }

    let app: NibApp
    let doc: DocumentID
    let session: EditorSession
    weak var host: CanvasHost?
    var displayScale: CGFloat = 2
    private(set) var board: PageID?
    private var contentBounds: Rect?
    private var renderTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    init(app: NibApp, doc: DocumentID, session: EditorSession) {
        self.app = app
        self.doc = doc
        self.session = session
        showsMap = app.settings.get(Whiteboard.minimapVisible)
    }

    // MARK: Content

    func reloadContent() {
        board = session.document == doc ? session.page : nil
        guard let board, let items = try? app.workspace.items(doc, page: board) else {
            itemCount = 0
            limit = .ok
            contentBounds = nil
            sketch = []
            image = nil
            imageWorld = nil
            updateGeometry()
            return
        }
        itemCount = items.count
        limit = BoardLimit.status(count: items.count)
        contentBounds = TemplatePlacement.union(items)
        paper = Self.paper(of: (try? app.workspace.content(doc).page(board))?.background)
        sketch = app.services.renderer == nil ? Self.sketch(items) : []
        updateGeometry(forceRender: true)
    }

    /// A commit touched this document: refresh once the burst settles (a stroke burst is many commits).
    func committed(_ changes: Changeset) {
        guard changes.documents.contains(doc) else { return }
        let touched = board.map { changes.itemPages[doc]?.contains($0) ?? false } ?? false
        guard touched || changes.headChanged(doc) else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reloadContent()
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
        let g = MinimapGeometry(world: MinimapGeometry.world(content: contentBounds, visible: viewport),
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

    /// The board's paper colour (templates carry it as the "paper" parameter).
    static func paper(of background: Background?) -> RGBA {
        guard let background else { return .white }
        switch background.kind {
        case .color:
            return background.color ?? .white
        case .template:
            return background.template?.params["paper"]?.stringValue.flatMap { RGBA(hex: $0) } ?? .white
        case .pdf, .image:
            return .white
        }
    }

    // MARK: Actions

    func zoomIn() { perform("view.zoom", ["scale": .number(MinimapZoom.step(from: zoom, zoomIn: true))]) }
    func zoomOut() { perform("view.zoom", ["scale": .number(MinimapZoom.step(from: zoom, zoomIn: false))]) }
    func fit() { perform("view.zoom", ["fit": true]) }

    func toggleMap() {
        perform(CommandIDs.settingsSet, ["name": .string(Whiteboard.minimapVisible.name), "value": .bool(!showsMap)])
    }

    func showBoards() { perform("panel.open", ["id": .string(Whiteboard.boardsPanel)]) }

    func addBoard() {
        Task { @MainActor in
            do {
                let added = try await app.bus.execute(Invocation(command: "board.add",
                                                                 params: ["doc": .string(NodeRef.document(doc).description)],
                                                                 principal: .user, session: session))
                if let ref = added.value["ref"] { app.perform("view.goToPage", ["page": ref], session: session) }
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": "board.add", "error": NibError.wrap(error)])
            }
        }
    }

    func centre(onMap point: CGPoint) { centre(on: geometry.page(point)) }

    /// Moves the viewport by a fraction of its own size (VoiceOver and keyboard equivalents of dragging it).
    func pan(dx: Double, dy: Double) {
        guard let v = viewport else { return }
        centre(on: Point(v.midX + dx * v.width / 2, v.midY + dy * v.height / 2))
    }

    /// Scrolls the canvas so the board point `p` is in the middle of the window.
    func centre(on p: Point) {
        guard let host, let board else { return }
        let target = host.viewPoint(p, page: board)
        let bounds = host.canvasView.bounds
        let dx = target.x - bounds.midX, dy = target.y - bounds.midY
        if let scroll = host.canvasView as? UIScrollView {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x + dx, y: scroll.contentOffset.y + dy), animated: false)
        } else {
            perform("view.scrollBy", ["dx": .number(Double(dx)), "dy": .number(Double(dy))])
        }
    }

    private func perform(_ command: String, _ params: JSONValue) {
        app.perform(command, params, session: session)
    }
}

// MARK: - Canvas attachment

/// "whiteboard.minimap" (D-028, D-116): an overview of the board with the viewport, drag or tap to pan, double-tap to
/// fit all content, zoom % with − / + (5–400 %), a show/hide button, and the board's item-limit warning (D-030).
/// Pinned to the bottom trailing corner of the visible canvas, above the page HUD; it claims touches in its frame so
/// they never reach the active tool.
@MainActor
final class MinimapAttachment: CanvasAttachment {
    static let id = "whiteboard.minimap"
    /// Above page tiles and selection handles.
    static let zPosition: CGFloat = 30

    private(set) var model: MinimapModel?
    private(set) var hosting: UIHostingController<MinimapOverlay>?
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []
    private var modelChanges: AnyCancellable?
    private weak var host: CanvasHost?
    private var sizeKey: String?
    private var fittedSize: CGSize = .zero

    func attach(to host: CanvasHost) {
        self.host = host
        let model = MinimapModel(app: host.app, doc: host.documentID, session: host.session)
        model.host = host
        let hosting = UIHostingController(rootView: MinimapOverlay(model: model))
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        hosting.view.layer.zPosition = Self.zPosition
        host.canvasView.addSubview(hosting.view)
        self.model = model
        self.hosting = hosting
        subscriptions.append(host.app.bus.observeCommits { [weak model] changes in model?.committed(changes) })
        observers.append(NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: host.app.settings,
                                                                queue: .main) { [weak model] note in
            guard (note.userInfo?["name"] as? String) == Whiteboard.minimapVisible.name else { return }
            Task { @MainActor in model?.settingsChanged() }
        })
        // The overlay changes size when the map, the banner or the size class changes: re-pin it after SwiftUI updates.
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        model.reloadContent()
        canvasDidChange(host)
    }

    func detach(from host: CanvasHost) {
        hosting?.view.removeFromSuperview()
        hosting = nil
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        modelChanges = nil
        model = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        model?.viewChanged(zoom: host.zoomScale, visible: Self.visibleRect(host))
        layout()
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard let view = hosting?.view, view.superview != nil, !view.isHidden else { return false }
        return view.frame.contains(viewPoint)
    }

    /// The visible part of the board in page coordinates: the session's, else the canvas bounds mapped to the page.
    static func visibleRect(_ host: CanvasHost) -> Rect? {
        if let r = host.session.visibleRect, !r.isEmpty { return r }
        let b = host.canvasView.bounds
        guard let a = host.pagePoint(CGPoint(x: b.minX, y: b.minY)),
              let c = host.pagePoint(CGPoint(x: b.maxX, y: b.maxY)) else { return nil }
        return Rect.bounding([a.point, c.point])
    }

    /// Pins the overlay to the visible canvas's bottom trailing corner. Runs on every scroll frame, so SwiftUI is asked
    /// for the overlay's size only when something that shapes it changed.
    private func layout() {
        guard let host, let hosting, let model else { return }
        let canvas = host.canvasView
        let compact = canvas.traitCollection.horizontalSizeClass == .compact || canvas.bounds.width < NibMetrics.compactBreakpoint
        if model.compact != compact { model.compact = compact }
        if canvas.traitCollection.displayScale > 0 { model.displayScale = canvas.traitCollection.displayScale }
        let key = "\(model.showsMap)|\(model.limit)|\(model.limit == .ok ? 0 : model.itemCount)|\(compact)|"
            + canvas.traitCollection.preferredContentSizeCategory.rawValue
        if key != sizeKey {
            fittedSize = hosting.sizeThatFits(in: canvas.bounds.size)
            sizeKey = key
        }
        let size = fittedSize
        let b = canvas.bounds, safe = canvas.safeAreaInsets
        let frame = CGRect(x: b.maxX - safe.right - NibMetrics.chromeInset - size.width,
                           y: b.maxY - safe.bottom - MinimapLayout.bottomClearance(compact: compact) - size.height,
                           width: size.width, height: size.height)
        if hosting.view.frame != frame { hosting.view.frame = frame }
    }
}

// MARK: - Views

struct MinimapOverlay: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        VStack(alignment: .trailing, spacing: NibSpacing.s) {
            if model.limit != .ok { MinimapLimitBanner(model: model) }
            if model.showsMap { MinimapMap(model: model) }
            MinimapControls(model: model)
        }
        .fixedSize()
    }
}

/// The overview: a render of the board (item boxes without a renderer) and the viewport washed in accent. Content, not
/// chrome, sits inside the Deep surface; the viewport is a precision affordance and never deforms.
struct MinimapMap: View {
    @ObservedObject var model: MinimapModel

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
                    .overlay(Rectangle().strokeBorder(NibColor.accent, lineWidth: 1.5))
                    .frame(width: max(r.width, 6), height: max(r.height, 6))
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: NibRadius.concentric(NibRadius.popover, inset: NibSpacing.s),
                                    style: .continuous))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3).onChanged { model.centre(onMap: $0.location) })
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
        .padding(NibSpacing.s)
        .nibGlass(.deep, cornerRadius: NibRadius.popover)
    }
}

/// Show/hide, − zoom % +, fit: a Clear HUD, 40 pt tall like every HUD.
struct MinimapControls: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        HStack(spacing: 0) {
            NibIconButton(MinimapSymbols.map,
                          label: model.showsMap ? String(localized: "Hide Minimap") : String(localized: "Show Minimap"),
                          size: .bar, isOn: model.showsMap, shortcut: KeyboardShortcut("m", modifiers: [.command, .option])) {
                model.toggleMap()
            }
            NibBarSeparator()
            NibIconButton(.minus, label: String(localized: "Zoom Out"), size: .bar) { model.zoomOut() }
                .disabled(model.zoom <= MinimapZoom.range.lowerBound * 1.001)
            Text(model.zoom, format: .percent.precision(.fractionLength(0)))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
                .monospacedDigit()
                .frame(minWidth: NibSpacing.x5)
                .accessibilityLabel(String(localized: "Zoom"))
                .accessibilityValue(Text(model.zoom, format: .percent.precision(.fractionLength(0))))
            NibIconButton(.plus, label: String(localized: "Zoom In"), size: .bar) { model.zoomIn() }
                .disabled(model.zoom >= MinimapZoom.range.upperBound * 0.999)
            NibIconButton(MinimapSymbols.fit, label: String(localized: "Fit All Content"), size: .bar) { model.fit() }
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .nibGlass(.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Board zoom"))
    }
}

/// The board's item limit (D-030): a warning from 80 %, and at 100 % the remedies (a new board, the Boards sidebar to
/// move content). Board templates and conversions refuse to go past the limit themselves.
struct MinimapLimitBanner: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Image(nib: .warningTriangle)
                    .foregroundStyle(NibColor.warning)
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
                    NibButton(String(localized: "Boards"), kind: .plain, size: .compact) { model.showBoards() }
                }
            }
        }
        .padding(NibSpacing.m)
        .frame(width: MinimapGeometry.mapSize(compact: model.compact).width + 2 * NibSpacing.s, alignment: .leading)
        .nibGlass(.deep, cornerRadius: NibRadius.popover)
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch model.limit {
        case .full:
            return String(localized: "This board is full. Add a board, or move items to another one, to keep writing.")
        case .warning:
            return String(localized: "This board holds \(model.itemCount.formatted()) of \(NibLimits.boardItemLimit.formatted()) items.")
        case .ok:
            return ""
        }
    }
}
