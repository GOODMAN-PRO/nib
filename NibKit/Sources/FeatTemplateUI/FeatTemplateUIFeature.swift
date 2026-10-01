import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatTemplateUIFeature: NibFeature {
    public static let id = "templateui"
    public static func register(_ app: NibApp) {
        app.settings.declarePrefix("templates.hidden.", synced: true, summary: "Hide one built-in or plugin template.", owner: id, schema: .bool())
        app.services.set(TemplatePickerPresenter(), for: TemplatePickerPresenter.serviceKey)
        TemplateUICommands.register(app)
        app.commands.register(TemplateChoose.self)
        app.commands.register(TemplateApply.self)
        var manage = PanelDescriptor(id: PanelIDs.templates, title: String(localized: "Manage Notebook Templates"),
                                     icon: NibSymbol.templates.name, placement: .sheet, order: 45, owner: id) {
            AnyView(TemplateLibraryView(context: $0))
        }
        manage.providesHeader = true
        app.ui.panels.register(manage)
        var change = PanelDescriptor(id: "templateui.change", title: String(localized: "Change Template"),
                                     icon: NibSymbol.templates.name, placement: .floating, order: 45, owner: id,
                                     docKinds: [.notebook]) { AnyView(ChangeTemplateSheet(context: $0)) }
        change.providesHeader = true
        app.ui.panels.register(change)
        for location in [MenuLocation.documentMore, .sidebarPage, .sidebarSelection] {
            app.ui.menus.register(MenuItemDescriptor(id: "templateui.change.\(location.rawValue)", title: String(localized: "Change Template"),
                icon: NibSymbol.templates.name, location: location, order: 45, owner: id, command: CommandIDs.panelOpen,
                params: { menu in
                    var p: [String: JSONValue] = ["id": "templateui.change", "kind": "paper"]
                    if let doc = menu.doc {
                        let pages = menu.nodes.isEmpty ? menu.page.map { [$0] } ?? [] : menu.nodes
                        p["pages"] = .array(pages.map { .string(NodeRef.page(doc, $0).description) })
                    }
                    return .object(p)
                }, isVisible: { $0.doc != nil }))
        }
        app.ui.menus.register(MenuItemDescriptor(id: "templateui.cover", title: String(localized: "Change Cover"),
            icon: NibSymbol.templates.name, location: .documentMore, order: 46, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": "templateui.change", "kind": "cover"] }, isVisible: { $0.doc != nil }))
        app.ui.menus.register(MenuItemDescriptor(id: "templateui.manage", title: String(localized: "Manage Notebook Templates"),
            icon: NibSymbol.templates.name, location: .appMenu, order: 45, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(PanelIDs.templates)] }))
        app.ui.menus.register(MenuItemDescriptor(id: "templateui.fromPage", title: String(localized: "Create Template from Page"),
            icon: NibSymbol.templates.name, location: .sidebarPage, order: 47, owner: id, command: CommandIDs.panelOpen,
            params: { menu in
                var p: [String: JSONValue] = ["id": .string(PanelIDs.templates)]
                if let doc = menu.doc, let page = menu.page { p["fromPage"] = .string(NodeRef.page(doc, page).description) }
                return .object(p)
            }))
        app.content.keyCommands.register(KeyCommandDescriptor(id: "templateui.manage.key", title: String(localized: "Manage Templates"),
            shortcut: KeyShortcut("t", [.command, .option, .shift]), command: CommandIDs.panelOpen,
            params: ["id": .string(PanelIDs.templates)], scope: .global, owner: id))
    }
}

