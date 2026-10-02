import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatUndoUI

/// A small undoable `.edit` command (sets a page title) so tests can make changes as any principal.
private struct SetPageTitle: NibCommand {
    struct Params: Codable {
        var page: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "test.setPageTitle", title: "Set Page Title", summary: "Test only: set a page's title.",
        params: .obj(["page": .ref, "title": .str()], required: ["page", "title"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "title": "T"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .page(doc, pid)? = NodeRef(p.page) else { throw NibError.invalid("not a page ref", path: "$.page") }
        try ctx.mutate { tx in
            guard var page = try tx.content(doc).page(pid) else { throw NibError.notFound("page \(pid)") }
            page.title = p.title
            try tx.put(page, doc: doc)
        }
        return NoResult()
    }
}

/// A window-level step like the toolbar's "Move Palette": undoable and redoable on an UndoManager, outside any document.
private final class WindowStep {
    var dock = "bottom"
    let manager: UndoManager

    init() {
        manager = UndoManager()
        manager.groupsByEvent = false
    }

    func move(to dock: String) {
        manager.beginUndoGrouping()
        set(dock)
        manager.endUndoGrouping()
    }

    private func set(_ next: String) {
        let previous = dock
        dock = next
        manager.registerUndo(withTarget: self) { step in step.set(previous) }
        manager.setActionName("Move Palette")
    }
}

@MainActor
final class FeatUndoUITests: XCTestCase {
    private func harness() -> Harness {
        let h = Harness(features: [FeatUndoUIFeature.self])
        h.app.commands.register(SetPageTitle.self)
        return h
    }

    private func setTitle(_ h: Harness, _ page: PageID, _ title: String, as principal: Principal = .user,
                          group: String? = nil) async throws {
        let params: JSONValue = ["page": .string(NodeRef.page(Fixtures.docID, page).description), "title": .string(title)]
        _ = try await h.app.bus.execute(Invocation(command: SetPageTitle.descriptor.id, params: params,
                                                   principal: principal, session: h.session, group: group))
    }

