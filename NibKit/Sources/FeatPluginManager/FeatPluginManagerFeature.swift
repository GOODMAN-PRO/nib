import Foundation
import SwiftUI
import UIKit
import CryptoKit
import NibContracts
import NibDesign

public enum FeatPluginManagerFeature: NibFeature {
    public static let id = "pluginmanager"
    public static func register(_ app: NibApp) {
        app.services.set(GalleryClient(), for: GalleryClient.serviceKey)
        app.services.set(ManagerGrants(), for: ManagerGrants.serviceKey)
        app.settings.declarePrefix(ManagerSettings.savedPrefix, synced: true,
            summary: "Saved gallery plugin or content pack, keyed by publisher and plugin id.", owner: id, schema: .bool())
        ManagerCommands.register(app)
        var settings = SettingsPageDescriptor(id: "pluginmanager.plugins", title: String(localized: "Plugins"),
            icon: NibSymbol.puzzle.name, section: .plugins, order: 0, owner: id) { AnyView(PluginListView(app: $0)) }
        settings.keywords = ["plugins", "gallery", "developer", "permissions", "content packs"]
        app.ui.settingsPages.register(settings)
        var gallery = PanelDescriptor(id: PanelIDs.gallery, title: String(localized: "Gallery"),
            icon: NibSymbol.gallery.name, placement: .libraryTab, order: 60, owner: id) { AnyView(GalleryView(app: $0.app)) }
        gallery.providesHeader = true
        app.ui.panels.register(gallery)
        var manager = PanelDescriptor(id: ManagerCommands.managerPanel, title: String(localized: "Plugins"),
            icon: NibSymbol.puzzle.name, placement: .sheet, order: 0, owner: id) { context in
            AnyView(PluginListView(app: context.app, close: context.dismiss))
        }
        manager.providesHeader = true
        app.ui.panels.register(manager)
        var console = PanelDescriptor(id: ManagerCommands.consolePanel, title: String(localized: "Developer Console"),
            icon: NibSymbol.command.name, placement: .floating, order: 0, owner: id) { context in
            AnyView(DevConsoleView(app: context.app, initialPlugin: context.params["plugin"]?.stringValue, close: context.dismiss))
        }
        console.providesHeader = true
        app.ui.panels.register(console)
    }
}

