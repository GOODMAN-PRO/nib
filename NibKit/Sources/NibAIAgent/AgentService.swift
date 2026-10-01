import Foundation
import NibContracts

/// `services.ai`: the bring-your-own-model agent (AI.md §1). A turn streams the active provider (F083), runs the
/// model's tool calls through the command bus (Gateway checks, confirmations, provenance), keeps everything the turn
/// changes in one undo group, stores the conversation per device, and emits `ai.turn.finished`.
@MainActor
final class AgentService: AIService {
    /// Where a turn's tool calls come from when a command (`ai.ask`) runs it.
    struct Caller {
        var principal: Principal
        var session: EditorSession?
        var depth: Int
        var readOnly: Bool
        var inheritedPolicy: ConfirmationPolicy?
    }

    /// Per tool call, confirmation wait included (AI.md §6).
    var toolTimeout: TimeInterval = 120
    /// Per context read (`query.context`, `recognize.pageText`) while building the prompt.
    var contextTimeout: TimeInterval = 15
    /// Stored messages sent back to the model when a conversation continues.
    var historyLimit = 40
    var historyCharacters = 80_000

    weak var app: NibApp?
    let chatStore: ChatStore
    private var running: [String: Task<TurnOutcome, Never>] = [:]

    init(app: NibApp) {
        self.app = app
        let services = app.services
        chatStore = ChatStore(directory: { [weak services] in
            services?.library?.metadataURL.appendingPathComponent("ai", isDirectory: true)
        }, deviceHex: app.deviceHex, clock: app.clock)
    }

    // MARK: Provider

