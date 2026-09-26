import UIKit
import SwiftUI
import Combine
import os
import NibContracts
import NibDesign

/// The notebook and whiteboard editor (`ui.editors` for `.notebook` and `.whiteboard`, `DocumentEditing`): the
/// document's pages on the desk, scrolled vertically or paged horizontally (`meta.scrollDirection`), or one
/// infinite board; pinch, double-tap and `view.zoom` zoom it (50–800 %, boards 5–400 %). It owns the `CanvasHost`,
/// hosts `ui.canvasAttachments`, activates the active tool, keeps `session.page` / `zoom` / `visibleRect` current,
/// shows the page HUD and pinch-zoom HUD (chrome overlays), the horizontal page scrubber, and offers a new page when
/// you pull past the last one. Ink capture is the input half (F101, `CanvasInputHooks`).
@MainActor
final class CanvasViewController: UIViewController, DocumentEditing, UIScrollViewDelegate, DocumentScrollViewHost,
    UIGestureRecognizerDelegate {
    let documentID: DocumentID
    let session: EditorSession
    let app: NibApp
    let scrollView: DocumentScrollView
    let fixedOverlay: PassThroughView
    let host: CanvasHostImpl
    let attachmentHost: CanvasAttachmentHost
    let hud = CanvasHUDModel()
    var canvasHost: CanvasHost? { host }

    private static let log = Logger(subsystem: "app.nib", category: "canvas")
    /// DESIGN.md §14.18: a small activity indicator in the page HUD only after 400 ms of loading.
    static let loadingIndicatorDelay: UInt64 = 400_000_000
    /// Session zoom and visible rect are published at most this often while scrolling (they drive SwiftUI chrome).
    static let sessionPublishInterval: UInt64 = 100_000_000
    /// How far past the last page you pull before releasing adds a page.
    static let addPageThreshold = NibSpacing.x6

    // Model
    private(set) var kind: DocumentKind = .notebook
    private(set) var livePages: [PageRecord] = []
    private(set) var direction: ScrollDirection = .vertical
    private(set) var mode: CanvasMode = .stack(.vertical)
    private var shown: [PageID: PageRecord] = [:]
    private(set) var board: BoardWorld?
    private(set) var boardContent: Rect?
    private var boardContentStale = true

    // Zoom
    private(set) var fitZoom: Double = 1
    private(set) var zoomLimits: ClosedRange<Double> = ZoomRules.notebookRange
    private var isAtFit = true
    private(set) var didInitialLayout = false
    private var lastViewport: CGSize = .zero

    // Navigation requested before the first layout
    private var pendingPage: PageID?
    private var pendingReveal: (page: PageID, rect: Rect)?
    private var pendingZoom: Double?

    // Tracking
    private var settingSessionPage = false
    private var dragStartIndex = 0
    private var addPageArmed = false
    private(set) var isClosed = false
    private var hadParent = false
    private var subscriptions: [AnyCancellable] = []
    private var commitObservation: EventSubscription?
    private var eventObservation: EventSubscription?
    private var inkingObservation: EventSubscription?
    private var notificationObservers: [NSObjectProtocol] = []
    private var paperCache: [String: UIColor] = [:]
    private(set) var failedPages: Set<PageID> = []
    private var loadingTask: Task<Void, Never>?
    private var sessionFlushScheduled = false
    private var hudLingerTask: Task<Void, Never>?
    private var replayDirty = false

    // Views
    private let scrubber = PageScrubberView()
    private let addPageIndicator = AddPageIndicatorView()
    private let errorView = PageErrorView()
    private var emptyHost: UIViewController?

    init(documentID: DocumentID, session: EditorSession, app: NibApp) {
        self.documentID = documentID
        self.session = session
        self.app = app
        let scroll = DocumentScrollView(frame: .zero)
        let overlay = PassThroughView()
        self.scrollView = scroll
        self.fixedOverlay = overlay
        let host = CanvasHostImpl(app: app, session: session, documentID: documentID, scrollView: scroll,
                                  fixedOverlay: overlay)
        self.host = host
        let kind = (try? app.workspace.content(documentID).meta.kind) ?? .notebook
        self.kind = kind
        self.attachmentHost = CanvasAttachmentHost(host: host, kind: kind)
        super.init(nibName: nil, bundle: nil)
        host.controller = self
        hud.canvas = self
        session.editor = self
        loadModel()
    }

    required init?(coder: NSCoder) { return nil }

    /// No system undo gestures or editing menu on the canvas unless text is being edited: the undo UI (F015) owns the
    /// three-finger gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        session.isEditingText ? .default : .none
    }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.desk
        view.accessibilityIgnoresInvertColors = true
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.host = self
        view.addSubview(scrollView)
        fixedOverlay.frame = view.bounds
        fixedOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(fixedOverlay)

        addPageIndicator.isHidden = true
        scrollView.addSubview(addPageIndicator)
        scrubber.isHidden = true
        scrubber.onScrub = { [weak self] index in self?.scrub(to: index) }
        fixedOverlay.addSubview(scrubber)
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.retryFailedPages() }
        fixedOverlay.addSubview(errorView)

        let tap = host.doubleTapZoomRecognizer
        tap.numberOfTapsRequired = 2
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.delegate = self
        tap.addTarget(self, action: #selector(doubleTapped(_:)))
        scrollView.addGestureRecognizer(tap)

        open()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isClosed { open() }
        if session.editor !== self { session.editor = self }
        if session.document != documentID { session.document = documentID }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            if hadParent { closeCanvas() }
        } else {
            hadParent = true
            if isClosed { open() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0, !isClosed else { return }
        updateChromeInsets()
        if size != lastViewport || !didInitialLayout {
            let anchor = didInitialLayout ? centreAnchor() : nil
            lastViewport = size
            relayout(anchor: anchor, initial: !didInitialLayout)
            didInitialLayout = true
            applyPendingNavigation()
        }
        layoutFixedViews()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateChromeInsets()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            updateChromeInsets()
            view.setNeedsLayout()
        }
    }

    /// Opens (or re-opens) the canvas: observers, tool, attachments, the input half.
    private func open() {
        isClosed = false
        observe()
        host.syncActiveTool()
        attachmentHost.attachAll()
        if host.inputController == nil { CanvasInputHooks.install?(host) }
        applyStylusMode()
        if didInitialLayout { reloadAll() }
    }

    /// Closes the canvas: the input half, attachments and the tool are torn down, waiters run, observers stop. Called
    /// when the editor leaves its container or the document closes; showing it again re-opens it.
    func closeCanvas() {
        guard !isClosed else { return }
        isClosed = true
        host.inputController?.canvasWillClose(host)
        host.inputController = nil
        attachmentHost.detachAll()
        host.deactivateTool()
        host.endInking()
        host.flushAllWaiters()
        commitObservation?.cancel()
        eventObservation?.cancel()
        inkingObservation?.cancel()
        commitObservation = nil
        eventObservation = nil
        inkingObservation = nil
        subscriptions.removeAll()
        for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
        notificationObservers.removeAll()
        loadingTask?.cancel()
        hudLingerTask?.cancel()
        scrollView.recycleAll()
        if session.editor === self { session.editor = nil }
        app.ui.setNeedsChromeUpdate(session)
    }

    // MARK: Observers

    private func observe() {
        commitObservation = app.bus.observeCommits { [weak self] cs in self?.committed(cs) }
        let doc = documentID
        let sessionID = session.id.raw
        eventObservation = app.events.subscribe { [weak self] e in
            if e.type == NibEventType.docClosed, e.doc == doc {
                Task { @MainActor in self?.closeCanvas() }
            } else if e.type == NibEventType.layersChanged, e.payload?["session"]?.stringValue == sessionID {
                // G3: redraw when this window shows or hides a layer.
                Task { @MainActor in self?.layersChanged() }
            }
        }
        inkingObservation = session.inking.observe { [weak self] signal in self?.inkingChanged(signal) }
        // @Published emits before the value changes: read the session on the next turn.
        let main = DispatchQueue.main
        session.$tool.dropFirst().receive(on: main).sink { [weak self] _ in self?.host.syncActiveTool() }
            .store(in: &subscriptions)
        session.$selection.dropFirst().receive(on: main).sink { [weak self] _ in self?.canvasDidChange() }
            .store(in: &subscriptions)
        session.$replay.dropFirst().receive(on: main).sink { [weak self] _ in self?.replayChanged() }
            .store(in: &subscriptions)
        session.$readOnly.dropFirst().receive(on: main).sink { [weak self] _ in self?.readOnlyChanged() }
            .store(in: &subscriptions)
        session.$page.dropFirst().receive(on: main).sink { [weak self] _ in self?.sessionPageChanged() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .compactMap { $0.userInfo?["name"] as? String }
            .filter { $0 == NibSettings.stylusMode.name }
            .receive(on: main)
            .sink { [weak self] _ in self?.applyStylusMode() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: app.ui.canvasTools)
            .map { RegistryChange.ids($0) }
            .receive(on: main)
            .sink { [weak self] ids in
                guard let self = self, ids.contains(self.host.activeToolIdentifier ?? self.session.tool) else { return }
                self.host.syncActiveTool(force: true)
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: main)
            .sink { [weak self] _ in self?.memoryWarning() }
            .store(in: &subscriptions)
    }

    // MARK: Model

    private func loadModel() {
        guard let content = try? app.workspace.content(documentID) else {
            livePages = []
            return
        }
        kind = content.meta.kind
        livePages = content.livePages
        direction = content.meta.scrollDirection
    }

    /// What the canvas shows for `page`: its board when it has no size, else the sized pages.
    private func mode(for page: PageID?) -> CanvasMode {
        let record = page.flatMap { id in livePages.first { $0.id == id } }
        if let r = record, r.size == nil { return .world(r.id) }
        if !livePages.contains(where: { $0.size != nil }), let board = livePages.first(where: { $0.size == nil }) {
            return .world(board.id)
        }
        return .stack(direction)
    }

    /// The page the window should show: the session's when it is one of ours, else the first page.
    private var currentPage: PageID? {
        if let p = session.page, livePages.contains(where: { $0.id == p }) { return p }
        return livePages.first?.id
    }

    var isCompact: Bool {
        traitCollection.horizontalSizeClass == .compact || view.bounds.width < NibMetrics.compactBreakpoint
    }

    // MARK: Layout

    /// Room for the chrome (bars at the top; on iPhone the palette at the bottom, DESIGN.md §14.2) so a page at fit
    /// starts below the bars and its last line scrolls above the palette.
    private func updateChromeInsets() {
        let safe = view.safeAreaInsets
        let top = safe.top + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.m
        let bottom = isCompact ? safe.bottom + NibMetrics.canvasBottomInsetCompact : safe.bottom + NibSpacing.l
        scrollView.chromeInsets = UIEdgeInsets(top: top, left: safe.left, bottom: bottom, right: safe.right)
    }

    /// Lays the pages out for the current mode and window, then zooms and scrolls: to the current page at fit the first
    /// time (`initial`), else keeping `anchor` (a page point) where it was.
    private func relayout(anchor: (page: PageID, point: Point, window: CGPoint)?, initial: Bool) {
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let target = pendingPage ?? currentPage
        let newMode = mode(for: target)
        let modeChanged = newMode != mode
        mode = newMode
        switch newMode {
        case .stack(let dir):
            let pages = livePages.filter { $0.size != nil }
            shown = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let sizes = pages.compactMap { $0.size }
            let widest = sizes.map { $0.width }.max() ?? PageSize.a4.width
            let tallest = sizes.map { $0.height }.max() ?? PageSize.a4.height
            fitZoom = ZoomRules.fit(page: PageSize(widest, tallest), viewport: size, insets: scrollView.chromeInsets,
                                    direction: dir, compact: isCompact)
            zoomLimits = ZoomRules.limits(world: false, fit: fitZoom)
            let slot = dir == .horizontal ? Double(size.width) / fitZoom : 0
            let layout = PageLayout(sizes: sizes, direction: dir, gap: Double(NibSpacing.l), minimumSlot: slot)
            board = nil
            scrollView.apply(mode: newMode, layout: layout, pages: pages.map { $0.id })
        case .world(let id):
            guard let record = livePages.first(where: { $0.id == id }) else { return }
            shown = [id: record]
            if modeChanged { boardContentStale = true }
            if boardContentStale { recomputeBoardContent(id) }
            let margin = BoardWorld.margin(viewport: size, minZoom: ZoomRules.boardRange.lowerBound)
            let world: BoardWorld
            if let existing = board, !modeChanged {
                world = existing.growing(toKeep: boardContent ?? .zero, margin: margin) ?? existing
            } else {
                world = BoardWorld.initial(content: boardContent, margin: margin)
            }
            board = world
            fitZoom = ZoomRules.boardFit(content: boardContent, viewport: size)
            zoomLimits = ZoomRules.boardRange
            let layout = PageLayout(sizes: [PageSize(world.rect.width, world.rect.height)], direction: .vertical, gap: 0)
            scrollView.apply(mode: newMode, layout: layout, pages: [id], worldOrigin: Point(world.rect.x, world.rect.y))
        }
        scrollView.minimumZoomScale = CGFloat(zoomLimits.lowerBound)
        scrollView.maximumZoomScale = CGFloat(zoomLimits.upperBound)
        configureScrolling()
        refreshConfiguredPages()

        if initial || modeChanged || anchor == nil {
            positionAtStart(page: target)
        } else {
            applyZoom(isAtFit ? fitZoom : ZoomRules.clamp(scrollView.zoom, zoomLimits))
            if let a = anchor { keep(a) }
        }
        finishViewChange(bake: true)
        updateHUD()
        updateEmptyState()
    }

    /// Scroll physics for the mode: paging decelerates fast, a column bounces vertically so you can pull for a page.
    private func configureScrolling() {
        switch mode {
        case .stack(.horizontal):
            scrollView.decelerationRate = .fast
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = false
        case .stack:
            scrollView.decelerationRate = .normal
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false
        case .world:
            scrollView.decelerationRate = .normal
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
        }
    }

    /// Fit and the page's start (a board: 100 % or fit, centred on its content).
    private func positionAtStart(page: PageID?) {
        switch mode {
        case .stack:
            applyZoom(fitZoom)
            isAtFit = true
            if let p = page { scrollToPage(p, animated: false) } else { setOffset(minimumOffset) }
        case .world(let id):
            let z = boardContent == nil ? 1 : min(1, fitZoom)
            applyZoom(z)
            isAtFit = abs(z - fitZoom) < 0.001
            centre(on: boardContent?.center ?? .zero, page: id)
        }
    }

    /// Re-configures the page views on screen (their records, paper or page rect may have changed).
    private func refreshConfiguredPages() {
        for (id, v) in scrollView.pageViews {
            if shown[id] != nil { documentScrollView(scrollView, configure: v, for: id) }
        }
    }

    /// Everything that follows a scroll, zoom or layout change.
    private func finishViewChange(bake: Bool) {
        scrollView.updateVisiblePages()
        if bake { scrollView.updateTiles() }
        host.layoutOverlay()
        updateCurrentPage()
        scheduleSessionFlush()
        canvasDidChange()
        updateAddPageIndicator()
        layoutFixedViews()
    }

    private func canvasDidChange() {
        guard !isClosed else { return }
        attachmentHost.canvasDidChange()
        host.inputController?.canvasDidChange(host)
    }

    // MARK: Zoom and offsets

    var zoom: Double { scrollView.zoom }

    private func applyZoom(_ z: Double) {
        let clamped = ZoomRules.clamp(z, zoomLimits)
        if abs(Double(scrollView.zoomScale) - clamped) > 1e-9 { scrollView.setZoomScale(CGFloat(clamped), animated: false) }
        scrollView.zoomDidChange()
        hud.setZoom(ZoomRules.percent(clamped))
    }

    private var minimumOffset: CGPoint {
        let inset = scrollView.adjustedContentInset
        return CGPoint(x: -inset.left, y: -inset.top)
    }

    private func clampedOffset(_ o: CGPoint) -> CGPoint {
        let inset = scrollView.adjustedContentInset
        let size = scrollView.bounds.size
        let minX = -inset.left, minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width + inset.right - size.width)
        let maxY = max(minY, scrollView.contentSize.height + inset.bottom - size.height)
        return CGPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    private func setOffset(_ o: CGPoint, animated: Bool = false) {
        let target = clampedOffset(o)
        let animate = animated && !UIAccessibility.isReduceMotionEnabled
        if animate {
            scrollView.setContentOffset(target, animated: true)
        } else if scrollView.contentOffset != target {
            scrollView.contentOffset = target
        }
    }

    /// The page point under a window point (offset from the scroll view's bounds origin), the nearest page's when the
    /// point is in a gap: what a zoom or relayout keeps in place.
    private func anchor(atWindow w: CGPoint) -> (page: PageID, point: Point, window: CGPoint)? {
        let v = CGPoint(x: scrollView.bounds.minX + w.x, y: scrollView.bounds.minY + w.y)
        let lp = scrollView.layoutPoint(v)
        let layout = scrollView.layout
        let index: Int?
        switch scrollView.mode {
        case .world: index = scrollView.pages.isEmpty ? nil : 0
        case .stack: index = layout.index(atOffset: layout.direction == .vertical ? lp.y : lp.x)
        }
        guard let i = index, i < scrollView.pages.count, let origin = scrollView.layoutOrigin(scrollView.pages[i]) else {
            return nil
        }
        return (scrollView.pages[i], Point(lp.x - origin.x, lp.y - origin.y), w)
    }

    /// The anchor at the middle of the unobscured window.
    private func centreAnchor() -> (page: PageID, point: Point, window: CGPoint)? {
        anchor(atWindow: visibleCentre)
    }

    /// The middle of the part of the window the chrome does not cover (window coordinates of the scroll view).
    private var visibleCentre: CGPoint {
        let b = scrollView.bounds.size
        let i = scrollView.mode.isWorld ? UIEdgeInsets.zero : scrollView.chromeInsets
        return CGPoint(x: i.left + (b.width - i.left - i.right) / 2, y: i.top + (b.height - i.top - i.bottom) / 2)
    }

    /// Scrolls so the anchor's page point is back at its window position.
    private func keep(_ a: (page: PageID, point: Point, window: CGPoint)) {
        let v = host.viewPoint(a.point, page: a.page)
        setOffset(CGPoint(x: v.x - a.window.x, y: v.y - a.window.y))
    }

    /// Zooms to `z` (clamped) keeping `anchor` (a page point) where it is, else the middle of the window. `centreFit`:
    /// a board's fit also centres its content.
    func setZoom(_ z: Double, anchor pageAnchor: (PageID, Point)?, centreFit: Bool) {
        guard isViewLoaded, didInitialLayout else {
            pendingZoom = z
            return
        }
        var keepAnchor = centreAnchor()
        if let pa = pageAnchor, scrollView.index(of: pa.0) != nil {
            let v = host.viewPoint(pa.1, page: pa.0)
            keepAnchor = (pa.0, pa.1, CGPoint(x: v.x - scrollView.bounds.minX, y: v.y - scrollView.bounds.minY))
        }
        applyZoom(z)
        isAtFit = abs(scrollView.zoom - fitZoom) <= fitZoom * 0.001
        if centreFit, case .world(let id) = mode {
            centre(on: boardContent?.center ?? .zero, page: id)
        } else if let a = keepAnchor {
            keep(a)
        }
        endZoom()
    }

    /// Double-tap: fit ↔ twice fit, around the tapped point.
    func toggleZoom(at viewPoint: CGPoint) {
        guard didInitialLayout, !isClosed else { return }
        let target = ZoomRules.toggleTarget(current: scrollView.zoom, fit: fitZoom, limits: zoomLimits)
        let w = CGPoint(x: viewPoint.x - scrollView.bounds.minX, y: viewPoint.y - scrollView.bounds.minY)
        let a = anchor(atWindow: w)
        applyZoom(target)
        isAtFit = abs(scrollView.zoom - fitZoom) <= fitZoom * 0.001
        if let a = a { keep(a) }
        endZoom()
    }

    /// A zoom ended: bake tiles at the new level, grow a board, tell the input half.
    private func endZoom() {
        scrollView.isZoomingNow = false
        finishViewChange(bake: true)
        growBoardIfNeeded()
        flushSessionState()
        host.inputController?.canvasDidEndZooming(host)
    }

    /// Centres the window on `point` of `page` (a board point).
    private func centre(on point: Point, page: PageID) {
        let v = host.viewPoint(point, page: page)
        let c = visibleCentre
        setOffset(CGPoint(x: v.x - c.x, y: v.y - c.y))
    }

    // MARK: Navigation (view.* commands, reveal)

    /// Shows `page`: switches to its board when it is one, else scrolls to its top (a paged window centres it).
    func goToPage(_ page: PageID, animated: Bool) {
        guard livePages.contains(where: { $0.id == page }) else {
            loadModel()
            guard livePages.contains(where: { $0.id == page }) else { return }
            return goToPage(page, animated: animated)
        }
        setSessionPage(page)
        guard isViewLoaded, didInitialLayout, !isClosed else {
            pendingPage = page
            return
        }
        if mode(for: page) != mode {
            relayout(anchor: nil, initial: true)
            return
        }
        scrollToPage(page, animated: animated)
        finishViewChange(bake: true)
        flushSessionState()
    }

    private func scrollToPage(_ page: PageID, animated: Bool) {
        guard let f = scrollView.layoutFrame(page) else { return }
        let rect = scrollView.viewRect(layout: f)
        let bounds = scrollView.bounds
        let insets = scrollView.chromeInsets
        switch mode {
        case .stack(.horizontal):
            let i = scrollView.index(of: page) ?? 0
            let slot = scrollView.layout.slot(i)
            let slotView = scrollView.viewRect(layout: Rect(x: slot.start, y: 0, width: slot.end - slot.start, height: 1))
            let x = rect.width <= bounds.width ? slotView.midX - bounds.width / 2 : rect.minX
            let y = rect.height <= bounds.height - insets.top - insets.bottom ? scrollView.contentOffset.y : rect.minY - insets.top
            setOffset(CGPoint(x: x, y: y), animated: animated)
        case .stack:
            let x = rect.width <= bounds.width ? scrollView.contentOffset.x : max(scrollView.contentOffset.x, rect.minX)
            setOffset(CGPoint(x: x, y: rect.minY - insets.top), animated: animated)
        case .world:
            break
        }
    }

    func reveal(page: PageID, rect: Rect?, animated: Bool) {
        guard let rect = rect else { return goToPage(page, animated: animated) }
        guard livePages.contains(where: { $0.id == page }) else { return }
        setSessionPage(page)
        guard isViewLoaded, didInitialLayout, !isClosed else {
            pendingPage = page
            pendingReveal = (page, rect)
            return
        }
        if mode(for: page) != mode { relayout(anchor: nil, initial: true) }
        guard let t = host.pageTransform(page) else { return }
        let bounds = scrollView.bounds
        let insets = scrollView.mode.isWorld ? UIEdgeInsets.zero : scrollView.chromeInsets
        let margin = NibSpacing.l
        let visible = CGRect(x: bounds.minX + insets.left + margin, y: bounds.minY + insets.top + margin,
                             width: max(1, bounds.width - insets.left - insets.right - 2 * margin),
                             height: max(1, bounds.height - insets.top - insets.bottom - 2 * margin))
        var target = rect.cg.applying(t)
        if target.width > visible.width || target.height > visible.height {
            // Too big for the window: zoom out until it fits (never in).
            let k = min(visible.width / max(target.width, 1), visible.height / max(target.height, 1))
            applyZoom(scrollView.zoom * Double(k))
            isAtFit = abs(scrollView.zoom - fitZoom) <= fitZoom * 0.001
            guard let t2 = host.pageTransform(page) else { return }
            target = rect.cg.applying(t2)
            setOffset(CGPoint(x: target.midX - (insets.left + visible.width / 2 + margin),
                              y: target.midY - (insets.top + visible.height / 2 + margin)), animated: animated)
            endZoom()
            return
        }
        guard !visible.contains(target) else {
            finishViewChange(bake: true)
            return
        }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if target.minX < visible.minX { dx = target.minX - visible.minX } else if target.maxX > visible.maxX { dx = target.maxX - visible.maxX }
        if target.minY < visible.minY { dy = target.minY - visible.minY } else if target.maxY > visible.maxY { dy = target.maxY - visible.maxY }
        // Far away: centre it; close by: the smallest scroll that shows it.
        if abs(dx) > visible.width || abs(dy) > visible.height {
            dx = target.midX - visible.midX
            dy = target.midY - visible.midY
        }
        setOffset(CGPoint(x: scrollView.contentOffset.x + dx, y: scrollView.contentOffset.y + dy), animated: animated)
        finishViewChange(bake: true)
        if !(animated && !UIAccessibility.isReduceMotionEnabled) { growBoardIfNeeded() }
        flushSessionState()
    }

    func reloadAll() {
        loadModel()
        boardContentStale = true
        paperCache.removeAll()
        failedPages.removeAll()
        guard isViewLoaded, didInitialLayout else { return }
        let anchor = centreAnchor()
        scrollView.recycleAll()
        relayout(anchor: anchor, initial: false)
    }

    /// Pans by page points (or fractions of the window). A paged window turns the page for a window-sized step.
    func scrollBy(dx: Double, dy: Double, windowFractions: Bool, animated: Bool) {
        guard isViewLoaded, didInitialLayout else { return }
        if windowFractions, case .stack(.horizontal) = mode, abs(dx) >= 0.5,
           let current = session.page, let i = scrollView.index(of: current) {
            let j = min(max(i + (dx > 0 ? 1 : -1), 0), scrollView.pages.count - 1)
            if j != i { return goToPage(scrollView.pages[j], animated: animated) }
        }
        let z = scrollView.zoom
        let b = scrollView.bounds.size
        let vx = windowFractions ? dx * Double(b.width) : dx * z
        let vy = windowFractions ? dy * Double(b.height) : dy * z
        let o = scrollView.contentOffset
        setOffset(CGPoint(x: Double(o.x) + vx, y: Double(o.y) + vy), animated: animated)
        finishViewChange(bake: true)
        // An animated scroll grows the board when it settles (scrollViewDidEndScrollingAnimation).
        if !(animated && !UIAccessibility.isReduceMotionEnabled) { growBoardIfNeeded() }
        flushSessionState()
    }

    /// Briefly washes `rect` (page coordinates) in the accent: the thing a link, search hit or comment points at.
    func flash(_ rect: Rect, page: PageID) {
        guard isViewLoaded, let t = host.pageTransform(page) else { return }
        let r = rect.cg.applying(t).insetBy(dx: -NibSpacing.xs, dy: -NibSpacing.xs)
        let v = UIView(frame: r)
        v.isUserInteractionEnabled = false
        v.backgroundColor = NibUIColor.accentWash
        v.layer.cornerRadius = NibRadius.pageWash
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = NibStroke.ring
        v.layer.borderColor = NibUIColor.accent.resolvedColor(with: traitCollection).cgColor
        v.isAccessibilityElement = false
        scrollView.addSubview(v)
        Task { @MainActor [weak v] in
            try? await Task.sleep(nanoseconds: UInt64(NibMotion.hudLinger * 1_000_000_000))
            guard let v = v else { return }
            NibMotion.animateUIKit(NibMotion.reduced, animations: { v.alpha = 0 }, completion: { _ in v.removeFromSuperview() })
        }
    }

    /// Navigation asked for before the first layout.
    private func applyPendingNavigation() {
        if let z = pendingZoom {
            pendingZoom = nil
            setZoom(z, anchor: nil, centreFit: false)
        }
        if let r = pendingReveal {
            pendingReveal = nil
            pendingPage = nil
            reveal(page: r.page, rect: r.rect, animated: false)
        } else if let p = pendingPage {
            pendingPage = nil
            goToPage(p, animated: false)
        }
    }

    // MARK: Session state

    private func setSessionPage(_ page: PageID) {
        guard session.page != page else { return }
        settingSessionPage = true
        session.page = page
        settingSessionPage = false
    }

    /// Someone else set `session.page` (a command that bypassed view.goToPage): follow it.
    private func sessionPageChanged() {
        guard !settingSessionPage, !isClosed, let p = session.page, p != displayedPage else { return }
        if livePages.contains(where: { $0.id == p }) { goToPage(p, animated: false) }
    }

    /// The page at the middle of the window.
    private(set) var displayedPage: PageID?

    private func updateCurrentPage() {
        guard let a = centreAnchor() else { return }
        let page = a.page
        guard page != displayedPage else { return }
        displayedPage = page
        setSessionPage(page)
        updateHUD()
        startLoadingWatch()
        host.inputController?.canvasActivePageDidChange(host)
        layoutFixedViews()
    }

    private func scheduleSessionFlush() {
        guard !sessionFlushScheduled else { return }
        sessionFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: CanvasViewController.sessionPublishInterval)
            self?.flushSessionState()
        }
    }

    /// Publishes zoom and the visible part of the current page (page coordinates) to the session.
    func flushSessionState() {
        sessionFlushScheduled = false
        guard !isClosed, didInitialLayout else { return }
        let z = scrollView.zoom
        if abs(session.zoom - z) > 1e-6 { session.zoom = z }
        var visible: Rect?
        if let page = displayedPage ?? currentPage, let f = scrollView.layoutFrame(page),
           let origin = scrollView.layoutOrigin(page) {
            let b = scrollView.bounds
            let i = scrollView.mode.isWorld ? UIEdgeInsets.zero : scrollView.chromeInsets
            let window = CGRect(x: b.minX + i.left, y: b.minY + i.top, width: max(0, b.width - i.left - i.right),
                                height: max(0, b.height - i.top - i.bottom))
            let a = scrollView.layoutPoint(window.origin), c = scrollView.layoutPoint(CGPoint(x: window.maxX, y: window.maxY))
            var r = Rect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
            if !scrollView.mode.isWorld {
                let x0 = max(r.minX, f.minX), y0 = max(r.minY, f.minY), x1 = min(r.maxX, f.maxX), y1 = min(r.maxY, f.maxY)
                r = Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
            }
            visible = Rect(x: r.x - origin.x, y: r.y - origin.y, width: r.width, height: r.height)
        }
        if session.visibleRect != visible { session.visibleRect = visible }
    }

    // MARK: Commits

    private func committed(_ cs: Changeset) {
        guard !isClosed, cs.documents.contains(documentID) else { return }
        if cs.headChanged(documentID) {
            let oldPages = livePages
            let oldDirection = direction
            let anchor = centreAnchor()
            loadModel()
            let geometry = livePages.map { $0.id } != oldPages.map { $0.id } || livePages.map { $0.size } != oldPages.map { $0.size }
                || direction != oldDirection
            if geometry || !livePages.contains(where: { $0.id == session.page }) {
                if let p = session.page, !livePages.contains(where: { $0.id == p }), !livePages.isEmpty {
                    // The current page went away: show its neighbour.
                    let old = oldPages.firstIndex { $0.id == p } ?? 0
                    setSessionPage(livePages[min(old, livePages.count - 1)].id)
                }
                if isViewLoaded && didInitialLayout {
                    let switched = mode(for: currentPage) != mode
                    relayout(anchor: switched ? nil : anchor, initial: switched)
                }
            } else {
                for r in livePages { if shown[r.id] != nil { shown[r.id] = r } }
                refreshConfiguredPages()
                updateHUD()
            }
        }
        for (page, dirty) in CanvasViewController.dirtyRects(cs, doc: documentID, content: app.content) {
            app.services.renderer?.invalidate(doc: documentID, page: page, rect: dirty)
            scrollView.pageViews[page]?.invalidate(dirty)
            scrollView.pageViews[page]?.invalidateAccessibility()
            host.placeLiveViews(on: page)
            if case .world(let id) = mode, id == page, !boardContentStale {
                boardContent = boardContent.map { $0.union(dirty) } ?? dirty
            }
            host.flushWaitersIfReady(page)
        }
        canvasDidChange()
    }

    /// Per page, the union of what every changed item painted before and after (`ContentRegistries.paintBounds`).
    static func dirtyRects(_ cs: Changeset, doc: DocumentID, content: ContentRegistries) -> [PageID: Rect] {
        var out: [PageID: Rect] = [:]
        for m in cs.mutations {
            guard case let .item(d, p, before, after) = m, d == doc else { continue }
            var r = content.paintBounds(for: after)
            if let b = before { r = r.union(content.paintBounds(for: b)) }
            out[p] = out[p].map { $0.union(r) } ?? r
        }
        return out
    }

    private func refreshAllTiles() {
        for v in scrollView.pageViews.values { v.invalidate(nil) }
    }

    private var lastVisibleLayers: Set<Int>?

    /// A layer was shown or hidden in this window (the active layer changing needs no redraw).
    private func layersChanged() {
        let visible = host.visibleLayers
        guard visible != (lastVisibleLayers ?? Set(0..<NibLimits.layerCount)) else { return }
        lastVisibleLayers = visible
        refreshAllTiles()
        for v in scrollView.pageViews.values { v.invalidateAccessibility() }
    }

    /// Note Replay moves `session.replay` many times a second: the tiles are redrawn for the latest time whenever the
    /// previous redraw has landed, never more than one at a time.
    private func replayChanged() {
        replayDirty = true
        refreshForReplayIfIdle()
    }

    private func refreshForReplayIfIdle() {
        guard replayDirty, scrollView.pageViews.values.allSatisfy({ $0.isSettled }) else { return }
        replayDirty = false
        refreshAllTiles()
    }

    private func readOnlyChanged() {
        applyStylusMode()
        host.inputController?.canvasReadOnlyDidChange(host)
        updateAddPageIndicator()
    }

    private func memoryWarning() {
        for v in scrollView.pageViews.values { v.trim() }
        paperCache.removeAll()
    }

    // MARK: Boards

    /// The union of the board's item bounds (painted area).
    private func recomputeBoardContent(_ page: PageID) {
        boardContentStale = false
        guard let items = try? app.workspace.items(documentID, page: page), !items.isEmpty else {
            boardContent = nil
            return
        }
        var r: Rect?
        for item in items {
            let b = app.content.paintBounds(for: item)
            guard !b.isEmpty, [b.x, b.y, b.width, b.height].allSatisfy({ $0.isFinite }) else { continue }
            r = r.map { $0.union(b) } ?? b
        }
        boardContent = r
    }

    /// The board's content bounds, recomputed if needed (fit).
    func currentBoardContent() -> Rect? {
        if case .world(let id) = mode, boardContentStale { recomputeBoardContent(id) }
        return boardContent
    }

    /// Fit for `view.zoom {fit}`: the page width, or all of a board's content as it is now.
    func currentFitZoom() -> Double {
        if mode.isWorld { fitZoom = ZoomRules.boardFit(content: currentBoardContent(), viewport: scrollView.bounds.size) }
        return fitZoom
    }

    /// Grows the board world when the window nears its edge, keeping everything where it is on screen.
    private func growBoardIfNeeded() {
        guard case .world(let id) = mode, let world = board, !scrollView.isDragging, !scrollView.isDecelerating,
              !scrollView.isZoomingNow else { return }
        let margin = BoardWorld.margin(viewport: scrollView.bounds.size, minZoom: ZoomRules.boardRange.lowerBound)
        let visible = scrollView.visibleLayoutRect
        let visibleWorld = Rect(x: visible.x + world.rect.x, y: visible.y + world.rect.y, width: visible.width,
                                height: visible.height)
        guard let grown = world.growing(toKeep: visibleWorld, margin: margin) else { return }
        let z = scrollView.zoom
        let dx = (world.rect.x - grown.rect.x) * z, dy = (world.rect.y - grown.rect.y) * z
        let offset = scrollView.contentOffset
        board = grown
        let layout = PageLayout(sizes: [PageSize(grown.rect.width, grown.rect.height)], direction: .vertical, gap: 0)
        scrollView.apply(mode: mode, layout: layout, pages: [id], worldOrigin: Point(grown.rect.x, grown.rect.y))
        refreshConfiguredPages()
        scrollView.contentOffset = CGPoint(x: Double(offset.x) + dx, y: Double(offset.y) + dy)
        finishViewChange(bake: true)
    }

    // MARK: Scroll view delegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { self.scrollView.contentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard didInitialLayout, !isClosed else { return }
        self.scrollView.updateVisiblePages()
        if !self.scrollView.isZooming && !self.scrollView.isZoomingNow { self.scrollView.updateTiles() }
        updateCurrentPage()
        scheduleSessionFlush()
        canvasDidChange()
        updateAddPageIndicator()
        layoutFixedViews()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartIndex = displayedPage.flatMap { self.scrollView.index(of: $0) } ?? 0
        hud.setScrolling(true, compact: isCompact)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if addPageArmed {
            addPageArmed = false
            addPage()
        }
        guard case .stack(.horizontal) = mode, !self.scrollView.layout.isEmpty else { return }
        let layout = self.scrollView.layout
        let frames = layout.frames.map { f -> (min: Double, max: Double) in
            let r = self.scrollView.viewRect(layout: f)
            return (Double(r.minX), Double(r.maxX))
        }
        let slots = (0..<layout.count).map { i -> (min: Double, max: Double) in
            let s = layout.slot(i)
            let r = self.scrollView.viewRect(layout: Rect(x: s.start, y: 0, width: s.end - s.start, height: 1))
            return (Double(r.minX), Double(r.maxX))
        }
        let inset = scrollView.adjustedContentInset
        let maxX = max(-inset.left, scrollView.contentSize.width + inset.right - scrollView.bounds.width)
        let x = PagingSnap.target(proposed: Double(targetContentOffset.pointee.x), velocity: Double(velocity.x),
                                  current: dragStartIndex, viewport: Double(scrollView.bounds.width), frames: frames,
                                  slots: slots, offsetRange: Double(-inset.left)...Double(maxX))
        targetContentOffset.pointee.x = CGFloat(x)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollDidSettle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollDidSettle() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scrollDidSettle() }

    private func scrollDidSettle() {
        hud.setScrolling(false, compact: isCompact)
        // A board lists the items near the window for VoiceOver: the window moved.
        if mode.isWorld { for v in scrollView.pageViews.values { v.invalidateAccessibility() } }
        growBoardIfNeeded()
        flushSessionState()
        updateAddPageIndicator()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        self.scrollView.isZoomingNow = true
        hudLingerTask?.cancel()
        hud.setPinching(true)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard didInitialLayout, !isClosed else { return }
        self.scrollView.zoomDidChange()
        host.layoutOverlay()
        hud.setZoom(ZoomRules.percent(self.scrollView.zoom))
        self.scrollView.updateVisiblePages()
        canvasDidChange()
        layoutFixedViews()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isAtFit = abs(self.scrollView.zoom - fitZoom) <= fitZoom * 0.005
        endZoom()
        hudLingerTask?.cancel()
        hudLingerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NibMotion.hudLinger * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hud.setPinching(false)
        }
    }

    // MARK: Page views

    func documentScrollView(_ view: DocumentScrollView, configure pageView: PageTileView, for page: PageID) {
        guard let record = shown[page] else { return }
        let rect: Rect
        if record.size == nil, let world = board {
            rect = world.rect
        } else {
            let s = record.size ?? PageSize.a4
            rect = Rect(x: 0, y: 0, width: s.width, height: s.height)
        }
        pageView.source = host
        pageView.configure(record, pageRect: rect, paper: paperColor(record))
        pageView.accessibilityProvider = { [weak self] v in self?.accessibilityElements(for: v) ?? [] }
        host.placeLiveViews(on: page)
    }

    func documentScrollView(_ view: DocumentScrollView, didRecycle pageView: PageTileView, for page: PageID) {
        host.flushWaitersIfReady(page)
    }

    func documentScrollViewScrollPage(_ view: DocumentScrollView, forward: Bool) -> Bool {
        guard let current = displayedPage ?? currentPage, let i = scrollView.index(of: current) else { return false }
        let j = i + (forward ? 1 : -1)
        guard j >= 0, j < scrollView.pages.count else { return false }
        goToPage(scrollView.pages[j], animated: false)
        UIAccessibility.post(notification: .pageScrolled, argument: hud.accessibilityLabel)
        return true
    }

    private func accessibilityName(_ record: PageRecord) -> String {
        if record.size == nil {
            return record.title ?? String(localized: "Board")
        }
        let index = (livePages.firstIndex { $0.id == record.id } ?? 0) + 1
        return String(localized: "Page \(index) of \(livePages.count)")
    }

    /// VoiceOver elements of a page (contract-gaps F037): the page itself (with Add Page), then its comment pins,
    /// links, typed text, maths and images in z-order, each at its hit area. Activating a pin opens its thread
    /// (`comment.tapAt`); a link is followed (`link.follow`). A board lists the items near the window.
    private func accessibilityElements(for pageView: PageTileView) -> [Any] {
        guard let id = pageView.pageID, let record = shown[id] else { return [] }
        let summary = UIAccessibilityElement(accessibilityContainer: pageView)
        summary.accessibilityLabel = accessibilityName(record)
        summary.accessibilityFrameInContainerSpace = record.size == nil ? visiblePageArea(id).cg : pageView.bounds
        summary.accessibilityCustomActions = pageActions()
        var out: [Any] = [summary]
        guard let items = try? app.workspace.items(documentID, page: id) else { return out }
        let layers = host.visibleLayers
        let area: Rect? = record.size == nil ? visiblePageArea(id).insetBy(-200) : nil
        for item in items where layers.contains(item.layer) {
            let hit = app.content.hitBounds(for: item)
            if let a = area, !hit.intersects(a) { continue }
            out += CanvasAccessibility.elements(for: item, frame: hit, page: id, container: pageView, canvas: self)
            if out.count > CanvasAccessibility.maxElements { break }
        }
        return out
    }

    /// The part of `page` the window shows (page coordinates).
    private func visiblePageArea(_ page: PageID) -> Rect {
        guard let origin = scrollView.layoutOrigin(page) else { return .zero }
        let v = scrollView.visibleLayoutRect
        return Rect(x: v.x - origin.x, y: v.y - origin.y, width: v.width, height: v.height)
    }

    private func pageActions() -> [UIAccessibilityCustomAction] {
        guard canAddPage else { return [] }
        return [UIAccessibilityCustomAction(name: String(localized: "Add Page")) { [weak self] _ in
            self?.addPage()
            return true
        }]
    }

    /// The paper colour behind a page's tiles (paper is never inverted in dark mode).
    private func paperColor(_ record: PageRecord) -> UIColor {
        let background = record.background
        switch background.kind {
        case .color:
            return (background.color ?? RGBA.white).uiColor
        case .pdf, .image:
            return RGBA.white.uiColor
        case .template:
            guard let ref = background.template, let definition = app.content.template(ref) else { return RGBA.white.uiColor }
            let key = ref.id + JSONValue.object(ref.params).jsonString()
            if let c = paperCache[key] { return c }
            let params = definition.defaults.merging(ref.params) { $1 }
            let size = record.size ?? PageSize(CanvasTileGrid.side(level: 0), CanvasTileGrid.side(level: 0))
            let render = definition.renderOps(params, size: size, scale: 1, region: Rect(x: 0, y: 0, width: 1, height: 1))
            let c = render.paper.uiColor
            paperCache[key] = c
            return c
        }
    }

    func pageDidSettle(_ page: PageID) {
        if page == displayedPage { hud.setLoading(false) }
        refreshForReplayIfIdle()
    }

    func pageDidFail(_ page: PageID) {
        failedPages.insert(page)
        layoutFixedViews()
    }

    private func retryFailedPages() {
        let pages = failedPages
        failedPages.removeAll()
        for p in pages { scrollView.pageViews[p]?.retry() }
        layoutFixedViews()
    }

    /// Shows the loading indicator in the page HUD when the page is still loading after 400 ms.
    private func startLoadingWatch() {
        loadingTask?.cancel()
        hud.setLoading(false)
        guard let page = displayedPage else { return }
        loadingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: CanvasViewController.loadingIndicatorDelay)
            guard let self = self, !Task.isCancelled, self.displayedPage == page else { return }
            if let v = self.scrollView.pageViews[page], !v.isSettled { self.hud.setLoading(true) }
        }
    }

    // MARK: Input

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        toggleZoom(at: g.location(in: scrollView))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === host.doubleTapZoomRecognizer else { return true }
        // Only taps on the paper or the desk: a control or an attachment that claims the touch keeps it.
        let v = touch.view
        guard v === scrollView || v === scrollView.contentView || v is PageTileView else { return false }
        let p = touch.location(in: scrollView)
        return !host.attachments.contains { $0.hitTest(p, isPencil: touch.type == .pencil, host: host) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === host.doubleTapZoomRecognizer && other === scrollView.panGestureRecognizer
    }

    /// Fingers scroll unless they draw ("Disconnect Apple Pencil", NibSettings.stylusMode = anyInput, with the input
    /// half installed): then panning takes two fingers. Read-only mode always scrolls with one.
    private func applyStylusMode() {
        let fingersDraw = app.settings.get(NibSettings.stylusMode) == .anyInput && host.inputController != nil
            && !host.isReadOnly
        scrollView.panGestureRecognizer.minimumNumberOfTouches = fingersDraw ? 2 : 1
    }

    private func inkingChanged(_ signal: InkingSignal) {
        scrubber.recede(signal.isInking)
    }

    // MARK: Add page by pulling past the end (D-053)

    private var canAddPage: Bool {
        kind == .notebook && !host.isReadOnly && app.commands.entry("page.add") != nil
    }

    private func updateAddPageIndicator() {
        guard didInitialLayout, canAddPage, case .stack(let dir) = mode, !scrollView.layout.isEmpty else {
            addPageIndicator.isHidden = true
            addPageArmed = false
            return
        }
        let inset = scrollView.adjustedContentInset
        let b = scrollView.bounds
        let content = scrollView.contentSize
        let over: CGFloat
        if dir == .vertical {
            over = b.maxY - (content.height + inset.bottom)
        } else {
            over = b.maxX - (content.width + inset.right)
        }
        guard over > 1, scrollView.isDragging || scrollView.isDecelerating else {
            addPageIndicator.isHidden = true
            addPageArmed = false
            return
        }
        let armed = over >= CanvasViewController.addPageThreshold && scrollView.isDragging
        addPageArmed = armed
        addPageIndicator.set(armed: armed)
        let size = addPageIndicator.fittingSize
        let origin: CGPoint
        if dir == .vertical {
            origin = CGPoint(x: b.midX - size.width / 2, y: content.height + inset.bottom + (over - size.height) / 2)
        } else {
            origin = CGPoint(x: content.width + inset.right + (over - size.width) / 2, y: b.midY - size.height / 2)
        }
        addPageIndicator.frame = CGRect(origin: origin, size: size)
        addPageIndicator.isHidden = false
    }

    private func addPage() {
        guard canAddPage else { return }
        app.perform("page.add", ["doc": .string(NodeRef.document(documentID).description), "position": "end"],
                    session: session)
    }

    // MARK: Fixed views: scrubber, error, empty state

    private func layoutFixedViews() {
        guard isViewLoaded else { return }
        let b = fixedOverlay.bounds
        let insets = scrollView.chromeInsets
        // Horizontal paging: a scrubber along the right edge (D-118); a vertical column uses the system's draggable
        // scroll indicator for the same thing.
        if case .stack(.horizontal) = mode, kind == .notebook, scrollView.pages.count > 1 {
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
            let w = NibMetrics.hitTarget
            scrubber.frame = CGRect(x: b.maxX - insets.right - w, y: insets.top, width: w,
                                    height: max(w, b.height - insets.top - insets.bottom))
            scrubber.update(count: scrollView.pages.count,
                            index: displayedPage.flatMap { scrollView.index(of: $0) } ?? 0)
            scrubber.isHidden = false
        } else {
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = true
            scrubber.isHidden = true
        }
        if let page = displayedPage, failedPages.contains(page), let f = host.pageFrame(page) {
            let visible = scrollView.convert(f, to: fixedOverlay).intersection(b)
            let size = errorView.systemLayoutSizeFitting(CGSize(width: min(b.width - 2 * NibSpacing.l, 360), height: 0),
                                                          withHorizontalFittingPriority: .required,
                                                          verticalFittingPriority: .fittingSizeLevel)
            let centre = visible.isNull ? CGPoint(x: b.midX, y: b.midY) : CGPoint(x: visible.midX, y: visible.midY)
            errorView.frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width,
                                     height: size.height)
            errorView.isHidden = false
        } else {
            errorView.isHidden = true
        }
    }

    private func scrub(to index: Int) {
        guard index >= 0, index < scrollView.pages.count else { return }
        let page = scrollView.pages[index]
        guard page != displayedPage else { return }
        app.perform("view.goToPage", ["page": .string(NodeRef.page(documentID, page).description)], session: session)
    }

    /// A notebook without pages: say so and offer a page.
    private func updateEmptyState() {
        let empty = kind == .notebook && livePages.filter({ $0.size != nil }).isEmpty && !mode.isWorld
        if empty, emptyHost == nil {
            var add: NibAction?
            if canAddPage { add = NibAction(String(localized: "Add Page"), handler: { [weak self] in self?.addPage() }) }
            let state = NibEmptyState(symbol: .addPage, title: String(localized: "No pages"),
                                      message: String(localized: "This notebook has no pages yet."), primary: add)
            let hosting = UIHostingController(rootView: state)
            hosting.view.backgroundColor = .clear
            addChild(hosting)
            hosting.view.frame = view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(hosting.view, belowSubview: fixedOverlay)
            hosting.didMove(toParent: self)
            emptyHost = hosting
        } else if !empty, let hosting = emptyHost {
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
            emptyHost = nil
        }
    }

    // MARK: HUD

    private func updateHUD() {
        let pages = livePages.filter { $0.size != nil }
        let index = displayedPage.flatMap { p in pages.firstIndex { $0.id == p } }
        hud.update(index: index, count: pages.count, isBoard: mode.isWorld, zoomPercent: ZoomRules.percent(scrollView.zoom))
    }
}

