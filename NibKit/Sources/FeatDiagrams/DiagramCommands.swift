import Foundation
import NibContracts

// The four commands F032 owns. Every UI path (Quick Diagramming dots, the connector editor, object-menu entries)
// calls these, so plugins, the AI and the bridge can do exactly what a finger can.

// MARK: - Shared params

/// One connector end in command params: {item, side?, t?} attaches to an item, {point} is a free end. User calls
/// may also pass a bare item ref / id string or an [x, y] point.
struct EndParam: Codable, Equatable {
    var item: String?
    /// "top" | "right" | "bottom" | "left" | "auto" (0–3 accepted too); "auto" faces the other end.
    var side: String?
    var t: Double?
    var point: Point?

    init(item: String? = nil, side: String? = nil, t: Double? = nil, point: Point? = nil) {
        self.item = item
        self.side = side
        self.t = t
        self.point = point
    }

    enum CodingKeys: String, CodingKey { case item, side, t, point }

    init(from decoder: Decoder) throws {
        var item: String?
        var side: String?
        var t: Double?
        var point: Point?
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            item = s
        } else if let single = try? decoder.singleValueContainer(), let p = try? single.decode(Point.self) {
            point = p
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            item = try c.decodeIfPresent(String.self, forKey: .item)
            if let s = try? c.decodeIfPresent(String.self, forKey: .side) {
                side = s
            } else if let i = try? c.decodeIfPresent(Int.self, forKey: .side) {
                side = String(i)
            }
            t = try c.decodeIfPresent(Double.self, forKey: .t)
            point = try c.decodeIfPresent(Point.self, forKey: .point)
        }
        self.item = item
        self.side = side
        self.t = t
        self.point = point
    }

    /// JSON for UI callers.
    static func attached(_ id: ElementID, side: ConnectorSide? = nil, t: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["item": .string(id.raw)]
        if let s = side { o["side"] = .string(s.name) }
        if let t = t { o["t"] = .number(t) }
        return .object(o)
    }

    static func free(_ p: Point) -> JSONValue { ["point": .array([.number(p.x), .number(p.y)])] }
}

enum DiagramSchemas {
    static let sides = ConnectorSide.allCases.map { $0.name }
    static let boxShapes: [ShapeKind] = [.rectangle, .roundedRectangle, .ellipse, .triangle, .diamond]
    static let end: JSONSchema = .obj([
        "item": .str("item to attach to: item:D/P/I or its id (shapes, text boxes, images, sticky notes, maths, custom items)"),
        "side": .str("side of the item; auto (default) faces the other end", choices: sides + ["auto"]),
        "t": .num("position along the side, 0 to 1 (default 0.5, the middle)", min: 0, max: 1),
        "point": .point,
    ], required: [], "an attached end {item, side?, t?} or a free end {point}")
    static let id: JSONSchema = .str("your own id for the new item, [A-Za-z0-9_-]{1,64}")

    /// Longest label (characters) on a node or a connector: longer text belongs in a text box.
    static let maxLabel = 1000

    static func checkLabel(_ text: String?, path: String) throws {
        guard let text = text, text.count > maxLabel else { return }
        throw NibError(.invalidParams, "label is \(text.count) characters; at most \(maxLabel) fit", path: path,
                       hint: "shorten it, or put the long text in a text box next to the diagram")
    }
}

