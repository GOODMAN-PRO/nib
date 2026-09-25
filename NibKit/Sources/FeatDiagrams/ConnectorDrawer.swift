import Foundation
import CoreGraphics
import UIKit
import NibContracts

// Connector geometry (routing for straight, elbow and curved connectors), anchoring to item sides, and the
// "connector" ItemDrawer. Everything here is pure and thread-safe: the drawer runs on render threads, and the
// commands and canvas attachments use the same routing, so what you edit is exactly what renders.

// MARK: - Sides

/// The four sides of a frame, in the model's numbering (`ConnectorEnd.side`, `Item.anchorPoint(side:t:)`).
enum ConnectorSide: Int, CaseIterable {
    case top = 0, right, bottom, left

    var name: String {
        switch self {
        case .top: return "top"
        case .right: return "right"
        case .bottom: return "bottom"
        case .left: return "left"
        }
    }

    init?(name: String) {
        switch name.lowercased() {
        case "top": self = .top
        case "right": self = .right
        case "bottom": self = .bottom
        case "left": self = .left
        default: return nil
        }
    }

    /// Outward unit normal of the side on an unrotated frame (page space, y down).
    var normal: Point {
        switch self {
        case .top: return Point(0, -1)
        case .right: return Point(1, 0)
        case .bottom: return Point(0, 1)
        case .left: return Point(-1, 0)
        }
    }

    var opposite: ConnectorSide {
        switch self {
        case .top: return .bottom
        case .right: return .left
        case .bottom: return .top
        case .left: return .right
        }
    }
}

// MARK: - Vector helpers

func vecDot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }

func vecLength(_ p: Point) -> Double { hypot(p.x, p.y) }

/// Unit vector; `fallback` when `p` is (almost) zero.
func vecUnit(_ p: Point, fallback: Point = Point(1, 0)) -> Point {
    let l = vecLength(p)
    return l < 1e-9 ? fallback : Point(p.x / l, p.y / l)
}

// MARK: - Geometry

/// The routed path of one connector: line and cubic segments, contiguous, from the `from` end to the `to` end.
struct ConnectorGeometry {
    enum Segment: Equatable {
        case line(Point, Point)
        case cubic(Point, Point, Point, Point)

        var start: Point {
            switch self {
            case let .line(p, _): return p
            case let .cubic(p, _, _, _): return p
            }
        }

        var end: Point {
            switch self {
            case let .line(_, q): return q
            case let .cubic(_, _, _, q): return q
            }
        }

        func point(at t: Double) -> Point {
            switch self {
            case let .line(p, q):
                return p + (q - p) * t
            case let .cubic(p0, c1, c2, p3):
                let u = 1 - t
                let a = p0 * (u * u * u) + c1 * (3 * u * u * t)
                let b = c2 * (3 * u * t * t) + p3 * (t * t * t)
                return a + b
            }
        }

        var midpoint: Point { point(at: 0.5) }

        /// Unit direction of travel as the segment arrives at its end.
        var endDirection: Point {
            switch self {
            case let .line(p, q):
                return vecUnit(q - p)
            case let .cubic(p0, c1, c2, p3):
                if vecLength(p3 - c2) > 1e-6 { return vecUnit(p3 - c2) }
                if vecLength(p3 - c1) > 1e-6 { return vecUnit(p3 - c1) }
                return vecUnit(p3 - p0)
            }
        }

        /// Unit direction pointing backward out of the start (where a start arrowhead points).
        var startDirection: Point {
            switch self {
            case let .line(p, q):
                return vecUnit(p - q)
            case let .cubic(p0, c1, c2, p3):
                if vecLength(p0 - c1) > 1e-6 { return vecUnit(p0 - c1) }
                if vecLength(p0 - c2) > 1e-6 { return vecUnit(p0 - c2) }
                return vecUnit(p0 - p3)
            }
        }

