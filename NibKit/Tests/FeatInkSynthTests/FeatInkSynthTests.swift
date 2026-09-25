import XCTest
import NibContracts
import NibTesting
@testable import FeatInkSynth

@MainActor
final class FeatInkSynthTests: XCTestCase {
    private var page1: String { NodeRef.page(Fixtures.docID, Fixtures.page1).description }
    private var page2: String { NodeRef.page(Fixtures.docID, Fixtures.page2).description }

    private func items(_ h: Harness, _ page: PageID = Fixtures.page2) throws -> [Item] {
        try h.app.workspace.items(Fixtures.docID, page: page)
    }

    private func strings(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    private func ref(_ page: PageID, _ id: ElementID) -> String {
        NodeRef.item(Fixtures.docID, page, id).description
    }

    private func inkBox(_ items: [Item]) -> Rect? {
        Rect.bounding(items.flatMap { $0.stroke?.polyline ?? [] })
    }

    /// A handwritten-looking word on the (still unloaded) page 2: synthesised, then stored as ordinary ink with the
    /// ids OLD0, OLD1, …
    private func seedWord(_ h: Harness, _ text: String, style: InkStyle, layer: Int = 1) -> [Item] {
        let layout = InkTypesetter.layout(text, at: Point(80, 200), options: .init(size: 24, shear: 0.2, style: style))
        let z = FractionalIndex.sequence(after: nil, count: layout.strokes.count)
        let seeded = layout.strokes.enumerated().map { k, stroke -> Item in
            var s = stroke
            InkModel.prepare(&s)
            return Item(id: NibID("OLD\(k)"), kind: .stroke, z: z[k], layer: layer, stroke: s)
        }
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page2] = seeded
        return seeded
    }

    private func assertError(_ h: Harness, _ command: String, _ params: JSONValue, _ code: NibError.Code,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await h.run(command, params)
            XCTFail("\(command) accepted \(params.jsonString())", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration and conformance

    func testCommandsConformWithUndoRoundTrips() async {
        let problems = await CommandConformance.check(features: [FeatInkSynthFeature.self], owners: [FeatInkSynthFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsAndTheDeviceFontSetting() throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        for id in [CommandIDs.inkWriteText, "handwriting.replaceWord"] {
            let d = try XCTUnwrap(h.app.commands.descriptor(id), id)
            XCTAssertEqual(d.owner, FeatInkSynthFeature.id)
            XCTAssertEqual(d.effect, .edit)
            XCTAssertTrue(d.undoable)
            XCTAssertFalse(d.examples.isEmpty)
        }
        let setting = try XCTUnwrap(h.app.settings.descriptor("inksynth.font"))
        XCTAssertFalse(setting.synced, "a device setting")
        XCTAssertEqual(h.app.settings.get(InkSynthSettings.font), .noteworthy)
    }

    func testTheDeviceFontSettingPicksTheHandwriting() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        try await h.run("settings.set", ["name": "inksynth.font", "value": "Marker Felt"])
        XCTAssertEqual(h.app.settings.get(InkSynthSettings.font), .markerFelt)
        XCTAssertEqual(try InkSynthParams.font(nil, settings: h.app.settings), .markerFelt)
        XCTAssertEqual(try InkSynthParams.font("bradley-hand", settings: h.app.settings), .bradleyHand, "a param wins")
        XCTAssertThrowsError(try InkSynthParams.font("Comic Sans", settings: h.app.settings))
    }

    // MARK: ink.writeText

    func testWriteTextStoresPreparedInkWithCallerIDsAsOneUndoStep() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        let before = try h.snapshot()
        h.session.activeLayer = 2
        let params: JSONValue = ["page": .string(page2), "text": "Hello Nib", "at": [72, 96], "size": 24,
                                 "color": "#1F5FD1", "ids": ["HELLO1", "HELLO2"]]
        let r = try await h.run(CommandIDs.inkWriteText, params)

        let refs = strings(r["refs"])
        XCTAssertGreaterThanOrEqual(refs.count, 8, "at least one stroke per letter")
        XCTAssertEqual(Array(refs.prefix(2)), [ref(Fixtures.page2, "HELLO1"), ref(Fixtures.page2, "HELLO2")])
        XCTAssertEqual(r["lines"], 1)
        XCTAssertNotNil(r["bounds"]?.arrayValue)

        let written = try items(h)
        XCTAssertEqual(Set(written.map { ref(Fixtures.page2, $0.id) }), Set(refs))
        for item in written {
            let stroke = try XCTUnwrap(item.stroke)
            XCTAssertEqual(stroke.style.color, RGBA(hex: "#1F5FD1"))
            XCTAssertEqual(stroke.style.tool, .pen)
            XCTAssertEqual(item.layer, 2, "the active layer")
            XCTAssertTrue(stroke.points.allSatisfy { $0.width > 0 && $0.height > 0 }, "InkModel.prepare derived nib sizes")
        }
        let box = try XCTUnwrap(inkBox(written))
        XCTAssertGreaterThanOrEqual(box.minX, 72 - 0.01)
        XCTAssertGreaterThanOrEqual(box.minY, 96 - 0.01)

        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try items(h).count, refs.count)
    }

    func testWriteTextWrapsAtThePageMarginByDefault() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        let text = "Velocity is the rate of change of displacement with respect to time, measured in metres per second."
        let r = try await h.run(CommandIDs.inkWriteText, ["page": .string(page2), "text": .string(text), "at": [72, 96]])
        XCTAssertGreaterThan(r["lines"]?.intValue ?? 0, 1)
        let box = try XCTUnwrap(inkBox(try items(h)))
        XCTAssertLessThanOrEqual(box.maxX, PageSize.a4.width - InkSynthParams.pageMargin + 0.01)
    }

