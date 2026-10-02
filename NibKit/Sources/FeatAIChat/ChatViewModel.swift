import Foundation
import Combine
import UIKit
import NibContracts

struct ChatEntry: Identifiable {
    var id: String
    var role: String
    var text: String { didSet { refreshCitations() } }
    private(set) var citationRefs: [String] = []
    private(set) var citationLabels: [String: String] = [:]
    private(set) var displayText = ""
    var isPersisted = false
    var images: [AssetRef] = []
    var tools: [ChatToolActivity] = []
    var changes = ChangeSummary()
    var group: String?
    var rating: String?
    var reverted = false
    var usage = AIUsage()
    var at = Date()
    var isReceipt = false
    var revertNote: String?

    init(id: String, role: String, text: String, images: [AssetRef] = [], changes: ChangeSummary = ChangeSummary(),
         group: String? = nil, rating: String? = nil, at: Date = Date(), isReceipt: Bool = false, isPersisted: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.images = images
        self.changes = changes; self.group = group; self.rating = rating; self.at = at
        self.isReceipt = isReceipt; self.isPersisted = isPersisted
        refreshCitations()
    }

    private mutating func refreshCitations() {
        citationRefs = ChatCitations.refs(in: text)
        displayText = ChatCitations.replacingRefs(in: text, labels: citationLabels, refs: citationRefs)
    }

    mutating func resolveCitations(_ label: (String) -> String) {
        for ref in citationRefs where citationLabels[ref] == nil { citationLabels[ref] = label(ref) }
        displayText = ChatCitations.replacingRefs(in: text, labels: citationLabels, refs: citationRefs)
    }
}

struct ChatToolActivity: Identifiable, Codable {
    var id = UUID().uuidString
    var name: String
    var arguments: JSONValue
    var succeeded: Bool?
    var cancelled = false
    var changes: ChangeSummary?
    var hasArguments = true
}

struct ChatConversation: Decodable, Identifiable {
    var id: String
    var title: String
    var doc: String?
    var updated: Double
}

/// F084's list is intentionally small; the JSONL record has additional optional fields.
struct StoredChatEntry: Codable {
    var id: String
    var role: String
    var text: String
    var group: String?
    var changes: ChangeSummary?
    var rating: String?
    var at: Double?
    var images: [String]?
    var usage: AIUsage?
    var tools: [ChatToolActivity]?
    var cancelled: Bool?
    var reverted: Bool?
    var revertNote: String?
    var receipt: Bool?

    init(_ entry: ChatEntry) {
        id = entry.id; role = entry.role; text = entry.text; group = entry.group
        changes = entry.changes; rating = entry.rating; at = entry.at.timeIntervalSince1970
        images = entry.images.map(\.name); usage = entry.usage; tools = entry.tools
        reverted = entry.reverted; revertNote = entry.revertNote; receipt = entry.isReceipt
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, group, changes, rating, at, images, usage, tools, cancelled, reverted, revertNote, receipt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group)
        changes = try c.decodeIfPresent(ChangeSummary.self, forKey: .changes)
        rating = try c.decodeIfPresent(String.self, forKey: .rating)
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        images = try c.decodeIfPresent([String].self, forKey: .images)
        usage = try c.decodeIfPresent(AIUsage.self, forKey: .usage)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled)
        reverted = try c.decodeIfPresent(Bool.self, forKey: .reverted)
        revertNote = try c.decodeIfPresent(String.self, forKey: .revertNote)
        receipt = try c.decodeIfPresent(Bool.self, forKey: .receipt)
        if let detailed = try? c.decode([ChatToolActivity].self, forKey: .tools) { tools = detailed }
        else if let names = try? c.decode([String].self, forKey: .tools) {
            // Legacy records never stored arguments or individual outcomes. Do not invent either.
            tools = names.enumerated().map { ChatToolActivity(id: id + ".tool.\($0.offset)", name: $0.element,
                arguments: [:], succeeded: nil, cancelled: cancelled ?? false, hasArguments: false) }
        }
    }

    var entry: ChatEntry {
        var entry = ChatEntry(id: id, role: role, text: text, images: (images ?? []).map(AssetRef.init),
            changes: changes ?? ChangeSummary(), group: group, rating: rating,
            at: Date(timeIntervalSince1970: at ?? 0), isReceipt: receipt ?? false, isPersisted: true)
        entry.usage = usage ?? AIUsage(); entry.tools = tools ?? []
        entry.reverted = reverted ?? false; entry.revertNote = revertNote
        return entry
    }
}

struct ChatListResult: Decodable {
    var chats: [ChatConversation]
    var messages: [StoredChatEntry]?
}

struct ChatDraft: Identifiable {
    var id = NibID.make().raw
    var text: String
    var asset: AssetRef?
    var image: UIImage?
    var prompt: String
}

