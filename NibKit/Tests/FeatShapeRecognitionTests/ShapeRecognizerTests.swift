import XCTest
import NibContracts
@testable import FeatShapeRecognition

/// Deterministic strokes for the recogniser: SplitMix64 + Box–Muller, shapes of 60–360 pt with Gaussian jitter
/// σ = 2 % of their size on every sample, random start points, directions and small closing gaps or overshoots.
/// The recogniser's thresholds were tuned against exactly this generator (see ShapeRecognizer.Threshold).
struct SeededStrokes {
    enum Kind { case circle, rectangle, triangle, line, arrow, scribble }

    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ a: Double = 0, _ b: Double = 1) -> Double {
        a + (b - a) * (Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0))
    }

    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    mutating func coin() -> Bool { next() & 1 == 1 }

    mutating func stroke(_ kind: Kind) -> [Point] {
        let size = uniform(60, 360)
        let cx = uniform(100, 500)
        let cy = uniform(100, 700)
        let sigma = 0.02 * size
        var reverse = coin()
        var pts: [Point] = []
        switch kind {
        case .circle:
            let r = size / 2
            let a0 = uniform(0, 2 * Double.pi)
            let sweep = 2 * Double.pi * (1 + uniform(-0.04, 0.08))
            for k in 0..<96 {
                let a = a0 + sweep * Double(k) / 95
                pts.append(Point(cx + r * cos(a), cy + r * sin(a)))
            }
        case .rectangle:
            var w = size
            var h = size * uniform(0.35, 1.0)
            if coin() { swap(&w, &h) }
            let tilt = uniform(-30, 30) * Double.pi / 180
            let c = Point(cx, cy)
            let corners = [Point(cx - w / 2, cy - h / 2), Point(cx + w / 2, cy - h / 2),
                           Point(cx + w / 2, cy + h / 2), Point(cx - w / 2, cy + h / 2)].map { Self.rotate($0, tilt, about: c) }
            let overshoot = uniform(-0.03, 0.06)
            pts = Geo.resample(loop(corners, overshoot: overshoot), count: 100)
        case .triangle:
            let t1 = uniform(0, 2 * Double.pi)
            let t2 = t1 + uniform(95, 140) * Double.pi / 180
            let t3 = t2 + uniform(95, 140) * Double.pi / 180
            let r = size / 2
            let corners = [t1, t2, t3].map { Point(cx + r * cos($0), cy + r * sin($0)) }
            let overshoot = uniform(-0.03, 0.06)
            pts = Geo.resample(loop(corners, overshoot: overshoot), count: 100)
        case .line:
            let a = uniform(0, 2 * Double.pi)
            pts = Geo.resample([Point(cx - size / 2 * cos(a), cy - size / 2 * sin(a)),
                                Point(cx + size / 2 * cos(a), cy + size / 2 * sin(a))], count: 80)
        case .arrow:
            let a = uniform(0, 2 * Double.pi)
            let tail = Point(cx - size / 2 * cos(a), cy - size / 2 * sin(a))
            let tip = Point(cx + size / 2 * cos(a), cy + size / 2 * sin(a))
            let barb = size * uniform(0.2, 0.35)
            let spread = uniform(25, 40) * Double.pi / 180
            let back = a + Double.pi
            let h1 = Point(tip.x + barb * cos(back + spread), tip.y + barb * sin(back + spread))
            let h2 = Point(tip.x + barb * cos(back - spread), tip.y + barb * sin(back - spread))
            pts = Geo.resample([tail, tip, h1, tip, h2], count: 110)
            reverse = false
        case .scribble:
            let k = Int(uniform(6, 13))
            var waypoints: [Point] = []
            if coin() {
                // Random waypoints joined by a Catmull–Rom spline.
                for _ in 0..<k {
                    let x = cx + uniform(-size / 2, size / 2)
                    let y = cy + uniform(-size / 2, size / 2)
                    waypoints.append(Point(x, y))
                }
                pts = Self.catmullRom(waypoints, perSegment: 12)
            } else {
                // Back-and-forth hatching that drifts sideways.
                let a = uniform(0, Double.pi)
                for i in 0..<k {
                    let off = (Double(i) / Double(k - 1) - 0.5) * size * uniform(0.3, 1.0)
                    let side = i % 2 == 0 ? size / 2 : -size / 2
                    let x = cx + side * uniform(0.6, 1.0)
                    waypoints.append(Self.rotate(Point(x, cy + off), a, about: Point(cx, cy)))
                }
                pts = Self.catmullRom(waypoints, perSegment: 10)
            }
            pts = Geo.resample(pts, count: 120)
            reverse = false
        }
        var noisy: [Point] = []
        for p in pts {
            let x = p.x + gauss() * sigma
            let y = p.y + gauss() * sigma
            noisy.append(Point(x, y))
        }
        return reverse ? noisy.reversed() : noisy
    }

    /// Walks the closed polygon from a random point for (1 + overshoot) turns.
    private mutating func loop(_ corners: [Point], overshoot: Double) -> [Point] {
        let n = corners.count
        var perimeter = 0.0
        for i in 0..<n { perimeter += corners[i].distance(to: corners[(i + 1) % n]) }
        let start = uniform(0, perimeter)
        let total = perimeter * (1 + overshoot)
        var out: [Point] = []
        for k in 0...400 {
            let s = (start + total * Double(k) / 400).truncatingRemainder(dividingBy: perimeter)
            var acc = 0.0
            for i in 0..<n {
                let a = corners[i], b = corners[(i + 1) % n]
                let length = a.distance(to: b)
                if acc + length >= s {
                    let t = (s - acc) / length
                    out.append(Point(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)))
                    break
                }
                acc += length
            }
        }
        return out
    }

    static func rotate(_ p: Point, _ a: Double, about c: Point) -> Point {
        let x = p.x - c.x, y = p.y - c.y
        return Point(c.x + x * cos(a) - y * sin(a), c.y + x * sin(a) + y * cos(a))
    }

    static func catmullRom(_ w: [Point], perSegment: Int) -> [Point] {
        var out: [Point] = []
        let n = w.count
        for i in 0..<(n - 1) {
            let p0 = w[max(i - 1, 0)], p1 = w[i], p2 = w[i + 1], p3 = w[min(i + 2, n - 1)]
            for s in 0..<perSegment {
                let t = Double(s) / Double(perSegment), t2 = t * t, t3 = t2 * t
                func axis(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(Point(axis(p0.x, p1.x, p2.x, p3.x), axis(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(w[n - 1])
        return out
    }
}

final class ShapeRecognizerTests: XCTestCase {
    // MARK: Acceptance: seeded generator, σ = 2 %, N = 200 per class

    func testSeededStrokesAreClassifiedAndScribblesRejected() {
        var gen = SeededStrokes(seed: 0x5EED_F030)
        let n = 200
        func hits(_ kind: SeededStrokes.Kind, _ correct: (ShapeItem?) -> Bool) -> Int {
            var count = 0
            for _ in 0..<n {
                let shape = ShapeRecognizer.recognize(gen.stroke(kind))?.shape
                if correct(shape) { count += 1 }
            }
            return count
        }
        let circles = hits(.circle) { $0?.shape == .ellipse && abs(($0?.frame.w ?? 0) - ($0?.frame.h ?? 1)) < 1e-9 }
        let rectangles = hits(.rectangle) { $0?.shape == .rectangle }
        let triangles = hits(.triangle) { $0?.shape == .triangle || ($0?.shape == .polygon && $0?.points.count == 3) }
        let lines = hits(.line) { $0?.shape == .line }
        let arrows = hits(.arrow) { $0?.shape == .arrow && $0?.style.arrowEnd == true }
        let rejected = hits(.scribble) { $0 == nil }
        let needed = n * 95 / 100
        XCTAssertGreaterThanOrEqual(circles, needed, "circles: \(circles)/\(n)")
        XCTAssertGreaterThanOrEqual(rectangles, needed, "rectangles: \(rectangles)/\(n)")
        XCTAssertGreaterThanOrEqual(triangles, needed, "triangles: \(triangles)/\(n)")
        XCTAssertGreaterThanOrEqual(lines, needed, "lines: \(lines)/\(n)")
        XCTAssertGreaterThanOrEqual(arrows, needed, "arrows: \(arrows)/\(n)")
        XCTAssertGreaterThanOrEqual(rejected, needed, "scribbles rejected: \(rejected)/\(n)")
    }

    // MARK: Geometry of the clean shapes

    private func closed(_ corners: [Point], count: Int = 120) -> [Point] {
        Geo.resample(corners + [corners[0]], count: count)
    }

    func testUprightRectangleKeepsItsFrame() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(closed([Point(100, 100), Point(300, 100), Point(300, 220), Point(100, 220)])))
        XCTAssertEqual(r.shape.shape, .rectangle)
        XCTAssertEqual(r.shape.frame.x, 100, accuracy: 0.5)
        XCTAssertEqual(r.shape.frame.y, 100, accuracy: 0.5)
        XCTAssertEqual(r.shape.frame.w, 200, accuracy: 0.5)
        XCTAssertEqual(r.shape.frame.h, 120, accuracy: 0.5)
        XCTAssertEqual(r.shape.frame.rotation, 0)
        XCTAssertEqual(r.shape.style.cornerRadius, 0)
        XCTAssertGreaterThan(r.confidence, 0.9)
    }

    func testNearSquareSnapsToSquare() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(closed([Point(50, 50), Point(200, 50), Point(200, 192), Point(50, 192)])))
        XCTAssertEqual(r.shape.shape, .rectangle)
        XCTAssertEqual(r.shape.frame.w, r.shape.frame.h)
    }

    func testTiltedRectangleKeepsItsTilt() throws {
        let c = Point(300, 300)
        let tilt = 20 * Double.pi / 180
        let corners = [Point(200, 250), Point(400, 250), Point(400, 350), Point(200, 350)].map { SeededStrokes.rotate($0, tilt, about: c) }
        let r = try XCTUnwrap(ShapeRecognizer.recognize(closed(corners)))
        XCTAssertEqual(r.shape.shape, .rectangle)
        XCTAssertEqual(r.shape.frame.rotation, tilt, accuracy: 0.02)
        XCTAssertEqual(r.shape.frame.center.x, 300, accuracy: 0.5)
        XCTAssertEqual(r.shape.frame.w, 200, accuracy: 1)
        XCTAssertEqual(r.shape.frame.h, 100, accuracy: 1)
    }

    func testRoundLoopBecomesCircleAndFlatLoopAnUprightEllipse() throws {
        let circle = (0...64).map { k -> Point in
            let a = 2 * Double.pi * Double(k) / 64
            return Point(200 + 50 * cos(a), 300 + 50 * sin(a))
        }
        let c = try XCTUnwrap(ShapeRecognizer.recognize(circle)).shape
        XCTAssertEqual(c.shape, .ellipse)
        XCTAssertEqual(c.frame.w, c.frame.h)
        XCTAssertEqual(c.frame.w, 100, accuracy: 1)
        XCTAssertEqual(c.frame.center.x, 200, accuracy: 0.5)
        XCTAssertEqual(c.frame.center.y, 300, accuracy: 0.5)

        let flat = (0...64).map { k -> Point in
            let a = 2 * Double.pi * Double(k) / 64
            return Point(300 + 100 * cos(a), 300 + 50 * sin(a))
        }
        let e = try XCTUnwrap(ShapeRecognizer.recognize(flat)).shape
        XCTAssertEqual(e.shape, .ellipse)
        XCTAssertEqual(e.frame.rotation, 0)
        XCTAssertEqual(e.frame.w, 200, accuracy: 2)
        XCTAssertEqual(e.frame.h, 100, accuracy: 2)
    }

    func testIsoscelesTriangleUsesTheFrameTriangle() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(closed([Point(200, 100), Point(300, 260), Point(100, 260)]))).shape
        XCTAssertEqual(r.shape, .triangle)
        XCTAssertEqual(r.frame.rotation, 0)
        XCTAssertEqual(r.frame.x, 100, accuracy: 1)
        XCTAssertEqual(r.frame.y, 100, accuracy: 1)
        XCTAssertEqual(r.frame.w, 200, accuracy: 1)
        XCTAssertEqual(r.frame.h, 160, accuracy: 1)
    }

    func testRightTriangleGetsAnExactRightAngle() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(closed([Point(100, 100), Point(103, 300), Point(260, 297)]))).shape
        XCTAssertEqual(r.shape, .polygon)
        XCTAssertEqual(r.points.count, 3)
        let v = r.points
        let corner = (0..<3).map { i -> Double in
            let a = v[(i + 2) % 3], b = v[i], c = v[(i + 1) % 3]
            let dot = (a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)
            return abs(dot) / (a.distance(to: b) * c.distance(to: b))
        }.min() ?? 1
        XCTAssertEqual(corner, 0, accuracy: 1e-6)
    }

    func testArrowPointsAtItsTipWhicheverEndWasDrawnFirst() throws {
        let tail = Point(100, 300), tip = Point(300, 300)
        let spread = 30 * Double.pi / 180
        let h1 = Point(tip.x - 50 * cos(spread), tip.y - 50 * sin(spread))
        let h2 = Point(tip.x - 50 * cos(spread), tip.y + 50 * sin(spread))
        let stroke = Geo.resample([tail, tip, h1, tip, h2], count: 110)
        for points in [stroke, Array(stroke.reversed())] {
            let r = try XCTUnwrap(ShapeRecognizer.recognize(points)).shape
            XCTAssertEqual(r.shape, .arrow)
            XCTAssertTrue(r.style.arrowEnd)
            XCTAssertEqual(r.points.count, 2)
            XCTAssertEqual(r.points[1].x, 300, accuracy: 2)
            XCTAssertEqual(r.points[0].x, 100, accuracy: 2)
            XCTAssertEqual(r.points[0].y, r.points[1].y, accuracy: 1e-9)
        }
    }

    func testNearlyLevelLineIsStraightened() throws {
        let r = try XCTUnwrap(ShapeRecognizer.recognize(Geo.resample([Point(100, 100), Point(300, 107)], count: 40))).shape
        XCTAssertEqual(r.shape, .line)
        XCTAssertEqual(r.points[0].y, r.points[1].y, accuracy: 1e-9)
        XCTAssertEqual(r.points[1].x - r.points[0].x, 200, accuracy: 1)
    }

    func testArcPassesThroughItsThreePoints() throws {
        let arc = stride(from: 0.0, through: 120.0, by: 4).map { d -> Point in
            Point(200 + 80 * cos(d * Double.pi / 180), 200 + 80 * sin(d * Double.pi / 180))
        }
        let r = try XCTUnwrap(ShapeRecognizer.recognize(arc)).shape
        XCTAssertEqual(r.shape, .arc)
        XCTAssertEqual(r.points.count, 3)
        for p in r.points { XCTAssertEqual(p.distance(to: Point(200, 200)), 80, accuracy: 1) }
        let outline = try XCTUnwrap(ShapeGeometry.outline(r).first)
        let nearest = outline.map { $0.distance(to: r.points[1]) }.min() ?? 99
        XCTAssertLessThan(nearest, 3)
    }

    func testDotsZigzagsAndSinglePointsAreNotShapes() {
        XCTAssertNil(ShapeRecognizer.recognize([Point(10, 10)]))
        XCTAssertNil(ShapeRecognizer.recognize([Point(10, 10), Point(10, 10)]))
        XCTAssertNil(ShapeRecognizer.recognize([Point(10, 10), Point(13, 12), Point(12, 14)]))
        let zigzag = [Point(100, 100), Point(200, 110), Point(105, 125), Point(205, 135), Point(100, 150),
                      Point(210, 160), Point(98, 172), Point(200, 185)]
        XCTAssertNil(ShapeRecognizer.recognize(zigzag))
    }

    // MARK: Snap to Other Shapes

    private func line(_ a: Point, _ b: Point) -> ShapeItem { ShapeRecognizer.pointShape(.line, [a, b]) }

    func testLineEndNearAnotherLineJoinsIntoOnePolyline() {
        let old = SnapNeighbor(ref: "N1", shape: line(Point(300, 300), Point(400, 300)))
        let r = ShapeSnapper.snap(line(Point(402, 305), Point(402, 400)), to: [old])
        XCTAssertEqual(r.mergeWith, ["N1"])
        XCTAssertEqual(r.shape.shape, .polyline)
        XCTAssertEqual(r.shape.points, [Point(300, 300), Point(400, 300), Point(402, 400)])
    }

    func testClosingTheLoopMakesOnePolygon() {
        let a = SnapNeighbor(ref: "A", shape: line(Point(100, 100), Point(200, 100)))
        let b = SnapNeighbor(ref: "B", shape: line(Point(200, 100), Point(150, 190)))
        let r = ShapeSnapper.snap(line(Point(152, 186), Point(103, 104)), to: [a, b])
        XCTAssertEqual(r.shape.shape, .polygon)
        XCTAssertEqual(Set(r.mergeWith), ["A", "B"])
        XCTAssertEqual(r.shape.points.count, 3)
        XCTAssertTrue(r.shape.points.contains(Point(100, 100)))
        XCTAssertTrue(r.shape.points.contains(Point(200, 100)))
    }

    func testEndSnapsOntoACornerWithoutMerging() {
        let box = SnapNeighbor(ref: "R", shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 200, w: 160, h: 90)))
        let locked = SnapNeighbor(ref: "L", shape: line(Point(400, 400), Point(500, 400)), mergeable: false)
        let r = ShapeSnapper.snap(line(Point(104, 203), Point(395, 404)), to: [box, locked])
        XCTAssertEqual(r.mergeWith, [])
        XCTAssertEqual(r.shape.shape, .line)
        XCTAssertEqual(r.shape.points, [Point(100, 200), Point(400, 400)])
    }

    func testClosedShapesAndFarShapesAreLeftAlone() {
        let far = SnapNeighbor(ref: "F", shape: line(Point(0, 0), Point(10, 0)))
        let circle = ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 20, h: 20))
        XCTAssertEqual(ShapeSnapper.snap(circle, to: [far]).shape, circle)
        let alone = line(Point(100, 100), Point(200, 100))
        let r = ShapeSnapper.snap(alone, to: [far])
        XCTAssertEqual(r.shape, alone)
        XCTAssertEqual(r.mergeWith, [])
    }

    // MARK: Draw and Hold live adjustment

    func testHeldLineFollowsThePencilAndSettlesOnStraightAngles() {
        let hold = DrawAndHold(shape: line(Point(100, 100), Point(200, 100)), grab: Point(200, 100))
        let turned = hold.shape(at: Point(100, 300))
        XCTAssertEqual(turned.points[0].x, 100, accuracy: 1e-9)
        XCTAssertEqual(turned.points[0].y, 100, accuracy: 1e-9)
        XCTAssertEqual(turned.points[1].x, 100, accuracy: 1e-9)
        XCTAssertEqual(turned.points[1].y, 300, accuracy: 1e-9)
        let wobble = hold.shape(at: Point(297, 104))                // 1.2° off level: stays level
        XCTAssertEqual(wobble.points[1].y, 100, accuracy: 1e-9)
        XCTAssertEqual(wobble.points[1].x, 100 + Point(297, 104).distance(to: Point(100, 100)), accuracy: 1e-9)
    }

    func testHeldBoxScalesAboutItsCentreAndStaysUpright() {
        let box = ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 100, w: 100, h: 50))
        let hold = DrawAndHold(shape: box, grab: Point(200, 150))
        let bigger = hold.shape(at: Point(250, 175))
        XCTAssertEqual(bigger.frame.center.x, 150, accuracy: 1e-9)
        XCTAssertEqual(bigger.frame.center.y, 125, accuracy: 1e-9)
        XCTAssertEqual(bigger.frame.w, 200, accuracy: 1e-9)
        XCTAssertEqual(bigger.frame.h, 100, accuracy: 1e-9)
        XCTAssertEqual(bigger.frame.rotation, 0)
        let c = Point(150, 125)
        let slightlyTurned = hold.shape(at: SeededStrokes.rotate(Point(250, 175), 3 * Double.pi / 180, about: c))
        XCTAssertEqual(slightlyTurned.frame.rotation, 0, accuracy: 1e-9)
        let turned = hold.shape(at: SeededStrokes.rotate(Point(250, 175), 30 * Double.pi / 180, about: c))
        XCTAssertEqual(turned.frame.rotation, 30 * Double.pi / 180, accuracy: 1e-9)
    }

    func testOutlinesOfBoxShapesAreClosed() {
        for kind in [ShapeKind.rectangle, .ellipse, .triangle, .diamond] {
            let s = ShapeItem(shape: kind, frame: Frame(x: 10, y: 20, w: 100, h: 60, rotation: 0.3))
            let ring = ShapeGeometry.outline(s)[0]
            XCTAssertEqual(ring.first, ring.last, "\(kind)")
            XCTAssertGreaterThanOrEqual(ring.count, 4, "\(kind)")
        }
    }
}
