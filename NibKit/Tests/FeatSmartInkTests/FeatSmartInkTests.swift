import XCTest
import NibContracts
import NibTesting
@testable import FeatSmartInk

@MainActor
final class FeatSmartInkTests: XCTestCase {
    // MARK: Helpers

    private let doc = Fixtures.docID
    private let page = Fixtures.page2

    /// Puts synthetic handwriting on the empty fixture page (before anything loads it); returns its item refs.
    private func install(_ s: Synth, in h: Harness) -> [String] {
        h.persistence.pageItems[doc, default: [:]][page] = items(s)
        return s.ids.map { ref($0) }
    }

    private func items(_ s: Synth) -> [Item] {
        let z = FractionalIndex.sequence(after: nil, count: s.strokes.count)
        var out: [Item] = []
        for (i, stroke) in s.strokes.enumerated() {
            let points = stroke.points.map { StrokePoint(x: Float($0.x), y: Float($0.y)) }
            out.append(Item(id: stroke.id, kind: .stroke, z: z[i],
                            stroke: Stroke(style: .defaultPen, points: points, t0: 1_700_000_000)))
        }
        return out
    }

    private func ref(_ id: ElementID) -> String { NodeRef.item(doc, page, id).description }
    private func json(_ refs: [String]) -> JSONValue { .array(refs.map { .string($0) }) }

    private func strokePoints(_ h: Harness) throws -> [ElementID: [Point]] {
        var out: [ElementID: [Point]] = [:]
        for item in try h.app.workspace.items(doc, page: page) { out[item.id] = item.stroke?.polyline }
        return out
    }

    private func lines(_ h: Harness, _ refs: [String]) async throws -> [JSONValue] {
        try await h.run("handwriting.words", ["refs": json(refs)])["lines"]?.arrayValue ?? []
    }

