import SwiftUI
import NibContracts

/// Settings are an opaque native form; the core module deliberately has no dependency on NibDesign.
@MainActor
struct RelaySettingsPage: View {
    let app: NibApp
    @State private var url = ""
    @State private var token = ""
    @State private var replaceToken = false
    @State private var hasToken = false
    @State private var saving = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Relay URL"), text: $url,
                          prompt: Text("wss://relay.example.com/"))
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(String(localized: "Relay URL"))
                    .disabled(saving)
                    .onChange(of: url) { _, value in
                        hasToken = app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self)?.hasToken(for: value) ?? false
                        message = ""
                    }
            } header: { Text(String(localized: "Internet collaboration")) }
              footer: { Text(String(localized: "Connect to your own relay for live editing with up to 50 people. Leave the URL empty to disable the relay. Use folder sync for larger groups.")) }
            Section {
                SecureField(String(localized: "Shared token"), text: Binding(
                    get: { token }, set: { token = $0; replaceToken = true; message = "" }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(saving)
                if hasToken {
                    Text(String(localized: "A token is saved on this device. Leave this field untouched to keep it."))
                    Button(String(localized: "Clear saved token"), role: .destructive) {
                        token = ""; replaceToken = true
                    }
                    .disabled(saving)
                }
            } header: { Text(String(localized: "Credentials")) }
              footer: { Text(String(localized: "Tokens stay in this device's Keychain. Plugins and AI cannot read or enter them. Use wss:// when connecting over the public internet.")) }
            Section {
                Button(String(localized: "Save relay settings")) { Task { await save() } }
                    .disabled(saving)
                if saving { ProgressView(String(localized: "Saving")) }
                if !message.isEmpty { Text(message).accessibilityLabel(message) }
            }
        }
        .navigationTitle(String(localized: "Collaboration Relay"))
        .task { await load() }
    }

    private func load() async {
        do {
            let result = try await app.bus.execute(Invocation(command: CommandIDs.settingsGet,
                params: ["name": .string(RelayRuntime.urlKey.name)]))
            url = result.value["value"]?.stringValue ?? ""
            hasToken = app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self)?.hasToken(for: url) ?? false
        } catch { message = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            guard let runtime = app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self) else {
                throw NibError.unavailable("relay")
            }
            try await runtime.saveFromSettings(url: url, token: replaceToken ? token : nil)
            token = ""; replaceToken = false
            await load()
            message = String(localized: "Relay settings saved.")
        } catch { message = error.localizedDescription }
    }
}
