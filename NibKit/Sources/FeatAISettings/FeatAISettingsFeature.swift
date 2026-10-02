import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatAISettingsFeature: NibFeature {
    public static let id = "aisettings"

    public static func register(_ app: NibApp) {
        app.services.set(ProviderSettingsRuntime(), for: ProviderSettingsRuntime.serviceKey)
        app.commands.register(ProviderList.self)
        app.commands.register(ProviderSave.self)
        app.commands.register(ProviderActivate.self)
        app.commands.register(ProviderDelete.self)
        app.commands.register(ProviderTest.self)
        app.bus.hooks.register(CommandHookDescriptor(id: "aisettings.noCommandSecrets", owner: id,
                                                     commands: [CommandIDs.aiProviderSave]) { _, params in
            let forbidden = ["apikey", "api_key", "key", "token", "secret", "password"]
            if params.objectValue?.keys.contains(where: { forbidden.contains($0.lowercased()) }) == true {
                throw NibError(.permissionDenied, "API keys can only be entered in Settings › AI.")
            }
            return nil
        })
        app.settings.declarePrefix(AISettingsKeys.credentialPrefix, synced: false,
                                  summary: "Whether this provider had credentials saved, never the credentials.",
                                  owner: id, schema: .bool(), readOnly: true)
        // F084 also declares this shared name. Identical routing and schema keep either registration order valid.
        app.settings.declare(AISettingsKeys.directTools, summary: "Command ids offered directly to the AI model.",
                             owner: id, schema: .arr(.str()))
        app.settings.declare(AISettingsKeys.maxSteps, summary: "Maximum tool rounds in an AI turn.",
                             owner: id, schema: .int(min: 1, max: 100))
        var page = SettingsPageDescriptor(id: "settings.ai", title: String(localized: "AI"),
                                          icon: NibSymbol.assistant.name, section: .ai, order: 0, owner: id) {
            AnyView(ProviderListView(app: $0))
        }
        page.keywords = ["AI", "providers", "privacy", "API key", "Ollama", "LM Studio", "models"]
        app.ui.settingsPages.register(page)
        // AI has several pages (subscriptions and other features' settings). Keep provider
        // creation directly available in that section index as well as the provider list.
        app.ui.settingsPages.register(SettingsPageDescriptor(id: "settings.ai.addProvider",
            title: String(localized: "Add provider"), icon: NibSymbol.plus.name, section: .ai, order: 3, owner: id) {
            AnyView(ProviderEditorView(app: $0))
        })
        for (preset, pageID) in [(ProviderPreset.claudeSubscription, "settings.ai.claude"), (.chatGPTSubscription, "settings.ai.chatgpt")] {
            app.ui.settingsPages.register(SettingsPageDescriptor(id: pageID, title: preset.title,
                icon: NibSymbol.assistant.name, section: .ai, order: preset == .claudeSubscription ? 1 : 2, owner: id) {
                AnyView(SubscriptionSetupView(app: $0, preset: preset))
            })
        }
    }
}

enum AISettingsKeys {
    static let credentialPrefix = "aisettings.credentials."
    static let directTools = SettingKey(NibSettings.aiDirectToolsName, default: NibSettings.defaultAIDirectTools, synced: true)
    // Contract gap: NibSettings.aiMaxSteps should own this synced key and F084 AgentService
    // should clamp AIRequest.maxSteps to it. F086 cannot change either owner.
    static let maxSteps = SettingKey("ai.maxSteps", default: 40, synced: true)
    static func hadKey(_ id: UUID) -> SettingKey<Bool> {
        SettingKey(credentialPrefix + id.uuidString, default: false)
    }
}

/// Secrets are staged by the native Settings page only, keyed to one invocation's fresh group.
/// Neither JSON params, command results, hooks nor settings ever contain the key.
@MainActor
final class ProviderSettingsRuntime {
    static let serviceKey = "aisettings.runtime"
    struct Pending { let config: AIProviderConfig; let key: String }
    private var pending: [String: Pending] = [:]

