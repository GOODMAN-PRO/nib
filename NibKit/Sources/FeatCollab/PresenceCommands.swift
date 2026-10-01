import Foundation
import NibContracts

// The three presence commands (ARCHITECTURE.md §6.5 `collab.*`, F108). The beads, the follow HUD, the title and More
// menus, the thumbnail menus, the Shared tab and the page dwell all run them, so the AI, plugins and the bridge can
// follow, lead and clear badges exactly as a person does. All three are session effects: nothing in a document
// changes; `collab.markSeen` stores this device's seen marks (device-local settings).

@MainActor
enum PresenceCommands {
    static func register(_ app: NibApp) {
        app.commands.register(CollabFollowCommand.self)
        app.commands.register(CollabFollowMeCommand.self)
        app.commands.register(CollabMarkSeenCommand.self)
    }

    /// The live session, or a `not_found` that says how to start one.
    static func requireLive(_ hub: PresenceHub) throws -> PresenceUIState {
        guard hub.state.live else {
            throw NibError(.notFound, String(localized: "No live session is running."),
                           hint: "start one with collab.host or join one with collab.join")
        }
        return hub.state
    }

    /// A participant by id, or by a name only one participant has (people and models type names).
    static func resolve(_ key: String, in state: PresenceUIState) throws -> CollabParticipant {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == state.me {
            throw NibError(.invalidParams, String(localized: "You can't follow yourself."), path: "$.participant",
                           hint: "call collab.participants for the others' ids")
        }
        if let p = state.others.first(where: { $0.id == trimmed }) { return p }
        let named = state.others.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if named.count == 1, let p = named.first { return p }
        throw NibError(.notFound, String(localized: "No one called “\(trimmed)” is connected to this live session."),
                       path: "$.participant", hint: "call collab.participants for participant ids")
    }
}

// MARK: - collab.follow

struct CollabFollowCommand: NibCommand {
    struct Params: Codable {
        var participant: String?
    }

    struct Output: Codable {
        /// Participant id now followed; nil = following nobody.
        var following: String?
        var name: String?
        /// The page they are on, in this library ("page:D/P"), when known.
        var page: String?
    }

    static let descriptor = CommandDescriptor(
        id: "collab.follow", title: "Follow Collaborator",
        summary: "Follow a live-session participant's view (your window shows the page and area they look at); omit participant to stop following.",
        params: .obj(["participant": .str("participant id from collab.participants (a name only one person has also works); omit to stop")]),
        examples: [["participant": "00000008"], [:]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let hub = try PresenceHub.require(ctx)
        let state = try PresenceCommands.requireLive(hub)
        guard let key = p.participant, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !ctx.dryRun { hub.follow.follow(nil) }
            return Output(following: nil, name: nil, page: nil)
        }
        let person = try PresenceCommands.resolve(key, in: state)
        if !ctx.dryRun {
            let window = ctx.activeSession.flatMap { $0.document == state.doc ? $0 : nil }
            hub.follow.follow(person.id, window: window)
        }
        let page = (hub.presence.people[person.id]?.viewport?.page ?? hub.rosterPage(person.id))
            .flatMap { page in state.doc.map { NodeRef.page($0, page).description } }
        return Output(following: person.id, name: person.name, page: page)
    }
}

// MARK: - collab.followMe

struct CollabFollowMeCommand: NibCommand {
    struct Params: Codable {
        var on: Bool
    }

    struct Output: Codable {
        var on: Bool
        /// How many other participants were told.
        var participants: Int
    }

    static let descriptor = CommandDescriptor(
        id: "collab.followMe", title: "Follow Me",
        summary: "Make everyone in your live session follow your view (on true), as a teacher leads a class, or let them go (on false).",
        params: .obj(["on": .bool("true = everyone follows you; false = stop")], required: ["on"]),
        examples: [["on": true], ["on": false]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let hub = try PresenceHub.require(ctx)
        let state = try PresenceCommands.requireLive(hub)
        if p.on, hub.hooks?.session?.isHost != true, hub.hooks?.session?.myRole != .edit {
            throw NibError(.permissionDenied, String(localized: "Only editors can lead a live session."),
                           hint: "ask the host for the edit role with collab.setRole")
        }
        if !ctx.dryRun { hub.follow.setLeading(p.on) }
        return Output(on: p.on, participants: state.others.count)
    }
}

// MARK: - collab.markSeen

struct CollabMarkSeenCommand: NibCommand {
    struct Params: Codable {
        var pages: [String]
    }

