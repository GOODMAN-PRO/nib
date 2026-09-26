import UIKit
import Combine
import NibContracts

/// F041 Layers (T-037, T-120): five named layers per notebook or whiteboard, the active layer new content goes to,
/// visibility per device (persisted per document), moving items between layers, and exports without hidden layers.
public enum FeatLayersFeature: NibFeature {
    public static let id = "layers"

    public static func register(_ app: NibApp) {
        app.commands.register(LayerSetActive.self)
        app.commands.register(LayerSetVisible.self)
        app.commands.register(LayerRename.self)
        app.commands.register(LayerMoveItems.self)
        app.commands.register(LayerExportOptions.self)
        LayerSettings.declare(app.settings, owner: id)
        app.bus.hooks.register(CommandHookDescriptor(id: "layers.visibleLayersOnly", owner: id,
                                                     commands: LayerExportOptions.hooked,
                                                     command: LayerCommandIDs.exportOptions))
        LayersChrome.registerMenus(app, owner: id)
    }

    public static func start(_ app: NibApp) async {
        let runtime = LayersRuntime(app: app)
        app.services.set(runtime, for: LayersRuntime.serviceKey)
        runtime.start()
    }
}

/// What runs after launch: the panel and every window's layer view follow `layers.show`, each window loads its
/// document's stored layer view, the Move to Layer menu shows the active document's layer names, and editing a hidden
/// layer shows it again.
@MainActor
final class LayersRuntime {
    static let serviceKey = "layers.runtime"
    private weak var app: NibApp?
    private var subscriptions: [EventSubscription] = []
    private var settingsObserver: AnyCancellable?
    private var menuNames = LayerModel.all.map(LayerModel.defaultName)
    private weak var alert: UIAlertController?

    init(app: NibApp) {
        self.app = app
    }

    func start() {
        guard let app else { return }
        LayersChrome.sync(app, owner: FeatLayersFeature.id)
        for session in app.services.sessions.sessions { LayerView.apply(app.settings, to: session) }
        refreshMenuNames()
        subscriptions.append(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.sessionDocument else { return }
            let runtime = self
            if Thread.isMainThread { runtime?.documentChanged(event) } else { Task { @MainActor in runtime?.documentChanged(event) } }
        })
        subscriptions.append(app.bus.observeCommits { [weak self] cs in self?.didCommit(cs) })
        settingsObserver = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .sink { [weak self] note in
                guard (note.userInfo?["name"] as? String) == LayerSettings.show.name else { return }
                let runtime = self
                if Thread.isMainThread { runtime?.syncChrome() } else { Task { @MainActor in runtime?.syncChrome() } }
            }
    }

    /// `layers.show` changed: add or remove the panel and shortcuts, and apply it to every window (off shows every
    /// layer and draws on Layer 1; on restores each document's stored view).
    private func syncChrome() {
        guard let app else { return }
        LayersChrome.sync(app, owner: FeatLayersFeature.id)
        for session in app.services.sessions.sessions { LayerView.apply(app.settings, to: session) }
    }

    /// A window switched documents: load that document's hidden and active layers on this device.
    private func documentChanged(_ event: NibEvent) {
        guard let app, let raw = event.payload?["session"]?.stringValue,
              let session = app.services.sessions.session(NibID(raw)) else { return }
        LayerView.apply(app.settings, to: session)
        if session === app.services.sessions.active { refreshMenuNames() }
    }

    private func didCommit(_ cs: Changeset) {
        guard let app else { return }
        if cs.mutations.contains(where: { m in
            if case .meta = m { return true }
            return false
        }) {
            refreshMenuNames()
        }
        if case .sync = cs.principal { return }
        guard !LayerModel.passiveCommands.contains(cs.command) else { return }
        // Editing a hidden layer (drawing while it is active, an AI or plugin edit) shows it again, with an alert.
        var shown = Set<DocumentID>()
        if app.settings.get(LayerSettings.show) {
            for session in app.services.sessions.sessions {
                guard let doc = session.document else { continue }
                shown.insert(doc)
                guard !session.hiddenLayers.isEmpty else { continue }
                let revealed = LayerModel.editedLayers(cs, doc: doc).intersection(session.hiddenLayers)
                guard !revealed.isEmpty else { continue }
                for layer in revealed.sorted() {
                    LayerView.setVisible(true, layer: layer, session: session, settings: app.settings)
                }
                tellUser(revealed: revealed, doc: doc, session: session)
            }
        }
        // Documents no window shows (every document while Layers is off): update the stored view, so the new content
        // is not hidden when the document is next shown with Layers on. No alert: nothing visible changes now.
        for doc in cs.documents where !shown.contains(doc) {
            LayerView.reveal(LayerModel.editedLayers(cs, doc: doc), doc: doc, settings: app.settings)
        }
    }

    private func tellUser(revealed: Set<Int>, doc: DocumentID, session: EditorSession) {
        guard !NibApp.isHostlessTest, let app, let navigator = app.ui.activeNavigator, navigator.session === session,
              alert?.presentingViewController == nil else { return }
        let layers = LayerModel.normalized((try? app.workspace.content(doc).meta.layers) ?? [])
        let names = revealed.sorted().map { layers[$0].name }
        let title = names.count == 1 ? String(localized: "\(names[0]) is visible again")
                                     : String(localized: "Hidden layers are visible again")
        let message = String(localized: "Something changed on a layer that was hidden on this device, so it is shown again.")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        self.alert = alert
        Task { @MainActor in navigator.presentModal(alert) }
    }

    /// Object menu › Move to Layer uses the active window's layer names.
    /// ponytail: one global set of titles; per-window titles need a MenuItemDescriptor title closure (contracts).
    private func refreshMenuNames() {
        guard let app else { return }
        let doc = app.services.sessions.active?.document
        let layers = doc.flatMap { try? app.workspace.content($0).meta.layers } ?? []
        let names = LayerModel.normalized(layers).map { $0.name }
        guard names != menuNames else { return }
        menuNames = names
        LayersChrome.registerMoveMenu(app, owner: FeatLayersFeature.id, names: names)
    }
}
