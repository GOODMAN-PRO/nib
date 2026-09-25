import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import NibIndex

/// Writes a text box on FIXTUREPG002 (drives the commit → debounce → index path).
private struct PutTestText: NibCommand {
    struct Params: Codable { var text: String }
    static let descriptor = CommandDescriptor(id: "test.putText", title: "Put Text", summary: "Test helper.",
                                              params: .obj(["text": .str()], required: ["text"]),
                                              examples: [["text": "x"]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in
            try tx.put(Item.makeText(TextBoxItem(frame: Frame(x: 72, y: 600, w: 200, h: 30), text: RichText(plain: p.text))),
                       doc: Fixtures.docID, page: Fixtures.page2)
        }
        return NoResult()
    }
}

/// Puts an image item with the given PNG on FIXTUREPG002.
private struct PutTestImage: NibCommand {
    struct Params: Codable { var asset: String }
    static let descriptor = CommandDescriptor(id: "test.putImage", title: "Put Image", summary: "Test helper.",
                                              params: .obj(["asset": .str()], required: ["asset"]),
                                              examples: [["asset": "x.png"]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in
            try tx.put(Item.makeImage(ImageItem(frame: Frame(x: 72, y: 100, w: 450, h: 120), asset: AssetRef(p.asset))),
                       doc: Fixtures.docID, page: Fixtures.page2)
        }
        return NoResult()
    }
}

