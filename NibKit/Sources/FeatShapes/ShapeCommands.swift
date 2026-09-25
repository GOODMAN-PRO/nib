import Foundation
import NibContracts

// MARK: - Params

/// A partial `ShapeItemStyle`: only the fields present change. `null` (or "none") clears an optional colour or the
/// ink look, so "no outline" and "no fill" are expressible in JSON.
struct ShapeStylePatch: Equatable {
    enum Change<T: Equatable>: Equatable {
        case keep
        case set(T)
    }

    var strokeColor: Change<RGBA?> = .keep
    var strokeWidth: Change<Double> = .keep
    var fillColor: Change<RGBA?> = .keep
    var radius: Change<Double> = .keep
    var pattern: Change<StrokePattern> = .keep
    var drawnWith: Change<InkTool?> = .keep
    var arrowStart: Change<Bool> = .keep
    var arrowEnd: Change<Bool> = .keep

    static let fields = ["strokeColor", "strokeWidth", "fillColor", "cornerRadius", "pattern", "drawnWith",
                         "arrowStart", "arrowEnd"]

    static let schema: JSONSchema = .obj([
        "strokeColor": .str("outline colour #RRGGBB or #RRGGBBAA; null or \"none\" = no outline"),
        "strokeWidth": .num("outline width in points", min: 0.1, max: 100),
        "fillColor": .str("fill colour #RRGGBB or #RRGGBBAA (alpha = translucency); null or \"none\" = no fill"),
        "cornerRadius": .num("corner rounding in points, 0 = sharp", min: 0, max: 1000),
        "pattern": .str("outline pattern", choices: StrokePattern.allCases.map { $0.rawValue }),
        "drawnWith": .str("draw the outline as pen, pencil or highlighter ink; null or \"none\" = clean vector",
                          choices: ["pen", "pencil", "highlighter", "none"]),
        "arrowStart": .bool("arrowhead at the first point (open shapes)"),
        "arrowEnd": .bool("arrowhead at the last point (open shapes; arrows always have one)")
    ], "only the fields given change")

    static func parse(_ value: JSONValue, path: String) throws -> ShapeStylePatch {
        guard case .object(let o) = value else { throw NibError.invalid("style must be an object", path: path) }
        var p = ShapeStylePatch()
        for (key, v) in o.sorted(by: { $0.key < $1.key }) {
            let at = path + "." + key
            switch key {
            case "strokeColor":
                p.strokeColor = .set(try colour(v, at))
            case "fillColor":
                p.fillColor = .set(try colour(v, at))
            case "strokeWidth":
                p.strokeWidth = .set(try number(v, at, 0.1...100))
            case "cornerRadius":
                p.radius = .set(try number(v, at, 0...1000))
            case "pattern":
                guard let s = v.stringValue, let pattern = StrokePattern(rawValue: s) else {
                    throw NibError.invalid("expected one of: solid, dashed, dotted", path: at)
                }
                p.pattern = .set(pattern)
            case "drawnWith":
                if v == .null || v.stringValue == "none" {
                    p.drawnWith = .set(nil)
                } else {
                    guard let s = v.stringValue, let tool = InkTool(rawValue: s), tool != .tape else {
                        throw NibError.invalid("expected pen, pencil, highlighter or null", path: at)
                    }
                    p.drawnWith = .set(tool)
                }
            case "arrowStart", "arrowEnd":
                guard let b = v.boolValue else { throw NibError.invalid("expected true or false", path: at) }
                if key == "arrowStart" { p.arrowStart = .set(b) } else { p.arrowEnd = .set(b) }
            default:
                throw NibError(.invalidParams, "unknown style field '\(key)'", path: at,
                               hint: "style fields: " + fields.joined(separator: ", "))
            }
        }
        return p
    }

    private static func colour(_ v: JSONValue, _ at: String) throws -> RGBA? {
        if v == .null { return nil }
        guard let s = v.stringValue else { throw NibError.invalid("expected a colour string or null", path: at) }
        if s.isEmpty || s.lowercased() == "none" { return nil }
        guard let c = RGBA(hex: s) else { throw NibError.invalid("expected #RRGGBB or #RRGGBBAA, or null for none", path: at) }
        return c
    }

