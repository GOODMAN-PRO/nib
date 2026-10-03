import Foundation
import Darwin
import SwiftUI
import UIKit
import NibContracts
import NibDesign

enum ProviderPreset: String, CaseIterable, Identifiable {
    case claudeSubscription, chatGPTSubscription, anthropic, openAI, openRouter, ollama, lmStudio, custom, nibHTTP
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeSubscription: return String(localized: "Claude — your subscription")
        case .chatGPTSubscription: return String(localized: "ChatGPT — your subscription")
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .custom: return String(localized: "Custom OpenAI-compatible")
        case .nibHTTP: return String(localized: "Nib HTTP")
        }
    }
    var kind: AIProviderKind {
        switch self { case .anthropic: return .anthropic; case .nibHTTP, .claudeSubscription, .chatGPTSubscription: return .nibHTTP; default: return .openAICompatible }
    }
    var baseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .custom, .nibHTTP, .claudeSubscription, .chatGPTSubscription: return ""
        }
    }
}

struct ProviderDraft {
    var id = UUID()
    var name = ""
    var kind = AIProviderKind.openAICompatible
    var baseURL = ""
    var model = ""
    var supportsVision = true
    var supportsTools = true
    var maxOutputTokens = "4096"
    var transcriptionModel = ""
    var imageModel = ""
    var headers = ""
    var contextTokens: Int?

    init(preset: ProviderPreset) { apply(preset) }
    init(config: AIProviderConfig) {
        id = config.id; name = config.name; kind = config.kind; baseURL = config.baseURL.absoluteString
        model = config.model; supportsVision = config.supportsVision; supportsTools = config.supportsTools
        maxOutputTokens = String(config.maxOutputTokens); transcriptionModel = config.transcriptionModel ?? ""
        imageModel = config.imageModel ?? ""; contextTokens = config.contextTokens
        headers = config.extraHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
    mutating func apply(_ preset: ProviderPreset) {
        name = preset.title; kind = preset.kind; baseURL = preset.baseURL; model = ""
        transcriptionModel = ""; imageModel = ""
        if preset == .claudeSubscription { model = "claude-sonnet" }
        if preset == .chatGPTSubscription { model = "chatgpt" }
        headers = preset == .openRouter ? "HTTP-Referer: https://github.com/GOODMAN-PRO/nib\nX-Title: Nib"
            : ([ProviderPreset.claudeSubscription, .chatGPTSubscription].contains(preset) ? "X-Nib-Subscription: 1" : "")
    }
    func config() throws -> AIProviderConfig {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProviderValidation.invalid("Enter a valid base URL.", "baseURL")
        }
        guard let tokens = Int(maxOutputTokens) else { throw ProviderValidation.invalid("Enter a whole token count.", "maxOutputTokens") }
        return try ProviderValidation.validate(AIProviderConfig(id: id, name: name, kind: kind, baseURL: url, model: model,
            extraHeaders: try ProviderValidation.headers(headers), supportsVision: supportsVision, supportsTools: supportsTools,
            contextTokens: contextTokens, maxOutputTokens: tokens,
            transcriptionModel: transcriptionModel, imageModel: imageModel))
    }
}

