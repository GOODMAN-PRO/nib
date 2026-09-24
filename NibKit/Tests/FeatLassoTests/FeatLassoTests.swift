import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatLasso

@MainActor
final class FeatLassoTests: XCTestCase {
    private var pageRef: String { "page:FIXTUREDOC01/FIXTUREPG001" }

    private func harness() -> Harness { Harness(features: [FeatLassoFeature.self]) }

    private func ref(_ id: ElementID) -> String { NodeRef.item(Fixtures.docID, Fixtures.page1, id).description }

    private func refs(_ value: JSONValue) -> Set<String> {
        Set(value["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
    }

    private func polygon(_ points: [(Double, Double)], include: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["page": .string(pageRef),
                                      "polygon": .array(points.map { JSONValue.array([.number($0.0), .number($0.1)]) })]
        if let include = include { o["include"] = .array(include.map { JSONValue.string($0) }) }
        return .object(o)
    }

    private func sample(_ x: Double, _ y: Double) -> CanvasSample {
        CanvasSample(page: Fixtures.page1, location: Point(x, y))
    }

    /// Replaces fixture items before the workspace first loads the page (the Harness loads pages lazily).
    private func editFixturePage(_ h: Harness, _ edit: (inout [Item]) -> Void) {
        var items = h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1] ?? []
        edit(&items)
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page1] = items
    }

    // MARK: Conformance

