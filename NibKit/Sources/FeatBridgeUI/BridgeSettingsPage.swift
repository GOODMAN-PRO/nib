import Foundation
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// MARK: - Pairing and validation (pure; unit-tested)

/// A message for a value the person typed that the page cannot store (shown under the field).
struct BridgeInputError: Error, Equatable {
    let message: String
}

enum BridgePortRules {
    static let defaultPort = 7331
    /// F090 declares `security.bridge.port` as 1024…65535.
    static let range = 1024...65535

    static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 5, t.allSatisfy(BridgeIP.isDigit), let value = Int(t), range.contains(value) else {
            return nil
        }
        return value
    }
}

/// IPv4 and IPv6 addresses as bytes (4 or 16). Only dotted quads are IPv4 (no "0x10", no octal): what people type into
/// the allowed networks must mean what it looks like.
enum BridgeIP {
    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// An IPv4-mapped IPv6 address (::ffff:a.b.c.d) folds to IPv4; a zone ("%en0") is ignored.
    static func parse(_ string: String) -> [UInt8]? {
        let s = string.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !s.isEmpty else { return nil }
        guard s.contains(":") else { return ipv4(s) }
        let noZone = String(s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var address = in6_addr()
        guard !noZone.isEmpty, inet_pton(AF_INET6, noZone, &address) == 1 else { return nil }
        return normalize(withUnsafeBytes(of: &address) { Array($0) })
    }

    /// "a.b.c.d"; with `padShort`, the short network forms the docs use ("10/8", "172.16/12") are padded with zeros.
    static func ipv4(_ s: String, padShort: Bool = false) -> [UInt8]? {
        var parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count) else { return nil }
        if parts.count < 4 {
            guard padShort else { return nil }
            parts += Array(repeating: "0", count: 4 - parts.count)
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(isDigit), let v = Int(part), v <= 255 else { return nil }
            bytes.append(UInt8(v))
        }
        return bytes
    }

    static func normalize(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return Array(bytes[12..<16])
        }
        return bytes
    }
}

/// A network in CIDR form ("192.168.0.0/16", "fd7a:115c:a1e0::/48"; a bare address is one host), read the way the
/// bridge (F090) reads `security.bridge.networks`.
struct BridgeCIDR: Equatable {
    /// The network address, host bits cleared.
    let bytes: [UInt8]
    let prefix: Int

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return nil }
        let host = parts[0]
        let parsed = host.contains(":") ? BridgeIP.parse(host) : BridgeIP.ipv4(host, padShort: parts.count == 2)
        guard let raw = parsed else { return nil }
        let bits = raw.count * 8
        var prefix = bits
        if parts.count == 2 {
            guard (1...3).contains(parts[1].count), parts[1].allSatisfy(BridgeIP.isDigit), let p = Int(parts[1]),
                  (0...bits).contains(p) else { return nil }
            prefix = p
        }
        self.init(bytes: raw, prefix: prefix)
    }

    init(bytes: [UInt8], prefix: Int) {
        self.bytes = BridgeCIDR.masked(bytes, prefix: prefix)
        self.prefix = prefix
    }

    static func masked(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        var out = bytes
        var remaining = max(prefix, 0)
        for i in out.indices {
            if remaining >= 8 {
                remaining -= 8
                continue
            }
            out[i] &= UInt8(truncatingIfNeeded: 0xff << (8 - remaining))
            remaining = 0
        }
        return out
    }

    func contains(_ address: [UInt8]) -> Bool {
        let a = BridgeIP.normalize(address)
        return a.count == bytes.count && BridgeCIDR.masked(a, prefix: prefix) == bytes
    }

    /// Every address of this network is also in `other`.
    func isInside(_ other: BridgeCIDR) -> Bool {
        other.bytes.count == bytes.count && other.prefix <= prefix && other.contains(bytes)
    }
}

/// What an address or a network is, for labels, ordering and the "outside your networks" warning.
enum BridgeAddressKind: Int, Comparable, CaseIterable {
    case hostName, lan, tailscale, other, linkLocal, loopback

    static func < (a: BridgeAddressKind, b: BridgeAddressKind) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .hostName: return String(localized: "Host name")
        case .lan: return String(localized: "Wi-Fi or local network")
        case .tailscale: return String(localized: "Tailscale")
        case .other: return String(localized: "Outside private networks")
        case .linkLocal: return String(localized: "Link-local")
        case .loopback: return String(localized: "This iPad only")
        }
    }
}

enum BridgeNetworkRules {
    static let tailscale = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"].compactMap { BridgeCIDR($0) }
    static let loopback = ["127.0.0.0/8", "::1/128"].compactMap { BridgeCIDR($0) }
    static let linkLocal = ["169.254.0.0/16", "fe80::/10"].compactMap { BridgeCIDR($0) }
    /// RFC 1918 and IPv6 unique local addresses.
    static let lan = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"].compactMap { BridgeCIDR($0) }

