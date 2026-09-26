import Foundation
import UIKit
import ImageIO
import os
import NibContracts

// MARK: - Shared names

/// Names shared by the whiteboard files.
enum Whiteboard {
    static let log = Logger(subsystem: "app.nib", category: "whiteboard")
    /// `app.content`, handed to the commands through `NibServices` (a `CommandContext` has no `NibApp`), so each app
    /// (two-device tests) resolves its own template registries.
    static let contentKey = "whiteboard.content"
    /// Minimap map shown on this device (the zoom controls always are).
    static let minimapVisible = SettingKey("whiteboard.minimap", default: true)
    /// Background of new and converted boards (F005's zoom-adaptive dot grid).
    static let dotsTemplate = "builtin.whiteboardDots"
    /// Gap between notebook pages laid out on a board, and between a template and a board's existing content.
    static let gap = 48.0
    /// `CustomItem.type` of the page cards a converted notebook leaves under each page's content.
    static let pageCardType = "page"

    static let boardsPanel = "whiteboard.boards"
    static let templatesPanel = "whiteboard.templates"
    static let createPanel = "whiteboard.create"
    /// The New Whiteboard key command (⇧⌘W in the library).
    static let newWhiteboardKey = "whiteboard.new"
}

extension RGBA {
    /// A palette colour (inks, highlighters, papers) as model data.
    init(_ colour: NibHexColour, alpha: Double = 1) {
        self.init(rgb: colour.hex, alpha: alpha)
    }

    /// 0xRRGGBB (the palette tables' rule and margin colours).
    init(rgb: UInt32, alpha: Double = 1) {
        self.init(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
        self = withAlpha(alpha)
    }
}

// MARK: - Board limit (D-030)

enum BoardLimitStatus: Equatable {
    case ok
    /// At or past 80 % of the limit; the fraction used.
    case warning(Double)
    case full
}

enum BoardLimit {
    static let warningFraction = 0.8

    static func status(count: Int, limit: Int = NibLimits.boardItemLimit) -> BoardLimitStatus {
        guard limit > 0, count < limit else { return .full }
        let fraction = Double(count) / Double(limit)
        return fraction >= warningFraction ? .warning(fraction) : .ok
    }

    /// Blocks an insertion that would take a board past the limit, naming the remedies.
    static func check(adding n: Int, to count: Int, limit: Int = NibLimits.boardItemLimit) throws {
        guard count + n > limit else { return }
        throw NibError(.unsupported, "this board would hold \(count + n) items; a board holds at most \(limit)",
                       hint: "add a board with board.add and insert there, move items to another board with "
                           + "item.moveToPage, or delete items")
    }
}

// MARK: - Placing a template fragment

/// A clipboard-format fragment ({format: "nib-fragment/1", items, assets: {name: base64}, bounds}) as a board template
/// carries it.
struct BoardFragment {
    var items: [Item]
    var assets: [String: Data]
    /// Union of the items' bounds (the JSON `bounds` may include margins; the placement centres the content itself).
    var bounds: Rect

    /// Plugin and content-pack fragments are untrusted: each asset and all of them together are capped, and only
    /// image and PDF files are stored.
    static let maxAssetBytes = 20 * 1024 * 1024
    static let maxTotalAssetBytes = 50 * 1024 * 1024
    static let assetExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "pdf"]

    init(items: [Item], assets: [String: Data] = [:]) throws {
        let live = items.filter { !$0.deleted }
        guard let bounds = TemplatePlacement.union(live) else {
            throw NibError(.invalidParams, "the board template has no items", path: "$.template")
        }
        self.items = live
        self.assets = assets
        self.bounds = bounds
    }

    init(json: JSONValue) throws {
        guard let list = json["items"] else {
            throw NibError(.invalidParams, "the board template fragment has no items", path: "$.template")
        }
        let items: [Item]
        do {
            items = try list.decode([Item].self)
        } catch {
            throw NibError(.invalidParams, "the board template fragment has malformed items: \(error.localizedDescription)",
                           path: "$.template")
        }
        var assets: [String: Data] = [:]
        var total = 0
        for (name, value) in json["assets"]?.objectValue ?? [:] {
            let ext = Self.assetExtension(name)
            guard Self.assetExtensions.contains(ext) else {
                throw NibError(.invalidParams, "asset '\(name)' of the board template is not an image or PDF file",
                               path: "$.template", hint: "name assets with one of: "
                                   + Self.assetExtensions.sorted().joined(separator: ", "))
            }
            guard let text = value.stringValue else {
                throw NibError(.invalidParams, "asset '\(name)' of the board template is not base64", path: "$.template")
            }
            // Refuse before decoding: base64 is 4 characters per 3 bytes.
            guard text.utf8.count / 4 * 3 <= Self.maxAssetBytes + 3, let data = Data(base64Encoded: text),
                  data.count <= Self.maxAssetBytes else {
                throw NibError(.invalidParams, "asset '\(name)' of the board template is not base64 or is larger than "
                                   + "\(Self.maxAssetBytes / 1_048_576) MB", path: "$.template")
            }
            total += data.count
            guard total <= Self.maxTotalAssetBytes else {
                throw NibError(.invalidParams, "the board template's assets are larger than "
                                   + "\(Self.maxTotalAssetBytes / 1_048_576) MB together", path: "$.template")
            }
            assets[name] = data
        }
        try self.init(items: items, assets: assets)
    }

