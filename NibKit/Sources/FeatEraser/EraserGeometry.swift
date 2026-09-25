import Foundation
import NibContracts

/// How the eraser treats a stroke it touches (parity T-018).
enum EraserMode: String, Codable, CaseIterable, Hashable {
    /// Cuts exactly at the eraser's edge, with interpolated end points.
    case precision
    /// Removes the touched run of points and splits the stroke there.
    case standard
    /// Removes every stroke it touches, whole.
    case stroke
}

/// Pure eraser geometry: capsule hit tests, cutting strokes, shape outlines and scribble coverage.
/// Every eraser path segment is a capsule (the segment swept by the eraser circle). A stroke is touched where its
/// centre line comes within `radius + half its nib width` of that segment, so the ink's visible edge decides, not its
/// centre line; in precision mode the cut lands where the round nib cap meets the eraser circle.
enum EraserGeometry {
    /// Pieces shorter than this (page points) are dropped: they would render as specks.
    static let minPieceLength = 0.3

    // MARK: Primitives

    /// Shortest distance between segments a–b and c–d.
    static func segmentDistance(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Double {
        if Geo.segmentsIntersect(a, b, c, d) { return 0 }
        return min(Geo.distance(a, toSegment: c, d), Geo.distance(b, toSegment: c, d),
                   Geo.distance(c, toSegment: a, b), Geo.distance(d, toSegment: a, b))
    }

    /// The parameters s ∈ [0, 1] of segment a→b that lie inside the capsule of `radius` around c–d, or nil.
    /// The capsule is convex, so the part of a line inside it is one interval: the hull of the line's intersections
    /// with the two end disks and the middle slab.
    static func capsuleInterval(_ a: Point, _ b: Point, _ c: Point, _ d: Point, radius: Double) -> (Double, Double)? {
        var lo = Double.infinity
        var hi = -Double.infinity
        for candidate in [diskInterval(a, b, c, radius), diskInterval(a, b, d, radius), slabInterval(a, b, c, d, radius)] {
            guard let part = candidate else { continue }
            lo = min(lo, part.0)
            hi = max(hi, part.1)
        }
        let s0 = max(0, lo), s1 = min(1, hi)
        return s0 <= s1 ? (s0, s1) : nil
    }

    /// The s where the line a + s·(b − a) is inside the disk (c, r).
    static func diskInterval(_ a: Point, _ b: Point, _ c: Point, _ r: Double) -> (Double, Double)? {
        let ex = b.x - a.x, ey = b.y - a.y
        let fx = a.x - c.x, fy = a.y - c.y
        let qa = ex * ex + ey * ey
        let qc = fx * fx + fy * fy - r * r
        if qa < 1e-12 { return qc <= 0 ? (-Double.infinity, Double.infinity) : nil }
        let qb = 2 * (fx * ex + fy * ey)
        let disc = qb * qb - 4 * qa * qc
        if disc < 0 { return nil }
        let root = disc.squareRoot()
        return ((-qb - root) / (2 * qa), (-qb + root) / (2 * qa))
    }

    /// The s where the line a + s·(b − a) is inside the rectangle of points that project onto c–d within r of it.
    static func slabInterval(_ a: Point, _ b: Point, _ c: Point, _ d: Point, _ r: Double) -> (Double, Double)? {
        let dx = d.x - c.x, dy = d.y - c.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-9 else { return nil }
        let ux = dx / length, uy = dy / length
        let ex = b.x - a.x, ey = b.y - a.y
        let ax = a.x - c.x, ay = a.y - c.y
        guard let along = linear(ax * ux + ay * uy, ex * ux + ey * uy, 0, length),
              let across = linear(ay * ux - ax * uy, ey * ux - ex * uy, -r, r) else { return nil }
        let lo = max(along.0, across.0), hi = min(along.1, across.1)
        return lo <= hi ? (lo, hi) : nil
    }

    /// The s where k0 + s·k1 lies in [lo, hi].
    static func linear(_ k0: Double, _ k1: Double, _ lo: Double, _ hi: Double) -> (Double, Double)? {
        if abs(k1) < 1e-12 { return (lo...hi).contains(k0) ? (-Double.infinity, Double.infinity) : nil }
        let s0 = (lo - k0) / k1, s1 = (hi - k0) / k1
        return (min(s0, s1), max(s0, s1))
    }

    /// Half the rendered nib at a point (half the style's width when the point carries none).
    static func halfWidth(_ p: StrokePoint, style: InkStyle) -> Double {
        let w = Double(max(p.width, p.height))
        return (w > 0 ? w : style.width) / 2
    }

    static func length(_ pts: [StrokePoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i - 1].location.distance(to: pts[i].location) }
        return total
    }

