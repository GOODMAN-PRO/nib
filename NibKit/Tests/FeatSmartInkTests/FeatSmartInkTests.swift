import XCTest
import NibContracts
import NibTesting
@testable import FeatSmartInk

@MainActor
final class FeatSmartInkTests: XCTestCase {
    // MARK: Helpers

    private let doc = Fixtures.docID
    private let page = Fixtures.page2

    /// Puts synthetic handwriting on the empty fixture page (contracts-v2 `Harness.insert`), then clears the undo
    /// history so each test counts only its own steps; returns the item refs.
    private func install(_ s: Synth, in h: Harness) async throws -> [String] {
        try await h.insert(items(s), page: page, doc: doc)
        h.app.bus.history.clear(doc)
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

    /// Page strokes as the layout sees them.
    private func layout(_ h: Harness) throws -> InkLayout {
        let items = try h.app.workspace.items(doc, page: page)
        return InkLayout.analyze(items.compactMap { InkGlyph(item: $0) })
    }

    /// Stand-in for item.delete (another feature's command), which Delete Word runs.
    private func installItemDelete(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.itemDelete, title: "Delete",
                                                  summary: "Test stand-in.", effect: .edit)) { params, ctx in
            try ctx.mutate { tx in
                for value in params["refs"]?.arrayValue ?? [] {
                    guard let s = value.stringValue, case let .item(d, p, id)? = NodeRef(s) else { continue }
                    try tx.delete(item: id, doc: d, page: p)
                }
            }
            return [:]
        }
    }

    /// The mode on the synthetic paragraph, laid out and ready.
    private func editMode(_ h: Harness, _ s: Synth) async throws -> (EditHandwritingModel, EditHandwritingTool, FakeCanvasHost) {
        _ = try await install(s, in: h)
        h.session.page = page
        h.session.selection = Selection(doc: doc, page: page, items: s.ids)
        let host = FakeCanvasHost(h)
        let tool = EditHandwritingTool()
        tool.activate(host)
        let model = EditHandwritingModel.of(h.session)
        await model.reload()
        return (model, tool, host)
    }

    /// No two words of a line overlap.
    private func assertNoOverlaps(_ layout: InkLayout, file: StaticString = #filePath, line: UInt = #line) {
        for l in layout.lines {
            for (a, b) in zip(l.words, l.words.dropFirst()) {
                XCTAssertGreaterThan(b.box.minX, a.box.maxX, "words overlap", file: file, line: line)
            }
        }
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
        let tool: JSONValue = ["tool": "smartink.edit", "temporary": true]
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
        let refs = try await install(s, in: h)
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
        let refs = try await install(s, in: h)
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
        let refs = try await install(s, in: h)
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
        XCTAssertEqual(out["height"]?.doubleValue, 40)
        XCTAssertEqual(out["offPage"]?.intValue, 0)
        let text = try h.app.workspace.item(doc, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertEqual(text.text?.frame.y ?? 0, 440, accuracy: 1e-9)
        let stroke = try h.app.workspace.item(doc, page: Fixtures.page1, id: Fixtures.strokeID)
        XCTAssertEqual(stroke.stroke?.points.first?.y, 120)
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)

        // Pushing the fixture's custom box (top 700) past the bottom of the A4 page is reported.
        let far = try await h.run("handwriting.insertSpace", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "y": 300, "height": 200])
        XCTAssertEqual(far["offPage"]?.intValue, 1)
        // Closing more space than there is stops at the shape above y.
        h.app.bus.undo(doc)
        let shapeBottom = try h.app.workspace.item(doc, page: Fixtures.page1, id: Fixtures.shapeID).bounds.maxY
        let closed = try await h.run("handwriting.insertSpace", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "y": 300, "height": -100])
        XCTAssertEqual(closed["height"]?.doubleValue ?? 0, Handwriting.rounded(shapeBottom - 300), accuracy: 0.051)
    }

    func testRecognisedWordsRefineTheWordsResult() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        s.line([1], y: 100)
        s.line([1], x: 88, y: 100)   // 8 pt apart: two words by geometry alone
        let refs = try await install(s, in: h)
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

    func testInvalidParamsAreReported() async throws {
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
        // Trust boundary: coordinates beyond the ink limit never reach the strokes.
        code = await errorCode { _ = try await h.run("handwriting.reflow", ["refs": [.string(stroke)], "width": 100, "left": 1e22]) }
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode { _ = try await h.run("handwriting.reflow", ["refs": [.string(stroke)], "width": 100, "left": -100_001]) }
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode { _ = try await h.run("handwriting.straighten", ["refs": [.string(stroke)], "pivot": "middle"]) }
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode { _ = try await h.run("handwriting.reflow", ["refs": [.string(stroke)], "width": 100, "without": ["page:FIXTUREDOC01/FIXTUREPG001"]]) }
        XCTAssertEqual(code, .invalidParams)
        // Inserted strokes must share a page with refs, and `after` must be one of refs.
        let s = Synth.paragraph()
        let refs = try await install(s, in: h)
        code = await errorCode { _ = try await h.run("handwriting.reflow", ["refs": json(refs), "width": 100, "insert": [.string(stroke)]]) }
        XCTAssertEqual(code, .invalidParams)
        code = await errorCode {
            _ = try await h.run("handwriting.reflow", ["refs": json(Array(refs.dropLast(2))), "width": 100,
                                                       "insert": json(Array(refs.suffix(2))), "after": .string(refs[refs.count - 1])])
        }
        XCTAssertEqual(code, .invalidParams)
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    /// The mode sends a page x for the column's left edge; for a slanted paragraph the command must land the column
    /// exactly there (the page-x round trip the side handles rely on).
    func testReflowOfASlantedParagraphLandsOnTheRequestedLeft() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        let tilt = tan(6 * Double.pi / 180)
        s.line([3, 3, 2, 4, 3], y: 100, tilt: tilt)
        s.line([2, 4, 3, 3, 2], y: 130, tilt: tilt)
        s.line([3, 2, 4], y: 160, tilt: tilt)
        let refs = try await install(s, in: h)
        let before = try layout(h)
        XCTAssertEqual(before.skew * 180 / .pi, 6, accuracy: 0.75)
        let requested = before.pageLeft + 30
        let out = try await h.run("handwriting.reflow", ["refs": json(refs), "width": .number(before.box.width * 0.6),
                                                         "left": .number(requested)])
        XCTAssertGreaterThan(out["lines"]?.intValue ?? 0, 3)
        let after = try layout(h)
        XCTAssertEqual(after.pageLeft, requested, accuracy: 0.5)
        XCTAssertEqual(after.words.map { $0.ids }, s.words)
        XCTAssertEqual(h.undoDepth(doc), 1)
    }

    /// Two side-by-side columns on one page reflow separately through the command, one undo step.
    func testReflowKeepsSideBySideColumnsApart() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        for y in [100.0, 130, 160] { s.line([3, 3, 2, 4], y: y) }
        let leftCount = s.words.count
        for y in [100.0, 130, 160] { s.line([2, 4, 3, 3], x: 400, y: y) }
        let refs = try await install(s, in: h)
        // Each column: 12 words of 28/28/18/38 (left) or 18/38/28/28 (right) pt, two to a 77 pt line.
        let out = try await h.run("handwriting.reflow", ["refs": json(refs), "width": 77])
        XCTAssertEqual(out["lines"]?.intValue, 12)
        let after = try layout(h)
        XCTAssertEqual(after.columns.count, 2)
        XCTAssertEqual(after.words.map { $0.ids }, s.words)
        XCTAssertEqual(Set(after.ids(ofColumn: 1)), Set(s.words[leftCount...].flatMap { $0 }))
        let words = try await lines(h, refs)
        XCTAssertEqual(words.compactMap { $0["column"]?.intValue }, Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6))
        XCTAssertEqual(h.undoDepth(doc), 1)
    }

    // MARK: Edit Handwriting mode

    func testEditModeDoubleTapSelectsAWord() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        let s = Synth.paragraph()
        let (model, tool, host) = try await editMode(h, s)
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

    /// Delete Word on the first word of a line: the column flows on at its width as if the word were gone (no false
    /// indent), then the word is deleted. One undo step that restores everything.
    func testEditModeDeleteClosesTheHoleAndReflows() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        installItemDelete(h)
        let s = Synth.paragraph()
        let (model, tool, host) = try await editMode(h, s)
        let before = try h.snapshot()
        let word = model.layout.lines[1].words[0]
        model.tap(at: word.box.center, page: page, time: 100)
        model.tap(at: word.box.center, page: page, time: 100.2)
        XCTAssertEqual(model.selectedWord, s.words[4])

        await model.deleteWord()
        let after = try layout(h)
        var expected = s.words
        expected.remove(at: 4)
        XCTAssertEqual(after.words.map { $0.ids }, expected)
        XCTAssertEqual(after.lines.map { $0.startsParagraph }, [true, false, false], "no false paragraph break")
        for line in after.lines { XCTAssertEqual(line.box.minX, 72, accuracy: 0.01) }
        XCTAssertLessThanOrEqual(after.box.width, 154.5)
        assertNoOverlaps(after)
        XCTAssertEqual(h.undoDepth(doc), 1, "reflow and delete are one undo step")
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)
        tool.deactivate(host)
    }

    /// Paste After Word on a mid-line word: the clipboard's handwriting (two lines) flows in as one run right after
    /// the word and the column reflows: reading order word, pasted, next word, and no word boxes overlap. One undo
    /// step restores the page (the pasted strokes are created and then moved in that step).
    func testEditModePastesAfterAMidLineWord() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        // The clipboard: "ab" over "cde", as a stand-in for F014's clipboard.paste (centred at `at`).
        var clip = Synth()
        clip.line([2], x: 0, y: 0)
        clip.line([3], x: 0, y: 30)
        let clipItems = items(clip).map { Item(id: NibID("PASTED" + $0.id.raw), kind: .stroke, stroke: $0.stroke) }
        let doc = self.doc
        h.app.commands.register(CommandDescriptor(id: CommandIDs.clipboardPaste, title: "Paste",
                                                  summary: "Test stand-in.", effect: .edit)) { params, ctx in
            guard let pageRef = params["page"]?.stringValue, case let .page(d, p)? = NodeRef(pageRef), d == doc,
                  let at = params["at"]?.arrayValue?.compactMap({ $0.doubleValue }), at.count == 2 else { return [:] }
            let bounds = InkLayout.union(clipItems.map { $0.bounds })
            let shift = Affine.translation(at[0] - bounds.midX, at[1] - bounds.midY)
            try ctx.mutate { tx in
                for item in clipItems { try tx.put(item.transformed(by: shift), doc: d, page: p) }
            }
            return ["refs": .array(clipItems.map { .string(NodeRef.item(d, p, $0.id).description) })]
        }
        let s = Synth.paragraph()
        let (model, tool, host) = try await editMode(h, s)
        let before = try h.snapshot()
        let anchor = model.layout.lines[0].words[1]
        model.tap(at: anchor.box.center, page: page, time: 100)
        model.tap(at: anchor.box.center, page: page, time: 100.2)
        XCTAssertEqual(model.selectedWord, s.words[1])

        await model.paste()
        let after = try layout(h)
        let pasted = clipItems.map { $0.id }
        var expected = s.words
        expected.insert(contentsOf: [[pasted[0], pasted[1]], [pasted[2], pasted[3], pasted[4]]], at: 2)
        XCTAssertEqual(after.words.map { $0.ids }, expected, "anchor, pasted words, next word")
        assertNoOverlaps(after)
        XCTAssertEqual(after.lines.count, 3)
        XCTAssertEqual(after.skew, 0)
        for line in after.lines { XCTAssertEqual(line.box.minX, 72, accuracy: 0.01) }
        XCTAssertLessThanOrEqual(after.box.width, 154.5)
        XCTAssertEqual(Set(model.target?.ids ?? []), Set(s.ids + pasted), "the pasted words are edited too")
        XCTAssertEqual(h.undoDepth(doc), 1, "paste and reflow are one undo step")
        h.app.bus.undo(doc)
        XCTAssertEqual(try h.snapshot(), before)
        tool.deactivate(host)
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

    /// Nothing is straightened while the Pencil is down, bursts on two pages are both kept, and each line is levelled
    /// about its left end (so a line continued after a pause meets the part already levelled).
    func testAutoStraightenWaitsForThePencilAndKeepsEveryBurst() async throws {
        let h = Harness(features: [FeatSmartInkFeature.self])
        var s = Synth()
        s.line([3, 4, 3, 2, 4, 3], y: 200, tilt: tan(6 * Double.pi / 180))
        var t = Synth()
        t.line([3, 4, 3, 2, 4, 3], y: 300, tilt: tan(-6 * Double.pi / 180))
        let onPage2 = items(s)
        let onPage1 = items(t).map { item in Item(id: NibID("P1" + item.id.raw), kind: .stroke, stroke: item.stroke) }
        let doc = self.doc, page = self.page
        var next = [(page, onPage2), (Fixtures.page1, onPage1)]
        h.app.commands.register(CommandDescriptor(id: CommandIDs.inkAddStrokes, title: "Add Strokes",
                                                  summary: "Test stand-in.", effect: .edit)) { _, ctx in
            let (p, written) = next.removeFirst()
            try ctx.mutate { tx in
                for item in written { try tx.put(item, doc: doc, page: p) }
            }
            return [:]
        }
        let straightener = AutoStraightener(app: h.app)
        straightener.start()
        try await h.run(CommandIDs.settingsSet, ["name": "smartink.autoStraighten", "value": true])
        try await h.run(CommandIDs.inkAddStrokes)
        try await h.run(CommandIDs.inkAddStrokes)
        XCTAssertEqual(straightener.bursts.map { $0.page }, [page, Fixtures.page1], "a new page keeps the first burst")

        h.session.inking.begin()
        straightener.flush()
        XCTAssertEqual(straightener.bursts.count, 2, "nothing moves while the Pencil is down")
        XCTAssertEqual(h.undoDepth(doc), 2)

        h.session.inking.end()
        let leftEnd = try XCTUnwrap(h.app.workspace.item(doc, page: page, id: s.ids[0]).stroke?.polyline.first)
        straightener.flush()
        XCTAssertTrue(straightener.bursts.isEmpty)
        let deadline = Date().addingTimeInterval(8)
        while h.undoDepth(doc) < 4, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(h.undoDepth(doc), 4, "each burst is its own undo step")
        let angle = try await lines(h, s.ids.map { ref($0) }).first?["angle"]?.doubleValue ?? 99
        XCTAssertLessThan(abs(angle), 0.75)
        let levelled = try XCTUnwrap(h.app.workspace.item(doc, page: page, id: s.ids[0]).stroke?.polyline.first)
        XCTAssertEqual(levelled.y, leftEnd.y, accuracy: 1.5, "levelled about the left end")
    }
}
