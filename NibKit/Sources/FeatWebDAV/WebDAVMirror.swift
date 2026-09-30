import Foundation
import CryptoKit
import NibContracts

// MARK: - Inputs of the three-way mirror

/// A file in the local library. `path` is the real relative path on disk ("/"-separated).
struct LocalEntry: Equatable {
    var path: String
    var size: Int64
    /// Content modification time, Unix seconds.
    var modified: Double

    /// What the mirror compares between syncs (size and modification time to the millisecond).
    var fingerprint: String { "\(size):\(Int64((modified * 1000).rounded()))" }
}

/// A file in the library folder on the server. `path` is the decoded relative path the server uses.
struct RemoteEntry: Equatable {
    var path: String
    /// `DAVResource.version`: normalised ETag, else modification date and size.
    var version: String
    var size: Int64?
}

/// The last-synced state of one path: the local fingerprint and the server version both sides had then.
struct SyncedEntry: Codable, Equatable {
    var local: String
    var remote: String

    init(local: String, remote: String) {
        self.local = local
        self.remote = remote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        local = try c.decodeIfPresent(String.self, forKey: .local) ?? ""
        remote = try c.decodeIfPresent(String.self, forKey: .remote) ?? ""
    }

    enum CodingKeys: String, CodingKey { case local, remote }
}

// MARK: - What is mirrored

/// Names the mirror never copies in either direction: Finder/Windows litter, AppleDouble files, atomic-write and
/// mirror temporaries, iCloud placeholders.
enum WebDAVMirrorFilter {
    static let ignoredNames: Set<String> = [
        ".DS_Store", ".localized", "Icon\r", ".Trashes", ".Trash", ".TemporaryItems", ".fseventsd", ".Spotlight-V100",
        ".DocumentRevisions-V100", "Thumbs.db", "desktop.ini"
    ]
    /// Prefix of the mirror's own sibling temporaries (atomic replace in the destination folder).
    static let tempPrefix = ".nibwebdav-"

    static func isExcludedName(_ name: String) -> Bool {
        if ignoredNames.contains(name) { return true }
        if name.hasPrefix("._") || name.hasPrefix(".dat.nosync") || name.hasPrefix(tempPrefix) || name.hasPrefix("~$") {
            return true
        }
        if name.hasSuffix(".tmp") { return true }
        return isICloudPlaceholder(name)
    }

    /// ".Name.ext.icloud": an iCloud Drive file that is not downloaded yet.
    static func isICloudPlaceholder(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > ".icloud".count + 1
    }

    /// "Name.ext" for ".Name.ext.icloud".
    static func placeholderTarget(_ name: String) -> String {
        String(name.dropFirst().dropLast(".icloud".count))
    }
}

// MARK: - Decision table

/// One step of a sync. `key` is the Unicode-normalised relative path.
struct MirrorAction: Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// local → server
        case upload
        /// server → local
        case download
        /// the file was deleted on the server; delete the unchanged local copy
        case deleteLocal
        /// the file was deleted locally; delete the unchanged server copy
        case deleteRemote
        /// both sides have the file and it changed on both (or no sync ever saw it): keep both
        case resolve
        /// gone on both sides: drop the remembered state
        case forget
    }

    var kind: Kind
    var key: String
    /// `resolve`: the local path the server's copy is saved under when it differs from the local file.
    var conflictPath: String?

    init(_ kind: Kind, _ key: String, conflictPath: String? = nil) {
        self.kind = kind
        self.key = key
        self.conflictPath = conflictPath
    }
}

struct MirrorPlan: Equatable {
    enum Reset: String { case local, remote }

    var actions: [MirrorAction] = []
    var unchanged = 0
    /// Keys left alone this run (locked documents, iCloud files still downloading); their state is kept.
    var skipped: [String] = []
    /// One side was empty although files were synced before (server folder wiped, library folder replaced): the
    /// remembered state is ignored, so the other side is copied back instead of deleting everything.
    var reset: Reset?

    func keys(_ kind: MirrorAction.Kind) -> [String] { actions.filter { $0.kind == kind }.map { $0.key } }
}