    static func box(_ a: Point, _ b: Point) -> Rect { Rect.bounding([a, b]) ?? .zero }

    // MARK: Cutting strokes

    /// Erases the capsule c–d (eraser `radius`) from one run of stroke points.
    /// nil = untouched; [] = nothing left; otherwise what remains, one array per new stroke. Cut ends are tripled so
    /// PencilKit's B-spline ends exactly there, as `InkModel.densify` does for a stroke's own ends.
    static func cut(_ pts: [StrokePoint], style: InkStyle, from c: Point, to d: Point, radius: Double,
                    mode: EraserMode) -> [[StrokePoint]]? {
        guard let first = pts.first else { return nil }
        let widest = pts.reduce(0.0) { max($0, halfWidth($1, style: style)) }
        guard box(c, d).insetBy(-(radius + widest)).intersects(Rect.bounding(pts.map { $0.location }) ?? .zero) else {
            return nil
        }
        if pts.count == 1 {
            return Geo.distance(first.location, toSegment: c, d) <= radius + halfWidth(first, style: style) ? [] : nil
        }
        switch mode {
        case .stroke: return touches(pts, style: style, c, d, radius: radius) ? [] : nil
        case .standard: return standardCut(pts, style: style, c, d, radius: radius)
        case .precision: return precisionCut(pts, style: style, c, d, radius: radius)
        }
    }

    static func touches(_ pts: [StrokePoint], style: InkStyle, _ c: Point, _ d: Point, radius: Double) -> Bool {
        let eraser = box(c, d)
        for i in 0..<(pts.count - 1) {
            let reach = radius + max(halfWidth(pts[i], style: style), halfWidth(pts[i + 1], style: style))
            let a = pts[i].location, b = pts[i + 1].location
            guard box(a, b).insetBy(-reach).intersects(eraser) else { continue }
            if segmentDistance(a, b, c, d) <= reach { return true }
        }
        return false
    }

    /// Standard: every point under the eraser goes, and so does every segment it crosses; the runs in between become
    /// new strokes.
    static func standardCut(_ pts: [StrokePoint], style: InkStyle, _ c: Point, _ d: Point, radius: Double) -> [[StrokePoint]]? {
        let n = pts.count
        let eraser = box(c, d)
        let reach = pts.map { radius + halfWidth($0, style: style) }
        let goneVertex = (0..<n).map { i -> Bool in
            let p = pts[i].location
            guard eraser.insetBy(-reach[i]).contains(p) else { return false }
            return Geo.distance(p, toSegment: c, d) <= reach[i]
        }
        let goneSegment = (0..<(n - 1)).map { i -> Bool in
            if goneVertex[i] || goneVertex[i + 1] { return true }
            let r = max(reach[i], reach[i + 1])
            let a = pts[i].location, b = pts[i + 1].location
            guard box(a, b).insetBy(-r).intersects(eraser) else { return false }
            return segmentDistance(a, b, c, d) <= r
        }
        guard goneVertex.contains(true) || goneSegment.contains(true) else { return nil }
        var pieces: [[StrokePoint]] = []
        var start: Int?
        for i in 0..<n {
            if goneVertex[i] { continue }
            if start == nil { start = i }
            if i == n - 1 || goneSegment[i], let s = start {
                if let piece = finish(Array(pts[s...i]), cutStart: s > 0, cutEnd: i < n - 1) { pieces.append(piece) }
                start = nil
            }
        }
        return pieces
    }

