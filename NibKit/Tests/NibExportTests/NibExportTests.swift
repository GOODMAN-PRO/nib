import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
@testable import NibExport

@MainActor
final class NibExportTests: XCTestCase {
    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [NibExportFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersExportRunAndTheBuiltInExportersWithTheirKinds() {
        let h = Harness(features: [NibExportFeature.self])
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.exportRun)?.owner, NibExportFeature.id)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.exportRun)?.effect, .read)
        let ids = h.app.content.exporters.all.map { $0.id }
        for format in ExportFormat.builtIn { XCTAssertTrue(ids.contains(format), format) }
        for format in [ExportFormat.pdf, ExportFormat.png, ExportFormat.jpeg] {
            XCTAssertEqual(h.app.content.exporters.get(format)?.docKinds, [.notebook, .whiteboard], format)
        }
        XCTAssertEqual(h.app.content.exporters.get(ExportFormat.nibnote)?.docKinds, Set(DocumentKind.allCases))
        XCTAssertEqual(h.app.content.exporters.get(ExportFormat.zip)?.docKinds, Set(DocumentKind.allCases))
    }

    // MARK: Acceptance

    /// FIXTUREDOC01 exports as a 3-page PDF whose third page embeds the fixture PDF, and inline base64 round-trips
    /// (it is byte for byte the tmp: asset).
    func testFixtureNotebookExportsAThreePagePDFEmbeddingTheFixturePDFOnPageThree() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf", "inline": true])
        let files = try XCTUnwrap(out["files"]?.arrayValue)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file["name"]?.stringValue, "Fixture Notebook.pdf")
        XCTAssertNil(out["inlineOmitted"]?.boolValue)
        let asset = try XCTUnwrap(file["asset"]?.stringValue)
        XCTAssertTrue(asset.hasPrefix("tmp:"), asset)
        XCTAssertFalse(asset.contains("file://"))
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["base64"]?.stringValue)))
        let stored = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        XCTAssertEqual(try Data(contentsOf: stored), data)
        XCTAssertEqual(file["bytes"]?.intValue, data.count)

        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 3)
        let third = try XCTUnwrap(pdf.page(at: 2))
        XCTAssertTrue(third.string?.contains("Fixture PDF text") ?? false, third.string ?? "no text")
        XCTAssertFalse(pdf.page(at: 0)?.string?.contains("Fixture PDF text") ?? false)
        XCTAssertEqual(third.bounds(for: .mediaBox).width, PageSize.a4.width, accuracy: 0.5)
        XCTAssertEqual(third.bounds(for: .mediaBox).height, PageSize.a4.height, accuracy: 0.5)
        // Typed text is real text in the PDF (the text box and the sticky note on page 1).
        let first = pdf.page(at: 0)?.string ?? ""
        XCTAssertTrue(first.contains("Hello Nib"), first)
        XCTAssertTrue(first.contains("Remember"), first)
    }

    func testAnotherPrincipalGetsTheSameExportAndItsParamsValidate() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "pages": ["page:FIXTUREDOC01/FIXTUREPG001"],
                                                         "format": "png", "options": ["scale": 2], "inline": true],
                                  as: .bridge("mac"))
        let files = try XCTUnwrap(out["files"]?.arrayValue)
        XCTAssertEqual(files.map { $0["name"]?.stringValue }, ["Fixture Notebook.png"])
        do {
            _ = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf", "options": ["scale": "big"]],
                                as: .bridge("mac"))
            XCTFail("a wrongly typed option must be refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    // MARK: Images

    func testPNGExportOfOnePageIsTheRequestedScale() async throws {
        let h = Harness(features: [NibExportFeature.self])
        for scale in [2.0, 3.0] {
            let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "pages": ["page:FIXTUREDOC01/FIXTUREPG003"],
                                                             "format": "png", "options": ["scale": .number(scale)], "inline": true])
            let file = try XCTUnwrap(out["files"]?.arrayValue?.first)
            XCTAssertEqual(file["type"]?.stringValue, "public.png")
            let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["base64"]?.stringValue)))
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(image.width, Int((PageSize.a4.width * scale).rounded()))
            XCTAssertEqual(image.height, Int((PageSize.a4.height * scale).rounded()))
        }
    }

    func testJPEGExportWritesOneImagePerPageNamedByPageNumber() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "jpeg"])
        let names = try XCTUnwrap(out["files"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["Fixture Notebook - Page 1.jpg", "Fixture Notebook - Page 2.jpg", "Fixture Notebook - Page 3.jpg"])
    }

    /// Items on layers the Layers hook reports hidden are left out of image exports.
    func testVisibleLayersOptionLeavesHiddenLayersOut() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let block = Item(id: "LAYERBLOCK01", kind: .shape, layer: 3,
                         shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 100, w: 200, h: 200),
                                          style: ShapeItemStyle(strokeColor: nil, fillColor: .black)))
        try await h.insert([block], page: Fixtures.page2)
        func centre(_ options: JSONValue) async throws -> RGBA? {
            let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "pages": ["page:FIXTUREDOC01/FIXTUREPG002"],
                                                             "format": "png", "options": options, "inline": true])
            let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(out["files"]?[0]?["base64"]?.stringValue)))
            let image = try XCTUnwrap(UIImage(data: data, scale: 2))
            return NibSnapshot.pixel(image, at: CGPoint(x: 200, y: 200))
        }
        let all = try await centre([:])
        XCTAssertLessThan(Int(all?.r ?? 255), 60, "the block is drawn when every layer is exported")
        let visible = try await centre(try JSONValue.parse(#"{"visibleLayersOnly": true, "visibleLayers": {"FIXTUREDOC01": [0, 1]}}"#))
        XCTAssertGreaterThan(Int(visible?.r ?? 0), 200, "layer 3 is hidden")
        let other = try await centre(try JSONValue.parse(#"{"visibleLayersOnly": true, "visibleLayers": {"FIXTUREDOC04": [0]}}"#))
        XCTAssertLessThan(Int(other?.r ?? 255), 60, "a document missing from the map keeps all its layers")
    }

    // MARK: Refusals and scopes

    func testLockedDocumentsAreRefusedWhileLocked() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let lock = FakeLockService(locked: [Fixtures.docID])
        h.app.services.lock = lock
        do {
            _ = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf"])
            XCTFail("a locked document must not export")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .locked)
        }
        lock.locked = []
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf"])
        XCTAssertEqual(out["files"]?.arrayValue?.count, 1)
    }

    func testUnknownFormatsAndKindsAFormatCannotExportAreRefused() async throws {
        let h = Harness(features: [NibExportFeature.self])
        do {
            _ = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "docx"])
            XCTFail("unknown format")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.format")
        }
        do {
            _ = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC03"], "format": "pdf"])
            XCTFail("no pdf exporter handles study sets here")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
    }

    /// "pdf" of a text document goes to the exporter registered for that kind (F103's "textdoc.pdf").
    func testFormatsDispatchToTheExporterForEachDocumentKind() async throws {
        let h = Harness(features: [NibExportFeature.self])
        var textDoc = ExporterDescriptor(id: "textdoc.pdf", title: "PDF", fileExtension: "pdf", utType: "com.adobe.pdf",
                                         owner: "test") { request, _ in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            try Data("%PDF-1.4 \(request.documents.map { $0.raw })".utf8).write(to: url)
            return [url]
        }
        textDoc.docKinds = [.textDocument]
        h.app.content.exporters.register(textDoc)
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01", "doc:FIXTUREDOC02"], "format": "pdf",
                                                         "inline": true])
        let files = try XCTUnwrap(out["files"]?.arrayValue)
        XCTAssertEqual(files.count, 2)
        let second = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(files[1]["base64"]?.stringValue)))
        XCTAssertTrue(String(decoding: second, as: UTF8.self).contains("FIXTUREDOC02"))
    }

    func testTheUserMayLeaveDocsOutForTheWindowsDocument() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["format": "pdf", "name": "Lecture 3"])
        XCTAssertEqual(out["files"]?.arrayValue?.first?["name"]?.stringValue, "Lecture 3.pdf")
    }

    // MARK: Options and page ranges

    func testPageRangesAreOneBasedAndClampedToTheDocument() throws {
        XCTAssertEqual(try ExportPages.parseRange("1-3, 5, 8-", count: 9), [0, 1, 2, 4, 7, 8])
        XCTAssertEqual(try ExportPages.parseRange("-2; 2", count: 5), [0, 1])
        XCTAssertEqual(try ExportPages.parseRange("4-99", count: 5), [3, 4])
        for bad in ["3-1", "x", "0", "1-2-3", "7"] {
            XCTAssertThrowsError(try ExportPages.parseRange(bad, count: 5), bad) { error in
                XCTAssertEqual((error as? NibError)?.path, "$.options.pageRange")
            }
        }
    }

    func testOptionsParseLenientlyAndRejectWrongTypes() throws {
        let o = try ExportOptions(try JSONValue.parse(
            #"{"mode": "editable", "background": false, "stickyNotes": "icon", "visibleLayersOnly": true, "visibleLayers": {"doc:FIXTUREDOC01": [0, 2], "FIXTUREDOC04": []}, "board": "tiled", "paper": "letter", "scale": 3, "itemFormat": "nibnote", "comments": null}"#))
        XCTAssertEqual(o.mode, .editable)
        XCTAssertFalse(o.background)
        XCTAssertTrue(o.annotations)
        XCTAssertTrue(o.comments)
        XCTAssertEqual(o.stickyNotes, .icon)
        XCTAssertEqual(o.layers(for: Fixtures.docID), [0, 2])
        XCTAssertEqual(o.layers(for: Fixtures.whiteboardID), [])
        XCTAssertNil(o.layers(for: Fixtures.textDocID))
        XCTAssertEqual(o.board, .tiled)
        XCTAssertEqual(o.paper, .letter)
        XCTAssertEqual(o.scale, 3)
        XCTAssertEqual(o.itemFormat, "nibnote")
        XCTAssertNil(try ExportOptions([:]).layers(for: Fixtures.docID))
        XCTAssertNil(try ExportOptions(["visibleLayers": ["FIXTUREDOC01": [0]]]).layers(for: Fixtures.docID),
                     "visibleLayers only applies with visibleLayersOnly")
        for (json, path) in [(#"{"mode": "flat"}"#, "$.options.mode"), (#"{"annotations": 1}"#, "$.options.annotations"),
                             (#"{"scale": 9}"#, "$.options.scale"), (#"{"itemFormat": "zip"}"#, "$.options.itemFormat"),
                             (#"{"visibleLayers": {"D": ["a"]}}"#, "$.options.visibleLayers.D")] {
            XCTAssertThrowsError(try ExportOptions(try JSONValue.parse(json))) { error in
                XCTAssertEqual((error as? NibError)?.path, path, json)
            }
        }
    }

    func testFileNamesAreSanitisedAndUnique() {
        XCTAssertEqual(ExportNames.sanitize("Physics: Unit 1/2", fallback: "x"), "Physics- Unit 1-2")
        XCTAssertEqual(ExportNames.sanitize("  ..  ", fallback: "Notebook"), "Notebook")
        var used = Set<String>()
        XCTAssertEqual(ExportNames.unique("Notes", ext: "pdf", used: &used), "Notes.pdf")
        XCTAssertEqual(ExportNames.unique("notes", ext: "pdf", used: &used), "notes 2.pdf")
        XCTAssertEqual(ExportNames.unique("Notes", ext: "nibnote.zip", used: &used), "Notes.nibnote.zip")
    }

    // MARK: Packages

    /// The package holds the store's files: the head, one compressed page file per page with items on the exported
    /// layers (comments included), the assets, and the audio transcript.
    func testNibnotePackageHasTheStoreFormatWithAudioCommentsAndVisibleLayersOnly() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let hidden = Item(id: "HIDDENSTK001", kind: .stroke, layer: 2,
                          stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 50, y: 10)]))
        try await h.insert([hidden])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nibexport-test-" + UUID().uuidString)
        let package = folder.appendingPathComponent("Fixture Notebook.nibnote")
        h.app.commands.register(CommandDescriptor(id: "test.package", title: "Package", summary: "Test helper.",
                                                  effect: .read, exposure: .ui)) { _, ctx in
            let options = try ExportOptions(try JSONValue.parse(#"{"visibleLayersOnly": true, "visibleLayers": {"FIXTUREDOC01": [0]}}"#))
            let source = try PackageSource.make(Fixtures.docID, request: ExportRequest(documents: [Fixtures.docID]),
                                                options: options, ctx: ctx)
            try PackageWriter.write(source.job, pull: MainPull { try source.items($0) }, to: package)
            source.evict()
            return .null
        }
        try await h.run("test.package")
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = h.app.deviceHex
        let head = try JSONDecoder().decode(DocumentContent.self,
                                            from: Data(contentsOf: package.appendingPathComponent("doc.\(device).json")))
        XCTAssertEqual(head.meta.id, Fixtures.docID)
        XCTAssertEqual(head.livePages.map { $0.id }, [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        XCTAssertEqual(head.liveAudio.map { $0.id }, [Fixtures.audioID])
        XCTAssertEqual(head.liveOutline.map { $0.id }, [Fixtures.outlineID])
        let pageFile = package.appendingPathComponent("pages/FIXTUREPG001/\(device).nibpage")
        let json = try (Data(contentsOf: pageFile) as NSData).decompressed(using: .lzfse) as Data
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("ptsB64"), "points are stored in compact form")
        let items = try JSONDecoder().decode([Item].self, from: json)
        let ids = Set(items.map { $0.id })
        XCTAssertTrue(ids.contains(Fixtures.commentID))
        XCTAssertTrue(ids.contains(Fixtures.strokeID))
        XCTAssertFalse(ids.contains("HIDDENSTK001"), "layer 2 is not exported")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: package.appendingPathComponent("assets/fixture-image.png").path))
        XCTAssertTrue(fm.fileExists(atPath: package.appendingPathComponent("assets/fixture-page.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: package.appendingPathComponent("audio/FIXTUREAUD01.transcript.json").path))
        XCTAssertFalse(fm.fileExists(atPath: package.appendingPathComponent("pages/FIXTUREPG002").path), "empty pages have no file")
    }

    func testNibnoteExportIsAZippedPackage() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC03"], "format": "nibnote", "inline": true])
        let file = try XCTUnwrap(out["files"]?.arrayValue?.first)
        XCTAssertEqual(file["name"]?.stringValue, "Fixture Study Set.nibnote.zip")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["base64"]?.stringValue)))
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertNotNil(data.range(of: Data("Fixture Study Set.nibnote/doc.\(h.app.deviceHex).json".utf8)))
    }

    /// A folder exports as a zip of its documents under the folder's name; kinds the item format cannot export fall
    /// back to packages.
    func testZipKeepsTheFolderTree() async throws {
        let h = Harness(features: [NibExportFeature.self])
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["folder:FIXTUREFLD01"], "format": "zip",
                                                         "options": ["itemFormat": "pdf"], "inline": true])
        let files = try XCTUnwrap(out["files"]?.arrayValue)
        XCTAssertEqual(files.map { $0["name"]?.stringValue }, ["Fixtures.zip"])
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(files[0]["base64"]?.stringValue)))
        for entry in ["Fixtures/Fixture Notebook.pdf", "Fixtures/Fixture Whiteboard.pdf",
                      "Fixtures/Fixture Study Set.nibnote.zip", "Fixtures/Fixture Text Document.nibnote.zip"] {
            XCTAssertNotNil(data.range(of: Data(entry.utf8)), entry)
        }
    }

    func testInlineIsOmittedAboveTheLimitButAssetsStillCome() async throws {
        XCTAssertEqual(ExportRun.inlineLimit, 20 * 1_048_576)
        let h = Harness(features: [NibExportFeature.self])
        let big = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data(count: ExportRun.inlineLimit + 1).write(to: big)
        h.app.content.exporters.register(ExporterDescriptor(id: "test.big", title: "Big", fileExtension: "bin",
                                                            utType: "public.data", owner: "test") { _, _ in [big] })
        let out = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "test.big", "inline": true])
        XCTAssertEqual(out["inlineOmitted"]?.boolValue, true)
        let file = try XCTUnwrap(out["files"]?.arrayValue?.first)
        XCTAssertNil(file["base64"]?.stringValue)
        XCTAssertTrue(file["asset"]?.stringValue?.hasPrefix("tmp:") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path), "the exporter's file is cleaned up")
    }
}