/// The three-way decision table: local file (L), server file (R) and last-synced state (S) per path.
///
/// | L | R | S | action |
/// |---|---|---|---|
/// | yes | – | – | upload |
/// | – | yes | – | download |
/// | yes | yes | – | resolve (identical → adopt, else keep both) |
/// | – | – | yes | forget |
/// | yes, unchanged | – | yes | deleteLocal |
/// | yes, changed | – | yes | upload (an edit beats a deletion) |
/// | – | yes, unchanged | yes | deleteRemote |
/// | – | yes, changed | yes | download |
/// | yes | yes | yes | only L changed → upload, only R → download, both → resolve, neither → nothing |
///
/// Devices write disjoint files (`<name>.<device>.<ext>`), so "resolve" only happens for a same-path divergence;
/// the server's copy is then kept under a conflict-copy name that NibStore merges and deletes.
enum MirrorPlanner {
    static let order: [MirrorAction.Kind] = [.forget, .resolve, .download, .upload, .deleteLocal, .deleteRemote]

    static func plan(local: [String: LocalEntry], remote: [String: RemoteEntry], state: [String: SyncedEntry],
                     deviceHex: String, skip: (String) -> Bool = { _ in false }) -> MirrorPlan {
        var plan = MirrorPlan()
        let hasLocal = local.keys.contains { !skip($0) }
        let hasRemote = remote.keys.contains { !skip($0) }
        let hasState = state.keys.contains { !skip($0) }
        var base = state
        if hasState, hasLocal != hasRemote {
            plan.reset = hasLocal ? .remote : .local
            base = [:]
        }
        var taken = Set(local.keys).union(remote.keys)
        var actions: [MirrorAction] = []
        for key in Set(local.keys).union(remote.keys).union(state.keys).sorted() {
            if skip(key) {
                plan.skipped.append(key)
                continue
            }
            switch (local[key], remote[key], base[key]) {
            case (nil, nil, _):
                if state[key] != nil { actions.append(MirrorAction(.forget, key)) }
            case (.some, nil, nil):
                actions.append(MirrorAction(.upload, key))
            case (nil, .some, nil):
                actions.append(MirrorAction(.download, key))
            case let (.some(l), .some, nil):
                let name = ConflictNaming.name(for: l.path, device: deviceHex, taken: taken)
                taken.insert(WebDAVPaths.key(name))
                actions.append(MirrorAction(.resolve, key, conflictPath: name))
            case let (.some(l), nil, .some(s)):
                actions.append(MirrorAction(l.fingerprint == s.local ? .deleteLocal : .upload, key))
            case let (nil, .some(r), .some(s)):
                actions.append(MirrorAction(r.version == s.remote ? .deleteRemote : .download, key))
            case let (.some(l), .some(r), .some(s)):
                switch (l.fingerprint != s.local, r.version != s.remote) {
                case (false, false):
                    plan.unchanged += 1
                case (true, false):
                    actions.append(MirrorAction(.upload, key))
                case (false, true):
                    actions.append(MirrorAction(.download, key))
                case (true, true):
                    let name = ConflictNaming.name(for: l.path, device: deviceHex, taken: taken)
                    taken.insert(WebDAVPaths.key(name))
                    actions.append(MirrorAction(.resolve, key, conflictPath: name))
                }
            }
        }
        // Copies first, deletions last: an interrupted run leaves extra files, never missing ones.
        plan.actions = actions.sorted { a, b in
            let ia = order.firstIndex(of: a.kind) ?? 0, ib = order.firstIndex(of: b.kind) ?? 0
            return ia != ib ? ia < ib : a.key < b.key
        }
        return plan
    }
}

/// Conflict-copy names in the provider style NibStore already merges ("doc.1a2b3c4d (conflicted copy).json",
/// "<dev> 2.nibpage"): the device hex keeps two devices resolving the same file from clobbering each other's copy.
enum ConflictNaming {
    static func name(for path: String, device: String, taken: Set<String>) -> String {
        let slash = path.lastIndex(of: "/")
        let dir = slash.map { String(path[...$0]) } ?? ""
        let file = slash.map { String(path[path.index(after: $0)...]) } ?? path
        var stem = file
        var ext = ""
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            stem = String(file[..<dot])
            ext = String(file[dot...])
        }
        var n = 1
        while true {
            let suffix = n == 1 ? " (WebDAV conflict \(device))" : " (WebDAV conflict \(device) \(n))"
            let candidate = dir + stem + suffix + ext
            if !taken.contains(WebDAVPaths.key(candidate)) { return candidate }
            n += 1
        }
    }
}

