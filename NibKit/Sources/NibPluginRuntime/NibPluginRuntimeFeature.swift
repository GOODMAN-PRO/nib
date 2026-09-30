import Foundation
import UIKit
import os
import NibContracts

/// Plugin runtime (F077): runs each JavaScript plugin in its own JavaScriptCore VM and gives it the `nib.*` API of
/// docs/PLUGIN_API.md. Everything a plugin does to documents and the library goes through the command bus as
/// `.plugin(id)`; the runtime itself only adds what has no command: timers, console logs, per-plugin storage,
/// dialogs, the network allowlist and the user's AI. The plugin host (F078) starts plugins through
/// `ServiceKeys.pluginRuntime` and maps their contributions.
public enum NibPluginRuntimeFeature: NibFeature {
    public static let id = "pluginruntime"

    public static func register(_ app: NibApp) {
        app.services.set(PluginRuntime(app: app), for: ServiceKeys.pluginRuntime)
    }
}

let runtimeLog = Logger(subsystem: "app.nib", category: "pluginruntime")

/// The limits of docs/PLUGIN_API.md §1 (and the runtime's own). Tests shorten the timeouts.
struct PluginLimits {
    /// One command handler, event callback or console evaluation.
    var callTimeout: TimeInterval = 30
    /// Handlers of commands declared `longRunning`.
    var longRunningTimeout: TimeInterval = 300
    /// Evaluating the prelude and the entry bundle.
    var startTimeout: TimeInterval = 30
    /// `nib.storage`, per plugin (live keys and values as JSON).
    var storageBytes = 5 * 1_048_576
    /// `nib.storage` changes wait this long before the file is written (one write for a burst of changes).
    var storageWriteDelay: TimeInterval = 0.25
    /// `nib.storage` lists its (synced) folder for other devices' changes at most this often.
    var storageRefreshInterval: TimeInterval = 1
    /// The entry bundle.
    var bundleBytes = 20 * 1_048_576
    /// Event deliveries: at most one per type (and document) in this interval.
    var coalesceInterval: TimeInterval = 0.1
    /// Refs one delivery's `changes` carries at most; past it the event says `truncated: true` (re-query instead).
    var coalescedRefs = 2_000
    var logCapacity = 1_000
    /// Longest console line kept (longer lines are cut and marked).
    var logLineBytes = 8_192
    var maxTimers = 1_000
    /// `nib.net.fetch` response bodies.
    var fetchBytes = 20 * 1_048_576
    var fetchTimeout: TimeInterval = 30
    /// How long `nib.ui.confirm/prompt/choose` wait for the user before answering "cancelled".
    var dialogTimeout: TimeInterval = 600
}

// MARK: - nib.storage

/// A plugin's `nib.storage`: JSON values by key, in `<library metadata>/plugin-data/<id>/storage.<device>.json`,
/// outside the hashed plugin folder so writes never invalidate the grant. Like every library store, each device
/// writes only its own file with the full merged state it knows; readers merge every device's file per key by
/// revision (`Rev`, far-future revisions distrusted), removals are tombstones (dropped after 30 days), and provider
/// conflict copies are merged and then deleted. All work runs on `queue`; the runtime keeps one instance per plugin
/// (across reloads), so that one queue orders every write.
///
/// Files are only ever merged INTO what is already known (last writer wins per key, tombstones included), so a file
/// that cannot be read right now never makes a key disappear. When this device's own file exists but cannot be read
/// (a file provider evicted it, an iCloud placeholder is still downloading) writes are refused with `unavailable`
/// until it can be, since rewriting it from partial state would lose its keys on every device. An own file that
/// reads but does not decode is moved aside to `storage.<device>.corrupt-<ms>.json` before it is rewritten.
///
/// Cost: the folder is listed at most every `refreshInterval`, and changes are written at most every `writeDelay`
/// (0 = at once); `flush()` writes a pending change now.
final class PluginStorage {
    struct Entry: Codable, Equatable {
        var rev: Rev
        var value: JSONValue?
        var deleted: Bool

