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

    var isVisibleMessage: Bool {
        !(role == "assistant" && (text ?? "").isEmpty && (group ?? "").isEmpty && (changes?.isEmpty ?? true))
    }

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

/// Serial durable writes. Failed jobs remain ordered ahead of later writes, including compaction.
/// Retrying an atomic replacement cannot append a partial record twice.
private final class ChatWrites {
    let queue = DispatchQueue(label: "app.nib.aiagent.chats", qos: .utility)
    struct MergeKey: Hashable {
        let destination: URL
        let data: Data
        let conflicts: Set<URL>
    }
    private struct Job {
        let merge: MergeKey?
        let write: () throws -> Void
    }
    private var pending: [Job] = []
    private var pendingMerges = Set<MergeKey>()
    var pendingCount: Int { pending.count } // Accessed only on queue.

    func enqueue(_ write: @escaping () throws -> Void) {
        queue.async { self.enqueueOnQueue(write) }
    }

    /// Called only on queue, including by the archive scanner.
    func enqueueOnQueue(merge: MergeKey? = nil, _ write: @escaping () throws -> Void) {
        // Refresh can rediscover the same conflict while storage is blocked. Retain one
        // snapshot per identical merge, but keep genuinely changed contents in order.
        if let merge, !pendingMerges.insert(merge).inserted {
            _ = retry()
            return
        }
        pending.append(Job(merge: merge, write: write))
        _ = retry()
    }

    func retry() -> NibError? {
        while let job = pending.first {
            do {
                try job.write()
                pending.removeFirst()
                if let merge = job.merge { pendingMerges.remove(merge) }
            } catch {
                return NibError(.unavailable, String(localized: "The conversation could not be saved."),
                                hint: String(localized: "Free some storage and try again. Unsaved messages are kept for retry while Nib is open."))
            }
        }
        return nil
    }
}

/// Conversations stored per device in the library's AI folder: `<chat>.<dev>.jsonl`, one `ChatRecord` per line.
/// Each device appends only to its own files (§4.3); readers merge every device's file of a chat (and provider
/// conflict copies, which are folded into this device's file and then removed) by record id and revision. Writes run
/// on a serial background queue. A lightweight index serves history; message bodies use a bounded cache.
/// Local records update memory at once and stay pinned while their writes have not been acknowledged.
@MainActor
final class ChatStore {
    typealias Directory = @MainActor () -> URL?

    nonisolated static let fileExtension = "jsonl"

    let deviceHex: String
    /// How often `refresh()` rescans the folder for files other devices wrote (forced reads ignore it).
    var scanInterval: TimeInterval = 2
    /// Test seam for suspending either stage of a command's history load.
    var beforeHistoryRead: (@MainActor (String?) async -> Void)?

    private let directoryProvider: Directory
    private let clock: HLCClock
    private let accessURL: URL?
    private let writes = ChatWrites()
    private var io: DispatchQueue { writes.queue }
    private var directory: URL?
    private var resolvedOnce = false
    private var chats: [String: ChatState] = [:]
    private var overviews: [String: Overview] = [:]
    private var recent: [String] = []
    private var pendingChats = Set<String>()
    private var generation: UInt64 = 0
    /// Durable message bodies are loaded on demand; unsaved bodies are pinned until flush succeeds.
    static let messageCacheLimit = 4
    var cachedChatIDs: Set<String> { Set(chats.keys) }
    var pendingWriteCount: Int { io.sync { writes.pendingCount } }

    struct Overview {
        // Metadata is small and preserves ownership/deletion if a synced file is temporarily unreadable.
        var meta: ChatRecord?
        var summary: AIChatSummary?
        var count: Int
        var deleted: Bool

        init(chat: String, state: ChatState) {
            meta = state.meta
            deleted = state.isDeleted
            count = 0
            var liveCount = 0
            var latest: Double = 0
            var firstUser: ChatRecord?
            for record in state.records.values where record.isMessage && !record.deleted {
                liveCount += 1
                if record.isVisibleMessage { count += 1 }
                latest = max(latest, record.at ?? 0)
                if record.role == "user" {
                    if let first = firstUser {
                        if (record.at ?? 0, record.rev) < (first.at ?? 0, first.rev) { firstUser = record }
                    } else { firstUser = record }
                }
            }
            let named = state.meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = named.isEmpty ? firstUser?.text.map { ChatStore.title(from: $0) } ?? "Conversation" : named
            let updated = max(latest, state.meta?.created ?? 0, Double(state.meta?.rev.wallMs ?? 0) / 1000)
            summary = deleted || (state.meta == nil && liveCount == 0) ? nil :
                AIChatSummary(id: chat, title: title, doc: state.meta?.doc.map { DocumentID($0) }, updated: updated)
        }
    }
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
    init(directory: @escaping Directory, deviceHex: String, clock: HLCClock, accessURL: URL? = nil) {
        self.directoryProvider = directory
        self.deviceHex = deviceHex
        self.clock = clock
        self.accessURL = accessURL?.startAccessingSecurityScopedResource() == true ? accessURL : nil
    }

