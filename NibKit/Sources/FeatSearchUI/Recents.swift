import Foundation
import Combine
import UIKit
import NibContracts
import NibDesign

/// Wire model for F055's search.text result. Kept local so UI never imports the index module.
struct SearchMatch: Codable, Equatable, Identifiable {
    var ref: String
    var doc: String
    var page: String?
    var pageIndex: Int?
    var title: String
    var docKind: String
    var kind: String
    var text: String
    var snippet: String
    var rect: Rect?
    var itemIDs: [String]
    var alternative: String?
    var time: Double?
    var score: Double
    var id: String {
        // Exact duplicate hits share an id; every field, including geometry, participates.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self).base64EncodedString()) ?? ref
    }
    var group: SearchGroup {
        if kind == "title" { return .titles }
        if kind == "outline" { return .outlines }
        if kind == "transcript" { return .transcripts }
        if docKind == DocumentKind.studySet.rawValue { return .studySets }
        if docKind == DocumentKind.whiteboard.rawValue { return .whiteboards }
        switch kind {
        case "pdf", "scan", "image": return .pdfs
        case "ink": return .written
        default: return .typed
        }
    }
}

struct SearchResponse: Codable {
    var results: [SearchMatch]
    var total: Int
    var truncated: Bool
    var cursor: String?
}

enum SearchGroup: String, CaseIterable, Identifiable {
    case titles, pdfs, written, typed, outlines, studySets, whiteboards, transcripts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .titles: return String(localized: "Titles")
        case .pdfs: return String(localized: "PDFs")
        case .written: return String(localized: "Written Notes")
        case .typed: return String(localized: "Typed Notes")
        case .outlines: return String(localized: "Outlines")
        case .studySets: return String(localized: "Study Sets")
        case .whiteboards: return String(localized: "Whiteboards")
        case .transcripts: return String(localized: "Transcripts")
        }
    }
    var symbol: NibSymbol {
        switch self {
        case .titles: return .notebook
        case .pdfs: return .pdf
        case .written: return .pen
        case .typed: return .text
        case .outlines: return .outline
        case .studySets: return .studySets
        case .whiteboards: return .whiteboard
        case .transcripts: return .record
        }
    }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, handwriting, typed, pdf, audio, cards
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .handwriting: return String(localized: "Handwriting")
        case .typed: return String(localized: "Typed")
        case .pdf: return String(localized: "PDF")
        case .audio: return String(localized: "Audio")
        case .cards: return String(localized: "Cards")
        }
    }
    func includes(_ hit: SearchMatch) -> Bool {
        switch self {
        case .all: return true
        case .handwriting: return hit.kind == "ink"
        case .typed: return hit.kind == "typed"
        case .pdf: return hit.kind == "pdf" || hit.kind == "scan" || hit.kind == "image"
        case .audio: return hit.kind == "transcript"
        case .cards: return hit.docKind == DocumentKind.studySet.rawValue
        }
    }
}

struct RecentDocument: Identifiable, Equatable {
    var doc: DocumentID
    var at: Double
    var id: String { doc.raw }
}

struct Recents {
    static let capacity = 20
    private(set) var documents: [RecentDocument] = []
    mutating func record(_ doc: DocumentID, at: Double) {
        if let previous = documents.first(where: { $0.doc == doc }), previous.at > at { return }
        documents.removeAll { $0.doc == doc }
        documents.append(RecentDocument(doc: doc, at: at))
        documents.sort { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
        documents = Array(documents.prefix(Self.capacity))
    }
}

struct RecentRow: Identifiable {
    var ref: String
    var title: String
    var kind: String
    var id: String { ref }
}

struct SearchSnippet {
    var image: UIImage
    var scale: Double
}

/// A query with no visible matches always explains whether work is pending or complete.
enum SearchEmptyPresentation: Equatable {
    case searching, indexing, noResults(String)

