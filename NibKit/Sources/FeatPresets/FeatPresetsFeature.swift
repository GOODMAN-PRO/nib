import SwiftUI
import NibContracts
import NibDesign

/// Tool presets (F008): the colour and thickness slots of the pen, pencil, highlighter, tape, shape and draw-shape
/// tools, the custom colour picker and the in-document eyedropper. State lives in `NibSettings.presets(tool)` (synced)
/// and changes only through the `preset.*` commands, so the AI, plugins and the bridge can do everything the menu does.
public enum FeatPresetsFeature: NibFeature {
    public static let id = "presets"

    public static func register(_ app: NibApp) {
        app.commands.register(PresetSelect.self)
        app.commands.register(PresetSetSwatch.self)
        app.commands.register(PresetAddSwatch.self)
        app.commands.register(PresetRemoveSwatch.self)
        app.commands.register(PresetMoveSwatch.self)
        app.commands.register(PresetSetWidth.self)
        app.commands.register(PresetReset.self)

        for tool in NibSettings.presetTools {
            app.ui.toolMenus.register(ToolMenuDescriptor(tool: tool, owner: id) { [weak app] session in
                guard let app else { return AnyView(EmptyView()) }
                // Keyed by tool: the palette shows one menu at a time in the same place, and each tool has its own state.
                return AnyView(ToolPresetMenu(app: app, session: session, tool: tool).id(tool))
            })
        }

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: EyedropperAttachment.descriptorID, owner: id,
                                                                     order: -100) { _ in EyedropperAttachment() })

        registerShortcuts(app)
    }

    /// `[` and `]` step through the active tool's thickness slots; 1–9 and 0 pick its first ten colours (DESIGN.md §12).
    static func registerShortcuts(_ app: NibApp) {
        func shortcut(_ keyID: String, _ title: String, _ key: String, _ params: JSONValue, order: Int) {
            app.content.keyCommands.register(KeyCommandDescriptor(id: keyID, title: title, shortcut: KeyShortcut(key),
                                                                  command: "preset.select", params: params, scope: .canvas,
                                                                  order: order, owner: id))
        }
        shortcut("presets.width.previous", String(localized: "Thinner Preset"), "[", ["tool": "current", "widthStep": -1], order: 0)
        shortcut("presets.width.next", String(localized: "Thicker Preset"), "]", ["tool": "current", "widthStep": 1], order: 1)
        for slot in 0..<10 {
            shortcut("presets.swatch.\(slot + 1)", String(localized: "Colour Preset \(slot + 1)"), slot == 9 ? "0" : String(slot + 1),
                     ["tool": "current", "swatch": .number(Double(slot))], order: 2 + slot)
        }
    }
}