    deinit { accessURL?.stopAccessingSecurityScopedResource() }

    // MARK: Reading

    /// Every live conversation of `doc` (nil = the library's), or of everything when `all`; newest first.
    func summaries(doc: DocumentID?, all: Bool = false) -> [AIChatSummary] {
        refresh()
        return listedSummaries(doc: doc, all: all)
    }

    private func listedSummaries(doc: DocumentID?, all: Bool) -> [AIChatSummary] {
        overviews.values.compactMap(\.summary).filter { all || $0.doc == doc }
            .sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
    }

    func messageCount(_ chat: String) -> Int { overviews[chat]?.count ?? 0 }

    /// The command path awaits disk work instead of blocking the main actor. Synchronous AIService
    /// consumers retain their contract and use the same index and bounded body cache.
    func summariesAsync(doc: DocumentID?, all: Bool = false) async -> [AIChatSummary] {
        await beforeHistoryRead?(nil)
        await refreshAsync()
        return listedSummaries(doc: doc, all: all)
    }

    func stateAsync(_ chat: String) async -> ChatState? {
        await beforeHistoryRead?(chat)
        await refreshAsync(loading: chat)
        touch(chat)
        guard let state = chats[chat], !state.isDeleted else { return nil }
        return state
    }

    /// The merged conversation (nil when unknown or deleted).
    func state(_ chat: String) -> ChatState? {
        refresh(loading: chat)
        touch(chat)
        guard let s = chats[chat], !s.isDeleted else { return nil }
        return s
    }

    func ownerDoc(_ chat: String) -> DocumentID? {
        refresh(loading: chat)
        // Tombstones retain their owner, including while a failed deletion is retried.
        return overviews[chat]?.meta?.doc.map { DocumentID($0) }
    }

    /// Bare chat ids carry no document ref for the gateway to inspect.
    func checkAccess(_ chat: String, principal: Principal, gateway: Gateway) throws {
        guard !principal.isUser, let doc = ownerDoc(chat), gateway.isLocked(doc) else { return }
        throw NibError(.locked, "the conversation belongs to a locked document", hint: "ask the user to unlock it first")
    }

    func messages(_ chat: String) -> [ChatRecord] { state(chat)?.messages ?? [] }

    /// True when the conversation was deleted (on any device).
    func isDeleted(_ chat: String) -> Bool {
        refresh(loading: chat)
        return overviews[chat]?.deleted ?? false
    }

    /// The messages the conversation shows (`AIService.messages`): answers that failed before writing anything are left out.
    func visibleMessages(_ chat: String) -> [ChatRecord] {
        messages(chat).filter(\.isVisibleMessage)
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
        refresh(loading: chat)
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
        if chats[chat] == nil { refresh(loading: chat) }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var state = chats[chat] ?? ChatState()
        for r in records { state.absorb(r, now: now) }
        chats[chat] = state
        overviews[chat] = Overview(chat: chat, state: state)
        generation &+= 1
        pendingChats.insert(chat)
        touch(chat)
        guard let dir = dir else { return }
        let url = dir.appendingPathComponent(ownFileName(chat))
        let data = ChatStore.encodeLines(records)
        ownLines[chat, default: 0] += records.count
        ownTombstoned.remove(chat)
        writes.enqueue { try ChatStore.appendData(data, to: url, directory: dir) }
        compactIfNeeded(chat)
    }

