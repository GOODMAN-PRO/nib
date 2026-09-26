import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

/// F016 Toolbar & tool switching: the document's tool palette (`ui.screens.toolbarView`, placed by the document chrome
/// inside its one droplet container), the last tool per document kind, single-key tool shortcuts, the active tool's
/// options bar and its popover, toolbar hiding, and the customisation sheet with saved layouts. Non-sticky tools hand
/// back themselves (`CanvasHost.finishToolUse`, contracts-v2).
public enum FeatToolbarFeature: NibFeature {
    public static let id = "toolbar"

    public static func register(_ app: NibApp) {
        let runtime = ToolbarRuntime(app: app)
        app.services.set(runtime, for: ToolbarRuntime.serviceKey)
        ToolbarCommands.register(app.commands)
        ToolbarSettings.declare(app.settings, owner: id)

        // contracts-v2: a SwiftUI screen the chrome places inside its own droplet container, full window (the palette
        // docks below the bars itself), so the palette merges and recedes with the bars and needs no UIKit
        // pass-through. The superseded UIView slot (`screens.toolbar`) stays empty.
        app.ui.screens.toolbarView = { session, app in AnyView(ToolbarScreen(app: app, session: session)) }

        let customize = String(localized: "Customise Toolbar")
        app.ui.panels.register(PanelDescriptor(
            id: ToolbarCustomizationView.panelID, title: customize, icon: "slider.horizontal.3", placement: .sheet,
            order: 900, owner: id, docKinds: ToolbarLayoutEngine.paletteKinds,
            makeView: { ctx in AnyView(ToolbarCustomizationView(app: ctx.app, onDone: ctx.dismiss)) }))
        app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "toolbar.settings", title: String(localized: "Toolbar"), icon: "slider.horizontal.3", section: .editing,
            order: 200, owner: id,
            makeView: { app in AnyView(ToolbarCustomizationView(app: app, onDone: nil)) }))

        let inPaletteDocument: @MainActor (MenuContext) -> Bool = { ctx in
            guard let doc = ctx.doc ?? ctx.session?.document,
                  let kind = try? ctx.app.workspace.content(doc).meta.kind else { return false }
            return ToolbarLayoutEngine.paletteKinds.contains(kind)
        }
        app.ui.menus.register(MenuItemDescriptor(
            id: "toolbar.customize", title: customize, icon: "slider.horizontal.3", location: .documentMore,
            order: 800, owner: id, command: "panel.open",
            params: { _ in ["id": .string(ToolbarCustomizationView.panelID)] }, isVisible: inPaletteDocument))
        app.ui.menus.register(MenuItemDescriptor(
            id: "toolbar.hide", title: String(localized: "Hide Tools"), icon: "eye.slash", location: .documentMore,
            order: 810, owner: id, command: "toolbar.setVisible", params: { _ in ["visible": false] },
            isVisible: { [weak runtime] ctx in
                inPaletteDocument(ctx) && (ctx.session.map { runtime?.isVisible($0) ?? true } ?? false)
            }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "toolbar.show", title: String(localized: "Show Tools"), icon: "eye", location: .documentMore,
            order: 810, owner: id, command: "toolbar.setVisible", params: { _ in ["visible": true] },
            isVisible: { [weak runtime] ctx in
                inPaletteDocument(ctx) && (ctx.session.map { !(runtime?.isVisible($0) ?? true) } ?? false)
            }))

        // The tools' own keys come from their toolbar items, which are registered by other features and plugins
        // (possibly later): `start` and every toolbar registry change sync them.
        app.content.keyCommands.register(ToolbarShortcuts.writingTools)
    }

    public static func start(_ app: NibApp) async {
        app.services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self)?.start()
    }
}

/// What `toolbar.dock` needs to know about one window, reported by its palette: the size class (compact widths dock
/// at the top or bottom only), the size (the default dock follows the orientation) and the window's UndoManager.
struct ToolbarWindowState {
    var compact: Bool
    var size: CGSize
    weak var undoManager: UndoManager? = nil
}