/// Resolving refs, ends and ids against the workspace, with errors that tell a model what to do next.
@MainActor
enum DiagramRefs {
    static func page(_ ref: String, in ws: Workspace, path: String) throws -> (DocumentID, PageID, PageRecord) {
        guard case let .page(doc, pid)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path,
                           hint: "query.context returns the current page ref")
        }
        guard let rec = try ws.content(doc).page(pid), !rec.deleted else { throw NibError.notFound("page \(pid) in document \(doc)") }
        return (doc, pid, rec)
    }

    static func itemRef(_ ref: String, path: String) throws -> (DocumentID, PageID, ElementID) {
        guard case let .item(doc, page, id)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: path,
                           hint: "query.get {\"ref\": \"page:D/P\"} lists the items of a page")
        }
        return (doc, page, id)
    }

    /// An item on `page` named by a ref or a bare id.
    static func item(_ ref: String, doc: DocumentID, page: PageID, in ws: Workspace, path: String) throws -> Item {
        let id: ElementID
        if let r = NodeRef(ref) {
            guard case let .item(d, p, i) = r else {
                throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: path)
            }
            guard d == doc, p == page else {
                throw NibError(.invalidParams, "item \(i) is not on page \(page)", path: path,
                               hint: "a connector joins items on its own page")
            }
            id = i
        } else {
            guard NibID.isValid(ref) else { throw NibError(.invalidParams, "'\(ref)' is not an item ref or id", path: path) }
            id = NibID(ref)
        }
        do {
            return try ws.item(doc, page: page, id: id)
        } catch {
            throw NibError(.notFound, "item \(id) not found on page \(page)", path: path)
        }
    }

    /// nil = auto.
    static func parseSide(_ s: String?, path: String) throws -> ConnectorSide? {
        guard let s = s, s.lowercased() != "auto" else { return nil }
        if let side = ConnectorSide(name: s) { return side }
        if let i = Int(s), let side = ConnectorSide(rawValue: i) { return side }
        throw NibError(.invalidParams, "side must be top, right, bottom, left or auto", path: path)
    }

    /// A new end from params: attached to an item with a frame, or free at a point.
    static func end(_ e: EndParam, doc: DocumentID, page: PageID, in ws: Workspace, path: String) throws -> ConnectorEndSpec {
        let side = try parseSide(e.side, path: path + ".side")
        let t = try position(e.t, path: path + ".t")
        if let ref = e.item {
            let it = try item(ref, doc: doc, page: page, in: ws, path: path + ".item")
            guard Anchoring.canAnchor(it) else {
                throw NibError(.invalidParams, "item \(it.id) (\(it.kind.rawValue)) has no frame to attach to", path: path + ".item",
                               hint: "attach to shapes, text boxes, images, sticky notes, maths or custom items, or give a point")
            }
            return .attached(it, side: side, t: t ?? 0.5)
        }
        guard let p = e.point else {
            throw NibError(.invalidParams, "a connector end needs an item or a point", path: path,
                           hint: "use {\"item\": \"item:D/P/I\"} or {\"point\": [x, y]}")
        }
        guard p.x.isFinite, p.y.isFinite else { throw NibError(.invalidParams, "point must be finite", path: path + ".point") }
        return .free(p)
    }

    /// An end of an existing connector after an edit. No param keeps it (anchored ends are re-read from their item,
    /// which may have moved); only side/t adjusts the current attachment; item/point re-anchors or frees it.
    static func edited(_ e: EndParam?, current: ConnectorEnd, doc: DocumentID, page: PageID, in ws: Workspace,
                       path: String) throws -> ConnectorEndSpec {
        let attachedItem = current.item.flatMap { try? ws.item(doc, page: page, id: $0) }
        let currentSide = current.side.flatMap { ConnectorSide(rawValue: $0) }
        guard let e = e else {
            guard let it = attachedItem else { return .free(current.point) }
            return .attached(it, side: currentSide, t: current.t ?? 0.5)
        }
        if e.item != nil || e.point != nil { return try end(e, doc: doc, page: page, in: ws, path: path) }
        guard let it = attachedItem else {
            throw NibError(.invalidParams, "this end is not attached to an item", path: path,
                           hint: "pass item to attach it, or point to move it")
        }
        var side = currentSide
        if e.side != nil { side = try parseSide(e.side, path: path + ".side") }
        let t = try position(e.t, path: path + ".t") ?? current.t ?? 0.5
        return .attached(it, side: side, t: t)
    }

    static func position(_ t: Double?, path: String) throws -> Double? {
        guard let t = t else { return nil }
        guard t.isFinite, (0...1).contains(t) else { throw NibError(.invalidParams, "t must be between 0 and 1", path: path) }
        return t
    }

    /// A caller-chosen id (valid and not live on the page), or a fresh one.
    static func newID(_ raw: String?, doc: DocumentID, page: PageID, in ws: Workspace, path: String) throws -> ElementID {
        guard let raw = raw else { return NibID.make() }
        guard NibID.isValid(raw) else { throw NibError(.invalidParams, "id must be 1–64 characters of [A-Za-z0-9_-]", path: path) }
        let id = NibID(raw)
        if try ws.items(doc, page: page).contains(where: { $0.id == id }) {
            throw NibError(.invalidParams, "id \(raw) is already used on this page", path: path, hint: "choose another id or leave it out")
        }
        return id
    }
}

// MARK: - connector.create

