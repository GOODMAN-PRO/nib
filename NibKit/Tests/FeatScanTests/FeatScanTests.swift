import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatScan

/// A scan's sheets; nil entries are sheets that cannot be read. Records the order they are read in.
@MainActor
final class FakeSheets: ScanSheets {
    let images: [UIImage?]
    private(set) var reads: [Int] = []

    init(_ images: [UIImage?]) { self.images = images }

    var count: Int { images.count }

    func image(at index: Int) -> UIImage? {
        reads.append(index)
        return images[index]
    }
}

/// Stands in for the document camera, the QR reader, Safari and the clipboard.
@MainActor
final class FakeScanDevice: ScanDevice {
    var sheets: [UIImage?]?
    var code: String?
    private(set) var captures = 0
    private(set) var stages: [ScanStage] = []
    private(set) var lastSheets: FakeSheets?
    private(set) var opened: [URL] = []
    private(set) var copied: [String] = []

    init(sheets: [UIImage?]? = nil, code: String? = nil) {
        self.sheets = sheets
        self.code = code
    }

    func captureDocuments(on stage: ScanStage) async throws -> ScanSheets? {
        captures += 1
        stages.append(stage)
        guard let sheets else { return nil }
        let fake = FakeSheets(sheets)
        lastSheets = fake
        return fake
    }

    func readQRCode(on stage: ScanStage) async throws -> String? {
        stages.append(stage)
        return code
    }

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return true
    }

    func copy(_ text: String) { copied.append(text) }
}

/// An asset store whose disk is full.
final class FullAssetStore: AssetStore {
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef { throw NibError(.internalError, "disk full") }
    func url(_ ref: AssetRef, doc: DocumentID) -> URL? { nil }
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data { throw NibError.notFound("asset \(ref.name)") }
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef { throw NibError(.internalError, "disk full") }
    func temporaryURL(_ ref: AssetRef) -> URL? { nil }
}

/// The window's floating host: records toasts.
@MainActor
final class FakeFloatingHost: FloatingHosting {
    private(set) var toasts: [(message: String, actionTitle: String?)] = []
    private(set) var lastAction: (@MainActor () -> Void)?