    /// Precision: exactly the parts of each segment inside the capsule go; the new ends are interpolated (position,
    /// time, pressure, tilt and nib size).
    static func precisionCut(_ pts: [StrokePoint], style: InkStyle, _ c: Point, _ d: Point, radius: Double) -> [[StrokePoint]]? {
        let n = pts.count
        let eraser = box(c, d)
        var gone: [(Double, Double)] = []
        for i in 0..<(n - 1) {
            let reach = radius + max(halfWidth(pts[i], style: style), halfWidth(pts[i + 1], style: style))
            let a = pts[i].location, b = pts[i + 1].location
            guard box(a, b).insetBy(-reach).intersects(eraser),
                  let s = capsuleInterval(a, b, c, d, radius: reach) else { continue }
            // A tangent graze removes nothing and must not split the stroke.
            let segment = a.distance(to: b)
            if segment > 1e-9 && (s.1 - s.0) * segment < 1e-6 { continue }
            gone.append((Double(i) + s.0, Double(i) + s.1))
        }
        guard !gone.isEmpty else { return nil }
        gone.sort { $0.0 < $1.0 }
        let end = Double(n - 1)
        var kept: [(Double, Double)] = []
        var from = 0.0
        for g in gone {
            if g.0 > from { kept.append((from, g.0)) }
            from = max(from, g.1)
        }
        if from < end { kept.append((from, end)) }

        func point(at t: Double) -> StrokePoint {
            if t == t.rounded() { return pts[min(n - 1, Int(t))] }
            let i = min(Int(t), n - 2)
            return StrokePoint.lerp(pts[i], pts[i + 1], Float(t - Double(i)))
        }
        return kept.compactMap { range -> [StrokePoint]? in
            let (u, v) = range
            var out = [point(at: u)]
            var k = Int(u.rounded(.down)) + 1
            while Double(k) < v {
                out.append(pts[k])
                k += 1
            }
            out.append(point(at: v))
            return finish(out, cutStart: u > 0, cutEnd: v < end)
        }
    }

    /// Triples cut ends and drops specks.
    static func finish(_ piece: [StrokePoint], cutStart: Bool, cutEnd: Bool) -> [StrokePoint]? {
        guard piece.count >= 2, length(piece) >= minPieceLength, let first = piece.first, let last = piece.last else {
            return nil
        }
        var out = piece
        if cutStart { out.insert(contentsOf: [first, first], at: 0) }
        if cutEnd { out.append(contentsOf: [last, last]) }
        return out
    }

    // MARK: Shapes and connectors

    /// What the eraser tests on a shape or connector: its outline (closed for box shapes), whether its inside counts
    /// (filled closed shapes) and half its outline width.
    struct Outline: Equatable {
        var points: [Point]
        var closed: Bool
        var filled: Bool
        var halfWidth: Double
    }

    static func outline(_ item: Item) -> Outline? {
        if let s = item.shape {
            let f = s.frame
            let half = s.style.strokeColor == nil ? 0 : s.style.strokeWidth / 2
            let filled = (s.style.fillColor?.a ?? 0) > 0
            func at(_ u: Double, _ v: Double) -> Point { framePoint(f, u, v) }
            func closed(_ pts: [Point]) -> Outline { Outline(points: pts, closed: true, filled: filled, halfWidth: half) }
            switch s.shape {
            case .rectangle, .roundedRectangle:
                return closed(f.corners)
            case .ellipse:
                return closed((0..<36).map { k -> Point in
                    let a = Double(k) / 36 * 2 * Double.pi
                    return at(0.5 + cos(a) / 2, 0.5 + sin(a) / 2)
                })
            case .triangle:
                return closed([at(0.5, 0), at(1, 1), at(0, 1)])
            case .diamond:
                return closed([at(0.5, 0), at(1, 0.5), at(0.5, 1), at(0, 0.5)])
            case .polygon:
                return closed(s.points.count >= 3 ? s.points : f.corners)
            default:
                // Lines, polylines, arrows, arcs and curves: their points (the control points of curves).
                let pts = s.points.count >= 2 ? s.points : [at(0, 0), at(1, 1)]
                return Outline(points: pts, closed: false, filled: false, halfWidth: half)
            }
        }
        if let c = item.connector {
            return Outline(points: [c.from.point] + c.bends + [c.to.point], closed: false, filled: false,
                           halfWidth: c.style.strokeWidth / 2)
        }
        return nil
    }

