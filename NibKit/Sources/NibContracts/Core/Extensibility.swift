import Foundation

/// Keys for services shared through `NibServices.set(_:for:)` / `get(_:as:)` (typed by the protocols below).
public enum ServiceKeys {
    /// `PluginRuntimeProviding` (Plugin Runtime feature).
    public static let pluginRuntime = "plugins.runtime"
    /// `PluginHosting` (Plugin Host feature).
    public static let pluginHost = "plugins.host"
    /// `PluginPanelFactory` (Plugin Panels feature).
    public static let pluginPanels = "plugins.panels"
    /// `AIProviderStore` (AI Providers feature).
    public static let aiProviders = "ai.providers"
    /// `CollabTransport` implementations.
    public static let collabMultipeer = "collab.transport.multipeer"
    public static let collabRelay = "collab.transport.relay"
}

// MARK: - Plugin manifest (see docs/PLUGIN_API.md)
// These types are built by decoding manifest JSON (tests: `PluginManifest.fixture(...)` in NibTesting).

public struct PluginNetwork: Codable, Equatable {
    /// Hostnames the plugin (and its panels) may reach with the "network" permission.
    public var hosts: [String]
    public init(hosts: [String]) { self.hosts = hosts }
}

public struct PluginCommandContribution: Codable, Equatable {
    /// Must start with the plugin id: "<pluginId>.<name>".
    public var id: String
    public var title: String
    public var summary: String
    /// JSON Schema of the params (flat subset recommended).
    public var params: JSONValue?
    /// "read" | "session" | "edit" | "library" | "irreversible" (default "edit").
    public var effect: String?
    /// "document" | "library" | "app" (default "document").
    public var target: String?
    public var destructive: Bool?
    public var examples: [JSONValue]?
    /// Exposed to the in-app AI (default true) and the MCP bridge (default true).
    public var ai: Bool?
    public var bridge: Bool?
    /// Offered to the AI as its own tool instead of only via nib_run.
    public var aiDirect: Bool?
    /// Allows handlers to run up to 300 s instead of 30 s.
    public var longRunning: Bool?
}

public struct PluginWhen: Codable, Equatable {
    /// Item kinds that must all be in the selection (e.g. ["stroke"]).
    public var selectionKinds: [String]?
    public var minSelection: Int?
    public var docKinds: [String]?
}

public struct PluginMenuContribution: Codable, Equatable {
    /// A `MenuLocation` raw value, e.g. "objectMenu", "documentMore", "libraryItem".
    public var location: String
    public var command: String
    public var title: String?
    public var icon: String?
    public var when: PluginWhen?
}

public struct PluginToolbarContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String
    /// "tools" | "accessories" (default "accessories").
    public var group: String?
    public var command: String?
    /// A plugin canvas tool id (from `tools`).
    public var tool: String?
}

public struct PluginToolContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    /// "stroke" (pts on lift) | "tap" (point) | "rect" (drag rectangle).
    public var input: String
    /// "ink" | "lasso" | "none" (host-drawn preview).
    public var preview: String?
    public var sticky: Bool?
    /// Command invoked with {page, pts, fmt, bbox} | {page, point} | {page, rect}.
    public var command: String
}

public struct PluginPanelContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    /// Path of the HTML file inside the plugin folder.
    public var entry: String
    /// A `PanelPlacement` raw value (default "floating").
    public var placement: String?
}

public struct PluginTemplateContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var category: String?
    /// "spec" (DisplayList with $param substitution) | "pdf" (file in the plugin folder).
    public var kind: String
    public var isCover: Bool?
    /// {"name": {"type": "number|color|choice|bool", "default": …, "choices": […]}}
    public var params: JSONValue?
    /// {"paper": "#FFFFFF", "ops": [DisplayOp…]} for kind "spec".
    public var spec: JSONValue?
    public var file: String?
    public var size: PageSize?
}

