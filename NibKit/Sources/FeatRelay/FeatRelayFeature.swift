import NibContracts
import Foundation
import SwiftUI

public enum FeatRelayFeature: NibFeature {
    public static let id = "relay"
    public static func register(_ app: NibApp) {
        app.settings.declare(RelayRuntime.urlKey, summary: "Device-local relay endpoint; change with relay.configure.",
                             owner: id, schema: .str(), readOnly: true)
        app.services.set(RelayRuntime(app: app), for: RelayRuntime.serviceKey)
        app.commands.register(RelayConfigure.descriptor) { params, ctx in
            guard let object = params.objectValue, Set(object.keys) == ["url"],
                  let url = object["url"]?.stringValue else {
                throw NibError.invalid("relay.configure accepts only url; enter the token in Settings.", path: "$")
            }
            guard let runtime = ctx.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self) else {
                throw NibError.unavailable("relay")
            }
            if !ctx.dryRun { try await runtime.configure(url, credentialGroup: ctx.principal.isUser ? ctx.group : nil, principal: ctx.principal) }
            else { _ = try RelayEndpoint.parse(url) }
            return [:]
        }
        var page = SettingsPageDescriptor(id: "relay.settings", title: String(localized: "Collaboration Relay"),
            icon: "network", section: .sync, order: 30, owner: id) { app in
                AnyView(RelaySettingsPage(app: app))
            }
        page.keywords = ["relay", "collaboration", "internet", "token", "self-hosted"]
        app.ui.settingsPages.register(page)
    }

    public static func start(_ app: NibApp) async {
        app.services.get(RelayRuntime.serviceKey, as: RelayRuntime.self)?.restore()
    }
}

enum RelayConfigure {
    static let descriptor = CommandDescriptor(id: "relay.configure",
        title: String(localized: "Configure Collaboration Relay"),
        summary: "Set a device-local ws/wss collaboration relay URL; use an empty URL to disable it. Enter its token in Settings only.",
        params: .obj(["url": .str("ws:// or wss:// endpoint; empty disables")], required: ["url"]),
        examples: [["url": "wss://relay.example.com/"], ["url": ""]], effect: .session, target: .app,
        undoable: false, sensitive: true)
}

/// The settings form hands its secret to the handler through a short-lived, user-only slot keyed by invocation
/// group. Neither the invocation, event stream, command hooks nor command result ever contains the token.
@MainActor
final class RelayRuntime {
    static let serviceKey = "relay.runtime"
    static let urlKey = SettingKey("relay.url", default: "")
    static let keychainService = "app.nib.relay"
    private weak var app: NibApp?
    private struct CredentialDraft { var url: URL; var token: String }
    private var credentials: [String: CredentialDraft] = [:]
    private var transport: WebSocketTransport?
    private let socketFactory: ((URLRequest) -> RelaySocket)?

    init(app: NibApp, socketFactory: ((URLRequest) -> RelaySocket)? = nil) {
        self.app = app; self.socketFactory = socketFactory
    }

    func restore() {
        guard transport == nil, let app = app, let url = try? RelayEndpoint.parse(app.settings.get(Self.urlKey)) else { return }
        install(url, app: app)
    }

    func configure(_ value: String, credentialGroup: String?, principal: Principal = .user) async throws {
        guard let app = app else { throw NibError.unavailable("relay") }
        let url = try RelayEndpoint.parse(value)
        if let group = credentialGroup, let draft = credentials.removeValue(forKey: group) {
            guard let url = url, url == draft.url else {
                throw NibError.invalid("The relay endpoint changed while saving. Re-enter its token.", path: "$.url")
            }
            let token = draft.token
            guard Keychain.setString(token.isEmpty ? nil : token, service: Self.keychainService, account: url.absoluteString) else {
                throw NibError(.unavailable, String(localized: "Couldn't save the relay token. Try again."))
            }
        }
        // End the live relay session through F072 before retiring the retained transport. This sends the host's
        // ended frame and clears F072's session state instead of leaving a zombie session with away participants.
        if app.commands.descriptor(CommandIDs.collabParticipants) != nil {
            let roster = try await app.bus.execute(Invocation(command: CommandIDs.collabParticipants, principal: principal))
            if roster.value["active"]?.boolValue == true, roster.value["transport"]?.stringValue == "relay" {
                _ = try await app.bus.execute(Invocation(command: CommandIDs.collabLeave, principal: principal))
            }
        }
        transport?.retire()
        transport = nil
        app.services.set(nil, for: ServiceKeys.collabRelay)
        app.settings.set(Self.urlKey, url?.absoluteString ?? "")
        if let url = url { install(url, app: app) }
    }

    private func install(_ url: URL, app: NibApp) {
        let pipe = WebSocketTransport(url: url, token: {
            Keychain.getString(service: Self.keychainService, account: url.absoluteString)
        }, factory: socketFactory)
        transport = pipe
        app.services.set(pipe, for: ServiceKeys.collabRelay)
    }

    func saveFromSettings(url: String, token: String?) async throws {
        guard let app = app else { throw NibError.unavailable("relay") }
        let group = UUID().uuidString
        if let token = token {
            guard let endpoint = try RelayEndpoint.parse(url) else {
                throw NibError.invalid("Enter a relay URL before saving its token.", path: "$.url")
            }
            guard token.utf8.count <= 4096, !token.contains("\r"), !token.contains("\n") else {
                throw NibError.invalid("The relay token is too long or contains a line break.")
            }
            credentials[group] = CredentialDraft(url: endpoint, token: token)
        }
        defer { credentials[group] = nil }
        _ = try await app.bus.execute(Invocation(command: CommandIDs.relayConfigure,
            params: ["url": .string(url)], principal: .user, group: group))
    }

    func hasToken(for value: String) -> Bool {
        guard let url = try? RelayEndpoint.parse(value) else { return false }
        return !(Keychain.getString(service: Self.keychainService, account: url.absoluteString) ?? "").isEmpty
    }
}