/// Per-window toolbar state, shared by the commands and every window's palette (a service, `serviceKey`): which
/// palettes are hidden, each window's size class and UndoManager, and the Undo/Redo replays of `toolbar.dock`.
/// Commands read the registries through `CommandContext.app` (contracts-v2); the app kept here serves the runtime's
/// own jobs only (tool keys, dock replays).
@MainActor
final class ToolbarRuntime: ObservableObject {
    static let serviceKey = "toolbar.runtime"

    private weak var app: NibApp?
    /// Windows whose palette is hidden (`toolbar.setVisible`). Window state: never persisted.
    @Published private(set) var hiddenSessions: Set<NibID> = []
    private var windows: [NibID: ToolbarWindowState] = [:]
    /// Docks an Undo or Redo is replaying through `toolbar.dock`, per window: that run registers no undo of its own.
    private var replays: [NibID: ToolbarDockSetting] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(app: NibApp) {
        self.app = app
    }

    // MARK: Windows and docks

    func windowDidChange(_ session: EditorSession, size: CGSize, compact: Bool) {
        var state = windows[session.id] ?? ToolbarWindowState(compact: compact, size: size)
        state.compact = compact
        state.size = size
        windows[session.id] = state
    }

    /// The palette's window: its UndoManager takes the "Move Palette" steps. nil detaches it and drops those steps.
    func setUndoManager(_ manager: UndoManager?, for session: EditorSession) {
        var state = windows[session.id] ?? ToolbarWindowState(compact: Self.deviceIsCompact, size: .zero)
        if let old = state.undoManager, old !== manager { old.removeAllActions(withTarget: self) }
        state.undoManager = manager
        windows[session.id] = state
    }

    /// Before a window reports its size class, the device decides: iPhone is compact.
    private static var deviceIsCompact: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    func isCompact(_ session: EditorSession?) -> Bool {
        session.flatMap { windows[$0.id]?.compact } ?? Self.deviceIsCompact
    }

    /// Where the palette of `session`'s window docks now, from the stored setting (never a drag in flight).
    func currentDock(_ session: EditorSession?, settings: SettingsStore) -> NibPaletteDock {
        let compact = isCompact(session)
        let size = session.flatMap { windows[$0.id]?.size } ?? .zero
        let fallback = size == .zero ? NibPaletteDock(edge: compact ? .bottom : .leading)
                                     : ToolbarDockRules.defaultDock(size: size, compact: compact)
        return ToolbarDockRules.effective(saved: ToolbarStore.dock(settings), defaultDock: fallback, compact: compact)
    }

    /// Registers the step back from `next` to `previous` on the window's UndoManager, named "Move Palette".
    func registerUndo(from previous: NibPaletteDock, to next: NibPaletteDock, session: EditorSession?) {
        guard previous != next, let session, let manager = windows[session.id]?.undoManager else { return }
        register(on: manager, restoring: previous, from: next, session: session)
    }

    /// Undoing the step registers the opposite step at once (on the redo stack while undoing, on the undo stack while
    /// redoing), then moves the palette through `toolbar.dock`, so an undo is observable and persisted like any move.
    /// Without a run loop grouping by event (a test's manager) the step gets a group of its own.
    private func register(on manager: UndoManager, restoring target: NibPaletteDock, from current: NibPaletteDock,
                          session: EditorSession) {
        let ownGroup = !manager.groupsByEvent && manager.groupingLevel == 0
        if ownGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { [weak session, weak manager] runtime in
            MainActor.assumeIsolated {
                guard let session else { return }
                runtime.replay(target, from: current, session: session, manager: manager)
            }
        }
        manager.setActionName(String(localized: "Move Palette"))
        if ownGroup { manager.endUndoGrouping() }
    }

    private func replay(_ target: NibPaletteDock, from current: NibPaletteDock, session: EditorSession,
                        manager: UndoManager?) {
        if let manager { register(on: manager, restoring: current, from: target, session: session) }
        replays[session.id] = ToolbarDockSetting(target)
        app?.perform(ToolbarDock.descriptor.id, ToolbarDock.Position(target).params, session: session)
    }