    func testWriteTextRejectsBadParamsWithoutTouchingTheDocument() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        let base: [String: JSONValue] = ["page": .string(page2), "text": "Hi", "at": [72, 96]]
        func with(_ key: String, _ value: JSONValue) -> JSONValue {
            var o = base
            o[key] = value
            return .object(o)
        }
        let command = CommandIDs.inkWriteText
        await assertError(h, command, with("text", "   "), .invalidParams)
        await assertError(h, command, with("at", [72]), .invalidParams)
        await assertError(h, command, with("font", "Comic Sans"), .invalidParams)
        await assertError(h, command, with("color", "blue"), .invalidParams)
        await assertError(h, command, with("size", 1), .invalidParams)
        await assertError(h, command, with("slant", 80), .invalidParams)
        await assertError(h, command, with("ids", ["not an id!"]), .invalidParams)
        await assertError(h, command, with("ids", ["TWICE", "TWICE"]), .invalidParams)
        await assertError(h, command, with("page", "doc:FIXTUREDOC01"), .invalidParams)
        await assertError(h, command, with("page", "page:FIXTUREDOC01/NOSUCHPAGE01"), .notFound)
        // An id already used on the page is refused instead of overwriting that item.
        await assertError(h, command, ["page": .string(page1), "text": "Hi", "at": [72, 96], "ids": ["FIXTURESTK01"]],
                          .invalidParams)
        // The AI gets the schema check first.
        do {
            _ = try await h.run(command, with("font", "Comic Sans"), as: .ai("chat"))
            XCTFail("schema check skipped")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertTrue(try items(h).isEmpty)
    }

    // MARK: handwriting.replaceWord

    func testReplaceWordMatchesPenColourLayerAndPlacementAsOneUndoStep() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        let style = InkStyle(tool: .pen, pen: .ball, color: RGBA(0xD1, 0x3B, 0x2F), width: 1.6)
        let old = seedWord(h, "hello", style: style)
        let before = try h.snapshot()
        let oldBox = try XCTUnwrap(inkBox(old))
        let oldRefs = old.map { JSONValue.string(ref(Fixtures.page2, $0.id)) }

        let r = try await h.run("handwriting.replaceWord", ["refs": .array(oldRefs), "text": "halls", "ids": ["NEWWORD1"]])
        let refs = strings(r["refs"])
        XCTAssertEqual(refs.first, ref(Fixtures.page2, "NEWWORD1"))
        let now = try items(h)
        XCTAssertEqual(Set(now.map { ref(Fixtures.page2, $0.id) }), Set(refs), "the old strokes are gone")
        for item in now {
            XCTAssertEqual(item.stroke?.style, style, "same pen, colour and width")
            XCTAssertEqual(item.layer, 1, "same layer")
        }
        let box = try XCTUnwrap(inkBox(now))
        XCTAssertEqual(box.minX, oldBox.minX, accuracy: 0.05, "starts where the word started")
        XCTAssertEqual(box.height, oldBox.height, accuracy: oldBox.height * 0.2, "same size")
        XCTAssertEqual(box.maxY, oldBox.maxY, accuracy: oldBox.height * 0.1, "same baseline")

        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try items(h).count, refs.count)
    }

    func testReplaceWordUsesTheRecognisedWordForItsSizeAndBaseline() async throws {
        let h = Harness(features: [FeatInkSynthFeature.self])
        // A stand-in for recognize.items (F055): the old strokes read "hello", which has no descender, so "help"
        // keeps hello's size and baseline and its "p" hangs below the old word.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizeItems, title: "Recognise",
                                                  summary: "Test recogniser.", effect: .read)) { _, _ in ["text": "hello"] }
        let old = seedWord(h, "hello", style: InkStyle())
        let oldBox = try XCTUnwrap(inkBox(old))
        let oldRefs = old.map { JSONValue.string(ref(Fixtures.page2, $0.id)) }

        try await h.run("handwriting.replaceWord", ["refs": .array(oldRefs), "text": "help"])
        let box = try XCTUnwrap(inkBox(try items(h)))
        XCTAssertEqual(box.minY, oldBox.minY, accuracy: oldBox.height * 0.12, "same ascender height")
        XCTAssertGreaterThan(box.maxY, oldBox.maxY + oldBox.height * 0.1, "the descender hangs below the old baseline")
    }

    func testReplaceWordRejectsWhatIsNotHandwriting() async {
        let h = Harness(features: [FeatInkSynthFeature.self])
        let command = "handwriting.replaceWord"
        let stroke = JSONValue.string(ref(Fixtures.page1, Fixtures.strokeID))
        await assertError(h, command, ["refs": [], "text": "word"], .invalidParams)
        await assertError(h, command, ["refs": [.string(ref(Fixtures.page1, Fixtures.textID))], "text": "word"], .invalidParams)
        await assertError(h, command, ["refs": [.string(ref(Fixtures.page1, Fixtures.tapeID))], "text": "word"], .invalidParams)
        await assertError(h, command, ["refs": [stroke], "text": "  "], .invalidParams)
        await assertError(h, command, ["refs": [.string(page1)], "text": "word"], .invalidParams)
        await assertError(h, command, ["refs": [.string(ref(Fixtures.page1, "NOSUCHITEM01"))], "text": "word"], .notFound)
        await assertError(h, command, ["refs": [stroke], "text": "word", "ids": ["FIXTURESHP01"]], .invalidParams)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }
}
