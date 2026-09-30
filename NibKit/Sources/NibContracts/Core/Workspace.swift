import Foundation

/// Storage behind the workspace. Implemented by the NibStore feature (package files in the library folder);
/// `InMemoryPersistence` is the default and the test double. Main-actor isolated (the workspace calls it on main);
/// implementations snapshot on main and do file I/O on their own queue. Package URLs off-main come from
/// `NibServices.packages` (a thread-safe `PackageLocator`), never from `LibraryService`.
@MainActor
public protocol DocumentPersistence: AnyObject {
    /// Loads and merges the document head from every device file. Throws `not_found`.
    func loadHead(_ doc: DocumentID) throws -> DocumentContent
    /// Loads and merges all items of a page, tombstones included.
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item]
    /// Called on the main actor after every commit/merge. `head` is nil when unchanged; `pages` holds the
    /// full item arrays (tombstones included) of changed pages. Implementations debounce and write off-main.
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]])
    /// Writes pending changes now (page leave, background, close).
    func flush(_ doc: DocumentID)
    /// Absolute URL of a file inside the document package (audio, transcripts); creates parent folders.
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL
    /// Records written by OTHER devices since this device last read them (folder sync). nil = nothing new.
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch?
    /// contracts-v2: true when the document must not be written (saved by a newer format, unreadable files, read-only
    /// package). Commits still apply in memory, but nothing is persisted. Default: false.
    func isReadOnly(_ doc: DocumentID) -> Bool
    /// contracts-v2: the highest revision of a page's items (tombstones included) as stored, WITHOUT loading the items
    /// into memory (thumbnail and index validity checks). nil = unknown (the caller loads the page). Default: nil.
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev?
}

@MainActor
public extension DocumentPersistence {
    func isReadOnly(_ doc: DocumentID) -> Bool { false }
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? { nil }
}

@MainActor
public final class InMemoryPersistence: DocumentPersistence {
    public var heads: [DocumentID: DocumentContent] = [:]
    public var pageItems: [DocumentID: [PageID: [Item]]] = [:]
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-memory-" + UUID().uuidString, isDirectory: true)
    }

    public func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        guard let h = heads[doc] else { throw NibError.notFound("document \(doc)") }
        return h
    }

    public func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        pageItems[doc]?[page] ?? []
    }

    public func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        if let h = head { heads[doc] = h }
        for (p, items) in pages { pageItems[doc, default: [:]][p] = items }
    }

    public func flush(_ doc: DocumentID) {}

    public func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(doc.raw, isDirectory: true).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    public func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }
}

/// In-memory state of open documents. Reads are public; writes happen only inside `DocTransaction`
/// (via `CommandContext.mutate`), undo/redo, and `CommandBus.applyRemote`.
@MainActor
public final class Workspace {
    public let clock: HLCClock
    /// Replace before any document is opened (the NibStore feature does this in `register`).
    public var persistence: DocumentPersistence
    public let events: EventBus
    private var heads: [DocumentID: DocumentContent] = [:]
    private var pageItems: [DocumentID: [PageID: [Item]]] = [:]
    /// id → index into `pageItems[doc][page]`, built lazily and dropped whenever that array is re-sorted or rebuilt,
    /// so replacing one item costs O(1) instead of a scan of the page (contracts-v2).
    private var itemIndex: [DocumentID: [PageID: [ElementID: Int]]] = [:]

    public init(clock: HLCClock, persistence: DocumentPersistence, events: EventBus) {
        self.clock = clock
        self.persistence = persistence
        self.events = events
    }

    // MARK: Reads

    public func content(_ doc: DocumentID) throws -> DocumentContent {
        if let h = heads[doc] { return h }
        let h = try persistence.loadHead(doc)
        clock.observe(h.meta.rev)
        heads[doc] = h
        events.emit(NibEventType.docOpened, doc: doc)
        return h
    }

