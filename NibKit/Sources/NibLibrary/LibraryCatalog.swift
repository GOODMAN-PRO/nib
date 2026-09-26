import Foundation
import NibContracts

// MARK: - Layout of the library folder

/// File names of the library folder (ARCHITECTURE §4.1). Documents are `*.nibnote` packages holding one
/// `doc.<dev>.json` head per device, folders are directories holding one `.nibfolder.<dev>.json` record per device,
/// and the hidden `.nib-library` directory holds the Trash and the synced prefs. Every per-device file may also exist
/// as a provider conflict copy (`doc.1a2b3c4d 2.json`), which readers merge like any other device file.
enum LibraryLayout {
    static let trashDirectory = "trash"
    static let headPrefix = "doc."
    static let folderPrefix = ".nibfolder."
    static let prefsPrefix = "prefs."
    static let jsonSuffix = ".json"
    /// iCloud Drive placeholder of an evicted item: `.<name>.icloud`.
    static let placeholderSuffix = ".icloud"
    /// iOS drops files opened from other apps into Documents/Inbox; it is not part of the library.
    static let inboxName = "Inbox"
    /// `DocumentMeta.ext` keys the library keeps on a trashed document next to `meta.trashedFrom`.
    static let trashedAtKey = "library.trashedAt"
    static let trashedFromFolderKey = "library.trashedFromFolder"

    static func headFileName(_ device: String) -> String { headPrefix + device + jsonSuffix }
    static func folderFileName(_ device: String) -> String { folderPrefix + device + jsonSuffix }
    static func prefsFileName(_ device: String) -> String { prefsPrefix + device + jsonSuffix }

    /// The device of a per-device file `<prefix><8 hex>…<suffix>`: `exact` for the device's own file name, false for a
    /// provider conflict copy (`doc.1a2b3c4d 2.json`, `doc.1a2b3c4d (conflicted copy).json`). nil = not such a file.
    static func device(of name: String, prefix: String, suffix: String = jsonSuffix) -> (hex: String, exact: Bool)? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard body.count >= 8 else { return nil }
        let hex = body.prefix(8)
        guard hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return (String(hex), body.count == 8)
    }

    static func isHeadFile(_ name: String) -> Bool { device(of: name, prefix: headPrefix) != nil }
    static func isFolderFile(_ name: String) -> Bool { device(of: name, prefix: folderPrefix) != nil }
    static func isPrefsFile(_ name: String) -> Bool { device(of: name, prefix: prefsPrefix) != nil }

    /// Library-relative path of the Trash.
    static var trashPath: String { NibFormat.libraryDirectory + "/" + trashDirectory }

    /// The containing directory of a library-relative path ("" = the library root).
    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// `child` is `path` itself or lies inside it.
    static func isWithin(_ child: String, _ path: String) -> Bool {
        child == path || child.hasPrefix(path + "/")
    }
}

// MARK: - Identifiers

enum LibraryIDs {
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 64-bit FNV-1a of `seed`.
    static func fnv(_ seed: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// A stable id derived from a seed (a library path): folders without a `.nibfolder` record, unreadable packages and
    /// second copies of a document id. Every device derives the same id for the same path.
    static func derived(_ seed: String) -> NibID {
        var h = fnv(seed)
        var chars: [Character] = []
        chars.reserveCapacity(12)
        for _ in 0..<12 {
            chars.append(alphabet[Int(h & 31)])
            h >>= 5
        }
        return NibID(String(chars))
    }

    /// 16 hex characters naming a per-root cache file.
    static func key(_ seed: String) -> String { String(format: "%016llx", fnv(seed)) }
}

// MARK: - Folder records

/// A folder's `.nibfolder.<dev>.json`: its id and style (plus where it was trashed from while it is in the Trash).
/// Each device writes only its own file; readers take the record with the highest revision (ARCHITECTURE §4.3).
struct FolderRecord: Codable, Equatable {
    var id: FolderID
    var rev: Rev
    var color: RGBA?
    var icon: String?
    var favorite: Bool
    /// Library-relative path of the folder it was trashed from ("" = the library root).
    var trashedFrom: String?
    var trashedFromFolder: FolderID?
    /// Unix seconds.
    var trashedAt: Double?

