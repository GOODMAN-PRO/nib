import Foundation
import NibContracts

/// Pen gestures (T-023/S-040 Scribble to Erase, T-024/S-041 Circle to Lasso, P-039 their toggles). The detectors are
/// pure geometry on a stroke's polyline in page points; `scale` is the zoom (view points per page point), so every
/// threshold below is what the user sees on screen whatever the zoom.
enum PenGestureTuning {
    // Scribble to Erase: a dense back-and-forth motion.
    /// Direction reversals along the scribble's main axis (5 passes).
    static let scribbleMinReversals = 4
    /// The scribble's length along its main axis, in screen points.
    static let scribbleMinExtent: Double = 14
    /// A reversal counts once the pen has come back this fraction of the scribble's length (hysteresis).
    static let scribbleHysteresis = 0.2
    /// Half the passes cover at least this fraction of the scribble's length (back and forth, not a wave).
    static let scribbleMinSwing = 0.45
    /// Path length over the scribble's length.
    static let scribbleMinDensity = 3.0
    /// A scribble turns one way, then the other: its net turning stays below this share of its total turning
    /// (circling a word several times turns one way only, and is not a scribble).
    static let scribbleMaxNetTurning = 0.5

    // Circle to Lasso: one closed loop.
    /// The loop's smaller side, in screen points (a letter o is smaller).
    static let loopMinSize: Double = 28
    /// The loop's path length, in screen points.
    static let loopMinLength: Double = 90
    /// Ends closer than this (screen points), or than this share of the path, close the loop.
    static let loopMaxGap: Double = 18
    static let loopMaxGapShare = 0.14
    /// One turn, with room for an overshoot: the net turning in radians.
    static let loopMinWinding = 1.55 * Double.pi
    static let loopMaxWinding = 2.9 * Double.pi
    /// 4πA / L²: 1 for a circle, about 0.4 for a 6:1 ellipse, near 0 for a sliver.
    static let loopMinCompactness = 0.2
    /// How long after the loop a long-press may turn it into a lasso.
    static let lassoWindow: TimeInterval = 3
    /// How close to the loop's line (or inside it) the long-press must be, in screen points.
    static let lassoHitTolerance: Double = 16
    /// A held "stroke" this small (screen points) is a press, not writing.
    static let dotMaxExtent: Double = 10
}

/// Small geometry helpers shared by the detectors and the tool.
enum PenGeometry {
    /// `points` without consecutive duplicates.
    static func deduplicated(_ points: [Point]) -> [Point] {
        var out: [Point] = []
        out.reserveCapacity(points.count)
        for p in points where p.x.isFinite && p.y.isFinite {
            if let last = out.last, last.distance(to: p) < 1e-6 { continue }
            out.append(p)
        }
        return out
    }

    /// Net (signed) and total (absolute) turning of a polyline, in radians.
    static func turning(_ points: [Point]) -> (net: Double, total: Double) {
        guard points.count >= 3 else { return (0, 0) }
        var net = 0.0, total = 0.0
        for i in 1..<(points.count - 1) {
            let a = points[i] - points[i - 1]
            let b = points[i + 1] - points[i]
            let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
            guard la > 1e-9, lb > 1e-9 else { continue }
            let angle = atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
            net += angle
            total += abs(angle)
        }
        return (net, total)
    }

    /// Area of the polygon the polyline makes when its ends are joined (shoelace, unsigned).
    static func area(_ points: [Point]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Distance from `p` to a polyline (its closing segment included when `closed`).
    static func distance(_ p: Point, toPolyline line: [Point], closed: Bool) -> Double {
        guard let first = line.first else { return .infinity }
        guard line.count > 1 else { return p.distance(to: first) }
        var best = Double.infinity
        for i in 1..<line.count { best = min(best, Geo.distance(p, toSegment: line[i - 1], line[i])) }
        if closed, let last = line.last { best = min(best, Geo.distance(p, toSegment: last, first)) }
        return best
    }

    /// The polyline resampled to about `spacing` apart (between 16 and 256 points).
    static func resampled(_ points: [Point], spacing: Double) -> [Point] {
        let length = Geo.pathLength(points)
        guard points.count >= 2, length > 0, spacing > 0 else { return points }
        let count = min(max(Int((length / spacing).rounded()), 16), 256)
        return Geo.resample(points, count: count)
    }

    /// At most `limit` points, evenly picked, both ends kept (commands cap their point lists).
    static func thinned(_ points: [Point], limit: Int) -> [Point] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[min(points.count - 1, Int((Double($0) * step).rounded()))] }
    }
}

