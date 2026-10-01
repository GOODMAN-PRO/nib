import Foundation
import SwiftUI
import UIKit
import NibContracts
import os

/// WebDAV sync (F069): a three-way mirror of the library folder with a folder on a WebDAV server (Nextcloud,
/// ownCloud, a NAS, Apache/nginx), the "server of your own" substitute for Goodnotes Cloud, and the WebDAV target
/// of auto backup (`webdav.put`). Runs when the app comes to the foreground, every 60 s while it is active, and as
/// the `app.nib.webdav` background refresh task.
public enum FeatWebDAVFeature: NibFeature {
    public static let id = "webdav"
    static let backgroundTaskID = "app.nib.webdav"
    static let settingsPageID = "webdav.settings"

    public static func register(_ app: NibApp) {
        WebDAVSettings.declare(app.settings, owner: id)
        app.commands.register(WebDAVSyncNowCommand.self)
        app.commands.register(WebDAVConfigureCommand.self)
        app.commands.register(WebDAVPutCommand.self)
        app.commands.register(WebDAVStatusCommand.self)

        let engine = WebDAVSyncEngine(app: app)
        app.services.set(engine, for: WebDAVSyncEngine.serviceKey)

        var page = SettingsPageDescriptor(id: settingsPageID, title: String(localized: "WebDAV"), icon: "server.rack",
                                          section: .sync, order: 30, owner: id) { app in
            AnyView(WebDAVSettingsPage(app: app))
        }
        page.keywords = ["WebDAV", "Nextcloud", "ownCloud", "NAS", "server", "sync", "backup", "certificate"]
        app.ui.settingsPages.register(page)

        app.content.backgroundTasks.register(BackgroundTaskDescriptor(id: backgroundTaskID, kind: .refresh, owner: id) {
            [weak engine] _ in
            await engine?.runBackgroundTask() ?? true
        })
    }

    public static func start(_ app: NibApp) async {
        app.services.get(WebDAVSyncEngine.serviceKey, as: WebDAVSyncEngine.self)?.start()
    }
}

/// Owns scheduling and the state the commands report: one mirror pass at a time (a manual request made while one
/// runs is queued behind it), a 60 s timer while the app is active, a pass when the app returns to the foreground,
/// a short finishing pass when it leaves it, and the background refresh task.
@MainActor
final class WebDAVSyncEngine {
    static let serviceKey = "webdav.engine"
    static let log = Logger(subsystem: "app.nib", category: "webdav")

    enum Trigger: String {
        case manual, foreground, timer, leavingForeground, backgroundTask, configured
    }

    private weak var app: NibApp?
    let settings: SettingsStore
    let events: EventBus
    /// Where the last-synced state lives (Application Support/Nib/webdav; tests use a temporary folder).
    var stateDirectory = MirrorStateStore.defaultDirectory
    /// Session configuration for each new client (tests install a URLProtocol).
    var makeSessionConfiguration: () -> URLSessionConfiguration = { .ephemeral }
    /// Automatic pass interval while the app is active.
    var interval: TimeInterval = 60
    /// Earliest next background refresh.
    var backgroundInterval: TimeInterval = 15 * 60

    private(set) var isActive = false
    private(set) var lastReport: WebDAVSyncReport?
    private(set) var lastSync: Double?
    /// The failure of the last pass that stopped early (typed, for command errors).
    private(set) var lastFailure: WebDAVError?
    /// The server rejected the password: automatic passes stop (each would be more failed logins, and Nextcloud's
    /// brute-force protection then throttles the user's whole IP) until `webdav.configure` runs (the settings page
    /// saving a new password runs it too) or the user syncs by hand.
    private(set) var authSuspended = false
    private var lastRunEnded: Date?
    private var lastRunStarted: Date?
    private var lastRunDuration: TimeInterval?
    private var running: Task<WebDAVSyncReport, Never>?
    private var queued: Task<WebDAVSyncReport, Never>?
    private var currentRun: WebDAVMirrorRun?
    private var summaryKey: String?
    private var lastEmitted: SyncStatusPayload?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var finishingTask: UIBackgroundTaskIdentifier = .invalid

    init(app: NibApp) {
        self.app = app
        settings = app.settings
        events = app.events
    }

