import Foundation
import CoreGraphics
import UIKit
import PencilKit
import NibContracts

// MARK: - Geometry

/// Shape geometry shared by the drawer, the commands, the tool, the control points and containers. Pure and
/// thread-safe: the drawer runs on render threads.
///
/// Box kinds (rectangle, rounded rectangle, ellipse, triangle, diamond) are defined by `frame` alone, rotated about its
/// centre. Point kinds keep their page-space `points` plus a `frame` fitted around them in the frame's own rotated axes,
/// so free rotation survives every edit. Curves and arcs treat their points as control points (Bézier / conic), so the
/// drawn outline never leaves the points' bounds, which is what `Item.bounds` (and so tile culling) uses.
enum ShapeGeometry {
    static let boxKinds: Set<ShapeKind> = [.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond]
    static let openKinds: Set<ShapeKind> = [.line, .polyline, .arc, .curve, .arrow]
    static let maxPoints = 2_000
    /// How far a drawer may paint outside `Item.bounds` (arrowheads, ink nibs, overflowing text). The renderer grants
    /// 12 pt; this stays under it.
    static let drawerMargin = 10.0

    static func isBox(_ kind: ShapeKind) -> Bool { boxKinds.contains(kind) }
    static func isOpen(_ kind: ShapeKind) -> Bool { openKinds.contains(kind) }

    /// Kinds whose corners `style.cornerRadius` rounds.
    static func hasCorners(_ kind: ShapeKind) -> Bool {
        switch kind {
        case .rectangle, .roundedRectangle, .triangle, .diamond, .polygon, .polyline: return true
        default: return false
        }
    }

    /// How many points a point kind takes; nil for box kinds.
    static func pointCount(_ kind: ShapeKind) -> ClosedRange<Int>? {
        switch kind {
        case .line, .arrow: return 2...2
        case .arc: return 3...3
        case .curve, .polyline: return 2...maxPoints
        case .polygon: return 3...maxPoints
        default: return nil
        }
    }

    // MARK: Frames

    static func rotate(_ p: Point, by angle: Double) -> Point {
        let c = cos(angle), s = sin(angle)
        return Point(p.x * c - p.y * s, p.x * s + p.y * c)
    }

    /// Page point → frame-local point (origin at the frame's centre, unrotated axes).
    static func local(_ p: Point, in f: Frame) -> Point { rotate(p - f.center, by: -f.rotation) }

    /// Frame-local point → page point.
    static func page(_ l: Point, in f: Frame) -> Point { rotate(l, by: f.rotation) + f.center }

    /// The frame with `rotation` that tightly encloses `points` in its own rotated axes.
    static func fitFrame(_ points: [Point], rotation: Double) -> Frame {
        let unrotated = points.map { rotate($0, by: -rotation) }
        let b = Rect.bounding(unrotated) ?? .zero
        let c = rotate(b.center, by: rotation)
        return Frame(x: c.x - b.width / 2, y: c.y - b.height / 2, w: b.width, h: b.height, rotation: rotation)
    }

    /// A frame with both sides usable by a box kind (a line's zero-height frame grows around its centre).
    static func nonDegenerate(_ f: Frame) -> Frame {
        var g = f
        if g.w < 2 { g.w = max(24, g.h * 0.6) }
        if g.h < 2 { g.h = max(24, g.w * 0.6) }
        let c = f.center
        g.x = c.x - g.w / 2
        g.y = c.y - g.h / 2
        return g
    }

    /// Vertices of a polygonal box kind in page coordinates (rectangle kinds: top-left, top-right, bottom-right,
    /// bottom-left; triangle: apex first; diamond: top, right, bottom, left).
    static func boxVertices(_ kind: ShapeKind, _ f: Frame) -> [Point] {
        let hw = f.w / 2, hh = f.h / 2
        let l: [Point]
        switch kind {
        case .triangle: l = [Point(0, -hh), Point(hw, hh), Point(-hw, hh)]
        case .diamond: l = [Point(0, -hh), Point(hw, 0), Point(0, hh), Point(-hw, 0)]
        default: l = [Point(-hw, -hh), Point(hw, -hh), Point(hw, hh), Point(-hw, hh)]
        }
        return l.map { page($0, in: f) }
    }

    static func ellipsePoints(_ f: Frame, count: Int = 24) -> [Point] {
        (0..<count).map { i in
            let a = 2 * Double.pi * Double(i) / Double(count) - Double.pi / 2
            return page(Point(cos(a) * f.w / 2, sin(a) * f.h / 2), in: f)
        }
    }

    /// Unit-circle vertices of a regular polygon.
    static func regular(_ n: Int, startAngle: Double) -> [Point] {
        (0..<n).map { i in
            let a = startAngle + 2 * Double.pi * Double(i) / Double(n)
            return Point(cos(a), sin(a))
        }
    }

