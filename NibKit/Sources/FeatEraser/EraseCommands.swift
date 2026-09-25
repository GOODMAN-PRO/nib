import Foundation
import NibContracts

/// What the erase and delete commands return: counts, never refs (split pieces are internal).
struct EraseCounts: Codable, Equatable {
    var removed: Int
    var created: Int

    static let zero = EraseCounts(removed: 0, created: 0)
}

/// Shared by the eraser commands.
@MainActor
enum EraseSupport {
    static func pageRef(_ ref: String, path: String = "$.page") throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref such as page:D/P", path: path,
                           hint: "call query.context for the current page")
        }
        return (doc, page)
    }

    /// Live items of a live page; a missing or trashed page is `not_found`.
    static func liveItems(_ workspace: Workspace, _ doc: DocumentID, _ page: PageID) throws -> [Item] {
        guard let record = try workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page.raw) in document \(doc.raw)")
        }
        return try workspace.items(doc, page: page)
    }

    /// Rejects paths too long to run in one call (each point scans the page's candidates on the main actor).
    static func checkLength(_ points: [Point], _ path: String) throws {
        guard points.count <= EraserGeometry.maxPathPoints else {
            throw NibError(.invalidParams, "\(path.dropFirst(2)) has more than \(EraserGeometry.maxPathPoints) points", path: path,
                           hint: "split it into several calls of at most \(EraserGeometry.maxPathPoints) points")
        }
    }

    /// The layer the eraser works on: the invoking window's active layer.
    static func layer(_ ctx: CommandContext) -> Int { ctx.activeSession?.activeLayer ?? 0 }

    /// Tombstones `ids`. Live children lose their `attachedTo` and connector ends anchored to a removed item are
    /// released (the end point stays), so nothing is left pointing at a removed item.
    /// Tombstones the already-fetched items (`tx.delete` would look each one up again with a scan of the page).
    /// ponytail: `put` still scans the page per item, so clearing a 100k-item board is quadratic; needs a bulk
    /// tombstone on DocTransaction.
    static func remove(_ ids: Set<ElementID>, among items: [Item], tx: DocTransaction, doc: DocumentID, page: PageID) throws {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            var gone = item
            gone.deleted = true
            try tx.put(gone, doc: doc, page: page)
        }
        for item in items where !ids.contains(item.id) {
            var next = item
            if let parent = item.attachedTo, ids.contains(parent) { next.attachedTo = nil }
            if var c = next.connector {
                if let target = c.from.item, ids.contains(target) { c.from = ConnectorEnd(point: c.from.point) }
                if let target = c.to.item, ids.contains(target) { c.to = ConnectorEnd(point: c.to.point) }
                next.connector = c
            }
            if next != item { try tx.put(next, doc: doc, page: page) }
        }
    }

    /// Applies an eraser gesture: removes what it erased and inserts the cut pieces with fresh ids in the original's
    /// place (layer, attachment, style and provenance). Each piece gets its own z key between the original's and the
    /// next item's, so pieces keep the stroke's place in the z-order and no two items share a key.
    static func commit(_ session: EraseSession, items: [Item], tx: DocTransaction, doc: DocumentID, page: PageID) throws -> EraseCounts {
        let plan = session.plan
        try remove(plan.remove, among: items, tx: tx, doc: doc, page: page)
        var created = 0
        var top = ""                                   // the highest key handed out so far (splits come in z-order)
        for split in plan.splits {
            let next = items.first { $0.z > split.original.z }?.z
            var last = max(split.original.z, top)
            for stroke in split.strokes {
                var piece = split.original
                piece.id = NibID.make()
                piece.rev = .zero
                piece.deleted = false
                piece.stroke = stroke
                piece.z = FractionalIndex.between(last, next)
                last = piece.z
                try tx.put(piece, doc: doc, page: page)
                created += 1
            }
            top = last
        }
        return EraseCounts(removed: plan.remove.count, created: created)
    }
}

// MARK: - ink.erase

struct InkErase: NibCommand {
    struct Params: Codable {
        var page: String
        var path: [Point]
        var radius: Double
        var mode: EraserMode
        var filter: [InkTool]?
    }
    typealias Output = EraseCounts