    static func kind(of cidr: BridgeCIDR) -> BridgeAddressKind {
        // Tailscale's IPv6 range sits inside fc00::/7, so it is checked first.
        if tailscale.contains(where: { cidr.isInside($0) }) { return .tailscale }
        if loopback.contains(where: { cidr.isInside($0) }) { return .loopback }
        if linkLocal.contains(where: { cidr.isInside($0) }) { return .linkLocal }
        if lan.contains(where: { cidr.isInside($0) }) { return .lan }
        return .other
    }

    /// `.hostName` for anything that is not an IP address.
    static func kind(ofHost host: String) -> BridgeAddressKind {
        guard let bytes = BridgeIP.parse(host) else { return .hostName }
        return kind(of: BridgeCIDR(bytes: bytes, prefix: bytes.count * 8))
    }

    /// A network that reaches past private ranges (e.g. 0.0.0.0/0): anyone who can reach the iPad could try tokens.
    static func isPublic(_ entry: String) -> Bool {
        BridgeCIDR(entry).map { kind(of: $0) == .other } ?? false
    }

    static func adding(_ text: String, to list: [String]) throws -> [String] {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let cidr = BridgeCIDR(entry) else {
            throw BridgeInputError(message: String(localized: "Enter a network such as 192.168.1.0/24 or fd7a:115c:a1e0::/48."))
        }
        guard !list.contains(where: { BridgeCIDR($0) == cidr }) else {
            throw BridgeInputError(message: String(localized: "\(entry) is already allowed."))
        }
        return list + [entry]
    }

    static func removing(_ entry: String, from list: [String]) -> [String] {
        list.filter { $0 != entry }
    }
}

/// Browser origins allowed to call the bridge (`security.bridge.origins`): scheme, host and optional port only.
enum BridgeOriginRules {
    static func normalize(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), let scheme = c.scheme, scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, c.path.isEmpty, c.query == nil, c.fragment == nil,
              c.user == nil, c.password == nil else { return nil }
        return s
    }

    static func adding(_ text: String, to list: [String]) throws -> [String] {
        guard let origin = normalize(text) else {
            throw BridgeInputError(message: String(localized: "Enter an origin such as http://localhost:5173 (no path)."))
        }
        guard !list.contains(where: { normalize($0) == origin }) else {
            throw BridgeInputError(message: String(localized: "\(origin) is already allowed."))
        }
        return list + [origin]
    }
}

/// The host name clients use instead of an IP address (`bridgeui.hostName`), e.g. a Tailscale MagicDNS name.
enum BridgeHostRules {
    /// "" for empty input (no host name); nil when it is neither an IP address nor a valid DNS name. A pasted URL or
    /// "name:port" keeps only the host.
    static func normalize(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return "" }
        if s.contains("://") {
            guard let host = BridgeAddress.host(fromURL: s) else { return nil }
            s = host
        }
        if s.hasPrefix("[") || BridgeIP.parse(s) != nil {
            let bare = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return BridgeIP.parse(bare) != nil ? bare : nil
        }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":"),
           s[s.index(after: colon)...].allSatisfy(BridgeIP.isDigit) {
            s = String(s[..<colon])
        }
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, s.count <= 253 else { return nil }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        let valid = labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        // An all-digit last label is a mistyped IP address, not a name.
        guard valid, let last = labels.last, !last.allSatisfy(BridgeIP.isDigit) else { return nil }
        return s
    }
}

/// One address a client can use to reach the bridge.
struct BridgeAddress: Identifiable, Hashable {
    /// Host name, IPv4 or IPv6 (without brackets).
    var host: String
    var kind: BridgeAddressKind
    var id: String { host }
    var urlHost: String { BridgeAddress.urlHost(host) }

    static func urlHost(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    /// "http://192.168.1.20:7331/mcp" → "192.168.1.20"; "http://[fd7a::1]:7331/mcp" → "fd7a::1".
    static func host(fromURL url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = s.range(of: "://") else { return nil }
        s = String(s[scheme.upperBound...])
        if let end = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<end]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let inner = String(s[s.index(after: s.startIndex)..<close])
            return inner.isEmpty ? nil : inner
        }
        if let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        return s.isEmpty ? nil : s
    }

    /// The person's host name first, then the bridge's addresses by kind (local network before Tailscale), keeping the
    /// bridge's order within a kind.
    static func list(urls: [String], hostName: String) -> [BridgeAddress] {
        let name = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [BridgeAddress] = []
        for url in urls {
            guard let host = host(fromURL: url), host != name, !found.contains(where: { $0.host == host }) else { continue }
            found.append(BridgeAddress(host: host, kind: BridgeNetworkRules.kind(ofHost: host)))
        }
        let sorted = found.enumerated()
            .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
            .map { $0.element }
        guard !name.isEmpty else { return sorted }
        return [BridgeAddress(host: name, kind: BridgeNetworkRules.kind(ofHost: name))] + sorted
    }
}

