import Foundation
import NibContracts

// The host's own commands (ARCHITECTURE.md §6.5 `plugin.*`, owner F078): list, enable, reload, logs, sdkTypes, docs.
// Installing, uninstalling and reviewing plugins belong to the installer (F079).

/// The device-local on/off switch of each plugin: the setting "pluginhost.disabled.<id>" (true = switched off; absent
/// = on). Written only by `plugin.enable` (through `PluginHost.setEnabled`).
enum PluginEnablement {
    static let prefix = "pluginhost.disabled."

    static func isEnabled(_ id: String, settings: SettingsStore) -> Bool {
        settings.json(prefix + id)?.boolValue != true
    }

    static func set(_ id: String, enabled: Bool, settings: SettingsStore) {
        settings.setJSON(prefix + id, enabled ? nil : .bool(true))
    }
}

@MainActor
enum PluginCommands {
    static func register(_ app: NibApp) {
        app.commands.register(PluginListCommand.self)
        app.commands.register(PluginEnableCommand.self)
        app.commands.register(PluginReloadCommand.self)
        app.commands.register(PluginLogsCommand.self)
        app.commands.register(PluginSDKTypesCommand.self)
        app.commands.register(PluginDocsCommand.self)
    }

    static func host(_ ctx: CommandContext) throws -> PluginHost {
        guard let host = ctx.services.get(ServiceKeys.pluginHost, as: PluginHost.self) else {
            throw NibError.unavailable("the plugin host")
        }
        return host
    }

    /// Plugins never manage plugins (plugin.enable carries plugins:manage, which is never granted to them; reloading is
    /// refused here, so a plugin cannot restart itself or another plugin mid-call).
    static func refusePlugins(_ ctx: CommandContext, _ what: String) throws {
        if case .plugin = ctx.principal {
            throw NibError(.permissionDenied, "plugins cannot \(what) plugins", hint: "ask the user to do it in Settings › Plugins")
        }
    }

    static let idSchema = JSONSchema.str("plugin id (reverse-DNS), e.g. dev.nib.hello")
}

// MARK: - plugin.list

struct PluginListCommand: NibCommand {
    struct Params: Codable {}

    struct Entry: Codable, Equatable {
        var id: String
        var name: String
        var version: String
        var author: String?
        var description: String?
        /// running | disabled | needsReview | failed | safeMode | stopped.
        var state: String
        var enabled: Bool
        var needsReview: Bool
        var error: String?
        /// Declared in the manifest.
        var permissions: [String]
        /// Held right now (declared, consented to on this device, and bound to the installed folder).
        var granted: [String]
        var networkHosts: [String]
        var sha256: String
        var source: String?
        var commands: [String]
    }

    struct Output: Codable {
        var plugins: [Entry]
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.pluginList, title: "List Plugins",
        summary: "Installed plugins with version, declared and granted permissions, state (running, disabled, needsReview, failed) and command ids.",
        examples: [[:]], effect: .read, target: .app)

    static func run(_ params: Params, _ ctx: CommandContext) async throws -> Output {
        let host = try PluginCommands.host(ctx)
        // A read: re-reads the plugins folder but never stops or restarts a plugin (a changed running one is left to
        // the scheduled rescan).
        await host.refreshForListing()
        let entries = host.records.values.sorted { $0.id < $1.id }.map { r -> Entry in
            let m = r.manifest
            return Entry(id: r.id, name: m?.name ?? r.id, version: m?.version ?? "", author: m?.author,
                         description: m?.description, state: r.state.rawValue, enabled: host.isEnabled(r.id),
                         needsReview: r.state == .needsReview, error: r.error, permissions: m?.permissions ?? [],
                         granted: host.grantedScopes(r.id).map { $0.rawValue }.sorted(),
                         networkHosts: m?.network?.hosts ?? [], sha256: r.sha256, source: r.source,
                         commands: (m?.contributes?.commands ?? []).map { $0.id })
        }
        return Output(plugins: entries)
    }
}

// MARK: - plugin.enable

struct PluginEnableCommand: NibCommand {
    struct Params: Codable {
        var id: String
        var enabled: Bool
    }

    struct Output: Codable {
        var id: String
        var enabled: Bool
        var state: String
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.pluginEnable, title: "Enable Plugin",
        summary: "Turn an installed plugin on or off on this device (needs plugins:manage; the user always confirms for the AI and the bridge).",
        params: .obj(["id": PluginCommands.idSchema, "enabled": .bool("true = run it, false = switch it off")],
                     required: ["id", "enabled"]),
        examples: [["id": "dev.nib.hello", "enabled": true]], effect: .session, target: .app, extraScopes: [.pluginsManage])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try PluginCommands.refusePlugins(ctx, "enable or disable")
        let host = try PluginCommands.host(ctx)
        try await host.setEnabled(p.id, p.enabled)
        return Output(id: p.id, enabled: host.isEnabled(p.id), state: host.state(p.id)?.rawValue ?? PluginState.stopped.rawValue)
    }
}

