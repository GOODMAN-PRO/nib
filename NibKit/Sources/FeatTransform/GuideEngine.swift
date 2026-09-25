import Foundation
import NibContracts

/// Alignment guides, smart equal-spacing guides and template-grid snapping for a box being moved or resized.
/// Pure value logic in page points: the drag controller feeds it rects and draws what it returns.
struct GuideEngine {
    enum Style: Equatable {
        /// Edge to edge: a solid line.
        case edge
        /// Anything involving a centre: a dashed line.
        case centre
        /// Equal gaps between neighbours: dashed segments inside each gap.
        case spacing
    }

    struct Guide: Equatable {
        /// true: a vertical line at x = `position` from y = `start` to `end`; false: a horizontal line at y = `position`.
        var vertical: Bool
        var position: Double
        var start: Double
        var end: Double
        var style: Style
    }

    /// Evenly spaced template lines along one axis: origin + k · step.
    struct Lines: Equatable {
        var origin: Double
        var step: Double

        func nearest(_ v: Double) -> Double {
            guard step > 0 else { return v }
            return origin + ((v - origin) / step).rounded() * step
        }
    }

    struct Grid: Equatable {
        var x: Lines?
        var y: Lines?

        /// Grid lines of a rendered template: `vlines` give x, `hlines` give y, `dots` give both (first op wins).
        static func from(_ display: DisplayList) -> Grid? {
            var x: Lines?
            var y: Lines?
            for op in display.ops {
                guard let r = op.rect else { continue }
                let step = max(op.spacing ?? 24, 1)       // DisplayList.draw's own default spacing
                switch op.op {
                case .hlines:
                    if y == nil { y = Lines(origin: r.minY, step: step) }
                case .vlines:
                    if x == nil { x = Lines(origin: r.minX, step: step) }
                case .dots:
                    if x == nil { x = Lines(origin: r.minX, step: step) }
                    if y == nil { y = Lines(origin: r.minY, step: step) }
                default:
                    break
                }
            }
            return x == nil && y == nil ? nil : Grid(x: x, y: y)
        }
    }

    /// The edges a resize moves.
    struct Edges: OptionSet {
        let rawValue: Int
        static let minX = Edges(rawValue: 1)
        static let maxX = Edges(rawValue: 2)
        static let minY = Edges(rawValue: 4)
        static let maxY = Edges(rawValue: 8)
    }

    struct Result: Equatable {
        /// Add to the moving rect (move), or to the moving edges (resize).
        var offset = Point.zero
        var guides: [Guide] = []
        /// The line each axis snapped to (nil = free). A new value is a new snap: the caller plays the haptic.
        var snapX: Double?
        var snapY: Double?
    }

    /// Boxes of the other objects on the page (page points).
    var others: [Rect]
    /// The page, for its centre lines (nil = infinite board).
    var page: Rect?
    var grid: Grid?
    /// NibSettings.alignObjects.
    var align: Bool
    /// NibSettings.snapToGrid.
    var snapToGrid: Bool
    /// Snap distance in page points (a few view points divided by the zoom).
    var tolerance: Double

    /// Things worth aligning to: objects, not individual handwriting strokes (a word is several strokes) or comment pins.
    /// ponytail: ink strokes are skipped wholesale; cluster them into words if handwriting guides are ever wanted.
    static func isGuideSource(_ item: Item) -> Bool {
        switch item.kind {
        case .comment: return false
        case .stroke: return item.stroke?.style.tool == .tape
        case .text: return !(item.text?.style.fullPage ?? false)
        default: return true
        }
    }

    // MARK: Move

    /// Snaps a moved box: alignment (edges and centres) and equal spacing within `tolerance`, else the grid.
    func move(_ r: Rect, lockX: Bool = false, lockY: Bool = false) -> Result {
        var result = Result()
        if !lockX, let s = snap(r, .x, anchors: [(r.minX, false), (r.midX, true), (r.maxX, false)], spacing: true) {
            result.offset.x = s.delta
            result.snapX = s.target
        }
        if !lockY, let s = snap(r, .y, anchors: [(r.minY, false), (r.midY, true), (r.maxY, false)], spacing: true) {
            result.offset.y = s.delta
            result.snapY = s.target
        }
        result.guides = guides(for: Rect(x: r.x + result.offset.x, y: r.y + result.offset.y, width: r.width, height: r.height))
        return result
    }

