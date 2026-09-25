import Foundation
import NibContracts

/// Bridge settings. All are `security.*`: only the user reads or changes them (FEATURES.md › Exceptions).
/// F091 (Bridge settings page) uses these names through `settings.get` / `settings.set` as the user:
/// `security.bridge.enabled` (Bool), `security.bridge.port` (Int), `security.bridge.networks` ([CIDR string]),
/// `security.bridge.origins` ([origin string]); the token is the Keychain item `BridgeSecrets` names.
/// ponytail: `networks` and `origins` are one array key each, not one key per entry (ARCHITECTURE.md §15.5): they are
/// device-local (never synced, so no two-device merge), user-only, and the settings page replaces the whole list.
/// Move to `declarePrefix` per-entry keys if they ever sync.
enum BridgeSettings {
    static let enabled = SettingKey("security.bridge.enabled", default: false)
    static let port = SettingKey("security.bridge.port", default: 7331)
    static let networks = SettingKey("security.bridge.networks", default: BridgeNetworks.defaults)
    static let origins = SettingKey("security.bridge.origins", default: [String]())

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(enabled, summary: "MCP/HTTP bridge is on (user only; change it with bridge.setEnabled).",
                  owner: owner, schema: .bool())
        s.declare(port, summary: "TCP port of the MCP/HTTP bridge (default 7331).", owner: owner,
                  schema: .int(min: 1024, max: 65535))
        s.declare(networks, summary: "Networks (CIDR) bridge clients may connect from: loopback, LAN, Tailscale, link-local.",
                  owner: owner, schema: .arr(.str("CIDR, e.g. 192.168.0.0/16")))
        s.declare(origins, summary: "Browser Origins allowed to call the bridge (requests without an Origin always pass).",
                  owner: owner, schema: .arr(.str("origin, e.g. http://localhost:5173")))
    }
}

/// `bridge.status` output (the status pill and the Bridge settings page read it too).
struct BridgeStatus: Codable {
    struct Client: Codable, Equatable {
        var name: String
        var version: String?
        /// Unix seconds.
        var lastSeen: Double
        var calls: Int
        /// Open MCP sessions.
        var sessions: Int
    }

    var enabled: Bool
    /// off | starting | listening | suspended (app in background) | failed | tokenMissing
    var state: String
    var running: Bool
    var port: Int
    /// `http://<address>:<port>/mcp` for every local address in the allowed networks (while listening).
    var urls: [String]
    var bonjour: String
    /// No token in the Keychain (never issued, or lost after re-signing): "credentials missing — re-enter".
    var tokenMissing: Bool
    var error: String?
    /// Clients with an open session or seen in the last 10 minutes, most recent first.
    var clients: [Client]
    var lastCall: BridgeCall?
}

struct BridgeSetEnabled: NibCommand {
    struct Params: Codable {
        var enabled: Bool
        var rotateToken: Bool?
    }
    struct Output: Codable {
        var enabled: Bool
        var state: String
        var port: Int
        /// A new token was written to the Keychain (first start, re-entry after it went missing, or rotation).
        var tokenIssued: Bool
    }
    static let descriptor = CommandDescriptor(
        id: "bridge.setEnabled", title: "MCP Bridge",
        summary: "Start or stop the MCP/HTTP bridge; rotateToken issues a new bearer token so old clients get 401 (user only).",
        params: .obj(["enabled": .bool("true starts the bridge (it runs while Nib is in the foreground)"),
                      "rotateToken": .bool("issue a new token; clients still using the old one are refused")],
                     required: ["enabled"]),
        examples: [["enabled": false]],
        effect: .session, target: .app, extraScopes: [.security])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard ctx.principal.isUser else {
            throw NibError(.permissionDenied, "only the user can turn the bridge on or off",
                           hint: "ask the user to open Settings › Bridge")
        }
        let controller = try BridgeController.resolve(ctx.services)
        var issued = false
        if p.rotateToken == true || (p.enabled && BridgeSecrets.token() == nil) {
            guard Keychain.setString(BridgeAuth.generateToken(), service: BridgeSecrets.service, account: BridgeSecrets.account) else {
                throw NibError(.unavailable, "the Keychain did not store the bridge token",
                               hint: "try again; the bridge stays off without a token")
            }
            issued = true
            controller.tokenChanged()
        }
        ctx.services.settings.set(BridgeSettings.enabled, p.enabled)
        controller.reconcile()
        let status = controller.status()
        return Output(enabled: p.enabled, state: status.state, port: status.port, tokenIssued: issued)
    }
}

struct BridgeStatusCommand: NibCommand {
    static let descriptor = CommandDescriptor(
        id: "bridge.status", title: "Bridge Status",
        summary: "MCP/HTTP bridge state: listening URLs and port, recent clients and the last call (never the token).",
        examples: [[:]],
        effect: .read, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> BridgeStatus {
        try BridgeController.resolve(ctx.services).status()
    }
}
