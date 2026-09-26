import Foundation
import os
import NibContracts
import ZIPFoundation

// MARK: - Fragment (the element format)

/// An element's content in the clipboard fragment format (UTI `app.nib.fragment`, shared with F014):
/// `{"format": "nib-fragment/1", "items": [Item], "assets": {name: base64}, "bounds": [x, y, w, h]}`.
/// Stored elements start at the origin; `instantiated` lands them on a page with fresh ids.
struct ElementFragment: Equatable {
    static let format = "nib-fragment/1"
    static let typeIdentifier = "app.nib.fragment"

    var items: [Item]
    /// Asset bytes keyed by the asset name the items reference.
    var assets: [String: Data]
    var bounds: Rect

    init(items: [Item], assets: [String: Data] = [:], bounds: Rect? = nil) {
        self.items = items
        self.assets = assets
        self.bounds = bounds ?? ElementFragment.union(items)
    }

    /// Item kinds in the fragment, sorted ("image", "shape", …).
    var kinds: [String] { Array(Set(items.map { $0.kind.rawValue })).sorted() }

    // MARK: Building

    /// `items` moved so their bounds start at the origin, with provenance and revisions stripped, carrying the bytes
    /// of every asset they reference (`assetData` throws for a missing asset).
    static func make(items: [Item], assetData: (AssetRef) throws -> Data) rethrows -> ElementFragment {
        let b = union(items)
        let move = Affine.translation(-b.minX, -b.minY)
        var assets: [String: Data] = [:]
        var clean: [Item] = []
        clean.reserveCapacity(items.count)
        for item in items {
            var n = item.transformed(by: move)
            n.rev = .zero
            n.createdBy = nil
            n.deleted = false
            for ref in assetRefs(n) where assets[ref.name] == nil {
                assets[ref.name] = try assetData(ref)
            }
            clean.append(n)
        }
        return ElementFragment(items: clean, assets: assets)
    }

    /// The live items `ids` (in that order), then everything attached to them, so a container carries its contents.
    /// Comments are left out: they discuss an object, they are not part of it.
    static func expand(_ ids: [ElementID], in pageItems: [Item]) -> [Item] {
        let live = pageItems.filter { !$0.deleted && $0.kind != .comment }
        var byID: [ElementID: Item] = [:]
        for item in live where byID[item.id] == nil { byID[item.id] = item }
        var chosen = Set<ElementID>()
        var out: [Item] = []
        for id in ids {
            if let item = byID[id], chosen.insert(id).inserted { out.append(item) }
        }
        var grew = !out.isEmpty
        while grew {
            grew = false
            for item in live where !chosen.contains(item.id) {
                if let parent = item.attachedTo, chosen.contains(parent) {
                    chosen.insert(item.id)
                    out.append(item)
                    grew = true
                }
            }
        }
        return out
    }

    // MARK: Landing on a page

    /// The items ready to write: new ids (`ids` in creation order, the rest minted), z keys above `zAfter` in the
    /// fragment's own z order, geometry moved by `transform`, references remapped (`attachedTo` and connector anchors
    /// that point outside the fragment are dropped, the connector end stays where it is), asset names mapped through
    /// `assets`, and `layer` applied when given.
    func instantiated(transform t: Affine, ids: [NibID] = [], zAfter: String?, layer: Int?,
                      assets assetMap: [String: AssetRef] = [:]) -> [Item] {
        var newIDs: [ElementID] = []
        var map: [ElementID: ElementID] = [:]
        for (i, item) in items.enumerated() {
            let fresh = i < ids.count ? ids[i] : NibID.make()
            newIDs.append(fresh)
            if map[item.id] == nil { map[item.id] = fresh }
        }
        let order = items.indices.sorted { a, b in
            (items[a].z, items[a].id.raw, a) < (items[b].z, items[b].id.raw, b)
        }
        let keys = FractionalIndex.sequence(after: zAfter, count: items.count)
        var z = [String](repeating: "", count: items.count)
        for (k, i) in order.enumerated() { z[i] = keys[k] }
        let identity = t == .identity

        var out: [Item] = []
        out.reserveCapacity(items.count)
        for i in items.indices {
            let source = items[i]
            var n = identity ? source : source.transformed(by: t)
            n.id = newIDs[i]
            n.rev = .zero
            n.deleted = false
            n.createdBy = nil
            n.z = z[i]
            n.attachedTo = source.attachedTo.flatMap { map[$0] }
            if var c = n.connector {
                c.from = ElementFragment.remap(c.from, map)
                c.to = ElementFragment.remap(c.to, map)
                n.connector = c
            }
            if var s = n.stroke {
                InkModel.prepare(&s)                  // synthetic (plugin / pack) ink gets nib sizes; captured ink is untouched
                n.stroke = s
            }
            if !assetMap.isEmpty { ElementFragment.mapAssets(&n) { assetMap[$0.name] ?? $0 } }
            n.layer = min(max(layer ?? n.layer, 0), NibLimits.layerCount - 1)
            out.append(n)
        }
        return out
    }

    private static func remap(_ end: ConnectorEnd, _ map: [ElementID: ElementID]) -> ConnectorEnd {
        guard let target = end.item else { return end }
        guard let mapped = map[target] else { return ConnectorEnd(point: end.point) }
        var e = end
        e.item = mapped
        return e
    }

