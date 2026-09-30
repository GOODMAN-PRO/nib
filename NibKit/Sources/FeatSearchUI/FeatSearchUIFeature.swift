import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

public enum FeatSearchUIFeature: NibFeature {
    public static let id = "searchui"
    public static func register(_ app: NibApp) {
        app.commands.register(SearchOpen.self)
        app.commands.register(SearchStep.self)
        app.settings.declarePrefix(SearchRuntime.recentPrefix, synced: false,
            summary: "Last document-open time for the twenty most recently opened documents.", owner: id,
            schema: .num(min: 0))
        app.ui.panels.register(PanelDescriptor(id: SearchOpen.documentPanel, title: String(localized: "Search"),
            icon: NibSymbol.search.name, placement: .sidebarTab, order: 40, owner: id) { context in
                if let session = context.session {
                    return AnyView(DocumentSearchPanel(app: context.app, session: session,
                        state: SearchRuntime.from(context.app).state(session)))
                }
                return AnyView(NibEmptyState(symbol: .search, title: String(localized: "Open a document to search it")))
            })
        var library = PanelDescriptor(id: SearchOpen.libraryPanel, title: String(localized: "Search"),
            icon: NibSymbol.search.name, placement: .fullScreen, order: 40, owner: id) { context in
                if let session = context.session ?? context.navigator?.session {
                    return AnyView(LibrarySearchView(app: context.app, session: session,
                        state: SearchRuntime.from(context.app).state(session)))
                }
                return AnyView(NibEmptyState(symbol: .search, title: String(localized: "Search is unavailable in this window")))
            }
        library.providesHeader = true
        app.ui.panels.register(library)
        var toolbar = ToolbarItemDescriptor(id: "searchui.find", title: String(localized: "Find in document"),
            icon: NibSymbol.search.name, group: .navTrailing, order: 20, owner: id,
            command: CommandIDs.searchOpen, params: ["scope": "document"],
            shortcut: KeyShortcut("f", [.command]), docKinds: Set(DocumentKind.allCases))
        toolbar.isOn = { $0.openPanels.contains(SearchOpen.documentPanel) }
        app.ui.toolbar.register(toolbar)
        app.ui.menus.register(MenuItemDescriptor(id: "searchui.libraryFind", title: String(localized: "Search library"),
            icon: NibSymbol.search.name, location: .appMenu, order: 40, owner: id,
            command: CommandIDs.searchOpen, params: { _ in ["scope": "lib"] }))
        for (suffix, scope, keyScope) in [("library", "lib", KeyScope.library), ("document", "document", .document)] {
            app.content.keyCommands.register(KeyCommandDescriptor(id: "searchui.find." + suffix,
                title: String(localized: "Find"), shortcut: KeyShortcut("f", [.command]),
                command: CommandIDs.searchOpen, params: ["scope": .string(scope), "instant": true], scope: keyScope, owner: id))
        }
        for (suffix, direction, modifiers) in [("next", "next", KeyModifiers.command),
                                              ("previous", "previous", [.command, .shift])] {
            app.content.keyCommands.register(KeyCommandDescriptor(id: "searchui." + suffix,
                title: suffix == "next" ? String(localized: "Find next") : String(localized: "Find previous"),
                shortcut: KeyShortcut("g", modifiers), command: CommandIDs.searchStep,
                params: ["direction": .string(direction)], scope: .document, owner: id))
        }
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "searchui.highlights", owner: id) { host in
            SearchHighlights(state: SearchRuntime.from(host.app).state(host.session))
        })
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(id: "searchui.field", owner: id, placement: .top,
            surface: .none, isVisible: { context in
                let state = SearchRuntime.from(context.app).state(context.session)
                return !context.isCompact && !state.isLibraryScope && state.isPresented
            }, makeView: { context in
                AnyView(DocumentSearchField(app: context.app, session: context.session,
                    state: SearchRuntime.from(context.app).state(context.session)))
            }))
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(id: "searchui.counter", owner: id, placement: .bottom, surface: .none,
            isVisible: { context in
                let state = SearchRuntime.from(context.app).state(context.session)
                return !state.isLibraryScope && state.isPresented && !state.visibleMatches.isEmpty
            }, makeView: { context in
                AnyView(SearchCounter(app: context.app, session: context.session,
                    state: SearchRuntime.from(context.app).state(context.session)))
            }))
    }
    public static func start(_ app: NibApp) async { SearchRuntime.from(app).start() }
}