/// Per-window state. All state-changing entry points below are reached through registered commands.
@MainActor
final class ChatViewModel: ObservableObject {
    weak var app: NibApp?
    weak var session: EditorSession?
    @Published var entries: [ChatEntry] = []
    @Published var totalTokens = 0
    @Published var conversations: [ChatConversation] = []
    @Published var chatID: String?
    @Published var scope = AIScope(kind: .library)
    @Published var mode = AIMode.ask
    @Published var composer = ""
    @Published var attachments: [AssetRef] = []
    @Published var isStreaming = false
    var isVisible = false
    var visibilityLease: String?
    weak var windowUndoManager: UndoManager?
    @Published var isGeneratingImage = false
    @Published var error: NibError?
    @Published var showsConversations = false
    @Published var renamingChat: String?
    @Published var renameTitle = ""
    @Published var showsTools = false
    @Published var draft: ChatDraft?
    @Published var proposals: [ChatProposal] = []
    @Published var showsProposalsOnPage = true
    @Published var proposalsReviewed = false
    @Published private(set) var isApplyingProposals = false
    @Published private(set) var isStagingProposals = false
    let localUndo = UndoManager()
    var proposalApplyGroup: String?
    @Published var confirmation: ChatConfirmation?
    @Published var providerLabel = String(localized: "No model connected")
    @Published private(set) var historyOperationLabel: String?
    @Published var contextLabel = String(localized: "Library")
    @Published var docKind: DocumentKind?
    @Published var needsImagePicker = false
    @Published var retryPrompt: String?
    private var generation: UUID?
    private var sessionObservation: AnyCancellable?
    var turnToken: UUID? { generation }
    @Published private(set) var isLoadingChat = false
    private var loadToken: UUID?
    private var imageTask: Task<Data, Error>?
    private var citationLabels: [String: String] = [:]
    private var retryImages: [AssetRef] = []
    private var retryEntry: String?
    private var confirmationContinuation: CheckedContinuation<ConfirmationDecision, Never>?

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        if let d = session?.document {
            scope = AIScope(kind: .document, doc: d)
        }
        refreshContextLabel()
        refreshProviderLabel()
        // Scope-menu prerequisites follow the canvas selection even when the conversation is idle.
        sessionObservation = session?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    static func tokenKey(_ chat: String) -> SettingKey<Int> { SettingKey("aichat.tokens." + chat, default: 0) }
    var tokenCount: Int { totalTokens }
    var settingsPageID: String {
        app?.ui.settingsPages.all.first(where: { $0.owner == "aisettings" })?.id ?? "settings.ai"
    }
    var isConfigured: Bool { app?.services.ai?.isConfigured ?? false }
    // These mirror existing command guards; presentation must not offer an action the model rejects.
    var canChangeConversation: Bool { !isStreaming && !isGeneratingImage && !isApplyingProposals && !isStagingProposals }
    var canStartGeneration: Bool { canChangeConversation && !isLoadingChat }
    var canSend: Bool { isConfigured && canStartGeneration && proposals.isEmpty }
    var canGenerateImage: Bool { isConfigured && app?.services.assets != nil && canStartGeneration }
    var canConfigureContext: Bool { !isStreaming && !isApplyingProposals }
    var canUseHistory: Bool { canStartGeneration && historyOperationLabel == nil }
    var progressLabel: String? {
        if let historyOperationLabel { return historyOperationLabel }
        if isLoadingChat { return String(localized: "Loading conversation…") }
        if isGeneratingImage { return String(localized: "Generating image…") }
        if isApplyingProposals { return String(localized: "Applying changes…") }
        if isStagingProposals { return String(localized: "Preparing changes…") }
        if isStreaming { return String(localized: "Generating response…") }
        return nil
    }

