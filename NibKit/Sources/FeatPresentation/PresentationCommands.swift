import Foundation
import NibContracts

/// What the external display shows (Goodnotes: Share & Export › Presentation Mode).
enum ExternalDisplayMode: String, Codable, CaseIterable {
    /// Periodic snapshots of the main window, chrome included.
    case mirror
    /// The active page only, following the presenter's zoom and scroll with animations.
    case presenter
    /// The whole active page, no zoom, no animation (flipbook).
    case fullPage

    /// Share & Export menu order: the page modes first.
    static let menuOrder: [ExternalDisplayMode] = [.presenter, .fullPage, .mirror]

    var title: String {
        switch self {
        case .mirror: return String(localized: "Mirror Entire Screen")
        case .presenter: return String(localized: "Presenter Page")
        case .fullPage: return String(localized: "Full Page")
        }
    }
}

enum PresentationSettings {
    /// Device-local: the external display belongs to this device, not to the library.
    static let mode = SettingKey("presentation.mode", default: ExternalDisplayMode.presenter)
}

/// `present.setMode {mode, blank?}`: the one presentation command. The presenter HUD, the Share & Export menu,
/// plugins, the AI and the bridge all switch modes (and blank the screen) through it.
struct PresentSetMode: NibCommand {
    static let id = "present.setMode"

    struct Params: Codable {
        var mode: String
        var blank: Bool?
    }

    struct Output: Codable {
        var mode: String
        var blank: Bool
        /// True while an external display (AirPlay or cable) is connected.
        var externalDisplay: Bool
        var displays: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "present.setMode", title: "Presentation Mode",
        summary: "External display: mirror (whole screen), presenter (active page, follows zoom/scroll) or fullPage (whole page, no animation); blank: true shows black.",
        params: .obj(["mode": .str("mirror | presenter | fullPage", choices: ExternalDisplayMode.allCases.map { $0.rawValue }),
                      "blank": .bool("black out the external display (default false)")],
                     required: ["mode"]),
        examples: [["mode": "presenter"], ["mode": "fullPage"], ["mode": "mirror"], ["mode": "presenter", "blank": true]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let mode = ExternalDisplayMode(rawValue: p.mode) else {
            throw NibError(.invalidParams, "unknown presentation mode '\(p.mode)'", path: "$.mode",
                           hint: "use mirror, presenter or fullPage")
        }
        let controller = ctx.services.get(PresentationController.serviceKey, as: PresentationController.self)
        controller?.setBlank(p.blank ?? false)
        ctx.services.settings.set(PresentationSettings.mode, mode)
        return Output(mode: mode.rawValue, blank: controller?.blank ?? false,
                      externalDisplay: controller?.isConnected ?? false, displays: controller?.displayNames ?? [])
    }
}