struct SearchOpen: NibCommand {
    static let libraryPanel = "searchui.library"
    static let documentPanel = "searchui.document"
    static let libraryOverlay = "searchui.libraryOverlay"
    struct Params: Codable {
        var scope: String
        var query: String?
        var filter: SearchFilterValue?
        var match: Int?
        var close: Bool?
        var instant: Bool?
        var refresh: Bool?
    }
    // Raw-string decoding yields invalid_params for unsupported filters.
    enum SearchFilterValue: String, Codable { case all, handwriting, typed, pdf, audio, cards }
    struct Output: Codable { var scope: String; var query: String; var count: Int; var selected: String? }
    static let descriptor = CommandDescriptor(id: "search.open", title: "Open Search",
        summary: "Open lib or document search; query updates results, filter narrows sources, match selects a zero-based result, close dismisses it.",
        params: .obj(["scope": .str("lib, document (invoking window), doc:D, folder:F or page:D/P"),
            "query": .str("words to find; empty shows recently opened documents"),
            "filter": .str(choices: SearchFilter.allCases.map(\.rawValue)),
            "match": .int("zero-based index in filtered results", min: 0), "close": .bool(),
            "instant": .bool("keyboard invocation, no animation"), "refresh": .bool("refresh without reopening")], required: ["scope"]),
        examples: [["scope": "lib"], ["scope": "doc:FIXTUREDOC01", "query": "Hello"]],
        effect: .session, target: .app, undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let app = ctx.app, let session = ctx.activeSession else { throw NibError(.unavailable, "Search needs an active window.") }
        let scope = try resolvedScope(p.scope, session: session)
        let runtime = SearchRuntime.from(app)
        let state = runtime.state(session)
        if p.close == true {
            state.isPresented = false
            state.generation += 1
            state.loading = false
            state.flashID = nil
            session.floatingHost?.dismiss(libraryOverlay)
            if session.openPanels.contains(libraryPanel) || session.openPanels.contains(documentPanel) {
                _ = try await ctx.execute(CommandIDs.panelClose, ["id": .string(state.isLibraryScope ? libraryPanel : documentPanel)])
            }
            app.ui.setNeedsChromeUpdate(session)
            return output(state)
        }
        if scope != state.scope {
            state.scope = scope
            state.query = ""
            state.filter = .all
            state.matches = []
            state.selectedID = nil
        }
        let changed = p.query.map { $0 != state.query } ?? false
        if let query = p.query { state.query = query }
        if let filter = p.filter, let value = SearchFilter(rawValue: filter.rawValue) {
            state.filter = value
            if !state.visibleMatches.contains(where: { $0.id == state.selectedID }) { state.selectedID = nil }
        }
        if p.query == nil && p.filter == nil && p.match == nil { state.instant = p.instant ?? false }
        state.isPresented = true
        if p.match == nil && p.refresh != true && !changed && p.filter == nil { state.focusGeneration += 1 }
        if p.match == nil && p.refresh != true {
            if state.isLibraryScope, let host = session.floatingHost {
                if !host.isPresenting(libraryOverlay) {
                    host.present(libraryOverlay) { LibrarySearchOverlay(app: app, session: session, state: state) }
                }
            } else {
                let panel = state.isLibraryScope ? libraryPanel : documentPanel
                if !session.openPanels.contains(panel) {
                    _ = try await ctx.execute(CommandIDs.panelOpen, ["id": .string(panel), "instant": .bool(state.instant)])
                }
            }
        }
        if p.match == nil && (changed || p.filter == nil || state.matches.isEmpty) {
            try await runtime.load(state, context: ctx)
        }
        if let index = p.match {
            guard state.visibleMatches.indices.contains(index) else {
                throw NibError(.invalidParams, "The search result no longer exists.", path: "$.match", hint: "Call search.open with the query again.")
            }
            try await navigate(state.visibleMatches[index], state: state, context: ctx)
        }
        app.ui.setNeedsChromeUpdate(session)
        return output(state)
    }
    static func output(_ state: SearchState) -> Output {
        Output(scope: state.scope, query: state.query, count: state.visibleMatches.count, selected: state.selectedID)
    }
    static func resolvedScope(_ input: String, session: EditorSession) throws -> String {
        if input == "document" || input == "doc" {
            guard let doc = session.document else { throw NibError(.unavailable, "Open a document to search it.") }
            return NodeRef.document(doc).description
        }
        guard let ref = NodeRef(input) else { throw NibError.invalid("scope must be lib, document, doc:D, folder:F or page:D/P") }
        switch ref {
        case .library, .document, .folder, .page: return ref.description
        default: throw NibError.invalid("Search scope must name a library, folder, document or page.")
        }
    }
    static func navigate(_ hit: SearchMatch, state: SearchState, context ctx: CommandContext) async throws {
        guard let session = ctx.activeSession, let doc = NodeRef(hit.doc)?.documentID else {
            throw NibError(.invariantViolation, "Search returned an invalid document reference.")
        }
        var params: JSONValue = ["doc": .string(hit.doc), "mode": "replace"]
        if let page = hit.page { params = params.merging(["page": .string(page)]) }
        if session.document != doc || session.editor == nil {
            _ = try await ctx.execute(CommandIDs.docOpen, params)
        }
        guard session.document == doc else { throw NibError(.unavailable, "The document could not be opened.") }
        state.selectedID = hit.id
        if let page = hit.page.flatMap({ NodeRef($0)?.pageID }) {
            session.page = page
            session.editor?.reveal(page: page, rect: hit.rect, animated: false)
        } else if case .block(_, let block) = NodeRef(hit.ref) {
            session.editor?.reveal(block: block, animated: false)
        } else if case .card = NodeRef(hit.ref) {
            // The shared reveal command can address non-page editor nodes by reference.
            _ = try await ctx.execute(CommandIDs.viewReveal, ["ref": .string(hit.ref)])
        }
        state.flashID = hit.id
        state.flashUntil = Date().addingTimeInterval(NibMotion.hudLinger)
        if state.isLibraryScope {
            state.isPresented = false
            session.floatingHost?.dismiss(libraryOverlay)
            if session.openPanels.contains(libraryPanel) {
                _ = try await ctx.execute(CommandIDs.panelClose, ["id": .string(libraryPanel)])
            }
        }
        ctx.app?.ui.setNeedsChromeUpdate(session)
        // Notify attachments after a new editor has been installed by doc.open.
        NotificationCenter.default.post(name: .searchHighlightsChanged, object: state)
    }
}

struct SearchStep: NibCommand {
    struct Params: Codable { var direction: String }
    static let descriptor = CommandDescriptor(id: "search.step", title: "Step Search Match",
        summary: "Select and reveal the next or previous search result in the invoking window, wrapping at either end.",
        params: .obj(["direction": .str(choices: ["next", "previous"])], required: ["direction"]),
        examples: [["direction": "next"], ["direction": "previous"]], effect: .session, target: .app, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SearchOpen.Output {
        guard let app = ctx.app, let session = ctx.activeSession else { throw NibError(.unavailable, "Search needs an active window.") }
        let state = SearchRuntime.from(app).state(session)
        guard state.isPresented, !state.isLibraryScope, let index = state.stepIndex(forward: p.direction == "next") else {
            return SearchOpen.output(state)
        }
        try await SearchOpen.navigate(state.visibleMatches[index], state: state, context: ctx)
        return SearchOpen.output(state)
    }
}

extension Notification.Name { static let searchHighlightsChanged = Notification.Name("NibSearchHighlightsChanged") }
