import Foundation
import NibContracts

/// The ink commands this feature owns (ARCHITECTURE §6.5 `ink.*`): `ink.addStrokes`, `ink.setStyle` and `ink.setPoints`.
/// `ink.addStrokes` is the one path every stroke takes into a document: the canvas commits captured ink with it (after
/// the stroke processors), and the AI, plugins, ink synthesis and the bridge write synthesised strokes with it. The two
/// point-carrying commands are JSON-level handlers: a captured stroke carries thousands of numbers, and reading them
/// straight from the `JSONValue` keeps the stroke finalize under its 2 ms budget (§20).
@MainActor
enum InkCommands {
    static func register(_ app: NibApp) {
        app.commands.register(InkAddStrokes.descriptor) { json, ctx in try await InkAddStrokes.handle(json, ctx) }
        app.commands.register(InkSetStyle.self)
        app.commands.register(InkSetPoints.descriptor) { json, ctx in try await InkSetPoints.handle(json, ctx) }
    }
}

/// Bounds that keep one call from exhausting memory (the AI and plugins are untrusted callers).
enum InkLimits {
    /// Strokes in one `ink.addStrokes` call.
    static let maxStrokes = 5_000
    /// Points one stroke may carry as sent.
    static let maxPointsPerStroke = 200_000
    /// Points a stroke may have once densified (a few metres of ink at 1.5 pt spacing).
    static let maxPreparedPoints = 400_000
    static let maxBatchPoints = 1_000_000
    /// Largest coordinate magnitude accepted (page points; boards are large but finite).
    static let maxCoordinate = 10_000_000.0
    /// Widest nominal nib, in points.
    static let maxWidth = 500.0
    /// Spacing `InkModel.densify` resamples to.
    static let densifySpacing = 1.5
}

// MARK: - Parsing and validation

/// Reading ink parameters with precise error paths, so a model can correct exactly the field that was wrong.
@MainActor
enum InkParse {
    static func describeHint(_ command: String) -> String {
        "call commands.describe {\"id\": \"\(command)\"} for the schema and examples"
    }

    /// An item ref "item:D/P/I".
    static func item(_ value: JSONValue?, path: String) throws -> (DocumentID, PageID, ElementID) {
        guard let s = value?.stringValue, case let .item(doc, page, id)? = NodeRef(s) else {
            throw NibError(.invalidParams, "expected a stroke item ref such as item:D/P/I", path: path,
                           hint: "query.find lists the strokes of a page with their refs")
        }
        return (doc, page, id)
    }

    /// The page to write on: a "page:D/P" ref, or (user callers only in practice) the window's current page.
    static func page(_ value: JSONValue?, _ ctx: CommandContext) throws -> (DocumentID, PageID) {
        if let v = value, v != .null, v.stringValue == nil {
            throw NibError(.invalidParams, "'page' must be a page ref like page:D/P", path: "$.page")
        }
        return try ctx.pageOrSession(value?.stringValue)
    }

    /// Refuses documents that must not be written (saved by a newer Nib, or read-only in persistence).
    static func checkWritable(_ doc: DocumentID, _ ctx: CommandContext) throws {
        guard ctx.isReadOnly(doc) else { return }
        throw NibError(.permissionDenied, "document \(doc.raw) is read-only",
                       hint: "it was saved by a newer version of Nib or cannot be written on this device")
    }

    /// The layer new ink goes on: the invoking window's active layer when it shows this document, else layer 0.
    static func activeLayer(_ ctx: CommandContext, doc: DocumentID) -> Int {
        guard let s = ctx.activeSession, s.document == nil || s.document == doc else { return 0 }
        return min(max(s.activeLayer, 0), NibLimits.layerCount - 1)
    }

    /// One Stroke JSON object: `{style?, fmt?, pts | ptsB64, t0?, tapeRevealed?}`.
    static func stroke(_ json: JSONValue, path: String) throws -> Stroke {
        guard json.objectValue != nil else {
            throw NibError(.invalidParams, "expected a Stroke object {style, fmt, pts}", path: path,
                           hint: describeHint("ink.addStrokes"))
        }
        let style = try self.style(json["style"], path: path + ".style")
        let points = try self.points(fmt: json["fmt"], pts: json["pts"], compact: json["ptsB64"], path: path)
        var t0 = Date().timeIntervalSince1970
        if let v = json["t0"], v != .null {
            guard let t = v.doubleValue, t.isFinite else {
                throw NibError.invalid("t0 must be a number of seconds", path: path + ".t0")
            }
            t0 = t
        }
        let revealed = json["tapeRevealed"]?.boolValue ?? false
        return Stroke(style: style, points: points, t0: t0, tapeRevealed: revealed)
    }

