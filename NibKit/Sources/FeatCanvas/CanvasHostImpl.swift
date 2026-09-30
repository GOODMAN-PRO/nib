import UIKit
import os
import NibContracts
import NibDesign

/// The canvas as tools, attachments, the input half and the Pencil handler see it (`CanvasHost`). One per open
/// notebook or whiteboard editor. Coordinates: `canvasView` is the scroll view and view points are its bounds
/// coordinates (they move with scrolling and zoom); page coordinates are page points (world points on a board).
@MainActor
final class CanvasHostImpl: CanvasHost, PageTileSource {
    let app: NibApp
    let session: EditorSession
    let documentID: DocumentID
    weak var controller: CanvasViewController?
    let scrollView: DocumentScrollView
    /// Above the scroll view, not scrolling or zooming (`fixedOverlayView`).
    let fixedOverlay: PassThroughView
    let overlayLayer = CALayer()
    /// The input half (F101), set in `CanvasInputHooks.install`.
    var inputController: CanvasInputController?
    /// Finger double-tap zooms between fit and 2× fit until the input half routes double-taps itself.
    let doubleTapZoomRecognizer = UITapGestureRecognizer()

    private static let log = Logger(subsystem: "app.nib", category: "canvas")

    private(set) var hiddenItems: [PageID: Set<ElementID>] = [:]
    private var liveViews: [ElementID: (view: UIView, page: PageID)] = [:]
    private(set) var activeTool: CanvasTool?
    private var activeToolID: String?

    private final class Waiter {
        let body: @MainActor () -> Void
        var done = false
        init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    }

    private var waiters: [PageID: [Waiter]] = [:]
    /// commitStroke calls still executing, per page: their commit has not happened yet.
    private var expecting: [PageID: Int] = [:]
    /// The longest a tool waits for dry tiles (a failed command, a page scrolled away, no renderer).
    static let renderWaitLimit: UInt64 = 1_500_000_000

    init(app: NibApp, session: EditorSession, documentID: DocumentID, scrollView: DocumentScrollView,
         fixedOverlay: PassThroughView) {
        self.app = app
        self.session = session
        self.documentID = documentID
        self.scrollView = scrollView
        self.fixedOverlay = fixedOverlay
        overlayLayer.actions = CanvasLayers.noActions
        overlayLayer.zPosition = 1000
        scrollView.layer.addSublayer(overlayLayer)
    }

    // MARK: CanvasHost basics

    var zoomScale: Double { scrollView.zoom }
    var canvasView: UIView { scrollView }
    var fixedOverlayView: UIView { fixedOverlay }
    var wetInkContainer: UIView { scrollView.wetInkContainer }

    /// Read-only (the session's mode or a document that must not be written): no ink, no tool input.
    var isReadOnly: Bool { session.readOnly || app.isReadOnly(documentID) }
    var isInkEnabled: Bool { !isReadOnly }

    /// Layers the session shows.
    var visibleLayers: Set<Int> { Set(0..<NibLimits.layerCount).subtracting(session.hiddenLayers) }

    /// Attachments in registry order (the input half asks them first, ARCHITECTURE §8.5).
    var attachments: [CanvasAttachment] { controller?.attachmentHost.attachments ?? [] }

    /// Pages that have a view right now (on screen or one page away).
    var displayedPages: [PageID] { scrollView.pages.filter { scrollView.pageViews[$0] != nil } }

    func pageFrame(_ page: PageID) -> CGRect? {
        guard let f = scrollView.layoutFrame(page) else { return nil }
        return scrollView.viewRect(layout: f)
    }

    func pageTransform(_ page: PageID) -> CGAffineTransform? {
        guard let origin = scrollView.layoutOrigin(page) else { return nil }
        let z = scrollView.zoom
        let o = scrollView.contentView.frame.origin
        return CGAffineTransform(a: CGFloat(z), b: 0, c: 0, d: CGFloat(z),
                                 tx: CGFloat(Double(o.x) + origin.x * z), ty: CGFloat(Double(o.y) + origin.y * z))
    }

