import Foundation
import NibContracts

/// The configured providers (`ServiceKeys.aiProviders`). Configs and the active id live in
/// Application Support/Nib/ai-providers.json on this device; API keys live only in the Keychain (service
/// `AIProviderConfig.keychainService`, account = config id, this device only). The file records which configs had a
/// key saved, so a key that disappears (the app was re-signed with another team, which changes the Keychain access
/// group) is reported as "credentials missing" — calls fail with permission_denied and "re-enter the API key" —
/// instead of silently going out without one.
@MainActor
final class ProviderStore: AIProviderStore {
    struct Entry: Codable, Equatable {
        var config: AIProviderConfig
        /// A key was saved for this config.
        var hasKey: Bool
    }

    struct FileFormat: Codable {
        var version: Int
        var active: UUID?
        var providers: [Entry]
    }

    static let fileName = "ai-providers.json"
    static let formatVersion = 1
    /// Header names that carry credentials; they belong in the Keychain, not in the (unencrypted) extra headers.
    static let secretHeaderNames: Set<String> = ["authorization", "proxy-authorization", "x-api-key", "api-key"]

    let fileURL: URL?
    private let secretsOverride: SecretStore?
    private let sessionConfiguration: URLSessionConfiguration?
    private let timeouts: ProviderTimeouts
    private var entries: [Entry] = []
    private var active: UUID?
    private var isLoaded = false
    private var httpStorage: ProviderHTTP?
    var bridgeIsEnabled: (() -> Bool)?

    /// The app's store: Application Support on a device, a private temporary folder in hostless tests.
    convenience init() {
        let url: URL?
        if NibApp.isHostlessTest {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nib-aiproviders-" + UUID().uuidString, isDirectory: true)
                .appendingPathComponent(ProviderStore.fileName)
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Nib", isDirectory: true).appendingPathComponent(ProviderStore.fileName)
        }
        self.init(fileURL: url)
    }

    /// `secrets` nil = `Keychain.store` at the time of each access (the Harness swaps in InMemorySecretStore);
    /// `sessionConfiguration` lets tests route requests through a URLProtocol stub.
    init(fileURL: URL?, secrets: SecretStore? = nil, sessionConfiguration: URLSessionConfiguration? = nil,
         timeouts: ProviderTimeouts = .standard) {
        self.fileURL = fileURL
        secretsOverride = secrets
        self.sessionConfiguration = sessionConfiguration
        self.timeouts = timeouts
    }

    private var secrets: SecretStore { secretsOverride ?? Keychain.store }

    /// One URLSession for every provider this store hands out.
    var http: ProviderHTTP {
        if let h = httpStorage { return h }
        let h = ProviderHTTP(configuration: sessionConfiguration, timeouts: timeouts)
        httpStorage = h
        return h
    }

    // MARK: AIProviderStore

    var configs: [AIProviderConfig] {
        loadIfNeeded()
        return entries.map(\.config)
    }

    var activeID: UUID? {
        get {
            loadIfNeeded()
            return active
        }
        set {
            if let error = loadIfNeeded() {
                providerLog.error("activate ignored: \(error.description, privacy: .public)")
                return
            }
            guard newValue != active else { return }
            if let id = newValue, !entries.contains(where: { $0.config.id == id }) {
                providerLog.error("activate ignored: no provider \(id.uuidString, privacy: .public)")
                return
            }
            let previous = active
            active = newValue
            do {
                try persist()
            } catch {
                active = previous
                providerLog.error("activate not saved: \(NibError.wrap(error).description, privacy: .public)")
            }
        }
    }

