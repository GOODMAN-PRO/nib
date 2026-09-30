import Foundation

/// Ask = read-only tools ("Create mode off"); edit = all tools ("Create mode on").
public enum AIMode: String, Codable, CaseIterable { case ask, edit }

public enum AIScopeKind: String, Codable, CaseIterable { case selection, page, document, library, block }

public struct AIScope: Codable, Equatable {
    public var kind: AIScopeKind
    public var doc: DocumentID?
    public var page: PageID?
    /// Selected item / block refs.
    public var refs: [String]

    public init(kind: AIScopeKind, doc: DocumentID? = nil, page: PageID? = nil, refs: [String] = []) {
        self.kind = kind
        self.doc = doc
        self.page = page
        self.refs = refs
    }
}

public struct AIMessage: Codable, Equatable {
    /// "user" | "assistant".
    public var role: String
    public var text: String
    /// Images stored with `AssetStore.putTemporary` or in the document.
    public var images: [AssetRef]?

    public init(role: String, text: String, images: [AssetRef]? = nil) {
        self.role = role
        self.text = text
        self.images = images
    }
}

public struct AIRequest {
    /// Continue a stored conversation (nil = new chat).
    public var chatID: String?
    /// Extra system instructions appended to Nib's system prompt.
    public var system: String?
    public var messages: [AIMessage]
    /// Command ids the model may call directly as tools; nil = the default catalogue for `mode`; [] = no tools.
    public var tools: [String]?
    public var mode: AIMode
    public var scope: AIScope?
    /// Tool calls run as this principal (plugins calling `nib.ai.complete` stay `.plugin(id)`).
    public var principal: Principal
    /// Undo group for everything the turn changes (nil = one fresh group per turn).
    public var group: String?
    public var maxSteps: Int
    /// Ask for a JSON-only answer (feature-internal prompts).
    public var jsonOutput: Bool

    public init(chatID: String? = nil, system: String? = nil, messages: [AIMessage], tools: [String]? = nil,
                mode: AIMode = .ask, scope: AIScope? = nil, principal: Principal = .ai("internal"), group: String? = nil,
                maxSteps: Int = 40, jsonOutput: Bool = false) {
        self.chatID = chatID
        self.system = system
        self.messages = messages
        self.tools = tools
        self.mode = mode
        self.scope = scope
        self.principal = principal
        self.group = group
        self.maxSteps = maxSteps
        self.jsonOutput = jsonOutput
    }
}

public struct AIUsage: Codable, Equatable {
    public var input: Int
    public var output: Int
    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public struct AIResponse: Codable {
    public var text: String
    public var changes: ChangeSummary
    /// Undo group of the turn (for "Undo" / `history.revertGroup`).
    public var group: String?
    public var usage: AIUsage
    public var chatID: String?

    public init(text: String, changes: ChangeSummary = ChangeSummary(), group: String? = nil, usage: AIUsage = AIUsage(), chatID: String? = nil) {
        self.text = text
        self.changes = changes
        self.group = group
        self.usage = usage
        self.chatID = chatID
    }
}

public enum AIStreamEvent {
    case text(String)
    case toolStarted(name: String, arguments: JSONValue)
    case toolFinished(name: String, ok: Bool, changes: ChangeSummary?)
    case finished(AIResponse)
    case failed(NibError)
}

public struct AIChatSummary: Codable, Identifiable {
    public var id: String
    public var title: String
    public var doc: DocumentID?
    public var updated: Double
    public init(id: String, title: String, doc: DocumentID?, updated: Double) {
        self.id = id
        self.title = title
        self.doc = doc
        self.updated = updated
    }
}

/// Bring-your-own-AI service (implemented by the AI Agent feature). Every feature that needs a model
/// (summaries, math, meeting notes, title suggestions, plugins' `nib.ai.complete`) goes through this.
@MainActor
public protocol AIService: AnyObject {
    var isConfigured: Bool { get }
    var supportsVision: Bool { get }
    /// Streams a turn (text deltas, tool calls). Tool calls go through the command bus as `request.principal`.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Runs a turn to completion.
    func complete(_ request: AIRequest) async throws -> AIResponse
    func cancel(chatID: String)
    func chats(doc: DocumentID?) -> [AIChatSummary]
    func messages(chatID: String) -> [AIMessage]
    func deleteChat(_ chatID: String)
    /// Cloud transcription via the provider's audio endpoint; throws `unsupported` when unavailable.
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment]
    /// Image generation via the provider; throws `unsupported` when unavailable.
    func generateImage(prompt: String) async throws -> Data
}

// MARK: - Tool catalogue (AI.md §4), shared by the in-app agent (F084) and the MCP bridge (F090)

