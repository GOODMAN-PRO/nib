import XCTest
import UIKit
import LinkPresentation
import NibContracts
import NibTesting
@testable import FeatTextDoc

@MainActor
final class FeatTextDocTests: XCTestCase {
    private let doc = Fixtures.textDocID
    private let heading = "block:FIXTUREDOC02/FIXTUREBLK01"
    private let paragraph = "block:FIXTUREDOC02/FIXTUREBLK02"
    private let table = "block:FIXTUREDOC02/FIXTUREBLK03"

    private func harness() -> Harness { Harness(features: [FeatTextDocFeature.self]) }

    private func live(_ h: Harness) throws -> [TextBlock] { try h.app.workspace.content(doc).liveBlocks }

    private func ids(_ h: Harness) throws -> [String] { try live(h).map { $0.id.raw } }

    private func block(_ h: Harness, _ id: String) throws -> TextBlock {
        try XCTUnwrap(live(h).first { $0.id.raw == id }, "block \(id)")
    }

    private func assertError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func openEditor(_ h: Harness) -> TextDocViewController {
        let editor = TextDocViewController(doc: doc, session: h.session, app: h.app)
        editor.loadViewIfNeeded()
        return editor
    }

    /// Polls `condition` on the main actor until it holds (async work: debounced renames, queued edits).
    private func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The Library Store's library.rename (F002), for tests that only register this feature.
    private func registerRename(_ h: Harness) {
        let library = h.library
        let descriptor = CommandDescriptor(
            id: "library.rename", title: "Rename", summary: "Rename a document (test stand-in).",
            params: .obj(["ref": .ref, "title": .str("new name")], required: ["ref", "title"]),
            effect: .library, target: .library)
        h.app.commands.register(descriptor) { json, _ in
            guard let ref = json["ref"]?.stringValue, let title = json["title"]?.stringValue else {
                throw NibError.invalid("ref and title are required")
            }
            try library.rename(NodeRef.documentID(from: ref), to: title)
            return [:]
        }
    }

    /// Every title in a menu, submenus included.
    private func titles(_ menu: UIMenu) -> [String] {
        menu.children.flatMap { element -> [String] in
            if let sub = element as? UIMenu { return [sub.title] + titles(sub) }
            return [element.title]
        }
    }

    private func environment(_ kind: BlockKind) -> BlockCell.Environment {
        BlockCell.Environment(style: BlockStyle.make(kind: kind), captionStyle: BlockStyle.make(kind: kind, caption: true),
                              marker: nil, placeholder: nil, alwaysShowsPlaceholder: false, readOnly: false,
                              accessoryWidth: 0, aiAvailable: false, isFirst: false)
    }