struct ConnectorCreate: NibCommand {
    struct Params: Codable {
        var page: String
        var from: EndParam
        var to: EndParam
        var route: ConnectorRoute?
        var arrowStart: Bool?
        var arrowEnd: Bool?
        var label: RichText?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "connector.create", title: "Connect",
        summary: "Connect two items or points with a straight, elbow or curved connector; from/to are {item, side?, t?} (side top|right|bottom|left, auto if omitted) or {point}.",
        params: .obj([
            "page": .ref,
            "from": DiagramSchemas.end,
            "to": DiagramSchemas.end,
            "route": .str("straight (default), elbow (right angles) or curved", choices: ConnectorRoute.allCases.map { $0.rawValue }),
            "arrowStart": .bool("arrowhead at the start (default false)"),
            "arrowEnd": .bool("arrowhead at the end (default true)"),
            "label": .str("text shown on the middle of the connector (at most 1000 characters)"),
            "id": DiagramSchemas.id,
        ], required: ["page", "from", "to"]),
        examples: [
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "from": {"item": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "side": "bottom"}, "to": {"item": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"}, "route": "elbow", "label": "explains"}"#),
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC04/FIXTUREBRD01", "from": {"item": "FIXTUREBSH01"}, "to": {"point": [320, 60]}, "route": "curved", "arrowStart": true}"#),
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ws = ctx.workspace
        let (doc, page, _) = try DiagramRefs.page(p.page, in: ws, path: "$.page")
        try DiagramSchemas.checkLabel(p.label?.plainText, path: "$.label")
        let newID = try DiagramRefs.newID(p.id, doc: doc, page: page, in: ws, path: "$.id")
        let from = try DiagramRefs.end(p.from, doc: doc, page: page, in: ws, path: "$.from")
        let to = try DiagramRefs.end(p.to, doc: doc, page: page, in: ws, path: "$.to")
        let (f, t) = Anchoring.ends(from, to)
        let label = p.label.flatMap { $0.isEmpty ? nil : $0 }
        let style = ShapeItemStyle(arrowStart: p.arrowStart ?? false, arrowEnd: p.arrowEnd ?? true)
        var item = Item.makeConnector(ConnectorItem(from: f, to: t, route: p.route ?? .straight, style: style, label: label),
                                      layer: ctx.activeSession?.activeLayer ?? 0)
        item.id = newID
        let stored = try ctx.mutate { (tx: DocTransaction) -> Item in try tx.put(item, doc: doc, page: page) }
        return Output(ref: NodeRef.item(doc, page, stored.id).description)
    }
}

// MARK: - connector.setPath

struct ConnectorSetPath: NibCommand {
    struct Params: Codable {
        var ref: String
        var route: ConnectorRoute?
        var bends: [Point]?
        var from: EndParam?
        var to: EndParam?
    }

    static let maxBends = ConnectorRouter.maxBends

    static let descriptor = CommandDescriptor(
        id: "connector.setPath", title: "Edit Connector",
        summary: "Reroute a connector: route straight|elbow|curved, bends (the full list of [x,y] waypoints; [] removes them), or re-anchor from/to ({side} switches side).",
        params: .obj([
            "ref": .ref,
            "route": .str("straight, elbow or curved (changing it clears bends unless bends is given)",
                          choices: ConnectorRoute.allCases.map { $0.rawValue }),
            "bends": .arr(.point, "every bend / control point in order, in page points"),
            "from": DiagramSchemas.end,
            "to": DiagramSchemas.end,
        ], required: ["ref"]),
        examples: [
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01", "route": "elbow"}"#),
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01", "route": "straight", "bends": [[330, 150]], "to": {"side": "top"}}"#),
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let ws = ctx.workspace
        let (doc, page, id) = try DiagramRefs.itemRef(p.ref, path: "$.ref")
        var item = try DiagramRefs.item(p.ref, doc: doc, page: page, in: ws, path: "$.ref")
        guard var c = item.connector else {
            throw NibError(.invalidParams, "item \(id) is a \(item.kind.rawValue), not a connector", path: "$.ref")
        }
        guard !item.locked else {
            throw NibError(.invalidParams, "connector \(id) is locked", path: "$.ref", hint: "unlock it with item.setLocked first")
        }
        if let r = p.route, r != c.route {
            c.route = r
            if p.bends == nil { c.bends = [] }
        }
        if let bends = p.bends {
            guard bends.count <= maxBends else { throw NibError(.invalidParams, "at most \(maxBends) bends", path: "$.bends") }
            if let i = bends.firstIndex(where: { !$0.x.isFinite || !$0.y.isFinite }) {
                throw NibError(.invalidParams, "bend must be finite", path: "$.bends[\(i)]")
            }
            c.bends = bends
        }
        let from = try DiagramRefs.edited(p.from, current: c.from, doc: doc, page: page, in: ws, path: "$.from")
        let to = try DiagramRefs.edited(p.to, current: c.to, doc: doc, page: page, in: ws, path: "$.to")
        (c.from, c.to) = Anchoring.ends(from, to)
        item.connector = c
        try ctx.mutate { (tx: DocTransaction) -> Void in _ = try tx.put(item, doc: doc, page: page) }
        return NoResult()
    }
}

// MARK: - diagram.addConnected

struct DiagramAddConnected: NibCommand {
    struct Params: Codable {
        var ref: String
        var side: String
        var shape: ShapeKind?
        var id: String?
    }

