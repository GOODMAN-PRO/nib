import Foundation
import os
import NibContracts

/// os.Logger for the module (category = the feature id). Never logs prompts, answers or note content.
let agentLog = Logger(subsystem: "app.nib", category: "aiagent")

/// One line of a chat file: the chat's metadata (`id == ChatRecord.metaID`) or one message. Records merge
/// last-writer-wins by `rev` (ARCHITECTURE.md §4.3), so a message rated on another device, a rename or a deletion is
/// simply a newer copy of the same record.
struct ChatRecord: LWWRecord {
    /// Id of the metadata record (generated ids never contain "_", so it cannot clash with a message id).
    static let metaID: NibID = "_chat"
    static let metaType = "chat"
    static let messageType = "message"

    var id: NibID
    var rev: Rev
    var deleted: Bool
    /// "chat" | "message".
    var type: String

    // Metadata
    var title: String?
    /// Raw document id; nil = a library conversation.
    var doc: String?
    var created: Double?

    // Messages
    /// "user" | "assistant".
    var role: String?
    var text: String?
    /// Asset names (temporary assets or assets of `doc`).
    var images: [String]?
    /// Unix seconds.
    var at: Double?
    /// Undo group of the turn (assistant messages).
    var group: String?
    var changes: ChangeSummary?
    var usage: AIUsage?
    /// "ask" | "edit".
    var mode: String?
    /// "up" | "down" (thumbs), nil = not rated.
    var rating: String?
    var cancelled: Bool?
    var error: NibError?
    /// Tools the turn called, in order.
    var tools: [String]?

    init(id: NibID, rev: Rev, type: String) {
        self.id = id
        self.rev = rev
        self.deleted = false
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, type, title, doc, created, role, text, images, at, group, changes, usage, mode, rating,
             cancelled, error, tools
    }

    /// Lenient (§4.2): only `id` and `type` are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NibID.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        rev = (try? c.decodeIfPresent(Rev.self, forKey: .rev)) ?? .zero
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        doc = try? c.decodeIfPresent(String.self, forKey: .doc)
        created = try? c.decodeIfPresent(Double.self, forKey: .created)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        images = try? c.decodeIfPresent([String].self, forKey: .images)
        at = try? c.decodeIfPresent(Double.self, forKey: .at)
        group = try? c.decodeIfPresent(String.self, forKey: .group)
        changes = try? c.decodeIfPresent(ChangeSummary.self, forKey: .changes)
        usage = try? c.decodeIfPresent(AIUsage.self, forKey: .usage)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        rating = try? c.decodeIfPresent(String.self, forKey: .rating)
        cancelled = try? c.decodeIfPresent(Bool.self, forKey: .cancelled)
        error = try? c.decodeIfPresent(NibError.self, forKey: .error)
        tools = try? c.decodeIfPresent([String].self, forKey: .tools)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(rev, forKey: .rev)
        if deleted { try c.encode(true, forKey: .deleted) }
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(doc, forKey: .doc)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(images, forKey: .images)
        try c.encodeIfPresent(at, forKey: .at)
        try c.encodeIfPresent(group, forKey: .group)
        if let ch = changes, !ch.isEmpty { try c.encode(ch, forKey: .changes) }
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(cancelled, forKey: .cancelled)
        try c.encodeIfPresent(error, forKey: .error)
        if let t = tools, !t.isEmpty { try c.encode(t, forKey: .tools) }
    }

    var isMessage: Bool { type == ChatRecord.messageType }
    var isMeta: Bool { id == ChatRecord.metaID }

    /// The message as the `AIService` API shows it.
    var aiMessage: AIMessage {
        AIMessage(role: role ?? "user", text: text ?? "", images: images.flatMap { $0.isEmpty ? nil : $0.map { AssetRef($0) } })
    }
}

/// The merged state of one conversation.
struct ChatState {
    var records: [NibID: ChatRecord] = [:]

    var meta: ChatRecord? { records[ChatRecord.metaID] }
    var isDeleted: Bool { meta?.deleted == true }

    /// Live messages, oldest first (time, then revision).
    var messages: [ChatRecord] {
        records.values.filter { $0.isMessage && !$0.deleted }
            .sorted { ($0.at ?? 0, $0.rev) < ($1.at ?? 0, $1.rev) }
    }

    /// Keeps the newer record (far-future revisions are distrusted, `Rev.effective`). True when `r` won.
    @discardableResult
    mutating func absorb(_ r: ChatRecord, now: UInt64) -> Bool {
        if let old = records[r.id], r.rev.effective(now: now) <= old.rev.effective(now: now) { return false }
        records[r.id] = r
        return true
    }

