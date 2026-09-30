import Foundation
import Combine
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
    var id: String { [ref, kind, snippet, String(time ?? -1)].joined(separator: "|") }
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
    var flashID: String?
    var flashUntil: Date?
    var visibleMatches: [SearchMatch] { matches.filter { filter.includes($0) } }
    var selectedIndex: Int? { visibleMatches.firstIndex { $0.id == selectedID } }
    var isLibraryScope: Bool { scope == "lib" || scope.hasPrefix("folder:") }
    var remainingPages: Int { max(0, progress?.pending ?? 0) }
    var isIndexing: Bool { progress?.running == true || remainingPages > 0 }
    var countLabel: String {
        if let selectedIndex { return String(localized: "\(selectedIndex + 1) of \(visibleMatches.count)") }
        return String(localized: "\(visibleMatches.count) matches")
    }
    func stepIndex(forward: Bool) -> Int? {
        let count = visibleMatches.count
        guard count > 0 else { return nil }
        guard let current = selectedIndex else { return forward ? 0 : count - 1 }
        return (current + (forward ? 1 : count - 1)) % count
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
    private var lastEvent: UInt64 = 0
    private var progress: IndexProgressPayload?

    init(app: NibApp) { self.app = app }
    deinit { watchTask?.cancel() }
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
        var wasOpen = session.openPanels.contains(SearchOpen.documentPanel)
        panelSubscriptions[session.id] = session.$openPanels.sink { [weak self, weak state, weak session] panels in
            let open = panels.contains(SearchOpen.documentPanel)
            if wasOpen && !open, let state, !state.isLibraryScope {
                state.isPresented = false
                state.generation += 1
                state.loading = false
                state.flashID = nil
                self?.app?.ui.setNeedsChromeUpdate(session)
            }
            wasOpen = open
        }
        return state
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
        watchTask = Task { @MainActor [weak self] in
            for event in replay { await self?.receive(event) }
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
    }
    func receive(_ event: NibEvent) async {
        guard event.seq > lastEvent, let app else { return }
        lastEvent = event.seq
        if event.type == NibEventType.docOpened, let doc = event.doc {
            recents.record(doc, at: event.at)
            // Persist through the existing registered settings command, one key per document.
            do {
                _ = try await app.bus.execute(CommandIDs.settingsSet,
                    ["name": .string(Self.recentPrefix + doc.raw), "value": .number(event.at)])
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
        if event.type == NibEventType.committed || event.type == NibEventType.libraryChanged ||
            event.type == NibEventType.docOpened || event.decode(IndexProgressPayload.self)?.running == false {
            for session in app.services.sessions.sessions {
                guard let state = states[session.id], state.isPresented else { continue }
                app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "refresh": true], session: session)
            }
        }
        let live = Set(app.services.sessions.sessions.map(\.id))
        states = states.filter { live.contains($0.key) }
        panelSubscriptions = panelSubscriptions.filter { live.contains($0.key) }
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
                        guard state.generation == generation else { return }
                        let ref = NodeRef.document(recent.doc).description
                        do {
                            let node = try await ctx.execute(CommandIDs.queryGet, ["ref": .string(ref)])
                            guard node["deleted"]?.boolValue != true, node["trashedAt"]?.doubleValue == nil,
                                  node["locked"]?.boolValue != true else { continue }
                            rows.append(RecentRow(ref: ref,
                                title: node["title"]?.stringValue ?? node["meta"]?["title"]?.stringValue ?? String(localized: "Untitled notebook"),
                                kind: node["kind"]?.stringValue ?? node["meta"]?["kind"]?.stringValue ?? "notebook"))
                        } catch let error as NibError where error.code == .notFound || error.code == .locked || error.code == .permissionDenied {
                            continue
                        }
                    }
                }
                guard generation == state.generation else { return }
                state.matches = []
                state.selectedID = nil
                state.recentRows = rows
            } else {
                var hits: [SearchMatch] = []
                var cursor: String?
                var seenCursors = Set<String>()
                repeat {
                    var params: JSONValue = ["query": .string(query), "scope": .string(state.scope), "limit": 500]
                    if let cursor { params = params.merging(["cursor": .string(cursor)]) }
                    let response = try await ctx.execute(CommandIDs.searchText, params).decode(SearchResponse.self)
                    guard generation == state.generation else { return }
                    hits.append(contentsOf: response.results)
                    cursor = response.truncated ? response.cursor : nil
                    if let cursor, !seenCursors.insert(cursor).inserted {
                        throw NibError(.invariantViolation, "Search returned a repeated result cursor.")
                    }
                } while cursor != nil
                var ids = Set<String>()
                state.matches = hits.filter { ids.insert($0.id).inserted }
                if !state.visibleMatches.contains(where: { $0.id == state.selectedID }) { state.selectedID = nil }
            }
        } catch {
            guard generation == state.generation else { return }
            state.error = NibError.wrap(error).message
            state.matches = []
            state.selectedID = nil
            throw error
        }
    }
}