    func testFeatureID() {
        XCTAssertEqual(FeatLassoFeature.id, "lasso")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLassoFeature.self], owners: [FeatLassoFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersToolToolbarAttachmentTapHandlerAndSettings() {
        let h = harness()
        XCTAssertNotNil(h.app.ui.canvasTools.get("lasso"))
        let item = h.app.ui.toolbar.get("lasso")
        XCTAssertEqual(item?.group, .lasso)
        XCTAssertEqual(item?.toolID, "lasso")
        XCTAssertEqual(item?.shortcut, KeyShortcut("v"))
        XCTAssertEqual(item?.hideable, false)
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("lasso.selection"))
        let tap = h.app.content.tapHandlers.get("selection.tapAt")
        XCTAssertEqual(tap?.order, 400)
        XCTAssertEqual(tap?.gesture, .tap)
        XCTAssertEqual(tap?.command, "selection.tapAt")
        XCTAssertNotNil(h.app.settings.descriptor("lasso.type"))
        XCTAssertNotNil(h.app.settings.descriptor("lasso.include"))
        for id in ["selection.set", "selection.clear", "selection.fromPolygon", "selection.fromRect", "selection.fromLoop",
                   "selection.selectAll", "selection.tapAt"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "lasso", id)
        }
    }

    // MARK: Polygon selection on the fixture items

    func testPolygonSelectsEveryItemItTouches() async throws {
        let h = harness()
        // A band across the top: it crosses the stroke (y ≈ 120) and the sticky note's top edge, nothing else.
        let band = try await h.run("selection.fromPolygon", polygon([(60, 110), (560, 110), (560, 130), (60, 130)]))
        XCTAssertEqual(refs(band), [ref(Fixtures.strokeID), ref(Fixtures.stickyID)])
        XCTAssertEqual(Set(h.session.selection.items), [Fixtures.strokeID, Fixtures.stickyID])
        XCTAssertEqual(h.session.selection.doc, Fixtures.docID)
        XCTAssertEqual(h.session.selection.page, Fixtures.page1)

        // The whole page touches all ten fixture items (every kind).
        let all = try await h.run("selection.fromPolygon", polygon([(0, 0), (595, 0), (595, 842), (0, 842)]))
        XCTAssertEqual(all["count"]?.intValue, 10)

        // A lasso drawn inside the image still touches it.
        let inside = try await h.run("selection.fromPolygon", polygon([(330, 490), (370, 490), (370, 530), (330, 530)]))
        XCTAssertEqual(refs(inside), [ref(Fixtures.imageID)])
        let bounds = try XCTUnwrap(h.session.selection.bounds)
        XCTAssertEqual(bounds, Rect(x: 320, y: 480, width: 64, height: 64))
    }

    func testIncludedInSelectionFilterParamAndSetting() async throws {
        let h = harness()
        let page = [(0.0, 0.0), (595.0, 0.0), (595.0, 842.0), (0.0, 842.0)]
        let filtered = try await h.run("selection.fromPolygon", polygon(page, include: ["images", "text"]))
        XCTAssertEqual(refs(filtered), [ref(Fixtures.imageID), ref(Fixtures.textID)])

        try await h.run("settings.set", ["name": "lasso.include", "value": ["tape", "comments"]])
        let fromSetting = try await h.run("selection.fromPolygon", polygon(page))
        XCTAssertEqual(refs(fromSetting), [ref(Fixtures.tapeID), ref(Fixtures.commentID)])

        do {
            try await h.run("selection.fromPolygon", polygon(page, include: ["crayons"]))
            XCTFail("an unknown category must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.include[0]")
        }
    }

    func testActiveLayerOnlyAndLockedItemsSelectable() async throws {
        let h = harness()
        editFixturePage(h) { items in
            for i in items.indices where items[i].id == Fixtures.imageID { items[i].locked = true }
            for i in items.indices where items[i].id == Fixtures.mathID { items[i].layer = 2 }
        }
        let area = polygon([(60, 470), (400, 470), (400, 560), (60, 560)])   // covers the maths item and the image
        let onBase = try await h.run("selection.fromPolygon", area)
        XCTAssertEqual(refs(onBase), [ref(Fixtures.imageID)], "the locked image is selectable; maths is on layer 2")

        h.session.activeLayer = 2
        let onTwo = try await h.run("selection.fromPolygon", area)
        XCTAssertEqual(refs(onTwo), [ref(Fixtures.mathID)])
        let all = try await h.run("selection.selectAll", ["page": .string(pageRef)])
        XCTAssertEqual(all["count"]?.intValue, 1)
    }

    func testRectSetSelectAllAndClear() async throws {
        let h = harness()
        let rect = try await h.run("selection.fromRect", ["page": .string(pageRef), "rect": [400, 570, -100, -100]])
        XCTAssertEqual(refs(rect), [ref(Fixtures.imageID)], "a rect dragged up-left is normalised")

        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.shapeID)), .string(ref(Fixtures.textID))]])
        XCTAssertEqual(h.session.selection.items, [Fixtures.shapeID, Fixtures.textID])

        let all = try await h.run("selection.selectAll", ["page": .string(pageRef)])
        XCTAssertEqual(all["count"]?.intValue, 10)

        try await h.run("selection.clear")
        XCTAssertTrue(h.session.selection.isEmpty)

        do {
            try await h.run("selection.set", ["refs": [.string(ref(Fixtures.shapeID)),
                                                       "item:FIXTUREDOC01/FIXTUREPG002/FIXTURESHP01"]])
            XCTFail("items on two pages must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            try await h.run("selection.set", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/NOSUCHITEM01"]])
            XCTFail("a missing item must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    // MARK: Circle to Lasso

    func testFromLoopDeletesTheLoopSelectsWhatItTouchesAndUndoRestoresIt() async throws {
        let h = harness()
        let loopID: ElementID = "LOOPSTROKE01"
        // An ellipse around the maths item and the image, clear of the text box above and the tape below.
        let pts: [StrokePoint] = (0...48).map { (k: Int) -> StrokePoint in
            let a = Double(k) / 48 * 2 * Double.pi
            return StrokePoint(x: Float(228 + 170 * cos(a)), y: Float(512 + 50 * sin(a)))
        }
        editFixturePage(h) { items in
            items.append(Item(id: loopID, kind: .stroke, z: "zz", stroke: Stroke(style: .defaultPen, points: pts)))
        }
        h.session.tool = "pen"
        let before = try h.snapshot()

        let r = try await h.run("selection.fromLoop", ["page": .string(pageRef), "stroke": .string(ref(loopID))])
        XCTAssertEqual(refs(r), [ref(Fixtures.mathID), ref(Fixtures.imageID)])
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).contains { $0.id == loopID })
        XCTAssertEqual(h.session.tool, "lasso")
        XCTAssertNotNil(SelectionOutlines.bySession[h.session.id])

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before, "undo restores the loop stroke")

        try await h.run("selection.clear")
        XCTAssertEqual(h.session.tool, "pen", "Circle to Lasso hands back the pen when the selection ends")
    }

    // MARK: Quick selection (tap)

    func testTapSelectsTopObjectSwitchesToLassoAndTapElsewhereReturns() async throws {
        let h = harness()
        h.session.tool = "pen"
        let onImage = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [352, 512], "gesture": "tap"])
        XCTAssertEqual(onImage["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.selection.items, [Fixtures.imageID])
        XCTAssertEqual(h.session.tool, "lasso")

        let elsewhere = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [300, 800]])
        XCTAssertEqual(elsewhere["handled"]?.boolValue, true)
        XCTAssertTrue(h.session.selection.isEmpty)
        XCTAssertEqual(h.session.tool, "pen")

        let empty = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [300, 800]])
        XCTAssertEqual(empty["handled"]?.boolValue, false, "nothing to select or clear: the tool gets the tap")

        let onInk = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [100, 121]])
        XCTAssertEqual(onInk["handled"]?.boolValue, false, "quick selection skips ink")

        try await h.run("settings.set", ["name": "editing.objectTapSelection", "value": false])
        let off = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [352, 512]])
        XCTAssertEqual(off["handled"]?.boolValue, false)
        XCTAssertTrue(h.session.selection.isEmpty)
    }

    func testTapWithTheLassoSelectsInkAndTheTextToolKeepsTextBoxes() async throws {
        let h = harness()
        h.session.tool = "lasso"
        let onInk = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [100, 121]])
        XCTAssertEqual(onInk["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.selection.items, [Fixtures.strokeID])

        try await h.run("selection.clear")
        h.session.tool = "text"
        let onText = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [200, 420]])
        XCTAssertEqual(onText["handled"]?.boolValue, false)
        XCTAssertTrue(h.session.selection.isEmpty)
    }

    // MARK: Housekeeping (start)

    func testHousekeepingFollowsMovesClearsDeletionsAndTracksTheToolbarGlyph() async throws {
        let h = harness()
        h.app.commands.register(TestNudge.self)
        h.app.commands.register(TestDelete.self)
        LassoHousekeeping.start(h.app)

        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.imageID))]])
        try await h.run("test.nudge", ["id": "FIXTUREIMG01", "dx": 10])
        XCTAssertEqual(h.session.selection.bounds, Rect(x: 330, y: 480, width: 64, height: 64), "bounds follow a move")
        try await h.run("test.delete", ["id": "FIXTUREIMG01"])
        XCTAssertTrue(h.session.selection.isEmpty, "a deleted item leaves the selection")

        h.session.tool = "pen"
        try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [122, 725]])   // the custom item
        XCTAssertEqual(h.session.tool, "lasso")
        h.session.tool = "eraser"
        XCTAssertNil(h.session.toolOptions["lasso"], "picking another tool forgets the return tool")
        try await h.run("selection.clear")
        XCTAssertEqual(h.session.tool, "eraser")

        XCTAssertEqual(h.app.ui.toolbar.get("lasso")?.icon, "lasso")
        try await h.run("settings.set", ["name": "lasso.type", "value": "rectangle"])
        XCTAssertEqual(h.app.ui.toolbar.get("lasso")?.icon, "rectangle.dashed")
    }

    // MARK: The tool

    func testFreehandAndRectangleGesturesSelect() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let tool = LassoTool()
        tool.activate(host)

        tool.touchesBegan(sample(90, 190), host: host)
        tool.touchesMoved([sample(270, 190), sample(270, 300), sample(90, 300)], host: host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count, 1, "the marquee is drawn while dragging")
        tool.touchesEnded(sample(90, 195), host: host)
        await tool.pending?.value
        XCTAssertEqual(Set(h.session.selection.items), [Fixtures.shapeID, Fixtures.connectorID])
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true, "the marquee is removed on lift")

        try await h.run("settings.set", ["name": "lasso.type", "value": "rectangle"])
        tool.touchesBegan(sample(300, 470), host: host)
        tool.touchesMoved([sample(350, 520)], host: host)
        tool.touchesEnded(sample(400, 570), host: host)
        await tool.pending?.value
        XCTAssertEqual(h.session.selection.items, [Fixtures.imageID])

        tool.tap(sample(300, 800), host: host)
        await tool.pending?.value
        XCTAssertTrue(h.session.selection.isEmpty, "a tap on empty paper deselects")
    }

    // MARK: The overlay

    func testOverlayDrawsTheOutlineAndBoundsAndFollowsTheSelection() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let overlay = SelectionOverlay()
        overlay.attach(to: host)
        XCTAssertTrue(overlay.view.superview === host.canvasView)
        XCTAssertNil(overlay.view.content)

        try await h.run("selection.fromPolygon", polygon([(330, 490), (370, 490), (370, 530), (330, 530)]))
        overlay.canvasDidChange(host)
        let drawn = try XCTUnwrap(overlay.view.content)
        XCTAssertEqual(drawn.box, CGRect(x: 320, y: 480, width: 64, height: 64))
        XCTAssertTrue(drawn.drawsBox)
        XCTAssertTrue(overlay.view.isAccessibilityElement)

        host.zoomScale = 2
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.view.content?.box, CGRect(x: 640, y: 960, width: 128, height: 128))

        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.shapeID))]])
        XCTAssertEqual(overlay.view.content?.drawsBox, false, "a by-ref selection draws a dashed box, not a lasso")

        try await h.run("selection.clear")
        XCTAssertNil(overlay.view.content)
        XCTAssertFalse(overlay.view.isAccessibilityElement)
        overlay.detach(from: host)
        XCTAssertNil(overlay.view.superview)
    }

    // MARK: Geometry

    func testLineTouchesAgreesWithGeoPolylineTouchesPolygon() {
        var rng = SeededGenerator(seed: 0x5EED)
        for _ in 0..<3000 {
            let n = Int.random(in: 3...12, using: &rng)
            let cx = Double.random(in: 100...300, using: &rng), cy = Double.random(in: 100...300, using: &rng)
            let poly = (0..<n).map { (k: Int) -> Point in
                let a = Double(k) / Double(n) * 2 * Double.pi
                let r = Double.random(in: 20...120, using: &rng)
                return Point(cx + r * cos(a), cy + r * sin(a))
            }
            let line = (0..<Int.random(in: 1...8, using: &rng)).map { _ in
                Point(Double.random(in: 0...400, using: &rng), Double.random(in: 0...400, using: &rng))
            }
            let prepared = LassoPolygon(poly)
            XCTAssertNotNil(prepared)
            guard let prepared = prepared else { return }
            XCTAssertEqual(LassoGeometry.lineTouches(line, prepared), Geo.polylineTouchesPolygon(line, poly),
                           "line \(line) polygon \(poly)")
        }
    }

    func testTapHitTestHonoursRotation() {
        let frame = Frame(x: 100, y: 100, w: 200, h: 20, rotation: Double.pi / 2)   // stands upright about (200, 110)
        XCTAssertTrue(LassoGeometry.frameContains(frame, Point(200, 190), margin: 0))
        XCTAssertFalse(LassoGeometry.frameContains(frame, Point(290, 110), margin: 0))
    }

    func testHitTestOverFiveThousandStrokesStaysInBudget() {
        let items: [Item] = (0..<5000).map { (i: Int) -> Item in
            let x = Double(i % 50) * 11 + 20, y = Double(i / 50) * 8 + 20
            let pts = (0..<20).map { (k: Int) -> StrokePoint in
                StrokePoint(x: Float(x + Double(k) * 0.4), y: Float(y + Double(k % 3)), width: 1.2, height: 1.2)
            }
            return Item.makeStroke(Stroke(style: .defaultPen, points: pts, t0: 0))
        }
        let lasso = (0..<72).map { (k: Int) -> Point in
            let a = Double(k) / 72 * 2 * Double.pi
            return Point(300 + 200 * cos(a), 420 + 200 * sin(a))
        }
        let everything = Set(LassoCategory.allCases)
        var best = Double.infinity
        var count = 0
        for _ in 0..<3 {
            let start = Date()
            count = SelectionEngine.select(items, polygon: lasso, include: everything, layer: 0).count
            best = min(best, Date().timeIntervalSince(start))
        }
        XCTAssertGreaterThan(count, 500)
        XCTAssertLessThan(count, 5000)
        XCTAssertLessThan(best, 0.016 * 4, "ARCHITECTURE §20: lasso hit test over 5k strokes < 16 ms (×4 in CI)")
    }
}

/// Test-only stand-ins for F012's move and F013's delete on the fixture page.
private struct TestNudge: NibCommand {
    struct Params: Codable {
        var id: String
        var dx: Double
    }

    static let descriptor = CommandDescriptor(id: "test.nudge", title: "Nudge",
                                              summary: "Move a fixture item right (test stand-in).", effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in
            let item = try tx.item(Fixtures.docID, page: Fixtures.page1, id: NibID(p.id))
            try tx.put(item.transformed(by: .translation(p.dx, 0)), doc: Fixtures.docID, page: Fixtures.page1)
        }
        return NoResult()
    }
}

private struct TestDelete: NibCommand {
    struct Params: Codable {
        var id: String
    }

    static let descriptor = CommandDescriptor(id: "test.delete", title: "Delete",
                                              summary: "Delete a fixture item (test stand-in).", effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in try tx.delete(item: NibID(p.id), doc: Fixtures.docID, page: Fixtures.page1) }
        return NoResult()
    }
}

/// Deterministic xorshift generator, so the geometry comparison is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