/// Ready-to-paste client configuration (docs/AI.md §9.4) and the device smoke runner's environment (tools/smoke).
enum BridgeSnippet: String, CaseIterable, Identifiable {
    case claudeCode, json, smokeShell, smokePowerShell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: return String(localized: "Claude Code")
        case .json: return String(localized: "JSON configuration")
        case .smokeShell: return String(localized: "macOS and Linux")
        case .smokePowerShell: return String(localized: "Windows PowerShell")
        }
    }
}

struct BridgePairing: Equatable {
    var host: String
    var port: Int
    var token: String

    var baseURL: String { "http://\(BridgeAddress.urlHost(host)):\(port)" }
    var mcpURL: String { baseURL + "/mcp" }

    /// `masked` shows "nib_••••…" in place of the token (what the page shows while the token is hidden); copying always
    /// uses the real one.
    func text(_ snippet: BridgeSnippet, masked: Bool = false) -> String {
        let token = masked ? BridgeToken.masked(self.token) : self.token
        switch snippet {
        case .claudeCode:
            // Brackets of an IPv6 URL are glob characters in zsh and bash: quote the URL then.
            let url = mcpURL.contains("[") ? "\"\(mcpURL)\"" : mcpURL
            return "claude mcp add --transport http nib \(url) --header \"Authorization: Bearer \(token)\""
        case .json:
            return """
            {
              "mcpServers": {
                "nib": {
                  "type": "http",
                  "url": \(BridgeJSON.quote(mcpURL)),
                  "headers": {
                    "Authorization": \(BridgeJSON.quote("Bearer " + token))
                  }
                }
              }
            }
            """
        case .smokeShell:
            return "export NIB_BRIDGE_URL=\"\(baseURL)\"\nexport NIB_BRIDGE_TOKEN=\"\(token)\"\nnode tools/smoke/run.mjs"
        case .smokePowerShell:
            return "$env:NIB_BRIDGE_URL = \"\(baseURL)\"\n$env:NIB_BRIDGE_TOKEN = \"\(token)\"\nnode tools/smoke/run.mjs"
        }
    }

    /// The pairing deep link the QR code holds (ARCHITECTURE.md §12: `nib://bridge/pair?host=…&token=…`, plus the port).
    /// Opening it shows the pairing sheet (F074) and never turns a bridge on by itself.
    var pairingURL: String {
        var c = URLComponents()
        c.scheme = "nib"
        c.host = "bridge"
        c.path = "/pair"
        c.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                        URLQueryItem(name: "token", value: token)]
        return c.string ?? "nib://bridge/pair"
    }
}

enum BridgeJSON {
    /// A JSON string literal (quotes, backslashes and control characters escaped; "/" left alone).
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Pasteboard

@MainActor
enum BridgePasteboard {
    /// Copied tokens and snippets leave the clipboard after 10 minutes, so a token does not linger there.
    static let lifetime: TimeInterval = 600

    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.expirationDate: Date(timeIntervalSinceNow: lifetime)])
    }
}

// MARK: - Model

/// Everything Settings › Bridge shows and does. Reads come from `bridge.status` (through `BridgeMonitor`), the settings
/// store and the Keychain; every change is a command run as the user (`bridge.setEnabled`, `settings.set`), so the page
/// does nothing a command could not.
@MainActor
final class BridgeSettingsModel: ObservableObject {
    let monitor: BridgeMonitor
    private weak var app: NibApp?

    @Published var tokenRevealed = false
    /// The address the snippets and the QR code use (nil = the first one).
    @Published var selectedHost: String?
    @Published var portText = ""
    @Published private(set) var portMessage: String?
    @Published var hostNameText = ""
    @Published private(set) var hostNameMessage: String?
    @Published var networkText = ""
    @Published private(set) var networkMessage: String?
    @Published var originText = ""
    @Published private(set) var originMessage: String?
    /// The last command that failed, in plain words.
    @Published private(set) var actionError: String?
    /// What just happened (a new token), shown until the next action.
    @Published private(set) var notice: String?
    /// The switch's position while `bridge.setEnabled` runs.
    @Published private(set) var pendingEnabled: Bool?
    @Published private(set) var busy = false
    /// Id of what was copied last (`"token"` or a snippet), for the "Copied" line; clears after 3 s.
    @Published private(set) var copied: String?