// MARK: - Local library

struct LocalScan {
    var files: [String: LocalEntry] = [:]
    /// Keys of iCloud files that are not downloaded yet (skipped this run; a download was requested).
    var notDownloaded: [String] = []
}

enum LocalLibraryScanner {
    /// Walks the library folder (hidden files included: `.nib-library`, `.nibfolder.<dev>.json`).
    /// `excludedTopLevel` names are skipped at the root (the app's own Inbox when the library is Documents).
    static func scan(root: URL, excludedTopLevel: Set<String> = []) throws -> LocalScan {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let walker = fm.enumerator(atPath: root.path) else {
            throw WebDAVError.local(String(localized: "The library folder is not available"))
        }
        var scan = LocalScan()
        while let rel = walker.nextObject() as? String {
            let parts = rel.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            if (parts.count == 1 && excludedTopLevel.contains(name)) || type == .typeSymbolicLink {
                if isDirectory { walker.skipDescendants() }
                continue
            }
            if WebDAVMirrorFilter.isICloudPlaceholder(name) {
                let target = (parts.dropLast() + [WebDAVMirrorFilter.placeholderTarget(name)]).joined(separator: "/")
                scan.notDownloaded.append(WebDAVPaths.key(target))
                try? fm.startDownloadingUbiquitousItem(at: root.appendingPathComponent(target))
                continue
            }
            if WebDAVMirrorFilter.isExcludedName(name) {
                if isDirectory { walker.skipDescendants() }
                if name.hasPrefix(WebDAVMirrorFilter.tempPrefix) {
                    removeIfStale(root.appendingPathComponent(rel),
                                  modified: walker.fileAttributes?[.modificationDate] as? Date)
                }
                continue
            }
            guard type == .typeRegular, let entry = LocalFiles.stat(root.appendingPathComponent(rel), path: rel) else {
                continue
            }
            scan.files[WebDAVPaths.key(rel)] = entry
        }
        return scan
    }