    /// `InkStyle` JSON (every field optional), checked and normalised: the pen type exists only on the pen.
    static func style(_ json: JSONValue?, path: String) throws -> InkStyle {
        guard let json = json, json != .null else { return InkStyle() }
        guard json.objectValue != nil else {
            throw NibError(.invalidParams, "style must be an object such as {\"tool\": \"pen\", \"color\": \"#121212\"}",
                           path: path)
        }
        var style: InkStyle
        do {
            style = try json.decode(InkStyle.self)
        } catch {
            throw NibError(.invalidParams, "invalid style: \(Self.reason(error))", path: path,
                           hint: "tool: pen|pencil|highlighter|tape, pen: fountain|ball|brush, color: #RRGGBB[AA], width: points")
        }
        guard style.width.isFinite, style.width > 0, style.width <= InkLimits.maxWidth else {
            throw NibError.invalid("width must be a number of points above 0 and at most \(Int(InkLimits.maxWidth))",
                                   path: path + ".width")
        }
        for (name, value) in [("tipSharpness", style.tipSharpness), ("pressureSensitivity", style.pressureSensitivity),
                              ("tipFlatness", style.tipFlatness)] {
            guard value.isFinite, (0...1).contains(value) else {
                throw NibError.invalid("\(name) must be between 0 and 1", path: path + "." + name)
            }
        }
        style.pen = style.tool == .pen ? (style.pen ?? .fountain) : nil
        return style
    }

    /// Points from the flat `pts` array in `fmt` order, or from the compact `ptsB64` form.
    static func points(fmt: JSONValue?, pts: JSONValue?, compact: JSONValue?, path: String) throws -> [StrokePoint] {
        if let c = compact, c != .null {
            guard let s = c.stringValue, let data = Data(base64Encoded: s),
                  data.count % (StrokePoint.fullStride * MemoryLayout<Float>.size) == 0 else {
                throw NibError.invalid("ptsB64 must be base64 of little-endian Float32 values, 10 per point",
                                       path: path + ".ptsB64")
            }
            let points = Stroke.unpackCompact(data)
            guard !points.isEmpty else { throw NibError.invalid("a stroke needs at least one point", path: path + ".ptsB64") }
            guard points.count <= InkLimits.maxPointsPerStroke else {
                throw NibError.invalid("a stroke may carry at most \(InkLimits.maxPointsPerStroke) points; split it",
                                       path: path + ".ptsB64")
            }
            try check(points, path: path + ".ptsB64")
            return points.map(sanitised)
        }
        var name = "xy"
        if let f = fmt, f != .null {
            guard let s = f.stringValue else { throw NibError.invalid("fmt must be a string", path: path + ".fmt") }
            name = s
        }
        guard let fields = StrokePoint.formats[name] else {
            throw NibError(.invalidParams, "unknown point format '\(name)'", path: path + ".fmt",
                           hint: "use one of " + InkSchemas.formatNames.joined(separator: ", "))
        }
        guard let values = pts?.arrayValue else {
            throw NibError(.invalidParams, "pts must be a flat array of numbers (\(fields.joined(separator: ", ")) per point)",
                           path: path + ".pts", hint: describeHint("ink.addStrokes"))
        }
        let stride = fields.count
        guard !values.isEmpty else { throw NibError.invalid("a stroke needs at least one point", path: path + ".pts") }
        guard values.count % stride == 0 else {
            throw NibError.invalid("pts has \(values.count) numbers, not a multiple of the \(stride) fields of fmt '\(name)'",
                                   path: path + ".pts")
        }
        guard values.count / stride <= InkLimits.maxPointsPerStroke else {
            throw NibError.invalid("a stroke may carry at most \(InkLimits.maxPointsPerStroke) points; split it",
                                   path: path + ".pts")
        }
        var floats = [Float](repeating: 0, count: values.count)
        for (k, v) in values.enumerated() {
            guard let d = v.doubleValue, d.isFinite, abs(d) <= InkLimits.maxCoordinate else {
                throw NibError.invalid("expected a finite number", path: "\(path).pts[\(k)]")
            }
            floats[k] = Float(d)
        }
        let points: [StrokePoint]
        if fields == StrokePoint.fullFormat {
            points = Stroke.unpackFull(floats)
        } else {
            var out: [StrokePoint] = []
            out.reserveCapacity(values.count / stride)
            for n in 0..<(values.count / stride) {
                // Formats without time space the samples like a 125 Hz Pencil (what `Stroke`'s own decoder does).
                var p = StrokePoint(x: 0, y: 0, t: Float(n) * 0.008)
                for (k, field) in fields.enumerated() { assign(&p, field, floats[n * stride + k]) }
                out.append(p)
            }
            points = out
        }
        try check(points, path: path + ".pts")
        return points.map(sanitised)
    }