enum ProviderValidation {
    static func invalid(_ message: String, _ field: String) -> NibError {
        NibError(.invalidParams, message, path: "$." + field, hint: "review this field in Settings › AI and save again")
    }
    static func validate(_ input: AIProviderConfig) throws -> AIProviderConfig {
        var c = input
        c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
        c.model = c.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.name.isEmpty, c.name.count <= 200 else { throw invalid("Give the provider a name of at most 200 characters.", "name") }
        guard ["https", "http"].contains(c.baseURL.scheme?.lowercased() ?? ""),
              let host = c.baseURL.host, !host.isEmpty, !host.contains("<"), !host.contains(">"),
              c.baseURL.absoluteString.count <= 2048 else { throw invalid("Use an http:// or https:// base URL with a host.", "baseURL") }
        guard c.baseURL.user == nil, c.baseURL.password == nil, c.baseURL.fragment == nil else {
            throw invalid("Credentials belong in the API key field, never in the base URL.", "baseURL")
        }
        let secretQueries = ["key", "api_key", "apikey", "api-key", "token", "access_token", "password", "secret", "authorization"]
        if URLComponents(url: c.baseURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
            secretQueries.contains($0.name.lowercased())
        }) == true { throw invalid("Credentials belong in the API key field, never in the base URL.", "baseURL") }
        guard (1...1_000_000).contains(c.maxOutputTokens) else { throw invalid("Choose an output limit from 1 to 1,000,000 tokens.", "maxOutputTokens") }
        guard c.model.count <= 256 else { throw invalid("The model id is too long.", "model") }
        c.transcriptionModel = c.transcriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        c.imageModel = c.imageModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.transcriptionModel?.isEmpty == true { c.transcriptionModel = nil }
        if c.imageModel?.isEmpty == true { c.imageModel = nil }
        guard (c.transcriptionModel?.count ?? 0) <= 256, (c.imageModel?.count ?? 0) <= 256 else {
            throw invalid("Use model ids of at most 256 characters.", "model")
        }
        let characters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let secretNames = ["authorization", "proxy-authorization", "x-api-key", "api-key", "apikey", "x-auth-token", "cookie", "set-cookie"]
        var names = Set<String>()
        var headers: [String: String] = [:]
        guard c.extraHeaders.count <= 32 else { throw invalid("Use at most 32 extra headers.", "extraHeaders") }
        for (raw, value) in c.extraHeaders {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ characters.contains($0) }),
                  names.insert(name.lowercased()).inserted else { throw invalid("Use unique valid header names.", "extraHeaders") }
            guard !secretNames.contains(name.lowercased()) else {
                throw invalid("Extra headers are stored unencrypted. Put credentials in the API key field.", "extraHeaders")
            }
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw invalid("Header values cannot contain line breaks or control characters.", "extraHeaders")
            }
            headers[name] = value.trimmingCharacters(in: .whitespaces)
        }
        guard headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 4096 else {
            throw invalid("Extra headers must fit within 4 KB.", "extraHeaders")
        }
        c.extraHeaders = headers
        return c
    }
    static func rejectKeyInMetadata(_ config: AIProviderConfig, key: String?) throws {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), key.count >= 8 else { return }
        let metadata = [config.name, config.baseURL.absoluteString, config.model,
                        config.transcriptionModel ?? "", config.imageModel ?? ""]
                       + Array(config.extraHeaders.keys) + Array(config.extraHeaders.values)
        if metadata.contains(where: { $0.contains(key) }) {
            throw NibError(.invalidParams, "The API key must not appear in provider metadata.",
                           hint: "remove it from the URL, model, name and extra headers")
        }
    }
    static func headers(_ text: String) throws -> [String: String] {
        var out: [String: String] = [:]
        var names = Set<String>()
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw invalid("Enter each header as Name: value on its own line.", "extraHeaders") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard names.insert(name.lowercased()).inserted else { throw invalid("Each extra header needs a unique name.", "extraHeaders") }
            out[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }
    static func warnsAboutHTTP(_ url: URL, hasKey: Bool) -> Bool {
        hasKey && url.scheme?.lowercased() == "http" && !isPrivateHost(url.host ?? "")
    }
    /// No DNS lookup: an unrecognised host is conservatively treated as public.
    static func isPrivateHost(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr)
            let a = n >> 24, b = (n >> 16) & 255
            return a == 10 || a == 127 || (a == 100 && (64...127).contains(b)) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
            return isPrivateHost(bytes.suffix(4).map(String.init).joined(separator: "."))
        }
        return false
    }
}

@MainActor
struct ProviderEditorView: View {
    let app: NibApp
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderDraft
    @State private var preset = ProviderPreset.anthropic
    @State private var key = ""
    @State private var replaceKey = false
    @State private var hasCredentials: Bool
    @State private var credentialsMissing: Bool
    @State private var savedConfig: AIProviderConfig?
    @State private var models: [String] = []
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var deleteArmed = false
    private let isNew: Bool