    var title: String {
        if let t = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let first = messages.first(where: { $0.role == "user" }), let text = first.text {
            return ChatStore.title(from: text)
        }
        return "Conversation"
    }

    var updated: Double {
        let last = messages.last?.at ?? 0
        return max(last, meta?.created ?? 0, Double(meta?.rev.wallMs ?? 0) / 1000)
    }
}

/// Conversations stored per device in the library's AI folder: `<chat>.<dev>.jsonl`, one `ChatRecord` per line.
/// Each device appends only to its own files (§4.3); readers merge every device's file of a chat (and provider
/// conflict copies, which are folded into this device's file and then removed) by record id and revision. Writes run
/// on a serial background queue; the merged state in memory is updated at once, so reads never wait for the disk.
@MainActor
final class ChatStore {
    typealias Directory = @MainActor () -> URL?

    nonisolated static let fileExtension = "jsonl"

    let deviceHex: String
    /// How often `refresh()` rescans the folder for files other devices wrote (forced reads ignore it).
    var scanInterval: TimeInterval = 2

    private let directoryProvider: Directory
    private let clock: HLCClock
    private let io = DispatchQueue(label: "app.nib.aiagent.chats", qos: .utility)
    private var directory: URL?
    private var resolvedOnce = false
    private var chats: [String: ChatState] = [:]
    private var signatures: [String: FileSignature] = [:]
    private var ownLines: [String: Int] = [:]
    /// Chats whose file on this device holds only their tombstone.
    private var ownTombstoned = Set<String>()
    private var lastScan: Date?

    struct FileSignature: Equatable {
        var modified: Double
        var size: Int
    }

    /// `directory` is resolved at every access (the library folder can change); nil keeps chats in memory only.
    init(directory: @escaping Directory, deviceHex: String, clock: HLCClock) {
        self.directoryProvider = directory
        self.deviceHex = deviceHex
        self.clock = clock
    }

    // MARK: Reading

    /// Every live conversation of `doc` (nil = the library's), or of everything when `all`; newest first.
    func summaries(doc: DocumentID?, all: Bool = false) -> [AIChatSummary] {
        refresh()
        return chats.compactMap { id, state -> AIChatSummary? in
            guard !state.isDeleted, !(state.meta == nil && state.messages.isEmpty) else { return nil }
            let owner = state.meta?.doc.map { DocumentID($0) }
            guard all || owner == doc else { return nil }
            return AIChatSummary(id: id, title: state.title, doc: owner, updated: state.updated)
        }.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
    }

    /// The merged conversation (nil when unknown or deleted).
    func state(_ chat: String) -> ChatState? {
        refresh()
        guard let s = chats[chat], !s.isDeleted else { return nil }
        return s
    }

    func ownerDoc(_ chat: String) -> DocumentID? { state(chat)?.meta?.doc.map { DocumentID($0) } }

    /// Bare chat ids carry no document ref for the gateway to inspect.
    func checkAccess(_ chat: String, principal: Principal, gateway: Gateway) throws {
        guard !principal.isUser, let doc = ownerDoc(chat), gateway.isLocked(doc) else { return }
        throw NibError(.locked, "the conversation belongs to a locked document", hint: "ask the user to unlock it first")
    }

    func messages(_ chat: String) -> [ChatRecord] { state(chat)?.messages ?? [] }

    /// True when the conversation was deleted (on any device).
    func isDeleted(_ chat: String) -> Bool {
        refresh()
        return chats[chat]?.isDeleted ?? false
    }

    /// The messages the conversation shows (`AIService.messages`): answers that failed before writing anything are left out.
    func visibleMessages(_ chat: String) -> [ChatRecord] {
        messages(chat).filter { !($0.role == "assistant" && ($0.text ?? "").isEmpty) }
    }

    // MARK: Writing

    /// A new message record stamped with this device's clock.
    func makeMessage(role: String, text: String, images: [AssetRef]? = nil) -> ChatRecord {
        var r = ChatRecord(id: NibID.make(), rev: clock.tick(), type: ChatRecord.messageType)
        r.role = role
        r.text = text
        r.images = images.flatMap { $0.isEmpty ? nil : $0.map(\.name) }
        r.at = Date().timeIntervalSince1970
        return r
    }

    /// Creates the conversation's metadata when it has none yet (a chat continued from another device keeps its own).
    func ensureChat(_ chat: String, title: String, doc: DocumentID?) {
        refresh()
        if chats[chat]?.meta != nil { return }
        var meta = ChatRecord(id: ChatRecord.metaID, rev: clock.tick(), type: ChatRecord.metaType)
        meta.title = ChatStore.title(from: title)
        meta.doc = doc?.raw
        meta.created = Date().timeIntervalSince1970
        append([meta], chat: chat)
    }

