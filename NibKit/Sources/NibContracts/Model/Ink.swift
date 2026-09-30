import Foundation

public enum InkTool: String, Codable, CaseIterable { case pen, pencil, highlighter, tape }
public enum PenStyle: String, Codable, CaseIterable { case fountain, ball, brush }
public enum StrokePattern: String, Codable, CaseIterable { case solid, dashed, dotted }

/// How a stroke looks. Every field is optional in JSON (missing fields take the defaults below).
public struct InkStyle: Codable, Hashable {
    public var tool: InkTool
    /// Pen tool only.
    public var pen: PenStyle?
    public var color: RGBA
    /// Nominal preset width in points.
    public var width: Double
    public var pattern: StrokePattern
    /// 0 = round … 1 = sharp (fountain pen).
    public var tipSharpness: Double
    /// 0 … 1 (fountain, brush).
    public var pressureSensitivity: Double
    /// 0 … 1 (fountain).
    public var tipFlatness: Double
    /// Apple Pencil Pro barrel roll shapes the nib (fountain).
    public var reactsToRoll: Bool
    /// Tape only: tiled pattern image; nil = solid color.
    public var tapePattern: AssetRef?
    /// Tape only: pattern follows stroke direction instead of staying horizontal.
    public var tapeFollowsDirection: Bool

    public init(tool: InkTool = .pen, pen: PenStyle? = .fountain, color: RGBA = .black, width: Double = 1.2,
                pattern: StrokePattern = .solid, tipSharpness: Double = 0.5, pressureSensitivity: Double = 0.5,
                tipFlatness: Double = 0, reactsToRoll: Bool = false, tapePattern: AssetRef? = nil,
                tapeFollowsDirection: Bool = false) {
        self.tool = tool
        self.pen = pen
        self.color = color
        self.width = width
        self.pattern = pattern
        self.tipSharpness = tipSharpness
        self.pressureSensitivity = pressureSensitivity
        self.tipFlatness = tipFlatness
        self.reactsToRoll = reactsToRoll
        self.tapePattern = tapePattern
        self.tapeFollowsDirection = tapeFollowsDirection
    }

    enum CodingKeys: String, CodingKey {
        case tool, pen, color, width, pattern, tipSharpness, pressureSensitivity, tipFlatness, reactsToRoll,
             tapePattern, tapeFollowsDirection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InkStyle()
        tool = try c.decodeIfPresent(InkTool.self, forKey: .tool) ?? d.tool
        pen = try c.decodeIfPresent(PenStyle.self, forKey: .pen) ?? (tool == .pen ? .fountain : nil)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        pattern = try c.decodeIfPresent(StrokePattern.self, forKey: .pattern) ?? d.pattern
        tipSharpness = try c.decodeIfPresent(Double.self, forKey: .tipSharpness) ?? d.tipSharpness
        pressureSensitivity = try c.decodeIfPresent(Double.self, forKey: .pressureSensitivity) ?? d.pressureSensitivity
        tipFlatness = try c.decodeIfPresent(Double.self, forKey: .tipFlatness) ?? d.tipFlatness
        reactsToRoll = try c.decodeIfPresent(Bool.self, forKey: .reactsToRoll) ?? d.reactsToRoll
        tapePattern = try c.decodeIfPresent(AssetRef.self, forKey: .tapePattern)
        tapeFollowsDirection = try c.decodeIfPresent(Bool.self, forKey: .tapeFollowsDirection) ?? d.tapeFollowsDirection
    }

    public static let defaultPen = InkStyle()
    public static let defaultPencil = InkStyle(tool: .pencil, pen: nil, color: RGBA(0x3A, 0x3A, 0x3C), width: 1.6)
    public static let defaultHighlighter = InkStyle(tool: .highlighter, pen: nil, color: .highlighterYellow, width: 12)
    public static let defaultTape = InkStyle(tool: .tape, pen: nil, color: RGBA(0xF4, 0xC4, 0x30), width: 18)
}

/// One captured sample. Page coordinates; `t` seconds since the stroke's `t0`; angles in radians.
/// `width`/`height`/`opacity` are what PencilKit rendered (0 = derive from style with `InkModel.fillSizes`).
public struct StrokePoint: Hashable {
    public var x: Float
    public var y: Float
    public var t: Float
    public var force: Float
    public var azimuth: Float
    public var altitude: Float
    public var roll: Float
    public var width: Float
    public var height: Float
    public var opacity: Float

    public init(x: Float, y: Float, t: Float = 0, force: Float = 0.5, azimuth: Float = 0,
                altitude: Float = 1.5707964, roll: Float = 0, width: Float = 0, height: Float = 0, opacity: Float = 1) {
        self.x = x
        self.y = y
        self.t = t
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.roll = roll
        self.width = width
        self.height = height
        self.opacity = opacity
    }

    public var location: Point { Point(Double(x), Double(y)) }

