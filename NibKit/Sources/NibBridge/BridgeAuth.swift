import Foundation
import Network
import NibContracts

/// Where the bridge token lives: Keychain generic password, service "app.nib.bridge", account "token" (device only,
/// never synced). `bridge.setEnabled` writes it; the Bridge settings page (F091) reads it to show / copy / pair.
enum BridgeSecrets {
    static let service = "app.nib.bridge"
    static let account = "token"

    /// nil when missing (never issued, or lost after re-signing with another team: "credentials missing — re-enter").
    static func token() -> String? {
        guard let t = Keychain.getString(service: service, account: account), !t.isEmpty else { return nil }
        return t
    }
}

/// Token, bearer header and Origin checks (docs/AI.md §9.1). Pure, so they are unit-tested.
enum BridgeAuth {
    static let tokenPrefix = "nib_"

    /// "nib_" + 43 base64url characters of 32 random bytes.
    static func generateToken() -> String {
        var rng = SystemRandomNumberGenerator()   // arc4random: cryptographically secure on Apple platforms
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return tokenPrefix + base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.range(of: "^nib_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }

    /// The credentials of an `Authorization: Bearer <token>` header (scheme is case-insensitive).
    static func bearer(_ header: String?) -> String? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.count > 7,
              h.prefix(7).lowercased() == "bearer " else { return nil }
        let t = h.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Compares every byte whatever the first mismatch, so response timing does not reveal how much of a guess
    /// was right.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0))
        }
        return diff == 0
    }

    /// True when `header` carries exactly `token` (nil token = the bridge has no credentials: nothing passes).
    static func authorized(_ header: String?, token: String?) -> Bool {
        guard let token = token, let presented = bearer(header) else { return false }
        return constantTimeEquals(presented, token)
    }

    /// `Origin` must be absent or on the allowlist (blocks DNS-rebinding pages in a browser).
    static func originAllowed(_ origin: String?, allowlist: [String]) -> Bool {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces), !origin.isEmpty else { return true }
        let normal = { (s: String) -> String in
            var s = s.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return allowlist.contains { normal($0) == normal(origin) }
    }

    /// The checks every request passes before routing (docs/AI.md §9.1), in order: remote address in the allowed
    /// networks (403), bearer token (401; `/health` needs none), `Origin` absent or allowlisted (403). nil = allowed.
    /// With `head` nil only the address is checked. Thread-safe (settings and Keychain are): the server runs it on
    /// its queue at accept and again on the head alone, before any body byte is buffered.
    static func refusal(_ head: HTTPRequest?, remote: [UInt8]?, settings: SettingsStore) -> HTTPResponse? {
        guard BridgeNetworks.allows(remote, in: BridgeNetworks.parse(settings.get(BridgeSettings.networks))) else {
            return HTTPResponse.failure(403, "this address is not in the bridge's allowed networks")
        }
        guard let head = head, head.normalizedPath != "/health" else { return nil }
        guard authorized(head.header("authorization"), token: BridgeSecrets.token()) else {
            return HTTPResponse.failure(401, "missing or wrong bearer token (Authorization: Bearer nib_…)",
                                        headers: [("WWW-Authenticate", "Bearer")])
        }
        guard originAllowed(head.header("origin"), allowlist: settings.get(BridgeSettings.origins)) else {
            return HTTPResponse.failure(403, "this Origin is not allowed")
        }
        return nil
    }
}

/// IPv4 / IPv6 addresses as raw bytes (4 or 16). IPv4-mapped IPv6 (::ffff:a.b.c.d) is folded to IPv4.
enum BridgeIP {
    static func parse(_ string: String) -> [UInt8]? {
        let s = string.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if !s.contains(":") {
            return IPv4Address(s).map { [UInt8]($0.rawValue) }
        }
        let noZone = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        return IPv6Address(noZone).map { normalize([UInt8]($0.rawValue)) }
    }

    static func normalize(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return Array(bytes[12..<16])
        }
        return bytes
    }
}

/// One allowed network, e.g. "192.168.0.0/16", "fd7a:115c:a1e0::/48"; a bare address is a single host.
struct CIDR: Equatable {
    let bytes: [UInt8]
    let prefix: Int

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), var host = parts.first.map(String.init), !host.isEmpty else { return nil }
        if !host.contains(":") {
            // "10/8", "172.16/12": pad the short IPv4 forms used in the docs.
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(octets.count) else { return nil }
            host += String(repeating: ".0", count: 4 - octets.count)
        }
        guard let bytes = BridgeIP.parse(host) else { return nil }
        let bits = bytes.count * 8
        var prefix = bits
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...bits).contains(p) else { return nil }
            prefix = p
        }
        self.bytes = bytes
        self.prefix = prefix
    }

    func contains(_ address: [UInt8]) -> Bool {
        let a = BridgeIP.normalize(address)
        guard a.count == bytes.count else { return false }
        var remaining = prefix
        for i in 0..<bytes.count where remaining > 0 {
            let mask: UInt8 = remaining >= 8 ? 0xff : UInt8(truncatingIfNeeded: 0xff << (8 - remaining))
            if a[i] & mask != bytes[i] & mask { return false }
            remaining -= 8
        }
        return true
    }
}

/// The networks a client may connect from (setting `security.bridge.networks`, user only).
enum BridgeNetworks {
    /// Loopback, RFC 1918, Tailscale (100.64/10, fd7a:115c:a1e0::/48) and link-local.
    static let defaults = [
        "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16",
        "::1/128", "fd7a:115c:a1e0::/48", "fe80::/10"
    ]

    /// Unparseable entries are skipped (the settings page validates what the user types).
    static func parse(_ list: [String]) -> [CIDR] { list.compactMap(CIDR.init) }

    static func allows(_ address: [UInt8]?, in networks: [CIDR]) -> Bool {
        guard let address = address else { return false }
        return networks.contains { $0.contains(address) }
    }
}
