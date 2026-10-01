import Foundation
import NibContracts

/// Plugin host (F078, docs/PLUGIN_API.md): `PluginHosting` under `ServiceKeys.pluginHost`. It loads the plugins in
/// the library's plugins folder whose device-local grant matches the folder hash (others are "needs review"),
/// validates their manifests, answers `Gateway.grants` for `.plugin(id)`, and maps every contribution into the
/// registries native features use, owned by the plugin id, so unloading is `unregister(owner:)` everywhere.
/// Commands: plugin.list, plugin.enable, plugin.reload, plugin.logs, plugin.sdkTypes, plugin.docs.
public enum NibPluginHostFeature: NibFeature {
    public static let id = "pluginhost"

    public static func register(_ app: NibApp) {
        let host = PluginHost(app: app)
        app.services.set(host, for: ServiceKeys.pluginHost)
        host.installGrants(on: app.gateway)
        PluginCommands.register(app)
        // Read-only for settings.set (every principal): plugin.enable, which needs plugins:manage and a confirmation
        // for the AI and the bridge, is the only writer (PluginEnablement.set writes the store directly).
        app.settings.declarePrefix(PluginEnablement.prefix, synced: false,
                                   summary: "Plugins switched off on this device (true = off); change with plugin.enable.",
                                   owner: id, schema: .bool(), readOnly: true)
    }

    /// Loads the approved plugins and keeps watching the library for plugins that arrive, change or leave.
    public static func start(_ app: NibApp) async {
        await app.services.get(ServiceKeys.pluginHost, as: PluginHost.self)?.start()
    }
}