    /// The lower-cased file extension of an asset name ("logo.PNG" → "png").
    static func assetExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}

enum TemplatePlacement {
    static func union(_ items: [Item]) -> Rect? {
        var out: Rect?
        for item in items { out = out.map { $0.union(item.bounds) } ?? item.bounds }
        return out
    }

    /// The fragment's items ready to put: caller ids first (then fresh ones) with every internal reference remapped
    /// (attachments, connector anchors, image assets), moved so their bounds centre on `centre`, on `layer`, stacked
    /// above `zAbove` in fragment order. References to items outside the fragment are dropped so the page stays valid.
    static func place(_ fragment: BoardFragment, centre: Point, ids: [NibID], layer: Int, zAbove: String?,
                      assets: [String: AssetRef] = [:]) -> [Item] {
        var map: [ElementID: ElementID] = [:]
        for (i, item) in fragment.items.enumerated() { map[item.id] = i < ids.count ? ids[i] : NibID.make() }
        let delta = centre - fragment.bounds.center
        let move = Affine.translation(delta.x, delta.y)
        let zs = FractionalIndex.sequence(after: zAbove, count: fragment.items.count)
        func end(_ e: ConnectorEnd) -> ConnectorEnd {
            var out = e
            out.item = e.item.flatMap { map[$0] }
            if out.item == nil {
                out.side = nil
                out.t = nil
            }
            return out
        }
        return fragment.items.enumerated().map { i, source in
            var it = source.transformed(by: move)
            it.id = map[source.id] ?? NibID.make()
            it.rev = .zero
            it.deleted = false
            it.createdBy = nil
            it.z = zs[i]
            it.layer = layer
            it.attachedTo = source.attachedTo.flatMap { map[$0] }
            if var c = it.connector {
                c.from = end(c.from)
                c.to = end(c.to)
                it.connector = c
            }
            if var image = it.image, let ref = assets[image.asset.name] {
                image.asset = ref
                it.image = image
            }
            return it
        }
    }

    /// Where a template goes when nobody is looking at the board: the origin of an empty board, else to the right of
    /// what is already there, so it never lands on existing content.
    static func defaultCentre(content: Rect?, templateSize: (width: Double, height: Double)) -> Point {
        guard let c = content, c.width > 0 || c.height > 0 else { return .zero }
        return Point(c.maxX + Whiteboard.gap + templateSize.width / 2, c.midY)
    }

    /// A rough footprint of a `diagram.create` spec, so its origin puts the laid-out diagram near the centre.
    /// ponytail: diagram.create owns the layout and reports no geometry up front; if its footprint differs, the
    /// diagram lands off-centre by that difference (re-centring after it ran would write every item twice in one undo
    /// group, which undo cannot revert). A dry-run geometry answer from diagram.create is the upgrade path.
    static func estimatedSize(nodes: Int, layout: String) -> (width: Double, height: Double) {
        let n = Double(max(nodes, 1))
        let node = (w: 180.0, h: 72.0, gap: 48.0)
        switch layout {
        case "timeline":
            return (n * (node.w + node.gap), node.h * 2 + node.gap)
        case "mindmap":
            let side = min(n, 8) * (node.h + node.gap)
            return (2 * node.w + 2 * node.gap + side, side)
        default:  // tree, flow: roughly square layers
            let columns = max(1, n.squareRoot().rounded(.up))
            let rows = (n / columns).rounded(.up)
            return (columns * (node.w + node.gap), rows * (node.h + node.gap) * 1.4)
        }
    }
}

// MARK: - Notebook → whiteboard layout (D-033)

struct PageSlotInput {
    var id: PageID
    var size: PageSize
    var rotation: Int
    var itemCount: Int
}

struct PageSlot {
    var page: PageID
    /// Page coordinates → board coordinates (rotation baked in).
    var transform: Affine
    /// The page's own box on the board (rotated with the page).
    var frame: Frame
}