public struct PluginKeybinding: Codable, Equatable {
    /// e.g. "cmd+shift+f", "alt+1".
    public var key: String
    public var command: String
    public var title: String?
}

public struct PluginAIAction: Codable, Equatable {
    public var title: String
    public var prompt: String
    /// An `AIScopeKind` raw value (default "selection").
    public var scope: String?
    /// "ask" | "edit" (default "ask").
    public var mode: String?
    public var icon: String?
}

public struct PluginAIGuidance: Codable, Equatable {
    /// ≤ 1,000 characters appended to the AI system prompt while the plugin is enabled.
    public var instructions: String?
}

public struct PluginFileHandler: Codable, Equatable {
    public var extensions: [String]
    public var command: String
    public var title: String?
}

public struct PluginItemType: Codable, Equatable {
    /// Custom item `type`; items are `custom` items with `owner` = plugin id.
    public var type: String
    public var title: String
    /// Command called with {ref} when the item is double-tapped (optional).
    public var edit: String?
    /// JSON Schema of `data` fields shown as an inspector form (writes go through `item.update`).
    public var inspector: JSONValue?
    /// Dot path inside `data` holding the item's text; indexed by search and returned by `recognize.pageText`.
    public var textPath: String?
}

/// Offers finger taps / double-taps / long-presses to a plugin command before the active tool
/// (→ `TapHandlerDescriptor`). The command gets {page, point, ref?, gesture} and returns {handled}.
public struct PluginTapHandler: Codable, Equatable {
    /// "tap" | "doubleTap" | "longPress".
    public var gesture: String
    public var command: String
    /// Only when the topmost item under the point is one of these kinds / custom types of this plugin.
    public var itemKinds: [String]?
    public var itemTypes: [String]?
}

/// An options bar for a plugin canvas tool: a form over some of the plugin's `settings` keys.
public struct PluginToolOptions: Codable, Equatable {
    public var tool: String
    public var settings: [String]
}

/// A text-document block kind (`BlockKind.custom` with `CustomBlock.type`), offered in the slash menu and Turn Into.
public struct PluginBlockContribution: Codable, Equatable {
    public var type: String
    public var title: String
    public var icon: String?
    public var height: Double?
    /// Called with {doc, after?} to insert the block, and with {ref} when the block is tapped for editing.
    public var command: String
    public var aliases: [String]?
}

/// A stroke processor: the command runs once per finished stroke with {page, stroke} and may return {stroke} or
/// {drop: true}. 50 ms budget; on timeout or error the raw stroke is kept.
public struct PluginStrokeProcessor: Codable, Equatable {
    public var id: String
    public var command: String
    /// Tool ids it applies to (default: pen, pencil, highlighter).
    public var tools: [String]?
}

/// An action users can bind to Apple Pencil double-tap or squeeze (Pencil settings).
public struct PluginPencilAction: Codable, Equatable {
    /// "doubleTap" | "squeeze".
    public var gesture: String
    public var command: String
    public var title: String
}

/// A before-command hook (→ `CommandHookDescriptor`); the hook command must have effect "read".
public struct PluginCommandHook: Codable, Equatable {
    /// Command ids or namespace wildcards ("page.*").
    public var commands: [String]
    public var command: String
}

/// A sticker/element collection: fragment JSON files (clipboard fragment format) inside the plugin folder.
public struct PluginElementCollection: Codable, Equatable {
    public var id: String
    public var title: String
    public var files: [String]
}

/// A tape pattern tile (PNG, ~100 px) inside the plugin folder.
public struct PluginTapePattern: Codable, Equatable {
    public var id: String
    public var title: String
    public var file: String
}

/// A whiteboard framework for `board.insertTemplate`: `diagram` = diagram.create params without `page`, or `file` =
/// a fragment JSON file.
public struct PluginBoardTemplate: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    public var diagram: JSONValue?
    public var file: String?
}

