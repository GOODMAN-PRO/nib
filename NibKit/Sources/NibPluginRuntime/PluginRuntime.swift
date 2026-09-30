import Foundation
import UIKit
import os
import NibContracts

// MARK: - Provider

/// `PluginRuntimeProviding` (`ServiceKeys.pluginRuntime`): starts plugins, one `PluginInstance` each.
@MainActor
final class PluginRuntime: PluginRuntimeProviding {
    private weak var app: NibApp?
    var limits = PluginLimits()
    /// Dialogs and toasts (tests install a fake).
    lazy var ui: PluginUIPresenting = NavigatorPluginUI(app: app)
    /// Safe Mode check (tests replace it instead of touching the launch counter).
    var isSafeMode: () -> Bool = { SafeMode.isActive }
    private(set) var running: [String: PluginInstance] = [:]
    /// One `nib.storage` per plugin, kept across reloads so a single queue orders all of its writes.
    private var storages: [String: PluginStorage] = [:]
    nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
        // Debounced storage writes reach the disk before the app can be suspended.
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushStorage() }
        }
    }

    deinit {
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// The plugin's `nib.storage` (nil without a library folder): the same instance for every start of the plugin
    /// while the library and the limits stay the same.
    func storage(for pluginID: String) -> PluginStorage? {
        guard let app = app, let metadata = app.services.library?.metadataURL else { return nil }
        let folder = PluginStorage.folder(metadata: metadata, pluginID: pluginID)
        if let existing = storages[pluginID], existing.folder == folder, existing.limitBytes == limits.storageBytes,
           existing.writeDelay == max(0, limits.storageWriteDelay),
           existing.refreshInterval == max(0, limits.storageRefreshInterval) {
            return existing
        }
        // A different library (or limits): the old instance writes what it still holds before the new one reads.
        storages[pluginID]?.flushAndWait()
        let storage = PluginStorage(pluginID: pluginID, folder: folder, deviceHex: app.deviceHex, clock: app.clock,
                                    limitBytes: limits.storageBytes, writeDelay: limits.storageWriteDelay,
                                    refreshInterval: limits.storageRefreshInterval)
        storages[pluginID] = storage
        return storage
    }

    /// Writes every plugin's pending storage changes now.
    func flushStorage() {
        for storage in storages.values { storage.flush() }
    }

    func start(_ manifest: PluginManifest, folder: URL) async throws -> PluginRuntimeHandle {
        try await startInstance(manifest, folder: folder)
    }

    /// `start`, typed.
    func startInstance(_ manifest: PluginManifest, folder: URL) async throws -> PluginInstance {
        guard let app = app else { throw NibError.unavailable("the app") }
        if isSafeMode() {
            throw NibError(.unavailable, "Nib is in Safe Mode, so plugins do not run",
                           hint: "restart Nib normally to use plugins again")
        }
        try PluginRuntime.validate(manifest)
        let entry = try PluginRuntime.entryURL(manifest, folder: folder)
        let prelude = try PluginRuntime.preludeSource()
        running[manifest.id]?.stop()
        let instance = PluginInstance(runtime: self, app: app, manifest: manifest, folder: folder, limits: limits,
                                      storage: storage(for: manifest.id))
        running[manifest.id] = instance
        do {
            try await instance.boot(prelude: prelude, entry: entry)
        } catch {
            instance.stop()
            throw error
        }
        return instance
    }

    /// The running instance of a plugin.
    func handle(_ id: String) -> PluginInstance? { running[id] }

    func didStop(_ instance: PluginInstance) {
        if running[instance.manifest.id] === instance { running[instance.manifest.id] = nil }
    }

    // MARK: Validation

    nonisolated static func validate(_ manifest: PluginManifest) throws {
        guard manifest.api == 1 else {
            throw NibError(.unsupported, "plugin API version \(manifest.api) is not supported (this Nib runs version 1)",
                           path: "$.api", hint: "update Nib, or ask the plugin's author for an api 1 build")
        }
        guard manifest.id.range(of: "^[a-z0-9]+([.-][a-z0-9]+)*$", options: .regularExpression) != nil,
              manifest.id.contains(".") else {
            throw NibError(.invalidParams, "plugin ids are reverse-DNS names of [a-z0-9.-], e.g. dev.example.cards", path: "$.id")
        }
    }

    /// The entry bundle inside `folder`: a relative path that stays inside the folder, symlinks resolved.
    nonisolated static func entryURL(_ manifest: PluginManifest, folder: URL) throws -> URL {
        let entry = manifest.entry
        guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.contains("\\"),
              !entry.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw NibError(.invalidParams, "the entry must be a path inside the plugin folder", path: "$.entry")
        }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(entry).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else {
            throw NibError(.invalidParams, "the entry must be a path inside the plugin folder", path: "$.entry")
        }
        return url
    }

    /// Reads the entry bundle (on the plugin's queue): UTF-8, at most `maxBytes`.
    nonisolated static func readEntry(_ url: URL, maxBytes: Int) throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue else {
            throw NibError(.notFound, "the plugin's entry script \(url.lastPathComponent) is missing", path: "$.entry")
        }
        guard size <= maxBytes else {
            throw NibError(.invalidParams, "the entry script is larger than \(maxBytes / 1_048_576) MB", path: "$.entry")
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw NibError(.invalidParams, "the entry script is not UTF-8 text", path: "$.entry")
        }
        return text
    }

    private nonisolated static let prelude: String? = {
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js"),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }()

    nonisolated static func preludeSource() throws -> String {
        guard let p = prelude else { throw NibError(.internalError, "the plugin prelude is missing from the app bundle") }
        return p
    }
}

