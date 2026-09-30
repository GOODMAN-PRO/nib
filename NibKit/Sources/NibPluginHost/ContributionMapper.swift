import Foundation
import UIKit
import SwiftUI
import Combine
import CoreGraphics
import UniformTypeIdentifiers
import NibContracts

// Maps a validated manifest's `contributes` (docs/PLUGIN_API.md §5) into the same registries native features use,
// every entry owned by the plugin id, so `unmap(owner:)` removes the plugin completely. Plugins never get closures
// of their own: every contribution points at a command, and the host adds the UI (forms, previews, block views).

// MARK: - Mapper

@MainActor
struct ContributionMapper {
    let app: NibApp
    weak var host: PluginHost?
    let manifest: PluginManifest
    let folder: URL

    init(app: NibApp, host: PluginHost?, manifest: PluginManifest, folder: URL) {
        self.app = app
        self.host = host
        self.manifest = manifest
        self.folder = folder
    }

    var pid: String { manifest.id }
    private var contributes: PluginContributions? { manifest.contributes }

    /// Registers every contribution. Throws (before registering anything) when an id is already taken by someone else.
    func map() throws {
        try checkConflicts()
        let c = contributes
        let pdfs = try pdfTemplates()
        mapCommands()
        declareSettings()
        mapMenus(c)
        mapToolbar(c)
        mapTools(c)
        mapPanels(c)
        mapTemplates(c, pdfs: pdfs)
        mapKeyBindings(c)
        mapSettingsPage(c)
        mapAI(c)
        try mapFileHandlers(c)
        mapItemTypes(c)
        mapTapHandlers(c)
        mapBlocks(c)
        mapStrokeProcessors(c)
        mapPencilActions(c)
        mapCommandHooks(c)
        try mapContentPacks(c)
    }

    /// Removes everything `owner` registered, everywhere (a registry is only touched when it holds an entry of the owner,
    /// so observers are not woken for nothing).
    static func unmap(owner: String, app: NibApp) {
        if app.commands.all().contains(where: { $0.owner == owner }) { app.commands.unregister(owner: owner) }
        let ui = app.ui
        drop(owner, ui.toolbar)
        drop(owner, ui.menus)
        drop(owner, ui.panels)
        drop(owner, ui.settingsPages)
        drop(owner, ui.inspectors)
        drop(owner, ui.canvasTools)
        drop(owner, ui.editors)
        drop(owner, ui.toolMenus)
        drop(owner, ui.blockViews)
        drop(owner, ui.canvasAttachments)
        drop(owner, ui.chromeOverlays)
        let c = app.content
        drop(owner, c.templates)
        drop(owner, c.drawers)
        drop(owner, c.importers)
        drop(owner, c.exporters)
        drop(owner, c.aiActions)
        drop(owner, c.strokeProcessors)
        drop(owner, c.keyCommands)
        drop(owner, c.backgroundTasks)
        drop(owner, c.tapHandlers)
        drop(owner, c.boardTemplates)
        drop(owner, c.tapePatterns)
        drop(owner, c.elementCollections)
        drop(owner, c.blockKinds)
        drop(owner, c.customItemTypes)
        drop(owner, c.pencilActions)
        drop(owner, c.textLayouts)
        drop(owner, app.bus.hooks)
    }

    private static func drop<D: Registrable>(_ owner: String, _ registry: Registry<D>) {
        if registry.all.contains(where: { $0.owner == owner }) { registry.unregister(owner: owner) }
    }

    // MARK: Conflicts

    private func checkConflicts() throws {
        let c = contributes
        func check<D: Registrable>(_ registry: Registry<D>, _ id: String, _ what: String) throws {
            if let existing = registry.get(id), existing.owner != pid {
                throw NibError(.conflict, "\(what) '\(id)' is already registered by \(existing.owner)",
                               hint: "give the plugin's contributions ids that start with its own id")
            }
        }
        for cmd in c?.commands ?? [] {
            if let d = app.commands.descriptor(cmd.id), d.owner != pid {
                throw NibError(.conflict, "command '\(cmd.id)' is already registered by \(d.owner)")
            }
        }
        for t in c?.toolbar ?? [] { try check(app.ui.toolbar, t.id, "toolbar item") }
        for t in c?.tools ?? [] { try check(app.ui.canvasTools, t.id, "canvas tool") }
        for p in c?.panels ?? [] { try check(app.ui.panels, p.id, "panel") }
        for t in c?.templates ?? [] { try check(app.content.templates, t.id, "template") }
        for s in c?.strokeProcessors ?? [] { try check(app.content.strokeProcessors, s.id, "stroke processor") }
        for e in c?.elements ?? [] { try check(app.content.elementCollections, e.id, "element collection") }
        for t in c?.tapePatterns ?? [] { try check(app.content.tapePatterns, t.id, "tape pattern") }
        for b in c?.boardTemplates ?? [] { try check(app.content.boardTemplates, b.id, "board template") }
        for o in c?.toolOptions ?? [] { try check(app.ui.toolMenus, o.tool, "tool options") }
    }

    // MARK: Commands

    /// Registers (or re-registers, e.g. when "Expose hidden plugin commands" changes) the plugin's commands: the
    /// descriptor comes from the manifest, the handler runs the plugin's JavaScript through its runtime handle.
    func mapCommands() {
        let exposeHidden = app.settings.get(NibSettings.exposeHiddenPluginCommands)
        let c = contributes
        let tapCommands = Set((c?.tapHandlers ?? []).map { $0.command })
        let pid = self.pid
        for cmd in c?.commands ?? [] {
            let descriptor = ContributionMapper.descriptor(cmd, owner: pid, exposeHidden: exposeHidden)
            // A double-tap on a custom item reaches its `edit` command through the tap router, which sends
            // {page, point, ref, gesture} and wants {handled}; the plugin gets {ref} as documented.
            let editsTypes = (c?.itemTypes ?? []).contains { $0.edit == cmd.id } && !tapCommands.contains(cmd.id)
            let id = cmd.id
            app.commands.register(descriptor) { [weak host] params, ctx in
                guard let handle = host?.handle(pid) else {
                    throw NibError(.unavailable, "plugin \(pid) is not running",
                                   hint: "enable it with plugin.enable or reload it with plugin.reload")
                }
                if editsTypes, params["gesture"]?.stringValue != nil, let ref = params["ref"]?.stringValue {
                    let value = try await handle.invoke(command: id, params: ["ref": .string(ref)], context: ctx)
                    return ContributionMapper.handled(value)
                }
                return try await handle.invoke(command: id, params: params, context: ctx)
            }
        }
    }

    static func descriptor(_ cmd: PluginCommandContribution, owner: String, exposeHidden: Bool) -> CommandDescriptor {
        let effect = cmd.effect.flatMap(Effect.init(rawValue:)) ?? .edit
        let target = cmd.target.flatMap(CommandTarget.init(rawValue:)) ?? .document
        var exposure = Exposure.all
        if !exposeHidden {
            if cmd.ai == false { exposure.remove(.ai) }
            if cmd.bridge == false { exposure.remove(.bridge) }
        }
        return CommandDescriptor(id: cmd.id, title: cmd.title, summary: oneLine(cmd.summary, limit: 200),
                                 params: cmd.params.map(SchemaConverter.schema) ?? .empty, examples: cmd.examples ?? [],
                                 effect: effect, target: target, destructive: cmd.destructive ?? false, exposure: exposure,
                                 owner: owner)
    }

    /// `value` as a tap-handler answer ({handled: true} unless the command said otherwise).
    static func handled(_ value: JSONValue) -> JSONValue {
        if case .object(var o) = value {
            if o["handled"]?.boolValue == nil { o["handled"] = true }
            return .object(o)
        }
        return ["handled": true, "value": value]
    }

