import Foundation

/// Shared by F090's authenticator and F091's pairing UI. Production always uses the
/// Keychain; only the explicit UI fixture launch uses its disposable container.
/// A failed Keychain write never falls back to a file. No token enters settings or logs.
public final class BridgeTokenStorage {
    public static let shared = BridgeTokenStorage(
        fixtureRoot: NibUITestMode.isEnabled ? NibUITestMode.rootURL : nil)

    private let fixtureRoot: URL?
    private let keychainRead: () -> String?
    private let keychainWrite: (String) -> Bool

    // Internal injection is for unit tests; callers cannot opt production into file storage.
    init(fixtureRoot: URL?,
         keychainRead: @escaping () -> String? = {
             Keychain.getString(service: BridgeNames.tokenService, account: BridgeNames.tokenAccount)
         },
         keychainWrite: @escaping (String) -> Bool = {
             Keychain.setString($0, service: BridgeNames.tokenService, account: BridgeNames.tokenAccount)
         }) {
        self.fixtureRoot = fixtureRoot
        self.keychainRead = keychainRead
        self.keychainWrite = keychainWrite
    }

    public func read() -> String? {
        let token: String?
        if let fixtureRoot {
            token = try? String(contentsOf: fixtureRoot.appendingPathComponent("bridge-token"), encoding: .utf8)
        } else {
            token = keychainRead()
        }
        return token.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func write(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        guard let fixtureRoot else { return keychainWrite(token) }
        do {
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try Data(token.utf8).write(to: fixtureRoot.appendingPathComponent("bridge-token"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