    // MARK: Assets

    /// Rewrites every asset reference an item holds: image, tape pattern, custom display ops and inline text glyphs.
    static func mapAssets(_ item: inout Item, _ f: (AssetRef) -> AssetRef) {
        if var image = item.image {
            image.asset = f(image.asset)
            item.image = image
        }
        if var stroke = item.stroke, let pattern = stroke.style.tapePattern {
            stroke.style.tapePattern = f(pattern)
            item.stroke = stroke
        }
        if var custom = item.custom {
            for i in custom.display.ops.indices {
                if let a = custom.display.ops[i].asset { custom.display.ops[i].asset = f(a) }
            }
            item.custom = custom
        }
        if var text = item.text {
            mapRich(&text.text, f)
            item.text = text
        }
        if var sticky = item.sticky {
            mapRich(&sticky.text, f)
            item.sticky = sticky
        }
        if var shape = item.shape, var label = shape.text {
            mapRich(&label, f)
            shape.text = label
            item.shape = shape
        }
        if var connector = item.connector, var label = connector.label {
            mapRich(&label, f)
            connector.label = label
            item.connector = connector
        }
    }

    private static func mapRich(_ t: inout RichText, _ f: (AssetRef) -> AssetRef) {
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices {
                if let a = t.paragraphs[p].runs[r].attrs.attachment { t.paragraphs[p].runs[r].attrs.attachment = f(a) }
            }
        }
    }

    static func assetRefs(_ item: Item) -> [AssetRef] {
        var out: [AssetRef] = []
        var probe = item
        mapAssets(&probe) { ref in
            if !out.contains(ref) { out.append(ref) }
            return ref
        }
        return out
    }

    // MARK: Helpers

    static func union(_ items: [Item]) -> Rect {
        guard let first = items.first else { return .zero }
        return items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    static func decode(_ data: Data) throws -> ElementFragment {
        do {
            return try JSONDecoder().decode(ElementFragment.self, from: data)
        } catch {
            throw NibError(.invalidParams, "the element could not be read (\(error.localizedDescription))",
                           hint: "elements are nib-fragment/1 JSON, as the clipboard writes it")
        }
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

extension ElementFragment: Codable {
    enum CodingKeys: String, CodingKey { case format, items, assets, bounds }

    /// Lenient: `format` may be left out (content packs, AI JSON); `assets` defaults to none and `bounds` to the union
    /// of the items. A different format version is refused.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let f = try c.decodeIfPresent(String.self, forKey: .format), f != ElementFragment.format {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                                                   debugDescription: "unsupported fragment format '\(f)'; expected \(ElementFragment.format)")
        }
        let items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        var assets: [String: Data] = [:]
        for (name, b64) in try c.decodeIfPresent([String: String].self, forKey: .assets) ?? [:] {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: c, debugDescription: "asset '\(name)' is not base64")
            }
            assets[name] = data
        }
        self.items = items
        self.assets = assets
        self.bounds = try c.decodeIfPresent(Rect.self, forKey: .bounds) ?? ElementFragment.union(items)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ElementFragment.format, forKey: .format)
        try c.encode(items, forKey: .items)
        try c.encode(assets.mapValues { $0.base64EncodedString() }, forKey: .assets)
        try c.encode(bounds, forKey: .bounds)
    }
}

// MARK: - Placement

enum ElementPlacement {
    /// Where an element lands on a page: scaled down to fit 90 % of a fixed-size page (never up), centred on `at`,
    /// else on the visible area, else on the page, and kept inside the page. Boards (no size) are never scaled.
    static func transform(bounds b: Rect, at: Point?, visible: Rect?, page: PageSize?) -> Affine {
        var k = 1.0
        if let s = page, b.width > 0, b.height > 0 {
            k = min(1, 0.9 * s.width / b.width, 0.9 * s.height / b.height)
        }
        let w = b.width * k
        let h = b.height * k
        var c = at ?? visible?.center ?? page.map { Point($0.width / 2, $0.height / 2) } ?? b.center
        if let s = page {
            c.x = min(max(c.x, w / 2), max(w / 2, s.width - w / 2))
            c.y = min(max(c.y, h / 2), max(h / 2, s.height - h / 2))
        }
        return Affine.scale(k, k, about: b.center).concatenating(.translation(c.x - b.midX, c.y - b.midY))
    }
}

// MARK: - Index records (per-device files merged by id and rev)

/// A collection's own record, kept in every `index.<dev>.json` of its folder.
struct CollectionRecord: LWWRecord {
    var id: NibID
    var rev: Rev
    var deleted: Bool
    var title: String
    /// Fractional key: collections are listed by (order, id).
    var order: String

    init(id: NibID, rev: Rev = .zero, deleted: Bool = false, title: String, order: String) {
        self.id = id
        self.rev = rev
        self.deleted = deleted
        self.title = title
        self.order = order
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, title, order }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NibID.self, forKey: .id)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
    }
}

/// One element of a collection. Its content lives in `file` (`<id>.<dev>.json`, written once by the device that made
/// it); the summary fields let lists render without reading any fragment.
struct ElementRecord: LWWRecord {
    var id: NibID
    var rev: Rev
    var deleted: Bool
    var title: String
    var order: String
    var file: String?
    var kinds: [String]
    var count: Int
    /// [width, height] in page points.
    var size: [Double]

