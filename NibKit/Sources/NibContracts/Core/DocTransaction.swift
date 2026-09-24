import Foundation

/// The ONLY way to change documents. Obtained exclusively inside `CommandContext.mutate { tx in … }`,
/// which runs synchronously on the main actor, so a transaction is atomic. Every write gets a fresh
/// revision and is recorded with its previous value (undo, sync, collaboration, events).
/// If the body throws, or an invariant fails, everything written is rolled back.
@MainActor
public final class DocTransaction {
    public let principal: Principal
    public let group: String
    let workspace: Workspace
    private(set) var mutations: [Mutation] = []

    init(workspace: Workspace, principal: Principal, group: String) {
        self.workspace = workspace
        self.principal = principal
        self.group = group
    }

    // MARK: Reads (see this transaction's own writes)

    public func content(_ doc: DocumentID) throws -> DocumentContent { try workspace.content(doc) }
    public func items(_ doc: DocumentID, page: PageID) throws -> [Item] { try workspace.items(doc, page: page) }
    public func item(_ doc: DocumentID, page: PageID, id: ElementID) throws -> Item { try workspace.item(doc, page: page, id: id) }

    /// A z key above every item on the page.
    public func topZ(_ doc: DocumentID, page: PageID) throws -> String {
        let last = try workspace.allItems(doc, page: page).last?.z
        return FractionalIndex.between(last, nil)
    }

    /// A z key below every item on the page.
    public func bottomZ(_ doc: DocumentID, page: PageID) throws -> String {
        let first = try workspace.allItems(doc, page: page).first?.z
        return FractionalIndex.between(nil, (first?.isEmpty ?? true) ? nil : first)
    }

    // MARK: Writes

    /// Inserts or replaces an item. Empty `z` = keep the existing z, or top of page for new items.
    @discardableResult
    public func put(_ item: Item, doc: DocumentID, page: PageID) throws -> Item {
        var it = item
        guard it.isValid else {
            throw NibError(.invariantViolation, "item \(it.id) must carry exactly the '\(it.kind.rawValue)' payload")
        }
        guard (0..<NibLimits.layerCount).contains(it.layer) else {
            throw NibError.invalid("layer must be 0...\(NibLimits.layerCount - 1)")
        }
        guard try content(doc).page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
        let existing = workspace.currentItem(it.id, doc: doc, page: page)
        if it.z.isEmpty {
            if let z = existing?.z, !z.isEmpty { it.z = z } else { it.z = try topZ(doc, page: page) }
        }
        // Provenance cannot be forged: non-user principals always stamp themselves on create and never change it.
        if let existing = existing {
            if !principal.isUser { it.createdBy = existing.createdBy }
        } else if !principal.isUser || it.createdBy == nil {
            it.createdBy = principal.description
        }
        it.rev = workspace.clock.tick()
        let before = try workspace.writeItem(it, doc: doc, page: page)
        mutations.append(.item(doc, page, before: before, after: it))
        return it
    }

    /// Tombstones an item.
    public func delete(item id: ElementID, doc: DocumentID, page: PageID) throws {
        var it = try workspace.item(doc, page: page, id: id)
        it.deleted = true
        try put(it, doc: doc, page: page)
    }

