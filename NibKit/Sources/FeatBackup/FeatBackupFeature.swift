import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

public enum FeatBackupFeature: NibFeature {
    public static let id = "backup"
    static let backgroundID = "app.nib.backup"

    public static func register(_ app: NibApp) {
        BackupSettings.declare(app.settings)
        app.commands.register(BackupNow.self)
        app.commands.register(BackupManual.self)
        app.commands.register(BackupConfigure.self)
        app.commands.register(BackupChooseFolder.self)
        app.commands.register(BackupStatus.self)
        app.commands.register(BackupClearQueue.self)
        let engine = BackupEngine(app: app)
        app.services.set(engine, for: BackupEngine.serviceKey)
        var page = SettingsPageDescriptor(id: "backup.settings", title: String(localized: "Backup"), icon: NibSymbol.backup.name,
                                          section: .sync, order: 20, owner: id) { app in AnyView(BackupSettingsPage(app: app)) }
        page.keywords = ["backup", "restore", "zip", "PDF", "Dropbox", "Google Drive", "OneDrive", "iCloud", "WebDAV"]
        app.ui.settingsPages.register(page)
        app.content.keyCommands.register(KeyCommandDescriptor(id: "backup.now.key", title: String(localized: "Back Up Now"),
            shortcut: KeyShortcut("b", [.command, .shift, .option]), command: CommandIDs.backupNow, scope: .global, owner: id))
        app.content.backgroundTasks.register(BackgroundTaskDescriptor(id: backgroundID, kind: .processing, owner: id) { [weak engine] _ in
            await engine?.automaticPass() ?? false
        })
    }

    public static func start(_ app: NibApp) async {
        await app.services.get(BackupEngine.serviceKey, as: BackupEngine.self)?.start()
    }
}

enum BackupExecution {
    @TaskLocal static var automatic = false
}

struct BackupStatusInfo: Codable {
    var configuration: BackupConfiguration
    var folderName: String
    var folderChosen: Bool
    var queued: Int
    var running: Bool
    var state: String
    var progress: Double
    var lastAttempt: Double?
    var lastSuccess: Double?
    var error: String?
    var skippedLocked: Int
    var nextRun: Double?
    var manual: Bool
    var manualInterrupted: Bool
}

@MainActor
final class BackupEngine {
    static let serviceKey = "backup.engine"
    private weak var app: NibApp?
    private(set) var queue = BackupQueue()
    var store: BackupQueueStore
    var userInterface: BackupUserInterface = BackupSystemPicker()
    var now: () -> Date = Date.init
    private var loaded = false
    private var loading: Task<BackupQueue, Error>?
    private var saving: Task<Void, Error>?
    private var commitSubscription: EventSubscription?
    private var eventSubscription: EventSubscription?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var scheduled: Task<Bool, Never>?
    private var pendingCommit: Task<Void, Never>?
    private var scheduledDue: Double?
    // Lifecycle and archive hooks keep interruption tests independent of a foreground simulator window.
    var archive: (URL, [URL], Progress, Set<DocumentID>, Set<DocumentID>) async throws -> URL = {
        try await BackupWriter.archive(root: $0, blocked: $1, progress: $2, unlockedDocuments: $3, lockedDocuments: $4)
    }
    var resumeManual: (() -> Void)?
    private var previousNodes: [LibraryNode] = []
    private var generation = UUID()
    private(set) var running = false
    private(set) var state = "idle"
    private(set) var error: String?
    private var progress = 0.0
    private var manualProgress: Progress?
    private var manualInterrupted = false
    private var skippedLocked = 0

    init(app: NibApp) {
        self.app = app
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        store = BackupQueueStore(url: base.appendingPathComponent("Nib/Backup/queue-" + app.deviceHex + ".json"))
    }

