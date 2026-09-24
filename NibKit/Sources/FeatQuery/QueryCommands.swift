import Foundation
import NibContracts

// MARK: - query.context

struct QueryContext: NibCommand {
    struct Params: Codable {
        var session: String?
    }

    static let descriptor = CommandDescriptor(
        id: "query.context", title: "Current Context",
        summary: "Where the user is: document, page, visible rect, tool, selection refs/kinds/bbox, active layer, read-only flag and open tabs.",
        params: .obj(["session": .str("window session id (default: the active window)")]),
        examples: [[:]], effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let session: EditorSession?
        if let id = p.session {
            guard let s = ctx.services.sessions.session(NibID(id)) else {
                throw NibError(.notFound, "session \(id) not found", path: "$.session", hint: "omit it for the active window")
            }
            session = s
        } else {
            session = ctx.activeSession
        }
        guard let s = session else { return .object(["session": .null, "tabs": .array([])]) }

        var o: [String: JSONValue] = ["session": .string(s.id.raw), "tool": .string(s.tool), "readOnly": .bool(s.readOnly),
                                      "activeLayer": .number(Double(s.activeLayer))]
        let navigator = Shapes.app(ctx)?.ui.activeNavigator
        let tabs = navigator.flatMap { $0.session === s ? $0.openDocuments : nil } ?? (s.document.map { [$0] } ?? [])
        o["tabs"] = .array(tabs.map { JSONValue.string(NodeRef.document($0).description) })
        o["selection"] = .object(["refs": .array([])])
        guard let doc = s.document else { return .object(o) }

        let docRef = NodeRef.document(doc).description
        if Shapes.hidden(doc, ctx) {
            o["document"] = .object(["ref": .string(docRef), "locked": .bool(true)])
            return .object(o)
        }
        let content = try ctx.workspace.content(doc)
        var d: [String: JSONValue] = ["ref": .string(docRef), "kind": .string(content.meta.kind.rawValue),
                                      "pageCount": .number(Double(content.livePages.count)),
                                      "locked": .bool(Shapes.isLocked(doc, ctx))]
        if let t = Shapes.title(doc, ctx) { d["title"] = .string(t) }
        o["document"] = .object(d)
        if let page = s.page, let rec = content.page(page) {
            var pg: [String: JSONValue] = ["ref": .string(NodeRef.page(doc, page).description), "size": Shapes.size(rec.size)]
            if let i = content.pageIndex(page) { pg["index"] = .number(Double(i)) }
            o["page"] = .object(pg)
        }
        if let r = s.visibleRect { o["visibleRect"] = Shapes.rect(r) }

        let sel = s.selection
        if !sel.isEmpty, let sd = sel.doc, let sp = sel.page, !Shapes.hidden(sd, ctx) {
            let chosen = ((try? ctx.workspace.items(sd, page: sp)) ?? []).filter { sel.items.contains($0.id) }
            let bbox = sel.bounds ?? chosen.map { $0.bounds }.reduce(nil as Rect?) { acc, r in acc?.union(r) ?? r }
            var so: [String: JSONValue] = [
                "refs": .array(sel.refs.map { JSONValue.string($0) }),
                "kinds": .array(Set(chosen.map { $0.kind.rawValue }).sorted().map { JSONValue.string($0) })
            ]
            if let b = bbox { so["bbox"] = Shapes.rect(b) }
            o["selection"] = .object(so)
        }
        return .object(o)
    }
}

// MARK: - query.tree

struct QueryTree: NibCommand {
    struct Params: Codable {
        var root: String?
        var depth: Int?
        var cursor: String?
    }