    func save(_ config: AIProviderConfig, apiKey: String?) throws {
        if let error = loadIfNeeded() { throw error }
        let config = try ProviderStore.validated(config)
        let index = entries.firstIndex { $0.config.id == config.id }
        var hasKey = index.map { entries[$0].hasKey } ?? false
        var wroteKey = false
        if let apiKey = apiKey {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                _ = secrets.set(nil, service: AIProviderConfig.keychainService, account: config.keychainAccount)
                hasKey = false
            } else {
                guard key.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
                    throw NibError(.invalidParams, "The API key contains spaces or characters that cannot be sent to the provider.",
                                   path: "$.apiKey", hint: "paste the key again without quotes or spaces")
                }
                guard secrets.set(Data(key.utf8), service: AIProviderConfig.keychainService, account: config.keychainAccount) else {
                    throw NibError(.unavailable, "Nib could not save the API key to the Keychain.",
                                   hint: "unlock the device and try again")
                }
                hasKey = true
                wroteKey = true
            }
        }
        let before = (entries, active)
        let entry = Entry(config: config, hasKey: hasKey)
        if let i = index { entries[i] = entry } else { entries.append(entry) }
        if active == nil { active = config.id }
        do {
            try persist()
        } catch {
            (entries, active) = before
            if wroteKey && index == nil {
                _ = secrets.set(nil, service: AIProviderConfig.keychainService, account: config.keychainAccount)
            }
            throw NibError.wrap(error)
        }
    }

    func delete(_ id: UUID) {
        if let error = loadIfNeeded() {
            providerLog.error("delete ignored: \(error.description, privacy: .public)")
            return
        }
        _ = secrets.set(nil, service: AIProviderConfig.keychainService, account: id.uuidString)
        guard let i = entries.firstIndex(where: { $0.config.id == id }) else { return }
        entries.remove(at: i)
        if active == id { active = entries.first?.config.id }
        do {
            try persist()
        } catch {
            providerLog.error("delete not saved: \(NibError.wrap(error).description, privacy: .public)")
        }
    }

    func provider(_ id: UUID?) -> AIProvider? {
        loadIfNeeded()
        guard let target = id ?? active, let entry = entries.first(where: { $0.config.id == target }) else { return nil }
        return ProviderStore.makeProvider(entry.config, credential: credential(for: entry), http: http, bridgeAllowed: bridgeIsEnabled?() ?? true)
    }

    // MARK: Credentials

    /// True when a key was saved for the provider and the Keychain no longer has it.
    func credentialsMissing(_ id: UUID) -> Bool {
        loadIfNeeded()
        guard let entry = entries.first(where: { $0.config.id == id }) else { return false }
        return credential(for: entry) == .missing
    }

    private func credential(for entry: Entry) -> ProviderCredential {
        let data = secrets.get(service: AIProviderConfig.keychainService, account: entry.config.keychainAccount)
        if let key = data.map({ String(decoding: $0, as: UTF8.self) })?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return .key(key)
        }
        return entry.hasKey ? .missing : .none
    }

    static func makeProvider(_ config: AIProviderConfig, credential: ProviderCredential, http: ProviderHTTP, bridgeAllowed: Bool = true) -> AIProvider {
        switch config.kind {
        case .anthropic: return AnthropicProvider(config: config, credential: credential, http: http)
        case .nibHTTP: return NibHTTPProvider(config: config, credential: credential, http: http, bridgeAllowed: bridgeAllowed)
        default: return OpenAICompatibleProvider(config: config, credential: credential, http: http)
        }
    }

    // MARK: Validation

    /// The config as stored: trimmed names, http(s) base URL, positive token counts, header names and values that
    /// can go on the wire, and no credentials among the extra headers.
    static func validated(_ input: AIProviderConfig) throws -> AIProviderConfig {
        var c = input
        c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.name.isEmpty else {
            throw NibError(.invalidParams, "The provider needs a name.", path: "$.name", hint: "give the provider a name")
        }
        guard let scheme = c.baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.baseURL.host, !host.isEmpty else {
            throw NibError(.invalidParams, "The base URL must be an http:// or https:// address.", path: "$.baseURL",
                           hint: "use an address like https://api.anthropic.com or http://<host>:11434/v1")
        }
        c.model = c.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.maxOutputTokens > 0 else {
            throw NibError(.invalidParams, "maxOutputTokens must be at least 1.", path: "$.maxOutputTokens")
        }
        if let context = c.contextTokens, context <= 0 {
            throw NibError(.invalidParams, "contextTokens must be at least 1.", path: "$.contextTokens")
        }
        c.transcriptionModel = c.transcriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.transcriptionModel?.isEmpty == true { c.transcriptionModel = nil }
        c.imageModel = c.imageModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.imageModel?.isEmpty == true { c.imageModel = nil }
        let tchar = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var headers: [String: String] = [:]
        for (rawName, value) in c.extraHeaders {
            let name = rawName.trimmingCharacters(in: .whitespaces)
            let path = "$.extraHeaders." + name
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tchar.contains($0) }) else {
                throw NibError(.invalidParams, "“\(rawName)” is not a valid header name.", path: path)
            }
            guard !secretHeaderNames.contains(name.lowercased()) else {
                throw NibError(.invalidParams, "\(name) carries a credential; extra headers are stored unencrypted.", path: path,
                               hint: "put the key in the API key field, which is kept in the Keychain")
            }
            guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\u{0}" }) else {
                throw NibError(.invalidParams, "The value of \(name) contains a line break.", path: path)
            }
            headers[name] = value.trimmingCharacters(in: .whitespaces)
        }
        c.extraHeaders = headers
        return c
    }

    // MARK: File

    /// Reads the file once. A missing file is an empty list; an unreadable one (data protection before the first
    /// unlock) is retried on the next access and blocks writes, so it is never overwritten unread; a corrupt one is
    /// moved aside.
    @discardableResult
    private func loadIfNeeded() -> NibError? {
        if isLoaded { return nil }
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            isLoaded = true
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            providerLog.error("provider list unreadable: \(error.localizedDescription, privacy: .public)")
            return NibError(.unavailable, "Nib could not read the list of AI providers.", hint: "unlock the device and try again")
        }
        isLoaded = true
        guard let json = JSONWire.parse(data), let list = json["providers"]?.arrayValue else {
            providerLog.error("provider list is corrupt; moved aside")
            let aside = url.deletingLastPathComponent().appendingPathComponent("ai-providers.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
        var loaded: [Entry] = []
        for raw in list {
            guard let entry = try? raw.decode(Entry.self) else {
                providerLog.error("skipped a provider entry that does not decode")
                continue
            }
            if !loaded.contains(where: { $0.config.id == entry.config.id }) { loaded.append(entry) }
        }
        entries = loaded
        if let s = json["active"]?.stringValue, let id = UUID(uuidString: s), loaded.contains(where: { $0.config.id == id }) {
            active = id
        }
        return nil
    }

    private func persist() throws {
        guard let url = fileURL else { return }
        guard isLoaded else {
            throw NibError(.unavailable, "Nib could not read the list of AI providers.", hint: "unlock the device and try again")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(FileFormat(version: ProviderStore.formatVersion, active: active, providers: entries))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw NibError(.unavailable, "Nib could not save the list of AI providers: \(error.localizedDescription)",
                           hint: "check the free storage on this device")
        }
    }
}
