import SwiftUI
import NibContracts
import NibDesign

/// The active tool's contextual options and its settings. The options bar is a `NibToolOptionsBar` that
/// `NibToolPalette(toolOptions:)` fuses to the palette's far side, level with the selected tool (DESIGN.md §13.3), so
/// it floats with the palette and docks with it on any screen edge. Its content comes from `ui.toolMenus` (registered
/// under the tool id) and otherwise from the toolbar item's own `activeToolMenu`.
@MainActor
enum ActiveToolMenuHost {
    enum Source: Equatable {
        /// A `ui.toolMenus` entry, the item's own `activeToolMenu`, or no options.
        case toolMenus, descriptor, absent
    }

    /// A `ui.toolMenus` entry wins over the item's `activeToolMenu`, so one feature (presets) can serve several tools.
    static func source(for descriptor: ToolbarItemDescriptor, app: NibApp) -> Source {
        if app.ui.toolMenus.get(descriptor.toolID ?? descriptor.id) != nil { return .toolMenus }
        return descriptor.activeToolMenu == nil ? .absent : .descriptor
    }

    static func menu(for descriptor: ToolbarItemDescriptor, app: NibApp, session: EditorSession) -> AnyView? {
        switch source(for: descriptor, app: app) {
        case .toolMenus: return app.ui.toolMenus.get(descriptor.toolID ?? descriptor.id)?.makeView(session)
        case .descriptor: return descriptor.activeToolMenu?(session)
        case .absent: return nil
        }
    }

    /// The options bar's content: the tool's options, then the chevron that buds its settings (T-001: "tap the
    /// selected tool again, or its chevron"). A tool with neither has no options bar.
    static func optionsBar(for descriptor: ToolbarItemDescriptor, app: NibApp, session: EditorSession,
                           openSettings: @escaping () -> Void) -> AnyView? {
        let options = Self.menu(for: descriptor, app: app, session: session)
        let settingsTitle = descriptor.settings == nil ? nil : descriptor.title
        guard options != nil || settingsTitle != nil else { return nil }
        return AnyView(ActiveToolOptions(menu: options, settingsTitle: settingsTitle, openSettings: openSettings))
    }
}

/// Inside the options bar droplet: the tool's options and a chevron for its settings. The chevron is also the
/// explicit settings button VoiceOver and Full Keyboard Access reach (tapping the selected tool again is not
/// discoverable there).
struct ActiveToolOptions: View {
    let menu: AnyView?
    let settingsTitle: String?
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let menu {
                menu
            }
            if let settingsTitle {
                if menu != nil { NibBarSeparator() }
                NibIconButton(.chevronDown, label: String(localized: "\(settingsTitle) Settings"), size: .bar,
                              action: openSettings)
            }
        }
    }
}

/// The body of a tool's settings popover, which the palette buds out of the tool (a second tap on it, or the options
/// bar's chevron through `settingsPresented`): the toolbar item's `settings` view.
struct ToolSettingsContent: View {
    let model: ToolbarModel
    let toolID: String

    var body: some View {
        if let view = model.settingsView(for: toolID) {
            view
        }
    }
}
