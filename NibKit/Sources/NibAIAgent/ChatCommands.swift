import Foundation
import NibContracts

/// The agent's commands (ARCHITECTURE.md §6.5 `ai.*`, owner F084).
@MainActor
enum ChatCommands {
    static func register(_ r: CommandRegistry) {
        r.register(AIAsk.self)
        r.register(AIChatList.self)
        r.register(AIChatRename.self)
        r.register(AIChatDelete.self)
        r.register(AIChatFeedback.self)
    }

    static func agent(_ ctx: CommandContext) throws -> AgentService {
        guard let agent = ctx.services.ai as? AgentService else {
            throw NibError(.unavailable, "the AI agent is not installed", hint: "the AI Agent feature is disabled")
        }
        return agent
    }

    static func checkChatID(_ chat: String, field: String = "chat") throws {
        guard NibID.isValid(chat) else {
            throw NibError(.invalidParams, "'\(field)' must be a conversation id", path: "$." + field,
                           hint: "call ai.chat.list for conversation ids")
        }
    }

    /// `scope` of `ai.ask`: a kind resolved against the caller's window ("selection", "page", "document", "library",
    /// "block") or a ref ("lib", "folder:F", "doc:D", "page:D/P", "item:D/P/I", "block:D/B", "card:D/C"…).
    static func scope(_ raw: String?, refs extra: [String]?, session: EditorSession?) throws -> AIScope? {
        let refs = (extra ?? []).filter { !$0.isEmpty }
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return refs.isEmpty ? nil : try scope(fromRefs: refs)
        }
        let doc = session?.document
        let page = session?.page
        switch raw {
        case AIScopeKind.selection.rawValue:
            let selected = refs.isEmpty ? (session?.selection.refs ?? []) : refs
            guard !selected.isEmpty else {
                throw NibError(.invalidParams, "nothing is selected", path: "$.scope",
                               hint: "pass the item refs in 'refs', or use scope 'page'")
            }
            return try scope(fromRefs: selected)
        case AIScopeKind.page.rawValue:
            guard let d = doc, let p = page else {
                throw NibError(.invalidParams, "no page is open", path: "$.scope", hint: "pass a page ref such as page:D/P")
            }
            return AIScope(kind: .page, doc: d, page: p, refs: refs)
        case AIScopeKind.document.rawValue:
            guard let d = doc else {
                throw NibError(.invalidParams, "no document is open", path: "$.scope", hint: "pass a document ref such as doc:D")
            }
            return AIScope(kind: .document, doc: d, refs: refs)
        case AIScopeKind.library.rawValue:
            return AIScope(kind: .library, refs: refs)
        case AIScopeKind.block.rawValue:
            guard !refs.isEmpty else {
                throw NibError(.invalidParams, "scope 'block' needs block refs in 'refs'", path: "$.refs")
            }
            return try scope(fromRefs: refs)
        default:
            guard let ref = NodeRef(raw) else {
                throw NibError(.invalidParams, "unknown scope '\(raw)'", path: "$.scope",
                               hint: "use selection, page, document, library or a ref such as page:D/P")
            }
            switch ref {
            case .library:
                return AIScope(kind: .library, refs: refs)
            case .folder:
                return AIScope(kind: .library, refs: [raw] + refs)
            case .document(let d):
                return AIScope(kind: .document, doc: d, refs: refs)
            case .page(let d, let p):
                return AIScope(kind: .page, doc: d, page: p, refs: refs)
            case .item, .block:
                return try scope(fromRefs: [raw] + refs)
            case .card(let d, _), .audio(let d, _), .outline(let d, _):
                return AIScope(kind: .document, doc: d, refs: [raw] + refs)
            }
        }
    }

    /// Item refs → a selection on their page; block refs → blocks of their document.
    static func scope(fromRefs refs: [String]) throws -> AIScope {
        var doc: DocumentID?
        var page: PageID?
        var blocks = false
        for (i, r) in refs.enumerated() {
            guard let ref = NodeRef(r), let d = ref.documentID else {
                throw NibError(.invalidParams, "'\(r)' is not an item or block ref", path: "$.refs[\(i)]")
            }
            if case .block = ref { blocks = true }
            if doc == nil { doc = d }
            if page == nil { page = ref.pageID }
        }
        return AIScope(kind: blocks ? .block : .selection, doc: doc, page: page, refs: refs)
    }
}

// MARK: - ai.ask

