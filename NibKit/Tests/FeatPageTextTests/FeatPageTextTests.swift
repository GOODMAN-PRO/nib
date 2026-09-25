import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatPageText

/// Writes items no registered command creates here (two full-page boxes on one page, as offline sync can leave).
private struct SeedItems: NibCommand {
    struct Params: Codable {
        var page: String
        var items: [Item]
    }

    static let descriptor = CommandDescriptor(id: "test.seedItems", title: "Seed Items", summary: "Test only.", effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .page(doc, page)? = NodeRef(p.page) else { throw NibError.invalid("page ref", path: "$.page") }
        try ctx.mutate { tx in
            for item in p.items { try tx.put(item, doc: doc, page: page) }
        }
        return NoResult()
    }
}

/// Stand-in for F003's `item.update` (not linked into this test target) with the part the editor uses: it applies
/// `patch.text.text` and, like the real command, checks the document lock only, never `item.locked`.
private struct FakeItemUpdate: NibCommand {
    struct Params: Codable {
        struct Patch: Codable {
            struct Box: Codable { var text: RichText }
            var text: Box
        }
        var ref: String
        var patch: Patch
    }

    static let descriptor = CommandDescriptor(id: CommandIDs.itemUpdate, title: "Update Item", summary: "Test only.",
                                              effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .item(doc, page, id)? = NodeRef(p.ref) else { throw NibError.invalid("item ref", path: "$.ref") }
        try ctx.mutate { tx in
            var item = try tx.item(doc, page: page, id: id)
            item.text?.text = p.patch.text.text
            try tx.put(item, doc: doc, page: page)
        }
        return NoResult()
    }
}

/// Stand-in for F007's `page.add`: appends an A4 ruled page with the given id.
private struct FakePageAdd: NibCommand {
    struct Params: Codable {
        var doc: String
        var id: String
    }

    static let descriptor = CommandDescriptor(id: CommandIDs.pageAdd, title: "Add Page", summary: "Test only.", effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .document(doc)? = NodeRef(p.doc) else { throw NibError.invalid("doc ref", path: "$.doc") }
        try ctx.mutate { tx in
            _ = try tx.put(PageRecord(id: NibID(p.id), size: .a4, background: .ofTemplate("builtin.ruled")), doc: doc)
        }
        return NoResult()
    }
}

@MainActor
final class FeatPageTextTests: XCTestCase {
    private let page1Ref = "page:FIXTUREDOC01/FIXTUREPG001"
    private let page2Ref = "page:FIXTUREDOC01/FIXTUREPG002"

    func testFeatureID() { XCTAssertEqual(FeatPageTextFeature.id, "pagetext") }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatPageTextFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: text.startPageText

