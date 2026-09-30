import Foundation

/// Who is calling a command. String form: "user", "plugin:<id>", "ai:<chat>", "bridge:<client>", "sync:<device>".
public enum Principal: Hashable, Codable, CustomStringConvertible {
    case user
    case plugin(String)
    case ai(String)
    case bridge(String)
    case sync(String)

    public init(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1).map { String($0) }
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "plugin": self = .plugin(rest)
        case "ai": self = .ai(rest)
        case "bridge": self = .bridge(rest)
        case "sync": self = .sync(rest)
        default: self = .user
        }
    }

    public var description: String {
        switch self {
        case .user: return "user"
        case .plugin(let id): return "plugin:\(id)"
        case .ai(let id): return "ai:\(id)"
        case .bridge(let id): return "bridge:\(id)"
        case .sync(let id): return "sync:\(id)"
        }
    }

    public var isUser: Bool { self == .user }

    /// contracts-v2: "user", "plugin", "ai", "bridge" or "sync" (per-kind gateway policies and presenters).
    public var kind: String {
        switch self {
        case .user: return "user"
        case .plugin: return "plugin"
        case .ai: return "ai"
        case .bridge: return "bridge"
        case .sync: return "sync"
        }
    }

    /// The exposure bit a command needs for this principal to see it.
    public var exposure: Exposure {
        switch self {
        case .user: return .ui
        case .plugin: return .plugin
        case .ai: return .ai
        case .bridge: return .bridge
        case .sync: return []
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self.init(string: s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// What a command does. Drives undo, confirmation and default scopes.
public enum Effect: String, Codable, CaseIterable {
    /// No mutation.
    case read
    /// Editor/window state only (tool, selection, zoom, navigation, panels). Not undoable, not persisted in documents.
    case session
    /// Undoable document mutation through `CommandContext.mutate`.
    case edit
    /// Library/file-system change (create, move, rename, trash). Recoverable through Trash, not on the undo stack.
    case library
    /// Cannot be undone (empty trash, delete permanently, overwrite a source file). Always confirmed for non-users.
    case irreversible
}

public enum CommandTarget: String, Codable, CaseIterable { case document, library, app }

public enum Scope: String, Codable, CaseIterable, Hashable {
    case documentRead = "document:read"
    case documentWrite = "document:write"
    case libraryRead = "library:read"
    case libraryWrite = "library:write"
    case destructive
    case app
    case ai
    case network
    /// Install/enable/remove plugins. Grantable to AI and bridge (always confirmed), never to plugins.
    case pluginsManage = "plugins:manage"
    /// Security settings, secrets, grants, passwords. Never granted to any non-user principal.
    case security
}

/// Which callers may see/run a command.
public struct Exposure: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ui = Exposure(rawValue: 1)
    public static let plugin = Exposure(rawValue: 2)
    public static let ai = Exposure(rawValue: 4)
    public static let bridge = Exposure(rawValue: 8)
    public static let all: Exposure = [.ui, .plugin, .ai, .bridge]
}