    static func oneLine(_ s: String, limit: Int) -> String {
        let flat = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    private func title(of command: String) -> String? {
        contributes?.commands?.first { $0.id == command }?.title ?? app.commands.descriptor(command)?.title
    }

    private func target(of command: String) -> CommandTarget {
        if let d = app.commands.descriptor(command) { return d.target }
        return contributes?.commands?.first { $0.id == command }?.target.flatMap(CommandTarget.init(rawValue:)) ?? .document
    }

    // MARK: Settings

    /// `plugin.<id>.` is declared as a prefix (synced with the library, like the plugin itself); every key of
    /// `contributes.settings` is also declared on its own, so `settings.set` validates it against its schema.
    private func declareSettings() {
        let prefix = PluginSettingsNames.prefix(pid)
        app.settings.declarePrefix(prefix, synced: true, summary: "Settings of the plugin \(manifest.name).", owner: pid)
        guard let properties = contributes?.settings?["properties"]?.objectValue else { return }
        for (key, schema) in properties {
            let field = SchemaField.field(key: key, schema: schema)
            app.settings.declare(SettingKey<JSONValue>(prefix + key, default: field.defaultValue ?? .null, synced: true),
                                 summary: field.help ?? field.title, owner: pid, schema: SchemaConverter.schema(schema))
        }
    }

    private func mapSettingsPage(_ c: PluginContributions?) {
        guard let schema = c?.settings, SchemaConverter.isObjectSchema(schema) else { return }
        let fields = SchemaField.fields(from: schema)
        guard !fields.isEmpty else { return }
        let pid = self.pid
        var page = SettingsPageDescriptor(id: pid + ".settings", title: manifest.name, icon: "puzzlepiece.extension",
                                          section: .plugins, order: 1000, owner: pid) { app in
            AnyView(PluginSettingsForm(app: app, pluginID: pid, fields: fields, style: .page))
        }
        page.keywords = [pid, manifest.name] + fields.map { $0.title }
        app.ui.settingsPages.register(page)
    }

    // MARK: Menus, toolbar, key bindings

    private func mapMenus(_ c: PluginContributions?) {
        for (i, m) in (c?.menus ?? []).enumerated() {
            guard let location = MenuLocation(rawValue: m.location) else { continue }
            let when = m.when
            app.ui.menus.register(MenuItemDescriptor(
                id: "\(pid).menu.\(i)", title: m.title ?? title(of: m.command) ?? m.command, icon: m.icon,
                location: location, order: 1000 + i, owner: pid, command: m.command,
                params: { ctx in MenuParams.build(ctx, location: location) },
                isVisible: { ctx in PluginWhenEvaluator.matches(when, context: ctx) }))
        }
    }

    private func mapToolbar(_ c: PluginContributions?) {
        for (i, t) in (c?.toolbar ?? []).enumerated() {
            let group = t.group.flatMap(ToolbarGroup.init(rawValue:)) ?? (t.tool != nil ? .tools : .accessories)
            let kinds: Set<DocumentKind> = t.tool != nil ? [.notebook, .whiteboard] : Set(DocumentKind.allCases)
            var d = ToolbarItemDescriptor(id: t.id, title: t.title, icon: t.icon, group: group, order: 1000 + i, owner: pid,
                                          toolID: t.tool, command: t.tool == nil ? t.command : nil, docKinds: kinds)
            if let tool = t.tool {
                d.isOn = { session in session.tool == tool }
            } else {
                d.sessionParams = { session in ToolbarParams.from(session) }
            }
            app.ui.toolbar.register(d)
        }
    }

    private func mapKeyBindings(_ c: PluginContributions?) {
        for (i, k) in (c?.keybindings ?? []).enumerated() {
            guard let shortcut = KeyBindingParser.parse(k.key) else { continue }
            let scope = KeyBindingParser.scope(for: shortcut, target: target(of: k.command))
            let keyID = "\(pid).key.\(i)"
            var d = KeyCommandDescriptor(id: keyID, title: k.title ?? title(of: k.command) ?? k.command,
                                         shortcut: shortcut, command: k.command, scope: scope, order: 1000 + i, owner: pid)
            if scope != .global { d.sessionParams = { session in ToolbarParams.from(session) } }
            app.content.keyCommands.register(d)
        }
    }

    // MARK: Canvas tools, options bars, tap handlers, stroke processors, Pencil actions

    private func mapTools(_ c: PluginContributions?) {
        for (i, tool) in (c?.tools ?? []).enumerated() {
            guard let input = PluginToolInput(rawValue: tool.input) else { continue }
            let spec = PluginToolSpec(id: tool.id, pluginID: pid, command: tool.command, input: input,
                                      preview: PluginToolPreview.resolve(tool.preview, input: input),
                                      sticky: tool.sticky ?? true)
            app.ui.canvasTools.register(CanvasToolDescriptor(id: tool.id, title: tool.title, order: 1000 + i, owner: pid) {
                PluginCanvasTool(spec)
            })
        }
        let settings = c?.settings ?? [:]
        for opt in c?.toolOptions ?? [] {
            let fields = SchemaField.fields(from: settings, only: opt.settings)
            let pid = self.pid
            app.ui.toolMenus.register(ToolMenuDescriptor(tool: opt.tool, owner: pid, order: 1000) { [weak app] _ in
                guard let app = app else { return AnyView(EmptyView()) }
                return AnyView(PluginSettingsForm(app: app, pluginID: pid, fields: fields, style: .bar))
            })
        }
    }

    private func mapTapHandlers(_ c: PluginContributions?) {
        for (i, t) in (c?.tapHandlers ?? []).enumerated() {
            guard let gesture = CanvasGesture(rawValue: t.gesture) else { continue }
            var kinds = t.itemKinds.flatMap { list -> Set<ItemKind>? in
                let s = Set(list.compactMap(ItemKind.init(rawValue:)))
                return s.isEmpty ? nil : s
            }
            let keys = t.itemTypes.flatMap { list -> Set<String>? in
                list.isEmpty ? nil : Set(list.map { "custom.\(pid).\($0)" })
            }
            if keys != nil { kinds = (kinds ?? []).union([.custom]) }
            app.content.tapHandlers.register(TapHandlerDescriptor(id: "\(pid).tap.\(i)", owner: pid, gesture: gesture,
                                                                  command: t.command, order: 500 + i, itemKinds: kinds,
                                                                  drawKeys: keys))
        }
    }

    private func mapStrokeProcessors(_ c: PluginContributions?) {
        for (i, s) in (c?.strokeProcessors ?? []).enumerated() {
            let tools = Set((s.tools ?? ["pen", "pencil", "highlighter"]).compactMap(InkTool.init(rawValue:)))
            let processor = PluginStrokeRunner(app: app, host: host, pluginID: pid, id: s.id, command: s.command, tools: tools)
            app.content.strokeProcessors.register(StrokeProcessorEntry(id: s.id, order: PluginStrokeRunner.order + i,
                                                                       owner: pid, processor: processor))
        }
    }

    private func mapPencilActions(_ c: PluginContributions?) {
        for (i, a) in (c?.pencilActions ?? []).enumerated() {
            app.content.pencilActions.register(PencilActionDescriptor(id: "\(pid).pencil.\(i)", title: a.title, owner: pid,
                                                                      command: a.command, gestures: [a.gesture],
                                                                      order: 1000 + i))
        }
    }

    // MARK: Command hooks

    /// A hook runs the plugin's read-only hook command as `.plugin(id)` before every matching call, from anyone, exactly
    /// like a command hook in `bus.hooks`: {command, params} in, `{}` / `{params}` out, a throw vetoes. The host adds
    /// one guard: plugin hooks never see or veto the calls that manage plugins or touch security settings, so a plugin
    /// can never stop the user from disabling it.
    private func mapCommandHooks(_ c: PluginContributions?) {
        let pid = self.pid
        for (i, h) in (c?.commandHooks ?? []).enumerated() {
            let hookCommand = h.command
            var d = CommandHookDescriptor.guarding(id: "\(pid).hook.\(i)", owner: pid, commands: h.commands,
                                                   order: 1000 + i) { command, params, ctx in
                if HookPolicy.isExempt(command, params: params, registry: ctx.bus.registry) { return nil }
                let r = try await ctx.bus.execute(Invocation(command: hookCommand,
                                                             params: ["command": .string(command), "params": params],
                                                             principal: .plugin(pid), session: ctx.session, group: ctx.group,
                                                             dryRun: ctx.dryRun, depth: ctx.depth + 1, readOnly: true,
                                                             inheritedPolicy: ctx.inheritedPolicy, skipHooks: true))
                guard let replaced = r.value["params"], replaced != .null else { return nil }
                return replaced
            }
            d.command = hookCommand
            d.principal = .plugin(pid)
            app.bus.hooks.register(d)
        }
    }

    // MARK: Panels

    private func mapPanels(_ c: PluginContributions?) {
        let manifest = self.manifest
        let folder = self.folder
        for (i, panel) in (c?.panels ?? []).enumerated() {
            let placement = panel.placement.flatMap(PanelPlacement.init(rawValue:)) ?? .floating
            let entry = panel.entry
            let title = panel.title
            var d = PanelDescriptor(id: panel.id, title: title, icon: panel.icon ?? "puzzlepiece.extension",
                                    placement: placement, order: 1000 + i, owner: pid) { context in
                guard let factory = context.app.services.get(ServiceKeys.pluginPanels, as: PluginPanelFactory.self) else {
                    return AnyView(PluginPanelUnavailable(title: title, dismiss: context.dismiss))
                }
                return factory.makePanel(manifest: manifest, folder: folder, entry: entry, context: context)
            }
            // The panel factory (F081) draws NibPluginPanelChrome, so the chrome adds no header of its own.
            d.providesHeader = true
            app.ui.panels.register(d)
        }
    }

    // MARK: Templates

    /// PDF templates are converted once, when the plugin loads (vector paths from the page, text through the PDF
    /// service), so rendering stays a pure DisplayList like every other template.
    private func pdfTemplates() throws -> [String: PDFTemplateConverter.Page] {
        var out: [String: PDFTemplateConverter.Page] = [:]
        for (i, t) in (contributes?.templates ?? []).enumerated() where t.kind == "pdf" {
            let url = try PluginPaths.existing(t.file ?? "", in: folder, path: "$.contributes.templates[\(i)].file")
            guard let page = PDFTemplateConverter.convert(url, text: app.services.pdf?.textBlocks(url, page: 0)) else {
                throw NibError(.invalidParams, "\(t.file ?? "") is not a readable PDF", path: "$.contributes.templates[\(i)].file")
            }
            out[t.id] = page
        }
        return out
    }

    private func mapTemplates(_ c: PluginContributions?, pdfs: [String: PDFTemplateConverter.Page]) {
        for (i, t) in (c?.templates ?? []).enumerated() {
            let params = SpecTemplate.params(t.params)
            let defaults = SpecTemplate.defaults(t.params)
            let category = t.category ?? manifest.name
            switch t.kind {
            case "spec":
                guard let spec = t.spec else { continue }
                let template = SpecTemplate(spec: spec, designSize: t.size, defaults: defaults)
                let cache = TemplateRenderCache()
                app.content.templates.register(TemplateDefinition(
                    id: t.id, title: t.title, category: category, isCover: t.isCover ?? false, order: 1000 + i, owner: pid,
                    params: params, defaults: defaults, preferredSize: t.size) { values, size, _ in
                        cache.render(template, values: values, size: size)
                    })
            case "pdf":
                guard let page = pdfs[t.id] else { continue }
                let design = page.size
                let ops = page.ops
                app.content.templates.register(TemplateDefinition(
                    id: t.id, title: t.title, category: category, isCover: t.isCover ?? false, order: 1000 + i, owner: pid,
                    params: params, defaults: defaults, preferredSize: t.size ?? design) { values, size, _ in
                        let merged = defaults.merging(values) { _, new in new }
                        let paper = merged[TemplateParamNames.paper]?.stringValue.flatMap(RGBA.init(hex:)) ?? .white
                        return TemplateRender(paper: paper, display: DisplayList(ops: SpecTemplate.scaled(ops, from: design, to: size)))
                    })
            default:
                continue
            }
        }
    }

    // MARK: AI

    private func mapAI(_ c: PluginContributions?) {
        for (i, a) in (c?.aiActions ?? []).enumerated() {
            app.content.aiActions.register(AIActionDescriptor(
                id: "\(pid).ai.\(i)", title: a.title, icon: a.icon ?? "text.bubble", prompt: a.prompt,
                scope: a.scope.flatMap(AIScopeKind.init(rawValue:)) ?? .selection,
                mode: a.mode.flatMap(AIMode.init(rawValue:)) ?? .ask, order: 1000 + i, owner: pid))
        }
    }

    // MARK: Importers and exporters

    private func mapFileHandlers(_ c: PluginContributions?) throws {
        for (i, h) in (c?.importers ?? []).enumerated() {
            let command = h.command
            let extensions = h.extensions.map(FileHandlerMapping.normalize)
            let fallbackExtension = extensions.first ?? "bin"
            app.content.importers.register(ImporterDescriptor(
                id: "\(pid).import.\(i)", title: h.title ?? manifest.name, fileExtensions: extensions,
                utTypes: extensions.compactMap { UTType(filenameExtension: $0)?.identifier }, order: 1000 + i,
                owner: pid) { url, target, ctx in
                    try await FileHandlerMapping.runImport(url, target: target, command: command,
                                                           fallbackExtension: fallbackExtension, ctx: ctx)
                })
        }
        for (i, h) in (c?.exporters ?? []).enumerated() {
            let command = h.command
            for ext in h.extensions.map(FileHandlerMapping.normalize) {
                let title = h.title ?? manifest.name
                app.content.exporters.register(ExporterDescriptor(
                    id: "\(pid).export.\(i).\(ext)", title: h.extensions.count > 1 ? "\(title) (.\(ext))" : title,
                    fileExtension: ext, utType: UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier,
                    order: 1000 + i, owner: pid) { request, ctx in
                        try await FileHandlerMapping.runExport(request, command: command, fileExtension: ext, ctx: ctx)
                    })
            }
        }
    }

    // MARK: Custom item types and blocks

    private func mapItemTypes(_ c: PluginContributions?) {
        for (i, t) in (c?.itemTypes ?? []).enumerated() {
            let drawKey = "custom.\(pid).\(t.type)"
            app.content.customItemTypes.register(CustomItemTypeDescriptor(owner: pid, type: t.type, title: t.title,
                                                                          textPath: t.textPath, editCommand: t.edit,
                                                                          order: 1000 + i))
            if let edit = t.edit {
                app.content.tapHandlers.register(TapHandlerDescriptor(id: "\(pid).edit.\(t.type)", owner: pid,
                                                                      gesture: .doubleTap, command: edit, order: 500,
                                                                      itemKinds: [.custom], drawKeys: [drawKey]))
            }
            if let schema = t.inspector, SchemaConverter.isObjectSchema(schema) {
                let fields = SchemaField.fields(from: schema)
                app.ui.inspectors.register(InspectorDescriptor(id: "\(pid).inspector.\(t.type)", title: t.title,
                                                               icon: "slider.horizontal.3", itemKinds: [.custom],
                                                               order: 1000 + i, owner: pid, drawKeys: [drawKey]) { ctx in
                    AnyView(CustomItemInspector(context: ctx, fields: fields))
                })
            }
        }
    }

    private func mapBlocks(_ c: PluginContributions?) {
        for (i, b) in (c?.blocks ?? []).enumerated() {
            let customType = "\(pid).\(b.type)"
            app.content.blockKinds.register(BlockKindDescriptor(id: "\(pid).block.\(b.type)", title: b.title,
                                                                icon: b.icon ?? "square.dashed", kind: .custom, owner: pid,
                                                                order: 1000 + i, customType: customType, command: b.command,
                                                                aliases: b.aliases ?? []))
            let command = b.command
            let title = b.title
            let height = b.height ?? 120
            app.ui.blockViews.register(BlockViewDescriptor(customType: customType, owner: pid, order: 1000 + i) { ctx in
                PluginBlockView(context: ctx, command: command, title: title, defaultHeight: height)
            })
        }
    }

    // MARK: Content packs

    private func mapContentPacks(_ c: PluginContributions?) throws {
        for (i, e) in (c?.elements ?? []).enumerated() {
            let urls = try e.files.enumerated().map { j, f in
                try PluginPaths.existing(f, in: folder, path: "$.contributes.elements[\(i)].files[\(j)]")
            }
            app.content.elementCollections.register(ElementCollectionDescriptor(id: e.id, title: e.title, order: 1000 + i,
                                                                                owner: pid) {
                try ElementPack.load(urls)
            })
        }
        for (i, t) in (c?.tapePatterns ?? []).enumerated() {
            let url = try PluginPaths.existing(t.file, in: folder, path: "$.contributes.tapePatterns[\(i)].file")
            app.content.tapePatterns.register(TapePatternDescriptor(id: t.id, title: t.title, order: 1000 + i, owner: pid) {
                try Data(contentsOf: url)
            })
        }
        for (i, b) in (c?.boardTemplates ?? []).enumerated() {
            let spec: JSONValue
            if let diagram = b.diagram {
                spec = diagram
            } else {
                let url = try PluginPaths.existing(b.file ?? "", in: folder, path: "$.contributes.boardTemplates[\(i)].file")
                guard let data = try? Data(contentsOf: url), let fragment = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    throw NibError(.invalidParams, "\(b.file ?? "") is not JSON", path: "$.contributes.boardTemplates[\(i)].file")
                }
                spec = ["fragment": fragment]
            }
            app.content.boardTemplates.register(BoardTemplateDescriptor(id: b.id, title: b.title,
                                                                        icon: b.icon ?? "rectangle.3.group",
                                                                        order: 1000 + i, owner: pid, spec: spec))
        }
    }
}