    /// Appends records to this device's file of `chat` (and to the merged state).
    func append(_ records: [ChatRecord], chat: String) {
        guard !records.isEmpty else { return }
        let dir = currentDirectory()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var state = chats[chat] ?? ChatState()
        for r in records { state.absorb(r, now: now) }
        chats[chat] = state
        guard let dir = dir else { return }
        let url = dir.appendingPathComponent(ownFileName(chat))
        let data = ChatStore.encodeLines(records)
        ownLines[chat, default: 0] += records.count
        ownTombstoned.remove(chat)
        io.async { ChatStore.appendData(data, to: url, directory: dir) }
        compactIfNeeded(chat)
    }

    func rename(_ chat: String, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NibError.invalid("the title is empty", path: "$.title") }
        refresh(force: true)
        guard let state = chats[chat], !state.isDeleted else { throw ChatStore.unknownChat(chat) }
        var meta = state.meta ?? ChatRecord(id: ChatRecord.metaID, rev: .zero, type: ChatRecord.metaType)
        if meta.created == nil { meta.created = state.messages.first?.at ?? Date().timeIntervalSince1970 }
        meta.title = String(clean.prefix(200))
        meta.rev = clock.tick()
        append([meta], chat: chat)
    }

    /// Deletes a conversation everywhere: a tombstone replaces this device's file; other devices' files lose to it
    /// (and shrink to the tombstone the next time those devices read the folder).
    func delete(_ chat: String) throws {
        refresh(force: true)
        guard let state = chats[chat], !state.isDeleted else { throw ChatStore.unknownChat(chat) }
        var meta = state.meta ?? ChatRecord(id: ChatRecord.metaID, rev: .zero, type: ChatRecord.metaType)
        meta.deleted = true
        meta.rev = clock.tick()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var s = state
        s.absorb(meta, now: now)
        chats[chat] = s
        rewriteOwnFile(chat, records: [meta])
    }

    /// Rates an assistant message ("up" / "down"; nil clears the rating). `message` is a message id, "last" (the
    /// latest answer) or the 0-based position in `visibleMessages` (what `AIService.messages(chatID:)` lists).
    @discardableResult
    func rate(_ chat: String, message: String, rating: String?) throws -> ChatRecord {
        refresh(force: true)
        guard let state = chats[chat], !state.isDeleted else { throw ChatStore.unknownChat(chat) }
        let visible = visibleMessages(chat)
        var found = state.records[NibID(message)].flatMap { $0.isMessage && !$0.deleted ? $0 : nil }
        if found == nil && message == "last" { found = visible.last(where: { $0.role == "assistant" }) }
        if found == nil, let i = Int(message), visible.indices.contains(i) { found = visible[i] }
        guard var r = found else {
            throw NibError(.notFound, "message '\(message)' not found in conversation '\(chat)'",
                           hint: "pass a message id from ai.chat.list {chat}, 'last', or the message's position")
        }
        guard r.role == "assistant" else {
            throw NibError.invalid("only AI answers can be rated", path: "$.message")
        }
        r.rating = rating
        r.rev = clock.tick()
        append([r], chat: chat)
        return r
    }

    /// Waits until every queued write reached the disk.
    func flush() {
        io.sync {}
    }

    // MARK: Folder scan and merge

    /// Reads files that changed since the last scan (other devices' and conflict copies) and merges them in.
    func refresh(force: Bool = false) {
        let dir = currentDirectory()
        guard let dir = dir else { return }
        if !force, let last = lastScan, Date().timeIntervalSince(last) < scanInterval { return }
        lastScan = Date()
        io.sync {}
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var conflicts: [String: [String]] = [:]
        for name in names {
            guard let parsed = ChatStore.parseFileName(name) else { continue }
            let url = dir.appendingPathComponent(name)
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let signature = FileSignature(
                modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                size: (attributes?[.size] as? NSNumber)?.intValue ?? 0)
            let isOwn = parsed.device == deviceHex
            let isConflict = !isOwn && !ChatStore.isDeviceHex(parsed.device)
            guard isConflict || signatures[name] != signature else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let (records, lines) = ChatStore.decodeLines(data)
            // Retry unreadable/partially downloaded copies on the next scan; never delete undecoded records.
            if isConflict {
                guard records.count == lines else { continue }
                conflicts[parsed.chat, default: []].append(name)
            }
            signatures[name] = signature
            var state = chats[parsed.chat] ?? ChatState()
            for r in records {
                clock.observe(r.rev)
                state.absorb(r, now: now)
            }
            chats[parsed.chat] = state
            if isOwn {
                ownLines[parsed.chat] = lines
                if records.count == 1 && records[0].isMeta && records[0].deleted {
                    ownTombstoned.insert(parsed.chat)
                } else {
                    ownTombstoned.remove(parsed.chat)
                }
            }
        }
        for (chat, files) in conflicts { foldConflicts(chat, files: files, in: dir) }
        for (chat, state) in chats where state.isDeleted && ownLines[chat] != nil && !ownTombstoned.contains(chat) {
            // Another device deleted the chat: shrink this device's file to the tombstone.
            if let meta = state.meta { rewriteOwnFile(chat, records: [meta]) }
        }
    }

    private func currentDirectory() -> URL? {
        let dir = directoryProvider()
        if !resolvedOnce || dir != directory {
            // The library folder changed (or was set up): start from what the new folder holds.
            resolvedOnce = true
            directory = dir
            chats = [:]
            signatures = [:]
            ownLines = [:]
            ownTombstoned = []
            lastScan = nil
        }
        return dir
    }

    /// Conflict copies are inputs like any other file: once their records are in this device's own file they are removed.
    private func foldConflicts(_ chat: String, files: [String], in dir: URL) {
        guard let state = chats[chat] else { return }
        let records = state.isDeleted ? state.meta.map { [$0] } ?? [] : ChatStore.ordered(state)
        let urls = files.map { dir.appendingPathComponent($0) }
        rewriteOwnFile(chat, records: records, removing: urls)
        for f in files { signatures[f] = nil }
    }

    private func compactIfNeeded(_ chat: String) {
        guard let state = chats[chat], let lines = ownLines[chat] else { return }
        let live = state.records.count
        guard lines > 2 * live + 16 else { return }
        rewriteOwnFile(chat, records: state.isDeleted ? state.meta.map { [$0] } ?? [] : ChatStore.ordered(state))
    }

    private func rewriteOwnFile(_ chat: String, records: [ChatRecord], removing conflicts: [URL] = []) {
        guard let dir = currentDirectory() else { return }
        let url = dir.appendingPathComponent(ownFileName(chat))
        let data = ChatStore.encodeLines(records)
        ownLines[chat] = records.count
        if records.count == 1 && records[0].isMeta && records[0].deleted {
            ownTombstoned.insert(chat)
        } else {
            ownTombstoned.remove(chat)
        }
        io.async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                for conflict in conflicts { try FileManager.default.removeItem(at: conflict) }
            } catch {
                agentLog.error("chat file not written: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Files

    func ownFileName(_ chat: String) -> String { "\(chat).\(deviceHex).\(ChatStore.fileExtension)" }

    /// "<chat>.<device>.jsonl" → (chat, device). The device part of a provider conflict copy is not 8 hex characters
    /// ("1a2b3c4d 2", "1a2b3c4d (conflicted copy)").
    nonisolated static func parseFileName(_ name: String) -> (chat: String, device: String)? {
        let suffix = "." + fileExtension
        guard name.hasSuffix(suffix), !name.hasPrefix(".") else { return nil }
        let base = name.dropLast(suffix.count)
        guard let dot = base.firstIndex(of: ".") else { return nil }
        let chat = String(base[..<dot])
        let device = String(base[base.index(after: dot)...])
        guard NibID.isValid(chat), !device.isEmpty else { return nil }
        return (chat, device)
    }

    nonisolated static func isDeviceHex(_ s: String) -> Bool {
        s.count == 8 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Metadata first, then messages oldest first.
    nonisolated static func ordered(_ state: ChatState) -> [ChatRecord] {
        (state.meta.map { [$0] } ?? []) + state.records.values.filter { !$0.isMeta }
            .sorted { ($0.at ?? 0, $0.rev) < ($1.at ?? 0, $1.rev) }
    }

    nonisolated static func encodeLines(_ records: [ChatRecord]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for r in records {
            guard let line = try? encoder.encode(r) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        return out
    }

    /// Records of every well-formed line (a torn last line from an interrupted write is skipped) and the line count.
    nonisolated static func decodeLines(_ data: Data) -> (records: [ChatRecord], lines: Int) {
        let decoder = JSONDecoder()
        var records: [ChatRecord] = []
        var lines = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lines += 1
            if let r = try? decoder.decode(ChatRecord.self, from: Data(line)) { records.append(r) }
        }
        return (records, lines)
    }

    nonisolated static func appendData(_ data: Data, to url: URL, directory: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if last?.first != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
            }
            try handle.write(contentsOf: data)
        } catch {
            agentLog.error("chat file not appended: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    /// A one-line title of at most 60 characters.
    nonisolated static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Conversation" }
        guard trimmed.count > 60 else { return trimmed }
        let cut = trimmed.prefix(59)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    static func unknownChat(_ chat: String) -> NibError {
        NibError(.notFound, "conversation '\(chat)' not found", hint: "call ai.chat.list for conversation ids")
    }
}