    init(id: FolderID, rev: Rev, style: FolderStyle = FolderStyle()) {
        self.id = id
        self.rev = rev
        self.color = style.color
        self.icon = style.icon
        self.favorite = style.favorite
        self.trashedFrom = nil
        self.trashedFromFolder = nil
        self.trashedAt = nil
    }

    var style: FolderStyle { FolderStyle(color: color, icon: icon, favorite: favorite) }

    enum CodingKeys: String, CodingKey { case id, rev, color, icon, favorite, trashedFrom, trashedFromFolder, trashedAt }

    /// Lenient: only `id` is required (a colour that does not parse is dropped, not fatal).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FolderID.self, forKey: .id)
        rev = (try? c.decodeIfPresent(Rev.self, forKey: .rev)) ?? .zero
        color = try? c.decodeIfPresent(RGBA.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        trashedFrom = try c.decodeIfPresent(String.self, forKey: .trashedFrom)
        trashedFromFolder = try c.decodeIfPresent(FolderID.self, forKey: .trashedFromFolder)
        trashedAt = try c.decodeIfPresent(Double.self, forKey: .trashedAt)
    }

    /// The record with the highest (effective) revision; the first one wins ties.
    static func merged(_ records: [FolderRecord], now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> FolderRecord? {
        guard var best = records.first else { return nil }
        for r in records.dropFirst() where r.rev.effective(now: now) > best.rev.effective(now: now) { best = r }
        return best
    }
}

enum FolderRecords {
    /// Every `.nibfolder.*.json` of a folder (device files and conflict copies), this device's file first.
    static func files(in dir: URL, device: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return sortedOwnFirst(names.filter { LibraryLayout.isFolderFile($0) }, own: LibraryLayout.folderFileName(device))
            .map { dir.appendingPathComponent($0) }
    }

    static func read(_ url: URL) -> FolderRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FolderRecord.self, from: data)
    }

    static func encode(_ record: FolderRecord) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(record)
    }

    static func sortedOwnFirst(_ names: [String], own: String) -> [String] {
        names.sorted { a, b in
            if (a == own) != (b == own) { return a == own }
            return a < b
        }
    }
}

// MARK: - Document heads

/// The part of a document head the catalog needs (meta and page table), decoded without the blocks and cards.
struct HeadSummary: Decodable {
    var meta: DocumentMeta
    var pages: [PageRecord]

    init(meta: DocumentMeta, pages: [PageRecord]) {
        self.meta = meta
        self.pages = pages
    }

    init(_ content: DocumentContent) {
        self.init(meta: content.meta, pages: content.pages)
    }

    enum CodingKeys: String, CodingKey { case meta, pages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(DocumentMeta.self, forKey: .meta)
        pages = try c.decodeIfPresent([PageRecord].self, forKey: .pages) ?? []
    }

    /// Last-writer-wins merge of device heads (meta: highest effective rev, first wins ties; pages by id and rev).
    static func merged(_ heads: [HeadSummary]) -> HeadSummary? {
        guard var out = heads.first else { return nil }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for h in heads.dropFirst() {
            if h.meta.rev.effective(now: now) > out.meta.rev.effective(now: now) { out.meta = h.meta }
            out.pages = LWW.merge(out.pages, h.pages)
        }
        return out
    }

    var livePageCount: Int { pages.filter { !$0.deleted }.count }

    var trashedPages: [TrashedPage] {
        pages.compactMap { p in
            guard p.deleted, let at = p.trashedAt else { return nil }
            return TrashedPage(page: p.id, trashedAt: at)
        }.sorted { ($0.trashedAt, $0.page.raw) > ($1.trashedAt, $1.page.raw) }
    }
}

/// A page in a document's page Trash (`deleted` + `trashedAt`).
struct TrashedPage: Codable, Equatable {
    var page: PageID
    /// Unix seconds.
    var trashedAt: Double
}