    init(id: NibID, rev: Rev = .zero, deleted: Bool = false, title: String, order: String, file: String?,
         kinds: [String] = [], count: Int = 0, size: [Double] = [0, 0]) {
        self.id = id
        self.rev = rev
        self.deleted = deleted
        self.title = title
        self.order = order
        self.file = file
        self.kinds = kinds
        self.count = count
        self.size = size
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, title, order, file, kinds, count, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NibID.self, forKey: .id)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file)
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        size = try c.decodeIfPresent([Double].self, forKey: .size) ?? [0, 0]
    }
}

/// The content of one `index.<dev>.json`: the collection record plus its element records (tombstones included).
struct CollectionIndex: Codable, Equatable {
    static let format = "nib-elements/1"

    var collection: CollectionRecord?
    var elements: [ElementRecord]

    init(collection: CollectionRecord?, elements: [ElementRecord] = []) {
        self.collection = collection
        self.elements = elements
    }

    enum CodingKeys: String, CodingKey { case format, collection, elements }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decodeIfPresent(CollectionRecord.self, forKey: .collection)
        elements = try c.decodeIfPresent([ElementRecord].self, forKey: .elements) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CollectionIndex.format, forKey: .format)
        try c.encodeIfPresent(collection, forKey: .collection)
        try c.encode(elements, forKey: .elements)
    }

    /// Every device file of a folder merged: the collection record and each element by id, the higher rev winning
    /// (`LWW.merge`, far-future revs distrusted).
    static func merge(_ parts: [CollectionIndex]) -> CollectionIndex {
        var collection: [CollectionRecord] = []
        var elements: [ElementRecord] = []
        for part in parts {
            if let c = part.collection { collection = LWW.merge(collection, [c]) }
            elements = LWW.merge(elements, part.elements)
        }
        return CollectionIndex(collection: collection.first, elements: elements)
    }

    var isLive: Bool { collection.map { !$0.deleted } ?? false }

    var liveElements: [ElementRecord] {
        elements.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) }
    }
}

// MARK: - Store (the library's `elements/<collection>/` folders, under NibFormat.libraryDirectory)

/// A starter collection written the first time a library is used (ids are fixed, so two fresh devices merge).
struct StarterCollection {
    let id: String
    let title: String
    let order: String
    let elements: [StarterElement]
}

struct StarterElement {
    let id: String
    let title: String
    let fragment: ElementFragment
}

/// The user's element collections on disk. One folder per collection holding the element fragments
/// (`<element>.<dev>.json`, written once) and one index per device (`index.<dev>.json`, the full merged state that
/// device knows). A device only ever writes its own files; conflict copies of index files are merged, then removed.
/// Synchronous file I/O: run it on `ElementIO.queue` (commands and the popover do).
final class ElementStore {
    static let folderName = "elements"
    static let defaultCollectionID = "my-elements"
    static let maxTitleLength = 120

    let root: URL
    /// This device's file suffix (8 hex digits of the app clock's device id, like `DeviceIdentity.hex`).
    let device: String
    private let tick: () -> Rev
    /// Advances the app clock past revisions read from other devices' files (`HLCClock.observe`), so an edit made
    /// here after reading them always outranks them, even when this device's wall clock runs behind.
    private let observe: (Rev) -> Void
    private var fm: FileManager { FileManager.default }
    private static let log = Logger(subsystem: "app.nib", category: "elements")

    init(metadataURL: URL, device: UInt32, tick: @escaping () -> Rev, observe: @escaping (Rev) -> Void = { _ in }) {
        root = metadataURL.appendingPathComponent(ElementStore.folderName, isDirectory: true)
        self.device = String(format: "%08x", device)
        self.tick = tick
        self.observe = observe
    }

    /// The store of a library on this app's clock.
    convenience init(metadataURL: URL, clock: HLCClock) {
        self.init(metadataURL: metadataURL, device: clock.device, tick: { clock.tick() }, observe: { clock.observe($0) })
    }

    func folder(_ c: String) -> URL { root.appendingPathComponent(c, isDirectory: true) }

    // MARK: File names