    /// Writes the pasteboard (nil = the system pasteboard); tests replace it.
    var copyText: ((String) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var copiedReset: Task<Void, Never>?

    init(app: NibApp, monitor: BridgeMonitor) {
        self.app = app
        self.monitor = monitor
        portText = String(configuredPort)
        hostNameText = hostName
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .compactMap { $0.userInfo?["name"] as? String }
            .filter { BridgeUISettings.affectsBridge($0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                Task { @MainActor in self?.settingChanged(name) }
            }
            .store(in: &cancellables)
    }

    // MARK: Reads

    /// A bridge setting as stored, else its declared default (F090 declares them; nil without the bridge).
    private func json(_ name: String) -> JSONValue? {
        guard let settings = app?.settings else { return nil }
        return settings.json(name) ?? settings.descriptor(name)?.defaultValue
    }

    private func strings(_ name: String) -> [String] {
        json(name)?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    var isEnabled: Bool {
        pendingEnabled ?? json(BridgeNames.enabledSetting)?.boolValue ?? monitor.snapshot?.enabled ?? false
    }

    var state: BridgeState {
        if let s = monitor.snapshot { return s.state }
        return isEnabled ? .starting : .off
    }

    var configuredPort: Int { json(BridgeNames.portSetting)?.intValue ?? BridgePortRules.defaultPort }

    /// The port clients use: the bound one while listening, else the configured one.
    var pairingPort: Int {
        if let s = monitor.snapshot, s.running { return s.port }
        return configuredPort
    }

    var networks: [String] { strings(BridgeNames.networksSetting) }

    var defaultNetworks: [String] {
        app?.settings.descriptor(BridgeNames.networksSetting)?.defaultValue.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    var networksAreDefault: Bool {
        app?.settings.json(BridgeNames.networksSetting) == nil || networks == defaultNetworks
    }

    var origins: [String] { strings(BridgeNames.originsSetting) }

    var policy: ConfirmationPolicy { app?.settings.get(NibSettings.bridgeConfirmationPolicy) ?? .destructive }

    var keepScreenAwake: Bool { app?.settings.get(BridgeUISettings.keepScreenAwake) ?? true }

    var hostName: String { app?.settings.get(BridgeUISettings.hostName) ?? "" }

    var token: String? { monitor.token }

    var addresses: [BridgeAddress] { BridgeAddress.list(urls: monitor.snapshot?.urls ?? [], hostName: hostName) }

    var selectedAddress: BridgeAddress? {
        let all = addresses
        return all.first { $0.host == selectedHost } ?? all.first
    }

    var pairing: BridgePairing? {
        guard let token = token, let address = selectedAddress else { return nil }
        return BridgePairing(host: address.host, port: pairingPort, token: token)
    }

    var clients: [BridgeSnapshot.Client] { monitor.snapshot?.clients ?? [] }

    var lastCall: BridgeSnapshot.Call? { monitor.snapshot?.lastCall }

    var stateDetail: String? {
        let port = String(pairingPort)
        switch state {
        case .off:
            return nil
        case .starting:
            return String(localized: "Opening port \(port)")
        case .listening:
            switch clients.count {
            case 0: return String(localized: "Port \(port), no clients yet")
            case 1: return String(localized: "Port \(port), 1 client")
            default: return String(localized: "Port \(port), \(String(clients.count)) clients")
            }
        case .suspended:
            return String(localized: "It starts again when you come back to Nib.")
        case .failed:
            return monitor.snapshot?.error ?? String(localized: "Try another port, or turn the bridge off and on again.")
        case .tokenMissing:
            return String(localized: "The bridge token is no longer in the Keychain.")
        }
    }

    // MARK: Actions (all commands, as the user)

    func setEnabled(_ on: Bool) async {
        guard let app = app else { return }
        pendingEnabled = on
        notice = nil
        await perform { try await BridgeCalls.setEnabled(app, enabled: on) }
        pendingEnabled = nil
        await monitor.refresh()
    }

    /// A new token for the bridge; every client that still presents the old one is refused (401) from now on. A running
    /// bridge rotates with `bridge.setEnabled {enabled: true, rotateToken: true}` (spec, G27); one the person turned off
    /// rotates with `enabled: false`, so rotating never starts a bridge behind their back.
    @discardableResult
    func rotateToken() async -> Bool {
        guard let app = app else { return false }
        let enabled = isEnabled
        let ok = await perform { try await BridgeCalls.setEnabled(app, enabled: enabled, rotateToken: true) }
        await monitor.refresh()
        if ok {
            post(notice: String(localized: "New token issued. Clients that still use the old one are refused until you paste the new one."))
        }
        return ok
    }

    /// "Credentials missing: re-enter": issues a new token and starts the bridge again.
    @discardableResult
    func issueNewToken() async -> Bool {
        guard let app = app else { return false }
        let ok = await perform { try await BridgeCalls.setEnabled(app, enabled: true, rotateToken: true) }
        await monitor.refresh()
        if ok {
            post(notice: String(localized: "New token issued. Paste it into your clients again."))
        }
        return ok
    }

    func applyPort() async {
        guard let port = BridgePortRules.parse(portText) else {
            portMessage = String(localized: "Enter a port from 1024 to 65535.")
            return
        }
        portMessage = nil
        portText = String(port)
        guard port != configuredPort else { return }
        await set(BridgeNames.portSetting, .number(Double(port)))
    }

    func resetPort() async {
        portMessage = nil
        if await set(BridgeNames.portSetting, .null) { portText = String(configuredPort) }
    }

    func applyHostName() async {
        guard let name = BridgeHostRules.normalize(hostNameText) else {
            hostNameMessage = String(localized: "Enter a host name such as ipad.tail1234.ts.net, or leave it empty.")
            return
        }
        hostNameMessage = nil
        hostNameText = name
        guard name != hostName else { return }
        if await set(BridgeUISettings.hostName.name, name.isEmpty ? .null : .string(name)) {
            selectedHost = name.isEmpty ? nil : name
        }
    }

    func addNetwork() async {
        do {
            let list = try BridgeNetworkRules.adding(networkText, to: networks)
            networkMessage = nil
            if await set(BridgeNames.networksSetting, .array(list.map { JSONValue.string($0) })) { networkText = "" }
        } catch {
            networkMessage = (error as? BridgeInputError)?.message ?? NibError.wrap(error).message
        }
    }

    func removeNetwork(_ entry: String) async {
        await set(BridgeNames.networksSetting, .array(BridgeNetworkRules.removing(entry, from: networks).map { JSONValue.string($0) }))
    }

    func restoreDefaultNetworks() async {
        await set(BridgeNames.networksSetting, .null)
    }

    func addOrigin() async {
        do {
            let list = try BridgeOriginRules.adding(originText, to: origins)
            originMessage = nil
            if await set(BridgeNames.originsSetting, .array(list.map { JSONValue.string($0) })) { originText = "" }
        } catch {
            originMessage = (error as? BridgeInputError)?.message ?? NibError.wrap(error).message
        }
    }

    func removeOrigin(_ entry: String) async {
        await set(BridgeNames.originsSetting, .array(origins.filter { $0 != entry }.map { JSONValue.string($0) }))
    }

    func setPolicy(_ policy: ConfirmationPolicy) async {
        await set(NibSettings.bridgeConfirmationPolicy.name, .string(policy.rawValue))
    }

    func setKeepScreenAwake(_ on: Bool) async {
        await set(BridgeUISettings.keepScreenAwake.name, .bool(on))
    }

    func copy(_ text: String, id: String) {
        if let write = copyText {
            write(text)
        } else {
            BridgePasteboard.copy(text)
        }
        copied = id
        NibHaptics.play(.success)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
        copiedReset?.cancel()
        copiedReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    // MARK: Plumbing

    @discardableResult
    private func set(_ name: String, _ value: JSONValue) async -> Bool {
        guard let app = app else { return false }
        return await perform { try await BridgeCalls.setSetting(app, name, value) }
    }

    @discardableResult
    private func perform(_ body: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await body()
            actionError = nil
            return true
        } catch {
            actionError = NibError.wrap(error).message
            return false
        }
    }

    private func post(notice text: String) {
        notice = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func settingChanged(_ name: String) {
        if name == BridgeNames.portSetting, portMessage == nil { portText = String(configuredPort) }
        if name == BridgeUISettings.hostName.name, hostNameMessage == nil { hostNameText = hostName }
        objectWillChange.send()
    }
}

extension ConfirmationPolicy {
    var bridgeTitle: String {
        switch self {
        case .always: return String(localized: "Always")
        case .destructive: return String(localized: "Deletions")
        case .never: return String(localized: "Never")
        }
    }

    var bridgeDetail: String {
        switch self {
        case .always:
            return String(localized: "Every change an agent makes waits until you allow it on this iPad.")
        case .destructive:
            return String(localized: "Deleting and overwriting wait until you allow them on this iPad; other changes go ahead and can be undone.")
        case .never:
            return String(localized: "Changes go ahead without asking; you can still undo them.")
        }
    }
}

// MARK: - Page

/// Settings › Bridge (DESIGN.md §14.8: an opaque inset grouped list; §14.9: the pairing code in `hudLarge`, connected
/// clients and what they may do).
@MainActor
struct BridgeSettingsPage: View {
    @ObservedObject private var monitor: BridgeMonitor
    @StateObject private var model: BridgeSettingsModel
    @State private var confirmsRotation = false
    @State private var confirmsNeverAsk = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case port, hostName, network, origin }

    init(app: NibApp, monitor: BridgeMonitor) {
        _monitor = ObservedObject(wrappedValue: monitor)
        _model = StateObject(wrappedValue: BridgeSettingsModel(app: app, monitor: monitor))
    }

    var body: some View {
        Group {
            if monitor.isAvailable {
                List {
                    statusSection
                    messagesSection
                    addressSection
                    tokenSection
                    pairingSections
                    clientsSection
                    confirmationSection
                    networksSection
                    originsSection
                    screenSection
                }
                .listStyle(.insetGrouped)
            } else {
                NibEmptyState(symbol: .bridge, title: String(localized: "The bridge isn't available"),
                              message: String(localized: "This build of Nib has no MCP bridge, or safe mode turned it off."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NibColor.groupedBackground)
            }
        }
        .onAppear { monitor.watch() }
        .onDisappear { monitor.unwatch() }
        .onChange(of: focus) { previous, _ in
            // Leaving a field keeps what was typed (touch keyboards have no return key on the number pad).
            switch previous {
            case .port?: Task { await model.applyPort() }
            case .hostName?: Task { await model.applyHostName() }
            default: break
            }
        }
        .confirmationDialog(String(localized: "Rotate the bridge token?"), isPresented: $confirmsRotation,
                            titleVisibility: .visible) {
            Button(String(localized: "Rotate Token"), role: .destructive) {
                Task { await model.rotateToken() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Every client that uses the current token is refused until you paste the new one."))
        }
        .confirmationDialog(String(localized: "Let agents change notes without asking?"), isPresented: $confirmsNeverAsk,
                            titleVisibility: .visible) {
            Button(String(localized: "Never Ask"), role: .destructive) {
                Task { await model.setPolicy(.never) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Connected agents could then change and delete notes without you seeing it first. You can still undo their changes."))
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            NibToggle(String(localized: "MCP bridge"),
                      isOn: Binding(get: { model.isEnabled }, set: { on in Task { await model.setEnabled(on) } }))
                .disabled(model.busy)
            BridgeStatusRow(state: model.state, detail: model.stateDetail)
        } footer: {
            BridgeFooter(String(localized: "Lets an agent such as Claude Code on your computer read and change your notes over Wi-Fi or Tailscale, with the same tools as the assistant. It runs only while Nib is open."))
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        if model.state == .tokenMissing {
            Section {
                NibBanner(String(localized: "Credentials missing. Re-enter them by issuing a new token, then paste it into your clients again. The bridge stays off until you do."),
                          style: .warning, symbol: .key,
                          action: NibAction(String(localized: "Issue New Token")) { Task { await model.issueNewToken() } })
                    .disabled(model.busy)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        if let error = model.actionError ?? monitor.refreshError {
            Section {
                NibBanner(error, style: .warning)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        if let notice = model.notice {
            Section {
                NibBanner(notice, style: .info, symbol: .key)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var addressSection: some View {
        Section {
            if let address = model.selectedAddress {
                VStack(alignment: .leading, spacing: NibSpacing.xs) {
                    Text(verbatim: BridgeFormat.hostPort(address.host, model.pairingPort))
                        .font(NibFont.hudLarge)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    Text(address.kind.title)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                .padding(.vertical, NibSpacing.xs)
                .accessibilityElement(children: .combine)
                if model.addresses.count > 1 {
                    Picker(String(localized: "Use address"),
                           selection: Binding(get: { model.selectedAddress?.host ?? "" }, set: { model.selectedHost = $0 })) {
                        ForEach(model.addresses) { a in
                            Text(verbatim: "\(a.urlHost) (\(a.kind.title))").tag(a.host)
                        }
                    }
                    .font(NibFont.body)
                }
            } else {
                Text(model.state == .listening
                     ? String(localized: "No network address. Join Wi-Fi or turn on Tailscale.")
                     : String(localized: "The address appears once the bridge is on."))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            portRow
            hostNameRow
        } header: {
            BridgeHeader(String(localized: "Address"))
        } footer: {
            BridgeFooter(String(localized: "On Tailscale, enter this iPad's \(BridgeUIIDs.magicDNS) name (for example ipad.tail1234.ts.net, shown in the Tailscale app) so clients keep working when its address changes. Tailscale addresses start with 100. Nib also announces the bridge on the local network as _nib._tcp."))
        }
    }

    private var portRow: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.s) {
                Text(String(localized: "Port"))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                Spacer(minLength: NibSpacing.s)
                TextField(String(BridgePortRules.defaultPort), text: $model.portText)
                    .font(NibFont.body.monospacedDigit())
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .focused($focus, equals: .port)
                    .onSubmit { Task { await model.applyPort() } }
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(String(localized: "Port"))
                if model.configuredPort != BridgePortRules.defaultPort {
                    NibButton(String(localized: "Use Default Port"), kind: .plain, size: .compact) {
                        Task { await model.resetPort() }
                    }
                }
            }
            if let message = model.portMessage {
                BridgeFieldMessage(message)
            }
        }
    }

    private var hostNameRow: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.s) {
                Text(String(localized: "Host name"))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                Spacer(minLength: NibSpacing.s)
                TextField(String(localized: "Optional"), text: $model.hostNameText)
                    .font(NibFont.body)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .hostName)
                    .onSubmit { Task { await model.applyHostName() } }
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(String(localized: "Host name, for example a Tailscale \(BridgeUIIDs.magicDNS) name"))
            }
            if let message = model.hostNameMessage {
                BridgeFieldMessage(message)
            }
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        if let token = model.token {
            Section {
                HStack(spacing: NibSpacing.xs) {
                    Text(verbatim: model.tokenRevealed ? token : BridgeToken.masked(token))
                        .font(NibFont.code)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(model.tokenRevealed ? 3 : 1)
                        .textSelection(.enabled)
                        .privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(model.tokenRevealed ? token : String(localized: "Token, hidden"))
                    NibIconButton(model.tokenRevealed ? .eyeSlash : .eye,
                                  label: model.tokenRevealed ? String(localized: "Hide Token") : String(localized: "Show Token"),
                                  size: .panel) {
                        model.tokenRevealed.toggle()
                    }
                    NibIconButton(.copy, label: String(localized: "Copy Token"), size: .panel) {
                        model.copy(token, id: "token")
                    }
                }
                if model.copied == "token" {
                    BridgeCopiedLine()
                }
                NibButton(String(localized: "Rotate Token"), symbol: .retry, kind: .destructive) {
                    confirmsRotation = true
                }
                .disabled(model.busy)
            } header: {
                BridgeHeader(String(localized: "Token"))
            } footer: {
                BridgeFooter(String(localized: "Anyone on an allowed network who has this token can read and change your notes, so keep it private. Rotating it refuses every client that still uses the old one. Copied tokens leave the clipboard after 10 minutes."))
            }
        } else if model.state != .tokenMissing {
            Section {
                Text(String(localized: "Nib issues a token when you turn the bridge on."))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
            } header: {
                BridgeHeader(String(localized: "Token"))
            }
        }
    }

    @ViewBuilder
    private var pairingSections: some View {
        if let pairing = model.pairing {
            Section {
                if model.tokenRevealed {
                    HStack {
                        Spacer(minLength: 0)
                        NibQRCode(pairing.pairingURL,
                                  label: String(localized: "QR code with this iPad's bridge address and token"))
                            .frame(width: 200, height: 200)
                            .privacySensitive()
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, NibSpacing.s)
                } else {
                    NibButton(String(localized: "Show QR Code"), symbol: .qrCode, kind: .secondary) {
                        model.tokenRevealed = true
                    }
                }
                snippetRow(.claudeCode, pairing)
                snippetRow(.json, pairing)
            } header: {
                BridgeHeader(String(localized: "Pair a Client"))
            } footer: {
                BridgeFooter(String(localized: "Run the command on the computer that runs Claude Code, or add the JSON to another MCP client's configuration. The QR code holds the address and the token."))
            }
            Section {
                snippetRow(.smokeShell, pairing)
                snippetRow(.smokePowerShell, pairing)
            } header: {
                BridgeHeader(String(localized: "Device Smoke Tests"))
            } footer: {
                BridgeFooter(String(localized: "Plays the tools/smoke scripts against this iPad from a clone of the Nib repository."))
            }
        }
    }

    private func snippetRow(_ snippet: BridgeSnippet, _ pairing: BridgePairing) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(snippet.title)
                .font(NibFont.footnoteEmphasis)
                .foregroundStyle(NibColor.labelSecondary)
            NibCodeBlock(pairing.text(snippet, masked: !model.tokenRevealed)) {
                model.copy(pairing.text(snippet), id: snippet.id)
            }
            .privacySensitive(model.tokenRevealed)
            if model.copied == snippet.id {
                BridgeCopiedLine()
            }
        }
        .padding(.vertical, NibSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var clientsSection: some View {
        if model.isEnabled {
            Section {
                if model.clients.isEmpty {
                    Text(String(localized: "No clients yet"))
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                ForEach(model.clients, id: \.name) { client in
                    NibRow(BridgeFormat.clientTitle(client), subtitle: BridgeFormat.clientDetail(client)) {
                        NibBadge(.principal(.bridge))
                    }
                    .accessibilityElement(children: .combine)
                }
                if let call = model.lastCall {
                    NibTraceRow(String(localized: "Last call: \(BridgeFormat.callText(call))"), phase: call.ok ? .done : .warning)
                        .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
                }
            } header: {
                BridgeHeader(String(localized: "Clients"))
            } footer: {
                BridgeFooter(String(localized: "Clients act as Bridge: they can do what the assistant can, never change security settings such as this page, and ask on this iPad as set below."))
            }
        }
    }

    private var confirmationSection: some View {
        Section {
            NibSegmentedControl(selection: Binding(get: { model.policy }, set: { policy in
                if policy == .never {
                    confirmsNeverAsk = true
                } else {
                    Task { await model.setPolicy(policy) }
                }
            }), options: ConfirmationPolicy.allCases) { $0.bridgeTitle }
                .accessibilityLabel(String(localized: "Ask before bridge changes"))
        } header: {
            BridgeHeader(String(localized: "Ask Before Changes"))
        } footer: {
            BridgeFooter(model.policy.bridgeDetail + " "
                         + String(localized: "Sending data off the iPad, deleting for good and installing plugins always ask, whatever you choose. A request waits up to 2 minutes for your answer."))
        }
    }

    private var networksSection: some View {
        Section {
            ForEach(model.networks, id: \.self) { entry in
                BridgeListEntryRow(text: entry,
                                   detail: BridgeCIDR(entry).map { BridgeNetworkRules.kind(of: $0).title },
                                   warns: BridgeNetworkRules.isPublic(entry),
                                   removeLabel: String(localized: "Remove \(entry)")) {
                    Task { await model.removeNetwork(entry) }
                }
            }
            if model.networks.isEmpty {
                BridgeFieldMessage(String(localized: "No networks: every client is refused."))
            }
            BridgeAddRow(text: $model.networkText, prompt: String(localized: "192.168.1.0/24"),
                         buttonTitle: String(localized: "Add Network"), message: model.networkMessage,
                         focus: $focus, field: .network) {
                Task { await model.addNetwork() }
            }
            if !model.networksAreDefault {
                NibButton(String(localized: "Restore Default Networks"), kind: .plain) {
                    Task { await model.restoreDefaultNetworks() }
                }
            }
        } header: {
            BridgeHeader(String(localized: "Allowed Networks"))
        } footer: {
            BridgeFooter(String(localized: "Clients must connect from one of these networks. The defaults cover this iPad, private home and office networks, Tailscale and link-local addresses."))
        }
    }

    private var originsSection: some View {
        Section {
            ForEach(model.origins, id: \.self) { entry in
                BridgeListEntryRow(text: entry, detail: nil, warns: false,
                                   removeLabel: String(localized: "Remove \(entry)")) {
                    Task { await model.removeOrigin(entry) }
                }
            }
            BridgeAddRow(text: $model.originText, prompt: String(localized: "http://localhost:5173"),
                         buttonTitle: String(localized: "Add Origin"), message: model.originMessage,
                         focus: $focus, field: .origin) {
                Task { await model.addOrigin() }
            }
        } header: {
            BridgeHeader(String(localized: "Allowed Web Origins"))
        } footer: {
            BridgeFooter(String(localized: "A web page may call the bridge only from one of these origins. Command-line clients such as Claude Code send no origin and are not affected."))
        }
    }

    private var screenSection: some View {
        Section {
            NibToggle(String(localized: "Keep screen awake"),
                      isOn: Binding(get: { model.keepScreenAwake }, set: { on in Task { await model.setKeepScreenAwake(on) } }))
        } footer: {
            BridgeFooter(String(localized: "iOS pauses the bridge when the screen locks or you leave Nib. While the bridge is on, this stops the screen from locking."))
        }
    }
}

// MARK: - Rows

private struct BridgeHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct BridgeFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
    }
}

private struct BridgeFieldMessage: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NibSpacing.xs) {
            Image(nib: .warningTriangle)
                .foregroundStyle(NibColor.warning)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(NibFont.caption1)
        .accessibilityElement(children: .combine)
    }
}

private struct BridgeCopiedLine: View {
    var body: some View {
        HStack(spacing: NibSpacing.xs) {
            Image(nib: .checkmark)
                .foregroundStyle(NibColor.success)
                .accessibilityHidden(true)
            Text(String(localized: "Copied. It leaves the clipboard after 10 minutes."))
                .foregroundStyle(NibColor.labelSecondary)
        }
        .font(NibFont.caption1)
    }
}

/// The bridge state with its dot: never colour alone (the title says it too).
private struct BridgeStatusRow: View {
    let state: BridgeState
    let detail: String?

    private var dot: NibStatusDot.Kind? {
        switch state {
        case .listening: return .connected
        case .failed, .tokenMissing: return .warning
        case .off, .starting, .suspended: return nil
        }
    }

    var body: some View {
        HStack(spacing: NibSpacing.s) {
            if let dot = dot {
                NibStatusDot(dot)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                if let detail = detail {
                    Text(detail)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Status: \(state.title)"))
        .accessibilityValue(detail ?? "")
    }
}

/// One allowed network or origin with its Remove button.
private struct BridgeListEntryRow: View {
    let text: String
    let detail: String?
    let warns: Bool
    let removeLabel: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: NibSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                    .font(NibFont.code)
                    .foregroundStyle(NibColor.label)
                if warns {
                    BridgeFieldMessage(String(localized: "Reaches past private networks: anyone who can reach this iPad could try tokens."))
                } else if let detail = detail {
                    Text(detail)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
            Spacer(minLength: NibSpacing.s)
            NibIconButton(.minus, label: removeLabel, size: .panel, action: onRemove)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(removeLabel), onRemove)
    }
}

/// A field and its Add button, with the reason when the value was refused.
private struct BridgeAddRow: View {
    @Binding var text: String
    let prompt: String
    let buttonTitle: String
    let message: String?
    var focus: FocusState<BridgeSettingsPage.Field?>.Binding
    let field: BridgeSettingsPage.Field
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.s) {
                TextField(prompt, text: $text)
                    .font(NibFont.code)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused(focus, equals: field)
                    .onSubmit(onAdd)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(buttonTitle)
                NibButton(buttonTitle, symbol: .plus, kind: .plain, size: .compact, action: onAdd)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = message {
                BridgeFieldMessage(message)
            }
        }
    }
}