        /// The segment with its end pulled back by up to `d` along the arrival direction (arrowheads).
        func trimmingEnd(_ d: Double) -> Segment {
            switch self {
            case let .line(p, q):
                let k = min(d, p.distance(to: q) * 0.5)
                return .line(p, q - endDirection * k)
            case let .cubic(p0, c1, c2, p3):
                let back = endDirection * min(d, p0.distance(to: p3) * 0.5)
                return .cubic(p0, c1, c2 - back, p3 - back)
            }
        }

        func trimmingStart(_ d: Double) -> Segment {
            switch self {
            case let .line(p, q):
                let k = min(d, p.distance(to: q) * 0.5)
                return .line(p - startDirection * k, q)
            case let .cubic(p0, c1, c2, p3):
                let back = startDirection * min(d, p0.distance(to: p3) * 0.5)
                return .cubic(p0 - back, c1 - back, c2, p3)
            }
        }
    }

    var segments: [Segment]

    var start: Point { segments.first?.start ?? .zero }
    var end: Point { segments.last?.end ?? .zero }
    var endDirection: Point { segments.last?.endDirection ?? Point(1, 0) }
    var startDirection: Point { segments.first?.startDirection ?? Point(-1, 0) }

    /// The path as a polyline (cubics sampled `steps` times each).
    func flattened(steps: Int = 16) -> [Point] {
        guard let first = segments.first else { return [] }
        let n = max(1, steps)
        var out = [first.start]
        for s in segments {
            switch s {
            case let .line(_, q):
                out.append(q)
            case .cubic:
                for i in 1...n { out.append(s.point(at: Double(i) / Double(n))) }
            }
        }
        return out
    }

    /// A CGPath in page coordinates, optionally shortened at either end so a stroke never pokes through an arrowhead.
    func path(trimStart: Double = 0, trimEnd: Double = 0) -> CGPath {
        var segs = segments
        if trimStart > 0, let first = segs.first { segs[0] = first.trimmingStart(trimStart) }
        if trimEnd > 0, let last = segs.last { segs[segs.count - 1] = last.trimmingEnd(trimEnd) }
        let path = CGMutablePath()
        for (i, s) in segs.enumerated() {
            if i == 0 { path.move(to: s.start.cg) }
            switch s {
            case let .line(_, q):
                path.addLine(to: q.cg)
            case let .cubic(_, c1, c2, p3):
                path.addCurve(to: p3.cg, control1: c1.cg, control2: c2.cg)
            }
        }
        return path
    }

    /// The point halfway along the path and the unit tangent there (label placement).
    func midpoint() -> (point: Point, tangent: Point) {
        let pts = flattened()
        guard pts.count > 1 else { return (pts.first ?? .zero, Point(1, 0)) }
        let half = Geo.pathLength(pts) / 2
        var acc = 0.0
        for i in 1..<pts.count {
            let d = pts[i - 1].distance(to: pts[i])
            if acc + d >= half && d > 0 {
                let k = (half - acc) / d
                return (pts[i - 1] + (pts[i] - pts[i - 1]) * k, vecUnit(pts[i] - pts[i - 1]))
            }
            acc += d
        }
        return (pts[pts.count - 1], vecUnit(pts[pts.count - 1] - pts[pts.count - 2]))
    }
}

// MARK: - Routing

enum ConnectorRouter {
    /// How far an elbow leaves an anchored side before it turns. Kept inside the padding `Item.bounds` gives
    /// connectors (half the width + 6 pt), so tile invalidation always covers the route.
    static let stub = 6.0
    static let epsilon = 0.01

    static func geometry(_ c: ConnectorItem) -> ConnectorGeometry {
        let a = c.from.point, b = c.to.point
        switch c.route {
        case .straight:
            return lines([a] + c.bends + [b])
        case .elbow:
            return lines(elbow(from: a, side: c.from.side, to: b, side: c.to.side, bends: c.bends))
        case .curved:
            return curve(from: a, side: c.from.side, to: b, side: c.to.side, bends: c.bends)
        }
    }

