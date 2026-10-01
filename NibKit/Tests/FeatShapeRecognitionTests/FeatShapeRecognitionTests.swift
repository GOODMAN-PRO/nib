import XCTest
import NibContracts
import NibTesting
@testable import FeatShapeRecognition

@MainActor
final class FeatShapeRecognitionTests: XCTestCase {
    private let page = Fixtures.page1
    private let pageRef = "page:FIXTUREDOC01/FIXTUREPG001"

    private func stroke(_ points: [Point], _ h: Harness) -> Stroke {
        Stroke(style: DrawShapeTool.inkStyle(h.app.settings),
               points: points.map { StrokePoint(x: Float($0.x), y: Float($0.y)) })
    }

    private func rectangleStroke(_ h: Harness) -> Stroke {
        stroke(Geo.resample([Point(100, 100), Point(300, 100), Point(300, 220), Point(100, 220), Point(100, 100)], count: 120), h)
    }

    private func zigzagStroke(_ h: Harness) -> Stroke {
        stroke([Point(100, 100), Point(200, 110), Point(105, 125), Point(205, 135), Point(100, 150), Point(210, 160),
                Point(98, 172), Point(200, 185)], h)
    }

    /// Stand-ins for commands other features own (F031 shape.create, F013 item.delete), recording each call.
    private final class Calls {
        var params: [String: JSONValue] = [:]
        var groups: [String: String] = [:]
    }

