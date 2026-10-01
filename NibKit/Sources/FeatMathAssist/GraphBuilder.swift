import Foundation
import NibContracts
import NibDesign

/// Centre in mathematical coordinates; scale is page points per mathematical unit (both axes).
struct GraphViewport: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 32

    static let scaleRange = 0.000001...1_000_000.0

    func validate() throws {
        for (name, value) in [("x", x), ("y", y)] {
            guard value.isFinite, abs(value) <= 1e12 else {
                throw GraphBuilder.invalid("The graph centre must be finite and within ±10¹².", path: "$." + name)
            }
        }
        guard scale.isFinite, Self.scaleRange.contains(scale) else {
            throw GraphBuilder.invalid("Scale must be between 0.000001 and 1000000 points per unit.", path: "$.scale")
        }
    }
}

struct GraphData: Codable, Equatable {
    var expressions: [String]
    var viewport: GraphViewport

    init(expressions: [String], viewport: GraphViewport) {
        self.expressions = expressions
        self.viewport = viewport
    }
    private enum CodingKeys: String, CodingKey { case expressions, viewport }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .expressions) {
            expressions = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else { expressions = try c.decode([String].self, forKey: .expressions) }
        viewport = try c.decode(GraphViewport.self, forKey: .viewport)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // The descriptor's textPath must resolve to text for search, recognition and accessibility.
        try c.encode(expressions.joined(separator: "\n"), forKey: .expressions)
        try c.encode(viewport, forKey: .viewport)
    }
}

/// Bounded vector generation, with no UIKit state or document writes. Run on MathStack.perform, away from UI work.
enum GraphBuilder {
    static let owner = "nib.mathgraph"
    static let type = "graph"
    static let drawKey = "custom." + owner + "." + type
    static let timeBudget = 2.0
    static var tooSlow: NibError {
        NibError(.unsupported, "This graph takes too long to draw", hint: "Use simpler expressions or a smaller range.")
    }
    static let maxExpressions = 8
    static let maxExpressionLength = 2048
    static let inks: [NibInk] = [.cobalt, .vermilion, .moss, .plum, .lagoon, .ochre, .sienna, .midnight]

    static func invalid(_ message: String, path: String) -> NibError {
        NibError(.invalidParams, message, path: path,
                 hint: "Call math.graph.create with one explicit function per expression, e.g. y = x^2, or math.graph.setViewport with ref, x, y and scale.")
    }

    static func validate(frame: Frame) throws {
        guard [frame.x, frame.y, frame.w, frame.h, frame.rotation].allSatisfy({ $0.isFinite }),
              abs(frame.x) <= 1e12, abs(frame.y) <= 1e12,
              frame.w >= Double(NibMetrics.hitTarget), frame.h >= Double(NibMetrics.hitTarget),
              frame.w <= 4096, frame.h <= 4096 else {
            throw invalid("Use a finite graph frame, 44–4096 points wide and high.", path: "$.rect")
        }
    }