        init(rev: Rev, value: JSONValue?, deleted: Bool = false) {
            self.rev = rev
            self.value = value
            self.deleted = deleted
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rev = try c.decode(Rev.self, forKey: .rev)
            value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        }

        enum CodingKeys: String, CodingKey { case rev, value, deleted }
    }

    struct FileBody: Codable {
        var version: Int
        var plugin: String
        var entries: [String: Entry]

        init(version: Int = 1, plugin: String, entries: [String: Entry]) {
            self.version = version
            self.plugin = plugin
            self.entries = entries
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            plugin = try c.decodeIfPresent(String.self, forKey: .plugin) ?? ""
            entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        }

        enum CodingKeys: String, CodingKey { case version, plugin, entries }
    }

    static let tombstoneLifetimeMs: UInt64 = 30 * 86_400_000
    static let maxKeyBytes = 1_024

    let pluginID: String
    let folder: URL
    let deviceHex: String
    let limitBytes: Int
    /// How long a change waits before it is written (changes in between share one write); 0 writes at once.
    let writeDelay: TimeInterval
    /// The folder is listed at most this often (0 = on every call).
    let refreshInterval: TimeInterval
    let queue: DispatchQueue
    private let clock: HLCClock
    // Queue-confined.
    private var merged: [String: Entry] = [:]
    private var sizes: [String: Int] = [:]
    private var total = 0
    private var signature: [String: String]?
    private var lastRefresh: DispatchTime?
    /// Why this device's own file cannot be rewritten right now (nil = it can).
    private var ownFileProblem: String?
    private var writePending = false
    private var writeScheduled = false

    init(pluginID: String, folder: URL, deviceHex: String, clock: HLCClock, limitBytes: Int,
         writeDelay: TimeInterval = 0, refreshInterval: TimeInterval = 0) {
        self.pluginID = pluginID
        self.folder = folder
        self.deviceHex = deviceHex
        self.clock = clock
        self.limitBytes = limitBytes
        self.writeDelay = max(0, writeDelay)
        self.refreshInterval = max(0, refreshInterval)
        self.queue = DispatchQueue(label: "app.nib.plugin.storage." + pluginID)
    }

    /// `<metadata>/plugin-data/<id>`.
    static func folder(metadata: URL, pluginID: String) -> URL {
        metadata.appendingPathComponent("plugin-data", isDirectory: true).appendingPathComponent(pluginID, isDirectory: true)
    }

    var fileURL: URL { folder.appendingPathComponent("storage.\(deviceHex).json") }

    /// "storage.<8 hex>.json" (a device's file) or a provider conflict copy of one ("storage.<8 hex> 2.json"); never
    /// a file moved aside as corrupt.
    static func isStorageFile(_ name: String) -> Bool {
        name.range(of: "^storage\\.[0-9a-f]{8}.*\\.json$", options: .regularExpression) != nil && !isCorruptCopy(name)
    }

    static func isConflictCopy(_ name: String) -> Bool {
        isStorageFile(name) && name.range(of: "^storage\\.[0-9a-f]{8}\\.json$", options: .regularExpression) == nil
    }

    /// "storage.<8 hex>.corrupt-<ms>.json": an own file that did not decode, kept for recovery and never read again.
    static func isCorruptCopy(_ name: String) -> Bool {
        name.hasPrefix("storage.") && name.contains(".corrupt-")
    }