// MARK: - HUD model

/// What the page HUD and the pinch-zoom HUD show for one canvas (chrome overlays, `FeatCanvasFeature`). Changes that
/// alter whether a HUD shows ask the chrome to re-evaluate (`UIRegistries.setNeedsChromeUpdate`).
@MainActor
final class CanvasHUDModel: ObservableObject {
    weak var canvas: CanvasViewController?
    /// 0-based index of the page at the middle of the window.
    @Published private(set) var pageIndex: Int?
    @Published private(set) var pageCount = 0
    @Published private(set) var zoomPercent = 100
    @Published private(set) var isLoading = false
    @Published private(set) var isPinching = false
    private(set) var isScrolling = false
    private(set) var isBoard = false
    private var isCompact = false

    func update(index: Int?, count: Int, isBoard: Bool, zoomPercent: Int) {
        let visibilityChanged = (pageCount == 0) != (count == 0) || self.isBoard != isBoard
        if pageIndex != index { pageIndex = index }
        if pageCount != count { pageCount = count }
        self.isBoard = isBoard
        setZoom(zoomPercent)
        if visibilityChanged { chromeNeedsUpdate() }
    }

    func setZoom(_ percent: Int) {
        if zoomPercent != percent { zoomPercent = percent }
    }

    func setLoading(_ on: Bool) {
        if isLoading != on { isLoading = on }
    }

