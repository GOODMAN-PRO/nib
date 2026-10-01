import Foundation
import CryptoKit
import NibContracts

// Device-local trust for plugins (docs/PLUGIN_API.md §1, ARCHITECTURE.md §11). The installer (F079) writes a grant
// after the user consents; the host only reads grants, and runs a plugin only while the sha256 of its installed folder
// still equals the hash the user approved. A plugin that arrives through a synced library, or changes on disk, is
// therefore "needs review" on this device until the user approves it again.

/// One device-local grant: the folder hash the user approved and the scopes they consented to.
/// Wire form (one entry of Application Support/PluginGrants.json): {"sha256": "<hex>", "scopes": ["document:read", …]}.
/// `source` (where the plugin came from) is optional and written by the installer when it knows it.
struct PluginGrant: Codable, Equatable {
    var sha256: String
    var scopes: [String]
    var source: String?

    init(sha256: String, scopes: [String], source: String? = nil) {
        self.sha256 = sha256
        self.scopes = scopes
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case sha256, scopes, source }

    /// Lenient: a grant without a hash never matches a folder, a grant without scopes grants nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = (try? c.decodeIfPresent(String.self, forKey: .sha256)) ?? ""
        scopes = (try? c.decodeIfPresent([String].self, forKey: .scopes)) ?? []
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// Reads Application Support/PluginGrants.json (`{"<plugin id>": PluginGrant}`). Thread-safe; the file is re-read when
/// its modification date or size changes (checked at most every `recheckInterval` on the fast path, always on
/// `reload()`), so a grant the installer or the plugin manager rewrote takes effect without a relaunch.
final class PluginGrantStore {
    /// Application Support/PluginGrants.json (device-local, never synced, outside the library).
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PluginGrants.json")
    }

    let url: URL
    var recheckInterval: TimeInterval = 0.25
    private let lock = NSLock()
    private var grants: [String: PluginGrant] = [:]
    private var stamp: String?
    private var lastCheck: TimeInterval = -.infinity

    init(url: URL = PluginGrantStore.defaultURL) {
        self.url = url
    }

    /// The grant of one plugin (nil = never approved on this device).
    func grant(_ id: String) -> PluginGrant? {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked(force: false)
        return grants[id]
    }

    /// Every grant on this device.
    func all() -> [String: PluginGrant] {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked(force: false)
        return grants
    }

    /// Re-reads the file now when it changed (the host calls this before loading a plugin).
    func reload() {
        lock.lock()
        refreshLocked(force: true)
        lock.unlock()
    }

    /// Entries that do not decode are skipped; an unreadable or malformed file grants nothing.
    static func decode(_ data: Data) -> [String: PluginGrant] {
        guard let raw = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        var out: [String: PluginGrant] = [:]
        for (id, value) in raw {
            if let g = try? value.decode(PluginGrant.self) { out[id] = g }
        }
        return out
    }

    private func refreshLocked(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastCheck < recheckInterval { return }
        lastCheck = now
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes = attributes else {
            grants = [:]
            stamp = nil
            return
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let current = "\(modified)|\(size)"
        guard current != stamp else { return }
        stamp = current
        grants = (try? Data(contentsOf: url)).map(PluginGrantStore.decode) ?? [:]
    }
}

// MARK: - Folder hash

/// The installed package hash a grant is bound to (shared with the installer F079 and the gallery index F082):
/// sha256, lowercase hex, over every regular file of the plugin folder whose relative path has no component starting
/// with "." (so `.DS_Store` and iCloud placeholders never change it), in byte-wise order of the UTF-8 relative path
/// ("/"-separated). Each file contributes `UTF8(path) 0x00 UTF8(decimal byte count) 0x00 contents`. Plugin data lives
/// in `plugin-data/`, outside the folder, so `nib.storage` writes never change the hash. A folder that contains a
/// symbolic link has no hash (the installer rejects links; a synced one is refused).
enum PluginFolderHash {
    struct File: Equatable {
        var path: String
        var url: URL
        var size: Int64
        var modified: TimeInterval
    }