    private static func number(_ v: JSONValue, _ at: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let n = v.doubleValue, n.isFinite else { throw NibError.invalid("expected a number", path: at) }
        guard range.contains(n) else {
            throw NibError.invalid("must be between \(range.lowerBound) and \(range.upperBound)", path: at)
        }
        return n
    }

    /// Every field set: the whole style as a patch (new shapes from the tool).
    static func full(_ s: ShapeItemStyle) -> ShapeStylePatch {
        ShapeStylePatch(strokeColor: .set(s.strokeColor), strokeWidth: .set(s.strokeWidth), fillColor: .set(s.fillColor),
                        radius: .set(s.cornerRadius), pattern: .set(s.pattern), drawnWith: .set(s.drawnWith),
                        arrowStart: .set(s.arrowStart), arrowEnd: .set(s.arrowEnd))
    }

    func applied(to base: ShapeItemStyle) -> ShapeItemStyle {
        var s = base
        if case .set(let v) = strokeColor { s.strokeColor = v }
        if case .set(let v) = strokeWidth { s.strokeWidth = v }
        if case .set(let v) = fillColor { s.fillColor = v }
        if case .set(let v) = radius { s.cornerRadius = v }
        if case .set(let v) = pattern { s.pattern = v }
        if case .set(let v) = drawnWith { s.drawnWith = v }
        if case .set(let v) = arrowStart { s.arrowStart = v }
        if case .set(let v) = arrowEnd { s.arrowEnd = v }
        return s
    }

    /// The patch as `shape.setStyle` / `shape.create` JSON (cleared fields are explicit nulls).
    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        func colour(_ c: RGBA?) -> JSONValue { c.map { JSONValue.string($0.hex) } ?? JSONValue.null }
        if case .set(let v) = strokeColor { o["strokeColor"] = colour(v) }
        if case .set(let v) = strokeWidth { o["strokeWidth"] = .number(v) }
        if case .set(let v) = fillColor { o["fillColor"] = colour(v) }
        if case .set(let v) = radius { o["cornerRadius"] = .number(v) }
        if case .set(let v) = pattern { o["pattern"] = .string(v.rawValue) }
        if case .set(let v) = drawnWith { o["drawnWith"] = v.map { JSONValue.string($0.rawValue) } ?? JSONValue.null }
        if case .set(let v) = arrowStart { o["arrowStart"] = .bool(v) }
        if case .set(let v) = arrowEnd { o["arrowEnd"] = .bool(v) }
        return .object(o)
    }
}

/// Parameter parsing shared by the shape commands.
enum ShapeParse {
    static let kindSchema: JSONSchema = .str("shape type", choices: ShapeKind.allCases.map { $0.rawValue })
    static let frameSchema: JSONSchema = .arr(.num(), "[x, y, width, height] in page points; optional 5th value: rotation in radians")
    static let pointsSchema: JSONSchema = .arr(.point, "[[x, y], …] in page points: line/arrow 2, arc 3 (start, control, end), "
                                               + "curve 2+ Bézier control points, polyline 2+, polygon 3+")

    static func kind(_ s: String, path: String) throws -> ShapeKind {
        guard let k = ShapeKind(rawValue: s) else {
            throw NibError.invalid("unknown shape '\(s)'; expected one of: "
                                   + ShapeKind.allCases.map { $0.rawValue }.joined(separator: ", "), path: path)
        }
        return k
    }

    static func frame(_ v: [Double], path: String) throws -> Frame {
        guard v.count == 4 || v.count == 5, v.allSatisfy({ $0.isFinite }) else {
            throw NibError.invalid("frame is [x, y, width, height] (optional 5th: rotation in radians)", path: path)
        }
        guard v[2] >= 0, v[3] >= 0 else { throw NibError.invalid("width and height must be 0 or more", path: path) }
        return Frame(x: v[0], y: v[1], w: v[2], h: v[3], rotation: v.count == 5 ? v[4] : 0)
    }