    func setPinching(_ on: Bool) {
        guard isPinching != on else { return }
        isPinching = on
        chromeNeedsUpdate()
    }

    /// On iPhone the page HUD hides while scrolling (DESIGN.md §14.2).
    func setScrolling(_ on: Bool, compact: Bool) {
        isCompact = compact
        guard isScrolling != on else { return }
        isScrolling = on
        if compact { chromeNeedsUpdate() }
    }

    var showsPageHUD: Bool { !isBoard && pageCount > 0 && !(isCompact && isScrolling) }
    var showsZoomHUD: Bool { isPinching }

    var primaryText: String { ((pageIndex ?? 0) + 1).formatted() }
    var secondaryText: String { "/ " + pageCount.formatted() }
    var zoomText: String { (Double(zoomPercent) / 100).formatted(.percent.precision(.fractionLength(0))) }

    var accessibilityLabel: String {
        String(localized: "Page \((pageIndex ?? 0) + 1) of \(pageCount)")
    }

    var canShowNavigator: Bool { canvas?.app.commands.entry("sidebar.toggle") != nil }

    func showNavigator() {
        guard let c = canvas, canShowNavigator else { return }
        c.app.perform("sidebar.toggle", [:], session: c.session)
    }

    /// Goes to page `index` (0-based) through `view.goToPage`, so the HUD does what plugins and the AI can do.
    func go(to index: Int) {
        guard let c = canvas, pageCount > 0 else { return }
        let i = min(max(index, 0), pageCount - 1)
        guard i != pageIndex else { return }
        c.app.perform("view.goToPage", ["index": .number(Double(i)), "doc": .string(NodeRef.document(c.documentID).description)],
                      session: c.session)
    }