    /// The package's files, sorted as the hash reads them.
    static func files(_ folder: URL) throws -> [File] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let subpaths = try? fm.subpathsOfDirectory(atPath: folder.path) else {
            throw NibError(.notFound, "plugin folder \(folder.lastPathComponent) is missing")
        }
        var out: [File] = []
        for relative in subpaths {
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let url = folder.appendingPathComponent(relative)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                throw NibError(.invalidParams, "the plugin contains a symbolic link (\(relative))",
                               hint: "reinstall the plugin from its package")
            }
            guard type == .typeRegular else { continue }
            out.append(File(path: relative, url: url, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
        }
        return out.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// The folder hash (reads every file; run it off the main actor).
    static func compute(_ folder: URL) throws -> String {
        try compute(files: files(folder))
    }

    static func compute(files: [File]) throws -> String {
        var hasher = SHA256()
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                throw NibError(.unavailable, "\(file.path) cannot be read yet", hint: "wait until the library finished syncing")
            }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            handle.seek(toFileOffset: 0)
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(size).utf8))
            hasher.update(data: Data([0]))
            // Streamed in 1 MB chunks, so a 20 MB bundle never sits in memory at once.
            var remaining = size
            while remaining > 0 {
                let chunk = handle.readData(ofLength: Int(min(remaining, 1_048_576)))
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
            guard remaining == 0 else {
                throw NibError(.unavailable, "\(file.path) changed while it was read", hint: "try again in a moment")
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A cheap fingerprint of the folder (paths, sizes, modification dates): when it is unchanged the stored hash still
    /// holds, so rescans after every library change do not re-read megabytes of plugin files.
    static func signature(_ files: [File]) -> String {
        files.map { "\($0.path)|\($0.size)|\($0.modified)" }.joined(separator: "\n")
    }

    /// Total bytes of the package's files.
    static func totalBytes(_ files: [File]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

// MARK: - Effective scopes

/// The scopes a plugin may use right now: declared in its manifest AND consented to in its grant, while the grant is
/// still bound to the folder the running copy was loaded from. `plugins:manage` and `security` are never granted.
/// Thread-safe: `Gateway.grants` asks it for every call by a `.plugin(id)` principal.
final class PluginGrantAuthority {
    private struct Loaded {
        var permissions: Set<String>
        var sha256: String
    }

    static let neverGranted: Set<Scope> = [.pluginsManage, .security]

    private let lock = NSLock()
    private var storeValue: PluginGrantStore
    private var loaded: [String: Loaded] = [:]

    init(store: PluginGrantStore) {
        self.storeValue = store
    }

    /// The grants file (tests point it at a temporary file).
    var store: PluginGrantStore {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storeValue
        }
        set {
            lock.lock()
            storeValue = newValue
            lock.unlock()
        }
    }

    /// A plugin started with `permissions` from the folder whose hash is `sha256`.
    func setLoaded(_ id: String, permissions: [String], sha256: String) {
        lock.lock()
        loaded[id] = Loaded(permissions: Set(permissions), sha256: sha256)
        lock.unlock()
    }

    func removeLoaded(_ id: String) {
        lock.lock()
        loaded[id] = nil
        lock.unlock()
    }

    func isLoaded(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded[id] != nil
    }

    func scopes(_ id: String) -> Set<Scope> {
        lock.lock()
        let entry = loaded[id]
        let store = storeValue
        lock.unlock()
        guard let e = entry else { return [] }
        return PluginGrantAuthority.effectiveScopes(declared: e.permissions, grant: store.grant(id), loadedHash: e.sha256)
    }

    /// Declared ∩ consented, only while the grant names the loaded folder hash.
    static func effectiveScopes(declared: Set<String>, grant: PluginGrant?, loadedHash: String) -> Set<Scope> {
        guard let g = grant, !g.sha256.isEmpty, g.sha256 == loadedHash else { return [] }
        let consented = Set(g.scopes)
        return Set(declared.intersection(consented).compactMap { Scope(rawValue: $0) }).subtracting(neverGranted)
    }
}