    var providerStore: AIProviderStore? { app?.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self) }

    private var activeConfig: AIProviderConfig? {
        guard let store = providerStore, let id = store.activeID else { return nil }
        return store.configs.first { $0.id == id }
    }

    var isConfigured: Bool { activeConfig != nil }
    var supportsVision: Bool { activeConfig?.supportsVision ?? false }

    private func provider() throws -> AIProvider {
        guard let p = providerStore?.provider(nil) else {
            throw NibError(.unavailable, "no AI provider is set up", hint: "add one in Settings › AI")
        }
        return p
    }

    // MARK: AIService

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self = self else {
                    let e = NibError.unavailable("the AI agent")
                    continuation.yield(.failed(e))
                    continuation.finish(throwing: e)
                    return
                }
                let result = await self.turn(request, caller: nil) { continuation.yield($0) }
                switch result {
                case .success(let r):
                    continuation.yield(.finished(r))
                    continuation.finish()
                case .failure(let e):
                    continuation.yield(.failed(e))
                    continuation.finish(throwing: e)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        try await turn(request, caller: nil) { _ in }.get()
    }

    /// Runs a turn for a command (`ai.ask`): tool calls run as the caller (the user's own calls run as the AI), nested
    /// one level deeper, read-only when the caller is, with the caller's confirmation policy.
    func complete(_ request: AIRequest, caller: Caller) async throws -> AIResponse {
        try await turn(request, caller: caller) { _ in }.get()
    }

    func cancel(chatID: String) {
        running[chatID]?.cancel()
    }

    func chats(doc: DocumentID?) -> [AIChatSummary] { chatStore.summaries(doc: doc) }

    func messages(chatID: String) -> [AIMessage] {
        chatStore.visibleMessages(chatID).map(\.aiMessage)
    }

    func deleteChat(_ chatID: String) {
        cancel(chatID: chatID)
        do {
            try chatStore.delete(chatID)
        } catch {
            agentLog.error("chat not deleted: \(NibError.wrap(error).description, privacy: .public)")
        }
    }

    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] {
        let p = try provider()
        return try await p.transcribe(audio: audio, language: language)
    }

    func generateImage(prompt: String) async throws -> Data {
        let p = try provider()
        return try await p.generateImage(prompt: prompt)
    }

    // MARK: Turns

    /// Whether a turn becomes a stored conversation: every turn that names a chat, and conversational turns of the
    /// user, the AI and the bridge. JSON-only feature prompts and plugins' `nib.ai.complete` stay ephemeral.
    static func persists(_ request: AIRequest, principal: Principal) -> Bool {
        if request.chatID != nil { return true }
        if request.jsonOutput { return false }
        switch principal {
        case .plugin, .sync: return false
        case .ai(let id): return id != "internal"
        case .user, .bridge: return true
        }
    }

    /// The principal tool calls run as. The AI never acts as the user: a user-started turn runs as `.ai(<chat>)`, and a
    /// stored conversation's AI turns carry its id, so `createdBy = "ai:<chat>"` selects everything the chat made.
    /// Plugins and the bridge keep their own principal, so nobody escalates through the AI.
    static func effectivePrincipal(_ principal: Principal, chat: String, persisted: Bool) -> Principal {
        switch principal {
        case .user: return .ai(chat)
        case .ai: return persisted ? .ai(chat) : principal
        default: return principal
        }
    }

    private func turn(_ request: AIRequest, caller: Caller?,
                      sink: @escaping @MainActor (AIStreamEvent) -> Void) async -> Result<AIResponse, NibError> {
        guard let app = app else { return .failure(NibError.unavailable("the AI agent")) }
        if let c = request.chatID, !NibID.isValid(c) {
            return .failure(NibError(.invalidParams, "chat ids are 1–64 characters [A-Za-z0-9_-]", path: "$.chat"))
        }
        let incoming = request.messages.filter { !$0.text.isEmpty || !($0.images ?? []).isEmpty }
        guard !incoming.isEmpty else {
            return .failure(NibError(.invalidParams, "the request has no message", path: "$.messages"))
        }
        let chatID = request.chatID ?? NibID.make().raw
        let basePrincipal = caller?.principal ?? request.principal
        if request.chatID != nil {
            do { try chatStore.checkAccess(chatID, principal: basePrincipal, gateway: app.gateway) }
            catch { return .failure(NibError.wrap(error)) }
        }
        if request.chatID != nil && chatStore.isDeleted(chatID) {
            return .failure(NibError(.notFound, "conversation '\(chatID)' was deleted", path: "$.chat",
                                     hint: "start a new conversation"))
        }
        guard running[chatID] == nil else {
            return .failure(NibError(.conflict, "this conversation is already answering",
                                     hint: "wait for the answer or stop it first"))
        }
        let provider: AIProvider
        do {
            provider = try self.provider()
        } catch {
            return .failure(NibError.wrap(error))
        }

        let persisted = AgentService.persists(request, principal: basePrincipal)
        let principal = AgentService.effectivePrincipal(basePrincipal, chat: chatID, persisted: persisted)
        let readOnly = request.mode == .ask || (caller?.readOnly ?? false)
        let group = request.group ?? NibID.make().raw
        let session = caller?.session ?? app.services.sessions.active
        let scopeDoc = request.scope?.doc ?? (request.scope == nil ? session?.document : nil)
        let config = provider.config

        // Conversation: stored history (when continuing) + the new messages.
        let stored = persisted && request.chatID != nil ? chatStore.visibleMessages(chatID) : []
        let fresh = AgentService.newMessages(incoming, after: stored)
        if persisted {
            let firstUser = stored.first(where: { $0.role == "user" })?.text
                ?? fresh.first(where: { $0.role != "assistant" })?.text ?? ""
            chatStore.ensureChat(chatID, title: firstUser, doc: scopeDoc)
            chatStore.append(fresh.map { chatStore.makeMessage(role: $0.role == "assistant" ? "assistant" : "user", text: $0.text,
                                                       images: $0.images) }, chat: chatID)
        }
        let history = trimmed(stored.map(\.aiMessage) + fresh).compactMap { chatMessage($0, doc: scopeDoc) }

        let toolbox = AgentToolbox.build(registry: app.commands, settings: app.settings,
                                         pluginHost: app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self),
                                         exposure: principal.exposure, readOnly: readOnly, requested: request.tools,
                                         supportsTools: config.supportsTools)
        let loop = AgentLoop(
            bus: app.bus, pluginHost: app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self),
            setup: AgentLoop.Setup(provider: provider, config: config, history: history, mode: request.mode,
                                   readOnly: readOnly, scope: request.scope, system: request.system,
                                   jsonOutput: request.jsonOutput, maxSteps: min(max(request.maxSteps, 1), 100),
                                   principal: principal, group: group, session: session,
                                   depth: caller?.depth ?? 0, inheritedPolicy: caller?.inheritedPolicy,
                                   toolbox: toolbox, toolTimeout: toolTimeout, contextTimeout: contextTimeout))

        // The loop runs in its own task so `cancel(chatID:)` can stop it; cancelling the caller stops it too.
        let inner = Task { @MainActor () -> TurnOutcome in await loop.run(sink) }
        running[chatID] = inner
        let outcome = await withTaskCancellationHandler {
            await inner.value
        } onCancel: {
            inner.cancel()
        }
        running[chatID] = nil
        return finish(outcome, chatID: chatID, persisted: persisted, principal: principal, group: group,
                      mode: readOnly ? .ask : request.mode, jsonOutput: request.jsonOutput, doc: scopeDoc)
    }

    /// Stores the answer, emits `ai.turn.finished` and builds the response. A cancelled turn keeps what it did: its
    /// response carries the partial text and the undo group of the changes made so far.
    private func finish(_ outcome: TurnOutcome, chatID: String, persisted: Bool, principal: Principal, group: String,
                        mode: AIMode, jsonOutput: Bool, doc: DocumentID?) -> Result<AIResponse, NibError> {
        let text = jsonOutput ? AgentLoop.unfenced(outcome.finalText.isEmpty ? outcome.text : outcome.finalText) : outcome.text
        if persisted {
            var r = chatStore.makeMessage(role: "assistant", text: text)
            r.group = outcome.changes.isEmpty ? nil : group
            r.changes = outcome.changes
            r.usage = outcome.usage
            r.mode = mode.rawValue
            r.tools = outcome.toolNames
            if outcome.cancelled { r.cancelled = true }
            r.error = outcome.error
            chatStore.append([r], chat: chatID)
        }
        var payload: [String: JSONValue] = [
            "group": .string(group), "chat": .string(chatID), "mode": .string(mode.rawValue),
            "steps": .number(Double(outcome.steps)),
            "usage": ["input": .number(Double(outcome.usage.input)), "output": .number(Double(outcome.usage.output))]
        ]
        if outcome.cancelled { payload["cancelled"] = true }
        if outcome.stepLimitReached { payload["stepLimitReached"] = true }
        if let e = outcome.error { payload["error"] = e.json["error"] ?? .null }
        app?.events.emit(NibEventType.aiTurnFinished, principal: principal, doc: doc, changes: outcome.changes,
                         payload: .object(payload))
        if let e = outcome.error { return .failure(e) }
        return .success(AIResponse(text: text, changes: outcome.changes, group: group, usage: outcome.usage,
                                   chatID: persisted ? chatID : nil))
    }

    // MARK: Conversation

    /// The request's messages that are not already stored: callers may send only the new message or the whole
    /// conversation again.
    static func newMessages(_ incoming: [AIMessage], after stored: [ChatRecord]) -> [AIMessage] {
        let shown = stored.filter { !($0.role == "assistant" && ($0.text ?? "").isEmpty) }
        guard !shown.isEmpty, incoming.count > shown.count else { return incoming }
        let prefix = zip(shown, incoming).allSatisfy { s, m in
            (s.role ?? "user") == m.role && (s.text ?? "") == m.text
                && (s.images ?? []) == (m.images ?? []).map(\.name)
        }
        return prefix ? Array(incoming.dropFirst(shown.count)) : incoming
    }

    /// The most recent messages within the history budget (the newest message is always kept).
    private func trimmed(_ messages: [AIMessage]) -> [AIMessage] {
        var out: [AIMessage] = []
        var characters = 0
        for m in messages.reversed() {
            if !out.isEmpty && (out.count >= historyLimit || characters + m.text.count > historyCharacters) { break }
            out.append(m)
            characters += m.text.count
        }
        var history = Array(out.reversed())
        while history.count > 1 && history.first?.role != "user" { history.removeFirst() }
        return history
    }

    /// A stored or new message for the provider: text plus its images (temporary assets, else the scope document's).
    private func chatMessage(_ m: AIMessage, doc: DocumentID?) -> ChatMessage? {
        var parts: [ChatPart] = []
        if !m.text.isEmpty { parts.append(.text(m.text)) }
        if m.role != "assistant" {
            for ref in m.images ?? [] {
                if let data = imageData(ref, doc: doc) {
                    parts.append(.image(data: data, mime: AgentService.mime(ref)))
                } else {
                    parts.append(.text("[An attached image is no longer available.]"))
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        return ChatMessage(role: m.role == "assistant" ? .assistant : .user, parts: parts)
    }

    private func imageData(_ ref: AssetRef, doc: DocumentID?) -> Data? {
        guard let assets = app?.services.assets else { return nil }
        if let url = assets.temporaryURL(ref), let data = try? Data(contentsOf: url) { return data }
        if let d = doc, let data = try? assets.data(ref, doc: d) { return data }
        return nil
    }

    static func mime(_ ref: AssetRef) -> String {
        switch ref.ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }

    /// Documents a change summary touched.
    static func documents(_ changes: ChangeSummary) -> Set<DocumentID> {
        Set(changes.all.compactMap { NodeRef($0)?.documentID })
    }
}