    // MARK: Resize

    /// Snaps the moving edges of a resized box to other objects' edges and centres (then the grid).
    func resize(_ r: Rect, edges: Edges) -> Result {
        var result = Result()
        var out = r
        if edges.contains(.minX) != edges.contains(.maxX) {
            let moving = edges.contains(.minX) ? r.minX : r.maxX
            if let s = snap(r, .x, anchors: [(moving, false)], spacing: false) {
                result.offset.x = s.delta
                result.snapX = s.target
                if edges.contains(.minX) {
                    out.x += s.delta
                    out.width -= s.delta
                } else {
                    out.width += s.delta
                }
            }
        }
        if edges.contains(.minY) != edges.contains(.maxY) {
            let moving = edges.contains(.minY) ? r.minY : r.maxY
            if let s = snap(r, .y, anchors: [(moving, false)], spacing: false) {
                result.offset.y = s.delta
                result.snapY = s.target
                if edges.contains(.minY) {
                    out.y += s.delta
                    out.height -= s.delta
                } else {
                    out.height += s.delta
                }
            }
        }
        result.guides = guides(for: out)
        return result
    }

    // MARK: Guides that hold

    /// Every alignment and equal gap that holds exactly for `r` (so a box dropped in place shows its guides too).
    func guides(for r: Rect) -> [Guide] {
        guard align else { return [] }
        var out: [Guide] = []
        for axis in [Axis.x, Axis.y] {
            let anchors: [(Double, Bool)] = [(axis.lo(r), false), (axis.mid(r), true), (axis.hi(r), false)]
            let cross = axis.cross
            for (o, isPage) in targets {
                for (c, cMid) in axis.lines(o, pageCentreOnly: isPage) {
                    for (a, aMid) in anchors where abs(c - a) < Self.exact {
                        out.append(Guide(vertical: axis == .x, position: c,
                                         start: min(cross.lo(r), cross.lo(o)), end: max(cross.hi(r), cross.hi(o)),
                                         style: cMid || aMid ? .centre : .edge))
                    }
                }
            }
            for s in spacingTargets(r, axis) where abs(s.target - axis.lo(r)) < Self.exact {
                out += s.guides
            }
        }
        return merged(out)
    }

    // MARK: Internals

    static let exact = 0.01

    enum Axis: Equatable {
        case x, y

        var cross: Axis { self == .x ? .y : .x }
        func lo(_ r: Rect) -> Double { self == .x ? r.minX : r.minY }
        func hi(_ r: Rect) -> Double { self == .x ? r.maxX : r.maxY }
        func mid(_ r: Rect) -> Double { self == .x ? r.midX : r.midY }

        /// Alignment lines of a box: both edges and the centre (the page offers its centre only).
        func lines(_ r: Rect, pageCentreOnly: Bool) -> [(Double, Bool)] {
            pageCentreOnly ? [(mid(r), true)] : [(lo(r), false), (mid(r), true), (hi(r), false)]
        }
    }

    private struct Snap {
        var delta: Double
        var target: Double
    }

    private struct SpacingTarget {
        /// Where the moving box's low edge goes.
        var target: Double
        var guides: [Guide]
    }

    private var targets: [(Rect, Bool)] {
        others.map { ($0, false) } + (page.map { [($0, true)] } ?? [])
    }