    /// A five-pointed star (inner radius at the golden ratio), apex up.
    static func star(points: Int = 5, inner: Double = 0.382) -> [Point] {
        (0..<(2 * points)).map { i in
            let a = -Double.pi / 2 + Double.pi * Double(i) / Double(points)
            let r = i % 2 == 0 ? 1 : inner
            return Point(r * cos(a), r * sin(a))
        }
    }

    /// Unit points stretched to fill `f` exactly (their bounds map onto the frame).
    static func fitted(_ unit: [Point], in f: Frame) -> [Point] {
        guard let b = Rect.bounding(unit), b.width > 0, b.height > 0 else { return unit.map { page($0, in: f) } }
        return unit.map { u in
            let x = (u.x - b.midX) / b.width * f.w
            let y = (u.y - b.midY) / b.height * f.h
            return page(Point(x, y), in: f)
        }
    }

    /// A point kind's points when all we have is a frame.
    static func defaultPoints(_ kind: ShapeKind, in f: Frame) -> [Point] {
        let hw = f.w / 2, hh = f.h / 2
        func p(_ x: Double, _ y: Double) -> Point { page(Point(x, y), in: f) }
        switch kind {
        case .line, .arrow: return [p(-hw, -hh), p(hw, hh)]
        case .polyline: return [p(-hw, hh), p(-hw / 3, -hh), p(hw / 3, hh), p(hw, -hh)]
        case .polygon: return fitted(regular(6, startAngle: 0), in: f)
        case .curve, .arc: return [p(-hw, hh), p(0, -hh), p(hw, hh)]
        default: return []
        }
    }

    /// A third point bulging to one side of a two-point line (curves and arcs need a control point).
    static func withBulge(_ pts: [Point]) -> [Point] {
        guard let a = pts.first else { return pts }
        let b = pts.count > 1 ? pts[pts.count - 1] : a + Point(40, 0)
        let d = b - a
        let len = max(hypot(d.x, d.y), 1)
        var n = Point(-d.y / len, d.x / len)
        if n.y > 0 { n = n * -1 }                       // bulge upward on the page
        let mid = (a + b) * 0.5
        return [a, mid + n * (len * 0.4), b]
    }

    /// Where a shape's outline turns: box vertices (an ellipse as a 24-gon) or the points of a point kind.
    static func sourceVertices(_ s: ShapeItem) -> [Point] {
        switch s.shape {
        case .ellipse: return ellipsePoints(s.frame)
        case .rectangle, .roundedRectangle, .triangle, .diamond: return boxVertices(s.shape, s.frame)
        default: return s.points
        }
    }

    // MARK: Building and editing

    /// A shape of `kind` from a frame or points (commands and the tool). Box kinds need a frame or ≥ 2 points (their
    /// bounds); point kinds take their points, or derive them from a frame (lines run corner to corner).
    static func make(_ kind: ShapeKind, frame: Frame?, points: [Point]?, style: ShapeItemStyle) throws -> ShapeItem {
        if isBox(kind) {
            if let f = frame { return ShapeItem(shape: kind, frame: f, style: style) }
            if let pts = points, pts.count >= 2, let r = Rect.bounding(pts) {
                return ShapeItem(shape: kind, frame: Frame(r), style: style)
            }
            throw NibError(.invalidParams, "a \(kind.rawValue) needs a frame [x, y, width, height]", path: "$.frame",
                           hint: "or give two or more points and the frame spans them")
        }
        let pts: [Point]
        if let given = points {
            pts = given
        } else if let f = frame {
            pts = defaultPoints(kind, in: f)
        } else {
            throw NibError(.invalidParams, "a \(kind.rawValue) needs points [[x, y], …] or a frame", path: "$.points",
                           hint: "lines and arrows take 2 points, arcs 3, curves and polylines 2 or more, polygons 3 or more")
        }
        try checkCount(kind, pts.count, path: "$.points")
        return ShapeItem(shape: kind, frame: fitFrame(pts, rotation: frame?.rotation ?? 0), points: pts, style: style)
    }

    static func checkCount(_ kind: ShapeKind, _ n: Int, path: String) throws {
        guard let range = pointCount(kind), !range.contains(n) else { return }
        let want = range.lowerBound == range.upperBound ? "exactly \(range.lowerBound)" : "\(range.lowerBound) or more"
        throw NibError(.invalidParams, "a \(kind.rawValue) takes \(want) points, got \(n)", path: path,
                       hint: "use polyline or polygon for any number of vertices")
    }

