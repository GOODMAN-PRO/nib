import Foundation
import NibContracts

// The seam between the two halves of the collaboration module (ARCHITECTURE.md §3, split features):
// F072 (this half: transport, session, sync and approval) publishes what happens in a live session through
// `CollabHooks`; F108 (presence, follow, unseen changes and the Shared tab) observes it and sends its own presence
// payloads through the same session, in its `register`, without F072 ever naming an F108 type.

// MARK: - Roles and participants

/// What a participant may do in the shared document (S-075).
enum CollabRole: String, Codable, CaseIterable {
    case edit, view

    /// Accepts the schema values plus the words people and models use ("read-only", "viewer", "editor").
    init?(param: String) {
        switch param.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
        case "edit", "editor", "canedit", "write": self = .edit
        case "view", "viewer", "canview", "readonly", "read": self = .view
        default: return nil
        }
    }

    /// "Can edit" / "Can view" (DESIGN.md §14.14).
    var title: String {
        switch self {
        case .edit: return String(localized: "Can edit")
        case .view: return String(localized: "Can view")
        }
    }
}

enum CollabParticipantState: String, Codable, CaseIterable {
    /// Asked to join; waiting for the host (`collab.approve`).
    case pending
    /// In the session.
    case active
    /// Admitted, but its connection dropped (suspended, out of range); it re-joins with the same code without asking
    /// again.
    case away
}

/// One person in a live session as every participant sees it. The host's roster is authoritative; guests mirror it.
struct CollabParticipant: Codable, Equatable, Identifiable {
    /// Stable per device: the device id (`NibApp.deviceHex`).
    var id: String
    var name: String
    var role: CollabRole
    var state: CollabParticipantState
    var isHost: Bool
    /// Index into `NibPresenceColour` (host 0, then join order).
    var colorIndex: Int
    /// The participant's `NibFormat.version` (S-100 feature gating).
    var format: Int
    /// The page they are looking at, as a ref in the HOST's document ids ("page:D/P"); nil when unknown.
    var page: String?
    /// Unix seconds.
    var joinedAt: Double
    /// Their Nib is older than the newest one in the session, so they can only view until they update (S-100).
    var needsUpdate: Bool

    init(id: String, name: String, role: CollabRole, state: CollabParticipantState, isHost: Bool, colorIndex: Int,
         format: Int = NibFormat.version, page: String? = nil, joinedAt: Double = Date().timeIntervalSince1970,
         needsUpdate: Bool = false) {
        self.id = id
        self.name = name
        self.role = role
        self.state = state
        self.isHost = isHost
        self.colorIndex = colorIndex
        self.format = format
        self.page = page
        self.joinedAt = joinedAt
        self.needsUpdate = needsUpdate
    }

    enum CodingKeys: String, CodingKey { case id, name, role, state, isHost, colorIndex, format, page, joinedAt, needsUpdate }

    /// Lenient: only `id` is required, so a roster from another Nib version still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = (try? c.decodeIfPresent(CollabRole.self, forKey: .role)) ?? .view
        state = (try? c.decodeIfPresent(CollabParticipantState.self, forKey: .state)) ?? .active
        isHost = try c.decodeIfPresent(Bool.self, forKey: .isHost) ?? false
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? NibFormat.version
        page = try c.decodeIfPresent(String.self, forKey: .page)
        joinedAt = try c.decodeIfPresent(Double.self, forKey: .joinedAt) ?? 0
        needsUpdate = try c.decodeIfPresent(Bool.self, forKey: .needsUpdate) ?? false
    }

    /// "SL" for "Sam Lee", "S" for "Sam" (presence beads).
    var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return letters.isEmpty ? "?" : letters
    }

    /// The presence colour as "#RRGGBB" (never collides with ink; DESIGN.md §3.6).
    var colorHex: String { String(format: "#%06X", NibPresenceColour.hex(colorIndex)) }

    /// Can change the document right now.
    var canEdit: Bool { state == .active && (isHost || role == .edit) }
}

/// Where a live session is (the host is `active` from the start).
enum CollabPhase: String, Codable, CaseIterable {
    case idle
    /// Looking for the session (joiner).
    case connecting
    /// Asked to join; the host has not answered yet.
    case waiting
    /// Admitted; the document is arriving (joiner without it).
    case receiving
    case active
    /// The connection dropped (suspend, out of range); re-joining with the same code.
    case reconnecting
    case ended
}