    /// `index.<8 hex>.json` or a provider's copy of one ("index.1a2b3c4d 2.json").
    static func isIndexFile(_ name: String) -> Bool {
        name.range(of: #"^index\.[0-9a-f]{8}.*\.json$"#, options: .regularExpression) != nil
    }

    static func isConflictCopy(_ name: String) -> Bool {
        isIndexFile(name) && name.range(of: #"^index\.[0-9a-f]{8}\.json$"#, options: .regularExpression) == nil
    }

    /// A file name from a (possibly synced, untrusted) record that stays inside the collection folder.
    private static func safeFileName(_ name: String?) -> String? {
        guard let n = name, !n.isEmpty, !n.contains("/"), !n.contains("\\"), !n.hasPrefix(".") else { return nil }
        return n
    }

    // MARK: Reading

    /// Collection folders on disk (valid ids only; hidden files and stray names are ignored).
    func collectionIDs() -> [String] {
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { NibID.isValid($0) }
            .sorted()
    }

    /// The merged index of a collection folder (empty when nothing has arrived yet).
    func index(_ c: String) -> CollectionIndex { load(c).index }

    /// The merged index plus the provider conflict copies that were read into it: the only copies a later `write`
    /// may remove (a copy that failed to decode, or arrived after this read, is kept for the next merge).
    func load(_ c: String) -> (index: CollectionIndex, copies: Set<String>) {
        let dir = folder(c)
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { ElementStore.isIndexFile($0) }.sorted()
        var parts: [CollectionIndex] = []
        var copies = Set<String>()
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  var part = try? JSONDecoder().decode(CollectionIndex.self, from: data) else { continue }
            if var record = part.collection {
                record.id = NibID(c)                  // the folder is the collection's identity
                part.collection = record
            }
            parts.append(part)
            if ElementStore.isConflictCopy(name) { copies.insert(name) }
        }
        let merged = CollectionIndex.merge(parts)
        if let r = merged.collection?.rev { observe(r) }
        if let r = merged.elements.lazy.map({ $0.rev }).max() { observe(r) }
        return (merged, copies)
    }

    func isLive(_ c: String) -> Bool { NibID.isValid(c) && index(c).isLive }

    /// Live collections in display order.
    func liveCollections() -> [(record: CollectionRecord, index: CollectionIndex)] {
        collectionIDs().compactMap { c -> (record: CollectionRecord, index: CollectionIndex)? in
            let idx = index(c)
            guard let r = idx.collection, !r.deleted else { return nil }
            return (r, idx)
        }
        .sorted { ($0.record.order, $0.record.id.raw) < ($1.record.order, $1.record.id.raw) }
    }

    /// `load` of a live collection (`not_found` otherwise).
    private func requireLiveLoad(_ c: String) throws -> (index: CollectionIndex, copies: Set<String>) {
        guard NibID.isValid(c) else { throw ElementStore.collectionNotFound(c) }
        let loaded = load(c)
        guard loaded.index.isLive else { throw ElementStore.collectionNotFound(c) }
        return loaded
    }

    /// The fragment bytes of an element: the file its record names, else any device's copy of it.
    func fragmentData(_ c: String, _ record: ElementRecord) throws -> Data {
        let dir = folder(c)
        if let file = ElementStore.safeFileName(record.file), let data = try? Data(contentsOf: dir.appendingPathComponent(file)) {
            return data
        }
        let prefix = record.id.raw + "."
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") && !ElementStore.isIndexFile($0) }
            .sorted()
        for name in names {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) { return data }
        }
        throw NibError(.notFound, "the content of element '\(record.id.raw)' has not arrived on this device yet",
                       hint: "wait for the library to finish syncing, then try again")
    }

    // MARK: Writing