    struct Output: Codable {
        /// The new shape.
        var ref: String
        var connector: String
    }

    /// Items that never block Quick Diagramming's placement (ink, connectors, comment pins).
    static let passThrough: Set<ItemKind> = [.stroke, .connector, .comment]

    static let descriptor = CommandDescriptor(
        id: "diagram.addConnected", title: "Add Connected Shape",
        summary: "Quick Diagramming: add a shape beside a shape (side top|right|bottom|left) joined to it by a connector; copies its kind, size and style unless shape is given.",
        params: .obj([
            "ref": .ref,
            "side": .str("which side the new shape goes on", choices: DiagramSchemas.sides),
            "shape": .str("kind of the new shape (default: the source's)", choices: DiagramSchemas.boxShapes.map { $0.rawValue }),
            "id": DiagramSchemas.id,
        ], required: ["ref", "side"]),
        examples: [
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "side": "bottom"}"#),
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01", "side": "right", "shape": "diamond"}"#),
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ws = ctx.workspace
        let (doc, page, _) = try DiagramRefs.itemRef(p.ref, path: "$.ref")
        let source = try DiagramRefs.item(p.ref, doc: doc, page: page, in: ws, path: "$.ref")
        guard Anchoring.canAnchor(source), let frame = source.frame else {
            throw NibError(.invalidParams, "item \(source.id) (\(source.kind.rawValue)) has no frame to connect from", path: "$.ref")
        }
        guard let side = try DiagramRefs.parseSide(p.side, path: "$.side") else {
            throw NibError(.invalidParams, "side must be top, right, bottom or left", path: "$.side")
        }
        let sourceKind = source.shape.map { $0.shape }.flatMap { DiagramSchemas.boxShapes.contains($0) ? $0 : nil }
        let kind = p.shape ?? sourceKind ?? .roundedRectangle
        guard DiagramSchemas.boxShapes.contains(kind) else {
            throw NibError(.invalidParams, "shape must be one of \(DiagramSchemas.boxShapes.map { $0.rawValue }.joined(separator: ", "))",
                           path: "$.shape")
        }
        let newID = try DiagramRefs.newID(p.id, doc: doc, page: page, in: ws, path: "$.id")
        let (_, _, pageRecord) = try DiagramRefs.page(NodeRef.page(doc, page).description, in: ws, path: "$.ref")
        let obstacles = try ws.items(doc, page: page)
            .filter { $0.id != source.id && !passThrough.contains($0.kind) }
            .map { $0.bounds }
        guard let rect = DiagramLayout.placeConnected(source: frame.bounds, size: NodeBox(w: frame.w, h: frame.h),
                                                      side: side, obstacles: obstacles, page: pageRecord.size) else {
            throw NibError(.invalidParams, "no room for a shape on the \(side.name) of item \(source.id) on this page",
                           path: "$.side", hint: "try another side, or move the shape further onto the page")
        }
        let layer = ctx.activeSession?.activeLayer ?? 0
        var style = source.shape?.style ?? ShapeItemStyle()
        style.arrowStart = false
        style.arrowEnd = false
        var shape = Item.makeShape(ShapeItem(shape: kind, frame: Frame(rect), style: style), layer: layer)
        shape.id = newID
        let (f, t) = Anchoring.ends(.attached(source, side: side), .attached(shape))
        let connectorStyle = ShapeItemStyle(strokeColor: style.strokeColor ?? .black, strokeWidth: max(1, style.strokeWidth),
                                            arrowEnd: true)
        let connector = Item.makeConnector(ConnectorItem(from: f, to: t, route: .straight, style: connectorStyle), layer: layer)
        try ctx.mutate { (tx: DocTransaction) -> Void in
            try tx.put(shape, doc: doc, page: page)
            try tx.put(connector, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, shape.id).description,
                      connector: NodeRef.item(doc, page, connector.id).description)
    }
}

// MARK: - diagram.create

/// The three looks of a generated diagram. Colours come from Nib's ink palette (DESIGN.md §3.4): ink is content,
/// never themed.
enum DiagramStyle: String, Codable, CaseIterable {
    case classic, gray, line