    /// The name of the file an iCloud placeholder (".storage.<8 hex>.json.icloud") stands for, else nil.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let target = String(name.dropFirst().dropLast(".icloud".count))
        return isStorageFile(target) ? target : nil
    }

    /// Runs `body` on the storage queue and hands its result to `done` there.
    func async<T>(_ body: @escaping (PluginStorage) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        queue.async { done(Result { try body(self) }) }
    }

    /// Writes a pending change now, on the queue (returns at once).
    func flush() {
        queue.async { self.writePendingChange() }
    }

    /// `flush`, waiting for the write.
    func flushAndWait() {
        queue.sync { self.writePendingChange() }
    }

    // MARK: Operations (on `queue`)

    func get(_ key: String) throws -> JSONValue? {
        try PluginStorage.check(key)
        try refresh()
        guard let e = merged[key], !e.deleted else { return nil }
        return e.value ?? .null
    }

    func set(_ key: String, _ value: JSONValue) throws {
        try PluginStorage.check(key)
        try refresh()
        try checkWritable()
        let size = key.utf8.count + value.jsonString().utf8.count
        let after = total - (sizes[key] ?? 0) + size
        guard after <= limitBytes else {
            throw NibError(.invalidParams, "nib.storage holds at most \(limitBytes / 1_048_576) MB per plugin; this write would make it \(after) bytes",
                           path: "$.value", hint: "remove keys the plugin no longer needs")
        }
        try change { $0.merged[key] = Entry(rev: $0.clock.tick(), value: value); $0.setSize(key, size) }
    }

    func remove(_ key: String) throws {
        try PluginStorage.check(key)
        try refresh()
        // Refused too while the own file is unreadable: the key may well be in it.
        try checkWritable()
        guard let e = merged[key], !e.deleted else { return }
        try change { $0.merged[key] = Entry(rev: $0.clock.tick(), value: nil, deleted: true); $0.setSize(key, nil) }
    }

    func keys() throws -> [String] {
        try refresh()
        return merged.filter { !$0.value.deleted }.keys.sorted()
    }

    /// Bytes counted against the limit: every live key and its JSON value.
    var liveBytes: Int { total }

    // MARK: Merge and files

    /// Merges `incoming` into `base` per key; the higher effective revision wins.
    static func merge(_ incoming: [String: Entry], into base: inout [String: Entry], now: UInt64) {
        for (key, entry) in incoming {
            if let current = base[key], current.rev.effective(now: now) >= entry.rev.effective(now: now) { continue }
            base[key] = entry
        }
    }

    private static func check(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= maxKeyBytes else {
            throw NibError(.invalidParams, "storage keys are 1 to \(maxKeyBytes) bytes", path: "$.key")
        }
    }

    private func checkWritable() throws {
        if let problem = ownFileProblem {
            throw NibError(.unavailable, problem, hint: "try again in a moment; nothing was changed")
        }
    }

    private func setSize(_ key: String, _ size: Int?) {
        total -= sizes[key] ?? 0
        sizes[key] = size
        total += size ?? 0
    }

    private func recomputeSizes() {
        sizes = [:]
        total = 0
        for (key, e) in merged where !e.deleted { setSize(key, key.utf8.count + (e.value ?? .null).jsonString().utf8.count) }
    }

    /// Applies a change to the merged state and writes (or schedules writing) this device's file. A write that fails
    /// at once restores the state.
    private func change(_ body: (PluginStorage) -> Void) throws {
        guard writeDelay > 0 else {
            let saved = (merged, sizes, total)
            body(self)
            do {
                try write()
            } catch {
                (merged, sizes, total) = saved
                throw error
            }
            return
        }
        body(self)
        writePending = true
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + writeDelay) {
            self.writeScheduled = false
            self.writePendingChange()
        }
    }

    private func writePendingChange() {
        guard writePending else { return }
        do {
            try write()
        } catch {
            // Kept pending: the next change or flush tries again.
            runtimeLog.error("plugin \(self.pluginID, privacy: .public) storage: \(NibError.wrap(error).message, privacy: .public)")
        }
    }

    /// Merges every device's file into the known state when the folder changed since the last read (sync brought a
    /// new file), at most every `refreshInterval`.
    func refresh() throws {
        let now = DispatchTime.now()
        if let last = lastRefresh, refreshInterval > 0,
           Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000_000 < refreshInterval {
            return
        }
        lastRefresh = now
        let fm = FileManager.default
        let listing = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let files = listing.filter { PluginStorage.isStorageFile($0.lastPathComponent) }
        let placeholders = listing.filter { PluginStorage.placeholderTarget($0.lastPathComponent) != nil }
        let current = PluginStorage.signature(of: files + placeholders)
        // While the own file cannot be read, every refresh tries again.
        if current == signature, ownFileProblem == nil { return }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let ownName = fileURL.lastPathComponent
        var problem: String?
        var movedAside = false
        var conflicts: [URL] = []
        for url in placeholders {
            // iCloud lists a file that is not downloaded yet as a hidden ".<name>.icloud" placeholder.
            guard let target = PluginStorage.placeholderTarget(url.lastPathComponent) else { continue }
            let real = folder.appendingPathComponent(target)
            try? fm.startDownloadingUbiquitousItem(at: real)
            if target == ownName, !fm.fileExists(atPath: real.path) {
                problem = "the plugin's storage is still downloading"
            }
        }
        for url in files {
            let name = url.lastPathComponent
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                // Evicted by a file provider, dataless while offline, not readable: ask for it, never rewrite without it.
                try? fm.startDownloadingUbiquitousItem(at: url)
                runtimeLog.error("plugin storage file \(name, privacy: .public) is not readable yet: \(error.localizedDescription, privacy: .public)")
                if name == ownName { problem = "the plugin's storage is still downloading" }
                continue
            }
            guard let body = try? JSONDecoder().decode(FileBody.self, from: data) else {
                runtimeLog.error("plugin storage file \(name, privacy: .public) does not decode")
                if name == ownName {
                    if moveAside(url) {
                        movedAside = true
                    } else {
                        problem = "the plugin's storage file is damaged and could not be moved aside"
                    }
                }
                continue
            }
            for e in body.entries.values { clock.observe(e.rev) }
            PluginStorage.merge(body.entries, into: &merged, now: nowMs)
            if PluginStorage.isConflictCopy(name) { conflicts.append(url) }
        }
        ownFileProblem = problem
        recomputeSizes()
        signature = movedAside ? PluginStorage.signature(of: currentFiles()) : current
        guard problem == nil else { return }
        if !conflicts.isEmpty {
            // Only copies that were read are deleted, after the merged state is safely written.
            try write()
            for url in conflicts { try? fm.removeItem(at: url) }
            signature = PluginStorage.signature(of: currentFiles())
        } else if writePending, !writeScheduled {
            scheduleWrite()
        }
    }

    /// Moves an own file that does not decode to "storage.<device>.corrupt-<ms>.json" (kept for recovery).
    private func moveAside(_ url: URL) -> Bool {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let target = folder.appendingPathComponent("storage.\(deviceHex).corrupt-\(ms).json")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return true
        } catch {
            runtimeLog.error("could not move aside \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func write() throws {
        try checkWritable()
        let fm = FileManager.default
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let cutoff = now > PluginStorage.tombstoneLifetimeMs ? now - PluginStorage.tombstoneLifetimeMs : 0
        merged = merged.filter { !$0.value.deleted || $0.value.rev.wallMs >= cutoff }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(FileBody(plugin: pluginID, entries: merged)).write(to: fileURL, options: .atomic)
        } catch {
            throw NibError(.internalError, "could not save the plugin's storage: \(error.localizedDescription)")
        }
        writePending = false
        signature = PluginStorage.signature(of: currentFiles())
    }

    private func currentFiles() -> [URL] {
        let listing = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return listing.filter {
            PluginStorage.isStorageFile($0.lastPathComponent) || PluginStorage.placeholderTarget($0.lastPathComponent) != nil
        }
    }

    private static func signature(of files: [URL]) -> [String: String] {
        var out: [String: String] = [:]
        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            out[url.lastPathComponent] = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? -1)"
        }
        return out
    }
}