    func step(forward: Bool) { go(to: (pageIndex ?? 0) + (forward ? 1 : -1)) }

    private func chromeNeedsUpdate() {
        guard let c = canvas else { return }
        c.app.ui.setNeedsChromeUpdate(c.session)
    }
}

// MARK: - HUD views (chrome overlays)

/// The page HUD (DESIGN.md §14.2, D-125): the page navigator button and "3 / 12", bottom-right, clear of the palette.
/// Tap the glyph for the page navigator; drag along it to scrub pages. The chrome gives it its Clear droplet.
struct CanvasPageHUD: View {
    @ObservedObject var model: CanvasHUDModel
    @State private var scrubStart: Int?
    /// Points of drag per page when scrubbing along the HUD.
    private static let scrubStep: CGFloat = 24

    var body: some View {
        HStack(spacing: NibSpacing.xxs) {
            if model.canShowNavigator {
                NibIconButton(.pages, label: String(localized: "Show Pages"), size: .bar) { model.showNavigator() }
            }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            NibHUDText(model.primaryText, secondary: model.secondaryText)
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    let start = scrubStart ?? (model.pageIndex ?? 0)
                    if scrubStart == nil { scrubStart = start }
                    let delta = Int((value.translation.width / CanvasPageHUD.scrubStep).rounded(.towardZero))
                    model.go(to: start + delta)
                }
                .onEnded { _ in scrubStart = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(String(localized: "Swipe up or down to change page."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.step(forward: true)
            case .decrement: model.step(forward: false)
            @unknown default: break
            }
        }
        .accessibilityActions {
            if model.canShowNavigator {
                Button(String(localized: "Show Pages")) { model.showNavigator() }
            }
        }
    }
}

/// The pinch-zoom HUD (DESIGN.md §9.2, §14.17): the zoom percentage at top centre during a pinch, lingering 0.6 s.
struct CanvasZoomHUD: View {
    @ObservedObject var model: CanvasHUDModel