    /// The direction an end leaves in: its side's normal, or (free ends) the dominant axis toward `q`.
    static func direction(side: Int?, at p: Point, toward q: Point) -> Point {
        if let s = side.flatMap({ ConnectorSide(rawValue: $0) }) { return s.normal }
        let d = q - p
        if abs(d.x) < epsilon && abs(d.y) < epsilon { return Point(1, 0) }
        return abs(d.x) >= abs(d.y) ? Point(d.x > 0 ? 1 : -1, 0) : Point(0, d.y > 0 ? 1 : -1)
    }

    /// One segment per pair of consecutive control points (degenerate ones included, so bend indices line up).
    static func lines(_ pts: [Point]) -> ConnectorGeometry {
        guard pts.count > 1 else { return ConnectorGeometry(segments: []) }
        let segs: [ConnectorGeometry.Segment] = (1..<pts.count).map { ConnectorGeometry.Segment.line(pts[$0 - 1], pts[$0]) }
        return ConnectorGeometry(segments: segs)
    }

    // MARK: Elbow (orthogonal)

    /// The editable middle of an elbow route: the stub points (the anchors themselves for free ends) and every corner
    /// between them. `first` and `last` are the stub points; the interior points are the elbow's bends.
    static func elbowFrame(from a: Point, side sa: Int?, to b: Point, side sb: Int?, bends: [Point]) -> [Point] {
        let dA = direction(side: sa, at: a, toward: bends.first ?? b)
        let dB = direction(side: sb, at: b, toward: bends.last ?? a)
        let q0 = sa == nil ? a : a + dA * stub
        let q1 = sb == nil ? b : b + dB * stub
        var pts = [q0]
        if bends.isEmpty {
            pts += corners(q0, dA, q1, dB)
        } else {
            var cur = q0
            var horizontal = dA.x != 0
            for w in bends {
                if let c = corner(from: cur, to: w, lastHorizontal: horizontal) {
                    pts.append(c)
                } else if abs(w.x - cur.x) >= epsilon || abs(w.y - cur.y) >= epsilon {
                    horizontal = abs(w.y - cur.y) < epsilon
                }
                pts.append(w)
                cur = w
            }
            // Arrive along the end's own axis.
            if abs(cur.x - q1.x) >= epsilon && abs(cur.y - q1.y) >= epsilon {
                pts.append(dB.x != 0 ? Point(cur.x, q1.y) : Point(q1.x, cur.y))
            }
        }
        pts.append(q1)
        return simplified(pts)
    }

    static func elbow(from a: Point, side sa: Int?, to b: Point, side sb: Int?, bends: [Point]) -> [Point] {
        simplified([a] + elbowFrame(from: a, side: sa, to: b, side: sb, bends: bends) + [b])
    }

    /// The corner that joins `p` to an unaligned `q`, turning first (so a bend point is always a visible corner).
    static func corner(from p: Point, to q: Point, lastHorizontal: Bool) -> Point? {
        if abs(p.x - q.x) < epsilon || abs(p.y - q.y) < epsilon { return nil }
        return lastHorizontal ? Point(p.x, q.y) : Point(q.x, p.y)
    }