    var title: String {
        switch self {
        case .searching: return String(localized: "Searching your notes…")
        case .indexing: return String(localized: "Handwriting is still being indexed.")
        case .noResults(let query): return String(localized: "No results for “\(query)”")
        }
    }
    var message: String {
        switch self {
        case .searching: return String(localized: "Results will appear here as the search finishes.")
        case .indexing: return String(localized: "Try typed text or check again when recognition finishes.")
        case .noResults: return String(localized: "Try fewer words or choose All to search every source.")
        }
    }
}

@MainActor
final class SearchState: ObservableObject {
    @Published var scope = "lib"
    @Published var query = ""
    @Published var filter = SearchFilter.all
    @Published var matches: [SearchMatch] = []
    @Published var selectedID: String?
    @Published var recentRows: [RecentRow] = []
    @Published var loading = false
    @Published var error: String?
    @Published var progress: IndexProgressPayload?
    @Published var isPresented = false
    @Published var instant = false
    @Published var focusGeneration = 0
    var generation = 0
    var cursor: String?
    var seenCursors = Set<String>()
    var pendingReveal: SearchMatch?
    var snippetImages: [String: SearchSnippet] = [:]
    var document: DocumentID? { NodeRef(scope)?.documentID }
    var flashID: String?
    var flashUntil: Date?
    var visibleMatches: [SearchMatch] { matches.filter { filter.includes($0) } }
    var selectedIndex: Int? { visibleMatches.firstIndex { $0.id == selectedID } }
    var isLibraryScope: Bool { scope == "lib" || scope.hasPrefix("folder:") }
    var remainingPages: Int { max(0, progress?.pending ?? 0) }
    var isIndexing: Bool { progress?.running == true || remainingPages > 0 }
    var emptyPresentation: SearchEmptyPresentation? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, error == nil, visibleMatches.isEmpty else { return nil }
        if loading { return .searching }
        if isIndexing { return .indexing }
        return .noResults(trimmed)
    }
    var indexingMessage: String? {
        guard isIndexing else { return nil }
        if remainingPages > 0 {
            return String(localized: "Handwriting in ^[\(remainingPages) page](inflect: true) is still being indexed.")
        }
        return String(localized: "Handwriting is still being indexed.")
    }
    /// Document navigation always has an active hit as soon as results arrive. Library search
    /// keeps its unselected count until a row is opened. Preserve selection across refreshes.
    func reconcileSelection() {
        guard selectedIndex == nil else { return }
        selectedID = isLibraryScope ? nil : visibleMatches.first?.id
    }
    var countLabel: String {
        if let selectedIndex { return String(localized: "\(selectedIndex + 1) of \(visibleMatches.count)") }
        return String(AttributedString(localized: "^[\(visibleMatches.count) match](inflect: true)").characters)
    }
}

/// App lifetime owner, with per-window state. No static/global current search.
@MainActor
final class SearchRuntime {
    static let key = "searchui.runtime"
    static let recentPrefix = "searchui.recent."
    weak var app: NibApp?
    var recents = Recents()
    private var states: [NibID: SearchState] = [:]
    private var panelSubscriptions: [NibID: AnyCancellable] = [:]
    private var watchTask: Task<Void, Never>?
    private var documentSubscriptions: [NibID: AnyCancellable] = [:]
    private var refreshTasks: [NibID: Task<Void, Never>] = [:]
    private var typingTasks: [NibID: Task<Void, Never>] = [:]
    private var progress: IndexProgressPayload?