    var body: some View {
        NibHUDText(model.zoomText)
            .padding(.horizontal, NibSpacing.xs)
            .frame(height: NibMetrics.hudHeight)
            .nibChromeTypeCap()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Zoom"))
            .accessibilityValue(model.zoomText)
    }
}

// MARK: - Page scrubber (D-118)

/// Horizontal paging's page scrubber: a thin thumb on the right edge, like the system's draggable scroll indicator,
/// that jumps between pages as you drag it (through `view.goToPage`). Adjustable for VoiceOver. It steps back while
/// the Pencil is down.
final class PageScrubberView: UIView, UIPointerInteractionDelegate {
    var onScrub: ((Int) -> Void)?
    private let thumb = UIView()
    private(set) var count = 0
    private(set) var index = 0
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        thumb.backgroundColor = NibUIColor.labelTertiary
        thumb.layer.cornerCurve = .continuous
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = String(localized: "Page scrubber")
    }

    required init?(coder: NSCoder) { return nil }

    func update(count: Int, index: Int) {
        guard count != self.count || index != self.index else { return }
        self.count = count
        if !dragging { self.index = index }
        accessibilityValue = String(localized: "Page \(self.index + 1) of \(count)")
        setNeedsLayout()
    }

    private var track: CGRect { bounds.insetBy(dx: 0, dy: NibSpacing.s) }