    static func resolve(_ services: NibServices) throws -> WebDAVSyncEngine {
        guard let engine = services.get(serviceKey, as: WebDAVSyncEngine.self) else {
            throw NibError.unavailable("WebDAV sync")
        }
        return engine
    }

    // MARK: Configuration

    var isConfigured: Bool { !settings.get(WebDAVSettings.url).isEmpty }

    var credentialsMissing: Bool {
        let v = WebDAVSettings.read(settings)
        return !v.url.isEmpty && !v.user.isEmpty && WebDAVCredentials.password(url: v.url, user: v.user) == nil
    }

    /// The saved configuration with its Keychain password; throws `notConfigured` / `credentialsMissing`
    /// (as `NibError`s with hints).
    func configuration() throws -> WebDAVConfiguration {
        do {
            return try loadConfiguration()
        } catch let e as WebDAVError {
            throw e.nibError
        }
    }

    private func loadConfiguration() throws -> WebDAVConfiguration {
        let v = WebDAVSettings.read(settings)
        guard !v.url.isEmpty, let server = try? WebDAVConfiguration.normalizeServerURL(v.url) else {
            throw WebDAVError.notConfigured
        }
        let folder = (try? WebDAVConfiguration.normalizeFolder(v.folder)) ?? WebDAVSettings.folder.defaultValue
        let config = WebDAVConfiguration(serverURL: server, user: v.user,
                                         password: WebDAVCredentials.password(url: v.url, user: v.user),
                                         folder: folder, allowUntrustedCertificates: v.allowUntrustedCertificates)
        if config.credentialsMissing { throw WebDAVError.credentialsMissing }
        return config
    }

    func makeClient(_ config: WebDAVConfiguration) -> WebDAVClient {
        WebDAVClient(configuration: config, sessionConfiguration: makeSessionConfiguration())
    }

    /// `webdav.configure` changed the server, user or folder: the next pass starts from that configuration's own
    /// state, and a pass in flight for the old one is stopped.
    func configurationChanged() {
        currentRun?.cancel()
        lastReport = nil
        lastSync = nil
        lastFailure = nil
        authSuspended = false
        summaryKey = nil
        lastEmitted = nil
        loadSummary()
        guard isConfigured else {
            emit(SyncStatusPayload(state: "idle", source: "webdav", message: String(localized: "WebDAV is off")))
            return
        }
        if credentialsMissing {
            emitCredentialsMissing()
        } else if isActive {
            Task { _ = await self.sync(.configured) }
        }
    }

    // MARK: Lifecycle

