import UIKit
import PencilKit
import NibContracts

/// A transparent, non-interactive accessibility element. Its value is a live snapshot, evaluated on demand by
/// accessibility (including during a gesture). Clipboard state is sampled outside the accessibility RPC below;
/// document state remains live, with no timers or production polling.
@MainActor
final class QAStateProbe: UIView {
    private weak var shell: ShellViewController?
    let clipboardProbe = QAClipboardProbe()

    init(shell: ShellViewController) {
        self.shell = shell
        super.init(frame: CGRect(x: 1, y: 1, width: 1, height: 1))
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "nib.qa.state"
        accessibilityLabel = "QA session state"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityValue: String? {
        get {
            guard let shell else { return nil }
            let app = shell.app, session = shell.session
            let doc = session.document
            let content = doc.flatMap { try? app.workspace.content($0) }
            let items = doc.flatMap { d in session.page.flatMap { try? app.workspace.items(d, page: $0) } } ?? []
            let canvas = findCanvas(in: shell.view)
            let offset = canvas?.contentOffset ?? .zero
            let receiptPages = NibUITestMode.scenario == .unseenBoards && content?.meta.kind == .whiteboard
                ? content?.livePages ?? [] : []
            let receiptPrefix = receiptPages.isEmpty ? nil : doc.map { "collabpresence.seen." + $0.raw }
            let baseline = receiptPrefix.flatMap { app.settings.json($0)?.stringValue }.flatMap(Rev.init(string:))
            let receipts: [String: JSONValue] = Dictionary(uniqueKeysWithValues: receiptPages.map { page in
                let mark = receiptPrefix.flatMap { app.settings.json($0 + "." + page.id.raw)?.stringValue }
                return (page.id.raw, mark.map(JSONValue.string) ?? .null)
            })
            // These are the seeded remote page-record changes, not a substitute for F108's unseen item tracker.
            let unseenFixturePages = receiptPages.filter { page in
                guard let baseline else { return false }
                let own = receipts[page.id.raw]?.stringValue.flatMap(Rev.init(string:)) ?? baseline
                return page.rev.device != app.clock.device && page.rev.effective() > max(baseline.effective(), own.effective())
            }.map { JSONValue.string($0.id.raw) }
            let state: JSONValue = [
                "screen": .string(UITestFixture.failure != nil ? "fixtureError" : !UITestFixture.isReady ? "loading" : doc == nil ? "library" : "document"),
                "document": doc.map { .string($0.raw) } ?? .null,
                "page": doc == nil ? .null : session.page.map { .string($0.raw) } ?? .null,
                "pageCount": .number(Double(content?.livePages.count ?? 0)),
                "tool": .string(session.tool),
                "zoom": .number(Double(canvas?.zoomScale ?? 1)),
                "contentOffset": ["x": .number(Double(offset.x)), "y": .number(Double(offset.y))],
                "itemCountOnPage": .number(Double(items.filter { !$0.deleted }.count)),
                "strokeCountOnPage": .number(Double(items.filter { !$0.deleted && $0.kind == .stroke }.count)),
                "inkInput": .array(canvas.map { inkInput(in: $0) } ?? []),
                "selectionCount": .number(Double(session.selection.items.count)),
                "clipboardChangeCount": clipboardProbe.changeCount.map { .number(Double($0)) } ?? .null,
                "undoAvailable": .bool(UndoRoute.resolve(redo: false, doc: doc, history: app.bus.history, window: shell.view.window?.undoManager) != .nothing),
                "redoAvailable": .bool(UndoRoute.resolve(redo: true, doc: doc, history: app.bus.history, window: shell.view.window?.undoManager) != .nothing),
                "openPanels": .array(session.openPanels.sorted().map(JSONValue.string)),
                "paletteDock": canvas == nil ? .null : session.toolOptions["nib.qa.paletteDock"] ?? .null,
                "fixtureError": UITestFixture.failure.map(JSONValue.string) ?? .null,
                "fixtureScenario": .string(NibUITestMode.scenario.rawValue),
                "boardReadReceipts": .object(receipts),
                "boardSeenBaseline": baseline.map { .string($0.description) } ?? .null,
                "unseenFixturePages": .array(unseenFixturePages),
                "renderFailureCount": .number(Double(UITestFixture.renderer?.failureCount ?? 0)),
                "rendererCachePurgeCount": .number(Double(UITestFixture.renderer?.cachePurgeCount ?? 0)),
                "memoryWarningCount": .number(Double(UITestFixture.memoryWarningCount)),
                "cachedPageCount": .number(Double(doc.map { app.workspace.cachedPages($0).count } ?? 0))
            ]
            return state.jsonString()
        }
        set { }
    }

    private func findCanvas(in view: UIView) -> UIScrollView? {
        if view.accessibilityIdentifier == "nib.canvas", let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let canvas = findCanvas(in: child) { return canvas }
        }
        return nil
    }