    func saveFromSettings(_ config: AIProviderConfig, key: String?, app: NibApp) async throws {
        let config = try ProviderValidation.validate(config)
        try ProviderValidation.rejectKeyInMetadata(config, key: key ?? Keychain.getString(
            service: AIProviderConfig.keychainService, account: config.keychainAccount))
        let group = UUID().uuidString
        if let key { pending[group] = Pending(config: config, key: key) }
        defer { pending[group] = nil }
        _ = try await app.bus.execute(Invocation(command: CommandIDs.aiProviderSave,
                                                params: try JSONValue.from(ProviderSave.Params(config)),
                                                principal: .user, session: app.services.sessions.active, group: group))
    }

    func key(for ctx: CommandContext, config: AIProviderConfig) throws -> String? {
        guard ctx.principal.isUser, let entry = pending[ctx.group] else { return nil }
        guard entry.config == config else {
            throw NibError(.permissionDenied, "The provider changed before its credentials could be saved.",
                           hint: "review the provider and save again")
        }
        return entry.key
    }
}

@MainActor
func providerStore(_ ctx: CommandContext) throws -> AIProviderStore {
    guard let store = ctx.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self) else {
        throw NibError.unavailable("AI providers are unavailable. Try opening Settings again.")
    }
    return store
}

func providerID(_ text: String) throws -> UUID {
    guard let id = UUID(uuidString: text) else {
        throw NibError(.invalidParams, "The provider id must be a UUID.", path: "$.id",
                       hint: "call ai.provider.list for provider ids")
    }
    return id
}

struct ProviderRow: Codable, Identifiable {
    var config: AIProviderConfig
    var credentialsMissing: Bool
    var hasCredentials: Bool
    var id: UUID { config.id }
}

struct ProviderList: NibCommand {
    struct Params: Codable { var cursor: Int?; var id: String? }
    struct Output: Codable { var providers: [ProviderRow]; var activeID: UUID?; var cursor: Int?; var truncated: Bool }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.aiProviderList, title: "List AI Providers",
        summary: "List configured AI providers and credential status, never their keys; cursor continues a long list.",
        params: .obj(["cursor": .int(min: 0), "id": .str()]), examples: [[:]], effect: .read, target: .app)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let store = try providerStore(ctx)
        let id = try p.id.map(providerID)
        let configs = store.configs.filter { id == nil || $0.id == id }
        let start = min(p.cursor ?? 0, configs.count)
        var rows: [ProviderRow] = []
        var size = 0
        for config in configs.dropFirst(start) {
            let hasKey = !(Keychain.getString(service: AIProviderConfig.keychainService,
                                             account: config.keychainAccount) ?? "").isEmpty
            // Contract gap: AIProviderStore.credentialsMissing(_:) should expose its persisted
            // hasKey marker. Repair our device marker whenever credentials are available.
            if !ctx.dryRun && hasKey && !ctx.services.settings.get(AISettingsKeys.hadKey(config.id)) {
                ctx.services.settings.set(AISettingsKeys.hadKey(config.id), true)
            }
            let row = ProviderRow(config: config,
                                  credentialsMissing: ctx.services.settings.get(AISettingsKeys.hadKey(config.id)) && !hasKey,
                                  hasCredentials: hasKey)
            let bytes = try JSONEncoder().encode(row).count
            if !rows.isEmpty && size + bytes > 16_000 { break }
            rows.append(row)
            size += bytes
        }
        let next = start + rows.count
        return Output(providers: rows, activeID: store.activeID, cursor: next < configs.count ? next : nil,
                      truncated: next < configs.count)
    }
}

