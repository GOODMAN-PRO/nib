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

/// Handwriting recognition that takes a while (so an extraction is still running when the page changes).
private final class SlowRecognizer: TextRecognizer {
    func recognize(strokes: [Item], language: String) async throws -> [TextRecognition] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return [TextRecognition(text: "Slowpoke", bbox: Rect(x: 70, y: 110, width: 90, height: 20), source: "ink")]
    }

    func recognize(image: CGImage, language: String) async throws -> [TextRecognition] { [] }
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

    // MARK: Handwriting geometry

    private func stroke(_ id: String, _ points: [(Double, Double)]) -> Item {
        Item(id: ElementID(id), kind: .stroke, z: "V",
             stroke: Stroke(style: .defaultPen, points: points.map { StrokePoint(x: Float($0.0), y: Float($0.1)) }))
    }

    private func assertPlanKeepsTargetScale(_ bounds: [Rect], file: StaticString = #filePath, line: UInt = #line) {
        let plan = InkLayout.plan(bounds)
        let target = InkLayout.targetScale(strokeHeights: bounds.map { $0.height })
        XCTAssertEqual(plan.scale, target, accuracy: 1e-9, file: file, line: line)
        XCTAssertGreaterThan(plan.groups.count, 1, file: file, line: line)
        XCTAssertEqual(plan.groups.flatMap { $0 }.sorted(), Array(bounds.indices), "every stroke in exactly one render",
                       file: file, line: line)
        for g in plan.groups {
            let box = g.dropFirst().reduce(bounds[g[0]]) { $0.union(bounds[$1]) }
            let scale = InkLayout.cappedScale(plan.scale, bounds: box)
            XCTAssertGreaterThanOrEqual(scale, target * 0.9, "render of \(g.count) strokes over \(box)", file: file, line: line)
            XCTAssertLessThanOrEqual(box.width * scale + 2 * InkLayout.margin, InkLayout.maxSide + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(box.height * scale + 2 * InkLayout.margin, InkLayout.maxSide + 0.001, file: file, line: line)
        }
    }

    func testInkPlanKeepsTheTargetScaleOnLargeBoards() {
        // Four-letter words of 10 pt strokes every 250 × 150 pt across a 5000 × 3000 pt board.
        var board: [Rect] = []
        for row in 0..<20 {
            for col in 0..<20 {
                for letter in 0..<4 {
                    board.append(Rect(x: Double(col) * 250 + Double(letter) * 9, y: Double(row) * 150, width: 8, height: 10))
                }
            }
        }
        assertPlanKeepsTargetScale(board)
        // One dense block of writing 3000 pt wide (a single cluster too big for one render): it is tiled.
        var dense: [Rect] = []
        for row in 0..<25 {
            for word in 0..<66 {
                for letter in 0..<4 {
                    dense.append(Rect(x: Double(word) * 45 + Double(letter) * 9, y: Double(row) * 16, width: 8, height: 10))
                }
            }
        }
        assertPlanKeepsTargetScale(dense)
        // A long arrow across the board does not chain the notes together (they keep the target scale).
        let arrow = Rect(x: 0, y: 1_000, width: 4_900, height: 4)
        let plan = InkLayout.plan(board + [arrow])
        let target = InkLayout.targetScale(strokeHeights: (board + [arrow]).map { $0.height })
        for g in plan.groups where !g.contains(board.count) {
            let box = g.dropFirst().reduce(board[g[0]]) { $0.union(board[$1]) }
            XCTAssertGreaterThanOrEqual(InkLayout.cappedScale(plan.scale, bounds: box), target * 0.9)
        }
        // A normal page of notes is still read in one render.
        var page: [Rect] = []
        for row in 0..<30 {
            for word in 0..<11 {
                page.append(Rect(x: 40 + Double(word) * 45, y: 40 + Double(row) * 25, width: 36, height: 10))
            }
        }
        XCTAssertEqual(InkLayout.plan(page).groups.count, 1)
        XCTAssertEqual(InkLayout.plan([]).groups, [])
    }

    /// Bounds of the dark pixels of a render (pixel rows counted from the top).
    private func darkPixelBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[y * w + x] < 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testInkRenderMapsVisionBoxesBackToPageCoordinates() throws {
        // Far apart vertically, so a y-flip error cannot cancel out.
        let a = stroke("STROKEAAAAAA", [(100, 200), (160, 200), (160, 212)])
        let b = stroke("STROKEBBBBBB", [(300, 420), (380, 430)])
        let render = try XCTUnwrap(InkRender.make([a, b], scale: 3))
        XCTAssertEqual(render.scale, 3)
        XCTAssertEqual(render.width, Double(render.image.width))
        XCTAssertEqual(render.height, Double(render.image.height))
        for item in [a, b] {
            let r = InkRender.bounds(of: item)
            // Page → render pixels (top-left origin) → Vision's normalised rect (bottom-left origin) → page.
            let px = (r.x - render.origin.x) * render.scale + render.margin
            let py = (r.y - render.origin.y) * render.scale + render.margin
            let vision = CGRect(x: px / render.width, y: 1 - (py + r.height * render.scale) / render.height,
                                width: r.width * render.scale / render.width, height: r.height * render.scale / render.height)
            let back = render.pageRect(vision)
            for (u, v) in [(back.x, r.x), (back.y, r.y), (back.width, r.width), (back.height, r.height)] {
                XCTAssertEqual(u, v, accuracy: 0.5, "\(back) vs \(r)")
            }
        }
        // The ink really is where pageRect says: the dark pixels map back onto the strokes (within the pen width).
        let dark = try XCTUnwrap(darkPixelBounds(render.image))
        let vision = CGRect(x: dark.minX / render.width, y: 1 - dark.maxY / render.height,
                            width: dark.width / render.width, height: dark.height / render.height)
        let mapped = render.pageRect(vision)
        let ink = InkRender.bounds(of: a).union(InkRender.bounds(of: b))
        for (u, v) in [(mapped.minX, ink.minX), (mapped.minY, ink.minY), (mapped.maxX, ink.maxX), (mapped.maxY, ink.maxY)] {
            XCTAssertEqual(u, v, accuracy: 1.5, "\(mapped) vs \(ink)")
        }
    }

    func testAssembleAssignsStrokesToTheWordsTheyFormWithRealWordBoxes() {
        let c = stroke("LETTERCCCCCC", [(10, 10), (14, 20)])
        let a = stroke("LETTERAAAAAA", [(18, 12), (24, 20)])
        let between = stroke("BETWEENWORDS", [(34, 12), (57, 18)])
        let d = stroke("LETTERDDDDDD", [(60, 10), (66, 20)])
        let far = stroke("ANOTHERLINE1", [(10, 200), (40, 210)])
        // Real (non-proportional) word boxes: "cat" is written wider than "dog".
        let words: [(text: String, bbox: Rect)] = [("cat", Rect(x: 8, y: 8, width: 30, height: 14)),
                                                   ("dog", Rect(x: 55, y: 8, width: 20, height: 14))]
        let line = InkLayout.assemble(text: "cat dog", alternatives: ["cot dog", "cat dug"], bbox: Rect(x: 8, y: 8, width: 67, height: 14),
                                      confidence: 0.8, words: words, strokes: [c, a, between, d, far])
        XCTAssertEqual(line.words.map { $0.text }, ["cat", "dog"])
        XCTAssertEqual(line.words.map { $0.itemIDs }, [[c.id, a.id], [d.id]])
        XCTAssertEqual(line.itemIDs, [c.id, a.id, between.id, d.id], "a stroke between words belongs to the line only")
        XCTAssertFalse(line.itemIDs.contains(far.id))
        XCTAssertEqual(line.alternatives, ["cot dog", "cat dug"])
        XCTAssertEqual(line.words[1].bbox, Rect(x: 55, y: 8, width: 20, height: 14))
    }

    // MARK: Versions, sweeps and concurrency

    func testPageVersionsDependOnlyOnSettingsThatApplyToThePage() throws {
        let (h, indexer) = harness()
        let head = try h.app.workspace.content(Fixtures.docID)
        func version(_ page: PageID) throws -> String? {
            try indexer.pageSnapshot(Fixtures.docID, page, head: head, includeInk: true)?.version
        }
        let blank = try version(Fixtures.page2)
        let notes = try version(Fixtures.page1)
        let pdf = try version(Fixtures.pdfPage)
        h.app.settings.set(IndexKeys.ocrImages, true)
        XCTAssertEqual(try version(Fixtures.page2), blank, "no images: OCR does not apply")
        XCTAssertNotEqual(try version(Fixtures.page1), notes, "page 1 holds an image")
        XCTAssertNotEqual(try version(Fixtures.pdfPage), pdf)
        let withOCR = try version(Fixtures.page1)
        h.app.content.customItemTypes.register(CustomItemTypeDescriptor(owner: "other.plugin", type: "card", title: "Card", textPath: "title"))
        XCTAssertEqual(try version(Fixtures.page1), withOCR, "a custom type the page does not use")
        h.app.content.customItemTypes.register(CustomItemTypeDescriptor(owner: "nib.fixture", type: "box", title: "Box", textPath: "title"))
        XCTAssertNotEqual(try version(Fixtures.page1), withOCR, "the page's own custom item type")
        XCTAssertEqual(try version(Fixtures.page2), blank)
    }

    func testTogglingOCRRecognisesHandwritingAgainOnlyWhereImagesOrPDFsAre() async throws {
        let recognizer = FakeRecognizer([TextRecognition(text: "ink", bbox: Rect(x: 80, y: 80, width: 40, height: 10), source: "ink")])
        let h = Harness(features: [NibIndexFeature.self])
        h.app.services.recognizer = recognizer
        let indexer = try XCTUnwrap(h.app.services.get(IndexKeys.service, as: Indexer.self))
        // Handwriting on page 2 too, where there are no images.
        let pen = Item(kind: .stroke, stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: 80, y: 80), StrokePoint(x: 120, y: 90)]))
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page2] = [pen]
        await indexer.indexDocument(Fixtures.docID)
        let before = recognizer.strokeCalls
        XCTAssertEqual(before, 2)
        h.app.settings.set(IndexKeys.ocrImages, true)
        await indexer.indexDocument(Fixtures.docID)
        XCTAssertEqual(recognizer.strokeCalls, before + 1, "only page 1 (it holds an image) is read again")
    }

    func testSweepSkipsUnchangedDocumentsUntilTheirPackageChanges() async throws {
        let (h, indexer) = harness()
        let package = try XCTUnwrap(h.app.services.packages.url(Fixtures.docID))
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let headFile = package.appendingPathComponent("doc.00000007.json")
        try Data("{}".utf8).write(to: headFile)

        let first = await indexer.sweep(foreground: false)
        XCTAssertTrue(first)
        XCTAssertNotNil(indexer.db?.stamp(doc: Fixtures.docID))
        let remember = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertFalse(remember.isEmpty)

        // Page 2 changes in storage, but the package files look the same: the sweep reads only the head and emits nothing.
        let note = Item.makeText(TextBoxItem(frame: Frame(x: 72, y: 300, w: 200, h: 30), text: RichText(plain: "Wombat burrow")))
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page2] = [note]
        var progress = 0
        let sub = h.app.events.subscribe { e in if e.type == "index.progress" { progress += 1 } }
        defer { sub.cancel() }
        let second = await indexer.sweep(foreground: false)
        XCTAssertTrue(second)
        XCTAssertEqual(progress, 0, "a sweep that changes nothing emits no progress")
        let skipped = results(try await h.run("search.text", ["query": "wombat"]))
        XCTAssertTrue(skipped.isEmpty, "unchanged stamp: pages were not loaded")

        // The package's files change (the new page file arrives): the pages are checked again.
        try Data("{\"rev\":2}".utf8).write(to: headFile)
        _ = await indexer.sweep(foreground: false)
        let found = results(try await h.run("search.text", ["query": "wombat"]))
        XCTAssertEqual(found.first?["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page2).description)
        XCTAssertGreaterThan(progress, 0)
    }

    func testPageIndexFollowsPageMovesInDocumentsThatAreNotOpen() async throws {
        let (h, indexer) = harness()
        await indexer.indexDocument(Fixtures.docID)
        let before = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertEqual(before.first?["pageIndex"]?.intValue, 0)
        // Page 2 moves in front of page 1 (e.g. on another device); page 1's own version does not change.
        var head = try XCTUnwrap(h.persistence.heads[Fixtures.docID])
        let i = try XCTUnwrap(head.pages.firstIndex { $0.id == Fixtures.page2 })
        head.pages[i].order = "A"
        head.pages[i].rev = Rev(wallMs: 2, counter: 0, device: 8)
        h.persistence.heads[Fixtures.docID] = head
        await indexer.indexDocument(Fixtures.docID)
        XCTAssertFalse(h.app.workspace.isLoaded(Fixtures.docID))
        let after = results(try await h.run("search.text", ["query": "Remember"]))
        XCTAssertEqual(after.first?["pageIndex"]?.intValue, 1)
    }

    func testAnExtractionStillRunningNeverBringsBackADeletedPage() async throws {
        let h = Harness(features: [NibIndexFeature.self])
        h.app.services.recognizer = SlowRecognizer()
        let indexer = try XCTUnwrap(h.app.services.get(IndexKeys.service, as: Indexer.self))
        let head = try XCTUnwrap(h.persistence.heads[Fixtures.docID])
        let slow = Task { @MainActor in await indexer.indexPage(Fixtures.docID, Fixtures.page1, head: head) }
        var spins = 0
        while indexer.extractionsInFlight == 0 && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(indexer.extractionsInFlight, 1)
        // Meanwhile page 1 is deleted (another device) and the document is indexed again.
        var deleted = head
        let i = try XCTUnwrap(deleted.pages.firstIndex { $0.id == Fixtures.page1 })
        deleted.pages[i].deleted = true
        deleted.pages[i].rev = Rev(wallMs: 2, counter: 0, device: 8)
        h.persistence.heads[Fixtures.docID] = deleted
        await indexer.indexDocument(Fixtures.docID)
        _ = await slow.value
        XCTAssertEqual(indexer.extractionsInFlight, 0)
        XCTAssertNil(indexer.db?.version(doc: Fixtures.docID, key: Fixtures.page1.raw))
        let hits = results(try await h.run("search.text", ["query": "slowpoke"]))
        XCTAssertTrue(hits.isEmpty, "\(hits)")
    }

    func testRecognizeItemsKeepsReadingOrderPerPageAndPagesInRefOrder() async throws {
        let (h, _) = harness()
        let footer = Item.makeText(TextBoxItem(frame: Frame(x: 72, y: 700, w: 200, h: 30), text: RichText(plain: "Page two footer")))
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page2] = [footer]
        let refs = [NodeRef.item(Fixtures.docID, Fixtures.page2, footer.id), NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.textID),
                    NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.stickyID)].map { JSONValue.string($0.description) }
        let r = try await h.run("recognize.items", ["refs": .array(refs)])
        XCTAssertEqual(r["text"]?.stringValue, "Page two footer\nRemember\nHello Nib")
    }

    func testOpenDocumentsOutsideTheLibraryAreSearchable() async throws {
        let (h, indexer) = harness()
        let doc: DocumentID = "LOOSEDOC0001"
        var meta = DocumentMeta(id: doc, kind: .notebook, createdAt: 1_700_000_000)
        meta.rev = Rev(wallMs: 1, counter: 0, device: 7)
        var page = PageRecord(id: "LOOSEPAGE001", order: "V", size: .a4)
        page.rev = meta.rev
        h.persistence.heads[doc] = DocumentContent(meta: meta, pages: [page])
        let sticky = Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 100, h: 100), text: RichText(plain: "Pelican")))
        h.persistence.pageItems[doc] = [page.id: [sticky]]
        _ = try h.app.workspace.content(doc)
        await indexer.indexDocument(doc)
        let open = results(try await h.run("search.text", ["query": "pelican", "scope": "doc:LOOSEDOC0001"]))
        XCTAssertEqual(open.first?["page"]?.stringValue, "page:LOOSEDOC0001/LOOSEPAGE001")
        h.app.workspace.close(doc)
        let closed = results(try await h.run("search.text", ["query": "pelican"]))
        XCTAssertTrue(closed.isEmpty, "neither in the library nor open")
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