    // MARK: Registration and conformance

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatTextDocFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandsEditorBlockKindsAndMenus() {
        let h = harness()
        XCTAssertEqual(FeatTextDocFeature.id, "textdoc")
        for id in ["block.insert", "block.update", "block.delete", "block.move"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "textdoc", id)
        }
        XCTAssertTrue(h.app.commands.descriptor("block.delete")?.destructive ?? false)
        XCTAssertNotNil(h.app.ui.editors.get(DocumentKind.textDocument.rawValue))
        let kinds = h.app.content.blockKinds.all
        let expected: Set<BlockKind> = [.paragraph, .heading1, .heading2, .heading3, .bullet, .numbered, .todo, .quote,
                                        .code, .divider, .image, .video]
        XCTAssertEqual(Set(kinds.map { $0.kind }), expected)
        for k in kinds {
            XCTAssertNil(k.command, k.id)
            XCTAssertEqual(k.params["kind"]?.stringValue, k.kind.rawValue, k.id)
            XCTAssertFalse(k.aliases.isEmpty, k.id)
        }
        let new = h.app.ui.menuItems(.libraryNew, MenuContext(app: h.app))
        XCTAssertTrue(new.contains { $0.id == "textdoc.new" && $0.command == CommandIDs.batch })
    }

    func testShiftCommandTMakesATextDocumentOnlyOnce() async throws {
        let h = harness()
        await FeatTextDocFeature.start(h.app)
        let d = try XCTUnwrap(h.app.content.keyCommands.get("textdoc.new"))
        XCTAssertEqual(d.shortcut, KeyShortcut("t", [.command, .shift]))
        XCTAssertEqual(d.command, CommandIDs.appOpenURL)
        XCTAssertEqual(d.params["url"]?.stringValue, "nib://new?kind=textDocument")
        XCTAssertEqual(d.scope, .library)
        await FeatTextDocFeature.start(h.app)
        XCTAssertEqual(h.app.content.keyCommands.all.filter { $0.shortcut == d.shortcut }.count, 1)

        // The keyboard feature got there first: no second ⇧⌘T.
        let other = harness()
        other.app.content.keyCommands.register(KeyCommandDescriptor(
            id: "keyboard.newTextDocument", title: "New Text Document", shortcut: KeyShortcut("T", [.shift, .command]),
            command: CommandIDs.appOpenURL, params: ["url": "nib://new?kind=textDocument"], scope: .global, owner: "keyboard"))
        await FeatTextDocFeature.start(other.app)
        XCTAssertNil(other.app.content.keyCommands.get("textdoc.new"))
    }

    func testTheEditorIsMadeForTextDocuments() throws {
        let h = harness()
        let make = try XCTUnwrap(h.app.ui.editors.get(DocumentKind.textDocument.rawValue)?.make)
        let vc = make(doc, h.session, h.app)
        let editor = try XCTUnwrap(vc as? TextDocViewController)
        XCTAssertTrue(h.session.editor === editor)
        XCTAssertNil(editor.canvasHost)
        editor.loadViewIfNeeded()
        XCTAssertEqual(editor.blocks.map { $0.id.raw }, ["FIXTUREBLK01", "FIXTUREBLK02", "FIXTUREBLK03"])
    }

    // MARK: Acceptance: undo round trip against FIXTUREDOC02

    func testBlockCommandsPassTheUndoRoundTripOnTheFixtureTextDocument() async throws {
        let insert: JSONValue = ["doc": "doc:FIXTUREDOC02", "after": "block:FIXTUREDOC02/FIXTUREBLK02", "kind": "todo",
                                 "text": "Revise", "id": "ROUNDTRIP01"]
        let update: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "kind": "quote", "text": "Quoted", "indent": 2]
        let delete: JSONValue = ["refs": ["block:FIXTUREDOC02/FIXTUREBLK01", "block:FIXTUREDOC02/FIXTUREBLK03"]]
        let move: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK03", "after": "doc:FIXTUREDOC02"]
        let calls: [(String, JSONValue)] = [("block.insert", insert), ("block.update", update),
                                            ("block.delete", delete), ("block.move", move)]
        for (command, params) in calls {
            let h = harness()
            let before = try h.snapshot(doc)
            let depth = h.undoDepth(doc)
            try await h.run(command, params)
            XCTAssertNotEqual(try h.snapshot(doc), before, command)
            XCTAssertEqual(h.undoDepth(doc), depth + 1, "\(command) is one undo step")
            XCTAssertTrue(h.app.bus.undo(doc), command)
            XCTAssertEqual(try h.snapshot(doc), before, "\(command) undo")
            XCTAssertTrue(h.app.bus.redo(doc), command)
            XCTAssertNotEqual(try h.snapshot(doc), before, "\(command) redo")
        }
    }

    // MARK: Order

    func testInsertGoesAfterTheAnchorAtTheTopOrAtTheEnd() async throws {
        let h = harness()
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "paragraph", "text": "end", "id": "ENDBLOCK"])
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "after": "doc:FIXTUREDOC02", "kind": "heading1",
                                         "text": "top", "id": "TOPBLOCK"])
        let r = try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "after": .string(heading), "kind": "bullet",
                                                 "text": "middle", "id": "MIDBLOCK"])
        XCTAssertEqual(r["ref"]?.stringValue, "block:FIXTUREDOC02/MIDBLOCK")
        XCTAssertEqual(try ids(h), ["TOPBLOCK", "FIXTUREBLK01", "MIDBLOCK", "FIXTUREBLK02", "FIXTUREBLK03", "ENDBLOCK"])
        XCTAssertEqual(try block(h, "MIDBLOCK").text.plainText, "middle")
    }

    func testMovePlacesTheBlockAfterTheAnchorOrOnTopAndSkipsNoOps() async throws {
        let h = harness()
        try await h.run("block.move", ["ref": .string(heading), "after": .string(table)])
        XCTAssertEqual(try ids(h), ["FIXTUREBLK02", "FIXTUREBLK03", "FIXTUREBLK01"])
        try await h.run("block.move", ["ref": .string(table)])
        XCTAssertEqual(try ids(h), ["FIXTUREBLK03", "FIXTUREBLK02", "FIXTUREBLK01"])
        let depth = h.undoDepth(doc)
        try await h.run("block.move", ["ref": .string(table), "after": "doc:FIXTUREDOC02"])
        XCTAssertEqual(h.undoDepth(doc), depth, "moving a block to where it is records nothing")
    }

    func testOrderKeysStayBetweenNeighboursEvenWithDuplicateKeys() throws {
        var a = TextBlock(id: "AAAA", kind: .paragraph, order: "k")
        var b = TextBlock(id: "BBBB", kind: .paragraph, order: "k")
        let c = TextBlock(id: "CCCC", kind: .paragraph, order: "t")
        a.rev = .zero
        b.rev = .zero
        let key = try BlockRules.orderKey(after: "block:D/AAAA", doc: "D", live: [a, b, c], moving: nil, whenOmitted: .end)
        XCTAssertGreaterThan(key, "k")
        XCTAssertLessThan(key, "t")
        let top = try BlockRules.orderKey(after: nil, doc: "D", live: [a, b, c], moving: nil, whenOmitted: .start)
        XCTAssertLessThan(top, "k")
    }

    // MARK: Kinds and payloads

    func testTurnIntoMovesContentBetweenKinds() async throws {
        let h = harness()
        try await h.run("block.update", ["ref": .string(paragraph), "kind": "todo"])
        XCTAssertEqual(try block(h, "FIXTUREBLK02").checked, false)
        try await h.run("block.update", ["ref": .string(paragraph), "checked": true])
        XCTAssertEqual(try block(h, "FIXTUREBLK02").checked, true)
        try await h.run("block.update", ["ref": .string(paragraph), "kind": "image"])
        var b = try block(h, "FIXTUREBLK02")
        XCTAssertNil(b.checked)
        XCTAssertTrue(b.text.isEmpty)
        XCTAssertEqual(b.caption?.plainText, "Hello blocks", "text becomes the caption")
        try await h.run("block.update", ["ref": .string(paragraph), "kind": "paragraph"])
        b = try block(h, "FIXTUREBLK02")
        XCTAssertEqual(b.text.plainText, "Hello blocks")
        XCTAssertNil(b.caption)
        XCTAssertEqual(b.comments?.count, 1, "comments survive Turn Into")

        try await h.run("block.update", ["ref": .string(table), "kind": "paragraph"])
        b = try block(h, "FIXTUREBLK03")
        XCTAssertNil(b.table)
        XCTAssertEqual(b.text.plainText, "A1\tB1\nA2\tB2")
        try await h.run("block.update", ["ref": .string(table), "kind": "table"])
        b = try block(h, "FIXTUREBLK03")
        XCTAssertEqual(b.table?.rows.count, 3)
        XCTAssertTrue(b.text.isEmpty)
    }

    func testInsertAppliesKindDefaults() async throws {
        let h = harness()
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "table", "text": "Header", "id": "TABLE2"])
        let t = try block(h, "TABLE2")
        XCTAssertEqual(t.table?.rows.count, 3)
        XCTAssertEqual(t.table?.rows.first?.count, 3)
        XCTAssertEqual(t.table?.rows[0][0].text.plainText, "Header")
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "divider", "text": "ignored", "id": "RULE1"])
        XCTAssertTrue(try block(h, "RULE1").text.isEmpty)
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "video", "url": " https://example.com/v.mp4 ",
                                         "text": "Lecture", "id": "VIDEO1"])
        let v = try block(h, "VIDEO1")
        XCTAssertEqual(v.url, "https://example.com/v.mp4")
        XCTAssertEqual(v.caption?.plainText, "Lecture")
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "image", "id": "EMPTYIMG"])
        XCTAssertNil(try block(h, "EMPTYIMG").asset, "an image block may wait for its image")
    }

    func testImageURLIsStoredAsADocumentAsset() async throws {
        let h = harness()
        let upload = try h.assets.putTemporary(Fixtures.pngData, ext: "png")
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "image", "url": .string("tmp:" + upload.name),
                                         "caption": "Cell diagram", "id": "IMGBLOCK1"])
        let b = try block(h, "IMGBLOCK1")
        let asset = try XCTUnwrap(b.asset)
        XCTAssertEqual(asset.ext, "png")
        XCTAssertEqual(try h.assets.data(asset, doc: doc), Fixtures.pngData)
        XCTAssertEqual(b.caption?.plainText, "Cell diagram")

        let text = try h.assets.putTemporary(Data("not an image".utf8), ext: "txt")
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": "block:FIXTUREDOC02/IMGBLOCK1", "url": .string("tmp:" + text.name)])
        }
    }

    func testInvalidCallsAreRefusedWithCodesAndPaths() async throws {
        let h = harness()
        await assertError(.invalidParams) {
            _ = try await h.run("block.insert", ["doc": "doc:FIXTUREDOC01", "kind": "paragraph"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "custom"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": .string(paragraph), "checked": true])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": .string(paragraph)])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": .string(heading), "kind": "custom"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "video", "url": "ftp://example.com/a"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.move", ["ref": .string(heading), "after": .string(heading)])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "paragraph", "id": "FIXTUREBLK01"])
        }
        await assertError(.notFound) {
            _ = try await h.run("block.delete", ["refs": ["block:FIXTUREDOC02/NOSUCHBLOCK"]])
        }
        await assertError(.notFound) {
            _ = try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "image", "asset": "missing.png"])
        }
        XCTAssertEqual(try ids(h), ["FIXTUREBLK01", "FIXTUREBLK02", "FIXTUREBLK03"], "failed calls change nothing")
    }

    func testPluginsCreateOnlyTheirOwnCustomBlocks() async throws {
        let h = harness()
        h.app.gateway.grants = { _ in Set(Scope.allCases) }
        let display: JSONValue = ["ops": [["op": "rect", "rect": [0, 0, 100, 40], "stroke": "#000000"]]]
        let mine: JSONValue = ["doc": "doc:FIXTUREDOC02", "kind": "custom", "id": "CUSTOM1",
                               "custom": ["owner": "dev.nib.charts", "type": "bar", "height": 80, "display": display]]
        try await h.run("block.insert", mine, as: .plugin("dev.nib.charts"))
        let c = try XCTUnwrap(try block(h, "CUSTOM1").custom)
        XCTAssertEqual(c.height, 80)
        XCTAssertEqual(c.display.ops.count, 1)
        XCTAssertEqual(try block(h, "CUSTOM1").custom?.owner, "dev.nib.charts")

        let theirs: JSONValue = ["doc": "doc:FIXTUREDOC02", "kind": "custom",
                                 "custom": ["owner": "someone.else", "type": "bar"]]
        await assertError(.permissionDenied) {
            _ = try await h.run("block.insert", theirs, as: .plugin("dev.nib.charts"))
        }
    }

    func testDuplicateMenuEntryCopiesTheBlockBelowInOneUndoStep() async throws {
        let h = harness()
        try await h.run("block.update", ["ref": .string(paragraph), "kind": "todo", "checked": true, "indent": 2])
        let ctx = MenuContext(app: h.app, session: h.session, doc: doc, ref: paragraph)
        let item = try XCTUnwrap(h.app.ui.menuItems(.block, ctx).first { $0.id == "textdoc.block.duplicate" })
        let depth = h.undoDepth(doc)
        try await h.run(item.command, item.params(ctx))
        let blocks = try live(h)
        XCTAssertEqual(blocks.count, 4)
        let copy = blocks[2]
        XCTAssertNotEqual(copy.id, Fixtures.paragraphBlockID)
        XCTAssertEqual(copy.kind, .todo)
        XCTAssertEqual(copy.checked, true)
        XCTAssertEqual(copy.indent, 2)
        XCTAssertEqual(copy.text.plainText, "Hello blocks")
        XCTAssertEqual(h.undoDepth(doc), depth + 1)

        let headingCtx = MenuContext(app: h.app, session: h.session, doc: doc, ref: heading)
        let visible = Set(h.app.ui.menuItems(.block, headingCtx).map { $0.id })
        XCTAssertFalse(visible.contains("textdoc.block.moveUp"), "the first block cannot move up")
        XCTAssertTrue(visible.contains("textdoc.block.moveDown"))
        XCTAssertFalse(visible.contains("textdoc.block.check"))
        h.session.readOnly = true
        XCTAssertTrue(h.app.ui.menuItems(.block, headingCtx).isEmpty, "read-only documents offer no edits")
    }

    // MARK: Text model

    func testSplitAndJoinWorkInUTF16Offsets() {
        let text = RichText(paragraphs: [
            Paragraph(runs: [TextRun("Hel"), TextRun("lo", TextAttributes(bold: true))]),
            Paragraph(runs: [TextRun("a\u{1D11E}b")])
        ])
        let (head, tail) = BlockText.split(text, at: 4)
        XCTAssertEqual(head.plainText, "Hell")
        XCTAssertEqual(tail.plainText, "o\na\u{1D11E}b")
        XCTAssertEqual(tail.paragraphs[0].runs.first?.attrs.bold, true)
        XCTAssertEqual(BlockText.join(head, tail), text)

        let atEnd = BlockText.split(text, at: 5)
        XCTAssertEqual(atEnd.head.plainText, "Hello")
        XCTAssertEqual(BlockText.join(atEnd.head, atEnd.tail), text)

        let surrogate = BlockText.split(text, at: 9)
        XCTAssertEqual(surrogate.head.plainText, "Hello\na\u{1D11E}")
        XCTAssertEqual(surrogate.tail.plainText, "b")
        XCTAssertEqual(BlockText.length(text), 10)

        let beyond = BlockText.split(text, at: 99)
        XCTAssertEqual(beyond.head, text)
        XCTAssertTrue(beyond.tail.isEmpty)
    }

    func testStyleRoundTripStoresOnlyWhatTheUserChose() {
        let rich = RichText(paragraphs: [
            Paragraph(runs: [TextRun("Plain "), TextRun("bold", TextAttributes(bold: true)), TextRun(" end")]),
            Paragraph(runs: [TextRun("second", TextAttributes(italic: true)), TextRun(" line", TextAttributes(underline: true))])
        ])
        for kind in [BlockKind.paragraph, .heading1, .heading3, .quote, .todo, .bullet] {
            let style = BlockStyle.make(kind: kind)
            XCTAssertEqual(style.richText(from: style.attributed(rich)), style.normalize(rich), kind.rawValue)
        }
        let code = BlockStyle.make(kind: .code)
        let snippet = RichText(paragraphs: [Paragraph(runs: [TextRun("let x = "), TextRun("1", TextAttributes(bold: true))])])
        XCTAssertEqual(code.richText(from: code.attributed(snippet)), code.normalize(snippet))

        // The heading's size and weight are the kind's, not the text's: nothing of them is stored.
        let h1 = BlockStyle.make(kind: .heading1)
        let stored = h1.richText(from: h1.attributed(RichText(plain: "Cells")))
        XCTAssertEqual(stored, RichText(plain: "Cells"))
        // A checked to-do is dimmed on screen only.
        let done = BlockStyle.make(kind: .todo, checked: true)
        XCTAssertEqual(done.richText(from: done.attributed(RichText(plain: "Done"))), RichText(plain: "Done"))
        // Paragraph list markers never enter a block's text.
        var listed = RichText(plain: "item")
        listed.paragraphs[0].list = .bullet
        XCTAssertEqual(BlockStyle.make(kind: .paragraph).attributed(listed).string, "item")
    }

    func testListMarkersNestAndRestart() {
        func b(_ id: String, _ kind: BlockKind, _ indent: Int = 0) -> TextBlock {
            var t = TextBlock(id: NibID(id), kind: kind)
            t.indent = indent == 0 ? nil : indent
            return t
        }
        let blocks = [b("N1", .numbered), b("N2", .numbered), b("N3", .numbered, 1), b("N4", .numbered, 1),
                      b("N5", .numbered), b("P1", .paragraph), b("N6", .numbered), b("B1", .bullet), b("B2", .bullet, 1),
                      b("B3", .bullet, 2), b("B4", .bullet, 3)]
        let m = BlockSnapshotPlan.markers(blocks)
        XCTAssertEqual(["N1", "N2", "N3", "N4", "N5", "N6"].map { m[NibID($0)] }, ["1.", "2.", "1.", "2.", "3.", "1."])
        XCTAssertNil(m[NibID("P1")])
        XCTAssertEqual(["B1", "B2", "B3", "B4"].map { m[NibID($0)] }, ["\u{2022}", "\u{25E6}", "\u{25AA}", "\u{2022}"])
    }

    func testSnapshotPlanReconfiguresOnlyWhatChanged() {
        func b(_ id: String, _ kind: BlockKind, _ text: String) -> TextBlock {
            TextBlock(id: NibID(id), kind: kind, text: RichText(plain: text))
        }
        let old = [b("A", .paragraph, "a"), b("B", .numbered, "b"), b("C", .numbered, "c"), b("A", .paragraph, "dup")]
        let first = BlockSnapshotPlan(blocks: old, previous: [:], previousMarkers: [:], previousFirst: nil)
        XCTAssertEqual(first.ids.map { $0.raw }, ["A", "B", "C"], "duplicate ids are dropped")
        XCTAssertTrue(first.reconfigure.isEmpty)

        // Editing A and inserting a numbered block before B renumbers B and C.
        let new = [b("A", .paragraph, "a2"), b("X", .numbered, "x"), b("B", .numbered, "b"), b("C", .numbered, "c")]
        let second = BlockSnapshotPlan(blocks: new, previous: first.byID, previousMarkers: first.markers, previousFirst: first.ids.first)
        XCTAssertEqual(Set(second.reconfigure.map { $0.raw }), ["A", "B", "C"])
        XCTAssertEqual(second.markers[NibID("C")], "3.")
        XCTAssertEqual(second.indexByID[NibID("B")], 2)
    }

    func testTextInFlightSurvivesAnOlderCommit() {
        let model = [TextBlock(id: "A", kind: .paragraph, text: RichText(plain: "Ce")),
                     TextBlock(id: "B", kind: .paragraph, text: RichText(plain: "b"))]
        var typed = TextBlock(id: "A", kind: .paragraph, text: RichText(plain: "Cells"))
        XCTAssertEqual(BlockOverlay.keepLocalText(model, local: [typed.id: typed], pending: []), model)
        let shown = BlockOverlay.keepLocalText(model, local: [typed.id: typed], pending: [typed.id])
        XCTAssertEqual(shown.map { $0.text.plainText }, ["Cells", "b"], "the newer keystrokes stay on screen")
        typed.kind = .heading1
        XCTAssertEqual(BlockOverlay.keepLocalText(model, local: [typed.id: typed], pending: [typed.id]), model,
                       "when the kinds differ the model wins")
    }

    func testTitleComesFromTheFirstLineOfText() {
        var image = TextBlock(id: "IMG", kind: .image)
        image.caption = RichText(plain: "A caption is not a title")
        let blocks = [image, TextBlock(id: "H", kind: .heading1),
                      TextBlock(id: "P", kind: .paragraph, text: RichText(plain: "  Cells: the basics / intro\nSecond line"))]
        XCTAssertEqual(TextDocTitle.derive(from: blocks), "Cells- the basics - intro")
        XCTAssertNil(TextDocTitle.derive(from: [TextBlock(id: "D", kind: .divider), TextBlock(id: "E", kind: .paragraph)]))
        XCTAssertEqual(TextDocTitle.sanitize("..hidden \t  name"), "hidden name")
        XCTAssertEqual(TextDocTitle.sanitize(String(repeating: "a", count: 200)).count, TextDocTitle.maxLength)
    }

    func testUpdateSetsVideoLinksAndStoredImagesAndRefusesTextWithoutAPlace() async throws {
        let h = harness()
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "video", "id": "VIDEO2"])
        try await h.run("block.update", ["ref": "block:FIXTUREDOC02/VIDEO2", "url": "https://example.com/talk.mp4"])
        XCTAssertEqual(try block(h, "VIDEO2").url, "https://example.com/talk.mp4")
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": "block:FIXTUREDOC02/VIDEO2", "url": "javascript:alert(1)"])
        }
        XCTAssertEqual(try block(h, "VIDEO2").url, "https://example.com/talk.mp4", "a refused link changes nothing")

        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "image", "id": "IMAGE2"])
        try await h.run("block.update", ["ref": "block:FIXTUREDOC02/IMAGE2", "asset": "fixture-image.png", "caption": "Cell"])
        let image = try block(h, "IMAGE2")
        XCTAssertEqual(image.asset, Fixtures.pngAsset)
        XCTAssertEqual(image.caption?.plainText, "Cell")
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": "block:FIXTUREDOC02/IMAGE2", "asset": "../fixture-image.png"])
        }
        await assertError(.notFound) {
            _ = try await h.run("block.update", ["ref": "block:FIXTUREDOC02/IMAGE2", "asset": "missing.png"])
        }

        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "divider", "id": "RULE2"])
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": "block:FIXTUREDOC02/RULE2", "text": "no place for this"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.update", ["ref": .string(table), "text": "cells hold table text"])
        }
        XCTAssertEqual(try block(h, "FIXTUREBLK03").table?.rows[0][0].text.plainText, "A1")
    }

    func testOnlyWebLinksAreShownOrOpened() throws {
        XCTAssertEqual(BlockMedia.webURL(" https://example.com/v.mp4 ")?.absoluteString, "https://example.com/v.mp4")
        XCTAssertNotNil(BlockMedia.webURL("http://example.com/v"))
        XCTAssertNil(BlockMedia.webURL("javascript:alert(1)"))
        XCTAssertNil(BlockMedia.webURL("file:///private/var/mobile/secret.mov"))
        XCTAssertNil(BlockMedia.webURL("nib://open?doc=FIXTUREDOC01"))

        // A link that reached the block without block.update (sync, node.set) is not offered.
        let h = harness()
        let editor = openEditor(h)
        var video = TextBlock(id: "VIDEO3", kind: .video)
        video.url = "javascript:alert(1)"
        XCTAssertFalse(titles(editor.blockMenu(for: video)).contains("Open Video"))
        video.url = "https://example.com/lecture.mp4"
        XCTAssertTrue(titles(editor.blockMenu(for: video)).contains("Open Video"))
    }

    func testMoveMenuStepsOneBlockAndStaysPutAtTheEdges() async throws {
        let h = harness()
        func params(_ ref: String, up: Bool) -> JSONValue {
            TextDocMenus.moveParams(MenuContext(app: h.app, session: h.session, doc: doc, ref: ref), up: up)
        }
        XCTAssertEqual(params(heading, up: false)["after"]?.stringValue, paragraph)
        XCTAssertEqual(params(paragraph, up: true)["after"]?.stringValue, "doc:FIXTUREDOC02")
        XCTAssertEqual(params(paragraph, up: false)["after"]?.stringValue, table)
        XCTAssertEqual(params(table, up: true)["after"]?.stringValue, heading)
        for (ref, up) in [(heading, true), (table, false)] {
            let depth = h.undoDepth(doc)
            try await h.run("block.move", params(ref, up: up))
            XCTAssertEqual(try ids(h), ["FIXTUREBLK01", "FIXTUREBLK02", "FIXTUREBLK03"], "\(ref) stays at the edge")
            XCTAssertEqual(h.undoDepth(doc), depth)
        }
        try await h.run("block.move", params(paragraph, up: false))
        XCTAssertEqual(try ids(h), ["FIXTUREBLK01", "FIXTUREBLK03", "FIXTUREBLK02"])
        try await h.run("block.move", params(paragraph, up: true))
        XCTAssertEqual(try ids(h), ["FIXTUREBLK01", "FIXTUREBLK02", "FIXTUREBLK03"])
    }

    // MARK: Editor

    func testAnEmbeddedViewFollowsItsBlockAcrossReusedCells() {
        let host = StubCellHost()
        let tableBlock = TextBlock(id: "TABLEBLK", kind: .table)
        let text = TextBlock(id: "TEXTBLK", kind: .paragraph, text: RichText(plain: "Text"))
        let a = BlockCell(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let b = BlockCell(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        a.host = host
        b.host = host

        a.configure(tableBlock, environment: environment(.table))
        XCTAssertTrue(host.tableView.isDescendant(of: a.contentView))
        // The table scrolls off and comes back in another cell.
        b.configure(tableBlock, environment: environment(.table))
        XCTAssertTrue(host.tableView.isDescendant(of: b.contentView))
        XCTAssertFalse(host.tableView.isDescendant(of: a.contentView))
        // ...and later in the first cell again, which still remembers having shown it.
        a.configure(tableBlock, environment: environment(.table))
        XCTAssertTrue(host.tableView.isDescendant(of: a.contentView), "the view is attached again, not left in the other cell")

        // A reused cell gives the view back, and another block never takes it along.
        a.prepareForReuse()
        XCTAssertNil(host.tableView.superview)
        a.configure(text, environment: environment(.paragraph))
        b.configure(tableBlock, environment: environment(.table))
        XCTAssertTrue(host.tableView.isDescendant(of: b.contentView))
        XCTAssertFalse(host.tableView.isDescendant(of: a.contentView))
    }

    func testCustomBlockViewsAreMadeAgainWhenTheirPayloadChanges() async throws {
        let h = harness()
        var made = 0
        h.app.ui.blockViews.register(BlockViewDescriptor(customType: "dev.nib.charts.bar", owner: "dev.nib.charts") { _ in
            made += 1
            return UIView()
        })
        var tables = 0
        h.app.ui.blockViews.register(BlockViewDescriptor(kind: .table, owner: "tables") { _ in
            tables += 1
            return UIView()
        })
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "custom", "id": "CHART1",
                                         "custom": ["owner": "dev.nib.charts", "type": "bar", "data": ["v": 1]]])
        let editor = openEditor(h)
        let chart = try XCTUnwrap(editor.block(NibID("CHART1")))
        let first = try XCTUnwrap(editor.embeddedView(for: chart))
        XCTAssertTrue(editor.embeddedView(for: chart) === first, "an unchanged block keeps its view")
        XCTAssertEqual(made, 1)

        var changed = chart
        changed.custom?.data = ["v": 2]
        let second = try XCTUnwrap(editor.embeddedView(for: changed))
        XCTAssertFalse(second === first, "new data, new view")
        XCTAssertEqual(made, 2)

        var turned = changed
        turned.kind = .paragraph
        turned.custom = nil
        XCTAssertNil(editor.embeddedView(for: turned))
        XCTAssertEqual(made, 2)

        // Tables watch their own data: their view stays.
        let tableBlock = try XCTUnwrap(editor.block(Fixtures.tableBlockID))
        let tableView = try XCTUnwrap(editor.embeddedView(for: tableBlock))
        var edited = tableBlock
        edited.table?.rows[0][0].text = RichText(plain: "Z1")
        XCTAssertTrue(editor.embeddedView(for: edited) === tableView)
        XCTAssertEqual(tables, 1)
    }

    func testTextSelectionMenuEntriesAppearOverSelectedBlockText() throws {
        let h = harness()
        var define = MenuItemDescriptor(
            id: "test.define", title: "Define Word", location: .textSelection, order: 1, owner: "test",
            command: "block.update", isVisible: { ctx in ctx.ref == "block:FIXTUREDOC02/FIXTUREBLK02" })
        define.contextTitle = { ctx in ctx.textRange == [0, 5] ? "Define Word" : "Wrong Range" }
        h.app.ui.menus.register(define)
        let editor = openEditor(h)
        let tv = BlockTextView()
        tv.blockID = Fixtures.paragraphBlockID
        let style = BlockStyle.make(kind: .paragraph)
        tv.style = style
        tv.attributedText = style.attributed(RichText(plain: "Hello blocks"))

        let menu = try XCTUnwrap(editor.textView(tv, editMenuForTextIn: NSRange(location: 0, length: 5), suggestedActions: []))
        XCTAssertTrue(titles(menu).contains("Define Word"), "entries get the block and the selected range")
        XCTAssertNil(editor.textView(tv, editMenuForTextIn: NSRange(location: 2, length: 0), suggestedActions: []),
                     "a caret without a selection keeps the system menu")
        tv.role = .caption
        let caption = try XCTUnwrap(editor.textView(tv, editMenuForTextIn: NSRange(location: 0, length: 5), suggestedActions: []))
        XCTAssertTrue(titles(caption).contains("Define Word"), "captions offer them too, for their block")
        tv.blockID = Fixtures.headingBlockID
        XCTAssertNil(editor.textView(tv, editMenuForTextIn: NSRange(location: 0, length: 5), suggestedActions: []),
                     "entries see the block they are for")
    }

    func testTheNameFollowsTheFirstLineUntilTheUserRenamesTheDocument() async throws {
        let h = harness()
        registerRename(h)
        try h.library.rename(doc, to: "Fixture Text")
        let editor = TextDocViewController(doc: doc, session: h.session, app: h.app)
        editor.titleDebounce = 0.05
        editor.loadViewIfNeeded()
        XCTAssertTrue(editor.followsFirstLine)

        try await h.run("block.update", ["ref": .string(heading), "text": "Cell biology"])
        try await waitUntil("the automatic rename") { h.library.node(doc)?.title == "Cell biology" }
        XCTAssertEqual(h.app.settings.get(TextDocTitle.settingKey(doc)), "Cell biology")

        // Renamed by hand: the name is the user's from now on, here and on the next open.
        try h.library.rename(doc, to: "Biology notes")
        try await h.run("block.update", ["ref": .string(heading), "text": "Cells"])
        try await waitUntil("automatic naming to stop") { !editor.followsFirstLine }
        XCTAssertEqual(h.library.node(doc)?.title, "Biology notes")
        XCTAssertEqual(h.app.settings.get(TextDocTitle.settingKey(doc)), "")
        XCTAssertFalse(openEditor(h).followsFirstLine)
    }

    func testAnAutomaticNameCatchesUpWithEditsMadeWhileTheDocumentWasClosed() async throws {
        let h = harness()
        registerRename(h)
        // The editor gave this name last time; the first line changed since (AI chat, bridge, another device).
        h.app.settings.set(TextDocTitle.settingKey(doc), "Fixture Text Document")
        let editor = openEditor(h)
        XCTAssertTrue(editor.followsFirstLine)
        try await waitUntil("the catch-up rename") { h.library.node(doc)?.title == "Fixture Text" }

        // A name nobody gave automatically is left alone.
        let other = harness()
        registerRename(other)
        XCTAssertFalse(openEditor(other).followsFirstLine)
        XCTAssertEqual(other.library.node(doc)?.title, "Fixture Text Document")
    }

    func testHookCommandsAndUndoWaitForQueuedEdits() async throws {
        let h = harness()
        let editor = openEditor(h)
        let before = try h.snapshot(doc)
        let output = await editor.run(BlockUpdate.self, BlockUpdate.Params(ref: paragraph, text: RichText(plain: "Edited")))
        XCTAssertNotNil(output)
        XCTAssertEqual(try block(h, "FIXTUREBLK02").text.plainText, "Edited")
        editor.undoDocument()
        await editor.flushEdits()
        XCTAssertEqual(try h.snapshot(doc), before)
        editor.redoDocument()
        await editor.flushEdits()
        XCTAssertEqual(try block(h, "FIXTUREBLK02").text.plainText, "Edited")
    }

    func testAProposalChangesNothingUntilAcceptedAndIsThenOneUndoStep() async throws {
        let h = harness()
        let editor = openEditor(h)
        let id = Fixtures.paragraphBlockID
        let before = try h.snapshot(doc)
        editor.showProposal(BlockProposal(title: "Make Concise", text: "Hi blocks\n\nA second thought", replaces: true), for: id)
        XCTAssertNotNil(editor.proposals[id])
        await editor.flushEdits()
        XCTAssertEqual(try h.snapshot(doc), before, "a proposal is only a preview")

        let depth = h.undoDepth(doc)
        editor.resolveProposal(for: id, .replace)
        await editor.flushEdits()
        XCTAssertNil(editor.proposals[id])
        let blocks = try live(h)
        XCTAssertEqual(blocks.map { $0.text.plainText }, ["Fixture Text", "Hi blocks", "A second thought", ""])
        XCTAssertEqual(blocks[2].kind, .paragraph)
        XCTAssertEqual(h.undoDepth(doc), depth + 1, "Replace is one undo step")
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(doc), before)

        editor.showProposal(BlockProposal(title: "Explain", text: "An answer", replaces: false), for: id)
        editor.resolveProposal(for: id, .discard)
        await editor.flushEdits()
        XCTAssertEqual(try h.snapshot(doc), before, "Discard changes nothing")

        editor.showProposal(BlockProposal(title: "Explain", text: "An answer", replaces: false), for: id)
        editor.resolveProposal(for: id, .insertBelow)
        await editor.flushEdits()
        XCTAssertEqual(try live(h).map { $0.text.plainText }, ["Fixture Text", "Hello blocks", "An answer", ""])
    }

    func testAssistantAnswersBecomeCleanParagraphs() {
        XCTAssertEqual(BlockAssistant.clean("  Shorter text.  \n"), "Shorter text.")
        XCTAssertEqual(BlockAssistant.clean("```\nlet x = 1\n```"), "let x = 1")
        XCTAssertEqual(BlockAssistant.clean("```swift\nlet x = 1\nlet y = 2\n```"), "let x = 1\nlet y = 2")
        XCTAssertEqual(BlockAssistant.clean("Use ```code``` here"), "Use ```code``` here")
        XCTAssertEqual(BlockAssistant.paragraphs(" One \n\n Two\n"), ["One", "Two"])
    }

    func testInlineImagesLeaveTheTextToBecomeImageBlocks() throws {
        let tv = UITextView()
        let text = NSMutableAttributedString(string: "ab")
        let attachment = NSTextAttachment()
        attachment.image = UIImage(data: Fixtures.pngData)
        text.insert(NSAttributedString(attachment: attachment), at: 1)
        tv.attributedText = text
        let images = BlockAttachments.takeImages(from: tv)
        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(BlockMedia.imageExtension(images[0]), "the image's bytes survive")
        XCTAssertEqual(tv.text, "ab")
        XCTAssertTrue(BlockAttachments.takeImages(from: tv).isEmpty)
        let removed = [NSRange(location: 0, length: 2), NSRange(location: 5, length: 1)]
        XCTAssertEqual(BlockAttachments.caretAfterRemoving(removed, caret: 4, length: 10), 2)
        XCTAssertEqual(BlockAttachments.caretAfterRemoving(removed, caret: 1, length: 10), 0)
        XCTAssertEqual(BlockAttachments.caretAfterRemoving(removed, caret: 9, length: 7), 6)
    }

    // MARK: Hooks

    func testHooksAreKeyedOrderedAndRemovable() {
        TextDocHooks.removeAll(prefix: "test.")
        TextDocHooks.addKeyCommandSet("test.b", order: 2) { _ in [] }
        TextDocHooks.addKeyCommandSet("test.a", order: 1) { _ in [] }
        TextDocHooks.addKeyCommandSet("test.a", order: 3) { _ in [] }
        let mine = TextDocHooks.keyCommandSets.filter { $0.id.hasPrefix("test.") }
        XCTAssertEqual(mine.map { $0.id }, ["test.b", "test.a"], "re-registering an id replaces it")
        TextDocHooks.removeAll(prefix: "test.")
        XCTAssertTrue(TextDocHooks.keyCommandSets.filter { $0.id.hasPrefix("test.") }.isEmpty)
    }

    // MARK: Acceptance: 1,000-block snapshot

    func testApplyingAThousandBlockSnapshotIsFast() throws {
        let h = harness()
        let id: DocumentID = "PERFTEXTDOC1"
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: id, kind: .textDocument)),
                                         title: "Long document", in: nil)
        let blocks: [TextBlock] = (0..<1000).map { i in
            let kind: BlockKind = i % 10 == 0 ? .heading2 : (i % 3 == 0 ? .numbered : .paragraph)
            return TextBlock(id: NibID("PERFBLK\(i)"), kind: kind, text: RichText(plain: "Line \(i) of a long document"),
                             order: String(format: "K%05dV", i))
        }
        let editor = TextDocViewController(doc: id, session: h.session, app: h.app)
        editor.loadViewIfNeeded()

        var start = CFAbsoluteTimeGetCurrent()
        editor.applyBlocks(blocks)
        let insertAll = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(editor.blocks.count, 1000)

        // A remote patch that touches every block (reconfigure path).
        let edited = blocks.map { b -> TextBlock in
            var b = b
            b.text = RichText(plain: b.text.plainText + " (edited)")
            return b
        }
        start = CFAbsoluteTimeGetCurrent()
        editor.applyBlocks(edited)
        let reconfigureAll = CFAbsoluteTimeGetCurrent() - start

        // Budget 200 ms, asserted at 4x for CI simulators (ARCHITECTURE §15.10).
        XCTAssertLessThan(insertAll, 0.2 * 4)
        XCTAssertLessThan(reconfigureAll, 0.2 * 4)
    }
}