    struct Look {
        var stroke: RGBA?
        var fill: RGBA?
        var text: RGBA
        var width: Double
    }

    static let branchInks: [NibInk] = [.cobalt, .lagoon, .moss, .ochre, .plum, .vermilion, .sienna, .crimson]

    static func rgba(_ ink: NibInk) -> RGBA {
        RGBA(UInt8((ink.hex >> 16) & 0xFF), UInt8((ink.hex >> 8) & 0xFF), UInt8(ink.hex & 0xFF))
    }

    func look(depth: Int, branch: Int, layout: DiagramLayoutKind, color: RGBA?) -> Look {
        let text = DiagramStyle.rgba(.carbon)
        switch self {
        case .classic:
            let hierarchical = layout == .tree || layout == .mindmap
            let base: RGBA
            if let c = color {
                base = c
            } else if hierarchical && depth == 0 {
                base = DiagramStyle.rgba(.carbon)
            } else if hierarchical {
                base = DiagramStyle.rgba(DiagramStyle.branchInks[max(0, branch) % DiagramStyle.branchInks.count])
            } else {
                base = DiagramStyle.rgba(.cobalt)
            }
            return Look(stroke: base, fill: base.withAlpha(depth == 0 && hierarchical ? 0.16 : 0.12), text: text, width: 1.5)
        case .gray:
            let base = color ?? DiagramStyle.rgba(.graphite)
            return Look(stroke: base, fill: base.withAlpha(depth == 0 ? 0.2 : 0.1), text: text, width: 1.5)
        case .line:
            return Look(stroke: color ?? DiagramStyle.rgba(.carbon), fill: nil, text: text, width: 1.5)
        }
    }

    var connectorInk: RGBA { self == .line ? DiagramStyle.rgba(.carbon) : DiagramStyle.rgba(.graphite) }
}

enum DiagramBuilder {
    static let margin = 36.0
    static let minScale = 0.35
    static let fontSize = 15.0
    static let rootFontSize = 17.0

    static func route(for layout: DiagramLayoutKind) -> ConnectorRoute {
        switch layout {
        case .tree, .flow: return .elbow
        case .timeline: return .straight
        case .mindmap: return .curved
        }
    }

    /// Flows and timelines read in a direction; trees and mind maps are hierarchies without arrowheads.
    static func arrows(for layout: DiagramLayoutKind) -> Bool { layout == .flow || layout == .timeline }

    /// Shrinks a diagram that is larger than a fixed-size page (never below `minScale`); boards never scale.
    static func fitScale(_ size: NodeBox, page: PageSize?) -> Double {
        guard let p = page, size.w > 0, size.h > 0 else { return 1 }
        let s = min(1, (p.width - 2 * margin) / size.w, (p.height - 2 * margin) / size.h)
        return max(minScale, s)
    }

    /// A laid-out diagram, the scale it is drawn at, and whether it then fits inside the page's margins.
    struct Arrangement {
        var result: DiagramLayoutResult
        var scale: Double
        var fits: Bool
    }

    /// Lays a diagram out for its page. A board (no fixed size) takes any size at scale 1. On a fixed-size page the
    /// diagram shrinks to fit (never below `minScale`), and a timeline also wraps into rows: the row widths that
    /// scales 1, 0.75, 0.5 and `minScale` leave are tried, and the arrangement that fits at the largest scale wins.
    /// Pure and value-typed, so `diagram.create` runs it off the main actor.
    static func arrange(_ boxes: [NodeBox], edges: [(Int, Int)], kind: DiagramLayoutKind, page: PageSize?) -> Arrangement {
        guard let p = page else {
            return Arrangement(result: DiagramLayout.layout(boxes, edges: edges, kind: kind), scale: 1, fits: true)
        }
        let usable = NodeBox(w: p.width - 2 * margin, h: p.height - 2 * margin)
        func fitted(_ r: DiagramLayoutResult) -> Arrangement {
            let s = fitScale(r.size, page: p)
            return Arrangement(result: r, scale: s, fits: r.size.w * s <= usable.w + 1e-6 && r.size.h * s <= usable.h + 1e-6)
        }
        var best = fitted(DiagramLayout.layout(boxes, edges: edges, kind: kind))
        guard kind == .timeline, !(best.fits && best.scale >= 1), usable.w > 0 else { return best }
        for target in [1.0, 0.75, 0.5, minScale] {
            let wrapped = fitted(DiagramLayout.layout(boxes, edges: edges, kind: kind, maxWidth: usable.w / target))
            if wrapped.fits && (!best.fits || wrapped.scale > best.scale + 1e-9) { best = wrapped }
        }
        return best
    }