    func present(_ id: String, content: AnyView) {}
    func dismiss(_ id: String) {}
    func isPresenting(_ id: String) -> Bool { false }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { false }
    func removeAnchor(_ id: String) {}
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { nil }

    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {
        toasts.append((message, actionTitle))
        lastAction = action
    }
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
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 110),
                                                                 .foregroundColor: UIColor.black]
                (text as NSString).draw(at: CGPoint(x: 100, y: 200), withAttributes: attributes)
            }
        }
    }

    /// Puts `device` in for the system camera until the test ends.
    @discardableResult
    private func install(_ device: FakeScanDevice) -> FakeScanDevice {
        let previous = ScanDevices.current
        ScanDevices.current = device
        addTeardownBlock {
            await MainActor.run { ScanDevices.current = previous }
        }
        return device
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

    private func refs(_ out: JSONValue) -> [String] {
        out["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    private func livePageIDs(_ h: Harness, _ doc: DocumentID = Fixtures.docID) throws -> [PageID] {
        try h.app.workspace.content(doc).livePages.map { $0.id }
    }

    // MARK: Registration

    func testConformanceAndDescriptors() async throws {
        let problems = await CommandConformance.check(features: [FeatScanFeature.self])
        XCTAssertEqual(problems, [])

        let h = Harness(features: [FeatScanFeature.self])
        let scan = try XCTUnwrap(h.app.commands.descriptor("scan.documents"))
        XCTAssertEqual(scan.owner, "scan")
        XCTAssertEqual(scan.effect, .library)
        XCTAssertTrue(scan.userPresence)
        guard case let .object(properties, required, _) = scan.params else { return XCTFail("params are not an object") }
        XCTAssertEqual(Set(properties.keys), ["doc", "position", "anchor", "folder", "ids"])
        XCTAssertEqual(required, [])
        let qr = try XCTUnwrap(h.app.commands.descriptor("scan.qr"))
        XCTAssertEqual(qr.effect, .session)
        XCTAssertTrue(qr.userPresence)
    }

    func testMenusSitInLibraryNewAddPageAndMore() throws {
        let h = Harness(features: [FeatScanFeature.self])
        let add = try XCTUnwrap(h.app.ui.menus.get("scan.addPage.documents"))
        XCTAssertEqual(add.location, .addPage)
        XCTAssertEqual(add.command, "scan.documents")
        XCTAssertEqual(add.icon, "doc.viewfinder")
        // Opened on page 2: the scan goes right after it.
        let onPage2 = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2)
        let expectedAfter: JSONValue = ["doc": "doc:FIXTUREDOC01", "position": "after",
                                        "anchor": "page:FIXTUREDOC01/FIXTUREPG002"]
        XCTAssertEqual(add.params(onPage2), expectedAfter)
        // No page in the context: the open page of the window.
        let expectedOpen: JSONValue = ["doc": "doc:FIXTUREDOC01", "position": "after",
                                       "anchor": "page:FIXTUREDOC01/FIXTUREPG001"]
        XCTAssertEqual(add.params(MenuContext(app: h.app, session: h.session, doc: Fixtures.docID)), expectedOpen)
        // No page at all: the end.
        let expectedEnd: JSONValue = ["doc": "doc:FIXTUREDOC01", "position": "end"]
        XCTAssertEqual(add.params(MenuContext(app: h.app, doc: Fixtures.docID)), expectedEnd)

        XCTAssertTrue(ScanMenus.canAddPages(onPage2))
        XCTAssertFalse(ScanMenus.canAddPages(MenuContext(app: h.app, doc: Fixtures.textDocID)), "not a notebook")
        h.session.readOnly = true
        XCTAssertFalse(ScanMenus.canAddPages(onPage2), "read-only window")
        h.session.readOnly = false

        let new = try XCTUnwrap(h.app.ui.menus.get("scan.new.documents"))
        XCTAssertEqual(new.location, .libraryNew)
        let expectedFolder: JSONValue = ["folder": "folder:FIXTUREFLD01"]
        XCTAssertEqual(new.params(MenuContext(app: h.app, folder: Fixtures.folderID)), expectedFolder)
        XCTAssertEqual(new.params(MenuContext(app: h.app)), [:])

        let newQR = try XCTUnwrap(h.app.ui.menus.get("scan.new.qr"))
        XCTAssertEqual(newQR.command, "scan.qr")
        XCTAssertEqual(newQR.icon, "qrcode")
        XCTAssertEqual(h.app.ui.menus.get("scan.more.qr")?.location, .documentMore)
        // Hostless tests have no camera, so every entry hides itself.
        XCTAssertFalse(new.isVisible(MenuContext(app: h.app)))
        XCTAssertFalse(add.isVisible(onPage2))
        XCTAssertFalse(newQR.isVisible(MenuContext(app: h.app)))
    }

    // MARK: scan.documents: OCR

    /// Acceptance: OCR of a generated image with text is stored as the page's "nib.scanText" blocks.
    func testOCROfAGeneratedImageIsStoredAsScanTextBlocks() async throws {
        let image = sheet("PHOTOSYNTHESIS")
        let cg = try XCTUnwrap(image.cgImage)
        let direct: [TextRecognition]
        do {
            direct = try ScanOCR.recognize(cg, language: "en-GB")
        } catch {
            throw XCTSkip("Vision text recognition is unavailable in this environment: \(error)")
        }
        let directText = direct.map { $0.text }.joined().uppercased().replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(directText.contains("PHOTOSYNTHESIS"), "Vision read \(directText)")

        // No recognizer installed: the scan runs Vision itself.
        let h = Harness(features: [FeatScanFeature.self])
        install(FakeScanDevice(sheets: [image]))
        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "end"])
        let scanned = try page(h, refs(out).first)
        XCTAssertNotNil(scanned.ext?[PageRecord.scanTextExtKey])
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
        // The ext is plain [TextRecognition] JSON, so any reader (the search index) decodes it.
        let decoded = try XCTUnwrap(scanned.ext?[PageRecord.scanTextExtKey]).decode([TextRecognition].self)
        XCTAssertEqual(decoded, blocks)
    }

    func testRecognizedBlocksAreScaledToPagePoints() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        var line = TextRecognition(text: " Mitochondria ", alternatives: ["Mitochondrla"],
                                   bbox: Rect(x: 124, y: 175.4, width: 620, height: 87.7), source: "image", confidence: 0.912)
        line.words = [TextRecognitionWord(text: "Mitochondria", bbox: Rect(x: 124, y: 175.4, width: 620, height: 87.7))]
        let recognizer = FakeRecognizer([line, TextRecognition(text: "   ", bbox: Rect(x: 0, y: 0, width: 10, height: 10),
                                                               source: "image")])
        h.app.services.recognizer = recognizer
        install(FakeScanDevice(sheets: [sheet()]))

        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "start"])
        XCTAssertEqual(recognizer.imageCalls, 1)
        let scanned = try page(h, refs(out).first)
        XCTAssertEqual(try livePageIDs(h).first, scanned.id)

        let size = ScanLayout.pageSize(pixelWidth: 1240, pixelHeight: 1754)
        XCTAssertEqual(scanned.size, size)
        XCTAssertEqual(scanned.rotation, 0)
        XCTAssertEqual(scanned.background.kind, .image)
        let asset = try XCTUnwrap(scanned.background.asset)
        XCTAssertEqual(asset.ext, "jpg")
        let stored = try XCTUnwrap(UIImage(data: try h.assets.data(asset, doc: Fixtures.docID)))
        XCTAssertEqual(stored.size.width * stored.scale, 1240, accuracy: 1)

        let blocks = ScanText.blocks(of: scanned)
        XCTAssertEqual(blocks.count, 1, "blank lines are dropped")
        let b = try XCTUnwrap(blocks.first)
        XCTAssertEqual(b.text, "Mitochondria")
        XCTAssertEqual(b.alternatives, ["Mitochondrla"])
        XCTAssertEqual(b.source, "scan")
        XCTAssertNil(b.words, "word boxes stay out of the document head")
        XCTAssertEqual(b.confidence, 0.91, accuracy: 0.001)
        XCTAssertEqual(b.bbox.x, 124 * size.width / 1240, accuracy: 0.01)
        XCTAssertEqual(b.bbox.y, 175.4 * size.height / 1754, accuracy: 0.01)
        XCTAssertEqual(b.bbox.width, 620 * size.width / 1240, accuracy: 0.01)
        XCTAssertEqual(b.bbox.height, 87.7 * size.height / 1754, accuracy: 0.01)
        XCTAssertEqual(out["textBlocks"]?.intValue, 1)
    }

    // MARK: scan.documents: placement and undo

    func testScanIntoTheOpenNotebookGoesAfterTheOpenPageAsOneUndoStep() async throws {
        let h = Harness(features: [FeatScanFeature.self])       // the session shows FIXTUREDOC01, page 1
        h.app.services.recognizer = FakeRecognizer([])
        install(FakeScanDevice(sheets: [sheet(), sheet(size: CGSize(width: 1754, height: 1240))]))
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)

        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "ids": ["SCANPAGE0001", "SCANPAGE0002"]])
        XCTAssertEqual(refs(out), ["page:FIXTUREDOC01/SCANPAGE0001", "page:FIXTUREDOC01/SCANPAGE0002"])
        XCTAssertEqual(out["doc"]?.stringValue, "doc:FIXTUREDOC01")
        XCTAssertEqual(out["created"]?.boolValue, false)
        XCTAssertEqual(out["cancelled"]?.boolValue, false)
        XCTAssertEqual(try livePageIDs(h),
                       [Fixtures.page1, NibID("SCANPAGE0001"), NibID("SCANPAGE0002"), Fixtures.page2, Fixtures.pdfPage])

        let landscape = try page(h, "page:FIXTUREDOC01/SCANPAGE0002")
        XCTAssertEqual(landscape.size?.height, PageSize.a4.width)
        XCTAssertEqual(landscape.size?.isLandscape, true)
        XCTAssertEqual(landscape.ext?[PageRecord.scanTextExtKey], JSONValue.array([]), "scanned with no text")

        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try livePageIDs(h).count, 5)
    }

    func testScanGoesBeforeAnAnchorAndAtTheStart() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.services.recognizer = FakeRecognizer([])
        install(FakeScanDevice(sheets: [sheet(), sheet(), sheet()]))

        _ = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "before",
                                               "anchor": "page:FIXTUREDOC01/FIXTUREPG002", "ids": ["B1", "B2", "B3"]])
        XCTAssertEqual(try livePageIDs(h), [Fixtures.page1, "B1", "B2", "B3", Fixtures.page2, Fixtures.pdfPage])

        // The anchor alone means after it; start ignores the open page.
        _ = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "anchor": "page:FIXTUREDOC01/FIXTUREPG003",
                                               "ids": ["A1", "A2", "A3"]])
        _ = try await h.run("scan.documents", ["doc": "FIXTUREDOC01", "position": "start", "ids": ["S1", "S2", "S3"]])
        XCTAssertEqual(try livePageIDs(h), ["S1", "S2", "S3", Fixtures.page1, "B1", "B2", "B3", Fixtures.page2,
                                            Fixtures.pdfPage, "A1", "A2", "A3"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 3, "one undo step per scan")
    }

    func testPlacementOrdersFitBetweenTheNeighbours() throws {
        let h = Harness(features: [FeatScanFeature.self])
        let content = try h.app.workspace.content(Fixtures.docID)     // orders: page 1 "V", page 2 "k", PDF page "t"
        func check(_ placement: ScanPlacement, above low: String?, below high: String?, file: StaticString = #filePath,
                   line: UInt = #line) {
            let keys = placement.orders(count: 40, in: content)
            XCTAssertEqual(keys.count, 40, file: file, line: line)
            XCTAssertEqual(keys, keys.sorted(), file: file, line: line)
            XCTAssertEqual(Set(keys).count, 40, file: file, line: line)
            if let low { XCTAssertTrue(keys.allSatisfy { $0 > low }, "\(keys) above \(low)", file: file, line: line) }
            if let high { XCTAssertTrue(keys.allSatisfy { $0 < high }, "\(keys) below \(high)", file: file, line: line) }
            XCTAssertLessThanOrEqual(keys.map { $0.count }.max() ?? 0, 4, "balanced keys stay short", file: file, line: line)
        }
        check(ScanPlacement(position: .after, anchor: Fixtures.page1), above: "V", below: "k")
        check(ScanPlacement(position: .before, anchor: Fixtures.page1), above: nil, below: "V")
        check(ScanPlacement(position: .before, anchor: Fixtures.pdfPage), above: "k", below: "t")
        check(ScanPlacement(position: .after, anchor: Fixtures.pdfPage), above: "t", below: nil)
        check(ScanPlacement(position: .start), above: nil, below: "V")
        check(ScanPlacement(position: .end), above: "t", below: nil)
        check(ScanPlacement(position: .after, anchor: "GONEPAGE0001"), above: "t", below: nil)

        // Two neighbours with one key leave no room between them: the pages go after both.
        var tied = content
        tied.pages = [PageRecord(id: "P1", order: "V"), PageRecord(id: "P2", order: "V")]
        let keys = ScanPlacement(position: .after, anchor: "P1").orders(count: 2, in: tied)
        XCTAssertTrue(keys.allSatisfy { $0 > "V" })
    }

    func testPlacementDefaultsAndErrors() throws {
        let h = Harness(features: [FeatScanFeature.self])
        let content = try h.app.workspace.content(Fixtures.docID)
        let doc = Fixtures.docID
        XCTAssertEqual(try ScanPlacement.resolve(position: nil, anchor: nil, doc: doc, content: content, session: h.session),
                       ScanPlacement(position: .after, anchor: Fixtures.page1), "after the open page")
        XCTAssertEqual(try ScanPlacement.resolve(position: nil, anchor: nil, doc: doc, content: content, session: nil),
                       ScanPlacement(position: .end), "no open page: the end")
        XCTAssertEqual(try ScanPlacement.resolve(position: "before", anchor: "page:FIXTUREDOC01/FIXTUREPG002", doc: doc,
                                                 content: content, session: h.session),
                       ScanPlacement(position: .before, anchor: Fixtures.page2))
        XCTAssertEqual(try ScanPlacement.resolve(position: "start", anchor: nil, doc: doc, content: content,
                                                 session: h.session),
                       ScanPlacement(position: .start))
        // The window shows another document: its page is no anchor here.
        h.session.document = Fixtures.whiteboardID
        XCTAssertEqual(try ScanPlacement.resolve(position: nil, anchor: nil, doc: doc, content: content, session: h.session),
                       ScanPlacement(position: .end))

        func code(_ position: String?, _ anchor: String?, session: EditorSession?) -> NibError.Code? {
            do {
                _ = try ScanPlacement.resolve(position: position, anchor: anchor, doc: doc, content: content, session: session)
                return nil
            } catch {
                return NibError.wrap(error).code
            }
        }
        XCTAssertEqual(code("after", nil, session: nil), .invalidParams, "after what?")
        XCTAssertEqual(code("middle", nil, session: nil), .invalidParams)
        XCTAssertEqual(code(nil, "page:FIXTUREDOC04/FIXTUREBRD01", session: nil), .invalidParams, "another document's page")
        XCTAssertEqual(code(nil, "page:FIXTUREDOC01/NOSUCHPAGE01", session: nil), .invalidParams)
        XCTAssertEqual(code(nil, "doc:FIXTUREDOC01", session: nil), .invalidParams)
    }

    // MARK: scan.documents: new notebooks

    func testScanWithoutADocumentMakesANewNotebookInTheFolder() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.services.recognizer = FakeRecognizer([TextRecognition(text: "Lab report", bbox: Rect(x: 10, y: 10, width: 400, height: 60),
                                                                    source: "image")])
        let device = install(FakeScanDevice(sheets: [sheet(), sheet(size: CGSize(width: 1754, height: 1240))]))

        let out = try await h.run("scan.documents", ["folder": "folder:FIXTUREFLD01", "ids": ["MYSCAN000001"]])
        XCTAssertEqual(out["created"]?.boolValue, true)
        XCTAssertEqual(device.captures, 1)
        guard let ref = out["doc"]?.stringValue, case let .document(doc)? = NodeRef(ref) else {
            return XCTFail("no doc in \(out)")
        }
        let node = try XCTUnwrap(h.library.node(doc))
        XCTAssertEqual(node.parent, Fixtures.folderID)
        XCTAssertEqual(node.documentKind, .notebook)
        XCTAssertTrue(node.title.hasPrefix("Scan"))
        let content = try h.app.workspace.content(doc)
        XCTAssertFalse(content.meta.coverEnabled, "page 1 is the scan, not a cover")
        XCTAssertEqual(content.meta.language, h.app.settings.get(NibSettings.defaultLanguage))
        // The stand-in first page became the first sheet; nothing else is in the notebook.
        let pages = content.livePages
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.id, NibID("MYSCAN000001"))
        XCTAssertEqual(refs(out), pages.map { NodeRef.page(doc, $0.id).description })
        XCTAssertTrue(pages.allSatisfy { $0.background.kind == .image && $0.ext?[PageRecord.scanTextExtKey] != nil })
        XCTAssertEqual(pages.last?.size?.isLandscape, true)
        XCTAssertEqual(ScanText.blocks(of: pages[0]).map { $0.text }, ["Lab report"])
        XCTAssertEqual(out["textBlocks"]?.intValue, 2)
        XCTAssertEqual(h.undoDepth(doc), 0, "a new notebook has nothing to undo to")
    }

    func testFailedScanRemovesTheNewNotebookAndLeavesDocumentsAlone() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.services.recognizer = FakeRecognizer([])
        h.app.services.assets = FullAssetStore()
        install(FakeScanDevice(sheets: [sheet()]))
        let nodes = Set(h.library.allNodes().map { $0.id })
        let before = try h.snapshotAll()

        var code = await errorCode(h, "scan.documents", ["folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(code, .internalError)
        XCTAssertEqual(Set(h.library.allNodes().map { $0.id }), nodes, "the half-made notebook is gone")

        code = await errorCode(h, "scan.documents", ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(code, .internalError)
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testUnreadableSheetsAreLeftOut() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.services.recognizer = FakeRecognizer([])
        let device = install(FakeScanDevice(sheets: [sheet(), nil, sheet(size: CGSize(width: 1754, height: 1240))]))

        let out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "end"])
        XCTAssertEqual(refs(out).count, 2)
        XCTAssertEqual(device.lastSheets?.reads, [0, 1, 2], "sheets are read one at a time, in order")

        device.sheets = [nil, nil]
        let nodes = h.library.allNodes().count
        let code = await errorCode(h, "scan.documents", [:])
        XCTAssertEqual(code, .internalError, "nothing could be read")
        XCTAssertEqual(h.library.allNodes().count, nodes, "no empty notebook is left behind")
    }

    func testCancelledScanChangesNothing() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        let device = install(FakeScanDevice(sheets: nil))
        let before = try h.snapshotAll()
        let documents = h.library.allNodes().count

        var out = try await h.run("scan.documents", [:])
        XCTAssertEqual(out["cancelled"]?.boolValue, true)
        XCTAssertNil(out["doc"])
        XCTAssertEqual(device.captures, 1)

        device.sheets = []
        out = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(out["cancelled"]?.boolValue, true, "a scan with no sheets")
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.library.allNodes().count, documents)
    }

    func testParamsAreCheckedBeforeTheCameraOpens() async {
        let h = Harness(features: [FeatScanFeature.self])
        let device = install(FakeScanDevice(sheets: [sheet()]))

        // JSON text keeps these literals cheap for the type checker.
        let cases: [(String, NibError.Code, String)] = [
            (#"{"doc": "doc:FIXTUREDOC01", "folder": "folder:FIXTUREFLD01"}"#, .invalidParams, "doc and folder"),
            (#"{"doc": "doc:FIXTUREDOC02"}"#, .invalidParams, "a text document takes no scanned pages"),
            (#"{"doc": "doc:FIXTUREDOC04"}"#, .invalidParams, "nor does a whiteboard"),
            (#"{"doc": "doc:NOSUCHDOC001"}"#, .notFound, "no such document"),
            (#"{"doc": "doc:FIXTUREDOC01", "position": "middle"}"#, .invalidParams, "no such position"),
            (#"{"doc": "doc:FIXTUREDOC01", "anchor": "page:FIXTUREDOC01/NOSUCHPAGE01"}"#, .invalidParams, "no such page"),
            (#"{"position": "end"}"#, .invalidParams, "a position needs doc"),
            (#"{"folder": "folder:NOSUCHFOLDER"}"#, .notFound, "no such folder"),
            (#"{"folder": "doc:FIXTUREDOC01"}"#, .invalidParams, "not a folder"),
            (#"{"doc": "doc:FIXTUREDOC01", "ids": ["FIXTUREPG001"]}"#, .invalidParams, "an id in use would overwrite a page"),
            (#"{"ids": ["not an id!"]}"#, .invalidParams, "invalid id"),
            (#"{"ids": ["SAME", "SAME"]}"#, .invalidParams, "duplicate ids")
        ]
        for (json, expected, why) in cases {
            let code = await errorCode(h, "scan.documents", try! JSONValue.parse(json))
            XCTAssertEqual(code, expected, why)
        }
        // A document saved by a newer Nib is read-only.
        h.app.services.set(NSMutableSet(array: [Fixtures.docID.raw]), for: ServiceKeys.storeReadOnly)
        let readOnly = await errorCode(h, "scan.documents", ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(readOnly, .permissionDenied)
        XCTAssertFalse(ScanMenus.canAddPages(MenuContext(app: h.app, session: h.session, doc: Fixtures.docID)))
        XCTAssertEqual(device.captures, 0)
    }

    func testAToastWithUndoFollowsPagesAddedToANotebook() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.services.recognizer = FakeRecognizer([])
        let host = FakeFloatingHost()
        h.session.floatingHost = host
        install(FakeScanDevice(sheets: [sheet(), sheet()]))

        _ = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "end"])
        XCTAssertEqual(host.toasts.map { $0.message }, [ScanFeedback.message(2)])
        XCTAssertEqual(host.toasts.first?.actionTitle, "Undo")
        XCTAssertEqual(try livePageIDs(h).count, 5)
        let firstAction = try XCTUnwrap(host.lastAction)

        // Undo reverts the scan's own step, even after a later edit in the notebook.
        let later = try await h.run("scan.documents", ["doc": "doc:FIXTUREDOC01", "position": "start",
                                                       "ids": ["LATER0000001", "LATER0000002"]])
        XCTAssertEqual(refs(later).count, 2)
        XCTAssertEqual(host.toasts.count, 2)
        firstAction()
        var waits = 0
        while try livePageIDs(h).count > 5, waits < 200 {
            waits += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(try livePageIDs(h),
                       ["LATER0000001", "LATER0000002", Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        XCTAssertNotEqual(ScanFeedback.message(1), ScanFeedback.message(2))

        // A new notebook opens instead of a toast.
        _ = try await h.run("scan.documents", [:])
        XCTAssertEqual(host.toasts.count, 2)
    }

    func testTheCameraShowsInTheInvokingWindowWithTheLiquidSetting() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        h.app.settings.set(NibSettings.liquidMode, "calm")
        let device = install(FakeScanDevice(sheets: nil, code: nil))
        _ = try await h.run("scan.documents", [:])
        _ = try await h.run("scan.qr")
        XCTAssertEqual(device.stages.count, 2)
        XCTAssertTrue(device.stages.allSatisfy { $0.session === h.session && $0.liquidMode == "calm" })

        // No window to show the camera in (a headless caller).
        let stage = ScanStage(session: nil, navigator: nil, liquidMode: "full")
        XCTAssertThrowsError(try stage.presenter()) { XCTAssertEqual(NibError.wrap($0).code, .unavailable) }
        // Hostless tests have no camera: the system device says so instead of prompting.
        ScanDevices.current = SystemScanDevice()
        let code = await errorCode(h, "scan.documents", [:])
        XCTAssertEqual(code, .unavailable)
    }

    func testDryRunNeverOpensTheCamera() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        let device = install(FakeScanDevice(sheets: [sheet()], code: "https://example.com"))
        for command in ["scan.documents", "scan.qr"] {
            do {
                _ = try await h.app.bus.execute(Invocation(command: command, params: [:], session: h.session, dryRun: true))
                XCTFail("\(command) ran as a dry run")
            } catch {
                XCTAssertEqual(NibError.wrap(error).code, .unsupported)
            }
        }
        XCTAssertEqual(device.captures, 0)
        XCTAssertTrue(device.stages.isEmpty)
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
        XCTAssertTrue(ScanLayout.newTitle(Date(timeIntervalSince1970: 1_790_000_000)).hasPrefix("Scan "))
    }

    func testBlocksFollowTheBackgroundOnAClampedStrip() throws {
        // A receipt far longer than the longest page: the page is clamped, the image is fitted into it and centred,
        // and the text boxes land where the renderer draws the words.
        let size = ScanLayout.pageSize(pixelWidth: 100, pixelHeight: 100_000)
        XCTAssertEqual(size.height, ScanLayout.longEdgeMax)
        let k = ScanLayout.longEdgeMax / 100_000
        let line = TextRecognition(text: "TOTAL", bbox: Rect(x: 0, y: 50_000, width: 100, height: 100), source: "image")
        let b = try XCTUnwrap(ScanText.blocks([line], imageWidth: 100, imageHeight: 100_000, in: size).first).bbox
        XCTAssertEqual(b.width, 100 * k, accuracy: 0.01)
        XCTAssertEqual(b.height, 100 * k, accuracy: 0.01)
        XCTAssertEqual(b.x, (size.width - 100 * k) / 2, accuracy: 0.01)
        XCTAssertEqual(b.y, 50_000 * k, accuracy: 0.01)
    }

    func testOCRLanguageMatching() {
        let supported = ["en-US", "fr-FR", "zh-Hans"]
        XCTAssertEqual(ScanOCR.match("en-US", in: supported), "en-US")
        XCTAssertEqual(ScanOCR.match("en-GB", in: supported), "en-US")
        XCTAssertEqual(ScanOCR.match("fr_CA", in: supported), "fr-FR")
        XCTAssertEqual(ScanOCR.match("zh-hans", in: supported), "zh-Hans")
        XCTAssertNil(ScanOCR.match("de-DE", in: supported))
        XCTAssertEqual(ScanText.blocks(of: PageRecord()), [])
        XCTAssertEqual(ScanText.blocks([TextRecognition(text: "x", bbox: Rect(x: 0, y: 0, width: 1, height: 1), source: "image")],
                                       imageWidth: 0, imageHeight: 10, in: .a4), [])
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
        XCTAssertEqual(QRPayload("  plain words \n").display, "plain words")
    }

    func testScanQROpensLinksAndCopiesEverythingElse() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        let device = install(FakeScanDevice(code: "https://example.com/unit?x=1"))

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
        XCTAssertNil(out["payload"])
    }

    func testScanQRHandsNibLinksToTheDeepLinkCommand() async throws {
        let h = Harness(features: [FeatScanFeature.self])
        var received: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: "app.openURL", title: "Open URL", summary: "Test stand-in.",
                                                  params: .obj(["url": .str()], required: ["url"]), effect: .session,
                                                  target: .app)) { params, _ in
            received.append(params)
            return .null
        }
        let device = install(FakeScanDevice(code: "nib://open/FIXTUREDOC01/FIXTUREPG002"))
        let out = try await h.run("scan.qr")
        XCTAssertEqual(out["opened"]?.boolValue, true)
        XCTAssertEqual(received.first?["url"]?.stringValue, "nib://open/FIXTUREDOC01/FIXTUREPG002")
        XCTAssertTrue(device.opened.isEmpty, "Nib opens its own links")
    }

    func testScannerModelShowsTheLatestCodeAndFinishesOnce() {
        let model = QRScannerModel(problem: nil)
        var results: [String?] = []
        model.onFinish = { results.append($0) }
        XCTAssertFalse(model.found(nil))
        XCTAssertFalse(model.found("   "))
        XCTAssertTrue(model.found("https://a.example"))
        XCTAssertFalse(model.found("https://a.example"), "the same code does not refresh the panel")
        model.dismissCode()
        XCTAssertNil(model.code)
        XCTAssertTrue(model.found("https://a.example"), "a code put away shows again when it is read again")
        XCTAssertTrue(model.found("hello"))
        XCTAssertEqual(model.code?.kind, .text)
        model.confirm()
        model.finish(nil)
        XCTAssertEqual(results, ["hello"])
        XCTAssertEqual(QRResultPanel.actionTitle(.web), "Open Link")
        XCTAssertEqual(QRResultPanel.actionTitle(.text), "Copy Text")
    }
}
