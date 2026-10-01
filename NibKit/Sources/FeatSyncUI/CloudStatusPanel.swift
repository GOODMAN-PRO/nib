import Foundation
import Observation
import SwiftUI
import NibContracts
import NibDesign

struct CloudSyncState: Equatable {
    var state: String
    var message: String?
    var files: [String]

    init(_ payload: SyncStatusPayload) {
        state = payload.state
        message = payload.message
        files = payload.files ?? []
    }

    var needsAttention: Bool { state == "error" || state == "warning" }
    var running: Bool { ["checking", "syncing", "downloading"].contains(state) }
    var title: String {
        switch state {
        case "checking": return String(localized: "Checking for changes…")
        case "syncing": return String(localized: "Syncing…")
        case "downloading": return files.isEmpty ? String(localized: "Downloading…") : String(localized: "Downloading \(files.count) files…")
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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var querySequence = 0
    @ObservationIgnored private var sequences: [String: UInt64] = [:]
    private var rootSequence: UInt64 = 0
    private var statuses: [String: CloudSyncState] = [:]
    var documents: [CloudDocument] = []
    var locationName = String(localized: "Library location unavailable")
    var locationPath: String?
    var provider = String(localized: "Files")
    var inContainer = false
    var backup: JSONValue?
    var webdav: JSONValue?
    var backupError: String?
    var webdavError: String?
    var queryError: String?
    var actionError: String?
    var receipt: String?
    var verificationRef: String?
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
        if event.type == NibEventType.libraryChanged, event.payload?["root"]?.boolValue == true {
            guard event.seq > rootSequence else { return }
            rootSequence = event.seq
            generation += 1
            statuses.removeAll()
            sequences.removeAll()
            documents.removeAll()
            backup = nil
            webdav = nil
            verificationRef = nil
            receipt = nil
        }
        guard event.seq >= rootSequence else { return }
        if let payload = event.decode(SyncStatusPayload.self) {
            let key = Self.statusKey(source: payload.source, doc: event.doc)
            guard event.seq > (sequences[key] ?? 0) else { return }
            sequences[key] = event.seq
            statuses[key] = CloudSyncState(payload)
            app?.ui.setNeedsChromeUpdate()
        }
        if event.type == NibEventType.libraryChanged {
            inContainer = app?.services.get("library.inContainer", as: NSNumber.self)?.boolValue ?? false
            app?.ui.setNeedsChromeUpdate()
        }
        if scheduleQueries, [NibEventType.libraryChanged, NibEventType.backupStatus,
                             NibEventType.syncStatus, NibEventType.docOpened].contains(event.type) {
            requestRefresh()
        }
    }

    static func statusKey(source: String, doc: DocumentID?) -> String { source + ":" + (doc?.raw ?? "") }

    var syncState: CloudSyncState {
        let states = statuses.filter { !$0.key.hasPrefix("backup:") && !$0.key.hasPrefix("webdav:") }.values
        let winner = states.max { $0.rank < $1.rank }
        let downloads = states.filter { $0.state == "downloading" }.flatMap(\.files)
        if let winner, winner.state == "downloading" {
            var result = winner
            result.files = downloads
            return result
        }
        return winner ?? CloudSyncState(SyncStatusPayload(state: "unknown", source: "sync"))
    }

    func documentStatus(_ doc: DocumentID) -> CloudSyncState {
        let suffix = ":" + doc.raw
        let states = statuses.filter { $0.key.hasSuffix(suffix) }.values
        if let result = states.max(by: { $0.rank < $1.rank }) { return result }
        let badge = documents.first { $0.documentID == doc }?.badge ?? "unknown"
        return CloudSyncState(SyncStatusPayload(state: badge, source: "catalog"))
    }

    var attentionDocuments: [CloudDocument] {
        var all = documents
        // A failed package might not be in the current catalogue. Preserve its repair row and its stable ref.
        for key in statuses.keys {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let raw = String(key[key.index(after: separator)...])
            guard !raw.isEmpty, let state = statuses[key], state.needsAttention,
                  !all.contains(where: { $0.documentID.raw == raw }) else { continue }
            let doc = DocumentID(raw)
            all.append(CloudDocument(ref: NodeRef.document(doc).description,
                                     title: String(localized: "Document \(raw)"), badge: "error",
                                     readOnly: app?.isReadOnly(doc) ?? false, locked: false))
        }
        return all.filter { $0.readOnly || $0.badge == "error" || documentStatus($0.documentID).needsAttention }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func requestRefresh() {
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.refreshRequested && !Task.isCancelled {
                self.refreshRequested = false
                await self.refresh()
            }
            self.refreshTask = nil
        }
    }

    func query(_ id: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        guard let app else { throw NibError.unavailable("the app") }
        return try await app.bus.execute(Invocation(command: id, params: params, readOnly: true)).value
    }

    func refresh() async {
        guard let app else { return }
        let ticket = generation
        querySequence += 1
        let request = querySequence
        let root = app.services.library?.rootURL
        loading = true
        defer { if request == querySequence { loading = false } }
        var rows: [CloudDocument] = []
        var listError: String?
        do {
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params: [String: JSONValue] = ["recursive": true, "limit": 1000]
                if let cursor { params["cursor"] = .string(cursor) }
                let value = try await query(CommandIDs.libraryList, .object(params))
                for node in value["nodes"]?.arrayValue ?? [] {
                    guard let ref = node["ref"]?.stringValue, case .document(let doc)? = NodeRef(ref) else { continue }
                    rows.append(CloudDocument(ref: ref, title: node["title"]?.stringValue ?? String(localized: "Untitled Document"),
                                              badge: node["sync"]?.stringValue ?? "unknown", readOnly: app.isReadOnly(doc),
                                              locked: node["locked"]?.boolValue ?? false))
                }
                cursor = value["cursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted {
                    throw NibError(.invariantViolation, "library.list repeated a cursor")
                }
            } while cursor != nil
        } catch { listError = NibError.wrap(error).message }
        let location = try? await query(CommandIDs.libraryLocations)
        var newBackup: JSONValue?
        var newWebdav: JSONValue?
        var newBackupError: String?
        var newWebdavError: String?
        if app.commands.entry(CommandIDs.backupStatus) != nil {
            do { newBackup = try await query(CommandIDs.backupStatus) }
            catch { newBackupError = NibError.wrap(error).message }
        }
        if app.commands.entry(CommandIDs.webdavStatus) != nil {
            do { newWebdav = try await query(CommandIDs.webdavStatus) }
            catch { newWebdavError = NibError.wrap(error).message }
        }
        guard ticket == generation, request == querySequence, root == app.services.library?.rootURL else { return }
        documents = rows
        queryError = listError
        backup = newBackup
        webdav = newWebdav
        backupError = newBackupError
        webdavError = newWebdavError
        inContainer = app.services.get("library.inContainer", as: NSNumber.self)?.boolValue ?? false
        if let current = location?["locations"]?.arrayValue?.first(where: { $0["current"]?.boolValue == true }) {
            locationName = current["name"]?.stringValue ?? String(localized: "Library")
            locationPath = current["path"]?.stringValue
            provider = Self.providerName(current["provider"]?.stringValue)
        } else {
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

    func serviceState(_ source: String) -> CloudSyncState? { statuses[source + ":"] }

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
                    self.receipt = report.errors.isEmpty
                        ? String(localized: "Catalogue rebuilt. \(report.merged) records merged.")
                        : String(localized: "Catalogue rebuilt. \(report.errors.count) documents still need attention.")
                }
                await self.refresh()
            } catch { if ticket == self.generation { self.actionError = NibError.wrap(error).message } }
        }
    }

    /// The duplicate is preserved even if verification fails, and the original is never removed.
    /// Opening the copy lets the user check its pages before deciding what to keep.
    func duplicateAndVerify(_ document: CloudDocument, session: EditorSession?) {
        guard !busy, let app else { return }
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
                self.receipt = String(localized: "Copy created and readable. Open it to verify the contents before removing the original.")
                await self.refresh()
            } catch {
                guard ticket == self.generation else { return }
                self.actionError = copyRef == nil ? NibError.wrap(error).message
                    : String(localized: "The copy was kept, but verification failed: \(NibError.wrap(error).message)")
            }
        }
    }
}

