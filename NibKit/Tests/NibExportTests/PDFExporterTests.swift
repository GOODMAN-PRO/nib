import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
@testable import NibExport

@MainActor
final class PDFExporterTests: XCTestCase {
    private func exportPDF(_ h: Harness, _ params: JSONValue) async throws -> PDFDocument {
        var p = params
        if case .object(var o) = p {
            o["format"] = "pdf"
            o["inline"] = true
            if o["docs"] == nil { o["docs"] = ["doc:FIXTUREDOC01"] }
            p = .object(o)
        }
        let out = try await h.run(CommandIDs.exportRun, p)
        let base64 = try XCTUnwrap(out["files"]?.arrayValue?.first?["base64"]?.stringValue)
        return try XCTUnwrap(PDFDocument(data: try XCTUnwrap(Data(base64Encoded: base64))))
    }

    /// Annotation types of a page, without the Popup companions PDFKit adds to text annotations.
    private func types(_ page: PDFPage?) -> [String] {
        (page?.annotations ?? []).map { ($0.type ?? "").replacingOccurrences(of: "/", with: "") }.filter { $0 != "Popup" }
    }

    /// The page's text ("" when it has none).
    private func text(_ page: PDFPage?) -> String { page?.string ?? "" }

    // MARK: Editable vs flattened (D-102)