    static func build(expressions: [String], frame: Frame, viewport: GraphViewport, cancellation: MathCancellation? = nil) throws -> DisplayList {
        let deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        try validate(frame: frame)
        try viewport.validate()
        guard !expressions.isEmpty, expressions.count <= maxExpressions else {
            throw invalid("Add between one and eight expressions.", path: "$.expressions")
        }
        guard JSONValue.array(expressions.map(JSONValue.string)).jsonString().utf8.count <= NibLimits.aiToolResultBytes / 2 else {
            throw invalid("The expressions are too large to edit through the query API. Use shorter functions.", path: "$.expressions")
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let engine = MathEngine(context: expressions)
        // One evaluator for the whole build: its work counter survives all samples and all curves.
        let evaluator = MathEvaluator(definitions: engine.definitions, cancellation: cancellation,
                                      nestingLimit: MathEngine.samplerNestingLimit)
        let functions = try expressions.enumerated().map { index, source -> (Double) throws -> Double? in
            if cancellation?.isCancelled == true { throw CancellationError() }
            let path = "$.expressions[\(index)]"
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.utf8.count <= maxExpressionLength, source.rangeOfCharacter(from: .newlines) == nil else {
                throw invalid("Each expression needs 1–2048 bytes of maths.", path: path)
            }
            do {
                _ = try engine.function(source)
                // A typo must not silently ship an empty graph. Domain holes, however, are normal.
                let statement = try MathStack.run { try MathParser.statements(source)[0] }
                let body = statement.rhs ?? statement.lhs
                let names = try MathStack.run { engine.definitions.freeNames(body, symbolic: ["x"]).subtracting(["x"]) }
                guard names.isEmpty else {
                    throw invalid("Undefined names: \(names.sorted().joined(separator: ", ")). Use x as the independent variable.", path: path)
                }
                try MathStack.run { try validateCalls(body, definitions: engine.definitions, bound: ["x"]) }
                if case .matrix = body { throw invalid("A graph needs a scalar function of x, not a matrix.", path: path) }
                return { x in
                    do { return try evaluator.sample(body, variable: "x", at: x) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as NibError where error.code == .unsupported { throw tooSlow }
                    catch { return nil } // Domain holes are normal.
                }
            } catch let error as NibError {
                throw NibError(error.code, error.message, path: path, hint: error.hint)
            }
        }

        let bounds = Rect(x: 0, y: 0, width: frame.w, height: frame.h)
        // Half the widest stroke keeps round caps and joins inside the item, without renderer clipping support.
        let plot = bounds.insetBy(Double(NibStroke.ring) / 2)
        let origin = Point(frame.w / 2 - viewport.x * viewport.scale,
                           frame.h / 2 + viewport.y * viewport.scale)
        let gridColour = colour(NibPaper.white.ruleHex)
        var ops = [DisplayOp(op: .rect, rect: bounds, fill: colour(NibPaper.white.hex))]
        let step = gridStep(scale: viewport.scale)
        let pixelStep = step * viewport.scale
        // Use a pixel phase, avoiding integer conversions or loops proportional to the world's coordinates.
        func positions(_ origin: Double, low: Double, high: Double) -> [Double] {
            let phase = origin.truncatingRemainder(dividingBy: pixelStep)
            let start = low + (phase - low).truncatingRemainder(dividingBy: pixelStep)
            return (0...Int(ceil((high - low) / pixelStep)) + 1).map { start + Double($0) * pixelStep }
                .filter { $0 >= low && $0 <= high }
        }
        for x in positions(origin.x, low: plot.minX, high: plot.maxX) {
            ops.append(DisplayOp(op: .line, points: [Point(x, plot.minY), Point(x, plot.maxY)],
                                 stroke: gridColour, width: Double(NibStroke.hairline)))
        }
        for y in positions(origin.y, low: plot.minY, high: plot.maxY) {
            ops.append(DisplayOp(op: .line, points: [Point(plot.minX, y), Point(plot.maxX, y)],
                                 stroke: gridColour, width: Double(NibStroke.hairline)))
        }
        if origin.x >= plot.minX, origin.x <= plot.maxX {
            ops.append(DisplayOp(op: .line, points: [Point(origin.x, plot.minY), Point(origin.x, plot.maxY)],
                                 stroke: colour(NibInk.graphite.hex), width: Double(NibStroke.thin)))
        }
        if origin.y >= plot.minY, origin.y <= plot.maxY {
            ops.append(DisplayOp(op: .line, points: [Point(plot.minX, origin.y), Point(plot.maxX, origin.y)],
                                 stroke: colour(NibInk.graphite.hex), width: Double(NibStroke.thin)))
        }
        func label(_ value: Double, x: Double, y: Double) {
            let width = min(44.0, plot.width), height = min(14.0, plot.height)
            let rect = Rect(x: min(plot.maxX - width, max(plot.minX, x - width / 2)),
                            y: min(plot.maxY - height, max(plot.minY, y)), width: width, height: height)
            ops.append(DisplayOp(op: .text, rect: rect, fill: colour(NibInk.graphite.hex),
                                 text: String(format: "%.3g", value), fontSize: 10, align: .center))
        }
        for x in positions(origin.x, low: plot.minX, high: plot.maxX) {
            label(viewport.x + (x - frame.w / 2) / viewport.scale, x: x, y: origin.y + 3)
        }
        for y in positions(origin.y, low: plot.minY, high: plot.maxY) {
            label(viewport.y - (y - frame.h / 2) / viewport.scale, x: origin.x - 24, y: y - 7)
        }
        for (index, function) in functions.enumerated() {
            let paths = try sample(function, frame: frame, viewport: viewport, clip: plot, cancellation: cancellation, deadline: deadline)
            if cancellation?.isCancelled == true { throw CancellationError() }
            for path in paths {
                let points = try simplified(path, clip: plot, deadline: deadline, cancellation: cancellation)
                ops.append(DisplayOp(op: .polyline, points: points,
                                     stroke: colour(inks[index].hex), width: Double(NibStroke.ring)))
            }
        }
        return DisplayList(ops: ops)
    }

    private static func validateCalls(_ node: MathNode, definitions: MathDefinitions, bound: Set<String>) throws {
        switch node {
        case .number, .variable: return
        case .negate(let a), .postfix(_, let a): try validateCalls(a, definitions: definitions, bound: bound)
        case .binary(_, let a, let b):
            try validateCalls(a, definitions: definitions, bound: bound)
            try validateCalls(b, definitions: definitions, bound: bound)
        case .function(_, let args):
            for a in args { try validateCalls(a, definitions: definitions, bound: bound) }
        case .call(let name, let args, let primes):
            guard definitions.functions[name] != nil || (bound.contains(name) && primes == 0 && args.count == 1) else {
                throw MathFailure.undefinedFunction(name)
            }
            for a in args { try validateCalls(a, definitions: definitions, bound: bound) }
        case .matrix(let rows):
            for a in rows.flatMap({ $0 }) { try validateCalls(a, definitions: definitions, bound: bound) }
        case .bigOperator(_, let name, let from, let to, let body), .integral(let name, let from, let to, let body):
            try validateCalls(from, definitions: definitions, bound: bound)
            try validateCalls(to, definitions: definitions, bound: bound)
            try validateCalls(body, definitions: definitions, bound: bound.union([name]))
        case .derivative(let name, _, let body, let at):
            if let at { try validateCalls(at, definitions: definitions, bound: bound) }
            try validateCalls(body, definitions: definitions, bound: bound.union([name]))
        }
    }

    static func colour(_ hex: UInt32) -> RGBA {
        RGBA(UInt8((hex >> 16) & 255), UInt8((hex >> 8) & 255), UInt8(hex & 255))
    }

    /// 1/2/5 decades, roughly one grid line per 48 page points at any zoom.
    static func gridStep(scale: Double) -> Double {
        let desired = 48 / scale
        let decade = pow(10, floor(log10(desired)))
        let mantissa = desired / decade
        return (mantissa <= 1 ? 1 : mantissa <= 2 ? 2 : mantissa <= 5 ? 5 : 10) * decade
    }

    private static func sample(_ function: (Double) throws -> Double?, frame: Frame, viewport: GraphViewport,
                               clip: Rect, cancellation: MathCancellation?, deadline: Double) throws -> [[Point]] {
        let count = min(2048, max(128, Int(ceil(frame.w))))
        let allowance = max(8, 16384 / count)
        var evaluations = 0
        var paths: [[Point]] = []
        var path: [Point] = []
        func flush() {
            if path.count >= 2 { paths.append(path) }
            path.removeAll(keepingCapacity: true)
        }
        func point(_ pixelX: Double) throws -> Point? {
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw tooSlow }
            guard evaluations < allowance else { return nil }
            evaluations += 1
            let x = viewport.x + (pixelX - frame.w / 2) / viewport.scale
            let value = try function(x)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw tooSlow }
            guard let y = value, y.isFinite else { return nil }
            let py = frame.h / 2 - (y - viewport.y) * viewport.scale
            guard py.isFinite else { return nil }
            return Point(pixelX, py)
        }
        func append(_ a: Point, _ b: Point) {
            guard let (start, end) = clipped(a, b, to: clip) else { flush(); return }
            if let last = path.last, last.distance(to: start) < 1e-7 {
                path.append(end)
            } else {
                flush()
                path = [start, end]
            }
        }
        // Subdivide where the midpoint disagrees with a straight segment. At the limit split, never connect
        // across an asymptote, undefined midpoint, or unresolved high-frequency oscillation.
        func segment(_ a: Point, _ b: Point, depth: Int) throws {
            guard let mid = try point((a.x + b.x) / 2) else { flush(); return }
            if [a, mid, b].allSatisfy({ $0.y < clip.minY }) || [a, mid, b].allSatisfy({ $0.y > clip.maxY }) {
                flush(); return
            }
            var error = abs(mid.y / 2 - a.y / 4 - b.y / 4) * 2
            if depth == 0 && error <= 0.75 {
                guard let q1 = try point(a.x * 0.75 + b.x * 0.25),
                      let q3 = try point(a.x * 0.25 + b.x * 0.75) else { flush(); return }
                error = max(error, abs(q1.y - (a.y * 0.75 + b.y * 0.25)),
                            abs(q3.y - (a.y * 0.25 + b.y * 0.75)))
            }
            if error > 0.75 {
                if depth < 6 {
                    try segment(a, mid, depth: depth + 1)
                    try segment(mid, b, depth: depth + 1)
                } else { flush() }
            } else { append(a, b) }
        }
        var previous = try point(0)
        for i in 1...count {
            evaluations = 0 // A difficult interval cannot starve later visible intervals.
            let current = try point(Double(i) * frame.w / Double(count))
            if let a = previous, let b = current { try segment(a, b, depth: 0) }
            else { flush() }
            previous = current
        }
        flush()
        return paths
    }