enum NotebookLayout {
    /// Pages side by side, left to right, tops aligned at y 0, `gap` apart. A board takes pages until the next one
    /// would pass `limit` items (each page also adds its card), then a new board starts; a page larger than the
    /// limit still gets a board of its own.
    static func boards(_ pages: [PageSlotInput], gap: Double = Whiteboard.gap,
                       limit: Int = NibLimits.boardItemLimit) -> [[PageSlot]] {
        var out: [[PageSlot]] = []
        var current: [PageSlot] = []
        var count = 0
        var x = 0.0
        for page in pages {
            let cost = page.itemCount + 1
            if !current.isEmpty && count + cost > limit {
                out.append(current)
                current = []
                count = 0
                x = 0
            }
            let placed = transform(size: page.size, rotation: page.rotation, x: x)
            let frame = Frame(x: 0, y: 0, w: page.size.width, h: page.size.height).applying(placed.transform)
            current.append(PageSlot(page: page.id, transform: placed.transform, frame: frame))
            count += cost
            x += placed.width + gap
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Rotates the page clockwise by `rotation` degrees about its origin, then moves its rotated box to (x, 0).
    static func transform(size: PageSize, rotation: Int, x: Double) -> (transform: Affine, width: Double) {
        let turn = Affine.rotation(Double(rotation) * .pi / 180)
        let corners = [Point(0, 0), Point(size.width, 0), Point(size.width, size.height), Point(0, size.height)]
        let box = Rect.bounding(corners.map { turn.apply($0) })
            ?? Rect(x: 0, y: 0, width: size.width, height: size.height)
        return (turn.concatenating(.translation(x - box.x, -box.y)), box.width)
    }
}

// MARK: - Command support

@MainActor
enum WhiteboardSupport {
    static func registries(_ ctx: CommandContext) -> ContentRegistries? {
        ctx.services.get(Whiteboard.contentKey, as: ContentRegistries.self)
    }

    static func template(_ id: String, _ ctx: CommandContext) throws -> BoardTemplateDescriptor {
        guard let registry = registries(ctx)?.boardTemplates else { throw NibError.unavailable("board templates") }
        guard let d = registry.get(id) else {
            let known = registry.all.map(\.id).prefix(30).joined(separator: ", ")
            throw NibError(.notFound, "unknown board template '\(id)'", path: "$.template",
                           hint: known.isEmpty ? "no board templates are installed" : "available templates: \(known)")
        }
        return d
    }

    static func pageRef(_ ref: String, path: String) throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a board ref like page:D/P", path: path,
                           hint: "boards are the pages of a whiteboard; call query.get {ref: \"doc:D\"} to list them")
        }
        return (doc, page)
    }

    static func requireWhiteboard(_ content: DocumentContent, path: String) throws {
        guard content.meta.kind == .whiteboard else {
            throw NibError(.invalidParams, "\(content.meta.id) is a \(content.meta.kind.rawValue), not a whiteboard",
                           path: path, hint: "board commands work on whiteboards; use page.* for notebooks, or "
                               + "doc.convertToWhiteboard first")
        }
    }

    static func liveBoard(_ content: DocumentContent, _ page: PageID) throws -> PageRecord {
        guard let p = content.page(page), !p.deleted else { throw NibError.notFound("board \(page)") }
        return p
    }

    static func validIDs(_ ids: [String]?, path: String) throws -> [NibID] {
        var seen = Set<String>()
        return try (ids ?? []).enumerated().map { i, raw in
            guard NibID.isValid(raw), seen.insert(raw).inserted else {
                throw NibError.invalid("ids must be distinct, 1–64 of [A-Za-z0-9_-]", path: "\(path)[\(i)]")
            }
            return NibID(raw)
        }
    }

    /// The centre of what a window shows of this page right now: the invoking window first, then any other.
    static func visibleCentre(doc: DocumentID, page: PageID, ctx: CommandContext) -> Point? {
        let candidates = [ctx.activeSession].compactMap { $0 } + ctx.services.sessions.sessions
        for s in candidates where s.document == doc && s.page == page {
            if let r = s.visibleRect, !r.isEmpty { return r.center }
        }
        return nil
    }

    /// Background of a new board: the last board's (pattern and colour carry over), else the document default.
    static func newBoardBackground(_ content: DocumentContent) -> Background {
        if let last = content.livePages.last { return last.background }
        return .ofTemplate(content.meta.defaultTemplate?.id ?? Whiteboard.dotsTemplate,
                           params: content.meta.defaultTemplate?.params ?? [:])
    }
}

// MARK: - board.add

struct BoardAdd: NibCommand {
    struct Params: Codable {
        /// Required for AI, plugins and the bridge (schema); the user's keyboard shortcut passes none and gets the
        /// active window's whiteboard.
        var doc: String?
        var title: String?
        var template: String?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
        /// Items of the template inserted on the new board.
        var items: [String]?
    }

    static let examples: [JSONValue] = [
        ["doc": "doc:FIXTUREDOC04"],
        ["doc": "doc:FIXTUREDOC04", "title": "Sprint plan", "template": "whiteboard.kanban"]
    ]