    private var thumbHeight: CGFloat {
        max(NibMetrics.hitTarget, track.height / CGFloat(max(count, 1)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = track
        let h = min(thumbHeight, t.height)
        let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
        let w = NibSpacing.xs + NibSpacing.xxs
        thumb.frame = CGRect(x: bounds.maxX - w - NibSpacing.xs, y: t.minY + (t.height - h) * fraction, width: w, height: h)
        thumb.layer.cornerRadius = NibRadius.capsule(w)
    }

    private func index(at y: CGFloat) -> Int {
        let t = track
        let h = min(thumbHeight, t.height)
        let usable = max(1, t.height - h)
        let fraction = min(max((y - t.minY - h / 2) / usable, 0), 1)
        return Int((fraction * CGFloat(max(count - 1, 0))).rounded())
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            dragging = true
            move(to: index(at: g.location(in: self).y))
        default:
            dragging = false
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        move(to: index(at: g.location(in: self).y))
    }

    private func move(to i: Int) {
        guard count > 0, i != index else { return }
        index = i
        setNeedsLayout()
        onScrub?(i)
    }

    override func accessibilityIncrement() { move(to: min(index + 1, count - 1)) }
    override func accessibilityDecrement() { move(to: max(index - 1, 0)) }

    /// Steps back to the recede opacity while the Pencil is down (DESIGN.md §10.8); back after the recede delay.
    func recede(_ inking: Bool) {
        restore?.cancel()
        restore = nil
        if inking {
            alpha = CGFloat(NibOpacity.recede)
        } else if alpha < 1 {
            restore = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(NibMotion.recedeDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.alpha = 1
            }
        }
    }

    private var restore: Task<Void, Never>?

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: thumb)
        return UIPointerStyle(effect: .highlight(preview))
    }
}

