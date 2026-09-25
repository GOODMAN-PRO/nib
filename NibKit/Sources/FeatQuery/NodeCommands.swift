import Foundation
import NibContracts

/// Shared write paths of node.* and item.*: every raw edit is encoded, merged and decoded by Codable before it is
/// stored with `DocTransaction.put` (which also stamps revisions and provenance).
@MainActor
enum Edits {
    /// Honours a caller-chosen id (the `id` param wins over the JSON's own `id`).
    static func applyID(_ obj: inout [String: JSONValue], _ id: String?, path: String) throws {
        if let id = id {
            guard NibID.isValid(id) else {
                throw NibError(.invalidParams, "id must be 1–64 characters of [A-Za-z0-9_-]", path: "$.id")
            }
            obj["id"] = .string(id)
        } else if let v = obj["id"], v != JSONValue.null {
            guard let s = v.stringValue, NibID.isValid(s) else {
                throw NibError(.invalidParams, "id must be 1–64 characters of [A-Za-z0-9_-]", path: path + ".id")
            }
        }
    }

    static func ensureNew<T: LWWRecord>(_ id: NibID, in records: [T], what: String) throws {
        if records.contains(where: { $0.id == id && !$0.deleted }) {
            throw NibError(.conflict, "\(what) \(id) already exists", hint: "use node.set to change it, or choose another id")
        }
    }

    static func sameID(_ new: NibID, _ old: NibID, path: String) throws {
        guard new == old else {
            throw NibError(.invalidParams, "a record's id cannot change", path: path + ".id",
                           hint: "use node.insert to add a record with a new id")
        }
    }

    static func defaultType(_ kind: DocumentKind) -> String {
        switch kind {
        case .notebook, .whiteboard: return "page"
        case .textDocument: return "block"
        case .studySet: return "card"
        }
    }

    /// Creates an item on a page: caller-chosen id, active-layer default, optional z index, ink normalised.
    static func createItem(_ json: [String: JSONValue], id: String?, doc: DocumentID, page: PageID, at: Int?,
                           path: String, _ ctx: CommandContext) throws -> String {
        var obj = json
        try applyID(&obj, id, path: path)
        obj["rev"] = nil
        obj["deleted"] = nil
        if obj["layer"] == nil || obj["layer"] == JSONValue.null {
            obj["layer"] = .number(Double(ctx.activeSession?.activeLayer ?? 0))
        }
        Shapes.unref(&obj, ["attachedTo"])
        guard let rec = try ctx.workspace.content(doc).page(page), !rec.deleted else {
            throw NibError.notFound("page \(page) in document \(doc)")
        }
        var item = try Shapes.decode(Item.self, .object(obj), at: path)
        let live = try ctx.workspace.items(doc, page: page)
        if live.contains(where: { $0.id == item.id }) {
            throw NibError(.conflict, "item \(item.id) already exists on page \(page)",
                           hint: "use item.update or node.set to change it, or choose another id")
        }
        if let at = at { item.z = Shapes.orderKey(at: at, among: live.map { $0.z }) }
        if var s = item.stroke {
            InkModel.prepare(&s)
            item.stroke = s
        }
        let stored = item
        let saved = try ctx.mutate { tx in try tx.put(stored, doc: doc, page: page) }
        return NodeRef.item(doc, page, saved.id).description
    }

    /// item.update patches may name payload fields directly ({"frame": …, "color": …}); they are nested under the
    /// item's kind key, while the common item fields (layer, locked, ext…) stay at the top.
    static func route(_ patch: [String: JSONValue], kind: ItemKind) -> [String: JSONValue] {
        let common: Set<String> = ["id", "rev", "deleted", "kind", "z", "layer", "locked", "attachedTo", "createdBy", "ext"]
        var out: [String: JSONValue] = [:]
        var payload: [String: JSONValue] = [:]
        for (k, v) in patch {
            if common.contains(k) {
                out[k] = v
            } else if k == kind.rawValue, case .object(let o) = v, o["paragraphs"] == nil {
                payload.merge(o) { a, b in a.merging(b) }
            } else {
                payload[k] = payload[k].map { $0.merging(v) } ?? v
            }
        }
        if !payload.isEmpty { out[kind.rawValue] = .object(payload) }
        return out
    }