    deinit {
        pendingCommit?.cancel(); commitSubscription?.cancel(); eventSubscription?.cancel(); timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static func resolve(_ services: NibServices) throws -> BackupEngine {
        guard let engine = services.get(serviceKey, as: BackupEngine.self) else { throw NibError.unavailable("Backup") }
        return engine
    }

    func ensureLoaded() async throws {
        guard !loaded else { return }
        let task: Task<BackupQueue, Error>
        if let existing = loading { task = existing }
        else { let disk = store; task = Task { try await disk.load() }; loading = task }
        do {
            let recovered = try await task.value
            if !loaded { queue = recovered; loaded = true }
            loading = nil
        } catch {
            loading = nil
            report(error)
            throw NibError(.unavailable, "The backup queue could not be read", hint: "Call backup.clearQueue to reset the device queue")
        }
    }

    /// Captures each version before scheduling the write; the chain prevents an older disk write winning a race.
    @discardableResult
    func persist() -> Task<Void, Error> {
        let snapshot = queue, disk = store, previous = saving
        let task = Task { if let previous { _ = try? await previous.value }; try await disk.save(snapshot) }
        saving = task
        Task { [weak self] in do { try await task.value } catch { self?.report(error) } }
        return task
    }

    func start() async {
        guard commitSubscription == nil, let app else { return }
        do { try await ensureLoaded() } catch { report(error) }
        previousNodes = app.services.library?.allNodes() ?? []
        commitSubscription = app.bus.observeCommits { [weak self] changes in self?.committed(changes) }
        eventSubscription = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor in await self?.libraryChanged() }
        }
        if !NibApp.isHostlessTest {
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.scheduled?.cancel()
                    self.interruptManualForBackground()
                    self.schedule()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeInterruptedManual(); self?.tick() }
            })
            // A cheap foreground check; no exports or network requests until the selected interval is due.
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            tick()
        }
        schedule(); emit()
    }

    func committed(_ changes: Changeset) {
        if changes.mutations.contains(where: { mutation in
            if case let .meta(_, _, after) = mutation { return after.locked }
            return false
        }) { manualProgress?.cancel() }
        let documents = Set(changes.mutations.filter(BackupQueue.triggers).map(\.document))
        guard !documents.isEmpty, loaded, let app,
              app.settings.get(BackupSettings.destination).kind != "none" else { return }
        var config: BackupConfiguration?
        var queued = false
        for doc in documents {
            // An existing entry only needs a fresh token, protecting edits made during an in-flight export.
            if queue.contains(doc) {
                queue.enqueue(doc, at: now().timeIntervalSince1970); queued = true
                continue
            }
            guard let node = app.services.library?.node(doc), node.kind == .document, node.trashedAt == nil else { continue }
            if config == nil { config = BackupSettings.read(app.settings) }
            guard !BackupQueue.excluded(node.title, substrings: config?.exclusions ?? []) else { continue }
            queue.enqueue(doc, at: now().timeIntervalSince1970); queued = true
        }
        if queued { coalesceCommitEffects() }
    }

    private func coalesceCommitEffects() {
        guard pendingCommit == nil else { return }
        pendingCommit = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self else { return }
            self.pendingCommit = nil
            self.persist(); self.schedule(); self.emit()
        }
    }

    func interruptManualForBackground() {
        guard let progress = manualProgress else { return }
        manualInterrupted = true; progress.cancel(); emit()
    }

    func resumeInterruptedManual() {
        guard manualInterrupted, !running, let app else { return }
        manualInterrupted = false
        if let resumeManual { resumeManual() }
        else { app.perform(CommandIDs.backupManual) }
    }

    func libraryChanged() async {
        guard loaded, let app else { return }
        let nodes = app.services.library?.allNodes() ?? []
        let before = previousNodes
        previousNodes = nodes
        let allowed = eligible(nodes)
        queue.retain(allowed)
        let config = BackupSettings.read(app.settings)
        guard config.destination.kind != "none" else { persist(); emit(); return }
        let runGeneration = generation
        var changed = BackupQueue.changedDocuments(before: before, after: nodes)
        let oldNodes = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for node in nodes where allowed.contains(node.id) && oldNodes[node.id]?.modified != node.modified && !changed.contains(node.id) {
            do {
                if let lock = app.services.lock, lock.isLocked(node.id) { continue }
                if app.services.lock == nil {
                    if node.locked { continue }
                    if try app.workspace.persistence.loadHead(node.id).meta.locked { continue }
                }
                let old = try await store.loadStamp(node.id)
                let fresh = try await contentStamp(node.id, persistence: app.workspace.persistence, previous: old)
                guard generation == runGeneration else { return }
                if old == nil || fresh.hasChanges(since: old!) { changed.insert(node.id) }
                // Even ignored changes advance the baseline, so restoring a removed record is a new change.
                try await store.saveStamp(fresh, document: node.id)
            } catch { report(error) }
        }
        guard generation == runGeneration else { return }
        for doc in changed where allowed.contains(doc) { queue.enqueue(doc, at: now().timeIntervalSince1970) }
        persist(); schedule(); emit()
    }

    /// Persistence, rather than cached Workspace pages, sees unopened documents downloaded by WebDAV too.
    /// Exclude only the specified non-triggers; content, attachments, audio records and plugin data remain visible.
    func contentStamp(_ doc: DocumentID, persistence: DocumentPersistence, previous: BackupContentStamp? = nil) async throws -> BackupContentStamp {
        let head = try persistence.loadHead(doc)
        let builder = BackupStampBuilder(previous: previous, pages: Set(head.livePages.map { $0.id.raw }))
        var meta = head.meta
        meta.rev = .zero; meta.favorite = false; meta.sourceBookmark = nil; meta.trashedFrom = nil
        var records: [(String, JSONValue)] = [("meta", try JSONValue.from(meta))]
        for var page in head.livePages {
            page.rev = .zero; page.bookmarked = false
            records.append(("page:" + page.id.raw, try JSONValue.from(page)))
        }
        for var block in head.liveBlocks { block.rev = .zero; records.append(("block:" + block.id.raw, try JSONValue.from(block))) }
        for var card in head.liveCards { card.rev = .zero; records.append(("card:" + card.id.raw, try JSONValue.from(card))) }
        for var audio in head.liveAudio { audio.rev = .zero; records.append(("audio:" + audio.id.raw, try JSONValue.from(audio))) }
        try await builder.add(records)
        for page in head.livePages {
            try Task.checkCancellation()
            let revision = persistence.contentRevision(doc, page: page.id)
            await builder.revision(revision, page: page.id)
            if revision == nil || previous?.pageRevisions?[page.id.raw] != revision {
                let items = try persistence.loadItems(doc, page: page.id)
                try await builder.addItems(items, page: page.id)
            }
        }
        return await builder.result()
    }

    func eligible(_ nodes: [LibraryNode]) -> Set<DocumentID> {
        guard let app else { return [] }
        let config = BackupSettings.read(app.settings)
        return Set(nodes.filter { $0.kind == .document && $0.trashedAt == nil && !BackupQueue.excluded($0.title, substrings: config.exclusions) }.map(\.id))
    }

    func configurationChanged() async throws {
        try await ensureLoaded()
        let oldQueue = queue
        generation = UUID()
        guard let app else { return }
        let nodes = app.services.library?.allNodes() ?? []
        queue.clear()
        if BackupSettings.read(app.settings).destination.kind != "none" {
            for id in eligible(nodes).sorted() { queue.enqueue(id, at: now().timeIntervalSince1970) }
        }
        queue.lastAttempt = now().timeIntervalSince1970 - BackupQueue.interval(frequent: BackupSettings.read(app.settings).frequent)
        previousNodes = nodes
        error = nil; state = running ? "syncing" : "idle"
        do { try await persist().value }
        catch { queue = oldQueue; report(error); throw NibError.wrap(error) }
        schedule(); emit()
    }

    func clearQueue() async throws {
        // Explicit reset also recovers corrupt state. Already-running exports cannot acknowledge new queue versions.
        if !loaded { loading?.cancel(); loading = nil; queue = BackupQueue(); loaded = true }
        generation = UUID(); queue.clear(); error = nil
        try await persist().value
        state = running ? "syncing" : "idle"; emit(); schedule()
    }

    func status() -> BackupStatusInfo {
        guard let app else {
            return BackupStatusInfo(configuration: BackupConfiguration(destination: BackupDestination(kind: "none"), format: "nib", folder: "", exclusions: [], frequent: false),
                folderName: "", folderChosen: false, queued: 0, running: false, state: "error", progress: 0,
                error: "Backup unavailable", skippedLocked: 0, manual: false, manualInterrupted: false)
        }
        let config = BackupSettings.read(app.settings)
        let next = queue.entries.isEmpty || config.destination.kind == "none" ? nil :
            (queue.lastAttempt ?? queue.entries.map(\.queuedAt).min() ?? now().timeIntervalSince1970) + BackupQueue.interval(frequent: config.frequent)
        return BackupStatusInfo(configuration: config, folderName: app.settings.get(BackupSettings.folderName),
            folderChosen: app.settings.get(BackupSettings.bookmark) != nil, queued: queue.entries.count, running: running,
            state: state, progress: manualProgress?.fractionCompleted ?? progress, lastAttempt: queue.lastAttempt,
            lastSuccess: queue.lastSuccess, error: error, skippedLocked: skippedLocked, nextRun: next, manual: manualProgress != nil, manualInterrupted: manualInterrupted)
    }

    func emit() {
        guard let app else { return }
        app.events.emit(NibEventType.backupStatus, payload: ["state": .string(state), "queued": .number(Double(queue.entries.count))])
        app.events.emit(SyncStatusPayload(state: state, source: "backup", message: error))
    }
    func report(_ failure: Error) { error = NibError.wrap(failure).message; state = "error"; emit() }

    func schedule() {
        guard let app, !queue.entries.isEmpty else { scheduledDue = nil; return }
        let config = BackupSettings.read(app.settings)
        guard config.destination.kind != "none" else { scheduledDue = nil; return }
        let due = (queue.lastAttempt ?? queue.entries.map(\.queuedAt).min() ?? now().timeIntervalSince1970) + BackupQueue.interval(frequent: config.frequent)
        guard due != scheduledDue else { return }
        scheduledDue = due
        app.scheduleBackgroundTask(FeatBackupFeature.backgroundID, earliestIn: max(1, due - now().timeIntervalSince1970))
    }
    func tick() {
        guard scheduled == nil, let app, UIApplication.shared.applicationState == .active,
              !ProcessInfo.processInfo.isLowPowerModeEnabled, ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              queue.isDue(at: now().timeIntervalSince1970, frequent: BackupSettings.read(app.settings).frequent) else { return }
        scheduled = Task { [weak self] in
            let result = await self?.automaticPass() ?? false
            self?.scheduled = nil
            return result
        }
    }
    func automaticPass() async -> Bool {
        guard let app else { return false }
        defer { schedule() }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { return true }
        do {
            try await BackupExecution.$automatic.withValue(true) { try await app.bus.execute(CommandIDs.backupNow) }
            return error == nil
        } catch { report(error); return false }
    }

    func run(_ ctx: CommandContext, automatic: Bool) async throws -> BackupStatusInfo {
        try await ensureLoaded()
        guard let app else { throw NibError.unavailable("Backup") }
        guard !running else { return status() }
        let config = BackupSettings.read(app.settings)
        guard config.destination.kind != "none" else {
            if automatic { return status() }
            throw NibError.unavailable("Choose an automatic backup destination first")
        }
        let library = try ctx.services.require(ctx.services.library, "Library")
        let nodes = library.allNodes()
        if ctx.dryRun { return status() }
        queue.retain(eligible(nodes))
        if !automatic { for id in eligible(nodes).sorted() { queue.enqueue(id, at: now().timeIntervalSince1970) } }
        if automatic && !queue.isDue(at: now().timeIntervalSince1970, frequent: config.frequent) { try await persist().value; return status() }
        let bookmark = app.settings.get(BackupSettings.bookmark)
        if config.destination.kind == "folder", bookmark == nil { throw NibError.unavailable("Choose a folder with backup.chooseFolder") }
        let runGeneration = generation
        running = true; state = "syncing"; error = nil; progress = 0; skippedLocked = 0
        defer { running = false; schedule(); emit() }
        queue.lastAttempt = now().timeIntervalSince1970
        do { try await persist().value } catch { report(error); throw NibError.wrap(error) }
        let batch = queue.entries
        emit()
        var failure: Error?
        for (index, entry) in batch.enumerated() {
            do {
                try Task.checkCancellation()
                guard generation == runGeneration else { break }
                guard let node = library.node(entry.document), node.trashedAt == nil else { queue.acknowledge(entry); continue }
                if isLocked(entry.document, node: node, ctx: ctx) { skippedLocked += 1; continue }
                ctx.workspace.persistence.flush(entry.document)
                let oldStamp = try await store.loadStamp(entry.document)
                let stamp = try await contentStamp(entry.document, persistence: ctx.workspace.persistence, previous: oldStamp)
                let formats = config.format == "both" ? ["nibnote", "pdf"] : [config.format == "nib" ? "nibnote" : "pdf"]
                for format in formats {
                    try Task.checkCancellation()
                    let result = try await ctx.execute(CommandIDs.exportRun, ["docs": .array([.string("doc:" + entry.document.raw)]), "format": .string(format)])
                    guard let files = result["files"]?.arrayValue, !files.isEmpty else { throw NibError(.internalError, "The exporter returned no backup files") }
                    for (fileIndex, file) in files.enumerated() {
                        try Task.checkCancellation()
                        guard generation == runGeneration else { throw CancellationError() }
                        guard !isLocked(entry.document, node: node, ctx: ctx) else { throw NibError(.locked, "Document was locked during backup") }
                        guard library.node(entry.document)?.trashedAt == nil, library.node(entry.document) != nil else { throw CancellationError() }
                        guard let asset = file["asset"]?.stringValue else { throw NibError(.internalError, "The exporter returned an invalid file") }
                        var path = try BackupWriter.relativePath(node: node, nodes: nodes, folder: config.folder, extension: format == "pdf" ? "pdf" : "nibnote.zip")
                        if files.count > 1 {
                            let base = (path as NSString).deletingPathExtension
                            path = base + "-" + String(fileIndex + 1) + "." + (format == "pdf" ? "pdf" : "zip")
                        }
                        if config.destination.kind == "webdav" {
                            _ = try await ctx.execute(CommandIDs.webdavPut, ["path": .string(path), "file": .string(asset), "overwrite": true])
                        } else if let bookmark {
                            let source = try await ctx.inputFile(asset)
                            try await BackupWriter.write(source: source, relativePath: path, bookmark: bookmark, libraryRoot: library.rootURL)
                        }
                    }
                }
                if generation == runGeneration {
                    try await store.saveStamp(stamp, document: entry.document)
                    if generation == runGeneration { queue.acknowledge(entry) }
                }
                try await persist().value
            } catch {
                if let nibError = error as? NibError, nibError.code == .locked { skippedLocked += 1; continue }
                if error is CancellationError { state = "warning"; self.error = String(localized: "Backup paused. Pending documents will resume on the next run."); break }
                failure = error
            }
            progress = Double(index + 1) / Double(max(1, batch.count)); emit()
        }
        if generation != runGeneration { state = "idle"; self.error = nil; progress = 0; return status() }
        if let failure { report(failure) }
        else if self.error == nil {
            if skippedLocked > 0 { state = "warning"; self.error = String(localized: "Locked documents were skipped. Unlock them to include them in the next backup.") }
            else { state = "ok"; queue.lastSuccess = now().timeIntervalSince1970; progress = 1 }
        }
        try await persist().value
        if let failure { throw NibError.wrap(failure) }
        return status()
    }

    func isLocked(_ document: DocumentID, node: LibraryNode, ctx: CommandContext) -> Bool {
        if let lock = ctx.services.lock { return lock.isLocked(document) }
        return node.locked || ((try? ctx.workspace.peekContent(document).meta.locked) ?? false)
    }

    func manual(_ ctx: CommandContext) async throws -> JSONValue {
        guard !running else { throw NibError.unavailable("A backup is already running") }
        let library = try ctx.services.require(ctx.services.library, "Library")
        let navigator = ctx.navigator
        // Window callers export the ZIP directly; only headless callers need a temporary asset.
        let assets = navigator == nil ? try ctx.services.require(ctx.services.assets, "Asset store") : nil
        let nodes = library.allNodes() + library.trashedNodes()
        var blocked: [URL] = []
        var unlockedDocuments = Set<DocumentID>()
        var lockedDocuments = Set<DocumentID>()
        skippedLocked = 0
        for node in nodes where node.kind == .document {
            if isLocked(node.id, node: node, ctx: ctx) {
                skippedLocked += 1; lockedDocuments.insert(node.id)
                if let url = library.packageURL(node.id) { blocked.append(url) }
                blocked.append(library.rootURL.appendingPathComponent(node.path))
                // Trash layouts can differ from their original catalog paths.
                blocked.append(library.metadataURL.appendingPathComponent("trash/" + node.id.raw + ".nibnote"))
            } else { unlockedDocuments.insert(node.id); ctx.workspace.persistence.flush(node.id) }
        }
        if ctx.dryRun { return ["skippedLocked": .number(Double(skippedLocked))] }
        let progress = Progress(totalUnitCount: 1)
        let lifecycle = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interruptManualForBackground() }
        }
        manualProgress = progress; manualInterrupted = false; running = true; state = "syncing"; error = nil; emit()
        let publisher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.emit()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(lifecycle); publisher.cancel(); manualProgress = nil; running = false; emit()
            // Activation may arrive before cancellation finishes unwinding.
            if !NibApp.isHostlessTest, UIApplication.shared.applicationState == .active { resumeInterruptedManual() }
        }
        do {
            let url = try await withTaskCancellationHandler {
                try await archive(library.rootURL, blocked, progress, unlockedDocuments, lockedDocuments)
            } onCancel: { progress.cancel() }
            defer { try? FileManager.default.removeItem(at: url) }
            for node in library.allNodes() + library.trashedNodes() where unlockedDocuments.contains(node.id) {
                if isLocked(node.id, node: node, ctx: ctx) { progress.cancel() }
            }
            guard !progress.isCancelled else { throw CancellationError() }
            var result: [String: JSONValue] = ["name": .string(url.lastPathComponent),
                "skippedLocked": .number(Double(skippedLocked)), "restoreCommand": .string(CommandIDs.importPick)]
            if let navigator {
                try await userInterface.saveArchive(url, navigator: navigator)
            } else if let assets {
                let ref = try await Task.detached(priority: .utility) {
                    try assets.putTemporary(Data(contentsOf: url, options: .mappedIfSafe), ext: "zip")
                }.value
                result["asset"] = .string("tmp:" + ref.name)
            }
            state = skippedLocked == 0 ? "ok" : "warning"
            if skippedLocked > 0 { error = String(localized: "Locked documents were skipped. Unlock them and create another backup to include them.") }
            return .object(result)
        } catch {
            if progress.isCancelled || error is CancellationError {
                state = "warning"
                self.error = String(localized: "Manual backup was interrupted. It restarts when Nib returns to the foreground.")
                throw NibError(.unavailable, self.error!)
            }
            if let failure = error as? NibError, failure.code == .userDenied {
                state = "idle"; self.error = nil; emit(); throw failure
            }
            report(error); throw NibError.wrap(error)
        }
    }
}