    /// A mirror temporary left by an interrupted run.
    static func removeIfStale(_ url: URL, modified: Date?) {
        guard let m = modified, Date().timeIntervalSince(m) > 3600 else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Coordinated local file operations. Every write re-checks that the file is still what the plan saw, so an edit
/// made during the sync is never overwritten (the next run picks it up).
enum LocalFiles {
    /// The file's size and modification time (one code path for the scan and every re-check, so fingerprints of an
    /// untouched file always compare equal).
    static func stat(_ url: URL, path: String) -> LocalEntry? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return LocalEntry(path: path, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    static func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions,
                           _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options,
                                                         error: &coordinationError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = bodyError { throw e }
        if let e = coordinationError { throw WebDAVError.local(e.localizedDescription) }
    }

    /// Moves `temp` to `root/path` atomically (sibling temporary + replace), unless the file there changed since
    /// the plan (`expected`; nil = must not exist). Returns the installed file.
    static func install(_ temp: URL, root: URL, path: String, expected: LocalEntry?) throws -> LocalEntry {
        let fm = FileManager.default
        let dest = root.appendingPathComponent(path)
        var installed: LocalEntry?
        try coordinate(writing: dest, options: .forReplacing) { url in
            let current = stat(url, path: path)
            guard current?.fingerprint == expected?.fingerprint else {
                throw WebDAVError.changedDuringSync(path)
            }
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let sibling = dir.appendingPathComponent(WebDAVMirrorFilter.tempPrefix + UUID().uuidString)
            try fm.moveItem(at: temp, to: sibling)
            do {
                if current != nil {
                    _ = try fm.replaceItemAt(url, withItemAt: sibling)
                } else {
                    try fm.moveItem(at: sibling, to: url)
                }
            } catch {
                try? fm.removeItem(at: sibling)
                throw error
            }
            installed = stat(url, path: path)
        }
        guard let entry = installed else { throw WebDAVError.local(String(localized: "\(path) could not be written")) }
        return entry
    }

    /// Copies `root/path` to a temporary file under a coordinated read. Returns the copy and the file it copied.
    static func snapshot(root: URL, path: String, into dir: URL) throws -> (URL, LocalEntry) {
        let fm = FileManager.default
        let source = root.appendingPathComponent(path)
        let copy = dir.appendingPathComponent(UUID().uuidString)
        var entry: LocalEntry?
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: .withoutChanges,
                                                         error: &coordinationError) { url in
            do {
                entry = stat(url, path: path)
                guard entry != nil else { throw WebDAVError.changedDuringSync(path) }
                try fm.copyItem(at: url, to: copy)
            } catch { bodyError = error }
        }
        if let e = bodyError { throw e }
        if let e = coordinationError { throw WebDAVError.local(e.localizedDescription) }
        guard let found = entry else { throw WebDAVError.changedDuringSync(path) }
        return (copy, found)
    }

    /// Deletes `root/path` if it is still `expected`.
    static func remove(root: URL, path: String, expected: LocalEntry) throws {
        let fm = FileManager.default
        let url = root.appendingPathComponent(path)
        try coordinate(writing: url, options: .forDeleting) { u in
            guard let current = stat(u, path: path) else { return }
            guard current.fingerprint == expected.fingerprint else { throw WebDAVError.changedDuringSync(path) }
            try fm.removeItem(at: u)
        }
    }

    /// Removes the folders that deleting `paths` left empty, deepest first (a moved or purged document's package
    /// folder). Never the library root or its top-level `.nib-library` marker folder.
    static func pruneEmptyFolders(root: URL, deleted paths: [String]) {
        let fm = FileManager.default
        var folders = Set<String>()
        for path in paths {
            var parts = path.split(separator: "/").map(String.init)
            parts.removeLast()
            while !parts.isEmpty {
                folders.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        folders.remove(NibFormat.libraryDirectory)
        for folder in folders.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            guard let contents = try? fm.contentsOfDirectory(atPath: dir.path),
                  contents.allSatisfy({ WebDAVMirrorFilter.ignoredNames.contains($0) }) else { continue }
            try? coordinate(writing: dir, options: .forDeleting) { u in try fm.removeItem(at: u) }
        }
    }

    /// True when `root/path` is really gone: no file there, and the closest existing folder above it can be listed
    /// (a folder the scan could not read must never turn into deletions on the server).
    static func isConfirmedAbsent(root: URL, path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(path).path) { return false }
        var parts = path.split(separator: "/").map(String.init)
        parts.removeLast()
        while true {
            let dir = parts.isEmpty ? root : root.appendingPathComponent(parts.joined(separator: "/"), isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                return isDir.boolValue && (try? fm.contentsOfDirectory(atPath: dir.path)) != nil
            }
            if parts.isEmpty { return false }
            parts.removeLast()
        }
    }

    /// Byte-for-byte comparison (sizes first).
    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        func size(_ url: URL) -> Int64? {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return (attributes[.size] as? NSNumber)?.int64Value
        }
        guard let sa = size(a), sa == size(b) else { return false }
        return fm.contentsEqual(atPath: a.path, andPath: b.path)
    }
}

// MARK: - Last-synced state

/// Counts of one sync run (`webdav.syncNow`, `webdav.status` `lastResult`).
struct WebDAVSyncReport: Codable, Equatable {
    var started: Double
    var finished: Double?
    var uploaded = 0
    var downloaded = 0
    var deletedLocal = 0
    var deletedRemote = 0
    var conflicts = 0
    var unchanged = 0
    var skippedLocked = 0
    /// Files left for the next run (changed during this run, failed, or iCloud files still downloading).
    var pending = 0
    var errors: [String] = []
    /// Local paths of conflict copies written by this run.
    var conflictFiles: [String] = []
    /// "local" or "remote" when one side was found empty and was restored from the other.
    var reset: String?
    /// Stable reason code of the failure that stopped the run.
    var failure: String?
    var cancelled = false

    init(started: Double) {
        self.started = started
    }

