import Foundation
import NibContracts

// The seven collaboration commands (ARCHITECTURE.md §6.5 `collab.*`, F072). Every button of the Share Live panel, the
// join sheet and the request HUD runs one of them, so the AI, plugins and the bridge can do the same (host and join
// are sensitive: data leaves the device, so non-user callers are always confirmed; approving someone is too).

@MainActor
enum CollabCommands {
    static func register(_ app: NibApp) {
        app.commands.register(CollabHostCommand.self)
        app.commands.register(CollabJoinCommand.self)
        app.commands.register(CollabLeaveCommand.self)
        app.commands.register(CollabParticipantsCommand.self)
        app.commands.register(CollabApproveCommand.self)
        app.commands.register(CollabSetRoleCommand.self)
        app.commands.register(CollabRevokeCommand.self)
    }

    static let transportSchema = JSONSchema.str(
        "multipeer = nearby devices, up to 8 people (default); relay = the internet relay, up to 50 (needs relay.configure)",
        choices: ["multipeer", "relay"])
    static let participantSchema = JSONSchema.str("participant id from collab.participants (a name that only one person has also works)")
    static let roleSchema = JSONSchema.str("edit = can change the document; view = read-only", choices: ["edit", "view"])

    static func role(_ raw: String, path: String) throws -> CollabRole {
        guard let role = CollabRole(param: raw) else {
            throw NibError(.invalidParams, "unknown role '\(raw)'", path: path, hint: "use edit or view")
        }
        return role
    }

    /// Opens the shared document in the invoking window (F018's `doc.open` when installed).
    static func open(_ doc: DocumentID, _ ctx: CommandContext) async {
        if ctx.app?.commands.entry(CommandIDs.docOpen) != nil {
            _ = try? await ctx.execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(doc).description)])
        } else {
            ctx.navigator?.openDocument(doc, page: nil, mode: .newTab)
        }
    }
}

// MARK: - collab.host

struct CollabHostCommand: NibCommand {
    struct Params: Codable {
        var doc: String?
        var transport: String?
        var role: String?
    }

    struct Output: Codable {
        var code: String
        var doc: String
        var title: String
        var transport: String
        /// What people who join may do.
        var role: String
        /// The link the QR code carries.
        var url: String
        /// Most people the session takes, the host included.
        var cap: Int
    }

    static let descriptor = CommandDescriptor(
        id: "collab.host", title: "Share Live",
        summary: "Share a document live (nearby or over the relay) and return the join code others pass to collab.join; the host approves each person.",
        params: .obj(["doc": .ref, "transport": CollabCommands.transportSchema,
                      "role": .str("what people who join may do (default edit)", choices: ["edit", "view"])],
                     required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"], ["doc": "doc:FIXTUREDOC01", "role": "view"]],
        effect: .library, target: .library, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let service = try CollabService.require(ctx)
        let doc = try ctx.documentOrSession(p.doc)
        let role = try p.role.map { try CollabCommands.role($0, path: "$.role") } ?? .edit
        let session = try await service.host(doc: doc, transportKey: p.transport, role: role)
        if p.role != nil { session.defaultRole = role }
        service.rememberShared(local: doc, remote: doc, role: "host", title: session.title, code: session.code)
        return Output(code: session.code, doc: NodeRef.document(doc).description, title: session.title,
                      transport: session.transportKey, role: session.defaultRole.rawValue,
                      url: CollabCode.joinURL(session.code), cap: session.transport.maxPeers)
    }
}

// MARK: - collab.join

struct CollabJoinCommand: NibCommand {
    struct Params: Codable {
        var code: String
        var transport: String?
    }

    struct Output: Codable {
        /// The shared document in this library.
        var doc: String
        var title: String
        /// "edit" or "view".
        var role: String
        var host: String
        var code: String
        var participants: Int
        /// True when the document arrived now (into the Shared folder).
        var received: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "collab.join", title: "Join Live Session",
        summary: "Join a live session with its join code and wait for the host's approval; a document this library lacks arrives in its Shared folder.",
        params: .obj(["code": .str("the 6-character join code, e.g. K7M2QX"), "transport": CollabCommands.transportSchema],
                     required: ["code"]),
        examples: [["code": "K7M2QX"]],
        effect: .library, target: .library, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let service = try CollabService.require(ctx)
        let (session, fresh) = try await service.join(code: p.code, transportKey: p.transport)
        guard let doc = session.localDoc else {
            throw NibError(.internalError, "joined a live session without its document")
        }
        if fresh { await CollabCommands.open(doc, ctx) }
        return Output(doc: NodeRef.document(doc).description, title: session.title, role: session.myRole.rawValue,
                      host: session.hostName, code: session.code, participants: session.publicRoster.count,
                      received: session.receivedSnapshot)
    }
}

// MARK: - collab.leave

struct CollabLeaveCommand: NibCommand {
    struct Params: Codable {}