    private func title(_ h: Harness, _ page: PageID) throws -> String? {
        try h.app.workspace.content(Fixtures.docID).page(page)?.title
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatUndoUIFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersButtonsShortcutsGesturesPanelAndSetting() throws {
        let app = harness().app
        XCTAssertEqual(app.ui.toolbar.get(UndoButtons.itemID(.undo))?.command, CommandIDs.undo)
        XCTAssertEqual(app.ui.toolbar.get(UndoButtons.itemID(.redo))?.command, CommandIDs.redo)
        XCTAssertEqual(app.ui.toolbar.get(UndoButtons.itemID(.undo))?.docKinds, Set(DocumentKind.allCases))
        let undoKey = try XCTUnwrap(app.content.keyCommands.get(UndoButtons.keyID(.undo)))
        XCTAssertEqual(undoKey.command, CommandIDs.undo)
        XCTAssertEqual(undoKey.shortcut, KeyShortcut("z", [.command]))
        let redoKey = try XCTUnwrap(app.content.keyCommands.get(UndoButtons.keyID(.redo)))
        XCTAssertEqual(redoKey.command, CommandIDs.redo)
        XCTAssertEqual(redoKey.shortcut, KeyShortcut("z", [.command, .shift]))
        XCTAssertEqual(app.ui.panels.get("undo.history")?.placement, .sidebarTab)
        XCTAssertNotNil(app.ui.canvasAttachments.get("undo.gestures"))
        XCTAssertNotNil(app.ui.settingsPages.get("undo.settings"))
        XCTAssertEqual(app.settings.descriptor(UndoSettings.gestures.name)?.owner, FeatUndoUIFeature.id)
        XCTAssertTrue(app.settings.get(UndoSettings.gestures))
    }

    /// contracts-v2: one registration. Each window's buttons name its document (`sessionParams`), title the step
    /// ("Undo Set Page Title", `sessionTitle`) and grey out with nothing to undo (`isEnabled`); iPhone keeps Undo only.
    /// The side follows `editing.undoOnRight`, and ⌘Z / ⇧⌘Z act on the key window's document.
    func testButtonsAndShortcutsFollowHistorySideAndDocument() async throws {
        let h = harness()
        let chrome = UndoChrome(app: h.app)
        chrome.refresh()
        let undo = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.undo)))
        let redo = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.redo)))
        XCTAssertEqual(undo.group, .navLeading)
        XCTAssertEqual(undo.resolvedTitle(for: h.session), "Undo")
        XCTAssertEqual(undo.resolvedParams(for: h.session), ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(undo.isEnabled?(h.session), false)
        XCTAssertEqual(redo.isEnabled?(h.session), false)
        XCTAssertTrue(undo.showsInCompactWidth)
        XCTAssertFalse(redo.showsInCompactWidth)
        XCTAssertEqual(chrome.titles, .plain)

        let original = try title(h, Fixtures.page1)
        try await setTitle(h, Fixtures.page1, "Kinematics")
        // The live state needs no re-registration: the same descriptors answer for the new step.
        XCTAssertEqual(undo.resolvedTitle(for: h.session), "Undo Set Page Title")
        XCTAssertEqual(undo.isEnabled?(h.session), true)
        XCTAssertEqual(redo.isEnabled?(h.session), false)
        chrome.refresh()
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.undo))?.title, "Undo Set Page Title")
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.redo))?.title, "Redo")

        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.undoButtonsOnRight.name), "value": true])
        chrome.refresh()
        XCTAssertEqual(h.app.ui.toolbar.get(UndoButtons.itemID(.undo))?.group, .navTrailing)
        XCTAssertEqual(h.app.ui.toolbar.get(UndoButtons.itemID(.redo))?.group, .navTrailing)

        // ⌘Z as the shell runs it: `resolvedParams` for the key window's session, routed by `UndoRoute`.
        let undoKey = try XCTUnwrap(h.app.content.keyCommands.get(UndoButtons.keyID(.undo)))
        XCTAssertEqual(undoKey.scope, .canvas)
        let undoParams = undoKey.resolvedParams(for: h.session)
        XCTAssertEqual(undoParams, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(UndoRoute.forCommand(undoKey.command, params: undoParams, session: h.session,
                                            history: h.app.bus.history, window: nil), .document(Fixtures.docID))
        _ = try await h.app.bus.execute(Invocation(command: undoKey.command, params: undoParams, session: h.session))
        XCTAssertEqual(try title(h, Fixtures.page1), original)
        XCTAssertEqual(redo.resolvedTitle(for: h.session), "Redo Set Page Title")
        XCTAssertEqual(redo.isEnabled?(h.session), true)
        chrome.refresh()
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.redo))?.title, "Redo Set Page Title")

        // `edit.redo {}` from the key's static params alone reaches the invoking session's document (contracts-v2).
        let redoKey = try XCTUnwrap(h.app.content.keyCommands.get(UndoButtons.keyID(.redo)))
        XCTAssertEqual(redoKey.params, [:])
        _ = try await h.app.bus.execute(Invocation(command: redoKey.command, params: redoKey.params, session: h.session))
        XCTAssertEqual(try title(h, Fixtures.page1), "Kinematics")

        // No document in the window: nothing to name, nothing to undo.
        let library = EditorSession()
        XCTAssertEqual(undo.resolvedParams(for: library), [:])
        XCTAssertEqual(undo.isEnabled?(library), false)
        XCTAssertEqual(undo.resolvedTitle(for: library), "Undo")
    }

    /// CreateUITests' QuickNote sequence, using the registered toolbar commands and real stored strokes.
    /// The invoking window must keep its document even when another window is active.
    func testToolbarUndoRedoRetainsStrokeIdentityInTheInvokingDocument() async throws {
        let h = harness()
        let doc = NibID.make(), page = NibID.make()
        let content = DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: [
            PageRecord(id: page, order: "V", size: .a4, background: .ofTemplate("builtin.ruled"))
        ])
        _ = try h.library.createDocument(content, title: "Untitled", in: nil)
        h.session.document = doc
        h.session.page = page
        let undo = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.undo)))
        let redo = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.redo)))
        let otherWindow = EditorSession()
        otherWindow.document = Fixtures.docID
        h.app.services.sessions.add(otherWindow)

        func run(_ button: ToolbarItemDescriptor) async throws {
            XCTAssertEqual(button.isEnabled?(h.session), true)
            let result = try await h.app.bus.execute(try XCTUnwrap(button.command),
                button.resolvedParams(for: h.session), session: h.session)
            XCTAssertEqual(result["done"]?.boolValue, true)
        }
        func strokes() throws -> [Item] { try h.app.workspace.items(doc, page: page) }

        var expected: [Item] = []
        for _ in 0..<2 {
            let stroke = Stroke(style: .defaultPen, points: [
                StrokePoint(x: 40, y: 60, width: 2, height: 2),
                StrokePoint(x: 60, y: 66, width: 2, height: 2)
            ])
            let written = try await h.insert([Item(kind: .stroke, stroke: stroke)], page: page, doc: doc)
            XCTAssertEqual(try strokes().count, expected.count + 1)
            try await run(undo)
            XCTAssertEqual(try strokes().map(\.id), expected.map(\.id))
            XCTAssertTrue(h.app.bus.history.canRedo(doc))
            try await run(redo)
            expected += written
            XCTAssertEqual(try strokes().map(\.id), expected.map(\.id))
            XCTAssertEqual(try strokes().map(\.stroke), expected.map(\.stroke))
            XCTAssertEqual(h.session.document, doc)
            XCTAssertEqual(h.session.page, page)
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        }
    }

    /// A retained closed popover must not consume the next tap on Undo. This exercises UIKit's actual
    /// scroll hit target, which can survive SwiftUI hiding the popover's contents.
    func testClosedPopoverLeavesUndoHitTargetAccessible() async throws {
        let h = harness()
        let undo = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.undo)))
        func chrome(presented: Bool) -> some View {
            ZStack {
                NibToolbarItem(.undo, label: undo.resolvedTitle(for: h.session)) {
                    h.app.perform(CommandIDs.undo, undo.resolvedParams(for: h.session), session: h.session)
                }
                NibPopoverPanel(title: "Document menu") { Text("Retained menu content") }
                    .budsFrom("title", isPresented: .constant(presented))
            }
        }
        let host = UIHostingController(rootView: chrome(presented: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        for presented in [false, true, false] {
            host.rootView = chrome(presented: presented)
            for _ in 0..<5 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            let point = CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
            XCTAssertTrue(scroll.bounds.contains(scroll.convert(point, from: host.view)),
                          "The retained menu must overlap Undo to exercise interception")
            let hit = try XCTUnwrap(host.view.hitTest(point, with: nil))
            XCTAssertEqual(hit.isDescendant(of: scroll), presented,
                           "Closing the menu must return the centre tap to Undo")
            XCTAssertEqual(scroll.isUserInteractionEnabled, presented)
            if !presented {
                // Reproduce the original native-host state: the same point is swallowed even though
                // the menu's presentation binding is false. Restore it before the next lifecycle step.
                scroll.isUserInteractionEnabled = true
                let intercepted = try XCTUnwrap(host.view.hitTest(point, with: nil))
                XCTAssertTrue(intercepted.isDescendant(of: scroll))
                scroll.isUserInteractionEnabled = false
            }
        }
    }

    /// Shell v2 falls back to the window's UndoManager when the document has nothing to undo. The ⌘Z / ⇧⌘Z titles
    /// follow the same route and wording as the shell's menu validation; the document's step always comes first.
    func testKeyTitlesFollowTheShellsWindowUndoFallback() async throws {
        let h = harness()
        let step = WindowStep()
        var windows: [EditorSession?] = []
        let chrome = UndoChrome(app: h.app) { _, session in
            windows.append(session)
            return step.manager
        }
        chrome.refresh()
        XCTAssertEqual(chrome.titles, .plain)
        XCTAssertTrue(windows.allSatisfy { $0 === h.session })      // the key window's (active) session

        step.move(to: "left")
        chrome.refresh()
        let undoKey = try XCTUnwrap(h.app.content.keyCommands.get(UndoButtons.keyID(.undo)))
        XCTAssertEqual(undoKey.title, step.manager.undoMenuItemTitle)
        XCTAssertTrue(undoKey.title.hasSuffix("Move Palette"))
        XCTAssertEqual(UndoRoute.forCommand(undoKey.command, params: undoKey.resolvedParams(for: h.session),
                                            session: h.session, history: h.app.bus.history, window: step.manager),
                       .window)
        // The toolbar buttons only reach the document, so they stay as they were.
        let undoItem = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.undo)))
        XCTAssertEqual(undoItem.isEnabled?(h.session), false)
        XCTAssertEqual(undoItem.resolvedTitle(for: h.session), "Undo")

        // A document step wins over the window's.
        try await setTitle(h, Fixtures.page1, "Kinematics")
        chrome.refresh()
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.undo))?.title, "Undo Set Page Title")

        // The document's step undone: ⌘Z names the window's step again, ⇧⌘Z the document's.
        _ = try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        chrome.refresh()
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.undo))?.title, step.manager.undoMenuItemTitle)
        XCTAssertTrue(UndoWindow.perform(.undo, on: step.manager))
        XCTAssertEqual(step.dock, "bottom")
        chrome.refresh()
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.undo))?.title, "Undo")
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.redo))?.title, "Redo Set Page Title")
        XCTAssertTrue(UndoWindow.perform(.redo, on: step.manager))
        XCTAssertEqual(step.dock, "left")
        XCTAssertFalse(UndoWindow.perform(.redo, on: step.manager))
    }

    /// The titles agree with `UndoRoute` for every combination of document and window steps.
    func testKeyTitlesMatchTheRoute() async throws {
        let h = harness()
        let history = h.app.bus.history
        let step = WindowStep()
        XCTAssertEqual(UndoKeyTitles(history: history, doc: Fixtures.docID, window: nil), .plain)
        XCTAssertEqual(UndoKeyTitles(history: history, doc: nil, window: nil), .plain)
        XCTAssertEqual(UndoKeyTitles(history: history, doc: nil, window: step.manager), .plain)
        step.move(to: "top")
        // No document open: only the window can act (the library, a window showing onboarding).
        XCTAssertEqual(UndoAction.undo.route(doc: nil, history: history, window: step.manager), .window)
        XCTAssertEqual(UndoKeyTitles(history: history, doc: nil, window: step.manager).undo,
                       step.manager.undoMenuItemTitle)
        try await setTitle(h, Fixtures.page1, "Kinematics")
        XCTAssertEqual(UndoAction.undo.route(doc: Fixtures.docID, history: history, window: step.manager),
                       .document(Fixtures.docID))
        XCTAssertEqual(UndoAction.redo.route(doc: Fixtures.docID, history: history, window: step.manager), .nothing)
        let titles = UndoKeyTitles(history: history, doc: Fixtures.docID, window: step.manager)
        XCTAssertEqual(titles, UndoKeyTitles(undo: "Undo Set Page Title", redo: "Redo"))
    }

    /// Acceptance: the History view model reverts a group made by `.ai("t")` and keeps later user edits.
    func testHistoryRevertsAnAITurnAndKeepsLaterUserEdits() async throws {
        let h = harness()
        let originalTitle = try title(h, Fixtures.page1)
        let turn = "AITURN000001"
        try await setTitle(h, Fixtures.page1, "AI heading", as: .ai("t"), group: turn)
        try await setTitle(h, Fixtures.page2, "AI summary", as: .ai("t"), group: turn)
        try await setTitle(h, Fixtures.page2, "Mine")
        try await setTitle(h, Fixtures.pdfPage, "Also mine")

        let model = HistoryViewModel(app: h.app, session: h.session)
        await model.show(doc: Fixtures.docID)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows.first?.principal.kind, .you)          // newest first
        let aiRow = try XCTUnwrap(model.rows.first { $0.group == turn })
        XCTAssertEqual(aiRow.principal.kind, .assistant)
        XCTAssertEqual(aiRow.changes, 2)
        XCTAssertEqual(aiRow.label, "Set Page Title")

        await model.revert(aiRow)

        XCTAssertEqual(model.receipt, .reverted(count: 1, kept: 1))
        XCTAssertEqual(try title(h, Fixtures.page1), originalTitle)     // the AI's edit nobody touched since
        XCTAssertEqual(try title(h, Fixtures.page2), "Mine")            // the later user edit is kept
        XCTAssertEqual(try title(h, Fixtures.pdfPage), "Also mine")
        XCTAssertFalse(model.rows.contains { $0.group == turn })
        XCTAssertEqual(model.rows.first?.label, "Revert Set Page Title") // the revert is itself one undoable step
        XCTAssertEqual(model.rows.first?.principal.kind, .you)

        // The step is gone now: reverting it again says so instead of failing silently.
        await model.revert(aiRow)
        XCTAssertEqual(model.receipt, .gone)
    }

    /// The open panel follows live commits (coalesced into one reload), and stops once it is off screen.
    func testHistoryFollowsCommitsWhileObservingAndStopsAfter() async throws {
        let h = harness()
        let model = HistoryViewModel(app: h.app, session: h.session)
        await model.show(doc: Fixtures.docID)
        let before = model.rows.count
        model.observe()

        try await setTitle(h, Fixtures.page1, "Live")
        await Task.yield()
        await Task.yield()
        for _ in 0..<100 where model.rows.count == before { await Task.yield() }   // the reload awaits the bus
        XCTAssertEqual(model.rows.count, before + 1)
        XCTAssertEqual(model.rows.first?.label, "Set Page Title")

        // A group that commits again after an interleaved edit is two rows, each with its own id.
        try await setTitle(h, Fixtures.page2, "AI", as: .ai("t"), group: "AITURN000002")
        try await setTitle(h, Fixtures.page1, "Mine")
        try await setTitle(h, Fixtures.page2, "AI again", as: .ai("t"), group: "AITURN000002")
        for _ in 0..<100 where model.rows.count < before + 4 { await Task.yield() }
        XCTAssertEqual(Set(model.rows.map(\.id)).count, model.rows.count)

        model.stopObserving()
        for _ in 0..<20 { await Task.yield() }       // a reload already under way finishes first
        let rows = model.rows
        try await setTitle(h, Fixtures.page1, "Unseen")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.rows, rows)
    }

    func testPrincipalBadgesDetailsAndReceipts() {
        XCTAssertEqual(HistoryPrincipal("user").kind, .you)
        XCTAssertEqual(HistoryPrincipal("ai:chat1").kind, .assistant)
        XCTAssertNil(HistoryPrincipal("ai:chat1").detail)
        XCTAssertEqual(HistoryPrincipal("plugin:anki-export").kind, .plugin)
        XCTAssertEqual(HistoryPrincipal("plugin:anki-export").detail, "anki-export")
        XCTAssertEqual(HistoryPrincipal("bridge:claude-code").kind, .bridge)
        XCTAssertEqual(HistoryPrincipal("bridge:claude-code").detail, "claude-code")
        XCTAssertEqual(HistoryPrincipal("sync:1a2b3c4d").kind, .collaborator)
        XCTAssertNil(HistoryPrincipal("sync:").detail)
        // The badge is NibDesign's provenance kind: the same words and glyphs as every other "made by" mark.
        XCTAssertEqual(HistoryPrincipal("bridge:claude-code").kind, NibPrincipalKind(.bridge("claude-code")))
        for kind in NibPrincipalKind.allCases { XCTAssertFalse(kind.title.isEmpty) }

        let row = HistoryRow(id: "G#1", group: "G", label: "Add Strokes", principal: HistoryPrincipal("plugin:anki-export"),
                             changes: 3, date: Date())
        XCTAssertTrue(row.detail().hasPrefix("anki-export · 3 changes · "))
        XCTAssertTrue(row.accessibilityLabel.hasPrefix("Add Strokes, Plugin, anki-export"))

        XCTAssertEqual(HistoryReceipt.reverted(count: 2, kept: 0).text, "Reverted 2 changes.")
        XCTAssertEqual(HistoryReceipt.reverted(count: 1, kept: 2).text, "Reverted 1 change. 2 changes made since were kept.")
        XCTAssertFalse(HistoryReceipt.reverted(count: 1, kept: 2).isWarning)
        XCTAssertTrue(HistoryReceipt.reverted(count: 0, kept: 2).isWarning)
        XCTAssertTrue(HistoryReceipt.gone.isWarning)
    }

    /// Acceptance: the gestures never fire on toolbars, whether the bar floats above the canvas or sits inside it.
    func testGesturesNeverFireOnToolbars() {
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let canvas = UIView(frame: window.bounds)
        window.addSubview(canvas)
        let page = UIView()
        canvas.addSubview(page)
        let tile = UIView()
        page.addSubview(tile)
        let floatingBar = UIView()
        window.addSubview(floatingBar)
        let floatingUndo = UIButton()
        floatingBar.addSubview(floatingUndo)
        let hostedToolbar = UIToolbar()
        canvas.addSubview(hostedToolbar)
        let toolbarContent = UIView()
        hostedToolbar.addSubview(toolbarContent)
        let menuButton = UIButton()
        let menu = UIView()
        canvas.addSubview(menu)
        menu.addSubview(menuButton)
        let textBox = UITextView()
        page.addSubview(textBox)

        XCTAssertTrue(UndoGestureGate.accepts(touchIn: canvas, canvas: canvas))
        XCTAssertTrue(UndoGestureGate.accepts(touchIn: tile, canvas: canvas))
        XCTAssertFalse(UndoGestureGate.accepts(touchIn: floatingUndo, canvas: canvas))
        XCTAssertFalse(UndoGestureGate.accepts(touchIn: floatingBar, canvas: canvas))
        XCTAssertFalse(UndoGestureGate.accepts(touchIn: toolbarContent, canvas: canvas))
        XCTAssertFalse(UndoGestureGate.accepts(touchIn: menuButton, canvas: canvas))
        XCTAssertFalse(UndoGestureGate.accepts(touchIn: textBox, canvas: canvas))
        XCTAssertFalse(UndoGestureGate.accepts(touchIn: nil, canvas: canvas))

        XCTAssertTrue(UndoGestureGate.isEnabled(setting: true, readOnly: false, editingText: false))
        XCTAssertFalse(UndoGestureGate.isEnabled(setting: false, readOnly: false, editingText: false))
        XCTAssertFalse(UndoGestureGate.isEnabled(setting: true, readOnly: true, editingText: false))
        XCTAssertFalse(UndoGestureGate.isEnabled(setting: true, readOnly: false, editingText: true))
    }

    func testGestureAttachmentUndoesAndRedoesTheCanvasDocument() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let original = try title(h, Fixtures.page1)
        try await setTitle(h, Fixtures.page1, "Kinematics")

        let attachment = UndoGestureAttachment(host: host)
        attachment.attach(to: host)
        let taps = host.canvasView.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        XCTAssertEqual(Set(taps.map { $0.numberOfTouchesRequired }), [2, 3])
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        XCTAssertTrue(taps.allSatisfy { $0.numberOfTapsRequired == 2 && $0.allowedTouchTypes == direct })
        XCTAssertEqual(attachment.undoTap.numberOfTouchesRequired, 2)
        XCTAssertEqual(attachment.redoTap.numberOfTouchesRequired, 3)
        XCTAssertTrue(attachment.focus.isDescendant(of: host.canvasView))
        XCTAssertEqual(attachment.focus.editingInteractionConfiguration, UIEditingInteractionConfiguration.none)
        XCTAssertTrue(attachment.gestureRecognizerShouldBegin(attachment.undoTap))

        let undone = await attachment.perform(.undo)
        XCTAssertTrue(undone)
        XCTAssertEqual(try title(h, Fixtures.page1), original)
        let redone = await attachment.perform(.redo)
        XCTAssertTrue(redone)
        XCTAssertEqual(try title(h, Fixtures.page1), "Kinematics")

        // With nothing left in the document, the taps fall back to the window's UndoManager, as ⌘Z does; the
        // document's step always comes first.
        let step = WindowStep()
        attachment.windowUndo = { _ in step.manager }
        let documentFirst = await attachment.perform(.undo)
        XCTAssertTrue(documentFirst)
        XCTAssertEqual(try title(h, Fixtures.page1), original)
        let nothing = await attachment.perform(.undo)
        XCTAssertFalse(nothing)
        step.move(to: "left")
        let windowUndone = await attachment.perform(.undo)
        XCTAssertTrue(windowUndone)
        XCTAssertEqual(step.dock, "bottom")
        XCTAssertEqual(try title(h, Fixtures.page1), original)
        let documentRedone = await attachment.perform(.redo)
        XCTAssertTrue(documentRedone)
        XCTAssertEqual(try title(h, Fixtures.page1), "Kinematics")
        XCTAssertEqual(step.dock, "bottom")
        let windowRedone = await attachment.perform(.redo)
        XCTAssertTrue(windowRedone)
        XCTAssertEqual(step.dock, "left")
        let nothingToRedo = await attachment.perform(.redo)
        XCTAssertFalse(nothingToRedo)

        // Off from Settings (through settings.set, as the AI or a plugin would), in read-only mode and while typing.
        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(UndoSettings.gestures.name), "value": false])
        XCTAssertFalse(attachment.gestureRecognizerShouldBegin(attachment.redoTap))
        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(UndoSettings.gestures.name), "value": true])
        h.session.readOnly = true
        XCTAssertFalse(attachment.gestureRecognizerShouldBegin(attachment.undoTap))
        h.session.readOnly = false
        h.session.isEditingText = true
        XCTAssertFalse(attachment.gestureRecognizerShouldBegin(attachment.undoTap))

        attachment.detach(from: host)
        XCTAssertTrue(host.canvasView.gestureRecognizers?.isEmpty ?? true)
        XCTAssertNil(attachment.focus.superview)
    }
}