struct ProviderSave: NibCommand {
    struct Params: Codable {
        var id: String?
        var name: String
        var kind: AIProviderKind
        var baseURL: String
        var model: String
        var extraHeaders: [String: String]?
        var supportsVision: Bool?
        var supportsTools: Bool?
        var maxOutputTokens: Int?
        var transcriptionModel: String?
        var imageModel: String?

        init(_ c: AIProviderConfig) {
            id = c.id.uuidString; name = c.name; kind = c.kind; baseURL = c.baseURL.absoluteString; model = c.model
            extraHeaders = c.extraHeaders; supportsVision = c.supportsVision; supportsTools = c.supportsTools
            maxOutputTokens = c.maxOutputTokens; transcriptionModel = c.transcriptionModel ?? ""; imageModel = c.imageModel ?? ""
        }

        func config(existing: AIProviderConfig?) throws -> AIProviderConfig {
            guard let url = URL(string: baseURL) else { throw ProviderValidation.invalid("Enter a valid base URL.", "baseURL") }
            var c = AIProviderConfig(id: try id.map(providerID) ?? UUID(), name: name, kind: kind, baseURL: url,
                                    model: model, extraHeaders: extraHeaders ?? existing?.extraHeaders ?? [:],
                                    supportsVision: supportsVision ?? existing?.supportsVision ?? true,
                                    supportsTools: supportsTools ?? existing?.supportsTools ?? true,
                                    contextTokens: existing?.contextTokens,
                                    maxOutputTokens: maxOutputTokens ?? existing?.maxOutputTokens ?? 4096,
                                    transcriptionModel: transcriptionModel ?? existing?.transcriptionModel,
                                    imageModel: imageModel ?? existing?.imageModel)
            c = try ProviderValidation.validate(c)
            return c
        }
    }
    struct Output: Codable { var id: UUID }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.aiProviderSave, title: "Save AI Provider",
        summary: "Add or update provider configuration. Keys can only be entered in the native Settings page.",
        params: .obj(["id": .str(), "name": .str(), "kind": .str(choices: AIProviderKind.allCases.map(\.rawValue)),
                      "baseURL": .str(), "model": .str(), "extraHeaders": .anything("Object of non-secret string headers"),
                      "supportsVision": .bool(), "supportsTools": .bool(), "maxOutputTokens": .int(min: 1, max: 1_000_000),
                      "transcriptionModel": .str(), "imageModel": .str()], required: ["name", "kind", "baseURL", "model"]),
        examples: [["name": "Local model", "kind": "openAICompatible", "baseURL": "http://localhost:11434/v1", "model": ""]],
        effect: .session, target: .app, sensitive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let store = try providerStore(ctx)
        let id = try p.id.map(providerID)
        let existing = store.configs.first { $0.id == id }
        let config = try p.config(existing: existing)
        let runtime = ctx.services.get(ProviderSettingsRuntime.serviceKey, as: ProviderSettingsRuntime.self)
        let key = try runtime?.key(for: ctx, config: config)
        let savedKey = Keychain.getString(service: AIProviderConfig.keychainService, account: config.keychainAccount)
        if !ctx.principal.isUser, let existing, savedKey?.isEmpty == false,
           existing.kind != config.kind || existing.baseURL.scheme?.lowercased() != config.baseURL.scheme?.lowercased()
            || existing.baseURL.host?.lowercased() != config.baseURL.host?.lowercased()
            || existing.baseURL.port != config.baseURL.port {
            throw NibError(.permissionDenied, "A provider with a saved key cannot be redirected by this caller.",
                           hint: "change the endpoint of a provider with a saved key in Settings › AI")
        }
        try ProviderValidation.rejectKeyInMetadata(config, key: key ?? savedKey)
        if !ctx.dryRun {
            try store.save(config, apiKey: key)
            if let key {
                ctx.services.settings.set(AISettingsKeys.hadKey(config.id), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if Keychain.get(service: AIProviderConfig.keychainService, account: config.keychainAccount) != nil {
                ctx.services.settings.set(AISettingsKeys.hadKey(config.id), true)
            }
            ctx.ui?.setNeedsChromeUpdate()
        }
        return Output(id: config.id)
    }
}

struct ProviderActivate: NibCommand {
    struct Params: Codable { var id: String }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.aiProviderActivate, title: "Activate AI Provider", summary: "Make a configured provider the active AI endpoint.",
        params: .obj(["id": .str()], required: ["id"]), examples: [["id": "00000000-0000-0000-0000-000000000086"]],
        effect: .session, target: .app, sensitive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let store = try providerStore(ctx), id = try providerID(p.id)
        guard store.configs.contains(where: { $0.id == id }) else { throw NibError(.notFound, "AI provider not found.", hint: "call ai.provider.list") }
        if !ctx.dryRun {
            store.activeID = id
            ctx.ui?.setNeedsChromeUpdate()
            guard store.activeID == id else { throw NibError.unavailable("The active provider could not be saved. Try again.") }
        }
        return NoResult()
    }
}