/// The live session as F108 and the UI see it.
struct CollabSessionInfo: Equatable {
    var id: String
    var code: String
    var isHost: Bool
    /// This device's participant id.
    var me: String
    var myRole: CollabRole
    /// The document in THIS library (nil while a joiner is still receiving it).
    var doc: DocumentID?
    /// The document id as the host knows it (every page ref on the wire uses it).
    var remoteDoc: DocumentID?
    var title: String
    var kind: DocumentKind?
    var hostName: String
    var transport: String
    var phase: CollabPhase
    /// The oldest admitted participant's `NibFormat.version` (S-100). What is enforced: participants older than the
    /// newest Nib in the session can only view (`CollabParticipant.needsUpdate`). Turning newer features off per
    /// document needs an effective-format contract features can read, which does not exist yet.
    var sessionFormat: Int
    /// Most participants the transport carries (8 nearby, 50 over the relay; S-101).
    var cap: Int
    var startedAt: Double
}

/// A document this device shared or received live (F108's Shared tab).
struct CollabSharedDocument: Codable, Equatable {
    /// Id in this library.
    var local: DocumentID
    /// Id on the host.
    var remote: DocumentID
    /// "host" or "guest".
    var role: String
    var title: String
    /// Unix seconds of the last session.
    var at: Double
    var code: String?
    /// A guest's admission secret for the session under `code`: after the app is relaunched it re-joins without a
    /// second approval. Device-local (the store is never synced).
    var secret: String?

    init(local: DocumentID, remote: DocumentID, role: String, title: String, at: Double, code: String?,
         secret: String? = nil) {
        self.local = local
        self.remote = remote
        self.role = role
        self.title = title
        self.at = at
        self.code = code
        self.secret = secret
    }
}

// MARK: - Hooks

/// What F072 reports to the second half (F108).
enum CollabHookEvent {
    /// A session started, changed phase or role, or ended (nil).
    case session(CollabSessionInfo?)
    /// The roster changed (joins, approvals, roles, pages, departures).
    case roster([CollabParticipant])
    /// A participant's changes were merged into this library's copy (unseen-change badges).
    case remoteChanges(participant: String, doc: DocumentID, summary: ChangeSummary, pages: Set<PageID>)
    /// A presence payload from a participant (cursor, viewport, lasso outline, laser, follow requests).
    case presence(participant: String, payload: JSONValue)
}

/// Internal hooks F108 fills in its `register`: observe the session, read the roster, send presence. One per app
/// (`CollabHooks.of(app)`), so two apps in one test process never cross-talk.
@MainActor
final class CollabHooks {
    static let serviceKey = "collab.hooks"

    /// Cancels an `observe` registration.
    final class Token {
        private var onCancel: (() -> Void)?
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() {
            onCancel?()
            onCancel = nil
        }
    }

    static func of(_ app: NibApp) -> CollabHooks? { app.services.get(serviceKey, as: CollabHooks.self) }

    /// The current live session (nil = none).
    private(set) var session: CollabSessionInfo?
    /// The roster, host first, in join order.
    private(set) var participants: [CollabParticipant] = []
    private var observers: [UUID: @MainActor (CollabHookEvent) -> Void] = [:]

    /// Installed by the session: sends a presence payload to one participant or everyone (nil); false when no session
    /// is live.
    var presenceSender: (@MainActor (JSONValue, String?) -> Bool)?
    /// Installed by the service: documents this device shared or received live.
    var sharedDocumentsProvider: (@MainActor () -> [CollabSharedDocument])?

    init() {}

    @discardableResult
    func observe(_ handler: @escaping @MainActor (CollabHookEvent) -> Void) -> Token {
        let id = UUID()
        observers[id] = handler
        return Token { [weak self] in
            CollabSession.onMain { self?.observers[id] = nil }
        }
    }

    /// Sends F108's payload (cursor, viewport, follow) through the live session; the host relays it.
    @discardableResult
    func sendPresence(_ payload: JSONValue, to participant: String? = nil) -> Bool {
        presenceSender?(payload, participant) ?? false
    }

    var sharedDocuments: [CollabSharedDocument] { sharedDocumentsProvider?() ?? [] }

    /// This participant.
    var me: CollabParticipant? { participants.first { $0.id == session?.me } }

    /// A page ref from the wire (host ids) as a ref in this library, or nil when it is not in the shared document.
    func localPageRef(_ remoteRef: String) -> String? {
        guard case let .page(d, p)? = NodeRef(remoteRef), d == session?.remoteDoc, let local = session?.doc else { return nil }
        return NodeRef.page(local, p).description
    }

    /// A page of this library's copy as the ref every participant uses (host ids).
    func remotePageRef(_ page: PageID) -> String? {
        guard let remote = session?.remoteDoc else { return nil }
        return NodeRef.page(remote, page).description
    }

    // MARK: Published by the service

    func update(session: CollabSessionInfo?, participants: [CollabParticipant]) {
        let sessionChanged = session != self.session
        let rosterChanged = participants != self.participants
        self.session = session
        self.participants = participants
        if sessionChanged { publish(.session(session)) }
        if rosterChanged { publish(.roster(participants)) }
    }

    func publish(_ event: CollabHookEvent) {
        for handler in Array(observers.values) { handler(event) }
    }
}
