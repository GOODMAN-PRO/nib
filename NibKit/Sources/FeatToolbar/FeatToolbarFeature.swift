import SwiftUI
import Combine
import NibContracts

/// F016 Toolbar & tool switching: the document's tool palette (`ui.screens.toolbar`), tool switching (sticky and
/// non-sticky tools, last tool per document kind), single-key tool shortcuts, the active tool's options bar, toolbar
/// hiding, and the customisation sheet with saved layouts.
public enum FeatToolbarFeature: NibFeature {
    public static let id = "toolbar"

    public static func register(_ app: NibApp) {
        let runtime = ToolbarRuntime(app: app)
        app.services.set(runtime, for: ToolbarRuntime.serviceKey)
        ToolbarCommands.register(app.commands)
        ToolbarSettings.declare(app.settings, owner: id)

        app.ui.screens.toolbar = { session, app in ToolbarHostView(app: app, session: session) }

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

/// App-wide toolbar state, shared by the commands and every window's palette (a service, `serviceKey`).
@MainActor
final class ToolbarRuntime: ObservableObject {
    static let serviceKey = "toolbar.runtime"

    private(set) weak var app: NibApp?
    /// Windows whose palette is hidden (`toolbar.setVisible`). Window state: never persisted.
    @Published private(set) var hiddenSessions: Set<NibID> = []
    private var stickiness: [String: Bool] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(app: NibApp) {
        self.app = app
        NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: app.ui.canvasTools)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stickiness.removeAll() }
            .store(in: &cancellables)
    }

    func isVisible(_ session: EditorSession) -> Bool { !hiddenSessions.contains(session.id) }

    func setVisible(_ visible: Bool, session: EditorSession) {
        if visible {
            hiddenSessions.remove(session.id)
        } else {
            hiddenSessions.insert(session.id)
        }
    }

    /// `CanvasTool.isSticky` of a registered tool (unknown tools count as sticky). Cached per tool id until the tool
    /// registry changes.
    func isSticky(_ tool: String) -> Bool {
        if let known = stickiness[tool] { return known }
        guard let make = app?.ui.canvasTools.get(tool)?.make else { return true }
        let sticky = make().isSticky
        stickiness[tool] = sticky
        return sticky
    }

    func entries(for kind: DocumentKind?) -> [ToolbarEntry] {
        guard let app else { return [] }
        return ToolbarLayoutEngine.entries(in: app, kind: kind)
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
enum ToolbarShortcuts {
    static let prefix = "toolbar.key."

    /// W shows or hides the writing tools.
    static var writingTools: KeyCommandDescriptor {
        KeyCommandDescriptor(id: prefix + "writingTools", title: String(localized: "Show or Hide Tools"),
                             shortcut: KeyShortcut("w"), command: "toolbar.setVisible", params: [:], scope: .canvas,
                             order: 0, owner: FeatToolbarFeature.id)
    }

    static func normalized(_ s: KeyShortcut) -> KeyShortcut {
        KeyShortcut(s.key.count == 1 ? s.key.lowercased() : s.key, s.modifiers)
    }

    /// W, then one command per item shortcut in registry order: `tool.select` for tools, the item's command
    /// otherwise. The first item to claim a key keeps it; keys in `taken` are skipped.
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
            out.append(KeyCommandDescriptor(id: prefix + d.id, title: d.title, shortcut: shortcut, command: command,
                                            params: params, scope: .canvas, order: out.count, owner: owner))
        }
        return out
    }
}