    static let descriptor = CommandDescriptor(
        id: "query.tree", title: "Library Tree",
        summary: "Library tree as flat rows (folders; documents with kind and page count; parent ref and depth) under lib or a folder, paged by cursor.",
        params: .obj(["root": .str("lib (default) or folder:F"), "depth": .int("levels below root (default: all)", min: 0, max: 16),
                      "cursor": .str("from the previous result")]),
        examples: [[:], ["root": "folder:FIXTUREFLD01", "depth": 1]], effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let root = try Shapes.folder(p.root ?? "lib", library, path: "$.root")
        let rows = Shapes.treeRows(library, root: root, depth: p.depth ?? NibLimits.maxNesting, ctx)
        let rootRef = root.map { NodeRef.folder($0).description } ?? "lib"
        let offset = try Shapes.offset(p.cursor)
        return Shapes.fill(["root": .string(rootRef)], key: "nodes", count: rows.count, offset: offset, limit: 500) { rows[$0] }
    }
}

// MARK: - query.get

struct QueryGet: NibCommand {
    struct Params: Codable {
        var ref: String
        var depth: Int?
        var fields: [String]?
        var points: Bool?
        var cursor: String?
    }

    static let descriptor = CommandDescriptor(
        id: "query.get", title: "Get Node",
        summary: "Any node (lib, folder, doc, page, item, block, card, audio, outline) as JSON; stroke points only with points=true; pages list items (≤200 + cursor).",
        params: .obj(["ref": .ref,
                      "depth": .int("0 = node only, 1 = child summaries (default), 2 = full child JSON", min: 0, max: 4),
                      "fields": .arr(.str(), "only these fields per row (e.g. ['ext','createdBy'])"),
                      "points": .bool("include stroke points (flat 'full' format, paged by cursor)"),
                      "cursor": .str("from the previous result")], required: ["ref"]),
        examples: [["ref": "page:FIXTUREDOC01/FIXTUREPG001"], ["ref": "doc:FIXTUREDOC02"],
                   ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "points": true]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let ref = try Shapes.ref(p.ref, path: "$.ref")
        let depth = max(0, p.depth ?? 1)
        let points = p.points ?? false
        let offset = try Shapes.offset(p.cursor)
        if let doc = ref.documentID, Shapes.hidden(doc, ctx) {
            return .object(["ref": .string(ref.description), "locked": .bool(true)])
        }
        switch ref {
        case .library, .folder:
            return try Shapes.libraryJSON(ref, depth: depth, offset: offset, ctx)
        case .document(let doc):
            return try Shapes.documentJSON(doc, depth: depth, fields: p.fields, points: points, offset: offset, ctx)
        case let .page(doc, page):
            return try Shapes.pageJSON(doc, page, depth: depth, fields: p.fields, points: points, offset: offset, ctx)
        case let .item(doc, page, id):
            return try itemJSON(ctx.workspace.item(doc, page: page, id: id), doc, page, p, offset: offset, ctx)
        case let .block(doc, id):
            guard let b = try ctx.workspace.content(doc).blocks.first(where: { $0.id == id && !$0.deleted }) else {
                throw NibError.notFound("block \(id) in document \(doc)")
            }
            return try Shapes.pick(Shapes.blockRow(b, doc), depth: 2, fields: p.fields) {
                var f = try Shapes.recordJSON(b, points: points)
                f["plainText"] = .string(b.text.plainText)
                return f
            }
        case let .card(doc, id):
            guard let c = try ctx.workspace.content(doc).cards.first(where: { $0.id == id && !$0.deleted }) else {
                throw NibError.notFound("card \(id) in document \(doc)")
            }
            return try Shapes.pick(Shapes.cardRow(c, doc), depth: 2, fields: p.fields) { try Shapes.recordJSON(c, points: points) }
        case let .audio(doc, id):
            guard let a = try ctx.workspace.content(doc).audio.first(where: { $0.id == id && !$0.deleted }) else {
                throw NibError.notFound("audio clip \(id) in document \(doc)")
            }
            return try Shapes.pick(Shapes.audioRow(a, doc), depth: 2, fields: p.fields) { try Shapes.recordJSON(a, points: false) }
        case let .outline(doc, id):
            guard let e = try ctx.workspace.content(doc).outline.first(where: { $0.id == id && !$0.deleted }) else {
                throw NibError.notFound("outline entry \(id) in document \(doc)")
            }
            return try Shapes.pick(Shapes.outlineRow(e, doc), depth: 2, fields: p.fields) { try Shapes.recordJSON(e, points: false) }
        }
    }