/// A cell host that hands out one shared table view, like the editor's per-block cache does.
@MainActor
private final class StubCellHost: BlockCellHost {
    let tableView = UIView()
    var documentID: DocumentID { Fixtures.textDocID }
    var assetStore: AssetStore? { nil }
    func loadImage(_ asset: AssetRef, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) { completion(nil) }
    func cachedAspect(_ asset: AssetRef) -> CGFloat? { nil }
    func linkMetadata(for url: URL, completion: @escaping (LPLinkMetadata) -> Void) -> LPLinkMetadata? { nil }
    func embeddedView(for block: TextBlock) -> UIView? { block.kind == .table ? tableView : nil }
    func embeddedHeight(for block: NibID) -> CGFloat? { 120 }
    func cellDidToggleCheckbox(_ cell: BlockCell) {}
    func cell(_ cell: BlockCell, addImageFrom source: BlockImageSource) {}
    func cellDidRequestVideoLink(_ cell: BlockCell) {}
    func cellDidTapCustom(_ cell: BlockCell) {}
    func aiMenuElements(for cell: BlockCell) -> [UIMenuElement] { [] }
    func accessibilityActions(for cell: BlockCell) -> [UIAccessibilityCustomAction] { [] }
    func cell(_ cell: BlockCell, resolveProposal choice: BlockProposal.Choice) {}
}