    /// Field order of the canonical "full" format.
    public static let fullFormat = ["x", "y", "t", "force", "azimuth", "altitude", "roll", "width", "height", "opacity"]
    public static let fullStride = 10

    /// Accepted `fmt` values for the flat `pts` array (plugins/AI usually send "xy").
    public static let formats: [String: [String]] = [
        "xy": ["x", "y"],
        "xyt": ["x", "y", "t"],
        "xytf": ["x", "y", "t", "force"],
        "xytfaa": ["x", "y", "t", "force", "azimuth", "altitude"],
        "xytfaar": ["x", "y", "t", "force", "azimuth", "altitude", "roll"],
        "full": StrokePoint.fullFormat
    ]

    var packed: [Float] { [x, y, t, force, azimuth, altitude, roll, width, height, opacity] }

    /// Linear interpolation of every field (used by `InkModel.densify`).
    public static func lerp(_ a: StrokePoint, _ b: StrokePoint, _ t: Float) -> StrokePoint {
        func m(_ u: Float, _ v: Float) -> Float { u + (v - u) * t }
        return StrokePoint(x: m(a.x, b.x), y: m(a.y, b.y), t: m(a.t, b.t), force: m(a.force, b.force),
                           azimuth: m(a.azimuth, b.azimuth), altitude: m(a.altitude, b.altitude), roll: m(a.roll, b.roll),
                           width: m(a.width, b.width), height: m(a.height, b.height), opacity: m(a.opacity, b.opacity))
    }

    mutating func set(_ field: String, _ v: Float) {
        switch field {
        case "x": x = v
        case "y": y = v
        case "t": t = v
        case "force": force = v
        case "azimuth": azimuth = v
        case "altitude": altitude = v
        case "roll": roll = v
        case "width": width = v
        case "height": height = v
        case "opacity": opacity = v
        default: break
        }
    }
}

/// A freehand stroke (pen, pencil, highlighter or tape) with the transform baked into its points.
public struct Stroke: Equatable {
    public var style: InkStyle
    public var points: [StrokePoint]
    /// Unix seconds of the first sample (links ink to audio for Note Replay).
    public var t0: Double
    /// Tape only: false = opaque (content hidden), true = revealed.
    public var tapeRevealed: Bool

    public init(style: InkStyle, points: [StrokePoint], t0: Double = Date().timeIntervalSince1970, tapeRevealed: Bool = false) {
        self.style = style
        self.points = points
        self.t0 = t0
        self.tapeRevealed = tapeRevealed
    }

    public var polyline: [Point] { points.map { $0.location } }

    /// Bounds including half the nib width.
    public var bounds: Rect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        var maxW: Float = 0
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
            maxW = max(maxW, max(p.width, p.height))
        }
        let pad = Double(max(maxW, Float(style.width))) / 2 + 1
        return Rect(x: Double(minX) - pad, y: Double(minY) - pad,
                    width: Double(maxX - minX) + 2 * pad, height: Double(maxY - minY) + 2 * pad)
    }

    public func transformed(by t: Affine) -> Stroke {
        var s = self
        let k = Float(sqrt(abs(t.determinant)))
        for i in s.points.indices {
            let p = t.apply(s.points[i].location)
            s.points[i].x = Float(p.x)
            s.points[i].y = Float(p.y)
            s.points[i].width *= k
            s.points[i].height *= k
        }
        s.style.width *= Double(k)
        return s
    }
}

public extension CodingUserInfoKey {
    /// Set to `true` in an encoder's `userInfo` to write stroke points as base64 little-endian Float32
    /// (`ptsB64`, used inside document packages). Otherwise points are written as a flat number array (`pts`).
    static let nibCompactPoints = CodingUserInfoKey(rawValue: "nib.compactPoints")!
}

