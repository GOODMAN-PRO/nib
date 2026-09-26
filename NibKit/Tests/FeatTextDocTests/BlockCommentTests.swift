import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
@testable import FeatTextDoc

@MainActor
final class BlockCommentTests: XCTestCase {
    private let doc = Fixtures.textDocID
    private let heading = "block:FIXTUREDOC02/FIXTUREBLK01"
    private let paragraph = "block:FIXTUREDOC02/FIXTUREBLK02"
    private let table = "block:FIXTUREDOC02/FIXTUREBLK03"

    /// Both halves of the text-document module. This feature's `TextDocHooks` are static, so every test that
    /// registers it takes them out again (other test classes of the target see the editor without them).
    private func harness() -> Harness {
        removeHooksAfterTest()
        return Harness(features: [FeatTextDocFeature.self, FeatTextDocExtrasFeature.self])
    }

    private func removeHooksAfterTest() {
        addTeardownBlock {
            await MainActor.run { TextDocHooks.removeAll(prefix: TextDocExtrasHookIDs.prefix) }
        }
    }

    private func block(_ h: Harness, _ id: String) throws -> TextBlock {
        try XCTUnwrap(h.app.workspace.content(doc).liveBlocks.first { $0.id.raw == id }, "block \(id)")
    }

    private func comment(_ b: TextBlock, _ id: String) throws -> BlockComment {
        try XCTUnwrap(b.comments?.first { $0.id.raw == id }, "comment \(id)")
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

    /// Polls `condition` on the main actor until it holds (queued edits, debounced refreshes).
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

    private func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let menu = element as? UIMenu { return (menu.title.isEmpty ? [] : [menu.title]) + titles(menu.children) }
            return [element.title]
        }
    }

    private func openEditor(_ h: Harness) -> TextDocViewController {
        h.session.document = doc
        let editor = TextDocViewController(doc: doc, session: h.session, app: h.app)
        editor.loadViewIfNeeded()
        return editor
    }

    /// A block's text view outside the collection (the edit-menu delegate only reads its block and role).
    private func textView(_ block: NibID, text: String, kind: BlockKind = .paragraph) -> BlockTextView {
        let tv = BlockTextView()
        tv.blockID = block
        let style = BlockStyle.make(kind: kind)
        tv.style = style
        tv.attributedText = style.attributed(RichText(plain: text))
        return tv
    }

    /// Runs the exporter inside a read command, the way export.run hands it a context.
    private func export(_ h: Harness, _ request: ExportRequest) async throws -> [URL] {
        let exporter = try XCTUnwrap(h.app.content.exporters.get(TextDocExporter.id))
        var out: [URL] = []
        h.app.commands.register(CommandDescriptor(id: "test.exportTextDoc", title: "Export", summary: "Test export.",
                                                  effect: .read, exposure: .ui)) { _, ctx in
            out = try await exporter.handler(request, ctx)
            return .null
        }
        defer { h.app.commands.unregister(id: "test.exportTextDoc") }
        try await h.run("test.exportTextDoc")
        return out
    }

    // MARK: Registration and conformance

    func testConformance() async {
        removeHooksAfterTest()
        let problems = await CommandConformance.check(features: [FeatTextDocFeature.self, FeatTextDocExtrasFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandsExporterPanelsAndEditorHooks() throws {
        let h = harness()
        XCTAssertEqual(FeatTextDocExtrasFeature.id, "textdocextras")
        for id in ["block.comment", "block.editComment", "block.deleteComment", "block.resolveComment"] {
            let d = try XCTUnwrap(h.app.commands.descriptor(id), id)
            XCTAssertEqual(d.owner, "textdocextras", id)
            XCTAssertEqual(d.effect, .edit, id)
        }
        XCTAssertTrue(h.app.commands.descriptor("block.deleteComment")?.destructive ?? false)
        let exporter = try XCTUnwrap(h.app.content.exporters.get("textdoc.pdf"))
        XCTAssertEqual(exporter.docKinds, [.textDocument])
        XCTAssertEqual(exporter.fileExtension, "pdf")
        for id in [TextDocOutlinePanel.panelID, TextDocCommentsPanel.panelID] {
            let panel = try XCTUnwrap(h.app.ui.panels.get(id), id)
            XCTAssertEqual(panel.docKinds, [.textDocument], id)
            XCTAssertEqual(panel.placement, .sidebarTab, id)
            XCTAssertFalse(["outline.tab", "outline.bookmarks"].contains(id), "one global panel registry: no clash with F046")
        }
        XCTAssertTrue(TextDocHooks.keyCommandSets.contains { $0.id.hasPrefix(TextDocExtrasHookIDs.prefix) })
        XCTAssertTrue(TextDocHooks.editMenuProviders.contains { $0.id.hasPrefix(TextDocExtrasHookIDs.prefix) })
        XCTAssertTrue(TextDocHooks.cellDecorators.contains { $0.id.hasPrefix(TextDocExtrasHookIDs.prefix) })
    }

    // MARK: Acceptance: the undo round trip on FIXTUREBLK02

    func testCommentCommandsPassTheUndoRoundTripOnTheFixtureParagraph() async throws {
        let calls: [(String, JSONValue)] = [
            ("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Right word?", "id": "ROUNDTRIPC01"]),
            ("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "Nice start"]),
            ("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "Nice", "range": [6, 6]]),
            ("block.deleteComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01"]),
            ("block.resolveComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "resolved": true])
        ]
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

    // MARK: Commands

    func testACommentKeepsItsAuthorRangeTextAndCallerChosenID() async throws {
        let h = harness()
        h.app.settings.set(NibSettings.authorName, "  Ada  ")
        let r = try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "  Plural?  ",
                                                  "id": "MYCOMMENT01"])
        XCTAssertEqual(r["block"]?.stringValue, paragraph)
        XCTAssertEqual(r["comment"]?.stringValue, "MYCOMMENT01")
        let c = try comment(try block(h, "FIXTUREBLK02"), "MYCOMMENT01")
        XCTAssertEqual(c.author, "Ada")
        XCTAssertEqual(c.text, "Plural?")
        XCTAssertEqual([c.rangeStart, c.rangeLength], [6, 6])
        XCTAssertFalse(c.resolved)
        XCTAssertEqual(try block(h, "FIXTUREBLK02").comments?.count, 2, "the fixture's comment stays")

        // A reply is a new comment on the same range; without an id one is made.
        let reply = try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Yes"])
        let replyID = try XCTUnwrap(reply["comment"]?.stringValue)
        XCTAssertTrue(NibID.isValid(replyID))
        let threads = CommentThreads.threads(in: try block(h, "FIXTUREBLK02"))
        XCTAssertEqual(threads.map { $0.comments.count }, [1, 2])
        XCTAssertEqual(threads[1].comments.map { $0.text }, ["Plural?", "Yes"])

        // The assistant signs as the assistant.
        h.app.gateway.grants = { _ in Set(Scope.allCases) }
        try await h.run("block.comment", ["ref": .string(heading), "range": [0, 7], "text": "Shorter?", "id": "AICOMMENT01"],
                        as: .ai("chat1"))
        XCTAssertEqual(try comment(try block(h, "FIXTUREBLK01"), "AICOMMENT01").author, "Assistant")
    }

    func testInvalidCallsAreRefusedAndChangeNothing() async throws {
        let h = harness()
        let before = try h.snapshot(doc)
        await assertError(.invalidParams) { _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [10, 5], "text": "x"]) }
        await assertError(.invalidParams) { _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [3, 0], "text": "x"]) }
        await assertError(.invalidParams) { _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [3], "text": "x"]) }
        await assertError(.invalidParams) { _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [0, 2], "text": "   "]) }
        await assertError(.invalidParams) { _ = try await h.run("block.comment", ["ref": .string(table), "range": [0, 1], "text": "x"]) }
        await assertError(.invalidParams) {
            _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [0, 2], "text": "x", "id": "FIXTURECMB01"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [0, 2], "text": "x", "id": "not valid!"])
        }
        await assertError(.invalidParams) { _ = try await h.run("block.comment", ["ref": "doc:FIXTUREDOC02", "range": [0, 2], "text": "x"]) }
        await assertError(.notFound) { _ = try await h.run("block.comment", ["ref": "block:FIXTUREDOC02/NOSUCHBLOCK", "range": [0, 1], "text": "x"]) }
        await assertError(.notFound) { _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "NOPE", "text": "x"]) }
        await assertError(.notFound) { _ = try await h.run("block.deleteComment", ["ref": .string(heading), "comment": "FIXTURECMB01"]) }
        await assertError(.notFound) { _ = try await h.run("block.resolveComment", ["ref": .string(paragraph), "comment": "NOPE", "resolved": true]) }
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "x", "range": [0, 99]])
        }
        await assertError(.invalidParams) {
            let long = String(repeating: "a", count: BlockCommentRules.maxTextLength + 1)
            _ = try await h.run("block.comment", ["ref": .string(paragraph), "range": [0, 2], "text": .string(long)])
        }
        XCTAssertEqual(try h.snapshot(doc), before, "failed calls change nothing")
    }

    func testEditMovesResolvesAndDeletesWithoutEmptyUndoSteps() async throws {
        let h = harness()
        try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "Better",
                                              "range": [6, 0]])
        var c = try comment(try block(h, "FIXTUREBLK02"), "FIXTURECMB01")
        XCTAssertEqual(c.text, "Better")
        XCTAssertEqual([c.rangeStart, c.rangeLength], [6, 0], "a comment may keep an empty place (its words were deleted)")
        XCTAssertEqual(c.author, "Fixture", "editing keeps the author")

        var depth = h.undoDepth(doc)
        try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": " Better "])
        XCTAssertEqual(h.undoDepth(doc), depth, "an edit that changes nothing records nothing")

        try await h.run("block.resolveComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "resolved": true])
        c = try comment(try block(h, "FIXTUREBLK02"), "FIXTURECMB01")
        XCTAssertTrue(c.resolved)
        depth = h.undoDepth(doc)
        try await h.run("block.resolveComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "resolved": true])
        XCTAssertEqual(h.undoDepth(doc), depth, "resolving a resolved comment records nothing")

        try await h.run("block.deleteComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01"])
        XCTAssertNil(try block(h, "FIXTUREBLK02").comments, "the last comment leaves no empty list behind")
    }

    // MARK: Keeping comments on their words

    func testRangesMoveThroughEdits() {
        func moved(_ r: [Int], _ old: String, _ new: String) -> [Int] {
            guard let e = CommentAnchors.edit(from: old, to: new) else { return r }
            let m = CommentAnchors.map(NSRange(location: r[0], length: r[1]), through: e)
            return [m.location, m.length]
        }
        let old = "Hello blocks"
        XCTAssertNil(CommentAnchors.edit(from: old, to: old))
        XCTAssertEqual(CommentAnchors.edit(from: old, to: "Oh, Hello blocks"), CommentAnchors.Edit(start: 0, oldEnd: 0, newEnd: 4))
        XCTAssertEqual(moved([6, 6], old, "Oh, Hello blocks"), [10, 6], "typing before the words moves them")
        XCTAssertEqual(moved([6, 6], old, "Hello xblocks"), [7, 6], "typing at their start stays outside")
        XCTAssertEqual(moved([6, 6], old, "Hello blocks!"), [6, 6], "typing at their end stays outside")
        XCTAssertEqual(moved([6, 6], old, "Hello blo-cks"), [6, 7], "typing inside grows them")
        XCTAssertEqual(moved([0, 5], old, "Hello blocks"), [0, 5])
        XCTAssertEqual(moved([6, 6], old, "Hello "), [6, 0], "deleting the words leaves an empty place")
        // "Helocks": "lo bl" (3..<8) deleted.
        XCTAssertEqual(CommentAnchors.edit(from: old, to: "Helocks"), CommentAnchors.Edit(start: 3, oldEnd: 8, newEnd: 3))
        XCTAssertEqual(moved([0, 5], old, "Helocks"), [0, 3], "deleting across the end cuts them")
        XCTAssertEqual(moved([6, 6], old, "Helocks"), [3, 4], "deleting across the start cuts them")
        XCTAssertEqual(moved([6, 6], old, "Hello bricks"), [6, 6], "replacing inside keeps the span")
        XCTAssertEqual(moved([6, 0], old, "Hello new blocks"), [10, 0], "an empty place moves with the text after it")
        // UTF-16: an emoji is two units.
        let emoji = "a\u{1F600}b"
        XCTAssertEqual(moved([3, 1], emoji, "ab"), [1, 1])
        XCTAssertEqual(moved([0, 1], emoji, "xa\u{1F600}b"), [1, 1])

        let comments = [BlockComment(id: "C1", author: "", text: "x", rangeStart: 6, rangeLength: 6),
                        BlockComment(id: "C2", author: "", text: "y", rangeStart: 0, rangeLength: 50)]
        let rebased = CommentAnchors.rebase(comments, from: old, to: "Oh, Hello blocks")
        XCTAssertEqual(rebased.map { [$0.rangeStart, $0.rangeLength] }, [[10, 6], [4, 12]],
                       "text typed at a range's start stays outside it; ranges past the end are cut")
        XCTAssertEqual(CommentAnchors.clamp(NSRange(location: 20, length: 5), length: 12), NSRange(location: 12, length: 0))
    }

    func testCommentsFollowTheirWordsInTheSameUndoStepAsTheEdit() async throws {
        let h = harness()
        await FeatTextDocExtrasFeature.start(h.app)
        await FeatTextDocExtrasFeature.start(h.app)   // Installing twice keeps one keeper.
        let keeper = try XCTUnwrap(h.app.services.get(CommentAnchorKeeper.serviceKey, as: CommentAnchorKeeper.self))
        try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Plural?", "id": "FOLLOW01"])
        let depth = h.undoDepth(doc)

        try await h.run("block.update", ["ref": .string(paragraph), "text": "Oh, Hello blocks"])
        await keeper.idle()
        var b = try block(h, "FIXTUREBLK02")
        XCTAssertEqual(b.text.plainText, "Oh, Hello blocks")
        XCTAssertEqual(try comment(b, "FIXTURECMB01").rangeStart, 4)
        XCTAssertEqual(try comment(b, "FOLLOW01").rangeStart, 10)
        XCTAssertEqual(CommentThreads.excerpt(NSRange(location: 10, length: 6), in: b), "blocks")
        XCTAssertEqual(h.undoDepth(doc), depth + 1, "the edit and the moved comments are one undo step")

        XCTAssertTrue(h.app.bus.undo(doc))
        await keeper.idle()
        b = try block(h, "FIXTUREBLK02")
        XCTAssertEqual(b.text.plainText, "Hello blocks")
        XCTAssertEqual(try comment(b, "FIXTURECMB01").rangeStart, 0, "undo restores text and ranges together")
        XCTAssertEqual(try comment(b, "FOLLOW01").rangeStart, 6)
        XCTAssertEqual(h.undoDepth(doc), depth, "undo is not re-anchored again")

        XCTAssertTrue(h.app.bus.redo(doc))
        await keeper.idle()
        XCTAssertEqual(try comment(try block(h, "FIXTUREBLK02"), "FOLLOW01").rangeStart, 10)

        // Turning the block into an image keeps the comments where they were (the text moved to the caption).
        let kept = try block(h, "FIXTUREBLK02").comments
        try await h.run("block.update", ["ref": .string(paragraph), "kind": "image"])
        await keeper.idle()
        XCTAssertEqual(try block(h, "FIXTUREBLK02").comments, kept)
    }

    // MARK: Threads

    func testThreadsGroupRepliesAndFindTheCommentsUnderASelection() {
        var b = TextBlock(id: "B1", kind: .paragraph, text: RichText(plain: "The mitochondria is the powerhouse"))
        b.comments = [
            BlockComment(id: "R2", author: "Ben", text: "Agreed", at: 20, rangeStart: 4, rangeLength: 12),
            BlockComment(id: "T2", author: "Ada", text: "Cite this", at: 30, rangeStart: 24, rangeLength: 10),
            BlockComment(id: "T1", author: "Ada", text: "Singular?", at: 10, rangeStart: 4, rangeLength: 12),
            BlockComment(id: "X1", author: "Ada", text: "Old", at: 5, resolved: true, rangeStart: 0, rangeLength: 3)
        ]
        let threads = CommentThreads.threads(in: b)
        XCTAssertEqual(threads.map { $0.comments.map { $0.id.raw } }, [["X1"], ["T1", "R2"], ["T2"]])
        XCTAssertEqual(threads[1].replyCount, 1)
        XCTAssertTrue(threads[0].isResolved)
        XCTAssertFalse(threads[1].isResolved)
        XCTAssertEqual(CommentThreads.excerpt(threads[1].range, in: b), "mitochondria")
        XCTAssertEqual(CommentThreads.threads(in: b, touching: NSRange(location: 8, length: 0)).map { $0.id }, [threads[1].id])
        XCTAssertEqual(CommentThreads.threads(in: b, touching: NSRange(location: 16, length: 0)).count, 1, "a caret at the end touches")
        XCTAssertEqual(CommentThreads.threads(in: b, touching: NSRange(location: 17, length: 3)).count, 0)
        XCTAssertEqual(CommentThreads.threads(in: b, touching: NSRange(location: 10, length: 20)).count, 2)
        XCTAssertEqual(CommentThreads.excerpt(NSRange(location: 4, length: 0), in: b), "", "deleted words have no excerpt")
    }

    // MARK: Editor

    func testEditMenuOffersCommentsAndLinksOnlyWhereTheyApply() async throws {
        let h = harness()
        let editor = openEditor(h)
        let tv = textView(Fixtures.paragraphBlockID, text: "Hello blocks")

        var menu = titles(editor.textView(tv, editMenuForTextIn: NSRange(location: 6, length: 6), suggestedActions: [])?.children ?? [])
        XCTAssertTrue(menu.contains("Add Comment"))
        XCTAssertFalse(menu.contains("Show Comment"))
        XCTAssertTrue(menu.contains("Add Link"), "without the Links feature this menu adds web links itself")

        menu = titles(editor.textView(tv, editMenuForTextIn: NSRange(location: 2, length: 0), suggestedActions: [])?.children ?? [])
        XCTAssertTrue(menu.contains("Show Comment"), "a caret in commented words shows the comment")
        XCTAssertFalse(menu.contains("Add Comment"))

        tv.role = .caption
        XCTAssertNil(editor.textView(tv, editMenuForTextIn: NSRange(location: 0, length: 5), suggestedActions: []),
                     "captions carry no comments")
        tv.role = .body

        // A linked address: open, copy and remove it.
        try await h.run("block.update", ["ref": .string(paragraph), "text": "See https://example.com now"])
        let linked = try XCTUnwrap(AutoLinker.linked(try block(h, "FIXTUREBLK02").text))
        try await h.run("block.update", ["ref": .string(paragraph), "text": try JSONValue.from(linked)])
        try await waitUntil("the editor shows the link") { AutoLinker.links(in: editor.block(Fixtures.paragraphBlockID)?.text ?? .empty).count == 1 }
        menu = titles(editor.textView(tv, editMenuForTextIn: NSRange(location: 8, length: 0), suggestedActions: [])?.children ?? [])
        XCTAssertTrue(menu.contains("Open Link"))
        XCTAssertTrue(menu.contains("Copy Link"))
        XCTAssertTrue(menu.contains("Remove Link"))

        h.session.readOnly = true
        menu = titles(editor.textView(tv, editMenuForTextIn: NSRange(location: 0, length: 3), suggestedActions: [])?.children ?? [])
        XCTAssertFalse(menu.contains("Add Comment"), "reading only: nothing that edits")
        XCTAssertFalse(menu.contains("Add Link"))
    }

    func testBlockMenuAndKeyCommands() throws {
        let h = harness()
        let editor = openEditor(h)
        let paragraphBlock = try block(h, "FIXTUREBLK02")
        let blockMenu = titles(editor.blockMenu(for: paragraphBlock).children)
        XCTAssertTrue(blockMenu.contains("Comment on Block"))
        XCTAssertTrue(blockMenu.contains("Show Comments"))
        XCTAssertFalse(titles(editor.blockMenu(for: try block(h, "FIXTUREBLK03")).children).contains("Comment on Block"))

        let keys = editor.keyCommands ?? []
        XCTAssertTrue(keys.contains { $0.title == "Print" && $0.input == "p" && $0.modifierFlags == .command })
        XCTAssertFalse(keys.contains { $0.input == "m" }, "⇧⌘M needs a block with the caret")
        let comment = TextDocHooks.keyCommandSets.first { $0.id == TextDocExtrasHookIDs.prefix + "comments.keys" }
        XCTAssertNotNil(comment)
    }

    func testHighlightsAreDrawnNotWrittenIntoTheText() throws {
        let h = harness()
        let editor = openEditor(h)
        let cell = BlockCell(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        let b = try block(h, "FIXTUREBLK02")
        let env = BlockCell.Environment(style: BlockStyle.make(kind: .paragraph), captionStyle: BlockStyle.make(kind: .paragraph, caption: true),
                                        marker: nil, placeholder: nil, alwaysShowsPlaceholder: false, readOnly: false,
                                        accessoryWidth: 0, aiAvailable: false, isFirst: false)
        cell.configure(b, environment: env)
        BlockCommentsEditor.decorate(cell, block: b, editor: editor)
        let text = cell.textView.attributedText ?? NSAttributedString()
        var washed = false
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if v != nil { washed = true }
        }
        XCTAssertFalse(washed, "the highlight never becomes a text attribute (it would be saved as the user's)")
        XCTAssertEqual(BlockStyle.make(kind: .paragraph).richText(from: text), RichText(plain: "Hello blocks"))
        XCTAssertNotNil(cell.textView.accessibilityHint)
        XCTAssertTrue(cell.textView.accessibilityCustomActions?.contains { $0.name == "Show Comments" } ?? false)
        if let layout = cell.textView.textLayoutManager {
            var found = false
            layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attrs, _ in
                if attrs[.backgroundColor] != nil { found = true }
                return !found
            }
            XCTAssertTrue(found, "the commented words carry a drawing-only wash")
        }

        // Resolved comments are not highlighted.
        var resolved = b
        resolved.comments = b.comments?.map { c in
            var c = c
            c.resolved = true
            return c
        }
        cell.configure(resolved, environment: env)
        BlockCommentsEditor.decorate(cell, block: resolved, editor: editor)
        XCTAssertNil(cell.textView.accessibilityHint)
    }

    func testAThreadCardRepliesEditsAndResolves() async throws {
        let h = harness()
        h.session.document = doc
        let runner = TextDocCommandRunner(app: h.app, session: h.session, doc: doc)
        let thread = try XCTUnwrap(CommentThreads.threads(in: try block(h, "FIXTUREBLK02")).first)
        let model = CommentThreadModel(runner: runner, block: Fixtures.paragraphBlockID, thread: thread)
        XCTAssertEqual(model.excerpt, "Hello")

        model.reply = "Thanks"
        model.sendReply()
        try await waitUntil("the reply") { model.thread?.comments.count == 2 }
        XCTAssertEqual(model.thread?.comments.last?.text, "Thanks")
        XCTAssertEqual(model.reply, "")
        let depth = h.undoDepth(doc)

        let first = try XCTUnwrap(model.thread?.comments.first)
        model.beginEdit(first)
        model.editDraft = "Nice one"
        model.saveEdit()
        try await waitUntil("the edit") { model.thread?.comments.first?.text == "Nice one" }

        model.setResolved(true)
        try await waitUntil("resolved") { model.thread?.isResolved == true }
        XCTAssertEqual(h.undoDepth(doc), depth + 2, "resolving the two comments of a thread is one undo step")

        model.delete(first)
        try await waitUntil("the first comment gone") { model.thread?.comments.count == 1 }
        XCTAssertEqual(model.thread?.comments.first?.text, "Thanks", "the thread is found again by its reply")
    }

    func testTheCommentsTabListsOpenAndResolvedThreads() async throws {
        let h = harness()
        h.session.document = doc
        let model = CommentsPanelModel(app: h.app, session: h.session,
                                       params: ["block": .string(paragraph)])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.excerpt, "Hello")
        XCTAssertEqual(model.expandedID, model.rows.first?.id, "panel.open {block} opens that block's thread")

        model.filter = .resolved
        XCTAssertTrue(model.rows.isEmpty)
        try await h.run("block.resolveComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "resolved": true])
        try await waitUntil("the resolved thread") { model.rows.count == 1 }
        model.filter = .open
        XCTAssertTrue(model.rows.isEmpty)

        h.session.document = Fixtures.docID
        try await waitUntil("a notebook has no text comments") { model.rows.isEmpty }
    }

    // MARK: Acceptance: outline builder

    func testOutlineIsBuiltFromHeadings() {
        func b(_ id: String, _ kind: BlockKind, _ text: String = "") -> TextBlock {
            TextBlock(id: NibID(id), kind: kind, text: RichText(plain: text))
        }
        let blocks = [b("H1A", .heading1, "Intro"), b("P1", .paragraph, "text"), b("H2A", .heading2, "Background"),
                      b("H3A", .heading3, "Details"), b("H2B", .heading2, "Method"), b("H1B", .heading1, "Results"),
                      b("H3B", .heading3, "Figures"), b("P2", .paragraph, "more"), b("H2C", .heading2, "  Spaced   title\nsecond line"),
                      b("H3C", .heading3, "")]
        let entries = TextDocOutline.entries(blocks)
        XCTAssertEqual(entries.map { $0.id.raw }, ["H1A", "H2A", "H3A", "H2B", "H1B", "H3B", "H2C", "H3C"])
        XCTAssertEqual(entries.map { $0.title }, ["Intro", "Background", "Details", "Method", "Results", "Figures", "Spaced title", ""])
        XCTAssertEqual(entries.map { $0.level }, [1, 2, 3, 2, 1, 3, 2, 3])
        XCTAssertEqual(entries.map { $0.depth }, [1, 2, 3, 2, 1, 2, 2, 3], "levels never leave gaps")
        XCTAssertEqual(entries.map { $0.hasChildren }, [true, true, false, false, true, false, true, false])
        XCTAssertEqual(entries.map { $0.index }, [0, 2, 3, 4, 5, 6, 8, 9])

        let visible = TextDocOutline.visible(entries, collapsed: ["H1A", "H3B"])
        XCTAssertEqual(visible.map { $0.id.raw }, ["H1A", "H1B", "H3B", "H2C", "H3C"], "collapsing hides the sub-headings")
        XCTAssertEqual(TextDocOutline.current(entries, atBlockIndex: 1), "H1A")
        XCTAssertEqual(TextDocOutline.current(entries, atBlockIndex: 7), "H3B")
        XCTAssertNil(TextDocOutline.current(Array(entries.dropFirst()), atBlockIndex: 1), "nothing before the first heading")
        XCTAssertEqual(TextDocOutline.visibleOwner(of: "H3A", in: entries, visible: visible), "H1A")
        XCTAssertTrue(TextDocOutline.entries([b("P", .paragraph, "x")]).isEmpty)
    }

    func testTheOutlineTabFollowsTheDocumentAndChangesHeadingLevels() async throws {
        let h = harness()
        h.session.document = doc
        let model = TextDocOutlineModel(app: h.app, session: h.session)
        XCTAssertEqual(model.entries.map { $0.title }, ["Fixture Text"])
        let entry = try XCTUnwrap(model.entries.first)
        model.setLevel(entry, 2)
        try await waitUntil("the heading became an H2") { model.entries.first?.level == 2 }
        XCTAssertEqual(try block(h, "FIXTUREBLK01").kind, .heading2)
        model.setLevel(try XCTUnwrap(model.entries.first), 0)
        try await waitUntil("no heading left") { model.entries.isEmpty }
        model.addHeading()
        try await waitUntil("a new heading") { model.entries.count == 1 }
        XCTAssertEqual(try h.app.workspace.content(doc).liveBlocks.last?.kind, .heading1)
    }

    // MARK: Acceptance: auto-link detection

    func testAddressesAreDetectedAndLinkedOnce() throws {
        let text = RichText(paragraphs: [
            Paragraph(runs: [TextRun("Read "), TextRun("https://example.com/a?b=1", TextAttributes(bold: true)), TextRun(" today.")]),
            Paragraph(runs: [TextRun("Mail ada@example.org or visit www.example.com.")]),
            Paragraph(runs: [TextRun("Code: "), TextRun("https://code.example.com", TextAttributes(code: true))])
        ])
        let linked = try XCTUnwrap(AutoLinker.linked(text))
        let links = AutoLinker.links(in: linked)
        XCTAssertEqual(links.count, 3, "inline code is never linked")
        XCTAssertEqual(links[0].link.url, "https://example.com/a?b=1")
        XCTAssertEqual(links[0].range, NSRange(location: 5, length: 25))
        XCTAssertEqual(links[1].link.url, "mailto:ada@example.org")
        XCTAssertEqual(URL(string: links[2].link.url ?? "")?.host, "www.example.com")
        let plain = linked.plainText as NSString
        XCTAssertEqual(plain.substring(with: links[1].range), "ada@example.org")
        XCTAssertEqual(plain.substring(with: links[2].range), "www.example.com")
        XCTAssertEqual(linked.plainText, text.plainText, "only attributes change")
        XCTAssertEqual(linked.paragraphs[0].runs[1].attrs.bold, true, "the address keeps its own style")
        XCTAssertNil(AutoLinker.linked(linked), "linked text is left alone")
        XCTAssertNil(AutoLinker.linked(RichText(plain: "no address here")))
        let skipped = AutoLinker.linked(text, skipping: ["https://example.com/a?b=1"])
        XCTAssertEqual(skipped.map { AutoLinker.links(in: $0).count }, 2, "an address the user unlinked stays plain")

        // Links to pages and audio are never replaced.
        var page = RichText(plain: "see https://example.com")
        page = AutoLinker.setLink(TextLink(document: "FIXTUREDOC01", page: "FIXTUREPG001"), in: page,
                                  range: NSRange(location: 4, length: 19))
        XCTAssertNil(AutoLinker.linked(page))

        let unlinked = AutoLinker.setLink(nil, in: linked, range: links[0].range)
        XCTAssertEqual(AutoLinker.links(in: unlinked).count, 2)
        XCTAssertEqual(unlinked.paragraphs[0].runs.map { $0.text }, ["Read ", "https://example.com/a?b=1", " today."])

        XCTAssertEqual(AutoLinker.webURL(from: "example.com")?.absoluteString.hasPrefix("https://"), true)
        XCTAssertEqual(AutoLinker.webURL(from: " name@example.com ")?.scheme, "mailto")
        XCTAssertNil(AutoLinker.webURL(from: "not an address"))
        XCTAssertNil(AutoLinker.webURL(TextLink(document: "FIXTUREDOC01")))
    }

    func testTheEditorLinksAddressesWithBlockUpdateAndRespectsRemovedLinks() async throws {
        let h = harness()
        let editor = openEditor(h)
        try await h.run("block.update", ["ref": .string(paragraph), "text": "Slides at https://example.com/slides"])
        try await waitUntil("the editor sees the text") { editor.block(Fixtures.paragraphBlockID)?.text.plainText.contains("slides") == true }
        let depth = h.undoDepth(doc)
        await AutoLinkEditor.link(Fixtures.paragraphBlockID, in: editor)
        var links = AutoLinker.links(in: try block(h, "FIXTUREBLK02").text)
        XCTAssertEqual(links.map { $0.link.url }, ["https://example.com/slides"])
        XCTAssertEqual(h.undoDepth(doc), depth + 1, "one block.update, one undo step")

        let found = try XCTUnwrap(links.first)
        AutoLinkEditor.removeLink(in: editor, block: Fixtures.paragraphBlockID, range: found.range, link: found.link)
        try await waitUntil("the link removed") { AutoLinker.links(in: (try? self.block(h, "FIXTUREBLK02").text) ?? .empty).isEmpty }
        await AutoLinkEditor.link(Fixtures.paragraphBlockID, in: editor)
        links = AutoLinker.links(in: try block(h, "FIXTUREBLK02").text)
        XCTAssertTrue(links.isEmpty, "an address unlinked by hand is not linked again")

        // Code blocks are never linked.
        try await h.run("block.update", ["ref": .string(heading), "kind": "code", "text": "curl https://example.com"])
        try await waitUntil("the code block") { editor.block(Fixtures.headingBlockID)?.kind == .code }
        await AutoLinkEditor.link(Fixtures.headingBlockID, in: editor)
        XCTAssertTrue(AutoLinker.links(in: try block(h, "FIXTUREBLK01").text).isEmpty)
    }

    // MARK: Acceptance: the exporter

    func testTheExporterMakesAPDFOfTheFixtureTextDocument() async throws {
        let h = harness()
        let urls = try await export(h, ExportRequest(documents: [doc]))
        XCTAssertEqual(urls.count, 1)
        let url = try XCTUnwrap(urls.first)
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "Fixture Text Document")
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        let text = pdf.string ?? ""
        for words in ["Fixture Text", "Hello blocks", "A1", "B2"] {
            XCTAssertTrue(text.contains(words), "the PDF holds \(words) as text")
        }
        XCTAssertFalse(text.contains("Nice"), "comments are left out unless asked for")

        let annotated = try await export(h, ExportRequest(documents: [doc], options: [ExportOptionKeys.annotations: true],
                                                          fileName: "Notes.pdf"))
        let second = try XCTUnwrap(annotated.first)
        XCTAssertEqual(second.lastPathComponent, "Notes.pdf")
        let withComments = PDFDocument(url: second)?.string ?? ""
        XCTAssertTrue(withComments.contains("Nice"))
        XCTAssertTrue(withComments.contains("Fixture"))
    }

    func testTheExporterRefusesLockedDocumentsAndOtherKinds() async throws {
        let h = harness()
        await assertError(.unsupported) { _ = try await self.export(h, ExportRequest(documents: [Fixtures.docID])) }
        await assertError(.invalidParams) { _ = try await self.export(h, ExportRequest(documents: [])) }
        h.app.services.lock = FakeLockService(locked: [doc])
        await assertError(.locked) { _ = try await self.export(h, ExportRequest(documents: [doc])) }
    }

    func testEveryBlockKindPrintsAndLongDocumentsPaginate() async throws {
        let h = harness()
        var blocks: [TextBlock] = []
        func add(_ kind: BlockKind, _ text: String, _ edit: (inout TextBlock) -> Void = { _ in }) {
            var b = TextBlock(id: NibID("K\(blocks.count)"), kind: kind, text: RichText(plain: text))
            edit(&b)
            blocks.append(b)
        }
        add(.heading1, "Cell biology")
        add(.bullet, "Nucleus")
        add(.bullet, "Membrane") { $0.indent = 1 }
        add(.numbered, "First")
        add(.todo, "Revise") { $0.checked = true }
        add(.quote, "Omnis cellula e cellula")
        add(.code, "let cells = 3\nprint(cells)")
        add(.divider, "")
        add(.image, "") {
            $0.asset = Fixtures.pngAsset
            $0.caption = RichText(plain: "Figure 1")
        }
        add(.video, "") {
            $0.url = "https://example.com/lecture.mp4"
            $0.caption = RichText(plain: "Lecture 4")
        }
        add(.table, "") {
            $0.table = TableData(rows: [[TableCell(text: RichText(plain: "Organelle")), TableCell(text: RichText(plain: "Role"))],
                                        [TableCell(text: RichText(plain: "Ribosome")), TableCell(text: RichText(plain: "Protein"))],
                                        [TableCell(text: RichText(plain: "Merged")), TableCell()]],
                                 merges: [TableMerge(row: 0, column: 1, rowSpan: 2, columnSpan: 1)])
        }
        let box = DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: 100, height: 40), stroke: .black)])
        add(.custom, "Chart") { $0.custom = CustomBlock(owner: "dev.nib.charts", type: "bar", height: 80, display: box) }
        for i in 0..<120 {
            add(i % 12 == 0 ? .heading2 : .paragraph,
                "Paragraph \(i): the quick brown fox jumps over the lazy dog, again and again, to fill the page.")
        }
        let snapshot = TextDocPrintSnapshot.make(doc: doc, title: "Cells", blocks: blocks, assets: h.assets,
                                                 options: [TextDocExportOptions.paper: "a5"])
        XCTAssertEqual(snapshot.paper, CGSize(width: PageSize.a5.width, height: PageSize.a5.height))
        let size = TextDocPrintMetrics.contentRect(paper: snapshot.paper).size
        let layout = TextDocPrintLayout(snapshot, size: size)
        XCTAssertGreaterThan(layout.pages.count, 2, "a long document takes several pages")

        // Every part of every unit is placed once, in order, and fits its page.
        var placed: [Int: [Range<Int>]] = [:]
        for page in layout.pages {
            for p in page {
                placed[p.unit, default: []].append(p.parts)
                XCTAssertLessThanOrEqual(p.y + p.height, size.height + 0.5)
            }
            if let last = page.last, page != layout.pages.last {
                XCTAssertFalse(layout.units[last.unit].keepWithNext && last.parts.upperBound == layout.units[last.unit].parts,
                               "a heading never ends a page")
            }
        }
        for (i, u) in layout.units.enumerated() {
            let parts = try XCTUnwrap(placed[i], "unit \(i)")
            XCTAssertEqual(parts.first?.lowerBound, 0)
            XCTAssertEqual(parts.last?.upperBound, u.parts)
            for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
        }

        let data = TextDocPDF.data(snapshot, layout: layout)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, layout.pages.count)
        let text = pdf.string ?? ""
        for words in ["Cell biology", "Figure 1", "Lecture 4", "example.com/lecture.mp4", "Ribosome", "Paragraph 119"] {
            XCTAssertTrue(text.contains(words), "the PDF holds \(words)")
        }
        let annotations = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }
        XCTAssertTrue(annotations.contains { $0.url?.absoluteString == "https://example.com/lecture.mp4" },
                      "links stay clickable in the PDF")
    }

    func testExportFileNamesAreSafeAndUnique() {
        var used = Set<String>()
        XCTAssertEqual(TextDocExporter.uniqueName("Biology: cells/notes.pdf", used: &used), "Biology- cells-notes")
        XCTAssertEqual(TextDocExporter.uniqueName("Biology- cells-notes", used: &used), "Biology- cells-notes 2")
        XCTAssertEqual(TextDocExporter.uniqueName("   ", used: &used), "Text Document")
    }
}