// MARK: - Scribble to Erase

enum ScribbleDetector {
    struct Analysis: Equatable {
        /// Direction reversals along the main axis.
        var reversals: Int
        /// Length along the main axis (page points).
        var extent: Double
        var pathLength: Double
        /// The median pass length along the main axis.
        var medianSwing: Double
        var netTurning: Double
        var totalTurning: Double
    }

    /// The back-and-forth structure of a stroke: passes along its principal axis (the direction of greatest spread)
    /// separated by reversals with hysteresis, so the humps of handwriting (m, w, cursive loops), which advance along
    /// the line, never count as reversals.
    static func analyse(_ raw: [Point]) -> Analysis? {
        let points = PenGeometry.deduplicated(raw)
        guard points.count >= 6 else { return nil }
        let n = Double(points.count)
        var cx = 0.0, cy = 0.0
        for p in points {
            cx += p.x
            cy += p.y
        }
        cx /= n
        cy /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        guard sxx + syy > 1e-9 else { return nil }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let ux = cos(theta), uy = sin(theta)
        let along = points.map { ($0.x - cx) * ux + ($0.y - cy) * uy }
        guard let lo = along.min(), let hi = along.max(), hi - lo > 0 else { return nil }
        let extent = hi - lo
        let h = extent * PenGestureTuning.scribbleHysteresis
        var swings: [Double] = []
        var direction = 0
        var turn = along[0]
        var extreme = along[0]
        for v in along.dropFirst() {
            switch direction {
            case 0:
                if v - turn > h {
                    direction = 1
                    extreme = v
                } else if turn - v > h {
                    direction = -1
                    extreme = v
                }
            case 1:
                if v > extreme {
                    extreme = v
                } else if extreme - v > h {
                    swings.append(extreme - turn)
                    turn = extreme
                    extreme = v
                    direction = -1
                }
            default:
                if v < extreme {
                    extreme = v
                } else if v - extreme > h {
                    swings.append(turn - extreme)
                    turn = extreme
                    extreme = v
                    direction = 1
                }
            }
        }
        if direction != 0 { swings.append(abs(extreme - turn)) }
        let median = swings.isEmpty ? 0 : swings.sorted()[swings.count / 2]
        let turning = PenGeometry.turning(PenGeometry.resampled(points, spacing: max(extent / 40, 0.5)))
        return Analysis(reversals: max(swings.count - 1, 0), extent: extent, pathLength: Geo.pathLength(points),
                        medianSwing: median, netTurning: turning.net, totalTurning: turning.total)
    }

    /// True for a dense back-and-forth scribble at least `scribbleMinExtent` screen points long.
    static func isScribble(_ points: [Point], scale: Double = 1) -> Bool {
        guard let a = analyse(points) else { return false }
        let k = max(scale, 0.01)
        return a.reversals >= PenGestureTuning.scribbleMinReversals
            && a.extent * k >= PenGestureTuning.scribbleMinExtent
            && a.medianSwing >= PenGestureTuning.scribbleMinSwing * a.extent
            && a.pathLength >= PenGestureTuning.scribbleMinDensity * a.extent
            && abs(a.netTurning) <= PenGestureTuning.scribbleMaxNetTurning * max(a.totalTurning, 1e-9)
    }
}

// MARK: - Circle to Lasso

enum LoopDetector {
    struct Analysis: Equatable {
        var pathLength: Double
        var bounds: Rect
        /// Distance between the stroke's ends.
        var gap: Double
        var netTurning: Double
        var totalTurning: Double
        /// 4πA / L².
        var compactness: Double
    }