    /// True when files in the library folder were created, replaced or deleted.
    var changedLocalFiles: Bool { downloaded + deletedLocal + conflicts > 0 }

    mutating func count(_ counter: WebDAVMirrorRun.Counter) {
        switch counter {
        case .uploaded: uploaded += 1
        case .downloaded: downloaded += 1
        case .deletedLocal: deletedLocal += 1
        case .deletedRemote: deletedRemote += 1
        case .conflicts: conflicts += 1
        case .unchanged: unchanged += 1
        }
    }

    enum CodingKeys: String, CodingKey {
        case started, finished, uploaded, downloaded, deletedLocal, deletedRemote, conflicts, unchanged, skippedLocked,
             pending, errors, conflictFiles, reset, failure, cancelled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        started = try c.decodeIfPresent(Double.self, forKey: .started) ?? 0
        finished = try c.decodeIfPresent(Double.self, forKey: .finished)
        uploaded = try c.decodeIfPresent(Int.self, forKey: .uploaded) ?? 0
        downloaded = try c.decodeIfPresent(Int.self, forKey: .downloaded) ?? 0
        deletedLocal = try c.decodeIfPresent(Int.self, forKey: .deletedLocal) ?? 0
        deletedRemote = try c.decodeIfPresent(Int.self, forKey: .deletedRemote) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        unchanged = try c.decodeIfPresent(Int.self, forKey: .unchanged) ?? 0
        skippedLocked = try c.decodeIfPresent(Int.self, forKey: .skippedLocked) ?? 0
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        conflictFiles = try c.decodeIfPresent([String].self, forKey: .conflictFiles) ?? []
        reset = try c.decodeIfPresent(String.self, forKey: .reset)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
    }
}

struct MirrorState: Codable, Equatable {
    var entries: [String: SyncedEntry] = [:]
    /// Unix seconds of the last run that finished without a fatal error.
    var lastSync: Double?
    var lastReport: WebDAVSyncReport?

    init() {}

    enum CodingKeys: String, CodingKey { case entries, lastSync, lastReport }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: SyncedEntry].self, forKey: .entries) ?? [:]
        lastSync = try c.decodeIfPresent(Double.self, forKey: .lastSync)
        lastReport = try? c.decodeIfPresent(WebDAVSyncReport.self, forKey: .lastReport)
    }
}

/// The last-synced state JSON, device-local in Application Support (never inside the mirrored library). One file
/// per server, user, folder and library root, so changing any of them starts from a clean three-way merge.
final class MirrorStateStore {
    let url: URL

    init(directory: URL, key: String) {
        url = directory.appendingPathComponent("state-\(key).json")
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Nib/webdav", isDirectory: true)
    }

    static func key(server: URL, user: String, folder: String, root: URL) -> String {
        let text = [server.absoluteString, user, folder, root.standardizedFileURL.path].joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    func load() -> MirrorState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(MirrorState.self, from: data) else {
            return MirrorState()
        }
        return state
    }

    func save(_ state: MirrorState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

// MARK: - Running a sync

/// Progress of the run in flight, readable from any thread (`webdav.status` pending count).
final class MirrorProgress {
    private let lock = NSLock()
    private var total = 0
    private var done = 0

    func begin(_ total: Int) {
        lock.lock()
        self.total = total
        done = 0
        lock.unlock()
    }

    func step() {
        lock.lock()
        done += 1
        lock.unlock()
    }

    var remaining: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, total - done)
    }
}

/// One mirror pass: scan the library, list the server, plan, copy (a few files at a time), delete, tidy empty
/// folders, and save the state. Runs off the main actor; never throws (failures end up in the report).
final class WebDAVMirrorRun {
    let client: WebDAVClient
    let root: URL
    let store: MirrorStateStore
    let deviceHex: String
    /// Keys of locked document packages ("Physics/Kinematics.nibnote"): skipped while locked.
    let lockedPackages: [String]
    let excludedTopLevel: Set<String>
    let progress = MirrorProgress()
    /// The error that stopped the run early, if any (set when `run()` returns).
    private(set) var failure: WebDAVError?
    var concurrency = 3
    /// Saves the state after this many finished actions, so an interrupted run loses little.
    var checkpointEvery = 50
    private let lock = NSLock()
    private var cancelled = false