    /// encode → `JSONValue.merging` → decode. A stroke patch with `pts` replaces the whole point array; a width
    /// change rescales captured nib sizes; `InkModel.prepare` then densifies and sizes new points.
    static func patchItem(_ old: Item, _ patch: [String: JSONValue], path: String) throws -> Item {
        guard case .object(var merged) = try Shapes.compactJSON(old).merging(.object(patch)) else { return old }
        let newPoints = patch["stroke"]?["pts"] != nil || patch["stroke"]?["ptsB64"] != nil
        if newPoints, patch["stroke"]?["ptsB64"] == nil, var s = merged["stroke"]?.objectValue {
            s["ptsB64"] = nil
            merged["stroke"] = .object(s)
        }
        var new = try Shapes.decode(Item.self, .object(merged), at: path)
        try sameID(new.id, old.id, path: path)
        if var s = new.stroke {
            if !newPoints, let o = old.stroke, o.style.width > 0, s.style.width != o.style.width {
                let k = Float(s.style.width / o.style.width)
                for i in s.points.indices {
                    s.points[i].width *= k
                    s.points[i].height *= k
                }
            }
            InkModel.prepare(&s)
            new.stroke = s
        }
        return new
    }

    /// Stores the item when it changed; false = nothing to do (no undo step).
    static func write(_ old: Item, _ new: Item, doc: DocumentID, page: PageID, _ ctx: CommandContext) throws -> Bool {
        guard new != old else { return false }
        try ctx.mutate { tx in try tx.put(new, doc: doc, page: page) }
        return true
    }

