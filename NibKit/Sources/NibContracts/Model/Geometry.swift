import Foundation

/// A point in page coordinates: PDF points (1/72 in), origin at the page's top-left, y grows downward.
/// Encoded as `[x, y]`.
public struct Point: Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }

    public func distance(to p: Point) -> Double { hypot(p.x - x, p.y - y) }

    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, s: Double) -> Point { Point(a.x * s, a.y * s) }
}

/// Axis-aligned rectangle in page coordinates. Encoded as `[x, y, width, height]`.
public struct Rect: Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(width)
        try c.encode(height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Point { Point(midX, midY) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func union(_ r: Rect) -> Rect {
        let nx = min(x, r.x), ny = min(y, r.y)
        return Rect(x: nx, y: ny, width: max(maxX, r.maxX) - nx, height: max(maxY, r.maxY) - ny)
    }

    public func intersects(_ r: Rect) -> Bool {
        x <= r.maxX && r.x <= maxX && y <= r.maxY && r.y <= maxY
    }

    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
    }

    public func contains(_ r: Rect) -> Bool {
        r.x >= x && r.maxX <= maxX && r.y >= y && r.maxY <= maxY
    }

    /// Positive `d` shrinks, negative grows.
    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    public static func bounding(_ points: [Point]) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A possibly rotated box: position/size of the unrotated box plus rotation (radians, clockwise on screen)
/// about its center. Used by shapes, text boxes, images, sticky notes, math and custom items.
public struct Frame: Hashable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var rotation: Double

    public init(x: Double, y: Double, w: Double, h: Double, rotation: Double = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rotation = rotation
    }

    public init(_ r: Rect, rotation: Double = 0) {
        self.init(x: r.x, y: r.y, w: r.width, h: r.height, rotation: rotation)
    }

    enum CodingKeys: String, CodingKey { case x, y, w, h, rotation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }

    public var rect: Rect { Rect(x: x, y: y, width: w, height: h) }
    public var center: Point { Point(x + w / 2, y + h / 2) }

    /// Corners (top-left, top-right, bottom-right, bottom-left) after rotation.
    public var corners: [Point] {
        let c = center
        let hw = w / 2, hh = h / 2
        let cs = cos(rotation), sn = sin(rotation)
        let offsets: [(Double, Double)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        return offsets.map { d in Point(c.x + d.0 * cs - d.1 * sn, c.y + d.0 * sn + d.1 * cs) }
    }

    /// Axis-aligned bounds of the rotated box.
    public var bounds: Rect {
        if rotation == 0 { return rect }
        return Rect.bounding(corners) ?? rect
    }

    /// Applies an affine transform (translation, uniform/non-uniform scale, rotation; shear is ignored).
    public func applying(_ t: Affine) -> Frame {
        let c = t.apply(center)
        let sx = hypot(t.a, t.b), sy = hypot(t.c, t.d)
        let nw = w * sx, nh = h * sy
        return Frame(x: c.x - nw / 2, y: c.y - nh / 2, w: nw, h: nh, rotation: rotation + atan2(t.b, t.a))
    }
}

/// 2-D affine transform in CoreGraphics convention: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
/// Encoded as `[a, b, c, d, tx, ty]`.
public struct Affine: Hashable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ dx: Double, _ dy: Double) -> Affine {
        Affine(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }

    public static func scale(_ sx: Double, _ sy: Double, about p: Point = .zero) -> Affine {
        translation(-p.x, -p.y)
            .concatenating(Affine(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0))
            .concatenating(translation(p.x, p.y))
    }

    public static func rotation(_ radians: Double, about p: Point = .zero) -> Affine {
        let cs = cos(radians), sn = sin(radians)
        return translation(-p.x, -p.y)
            .concatenating(Affine(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0))
            .concatenating(translation(p.x, p.y))
    }

    /// `self` first, then `t`.
    public func concatenating(_ t: Affine) -> Affine {
        Affine(a: a * t.a + b * t.c,
               b: a * t.b + b * t.d,
               c: c * t.a + d * t.c,
               d: c * t.b + d * t.d,
               tx: tx * t.a + ty * t.c + t.tx,
               ty: tx * t.b + ty * t.d + t.ty)
    }

    public func apply(_ p: Point) -> Point {
        Point(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    public var determinant: Double { a * d - b * c }

    public init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(Double.self)
        b = try u.decode(Double.self)
        c = try u.decode(Double.self)
        d = try u.decode(Double.self)
        tx = try u.decode(Double.self)
        ty = try u.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        try u.encode(a)
        try u.encode(b)
        try u.encode(c)
        try u.encode(d)
        try u.encode(tx)
        try u.encode(ty)
    }
}

/// Shared geometry helpers (hit testing, lasso, eraser, recognition).
public enum Geo {
    public static func distance(_ p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: Point(a.x + t * dx, a.y + t * dy))
    }

    /// Even-odd point-in-polygon test.
    public static func polygonContains(_ polygon: [Point], _ p: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func segmentsIntersect(_ p1: Point, _ p2: Point, _ q1: Point, _ q2: Point) -> Bool {
        func orient(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2)
        let d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// True when any vertex of `line` is inside `polygon` or any segment crosses its boundary.
    public static func polylineTouchesPolygon(_ line: [Point], _ polygon: [Point]) -> Bool {
        if line.contains(where: { polygonContains(polygon, $0) }) { return true }
        guard polygon.count >= 2, line.count >= 2 else { return false }
        for i in 0..<(line.count - 1) {
            for j in 0..<polygon.count {
                let k = (j + 1) % polygon.count
                if segmentsIntersect(line[i], line[i + 1], polygon[j], polygon[k]) { return true }
            }
        }
        return false
    }

    public static func pathLength(_ pts: [Point]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i - 1].distance(to: pts[i]) }
        return total
    }

    /// Resamples a polyline to `count` evenly spaced points.
    public static func resample(_ pts: [Point], count: Int) -> [Point] {
        guard pts.count > 1, count > 1 else { return pts }
        let total = pathLength(pts)
        if total == 0 { return Array(repeating: pts[0], count: count) }
        let step = total / Double(count - 1)
        var out = [pts[0]]
        var acc = 0.0
        var prev = pts[0]
        var i = 1
        while i < pts.count && out.count < count {
            let cur = pts[i]
            let d = prev.distance(to: cur)
            if d > 0 && acc + d >= step {
                let t = (step - acc) / d
                let q = Point(prev.x + t * (cur.x - prev.x), prev.y + t * (cur.y - prev.y))
                out.append(q)
                prev = q
                acc = 0
            } else {
                acc += d
                prev = cur
                i += 1
            }
        }
        while out.count < count { out.append(pts[pts.count - 1]) }
        return out
    }

    /// Douglas–Peucker simplification.
    public static func simplify(_ pts: [Point], tolerance: Double) -> [Point] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let pair = stack.popLast() {
            let s = pair.0, e = pair.1
            guard e > s + 1 else { continue }
            var maxD = 0.0
            var idx = -1
            for i in (s + 1)..<e {
                let d = distance(pts[i], toSegment: pts[s], pts[e])
                if d > maxD {
                    maxD = d
                    idx = i
                }
            }
            if idx >= 0 && maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}
