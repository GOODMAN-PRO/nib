import XCTest
import UIKit
import PDFKit
import NibContracts
@testable import FeatImport

@MainActor
private final class BatchTestRenderer: UIPrintPageRenderer {
    var drawn: [Int] = []
    var onDraw: ((Int) -> Void)?
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 200, height: 300) }
    override var printableRect: CGRect { paperRect }
    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        drawn.append(pageIndex)
        onDraw?(pageIndex)
        ("Page \(pageIndex + 1)" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
    }
}

@MainActor
final class OfficePDFBatchTests: XCTestCase {
    func testRenderingReleasesMainActorBetweenBatchesAndPreservesEveryPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("converted.pdf")
        let renderer = BatchTestRenderer()
        var heartbeat = false
        renderer.onDraw = { index in
            if index == 0 { Task { @MainActor in heartbeat = true } }
            if index >= 4 { XCTAssertTrue(heartbeat, "input must advance before drawing the next batch") }
        }
        try await OfficePDFBatches.write(renderer, count: 11, to: output)
        XCTAssertEqual(renderer.drawn, Array(0..<11))
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 11)
        for index in 1...11 { XCTAssertEqual(pdf.page(at: index)?.getBoxRect(.mediaBox), renderer.paperRect) }
        let text = try XCTUnwrap(PDFDocument(url: output))
        for index in 0..<11 { XCTAssertTrue(text.page(at: index)?.string?.contains("Page \(index + 1)") == true) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["converted.pdf"])
    }

    func testCancellationBetweenBatchesDoesNotPublishPartialPDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("converted.pdf")
        let renderer = BatchTestRenderer()
        do {
            try await OfficePDFBatches.write(renderer, count: 500, to: output) { throw CancellationError() }
            XCTFail("Cancellation must stop conversion")
        } catch is CancellationError {}
        XCTAssertEqual(renderer.drawn, [0, 1, 2, 3])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
