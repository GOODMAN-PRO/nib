import Foundation
import SwiftUI
import Network
import Combine
import NibContracts
import NibDesign

struct AgentPairing: Equatable {
    let url: URL
    let token: String
    static func parse(_ text: String) throws -> AgentPairing {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "nib", c.host == "agent", c.path == "/pair", c.fragment == nil,
              let items = c.queryItems, Set(items.map(\.name)).count == items.count,
              let host = items.first(where: { $0.name == "host" })?.value,
              let portText = items.first(where: { $0.name == "port" })?.value,
              let port = Int(portText), (1...65535).contains(port),
              let token = items.first(where: { $0.name == "token" })?.value, validToken(token) else {
            throw NibError.invalid("Paste the complete pairing string printed by Nib Agent on your Mac.", path: "$.pairing")
        }
        var url = URLComponents(); url.scheme = "http"; url.host = host; url.port = port; url.path = "/"
        guard let endpoint = url.url, !host.isEmpty, !host.contains("/"), !host.contains("@") else {
            throw NibError.invalid("The pairing address is invalid. Copy it from Nib Agent again.", path: "$.pairing")
        }
        return AgentPairing(url: endpoint, token: token)
    }
    static func validToken(_ token: String) -> Bool {
        token.range(of: "^nib_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
}

@MainActor
final class AgentDiscovery: NSObject, ObservableObject, NetServiceDelegate {
    struct Found: Identifiable { let id: String; let name: String; let url: URL }
    @Published var agents: [Found] = []
    @Published var hint: String?
    private var browser: NWBrowser?
    private var resolving: [NetService] = []
    private let allowsDiscovery: Bool
    private let makeBrowser: () -> NWBrowser?

    init(isFixture: Bool = NibUITestMode.isEnabled, isHostlessTest: Bool? = nil,
         makeBrowser: @escaping () -> NWBrowser? = {
             NWBrowser(for: .bonjour(type: "_nib-agent._tcp", domain: nil), using: .tcp)
         }) {
        allowsDiscovery = !isFixture && !(isHostlessTest ?? NibApp.isHostlessTest)
        self.makeBrowser = makeBrowser
        super.init()
    }
    static func endpoint(host: String, port: Int) -> URL? {
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        var c = URLComponents(); c.scheme = "http"; c.host = host; c.port = port; c.path = "/"
        return c.url
    }
    func start() {
        guard browser == nil, allowsDiscovery, let browser = makeBrowser() else { return }
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browser != nil else { return }
                self.resolving.forEach { $0.stop() }; self.resolving = []; self.agents = []
                for result in results {
                    guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
                    let service = NetService(domain: domain, type: type, name: name)
                    service.delegate = self; self.resolving.append(service); service.resolve(withTimeout: 5)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .waiting = state { Task { @MainActor in self?.hint = String(localized: "Allow Local Network access in Settings, or paste the Mac’s pairing string.") } }
        }
        browser.start(queue: .main)
    }
    func stop() { browser?.cancel(); browser = nil; resolving.forEach { $0.stop() }; resolving = [] }
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        let port = sender.port, name = sender.name
        Task { @MainActor in
            guard let url = Self.endpoint(host: host, port: port), browser != nil else { return }
            agents.removeAll { $0.id == name }
            agents.append(Found(id: name, name: name, url: url))
        }
    }
}

@MainActor
struct SubscriptionSetupView: View {
    let app: NibApp
    let preset: ProviderPreset
    @State private var current: AIProviderConfig?
    @State private var deleteArmed = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = AgentDiscovery()
    @State private var pairing = ""
    @State private var address = ""
    @State private var token = ""
    @State private var model = "claude-sonnet"
    @State private var bridgeHost = ""
    @State private var busy = false
    @State private var message: String?
    @State private var saved = false
    init(app: NibApp, preset: ProviderPreset, existing: AIProviderConfig? = nil) {
        self.app = app; self.preset = preset; _current = State(initialValue: existing)
        _address = State(initialValue: existing?.baseURL.absoluteString ?? "")
        _model = State(initialValue: existing?.model ?? (preset == .chatGPTSubscription ? "chatgpt" : "claude-sonnet"))
        _bridgeHost = State(initialValue: existing?.extraHeaders["X-Nib-Bridge-Host"] ?? "")
    }
    var body: some View {
        Form {
            Section {
                Text(String(localized: "Run Nib Agent on your Mac, then paste its pairing string here. It uses your existing Claude Code or Codex login. No API key is needed."))
                NibSecureField(text: $pairing, prompt: String(localized: "Pairing string"))
                NibButton(String(localized: "Use pairing string"), kind: .plain) {
                    do { let value = try AgentPairing.parse(pairing); address = value.url.absoluteString; token = value.token; pairing = ""; message = nil }
                    catch { message = NibError.wrap(error).message }
                }.disabled(pairing.isEmpty)
            } header: { AISettingsHeader(String(localized: "Connect your Mac")) }
            Section {
                ForEach(discovery.agents) { agent in
                    NibButton(agent.name, symbol: .network, kind: .plain) { address = agent.url.absoluteString }
                }
                if discovery.agents.isEmpty { Text(String(localized: "Looking for Nib Agent on your network…")).font(NibFont.footnote) }
                if let hint = discovery.hint { Text(hint).font(NibFont.footnote) }
                NibField(text: $address, prompt: String(localized: "Mac address, e.g. http://192.168.1.20:7332/"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                NibSecureField(text: $token, prompt: String(localized: "Pairing token"))
                if current != nil { Text(String(localized: "Leave the token empty to keep the saved pairing.")).font(NibFont.footnote) }
            } header: { AISettingsHeader(String(localized: "Mac and token")) }
            if preset == .claudeSubscription {
                Section {
                    Picker(String(localized: "Claude model"), selection: $model) {
                        Text("Claude Sonnet").tag("claude-sonnet")
                        Text("Claude Opus").tag("claude-opus")
                        Text("Claude Haiku").tag("claude-haiku")
                    }
                }
            }
            Section {
                Text(String(localized: "Connecting enables Nib’s tool bridge. Keep Nib open while the assistant works. Each request gets a temporary token for its tools; your confirmation policy still applies."))
                DisclosureGroup(String(localized: "Tailscale or another network")) {
                    NibField(text: $bridgeHost, prompt: String(localized: "This iPad’s address reachable from your Mac"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(String(localized: "Leave empty on Wi-Fi. On Tailscale, enter this iPad’s Tailscale IP address.")).font(NibFont.footnote)
                }
                NibButton(String(localized: "Connect and use subscription"), symbol: .checkmark, kind: .primary) { connect() }
                    .disabled(busy)
                if busy { ProgressView() }
                if let message { Text(message).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary) }
                if saved { Text(String(localized: "Your subscription is now the default for Nib’s assistant and AI actions.")) }
                if let url = URL(string: address), ProviderValidation.warnsAboutHTTP(url, hasKey: true) {
                    NibBanner(String(localized: "This address sends your pairing token without encryption. Use a trusted local network, Tailscale or HTTPS."), style: .warning)
                }
            }
            if let current {
                Section {
                    if deleteArmed {
                        Text(String(localized: "Remove this subscription connection and its pairing token?"))
                        NibButton(String(localized: "Remove connection"), symbol: .trash, kind: .destructive) {
                            busy = true
                            Task { @MainActor in
                                defer { busy = false }
                                do {
                                    _ = try await app.bus.execute(CommandIDs.aiProviderDelete, ["id": .string(current.id.uuidString)])
                                    dismiss()
                                } catch { message = NibError.wrap(error).message }
                            }
                        }
                        NibButton(String(localized: "Keep connection"), kind: .plain) { deleteArmed = false }
                    } else {
                        NibButton(String(localized: "Remove connection"), symbol: .trash, kind: .destructivePlain) { deleteArmed = true }
                    }
                }
            }
        }
        .font(NibFont.body).scrollContentBackground(.hidden).background(NibColor.groupedBackground)
        .navigationTitle(preset.title)
        .task { discovery.start() }
        .onDisappear { discovery.stop(); token = ""; pairing = "" }
    }
    private func connect() {
        busy = true; saved = false; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if !pairing.isEmpty { let value = try AgentPairing.parse(pairing); address = value.url.absoluteString; token = value.token; pairing = "" }
                guard AgentPairing.validToken(token) || (token.isEmpty && current != nil) else {
                    throw NibError.invalid("Copy the pairing token from Nib Agent on your Mac.", path: "$.token")
                }
                var draft = current.map(ProviderDraft.init(config:)) ?? ProviderDraft(preset: preset)
                let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.baseURL = raw.contains("://") ? raw : "http://" + raw + (raw.contains(":") ? "/" : ":7332/")
                draft.model = model
                var config = try draft.config()
                config.extraHeaders["X-Nib-Subscription"] = "1"
                if !bridgeHost.isEmpty { config.extraHeaders["X-Nib-Bridge-Host"] = bridgeHost }
                else { config.extraHeaders.removeValue(forKey: "X-Nib-Bridge-Host") }
                guard let runtime = app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self) else {
                    throw NibError.unavailable("Open AI settings again and retry.")
                }
                // Explicit user action. Do not change either confirmation policy or rotate other clients' tokens.
                _ = try await app.bus.execute(CommandIDs.bridgeSetEnabled, ["enabled": true])
                try await runtime.saveFromSettings(config, key: token.isEmpty ? nil : token, app: app)
                current = config
                _ = try await app.bus.execute(CommandIDs.aiProviderTest, ["id": .string(config.id.uuidString)])
                _ = try await app.bus.execute(CommandIDs.aiProviderActivate, ["id": .string(config.id.uuidString)])
                token = ""; saved = true
            } catch { message = NibError.wrap(error).message }
        }
    }
}