    /// Top-left for a diagram of `size`: centred in the visible area (or the page), kept inside a fixed-size page.
    static func origin(for size: NodeBox, page: PageSize?, visible: Rect?) -> Point {
        let centre = visible?.center ?? page.map { Point($0.width / 2, $0.height / 2) } ?? .zero
        var o = Point(centre.x - size.w / 2, centre.y - size.h / 2)
        if let p = page {
            o.x = min(max(margin, o.x), max(margin, p.width - margin - size.w))
            o.y = min(max(margin, o.y), max(margin, p.height - margin - size.h))
        }
        return o
    }

    static func text(_ s: String, size: Double, color: RGBA) -> RichText? {
        guard !s.isEmpty else { return nil }
        var rt = RichText(plain: s, attrs: TextAttributes(size: size, color: color))
        for i in rt.paragraphs.indices { rt.paragraphs[i].align = .center }
        return rt
    }

    /// Item ids for the nodes: `ids` first (they must be valid and free), then each node's own id when it is a valid
    /// id not yet used on the page, else a fresh id.
    static func itemIDs(nodeIDs: [String], overrides: [String]?, taken: Set<ElementID>) throws -> [ElementID] {
        if let o = overrides, o.count > nodeIDs.count {
            throw NibError(.invalidParams, "ids has \(o.count) entries for \(nodeIDs.count) nodes", path: "$.ids")
        }
        var used = taken
        var out: [ElementID] = []
        for (i, raw) in nodeIDs.enumerated() {
            if let o = overrides, i < o.count {
                guard NibID.isValid(o[i]) else {
                    throw NibError(.invalidParams, "id must be 1–64 characters of [A-Za-z0-9_-]", path: "$.ids[\(i)]")
                }
                let id = NibID(o[i])
                guard !used.contains(id) else {
                    throw NibError(.invalidParams, "id \(o[i]) is already used", path: "$.ids[\(i)]", hint: "choose another id")
                }
                used.insert(id)
                out.append(id)
            } else if NibID.isValid(raw), !used.contains(NibID(raw)) {
                used.insert(NibID(raw))
                out.append(NibID(raw))
            } else {
                var id = NibID.make()
                while used.contains(id) { id = NibID.make() }
                used.insert(id)
                out.append(id)
            }
        }
        return out
    }
}

struct DiagramCreate: NibCommand {
    struct Node: Codable {
        var id: String
        var label: String?
        var shape: ShapeKind?
        var color: RGBA?
    }

    struct Edge: Codable {
        var from: String
        var to: String
        var label: String?
    }

    struct Params: Codable {
        var page: String
        var nodes: [Node]
        var edges: [Edge]?
        var layout: DiagramLayoutKind
        var style: DiagramStyle?
        var origin: Point?
        var ids: [String]?
    }

    struct Output: Codable {
        /// The node shapes, in node order.
        var refs: [String]
        /// The connectors, in edge order.
        var connectors: [String]
    }

    /// Caps that keep the layout (off the main actor) well under a second even for a tangled flow.
    static let maxNodes = 200
    static let maxEdges = 600