    /// Changes the type keeping the frame (and its rotation). Box targets reuse the frame; point targets derive their
    /// points from the current outline.
    static func setKind(_ s: ShapeItem, to kind: ShapeKind) -> ShapeItem {
        var out = s
        out.shape = kind
        if isBox(kind) {
            out.points = []
            out.frame = nonDegenerate(s.frame)
            return out
        }
        let f = s.frame
        let src = sourceVertices(s)
        let fromBox = isBox(s.shape)
        var pts: [Point]
        switch kind {
        case .line, .arrow:
            if fromBox || src.count < 2 {
                pts = defaultPoints(kind, in: f)
            } else {
                pts = [src[0], src[src.count - 1]]
            }
        case .polyline:
            pts = src.count >= 2 ? src : defaultPoints(.polyline, in: nonDegenerate(f))
        case .polygon:
            pts = src.count >= 3 ? src : defaultPoints(.polygon, in: nonDegenerate(f))
        case .curve:
            if fromBox {
                pts = defaultPoints(.curve, in: f)
            } else {
                pts = src.count >= 3 ? src : withBulge(src)
            }
        case .arc:
            if fromBox {
                pts = defaultPoints(.arc, in: f)
            } else if src.count >= 3 {
                let inner = Array(src[1..<(src.count - 1)])
                let control = inner.reduce(Point.zero, +) * (1 / Double(inner.count))
                pts = [src[0], control, src[src.count - 1]]
            } else {
                pts = withBulge(src)
            }
        default:
            pts = src
        }
        out.points = pts
        out.frame = fitFrame(pts, rotation: f.rotation)
        return out
    }

    /// Replaces the vertices / control points. Box kinds: 2 points are opposite corners (in the frame's rotated axes),
    /// 3 or more turn the shape into a polygon.
    static func setPoints(_ s: ShapeItem, _ pts: [Point], path: String = "$.points") throws -> ShapeItem {
        var out = s
        let rotation = s.frame.rotation
        if isBox(s.shape) {
            if pts.count == 2 {
                out.frame = fitFrame(pts, rotation: rotation)
                return out
            }
            guard pts.count >= 3 else {
                throw NibError.invalid("give 2 corner points or 3 or more vertices", path: path)
            }
            try checkCount(.polygon, pts.count, path: path)
            out.shape = .polygon
        } else {
            try checkCount(s.shape, pts.count, path: path)
        }
        out.points = pts
        out.frame = fitFrame(pts, rotation: rotation)
        return out
    }

    /// The corner radius a rounded rectangle gets when nobody chose one: a fifth of its short side.
    static func roundedDefault(_ f: Frame, current: Double) -> Double {
        max(current, (min(f.w, f.h) * 0.2).rounded())
    }

