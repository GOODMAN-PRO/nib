import Foundation
import os
import NibContracts

/// One synced setting as stored in a prefs file: its value (JSON `null` = removed) and the revision that wrote it.
struct PrefEntry: Codable, Equatable {
    var rev: Rev
    var value: JSONValue

    init(rev: Rev, value: JSONValue) {
        self.rev = rev
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case rev, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = try c.decode(Rev.self, forKey: .rev)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rev, forKey: .rev)
        try c.encode(value, forKey: .value)
    }
}

/// Per-key last-writer-wins merge of prefs files.
enum PrefsMerge {
    /// `incoming` merged into `base`: per key, the entry with the higher (effective) revision wins; `base` wins ties.
    static func merge(_ base: [String: PrefEntry], _ incoming: [String: PrefEntry],
                      now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> [String: PrefEntry] {
        var out = base
        for (name, entry) in incoming {
            if let current = out[name], current.rev.effective(now: now) >= entry.rev.effective(now: now) { continue }
            out[name] = entry
        }
        return out
    }

    /// Names whose value differs between two merged states.
    static func changedNames(_ a: [String: PrefEntry], _ b: [String: PrefEntry]) -> [String] {
        Set(a.keys).union(b.keys).filter { (a[$0]?.value ?? .null) != (b[$0]?.value ?? .null) }.sorted()
    }

    static func decode(_ data: Data) -> [String: PrefEntry]? {
        guard let raw = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        var out: [String: PrefEntry] = [:]
        for (name, value) in raw {
            if let entry = try? value.decode(PrefEntry.self) { out[name] = entry }
        }
        return out
    }

    static func encode(_ entries: [String: PrefEntry]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(entries)
    }
}

/// The library's synced settings (`SettingsStore.syncedBackend`): `prefs.<dev>.json` files in the `.nib-library` folder, one per device,
/// merged per key by revision (ARCHITECTURE §4.3). Each device writes only its own file, holding the full merged state
/// it knows; a collection is one key per entry, so additions on two devices never collide. A removed setting is kept
/// as a `null` entry with its revision, so the removal wins over older values from other devices.
///
/// Thread-safe: `SettingsStore` calls it from any thread. Writes are coalesced and done on a private queue.
final class LibraryPrefs: SyncedSettingsBackend {
    private let device: String
    private let clock: HLCClock
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.nib.library.prefs", qos: .utility)
    private let log = Logger(subsystem: "app.nib", category: "library")
    private var directory: URL?
    private var merged: [String: PrefEntry] = [:]
    private var loaded = false
    private var dirty = false
    private var writeScheduled = false
    /// Conflict copies whose entries are merged in: deleted once this device's file holds them.
    private var copies: [URL] = []
    /// Writes that failed in a row; each retry waits twice as long, up to `maxRetries`.
    private var failures = 0
    static let maxRetries = 8
    /// Coalescing delay of writes.
    var writeDelay: TimeInterval = 0.5

    init(device: String, clock: HLCClock, directory: URL?) {
        self.device = device
        self.clock = clock
        self.directory = directory
    }

    // MARK: SyncedSettingsBackend

    func value(_ name: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let v = merged[name]?.value, v != .null else { return nil }
        return v
    }

    func setValue(_ name: String, _ value: JSONValue?) {
        lock.lock()
        loadIfNeeded()
        let v = value ?? .null
        if let current = merged[name], current.value == v {
            lock.unlock()
            return
        }
        if let current = merged[name] { clock.observe(current.rev) }
        merged[name] = PrefEntry(rev: clock.tick(), value: v)
        dirty = true
        let schedule = !writeScheduled
        writeScheduled = true
        let delay = writeDelay
        lock.unlock()
        if schedule {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.writeNow() }
        }
    }