    func refreshProviderLabel() {
        guard let store = app?.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self),
              let config = store.configs.first(where: { $0.id == store.activeID }) else {
            if providerLabel != String(localized: "No model connected") { providerLabel = String(localized: "No model connected") }
            return
        }
        let hasKey = !(Keychain.getString(service: AIProviderConfig.keychainService, account: config.keychainAccount) ?? "").isEmpty
        let credentials = hasKey ? String(localized: "your API key") : String(localized: "no API key saved")
        let label = "\(config.model) · \(config.name) · \(credentials)"
        if providerLabel != label { providerLabel = label }
    }

    func refreshContextLabel() {
        guard scope.kind != .library else { contextLabel = String(localized: "Library"); return }
        let title = scope.doc.flatMap { app?.services.library?.node($0)?.title } ?? String(localized: "Document unavailable")
        let content = scope.doc.flatMap { try? app?.workspace.content($0) }
        let page = scope.page.flatMap { content?.pageIndex($0) }.map { String(localized: "Page \($0 + 1)") }
        var parts = [title]
        if scope.kind != .document, let page { parts.append(page) }
        switch scope.kind {
        case .page: if page == nil { parts.append(String(localized: "Page unavailable")) }
        case .selection:
            parts.append(scope.refs.count == 1 ? String(localized: "1 item selected") : String(localized: "\(scope.refs.count) items selected"))
        case .block:
            parts.append(scope.refs.count == 1 ? String(localized: "1 block selected") : String(localized: "\(scope.refs.count) blocks selected"))
        default: break
        }
        contextLabel = parts.joined(separator: " · ")
    }

    func scopeUnavailableReason(_ kind: AIScopeKind) -> String? {
        switch kind {
        case .library: return nil
        case .document: return session?.document == nil ? String(localized: "Open a document first") : nil
        case .page: return session?.document == nil || session?.page == nil ? String(localized: "Open a page first") : nil
        case .selection, .block:
            let selected = session?.selection.refs ?? []
            let valid = !selected.isEmpty && selected.allSatisfy {
                if case .block? = NodeRef($0) { return true }
                if kind == .selection, case .item? = NodeRef($0) { return true }
                return false
            }
            return valid ? nil : (kind == .block ? String(localized: "Select a block first") : String(localized: "Select an item first"))
        }
    }

    var quickActions: [AIActionDescriptor] {
        app?.content.aiActions.all.filter { action in
            docKind.map { action.docKinds.contains($0) } ?? (action.scope == .library)
        } ?? []
    }

    func perform(_ command: String, _ params: JSONValue = [:]) {
        guard let app else { return }
        let historyOperation: String?
        switch command {
        case CommandIDs.aiChatRename: historyOperation = String(localized: "Saving conversation name…")
        case CommandIDs.aiChatDelete: historyOperation = String(localized: "Deleting conversation…")
        default: historyOperation = nil
        }
        if let historyOperation { historyOperationLabel = historyOperation }
        Task { @MainActor in
            defer { if historyOperation != nil { historyOperationLabel = nil } }
            do {
                _ = try await app.bus.execute(command, params, session: session)
                if historyOperation != nil { error = nil }
                if command == CommandIDs.aiChatRename { renamingChat = nil }
                if command == CommandIDs.aiChatRename || command == CommandIDs.aiChatDelete {
                    if command == CommandIDs.aiChatDelete, params["chat"]?.stringValue == chatID { stop(); try newChat() }
                    try await refreshChats()
                }
                if command == CommandIDs.aiChatFeedback, let message = params["message"]?.stringValue,
                   let i = entries.firstIndex(where: { $0.id == message }) {
                    let rating = params["rating"]?.stringValue
                    entries[i].rating = rating == "none" ? nil : rating
                }
            } catch { self.error = NibError.wrap(error) }
        }
    }

    func loadContext(principal: Principal = .user) async throws {
        guard let app else { throw NibError.unavailable("assistant is closed") }
        let result = try await app.bus.execute(CommandIDs.queryContext, [:], principal: principal, session: session)
        let value = result
        docKind = value["document"]?["kind"]?.stringValue.flatMap(DocumentKind.init(rawValue:))
        refreshProviderLabel()
        refreshContextLabel()
    }

    func setScope(_ kind: AIScopeKind, refs: [String] = []) throws {
        let doc = session?.document
        let page = session?.page
        let selected = refs.isEmpty ? (session?.selection.refs ?? []) : refs
        switch kind {
        case .library: scope = AIScope(kind: kind)
        case .document:
            guard let doc else { throw NibError.invalid("no document is open", path: "$.scope") }
            scope = AIScope(kind: kind, doc: doc)
        case .page:
            guard let doc, let page else { throw NibError.invalid("no page is open", path: "$.scope") }
            scope = AIScope(kind: kind, doc: doc, page: page)
        case .selection, .block:
            guard !selected.isEmpty, selected.allSatisfy({ if case .item? = NodeRef($0) { return true }; if case .block? = NodeRef($0) { return true }; return false }) else {
                throw NibError.invalid("select an item or block first", path: "$.refs")
            }
            if kind == .block, !selected.allSatisfy({ if case .block? = NodeRef($0) { return true }; return false }) {
                throw NibError.invalid("block context needs block refs", path: "$.refs")
            }
            scope = AIScope(kind: kind, doc: NodeRef(selected[0])?.documentID,
                            page: NodeRef(selected[0])?.pageID, refs: selected)
        }
        refreshContextLabel()
    }

    func refreshChats(principal: Principal = .user) async throws {
        guard let app else { throw NibError.unavailable("assistant is closed") }
        let previousOperation = historyOperationLabel
        if previousOperation == nil { historyOperationLabel = String(localized: "Loading conversations…") }
        defer { historyOperationLabel = previousOperation }
        let result = try await app.bus.execute(CommandIDs.aiChatList, ["all": true], principal: principal, session: session)
        conversations = try result.decode(ChatListResult.self).chats
    }

    func selectChat(_ id: String, principal: Principal = .user) async throws {
        guard canChangeConversation else { throw NibError(.conflict, "stop this turn before switching conversations") }
        guard let app else { throw NibError.unavailable("assistant is closed") }
        let token = UUID()
        loadToken = token
        isLoadingChat = true
        defer { if loadToken == token { loadToken = nil; isLoadingChat = false } }
        let result = try await app.bus.execute(CommandIDs.aiChatList, ["all": true, "chat": .string(id)], principal: principal, session: session)
        guard loadToken == token, !isStreaming, !isGeneratingImage else { throw CancellationError() }
        let list = try result.decode(ChatListResult.self)
        let restored = try await ChatArchive.restore(chat: id, listed: list.messages ?? [], metadata: app.services.library?.metadataURL)
        guard loadToken == token, !isStreaming, !isGeneratingImage else { throw CancellationError() }
        chatID = id
        conversations = list.chats
        entries = restored.map(\.entry)
        let usage = restored.compactMap(\.usage)
        totalTokens = usage.isEmpty ? app.settings.get(Self.tokenKey(id)) : usage.reduce(0) { $0 + $1.input + $1.output }
        proposals = []; proposalApplyGroup = nil; localUndo.removeAllActions()
        for i in entries.indices { resolveEntryCitations(i) }
        if let owner = list.chats.first(where: { $0.id == id })?.doc, let ref = NodeRef(owner), let doc = ref.documentID {
            scope = AIScope(kind: .document, doc: doc)
        } else { scope = AIScope(kind: .library) }
        refreshContextLabel()
        showsConversations = false
        composer = ""
        attachments = []
        draft = nil
        error = nil
        retryPrompt = nil
    }

    func newChat() throws {
        guard canChangeConversation else { throw NibError(.conflict, "stop this turn before starting a conversation") }
        loadToken = nil
        isLoadingChat = false
        chatID = nil
        totalTokens = 0
        entries = []
        proposals = []
        proposalApplyGroup = nil
        localUndo.removeAllActions()
        attachments = []
        composer = ""
        draft = nil
        error = nil
        retryPrompt = nil
        showsConversations = false
    }

    @discardableResult
    func send(prompt: String, principal: Principal, group: String, retry: Bool = false,
              linkUndoAcrossDocuments: (@MainActor () -> Void)? = nil) async throws -> AIResponse {
        guard let app, let ai = app.services.ai, ai.isConfigured else {
            throw NibError(.unavailable, "Connect a model to use the assistant.", hint: "open Settings › AI")
        }
        guard canStartGeneration else { throw NibError(.conflict, "a turn or conversation load is already running") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NibError.invalid("enter a question or instruction", path: "$.prompt") }
        let images = retry ? retryImages : attachments
        guard images.isEmpty || ai.supportsVision else {
            throw NibError(.unsupported, "this model cannot read images", hint: "choose a model with vision in Settings › AI")
        }
        guard proposals.isEmpty else { throw NibError(.conflict, "accept or discard the pending proposals first") }
        let id = chatID ?? NibID.make().raw
        chatID = id
        let prior = retry ? entries.first(where: { $0.id == retryEntry }) : nil
        if let prior, !prior.changes.isEmpty, !prior.reverted {
            throw NibError(.conflict, "Undo this turn's partial changes before retrying.")
        }
        let replacesPartialText = retry && (prior?.changes.isEmpty ?? true)
        let answerID = replacesPartialText ? (retryEntry ?? NibID.make().raw) : NibID.make().raw
        if replacesPartialText, let i = entries.firstIndex(where: { $0.id == answerID }) {
            entries[i].tools = []
            entries[i].text = ""
            entries[i].changes = ChangeSummary()
            entries[i].group = group
            entries[i].isPersisted = false
        } else {
            entries.append(ChatEntry(id: NibID.make().raw, role: "user", text: text, images: images))
            entries.append(ChatEntry(id: answerID, role: "assistant", text: "", group: group))
        }
        let token = UUID()
        generation = token
        isStreaming = true
        error = nil
        composer = ""
        attachments = []
        retryPrompt = text
        retryImages = images
        retryEntry = answerID
        let effectivePrincipal = principal.isUser ? Principal.ai(id) : principal
        var request = AIRequest(chatID: id, messages: [AIMessage(role: "user", text: text, images: images.isEmpty ? nil : images)],
                                mode: mode, scope: scope, principal: effectivePrincipal, group: group)
        if mode == .edit {
            request.system = "For proposed note edits, call ai.chat.propose with changes [{command, params, title}]. Each row must be an independent command. Use commands.describe to read its schema. These edits remain previews until the user accepts individual rows. Do not claim they are applied."
        }
        // Commit observers run synchronously on the bus's main actor. Keep the receipt accurate even if Stop wins
        // the race with a queued toolFinished stream event.
        let commits = app.bus.observeCommits { [weak self] changeset in
            guard changeset.group == group else { return }
            MainActor.assumeIsolated {
                guard let self, let i = self.entries.firstIndex(where: { $0.id == answerID }) else { return }
                self.entries[i].changes.merge(changeset.summary)
                if Set(self.entries[i].changes.all.compactMap { NodeRef($0)?.documentID }).count > 1 {
                    linkUndoAcrossDocuments?()
                }
            }
        }
        defer {
            commits.cancel()
            if generation == token {
                isStreaming = false
                generation = nil
                if let i = entries.firstIndex(where: { $0.id == answerID }) {
                    for j in entries[i].tools.indices where entries[i].tools[j].succeeded == nil { entries[i].tools[j].succeeded = false }
                }
                resolveConfirmation(.deny)
            }
        }
        do {
            for try await event in ai.stream(request) {
                guard generation == token, !Task.isCancelled else { throw CancellationError() }
                guard let i = entries.firstIndex(where: { $0.id == answerID }) else { throw CancellationError() }
                switch event {
                case .text(let delta):
                    entries[i].text += delta
                    resolveEntryCitations(i)
                case .toolStarted(let name, let arguments):
                    entries[i].tools.append(ChatToolActivity(name: name, arguments: arguments))
                case .toolFinished(let name, let ok, let changes):
                    if let j = entries[i].tools.firstIndex(where: { $0.name == name && $0.succeeded == nil }) {
                        entries[i].tools[j].succeeded = ok
                        entries[i].tools[j].changes = changes
                    }
                    if let changes { entries[i].changes.merge(changes) }
                case .finished(let response):
                    entries[i].text = response.text
                    resolveEntryCitations(i)
                    entries[i].changes.merge(response.changes)
                    entries[i].group = response.group ?? group
                    entries[i].usage = response.usage
                    chatID = response.chatID ?? id
                    let key = Self.tokenKey(chatID ?? id)
                    totalTokens = max(totalTokens, app.settings.get(key)) + response.usage.input + response.usage.output
                    retryPrompt = nil
                    // Fetch persisted message ids so feedback always targets this answer, not a later one.
                    if app.commands.entry(CommandIDs.aiChatList) != nil {
                        do {
                            let list = try await app.bus.execute(CommandIDs.aiChatList, ["chat": .string(chatID ?? id)], session: session)
                            let stored = try list.decode(ChatListResult.self)
                            if generation == token { conversations = stored.chats }
                            if generation == token, let current = entries.firstIndex(where: { $0.id == answerID }),
                               let last = stored.messages?.last(where: { $0.role == "assistant" && ($0.group == (response.group ?? group) || ($0.group == nil && $0.text == response.text)) }) {
                                entries[current].id = last.id
                                entries[current].isPersisted = true
                            }
                        } catch { /* The streamed receipt remains usable when the catalogue is temporarily unavailable. */ }
                    }
                    try await persistConversation()
                    return response
                case .failed(let failure): throw failure
                }
            }
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            throw NibError(.unavailable, "the provider closed the stream before completing the answer", hint: "retry this turn")
        } catch {
            if generation == token, !(error is CancellationError) { self.error = NibError.wrap(error) }
            try? await persistConversation()
            throw error
        }
    }

    func stop() {
        imageTask?.cancel()
        imageTask = nil
        loadToken = nil
        isLoadingChat = false
        if let id = chatID { app?.services.ai?.cancel(chatID: id) }
        for i in entries.indices {
            for j in entries[i].tools.indices where entries[i].tools[j].succeeded == nil {
                entries[i].tools[j].succeeded = false
                entries[i].tools[j].cancelled = true
            }
        }
        generation = nil
        isStreaming = false
        isGeneratingImage = false
        resolveConfirmation(.deny)
    }

    func undo(_ entryID: String, context: CommandContext) async throws -> JSONValue {
        guard let i = entries.firstIndex(where: { $0.id == entryID }), let group = entries[i].group else {
            throw NibError(.unavailable, "this answer has no undo group")
        }
        guard !entries[i].reverted else { throw NibError(.conflict, "these changes have already been reverted") }
        let docs = Set(entries[i].changes.all.compactMap { NodeRef($0)?.documentID })
        guard !docs.isEmpty else { throw NibError(.notFound, "this answer did not change a document") }
        var reverted = 0
        var skipped = 0
        var notes: [String] = []
        var failed = 0
        for doc in docs.sorted(by: { $0.raw < $1.raw }) {
            let label = citationLabel(NodeRef.document(doc).description)
            do {
                let result = try await context.execute(CommandIDs.revertGroup,
                                                      ["doc": .string(NodeRef.document(doc).description), "group": .string(group)])
                let count = result["reverted"]?.intValue ?? 0
                let kept = result["skipped"]?.intValue ?? 0
                reverted += count
                skipped += kept
                notes.append(String(localized: "\(label): \(count) changes reverted · \(kept) later edits kept"))
            } catch {
                failed += 1
                notes.append(String(localized: "\(label): Undo failed. \(NibError.wrap(error).message)"))
            }
        }
        if let current = entries.firstIndex(where: { $0.id == entryID }) {
            entries[current].reverted = failed == 0
            entries[current].revertNote = notes.joined(separator: "\n")
        }
        if failed > 0 { error = NibError(.conflict, notes.joined(separator: "\n")) }
        else if skipped > 0 { error = NibError(.conflict, "\(skipped) later edits were kept. \(reverted) changes reverted.") }
        try await persistConversation()
        return ["reverted": .number(Double(reverted)), "skipped": .number(Double(skipped))]
    }

    func showChanges(_ entryID: String, context: CommandContext) async throws {
        guard let entry = entries.first(where: { $0.id == entryID }) else { throw NibError.notFound("answer") }
        guard let raw = entry.changes.all.first else { return }
        let target: String
        if entry.changes.removed.contains(raw), let ref = NodeRef(raw) {
            if let d = ref.documentID, let p = ref.pageID { target = NodeRef.page(d, p).description }
            else if let d = ref.documentID { target = NodeRef.document(d).description }
            else { return }
        } else { target = raw }
        _ = try await context.execute(CommandIDs.viewReveal, ["ref": .string(target)])
        let visibleItems = entry.changes.all.filter { ref in
            guard !entry.changes.removed.contains(ref), let node = NodeRef(ref),
                  node.documentID == NodeRef(target)?.documentID, node.pageID == NodeRef(target)?.pageID else { return false }
            if case .item = node { return true }
            return false
        }
        if !visibleItems.isEmpty, context.app?.commands.entry(CommandIDs.selectionSet) != nil {
            _ = try await context.execute(CommandIDs.selectionSet, ["refs": .array(visibleItems.map(JSONValue.string))])
        } else if !visibleItems.isEmpty, let first = NodeRef(visibleItems[0]),
                  let doc = first.documentID, let page = first.pageID {
            context.activeSession?.selection = Selection(doc: doc, page: page, items: visibleItems.compactMap {
                if case .item(_, _, let item)? = NodeRef($0) { return item }
                return nil
            })
        }
    }

    func generateImage(_ prompt: String) async throws {
        guard let app, let ai = app.services.ai, ai.isConfigured, let assets = app.services.assets else {
            throw NibError.unavailable("connect a model and an asset store first")
        }
        guard canStartGeneration else { throw NibError(.conflict, "a turn or conversation load is already running") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NibError.invalid("describe an image", path: "$.prompt") }
        let token = UUID()
        generation = token
        isGeneratingImage = true
        composer = ""
        error = nil
        let task = Task { try await ai.generateImage(prompt: prompt) }
        imageTask = task
        defer { if generation == token { generation = nil; isGeneratingImage = false; imageTask = nil } }
        do {
            let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == token else { throw CancellationError() }
            let result = try await Task.detached { () throws -> (AssetRef, UIImage?) in
                let normalized = try ChatImageBytes.normalized(data)
                let ref = try assets.putTemporary(normalized.data, ext: normalized.ext)
                return (ref, UIImage(data: normalized.data))
            }.value
            guard generation == token else { throw CancellationError() }
            draft = ChatDraft(text: "", asset: result.0, image: result.1, prompt: prompt)
        } catch {
            if generation == token, !(error is CancellationError) { self.error = NibError.wrap(error) }
            throw error
        }
    }

    func persistConversation() async throws {
        guard let app, let chatID, let metadata = app.services.library?.metadataURL else { return }
        // Reconcile the user message too, so attachments merge by F084's canonical message id.
        if app.commands.entry(CommandIDs.aiChatList) != nil,
           let value = try? await app.bus.execute(CommandIDs.aiChatList, ["chat": .string(chatID)], session: session),
           let stored = try? value.decode(ChatListResult.self) {
            var used = Set(entries.filter(\.isPersisted).map(\.id))
            for i in entries.indices where !entries[i].isPersisted && !entries[i].isReceipt {
                if let match = stored.messages?.first(where: { !used.contains($0.id) && $0.role == entries[i].role && $0.text == entries[i].text && ($0.group == nil || $0.group == entries[i].group) }) {
                    entries[i].id = match.id; entries[i].isPersisted = true; used.insert(match.id)
                }
            }
        }
        let records = entries.filter { $0.isPersisted || $0.isReceipt }.map { ChatArchive.Record(message: StoredChatEntry($0), rev: app.clock.tick()) }
        try await ChatArchive.save(chat: chatID, device: app.deviceHex, records: records, metadata: metadata,
                                   assets: app.services.assets, doc: scope.doc)
    }

    func imageURL(_ asset: AssetRef) -> URL? {
        if let metadata = app?.services.library?.metadataURL {
            let url = ChatArchive.assetURL(asset.name, metadata: metadata)
            if let url, FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return app?.services.assets?.temporaryURL(asset) ?? scope.doc.flatMap { app?.services.assets?.url(asset, doc: $0) }
    }

    private func resolveEntryCitations(_ index: Int) {
        var entry = entries[index]
        entry.resolveCitations(citationLabel)
        entries[index] = entry
    }

    func confirmationTargetLabel(_ raw: String) -> String {
        let label = citationLabel(raw)
        guard let ref = NodeRef(raw), let doc = ref.documentID,
              let title = app?.services.library?.node(doc)?.title else { return label }
        if case .document = ref { return title }
        return "\(title) · \(label)"
    }

    func citationLabel(_ raw: String) -> String {
        if let cached = citationLabels[raw] { return cached }
        guard let ref = NodeRef(raw) else { return String(localized: "Reference") }
        let content = ref.documentID.flatMap { try? app?.workspace.content($0) }
        let label: String
        switch ref {
        case .document(let doc): label = app?.services.library?.node(doc)?.title ?? String(localized: "Document")
        case .page(_, let page):
            label = content?.pageIndex(page).map { String(localized: "Page \($0 + 1)") } ?? String(localized: "Page")
        case .item(let doc, let page, let item):
            let kind = (try? app?.workspace.item(doc, page: page, id: item).kind.rawValue.capitalized) ?? String(localized: "Item")
            label = content?.pageIndex(page).map { String(localized: "\(kind) on page \($0 + 1)") } ?? kind
        case .block(_, let block):
            label = content?.liveBlocks.firstIndex(where: { $0.id == block }).map { String(localized: "Block \($0 + 1)") } ?? String(localized: "Block")
        case .card: label = String(localized: "Card")
        case .audio: label = String(localized: "Audio recording")
        case .outline: label = String(localized: "Outline entry")
        case .library: label = String(localized: "Library")
        case .folder: label = String(localized: "Folder")
        }
        citationLabels[raw] = label
        return label
    }

    func requestConfirmation(_ pending: ChatConfirmation) async -> ConfirmationDecision {
        resolveConfirmation(.deny)
        confirmation = pending
        return await withCheckedContinuation { confirmationContinuation = $0 }
    }

    func resolveConfirmation(_ decision: ConfirmationDecision) {
        let continuation = confirmationContinuation
        confirmationContinuation = nil
        confirmation = nil
        continuation?.resume(returning: decision)
    }
}

