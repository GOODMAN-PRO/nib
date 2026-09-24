import Foundation
import NibContracts

/// Result shapes (ARCHITECTURE §7.2), paging (§7.4) and raw-edit helpers shared by the query, node and asset commands.
@MainActor
enum Shapes {
    /// Fields non-user principals may never write through raw edits (ARCHITECTURE §6.4).
    static let protectedFields = ["createdBy", "rev", "deleted", "id"]
    /// Document meta fields non-user principals may never write.
    static let protectedMetaFields = ["id", "rev", "format", "locked", "trashedFrom"]
    /// Summary text is cut here so one row never dominates a result page.
    static let summaryTextLimit = 500
    /// Assets up to this size come back inline (base64) from asset.get, still under the 20 KB result cap.
    static let inlineAssetBytes = 12_000

    // MARK: Refs, locks, ids

    static func ref(_ s: String, path: String) throws -> NodeRef {
        guard let r = NodeRef(s) else {
            throw NibError(.invalidParams, "'\(s)' is not a node ref", path: path,
                           hint: "refs look like doc:D, page:D/P, item:D/P/I; get them from query.context, query.get or query.find")
        }
        return r
    }

    /// The app that owns this call's bus (registries the context does not carry: custom item types, navigator).
    static func app(_ ctx: CommandContext) -> NibApp? {
        guard let app = NibApp.shared, app.bus === ctx.bus else { return nil }
        return app
    }

    /// Password-locked documents are never expanded for non-user principals (ARCHITECTURE §7.4).
    static func hidden(_ doc: DocumentID, _ ctx: CommandContext) -> Bool {
        !ctx.principal.isUser && isLocked(doc, ctx)
    }

    static func isLocked(_ doc: DocumentID, _ ctx: CommandContext) -> Bool {
        ctx.services.lock?.isLocked(doc) ?? false
    }

    static func requireUnlocked(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if hidden(doc, ctx) {
            throw NibError(.locked, "document \(doc) is locked", hint: "ask the user to unlock it first")
        }
    }

    static func title(_ doc: DocumentID, _ ctx: CommandContext) -> String? {
        ctx.services.library?.node(doc)?.title
    }

    static func lastID(_ r: NodeRef) -> NibID? {
        switch r {
        case .library: return nil
        case .folder(let f): return f
        case .document(let d): return d
        case .page(_, let p): return p
        case .item(_, _, let i): return i
        case .block(_, let x), .card(_, let x), .audio(_, let x), .outline(_, let x): return x
        }
    }

    /// Lets callers pass refs ("page:D/P") where a record stores a bare id.
    static func unref(_ o: inout [String: JSONValue], _ keys: [String]) {
        for k in keys {
            if let s = o[k]?.stringValue, let r = NodeRef(s), let id = lastID(r) { o[k] = .string(id.raw) }
        }
    }

    /// Accepts the query shape `[w, h]` for a page size (records store {width, height}).
    static func normalizeSize(_ o: inout [String: JSONValue]) {
        if let a = o["size"]?.arrayValue, a.count == 2, let w = a[0].doubleValue, let h = a[1].doubleValue {
            o["size"] = .object(["width": .number(w), "height": .number(h)])
        }
    }

    // MARK: Numbers and geometry

    static func num(_ v: Double) -> JSONValue { .number((v * 100).rounded() / 100) }

    static func rect(_ r: Rect) -> JSONValue { .array([num(r.x), num(r.y), num(r.width), num(r.height)]) }

    static func size(_ s: PageSize?) -> JSONValue {
        guard let s = s else { return .null }
        return .array([num(s.width), num(s.height)])
    }

