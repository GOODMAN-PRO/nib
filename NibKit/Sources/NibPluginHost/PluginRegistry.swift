import Foundation
import UIKit
import os
import NibContracts

let hostLog = Logger(subsystem: "app.nib", category: "pluginhost")

// MARK: - Records

/// Where one installed plugin stands on this device.
enum PluginState: String, Codable, Equatable {
    /// Started: its contributions are mapped and its runtime is live.
    case running
    /// Approved but switched off by the user (plugin.enable {enabled: false}).
    case disabled
    /// Present in the library but never approved on this device, or changed on disk since (hash ≠ grant).
    case needsReview
    /// The manifest is invalid, a file is missing, or the runtime refused to start it.
    case failed
    /// Nib runs in Safe Mode: no plugin starts.
    case safeMode
    /// Loaded before, stopped now (unloaded).
    case stopped
}

/// One plugin folder in the library's plugins folder (`plugins/<id>/` of the library metadata folder).
struct PluginRecord: Equatable {
    var id: String
    var folder: URL
    var manifest: PluginManifest?
    var sha256: String = ""
    /// Paths, sizes and dates of the files the hash was computed from.
    var signature: String = ""
    var state: PluginState = .stopped
    var error: String?
    var source: String?

    init(id: String, folder: URL) {
        self.id = id
        self.folder = folder
    }
}

/// Paths inside a plugin folder: relative, no "..", no absolute paths or backslashes, and (symlinks resolved) still
/// inside the folder.
enum PluginPaths {
    static func resolve(_ relative: String, in folder: URL, path: String) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\"), !trimmed.contains("\0"),
              !trimmed.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw NibError.invalid("'\(relative)' must be a relative path inside the plugin folder", path: path)
        }
        let base = folder.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(trimmed)
        // A path that does not exist cannot lead anywhere through a link; one that exists must stay inside once its
        // links are resolved (both sides existing, so they resolve the same way).
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let resolved = candidate.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(prefix) else {
            throw NibError.invalid("'\(relative)' must be a relative path inside the plugin folder", path: path)
        }
        return resolved
    }

    /// `resolve`, and the file must exist.
    static func existing(_ relative: String, in folder: URL, path: String) throws -> URL {
        let url = try resolve(relative, in: folder, path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw NibError(.notFound, "\(relative) is missing from the plugin", path: path)
        }
        return url
    }
}

// MARK: - Manifest validation (docs/PLUGIN_API.md §2–§5)

/// Checks a manifest before anything of it is mapped. Every rule reports a `NibError` with a JSON path into the
/// manifest, so the developer console and `plugin.list` can say exactly what to fix.
enum ManifestValidator {
    /// Scopes a manifest may ask for. `plugins:manage` and `security` are never granted to plugins.
    static let grantable: [String] = ["document:read", "document:write", "library:read", "library:write", "destructive",
                                      "app", "ai", "network"]
    static let idPattern = "^[a-z0-9]+([.-][a-z0-9]+)*$"
    static let versionPattern = "^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]+)?$"
    static let namePattern = "^[A-Za-z0-9_-]+$"
    static let hostPattern = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"
    static let maxInstructions = 1_000
    static let maxBundleBytes: Int64 = 20 * 1_048_576