@MainActor
final class NibIndexTests: XCTestCase {
    private var strokeRef: String { NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.strokeID).description }

    private func harness(_ script: [TextRecognition] = []) -> (Harness, Indexer) {
        let h = Harness(features: [NibIndexFeature.self])
        h.app.services.recognizer = FakeRecognizer(script)
        let indexer = h.app.services.get(IndexKeys.service, as: Indexer.self)!
        return (h, indexer)
    }

    private func results(_ r: JSONValue) -> [JSONValue] { r["results"]?.arrayValue ?? [] }

    private static func textImage(_ text: String) -> UIImage {
        let size = CGSize(width: 900, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(at: CGPoint(x: 40, y: 70), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72),
                                                                               .foregroundColor: UIColor.black])
        }
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [NibIndexFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersServicesAndBackgroundTask() {
        let h = Harness(features: [NibIndexFeature.self])
        XCTAssertTrue(h.app.services.recognizer is VisionRecognizer)
        XCTAssertEqual(h.app.content.backgroundTasks.get("app.nib.index")?.kind, .processing)
        for id in ["search.text", "recognize.pageText", "recognize.items", "index.rebuild"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "index", id)
        }
        XCTAssertNotNil(h.app.settings.descriptor("search.ocrImages"))
    }

    func testPageTextReturnsTypedTextOfFixturePage() async throws {
        let (h, _) = harness()
        h.app.content.customItemTypes.register(CustomItemTypeDescriptor(owner: "nib.fixture", type: "box", title: "Box", textPath: "title"))
        let r = try await h.run("recognize.pageText", ["page": .string(NodeRef.page(Fixtures.docID, Fixtures.page1).description)])
        let blocks = r["blocks"]?.arrayValue ?? []
        let texts = blocks.compactMap { $0["text"]?.stringValue }
        XCTAssertTrue(texts.contains("Hello Nib"), "\(texts)")
        XCTAssertTrue(texts.contains("Remember"), "\(texts)")
        XCTAssertTrue(texts.contains("Fixture box"), "\(texts)")
        let text = blocks.first { $0["text"]?.stringValue == "Hello Nib" }
        XCTAssertEqual(text?["source"]?.stringValue, "typed")
        XCTAssertEqual(text?["itemIDs"]?[0]?.stringValue, Fixtures.textID.raw)
        XCTAssertEqual(text?["bbox"]?.arrayValue?.count, 4)
    }

    func testPageTextReturnsPDFTextOfFixturePDFPage() async throws {
        let (h, _) = harness()
        let pdf = FakePDFService()
        pdf.texts[Fixtures.pdfAsset.name] = "Fixture PDF text"
        h.app.services.pdf = pdf
        let r = try await h.run("recognize.pageText", ["page": .string(NodeRef.page(Fixtures.docID, Fixtures.pdfPage).description)])
        let blocks = r["blocks"]?.arrayValue ?? []
        XCTAssertEqual(blocks.first?["text"]?.stringValue, "Fixture PDF text")
        XCTAssertEqual(blocks.first?["source"]?.stringValue, "pdf")
    }

    func testPageTextUnknownPageIsNotFound() async {
        let (h, _) = harness()
        do {
            _ = try await h.run("recognize.pageText", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"])
            XCTFail("expected not_found")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSearchFindsHandwritingAlternatesTypedTextTitlesOutlinesAndTranscripts() async throws {
        let line = TextRecognition(text: "clog", alternatives: ["dog", "cloq"], bbox: Rect(x: 70, y: 110, width: 90, height: 20), source: "ink")
        let (h, indexer) = harness([line])
        await indexer.indexDocument(Fixtures.docID)

        let ink = results(try await h.run("search.text", ["query": "dog"]))
        XCTAssertEqual(ink.first?["kind"]?.stringValue, "ink")
        XCTAssertEqual(ink.first?["alternative"]?.stringValue, "dog")
        XCTAssertEqual(ink.first?["ref"]?.stringValue, strokeRef)
        XCTAssertEqual(ink.first?["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page1).description)

        let typed = results(try await h.run("search.text", ["query": "hello"]))
        XCTAssertEqual(typed.first?["ref"]?.stringValue, NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.textID).description)
        XCTAssertEqual(typed.first?["title"]?.stringValue, "Fixture Notebook")
        XCTAssertEqual(typed.first?["docKind"]?.stringValue, "notebook")

        let title = results(try await h.run("search.text", ["query": "Fixture Notebook", "kinds": ["title"]]))
        XCTAssertEqual(title.first?["ref"]?.stringValue, "doc:FIXTUREDOC01")

        let outline = results(try await h.run("search.text", ["query": "fixture section"]))
        XCTAssertEqual(outline.first?["kind"]?.stringValue, "outline")
        XCTAssertEqual(outline.first?["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page1).description)

        let transcript = results(try await h.run("search.text", ["query": "velocity"]))
        XCTAssertEqual(transcript.first?["kind"]?.stringValue, "transcript")
        XCTAssertEqual(transcript.first?["ref"]?.stringValue, NodeRef.audio(Fixtures.docID, Fixtures.audioID).description)
        XCTAssertEqual(transcript.first?["time"]?.doubleValue, 4)

        let scoped = results(try await h.run("search.text", ["query": "hello", "scope": "page:FIXTUREDOC01/FIXTUREPG002"]))
        XCTAssertTrue(scoped.isEmpty)
    }

    func testLockedAndTrashedDocumentsAreExcluded() async throws {
        let (h, indexer) = harness()
        await indexer.indexDocument(Fixtures.docID)
        let unlocked = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertFalse(unlocked.isEmpty)
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        let locked = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertTrue(locked.isEmpty)
        h.app.services.lock = nil
        try h.library.trash(Fixtures.docID)
        let trashed = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertTrue(trashed.isEmpty)
    }

    func testIndexHandwritingSettingIsRespected() async throws {
        let line = TextRecognition(text: "zebra", bbox: Rect(x: 70, y: 110, width: 90, height: 20), source: "ink")
        let (h, indexer) = harness([line])
        h.app.settings.set(NibSettings.indexHandwriting, false)
        await indexer.indexDocument(Fixtures.docID)
        let inkOff = results(try await h.run("search.text", ["query": "zebra"]))
        XCTAssertTrue(inkOff.isEmpty)
        let typedOff = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertFalse(typedOff.isEmpty)
        h.app.settings.set(NibSettings.indexHandwriting, true)
        await indexer.indexDocument(Fixtures.docID)
        let inkOn = results(try await h.run("search.text", ["query": "zebra"]))
        XCTAssertEqual(inkOn.first?["kind"]?.stringValue, "ink")
    }

    func testRecognizeItemsMapsWordsToStrokes() async throws {
        let line = TextRecognition(text: "Hello world", bbox: Rect(x: 70, y: 110, width: 90, height: 20), source: "ink")
        let (h, _) = harness([line])
        let textRef = NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.textID).description
        let r = try await h.run("recognize.items", ["refs": [.string(strokeRef), .string(textRef)]])
        XCTAssertEqual(r["text"]?.stringValue, "Hello world\nHello Nib")
        let lines = r["lines"]?.arrayValue ?? []
        XCTAssertEqual(lines.count, 2)
        let words = lines.first?["words"]?.arrayValue ?? []
        XCTAssertEqual(words.map { $0["text"]?.stringValue }, ["Hello", "world"])
        XCTAssertEqual(words.first?["refs"], [.string(strokeRef)])
        XCTAssertEqual(lines.first?["refs"], [.string(strokeRef)])
        XCTAssertEqual(lines.last?["refs"], [.string(textRef)])
    }

    func testRecognizeItemsRejectsNonItemRefs() async {
        let (h, _) = harness()
        do {
            _ = try await h.run("recognize.items", ["refs": ["page:FIXTUREDOC01/FIXTUREPG001"]])
            XCTFail("expected invalid_params")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.refs[0]")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCommitsAreIndexedAfterTheDebounceWithProgressEvents() async throws {
        let (h, indexer) = harness()
        h.app.commands.register(PutTestText.self)
        indexer.debounce = 0.05
        indexer.start()
        var progress = 0
        let sub = h.app.events.subscribe { e in if e.type == "index.progress" { progress += 1 } }
        defer { sub.cancel() }
        try await h.run("test.putText", ["text": "Quokka crossing"])
        var found: [JSONValue] = []
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            // Library scope: nothing is flushed on demand, so a hit proves the debounced indexing ran.
            found = results(try await h.run("search.text", ["query": "quokka"]))
            if !found.isEmpty { break }
        }
        XCTAssertEqual(found.first?["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page2).description)
        XCTAssertGreaterThan(progress, 0)
    }

    func testRebuildDocument() async throws {
        let (h, _) = harness()
        let r = try await h.run("index.rebuild", ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(r["scheduled"]?.boolValue, false)
        XCTAssertGreaterThan(r["units"]?.intValue ?? 0, 0)
        let typed = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertEqual(typed.first?["kind"]?.stringValue, "typed")
        let blocks = results(try await h.run("search.text", ["query": "blocks", "scope": "doc:FIXTUREDOC02"]))
        XCTAssertTrue(blocks.isEmpty, "only the rebuilt document is indexed")
    }

    func testScanTextPageExtIsIndexed() {
        let value: JSONValue = [["text": "Scanned receipt", "bbox": [10, 20, 100, 12]], "Loose line"]
        let recs = PageExtractor.scanRecognitions(value)
        XCTAssertEqual(recs.map { $0.text }, ["Scanned receipt", "Loose line"])
        XCTAssertEqual(recs.first?.bbox, Rect(x: 10, y: 20, width: 100, height: 12))
        let full = try! JSONValue.from([TextRecognition(text: "Full", alternatives: ["Fall"], bbox: Rect(x: 1, y: 2, width: 3, height: 4), source: "scan")])
        XCTAssertEqual(PageExtractor.scanRecognitions(full).first?.alternatives, ["Fall"])
    }

    func testCustomItemTextPaths() {
        let data: JSONValue = ["series": [["label": "Q1"], ["label": "Q2"]], "title": "Chart", "n": 3]
        XCTAssertEqual(PageExtractor.text(at: "series.1.label", in: data), "Q2")
        XCTAssertEqual(PageExtractor.text(at: "series", in: data), "Q1 Q2")
        XCTAssertEqual(PageExtractor.text(at: "n", in: data), "3")
        XCTAssertNil(PageExtractor.text(at: "missing.path", in: data))
        let item = CustomItem(owner: "gone.plugin", type: "note", frame: Frame(x: 0, y: 0, w: 10, h: 10), data: ["label": "Orphan"])
        XCTAssertEqual(PageExtractor.customText(item, path: nil), "Orphan")
    }

    private func assertRect(_ a: Rect?, _ b: Rect, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a else { return XCTFail("nil rect", file: file, line: line) }
        for (x, y) in [(a.x, b.x), (a.y, b.y), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 1e-9, "\(a) vs \(b)", file: file, line: line)
        }
    }

    func testImageOCRMapsThroughFrameAndCrop() {
        let frame = Frame(x: 100, y: 200, w: 300, h: 100)
        let r = ImageGeometry.pageRect(Rect(x: 60, y: 20, width: 30, height: 10), imageWidth: 600, imageHeight: 200, frame: frame, crop: nil)
        assertRect(r, Rect(x: 130, y: 210, width: 15, height: 5))
        let cropped = ImageGeometry.pageRect(Rect(x: 300, y: 0, width: 60, height: 20), imageWidth: 600, imageHeight: 200, frame: frame,
                                             crop: Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        assertRect(cropped, Rect(x: 100, y: 200, width: 60, height: 10))
        XCTAssertNil(ImageGeometry.pageRect(Rect(x: 0, y: 0, width: 60, height: 20), imageWidth: 600, imageHeight: 200, frame: frame,
                                            crop: Rect(x: 0.5, y: 0, width: 0.5, height: 1)))
    }

    func testInkLayoutScaleAndWordSplit() {
        // 10 pt strokes ≈ 7 pt x-height → ~4.5 px/pt, so the x-height renders near 32 px.
        let scale = InkLayout.renderScale(strokeHeights: [10, 10, 10], bounds: Rect(x: 0, y: 0, width: 300, height: 40))
        XCTAssertEqual(scale * 10 / 1.4, InkLayout.targetXHeight, accuracy: 0.01)
        // A full A4 page never exceeds the render caps.
        let page = InkLayout.renderScale(strokeHeights: [4], bounds: Rect(x: 0, y: 0, width: 595, height: 842))
        XCTAssertLessThanOrEqual(842 * page, InkLayout.maxSide + 0.001)
        XCTAssertLessThanOrEqual(595 * 842 * page * page, InkLayout.maxPixels + 1)
        let words = InkLayout.splitWords("ab cd", in: Rect(x: 0, y: 0, width: 50, height: 10))
        XCTAssertEqual(words.map { $0.text }, ["ab", "cd"])
        XCTAssertEqual(words[1].bbox.x, 30, accuracy: 0.001)
    }

    func testVisionReadsGeneratedImageAndOCRMakesImagesSearchable() async throws {
        let image = NibIndexTests.textImage("Quantum harbour 2026")
        let recognizer = VisionRecognizer()
        let direct: [TextRecognition]
        do {
            direct = try await recognizer.recognize(image: image.cgImage!, language: "en-GB")
        } catch {
            throw XCTSkip("Vision text recognition is unavailable in this environment: \(error)")
        }
        let read = direct.map { $0.text }.joined(separator: " ").lowercased()
        XCTAssertTrue(read.contains("quantum"), read)
        XCTAssertEqual(direct.first?.source, "image")

        let h = Harness(features: [NibIndexFeature.self])
        h.app.commands.register(PutTestImage.self)
        let asset = try h.assets.put(image.pngData()!, ext: "png", doc: Fixtures.docID)
        try await h.run("test.putImage", ["asset": .string(asset.name)])
        h.app.settings.set(IndexKeys.ocrImages, true)
        let indexer = h.app.services.get(IndexKeys.service, as: Indexer.self)!
        await indexer.indexDocument(Fixtures.docID)
        let hit = results(try await h.run("search.text", ["query": "quantum", "kinds": ["image"]])).first
        XCTAssertEqual(hit?["kind"]?.stringValue, "image")
        XCTAssertEqual(hit?["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page2).description)
    }

    func testLanguageResolution() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "ja-JP", "pt-BR"]
        XCTAssertEqual(VisionRecognizer.resolve("en-GB", supported: supported), "en-US")
        XCTAssertEqual(VisionRecognizer.resolve("fr-fr", supported: supported), "fr-FR")
        XCTAssertEqual(VisionRecognizer.resolve("zh-TW", supported: supported), "zh-Hant")
        XCTAssertEqual(VisionRecognizer.resolve("zh-CN", supported: supported), "zh-Hans")
        XCTAssertEqual(VisionRecognizer.resolve("pt_PT", supported: supported), "pt-BR")
        XCTAssertNil(VisionRecognizer.resolve("xx-YY", supported: supported))
    }
}