    struct Output: Codable {
        /// False when no session was running.
        var left: Bool
        /// True when this device hosted it (everyone was disconnected).
        var ended: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "collab.leave", title: "Leave Live Session",
        summary: "Leave the live session you joined, or end the one you host (everyone is disconnected; every copy stays).",
        params: .empty, examples: [[:]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let service = try CollabService.require(ctx)
        let result = service.leave()
        return Output(left: result.left, ended: result.wasHost)
    }
}

// MARK: - collab.participants

/// `collab.participants` → the session and its roster. Page refs use this library's document ids.
struct CollabRosterOutput: Codable {
    struct Person: Codable {
        var id: String
        var name: String
        /// "edit" or "view".
        var role: String
        /// "pending" (waiting for approval), "active" or "away" (re-joining).
        var state: String
        var host: Bool
        var me: Bool
        var page: String?
        /// Presence colour "#RRGGBB".
        var color: String
        var format: Int
        var needsUpdate: Bool
    }

    var active: Bool
    var phase: String
    /// "host" or "guest".
    var side: String?
    var code: String?
    var doc: String?
    var title: String?
    var role: String?
    var me: String?
    var transport: String?
    /// The oldest participant's format version (S-100).
    var sessionFormat: Int?
    var cap: Int?
    /// Why the last session ended.
    var message: String?
    var participants: [Person]

    @MainActor
    static func make(_ service: CollabService) -> CollabRosterOutput {
        guard let s = service.session, !s.isClosed else {
            return CollabRosterOutput(active: false, phase: CollabPhase.idle.rawValue, message: service.state.message,
                                      participants: [])
        }
        let people = s.roster.map { p -> Person in
            var page: String?
            if let ref = p.page, case let .page(_, pid)? = NodeRef(ref), let local = s.localDoc {
                page = NodeRef.page(local, pid).description
            }
            return Person(id: p.id, name: p.name, role: p.role.rawValue, state: p.state.rawValue, host: p.isHost,
                          me: p.id == s.me, page: page, color: p.colorHex, format: p.format, needsUpdate: p.needsUpdate)
        }
        let info = s.info
        return CollabRosterOutput(active: true, phase: info.phase.rawValue, side: s.side.rawValue, code: s.code,
                                  doc: s.localDoc.map { NodeRef.document($0).description }, title: s.title,
                                  role: info.myRole.rawValue, me: s.me, transport: s.transportKey,
                                  sessionFormat: info.sessionFormat, cap: info.cap, message: nil, participants: people)
    }
}

extension CollabRosterOutput {
    init(active: Bool, phase: String, message: String?, participants: [Person]) {
        self.init(active: active, phase: phase, side: nil, code: nil, doc: nil, title: nil, role: nil, me: nil,
                  transport: nil, sessionFormat: nil, cap: nil, message: message, participants: participants)
    }
}

struct CollabParticipantsCommand: NibCommand {
    struct Params: Codable {}
    typealias Output = CollabRosterOutput

    static let descriptor = CommandDescriptor(
        id: "collab.participants", title: "Live Session Participants",
        summary: "The live session (code, document, your role) and its participants with names, pages, roles and states (pending = waiting for approval).",
        params: .empty, examples: [[:]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        CollabRosterOutput.make(try CollabService.require(ctx))
    }
}

// MARK: - collab.approve

struct CollabApproveCommand: NibCommand {
    struct Params: Codable {
        var participant: String
        var allow: Bool
    }

    struct Output: Codable {
        var participant: String
        var name: String
        /// "active" (admitted) or "declined".
        var state: String
    }

    static let descriptor = CommandDescriptor(
        id: "collab.approve", title: "Approve Join Request",
        summary: "Let a person waiting to join your live session in (allow true) or turn them away (allow false); ids come from collab.participants.",
        params: .obj(["participant": CollabCommands.participantSchema, "allow": .bool("true = let them in, false = decline")],
                     required: ["participant", "allow"]),
        examples: [["participant": "00000008", "allow": true]],
        effect: .session, target: .app, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let session = try CollabService.require(ctx).requireSession()
        let person = try session.resolveParticipant(p.participant)
        let admitted = try session.approve(person.id, allow: p.allow)
        return Output(participant: person.id, name: person.name, state: admitted == nil ? "declined" : "active")
    }
}

// MARK: - collab.setRole

struct CollabSetRoleCommand: NibCommand {
    struct Params: Codable {
        var participant: String
        var role: String
    }

    struct Output: Codable {
        var participant: String
        var name: String
        var role: String
    }

