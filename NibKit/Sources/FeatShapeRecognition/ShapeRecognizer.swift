import Foundation
import NibContracts

/// A stroke recognised as a clean shape. The shape carries a neutral style (sharp corners, an arrowhead on arrows);
/// callers restyle it with the tool that drew it.
struct RecognizedShape {
    var shape: ShapeItem
    /// Mean distance from the stroke to the shape as a fraction of the stroke's size (0 = perfect).
    var error: Double
    /// 0…1: how far the error sits under its class's acceptance threshold.
    var confidence: Double
}

/// Rough stroke → clean shape (T-013, T-046, T-102, S-043).
///
/// The stroke is resampled to 64 points and fits are scored by normalised mean error. Open strokes try an arrow (a
/// straight shaft plus a short V at the tip), a total-least-squares line, a circular arc, a parabola and a
/// Douglas–Peucker polyline. Closed strokes try an algebraic conic (ellipse, snapped to a circle when nearly round)
/// against Douglas–Peucker corners (triangle, rectangle or square, convex polygon), with near-right angles snapped
/// to right angles. A stroke that no fit explains (a scribble, handwriting) returns nil, so the ink stays ink.
enum ShapeRecognizer {
    static let sampleCount = 64
    /// Strokes whose bounding diagonal is shorter than this (page points) are dots or ticks, never shapes.
    static let minimumSize = 8.0

    /// Largest accepted mean error per class, as a fraction of the stroke's bounding diagonal (lines and arrows use
    /// their own length). Real shapes drawn with σ = 2 % jitter sit near 0.01; scribbles sit well above.
    /// ponytail: fixed thresholds tuned on the seeded generator in ShapeRecognizerTests, not a trained classifier;
    /// retune against recorded Pencil traces if real strokes disagree.
    enum Threshold {
        static let line = 0.03
        static let arrow = 0.035
        static let ellipse = 0.03
        static let polygon = 0.018
        static let arc = 0.03
        static let curve = 0.03
        static let polyline = 0.028
    }

    /// Recognised shapes have sharp corners; arrows get their head from `arrowEnd`.
    static let neutralStyle = ShapeItemStyle(cornerRadius: 0)

    private static let degree = Double.pi / 180

    static func recognize(_ input: [Point]) -> RecognizedShape? {
        var pts: [Point] = []
        pts.reserveCapacity(input.count)
        for p in input where p.x.isFinite && p.y.isFinite {
            if let last = pts.last, last.distance(to: p) <= 1e-6 { continue }
            pts.append(p)
        }
        guard pts.count >= 2, let box = Rect.bounding(pts) else { return nil }
        let size = hypot(box.width, box.height)
        guard size >= minimumSize else { return nil }
        let r = Geo.resample(pts, count: sampleCount)
        // Closed when a point near the end comes back to the start; any overshoot past that point is dropped.
        var end = r.count - 1
        var gap = r[0].distance(to: r[end])
        for j in Int(Double(r.count) * 0.7)..<r.count {
            let d = r[0].distance(to: r[j])
            if d < gap {
                gap = d
                end = j
            }
        }
        if gap < 0.2 * size {
            return closedShape(Geo.resample(Array(r[0...end]), count: sampleCount), size: size)
        }
        return openShape(r, raw: pts, size: size)
    }

    private static func confidence(_ error: Double, _ threshold: Double) -> Double {
        max(0, min(1, 1 - error / threshold))
    }

    // MARK: Closed strokes

    private static func closedShape(_ c: [Point], size s: Double) -> RecognizedShape? {
        let swept = abs(winding(c))
        guard swept > 270 * degree, swept < 460 * degree else { return nil }
        let idx = corners(c, closed: true, size: s)
        let v = idx.count >= 3 ? refine(c, idx, closed: true) : []
        var best: RecognizedShape?
        var bestScore = Double.infinity
        if let e = fitEllipse(c, size: s), e.error <= Threshold.ellipse {
            // Many soft corners are a circle drawn in segments, not a polygon: prefer the conic there.
            bestScore = e.error * (v.count >= 5 || v.count < 3 ? 0.55 : 1)
            best = RecognizedShape(shape: ellipseShape(e), error: e.error, confidence: confidence(e.error, Threshold.ellipse))
        }
        if (3...8).contains(v.count) {
            let pe = polyError(c, v, closed: true) / s
            if pe <= Threshold.polygon, pe < bestScore, isSimple(v), v.count < 5 || isConvex(v) {
                best = RecognizedShape(shape: polygonShape(v), error: pe, confidence: confidence(pe, Threshold.polygon))
            }
        }
        return best
    }

    /// Signed total angle swept around the centroid (±2π for a loop drawn once).
    private static func winding(_ p: [Point]) -> Double {
        let c = ShapeFit.centroid(p)
        func angle(_ q: Point) -> Double { atan2(q.y - c.y, q.x - c.x) }
        var total = 0.0
        for i in 1..<p.count { total += ShapeFit.normalized(angle(p[i]) - angle(p[i - 1])) }
        total += ShapeFit.normalized(angle(p[0]) - angle(p[p.count - 1]))
        return total
    }

    private struct Conic {
        var center: Point
        var major: Double
        var minor: Double
        /// Direction of the major axis (radians, clockwise on screen).
        var angle: Double
        var error: Double
    }