/// Runs the user's AI headlessly. The turn's tool calls run as the caller (a user caller's as the AI), in the caller's
/// undo group, and read-only when the caller is read-only (`forwardsCalls`: the bus authorises every nested call).
struct AIAsk: NibCommand {
    struct Params: Codable {
        var prompt: String
        var scope: String?
        var mode: String?
        var chat: String?
        /// Additive: item or block refs for a selection / block scope.
        var refs: [String]?
    }
    typealias Output = AIResponse

    static let descriptor = CommandDescriptor(
        id: "ai.ask", title: "Ask AI",
        summary: "Run the user's AI on a prompt headlessly and return its answer {text, changes, group, usage, chatID} (tool calls run as the caller).",
        params: .obj(["prompt": .str("what to ask or do"),
                      "scope": .str("selection | page | document | library | block, or a ref (lib, doc:D, page:D/P, item:D/P/I, block:D/B); default: where the user is"),
                      "mode": .str("ask = read-only (default), edit = may change notes", choices: AIMode.allCases.map(\.rawValue)),
                      "chat": .str("conversation id to continue (from ai.chat.list); omit for a new one"),
                      "refs": .arr(.ref, "item or block refs for scope selection / block")],
                     required: ["prompt"]),
        examples: [["prompt": "Summarise this page in three bullet points", "scope": "page:FIXTUREDOC01/FIXTUREPG001"],
                   ["prompt": "Add a heading 'Summary' at the top of the page", "scope": "page:FIXTUREDOC01/FIXTUREPG002",
                    "mode": "edit"]],
        effect: .read, target: .document, extraScopes: [.ai], forwardsCalls: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> AIResponse {
        let prompt = p.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw NibError(.invalidParams, "the prompt is empty", path: "$.prompt") }
        if let c = p.chat { try ChatCommands.checkChatID(c) }
        var mode = AIMode.ask
        if let m = p.mode {
            guard let parsed = AIMode(rawValue: m) else {
                throw NibError(.invalidParams, "mode is 'ask' or 'edit'", path: "$.mode")
            }
            mode = parsed
        }
        let session = ctx.activeSession
        let scope = try ChatCommands.scope(p.scope, refs: p.refs, session: session)
        guard let ai = ctx.services.ai else {
            throw NibError(.unavailable, "no AI is set up", hint: "add a provider in Settings › AI")
        }
        let request = AIRequest(chatID: p.chat, messages: [AIMessage(role: "user", text: prompt)], mode: mode, scope: scope,
                                principal: ctx.principal, group: ctx.group)
        // A read-only caller keeps the turn read-only; so does a dry run, whose tool calls could not be rolled back.
        let readOnly = ctx.readOnly || ctx.dryRun
        guard let agent = ai as? AgentService else {
            // Another AIService implementation runs the turn itself.
            var r = request
            if readOnly { r.mode = .ask }
            return try await ai.complete(r)
        }
        let caller = AgentService.Caller(principal: ctx.principal, session: ctx.session ?? session, depth: ctx.depth + 1,
                                         readOnly: readOnly, inheritedPolicy: ctx.inheritedPolicy)
        let response = try await agent.complete(request, caller: caller)
        // A turn that changed several documents undoes as one step in all of them.
        if AgentService.documents(response.changes).count > 1 && !ctx.dryRun { ctx.linkUndoAcrossDocuments() }
        return response
    }
}

// MARK: - Conversations

struct AIChatList: NibCommand {
    struct Params: Codable {
        var doc: String?
        /// Additive: every conversation (documents and library).
        var all: Bool?
        /// Additive: also return this conversation's messages (with the ids `ai.chat.feedback` takes).
        var chat: String?
    }
    struct Row: Codable {
        var id: String
        var title: String
        /// "doc:D"; absent for library conversations.
        var doc: String?
        var updated: Double
        var messages: Int
    }
    struct Message: Codable {
        var id: String
        var role: String
        var text: String
        var at: Double?
        var rating: String?
        /// Undo group of an answer that changed notes (`history.revertGroup`).
        var group: String?
        var changes: ChangeSummary?
        var cancelled: Bool?
    }
    struct Output: Codable {
        var chats: [Row]
        var messages: [Message]?
    }