    init(client: WebDAVClient, root: URL, store: MirrorStateStore, deviceHex: String, lockedPackages: [String] = [],
         excludedTopLevel: Set<String> = []) {
        self.client = client
        self.root = root
        self.store = store
        self.deviceHex = deviceHex
        self.lockedPackages = lockedPackages.map(WebDAVPaths.key)
        self.excludedTopLevel = excludedTopLevel
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        client.cancelAll()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    func isLocked(_ key: String) -> Bool {
        lockedPackages.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    enum Counter {
        case uploaded, downloaded, deletedLocal, deletedRemote, conflicts, unchanged
    }

    /// Outcome of one action: state changes (nil = forget) and counters.
    struct Outcome {
        var updates: [(String, SyncedEntry?)] = []
        var counter: Counter?
        var conflictFile: String?
        var error: WebDAVError?
        var uploadedPaths: [String] = []
        var deletedRemotePath: String?
        var deletedLocalPath: String?
    }

    func run() async -> WebDAVSyncReport {
        var report = WebDAVSyncReport(started: Date().timeIntervalSince1970)
        var state = store.load()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nib-webdav/" + UUID().uuidString,
                                                                                    isDirectory: true)
        let accessing = root.startAccessingSecurityScopedResource()
        defer {
            if accessing { root.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: scratch)
        }
        var deletedLocal: [String] = []
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let scan = try LocalLibraryScanner.scan(root: root, excludedTopLevel: excludedTopLevel)
            if isCancelled { throw WebDAVError.cancelled }
            var tree: RemoteTree
            if let listed = try await client.listLibrary() {
                tree = listed
            } else {
                try await client.ensureCollections(client.configuration.folderComponents)
                tree = RemoteTree()
            }
            // An evicted iCloud file or package is not "deleted locally": leave everything under it alone.
            let notDownloaded = scan.notDownloaded
            let plan = MirrorPlanner.plan(local: scan.files, remote: tree.files, state: state.entries,
                                          deviceHex: deviceHex,
                                          skip: { key in
                                              self.isLocked(key)
                                                  || notDownloaded.contains { key == $0 || key.hasPrefix($0 + "/") }
                                          })
            report.unchanged = plan.unchanged
            report.skippedLocked = plan.skipped.filter { self.isLocked($0) }.count
            report.pending = plan.skipped.count - report.skippedLocked
            report.reset = plan.reset?.rawValue
            if plan.reset != nil {
                // Rebuilt from the copy step's results; skipped (locked) paths keep what they had.
                let kept = Set(plan.skipped)
                state.entries = state.entries.filter { kept.contains($0.key) }
            }
            progress.begin(plan.actions.count)
            let copies = plan.actions.filter { [.resolve, .download, .upload, .forget].contains($0.kind) }
            let deletions = plan.actions.filter { [.deleteLocal, .deleteRemote].contains($0.kind) }
            var remainingRemote = Set(tree.files.values.map { $0.path })
            var deletedRemote: [String] = []
            var applied = 0
            for phase in [copies, deletions] {
                try await execute(phase, scan: scan, tree: tree, scratch: scratch) { outcome in
                    for (key, entry) in outcome.updates { state.entries[key] = entry }
                    if let counter = outcome.counter { report.count(counter) }
                    if let file = outcome.conflictFile { report.conflictFiles.append(file) }
                    for path in outcome.uploadedPaths { remainingRemote.insert(path) }
                    if let path = outcome.deletedRemotePath {
                        remainingRemote.remove(path)
                        deletedRemote.append(path)
                    }
                    if let path = outcome.deletedLocalPath { deletedLocal.append(path) }
                    if let error = outcome.error {
                        report.pending += 1
                        if case .changedDuringSync = error {} else { report.errors.append(error.message) }
                    }
                    applied += 1
                    if applied % max(1, self.checkpointEvery) == 0 { try? self.store.save(state) }
                }
            }
            await pruneRemoteFolders(deleted: deletedRemote, remaining: remainingRemote, collections: tree.collections)
            if isCancelled { throw WebDAVError.cancelled }
            state.lastSync = Date().timeIntervalSince1970
        } catch {
            let failure = WebDAVError.from(error, host: client.host)
            self.failure = failure
            report.failure = failure.reason
            report.cancelled = failure == .cancelled
            report.errors.append(failure.message)
        }
        // Also after a run that stopped early: a half-emptied package folder must not look like a document.
        LocalFiles.pruneEmptyFolders(root: root, deleted: deletedLocal)
        report.finished = Date().timeIntervalSince1970
        state.lastReport = report
        try? store.save(state)
        return report
    }