// MARK: - Logs and subscriptions (thread-safe)

/// The console ring buffer behind `PluginRuntimeHandle.logs`.
final class LogRing {
    static let truncationMark = "… (truncated)"
    private let lock = NSLock()
    private var buffer: [String] = []
    private let capacity: Int
    private let maxLineBytes: Int
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(capacity: Int, maxLineBytes: Int = 8_192) {
        self.capacity = max(1, capacity)
        self.maxLineBytes = max(64, maxLineBytes)
    }

    func append(_ level: String, _ text: String) {
        let text = LogRing.truncate(text, maxBytes: maxLineBytes)
        let stamp: String
        lock.lock()
        stamp = LogRing.clock.string(from: Date())
        buffer.append("\(stamp) [\(level)] \(text)")
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// `text` cut to at most `maxBytes` of UTF-8 and marked, so one `console.log(hugeObject)` cannot hold megabytes.
    static func truncate(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var cut = text.utf8.prefix(maxBytes).endIndex
        // Back up to a character boundary.
        while cut > text.startIndex, String.Index(cut, within: text) == nil { cut = text.utf8.index(before: cut) }
        return String(text[..<cut]) + truncationMark
    }
}

/// Event types the plugin's JavaScript listens to (from `nib.events.on`), counted per type.
final class SubscriptionTable {
    private let lock = NSLock()
    private var all: [String: Int] = [:]
    private var own: [String: Int] = [:]

    func update(_ type: String, includeOwn: Bool, delta: Int) {
        lock.lock()
        all[type] = max(0, (all[type] ?? 0) + delta)
        if includeOwn { own[type] = max(0, (own[type] ?? 0) + delta) }
        lock.unlock()
    }

    /// True when a listener wants `type`; for the plugin's own events only listeners with `{self: true}` count.
    func wants(_ type: String, own isOwn: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOwn ? (own[type] ?? 0) > 0 : (all[type] ?? 0) > 0
    }
}

// MARK: - A running plugin

/// One running plugin: its JavaScript engine (`JSBridge`), the entry contexts of calls in flight, event coalescing,
/// storage and the watchdog. Implements `PluginRuntimeHandle`.
@MainActor
final class PluginInstance: PluginRuntimeHandle {
    enum State: Equatable { case starting, running, unresponsive, stopped }

    /// One entry into JavaScript (a command handler, an event delivery, a console evaluation). JavaScript receives
    /// its token as the ctx; `ctx.execute` calls are built from it: same undo group, read-only mode, dry run,
    /// confirmation policy and session as the CommandContext that invoked the handler.
    final class Entry {
        enum Kind {
            case command(String)
            case event(String)
            case evaluate
        }

        let token = UUID().uuidString
        let kind: Kind
        let group: String
        let depth: Int
        let readOnly: Bool
        let dryRun: Bool
        let inheritedPolicy: ConfirmationPolicy?
        let session: EditorSession?
        let commandContext: CommandContext?
        let limit: TimeInterval
        var deadline: Date
        var continuation: CheckedContinuation<JSONValue, Error>?
        var timer: Task<Void, Never>?

        init(kind: Kind, group: String, depth: Int = 0, readOnly: Bool = false, dryRun: Bool = false,
             inheritedPolicy: ConfirmationPolicy? = nil, session: EditorSession? = nil,
             commandContext: CommandContext? = nil, limit: TimeInterval) {
            self.kind = kind
            self.group = group
            self.depth = depth
            self.readOnly = readOnly
            self.dryRun = dryRun
            self.inheritedPolicy = inheritedPolicy
            self.session = session
            self.commandContext = commandContext
            self.limit = limit
            // A little grace, so a thread that is blocked for the whole limit is reported by the watchdog
            // ("stopped responding") before this call's own timeout.
            self.deadline = Date().addingTimeInterval(limit + max(0.25, limit * 0.05))
        }

        var label: String {
            switch kind {
            case .command(let id): return "the handler of '\(id)'"
            case .event(let type): return "the '\(type)' event callback"
            case .evaluate: return "the console evaluation"
            }
        }
    }

    /// What calls made outside a ctx inherit from the entries in flight: the strictest mode of any of them, so a
    /// handler running read-only (ask mode, a `read` command) or as a dry run cannot write through
    /// `nib.commands.execute` either, and recursion through it still counts towards the nesting limit.
    struct Ambient {
        var readOnly = false
        var dryRun = false
        var depth = 0
        var policy: ConfirmationPolicy?
    }

    private struct CoalesceKey: Hashable {
        let type: String
        let doc: String?
        let own: Bool
    }