    private func errorCode(_ body: () async throws -> Void) async -> NibError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? NibError)?.code
        }
    }

    // MARK: Registration and conformance

    /// Every `.edit` example passes the undo round trip over all fixture documents (CI's ConformanceTests run on main).
    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatSmartInkFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsToolAndSetting() {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let owned = Set(h.app.commands.all().filter { $0.owner == FeatSmartInkFeature.id }.map { $0.id })
        XCTAssertEqual(owned, ["handwriting.words", "handwriting.reflow", "handwriting.straighten", "handwriting.align",
                               "handwriting.insertSpace"])
        XCTAssertEqual(h.app.commands.descriptor("handwriting.words")?.effect, .read)
        XCTAssertNotNil(h.app.ui.canvasTools.get(FeatSmartInkFeature.toolID))
        XCTAssertNotNil(h.app.ui.toolMenus.get(FeatSmartInkFeature.toolID))
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("smartink.overlay"))
        XCTAssertNotNil(h.app.settings.descriptor(FeatSmartInkFeature.autoStraighten.name))
    }

    func testMenusRunSmartInkCommands() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID])
        let ctx = MenuContext(app: h.app, session: h.session, doc: doc, page: Fixtures.page1, selection: selection,
                              itemKinds: [.stroke])
        let object = h.app.ui.menuItems(.objectMenu, ctx)
        let edit = object.first { $0.id == "smartink.editHandwriting" }
        XCTAssertEqual(edit?.command, CommandIDs.toolSelect)
        let tool: JSONValue = ["tool": "smartink.edit"]
        XCTAssertEqual(edit?.params(ctx), tool)
        let straighten = object.first { $0.id == "smartink.straighten" }
        let refs: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"]]
        XCTAssertEqual(straighten?.params(ctx), refs)

        let pageCtx = MenuContext(app: h.app, session: h.session, doc: doc, page: Fixtures.page1, point: Point(100, 300))
        let insert = try XCTUnwrap(h.app.ui.menuItems(.pageLongPress, pageCtx).first { $0.id == "smartink.insertSpace" })
        let out = try await h.run(insert.command, insert.params(pageCtx))
        XCTAssertEqual(out["moved"]?.intValue, 6)

        h.session.readOnly = true
        XCTAssertTrue(h.app.ui.menuItems(.objectMenu, ctx).filter { $0.owner == FeatSmartInkFeature.id }.isEmpty)
        XCTAssertTrue(h.app.ui.menuItems(.pageLongPress, pageCtx).filter { $0.owner == FeatSmartInkFeature.id }.isEmpty)
    }

    // MARK: Commands

    /// Acceptance at the command level: the 3-line paragraph reflows to 5 lines at half width, in reading order, by
    /// translating strokes only, as one undo step.
    func testReflowToHalfWidthIsOneUndoableTranslation() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let s = Synth.paragraph()
        let refs = install(s, in: h)
        let before = try h.snapshot()
        let original = try strokePoints(h)
        let lines3 = try await lines(h, refs)
        XCTAssertEqual(lines3.count, 3)
        XCTAssertEqual(lines3.first?["words"]?.arrayValue?.count, 4)

        let out = try await h.run("handwriting.reflow", ["refs": json(refs), "width": 77])
        XCTAssertEqual(out["lines"]?.intValue, 5)
        XCTAssertEqual(out["moved"]?.intValue, 23)   // the first two words stay put

        let lines5 = try await lines(h, refs)
        XCTAssertEqual(lines5.count, 5)
        let order: [[String]] = lines5.flatMap { line in
            (line["words"]?.arrayValue ?? []).map { word in (word["refs"]?.arrayValue ?? []).compactMap { $0.stringValue } }
        }
        XCTAssertEqual(order, s.words.map { $0.map { ref($0) } })

        let moved = try strokePoints(h)
        for (id, points) in original {
            guard let now = moved[id], let a = points.first, let b = now.first else {
                XCTFail("stroke \(id) is gone")
                continue
            }
            XCTAssertEqual(now.count, points.count)
            for (p, q) in zip(points, now) {
                XCTAssertEqual(q.x - p.x, b.x - a.x, accuracy: 1e-3)
                XCTAssertEqual(q.y - p.y, b.y - a.y, accuracy: 1e-3)
            }
        }

        XCTAssertEqual(h.undoDepth(doc), 1)
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testStraightenLevelsASlantedLineAndUndoes() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        s.line([3, 4, 3, 2, 4, 3], y: 200, tilt: tan(6 * .pi / 180))
        let refs = install(s, in: h)
        let before = try h.snapshot()
        let slanted = try await lines(h, refs).first?["angle"]?.doubleValue ?? 0
        XCTAssertEqual(slanted, 6, accuracy: 0.75)

        // Lines flatter than minAngle stay as written.
        let skipped = try await h.run("handwriting.straighten", ["refs": json(refs), "minAngle": 10])
        XCTAssertEqual(skipped["straightened"]?.intValue, 0)
        XCTAssertEqual(h.undoDepth(doc), 0)

        let out = try await h.run("handwriting.straighten", ["refs": json(refs)])
        XCTAssertEqual(out["straightened"]?.intValue, 1)
        let level = try await lines(h, refs).first?["angle"]?.doubleValue ?? 99
        XCTAssertLessThan(abs(level), 0.75)
        XCTAssertEqual(h.undoDepth(doc), 1)
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testAlignRightLinesUpTheRightEdges() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        s.line([3, 3], y: 100)
        s.line([3, 3, 3], y: 130)
        let refs = install(s, in: h)
        let before = try h.snapshot()
        let out = try await h.run("handwriting.align", ["refs": json(refs), "align": "right"])
        XCTAssertEqual(out["moved"]?.intValue, 6)
        let right = try await lines(h, refs).map { line -> Double in
            (line["bbox"]?[0]?.doubleValue ?? 0) + (line["bbox"]?[2]?.doubleValue ?? 0)
        }
        XCTAssertEqual(right.count, 2)
        XCTAssertEqual(right[0], right[1], accuracy: 0.11)
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)

        // "center" is accepted as well as "centre".
        let centred = try await h.run("handwriting.align", ["refs": json(refs), "align": "center"])
        XCTAssertEqual(centred["moved"]?.intValue, 6)
    }

    func testInsertSpacePushesItemsBelowDownAndUndoes() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let before = try h.snapshot()
        let out = try await h.run("handwriting.insertSpace",
                                  ["page": "page:FIXTUREDOC01/FIXTUREPG001", "y": 300, "height": 40])
        XCTAssertEqual(out["moved"]?.intValue, 6)
        let text = try h.app.workspace.item(doc, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertEqual(text.text?.frame.y ?? 0, 440, accuracy: 1e-9)
        let stroke = try h.app.workspace.item(doc, page: Fixtures.page1, id: Fixtures.strokeID)
        XCTAssertEqual(stroke.stroke?.points.first?.y, 120)
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testRecognisedWordsRefineTheWordsResult() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        s.line([1], y: 100)
        s.line([1], x: 88, y: 100)   // 8 pt apart: two words by geometry alone
        let refs = install(s, in: h)
        let apart = try await lines(h, refs).first?["words"]?.arrayValue?.count
        XCTAssertEqual(apart, 2)

        h.app.services.recognizer = FakeRecognizer([TextRecognition(text: "it", bbox: Rect(x: 72, y: 95, width: 24, height: 10),
                                                                    itemIDs: s.ids, source: "ink")])
        let out = try await h.run("handwriting.words", ["refs": json(refs)])
        let words = out["lines"]?[0]?["words"]?.arrayValue ?? []
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words.first?["text"]?.stringValue, "it")
        XCTAssertEqual(out["text"]?.stringValue, "it")
    }

    func testInvalidParamsAreReported() async {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let stroke = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"
        var code = await errorCode { _ = try await h.run("handwriting.align", ["refs": [.string(stroke)], "align": "middle"]) }
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode { _ = try await h.run("handwriting.reflow", ["refs": ["page:FIXTUREDOC01/FIXTUREPG001"], "width": 100]) }
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode {
            _ = try await h.run("handwriting.reflow", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"], "width": 100])
        }
        XCTAssertEqual(code, .invalidParams)   // a text box is not handwriting
        code = await errorCode { _ = try await h.run("handwriting.straighten", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/NOSUCHITEM01"]]) }
        XCTAssertEqual(code, .notFound)
        code = await errorCode { _ = try await h.run("handwriting.insertSpace", ["page": "doc:FIXTUREDOC01", "y": 1, "height": 1]) }
        XCTAssertEqual(code, .invalidParams)
    }

    // MARK: Edit Handwriting mode

    func testEditModeDoubleTapSelectsAWord() throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let s = Synth.paragraph()
        _ = install(s, in: h)
        h.session.page = page
        h.session.selection = Selection(doc: doc, page: page, items: s.ids)
        let host = FakeCanvasHost(h)
        let tool = EditHandwritingTool()
        tool.activate(host)

        let model = EditHandwritingModel.of(h.session)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.target?.ids.count, s.ids.count)
        XCTAssertEqual(model.layout.lines.count, 3)
        XCTAssertTrue(h.session.selection.isEmpty, "the mode shows its own frame instead of the lasso's")

        let word = model.layout.lines[1].words[2]
        model.tap(at: word.box.center, page: page, time: 100)
        XCTAssertEqual(model.selectedWord, [], "a single tap does not select")
        model.tap(at: word.box.center, page: page, time: 100.2)
        XCTAssertEqual(model.selectedWord, word.ids)
        model.stepWord(1)
        XCTAssertEqual(model.selectedWord, model.layout.lines[1].words[3].ids)
        model.tap(at: model.layout.lines[0].words[0].box.center, page: page, time: 105)
        XCTAssertEqual(model.selectedWord, [], "a single tap elsewhere in the block clears the word")

        model.previewReflow(left: model.layout.box.minX, width: model.layout.box.width / 2)
        XCTAssertEqual(model.preview?.width ?? 0, 77, accuracy: 1e-9)
        XCTAssertFalse(model.preview?.moves.isEmpty ?? true)
        model.cancelPreview()

        tool.deactivate(host)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.target)
    }

    // MARK: Line Straightening as you write

    func testAutoStraightenLevelsABurstAfterThePause() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        s.line([3, 4, 3, 2, 4, 3], y: 200, tilt: tan(6 * .pi / 180))
        let written = items(s)
        let doc = self.doc, page = self.page
        // Stand-in for F007's ink.addStrokes, which the canvas commits every finished stroke through.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.inkAddStrokes, title: "Add Strokes",
                                                  summary: "Test stand-in.", effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                for item in written { try tx.put(item, doc: doc, page: page) }
            }
            return [:]
        }
        await FeatSmartInkFeature.start(h.app)
        try await h.run(CommandIDs.settingsSet, ["name": "smartink.autoStraighten", "value": true])
        try await h.run(CommandIDs.inkAddStrokes)
        XCTAssertEqual(h.undoDepth(doc), 1)

        let deadline = Date().addingTimeInterval(8)
        while h.undoDepth(doc) < 2, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(h.undoDepth(doc), 2, "the burst is straightened as its own undo step")
        let refs = s.ids.map { ref($0) }
        let angle = try await lines(h, refs).first?["angle"]?.doubleValue ?? 99
        XCTAssertLessThan(abs(angle), 0.75)
    }
}
