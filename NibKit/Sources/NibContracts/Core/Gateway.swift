import Foundation

public enum ConfirmationPolicy: String, Codable, CaseIterable {
    /// Confirm every mutating command.
    case always
    /// Confirm destructive commands (default).
    case destructive
    /// Never confirm (irreversible, sensitive and plugin-management commands are still confirmed).
    case never

    private var rank: Int {
        switch self {
        case .always: return 2
        case .destructive: return 1
        case .never: return 0
        }
    }

    /// The stricter of two policies (nil = no constraint).
    public static func stricter(_ a: ConfirmationPolicy?, _ b: ConfirmationPolicy?) -> ConfirmationPolicy? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        return a.rank >= b.rank ? a : b
    }
}

public struct ConfirmationRequest {
    public let principal: Principal
    public let command: CommandDescriptor
    public let params: JSONValue

    public init(principal: Principal, command: CommandDescriptor, params: JSONValue) {
        self.principal = principal
        self.command = command
        self.params = params
    }
}

public enum ConfirmationDecision { case allow, allowRestOfGroup, deny }

/// Shows the confirmation sheet. The app shell installs a minimal alert-based presenter at launch (so plugins and
/// the bridge work without the AI chat feature); F085 wraps it with its richer sheet for AI turns.
@MainActor
public protocol ConfirmationPresenter: AnyObject {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision
}

/// Permission, lock and confirmation checks for every non-user call.
@MainActor
public final class Gateway {
    /// Granted scopes per principal. The plugin host replaces this to answer for `.plugin(id)`.
    public var grants: (Principal) -> Set<Scope>
    /// Confirmation policy per principal (AI / bridge settings).
    public var policy: (Principal) -> ConfirmationPolicy
    /// True when a document is locked for non-user principals (Password Lock feature).
    public var isLocked: (DocumentID) -> Bool
    public weak var presenter: ConfirmationPresenter?
    private var allowedGroups = Set<String>()

    public init() {
        grants = { p in Gateway.defaultGrants(p) }
        policy = { _ in .destructive }
        isLocked = { _ in false }
    }

    public nonisolated static func defaultGrants(_ p: Principal) -> Set<Scope> {
        switch p {
        case .user: return Set(Scope.allCases)
        case .ai, .bridge: return Set(Scope.allCases).subtracting([.security])
        case .plugin, .sync: return []
        }
    }

    public func authorize(_ d: CommandDescriptor, params: JSONValue, principal: Principal, group: String,
                          inheritedPolicy: ConfirmationPolicy? = nil) async throws {
        if principal.isUser { return }
        if case .sync = principal { throw NibError(.permissionDenied, "sync cannot run commands") }
        guard d.exposure.contains(principal.exposure) else {
            throw NibError(.permissionDenied, "'\(d.id)' is not available to \(principal)")
        }
        if d.scopes.contains(.security) {
            throw NibError(.permissionDenied, "'\(d.id)' can only be run by the user")
        }
        let missing = d.scopes.subtracting(grants(principal))
        guard missing.isEmpty else {
            throw NibError(.permissionDenied, "missing permission(s): " + missing.map { $0.rawValue }.sorted().joined(separator: ", "),
                           hint: "the user must grant these permissions")
        }
        for doc in Gateway.referencedDocuments(params) where isLocked(doc) {
            throw NibError(.locked, "document \(doc) is locked", hint: "ask the user to unlock it first")
        }
        guard needsConfirmation(d, principal: principal, inheritedPolicy: inheritedPolicy),
              !allowedGroups.contains(group) else { return }
        guard let presenter = presenter else {
            throw NibError(.userDenied, "'\(d.title)' needs confirmation but no confirmation UI is available")
        }
        switch await presenter.confirm(ConfirmationRequest(principal: principal, command: d, params: params)) {
        case .allow: return
        case .allowRestOfGroup: allowedGroups.insert(group)
        case .deny: throw NibError(.userDenied, "the user declined '\(d.title)'")
        }
    }

    public func needsConfirmation(_ d: CommandDescriptor, principal: Principal,
                                  inheritedPolicy: ConfirmationPolicy? = nil) -> Bool {
        if principal.isUser { return false }
        if d.effect == .irreversible || d.sensitive || d.scopes.contains(.pluginsManage) { return true }
        switch ConfirmationPolicy.stricter(policy(principal), inheritedPolicy) ?? .destructive {
        case .always: return d.isMutating
        case .destructive: return d.destructive
        case .never: return false
        }
    }

    /// Documents referenced by ref strings anywhere in `params`, or by bare ids under doc/document/docId keys.
    public nonisolated static func referencedDocuments(_ params: JSONValue) -> Set<DocumentID> {
        var out = Set<DocumentID>()
        func walk(_ v: JSONValue, key: String?) {
            switch v {
            case .string(let s):
                if let ref = NodeRef(s), let d = ref.documentID {
                    out.insert(d)
                } else if let k = key, ["doc", "document", "docId", "documentId"].contains(k), NibID.isValid(s) {
                    out.insert(NibID(s))
                }
            case .array(let a):
                for x in a { walk(x, key: key) }
            case .object(let o):
                for (k, x) in o { walk(x, key: k) }
            default:
                break
            }
        }
        walk(params, key: nil)
        return out
    }
}