    init(app: NibApp) { self.app = app }
    deinit {
        watchTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
        for task in typingTasks.values { task.cancel() }
    }
    static func from(_ app: NibApp) -> SearchRuntime {
        if let runtime = app.services.get(key, as: SearchRuntime.self) { return runtime }
        let runtime = SearchRuntime(app: app)
        app.services.set(runtime, for: key)
        runtime.start()
        return runtime
    }
    func state(_ session: EditorSession) -> SearchState {
        if let state = states[session.id] { return state }
        let state = SearchState()
        state.progress = progress
        states[session.id] = state
        var wasOpen = session.openPanels.contains(SearchOpen.documentPanel) || session.openPanels.contains(SearchOpen.libraryPanel)
        panelSubscriptions[session.id] = session.$openPanels.sink { [weak self, weak state, weak session] panels in
            let open = panels.contains(SearchOpen.documentPanel) || panels.contains(SearchOpen.libraryPanel)
            if wasOpen && !open, let state {
                state.isPresented = false
                state.generation += 1
                state.loading = false
                state.flashID = nil
                if let session { self?.cancelPending(session) }
                self?.app?.ui.setNeedsChromeUpdate(session)
            }
            wasOpen = open
        }
        documentSubscriptions[session.id] = session.$document.sink { [weak self, weak state, weak session] doc in
            guard let self, let state, let session, state.isPresented,
                  !state.isLibraryScope, state.document != doc else { return }
            self.cancelPending(session)
            state.generation += 1
            state.matches = []
            state.selectedID = nil
            state.cursor = nil
            state.flashID = nil
            state.loading = false
            if let doc {
                state.scope = NodeRef.document(doc).description
                // Published delivers in willSet; execute after the session has finished switching.
                self.scheduleRefresh(session, state: state, delay: 0)
            } else {
                state.isPresented = false
            }
            self.app?.ui.setNeedsChromeUpdate(session)
        }
        return state
    }
    func cancelPending(_ session: EditorSession) {
        refreshTasks.removeValue(forKey: session.id)?.cancel()
        typingTasks.removeValue(forKey: session.id)?.cancel()
    }
    func type(_ query: String, session: EditorSession, state: SearchState) {
        cancelPending(session)
        state.query = query
        state.generation += 1
        state.matches = []
        state.selectedID = nil
        state.cursor = nil
        state.loading = true
        typingTasks[session.id] = Task { @MainActor [weak self, weak session, weak state] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, let session, let state, state.isPresented, let app = self.app else { return }
            do {
                _ = try await app.bus.execute(CommandIDs.searchOpen,
                    ["scope": .string(state.scope), "refresh": true], session: session)
            } catch { /* load exposes the failure in the search banner. */ }
        }
    }
    private func scheduleRefresh(_ session: EditorSession, state: SearchState, delay: UInt64 = 1_000_000_000) {
        refreshTasks.removeValue(forKey: session.id)?.cancel()
        state.generation += 1
        refreshTasks[session.id] = Task { @MainActor [weak self, weak session, weak state] in
            do {
                try await Task.sleep(nanoseconds: delay)
                while session?.inking.isInking == true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard !Task.isCancelled, let self, let session, let state,
                      state.isPresented, let app = self.app else { return }
                _ = try await app.bus.execute(CommandIDs.searchOpen,
                    ["scope": .string(state.scope), "refresh": true], session: session)
            } catch { /* Cancellation is normal; load exposes other failures. */ }
        }
    }
    private func contains(_ doc: DocumentID, scope: String) -> Bool {
        if scope == "lib" { return true }
        if let scopedDoc = NodeRef(scope)?.documentID { return scopedDoc == doc }
        guard case .folder(let folder) = NodeRef(scope) else { return false }
        var parent = app?.services.library?.node(doc)?.parent
        var seen = Set<FolderID>()
        while let current = parent, seen.insert(current).inserted {
            if current == folder { return true }
            parent = app?.services.library?.node(current)?.parent
        }
        return false
    }
    func start() {
        guard watchTask == nil, let app else { return }
        for name in app.settings.names(prefix: Self.recentPrefix) {
            if let at = app.settings.json(name)?.doubleValue {
                recents.record(DocumentID(String(name.dropFirst(Self.recentPrefix.count))), at: at)
            }
        }
        let stream = app.events.stream()
        let replay = app.events.events(since: 0, limit: app.events.capacity)
        let replayEnd = replay.last?.seq ?? 0
        watchTask = Task { @MainActor [weak self] in
            for event in replay { await self?.receive(event) }
            for await event in stream {
                guard !Task.isCancelled else { return }
                if event.seq > replayEnd { await self?.receive(event) }
            }
        }
    }
    func receive(_ event: NibEvent) async {
        guard let app else { return }
        let opened = event.type == NibEventType.sessionDocument ||
            (event.type == NibEventType.docOpened && app.services.sessions.sessions.contains { $0.document == event.doc })
        if opened, let doc = event.doc {
            recents.record(doc, at: event.at)
            // Persist through the existing registered settings command, one key per document.
            do {
                if let at = recents.documents.first(where: { $0.doc == doc })?.at {
                    _ = try await app.bus.execute(CommandIDs.settingsSet,
                        ["name": .string(Self.recentPrefix + doc.raw), "value": .number(at)])
                }
                let kept = Set(recents.documents.map { Self.recentPrefix + $0.id })
                for name in app.settings.names(prefix: Self.recentPrefix) where !kept.contains(name) {
                    _ = try await app.bus.execute(CommandIDs.settingsSet, ["name": .string(name), "value": .null])
                }
            } catch {
                // Recents remain available for this process if device preferences cannot be saved.
                app.services.sessions.active?.floatingHost?.postToast(NibError.wrap(error).message)
            }
        }
        if let payload = event.decode(IndexProgressPayload.self) {
            progress = payload
            for state in states.values { state.progress = payload }
        }
        if event.type == NibEventType.libraryChanged || opened || event.decode(IndexProgressPayload.self)?.running == false {
            for session in app.services.sessions.sessions {
                guard let state = states[session.id], state.isPresented else { continue }
                if opened {
                    guard state.scope == "lib", state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                } else if let doc = event.doc, !contains(doc, scope: state.scope) { continue }
                scheduleRefresh(session, state: state)
            }
        }
        let live = Set(app.services.sessions.sessions.map(\.id))
        states = states.filter { live.contains($0.key) }
        panelSubscriptions = panelSubscriptions.filter { live.contains($0.key) }
        documentSubscriptions = documentSubscriptions.filter { live.contains($0.key) }
        for id in refreshTasks.keys where !live.contains(id) { refreshTasks.removeValue(forKey: id)?.cancel() }
        for id in typingTasks.keys where !live.contains(id) { typingTasks.removeValue(forKey: id)?.cancel() }
    }