// MARK: - Pull to add a page (D-053)

/// Shown in the space you pull open past the last page: "Pull to add a page", then "Release to add a page".
final class AddPageIndicatorView: UIView {
    private let icon = UIImageView()
    private let label = UILabel()
    private(set) var armed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        icon.image = UIImage(nib: .addPage)
        icon.preferredSymbolConfiguration = NibUIFont.glyph(.panel)
        icon.tintColor = NibUIColor.labelSecondary
        icon.contentMode = .center
        label.font = NibUIFont.footnoteEmphasis
        label.adjustsFontForContentSizeCategory = true
        label.textColor = NibUIColor.labelSecondary
        label.textAlignment = .center
        addSubview(icon)
        addSubview(label)
        set(armed: false)
    }

    required init?(coder: NSCoder) { return nil }

    func set(armed: Bool) {
        guard armed != self.armed || label.text == nil else { return }
        self.armed = armed
        label.text = armed ? String(localized: "Release to add a page") : String(localized: "Pull to add a page")
        icon.tintColor = armed ? NibUIColor.accent : NibUIColor.labelSecondary
        setNeedsLayout()
    }

    var fittingSize: CGSize {
        let text = label.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: max(text.width, NibMetrics.hitTarget), height: NibMetrics.hitTarget + NibSpacing.xs + text.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 0, y: 0, width: bounds.width, height: NibMetrics.hitTarget)
        label.frame = CGRect(x: 0, y: NibMetrics.hitTarget + NibSpacing.xs, width: bounds.width,
                             height: max(0, bounds.height - NibMetrics.hitTarget - NibSpacing.xs))
    }
}