    /// Algebraic least-squares conic A x² + B xy + C y² + D x + E y = 1 on centred, scaled points, turned into centre,
    /// semi-axes and angle. Error: mean radial distance from each point to the ellipse over the stroke size.
    private static func fitEllipse(_ c: [Point], size s: Double) -> Conic? {
        let o = ShapeFit.centroid(c)
        let k = s / 2
        var m = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 5)
        var b = [Double](repeating: 0, count: 5)
        for p in c {
            let x = (p.x - o.x) / k, y = (p.y - o.y) / k
            let v = [x * x, x * y, y * y, x, y]
            for i in 0..<5 {
                b[i] += v[i]
                for j in 0..<5 { m[i][j] += v[i] * v[j] }
            }
        }
        guard let q = ShapeFit.solve(m, b) else { return nil }
        let a2 = q[0], b2 = q[1], c2 = q[2], d1 = q[3], e1 = q[4]
        guard b2 * b2 - 4 * a2 * c2 < 0,
              let ctr = ShapeFit.solve([[2 * a2, b2], [b2, 2 * c2]], [-d1, -e1]) else { return nil }
        let x0 = ctr[0], y0 = ctr[1]
        let f0 = a2 * x0 * x0 + b2 * x0 * y0 + c2 * y0 * y0 + d1 * x0 + e1 * y0 - 1
        // About the centre: Q(X) = -f0. Keep Q positive definite so the smaller eigenvalue is the major axis.
        var qa = a2, qb = b2, qc = c2, rhs = -f0
        if qa + qc < 0 {
            qa = -qa
            qb = -qb
            qc = -qc
            rhs = -rhs
        }
        let mean = (qa + qc) / 2
        let spread = (((qa - qc) / 2) * ((qa - qc) / 2) + (qb / 2) * (qb / 2)).squareRoot()
        let lmax = mean + spread, lmin = mean - spread
        guard rhs > 0, lmin > 0, lmax > 0 else { return nil }
        let major = (rhs / lmin).squareRoot() * k
        let minor = (rhs / lmax).squareRoot() * k
        guard major.isFinite, minor.isFinite, minor > 0 else { return nil }
        let angle = 0.5 * atan2(qb, qa - qc) + Double.pi / 2
        let center = Point(o.x + x0 * k, o.y + y0 * k)
        let cs = cos(angle), sn = sin(angle)
        var err = 0.0
        for p in c {
            let dx = p.x - center.x, dy = p.y - center.y
            let u = dx * cs + dy * sn
            let w = -dx * sn + dy * cs
            let r = hypot(u / major, w / minor)
            let rho = hypot(u, w)
            err += r > 1e-9 ? abs(rho - rho / r) : major
        }
        return Conic(center: center, major: major, minor: minor, angle: angle, error: err / Double(c.count) / s)
    }

    /// Nearly round conics become circles; axes within 8° of the page axes become upright.
    private static func ellipseShape(_ e: Conic) -> ShapeItem {
        let c = e.center
        if e.minor / e.major >= 0.85 {
            let r = (e.major + e.minor) / 2
            return ShapeItem(shape: .ellipse, frame: Frame(x: c.x - r, y: c.y - r, w: 2 * r, h: 2 * r), style: neutralStyle)
        }
        var angle = ShapeFit.normalized(e.angle)
        if angle > Double.pi / 2 {
            angle -= Double.pi
        } else if angle <= -Double.pi / 2 {
            angle += Double.pi
        }
        var w = 2 * e.major, h = 2 * e.minor, rotation = angle
        if abs(angle) < 8 * degree {
            rotation = 0
        } else if abs(abs(angle) - Double.pi / 2) < 8 * degree {
            rotation = 0
            swap(&w, &h)
        }
        return ShapeItem(shape: .ellipse, frame: Frame(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h, rotation: rotation),
                         style: neutralStyle)
    }

    private static func polygonShape(_ v: [Point]) -> ShapeItem {
        switch v.count {
        case 3: return triangleShape(v)
        case 4: return quadShape(v)
        default: return pointShape(.polygon, snapRightAngles(v, closed: true))
        }
    }

    /// An isosceles triangle (apex on the base's perpendicular bisector) becomes the frame-based triangle, apex at the
    /// top centre of its frame; any other triangle stays a three-point polygon.
    private static func triangleShape(_ raw: [Point]) -> ShapeItem {
        let v = snapRightAngles(raw, closed: true)
        for i in 0..<3 {
            let apex = v[i], b1 = v[(i + 1) % 3], b2 = v[(i + 2) % 3]
            let base = b1.distance(to: b2)
            guard base > 0 else { continue }
            let m = Point((b1.x + b2.x) / 2, (b1.y + b2.y) / 2)
            let bx = (b2.x - b1.x) / base, by = (b2.y - b1.y) / base
            let along = (apex.x - m.x) * bx + (apex.y - m.y) * by
            let across = -(apex.x - m.x) * by + (apex.y - m.y) * bx
            let height = abs(across)
            guard height > 0, abs(along) <= 0.06 * max(base, height) else { continue }
            // The base's unit normal towards the apex is the frame's "up" (0, -1) turned by `rotation`.
            let nx = across >= 0 ? -by : by, ny = across >= 0 ? bx : -bx
            var rotation = atan2(nx, -ny)
            let off = rotation.remainder(dividingBy: Double.pi / 2)
            if abs(off) < 8 * degree { rotation -= off }
            let center = Point(m.x + sin(rotation) * height / 2, m.y - cos(rotation) * height / 2)
            return ShapeItem(shape: .triangle,
                             frame: Frame(x: center.x - base / 2, y: center.y - height / 2, w: base, h: height,
                                          rotation: abs(rotation) < 1e-9 ? 0 : rotation),
                             style: neutralStyle)
        }
        return pointShape(.polygon, v)
    }

    /// Four near-right angles (±22°) make a rectangle, a square when its sides differ by under 10 %; its tilt snaps
    /// upright within 8°. Other quadrilaterals stay polygons.
    private static func quadShape(_ v: [Point]) -> ShapeItem {
        let rightAngled = (0..<4).allSatisfy { i in
            abs(ShapeFit.turn(v[(i + 3) % 4], v[i], v[(i + 1) % 4]) - Double.pi / 2) <= 22 * degree
        }
        guard rightAngled else { return pointShape(.polygon, snapRightAngles(v, closed: true)) }
        var rotation = dominantAngle(v, closed: true)
        if abs(rotation) < 8 * degree { rotation = 0 }
        let c = ShapeFit.centroid(v)
        let ux = cos(rotation), uy = sin(rotation)
        let us = v.map { ($0.x - c.x) * ux + ($0.y - c.y) * uy }.sorted()
        let ws = v.map { -($0.x - c.x) * uy + ($0.y - c.y) * ux }.sorted()
        // Opposite sides are averaged (two lowest against two highest projections), so jitter does not grow the box.
        var w = (us[2] + us[3] - us[0] - us[1]) / 2
        var h = (ws[2] + ws[3] - ws[0] - ws[1]) / 2
        let du = (us[0] + us[1] + us[2] + us[3]) / 4, dw = (ws[0] + ws[1] + ws[2] + ws[3]) / 4
        let center = Point(c.x + du * ux - dw * uy, c.y + du * uy + dw * ux)
        if abs(w - h) < 0.1 * max(w, h) {
            w = (w + h) / 2
            h = w
        }
        return ShapeItem(shape: .rectangle,
                         frame: Frame(x: center.x - w / 2, y: center.y - h / 2, w: w, h: h, rotation: rotation),
                         style: neutralStyle)
    }

    // MARK: Open strokes

    private static func openShape(_ r: [Point], raw: [Point], size s: Double) -> RecognizedShape? {
        if let a = fitArrow(r, raw: raw), a.error <= Threshold.arrow {
            var style = neutralStyle
            style.arrowEnd = true
            let p = snapAngle(a.tail, a.tip)
            let shape = ShapeItem(shape: .arrow, frame: Frame(Rect.bounding(p) ?? .zero), points: p, style: style)
            return RecognizedShape(shape: shape, error: a.error, confidence: confidence(a.error, Threshold.arrow))
        }
        if let l = fitLine(r), l.error <= Threshold.line, l.backtrack < 0.15 {
            return RecognizedShape(shape: pointShape(.line, snapAngle(l.start, l.end)), error: l.error,
                                   confidence: confidence(l.error, Threshold.line))
        }
        var best: RecognizedShape?
        var bestScore = Double.infinity
        func consider(_ shape: ShapeItem, error: Double, score: Double, threshold: Double) {
            guard score < bestScore else { return }
            bestScore = score
            best = RecognizedShape(shape: shape, error: error, confidence: confidence(error, threshold))
        }
        if let arc = fitArc(r, size: s), arc.error <= Threshold.arc {
            consider(pointShape(arc.kind, arc.points), error: arc.error, score: arc.error, threshold: Threshold.arc)
        }
        if let curve = fitParabola(r, size: s), curve.error <= Threshold.curve {
            consider(pointShape(.curve, curve.points), error: curve.error, score: curve.error, threshold: Threshold.curve)
        }
        let idx = corners(r, closed: false, size: s)
        if (3...5).contains(idx.count) {
            let v = refine(r, idx, closed: false)
            let pe = polyError(r, v, closed: false) / s
            var segments: [Double] = []
            for i in 0..<(v.count - 1) { segments.append(v[i].distance(to: v[i + 1])) }
            let sm = ShapeFit.smooth(r, radius: 2, closed: false)
            var sharpest = 0.0
            var crisp = Double.infinity
            for j in 1..<(v.count - 1) {
                let bend = ShapeFit.turn(v[j - 1], v[j], v[j + 1])
                sharpest = max(sharpest, bend)
                // A real corner turns within a few samples; a smooth curve cut into segments turns gradually.
                let k = idx[j]
                let local = ShapeFit.turn(sm[max(k - 6, 0)], sm[k], sm[min(k + 6, r.count - 1)])
                crisp = min(crisp, local / max(bend, 1e-9))
            }
            let needed = best == nil ? 0.45 : 0.6
            let total = segments.reduce(0, +)
            if pe <= Threshold.polyline, (segments.min() ?? 0) > 0.12 * total, sharpest < 140 * degree, crisp >= needed {
                consider(pointShape(.polyline, snapRightAngles(v, closed: false)), error: pe, score: pe * 0.5,
                         threshold: Threshold.polyline)
            }
        }
        return best
    }

    /// Total least squares line. `error` is the mean perpendicular distance over the line's length and `backtrack` how
    /// far the (smoothed) stroke runs backwards along it, so back-and-forth hatching is never a line.
    private static func fitLine(_ r: [Point]) -> (start: Point, end: Point, error: Double, backtrack: Double)? {
        let (c, u) = ShapeFit.principal(r)
        let proj = r.map { ($0.x - c.x) * u.x + ($0.y - c.y) * u.y }
        guard let lo = proj.min(), let hi = proj.max(), hi - lo > 0 else { return nil }
        let length = hi - lo
        var perp = 0.0
        for p in r { perp += abs(-(p.x - c.x) * u.y + (p.y - c.y) * u.x) }
        let smoothed = ShapeFit.smooth(r, radius: 3, closed: false).map { ($0.x - c.x) * u.x + ($0.y - c.y) * u.y }
        let first = proj[0], last = proj[proj.count - 1]
        let sign: Double = last >= first ? 1 : -1
        var back = 0.0
        for i in 1..<smoothed.count { back += max(0, -sign * (smoothed[i] - smoothed[i - 1])) }
        return (Point(c.x + first * u.x, c.y + first * u.y), Point(c.x + last * u.x, c.y + last * u.y),
                perp / Double(r.count) / length, back / length)
    }

    /// A straight shaft up to the tip (the first point that reaches the farthest distance from the start), then a short
    /// head that stays behind the tip and reaches both sides of the shaft (a V). Either end may carry the head.
    /// `r` is the resampled stroke, `raw` the drawn points (the ends are measured on those).
    private static func fitArrow(_ r: [Point], raw: [Point]) -> (tail: Point, tip: Point, error: Double)? {
        var best: (tail: Point, tip: Point, error: Double)?
        for reversed in [false, true] {
            let p = reversed ? Array(r.reversed()) : r
            let sm = ShapeFit.smooth(p, radius: 1, closed: false)
            let d = sm.map { sm[0].distance(to: $0) }
            guard let dmax = d.max(), dmax > 0, var k = d.firstIndex(where: { $0 >= 0.92 * dmax }) else { continue }
            while true {
                var w = k
                for j in k..<min(k + 5, d.count) where d[j] > d[w] { w = j }
                if w == k { break }
                k = w
            }
            guard k >= 12, k <= p.count - 6 else { continue }
            let tail = sm[0], tip = sm[k]
            let length = tail.distance(to: tip)
            guard length > 0 else { continue }
            let ux = (tip.x - tail.x) / length, uy = (tip.y - tail.y) / length
            var shaftMax = 0.0, shaftSum = 0.0
            for q in p[0...k] {
                let off = abs(-(q.x - tail.x) * uy + (q.y - tail.y) * ux)
                shaftMax = max(shaftMax, off)
                shaftSum += off
            }
            let shaftMean = shaftSum / Double(k + 1)
            guard shaftMax <= 0.12 * length, shaftMean <= 0.04 * length else { continue }
            let head = p[k...]
            var left = 0.0, right = 0.0, far = 0.0
            var ahead = 0
            for q in head {
                let x = -((q.x - tip.x) * ux + (q.y - tip.y) * uy)          // > 0 behind the tip
                let y = -(q.x - tip.x) * uy + (q.y - tip.y) * ux
                far = max(far, hypot(x, y))
                if x < -0.06 * length { ahead += 1 }
                if x > 0.02 * length {
                    left = max(left, y)
                    right = min(right, y)
                }
            }
            guard far <= 0.6 * length, far >= 0.1 * length, Double(ahead) <= 0.1 * Double(head.count),
                  left >= 0.06 * length, -right >= 0.06 * length else { continue }
            let error = shaftMean / length
            if let b = best, b.error <= error { continue }
            // Resampling and smoothing both cut the corner at the tip, so the arrow runs between the drawn ends: the
            // first point, and the drawn point around the tip that reaches farthest along the shaft, both on the shaft.
            func along(_ q: Point) -> Double { (q.x - tail.x) * ux + (q.y - tail.y) * uy }
            let corner = p[k]
            let reach = raw.filter { $0.distance(to: corner) <= 0.08 * length }.map(along).max() ?? length
            let start = along(p[0])
            best = (Point(tail.x + start * ux, tail.y + start * uy), Point(tail.x + reach * ux, tail.y + reach * uy), error)
        }
        return best
    }

    /// Algebraic (Kåsa) circle through an open stroke that sweeps 40°–330° without turning back. Under 170° it is an
    /// arc (start, control, end) whose control is where the end tangents meet, so the conic drawn with weight
    /// cos(span / 2) is the exact circular arc. Wider sweeps, whose tangents meet far away or never, become a clamped
    /// cubic B-spline curve with control points every ≤ 20° just outside the circle (within 1 % of it).
    private static func fitArc(_ r: [Point], size s: Double) -> (kind: ShapeKind, points: [Point], error: Double)? {
        let o = ShapeFit.centroid(r)
        let k = s / 2
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var b = [0.0, 0.0, 0.0]
        for p in r {
            let x = (p.x - o.x) / k, y = (p.y - o.y) / k
            let v = [x, y, 1.0]
            let rhs = -(x * x + y * y)
            for i in 0..<3 {
                b[i] += v[i] * rhs
                for j in 0..<3 { m[i][j] += v[i] * v[j] }
            }
        }
        guard let q = ShapeFit.solve(m, b) else { return nil }
        let cx0 = -q[0] / 2, cy0 = -q[1] / 2
        let r2 = cx0 * cx0 + cy0 * cy0 - q[2]
        guard r2 > 0 else { return nil }
        let radius = r2.squareRoot() * k
        let c = Point(o.x + cx0 * k, o.y + cy0 * k)
        guard radius <= 3 * s else { return nil }
        var err = 0.0
        for p in r { err += abs(p.distance(to: c) - radius) }
        let angles = ShapeFit.smooth(r, radius: 2, closed: false).map { atan2($0.y - c.y, $0.x - c.x) }
        var total = 0.0
        for i in 1..<angles.count { total += ShapeFit.normalized(angles[i] - angles[i - 1]) }
        let sign: Double = total >= 0 ? 1 : -1
        var back = 0.0
        for i in 1..<angles.count { back += max(0, -sign * ShapeFit.normalized(angles[i] - angles[i - 1])) }
        let span = abs(total)
        guard span >= 40 * degree, span <= 330 * degree, back <= 0.15 * span else { return nil }
        let a0 = atan2(r[0].y - c.y, r[0].x - c.x)
        func on(_ a: Double, _ distance: Double) -> Point { Point(c.x + distance * cos(a), c.y + distance * sin(a)) }
        let error = err / Double(r.count) / s
        if span < 170 * degree {
            return (.arc, [on(a0, radius), on(a0 + total / 2, radius / cos(span / 2)), on(a0 + total, radius)], error)
        }
        // A uniform cubic B-spline passes (P[k-1] + 4 P[k] + P[k+1]) / 6 at each knot: control points on a circle of
        // radius 6R / (4 + 2 cos step) put every knot on the circle of radius R. The ends are the stroke's ends.
        let n = Int((span / (20 * degree)).rounded(.up))
        let step = total / Double(n)
        let rho = 6 * radius / (4 + 2 * cos(step))
        return (.curve, (0...n).map { k in on(a0 + step * Double(k), k == 0 || k == n ? radius : rho) }, error)
    }

    /// Parabola y = a·t² + b·t + c across the chord (t = 0…1 from the first to the last point) as a quadratic Bézier:
    /// start, control, end (the control is 2 × middle − (start + end) / 2, so the curve passes through the middle).
    private static func fitParabola(_ r: [Point], size s: Double) -> (points: [Point], error: Double)? {
        let a = r[0], z = r[r.count - 1]
        let length = a.distance(to: z)
        guard length >= 0.3 * s else { return nil }
        let ux = (z.x - a.x) / length, uy = (z.y - a.y) / length
        let xs = r.map { ($0.x - a.x) * ux + ($0.y - a.y) * uy }
        let ys = r.map { -($0.x - a.x) * uy + ($0.y - a.y) * ux }
        let sx = ShapeFit.smooth(r, radius: 3, closed: false).map { ($0.x - a.x) * ux + ($0.y - a.y) * uy }
        var back = 0.0
        for i in 1..<sx.count { back += max(0, -(sx[i] - sx[i - 1])) }
        guard back <= 0.06 * length else { return nil }
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var b = [0.0, 0.0, 0.0]
        for i in 0..<xs.count {
            let t = xs[i] / length
            let v = [t * t, t, 1.0]
            for p in 0..<3 {
                b[p] += v[p] * ys[i]
                for q in 0..<3 { m[p][q] += v[p] * v[q] }
            }
        }
        guard let q = ShapeFit.solve(m, b) else { return nil }
        var err = 0.0
        for i in 0..<xs.count {
            let t = xs[i] / length
            err += abs(ys[i] - (q[0] * t * t + q[1] * t + q[2]))
        }
        func at(_ t: Double) -> Point {
            let y = q[0] * t * t + q[1] * t + q[2]
            return Point(a.x + t * length * ux - y * uy, a.y + t * length * uy + y * ux)
        }
        let start = at(0), end = at(1)
        return ([start, at(0.5) * 2 - (start + end) * 0.5, end], err / Double(xs.count) / s)
    }

    // MARK: Corners (Douglas–Peucker, cleaned)

    /// Douglas–Peucker corner indices into `p` (tolerance 5 % of the size), cleaned on the refined vertices: a vertex
    /// turning under 30° or ending a side shorter than 7 % of the perimeter is dropped, one at a time.
    static func corners(_ p: [Point], closed: Bool, size s: Double) -> [Int] {
        let n = p.count
        let tolerance = 0.05 * s
        var idx: [Int]
        if closed {
            // Start the loop at the point farthest from the centroid, which is a corner on any polygon.
            let c = ShapeFit.centroid(p)
            var far = 0
            var farDistance = -1.0
            for i in 0..<n where p[i].distance(to: c) > farDistance {
                farDistance = p[i].distance(to: c)
                far = i
            }
            var loop = Array(p[far..<n])
            loop += p[0..<far]
            loop.append(p[far])
            idx = ShapeFit.simplifyIndices(loop, tolerance: tolerance).dropLast().map { ($0 + far) % n }
        } else {
            idx = ShapeFit.simplifyIndices(p, tolerance: tolerance)
        }
        while idx.count >= (closed ? 3 : 2) {
            let v = refine(p, idx, closed: closed)
            let m = v.count
            var turns: [Int: Double] = [:]
            for j in 0..<m where closed || (j > 0 && j < m - 1) {
                turns[j] = ShapeFit.turn(v[(j - 1 + m) % m], v[j], v[(j + 1) % m])
            }
            guard let softest = turns.min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { break }
            if softest.value < 30 * degree {
                idx.remove(at: softest.key)
                continue
            }
            let edges = closed ? m : m - 1
            var perimeter = 0.0
            var shortest = 0
            var shortestLength = Double.infinity
            for k in 0..<edges {
                let length = v[k].distance(to: v[(k + 1) % m])
                perimeter += length
                if length < shortestLength {
                    shortestLength = length
                    shortest = k
                }
            }
            if shortestLength < 0.07 * perimeter {
                let options = [shortest, (shortest + 1) % m].compactMap { j in turns[j].map { (j, $0) } }
                if let drop = options.min(by: { ($0.1, $0.0) < ($1.1, $1.0) }) {
                    idx.remove(at: drop.0)
                    continue
                }
            }
            break
        }
        return idx
    }

    /// Accurate vertices: a line fitted to the middle 70 % of each side, neighbouring lines intersected (open ends are
    /// projected onto their side's line). A vertex whose intersection lands far away keeps its sample.
    static func refine(_ p: [Point], _ idx: [Int], closed: Bool) -> [Point] {
        let n = p.count, m = idx.count
        let edges = closed ? m : m - 1
        guard edges >= 1 else { return idx.map { p[$0] } }
        var lines: [(c: Point, u: Point)] = []
        for j in 0..<edges {
            let s = idx[j], e = idx[(j + 1) % m]
            let span = closed ? ((e - s) % n + n) % n : e - s
            let lo = Int(Double(span) * 0.15), hi = Int((Double(span) * 0.85).rounded(.up))
            var side: [Point] = []
            if lo <= hi {
                for k in lo...hi { side.append(p[(s + k) % n]) }
            }
            if side.count < 2 { side = [p[s], p[e]] }
            lines.append(ShapeFit.principal(side))
        }
        let limit = 0.3 * Geo.pathLength(p) / Double(max(m, 1))
        var out: [Point] = []
        for j in 0..<m {
            let sample = p[idx[j]]
            if !closed && (j == 0 || j == m - 1) {
                let l = j == 0 ? lines[0] : lines[edges - 1]
                let t = (sample.x - l.c.x) * l.u.x + (sample.y - l.c.y) * l.u.y
                out.append(Point(l.c.x + t * l.u.x, l.c.y + t * l.u.y))
                continue
            }
            let l1 = lines[(j - 1 + edges) % edges], l2 = lines[j % edges]
            if let q = ShapeFit.intersect(l1.c, l1.u, l2.c, l2.u), q.distance(to: sample) < limit {
                out.append(q)
            } else {
                out.append(sample)
            }
        }
        return out
    }

    private static func polyError(_ p: [Point], _ v: [Point], closed: Bool) -> Double {
        let m = v.count
        let edges = closed ? m : m - 1
        guard edges >= 1, !p.isEmpty else { return .infinity }
        var sum = 0.0
        for q in p {
            var best = Double.infinity
            for j in 0..<edges { best = min(best, Geo.distance(q, toSegment: v[j], v[(j + 1) % m])) }
            sum += best
        }
        return sum / Double(p.count)
    }

    private static func isSimple(_ v: [Point]) -> Bool {
        let m = v.count
        for i in 0..<m {
            for j in (i + 1)..<m where !(j == i + 1 || (i == 0 && j == m - 1)) {
                if Geo.segmentsIntersect(v[i], v[(i + 1) % m], v[j], v[(j + 1) % m]) { return false }
            }
        }
        return true
    }

    private static func isConvex(_ v: [Point]) -> Bool {
        let m = v.count
        var sign = 0
        for i in 0..<m {
            let a = v[(i - 1 + m) % m], b = v[i], c = v[(i + 1) % m]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            let s = cross > 0 ? 1 : -1
            if sign == 0 {
                sign = s
            } else if s != sign {
                return false
            }
        }
        return true
    }

    // MARK: Snapping and output

    /// A point-defined shape with its frame set to the bounds of its outline.
    static func pointShape(_ kind: ShapeKind, _ points: [Point],
                           style: ShapeItemStyle = ShapeRecognizer.neutralStyle) -> ShapeItem {
        var s = ShapeItem(shape: kind, frame: Frame(x: 0, y: 0, w: 0, h: 0), points: points, style: style)
        s.frame = Frame(ShapeGeometry.bounds(s))
        return s
    }

    /// Straightens a segment within 4° of a multiple of 45°, about its midpoint.
    static func snapAngle(_ a: Point, _ b: Point) -> [Point] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let off = angle.remainder(dividingBy: Double.pi / 4)
        guard abs(off) < 4 * degree, off != 0 else { return [a, b] }
        let t = Affine.rotation(-off, about: Point((a.x + b.x) / 2, (a.y + b.y) / 2))
        return [t.apply(a), t.apply(b)]
    }

    /// Orientation of the sides modulo 90°, in (-45°, 45°]: the length-weighted mean of 4 × angle.
    static func dominantAngle(_ v: [Point], closed: Bool) -> Double {
        let m = v.count
        var sx = 0.0, sy = 0.0
        for i in 0..<(closed ? m : m - 1) {
            let a = v[i], b = v[(i + 1) % m]
            let phi = atan2(b.y - a.y, b.x - a.x)
            let length = a.distance(to: b)
            sx += length * cos(4 * phi)
            sy += length * sin(4 * phi)
        }
        return atan2(sy, sx) / 4
    }

    /// "~90° snapping": sides within 7° of level or upright become exactly so, and other sides within 7° of the shape's
    /// dominant orientation (or its perpendicular) become exactly parallel to it, so near-right angles become right
    /// angles even on a tilted shape. Vertices are the intersections of the adjusted sides.
    static func snapRightAngles(_ v: [Point], closed: Bool) -> [Point] {
        let m = v.count
        let edges = closed ? m : m - 1
        guard edges >= 2 else { return v }
        let theta = dominantAngle(v, closed: closed)
        var lines: [(c: Point, u: Point)] = []
        var longest = 0.0
        for i in 0..<edges {
            let a = v[i], b = v[(i + 1) % m]
            longest = max(longest, a.distance(to: b))
            var phi = atan2(b.y - a.y, b.x - a.x)
            let toAxis = phi.remainder(dividingBy: Double.pi / 2)
            let toTheta = (phi - theta).remainder(dividingBy: Double.pi / 2)
            if abs(toAxis) < 7 * degree {
                phi -= toAxis
            } else if abs(toTheta) < 7 * degree {
                phi -= toTheta
            }
            lines.append((Point((a.x + b.x) / 2, (a.y + b.y) / 2), Point(cos(phi), sin(phi))))
        }
        var out = v
        for j in 0..<m {
            if !closed && (j == 0 || j == m - 1) {
                let l = j == 0 ? lines[0] : lines[edges - 1]
                let t = (v[j].x - l.c.x) * l.u.x + (v[j].y - l.c.y) * l.u.y
                out[j] = Point(l.c.x + t * l.u.x, l.c.y + t * l.u.y)
                continue
            }
            let l1 = lines[(j - 1 + edges) % edges], l2 = lines[j % edges]
            if let q = ShapeFit.intersect(l1.c, l1.u, l2.c, l2.u), q.distance(to: v[j]) < 0.25 * longest { out[j] = q }
        }
        return out
    }
}