// MARK: - plugin.reload

struct PluginReloadCommand: NibCommand {
    struct Params: Codable {
        var id: String
    }

    struct Output: Codable {
        var id: String
        var state: String
        var version: String?
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.pluginReload, title: "Reload Plugin",
        summary: "Reload a plugin from its folder after its files changed: re-read the manifest, re-check its approval, restart it.",
        params: .obj(["id": PluginCommands.idSchema], required: ["id"]),
        examples: [["id": "dev.nib.hello"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try PluginCommands.refusePlugins(ctx, "reload")
        let host = try PluginCommands.host(ctx)
        try await host.load(p.id)
        return Output(id: p.id, state: host.state(p.id)?.rawValue ?? PluginState.stopped.rawValue,
                      version: host.records[p.id]?.manifest?.version)
    }
}

// MARK: - plugin.logs

struct PluginLogsCommand: NibCommand {
    struct Params: Codable {
        var id: String
        var limit: Int?
    }

    struct Output: Codable {
        var id: String
        var running: Bool
        /// Oldest first.
        var lines: [String]
        /// Older lines were left out to keep the result small (ask for fewer).
        var truncated: Bool
    }

    static let defaultLimit = 200
    static let maxLimit = 1_000
    /// Keeps the result under the 20 KB read budget.
    static let maxBytes = 18_000

    static let descriptor = CommandDescriptor(
        id: CommandIDs.pluginLogs, title: "Plugin Logs",
        summary: "Recent console output (console.log/warn/error) of a plugin, newest last; a plugin can read only its own logs.",
        params: .obj(["id": PluginCommands.idSchema, "limit": .int("lines, newest kept (default 200)", min: 1, max: maxLimit)],
                     required: ["id"]),
        examples: [["id": "dev.nib.hello", "limit": 50]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if case let .plugin(caller) = ctx.principal, caller != p.id {
            throw NibError(.permissionDenied, "a plugin can read only its own logs", path: "$.id")
        }
        let host = try PluginCommands.host(ctx)
        guard host.records[p.id] != nil || host.handle(p.id) != nil else {
            throw NibError(.notFound, "plugin \(p.id) is not installed", hint: "call plugin.list to see installed plugins")
        }
        let limit = max(1, min(p.limit ?? defaultLimit, maxLimit))
        let (lines, truncated) = recent(host.logs(p.id), limit: limit, maxBytes: maxBytes)
        return Output(id: p.id, running: host.handle(p.id) != nil, lines: lines, truncated: truncated)
    }

    /// The newest `limit` lines that fit in `maxBytes`, oldest first.
    static func recent(_ all: [String], limit: Int, maxBytes: Int) -> ([String], Bool) {
        var out: [String] = []
        var bytes = 0
        for line in all.reversed() {
            guard out.count < limit else { return (out.reversed(), true) }
            let size = line.utf8.count + 4
            guard bytes + size <= maxBytes else { return (out.reversed(), true) }
            bytes += size
            out.append(line)
        }
        return (out.reversed(), false)
    }
}

// MARK: - plugin.sdkTypes

struct PluginSDKTypesCommand: NibCommand {
    struct Params: Codable {
        var cursor: String?
    }

    struct Output: Codable {
        var text: String
        var truncated: Bool
        var cursor: String?
        var offset: Int
        var total: Int
        /// Commands described.
        var commands: Int
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.pluginSdkTypes, title: "Plugin SDK Types",
        summary: "TypeScript definitions (nib.d.ts) of the plugin API and of every command a plugin can call, from the live registry; paged with cursor.",
        params: .obj(["cursor": .str("from the previous page when it was truncated")]),
        examples: [[:]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let commands = ctx.bus.registry.all(exposedTo: .plugin)
        let page = try TextPager.page(SDKTypesGenerator.generate(commands), cursor: p.cursor)
        return Output(text: page.text, truncated: page.truncated, cursor: page.cursor, offset: page.offset,
                      total: page.total, commands: commands.count)
    }
}

// MARK: - plugin.docs

struct PluginDocsCommand: NibCommand {
    struct Params: Codable {
        var cursor: String?
    }

    struct Output: Codable {
        var format: String
        var text: String
        var truncated: Bool
        var cursor: String?
        var offset: Int
        var total: Int
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.pluginDocs, title: "Plugin Docs",
        summary: "The plugin authoring reference: manifest rules and schema, permissions, contribution points, JS API, events and limits; paged with cursor.",
        params: .obj(["cursor": .str("from the previous page when it was truncated")]),
        examples: [[:]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let page = try TextPager.page(PluginDocs.markdown(), cursor: p.cursor)
        return Output(format: "markdown", text: page.text, truncated: page.truncated, cursor: page.cursor,
                      offset: page.offset, total: page.total)
    }
}