    static let descriptor = CommandDescriptor(
        id: "ai.chat.list", title: "AI Conversations",
        summary: "AI conversations of a document (doc) or of the library (no doc), newest first; all=true lists every one; chat=id adds its messages.",
        params: .obj(["doc": .ref, "all": .bool("list the conversations of every document and the library"),
                      "chat": .str("conversation id: also return its messages")]),
        examples: [[:], ["doc": "doc:FIXTUREDOC01"], ["all": true, "chat": "FIXTURECHAT1"]],
        effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = p.doc.flatMap { $0.isEmpty || $0 == "lib" || $0 == "library" ? nil : NodeRef.documentID(from: $0) }
        if let c = p.chat { try ChatCommands.checkChatID(c) }
        guard let ai = ctx.services.ai else { return Output(chats: [], messages: p.chat == nil ? nil : []) }
        let agent = ai as? AgentService
        // Conversations of locked documents stay hidden from everyone but the user.
        func visible(_ owner: DocumentID?) -> Bool {
            ctx.principal.isUser || owner.map { !ctx.bus.gateway.isLocked($0) } ?? true
        }
        let summaries = (agent?.chatStore.summaries(doc: doc, all: p.all ?? false) ?? ai.chats(doc: doc))
            .filter { visible($0.doc) }
        let rows = summaries.map { s -> Row in
            let count = agent?.chatStore.visibleMessages(s.id).count ?? ai.messages(chatID: s.id).count
            return Row(id: s.id, title: s.title, doc: s.doc.map { NodeRef.document($0).description }, updated: s.updated,
                       messages: count)
        }
        guard let chat = p.chat else { return Output(chats: rows) }
        guard let agent = agent else {
            let list = ai.messages(chatID: chat).enumerated().map {
                Message(id: String($0.offset), role: $0.element.role, text: $0.element.text)
            }
            return Output(chats: rows, messages: list)
        }
        guard let state = agent.chatStore.state(chat) else { throw ChatStore.unknownChat(chat) }
        guard visible(state.meta?.doc.map { DocumentID($0) }) else {
            throw NibError(.locked, "the conversation belongs to a locked document", hint: "ask the user to unlock it first")
        }
        let list = agent.chatStore.visibleMessages(chat).map {
            Message(id: $0.id.raw, role: $0.role ?? "user", text: $0.text ?? "", at: $0.at, rating: $0.rating,
                    group: $0.group, changes: $0.changes, cancelled: $0.cancelled)
        }
        return Output(chats: rows, messages: list)
    }
}

struct AIChatRename: NibCommand {
    struct Params: Codable {
        var chat: String
        var title: String
    }
    static let descriptor = CommandDescriptor(
        id: "ai.chat.rename", title: "Rename Conversation",
        summary: "Rename an AI conversation (chat id from ai.chat.list).",
        params: .obj(["chat": .str("conversation id"), "title": .str("new title")], required: ["chat", "title"]),
        examples: [["chat": "FIXTURECHAT1", "title": "Kinematics revision"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ChatCommands.checkChatID(p.chat)
        try ChatCommands.agent(ctx).chatStore.rename(p.chat, title: p.title)
        return NoResult()
    }
}

struct AIChatDelete: NibCommand {
    struct Params: Codable {
        var chat: String
    }
    static let descriptor = CommandDescriptor(
        id: "ai.chat.delete", title: "Delete Conversation",
        summary: "Delete an AI conversation on every device (chat id from ai.chat.list); what the AI changed in notes stays.",
        params: .obj(["chat": .str("conversation id")], required: ["chat"]),
        examples: [["chat": "FIXTURECHAT1"]],
        effect: .session, target: .app, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ChatCommands.checkChatID(p.chat)
        let agent = try ChatCommands.agent(ctx)
        agent.cancel(chatID: p.chat)
        try agent.chatStore.delete(p.chat)
        return NoResult()
    }
}

struct AIChatFeedback: NibCommand {
    struct Params: Codable {
        var chat: String
        var message: String
        var rating: String
    }
    static let descriptor = CommandDescriptor(
        id: "ai.chat.feedback", title: "Rate AI Answer",
        summary: "Rate an AI answer thumbs up or down (none clears it); the rating is stored with the conversation.",
        params: .obj(["chat": .str("conversation id"),
                      "message": .str("the AI message's id (ai.chat.list {chat}), 'last', or its 0-based position"),
                      "rating": .str("up, down or none", choices: ["up", "down", "none"])],
                     required: ["chat", "message", "rating"]),
        examples: [["chat": "FIXTURECHAT1", "message": "FIXTUREMSG001", "rating": "up"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ChatCommands.checkChatID(p.chat)
        guard ["up", "down", "none"].contains(p.rating) else {
            throw NibError(.invalidParams, "rating is 'up', 'down' or 'none'", path: "$.rating")
        }
        try ChatCommands.agent(ctx).chatStore.rate(p.chat, message: p.message, rating: p.rating == "none" ? nil : p.rating)
        return NoResult()
    }
}