    func viewPoint(_ p: Point, page: PageID) -> CGPoint {
        guard let t = pageTransform(page) else { return .zero }
        return CGPoint(x: p.x, y: p.y).applying(t)
    }

    func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? {
        let lp = scrollView.layoutPoint(v)
        switch scrollView.mode {
        case .world(let id):
            guard let origin = scrollView.layoutOrigin(id) else { return nil }
            return (id, Point(lp.x - origin.x, lp.y - origin.y))
        case .stack:
            guard let i = scrollView.layout.page(at: lp), i < scrollView.pages.count else { return nil }
            let f = scrollView.layout.frames[i]
            return (scrollView.pages[i], Point(lp.x - f.x, lp.y - f.y))
        }
    }

    func convert(_ point: Point, from source: PageID, to target: PageID) -> Point? {
        if source == target { return point }
        guard let a = scrollView.layoutOrigin(source), let b = scrollView.layoutOrigin(target) else { return nil }
        return Point(point.x + a.x - b.x, point.y + a.y - b.y)
    }

    /// `rect` (page coordinates) in window coordinates, for the inking signal and chrome anchors.
    func windowRect(_ rect: Rect, page: PageID) -> CGRect? {
        guard let t = pageTransform(page) else { return nil }
        let v = rect.cg.applying(t)
        return scrollView.window == nil ? v : scrollView.convert(v, to: nil)
    }

    // MARK: Hidden items, invalidation

    func setHidden(_ ids: Set<ElementID>, page: PageID) {
        let before = hiddenItems[page] ?? []
        guard before != ids else { return }
        hiddenItems[page] = ids.isEmpty ? nil : ids
        // Only the tiles under the items that appear or disappear are drawn again.
        var dirty: Rect?
        for id in before.symmetricDifference(ids) {
            guard let item = try? app.workspace.item(documentID, page: page, id: id) else { continue }
            let r = app.content.paintBounds(for: item)
            dirty = dirty.map { $0.union(r) } ?? r
        }
        for id in before.union(ids) {
            if let entry = liveViews[id], entry.page == page { entry.view.isHidden = ids.contains(id) }
        }
        if let dirty = dirty { scrollView.pageViews[page]?.invalidate(dirty) }
    }

    func invalidate(page: PageID, rect: Rect?) {
        app.services.renderer?.invalidate(doc: documentID, page: page, rect: rect)
        scrollView.pageViews[page]?.invalidate(rect)
    }

    // MARK: Strokes

    func commitStroke(_ stroke: Stroke, page: PageID) {
        commitStroke(stroke, page: page) { _ in }
    }