extension Stroke: Codable {
    enum CodingKeys: String, CodingKey { case style, pts, ptsB64, fmt, t0, tapeRevealed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(InkStyle.self, forKey: .style) ?? InkStyle()
        t0 = try c.decodeIfPresent(Double.self, forKey: .t0) ?? Date().timeIntervalSince1970
        tapeRevealed = try c.decodeIfPresent(Bool.self, forKey: .tapeRevealed) ?? false
        if let b64 = try c.decodeIfPresent(String.self, forKey: .ptsB64) {
            guard let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(forKey: .ptsB64, in: c, debugDescription: "invalid base64 points")
            }
            points = Stroke.unpackCompact(data)
        } else {
            let fmt = try c.decodeIfPresent(String.self, forKey: .fmt) ?? "xy"
            guard let fields = StrokePoint.formats[fmt] else {
                throw DecodingError.dataCorruptedError(forKey: .fmt, in: c,
                    debugDescription: "unknown point format '\(fmt)'; use one of \(StrokePoint.formats.keys.sorted())")
            }
            let raw = try c.decodeIfPresent([Double].self, forKey: .pts) ?? []
            points = Stroke.unpack(raw.map { Float($0) }, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(t0, forKey: .t0)
        if tapeRevealed { try c.encode(true, forKey: .tapeRevealed) }
        var flat: [Float] = []
        flat.reserveCapacity(points.count * StrokePoint.fullStride)
        for p in points { flat.append(contentsOf: p.packed) }
        if encoder.userInfo[.nibCompactPoints] as? Bool == true {
            let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            try c.encode(data.base64EncodedString(), forKey: .ptsB64)
        } else {
            try c.encode("full", forKey: .fmt)
            try c.encode(flat.map { (Double($0) * 1000).rounded() / 1000 }, forKey: .pts)
        }
    }

    /// contracts-v2: points from the compact package form (`ptsB64`: little-endian Float32 in `StrokePoint.fullFormat`
    /// order), without JSON: page readers decode strokes straight from the file bytes.
    public static func unpackCompact(_ data: Data) -> [StrokePoint] {
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return unpackFull(floats)
    }

    /// contracts-v2: points from a flat array in exactly the encoder's `StrokePoint.fullFormat` order (the fast path
    /// of every "full" and compact decode: no per-field name lookups).
    public static func unpackFull(_ v: [Float]) -> [StrokePoint] {
        let s = StrokePoint.fullStride
        let n = v.count / s
        var out: [StrokePoint] = []
        out.reserveCapacity(n)
        v.withUnsafeBufferPointer { b in
            for k in 0..<n {
                let i = k * s
                out.append(StrokePoint(x: b[i], y: b[i + 1], t: b[i + 2], force: b[i + 3], azimuth: b[i + 4],
                                       altitude: b[i + 5], roll: b[i + 6], width: b[i + 7], height: b[i + 8],
                                       opacity: b[i + 9]))
            }
        }
        return out
    }

    static func unpack(_ v: [Float], fields: [String]) -> [StrokePoint] {
        let stride = fields.count
        guard stride > 0 else { return [] }
        if fields == StrokePoint.fullFormat { return unpackFull(v) }
        var out: [StrokePoint] = []
        out.reserveCapacity(v.count / stride)
        var i = 0
        var n = 0
        while i + stride <= v.count {
            var p = StrokePoint(x: 0, y: 0, t: Float(n) * 0.008)
            for (k, f) in fields.enumerated() { p.set(f, v[i + k]) }
            out.append(p)
            i += stride
            n += 1
        }
        return out
    }
}

public enum InkModel {
    /// Fills zero `width`/`height` (and zero opacity) from the style — for points created by AI, plugins,
    /// ink synthesis or SVG import that carry no rendered nib size.
    public static func fillSizes(_ points: inout [StrokePoint], style: InkStyle) {
        let w = Float(style.width)
        for i in points.indices where points[i].width <= 0 || points[i].height <= 0 {
            var f: Float = 1
            switch style.tool {
            case .pen:
                if style.pen != .ball {
                    f = 1 + (points[i].force - 0.5) * Float(style.pressureSensitivity) * 1.2
                }
            case .pencil:
                f = 0.8 + points[i].force * 0.4
            case .highlighter, .tape:
                f = 1
            }
            let size = max(0.1, w * f)
            points[i].width = size
            points[i].height = size
            if points[i].opacity <= 0 { points[i].opacity = 1 }
        }
    }

    /// Resamples so consecutive points are at most `maxSpacing` points apart (every field interpolated) and
    /// repeats each end point so it appears 3 times. PencilKit treats stroke points as control points of a
    /// uniform cubic B-spline; sparse AI/plugin polylines would otherwise render with rounded, pulled-in corners
    /// that no longer match the polyline used by the eraser, lasso, hit testing and recognition.
    public static func densify(_ points: [StrokePoint], maxSpacing: Float = 1.5) -> [StrokePoint] {
        guard points.count >= 2, let first = points.first, let last = points.last else { return points }
        let spacing = max(maxSpacing, 0.1)
        var out: [StrokePoint] = [first, first]
        out.reserveCapacity(points.count * 4)
        for i in points.indices {
            let p = points[i]
            if i > 0 {
                let a = points[i - 1]
                let d = ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
                let n = max(1, Int((d / spacing).rounded(.up)))
                for k in 1..<n { out.append(StrokePoint.lerp(a, p, Float(k) / Float(n))) }
            }
            out.append(p)
        }
        out.append(last)
        out.append(last)
        return out
    }

    /// Normalises a stroke that did not come from PencilKit (AI, plugins, ink synthesis, SVG import, patched
    /// points): when EVERY point has zero width it is densified and its nib sizes are derived from the style.
    /// Captured PencilKit strokes (non-zero widths) are untouched. `ink.addStrokes`, `ink.setPoints`,
    /// `item.update`/`node.set` of stroke points and `PKBridge.pkStroke` all call this before storing/drawing.
    public static func prepare(_ stroke: inout Stroke) {
        guard !stroke.points.isEmpty, stroke.points.allSatisfy({ $0.width <= 0 }) else { return }
        stroke.points = densify(stroke.points)
        fillSizes(&stroke.points, style: stroke.style)
    }
}
