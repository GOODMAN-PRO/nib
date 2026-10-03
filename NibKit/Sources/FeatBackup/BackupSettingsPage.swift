import SwiftUI
import NibContracts
import NibDesign

/// Settings stay opaque and quiet; NibToggle is the only liquid surface on this page (DESIGN.md §14.8).
struct BackupSettingsPage: View {
    @StateObject private var model: BackupSettingsModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp) { _model = StateObject(wrappedValue: BackupSettingsModel(app: app)) }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Destination"), selection: $model.destination) {
                    Text(String(localized: "Off")).tag("none")
                    Text(String(localized: "Files folder")).tag("folder")
                    Text(String(localized: "WebDAV")).tag("webdav")
                }
                .font(NibFont.body)
                .frame(minHeight: NibMetrics.hitTarget)
                if model.destination == "folder" {
                    NibRow(String(localized: "Files folder"), subtitle: model.status?.folderName.isEmpty == false ? model.status?.folderName : String(localized: "Choose a folder to grant access on this device"), icon: .folder) {
                        NibButton(String(localized: "Choose Folder"), kind: .plain) { model.send(CommandIDs.backupChooseFolder) }
                        .accessibilityIdentifier("cmd." + CommandIDs.backupChooseFolder)
                    }
                }
                if model.destination != "none" {
                    NibField(text: $model.folder, prompt: String(localized: "Backup subfolder"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(String(localized: "Backup subfolder"))
                }
            } header: { Text(String(localized: "Automatic backup")) } footer: {
                Text(String(localized: "Files folders work with Google Drive, Dropbox, OneDrive and iCloud Drive. Choose a destination outside your library. WebDAV uses your saved server settings."))
                    .font(NibFont.footnote)
            }

            Section {
                Picker(String(localized: "Format"), selection: $model.format) {
                    Text(String(localized: "Nib document")).tag("nib")
                    Text(String(localized: "PDF")).tag("pdf")
                    Text(String(localized: "Both")).tag("both")
                }
                .font(NibFont.body)
                .frame(minHeight: NibMetrics.hitTarget)
                NibToggle(String(localized: "Increase Frequency"), isOn: $model.frequent)
                NibField(text: $model.exclusions, prompt: String(localized: "Excluded file names, one per line"), lines: 2...6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(String(localized: "Excluded file name substrings, one per line"))
            } header: { Text(String(localized: "Backup options")) } footer: {
                Text(String(localized: "Normally every 12 hours; Increase Frequency uses about 90 seconds while Nib is open. iOS decides when background work runs. Names containing an excluded phrase are skipped. Locked documents are skipped. Favourites, outline edits and deletions do not trigger a backup."))
                    .font(NibFont.footnote)
            }

            Section {
                NibButton(String(localized: "Save Backup Settings"), kind: .primary, expands: sizeClass == .compact) { model.save() }
                    .disabled(model.status?.running == true || (model.destination == "folder" && model.status?.folderChosen != true))
                NibButton(String(localized: "Back Up Now"), kind: .plain, expands: sizeClass == .compact) { model.send(CommandIDs.backupNow) }
                .accessibilityIdentifier("cmd." + CommandIDs.backupNow)
                    .disabled(model.status?.running == true || model.status?.configuration.destination.kind == "none")
                if let status = model.status {
                    NibRow(String(localized: "Pending documents")) {
                        Text(status.queued, format: .number).font(NibFont.body).foregroundStyle(NibColor.labelSecondary)
                    }
                    if status.running && !status.manual {
                        NibProgressBar(value: status.progress).accessibilityLabel(String(localized: "Backup progress"))
                        Text(String(localized: "Keep Nib open until the backup finishes.")).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                    }
                    if let date = status.lastSuccess {
                        NibRow(String(localized: "Last automatic backup")) {
                            Text(Date(timeIntervalSince1970: date), style: .relative).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                        }
                    }
                    if let error = status.error { NibBanner(error, style: .warning) }
                    else if !status.running, status.state == "ok" { Text(String(localized: "Backup complete")).font(NibFont.body).foregroundStyle(NibColor.labelSecondary) }
                    NibButton(String(localized: "Clear Pending Backups"), kind: .plain) { model.send(CommandIDs.backupClearQueue) }
                    .accessibilityIdentifier("cmd." + CommandIDs.backupClearQueue)
                        .disabled(status.queued == 0 && status.error == nil)
                }
                if let error = model.error { NibBanner(error, style: .warning) }
            } header: { Text(String(localized: "This device")) } footer: {
                Text(String(localized: "Each device has its own queue. Clearing it keeps saved backup files. Low Power Mode and high device temperatures defer automatic work."))
                    .font(NibFont.footnote)
            }

            Section {
                NibButton(String(localized: "Create Library Backup"), symbol: .backup, kind: .plain, expands: sizeClass == .compact) {
                    model.send(CommandIDs.backupManual)
                }
                .accessibilityIdentifier("cmd." + CommandIDs.backupManual).disabled(model.status?.running == true)
                if let status = model.status, status.running && status.manual {
                    NibProgressBar(value: status.progress).accessibilityLabel(String(localized: "Manual backup progress"))
                    Text(String(localized: "Keep Nib open until the backup finishes.")).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                }
                NibButton(String(localized: "Restore from ZIP"), kind: .plain) { model.send(CommandIDs.importPick) }
                .accessibilityIdentifier("cmd." + CommandIDs.importPick)
                    .disabled(model.status?.running == true)
            } header: { Text(String(localized: "Manual backup and restore")) } footer: {
                Text(String(localized: "Create a ZIP of your library without caches or locked documents, then save it to Files. Keep Nib in the foreground. An interrupted manual backup restarts from the beginning. Restore imports the ZIP through the library importer. After reinstalling, reopen your existing library folder or import your backup."))
                    .font(NibFont.footnote)
            }
        }
        .tint(NibColor.accent)
        .foregroundStyle(NibColor.label)
        .scrollContentBackground(.hidden)
        .background(NibColor.backgroundSecondary)
        .navigationTitle(String(localized: "Backup"))
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}