@MainActor
public enum ToolCatalog {
    /// The nine meta-tools. Their set never grows; every command is reachable through `nib_run`.
    public static let metaTools: [ToolSpec] = [
        spec("nib_context", "Where the user is: document, page, visible rect, tool, selection refs/bbox, tabs.", .empty),
        spec("nib_get", "Any node (library, folder, doc, page, item, block, card) as JSON; stroke points only with points=true.",
             .obj(["ref": .ref, "depth": .int(min: 0, max: 4), "points": .bool(), "fields": .arr(.str()),
                   "cursor": .str("from the previous result when it was truncated")], required: ["ref"])),
        spec("nib_find", "Find items by kind, layer, area (bbox), field equality (where) or text inside a page or document.",
             .obj(["in": .ref, "kinds": .arr(.str()), "layer": .int(min: 0, max: 4), "bbox": .rect, "where": .anything(),
                   "text": .str(), "limit": .int(min: 1, max: 500), "cursor": .str()], required: ["in"])),
        spec("nib_search", "Full-text search over handwriting, typed text, PDFs, titles and transcripts.",
             .obj(["query": .str(), "scope": .str("doc:D or lib")], required: ["query"])),
        spec("nib_page_text", "Recognised text blocks of a page with bboxes, sources and item ids.",
             .obj(["page": .ref], required: ["page"])),
        spec("nib_render", "Render a page (or region) as an image; marks=true numbers the items and returns mark → ref.",
             .obj(["page": .ref, "region": .rect, "scale": .num(min: 0.1, max: 8), "marks": .bool()], required: ["page"])),
        spec("nib_commands", "List the commands you may call (id, one-line summary, effect), optionally for one namespace.",
             .obj(["namespace": .str()])),
        spec("nib_command_schema", "Full JSON schema and examples of one command. Read it before using an unfamiliar command.",
             .obj(["id": .str()], required: ["id"])),
        spec("nib_run", "Run one command {command, params} or several {calls:[{command, params}]} as one undo step; dry_run previews.",
             .obj(["command": .str(), "params": .anything(), "calls": .arr(.obj(["command": .str(), "params": .anything()])),
                   "dry_run": .bool()]))
    ]

    /// Meta-tools plus the direct tools (command ids) visible to `exposure`; ask mode keeps only `read` commands.
    public static func tools(_ registry: CommandRegistry, exposure: Exposure, readOnly: Bool, direct: [String]) -> [ToolSpec] {
        var out = metaTools
        for id in direct {
            guard let d = registry.descriptor(id), d.exposure.contains(exposure), !readOnly || d.effect == .read else { continue }
            out.append(ToolSpec(name: d.toolName, description: d.summary, schema: d.params.toJSON()))
        }
        return out
    }

    /// The Invocation a tool call stands for (nil = unknown tool). `nib_render` maps to `render.page`: callers turn
    /// its `asset` into an image part (or page text for models without vision). `readOnly` = ask mode.
    public static func invocation(tool: String, arguments: JSONValue, registry: CommandRegistry, principal: Principal,
                                  group: String, readOnly: Bool, session: EditorSession? = nil) -> Invocation? {
        func inv(_ command: String, _ params: JSONValue, dryRun: Bool = false) -> Invocation {
            Invocation(command: command, params: params, principal: principal, session: session, group: group,
                       dryRun: dryRun, readOnly: readOnly)
        }
        let args = arguments == .null ? [:] : arguments
        switch tool {
        case "nib_context": return inv(CommandIDs.queryContext, [:])
        case "nib_get": return inv(CommandIDs.queryGet, args)
        case "nib_find": return inv(CommandIDs.queryFind, args)
        case "nib_search": return inv(CommandIDs.searchText, args)
        case "nib_page_text": return inv(CommandIDs.recognizePageText, args)
        case "nib_render": return inv(CommandIDs.renderPage, args)
        case "nib_commands": return inv(CommandIDs.commandsList, args)
        case "nib_command_schema": return inv(CommandIDs.commandsDescribe, args)
        case "nib_run":
            let dry = args["dry_run"]?.boolValue ?? false
            if let calls = args["calls"] { return inv(CommandIDs.batch, ["calls": calls], dryRun: dry) }
            return inv(args["command"]?.stringValue ?? "", args["params"] ?? [:], dryRun: dry)
        default:
            guard let d = registry.all().first(where: { $0.toolName == tool }) else { return nil }
            return inv(d.id, args)
        }
    }

    private static func spec(_ name: String, _ description: String, _ schema: JSONSchema) -> ToolSpec {
        ToolSpec(name: name, description: description, schema: schema.toJSON())
    }
}