/// Reading and writing the heads of a package. The format is the Document Store's (F001): `doc.<dev>.json` holds
/// `DocumentContent` JSON with sorted keys and compact stroke points; every reader merges every device file.
enum PackageIO {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.userInfo[.nibCompactPoints] = true
        return e
    }

    /// Head files of a package (device files and conflict copies), this device's file first.
    static func headFiles(in pkg: URL, device: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pkg.path)) ?? []
        return FolderRecords.sortedOwnFirst(names.filter { LibraryLayout.isHeadFile($0) },
                                            own: LibraryLayout.headFileName(device))
            .map { pkg.appendingPathComponent($0) }
    }

    /// A directory holding at least one head file (how a legacy `*.nib` package is told from a folder).
    static func hasHeadFile(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { LibraryLayout.isHeadFile($0) }
    }

    /// Every head of the package that decodes (an unreadable file from another device never hides the document).
    static func readHeads(_ pkg: URL, device: String) -> [DocumentContent] {
        headFiles(in: pkg, device: device).compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DocumentContent.self, from: data)
        }
    }

    /// Last-writer-wins merge of device heads, the first head winning ties.
    static func merge(_ heads: [DocumentContent]) -> DocumentContent? {
        guard var out = heads.first else { return nil }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for h in heads.dropFirst() {
            if h.meta.rev.effective(now: now) > out.meta.rev.effective(now: now) { out.meta = h.meta }
            out.pages = LWW.merge(out.pages, h.pages)
            out.outline = LWW.merge(out.outline, h.outline)
            out.blocks = LWW.merge(out.blocks, h.blocks)
            out.cards = LWW.merge(out.cards, h.cards)
            out.audio = LWW.merge(out.audio, h.audio)
        }
        return out
    }

    static func readMergedHead(_ pkg: URL, device: String) -> DocumentContent? {
        merge(readHeads(pkg, device: device))
    }

    static func readSummary(_ heads: [URL]) -> HeadSummary? {
        HeadSummary.merged(heads.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(HeadSummary.self, from: data)
        })
    }

    /// Writes `head` as this device's head file (coordinated, atomic).
    static func writeHead(_ head: DocumentContent, to pkg: URL, device: String) throws {
        let data = try encoder().encode(head)
        try FileOps.write(data, to: pkg.appendingPathComponent(LibraryLayout.headFileName(device)))
    }

    /// Rewrites this device's head as the merged head with `change` applied, at a revision above every head's (so the
    /// change wins the merge on every device). `collapse` removes every other head file afterwards (a duplicated or
    /// re-identified package starts with this device's head only).
    @discardableResult
    static func updateHead(_ pkg: URL, device: String, clock: HLCClock, collapse: Bool = false,
                           _ change: (inout DocumentContent) -> Void) throws -> DocumentContent {
        let files = headFiles(in: pkg, device: device)
        let heads = files.compactMap { url -> DocumentContent? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DocumentContent.self, from: data)
        }
        guard var head = merge(heads) else {
            throw NibError(.notFound, "the document '\(pkg.deletingPathExtension().lastPathComponent)' has no readable head",
                           hint: "wait until it has downloaded, or repair the library")
        }
        // A head from a newer major format may hold records this build cannot keep: never rewrite it (as the store).
        guard heads.allSatisfy({ $0.meta.format <= NibFormat.version }) else {
            throw NibError(.unsupported, "'\(pkg.deletingPathExtension().lastPathComponent)' was saved by a newer version of Nib",
                           hint: "update Nib to change it")
        }
        clock.observe(head.meta.rev)
        change(&head)
        head.meta.rev = clock.tick()
        try writeHead(head, to: pkg, device: device)
        if collapse {
            let own = LibraryLayout.headFileName(device)
            for url in files where url.lastPathComponent != own { try? FileOps.remove(url) }
        } else {
            // Conflict copies are merged into this device's file now, so they can go (ARCHITECTURE §4.3).
            for url in files where LibraryLayout.device(of: url.lastPathComponent, prefix: LibraryLayout.headPrefix)?.exact == false {
                try? FileOps.remove(url)
            }
        }
        return head
    }
}

// MARK: - Sync state

/// The iCloud / File Provider state of an item, from its URL resource values.
struct UbiquityState: Equatable {
    var isUbiquitous = false
    var notDownloaded = false
    var isDownloading = false
    var isUploading = false
    var isUploaded = true
    var hasError = false