    func testOnlyOneFullPageBoxPerPageAtTheBottom() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        let first = try await h.run("text.startPageText", ["page": .string(page1Ref)])
        let second = try await h.run("text.startPageText", ["page": .string(page1Ref)])
        XCTAssertEqual(first["created"]?.boolValue, true)
        XCTAssertEqual(second["created"]?.boolValue, false)
        XCTAssertEqual(first["ref"], second["ref"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "opening the existing box records nothing")

        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let boxes = items.filter(PageTextModel.isFullPageBox)
        XCTAssertEqual(boxes.count, 1)
        let box = try XCTUnwrap(boxes.first)
        XCTAssertEqual(items.first?.id, box.id, "below the fixture page's ten items")
        XCTAssertTrue(box.locked, "part of the page: transform, the eraser and the text tool leave it alone")
        XCTAssertEqual(box.text?.style.defaults.font, "Helvetica")
        XCTAssertEqual(box.text?.text.paragraphs.first?.style, PageTextStyle.body.rawValue)
        let page = try XCTUnwrap(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1))
        XCTAssertEqual(box.text?.frame, PageTextModel.frame(for: page))
    }

    func testStartUndoRedoRoundTrip() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        let before = try h.snapshot()
        let r = try await h.run("text.startPageText", ["page": .string(page2Ref), "id": "PAGETEXT0001"])
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/PAGETEXT0001")
        XCTAssertNotEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        let box = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "PAGETEXT0001")
        XCTAssertTrue(PageTextModel.isFullPageBox(box))
    }

    func testDefaultsToTheCurrentPageAndWorksForTheAssistant() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        let r = try await h.run("text.startPageText", [:], as: .ai("chat1"))
        XCTAssertEqual(r["ref"]?.stringValue?.hasPrefix("item:FIXTUREDOC01/FIXTUREPG001/"), true)
    }

    func testBoardsAndMissingPagesAreRefused() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        do {
            _ = try await h.run("text.startPageText", ["page": "page:FIXTUREDOC04/FIXTUREBRD01"])
            XCTFail("an infinite board has no page to fill")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
        do {
            _ = try await h.run("text.startPageText", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"])
            XCTFail("unknown page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    func testReadOnlyWindowsAreRefused() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.session.readOnly = true
        do {
            _ = try await h.run("text.startPageText", ["page": .string(page1Ref)])
            XCTFail("a read-only window never starts typing")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testDuplicateBoxesFromSyncMergeIntoOne() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(SeedItems.self)
        let page = try XCTUnwrap(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page2))
        let frame = try XCTUnwrap(PageTextModel.frame(for: page))
        func box(_ id: String, _ text: String, z: String) -> Item {
            var item = Item.makeText(TextBoxItem(frame: frame, text: RichText(plain: text), style: PageTextModel.boxStyle()))
            item.id = NibID(id)
            item.z = z
            return item
        }
        try await h.app.bus.run(SeedItems.self, SeedItems.Params(page: page2Ref,
                                                                 items: [box("BOXA", "First", z: "F"), box("BOXB", "Second", z: "V")]))
        let r = try await h.run("text.startPageText", ["page": .string(page2Ref)])
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/BOXA")
        let boxes = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).filter(PageTextModel.isFullPageBox)
        XCTAssertEqual(boxes.map { $0.id.raw }, ["BOXA"])
        XCTAssertEqual(boxes.first?.text?.text.plainText, "First\nSecond")
    }

    func testAnExistingBoxOutOfPlaceIsRefittedAtTheBottom() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(SeedItems.self)
        let page = try XCTUnwrap(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1))
        let frame = try XCTUnwrap(PageTextModel.frame(for: page))
        let top = FractionalIndex.between(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).last?.z, nil)
        var moved = Item.makeText(TextBoxItem(frame: Frame(x: 120, y: 300, w: 80, h: 60), text: RichText(plain: "Moved"),
                                              style: PageTextModel.boxStyle()))
        moved.id = "MOVEDBOX01"
        moved.z = top
        try await h.app.bus.run(SeedItems.self, SeedItems.Params(page: page1Ref, items: [moved]))
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).last?.id, moved.id)
        let depth = h.undoDepth(Fixtures.docID)

        let r = try await h.run("text.startPageText", ["page": .string(page1Ref)])
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/MOVEDBOX01")
        XCTAssertEqual(r["created"]?.boolValue, false)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        XCTAssertEqual(items.first?.id, moved.id, "back at the bottom of the z-order")
        XCTAssertEqual(items.first?.text?.frame, frame, "re-fitted to the page")
        XCTAssertEqual(items.first?.text?.text.plainText, "Moved")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
    }

    // MARK: Model

    func testFrameIsThePageMinusTemplateMargins() throws {
        let plain = PageRecord(id: "PAGEA", size: .a4, background: .ofTemplate("builtin.ruled"))
        let f = try XCTUnwrap(PageTextModel.frame(for: plain))
        XCTAssertGreaterThan(f.x, 0)
        XCTAssertGreaterThan(f.y, 0)
        XCTAssertLessThan(f.x + f.w, PageSize.a4.width)
        XCTAssertLessThan(f.y + f.h, PageSize.a4.height)

        let margin = PageRecord(id: "PAGEB", size: .a4, background: .ofTemplate("builtin.ruled", params: ["margin": true]))
        XCTAssertGreaterThan(try XCTUnwrap(PageTextModel.frame(for: margin)).x, f.x, "text starts right of the margin line")
        let at = PageRecord(id: "PAGEC", size: .a4, background: .ofTemplate("builtin.ruled", params: ["margin": 90]))
        XCTAssertEqual(try XCTUnwrap(PageTextModel.frame(for: at)).x, 90 + PageTextModel.marginGap)

        XCTAssertNil(PageTextModel.frame(for: PageRecord(id: "BOARD", size: nil)))
    }

    func testStylePresets() {
        var text = RichText(paragraphs: [Paragraph(runs: [TextRun("Heading")]),
                                         Paragraph(runs: [TextRun("small", TextAttributes(size: 40, bold: true))])])
        text = PageTextModel.applying(.title, to: 0..<1, in: text)
        XCTAssertEqual(text.paragraphs[0].style, "title")
        XCTAssertEqual(text.paragraphs[0].runs[0].attrs.size, PageTextStyle.title.size)
        XCTAssertEqual(text.paragraphs[0].runs[0].attrs.bold, true)
        text = PageTextModel.applying(.caption, to: 1..<5, in: text)
        XCTAssertEqual(text.paragraphs[1].style, "caption")
        XCTAssertEqual(text.paragraphs[1].runs[0].attrs.size, PageTextStyle.caption.size)
        XCTAssertNil(text.paragraphs[1].runs[0].attrs.bold)

        XCTAssertEqual(PageTextStyle.of(Paragraph()), .body)
        XCTAssertEqual(PageTextStyle.of(Paragraph(style: "nonsense")), .body)
        XCTAssertEqual(PageTextStyle.heading.next, .body)
        XCTAssertEqual(PageTextStyle.caption.next, .caption)
    }

    func testListsToggleAndIndentsClamp() {
        var text = RichText(plain: "a\nb\nc")
        text = PageTextModel.settingList(.bullet, paragraphs: 0..<2, in: text)
        XCTAssertEqual(text.paragraphs.map { $0.list }, [.bullet, .bullet, .plain])
        text = PageTextModel.settingList(.bullet, paragraphs: 0..<2, in: text)
        XCTAssertEqual(text.paragraphs.map { $0.list }, [.plain, .plain, .plain], "the same list again removes it")
        text = PageTextModel.settingList(.todo, paragraphs: 2..<3, in: text)
        text = PageTextModel.togglingChecked(2, in: text)
        XCTAssertTrue(text.paragraphs[2].checked)
        text = PageTextModel.settingList(.todo, paragraphs: 2..<3, in: text, toggles: false)
        XCTAssertEqual(text.paragraphs[2].list, .todo, "the list menu sets, never toggles")
        text = PageTextModel.settingList(.number, paragraphs: 2..<3, in: text)
        XCTAssertFalse(text.paragraphs[2].checked)

        text = PageTextModel.indenting(by: 10, paragraphs: 0..<3, in: text)
        XCTAssertEqual(text.paragraphs.map { $0.indent }, [6, 6, 6])
        text = PageTextModel.indenting(by: -1, paragraphs: 0..<1, in: text)
        text = PageTextModel.indenting(by: -9, paragraphs: 2..<9, in: text)
        XCTAssertEqual(text.paragraphs.map { $0.indent }, [5, 6, 0])
    }

    // MARK: Layout

    func testCaretSpotsSurviveListMarkers() {
        let rich = RichText(paragraphs: [Paragraph(runs: [TextRun("one")], list: .bullet),
                                         Paragraph(runs: [TextRun("two")], list: .number)])
        let marked = RichTextBridge.attributed(rich)                                   // "• one\n1. two"
        let plain = RichTextBridge.attributed(PageTextModel.settingList(.plain, paragraphs: 0..<2, in: rich,
                                                                        toggles: false)) // "one\ntwo"
        XCTAssertEqual(PageTextLayout.paragraphRanges(marked).count, 2)
        XCTAssertEqual(PageTextLayout.spot(at: 5, in: marked), TextSpot(paragraph: 0, offset: 3))
        XCTAssertEqual(PageTextLayout.spot(at: 0, in: marked), TextSpot(paragraph: 0, offset: 0))
        let spot = TextSpot(paragraph: 1, offset: 2)
        XCTAssertEqual(PageTextLayout.offset(of: spot, in: marked), 11)
        XCTAssertEqual(PageTextLayout.offset(of: spot, in: plain), 6)
        XCTAssertEqual(PageTextLayout.paragraphRanges(NSAttributedString(string: "a\n")).count, 2)
    }

    func testTextMustFitThePage() {
        let base = PageTextModel.boxStyle().defaults
        let line = RichTextBridge.attributed(RichText(plain: "Hello"), base: base)
        let lineAndReturn = RichTextBridge.attributed(RichText(plain: "Hello\n"), base: base)
        let many = RichTextBridge.attributed(RichText(plain: Array(repeating: "Line", count: 40).joined(separator: "\n")),
                                             base: base)
        let box = CGSize(width: 400, height: 100)
        XCTAssertTrue(PageTextLayout.fits(line, in: box))
        XCTAssertFalse(PageTextLayout.fits(many, in: box))
        XCTAssertGreaterThan(PageTextLayout.usedHeight(lineAndReturn, width: box.width),
                             PageTextLayout.usedHeight(line, width: box.width), "an empty last line takes room")
        let page = CGSize(width: 500, height: 700)
        XCTAssertEqual(PageTextLayout.contentScale(zoom: 1, screenScale: 2, boxSize: page), 2)
        let deep = PageTextLayout.contentScale(zoom: 8, screenScale: 2, boxSize: page)
        XCTAssertLessThanOrEqual(deep * deep * page.width * page.height, 4_000_001, "about 4 M pixels at most")
        XCTAssertGreaterThan(deep, 2)
    }

    // MARK: Editor

    func testEditorOpensOverTheBoxAndCommitsOneUndoStep() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(FakeItemUpdate.self)
        let host = FakeCanvasHost(h)
        let editor = PageTextEditor()
        editor.attach(to: host)
        defer { editor.detach(from: host) }

        let (page, id) = try await start(h, page2Ref)
        XCTAssertEqual(host.hidden[page], [id], "the drawn box hides under the live text view")
        XCTAssertTrue(h.session.isEditingText)
        XCTAssertTrue(editor.hitTest(host.viewPoint(Point(300, 400), page: page), host: host))
        XCTAssertFalse(editor.hitTest(host.viewPoint(Point(4, 4), page: page), host: host))
        let tv = try XCTUnwrap(textView(host))

        let depth = h.undoDepth(Fixtures.docID)
        XCTAssertTrue(typeText("Hello", editor, tv))
        editor.perform(key: "style.heading")
        editor.perform(key: "list.bullet")
        editor.finish()
        XCTAssertFalse(h.session.isEditingText)

        let committed = await eventually { self.boxText(h, page, id)?.paragraphs.first?.list == .bullet }
        XCTAssertTrue(committed)
        let text = try XCTUnwrap(boxText(h, page, id))
        XCTAssertEqual(text.plainText, "Hello", "the typed text reaches the locked box")
        XCTAssertEqual(text.paragraphs.first?.style, PageTextStyle.heading.rawValue)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1, "one typing session is one undo step")
        let shown = await eventually { host.hidden[page] == nil }
        XCTAssertTrue(shown, "the drawn box shows again once it has the final text")
    }

    func testDebouncedCommitsMergeIntoOneUndoStep() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(FakeItemUpdate.self)
        let host = FakeCanvasHost(h)
        let editor = PageTextEditor()
        editor.attach(to: host)
        defer { editor.detach(from: host) }

        let (page, id) = try await start(h, page2Ref)
        let tv = try XCTUnwrap(textView(host))
        let depth = h.undoDepth(Fixtures.docID)
        XCTAssertTrue(typeText("One", editor, tv))
        let first = await eventually { self.boxText(h, page, id)?.plainText == "One" }
        XCTAssertTrue(first, "committed while typing, before Done")
        XCTAssertTrue(typeText(" two", editor, tv))
        let second = await eventually { self.boxText(h, page, id)?.plainText == "One two" }
        XCTAssertTrue(second)
        editor.finish()
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1, "every commit of one session is one undo step")

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(boxText(h, page, id)?.plainText, "")
    }

    func testEditorReloadsOnOutsideChangesAndUndoStartsANewStep() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(FakeItemUpdate.self)
        let host = FakeCanvasHost(h)
        let editor = PageTextEditor()
        editor.attach(to: host)
        defer { editor.detach(from: host) }

        let (page, id) = try await start(h, page2Ref)
        let tv = try XCTUnwrap(textView(host))
        XCTAssertTrue(typeText("Mine", editor, tv))
        let mine = await eventually { self.boxText(h, page, id)?.plainText == "Mine" }
        XCTAssertTrue(mine)
        let depth = h.undoDepth(Fixtures.docID)

        // Another undo group writes the box (the assistant, a plugin, sync): the open editor shows it.
        let ref = NodeRef.item(Fixtures.docID, page, id).description
        try await h.run(CommandIDs.itemUpdate, ["ref": .string(ref), "patch": ["text": ["text": "Theirs"]]])
        XCTAssertEqual(tv.text, "Theirs")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)

        // Undo while typing reloads the view, and typing afterwards is a new undo step.
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(tv.text, "Mine")
        XCTAssertTrue(h.session.isEditingText)
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        XCTAssertTrue(typeText("!", editor, tv))
        let again = await eventually { self.boxText(h, page, id)?.plainText == "Mine!" }
        XCTAssertTrue(again)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1, "not merged into the step before the undo")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(boxText(h, page, id)?.plainText, "Mine")
        XCTAssertEqual(tv.text, "Mine")
    }

    func testAnInsertThatDoesNotFitIsRejectedAndOffersANewPage() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(FakeItemUpdate.self)
        let host = FakeCanvasHost(h)
        let editor = PageTextEditor()
        editor.attach(to: host)
        defer { editor.detach(from: host) }

        _ = try await start(h, page2Ref)
        let tv = try XCTUnwrap(textView(host))
        XCTAssertFalse(editor.pageFull)
        let tooLong = Array(repeating: "Line", count: 200).joined(separator: "\n")
        XCTAssertFalse(typeText(tooLong, editor, tv), "typing never reflows past the page")
        XCTAssertEqual(tv.text, "")
        XCTAssertTrue(editor.pageFull, "the bar offers \"Add page to continue\"")
        XCTAssertTrue(typeText("Fits", editor, tv))
        XCTAssertEqual(tv.text, "Fits")
    }

    func testAddPageAndContinueIsOneUndoStep() async throws {
        let h = Harness(features: [FeatPageTextFeature.self])
        h.app.commands.register(FakeItemUpdate.self)
        h.app.commands.register(FakePageAdd.self)
        let host = FakeCanvasHost(h)
        let editor = PageTextEditor()
        editor.attach(to: host)
        defer { editor.detach(from: host) }

        _ = try await start(h, page2Ref)
        let depth = h.undoDepth(Fixtures.docID)
        let before = Set(try h.app.workspace.content(Fixtures.docID).livePages.map { $0.id })
        editor.addPageAndContinue()

        var added: PageID?
        let done = await eventually {
            guard let content = try? h.app.workspace.content(Fixtures.docID),
                  let page = content.livePages.map({ $0.id }).first(where: { !before.contains($0) }) else { return false }
            added = page
            return ((try? h.app.workspace.items(Fixtures.docID, page: page)) ?? []).contains(where: PageTextModel.isFullPageBox)
        }
        XCTAssertTrue(done)
        let page = try XCTUnwrap(added)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1, "the page and its box are one undo step")
        let box = try XCTUnwrap(try h.app.workspace.items(Fixtures.docID, page: page).first(where: PageTextModel.isFullPageBox))

        // The canvas lays the new page out, and typing goes on there.
        host.pages.append(page)
        editor.canvasDidChange(host)
        XCTAssertEqual(host.hidden[page], [box.id])
        XCTAssertTrue(h.session.isEditingText)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).livePages.first(where: { $0.id == page }))
        XCTAssertFalse(h.session.isEditingText, "undoing the page ends typing on it")
    }

    // MARK: Helpers

    /// Runs `text.startPageText` as the user; returns the page and item of the box.
    private func start(_ h: Harness, _ pageRef: String) async throws -> (PageID, ElementID) {
        let r = try await h.run("text.startPageText", ["page": .string(pageRef)])
        guard case let .item(_, page, id)? = NodeRef(r["ref"]?.stringValue ?? "") else {
            throw NibError.invalid("no item ref")
        }
        return (page, id)
    }

    private func textView(_ host: FakeCanvasHost) -> PageTextView? {
        host.canvasView.subviews.lazy.compactMap { $0 as? PageTextView }.first
    }

    private func boxText(_ h: Harness, _ page: PageID, _ id: ElementID) -> RichText? {
        (try? h.app.workspace.item(Fixtures.docID, page: page, id: id))?.text?.text
    }

    /// Types `text` at the caret the way the keyboard does: ask the delegate, change the text, report the change.
    private func typeText(_ text: String, _ editor: PageTextEditor, _ tv: UITextView) -> Bool {
        let range = tv.selectedRange
        guard editor.textView(tv, shouldChangeTextIn: range, replacementText: text) else { return false }
        tv.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: tv.typingAttributes))
        tv.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        editor.textViewDidChange(tv)
        return true
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
