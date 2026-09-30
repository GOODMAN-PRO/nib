import Foundation
import NibContracts

// MARK: - app.openURL

/// `app.openURL {url}`: follows a nib:// link (ARCHITECTURE.md §12). The shell sends every nib:// URL here (the scheme
/// is registered in Info.plist), and text links (F029), comment links (F037), QR codes (F065), key commands (F047) and
/// App Intents use it too, so every caller gets the same checks.
struct AppOpenURL: NibCommand {
    struct Params: Codable {
        var url: String
    }
    typealias Output = RouteResult

    static let descriptor = CommandDescriptor(
        id: "app.openURL", title: "Open Nib Link",
        summary: "Follow a nib:// link: open/<doc>[/<page>][?comment=<id>], audio/<doc>/<clip>?t=, quicknote, new?kind=, search?q=, plugin/install?url=, bridge/pair, import.",
        params: .obj(["url": .str("a nib:// link, e.g. nib://open/<doc>/<page> or nib://search?q=velocity")],
                     required: ["url"]),
        examples: [["url": "nib://open/FIXTUREDOC01/FIXTUREPG002"],
                   ["url": "nib://audio/FIXTUREDOC01/FIXTUREAUD01?t=12"],
                   ["url": "nib://search?q=velocity"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> RouteResult {
        let link = try DeepLinkParser.parse(p.url)
        await LaunchGate.waitUntilReady(ctx)
        return try await DeepLinkRouter.perform(link, ctx: ctx)
    }
}

// MARK: - app.quickAction

/// `app.quickAction {type}`: a Home Screen quick action (the shell sends the item's type, on a cold launch too).
struct AppQuickAction: NibCommand {
    struct Params: Codable {
        var type: String
    }
    typealias Output = RouteResult

    static let descriptor = CommandDescriptor(
        id: "app.quickAction", title: "Home Screen Quick Action",
        summary: "Run a Home Screen quick action: app.nib.quicknote makes a QuickNote; app.nib.open.<doc id> opens that favourite.",
        params: .obj(["type": .str("app.nib.quicknote or app.nib.open.<document id>")], required: ["type"]),
        examples: [["type": "app.nib.quicknote"], ["type": "app.nib.open.FIXTUREDOC01"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> RouteResult {
        let link = try QuickActionTypes.link(for: p.type)
        await LaunchGate.waitUntilReady(ctx)
        return try await DeepLinkRouter.perform(link, ctx: ctx)
    }
}

/// A link or quick action that launches Nib arrives while the scene connects: before the features have started and
/// before a window is active. Give them a moment (at most `timeout`) so the document opens in that window instead of
/// failing with "no window".
@MainActor
enum LaunchGate {
    static let timeout: UInt64 = 5_000_000_000
    static let step: UInt64 = 50_000_000

    static func waitUntilReady(_ ctx: CommandContext) async {
        guard !NibApp.isHostlessTest, !ctx.dryRun, let app = ctx.app else { return }
        var waited: UInt64 = 0
        while waited < timeout, !app.isStarted || (ctx.principal.isUser && app.ui.activeNavigator == nil) {
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
    }
}

// MARK: - App Intents support

/// Library lists for the App Intents entity queries (Shortcuts pickers, Siri disambiguation): case- and
/// diacritic-insensitive matching, best matches first.
enum LibrarySearch {
    static func normalised(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 0 exact title, 1 title prefix, 2 a word's prefix, 3 anywhere in the title; nil = no match.
    static func score(_ title: String, _ query: String) -> Int? {
        let t = normalised(title)
        if t == query { return 0 }
        if t.hasPrefix(query) { return 1 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(query) }) { return 2 }
        if t.contains(query) { return 3 }
        return nil
    }

    /// Nodes of `kind` matching `query`. With no query: favourites first, then most recently modified.
    static func rank(_ nodes: [LibraryNode], query: String?, kind: LibraryNodeKind, limit: Int) -> [LibraryNode] {
        let pool = nodes.filter { $0.kind == kind && $0.trashedAt == nil }
        let q = normalised(query ?? "")
        let ranked: [LibraryNode]
        if q.isEmpty {
            ranked = pool.sorted { a, b in
                if a.favorite != b.favorite { return a.favorite }
                if a.modified != b.modified { return a.modified > b.modified }
                return tieBreak(a, b)
            }
        } else {
            ranked = pool.compactMap { n in score(n.title, q).map { (n, $0) } }
                .sorted { a, b in
                    if a.1 != b.1 { return a.1 < b.1 }
                    if a.0.modified != b.0.modified { return a.0.modified > b.0.modified }
                    return tieBreak(a.0, b.0)
                }
                .map { $0.0 }
        }
        return Array(ranked.prefix(max(0, limit)))
    }

    static func tieBreak(_ a: LibraryNode, _ b: LibraryNode) -> Bool {
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }

    /// "Physics › Mechanics": the folders above a node (nil at the library root).
    @MainActor
    static func location(of node: LibraryNode, in library: LibraryService) -> String? {
        var titles: [String] = []
        var next = node.parent
        var seen = Set<NibID>()
        while let id = next, seen.insert(id).inserted, titles.count < 32, let folder = library.node(id) {
            titles.insert(folder.title, at: 0)
            next = folder.parent
        }
        return titles.isEmpty ? nil : titles.joined(separator: " › ")
    }
}

/// Where "Append Text to Note" puts the text: a paragraph at the end of a text document; a text box under the last
/// thing on the last page of a notebook (on a new page when that one is full); under everything on a whiteboard's
/// last board. Study sets hold cards, not notes.
enum AppendPlan: Equatable {
    case paragraph(doc: DocumentID)
    case textBox(doc: DocumentID, page: PageID, at: Point)
    case textBoxOnNewPage(doc: DocumentID, at: Point)
}

enum AppendPlanner {
    /// Left margin: 9 % of the page width, between 36 and 72 pt (≈ 2 cm on A4).
    static func leftMargin(_ width: Double) -> Double { min(72, max(36, width * 0.09)) }
    static let topMargin = 72.0
    static let bottomMargin = 48.0
    /// Space between the last thing on the page and the new text.
    static let gap = 24.0
    /// Room one line of new text needs.
    static let lineRoom = 40.0

    static func plan(_ content: DocumentContent, lastPageItems: [Item]) throws -> AppendPlan {
        let doc = content.meta.id
        switch content.meta.kind {
        case .textDocument:
            return .paragraph(doc: doc)
        case .studySet:
            throw NibError(.unsupported, "study sets hold cards, not text", path: "$.doc",
                           hint: "choose a notebook, whiteboard or text document, or add a card with card.add")
        case .whiteboard:
            guard let board = content.livePages.last else {
                throw NibError(.notFound, "the whiteboard has no board", path: "$.doc")
            }
            guard let bounds = union(lastPageItems) else {
                return .textBox(doc: doc, page: board.id, at: Point(0, 0))
            }
            return .textBox(doc: doc, page: board.id, at: Point(bounds.minX, bounds.maxY + gap * 2))
        case .notebook:
            guard let page = content.livePages.last else {
                return .textBoxOnNewPage(doc: doc, at: Point(leftMargin(PageSize.standard.width), topMargin))
            }
            let size = page.size ?? PageSize.standard
            let x = leftMargin(size.width)
            guard let bounds = union(lastPageItems) else {
                return .textBox(doc: doc, page: page.id, at: Point(x, topMargin))
            }
            let y = max(topMargin, bounds.maxY + gap)
            if y + lineRoom > size.height - bottomMargin {
                return .textBoxOnNewPage(doc: doc, at: Point(x, topMargin))
            }
            return .textBox(doc: doc, page: page.id, at: Point(x, y))
        }
    }

    /// Bounds of every live item with a size (comment pins and empty strokes do not push the text down).
    static func union(_ items: [Item]) -> Rect? {
        var out: Rect?
        for item in items where !item.deleted {
            let b = item.bounds
            guard b.width > 0 || b.height > 0, b.x.isFinite, b.y.isFinite, item.kind != .comment else { continue }
            out = out.map { $0.union(b) } ?? b
        }
        return out
    }
}

/// What the App Intents (app target) run, as the user: through the command bus, so undo, provenance and every
/// feature's checks apply exactly as for a tap.
@MainActor
enum IntentActions {
    static func appendText(_ text: String, to doc: DocumentID, app: NibApp) async throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NibError(.invalidParams, "there is no text to add", path: "$.text") }
        let library = try app.services.require(app.services.library, "the library")
        guard let node = library.node(doc), node.kind == .document, node.trashedAt == nil else {
            throw NibError(.notFound, "that document is not in the library (it may be in Trash)", path: "$.doc")
        }
        let title = QuickActions.displayTitle(node.title)
        // Siri and Shortcuts run without unlocking: a locked or read-only document is left alone.
        if app.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "\(title) is locked", hint: "unlock it in Nib, then run the shortcut again")
        }
        if app.isReadOnly(doc) {
            throw NibError(.unsupported, "\(title) was saved by a newer version of Nib and opens read-only",
                           hint: "update Nib to add to it")
        }
        let content = try app.workspace.content(doc)
        let last = try content.livePages.last.map { try app.workspace.items(doc, page: $0.id) } ?? []
        let plan = try AppendPlanner.plan(content, lastPageItems: last)
        let group = NibID.make().raw
        let session = app.services.sessions.active
        func run(_ command: String, _ params: JSONValue) async throws -> JSONValue {
            try await app.bus.execute(Invocation(command: command, params: params, principal: .user, session: session,
                                                 group: group)).value
        }
        let docRef = NodeRef.document(doc).description
        let result: JSONValue
        switch plan {
        case .paragraph:
            result = try await run(SystemIDs.blockInsert, ["doc": .string(docRef), "kind": "paragraph",
                                                           "text": .string(body)])
        case let .textBox(_, page, at):
            result = try await run(SystemIDs.textCreateBox, ["page": .string(NodeRef.page(doc, page).description),
                                                             "at": [.number(at.x), .number(at.y)], "text": .string(body)])
        case let .textBoxOnNewPage(_, at):
            let page = NibID.make()
            _ = try await run(SystemIDs.pageAdd, ["doc": .string(docRef), "position": "end", "id": .string(page.raw)])
            result = try await run(SystemIDs.textCreateBox, ["page": .string(NodeRef.page(doc, page).description),
                                                             "at": [.number(at.x), .number(at.y)], "text": .string(body)])
        }
        return result["ref"]?.stringValue ?? docRef
    }
}