    static let resourceKeys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemUploadingErrorKey
    ]

    init(isUbiquitous: Bool = false, notDownloaded: Bool = false, isDownloading: Bool = false, isUploading: Bool = false,
         isUploaded: Bool = true, hasError: Bool = false) {
        self.isUbiquitous = isUbiquitous
        self.notDownloaded = notDownloaded
        self.isDownloading = isDownloading
        self.isUploading = isUploading
        self.isUploaded = isUploaded
        self.hasError = hasError
    }

    init(_ values: URLResourceValues?) {
        guard let v = values, v.isUbiquitousItem == true else { return }
        isUbiquitous = true
        notDownloaded = v.ubiquitousItemDownloadingStatus == .notDownloaded
        isDownloading = v.ubiquitousItemIsDownloading ?? false
        isUploading = v.ubiquitousItemIsUploading ?? false
        isUploaded = v.ubiquitousItemIsUploaded ?? true
        hasError = v.ubiquitousItemDownloadingError != nil || v.ubiquitousItemUploadingError != nil
    }

    /// Error beats downloading (evicted or arriving) beats uploading; a local folder is `localOnly`.
    var badge: SyncBadge {
        guard isUbiquitous else { return .localOnly }
        if hasError { return .error }
        if isDownloading || notDownloaded { return .downloading }
        if isUploading || !isUploaded { return .syncing }
        return .synced
    }
}

// MARK: - Catalog entries

/// One folder or document of the catalog: the `LibraryNode` the library lists plus what the incremental scan and
/// the Trash need. Cached as JSON in Application Support between launches.
struct CatalogEntry: Codable, Equatable {
    var node: LibraryNode
    /// Library-relative path of the containing directory ("" = the library root).
    var parentPath: String
    /// In the Trash folder (directly, or inside a trashed folder).
    var inTrash: Bool
    /// Directly in the Trash folder: what the Trash lists.
    var trashTop: Bool
    /// Documents: modification date of the package directory when its heads were last read (an atomic head write
    /// renames a file inside it, which changes the date).
    var stamp: Double?
    /// Names, dates and sizes of the head files (documents) or `.nibfolder` files (folders) last read.
    var signature: String?
    /// Folders: a `.nibfolder` record exists (else the id is derived from the path until one is written).
    var hasRecord: Bool
    /// Documents stored as a legacy `*.nib` package (renamed to `.nibnote` on first open).
    var legacy: Bool
    /// The id was derived from the path (no readable head yet, or a second copy of a document id).
    var derivedID: Bool
    /// Where a trashed item came from (library-relative folder path, "" = root) and that folder's id.
    var trashedFrom: String?
    var trashedFromFolder: FolderID?
    /// Documents: the pages in the document's own page Trash.
    var trashedPages: [TrashedPage]
    /// Documents: the id in the merged head (differs from `node.id` for a second copy of a document).
    var headID: NibID?

    init(node: LibraryNode, parentPath: String, inTrash: Bool = false, trashTop: Bool = false, stamp: Double? = nil,
         signature: String? = nil, hasRecord: Bool = false, legacy: Bool = false, derivedID: Bool = false,
         trashedFrom: String? = nil, trashedFromFolder: FolderID? = nil, trashedPages: [TrashedPage] = [],
         headID: NibID? = nil) {
        self.node = node
        self.parentPath = parentPath
        self.inTrash = inTrash
        self.trashTop = trashTop
        self.stamp = stamp
        self.signature = signature
        self.hasRecord = hasRecord
        self.legacy = legacy
        self.derivedID = derivedID
        self.trashedFrom = trashedFrom
        self.trashedFromFolder = trashedFromFolder
        self.trashedPages = trashedPages
        self.headID = headID
    }

    var isDocument: Bool { node.kind == .document }
    var isFolder: Bool { node.kind == .folder }
    var ref: String { isDocument ? NodeRef.document(node.id).description : NodeRef.folder(node.id).description }

    /// Copies what a document head says into the node (id excepted).
    mutating func apply(_ head: HeadSummary) {
        node.documentKind = head.meta.kind
        node.created = head.meta.createdAt
        node.favorite = head.meta.favorite
        node.locked = head.meta.locked
        node.pageCount = CatalogEntry.isPaged(head.meta.kind) ? head.livePageCount : nil
        trashedPages = head.trashedPages
        trashedFrom = head.meta.trashedFrom
        trashedFromFolder = head.meta.ext?[LibraryLayout.trashedFromFolderKey]?.stringValue.map { NibID($0) }
        if let at = head.meta.ext?[LibraryLayout.trashedAtKey]?.doubleValue { node.trashedAt = at }
        headID = head.meta.id
    }