    /// Inserts or replaces a page record. Empty `order` = append at the end.
    @discardableResult
    public func put(_ page: PageRecord, doc: DocumentID) throws -> PageRecord {
        var p = page
        if let s = p.size, !(1.0...100_000.0).contains(s.width) || !(1.0...100_000.0).contains(s.height) {
            throw NibError.invalid("page size out of range")
        }
        guard [0, 90, 180, 270].contains(p.rotation) else { throw NibError.invalid("rotation must be 0, 90, 180 or 270") }
        if p.order.isEmpty {
            let last = try content(doc).livePages.last?.order
            p.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(p, doc: doc, at: \.pages) { .page(doc, before: $0, after: $1) }
    }

    public func putMeta(_ meta: DocumentMeta) throws {
        var m = meta
        m.rev = workspace.clock.tick()
        let before = try workspace.writeMeta(m)
        mutations.append(.meta(m.id, before: before, after: m))
    }

    @discardableResult
    public func put(_ block: TextBlock, doc: DocumentID) throws -> TextBlock {
        var b = block
        if b.order.isEmpty {
            let last = try content(doc).liveBlocks.last?.order
            b.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(b, doc: doc, at: \.blocks) { .block(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ card: StudyCard, doc: DocumentID) throws -> StudyCard {
        var c = card
        if c.order.isEmpty {
            let last = try content(doc).liveCards.last?.order
            c.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(c, doc: doc, at: \.cards) { .card(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ clip: AudioClip, doc: DocumentID) throws -> AudioClip {
        try putRecord(clip, doc: doc, at: \.audio) { .audio(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ entry: OutlineEntry, doc: DocumentID) throws -> OutlineEntry {
        var e = entry
        if e.order.isEmpty {
            let last = try content(doc).liveOutline.last?.order
            e.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(e, doc: doc, at: \.outline) { .outline(doc, before: $0, after: $1) }
    }

    private func putRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                         wrap: (T?, T) -> Mutation) throws -> T {
        var r = record
        r.rev = workspace.clock.tick()
        let before = try workspace.writeRecord(r, doc: doc, at: path)
        mutations.append(wrap(before, r))
        return r
    }

    // MARK: Commit support (bus only)

    /// Referential invariants checked before commit.
    func validate() throws {
        for m in mutations {
            guard case let .item(doc, page, _, after) = m, !after.deleted else { continue }
            if let parent = after.attachedTo, workspace.currentItem(parent, doc: doc, page: page)?.deleted != false {
                throw NibError(.invariantViolation, "item \(after.id) is attached to missing item \(parent)")
            }
            if let c = after.connector {
                for end in [c.from, c.to] {
                    if let target = end.item, workspace.currentItem(target, doc: doc, page: page)?.deleted != false {
                        throw NibError(.invariantViolation, "connector \(after.id) points at missing item \(target)")
                    }
                }
            }
        }
    }

    /// Restores every record to its exact previous value (revisions included).
    func rollback() {
        for m in mutations.reversed() {
            switch m {
            case let .item(d, p, b, a):
                if let b = b { _ = try? workspace.writeItem(b, doc: d, page: p) } else { workspace.removeItem(a.id, doc: d, page: p) }
            case let .page(d, b, a): restore(b, a.id, d, \.pages)
            case let .meta(_, b, _): _ = try? workspace.writeMeta(b)
            case let .block(d, b, a): restore(b, a.id, d, \.blocks)
            case let .card(d, b, a): restore(b, a.id, d, \.cards)
            case let .audio(d, b, a): restore(b, a.id, d, \.audio)
            case let .outline(d, b, a): restore(b, a.id, d, \.outline)
            }
        }
        mutations.removeAll()
    }

    private func restore<T: LWWRecord>(_ before: T?, _ id: NibID, _ doc: DocumentID, _ path: WritableKeyPath<DocumentContent, [T]>) {
        if let b = before {
            _ = try? workspace.writeRecord(b, doc: doc, at: path)
        } else {
            workspace.removeRecord(id, doc: doc, at: path)
        }
    }

    /// Undo/redo/revert: writes each mutation's `before` (or a tombstone when it was an insert) with a fresh
    /// revision — but only where the record still carries the reverted revision, so later edits by other
    /// devices or collaborators are never overwritten. Returns the number of skipped records.
    func revert(_ muts: [Mutation]) -> Int {
        var skipped = 0
        for m in muts.reversed() {
            switch m {
            case let .item(d, p, b, a):
                guard let cur = workspace.currentItem(a.id, doc: d, page: p), cur.rev == a.rev else {
                    skipped += 1
                    continue
                }
                var target = b ?? a
                if b == nil { target.deleted = true }
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeItem(target, doc: d, page: p)
                mutations.append(.item(d, p, before: cur, after: target))
            case let .page(d, b, a):
                if !revertRecord(b, a, d, \.pages, { .page(d, before: $0, after: $1) }) { skipped += 1 }
            case let .meta(d, b, a):
                guard let cur = try? workspace.content(d).meta, cur.rev == a.rev else {
                    skipped += 1
                    continue
                }
                var target = b
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeMeta(target)
                mutations.append(.meta(d, before: cur, after: target))
            case let .block(d, b, a):
                if !revertRecord(b, a, d, \.blocks, { .block(d, before: $0, after: $1) }) { skipped += 1 }
            case let .card(d, b, a):
                if !revertRecord(b, a, d, \.cards, { .card(d, before: $0, after: $1) }) { skipped += 1 }
            case let .audio(d, b, a):
                if !revertRecord(b, a, d, \.audio, { .audio(d, before: $0, after: $1) }) { skipped += 1 }
            case let .outline(d, b, a):
                if !revertRecord(b, a, d, \.outline, { .outline(d, before: $0, after: $1) }) { skipped += 1 }
            }
        }
        return skipped
    }

    private func revertRecord<T: LWWRecord>(_ before: T?, _ after: T, _ doc: DocumentID,
                                            _ path: WritableKeyPath<DocumentContent, [T]>,
                                            _ wrap: (T?, T) -> Mutation) -> Bool {
        guard let cur = workspace.currentRecord(after.id, doc: doc, at: path), cur.rev == after.rev else { return false }
        var target = before ?? after
        if before == nil { target.deleted = true }
        target.rev = workspace.clock.tick()
        _ = try? workspace.writeRecord(target, doc: doc, at: path)
        mutations.append(wrap(cur, target))
        return true
    }
}