@MainActor
final class BackupSettingsModel: ObservableObject {
    let app: NibApp
    @Published var destination = "none"
    @Published var format = "nib"
    @Published var folder = "Nib Backups"
    @Published var exclusions = ""
    @Published var frequent = false
    @Published var status: BackupStatusInfo?
    @Published var error: String?
    private var subscription: EventSubscription?
    private var refreshing = false
    private var refreshAgain = false
    private var lastConfiguration: BackupConfiguration?

    init(app: NibApp) { self.app = app }
    func start() async {
        if subscription == nil {
            subscription = app.events.subscribe { [weak self] event in
                guard event.type == NibEventType.backupStatus else { return }
                Task { @MainActor in await self?.refresh() }
            }
        }
        await refresh()
    }
    func stop() { subscription?.cancel(); subscription = nil }
    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                let result = try await app.bus.execute(CommandIDs.backupStatus)
                let value = try result.decode(BackupStatusInfo.self)
                status = value; error = nil
                if lastConfiguration != value.configuration {
                    lastConfiguration = value.configuration
                    destination = value.configuration.destination.kind; format = value.configuration.format
                    folder = value.configuration.folder; exclusions = value.configuration.exclusions.joined(separator: "\n")
                    frequent = value.configuration.frequent
                }
            } catch { self.error = NibError.wrap(error).message }
        } while refreshAgain
    }
    func send(_ command: String, _ params: JSONValue = [:]) { app.perform(command, params) }
    func save() {
        let terms = exclusions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let params = BackupConfigure.Params(destination: BackupDestination(kind: destination), format: format,
                                             folder: folder, exclusions: terms, frequent: frequent)
        do { send(CommandIDs.backupConfigure, try JSONValue.from(params)) }
        catch { self.error = NibError.wrap(error).message }
    }
}