    /// Full item JSON; with `points` a stroke carries its points in the flat "full" format, paged by cursor.
    static func itemJSON(_ it: Item, _ doc: DocumentID, _ page: PageID, _ p: Params, offset: Int,
                         _ ctx: CommandContext) throws -> JSONValue {
        let points = p.points ?? false
        let row = try Shapes.itemRow(it, doc, page, depth: 2, fields: p.fields, points: points && it.stroke == nil, ctx)
        guard points, let stroke = it.stroke, case .object(var o) = row, var so = o["stroke"]?.objectValue else { return row }
        so["pointCount"] = nil
        o["stroke"] = .object(so)
        let paged = Shapes.fill([:], key: "pts", count: stroke.points.count, offset: offset, limit: Int.max,
                                overhead: JSONValue.object(o).jsonString().utf8.count + 80) { Shapes.pointRow(stroke.points[$0]) }
        let rows = paged["pts"]?.arrayValue ?? []
        so["fmt"] = .string("full")
        so["pts"] = .array(rows.flatMap { $0.arrayValue ?? [] })
        so["pointOffset"] = .number(Double(offset))
        so["pointCount"] = .number(Double(stroke.points.count))
        o["stroke"] = .object(so)
        o["cursor"] = paged["cursor"]
        o["truncated"] = paged["truncated"]
        return .object(o)
    }
}

// MARK: - query.find

struct QueryFind: NibCommand {
    struct Params: Codable {
        var inRef: String
        var kinds: [String]?
        var layer: Int?
        var bbox: [Double]?
        var whereFields: JSONValue?
        var text: String?
        var limit: Int?
        var cursor: String?

        enum CodingKeys: String, CodingKey {
            case inRef = "in"
            case whereFields = "where"
            case kinds, layer, bbox, text, limit, cursor
        }
    }