    /// Runs `actions` with at most `concurrency` at a time; `apply` sees every outcome on this task, in completion
    /// order. A fatal error (authentication, network, cancellation) stops the phase and is rethrown.
    func execute(_ actions: [MirrorAction], scan: LocalScan, tree: RemoteTree, scratch: URL,
                 apply: (Outcome) -> Void) async throws {
        guard !actions.isEmpty else { return }
        var fatal: WebDAVError?
        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func startNext() {
                guard next < actions.count else { return }
                let action = actions[next]
                next += 1
                group.addTask { await self.perform(action, scan: scan, tree: tree, scratch: scratch) }
            }
            for _ in 0..<min(max(1, concurrency), actions.count) { startNext() }
            while let outcome = await group.next() {
                progress.step()
                if let e = outcome.error, e.isFatal {
                    if fatal == nil { fatal = e }
                    group.cancelAll()
                    continue
                }
                apply(outcome)
                if fatal == nil && !isCancelled { startNext() }
            }
        }
        if let e = fatal { throw e }
        if isCancelled { throw WebDAVError.cancelled }
    }

    func perform(_ action: MirrorAction, scan: LocalScan, tree: RemoteTree, scratch: URL) async -> Outcome {
        if isCancelled { return Outcome(error: .cancelled) }
        let key = action.key
        let local = scan.files[key]
        let remote = tree.files[key]
        do {
            switch action.kind {
            case .forget:
                return Outcome(updates: [(key, nil)])
            case .upload:
                guard let l = local else { return Outcome() }
                let remotePath = remote?.path ?? l.path
                let entry = try await upload(l.path, to: remotePath, createOnly: remote == nil, scratch: scratch)
                return Outcome(updates: [(key, entry)], counter: .uploaded, uploadedPaths: [remotePath])
            case .download:
                guard let r = remote else { return Outcome() }
                let temp = scratch.appendingPathComponent(UUID().uuidString)
                try await client.get(client.libraryFileURL(r.path), to: temp)
                let installed = try LocalFiles.install(temp, root: root, path: local?.path ?? r.path, expected: local)
                return Outcome(updates: [(key, SyncedEntry(local: installed.fingerprint, remote: r.version))],
                               counter: .downloaded)
            case .deleteLocal:
                guard let l = local else { return Outcome(updates: [(key, nil)]) }
                try LocalFiles.remove(root: root, path: l.path, expected: l)
                return Outcome(updates: [(key, nil)], counter: .deletedLocal, deletedLocalPath: l.path)
            case .deleteRemote:
                guard let r = remote else { return Outcome(updates: [(key, nil)]) }
                guard LocalFiles.isConfirmedAbsent(root: root, path: r.path) else {
                    return Outcome(error: .changedDuringSync(r.path))
                }
                try await client.delete(client.libraryFileURL(r.path))
                return Outcome(updates: [(key, nil)], counter: .deletedRemote, deletedRemotePath: r.path)
            case .resolve:
                guard let l = local, let r = remote else { return Outcome() }
                return try await resolve(key, local: l, remote: r, conflictPath: action.conflictPath, scratch: scratch)
            }
        } catch {
            return Outcome(error: WebDAVError.from(error, host: client.host))
        }
    }

    /// Uploads `root/path` to the library-relative `remotePath` and reads back the server's version.
    func upload(_ path: String, to remotePath: String, createOnly: Bool, scratch: URL) async throws -> SyncedEntry {
        let (copy, entry) = try LocalFiles.snapshot(root: root, path: path, into: scratch)
        defer { try? FileManager.default.removeItem(at: copy) }
        let parent = remotePath.split(separator: "/").dropLast().joined(separator: "/")
        try await client.ensureCollections(client.serverComponents(libraryPath: parent))
        let etag = try await client.put(file: copy, to: client.libraryFileURL(remotePath), createOnly: createOnly)
        let version = (try? await client.version(ofLibraryFile: remotePath))
            ?? etag.map { "e:" + WebDAVPaths.normalizeETag($0) }
        // An unknown version reads as "changed on the server" next time: one harmless re-download, then stable.
        return SyncedEntry(local: entry.fingerprint, remote: version ?? "")
    }

    /// Same path on both sides with different histories. Identical bytes → just remember them. Otherwise the
    /// server's copy is saved next to the local file under a conflict-copy name (NibStore merges it as a conflict
    /// copy), the local file is pushed to the path, and the conflict copy is pushed too, so every device keeps both.
    func resolve(_ key: String, local: LocalEntry, remote: RemoteEntry, conflictPath: String?,
                 scratch: URL) async throws -> Outcome {
        let temp = scratch.appendingPathComponent(UUID().uuidString)
        try await client.get(client.libraryFileURL(remote.path), to: temp)
        if LocalFiles.sameContents(temp, root.appendingPathComponent(local.path)) {
            try? FileManager.default.removeItem(at: temp)
            guard let current = LocalFiles.stat(root.appendingPathComponent(local.path), path: local.path),
                  current.fingerprint == local.fingerprint else { throw WebDAVError.changedDuringSync(local.path) }
            return Outcome(updates: [(key, SyncedEntry(local: current.fingerprint, remote: remote.version))],
                           counter: .unchanged)
        }
        let copyPath = conflictPath ?? ConflictNaming.name(for: local.path, device: deviceHex, taken: [])
        let copyKey = WebDAVPaths.key(copyPath)
        let copy = try LocalFiles.install(temp, root: root, path: copyPath, expected: nil)
        var outcome = Outcome(counter: .conflicts, conflictFile: copyPath)
        // From here the server's version is safe locally: if a push fails, the next run pushes the local file
        // ("" = local changed) instead of resolving the same divergence again.
        outcome.updates = [(key, SyncedEntry(local: "", remote: remote.version)),
                           (copyKey, SyncedEntry(local: copy.fingerprint, remote: ""))]
        do {
            let pushed = try await upload(local.path, to: remote.path, createOnly: false, scratch: scratch)
            outcome.updates[0] = (key, pushed)
            outcome.uploadedPaths.append(remote.path)
            let pushedCopy = try await upload(copyPath, to: copyPath, createOnly: true, scratch: scratch)
            outcome.updates[1] = (copyKey, pushedCopy)
            outcome.uploadedPaths.append(copyPath)
        } catch {
            outcome.error = WebDAVError.from(error, host: client.host)
            if outcome.updates[1].1?.remote == "" { outcome.updates[1] = (copyKey, nil) }
        }
        return outcome
    }

    /// Deletes server folders that only held files this run deleted (a moved or purged document), deepest first.
    /// Each one is re-listed right before the DELETE, so a file another device just added is never removed.
    func pruneRemoteFolders(deleted: [String], remaining: Set<String>, collections: Set<String>) async {
        guard !deleted.isEmpty, !isCancelled else { return }
        var candidates = Set<String>()
        for path in deleted {
            var parts = path.split(separator: "/").map(String.init)
            parts.removeLast()
            while !parts.isEmpty {
                candidates.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        var pruned = Set<String>()
        for folder in candidates.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            if isCancelled { return }
            let prefix = folder + "/"
            let busy = remaining.contains { $0.hasPrefix(prefix) }
                || collections.contains { $0.hasPrefix(prefix) && !pruned.contains($0) }
            if busy { continue }
            let url = WebDAVPaths.collectionURL(client.configuration.libraryURL,
                                                components: folder.split(separator: "/").map(String.init))
            guard let listing = try? await client.propfind(url, depth: 1) else { continue }
            let members = WebDAVMultistatusParser.members(of: listing, requestComponents: WebDAVPaths.components(of: url))
            guard members.allSatisfy({ WebDAVMirrorFilter.isExcludedName($0.name) }) else { continue }
            if (try? await client.delete(url)) != nil { pruned.insert(folder) }
        }
    }
}