/// Citation refs are an explicit part of F084's system prompt; never turn arbitrary URLs into commands.
enum ChatCitations {
    static let regex = try! NSRegularExpression(pattern: #"(?:item|page|doc|block|card|audio|outline):[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+){0,2}"#)

    static func replacingRefs(in text: String, labels: [String: String], refs: [String]? = nil) -> String {
        var result = text
        for raw in (refs ?? Self.refs(in: text)).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: raw, with: labels[raw] ?? String(localized: "Reference"))
        }
        return result
    }
    static func refs(in text: String) -> [String] {

        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let raw = ns.substring(with: $0.range)
            guard NodeRef(raw) != nil, seen.insert(raw).inserted else { return nil }
            return raw
        }
    }
}


/// Preserve wire-compatible bytes; convert other decodable image formats before storing.
enum ChatImageBytes {
    static func normalized(_ data: Data) throws -> (data: Data, ext: String) {
        guard let image = UIImage(data: data) else { throw NibError.invalid("unreadable image", path: "$.image") }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return (data, "png") }
        if data.starts(with: [0xff, 0xd8, 0xff]) { return (data, "jpg") }
        guard let png = image.pngData() else { throw NibError.invalid("cannot convert image", path: "$.image") }
        return (png, "png")
    }
}

/// Presentation metadata supplements, never rewrites, F084's chat records. The folder is inside the synced
/// AI metadata tree; F084 scans only its top-level JSONL files. I/O is serialized off the main actor.
actor ChatArchive {
    static let io = ChatArchive()
    struct Record: Codable {
        var message: StoredChatEntry
        var rev: Rev
    }
    private struct AgentRecord: Decodable {
        var message: StoredChatEntry
        var rev: Rev
        var deleted: Bool
        var type: String
        enum CodingKeys: String, CodingKey { case rev, deleted, type }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "message"
            message = try StoredChatEntry(from: decoder)
        }
    }

    static func assetURL(_ name: String, metadata: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
        return metadata.appendingPathComponent("ai/presentation/assets", isDirectory: true).appendingPathComponent(name)
    }
    static func restore(chat: String, listed: [StoredChatEntry], metadata: URL?) async throws -> [StoredChatEntry] {
        guard NibID.isValid(chat), let metadata else { return listed }
        return try await io.load(chat: chat, listed: listed, metadata: metadata)
    }
    static func save(chat: String, device: String, records: [Record], metadata: URL, assets: AssetStore?, doc: DocumentID?) async throws {
        guard NibID.isValid(chat), device.count == 8, device.allSatisfy({ $0.isHexDigit }) else { throw NibError.invalid("invalid conversation archive id") }
        try await io.write(chat: chat, device: device, records: records, metadata: metadata, assets: assets, doc: doc)
    }

    private func files(_ directory: URL, chat: String) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix(chat + ".") && $0.pathExtension == "jsonl" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func records<T: Decodable>(_ type: T.Type, url: URL) throws -> [T] {
        // A torn line is skipped just as in F084. An unreadable file is surfaced to the caller.
        try Data(contentsOf: url).split(separator: 0x0a).compactMap { try? JSONDecoder().decode(type, from: Data($0)) }
    }
    private func merged(chat: String, metadata: URL) throws -> [String: Record] {
        var result: [String: Record] = [:]
        for file in try files(metadata.appendingPathComponent("ai/presentation"), chat: chat) {
            for record in try records(Record.self, url: file) {
                if result[record.message.id].map({ $0.rev.effective() >= record.rev.effective() }) != true { result[record.message.id] = record }
            }
        }
        return result
    }
    private func load(chat: String, listed: [StoredChatEntry], metadata: URL) throws -> [StoredChatEntry] {
        var agent: [String: AgentRecord] = [:]
        for file in try files(metadata.appendingPathComponent("ai"), chat: chat) {
            for record in try records(AgentRecord.self, url: file) where record.type == "message" {
                if agent[record.message.id].map({ $0.rev.effective() >= record.rev.effective() }) != true { agent[record.message.id] = record }
            }
        }
        let presentation = try merged(chat: chat, metadata: metadata)
        // List owns visibility, message order and feedback. Never resurrect a deleted or inaccessible message.
        var restored = listed.compactMap { base -> StoredChatEntry? in
            guard agent[base.id]?.deleted != true else { return nil }
            var result = base
            let disk = agent[base.id]?.message
            let ui = presentation[base.id]?.message
            result.images = ui?.images ?? disk?.images ?? base.images
            result.usage = disk?.usage ?? ui?.usage ?? base.usage
            result.tools = ui?.tools ?? disk?.tools ?? base.tools
            result.cancelled = disk?.cancelled ?? ui?.cancelled ?? base.cancelled
            result.reverted = ui?.reverted ?? base.reverted
            result.revertNote = ui?.revertNote ?? base.revertNote
            return result
        }
        let ids = Set(restored.map(\.id))
        restored += presentation.values.map(\.message).filter { $0.receipt == true && !ids.contains($0.id) }
            .sorted { ($0.at ?? 0, $0.id) < ($1.at ?? 0, $1.id) }
        return restored
    }
    private func write(chat: String, device: String, records incoming: [Record], metadata: URL, assets: AssetStore?, doc: DocumentID?) throws {
        let directory = metadata.appendingPathComponent("ai/presentation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(chat + "." + device + ".jsonl")
        var own = Dictionary((FileManager.default.fileExists(atPath: file.path) ? try records(Record.self, url: file) : []).map { ($0.message.id, $0) }, uniquingKeysWith: { $0.rev > $1.rev ? $0 : $1 })
        let existing = try merged(chat: chat, metadata: metadata)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for record in incoming {
            for name in record.message.images ?? [] {
                guard let dest = Self.assetURL(name, metadata: metadata) else { throw NibError.invalid("invalid attachment name") }
                if !FileManager.default.fileExists(atPath: dest.path), let assets,
                   let source = assets.temporaryURL(AssetRef(name)) ?? doc.flatMap({ assets.url(AssetRef(name), doc: $0) }) {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(contentsOf: source).write(to: dest, options: .atomic)
                }
            }
            if let prior = existing[record.message.id], try encoder.encode(prior.message) == encoder.encode(record.message) { continue }
            own[record.message.id] = record
        }
        var data = Data()
        for record in own.values.sorted(by: { $0.message.id < $1.message.id }) { data.append(try encoder.encode(record)); data.append(0x0a) }
        try data.write(to: file, options: .atomic)
    }
}