    static let descriptor = CommandDescriptor(
        id: "board.add", title: "Add Board",
        summary: "Add a board to a whiteboard after the last one (same background); optional title and a board template "
            + "to start it with (see board.insertTemplate).",
        params: .obj(["doc": .ref,
                      "title": .str("board name; default 'Board N'"),
                      "template": .str("board template id, e.g. 'whiteboard.kanban'"),
                      "id": .str("your own id for the new board, [A-Za-z0-9_-]{1,64}")],
                     required: ["doc"]),
        examples: examples, effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc: DocumentID
        if let raw = p.doc {
            doc = NodeRef.documentID(from: raw)
        } else if let active = ctx.activeSession?.document {
            doc = active
        } else {
            throw NibError(.invalidParams, "missing required field 'doc'", path: "$.doc", hint: "pass doc:D of a whiteboard")
        }
        if let id = p.id, !NibID.isValid(id) { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let title = p.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template = p.template {
            // Everything that could make the insertion fail is checked before the board exists, so a refused template
            // never leaves an empty board behind (and a retry never adds a second one).
            let plan = try BoardInsertTemplate.plan(WhiteboardSupport.template(template, ctx), ctx: ctx)
            try BoardLimit.check(adding: plan.itemCount, to: 0)
        }
        let board = try ctx.mutate { tx -> PageRecord in
            let content = try tx.content(doc)
            try WhiteboardSupport.requireWhiteboard(content, path: "$.doc")
            if let id = p.id, content.page(NibID(id)) != nil {
                throw NibError.invalid("a board or page with id \(id) already exists", path: "$.id")
            }
            let name = (title?.isEmpty == false ? title : nil)
                ?? String(localized: "Board \(content.livePages.count + 1)")
            let record = PageRecord(id: p.id.map { NibID($0) } ?? NibID.make(), order: "", size: nil,
                                    background: WhiteboardSupport.newBoardBackground(content),
                                    title: String(name.prefix(200)))
            return try tx.put(record, doc: doc)
        }
        let ref = NodeRef.page(doc, board.id).description
        var items: [String]?
        if let template = p.template {
            let inserted = try await ctx.execute(BoardInsertTemplate.self,
                                                 BoardInsertTemplate.Params(page: ref, template: template))
            items = inserted.refs
        }
        return Output(ref: ref, items: items)
    }
}

// MARK: - board.rename

struct BoardRename: NibCommand {
    struct Params: Codable {
        var page: String
        var title: String
    }

    struct Output: Codable {
        var ref: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "board.rename", title: "Rename Board",
        summary: "Rename a whiteboard board (the name shown in the Boards sidebar and on exports).",
        params: .obj(["page": .ref, "title": .str("new board name")], required: ["page", "title"]),
        examples: [["page": "page:FIXTUREDOC04/FIXTUREBRD01", "title": "Roadmap"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, pageID) = try WhiteboardSupport.pageRef(p.page, path: "$.page")
        let title = String(p.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !title.isEmpty else { throw NibError.invalid("a board name cannot be empty", path: "$.title") }
        try ctx.mutate { tx in
            let content = try tx.content(doc)
            try WhiteboardSupport.requireWhiteboard(content, path: "$.page")
            var board = try WhiteboardSupport.liveBoard(content, pageID)
            guard board.title != title else { return }
            board.title = title
            try tx.put(board, doc: doc)
        }
        return Output(ref: p.page, title: title)
    }
}

// MARK: - board.insertTemplate

struct BoardInsertTemplate: NibCommand {
    struct Params: Codable {
        var page: String
        var template: String
        var at: [Double]?
        var ids: [String]?

        init(page: String, template: String, at: [Double]? = nil, ids: [String]? = nil) {
            self.page = page
            self.template = template
            self.at = at
            self.ids = ids
        }
    }

    struct Output: Codable {
        var refs: [String]
        var template: String
    }

    static let examples: [JSONValue] = [
        ["page": "page:FIXTUREDOC04/FIXTUREBRD01", "template": "whiteboard.swot"],
        ["page": "page:FIXTUREDOC04/FIXTUREBRD01", "template": "whiteboard.mindMap", "at": [400, 300]]
    ]

