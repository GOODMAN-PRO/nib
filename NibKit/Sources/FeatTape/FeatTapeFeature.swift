import SwiftUI
import NibContracts
import NibDesign

/// Tape (F033): the "tape" canvas tool (key A), the "stroke.tape" drawer, tap-to-reveal (`tape.tapAt`, order 100,
/// also in read-only mode), 12 generated recolourable patterns, custom pattern images, content-pack patterns and the
/// synced pattern history. Tape is a stroke with `tool == .tape`; hiding and revealing it is persisted but not
/// undoable.
public enum FeatTapeFeature: NibFeature {
    public static let id = TapeCommands.owner

    public static func register(_ app: NibApp) {
        TapeCommands.register(app)
        app.settings.declare(TapeSettings.straight,
                             summary: "Tape is drawn as straight strips (first to last point, snapped level or plumb within 4°).",
                             owner: id, schema: .bool())
        app.settings.declare(TapeSettings.followsDirection,
                             summary: "Tape patterns turn with the stroke instead of staying level with the page.",
                             owner: id, schema: .bool())
        app.services.set(TapeStore(app: app), for: TapeStore.serviceKey)
        for (order, pattern) in TapePattern.allCases.enumerated() {
            app.content.tapePatterns.register(pattern.descriptor(order: order, owner: id))
        }
        app.content.drawers.register(ItemDrawerEntry(key: "stroke.tape", owner: id, drawer: TapeDrawer()))
        app.content.tapHandlers.register(TapHandlerDescriptor(id: "tape.tapAt", owner: id, gesture: .tap,
                                                              command: "tape.tapAt", order: 100, worksInReadOnly: true))
        app.ui.canvasTools.register(CanvasToolDescriptor(id: "tape", title: String(localized: "Tape"), order: 700, owner: id) {
            TapeTool()
        })
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "tape", title: String(localized: "Tape"), icon: NibSymbol.tape.name, group: .tools, order: 700, owner: id,
            toolID: "tape", shortcut: KeyShortcut("a"),
            settings: { [weak app] session in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(TapeSettingsView(app: app, session: session))
            }))
    }

    /// Loads custom patterns and the history, and reloads them whenever the library changes (another folder, sync).
    public static func start(_ app: NibApp) async {
        guard let store = app.services.get(TapeStore.serviceKey, as: TapeStore.self) else { return }
        store.reload()
        store.librarySubscription = app.events.subscribe { [weak store] event in
            guard event.type == NibEventType.libraryChanged, let store else { return }
            Task { @MainActor in store.scheduleReload() }
        }
    }
}

/// The tape tool's own settings (synced: they follow the library, like the tape presets).
enum TapeSettings {
    static let straight = SettingKey("tape.straight", default: false, synced: true)
    static let followsDirection = SettingKey("tape.followsDirection", default: false, synced: true)
}