    /// True (once) when this `toolbar.dock` call is the replay an Undo or Redo started.
    func takeReplay(_ session: EditorSession?, edge: NibDock, along: Double?) -> Bool {
        guard let session, let pending = replays[session.id], pending.edge == edge.commandValue, let along,
              abs(along - pending.along) < 1e-9 else { return false }
        replays[session.id] = nil
        return true
    }

    func isVisible(_ session: EditorSession) -> Bool { !hiddenSessions.contains(session.id) }

    func setVisible(_ visible: Bool, session: EditorSession) {
        if visible {
            hiddenSessions.remove(session.id)
        } else {
            hiddenSessions.insert(session.id)
        }
    }

    func start() {
        guard !started, let app else { return }
        started = true
        syncKeyCommands()
        NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: app.ui.toolbar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncKeyCommands() }
            .store(in: &cancellables)
    }

    /// Registers a canvas-scope key command for every palette item's shortcut (T-085, P-054; the shell runs them only
    /// while no text is being edited, and F073's setting can turn them off), plus W, and drops the ones whose item
    /// went away. A key another owner already uses is left to that owner.
    func syncKeyCommands() {
        guard let app else { return }
        let registry = app.content.keyCommands
        let owner = FeatToolbarFeature.id
        let taken = Set(registry.all.filter { $0.owner != owner && $0.scope != .library }
            .map { ToolbarShortcuts.normalized($0.shortcut) })
        let items = app.ui.toolbar.all.filter { ToolbarLayoutEngine.paletteGroups.contains($0.group) }
        let wanted = ToolbarShortcuts.commands(for: items, taken: taken, owner: owner)
        let wantedIDs = Set(wanted.map { $0.id })
        for stale in registry.all where stale.owner == owner && !wantedIDs.contains(stale.id) {
            registry.unregister(id: stale.id)
        }
        for d in wanted { registry.register(d) }
    }
}

/// Single-key tool shortcuts (KeyScope.canvas).
@MainActor
enum ToolbarShortcuts {
    static let prefix = "toolbar.key."

    /// W shows or hides the writing tools, in the documents that have a palette.
    static var writingTools: KeyCommandDescriptor {
        var key = KeyCommandDescriptor(id: prefix + "writingTools", title: String(localized: "Show or Hide Tools"),
                                       shortcut: KeyShortcut("w"), command: "toolbar.setVisible", params: [:],
                                       scope: .canvas, order: 0, owner: FeatToolbarFeature.id)
        key.docKinds = ToolbarLayoutEngine.paletteKinds
        return key
    }

    static func normalized(_ s: KeyShortcut) -> KeyShortcut {
        KeyShortcut(s.key.count == 1 ? s.key.lowercased() : s.key, s.modifiers)
    }

    /// W, then one command per item shortcut in registry order: `tool.select` for tools, the item's command
    /// otherwise. The first item to claim a key keeps it; keys in `taken` are skipped. Each key works only in the
    /// document kinds its item shows in, and a command item's `sessionParams` go with its key (contracts-v2: the shell
    /// passes `resolvedParams(for:)`).
    static func commands(for items: [ToolbarItemDescriptor], taken: Set<KeyShortcut>, owner: String) -> [KeyCommandDescriptor] {
        var used = taken
        var out: [KeyCommandDescriptor] = []
        if used.insert(normalized(writingTools.shortcut)).inserted { out.append(writingTools) }
        for d in items {
            guard let shortcut = d.shortcut else { continue }
            let command: String
            let params: JSONValue
            if let tool = d.toolID {
                command = CommandIDs.toolSelect
                params = ["tool": .string(tool)]
            } else if let c = d.command {
                command = c
                params = d.params
            } else {
                continue
            }
            guard used.insert(normalized(shortcut)).inserted else { continue }
            var key = KeyCommandDescriptor(id: prefix + d.id, title: d.title, shortcut: shortcut, command: command,
                                           params: params, scope: .canvas, order: out.count, owner: owner)
            key.docKinds = d.docKinds
            if d.toolID == nil { key.sessionParams = d.sessionParams }
            out.append(key)
        }
        return out
    }
}