    func load(_ state: SearchState, context ctx: CommandContext) async throws {
        state.generation += 1
        let generation = state.generation
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        state.loading = true
        state.error = nil
        defer { if state.generation == generation { state.loading = false } }
        do {
            if query.isEmpty {
                var rows: [RecentRow] = []
                if state.scope == "lib" {
                    for recent in recents.documents {
                        guard let node = app?.services.library?.node(recent.doc), node.kind == .document,
                              node.trashedAt == nil, app?.services.lock?.isLocked(recent.doc) != true else { continue }
                        rows.append(RecentRow(ref: NodeRef.document(recent.doc).description,
                            title: node.title, kind: node.documentKind?.rawValue ?? DocumentKind.notebook.rawValue))
                    }
                }
                guard generation == state.generation else { return }
                state.matches = []
                state.selectedID = nil
                state.cursor = nil
                state.seenCursors = []
                state.snippetImages = [:]
                state.recentRows = rows
            } else {
                state.cursor = nil
                state.seenCursors = []
                let response = try await ctx.execute(CommandIDs.searchText,
                    ["query": .string(query), "scope": .string(state.scope), "limit": 100]).decode(SearchResponse.self)
                guard generation == state.generation, !Task.isCancelled else { return }
                state.matches = exactUnique(response.results)
                state.cursor = response.truncated ? response.cursor : nil
                state.recentRows = []
                state.snippetImages = state.snippetImages.filter { key, _ in state.matches.contains { $0.id == key } }
                state.reconcileSelection()
            }
        } catch {
            guard generation == state.generation else { return }
            guard !Task.isCancelled else { return }
            state.error = NibError.wrap(error).message
            state.matches = []
            state.selectedID = nil
            throw error
        }
    }
    func loadMore(_ state: SearchState, context ctx: CommandContext) async throws {
        guard state.isPresented, !state.loading, let cursor = state.cursor else { return }
        let generation = state.generation
        state.loading = true
        defer { if state.generation == generation { state.loading = false } }
        do {
            guard state.seenCursors.insert(cursor).inserted else {
                throw NibError(.invariantViolation, "Search returned a repeated result cursor.")
            }
            let response = try await ctx.execute(CommandIDs.searchText,
                ["query": .string(state.query.trimmingCharacters(in: .whitespacesAndNewlines)),
                 "scope": .string(state.scope), "limit": 100, "cursor": .string(cursor)]).decode(SearchResponse.self)
            guard generation == state.generation, !Task.isCancelled else { return }
            state.matches = exactUnique(state.matches + response.results)
            state.reconcileSelection()
            state.cursor = response.truncated ? response.cursor : nil
        } catch {
            guard generation == state.generation, !Task.isCancelled else { return }
            state.error = NibError.wrap(error).message
            throw error
        }
    }
    private func exactUnique(_ hits: [SearchMatch]) -> [SearchMatch] {
        var result: [SearchMatch] = []
        for hit in hits where !result.contains(hit) { result.append(hit) }
        return result
    }

}
