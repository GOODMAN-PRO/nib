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
        try putItem(item, doc: doc, page: page, inherited: nil)
    }

    /// contracts-v2: inserts or replaces `item` on `page`, keeping the provenance (`createdBy`) of the STORED record with
    /// the same id on `sourcePage` (of `sourceDoc`, default `doc`; live or tombstoned) instead of stamping the principal.
    /// For moves and copies of an existing record across pages or documents (`node.move`, `item.moveToPage`,
    /// `page.moveTo`): the AI moving the user's handwriting keeps it the user's. The value is read from storage, never
    /// from params, so it cannot be forged; throws `not_found` when no such record exists. `move(item:doc:from:to:)`
    /// does a whole same-document move.
    @discardableResult
    public func put(_ item: Item, doc: DocumentID, page: PageID, keepingProvenanceFrom sourcePage: PageID,
                    in sourceDoc: DocumentID? = nil) throws -> Item {
        guard let source = workspace.currentItem(item.id, doc: sourceDoc ?? doc, page: sourcePage) else {
            throw NibError.notFound("item \(item.id) on page \(sourcePage)")
        }
        return try putItem(item, doc: doc, page: page, inherited: .some(source.createdBy))
    }

    /// contracts-v2: moves a live item to another page of the same document in one step: tombstones it on `source` and
    /// writes it on `target` with the same id and its provenance kept (see `put(_:doc:page:keepingProvenanceFrom:in:)`),
    /// optionally transformed. Empty `z` = top of the target page. `attachedTo` and connector anchors that do not
    /// resolve to a live item on the target page are dropped (connector ends keep their points), so the transaction
    /// still validates. `source == target` is a plain update. Returns the written item.
    @discardableResult
    public func move(item id: ElementID, doc: DocumentID, from source: PageID, to target: PageID,
                     transform: Affine? = nil, z: String = "") throws -> Item {
        let original = try workspace.item(doc, page: source, id: id)
        var moved = transform.map { original.transformed(by: $0) } ?? original
        if source == target {
            if !z.isEmpty { moved.z = z }
            return try put(moved, doc: doc, page: target)
        }
        guard try content(doc).page(target) != nil else { throw NibError.notFound("page \(target) in document \(doc)") }
        try delete(item: id, doc: doc, page: source)
        moved.z = z
        moved.deleted = false
        func live(_ other: ElementID?) -> Bool {
            guard let other = other else { return false }
            return workspace.currentItem(other, doc: doc, page: target)?.deleted == false
        }
        if moved.attachedTo != nil && !live(moved.attachedTo) { moved.attachedTo = nil }
        if var c = moved.connector {
            if c.from.item != nil && !live(c.from.item) { c.from = ConnectorEnd(point: c.from.point) }
            if c.to.item != nil && !live(c.to.item) { c.to = ConnectorEnd(point: c.to.point) }
            moved.connector = c
        }
        return try putItem(moved, doc: doc, page: target, inherited: .some(original.createdBy))
    }

    /// contracts-v2: inserts or replaces many items on one page in one pass (O(n) lookups, one sort), with the same
    /// rules as `put(_:doc:page:)` applied to each in order (z, provenance, validation). For page-wide edits (erase,
    /// clear, import, paste, board templates) near `NibLimits.boardItemLimit`, where per-item puts are quadratic.
    @discardableResult
    public func put(_ items: [Item], doc: DocumentID, page: PageID) throws -> [Item] {
        guard !items.isEmpty else { return [] }
        guard try content(doc).page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
        let current = try workspace.allItems(doc, page: page)
        var byID: [ElementID: Item] = [:]
        for it in current { byID[it.id] = it }
        let valid = try items.map { try checked($0) }
        // Items that get a fresh z on top: empty z, first occurrence, and not already on the page with a z. Each run of
        // them takes balanced keys (short, see FractionalIndex.balanced) after the top at the run's start.
        var seen = Set<ElementID>()
        let fresh = valid.map { it -> Bool in
            let first = seen.insert(it.id).inserted
            return it.z.isEmpty && first && (byID[it.id]?.z ?? "").isEmpty
        }
        var top = current.last?.z
        var runKeys: ArraySlice<String> = []
        var prepared: [Item] = []
        prepared.reserveCapacity(items.count)
        for i in valid.indices {
            var it = valid[i]
            let existing = byID[it.id]
            if it.z.isEmpty {
                if fresh[i] {
                    if runKeys.isEmpty {
                        var j = i
                        while j < fresh.count, fresh[j] { j += 1 }
                        runKeys = FractionalIndex.balanced(count: j - i, after: top)[...]
                    }
                    it.z = runKeys.removeFirst()
                } else if let z = existing?.z, !z.isEmpty {
                    it.z = z
                } else {
                    it.z = FractionalIndex.between(top, nil)
                }
            }
            if top.map({ it.z > $0 }) ?? true { top = it.z }
            stampProvenance(&it, existing: existing, inherited: nil)
            it.rev = workspace.clock.tick()
            byID[it.id] = it
            prepared.append(it)
        }
        let befores = try workspace.writeItems(prepared, doc: doc, page: page)
        for (b, a) in zip(befores, prepared) { mutations.append(.item(doc, page, before: b, after: a)) }
        return prepared
    }

    /// contracts-v2: tombstones many live items of one page in one pass (duplicates ignored). Throws `not_found`, and
    /// writes nothing, when an id is not a live item of the page.
    public func delete(items ids: [ElementID], doc: DocumentID, page: PageID) throws {
        var byID: [ElementID: Item] = [:]
        for it in try workspace.allItems(doc, page: page) { byID[it.id] = it }
        var seen = Set<ElementID>()
        var tombstones: [Item] = []
        for id in ids where seen.insert(id).inserted {
            guard var it = byID[id], !it.deleted else { throw NibError.notFound("item \(id) on page \(page)") }
            it.deleted = true
            tombstones.append(it)
        }
        try put(tombstones, doc: doc, page: page)
    }

    private func checked(_ item: Item) throws -> Item {
        guard item.isValid else {
            throw NibError(.invariantViolation, "item \(item.id) must carry exactly the '\(item.kind.rawValue)' payload")
        }
        guard (0..<NibLimits.layerCount).contains(item.layer) else {
            throw NibError.invalid("layer must be 0...\(NibLimits.layerCount - 1)")
        }
        return item
    }

    /// Provenance cannot be forged: non-user principals always stamp themselves on create and never change it;
    /// `inherited` (a stored record's `createdBy`, for moves) wins over both.
    private func stampProvenance(_ it: inout Item, existing: Item?, inherited: String??) {
        if let kept = inherited {
            it.createdBy = kept
        } else if let existing = existing {
            if !principal.isUser { it.createdBy = existing.createdBy }
        } else if !principal.isUser || it.createdBy == nil {
            it.createdBy = principal.description
        }
    }

    private func putItem(_ item: Item, doc: DocumentID, page: PageID, inherited: String??) throws -> Item {
        var it = try checked(item)
        guard try content(doc).page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
        let existing = workspace.currentItem(it.id, doc: doc, page: page)
        if it.z.isEmpty {
            if let z = existing?.z, !z.isEmpty { it.z = z } else { it.z = try topZ(doc, page: page) }
        }
        stampProvenance(&it, existing: existing, inherited: inherited)
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

    /// contracts-v2: inserts or replaces many blocks in one pass (empty `order` = appended in array order).
    @discardableResult
    public func put(_ blocks: [TextBlock], doc: DocumentID) throws -> [TextBlock] {
        try putOrdered(blocks, doc: doc, at: \.blocks, last: try content(doc).liveBlocks.last?.order) {
            .block(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many cards in one pass (empty `order` = appended in array order), so an
    /// importer appending thousands of cards to a set is linear, not quadratic.
    @discardableResult
    public func put(_ cards: [StudyCard], doc: DocumentID) throws -> [StudyCard] {
        try putOrdered(cards, doc: doc, at: \.cards, last: try content(doc).liveCards.last?.order) {
            .card(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many pages in one pass (empty `order` = appended in array order). Every page is
    /// validated first; nothing is written when one is invalid.
    @discardableResult
    public func put(_ pages: [PageRecord], doc: DocumentID) throws -> [PageRecord] {
        for p in pages {
            if let s = p.size, !(1.0...100_000.0).contains(s.width) || !(1.0...100_000.0).contains(s.height) {
                throw NibError.invalid("page size out of range")
            }
            guard [0, 90, 180, 270].contains(p.rotation) else { throw NibError.invalid("rotation must be 0, 90, 180 or 270") }
        }
        return try putOrdered(pages, doc: doc, at: \.pages, last: try content(doc).livePages.last?.order) {
            .page(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many outline entries in one pass (empty `order` = appended in array order).
    @discardableResult
    public func put(_ entries: [OutlineEntry], doc: DocumentID) throws -> [OutlineEntry] {
        try putOrdered(entries, doc: doc, at: \.outline, last: try content(doc).liveOutline.last?.order) {
            .outline(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many audio clips in one pass.
    @discardableResult
    public func put(_ clips: [AudioClip], doc: DocumentID) throws -> [AudioClip] {
        guard !clips.isEmpty else { return [] }
        var prepared = clips
        for i in prepared.indices { prepared[i].rev = workspace.clock.tick() }
        let befores = try workspace.writeRecords(prepared, doc: doc, at: \.audio)
        for (b, a) in zip(befores, prepared) { mutations.append(.audio(doc, before: b, after: a)) }
        return prepared
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

    private func putOrdered<T: OrderedRecord>(_ records: [T], doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                              last: String?, wrap: (T?, T) -> Mutation) throws -> [T] {
        guard !records.isEmpty else { return [] }
        var top = last
        var runKeys: ArraySlice<String> = []
        var prepared: [T] = []
        prepared.reserveCapacity(records.count)
        for i in records.indices {
            var r = records[i]
            if r.order.isEmpty {
                // Each run of records without an order takes balanced keys after the top at the run's start.
                if runKeys.isEmpty {
                    var j = i
                    while j < records.count, records[j].order.isEmpty { j += 1 }
                    runKeys = FractionalIndex.balanced(count: j - i, after: top)[...]
                }
                r.order = runKeys.removeFirst()
            }
            if top.map({ r.order > $0 }) ?? true { top = r.order }
            r.rev = workspace.clock.tick()
            prepared.append(r)
        }
        let befores = try workspace.writeRecords(prepared, doc: doc, at: path)
        for (b, a) in zip(befores, prepared) { mutations.append(wrap(b, a)) }
        return prepared
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
    /// contracts-v2: consecutive record writes of one kind are restored in one pass (a failed 10,000-card import rolls
    /// back in linear time).
    func rollback() {
        let ordered = Array(mutations.reversed())
        var i = 0
        while i < ordered.count {
            let m = ordered[i]
            switch m {
            case let .item(d, p, b, a):
                if let b = b { _ = try? workspace.writeItem(b, doc: d, page: p) } else { workspace.removeItem(a.id, doc: d, page: p) }
                i += 1
            case let .meta(_, b, _):
                _ = try? workspace.writeMeta(b)
                i += 1
            case let .page(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.pages) { if case let .page(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .block(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.blocks) { if case let .block(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .card(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.cards) { if case let .card(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .audio(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.audio) { if case let .audio(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .outline(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.outline) { if case let .outline(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            }
        }
        mutations.removeAll()
    }

    /// End (exclusive) of the run of mutations starting at `start` that write the same record kind of the same document.
    private func runEnd(_ muts: [Mutation], from start: Int) -> Int {
        let first = muts[start].recordKey
        var j = start + 1
        while j < muts.count {
            let k = muts[j].recordKey
            guard k.kind == first.kind, k.doc == first.doc else { break }
            j += 1
        }
        return j
    }

    /// Rollback of one run (newest first): each record ends at the `before` of its OLDEST write in the run.
    private func restoreRun<T: LWWRecord>(_ run: ArraySlice<Mutation>, _ doc: DocumentID,
                                          _ path: WritableKeyPath<DocumentContent, [T]>,
                                          _ unwrap: (Mutation) -> (T?, T)?) {
        var finals: [NibID: T?] = [:]
        var order: [NibID] = []
        for m in run {
            guard let write = unwrap(m) else { continue }
            if finals.updateValue(write.0, forKey: write.1.id) == nil { order.append(write.1.id) }
        }
        workspace.restoreRecords(finals, order: order, doc: doc, at: path)
    }

    /// Revisions this transaction's reverts re-stamped (see `RevRebase`); the bus applies them to the undo history.
    private(set) var rebase = RevRebase()

    /// Undo/redo/revert: writes each mutation's `before` (or a tombstone when it was an insert) with a fresh
    /// revision — but only where the record still carries the reverted revision, so later edits by other
    /// devices or collaborators are never overwritten. Returns the number of skipped records.
    ///
    /// contracts-v2 fix: a record written several times in one undo group (drag then attach, debounced text commits)
    /// is reverted all the way back. Reverting the newest write re-stamps the record, and the older write of the same
    /// record now accepts that fresh revision (`RevRebase`), instead of looking changed-since and being skipped.
    /// contracts-v2: consecutive record writes of one kind (a batch `put(_ cards:)`) are reverted in one pass, so
    /// undoing a large import is linear.
    func revert(_ muts: [Mutation]) -> Int {
        var skipped = 0
        let ordered = Array(muts.reversed())
        var i = 0
        while i < ordered.count {
            let m = ordered[i]
            let key = m.recordKey
            let expected = rebase.current(key, m.afterRev)
            switch m {
            case let .item(d, p, b, a):
                i += 1
                guard let cur = workspace.currentItem(a.id, doc: d, page: p), cur.rev == expected else {
                    skipped += 1
                    continue
                }
                var target = b ?? a
                if b == nil { target.deleted = true }
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeItem(target, doc: d, page: p)
                mutations.append(.item(d, p, before: cur, after: target))
                if let b = b { rebase.record(key, old: b.rev, new: target.rev) }
            case let .meta(d, b, _):
                i += 1
                guard let cur = try? workspace.content(d).meta, cur.rev == expected else {
                    skipped += 1
                    continue
                }
                var target = b
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeMeta(target)
                mutations.append(.meta(d, before: cur, after: target))
                rebase.record(key, old: b.rev, new: target.rev)
            case let .page(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.pages, { if case let .page(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .page(d, before: $0, after: $1) })
                i = j
            case let .block(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.blocks, { if case let .block(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .block(d, before: $0, after: $1) })
                i = j
            case let .card(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.cards, { if case let .card(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .card(d, before: $0, after: $1) })
                i = j
            case let .audio(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.audio, { if case let .audio(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .audio(d, before: $0, after: $1) })
                i = j
            case let .outline(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.outline, { if case let .outline(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .outline(d, before: $0, after: $1) })
                i = j
            }
        }
        return skipped
    }

    /// Reverts one run (newest first) of record writes of one kind and document: current values are looked up once,
    /// the run is checked in order exactly like single reverts (so double writes rebase), then written in one pass.
    private func revertRun<T: LWWRecord>(_ run: ArraySlice<Mutation>, _ doc: DocumentID,
                                         _ path: WritableKeyPath<DocumentContent, [T]>,
                                         _ unwrap: (Mutation) -> (T?, T)?, _ wrap: (T?, T) -> Mutation) -> Int {
        var current: [NibID: T] = [:]
        if let list = try? workspace.content(doc)[keyPath: path] {
            var wanted = Set<NibID>()
            for m in run { if let write = unwrap(m) { wanted.insert(write.1.id) } }
            for r in list where wanted.contains(r.id) && current[r.id] == nil { current[r.id] = r }
        }
        var skipped = 0
        var targets: [T] = []
        for m in run {
            guard let write = unwrap(m) else { continue }
            let (before, after) = write
            let key = m.recordKey
            guard let cur = current[after.id], cur.rev == rebase.current(key, m.afterRev) else {
                skipped += 1
                continue
            }
            var target = before ?? after
            if before == nil { target.deleted = true }
            target.rev = workspace.clock.tick()
            current[after.id] = target
            targets.append(target)
            mutations.append(wrap(cur, target))
            if let b = before { rebase.record(key, old: b.rev, new: target.rev) }
        }
        if !targets.isEmpty { _ = try? workspace.writeRecords(targets, doc: doc, at: path) }
        return skipped
    }
}

/// Records kept in a fractional `order` key (batch puts append in array order).
protocol OrderedRecord: LWWRecord {
    var order: String { get set }
}

extension TextBlock: OrderedRecord {}
extension StudyCard: OrderedRecord {}
extension PageRecord: OrderedRecord {}
extension OutlineEntry: OrderedRecord {}
