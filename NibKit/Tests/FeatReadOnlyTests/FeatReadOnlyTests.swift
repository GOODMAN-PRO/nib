import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
@testable import FeatReadOnly

/// Read-only mode, the PDF text marks and their undo round trip, the long-press selection and its handles.
@MainActor
final class FeatReadOnlyTests: XCTestCase {
    private let pdfPage: JSONValue = "page:FIXTUREDOC01/FIXTUREPG003"

    /// The fixture notebook with a scripted PDF engine whose fixture PDF reads "Fixture PDF text" (`pdf: nil` = none).
    private func harness(pdf: PDFService? = FakePDFService()) -> Harness {
        let h = Harness(features: [FeatReadOnlyFeature.self])
        if let fake = pdf as? FakePDFService { fake.texts[Fixtures.pdfAsset.name] = "Fixture PDF text" }
        h.app.services.pdf = pdf
        return h
    }

    private func assertThrows(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func pdfItems(_ h: Harness) throws -> [Item] {
        try h.app.workspace.items(Fixtures.docID, page: Fixtures.pdfPage)
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatReadOnlyFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersTheCommandsTheLongPressHandlerAndTheEditEntry() throws {
        let h = harness()
        for id in ["view.setReadOnly", "pdf.markSelection", "pdf.copyText", "pdf.tapAt"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatReadOnlyFeature.id, id)
        }
        let handler = try XCTUnwrap(h.app.content.tapHandlers.get("pdf.tapAt"))
        XCTAssertEqual(handler.gesture, .longPress)
        XCTAssertTrue(handler.worksInReadOnly)
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(FeatReadOnlyFeature.pdfTextAttachment))
        XCTAssertEqual(h.app.content.keyCommands.get(FeatReadOnlyFeature.toggleKey)?.command, "view.setReadOnly")
        XCTAssertEqual(h.app.ui.menus.get(FeatReadOnlyFeature.editEntry)?.shortcut, FeatReadOnlyFeature.shortcut,
                       "the Edit entry shows the ⌥⌘R label")
    }

    /// contracts-v2 `isOn` / `sessionParams`: the nav bar's Read Only item shows the window's mode and sends the
    /// opposite, in every kind of document.
    func testNavBarToggleShowsTheModeAndSendsTheOpposite() async throws {
        let h = harness(pdf: nil)
        let toggle = try XCTUnwrap(h.app.ui.toolbar.get(FeatReadOnlyFeature.navItem))
        XCTAssertEqual(toggle.group, .navLeading)
        XCTAssertEqual(toggle.command, "view.setReadOnly")
        XCTAssertEqual(toggle.docKinds, Set(DocumentKind.allCases))
        XCTAssertEqual(toggle.isOn?(h.session), false)
        XCTAssertEqual(toggle.resolvedParams(for: h.session), ["on": true])

        try await h.run("view.setReadOnly", toggle.resolvedParams(for: h.session))
        XCTAssertTrue(h.session.readOnly)
        XCTAssertEqual(toggle.isOn?(h.session), true)
        XCTAssertEqual(toggle.resolvedParams(for: h.session), ["on": false])
        try await h.run("view.setReadOnly", toggle.resolvedParams(for: h.session))
        XCTAssertFalse(h.session.readOnly)
    }

    // MARK: Read-only mode

    func testReadOnlyToggleIsSessionStateAndClearsTheSelection() async throws {
        let h = harness(pdf: nil)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1)
        XCTAssertTrue(h.app.ui.menuItems(.documentTitle, context).isEmpty)

        let on = try await h.run("view.setReadOnly", ["on": true])
        XCTAssertEqual(on["on"]?.boolValue, true)
        XCTAssertTrue(h.session.readOnly)
        XCTAssertTrue(h.session.selection.isEmpty)
        // DESIGN.md §14.2: tapping the title offers Edit while read-only.
        let edit = try XCTUnwrap(h.app.ui.menuItems(.documentTitle, context).first)
        XCTAssertEqual(edit.command, "view.setReadOnly")
        XCTAssertEqual(edit.params(context), ["on": false])