    static let descriptor = CommandDescriptor(
        id: "board.insertTemplate", title: "Insert Board Template",
        summary: "Insert a whiteboard framework (brainstorm, kanban, swot, retro, mindMap, timeline, meeting, flowchart "
            + "or a plugin one) centred on at, else on the visible centre.",
        params: .obj(["page": .ref,
                      "template": .str("board template id: whiteboard.brainstorm, whiteboard.kanban, whiteboard.swot, "
                          + "whiteboard.retro, whiteboard.mindMap, whiteboard.timeline, whiteboard.meeting, "
                          + "whiteboard.flowchart, or a plugin template id"),
                      "at": .point,
                      "ids": .arr(.str("your own item id, [A-Za-z0-9_-]{1,64}"), "ids for the created items, in order")],
                     required: ["page", "template"]),
        examples: examples, effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, pageID) = try WhiteboardSupport.pageRef(p.page, path: "$.page")
        let template = try WhiteboardSupport.template(p.template, ctx)
        if let at = p.at, at.count != 2 { throw NibError.invalid("at must be [x, y]", path: "$.at") }
        let ids = try WhiteboardSupport.validIDs(p.ids, path: "$.ids")
        let content = try ctx.workspace.content(doc)
        let page = try WhiteboardSupport.liveBoard(content, pageID)
        let existing = try ctx.workspace.items(doc, page: pageID)
        let isBoard = page.size == nil
        if let clash = ids.first(where: { id in existing.contains { $0.id == id } }) {
            throw NibError.invalid("item id \(clash) is already used on this page", path: "$.ids")
        }
        func centre(for size: (width: Double, height: Double)) -> Point {
            if let at = p.at { return Point(at[0], at[1]) }
            if let visible = WhiteboardSupport.visibleCentre(doc: doc, page: pageID, ctx: ctx) { return visible }
            if let paper = page.size { return Point(paper.width / 2, paper.height / 2) }
            return TemplatePlacement.defaultCentre(content: TemplatePlacement.union(existing), templateSize: size)
        }

        let insertion = try Self.plan(template, ctx: ctx)
        if isBoard { try BoardLimit.check(adding: insertion.itemCount, to: existing.count) }
        guard case let .fragment(fragment) = insertion else {
            return try await insertDiagram(template, page: p.page, doc: doc, pageID: pageID, ids: ids,
                                           existing: existing, centre: centre, ctx: ctx)
        }
        var assets: [String: AssetRef] = [:]
        if !fragment.assets.isEmpty {
            let store = try ctx.services.require(ctx.services.assets, "the asset store")
            for (name, data) in fragment.assets {
                assets[name] = try store.put(data, ext: BoardFragment.assetExtension(name), doc: doc)
            }
        }
        let target = centre(for: (fragment.bounds.width, fragment.bounds.height))
        let layer = ctx.activeSession?.activeLayer ?? 0
        let refs = try ctx.mutate { tx -> [String] in
            let zAbove = try ctx.workspace.allItems(doc, page: pageID).last?.z
            let placed = TemplatePlacement.place(fragment, centre: target, ids: ids, layer: layer, zAbove: zAbove,
                                                 assets: assets)
            for item in placed { try tx.put(item, doc: doc, page: pageID) }
            return placed.map { NodeRef.item(doc, pageID, $0.id).description }
        }
        return Output(refs: refs, template: template.id)
    }

    /// What a board template inserts, checked before anything is written.
    enum Plan {
        case fragment(BoardFragment)
        case diagram(nodes: Int, edges: Int)

        /// Items the insertion adds to the board (a diagram adds a shape per node and a connector per edge).
        var itemCount: Int {
            switch self {
            case let .fragment(fragment): return fragment.items.count
            case let .diagram(nodes, edges): return nodes + edges
            }
        }
    }

    /// Parses a template's spec: a fragment (built-ins, plugins, content packs) or a `diagram.create` spec, which needs
    /// the Diagrams feature installed.
    static func plan(_ template: BoardTemplateDescriptor, ctx: CommandContext) throws -> Plan {
        if let fragment = template.spec["fragment"] { return .fragment(try BoardFragment(json: fragment)) }
        guard case let .object(params) = template.spec, let nodes = params["nodes"]?.arrayValue else {
            throw NibError(.invalidParams, "board template '\(template.id)' is neither a fragment nor a diagram spec",
                           path: "$.template")
        }
        guard ctx.bus.registry.descriptor(CommandIDs.diagramCreate) != nil else {
            throw NibError(.unavailable, "board template '\(template.id)' is a diagram, and \(CommandIDs.diagramCreate) "
                               + "is not installed", path: "$.template",
                           hint: "pick a template whose spec is a fragment, e.g. whiteboard.mindMap")
        }
        return .diagram(nodes: nodes.count, edges: params["edges"]?.arrayValue?.count ?? 0)
    }

