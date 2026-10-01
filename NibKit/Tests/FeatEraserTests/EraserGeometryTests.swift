import XCTest
import NibContracts
@testable import FeatEraser

final class EraserGeometryTests: XCTestCase {
    private let pen = InkStyle(tool: .pen, pen: .ball, width: 2)

    /// A horizontal stroke from x0 to x1 at y, one point every `step`, rendered `width` wide.
    private func line(_ x0: Float, _ x1: Float, y: Float = 50, step: Float = 1, width: Float = 2) -> [StrokePoint] {
        stride(from: x0, through: x1, by: step).enumerated().map { i, x in
            StrokePoint(x: x, y: y, t: Float(i) * 0.01, width: width, height: width)
        }
    }

    private func strokeItem(_ id: String, y: Float, tool: InkTool = .pen, layer: Int = 0, locked: Bool = false,
                            attachedTo: ElementID? = nil) -> Item {
        let style = InkStyle(tool: tool, pen: tool == .pen ? .ball : nil, width: 2)
        return Item(id: NibID(id), kind: .stroke, z: "V", layer: layer, locked: locked, attachedTo: attachedTo,
                    stroke: Stroke(style: style, points: line(0, 100, y: y), t0: 1))
    }

    // MARK: Capsule primitives

    func testCapsuleIntervalCoversSlabAndEndDisks() throws {
        // A vertical capsule across the middle of a horizontal segment: x in [4, 6].
        let across = try XCTUnwrap(EraserGeometry.capsuleInterval(Point(0, 0), Point(10, 0), Point(5, -5), Point(5, 5), radius: 1))
        XCTAssertEqual(across.0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(across.1, 0.6, accuracy: 1e-9)
        // A parallel capsule 3 away with radius 1 misses.
        XCTAssertNil(EraserGeometry.capsuleInterval(Point(0, 0), Point(10, 0), Point(0, 3), Point(10, 3), radius: 1))
        // Only the round end of a capsule to the right reaches the segment's last 1 pt.
        let end = try XCTUnwrap(EraserGeometry.capsuleInterval(Point(0, 0), Point(10, 0), Point(12, 0), Point(20, 0), radius: 3))
        XCTAssertEqual(end.0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(end.1, 1, accuracy: 1e-9)
        // A point eraser is a disk.
        let dot = try XCTUnwrap(EraserGeometry.capsuleInterval(Point(0, 0), Point(10, 0), Point(5, 0), Point(5, 0), radius: 2))
        XCTAssertEqual(dot.0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(dot.1, 0.7, accuracy: 1e-9)
    }

    // MARK: Modes

    func testStandardRemovesTheTouchedRunAndSplitsInTwo() throws {
        let pts = line(0, 100)
        let pieces = try XCTUnwrap(EraserGeometry.cut(pts, style: pen, from: Point(50, 50), to: Point(50, 50), radius: 5, mode: .standard))
        // Reach = radius 5 + half the 2 pt nib: points 44…56 go.
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].first?.x, 0)
        XCTAssertEqual(pieces[0].last?.x, 43)
        XCTAssertEqual(pieces[1].first?.x, 57)
        XCTAssertEqual(pieces[1].last?.x, 100)
        // Cut ends are tripled so the spline ends on them; the stroke's own ends are left alone.
        XCTAssertEqual(pieces[0].suffix(3).map { $0.x }, [43, 43, 43])
        XCTAssertEqual(pieces[1].prefix(3).map { $0.x }, [57, 57, 57])
        XCTAssertNotEqual(pieces[0][1].x, 0)
        XCTAssertTrue(pieces.joined().allSatisfy { $0.width == 2 && $0.height == 2 }, "widths are kept")
    }

    func testStandardSplitsACrossedSegmentEvenWithNoPointInside() throws {
        let xs: [Float] = [0, 30, 60, 90]
        let sparse = xs.map { StrokePoint(x: $0, y: 0, width: 2, height: 2) }
        let pieces = try XCTUnwrap(EraserGeometry.cut(sparse, style: pen, from: Point(45, 0), to: Point(45, 0), radius: 5, mode: .standard))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].last?.x, 30)
        XCTAssertEqual(pieces[1].first?.x, 60)
    }

    func testPrecisionCutsAtTheCircleWithInterpolatedPoints() throws {
        let sparse = [0, 30, 60, 90].enumerated().map { i, x in
            StrokePoint(x: Float(x), y: 0, t: Float(i) * 0.3, force: Float(i) * 0.2, width: 2, height: 2)
        }
        let pieces = try XCTUnwrap(EraserGeometry.cut(sparse, style: pen, from: Point(45, 0), to: Point(45, 0), radius: 5, mode: .precision))
        // The nib's round cap ends on the eraser circle: centre-line cuts at 45 ± (5 + 1).
        XCTAssertEqual(pieces.count, 2)
        let cutEnd = try XCTUnwrap(pieces[0].last)
        let cutStart = try XCTUnwrap(pieces[1].first)
        XCTAssertEqual(cutEnd.x, 39, accuracy: 1e-3)
        XCTAssertEqual(cutStart.x, 51, accuracy: 1e-3)
        XCTAssertEqual(cutEnd.t, 0.39, accuracy: 1e-4, "time is interpolated (Note Replay)")
        XCTAssertEqual(cutEnd.force, 0.26, accuracy: 1e-4, "pressure is interpolated")
        XCTAssertEqual(pieces[0].map { $0.x }, [0, 30, cutEnd.x, cutEnd.x, cutEnd.x])
        XCTAssertEqual(pieces[1].map { $0.x }, [cutStart.x, cutStart.x, cutStart.x, 60, 90])
        XCTAssertTrue(pieces.joined().allSatisfy { $0.width == 2 }, "widths are kept")
    }

    func testPrecisionSweepCutsWhereThePathCrossesAndMissesLeaveStrokesAlone() throws {
        let pts = line(0, 100, y: 0)
        let pieces = try XCTUnwrap(EraserGeometry.cut(pts, style: pen, from: Point(50, -20), to: Point(50, 20), radius: 2, mode: .precision))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(Double(try XCTUnwrap(pieces[0].last).x), 47, accuracy: 1e-3)
        XCTAssertEqual(Double(try XCTUnwrap(pieces[1].first).x), 53, accuracy: 1e-3)
        XCTAssertNil(EraserGeometry.cut(pts, style: pen, from: Point(50, 10), to: Point(60, 10), radius: 2, mode: .precision))
        XCTAssertNil(EraserGeometry.cut(pts, style: pen, from: Point(50, 10), to: Point(60, 10), radius: 2, mode: .standard))
    }

    func testErasingAnEndLeavesOnePieceAndErasingEverythingLeavesNone() throws {
        let pts = line(0, 20, y: 0)
        let tail = try XCTUnwrap(EraserGeometry.cut(pts, style: pen, from: Point(20, 0), to: Point(20, 0), radius: 3, mode: .precision))
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(Double(try XCTUnwrap(tail[0].last).x), 16, accuracy: 1e-3)
        let all = try XCTUnwrap(EraserGeometry.cut(pts, style: pen, from: Point(-5, 0), to: Point(25, 0), radius: 3, mode: .standard))
        XCTAssertTrue(all.isEmpty)
    }

    func testStrokeModeRemovesWholeStrokesOrNothing() {
        let pts = line(0, 100)
        XCTAssertEqual(EraserGeometry.cut(pts, style: pen, from: Point(99, 48), to: Point(99, 48), radius: 2, mode: .stroke)?.count, 0)
        XCTAssertNil(EraserGeometry.cut(pts, style: pen, from: Point(50, 60), to: Point(50, 70), radius: 2, mode: .stroke))
        // A single-point dot goes when touched.
        let dot = [StrokePoint(x: 10, y: 10, width: 4, height: 4)]
        XCTAssertEqual(EraserGeometry.cut(dot, style: pen, from: Point(14, 10), to: Point(14, 10), radius: 3, mode: .precision)?.count, 0)
    }

    // MARK: Session: scoping, shapes, plan

    func testSessionScopesToFilterLayerUnlockedAndShapesWithoutChildren() {
        var box = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 40, y: 60, w: 20, h: 20)))
        box.id = "BOX"
        var label = Item.makeText(TextBoxItem(frame: Frame(x: 42, y: 62, w: 10, h: 10), text: RichText(plain: "A")))
        label.id = "LABEL"
        label.attachedTo = box.id
        var ring = Item.makeShape(ShapeItem(shape: .ellipse, frame: Frame(x: 30, y: 100, w: 40, h: 40)))
        ring.id = "RING"
        let items = [strokeItem("PEN", y: 10), strokeItem("HIL", y: 20, tool: .highlighter),
                     strokeItem("LCK", y: 30, locked: true), strokeItem("LAY", y: 40, layer: 1), box, label, ring]

        var ink = EraseSession(items: items, radius: 3, mode: .standard, filter: [.pen, .pencil, .tape], layer: 0)
        ink.extend(to: Point(50, 0))
        ink.extend(to: Point(50, 200))
        XCTAssertEqual(ink.affected, ["PEN", "RING"])
        XCTAssertEqual(ink.pieces["PEN"]?.count, 2)

        var highlighterOnly = EraseSession(items: items, radius: 3, mode: .precision, filter: [.highlighter], layer: 0)
        highlighterOnly.extend(to: Point(50, 0))
        highlighterOnly.extend(to: Point(50, 200))
        XCTAssertEqual(highlighterOnly.affected, ["HIL"])

        var otherLayer = EraseSession(items: items, radius: 3, mode: .stroke, filter: Set(InkTool.allCases), layer: 1)
        otherLayer.extend(to: Point(50, 0))
        otherLayer.extend(to: Point(50, 200))
        XCTAssertEqual(otherLayer.affected, ["LAY"])
        XCTAssertTrue(otherLayer.pieces.isEmpty, "stroke mode keeps no pieces")
    }

    func testPlanReplacesACutStrokeWithPiecesInItsStyle() throws {
        let original = strokeItem("PEN", y: 10)
        var session = EraseSession(items: [original], radius: 2, mode: .precision, filter: [.pen], layer: 0)
        session.extend(to: Point(30, 0))
        session.extend(to: Point(30, 20))
        session.extend(to: Point(70, 20))
        session.extend(to: Point(70, 0))
        let plan = session.plan
        XCTAssertEqual(plan.remove, ["PEN"])
        let split = try XCTUnwrap(plan.splits.first)
        XCTAssertEqual(split.original.id, "PEN")
        XCTAssertEqual(split.strokes.count, 3)
        XCTAssertTrue(split.strokes.allSatisfy { $0.style == original.stroke?.style && $0.t0 == original.stroke?.t0 })
    }

    func testPrecisionErasingDoesNotDependOnPathDirection() {
        // Erasing removes the union of the eraser's capsules, so the same path walked either way leaves the same ink.
        let original = strokeItem("PEN", y: 10)
        let path = stride(from: 0.0, through: 60.0, by: 3.0).map { Point($0, 10 + sin($0 / 6) * 8) }
        func remaining(_ points: [Point]) -> (count: Int, length: Double) {
            var session = EraseSession(items: [original], radius: 2.5, mode: .precision, filter: [.pen], layer: 0)
            for p in points { session.extend(to: p) }
            let pieces = session.pieces["PEN"] ?? []
            return (pieces.count, pieces.reduce(0.0) { $0 + EraserGeometry.length($1) })
        }
        let forward = remaining(path)
        let backward = remaining(Array(path.reversed()))
        XCTAssertGreaterThan(forward.count, 1)
        XCTAssertEqual(forward.count, backward.count)
        XCTAssertEqual(forward.length, backward.length, accuracy: 1e-3)
        XCTAssertLessThan(forward.length, 100)
    }

    func testShapeOutlinesHitOnTheirEdgeAndFilledShapesInside() throws {
        let hollow = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 100, h: 100)))
        let filled = Item.makeShape(ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 100, h: 100),
                                              style: ShapeItemStyle(fillColor: .black)))
        let hollowOutline = try XCTUnwrap(EraserGeometry.outline(hollow))
        let filledOutline = try XCTUnwrap(EraserGeometry.outline(filled))
        XCTAssertFalse(EraserGeometry.hits(hollowOutline, from: Point(50, 50), to: Point(50, 50), radius: 5))
        XCTAssertTrue(EraserGeometry.hits(filledOutline, from: Point(50, 50), to: Point(50, 50), radius: 5))
        XCTAssertTrue(EraserGeometry.hits(hollowOutline, from: Point(50, 50), to: Point(50, 104), radius: 2))
        // A rotated triangle's apex is where the rotation puts it.
        let tri = Item.makeShape(ShapeItem(shape: .triangle, frame: Frame(x: 0, y: 0, w: 20, h: 20, rotation: Double.pi)))
        let apex = try XCTUnwrap(EraserGeometry.outline(tri)?.points.first)
        XCTAssertEqual(apex.x, 10, accuracy: 1e-9)
        XCTAssertEqual(apex.y, 20, accuracy: 1e-9)
    }

    // MARK: Scribble to Erase

    func testScribbleCoversTheWordUnderItButNotALongLineItCrosses() {
        let scribble = [Point(0, 0), Point(40, 2), Point(0, 6), Point(40, 8), Point(0, 12)]
        let hull = EraserGeometry.convexHull(scribble)
        XCTAssertEqual(hull.count, 4)
        let word = Stroke(style: pen, points: (0...30).map { StrokePoint(x: Float(5 + $0), y: Float(4 + $0 % 5)) })
        XCTAssertTrue(EraserGeometry.scribbleCovers(word, hull: hull))
        let rule = Stroke(style: pen, points: (0...240).map { StrokePoint(x: Float(-100 + $0), y: 6) })
        XCTAssertFalse(EraserGeometry.scribbleCovers(rule, hull: hull))
        let far = Stroke(style: pen, points: [StrokePoint(x: 200, y: 200), StrokePoint(x: 210, y: 200)])
        XCTAssertFalse(EraserGeometry.scribbleCovers(far, hull: hull))
    }
}