    /// Writes this device's index file, then removes the provider conflict copies `merged` names: those were read into
    /// `index` (see `load`). Any other copy stays until a later read merges it.
    private func write(_ index: CollectionIndex, to c: String, merged: Set<String>) throws {
        let dir = folder(c)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: dir.appendingPathComponent("index.\(device).json"), options: .atomic)
        for name in merged.sorted() where ElementStore.isConflictCopy(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func writeFragment(_ fragment: ElementFragment, id: String, in c: String) throws -> String {
        let dir = folder(c)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "\(id).\(device).json"
        try fragment.encoded().write(to: dir.appendingPathComponent(file), options: .atomic)
        return file
    }

    private func nextOrder() -> String {
        FractionalIndex.between(liveCollections().last?.record.order, nil)
    }

    /// Creates a collection. An id whose collection was deleted is brought back (empty: its elements keep their
    /// tombstones), so a caller can recreate a collection by its own id; only a live collection is a conflict.
    func createCollection(id: String, title: String) throws -> CollectionRecord {
        guard NibID.isValid(id) else { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let lower = id.lowercased()
        // Folder names must also be unique on case-insensitive file systems.
        if let existing = collectionIDs().first(where: { $0.lowercased() == lower }) {
            let loaded = load(existing)
            guard existing == id, !loaded.index.isLive else {
                throw NibError(.conflict, "an element collection with the id '\(id)' already exists",
                               hint: "leave out id to get a new one, or call element.collection.list")
            }
            var idx = loaded.index
            let record = CollectionRecord(id: NibID(id), rev: tick(), title: title, order: nextOrder())
            idx.collection = record
            try write(idx, to: id, merged: loaded.copies)
            return record
        }
        let record = CollectionRecord(id: NibID(id), rev: tick(), title: title, order: nextOrder())
        try write(CollectionIndex(collection: record), to: id, merged: [])
        return record
    }

    /// The default collection, created (or brought back) when something is saved to it.
    func ensureDefaultCollection(title: String) throws {
        let loaded = load(ElementStore.defaultCollectionID)
        guard !loaded.index.isLive else { return }
        var idx = loaded.index
        idx.collection = CollectionRecord(id: NibID(ElementStore.defaultCollectionID), rev: tick(), title: title,
                                          order: nextOrder())
        try write(idx, to: ElementStore.defaultCollectionID, merged: loaded.copies)
    }

    /// Renames and/or moves a collection to `position` (0-based among the live collections).
    func updateCollection(_ c: String, title: String?, position: Int?) throws -> CollectionRecord {
        let loaded = try requireLiveLoad(c)
        var idx = loaded.index
        guard var record = idx.collection else { throw ElementStore.collectionNotFound(c) }
        if let t = title { record.title = t }
        if let p = position {
            let others = liveCollections().map { $0.record }.filter { $0.id.raw != c }
            let i = min(max(p, 0), others.count)
            let before = i > 0 ? others[i - 1].order : nil
            let after = i < others.count ? others[i].order : nil
            if let b = before, let a = after, !(b < a) {
                record.order = FractionalIndex.between(b, nil)       // equal keys (two fresh devices): go after
            } else {
                record.order = FractionalIndex.between(before, after)
            }
        }
        record.rev = tick()
        idx.collection = record
        try write(idx, to: c, merged: loaded.copies)
        return record
    }

    /// Tombstones the collection and every element in it. Fragment files stay (another device's later edit may still
    /// point at them). ponytail: nothing sweeps them; add a sweep of tombstoned folders if libraries grow large.
    func deleteCollection(_ c: String) throws {
        let loaded = try requireLiveLoad(c)
        var idx = loaded.index
        guard var record = idx.collection else { return }
        record.deleted = true
        record.rev = tick()
        idx.collection = record
        for i in idx.elements.indices where !idx.elements[i].deleted {
            idx.elements[i].deleted = true
            idx.elements[i].rev = tick()
        }
        try write(idx, to: c, merged: loaded.copies)
    }

    func addElement(_ c: String, id: String, title: String?, defaultTitle: (Int) -> String,
                    fragment: ElementFragment) throws -> ElementRecord {
        let loaded = try requireLiveLoad(c)
        var idx = loaded.index
        let lower = id.lowercased()
        guard NibID.isValid(id), lower != "index" else {
            throw NibError.invalid("element id must be 1–64 of [A-Za-z0-9_-] and not 'index'", path: "$.id")
        }
        if idx.elements.contains(where: { $0.id.raw.lowercased() == lower }) {
            throw NibError(.conflict, "collection '\(c)' already has an element with the id '\(id)'",
                           hint: "leave out id to get a new one")
        }
        let live = idx.liveElements
        let file = try writeFragment(fragment, id: id, in: c)
        let record = ElementRecord(id: NibID(id), rev: tick(), title: title ?? defaultTitle(live.count + 1),
                                   order: FractionalIndex.between(live.last?.order, nil), file: file,
                                   kinds: fragment.kinds, count: fragment.items.count,
                                   size: [fragment.bounds.width, fragment.bounds.height])
        idx.elements = LWW.merge(idx.elements, [record])
        try write(idx, to: c, merged: loaded.copies)
        return record
    }

    func renameElement(_ c: String, _ e: String, title: String) throws -> ElementRecord {
        let loaded = try requireLiveLoad(c)
        var idx = loaded.index
        guard let i = idx.elements.firstIndex(where: { $0.id.raw == e && !$0.deleted }) else {
            throw ElementStore.elementNotFound(e, in: c)
        }
        idx.elements[i].title = title
        idx.elements[i].rev = tick()
        try write(idx, to: c, merged: loaded.copies)
        return idx.elements[i]
    }

    /// Tombstones an element (its fragment file stays, see `deleteCollection`).
    func deleteElement(_ c: String, _ e: String) throws {
        let loaded = try requireLiveLoad(c)
        var idx = loaded.index
        guard let i = idx.elements.firstIndex(where: { $0.id.raw == e && !$0.deleted }) else {
            throw ElementStore.elementNotFound(e, in: c)
        }
        idx.elements[i].deleted = true
        idx.elements[i].rev = tick()
        try write(idx, to: c, merged: loaded.copies)
    }

    /// Adds an imported `.nibcollection` as a new collection (its own id when free, else a fresh one).
    func importCollection(_ imported: ImportedCollection, fallbackTitle: String) throws -> (record: CollectionRecord, count: Int) {
        let taken = Set(collectionIDs().map { $0.lowercased() })
        var id = NibID.make().raw
        if let wanted = imported.id, NibID.isValid(wanted), !taken.contains(wanted.lowercased()) { id = wanted }
        let rawTitle = (imported.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((rawTitle.isEmpty ? fallbackTitle : rawTitle).prefix(ElementStore.maxTitleLength))
        let record = try createCollection(id: id, title: title)
        let loaded = load(id)
        var idx = loaded.index
        var used = Set<String>()
        let keys = FractionalIndex.sequence(after: nil, count: imported.elements.count)
        for (i, element) in imported.elements.enumerated() {
            var eid = NibID.make().raw
            if let wanted = element.id, NibID.isValid(wanted), wanted.lowercased() != "index",
               !used.contains(wanted.lowercased()) {
                eid = wanted
            }
            used.insert(eid.lowercased())
            let file = try writeFragment(element.fragment, id: eid, in: id)
            let name = element.title.trimmingCharacters(in: .whitespacesAndNewlines)
            idx.elements.append(ElementRecord(id: NibID(eid), rev: tick(),
                                              title: String((name.isEmpty ? "\(i + 1)" : name).prefix(ElementStore.maxTitleLength)),
                                              order: keys[i], file: file, kinds: element.fragment.kinds,
                                              count: element.fragment.items.count,
                                              size: [element.fragment.bounds.width, element.fragment.bounds.height]))
        }
        try write(idx, to: id, merged: loaded.copies)
        return (record, imported.elements.count)
    }

    // MARK: Starter collections

    private static var prepared = Set<String>()
    private static let preparedLock = NSLock()

    /// Starter records carry a floor revision instead of the clock's: every real edit or tombstone, from any device,
    /// outranks them in `LWW.merge`. So a device whose sync has not yet delivered another device's starter files
    /// (it sees no record and writes its own) never brings back a deleted starter or undoes a rename or reorder.
    /// Two fresh devices write equal revisions, which merge deterministically (the first file in name order wins).
    static func starterRev(_ n: Int) -> Rev { Rev(wallMs: 1, counter: UInt32(clamping: n), device: 0) }

    /// First use of a library on this device: writes every starter collection that has no record at all. A deleted
    /// starter keeps its tombstone, so it never comes back; `make` (which renders) runs only when something is missing.
    func ensureStarters(ids: [String], make: () -> [StarterCollection]) {
        let key = root.standardizedFileURL.path + "#" + device
        ElementStore.preparedLock.lock()
        let first = ElementStore.prepared.insert(key).inserted
        ElementStore.preparedLock.unlock()
        guard first else { return }
        let missing = Set(ids.filter { index($0).collection == nil })
        guard !missing.isEmpty else { return }
        for starter in make() where missing.contains(starter.id) {
            do {
                try writeStarter(starter)
            } catch {
                ElementStore.log.error("starter collection \(starter.id, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func writeStarter(_ starter: StarterCollection) throws {
        let loaded = load(starter.id)
        var idx = loaded.index
        let keys = FractionalIndex.sequence(after: nil, count: starter.elements.count)
        for (i, element) in starter.elements.enumerated() {
            let file = try writeFragment(element.fragment, id: element.id, in: starter.id)
            let record = ElementRecord(id: NibID(element.id), rev: ElementStore.starterRev(i + 1), title: element.title,
                                       order: keys[i], file: file, kinds: element.fragment.kinds,
                                       count: element.fragment.items.count,
                                       size: [element.fragment.bounds.width, element.fragment.bounds.height])
            idx.elements = LWW.merge(idx.elements, [record])
        }
        let record = CollectionRecord(id: NibID(starter.id), rev: ElementStore.starterRev(0), title: starter.title,
                                      order: starter.order)
        idx.collection = LWW.merge(idx.collection.map { [$0] } ?? [], [record]).first
        try write(idx, to: starter.id, merged: loaded.copies)
    }

    // MARK: Errors

    static func collectionNotFound(_ c: String) -> NibError {
        NibError(.notFound, "element collection '\(c)' not found", hint: "call element.collection.list for the collection ids")
    }

    static func elementNotFound(_ e: String, in c: String) -> NibError {
        NibError(.notFound, "element '\(e)' not found in collection '\(c)'", hint: "call element.list {collection} for the element ids")
    }
}

// MARK: - Background I/O

/// One serial queue for every element file operation, so read-modify-write of an index never interleaves.
enum ElementIO {
    static let queue = DispatchQueue(label: "app.nib.elements.io", qos: .userInitiated)

    static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Catalog (user collections + read-only content packs)

enum ElementSourceKind: String, Codable {
    case user, plugin
}

struct ElementCollectionInfo: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var count: Int
    /// Content-pack collections (`content.elementCollections`) cannot be changed.
    var readOnly: Bool
    var source: ElementSourceKind
    /// The plugin that contributed a read-only collection.
    var owner: String?
}

struct ElementInfo: Codable, Equatable, Identifiable {
    var id: String
    var collection: String
    var title: String
    var kinds: [String]
    var itemCount: Int
    /// [width, height] in page points.
    var size: [Double]

    /// Unique across collections (search results mix them).
    var key: String { collection + "/" + id }
}

/// Content-pack entries loaded once per catalog snapshot: a pack's `load` decodes every element (base64 assets
/// included), so thumbnails, list pages and exports reuse one load instead of repeating it per element.
final class ElementPackCache {
    private struct Loaded {
        var entries: [ElementEntry]
        var byID: [String: Int]
    }

    private var loaded: [String: Loaded] = [:]
    private let lock = NSLock()

    private func cached(_ id: String) -> Loaded? {
        lock.lock()
        defer { lock.unlock() }
        return loaded[id]
    }

    private func load(_ d: ElementCollectionDescriptor) throws -> Loaded {
        if let hit = cached(d.id) { return hit }
        let entries = try d.load()
        var byID: [String: Int] = [:]
        for (i, e) in entries.enumerated() where byID[e.id] == nil { byID[e.id] = i }
        let fresh = Loaded(entries: entries, byID: byID)
        lock.lock()
        loaded[d.id] = fresh
        lock.unlock()
        return fresh
    }

    func entries(_ d: ElementCollectionDescriptor) throws -> [ElementEntry] { try load(d).entries }

    func entry(_ d: ElementCollectionDescriptor, _ id: String) throws -> ElementEntry? {
        let l = try load(d)
        return l.byID[id].map { l.entries[$0] }
    }
}

/// Snapshot of where elements come from, made on the main actor and used on `ElementIO.queue`.
struct ElementCatalog {
    let store: ElementStore?
    let plugins: [ElementCollectionDescriptor]
    /// Lives as long as this snapshot: the popover makes a new catalog on every reload and registry change.
    let packs = ElementPackCache()

    @MainActor
    init(services: NibServices, clock: HLCClock) {
        if let library = services.library {
            store = ElementStore(metadataURL: library.metadataURL, clock: clock)
        } else {
            store = nil
        }
        plugins = services.get(ElementsRuntime.key, as: ElementsRuntime.self)?.content.elementCollections.all ?? []
    }

    @MainActor
    init(_ ctx: CommandContext) {
        self.init(services: ctx.services, clock: ctx.workspace.clock)
    }

    func requireStore() throws -> ElementStore {
        guard let s = store else { throw NibError.unavailable("the library folder") }
        return s
    }

    /// Writes the starter collections the first time this library is used on this device. A library write: called by
    /// `FeatElementsFeature.start`, the popover and the library commands, never by a read command.
    func prepare() {
        store?.ensureStarters(ids: StarterElements.ids, make: StarterElements.make)
    }

    func plugin(_ id: String) -> ElementCollectionDescriptor? { plugins.first { $0.id == id } }

    /// True for a live user collection (content packs are read-only).
    func isWritable(_ c: String) -> Bool { store?.isLive(c) ?? false }

    func collections() throws -> [ElementCollectionInfo] {
        var out = (store?.liveCollections() ?? []).map { entry in
            ElementCollectionInfo(id: entry.record.id.raw, title: entry.record.title, count: entry.index.liveElements.count,
                                  readOnly: false, source: .user, owner: nil)
        }
        let taken = Set(out.map { $0.id })
        for d in plugins where !taken.contains(d.id) {
            let count = (try? packs.entries(d).count) ?? 0
            out.append(ElementCollectionInfo(id: d.id, title: d.title, count: count, readOnly: true, source: .plugin,
                                             owner: d.owner))
        }
        return out
    }

    func list(_ c: String) throws -> (info: ElementCollectionInfo, elements: [ElementInfo]) {
        if let store = store, NibID.isValid(c) {
            let idx = store.index(c)
            if let record = idx.collection, !record.deleted {
                let live = idx.liveElements
                let info = ElementCollectionInfo(id: c, title: record.title, count: live.count, readOnly: false,
                                                 source: .user, owner: nil)
                return (info, live.map { ElementInfo(id: $0.id.raw, collection: c, title: $0.title, kinds: $0.kinds,
                                                     itemCount: $0.count, size: $0.size) })
            }
        }
        if let d = plugin(c) {
            let entries = try loadPlugin(d)
            let elements = entries.compactMap { entry -> ElementInfo? in
                guard let f = try? entry.fragment.decode(ElementFragment.self) else { return nil }
                return ElementInfo(id: entry.id, collection: c, title: entry.title, kinds: f.kinds,
                                   itemCount: f.items.count, size: [f.bounds.width, f.bounds.height])
            }
            return (ElementCollectionInfo(id: c, title: d.title, count: elements.count, readOnly: true, source: .plugin,
                                          owner: d.owner), elements)
        }
        throw ElementStore.collectionNotFound(c)
    }

    func fragment(_ c: String, _ e: String) throws -> (title: String, fragment: ElementFragment) {
        if let store = store, NibID.isValid(c) {
            let idx = store.index(c)
            if idx.isLive {
                guard let record = idx.liveElements.first(where: { $0.id.raw == e }) else {
                    throw ElementStore.elementNotFound(e, in: c)
                }
                return (record.title, try ElementFragment.decode(try store.fragmentData(c, record)))
            }
        }
        if let d = plugin(c) {
            guard let entry = try loadPluginEntry(d, e) else { throw ElementStore.elementNotFound(e, in: c) }
            do {
                return (entry.title, try entry.fragment.decode(ElementFragment.self))
            } catch {
                throw NibError(.invalidParams, "element '\(e)' of '\(c)' is not a Nib fragment",
                               hint: "the content pack that provides it needs an update")
            }
        }
        throw ElementStore.collectionNotFound(c)
    }

    /// Title and encoded fragments of a collection, for `.nibcollection` export.
    func exportEntries(_ c: String) throws -> (title: String, elements: [(id: String, title: String, data: Data)]) {
        let listed = try list(c)
        var out: [(id: String, title: String, data: Data)] = []
        for e in listed.elements {
            let loaded = try fragment(c, e.id)
            out.append((id: e.id, title: loaded.title, data: try loaded.fragment.encoded()))
        }
        return (listed.info.title, out)
    }

    private func loadPlugin(_ d: ElementCollectionDescriptor) throws -> [ElementEntry] {
        do {
            return try packs.entries(d)
        } catch {
            throw ElementCatalog.packUnreadable(d, error)
        }
    }

    private func loadPluginEntry(_ d: ElementCollectionDescriptor, _ e: String) throws -> ElementEntry? {
        do {
            return try packs.entry(d, e)
        } catch {
            throw ElementCatalog.packUnreadable(d, error)
        }
    }

    private static func packUnreadable(_ d: ElementCollectionDescriptor, _ error: Error) -> NibError {
        NibError(.unavailable, "the content pack collection '\(d.title)' could not be read (\(error.localizedDescription))",
                 hint: "reload or reinstall the plugin '\(d.owner)'")
    }
}

// MARK: - .nibcollection (zip)

struct ImportedElement {
    var id: String?
    var title: String
    var fragment: ElementFragment
}

struct ImportedCollection {
    var id: String?
    var title: String?
    var elements: [ImportedElement]
}

/// `.nibcollection` = a zip (ZIPFoundation) holding `collection.json` ({format, id, title, elements: [{id, title,
/// file}]}) and one fragment per element under `elements/`. Import also takes zips of bare fragment files or of
/// content-pack lists (`[{id, title, fragment}]`, PLUGIN_API.md §5.10).
enum ElementArchive {
    static let fileExtension = "nibcollection"
    static let typeIdentifier = "app.nib.collection"
    static let manifestName = "collection.json"
    static let format = "nib-collection/1"
    static let maxEntryBytes = 32 << 20
    static let maxTotalBytes = 256 << 20
    static let maxElements = 5_000

    struct Manifest: Codable {
        var format: String?
        var id: String?
        var title: String?
        var elements: [Entry]?
    }

    struct Entry: Codable {
        var id: String?
        var title: String?
        var file: String?
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Elements" : cleaned) + "." + fileExtension
    }

    static func write(id: String, title: String, elements: [(id: String, title: String, data: Data)], to url: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("nib-elements-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("elements", isDirectory: true), withIntermediateDirectories: true)
        var entries: [Entry] = []
        var paths = [manifestName]
        for (i, e) in elements.enumerated() {
            // Numbered file names: content-pack ids may hold characters a path must not.
            let path = "elements/\(i + 1).json"
            try e.data.write(to: staging.appendingPathComponent(path))
            entries.append(Entry(id: e.id, title: e.title, file: path))
            paths.append(path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(Manifest(format: format, id: id, title: title, elements: entries))
            .write(to: staging.appendingPathComponent(manifestName))
        try? fm.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for path in paths {
            try archive.addEntry(with: path, relativeTo: staging, compressionMethod: .deflate)
        }
    }

    /// Reads a `.nibcollection` (untrusted): at most `maxElements` JSON files (plus the manifest), none over
    /// `maxEntryBytes` unpacked, all together at most `maxTotalBytes`. The limits are parameters so tests can use
    /// small ones.
    static func read(_ url: URL, maxEntryBytes: Int = ElementArchive.maxEntryBytes,
                     maxTotalBytes: Int = ElementArchive.maxTotalBytes,
                     maxElements: Int = ElementArchive.maxElements) throws -> ImportedCollection {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw NibError(.invalidParams, "not a .nibcollection file (\(error.localizedDescription))",
                           hint: "export a collection from Nib (element.export) and import that file")
        }
        let tooLarge = NibError(.invalidParams, "the collection is too large to import",
                                hint: "split it into smaller collections")
        var files: [String: Data] = [:]
        var total = 0
        for entry in archive where entry.type == .file {
            let path = entry.path
            guard isWanted(path) else { continue }
            guard files.count <= maxElements else {
                throw NibError(.invalidParams, "the collection holds more than \(maxElements) elements",
                               hint: "split it into smaller collections")
            }
            var data = Data()
            var overLimit = false
            do {
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                    total += chunk.count
                    if data.count > maxEntryBytes || total > maxTotalBytes {
                        overLimit = true
                        throw tooLarge
                    }
                }
            } catch {
                if overLimit { throw tooLarge }
                throw NibError(.invalidParams, "the collection file is damaged (\(error.localizedDescription))",
                               hint: "export the collection again and import the new file")
            }
            files[path] = data
        }
        return try parse(files: files)
    }

    /// JSON files only, never outside the archive root, never hidden files or macOS resource forks.
    static func isWanted(_ path: String) -> Bool {
        guard path.hasSuffix(".json"), !path.hasPrefix("/"), !path.hasPrefix("__MACOSX/") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0.hasPrefix(".") }
    }

    static func parse(files: [String: Data]) throws -> ImportedCollection {
        var result: ImportedCollection
        if let m = files[manifestName], let manifest = try? JSONDecoder().decode(Manifest.self, from: m) {
            if let f = manifest.format, !f.hasPrefix("nib-collection/") {
                throw NibError(.invalidParams, "unsupported collection format '\(f)'")
            }
            var elements: [ImportedElement] = []
            for e in manifest.elements ?? [] {
                guard let file = e.file, let data = files[file] else { continue }
                let fragment = try ElementFragment.decode(data)
                guard !fragment.items.isEmpty else { continue }
                elements.append(ImportedElement(id: e.id, title: e.title ?? "", fragment: fragment))
            }
            result = ImportedCollection(id: manifest.id, title: manifest.title, elements: elements)
        } else {
            var elements: [ImportedElement] = []
            for (path, data) in files.sorted(by: { $0.key < $1.key }) where path != manifestName {
                if let list = try? JSONDecoder().decode([ElementEntry].self, from: data) {
                    for entry in list {
                        if let f = try? entry.fragment.decode(ElementFragment.self), !f.items.isEmpty {
                            elements.append(ImportedElement(id: entry.id, title: entry.title, fragment: f))
                        }
                    }
                } else if let f = try? ElementFragment.decode(data), !f.items.isEmpty {
                    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    elements.append(ImportedElement(id: nil, title: name, fragment: f))
                }
            }
            result = ImportedCollection(id: nil, title: nil, elements: elements)
        }
        guard !result.elements.isEmpty else {
            throw NibError(.invalidParams, "the file holds no Nib elements",
                           hint: "export a collection from Nib (element.export) and import that file")
        }
        return result
    }
}
