import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
@testable import NibPDF

/// Test PDFs generated with UIGraphicsPDFRenderer (text drawn at a known top-left point, optional web link), plus
/// PDFKit edits and a raw Core Graphics reader that bypasses PDFKit.
enum TestPDF {
    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    /// UIKit (top-left origin) point where each page's line of text is drawn.
    static let textOrigin = CGPoint(x: 72, y: 100)
    static let linkURL = URL(string: "https://example.com/nib")!

    static func make(pages: Int = 1, link: Bool = false, text: (Int) -> String = { "Page \($0 + 1) text" }) -> Data {
        UIGraphicsPDFRenderer(bounds: a4).pdfData { context in
            for i in 0..<pages {
                context.beginPage()
                (text(i) as NSString).draw(at: textOrigin, withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
                if link && i == 0 {
                    UIGraphicsSetPDFContextURLForRect(linkURL, CGRect(x: 72, y: 100, width: 220, height: 24))
                }
            }
        }
    }

    /// Writes `data` as `<name>.pdf` in a fresh temporary folder (the file name becomes the notebook title).
    static func file(_ data: Data, name: String = "Test") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nibpdf-" + UUID().uuidString,
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".pdf")
        try data.write(to: url)
        return url
    }

    static func edited(_ data: Data, _ edit: (PDFDocument) throws -> Void) throws -> Data {
        let document = try XCTUnwrap(PDFDocument(data: data))
        try edit(document)
        return try XCTUnwrap(document.dataRepresentation())
    }

    static func encrypted(_ data: Data, password: String) throws -> Data {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nibpdf-locked-\(UUID().uuidString).pdf")
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: password,
                                                            .ownerPasswordOption: password + "-owner"]))
        return try Data(contentsOf: url)
    }

    /// Outline: "Chapter 2" → page index 1, with child "Section 2.1" → page index 2.
    static func withOutline(_ data: Data) throws -> Data {
        try edited(data) { document in
            let chapter = PDFOutline()
            chapter.label = "Chapter 2"
            chapter.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: .zero)
            let section = PDFOutline()
            section.label = "Section 2.1"
            section.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 2)), at: .zero)
            chapter.insertChild(section, at: 0)
            let root = PDFOutline()
            root.insertChild(chapter, at: 0)
            document.outlineRoot = root
        }
    }

    /// `/Rect` of every annotation on page `number` (1-based), read with Core Graphics in PDF user space (y up).
    static func rawAnnotationRects(_ data: Data, page number: Int) -> [CGRect] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: number)?.dictionary else { return [] }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let list = annotations else { return [] }
        var rects: [CGRect] = []
        for i in 0..<CGPDFArrayGetCount(list) {
            var annotation: CGPDFDictionaryRef?
            var numbers: CGPDFArrayRef?
            guard CGPDFArrayGetDictionary(list, i, &annotation), let entry = annotation,
                  CGPDFDictionaryGetArray(entry, "Rect", &numbers), let rect = numbers else { continue }
            var v = [CGPDFReal](repeating: 0, count: 4)
            for j in 0..<4 { _ = CGPDFArrayGetNumber(rect, j, &v[j]) }
            rects.append(CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1])))
        }
        return rects
    }
}

@MainActor
final class PDFServiceTests: XCTestCase {
    // MARK: PDFKit service on generated PDFs

