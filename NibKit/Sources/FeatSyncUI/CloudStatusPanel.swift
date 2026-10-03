import Foundation
import Observation
import SwiftUI
import NibContracts
import NibDesign

struct CloudSyncState: Equatable {
    var state: String
    var message: String?
    var reason: String?
    var files: [String]

    init(_ payload: SyncStatusPayload) {
        state = payload.state
        message = payload.message
        reason = payload.reason
        files = payload.files ?? []
    }

    var needsAttention: Bool { state == "error" || state == "warning" }
    var running: Bool { ["checking", "syncing", "downloading"].contains(state) }
    var title: String {
        switch state {
        case "checking": return String(localized: "Checking for changes…")
        case "syncing": return String(localized: "Syncing…")
        case "downloading": return files.isEmpty ? String(localized: "Downloading…") : String(localized: "Downloading ^[\(files.count) file](inflect: true)…")
        case "error": return String(localized: "Sync needs attention")
        case "warning": return String(localized: "Check sync warning")
        case "ok", "idle", "synced": return String(localized: "Up to date")
        case "localOnly": return String(localized: "Saved on this device")
        default: return String(localized: "Not checked yet")
        }
    }
    var symbol: NibSymbol { needsAttention ? .syncError : running ? .syncing : .syncDone }
    var phase: NibTraceRow.Phase { needsAttention ? .warning : running ? .running : .done }
    var rank: Int {
        switch state {
        case "error": return 5
        case "warning": return 4
        case "downloading": return 3
        case "checking", "syncing": return 2
        case "ok", "idle", "synced": return 1
        default: return 0
        }
    }
}

struct CloudDocument: Identifiable, Equatable {
    var ref: String
    var title: String
    var badge: String
    var readOnly: Bool
    var locked: Bool
    var id: String { ref }
    var documentID: DocumentID { NodeRef.documentID(from: ref) }
}

/// Queries supply snapshots; events supply transient per-source, per-document state.
/// Keeping each source separately prevents a successful folder check from hiding a failed save or backup.
@MainActor @Observable
final class CloudStatusModel {
    static let key = "syncui.statusModel"
    private weak var app: NibApp?
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var locationRequested = false
    @ObservationIgnored private var catalogDirty = true
    @ObservationIgnored private var visibleHosts = 0
    @ObservationIgnored private var lastServiceRefresh = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var querySequence = 0
    @ObservationIgnored private var sequences: [String: UInt64] = [:]
    @ObservationIgnored private var documentSequences: [DocumentID: UInt64] = [:]
    private var rootSequence: UInt64 = 0
    private var statuses: [DocumentID: [String: CloudSyncState]] = [:]
    private var globalStatuses: [String: CloudSyncState] = [:]
    private var catalogDocuments: [DocumentID: CloudDocument] = [:]
    private(set) var documents: [CloudDocument] = []
    private(set) var attentionDocuments: [CloudDocument] = []
    private(set) var syncState = CloudSyncState(SyncStatusPayload(state: "unknown", source: "sync"))
    var locationName = String(localized: "Library location unavailable")
    var locationPath: String?
    var provider = String(localized: "Files")
    var inContainer = false
    var backup: JSONValue?
    var webdav: JSONValue?
    var backupError: String?
    var webdavError: String?
    var actionError: String?
    var receipt: String?
    var verificationRef: String?
    var canCopyLibrary = false
    var busy = false
    var loading = false

    static func shared(_ app: NibApp) -> CloudStatusModel {
        if let existing = app.services.get(key, as: CloudStatusModel.self) { return existing }
        let model = CloudStatusModel(app: app)
        app.services.set(model, for: key)
        return model
    }