// MARK: - Numeric helpers

enum ShapeFit {
    static func centroid(_ p: [Point]) -> Point {
        var x = 0.0, y = 0.0
        for q in p {
            x += q.x
            y += q.y
        }
        let n = Double(max(p.count, 1))
        return Point(x / n, y / n)
    }

    /// Centroid and unit direction of largest spread (the total least squares line).
    static func principal(_ p: [Point]) -> (c: Point, u: Point) {
        let c = centroid(p)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for q in p {
            let dx = q.x - c.x, dy = q.y - c.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let a = 0.5 * atan2(2 * sxy, sxx - syy)
        return (c, Point(cos(a), sin(a)))
    }

    /// Moving average over ±`radius` samples (wrapping when closed).
    static func smooth(_ p: [Point], radius: Int, closed: Bool) -> [Point] {
        let n = p.count
        guard n > 0 else { return p }
        return (0..<n).map { i -> Point in
            var sx = 0.0, sy = 0.0, count = 0.0
            for k in -radius...radius {
                var j = i + k
                if closed {
                    j = ((j % n) + n) % n
                } else if j < 0 || j >= n {
                    continue
                }
                sx += p[j].x
                sy += p[j].y
                count += 1
            }
            return Point(sx / count, sy / count)
        }
    }

    /// Angle in (-π, π].
    static func normalized(_ a: Double) -> Double {
        var r = a.remainder(dividingBy: 2 * Double.pi)
        if r <= -Double.pi { r += 2 * Double.pi }
        return r
    }

    /// Unsigned turn at `b` walking a → b → c (0 = straight on, π = straight back).
    static func turn(_ a: Point, _ b: Point, _ c: Point) -> Double {
        abs(normalized(atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x)))
    }