    func start() {
        loadSummary()
        if isConfigured && credentialsMissing { emitCredentialsMissing() }
        guard !NibApp.isHostlessTest, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.becameActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resignedActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        })
        if UIApplication.shared.applicationState == .active { becameActive() }
    }

    func becameActive() {
        isActive = true
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trigger(.timer) }
        }
        t.tolerance = min(10, interval / 6)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        trigger(.foreground)
    }

    func resignedActive() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    /// Leaving the foreground: schedule the background refresh and use the few seconds iOS grants to push the last
    /// edits (the pass is stopped cleanly if that time runs out).
    func enteredBackground() {
        guard isConfigured, !credentialsMissing, !authSuspended, let app = app else { return }
        app.scheduleBackgroundTask(FeatWebDAVFeature.backgroundTaskID, earliestIn: backgroundInterval)
        guard !NibApp.isHostlessTest, finishingTask == .invalid else { return }
        finishingTask = UIApplication.shared.beginBackgroundTask(withName: "WebDAV sync") { [weak self] in
            MainActor.assumeIsolated { self?.endFinishingTask(expired: true) }
        }
        Task {
            _ = await self.sync(.leavingForeground)
            self.endFinishingTask(expired: false)
        }
    }

    private func endFinishingTask(expired: Bool) {
        if expired { currentRun?.cancel() }
        guard finishingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finishingTask)
        finishingTask = .invalid
    }

    /// The `app.nib.webdav` refresh task: one pass, stopped cleanly when iOS expires the task.
    func runBackgroundTask() async -> Bool {
        app?.scheduleBackgroundTask(FeatWebDAVFeature.backgroundTaskID, earliestIn: backgroundInterval)
        guard isConfigured, !credentialsMissing, !authSuspended else { return true }
        let report = await withTaskCancellationHandler {
            await self.sync(.backgroundTask)
        } onCancel: {
            Task { @MainActor in self.currentRun?.cancel() }
        }
        return report.failure == nil
    }

    /// An automatic pass: skipped while one runs, when WebDAV is off, when the password is missing (reported once)
    /// or was rejected. Returning to the foreground right after a pass (Control Center, a notification) does not
    /// start another, and passes that take long are spaced at twice their duration. Returns whether one started.
    @discardableResult
    func trigger(_ trigger: Trigger) -> Bool {
        guard isConfigured, running == nil else { return false }
        if trigger == .foreground, let ended = lastRunEnded, Date().timeIntervalSince(ended) < 15 { return false }
        if WebDAVSyncEngine.tooSoon(now: Date(), lastStarted: lastRunStarted, lastDuration: lastRunDuration,
                                    interval: interval) {
            return false
        }
        if credentialsMissing {
            emitCredentialsMissing()
            return false
        }
        if authSuspended { return false }
        Task { _ = await self.sync(trigger) }
        return true
    }

    /// Automatic passes start at most every max(interval, 2 × the last pass's duration), so a large library on a
    /// slow server leaves the radio and the server idle between passes.
    static func tooSoon(now: Date, lastStarted: Date?, lastDuration: TimeInterval?, interval: TimeInterval) -> Bool {
        guard let started = lastStarted, let duration = lastDuration, 2 * duration > interval else { return false }
        return now.timeIntervalSince(started) < 2 * duration
    }

    // MARK: Syncing

    var isRunning: Bool { running != nil }

    /// Runs a pass now; while one runs, waits for it and runs one more (shared by every caller that asks meanwhile).
    /// Never throws: failures are in the report (`failure`, `errors`).
    func sync(_ trigger: Trigger) async -> WebDAVSyncReport {
        if let q = queued { return await q.value }
        if let r = running {
            let q = Task { @MainActor [weak self] () -> WebDAVSyncReport in
                _ = await r.value
                guard let self = self else { return WebDAVSyncReport(started: Date().timeIntervalSince1970) }
                self.queued = nil
                return await self.launch(trigger).value
            }
            queued = q
            return await q.value
        }
        return await launch(trigger).value
    }

    private func launch(_ trigger: Trigger) -> Task<WebDAVSyncReport, Never> {
        let task = Task { @MainActor [weak self] () -> WebDAVSyncReport in
            guard let self = self else { return WebDAVSyncReport(started: Date().timeIntervalSince1970) }
            let started = Date()
            let report = await self.perform(trigger)
            self.running = nil
            self.currentRun = nil
            self.lastRunEnded = Date()
            self.lastRunStarted = started
            self.lastRunDuration = Date().timeIntervalSince(started)
            return report
        }
        running = task
        return task
    }

    private func perform(_ trigger: Trigger) async -> WebDAVSyncReport {
        let config: WebDAVConfiguration
        do {
            config = try loadConfiguration()
        } catch {
            return fail(WebDAVError.from(error, host: ""))
        }
        guard let app = app, let library = app.services.library else {
            return fail(.local(String(localized: "The library is not available")))
        }
        let root = library.rootURL
        let key = MirrorStateStore.key(server: config.serverURL, user: config.user, folder: config.folder, root: root)
        let store = MirrorStateStore(directory: stateDirectory, key: key)
        store.adoptLegacy(MirrorStateStore(directory: stateDirectory,
                                           key: MirrorStateStore.legacyKey(server: config.serverURL, user: config.user,
                                                                           folder: config.folder, root: root)))
        let run = WebDAVMirrorRun(client: makeClient(config), root: root, store: store,
                                  deviceHex: app.deviceHex, lockedPackages: lockedPackages(library),
                                  excludedTopLevel: WebDAVSyncEngine.excludedTopLevel(root: root))
        currentRun = run
        emit(SyncStatusPayload(state: "syncing", source: "webdav",
                               message: String(localized: "Syncing with \(config.serverURL.host ?? "the server")")))
        let report = await run.run()
        summaryKey = key
        lastReport = report
        if report.failure == nil {
            lastSync = report.finished
            lastFailure = nil
            authSuspended = false
        } else {
            lastFailure = run.failure ?? .local(report.errors.last ?? "")
            if run.failure == .authenticationFailed { authSuspended = true }
        }
        WebDAVSyncEngine.log.info("webdav \(trigger.rawValue, privacy: .public): +\(report.uploaded) ↓\(report.downloaded) -\(report.deletedLocal)/\(report.deletedRemote) conflicts \(report.conflicts) failure \(report.failure ?? "none", privacy: .public)")
        if report.changedLocalFiles {
            // New or replaced files from other devices: rescan the catalog and let folder sync (F025, optional)
            // merge them into open documents.
            library.refresh()
            if app.commands.entry(CommandIDs.syncNow) != nil {
                _ = try? await app.bus.execute(CommandIDs.syncNow)
            }
        }
        emit(WebDAVSyncEngine.payload(for: report))
        return report
    }

    private func fail(_ error: WebDAVError) -> WebDAVSyncReport {
        let now = Date().timeIntervalSince1970
        var report = WebDAVSyncReport(started: now)
        report.finished = now
        report.failure = error.reason
        report.errors = [error.message]
        lastFailure = error
        if error == .credentialsMissing {
            emitCredentialsMissing()
        } else {
            lastReport = report
            emit(SyncStatusPayload(state: "error", source: "webdav", reason: error.reason, message: error.message))
        }
        return report
    }

    /// Package paths (library-relative) of documents that are locked and not unlocked in this session.
    func lockedPackages(_ library: LibraryService) -> [String] {
        guard let lock = app?.services.lock else { return [] }
        let rootParts = library.rootURL.standardizedFileURL.pathComponents
        var out: [String] = []
        for node in library.allNodes() + library.trashedNodes() where node.kind == .document && lock.isLocked(node.id) {
            if let url = library.packageURL(node.id) {
                let parts = url.standardizedFileURL.pathComponents
                if parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts {
                    out.append(parts.dropFirst(rootParts.count).joined(separator: "/"))
                    continue
                }
            }
            if !node.path.isEmpty { out.append(node.path) }
        }
        return out
    }

    /// When the library is the app's own Documents folder, the system Inbox and diagnostics folders stay local.
    static func excludedTopLevel(root: URL) -> Set<String> {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              documents.standardizedFileURL.resolvingSymlinksInPath().path
                == root.standardizedFileURL.resolvingSymlinksInPath().path else { return [] }
        return ["Inbox", "diagnostics"]
    }

    /// Uploads one file (webdav.put) to server-relative `components`; an existing file is only replaced with
    /// `overwrite`.
    func put(_ file: URL, components: [String], configuration config: WebDAVConfiguration,
             overwrite: Bool) async throws -> String? {
        let client = makeClient(config)
        let path = components.joined(separator: "/")
        do {
            let target = try WebDAVPaths.fileURL(config.serverURL, path: path)
            try await client.ensureCollections(Array(components.dropLast()))
            return try await client.put(file: file, to: target, precondition: overwrite ? .none : .absent)
        } catch {
            let e = WebDAVError.from(error, host: client.host)
            if case .changedDuringSync = e {
                throw NibError(.conflict, "\(path) already exists on the WebDAV server", path: "$.path",
                               hint: "pass overwrite: true to replace it, or choose another path")
            }
            throw e.nibError
        }
    }

    // MARK: Status

    func status(check: Bool) async -> WebDAVStatusInfo {
        let v = WebDAVSettings.read(settings)
        let configured = !v.url.isEmpty
        let missing = credentialsMissing
        let report = lastReport
        var info = WebDAVStatusInfo(configured: configured, url: configured ? v.url : nil,
                                    user: configured ? v.user : nil, folder: configured ? v.folder : nil,
                                    allowUntrustedCertificates: v.allowUntrustedCertificates,
                                    credentialsMissing: missing, authFailed: configured && authSuspended,
                                    state: "idle", running: isRunning,
                                    lastSync: lastSync, pending: 0, errors: Array((report?.errors ?? []).prefix(20)),
                                    message: nil, lastResult: report, connection: nil)
        if let run = currentRun {
            info.pending = run.progress.remaining
        } else {
            info.pending = (report?.pending ?? 0) + (report?.skippedLocked ?? 0)
        }
        if !configured {
            info.state = "unconfigured"
            info.message = String(localized: "WebDAV is not set up")
        } else if missing {
            info.state = "error"
            info.message = WebDAVError.credentialsMissing.message
        } else if isRunning {
            info.state = "syncing"
            info.message = String(localized: "Syncing…")
        } else if authSuspended {
            info.state = "error"
            info.message = WebDAVError.authenticationFailed.message
        } else if let r = report {
            let payload = WebDAVSyncEngine.payload(for: r)
            info.state = payload.state
            info.message = payload.message
        }
        if check { info.connection = await testConnection() }
        return info
    }

    func testConnection() async -> WebDAVConnectionCheck {
        let config: WebDAVConfiguration
        do {
            config = try loadConfiguration()
        } catch {
            let e = WebDAVError.from(error, host: "")
            return WebDAVConnectionCheck(ok: false, folderExists: nil, message: e.message, reason: e.reason)
        }
        let client = makeClient(config)
        do {
            let result = try await client.checkConnection()
            let message = result.folderExists
                ? String(localized: "Connected. The folder “\(config.folder)” is on the server.")
                : String(localized: "Connected. The folder “\(config.folder)” is created on the first sync.")
            return WebDAVConnectionCheck(ok: true, folderExists: result.folderExists, message: message, reason: nil)
        } catch {
            let e = WebDAVError.from(error, host: client.host)
            return WebDAVConnectionCheck(ok: false, folderExists: nil, message: e.message, reason: e.reason)
        }
    }

    /// Loads the last report of the current configuration from its state file (off the main actor), so the status
    /// survives relaunches.
    func loadSummary() {
        let v = WebDAVSettings.read(settings)
        guard !v.url.isEmpty, let server = try? WebDAVConfiguration.normalizeServerURL(v.url),
              let root = app?.services.library?.rootURL else { return }
        let folder = (try? WebDAVConfiguration.normalizeFolder(v.folder)) ?? WebDAVSettings.folder.defaultValue
        let key = MirrorStateStore.key(server: server, user: v.user, folder: folder, root: root)
        guard key != summaryKey else { return }
        summaryKey = key
        let store = MirrorStateStore(directory: stateDirectory, key: key)
        Task { @MainActor [weak self] in
            let state = await Task.detached(priority: .utility) { store.load() }.value
            guard let self = self, self.summaryKey == key, self.lastReport == nil else { return }
            self.lastReport = state.lastReport
            self.lastSync = state.lastSync
        }
    }

    // MARK: Events

    static func payload(for report: WebDAVSyncReport) -> SyncStatusPayload {
        if report.cancelled {
            return SyncStatusPayload(state: "warning", source: "webdav", reason: "cancelled",
                                     message: WebDAVError.cancelled.message)
        }
        if let failure = report.failure {
            return SyncStatusPayload(state: "error", source: "webdav", reason: failure, message: report.errors.last)
        }
        if report.conflicts > 0 {
            return SyncStatusPayload(state: "warning", source: "webdav", reason: "conflictCopies",
                                     message: String(localized: "Kept both versions of \(report.conflicts) file(s)"),
                                     files: Array(report.conflictFiles.prefix(50)))
        }
        if !report.errors.isEmpty {
            return SyncStatusPayload(state: "warning", source: "webdav", reason: "fileErrors",
                                     message: report.errors.first)
        }
        let copied = report.uploaded + report.downloaded + report.deletedLocal + report.deletedRemote
        let message = copied == 0
            ? String(localized: "Up to date")
            : String(localized: "Synced \(copied) file change(s)")
        return SyncStatusPayload(state: "ok", source: "webdav", message: message)
    }

    private func emitCredentialsMissing() {
        emit(SyncStatusPayload(state: "error", source: "webdav", reason: WebDAVError.credentialsMissing.reason,
                               message: WebDAVError.credentialsMissing.message))
    }

    /// Emits `sync.status` (source "webdav"); an identical error or warning is not repeated every minute.
    private func emit(_ payload: SyncStatusPayload) {
        if payload == lastEmitted, payload.state == "error" || payload.state == "warning" { return }
        lastEmitted = payload
        events.emit(payload)
    }
}
