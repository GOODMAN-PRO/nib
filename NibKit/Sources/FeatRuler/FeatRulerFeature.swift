import Foundation
import NibContracts
import NibDesign

/// F039 Ruler (T-074, T-103): an accessory (key R) that puts an opaque ruler on the page. The ruler is a
/// `CanvasAttachment` that claims its own touches: one finger drags it, two fingers rotate it (snapping to 0/45/90°
/// with a Pencil Pro alignment haptic, the angle in a Clear HUD the chrome shows), a double tap opens Set Angle, Set
/// Position, Hide Ruler and Options (Hide Digits, centimetres or inches). Its scale is drawn at the page's real size at
/// every zoom. The stroke processor "ruler.project" lays pen, pencil and highlighter strokes that start within 20 pt of
/// an edge along that edge. Everything goes through the one session command `ruler.set`; units and digits are synced
/// settings.
public enum FeatRulerFeature: NibFeature {
    public static let id = "ruler"
    /// The key command's registry id (not a command id: it runs `ruler.set`).
    static let keyCommandID = "ruler.toggle"
    /// The documents with pages the ruler lies on: its attachment, button, key and HUD exist only there.
    static let docKinds: Set<DocumentKind> = [.notebook, .whiteboard]

    public static func register(_ app: NibApp) {
        RulerSettings.declare(in: app.settings, owner: id)
        app.commands.register(RulerSet.self)

        let title = String(localized: "Ruler")
        let toggle: JSONValue = ["toggle": true]
        var button = ToolbarItemDescriptor(
            id: "ruler", title: title, icon: NibSymbol.ruler.name, group: .accessories, order: 30, owner: id,
            command: RulerSet.id, params: toggle, shortcut: KeyShortcut("r"), docKinds: docKinds)
        button.isOn = { RulerState.load($0).visible }
        app.ui.toolbar.register(button)
        // Key R works even without the toolbar feature; the toolbar leaves a key another owner registered alone.
        var key = KeyCommandDescriptor(
            id: keyCommandID, title: String(localized: "Show or Hide Ruler"), shortcut: KeyShortcut("r"),
            command: RulerSet.id, params: toggle, scope: .canvas, order: 30, owner: id)
        key.docKinds = docKinds
        app.content.keyCommands.register(key)
        app.content.strokeProcessors.register(StrokeProcessorEntry(
            id: RulerProcessor.id, order: RulerProcessor.order, owner: id, processor: RulerProcessor()))
        // After precision handles (selection, shape points), which sit on top of it and must win the touch.
        let hud = RulerHUD()
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: "ruler", owner: id, order: 500, docKinds: docKinds, make: { _ in RulerAttachment(hud: hud) }))
        app.ui.chromeOverlays.register(hud.descriptor(owner: id))
    }
}