    static func isValidPluginID(_ id: String) -> Bool {
        id.count <= 128 && id.contains(".") && matches(id, idPattern)
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Throws the first problem (with how many more there are).
    static func validate(_ m: PluginManifest, folder: URL?, folderName: String? = nil) throws {
        let all = problems(m, folder: folder, folderName: folderName)
        guard var first = all.first else { return }
        if all.count > 1 { first.message += " (and \(all.count - 1) more problem\(all.count == 2 ? "" : "s"))" }
        throw first
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func problems(_ m: PluginManifest, folder: URL?, folderName: String? = nil) -> [NibError] {
        var out: [NibError] = []
        func fail(_ message: String, _ path: String, _ code: NibError.Code = .invalidParams, hint: String? = nil) {
            out.append(NibError(code, message, path: path, hint: hint))
        }
        let pid = m.id
        let prefix = pid + "."
        if !isValidPluginID(pid) {
            fail("plugin ids are reverse-DNS names of [a-z0-9.-], e.g. dev.example.cards", "$.id")
        }
        if let name = folderName, name != pid {
            fail("the manifest id '\(pid)' does not match its folder '\(name)'", "$.id")
        }
        if m.name.trimmingCharacters(in: .whitespaces).isEmpty { fail("name must not be empty", "$.name") }
        if !matches(m.version, versionPattern) { fail("version must be semver, e.g. 1.2.0", "$.version") }
        if m.api != 1 {
            fail("plugin API version \(m.api) is not supported (this Nib runs version 1)", "$.api", .unsupported)
        }
        if let folder = folder {
            do { _ = try PluginPaths.existing(m.entry, in: folder, path: "$.entry") } catch { out.append(NibError.wrap(error)) }
        } else if m.entry.isEmpty || m.entry.hasPrefix("/") || m.entry.contains("..") {
            fail("the entry must be a path inside the plugin folder", "$.entry")
        }
        for (i, p) in m.permissions.enumerated() {
            if p == Scope.pluginsManage.rawValue || p == Scope.security.rawValue {
                fail("'\(p)' is never granted to plugins", "$.permissions[\(i)]", .permissionDenied)
            } else if !grantable.contains(p) {
                fail("unknown permission '\(p)'; use \(grantable.joined(separator: ", "))", "$.permissions[\(i)]")
            }
        }
        for (i, h) in (m.network?.hosts ?? []).enumerated() where !matches(h.lowercased(), hostPattern) {
            fail("network hosts are plain host names like api.example.com (no scheme, port or path)", "$.network.hosts[\(i)]")
        }

        let c = m.contributes
        let declared = Dictionary((c?.commands ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// A command a contribution points at: this plugin's own must be declared; others (built-in or another
        /// plugin's) are resolved when invoked.
        func command(_ id: String, _ path: String) {
            if id.isEmpty { return fail("missing command id", path) }
            if id.hasPrefix(prefix), declared[id] == nil {
                fail("'\(id)' is not declared in contributes?.commands", path)
            } else if !matches(id, "^[a-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+$") {
                fail("'\(id)' is not a command id", path)
            }
        }
        func owned(_ id: String, _ path: String) {
            if !id.hasPrefix(prefix) || id.count <= prefix.count {
                fail("ids a plugin contributes start with '\(prefix)'", path)
            }
        }
        func file(_ relative: String?, _ path: String) {
            guard let r = relative, !r.isEmpty else { return fail("missing file path", path) }
            guard let folder = folder else { return }
            do { _ = try PluginPaths.existing(r, in: folder, path: path) } catch { out.append(NibError.wrap(error)) }
        }
        func unique<T>(_ list: [T]?, _ key: (T) -> String, _ path: String) {
            var seen = Set<String>()
            for (i, x) in (list ?? []).enumerated() where !seen.insert(key(x)).inserted {
                fail("duplicate id '\(key(x))'", "\(path)[\(i)]")
            }
        }

        // Commands
        unique(c?.commands, { $0.id }, "$.contributes.commands")
        for (i, cmd) in (c?.commands ?? []).enumerated() {
            let p = "$.contributes.commands[\(i)]"
            owned(cmd.id, p + ".id")
            let name = String(cmd.id.dropFirst(prefix.count))
            if cmd.id.hasPrefix(prefix), !matches(name, "^[A-Za-z0-9]+(\\.[A-Za-z0-9]+)*$") {
                fail("command names after the plugin id are dot-separated [A-Za-z0-9] segments", p + ".id")
            }
            if cmd.id.replacingOccurrences(of: ".", with: "__").count > 64 {
                fail("'\(cmd.id)' is too long for AI tool names (64 characters with dots as __)", p + ".id")
            }
            if cmd.title.trimmingCharacters(in: .whitespaces).isEmpty { fail("title must not be empty", p + ".title") }
            if cmd.summary.trimmingCharacters(in: .whitespaces).isEmpty { fail("summary must not be empty", p + ".summary") }
            if let e = cmd.effect, Effect(rawValue: e) == nil {
                fail("effect is one of \(Effect.allCases.map { $0.rawValue }.joined(separator: ", "))", p + ".effect")
            }
            if let t = cmd.target, CommandTarget(rawValue: t) == nil {
                fail("target is one of document, library, app", p + ".target")
            }
            if let params = cmd.params {
                if !SchemaConverter.isObjectSchema(params) {
                    fail("params must be a JSON Schema object ({\"type\": \"object\", \"properties\": {…}})", p + ".params")
                } else {
                    let schema = SchemaConverter.schema(params)
                    for (j, ex) in (cmd.examples ?? []).enumerated() {
                        if let e = schema.validate(ex, path: "\(p).examples[\(j)]").first { out.append(e) }
                    }
                }
            }
        }
        // Menus
        for (i, menu) in (c?.menus ?? []).enumerated() {
            let p = "$.contributes.menus[\(i)]"
            if MenuLocation(rawValue: menu.location) == nil {
                fail("unknown menu location '\(menu.location)'", p + ".location")
            }
            command(menu.command, p + ".command")
            if let w = menu.when {
                for (j, k) in (w.selectionKinds ?? []).enumerated() where ItemKind(rawValue: k) == nil {
                    fail("unknown item kind '\(k)'", "\(p).when.selectionKinds[\(j)]")
                }
                for (j, k) in (w.docKinds ?? []).enumerated() where DocumentKind(rawValue: k) == nil {
                    fail("unknown document kind '\(k)'", "\(p).when.docKinds[\(j)]")
                }
                if let n = w.minSelection, n < 0 { fail("minSelection must be 0 or more", p + ".when.minSelection") }
            }
        }
        // Canvas tools and their option bars
        let toolIDs = Set((c?.tools ?? []).map { $0.id })
        unique(c?.tools, { $0.id }, "$.contributes.tools")
        for (i, tool) in (c?.tools ?? []).enumerated() {
            let p = "$.contributes.tools[\(i)]"
            owned(tool.id, p + ".id")
            if PluginToolInput(rawValue: tool.input) == nil { fail("input is stroke, tap or rect", p + ".input") }
            if let preview = tool.preview, PluginToolPreview(rawValue: preview) == nil {
                fail("preview is ink, lasso or none", p + ".preview")
            }
            command(tool.command, p + ".command")
        }
        let settingKeys = Set(c?.settings?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        for (i, opt) in (c?.toolOptions ?? []).enumerated() {
            let p = "$.contributes.toolOptions[\(i)]"
            if !toolIDs.contains(opt.tool) { fail("'\(opt.tool)' is not one of this plugin's tools", p + ".tool") }
            for (j, key) in opt.settings.enumerated() where !settingKeys.contains(key) {
                fail("'\(key)' is not a key of contributes?.settings", "\(p).settings[\(j)]")
            }
        }
        // Toolbar
        unique(c?.toolbar, { $0.id }, "$.contributes.toolbar")
        for (i, item) in (c?.toolbar ?? []).enumerated() {
            let p = "$.contributes.toolbar[\(i)]"
            owned(item.id, p + ".id")
            switch (item.command, item.tool) {
            case (let cmd?, nil): command(cmd, p + ".command")
            case (nil, let tool?): if !toolIDs.contains(tool) { fail("'\(tool)' is not one of this plugin's tools", p + ".tool") }
            default: fail("a toolbar entry sets exactly one of command or tool", p)
            }
            if let g = item.group, !["tools", "accessories", "navLeading", "navTrailing"].contains(g) {
                fail("group is tools, accessories, navLeading or navTrailing", p + ".group")
            }
            if item.icon.isEmpty { fail("icon must be an SF Symbol name", p + ".icon") }
        }
        // Panels
        unique(c?.panels, { $0.id }, "$.contributes.panels")
        for (i, panel) in (c?.panels ?? []).enumerated() {
            let p = "$.contributes.panels[\(i)]"
            owned(panel.id, p + ".id")
            file(panel.entry, p + ".entry")
            if let placement = panel.placement, PanelPlacement(rawValue: placement) == nil {
                fail("placement is sidebarTab, floating, sheet, libraryTab or fullScreen", p + ".placement")
            }
        }
        // Templates
        unique(c?.templates, { $0.id }, "$.contributes.templates")
        for (i, t) in (c?.templates ?? []).enumerated() {
            let p = "$.contributes.templates[\(i)]"
            owned(t.id, p + ".id")
            if let size = t.size, !(size.width > 0 && size.height > 0) { fail("size must be positive", p + ".size") }
            for problem in SpecTemplate.paramProblems(t.params, path: p + ".params") { out.append(problem) }
            switch t.kind {
            case "spec":
                guard let spec = t.spec, case .object = spec, spec["ops"]?.arrayValue != nil else {
                    fail("a spec template needs spec {paper?, ops: [DisplayOp]}", p + ".spec")
                    continue
                }
                let template = SpecTemplate(spec: spec, designSize: t.size, defaults: SpecTemplate.defaults(t.params))
                if let bad = template.invalidOp() { fail("op \(bad.index) is not a valid DisplayOp: \(bad.reason)", "\(p).spec.ops[\(bad.index)]") }
            case "pdf":
                file(t.file, p + ".file")
            default:
                fail("kind is spec or pdf", p + ".kind")
            }
        }
        // Key bindings
        for (i, k) in (c?.keybindings ?? []).enumerated() {
            let p = "$.contributes.keybindings[\(i)]"
            if KeyBindingParser.parse(k.key) == nil {
                fail("'\(k.key)' is not a key binding like cmd+shift+f", p + ".key")
            }
            command(k.command, p + ".command")
        }
        // Settings
        if let s = c?.settings {
            if !SchemaConverter.isObjectSchema(s) {
                fail("settings must be a JSON Schema object with properties", "$.contributes.settings")
            }
            for key in settingKeys where !matches(key, "^[A-Za-z0-9_-]+$") {
                fail("setting keys are [A-Za-z0-9_-]", "$.contributes.settings.properties.\(key)")
            }
        }
        // AI
        for (i, a) in (c?.aiActions ?? []).enumerated() {
            let p = "$.contributes.aiActions[\(i)]"
            if a.title.trimmingCharacters(in: .whitespaces).isEmpty { fail("title must not be empty", p + ".title") }
            if a.prompt.trimmingCharacters(in: .whitespaces).isEmpty { fail("prompt must not be empty", p + ".prompt") }
            if let s = a.scope, AIScopeKind(rawValue: s) == nil {
                fail("scope is \(AIScopeKind.allCases.map { $0.rawValue }.joined(separator: ", "))", p + ".scope")
            }
            if let mode = a.mode, AIMode(rawValue: mode) == nil { fail("mode is ask or edit", p + ".mode") }
        }
        if let text = c?.ai?.instructions, text.count > maxInstructions {
            fail("ai.instructions is limited to \(maxInstructions) characters", "$.contributes.ai.instructions")
        }
        // Importers and exporters
        for (name, list) in [("importers", c?.importers), ("exporters", c?.exporters)] {
            for (i, h) in (list ?? []).enumerated() {
                let p = "$.contributes.\(name)[\(i)]"
                if h.extensions.isEmpty { fail("extensions must not be empty", p + ".extensions") }
                for (j, e) in h.extensions.enumerated() where !matches(FileHandlerMapping.normalize(e), "^[a-z0-9]+$") {
                    fail("'\(e)' is not a file extension", "\(p).extensions[\(j)]")
                }
                command(h.command, p + ".command")
            }
        }
        // Custom item types
        let itemTypes = Set((c?.itemTypes ?? []).map { $0.type })
        unique(c?.itemTypes, { $0.type }, "$.contributes.itemTypes")
        for (i, t) in (c?.itemTypes ?? []).enumerated() {
            let p = "$.contributes.itemTypes[\(i)]"
            if !matches(t.type, namePattern) { fail("type is [A-Za-z0-9_-]", p + ".type") }
            if t.title.isEmpty { fail("title must not be empty", p + ".title") }
            if let e = t.edit { command(e, p + ".edit") }
            if let schema = t.inspector, !SchemaConverter.isObjectSchema(schema) {
                fail("inspector must be a JSON Schema object with properties", p + ".inspector")
            }
            if let path = t.textPath, path.isEmpty { fail("textPath must not be empty", p + ".textPath") }
        }
        // Tap handlers
        for (i, t) in (c?.tapHandlers ?? []).enumerated() {
            let p = "$.contributes.tapHandlers[\(i)]"
            if CanvasGesture(rawValue: t.gesture) == nil { fail("gesture is tap, doubleTap or longPress", p + ".gesture") }
            command(t.command, p + ".command")
            for (j, k) in (t.itemKinds ?? []).enumerated() where ItemKind(rawValue: k) == nil {
                fail("unknown item kind '\(k)'", "\(p).itemKinds[\(j)]")
            }
            for (j, k) in (t.itemTypes ?? []).enumerated() where !itemTypes.contains(k) {
                fail("'\(k)' is not one of this plugin's itemTypes", "\(p).itemTypes[\(j)]")
            }
        }
        // Blocks
        unique(c?.blocks, { $0.type }, "$.contributes.blocks")
        for (i, b) in (c?.blocks ?? []).enumerated() {
            let p = "$.contributes.blocks[\(i)]"
            if !matches(b.type, namePattern) { fail("type is [A-Za-z0-9_-]", p + ".type") }
            if b.title.isEmpty { fail("title must not be empty", p + ".title") }
            if let h = b.height, !(h > 0 && h <= 4_000) { fail("height is 1…4000 points", p + ".height") }
            command(b.command, p + ".command")
        }
        // Stroke processors
        unique(c?.strokeProcessors, { $0.id }, "$.contributes.strokeProcessors")
        for (i, s) in (c?.strokeProcessors ?? []).enumerated() {
            let p = "$.contributes.strokeProcessors[\(i)]"
            owned(s.id, p + ".id")
            command(s.command, p + ".command")
            for (j, t) in (s.tools ?? []).enumerated() where InkTool(rawValue: t) == nil {
                fail("unknown ink tool '\(t)'", "\(p).tools[\(j)]")
            }
        }
        // Pencil actions
        for (i, a) in (c?.pencilActions ?? []).enumerated() {
            let p = "$.contributes.pencilActions[\(i)]"
            if !["doubleTap", "squeeze"].contains(a.gesture) { fail("gesture is doubleTap or squeeze", p + ".gesture") }
            if a.title.isEmpty { fail("title must not be empty", p + ".title") }
            command(a.command, p + ".command")
        }
        // Command hooks: the hook command runs read-only before each matching call, so it must be declared read.
        for (i, h) in (c?.commandHooks ?? []).enumerated() {
            let p = "$.contributes.commandHooks[\(i)]"
            if h.commands.isEmpty { fail("commands must name at least one command id or namespace.*", p + ".commands") }
            for (j, pattern) in h.commands.enumerated()
            where !matches(pattern, "^[a-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)*(\\.\\*)?$") || pattern == "*" {
                fail("'\(pattern)' is not a command id or namespace wildcard like page.*", "\(p).commands[\(j)]")
            }
            guard let hook = declared[h.command] else {
                fail("the hook command must be one of this plugin's commands", p + ".command")
                continue
            }
            if (hook.effect ?? "edit") != Effect.read.rawValue {
                fail("hook commands must be declared \"effect\": \"read\"", p + ".command")
            }
        }
        // Content packs
        unique(c?.elements, { $0.id }, "$.contributes.elements")
        for (i, e) in (c?.elements ?? []).enumerated() {
            let p = "$.contributes.elements[\(i)]"
            owned(e.id, p + ".id")
            if e.files.isEmpty { fail("files must list at least one fragment file", p + ".files") }
            for (j, f) in e.files.enumerated() { file(f, "\(p).files[\(j)]") }
        }
        unique(c?.tapePatterns, { $0.id }, "$.contributes.tapePatterns")
        for (i, t) in (c?.tapePatterns ?? []).enumerated() {
            let p = "$.contributes.tapePatterns[\(i)]"
            owned(t.id, p + ".id")
            file(t.file, p + ".file")
        }
        unique(c?.boardTemplates, { $0.id }, "$.contributes.boardTemplates")
        for (i, b) in (c?.boardTemplates ?? []).enumerated() {
            let p = "$.contributes.boardTemplates[\(i)]"
            owned(b.id, p + ".id")
            switch (b.diagram, b.file) {
            case (let d?, nil):
                if d["nodes"]?.arrayValue == nil { fail("diagram needs nodes (a diagram.create spec without page)", p + ".diagram") }
            case (nil, let f?): file(f, p + ".file")
            default: fail("a board template sets exactly one of diagram or file", p)
            }
        }
        return out
    }
}

// MARK: - The host

/// `PluginHosting` (`ServiceKeys.pluginHost`): finds plugin folders in the library, loads the approved ones (grant hash
/// = folder hash), maps their contributions into the registries with owner = plugin id, answers `Gateway.grants` for
/// `.plugin(id)`, and unmaps everything again on unload.
@MainActor
final class PluginHost: PluginHosting {
    private weak var app: NibApp?
    let authority: PluginGrantAuthority
    /// Folder that holds the plugin folders; nil = `<library metadata>/plugins` (tests set their own).
    var pluginsFolderOverride: URL?
    /// Safe Mode check (tests replace it).
    var isSafeMode: () -> Bool = { SafeMode.isActive }
    /// How long stroke processors may take (docs/PLUGIN_API.md §5.9).
    var strokeProcessorBudget: TimeInterval = 0.05
    private(set) var records: [String: PluginRecord] = [:]
    private var handles: [String: PluginRuntimeHandle] = [:]
    /// Console output of a plugin that was stopped, so `plugin.logs` still shows why it went away.
    private var lastLogs: [String: [String]] = [:]
    /// Bumped by every load and unload of a plugin: a load that finds its generation changed after an `await` gave way to
    /// a newer load or an unload and backs out.
    private var generations: [String: Int] = [:]
    private var started = false
    private var refreshTask: Task<Void, Never>?
    private var subscriptions: [EventSubscription] = []
    /// Library, foreground and settings observers (the host lives as long as the app).
    private var observers: [NSObjectProtocol] = []

    init(app: NibApp, store: PluginGrantStore = PluginGrantStore()) {
        self.app = app
        self.authority = PluginGrantAuthority(store: store)
    }

    /// Answers `Gateway.grants` for `.plugin(id)` (every other principal keeps the previous answer).
    func installGrants(on gateway: Gateway) {
        let previous = gateway.grants
        let authority = self.authority
        gateway.grants = { principal in
            if case let .plugin(id) = principal { return authority.scopes(id) }
            return previous(principal)
        }
    }

    // MARK: PluginHosting

    var installed: [PluginInfo] {
        records.values.sorted { ($0.manifest?.name ?? $0.id, $0.id) < ($1.manifest?.name ?? $1.id, $1.id) }.map(info)
    }

    func info(_ r: PluginRecord) -> PluginInfo {
        PluginInfo(id: r.id, name: r.manifest?.name ?? r.id, version: r.manifest?.version ?? "",
                   enabled: isEnabled(r.id), needsReview: r.state == .needsReview,
                   permissions: r.manifest?.permissions ?? [], sha256: r.sha256, source: r.source)
    }

    func handle(_ id: String) -> PluginRuntimeHandle? { handles[id] }

    func folder(_ id: String) -> URL? {
        if let r = records[id] { return r.folder }
        guard ManifestValidator.isValidPluginID(id), let root = pluginsFolder else { return nil }
        let url = root.appendingPathComponent(id, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var aiInstructions: [String] {
        records.values.filter { $0.state == .running && handles[$0.id] != nil }.sorted { $0.id < $1.id }.compactMap { r in
            guard let text = r.manifest?.contributes?.ai?.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return String(text.prefix(ManifestValidator.maxInstructions))
        }
    }

    /// The `plugins` folder of the library metadata folder.
    var pluginsFolder: URL? {
        if let o = pluginsFolderOverride { return o }
        return app?.services.library?.metadataURL.appendingPathComponent("plugins", isDirectory: true)
    }

    func isEnabled(_ id: String) -> Bool {
        guard let app = app else { return false }
        return PluginEnablement.isEnabled(id, settings: app.settings)
    }

    /// Scopes `.plugin(id)` holds right now.
    func grantedScopes(_ id: String) -> Set<Scope> { authority.scopes(id) }

    func logs(_ id: String) -> [String] { handles[id]?.logs ?? lastLogs[id] ?? [] }

    func state(_ id: String) -> PluginState? { records[id]?.state }

    // MARK: Loading

    /// (Re)loads a plugin from its folder: reads and validates the manifest, checks the grant against the folder hash,
    /// starts the runtime and maps the contributions. A disabled plugin is read (for listings) but not started.
    func load(_ id: String) async throws {
        guard let app = app else { throw NibError.unavailable("the app") }
        guard ManifestValidator.isValidPluginID(id) else {
            throw NibError.invalid("'\(id)' is not a plugin id", path: "$.id")
        }
        guard let root = pluginsFolder else {
            throw NibError(.unavailable, "no library folder is open", hint: "choose a library folder first")
        }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            unload(id)
            records[id] = nil
            throw NibError(.notFound, "plugin \(id) is not installed", hint: "call plugin.list to see installed plugins")
        }
        unload(id)
        let generation = bump(id)
        var record = PluginRecord(id: id, folder: folder)
        record.state = .failed
        func finish(_ state: PluginState, _ error: Error?) {
            record.state = state
            record.error = error.map { NibError.wrap($0).message }
            if generations[id] == generation { records[id] = record }
        }

        // Manifest, files and hash (read off the main actor).
        let scan: PackageScan
        do {
            scan = try await Task.detached(priority: .userInitiated) { try PackageScan.read(folder) }.value
        } catch {
            finish(.failed, error)
            throw error
        }
        guard generations[id] == generation else { return }
        record.manifest = scan.manifest
        record.sha256 = scan.sha256
        record.signature = scan.signature
        do {
            try ManifestValidator.validate(scan.manifest, folder: folder, folderName: id)
        } catch {
            finish(.failed, error)
            throw error
        }
        authority.store.reload()
        guard let grant = authority.store.grant(id), grant.sha256 == scan.sha256 else {
            let e = NibError(.permissionDenied,
                             "plugin \(id) was never approved on this device or changed since it was approved",
                             hint: "review it with plugin.review {\"id\": \"\(id)\"}")
            finish(.needsReview, e)
            throw e
        }
        record.source = grant.source
        guard isEnabled(id) else {
            finish(.disabled, nil)
            return
        }
        if isSafeMode() {
            let e = NibError(.unavailable, "Nib is in Safe Mode, so plugins do not run", hint: "restart Nib normally")
            finish(.safeMode, e)
            throw e
        }
        guard let runtime = app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntimeProviding.self) else {
            let e = NibError.unavailable("the plugin runtime")
            finish(.failed, e)
            throw e
        }
        // The grant is live while main.js boots (it may call commands at start-up).
        authority.setLoaded(id, permissions: scan.manifest.permissions, sha256: scan.sha256)
        let handle: PluginRuntimeHandle
        do {
            handle = try await runtime.start(scan.manifest, folder: folder)
        } catch {
            if generations[id] == generation { authority.removeLoaded(id) }
            finish(.failed, error)
            throw error
        }
        guard generations[id] == generation else {
            handle.stop()
            return
        }
        handles[id] = handle
        do {
            let mapper = ContributionMapper(app: app, host: self, manifest: scan.manifest, folder: folder)
            try mapper.map()
        } catch {
            ContributionMapper.unmap(owner: id, app: app)
            handles[id] = nil
            handle.stop()
            authority.removeLoaded(id)
            finish(.failed, error)
            throw error
        }
        finish(.running, nil)
        hostLog.info("plugin \(id, privacy: .public) \(scan.manifest.version, privacy: .public) loaded")
    }

    /// Stops a plugin and removes everything it registered (every registry, the bus hooks, its grant).
    func unload(_ id: String) {
        bump(id)
        if let app = app { ContributionMapper.unmap(owner: id, app: app) }
        authority.removeLoaded(id)
        if let handle = handles.removeValue(forKey: id) {
            lastLogs[id] = handle.logs
            handle.stop()
        }
        if var r = records[id], r.state == .running {
            r.state = .stopped
            records[id] = r
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        guard let app = app else { throw NibError.unavailable("the app") }
        guard folder(id) != nil else {
            throw NibError(.notFound, "plugin \(id) is not installed", hint: "call plugin.list to see installed plugins")
        }
        PluginEnablement.set(id, enabled: enabled, settings: app.settings)
        if enabled {
            try await load(id)
        } else {
            unload(id)
            if var r = records[id], r.state != .needsReview {
                r.state = .disabled
                r.error = nil
                records[id] = r
            }
        }
    }

    @discardableResult
    private func bump(_ id: String) -> Int {
        let g = (generations[id] ?? 0) + 1
        generations[id] = g
        return g
    }

    // MARK: Scanning

    /// Launch: scans the plugins folder and loads every approved, enabled plugin, then keeps watching the library
    /// (sync brings new or changed plugin folders; the installer writes grants).
    func start() async {
        guard !started, let app = app else { return }
        started = true
        subscriptions.append(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRefresh() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                queue: nil) { [weak self] note in
            guard note.userInfo?["name"] as? String == NibSettings.exposeHiddenPluginCommands.name else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remapExposure() } }
        })
        await refresh(startApproved: true)
    }

    /// Coalesces bursts of library changes into one rescan.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh(startApproved: true)
        }
    }

    /// Brings the records in line with the plugins folder: removed folders are unloaded and forgotten, a running plugin
    /// whose files or grant no longer match is stopped (needs review), and with `startApproved` new or newly approved
    /// plugins are loaded.
    func refresh(startApproved: Bool) async {
        guard let root = pluginsFolder else {
            for id in Array(records.keys) {
                unload(id)
                records[id] = nil
            }
            return
        }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let folders = names.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let ids = Set(folders.map { $0.lastPathComponent }.filter { ManifestValidator.isValidPluginID($0) })
        for gone in Set(records.keys).subtracting(ids) {
            unload(gone)
            records[gone] = nil
        }
        authority.store.reload()
        for id in ids.sorted() {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            let signature = await Task.detached { (try? PluginFolderHash.files(folder)).map(PluginFolderHash.signature) }.value
            if let r = records[id], r.folder == folder, let sig = signature, sig == r.signature, !r.sha256.isEmpty {
                let approved = authority.store.grant(id)?.sha256 == r.sha256
                switch r.state {
                case .running where !approved:
                    unload(id)
                    var changed = r
                    changed.state = .needsReview
                    changed.error = "the grant no longer matches this plugin"
                    records[id] = changed
                case .needsReview where approved && startApproved,
                     .stopped where startApproved && isEnabled(id),
                     .disabled where startApproved && isEnabled(id):
                    do { try await load(id) } catch { hostLog.error("plugin \(id, privacy: .public): \(NibError.wrap(error).message, privacy: .public)") }
                default:
                    break
                }
                continue
            }
            if startApproved || records[id]?.state == .running {
                do { try await load(id) } catch { hostLog.error("plugin \(id, privacy: .public): \(NibError.wrap(error).message, privacy: .public)") }
            } else {
                await inspect(id, folder: folder)
            }
        }
    }

    /// Reads a plugin folder for listings without starting anything (a changed running plugin is stopped).
    private func inspect(_ id: String, folder: URL) async {
        let scan = try? await Task.detached { try PackageScan.read(folder) }.value
        var record = records[id] ?? PluginRecord(id: id, folder: folder)
        guard let s = scan else {
            record.state = .failed
            record.error = "the plugin folder cannot be read"
            records[id] = record
            return
        }
        record.folder = folder
        record.manifest = s.manifest
        record.sha256 = s.sha256
        record.signature = s.signature
        let approved = authority.store.grant(id)?.sha256 == s.sha256
        if !approved {
            unload(id)
            record.state = .needsReview
        } else if let problem = ManifestValidator.problems(s.manifest, folder: folder, folderName: id).first {
            record.state = .failed
            record.error = problem.message
        } else if record.state != .running {
            record.state = isEnabled(id) ? .stopped : .disabled
        }
        records[id] = record
    }

    /// Re-registers plugin commands when "Expose hidden plugin commands" changes (exposure is part of the descriptor).
    func remapExposure() {
        guard let app = app else { return }
        for r in records.values where r.state == .running {
            guard let manifest = r.manifest else { continue }
            ContributionMapper(app: app, host: self, manifest: manifest, folder: r.folder).mapCommands()
        }
    }
}

/// A plugin folder read from disk: its manifest and package hash.
struct PackageScan {
    var manifest: PluginManifest
    var sha256: String
    var signature: String