    init(app: NibApp) {
        self.app = app
        inContainer = app.services.get("library.inContainer", as: NSNumber.self)?.boolValue ?? false
        // Subscribe before replay: sequence checks discard duplicates and delayed events from older libraries.
        subscription = app.events.subscribe { [weak self] event in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.consume(event) }
            } else {
                Task { @MainActor [weak self] in self?.consume(event) }
            }
        }
        for event in app.events.events(since: 0, limit: app.events.capacity) { consume(event, scheduleQueries: false) }
    }

    deinit {
        subscription?.cancel()
        refreshTask?.cancel()
    }

    func consume(_ event: NibEvent, scheduleQueries: Bool = true) {
        let rootChanged = event.type == NibEventType.libraryChanged && event.payload?["root"]?.boolValue == true
        if rootChanged {
            guard event.seq > rootSequence else { return }
            rootSequence = event.seq
            generation += 1
            statuses.removeAll()
            globalStatuses.removeAll()
            sequences.removeAll()
            documentSequences.removeAll()
            catalogDocuments.removeAll()
            backup = nil
            webdav = nil
            verificationRef = nil
            receipt = nil
            canCopyLibrary = false
        }
        guard event.seq >= rootSequence else { return }
        if event.type == NibEventType.docClosed, let doc = event.doc {
            guard event.seq > (documentSequences[doc] ?? 0) else { return }
            documentSequences[doc] = event.seq
            statuses.removeValue(forKey: doc)
            updateDerivedState()
        }
        if let payload = event.decode(SyncStatusPayload.self) {
            let key = Self.statusKey(source: payload.source, doc: event.doc)
            guard event.seq > (sequences[key] ?? 0),
                  event.doc.map({ event.seq > (documentSequences[$0] ?? 0) }) ?? true else { return }
            sequences[key] = event.seq
            if let doc = event.doc { statuses[doc, default: [:]][payload.source] = CloudSyncState(payload) }
            else { globalStatuses[payload.source] = CloudSyncState(payload) }
            updateDerivedState()
        }
        if event.type == NibEventType.libraryChanged {
            catalogDirty = true
            inContainer = app?.services.get("library.inContainer", as: NSNumber.self)?.boolValue ?? false
            if visibleHosts > 0 { readCatalogIfNeeded() }
            else if rootChanged { updateDerivedState() }
            app?.ui.setNeedsChromeUpdate()
        }
        guard scheduleQueries, visibleHosts > 0 else { return }
        if rootChanged { requestRefresh(includeLocation: true) }
        else if [NibEventType.backupStatus, NibEventType.syncStatus].contains(event.type) {
            requestRefresh()
        }
    }

    static func statusKey(source: String, doc: DocumentID?) -> String { source + ":" + (doc?.raw ?? "") }

    func documentStatus(_ doc: DocumentID) -> CloudSyncState {
        let catalog = catalogDocuments[doc]?.badge ?? app?.services.library?.node(doc)?.sync.rawValue ?? "unknown"
        let fallback = CloudSyncState(SyncStatusPayload(state: catalog, source: "catalog"))
        return (Array(statuses[doc]?.values ?? [:].values) + [fallback]).max { $0.rank < $1.rank } ?? fallback
    }

    func isDownloading(_ doc: DocumentID) -> Bool {
        catalogDocuments[doc]?.badge == "downloading" || app?.services.library?.node(doc)?.sync == .downloading
            || statuses[doc]?.values.contains { $0.state == "downloading" || $0.reason == "downloadTimeout" } == true
    }

    private func documentRow(_ doc: DocumentID) -> CloudDocument {
        if let row = catalogDocuments[doc] { return row }
        let node = app?.services.library?.node(doc)
        return CloudDocument(ref: NodeRef.document(doc).description,
                             title: node?.title ?? String(localized: "Untitled Document"),
                             badge: node?.sync.rawValue ?? "unknown",
                             readOnly: app?.isReadOnly(doc) ?? false, locked: node?.locked ?? false)
    }

    private func updateDerivedState() {
        let states = globalStatuses.filter { !["backup", "webdav"].contains($0.key) }.map(\.value)
            + statuses.values.flatMap { $0.filter { !["backup", "webdav"].contains($0.key) }.map(\.value) }
            + catalogDocuments.values.map { CloudSyncState(SyncStatusPayload(state: $0.badge, source: "catalog")) }
        syncState = states.max { $0.rank < $1.rank }
            ?? CloudSyncState(SyncStatusPayload(state: "unknown", source: "sync"))
        if syncState.state == "downloading" { syncState.files = states.filter { $0.state == "downloading" }.flatMap(\.files) }
        let eventDocuments = statuses.filter { $0.value.values.contains { $0.needsAttention || $0.running } }.keys
        let candidates = Set(catalogDocuments.keys).union(eventDocuments)
        documents = candidates.map { documentRow($0) }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        attentionDocuments = documents.filter {
            let state = documentStatus($0.documentID)
            return $0.readOnly || state.needsAttention || state.state == "downloading"
        }
        app?.ui.setNeedsChromeUpdate()
    }

    private func readCatalogIfNeeded() {
        guard catalogDirty, let app else { return }
        catalogDirty = false
        catalogDocuments = Dictionary(uniqueKeysWithValues: (app.services.library?.allNodes() ?? []).compactMap { node in
            guard node.kind == .document,
                  node.sync == .error || node.sync == .downloading || app.isReadOnly(node.id) else { return nil }
            let row = CloudDocument(ref: NodeRef.document(node.id).description, title: node.title,
                                    badge: node.sync.rawValue, readOnly: app.isReadOnly(node.id), locked: node.locked)
            return (node.id, row)
        })
        updateDerivedState()
    }

    func visibilityBegan() {
        visibleHosts += 1
        readCatalogIfNeeded()
        requestRefresh(includeLocation: true)
    }

    func visibilityEnded() {
        visibleHosts = max(0, visibleHosts - 1)
        if visibleHosts == 0 {
            refreshTask?.cancel()
            refreshTask = nil
            refreshRequested = false
            locationRequested = false
            querySequence += 1
            loading = false
        }
    }

    /// Only successful repair evidence clears stale save/repair alerts, never an unrelated sync idle.
    func repairCompleted(_ report: LibraryRepair.Output, since sequence: UInt64) {
        let unresolved = Set((report.errors.map(\.ref) + report.skippedReadOnly).compactMap { NodeRef($0)?.documentID })
        let libraryFailed = report.errors.contains { NodeRef($0.ref)?.documentID == nil }
        if !libraryFailed {
            for doc in Array(statuses.keys) where !unresolved.contains(doc) && !isDownloading(doc) && app?.isReadOnly(doc) != true {
                for source in ["store", "syncui"] where (sequences[Self.statusKey(source: source, doc: doc)] ?? 0) <= sequence {
                    // Clock and format warnings need evidence from their emitter, not merely an empty merge report.
                    if source == "store", statuses[doc]?[source]?.state != "error" { continue }
                    statuses[doc]?.removeValue(forKey: source)
                }
                if statuses[doc]?.isEmpty == true { statuses.removeValue(forKey: doc) }
            }
        }
        updateDerivedState()
    }

    func requestRefresh(includeLocation: Bool = false) {
        refreshRequested = true
        locationRequested = locationRequested || includeLocation
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.refreshRequested && !Task.isCancelled {
                let delay = max(0, 1 - Date().timeIntervalSince(self.lastServiceRefresh))
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                let location = self.locationRequested
                self.refreshRequested = false
                self.locationRequested = false
                await self.refresh(includeLocation: location)
            }
            if !Task.isCancelled { self.refreshTask = nil }
        }
    }

    func query(_ id: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        guard let app else { throw NibError.unavailable("the app") }
        return try await app.bus.execute(Invocation(command: id, params: params, readOnly: true)).value
    }

    func refresh(includeLocation: Bool = true) async {
        guard let app else { return }
        readCatalogIfNeeded()
        let ticket = generation
        querySequence += 1
        let request = querySequence
        let root = app.services.library?.rootURL
        lastServiceRefresh = Date()
        loading = true
        defer { if request == querySequence { loading = false } }
        let location = includeLocation ? try? await query(CommandIDs.libraryLocations) : nil
        guard !Task.isCancelled else { return }
        var newBackup: JSONValue?
        var newWebdav: JSONValue?
        var newBackupError: String?
        var newWebdavError: String?
        if app.commands.entry(CommandIDs.backupStatus) != nil {
            do { newBackup = try await query(CommandIDs.backupStatus) }
            catch { newBackupError = NibError.wrap(error).message }
        }
        guard !Task.isCancelled else { return }
        if app.commands.entry(CommandIDs.webdavStatus) != nil {
            do { newWebdav = try await query(CommandIDs.webdavStatus) }
            catch { newWebdavError = NibError.wrap(error).message }
        }
        guard !Task.isCancelled, ticket == generation, request == querySequence, root == app.services.library?.rootURL else { return }
        backup = newBackup
        webdav = newWebdav
        backupError = newBackupError
        webdavError = newWebdavError
        inContainer = app.services.get("library.inContainer", as: NSNumber.self)?.boolValue ?? false
        if let current = location?["locations"]?.arrayValue?.first(where: { $0["current"]?.boolValue == true }) {
            locationName = current["name"]?.stringValue ?? String(localized: "Library")
            locationPath = current["path"]?.stringValue
            provider = Self.providerName(current["provider"]?.stringValue)
        } else if includeLocation {
            locationName = String(localized: "Library location unavailable")
            locationPath = nil
        }
    }

    static func providerName(_ raw: String?) -> String {
        switch raw {
        case "app": return String(localized: "Inside Nib")
        case "icloud", "iCloud": return String(localized: "iCloud Drive")
        case "local": return String(localized: "On this device")
        default: return raw.flatMap { $0 == "files" ? nil : $0 } ?? String(localized: "Files")
        }
    }

    func serviceState(_ source: String) -> CloudSyncState? { globalStatuses[source] }

    static func pending(_ snapshot: JSONValue?) -> Int? {
        snapshot?["pending"]?.intValue ?? snapshot?["queued"]?.intValue ?? snapshot?["queue"]?.arrayValue?.count
    }

    static func errors(_ snapshot: JSONValue?) -> [String] {
        (snapshot?["errors"]?.arrayValue ?? []).compactMap {
            $0.stringValue ?? $0["message"]?.stringValue ?? $0["error"]?.stringValue
        }
    }

    func perform(_ command: String, params: JSONValue = [:], session: EditorSession? = nil) {
        guard !busy, let app else { return }
        let ticket = generation
        let sequence = app.events.lastSeq
        busy = true
        actionError = nil
        receipt = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let result = try await app.bus.execute(command, params, session: session)
                guard ticket == self.generation else { return }
                if command == CommandIDs.libraryRepair {
                    let report = try result.decode(LibraryRepair.Output.self)
                    self.repairCompleted(report, since: sequence)
                    self.receipt = report.errors.isEmpty
                        ? String(localized: "Catalogue checked. ^[\(report.merged) record](inflect: true) merged.")
                        : report.errors.count == 1
                            ? String(localized: "Catalogue checked. One document still needs attention.")
                            : String(localized: "Catalogue checked. ^[\(report.errors.count) document](inflect: true) still need attention.")
                }
                await self.refresh()
            } catch {
                if ticket == self.generation {
                    let failure = NibError.wrap(error)
                    self.actionError = failure.message
                    if command == CommandIDs.libraryRelocate, failure.code == .invalidParams, failure.path == "$.copy" {
                        self.canCopyLibrary = true
                    }
                }
            }
        }
    }

    /// The duplicate is preserved even if verification fails, and the original is never removed.
    /// Opening the copy lets the user check its pages before deciding what to keep.
    func duplicateAndVerify(_ document: CloudDocument, session: EditorSession?) {
        guard !busy, !isDownloading(document.documentID),
              !document.readOnly, !document.locked, let app else { return }
        let ticket = generation
        busy = true
        actionError = nil
        receipt = nil
        verificationRef = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            var copyRef: String?
            do {
                guard app.commands.entry(CommandIDs.queryGet) != nil else { throw NibError.unavailable("document verification") }
                let readSequence = app.events.lastSeq
                app.workspace.persistence.flush(document.documentID)
                let original = try? await self.query(CommandIDs.queryGet, ["ref": .string(document.ref), "depth": 1])
                let originalHead = try? app.workspace.persistence.loadHead(document.documentID)
                let expectedPages = originalHead?.livePages.count
                    ?? app.services.library?.node(document.documentID)?.pageCount
                    ?? original?["pages"]?.arrayValue?.count
                guard ticket == self.generation else { return }
                try self.requireCleanRead(document.documentID, since: readSequence)
                guard !app.isReadOnly(document.documentID), !self.isDownloading(document.documentID) else {
                    throw NibError(.unavailable, String(localized: "Wait until the original is downloaded and readable before making a copy."))
                }
                let duplicated = try await app.bus.execute(CommandIDs.libraryDuplicate,
                                                           ["refs": [.string(document.ref)]], session: session)
                guard ticket == self.generation else { return }
                guard let ref = duplicated["refs"]?.arrayValue?.first?.stringValue,
                      case .document? = NodeRef(ref), ref != document.ref else {
                    throw NibError(.invariantViolation, String(localized: "The copy could not be identified."))
                }
                copyRef = ref
                self.verificationRef = ref
                let contents = try await self.query(CommandIDs.queryGet, ["ref": .string(ref), "depth": 1])
                guard ticket == self.generation else { return }
                guard case .object(let object) = contents, !object.isEmpty else {
                    throw NibError(.invariantViolation, String(localized: "No readable contents were returned for the copy."))
                }
                guard case .document(let copyID)? = NodeRef(ref), let expectedPages else {
                    throw NibError(.unavailable, String(localized: "The original's page count could not be checked."))
                }
                let copyHead = try app.workspace.persistence.loadHead(copyID)
                let missing = expectedPages - copyHead.livePages.count
                guard missing == 0 else {
                    throw NibError(.invariantViolation, missing > 0
                                   ? String(localized: "The copy is missing ^[\(missing) page](inflect: true).")
                                   : String(localized: "The copy's page count does not match the original."))
                }
                // Read every copied page, including iCloud-evicted pages; a nonempty query object is not verification.
                for (index, page) in copyHead.livePages.enumerated() {
                    let copiedItems = try app.workspace.persistence.loadItems(copyID, page: page.id).filter { !$0.deleted }
                    if let originalHead {
                        let originalPage = originalHead.livePages[index]
                        let originalItems = try app.workspace.persistence.loadItems(document.documentID, page: originalPage.id).filter { !$0.deleted }
                        guard copiedItems.count == originalItems.count else {
                            throw NibError(.invariantViolation, String(localized: "The copy's item count does not match the original on page \(index + 1)."))
                        }
                    }
                }
                try self.requireCleanRead(document.documentID, since: readSequence)
                try self.requireCleanRead(copyID, since: readSequence)
                self.receipt = originalHead == nil
                    ? String(localized: "Copy created. Its page count matches the catalogue, but the original could not be read. Open both to verify the contents.")
                    : String(localized: "Copy created and readable. Page and item counts match the original. Open it to verify the contents before removing the original.")
                await self.refresh()
            } catch {
                guard ticket == self.generation else { return }
                self.actionError = copyRef == nil ? NibError.wrap(error).message
                    : String(localized: "The copy was kept, but verification failed: \(NibError.wrap(error).message)")
            }
        }
    }

    private func requireCleanRead(_ doc: DocumentID, since sequence: UInt64) throws {
        if let state = statuses[doc]?["store"], state.state == "error",
           (sequences[Self.statusKey(source: "store", doc: doc)] ?? 0) > sequence {
            throw NibError(.unavailable, state.message ?? String(localized: "Some document files could not be read."))
        }
    }

}

