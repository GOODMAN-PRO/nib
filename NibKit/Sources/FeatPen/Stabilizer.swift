import Foundation
import NibContracts

// MARK: - Stroke Stabilization (T-007)

/// Pure stroke smoothing shared by the pen and the pencil. It is the highlighter's rule (F009), so every writing tool
/// smooths the same way: an exponential moving average of the positions whose sample weight is `1 − 0.85 × amount`,
/// run forwards and backwards and averaged so the smoothed line does not lag behind the pen. Only x and y change, and
/// both end points are kept exactly (a stroke still starts and ends where the nib touched the page).
enum StrokeStabilizer {
    /// `amount` 0 (off) … 1 (strongest). Returns `points` unchanged when off or when there is nothing between the ends.
    static func stabilized(_ points: [StrokePoint], amount: Double) -> [StrokePoint] {
        let a = amount.isFinite ? min(max(amount, 0), 1) : 0
        guard a > 0, points.count > 2 else { return points }
        let w = Float(1 - 0.85 * a)
        var forward = points
        var backward = points
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

/// StrokeProcessor "pen.stabilize": smooths every finished pen and pencil stroke by `pen.stabilization`. It runs first
/// (order 10, beside the highlighter's own stabiliser, before straightening and ruler projection: ARCHITECTURE §8.2).
@MainActor
final class PenStabilizer: StrokeProcessor {
    static let id = "pen.stabilize"
    static let order = 10

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        guard stroke.style.tool == .pen || stroke.style.tool == .pencil else { return true }
        let amount = settings.get(PenSettings.stabilization)
        guard amount > 0 else { return true }
        stroke.points = StrokeStabilizer.stabilized(stroke.points, amount: amount)
        return true
    }
}

// MARK: - Nib dynamics (T-005, T-006, T-089, T-090)

/// Shapes the nib sizes PencilKit captured by the pen's own settings, which PencilKit's inks cannot express:
/// Pressure Sensitivity (how much the width follows the pressure), Tip Sharpness (tapered or blunt stroke ends), Tip
/// Flatness (a chisel nib) and React to Pen Rotation (whether the stroke keeps the Apple Pencil Pro barrel roll).
/// Every setting is neutral at its default (pressure 0.5, sharpness 0.5, flatness 0, roll on), so with default settings
/// the dry stroke is exactly what PencilKit drew. The values come from the stroke's own style (captured when it was
/// drawn), never from global state, so replaying a stroke gives the same result. Strokes without captured sizes (every
/// width 0: AI, plugins, the dashed pens' sample input) are left alone: `InkModel.fillSizes` derives theirs.
enum PenDynamics {
    /// How far the width may swing around its mean at full pressure sensitivity (twice PencilKit's own contrast).
    static let maxPressureGain = 2.0
    /// The thinnest a tapered end gets, as a fraction of the width there.
    static let taperFloor: Float = 0.2
    /// How much a fully flat tip narrows the nib's minor axis.
    static let flatteningAtFull: Float = 0.7

    /// True when `style` changes nothing (the defaults): the processor then skips the stroke.
    static func isNeutral(_ style: InkStyle) -> Bool {
        abs(style.pressureSensitivity - 0.5) < 0.005 && abs(style.tipSharpness - 0.5) < 0.005
            && style.tipFlatness < 0.005 && style.reactsToRoll
    }

    static func apply(_ points: inout [StrokePoint], style: InkStyle, captured: Bool = true) {
        guard !points.isEmpty, points.contains(where: { $0.width > 0 }) else { return }
        if !style.reactsToRoll {
            for i in points.indices { points[i].roll = 0 }
        }
        let tool = style.tool
        let pen = style.pen ?? .fountain
        guard tool == .pen || tool == .pencil, !(tool == .pen && pen == .ball) else { return }
        if captured || tool == .pencil {
            applyPressure(&points, sensitivity: style.pressureSensitivity, opacityToo: tool == .pencil)
        }
        if tool == .pen {
            applySharpness(&points, sharpness: style.tipSharpness, nominalWidth: style.width)
            if pen == .fountain { applyFlatness(&points, flatness: style.tipFlatness) }
        }
    }