    /// Stroke processors in registry order (stabilisation, straight highlighter, ruler projection), then
    /// `ink.addStrokes` as the user. A processor that drops the stroke succeeds with nil; a failing command reports
    /// its error, so a tool never records history for a stroke that was not written.
    func commitStroke(_ stroke: Stroke, page: PageID, completion: @escaping @MainActor (Result<ElementID?, NibError>) -> Void) {
        guard !isReadOnly else {
            completion(.failure(NibError(.permissionDenied, "This document is read-only.",
                                         hint: "turn off read-only mode (view.setReadOnly) to write")))
            return
        }
        var s = stroke
        for entry in app.content.strokeProcessors.all {
            if !entry.processor.process(&s, page: page, session: session) {
                completion(.success(nil))
                return
            }
        }
        let params: JSONValue
        do {
            params = ["page": .string(NodeRef.page(documentID, page).description), "strokes": .array([try JSONValue.from(s)])]
        } catch {
            completion(.failure(NibError.wrap(error)))
            return
        }
        expecting[page, default: 0] += 1
        let invocation = Invocation(command: CommandIDs.inkAddStrokes, params: params, principal: .user, session: session)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let outcome: Result<ElementID?, NibError>
            do {
                let r = try await self.app.bus.execute(invocation)
                outcome = .success(CanvasHostImpl.createdItem(r))
            } catch {
                let e = NibError.wrap(error)
                CanvasHostImpl.log.error("ink.addStrokes failed: \(e.description, privacy: .public)")
                outcome = .failure(e)
            }
            self.expecting[page] = max(0, (self.expecting[page] ?? 1) - 1)
            completion(outcome)
            self.flushWaitersIfReady(page)
        }
    }

    /// The id of the item a creating command made: its `ref` / `refs[0]`, else the first created ref.
    static func createdItem(_ r: InvocationResult) -> ElementID? {
        let candidates = [r.value["ref"]?.stringValue, r.value["refs"]?[0]?.stringValue, r.value["ids"]?[0]?.stringValue]
            + r.changes.created.map { Optional($0) }
        for c in candidates {
            guard let s = c else { continue }
            if case let .item(_, _, id)? = NodeRef(s) { return id }
            if NibID.isValid(s), !s.contains(":") { return NibID(s) }
        }
        return nil
    }

    func cancelWetStroke() {
        inputController?.canvasCancelWetStroke(self)
    }

    func finishToolUse(_ tool: CanvasTool) {
        session.finishToolUse(sticky: tool.isSticky)
    }

    // MARK: After the next render

    /// Runs `body` once the dry tiles of `page` have been drawn after the latest commit: at once (next main-queue turn)
    /// when nothing is pending, else when the page's pending renders land and every `commitStroke` for it has
    /// finished. Never later than `renderWaitLimit`.
    func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void) {
        let waiter = Waiter(body)
        guard isWaiting(page) else {
            Task { @MainActor in waiter.body() }
            return
        }
        waiters[page, default: []].append(waiter)
        Task { @MainActor [weak self, weak waiter] in
            try? await Task.sleep(nanoseconds: CanvasHostImpl.renderWaitLimit)
            guard let waiter = waiter, !waiter.done else { return }
            waiter.done = true
            self?.waiters[page]?.removeAll { $0 === waiter }
            waiter.body()
        }
    }

    private func isWaiting(_ page: PageID) -> Bool {
        (expecting[page] ?? 0) > 0 || (scrollView.pageViews[page]?.pendingRenders ?? 0) > 0
    }

    func flushWaitersIfReady(_ page: PageID) {
        guard !isWaiting(page), let list = waiters.removeValue(forKey: page) else { return }
        for w in list where !w.done {
            w.done = true
            w.body()
        }
    }

    /// Runs every waiting body (the canvas closes).
    func flushAllWaiters() {
        let all = waiters
        waiters.removeAll()
        for w in all.values.flatMap({ $0 }) where !w.done {
            w.done = true
            w.body()
        }
    }

    // MARK: PageTileSource

    func renderTile(page: PageID, region: Rect?, scale: Double) async throws -> CGImage {
        guard let renderer = app.services.renderer else { throw NibError.unavailable("page renderer") }
        var request = RenderRequest(doc: documentID, page: page, region: region, scale: scale, layers: visibleLayers,
                                    background: true, annotations: true, hidden: hiddenItems[page] ?? [],
                                    marks: false, replay: session.replay)
        request.purpose = .screen
        let result = try await renderer.render(request)
        try Task.checkCancellation()
        return result.image
    }

    func pageTileViewDidSettle(_ view: PageTileView) {
        guard let page = view.pageID else { return }
        flushWaitersIfReady(page)
        controller?.pageDidSettle(page)
    }

    func pageTileView(_ view: PageTileView, didFailWith error: Error) {
        // No renderer installed (a stripped-down build): the pages show their paper, which is not a failure.
        guard let page = view.pageID, NibError.wrap(error).code != .unavailable else { return }
        CanvasHostImpl.log.error("page \(page.raw, privacy: .public) failed to render: \(NibError.wrap(error).description, privacy: .public)")
        controller?.pageDidFail(page)
    }

    // MARK: Live views

    /// Keeps `view` over the item's frame (it scales and scrolls with the page); nil removes it.
    func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) {
        if let old = liveViews[item]?.view, old !== view { old.removeFromSuperview() }
        guard let view = view else {
            liveViews[item] = nil
            return
        }
        liveViews[item] = (view, page)
        placeLiveView(item)
    }

    /// Re-places the live views of `page` (its view appeared, or a commit moved items).
    func placeLiveViews(on page: PageID) {
        for (id, entry) in liveViews where entry.page == page { placeLiveView(id) }
    }

    private func placeLiveView(_ id: ElementID) {
        guard let entry = liveViews[id] else { return }
        guard let pageView = scrollView.pageViews[entry.page],
              let item = try? app.workspace.item(documentID, page: entry.page, id: id) else {
            entry.view.removeFromSuperview()
            return
        }
        let frame = item.frame ?? Frame(item.bounds)
        if entry.view.superview !== pageView.liveViewContainer { pageView.liveViewContainer.addSubview(entry.view) }
        entry.view.transform = .identity
        entry.view.bounds = CGRect(x: 0, y: 0, width: frame.w, height: frame.h)
        entry.view.center = CGPoint(x: frame.center.x, y: frame.center.y)
        entry.view.transform = CGAffineTransform(rotationAngle: CGFloat(frame.rotation))
        entry.view.isHidden = hiddenItems[entry.page]?.contains(id) ?? false
    }

    var liveViewCount: Int { liveViews.count }

    // MARK: Active tool

    /// Makes the tool for `session.tool` from `ui.canvasTools` (deactivating the previous one) when it changed, or
    /// when its descriptor was registered again (`force`).
    func syncActiveTool(force: Bool = false) {
        let id = session.tool
        guard force || id != activeToolID else { return }
        activeTool?.deactivate(self)
        clearOverlay()
        activeToolID = id
        activeTool = app.ui.canvasTools.get(id)?.make()
        activeTool?.activate(self)
        inputController?.canvasActiveToolDidChange(self)
    }

    var activeToolIdentifier: String? { activeToolID }

    func deactivateTool() {
        activeTool?.deactivate(self)
        activeTool = nil
        activeToolID = nil
        clearOverlay()
    }

    private func clearOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in overlayLayer.sublayers ?? [] { l.removeFromSuperlayer() }
        CATransaction.commit()
    }

    /// Keeps the tool layer covering the content so tool previews in `canvasView` coordinates are never clipped.
    func layoutOverlay() {
        let content = CGRect(origin: .zero, size: scrollView.contentSize)
        guard overlayLayer.frame != content else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.frame = content
        CATransaction.commit()
    }

    // MARK: Inking signal (contracts-v2, G12)

    /// The Pencil (or a drawing finger, or a lasso drag) went down on `page`: chrome and HUDs recede.
    func beginInking(page: PageID, strokeBounds: Rect?) {
        session.inking.begin(strokeBounds: strokeBounds.flatMap { windowRect($0, page: page) })
    }

    /// The stroke grew (page coordinates).
    func updateInking(page: PageID, strokeBounds: Rect) {
        guard let r = windowRect(strokeBounds, page: page) else { return }
        session.inking.update(strokeBounds: r)
    }

    func endInking() {
        session.inking.end()
    }

    // MARK: Hit testing for the input half

    /// The topmost live item on a visible layer whose hit area (`ContentRegistries.hitBounds`) contains `point`,
    /// grown by `tolerance` page points: the `ref` finger gestures are offered with.
    func topmostItem(at point: Point, page: PageID, tolerance: Double = 0) -> Item? {
        guard let items = try? app.workspace.items(documentID, page: page) else { return nil }
        let layers = visibleLayers
        for item in items.reversed() where layers.contains(item.layer) {
            if app.content.hitBounds(for: item).insetBy(-tolerance).contains(point) { return item }
        }
        return nil
    }

    /// Double-tap zoom: to twice fit around `viewPoint`, or back to fit.
    func zoomToggle(at viewPoint: CGPoint) {
        controller?.toggleZoom(at: viewPoint)
    }
}
