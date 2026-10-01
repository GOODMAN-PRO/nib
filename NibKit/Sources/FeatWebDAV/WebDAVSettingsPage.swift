import Foundation
import SwiftUI
import NibContracts

/// Settings › Sync › WebDAV: server address, user name, password (Keychain), library folder, untrusted
/// certificates, Save and Test (webdav.configure + webdav.status {check}), sync status and Sync Now
/// (webdav.syncNow), Disconnect (webdav.configure with an empty url).
struct WebDAVSettingsPage: View {
    @StateObject private var model: WebDAVSettingsModel
    @State private var confirmDisconnect = false

    init(app: NibApp) {
        _model = StateObject(wrappedValue: WebDAVSettingsModel(app: app))
    }

    var body: some View {
        Form {
            if model.status?.credentialsMissing == true {
                Section {
                    Label(String(localized: "Credentials missing — re-enter the password below."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityAddTraits(.isStaticText)
                }
            } else if model.status?.authFailed == true {
                Section {
                    Label(String(localized: "The server rejected the password. Automatic sync is paused until you re-enter it below."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            serverSection
            actionSection
            if model.savedConfigured {
                syncSection
                Section {
                    Button(String(localized: "Disconnect"), role: .destructive) { confirmDisconnect = true }
                        .disabled(model.isWorking)
                }
            }
        }
        .confirmationDialog(String(localized: "Disconnect from the WebDAV server?"), isPresented: $confirmDisconnect,
                            titleVisibility: .visible) {
            Button(String(localized: "Disconnect"), role: .destructive) { Task { await model.disconnect() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Sync stops and the password is removed from this device. Files on the server and in the library stay as they are."))
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var serverSection: some View {
        Section {
            TextField(String(localized: "Server address"), text: $model.url,
                      prompt: Text(verbatim: "https://dav.example.com/remote.php/dav/files/alex/"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(String(localized: "Server address"))
            TextField(String(localized: "User name"), text: $model.user)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(String(localized: "User name"))
            SecureField(String(localized: "Password"), text: $model.password,
                        prompt: Text(model.hasSavedPassword ? String(localized: "Saved in the Keychain")
                                                            : String(localized: "Password")))
                .textContentType(.password)
                .accessibilityLabel(String(localized: "Password"))
            TextField(String(localized: "Folder on the server"), text: $model.folder, prompt: Text(verbatim: "Nib"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(String(localized: "Folder on the server"))
            Toggle(String(localized: "Allow Untrusted Certificates"), isOn: $model.allowUntrusted)
        } header: {
            Text(String(localized: "Server"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Nextcloud, ownCloud, a NAS or any WebDAV server. The library is mirrored into the folder; the password stays in this device's Keychain."))
                if model.isPlainHTTP {
                    Text(String(localized: "This address uses http, so the password is sent unencrypted."))
                        .foregroundStyle(.orange)
                }
                if model.allowUntrusted {
                    Text(String(localized: "Only allow untrusted certificates for a server you run yourself (a self-signed certificate)."))
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await model.saveAndTest() }
            } label: {
                HStack {
                    Text(model.isDirty ? String(localized: "Save and Test") : String(localized: "Test Connection"))
                    Spacer()
                    if model.working == .saving || model.working == .testing { ProgressView() }
                }
            }
            .disabled(model.isWorking || model.url.trimmingCharacters(in: .whitespaces).isEmpty)
            if let check = model.testResult {
                Label(check.message, systemImage: check.ok ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(check.ok ? Color.green : Color.red)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var syncSection: some View {
        Section {
            LabeledContent(String(localized: "Status"), value: model.statusText)
            if let last = model.status?.lastSync {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    LabeledContent(String(localized: "Last Sync"),
                                   value: Date(timeIntervalSince1970: last).formatted(.relative(presentation: .named)))
                }
            }
            if let pending = model.status?.pending, pending > 0 {
                LabeledContent(String(localized: "Waiting"), value: String(localized: "\(pending) file(s)"))
            }
            if let result = model.status?.lastResult, result.skippedLocked > 0 {
                Text(String(localized: "\(result.skippedLocked) file(s) of locked notebooks wait until they are unlocked."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array((model.status?.errors ?? []).prefix(5).enumerated()), id: \.offset) { _, message in
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.syncNow() }
            } label: {
                HStack {
                    Text(String(localized: "Sync Now"))
                    Spacer()
                    if model.working == .syncing || model.status?.running == true { ProgressView() }
                }
            }
            .disabled(model.isWorking || model.status?.credentialsMissing == true)
        } header: {
            Text(String(localized: "Sync"))
        } footer: {
            Text(String(localized: "Nib syncs when it opens, every minute while it is open, and in the background when iOS allows. Each device writes its own files, so edits from several devices never overwrite each other."))
        }
    }
}

/// State of the WebDAV settings page. Every change runs a command as the user; only the password is written
/// straight to the Keychain (it is never a command parameter).
@MainActor
final class WebDAVSettingsModel: ObservableObject {
    enum Work: Equatable { case saving, testing, syncing }

    struct Fields: Equatable {
        var url = ""
        var user = ""
        var folder = WebDAVSettings.folder.defaultValue
        var allowUntrusted = false
    }

    let app: NibApp
    @Published var url = ""
    @Published var user = ""
    @Published var password = ""
    @Published var folder = WebDAVSettings.folder.defaultValue
    @Published var allowUntrusted = false
    @Published private(set) var status: WebDAVStatusInfo?
    @Published private(set) var testResult: WebDAVConnectionCheck?
    @Published private(set) var working: Work?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSavedPassword = false
    private var saved = Fields()
    private var subscription: EventSubscription?
    private var polling: Task<Void, Never>?

    init(app: NibApp) {
        self.app = app
        loadFields()
    }

    var fields: Fields {
        Fields(url: url.trimmingCharacters(in: .whitespacesAndNewlines),
               user: user.trimmingCharacters(in: .whitespacesAndNewlines),
               folder: folder.trimmingCharacters(in: .whitespacesAndNewlines), allowUntrusted: allowUntrusted)
    }

    var isDirty: Bool { fields != saved || !password.isEmpty }
    var isWorking: Bool { working != nil }
    var savedConfigured: Bool { !saved.url.isEmpty }
    var isPlainHTTP: Bool { url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") }

    var statusText: String {
        guard let s = status else { return "" }
        switch s.state {
        case "syncing": return String(localized: "Syncing…")
        case "ok": return s.message ?? String(localized: "Up to date")
        case "warning", "error": return s.message ?? String(localized: "Needs attention")
        case "unconfigured": return String(localized: "Not set up")
        default: return String(localized: "Not synced yet")
        }
    }

    func loadFields() {
        let v = WebDAVSettings.read(app.settings)
        saved = Fields(url: v.url, user: v.user, folder: v.folder, allowUntrusted: v.allowUntrustedCertificates)
        url = v.url
        user = v.user
        folder = v.folder
        allowUntrusted = v.allowUntrustedCertificates
        hasSavedPassword = WebDAVCredentials.password(url: v.url, user: v.user) != nil
    }

    func appear() {
        if subscription == nil {
            subscription = app.events.subscribe { [weak self] event in
                guard event.decode(SyncStatusPayload.self)?.source == "webdav" else { return }
                Task { @MainActor in await self?.refreshStatus() }
            }
        }
        Task { await refreshStatus() }
    }

    func disappear() {
        subscription?.cancel()
        subscription = nil
        polling?.cancel()
        polling = nil
    }

    func refreshStatus() async {
        status = try? await app.bus.run(WebDAVStatusCommand.self, .init(check: nil))
        // While a pass runs, follow its pending count.
        if status?.running == true, polling == nil {
            polling = Task { @MainActor [weak self] in
                while let self = self, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.status = try? await self.app.bus.run(WebDAVStatusCommand.self, .init(check: nil))
                    if self.status?.running != true { break }
                }
                self?.polling = nil
            }
        }
    }

    /// Stores the password (if typed) for the new server and user, then runs `webdav.configure`.
    func save() async -> Bool {
        errorMessage = nil
        testResult = nil
        working = .saving
        defer { working = nil }
        let f = fields
        do {
            let server = try WebDAVConfiguration.normalizeServerURL(f.url).absoluteString
            if !password.isEmpty {
                WebDAVCredentials.setPassword(password, url: server, user: f.user)
            } else if server != saved.url || f.user != saved.user,
                      WebDAVCredentials.password(url: server, user: f.user) == nil,
                      let previous = WebDAVCredentials.password(url: saved.url, user: saved.user) {
                // The user edited the address or name of the same account without retyping the password.
                WebDAVCredentials.setPassword(previous, url: server, user: f.user)
            }
            _ = try await app.bus.run(WebDAVConfigureCommand.self,
                                      .init(url: server, user: f.user, folder: f.folder.isEmpty ? "Nib" : f.folder,
                                            allowUntrustedCertificates: f.allowUntrusted))
            password = ""
            loadFields()
            await refreshStatus()
            return true
        } catch {
            errorMessage = NibError.wrap(error).message
            return false
        }
    }

    func saveAndTest() async {
        if isDirty {
            guard await save() else { return }
        }
        working = .testing
        defer { working = nil }
        do {
            let checked = try await app.bus.run(WebDAVStatusCommand.self, .init(check: true))
            status = checked
            testResult = checked.connection
        } catch {
            errorMessage = NibError.wrap(error).message
        }
    }

    func syncNow() async {
        errorMessage = nil
        working = .syncing
        defer { working = nil }
        do {
            _ = try await app.bus.run(WebDAVSyncNowCommand.self, .init())
        } catch {
            errorMessage = NibError.wrap(error).message
        }
        await refreshStatus()
    }

    func disconnect() async {
        errorMessage = nil
        testResult = nil
        do {
            _ = try await app.bus.run(WebDAVConfigureCommand.self,
                                      .init(url: "", user: "", folder: WebDAVSettings.folder.defaultValue,
                                            allowUntrustedCertificates: nil))
        } catch {
            errorMessage = NibError.wrap(error).message
        }
        password = ""
        loadFields()
        await refreshStatus()
    }
}