    /// Automatic corners between the two stub points (no user bends).
    static func corners(_ q0: Point, _ dA: Point, _ q1: Point, _ dB: Point) -> [Point] {
        if abs(q0.x - q1.x) < epsilon && abs(q0.y - q1.y) < epsilon { return [] }
        let hA = dA.x != 0, hB = dB.x != 0
        switch (hA, hB) {
        case (true, true):
            if dA.x == dB.x {
                // Both ends leave the same way: go round the far side.
                let x = dA.x > 0 ? max(q0.x, q1.x) : min(q0.x, q1.x)
                return [Point(x, q0.y), Point(x, q1.y)]
            }
            if dA.x * (q1.x - q0.x) >= 0 {
                let mx = (q0.x + q1.x) / 2
                return [Point(mx, q0.y), Point(mx, q1.y)]
            }
            let my = (q0.y + q1.y) / 2
            return [Point(q0.x, my), Point(q1.x, my)]
        case (false, false):
            if dA.y == dB.y {
                let y = dA.y > 0 ? max(q0.y, q1.y) : min(q0.y, q1.y)
                return [Point(q0.x, y), Point(q1.x, y)]
            }
            if dA.y * (q1.y - q0.y) >= 0 {
                let my = (q0.y + q1.y) / 2
                return [Point(q0.x, my), Point(q1.x, my)]
            }
            let mx = (q0.x + q1.x) / 2
            return [Point(mx, q0.y), Point(mx, q1.y)]
        case (true, false):
            if dA.x * (q1.x - q0.x) >= 0 && dB.y * (q0.y - q1.y) >= 0 { return [Point(q1.x, q0.y)] }
            return [Point(q0.x, q1.y)]
        case (false, true):
            if dA.y * (q1.y - q0.y) >= 0 && dB.x * (q0.x - q1.x) >= 0 { return [Point(q0.x, q1.y)] }
            return [Point(q1.x, q0.y)]
        }
    }

    /// Drops repeated points and middle points on the line through their neighbours (first and last are kept).
    static func simplified(_ pts: [Point]) -> [Point] {
        var out: [Point] = []
        for (i, p) in pts.enumerated() {
            if let last = out.last, abs(last.x - p.x) < epsilon && abs(last.y - p.y) < epsilon {
                if i == pts.count - 1 { out[out.count - 1] = p }
                continue
            }
            if out.count >= 2 {
                let ab = out[out.count - 1] - out[out.count - 2], bp = p - out[out.count - 1]
                let cross = ab.x * bp.y - ab.y * bp.x
                if abs(cross) <= 1e-9 * max(1, vecLength(ab) * vecLength(bp)) {
                    out[out.count - 1] = p
                    continue
                }
            }
            out.append(p)
        }
        return out
    }

    // MARK: Curved

    /// A smooth curve through the bends (Catmull-Rom), leaving and arriving along the anchored sides.
    static func curve(from a: Point, side sa: Int?, to b: Point, side sb: Int?, bends: [Point]) -> ConnectorGeometry {
        let p = [a] + bends + [b]
        let n = p.count
        var t = [Point](repeating: .zero, count: n)
        for i in 0..<n {
            if i == 0 {
                t[i] = direction(side: sa, at: a, toward: p[1]) * (p[0].distance(to: p[1]) * 1.2)
            } else if i == n - 1 {
                t[i] = direction(side: sb, at: b, toward: p[n - 2]) * (-p[n - 1].distance(to: p[n - 2]) * 1.2)
            } else {
                t[i] = (p[i + 1] - p[i - 1]) * 0.5
            }
        }
        let segs: [ConnectorGeometry.Segment] = (1..<n).map { i in
            ConnectorGeometry.Segment.cubic(p[i - 1], p[i - 1] + t[i - 1] * (1.0 / 3), p[i] - t[i] * (1.0 / 3), p[i])
        }
        return ConnectorGeometry(segments: segs)
    }
}

// MARK: - Anchoring

/// A connector end before its point is computed: attached to `item` (side nil = pick the facing side) or free at
/// `point`.
struct ConnectorEndSpec {
    var item: Item?
    var side: ConnectorSide?
    var t: Double
    var point: Point

    static func attached(_ item: Item, side: ConnectorSide? = nil, t: Double = 0.5) -> ConnectorEndSpec {
        ConnectorEndSpec(item: item, side: side, t: t, point: Anchoring.centre(item))
    }

    static func free(_ p: Point) -> ConnectorEndSpec { ConnectorEndSpec(item: nil, side: nil, t: 0.5, point: p) }
}