    let manifest: PluginManifest
    let folder: URL
    let principal: Principal
    private(set) var state: State = .starting
    private weak var runtime: PluginRuntime?
    private weak var app: NibApp?
    private let limits: PluginLimits
    let bridge: JSBridge
    private let logRing: LogRing
    private let subscriptions = SubscriptionTable()
    private let storage: PluginStorage?
    private var entries: [String: Entry] = [:]
    private var bootContinuation: CheckedContinuation<Void, Error>?
    private var eventSubscription: EventSubscription?
    private var recentSeqs: [UInt64] = []
    private var recentSeqSet = Set<UInt64>()
    private var windowEnds: [CoalesceKey: Date] = [:]
    private var pendingEvents: [CoalesceKey: PendingDelivery] = [:]
    private var flushTask: Task<Void, Never>?
    private var dialogs = 0
    /// Undo groups this plugin was handed: the groups of its entries (a handler's `ctx.group`) and the groups its own
    /// calls returned (`nib.ai.complete`, `nib.commands.execute`). `nib.commands.execute {group}` joins these as they
    /// are; any other group is namespaced to the plugin (`pluginGroup`), so a plugin can never write into another
    /// principal's undo step, nor into a group the user allowed "for the rest of the group" there.
    private var knownGroups: [String] = []
    private var knownGroupSet = Set<String>()
    static let knownGroupCapacity = 256

    init(runtime: PluginRuntime, app: NibApp, manifest: PluginManifest, folder: URL, limits: PluginLimits,
         storage: PluginStorage?) {
        self.runtime = runtime
        self.app = app
        self.manifest = manifest
        self.folder = folder
        self.limits = limits
        self.principal = .plugin(manifest.id)
        self.logRing = LogRing(capacity: limits.logCapacity, maxLineBytes: limits.logLineBytes)
        self.bridge = JSBridge(pluginID: manifest.id, maxTimers: limits.maxTimers, defaultLimit: limits.callTimeout)
        self.storage = storage
    }

    // MARK: PluginRuntimeHandle

    var logs: [String] { logRing.lines }

    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue {
        try acceptCalls()
        let limit = timeout(for: command)
        let entry = Entry(kind: .command(command), group: context.group, depth: context.depth, readOnly: context.readOnly,
                          dryRun: context.dryRun, inheritedPolicy: context.inheritedPolicy, session: context.session,
                          commandContext: context, limit: limit)
        let paramsJSON = (params == .null ? [:] : params).jsonString()
        let ctxJSON = payload(for: entry)
        return try await run(entry) { bridge in
            bridge.callDispatch("invoke", [entry.token, command, paramsJSON, ctxJSON], limit: limit)
        }
    }

    func deliver(_ event: NibEvent) {
        guard state == .running else { return }
        if event.seq != 0 {
            // The host may forward the same bus events this instance already receives: deliver each once.
            guard recentSeqSet.insert(event.seq).inserted else { return }
            recentSeqs.append(event.seq)
            if recentSeqs.count > 512 { recentSeqSet.remove(recentSeqs.removeFirst()) }
        }
        // Panels reach main.js through `postMessage`; `plugin.message` events on the bus are main.js → panel posts.
        if event.type == NibEventType.pluginMessage { return }
        let own = event.principal == principal
        guard subscriptions.wants(event.type, own: own) else { return }
        enqueue(event, key: CoalesceKey(type: event.type, doc: event.doc?.raw, own: own))
    }

    func postMessage(from panel: String, message: JSONValue) {
        guard state == .running, subscriptions.wants(NibEventType.pluginMessage, own: false) else { return }
        let event: JSONValue = ["seq": 0, "type": .string(NibEventType.pluginMessage), "at": .number(Date().timeIntervalSince1970),
                                "panel": .string(panel), "payload": message]
        dispatchEvent(event, type: NibEventType.pluginMessage)
    }

    func evaluate(_ javascript: String) async -> String {
        do {
            try acceptCalls()
            let entry = Entry(kind: .evaluate, group: NibID.make().raw, limit: limits.callTimeout)
            let value = try await run(entry) { bridge in
                bridge.callDispatch("evaluate", [entry.token, javascript], limit: entry.limit)
            }
            return value.stringValue ?? value.jsonString()
        } catch {
            let e = NibError.wrap(error)
            return "Error [\(e.code.rawValue)]: \(e.message)"
        }
    }

    func stop() {
        guard state != .stopped else { return }
        let wasUnresponsive = state == .unresponsive
        state = .stopped
        if !wasUnresponsive {
            shutDown(NibError(.unavailable, "plugin \(manifest.id) was stopped", hint: "enable or reload the plugin"))
        }
        storage?.flush()
        runtime?.didStop(self)
    }

    // MARK: Start