// MARK: - Settings names

enum PluginSettingsNames {
    static func prefix(_ pluginID: String) -> String { "plugin.\(pluginID)." }
}

// MARK: - Command hooks policy

enum HookPolicy {
    /// Calls plugin hooks never see: plugin management (`plugin.*`, anything carrying `plugins:manage`), `security`
    /// commands, and settings calls on `security.*` names.
    @MainActor
    static func isExempt(_ command: String, params: JSONValue, registry: CommandRegistry) -> Bool {
        if command.hasPrefix("plugin.") { return true }
        if let d = registry.descriptor(command), d.scopes.contains(.pluginsManage) || d.scopes.contains(.security) {
            return true
        }
        if command.hasPrefix("settings."), params["name"]?.stringValue?.hasPrefix("security.") == true { return true }
        return false
    }
}

// MARK: - JSON Schema → the flat schema

/// Plugin manifests carry standard JSON Schema; commands and settings validate with NibContracts' flat `JSONSchema`.
/// The conversion keeps types, required keys, enums, bounds and descriptions (a default becomes part of the
/// description), so non-user callers get `invalid_params` with a path before the plugin's JavaScript runs.
enum SchemaConverter {
    static func isObjectSchema(_ value: JSONValue) -> Bool {
        guard case .object(let o) = value else { return false }
        if let t = o["type"] { return typeNames(t).contains("object") }
        return o["properties"]?.objectValue != nil
    }

