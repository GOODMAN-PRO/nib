import XCTest
import NibContracts
import NibTesting
@testable import FeatHighlighter

@MainActor
final class FeatHighlighterTests: XCTestCase {
    private func points(_ xy: [(Float, Float)]) -> [StrokePoint] {
        xy.enumerated().map { i, p in StrokePoint(x: p.0, y: p.1, t: Float(i) * 0.01, width: 12, height: 12) }
    }

    /// A wobbly pass whose best-fit line is y = 100 (the wobble is symmetric about the middle).
    private var wobbly: [StrokePoint] {
        points([(10, 100), (30, 102), (50, 98), (70, 98), (90, 102), (110, 100)])
    }

    // MARK: Draw in Straight Line

    func testStraightLineIsTwoPointsWithTheEndpointsPreserved() {
        let out = HighlighterGeometry.straightened(wobbly)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].x, 10, accuracy: 0.001)
        XCTAssertEqual(out[0].y, 100, accuracy: 0.001)
        XCTAssertEqual(out[1].x, 110, accuracy: 0.001)
        XCTAssertEqual(out[1].y, 100, accuracy: 0.001)
        XCTAssertEqual(out[0].t, wobbly[0].t)
        XCTAssertEqual(out[1].t, wobbly[5].t)
        // Sizes are left for InkModel.prepare to densify and derive from the style width.
        XCTAssertTrue(out.allSatisfy { $0.width == 0 && $0.height == 0 })
    }

    func testStraightLineKeepsTheDirectionAndSlantItWasDrawnIn() {
        let slant = points([(30, 40), (21, 28), (9, 12), (3, 4), (0, 0)])       // drawn from (30, 40) to the origin
        let out = HighlighterGeometry.straightened(slant)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].x, 30, accuracy: 0.001)
        XCTAssertEqual(out[0].y, 40, accuracy: 0.001)
        XCTAssertEqual(out[1].x, 0, accuracy: 0.001)
        XCTAssertEqual(out[1].y, 0, accuracy: 0.001)
    }

    func testStraightLineProcessorRunsOnlyForHighlighterStrokesWhenTheSettingIsOn() async throws {
        let h = Harness(features: [FeatHighlighterFeature.self])
        let processor = StraightLineProcessor(settings: h.app.settings)
        var stroke = Stroke(style: .defaultHighlighter, points: wobbly, t0: 0)
        XCTAssertTrue(processor.process(&stroke, page: Fixtures.page1, session: h.session))
        XCTAssertEqual(stroke.points.count, wobbly.count, "off by default")

        try await h.run(CommandIDs.settingsSet, ["name": "highlighter.straightLine", "value": true])
        XCTAssertTrue(processor.process(&stroke, page: Fixtures.page1, session: h.session))
        XCTAssertEqual(stroke.points.count, 2)
        XCTAssertEqual(stroke.style, .defaultHighlighter, "width and colour are kept")

        var pen = Stroke(style: .defaultPen, points: wobbly, t0: 0)
        XCTAssertTrue(processor.process(&pen, page: Fixtures.page1, session: h.session))
        XCTAssertEqual(pen.points, wobbly)
    }

    // MARK: Stroke Stabilization

    func testStabilizationSmoothsAndKeepsEndpoints() {
        let zigzag = points((0..<21).map { i -> (Float, Float) in (Float(i * 5), i % 2 == 0 ? 100 : 106) })
        let out = HighlighterGeometry.stabilized(zigzag, amount: 0.8)
        XCTAssertEqual(out.first, zigzag.first)
        XCTAssertEqual(out.last, zigzag.last)
        XCTAssertEqual(out.map(\.x), zigzag.map(\.x))
        func roughness(_ p: [StrokePoint]) -> Float { zip(p, p.dropFirst()).map { abs($1.y - $0.y) }.reduce(0, +) }
        XCTAssertLessThan(roughness(out), roughness(zigzag) * 0.5)
        XCTAssertEqual(HighlighterGeometry.stabilized(zigzag, amount: 0), zigzag)
    }

    // MARK: Registration

    func testRegistersTheToolInTheWritingToolsGroupWithProcessorsAndSettings() {
        let h = Harness(features: [FeatHighlighterFeature.self])
        let item = h.app.ui.toolbar.get("highlighter")
        XCTAssertEqual(item?.group, .tools)
        XCTAssertEqual(item?.toolID, "highlighter")
        XCTAssertEqual(item?.shortcut, KeyShortcut("h"))
        XCTAssertNotNil(item?.settings)
        XCTAssertTrue(h.app.ui.toolbarItems(for: .notebook).contains { $0.id == "highlighter" })
        XCTAssertTrue(h.app.ui.toolbarItems(for: .whiteboard).contains { $0.id == "highlighter" })

        let tool = h.app.ui.canvasTools.get("highlighter")?.make()
        XCTAssertEqual(tool?.inputMode, .pencilKit)
        let style = tool?.inkStyle(FakeCanvasHost(h))
        let presets = ToolPresets.defaults(for: "highlighter")
        XCTAssertEqual(style?.tool, .highlighter)
        XCTAssertEqual(style?.color, presets.color)
        XCTAssertEqual(style?.width, presets.width)

        XCTAssertEqual(h.app.content.strokeProcessors.all.map(\.id), ["highlighter.stabilize", "highlighter.straight"])
        for name in ["highlighter.straightLine", "highlighter.stabilization", "highlighter.drawAndHold"] {
            XCTAssertEqual(h.app.settings.descriptor(name)?.owner, "highlighter", name)
        }
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatHighlighterFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Presets

    func testThicknessSelectsAMatchingSlotOrResizesTheSelectedOne() {
        let p = ToolPresets.defaults(for: "highlighter")                       // widths 8, 12, 18; slot 1 selected
        XCTAssertNil(PresetEdit.width(12, in: p))
        XCTAssertEqual(PresetEdit.width(8, in: p), .selectWidth(0))
        XCTAssertEqual(PresetEdit.width(14.04, in: p), .setWidth(index: 1, width: 14))
        var q = p
        PresetEdit.setWidth(index: 1, width: 14).apply(to: &q)
        XCTAssertEqual(q.widths, [8, 14, 18])
        let mint = PresetEdit.setColour(index: 0, color: NibHighlighter.mint.rgba)
        XCTAssertEqual(mint.command, "preset.setSwatch")
        XCTAssertEqual(mint.params["color"]?.stringValue, "#86E3AE80")
    }

    // MARK: Draw and Hold

    func testRecognitionResultDecodesBareAndWrappedShapes() throws {
        let bare = try JSONValue.parse(#"{"shape":"rectangle","frame":{"x":1,"y":2,"w":3,"h":4}}"#)
        XCTAssertEqual(HeldShape.decode(bare)?.shape, .rectangle)
        let wrapped = try JSONValue.parse(#"{"shape":{"shape":"line","points":[[0,0],[10,0]]},"mergeWith":[]}"#)
        XCTAssertEqual(HeldShape.decode(wrapped)?.points.count, 2)
        XCTAssertNil(HeldShape.decode(.null))
        XCTAssertNil(HeldShape.decode(["shape": .null]))
    }

    func testHeldShapesFollowThePen() {
        let line = ShapeItem(shape: .line, frame: Frame(x: 0, y: 0, w: 100, h: 0), points: [Point(0, 0), Point(100, 0)])
        let turned = HeldShape.adjusted(line, from: Point(100, 0), to: Point(0, 200))
        XCTAssertEqual(turned.points[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(turned.points[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(turned.points[1].x, 0, accuracy: 1e-9)
        XCTAssertEqual(turned.points[1].y, 200, accuracy: 1e-9)

        let ellipse = ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 100, h: 50))
        let grown = HeldShape.adjusted(ellipse, from: Point(100, 25), to: Point(150, 25))
        XCTAssertEqual(grown.frame, Frame(x: -50, y: -25, w: 200, h: 100))
    }

    func testTiltedBoxesAreCreatedAsPolygons() {
        let upright = ShapeItem(shape: .rectangle, frame: Frame(x: 10, y: 20, w: 30, h: 40))
        let a = HeldShape.createParams(upright, page: "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(a["shape"]?.stringValue, "rectangle")
        XCTAssertEqual(a["frame"], [10, 20, 30, 40])

        let tilted = ShapeItem(shape: .rectangle, frame: Frame(x: 10, y: 20, w: 30, h: 40, rotation: 0.3))
        let b = HeldShape.createParams(tilted, page: "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(b["shape"]?.stringValue, "polygon")
        XCTAssertEqual(b["points"]?.arrayValue?.count, 4)
        XCTAssertNil(b["frame"])
    }

    func testDrawAndHoldSnapsThroughShapeRecognizeAndCreatesAHighlighterShape() async throws {
        final class Box { var created: JSONValue? }
        let box = Box()
        let h = Harness(features: [FeatHighlighterFeature.self])
        h.app.commands.register(CommandDescriptor(id: "shape.recognize", title: "Recognise Shape", summary: "Stand-in.",
                                                  effect: .read)) { _, _ in
            try JSONValue.parse(#"{"shape":"line","points":[[10,10],[110,10]]}"#)
        }
        h.app.commands.register(CommandDescriptor(id: "shape.create", title: "Create Shape", summary: "Stand-in.",
                                                  effect: .edit)) { params, _ in
            box.created = params
            return ["ref": "item:FIXTUREDOC01/FIXTUREPG001/NEWSHAPE0001"]
        }
        let host = FakeCanvasHost(h)
        let tool = HighlighterTool()
        let stroke = Stroke(style: .defaultHighlighter, points: points([(10, 10), (60, 13), (110, 10)]), t0: 0)

        XCTAssertTrue(tool.strokeHeld(stroke, page: Fixtures.page1, host: host))
        XCTAssertEqual(host.wetStrokeCancels, 1)
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(110, 10)), host: host)
        for _ in 0..<200 where box.created == nil { try await Task.sleep(nanoseconds: 5_000_000) }

        let created = try XCTUnwrap(box.created)
        XCTAssertEqual(created["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(created["shape"]?.stringValue, "line")
        XCTAssertEqual(created["style"]?["drawnWith"]?.stringValue, "highlighter")
        XCTAssertEqual(created["style"]?["strokeWidth"]?.doubleValue, InkStyle.defaultHighlighter.width)
        XCTAssertTrue(host.committed.isEmpty, "the snapped shape replaces the stroke")
    }

    func testWithoutShapeRecognitionOrWithDrawAndHoldOffTheStrokeIsNotConsumed() async throws {
        let h = Harness(features: [FeatHighlighterFeature.self])
        let host = FakeCanvasHost(h)
        let tool = HighlighterTool()
        let stroke = Stroke(style: .defaultHighlighter, points: wobbly, t0: 0)
        XCTAssertFalse(tool.strokeHeld(stroke, page: Fixtures.page1, host: host), "shape.recognize is not installed")

        h.app.commands.register(CommandDescriptor(id: "shape.recognize", title: "Recognise Shape", summary: "Stand-in.",
                                                  effect: .read)) { _, _ in .null }
        h.app.commands.register(CommandDescriptor(id: "shape.create", title: "Create Shape", summary: "Stand-in.",
                                                  effect: .edit)) { _, _ in .null }
        try await h.run(CommandIDs.settingsSet, ["name": "highlighter.drawAndHold", "value": false])
        XCTAssertFalse(tool.strokeHeld(stroke, page: Fixtures.page1, host: host))
        XCTAssertEqual(host.wetStrokeCancels, 0)
    }

    func testAHoldThatSnapsToNothingKeepsTheStroke() async throws {
        let h = Harness(features: [FeatHighlighterFeature.self])
        h.app.commands.register(CommandDescriptor(id: "shape.recognize", title: "Recognise Shape", summary: "Stand-in.",
                                                  effect: .read)) { _, _ in .null }
        h.app.commands.register(CommandDescriptor(id: "shape.create", title: "Create Shape", summary: "Stand-in.",
                                                  effect: .edit)) { _, _ in .null }
        let host = FakeCanvasHost(h)
        let tool = HighlighterTool()
        let stroke = Stroke(style: .defaultHighlighter, points: wobbly, t0: 0)
        XCTAssertTrue(tool.strokeHeld(stroke, page: Fixtures.page1, host: host))
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(110, 100)), host: host)
        for _ in 0..<200 where host.committed.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(host.committed.first?.stroke, stroke)
        XCTAssertEqual(host.committed.count, 1)
    }
}