    struct Output: Codable {
        /// Pages that had unseen changes and no longer do.
        var cleared: [String]
        /// How many unseen changes that cleared.
        var changes: Int
        /// Unseen changes left in the documents named.
        var remaining: Int
    }

    static let descriptor = CommandDescriptor(
        id: "collab.markSeen", title: "Mark as Seen",
        summary: "Clear unseen-change badges of pages others changed: page refs mark those pages seen, a doc ref marks the whole document seen.",
        params: .obj(["pages": .arr(.ref, "page refs page:D/P, or doc:D for every page of a document")],
                     required: ["pages"]),
        examples: [["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]], ["pages": ["doc:FIXTUREDOC01"]]],
        effect: .session, target: .document)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let hub = try PresenceHub.require(ctx)
        // Document → what to mark (the whole document, or pages), in the order given.
        var order: [DocumentID] = []
        var whole = Set<DocumentID>()
        var pagesOf: [DocumentID: [PageID]] = [:]
        for (i, raw) in p.pages.enumerated() {
            let path = "$.pages[\(i)]"
            let doc: DocumentID
            var page: PageID?
            switch NodeRef(raw) {
            case let .page(d, pg)?:
                doc = d
                page = pg
            case let .document(d)?:
                doc = d
            case nil where NibID.isValid(raw):
                doc = NodeRef.documentID(from: raw)
            default:
                throw NibError(.invalidParams, "expected a page ref page:D/P or a document ref doc:D", path: path,
                               hint: "pass page refs, or doc:D for a whole document")
            }
            guard let content = try? ctx.workspace.peekContent(doc) else { throw NibError.notFound("document \(doc)") }
            if let page = page, content.page(page) == nil { throw NibError.notFound("page \(page) in document \(doc)") }
            if !order.contains(doc) { order.append(doc) }
            if let page = page {
                if !(pagesOf[doc]?.contains(page) ?? false) { pagesOf[doc, default: []].append(page) }
            } else {
                whole.insert(doc)
            }
        }
        let tracker = hub.unseen
        var cleared: [String] = []
        var changes = 0
        for doc in order {
            let pages: [PageID]? = whole.contains(doc) ? nil : (pagesOf[doc] ?? [])
            let before = tracker.unseen(doc)
            let hit = pages.map { list in list.filter { before[$0]?.isEmpty == false } }
                ?? Array(before.filter { !$0.value.isEmpty }.keys)
            cleared += hit.map { NodeRef.page(doc, $0).description }
            changes += hit.reduce(0) { $0 + (before[$1]?.count ?? 0) }
            if !ctx.dryRun { try tracker.markSeen(doc, pages: pages) }
        }
        if !ctx.dryRun, !order.isEmpty { hub.unseenChanged() }
        let remaining = order.reduce(0) { $0 + tracker.count($1) } - (ctx.dryRun ? changes : 0)
        return Output(cleared: cleared.sorted(), changes: changes, remaining: remaining)
    }
}

// MARK: - Seen marks (written only from collab.markSeen)

extension UnseenTracker {
    /// Stores revisions actually present in the document. G9's content revision falls back to loading the page
    /// when persistence cannot supply it; a local wall clock must never hide a collaborator's next edit.
    func markSeen(_ doc: DocumentID, pages: [PageID]?) throws {
        let content = try app.workspace.peekContent(doc)
        let records = pages.map { wanted in content.pages.filter { wanted.contains($0.id) } } ?? content.pages
        var pageMarks: [PageID: Rev] = [:]
        for record in records {
            let newest: Rev
            if let rev = app.workspace.contentRevision(doc, page: record.id) {
                newest = max(record.rev.effective(), rev.effective())
            } else {
                let items = try app.workspace.allItems(doc, page: record.id)
                newest = UnseenComputation.newest(record, items: items) ?? .zero
            }
            pageMarks[record.id] = max(newest, lastSeen(doc, page: record.id)?.effective() ?? .zero)
        }
        if pages != nil {
            for (page, mark) in pageMarks {
                app.settings.setJSON(UnseenTracker.pageKey(doc, page), .string(mark.description))
            }
        } else {
            let mark = max(baseline(doc)?.effective() ?? .zero, pageMarks.values.max() ?? .zero)
            app.settings.setJSON(UnseenTracker.docKey(doc), .string(mark.description))
            for name in app.settings.names(prefix: UnseenTracker.docKey(doc) + ".") { app.settings.setJSON(name, nil) }
        }
        forgetMarks()
        clear(doc, pages: pages)
    }
}