    static let descriptor = CommandDescriptor(
        id: "ink.erase", title: "Erase",
        summary: "Erase along a path on a page: precision cuts at the eraser's edge, standard removes touched segments, stroke removes whole strokes. Returns counts.",
        params: .obj(["page": .ref,
                      "path": .arr(.point, "eraser centre line [[x,y],…] in page points (at most \(EraserGeometry.maxPathPoints) points)"),
                      "radius": .num("eraser radius in page points", min: 0.1, max: EraserGeometry.maxRadius),
                      "mode": .str("precision | standard | stroke", choices: EraserMode.allCases.map { $0.rawValue }),
                      "filter": .arr(.str(choices: InkTool.allCases.map { $0.rawValue }),
                                     "ink tools to erase (default all; shapes and connectors count as pen)")],
                     required: ["page", "path", "radius", "mode"]),
        examples: [
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","path":[[100,100],[100,140]],"radius":3,"mode":"standard"}"#),
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","path":[[90,110],[110,135]],"radius":4,"mode":"precision","filter":["pen","highlighter"]}"#),
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","path":[[150,590],[190,610]],"radius":5,"mode":"stroke","filter":["tape"]}"#),
            try! JSONValue.parse(#"{"page":"page:FIXTUREDOC04/FIXTUREBRD01","path":[[-10,60],[10,60]],"radius":4,"mode":"standard"}"#)
        ],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> EraseCounts {
        let (doc, page) = try EraseSupport.pageRef(p.page)
        try EraseSupport.checkLength(p.path, "$.path")
        guard !p.path.isEmpty, p.path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw NibError.invalid("path needs at least one finite [x, y] point", path: "$.path")
        }
        guard p.radius.isFinite, p.radius > 0, p.radius <= EraserGeometry.maxRadius else {
            throw NibError.invalid("radius must be a positive number up to \(Int(EraserGeometry.maxRadius))", path: "$.radius")
        }
        // The geometry runs before `mutate` (ARCHITECTURE §6.1: slow work stays out of transactions).
        let items = try EraseSupport.liveItems(ctx.workspace, doc, page)
        let region = Rect.bounding(p.path)?.insetBy(-p.radius)
        var session = EraseSession(items: items, radius: p.radius, mode: p.mode, filter: Set(p.filter ?? InkTool.allCases),
                                   layer: EraseSupport.layer(ctx), region: region)
        for point in p.path { session.extend(to: point) }
        guard !session.affected.isEmpty else { return .zero }
        return try ctx.mutate { tx in try EraseSupport.commit(session, items: items, tx: tx, doc: doc, page: page) }
    }
}

// MARK: - ink.scribbleErase

struct InkScribbleErase: NibCommand {
    struct Params: Codable {
        var page: String
        var points: [Point]
    }
    typealias Output = EraseCounts

    static let descriptor = CommandDescriptor(
        id: "ink.scribbleErase", title: "Scribble to Erase",
        summary: "Erase the pen and pencil strokes a scribble covers (points = the scribble's path in page points; the scribble is not kept). Returns counts.",
        params: .obj(["page": .ref,
                      "points": .arr(.point, "the scribble's path [[x,y],…] in page points (at most \(EraserGeometry.maxPathPoints) points)")],
                     required: ["page", "points"]),
        examples: [try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","points":[[70,116],[150,118],[70,121],[150,124],[70,127]]}"#)],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> EraseCounts {
        let (doc, page) = try EraseSupport.pageRef(p.page)
        try EraseSupport.checkLength(p.points, "$.points")
        guard p.points.count >= 2, p.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw NibError.invalid("points needs at least two finite [x, y] points", path: "$.points")
        }
        let items = try EraseSupport.liveItems(ctx.workspace, doc, page)
        let layer = EraseSupport.layer(ctx)
        let hull = EraserGeometry.convexHull(p.points)
        let ids = Set(items.filter { item -> Bool in
            guard !item.locked, item.layer == layer, let s = item.stroke,
                  s.style.tool == .pen || s.style.tool == .pencil else { return false }
            return EraserGeometry.scribbleCovers(s, hull: hull)
        }.map { $0.id })
        guard !ids.isEmpty else { return .zero }
        return try ctx.mutate { tx in
            try EraseSupport.remove(ids, among: items, tx: tx, doc: doc, page: page)
            return EraseCounts(removed: ids.count, created: 0)
        }
    }
}

// MARK: - page.clear

struct PageClear: NibCommand {
    struct Params: Codable {
        var page: String
    }
    typealias Output = EraseCounts