// MARK: - Render failure (DESIGN.md §14.18)

/// "Couldn't show this page." with Try Again, over a page whose render failed.
final class PageErrorView: UIView {
    var onRetry: (() -> Void)?
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let icon = UIImageView(image: UIImage(nib: .warningTriangle))
        icon.preferredSymbolConfiguration = NibUIFont.glyph(.sidebar)
        icon.tintColor = NibUIColor.labelSecondary
        icon.contentMode = .center
        icon.isAccessibilityElement = false
        let label = UILabel()
        label.text = String(localized: "Couldn't show this page.")
        label.font = NibUIFont.callout
        label.adjustsFontForContentSizeCategory = true
        label.textColor = NibUIColor.label
        label.numberOfLines = 0
        label.textAlignment = .center
        let button = UIButton(type: .system)
        button.setTitle(String(localized: "Try Again"), for: .normal)
        button.titleLabel?.font = NibUIFont.button
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.tintColor = NibUIColor.accent
        button.addTarget(self, action: #selector(retry), for: .primaryActionTriggered)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: NibMetrics.hitTarget).isActive = true
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = NibSpacing.s
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: NibSpacing.l),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -NibSpacing.l),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: NibSpacing.l),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -NibSpacing.l),
        ])
        shouldGroupAccessibilityChildren = true
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func retry() { onRetry?() }
}

// MARK: - Item accessibility

/// A VoiceOver element for something on a page, positioned in the page view's (page point) coordinates, so it follows
/// scrolling and zoom. Activating it runs the same command a finger would.
final class CanvasItemElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let action = onActivate else { return false }
        action()
        return true
    }
}

/// Builds the per-item VoiceOver elements of a page.
@MainActor
enum CanvasAccessibility {
    /// A page with more than this many readable items lists the first ones (VoiceOver reads the page summary first).
    static let maxElements = 400
    static let maxTextLength = 400

    static func elements(for item: Item, frame: Rect, page: PageID, container: UIView,
                         canvas: CanvasViewController) -> [Any] {
        let app = canvas.app
        let doc = canvas.documentID
        func element(_ label: String, value: String? = nil, traits: UIAccessibilityTraits = .staticText,
                     hint: String? = nil, activate: (() -> Void)? = nil) -> CanvasItemElement {
            let e = CanvasItemElement(accessibilityContainer: container)
            e.accessibilityLabel = label
            e.accessibilityValue = value
            e.accessibilityTraits = traits
            e.accessibilityHint = hint
            e.accessibilityFrameInContainerSpace = frame.cg
            e.onActivate = activate
            return e
        }
        switch item.kind {
        case .comment:
            guard let c = item.comment else { return [] }
            let open: (() -> Void)? = app.commands.entry("comment.tapAt") == nil ? nil : {
                app.perform("comment.tapAt", ["page": .string(NodeRef.page(doc, page).description),
                                              "point": [.number(c.anchor.x), .number(c.anchor.y)]], session: canvas.session)
            }
            let first = c.messages.first.map { clipped($0.author.isEmpty ? $0.text : $0.author + ": " + $0.text) }
            return [element(c.resolved ? String(localized: "Resolved comment") : String(localized: "Comment"),
                            value: first, traits: .button,
                            hint: open == nil ? nil : String(localized: "Opens the comment thread."), activate: open)]
        case .text, .sticky:
            guard let text = item.kind == .text ? item.text?.text : item.sticky?.text else { return [] }
            var out: [Any] = []
            let plain = text.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                out.append(element(item.kind == .sticky ? String(localized: "Sticky note") : String(localized: "Text"),
                                   value: clipped(plain)))
            }
            for (label, link) in links(in: text) {
                guard let params = followParams(link), app.commands.entry("link.follow") != nil else { continue }
                out.append(element(clipped(label), traits: .link, activate: {
                    app.perform("link.follow", params, session: canvas.session)
                }))
            }
            return out
        case .math:
            guard let m = item.math, !m.latex.isEmpty else { return [] }
            return [element(String(localized: "Maths"), value: clipped(m.latex.joined(separator: ", ")))]
        case .image:
            return [element(String(localized: "Image"), traits: .image)]
        default:
            return []
        }
    }

    /// Runs of text that carry the same link, with their text.
    static func links(in text: RichText) -> [(String, TextLink)] {
        var out: [(String, TextLink)] = []
        for paragraph in text.paragraphs {
            for run in paragraph.runs {
                guard let link = run.attrs.link else { continue }
                if let last = out.last, last.1 == link {
                    out[out.count - 1].0 += run.text
                } else {
                    out.append((run.text, link))
                }
            }
        }
        return out.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `link.follow` params for a link: a URL, a page of a document, or an audio time.
    static func followParams(_ link: TextLink) -> JSONValue? {
        if let url = link.url, !url.isEmpty { return ["url": .string(url)] }
        guard let doc = link.document else { return nil }
        if let clip = link.audioClip {
            return ["clip": .string(NodeRef.audio(doc, clip).description), "t": .number(link.audioTime ?? 0)]
        }
        var o: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
        if let page = link.page { o["page"] = .string(NodeRef.page(doc, page).description) }
        return .object(o)
    }

    private static func clipped(_ s: String) -> String {
        s.count > maxTextLength ? String(s.prefix(maxTextLength)) + "…" : s
    }
}