    private func standIn(_ id: String, _ h: Harness, _ calls: Calls, _ done: XCTestExpectation? = nil,
                         result: JSONValue = [:], fails: Bool = false) {
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", params: .anything(),
                                                  effect: .edit)) { json, ctx in
            calls.params[id] = json
            calls.groups[id] = ctx.group
            done?.fulfill()
            if fails { throw NibError.unavailable("the test's \(id)") }
            return result
        }
    }

    /// Existing unlocked line shapes on the fixture page, added through a test command.
    private func seedLines(_ h: Harness, _ lines: [(id: String, from: Point, to: Point, layer: Int)]) async throws {
        h.app.commands.register(CommandDescriptor(id: "test.seedLines", title: "Seed lines", summary: "Test helper.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                for l in lines {
                    var item = Item.makeShape(ShapeRecognizer.pointShape(.line, [l.from, l.to]), layer: l.layer)
                    item.id = NibID(l.id)
                    _ = try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1)
                }
            }
            return [:]
        }
        _ = try await h.run("test.seedLines")
    }

    private func itemRef(_ id: String) -> String { "item:FIXTUREDOC01/FIXTUREPG001/\(id)" }

    private func assertPoints(_ value: JSONValue?, _ expected: [Point], file: StaticString = #filePath, line: UInt = #line) {
        let got = (value?.arrayValue ?? []).map { Point($0[0]?.doubleValue ?? .nan, $0[1]?.doubleValue ?? .nan) }
        XCTAssertEqual(got.count, expected.count, "points: \(got)", file: file, line: line)
        for (g, e) in zip(got, expected) {
            XCTAssertLessThan(g.distance(to: e), 0.01, "points: \(got)", file: file, line: line)
        }
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Registration

    func testFeatureRegistersItsCommandToolShortcutSettingsAndPage() {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        XCTAssertEqual(FeatShapeRecognitionFeature.id, "shaperec")
        XCTAssertEqual(h.app.commands.descriptor("shape.recognize")?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor("shape.recognize")?.owner, "shaperec")
        XCTAssertNotNil(h.app.ui.canvasTools.get("drawShape"))
        let item = h.app.ui.toolbar.get("drawShape")
        XCTAssertEqual(item?.toolID, "drawShape")
        XCTAssertEqual(item?.icon, "pencil.and.outline", "NibSymbol.drawShape")
        XCTAssertEqual(item?.shortcut, KeyShortcut("d"))
        XCTAssertNotNil(item?.settings)
        let key = h.app.content.keyCommands.all.first { $0.shortcut == KeyShortcut("d") }
        XCTAssertEqual(key?.command, CommandIDs.toolSelect)
        XCTAssertEqual(key?.params, ["tool": "drawShape"])
        XCTAssertEqual(key?.scope, .canvas)
        XCTAssertEqual(key?.docKinds, [.notebook, .whiteboard])
        for name in ["shapes.snapToOtherShapes", "shapes.requireHoldToSnap"] {
            XCTAssertEqual(h.app.settings.descriptor(name)?.owner, "shaperec", name)
            XCTAssertEqual(h.app.settings.descriptor(name)?.synced, true, name)
        }
        // Draw and Hold is the contracts' shared key: read, not re-declared.
        XCTAssertEqual(h.app.settings.descriptor(NibSettings.drawAndHold.name)?.owner, "builtin")
        XCTAssertEqual(NibSettings.drawAndHold.name, "shapes.drawAndHold")
        XCTAssertEqual(h.app.ui.settingsPages.get("shaperec.settings")?.section, .writing)
    }

    /// Under the shell's key routing, D selects the tool in notebooks and whiteboards while no text is edited, and
    /// nowhere else.
    func testDrawShapeKeyIsLiveOnlyOnCanvasDocuments() throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let key = try XCTUnwrap(h.app.content.keyCommands.get(DrawShapeTool.keyCommandID))
        XCTAssertTrue(key.isActive(in: KeyCommandContext(docKind: .notebook)))
        XCTAssertTrue(key.isActive(in: KeyCommandContext(docKind: .whiteboard)))
        XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: .notebook, isEditingText: true)))
        XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: .studySet)))
        XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: .textDocument)))
        XCTAssertFalse(key.isActive(in: KeyCommandContext(docKind: nil, hasTabs: true)))
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatShapeRecognitionFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: shape.recognize

    /// The wrapped result (ARCHITECTURE §6.5): `{shape: ShapeItem, confidence, mergeWith}`.
    func testRecognizeReturnsTheWrappedShapeItemForTheAssistant() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let points: JSONValue = [[100, 100], [260, 102], [259, 190], [101, 188], [100, 101]]
        let value = try await h.run("shape.recognize", ["points": points], as: .ai("chat"))
        XCTAssertEqual(Set(value.objectValue?.keys.map { $0 } ?? []), ["shape", "confidence", "mergeWith"])
        XCTAssertEqual(value["shape"]?["shape"], "rectangle")
        XCTAssertEqual(value["mergeWith"], [])
        XCTAssertGreaterThan(value["confidence"]?.doubleValue ?? 0, 0.5)
        XCTAssertLessThanOrEqual(value["confidence"]?.doubleValue ?? 2, 1)
        let shape = try XCTUnwrap(value["shape"]).decode(ShapeItem.self)
        XCTAssertEqual(shape.shape, .rectangle)
        XCTAssertEqual(shape.frame.w, 159, accuracy: 3)
        XCTAssertEqual(shape.frame.h, 88, accuracy: 3)
        XCTAssertEqual(shape.style.cornerRadius, 0)
        let output = try value.decode(ShapeRecognizeCommand.Output.self)
        XCTAssertEqual(output.shape, shape)
        XCTAssertEqual(output.mergeWith, [])
    }

    /// Curves come back as control points (contracts-v2 ShapeItem.points): a parabola's quadratic control lies off the
    /// stroke, where `ShapeItem.quadraticControl(through:_:_:)` puts it.
    func testRecognizeReturnsCurveControlPoints() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let points = JSONValue.array((0...60).map { i -> JSONValue in
            let t = Double(i) / 60
            return [.number(100 + 240 * t), .number(300 - 240 * t * (1 - t))]
        })
        let value = try await h.run("shape.recognize", ["points": points])
        let shape = try XCTUnwrap(value["shape"]).decode(ShapeItem.self)
        XCTAssertEqual(shape.shape, .curve)
        let expected = ShapeItem.quadraticControl(through: Point(100, 300), Point(220, 240), Point(340, 300))
        XCTAssertEqual(shape.points.count, 3)
        for (got, want) in zip(shape.points, expected) {
            XCTAssertLessThan(got.distance(to: want), 1, "\(shape.points)")
        }
    }

    func testRecognizeReturnsANullShapeForAScribbleAndRejectsBadInput() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let zigzag: JSONValue = [[100, 100], [200, 110], [105, 125], [205, 135], [100, 150], [210, 160], [98, 172], [200, 185]]
        let value = try await h.run("shape.recognize", ["points": zigzag])
        XCTAssertEqual(value, ["shape": .null])
        XCTAssertNil(try value.decode(ShapeRecognizeCommand.Output.self).shape)
        do {
            _ = try await h.run("shape.recognize", ["points": [[1, 2]]], as: .ai("chat"))
            XCTFail("one point is not a stroke")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            _ = try await h.run("shape.recognize", ["points": [[1, 2], [30, 40]], "neighbors": ["doc:FIXTUREDOC01"]])
            XCTFail("a document is not a neighbour")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.neighbors[0]")
        }
    }

    func testRecognizeJoinsInlineNeighboursUnlessSnappingIsOff() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let params: JSONValue = [
            "points": [[402, 305], [402, 400]],
            "neighbors": [["id": "N1", "shape": "line", "points": [[300, 300], [400, 300]]]]
        ]
        let joined = try await h.run("shape.recognize", params)
        XCTAssertEqual(joined["shape"]?["shape"], "polyline")
        XCTAssertEqual(joined["mergeWith"], ["N1"])
        assertPoints(joined["shape"]?["points"], [Point(300, 300), Point(400, 300), Point(402, 400)])

        _ = try await h.run(CommandIDs.settingsSet, ["name": "shapes.snapToOtherShapes", "value": false])
        let alone = try await h.run("shape.recognize", params)
        XCTAssertEqual(alone["shape"]?["shape"], "line")
        XCTAssertEqual(alone["mergeWith"], [])
    }

    func testRecognizeSnapsToTheShapesOfAPage() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        // The fixture page's rectangle has its top-left corner at (100, 200).
        let value = try await h.run("shape.recognize", ["points": [[104, 203], [180, 320]], "neighbors": .string(pageRef)])
        XCTAssertEqual(value["shape"]?["shape"], "line")
        XCTAssertEqual(value["shape"]?["points"]?[0], [100, 200])
        XCTAssertEqual(value["mergeWith"], [])
    }

    /// With a page ref the command sees what the Draw Shape tool sees: shapes on another layer are snap targets but
    /// are never merged away, and shapes on hidden layers are ignored.
    func testRecognizeWithAPageRefMergesOnlyTheActiveLayer() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        try await seedLines(h, [(id: "LAYERLINE001", from: Point(300, 600), to: Point(400, 600), layer: 1)])
        let params: JSONValue = ["points": [[402, 605], [402, 700]], "neighbors": .string(pageRef)]
        h.session.activeLayer = 0
        let other = try await h.run("shape.recognize", params)
        XCTAssertEqual(other["shape"]?["shape"], "line")
        XCTAssertEqual(other["mergeWith"], [])
        XCTAssertEqual(other["shape"]?["points"]?[0], [400, 600])

        h.session.activeLayer = 1
        let active = try await h.run("shape.recognize", params)
        XCTAssertEqual(active["shape"]?["shape"], "polyline")
        XCTAssertEqual(active["mergeWith"], [.string(itemRef("LAYERLINE001"))])

        h.session.activeLayer = 0
        h.session.hiddenLayers = [1]
        let hidden = try await h.run("shape.recognize", params)
        XCTAssertEqual(hidden["mergeWith"], [])
        assertPoints(hidden["shape"]?["points"], [Point(402, 605), Point(402, 700)])
    }

    // MARK: Draw Shape tool

    func testDrawShapeKeepsInkThatIsNotAShape() {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(zigzagStroke(h), page: page, host: host)
        XCTAssertEqual(host.committed.count, 1)
        XCTAssertEqual(host.wetStrokeCancels, 0)
    }

    func testDrawShapeConvertsOnLiftWithThePenLook() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let calls = Calls()
        let created = expectation(description: "shape.create")
        standIn(CommandIDs.shapeCreate, h, calls, created, result: ["ref": "item:FIXTUREDOC01/FIXTUREPG001/NEWSHAPE0001"])
        let host = FakeCanvasHost(h)
        let tool = DrawShapeTool()
        XCTAssertEqual(tool.inkStyle(host)?.pen, .ball)
        tool.strokeFinished(rectangleStroke(h), page: page, host: host)
        await fulfillment(of: [created], timeout: 5)
        let p = try XCTUnwrap(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(p["page"], .string(pageRef))
        XCTAssertEqual(p["shape"], "rectangle")
        XCTAssertEqual(p["frame"]?[2]?.doubleValue ?? 0, 200, accuracy: 1)
        XCTAssertEqual(p["style"]?["drawnWith"], "pen")
        XCTAssertEqual(p["style"]?["cornerRadius"], 0)
        XCTAssertTrue(host.committed.isEmpty)
        XCTAssertEqual(host.wetStrokeCancels, 1)
    }

    /// The clean preview stays until the page's dry tiles show the committed shape (`afterNextRender`), then goes.
    func testPreviewIsRetiredAfterTheNextRender() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let calls = Calls()
        standIn(CommandIDs.shapeCreate, h, calls, result: ["ref": "item:FIXTUREDOC01/FIXTUREPG001/NEWSHAPE0001"])
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(rectangleStroke(h), page: page, host: host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count ?? 0, 1, "the clean shape shows at once")
        await settle { !host.renderWaits.isEmpty }
        XCTAssertNotNil(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(host.renderWaits, [page])
        XCTAssertEqual(host.overlayLayer.sublayers?.count ?? 0, 0)
    }

    func testRequireHoldToSnapKeepsLiftedStrokesAsInk() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        _ = try await h.run(CommandIDs.settingsSet, ["name": "shapes.requireHoldToSnap", "value": true])
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(rectangleStroke(h), page: page, host: host)
        XCTAssertEqual(host.committed.count, 1)
    }

    func testDrawAndHoldScalesTheSnappedShapeUntilLift() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let calls = Calls()
        let created = expectation(description: "shape.create")
        standIn(CommandIDs.shapeCreate, h, calls, created)
        let host = FakeCanvasHost(h)
        let tool = DrawShapeTool()
        let line = stroke(Geo.resample([Point(100, 100), Point(200, 100)], count: 30), h)
        XCTAssertTrue(tool.strokeHeld(line, page: page, host: host))
        tool.touchesMoved([CanvasSample(page: page, location: Point(250, 100))], host: host)
        tool.touchesEnded(CanvasSample(page: page, location: Point(300, 100)), host: host)
        await fulfillment(of: [created], timeout: 5)
        let p = try XCTUnwrap(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(p["shape"], "line")
        XCTAssertEqual(p["points"]?[0]?[0]?.doubleValue ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(p["points"]?[1]?[0]?.doubleValue ?? 0, 300, accuracy: 1e-6)
        XCTAssertEqual(p["points"]?[1]?[1]?.doubleValue ?? 0, 100, accuracy: 1e-6)
        XCTAssertTrue(host.committed.isEmpty)
    }

    func testDrawAndHoldOffLeavesTheHeldStrokeAlone() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        _ = try await h.run(CommandIDs.settingsSet, ["name": "shapes.drawAndHold", "value": false])
        let host = FakeCanvasHost(h)
        let line = stroke(Geo.resample([Point(100, 100), Point(200, 100)], count: 30), h)
        XCTAssertFalse(DrawShapeTool().strokeHeld(line, page: page, host: host))
    }

    func testCancelledHoldKeepsTheInk() {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let host = FakeCanvasHost(h)
        let tool = DrawShapeTool()
        XCTAssertTrue(tool.strokeHeld(rectangleStroke(h), page: page, host: host))
        tool.touchesCancelled(host: host)
        XCTAssertEqual(host.committed.count, 1)
    }

    /// A Pencil squeeze, double-tap or shortcut that switches tools mid-hold keeps the held stroke as ink.
    func testSwitchingToolsDuringAHoldKeepsTheInk() {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let host = FakeCanvasHost(h)
        let tool = DrawShapeTool()
        let held = rectangleStroke(h)
        XCTAssertTrue(tool.strokeHeld(held, page: page, host: host))
        tool.deactivate(host)
        XCTAssertEqual(host.committed.count, 1)
        XCTAssertEqual(host.committed.first?.stroke.points.count, held.points.count)
        XCTAssertEqual(host.committed.first?.page, page)
        tool.deactivate(host)
        XCTAssertEqual(host.committed.count, 1, "no hold, nothing more to keep")
    }

    func testWithoutShapeCreateTheStrokeStaysInk() async {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(rectangleStroke(h), page: page, host: host)
        await settle { !host.committed.isEmpty }
        XCTAssertEqual(host.committed.count, 1)
    }

    func testJoiningAnExistingLineDeletesItAndCreatesOnePolylineInOneUndoStep() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        try await seedLines(h, [(id: "OLDLINE00001", from: Point(300, 300), to: Point(400, 300), layer: 0)])
        let calls = Calls()
        let created = expectation(description: "shape.create")
        let deleted = expectation(description: "item.delete")
        standIn(CommandIDs.shapeCreate, h, calls, created)
        standIn(CommandIDs.itemDelete, h, calls, deleted)
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(stroke(Geo.resample([Point(402, 305), Point(402, 400)], count: 30), h), page: page, host: host)
        await fulfillment(of: [created, deleted], timeout: 5, enforceOrder: true)
        XCTAssertEqual(calls.params[CommandIDs.itemDelete]?["refs"], [.string(itemRef("OLDLINE00001"))])
        let p = try XCTUnwrap(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(p["shape"], "polyline")
        assertPoints(p["points"], [Point(300, 300), Point(400, 300), Point(402, 400)])
        XCTAssertNotNil(calls.groups[CommandIDs.shapeCreate])
        XCTAssertEqual(calls.groups[CommandIDs.shapeCreate], calls.groups[CommandIDs.itemDelete])
    }

    /// A box drawn as four separate lines: the fourth side joins the far side too (through the top and bottom), so the
    /// three old lines go and one four-cornered polygon is made.
    func testFourthSideOfABoxOfLinesMakesOnePolygon() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        try await seedLines(h, [(id: "BOXTOP000001", from: Point(400, 600), to: Point(560, 600), layer: 0),
                                (id: "BOXRIGHT0001", from: Point(560, 600), to: Point(560, 760), layer: 0),
                                (id: "BOXBOTTOM001", from: Point(560, 760), to: Point(400, 760), layer: 0)])
        let calls = Calls()
        let created = expectation(description: "shape.create")
        let deleted = expectation(description: "item.delete")
        standIn(CommandIDs.shapeCreate, h, calls, created)
        standIn(CommandIDs.itemDelete, h, calls, deleted)
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(stroke(Geo.resample([Point(400, 758), Point(400, 602)], count: 40), h), page: page, host: host)
        await fulfillment(of: [created, deleted], timeout: 5, enforceOrder: true)
        let refs = (calls.params[CommandIDs.itemDelete]?["refs"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(Set(refs), Set(["BOXTOP000001", "BOXRIGHT0001", "BOXBOTTOM001"].map { itemRef($0) }))
        let p = try XCTUnwrap(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(p["shape"], "polygon")
        let corners = (p["points"]?.arrayValue ?? []).map { Point($0[0]?.doubleValue ?? .nan, $0[1]?.doubleValue ?? .nan) }
        XCTAssertEqual(corners.count, 4, "\(corners)")
        for expected in [Point(400, 600), Point(560, 600), Point(560, 760), Point(400, 760)] {
            XCTAssertLessThan(corners.map { $0.distance(to: expected) }.min() ?? 99, 0.01, "\(corners)")
        }
        XCTAssertEqual(calls.groups[CommandIDs.shapeCreate], calls.groups[CommandIDs.itemDelete])
        XCTAssertTrue(host.committed.isEmpty)
    }

    /// A tilted box goes to shape.create as one frame with its rotation (`[x, y, w, h, radians]`, `Frame.array`): one
    /// command, no follow-up turn.
    func testTiltedBoxSendsItsRotationInTheFrame() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let calls = Calls()
        let created = expectation(description: "shape.create")
        standIn(CommandIDs.shapeCreate, h, calls, created, result: ["ref": .string(itemRef("NEWSHAPE0001"))])
        standIn(CommandIDs.itemTransform, h, calls)
        let host = FakeCanvasHost(h)
        let c = Point(300, 600), tilt = 20 * Double.pi / 180
        let corners = [Point(200, 550), Point(400, 550), Point(400, 650), Point(200, 650)]
            .map { SeededStrokes.rotate($0, tilt, about: c) }
        DrawShapeTool().strokeFinished(stroke(Geo.resample(corners + [corners[0]], count: 120), h), page: page, host: host)
        await fulfillment(of: [created], timeout: 5)
        await settle { !host.renderWaits.isEmpty }
        let create = try XCTUnwrap(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(create["shape"], "rectangle")
        let values = (create["frame"]?.arrayValue ?? []).compactMap(\.doubleValue)
        let frame = try XCTUnwrap(Frame(array: values), "\(values)")
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(frame.w, 200, accuracy: 2)
        XCTAssertEqual(frame.h, 100, accuracy: 2)
        XCTAssertEqual(frame.center.x, c.x, accuracy: 1)
        XCTAssertEqual(frame.center.y, c.y, accuracy: 1)
        XCTAssertEqual(frame.rotation, tilt, accuracy: 1 * Double.pi / 180)
        XCTAssertNil(calls.params[CommandIDs.itemTransform], "the rotation travels with the frame")
    }

    /// shape.create runs before anything is deleted: when it fails, the neighbours stay and the stroke stays as ink.
    func testFailedCreateKeepsTheNeighboursAndTheInk() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        try await seedLines(h, [(id: "OLDLINE00001", from: Point(300, 300), to: Point(400, 300), layer: 0)])
        let calls = Calls()
        standIn(CommandIDs.shapeCreate, h, calls, fails: true)
        standIn(CommandIDs.itemDelete, h, calls)
        let depth = h.undoDepth(Fixtures.docID)
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(stroke(Geo.resample([Point(402, 305), Point(402, 400)], count: 30), h), page: page, host: host)
        await settle { !host.committed.isEmpty }
        XCTAssertNotNil(calls.params[CommandIDs.shapeCreate], "the merged polyline was tried")
        XCTAssertNil(calls.params[CommandIDs.itemDelete], "nothing was deleted")
        XCTAssertEqual(host.committed.count, 1)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth, "no revert step on the undo stack")
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: page, id: NibID("OLDLINE00001")))
    }

    /// When the canvas closes before the shape could be made, the stroke is still kept, through ink.addStrokes.
    func testClosedCanvasStillKeepsTheStrokeAsInk() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let calls = Calls()
        let kept = expectation(description: "ink.addStrokes")
        standIn(CommandIDs.inkAddStrokes, h, calls, kept)
        let drawn = rectangleStroke(h)
        weak var gone: FakeCanvasHost?
        do {
            let host = FakeCanvasHost(h)
            gone = host
            DrawShapeTool().strokeFinished(drawn, page: page, host: host)
        }
        XCTAssertNil(gone, "the canvas closed before the shape was made")
        await fulfillment(of: [kept], timeout: 5)
        let p = try XCTUnwrap(calls.params[CommandIDs.inkAddStrokes])
        XCTAssertEqual(p["page"], .string(pageRef))
        let strokes = try XCTUnwrap(p["strokes"]?.arrayValue)
        XCTAssertEqual(strokes.count, 1)
        XCTAssertEqual(try strokes[0].decode(Stroke.self).points.count, drawn.points.count)
    }

    /// `shape.snapped` (NibEventType.shapeSnapped) carries a `ShapeSnappedPayload` with the page point where the Pencil
    /// is, for F043's Pencil Pro haptic.
    func testSnappingEmitsAShapeSnappedPayloadWhereThePencilIs() throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let before = h.app.events.lastSeq
        let host = FakeCanvasHost(h)
        XCTAssertTrue(DrawShapeTool().strokeHeld(rectangleStroke(h), page: page, host: host))
        let snapped = h.app.events.events(since: before).filter { $0.type == NibEventType.shapeSnapped }
        XCTAssertEqual(snapped.count, 1)
        XCTAssertEqual(snapped.first?.doc, Fixtures.docID)
        let payload = try XCTUnwrap(snapped.first?.decode(ShapeSnappedPayload.self))
        XCTAssertEqual(payload.shape, "rectangle")
        XCTAssertEqual(payload.page, pageRef)
        XCTAssertEqual(payload.session, h.session.id.raw)
        // The rectangle stroke ends back at its first corner, where the Pencil is held.
        let point = try XCTUnwrap(payload.point)
        XCTAssertEqual(point.x, 100, accuracy: 0.01)
        XCTAssertEqual(point.y, 100, accuracy: 0.01)
    }

    func testCreateParamsSendFramesWithTheirRotationAndPoints() {
        let box = ShapeItem(shape: .ellipse, frame: Frame(x: 10, y: 20, w: 30, h: 40, rotation: 0.4))
        let boxParams = ShapeCommit.createParams(box, page: pageRef)
        XCTAssertEqual(boxParams["frame"], [10, 20, 30, 40, 0.4])
        XCTAssertNil(boxParams["points"])
        let upright = ShapeItem(shape: .rectangle, frame: Frame(x: 10, y: 20, w: 30, h: 40))
        XCTAssertEqual(ShapeCommit.createParams(upright, page: pageRef)["frame"], [10, 20, 30, 40])
        let arrow = ShapeRecognizer.pointShape(.arrow, [Point(1, 2), Point(3, 4)])
        let arrowParams = ShapeCommit.createParams(arrow, page: pageRef)
        XCTAssertEqual(arrowParams["points"], [[1, 2], [3, 4]])
        XCTAssertNil(arrowParams["frame"])
        XCTAssertEqual(arrowParams["shape"], "arrow")
    }
}