    /// A point of a frame in unit coordinates of the unrotated box, rotated about the frame's centre.
    static func framePoint(_ f: Frame, _ u: Double, _ v: Double) -> Point {
        let centre = f.center
        let dx = (u - 0.5) * f.w, dy = (v - 0.5) * f.h
        let cs = cos(f.rotation), sn = sin(f.rotation)
        return Point(centre.x + dx * cs - dy * sn, centre.y + dx * sn + dy * cs)
    }

    static func hits(_ o: Outline, from c: Point, to d: Point, radius: Double) -> Bool {
        let reach = radius + o.halfWidth
        var pts = o.points
        if o.closed, let first = pts.first { pts.append(first) }
        if pts.count == 1 { return Geo.distance(pts[0], toSegment: c, d) <= reach }
        for i in 0..<max(0, pts.count - 1) where segmentDistance(pts[i], pts[i + 1], c, d) <= reach { return true }
        return o.filled && o.closed && (Geo.polygonContains(o.points, c) || Geo.polygonContains(o.points, d))
    }

    // MARK: Scribble to Erase

    /// Convex hull (Andrew's monotone chain).
    static func convexHull(_ points: [Point]) -> [Point] {
        let pts = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard pts.count > 2 else { return pts }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Point] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Point] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    /// Share of a stroke's points that must lie under the scribble for it to go.
    static let scribbleCoverage = 0.6
    /// How far outside the scribble's hull a point still counts as covered (page points).
    static let scribbleTolerance = 3.0

    /// True when most of the stroke lies under the scribble (inside its convex hull, give or take the tolerance), so a
    /// long line the scribble merely crosses survives.
    static func scribbleCovers(_ stroke: Stroke, hull: [Point], tolerance: Double = scribbleTolerance) -> Bool {
        guard !stroke.points.isEmpty, let hullBox = Rect.bounding(hull),
              stroke.bounds.intersects(hullBox.insetBy(-tolerance)) else { return false }
        var ring = hull
        if hull.count > 2, let first = hull.first { ring.append(first) }
        func near(_ p: Point) -> Bool {
            if hull.count > 2 && Geo.polygonContains(hull, p) { return true }
            if ring.count == 1 { return p.distance(to: ring[0]) <= tolerance }
            for i in 0..<max(0, ring.count - 1) where Geo.distance(p, toSegment: ring[i], ring[i + 1]) <= tolerance {
                return true
            }
            return false
        }
        let covered = stroke.points.reduce(0) { $0 + (near($1.location) ? 1 : 0) }
        return Double(covered) >= Double(stroke.points.count) * scribbleCoverage
    }
}

/// One eraser gesture over one page. Feed it the eraser path point by point: the canvas tool does so live (to hide
/// and preview what it will erase) and `ink.erase` does so for the whole path, so both follow the same rules.
/// Only live, unlocked items on `layer` take part: strokes whose tool is in `filter`, and shapes and connectors with no
/// attached children (under the "pen" filter entry, or the tool a snapped shape was drawn with).
struct EraseSession {
    enum Target {
        case stroke(Stroke)
        case outline(EraserGeometry.Outline)
    }