    func boot(prelude: String, entry: URL) async throws {
        let info: JSONValue = ["id": .string(manifest.id), "version": .string(manifest.version), "settings": settingsSnapshot()]
        wireBridge()
        subscribeToEvents()
        let maxBytes = limits.bundleBytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bootContinuation = continuation
            // The entry is read and evaluated on the plugin's queue; the result comes back to the main actor.
            bridge.bootAsync(prelude: prelude, info: info.jsonString(), source: { try PluginRuntime.readEntry(entry, maxBytes: maxBytes) },
                             sourceURL: URL(string: "nib-plugin://\(manifest.id)/\(manifest.entry)"), limit: limits.startTimeout) { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishBoot(result) }
                }
            }
        }
        state = .running
        logRing.append("nib", "started \(manifest.id) \(manifest.version)")
    }

    private func finishBoot(_ result: Result<Void, Error>) {
        guard let continuation = bootContinuation else { return }
        bootContinuation = nil
        if case .failure(let error) = result {
            logRing.append("error", "start failed: \(NibError.wrap(error).message)")
        }
        continuation.resume(with: result)
    }

    private func wireBridge() {
        let bridge = self.bridge
        let logRing = self.logRing
        let subscriptions = self.subscriptions
        let storage = self.storage
        let id = manifest.id
        bridge.onLog = { level, text in
            logRing.append(level, text)
            if level == "error" { runtimeLog.error("plugin \(id, privacy: .public): \(text, privacy: .private)") }
        }
        bridge.onSubscribe = { type, includeOwn, delta in
            subscriptions.update(type, includeOwn: includeOwn, delta: delta)
        }
        bridge.onCall = { [weak self] method, args, callID, reply in
            if method.hasPrefix("storage.") {
                // Storage never needs the main actor: it runs on its own queue, in call order.
                PluginInstance.storageCall(storage, bridge: bridge, method: method, argsJSON: args, reply: reply)
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else {
                        bridge.reply(reply, ok: false, json: JSBridge.errorJSON(NibError.unavailable("the plugin")))
                        return
                    }
                    self.handleCall(method: method, argsJSON: args, callID: callID, reply: reply)
                }
            }
        }
        bridge.onDone = { [weak self] token, ok, json in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishEntry(token, ok: ok, json: json) }
            }
        }
        bridge.onHang = { [weak self] seconds in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.markUnresponsive(seconds: seconds) }
            }
        }
    }

    private func subscribeToEvents() {
        guard let app = app else { return }
        eventSubscription = app.events.subscribe { [weak self] event in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.deliver(event) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.deliver(event) }
                }
            }
        }
    }

    // MARK: Entries, deadlines and the watchdog

    private func acceptCalls() throws {
        switch state {
        case .starting, .running: return
        case .unresponsive: throw unresponsiveError(limits.callTimeout)
        case .stopped:
            throw NibError(.unavailable, "plugin \(manifest.id) is not running", hint: "enable or reload the plugin")
        }
    }

    private func timeout(for command: String) -> TimeInterval {
        let longRunning = manifest.contributes?.commands?.first { $0.id == command }?.longRunning ?? false
        return longRunning ? limits.longRunningTimeout : limits.callTimeout
    }

    private func run(_ entry: Entry, start: (JSBridge) -> Void) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            entry.continuation = continuation
            begin(entry)
            start(bridge)
        }
    }

    private func begin(_ entry: Entry) {
        entries[entry.token] = entry
        remember(group: entry.group)
        updateBusyLimit()
        entry.timer = Task { @MainActor [weak self, weak entry] in
            while !Task.isCancelled {
                guard let entry = entry else { return }
                let wait = entry.deadline.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000) }
                if Task.isCancelled { return }
                guard let self = self else { return }
                if self.dialogs > 0 {
                    // Time the user spends answering a dialog does not count (the deadline moves when it closes).
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if entry.deadline.timeIntervalSinceNow <= 0 {
                    self.timeOut(entry)
                    return
                }
            }
        }
    }

    private func finishEntry(_ token: String, ok: Bool, json: String) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        entry.timer?.cancel()
        updateBusyLimit()
        if ok {
            entry.continuation?.resume(returning: (try? JSONValue.parse(json)) ?? .null)
        } else {
            let (error, stack) = PluginInstance.error(fromJSON: json)
            if error.code == .internalError || entry.continuation == nil {
                logRing.append("error", "\(entry.label) failed: \(error.message)" + (stack.map { "\n" + $0 } ?? ""))
            }
            entry.continuation?.resume(throwing: error)
        }
        entry.continuation = nil
    }

    private func timeOut(_ entry: Entry) {
        guard entries[entry.token] != nil else { return }
        let blocked = bridge.busySeconds
        if blocked >= entry.limit * 0.9 {
            // Not slow but stuck: the JavaScript thread has not yielded for the whole limit.
            markUnresponsive(seconds: blocked)
            return
        }
        entries[entry.token] = nil
        updateBusyLimit()
        var hint = "make the handler finish sooner, or split the work"
        if case .command = entry.kind, entry.limit < limits.longRunningTimeout {
            hint = "declare the command with \"longRunning\": true to allow \(Int(limits.longRunningTimeout)) s"
        }
        let error = NibError(.timeout, "\(entry.label) of plugin \(manifest.id) did not finish within \(PluginInstance.seconds(entry.limit))",
                             hint: hint)
        logRing.append("nib", error.message)
        entry.continuation?.resume(throwing: error)
        entry.continuation = nil
    }

    /// The plugin's JavaScript thread ran past its limit: every call in flight and every later call is rejected
    /// with `timeout` until the plugin is reloaded.
    func markUnresponsive(seconds: TimeInterval) {
        guard state == .starting || state == .running else { return }
        state = .unresponsive
        let error = unresponsiveError(seconds)
        logRing.append("nib", error.message)
        runtimeLog.fault("plugin \(self.manifest.id, privacy: .public) stopped responding")
        shutDown(error)
    }

    private func unresponsiveError(_ seconds: TimeInterval) -> NibError {
        NibError(.timeout, "plugin \(manifest.id) stopped responding: its JavaScript ran for \(PluginInstance.seconds(seconds)) without yielding",
                 hint: "fix the plugin, then reload it (plugin.reload); plugin.logs shows its console")
    }

    /// Fails everything in flight with `error`, cancels timers and subscriptions and releases the engine.
    private func shutDown(_ error: NibError) {
        let pending = Array(entries.values)
        entries.removeAll()
        for entry in pending {
            entry.timer?.cancel()
            entry.continuation?.resume(throwing: error)
            entry.continuation = nil
        }
        if let boot = bootContinuation {
            bootContinuation = nil
            boot.resume(throwing: error)
        }
        eventSubscription?.cancel()
        eventSubscription = nil
        flushTask?.cancel()
        flushTask = nil
        pendingEvents.removeAll()
        bridge.shutdown()
    }

    private func updateBusyLimit() {
        bridge.defaultLimit = max(limits.callTimeout, entries.values.map(\.limit).max() ?? 0)
    }

    private func ambient() -> Ambient {
        var a = Ambient()
        guard !entries.isEmpty else { return a }
        for e in entries.values {
            a.readOnly = a.readOnly || e.readOnly
            a.dryRun = a.dryRun || e.dryRun
            a.depth = max(a.depth, e.depth + 1)
            a.policy = ConfirmationPolicy.stricter(a.policy, e.inheritedPolicy)
        }
        return a
    }

    private func payload(for entry: Entry) -> String {
        let ctx: JSONValue = ["token": .string(entry.token), "group": .string(entry.group), "readOnly": .bool(entry.readOnly),
                              "settings": settingsSnapshot()]
        return ctx.jsonString()
    }

    /// Current values of `contributes.settings` ("plugin.<id>.<key>", else the schema default): `nib.plugin.settings`.
    private func settingsSnapshot() -> JSONValue {
        guard let app = app, let properties = manifest.contributes?.settings?["properties"]?.objectValue else { return [:] }
        var out: [String: JSONValue] = [:]
        for (key, schema) in properties {
            out[key] = app.settings.json("plugin.\(manifest.id).\(key)") ?? schema["default"] ?? .null
        }
        return .object(out)
    }

    // MARK: Events

    /// Events of one type (and document) that arrived inside a coalescing window: the latest event and the union of
    /// their changes. A class, so adding to it never copies what it already collected.
    private final class PendingDelivery {
        var event: NibEvent
        var changes: CoalescedChanges

        init(_ event: NibEvent, limit: Int) {
            self.event = event
            self.changes = CoalescedChanges(limit: limit)
        }
    }

    private func enqueue(_ event: NibEvent, key: CoalesceKey) {
        let now = Date()
        if let end = windowEnds[key], end > now {
            let pending: PendingDelivery
            if let existing = pendingEvents[key] {
                pending = existing
                pending.event = event
            } else {
                pending = PendingDelivery(event, limit: limits.coalescedRefs)
                pendingEvents[key] = pending
            }
            pending.changes.add(event.changes)
            scheduleFlush()
            return
        }
        windowEnds[key] = now.addingTimeInterval(limits.coalesceInterval)
        var changes = CoalescedChanges(limit: limits.coalescedRefs)
        changes.add(event.changes)
        dispatch(event, changes: changes)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let earliest = pendingEvents.keys.compactMap { windowEnds[$0] }.min() ?? Date()
        let wait = max(0, earliest.timeIntervalSinceNow)
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        guard state == .running else { return }
        let now = Date()
        for (key, pending) in pendingEvents where (windowEnds[key] ?? now) <= now {
            pendingEvents[key] = nil
            windowEnds[key] = now.addingTimeInterval(limits.coalesceInterval)
            dispatch(pending.event, changes: pending.changes)
        }
        windowEnds = windowEnds.filter { $0.value > now || pendingEvents[$0.key] != nil }
        if !pendingEvents.isEmpty { scheduleFlush() }
    }

    /// The event as JavaScript sees it, with the (coalesced, capped) changes in place of the event's own.
    private func dispatch(_ event: NibEvent, changes: CoalescedChanges) {
        var fields: [String: JSONValue] = ["seq": .number(Double(event.seq)), "type": .string(event.type), "at": .number(event.at)]
        if let p = event.principal, let v = try? JSONValue.from(p) { fields["principal"] = v }
        if let d = event.doc, let v = try? JSONValue.from(d) { fields["doc"] = v }
        if let c = changes.json { fields["changes"] = c }
        if let payload = event.payload { fields["payload"] = payload }
        dispatchEvent(.object(fields), type: event.type)
    }

    /// One delivery: a fresh ctx (its own undo group), a done callback, the call timeout.
    private func dispatchEvent(_ json: JSONValue, type: String) {
        let entry = Entry(kind: .event(type), group: NibID.make().raw, limit: limits.callTimeout)
        begin(entry)
        bridge.callDispatch("event", [entry.token, json.jsonString(), payload(for: entry)], limit: entry.limit)
    }

    // MARK: Native calls (main actor)

    private func handleCall(method: String, argsJSON: String, callID: String, reply: Int) {
        guard state == .starting || state == .running else {
            bridge.reply(reply, ok: false, json: JSBridge.errorJSON(NibError(.unavailable, "plugin \(manifest.id) is not running")))
            return
        }
        let args: JSONValue
        do {
            args = try JSONValue.parse(argsJSON)
        } catch {
            bridge.reply(reply, ok: false, json: JSBridge.errorJSON(NibError.invalid("the call's arguments are not JSON")))
            return
        }
        // A ctx call belongs to the entry it was made in; look it up now, in call order, so a call issued before
        // the handler returned still runs in its context even when the handler's result arrives first.
        let entry = callID.isEmpty ? nil : entries[callID]
        Task { @MainActor in
            do {
                let value = try await self.perform(method, args: args, callID: callID, entry: entry)
                self.bridge.reply(reply, ok: true, json: value.jsonString())
            } catch {
                self.bridge.reply(reply, ok: false, json: JSBridge.errorJSON(NibError.wrap(error)))
            }
        }
    }

    func perform(_ method: String, args: JSONValue, callID: String, entry: Entry?) async throws -> JSONValue {
        switch method {
        case "execute": return try await execute(args, token: callID, entry: entry)
        case "ui.toast": return toast(args)
        case "ui.confirm", "ui.prompt", "ui.choose": return try await dialog(method, args)
        case "ui.openPanel": return try await openPanel(args)
        case "ui.postToPanel": return try postToPanel(args)
        case "settings.get": return try await settingsGet(args)
        case "settings.set": return try await settingsSet(args)
        case "ai.complete": return try await aiComplete(args)
        case "net.fetch": return try await fetch(args)
        default:
            throw NibError(.notFound, "unknown plugin API '\(method)'")
        }
    }

    // MARK: Commands

    /// `ctx.execute` (a token) or `nib.commands.execute` (no token): always `.plugin(id)`, through the bus.
    private func execute(_ args: JSONValue, token: String, entry: Entry?) async throws -> JSONValue {
        guard let app = app else { throw NibError.unavailable("the app") }
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            throw NibError.invalid("missing command id", path: "$.command")
        }
        let params = args["params"] ?? [:]
        let dryRun = args["dryRun"]?.boolValue ?? false
        if !token.isEmpty {
            guard let entry = entry else {
                throw NibError(.invalidParams, "ctx.execute('\(command)') ran after its handler had finished",
                               hint: "await every ctx.execute call before the handler returns")
            }
            if let ctx = entry.commandContext, ctx.principal == principal, !dryRun || ctx.dryRun {
                // Invoked as this plugin already: the context's own execute also reports the changes.
                return try await ctx.execute(command, params)
            }
            let inv = Invocation(command: command, params: params, principal: principal, session: entry.session,
                                 group: entry.group, dryRun: entry.dryRun || dryRun, depth: entry.depth + 1,
                                 readOnly: entry.readOnly, inheritedPolicy: entry.inheritedPolicy)
            return try await app.bus.execute(inv).value
        }
        var group: String?
        if let g = args["group"]?.stringValue, !g.isEmpty {
            guard g.count <= 64, g.range(of: "^[A-Za-z0-9_:.-]+$", options: .regularExpression) != nil else {
                throw NibError.invalid("an undo group is 1 to 64 of [A-Za-z0-9_:.-]", path: "$.group")
            }
            group = pluginGroup(g)
        }
        return try await executeAmbient(command, params, dryRun: dryRun, group: group)
    }

    private func executeAmbient(_ command: String, _ params: JSONValue, dryRun: Bool = false, group: String? = nil) async throws -> JSONValue {
        guard let app = app else { throw NibError.unavailable("the app") }
        let a = ambient()
        let inv = Invocation(command: command, params: params, principal: principal, group: group,
                             dryRun: dryRun || a.dryRun, depth: a.depth, readOnly: a.readOnly, inheritedPolicy: a.policy)
        let result = try await app.bus.execute(inv)
        remember(group: result.group)
        return result.value
    }

    /// The undo group a `nib.commands.execute {group}` call runs in: `requested` itself when this plugin was handed
    /// it, else "plugin.<id>:<requested>" (the same requested name is still one undo step).
    func pluginGroup(_ requested: String) -> String {
        knownGroupSet.contains(requested) ? requested : "plugin.\(manifest.id):\(requested)"
    }

    private func remember(group: String) {
        guard !group.isEmpty, knownGroupSet.insert(group).inserted else { return }
        knownGroups.append(group)
        if knownGroups.count > PluginInstance.knownGroupCapacity { knownGroupSet.remove(knownGroups.removeFirst()) }
    }

    // MARK: Settings

    private func settingsGet(_ args: JSONValue) async throws -> JSONValue {
        guard let app = app else { throw NibError.unavailable("the app") }
        guard let name = args["name"]?.stringValue, !name.isEmpty else { throw NibError.invalid("missing setting name", path: "$.name") }
        let own = "plugin.\(manifest.id)."
        if name.hasPrefix(own) {
            // A plugin always reads its own settings (no "app" permission needed).
            let key = String(name.dropFirst(own.count))
            let fallback = manifest.contributes?.settings?["properties"]?[key]?["default"]
            return app.settings.json(name) ?? fallback ?? .null
        }
        let r = try await executeAmbient(CommandIDs.settingsGet, ["name": .string(name)])
        return r["value"] ?? .null
    }

    private func settingsSet(_ args: JSONValue) async throws -> JSONValue {
        guard let name = args["name"]?.stringValue, !name.isEmpty else { throw NibError.invalid("missing setting name", path: "$.name") }
        _ = try await executeAmbient(CommandIDs.settingsSet, ["name": .string(name), "value": args["value"] ?? .null])
        return .null
    }

    // MARK: UI

    private func toast(_ args: JSONValue) -> JSONValue {
        let message = args["message"]?.stringValue ?? ""
        let shown = runtime?.ui.toast(message, from: manifest) ?? false
        logRing.append("toast", shown ? message : message + " (no window to show it in)")
        return .null
    }

    private func dialog(_ method: String, _ args: JSONValue) async throws -> JSONValue {
        guard let ui = runtime?.ui else { throw NibError.unavailable("dialogs") }
        let title = args["title"]?.stringValue ?? manifest.name
        let timeout = limits.dialogTimeout
        dialogs += 1
        let opened = Date()
        defer {
            dialogs -= 1
            // The time spent in the dialog does not count towards any call's timeout.
            let waited = Date().timeIntervalSince(opened)
            for e in entries.values { e.deadline = e.deadline.addingTimeInterval(waited) }
        }
        switch method {
        case "ui.confirm":
            return .bool(try await ui.confirm(title, message: args["message"]?.stringValue, from: manifest, timeout: timeout))
        case "ui.prompt":
            let text = try await ui.prompt(title, placeholder: args["placeholder"]?.stringValue, initial: args["initial"]?.stringValue,
                                           from: manifest, timeout: timeout)
            return text.map { JSONValue.string($0) } ?? .null
        default:
            let options = (args["options"]?.arrayValue ?? []).compactMap { $0.stringValue }
            guard !options.isEmpty else { throw NibError.invalid("nib.ui.choose needs at least one option", path: "$.options") }
            let index = try await ui.choose(title, options: options, from: manifest, timeout: timeout)
            return index.map { JSONValue.number(Double($0)) } ?? .null
        }
    }

    private func ownPanel(_ args: JSONValue) throws -> String {
        guard let id = args["id"]?.stringValue, !id.isEmpty else { throw NibError.invalid("missing panel id", path: "$.id") }
        guard manifest.contributes?.panels?.contains(where: { $0.id == id }) == true else {
            throw NibError(.notFound, "'\(id)' is not one of this plugin's panels", path: "$.id",
                           hint: "declare it in manifest contributes.panels")
        }
        return id
    }

    /// Opens one of the plugin's own panels in the active window. Showing its own UI needs no permission, so this
    /// runs `panel.open` for exactly that id as the window's user action (never any other panel). It keeps the
    /// modes of the calls in flight: read-only (ask mode, a `read` command) refuses it, and a dry run opens nothing.
    private func openPanel(_ args: JSONValue) async throws -> JSONValue {
        guard let app = app else { throw NibError.unavailable("the app") }
        let id = try ownPanel(args)
        let a = ambient()
        let inv = Invocation(command: CommandIDs.panelOpen, params: ["id": .string(id)], principal: .user,
                             session: app.services.sessions.active, dryRun: a.dryRun, readOnly: a.readOnly)
        if a.dryRun && !a.readOnly { return .null }
        do {
            _ = try await app.bus.execute(inv)
        } catch let e as NibError where e.code == .notFound {
            throw NibError(.unavailable, "panels cannot be opened here: \(e.message)")
        }
        return .null
    }

    /// `nib.ui.postToPanel`: a `plugin.message` event from this plugin, addressed to one of its panels
    /// (payload {panel, to: "panel", message}); the panel host delivers it to `window.nib.onMessage`.
    private func postToPanel(_ args: JSONValue) throws -> JSONValue {
        guard let app = app else { throw NibError.unavailable("the app") }
        let id = try ownPanel(args)
        app.events.emit(NibEventType.pluginMessage, principal: principal,
                        payload: ["panel": .string(id), "to": "panel", "message": args["message"] ?? .null])
        return .null
    }

    // MARK: AI and network

    /// Scopes the runtime checks itself (no command behind them): declared in the manifest AND granted.
    private func requireScope(_ scope: Scope) throws {
        guard let app = app else { throw NibError.unavailable("the app") }
        guard manifest.permissions.contains(scope.rawValue), app.gateway.grants(principal).contains(scope) else {
            throw NibError(.permissionDenied, "missing permission: \(scope.rawValue)",
                           hint: "declare \"\(scope.rawValue)\" in the manifest's permissions; the user must grant it")
        }
    }

    /// `nib.ai.complete`: the user's AI; tool calls run as this plugin, with its permissions.
    private func aiComplete(_ args: JSONValue) async throws -> JSONValue {
        try requireScope(.ai)
        guard let ai = app?.services.ai, ai.isConfigured else {
            throw NibError(.unavailable, "no AI provider is set up", hint: "the user can add one in Settings › AI")
        }
        guard let raw = args["messages"]?.arrayValue, !raw.isEmpty else {
            throw NibError.invalid("nib.ai.complete needs at least one message", path: "$.messages")
        }
        var messages: [AIMessage] = []
        for (i, m) in raw.enumerated() {
            let role = m["role"]?.stringValue ?? "user"
            guard role == "user" || role == "assistant" else {
                throw NibError.invalid("role is 'user' or 'assistant'", path: "$.messages[\(i)].role")
            }
            guard let text = m["text"]?.stringValue else { throw NibError.invalid("missing text", path: "$.messages[\(i)].text") }
            let images = (m["images"]?.arrayValue ?? []).compactMap { $0.stringValue }
                .map { AssetRef($0.hasPrefix("tmp:") ? String($0.dropFirst(4)) : $0) }
            messages.append(AIMessage(role: role, text: text, images: images.isEmpty ? nil : images))
        }
        let a = ambient()
        var mode: AIMode = args["mode"]?.stringValue == AIMode.edit.rawValue ? .edit : .ask
        if a.readOnly || a.dryRun { mode = .ask }
        let tools: [String]? = args["tools"]?.arrayValue.map { $0.compactMap { $0.stringValue } }
        let steps = min(max(args["maxSteps"]?.intValue ?? 40, 1), 40)
        let request = AIRequest(system: args["system"]?.stringValue, messages: messages, tools: tools, mode: mode,
                                principal: principal, maxSteps: steps, jsonOutput: args["json"]?.boolValue ?? false)
        let response = try await ai.complete(request)
        var out: [String: JSONValue] = ["text": .string(response.text), "changes": try JSONValue.from(response.changes)]
        if let g = response.group {
            remember(group: g)
            out["group"] = .string(g)
        }
        return .object(out)
    }

    /// `nib.net.fetch`: needs "network" and a host from `network.hosts`.
    private func fetch(_ args: JSONValue) async throws -> JSONValue {
        try requireScope(.network)
        guard let s = args["url"]?.stringValue, let url = URL(string: s) else {
            throw NibError.invalid("nib.net.fetch needs an https URL", path: "$.url")
        }
        let hosts = Set(manifest.network?.hosts ?? [])
        try PluginFetcher.check(url, hosts: hosts)
        let options = args["init"] ?? [:]
        let method = (options["method"]?.stringValue ?? "GET").uppercased()
        guard PluginFetcher.methods.contains(method) else {
            throw NibError.invalid("unsupported method \(method)", path: "$.init.method")
        }
        var headers: [String: String] = [:]
        for (k, v) in options["headers"]?.objectValue ?? [:] { headers[k] = v.stringValue ?? v.jsonString() }
        var body: Data?
        if let b64 = options["bodyBase64"]?.stringValue {
            guard let data = Data(base64Encoded: b64) else { throw NibError.invalid("bodyBase64 is not base64", path: "$.init.bodyBase64") }
            body = data
        } else if let text = options["body"]?.stringValue {
            body = Data(text.utf8)
        }
        let fetcher = PluginFetcher(hosts: hosts, maxBytes: limits.fetchBytes, timeout: limits.fetchTimeout)
        return try await fetcher.fetch(url, method: method, headers: headers, body: body)
    }

    // MARK: Storage (storage queue)

    private nonisolated static func storageCall(_ storage: PluginStorage?, bridge: JSBridge, method: String, argsJSON: String, reply: Int) {
        guard let storage = storage else {
            bridge.reply(reply, ok: false, json: JSBridge.errorJSON(NibError(.unavailable, "plugin storage needs a library folder")))
            return
        }
        storage.async({ storage -> JSONValue in
            let args = try JSONValue.parse(argsJSON)
            let key = args["key"]?.stringValue ?? ""
            switch method {
            case "storage.get":
                let value = try storage.get(key)
                return ["found": .bool(value != nil), "value": value ?? .null]
            case "storage.set":
                if let value = args["value"] { try storage.set(key, value) } else { try storage.remove(key) }
                return .null
            case "storage.remove":
                try storage.remove(key)
                return .null
            case "storage.keys":
                return .array(try storage.keys().map { .string($0) })
            default:
                throw NibError(.notFound, "unknown plugin API '\(method)'")
            }
        }, done: { result in
            switch result {
            case .success(let value): bridge.reply(reply, ok: true, json: value.jsonString())
            case .failure(let error): bridge.reply(reply, ok: false, json: JSBridge.errorJSON(NibError.wrap(error)))
            }
        })
    }

    // MARK: Helpers

    nonisolated static func error(fromJSON json: String) -> (NibError, String?) {
        guard let v = try? JSONValue.parse(json) else { return (NibError(.internalError, json), nil) }
        let code = v["code"]?.stringValue.flatMap { NibError.Code(rawValue: $0) } ?? .internalError
        let error = NibError(code, v["message"]?.stringValue ?? "the plugin failed", path: v["path"]?.stringValue,
                             hint: v["hint"]?.stringValue)
        return (error, v["stack"]?.stringValue)
    }

    nonisolated static func seconds(_ t: TimeInterval) -> String {
        t >= 10 ? "\(Int(t.rounded())) s" : String(format: "%.1f s", t)
    }
}

