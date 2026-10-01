import Foundation
import NibContracts

/// A pending document is replaced when it changes again. A writer can acknowledge only the exact version it read.
struct BackupQueue: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var document: DocumentID
        var token: UUID = UUID()
        var queuedAt: Double
    }
    private(set) var entries: [Entry] = []
    var lastAttempt: Double?
    var lastSuccess: Double?
    // Derived from entries and excluded from disk state. Commits must not scan the whole queue.
    private var indices: [DocumentID: Int] = [:]

    private enum CodingKeys: String, CodingKey { case entries, lastAttempt, lastSuccess }

    init() { }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([Entry].self, forKey: .entries)
        lastAttempt = try values.decodeIfPresent(Double.self, forKey: .lastAttempt)
        lastSuccess = try values.decodeIfPresent(Double.self, forKey: .lastSuccess)
        rebuildIndices()
    }

    private mutating func rebuildIndices() {
        indices = Dictionary(entries.enumerated().map { ($0.element.document, $0.offset) },
                             uniquingKeysWith: { first, _ in first })
    }

    func contains(_ document: DocumentID) -> Bool { indices[document] != nil }

    mutating func enqueue(_ document: DocumentID, at time: Double) {
        if let i = indices[document] {
            entries[i].token = UUID()
        } else {
            indices[document] = entries.count
            entries.append(Entry(document: document, queuedAt: time))
        }
    }
    mutating func acknowledge(_ entry: Entry) {
        entries.removeAll { $0.document == entry.document && $0.token == entry.token }
        rebuildIndices()
    }
    mutating func retain(_ documents: Set<DocumentID>) {
        entries.removeAll { !documents.contains($0.document) }
        rebuildIndices()
    }
    mutating func clear() { entries.removeAll(); indices.removeAll() }

    static func interval(frequent: Bool) -> TimeInterval { frequent ? 90 : 12 * 60 * 60 }
    func isDue(at time: Double, frequent: Bool) -> Bool {
        guard !entries.isEmpty else { return false }
        return time - (lastAttempt ?? entries.map(\.queuedAt).min() ?? time) >= Self.interval(frequent: frequent)
    }

    static func excluded(_ name: String, substrings: [String]) -> Bool {
        substrings.contains { term in
            !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }

    /// Revision and provenance changes alone do not count. Deletions, favourites and custom outline changes
    /// leave the existing remote backup intact; an actual subsequent content change includes the latest state.
    static func triggers(_ mutation: Mutation) -> Bool {
        switch mutation {
        case .outline: return false
        case let .item(_, _, _, after): return !after.deleted
        case let .block(_, _, after): return !after.deleted
        case let .card(_, _, after): return !after.deleted
        case let .audio(_, _, after): return !after.deleted
        case let .page(_, before, after):
            guard !after.deleted else { return false }
            guard var before else { return true }
            var after = after
            before.rev = .zero; after.rev = .zero
            before.bookmarked = after.bookmarked
            return (try? JSONValue.from(before)) != (try? JSONValue.from(after))
        case let .meta(_, before, after):
            if after.trashedFrom != nil { return false }
            var before = before, after = after
            before.rev = .zero; after.rev = .zero
            before.favorite = after.favorite
            return (try? JSONValue.from(before)) != (try? JSONValue.from(after))
        }
    }

    /// `modified` is deliberately ignored: it changes after favourite/outline edits as well as content edits.
    static func changedDocuments(before: [LibraryNode], after: [LibraryNode]) -> Set<DocumentID> {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let folders = Dictionary(after.filter { $0.kind == .folder }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changedFolders = Set(folders.values.filter { node in
            old[node.id].map { $0.path != node.path || $0.title != node.title || $0.parent != node.parent } ?? true
        }.map(\.id))
        return Set(after.filter { node in
            guard node.kind == .document, node.trashedAt == nil else { return false }
            if old[node.id].map({ $0.path != node.path || $0.title != node.title || $0.parent != node.parent || $0.trashedAt != nil }) ?? true {
                return true
            }
            var parent = node.parent
            var visited = Set<FolderID>()
            while let id = parent, visited.insert(id).inserted {
                if changedFolders.contains(id) { return true }
                parent = folders[id]?.parent
            }
            return false
        }.map(\.id))
    }
}

/// Serial, atomic per-device disk state, kept outside the synced library. Corruption is reported, never silently reset.
actor BackupQueueStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> BackupQueue {
        guard FileManager.default.fileExists(atPath: url.path) else { return BackupQueue() }
        return try JSONDecoder().decode(BackupQueue.self, from: Data(contentsOf: url))
    }
    func save(_ queue: BackupQueue) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(queue).write(to: url, options: .atomic)
        var resource = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
}