    init(app: NibApp, row: ProviderRow? = nil) {
        self.app = app; isNew = row == nil
        _draft = State(initialValue: row.map { ProviderDraft(config: $0.config) } ?? ProviderDraft(preset: .anthropic))
        _hasCredentials = State(initialValue: row?.hasCredentials ?? false)
        _credentialsMissing = State(initialValue: row?.credentialsMissing ?? false)
        _savedConfig = State(initialValue: row?.config)
    }
    private var warning: Bool {
        guard let url = URL(string: draft.baseURL) else { return false }
        return ProviderValidation.warnsAboutHTTP(url, hasKey: !key.isEmpty || (!replaceKey && hasCredentials))
    }
    private var clean: Bool { (try? draft.config()) == savedConfig && key.isEmpty && !replaceKey }

    var body: some View {
        Form {
            if isNew && savedConfig == nil {
                Section {
                    Picker(String(localized: "Preset"), selection: $preset) {
                        ForEach(ProviderPreset.allCases.filter { $0 != .claudeSubscription && $0 != .chatGPTSubscription }) { Text($0.title).tag($0) }
                    }
                    .frame(minHeight: NibMetrics.hitTarget)
                    .onChange(of: preset) { _, value in draft.apply(value); models = [] }
                }
            }
            Section {
                field(String(localized: "Name"), text: $draft.name)
                Picker(String(localized: "Protocol"), selection: $draft.kind) {
                    Text("Anthropic").tag(AIProviderKind.anthropic)
                    Text(String(localized: "OpenAI-compatible")).tag(AIProviderKind.openAICompatible)
                    Text(String(localized: "Nib HTTP")).tag(AIProviderKind.nibHTTP)
                }.frame(minHeight: NibMetrics.hitTarget)
                field(String(localized: "Base URL"), text: $draft.baseURL, keyboard: .URL)
                if preset == .ollama || preset == .lmStudio {
                    Text(String(localized: "For a server on another device, replace localhost with its private address or local hostname."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                }
            } header: { AISettingsHeader(String(localized: "Provider")) }
            Section {
                NibSecureField(text: $key, prompt: String(localized: "API key"))
                    .accessibilityLabel(String(localized: "API key, stored only in Keychain"))
                    .onChange(of: key) { _, value in if !value.isEmpty { replaceKey = true } }
                if hasCredentials {
                    NibToggle(String(localized: "Replace saved key"), isOn: $replaceKey)
                    Text(String(localized: "Leave replacement off to keep the saved key. An empty replacement removes it."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                }
                if credentialsMissing {
                    NibBanner(String(localized: "credentials missing — re-enter"), style: .warning)
                }
                if warning {
                    NibBanner(String(localized: "This key will be sent without encryption. The HTTP address is not recognised as private. Use HTTPS to protect your credentials."), style: .warning)
                }
            } header: { AISettingsHeader(String(localized: "Credentials")) }
            Section {
                field(String(localized: "Chat model"), text: $draft.model)
                if !models.isEmpty {
                    Picker(String(localized: "Available models"), selection: $draft.model) {
                        ForEach(Array(Set(models + [draft.model])).sorted(), id: \.self) { Text($0.isEmpty ? String(localized: "Enter a model id") : $0).tag($0) }
                    }.frame(minHeight: NibMetrics.hitTarget)
                }
                NibButton(String(localized: "Load models"), symbol: .retry) { runConnection(modelsOnly: true) }
                    .disabled(busy || !clean || savedConfig == nil)
                field(String(localized: "Transcription model"), text: $draft.transcriptionModel)
                field(String(localized: "Image model"), text: $draft.imageModel)
                field(String(localized: "Maximum output tokens"), text: $draft.maxOutputTokens, keyboard: .numberPad)
                NibToggle(String(localized: "Accepts images"), isOn: $draft.supportsVision)
                NibToggle(String(localized: "Supports tools"), isOn: $draft.supportsTools)
            } header: { AISettingsHeader(String(localized: "Models")) }
            Section {
                NibField(text: $draft.headers, prompt: String(localized: "Name: value"), lines: 3...8)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(String(localized: "Extra headers, one name and value per line"))
            } header: { AISettingsHeader(String(localized: "Extra headers")) }
              footer: { Text(String(localized: "Use non-secret headers only. Credentials always belong in the API key field.")) }
            Section {
                NibButton(String(localized: "Save provider"), symbol: .checkmark, kind: .primary,
                          shortcut: KeyboardShortcut("s", modifiers: .command)) { save() }
                    .disabled(busy)
                NibButton(String(localized: "Test connection"), symbol: .network,
                          shortcut: KeyboardShortcut("t", modifiers: [.command, .shift])) { runConnection(modelsOnly: false) }
                    .disabled(busy || !clean || savedConfig == nil)
                if busy { ProgressView().accessibilityLabel(String(localized: "Contacting provider")) }
                if let message {
                    if failed { NibBanner(message, style: .warning) }
                    else { Text(message).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary) }

                }
            } footer: { Text(String(localized: "Save changes before loading models or testing. A test sends only a tiny completion, without notes or tools.")) }
            if savedConfig != nil {
                Section {
                    if deleteArmed {
                        Text(String(localized: "Delete this provider and its saved key?"))
                        NibButton(String(localized: "Delete provider and key"), symbol: .trash, kind: .destructive) { delete() }
                        NibButton(String(localized: "Keep provider"), kind: .plain) { deleteArmed = false }
                    } else {
                        NibButton(String(localized: "Delete provider"), symbol: .trash, kind: .destructivePlain) { deleteArmed = true }
                    }
                }
            }
        }
        .font(NibFont.body)
        .scrollContentBackground(.hidden)
        .background(NibColor.groupedBackground)
        .navigationTitle(savedConfig?.name ?? String(localized: "Add provider"))
        .onChange(of: message) { _, value in
            if let value, UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: value) }
        }
        .onDisappear { key = ""; operation?.cancel() }
        .disabled(busy)
    }
    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(title).font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary).accessibilityHidden(true)
            NibField(text: text, prompt: title).keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title)
        }
    }
    private func save() {
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let config = try draft.config()
                guard let runtime = app.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self) else {
                    throw NibError.unavailable("Provider settings are unavailable. Open Settings again.")
                }
                try await runtime.saveFromSettings(config, key: replaceKey || !key.isEmpty ? key : nil, app: app)
                savedConfig = config; draft = ProviderDraft(config: config)
                key = ""; replaceKey = false
                let result = try await app.bus.execute(CommandIDs.aiProviderList, ["id": .string(config.id.uuidString)])
                let rows = try result.decode(ProviderList.Output.self)
                if let row = rows.providers.first(where: { $0.id == config.id }) {
                    hasCredentials = row.hasCredentials; credentialsMissing = row.credentialsMissing
                }
                key = ""; replaceKey = false
                message = String(localized: "Provider saved."); failed = false
            } catch is CancellationError { }
              catch { message = NibError.wrap(error).message; failed = true }
        }
    }
    private func runConnection(modelsOnly: Bool) {
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let params: JSONValue = ["id": .string(draft.id.uuidString), "listModels": .bool(modelsOnly)]
                let result = try await app.bus.execute(CommandIDs.aiProviderTest, params)
                let output = try result.decode(ProviderTest.Output.self)
                if modelsOnly { models = output.models ?? []; message = models.isEmpty ? String(localized: "The provider listed no models. Enter a model id manually.") : String(localized: "Models loaded.") }
                else { message = String(localized: "Connection successful.") }
                failed = false
            } catch is CancellationError { }
              catch { message = NibError.wrap(error).message; failed = true }
        }
    }
    private func delete() {
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await app.bus.execute(CommandIDs.aiProviderDelete, ["id": .string(draft.id.uuidString)])
                key = ""; dismiss()
            } catch is CancellationError { }
              catch { message = NibError.wrap(error).message; failed = true }
        }
    }
}