enum ManagerSettings {
    static let savedPrefix = "pluginmanager.saved."
    static func savedKey(_ entry: GalleryEntry) -> String {
        savedPrefix + SHA256.hash(data: Data(entry.key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct InstalledPlugin: Codable, Identifiable {
    var id: String
    var name: String
    var version: String
    var author: String?
    var description: String?
    var state: String
    var enabled: Bool
    var needsReview: Bool
    var error: String?
    var permissions: [String]
    var granted: [String]
    var networkHosts: [String]
    var sha256: String
    var source: String?
    var commands: [String]
}

/// Local adapter for the host/installer's documented, device-local grant file. No grants are stored in synced prefs.
final class ManagerGrants {
    static let serviceKey = "pluginmanager.grants"
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PluginGrants.json")
    }
    func read() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do { return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url)) }
        catch { throw NibError(.unavailable, "Plugin grants could not be read. Review the plugin again.") }
    }
    static func scopes(_ id: String, hash: String, grants: [String: JSONValue]) -> [String] {
        guard let grant = grants[id], grant["sha256"]?.stringValue == hash else { return [] }
        return grant["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    func set(_ id: String, hash: String, scopes: [String]) throws {
        var all = try read()
        guard var grant = all[id]?.objectValue, grant["sha256"]?.stringValue == hash else {
            throw NibError(.permissionDenied, "This plugin changed. Review its permissions first.")
        }
        grant["scopes"] = .array(scopes.sorted().map(JSONValue.string))
        all[id] = .object(grant)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}

enum PluginSkeleton {
    static func validID(_ id: String) -> Bool {
        id.count <= 128 && id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
    static func validCommandID(_ id: String) -> Bool {
        validID(id) && (id + ".hello").replacingOccurrences(of: ".", with: "__").count <= 64
    }
    static func files(id: String, name: String) throws -> JSONValue {
        guard validID(id) else { throw NibError.invalid("Use a reverse-DNS plugin id such as dev.example.hello.", path: "$.id") }
        guard validCommandID(id) else {
            throw NibError.invalid("The hello command id must fit 64 characters with dots written as __. Use a shorter plugin id.", path: "$.id")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw NibError.invalid("Enter a plugin name of 1 to 120 characters.", path: "$.name")
        }
        let command = id + ".hello"
        let manifest: JSONValue = ["id": .string(id), "name": .string(name), "version": "1.0.0", "api": 1,
            "entry": "main.js", "permissions": ["app"], "description": "A hello-world Nib plugin.",
            "contributes": ["commands": [["id": .string(command), "title": "Say Hello", "summary": "Show a hello-world message.",
                "params": ["type": "object", "properties": [:]], "effect": "session", "target": "app", "examples": [[:]]]],
                "toolbar": [["id": .string(id + ".button"), "title": "Say Hello", "icon": "hand.wave", "group": "accessories", "command": .string(command)]]]]
        let literal = JSONValue.string(command).jsonString()
        let script = "nib.commands.register(\(literal), async () => {\n  nib.ui.toast('Hello from your plugin');\n  return { ok: true };\n});\n"
        return ["manifest.json": .string(manifest.jsonString()), "main.js": .string(script)]
    }
}

@MainActor
enum ManagerCommands {
    static let managerPanel = "pluginmanager.manager"
    static let consolePanel = "pluginmanager.console"
    static let inspect = "pluginmanager.inspect"
    static let evaluate = "pluginmanager.evaluate"
    static let create = "pluginmanager.new"
    static let export = "pluginmanager.export"
    static let sdkExport = "pluginmanager.sdkExport"
    static let permission = "pluginmanager.permission"
    static let installFile = "pluginmanager.installFile"

    static func host(_ ctx: CommandContext) throws -> PluginHosting {
        guard let host = ctx.services.get(ServiceKeys.pluginHost, as: PluginHosting.self) else { throw NibError.unavailable("the plugin host") }
        return host
    }
    static func live(_ ctx: CommandContext) throws {
        guard !ctx.dryRun else { throw NibError(.unsupported, "This plugin action cannot be simulated.") }
    }
    static func id(_ p: JSONValue) throws -> String {
        guard let id = p["id"]?.stringValue, PluginSkeleton.validID(id) else {
            throw NibError.invalid("Supply an installed plugin id from plugin.list.", path: "$.id")
        }
        return id
    }
    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "gallery.list", title: String(localized: "List Gallery"),
            summary: "List configured gallery indexes, filtering compatible plugins/content packs by search, category, author or saved state; cursor pages results.",
            params: .obj(["index": .str("one HTTPS index; omitted uses configured indexes plus Nib Community"),
                "ids": .arr(.str(), "only these plugin ids"), "query": .str(), "category": .str(), "author": .str(), "saved": .bool(),
                "cursor": .int(min: 0), "limit": .int(min: 1, max: 50), "refresh": .bool("refresh cached indexes")], required: []),
            examples: [[:]], effect: .read, target: .app)) { p, ctx in
            let configured = ctx.services.settings.get(NibSettings.pluginGalleries)
            if !ctx.principal.isUser, let index = p["index"]?.stringValue,
               index != GalleryClient.defaultIndex, !configured.contains(index) {
                throw NibError(.permissionDenied, "Non-user callers may read only the default or configured gallery indexes.", path: "$.index")
            }
            let indexes = p["index"]?.stringValue.map { [$0] } ?? ([GalleryClient.defaultIndex] + configured).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let client = ctx.services.get(GalleryClient.serviceKey, as: GalleryClient.self) ?? GalleryClient()
            if p["refresh"]?.boolValue == true, p["cursor"] == nil { client.invalidate() }
            let offset = p["cursor"]?.intValue ?? 0
            let limit = p["limit"]?.intValue ?? 30
            guard indexes.count <= 20 else { throw NibError.invalid("Configure at most 20 gallery indexes.", path: "$.index") }
            var filterValues: [String: JSONValue] = [:]
            for key in ["ids", "query", "category", "author", "saved"] { if let value = p[key] { filterValues[key] = value } }
            let listing = try await client.listing(indexes: indexes, filters: .object(filterValues), settings: ctx.services.settings)
            var output = listing.headers
            let headerBytes = try JSONEncoder().encode(output).count
            guard headerBytes <= 7_500 else { throw NibError.invalid("The configured galleries exceed the result budget. Request one index at a time.", path: "$.index") }
            let entryBudget = 18_500 - headerBytes
            var included = 0
            var bytes = 0
            // Only size the requested slice. Cached rows before/after it need no work on later pages.
            for row in listing.rows.dropFirst(offset).prefix(limit) {
                let size = try JSONEncoder().encode(row.entry).count
                guard bytes + size < entryBudget else { break }
                output[row.section].plugins.append(row.entry)
                included += 1
                bytes += size
            }
            return ["indexes": try JSONValue.from(output), "total": .number(Double(listing.rows.count)),
                    "cursor": offset + included < listing.rows.count ? .number(Double(offset + included)) : .null]
        }
        app.commands.register(CommandDescriptor(id: inspect, title: String(localized: "Inspect Plugin"),
            summary: "Read an installed plugin's manifest and contributed settings, tools, panels and commands.",
            params: .obj(["id": .str(), "cursor": .int("UTF-8 byte offset from the previous page", min: 0)], required: ["id"]), examples: [["id": "dev.nib.hello"]], effect: .read, target: .app)) { p, ctx in
            let pluginID = try id(p)
            if case .plugin(let caller) = ctx.principal, caller != pluginID { throw NibError(.permissionDenied, "Plugins can inspect only themselves.") }
            let host = try host(ctx)
            guard let folder = host.folder(pluginID) else { throw NibError(.notFound, "This plugin is not installed.") }
            let data = try await Task.detached { try Data(contentsOf: folder.appendingPathComponent("manifest.json")) }.value
            guard data.count <= 512 * 1_024 else { throw NibError.invalid("The manifest is too large.") }
            _ = try JSONDecoder().decode(PluginManifest.self, from: data)
            let plugin = host.installed.first { $0.id == pluginID }
            let grants = try ctx.services.get(ManagerGrants.serviceKey, as: ManagerGrants.self)?.read() ?? [:]
            let consented = plugin.map { ManagerGrants.scopes(pluginID, hash: $0.sha256, grants: grants) } ?? []
            return try ManagerTextPage.page(data, offset: p["cursor"]?.intValue ?? 0)
                .merging(["consented": .array(consented.map(JSONValue.string))])
        }
        app.commands.register(CommandDescriptor(id: evaluate, title: String(localized: "Evaluate JavaScript"),
            summary: "Evaluate JavaScript in a running plugin's sandbox; user-only because evaluate has no caller-context parameter.",
            params: .obj(["id": .str(), "javascript": .str()], required: ["id", "javascript"]),
            examples: [["id": "dev.nib.hello", "javascript": "1 + 1"]], effect: .session, target: .app,
            extraScopes: [.security], exposure: .ui, userPresence: true)) { p, ctx in
            try live(ctx)
            let id = try id(p)
            guard let source = p["javascript"]?.stringValue, !source.isEmpty, source.utf8.count <= 64 * 1_024 else {
                throw NibError.invalid("Enter JavaScript smaller than 64 KB.", path: "$.javascript")
            }
            guard let handle = try host(ctx).handle(id) else { throw NibError(.unavailable, "Enable and review this plugin before evaluating JavaScript.") }
            return ["text": .string(ManagerTextPage.truncate(await handle.evaluate(source), maxBytes: 64 * 1_024))]
        }
        app.commands.register(CommandDescriptor(id: create, title: String(localized: "New Plugin"),
            summary: "Create a hello-world plugin skeleton through plugin.install, with the normal permission consent and folder installation.",
            params: .obj(["id": .str("reverse-DNS; omit to generate one"), "name": .str()], required: ["name"]),
            examples: [["id": "dev.nib.hello", "name": "Hello"]], effect: .library, target: .library,
            extraScopes: [.pluginsManage], userPresence: true)) { p, ctx in
            try live(ctx)
            let pluginID = p["id"]?.stringValue ?? "dev.nib.plugin." + UUID().uuidString.lowercased()
            guard !(try host(ctx)).installed.contains(where: { $0.id == pluginID }) else { throw NibError(.conflict, "A plugin with this id already exists.") }
            let files = try PluginSkeleton.files(id: pluginID, name: p["name"]?.stringValue ?? "")
            return try await ctx.execute(CommandIDs.pluginInstall, ["files": files])
        }
        app.commands.register(CommandDescriptor(id: export, title: String(localized: "Export Plugin"),
            summary: "Export an installed plugin's package files as a .nibplugin ZIP temporary asset; share opens the system share sheet.",
            params: .obj(["id": .str(), "share": .bool()], required: ["id"]),
            examples: [["id": "dev.nib.hello"]], effect: .read, target: .app)) { p, ctx in
            let pluginID = try id(p)
            if case .plugin(let caller) = ctx.principal, caller != pluginID { throw NibError(.permissionDenied, "Plugins can export only themselves.") }
            guard let folder = try host(ctx).folder(pluginID), let assets = ctx.services.assets else { throw NibError.unavailable("plugin files or the asset store") }
            let data = try await Task.detached { try PluginArchive.make(folder: folder) }.value
            let asset = try assets.putTemporary(data, ext: "nibplugin")
            try shareIfRequested(p, asset: asset, filename: pluginID + ".nibplugin", ctx: ctx)
            return ["asset": .string("tmp:" + asset.name), "filename": .string(pluginID + ".nibplugin")]
        }
        app.commands.register(CommandDescriptor(id: sdkExport, title: String(localized: "Export SDK Types"),
            summary: "Collect every plugin.sdkTypes page and export the complete nib.d.ts as a temporary asset, optionally sharing it.",
            params: .obj(["share": .bool()]), examples: [[:]], effect: .read, target: .app)) { p, ctx in
            guard let assets = ctx.services.assets else { throw NibError.unavailable("the asset store") }
            var params: JSONValue = [:]
            var text = ""
            var cursors = Set<String>()
            repeat {
                let page = try await ctx.execute(CommandIDs.pluginSdkTypes, params)
                guard let chunk = page["text"]?.stringValue else { throw NibError(.unavailable, "The SDK types response is incomplete.") }
                text += chunk
                guard text.utf8.count <= 8 * 1_024 * 1_024 else { throw NibError(.unavailable, "The SDK types exceed 8 MB.") }
                if page["truncated"]?.boolValue != true { break }
                guard let cursor = page["cursor"]?.stringValue, cursors.insert(cursor).inserted else {
                    throw NibError(.unavailable, "The SDK types cursor did not advance.")
                }
                params = ["cursor": .string(cursor)]
            } while true
            let asset = try assets.putTemporary(Data(text.utf8), ext: "d.ts")
            try shareIfRequested(p, asset: asset, filename: "nib.d.ts", ctx: ctx)
            return ["asset": .string("tmp:" + asset.name), "filename": "nib.d.ts"]
        }
        app.commands.register(CommandDescriptor(id: permission, title: String(localized: "Change Plugin Permission"),
            summary: "Change one device-local plugin permission; enabling asks for consent again and retains the other permission choices.",
            params: .obj(["id": .str(), "scope": .str(), "enabled": .bool()], required: ["id", "scope", "enabled"]),
            examples: [["id": "dev.nib.hello", "scope": "app", "enabled": false]], effect: .session, target: .app,
            extraScopes: [.security], userPresence: true)) { p, ctx in
            try live(ctx)
            let pluginID = try id(p)
            let host = try host(ctx)
            guard let plugin = host.installed.first(where: { $0.id == pluginID }), !plugin.needsReview,
                  let scope = p["scope"]?.stringValue, plugin.permissions.contains(scope),
                  Scope(rawValue: scope) != nil, !["security", "plugins:manage"].contains(scope),
                  let enabled = p["enabled"]?.boolValue else { throw NibError.invalid("Review the plugin, then choose one of its declared permissions.", path: "$.scope") }
            guard let grants = ctx.services.get(ManagerGrants.serviceKey, as: ManagerGrants.self) else { throw NibError.unavailable("plugin grants") }
            let grant = try grants.read()[pluginID]
            guard grant?["sha256"]?.stringValue == plugin.sha256 else { throw NibError(.permissionDenied, "The plugin changed. Review it first.") }
            var scopes = Set(grant?["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if enabled, !scopes.contains(scope) {
                guard let presenter = ctx.bus.gateway.confirmationPresenter(for: .user),
                      var descriptor = ctx.bus.registry.descriptor(permission) else { throw NibError.unavailable("permission confirmation") }
                var hosts = host.handle(pluginID)?.manifest.network?.hosts ?? []
                if scope == "network", host.handle(pluginID) == nil, let folder = host.folder(pluginID) {
                    hosts = try await Task.detached {
                        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
                        guard data.count <= 512 * 1_024 else { throw NibError.invalid("The manifest is too large.") }
                        return try JSONDecoder().decode(PluginManifest.self, from: data).network?.hosts ?? []
                    }.value
                }
                descriptor.title = String(localized: "Allow \(plugin.name) to \(PermissionCopy.sentence(scope, hosts: hosts).lowercased())?")
                if case .deny = await presenter.confirm(ConfirmationRequest(principal: .user, command: descriptor, params: p)) {
                    throw NibError(.userDenied, "Permission change cancelled.")
                }
                scopes.insert(scope)
            } else if !enabled { scopes.remove(scope) }
            try grants.set(pluginID, hash: plugin.sha256, scopes: Array(scopes))
            if plugin.enabled { try await host.load(pluginID) }
            return ["id": .string(pluginID), "scope": .string(scope), "enabled": .bool(enabled)]
        }
        app.commands.register(CommandDescriptor(id: installFile, title: String(localized: "Install Plugin from Files"),
            summary: "Choose a .nibplugin or ZIP in Files and install it through the normal plugin.install permission consent.",
            examples: [[:]], effect: .session, target: .app, extraScopes: [.pluginsManage], userPresence: true)) { _, ctx in
            try live(ctx)
            guard !NibApp.isHostlessTest, let app = ctx.app, let navigator = ctx.navigator else { throw NibError.unavailable("a window for the file picker") }
            let picker = PluginFilePicker(app: app)
            navigator.presentModal(picker)
            return [:]
        }
    }
    static func shareIfRequested(_ p: JSONValue, asset: AssetRef, filename: String, ctx: CommandContext) throws {
        guard p["share"]?.boolValue == true else { return }
        guard ctx.principal.isUser, !NibApp.isHostlessTest, let navigator = ctx.navigator,
              let url = ctx.services.assets?.temporaryURL(asset) else { throw NibError.unavailable("a window for sharing") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pluginmanager-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let namedURL = directory.appendingPathComponent(filename)
        do { try FileManager.default.copyItem(at: url, to: namedURL) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let controller = UIActivityViewController(activityItems: [namedURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
        controller.popoverPresentationController?.sourceView = navigator.rootViewController?.view
        controller.popoverPresentationController?.sourceRect = navigator.rootViewController?.view.bounds ?? .zero
        navigator.presentModal(controller)
    }
}

/// ZIP store records, no compression dependency. Only package files are exported; plugin storage and grants stay private.
/// CRC-32 and central directory offsets are the standard ZIP format understood by F079 and Files.
struct PluginArchive {
    static func make(folder: URL) throws -> Data {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw NibError(.notFound, "Plugin files could not be read.") }
        var files: [(String, Data)] = []
        var total = 0
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard properties.isSymbolicLink != true else { throw NibError.invalid("Plugin packages cannot contain symbolic links.") }
            guard properties.isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard GalleryClient.safePath(path), files.count < 1_000, (properties.fileSize ?? 0) <= 20 * 1_024 * 1_024 else {
                throw NibError.invalid("Plugin packages must contain at most 1,000 safe files and be smaller than 20 MB.")
            }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= 20 * 1_024 * 1_024 else { throw NibError.invalid("Plugin packages must be smaller than 20 MB.") }
            files.append((path, data))
        }
        if let enumerationError { throw NibError(.unavailable, enumerationError.localizedDescription) }
        guard files.contains(where: { $0.0 == "manifest.json" }) else { throw NibError.invalid("This plugin has no manifest.json.") }
        return try zip(files: files.sorted { $0.0 < $1.0 })
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return crc ^ 0xffff_ffff
    }
    static func zip(files: [(String, Data)]) throws -> Data {
        var out = Data(), directory = Data()
        func u16(_ number: Int, _ data: inout Data) { data.append(contentsOf: [UInt8(truncatingIfNeeded: number), UInt8(truncatingIfNeeded: number >> 8)]) }
        func u32(_ number: UInt32, _ data: inout Data) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: number >> shift)) }
        }
        for (path, data) in files {
            let name = Data(path.utf8)
            guard name.count <= 65_535, GalleryClient.safePath(path) else { throw NibError.invalid("Invalid archive path.") }
            let offset = UInt32(out.count), crc = crc32(data), size = UInt32(data.count)
            u32(0x04034b50, &out); u16(20, &out); u16(0x800, &out); u16(0, &out)
            u16(0, &out); u16(33, &out); u32(crc, &out); u32(size, &out); u32(size, &out)
            u16(name.count, &out); u16(0, &out); out.append(name); out.append(data)
            u32(0x02014b50, &directory); u16(20, &directory); u16(20, &directory); u16(0x800, &directory); u16(0, &directory)
            u16(0, &directory); u16(33, &directory); u32(crc, &directory); u32(size, &directory); u32(size, &directory)
            u16(name.count, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
            u32(0, &directory); u32(offset, &directory); directory.append(name)
        }
        let offset = UInt32(out.count)
        out.append(directory)
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(directory.count), &out); u32(offset, &out); u16(0, &out)
        return out
    }
}

/// Byte offsets remain exact across emoji and combining marks; pages fit under the 20 KB JSON read budget.
enum ManagerTextPage {
    static func truncate(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let suffix = "\n" + String(localized: "Result truncated.")
        var bytes = Array(text.utf8.prefix(maxBytes - suffix.utf8.count))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self) + suffix
    }
    static func page(_ data: Data, offset: Int) throws -> JSONValue {
        guard offset >= 0, offset <= data.count, offset == data.count || data[offset] & 0xc0 != 0x80 else {
            throw NibError.invalid("Use the cursor from the previous manifest page.", path: "$.cursor")
        }
        var end = min(offset + 4_000, data.count)
        while end > offset, end < data.count, data[end] & 0xc0 == 0x80 { end -= 1 }
        guard let text = String(data: data[offset..<end], encoding: .utf8) else { throw NibError.invalid("The manifest must be UTF-8 JSON.") }
        return ["text": .string(text), "cursor": end < data.count ? .number(Double(end)) : .null,
            "truncated": .bool(end < data.count)]
    }
}
