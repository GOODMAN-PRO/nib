import XCTest
import UIKit
import NibContracts
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

    /// Titles come from the undo history, the side from `editing.undoOnRight`, and ⌘Z / ⇧⌘Z act on the session's
    /// document through their descriptors alone.
    func testButtonsAndShortcutsFollowHistorySideAndDocument() async throws {
        let h = harness()
        let chrome = UndoChrome(app: h.app)
        chrome.refresh()
        let first = try XCTUnwrap(h.app.ui.toolbar.get(UndoButtons.itemID(.undo)))
        XCTAssertEqual(first.title, "Undo")
        XCTAssertEqual(first.group, .navLeading)
        XCTAssertEqual(first.params, ["doc": "doc:FIXTUREDOC01"])

        let original = try title(h, Fixtures.page1)
        try await setTitle(h, Fixtures.page1, "Kinematics")
        chrome.refresh()
        XCTAssertEqual(h.app.ui.toolbar.get(UndoButtons.itemID(.undo))?.title, "Undo Set Page Title")
        XCTAssertEqual(h.app.content.keyCommands.get(UndoButtons.keyID(.undo))?.title, "Undo Set Page Title")

        _ = try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.undoButtonsOnRight.name), "value": true])
        chrome.refresh()
        XCTAssertEqual(h.app.ui.toolbar.get(UndoButtons.itemID(.undo))?.group, .navTrailing)
        XCTAssertEqual(h.app.ui.toolbar.get(UndoButtons.itemID(.redo))?.group, .navTrailing)

        let undoKey = try XCTUnwrap(h.app.content.keyCommands.get(UndoButtons.keyID(.undo)))
        _ = try await h.app.bus.execute(Invocation(command: undoKey.command, params: undoKey.params, session: h.session))
        XCTAssertEqual(try title(h, Fixtures.page1), original)
        chrome.refresh()
        XCTAssertEqual(h.app.ui.toolbar.get(UndoButtons.itemID(.redo))?.title, "Redo Set Page Title")

        let redoKey = try XCTUnwrap(h.app.content.keyCommands.get(UndoButtons.keyID(.redo)))
        _ = try await h.app.bus.execute(Invocation(command: redoKey.command, params: redoKey.params, session: h.session))
        XCTAssertEqual(try title(h, Fixtures.page1), "Kinematics")
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
        let aiRow = try XCTUnwrap(model.rows.first { $0.id == turn })
        XCTAssertEqual(aiRow.principal.kind, .ai)
        XCTAssertEqual(aiRow.changes, 2)
        XCTAssertEqual(aiRow.label, "Set Page Title")

        await model.revert(aiRow)

        XCTAssertEqual(model.receipt, .reverted(count: 1, kept: 1))
        XCTAssertEqual(try title(h, Fixtures.page1), originalTitle)     // the AI's edit nobody touched since
        XCTAssertEqual(try title(h, Fixtures.page2), "Mine")            // the later user edit is kept
        XCTAssertEqual(try title(h, Fixtures.pdfPage), "Also mine")
        XCTAssertFalse(model.rows.contains { $0.id == turn })
        XCTAssertEqual(model.rows.first?.label, "Revert Set Page Title") // the revert is itself one undoable step
        XCTAssertEqual(model.rows.first?.principal.kind, .you)

        // The step is gone now: reverting it again says so instead of failing silently.
        await model.revert(aiRow)
        XCTAssertEqual(model.receipt, .gone)
    }

    func testPrincipalBadgesDetailsAndReceipts() {
        XCTAssertEqual(HistoryPrincipal("user").kind, .you)
        XCTAssertEqual(HistoryPrincipal("ai:chat1").kind, .ai)
        XCTAssertNil(HistoryPrincipal("ai:chat1").detail)
        XCTAssertEqual(HistoryPrincipal("plugin:anki-export").kind, .plugin)
        XCTAssertEqual(HistoryPrincipal("plugin:anki-export").detail, "anki-export")
        XCTAssertEqual(HistoryPrincipal("bridge:claude-code").kind, .bridge)
        XCTAssertEqual(HistoryPrincipal("bridge:claude-code").detail, "claude-code")
        XCTAssertEqual(HistoryPrincipal("sync:1a2b3c4d").kind, .collaborator)
        for kind in HistoryPrincipal.Kind.allCases { XCTAssertFalse(kind.title.isEmpty) }

        let row = HistoryRow(id: "G", label: "Add Strokes", principal: HistoryPrincipal("plugin:anki-export"), changes: 3,
                             date: Date())
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
