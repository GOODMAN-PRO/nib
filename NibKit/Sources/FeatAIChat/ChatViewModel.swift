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

struct ChatToolActivity: Identifiable {
    var id = UUID().uuidString
    var name: String
    var arguments: JSONValue
    var succeeded: Bool?
    var cancelled = false
    var changes: ChangeSummary?
}

struct ChatConversation: Decodable, Identifiable {
    var id: String
    var title: String
    var doc: String?
    var updated: Double
}

struct StoredChatEntry: Decodable {
    var id: String
    var role: String
    var text: String
    var group: String?
    var changes: ChangeSummary?
    var rating: String?
    var at: Double?
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
    @Published var isGeneratingImage = false
    @Published var error: NibError?
    @Published var showsConversations = false
    @Published var renamingChat: String?
    @Published var renameTitle = ""
    @Published var showsTools = false
    @Published var draft: ChatDraft?
    @Published var confirmation: ChatConfirmation?
    @Published var providerLabel = String(localized: "Your provider · your API key")
    @Published var contextLabel = String(localized: "Library")
    @Published var docKind: DocumentKind?
    @Published var needsImagePicker = false
    @Published var retryPrompt: String?
    private var generation: UUID?
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
            contextLabel = String(localized: "Document")
        }
    }

    static func tokenKey(_ chat: String) -> SettingKey<Int> { SettingKey("aichat.tokens." + chat, default: 0) }
    var tokenCount: Int { totalTokens }
    var settingsPageID: String {
        app?.ui.settingsPages.all.first(where: { $0.owner == "aisettings" })?.id ?? "settings.ai"
    }
    var isConfigured: Bool { app?.services.ai?.isConfigured ?? false }
    var quickActions: [AIActionDescriptor] {
        app?.content.aiActions.all.filter { action in
            docKind.map { action.docKinds.contains($0) } ?? (action.scope == .library)
        } ?? []
    }

    func perform(_ command: String, _ params: JSONValue = [:]) {
        guard let app else { return }
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(command, params, session: session)
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
        if let store = app.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self),
           let config = store.configs.first(where: { $0.id == store.activeID }) {
            providerLabel = "\(config.model) · \(config.name) · " + String(localized: "your API key")
        }
        if scope.kind == .page, let index = value["page"]?["index"]?.intValue {
            contextLabel = String(localized: "Page \(index)")
        }
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
        switch kind {
        case .selection: contextLabel = String(localized: "Selection · \(selected.count) items")
        case .block: contextLabel = String(localized: "Block · \(selected.count) selected")
        case .page: contextLabel = String(localized: "Page")
        case .document: contextLabel = String(localized: "Document")
        case .library: contextLabel = String(localized: "Library")
        }
    }

    func refreshChats(principal: Principal = .user) async throws {
        guard let app else { throw NibError.unavailable("assistant is closed") }
        let result = try await app.bus.execute(CommandIDs.aiChatList, ["all": true], principal: principal, session: session)
        conversations = try result.decode(ChatListResult.self).chats
    }

    func selectChat(_ id: String, principal: Principal = .user) async throws {
        guard !isStreaming, !isGeneratingImage else { throw NibError(.conflict, "stop this turn before switching conversations") }
        guard let app else { throw NibError.unavailable("assistant is closed") }
        let token = UUID()
        loadToken = token
        isLoadingChat = true
        defer { if loadToken == token { loadToken = nil; isLoadingChat = false } }
        let result = try await app.bus.execute(CommandIDs.aiChatList, ["all": true, "chat": .string(id)], principal: principal, session: session)
        guard loadToken == token, !isStreaming, !isGeneratingImage else { throw CancellationError() }
        let list = try result.decode(ChatListResult.self)
        chatID = id
        totalTokens = app.settings.get(Self.tokenKey(id))
        conversations = list.chats
        entries = (list.messages ?? []).map {
            ChatEntry(id: $0.id, role: $0.role, text: $0.text, changes: $0.changes ?? ChangeSummary(),
                      group: $0.group, rating: $0.rating, at: Date(timeIntervalSince1970: $0.at ?? 0), isPersisted: true)
        }
        for i in entries.indices { resolveEntryCitations(i) }
        if let owner = list.chats.first(where: { $0.id == id })?.doc, let ref = NodeRef(owner), let doc = ref.documentID {
            scope = AIScope(kind: .document, doc: doc)
            contextLabel = String(localized: "Document")
        } else { scope = AIScope(kind: .library); contextLabel = String(localized: "Library") }
        showsConversations = false
        composer = ""
        attachments = []
        draft = nil
        error = nil
        retryPrompt = nil
    }

    func newChat() throws {
        guard !isStreaming, !isGeneratingImage else { throw NibError(.conflict, "stop this turn before starting a conversation") }
        loadToken = nil
        isLoadingChat = false
        chatID = nil
        totalTokens = 0
        entries = []
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
        guard !isStreaming, !isGeneratingImage, !isLoadingChat else { throw NibError(.conflict, "a turn or conversation load is already running") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NibError.invalid("enter a question or instruction", path: "$.prompt") }
        let images = retry ? retryImages : attachments
        guard images.isEmpty || ai.supportsVision else {
            throw NibError(.unsupported, "this model cannot read images", hint: "choose a model with vision in Settings › AI")
        }
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
        let request = AIRequest(chatID: id, messages: [AIMessage(role: "user", text: text, images: images.isEmpty ? nil : images)],
                                mode: mode, scope: scope, principal: effectivePrincipal, group: group)
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
                    return response
                case .failed(let failure): throw failure
                }
            }
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            throw NibError(.unavailable, "the provider closed the stream before completing the answer", hint: "retry this turn")
        } catch {
            if generation == token, !(error is CancellationError) { self.error = NibError.wrap(error) }
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
        guard !isStreaming, !isGeneratingImage, !isLoadingChat else { throw NibError(.conflict, "a turn or conversation load is already running") }
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

    private func resolveEntryCitations(_ index: Int) {
        var entry = entries[index]
        entry.resolveCitations(citationLabel)
        entries[index] = entry
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