    static func isPaged(_ kind: DocumentKind) -> Bool { kind == .notebook || kind == .whiteboard }
}

// MARK: - In-memory catalog

/// The catalog: every folder and document of the library (including the Trash), indexed by path and id. Main actor
/// only (owned by `FolderLibrary`); the disk scan builds entries off-main and hands them over.
final class LibraryCatalog {
    private(set) var byPath: [String: CatalogEntry] = [:]
    private var pathByID: [NibID: String] = [:]
    private var childIndex: [String: [LibraryNode]]?
    private var liveList: [LibraryNode]?

    init(_ entries: [CatalogEntry] = []) {
        replaceAll(entries)
    }

    var entries: [CatalogEntry] { Array(byPath.values) }
    var count: Int { byPath.count }

    func replaceAll(_ list: [CatalogEntry]) {
        byPath = [:]
        pathByID = [:]
        byPath.reserveCapacity(list.count)
        pathByID.reserveCapacity(list.count)
        for e in list {
            byPath[e.node.path] = e
            pathByID[e.node.id] = e.node.path
        }
        invalidate()
    }

    func entry(id: NibID) -> CatalogEntry? {
        guard let p = pathByID[id] else { return nil }
        return byPath[p]
    }

    func entry(path: String) -> CatalogEntry? { byPath[path] }

    /// Inserts or replaces the entry at its path (an entry that moved leaves its old path).
    func upsert(_ e: CatalogEntry) {
        if let old = pathByID[e.node.id], old != e.node.path, byPath[old]?.node.id == e.node.id { byPath[old] = nil }
        if let displaced = byPath[e.node.path], displaced.node.id != e.node.id,
           pathByID[displaced.node.id] == e.node.path {
            pathByID[displaced.node.id] = nil
        }
        byPath[e.node.path] = e
        pathByID[e.node.id] = e.node.path
        invalidate()
    }

    /// The entry at `path` and everything inside it.
    func subtree(path: String) -> [CatalogEntry] {
        byPath.values.filter { LibraryLayout.isWithin($0.node.path, path) }.sorted { $0.node.path < $1.node.path }
    }

    func removeSubtree(path: String) {
        for e in subtree(path: path) {
            byPath[e.node.path] = nil
            if pathByID[e.node.id] == e.node.path { pathByID[e.node.id] = nil }
        }
        invalidate()
    }

    /// Every folder and document outside the Trash, in path order.
    func liveNodes() -> [LibraryNode] {
        if let l = liveList { return l }
        let l = byPath.values.filter { !$0.inTrash }.map { $0.node }.sorted { $0.path < $1.path }
        liveList = l
        return l
    }

    /// What the Trash lists (items directly in it), most recently trashed first.
    func trashTopNodes() -> [LibraryNode] {
        byPath.values.filter { $0.trashTop }.map { $0.node }
            .sorted { ($0.trashedAt ?? 0, $1.path) > ($1.trashedAt ?? 0, $0.path) }
    }

    /// Live children of a folder (nil = the library root), in title order.
    func children(of folder: FolderID?) -> [LibraryNode] {
        if childIndex == nil {
            var index: [String: [LibraryNode]] = [:]
            for n in liveNodes() { index[n.parent?.raw ?? "", default: []].append(n) }
            for k in Array(index.keys) {
                index[k]?.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            childIndex = index
        }
        return childIndex?[folder?.raw ?? ""] ?? []
    }

    /// Every document (live and trashed) → package URL, for `PackageLocator.replaceAll`.
    func locations(root: URL) -> [DocumentID: URL] {
        var out: [DocumentID: URL] = [:]
        out.reserveCapacity(byPath.count)
        for e in byPath.values where e.isDocument {
            out[e.node.id] = root.appendingPathComponent(e.node.path, isDirectory: true)
        }
        return out
    }

    private func invalidate() {
        childIndex = nil
        liveList = nil
    }
}

/// The catalog as cached in Application Support (one file per library root).
struct CatalogCache: Codable {
    static let currentVersion = 1
    var version: Int
    var root: String
    var entries: [CatalogEntry]