    static func assign(_ p: inout StrokePoint, _ field: String, _ v: Float) {
        switch field {
        case "x": p.x = v
        case "y": p.y = v
        case "t": p.t = v
        case "force": p.force = v
        case "azimuth": p.azimuth = v
        case "altitude": p.altitude = v
        case "roll": p.roll = v
        case "width": p.width = v
        case "height": p.height = v
        case "opacity": p.opacity = v
        default: break
        }
    }

    /// Negative sizes and out-of-range opacity or force become the nearest valid value.
    static func sanitised(_ p: StrokePoint) -> StrokePoint {
        var q = p
        q.width = max(q.width, 0)
        q.height = max(q.height, 0)
        q.opacity = min(max(q.opacity, 0), 1)
        q.force = max(q.force, 0)
        return q
    }

    static func check(_ points: [StrokePoint], path: String) throws {
        for (i, p) in points.enumerated() {
            let values = [p.x, p.y, p.t, p.force, p.azimuth, p.altitude, p.roll, p.width, p.height, p.opacity]
            guard values.allSatisfy({ $0.isFinite }), abs(Double(p.x)) <= InkLimits.maxCoordinate,
                  abs(Double(p.y)) <= InkLimits.maxCoordinate else {
                throw NibError.invalid("point \(i) is not finite or lies too far away", path: path)
            }
        }
    }

    /// How many points `InkModel.prepare` would make of a stroke (it densifies only strokes with no captured sizes).
    static func preparedCount(_ points: [StrokePoint]) -> Int {
        guard points.count >= 2, points.allSatisfy({ $0.width <= 0 }) else { return points.count }
        var n = 5
        for i in 1..<points.count {
            let dx = Double(points[i].x - points[i - 1].x), dy = Double(points[i].y - points[i - 1].y)
            n += max(1, Int(((dx * dx + dy * dy).squareRoot() / InkLimits.densifySpacing).rounded(.up)))
            if n > InkLimits.maxPreparedPoints { return n }
        }
        return n
    }

    static func checkPreparable(_ points: [StrokePoint], path: String) throws {
        guard preparedCount(points) <= InkLimits.maxPreparedPoints else {
            throw NibError(.invalidParams, "the stroke is too long to densify at 1.5 pt spacing", path: path,
                           hint: "split it into several strokes, or send captured nib sizes (fmt full)")
        }
    }

    /// AI/plugin points derive their nib once; captured points have already passed the canvas dynamics processor.
    static func prepare(_ stroke: inout Stroke) {
        let synthesized = !stroke.points.isEmpty && stroke.points.allSatisfy { $0.width <= 0 }
        InkModel.prepare(&stroke)
        if synthesized { PenDynamics.apply(&stroke.points, style: stroke.style, captured: false) }
    }

    /// Caller-chosen ids in stroke order (fewer ids than strokes: the rest get fresh ids).
    static func ids(_ value: JSONValue?, count: Int) throws -> [NibID?] {
        guard let value = value, value != .null else { return Array(repeating: nil, count: count) }
        guard let list = value.arrayValue else {
            throw NibError.invalid("ids must be an array of id strings", path: "$.ids")
        }
        guard list.count <= count else {
            throw NibError.invalid("ids has \(list.count) entries for \(count) strokes", path: "$.ids")
        }
        var seen = Set<String>()
        var out: [NibID?] = []
        for (i, v) in list.enumerated() {
            guard let s = v.stringValue, NibID.isValid(s) else {
                throw NibError.invalid("an id is 1–64 characters of [A-Za-z0-9_-]", path: "$.ids[\(i)]")
            }
            guard seen.insert(s).inserted else { throw NibError.invalid("id \(s) is given twice", path: "$.ids[\(i)]") }
            out.append(NibID(s))
        }
        return out + Array(repeating: nil, count: count - list.count)
    }

