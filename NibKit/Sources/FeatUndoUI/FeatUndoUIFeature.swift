import SwiftUI
import NibContracts
import NibDesign

/// Undo/redo UI (F015): toolbar buttons, ⌘Z / ⇧⌘Z, two- and three-finger double-tap on the canvas, and the History
/// sidebar tab with selective revert. It owns no commands: every action runs a contract command (`edit.undo`,
/// `edit.redo`, `history.list`, `history.revertGroup`, `settings.set`), so plugins, the AI and the bridge can do
/// exactly what the buttons do.
public enum FeatUndoUIFeature: NibFeature {
    public static let id = "undo"

    public static func register(_ app: NibApp) {
        app.settings.declare(UndoSettings.gestures,
                             summary: "Two-finger double-tap undoes and three-finger double-tap redoes on the canvas.",
                             owner: id, schema: .bool())
        // Defaults until `start` knows the document, the step labels and the side (register never reads settings).
        UndoButtons.install(UndoChromeState(), in: app)
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "undo.gestures", owner: id, order: 900) { host in
            UndoGestureAttachment(host: host)
        })
        app.ui.panels.register(PanelDescriptor(
            id: "undo.history", title: String(localized: "History"), icon: NibSymbol.recents.name,
            placement: .sidebarTab, order: 900, owner: id) { ctx in
                AnyView(HistoryPanel(app: ctx.app, session: ctx.session ?? ctx.app.services.sessions.active))
            })
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "undo.settings", title: String(localized: "Undo and Redo"), icon: NibSymbol.undo.name,
            section: .editing, order: 200, owner: id) { app in
                AnyView(UndoSettingsView(app: app))
            })
    }

    public static func start(_ app: NibApp) async {
        UndoChrome(app: app).start()
    }
}

/// Settings owned by this feature.
enum UndoSettings {
    /// Two-finger double-tap = undo, three-finger double-tap = redo on the canvas (can be turned off, P-041).
    static let gestures = SettingKey("undo.gestures", default: true, synced: true)
}
