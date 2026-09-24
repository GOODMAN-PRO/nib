import SwiftUI
import NibContracts
import NibDesign

/// F009 Highlighter tool: the "highlighter" canvas tool (key H, PKInk.marker, presets "highlighter") in the writing
/// tools group, its settings popover, and the stroke processors "highlighter.stabilize" and "highlighter.straight".
/// It registers no commands of its own: the tool is chosen with `tool.select`, its settings change through
/// `settings.set` (`highlighter.straightLine`, `highlighter.stabilization`, `highlighter.drawAndHold`), colour and
/// thickness through `preset.*`, and Draw and Hold runs `shape.recognize` / `shape.create`. The renderer draws the
/// captured strokes beneath ink (its multiply band).
public enum FeatHighlighterFeature: NibFeature {
    public static let id = "highlighter"

    public static func register(_ app: NibApp) {
        HighlighterSettings.declare(in: app.settings, owner: id)
        let title = String(localized: "Highlighter")
        app.ui.canvasTools.register(CanvasToolDescriptor(id: HighlighterSettings.toolID, title: title, order: 20, owner: id,
                                                         make: { HighlighterTool() }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: HighlighterSettings.toolID, title: title, icon: NibSymbol.highlighter.name, group: .tools, order: 20,
            owner: id, toolID: HighlighterSettings.toolID, shortcut: KeyShortcut("h"),
            settings: { [weak app] session in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(HighlighterSettingsView(app: app, session: session))
            }))
        app.content.strokeProcessors.register(StrokeProcessorEntry(
            id: HighlighterStabilizer.id, order: HighlighterStabilizer.order, owner: id,
            processor: HighlighterStabilizer(settings: app.settings)))
        app.content.strokeProcessors.register(StrokeProcessorEntry(
            id: StraightLineProcessor.id, order: StraightLineProcessor.order, owner: id,
            processor: StraightLineProcessor(settings: app.settings)))
    }
}