/// How connector ends attach to items: side midpoints, the nearest point on an outline, and the best facing sides.
enum Anchoring {
    /// Items a connector can attach to: anything with a frame (shapes, text, images, sticky notes, maths, custom).
    static func canAnchor(_ item: Item) -> Bool { !item.deleted && item.kind != .connector && item.frame != nil }

    static func centre(_ item: Item) -> Point { item.frame?.center ?? item.bounds.center }

    static func point(_ item: Item, _ side: ConnectorSide, t: Double = 0.5) -> Point {
        item.anchorPoint(side: side.rawValue, t: t) ?? centre(item)
    }

    /// The side of `item` whose midpoint is closest to `target`.
    static func bestSide(_ item: Item, toward target: Point) -> ConnectorSide {
        var best = ConnectorSide.right
        var d = Double.infinity
        for s in ConnectorSide.allCases {
            let dist = point(item, s).distance(to: target)
            if dist < d - 1e-9 {
                d = dist
                best = s
            }
        }
        return best
    }

    /// The two sides whose midpoints are closest: right → left for items side by side, bottom → top for stacked
    /// ones, a right-angle pair for diagonal neighbours.
    static func bestPair(_ a: Item, _ b: Item) -> (ConnectorSide, ConnectorSide) {
        var best = (ConnectorSide.right, ConnectorSide.left)
        var d = Double.infinity
        for sa in ConnectorSide.allCases {
            for sb in ConnectorSide.allCases {
                let dist = point(a, sa).distance(to: point(b, sb))
                if dist < d - 1e-9 {
                    d = dist
                    best = (sa, sb)
                }
            }
        }
        return best
    }

    /// The closest point on `item`'s outline to `p`: its side, the position along it (the middle is magnetic) and
    /// the distance.
    static func nearest(on item: Item, to p: Point) -> (side: ConnectorSide, t: Double, point: Point, distance: Double)? {
        guard item.frame != nil else { return nil }
        var best: (side: ConnectorSide, t: Double, point: Point, distance: Double)?
        for s in ConnectorSide.allCases {
            guard let a = item.anchorPoint(side: s.rawValue, t: 0), let b = item.anchorPoint(side: s.rawValue, t: 1) else {
                continue
            }
            let ab = b - a
            let len2 = vecDot(ab, ab)
            var t = len2 > 0 ? vecDot(p - a, ab) / len2 : 0.5
            t = max(0, min(1, t))
            if abs(t - 0.5) < 0.12 { t = 0.5 }
            let q = a + ab * t
            let d = q.distance(to: p)
            if let current = best, d >= current.distance { continue }
            best = (s, t, q, d)
        }
        return best
    }

    /// Connector ends for two resolved ends: a missing side faces the other end (both missing: the closest pair).
    static func ends(_ a: ConnectorEndSpec, _ b: ConnectorEndSpec) -> (ConnectorEnd, ConnectorEnd) {
        var sa = a.side, sb = b.side
        if let ia = a.item, let ib = b.item, sa == nil, sb == nil {
            let pair = bestPair(ia, ib)
            sa = pair.0
            sb = pair.1
        }
        if let ia = a.item, sa == nil { sa = bestSide(ia, toward: reference(b, sb)) }
        if let ib = b.item, sb == nil { sb = bestSide(ib, toward: reference(a, sa)) }
        return (end(a, sa), end(b, sb))
    }

    private static func reference(_ e: ConnectorEndSpec, _ side: ConnectorSide?) -> Point {
        guard let item = e.item else { return e.point }
        return side.map { point(item, $0, t: e.t) } ?? centre(item)
    }

    private static func end(_ e: ConnectorEndSpec, _ side: ConnectorSide?) -> ConnectorEnd {
        guard let item = e.item, let s = side else { return ConnectorEnd(point: e.point) }
        return ConnectorEnd(point: point(item, s, t: e.t), item: item.id, side: s.rawValue, t: e.t)
    }
}

// MARK: - Drawer