    static func page(_ ref: String, path: String) throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref page:D/P", path: path, hint: "call query.context for the current page")
        }
        return (doc, page)
    }

    static func item(_ ref: String, path: String) throws -> (DocumentID, PageID, ElementID) {
        guard case let .item(doc, page, id)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected an item ref item:D/P/I", path: path, hint: "query.find {kinds: [\"shape\"]}")
        }
        return (doc, page, id)
    }

    /// The live, unlocked shape item a ref points at.
    @MainActor
    static func shape(_ tx: DocTransaction, _ doc: DocumentID, _ page: PageID, _ id: ElementID, path: String) throws -> Item {
        let item = try tx.item(doc, page: page, id: id)
        guard item.kind == .shape, item.shape != nil else {
            throw NibError(.invalidParams, "item \(id) is a \(item.kind.rawValue), not a shape", path: path,
                           hint: "use item.recolor or the command for that kind")
        }
        guard !item.locked else {
            throw NibError(.invalidParams, "shape \(id) is locked", path: path, hint: "unlock it with item.setLocked first")
        }
        return item
    }

    /// Connectors anchored to `shape` follow its new outline (same transaction, so one undo step).
    @MainActor
    static func reanchorConnectors(_ tx: DocTransaction, doc: DocumentID, page: PageID, shape: Item) throws {
        for var c in try tx.items(doc, page: page) where c.kind == .connector {
            guard var con = c.connector else { continue }
            var changed = false
            if con.from.item == shape.id, let side = con.from.side,
               let p = shape.anchorPoint(side: side, t: con.from.t ?? 0.5), p != con.from.point {
                con.from.point = p
                changed = true
            }
            if con.to.item == shape.id, let side = con.to.side,
               let p = shape.anchorPoint(side: side, t: con.to.t ?? 0.5), p != con.to.point {
                con.to.point = p
                changed = true
            }
            if changed {
                c.connector = con
                try tx.put(c, doc: doc, page: page)
            }
        }
    }
}

/// JSON the UI sends (so the tool, the inspector and the control points use the same commands as plugins and AI).
enum ShapeJSON {
    static func points(_ pts: [Point]) -> JSONValue { .array(pts.map { JSONValue.array([.number($0.x), .number($0.y)]) }) }

    static func frame(_ f: Frame) -> JSONValue {
        var v: [JSONValue] = [.number(f.x), .number(f.y), .number(f.w), .number(f.h)]
        if f.rotation != 0 { v.append(.number(f.rotation)) }
        return .array(v)
    }

    static func createParams(_ s: ShapeItem, page: String) -> JSONValue {
        var o: [String: JSONValue] = ["page": .string(page), "shape": .string(s.shape.rawValue),
                                      "style": ShapeStylePatch.full(s.style).json]
        if ShapeGeometry.isBox(s.shape) { o["frame"] = frame(s.frame) } else { o["points"] = points(s.points) }
        if let t = s.text, !t.isEmpty { o["text"] = (try? JSONValue.from(t)) ?? .string(t.plainText) }
        return .object(o)
    }
}

// MARK: - Commands

struct ShapeCreate: NibCommand {
    struct Params: Codable {
        var page: String
        var shape: String
        var frame: [Double]?
        var points: [Point]?
        var style: JSONValue?
        var text: RichText?
        var id: String?
    }
    struct Output: Codable { var ref: String }