    static let descriptor = CommandDescriptor(
        id: "collab.setRole", title: "Change Participant Role",
        summary: "Change what a participant of your live session may do: edit, or view (read-only).",
        params: .obj(["participant": CollabCommands.participantSchema, "role": CollabCommands.roleSchema],
                     required: ["participant", "role"]),
        examples: [["participant": "00000008", "role": "view"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let session = try CollabService.require(ctx).requireSession()
        let role = try CollabCommands.role(p.role, path: "$.role")
        let person = try session.resolveParticipant(p.participant)
        let updated = try session.setRole(person.id, role)
        return Output(participant: updated.id, name: updated.name, role: updated.role.rawValue)
    }
}

// MARK: - collab.revoke

struct CollabRevokeCommand: NibCommand {
    struct Params: Codable {
        var participant: String
    }

    struct Output: Codable {
        var participant: String
        var name: String
        var revoked: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "collab.revoke", title: "Remove from Live Session",
        summary: "Remove a participant from your live session: they are disconnected and can't ask to join again with this code.",
        params: .obj(["participant": CollabCommands.participantSchema], required: ["participant"]),
        examples: [["participant": "00000008"]],
        effect: .session, target: .app, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let session = try CollabService.require(ctx).requireSession()
        let person = try session.resolveParticipant(p.participant)
        let removed = try session.revoke(person.id)
        return Output(participant: removed.id, name: removed.name, revoked: true)
    }
}

// MARK: - Service helpers used by the commands

extension CollabService {
    static func require(_ ctx: CommandContext) throws -> CollabService {
        guard let app = ctx.app, let service = CollabService.of(app) else {
            throw NibError.unavailable("live collaboration")
        }
        return service
    }

    func requireSession() throws -> CollabSession {
        guard let s = session, !s.isClosed else {
            throw NibError(.notFound, String(localized: "No live session is running."),
                           hint: "start one with collab.host or join one with collab.join")
        }
        return s
    }
}

// MARK: - Shared documents (device-local, one setting per document)

enum CollabSharedStore {
    /// "collab.shared.<host document id>" → `CollabSharedDocument` JSON.
    static let prefix = "collab.shared."

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declarePrefix(prefix, synced: false,
                               summary: "Documents this device shared or received live: host document id → local copy, role, title.",
                               owner: owner)
    }
}

extension CollabService {
    /// Records a shared or received document (the join flow and F108's Shared tab read it). Written while
    /// `collab.host` / `collab.join` run.
    func rememberShared(local: DocumentID, remote: DocumentID, role: String, title: String, code: String?) {
        let record = CollabSharedDocument(local: local, remote: remote, role: role, title: title,
                                          at: Date().timeIntervalSince1970, code: code)
        guard let json = try? JSONValue.from(record) else { return }
        app.settings.setJSON(CollabSharedStore.prefix + remote.raw, json)
    }

    func sharedRecord(_ remote: DocumentID) -> CollabSharedDocument? {
        app.settings.json(CollabSharedStore.prefix + remote.raw).flatMap { try? $0.decode(CollabSharedDocument.self) }
    }

    func sharedDocuments() -> [CollabSharedDocument] {
        app.settings.names(prefix: CollabSharedStore.prefix)
            .compactMap { app.settings.json($0).flatMap { try? $0.decode(CollabSharedDocument.self) } }
            .sorted { $0.at > $1.at }
    }

    /// The library's "Shared" folder at the root, created on first use.
    func sharedFolder(_ library: LibraryService) throws -> FolderID {
        let name = String(localized: "Shared")
        if let existing = library.children(of: nil).first(where: { $0.kind == .folder && $0.title == name }) {
            return existing.id
        }
        return try library.createFolder(title: name, in: nil, style: nil)
    }

    /// Saves a host's snapshot into the Shared folder and returns the document's id in this library (the host's id
    /// unless this library already uses it). Runs while `collab.join` waits.
    func importSnapshot(_ s: CollabMessage.Snapshot, author: String) async throws -> DocumentID {
        guard let library = app.services.library else { throw NibError.unavailable("the library") }
        let folder = try sharedFolder(library)
        switch s.format {
        case .package:
            guard let data = s.data else {
                throw NibError.invalid(String(localized: "The shared document arrived empty."))
            }
            let package = try await Task.detached(priority: .userInitiated) { try CollabPackageIO.unzip(data) }.value
            defer { try? FileManager.default.removeItem(at: CollabPackageIO.scratchFolder(of: package)) }
            return try library.importPackage(at: package, into: folder)
        case .content:
            guard var snapshot = s.content else {
                throw NibError.invalid(String(localized: "The shared document arrived empty."))
            }
            if library.node(snapshot.content.meta.id) != nil { snapshot.content.meta.id = NibID.make() }
            let local = try library.createDocument(snapshot.content, title: s.title, in: folder)
            _ = try app.workspace.content(local)
            var patch = DocumentPatch(doc: local)
            patch.items = snapshot.items
            app.bus.applyRemote(patch, origin: CollabSession.originPrefix + author)
            return local
        }
    }
}