    static func load(_ url: URL, root: String) -> [CatalogEntry]? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data),
              cache.version == currentVersion, cache.root == root else { return nil }
        return cache.entries
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Disk scan

/// Builds catalog entries from the library folder. Incremental: a package whose directory date is unchanged keeps its
/// cached entry (only its sync badge is refreshed), and a folder whose `.nibfolder` files are unchanged keeps its
/// record, so a rescan of an unchanged library costs one directory listing per folder and one stat per package.
/// Pure file-system reads, safe off the main actor.
struct CatalogScanner {
    let root: URL
    let device: String
    /// The previous catalog, by path.
    let previous: [String: CatalogEntry]
    /// Skip the root's `Inbox` (the library lives in the app's Documents folder).
    let skipInbox: Bool

    static let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        + UbiquityState.resourceKeys

    /// The whole library: the tree under the root, then the Trash.
    func scan() -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        visit(list(root), in: "", inTrash: false, trashTop: false, isRoot: true, into: &out)
        let trash = root.appendingPathComponent(LibraryLayout.trashPath, isDirectory: true)
        visit(list(trash), in: LibraryLayout.trashPath, inTrash: true, trashTop: true, isRoot: false, into: &out)
        return CatalogScanner.resolve(out, previous: previous, existing: [:])
    }

    /// One item and everything inside it (a new copy or import at `url`), resolved against `existing` entries so
    /// parent folders and taken ids are known.
    func scanItem(at url: URL, inTrash: Bool, trashTop: Bool, existing: [String: CatalogEntry]) -> [CatalogEntry] {
        let path = relativePath(url)
        let parent = LibraryLayout.parentPath(of: path)
        var out: [CatalogEntry] = []
        let values = try? url.resourceValues(forKeys: Set(CatalogScanner.keys))
        let ext = url.pathExtension.lowercased()
        if ext == NibFormat.packageExtension || (ext == NibFormat.legacyPackageExtension && PackageIO.hasHeadFile(url)) {
            out.append(document(url, path: path, parent: parent, values: values, legacy: ext != NibFormat.packageExtension,
                                inTrash: inTrash, trashTop: trashTop))
        } else {
            folder(url, path: path, parent: parent, values: values, inTrash: inTrash, trashTop: trashTop, into: &out)
        }
        return CatalogScanner.resolve(out, previous: previous, existing: existing)
    }