    /// All items of a page including tombstones, sorted by (z, id).
    public func allItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        if let items = pageItems[doc]?[page] { return items }
        _ = try content(doc)
        let items = Workspace.sortedByZ(try persistence.loadItems(doc, page: page))
        pageItems[doc, default: [:]][page] = items
        itemIndex[doc]?[page] = nil
        return items
    }

    /// Live items of a page in z-order (bottom first).
    public func items(_ doc: DocumentID, page: PageID) throws -> [Item] {
        try allItems(doc, page: page).filter { !$0.deleted }
    }

    /// Live items whose bounds intersect `rect`.
    public func items(_ doc: DocumentID, page: PageID, in rect: Rect) throws -> [Item] {
        try items(doc, page: page).filter { $0.bounds.intersects(rect) }
    }

    public func item(_ doc: DocumentID, page: PageID, id: ElementID) throws -> Item {
        guard let it = try allItems(doc, page: page).first(where: { $0.id == id && !$0.deleted }) else {
            throw NibError.notFound("item \(id) on page \(page)")
        }
        return it
    }

    /// Finds the page holding a live item (loads pages as needed).
    public func page(ofItem id: ElementID, in doc: DocumentID) throws -> PageID? {
        for p in try content(doc).pages {
            if try allItems(doc, page: p.id).contains(where: { $0.id == id && !$0.deleted }) { return p.id }
        }
        return nil
    }

    public var loadedDocuments: [DocumentID] { Array(heads.keys) }
    public func isLoaded(_ doc: DocumentID) -> Bool { heads[doc] != nil }

    /// contracts-v2: true when the page's items are in memory (reading them costs no I/O).
    public func isPageCached(_ doc: DocumentID, page: PageID) -> Bool { pageItems[doc]?[page] != nil }

    /// contracts-v2: pages of `doc` whose items are in memory (e.g. to evict only pages you loaded yourself).
    public func cachedPages(_ doc: DocumentID) -> Set<PageID> { Set(pageItems[doc]?.keys.map { $0 } ?? []) }

    /// contracts-v2: the document head WITHOUT opening it: the loaded head when the document is open, else a fresh
    /// read from persistence that is neither cached nor announced (`doc.opened` is not emitted). For library-wide
    /// scans (favourite and trashed pages, catalogues). Throws `not_found`.
    public func peekContent(_ doc: DocumentID) throws -> DocumentContent {
        if let h = heads[doc] { return h }
        return try persistence.loadHead(doc)
    }

    /// contracts-v2: the highest revision among a page's items (tombstones included): from memory when the page is
    /// cached, else `persistence.contentRevision` (nil = unknown without loading the page). Thumbnail keys, caches.
    public func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? {
        if let items = pageItems[doc]?[page] { return items.map { $0.rev }.max() ?? .zero }
        return persistence.contentRevision(doc, page: page)
    }

    /// contracts-v2: true when persistence refuses to write the document (see `DocumentPersistence.isReadOnly`).
    public func isReadOnly(_ doc: DocumentID) -> Bool { persistence.isReadOnly(doc) }

    /// Flushes and drops a document from memory.
    public func close(_ doc: DocumentID) {
        guard heads[doc] != nil else { return }
        persistence.flush(doc)
        heads[doc] = nil
        pageItems[doc] = nil
        itemIndex[doc] = nil
        events.emit(NibEventType.docClosed, doc: doc)
    }

    /// Memory pressure: drop cached pages except `keeping`.
    public func evictPages(_ doc: DocumentID, keeping: Set<PageID>) {
        persistence.flush(doc)
        guard var cache = pageItems[doc] else { return }
        for key in Array(cache.keys) where !keeping.contains(key) {
            cache[key] = nil
            itemIndex[doc]?[key] = nil
        }
        pageItems[doc] = cache
    }

    static func sortedByZ(_ items: [Item]) -> [Item] {
        items.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
    }

    // MARK: Internal writes (DocTransaction, undo, merge)

    /// Index of `id` in the cached page array (building the page's id index on first use).
    private func position(_ id: ElementID, doc: DocumentID, page: PageID) -> Int? {
        if let i = itemIndex[doc]?[page]?[id] { return i }
        if itemIndex[doc]?[page] != nil { return nil }
        guard let list = pageItems[doc]?[page] else { return nil }
        var index: [ElementID: Int] = [:]
        index.reserveCapacity(list.count)
        for (i, it) in list.enumerated() where index[it.id] == nil { index[it.id] = i }
        itemIndex[doc, default: [:]][page] = index
        return index[id]
    }

    private func resort(_ doc: DocumentID, _ page: PageID) {
        guard let list = pageItems[doc]?[page] else { return }
        pageItems[doc]?[page] = Workspace.sortedByZ(list)
        itemIndex[doc]?[page] = nil
    }

    func currentItem(_ id: ElementID, doc: DocumentID, page: PageID) -> Item? {
        guard (try? allItems(doc, page: page)) != nil, let i = position(id, doc: doc, page: page) else { return nil }
        return pageItems[doc]?[page]?[i]
    }

    @discardableResult
    func writeItem(_ item: Item, doc: DocumentID, page: PageID) throws -> Item? {
        _ = try allItems(doc, page: page)
        if let i = position(item.id, doc: doc, page: page), let old = pageItems[doc]?[page]?[i] {
            pageItems[doc]?[page]?[i] = item
            if old.z != item.z { resort(doc, page) }
            return old
        }
        let last = pageItems[doc]?[page]?.last
        pageItems[doc]?[page]?.append(item)
        if let last = last, (last.z, last.id.raw) > (item.z, item.id.raw) {
            resort(doc, page)
        } else if itemIndex[doc]?[page] != nil, let count = pageItems[doc]?[page]?.count {
            itemIndex[doc]?[page]?[item.id] = count - 1
        }
        return nil
    }

    /// Writes several items of one page (later entries win for repeated ids); returns each write's previous value.
    func writeItems(_ items: [Item], doc: DocumentID, page: PageID) throws -> [Item?] {
        var list = try allItems(doc, page: page)
        pageItems[doc]?[page] = []                      // keep `list` uniquely referenced while it is edited
        var index: [ElementID: Int] = [:]
        index.reserveCapacity(list.count + items.count)
        for (i, it) in list.enumerated() where index[it.id] == nil { index[it.id] = i }
        var olds: [Item?] = []
        olds.reserveCapacity(items.count)
        var needsSort = false
        for item in items {
            if let i = index[item.id] {
                olds.append(list[i])
                if list[i].z != item.z { needsSort = true }
                list[i] = item
            } else {
                if let last = list.last, (last.z, last.id.raw) > (item.z, item.id.raw) { needsSort = true }
                index[item.id] = list.count
                list.append(item)
                olds.append(nil)
            }
        }
        if needsSort {
            pageItems[doc, default: [:]][page] = Workspace.sortedByZ(list)
            itemIndex[doc]?[page] = nil
        } else {
            pageItems[doc, default: [:]][page] = list
            itemIndex[doc, default: [:]][page] = index
        }
        return olds
    }

    func removeItem(_ id: ElementID, doc: DocumentID, page: PageID) {
        pageItems[doc]?[page]?.removeAll { $0.id == id }
        itemIndex[doc]?[page] = nil
    }

    @discardableResult
    func writeRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) throws -> T? {
        _ = try content(doc)
        guard var h = heads.removeValue(forKey: doc) else { throw NibError.notFound("document \(doc)") }
        var old: T?
        if let i = h[keyPath: path].firstIndex(where: { $0.id == record.id }) {
            old = h[keyPath: path][i]
            h[keyPath: path][i] = record
        } else {
            h[keyPath: path].append(record)
        }
        heads[doc] = h
        return old
    }

    /// Writes several records of one kind (later entries win for repeated ids); returns each write's previous value.
    func writeRecords<T: LWWRecord>(_ records: [T], doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) throws -> [T?] {
        _ = try content(doc)
        guard var h = heads.removeValue(forKey: doc) else { throw NibError.notFound("document \(doc)") }
        var list = h[keyPath: path]
        h[keyPath: path] = []
        var index: [NibID: Int] = [:]
        for (i, r) in list.enumerated() where index[r.id] == nil { index[r.id] = i }
        var olds: [T?] = []
        olds.reserveCapacity(records.count)
        for r in records {
            if let i = index[r.id] {
                olds.append(list[i])
                list[i] = r
            } else {
                index[r.id] = list.count
                list.append(r)
                olds.append(nil)
            }
        }
        h[keyPath: path] = list
        heads[doc] = h
        return olds
    }

    /// Rollback support: restores several records of one kind in one pass (`nil` value = remove the record; ids that
    /// are not present are appended in `order`).
    func restoreRecords<T: LWWRecord>(_ values: [NibID: T?], order: [NibID], doc: DocumentID,
                                      at path: WritableKeyPath<DocumentContent, [T]>) {
        guard !values.isEmpty, var h = heads.removeValue(forKey: doc) else { return }
        let list = h[keyPath: path]
        h[keyPath: path] = []
        var out: [T] = []
        out.reserveCapacity(list.count)
        var placed = Set<NibID>()
        for r in list {
            guard let value = values[r.id] else {
                out.append(r)
                continue
            }
            guard let restored = value else { continue }
            out.append(placed.insert(r.id).inserted ? restored : r)
        }
        for id in order where !placed.contains(id) {
            if let value = values[id], let restored = value { out.append(restored) }
        }
        h[keyPath: path] = out
        heads[doc] = h
    }

    func removeRecord<T: LWWRecord>(_ id: NibID, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) {
        guard var h = heads[doc] else { return }
        h[keyPath: path].removeAll { $0.id == id }
        heads[doc] = h
    }

    func currentRecord<T: LWWRecord>(_ id: NibID, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) -> T? {
        (try? content(doc))?[keyPath: path].first { $0.id == id }
    }

    @discardableResult
    func writeMeta(_ meta: DocumentMeta) throws -> DocumentMeta {
        var h = try content(meta.id)
        let old = h.meta
        h.meta = meta
        heads[meta.id] = h
        return old
    }

    /// Hands changed state to persistence.
    func persist(_ cs: Changeset) {
        let itemPages = cs.itemPages
        for doc in cs.documents {
            guard let h = heads[doc] else { continue }
            var pages: [PageID: [Item]] = [:]
            for p in itemPages[doc] ?? [] {
                if let items = pageItems[doc]?[p] { pages[p] = items }
            }
            persistence.didChange(doc, head: cs.headChanged(doc) ? h : nil, pages: pages)
        }
    }

    /// Last-writer-wins merge of a remote patch. Returns the mutations that actually changed state.
    /// Remote revs more than 24 h ahead are distrusted (`Rev.effective`).
    func merge(_ patch: DocumentPatch) throws -> [Mutation] {
        let doc = patch.doc
        var out: [Mutation] = []
        if let m = patch.meta {
            clock.observe(m.rev)
            let current = try content(doc).meta
            if m.rev.effective() > current.rev.effective() {
                let before = try writeMeta(m)
                out.append(.meta(doc, before: before, after: m))
            }
        }
        for r in patch.pages { try mergeRecord(r, doc: doc, at: \.pages, into: &out) { .page(doc, before: $0, after: $1) } }
        for r in patch.outline { try mergeRecord(r, doc: doc, at: \.outline, into: &out) { .outline(doc, before: $0, after: $1) } }
        for r in patch.blocks { try mergeRecord(r, doc: doc, at: \.blocks, into: &out) { .block(doc, before: $0, after: $1) } }
        for r in patch.cards { try mergeRecord(r, doc: doc, at: \.cards, into: &out) { .card(doc, before: $0, after: $1) } }
        for r in patch.audio { try mergeRecord(r, doc: doc, at: \.audio, into: &out) { .audio(doc, before: $0, after: $1) } }
        for (pageRaw, items) in patch.items {
            let page = PageID(pageRaw)
            guard try content(doc).page(page) != nil else { continue }
            for it in items {
                clock.observe(it.rev)
                let current = currentItem(it.id, doc: doc, page: page)
                if let current = current, current.rev.effective() >= it.rev.effective() { continue }
                let before = try writeItem(it, doc: doc, page: page)
                out.append(.item(doc, page, before: before, after: it))
            }
        }
        return out
    }

    private func mergeRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                           into out: inout [Mutation], wrap: (T?, T) -> Mutation) throws {
        clock.observe(record.rev)
        if let current = currentRecord(record.id, doc: doc, at: path), current.rev.effective() >= record.rev.effective() { return }
        let before = try writeRecord(record, doc: doc, at: path)
        out.append(wrap(before, record))
    }
}