    static let descriptor = CommandDescriptor(
        id: "query.find", title: "Find Items",
        summary: "Find items in a page or document by kind or tool, layer, area (bbox), field match (where, e.g. {\"tool\":\"highlighter\"}) or typed text.",
        params: .obj(["in": .ref,
                      "kinds": .arr(.str(choices: ItemKind.allCases.map { $0.rawValue } + InkTool.allCases.map { $0.rawValue }),
                                    "item kinds, or stroke tools (pen, pencil, highlighter, tape)"),
                      "layer": .int(min: 0, max: 4), "bbox": .rect,
                      "where": .anything("field equality on the item row or item JSON; objects match as subsets"),
                      "text": .str("case-insensitive typed text"), "limit": .int(min: 1, max: 500),
                      "cursor": .str("from the previous result")], required: ["in"]),
        examples: [try! JSONValue.parse(#"{"in": "page:FIXTUREDOC01/FIXTUREPG001", "kinds": ["tape"]}"#),
                   ["in": "doc:FIXTUREDOC01", "text": "hello"],
                   try! JSONValue.parse(#"{"in": "page:FIXTUREDOC01/FIXTUREPG001", "where": {"tool": "pen"}}"#)],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let ref = try Shapes.ref(p.inRef, path: "$.in")
        let offset = try Shapes.offset(p.cursor)
        guard let doc = ref.documentID else {
            throw NibError(.invalidParams, "'in' must be a doc or page ref", path: "$.in")
        }
        if Shapes.hidden(doc, ctx) {
            return .object(["in": .string(ref.description), "locked": .bool(true), "items": .array([])])
        }
        let content = try ctx.workspace.content(doc)
        let pages: [PageID]
        switch ref {
        case .document:
            pages = content.livePages.map { $0.id }
        case .page(_, let page):
            guard content.page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
            pages = [page]
        default:
            throw NibError(.invalidParams, "'in' must be a doc or page ref", path: "$.in")
        }
        let area = try p.bbox.map { try Shapes.rect(from: $0, path: "$.bbox") }
        let kinds = p.kinds.map { Set($0) }
        let wanted = p.whereFields?.objectValue

        var hits: [JSONValue] = []
        for page in pages {
            for it in try ctx.workspace.items(doc, page: page) {
                if let k = kinds, !k.contains(it.kind.rawValue), !(it.stroke.map { k.contains($0.style.tool.rawValue) } ?? false) {
                    continue
                }
                if let l = p.layer, it.layer != l { continue }
                if let r = area, !it.bounds.intersects(r) { continue }
                if let t = p.text, !(Shapes.text(of: it, ctx)?.localizedCaseInsensitiveContains(t) ?? false) { continue }
                let row = Shapes.summary(it, doc: doc, page: page, ctx)
                if let w = wanted, !Shapes.matches(row, w, full: { (try? Shapes.itemJSON(it, points: false)) ?? [:] }) {
                    continue
                }
                hits.append(.object(row))
            }
        }
        return Shapes.fill(["in": .string(ref.description), "count": .number(Double(hits.count))], key: "items",
                           count: hits.count, offset: offset, limit: p.limit ?? 100) { hits[$0] }
    }
}

// MARK: - Node shapes

extension Shapes {
    /// nil = library root.
    static func folder(_ s: String, _ library: LibraryService, path: String) throws -> FolderID? {
        switch try ref(s, path: path) {
        case .library:
            return nil
        case .folder(let f):
            guard let n = library.node(f), n.kind == .folder, n.trashedAt == nil else { throw NibError.notFound("folder \(f)") }
            return f
        default:
            throw NibError(.invalidParams, "expected lib or a folder ref", path: path)
        }
    }

    /// Depth-first rows (folders first) under `root`, `depth` levels deep.
    static func treeRows(_ library: LibraryService, root: FolderID?, depth: Int, _ ctx: CommandContext) -> [JSONValue] {
        var out: [JSONValue] = []
        func walk(_ folder: FolderID?, _ level: Int) {
            guard level <= depth else { return }
            let parent = folder.map { NodeRef.folder($0).description } ?? "lib"
            let nodes = library.children(of: folder).sorted { a, b in
                a.kind != b.kind ? a.kind == .folder : a.title < b.title
            }
            for n in nodes {
                out.append(libraryRow(n, parent: parent, depth: level, ctx))
                if n.kind == .folder { walk(n.id, level + 1) }
            }
        }
        walk(root, 1)
        return out
    }

    static func libraryRow(_ n: LibraryNode, parent: String, depth: Int, _ ctx: CommandContext) -> JSONValue {
        var o: [String: JSONValue] = ["parent": .string(parent), "depth": .number(Double(depth))]
        if n.kind == .folder {
            o["ref"] = .string(NodeRef.folder(n.id).description)
            o["kind"] = .string("folder")
            o["title"] = .string(n.title)
            if n.favorite || n.style?.favorite == true { o["favorite"] = .bool(true) }
            if let c = n.style?.color { o["color"] = .string(c.hex) }
            return .object(o)
        }
        o["ref"] = .string(NodeRef.document(n.id).description)
        o["kind"] = .string("document")
        if hidden(n.id, ctx) {
            o["locked"] = .bool(true)
            return .object(o)
        }
        o["title"] = .string(n.title)
        if let k = n.documentKind { o["documentKind"] = .string(k.rawValue) }
        if let c = n.pageCount { o["pageCount"] = .number(Double(c)) }
        o["modified"] = .number(n.modified.rounded())
        if n.favorite { o["favorite"] = .bool(true) }
        if n.locked || isLocked(n.id, ctx) { o["locked"] = .bool(true) }
        return .object(o)
    }

    static func libraryJSON(_ ref: NodeRef, depth: Int, offset: Int, _ ctx: CommandContext) throws -> JSONValue {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let root = try folder(ref.description, library, path: "$.ref")
        var base: [String: JSONValue] = ["ref": .string(ref.description), "kind": .string(root == nil ? "library" : "folder")]
        if let f = root, let n = library.node(f) {
            base["title"] = .string(n.title)
            base["parent"] = .string(n.parent.map { NodeRef.folder($0).description } ?? "lib")
        }
        let rows = depth > 0 ? treeRows(library, root: root, depth: depth, ctx) : []
        return fill(base, key: "children", count: rows.count, offset: offset, limit: 500) { rows[$0] }
    }

    static func documentJSON(_ doc: DocumentID, depth: Int, fields: [String]?, points: Bool, offset: Int,
                             _ ctx: CommandContext) throws -> JSONValue {
        let c = try ctx.workspace.content(doc)
        var meta = try JSONValue.from(c.meta).objectValue ?? [:]
        meta["sourceBookmark"] = nil
        var o: [String: JSONValue] = [
            "ref": .string(NodeRef.document(doc).description), "kind": .string("document"),
            "documentKind": .string(c.meta.kind.rawValue), "meta": .object(meta), "locked": .bool(isLocked(doc, ctx)),
            "pageCount": .number(Double(c.livePages.count)), "trashedPages": .number(Double(c.trashedPages.count)),
            "blockCount": .number(Double(c.liveBlocks.count)), "cardCount": .number(Double(c.liveCards.count)),
            "outlineCount": .number(Double(c.liveOutline.count)), "audioCount": .number(Double(c.liveAudio.count))
        ]
        if let t = title(doc, ctx) { o["title"] = .string(t) }
        guard depth >= 1 else { return .object(o) }
        o["outline"] = .array(try c.liveOutline.map { e in
            try pick(outlineRow(e, doc), depth: depth, fields: fields) { try recordJSON(e, points: false) }
        })
        o["audio"] = .array(try c.liveAudio.map { a in
            try pick(audioRow(a, doc), depth: depth, fields: fields) { try recordJSON(a, points: false) }
        })
        switch c.meta.kind {
        case .notebook, .whiteboard:
            let pages = c.livePages
            return try fill(o, key: "pages", count: pages.count, offset: offset, limit: 500) { i in
                try pick(pageRow(pages[i], doc, index: i), depth: depth, fields: fields) { try recordJSON(pages[i], points: points) }
            }
        case .textDocument:
            let blocks = c.liveBlocks
            return try fill(o, key: "blocks", count: blocks.count, offset: offset, limit: 500) { i in
                try pick(blockRow(blocks[i], doc), depth: depth, fields: fields) { try recordJSON(blocks[i], points: points) }
            }
        case .studySet:
            let cards = c.liveCards
            return try fill(o, key: "cards", count: cards.count, offset: offset, limit: 500) { i in
                try pick(cardRow(cards[i], doc), depth: depth, fields: fields) { try recordJSON(cards[i], points: points) }
            }
        }
    }

    /// The §7.2 page shape; items are summaries (depth 1), full JSON (depth ≥ 2) or `fields`, ≤ 200 per call.
    static func pageJSON(_ doc: DocumentID, _ page: PageID, depth: Int, fields: [String]?, points: Bool, offset: Int,
                         _ ctx: CommandContext) throws -> JSONValue {
        let c = try ctx.workspace.content(doc)
        guard let rec = c.page(page), !rec.deleted || rec.trashedAt != nil else {
            throw NibError.notFound("page \(page) in document \(doc)")
        }
        var o = pageRow(rec, doc, index: c.pageIndex(page))
        o["rotation"] = .number(Double(rec.rotation))
        o["background"] = try JSONValue.from(rec.background)
        if rec.deleted { o["trashed"] = .bool(true) }
        if let ext = rec.ext { o["ext"] = .object(ext) }
        o["layers"] = layers(c.meta, doc, ctx)
        let items = try ctx.workspace.items(doc, page: page)
        var counts: [String: Int] = [:]
        for it in items { counts[it.kind.rawValue, default: 0] += 1 }
        o["counts"] = .object(counts.mapValues { JSONValue.number(Double($0)) })
        o["itemCount"] = .number(Double(items.count))
        guard depth >= 1 else { return .object(o) }
        return try fill(o, key: "items", count: items.count, offset: offset, limit: 200) { i in
            try itemRow(items[i], doc, page, depth: depth, fields: fields, points: points, ctx)
        }
    }

    static func itemRow(_ it: Item, _ doc: DocumentID, _ page: PageID, depth: Int, fields: [String]?, points: Bool,
                        _ ctx: CommandContext) throws -> JSONValue {
        try pick(summary(it, doc: doc, page: page, ctx), depth: depth, fields: fields) {
            var f = try itemJSON(it, points: points)
            f["bbox"] = rect(it.bounds)
            return f
        }
    }

    static func layers(_ meta: DocumentMeta, _ doc: DocumentID, _ ctx: CommandContext) -> JSONValue {
        let s = ctx.activeSession.flatMap { $0.document == doc ? $0 : nil }
        return .array(meta.layers.map { l in
            JSONValue.object(["index": .number(Double(l.index)), "name": .string(l.name),
                              "visible": .bool(!(s?.hiddenLayers.contains(l.index) ?? false)),
                              "active": .bool((s?.activeLayer ?? 0) == l.index)])
        })
    }

    static func pageRow(_ p: PageRecord, _ doc: DocumentID, index: Int?) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["ref": .string(NodeRef.page(doc, p.id).description), "kind": .string("page"),
                                      "size": size(p.size), "background": .string(p.background.kind.rawValue)]
        if let i = index { o["index"] = .number(Double(i)) }
        if let t = p.title { o["title"] = .string(t) }
        if p.bookmarked { o["bookmarked"] = .bool(true) }
        return o
    }

    static func blockRow(_ b: TextBlock, _ doc: DocumentID) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["ref": .string(NodeRef.block(doc, b.id).description), "kind": .string(b.kind.rawValue)]
        let t = b.text.plainText
        if !t.isEmpty { o["text"] = .string(clip(t)) }
        if let c = b.checked { o["checked"] = .bool(c) }
        if let n = b.indent, n > 0 { o["indent"] = .number(Double(n)) }
        if let a = b.asset { o["asset"] = .string(a.name) }
        if let c = b.custom {
            o["owner"] = .string(c.owner)
            o["type"] = .string(c.type)
        }
        if let n = b.comments?.count, n > 0 { o["comments"] = .number(Double(n)) }
        return o
    }

    static func cardRow(_ c: StudyCard, _ doc: DocumentID) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["ref": .string(NodeRef.card(doc, c.id).description), "kind": .string("card"),
                                      "front": faceText(c.front), "back": faceText(c.back)]
        if let due = c.srs?.due, due > 0 { o["due"] = .number(due.rounded()) }
        return o
    }

    static func faceText(_ f: CardFace) -> JSONValue {
        switch f.kind {
        case .text: return .string(clip(f.text?.plainText ?? ""))
        case .image: return .string("[image " + (f.asset?.name ?? "") + "]")
        case .ink: return .string("[ink]")
        }
    }

    static func outlineRow(_ e: OutlineEntry, _ doc: DocumentID) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["ref": .string(NodeRef.outline(doc, e.id).description), "kind": .string("outline"),
                                      "title": .string(e.title)]
        if let p = e.page { o["page"] = .string(NodeRef.page(doc, p).description) }
        if let p = e.parent { o["parent"] = .string(NodeRef.outline(doc, p).description) }
        return o
    }

    static func audioRow(_ a: AudioClip, _ doc: DocumentID) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["ref": .string(NodeRef.audio(doc, a.id).description), "kind": .string("audio"),
                                      "name": .string(a.name), "start": num(a.start), "duration": num(a.duration)]
        if let p = a.page { o["page"] = .string(NodeRef.page(doc, p).description) }
        return o
    }
}