    /// node.set on any record.
    static func set(_ ref: NodeRef, _ fields: [String: JSONValue], path: String, _ ctx: CommandContext) throws -> Bool {
        switch ref {
        case .library, .folder:
            throw NibError(.invalidParams, "folders and the library are not document records", path: "$.ref",
                           hint: "rename, move or restyle them with the library commands (commands.list)")
        case .document(let doc):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedMetaFields, path: path, ctx)
            var patch = fields
            patch["meta"] = nil
            if let meta = fields["meta"]?.objectValue {
                try Shapes.rejectProtected(meta, keys: Shapes.protectedMetaFields, path: path + ".meta", ctx)
                patch.merge(meta) { _, new in new }
            }
            let old = try ctx.workspace.content(doc).meta
            let new = try Shapes.decode(DocumentMeta.self, Shapes.compactJSON(old).merging(.object(patch)),
                                        at: fields["meta"] == nil ? path : path + ".meta")
            try sameID(new.id, old.id, path: path)
            guard new != old else { return false }
            try ctx.mutate { tx in try tx.putMeta(new) }
            return true
        case let .page(doc, id):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedFields, path: path, ctx)
            var patch = fields
            Shapes.normalizeSize(&patch)
            return try setRecord(ctx.workspace.content(doc).pages, id, patch, path: path, what: "page", ctx) { tx, r in
                try tx.put(r, doc: doc)
            }
        case let .item(doc, page, id):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedFields, path: path, ctx)
            if let stroke = fields["stroke"]?.objectValue { try Shapes.checkStrokePoints(stroke, path: path + ".stroke") }
            guard let old = try ctx.workspace.allItems(doc, page: page).first(where: { $0.id == id }) else {
                throw NibError.notFound("item \(id) on page \(page)")
            }
            var patch = fields
            Shapes.unref(&patch, ["attachedTo"])
            return try write(old, patchItem(old, patch, path: path), doc: doc, page: page, ctx)
        case let .block(doc, id):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedFields, path: path, ctx)
            return try setRecord(ctx.workspace.content(doc).blocks, id, fields, path: path, what: "block", ctx) { tx, r in
                try tx.put(r, doc: doc)
            }
        case let .card(doc, id):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedFields, path: path, ctx)
            return try setRecord(ctx.workspace.content(doc).cards, id, fields, path: path, what: "card", ctx) { tx, r in
                try tx.put(r, doc: doc)
            }
        case let .audio(doc, id):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedFields, path: path, ctx)
            var patch = fields
            Shapes.unref(&patch, ["page"])
            return try setRecord(ctx.workspace.content(doc).audio, id, patch, path: path, what: "audio clip", ctx) { tx, r in
                try tx.put(r, doc: doc)
            }
        case let .outline(doc, id):
            try Shapes.rejectProtected(fields, keys: Shapes.protectedFields, path: path, ctx)
            var patch = fields
            Shapes.unref(&patch, ["page", "parent"])
            return try setRecord(ctx.workspace.content(doc).outline, id, patch, path: path, what: "outline entry", ctx) { tx, r in
                try tx.put(r, doc: doc)
            }
        }
    }

    static func setRecord<T: LWWRecord>(_ records: [T], _ id: NibID, _ fields: [String: JSONValue], path: String,
                                        what: String, _ ctx: CommandContext,
                                        put: (DocTransaction, T) throws -> T) throws -> Bool {
        guard let old = records.first(where: { $0.id == id }) else { throw NibError.notFound("\(what) \(id)") }
        let new = try Shapes.decode(T.self, Shapes.compactJSON(old).merging(.object(fields)), at: path)
        try sameID(new.id, old.id, path: path)
        guard new != old else { return false }
        try ctx.mutate { tx in _ = try put(tx, new) }
        return true
    }

    static func tombstone<T: LWWRecord>(_ records: [T], _ id: NibID, what: String, _ ctx: CommandContext,
                                        put: (DocTransaction, T) throws -> T) throws {
        guard var r = records.first(where: { $0.id == id && !$0.deleted }) else { throw NibError.notFound("\(what) \(id)") }
        r.deleted = true
        let stored = r
        try ctx.mutate { tx in _ = try put(tx, stored) }
    }

    /// Moves a record to `at` among its live siblings (`live` is sorted by order).
    static func reorder<T: LWWRecord>(_ live: [T], _ id: NibID, at: Int?, order: WritableKeyPath<T, String>, what: String,
                                      _ ctx: CommandContext, put: (DocTransaction, T) throws -> T) throws {
        guard var r = live.first(where: { $0.id == id }) else { throw NibError.notFound("\(what) \(id)") }
        r[keyPath: order] = Shapes.orderKey(at: at, among: live.filter { $0.id != id }.map { $0[keyPath: order] })
        let stored = r
        try ctx.mutate { tx in _ = try put(tx, stored) }
    }

    /// Clears attachments and connector anchors that point at `id`, so the page stays valid when it leaves.
    static func detach(_ id: ElementID, doc: DocumentID, page: PageID, _ tx: DocTransaction) throws {
        for var it in try tx.items(doc, page: page) where it.id != id {
            var changed = false
            if it.attachedTo == id {
                it.attachedTo = nil
                changed = true
            }
            if var c = it.connector {
                if c.from.item == id {
                    c.from = ConnectorEnd(point: c.from.point)
                    changed = true
                }
                if c.to.item == id {
                    c.to = ConnectorEnd(point: c.to.point)
                    changed = true
                }
                it.connector = c
            }
            if changed { try tx.put(it, doc: doc, page: page) }
        }
    }

    /// The item without references to other items of its old page (they do not exist on the new one).
    static func unanchored(_ item: Item) -> Item {
        var it = item
        it.attachedTo = nil
        if var c = it.connector {
            c.from = ConnectorEnd(point: c.from.point)
            c.to = ConnectorEnd(point: c.to.point)
            it.connector = c
        }
        return it
    }
}

// MARK: - node.insert

