import SwiftUI
import WebKit
import NibContracts
import NibDesign

/// Plugin HTML panels (F081, docs/PLUGIN_API.md §5.5, DESIGN.md §14.10). Provides `PluginPanelFactory` under
/// `ServiceKeys.pluginPanels`; the plugin host (F078) maps each `contributes.panels` entry to a `PanelDescriptor`
/// (with `providesHeader`) whose view comes from here: a WKWebView per panel served from `nib-plugin://<id>/…` by a
/// scheme handler confined to the plugin folder, under a content rule list that blocks every load except the plugin's
/// own files and, with the granted "network" permission, its declared hosts; `window.nib` injected with the same API
/// as main.js, routed to the command bus as `.plugin(id)`; main.js ↔ panel messages through
/// `PluginRuntimeHandle.postMessage` and `plugin.message` events.
///
/// It registers no commands of its own: the panel chrome's actions run `panel.close`, `plugin.reload`,
/// `settings.open`, `link.follow` and `diagnostics.export`, and everything a panel's page does is a bus call.
public enum FeatPluginPanelsFeature: NibFeature {
    public static let id = "pluginpanels"

    public static func register(_ app: NibApp) {
        app.services.set(PluginPanelFactoryService(app: app), for: ServiceKeys.pluginPanels)
    }

    public static func start(_ app: NibApp) async {
        app.services.get(ServiceKeys.pluginPanels, as: PluginPanelFactoryService.self)?.startListening()
    }
}

// MARK: - Mailbox (pure, tested)

/// Messages main.js posts to a panel that is not showing yet: `await nib.ui.openPanel(id)` resolves before the chrome
/// has built the panel, and `nib.ui.postToPanel` usually follows at once. They wait here (per plugin and panel, at most
/// `capacity`, for `lifetime` seconds) until the panel attaches.
struct PanelMailbox {
    struct Letter: Equatable {
        var message: JSONValue
        var at: Date
    }

    var capacity = 64
    var lifetime: TimeInterval = 30
    private(set) var letters: [String: [Letter]] = [:]

    static func key(plugin: String, panel: String) -> String { plugin + "\n" + panel }

    mutating func post(_ message: JSONValue, plugin: String, panel: String, at date: Date) {
        // Forget panels whose every letter expired.
        letters = letters.filter { _, list in list.contains { date.timeIntervalSince($0.at) <= lifetime } }
        let k = PanelMailbox.key(plugin: plugin, panel: panel)
        var list = (letters[k] ?? []).filter { date.timeIntervalSince($0.at) <= lifetime }
        list.append(Letter(message: message, at: date))
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        letters[k] = list
    }

    /// The letters for a panel that are still fresh, oldest first; the box is then empty.
    mutating func drain(plugin: String, panel: String, now: Date) -> [JSONValue] {
        let list = letters.removeValue(forKey: PanelMailbox.key(plugin: plugin, panel: panel)) ?? []
        return list.filter { now.timeIntervalSince($0.at) <= lifetime }.map { $0.message }
    }

    func count(plugin: String, panel: String) -> Int {
        letters[PanelMailbox.key(plugin: plugin, panel: panel)]?.count ?? 0
    }
}

// MARK: - The factory

/// `PluginPanelFactory`: builds panels, routes main.js's `plugin.message` posts to the open copies of their panel (or
/// the mailbox), and keeps one private, non-persistent website data store per plugin (panels of one plugin share
/// `localStorage` for the session; plugins never share cookies; `nib.storage` is the persistent store).
@MainActor
final class PluginPanelFactoryService: PluginPanelFactory {
    private weak var app: NibApp?
    let ruleLists = PanelRuleListCache()
    private(set) var mailbox = PanelMailbox()
    private var sinks: [String: [WeakSink]] = [:]
    private var listening = false
    private let bag = PanelSubscriptionBag()
    private var stores: [String: WKWebsiteDataStore] = [:]
    /// Mailbox time (tests replace it).
    var now: () -> Date = { Date() }

    init(app: NibApp) {
        self.app = app
    }

    func makePanel(manifest: PluginManifest, folder: URL, entry: String, context: PanelContext) -> AnyView {
        let panelID = PanelIdentity.panelID(manifest: manifest, entry: entry, openPanels: context.session?.openPanels ?? [])
        let placement = manifest.contributes?.panels?.first { $0.id == panelID }?.placement
        let floating = PanelIdentity.usesFloatingChrome(presentation: context.presentation, placement: placement)
        let app = context.app
        return AnyView(PluginPanelView(floating: floating) { [weak self] in
            PluginWebPanel(app: app, factory: self, manifest: manifest, panelID: panelID, folder: folder, entry: entry,
                           context: context)
        })
    }

    /// Starts routing `plugin.message` events (from `start`, never from `register`), and drops the compiled rule
    /// lists earlier sessions left in WebKit's store (uninstalled plugins, changed hosts).
    func startListening() {
        guard !listening, let app = app else { return }
        listening = true
        if !NibApp.isHostlessTest { ruleLists.sweepUnused() }
        bag.add(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.pluginMessage else { return }
            PanelMainThread.run { self?.route(event) }
        })
    }

    /// A `plugin.message` addressed to a panel (`{panel, to: "panel", message}` from `plugin:<id>`) reaches every open
    /// copy of that plugin's panel, or waits in the mailbox. Messages for main.js are the runtime's.
    func route(_ event: NibEvent) {
        guard event.type == NibEventType.pluginMessage, case .plugin(let pluginID)? = event.principal,
              let payload = event.payload, payload["to"]?.stringValue == "panel",
              let panel = payload["panel"]?.stringValue, !panel.isEmpty else { return }
        let message = payload["message"] ?? .null
        let live = liveSinks(plugin: pluginID, panel: panel)
        if live.isEmpty {
            mailbox.post(message, plugin: pluginID, panel: panel, at: now())
        } else {
            for sink in live { sink.deliverMessage(message) }
        }
    }

    /// A panel is showing: it gets what waited for it, then every later message.
    func attach(_ sink: PanelMessageSink) {
        let key = PanelMailbox.key(plugin: sink.pluginID, panel: sink.panelID)
        var list = (sinks[key] ?? []).filter { $0.value != nil && $0.value !== sink }
        list.append(WeakSink(sink))
        sinks[key] = list
        for message in mailbox.drain(plugin: sink.pluginID, panel: sink.panelID, now: now()) {
            sink.deliverMessage(message)
        }
    }

    func liveSinks(plugin: String, panel: String) -> [PanelMessageSink] {
        let key = PanelMailbox.key(plugin: plugin, panel: panel)
        let live = (sinks[key] ?? []).compactMap { $0.value }
        sinks[key] = live.isEmpty ? nil : live.map { WeakSink($0) }
        return live
    }

    /// The plugin's private web data store (created on first use; never in hostless tests).
    func dataStore(for pluginID: String) -> WKWebsiteDataStore {
        if let store = stores[pluginID] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[pluginID] = store
        return store
    }
}

private final class WeakSink {
    weak var value: PanelMessageSink?
    init(_ value: PanelMessageSink) { self.value = value }
}