    struct Candidate {
        let item: Item
        let bounds: Rect
        let target: Target
    }

    let radius: Double
    let mode: EraserMode
    let filter: Set<InkTool>
    let layer: Int
    private(set) var candidates: [Candidate] = []
    private(set) var path: [Point] = []
    /// Strokes cut so far (precision and standard): what is left of each ([] = nothing).
    private(set) var pieces: [ElementID: [[StrokePoint]]] = [:]
    /// Items erased whole (stroke mode, shapes and connectors).
    private(set) var erased: Set<ElementID> = []

    /// `region`, when known up front (a whole path), skips items that cannot be reached.
    /// ponytail: a linear bounds scan per path segment; add a spatial grid if pages with 10k+ items lag.
    init(items: [Item], radius: Double, mode: EraserMode, filter: Set<InkTool>, layer: Int, region: Rect? = nil) {
        self.radius = radius
        self.mode = mode
        self.filter = filter
        self.layer = layer
        let live = items.filter { !$0.deleted }
        let parents = Set(live.compactMap { $0.attachedTo })
        for item in live where !item.locked && item.layer == layer && (region?.intersects(item.bounds) ?? true) {
            switch item.kind {
            case .stroke:
                guard let s = item.stroke, filter.contains(s.style.tool) else { continue }
                candidates.append(Candidate(item: item, bounds: item.bounds, target: .stroke(s)))
            case .shape, .connector:
                let tool = item.shape?.style.drawnWith ?? .pen
                guard filter.contains(tool), !parents.contains(item.id), let o = EraserGeometry.outline(item) else { continue }
                candidates.append(Candidate(item: item, bounds: item.bounds, target: .outline(o)))
            default:
                continue
            }
        }
    }

    /// Every item the gesture has erased or cut so far.
    var affected: Set<ElementID> { erased.union(pieces.keys) }

    /// A candidate stroke as it was before the gesture (previews draw its remaining pieces in its style).
    func stroke(_ id: ElementID) -> Stroke? {
        for c in candidates where c.item.id == id {
            if case .stroke(let s) = c.target { return s }
        }
        return nil
    }

    /// Moves the eraser to `p` (the first call places it); returns the ids whose result changed.
    @discardableResult
    mutating func extend(to p: Point) -> Set<ElementID> {
        let c = path.last ?? p
        path.append(p)
        let reach = EraserGeometry.box(c, p).insetBy(-radius)
        var changed = Set<ElementID>()
        for candidate in candidates where !erased.contains(candidate.item.id) && reach.intersects(candidate.bounds) {
            let id = candidate.item.id
            switch candidate.target {
            case .outline(let o):
                if EraserGeometry.hits(o, from: c, to: p, radius: radius) {
                    erased.insert(id)
                    changed.insert(id)
                }
            case .stroke(let s):
                let current = pieces[id] ?? [s.points]
                guard !current.isEmpty else { continue }
                var next: [[StrokePoint]] = []
                var touched = false
                for piece in current {
                    if let rest = EraserGeometry.cut(piece, style: s.style, from: c, to: p, radius: radius, mode: mode) {
                        touched = true
                        next += rest
                    } else {
                        next.append(piece)
                    }
                }
                guard touched else { continue }
                if mode == .stroke {
                    erased.insert(id)
                } else {
                    pieces[id] = next
                }
                changed.insert(id)
            }
        }
        return changed
    }

    /// What committing the gesture does: the items to remove, and the strokes replacing each cut one (z order).
    var plan: (remove: Set<ElementID>, splits: [(original: Item, strokes: [Stroke])]) {
        var splits: [(original: Item, strokes: [Stroke])] = []
        for c in candidates {
            guard let rest = pieces[c.item.id], case .stroke(let s) = c.target else { continue }
            let strokes = rest.map { points -> Stroke in
                var piece = s
                piece.points = points
                return piece
            }
            splits.append((original: c.item, strokes: strokes))
        }
        return (remove: affected, splits: splits)
    }
}