    func testTextBlocksAndLinksComeBackInTopLeftPagePoints() throws {
        let data = TestPDF.make(link: true, text: { _ in "Hello PDF" })
        let url = try TestPDF.file(data)
        let service = PDFKitService()

        XCTAssertEqual(service.pageCount(url), 1)
        let size = try XCTUnwrap(service.pageSize(url, page: 0))
        XCTAssertEqual(size.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(size.height, 841.89, accuracy: 0.01)
        XCTAssertEqual(service.text(url, page: 0)?.contains("Hello PDF"), true)
        XCTAssertNil(service.text(url, page: 1), "no such page")

        // UIKit drew the line at (72, 100) from the top-left: it comes back there, not mirrored near the bottom.
        let block = try XCTUnwrap(service.textBlocks(url, page: 0).first { $0.text.contains("Hello PDF") })
        XCTAssertEqual(block.source, "pdf")
        XCTAssertEqual(block.bbox.x, 72, accuracy: 4)
        XCTAssertEqual(block.bbox.y, 100, accuracy: 10)

        // The link rect is the annotation's raw /Rect (PDF user space, y up) flipped to the top-left origin.
        let raw = try XCTUnwrap(TestPDF.rawAnnotationRects(data, page: 1).first)
        let links = service.links(url, page: 0)
        XCTAssertEqual(links.count, 1)
        let link = try XCTUnwrap(links.first)
        XCTAssertEqual(link.url, TestPDF.linkURL.absoluteString)
        XCTAssertNil(link.pageIndex)
        XCTAssertEqual(link.rect.x, Double(raw.minX), accuracy: 0.01)
        XCTAssertEqual(link.rect.y, size.height - Double(raw.maxY), accuracy: 0.01)
        XCTAssertEqual(link.rect.width, Double(raw.width), accuracy: 0.01)
        XCTAssertEqual(link.rect.height, Double(raw.height), accuracy: 0.01)
    }

    func testDragSelectionReturnsTextAndLineRects() throws {
        let url = try TestPDF.file(TestPDF.make(text: { _ in "Select these words" }))
        let service = PDFKitService()
        let selection = service.selection(url, page: 0, from: Point(70, 111), to: Point(420, 111))
        XCTAssertTrue(selection.text.contains("Select"), selection.text)
        let line = try XCTUnwrap(selection.rects.first)
        XCTAssertEqual(line.y, 100, accuracy: 10)
        XCTAssertEqual(service.selection(url, page: 5, from: .zero, to: Point(10, 10)).text, "")
    }

    func testWordAtAPointReturnsThatWordAndItsBox() throws {
        let url = try TestPDF.file(TestPDF.make(text: { _ in "Hello World" }))
        let service = PDFKitService()
        let font = UIFont.systemFont(ofSize: 18)
        let lead = Double(("Hello " as NSString).size(withAttributes: [.font: font]).width)
        let wordWidth = Double(("World" as NSString).size(withAttributes: [.font: font]).width)
        let lineMid = Double(TestPDF.textOrigin.y) + Double(font.lineHeight) / 2
        let inWorld = Point(Double(TestPDF.textOrigin.x) + lead + wordWidth / 2, lineMid)

        let word = try XCTUnwrap(service.word(url, page: 0, at: inWorld))
        XCTAssertEqual(word.text, "World")
        XCTAssertTrue(word.rect.contains(inWorld), "\(word.rect) should contain \(inWorld)")
        XCTAssertEqual(word.rect.minX, Double(TestPDF.textOrigin.x) + lead, accuracy: 4)
        XCTAssertEqual(word.rect.width, wordWidth, accuracy: 6)
        XCTAssertEqual(word.rect.midY, lineMid, accuracy: 8)

        let hello = try XCTUnwrap(service.word(url, page: 0, at: Point(Double(TestPDF.textOrigin.x) + 10, lineMid)))
        XCTAssertEqual(hello.text, "Hello")

        XCTAssertNil(service.word(url, page: 0, at: Point(300, 600)), "blank space has no word")
        XCTAssertNil(service.word(url, page: 0, at: Point(inWorld.x, lineMid + 80)), "a line below the text")
        XCTAssertNil(service.word(url, page: 0, at: Point(-20, lineMid)), "off the page")
        XCTAssertNil(service.word(url, page: 3, at: inWorld), "no such page")
    }

    func testWordOnARotatedPageIsInDisplayedPagePoints() throws {
        let rotated = try TestPDF.edited(TestPDF.make(text: { _ in "Rotated line of text" })) { document in
            try XCTUnwrap(document.page(at: 0)).rotation = 90
        }
        let url = try TestPDF.file(rotated)
        let service = PDFKitService()
        let block = try XCTUnwrap(service.textBlocks(url, page: 0).first { $0.text.contains("Rotated") })
        // The line runs down the right-hand edge: its first word sits at the top of the block.
        let point = Point(block.bbox.midX, block.bbox.minY + 12)
        let word = try XCTUnwrap(service.word(url, page: 0, at: point))
        XCTAssertEqual(word.text, "Rotated")
        XCTAssertTrue(word.rect.contains(point), "\(word.rect) should contain \(point)")
        XCTAssertGreaterThan(word.rect.height, word.rect.width, "a quarter turn stands the word upright")
    }

    func testRotatedPagesSwapTheirSizeAndTurnCoordinatesClockwise() throws {
        let rotated = try TestPDF.edited(TestPDF.make(text: { _ in "Rotated line of text" })) { document in
            try XCTUnwrap(document.page(at: 0)).rotation = 90
        }
        let url = try TestPDF.file(rotated)
        let service = PDFKitService()
        let size = try XCTUnwrap(service.pageSize(url, page: 0))
        XCTAssertEqual(size.width, 841.89, accuracy: 0.01)
        XCTAssertEqual(size.height, 595.28, accuracy: 0.01)
        // Turned a quarter clockwise, the line along the top-left edge runs down the right-hand edge.
        let block = try XCTUnwrap(service.textBlocks(url, page: 0).first { $0.text.contains("Rotated") })
        XCTAssertGreaterThan(block.bbox.minX, size.width - 150)
        XCTAssertEqual(block.bbox.minY, 72, accuracy: 10)
        XCTAssertGreaterThan(block.bbox.height, block.bbox.width)
        // The importer measures the same displayed size with Core Graphics.
        let document = try XCTUnwrap(PDFImportPreparation.cgDocument(rotated))
        let measured = try XCTUnwrap(PDFImportPreparation.pageSizes(document).first)
        XCTAssertEqual(measured.width, 841.89, accuracy: 0.01)
        XCTAssertEqual(measured.height, 595.28, accuracy: 0.01)
    }

    func testOutlineIsReadFromThePDF() throws {
        let url = try TestPDF.file(try TestPDF.withOutline(TestPDF.make(pages: 3)))
        XCTAssertEqual(PDFKitService().outline(url), [
            PDFOutlineNode(title: "Chapter 2", pageIndex: 1, children: [PDFOutlineNode(title: "Section 2.1", pageIndex: 2)])
        ])
    }

    func testUnreadableFilesReadAsEmpty() throws {
        let url = try TestPDF.file(Data("not a pdf".utf8))
        let service = PDFKitService()
        XCTAssertEqual(service.pageCount(url), 0)
        XCTAssertNil(service.pageSize(url, page: 0))
        XCTAssertEqual(service.links(url, page: 0), [])
        XCTAssertEqual(service.pageCount(URL(fileURLWithPath: "/nonexistent/missing.pdf")), 0)
    }

    // MARK: Pure geometry, ordering and paging

    func testGeometryRoundTripsEveryRotationWithAnOffsetCropBox() {
        let box = CGRect(x: 20, y: 30, width: 400, height: 600)
        for rotation in [0, 90, 180, 270, -90, 450] {
            let geometry = PDFPageGeometry(box: box, rotation: rotation)
            for p in [Point(0, 0), Point(10, 20), Point(123.5, 77.25), Point(400, 600)] {
                let back = geometry.pagePoint(geometry.pdfPoint(p))
                XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
                XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: -90).rotation, 270)
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: 90).size, PageSize(600, 400))
        // The displayed top-left corner is the crop box's top-left, bottom-left, bottom-right, top-right.
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: 0).pagePoint(CGPoint(x: 20, y: 630)), Point(0, 0))
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: 90).pagePoint(CGPoint(x: 20, y: 30)), Point(0, 0))
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: 180).pagePoint(CGPoint(x: 420, y: 30)), Point(0, 0))
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: 270).pagePoint(CGPoint(x: 420, y: 630)), Point(0, 0))
        // A rectangle keeps its extent, swapped by a quarter turn.
        XCTAssertEqual(PDFPageGeometry(box: box, rotation: 90).pageRect(CGRect(x: 20, y: 30, width: 100, height: 50)),
                       Rect(x: 0, y: 0, width: 50, height: 100))
    }

    func testPlacementFollowsTheBackgroundTransform() {
        let rect = Rect(x: 10, y: 20, width: 30, height: 40)
        let pdf = PageSize(600, 800)
        func placed(_ page: PageSize?, rotation: Int = 0) -> Rect {
            PDFPagePlacement.rect(rect, PageRecord.backgroundTransform(sourceSize: pdf, rotation: rotation, pageSize: page))
        }
        // An imported page (same size, unrotated) is the identity; so is a board, which draws the PDF unscaled.
        XCTAssertEqual(placed(PageSize(600, 800)), rect)
        XCTAssertEqual(placed(nil), rect)
        // A half-size page scales by 0.5; a wider page centres the PDF horizontally.
        XCTAssertEqual(placed(PageSize(300, 400)), Rect(x: 5, y: 10, width: 15, height: 20))
        XCTAssertEqual(placed(PageSize(800, 800)), Rect(x: 110, y: 20, width: 30, height: 40))
        // PageRecord.rotation turns the background clockwise (contracts-v2 G22): a quarter turn onto the swapped page
        // moves the rect's top-left corner to the top-right and swaps its extent.
        XCTAssertEqual(placed(PageSize(800, 600), rotation: 90), Rect(x: 800 - 60, y: 10, width: 40, height: 30))
        XCTAssertEqual(placed(PageSize(600, 800), rotation: 180), Rect(x: 600 - 40, y: 800 - 60, width: 30, height: 40))
        XCTAssertEqual(placed(PageSize(800, 600), rotation: 270), Rect(x: 20, y: 600 - 40, width: 40, height: 30))
        // Rounded to 0.01 pt.
        let third = PDFPagePlacement.rect(Rect(x: 1, y: 1, width: 1, height: 1), Affine(a: 1.0 / 3, b: 0, c: 0, d: 1.0 / 3, tx: 0, ty: 0))
        XCTAssertEqual(third, Rect(x: 0.33, y: 0.33, width: 0.33, height: 0.33))
    }

    func testTitlesComeFromTheDisplayNameElseTheFileName() {
        XCTAssertEqual(PDFImporter.title(of: URL(fileURLWithPath: "/tmp/Mechanics.pdf")), "Mechanics")
        // import.files passes the original name: a tmp: asset or a download keeps a generated or original local name.
        let local = URL(fileURLWithPath: "/tmp/nib-downloads/\(UUID().uuidString)/lecture3.pdf")
        XCTAssertEqual(PDFImporter.title(of: local, displayName: "Lecture 3"), "Lecture 3")
        XCTAssertEqual(PDFImporter.title(of: local, displayName: "  "), "lecture3")
        XCTAssertEqual(PDFImporter.title(of: local), "lecture3")
        // A file that happens to start with a UUID keeps it: nothing is stripped any more.
        let uuidName = UUID().uuidString + "-Notes"
        XCTAssertEqual(PDFImporter.title(of: URL(fileURLWithPath: "/tmp/\(uuidName).pdf")), uuidName)
    }

    func testOrderKeysAreSortedUniqueBoundedAndShort() {
        let keys = PDFImporter.orderKeys(between: "V", "k", count: 1_000)
        XCTAssertEqual(keys.count, 1_000)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, 1_000)
        XCTAssertTrue(keys.allSatisfy { $0 > "V" && $0 < "k" })
        XCTAssertLessThanOrEqual(keys.map { $0.count }.max() ?? 0, 8)
        XCTAssertEqual(PDFImporter.orderKeys(between: nil, nil, count: 0), [])
        let open = PDFImporter.orderKeys(between: nil, nil, count: 300)
        XCTAssertEqual(open, open.sorted())
    }

    func testNeighboursFollowPositionAndFallBackToTheEnd() {
        let pages = [PageRecord(id: "P1", order: "V"), PageRecord(id: "P2", order: "k")]
        XCTAssertTrue(PDFImporter.neighbours(pages, .start, anchor: nil) == (nil, "V"))
        XCTAssertTrue(PDFImporter.neighbours(pages, .end, anchor: nil) == ("k", nil))
        XCTAssertTrue(PDFImporter.neighbours(pages, .before, anchor: "P2") == ("V", "k"))
        XCTAssertTrue(PDFImporter.neighbours(pages, .after, anchor: "P1") == ("V", "k"))
        XCTAssertTrue(PDFImporter.neighbours(pages, .after, anchor: "MISSING") == ("k", nil))
    }

    func testLongResultsArePagedWithACursor() throws {
        let text = String(repeating: "Kinematics — SUVAT. ", count: 2_000)
        var pieces: [String] = []
        var start = 0
        while true {
            let slice = PDFResultPaging.text(text, from: start)
            XCTAssertLessThanOrEqual(slice.text.utf8.count, PDFResultPaging.budget)
            pieces.append(slice.text)
            guard let next = slice.next else { break }
            start = try PDFResultPaging.start(String(next))
        }
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertThrowsError(try PDFResultPaging.start("abc"))
        let numbers = PDFResultPaging.items(Array(0..<10_000), from: 0)
        XCTAssertEqual(numbers.items.first, 0)
        XCTAssertNotNil(numbers.next)
        XCTAssertEqual(PDFResultPaging.items(Array(0..<3), from: 0).items, [0, 1, 2])
    }
}