/// Draws connector items (`drawKey` "connector") into tiles, thumbnails and exports. Stateless, so thread-safe.
final class ConnectorDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let c = item.connector else { return }
        ConnectorPainter.draw(c, in: context.cg, darkPaper: context.darkPaper)
    }
}

enum ConnectorPainter {
    static let labelSize = 13.0
    static let labelMaxWidth = 240.0

    static func arrowSize(_ width: Double) -> Double { 6 + width * 2.5 }

    static func draw(_ c: ConnectorItem, in cg: CGContext, darkPaper: Bool) {
        let g = ConnectorRouter.geometry(c)
        guard !g.segments.isEmpty, g.start.distance(to: g.end) > 0.01 || g.segments.count > 1 else { return }
        let ink = lifted(c.style.strokeColor ?? .black, darkPaper: darkPaper)
        let w = max(c.style.strokeWidth, 0.25)
        let s = arrowSize(w)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(ink.cgColor)
        cg.setFillColor(ink.cgColor)
        cg.setLineWidth(CGFloat(w))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        switch c.style.pattern {
        case .solid:
            break
        case .dashed:
            cg.setLineDash(phase: 0, lengths: [CGFloat(w * 4), CGFloat(w * 3)])
        case .dotted:
            cg.setLineDash(phase: 0, lengths: [0.01, CGFloat(w * 2.5)])
        }
        cg.addPath(g.path(trimStart: c.style.arrowStart ? s * 0.8 : 0, trimEnd: c.style.arrowEnd ? s * 0.8 : 0))
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        if c.style.arrowEnd { arrowhead(at: g.end, direction: g.endDirection, size: s, in: cg) }
        if c.style.arrowStart { arrowhead(at: g.start, direction: g.startDirection, size: s, in: cg) }
        if let label = c.label, !label.isEmpty { drawLabel(label, geometry: g, ink: ink, in: cg) }
    }

    static func arrowhead(at tip: Point, direction u: Point, size s: Double, in cg: CGContext) {
        let n = Point(-u.y, u.x)
        let base = tip - u * s
        let path = CGMutablePath()
        path.move(to: tip.cg)
        path.addLine(to: (base + n * (s * 0.45)).cg)
        path.addLine(to: (base - n * (s * 0.45)).cg)
        path.closeSubpath()
        cg.addPath(path)
        cg.fillPath()
    }

    /// Where a label sits: centred beside the middle of the path, above it (to its right when it runs vertically).
    static func labelRect(size: CGSize, geometry g: ConnectorGeometry) -> CGRect {
        let mid = g.midpoint()
        var n = Point(-mid.tangent.y, mid.tangent.x)
        if n.y > 1e-6 || (abs(n.y) <= 1e-6 && n.x < 0) { n = n * -1 }
        let w = Double(size.width), h = Double(size.height)
        let reach = abs(n.x) * w / 2 + abs(n.y) * h / 2 + 4
        let c = mid.point + n * reach
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    static func drawLabel(_ label: RichText, geometry g: ConnectorGeometry, ink: RGBA, in cg: CGContext) {
        let text = RichTextBridge.attributed(label, base: TextAttributes(size: labelSize, color: ink))
        let bounds = text.boundingRect(with: CGSize(width: labelMaxWidth, height: 10_000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let rect = labelRect(size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)), geometry: g)
        UIGraphicsPushContext(cg)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }

    /// On dark paper dark ink is lifted toward white (never inverted), so a connector stays readable.
    static func lifted(_ c: RGBA, darkPaper: Bool) -> RGBA {
        guard darkPaper else { return c }
        let luminance = (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
        guard luminance < 0.45 else { return c }
        func mix(_ v: UInt8) -> UInt8 { UInt8(min(255, (Double(v) + (255 - Double(v)) * 0.75).rounded())) }
        return RGBA(mix(c.r), mix(c.g), mix(c.b), c.a)
    }
}