    static func reason(_ error: Error) -> String {
        if let e = error as? NibError { return e.message }
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted(let c): return c.debugDescription
            case .typeMismatch(_, let c), .valueNotFound(_, let c):
                return "wrong type at " + c.codingPath.map { $0.stringValue }.joined(separator: ".")
            case .keyNotFound(let k, _): return "missing '\(k.stringValue)'"
            @unknown default: return "unreadable value"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Schemas shared by the descriptors

enum InkSchemas {
    /// Accepted `fmt` values, sorted (xy, xyt, xytf, xytfaa, xytfaar, full).
    static let formatNames = StrokePoint.formats.keys.sorted()

    static let style: JSONSchema = .obj([
        "tool": .str("pen | pencil | highlighter | tape (default pen)", choices: InkTool.allCases.map { $0.rawValue }),
        "pen": .str("pen type, pen tool only (default fountain)", choices: PenStyle.allCases.map { $0.rawValue }),
        "color": .color,
        "width": .num("nominal nib width in page points (default 1.2)", min: 0.05, max: InkLimits.maxWidth),
        "pattern": .str("line pattern (default solid)", choices: StrokePattern.allCases.map { $0.rawValue }),
        "tipSharpness": .num("0 round … 1 sharp, tapered ends (fountain and brush)", min: 0, max: 1),
        "pressureSensitivity": .num("0 uniform … 1 strongly pressure-driven width", min: 0, max: 1),
        "tipFlatness": .num("0 round … 1 flat chisel nib (fountain)", min: 0, max: 1),
        "reactsToRoll": .bool("the nib follows Apple Pencil Pro barrel roll (fountain)")
    ], required: [], "InkStyle; every field optional")

    static let stroke: JSONSchema = .obj([
        "style": style,
        "fmt": .str("field order of pts (default xy)", choices: InkSchemas.formatNames),
        "pts": .arr(.num(), "flat numbers, the fmt fields of each point in turn, x and y in page points"),
        "t0": .num("unix seconds of the first point (links ink to audio)"),
        "ptsB64": .str("instead of pts: base64 little-endian Float32, 10 per point (full order)")
    ], required: [], "Stroke JSON")
}

// MARK: - ink.addStrokes

/// `ink.addStrokes {page, strokes[], ids?}` (edit): validates every stroke, runs `InkModel.prepare` on each (sparse
/// AI, plugin and synthesised polylines are densified to ≤ 1.5 pt spacing with tripled end points, then get nib sizes:
/// PencilKit reads stroke points as B-spline control points), puts them on the active layer, honours caller ids, and
/// writes them with ONE batch `tx.put(items, doc:page:)` in one transaction (one undo step).
@MainActor
enum InkAddStrokes {
    static let descriptor = CommandDescriptor(
        id: "ink.addStrokes", title: "Add Ink",
        summary: "Add strokes {style, fmt, pts} in page points as one undo step; sparse points are densified and nib sizes derived; optional caller ids; active layer.",
        params: .obj(["page": .ref,
                      "strokes": .arr(InkSchemas.stroke, "the strokes, drawn in this order (at most \(InkLimits.maxStrokes))"),
                      "ids": .arr(.str("your own id, [A-Za-z0-9_-]{1,64}"), "caller-chosen ids, in stroke order")],
                     required: ["page", "strokes"]),
        examples: [
            try! JSONValue.parse(##"{"page":"page:FIXTUREDOC01/FIXTUREPG002","strokes":[{"style":{"tool":"pen","pen":"ball","color":"#2156D9","width":1.2},"fmt":"xy","pts":[100,100,220,100,220,170,100,170,100,100]}]}"##),
            try! JSONValue.parse(##"{"page":"page:FIXTUREDOC04/FIXTUREBRD01","strokes":[{"style":{"tool":"pencil","color":"#5B6068","width":1.6},"fmt":"xyt","pts":[40,60,0,90,64,0.05,140,58,0.1]},{"fmt":"xy","pts":[40,90,140,92]}],"ids":["AISTROKE0001","AISTROKE0002"]}"##)
        ],
        effect: .edit)

    static func handle(_ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue {
        let (doc, page) = try InkParse.page(params["page"], ctx)
        guard let list = params["strokes"]?.arrayValue else {
            throw NibError(.invalidParams, "strokes must be an array of Stroke objects", path: "$.strokes",
                           hint: InkParse.describeHint("ink.addStrokes"))
        }
        guard !list.isEmpty else { throw NibError.invalid("give at least one stroke", path: "$.strokes") }
        guard list.count <= InkLimits.maxStrokes else {
            throw NibError.invalid("at most \(InkLimits.maxStrokes) strokes per call; send the rest in another call",
                                   path: "$.strokes")
        }
        let ids = try InkParse.ids(params["ids"], count: list.count)
        var strokes: [Stroke] = []
        strokes.reserveCapacity(list.count)
        var batchPoints = 0
        for (i, json) in list.enumerated() {
            let path = "$.strokes[\(i)]"
            var stroke = try InkParse.stroke(json, path: path)
            try InkParse.checkPreparable(stroke.points, path: path + ".pts")
            batchPoints += InkParse.preparedCount(stroke.points)
            guard batchPoints <= InkLimits.maxBatchPoints else {
                throw NibError.invalid("too many prepared points in one batch; split the strokes across calls", path: "$.strokes")
            }
            InkParse.prepare(&stroke)
            strokes.append(stroke)
        }
        try InkParse.checkWritable(doc, ctx)
        let layer = InkParse.activeLayer(ctx, doc: doc)
        let written = try ctx.mutate { tx -> [Item] in
            var items: [Item] = []
            items.reserveCapacity(strokes.count)
            for (i, stroke) in strokes.enumerated() {
                var item = Item.makeStroke(stroke, layer: layer)
                if let id = ids[i] {
                    item.id = id
                    if (try? tx.item(doc, page: page, id: id)) != nil {
                        throw NibError(.conflict, "an item with id \(id.raw) already exists on this page", path: "$.ids[\(i)]",
                                       hint: "choose another id or leave it out")
                    }
                }
                items.append(item)
            }
            return try tx.put(items, doc: doc, page: page)
        }
        return .object(["refs": .array(written.map { JSONValue.string(NodeRef.item(doc, page, $0.id).description) })])
    }
}

// MARK: - ink.setPoints

/// `ink.setPoints {ref, fmt, pts}` (edit): replaces a stroke's whole point array and re-prepares it (points without
/// nib sizes are densified and sized, as `ink.addStrokes` does).
@MainActor
enum InkSetPoints {
    static let descriptor = CommandDescriptor(
        id: "ink.setPoints", title: "Edit Ink Points",
        summary: "Replace all points of a stroke: fmt (xy…full) and a flat pts array in page points; points without nib sizes are densified and sized like new ink.",
        params: .obj(["ref": .ref,
                      "fmt": .str("field order of pts", choices: InkSchemas.formatNames),
                      "pts": .arr(.num(), "flat numbers, the fmt fields of each point in turn")],
                     required: ["ref", "fmt", "pts"]),
        examples: [try! JSONValue.parse(##"{"ref":"item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01","fmt":"xy","pts":[72,120,150,160,230,118]}"##)],
        effect: .edit)

    static func handle(_ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue {
        let (doc, page, id) = try InkParse.item(params["ref"], path: "$.ref")
        let points = try InkParse.points(fmt: params["fmt"], pts: params["pts"], compact: nil, path: "$")
        try InkParse.checkPreparable(points, path: "$.pts")
        let item = try ctx.workspace.item(doc, page: page, id: id)
        guard item.kind == .stroke, var stroke = item.stroke else {
            throw NibError(.invalidParams, "item \(id.raw) is a \(item.kind.rawValue), not a stroke", path: "$.ref",
                           hint: item.kind == .shape ? "use shape.setPoints for shapes" : "pass the ref of an ink stroke")
        }
        guard !item.locked else {
            throw NibError(.invalidParams, "item \(id.raw) is locked", path: "$.ref", hint: "unlock it first")
        }
        try InkParse.checkWritable(doc, ctx)
        stroke.points = points
        InkParse.prepare(&stroke)
        var updated = item
        updated.stroke = stroke
        try ctx.mutate { tx in try tx.put(updated, doc: doc, page: page) }
        return .object(["ref": .string(NodeRef.item(doc, page, id).description), "count": .number(Double(stroke.points.count))])
    }
}

// MARK: - ink.setStyle

/// The style fields `ink.setStyle` may change (every one optional, at least one given).
struct InkStylePatch: Equatable {
    var tool: InkTool?
    var pen: PenStyle?
    var color: RGBA?
    var width: Double?
    var pattern: StrokePattern?
    var tipSharpness: Double?
    var pressureSensitivity: Double?
    var tipFlatness: Double?
    var reactsToRoll: Bool?

    static let fields = ["tool", "pen", "color", "width", "pattern", "tipSharpness", "pressureSensitivity", "tipFlatness",
                         "reactsToRoll"]

    static func parse(_ json: JSONValue, path: String) throws -> InkStylePatch {
        guard let o = json.objectValue else {
            throw NibError.invalid("style must be an object such as {\"color\": \"#D9432B\", \"width\": 2}", path: path)
        }
        var p = InkStylePatch()
        for key in o.keys.sorted() where !fields.contains(key) {
            throw NibError(.invalidParams, "unknown style field '\(key)'", path: path + "." + key,
                           hint: "style fields: " + fields.joined(separator: ", "))
        }
        func string(_ key: String) throws -> String? {
            guard let v = o[key], v != .null else { return nil }
            guard let s = v.stringValue else { throw NibError.invalid("\(key) must be a string", path: path + "." + key) }
            return s
        }
        func unit(_ key: String) throws -> Double? {
            guard let v = o[key], v != .null else { return nil }
            guard let d = v.doubleValue, d.isFinite, (0...1).contains(d) else {
                throw NibError.invalid("\(key) must be a number between 0 and 1", path: path + "." + key)
            }
            return d
        }
        if let s = try string("tool") {
            guard let t = InkTool(rawValue: s) else {
                throw NibError.invalid("tool must be one of " + InkTool.allCases.map { $0.rawValue }.joined(separator: ", "),
                                       path: path + ".tool")
            }
            p.tool = t
        }
        if let s = try string("pen") {
            guard let t = PenStyle(rawValue: s) else {
                throw NibError.invalid("pen must be one of " + PenStyle.allCases.map { $0.rawValue }.joined(separator: ", "),
                                       path: path + ".pen")
            }
            p.pen = t
        }
        if let s = try string("color") {
            guard let c = RGBA(hex: s) else { throw NibError.invalid("color must be #RRGGBB or #RRGGBBAA", path: path + ".color") }
            p.color = c
        }
        if let v = o["width"], v != .null {
            guard let w = v.doubleValue, w.isFinite, w > 0, w <= InkLimits.maxWidth else {
                throw NibError.invalid("width must be a number of points above 0 and at most \(Int(InkLimits.maxWidth))",
                                       path: path + ".width")
            }
            p.width = w
        }
        if let s = try string("pattern") {
            guard let t = StrokePattern(rawValue: s) else {
                throw NibError.invalid("pattern must be solid, dashed or dotted", path: path + ".pattern")
            }
            p.pattern = t
        }
        p.tipSharpness = try unit("tipSharpness")
        p.pressureSensitivity = try unit("pressureSensitivity")
        p.tipFlatness = try unit("tipFlatness")
        if let v = o["reactsToRoll"], v != .null {
            guard let b = v.boolValue else { throw NibError.invalid("reactsToRoll must be true or false", path: path + ".reactsToRoll") }
            p.reactsToRoll = b
        }
        guard p != InkStylePatch() else {
            throw NibError(.invalidParams, "style names no field to change", path: path,
                           hint: "style fields: " + fields.joined(separator: ", "))
        }
        return p
    }

    /// The stroke in the new style. A new width scales the captured nib sizes with it; a new tool or pen type derives
    /// them again from the new ink (`InkModel.fillSizes`, which follows the recorded pressure); a new pressure
    /// sensitivity rescales the width's swing around its mean.
    func applied(to stroke: Stroke) -> Stroke {
        var s = stroke
        let old = stroke.style
        var style = old
        if let t = tool { style.tool = t }
        if let t = pen { style.pen = t }
        style.pen = style.tool == .pen ? (style.pen ?? .fountain) : nil
        if let c = color { style.color = c }
        if let w = width { style.width = w }
        if let t = pattern { style.pattern = t }
        if let v = tipSharpness { style.tipSharpness = v }
        if let v = pressureSensitivity { style.pressureSensitivity = v }
        if let v = tipFlatness { style.tipFlatness = v }
        if let v = reactsToRoll { style.reactsToRoll = v }
        s.style = style
        let captured = s.points.contains { $0.width > 0 }
        if style.tool != old.tool || style.pen != old.pen || style.tipSharpness != old.tipSharpness
            || style.tipFlatness != old.tipFlatness || style.pressureSensitivity != old.pressureSensitivity {
            for i in s.points.indices {
                s.points[i].width = 0
                s.points[i].height = 0
            }
            InkModel.fillSizes(&s.points, style: style)
            PenDynamics.apply(&s.points, style: style, captured: false)
            return s
        }
        if captured, style.width != old.width, old.width > 0 {
            let k = Float(style.width / old.width)
            for i in s.points.indices {
                s.points[i].width = max(0.1, s.points[i].width * k)
                s.points[i].height = max(0.1, s.points[i].height * k)
            }
        }
        if !style.reactsToRoll {
            for i in s.points.indices { s.points[i].roll = 0 }
        }
        return s
    }
}

/// `ink.setStyle {refs, style}` (edit): changes style fields of existing strokes, on any pages, in one undo step.
struct InkSetStyle: NibCommand {
    struct Params: Codable {
        /// The schema requires it; the user may omit it (menus, toolbar): the window's selection (§6.1).
        var refs: [String]?
        var style: JSONValue
    }

    struct Output: Codable, Equatable {
        var updated: Int
    }

    static let descriptor = CommandDescriptor(
        id: "ink.setStyle", title: "Change Ink Style",
        summary: "Change stroke style fields on refs: tool, pen, colour, width, pattern, sharpness, pressure, flatness and roll; nib sizes follow, one undo step.",
        params: .obj(["refs": .arr(.ref, "stroke item refs item:D/P/I"),
                      "style": InkSchemas.style],
                     required: ["refs", "style"]),
        examples: [
            try! JSONValue.parse(##"{"refs":["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"],"style":{"color":"#D9432B","width":2}}"##),
            try! JSONValue.parse(##"{"refs":["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"],"style":{"pen":"brush","pattern":"dashed"}}"##)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let refs = ctx.refsOrSelection(p.refs)
        guard !refs.isEmpty else {
            throw NibError(.invalidParams, "give at least one stroke ref", path: "$.refs",
                           hint: "select strokes first, or pass refs like item:D/P/I")
        }
        let patch = try InkStylePatch.parse(p.style, path: "$.style")
        struct Target: Hashable {
            let doc: DocumentID
            let page: PageID
        }
        var order: [Target] = []
        var changes: [Target: [Item]] = [:]
        var seen = Set<String>()
        for (i, ref) in refs.enumerated() where seen.insert(ref).inserted {
            let (doc, page, id) = try InkParse.item(.string(ref), path: "$.refs[\(i)]")
            let item = try ctx.workspace.item(doc, page: page, id: id)
            guard item.kind == .stroke, let stroke = item.stroke else {
                throw NibError(.invalidParams, "item \(id.raw) is a \(item.kind.rawValue), not a stroke", path: "$.refs[\(i)]",
                               hint: item.kind == .shape ? "use shape.setStyle for shapes" : "pass ink stroke refs only")
            }
            guard !item.locked else {
                throw NibError(.invalidParams, "item \(id.raw) is locked", path: "$.refs[\(i)]", hint: "unlock it first")
            }
            var updated = item
            updated.stroke = patch.applied(to: stroke)
            let key = Target(doc: doc, page: page)
            if changes[key] == nil {
                order.append(key)
                try InkParse.checkWritable(doc, ctx)
            }
            changes[key, default: []].append(updated)
        }
        try ctx.mutate { tx in
            for key in order {
                try tx.put(changes[key] ?? [], doc: key.doc, page: key.page)
            }
        }
        return Output(updated: changes.values.reduce(0) { $0 + $1.count })
    }
}