    static func typeNames(_ t: JSONValue) -> [String] {
        switch t {
        case .string(let s): return [s]
        case .array(let a): return a.compactMap { $0.stringValue }
        default: return []
        }
    }

    static func schema(_ value: JSONValue) -> JSONSchema {
        guard case .object(let o) = value else { return .anything() }
        let description = describe(o)
        var types = o["type"].map(typeNames) ?? []
        types.removeAll { $0 == "null" }
        let type = types.first ?? (o["properties"] != nil ? "object" : (o["items"] != nil ? "array" : nil))
        let enumStrings: [String]? = {
            if let e = o["enum"]?.arrayValue {
                let s = e.compactMap { $0.stringValue }
                return s.count == e.count && !s.isEmpty ? s : nil
            }
            return o["const"]?.stringValue.map { [$0] }
        }()
        switch type {
        case "object"?:
            let properties = (o["properties"]?.objectValue ?? [:]).mapValues { schema($0) }
            let required = (o["required"]?.arrayValue ?? []).compactMap { $0.stringValue }
            return .obj(properties, required: required, description)
        case "array"?:
            return .arr(schema(o["items"] ?? [:]), description)
        case "string"?:
            return .str(description, choices: enumStrings)
        case "integer"?:
            return .int(description, min: o["minimum"]?.doubleValue.map { Int($0.rounded(.up)) },
                        max: o["maximum"]?.doubleValue.map { Int($0.rounded(.down)) })
        case "number"?:
            return .num(description, min: o["minimum"]?.doubleValue, max: o["maximum"]?.doubleValue)
        case "boolean"?:
            return .bool(description)
        default:
            if let choices = enumStrings { return .str(description, choices: choices) }
            return .anything(description)
        }
    }

    static func describe(_ o: [String: JSONValue]) -> String? {
        var parts: [String] = []
        if let d = o["description"]?.stringValue ?? o["title"]?.stringValue, !d.isEmpty { parts.append(d) }
        if let f = o["format"]?.stringValue { parts.append("Format: \(f).") }
        if let def = o["default"], def != .null { parts.append("Default: \(def.jsonString()).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Menu context → params, `when`

enum MenuParams {
    /// The menu context as a plugin command's params (docs/PLUGIN_API.md §5.2): {doc, page, point, selection, nodes,
    /// ref, index} plus the library `folder` and a text `range` when the menu has them.
    @MainActor
    static func build(_ ctx: MenuContext, location: MenuLocation) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let d = ctx.doc {
            o["doc"] = .string(NodeRef.document(d).description)
            if let p = ctx.page { o["page"] = .string(NodeRef.page(d, p).description) }
        }
        if let pt = ctx.point { o["point"] = [.number(pt.x), .number(pt.y)] }
        if !ctx.selection.isEmpty { o["selection"] = .array(ctx.selection.refs.map { .string($0) }) }
        if !ctx.nodes.isEmpty { o["nodes"] = .array(ctx.nodes.map { .string(nodeRef($0, ctx, location)) }) }
        if let r = ctx.ref { o["ref"] = .string(r) }
        if let i = ctx.index { o["index"] = .number(Double(i)) }
        if let f = ctx.folder { o["folder"] = .string(NodeRef.folder(f).description) }
        if let r = ctx.textRange { o["range"] = .array(r.map { .number(Double($0)) }) }
        return .object(o)
    }

    /// Sidebar nodes are pages of the menu's document; library nodes are documents or folders.
    @MainActor
    static func nodeRef(_ id: NibID, _ ctx: MenuContext, _ location: MenuLocation) -> String {
        switch location {
        case .sidebarPage, .sidebarSelection:
            if let d = ctx.doc { return NodeRef.page(d, id).description }
        case .libraryItem, .librarySelection, .libraryNew:
            if let node = ctx.app.services.library?.node(id) {
                return node.kind == .folder ? NodeRef.folder(id).description : NodeRef.document(id).description
            }
        default:
            break
        }
        return id.raw
    }
}

enum ToolbarParams {
    /// {doc, page} of the window a toolbar button or key was used in.
    @MainActor
    static func from(_ session: EditorSession) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let d = session.document {
            o["doc"] = .string(NodeRef.document(d).description)
            if let p = session.page { o["page"] = .string(NodeRef.page(d, p).description) }
        }
        return .object(o)
    }
}

/// The structured `when` of a plugin menu entry: `minSelection` (items, or library/sidebar nodes), `selectionKinds`
/// (every selected item is one of these kinds) and `docKinds` (the menu's document is one of these kinds).
enum PluginWhenEvaluator {
    @MainActor
    static func matches(_ when: PluginWhen?, context ctx: MenuContext) -> Bool {
        guard let w = when else { return true }
        let count = ctx.selection.isEmpty ? ctx.nodes.count : ctx.selection.items.count
        return matches(w, selectionCount: count, itemKinds: ctx.itemKinds, docKind: documentKind(ctx))
    }

    static func matches(_ w: PluginWhen, selectionCount: Int, itemKinds: Set<ItemKind>, docKind: DocumentKind?) -> Bool {
        if let n = w.minSelection, selectionCount < n { return false }
        if let kinds = w.selectionKinds, !kinds.isEmpty {
            let allowed = Set(kinds.compactMap(ItemKind.init(rawValue:)))
            guard !itemKinds.isEmpty, itemKinds.isSubset(of: allowed) else { return false }
        }
        if let kinds = w.docKinds, !kinds.isEmpty {
            guard let k = docKind, kinds.contains(k.rawValue) else { return false }
        }
        return true
    }

    @MainActor
    static func documentKind(_ ctx: MenuContext) -> DocumentKind? {
        guard let doc = ctx.doc else { return nil }
        if let k = ctx.app.services.library?.node(doc)?.documentKind { return k }
        guard ctx.app.workspace.isLoaded(doc) else { return nil }
        return try? ctx.app.workspace.content(doc).meta.kind
    }
}

// MARK: - Key bindings

enum KeyBindingParser {
    static let namedKeys: [String: String] = [
        "up": "up", "arrowup": "up", "down": "down", "arrowdown": "down", "left": "left", "arrowleft": "left",
        "right": "right", "arrowright": "right", "escape": "escape", "esc": "escape", "delete": "delete",
        "backspace": "delete", "tab": "tab", "return": "return", "enter": "return", "space": "space"
    ]

    /// "cmd+shift+f", "alt+1", "ctrl+option+left", "cmd++" → a `KeyShortcut`; nil when it is not a binding.
    static func parse(_ text: String) -> KeyShortcut? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        var key: String?
        if s.hasSuffix("++") {
            key = "+"
            s = String(s.dropLast(2))
        } else if s == "+" {
            return KeyShortcut("+")
        }
        let parts = s.isEmpty ? [] : s.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: KeyModifiers = []
        for (i, part) in parts.enumerated() {
            switch part {
            case "cmd", "command", "meta", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "alt", "option", "opt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default:
                guard i == parts.count - 1, key == nil else { return nil }
                if let named = namedKeys[part] {
                    key = named
                } else if part.count == 1 {
                    key = part
                } else {
                    return nil
                }
            }
        }
        guard let k = key else { return nil }
        return KeyShortcut(k, modifiers)
    }

    /// A key without ⌘, ⌥ or ⌃ only works on the canvas (typing keeps plain keys); others follow the command's
    /// target (document commands while a document is open, library and app commands everywhere).
    static func scope(for shortcut: KeyShortcut, target: CommandTarget) -> KeyScope {
        if shortcut.modifiers.isDisjoint(with: [.command, .option, .control]) { return .canvas }
        return target == .document ? .document : .global
    }
}

// MARK: - Spec templates

/// A `kind: "spec"` template: a DisplayList with `"$name"` strings replaced by parameter values (defaults merged
/// under the page's params), scaled from its design size to the page.
struct SpecTemplate {
    var spec: JSONValue
    var designSize: PageSize?
    var defaults: [String: JSONValue]

    static let paramKinds: Set<String> = ["number", "color", "choice", "bool"]

    func render(values: [String: JSONValue], size: PageSize) -> TemplateRender {
        let merged = defaults.merging(values) { _, new in new }
        let resolved = SpecTemplate.substitute(spec, merged)
        let paper = resolved["paper"]?.stringValue.flatMap(RGBA.init(hex:)) ?? .white
        let ops = SpecTemplate.decodeOps(resolved["ops"] ?? [])
        let scaled = designSize.map { SpecTemplate.scaled(ops, from: $0, to: size) } ?? ops
        return TemplateRender(paper: paper, display: DisplayList(ops: scaled))
    }