    static func analyse(_ raw: [Point]) -> Analysis? {
        // Bound all loop geometry, including debug builds on large captured strokes.
        let points = PenGeometry.deduplicated(PenGeometry.thinned(raw, limit: 1_024))
        guard points.count >= 8, let bounds = Rect.bounding(points) else { return nil }
        let length = Geo.pathLength(points)
        guard length > 0, let first = points.first, let last = points.last else { return nil }
        let side = max(min(bounds.width, bounds.height), 1e-6)
        let turning = PenGeometry.turning(PenGeometry.resampled(points, spacing: side / 12))
        let area = PenGeometry.area(points)
        return Analysis(pathLength: length, bounds: bounds, gap: first.distance(to: last),
                        netTurning: turning.net, totalTurning: turning.total,
                        compactness: 4 * Double.pi * area / (length * length))
    }

    /// True for one roughly closed loop (a circle or an oval, overshoot allowed) big enough to enclose something.
    static func isClosedLoop(_ raw: [Point], scale: Double = 1) -> Bool {
        let points = PenGeometry.thinned(raw, limit: 1_024)
        guard let a = analyse(points) else { return false }
        let k = max(scale, 0.01)
        let closed = a.gap * k <= PenGestureTuning.loopMaxGap || a.gap <= PenGestureTuning.loopMaxGapShare * a.pathLength
            || crossesStart(PenGeometry.resampled(points, spacing: max(min(a.bounds.width, a.bounds.height), 1e-6) / 24))
        let winding = abs(a.netTurning)
        return closed
            && min(a.bounds.width, a.bounds.height) * k >= PenGestureTuning.loopMinSize
            && a.pathLength * k >= PenGestureTuning.loopMinLength
            && winding >= PenGestureTuning.loopMinWinding && winding <= PenGestureTuning.loopMaxWinding
            && a.totalTurning <= winding * 1.6 + Double.pi
            && a.compactness >= PenGestureTuning.loopMinCompactness
    }

    /// Whether `point` is inside the loop or within `tolerance` of its line (the long-press that turns it into a lasso).
    static func hits(_ point: Point, loop: [Point], tolerance: Double) -> Bool {
        guard loop.count >= 3 else { return false }
        return Geo.polygonContains(loop, point) || PenGeometry.distance(point, toPolyline: loop, closed: true) <= tolerance
    }

    /// True when a stroke's size is that of a press, not of writing.
    static func isDot(_ points: [Point], scale: Double = 1) -> Bool {
        guard let b = Rect.bounding(points) else { return true }
        return max(b.width, b.height) * max(scale, 0.01) <= PenGestureTuning.dotMaxExtent
    }

    /// The last third of the stroke crosses its first third.
    static func crossesStart(_ points: [Point]) -> Bool {
        guard points.count >= 8 else { return false }
        let head = Array(points.prefix(max(2, points.count / 3)))
        let tail = Array(points.suffix(max(2, points.count / 3)))
        for i in 1..<tail.count {
            for j in 1..<head.count where Geo.segmentsIntersect(tail[i - 1], tail[i], head[j - 1], head[j]) {
                return true
            }
        }
        return false
    }
}

/// A loop stroke just committed with a caller-chosen id, waiting (up to `lassoWindow`) for the long-press that turns it
/// into a lasso selection. `committed` resolves to whether `ink.addStrokes` wrote it; `group` is the undo group the
/// loop was written in, which `selection.fromLoop` joins so the loop and its removal are one undo step.
struct PendingLoop {
    let id: ElementID
    let page: PageID
    let outline: [Point]
    let finishedAt: TimeInterval
    let group: String
    let committed: Task<Bool, Never>

    func isOpen(at time: TimeInterval) -> Bool {
        time >= finishedAt && time - finishedAt <= PenGestureTuning.lassoWindow
    }

    func accepts(_ point: Point, at time: TimeInterval, scale: Double) -> Bool {
        isOpen(at: time)
            && LoopDetector.hits(point, loop: outline, tolerance: PenGestureTuning.lassoHitTolerance / max(scale, 0.01))
    }
}
