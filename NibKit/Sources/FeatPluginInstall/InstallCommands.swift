import Foundation
import NibContracts

// plugin.install, plugin.uninstall, plugin.review (ARCHITECTURE.md §6.5 `plugin.*`, owner F079) and the "nibplugin"
// importer. All three carry plugins:manage: the AI and the bridge are always confirmed by the gateway, plugins are
// never allowed (their grants never hold plugins:manage), and the installer refuses them again by name.

@MainActor
enum InstallCommands {
    static func register(_ app: NibApp) {
        app.commands.register(PluginInstallCommand.self)
        app.commands.register(PluginUninstallCommand.self)
        app.commands.register(PluginReviewCommand.self)
    }

    static let importerID = "plugininstall.nibplugin"

    /// `.nibplugin` files and folders reaching `import.files` (Files, the share sheet, drag and drop, Open In) install
    /// through plugin.install as whoever imported them, so the consent sheet (and for the AI the gateway) always asks.
    static func importer(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: importerID, title: String(localized: "Nib plugins"),
                           fileExtensions: [NibFormat.pluginExtension], utTypes: [NibFormat.pluginUTType], order: 50,
                           owner: owner) { url, _, ctx in
            _ = try await ctx.execute(CommandIDs.pluginInstall, ["path": .string(url.absoluteString)])
            return []
        }
    }

    static let idSchema = JSONSchema.str("plugin id (reverse-DNS), e.g. dev.nib.hello")

    /// A minimal, valid plugin (the hello-world of docs/PLUGIN_API.md §10.1) as inline files.
    static let exampleManifest = #"{"id": "dev.nib.hello", "name": "Hello", "version": "1.0.0", "api": 1, "entry": "main.js", "permissions": ["document:write"]}"#
    static let exampleScript = #"nib.commands.register("dev.nib.hello.stamp", async () => ({ ok: true }));"#
}

// MARK: - plugin.install

struct PluginInstallCommand: NibCommand {
    struct Params: Codable {
        /// https URL (or tmp: ref) of a .nibplugin / .zip package.
        var url: String?
        /// A local .nibplugin, .zip or plugin folder (file URL, absolute path or tmp: ref).
        var path: String?
        /// Inline files {path: contents}, or with `base` the gallery entry's list of relative paths.
        var files: JSONValue?
        /// Gallery entry `base` (raw files), resolved against `index` when relative.
        var base: String?
        var index: String?
        /// The expected folder hash (the gallery's sha256).
        var sha256: String?
    }

    typealias Output = PluginInstallResult

    static let descriptor = CommandDescriptor(
        id: "plugin.install", title: "Install Plugin",
        summary: "Install or update a plugin from a URL (.nibplugin), a local path, a gallery entry (base + files) or inline files (AI authoring); always shows the consent sheet.",
        params: .obj([
            "url": .str("https URL (or tmp: ref) of a .nibplugin / .zip package"),
            "path": .str("local .nibplugin, .zip or plugin folder: a file URL, an absolute path or a tmp: ref"),
            "files": .anything("inline files {\"manifest.json\": \"…\", \"main.js\": \"…\"} (text, or {\"base64\": …} for binary files); with base: the gallery entry's list of relative paths"),
            "base": .str("gallery entry base URL of raw files (relative to index when index is given)"),
            "index": .str("URL of the gallery index that lists the plugin"),
            "sha256": .str("expected package hash (the gallery's sha256); the install fails when the files differ"),
        ]),
        examples: [
            ["files": ["manifest.json": .string(InstallCommands.exampleManifest), "main.js": .string(InstallCommands.exampleScript)]],
            ["url": "https://example.com/plugins/dev.nib.hello-1.0.0.nibplugin"],
            ["index": "https://example.com/plugins/index.json", "base": "examples/hello-world/", "files": ["manifest.json", "main.js"]],
        ],
        effect: .library, target: .library, extraScopes: [.pluginsManage])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try PluginInstaller.refusePlugins(ctx, "install")
        let source = try PluginSource.from(url: p.url, path: p.path, files: p.files, base: p.base, index: p.index, expectedHash: p.sha256)
        return try await PluginInstaller.shared(ctx.services).install(source, expectedHash: p.sha256, ctx: ctx)
    }
}

// MARK: - plugin.uninstall

struct PluginUninstallCommand: NibCommand {
    struct Params: Codable {
        var id: String
        /// Also delete the plugin's stored data (nib.storage); by default it stays for a reinstall.
        var removeData: Bool?
    }

    typealias Output = PluginUninstallResult

    static let descriptor = CommandDescriptor(
        id: "plugin.uninstall", title: "Uninstall Plugin",
        summary: "Remove a plugin from the library and its grant on this device; removeData also deletes its stored data.",
        params: .obj(["id": InstallCommands.idSchema,
                      "removeData": .bool("also delete its stored data (default false: kept for a reinstall)")],
                     required: ["id"]),
        examples: [["id": "dev.nib.hello"]],
        effect: .library, target: .library, destructive: true, extraScopes: [.pluginsManage])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try PluginInstaller.refusePlugins(ctx, "remove")
        return try await PluginInstaller.shared(ctx.services).uninstall(p.id, removeData: p.removeData ?? false, ctx: ctx)
    }
}

// MARK: - plugin.review

struct PluginReviewCommand: NibCommand {
    struct Params: Codable {
        var id: String
    }

    typealias Output = PluginReviewResult

    static let descriptor = CommandDescriptor(
        id: "plugin.review", title: "Review Plugin",
        summary: "Show the consent sheet for a plugin that arrived through sync or changed on disk, and let it run on this device once approved.",
        params: .obj(["id": InstallCommands.idSchema], required: ["id"]),
        examples: [["id": "dev.nib.hello"]],
        effect: .session, target: .app, extraScopes: [.pluginsManage], userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try PluginInstaller.refusePlugins(ctx, "approve")
        return try await PluginInstaller.shared(ctx.services).review(p.id, ctx: ctx)
    }
}