    static let descriptor = CommandDescriptor(
        id: "shape.create", title: "Create Shape",
        summary: "Create a shape: rectangle, roundedRectangle, ellipse, triangle, diamond from a frame, or line, arrow, "
            + "polyline, polygon, curve, arc from points; optional style, text and id.",
        params: .obj(["page": .ref, "shape": ShapeParse.kindSchema, "frame": ShapeParse.frameSchema,
                      "points": ShapeParse.pointsSchema, "style": ShapeStylePatch.schema,
                      "text": .anything("text inside the shape: a string or RichText"),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")], required: ["page", "shape"]),
        examples: [
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG002","shape":"ellipse","frame":[100,120,180,110],"style":{"fillColor":"#2156D94D"},"text":"Idea"}"#),
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","shape":"arrow","points":[[80,320],[260,360]],"style":{"strokeWidth":2}}"#),
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC04/FIXTUREBRD01","shape":"diamond","frame":[260,40,120,90],"style":{"strokeColor":null,"fillColor":"#FFE45C"},"text":"Decide"}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try ShapeParse.page(p.page, path: "$.page")
        if let id = p.id, !NibID.isValid(id) { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let kind = try ShapeParse.kind(p.shape, path: "$.shape")
        let patch = try p.style.map { try ShapeStylePatch.parse($0, path: "$.style") } ?? ShapeStylePatch()
        let frame = try p.frame.map { try ShapeParse.frame($0, path: "$.frame") }
        var shape = try ShapeGeometry.make(kind, frame: frame, points: p.points, style: patch.applied(to: ShapeItemStyle()))
        if kind == .roundedRectangle, patch.radius == .keep {
            shape.style.cornerRadius = ShapeGeometry.roundedDefault(shape.frame, current: shape.style.cornerRadius)
        }
        if let t = p.text, !t.isEmpty { shape.text = t }
        try ShapeGeometry.validate(shape, path: "$")
        let layer = ctx.activeSession?.activeLayer ?? 0
        let item = try ctx.mutate { tx -> Item in
            var it = Item.makeShape(shape, layer: layer)
            if let id = p.id {
                it.id = NibID(id)
                if (try? tx.item(doc, page: page, id: it.id)) != nil {
                    throw NibError(.conflict, "an item with id \(id) already exists on this page", path: "$.id",
                                   hint: "choose another id or leave it out")
                }
            }
            return try tx.put(it, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, item.id).description)
    }
}

struct ShapeSetStyle: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var style: JSONValue
    }

    static let descriptor = CommandDescriptor(
        id: "shape.setStyle", title: "Shape Style",
        summary: "Change shape style: outline colour/width or none (strokeColor null), fill (null = none, alpha = "
            + "translucency), cornerRadius, pattern, arrowheads, ink look (drawnWith).",
        params: .obj(["refs": .arr(.ref, "shape item refs"), "style": ShapeStylePatch.schema], required: ["refs", "style"]),
        examples: [
            try! JSONValue.parse(#"{"refs":["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"],"style":{"strokeColor":null,"fillColor":"#FFE45C99","cornerRadius":14}}"#),
            try! JSONValue.parse(#"{"refs":["item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01"],"style":{"pattern":"dashed","drawnWith":"pencil","strokeWidth":2.5}}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard !p.refs.isEmpty else { throw NibError.invalid("give at least one shape ref", path: "$.refs") }
        let patch = try ShapeStylePatch.parse(p.style, path: "$.style")
        let targets = try p.refs.enumerated().map { i, ref in try ShapeParse.item(ref, path: "$.refs[\(i)]") }
        try ctx.mutate { tx in
            for (i, target) in targets.enumerated() {
                let (doc, page, id) = target
                var item = try ShapeParse.shape(tx, doc, page, id, path: "$.refs[\(i)]")
                guard var s = item.shape else { continue }
                s.style = patch.applied(to: s.style)
                try ShapeGeometry.validate(s, path: "$")
                item.shape = s
                try tx.put(item, doc: doc, page: page)
            }
        }
        return NoResult()
    }
}

struct ShapeSetKind: NibCommand {
    struct Params: Codable {
        var ref: String
        var shape: String
    }

    static let descriptor = CommandDescriptor(
        id: "shape.setKind", title: "Change Shape Type",
        summary: "Change a shape's type keeping its frame (e.g. rectangle to ellipse, line to arrow); switching to a "
            + "point-based type derives its vertices from the current outline.",
        params: .obj(["ref": .ref, "shape": ShapeParse.kindSchema], required: ["ref", "shape"]),
        examples: [
            try! JSONValue.parse(#"{"ref":"item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01","shape":"ellipse"}"#),
            try! JSONValue.parse(#"{"ref":"item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01","shape":"polygon"}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, page, id) = try ShapeParse.item(p.ref, path: "$.ref")
        let kind = try ShapeParse.kind(p.shape, path: "$.shape")
        try ctx.mutate { tx in
            var item = try ShapeParse.shape(tx, doc, page, id, path: "$.ref")
            guard let old = item.shape, old.shape != kind else { return }
            var s = ShapeGeometry.setKind(old, to: kind)
            if kind == .roundedRectangle, old.shape != .rectangle {
                s.style.cornerRadius = ShapeGeometry.roundedDefault(s.frame, current: s.style.cornerRadius)
            }
            if ShapeGeometry.isOpen(kind), (s.style.strokeColor?.a ?? 0) == 0 {
                s.style.strokeColor = old.style.fillColor?.withAlpha(1) ?? .black    // a fill-only box stays visible as a line
            }
            try ShapeGeometry.validate(s, path: "$")
            item.shape = s
            let written = try tx.put(item, doc: doc, page: page)
            try ShapeParse.reanchorConnectors(tx, doc: doc, page: page, shape: written)
        }
        return NoResult()
    }
}

struct ShapeSetPoints: NibCommand {
    struct Params: Codable {
        var ref: String
        var points: [Point]
    }

    static let descriptor = CommandDescriptor(
        id: "shape.setPoints", title: "Edit Shape Points",
        summary: "Edit a shape's vertices / control points ([[x,y]…]); on box shapes 2 points set opposite corners and "
            + "3 or more turn it into a polygon.",
        params: .obj(["ref": .ref, "points": ShapeParse.pointsSchema], required: ["ref", "points"]),
        examples: [
            try! JSONValue.parse(#"{"ref":"item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01","points":[[100,290],[180,200],[260,290]]}"#),
            try! JSONValue.parse(#"{"ref":"item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01","points":[[0,0],[240,150]]}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, page, id) = try ShapeParse.item(p.ref, path: "$.ref")
        try ctx.mutate { tx in
            var item = try ShapeParse.shape(tx, doc, page, id, path: "$.ref")
            guard let old = item.shape else { return }
            let s = try ShapeGeometry.setPoints(old, p.points)
            try ShapeGeometry.validate(s, path: "$")
            item.shape = s
            let written = try tx.put(item, doc: doc, page: page)
            try ShapeParse.reanchorConnectors(tx, doc: doc, page: page, shape: written)
        }
        return NoResult()
    }
}

/// The tap handler behind "type inside a shape" (ARCHITECTURE §8.5): a tap on the selected shape, a double-tap on
/// any shape, or the inspector's Edit Text button opens the text editor over it. Commits go through `text.setText`.
struct ShapeTapAt: NibCommand {
    struct Params: Codable {
        var page: String?
        var point: [Double]?
        var ref: String?
        var gesture: String?
    }
    struct Output: Codable { var handled: Bool }

    static let descriptor = CommandDescriptor(
        id: "shape.tapAt", title: "Edit Shape Text",
        summary: "Tap handler: start typing inside the selected shape under a tap (double-tap selects and edits any "
            + "shape); returns {handled}.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str("how it was invoked", choices: ["tap", "doubleTap", "longPress", "button"])]),
        examples: [
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","point":[180,245],"ref":"item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01","gesture":"tap"}"#)
        ],
        effect: .session)

    static let textCommand = "text.setText"

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let gesture = p.gesture ?? "tap"
        guard gesture != "longPress", let session = ctx.activeSession, !session.readOnly,
              ctx.bus.registry.entry(textCommand) != nil,
              let found = try target(p, ctx: ctx, session: session) else { return Output(handled: false) }
        let (doc, page, item) = found
        guard let shape = item.shape, !item.locked else { return Output(handled: false) }
        let selected = session.selection.doc == doc && session.selection.page == page && session.selection.items == [item.id]
        switch gesture {
        case "tap":
            guard selected, !ShapeGeometry.isOpen(shape.shape) else { return Output(handled: false) }
        case "doubleTap":
            guard !ShapeGeometry.isOpen(shape.shape) else { return Output(handled: false) }
        default:
            break
        }
        guard session.document == doc, let overlay = ShapeEditOverlay.overlay(for: session) else { return Output(handled: false) }
        if !selected { session.selection = Selection(doc: doc, page: page, items: [item.id], bounds: item.bounds) }
        return Output(handled: overlay.beginTextEditing(doc: doc, page: page, id: item.id))
    }

    /// The shape to edit: `ref`, else the topmost shape under `point`, else the session's single selected item.
    static func target(_ p: Params, ctx: CommandContext, session: EditorSession) throws -> (DocumentID, PageID, Item)? {
        if let ref = p.ref {
            let (doc, page, id) = try ShapeParse.item(ref, path: "$.ref")
            guard let item = try? ctx.workspace.item(doc, page: page, id: id) else { return nil }
            return (doc, page, item)
        }
        if let pageRef = p.page, let xy = p.point, xy.count >= 2 {
            let (doc, page) = try ShapeParse.page(pageRef, path: "$.page")
            let at = Point(xy[0], xy[1])
            let hit = try ctx.workspace.items(doc, page: page).last(where: { item in
                item.shape.map { ShapeGeometry.hit($0, at: at, tolerance: 6) } ?? false
            })
            return hit.map { (doc, page, $0) }
        }
        let sel = session.selection
        guard sel.items.count == 1, let doc = sel.doc, let page = sel.page,
              let item = try? ctx.workspace.item(doc, page: page, id: sel.items[0]) else { return nil }
        return (doc, page, item)
    }
}

// MARK: - Containers

/// Shapes as containers (T-050): an item dropped fully inside a closed shape is attached to it (`attachedTo`), so it
/// moves with the shape; dropped outside, it is released. Pure planning; `ShapeContainerWatcher` applies it.
enum ShapeContainers {
    static let containerKinds: Set<ShapeKind> = [.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond, .polygon]
    /// Commands that land items on a page without moving an existing record (drops from elsewhere).
    static let dropCommands: Set<String> = [CommandIDs.itemMoveToPage, CommandIDs.clipboardPaste, "element.insert"]
    static let ignoredCommands: Set<String> = [CommandIDs.undo, CommandIDs.redo, CommandIDs.revertGroup]

    /// Items a user changeset moved (bounds changed) or dropped onto a page, per document and page.
    static func movedItems(_ cs: Changeset) -> [DocumentID: [PageID: [ElementID]]] {
        guard !ignoredCommands.contains(cs.command), !cs.command.hasPrefix("shape.") else { return [:] }
        var out: [DocumentID: [PageID: [ElementID]]] = [:]
        for m in cs.mutations {
            guard case let .item(doc, page, before, after) = m, !after.deleted else { continue }
            let moved: Bool
            if let b = before, !b.deleted {
                moved = b.bounds != after.bounds
            } else {
                moved = dropCommands.contains(cs.command)
            }
            if moved { out[doc, default: [:]][page, default: []].append(after.id) }
        }
        return out
    }

    struct Change: Equatable {
        let item: ElementID
        let parent: ElementID?
    }

    /// For each moved item: the smallest closed shape that now encloses it (nil = none). Only changes are returned,
    /// never a cycle, and items attached to something other than a shape (a comment on a sticky note) are left alone.
    static func plan(moved: [ElementID], items: [Item]) -> [Change] {
        let live = items.filter { !$0.deleted }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let containers = live.enumerated().compactMap { index, item -> (Item, ShapeItem, Double, Int)? in
            guard let s = item.shape, containerKinds.contains(s.shape) else { return nil }
            return (item, s, s.frame.w * s.frame.h, index)
        }
        var out: [Change] = []
        for id in moved {
            guard let item = byID[id], item.kind != .comment, item.kind != .connector else { continue }
            if let current = item.attachedTo, let parent = byID[current], parent.kind != .shape { continue }
            let box = item.bounds
            let parent = containers
                .filter { c in c.0.id != id && !isDescendant(c.0.id, of: id, byID) && ShapeGeometry.contains(c.1, box) }
                .min { a, b in a.2 != b.2 ? a.2 < b.2 : a.3 > b.3 }?.0.id
            if parent != item.attachedTo { out.append(Change(item: id, parent: parent)) }
        }
        return out
    }

    /// True when `candidate` hangs (directly or through other items) from `ancestor`.
    static func isDescendant(_ candidate: ElementID, of ancestor: ElementID, _ byID: [ElementID: Item]) -> Bool {
        var seen: Set<ElementID> = []
        var cur = byID[candidate]?.attachedTo
        while let p = cur, seen.insert(p).inserted {
            if p == ancestor { return true }
            cur = byID[p]?.attachedTo
        }
        return false
    }
}