    func testEditableKeepsInkTextBoxesCommentsAndTheOutlineAsPDFObjects() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let pdf = try await exportPDF(h, ["options": ["mode": "editable"]])
        XCTAssertEqual(pdf.pageCount, 3)
        let kinds = types(pdf.page(at: 0))
        XCTAssertTrue(kinds.contains("Ink"), "\(kinds)")
        XCTAssertTrue(kinds.contains("FreeText"), "\(kinds)")
        XCTAssertTrue(kinds.contains("Text"), "the comment thread is a text annotation: \(kinds)")
        let freeText = pdf.page(at: 0)?.annotations.first { ($0.type ?? "").contains("FreeText") }
        XCTAssertEqual(freeText?.contents, "Hello Nib")
        let note = pdf.page(at: 0)?.annotations.first { ($0.type ?? "") == "Text" || ($0.type ?? "") == "/Text" }
        XCTAssertTrue(note?.contents?.contains("Check this") ?? false)
        let outline = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(outline.child(at: 0)?.label, "Fixture section")
        let target = try XCTUnwrap(outline.child(at: 0)?.destination?.page)
        XCTAssertEqual(pdf.index(for: target), 0)
    }

    func testFlattenedDrawsEverythingIntoThePageAndKeepsOnlyCommentsAndLinks() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let pdf = try await exportPDF(h, [:])
        let kinds = types(pdf.page(at: 0))
        XCTAssertFalse(kinds.contains("Ink"))
        XCTAssertFalse(kinds.contains("FreeText"))
        XCTAssertEqual(kinds, ["Text"])
        XCTAssertNil(pdf.outlineRoot)
        let plain = try await exportPDF(h, ["options": ["comments": false]])
        XCTAssertEqual(types(plain.page(at: 0)), [])
    }

    func testEditableKeepsTheSourcePDFOutlineAndLinks() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let service = FakePDFService()
        service.outlines["fixture-page.pdf"] = [PDFOutlineNode(title: "Chapter 1", pageIndex: 0)]
        service.linkMap["fixture-page.pdf"] = [PDFLinkInfo(rect: Rect(x: 72, y: 72, width: 120, height: 20), url: "https://source.example")]
        h.app.services.pdf = service
        let pdf = try await exportPDF(h, ["options": ["mode": "editable"]])
        let root = try XCTUnwrap(pdf.outlineRoot)
        let labels = (0..<root.numberOfChildren).compactMap { root.child(at: $0)?.label }
        XCTAssertEqual(labels, ["Fixture section", "Chapter 1"])
        let chapter = try XCTUnwrap(root.child(at: 1)?.destination?.page)
        XCTAssertEqual(pdf.index(for: chapter), 2)
        let link = pdf.page(at: 2)?.annotations.first { $0.url?.absoluteString == "https://source.example" }
        XCTAssertNotNil(link)
        // Flattened exports keep only the links Nib created.
        let flat = try await exportPDF(h, [:])
        XCTAssertNil(flat.page(at: 2)?.annotations.first { $0.url != nil })
    }

    // MARK: Searchable text

    func testFlattenedAddsAnInvisibleLayerOfRecognisedHandwriting() async throws {
        let h = Harness(features: [NibExportFeature.self])
        h.app.services.recognizer = FakeRecognizer([TextRecognition(text: "velocity", bbox: Rect(x: 72, y: 110, width: 80, height: 20),
                                                                    itemIDs: [Fixtures.strokeID], source: "ink")])
        let searchable = try await exportPDF(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]])
        XCTAssertEqual(searchable.pageCount, 1)
        XCTAssertTrue(searchable.page(at: 0)?.string?.contains("velocity") ?? false, searchable.page(at: 0)?.string ?? "")
        let hits = searchable.findString("velocity", withOptions: .caseInsensitive)
        let bounds = try XCTUnwrap(hits.first?.bounds(for: try XCTUnwrap(searchable.page(at: 0))))
        XCTAssertEqual(bounds.minX, 72, accuracy: 4, "the text sits over the handwriting")
        let plain = try await exportPDF(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "options": ["searchableText": false]])
        XCTAssertFalse(text(plain.page(at: 0)).contains("velocity"))
        let hidden = try await exportPDF(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"],
                                             "options": try JSONValue.parse(#"{"visibleLayersOnly": true, "visibleLayers": {"FIXTUREDOC01": [1]}}"#)])
        XCTAssertFalse(text(hidden.page(at: 0)).contains("velocity"), "text of hidden ink is left out too")
    }

    // MARK: Links

    func testTextLinksBecomeLinkAnnotationsOverTheirWords() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let text = RichText(paragraphs: [Paragraph(runs: [
            TextRun("Read ", TextAttributes(size: 20)),
            TextRun("this", TextAttributes(size: 20, link: TextLink(url: "https://example.com/notes"))),
            TextRun(" or ", TextAttributes(size: 20)),
            TextRun("page three", TextAttributes(size: 20, link: TextLink(document: Fixtures.docID, page: Fixtures.pdfPage))),
        ])])
        try await h.insert([Item(id: "LINKTEXT0001", kind: .text,
                                 text: TextBoxItem(frame: Frame(x: 100, y: 600, w: 400, h: 40), text: text))])
        let pdf = try await exportPDF(h, [:])
        let links = (pdf.page(at: 0)?.annotations ?? []).filter { ($0.type ?? "").contains("Link") }
        XCTAssertEqual(links.count, 2)
        let web = try XCTUnwrap(links.first { $0.url != nil })
        XCTAssertEqual(web.url?.absoluteString, "https://example.com/notes")
        XCTAssertGreaterThan(web.bounds.minX, 100)
        XCTAssertLessThan(web.bounds.maxX, 500)
        // PDF space is y-up: the box at y 600…640 on an 842 pt page.
        XCTAssertEqual(web.bounds.maxY, PageSize.a4.height - 600, accuracy: 6)
        let internalLink = try XCTUnwrap(links.first { $0.url == nil })
        let destination = internalLink.destination ?? (internalLink.action as? PDFActionGoTo)?.destination
        XCTAssertEqual(destination?.page.map { pdf.index(for: $0) }, 2)
        let none = try await exportPDF(h, ["options": ["annotations": false, "comments": false]])
        XCTAssertEqual(types(none.page(at: 0)), [])
    }

    // MARK: Boards (D-032)

    func testWhiteboardExportsItsContentBoundsAsOnePageOrTiledPaper() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let items = try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID)
        let bounds = ExportPlan.contentBounds(items, registries: h.app.content)
        let single = try await exportPDF(h, ["docs": ["doc:FIXTUREDOC04"]])
        XCTAssertEqual(single.pageCount, 1)
        let box = try XCTUnwrap(single.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(box.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(box.height, bounds.height, accuracy: 0.5)

        try await h.insert([Item(id: "FARSHAPE0001", kind: .shape,
                                 shape: ShapeItem(shape: .rectangle, frame: Frame(x: 1400, y: 2000, w: 100, h: 100)))],
                           page: Fixtures.boardID, doc: Fixtures.whiteboardID)
        let wide = ExportPlan.contentBounds(try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID),
                                            registries: h.app.content)
        let expected = ExportPlan.boardSheets(wide, layout: .tiled, paper: .a4, page: 0)
        XCTAssertEqual(expected.count, 3 * 3)
        let tiled = try await exportPDF(h, ["docs": ["doc:FIXTUREDOC04"], "options": ["board": "tiled"]])
        XCTAssertEqual(tiled.pageCount, expected.count)
        let tile = try XCTUnwrap(tiled.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(tile.width, PageSize.a4.width, accuracy: 0.5)
        XCTAssertEqual(tile.height, PageSize.a4.height, accuracy: 0.5)
        // The tiles cover the bounds, centred.
        let union = expected.map { $0.region }.reduce(expected[0].region) { $0.union($1) }
        XCTAssertTrue(union.contains(wide))
        XCTAssertEqual(union.midX, wide.midX, accuracy: 0.01)
    }

    func testBoardsExportAsImagesOfTheirContent() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC04"], "format": "png", "inline": true])
        let file = try XCTUnwrap(out["files"]?.arrayValue?.first)
        XCTAssertEqual(file["name"]?.stringValue, "Fixture Whiteboard.png")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["base64"]?.stringValue)))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let bounds = ExportPlan.contentBounds(try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID),
                                              registries: h.app.content)
        XCTAssertEqual(image.width, Int((bounds.width * 2).rounded()))
    }

    // MARK: Options

    func testBackgroundOffLeavesThePDFBackgroundOut() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let pdf = try await exportPDF(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG003"], "options": ["background": false]])
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertFalse(text(pdf.page(at: 0)).contains("Fixture PDF text"))
        let range = try await exportPDF(h, ["options": ["pageRange": "2-3"]])
        XCTAssertEqual(range.pageCount, 2)
        XCTAssertTrue(range.page(at: 1)?.string?.contains("Fixture PDF text") ?? false)
    }

    func testStickyNotesPrintAsIconsOrExpandedOnACopy() throws {
        let note = Item(kind: .sticky, sticky: StickyItem(frame: Frame(x: 0, y: 0, w: 140, h: 140), text: RichText(plain: "Hi")))
        XCTAssertEqual(ExportPlan.applyingStickyOption(note, .icon).sticky?.collapsed, true)
        XCTAssertEqual(ExportPlan.applyingStickyOption(note, .asIs), note)
        var collapsed = note
        collapsed.sticky?.collapsed = true
        XCTAssertEqual(ExportPlan.applyingStickyOption(collapsed, .expanded).sticky?.collapsed, false)
        XCTAssertEqual(ExportPlan.applyingStickyOption(collapsed, .expanded).sticky?.frame, note.sticky?.frame)
        let shape = Item(kind: .shape, shape: ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 10, h: 10)))
        XCTAssertEqual(ExportPlan.applyingStickyOption(shape, .icon), shape)
    }

    func testIconStickyNotesLoseTheirTextInTheExportButNotInTheDocument() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let icons = try await exportPDF(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "options": ["stickyNotes": "icon"]])
        XCTAssertFalse(text(icons.page(at: 0)).contains("Remember"))
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).sticky?.collapsed, false)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    /// Pencil keeps its texture as a 300 dpi image in PDFs; highlighter and dashed ink stay vector; images draw all.
    func testEveryInkKindExportsToPDFAndImages() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let pts = [StrokePoint(x: 100, y: 700), StrokePoint(x: 300, y: 720)]
        var dashed = InkStyle.defaultPen
        dashed.pattern = .dashed
        try await h.insert([Item(kind: .stroke, stroke: Stroke(style: .defaultHighlighter, points: pts)),
                            Item(kind: .stroke, stroke: Stroke(style: dashed, points: pts)),
                            Item(kind: .stroke, stroke: Stroke(style: .defaultPencil, points: pts))], page: Fixtures.page2)
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "pages": ["page:FIXTUREDOC01/FIXTUREPG002"],
                                                         "format": "pdf", "inline": true])
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(out["files"]?[0]?["base64"]?.stringValue)))
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
        XCTAssertNotNil(data.range(of: Data("/Image".utf8)), "the pencil stroke is embedded as an image")
        let images = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "pages": ["page:FIXTUREDOC01/FIXTUREPG002"],
                                                            "format": "jpeg", "options": ["scale": 3, "quality": 0.5], "inline": true])
        let jpeg = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(images["files"]?[0]?["base64"]?.stringValue)))
        XCTAssertEqual(UIImage(data: jpeg)?.cgImage?.width, Int((PageSize.a4.width * 3).rounded()))
    }

    // MARK: Pure pieces

    func testEditableSplitKeepsInkUnderTapeInThePage() {
        let under = Item(id: "UNDERINK0001", kind: .stroke,
                         stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: 100, y: 600), StrokePoint(x: 200, y: 600)]))
        let tape = Item(id: "TAPESTRIP001", kind: .stroke,
                        stroke: Stroke(style: .defaultTape, points: [StrokePoint(x: 80, y: 600), StrokePoint(x: 260, y: 600)]))
        let above = Item(id: "ABOVEINK0001", kind: .stroke,
                         stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: 100, y: 602), StrokePoint(x: 200, y: 602)]))
        let text = Item(id: "TEXTBOX00001", kind: .text,
                        text: TextBoxItem(frame: Frame(x: 0, y: 0, w: 100, h: 30), text: RichText(plain: "Hi")))
        var rotated = text
        rotated.id = "ROTATEDTXT01"
        rotated.text?.frame.rotation = 0.3
        let ids = EditableSplit.annotated([under, tape, above, text, rotated]).map { $0.id }
        XCTAssertEqual(ids, ["ABOVEINK0001", "TEXTBOX00001"])
        var revealed = tape
        revealed.stroke?.tapeRevealed = true
        XCTAssertEqual(EditableSplit.annotated([under, revealed]).map { $0.id }, ["UNDERINK0001"])
    }

    func testHighlighterRunsSitBeneathInkAndItemsKeepTheirOrder() {
        func stroke(_ tool: InkTool, _ id: String) -> Item {
            var style = InkStyle(tool: tool, pen: tool == .pen ? .ball : nil)
            if tool == .highlighter { style.color = .highlighterYellow }
            return Item(id: NibID(id), kind: .stroke, stroke: Stroke(style: style, points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 9, y: 9)]))
        }
        let shape = Item(id: "SHAPE0000001", kind: .shape, shape: ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 5, h: 5)))
        let bands = ExportBands.make([stroke(.pen, "PEN000000001"), stroke(.highlighter, "HIGH00000001"), stroke(.pencil, "PENCIL000001"),
                                      shape, stroke(.highlighter, "HIGH00000002"), stroke(.tape, "TAPE00000001")])
        XCTAssertEqual(bands.map { $0.kind }, [.highlighter, .pen, .pencil, .item, .highlighter, .item])
        XCTAssertEqual(bands.last?.items.first?.id, "TAPE00000001")
    }

    func testCurvesStartAndEndAtTheirOuterControlPoints() {
        let pts = [Point(0, 0), Point(50, 80), Point(100, 0), Point(150, 80), Point(200, 0)]
        let geometry = ShapeGeometry.make(ShapeItem(shape: .curve, frame: Frame(x: 0, y: 0, w: 200, h: 80), points: pts))
        XCTAssertFalse(geometry.closed)
        XCTAssertEqual(geometry.ends?.start, CGPoint(x: 0, y: 0))
        XCTAssertEqual(geometry.ends?.end, CGPoint(x: 200, y: 0))
        let box = geometry.path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 200, accuracy: 0.01)
        XCTAssertLessThanOrEqual(box.maxY, 80)
        let diamond = ShapeGeometry.make(ShapeItem(shape: .diamond, frame: Frame(x: 10, y: 10, w: 100, h: 50)))
        XCTAssertTrue(diamond.closed)
        XCTAssertEqual(diamond.path.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 100, height: 50))
    }

    func testTiledBoardsCoverTheContent() {
        let bounds = Rect(x: -50, y: 10, width: 1300, height: 900)
        let sheets = ExportPlan.boardSheets(bounds, layout: .tiled, paper: .a4, page: 4)
        XCTAssertEqual(sheets.count, 3 * 2)
        XCTAssertTrue(sheets.allSatisfy { $0.page == 4 && $0.region.width == PageSize.a4.width })
        XCTAssertEqual(sheets.map { $0.row ?? -1 }, [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(ExportPlan.boardSheets(bounds, layout: .single, paper: .a4, page: 0).map { $0.region }, [bounds])
    }
}