    /// Runs off the main actor.
    static func read(_ folder: URL) throws -> PackageScan {
        let files = try PluginFolderHash.files(folder)
        let total = PluginFolderHash.totalBytes(files)
        guard total <= ManifestValidator.maxBundleBytes else {
            throw NibError(.invalidParams, "the plugin is larger than \(ManifestValidator.maxBundleBytes / 1_048_576) MB")
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw NibError(.notFound, "manifest.json is missing from plugin \(folder.lastPathComponent)")
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let e as DecodingError {
            throw NibError(.invalidParams, "manifest.json does not decode: \(ManifestErrors.describe(e))", path: ManifestErrors.path(e))
        } catch {
            throw NibError(.invalidParams, "manifest.json is not JSON: \(error.localizedDescription)")
        }
        return PackageScan(manifest: manifest, sha256: try PluginFolderHash.compute(files: files),
                           signature: PluginFolderHash.signature(files))
    }
}

/// Readable decoding errors for manifests.
enum ManifestErrors {
    static func path(_ e: DecodingError) -> String {
        func join(_ p: [CodingKey]) -> String { "$" + p.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined() }
        switch e {
        case .keyNotFound(let k, let c): return join(c.codingPath + [k])
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return join(c.codingPath)
        @unknown default: return "$"
        }
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _): return "missing '\(k.stringValue)'"
        case .typeMismatch(let t, _): return "wrong type (expected \(t))"
        case .valueNotFound(let t, _): return "missing value (expected \(t))"
        case .dataCorrupted(let c): return c.debugDescription
        @unknown default: return "invalid manifest"
        }
    }
}
