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
        // Only positions move: time and nib sizes are the captured ones.
        XCTAssertEqual(out.map(\.t), zigzag.map(\.t))
        XCTAssertEqual(out.map(\.width), zigzag.map(\.width))
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
        for name in ["highlighter.straightLine", "highlighter.stabilization"] {
            XCTAssertEqual(h.app.settings.descriptor(name)?.owner, "highlighter", name)
        }
        // Draw and Hold is the shared contracts key (G13): read, not declared again.
        XCTAssertEqual(HighlighterSettings.drawAndHold.name, NibSettings.drawAndHold.name)
        XCTAssertNotEqual(h.app.settings.descriptor(NibSettings.drawAndHold.name)?.owner, "highlighter")
        XCTAssertNil(h.app.settings.descriptor("highlighter.drawAndHold"))
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
        XCTAssertEqual(PresetEdit.selectWidth(0).command, "preset.select")
        XCTAssertEqual(PresetEdit.setWidth(index: 0, width: 9).command, "preset.setWidth")
        // Every highlighter colour, preset or custom, carries the contracts' highlighter translucency.
        XCTAssertTrue(NibHighlighter.allCases.allSatisfy { $0.rgba.a == RGBA.highlighterAlpha })
        XCTAssertEqual(RGBA(0x12, 0x34, 0x56).asHighlighter, RGBA(0x12, 0x34, 0x56, RGBA.highlighterAlpha))
    }

    // MARK: Draw and Hold

    func testRecognitionResultDecodesBareAndWrappedShapes() throws {
        let bare = try JSONValue.parse(#"{"shape":"rectangle","frame":{"x":1,"y":2,"w":3,"h":4},"confidence":0.9,"mergeWith":["item:D/P/A"]}"#)
        XCTAssertEqual(HeldShape.decode(bare)?.shape.shape, .rectangle)
        XCTAssertEqual(HeldShape.decode(bare)?.mergeWith, ["item:D/P/A"])
        let wrapped = try JSONValue.parse(#"{"shape":{"shape":"line","points":[[0,0],[10,0]]},"mergeWith":["item:D/P/B"],"confidence":0.8}"#)
        XCTAssertEqual(HeldShape.decode(wrapped)?.shape.points.count, 2)
        XCTAssertEqual(HeldShape.decode(wrapped)?.mergeWith, ["item:D/P/B"])
        let alone = try JSONValue.parse(#"{"shape":{"shape":"ellipse","frame":{"x":0,"y":0,"w":5,"h":5}}}"#)
        XCTAssertEqual(HeldShape.decode(alone)?.mergeWith, [])
        XCTAssertNil(HeldShape.decode(.null))
        XCTAssertNil(HeldShape.decode(["shape": .null]))
        XCTAssertNil(HeldShape.decode(["shape": .null, "mergeWith": []]))
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

    func testBoxesAreCreatedWithTheArrayFrameKeepingTheirRotation() throws {
        let upright = ShapeItem(shape: .rectangle, frame: Frame(x: 10, y: 20, w: 30, h: 40))
        let a = HeldShape.createParams(upright, page: "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(a["shape"]?.stringValue, "rectangle")
        XCTAssertEqual(a["frame"], [10, 20, 30, 40])

        // A box the pen turned stays that box: the rotation travels as the frame's 5th value (§6.1, G24).
        let tilted = ShapeItem(shape: .ellipse, frame: Frame(x: 10, y: 20, w: 30, h: 40, rotation: 0.3))
        let b = HeldShape.createParams(tilted, page: "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(b["shape"]?.stringValue, "ellipse")
        XCTAssertNil(b["points"])
        let frame = try XCTUnwrap(b["frame"]?.arrayValue?.compactMap(\.doubleValue))
        XCTAssertEqual(frame.count, 5)
        XCTAssertEqual(Frame(array: frame), tilted.frame)

        // Point shapes send their control points unchanged.
        let arc = ShapeItem(shape: .arc, frame: Frame(x: 0, y: 0, w: 100, h: 100),
                            points: [Point(100, 0), Point(100, 100), Point(0, 100)])
        let c = HeldShape.createParams(arc, page: "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(c["points"], [[100, 0], [100, 100], [0, 100]])
        XCTAssertNil(c["frame"])
    }

    // MARK: Preview (control points, as the Shapes feature draws them)

    private func assertInside(_ line: [Point], _ controls: [Point], file: StaticString = #filePath, line l: UInt = #line) {
        guard let hull = Rect.bounding(controls) else { return XCTFail("no control points", file: file, line: l) }
        for p in line {
            XCTAssertTrue(p.x >= hull.minX - 1e-9 && p.x <= hull.maxX + 1e-9 && p.y >= hull.minY - 1e-9 && p.y <= hull.maxY + 1e-9,
                          "\(p) leaves the control points' bounds", file: file, line: l)
        }
    }

    func testThreePointCurvePreviewTreatsTheMiddlePointAsAControlPoint() throws {
        let controls = [Point(0, 0), Point(50, 100), Point(100, 0)]
        let curve = ShapeItem(shape: .curve, frame: Frame(x: 0, y: 0, w: 100, h: 100), points: controls)
        let line = try XCTUnwrap(HeldShape.outline(curve).first)
        XCTAssertEqual(line.first, controls[0])
        XCTAssertEqual(line.last, controls[2])
        // A quadratic Bézier's apex is halfway to its control point: (50, 50), not through (50, 100).
        let apex = try XCTUnwrap(line.max { $0.y < $1.y })
        XCTAssertEqual(apex.x, 50, accuracy: 1e-6)
        XCTAssertEqual(apex.y, 50, accuracy: 1e-6)
        assertInside(line, controls)

        // Through-points converted with the contracts' helper come back through the middle point.
        let through = ShapeItem.quadraticControl(through: Point(0, 0), Point(50, 100), Point(100, 0))
        let converted = ShapeItem(shape: .curve, frame: Frame(x: 0, y: 0, w: 100, h: 200), points: through)
        let passing = try XCTUnwrap(HeldShape.outline(converted).first)
        let top = try XCTUnwrap(passing.max { $0.y < $1.y })
        XCTAssertEqual(top.x, 50, accuracy: 2)
        XCTAssertEqual(top.y, 100, accuracy: 0.05)
    }

    func testCubicAndSplineCurvePreviewsStayInsideTheirControlPoints() throws {
        let cubic = [Point(0, 0), Point(0, 90), Point(120, 90), Point(120, 0)]
        let a = try XCTUnwrap(HeldShape.outline(ShapeItem(shape: .curve, frame: Frame(x: 0, y: 0, w: 120, h: 90),
                                                          points: cubic)).first)
        XCTAssertEqual(a.first, cubic[0])
        XCTAssertEqual(a.last, cubic[3])
        XCTAssertEqual(try XCTUnwrap(a.max { $0.y < $1.y }).y, 67.5, accuracy: 1e-6)   // 3/4 of the control height
        assertInside(a, cubic)

        let spline = [Point(0, 0), Point(40, 80), Point(80, 0), Point(120, 80), Point(160, 0)]
        let b = try XCTUnwrap(HeldShape.outline(ShapeItem(shape: .curve, frame: Frame(x: 0, y: 0, w: 160, h: 80),
                                                          points: spline)).first)
        XCTAssertEqual(b.first, spline[0])
        XCTAssertEqual(b.last?.x ?? 0, 160, accuracy: 1e-9)
        XCTAssertEqual(b.last?.y ?? 1, 0, accuracy: 1e-9)
        XCTAssertFalse(b.contains { $0.distance(to: Point(40, 80)) < 1 }, "a B-spline does not pass through its control points")
        assertInside(b, spline)
    }

    func testArcPreviewIsTheConicWhoseTangentsMeetAtTheControlPoint() throws {
        // A quarter circle of radius 100 about the origin: start (100, 0), tangents meet at (100, 100), end (0, 100).
        let controls = [Point(100, 0), Point(100, 100), Point(0, 100)]
        let arc = ShapeItem(shape: .arc, frame: Frame(x: 0, y: 0, w: 100, h: 100), points: controls)
        let line = try XCTUnwrap(HeldShape.outline(arc).first)
        XCTAssertEqual(line.first, controls[0])
        XCTAssertEqual(line.last, controls[2])
        XCTAssertGreaterThan(line.count, 12)
        for p in line { XCTAssertEqual(p.distance(to: .zero), 100, accuracy: 1e-6) }
        assertInside(line, controls)
    }

    func testAdjustingACurveMovesItsControlPointsTogether() {
        let curve = ShapeItem(shape: .curve, frame: Frame(x: 0, y: 0, w: 100, h: 100),
                              points: [Point(0, 0), Point(50, 100), Point(100, 0)])
        let doubled = HeldShape.adjusted(curve, from: Point(100, 0), to: Point(200, 0))
        XCTAssertEqual(doubled.points, [Point(0, 0), Point(100, 200), Point(200, 0)])
        XCTAssertEqual(doubled.frame, Frame(x: 0, y: 0, w: 200, h: 200), "the frame bounds the control points")
    }

    func testDrawAndHoldSnapsThroughShapeRecognizeAndCreatesAHighlighterShape() async throws {
        final class Box {
            var created: JSONValue?
            var createGroup: String?
            var deleted: JSONValue?
            var deleteGroup: String?
            var snaps: [ShapeSnappedPayload] = []
        }
        let box = Box()
        let h = Harness(features: [FeatHighlighterFeature.self])
        h.app.commands.register(CommandDescriptor(id: "shape.recognize", title: "Recognise Shape", summary: "Stand-in.",
                                                  effect: .read)) { _, _ in
            try JSONValue.parse(#"{"shape":{"shape":"line","points":[[10,10],[110,10]]},"mergeWith":["item:FIXTUREDOC01/FIXTUREPG001/OLDSHAPE0001"],"confidence":0.9}"#)
        }
        h.app.commands.register(CommandDescriptor(id: "shape.create", title: "Create Shape", summary: "Stand-in.",
                                                  effect: .edit)) { params, ctx in
            box.created = params
            box.createGroup = ctx.group
            return ["ref": "item:FIXTUREDOC01/FIXTUREPG001/NEWSHAPE0001"]
        }
        h.app.commands.register(CommandDescriptor(id: "item.delete", title: "Delete", summary: "Stand-in.",
                                                  effect: .edit)) { params, ctx in
            box.deleted = params
            box.deleteGroup = ctx.group
            return .null
        }
        let subscription = h.app.events.subscribe { event in
            if let snap = event.decode(ShapeSnappedPayload.self) { box.snaps.append(snap) }
        }
        defer { subscription.cancel() }
        let host = FakeCanvasHost(h)
        let tool = HighlighterTool()
        let stroke = Stroke(style: .defaultHighlighter, points: points([(10, 10), (60, 13), (110, 10)]), t0: 0)

        XCTAssertTrue(tool.strokeHeld(stroke, page: Fixtures.page1, host: host))
        XCTAssertEqual(host.wetStrokeCancels, 1)
        XCTAssertEqual(host.overlayLayer.sublayers?.count, 1, "the held ink stays visible as a preview")
        for _ in 0..<200 where box.snaps.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let snap = try XCTUnwrap(box.snaps.first)
        XCTAssertEqual(snap, ShapeSnappedPayload(page: "page:FIXTUREDOC01/FIXTUREPG001", shape: "line",
                                                 point: Point(110, 10), session: h.session.id.raw))

        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(110, 10)), host: host)
        for _ in 0..<200 where box.deleted == nil { try await Task.sleep(nanoseconds: 5_000_000) }

        let created = try XCTUnwrap(box.created)
        XCTAssertEqual(created["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(created["shape"]?.stringValue, "line")
        XCTAssertEqual(created["points"], [[10, 10], [110, 10]])
        XCTAssertEqual(created["style"]?["drawnWith"]?.stringValue, "highlighter")
        XCTAssertEqual(created["style"]?["strokeWidth"]?.doubleValue, InkStyle.defaultHighlighter.width)
        XCTAssertTrue(host.committed.isEmpty, "the snapped shape replaces the stroke")
        // The neighbours the recogniser joined in go in the same undo step as the new shape.
        XCTAssertEqual(box.deleted?["refs"], ["item:FIXTUREDOC01/FIXTUREPG001/OLDSHAPE0001"])
        XCTAssertNotNil(box.createGroup)
        XCTAssertEqual(box.deleteGroup, box.createGroup)
        // The preview is dropped once the created shape has rendered.
        for _ in 0..<200 where host.renderWaits.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(host.renderWaits, [Fixtures.page1])
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true)
        XCTAssertEqual(box.snaps.count, 1)
    }

    func testAHeldShapeFollowsThePenOntoTheNextPage() async throws {
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
        // Lifted on page 2, straight below the hold point: in page 1's coordinates that is one page and gap lower.
        let below = try XCTUnwrap(host.convert(Point(110, 10), from: Fixtures.page2, to: Fixtures.page1))
        XCTAssertGreaterThan(below.y, 800)
        tool.touchesEnded(CanvasSample(page: Fixtures.page2, location: Point(110, 10)), host: host)
        for _ in 0..<200 where box.created == nil { try await Task.sleep(nanoseconds: 5_000_000) }

        let created = try XCTUnwrap(box.created)
        XCTAssertEqual(created["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        let end = try XCTUnwrap(created["points"]?.arrayValue?.last?.arrayValue?.compactMap(\.doubleValue))
        XCTAssertEqual(end[0], below.x, accuracy: 1e-6)
        XCTAssertEqual(end[1], below.y, accuracy: 1e-6)
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
        try await h.run(CommandIDs.settingsSet, ["name": "shapes.drawAndHold", "value": false])
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
        let subscription = h.app.events.subscribe { event in
            XCTAssertNotEqual(event.type, NibEventType.shapeSnapped, "nothing snapped")
        }
        defer { subscription.cancel() }
        XCTAssertTrue(tool.strokeHeld(stroke, page: Fixtures.page1, host: host))
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(110, 100)), host: host)
        for _ in 0..<200 where host.committed.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(host.committed.first?.stroke, stroke)
        XCTAssertEqual(host.committed.count, 1)
        XCTAssertEqual(host.renderWaits, [Fixtures.page1], "the preview stays until the kept stroke has rendered")
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true)
    }

    func testCancellingAHoldKeepsTheStrokeAsDrawn() {
        let h = Harness(features: [FeatHighlighterFeature.self])
        h.app.commands.register(CommandDescriptor(id: "shape.recognize", title: "Recognise Shape", summary: "Stand-in.",
                                                  effect: .read)) { _, _ in .null }
        h.app.commands.register(CommandDescriptor(id: "shape.create", title: "Create Shape", summary: "Stand-in.",
                                                  effect: .edit)) { _, _ in .null }
        let host = FakeCanvasHost(h)
        let tool = HighlighterTool()
        let stroke = Stroke(style: .defaultHighlighter, points: wobbly, t0: 0)
        XCTAssertTrue(tool.strokeHeld(stroke, page: Fixtures.page1, host: host))
        tool.touchesCancelled(host: host)
        XCTAssertEqual(host.committed.map(\.stroke), [stroke])
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true)
    }
}