@MainActor
struct ContainerLibraryBanner: View {
    let app: NibApp
    var body: some View {
        NibBanner(String(localized: "Your library is inside Nib. Reinstalling with another signer can delete it. Move it to a folder outside the app."),
                  action: NibAction(String(localized: "Move Library…")) {
                      app.perform(CommandIDs.libraryRelocate, ["copy": false])
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
        .accessibilityValue(model.syncState.title)
        .task { await model.refresh() }
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
                    if let error = model.actionError ?? model.queryError { NibBanner(error) }
                    if let receipt = model.receipt { NibBanner(receipt, style: .info) }
                    if let ref = model.verificationRef {
                        NibButton(String(localized: "Open Copy to Verify"), symbol: .notebook, kind: .plain) {
                            context.app.perform(CommandIDs.docOpen, ["doc": .string(ref)], session: context.session)
                        }
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
                    }
                    if let doc = selectedDocumentID {
                        NibInspectorSection(String(localized: "Document Sync")) {
                            let state = model.documentStatus(doc)
                            NibRow(model.documents.first { $0.documentID == doc }?.title ?? String(localized: "Document"),
                                   subtitle: state.title, icon: state.symbol)
                            if let message = state.message {
                                Text(message).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    NibInspectorSection(String(localized: "WebDAV")) {
                        serviceSummary(source: "webdav", snapshot: model.webdav, error: model.webdavError)
                        commandButton(String(localized: "Sync WebDAV Now"), CommandIDs.webdavSyncNow, symbol: .syncing)
                        settingsButton(owner: "webdav", title: String(localized: "WebDAV Settings"))
                    }
                    NibInspectorSection(String(localized: "Backup")) {
                        serviceSummary(source: "backup", snapshot: model.backup, error: model.backupError)
                        commandButton(String(localized: "Back Up Now"), CommandIDs.backupNow, symbol: .share)
                        settingsButton(owner: "backup", title: String(localized: "Backup Settings"))
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
        .task { await model.refresh() }
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
        if let pending = CloudStatusModel.pending(snapshot) {
            NibRow(String(localized: "\(pending) documents queued"))
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
            }.disabled(model.busy)
            NibButton(String(localized: "Repair Library and Search Index"), symbol: .search, kind: .plain) {
                model.perform(CommandIDs.libraryRepair, params: ["rebuildIndex": true], session: session)
            }.disabled(model.busy || app.commands.entry(CommandIDs.indexRebuild) == nil)
            if model.busy { NibTraceRow(String(localized: "Working…"), phase: .running) }
            if showMessages {
                if let error = model.actionError { NibBanner(error) }
                if let receipt = model.receipt { NibBanner(receipt, style: .info) }
            }
        }
    }
}