    func names() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return merged.filter { $0.value.value != .null }.keys.sorted()
    }

    // MARK: Loading, reloading, switching libraries

    /// Re-reads every prefs file (other devices' changes after a sync) and returns the names whose value changed.
    @discardableResult
    func reload() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard loaded else {
            loadIfNeeded()
            return []
        }
        let before = merged
        let (fromDisk, found) = readFiles()
        merged = PrefsMerge.merge(merged, fromDisk)
        copies = found
        for e in merged.values { clock.observe(e.rev) }
        let changed = PrefsMerge.changedNames(before, merged)
        if !found.isEmpty && !dirty {
            dirty = true
            scheduleLocked()
        }
        return changed
    }

    /// Switches to another library's `.nib-library` (after writing pending changes to the old one); returns the names
    /// whose value differs between the two libraries. The old library's state is taken and the switch made under one
    /// lock, so a change that lands meanwhile is written to the library it was made in.
    @discardableResult
    func setDirectory(_ url: URL?) -> [String] {
        lock.lock()
        let before = merged
        let old = directory
        let pending = dirty ? merged : nil
        let oldCopies = copies
        directory = url
        loaded = false
        merged = [:]
        copies = []
        dirty = false
        failures = 0
        loadIfNeeded()
        let changed = PrefsMerge.changedNames(before, merged)
        lock.unlock()
        if let snapshot = pending, let dir = old {
            let device = self.device, log = self.log
            queue.sync {
                do {
                    try LibraryPrefs.write(snapshot, device: device, to: dir, removing: oldCopies)
                } catch {
                    log.error("could not save the settings of the previous library: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return changed
    }

    /// Writes pending changes now (app backgrounding, switching libraries, tests).
    func flush() {
        queue.sync { writeNow() }
    }

    // MARK: Private

    /// Must hold `lock`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let (fromDisk, found) = readFiles()
        merged = PrefsMerge.merge(merged, fromDisk)
        copies = found
        for e in merged.values { clock.observe(e.rev) }
        if !found.isEmpty {
            dirty = true
            scheduleLocked()
        }
    }

    /// Every prefs file merged (this device's file first), and the conflict copies among them. Must hold `lock`.
    private func readFiles() -> ([String: PrefEntry], [URL]) {
        guard let dir = directory else { return ([:], []) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let own = LibraryLayout.prefsFileName(device)
        var out: [String: PrefEntry] = [:]
        var copies: [URL] = []
        for name in FolderRecords.sortedOwnFirst(names.filter { LibraryLayout.isPrefsFile($0) }, own: own) {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let entries = PrefsMerge.decode(data) else { continue }
            out = PrefsMerge.merge(out, entries)
            if LibraryLayout.device(of: name, prefix: LibraryLayout.prefsPrefix)?.exact == false { copies.append(url) }
        }
        return (out, copies)
    }

    /// Must hold `lock`.
    private func scheduleLocked(after delay: TimeInterval? = nil) {
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + (delay ?? writeDelay)) { [weak self] in self?.writeNow() }
    }

    /// This device's prefs file holding `entries`, then the merged conflict copies removed.
    private static func write(_ entries: [String: PrefEntry], device: String, to dir: URL, removing copies: [URL]) throws {
        let data = try PrefsMerge.encode(entries)
        try FileOps.write(data, to: dir.appendingPathComponent(LibraryLayout.prefsFileName(device)))
        for url in copies { try? FileOps.remove(url) }
    }

    /// Runs on `queue`.
    private func writeNow() {
        lock.lock()
        writeScheduled = false
        guard dirty, let dir = directory else {
            lock.unlock()
            return
        }
        let snapshot = merged
        let toDelete = copies
        dirty = false
        lock.unlock()
        do {
            try LibraryPrefs.write(snapshot, device: device, to: dir, removing: toDelete)
            lock.lock()
            copies.removeAll { toDelete.contains($0) }
            failures = 0
            lock.unlock()
        } catch {
            log.error("could not save library settings: \(error.localizedDescription, privacy: .public)")
            lock.lock()
            // Still this library: try again later (backing off), not only at the next change or backgrounding.
            if directory == dir {
                dirty = true
                failures += 1
                if failures <= LibraryPrefs.maxRetries {
                    scheduleLocked(after: min(60, writeDelay * pow(2, Double(failures))))
                }
            }
            lock.unlock()
        }
    }
}
