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
                         result: JSONValue = [:]) {
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", params: .anything(),
                                                  effect: .edit)) { json, ctx in
            calls.params[id] = json
            calls.groups[id] = ctx.group
            done?.fulfill()
            return result
        }
    }

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
        XCTAssertEqual(item?.shortcut, KeyShortcut("d"))
        XCTAssertNotNil(item?.settings)
        let key = h.app.content.keyCommands.all.first { $0.shortcut == KeyShortcut("d") }
        XCTAssertEqual(key?.command, CommandIDs.toolSelect)
        XCTAssertEqual(key?.params, ["tool": "drawShape"])
        XCTAssertEqual(key?.scope, .canvas)
        for name in ["shapes.drawAndHold", "shapes.snapToOtherShapes", "shapes.requireHoldToSnap"] {
            XCTAssertEqual(h.app.settings.descriptor(name)?.owner, "shaperec", name)
            XCTAssertEqual(h.app.settings.descriptor(name)?.synced, true, name)
        }
        XCTAssertEqual(h.app.ui.settingsPages.get("shaperec.settings")?.section, .writing)
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatShapeRecognitionFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: shape.recognize

    func testRecognizeReturnsShapeItemJSONForTheAssistant() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let points: JSONValue = [[100, 100], [260, 102], [259, 190], [101, 188], [100, 101]]
        let value = try await h.run("shape.recognize", ["points": points], as: .ai("chat"))
        XCTAssertEqual(value["shape"], "rectangle")
        XCTAssertEqual(value["mergeWith"], [])
        XCTAssertGreaterThan(value["confidence"]?.doubleValue ?? 0, 0.5)
        let shape = try value.decode(ShapeItem.self)
        XCTAssertEqual(shape.shape, .rectangle)
        XCTAssertEqual(shape.frame.w, 159, accuracy: 3)
        XCTAssertEqual(shape.frame.h, 88, accuracy: 3)
    }

    func testRecognizeReturnsNullForAScribbleAndRejectsBadInput() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let zigzag: JSONValue = [[100, 100], [200, 110], [105, 125], [205, 135], [100, 150], [210, 160], [98, 172], [200, 185]]
        let value = try await h.run("shape.recognize", ["points": zigzag])
        XCTAssertEqual(value, .null)
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
        XCTAssertEqual(joined["shape"], "polyline")
        XCTAssertEqual(joined["mergeWith"], ["N1"])
        assertPoints(joined["points"], [Point(300, 300), Point(400, 300), Point(402, 400)])

        _ = try await h.run(CommandIDs.settingsSet, ["name": "shapes.snapToOtherShapes", "value": false])
        let alone = try await h.run("shape.recognize", params)
        XCTAssertEqual(alone["shape"], "line")
        XCTAssertEqual(alone["mergeWith"], [])
    }

    func testRecognizeSnapsToTheShapesOfAPage() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        // The fixture page's rectangle has its top-left corner at (100, 200).
        let value = try await h.run("shape.recognize", ["points": [[104, 203], [180, 320]], "neighbors": .string(pageRef)])
        XCTAssertEqual(value["shape"], "line")
        XCTAssertEqual(value["points"]?[0], [100, 200])
        XCTAssertEqual(value["mergeWith"], [])
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

    func testWithoutShapeCreateTheStrokeStaysInk() async {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(rectangleStroke(h), page: page, host: host)
        await settle { !host.committed.isEmpty }
        XCTAssertEqual(host.committed.count, 1)
    }

    func testJoiningAnExistingLineDeletesItAndCreatesOnePolylineInOneUndoStep() async throws {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        // An existing unlocked line shape on the active layer, added through a test command.
        h.app.commands.register(CommandDescriptor(id: "test.addLine", title: "Add line", summary: "Test helper.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in
                var item = Item.makeShape(ShapeRecognizer.pointShape(.line, [Point(300, 300), Point(400, 300)]))
                item.id = NibID("OLDLINE00001")
                _ = try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return [:]
        }
        _ = try await h.run("test.addLine")
        let calls = Calls()
        let created = expectation(description: "shape.create")
        standIn(CommandIDs.shapeCreate, h, calls, created)
        standIn(ShapeCommit.deleteCommand, h, calls)
        let host = FakeCanvasHost(h)
        DrawShapeTool().strokeFinished(stroke(Geo.resample([Point(402, 305), Point(402, 400)], count: 30), h), page: page, host: host)
        await fulfillment(of: [created], timeout: 5)
        XCTAssertEqual(calls.params[ShapeCommit.deleteCommand]?["refs"], ["item:FIXTUREDOC01/FIXTUREPG001/OLDLINE00001"])
        let p = try XCTUnwrap(calls.params[CommandIDs.shapeCreate])
        XCTAssertEqual(p["shape"], "polyline")
        assertPoints(p["points"], [Point(300, 300), Point(400, 300), Point(402, 400)])
        XCTAssertNotNil(calls.groups[CommandIDs.shapeCreate])
        XCTAssertEqual(calls.groups[CommandIDs.shapeCreate], calls.groups[ShapeCommit.deleteCommand])
    }

    func testSnappingEmitsAnEvent() {
        let h = Harness(features: [FeatShapeRecognitionFeature.self])
        let before = h.app.events.lastSeq
        let host = FakeCanvasHost(h)
        XCTAssertTrue(DrawShapeTool().strokeHeld(rectangleStroke(h), page: page, host: host))
        let snapped = h.app.events.events(since: before).filter { $0.type == ShapeRecognitionEvents.snapped }
        XCTAssertEqual(snapped.count, 1)
        XCTAssertEqual(snapped.first?.payload?["shape"], "rectangle")
        XCTAssertEqual(snapped.first?.payload?["page"], .string(pageRef))
    }

    func testCreateParamsSendUprightFramesAndPoints() {
        let box = ShapeItem(shape: .ellipse, frame: Frame(x: 10, y: 20, w: 30, h: 40, rotation: 0.4))
        let boxParams = ShapeCommit.createParams(box, page: pageRef)
        XCTAssertEqual(boxParams["frame"], [10, 20, 30, 40])
        XCTAssertNil(boxParams["points"])
        let arrow = ShapeRecognizer.pointShape(.arrow, [Point(1, 2), Point(3, 4)])
        let arrowParams = ShapeCommit.createParams(arrow, page: pageRef)
        XCTAssertEqual(arrowParams["points"], [[1, 2], [3, 4]])
        XCTAssertNil(arrowParams["frame"])
        XCTAssertEqual(arrowParams["shape"], "arrow")
    }
}