    /// Rejects shapes that cannot be drawn or would be invisible.
    static func validate(_ s: ShapeItem, path: String) throws {
        let f = s.frame
        let finite = [f.x, f.y, f.w, f.h, f.rotation].allSatisfy { $0.isFinite && abs($0) < 1e7 }
            && s.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e7 && abs($0.y) < 1e7 }
        guard finite else { throw NibError.invalid("coordinates must be finite numbers", path: path) }
        guard f.w >= 0, f.h >= 0, max(f.w, f.h) >= 0.5 else {
            throw NibError(.invalidParams, "the shape has no size", path: path,
                           hint: "give a frame with a width and height, or points that are apart")
        }
        let st = s.style
        guard st.strokeWidth > 0, st.strokeWidth <= 100 else {
            throw NibError.invalid("strokeWidth must be between 0.1 and 100 points", path: path + ".style.strokeWidth")
        }
        guard st.cornerRadius >= 0, st.cornerRadius.isFinite else {
            throw NibError.invalid("cornerRadius must be 0 or more", path: path + ".style.cornerRadius")
        }
        let outline = (st.strokeColor?.a ?? 0) > 0
        let fill = !isOpen(s.shape) && (st.fillColor?.a ?? 0) > 0
        let text = !(s.text?.isEmpty ?? true)
        guard outline || fill || text else {
            let message = isOpen(s.shape) ? "lines, arrows and curves need an outline colour"
                                          : "a shape needs an outline or a fill"
            throw NibError(.invalidParams, message, path: path + ".style", hint: "set style.strokeColor or style.fillColor")
        }
    }

    // MARK: Paths

    /// The outline in page coordinates, without arrowheads.
    static func path(_ s: ShapeItem) -> CGPath {
        let p = CGMutablePath()
        let r = s.style.cornerRadius
        switch s.shape {
        case .rectangle, .roundedRectangle, .triangle, .diamond:
            addRounded(p, boxVertices(s.shape, s.frame), radius: r, closed: true)
        case .ellipse:
            let f = s.frame
            let t = CGAffineTransform(translationX: CGFloat(f.center.x), y: CGFloat(f.center.y)).rotated(by: CGFloat(f.rotation))
            p.addEllipse(in: CGRect(x: -f.w / 2, y: -f.h / 2, width: f.w, height: f.h), transform: t)
        case .polygon:
            addRounded(p, s.points, radius: r, closed: true)
        case .polyline:
            addRounded(p, s.points, radius: r, closed: false)
        case .curve:
            addCurve(p, s.points)
        case .arc:
            if s.points.count >= 3 {
                p.addLines(between: conicPoints(s.points[0], s.points[1], s.points[2]).map { $0.cg })
            } else {
                addRounded(p, s.points, radius: 0, closed: false)
            }
        default:
            if let a = s.points.first, let b = s.points.last {
                p.move(to: a.cg)
                p.addLine(to: b.cg)
            }
        }
        return p
    }

    /// A polygon or polyline with every corner rounded by `radius`, clamped so neighbouring arcs never overlap.
    static func addRounded(_ path: CGMutablePath, _ vertices: [Point], radius: Double, closed: Bool) {
        var pts: [Point] = []
        for q in vertices where pts.last.map({ $0.distance(to: q) > 1e-6 }) ?? true { pts.append(q) }
        if closed, pts.count > 2, pts[0].distance(to: pts[pts.count - 1]) < 1e-6 { pts.removeLast() }
        guard let first = pts.first else { return }
        guard pts.count >= 2 else {
            path.move(to: first.cg)
            path.addLine(to: first.cg)
            return
        }
        let n = pts.count
        if !closed || n < 3 {
            path.move(to: first.cg)
            for i in 1..<n {
                if i < n - 1 {
                    let r = cornerRadius(pts[i - 1], pts[i], pts[i + 1], radius)
                    path.addArc(tangent1End: pts[i].cg, tangent2End: pts[i + 1].cg, radius: CGFloat(r))
                } else {
                    path.addLine(to: pts[i].cg)
                }
            }
            if closed { path.closeSubpath() }
            return
        }
        path.move(to: ((pts[n - 1] + pts[0]) * 0.5).cg)
        for i in 0..<n {
            let prev = pts[(i + n - 1) % n], cur = pts[i], next = pts[(i + 1) % n]
            path.addArc(tangent1End: cur.cg, tangent2End: next.cg, radius: CGFloat(cornerRadius(prev, cur, next, radius)))
        }
        path.closeSubpath()
    }

    /// The largest radius ≤ `r` whose tangent points stay within half of each edge meeting at `b`.
    static func cornerRadius(_ a: Point, _ b: Point, _ c: Point, _ r: Double) -> Double {
        guard r > 0 else { return 0 }
        let u = a - b, w = c - b
        let lu = hypot(u.x, u.y), lw = hypot(w.x, w.y)
        guard lu > 1e-6, lw > 1e-6 else { return 0 }
        let cosine = max(-1, min(1, (u.x * w.x + u.y * w.y) / (lu * lw)))
        let angle = acos(cosine)
        guard angle > 1e-3, angle < Double.pi - 1e-3 else { return 0 }
        return min(r, min(lu, lw) / 2 * tan(angle / 2))
    }

    /// Curves: 2 points a line, 3 a quadratic Bézier (start, control, end), 4 a cubic, more a clamped uniform cubic
    /// B-spline. Every form stays inside its control points' hull.
    static func addCurve(_ path: CGMutablePath, _ pts: [Point]) {
        guard let first = pts.first else { return }
        path.move(to: first.cg)
        switch pts.count {
        case 1:
            path.addLine(to: first.cg)
        case 2:
            path.addLine(to: pts[1].cg)
        case 3:
            path.addQuadCurve(to: pts[2].cg, control: pts[1].cg)
        case 4:
            path.addCurve(to: pts[3].cg, control1: pts[1].cg, control2: pts[2].cg)
        default:
            let last = pts[pts.count - 1]
            let q = [first, first] + pts + [last, last]
            for i in 0..<(q.count - 3) {
                let c1 = (q[i + 1] * 4 + q[i + 2] * 2) * (1.0 / 6)
                let c2 = (q[i + 1] * 2 + q[i + 2] * 4) * (1.0 / 6)
                let end = (q[i + 1] + q[i + 2] * 4 + q[i + 3]) * (1.0 / 6)
                path.addCurve(to: end.cg, control1: c1.cg, control2: c2.cg)
            }
        }
    }

    /// The conic weight that makes an isosceles (start, control, end) triangle a circular arc: cos of the angle
    /// between the chord and the tangents (other triangles give an elliptic arc, still inside the hull).
    static func conicWeight(_ a: Point, _ c: Point, _ b: Point) -> Double {
        func angle(_ o: Point, _ p: Point, _ q: Point) -> Double {
            let u = p - o, v = q - o
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 1e-9, lv > 1e-9 else { return 0 }
            return acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv))))
        }
        let theta = (angle(a, c, b) + angle(b, c, a)) / 2
        return min(max(cos(theta), 0.05), 1)
    }

    /// Points along the rational quadratic (conic) arc from `a` to `b` with control `c`.
    static func conicPoints(_ a: Point, _ c: Point, _ b: Point) -> [Point] {
        let w = conicWeight(a, c, b)
        let approx = a.distance(to: c) + c.distance(to: b)
        let n = max(24, min(256, Int(approx / 2)))
        return (0...n).map { k in
            let t = Double(k) / Double(n), u = 1 - t
            let d = u * u + 2 * u * t * w + t * t
            let x = (u * u * a.x + 2 * u * t * w * c.x + t * t * b.x) / d
            let y = (u * u * a.y + 2 * u * t * w * c.y + t * t * b.y) / d
            return Point(x, y)
        }
    }

    /// Polylines approximating a path (one per subpath; closed subpaths repeat their first point).
    static func flatten(_ path: CGPath, segments: Int = 12) -> [[Point]] {
        var out: [[Point]] = []
        var current: [Point] = []
        var start = Point.zero
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { out.append(current) }
                start = Point(e.points[0])
                current = [start]
            case .addLineToPoint:
                if current.isEmpty { current = [start] }
                current.append(Point(e.points[0]))
            case .addQuadCurveToPoint:
                if current.isEmpty { current = [start] }
                let p0 = current[current.count - 1], c = Point(e.points[0]), p1 = Point(e.points[1])
                for k in 1...segments {
                    let t = Double(k) / Double(segments), u = 1 - t
                    current.append(p0 * (u * u) + c * (2 * u * t) + p1 * (t * t))
                }
            case .addCurveToPoint:
                if current.isEmpty { current = [start] }
                let p0 = current[current.count - 1], c1 = Point(e.points[0])
                let c2 = Point(e.points[1]), p1 = Point(e.points[2])
                for k in 1...segments {
                    let t = Double(k) / Double(segments), u = 1 - t
                    let a = p0 * (u * u * u) + c1 * (3 * u * u * t)
                    let b = c2 * (3 * u * t * t) + p1 * (t * t * t)
                    current.append(a + b)
                }
            case .closeSubpath:
                if current.count > 1 {
                    current.append(current[0])
                    out.append(current)
                }
                current = []
            @unknown default:
                break
            }
        }
        if current.count > 1 { out.append(current) }
        return out
    }

    /// The outline as one polygon (closed kinds) or polyline (open kinds).
    static func outline(_ s: ShapeItem) -> [Point] { flatten(path(s)).first ?? [] }

    // MARK: Arrowheads

    struct Arrowhead: Equatable {
        let tip: Point
        let left: Point
        let right: Point

        var points: [Point] { [left, tip, right] }

        var path: CGPath {
            let p = CGMutablePath()
            p.addLines(between: [left.cg, tip.cg, right.cg])
            p.closeSubpath()
            return p
        }
    }

    /// What the outline stroke draws: the body (trimmed where arrowheads sit) and the heads.
    struct StrokeParts {
        let body: CGPath
        let polylines: [[Point]]
        let heads: [Arrowhead]
    }

    static func wantsEndHead(_ s: ShapeItem) -> Bool { isOpen(s.shape) && (s.shape == .arrow || s.style.arrowEnd) }
    static func wantsStartHead(_ s: ShapeItem) -> Bool { isOpen(s.shape) && s.style.arrowStart }

    static func strokeParts(_ s: ShapeItem) -> StrokeParts {
        let outlinePath = path(s)
        let lines = flatten(outlinePath)
        let end = wantsEndHead(s), start = wantsStartHead(s)
        guard end || start, var line = lines.first, line.count >= 2 else {
            return StrokeParts(body: outlinePath, polylines: lines, heads: [])
        }
        let count = (end ? 1 : 0) + (start ? 1 : 0)
        let size = headSize(width: s.style.strokeWidth, length: Geo.pathLength(line), count: count)
        var heads: [Arrowhead] = []
        if end, let h = head(Array(line.reversed()), size: size) { heads.append(h) }
        if start, let h = head(line, size: size) { heads.append(h) }
        let trim = size.length * 0.6
        line = trimmed(line, start: start ? trim : 0, end: end ? trim : 0)
        let body = CGMutablePath()
        body.addLines(between: line.map { $0.cg })
        return StrokeParts(body: body, polylines: [line], heads: heads)
    }

    /// Head size for an outline width: at most `drawerMargin` wide on each side, and together no more than 90 % of
    /// the line.
    static func headSize(width w: Double, length total: Double, count: Int) -> (length: Double, halfWidth: Double) {
        var half = min(drawerMargin, max(3, 1.6 * w + 1.5))
        var length = half * 2.2
        let limit = total * 0.45 / Double(max(count, 1))
        if length > limit, length > 0 {
            let k = limit / length
            length *= k
            half *= k
        }
        return (length, half)
    }

    /// The arrowhead at the first point of `line`, pointing outward.
    static func head(_ line: [Point], size: (length: Double, halfWidth: Double)) -> Arrowhead? {
        guard line.count >= 2, size.length > 0 else { return nil }
        let tip = line[0]
        let back = point(line, at: size.length)
        let d = tip - back
        let len = hypot(d.x, d.y)
        guard len > 1e-9 else { return nil }
        let dir = d * (1 / len)
        let base = tip - dir * size.length
        let normal = Point(-dir.y, dir.x)
        return Arrowhead(tip: tip, left: base + normal * size.halfWidth, right: base - normal * size.halfWidth)
    }

    /// The point `distance` along a polyline from its start (its end when the line is shorter).
    static func point(_ line: [Point], at distance: Double) -> Point {
        var remaining = distance
        for i in 0..<max(0, line.count - 1) {
            let d = line[i].distance(to: line[i + 1])
            if d >= remaining, d > 0 { return line[i] + (line[i + 1] - line[i]) * (remaining / d) }
            remaining -= d
        }
        return line.last ?? .zero
    }

    /// The polyline with `start` of its length cut from the beginning and `end` from the end.
    static func trimmed(_ line: [Point], start: Double, end: Double) -> [Point] {
        var pts = line
        if start > 0 { pts = cut(pts, start) }
        if end > 0 { pts = Array(cut(Array(pts.reversed()), end).reversed()) }
        return pts
    }

    static func cut(_ line: [Point], _ length: Double) -> [Point] {
        guard line.count >= 2 else { return line }
        var remaining = length
        var head = line[0]
        for i in 0..<(line.count - 1) {
            let d = head.distance(to: line[i + 1])
            if d > remaining {
                let p = head + (line[i + 1] - head) * (remaining / d)
                return [p] + line[(i + 1)...]
            }
            remaining -= d
            head = line[i + 1]
        }
        let last = line[line.count - 1]
        return [last, last]
    }

    /// Splits a polyline into dashes (`on` long, `off` apart) for the ink look.
    static func dashed(_ line: [Point], on: Double, off: Double) -> [[Point]] {
        guard line.count >= 2, on > 0, off > 0 else { return [line] }
        var out: [[Point]] = []
        var current: [Point] = [line[0]]
        var drawing = true
        var left = on
        for i in 0..<(line.count - 1) {
            var a = line[i]
            let b = line[i + 1]
            var d = a.distance(to: b)
            while d > 0 {
                if d >= left {
                    let p = a + (b - a) * (left / d)
                    if drawing {
                        current.append(p)
                        out.append(current)
                    } else {
                        current = [p]
                    }
                    d -= left
                    a = p
                    drawing.toggle()
                    left = drawing ? on : off
                } else {
                    if drawing { current.append(b) }
                    left -= d
                    d = 0
                }
            }
        }
        if drawing, current.count >= 2 { out.append(current) }
        return out
    }

    // MARK: Hit testing, containment, text

    /// True when `p` is on the outline (within `tolerance` plus half the outline width) or inside a closed shape.
    static func hit(_ s: ShapeItem, at p: Point, tolerance: Double) -> Bool {
        let polys = flatten(path(s))
        let reach = tolerance + s.style.strokeWidth / 2
        for poly in polys {
            for i in 1..<max(1, poly.count) where Geo.distance(p, toSegment: poly[i - 1], poly[i]) <= reach { return true }
        }
        if !isOpen(s.shape), let poly = polys.first { return Geo.polygonContains(poly, p) }
        return false
    }

    /// True when a closed shape's outline encloses the whole rectangle.
    static func contains(_ s: ShapeItem, _ r: Rect) -> Bool {
        guard !isOpen(s.shape) else { return false }
        let poly = outline(s)
        let corners = [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
        return corners.allSatisfy { Geo.polygonContains(poly, $0) }
    }

    /// Where text sits inside the shape: a frame (rotated with the shape) inscribed in the outline.
    static func textFrame(_ s: ShapeItem) -> Frame {
        let f = s.frame
        let pad = (s.style.strokeColor == nil ? 0 : s.style.strokeWidth / 2) + 4
        var w = f.w, h = f.h, centreY = 0.0
        switch s.shape {
        case .rectangle, .roundedRectangle:
            let inset = pad + min(s.style.cornerRadius, min(f.w, f.h) / 2) * 0.3
            w = f.w - 2 * inset
            h = f.h - 2 * inset
        case .ellipse:
            w = f.w / sqrt(2.0) - 2 * pad
            h = f.h / sqrt(2.0) - 2 * pad
        case .diamond:
            w = f.w / 2 - pad
            h = f.h / 2 - pad
        case .triangle:
            w = f.w / 2 - pad
            h = f.h / 2 - pad
            centreY = f.h / 4
        case .polygon:
            w = f.w * 0.6
            h = f.h * 0.6
        default:
            break
        }
        w = max(w, 1)
        h = max(h, 1)
        let c = page(Point(0, centreY), in: f)
        return Frame(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h, rotation: f.rotation)
    }

    /// Everything the drawer may paint: `Item.bounds` plus the drawer margin.
    static func drawBounds(_ s: ShapeItem) -> Rect {
        Item.makeShape(s).bounds.insetBy(-drawerMargin)
    }
}

