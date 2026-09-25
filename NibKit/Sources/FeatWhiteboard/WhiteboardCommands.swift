import Foundation
import UIKit
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
        for (name, value) in json["assets"]?.objectValue ?? [:] {
            guard let text = value.stringValue, let data = Data(base64Encoded: text) else {
                throw NibError(.invalidParams, "asset '\(name)' of the board template is not base64", path: "$.template")
            }
            assets[name] = data
        }
        try self.init(items: items, assets: assets)
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
        if let template = p.template { _ = try WhiteboardSupport.template(template, ctx) }
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

        guard let fragmentJSON = template.spec["fragment"] else {
            return try await insertDiagram(template, page: p.page, doc: doc, pageID: pageID, ids: ids,
                                           existing: existing, isBoard: isBoard, centre: centre, ctx: ctx)
        }
        let fragment = try BoardFragment(json: fragmentJSON)
        if isBoard { try BoardLimit.check(adding: fragment.items.count, to: existing.count) }
        var assets: [String: AssetRef] = [:]
        if !fragment.assets.isEmpty {
            let store = try ctx.services.require(ctx.services.assets, "the asset store")
            for (name, data) in fragment.assets {
                let ext = (name as NSString).pathExtension
                assets[name] = try store.put(data, ext: ext.isEmpty ? "png" : ext, doc: doc)
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

    /// A `diagram.create` spec (plugins' `diagram` templates): node ids are replaced by the caller's or fresh ones so
    /// inserting a template twice never overwrites the first copy, then F032 lays it out in this command's undo group.
    private static func insertDiagram(_ template: BoardTemplateDescriptor, page: String, doc: DocumentID, pageID: PageID,
                                      ids: [NibID], existing: [Item], isBoard: Bool,
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
        if isBoard { try BoardLimit.check(adding: nodes.count + edges.count, to: existing.count) }
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
        effect: .edit)

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
        let plan = NotebookLayout.boards(pages.map {
            PageSlotInput(id: $0.id, size: $0.size ?? .a4, rotation: $0.rotation, itemCount: items[$0.id]?.count ?? 0)
        })
        let slots = Dictionary(uniqueKeysWithValues: plan.joined().map { ($0.page, $0) })

        // Slow work before the transaction: each page's paper becomes a card (PDF pages are rendered to images).
        var cards: [PageID: Item] = [:]
        for (index, page) in pages.enumerated() {
            guard let slot = slots[page.id] else { continue }
            cards[page.id] = await PageCards.card(for: page, number: index + 1, frame: slot.frame, doc: doc, ctx: ctx)
        }

        let boards = try ctx.mutate { tx -> [PageID] in
            // Every record is written once in this command, so undo restores it exactly (a record written twice in one
            // undo group would only be reverted to its intermediate state).
            for page in pages {
                for item in items[page.id] ?? [] { try tx.delete(item: item.id, doc: doc, page: page.id) }
                var retired = page
                retired.deleted = true
                retired.trashedAt = nil
                try tx.put(retired, doc: doc)
            }
            var created: [PageID] = []
            var boardOf: [PageID: PageID] = [:]
            for (index, boardSlots) in plan.enumerated() {
                let board = try tx.put(PageRecord(order: "", size: nil, background: .ofTemplate(Whiteboard.dotsTemplate),
                                                  title: String(localized: "Board \(index + 1)")), doc: doc)
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
                    let pageItems = items[slot.page] ?? []
                    var remap: [ElementID: ElementID] = [:]
                    for item in pageItems where used.contains(item.id) { remap[item.id] = NibID.make() }
                    for item in pageItems {
                        var moved = item.transformed(by: slot.transform)
                        moved.id = remap[item.id] ?? item.id
                        moved.attachedTo = item.attachedTo.map { remap[$0] ?? $0 }
                        if var c = moved.connector {
                            c.from.item = c.from.item.map { remap[$0] ?? $0 }
                            c.to.item = c.to.item.map { remap[$0] ?? $0 }
                            moved.connector = c
                        }
                        moved.z = zs.popFirst() ?? ""
                        used.insert(moved.id)
                        try tx.put(moved, doc: doc, page: board.id)
                    }
                }
            }
            for clip in content.liveAudio {
                guard let page = clip.page, let board = boardOf[page] else { continue }
                var moved = clip
                moved.page = board
                try tx.put(moved, doc: doc)
            }
            var meta = try tx.content(doc).meta
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

/// The card a converted page leaves on its board, under its content: the page's image background as an image item, a
/// PDF page rendered to an image, otherwise a vector card drawn from the page's template (crisp at any zoom). Cards are
/// locked so writing over them never drags the paper.
@MainActor
enum PageCards {
    static func card(for page: PageRecord, number: Int, frame: Frame, doc: DocumentID, ctx: CommandContext) async -> Item {
        let title = page.title ?? String(localized: "Page \(number)")
        switch page.background.kind {
        case .image:
            if let asset = page.background.asset {
                return locked(.makeImage(ImageItem(frame: frame, asset: asset, altText: title)))
            }
        case .pdf:
            if let asset = await renderedPage(page, doc: doc, ctx: ctx) {
                return locked(.makeImage(ImageItem(frame: frame, asset: asset, altText: title)))
            }
        case .template, .color:
            break
        }
        let data: JSONValue = ["title": .string(title), "page": .string(page.id.raw),
                               "background": (try? JSONValue.from(page.background)) ?? .null]
        let custom = CustomItem(owner: FeatWhiteboardFeature.id, type: Whiteboard.pageCardType, frame: frame, data: data,
                                display: display(for: page.background, size: page.size ?? .a4,
                                                 templates: WhiteboardSupport.registries(ctx)?.templates))
        return locked(.makeCustom(custom))
    }

    /// Paper plus the template's own drawing, in the card's (unrotated page) coordinates. A PDF page that could not be
    /// rendered keeps its background in the card's data and shows plain paper.
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

    /// ponytail: 2 px per point is sharp at 100 % and soft past 200 %; a vector PDF item type is the upgrade path.
    private static func renderedPage(_ page: PageRecord, doc: DocumentID, ctx: CommandContext) async -> AssetRef? {
        guard let renderer = ctx.services.renderer, let assets = ctx.services.assets else { return nil }
        let request = RenderRequest(doc: doc, page: page.id, scale: 2, background: true, annotations: false)
        do {
            let result = try await renderer.render(request)
            guard let png = UIImage(cgImage: result.image).pngData() else { return nil }
            return try assets.put(png, ext: "png", doc: doc)
        } catch {
            Whiteboard.log.error("rendering page \(page.id.raw, privacy: .public) for the whiteboard failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func locked(_ item: Item) -> Item {
        var it = item
        it.locked = true
        return it
    }
}