struct NodeInsert: NibCommand {
    struct Params: Codable {
        var parent: String
        var node: JSONValue
        var at: Int?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "node.insert", title: "Insert Node",
        summary: "Insert any record as raw JSON: an item under page:D/P, a page/block/card/outline/audio under doc:D (node.type), or a child under outline:D/O.",
        params: .obj(["parent": .str("page:D/P for items, doc:D for pages/blocks/cards/outline/audio, outline:D/O for a child entry"),
                      "node": .obj([:], required: [], "record JSON; under a doc, node.type = page|block|card|outline|audio (default by document kind)"),
                      "at": .int("index among live siblings (items: z order, 0 = bottom); default last", min: 0),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")],
                     required: ["parent", "node"]),
        examples: [
            try! JSONValue.parse(#"{"parent": "page:FIXTUREDOC01/FIXTUREPG002", "node": {"kind": "text", "text": {"frame": {"x": 72, "y": 72, "w": 240, "h": 40}, "text": "Inserted"}}}"#),
            try! JSONValue.parse(#"{"parent": "doc:FIXTUREDOC02", "node": {"kind": "paragraph", "text": "A new paragraph"}, "at": 1}"#),
            try! JSONValue.parse(#"{"parent": "doc:FIXTUREDOC01", "node": {"type": "page"}, "at": 1}"#),
            try! JSONValue.parse(#"{"parent": "doc:FIXTUREDOC01", "node": {"type": "outline", "title": "Page two", "page": "page:FIXTUREDOC01/FIXTUREPG002"}}"#),
            try! JSONValue.parse(#"{"parent": "doc:FIXTUREDOC03", "node": {"front": "Term", "back": "Definition"}}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let parent = try Shapes.ref(p.parent, path: "$.parent")
        guard case .object(var node) = p.node else {
            throw NibError(.invalidParams, "node must be a JSON object", path: "$.node")
        }
        try Shapes.rejectProtected(node, keys: ["createdBy", "rev", "deleted"], path: "$.node", ctx)
        guard let doc = parent.documentID else {
            throw NibError(.invalidParams, "parent must be a page, doc or outline ref", path: "$.parent",
                           hint: "folders and documents are created with the library commands")
        }
        try Shapes.requireUnlocked(doc, ctx)
        let content = try ctx.workspace.content(doc)
        var kind = node["type"]?.stringValue ?? Edits.defaultType(content.meta.kind)
        switch parent {
        case let .page(_, page):
            return Output(ref: try Edits.createItem(node, id: p.id, doc: doc, page: page, at: p.at, path: "$.node", ctx))
        case .document:
            break
        case let .outline(_, entry):
            guard content.outline.contains(where: { $0.id == entry && !$0.deleted }) else {
                throw NibError.notFound("outline entry \(entry) in document \(doc)")
            }
            kind = "outline"
            node["parent"] = .string(entry.raw)
        default:
            throw NibError(.invalidParams, "parent must be a page, doc or outline ref", path: "$.parent")
        }
        try Edits.applyID(&node, p.id, path: "$.node")
        node["rev"] = nil
        node["deleted"] = nil

        switch kind {
        case "page":
            Shapes.normalizeSize(&node)
            var page = try Shapes.decode(PageRecord.self, .object(node), at: "$.node")
            if page.size == nil, node["size"] == nil, content.meta.kind != .whiteboard {
                page.size = content.livePages.last?.size ?? .a4   // notebook pages are never infinite by accident
            }
            try Edits.ensureNew(page.id, in: content.pages, what: "page")
            if let at = p.at { page.order = Shapes.orderKey(at: at, among: content.livePages.map { $0.order }) }
            let stored = page
            let saved = try ctx.mutate { tx in try tx.put(stored, doc: doc) }
            return Output(ref: NodeRef.page(doc, saved.id).description)
        case "block":
            var block = try Shapes.decode(TextBlock.self, .object(node), at: "$.node")
            try Edits.ensureNew(block.id, in: content.blocks, what: "block")
            if let at = p.at { block.order = Shapes.orderKey(at: at, among: content.liveBlocks.map { $0.order }) }
            let stored = block
            let saved = try ctx.mutate { tx in try tx.put(stored, doc: doc) }
            return Output(ref: NodeRef.block(doc, saved.id).description)
        case "card":
            var card = try Shapes.decode(StudyCard.self, .object(node), at: "$.node")
            try Edits.ensureNew(card.id, in: content.cards, what: "card")
            if let at = p.at { card.order = Shapes.orderKey(at: at, among: content.liveCards.map { $0.order }) }
            let stored = card
            let saved = try ctx.mutate { tx in try tx.put(stored, doc: doc) }
            return Output(ref: NodeRef.card(doc, saved.id).description)
        case "outline":
            Shapes.unref(&node, ["page", "parent"])
            var entry = try Shapes.decode(OutlineEntry.self, .object(node), at: "$.node")
            try Edits.ensureNew(entry.id, in: content.outline, what: "outline entry")
            let parentID = entry.parent
            if let pid = parentID, !content.outline.contains(where: { $0.id == pid && !$0.deleted }) {
                throw NibError.notFound("outline entry \(pid) in document \(doc)")
            }
            if let at = p.at {
                entry.order = Shapes.orderKey(at: at, among: content.liveOutline.filter { $0.parent == parentID }.map { $0.order })
            }
            let stored = entry
            let saved = try ctx.mutate { tx in try tx.put(stored, doc: doc) }
            return Output(ref: NodeRef.outline(doc, saved.id).description)
        case "audio":
            Shapes.unref(&node, ["page"])
            let clip = try Shapes.decode(AudioClip.self, .object(node), at: "$.node")
            try Edits.ensureNew(clip.id, in: content.audio, what: "audio clip")
            let saved = try ctx.mutate { tx in try tx.put(clip, doc: doc) }
            return Output(ref: NodeRef.audio(doc, saved.id).description)
        default:
            throw NibError(.invalidParams, "unknown node type '\(kind)'", path: "$.node.type",
                           hint: "use page, block, card, outline or audio; items go under a page ref")
        }
    }
}

// MARK: - node.set

struct NodeSet: NibCommand {
    struct Params: Codable {
        var ref: String
        var fields: JSONValue
    }

    struct Output: Codable {
        var ref: String
        var changed: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "node.set", title: "Set Node Fields",
        summary: "Merge fields into any record (JSON merge, re-validated by Codable): item, page, block, card, audio, outline; for a doc use {meta: {…}}.",
        params: .obj(["ref": .ref,
                      "fields": .obj([:], required: [], "partial record JSON; objects merge key by key, other values replace")],
                     required: ["ref", "fields"]),
        examples: [
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "fields": {"ext": {"dev.example": {"tag": "draft"}}}}"#),
            try! JSONValue.parse(#"{"ref": "doc:FIXTUREDOC01", "fields": {"meta": {"favorite": true}}}"#),
            try! JSONValue.parse(#"{"ref": "page:FIXTUREDOC01/FIXTUREPG001", "fields": {"bookmarked": true}}"#),
            try! JSONValue.parse(#"{"ref": "card:FIXTUREDOC03/FIXTURECRD01", "fields": {"back": "New definition"}}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ref = try Shapes.ref(p.ref, path: "$.ref")
        guard case .object(let fields) = p.fields else {
            throw NibError(.invalidParams, "fields must be a JSON object", path: "$.fields")
        }
        if let doc = ref.documentID { try Shapes.requireUnlocked(doc, ctx) }
        let changed = try Edits.set(ref, fields, path: "$.fields", ctx)
        return Output(ref: ref.description, changed: changed)
    }
}

// MARK: - node.remove

struct NodeRemove: NibCommand {
    struct Params: Codable {
        var ref: String
    }

    struct Output: Codable {
        var removed: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "node.remove", title: "Remove Node",
        summary: "Tombstone any record: item (anchors to it are cleared), page (to the page Trash), block, card, audio clip, or outline entry with its children.",
        params: .obj(["ref": .ref], required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], ["ref": "page:FIXTUREDOC01/FIXTUREPG002"],
                   ["ref": "block:FIXTUREDOC02/FIXTUREBLK02"], ["ref": "outline:FIXTUREDOC01/FIXTUREOUT01"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ref = try Shapes.ref(p.ref, path: "$.ref")
        if let doc = ref.documentID { try Shapes.requireUnlocked(doc, ctx) }
        switch ref {
        case let .item(doc, page, id):
            _ = try ctx.workspace.item(doc, page: page, id: id)
            try ctx.mutate { tx in
                try Edits.detach(id, doc: doc, page: page, tx)
                try tx.delete(item: id, doc: doc, page: page)
            }
        case let .page(doc, id):
            let content = try ctx.workspace.content(doc)
            guard var page = content.page(id), !page.deleted else { throw NibError.notFound("page \(id) in document \(doc)") }
            guard content.livePages.count > 1 else {
                throw NibError(.invalidParams, "a document keeps at least one page", path: "$.ref", hint: "add a page first")
            }
            page.deleted = true
            page.trashedAt = Date().timeIntervalSince1970
            let stored = page
            try ctx.mutate { tx in try tx.put(stored, doc: doc) }
        case let .block(doc, id):
            try Edits.tombstone(ctx.workspace.content(doc).blocks, id, what: "block", ctx) { tx, r in try tx.put(r, doc: doc) }
        case let .card(doc, id):
            try Edits.tombstone(ctx.workspace.content(doc).cards, id, what: "card", ctx) { tx, r in try tx.put(r, doc: doc) }
        case let .audio(doc, id):
            try Edits.tombstone(ctx.workspace.content(doc).audio, id, what: "audio clip", ctx) { tx, r in try tx.put(r, doc: doc) }
        case let .outline(doc, id):
            let outline = try ctx.workspace.content(doc).outline
            guard outline.contains(where: { $0.id == id && !$0.deleted }) else {
                throw NibError.notFound("outline entry \(id) in document \(doc)")
            }
            var ids = [id]
            var i = 0
            while i < ids.count {
                let parent = ids[i]
                let known = Set(ids)
                let children = outline.filter { !$0.deleted && $0.parent == parent && !known.contains($0.id) }.map { $0.id }
                ids.append(contentsOf: children)
                i += 1
            }
            let doomed = Set(ids)
            try ctx.mutate { tx in
                for var e in outline where doomed.contains(e.id) && !e.deleted {
                    e.deleted = true
                    try tx.put(e, doc: doc)
                }
            }
            return Output(removed: ids.map { NodeRef.outline(doc, $0).description })
        case .library, .folder, .document:
            throw NibError(.invalidParams, "documents and folders are removed with the library commands", path: "$.ref",
                           hint: "see commands.list for the trash commands")
        }
        return Output(removed: [ref.description])
    }
}

// MARK: - node.move

struct NodeMove: NibCommand {
    struct Params: Codable {
        var ref: String
        var to: String
        var at: Int?
    }

    struct Output: Codable {
        var newRef: String
    }

    static let descriptor = CommandDescriptor(
        id: "node.move", title: "Move Node",
        summary: "Reorder or reparent: an item to a z index or another page of its document (id kept), a page/block/card to an index, an outline entry under another.",
        params: .obj(["ref": .ref,
                      "to": .str("items: page:D/P; pages, blocks, cards: doc:D; outline entries: doc:D or outline:D/O"),
                      "at": .int("index among the new siblings (items: z order, 0 = bottom); default last/top", min: 0)],
                     required: ["ref", "to"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "to": "page:FIXTUREDOC01/FIXTUREPG002"],
                   ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01", "to": "page:FIXTUREDOC01/FIXTUREPG001", "at": 0],
                   ["ref": "page:FIXTUREDOC01/FIXTUREPG003", "to": "doc:FIXTUREDOC01", "at": 0],
                   ["ref": "block:FIXTUREDOC02/FIXTUREBLK03", "to": "doc:FIXTUREDOC02", "at": 0]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let ref = try Shapes.ref(p.ref, path: "$.ref")
        let to = try Shapes.ref(p.to, path: "$.to")
        guard let doc = ref.documentID, to.documentID == doc else {
            throw NibError(.invalidParams, "'to' must be in the same document as 'ref'", path: "$.to",
                           hint: "items go to a page ref, pages/blocks/cards to their doc ref, outline entries to the doc or an entry")
        }
        try Shapes.requireUnlocked(doc, ctx)
        let content = try ctx.workspace.content(doc)
        switch ref {
        case let .item(_, page, id):
            guard case let .page(_, target) = to, let rec = content.page(target), !rec.deleted else {
                throw NibError(.invalidParams, "items move to a live page of the same document", path: "$.to")
            }
            let item = try ctx.workspace.item(doc, page: page, id: id)
            if target == page {
                var moved = item
                let others = try ctx.workspace.items(doc, page: page).filter { $0.id != id }
                moved.z = Shapes.orderKey(at: p.at, among: others.map { $0.z })
                let stored = moved
                try ctx.mutate { tx in try tx.put(stored, doc: doc, page: page) }
            } else {
                let targetItems = try ctx.workspace.items(doc, page: target)
                if targetItems.contains(where: { $0.id == id }) {
                    throw NibError(.conflict, "page \(target) already has an item \(id)")
                }
                var moved = Edits.unanchored(item)
                moved.z = Shapes.orderKey(at: p.at, among: targetItems.map { $0.z })
                let stored = moved
                try ctx.mutate { tx in
                    try Edits.detach(id, doc: doc, page: page, tx)
                    try tx.delete(item: id, doc: doc, page: page)
                    try tx.put(stored, doc: doc, page: target)
                }
            }
            return Output(newRef: NodeRef.item(doc, target, id).description)
        case let .page(_, id):
            try requireDocTarget(to)
            try Edits.reorder(content.livePages, id, at: p.at, order: \.order, what: "page", ctx) { tx, r in try tx.put(r, doc: doc) }
        case let .block(_, id):
            try requireDocTarget(to)
            try Edits.reorder(content.liveBlocks, id, at: p.at, order: \.order, what: "block", ctx) { tx, r in try tx.put(r, doc: doc) }
        case let .card(_, id):
            try requireDocTarget(to)
            try Edits.reorder(content.liveCards, id, at: p.at, order: \.order, what: "card", ctx) { tx, r in try tx.put(r, doc: doc) }
        case let .outline(_, id):
            guard var entry = content.outline.first(where: { $0.id == id && !$0.deleted }) else {
                throw NibError.notFound("outline entry \(id) in document \(doc)")
            }
            var parent: NibID?
            switch to {
            case .document:
                parent = nil
            case let .outline(_, target):
                guard content.outline.contains(where: { $0.id == target && !$0.deleted }) else {
                    throw NibError.notFound("outline entry \(target) in document \(doc)")
                }
                var ancestor: NibID? = target
                var steps = 0
                while let a = ancestor, steps <= content.outline.count {
                    if a == id { throw NibError(.invalidParams, "an outline entry cannot move under itself", path: "$.to") }
                    ancestor = content.outline.first(where: { $0.id == a })?.parent
                    steps += 1
                }
                parent = target
            default:
                throw NibError(.invalidParams, "outline entries move to doc:D or under outline:D/O", path: "$.to")
            }
            entry.parent = parent
            let siblings = content.liveOutline.filter { $0.parent == parent && $0.id != id }
            entry.order = Shapes.orderKey(at: p.at, among: siblings.map { $0.order })
            let stored = entry
            try ctx.mutate { tx in try tx.put(stored, doc: doc) }
        case .audio, .document, .library, .folder:
            throw NibError(.invalidParams, "only items, pages, blocks, cards and outline entries can move", path: "$.ref",
                           hint: "documents and folders move with the library commands")
        }
        return Output(newRef: ref.description)
    }

    static func requireDocTarget(_ to: NodeRef) throws {
        guard case .document = to else {
            throw NibError(.invalidParams, "pages, blocks and cards move within their doc:D", path: "$.to")
        }
    }
}

// MARK: - item.create

struct ItemCreate: NibCommand {
    struct Params: Codable {
        var page: String
        var item: JSONValue
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "item.create", title: "Create Item",
        summary: "Create an item from Item JSON (kind + matching payload, e.g. {kind:'text', text:{frame, text}}); layer defaults to the active layer.",
        params: .obj(["page": .ref,
                      "item": .obj(["kind": .str(choices: ItemKind.allCases.map { $0.rawValue })], required: ["kind"],
                                   "Item JSON; strokes: {kind:'stroke', stroke:{style?, fmt:'xy', pts:[x,y,…]}}"),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")],
                     required: ["page", "item"]),
        examples: [
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "item": {"kind": "sticky", "sticky": {"frame": {"x": 400, "y": 300, "w": 140, "h": 140}, "text": "New note"}}}"#),
            try! JSONValue.parse(##"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "item": {"kind": "stroke", "stroke": {"style": {"color": "#D0021BFF"}, "fmt": "xy", "pts": [72, 72, 200, 120]}}}"##)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page) = try Shapes.ref(p.page, path: "$.page") else {
            throw NibError(.invalidParams, "expected a page ref", path: "$.page")
        }
        guard case .object(let obj) = p.item else {
            throw NibError(.invalidParams, "item must be a JSON object", path: "$.item")
        }
        try Shapes.requireUnlocked(doc, ctx)
        // createdBy / rev / deleted are not errors here: DocTransaction.put stamps provenance and revisions itself.
        return Output(ref: try Edits.createItem(obj, id: p.id, doc: doc, page: page, at: nil, path: "$.item", ctx))
    }
}

// MARK: - item.update

struct ItemUpdate: NibCommand {
    struct Params: Codable {
        var ref: String
        var patch: JSONValue
    }

    struct Output: Codable {
        var ref: String
        var changed: Bool
        var bbox: Rect
    }

    static let descriptor = CommandDescriptor(
        id: "item.update", title: "Update Item",
        summary: "Patch an item's fields (style, frame, text, ext…; payload fields may be given directly); stroke points need {fmt, pts} and replace the array.",
        params: .obj(["ref": .ref,
                      "patch": .obj([:], required: [], "e.g. {\"frame\": {\"w\": 300}}, {\"text\": \"Hi\"}, {\"stroke\": {\"fmt\": \"xy\", \"pts\": […]}}")],
                     required: ["ref", "patch"]),
        examples: [
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "patch": {"stroke": {"fmt": "xy", "pts": [72, 140, 150, 170, 230, 140]}}}"#),
            try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "patch": {"text": "Updated text", "frame": {"w": 320}}}"#),
            try! JSONValue.parse(##"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "patch": {"color": "#A0E7E5FF", "layer": 1}}"##)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .item(doc, page, id) = try Shapes.ref(p.ref, path: "$.ref") else {
            throw NibError(.invalidParams, "expected an item ref", path: "$.ref")
        }
        guard case .object(let patch) = p.patch else {
            throw NibError(.invalidParams, "patch must be a JSON object", path: "$.patch")
        }
        try Shapes.requireUnlocked(doc, ctx)
        try Shapes.rejectProtected(patch, keys: Shapes.protectedFields, path: "$.patch", ctx)
        let old = try ctx.workspace.item(doc, page: page, id: id)
        var routed = Edits.route(patch, kind: old.kind)
        Shapes.unref(&routed, ["attachedTo"])
        if let stroke = routed["stroke"]?.objectValue {
            try Shapes.checkStrokePoints(stroke, path: patch["pts"] != nil ? "$.patch" : "$.patch.stroke")
        }
        let new = try Edits.patchItem(old, routed, path: "$.patch")
        let changed = try Edits.write(old, new, doc: doc, page: page, ctx)
        return Output(ref: NodeRef.item(doc, page, id).description, changed: changed, bbox: new.bounds)
    }
}