extension NibInk {
    var rgba: RGBA { RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF)) }
}

extension RGBA {
    /// Same colour ignoring alpha.
    func sameHue(_ o: RGBA) -> Bool { r == o.r && g == o.g && b == o.b }

    var luminance: Double { (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255 }
}

// MARK: - Text

/// Text inside shapes: centred by default, in the outline colour, 17 pt. The editor works at `scale` (page → view) so
/// its text is crisp at any zoom, then maps back to page units.
enum ShapeTextStyle {
    static var baseSize: Double { RichTextBridge.defaultFontSize }

    static func baseColour(_ s: ShapeItem, darkPaper: Bool) -> RGBA {
        if let c = s.style.strokeColor, c.a > 0 { return ShapeRenderer.onPaper(c.withAlpha(1), darkPaper: darkPaper) }
        return darkPaper ? NibInk.chalk.rgba : .black
    }

    static func base(_ s: ShapeItem, darkPaper: Bool, scale: Double) -> TextAttributes {
        TextAttributes(size: baseSize * scale, color: baseColour(s, darkPaper: darkPaper))
    }

    static func scaled(_ text: RichText, by scale: Double) -> RichText {
        guard scale != 1 else { return text }
        var t = text
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices {
                if let size = t.paragraphs[p].runs[r].attrs.size { t.paragraphs[p].runs[r].attrs.size = size * scale }
            }
        }
        return t
    }