struct ChatProposal: Identifiable {
    var id = NibID.make().raw
    var number: Int
    var command: String
    var params: JSONValue
    var title: String
    var changes: ChangeSummary
    var originals: [String: JSONValue]
    var included = true
    var destructive: Bool
    var target: String?
    var previewText: String
    var group: String
}

@MainActor
extension ChatViewModel {
    var proposalNeedsReview: Bool {
        !proposalsReviewed && (proposals.reduce(0) { $0 + $1.changes.count } > 10 || Set(proposals.flatMap { $0.changes.all }.compactMap {
            guard let ref = NodeRef($0), let doc = ref.documentID else { return nil as String? }
            return doc.raw + "/" + (ref.pageID?.raw ?? "blocks")
        }).count > 1)
    }

    func proposalSnapshot(_ ref: String) throws -> JSONValue {
        guard let app, let node = NodeRef(ref), let doc = node.documentID else { throw NibError.invalid("invalid proposal ref") }
        switch node {
        case .item(_, let page, let item):
            return try JSONValue.from(app.workspace.allItems(doc, page: page).first { $0.id == item })
        case .block(_, let block):
            return try JSONValue.from(app.workspace.content(doc).blocks.first { $0.id == block })
        case .page(_, let page):
            return try JSONValue.from(app.workspace.content(doc).pages.first { $0.id == page })
        default: return try JSONValue.from(app.workspace.content(doc))
        }
    }