    /// The first op that does not decode with the default params (validation).
    func invalidOp() -> (index: Int, reason: String)? {
        let resolved = SpecTemplate.substitute(spec, defaults)
        for (i, op) in (resolved["ops"]?.arrayValue ?? []).enumerated() {
            do {
                _ = try op.decode(DisplayOp.self)
            } catch let e as DecodingError {
                return (i, ManifestErrors.describe(e))
            } catch {
                return (i, error.localizedDescription)
            }
        }
        return nil
    }

    /// Every string that is exactly "$name" becomes the parameter's value (unknown names stay as they are).
    static func substitute(_ value: JSONValue, _ params: [String: JSONValue]) -> JSONValue {
        switch value {
        case .string(let s):
            if s.hasPrefix("$"), s.count > 1, let v = params[String(s.dropFirst())] { return v }
            return value
        case .array(let a):
            return .array(a.map { substitute($0, params) })
        case .object(let o):
            return .object(o.mapValues { substitute($0, params) })
        default:
            return value
        }
    }

    /// Ops that decode; invalid ones are left out (validation already reported them).
    static func decodeOps(_ ops: JSONValue) -> [DisplayOp] {
        (ops.arrayValue ?? []).compactMap { try? $0.decode(DisplayOp.self) }
    }

    /// Positions scale per axis to the page; widths, fonts, dashes and radii by the smaller factor; line spacing by the
    /// axis it repeats along.
    static func scaled(_ ops: [DisplayOp], from design: PageSize, to size: PageSize) -> [DisplayOp] {
        guard design.width > 0, design.height > 0, size.width > 0, size.height > 0 else { return ops }
        let sx = size.width / design.width
        let sy = size.height / design.height
        if abs(sx - 1) < 1e-9 && abs(sy - 1) < 1e-9 { return ops }
        let s = min(sx, sy)
        return ops.map { op in
            var o = op
            if let r = op.rect { o.rect = Rect(x: r.x * sx, y: r.y * sy, width: r.width * sx, height: r.height * sy) }
            if let pts = op.points { o.points = pts.map { Point($0.x * sx, $0.y * sy) } }
            if let w = op.width { o.width = w * s }
            if let d = op.dash { o.dash = d.map { $0 * s } }
            if let f = op.fontSize { o.fontSize = f * s }
            if let r = op.radius { o.radius = r * s }
            if let sp = op.spacing {
                switch op.op {
                case .hlines: o.spacing = sp * sy
                case .vlines: o.spacing = sp * sx
                default: o.spacing = sp * s
                }
            }
            return o
        }
    }

    /// {"name": {"type": "number|color|choice|bool", "default": …, "choices": […], "title"?, "min"?, "max"?}}.
    static func params(_ params: JSONValue?) -> [TemplateParam] {
        guard let o = params?.objectValue else { return [] }
        return o.keys.sorted().compactMap { name in
            guard let p = o[name]?.objectValue, let kind = p["type"]?.stringValue, paramKinds.contains(kind) else { return nil }
            let choices = p["choices"]?.arrayValue?.compactMap { $0.stringValue }
            return TemplateParam(name: name, title: p["title"]?.stringValue ?? name, kind: kind, choices: choices,
                                 minimum: (p["minimum"] ?? p["min"])?.doubleValue,
                                 maximum: (p["maximum"] ?? p["max"])?.doubleValue)
        }
    }

    static func defaults(_ params: JSONValue?) -> [String: JSONValue] {
        guard let o = params?.objectValue else { return [:] }
        var out: [String: JSONValue] = [:]
        for (name, p) in o {
            if let d = p["default"], d != .null { out[name] = d }
        }
        return out
    }

    static func paramProblems(_ params: JSONValue?, path: String) -> [NibError] {
        guard let params = params else { return [] }
        guard let o = params.objectValue else { return [NibError.invalid("params must be an object", path: path)] }
        var out: [NibError] = []
        for name in o.keys.sorted() {
            let p = "\(path).\(name)"
            guard let def = o[name]?.objectValue, let kind = def["type"]?.stringValue, paramKinds.contains(kind) else {
                out.append(NibError.invalid("a template param has type number, color, choice or bool", path: p + ".type"))
                continue
            }
            if kind == "choice", (def["choices"]?.arrayValue ?? []).isEmpty {
                out.append(NibError.invalid("a choice param lists its choices", path: p + ".choices"))
            }
            if kind == "color", let d = def["default"]?.stringValue, RGBA(hex: d) == nil {
                out.append(NibError.invalid("the default colour is #RRGGBB or #RRGGBBAA", path: p + ".default"))
            }
        }
        return out
    }
}

/// Keeps the last few renders of a spec template (per params and size). Thread-safe: templates render on tile threads.
final class TemplateRenderCache {
    private let lock = NSLock()
    private var entries: [String: TemplateRender] = [:]
    private var order: [String] = []
    let capacity = 16

    func render(_ template: SpecTemplate, values: [String: JSONValue], size: PageSize) -> TemplateRender {
        let key = JSONValue.object(values).jsonString() + "|\(size.width)x\(size.height)"
        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let r = template.render(values: values, size: size)
        lock.lock()
        if entries[key] == nil {
            entries[key] = r
            order.append(key)
            if order.count > capacity { entries[order.removeFirst()] = nil }
        }
        lock.unlock()
        return r
    }
}

// MARK: - PDF templates

/// Turns the first page of a template PDF into a DisplayList: filled and stroked paths (lines, rectangles, curves
/// flattened; form XObjects followed) from the page's content stream, and text lines from the PDF service. Images and
/// shadings are left out; the page keeps the paper colour under them.
final class PDFTemplateConverter {
    struct Page: Equatable {
        var size: PageSize
        var ops: [DisplayOp]
    }

    static let maxOps = 20_000
    static let curveSegments = 8
    static let maxFormDepth = 8

    private struct GState {
        var ctm = CGAffineTransform.identity
        var stroke = RGBA(0, 0, 0)
        var fill = RGBA(0, 0, 0)
        var lineWidth: CGFloat = 1
        var dash: [CGFloat]?
    }

    private let base: CGAffineTransform
    private var table: CGPDFOperatorTableRef?
    private var state = GState()
    private var stack: [GState] = []
    private var subpaths: [(points: [CGPoint], closed: Bool)] = []
    private var current: [CGPoint] = []
    private var formDepth = 0
    private(set) var ops: [DisplayOp] = []

    private init(base: CGAffineTransform) {
        self.base = base
    }

