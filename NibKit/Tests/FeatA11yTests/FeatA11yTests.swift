import XCTest
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatA11y

@MainActor
final class FeatA11yTests: XCTestCase {
    private let page1Ref = NodeRef.page(Fixtures.docID, Fixtures.page1).description

    private func harness(recognizer: TextRecognizer? = nil) -> Harness {
        let h = Harness(features: [FeatA11yFeature.self])
        h.app.services.recognizer = recognizer
        return h
    }

    private func ref(_ id: ElementID) -> String { NodeRef.item(Fixtures.docID, Fixtures.page1, id).description }

    private func describe(_ h: Harness, _ params: JSONValue? = nil, as principal: Principal = .user) async throws -> PageDescription {
        let value = try await h.run(CommandIDs.a11yDescribePage, params ?? ["page": .string(page1Ref)], as: principal)
        return try value.decode(PageDescription.self)
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

    /// Handwriting on the fixture stroke (72…148, 120…124).
    private func handwritingRecognizer() -> FakeRecognizer {
        FakeRecognizer([TextRecognition(text: "Kinematics  SUVAT", bbox: Rect(x: 72, y: 116, width: 80, height: 12),
                                        itemIDs: [Fixtures.strokeID], source: "vision")])
    }

    // MARK: Registration and conformance

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatA11yFeature.self], owners: [FeatA11yFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandPanelMenuKeyAndSettings() {
        let h = harness()
        XCTAssertEqual(FeatA11yFeature.id, "a11y")
        let d = h.app.commands.descriptor(CommandIDs.a11yDescribePage)
        XCTAssertEqual(d?.owner, FeatA11yFeature.id)
        XCTAssertEqual(d?.effect, .read)
        XCTAssertEqual(h.app.commands.all().filter { $0.owner == FeatA11yFeature.id }.map { $0.id }, ["a11y.describePage"])
        let panel = h.app.ui.panels.get(PageContentsChrome.panelID)
        XCTAssertEqual(panel?.placement, .floating, "a floating panel until start() knows whether VoiceOver runs")
        XCTAssertEqual(panel?.docKinds, [.notebook, .whiteboard])
        XCTAssertEqual(h.app.ui.menus.get(PageContentsChrome.menuID)?.command, CommandIDs.panelOpen)
        XCTAssertEqual(h.app.ui.menus.get(PageContentsChrome.menuID)?.location, .documentMore)
        let key = h.app.content.keyCommands.get(PageContentsChrome.keyID)
        XCTAssertEqual(key?.shortcut, KeyShortcut("i", [.command, .option]))
        XCTAssertEqual(key?.params["id"]?.stringValue, PageContentsChrome.panelID)
        XCTAssertEqual(key?.docKinds, [.notebook, .whiteboard])
        XCTAssertNotNil(h.app.ui.settingsPages.get(PageContentsChrome.settingsID))
        XCTAssertEqual(h.app.settings.descriptor(A11ySettings.pageContentsTab.name)?.synced, false)
    }

    func testPageContentsIsASidebarTabWithVoiceOverOrWhenAlwaysOn() async throws {
        XCTAssertEqual(PageContentsChrome.placement(mode: "auto", voiceOver: true), .sidebarTab)
        XCTAssertEqual(PageContentsChrome.placement(mode: "auto", voiceOver: false), .floating)
        XCTAssertEqual(PageContentsChrome.placement(mode: "on", voiceOver: false), .sidebarTab)
        XCTAssertEqual(PageContentsChrome.placement(mode: "off", voiceOver: true), .floating)

        let h = harness()
        PageContentsChrome.sync(h.app, voiceOver: true)
        XCTAssertEqual(h.app.ui.panels.get(PageContentsChrome.panelID)?.placement, .sidebarTab)
        XCTAssertEqual(h.app.ui.panels.get(PageContentsChrome.panelID)?.owner, FeatA11yFeature.id)
        // The setting goes through settings.set like every other write, and is validated against its choices.
        try await h.run(CommandIDs.settingsSet, ["name": "a11y.pageContentsTab", "value": "off"])
        PageContentsChrome.sync(h.app, voiceOver: true)
        XCTAssertEqual(h.app.ui.panels.get(PageContentsChrome.panelID)?.placement, .floating)
        await assertError(.invalidParams) {
            try await h.run(CommandIDs.settingsSet, ["name": "a11y.pageContentsTab", "value": "sometimes"], as: .ai("t"))
        }
    }

    // MARK: a11y.describePage

    func testDescribesEveryItemWithRecognisedHandwritingInReadingOrder() async throws {
        let recognizer = handwritingRecognizer()
        let h = harness(recognizer: recognizer)
        h.app.content.customItemTypes.register(CustomItemTypeDescriptor(owner: "nib.fixture", type: "box",
                                                                        title: "Fixture Box", textPath: "title"))
        let d = try await describe(h)
        XCTAssertEqual(d.page, page1Ref)
        XCTAssertEqual(d.index, 1)
        XCTAssertEqual(d.pageCount, 3)
        XCTAssertEqual(d.recognition, "recognised")
        XCTAssertEqual(recognizer.strokeCalls, 1)
        XCTAssertFalse(d.truncated)
        XCTAssertEqual(d.total, d.items.count)

        let handwriting = try XCTUnwrap(d.items.first { $0.kind == .handwriting })
        XCTAssertEqual(handwriting.text, "Kinematics SUVAT", "whitespace is collapsed")
        XCTAssertEqual(handwriting.refs, [ref(Fixtures.strokeID)])
        XCTAssertTrue(handwriting.label.contains("Kinematics SUVAT"))
        XCTAssertFalse(d.items.contains { $0.kind == .drawing }, "the recognised stroke is not also a drawing")

        XCTAssertEqual(d.items.first { $0.kind == .text }?.text, "Hello Nib")
        XCTAssertEqual(d.items.first { $0.kind == .sticky }?.text, "Remember")
        XCTAssertEqual(d.items.first { $0.kind == .math }?.text, "\\frac{a}{b}")
        XCTAssertEqual(d.items.first { $0.kind == .comment }?.text, "Fixture: Check this")
        let custom = try XCTUnwrap(d.items.first { $0.kind == .custom })
        XCTAssertEqual(custom.title, "Fixture Box")
        XCTAssertEqual(custom.text, "Fixture box")
        for kind: EntryKind in [.shape, .connector, .image, .tape] {
            XCTAssertEqual(d.items.filter { $0.kind == kind }.count, 1, kind.rawValue)
        }
        XCTAssertEqual(d.counts["text"], 1)
        XCTAssertEqual(d.items.count, 10)

        // Reading order: the handwriting (y 120, x 72) and the sticky note (y 120, x 400) share a line, the text box
        // (y 400) comes after both.
        let order = d.items.map { $0.kind }
        let hw = try XCTUnwrap(order.firstIndex(of: .handwriting))
        let sticky = try XCTUnwrap(order.firstIndex(of: .sticky))
        let text = try XCTUnwrap(order.firstIndex(of: .text))
        XCTAssertLessThan(hw, sticky)
        XCTAssertLessThan(sticky, text)

        // Every item offers Show on Page (view.reveal) and Select (selection.set) with its refs.
        let goTo = try XCTUnwrap(handwriting.actions.first { $0.id == "goTo" })
        XCTAssertEqual(goTo.command, CommandIDs.viewReveal)
        XCTAssertEqual(goTo.params["ref"]?.stringValue, ref(Fixtures.strokeID))
        let select = try XCTUnwrap(handwriting.actions.first { $0.id == "select" })
        XCTAssertEqual(select.command, CommandIDs.selectionSet)
        XCTAssertEqual(select.params["refs"], [.string(ref(Fixtures.strokeID))])
        XCTAssertFalse(select.available, "selection.set belongs to F011, which this test does not install")

        let comment = try XCTUnwrap(d.items.first { $0.kind == .comment })
        let open = try XCTUnwrap(comment.actions.first)
        XCTAssertEqual(open.id, "openComment")
        XCTAssertEqual(open.command, CommandIDs.commentTapAt)
        XCTAssertEqual(open.params["point"], [560, 400])
    }

    func testTapeOffersRevealAndHidesWhatItCovers() async throws {
        let h = harness(recognizer: handwritingRecognizer())
        // A text box whose centre (150, 600) lies under the fixture tape (80…260 at y 600, 18 pt wide).
        var answer = Item.makeText(TextBoxItem(frame: Frame(x: 100, y: 590, w: 100, h: 20),
                                               text: RichText(plain: "The answer is 42")))
        answer.id = "A11YANSWER01"
        var highlight = Item.makeStroke(Stroke(style: .defaultHighlighter, points: [
            StrokePoint(x: 100, y: 600, width: 20, height: 20),
            StrokePoint(x: 200, y: 600, width: 20, height: 20),
        ]))
        highlight.id = "A11YHILITE01"
        try await h.insert([answer, highlight])
        let d = try await describe(h)
        let tape = try XCTUnwrap(d.items.first { $0.kind == .tape })
        XCTAssertEqual(tape.revealed, false)
        let reveal = try XCTUnwrap(tape.actions.first)
        XCTAssertEqual(reveal.id, "revealTape")
        XCTAssertEqual(reveal.command, CommandIDs.tapeSetRevealed)
        XCTAssertEqual(reveal.params["refs"], [.string(ref(Fixtures.tapeID))])
        XCTAssertEqual(reveal.params["revealed"], true)

        let covered = try XCTUnwrap(d.items.first { $0.kind == .text && $0.coveredByTape == true })
        XCTAssertEqual(covered.kind, .text)
        XCTAssertNil(covered.text, "hidden tape keeps its answer hidden from VoiceOver too")
        XCTAssertFalse(covered.label.contains("42"))
        XCTAssertEqual(covered.actions.first?.id, "revealTape")
        XCTAssertEqual(d.items.first { $0.kind == .highlight }?.coveredByTape, true)
        XCTAssertFalse(try JSONValue.from(d).jsonString().contains("42"))
    }

    func testRevealedTapeOffersHideAndCoversNothing() async throws {
        let h = harness()
        var tape = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.tapeID)
        tape.stroke?.tapeRevealed = true
        try await h.insert([tape, Item.makeText(TextBoxItem(frame: Frame(x: 100, y: 590, w: 100, h: 20),
                                                            text: RichText(plain: "Visible")))])
        let d = try await describe(h)
        XCTAssertEqual(d.items.first { $0.kind == .tape }?.actions.first?.id, "hideTape")
        XCTAssertEqual(d.items.first { $0.kind == .tape }?.actions.first?.params["revealed"], false)
        XCTAssertNil(d.items.first { $0.coveredByTape == true })
        XCTAssertTrue(d.items.contains { $0.text == "Visible" })
    }