struct BackupDestination: Codable, Equatable {
    var kind: String
    var folder: String?
}

struct BackupConfiguration: Codable, Equatable {
    var destination: BackupDestination
    var format: String
    var folder: String
    var exclusions: [String]
    var frequent: Bool
}

enum BackupSettings {
    static let destination = SettingKey("backup.destination", default: BackupDestination(kind: "none"))
    static let format = SettingKey("backup.format", default: "nib")
    static let folder = SettingKey("backup.folder", default: "Nib Backups")
    static let frequent = SettingKey("backup.frequent", default: false)
    static let bookmark = SettingKey<Data?>("backup.bookmark", default: nil)
    static let folderName = SettingKey("backup.folderName", default: "")
    static let exclusionPrefix = "backup.exclusion."

    static func declare(_ store: SettingsStore) {
        store.declare(destination, summary: "Automatic backup destination on this device", owner: "backup", readOnly: true)
        store.declare(format, summary: "Automatic backup format: nib, PDF or both", owner: "backup", schema: .str(choices: ["nib", "pdf", "both"]), readOnly: true)
        store.declare(folder, summary: "Backup subfolder", owner: "backup", readOnly: true)
        store.declare(frequent, summary: "Use a 90-second interval instead of 12 hours", owner: "backup", readOnly: true)
        store.declare(bookmark, summary: "Folder grant from backup.chooseFolder", owner: "backup", readOnly: true)
        store.declare(folderName, summary: "Chosen folder name", owner: "backup", readOnly: true)
        store.declarePrefix(exclusionPrefix, synced: true, summary: "Excluded file name substring", owner: "backup", schema: .str(), readOnly: true)
    }
    static func read(_ store: SettingsStore) -> BackupConfiguration {
        let exclusions = store.names(prefix: exclusionPrefix).compactMap {
            store.get(SettingKey<String?>($0, default: nil, synced: true))
        }.sorted()
        return BackupConfiguration(destination: store.get(destination), format: store.get(format),
                                   folder: store.get(folder), exclusions: exclusions, frequent: store.get(frequent))
    }
    static func write(_ config: BackupConfiguration, to store: SettingsStore) {
        store.set(destination, config.destination); store.set(format, config.format)
        store.set(folder, config.folder); store.set(frequent, config.frequent)
        for name in store.names(prefix: exclusionPrefix) { store.set(SettingKey<String?>(name, default: nil, synced: true), nil) }
        for term in Set(config.exclusions) {
            // Stable entry ids keep concurrent exclusions independent across devices.
            let key = exclusionPrefix + Data(term.utf8).base64EncodedString()
            store.set(SettingKey<String?>(key, default: nil, synced: true), term)
        }
    }
}

/// A record-level comparison of library rescans. Missing records are deletions; only new or changed live values
/// trigger work. The baseline is stored separately from the frequently-written queue, one file per document.
struct BackupContentStamp: Codable, Equatable {
    var records: [String: String] = [:]
    // Optional for queues stamped before revision caching was introduced.
    var pageRevisions: [String: Rev]?
    func hasChanges(since old: BackupContentStamp) -> Bool {
        records.contains { old.records[$0.key] != $0.value }
    }
}

extension BackupQueueStore {
    private func stampURL(_ document: DocumentID) -> URL {
        // NibID accepts arbitrary caller ids; base64 avoids treating an id as a path.
        let name = Data(document.raw.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-stamps")
            .appendingPathComponent(name + ".json")
    }
    func loadStamp(_ document: DocumentID) throws -> BackupContentStamp? {
        let location = stampURL(document)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        return try JSONDecoder().decode(BackupContentStamp.self, from: Data(contentsOf: location))
    }
    func saveStamp(_ stamp: BackupContentStamp, document: DocumentID) throws {
        let location = stampURL(document)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stamp).write(to: location, options: .atomic)
    }
}