    static let descriptor = CommandDescriptor(
        id: "diagram.create", title: "Create Diagram",
        summary: "Create an editable diagram of shapes and connectors: layout tree|flow|timeline|mindmap, style classic|gray|line; nodes [{id, label}], edges [{from, to}] by node id.",
        params: .obj([
            "page": .ref,
            "nodes": .arr(.obj([
                "id": .str("node id, used by edges; becomes the item id when it is free on the page"),
                "label": .str("text in the box (at most 1000 characters)"),
                "shape": .str("box shape (default roundedRectangle)", choices: DiagramSchemas.boxShapes.map { $0.rawValue }),
                "color": .color,
            ], required: ["id"]), "the boxes, in order (at most 200)"),
            "edges": .arr(.obj([
                "from": .str("node id"),
                "to": .str("node id"),
                "label": .str("text on the connector (at most 1000 characters)"),
            ], required: ["from", "to"]), "connectors between nodes (at most 600); a timeline with none is chained in node order"),
            "layout": .str("tree: top-down hierarchy, flow: layered flowchart, timeline: left to right (wraps into rows on a fixed-size page), mindmap: radial",
                           choices: DiagramLayoutKind.allCases.map { $0.rawValue }),
            "style": .str("classic (colour, default), gray or line (outlines only)", choices: DiagramStyle.allCases.map { $0.rawValue }),
            "origin": .point,
            "ids": .arr(.str(), "item ids for the nodes in node order (override the node ids)"),
        ], required: ["page", "nodes", "edges", "layout"]),
        examples: [
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "mindmap", "nodes": [{"id": "n1", "label": "Kinematics"}, {"id": "n2", "label": "SUVAT"}, {"id": "n3", "label": "Graphs"}], "edges": [{"from": "n1", "to": "n2"}, {"from": "n1", "to": "n3", "label": "shows"}]}"#),
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC04/FIXTUREBRD01", "layout": "flow", "style": "gray", "origin": [0, 200], "nodes": [{"id": "start", "label": "Start", "shape": "ellipse"}, {"id": "check", "label": "Units consistent?", "shape": "diamond"}, {"id": "solve", "label": "Solve"}], "edges": [{"from": "start", "to": "check"}, {"from": "check", "to": "solve", "label": "yes"}]}"#),
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ws = ctx.workspace
        let (doc, page, before) = try DiagramRefs.page(p.page, in: ws, path: "$.page")
        let nodes = p.nodes
        let n = nodes.count
        guard n > 0 else { throw NibError(.invalidParams, "nodes is empty", path: "$.nodes") }
        guard n <= maxNodes else {
            throw NibError(.invalidParams, "at most \(maxNodes) nodes", path: "$.nodes", hint: "split it into several diagrams")
        }
        let edges = p.edges ?? []
        guard edges.count <= maxEdges else {
            throw NibError(.invalidParams, "at most \(maxEdges) edges", path: "$.edges", hint: "split it into several diagrams")
        }
        if let o = p.origin, !o.x.isFinite || !o.y.isFinite {
            throw NibError(.invalidParams, "origin must be finite", path: "$.origin")
        }

        var index: [String: Int] = [:]
        for (i, node) in nodes.enumerated() {
            guard !node.id.isEmpty else { throw NibError(.invalidParams, "node id is empty", path: "$.nodes[\(i)].id") }
            guard index[node.id] == nil else {
                throw NibError(.invalidParams, "duplicate node id '\(node.id)'", path: "$.nodes[\(i)].id")
            }
            if let s = node.shape, !DiagramSchemas.boxShapes.contains(s) {
                throw NibError(.invalidParams, "shape must be one of \(DiagramSchemas.boxShapes.map { $0.rawValue }.joined(separator: ", "))",
                               path: "$.nodes[\(i)].shape")
            }
            try DiagramSchemas.checkLabel(node.label, path: "$.nodes[\(i)].label")
            index[node.id] = i
        }
        var pairs: [(Int, Int)] = []
        var edgeLabels: [String?] = []
        for (i, e) in edges.enumerated() {
            guard let u = index[e.from] else {
                throw NibError(.invalidParams, "edge \(i) starts at unknown node '\(e.from)'", path: "$.edges[\(i)].from",
                               hint: "from and to are ids from nodes[].id")
            }
            guard let v = index[e.to] else {
                throw NibError(.invalidParams, "edge \(i) ends at unknown node '\(e.to)'", path: "$.edges[\(i)].to",
                               hint: "from and to are ids from nodes[].id")
            }
            guard u != v else { throw NibError(.invalidParams, "edge \(i) joins a node to itself", path: "$.edges[\(i)]") }
            try DiagramSchemas.checkLabel(e.label, path: "$.edges[\(i)].label")
            pairs.append((u, v))
            edgeLabels.append(e.label)
        }
        if pairs.isEmpty && p.layout == .timeline && n > 1 {
            pairs = (1..<n).map { ($0 - 1, $0) }
            edgeLabels = [String?](repeating: nil, count: n - 1)
        }
        // Bad ids fail before the layout runs.
        _ = try DiagramBuilder.itemIDs(nodeIDs: nodes.map { $0.id }, overrides: p.ids,
                                       taken: Set(ws.items(doc, page: page).map { $0.id }))

        var isRoot = [Bool](repeating: false, count: n)
        if p.layout == .tree || p.layout == .mindmap {
            let roots = DiagramLayout.spanningForest(count: n, edges: pairs).roots
            for r in (p.layout == .mindmap ? Array(roots.prefix(1)) : roots) { isRoot[r] = true }
        }
        let labels = nodes.map { $0.label ?? "" }
        let fonts = isRoot.map { $0 ? DiagramBuilder.rootFontSize : DiagramBuilder.fontSize }
        let boxes = (0..<n).map { DiagramLayout.nodeBox(label: labels[$0], fontSize: fonts[$0]) }

        // The layout is pure value work that grows fast with the graph: off the main actor (ARCHITECTURE §14).
        let edgePairs = pairs
        let kind = p.layout
        let pageSize = before.size
        let arranged = await Task.detached(priority: .userInitiated) {
            DiagramBuilder.arrange(boxes, edges: edgePairs, kind: kind, page: pageSize)
        }.value

        // The document may have changed during the await: resolve the page and the free ids again.
        let (_, _, pageRecord) = try DiagramRefs.page(p.page, in: ws, path: "$.page")
        guard pageRecord.size == pageSize else {
            throw NibError(.conflict, "the page changed size while the diagram was laid out", path: "$.page",
                           hint: "run diagram.create again")
        }
        let taken = try Set(ws.items(doc, page: page).map { $0.id })
        let ids = try DiagramBuilder.itemIDs(nodeIDs: nodes.map { $0.id }, overrides: p.ids, taken: taken)

        let result = arranged.result
        let s = arranged.scale
        let placed = NodeBox(w: result.size.w * s, h: result.size.h * s)
        if let size = pageRecord.size {
            // Nothing may land off a fixed-size page: off-page items never render and the lasso cannot reach them.
            if let o = p.origin {
                guard o.x >= 0, o.y >= 0, o.x + placed.w <= size.width + 1e-6, o.y + placed.h <= size.height + 1e-6 else {
                    throw NibError(.invalidParams,
                                   "the diagram (\(Int(placed.w.rounded())) × \(Int(placed.h.rounded())) pt) does not fit on the page at this origin",
                                   path: "$.origin", hint: "leave origin out to centre it on the page, or use a whiteboard page")
                }
            } else if !arranged.fits {
                throw NibError(.invalidParams, "diagram is too large for this page", path: "$.nodes",
                               hint: "use a whiteboard page, split it into smaller diagrams, or try the mindmap layout")
            }
        }
        let session = ctx.activeSession
        let visible = session?.document == doc && session?.page == page ? session?.visibleRect : nil
        let o = p.origin ?? DiagramBuilder.origin(for: placed, page: pageRecord.size, visible: visible)
        func place(_ q: Point) -> Point { Point(o.x + q.x * s, o.y + q.y * s) }

        let style = p.style ?? .classic
        let layer = session?.activeLayer ?? 0
        var shapes: [Item] = []
        for i in 0..<n {
            let f = result.frames[i]
            let frame = Frame(x: o.x + f.x * s, y: o.y + f.y * s, w: f.width * s, h: f.height * s)
            let look = style.look(depth: result.depth[i], branch: result.branch[i], layout: p.layout, color: nodes[i].color)
            let radius = p.layout == .mindmap ? frame.h / 2 : 10 * s
            let shapeStyle = ShapeItemStyle(strokeColor: look.stroke, strokeWidth: look.width, fillColor: look.fill, cornerRadius: radius)
            var item = Item.makeShape(ShapeItem(shape: nodes[i].shape ?? .roundedRectangle, frame: frame, style: shapeStyle,
                                                text: DiagramBuilder.text(labels[i], size: fonts[i] * s, color: look.text)),
                                      layer: layer)
            item.id = ids[i]
            shapes.append(item)
        }
        var connectors: [Item] = []
        for (k, pair) in pairs.enumerated() {
            let route = result.edges[k]
            let ends = Anchoring.ends(.attached(shapes[pair.0], side: route.fromSide), .attached(shapes[pair.1], side: route.toSide))
            let label = edgeLabels[k].flatMap { $0.isEmpty ? nil : RichText(plain: $0) }
            let connector = ConnectorItem(from: ends.0, to: ends.1, route: DiagramBuilder.route(for: p.layout),
                                          bends: route.bends.map(place),
                                          style: ShapeItemStyle(strokeColor: style.connectorInk, strokeWidth: 1.5,
                                                                arrowEnd: DiagramBuilder.arrows(for: p.layout)),
                                          label: label)
            connectors.append(Item.makeConnector(connector, layer: layer))
        }
        try ctx.mutate { (tx: DocTransaction) -> Void in
            for item in shapes { try tx.put(item, doc: doc, page: page) }
            for item in connectors { try tx.put(item, doc: doc, page: page) }
        }
        return Output(refs: shapes.map { NodeRef.item(doc, page, $0.id).description },
                      connectors: connectors.map { NodeRef.item(doc, page, $0.id).description })
    }
}
