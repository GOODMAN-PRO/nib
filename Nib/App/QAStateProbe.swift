import UIKit
import NibContracts

/// A transparent, non-interactive accessibility element. Its value is a live snapshot, evaluated on demand by
/// accessibility (including during a gesture); no cached state, timers, subscriptions or production polling.
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
                "selectionCount": .number(Double(session.selection.items.count)),
                "clipboardChangeCount": .number(Double(UIPasteboard.general.changeCount)),
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
}

/// Keeps fragment bytes out of the compact state JSON. The helper checks that Copy changed the clipboard before
/// consuming this payload; Nib can read its own output without cross-app authorization.
@MainActor
final class QAClipboardProbe: UIView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "nib.qa.clipboard"
        accessibilityLabel = "QA copied fragment"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityValue: String? {
        get {
            let snapshot = NibUITestClipboardSnapshot(pasteboard: .general)
            return (try? JSONEncoder().encode(snapshot)).map { String(decoding: $0, as: UTF8.self) }
        }
        set { }
    }
}