public struct PluginContributions: Codable, Equatable {
    public var commands: [PluginCommandContribution]?
    public var menus: [PluginMenuContribution]?
    public var toolbar: [PluginToolbarContribution]?
    public var tools: [PluginToolContribution]?
    public var toolOptions: [PluginToolOptions]?
    public var panels: [PluginPanelContribution]?
    /// Papers and covers (`isCover: true`).
    public var templates: [PluginTemplateContribution]?
    public var keybindings: [PluginKeybinding]?
    /// JSON Schema object; values stored as settings "plugin.<id>.<key>".
    public var settings: JSONValue?
    public var aiActions: [PluginAIAction]?
    public var ai: PluginAIGuidance?
    public var importers: [PluginFileHandler]?
    public var exporters: [PluginFileHandler]?
    public var itemTypes: [PluginItemType]?
    public var tapHandlers: [PluginTapHandler]?
    public var blocks: [PluginBlockContribution]?
    public var strokeProcessors: [PluginStrokeProcessor]?
    public var pencilActions: [PluginPencilAction]?
    public var commandHooks: [PluginCommandHook]?
    /// Content packs.
    public var elements: [PluginElementCollection]?
    public var tapePatterns: [PluginTapePattern]?
    public var boardTemplates: [PluginBoardTemplate]?
}

public struct PluginManifest: Codable, Equatable {
    /// Reverse-DNS id, e.g. "dev.nib.cards". [a-z0-9.-]
    public var id: String
    public var name: String
    /// Semantic version "1.2.3".
    public var version: String
    /// Plugin API version (currently 1).
    public var api: Int
    public var author: String?
    public var description: String?
    /// Single-file JS bundle, e.g. "main.js".
    public var entry: String
    /// Scope raw values: "document:read", "document:write", "library:read", "library:write", "destructive",
    /// "app", "ai", "network". ("plugins:manage" and "security" are never granted to plugins.)
    public var permissions: [String]
    public var network: PluginNetwork?
    public var contributes: PluginContributions?
    public var homepage: String?
}

public struct PluginInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    /// Present on disk (e.g. synced from another device) but not yet approved on this device.
    public var needsReview: Bool
    public var permissions: [String]
    public var sha256: String
    public var source: String?

    public init(id: String, name: String, version: String, enabled: Bool, needsReview: Bool, permissions: [String],
                sha256: String, source: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.needsReview = needsReview
        self.permissions = permissions
        self.sha256 = sha256
        self.source = source
    }
}

/// A running plugin (JavaScriptCore context).
@MainActor
public protocol PluginRuntimeHandle: AnyObject {
    var manifest: PluginManifest { get }
    /// Recent console output (ring buffer).
    var logs: [String] { get }
    /// Calls a command handler registered by the plugin's JS (`nib.commands.register`).
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue
    func deliver(_ event: NibEvent)
    /// Delivers a message to the plugin's `nib.events.on("plugin.message")` handlers.
    func postMessage(from panel: String, message: JSONValue)
    /// Developer console: evaluates JS in the plugin context and returns the result as text.
    func evaluate(_ javascript: String) async -> String
    func stop()
}

@MainActor
public protocol PluginRuntimeProviding: AnyObject {
    /// Creates the context, evaluates the prelude and the entry bundle. `folder` = the installed plugin folder.
    func start(_ manifest: PluginManifest, folder: URL) async throws -> PluginRuntimeHandle
}

@MainActor
public protocol PluginHosting: AnyObject {
    var installed: [PluginInfo] { get }
    func handle(_ id: String) -> PluginRuntimeHandle?
    func folder(_ id: String) -> URL?
    /// (Re)loads a plugin from its folder: validates, maps contributions, starts the runtime.
    func load(_ id: String) async throws
    func unload(_ id: String)
    func setEnabled(_ id: String, _ enabled: Bool) async throws
    /// `ai.instructions` of enabled plugins (appended to the AI system prompt).
    var aiInstructions: [String] { get }
}

// MARK: - AI providers (bring your own model)