    /// Mutations enqueue writes; command callers await flushAsync before reporting success.
    func rename(_ chat: String, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NibError.invalid("the title is empty", path: "$.title") }
        refresh(force: true, loading: chat)
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
        refresh(force: true, loading: chat)
        guard let state = chats[chat] else { throw ChatStore.unknownChat(chat) }
        if state.isDeleted {
            // A previous attempt may have installed the tombstone but failed to write it.
            // Deletion is idempotent; the command awaits flushAsync before acknowledging it.
            return
        }
        var meta = state.meta ?? ChatRecord(id: ChatRecord.metaID, rev: .zero, type: ChatRecord.metaType)
        meta.deleted = true
        meta.rev = clock.tick()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var s = state
        s.absorb(meta, now: now)
        chats[chat] = s
        overviews[chat] = Overview(chat: chat, state: s)
        generation &+= 1
        pendingChats.insert(chat)
        rewriteOwnFile(chat, records: [meta])
    }

    /// Rates an assistant message ("up" / "down"; nil clears the rating). `message` is a message id, "last" (the
    /// latest answer) or the 0-based position in `visibleMessages` (what `AIService.messages(chatID:)` lists).
    @discardableResult
    func rate(_ chat: String, message: String, rating: String?) throws -> ChatRecord {
        refresh(force: true, loading: chat)
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

    /// Retries pending writes; a failure is retained for the next flush.
    @discardableResult
    func flush() -> NibError? {
        let error = io.sync { writes.retry() }
        if error == nil, directory != nil { pendingChats.removeAll(); trimCache() }
        return error
    }

    func flushAsync() async -> NibError? {
        let writes = self.writes
        let version = generation
        let error: NibError? = await withCheckedContinuation { continuation in
            writes.queue.async { continuation.resume(returning: writes.retry()) }
        }
        if error == nil, generation == version, directory != nil { pendingChats.removeAll(); trimCache() }
        return error
    }

    // MARK: Folder scan and merge

    private struct Scan {
        var overviews: [String: Overview]
        var states: [String: ChatState]
        var signatures: [String: FileSignature]
        var ownLines: [String: Int]
        var tombstoned: Set<String>
    }

    private func shouldScan(force: Bool, loading: String?) -> Bool {
        if let chat = loading, chats[chat] == nil { return true }
        guard let lastScan = lastScan else { return true }
        return force || Date().timeIntervalSince(lastScan) >= scanInterval
    }

    /// Synchronous compatibility for AIService and mutations. I/O and decoding still run on the
    /// worker, and only the requested conversation's bodies enter the cache.
    func refresh(force: Bool = false, loading: String? = nil) {
        guard let dir = currentDirectory(), shouldScan(force: force, loading: loading) else { return }
        let input = scanInput()
        let result = io.sync { Self.scan(input, directory: dir, loading: loading, device: deviceHex, clock: clock, writes: writes) }
        accept(result, keeping: loading)
    }

    private func refreshAsync(loading: String? = nil) async {
        while true {
            guard let dir = currentDirectory(), shouldScan(force: false, loading: loading) else { return }
            let version = generation
            let input = scanInput()
            let device = deviceHex
            let clock = self.clock
            let writes = self.writes
            let result: Scan = await withCheckedContinuation { continuation in
                writes.queue.async {
                    continuation.resume(returning: Self.scan(input, directory: dir, loading: loading,
                                                              device: device, clock: clock, writes: writes))
                }
            }
            // A suspended scan may overlap a local append, another scan, or a library switch.
            // Never replace newer in-memory state or expose the old root's summaries.
            guard currentDirectory() == dir, generation == version else { continue }
            accept(result, keeping: loading)
            return
        }
    }

    private func scanInput() -> Scan {
        Scan(overviews: overviews, states: chats, signatures: signatures, ownLines: ownLines, tombstoned: ownTombstoned)
    }

    private func accept(_ result: Scan, keeping chat: String?) {
        overviews = result.overviews
        chats = result.states
        signatures = result.signatures
        ownLines = result.ownLines
        ownTombstoned = result.tombstoned
        if chat == nil { lastScan = Date() }
        generation &+= 1
        if let chat = chat { touch(chat) } else { trimCache() }
    }

    private func touch(_ chat: String) {
        recent.removeAll { $0 == chat }
        recent.append(chat)
        trimCache(keeping: chat)
    }

    private func trimCache(keeping chat: String? = nil) {
        guard directory != nil else { return } // A memory-only store has no backing copy to reload.
        let durable = chats.keys.filter { !pendingChats.contains($0) && $0 != chat }
            .sorted { (recent.firstIndex(of: $0) ?? -1) < (recent.firstIndex(of: $1) ?? -1) }
        var excess = max(0, chats.count - pendingChats.count - Self.messageCacheLimit)
        for id in durable where excess > 0 {
            chats[id] = nil
            recent.removeAll { $0 == id }
            excess -= 1
        }
    }

    /// Bootstrap/changed-file scans decode one conversation at a time on the I/O queue. The
    /// index retains only title/owner/date/count; unselected message bodies die before the next chat.
    nonisolated private static func scan(_ input: Scan, directory dir: URL, loading: String?, device: String,
                                        clock: HLCClock, writes: ChatWrites) -> Scan {
        var result = input
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return result }
        var files: [String: [(name: String, device: String, signature: FileSignature)]] = [:]
        for name in names {
            guard let parsed = parseFileName(name) else { continue }
            let attributes = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            let signature = FileSignature(modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                                          size: (attributes?[.size] as? NSNumber)?.intValue ?? 0)
            files[parsed.chat, default: []].append((name, parsed.device, signature))
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for (chat, entries) in files where loading == nil || loading == chat {
            let changed = entries.contains { input.signatures[$0.name] != $0.signature || !isDeviceHex($0.device) }
            guard changed || (loading == chat && input.states[chat] == nil) else { continue }
            var state = input.states[chat] ?? ChatState()
            if let meta = input.overviews[chat]?.meta { state.absorb(meta, now: now) }
            var conflicts: [URL: Data] = [:]
            for file in entries {
                let url = dir.appendingPathComponent(file.name)
                guard let data = try? Data(contentsOf: url) else { continue }
                let (records, lines) = decodeLines(data)
                let conflict = file.device != device && !isDeviceHex(file.device)
                if conflict {
                    guard records.count == lines else { continue }
                    conflicts[url] = data
                }
                result.signatures[file.name] = file.signature
                for record in records { clock.observe(record.rev); state.absorb(record, now: now) }
                if file.device == device {
                    result.ownLines[chat] = lines
                    if records.count == 1 && records[0].isMeta && records[0].deleted {
                        result.tombstoned.insert(chat)
                    } else { result.tombstoned.remove(chat) }
                }
            }
            result.overviews[chat] = Overview(chat: chat, state: state)
            if input.states[chat] != nil || loading == chat { result.states[chat] = state }
            let shrink = state.isDeleted && result.ownLines[chat] != nil && !result.tombstoned.contains(chat)
            if !conflicts.isEmpty || shrink {
                let records = state.isDeleted ? state.meta.map { [$0] } ?? [] : ordered(state)
                let data = encodeLines(records)
                let destination = dir.appendingPathComponent("\(chat).\(device).\(fileExtension)")
                let merge = ChatWrites.MergeKey(destination: destination, data: data, conflicts: Set(conflicts.keys))
                writes.enqueueOnQueue(merge: merge) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                    for (url, snapshot) in conflicts {
                        try removeConflict(url, matching: snapshot)
                    }
                }
                result.ownLines[chat] = records.count
                if state.isDeleted { result.tombstoned.insert(chat) }
                for url in conflicts.keys { result.signatures[url.lastPathComponent] = nil }
            }
        }
        return result
    }

    private func currentDirectory() -> URL? {
        let dir = directoryProvider()
        if !resolvedOnce || dir != directory {
            // The library folder changed (or was set up): start from what the new folder holds.
            resolvedOnce = true
            directory = dir
            chats = [:]
            overviews = [:]
            recent = []
            pendingChats = []
            generation &+= 1
            signatures = [:]
            ownLines = [:]
            ownTombstoned = []
            lastScan = nil
        }
        return dir
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
        writes.enqueue {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            for conflict in conflicts where FileManager.default.fileExists(atPath: conflict.path) {
                try FileManager.default.removeItem(at: conflict)
            }
        }
    }

    // MARK: Files

    /// A retained job may outlive the conflict version it scanned. Coordinate the comparison
    /// and removal together; newer sync contents stay on disk for the next scan to merge.
    nonisolated private static func removeConflict(_ url: URL, matching snapshot: Data) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                        error: &coordinationError) { coordinatedURL in
            do {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                guard try Data(contentsOf: coordinatedURL) == snapshot else { return }
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch { removalError = error }
        }
        if let error = coordinationError { throw error }
        if let error = removalError { throw error }
    }

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

    nonisolated static func appendData(_ data: Data, to url: URL, directory: URL) throws {
        // Atomic replacement avoids partial appends on failure. compactIfNeeded bounds redundant
        // lines to 2 * live records + 16; the full-file write still scales with live history.
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var contents = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
        if !contents.isEmpty && contents.last != 0x0A { contents.append(0x0A) }
        contents.append(data)
        try contents.write(to: url, options: .atomic)
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