    static func rect(from a: [Double], path: String) throws -> Rect {
        guard a.count == 4 else { throw NibError(.invalidParams, "expected [x, y, width, height]", path: path) }
        return Rect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    static func clip(_ t: String) -> String {
        t.count > summaryTextLimit ? String(t.prefix(summaryTextLimit)) + "…" : t
    }

    /// One stroke point in the canonical "full" order, rounded like the Stroke codec.
    static func pointRow(_ p: StrokePoint) -> JSONValue {
        let values: [Float] = [p.x, p.y, p.t, p.force, p.azimuth, p.altitude, p.roll, p.width, p.height, p.opacity]
        return .array(values.map { JSONValue.number((Double($0) * 1000).rounded() / 1000) })
    }

    // MARK: Items

    /// Readable text of an item (typed text, labels, LaTeX, comments, custom item text); nil for ink.
    static func text(of it: Item, _ ctx: CommandContext) -> String? {
        var s: String?
        switch it.kind {
        case .text: s = it.text?.text.plainText
        case .sticky: s = it.sticky?.text.plainText
        case .shape: s = it.shape?.text?.plainText
        case .connector: s = it.connector?.label?.plainText
        case .math: s = it.math?.latex.joined(separator: "\n")
        case .comment: s = it.comment?.messages.map { $0.text }.joined(separator: "\n")
        case .image: s = it.image?.altText
        case .custom: s = it.custom.flatMap { customText($0, ctx) }
        case .stroke: s = nil
        }
        guard let t = s, !t.isEmpty else { return nil }
        return t
    }

    /// Text of a custom item via its registered `textPath` (else `data.title` / `data.text`).
    static func customText(_ c: CustomItem, _ ctx: CommandContext) -> String? {
        let declared = app(ctx)?.content.customItemTypes.get("custom." + c.owner + "." + c.type)?.textPath
        for path in declared.map({ [$0] }) ?? ["title", "text"] {
            var v: JSONValue? = c.data
            for key in path.split(separator: ".") { v = v?[String(key)] }
            if let s = v?.stringValue { return s }
        }
        return nil
    }

    /// The §7.2 item row: ref, kind, bbox, layer plus the few fields that describe the item.
    static func summary(_ it: Item, doc: DocumentID, page: PageID, _ ctx: CommandContext) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["ref": .string(NodeRef.item(doc, page, it.id).description),
                                      "kind": .string(it.kind.rawValue), "bbox": rect(it.bounds),
                                      "layer": .number(Double(it.layer))]
        if it.locked { o["locked"] = .bool(true) }
        if let a = it.attachedTo { o["attachedTo"] = .string(NodeRef.item(doc, page, a).description) }
        if let s = it.stroke {
            o["tool"] = .string(s.style.tool.rawValue)
            if s.style.tool == .pen, let pen = s.style.pen { o["pen"] = .string(pen.rawValue) }
            o["color"] = .string(s.style.color.hex)
            o["width"] = num(s.style.width)
            o["pointCount"] = .number(Double(s.points.count))
        }
        if let s = it.shape {
            o["shape"] = .string(s.shape.rawValue)
            if let c = s.style.strokeColor { o["color"] = .string(c.hex) }
            if let f = s.style.fillColor { o["fill"] = .string(f.hex) }
        }
        if let c = it.connector {
            if let i = c.from.item { o["from"] = .string(NodeRef.item(doc, page, i).description) }
            if let i = c.to.item { o["to"] = .string(NodeRef.item(doc, page, i).description) }
        }
        if let i = it.image { o["asset"] = .string(i.asset.name) }
        if let s = it.sticky { o["color"] = .string(s.color.hex) }
        if let m = it.math { o["color"] = .string(m.color.hex) }
        if let c = it.comment {
            o["messages"] = .number(Double(c.messages.count))
            if c.resolved { o["resolved"] = .bool(true) }
        }
        if let c = it.custom {
            o["owner"] = .string(c.owner)
            o["type"] = .string(c.type)
        }
        if let t = text(of: it, ctx) { o["text"] = .string(clip(t)) }
        return o
    }

