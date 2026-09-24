import Foundation

/// Node refs touched by a change (what events carry; subscribers query for details).
public struct ChangeSummary: Codable, Equatable {
    public var created: [String]
    public var updated: [String]
    public var removed: [String]

    public init(created: [String] = [], updated: [String] = [], removed: [String] = []) {
        self.created = created
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool { created.isEmpty && updated.isEmpty && removed.isEmpty }
    public var count: Int { created.count + updated.count + removed.count }
    public var all: [String] { created + updated + removed }

    public mutating func merge(_ other: ChangeSummary) {
        var seen = Set(all)
        for r in other.created where seen.insert(r).inserted { created.append(r) }
        for r in other.updated where seen.insert(r).inserted { updated.append(r) }
        for r in other.removed where seen.insert(r).inserted { removed.append(r) }
    }
}

/// One record write with its previous value (nil = inserted). The only mutation primitive.
public enum Mutation {
    case item(DocumentID, PageID, before: Item?, after: Item)
    case page(DocumentID, before: PageRecord?, after: PageRecord)
    case meta(DocumentID, before: DocumentMeta, after: DocumentMeta)
    case block(DocumentID, before: TextBlock?, after: TextBlock)
    case card(DocumentID, before: StudyCard?, after: StudyCard)
    case audio(DocumentID, before: AudioClip?, after: AudioClip)
    case outline(DocumentID, before: OutlineEntry?, after: OutlineEntry)

    public var document: DocumentID {
        switch self {
        case .item(let d, _, _, _), .page(let d, _, _), .meta(let d, _, _), .block(let d, _, _),
             .card(let d, _, _), .audio(let d, _, _), .outline(let d, _, _):
            return d
        }
    }

    /// Ref of the written record and whether the write created or removed it (tombstone transitions).
    public var change: (ref: String, created: Bool, removed: Bool) {
        func classify(_ beforeDeleted: Bool?, _ afterDeleted: Bool) -> (Bool, Bool) {
            let wasLive = beforeDeleted.map { !$0 } ?? false
            return (!wasLive && !afterDeleted, wasLive && afterDeleted)
        }
        switch self {
        case let .item(d, p, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.item(d, p, a.id).description, c.0, c.1)
        case let .page(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.page(d, a.id).description, c.0, c.1)
        case let .meta(d, _, _):
            return (NodeRef.document(d).description, false, false)
        case let .block(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.block(d, a.id).description, c.0, c.1)
        case let .card(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.card(d, a.id).description, c.0, c.1)
        case let .audio(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.audio(d, a.id).description, c.0, c.1)
        case let .outline(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.outline(d, a.id).description, c.0, c.1)
        }
    }
}

/// A committed transaction (or a merged remote patch). Observers use it to invalidate tiles, indexes, etc.
public struct Changeset {
    public let id: UUID
    /// Monotonic per app run.
    public let seq: UInt64
    public let principal: Principal
    /// Undo group: all changes of one command, one plugin call or one AI turn share a group.
    public let group: String
    public let label: String
    public let command: String
    public let mutations: [Mutation]

    public init(id: UUID = UUID(), seq: UInt64, principal: Principal, group: String, label: String, command: String, mutations: [Mutation]) {
        self.id = id
        self.seq = seq
        self.principal = principal
        self.group = group
        self.label = label
        self.command = command
        self.mutations = mutations
    }

    public static func summarize(_ mutations: [Mutation]) -> ChangeSummary {
        var s = ChangeSummary()
        var seen = Set<String>()
        for m in mutations {
            let c = m.change
            guard seen.insert(c.ref).inserted else { continue }
            if c.created {
                s.created.append(c.ref)
            } else if c.removed {
                s.removed.append(c.ref)
            } else {
                s.updated.append(c.ref)
            }
        }
        return s
    }

    public var summary: ChangeSummary { Changeset.summarize(mutations) }
    public func summary(for doc: DocumentID) -> ChangeSummary { Changeset.summarize(mutations.filter { $0.document == doc }) }
    public var documents: Set<DocumentID> { Set(mutations.map { $0.document }) }

    /// True when the document head (meta, page table, outline, blocks, cards, audio) changed.
    public func headChanged(_ doc: DocumentID) -> Bool {
        mutations.contains { m in
            if case .item = m { return false }
            return m.document == doc
        }
    }

    /// Pages whose items changed, per document.
    public var itemPages: [DocumentID: Set<PageID>] {
        var out: [DocumentID: Set<PageID>] = [:]
        for m in mutations {
            if case let .item(d, p, _, _) = m { out[d, default: []].insert(p) }
        }
        return out
    }

    /// Union of before/after bounds of items changed on a page (for tile invalidation); nil if none.
    public func dirtyRect(doc: DocumentID, page: PageID) -> Rect? {
        var r: Rect?
        for m in mutations {
            guard case let .item(d, p, b, a) = m, d == doc, p == page else { continue }
            var u = a.bounds
            if let b = b { u = u.union(b.bounds) }
            r = r.map { $0.union(u) } ?? u
        }
        return r
    }

    /// The after-values for one document, as sent to collaborators.
    public func patch(for doc: DocumentID) -> DocumentPatch {
        var p = DocumentPatch(doc: doc)
        for m in mutations where m.document == doc {
            switch m {
            case let .item(_, page, _, a): p.items[page.raw, default: []].append(a)
            case let .page(_, _, a): p.pages.append(a)
            case let .meta(_, _, a): p.meta = a
            case let .block(_, _, a): p.blocks.append(a)
            case let .card(_, _, a): p.cards.append(a)
            case let .audio(_, _, a): p.audio.append(a)
            case let .outline(_, _, a): p.outline.append(a)
            }
        }
        return p
    }
}

/// Records to merge last-writer-wins (sync, collaboration, per-device package files).
public struct DocumentPatch: Codable {
    public var doc: DocumentID
    public var meta: DocumentMeta?
    public var pages: [PageRecord]
    /// PageID raw value → items.
    public var items: [String: [Item]]
    public var outline: [OutlineEntry]
    public var blocks: [TextBlock]
    public var cards: [StudyCard]
    public var audio: [AudioClip]

    public init(doc: DocumentID, meta: DocumentMeta? = nil, pages: [PageRecord] = [], items: [String: [Item]] = [:],
                outline: [OutlineEntry] = [], blocks: [TextBlock] = [], cards: [StudyCard] = [], audio: [AudioClip] = []) {
        self.doc = doc
        self.meta = meta
        self.pages = pages
        self.items = items
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
    }

    public var isEmpty: Bool {
        meta == nil && pages.isEmpty && items.isEmpty && outline.isEmpty && blocks.isEmpty && cards.isEmpty && audio.isEmpty
    }
}