    /// Page 1 of `url` in page points (top-left origin, the page's /Rotate applied); nil when it is not a PDF.
    static func convert(_ url: URL, text: [TextRecognition]?) -> Page? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = rotation % 180 == 0 ? PageSize(Double(box.width), Double(box.height))
                                       : PageSize(Double(box.height), Double(box.width))
        let target = CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height))
        let drawing = page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(size.height))
        let converter = PDFTemplateConverter(base: drawing.concatenating(flip))
        converter.scan(page)
        var ops = converter.ops
        for block in text ?? [] {
            let t = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, block.bbox.height > 0, ops.count < maxOps else { continue }
            let fontSize = max(4, min(72, block.bbox.height * 0.8))
            ops.append(DisplayOp(op: .text, rect: Rect(x: block.bbox.x, y: block.bbox.y,
                                                       width: block.bbox.width * 1.05 + 2, height: block.bbox.height * 1.2),
                                 fill: RGBA(0, 0, 0), text: t, fontSize: fontSize))
        }
        return Page(size: size, ops: ops)
    }

    private func scan(_ page: CGPDFPage) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        self.table = table
        PDFTemplateConverter.install(table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        self.table = nil
    }

    // MARK: Operators

    private static func with(_ info: UnsafeMutableRawPointer?, _ body: (PDFTemplateConverter) -> Void) {
        guard let info = info else { return }
        let c = Unmanaged<PDFTemplateConverter>.fromOpaque(info).takeUnretainedValue()
        guard c.ops.count < maxOps else { return }
        body(c)
    }

    /// `n` numbers from the operand stack, in operand order.
    private static func numbers(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
        var out = [CGFloat](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &v) else { return nil }
            out[i] = v
        }
        return out
    }

    /// Every number left on the operand stack, in operand order (colour operators with 1, 3 or 4 components).
    private static func allNumbers(_ s: CGPDFScannerRef) -> [CGFloat] {
        var out: [CGFloat] = []
        var v: CGPDFReal = 0
        while out.count < 8, CGPDFScannerPopNumber(s, &v) { out.insert(v, at: 0) }
        return out
    }

    private static func color(_ c: [CGFloat]) -> RGBA? {
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        switch c.count {
        case 1: return RGBA(byte(c[0]), byte(c[0]), byte(c[0]))
        case 3: return RGBA(byte(c[0]), byte(c[1]), byte(c[2]))
        case 4:
            let k = 1 - c[3]
            return RGBA(byte((1 - c[0]) * k), byte((1 - c[1]) * k), byte((1 - c[2]) * k))
        default: return nil
        }
    }

    /// Operator names are static C strings, so the table may keep the pointer.
    private static func set(_ t: CGPDFOperatorTableRef, _ name: StaticString, _ callback: @escaping CGPDFOperatorCallback) {
        CGPDFOperatorTableSetCallback(t, UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: CChar.self), callback)
    }

    // swiftlint:disable:next function_body_length
    private static func install(_ t: CGPDFOperatorTableRef) {
        PDFTemplateConverter.set(t, "q") { _, info in PDFTemplateConverter.with(info) { $0.stack.append($0.state) } }
        PDFTemplateConverter.set(t, "Q") { _, info in
            PDFTemplateConverter.with(info) { c in if let s = c.stack.popLast() { c.state = s } }
        }
        PDFTemplateConverter.set(t, "cm") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 6) else { return }
                c.state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(c.state.ctm)
            }
        }
        PDFTemplateConverter.set(t, "w") { s, info in
            PDFTemplateConverter.with(info) { c in if let n = PDFTemplateConverter.numbers(s, 1) { c.state.lineWidth = n[0] } }
        }
        PDFTemplateConverter.set(t, "d") { s, info in
            PDFTemplateConverter.with(info) { c in
                var phase: CGPDFReal = 0
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopNumber(s, &phase), CGPDFScannerPopArray(s, &array), let a = array else { return }
                var dash: [CGFloat] = []
                for i in 0..<CGPDFArrayGetCount(a) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(a, i, &v) { dash.append(v) }
                }
                c.state.dash = dash.isEmpty || dash.allSatisfy({ $0 == 0 }) ? nil : dash
            }
        }
        for name in ["RG", "G", "K", "SC", "SCN"] as [StaticString] {
            PDFTemplateConverter.set(t, name) { s, info in
                PDFTemplateConverter.with(info) { c in
                    if let color = PDFTemplateConverter.color(PDFTemplateConverter.allNumbers(s)) { c.state.stroke = color }
                }
            }
        }
        for name in ["rg", "g", "k", "sc", "scn"] as [StaticString] {
            PDFTemplateConverter.set(t, name) { s, info in
                PDFTemplateConverter.with(info) { c in
                    if let color = PDFTemplateConverter.color(PDFTemplateConverter.allNumbers(s)) { c.state.fill = color }
                }
            }
        }
        PDFTemplateConverter.set(t, "m") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 2) else { return }
                c.flush()
                c.current = [c.point(n[0], n[1])]
            }
        }
        PDFTemplateConverter.set(t, "l") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 2) else { return }
                c.current.append(c.point(n[0], n[1]))
            }
        }
        PDFTemplateConverter.set(t, "c") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 6) else { return }
                c.curve(c.point(n[0], n[1]), c.point(n[2], n[3]), c.point(n[4], n[5]))
            }
        }
        PDFTemplateConverter.set(t, "v") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 4), let start = c.current.last else { return }
                c.curve(start, c.point(n[0], n[1]), c.point(n[2], n[3]))
            }
        }
        PDFTemplateConverter.set(t, "y") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 4) else { return }
                let end = c.point(n[2], n[3])
                c.curve(c.point(n[0], n[1]), end, end)
            }
        }
        PDFTemplateConverter.set(t, "h") { _, info in PDFTemplateConverter.with(info) { $0.closeCurrent() } }
        PDFTemplateConverter.set(t, "re") { s, info in
            PDFTemplateConverter.with(info) { c in
                guard let n = PDFTemplateConverter.numbers(s, 4) else { return }
                c.flush()
                c.subpaths.append(([c.point(n[0], n[1]), c.point(n[0] + n[2], n[1]), c.point(n[0] + n[2], n[1] + n[3]),
                                    c.point(n[0], n[1] + n[3])], true))
            }
        }
        PDFTemplateConverter.set(t, "S") { _, info in PDFTemplateConverter.with(info) { $0.paint(fill: false, stroke: true) } }
        PDFTemplateConverter.set(t, "s") { _, info in
            PDFTemplateConverter.with(info) { c in
                c.closeCurrent()
                c.paint(fill: false, stroke: true)
            }
        }
        for name in ["f", "F", "f*"] as [StaticString] {
            PDFTemplateConverter.set(t, name) { _, info in PDFTemplateConverter.with(info) { $0.paint(fill: true, stroke: false) } }
        }
        for name in ["B", "B*"] as [StaticString] {
            PDFTemplateConverter.set(t, name) { _, info in PDFTemplateConverter.with(info) { $0.paint(fill: true, stroke: true) } }
        }
        for name in ["b", "b*"] as [StaticString] {
            PDFTemplateConverter.set(t, name) { _, info in
                PDFTemplateConverter.with(info) { c in
                    c.closeCurrent()
                    c.paint(fill: true, stroke: true)
                }
            }
        }
        PDFTemplateConverter.set(t, "n") { _, info in
            PDFTemplateConverter.with(info) { c in
                c.current = []
                c.subpaths = []
            }
        }
        PDFTemplateConverter.set(t, "Do") { s, info in PDFTemplateConverter.with(info) { $0.drawForm(s) } }
    }

    // MARK: Paths

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y).applying(state.ctm).applying(base)
    }

    private func flush() {
        if current.count >= 2 { subpaths.append((current, false)) }
        current = []
    }

    private func closeCurrent() {
        if current.count >= 2 {
            subpaths.append((current, true))
            current = [current[0]]
        } else if var last = subpaths.popLast() {
            last.closed = true
            subpaths.append(last)
        }
    }

    private func curve(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) {
        guard let start = current.last else {
            current = [end]
            return
        }
        let n = PDFTemplateConverter.curveSegments
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let u = 1 - t
            let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
            let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
            current.append(CGPoint(x: x, y: y))
        }
    }

    private func paint(fill: Bool, stroke: Bool) {
        flush()
        defer { subpaths = [] }
        let total = state.ctm.concatenating(base)
        let scale = sqrt(abs(total.a * total.d - total.b * total.c))
        let width = Double(max(state.lineWidth * scale, 0.25))
        let dash = state.dash.map { $0.map { Double($0 * scale) } }
        for sub in subpaths where sub.points.count >= 2 && ops.count < PDFTemplateConverter.maxOps {
            let pts = sub.points.map { Point(Double($0.x), Double($0.y)) }
            if fill || sub.closed {
                let strokeColor = stroke ? state.stroke : nil
                let fillColor = fill ? state.fill : nil
                if let r = PDFTemplateConverter.axisAlignedRect(pts) {
                    ops.append(DisplayOp(op: .rect, rect: r, stroke: strokeColor, fill: fillColor,
                                         width: stroke ? width : nil, dash: stroke ? dash : nil))
                } else {
                    ops.append(DisplayOp(op: .polygon, points: pts, stroke: strokeColor, fill: fillColor,
                                         width: stroke ? width : nil, dash: stroke ? dash : nil))
                }
            } else if stroke {
                ops.append(DisplayOp(op: pts.count == 2 ? .line : .polyline, points: pts, stroke: state.stroke, width: width,
                                     dash: dash))
            }
        }
    }

    /// A closed four-corner path that is an axis-aligned rectangle.
    static func axisAlignedRect(_ pts: [Point]) -> Rect? {
        var p = pts
        if p.count == 5, let f = p.first, let l = p.last, abs(f.x - l.x) < 0.01, abs(f.y - l.y) < 0.01 { p.removeLast() }
        guard p.count == 4 else { return nil }
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            guard abs(a.x - b.x) < 0.01 || abs(a.y - b.y) < 0.01 else { return nil }
        }
        guard let r = Rect.bounding(p), r.width > 0.01, r.height > 0.01 else { return nil }
        return r
    }

    // MARK: Form XObjects

    private func drawForm(_ s: CGPDFScannerRef) {
        guard formDepth < PDFTemplateConverter.maxFormDepth, let table = table else { return }
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(s, &name), let n = name else { return }
        let parent = CGPDFScannerGetContentStream(s)
        guard let object = CGPDFContentStreamGetResource(parent, "XObject", n) else { return }
        var streamRef: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let st = subtype, String(cString: st) == "Form" else { return }
        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &array), let a = array, CGPDFArrayGetCount(a) == 6 {
            var m = [CGFloat](repeating: 0, count: 6)
            for i in 0..<6 {
                var v: CGPDFReal = 0
                _ = CGPDFArrayGetNumber(a, i, &v)
                m[i] = v
            }
            matrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        }
        var resources: CGPDFDictionaryRef?
        let formResources = CGPDFDictionaryGetDictionary(dict, "Resources", &resources) ? resources : nil
        let content = CGPDFContentStreamCreateWithStream(stream, formResources ?? dict, parent)
        let saved = state
        let savedStack = stack
        let savedPath = (subpaths, current)
        state.ctm = matrix.concatenating(state.ctm)
        subpaths = []
        current = []
        formDepth += 1
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        formDepth -= 1
        state = saved
        stack = savedStack
        (subpaths, current) = savedPath
    }
}

