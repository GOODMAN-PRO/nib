import SwiftUI
import NibContracts
import NibDesign

/// Tool presets (F008): the colour and thickness slots of the pen, pencil, highlighter, tape, shape and draw-shape
/// tools, the custom colour picker and the in-document eyedropper. State lives in `NibSettings.presets(tool)` (synced)
/// and changes only through the `preset.*` commands, so the AI, plugins and the bridge can do everything the menu does.
public enum FeatPresetsFeature: NibFeature {
    public static let id = "presets"

    /// Where the preset keys run: the documents whose canvas draws with the preset tools.
    static let canvasKinds: Set<DocumentKind> = [.notebook, .whiteboard]

    public static func register(_ app: NibApp) {
        app.commands.register(PresetSelect.self)
        app.commands.register(PresetSetSwatch.self)
        app.commands.register(PresetAddSwatch.self)
        app.commands.register(PresetRemoveSwatch.self)
        app.commands.register(PresetMoveSwatch.self)
        app.commands.register(PresetSetWidth.self)
        app.commands.register(PresetReset.self)

        let menus = PresetMenus(app: app)
        for tool in NibSettings.presetTools {
            app.ui.toolMenus.register(menuDescriptor(tool, menus: menus))
        }

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: EyedropperAttachment.descriptorID, owner: id,
                                                                     order: -100) { _ in EyedropperAttachment() })

        registerShortcuts(app)
    }

    /// One tool's options bar and its popover (contracts-v2 `makePopover`): both read the window's `PresetMenuModel`,
    /// so a tap in the bar opens the thickness slider or the colour editor, which the palette buds beside the bar.
    static func menuDescriptor(_ tool: String, menus: PresetMenus) -> ToolMenuDescriptor {
        var menu = ToolMenuDescriptor(tool: tool, owner: id) { session in
            guard let model = menus.model(tool, session: session) else { return AnyView(EmptyView()) }
            // Keyed by tool: the palette shows one menu at a time in the same place, and each tool has its own state.
            return AnyView(ToolPresetMenu(model: model).id(tool))
        }
        menu.makePopover = { session in menus.model(tool, session: session)?.makePopover() }
        return menu
    }

    /// `[` and `]` step through the active tool's thickness slots; 1–9 and 0 pick its first ten colours (DESIGN.md §12).
    /// Canvas keys in notebooks and whiteboards only (contracts-v2.2 routing): never while text is edited, and never in
    /// study sets or text documents, whose own plain keys they would take.
    static func registerShortcuts(_ app: NibApp) {
        func shortcut(_ keyID: String, _ title: String, _ key: String, _ params: JSONValue, order: Int) {
            var descriptor = KeyCommandDescriptor(id: keyID, title: title, shortcut: KeyShortcut(key), command: "preset.select",
                                                  params: params, scope: .canvas, order: order, owner: id)
            descriptor.docKinds = canvasKinds
            app.content.keyCommands.register(descriptor)
        }
        shortcut("presets.width.previous", String(localized: "Thinner Preset"), "[", ["tool": "current", "widthStep": -1], order: 0)
        shortcut("presets.width.next", String(localized: "Thicker Preset"), "]", ["tool": "current", "widthStep": 1], order: 1)
        for slot in 0..<10 {
            shortcut("presets.swatch.\(slot + 1)", String(localized: "Colour Preset \(slot + 1)"), slot == 9 ? "0" : String(slot + 1),
                     ["tool": "current", "swatch": .number(Double(slot))], order: 2 + slot)
        }
    }
}