    static let descriptor = CommandDescriptor(
        id: "page.clear", title: "Clear Page",
        summary: "Remove every item on a page (ink, shapes, text, images, notes, comments); the page and its background stay. Returns counts.",
        params: .obj(["page": .ref], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"], ["page": "page:FIXTUREDOC04/FIXTUREBRD01"]],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> EraseCounts {
        let (doc, page) = try EraseSupport.pageRef(p.page)
        let items = try EraseSupport.liveItems(ctx.workspace, doc, page)
        guard !items.isEmpty else { return .zero }
        return try ctx.mutate { tx in
            try EraseSupport.remove(Set(items.map { $0.id }), among: items, tx: tx, doc: doc, page: page)
            return EraseCounts(removed: items.count, created: 0)
        }
    }
}

// MARK: - page.deleteItems

/// What `page.deleteItems` accepts (plain constants, outside the main-actor command type).
enum DeletableKinds {
    /// "stroke" (all ink), the ink tools, then every other item kind.
    static let all: [String] = [ItemKind.stroke.rawValue] + InkTool.allCases.map { $0.rawValue }
        + ItemKind.allCases.filter { $0 != .stroke }.map { $0.rawValue }
    static let scopes = ["page", "document"]
}

struct PageDeleteItems: NibCommand {
    struct Params: Codable {
        var doc: String?
        var page: String?
        var kinds: [String]
        var scope: String
    }
    typealias Output = EraseCounts

    static let descriptor = CommandDescriptor(
        id: "page.deleteItems", title: "Delete Specific Items",
        summary: "Delete every item of the chosen kinds on a page or in the whole document (kinds: pen, pencil, highlighter, tape, stroke = all ink, or item kinds). Returns counts.",
        params: .obj(["doc": .ref,
                      "page": .ref,
                      "kinds": .arr(.str(choices: DeletableKinds.all), "what to delete"),
                      "scope": .str("page = one page (page, or the current page of doc); document = every page",
                                    choices: DeletableKinds.scopes)],
                     required: ["kinds", "scope"]),
        examples: [try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG001","kinds":["pen","tape","image"],"scope":"page"}"#),
                   try! JSONValue.parse(#"{"doc":"doc:FIXTUREDOC01","kinds":["shape","sticky"],"scope":"document"}"#)],
        effect: .edit, destructive: true)

    static func matches(_ item: Item, _ kinds: Set<String>) -> Bool {
        if item.kind == .stroke {
            return kinds.contains(ItemKind.stroke.rawValue) || kinds.contains((item.stroke?.style.tool ?? .pen).rawValue)
        }
        return kinds.contains(item.kind.rawValue)
    }

    /// One page's share of a call: its live items and the ids that go.
    typealias Work = (doc: DocumentID, page: PageID, items: [Item], ids: Set<ElementID>)

    /// What a call would delete, from reads only: `run` deletes it and the Delete Specific Items sheet counts it
    /// (no transaction, so counting a large document never tombstones and rolls back every match).
    static func resolve(_ p: Params, workspace: Workspace, session: EditorSession?) throws -> [Work] {
        let kinds = Set(p.kinds)
        guard !kinds.isEmpty else { throw NibError.invalid("choose at least one kind", path: "$.kinds") }
        if let unknown = kinds.subtracting(DeletableKinds.all).sorted().first {
            throw NibError(.invalidParams, "unknown kind '\(unknown)'", path: "$.kinds",
                           hint: "use any of: " + DeletableKinds.all.joined(separator: ", "))
        }
        var targets: [(DocumentID, PageID)] = []
        switch p.scope {
        case "page":
            if let ref = p.page {
                targets = try [EraseSupport.pageRef(ref)]
            } else if let docRef = p.doc, let session = session, let current = session.page,
                      session.document == NodeRef.documentID(from: docRef) {
                targets = [(NodeRef.documentID(from: docRef), current)]
            } else {
                throw NibError(.invalidParams, "scope 'page' needs a page", path: "$.page",
                               hint: "pass page: \"page:D/P\", or use scope: \"document\"")
            }
        case "document":
            let doc: DocumentID
            if let d = p.doc {
                doc = NodeRef.documentID(from: d)
            } else if let ref = p.page {
                doc = try EraseSupport.pageRef(ref).0
            } else {
                throw NibError.invalid("scope 'document' needs doc", path: "$.doc")
            }
            targets = try workspace.content(doc).livePages.map { (doc, $0.id) }
        default:
            throw NibError.invalid("scope must be page or document", path: "$.scope")
        }
        var work: [Work] = []
        for (doc, page) in targets {
            let items = try EraseSupport.liveItems(workspace, doc, page)
            let ids = Set(items.filter { matches($0, kinds) }.map { $0.id })
            if !ids.isEmpty { work.append((doc: doc, page: page, items: items, ids: ids)) }
        }
        return work
    }

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> EraseCounts {
        let work = try resolve(p, workspace: ctx.workspace, session: ctx.activeSession)
        guard !work.isEmpty else { return .zero }
        return try ctx.mutate { tx in
            var removed = 0
            for w in work {
                try EraseSupport.remove(w.ids, among: w.items, tx: tx, doc: w.doc, page: w.page)
                removed += w.ids.count
            }
            return EraseCounts(removed: removed, created: 0)
        }
    }
}