    /// A `diagram.create` spec (plugins' `diagram` templates): node ids are replaced by the caller's or fresh ones so
    /// inserting a template twice never overwrites the first copy, then F032 lays it out in this command's undo group.
    private static func insertDiagram(_ template: BoardTemplateDescriptor, page: String, doc: DocumentID, pageID: PageID,
                                      ids: [NibID], existing: [Item],
                                      centre: @MainActor ((width: Double, height: Double)) -> Point,
                                      ctx: CommandContext) async throws -> Output {
        guard case .object(var params) = template.spec, let nodes = params["nodes"]?.arrayValue else {
            throw NibError(.invalidParams, "board template '\(template.id)' is neither a fragment nor a diagram spec",
                           path: "$.template")
        }
        let edges = params["edges"]?.arrayValue ?? []
        var map: [String: String] = [:]
        let remapped: [JSONValue] = nodes.enumerated().map { i, node in
            guard case .object(var o) = node else { return node }
            let fresh = i < ids.count ? ids[i].raw : NibID.make().raw
            if let old = o["id"]?.stringValue { map[old] = fresh }
            o["id"] = .string(fresh)
            return .object(o)
        }
        params["nodes"] = .array(remapped)
        params["edges"] = .array(edges.map { edge in
            guard case .object(var o) = edge else { return edge }
            for key in ["from", "to"] {
                if let old = o[key]?.stringValue, let fresh = map[old] { o[key] = .string(fresh) }
            }
            return .object(o)
        })
        params["ids"] = .array(remapped.compactMap { $0["id"] })
        params["page"] = .string(page)
        let size = TemplatePlacement.estimatedSize(nodes: nodes.count, layout: params["layout"]?.stringValue ?? "tree")
        let target = centre(size)
        params["origin"] = .array([.number(target.x - size.width / 2), .number(target.y - size.height / 2)])
        let before = Set(existing.map(\.id))
        _ = try await ctx.execute(CommandIDs.diagramCreate, .object(params))
        let created = try ctx.workspace.items(doc, page: pageID).filter { !before.contains($0.id) }
        return Output(refs: created.map { NodeRef.item(doc, pageID, $0.id).description }, template: template.id)
    }
}

// MARK: - doc.convertToWhiteboard

struct DocConvertToWhiteboard: NibCommand {
    struct Params: Codable {
        var doc: String
    }

    struct Output: Codable {
        var doc: String
        /// The new boards (one unless the notebook holds more than a board's item limit).
        var boards: [String]
        var pages: Int
    }

    static let descriptor = CommandDescriptor(
        id: "doc.convertToWhiteboard", title: "Convert to Whiteboard",
        summary: "Convert a notebook into a whiteboard: its pages are laid out side by side on one board, each page's "
            + "paper kept as a locked card under its content.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let content = try ctx.workspace.content(doc)
        guard content.meta.kind == .notebook else {
            throw NibError(.invalidParams, "only notebooks can become whiteboards; \(doc) is a \(content.meta.kind.rawValue)",
                           path: "$.doc")
        }
        let pages = content.livePages
        guard !pages.isEmpty else { throw NibError.invalid("the notebook has no pages to convert", path: "$.doc") }
        var items: [PageID: [Item]] = [:]
        for page in pages { items[page.id] = try ctx.workspace.items(doc, page: page.id) }
        let snapshot = ConversionSnapshot(pages: pages, items: items)
        let plan = NotebookLayout.boards(pages.map {
            PageSlotInput(id: $0.id, size: $0.size ?? .a4, rotation: $0.rotation, itemCount: items[$0.id]?.count ?? 0)
        })
        let slots = Dictionary(uniqueKeysWithValues: plan.joined().map { ($0.page, $0) })

        // Slow work before the transaction: each page's paper becomes a card. PDF pages are rendered to images one at a
        // time, off the main actor; a page that cannot be rendered stops the conversion before anything is written.
        let templates = WhiteboardSupport.registries(ctx)?.templates
        var cards: [PageID: Item] = [:]
        var pdfURLs: [String: URL] = [:]
        for (index, page) in pages.enumerated() {
            guard let slot = slots[page.id] else { continue }
            var raster: AssetRef?
            if page.background.kind == .pdf {
                raster = try await PageCards.rasterisePDFPage(page, number: index + 1, doc: doc, ctx: ctx, urls: &pdfURLs)
            }
            cards[page.id] = PageCards.card(for: page, number: index + 1, frame: slot.frame, raster: raster,
                                            templates: templates)
        }

        let boards = try ctx.mutate { tx -> [PageID] in
            // The rendering above awaited: a sync merge or another window may have written meanwhile. Converting the
            // stale snapshot would tombstone those edits, so the notebook must still be exactly what was read.
            let fresh = try tx.content(doc)
            var current: [PageID: [Item]] = [:]
            for page in fresh.livePages { current[page.id] = try tx.items(doc, page: page.id) }
            guard fresh.meta.kind == .notebook, ConversionSnapshot(pages: fresh.livePages, items: current) == snapshot else {
                throw NibError(.conflict, "the notebook changed while converting, so it was left as it is", path: "$.doc",
                               hint: "run doc.convertToWhiteboard again")
            }
            // Every record is written once in this command, so undo restores it exactly (a record written twice in one
            // undo group would only be reverted to its intermediate state).
            for page in pages {
                for item in items[page.id] ?? [] { try tx.delete(item: item.id, doc: doc, page: page.id) }
                var retired = page
                retired.deleted = true
                retired.trashedAt = nil
                try tx.put(retired, doc: doc)
            }
            let bookmarked = Set(pages.filter(\.bookmarked).map(\.id))
            var created: [PageID] = []
            var boardOf: [PageID: PageID] = [:]
            for (index, boardSlots) in plan.enumerated() {
                var record = PageRecord(order: "", size: nil, background: .ofTemplate(Whiteboard.dotsTemplate),
                                        title: String(localized: "Board \(index + 1)"))
                record.bookmarked = boardSlots.contains { bookmarked.contains($0.page) }
                let board = try tx.put(record, doc: doc)
                created.append(board.id)
                let count = boardSlots.reduce(0) { $0 + 1 + (items[$1.page]?.count ?? 0) }
                var zs = FractionalIndex.sequence(after: nil, count: count)[...]
                var used = Set<ElementID>()
                for slot in boardSlots {
                    boardOf[slot.page] = board.id
                    if var card = cards[slot.page] {
                        card.z = zs.popFirst() ?? ""
                        used.insert(card.id)
                        try tx.put(card, doc: doc, page: board.id)
                    }
                    for moved in NotebookLayout.rehome(items[slot.page] ?? [], transform: slot.transform, used: &used) {
                        var item = moved
                        item.z = zs.popFirst() ?? ""
                        try tx.put(item, doc: doc, page: board.id)
                    }
                }
            }
            // Recordings, outline entries and bookmarks follow their pages onto the boards.
            for clip in fresh.liveAudio {
                guard let page = clip.page, let board = boardOf[page] else { continue }
                var moved = clip
                moved.page = board
                try tx.put(moved, doc: doc)
            }
            for entry in fresh.liveOutline {
                guard let page = entry.page, let board = boardOf[page] else { continue }
                var moved = entry
                moved.page = board
                try tx.put(moved, doc: doc)
            }
            var meta = fresh.meta
            meta.kind = .whiteboard
            meta.coverEnabled = false
            meta.defaultTemplate = TemplateRef(Whiteboard.dotsTemplate)
            try tx.putMeta(meta)
            return created
        }
        return Output(doc: NodeRef.document(doc).description,
                      boards: boards.map { NodeRef.page(doc, $0).description }, pages: pages.count)
    }
}

/// What a conversion read before its slow work (the page cards): the live pages in order and every item's revision.
/// The transaction compares it with the notebook as it is then.
struct ConversionSnapshot: Equatable {
    var pages: [PageID]
    var pageRevs: [Rev]
    var items: [PageID: [ElementID: Rev]]