    /// Pressure 0.5 keeps PencilKit's contrast; 0 makes the width uniform (the mean); 1 doubles the swing.
    static func applyPressure(_ points: inout [StrokePoint], sensitivity: Double, opacityToo: Bool) {
        let s = sensitivity.isFinite ? min(max(sensitivity, 0), 1) : 0.5
        let gain = Float(min(s / 0.5, maxPressureGain))
        guard abs(gain - 1) > 0.001 else { return }
        let n = Float(points.count)
        let meanW = points.reduce(Float(0)) { $0 + $1.width } / n
        let meanH = points.reduce(Float(0)) { $0 + $1.height } / n
        let meanO = points.reduce(Float(0)) { $0 + $1.opacity } / n
        for i in points.indices {
            points[i].width = clampSize(meanW + (points[i].width - meanW) * gain, mean: meanW)
            points[i].height = clampSize(meanH + (points[i].height - meanH) * gain, mean: meanH)
            if opacityToo {
                points[i].opacity = min(max(meanO + (points[i].opacity - meanO) * gain, 0.05), 1)
            }
        }
    }

    /// Sharpness above 0.5 tapers both ends to a point (1 = the strongest taper); below 0.5 it rounds them off by
    /// filling the thin ends up to the stroke's typical width (0 = fully blunt).
    static func applySharpness(_ points: inout [StrokePoint], sharpness: Double, nominalWidth: Double) {
        let s = sharpness.isFinite ? min(max(sharpness, 0), 1) : 0.5
        guard abs(s - 0.5) > 0.005, points.count >= 3 else { return }
        let strength = Float(abs(s - 0.5) * 2)
        let fromStart = arcLengths(points)
        let total = fromStart.last ?? 0
        guard total > 0 else { return }
        let reach = Float(max(4, min(nominalWidth * 4, Double(total) / 3)))
        if s > 0.5 {
            for i in points.indices {
                let d = min(fromStart[i], total - fromStart[i])
                guard d < reach else { continue }
                let closeness = 1 - d / reach
                let factor = 1 - strength * (1 - taperFloor) * closeness * closeness
                points[i].width = max(0.1, points[i].width * factor)
                points[i].height = max(0.1, points[i].height * factor)
            }
        } else {
            let middle = points.indices.filter { i in min(fromStart[i], total - fromStart[i]) >= reach }
            let pool = middle.isEmpty ? Array(points.indices) : middle
            let typicalW = median(pool.map { points[$0].width })
            let typicalH = median(pool.map { points[$0].height })
            for i in points.indices {
                let d = min(fromStart[i], total - fromStart[i])
                guard d < reach else { continue }
                let k = strength * (1 - d / reach)
                points[i].width += max(typicalW - points[i].width, 0) * k
                points[i].height += max(typicalH - points[i].height, 0) * k
            }
        }
    }

    /// Narrows the nib's minor axis (the smaller of width and height) so a fountain pen writes like a chisel nib.
    static func applyFlatness(_ points: inout [StrokePoint], flatness: Double) {
        let f = flatness.isFinite ? min(max(flatness, 0), 1) : 0
        guard f > 0.005 else { return }
        let k = 1 - Float(f) * flatteningAtFull
        for i in points.indices {
            if points[i].height <= points[i].width {
                points[i].height = max(0.1, points[i].height * k)
            } else {
                points[i].width = max(0.1, points[i].width * k)
            }
        }
    }

    static func arcLengths(_ points: [StrokePoint]) -> [Float] {
        var out = [Float](repeating: 0, count: points.count)
        guard points.count > 1 else { return out }
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            out[i] = out[i - 1] + (dx * dx + dy * dy).squareRoot()
        }
        return out
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func clampSize(_ v: Float, mean: Float) -> Float {
        guard mean > 0 else { return max(v, 0) }
        return min(max(v, max(0.1, mean * 0.15)), mean * 4)
    }
}

/// StrokeProcessor "pen.dynamics": applies `PenDynamics` to finished pen and pencil strokes whose style is not neutral.
/// Runs after stabilisation (positions settle first) and before straightening and ruler projection.
@MainActor
final class PenDynamicsProcessor: StrokeProcessor {
    static let id = "pen.dynamics"
    static let order = 12

    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
        guard stroke.style.tool == .pen || stroke.style.tool == .pencil, !PenDynamics.isNeutral(stroke.style) else {
            return true
        }
        let captured = stroke.points.contains { $0.width > 0 }
        InkModel.prepare(&stroke)
        PenDynamics.apply(&stroke.points, style: stroke.style, captured: captured)
        return true
    }
}