        // No ink while read-only, whatever tool commits it; the gate runs before every other stroke processor.
        let gate = try XCTUnwrap(h.app.content.strokeProcessors.get(FeatReadOnlyFeature.inkGate)).processor
        var stroke = Stroke(style: .defaultPen, points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 20, y: 10)])
        XCTAssertFalse(gate.process(&stroke, page: Fixtures.page1, session: h.session))

        // The document chrome's own Edit entry for the same command wins: the title menu never lists Edit twice.
        h.app.ui.menus.register(MenuItemDescriptor(
            id: "chrome.title.edit", title: "Edit", location: .documentTitle, order: 0, owner: "docchrome",
            command: "view.setReadOnly", params: { _ in ["on": false] },
            isVisible: { ctx in ctx.session?.readOnly == true }))
        XCTAssertEqual(h.app.ui.menuItems(.documentTitle, context).map { $0.id }, ["chrome.title.edit"])

        let toggled = try await h.run("view.setReadOnly")
        XCTAssertEqual(toggled["on"]?.boolValue, false)
        XCTAssertFalse(h.session.readOnly)
        XCTAssertTrue(gate.process(&stroke, page: Fixtures.page1, session: h.session))
        XCTAssertEqual(h.undoDepths().values.reduce(0, +), 0, "a session command never touches undo")
    }

    // MARK: pdf.markSelection

    /// Acceptance: the markSelection examples pass the undo round trip on FIXTUREPG003 (the fixture PDF page).
    func testMarkSelectionExamplesUndoRoundTripOnTheFixturePDFPage() async throws {
        let h = harness()
        let before = try h.snapshotAll()
        for example in PDFMarkSelection.descriptor.examples {
            let result = try await h.run("pdf.markSelection", example)
            XCTAssertEqual(result["refs"]?.arrayValue?.count, 1, example.jsonString())
            XCTAssertEqual(try pdfItems(h).count, 1)
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
            XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
            XCTAssertEqual(try h.snapshotAll(), before, example.jsonString())
        }
    }

    /// The examples' points land on the fixture PDF's real text line (PDFKit), so the round trip also holds with the
    /// real PDF engine on main.
    func testExamplePointsSelectTheFixturePDFTextWithPDFKit() async throws {
        let h = harness(pdf: PDFKitSelectionService())
        let copied = try await h.run("pdf.copyText", PDFCopyText.example)
        XCTAssertTrue(copied["text"]?.stringValue?.contains("PDF") ?? false, copied.jsonString())
        XCTAssertEqual(copied["rects"]?.arrayValue?.count, 1)

        let before = try h.snapshotAll()
        let marked = try await h.run("pdf.markSelection", PDFMarkSelection.highlightExample)
        let ref = try XCTUnwrap(marked["refs"]?[0]?.stringValue)
        let stroke = try XCTUnwrap(try pdfItems(h).first?.stroke)
        XCTAssertTrue(ref.hasPrefix("item:FIXTUREDOC01/FIXTUREPG003/"))
        XCTAssertEqual(stroke.style.tool, .highlighter)
        XCTAssertTrue(stroke.bounds.intersects(Rect(x: 72, y: 72, width: 130, height: 22)), "\(stroke.bounds)")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testMarkSelectionMakesOneStrokePerLineWithCallerIDsOnTheActiveLayer() async throws {
        let h = harness()
        h.session.activeLayer = 2
        let params: JSONValue = ["page": pdfPage, "from": [80, 100], "to": [300, 100], "style": "strikeout",
                                 "ids": ["MYSTRIKE0001"]]
        let result = try await h.run("pdf.markSelection", params)
        XCTAssertEqual(result["refs"]?.arrayValue?.compactMap { $0.stringValue }, ["item:FIXTUREDOC01/FIXTUREPG003/MYSTRIKE0001"])
        XCTAssertEqual(result["text"]?.stringValue, "Fixture PDF text")
        let item = try XCTUnwrap(try pdfItems(h).first)
        XCTAssertEqual(item.layer, 2)
        XCTAssertEqual(item.stroke?.style.tool, .pen)
        // The fake engine selects [80, 100, 220, 18]: the pen line runs through its middle.
        XCTAssertTrue(item.stroke?.points.allSatisfy { $0.y == 109 } ?? false)

        await assertThrows(.conflict) { try await h.run("pdf.markSelection", params) }
    }

    func testMarkSelectionRejectsBadInputAndNeedsThePDFEngine() async {
        let h = harness()
        let onRuledPage: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "from": [80, 100], "to": [300, 100],
                                      "style": "highlight"]
        await assertThrows(.invalidParams) { try await h.run("pdf.markSelection", onRuledPage) }
        let badStyle: JSONValue = ["page": pdfPage, "from": [80, 100], "to": [300, 100], "style": "underline"]
        await assertThrows(.invalidParams) { try await h.run("pdf.markSelection", badStyle) }
        let badID: JSONValue = ["page": pdfPage, "from": [80, 100], "to": [300, 100], "style": "highlight",
                                "ids": ["not an id"]]
        await assertThrows(.invalidParams) { try await h.run("pdf.markSelection", badID) }
        let noEngine = harness(pdf: nil)
        await assertThrows(.unavailable) { try await noEngine.run("pdf.markSelection", PDFMarkSelection.highlightExample) }
        // contracts-v2 G2: a document Nib will not write refuses marks from every caller.
        h.app.services.set(NSMutableSet(array: [Fixtures.docID.raw]), for: ServiceKeys.storeReadOnly)
        await assertThrows(.unsupported) { try await h.run("pdf.markSelection", PDFMarkSelection.highlightExample) }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertEqual(try pdfItems(h).count, 0)
    }

    /// §6.1 session defaults: the user may leave `page` out (the window's current page); other callers must pass it.
    func testTheUserMayOmitThePage() async throws {
        let h = harness()
        h.session.page = Fixtures.pdfPage
        let params: JSONValue = ["from": [80, 100], "to": [300, 100]]
        let copied = try await h.run("pdf.copyText", params)
        XCTAssertEqual(copied["text"]?.stringValue, "Fixture PDF text")
        let marked = try await h.run("pdf.markSelection", ["from": [80, 100], "to": [300, 100], "style": "highlight"])
        XCTAssertEqual(marked["refs"]?.arrayValue?.count, 1)
        await assertThrows(.invalidParams) { try await h.run("pdf.copyText", params, as: .plugin("dev.test.plugin")) }
    }

    func testHighlightAndStrikeoutGeometry() {
        let rects = [Rect(x: 72, y: 100, width: 200, height: 20), Rect(x: 72, y: 124, width: 120, height: 20), .zero]
        let lines = rects.map { PDFTextLine(rect: $0) }
        let highlights = PDFMarkGeometry.strokes(over: lines, style: .highlight, t0: 1)
        XCTAssertEqual(highlights.count, 2, "empty rects are skipped")
        XCTAssertEqual(highlights[0].style.tool, .highlighter)
        XCTAssertEqual(highlights[0].style.width, 20, "a highlight is as tall as its line")
        XCTAssertEqual(highlights[0].style.color, PDFMarkGeometry.highlightColour)
        XCTAssertEqual(highlights[0].points.first?.x, 72)
        XCTAssertEqual(highlights[0].points.last?.x, 272)
        XCTAssertTrue(highlights[1].points.allSatisfy { $0.y == 134 && $0.width == 20 }, "straight, sizes filled")

        let strikes = PDFMarkGeometry.strokes(over: lines, style: .strikeout, t0: 1)
        XCTAssertEqual(strikes[0].style.tool, .pen)
        XCTAssertEqual(strikes[0].style.pen, .ball)
        XCTAssertEqual(strikes[0].style.width, 1.6, accuracy: 1e-9)
        XCTAssertTrue(strikes[0].points.allSatisfy { $0.y == 110 })

        // A line on a quarter-turned background runs down the page: its mark does too, as wide as the line is tall.
        let turned = PDFMarkGeometry.strokes(over: [PDFTextLine(start: Point(751, 72), end: Point(751, 472), thickness: 18)],
                                             style: .highlight, t0: 1)
        XCTAssertEqual(turned[0].style.width, 18)
        XCTAssertTrue(turned[0].points.allSatisfy { $0.x == 751 })
        XCTAssertEqual(turned[0].points.first?.y, 72)
        XCTAssertEqual(turned[0].points.last?.y, 472)
    }

    // MARK: Geometry helpers

    func testLongPressPicksTheNearestLineAndExtendsLineEndByLineEnd() {
        let lines = [Rect(x: 72, y: 96, width: 200, height: 20), Rect(x: 72, y: 72, width: 300, height: 20)]
        let second = PDFTextPick.line(at: Point(100, 99), lines: lines)
        XCTAssertEqual(second?.from, Point(72.5, 106))
        XCTAssertEqual(second?.to, Point(271.5, 106))
        XCTAssertNil(PDFTextPick.line(at: Point(100, 400), lines: lines))

        // Forward: to the end of the anchor's line, then the end of the next line in reading order; backward mirrors.
        XCTAssertEqual(PDFTextPick.extended(Point(100, 82), forward: true, lines: lines), Point(371.5, 82))
        XCTAssertEqual(PDFTextPick.extended(Point(371.5, 82), forward: true, lines: lines), Point(271.5, 106))
        XCTAssertNil(PDFTextPick.extended(Point(271.5, 106), forward: true, lines: lines))
        XCTAssertEqual(PDFTextPick.extended(Point(200, 106), forward: false, lines: lines), Point(72.5, 106))
        XCTAssertEqual(PDFTextPick.extended(Point(72.5, 106), forward: false, lines: lines), Point(72.5, 82))
        XCTAssertNil(PDFTextPick.extended(Point(72.5, 82), forward: false, lines: lines))
    }

    /// contracts-v2 G22: the PDF sits where `PageRecord.backgroundTransform` puts it (aspect-fitted and centred, turned
    /// by `rotation`), for points, rects and lines.
    func testThePDFSitsWhereTheBackgroundTransformPutsIt() {
        let fit = PDFPageMapping(PageRecord.backgroundTransform(sourceSize: PageSize(300, 400), rotation: 0,
                                                                pageSize: PageSize(600, 1000)))
        XCTAssertEqual(fit.pagePoint(Point(0, 0)), Point(0, 100))
        XCTAssertEqual(fit.pagePoint(Point(300, 400)), Point(600, 900))
        XCTAssertEqual(fit.pdfPoint(Point(600, 900)), Point(300, 400))
        XCTAssertEqual(fit.pageRect(Rect(x: 10, y: 10, width: 20, height: 5)), Rect(x: 20, y: 120, width: 40, height: 10))
        XCTAssertEqual(fit.pageLine(Rect(x: 10, y: 10, width: 20, height: 5)),
                       PDFTextLine(start: Point(20, 125), end: Point(60, 125), thickness: 10))
        let same = PDFPageMapping(PageRecord.backgroundTransform(sourceSize: .a4, rotation: 0, pageSize: .a4))
        XCTAssertEqual(same.pagePoint(Point(76, 83)), Point(76, 83))
        let board = PDFPageMapping(PageRecord.backgroundTransform(sourceSize: .a4, rotation: 0, pageSize: nil))
        XCTAssertEqual(board.pdfPoint(Point(5, 6)), Point(5, 6))

        // A portrait page turned a quarter clockwise onto a landscape page: the PDF's left edge runs along the top.
        let turned = PDFPageMapping(PageRecord.backgroundTransform(sourceSize: PageSize(595, 842), rotation: 90,
                                                                   pageSize: PageSize(842, 595)))
        assertEqual(turned.pagePoint(Point(72, 82)), Point(760, 72))
        assertEqual(turned.pdfPoint(Point(760, 72)), Point(72, 82))
        let line = turned.pageLine(Rect(x: 72, y: 72, width: 400, height: 20))
        assertEqual(line.start, Point(760, 72))
        assertEqual(line.end, Point(760, 472))
        XCTAssertEqual(line.thickness, 20, accuracy: 1e-9)
        let bounds = turned.pageRect(Rect(x: 72, y: 72, width: 400, height: 20))
        XCTAssertEqual(bounds.minX, 750, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxX, 770, accuracy: 1e-9)
        XCTAssertEqual(bounds.minY, 72, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxY, 472, accuracy: 1e-9)
    }

    /// A long-press on a page whose PDF background is turned picks the line in the PDF's own space, so the anchors,
    /// the selected lines and their marks follow the turned text.
    func testLongPressOnATurnedPDFPageSelectsTheTurnedLine() async throws {
        let h = harness()
        let url = try XCTUnwrap(h.assets.url(Fixtures.pdfAsset, doc: Fixtures.docID))
        // The fake engine's PDF page is A4 portrait; the Nib page is A4 landscape, so the PDF fits at scale 1.
        let top = PageSize.a4.height
        let source = PDFTextSource(doc: Fixtures.docID, page: Fixtures.pdfPage, url: url, index: 0,
                                   pageSize: PageSize(PageSize.a4.height, PageSize.a4.width), rotation: 90,
                                   service: try XCTUnwrap(h.app.services.pdf))
        // The fake engine's line is [72, 72, 400, 20] in the PDF: page x top-92…top-72, y 72…472.
        let picked = await source.pick(at: Point(top - 82, 100))
        let s = try XCTUnwrap(picked)
        assertEqual(s.from, Point(top - 82, 72.5))
        assertEqual(s.to, Point(top - 82, 471.5))
        XCTAssertEqual(s.text, "Fixture PDF text")
        // The fake selects [from.x, from.y, …, 18] in PDF points: a vertical line 18 wide at page x top-91.
        let line = try XCTUnwrap(s.lines.first)
        assertEqual(line.start, Point(top - 91, 72.5))
        assertEqual(line.end, Point(top - 91, 471.5))
        XCTAssertEqual(line.thickness, 18, accuracy: 1e-9)
        XCTAssertEqual(s.rects.first?.width ?? 0, 18, accuracy: 1e-9)
        let noText = await source.pick(at: Point(300, 100))
        XCTAssertNil(noText)
    }

    func testHandleTargetsAreAtLeast44PointsAndPickTheNearerHandle() {
        let first = PDFTextLine(rect: Rect(x: 100, y: 100, width: 200, height: 20))
        let last = PDFTextLine(rect: Rect(x: 100, y: 124, width: 120, height: 20))
        let start = PDFSelectionHandles.hitRect(.start, first: first, last: last)
        XCTAssertGreaterThanOrEqual(start.width, 44)
        XCTAssertGreaterThanOrEqual(start.height, 44)
        // The knobs are NibDesign's 12 pt handle beads, above the first line's start and below the last line's end.
        XCTAssertEqual(PDFSelectionHandles.knob(.start, first: first, last: last), CGRect(x: 94, y: 88, width: 12, height: 12))
        XCTAssertEqual(PDFSelectionHandles.knob(.end, first: first, last: last), CGRect(x: 214, y: 144, width: 12, height: 12))
        XCTAssertEqual(PDFSelectionHandles.bar(.start, first: first, last: last),
                       [CGPoint(x: 99, y: 100), CGPoint(x: 101, y: 100), CGPoint(x: 101, y: 120), CGPoint(x: 99, y: 120)])
        XCTAssertEqual(PDFSelectionHandles.end(at: CGPoint(x: 101, y: 95), first: first, last: last), .start)
        XCTAssertEqual(PDFSelectionHandles.end(at: CGPoint(x: 219, y: 150), first: first, last: last), .end)
        XCTAssertNil(PDFSelectionHandles.end(at: CGPoint(x: 200, y: 300), first: first, last: last))

        // Text turned a quarter clockwise reads downwards and its top faces right: the start knob sits right of it.
        let down = PDFTextLine(start: Point(100, 100), end: Point(100, 300), thickness: 20)
        let knob = PDFSelectionHandles.knobCentre(.start, first: down, last: down)
        XCTAssertEqual(knob.x, 116, accuracy: 1e-9)
        XCTAssertEqual(knob.y, 100, accuracy: 1e-9)
    }

    // MARK: Long-press, handles and the text menu

    func testLongPressSelectsTheLineAndTheMenuActionsRunCommands() async throws {
        let h = harness()
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.docID,
                                  pages: [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        let descriptor = try XCTUnwrap(h.app.ui.canvasAttachments.get(FeatReadOnlyFeature.pdfTextAttachment))
        let attachment = try XCTUnwrap(descriptor.make(host) as? PDFTextMenuAttachment)
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }

        // Bare paper and ruled pages decline, so the page menu still gets those long-presses.
        let miss = try await h.run("pdf.tapAt", ["page": pdfPage, "point": [100, 600], "gesture": "longPress"])
        XCTAssertEqual(miss["handled"]?.boolValue, false)
        let ruled = try await h.run("pdf.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [100, 82]])
        XCTAssertEqual(ruled["handled"]?.boolValue, false)
        let tap = try await h.run("pdf.tapAt", ["page": pdfPage, "point": [100, 82], "gesture": "tap"])
        XCTAssertEqual(tap["handled"]?.boolValue, false)

        // Read-only mode too: the fake engine's line is [72, 72, 400, 20], so the whole line is selected.
        h.session.readOnly = true
        let hit = try await h.run("pdf.tapAt", PDFTapAt.example)
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        XCTAssertEqual(hit["text"]?.stringValue, "Fixture PDF text")
        let selection = try XCTUnwrap(attachment.selection)
        XCTAssertEqual(selection.from, Point(72.5, 82))
        XCTAssertEqual(selection.to, Point(471.5, 82))
        XCTAssertEqual(PDFTextAction.menu(writable: true, assistive: false).map { $0.title },
                       ["Highlight", "Strikethrough", "Define", "Speak", "Copy"])
        XCTAssertEqual(attachment.actions(for: selection).first, .highlight)

        // The end handle claims its touch; dragging it back to x 150 shrinks the selection through the PDF engine.
        let endKnob = host.viewPoint(Point(471.5, 100), page: Fixtures.pdfPage)
        XCTAssertTrue(attachment.hitTest(endKnob, host: host))
        XCTAssertFalse(attachment.hitTest(host.viewPoint(Point(300, 600), page: Fixtures.pdfPage), host: host))
        attachment.touchesBegan(CanvasSample(page: Fixtures.pdfPage, location: Point(471.5, 82), isPencil: false), host: host)
        attachment.touchesEnded(CanvasSample(page: Fixtures.pdfPage, location: Point(150, 82), isPencil: false), host: host)
        await attachment.query?.value
        let shrunk = try XCTUnwrap(attachment.selection)
        XCTAssertEqual(shrunk.to, Point(150, 82))
        XCTAssertEqual(shrunk.rects.first?.maxX ?? 0, 150, accuracy: 1e-9)

        // Highlight from the menu runs pdf.markSelection on exactly that selection and ends it.
        await attachment.choose(.highlight, for: shrunk)
        XCTAssertNil(attachment.selection)
        let stroke = try XCTUnwrap(try pdfItems(h).first?.stroke)
        XCTAssertEqual(stroke.style.tool, .highlighter)
        XCTAssertEqual(stroke.points.last?.x, 150)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    /// contracts-v2 G22: with a PDF engine that finds words, a long-press selects the word, so Define looks up one
    /// word; the extend actions (VoiceOver, Switch Control) then grow it to the line's end and back to its start.
    func testLongPressSelectsTheWordAndTheExtendActionsGrowIt() async throws {
        let fake = FakePDFService()
        fake.words[Fixtures.pdfAsset.name] = [(text: "Fixture", rect: Rect(x: 72, y: 72, width: 60, height: 20))]
        let h = harness(pdf: fake)
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.docID,
                                  pages: [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        let attachment = PDFTextMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }

        let hit = try await h.run("pdf.tapAt", PDFTapAt.example)
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        XCTAssertEqual(hit["text"]?.stringValue, "Fixture")
        let word = try XCTUnwrap(attachment.selection)
        XCTAssertEqual(word.from, Point(72.5, 82))
        XCTAssertEqual(word.to, Point(131.5, 82))
        XCTAssertEqual(word.rects, [Rect(x: 72, y: 72, width: 60, height: 20)])

        XCTAssertEqual(PDFTextAction.menu(writable: true, assistive: true).suffix(2).map { $0.title },
                       ["Extend Selection Backward", "Extend Selection Forward"])
        await attachment.choose(.extendForward, for: word)
        await attachment.query?.value
        let line = try XCTUnwrap(attachment.selection, "extending keeps the selection")
        XCTAssertEqual(line.from, Point(72.5, 82))
        XCTAssertEqual(line.to, Point(471.5, 82))
        XCTAssertFalse(attachment.presentWhenSettled, "the menu comes back once the engine answers")
        // Nothing further in either direction: the selection stays as it is.
        await attachment.choose(.extendForward, for: line)
        await attachment.choose(.extendBackward, for: line)
        XCTAssertEqual(attachment.selection, line)
    }

    /// Typed text, images and sticky notes over the PDF keep their long-press; ink over the text does not block it.
    func testLongPressDeclinesForItemsOtherThanInk() async throws {
        let h = harness()
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.docID,
                                  pages: [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        let attachment = PDFTextMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }

        let onText = PDFTapAt.example.merging(
            ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.textID).description)])
        let declined = try await h.run("pdf.tapAt", onText)
        XCTAssertEqual(declined["handled"]?.boolValue, false)
        XCTAssertNil(attachment.selection)

        let onInk = PDFTapAt.example.merging(
            ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.strokeID).description)])
        let handled = try await h.run("pdf.tapAt", onInk)
        XCTAssertEqual(handled["handled"]?.boolValue, true)
        XCTAssertNotNil(attachment.selection)
    }

    /// A handle drag cancelled while a query runs and another position waits: the queued position is dropped, the
    /// running query settles the selection and the menu is asked for again (no selection stuck without a menu).
    func testCancelledHandleDragSettlesAndShowsTheMenu() async throws {
        let h = harness()
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.docID,
                                  pages: [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        let attachment = PDFTextMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        try await h.run("pdf.tapAt", PDFTapAt.example)

        let page = Fixtures.pdfPage
        attachment.touchesBegan(CanvasSample(page: page, location: Point(471.5, 82), isPencil: false), host: host)
        attachment.touchesMoved([CanvasSample(page: page, location: Point(300, 82), isPencil: false)], host: host)
        attachment.touchesMoved([CanvasSample(page: page, location: Point(200, 82), isPencil: false)], host: host)
        attachment.touchesCancelled(host: host)
        await attachment.query?.value
        XCTAssertNil(attachment.query, "the queued position did not run")
        let settled = try XCTUnwrap(attachment.selection)
        XCTAssertEqual(settled.to, Point(300, 82))
        XCTAssertFalse(attachment.presentWhenSettled, "the menu was asked for")
    }

    /// contracts-v2 G2: in a document Nib will not write, the menu offers no marks (Define, Speak and Copy stay), and
    /// a tap on a selection handle stays with the selection instead of reaching the tap handlers.
    func testReadOnlyDocumentsOfferNoMarksAndHandleTapsStayWithTheSelection() async throws {
        let h = harness()
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.docID,
                                  pages: [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        let attachment = PDFTextMenuAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        try await h.run("pdf.tapAt", PDFTapAt.example)
        let selection = try XCTUnwrap(attachment.selection)

        h.app.services.set(NSMutableSet(array: [Fixtures.docID.raw]), for: ServiceKeys.storeReadOnly)
        XCTAssertEqual(attachment.actions(for: selection), [.define, .speak, .copy])

        let onEndKnob = CanvasSample(page: Fixtures.pdfPage, location: Point(471.5, 100), isPencil: false)
        XCTAssertTrue(attachment.gesture(.tap, at: onEndKnob, host: host))
        let elsewhere = CanvasSample(page: Fixtures.pdfPage, location: Point(300, 600), isPencil: false)
        XCTAssertFalse(attachment.gesture(.tap, at: elsewhere, host: host))
    }

    private func assertEqual(_ a: Point, _ b: Point, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "x of \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, "y of \(a) vs \(b)", file: file, line: line)
    }
}

/// Just enough PDFKit to prove the command examples land on the fixture PDF's text (a top-left page space, as
/// `PDFService` specifies; the fixture page has no crop offset or rotation).
private final class PDFKitSelectionService: PDFService {
    private func page(_ url: URL, _ index: Int) -> PDFPage? { PDFDocument(url: url)?.page(at: index) }

    func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }
    func pageSize(_ url: URL, page: Int) -> PageSize? {
        self.page(url, page).map { p -> PageSize in
            let b = p.bounds(for: .mediaBox)
            return PageSize(Double(b.width), Double(b.height))
        }
    }
    func text(_ url: URL, page: Int) -> String? { self.page(url, page)?.string }
    func textBlocks(_ url: URL, page: Int) -> [TextRecognition] { [] }
    func links(_ url: URL, page: Int) -> [PDFLinkInfo] { [] }
    func outline(_ url: URL) -> [PDFOutlineNode] { [] }

    func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect]) {
        guard let p = self.page(url, page) else { return ("", []) }
        let height = Double(p.bounds(for: .mediaBox).height)
        guard let s = p.selection(from: CGPoint(x: from.x, y: height - from.y), to: CGPoint(x: to.x, y: height - to.y)) else {
            return ("", [])
        }
        let rects = s.selectionsByLine().map { line -> Rect in
            let b = line.bounds(for: p)
            return Rect(x: Double(b.minX), y: height - Double(b.maxY), width: Double(b.width), height: Double(b.height))
        }
        return (s.string ?? "", rects)
    }
}