    /// Solves A·x = b by Gaussian elimination with partial pivoting; nil when (nearly) singular.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = (0..<n).map { a[$0] + [b[$0]] }
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) >= 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for r in (col + 1)..<n {
                let f = m[r][col] / m[col][col]
                for c in col...n { m[r][c] -= f * m[col][c] }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = m[r][n]
            for c in (r + 1)..<n { s -= m[r][c] * x[c] }
            x[r] = s / m[r][r]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    /// Intersection of the lines p + t·d and q + s·e; nil when they are (nearly) parallel.
    static func intersect(_ p: Point, _ d: Point, _ q: Point, _ e: Point) -> Point? {
        let den = d.x * e.y - d.y * e.x
        guard abs(den) >= 1e-9 else { return nil }
        let t = ((q.x - p.x) * e.y - (q.y - p.y) * e.x) / den
        return Point(p.x + t * d.x, p.y + t * d.y)
    }

    /// Douglas–Peucker: indices of the points kept (first and last always).
    static func simplifyIndices(_ p: [Point], tolerance: Double) -> [Int] {
        guard p.count > 2 else { return Array(p.indices) }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true
        keep[p.count - 1] = true
        var stack = [(0, p.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxDistance = 0.0
            var index = -1
            for i in (s + 1)..<e {
                let d = Geo.distance(p[i], toSegment: p[s], p[e])
                if d > maxDistance {
                    maxDistance = d
                    index = i
                }
            }
            if index >= 0 && maxDistance > tolerance {
                keep[index] = true
                stack.append((s, index))
                stack.append((index, e))
            }
        }
        return p.indices.filter { keep[$0] }
    }
}

// MARK: - Shape geometry

/// Page-space geometry of a `ShapeItem`, shared by the recogniser (frames of curves), the snapper (vertices) and the
/// live preview (outline). Box kinds are defined by their frame, point kinds by their points. Arcs and curves hold
/// control points (CONTRACTS: ShapeItem.points), outlined exactly as the shape drawer (F031) draws them: an arc is the
/// conic (start, control, end), a curve a Bézier or a clamped B-spline.
enum ShapeGeometry {
    static let boxKinds: Set<ShapeKind> = [.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond]
    static let openKinds: Set<ShapeKind> = [.line, .polyline, .arrow, .arc, .curve]

    /// Whether the shape is drawn from its frame (a box kind without its own vertices).
    static func isBox(_ s: ShapeItem) -> Bool { boxKinds.contains(s.shape) && s.points.isEmpty }

    /// The point offset (dx, dy) from the frame's centre along the frame's own (rotated) axes.
    static func framePoint(_ f: Frame, _ dx: Double, _ dy: Double) -> Point {
        let c = f.center, cs = cos(f.rotation), sn = sin(f.rotation)
        return Point(c.x + dx * cs - dy * sn, c.y + dx * sn + dy * cs)
    }

    /// The points of a point shape, or its frame's diagonal when it has none (lenient AI / plugin JSON).
    static func points(_ s: ShapeItem) -> [Point] {
        if s.points.count >= 2 { return s.points }
        let f = s.frame
        return [Point(f.x, f.y), Point(f.x + f.w, f.y + f.h)]
    }

    /// Polylines outlining the shape in page coordinates; closed outlines repeat their first point, arrows add their head.
    static func outline(_ s: ShapeItem) -> [[Point]] {
        let f = s.frame, hw = f.w / 2, hh = f.h / 2
        func closed(_ p: [Point]) -> [Point] { p.first.map { p + [$0] } ?? p }
        let own = s.points.count >= 3 ? s.points : nil
        switch s.shape {
        case .rectangle, .roundedRectangle:
            return [closed(own ?? f.corners)]
        case .ellipse:
            return [closed((0..<64).map { i -> Point in
                let a = Double(i) / 64 * 2 * Double.pi
                return framePoint(f, hw * cos(a), hh * sin(a))
            })]
        case .triangle:
            return [closed(own ?? [framePoint(f, 0, -hh), framePoint(f, hw, hh), framePoint(f, -hw, hh)])]
        case .diamond:
            return [closed(own ?? [framePoint(f, 0, -hh), framePoint(f, hw, 0), framePoint(f, 0, hh), framePoint(f, -hw, 0)])]
        case .polygon:
            return [closed(points(s))]
        case .arc:
            let p = points(s)
            guard p.count == 3 else { return [p] }
            let w = conicWeight(p[0], p[1], p[2])
            return [(0...48).map { i -> Point in
                let t = Double(i) / 48, u = 1 - t
                let d = u * u + 2 * u * t * w + t * t
                let k0 = u * u / d, k1 = 2 * u * t * w / d, k2 = t * t / d
                return Point(p[0].x * k0 + p[1].x * k1 + p[2].x * k2, p[0].y * k0 + p[1].y * k1 + p[2].y * k2)
            }]
        case .curve:
            return [curvePoints(points(s))]
        case .arrow:
            let p = points(s)
            let tip = p[p.count - 1], from = p[p.count - 2]
            let angle = atan2(tip.y - from.y, tip.x - from.x)
            let length = max(10, s.style.strokeWidth * 4)
            func wing(_ da: Double) -> Point { Point(tip.x - length * cos(angle + da), tip.y - length * sin(angle + da)) }
            return [p, [wing(Double.pi / 7), tip, wing(-Double.pi / 7)]]
        default:
            return [points(s)]
        }
    }

    /// Vertices another shape's end can snap onto: ends and corners, and an ellipse's four axis ends.
    static func anchors(_ s: ShapeItem) -> [Point] {
        let f = s.frame
        switch s.shape {
        case .ellipse where s.points.isEmpty:
            return [framePoint(f, 0, -f.h / 2), framePoint(f, f.w / 2, 0), framePoint(f, 0, f.h / 2), framePoint(f, -f.w / 2, 0)]
        case .arc, .curve:
            let p = points(s)
            return [p[0], p[p.count - 1]]
        default:
            let ring = outline(s).first ?? []
            let isClosed = boxKinds.contains(s.shape) || s.shape == .polygon
            return isClosed ? Array(ring.dropLast()) : ring
        }
    }

    /// Axis-aligned bounds of the outline (without an arrowhead).
    static func bounds(_ s: ShapeItem) -> Rect {
        Rect.bounding(outline(s).first ?? []) ?? s.frame.bounds
    }

    /// The arc's conic weight as the shape drawer computes it: cos of the angle between the chord and the tangents, so
    /// an isosceles (start, control, end) triangle gives a circular arc.
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

    /// A curve as the shape drawer draws it: 2 points a line, 3 a quadratic Bézier (start, control, end), 4 a cubic,
    /// more a uniform cubic B-spline clamped by tripling its ends.
    static func curvePoints(_ p: [Point]) -> [Point] {
        func cubic(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> [Point] {
            (0...16).map { i -> Point in
                let t = Double(i) / 16, u = 1 - t
                let k0 = u * u * u, k1 = 3 * u * u * t, k2 = 3 * u * t * t, k3 = t * t * t
                return Point(a.x * k0 + b.x * k1 + c.x * k2 + d.x * k3, a.y * k0 + b.y * k1 + c.y * k2 + d.y * k3)
            }
        }
        switch p.count {
        case 0...2:
            return p
        case 3:
            return cubic(p[0], p[0] + (p[1] - p[0]) * (2.0 / 3), p[2] + (p[1] - p[2]) * (2.0 / 3), p[2])
        case 4:
            return cubic(p[0], p[1], p[2], p[3])
        default:
            let q = [p[0], p[0]] + p + [p[p.count - 1], p[p.count - 1]]
            var out = [p[0]]
            for i in 0..<(q.count - 3) {
                let c1 = (q[i + 1] * 4 + q[i + 2] * 2) * (1.0 / 6)
                let c2 = (q[i + 1] * 2 + q[i + 2] * 4) * (1.0 / 6)
                let end = (q[i + 1] + q[i + 2] * 4 + q[i + 3]) * (1.0 / 6)
                out += cubic(out[out.count - 1], c1, c2, end).dropFirst()
            }
            return out
        }
    }
}