    static func attributed(_ text: RichText, shape: ShapeItem, darkPaper: Bool, scale: Double) -> NSAttributedString {
        let a = RichTextBridge.attributed(scaled(text, by: scale), base: base(shape, darkPaper: darkPaper, scale: scale))
        let m = NSMutableAttributedString(attributedString: a)
        m.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let ps = value as? NSParagraphStyle, ps.alignment == .natural,
                  let centred = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
            centred.alignment = .center
            m.addAttribute(.paragraphStyle, value: centred, range: range)
        }
        return m
    }

    /// What typing inserts in an empty shape.
    static func typingAttributes(_ s: ShapeItem, scale: Double) -> [NSAttributedString.Key: Any] {
        var a = RichTextBridge.attributes(TextAttributes(), base: base(s, darkPaper: false, scale: scale))
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        a[.paragraphStyle] = ps
        return a
    }

    /// Back to page units: sizes divided by `scale`, the default size and colour left implicit, centred paragraphs
    /// stored as natural (a shape centres natural text itself).
    static func richText(_ a: NSAttributedString, shape: ShapeItem, scale: Double) -> RichText {
        var rich = RichTextBridge.richText(a)
        let colour = baseColour(shape, darkPaper: false)
        for p in rich.paragraphs.indices {
            if rich.paragraphs[p].align == .center { rich.paragraphs[p].align = .natural }
            for r in rich.paragraphs[p].runs.indices {
                var at = rich.paragraphs[p].runs[r].attrs
                if let size = at.size {
                    let unscaled = (size / max(scale, 0.01) * 2).rounded() / 2
                    at.size = abs(unscaled - baseSize) < 0.01 ? nil : unscaled
                }
                if at.color == colour { at.color = nil }
                rich.paragraphs[p].runs[r].attrs = at
            }
        }
        return rich
    }
}