@MainActor
enum TemplateUICommands {
    static func store(_ ctx: CommandContext) throws -> CustomTemplateStore {
        guard let library = ctx.services.library else { throw NibError.unavailable("Template library") }
        return CustomTemplateStore(root: library.metadataURL.appendingPathComponent("templates", isDirectory: true), clock: ctx.workspace.clock)
    }
    static func required(_ p: JSONValue, _ key: String) throws -> String {
        guard let value = p[key]?.stringValue, !value.isEmpty else { throw NibError.invalid("Missing \(key).", path: "$." + key) }
        return value
    }
    static func guardWrite(_ ctx: CommandContext) throws {
        guard !ctx.dryRun else { throw NibError.unsupported("Dry-run template library changes") }
    }
    static func register(_ app: NibApp) {
        func command(_ id: String, _ title: String, _ summary: String, _ schema: JSONSchema, _ example: JSONValue,
                     effect: Effect = .library, destructive: Bool = false, _ handler: @escaping CommandHandler) {
            app.commands.register(CommandDescriptor(id: id, title: title, summary: summary, params: schema, examples: [example],
                effect: effect, target: .library, destructive: destructive, undoable: false)) { params, context in
                let result = try await handler(params, context)
                if effect == .library { context.events.emit(NibEventType.libraryChanged, principal: context.principal, payload: ["templates": true]) }
                return result
            }
        }
        command("template.import", "Import Template", "Import the first PDF page or an image as custom paper or a cover.",
            .obj(["url": .str(), "group": .str(), "kind": .str(choices: ["paper", "cover"]), "id": .str(), "title": .str()], required: ["url", "kind"]),
            ["url": "tmp:template.pdf", "kind": "paper"]) { p, ctx in
                try guardWrite(ctx)
                let url = try await ctx.inputFile(required(p, "url"))
                let entry = try await store(ctx).importFile(url, group: p["group"]?.stringValue, kind: required(p, "kind"), id: p["id"]?.stringValue, title: p["title"]?.stringValue)
                return try JSONValue.from(entry)
            }
        command("template.listCustom", "List Custom Templates", "List custom templates and groups, hidden template IDs and notebook defaults.",
            .obj(["group": .str()]), [:], effect: .read) { p, ctx in
                let groups = try store(ctx).groups().filter { group in p["group"]?.stringValue.map { group.id == $0 } ?? true }
                let settings = ctx.services.settings
                let hidden = settings.names(prefix: "templates.hidden.").filter { settings.json($0)?.boolValue == true }.map { String($0.dropFirst("templates.hidden.".count)) }
                return ["groups": try JSONValue.from(groups), "templates": try JSONValue.from(groups.flatMap(\.liveTemplates)),
                        "hidden": .array(hidden.map(JSONValue.string)), "defaultPaper": try JSONValue.from(settings.get(NibSettings.defaultPaper)),
                        "defaultCover": try JSONValue.from(settings.get(NibSettings.defaultCover)), "coverByDefault": .bool(settings.get(NibSettings.coverByDefault)), "defaultSize": try JSONValue.from(settings.get(NibSettings.defaultPageSize))]
            }
        command("template.group.create", "Create Template Group", "Create a named custom-template group with an optional caller-chosen ID.",
            .obj(["title": .str(), "id": .str()], required: ["title"]), ["title": "My papers", "id": "papers"]) { p, ctx in
                try guardWrite(ctx)
                return try JSONValue.from(store(ctx).create(title: required(p, "title"), id: p["id"]?.stringValue))
            }
        command("template.group.rename", "Rename Template Group", "Rename a custom-template group, keeping its templates and ID.",
            .obj(["group": .str(), "title": .str()], required: ["group", "title"]), ["group": "papers", "title": "Work papers"]) { p, ctx in
                try guardWrite(ctx)
                return try JSONValue.from(store(ctx).rename(required(p, "group"), title: required(p, "title")))
            }
        command("template.group.delete", "Delete Template Group", "Remove a group and its custom templates with a synced tombstone.",
            .obj(["group": .str()], required: ["group"]), ["group": "papers"], destructive: true) { p, ctx in
                try guardWrite(ctx); try store(ctx).deleteGroup(required(p, "group")); return [:]
            }
        command("template.delete", "Delete Custom Template", "Remove a custom template without affecting documents that already use it.",
            .obj(["id": .str()], required: ["id"]), ["id": "paper01"], destructive: true) { p, ctx in
                try guardWrite(ctx); try store(ctx).delete(required(p, "id")); return [:]
            }
        command("template.setHidden", "Hide or Restore Template", "Hide or restore one registered built-in or plugin template using a synced per-template preference.",
            .obj(["id": .str(), "hidden": .bool()], required: ["id", "hidden"]), ["id": .string(TemplateIDs.blank), "hidden": false]) { p, ctx in
                try guardWrite(ctx)
                let id = try required(p, "id")
                guard ctx.content.templates.get(id) != nil else { throw NibError.notFound("Template \(id)") }
                guard let hidden = p["hidden"]?.boolValue else { throw NibError.invalid("Supply hidden.", path: "$.hidden") }
                ctx.services.settings.setJSON("templates.hidden." + id, .bool(hidden)); return [:]
            }
        command("template.fromPage", "Create Template from Page", "Export one page as flattened PDF and import it as custom paper.",
            .obj(["page": .ref, "title": .str(), "id": .str()], required: ["page", "title"]),
            ["page": "page:FIXTUREDOC01/FIXTUREPG001", "title": "Lecture paper"]) { p, ctx in
                try guardWrite(ctx)
                let (doc, page) = try ctx.pageOrSession(p["page"]?.stringValue)
                if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the document before exporting a template.") }
                let title = try CustomTemplateStore.title(required(p, "title"))
                if let id = p["id"]?.stringValue { _ = try CustomTemplateStore.validID(id) }
                let exported = try await ctx.execute(CommandIDs.exportRun, ["docs": [.string(NodeRef.document(doc).description)],
                    "pages": [.string(NodeRef.page(doc, page).description)], "format": "pdf", "options": ["mode": "flattened"], "name": .string(title)])
                guard let asset = exported["files"]?[0]?["asset"]?.stringValue else { throw NibError(.internalError, "Export did not return a template file.") }
                return try await ctx.execute("template.import", ["url": .string(asset), "kind": "paper", "title": .string(title), "id": p["id"] ?? .null])
            }
    }
}