@MainActor
struct ContainerLibraryBanner: View {
    let app: NibApp
    var body: some View {
        NibBanner(String(localized: "Your library is stored inside Nib and may be lost if you reinstall the app. Move or copy it to a folder outside Nib."),
                  action: NibAction(CloudStatusModel.shared(app).canCopyLibrary ? String(localized: "Copy Library…") : String(localized: "Move Library…"), command: CommandIDs.libraryRelocate) {
                      let model = CloudStatusModel.shared(app)
                      model.perform(CommandIDs.libraryRelocate, params: ["copy": .bool(model.canCopyLibrary)])
                  })
    }
}

@MainActor
struct CloudStatusButton: View {
    let app: NibApp
    let model: CloudStatusModel
    let compact: Bool
    var body: some View {
        Group {
            if compact {
                NibDropletButton(id: "syncui.statusButton", symbol: model.syncState.symbol,
                                 label: String(localized: "Cloud & Backup")) { open() }
            } else {
                NibDropletButton(id: "syncui.statusButton", title: String(localized: "Cloud & Backup"),
                                 symbol: model.syncState.symbol) { open() }
            }
        }
        .accessibilityIdentifier("cmd." + CommandIDs.panelOpen)
        .accessibilityValue(model.syncState.title)
        .onAppear { model.visibilityBegan() }
        .onDisappear { model.visibilityEnded() }
    }
    private func open() { app.perform(CommandIDs.panelOpen, ["id": .string(PanelIDs.cloudBackup)]) }
}

