import XCTest
import UIKit
import SwiftUI
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
        // "Helocks": "lo bl" (3..<8) deleted; "llo b" (2..<7) gives the same text.
        XCTAssertEqual(CommentAnchors.edit(from: old, to: "Helocks"),
                       CommentAnchors.Edit(start: 3, oldEnd: 8, newEnd: 3, lowest: 2))
        XCTAssertEqual(moved([0, 5], old, "Helocks"), [0, 3], "deleting across the end cuts them")
        XCTAssertEqual(moved([6, 6], old, "Helocks"), [3, 4], "deleting across the start cuts them")
        XCTAssertEqual(moved([6, 6], old, "Hello bricks"), [6, 6], "replacing inside keeps the span")
        XCTAssertEqual(moved([6, 0], old, "Hello new blocks"), [10, 0], "an empty place moves with the text after it")
        // A character equal to the first of the words, typed before them: the diff puts it after the "b", but the
        // same text comes from typing it before, so the comment does not grow over it.
        XCTAssertEqual(CommentAnchors.edit(from: old, to: "Hello bblocks"),
                       CommentAnchors.Edit(start: 7, oldEnd: 7, newEnd: 8, lowest: 6))
        XCTAssertEqual(moved([6, 6], old, "Hello bblocks"), [7, 6], "b typed before 'blocks' stays outside")
        XCTAssertEqual(moved([0, 7], old, "Hello bblocks"), [0, 7], "and after 'Hello b' too")
        XCTAssertEqual(moved([1, 2], "aab", "ab"), [0, 2], "a repeated character deleted before the words")
        XCTAssertEqual(moved([0, 2], "abb", "ab"), [0, 2], "and after them")
        XCTAssertEqual(moved([0, 5], "Hello", "Helllo"), [0, 6], "typed inside, it still grows them")
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

    func testEditsLandingBeforeTheKeeperRunsAreRebasedOneAfterTheOther() async throws {
        let h = harness()
        await FeatTextDocExtrasFeature.start(h.app)
        let keeper = try XCTUnwrap(h.app.services.get(CommentAnchorKeeper.serviceKey, as: CommentAnchorKeeper.self))
        try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Plural?", "id": "RAPID01"])
        let original = try XCTUnwrap(try block(h, "FIXTUREBLK02").comments)
        let depth = h.undoDepth(doc)

        // Two keystrokes' commits before the keeper had its turn: the second continues from where the first left.
        try await h.run("block.update", ["ref": .string(paragraph), "text": "Oh, Hello blocks"])
        try await h.run("block.update", ["ref": .string(paragraph), "text": "Oh, Hello big blocks"])
        await keeper.idle()
        let expected = CommentAnchors.rebase(CommentAnchors.rebase(original, from: "Hello blocks", to: "Oh, Hello blocks"),
                                             from: "Oh, Hello blocks", to: "Oh, Hello big blocks")
        let b = try block(h, "FIXTUREBLK02")
        XCTAssertEqual(b.comments?.map { [$0.rangeStart, $0.rangeLength] }, expected.map { [$0.rangeStart, $0.rangeLength] })
        XCTAssertEqual(CommentThreads.excerpt(CommentAnchors.range(of: try comment(b, "FIXTURECMB01"), length: 20), in: b), "Hello")
        XCTAssertEqual(CommentThreads.excerpt(CommentAnchors.range(of: try comment(b, "RAPID01"), length: 20), in: b), "blocks")
        XCTAssertLessThanOrEqual(h.undoDepth(doc), depth + 2, "the ranges ride in the edits' own undo steps")
    }

    func testAKeystrokeBeforeSeveralCommentsIsOneMoreChangeNotOnePerComment() async throws {
        let h = harness()
        await FeatTextDocExtrasFeature.start(h.app)
        let keeper = try XCTUnwrap(h.app.services.get(CommentAnchorKeeper.serviceKey, as: CommentAnchorKeeper.self))
        try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Plural?", "id": "BATCH01"])
        var commits = 0
        let subscription = h.app.bus.observeCommits { cs in
            if cs.documents.contains(Fixtures.textDocID) { commits += 1 }
        }
        defer { subscription.cancel() }
        var text = "Hello blocks"
        for typed in ["a", "b", "c"] {
            text = typed + text
            commits = 0
            try await h.run("block.update", ["ref": .string(paragraph), "text": .string(text)])
            await keeper.idle()
            XCTAssertEqual(commits, 2, "\(typed): the text, then both comments' ranges in one change")
        }
        let b = try block(h, "FIXTUREBLK02")
        XCTAssertEqual([try comment(b, "FIXTURECMB01").rangeStart, try comment(b, "BATCH01").rangeStart], [3, 9])

        // block.editComment moves several comments of a block in one write, and refuses what it cannot do.
        try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "Nice",
                                              "range": [0, 3], "moves": [["comment": "BATCH01", "range": [3, 5]]]])
        let moved = try block(h, "FIXTUREBLK02")
        XCTAssertEqual([try comment(moved, "FIXTURECMB01").rangeLength, try comment(moved, "BATCH01").rangeStart], [3, 3])
        await assertError(.notFound) {
            _ = try await h.run("block.editComment", ["ref": .string(self.paragraph), "comment": "FIXTURECMB01", "text": "Nice",
                                                      "moves": [["comment": "NOPE", "range": [0, 1]]]])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(self.paragraph), "comment": "FIXTURECMB01", "text": "Nice",
                                                      "moves": [["comment": "BATCH01", "range": [0, 99]]]])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(self.paragraph), "comment": "FIXTURECMB01", "text": "Nice",
                                                      "block": .string(self.heading), "range": [0, 1],
                                                      "moves": [["comment": "BATCH01", "range": [0, 1]]]])
        }
    }

    func testACommentMovesToAnotherBlockKeepingWhoWroteItAndWhen() async throws {
        let h = harness()
        let before = try comment(try block(h, "FIXTUREBLK02"), "FIXTURECMB01")
        let snapshot = try h.snapshot(doc)
        try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "Nice title",
                                              "block": .string(heading), "range": [0, 7]])
        XCTAssertNil(try block(h, "FIXTUREBLK02").comments, "it left the paragraph")
        let moved = try comment(try block(h, "FIXTUREBLK01"), "FIXTURECMB01")
        XCTAssertEqual([moved.rangeStart, moved.rangeLength], [0, 7])
        XCTAssertEqual(moved.text, "Nice title")
        XCTAssertEqual(moved.author, before.author)
        XCTAssertEqual(moved.at, before.at)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(doc), snapshot, "one undo step")

        let other = "block:FIXTUREDOC02/NOSUCHBLOCK"
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "x",
                                                      "block": .string(heading)])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "x",
                                                      "block": .string(table), "range": [0, 0]])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "x",
                                                      "block": "block:FIXTUREDOC01/FIXTUREBLK01", "range": [0, 0]])
        }
        await assertError(.notFound) {
            _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "x",
                                                      "block": .string(other), "range": [0, 0]])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "x",
                                                      "block": .string(heading), "range": [0, 40]])
        }
        XCTAssertEqual(try h.snapshot(doc), snapshot, "refused moves change nothing")

        // Out of a block deleted in the same change: the delete stays, the comment lives on.
        try await h.run("block.delete", ["refs": [.string(paragraph)]])
        try await h.run("block.editComment", ["ref": .string(paragraph), "comment": "FIXTURECMB01", "text": "Nice",
                                              "block": .string(heading), "range": [8, 4]])
        XCTAssertEqual(try comment(try block(h, "FIXTUREBLK01"), "FIXTURECMB01").rangeStart, 8)
        let tombstone = try h.app.workspace.content(doc).blocks.first { $0.id == Fixtures.paragraphBlockID }
        XCTAssertEqual(tombstone?.deleted, true)
        XCTAssertNil(tombstone?.comments, "no comment is left twice")
    }

    func testSplitsAndJoinsAreRecognisedFromTheTextThatMoved() {
        let c = [BlockComment(id: "HEAD", author: "", text: "h", rangeStart: 0, rangeLength: 5),
                 BlockComment(id: "ACROSS", author: "", text: "a", rangeStart: 3, rangeLength: 6),
                 BlockComment(id: "TAIL", author: "", text: "t", rangeStart: 6, rangeLength: 6),
                 BlockComment(id: "GONE", author: "", text: "g", rangeStart: 6, rangeLength: 0)]
        let cut = CommentAnchors.TextEdit(block: "A", old: "Hello blocks", new: "Hello ", comments: c)
        let moved = CommentAnchors.split([cut], inserted: "blocks")
        XCTAssertEqual(moved.map { $0.comment }, ["TAIL"], "only comments wholly on the rest go with it")
        XCTAssertEqual(moved.first?.range, NSRange(location: 0, length: 6))
        XCTAssertEqual(moved.first?.block, "A")
        XCTAssertTrue(CommentAnchors.split([cut], inserted: "other").isEmpty, "a new block with other text is no split")
        XCTAssertTrue(CommentAnchors.split([cut], inserted: "").isEmpty)
        // Return over a selection: "lo b" (3..<7) replaced, "Hel" stays, "locks" moves on.
        let overSelection = CommentAnchors.TextEdit(block: "A", old: "Hello blocks", new: "Hel", comments: c)
        XCTAssertEqual(CommentAnchors.split([overSelection], inserted: "locks").map { $0.comment }, [])
        let late = [BlockComment(id: "END", author: "", text: "e", rangeStart: 8, rangeLength: 4)]
        let selectionCut = CommentAnchors.TextEdit(block: "A", old: "Hello blocks", new: "Hel", comments: late)
        XCTAssertEqual(CommentAnchors.split([selectionCut], inserted: "ocks").first?.range, NSRange(location: 0, length: 4))

        let append = CommentAnchors.TextEdit(block: "A", old: "Fixture Text", new: "Fixture TextHello blocks", comments: [])
        let joined = CommentAnchors.join([append], deleted: "Hello blocks", comments: Array(c.prefix(3)))
        XCTAssertEqual(joined?.block, "A")
        XCTAssertEqual(joined?.comments.map { $0.range.location }, [12, 15, 18])
        XCTAssertNil(CommentAnchors.join([append], deleted: "Other", comments: c), "text the deleted block never had")
        XCTAssertNil(CommentAnchors.join([cut], deleted: "blocks", comments: c), "a cut is no join")
        // UTF-16: an emoji is two units.
        let emoji = CommentAnchors.TextEdit(block: "A", old: "a\u{1F600}", new: "a\u{1F600}bc", comments: [])
        XCTAssertEqual(CommentAnchors.join([emoji], deleted: "bc", comments: [c[0]])?.comments.first?.range,
                       NSRange(location: 3, length: 2), "cut to the deleted block's text, then after the text there")
    }

    func testReturnAndJoiningBlocksTakeTheirCommentsAlongInOneUndoStep() async throws {
        let h = harness()
        await FeatTextDocExtrasFeature.start(h.app)
        let keeper = try XCTUnwrap(h.app.services.get(CommentAnchorKeeper.serviceKey, as: CommentAnchorKeeper.self))
        try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Plural?", "id": "SPLITC01"])
        let before = try h.snapshot(doc)
        let depth = h.undoDepth(doc)

        // Return between the words (the editor's split: one group, cut the block, then insert the rest after it).
        let tailRef = "block:FIXTUREDOC02/SPLITTAIL01"
        try await h.run(CommandIDs.batch, ["calls": [
            ["command": "block.update", "params": ["ref": .string(paragraph), "text": "Hello "]],
            ["command": "block.insert", "params": ["doc": "doc:FIXTUREDOC02", "after": .string(paragraph),
                                                    "kind": "paragraph", "text": "blocks", "id": "SPLITTAIL01"]]]])
        await keeper.idle()
        var head = try block(h, "FIXTUREBLK02")
        XCTAssertEqual(head.comments?.map { $0.id.raw }, ["FIXTURECMB01"], "the comment on the first word stays")
        let carried = try comment(try block(h, "SPLITTAIL01"), "SPLITC01")
        XCTAssertEqual([carried.rangeStart, carried.rangeLength], [0, 6], "the comment went with its word")
        XCTAssertEqual(h.undoDepth(doc), depth + 1, "Return and the moved comment are one undo step")

        // Delete at the start of the new block joins it back, with its comment.
        try await h.run(CommandIDs.batch, ["calls": [
            ["command": "block.update", "params": ["ref": .string(paragraph), "text": "Hello blocks"]],
            ["command": "block.delete", "params": ["refs": [.string(tailRef)]]]]])
        await keeper.idle()
        head = try block(h, "FIXTUREBLK02")
        let back = try comment(head, "SPLITC01")
        XCTAssertEqual([back.rangeStart, back.rangeLength], [6, 6])
        XCTAssertEqual(CommentThreads.excerpt(NSRange(location: 6, length: 6), in: head), "blocks")
        XCTAssertEqual(h.undoDepth(doc), depth + 2)

        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        await keeper.idle()
        XCTAssertEqual(try h.snapshot(doc), before, "two undos restore the text, the blocks and the comments")
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

    // MARK: ⇧⌘M as a scoped key command (contracts-v2.2)

    func testTheCommentKeyIsLiveOnlyInTextDocumentsWhileNoTextIsEdited() throws {
        let h = harness()
        let key = try XCTUnwrap(h.app.content.keyCommands.get(BlockCommentsEditor.keyID))
        XCTAssertEqual(key.owner, "textdocextras")
        XCTAssertEqual(key.shortcut, KeyShortcut("m", [.command, .shift]))
        XCTAssertEqual(key.docKinds, [.textDocument])
        XCTAssertEqual(key.scope, .canvas)
        XCTAssertEqual(key.command, CommandIDs.panelOpen)
        XCTAssertEqual(key.params["id"]?.stringValue, TextDocCommentsPanel.panelID)

        let all = h.app.content.keyCommands.all
        func live(_ context: KeyCommandContext) -> Bool {
            KeyCommandRouting.active(all, in: context).contains { $0.id == key.id }
        }
        XCTAssertTrue(live(KeyCommandContext(docKind: .textDocument)))
        XCTAssertFalse(live(KeyCommandContext(docKind: .textDocument, isEditingText: true)),
                       "while a block is edited the editor serves ⇧⌘M itself, at the selected words")
        XCTAssertFalse(live(KeyCommandContext(docKind: .notebook)))
        XCTAssertFalse(live(KeyCommandContext(docKind: nil)), "never in the library")

        // An any-kind ⇧⌘M (a plugin, another feature) does not take the key in text documents.
        var other = KeyCommandDescriptor(id: "dev.plugin.m", title: "Other", shortcut: key.shortcut, command: "dev.other",
                                         scope: .document, owner: "dev.plugin")
        other.docKinds = nil
        let winners = KeyCommandRouting.active(all + [other], in: KeyCommandContext(docKind: .textDocument))
        XCTAssertTrue(winners.contains { $0.id == key.id })
        XCTAssertFalse(winners.contains { $0.id == other.id })
    }

    func testTheCommentKeyComposesOnTheWordsSelectedLast() throws {
        let h = harness()
        let editor = openEditor(h)
        h.session.editor = editor
        let key = try XCTUnwrap(h.app.content.keyCommands.get(BlockCommentsEditor.keyID))
        XCTAssertEqual(key.resolvedParams(for: h.session), ["id": .string(TextDocCommentsPanel.panelID)],
                       "nothing selected: the Comments tab opens on its list")

        TextDocExtrasState.of(editor).lastSelection = TextDocSelection(block: Fixtures.paragraphBlockID,
                                                                      range: NSRange(location: 6, length: 6))
        let params = key.resolvedParams(for: h.session)
        XCTAssertEqual(params["id"]?.stringValue, TextDocCommentsPanel.panelID)
        XCTAssertEqual(params["block"]?.stringValue, paragraph)
        XCTAssertEqual(params["range"], [6, 6])
        XCTAssertEqual(params["compose"]?.boolValue, true)
        let again = key.resolvedParams(for: h.session)
        XCTAssertNotNil(params["request"]?.stringValue)
        XCTAssertNotEqual(again["request"], params["request"],
                          "every press reaches a Comments tab on screen, even on the same words")

        // Posted on those words: they are forgotten (⇧⌘M would offer them a second time).
        BlockCommentsEditor.forgetSelection(in: editor, block: Fixtures.paragraphBlockID)
        XCTAssertNil(TextDocExtrasState.of(editor).lastSelection)

        // Words past the end of the block's text now (it changed since) are cut to it; none left, no composer.
        TextDocExtrasState.of(editor).lastSelection = TextDocSelection(block: Fixtures.paragraphBlockID,
                                                                      range: NSRange(location: 40, length: 3))
        XCTAssertNil(key.resolvedParams(for: h.session)["compose"])
        TextDocExtrasState.of(editor).lastSelection = TextDocSelection(block: Fixtures.tableBlockID,
                                                                      range: NSRange(location: 0, length: 1))
        XCTAssertNil(key.resolvedParams(for: h.session)["compose"], "a table has no text to comment on")

        TextDocExtrasState.of(editor).lastSelection = TextDocSelection(block: Fixtures.paragraphBlockID,
                                                                      range: NSRange(location: 0, length: 5))
        h.session.readOnly = true
        XCTAssertNil(key.resolvedParams(for: h.session)["compose"], "reading only: nothing to write")
    }

    func testTheCommentsTabComposesAPostsAndOpensTheNewThread() async throws {
        let h = harness()
        h.session.document = doc
        let model = CommentsPanelModel(app: h.app, session: h.session,
                                       params: ["block": .string(paragraph), "range": [6, 6], "compose": true])
        let draft = try XCTUnwrap(model.draft)
        XCTAssertEqual(draft.excerpt, "blocks")
        XCTAssertEqual(draft.range, NSRange(location: 6, length: 6))
        XCTAssertNil(model.expandedID, "composing opens no existing thread")

        let depth = h.undoDepth(doc)
        let posted = await model.postDraft("Plural?")
        XCTAssertTrue(posted)
        try await waitUntil("the new comment") { model.draft == nil && model.rows.count == 2 }
        XCTAssertEqual(h.undoDepth(doc), depth + 1)
        let b = try block(h, "FIXTUREBLK02")
        let added = try XCTUnwrap(b.comments?.first { $0.text == "Plural?" })
        XCTAssertEqual([added.rangeStart, added.rangeLength], [6, 6])
        let open = try XCTUnwrap(model.rows.first { $0.id == model.expandedID })
        XCTAssertTrue(open.thread.contains(added.id), "the new thread opens in the list")

        // panel.open again on the tab on screen, and a request the window cannot write.
        model.apply(["block": .string(paragraph), "range": [0, 5], "compose": true])
        XCTAssertEqual(model.draft?.excerpt, "Hello")
        let token = model.draft?.token
        // Text typed before the words while the comment is written: the draft follows them.
        try await h.run("block.update", ["ref": .string(paragraph), "text": "Oh, Hello blocks"])
        try await waitUntil("the draft follows its words") { model.draft?.range == NSRange(location: 4, length: 5) }
        XCTAssertEqual(model.draft?.excerpt, "Hello")
        XCTAssertEqual(model.draft?.token, token, "the composer and its text stay")
        // Its words deleted meanwhile: the composer and its text stay, now on the whole block.
        try await h.run("block.update", ["ref": .string(paragraph), "text": "Oh, blocks"])
        try await waitUntil("the draft on the whole block") { model.draft?.range == NSRange(location: 0, length: 10) }
        XCTAssertEqual(model.draft?.token, token, "the words typed in it are not lost")
        XCTAssertEqual(model.draft?.excerpt, "Oh, blocks")
        XCTAssertEqual(model.draft?.canPost, true)
        // Its block gone: still there, with Comment off, until the block is back.
        try await h.run("block.delete", ["refs": [.string(paragraph)]])
        try await waitUntil("the block is gone") { model.draft?.canPost == false }
        XCTAssertEqual(model.draft?.token, token)
        let refused = await model.postDraft("Lost?")
        XCTAssertFalse(refused, "nothing to post on")
        XCTAssertTrue(h.app.bus.undo(doc))
        try await waitUntil("the block is back") { model.draft?.canPost == true }
        XCTAssertEqual(model.draft?.excerpt, "Oh, blocks")

        model.apply(["block": .string(paragraph), "range": [0, 3], "compose": true])
        XCTAssertEqual(model.draft?.excerpt, "Oh,")
        model.cancelDraft()
        XCTAssertNil(model.draft)
        // ⇧⌘M again on the same words after Cancel: a composer again.
        model.apply(["block": .string(paragraph), "range": [0, 3], "compose": true])
        XCTAssertEqual(model.draft?.excerpt, "Oh,")
        model.cancelDraft()
        model.apply(["block": .string(paragraph), "range": [0, 3], "compose": true])
        XCTAssertEqual(model.draft?.excerpt, "Oh,")
        model.cancelDraft()
        model.apply(["block": .string(table), "range": [0, 1], "compose": true])
        XCTAssertNil(model.draft, "a table has no text to comment on")
        h.session.readOnly = true
        model.apply(["block": .string(paragraph), "range": [0, 5], "compose": true])
        XCTAssertNil(model.draft, "reading only: no composer")
    }

    func testCommentViewsRenderInLightDarkAndAtAX3() throws {
        let h = harness()
        h.session.document = doc
        let runner = TextDocCommandRunner(app: h.app, session: h.session, doc: doc)
        var b = try block(h, "FIXTUREBLK02")
        b.comments?.append(BlockComment(id: "SNAPREPLY01", author: "Ben", text: "Agreed, and a longer reply that wraps",
                                        at: 20, rangeStart: 0, rangeLength: 5))
        let thread = try XCTUnwrap(CommentThreads.threads(in: b).first)
        let model = CommentThreadModel(runner: runner, block: b.id, thread: thread)
        let width: CGFloat = 280   // a popover's content width
        let card = CommentThreadView(model: model, chrome: .popover, showsQuote: true) {}
            .frame(width: width)
        let composer = CommentComposerView(excerpt: "Hello", chrome: .panel, onCancel: {}) { _ in true }
            .frame(width: width)
        for view in [AnyView(card), AnyView(composer)] {
            let images = NibSnapshot.images(view, size: CGSize(width: width, height: 360))
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases))
            let regular = NibSnapshot.fittingSize(view, width: width)
            let large = NibSnapshot.fittingSize(view, width: width, variant: .largeText)
            XCTAssertGreaterThan(regular.height, 0)
            XCTAssertGreaterThan(large.height, regular.height, "text grows with Dynamic Type")
        }
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

    // MARK: The Comments tab and the editor

    func testOpeningAThreadInTheTabLeavesTheCaretAndTheTextAlone() async throws {
        let h = harness()
        let editor = openEditor(h)
        h.session.editor = editor
        // In a window, so a text view could take the keyboard if something asked it to.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        editor.view.layoutIfNeeded()
        let before = try block(h, "FIXTUREBLK02").text

        let model = CommentsPanelModel(app: h.app, session: h.session, params: ["block": .string(paragraph)])
        XCTAssertNotNil(model.expandedID, "panel.open {block} opens that block's thread")
        XCTAssertNotNil(model.pendingReveal, "the editor is scrolled once the tab is on screen, not while it is made")
        model.performPendingReveal()
        XCTAssertNil(model.pendingReveal)

        let row = try XCTUnwrap(model.rows.first)
        let tv = editor.cell(for: Fixtures.paragraphBlockID)?.textView
        let selection = tv?.selectedRange
        model.collapse()
        model.open(row)
        XCTAssertEqual(model.expandedID, row.id)
        XCTAssertFalse(tv?.isFirstResponder ?? false, "opening a thread never gives the document the keyboard")
        XCTAssertNil(editor.focusedBlockID)
        XCTAssertFalse(h.session.isEditingText)
        if let tv = tv, let selection = selection {
            XCTAssertEqual(tv.selectedRange, selection, "nor selects the commented words (a key would replace them)")
        }

        // Reply puts the keyboard in the thread's reply field, not in the document.
        model.reply(row)
        XCTAssertEqual(model.expanded?.focusReply, true)
        XCTAssertFalse(tv?.isFirstResponder ?? false)
        XCTAssertNil(editor.focusedBlockID)

        await editor.flushEdits()
        XCTAssertEqual(try block(h, "FIXTUREBLK02").text, before, "the commented words are unchanged")
    }

    // MARK: Auto-linking while typing

    func testAHalfTypedAddressIsNotLinkedAndAnEarlyAutoLinkGrowsToTheWholeAddress() throws {
        // A pass while the caret is at the end of "https://exa" (the address may still be typed) links nothing.
        let typing = RichText(plain: "see https://exa")
        XCTAssertNil(AutoLinker.linked(typing, caret: NSRange(location: 15, length: 0)))
        XCTAssertNil(AutoLinker.linked(typing, caret: NSRange(location: 8, length: 0)), "nor with the caret inside it")
        XCTAssertTrue(AutoLinker.isTyping(at: NSRange(location: 15, length: 0), in: NSRange(location: 4, length: 11)))
        XCTAssertFalse(AutoLinker.isTyping(at: NSRange(location: 16, length: 0), in: NSRange(location: 4, length: 11)))
        // Once a space ends it, or without a caret (the caret left the block), it is linked.
        let ended = try XCTUnwrap(AutoLinker.linked(RichText(plain: "see https://example.com "),
                                                    caret: NSRange(location: 24, length: 0)))
        XCTAssertEqual(AutoLinker.links(in: ended).map { $0.link.url }, ["https://example.com"])

        // An auto-link made before the rest was typed: "https://exa" linked, "mple.com " typed after it unlinked.
        let early = AutoLinker.setLink(TextLink(url: "https://exa"), in: typing, range: NSRange(location: 4, length: 11))
        var grown = early
        grown.paragraphs[0].runs.append(TextRun("mple.com "))
        let fixed = try XCTUnwrap(AutoLinker.linked(grown))
        let links = AutoLinker.links(in: fixed)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.link.url, "https://example.com")
        XCTAssertEqual(links.first?.range, NSRange(location: 4, length: 19), "one link over the whole address")
        XCTAssertEqual(fixed.plainText, "see https://example.com ")

        // A link someone chose inside the address is theirs: left alone.
        let chosen = AutoLinker.setLink(TextLink(url: "https://elsewhere.org"), in: RichText(plain: "see https://example.com "),
                                        range: NSRange(location: 4, length: 11))
        XCTAssertNil(AutoLinker.linked(chosen))
        XCTAssertTrue(AutoLinker.isAutoLink(TextLink(url: "mailto:ada@example.org"), text: "ada@example.org"))
        XCTAssertFalse(AutoLinker.isAutoLink(TextLink(url: "https://elsewhere.org"), text: "https://exa"))
        XCTAssertFalse(AutoLinker.isAutoLink(TextLink(document: "FIXTUREDOC01"), text: "https://exa"))
    }

    // MARK: Highlights on TextKit 1

    func testTheTextKit1HighlightIsAShapeLayerBehindTheWords() throws {
        let h = harness()
        let editor = openEditor(h)
        let cell = BlockCell(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        let b = try block(h, "FIXTUREBLK02")
        let env = BlockCell.Environment(style: BlockStyle.make(kind: .paragraph), captionStyle: BlockStyle.make(kind: .paragraph, caption: true),
                                        marker: nil, placeholder: nil, alwaysShowsPlaceholder: false, readOnly: false,
                                        accessoryWidth: 0, aiAvailable: false, isFirst: false)
        cell.configure(b, environment: env)
        _ = cell.textView.layoutManager   // another part of the app asked for TextKit 1
        XCTAssertNil(cell.textView.textLayoutManager, "the view now runs on TextKit 1")
        cell.layoutIfNeeded()
        BlockCommentsEditor.decorate(cell, block: b, editor: editor)
        let marks = try XCTUnwrap(cell.textView.layer.sublayers?.first { $0.name == "textdocextras.comment.marks" } as? CAShapeLayer)
        XCTAssertFalse(marks.path?.isEmpty ?? true, "the commented words are washed")
        let rules = try XCTUnwrap(marks.sublayers?.first as? CAShapeLayer)
        XCTAssertFalse(rules.path?.isEmpty ?? true, "with a rule under them (never colour alone)")
        XCTAssertFalse(rules.lineDashPattern?.isEmpty ?? true, "dashed, like the dotted underline of TextKit 2")
        let text = cell.textView.attributedText ?? NSAttributedString()
        XCTAssertEqual(BlockStyle.make(kind: .paragraph).richText(from: text), RichText(plain: "Hello blocks"),
                       "nothing entered the text")

        // Resolved: the wash goes.
        var resolved = b
        resolved.comments = b.comments?.map { c in
            var c = c
            c.resolved = true
            return c
        }
        BlockCommentsEditor.decorate(cell, block: resolved, editor: editor)
        XCTAssertTrue(marks.path?.isEmpty ?? true)
    }

    // MARK: Printing

    /// The print system's paper, stood in (the renderer asks for it when it paginates).
    private final class StubPaperRenderer: TextDocPageRenderer {
        override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 612, height: 792) }
        override var printableRect: CGRect { paperRect.insetBy(dx: 18, dy: 18) }
    }

    func testThePrintRendererPaginatesForThePaperThePrintSystemPicks() throws {
        let h = harness()
        h.session.document = doc
        let renderer = try TextDocPrinter.renderer(doc: doc, app: h.app, session: h.session)
        XCTAssertEqual(renderer.snapshot.title, "Fixture Text Document")
        let stub = StubPaperRenderer(snapshot: renderer.snapshot, paper: nil)
        XCTAssertGreaterThanOrEqual(stub.numberOfPages, 1)
        let content = stub.contentRect
        XCTAssertEqual(content.minX, TextDocPrintMetrics.margin, "at least a margin from the paper's edge")
        XCTAssertLessThanOrEqual(content.maxY, 792 - TextDocPrintMetrics.margin)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 612, height: 792)).image { _ in
            stub.prepare(forDrawingPages: NSRange(location: 0, length: stub.numberOfPages))
            for i in 0..<stub.numberOfPages { stub.drawPage(at: i, in: stub.paperRect) }
        }
        XCTAssertEqual(image.size, CGSize(width: 612, height: 792))

        XCTAssertThrowsError(try TextDocPrinter.renderer(doc: Fixtures.docID, app: h.app, session: h.session),
                             "a notebook is not printed as a text document")
        h.app.services.lock = FakeLockService(locked: [doc])
        XCTAssertThrowsError(try TextDocPrinter.renderer(doc: doc, app: h.app, session: h.session), "nor a locked one")
    }

    func testOnlyWebAndMailLinksBecomeLiveInThePDF() throws {
        let h = harness()
        var text = RichText(plain: "web mail page script")
        text = AutoLinker.setLink(TextLink(url: "https://example.com/a"), in: text, range: NSRange(location: 0, length: 3))
        text = AutoLinker.setLink(TextLink(url: "mailto:ada@example.org"), in: text, range: NSRange(location: 4, length: 4))
        text = AutoLinker.setLink(TextLink(url: "nib://doc/FIXTUREDOC01"), in: text, range: NSRange(location: 9, length: 4))
        text = AutoLinker.setLink(TextLink(url: "javascript:alert(1)"), in: text, range: NSRange(location: 14, length: 6))
        let blocks = [TextBlock(id: "L1", kind: .paragraph, text: text)]
        let snapshot = TextDocPrintSnapshot.make(doc: doc, title: "Links", blocks: blocks, assets: h.assets, options: [:])
        let pdf = try XCTUnwrap(PDFDocument(data: TextDocPDF.data(snapshot)))
        let urls = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }.compactMap { $0.url?.absoluteString }
        XCTAssertEqual(urls.filter { $0 == "https://example.com/a" }.count, 1, "a web link is one live link")
        XCTAssertEqual(urls.filter { $0 == "mailto:ada@example.org" }.count, 1)
        XCTAssertFalse(urls.contains { $0.hasPrefix("nib:") }, "Nib's own ids mean nothing outside Nib")
        XCTAssertFalse(urls.contains { $0.hasPrefix("javascript:") }, "nor does a script become a live link")
    }

    // MARK: Design gate (DESIGN §15.7): the Outline and Comments tabs in every variant

    func testTheOutlineAndCommentsTabsRenderInEveryVariant() async throws {
        let h = harness()
        h.session.document = doc
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "heading2", "text": "Background", "id": "SNAPH2A"])
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "heading3", "text": "Earlier work", "id": "SNAPH3A"])
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "heading2", "text": "Method", "id": "SNAPH2B"])
        try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Plural?", "id": "SNAPC01"])
        try await h.run("block.comment", ["ref": .string(paragraph), "range": [6, 6], "text": "Yes, both of them", "id": "SNAPC02"])
        func context(_ params: JSONValue) -> PanelContext {
            var c = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
            c.params = params
            return c
        }
        let outline = TextDocOutlineModel(app: h.app, session: h.session)
        XCTAssertEqual(outline.entries.map { $0.depth }, [1, 2, 3, 2], "the fixture heading with nested H2 and H3")
        let size = CGSize(width: 320, height: 480)
        let views: [(String, AnyView)] = [
            ("outline", AnyView(TextDocOutlinePanel(context: context([:])))),
            ("comments list", AnyView(TextDocCommentsPanel(context: context([:])))),
            ("comments thread", AnyView(TextDocCommentsPanel(context: context(["block": .string(paragraph),
                                                                               "comment": "SNAPC01"])))),
            ("comments draft", AnyView(TextDocCommentsPanel(context: context(["block": .string(paragraph), "range": [0, 5],
                                                                              "compose": true]))))
        ]
        for (name, view) in views {
            let images = NibSnapshot.images(view, size: size)
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases), name)
        }
    }
}
