import Foundation
import NibContracts

/// Pure stroke geometry for the highlighter: Draw in Straight Line (best-fit line) and Stroke Stabilization (EMA).
enum HighlighterGeometry {
    /// Replaces a stroke's points with a 2-point line: the total-least-squares line through the centroid (the one
    /// that minimises perpendicular distances, so a wobbly pass over a line of text lands on that line), spanning the
    /// extent of the stroke along it and oriented from where the stroke started. Every other field of the two points
    /// comes from the original first / last sample.
    ///
    /// The nib sizes are zeroed on purpose: PencilKit treats stroke points as B-spline control points, so a bare
    /// 2-point path would render pulled in. `ink.addStrokes` (and `PKBridge.pkStroke`) run `InkModel.prepare`, which
    /// densifies an all-zero-width stroke with clamped ends and derives the nib size from the unchanged style width.
    static func straightened(_ points: [StrokePoint]) -> [StrokePoint] {
        guard points.count >= 2, let first = points.first, let last = points.last else { return points }
        let n = Double(points.count)
        var cx = 0.0, cy = 0.0
        for p in points {
            cx += Double(p.x)
            cy += Double(p.y)
        }
        cx /= n
        cy /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = Double(p.x) - cx, dy = Double(p.y) - cy
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        // Principal axis of the point cloud; a single repeated point has no axis (any direction gives a dot).
        let theta = (sxx + syy) > 1e-12 ? 0.5 * atan2(2 * sxy, sxx - syy) : 0
        let ux = cos(theta), uy = sin(theta)
        func along(_ p: StrokePoint) -> Double { (Double(p.x) - cx) * ux + (Double(p.y) - cy) * uy }
        var lo = Double.infinity, hi = -Double.infinity
        for p in points {
            let t = along(p)
            lo = min(lo, t)
            hi = max(hi, t)
        }
        // Start at the extreme nearer the first sample, so the line keeps the direction it was drawn in.
        let startsLow = abs(along(first) - lo) <= abs(along(first) - hi)
        let tStart = startsLow ? lo : hi
        let tEnd = startsLow ? hi : lo
        func placed(_ source: StrokePoint, at t: Double) -> StrokePoint {
            var q = source
            q.x = Float(cx + t * ux)
            q.y = Float(cy + t * uy)
            q.width = 0
            q.height = 0
            return q
        }
        return [placed(first, at: tStart), placed(last, at: tEnd)]
    }

    /// Stroke Stabilization: an exponential moving average of the positions (the pen's rule: the weight of each new
    /// sample is `1 - 0.85 * amount`), run forwards and backwards and averaged so the smoothed line does not lag
    /// behind the pen. Only x/y change; both end points are kept exactly. `amount` 0 = off ... 1 = strongest.
    static func stabilized(_ points: [StrokePoint], amount: Double) -> [StrokePoint] {
        let a = min(max(amount, 0), 1)
        guard a > 0, points.count > 2 else { return points }
        let w = Float(1 - 0.85 * a)
        var forward = points, backward = points
        for i in 1..<points.count {
            forward[i].x = forward[i - 1].x + w * (points[i].x - forward[i - 1].x)
            forward[i].y = forward[i - 1].y + w * (points[i].y - forward[i - 1].y)
        }
        for i in stride(from: points.count - 2, through: 0, by: -1) {
            backward[i].x = backward[i + 1].x + w * (points[i].x - backward[i + 1].x)
            backward[i].y = backward[i + 1].y + w * (points[i].y - backward[i + 1].y)
        }
        var out = points
        for i in 1..<(points.count - 1) {
            out[i].x = (forward[i].x + backward[i].x) / 2
            out[i].y = (forward[i].y + backward[i].y) / 2
        }
        return out
    }
}

/// StrokeProcessor "highlighter.straight": when Draw in Straight Line is on, a finished highlighter stroke becomes a
/// best-fit 2-point line with the same style (width, colour).
@MainActor
final class StraightLineProcessor: StrokeProcessor {
    static let id = "highlighter.straight"
    /// After stabilisation (10), before ruler projection (50): ARCHITECTURE §8.2.
    static let order = 20

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        guard stroke.style.tool == .highlighter, settings.get(HighlighterSettings.straightLine) else { return true }
        stroke.points = HighlighterGeometry.straightened(stroke.points)
        return true
    }
}

/// StrokeProcessor "highlighter.stabilize": smooths highlighter strokes by `highlighter.stabilization`.
@MainActor
final class HighlighterStabilizer: StrokeProcessor {
    static let id = "highlighter.stabilize"
    static let order = 10

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        guard stroke.style.tool == .highlighter else { return true }
        stroke.points = HighlighterGeometry.stabilized(stroke.points, amount: settings.get(HighlighterSettings.stabilization))
        return true
    }
}