    func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count).drop { $0 == "/" })
    }

    private func list(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: CatalogScanner.keys,
                                                      options: [])) ?? []
    }

    private func visit(_ urls: [URL], in parent: String, inTrash: Bool, trashTop: Bool, isRoot: Bool,
                       into out: inout [CatalogEntry]) {
        for url in urls {
            let name = url.lastPathComponent
            let path = parent.isEmpty ? name : parent + "/" + name
            if name.hasPrefix(".") {
                if name.hasSuffix(LibraryLayout.placeholderSuffix), name.count > 1 + LibraryLayout.placeholderSuffix.count {
                    let real = String(name.dropFirst().dropLast(LibraryLayout.placeholderSuffix.count))
                    if (real as NSString).pathExtension.lowercased() == NibFormat.packageExtension {
                        out.append(placeholder(named: real, parent: parent, inTrash: inTrash, trashTop: trashTop))
                    }
                }
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(CatalogScanner.keys))
            guard values?.isDirectory == true else { continue }
            if isRoot && skipInbox && name == LibraryLayout.inboxName { continue }
            let ext = url.pathExtension.lowercased()
            if ext == NibFormat.packageExtension {
                out.append(document(url, path: path, parent: parent, values: values, legacy: false, inTrash: inTrash,
                                    trashTop: trashTop))
            } else if ext == NibFormat.legacyPackageExtension && PackageIO.hasHeadFile(url) {
                out.append(document(url, path: path, parent: parent, values: values, legacy: true, inTrash: inTrash,
                                    trashTop: trashTop))
            } else {
                folder(url, path: path, parent: parent, values: values, inTrash: inTrash, trashTop: trashTop, into: &out)
            }
        }
    }

    private func folder(_ url: URL, path: String, parent: String, values: URLResourceValues?, inTrash: Bool,
                        trashTop: Bool, into out: inout [CatalogEntry]) {
        let children = list(url)
        let styleFiles = children.filter { LibraryLayout.isFolderFile($0.lastPathComponent) }
        let signature = CatalogScanner.signature(styleFiles)
        let prev = previous[path].flatMap { $0.isFolder ? $0 : nil }
        var entry: CatalogEntry
        if let p = prev, p.signature == signature {
            entry = p
        } else {
            let own = LibraryLayout.folderFileName(device)
            let sorted = styleFiles.sorted { a, b in
                let an = a.lastPathComponent, bn = b.lastPathComponent
                if (an == own) != (bn == own) { return an == own }
                return an < bn
            }
            let record = FolderRecord.merged(sorted.compactMap { FolderRecords.read($0) })
            // Without a record the folder keeps the id it had at this path (derived from the path the first time).
            let id = record?.id ?? prev?.node.id ?? LibraryIDs.derived("folder:" + path)
            var node = LibraryNode(id: id, kind: .folder, title: url.lastPathComponent, path: path)
            node.style = record?.style ?? FolderStyle()
            node.favorite = record?.favorite ?? false
            entry = CatalogEntry(node: node, parentPath: parent, signature: signature, hasRecord: record != nil,
                                 derivedID: record == nil)
            entry.trashedFrom = record?.trashedFrom
            entry.trashedFromFolder = record?.trashedFromFolder
            entry.node.trashedAt = record?.trashedAt
        }
        entry.node.title = url.lastPathComponent
        entry.node.path = path
        entry.parentPath = parent
        entry.inTrash = inTrash
        entry.trashTop = trashTop
        if !trashTop { entry.node.trashedAt = nil }
        if trashTop, entry.node.trashedAt == nil {
            entry.node.trashedAt = values?.contentModificationDate?.timeIntervalSince1970
        }
        entry.node.modified = values?.contentModificationDate?.timeIntervalSince1970 ?? entry.node.modified
        entry.node.created = values?.creationDate?.timeIntervalSince1970 ?? entry.node.created
        entry.node.sync = UbiquityState(values).badge
        out.append(entry)
        visit(children, in: path, inTrash: inTrash, trashTop: false, isRoot: false, into: &out)
    }

    private func document(_ url: URL, path: String, parent: String, values: URLResourceValues?, legacy: Bool,
                          inTrash: Bool, trashTop: Bool) -> CatalogEntry {
        let title = (url.lastPathComponent as NSString).deletingPathExtension
        let ubiquity = UbiquityState(values)
        let stamp = values?.contentModificationDate?.timeIntervalSinceReferenceDate
        var entry: CatalogEntry
        if var p = previous[path], p.isDocument, stamp != nil, p.stamp == stamp, p.legacy == legacy, !p.derivedID {
            p.node.sync = ubiquity.badge
            entry = p
        } else {
            let heads = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [
                .contentModificationDateKey, .fileSizeKey], options: [])) ?? []
            let own = LibraryLayout.headFileName(device)
            let files = heads.filter { LibraryLayout.isHeadFile($0.lastPathComponent) }.sorted { a, b in
                let an = a.lastPathComponent, bn = b.lastPathComponent
                if (an == own) != (bn == own) { return an == own }
                return an < bn
            }
            let prev = previous[path].flatMap { $0.isDocument ? $0 : nil }
            let summary = PackageIO.readSummary(files)
            let modified = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max()?.timeIntervalSince1970
            let node = LibraryNode(id: summary?.meta.id ?? prev?.node.id ?? LibraryIDs.derived("doc:" + path),
                                   kind: .document, title: title, path: path)
            entry = CatalogEntry(node: node, parentPath: parent, stamp: stamp, signature: CatalogScanner.signature(files),
                                 legacy: legacy, derivedID: summary == nil && prev == nil)
            if let s = summary {
                entry.apply(s)
            } else if let p = prev {
                entry.node.documentKind = p.node.documentKind
                entry.node.created = p.node.created
                entry.node.pageCount = p.node.pageCount
                entry.headID = p.headID
                entry.stamp = nil          // read the heads again next time
            } else {
                entry.stamp = nil
            }
            entry.node.modified = modified ?? values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if summary == nil && !ubiquity.isUbiquitous {
                entry.node.sync = .error
            } else {
                entry.node.sync = summary == nil ? .downloading : ubiquity.badge
            }
        }
        entry.node.title = title
        entry.node.path = path
        entry.parentPath = parent
        entry.inTrash = inTrash
        entry.trashTop = trashTop
        entry.legacy = legacy
        if !trashTop {
            entry.node.trashedAt = nil
        } else if entry.node.trashedAt == nil {
            entry.node.trashedAt = values?.contentModificationDate?.timeIntervalSince1970
        }
        if entry.node.created == 0 { entry.node.created = values?.creationDate?.timeIntervalSince1970 ?? 0 }
        return entry
    }

    /// An evicted iCloud package (`.<name>.icloud`): listed with its cached id, downloading.
    private func placeholder(named real: String, parent: String, inTrash: Bool, trashTop: Bool) -> CatalogEntry {
        let path = parent.isEmpty ? real : parent + "/" + real
        let title = (real as NSString).deletingPathExtension
        if var p = previous[path], p.isDocument {
            p.node.sync = .downloading
            p.stamp = nil
            p.parentPath = parent
            p.inTrash = inTrash
            p.trashTop = trashTop
            return p
        }
        var node = LibraryNode(id: LibraryIDs.derived("doc:" + path), kind: .document, title: title, path: path)
        node.sync = .downloading
        return CatalogEntry(node: node, parentPath: parent, inTrash: inTrash, trashTop: trashTop, derivedID: true)
    }

    static func signature(_ files: [URL]) -> String {
        files.map { url -> String in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = v?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(url.lastPathComponent):\(date):\(v?.fileSize ?? -1)"
        }.sorted().joined(separator: "|")
    }

    /// Makes ids unique and links parents. An id claimed twice (a package or folder copied in the Files app, or a
    /// provider showing an item at two places during a move) stays with the path that held it before (or the first
    /// path), and the other copy gets an id derived from its path, so the scan never writes to disk. Parents come
    /// from the containing folder; a trashed item's parent is the live folder it was trashed from.
    static func resolve(_ scanned: [CatalogEntry], previous: [String: CatalogEntry],
                        existing: [String: CatalogEntry]) -> [CatalogEntry] {
        var formerOwner: [NibID: String] = [:]
        for e in previous.values { formerOwner[e.node.id] = e.node.path }
        let ordered = scanned.sorted { a, b in
            let ao = formerOwner[a.node.id] == a.node.path, bo = formerOwner[b.node.id] == b.node.path
            if ao != bo { return ao }
            return a.node.path < b.node.path
        }
        var taken = Set<NibID>()
        for e in existing.values { taken.insert(e.node.id) }
        var out: [CatalogEntry] = []
        out.reserveCapacity(ordered.count)
        for var e in ordered {
            if !taken.insert(e.node.id).inserted {
                var seed = (e.isDocument ? "doc:" : "folder:") + e.node.path
                var id = LibraryIDs.derived(seed)
                while taken.contains(id) {
                    seed += "+"
                    id = LibraryIDs.derived(seed)
                }
                e.node.id = id
                e.derivedID = true
                taken.insert(id)
            }
            out.append(e)
        }
        var folderIDs: [String: FolderID] = [:]
        for e in existing.values where e.isFolder { folderIDs[e.node.path] = e.node.id }
        for e in out where e.isFolder { folderIDs[e.node.path] = e.node.id }
        var liveFolders = Set<FolderID>()
        for e in existing.values where e.isFolder && !e.inTrash { liveFolders.insert(e.node.id) }
        for e in out where e.isFolder && !e.inTrash { liveFolders.insert(e.node.id) }
        for i in out.indices {
            if out[i].trashTop {
                let from = out[i].trashedFromFolder
                out[i].node.parent = from.flatMap { liveFolders.contains($0) ? $0 : nil }
            } else {
                let p = out[i].parentPath
                out[i].node.parent = p.isEmpty ? nil : folderIDs[p]
            }
        }
        return out
    }
}