    /// The item's record JSON; stroke points are replaced by `pointCount` unless `points`.
    static func itemJSON(_ item: Item, points: Bool) throws -> [String: JSONValue] {
        var it = item
        if !points {
            it.stroke?.points = []
            it.math?.sourceInk = item.math?.sourceInk?.map { stroke -> Stroke in
                var copy = stroke
                copy.points = []
                return copy
            }
        }
        let json = try JSONValue.from(it)
        var o = (points ? json : stripPoints(json)).objectValue ?? [:]
        if !points, let s = item.stroke, var so = o["stroke"]?.objectValue {
            so["pointCount"] = .number(Double(s.points.count))
            o["stroke"] = .object(so)
        }
        return o
    }

    /// Record JSON for pages, blocks, cards, clips and outline entries (ink points dropped unless `points`).
    static func recordJSON<T: Encodable>(_ record: T, points: Bool) throws -> [String: JSONValue] {
        let json = try JSONValue.from(record)
        return (points ? json : stripPoints(json)).objectValue ?? [:]
    }

    /// Removes flat point arrays (`pts` / `ptsB64` / `fmt`) from every stroke object inside `v`.
    static func stripPoints(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(var o):
            if o["style"] != nil && (o["pts"] != nil || o["ptsB64"] != nil) {
                o["pts"] = nil
                o["ptsB64"] = nil
                o["fmt"] = nil
            }
            return .object(o.mapValues { stripPoints($0) })
        case .array(let a):
            return .array(a.map { stripPoints($0) })
        default:
            return v
        }
    }

    /// A listing row: the summary, the full record JSON (`depth ≥ 2`), or only `fields` (plus ref and kind).
    static func pick(_ summary: [String: JSONValue], depth: Int, fields: [String]?,
                     full: () throws -> [String: JSONValue]) rethrows -> JSONValue {
        if let fields = fields {
            let f = try full()
            var r: [String: JSONValue] = [:]
            for k in ["ref", "kind"] + fields {
                if let v = summary[k] ?? f[k] { r[k] = v }
            }
            return .object(r)
        }
        guard depth >= 2 else { return .object(summary) }
        var f = try full()
        f["ref"] = summary["ref"]
        return .object(f)
    }

    /// `where` filter of query.find: every key must match the row (or the item JSON when the row lacks it).
    /// Objects match as subsets (e.g. {"ext": {"dev.x": {"tag": "a"}}}); colours compare as colours.
    static func matches(_ row: [String: JSONValue], _ want: [String: JSONValue],
                        full: () -> [String: JSONValue]) -> Bool {
        var fullJSON: [String: JSONValue]?
        for (k, v) in want {
            var have = row[k]
            if have == nil {
                if fullJSON == nil { fullJSON = full() }
                have = fullJSON?[k]
            }
            if !jsonMatches(have, v) { return false }
        }
        return true
    }

    static func jsonMatches(_ have: JSONValue?, _ want: JSONValue) -> Bool {
        switch want {
        case .null:
            return have == nil || have == JSONValue.null
        case .object(let o):
            guard case .object(let h)? = have else { return false }
            return o.allSatisfy { jsonMatches(h[$0.key], $0.value) }
        case .string(let s):
            if s.hasPrefix("#"), let a = RGBA(hex: s), let hs = have?.stringValue, let b = RGBA(hex: hs) { return a == b }
            return have == want
        default:
            return have == want
        }
    }

    // MARK: Raw edits

    /// Record JSON with stroke points as exact base64 floats, so encode → merge → decode never drifts.
    static func compactJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.userInfo[.nibCompactPoints] = true
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    /// Decodes a record; failures become `invalid_params` at the offending JSON path under `root`.
    static func decode<T: Decodable>(_ type: T.Type, _ json: JSONValue, at root: String) throws -> T {
        do {
            return try json.decode(T.self)
        } catch let error as DecodingError {
            var message = "invalid value"
            var context: DecodingError.Context?
            var tail = ""
            switch error {
            case let .keyNotFound(key, c):
                message = "missing '\(key.stringValue)'"
                context = c
                tail = "." + key.stringValue
            case let .typeMismatch(expected, c):
                message = "wrong type (expected \(expected))"
                context = c
            case let .valueNotFound(expected, c):
                message = "missing value (expected \(expected))"
                context = c
            case let .dataCorrupted(c):
                message = c.debugDescription
                context = c
            @unknown default:
                break
            }
            let keys = context?.codingPath ?? []
            let path = root + keys.map { k in k.intValue.map { "[\($0)]" } ?? "." + k.stringValue }.joined() + tail
            throw NibError(.invalidParams, message, path: path,
                           hint: "compare with the record's JSON from query.get (depth 2) and commands.describe")
        }
    }

    /// Non-user principals may not write provenance, revisions, tombstones, ids or protected meta (§6.4).
    static func rejectProtected(_ patch: [String: JSONValue], keys: [String], path: String, _ ctx: CommandContext) throws {
        guard !ctx.principal.isUser else { return }
        for k in keys where patch[k] != nil {
            throw NibError(.invalidParams, "'\(k)' cannot be set by \(ctx.principal)", path: path + "." + k,
                           hint: "the app stamps provenance, revisions and ids itself; remove '\(k)'")
        }
    }

    /// A stroke patch that replaces points must name their format and give the whole flat array.
    static func checkStrokePoints(_ stroke: [String: JSONValue], path: String) throws {
        guard let pts = stroke["pts"], pts != JSONValue.null else { return }
        let formats = StrokePoint.formats.keys.sorted().joined(separator: ", ")
        guard let fmt = stroke["fmt"]?.stringValue else {
            throw NibError(.invalidParams, "'fmt' is required with 'pts'", path: path + ".fmt",
                           hint: "e.g. \"fmt\": \"xy\" with \"pts\": [x0, y0, x1, y1, …]; formats: " + formats)
        }
        guard let fields = StrokePoint.formats[fmt] else {
            throw NibError(.invalidParams, "unknown point format '\(fmt)'", path: path + ".fmt", hint: "use one of " + formats)
        }
        guard let values = pts.arrayValue, !values.isEmpty, values.count % fields.count == 0,
              values.allSatisfy({ $0.doubleValue != nil }) else {
            throw NibError(.invalidParams, "'pts' must be a flat array of numbers, \(fields.count) per point for '\(fmt)'",
                           path: path + ".pts")
        }
    }

    /// An order / z key placing a record at `index` among the sorted keys of its live siblings (nil = last).
    static func orderKey(at index: Int?, among keys: [String]) -> String {
        let i = min(max(index ?? keys.count, 0), keys.count)
        return FractionalIndex.between(i > 0 ? keys[i - 1] : nil, i < keys.count ? keys[i] : nil)
    }

    // MARK: Paging (ARCHITECTURE §7.4)

    static func offset(_ cursor: String?) throws -> Int {
        guard let c = cursor, !c.isEmpty else { return 0 }
        guard let n = Int(c), n >= 0 else {
            throw NibError(.invalidParams, "invalid cursor '\(c)'", path: "$.cursor",
                           hint: "pass the cursor returned by the previous call")
        }
        return n
    }

    /// Adds rows `offset…` of `count` under `key` of `base`: as many as fit `NibLimits.aiToolResultBytes` (at least
    /// one, so paging always advances; at most `limit`), plus `cursor` + `truncated` when rows remain.
    /// `overhead` = bytes the caller adds around the result afterwards.
    static func fill(_ base: [String: JSONValue], key: String, count: Int, offset: Int, limit: Int, overhead: Int = 0,
                     row: (Int) throws -> JSONValue) rethrows -> JSONValue {
        var out = base
        let budget = NibLimits.aiToolResultBytes - JSONValue.object(base).jsonString().utf8.count - overhead - 64
        var rows: [JSONValue] = []
        var used = 0
        var i = max(0, offset)
        while i < count && rows.count < max(1, limit) {
            let r = try row(i)
            let bytes = r.jsonString().utf8.count + 1
            if !rows.isEmpty && used + bytes > budget { break }
            rows.append(r)
            used += bytes
            i += 1
        }
        out[key] = .array(rows)
        if i < count {
            out["cursor"] = .string(String(i))
            out["truncated"] = .bool(true)
        }
        return .object(out)
    }
}