    init(pages: [PageRecord], items: [PageID: [Item]]) {
        self.pages = pages.map(\.id)
        pageRevs = pages.map(\.rev)
        var revs: [PageID: [ElementID: Rev]] = [:]
        for page in pages {
            revs[page.id] = Dictionary((items[page.id] ?? []).map { ($0.id, $0.rev) }, uniquingKeysWith: { first, _ in first })
        }
        self.items = revs
    }
}

extension NotebookLayout {
    /// A page's items moved onto its board slot. An id already used on the board (the cards, earlier pages) gets a
    /// fresh one, and the page's own attachments and connector anchors follow the new id.
    static func rehome(_ items: [Item], transform: Affine, used: inout Set<ElementID>) -> [Item] {
        var remap: [ElementID: ElementID] = [:]
        for item in items where used.contains(item.id) { remap[item.id] = NibID.make() }
        return items.map { item in
            var moved = item.transformed(by: transform)
            moved.id = remap[item.id] ?? item.id
            moved.attachedTo = item.attachedTo.map { remap[$0] ?? $0 }
            if var c = moved.connector {
                c.from.item = c.from.item.map { remap[$0] ?? $0 }
                c.to.item = c.to.item.map { remap[$0] ?? $0 }
                moved.connector = c
            }
            used.insert(moved.id)
            return moved
        }
    }
}

/// The card a converted page leaves on its board, under its content: the page's image background as an image item, a
/// PDF page rendered to an image, otherwise a vector card drawn from the page's template (crisp at any zoom). Cards are
/// locked so writing over them never drags the paper.
@MainActor
enum PageCards {
    /// Pixels per point of a rendered PDF page.
    /// ponytail: 2 px per point is sharp at 100 % and soft past 200 %; a vector PDF item type is the upgrade path.
    static let pdfScale = 2.0

    /// `raster` is the rendered page of a `.pdf` background (see `rasterisePDFPage`).
    static func card(for page: PageRecord, number: Int, frame: Frame, raster: AssetRef?,
                     templates: Registry<TemplateDefinition>?) -> Item {
        let title = page.title ?? String(localized: "Page \(number)")
        if let raster {
            return locked(.makeImage(ImageItem(frame: frame, asset: raster, altText: title)))
        }
        if page.background.kind == .image, let asset = page.background.asset {
            return locked(.makeImage(ImageItem(frame: frame, asset: asset, altText: title)))
        }
        let data: JSONValue = ["title": .string(title), "page": .string(page.id.raw),
                               "background": (try? JSONValue.from(page.background)) ?? .null]
        let custom = CustomItem(owner: FeatWhiteboardFeature.id, type: Whiteboard.pageCardType, frame: frame, data: data,
                                display: display(for: page.background, size: page.size ?? .a4, templates: templates))
        return locked(.makeCustom(custom))
    }