    /// Quantise to hundredths of a point, then retain only visually significant bends.
    private static func simplified(_ points: [Point], clip: Rect, deadline: Double,
                                   cancellation: MathCancellation?) throws -> [Point] {
        let points = points.map {
            Point(min(clip.maxX, max(clip.minX, ($0.x * 100).rounded() / 100)),
                  min(clip.maxY, max(clip.minY, ($0.y * 100).rounded() / 100)))
        }
        guard points.count > 2 else { return points }
        var keep: Set<Int> = [0, points.count - 1]
        var ranges = [(0, points.count - 1)]
        while let (start, end) = ranges.popLast() {
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw tooSlow }
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            var farthest = 0.25, selected: Int?
            for i in (start + 1)..<end {
                let p = points[i]
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                let distance = p.distance(to: Point(a.x + t * dx, a.y + t * dy))
                if distance > farthest { farthest = distance; selected = i }
                else if distance == farthest, let old = selected,
                        abs(i - (start + end) / 2) < abs(old - (start + end) / 2) { selected = i }
            }
            if let selected {
                keep.insert(selected)
                ranges.append((start, selected)); ranges.append((selected, end))
            }
        }
        return keep.sorted().map { points[$0] }
    }

    /// Liang–Barsky clipping. Callers only pass finite points; huge values are rejected before subtraction.
    static func clipped(_ a: Point, _ b: Point, to r: Rect) -> (Point, Point)? {
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx.isFinite, dy.isFinite else { return nil }
        var low = 0.0, high = 1.0
        for (p, q) in [(-dx, a.x - r.minX), (dx, r.maxX - a.x),
                       (-dy, a.y - r.minY), (dy, r.maxY - a.y)] {
            if p == 0 { if q < 0 { return nil }; continue }
            let t = q / p
            if p < 0 { low = max(low, t) } else { high = min(high, t) }
            if low > high { return nil }
        }
        func at(_ t: Double) -> Point {
            // Clamp tiny floating-point overshoots at the frame edges.
            Point(min(r.maxX, max(r.minX, a.x + t * dx)), min(r.maxY, max(r.minY, a.y + t * dy)))
        }
        return (at(low), at(high))
    }
}