// MARK: - Rendering

/// Draws one shape into a CoreGraphics context whose units are page points (y down). Pure and thread-safe.
enum ShapeRenderer {
    /// Near-black outlines turn to chalk on dark paper (the paper itself is never inverted).
    static func onPaper(_ c: RGBA, darkPaper: Bool) -> RGBA {
        guard darkPaper, c.luminance < 0.18 else { return c }
        return NibInk.chalk.rgba.withAlpha(c.alpha)
    }

    /// Dash lengths for a pattern (round caps add a width to each dash, so dotted is a zero-length dash).
    static func dashLengths(_ pattern: StrokePattern, width w: Double) -> [Double]? {
        switch pattern {
        case .solid: return nil
        case .dashed: return [max(3 * w, 3), max(3 * w, 3)]
        case .dotted: return [0.01, max(2 * w, 2)]
        }
    }

    static func draw(_ s: ShapeItem, in cg: CGContext, scale: Double, darkPaper: Bool, drawsText: Bool = true) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: ShapeGeometry.drawBounds(s).cg)
        let style = s.style
        if !ShapeGeometry.isOpen(s.shape), let fill = style.fillColor, fill.a > 0 {
            cg.addPath(ShapeGeometry.path(s))
            cg.setFillColor(fill.cgColor)
            cg.fillPath()
        }
        if let raw = style.strokeColor, raw.a > 0 {
            let colour = onPaper(raw, darkPaper: darkPaper)
            let parts = ShapeGeometry.strokeParts(s)
            if let tool = style.drawnWith, tool != .tape {
                drawInk(parts, tool: tool, colour: colour, style: style, in: cg, scale: scale, darkPaper: darkPaper)
            } else {
                drawVector(parts, colour: colour, style: style, in: cg)
            }
        }
        if drawsText, let text = s.text, !text.isEmpty { drawText(text, shape: s, in: cg, darkPaper: darkPaper) }
    }

    static func drawVector(_ parts: ShapeGeometry.StrokeParts, colour: RGBA, style: ShapeItemStyle, in cg: CGContext) {
        let w = CGFloat(style.strokeWidth)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(colour.cgColor)
        cg.setFillColor(colour.cgColor)
        cg.setLineWidth(w)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if let dash = dashLengths(style.pattern, width: style.strokeWidth) {
            cg.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
        }
        cg.addPath(parts.body)
        cg.strokePath()
        guard !parts.heads.isEmpty else { return }
        cg.setLineDash(phase: 0, lengths: [])
        cg.setLineWidth(max(w * 0.5, 0.5))
        for h in parts.heads {
            cg.addPath(h.path)
            cg.drawPath(using: .fillStroke)
        }
    }

    /// The ink look of a Draw-and-Hold shape: synthetic strokes along the outline, rendered by PencilKit with the
    /// tool that drew it (arrowheads as open chevrons, dashes as separate strokes).
    static func drawInk(_ parts: ShapeGeometry.StrokeParts, tool: InkTool, colour: RGBA, style: ShapeItemStyle,
                        in cg: CGContext, scale: Double, darkPaper: Bool) {
        var lines = parts.polylines
        if let dash = dashLengths(style.pattern, width: style.strokeWidth) {
            lines = lines.flatMap { ShapeGeometry.dashed($0, on: dash[0], off: dash[1]) }
        }
        lines += parts.heads.map { $0.points }
        let ink = InkStyle(tool: tool, pen: tool == .pen ? .fountain : nil, color: colour, width: style.strokeWidth)
        let strokes = lines.filter { $0.count >= 2 }.map { line -> Stroke in
            let pts = line.enumerated().map { i, p in StrokePoint(x: Float(p.x), y: Float(p.y), t: Float(i) * 0.004) }
            return Stroke(style: ink, points: pts, t0: 0)
        }
        guard !strokes.isEmpty else { return }
        let drawing = PKBridge.drawing(strokes)
        var rect = drawing.bounds
        let clip = cg.boundingBoxOfClipPath
        if !clip.isNull, !clip.isInfinite { rect = rect.intersection(clip) }
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        // ponytail: one bitmap per draw, capped at 16 Mpx; tile the ink if huge shapes at deep zoom ever look soft.
        var pxPerPt = CGFloat(max(scale, 0.25))
        let pixels = rect.width * rect.height * pxPerPt * pxPerPt
        if pixels > 16_000_000 { pxPerPt *= sqrt(16_000_000 / pixels) }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: pxPerPt)
        }
        guard let cgImage = image?.cgImage else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        if tool == .highlighter {
            if darkPaper { cg.setAlpha(0.55) } else { cg.setBlendMode(.multiply) }
        }
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
    }

    static func drawText(_ text: RichText, shape: ShapeItem, in cg: CGContext, darkPaper: Bool) {
        let tf = ShapeGeometry.textFrame(shape)
        let attributed = ShapeTextStyle.attributed(text, shape: shape, darkPaper: darkPaper, scale: 1)
        let width = CGFloat(tf.w)
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                               options: options, context: nil)
        let height = ceil(measured.height)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(tf.center.x), y: CGFloat(tf.center.y))
        cg.rotate(by: CGFloat(tf.rotation))
        UIGraphicsPushContext(cg)
        attributed.draw(with: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), options: options,
                        context: nil)
        UIGraphicsPopContext()
    }
}

/// The "shape" item drawer (ARCHITECTURE §9): rounded CoreGraphics outlines, translucent fills, dash patterns,
/// arrowheads, text, and the ink look for shapes `drawnWith` a pen, pencil or highlighter.
final class ShapeDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let shape = item.shape else { return }
        ShapeRenderer.draw(shape, in: context.cg, scale: context.scale, darkPaper: context.darkPaper)
    }
}
