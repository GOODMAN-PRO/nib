import SwiftUI
import NibContracts

/// Who made something, in people's words (DESIGN.md §14.9 provenance, the undo history): the principal of a command
/// as a badge (`NibBadge(.principal)`), a menu header ("Made by Assistant · 09:41") or a history row.
public enum NibPrincipalKind: String, CaseIterable, Sendable {
    case you, assistant, plugin, bridge, collaborator

    public init(_ principal: Principal) {
        switch principal {
        case .user: self = .you
        case .ai: self = .assistant
        case .plugin: self = .plugin
        case .bridge: self = .bridge
        case .sync: self = .collaborator
        }
    }

    public var title: String {
        switch self {
        case .you: return String(localized: "You", bundle: .module)
        case .assistant: return String(localized: "Assistant", bundle: .module)
        case .plugin: return String(localized: "Plugin", bundle: .module)
        case .bridge: return String(localized: "Bridge", bundle: .module)
        case .collaborator: return String(localized: "Collaborator", bundle: .module)
        }
    }

    public var symbol: NibSymbol {
        switch self {
        case .you: return .pencil
        case .assistant: return .assistant
        case .plugin: return .puzzle
        case .bridge: return .bridge
        case .collaborator: return .shared
        }
    }

    /// The assistant's drop is in accent, as every AI mark is; the others are secondary. The word is always there, so
    /// the colour is never the only signal.
    var glyphColor: Color { self == .assistant ? NibColor.accent : NibColor.labelSecondary }
}