    func testLinksInTextBecomeOpenLinkActions() async throws {
        let h = harness()
        let text = RichText(paragraphs: [Paragraph(runs: [
            TextRun("See "),
            TextRun("the syllabus", TextAttributes(link: TextLink(url: "https://example.com/syllabus"))),
            TextRun(" and "),
            TextRun("page two", TextAttributes(link: TextLink(page: Fixtures.page2))),
        ])])
        try await h.insert([Item.makeText(TextBoxItem(frame: Frame(x: 72, y: 760, w: 300, h: 30), text: text))])
        let d = try await describe(h)
        let entry = try XCTUnwrap(d.items.first { $0.text == "See the syllabus and page two" })
        let links = entry.actions.filter { $0.id == "openLink" }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].command, CommandIDs.linkFollow)
        XCTAssertEqual(links[0].params, ["url": "https://example.com/syllabus"])
        XCTAssertTrue(links[0].title.contains("the syllabus"))
        XCTAssertEqual(links[1].params["doc"]?.stringValue, "doc:FIXTUREDOC01")
        XCTAssertEqual(links[1].params["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page2).description)
    }

    func testWithoutRecognitionHandwritingIsListedAsDrawing() async throws {
        let h = harness()
        let d = try await describe(h)
        XCTAssertEqual(d.recognition, "unavailable")
        let drawing = try XCTUnwrap(d.items.first { $0.kind == .drawing })
        XCTAssertNil(drawing.text)
        XCTAssertEqual(drawing.refs, [ref(Fixtures.strokeID)])
        XCTAssertNil(d.items.first { $0.kind == .handwriting })
    }

    func testHighlightReadsTheTextUnderIt() async throws {
        let h = harness()
        let points = [StrokePoint(x: 70, y: 420, width: 12, height: 12), StrokePoint(x: 370, y: 420, width: 12, height: 12)]
        try await h.insert([Item.makeStroke(Stroke(style: .defaultHighlighter, points: points))])
        let d = try await describe(h)
        let highlight = try XCTUnwrap(d.items.first { $0.kind == .highlight })
        XCTAssertEqual(highlight.text, "Hello Nib")
    }

    func testPageDefaultsToTheWindowForTheUserOnly() async throws {
        let h = harness()
        let d = try await describe(h, [:])
        XCTAssertEqual(d.page, page1Ref)
        await assertError(.invalidParams) { _ = try await self.describe(h, [:], as: .ai("t")) }
        let ai = try await describe(h, ["page": .string(page1Ref)], as: .ai("t"))
        XCTAssertEqual(ai.items.count, d.items.count)
    }

    func testRejectsBadRefsUnknownPagesAndLockedDocuments() async {
        let h = harness()
        await assertError(.invalidParams) { _ = try await self.describe(h, ["page": "doc:FIXTUREDOC01"]) }
        await assertError(.notFound) { _ = try await self.describe(h, ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"]) }
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        await assertError(.locked) { _ = try await self.describe(h) }
    }

    func testBoardsAndEmptyPages() async throws {
        let h = harness()
        let board = try await describe(h, ["page": .string(NodeRef.page(Fixtures.whiteboardID, Fixtures.boardID).description)])
        XCTAssertFalse(board.title.isEmpty)
        XCTAssertFalse(board.items.isEmpty)
        let empty = try await describe(h, ["page": .string(NodeRef.page(Fixtures.docID, Fixtures.page2).description)])
        XCTAssertEqual(empty.index, 2)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.summary.split(separator: "\n").count, 2)
    }

    func testEntriesOnLayersTheWindowHidesAreMarked() async throws {
        let h = harness()
        h.session.hiddenLayers = [0]
        let d = try await describe(h)
        XCTAssertTrue(d.items.allSatisfy { $0.hidden == true })
        XCTAssertTrue(d.counts.isEmpty)
        XCTAssertFalse(d.summary.contains("This page has"))
        h.session.hiddenLayers = []
        let shown = try await describe(h)
        XCTAssertTrue(shown.items.allSatisfy { $0.hidden == nil })
    }

    func testLargeClusterUsesRectangleSelectionWithinToolBudget() async throws {
        let h = harness()
        let strokes = (0..<500).map { i in
            Item.makeStroke(Stroke(style: .defaultPen, points: [
                StrokePoint(x: Float(i), y: 1000), StrokePoint(x: Float(i + 2), y: 1002),
            ]))
        }
        try await h.insert(strokes)
        var cursor: String?
        var entries: [PageEntry] = []
        repeat {
            var params: [String: JSONValue] = ["page": .string(page1Ref)]
            if let cursor { params["cursor"] = .string(cursor) }
            let value = try await h.run(CommandIDs.a11yDescribePage, .object(params), as: .ai("budget"))
            XCTAssertLessThan(value.jsonString().utf8.count, NibLimits.aiToolResultBytes)
            let result = try value.decode(PageDescription.self)
            entries += result.items
            cursor = result.cursor
        } while cursor != nil
        let cluster = try XCTUnwrap(entries.first { $0.refCount == 500 })
        XCTAssertEqual(cluster.refs.count, PageDescriber.maxRefs)
        let select = try XCTUnwrap(cluster.actions.first { $0.id == "select" })
        XCTAssertEqual(select.command, CommandIDs.selectionFromRect)
        XCTAssertEqual(select.params["page"]?.stringValue, page1Ref)
        XCTAssertEqual(try select.params["rect"]?.decode(Rect.self), cluster.bbox)
        XCTAssertNil(select.params["refs"])
        XCTAssertEqual(cluster.actions.first { $0.id == "goTo" }?.params["ref"]?.stringValue, cluster.refs.first)
    }

    func testCursorReusesRecognitionRejectsEditsAndRetainsMoreThan400Entries() async throws {
        let recognizer = handwritingRecognizer()
        let h = harness(recognizer: recognizer)
        try await h.insert((0..<450).map { i in
            Item.makeText(TextBoxItem(frame: Frame(x: 72, y: Double(i) * 30 + 1100, w: 200, h: 20),
                                      text: RichText(plain: "Line \(i)")))
        })
        let first = try await describe(h)
        let oldCursor = try XCTUnwrap(first.cursor)
        XCTAssertTrue(oldCursor.contains(":"))
        var all = first.items
        var cursor = first.cursor
        while let next = cursor {
            let more = try await describe(h, ["page": .string(page1Ref), "cursor": .string(next)])
            XCTAssertLessThan(try JSONEncoder().encode(more).count, NibLimits.aiToolResultBytes)
            all += more.items
            cursor = more.cursor
        }
        XCTAssertEqual(all.count, 460)
        XCTAssertEqual(first.total, 460)
        XCTAssertEqual(Set(all.map { $0.id }).count, all.count)
        XCTAssertEqual(recognizer.strokeCalls, 1, "one recognition for all cursor pages")
        _ = try await describe(h)
        XCTAssertEqual(recognizer.strokeCalls, 1, "a reload of the same version reuses recognition")
        try await h.insert([Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 10, w: 50, h: 20),
                                                     text: RichText(plain: "Changed")))])
        await assertError(.invalidParams) {
            _ = try await self.describe(h, ["page": .string(self.page1Ref), "cursor": .string(oldCursor)])
        }
        let refreshed = try await describe(h)
        XCTAssertEqual(refreshed.total, 461)
        XCTAssertEqual(recognizer.strokeCalls, 2)
        await assertError(.invalidParams) {
            _ = try await self.describe(h, ["page": .string(self.page1Ref), "cursor": .string(oldCursor)])
        }
    }

    func testIndexCursorPagesJoinImageOCRAndHaveUniqueInkIDs() async throws {
        let recognizer = handwritingRecognizer()
        let h = harness(recognizer: recognizer)
        var image = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        image.image?.altText = nil
        try await h.insert([image])
        var cursors: [String?] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizePageText, title: "Page Text",
                                                  summary: "Scripted index", params: .obj([
                                                    "page": .ref, "cursor": .str()], required: ["page"]), effect: .read)) { p, _ in
            let cursor = p["cursor"]?.stringValue
            cursors.append(cursor)
            let blocks: [TextRecognition]
            if cursor == nil {
                blocks = [TextRecognition(text: "First ink line", bbox: .zero,
                                          itemIDs: [Fixtures.strokeID], source: "ink"),
                          TextRecognition(text: "First OCR line", bbox: .zero,
                                          itemIDs: [Fixtures.imageID], source: "image")]
            } else {
                XCTAssertEqual(cursor, "second")
                blocks = [TextRecognition(text: "Second ink line", bbox: .zero,
                                          itemIDs: [Fixtures.strokeID], source: "ink"),
                          TextRecognition(text: "Unassigned ink A", bbox: .zero, source: "ink"),
                          TextRecognition(text: "Unassigned ink B", bbox: .zero, source: "ink"),
                          TextRecognition(text: "Second OCR line", bbox: .zero,
                                          itemIDs: [Fixtures.imageID], source: "image")]
            }
            return ["blocks": try JSONValue.from(blocks), "truncated": .bool(cursor == nil),
                    "cursor": cursor == nil ? "second" : .null]
        }
        let d = try await describe(h)
        XCTAssertEqual(cursors.count, 2)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1], "second")
        XCTAssertEqual(recognizer.strokeCalls, 0)
        XCTAssertEqual(d.items.first { $0.kind == .image }?.text, "First OCR line Second OCR line")
        XCTAssertEqual(d.items.filter { $0.kind == .handwriting }.count, 4)
        XCTAssertEqual(Set(d.items.map { $0.id }).count, d.items.count)
    }

    func testIndexErrorsFallBackToRecognizer() async throws {
        for code: NibError.Code in [.unavailable, .internalError] {
            let recognizer = handwritingRecognizer()
            let h = harness(recognizer: recognizer)
            h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizePageText, title: "Page Text",
                                                      summary: "Failing index", effect: .read)) { _, _ in
                throw NibError(code, "index unavailable")
            }
            let d = try await describe(h)
            XCTAssertEqual(recognizer.strokeCalls, 1)
            XCTAssertEqual(d.items.first { $0.kind == .handwriting }?.text, "Kinematics SUVAT")
        }
    }

    func testPDFBackgroundTextAndLinksUseBackgroundTransform() async throws {
        let h = harness()
        var content = try XCTUnwrap(h.persistence.heads[Fixtures.docID])
        let i = try XCTUnwrap(content.pages.firstIndex { $0.id == Fixtures.pdfPage })
        content.pages[i].rotation = 90
        content.pages[i].size = PageSize(400, 600)
        h.persistence.heads[Fixtures.docID] = content
        let pdf = FakePDFService()
        pdf.texts[Fixtures.pdfAsset.name] = "PDF background text"
        let rect = Rect(x: 80, y: 150, width: 100, height: 30)
        pdf.linkMap[Fixtures.pdfAsset.name] = [PDFLinkInfo(rect: rect, url: "https://example.com/pdf")]
        h.app.services.pdf = pdf
        let d = try await describe(h, ["page": .string(NodeRef.page(Fixtures.docID, Fixtures.pdfPage).description)])
        let transform = content.pages[i].backgroundTransform(sourceSize: .a4)
        let text = try XCTUnwrap(d.items.first { $0.kind == .pdf })
        XCTAssertEqual(text.text, "PDF background text")
        XCTAssertEqual(text.bbox, PageDescriber.apply(transform, to: Rect(x: 72, y: 72, width: 400, height: 20)))
        let link = try XCTUnwrap(d.items.first { $0.kind == .link })
        XCTAssertEqual(link.bbox, PageDescriber.apply(transform, to: rect))
        XCTAssertNotEqual(link.bbox, rect)
        XCTAssertEqual(link.actions.first?.command, CommandIDs.linkFollow)
        XCTAssertEqual(link.actions.first?.params["url"]?.stringValue, "https://example.com/pdf")
    }

    // MARK: Pure logic

    private func entry(_ id: String, _ rect: Rect, kind: EntryKind = .text) -> PageEntry {
        PageEntry(id: id, kind: kind, title: kind.title, label: id, text: id, refs: [id], bbox: rect, layer: 0,
                  hidden: nil, coveredByTape: nil, revealed: nil, actions: [])
    }

    func testReadingOrderGoesByLineThenLeftToRight() {
        let entries = [
            entry("c", Rect(x: 300, y: 205, width: 50, height: 20)),
            entry("d", Rect(x: 10, y: 400, width: 50, height: 20)),
            entry("b", Rect(x: 10, y: 200, width: 50, height: 20)),
            entry("a", Rect(x: 200, y: 50, width: 50, height: 20)),
            // A tall drawing beside two lines overlaps each by less than half of the line: it starts its own line.
            entry("tall", Rect(x: 400, y: 190, width: 100, height: 300)),
        ]
        XCTAssertEqual(ReadingOrder.sorted(entries).map { $0.id }, ["a", "tall", "b", "c", "d"])
    }

    func testClustersJoinStrokesThatTouchAndSplitDistantOnes() {
        func stroke(_ x: Float, _ y: Float) -> Item {
            Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: x, y: y), StrokePoint(x: x + 20, y: y + 10)]))
        }
        let groups = PageDescriber.clusters([stroke(10, 10), stroke(40, 12), stroke(70, 14), stroke(500, 500),
                                             stroke(10, 700)])
        XCTAssertEqual(groups.map { $0.count }.sorted(), [1, 1, 3])
        XCTAssertEqual(PageDescriber.clusters([]).count, 0)
    }

    func testPagingStaysUnderTheResultBudgetAndRoundTrips() throws {
        let long = String(repeating: "word ", count: 100)
        let entries = (0..<200).map { i -> PageEntry in
            var e = entry("e\(i)", Rect(x: 0, y: Double(i) * 30, width: 100, height: 20))
            e.text = long
            return e
        }
        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try PageDescriber.page(entries, cursor: cursor)
            XCTAssertFalse(page.items.isEmpty)
            let bytes = try JSONEncoder().encode(page.items).count
            XCTAssertLessThan(bytes, NibLimits.aiToolResultBytes)
            seen += page.items.map { $0.id }
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 100
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen, entries.map { $0.id })
        XCTAssertThrowsError(try PageDescriber.page(entries, cursor: "banana"))
        XCTAssertThrowsError(try PageDescriber.page(entries, cursor: "test:999"))
        XCTAssertThrowsError(try PageDescriber.page(entries, cursor: "old:1", version: "new"))
    }

    func testTextIsCleanedAndClipped() {
        XCTAssertEqual(PageDescriber.clean("  two\n\nlines\t here "), "two lines here")
        let clipped = PageDescriber.clean(String(repeating: "a", count: 1000))
        XCTAssertEqual(clipped.count, PageDescriber.maxTextLength + 1)
        XCTAssertEqual(PageDescriber.value(at: "series.label", in: ["series": ["label": "Q3"]]), "Q3")
        XCTAssertEqual(PageDescriber.value(at: "n", in: ["n": 3]), "3")
        XCTAssertNil(PageDescriber.value(at: "missing", in: [:]))
    }

    // MARK: Panel

    private func waitForLoad(_ model: PageContentsModel, page: String) async throws -> PageDescription {
        for _ in 0..<200 {
            if let d = model.description, d.page == page { return d }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the panel never loaded \(page) (state \(model.state))")
        throw NibError(.timeout, "not loaded")
    }

    func testPanelModelFollowsTheWindowAndItsEdits() async throws {
        let h = harness(recognizer: handwritingRecognizer())
        let model = PageContentsModel(app: h.app, session: h.session)
        let first = try await waitForLoad(model, page: page1Ref)
        XCTAssertEqual(first.items.count, 10)
        XCTAssertEqual(model.shownRef, page1Ref)

        let page2 = NodeRef.page(Fixtures.docID, Fixtures.page2).description
        h.session.page = Fixtures.page2
        let second = try await waitForLoad(model, page: page2)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(model.direction, 1)

        try await h.insert([Item.makeText(TextBoxItem(frame: Frame(x: 72, y: 72, w: 200, h: 30), text: RichText(plain: "New")))],
                           page: Fixtures.page2)
        for _ in 0..<200 where model.description?.items.isEmpty != false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.description?.items.first?.text, "New")

        let added = try XCTUnwrap(model.description?.items.first)
        guard case let .item(_, _, id)? = NodeRef(added.refs.first ?? "") else { return XCTFail("not an item ref") }
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page2, items: [id])
        XCTAssertTrue(model.isSelected(added))

        h.session.document = nil
        XCTAssertEqual(model.state, .noPage)
    }

    func testSupersededPanelLoadStopsRecognitionCursorLoop() async throws {
        let h = harness()
        var firstPageCalls = 0
        var enteredRecognition = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizePageText, title: "Page Text",
                                                  summary: "Delayed index", effect: .read)) { p, _ in
            guard p["page"]?.stringValue == self.page1Ref else {
                return ["blocks": [], "truncated": false]
            }
            firstPageCalls += 1
            enteredRecognition = true
            // Deliberately ignore cancellation, like an already-running system recognizer.
            try? await Task.sleep(nanoseconds: 200_000_000)
            return ["blocks": [], "truncated": true, "cursor": "next"]
        }
        let model = PageContentsModel(app: h.app, session: h.session)
        for _ in 0..<200 where !enteredRecognition { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(enteredRecognition)
        h.session.page = Fixtures.page2
        let page2Ref = NodeRef.page(Fixtures.docID, Fixtures.page2).description
        let result = try await waitForLoad(model, page: page2Ref)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(firstPageCalls, 1, "a cancelled load must not ask for the next recognition page")
        XCTAssertEqual(model.shownRef, page2Ref)
    }

    func testPanelShowsLockedDocuments() async throws {
        let h = harness()
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        let model = PageContentsModel(app: h.app, session: h.session)
        for _ in 0..<200 where model.state != .locked { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.state, .locked)
    }

    func testRowsGrowWithDynamicTypeAndTheViewsRender() throws {
        var e = entry("item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", Rect(x: 0, y: 0, width: 10, height: 10))
        e.text = "The mitochondria is the powerhouse of the cell, and this line is long enough to wrap."
        e.actions = [EntryAction(id: "goTo", title: "Show on Page", command: CommandIDs.viewReveal,
                                 params: ["ref": .string(e.id)], available: true),
                     EntryAction(id: "select", title: "Select", command: CommandIDs.selectionSet,
                                 params: ["refs": [.string(e.id)]], available: true)]
        let row = PageEntryRow(entry: e, isSelected: false, perform: { _ in })
        let regular = NibSnapshot.fittingSize(row, width: 280, variant: .light)
        let large = NibSnapshot.fittingSize(row, width: 280, variant: .largeText)
        XCTAssertGreaterThanOrEqual(regular.height, 44)
        XCTAssertGreaterThan(large.height, regular.height)
        for variant in NibSnapshot.Variant.allCases {
            XCTAssertNotNil(NibSnapshot.image(row, size: CGSize(width: 280, height: 120), variant: variant), variant.rawValue)
        }

        let h = harness()
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        XCTAssertNotNil(NibSnapshot.image(PageContentsPanelRoot(context: context), size: CGSize(width: 320, height: 600)))
        XCTAssertEqual(PageEntryRow.symbol(.handwriting), .editHandwriting)
        XCTAssertEqual(PageContentsModel.announcement(for: "revealTape"), "Tape revealed")
        XCTAssertNil(PageContentsModel.announcement(for: "goTo"))
    }

    func testSettingsPageWritesTheTabModeThroughSettingsSet() async throws {
        let h = harness()
        let model = A11ySettingsModel(app: h.app)
        XCTAssertEqual(model.tabMode, "auto")
        model.setTabMode("on")
        for _ in 0..<200 where h.app.settings.get(A11ySettings.pageContentsTab) != "on" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(h.app.settings.get(A11ySettings.pageContentsTab), "on")
        for mode in A11ySettings.tabModes { XCTAssertFalse(A11ySettingsModel.title(mode).isEmpty) }
        XCTAssertFalse(A11ySettingsModel.appLanguage.isEmpty)
    }

    // MARK: String catalog (P-087)

    private static let locales = ["de", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "sv", "tr", "zh-Hans", "zh-Hant"]

    private func catalog() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FeatA11yTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NibKit
            .deletingLastPathComponent() // repository root
        let data = try Data(contentsOf: root.appendingPathComponent("Nib/Resources/Localizable.xcstrings"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Conversions of the format specifiers in `s`, in argument order (%1$@ and %@ are both "@").
    static func specifiers(_ s: String) -> [String] {
        let pattern = "%(?:(\\d+)\\$)?[-+ #0']*(?:\\d+|\\*)?(?:\\.(?:\\d+|\\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = s.replacingOccurrences(of: "%%", with: "")
        let ns = text as NSString
        var found: [(Int?, String)] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let position = m.range(at: 1).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 1)))
            let length = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            found.append((position, length + ns.substring(with: m.range(at: 3))))
        }
        if !found.isEmpty && found.allSatisfy({ $0.0 != nil }) {
            return found.sorted { ($0.0 ?? 0) < ($1.0 ?? 0) }.map { $0.1 }
        }
        return found.map { $0.1 }
    }

    func testStringCatalogIsCompleteInFifteenLanguages() throws {
        let c = try catalog()
        XCTAssertEqual(c["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(c["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 100)
        var problems: [String] = []
        var checked = 0
        for (key, entry) in strings {
            if entry["extractionState"] as? String == "stale" || entry["shouldTranslate"] as? Bool == false { continue }
            checked += 1
            let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
            let source = ((locs["en"]?["stringUnit"] as? [String: Any])?["value"] as? String) ?? key
            let want = Self.specifiers(source)
            for l in Self.locales {
                guard let loc = locs[l] else {
                    problems.append("\(l): \(key) is not translated")
                    continue
                }
                if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
                    if plural["other"] == nil { problems.append("\(l): \(key) has no 'other' plural form") }
                    for (form, unit) in plural {
                        let value = (unit["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                        if value.isEmpty { problems.append("\(l): \(key) plural \(form) is empty") }
                        if !Set(Self.specifiers(value)).isSubset(of: Set(want)) {
                            problems.append("\(l): \(key) plural \(form) has specifiers \(Self.specifiers(value))")
                        }
                    }
                    continue
                }
                let value = ((loc["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                if value.isEmpty { problems.append("\(l): \(key) is empty") }
                if Self.specifiers(value) != want {
                    problems.append("\(l): \(key) → \(value) has specifiers \(Self.specifiers(value)), wanted \(want)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(Array(problems.sorted().prefix(40)), [], "\(problems.count) catalog problems")
    }

    func testCatalogHasThisFeaturesStringsWithPluralForms() throws {
        let strings = try XCTUnwrap(try catalog()["strings"] as? [String: [String: Any]])
        for key in ["Page Contents", "Page %lld of %lld", "Handwriting: %@", "Reveal Tape", "Show on Page",
                    "This page has %@.", "Tape, hidden", "%@, covered by tape"] {
            XCTAssertNotNil(strings[key], key)
        }
        for key in ["%lld links", "%lld lines of handwriting", "%lld pieces of tape"] {
            let locs = try XCTUnwrap(strings[key]?["localizations"] as? [String: [String: Any]], key)
            let en = (locs["en"]?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            XCTAssertNotNil(en?["one"], "\(key): English needs its singular")
            let ru = (locs["ru"]?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            XCTAssertEqual(Set(ru?.keys.map { $0 } ?? []), ["one", "few", "many", "other"], key)
        }
        XCTAssertEqual(Self.specifiers("%2$@ von %1$lld"), ["lld", "@"])
        XCTAssertEqual(Self.specifiers("100%% %@"), ["@"])
    }
}