    private func snap(_ r: Rect, _ axis: Axis, anchors: [(Double, Bool)], spacing: Bool) -> Snap? {
        var best: Snap?
        func consider(_ delta: Double, _ target: Double) {
            guard abs(delta) <= tolerance, abs(delta) < abs(best?.delta ?? .infinity) - 1e-9 else { return }
            best = Snap(delta: delta, target: target)
        }
        if align {
            for (o, isPage) in targets {
                for (c, _) in axis.lines(o, pageCentreOnly: isPage) {
                    for (a, _) in anchors { consider(c - a, c) }
                }
            }
            if spacing {
                for s in spacingTargets(r, axis) { consider(s.target - axis.lo(r), s.target) }
            }
        }
        if best == nil, snapToGrid, let lines = axis == .x ? grid?.x : grid?.y {
            // The grid always snaps: the edge nearer to a line lands on it (the low edge on a tie).
            var g: Snap?
            for (a, isMid) in anchors where !isMid {
                let t = lines.nearest(a)
                if abs(t - a) < abs(g?.delta ?? .infinity) - 1e-9 { g = Snap(delta: t - a, target: t) }
            }
            best = g
        }
        return best
    }

    /// Positions that make the moving box's gaps equal to its row neighbours' (centred between two neighbours, or
    /// continuing a run of equally spaced boxes on either side).
    private func spacingTargets(_ r: Rect, _ axis: Axis) -> [SpacingTarget] {
        let cross = axis.cross
        let row = others.filter { cross.lo($0) < cross.hi(r) && cross.hi($0) > cross.lo(r) }
        let before = row.filter { axis.hi($0) <= axis.mid(r) }.sorted { axis.hi($0) > axis.hi($1) }
        let after = row.filter { axis.lo($0) >= axis.mid(r) }.sorted { axis.lo($0) < axis.lo($1) }
        let size = axis.hi(r) - axis.lo(r)
        var out: [SpacingTarget] = []

        func gapGuide(_ from: Double, _ to: Double, _ a: Rect, _ b: Rect) -> Guide {
            let mid = (max(cross.lo(a), cross.lo(b)) + min(cross.hi(a), cross.hi(b))) / 2
            return Guide(vertical: axis == .y, position: mid, start: from, end: to, style: .spacing)
        }
        func placed(_ lo: Double) -> Rect {
            axis == .x ? Rect(x: lo, y: r.y, width: r.width, height: r.height)
                       : Rect(x: r.x, y: lo, width: r.width, height: r.height)
        }

        if let l = before.first, let n = after.first {
            let gap = (axis.lo(n) - axis.hi(l) - size) / 2
            if gap > 0 {
                let t = axis.hi(l) + gap
                let m = placed(t)
                out.append(SpacingTarget(target: t, guides: [gapGuide(axis.hi(l), t, l, m),
                                                              gapGuide(t + size, axis.lo(n), m, n)]))
            }
        }
        if let l = before.first, let l2 = before.first(where: { axis.hi($0) <= axis.lo(l) }) {
            let gap = axis.lo(l) - axis.hi(l2)
            if gap > 0 {
                let t = axis.hi(l) + gap
                out.append(SpacingTarget(target: t, guides: [gapGuide(axis.hi(l2), axis.lo(l), l2, l),
                                                              gapGuide(axis.hi(l), t, l, placed(t))]))
            }
        }
        if let n = after.first, let n2 = after.first(where: { axis.lo($0) >= axis.hi(n) }) {
            let gap = axis.lo(n2) - axis.hi(n)
            if gap > 0 {
                let t = axis.lo(n) - gap - size
                out.append(SpacingTarget(target: t, guides: [gapGuide(t + size, axis.lo(n), placed(t), n),
                                                              gapGuide(axis.hi(n), axis.lo(n2), n, n2)]))
            }
        }
        return out
    }

    /// One line per position and style, spanning everything that aligns there.
    private func merged(_ guides: [Guide]) -> [Guide] {
        var out: [Guide] = []
        for g in guides {
            if g.style != .spacing,
               let i = out.firstIndex(where: { $0.vertical == g.vertical && $0.style == g.style
                                               && abs($0.position - g.position) < Self.exact }) {
                out[i].start = min(out[i].start, g.start)
                out[i].end = max(out[i].end, g.end)
            } else if !out.contains(g) {
                out.append(g)
            }
        }
        return out
    }
}