@MainActor
struct CloudStatusPanel: View {
    let context: PanelContext
    let model: CloudStatusModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var selectedDocumentID: DocumentID? {
        if let ref = context.params["doc"]?.stringValue, case .document(let doc)? = NodeRef(ref) { return doc }
        return context.session?.document
    }

    var body: some View {
        VStack(spacing: NibSpacing.m) {
            NibSheetHeader(String(localized: "Cloud & Backup"), cancelTitle: String(localized: "Close"), onCancel: {
                context.app.perform(CommandIDs.panelClose, ["id": .string(PanelIDs.cloudBackup)], session: context.session)
            })
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.xxl) {
                    if model.inContainer { ContainerLibraryBanner(app: context.app) }
                    if let doc = selectedDocumentID, context.app.isReadOnly(doc) {
                        NibBanner(String(localized: "This document is read-only. Update Nib if it was written by a newer version."))
                    }
                    if let error = model.actionError { NibBanner(error) }
                    if let receipt = model.receipt { NibBanner(receipt, style: .info) }
                    if let ref = model.verificationRef {
                        NibButton(String(localized: "Open Copy to Verify"), symbol: .notebook, kind: .plain) {
                            context.app.perform(CommandIDs.docOpen, ["doc": .string(ref)], session: context.session)
                        }
                        .accessibilityIdentifier("cmd." + CommandIDs.docOpen)
                    }
                    NibInspectorSection(String(localized: "Library")) {
                        NibRow(model.locationName, subtitle: model.provider, icon: .folder)
                        if let path = model.locationPath {
                            Text(path).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        NibTraceRow(model.syncState.message ?? model.syncState.title, phase: model.syncState.phase)
                        commandButton(String(localized: "Sync Now"), CommandIDs.syncNow, symbol: .syncing)
                        commandButton(String(localized: "Move Library…"), CommandIDs.libraryRelocate,
                                      params: ["copy": false], symbol: .folder)
                        if model.canCopyLibrary {
                            commandButton(String(localized: "Copy Library…"), CommandIDs.libraryRelocate,
                                          params: ["copy": true], symbol: .copy)
                        }
                    }
                    if let doc = selectedDocumentID {
                        NibInspectorSection(String(localized: "Document Sync")) {
                            let state = model.documentStatus(doc)
                            NibRow(context.app.services.library?.node(doc)?.title ?? String(localized: "Untitled Document"),
                                   subtitle: state.title, icon: state.symbol)
                            if let message = state.message {
                                Text(message).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if context.app.commands.entry(CommandIDs.webdavStatus) != nil {
                        NibInspectorSection(String(localized: "WebDAV")) {
                            serviceSummary(source: "webdav", snapshot: model.webdav, error: model.webdavError)
                            commandButton(String(localized: "Sync WebDAV Now"), CommandIDs.webdavSyncNow, symbol: .syncing)
                            settingsButton(owner: "webdav", title: String(localized: "Open WebDAV Settings"))
                        }
                    }
                    if context.app.commands.entry(CommandIDs.backupStatus) != nil {
                        NibInspectorSection(String(localized: "Backup")) {
                            serviceSummary(source: "backup", snapshot: model.backup, error: model.backupError)
                            commandButton(String(localized: "Back Up Now"), CommandIDs.backupNow, symbol: .backup)
                            settingsButton(owner: "backup", title: String(localized: "Open Backup Settings"))
                        }
                    }
                    if !model.attentionDocuments.isEmpty {
                        NibInspectorSection(String(localized: "Documents Needing Attention")) {
                            ForEach(model.attentionDocuments) { document in
                                VStack(alignment: .leading, spacing: NibSpacing.s) {
                                    NibRow(document.title, subtitle: document.readOnly
                                           ? String(localized: "Read-only. Update Nib to edit newer documents.")
                                           : model.documentStatus(document.documentID).message ?? model.documentStatus(document.documentID).title,
                                           icon: .syncError)
                                    NibButton(String(localized: "Duplicate and Verify"), symbol: .duplicate, kind: .plain) {
                                        model.duplicateAndVerify(document, session: context.session)
                                    }
                                    .disabled(model.busy || document.readOnly || document.locked ||
                                              model.isDownloading(document.documentID) ||
                                              context.app.commands.entry(CommandIDs.libraryDuplicate) == nil ||
                                              context.app.commands.entry(CommandIDs.queryGet) == nil)
                                    if document.locked { Text(String(localized: "Unlock this document before making a copy."))
                                            .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary) }
                                }
                            }
                        }
                    }
                    RepairToolsView(app: context.app, model: model, session: context.session, showMessages: false)
                }
                .padding(.horizontal, sizeClass == .compact ? NibSpacing.l : NibSpacing.xxl)
                .padding(.bottom, NibSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(NibColor.backgroundSecondary)
        .onAppear { model.visibilityBegan() }
        .onDisappear { model.visibilityEnded() }
        .accessibilityIdentifier("syncui.cloudBackup")
    }

    private func commandButton(_ title: String, _ command: String, params: JSONValue = [:], symbol: NibSymbol) -> some View {
        NibButton(title, symbol: symbol, kind: .plain) {
            model.perform(command, params: params, session: context.session)
        }
        .disabled(model.busy || context.app.commands.entry(command) == nil)
    }

    @ViewBuilder private func serviceSummary(source: String, snapshot: JSONValue?, error: String?) -> some View {
        if let error { NibBanner(error) }
        else if let state = model.serviceState(source) { NibTraceRow(state.message ?? state.title, phase: state.phase) }
        else if snapshot == nil { NibRow(String(localized: "Not available"), subtitle: String(localized: "Enable this feature in Settings.")) }
        else if !CloudStatusModel.errors(snapshot).isEmpty {
            NibRow(String(localized: "Needs attention"), icon: .warningTriangle)
        } else if snapshot?["running"]?.boolValue == true {
            NibTraceRow(String(localized: "Working…"), phase: .running)
        } else {
            NibRow(snapshot?["enabled"]?.boolValue == false || snapshot?["configured"]?.boolValue == false
                   ? String(localized: "Not configured") : String(localized: "Ready"))
        }
        if let pending = CloudStatusModel.pending(snapshot), pending > 0 {
            NibRow(source == "webdav"
                   ? String(localized: "^[\(pending) file](inflect: true) queued")
                   : String(localized: "^[\(pending) document](inflect: true) queued"))
        }
        if let date = snapshot?[source == "backup" ? "lastRun" : "lastSync"]?.doubleValue, date > 0 {
            NibRow(String(localized: "Last completed"), subtitle: Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .shortened))
        }
        ForEach(Array(CloudStatusModel.errors(snapshot).enumerated()), id: \.offset) { _, message in
            NibBanner(message)
        }
    }

    private func settingsButton(owner: String, title: String) -> some View {
        NibButton(title, symbol: .settings, kind: .plain) {
            let page = context.app.ui.settingsPages.all.first { $0.owner == owner }?.id
            let params: JSONValue = page.map { ["page": .string($0)] } ?? [:]
            context.app.perform(CommandIDs.settingsOpen, params, session: context.session)
        }
        .accessibilityIdentifier("cmd." + CommandIDs.settingsOpen)
        .disabled(context.app.commands.entry(CommandIDs.settingsOpen) == nil)
    }
}

@MainActor
struct RepairToolsView: View {
    let app: NibApp
    let model: CloudStatusModel
    var session: EditorSession? = nil
    var showMessages = true

    var body: some View {
        NibInspectorSection(String(localized: "Library Repair")) {
            Text(String(localized: "Rebuild the catalogue and re-merge package records. Your documents and undo history are kept."))
                .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NibButton(String(localized: "Repair Library"), symbol: .retry) {
                model.perform(CommandIDs.libraryRepair, session: session)
            }
            .accessibilityIdentifier("cmd." + CommandIDs.libraryRepair).disabled(model.busy)
            NibButton(String(localized: "Repair Library and Search Index"), symbol: .search, kind: .plain) {
                model.perform(CommandIDs.libraryRepair, params: ["rebuildIndex": true], session: session)
            }
            .accessibilityIdentifier("cmd." + CommandIDs.libraryRepair).disabled(model.busy || app.commands.entry(CommandIDs.indexRebuild) == nil)
            if model.busy { NibTraceRow(String(localized: "Working…"), phase: .running) }
            if showMessages {
                if let error = model.actionError { NibBanner(error) }
                if let receipt = model.receipt { NibBanner(receipt, style: .info) }
            }
        }
    }
}