// MARK: - Coalesced changes

/// The union of the `changes` of the events one delivery stands for, without duplicates, in arrival order. Adding
/// costs O(new refs); at most `limit` refs are kept, past that `truncated` is set (the plugin re-queries).
struct CoalescedChanges {
    let limit: Int
    private(set) var created: [String] = []
    private(set) var updated: [String] = []
    private(set) var removed: [String] = []
    private(set) var truncated = false
    /// True once any event carried changes.
    private(set) var hasChanges = false
    private var seen = Set<String>()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var count: Int { seen.count }

    mutating func add(_ changes: ChangeSummary?) {
        guard let c = changes else { return }
        hasChanges = true
        for r in c.created where admit(r) { created.append(r) }
        for r in c.updated where admit(r) { updated.append(r) }
        for r in c.removed where admit(r) { removed.append(r) }
    }

    private mutating func admit(_ ref: String) -> Bool {
        if seen.contains(ref) { return false }
        guard seen.count < limit else {
            truncated = true
            return false
        }
        seen.insert(ref)
        return true
    }

    /// `{created, updated, removed, truncated?}` for JavaScript; nil when no event carried changes.
    var json: JSONValue? {
        guard hasChanges else { return nil }
        var out: [String: JSONValue] = ["created": .array(created.map { .string($0) }),
                                        "updated": .array(updated.map { .string($0) }),
                                        "removed": .array(removed.map { .string($0) })]
        if truncated { out["truncated"] = true }
        return .object(out)
    }
}
