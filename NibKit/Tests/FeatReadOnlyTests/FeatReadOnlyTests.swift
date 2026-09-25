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
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testHighlightAndStrikeoutGeometry() {
        let rects = [Rect(x: 72, y: 100, width: 200, height: 20), Rect(x: 72, y: 124, width: 120, height: 20), .zero]
        let highlights = PDFMarkGeometry.strokes(over: rects, style: .highlight, t0: 1)
        XCTAssertEqual(highlights.count, 2, "empty rects are skipped")
        XCTAssertEqual(highlights[0].style.tool, .highlighter)
        XCTAssertEqual(highlights[0].style.width, 20, "a highlight is as tall as its line")
        XCTAssertEqual(highlights[0].style.color, PDFMarkGeometry.highlightColour)
        XCTAssertEqual(highlights[0].points.first?.x, 72)
        XCTAssertEqual(highlights[0].points.last?.x, 272)
        XCTAssertTrue(highlights[1].points.allSatisfy { $0.y == 134 && $0.width == 20 }, "straight, sizes filled")

        let strikes = PDFMarkGeometry.strokes(over: rects, style: .strikeout, t0: 1)
        XCTAssertEqual(strikes[0].style.tool, .pen)
        XCTAssertEqual(strikes[0].style.pen, .ball)
        XCTAssertEqual(strikes[0].style.width, 1.6, accuracy: 1e-9)
        XCTAssertTrue(strikes[0].points.allSatisfy { $0.y == 110 })
    }

    // MARK: Geometry helpers

    func testLongPressPicksTheNearestLineAndThePlacementCentresASmallerPDF() {
        let lines = [Rect(x: 72, y: 72, width: 300, height: 20), Rect(x: 72, y: 96, width: 200, height: 20)]
        let second = PDFTextPick.line(at: Point(100, 99), lines: lines)
        XCTAssertEqual(second?.from, Point(72.5, 106))
        XCTAssertEqual(second?.to, Point(271.5, 106))
        XCTAssertNil(PDFTextPick.line(at: Point(100, 400), lines: lines))

        let placement = PDFPlacement(pdf: PageSize(300, 400), page: PageSize(600, 1000))
        XCTAssertEqual(placement.toPage(Point(0, 0)), Point(0, 100))
        XCTAssertEqual(placement.toPage(Point(300, 400)), Point(600, 900))
        XCTAssertEqual(placement.toPDF(Point(600, 900)), Point(300, 400))
        XCTAssertEqual(placement.toPage(Rect(x: 10, y: 10, width: 20, height: 5)), Rect(x: 20, y: 120, width: 40, height: 10))
        XCTAssertEqual(PDFPlacement(pdf: .a4, page: .a4).toPage(Point(76, 83)), Point(76, 83))
        XCTAssertEqual(PDFPlacement(pdf: .a4, page: nil).toPDF(Point(5, 6)), Point(5, 6))
    }

    func testHandleTargetsAreAtLeast44PointsAndPickTheNearerHandle() {
        let first = CGRect(x: 100, y: 100, width: 200, height: 20)
        let last = CGRect(x: 100, y: 124, width: 120, height: 20)
        let start = PDFSelectionHandles.hitRect(.start, first: first, last: last)
        XCTAssertGreaterThanOrEqual(start.width, 44)
        XCTAssertGreaterThanOrEqual(start.height, 44)
        XCTAssertEqual(PDFSelectionHandles.end(at: CGPoint(x: 101, y: 95), first: first, last: last), .start)
        XCTAssertEqual(PDFSelectionHandles.end(at: CGPoint(x: 219, y: 150), first: first, last: last), .end)
        XCTAssertNil(PDFSelectionHandles.end(at: CGPoint(x: 200, y: 300), first: first, last: last))
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
        XCTAssertEqual(PDFTextAction.allCases.map { $0.title }, ["Highlight", "Strikethrough", "Define", "Speak", "Copy"])

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