// MARK: - nib.net.fetch

/// `nib.net.fetch`: https only, only to the hosts in the manifest's `network.hosts` (redirects included), no cookies
/// or cache, bounded time and size. The body is collected as it arrives and the request is cancelled as soon as the
/// announced length or the bytes received pass `maxBytes`, so the cap bounds memory too. One instance per request.
final class PluginFetcher: NSObject, URLSessionDataDelegate {
    /// Prepended to the session's protocol classes (tests register a stub `URLProtocol`).
    static var protocolClasses: [AnyClass] = []
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

    let hosts: Set<String>
    let maxBytes: Int
    let timeout: TimeInterval

    // Guarded by `lock` (delegate callbacks arrive on the session's queue).
    private let lock = NSLock()
    private var received = Data()
    private var response: URLResponse?
    private var tooLarge = false
    private var continuation: CheckedContinuation<(Data, URLResponse?), Error>?

    init(hosts: Set<String>, maxBytes: Int, timeout: TimeInterval) {
        self.hosts = Set(hosts.map { $0.lowercased() })
        self.maxBytes = maxBytes
        self.timeout = timeout
    }

    /// Throws `permission_denied` unless `url` is https and its host is allowed.
    static func check(_ url: URL, hosts: Set<String>) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw NibError(.permissionDenied, "nib.net.fetch only reaches https URLs", path: "$.url")
        }
        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty, hosts.contains(where: { $0.lowercased() == host }) else {
            throw NibError(.permissionDenied, "'\(host)' is not in the plugin's network.hosts", path: "$.url",
                           hint: "add the host to manifest network.hosts; the user consents to it on install")
        }
    }

    func fetch(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> JSONValue {
        try PluginFetcher.check(url, hosts: hosts)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.protocolClasses = PluginFetcher.protocolClasses + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse?
        do {
            (data, response) = try await load(request, in: session)
        } catch let e as NibError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw NibError(.timeout, "\(url.host ?? "the server") did not answer within \(Int(timeout)) s")
        } catch {
            throw NibError(.unavailable, "the request to \(url.host ?? "the server") failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw NibError(.unavailable, "\(url.host ?? "the server") did not answer over HTTP")
        }
        return PluginFetcher.result(http, data: data)
    }

    private func load(_ request: URLRequest, in session: URLSession) async throws -> (Data, URLResponse?) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse?), Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private var sizeLimitError: NibError {
        let limit = maxBytes >= 1_048_576 ? "\(maxBytes / 1_048_576) MB" : "\(maxBytes) bytes"
        return NibError(.invalidParams, "the response is larger than \(limit)", hint: "request less data (a range, a page, a smaller format)")
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let announcedTooLarge = response.expectedContentLength > Int64(maxBytes)
        lock.lock()
        self.response = response
        if announcedTooLarge { tooLarge = true }
        lock.unlock()
        completionHandler(announcedTooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var cancel = tooLarge
        if !tooLarge {
            if received.count + data.count > maxBytes {
                tooLarge = true
                received = Data()
                cancel = true
            } else {
                received.append(data)
            }
        }
        lock.unlock()
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<(Data, URLResponse?), Error>
        if tooLarge {
            result = .failure(sizeLimitError)
        } else if let error = error {
            result = .failure(error)
        } else {
            result = .success((received, response ?? task.response))
        }
        received = Data()
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// `{status, headers, text, base64?}`: text for textual bodies, base64 (and empty text) for binary ones.
    static func result(_ http: HTTPURLResponse, data: Data) -> JSONValue {
        var headers: [String: JSONValue] = [:]
        for (k, v) in http.allHeaderFields {
            headers[String(describing: k).lowercased()] = .string(String(describing: v))
        }
        let mime = (http.mimeType ?? "").lowercased()
        let textual = mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || mime.contains("javascript")
            || mime.contains("x-www-form-urlencoded") || (mime.isEmpty && String(data: data, encoding: .utf8) != nil)
        var out: [String: JSONValue] = ["status": .number(Double(http.statusCode)), "headers": .object(headers)]
        if textual {
            out["text"] = .string(String(decoding: data, as: UTF8.self))
        } else {
            out["text"] = ""
            out["base64"] = .string(data.base64EncodedString())
        }
        return .object(out)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? PluginFetcher.check(url, hosts: hosts)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - nib.ui

/// Dialogs and toasts for plugins, shown in the active window. Behind a protocol so tests use a fake.
@MainActor
protocol PluginUIPresenting: AnyObject {
    /// False when there is no window to show it in.
    @discardableResult
    func toast(_ message: String, from plugin: PluginManifest) -> Bool
    func confirm(_ title: String, message: String?, from plugin: PluginManifest, timeout: TimeInterval) async throws -> Bool
    func prompt(_ title: String, placeholder: String?, initial: String?, from plugin: PluginManifest,
                timeout: TimeInterval) async throws -> String?
    func choose(_ title: String, options: [String], from plugin: PluginManifest, timeout: TimeInterval) async throws -> Int?
}

/// Shows plugin dialogs as alerts on the active navigator (`SceneNavigator.presentModal`), naming the plugin so a
/// plugin cannot pass its dialog off as the system's, and toasts in the window's floating host.
@MainActor
final class NavigatorPluginUI: PluginUIPresenting {
    private weak var app: NibApp?

    init(app: NibApp?) {
        self.app = app
    }

    private func navigator() throws -> SceneNavigator {
        guard !NibApp.isHostlessTest, let navigator = app?.ui.activeNavigator else {
            throw NibError(.unavailable, "there is no window to show the plugin's dialog in")
        }
        return navigator
    }

    @discardableResult
    func toast(_ message: String, from plugin: PluginManifest) -> Bool {
        guard !NibApp.isHostlessTest, let host = app?.ui.activeNavigator?.floatingHost else { return false }
        host.postToast(message)
        return true
    }

    func confirm(_ title: String, message: String?, from plugin: PluginManifest, timeout: TimeInterval) async throws -> Bool {
        let navigator = try navigator()
        return await ask(navigator, timeout: timeout, cancelled: false) { finish in
            let alert = UIAlertController(title: title, message: Self.message(message, plugin), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(false) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in finish(true) })
            return alert
        }
    }

    func prompt(_ title: String, placeholder: String?, initial: String?, from plugin: PluginManifest,
                timeout: TimeInterval) async throws -> String? {
        let navigator = try navigator()
        return await ask(navigator, timeout: timeout, cancelled: nil) { finish in
            let alert = UIAlertController(title: title, message: Self.message(nil, plugin), preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = placeholder
                field.text = initial
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(nil) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak alert] _ in
                finish(alert?.textFields?.first?.text ?? "")
            })
            return alert
        }
    }

    func choose(_ title: String, options: [String], from plugin: PluginManifest, timeout: TimeInterval) async throws -> Int? {
        let navigator = try navigator()
        return await ask(navigator, timeout: timeout, cancelled: nil) { finish in
            let alert = UIAlertController(title: title, message: Self.message(nil, plugin), preferredStyle: .alert)
            for (index, option) in options.enumerated() {
                alert.addAction(UIAlertAction(title: option, style: .default) { _ in finish(index) })
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(nil) })
            return alert
        }
    }

    private static func message(_ message: String?, _ plugin: PluginManifest) -> String {
        let source = String(localized: "From the plugin \(plugin.name)")
        guard let m = message, !m.isEmpty else { return source }
        return m + "\n\n" + source
    }

    /// Presents the alert `make` builds and waits for one answer; after `timeout` the alert is dismissed and
    /// `cancelled` is the answer.
    private func ask<T>(_ navigator: SceneNavigator, timeout: TimeInterval, cancelled: T,
                        make: (@escaping (T) -> Void) -> UIAlertController) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let state = DialogState()
            let finish: (T) -> Void = { value in
                guard !state.answered else { return }
                state.answered = true
                continuation.resume(returning: value)
            }
            let controller = make(finish)
            navigator.presentModal(controller)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                guard !state.answered else { return }
                controller.dismiss(animated: true)
                finish(cancelled)
            }
        }
    }
}

/// Whether a dialog was answered (its continuation resumes once).
private final class DialogState {
    var answered = false
}