struct ProviderDelete: NibCommand {
    typealias Params = ProviderActivate.Params
    static let descriptor = CommandDescriptor(
        id: CommandIDs.aiProviderDelete, title: "Delete AI Provider", summary: "Delete an AI provider and its saved Keychain credentials.",
        params: .obj(["id": .str()], required: ["id"]), examples: [["id": "00000000-0000-0000-0000-000000000086"]],
        effect: .session, target: .app, destructive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let store = try providerStore(ctx), id = try providerID(p.id)
        guard store.configs.contains(where: { $0.id == id }) else { throw NibError(.notFound, "AI provider not found.", hint: "call ai.provider.list") }
        if !ctx.dryRun {
            // Contract gap: AIProviderStore.delete must throw on persistence failure; its
            // current nonthrowing contract cannot guarantee deletion survives relaunch.
            store.delete(id)
            guard !store.configs.contains(where: { $0.id == id }) else { throw NibError.unavailable("The provider could not be deleted. Try again.") }
            guard Keychain.get(service: AIProviderConfig.keychainService, account: id.uuidString) == nil else {
                throw NibError(.unavailable, "The saved key could not be removed from Keychain. Unlock the device and try again.")
            }
            ctx.services.settings.setJSON(AISettingsKeys.credentialPrefix + id.uuidString, nil)
            ctx.ui?.setNeedsChromeUpdate()
        }
        return NoResult()
    }
}

struct ProviderTest: NibCommand {
    struct Params: Codable { var id: String?; var listModels: Bool? }
    struct Output: Codable { var ok: Bool; var models: [String]? }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.aiProviderTest, title: "Test AI Connection",
        summary: "Send a tiny tool-free completion to a saved provider (active by default), or fetch model ids with listModels=true.",
        params: .obj(["id": .str(), "listModels": .bool()]), examples: [[:]], effect: .read, target: .app, sensitive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let store = try providerStore(ctx)
        guard let provider = store.provider(try p.id.map(providerID)) else {
            if p.id != nil { throw NibError(.notFound, "AI provider not found.", hint: "call ai.provider.list") }
            throw NibError.unavailable("Add an AI provider before testing a connection.")
        }
        if ctx.dryRun { return Output(ok: true, models: nil) }
        if p.listModels == true {
            return Output(ok: true, models: try await provider.listModels())
        }
        let request = ChatRequest(model: provider.config.model, system: "Reply with OK only.",
                                  messages: [ChatMessage(role: .user, parts: [.text("Connection test")])], tools: [], maxTokens: 8)
        var responded = false
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let text): responded = responded || !text.isEmpty
            case .stop: responded = true
            case .toolCall: throw NibError(.unsupported, "The provider returned a tool call during a tool-free test.")
            case .usage: break
            }
        }
        guard responded else { throw NibError.unavailable("The provider returned no response. Check the model and try again.") }
        return Output(ok: true, models: nil)
    }
}