public enum AIProviderKind: String, Codable, CaseIterable {
    /// Anthropic Messages API.
    case anthropic
    /// OpenAI Chat Completions and compatible servers (OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Groq…).
    case openAICompatible
    /// The user's own endpoint speaking the Nib Agent Protocol (docs/AI.md §3).
    case nibHTTP
}

public struct AIProviderConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: URL
    public var model: String
    /// Non-secret headers (e.g. OpenRouter HTTP-Referer / X-Title).
    public var extraHeaders: [String: String]
    public var supportsVision: Bool
    public var supportsTools: Bool
    public var contextTokens: Int?
    public var maxOutputTokens: Int
    /// Optional OpenAI-compatible audio transcription model (e.g. "whisper-1").
    public var transcriptionModel: String?
    /// Optional image generation model (e.g. "gpt-image-1").
    public var imageModel: String?

    public init(id: UUID = UUID(), name: String, kind: AIProviderKind, baseURL: URL, model: String,
                extraHeaders: [String: String] = [:], supportsVision: Bool = true, supportsTools: Bool = true,
                contextTokens: Int? = nil, maxOutputTokens: Int = 4096, transcriptionModel: String? = nil, imageModel: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.extraHeaders = extraHeaders
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.transcriptionModel = transcriptionModel
        self.imageModel = imageModel
    }

    /// Keychain location of the API key: service "app.nib.ai", account = id.
    public static let keychainService = "app.nib.ai"
    public var keychainAccount: String { id.uuidString }
}

public enum ChatRole: String, Codable { case user, assistant, tool }

public enum ChatPart: Equatable {
    case text(String)
    case image(data: Data, mime: String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, parts: [ChatPart], isError: Bool)
}

public struct ChatMessage: Equatable {
    public var role: ChatRole
    public var parts: [ChatPart]
    public init(role: ChatRole, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct ToolSpec: Equatable {
    /// [a-zA-Z0-9_-]{1,64}
    public var name: String
    public var description: String
    /// JSON Schema object.
    public var schema: JSONValue
    public init(name: String, description: String, schema: JSONValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

public struct ChatRequest {
    public var model: String
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var maxTokens: Int
    public var temperature: Double?
    public init(model: String, system: String, messages: [ChatMessage], tools: [ToolSpec] = [], maxTokens: Int = 4096,
                temperature: Double? = nil) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum ChatEvent: Equatable {
    case textDelta(String)
    /// Emitted once the call's arguments are complete.
    case toolCall(id: String, name: String, arguments: JSONValue)
    case usage(input: Int, output: Int)
    case stop(reason: String)
}

/// One wire protocol adapter bound to a config (+ its Keychain secret).
public protocol AIProvider: AnyObject {
    var config: AIProviderConfig { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]
    /// Throws `NibError(.unsupported)` when the provider has no transcription endpoint.
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment]
    /// Throws `NibError(.unsupported)` when the provider has no image endpoint.
    func generateImage(prompt: String) async throws -> Data
}

@MainActor
public protocol AIProviderStore: AnyObject {
    var configs: [AIProviderConfig] { get }
    var activeID: UUID? { get set }
    /// Saves the config; a non-nil `apiKey` is written to the Keychain ("" deletes it).
    func save(_ config: AIProviderConfig, apiKey: String?) throws
    func delete(_ id: UUID)
    /// nil id = the active provider.
    func provider(_ id: UUID?) -> AIProvider?
}

// MARK: - Collaboration transports

public struct CollabPeer: Codable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A message pipe between collaborators (Multipeer on the local network, WebSocket relay over the internet).
@MainActor
public protocol CollabTransport: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var peers: [CollabPeer] { get }
    var maxPeers: Int { get }
    var onMessage: ((CollabPeer, Data) -> Void)? { get set }
    var onPeersChanged: (([CollabPeer]) -> Void)? { get set }
    func host(code: String, displayName: String) async throws
    func join(code: String, displayName: String) async throws
    /// nil = everyone.
    func send(_ data: Data, to peers: [CollabPeer]?) throws
    func leave()
}
