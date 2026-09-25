import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatScan

/// Stands in for the document camera, the QR reader, Safari and the clipboard.
@MainActor
final class FakeScanDevice: ScanDevice {
    var sheets: [UIImage]?
    var code: String?
    private(set) var captures = 0
    private(set) var opened: [URL] = []
    private(set) var copied: [String] = []

    init(sheets: [UIImage]? = nil, code: String? = nil) {
        self.sheets = sheets
        self.code = code
    }

    func captureDocuments(session: EditorSession?) async throws -> [UIImage]? {
        captures += 1
        return sheets
    }

    func readQRCode(session: EditorSession?) async throws -> String? { code }

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return true
    }

    func copy(_ text: String) { copied.append(text) }
}

@MainActor
final class FeatScanTests: XCTestCase {
    /// A white sheet at scale 1 (so its pixel size is `size`), optionally with one line of large black text.
    private func sheet(_ text: String? = nil, size: CGSize = CGSize(width: 1240, height: 1754)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let text {
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 110, weight: .bold),
                                                                 .foregroundColor: UIColor.black]
                (text as NSString).draw(at: CGPoint(x: 100, y: 200), withAttributes: attributes)
            }
        }
    }

    private func errorCode(_ h: Harness, _ command: String, _ params: JSONValue) async -> NibError.Code? {
        do {
            _ = try await h.run(command, params)
            return nil
        } catch {
            return NibError.wrap(error).code
        }
    }

    private func page(_ h: Harness, _ ref: String?) throws -> PageRecord {
        guard let ref, case let .page(doc, id)? = NodeRef(ref), let page = try h.app.workspace.content(doc).page(id) else {
            throw NibError.notFound("page \(ref ?? "nil")")
        }
        return page
    }

    // MARK: Registration

    func testConformanceAndDescriptors() async {
        let problems = await CommandConformance.check(features: [FeatScanFeature.self])
        XCTAssertEqual(problems, [])

        let h = Harness(features: [FeatScanFeature.self])
        let scan = h.app.commands.descriptor("scan.documents")
        XCTAssertEqual(scan?.owner, "scan")
        XCTAssertEqual(scan?.effect, .library)
        XCTAssertEqual(scan?.userPresence, true)
        let qr = h.app.commands.descriptor("scan.qr")
        XCTAssertEqual(qr?.effect, .session)
        XCTAssertEqual(qr?.userPresence, true)
    }

    func testMenusSitInLibraryNewAndAddPage() throws {
        let h = Harness(features: [FeatScanFeature.self])
        let add = try XCTUnwrap(h.app.ui.menus.get("scan.addPage.documents"))
        XCTAssertEqual(add.location, .addPage)
        XCTAssertEqual(add.command, "scan.documents")
        let inNotebook = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1)
        let expectedAdd: JSONValue = ["doc": "doc:FIXTUREDOC01"]
        XCTAssertEqual(add.params(inNotebook), expectedAdd)
        XCTAssertTrue(ScanMenus.isNotebook(inNotebook))
        XCTAssertFalse(ScanMenus.isNotebook(MenuContext(app: h.app, doc: Fixtures.textDocID)))

        let new = try XCTUnwrap(h.app.ui.menus.get("scan.new.documents"))
        XCTAssertEqual(new.location, .libraryNew)
        let expectedNew: JSONValue = ["folder": "folder:FIXTUREFLD01"]
        XCTAssertEqual(new.params(MenuContext(app: h.app, nodes: [Fixtures.folderID])), expectedNew)
        XCTAssertEqual(new.params(MenuContext(app: h.app)), [:])

        XCTAssertEqual(h.app.ui.menus.get("scan.new.qr")?.command, "scan.qr")
        XCTAssertEqual(h.app.ui.menus.get("scan.more.qr")?.location, .documentMore)
        // Hostless tests have no camera, so every entry hides itself.
        XCTAssertFalse(new.isVisible(MenuContext(app: h.app)))
        XCTAssertFalse(add.isVisible(inNotebook))
    }

    // MARK: scan.documents

    /// Acceptance: OCR of a generated image with text is stored as the page's "nib.scanText" blocks.
    func testOCROfAGeneratedImageIsStoredAsScanTextBlocks() async throws {
        let image = sheet("PHOTOSYNTHESIS")
        let cg = try XCTUnwrap(image.cgImage)
        let direct: [TextRecognition]
        do {
            direct = try ScanOCR.recognize(cg, language: "en-US")
        } catch {
            throw XCTSkip("Vision text recognition is not available on this simulator: \(error)")
        }
        let directText = direct.map { $0.text }.joined().uppercased().replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(directText.contains("PHOTOSYNTHESIS"), "Vision read \(directText)")

        let h = Harness(features: [FeatScanFeature.self])
        let device = FakeScanDevice(sheets: [image])
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }

        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "end"])
        let scanned = try page(h, out["refs"]?[0]?.stringValue)
        let blocks = ScanText.blocks(of: scanned)
        let stored = blocks.map { $0.text }.joined().uppercased().replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(stored.contains("PHOTOSYNTHESIS"), "stored \(stored)")
        XCTAssertEqual(out["textBlocks"]?.intValue, blocks.count)
        let size = try XCTUnwrap(scanned.size)
        for block in blocks {
            XCTAssertEqual(block.source, "scan")
            XCTAssertGreaterThanOrEqual(block.bbox.x, 0)
            XCTAssertGreaterThanOrEqual(block.bbox.y, 0)
            XCTAssertLessThanOrEqual(block.bbox.x + block.bbox.width, size.width + 1)
            // The line was drawn in the top quarter of the sheet; the box is in page points, top-left origin.
            XCTAssertLessThan(block.bbox.y, size.height / 4)
        }
    }

    func testRecognizedBlocksAreScaledToPagePoints() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        let recognizer = FakeRecognizer([
            TextRecognition(text: " Mitochondria ", alternatives: ["Mitochondrla"],
                            bbox: Rect(x: 124, y: 175.4, width: 620, height: 87.7), source: "image", confidence: 0.912),
            TextRecognition(text: "   ", bbox: Rect(x: 0, y: 0, width: 10, height: 10), source: "image")
        ])
        h.app.services.recognizer = recognizer
        let device = FakeScanDevice(sheets: [sheet()])
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }

        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "start"])
        XCTAssertEqual(recognizer.imageCalls, 1)
        let scanned = try page(h, out["refs"]?[0]?.stringValue)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).livePages.first?.id, scanned.id)

        let size = ScanLayout.pageSize(pixelWidth: 1240, pixelHeight: 1754)
        XCTAssertEqual(scanned.size, size)
        XCTAssertEqual(scanned.background.kind, .image)
        let asset = try XCTUnwrap(scanned.background.asset)
        XCTAssertEqual(asset.ext, "jpg")
        XCTAssertNotNil(UIImage(data: try h.assets.data(asset, doc: Fixtures.docID)))

        let blocks = ScanText.blocks(of: scanned)
        XCTAssertEqual(blocks.count, 1, "blank lines are dropped")
        let b = try XCTUnwrap(blocks.first)
        XCTAssertEqual(b.text, "Mitochondria")
        XCTAssertEqual(b.alternatives, ["Mitochondrla"])
        XCTAssertEqual(b.source, "scan")
        XCTAssertEqual(b.confidence, 0.91, accuracy: 0.001)
        XCTAssertEqual(b.bbox.x, 124 * size.width / 1240, accuracy: 0.01)
        XCTAssertEqual(b.bbox.y, 175.4 * size.height / 1754, accuracy: 0.01)
        XCTAssertEqual(b.bbox.width, 620 * size.width / 1240, accuracy: 0.01)
        XCTAssertEqual(b.bbox.height, 87.7 * size.height / 1754, accuracy: 0.01)
        XCTAssertEqual(out["textBlocks"]?.intValue, 1)
    }

    func testScanIntoTheOpenNotebookGoesAfterTheOpenPageAsOneUndoStep() async throws {
        let h = Harness(features: [FeatScanFeature.self])       // the session shows FIXTUREDOC01, page 1
        h.app.services.recognizer = FakeRecognizer([])
        let device = FakeScanDevice(sheets: [sheet(), sheet(size: CGSize(width: 1754, height: 1240))])
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)

        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "ids": ["SCANPAGE0001", "SCANPAGE0002"]])
        XCTAssertEqual(out["refs"]?.arrayValue?.compactMap { $0.stringValue },
                       ["page:FIXTUREDOC01/SCANPAGE0001", "page:FIXTUREDOC01/SCANPAGE0002"])
        XCTAssertEqual(out["created"]?.boolValue, false)
        XCTAssertEqual(out["cancelled"]?.boolValue, false)
        let order = try h.app.workspace.content(Fixtures.docID).livePages.map { $0.id }
        XCTAssertEqual(order, [Fixtures.page1, NibID("SCANPAGE0001"), NibID("SCANPAGE0002"), Fixtures.page2, Fixtures.pdfPage])

        let landscape = try page(h, "page:FIXTUREDOC01/SCANPAGE0002")
        XCTAssertEqual(landscape.size?.height, PageSize.a4.width)
        XCTAssertEqual(landscape.size?.isLandscape, true)
        XCTAssertEqual(landscape.ext?[ScanText.extKey], JSONValue.array([]), "scanned with no text")

        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testScanWithoutADocumentMakesANewNotebookInTheFolder() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.services.recognizer = FakeRecognizer([])
        let device = FakeScanDevice(sheets: [sheet()])
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }

        let out = try await h.run("scan.documents", ["folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(out["created"]?.boolValue, true)
        guard let ref = out["doc"]?.stringValue, case let .document(doc)? = NodeRef(ref) else {
            return XCTFail("no doc in \(out)")
        }
        let node = try XCTUnwrap(h.library.node(doc))
        XCTAssertEqual(node.parent, Fixtures.folderID)
        XCTAssertEqual(node.documentKind, .notebook)
        XCTAssertTrue(node.title.hasPrefix("Scan"))
        let content = try h.app.workspace.content(doc)
        XCTAssertEqual(content.livePages.count, 1)
        XCTAssertFalse(content.meta.coverEnabled, "page 1 is the scan, not a cover")
        XCTAssertEqual(content.livePages.first?.background.kind, .image)
        XCTAssertEqual(h.undoDepth(doc), 0, "a new notebook has nothing to undo to")
    }

    func testCancelledScanChangesNothing() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        let device = FakeScanDevice(sheets: nil)
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }
        let before = try h.snapshotAll()
        let documents = h.library.allNodes().count

        let out = try await h.run("scan.documents", [:])
        XCTAssertEqual(out["cancelled"]?.boolValue, true)
        XCTAssertNil(out["doc"])
        XCTAssertEqual(device.captures, 1)
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.library.allNodes().count, documents)
    }

    func testParamsAreCheckedBeforeTheCameraOpens() async {
        let h = Harness(features: [FeatScanFeature.self])
        let device = FakeScanDevice(sheets: [sheet()])
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }

        var code = await errorCode(h, "scan.documents", ["doc": "doc:FIXTUREDOC01", "folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode(h, "scan.documents", ["doc": "doc:FIXTUREDOC02"])
        XCTAssertEqual(code, .invalidParams, "a text document takes no scanned pages")
        code = await errorCode(h, "scan.documents", ["doc": "doc:NOSUCHDOC001"])
        XCTAssertEqual(code, .notFound)
        code = await errorCode(h, "scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "middle"])
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode(h, "scan.documents", ["folder": "folder:NOSUCHFOLDER"])
        XCTAssertEqual(code, .notFound)
        code = await errorCode(h, "scan.documents", ["doc": "doc:FIXTUREDOC01", "ids": ["FIXTUREPG001"]])
        XCTAssertEqual(code, .invalidParams, "an id already in use would overwrite that page")
        code = await errorCode(h, "scan.documents", ["ids": ["not an id!"]])
        XCTAssertEqual(code, .invalidParams)
        XCTAssertEqual(device.captures, 0)
    }

    func testPageSizeFollowsTheSheet() {
        let portrait = ScanLayout.pageSize(pixelWidth: 1000, pixelHeight: 2000)
        XCTAssertEqual(portrait.width, PageSize.a4.width)
        XCTAssertEqual(portrait.height, 1190.56, accuracy: 0.001)
        let landscape = ScanLayout.pageSize(pixelWidth: 2000, pixelHeight: 1000)
        XCTAssertEqual(landscape.width, 1190.56, accuracy: 0.001)
        XCTAssertEqual(landscape.height, PageSize.a4.width)
        XCTAssertEqual(ScanLayout.pageSize(pixelWidth: 0, pixelHeight: 100), .a4)
        XCTAssertEqual(ScanLayout.pageSize(pixelWidth: 100, pixelHeight: 1_000_000).height, ScanLayout.longEdgeMax)
    }

    func testOCRLanguageMatching() {
        let supported = ["en-US", "fr-FR", "zh-Hans"]
        XCTAssertEqual(ScanOCR.match("en-US", in: supported), "en-US")
        XCTAssertEqual(ScanOCR.match("en-GB", in: supported), "en-US")
        XCTAssertEqual(ScanOCR.match("fr_CA", in: supported), "fr-FR")
        XCTAssertEqual(ScanOCR.match("zh-hans", in: supported), "zh-Hans")
        XCTAssertNil(ScanOCR.match("de-DE", in: supported))
        XCTAssertEqual(ScanText.blocks(of: PageRecord()), [])
    }

    // MARK: scan.qr

    func testQRPayloadKinds() {
        XCTAssertEqual(QRPayload("https://example.com/a?b=1").kind, .web)
        XCTAssertEqual(QRPayload("  HTTP://EXAMPLE.COM  ").kind, .web)
        XCTAssertEqual(QRPayload("www.example.com/path").url?.absoluteString, "https://www.example.com/path")
        XCTAssertEqual(QRPayload("www.example.com:8080").kind, .web)
        XCTAssertEqual(QRPayload("nib://open/FIXTUREDOC01").kind, .nib)
        XCTAssertEqual(QRPayload("http://").kind, .text, "a link with no host")
        XCTAssertEqual(QRPayload("javascript:alert(1)").kind, .text)
        XCTAssertEqual(QRPayload("mailto:someone@example.com").kind, .text)
        XCTAssertEqual(QRPayload("WIFI:S:Lab;T:WPA;P:secret;;").kind, .text)
        XCTAssertEqual(QRPayload("https://example.com and more").kind, .text)
        XCTAssertNil(QRPayload("plain words").url)
    }

    func testScanQROpensLinksAndCopiesEverythingElse() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        let device = FakeScanDevice(code: "https://example.com/unit?x=1")
        let previous = ScanDevices.current
        ScanDevices.current = device
        defer { ScanDevices.current = previous }

        var out = try await h.run("scan.qr")
        XCTAssertEqual(out["kind"]?.stringValue, "web")
        XCTAssertEqual(out["opened"]?.boolValue, true)
        XCTAssertEqual(device.opened.map { $0.absoluteString }, ["https://example.com/unit?x=1"])

        // No deep-link feature installed: the nib:// link goes to the system, which hands it back to Nib.
        device.code = "nib://open/FIXTUREDOC01"
        out = try await h.run("scan.qr")
        XCTAssertEqual(out["kind"]?.stringValue, "nib")
        XCTAssertEqual(out["opened"]?.boolValue, true)
        XCTAssertEqual(device.opened.last?.absoluteString, "nib://open/FIXTUREDOC01")

        for text in ["WIFI:S:Lab;T:WPA;P:secret;;", "javascript:alert(1)"] {
            device.code = text
            out = try await h.run("scan.qr")
            XCTAssertEqual(out["kind"]?.stringValue, "text")
            XCTAssertEqual(out["copied"]?.boolValue, true)
            XCTAssertEqual(out["opened"]?.boolValue, false)
            XCTAssertEqual(out["payload"]?.stringValue, text)
        }
        XCTAssertEqual(device.copied, ["WIFI:S:Lab;T:WPA;P:secret;;", "javascript:alert(1)"])
        XCTAssertEqual(device.opened.count, 2, "text is never opened")

        device.code = nil
        out = try await h.run("scan.qr")
        XCTAssertEqual(out["cancelled"]?.boolValue, true)
    }

    func testScannerModelShowsTheLatestCodeAndFinishesOnce() {
        let model = QRScannerModel(problem: nil)
        var results: [String?] = []
        model.onFinish = { results.append($0) }
        XCTAssertFalse(model.found(nil))
        XCTAssertFalse(model.found("   "))
        XCTAssertTrue(model.found("https://a.example"))
        XCTAssertFalse(model.found("https://a.example"), "the same code does not refresh the card")
        XCTAssertTrue(model.found("hello"))
        XCTAssertEqual(model.code?.kind, .text)
        model.confirm()
        model.finish(nil)
        XCTAssertEqual(results, ["hello"])
    }
}