// MARK: - Importers and exporters

enum FileHandlerMapping {
    /// "APKG" / ".apkg" → "apkg".
    static func normalize(_ ext: String) -> String {
        var e = ext.trimmingCharacters(in: .whitespaces).lowercased()
        while e.hasPrefix(".") { e.removeFirst() }
        return e
    }

    /// File → temporary asset → the plugin command {asset, name, target: {folder?, doc?, position, anchor?, ids?}};
    /// returns the documents it created or changed (from `refs` / `ref` / `docs` in the result, else the target).
    @MainActor
    static func runImport(_ url: URL, target: ImportTarget, command: String, fallbackExtension: String,
                          ctx: CommandContext) async throws -> [DocumentID] {
        guard let assets = ctx.services.assets else { throw NibError.unavailable("temporary assets") }
        let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            guard size <= NibLimits.maxDownloadBytes else {
                throw NibError(.invalidParams, "the file is larger than \(NibLimits.maxDownloadBytes / 1_048_576) MB")
            }
            return try Data(contentsOf: url)
        }.value
        let ext = url.pathExtension.isEmpty ? fallbackExtension : normalize(url.pathExtension)
        let ref = try assets.putTemporary(data, ext: ext)
        var t: [String: JSONValue] = ["position": .string(target.position.rawValue)]
        if let f = target.folder { t["folder"] = .string(NodeRef.folder(f).description) }
        if let d = target.document {
            t["doc"] = .string(NodeRef.document(d).description)
            if let a = target.anchorPage { t["anchor"] = .string(NodeRef.page(d, a).description) }
        }
        if let ids = target.ids { t["ids"] = .array(ids.map { .string($0.raw) }) }
        let name = target.displayName ?? url.deletingPathExtension().lastPathComponent
        let result = try await ctx.execute(command, ["asset": .string("tmp:" + ref.name), "name": .string(name),
                                                     "target": .object(t)])
        let docs = documents(in: result)
        if !docs.isEmpty { return docs }
        return target.document.map { [$0] } ?? []
    }

    /// Document ids named by an importer's result: `refs`, `ref`, `docs` or `documents` (any node ref counts for its
    /// document), in order, without duplicates.
    static func documents(in result: JSONValue) -> [DocumentID] {
        var strings: [String] = []
        for key in ["refs", "docs", "documents"] {
            strings += result[key]?.arrayValue?.compactMap { $0.stringValue } ?? []
        }
        if let r = result["ref"]?.stringValue { strings.insert(r, at: 0) }
        if let d = result["doc"]?.stringValue { strings.append(d) }
        var seen = Set<DocumentID>()
        var out: [DocumentID] = []
        for s in strings {
            let id: DocumentID?
            if let ref = NodeRef(s) {
                id = ref.documentID
            } else {
                id = NibID.isValid(s) ? NibID(s) : nil
            }
            if let d = id, seen.insert(d).inserted { out.append(d) }
        }
        return out
    }

    /// The plugin command {docs, pages?, options, fileName?} → {files: [{name, base64 | text}]} written to a fresh
    /// temporary folder.
    @MainActor
    static func runExport(_ request: ExportRequest, command: String, fileExtension: String,
                          ctx: CommandContext) async throws -> [URL] {
        var p: [String: JSONValue] = ["docs": .array(request.documents.map { .string(NodeRef.document($0).description) }),
                                      "options": request.options]
        if let pages = request.pages {
            if request.documents.count == 1, let doc = request.documents.first {
                p["pages"] = .array(pages.map { .string(NodeRef.page(doc, $0).description) })
            } else {
                p["pages"] = .array(pages.map { .string($0.raw) })
            }
        }
        if let name = request.fileName { p["fileName"] = .string(name) }
        let result = try await ctx.execute(command, .object(p))
        return try writeFiles(result, defaultName: request.fileName ?? "Export", fileExtension: fileExtension)
    }

    static func writeFiles(_ result: JSONValue, defaultName: String, fileExtension: String) throws -> [URL] {
        guard let files = result["files"]?.arrayValue, !files.isEmpty else {
            throw NibError(.invalidParams, "the exporter returned no files", path: "$.files",
                           hint: "return {files: [{name, base64}]}")
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("nib-plugin-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        var used = Set<String>()
        for (i, f) in files.enumerated() {
            let data: Data
            if let b64 = f["base64"]?.stringValue {
                guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    throw NibError.invalid("file \(i) is not valid base64", path: "$.files[\(i)].base64")
                }
                data = d
            } else if let text = f["text"]?.stringValue {
                data = Data(text.utf8)
            } else {
                throw NibError.invalid("file \(i) needs base64 or text", path: "$.files[\(i)]")
            }
            var name = safeName(f["name"]?.stringValue ?? "", fallback: files.count > 1 ? "\(defaultName) \(i + 1)" : defaultName)
            if (name as NSString).pathExtension.isEmpty { name += "." + fileExtension }
            while !used.insert(name.lowercased()).inserted {
                name = (name as NSString).deletingPathExtension + " \(i + 1)." + (name as NSString).pathExtension
            }
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    /// A plain file name: no folders, no leading dot, no control characters.
    static func safeName(_ name: String, fallback: String) -> String {
        let last = (name as NSString).lastPathComponent
        var cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            cleaned = String(fallback.unicodeScalars.filter { $0 != "/" && $0 != "\\" && $0 != ":" })
        }
        return String(cleaned.prefix(200))
    }
}

// MARK: - Element collections

enum ElementPack {
    /// Each file is one clipboard fragment ({format: "nib-fragment/1", …}; id = file name) or an array of
    /// {id, title, fragment}.
    static func load(_ urls: [URL]) throws -> [ElementEntry] {
        var out: [ElementEntry] = []
        var ids = Set<String>()
        for url in urls {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            let stem = url.deletingPathExtension().lastPathComponent
            if let list = value.arrayValue {
                for (i, e) in list.enumerated() {
                    guard let fragment = e["fragment"] else { continue }
                    let id = e["id"]?.stringValue ?? "\(stem)-\(i + 1)"
                    guard ids.insert(id).inserted else { continue }
                    out.append(ElementEntry(id: id, title: e["title"]?.stringValue ?? id, fragment: fragment))
                }
            } else if case .object = value {
                guard ids.insert(stem).inserted else { continue }
                let title = value["title"]?.stringValue ?? stem.replacingOccurrences(of: "-", with: " ").capitalized
                out.append(ElementEntry(id: stem, title: title, fragment: value))
            }
        }
        return out
    }
}

// MARK: - Forms (settings pages, tool options bars, custom item inspectors)

/// One control of an auto-generated form, from a JSON Schema property.
struct SchemaField: Identifiable, Equatable {
    enum Kind: Equatable {
        case toggle
        case text
        case choice([String])
        case number(min: Double?, max: Double?, integer: Bool)
        case color
        case json
    }

    var id: String { key }
    var key: String
    var title: String
    var help: String?
    var kind: Kind
    var defaultValue: JSONValue?

    static func field(key: String, schema: JSONValue) -> SchemaField {
        let o = schema.objectValue ?? [:]
        var types = o["type"].map(SchemaConverter.typeNames) ?? []
        types.removeAll { $0 == "null" }
        let choices = o["enum"]?.arrayValue?.compactMap { $0.stringValue }
        let kind: Kind
        switch types.first {
        case "boolean"?:
            kind = .toggle
        case "string"?:
            if let c = choices, !c.isEmpty {
                kind = .choice(c)
            } else if ["color", "colour"].contains(o["format"]?.stringValue ?? "") {
                kind = .color
            } else {
                kind = .text
            }
        case "number"?, "integer"?:
            kind = .number(min: o["minimum"]?.doubleValue, max: o["maximum"]?.doubleValue, integer: types.first == "integer")
        case nil where !(choices ?? []).isEmpty:
            kind = .choice(choices ?? [])
        default:
            kind = .json
        }
        let title = o["title"]?.stringValue ?? key.prefix(1).uppercased() + key.dropFirst()
        return SchemaField(key: key, title: title, help: o["description"]?.stringValue, kind: kind,
                           defaultValue: o["default"].flatMap { $0 == .null ? nil : $0 })
    }

    /// The properties of an object schema as fields: `only` keeps those keys in that order; otherwise by the
    /// properties' optional "order", then title.
    static func fields(from schema: JSONValue, only keys: [String]? = nil) -> [SchemaField] {
        let properties = schema["properties"]?.objectValue ?? [:]
        if let keys = keys {
            return keys.compactMap { k in properties[k].map { field(key: k, schema: $0) } }
        }
        return properties.map { (k, v) in (v["order"]?.doubleValue ?? .infinity, field(key: k, schema: v)) }
            .sorted { ($0.0, $0.1.title, $0.1.key) < ($1.0, $1.1.title, $1.1.key) }
            .map { $0.1 }
    }
}

enum SchemaFormStyle { case page, bar, inspector }

/// A form over JSON values: toggles, pickers, sliders (bounded numbers), text fields, colour wells and a JSON editor.
/// Text and number fields commit on Return; sliders when released; colours after a short pause.
struct SchemaFormView: View {
    let fields: [SchemaField]
    let values: [String: JSONValue]
    let style: SchemaFormStyle
    let commit: (String, JSONValue) -> Void

    var body: some View {
        switch style {
        case .page:
            Form {
                ForEach(fields) { f in
                    Section {
                        SchemaFieldControl(field: f, value: values[f.key] ?? f.defaultValue, compact: false, commit: commit)
                    } footer: {
                        if let help = f.help { Text(verbatim: help) }
                    }
                }
            }
        case .inspector:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(fields) { f in
                    SchemaFieldControl(field: f, value: values[f.key] ?? f.defaultValue, compact: false, commit: commit)
                }
            }
            .padding()
        case .bar:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(fields) { f in
                        SchemaFieldControl(field: f, value: values[f.key] ?? f.defaultValue, compact: true, commit: commit)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct SchemaFieldControl: View {
    let field: SchemaField
    let value: JSONValue?
    let compact: Bool
    let commit: (String, JSONValue) -> Void
    @State private var draft = ""
    @State private var number: Double = 0
    @State private var colour = Color.black
    @State private var invalid = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        control
            .onAppear(perform: load)
            .onChange(of: value) { _, _ in load() }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value?.boolValue ?? false }, set: { commit(field.key, .bool($0)) })) {
                Text(verbatim: field.title)
            }
            .fixedSize(horizontal: compact, vertical: false)
        case .choice(let choices):
            Picker(selection: Binding(get: { value?.stringValue ?? choices.first ?? "" },
                                      set: { commit(field.key, .string($0)) })) {
                ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
            } label: {
                Text(verbatim: field.title)
            }
        case let .number(min, max, integer):
            if let lo = min, let hi = max, hi > lo {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: field.title)
                        Spacer()
                        Text(verbatim: format(number, integer: integer)).monospacedDigit()
                    }
                    Slider(value: $number, in: lo...hi, step: integer ? 1 : (hi - lo) / 100) { editing in
                        if !editing { commit(field.key, .number(integer ? number.rounded() : number)) }
                    }
                    .accessibilityLabel(Text(verbatim: field.title))
                    .accessibilityValue(Text(verbatim: format(number, integer: integer)))
                }
                .frame(minWidth: compact ? 180 : nil)
            } else {
                textField(keyboard: .numbersAndPunctuation) {
                    guard let n = Double(draft.replacingOccurrences(of: ",", with: ".")) else { return nil }
                    if let lo = min, n < lo { return nil }
                    if let hi = max, n > hi { return nil }
                    return .number(integer ? n.rounded() : n)
                }
            }
        case .text:
            textField(keyboard: .default) { .string(draft) }
        case .color:
            ColorPicker(selection: Binding(get: { colour }, set: { newValue in
                colour = newValue
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    commit(field.key, .string(RGBA(UIColor(newValue)).hex))
                }
            }), supportsOpacity: true) {
                Text(verbatim: field.title)
            }
            .fixedSize(horizontal: compact, vertical: false)
        case .json:
            textField(keyboard: .default) { try? JSONValue.parse(draft) }
        }
    }

    private func textField(keyboard: UIKeyboardType, parse: @escaping () -> JSONValue?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact { Text(verbatim: field.title) }
            TextField(text: $draft, axis: field.kind == .json ? .vertical : .horizontal) {
                Text(verbatim: field.title)
            }
            .keyboardType(keyboard)
            .submitLabel(.done)
            .autocorrectionDisabled(field.kind != .text)
            .textInputAutocapitalization(field.kind == .text ? .sentences : .never)
            .onSubmit {
                guard let v = parse() else {
                    invalid = true
                    return
                }
                invalid = false
                commit(field.key, v)
            }
            .frame(minWidth: compact ? 120 : nil)
            if invalid {
                Text(String(localized: "This value is not valid.")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        invalid = false
        switch field.kind {
        case .number:
            number = value?.doubleValue ?? 0
            draft = value?.doubleValue.map { format($0, integer: false) } ?? ""
        case .text:
            draft = value?.stringValue ?? ""
        case .json:
            draft = value.map { $0.jsonString(pretty: true) } ?? ""
        case .color:
            colour = Color(uiColor: (value?.stringValue.flatMap(RGBA.init(hex:)) ?? RGBA(0, 0, 0)).uiColor)
        case .toggle, .choice:
            break
        }
    }

    private func format(_ n: Double, integer: Bool) -> String {
        if integer || n == n.rounded() { return String(Int(n.rounded())) }
        return String(format: "%.2f", n)
    }
}

/// The auto-generated settings page (and tool options bar) of a plugin: values are the settings
/// "plugin.<id>.<key>", written with `settings.set` like any other setting.
struct PluginSettingsForm: View {
    let app: NibApp
    let pluginID: String
    let fields: [SchemaField]
    let style: SchemaFormStyle
    @State private var values: [String: JSONValue] = [:]

    var body: some View {
        SchemaFormView(fields: fields, values: values, style: style) { key, value in
            values[key] = value
            app.perform(CommandIDs.settingsSet, ["name": .string(PluginSettingsNames.prefix(pluginID) + key), "value": value])
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { note in
            if (note.userInfo?["name"] as? String)?.hasPrefix(PluginSettingsNames.prefix(pluginID)) == true { reload() }
        }
    }

    private func reload() {
        var out: [String: JSONValue] = [:]
        for f in fields {
            out[f.key] = app.settings.json(PluginSettingsNames.prefix(pluginID) + f.key) ?? f.defaultValue
        }
        values = out
    }
}

/// The inspector of a plugin's custom item type: a form over `data`; a change goes through `item.update` for every
/// selected item of the type, as one undo step.
struct CustomItemInspector: View {
    let context: InspectorContext
    let fields: [SchemaField]

    var body: some View {
        SchemaFormView(fields: fields, values: context.items.first?.custom?.data.objectValue ?? [:], style: .inspector) { key, value in
            CustomItemInspector.write(key, value, context)
        }
    }

    @MainActor
    static func write(_ key: String, _ value: JSONValue, _ context: InspectorContext) {
        let app = context.app
        let group = NibID.make().raw
        let ids = context.items.filter { $0.kind == .custom }.map { $0.id }
        Task { @MainActor in
            for id in ids {
                // The current item, not the inspector's snapshot, so quick successive edits all land.
                guard let item = try? app.workspace.item(context.doc, page: context.page, id: id),
                      var custom = item.custom else { continue }
                custom.data = CustomItemInspector.updated(custom.data, key: key, value: value)
                do {
                    let patch: JSONValue = ["custom": try JSONValue.from(custom)]
                    _ = try await app.bus.execute(Invocation(command: CommandIDs.itemUpdate,
                                                             params: ["ref": .string(NodeRef.item(context.doc, context.page, id).description),
                                                                      "patch": patch],
                                                             session: context.session, group: group))
                } catch {
                    NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                    userInfo: ["command": CommandIDs.itemUpdate, "error": NibError.wrap(error)])
                    return
                }
            }
        }
    }

    static func updated(_ data: JSONValue, key: String, value: JSONValue) -> JSONValue {
        var o = data.objectValue ?? [:]
        o[key] = value
        return .object(o)
    }
}

/// Shown instead of a plugin panel when the panels feature is not installed.
struct PluginPanelUnavailable: View {
    let title: String
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(verbatim: title).font(.headline)
            Text(String(localized: "Plugin panels are not available in this build of Nib."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "Close")) { dismiss() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Custom block views

/// A plugin's text-document block: draws `CustomBlock.display` at the block's height; a tap runs the block's command
/// with {ref} (docs/PLUGIN_API.md §5.9).
final class PluginBlockView: UIView {
    private let app: NibApp
    private let session: EditorSession
    private let doc: DocumentID
    private let block: TextBlock
    private let command: String
    private let height: CGFloat

    @MainActor
    init(context: BlockViewContext, command: String, title: String, defaultHeight: Double) {
        self.app = context.app
        self.session = context.session
        self.doc = context.doc
        self.block = context.block
        self.command = command
        self.height = CGFloat(max(1, context.block.custom?.height ?? defaultHeight))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: height))
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens the block's editor.")
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        context.heightChanged(height)
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext(), let display = block.custom?.display else { return }
        display.draw(in: cg, origin: .zero, assets: app.services.assets, doc: doc)
    }

    @objc private func tapped() {
        app.perform(command, ["ref": .string(NodeRef.block(doc, block.id).description)], session: session)
    }
}