    /// Paper plus the template's own drawing, in the card's (unrotated page) coordinates.
    static func display(for background: Background, size: PageSize, templates: Registry<TemplateDefinition>?) -> DisplayList {
        var paper = RGBA.white
        var ops: [DisplayOp] = []
        switch background.kind {
        case .color:
            paper = background.color ?? .white
        case .template:
            if let ref = background.template, let definition = templates?.get(ref.id) {
                let params = definition.defaults.merging(ref.params) { _, new in new }
                let render = definition.render(params, size, 2)
                paper = render.paper
                ops = render.display.ops
            }
        case .pdf, .image:
            break
        }
        let sheet = DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: size.width, height: size.height),
                              stroke: RGBA(NibInk.graphite, alpha: 0.35), fill: paper, width: 0.5)
        return DisplayList(ops: [sheet] + ops)
    }

    /// Renders a PDF-backed page to a PNG asset: through the renderer service, else straight from the PDF with Core
    /// Graphics. Rendering and PNG encoding run off the main actor. A page neither can draw (damaged or locked PDF,
    /// missing asset) throws `unavailable`, so a conversion never trades a PDF page for blank paper.
    static func rasterisePDFPage(_ page: PageRecord, number: Int, doc: DocumentID, ctx: CommandContext,
                                 urls: inout [String: URL]) async throws -> AssetRef {
        let failure = NibError(.unavailable, "page \(number) of the PDF could not be rendered, so the notebook was not "
                                   + "converted", path: "$.doc",
                               hint: "check that the PDF opens in Nib (it may be damaged or password-protected), or move "
                                   + "that page out of the notebook and convert again")
        let assets = try ctx.services.require(ctx.services.assets, "the asset store")
        let size = page.size ?? .a4
        var png: Data?
        if let renderer = ctx.services.renderer {
            do {
                let request = RenderRequest(doc: doc, page: page.id, scale: pdfScale, background: true, annotations: false)
                let image = try await renderer.render(request).image
                png = await Task.detached(priority: .userInitiated) { PageRaster.png(image) }.value
            } catch {
                Whiteboard.log.error("rendering page \(page.id.raw, privacy: .public) for the whiteboard failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if png == nil, let ref = page.background.asset {
            if urls[ref.name] == nil { urls[ref.name] = assets.url(ref, doc: doc) }
            if let url = urls[ref.name] {
                let index = page.background.pdfPage ?? 0
                let scale = pdfScale
                png = await Task.detached(priority: .userInitiated) {
                    PageRaster.pdfPage(url: url, index: index, size: size, scale: scale).flatMap(PageRaster.png)
                }.value
            }
        }
        guard let png else { throw failure }
        do {
            return try assets.put(png, ext: "png", doc: doc)
        } catch {
            Whiteboard.log.error("storing page \(page.id.raw, privacy: .public) for the whiteboard failed: \(error.localizedDescription, privacy: .public)")
            throw failure
        }
    }

    private static func locked(_ item: Item) -> Item {
        var it = item
        it.locked = true
        return it
    }
}

/// Thread-safe raster helpers (Core Graphics and ImageIO only), run off the main actor.
enum PageRaster {
    /// Largest bitmap a converted page may take (a 100 000 pt page would otherwise ask for gigabytes).
    static let maxPixels = 16_000_000.0

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Page `index` (0-based) of the PDF at `url`, aspect-fitted on white into a page of `size` points at `scale`
    /// pixels per point, honouring the PDF page's own rotation. nil when the PDF cannot be opened or unlocked.
    static func pdfPage(url: URL, index: Int, size: PageSize, scale: Double) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") { return nil }
        guard index >= 0, let page = document.page(at: index + 1) else { return nil }
        let points = max(size.width * size.height, 1)
        let s = min(scale, (maxPixels / points).squareRoot())
        let width = max(1, Int((size.width * s).rounded())), height = max(1, Int((size.height * s).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
        let turned = angle == 90 || angle == 270
        let fit = min(CGFloat(width) / (turned ? box.height : box.width), CGFloat(height) / (turned ? box.width : box.height))
        // PDF space is y-up like a bitmap context; /Rotate turns the page clockwise as displayed.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.scaleBy(x: fit, y: fit)
        context.rotate(by: -CGFloat(angle) * .pi / 180)
        context.translateBy(x: -box.midX, y: -box.midY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