    func stageProposals(_ rows: [JSONValue], context: CommandContext) async throws -> JSONValue {
        guard let app, mode == .edit, !isApplyingProposals, !isStagingProposals, !isLoadingChat else { throw NibError(.conflict, "switch to Edit before proposing changes") }
        guard !rows.isEmpty, rows.count + proposals.count <= 100 else { throw NibError.invalid("propose between 1 and 100 independent changes") }
        if !context.principal.isUser {
            guard case .ai(let chat) = context.principal, chat == chatID, isStreaming else { throw NibError(.permissionDenied, "proposals belong to this window's active AI turn") }
        }
        let turn = turnToken
        let chat = chatID
        isStagingProposals = true
        defer { isStagingProposals = false }
        var staged: [ChatProposal] = []
        for row in rows {
            let command = try ChatCommands.string(row, "command")
            guard let descriptor = app.commands.descriptor(command), descriptor.effect == .edit,
                  descriptor.owner != FeatAIChatFeature.id, !descriptor.sensitive, !descriptor.userPresence,
                  !descriptor.forwardsCalls, !descriptor.scopes.contains(.network),
                  app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self)?.installed.contains(where: { $0.id == descriptor.owner }) != true else {
                throw NibError(.unsupported, "this command cannot be staged safely", hint: "propose independent local document edits")
            }
            var params = row["params"] ?? [:]
            guard params.objectValue != nil else { throw NibError.invalid("proposal params must be an object") }
            // Freeze caller-chosen ids and session defaults at preview time.
            if descriptor.params.toJSON()["properties"]?["id"] != nil, params["id"] == nil { params = params.merging(["id": .string(NibID.make().raw)]) }
            if descriptor.params.toJSON()["properties"]?["page"] != nil, params["page"] == nil, let doc = session?.document, let page = session?.page {
                params = params.merging(["page": .string(NodeRef.page(doc, page).description)])
            }
            if descriptor.params.toJSON()["properties"]?["doc"] != nil, params["doc"] == nil, let doc = session?.document {
                params = params.merging(["doc": .string(NodeRef.document(doc).description)])
            }
            if let issue = descriptor.params.validate(params).first { throw NibError.invalid(issue.message, path: issue.path) }
            let preview = try await app.bus.execute(Invocation(command: command, params: params, principal: .user,
                session: session, group: context.group, dryRun: true))
            guard !preview.changes.isEmpty else { throw NibError.invalid("the proposal has no document changes") }
            let touched = Set(preview.changes.all)
            guard !proposals.contains(where: { !Set($0.changes.all).isDisjoint(with: touched) }),
                  !staged.contains(where: { !Set($0.changes.all).isDisjoint(with: touched) }) else {
                throw NibError(.conflict, "each proposal must change independent records")
            }
            var originals: [String: JSONValue] = [:]
            for ref in touched { originals[ref] = try proposalSnapshot(ref) }
            staged.append(ChatProposal(number: proposals.count + staged.count + 1, command: command, params: params,
                title: row["title"]?.stringValue ?? descriptor.title, changes: preview.changes, originals: originals,
                destructive: descriptor.destructive || !preview.changes.removed.isEmpty,
                target: preview.changes.all.first, previewText: (try? params["text"]?.decode(RichText.self).plainText) ?? row["title"]?.stringValue ?? descriptor.title,
                group: context.group))
        }
        if !context.principal.isUser, turn != turnToken || chat != chatID || !isStreaming { throw CancellationError() }
        if !context.dryRun {
            let prior = proposals
            registerProposalUndo(prior, title: String(localized: "Propose changes"))
            if proposals.isEmpty { proposalApplyGroup = nil }
            proposals += staged; proposalsReviewed = false
        }
        return ["proposed": .number(Double(staged.count)), "applied": false, "ids": .array(staged.map { .string($0.id) })]
    }

    func registerContextUndo() {
        let previousScope = scope, previousMode = mode, previousLabel = contextLabel
        let manager = windowUndoManager ?? (session?.editor as? UIViewController)?.undoManager ?? localUndo
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerContextUndo()
                model.scope = previousScope; model.mode = previousMode; model.contextLabel = previousLabel
            }
        }
        manager.setActionName(String(localized: "Change assistant context"))
    }

    func setPreviewVisibility(_ visible: Bool) {
        let prior = showsProposalsOnPage
        let manager = windowUndoManager ?? (session?.editor as? UIViewController)?.undoManager ?? localUndo
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setPreviewVisibility(prior) }
        }
        manager.setActionName(String(localized: "Preview proposals"))
        showsProposalsOnPage = visible
    }

    func registerProposalUndo(_ previous: [ChatProposal], title: String) {
        let manager = windowUndoManager ?? (session?.editor as? UIViewController)?.undoManager ?? localUndo
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.proposals
                model.registerProposalUndo(current, title: title)
                model.proposals = previous; model.proposalsReviewed = false
            }
        }
        manager.setActionName(title)
    }

    func changeProposal(_ action: String, id: String?, included: [String]?, visible: Bool?) throws {
        guard !isStreaming, !isApplyingProposals, !isStagingProposals else { throw NibError(.conflict, "wait for the current turn") }
        if action == "preview" {
            setPreviewVisibility(visible ?? !showsProposalsOnPage)
            return
        }
        if let id, !proposals.contains(where: { $0.id == id }) { throw NibError.notFound("proposal") }
        if let included, !Set(included).isSubset(of: Set(proposals.map(\.id))) { throw NibError.notFound("proposal") }
        registerProposalUndo(proposals, title: String(localized: "Choose proposed changes"))
        if action == "discard" { proposals.removeAll { id == nil || $0.id == id } }
        else if action == "include", let included {
            for i in proposals.indices { proposals[i].included = included.contains(proposals[i].id) }
        } else { throw NibError.invalid("unknown proposal action") }
    }

    func applyProposals(id: String?, context: CommandContext) async throws -> JSONValue {
        guard context.principal.isUser else { throw NibError(.permissionDenied, "only the user may accept proposals") }
        guard canStartGeneration else { throw NibError(.conflict, "wait for the current turn") }
        guard !proposalNeedsReview else { throw NibError(.conflict, "review these changes before accepting") }
        let selected = proposals.filter { row in id.map { $0 == row.id } ?? (row.included && !row.destructive) }
        guard !selected.isEmpty else { throw NibError(.unavailable, "include a proposal before accepting") }
        // Preflight every selected row before writing any of them. Later edits are never silently overwritten.
        for proposal in selected {
            for (ref, original) in proposal.originals where try proposalSnapshot(ref) != original {
                throw NibError(.conflict, "a proposed record changed after its preview", hint: "discard it and ask for a new proposal")
            }
        }
        if context.dryRun { return ["count": .number(Double(selected.count))] }
        proposalApplyGroup = context.group
        isApplyingProposals = true
        defer { isApplyingProposals = false }
        var changes = ChangeSummary()
        let chat = chatID ?? NibID.make().raw
        for proposal in selected {
            let result = try await ChatCommands.insertAIContent(proposal.command, proposal.params, context: context, chat: chat)
            let applied = (try? result["changes"]?.decode(ChangeSummary.self)) ?? ChangeSummary()
            changes.merge(applied)
            proposals.removeAll { $0.id == proposal.id }
            if let i = entries.lastIndex(where: { $0.group == context.group && $0.isReceipt }) { entries[i].changes.merge(applied) }
            else { entries.append(ChatEntry(id: NibID.make().raw, role: "assistant", text: String(localized: "Applied proposed changes."),
                changes: applied, group: context.group, isReceipt: true)) }
        }
        let turnChanges = entries.last(where: { $0.group == context.group && $0.isReceipt })?.changes ?? changes
        if Set(turnChanges.all.compactMap { NodeRef($0)?.documentID }).count > 1 { context.linkUndoAcrossDocuments() }
        try await persistConversation()
        return ["changes": try JSONValue.from(changes), "group": .string(context.group)]
    }
}