    /// Read-only native input diagnostics distinguish a missed gesture from a
    /// committed stroke missing in the document model in failure attachments.
    private func inkInput(in view: UIView) -> [JSONValue] {
        if let ink = view as? PKCanvasView {
            return [[
                "enabled": .bool(ink.isUserInteractionEnabled),
                "hidden": .bool(ink.isHidden),
                "mounted": .bool(ink.window != nil),
                "anyInput": .bool(ink.drawingPolicy == .anyInput),
                "nativeStrokeCount": .number(Double(ink.drawing.strokes.count)),
                "drawingEnabled": .bool(ink.drawingGestureRecognizer.isEnabled),
                "drawingState": .number(Double(ink.drawingGestureRecognizer.state.rawValue))
            ]]
        }
        return view.subviews.flatMap { inkInput(in: $0) }
    }
}

/// Keeps fragment bytes out of the compact state JSON. The helper checks that Copy changed the clipboard before
/// consuming this payload; Nib can read its own output without cross-app authorization.
@MainActor
final class QAClipboardProbe: UIView {
    private var snapshot: String?
    private var observedRevision: Int?
    private var loadedRevision: Int?
    private var loadingRevision: Int?
    private var refreshScheduled = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "nib.qa.clipboard"
        accessibilityLabel = "QA copied fragment"
        NotificationCenter.default.addObserver(self, selector: #selector(pasteboardDidChange),
                                               name: UIPasteboard.changedNotification, object: nil)
        scheduleRefresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityValue: String? {
        get {
            // XCTest evaluates values while matching unrelated identifiers too. A
            // synchronous pasteboard read here can deadlock its accessibility RPC.
            scheduleRefresh()
            guard loadedRevision == observedRevision else { return nil }
            return snapshot
        }
        set { }
    }

    /// Even changeCount can synchronously contact the pasteboard service. Accessibility getters must only read
    /// memory; their next main-queue turn samples the real revision and the copied bytes together.
    var changeCount: Int? {
        scheduleRefresh()
        return observedRevision
    }

    @objc private func pasteboardDidChange() {
        observedRevision = nil
        snapshot = nil
        // Re-read the bytes after a notification; finish also validates any in-flight provider's revision.
        loadedRevision = nil
        scheduleRefresh()
    }

    @objc private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let board = UIPasteboard.general
        let revision = board.changeCount
        if observedRevision != revision {
            observedRevision = revision
            snapshot = nil
        }
        guard revision != loadedRevision, revision != loadingRevision else { return }
        loadingRevision = revision
        let type = "app.nib.fragment"
        guard let provider = board.itemProviders.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else {
            finish(nil, revision: revision)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
            DispatchQueue.main.async { self?.finish(data, revision: revision) }
        }
    }

    private func finish(_ data: Data?, revision: Int) {
        guard loadingRevision == revision else { return }
        loadingRevision = nil
        guard UIPasteboard.general.changeCount == revision else { scheduleRefresh(); return }
        let value: JSONValue = ["changeCount": .number(Double(revision)),
                                "fragment": data.map { .string($0.base64EncodedString()) } ?? .null]
        snapshot = value.jsonString()
        observedRevision = revision
        loadedRevision = revision
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
