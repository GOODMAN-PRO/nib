import Foundation
import UIKit
import NibContracts
import NibDesign

public enum FeatLibraryUIFeature: NibFeature {
    public static let id = "libraryui"
    public static func start(_ app: NibApp) async {
        // The screen factory has no folder parameter and the current shell discards showLibrary's folder.
        // Preserve the core descriptor/handler, then forward its already-authorised request to our session command.
        guard app.services.get("libraryui.routing", as: LibraryRoutingAdapter.self) == nil,
              let entry = app.commands.entry(CommandIDs.windowShowLibrary) else { return }
        let adapter = LibraryRoutingAdapter(original: entry.handler)
        app.services.set(adapter, for: "libraryui.routing")
        app.commands.register(entry.descriptor) { params, context in
            guard !context.dryRun else { return [:] }
            let result = try await adapter.original(params, context)
            _ = try await context.execute(CommandIDs.librarySetView, ["folder": params["folder"]?.stringValue.map(JSONValue.string) ?? "lib", "sidebar": false])
            return result
        }
    }
    public static func register(_ app: NibApp) {
        app.commands.register(LibrarySetView.self)
        app.commands.register(LibraryReorder.self)
        LibraryMenus.register(app)
        app.settings.declarePrefix("library.order.", synced: true, summary: "Manual sibling order for each library folder.", owner: id, schema: .arr(.ref))
        app.settings.declarePrefix("libraryui.view.", synced: true, summary: "Remembered library layout, sort and filter per folder.", owner: id,
                                   schema: .obj(["layout": .str(choices: LibraryLayout.allCases.map(\.rawValue)),
                                                 "sort": .str(choices: LibrarySort.allCases.map(\.rawValue)),
                                                 "filter": .str(choices: LibraryFilter.allCases.map(\.rawValue))]))
        app.ui.screens.libraryRoot = { app, navigator in LibraryRootViewController(app: app, navigator: navigator) }
        app.content.keyCommands.register(KeyCommandDescriptor(id: id + ".selectAll", title: String(localized: "Select All"),
            shortcut: KeyShortcut("a", [.command]), command: CommandIDs.librarySetView,
            params: ["selection": "all"], scope: .library, owner: id))
        app.content.keyCommands.register(KeyCommandDescriptor(id: id + ".endSelection", title: String(localized: "Deselect All"),
            shortcut: KeyShortcut("escape"), command: CommandIDs.librarySetView,
            params: ["selection": "clear", "menu": "none"], scope: .library, owner: id))
        app.content.keyCommands.register(KeyCommandDescriptor(id: id + ".rename", title: String(localized: "Rename"),
            shortcut: KeyShortcut("return"), command: CommandIDs.librarySetView,
            params: ["renameSelected": true], scope: .library, owner: id))
        app.ui.panels.register(PanelDescriptor(id: "libraryui.move", title: String(localized: "Move Items"), icon: NibSymbol.folder.name,
            placement: .sheet, order: 0, owner: id) { context in
                AnyMovePicker.make(context)
            })
    }
}

struct LibrarySetView: NibCommand {
    struct Params: Codable {
        var folder: String?
        var layout: LibraryLayout?
        var sort: LibrarySort?
        var filter: LibraryFilter?
        var panel: String?
        var params: JSONValue?
        var close: Bool?
        // UI state lives in this session command too, so it remains available to plugins and AI.
        var selection: String?
        var refs: [String]?
        var menu: String?
        var rename: String?
        var renameSelected: Bool?
        var search: String?
        var sidebar: Bool?
    }
    typealias Output = JSONValue
    static let descriptor = CommandDescriptor(id: "library.setView", title: "Set Library View",
        summary: "Set this window's folder, layout, sort, filter or selection; present or close a registered library panel with params.",
        params: .obj(["folder": .str("folder:<id>, or lib for root"), "layout": .str(choices: LibraryLayout.allCases.map(\.rawValue)),
            "sort": .str(choices: LibrarySort.allCases.map(\.rawValue)), "filter": .str(choices: LibraryFilter.allCases.map(\.rawValue)),
            "panel": .str("registered panel id, or documents"), "params": .anything("panel parameters"), "close": .bool(),
            "selection": .str(choices: ["all", "clear", "begin", "toggle", "replace"]), "refs": .arr(.ref),
            "menu": .str(choices: ["new", "app", "sort", "none"]), "rename": .ref, "renameSelected": .bool(),
            "search": .str(), "sidebar": .bool()]),
        examples: [["layout": "list", "sort": "created"], ["folder": "lib", "filter": "folders"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        guard let app = ctx.app, let session = ctx.activeSession else { throw NibError.unavailable("A library window is required") }
        let model = LibraryModels.get(app).model(session)
        if let folder = p.folder {
            let id = try LibraryModels.folder(folder)
            if let id, ctx.services.library?.node(id)?.kind != .folder { throw NibError.notFound("Library folder") }
            model.folder = id
            model.restoreView()
            model.tab = nil
            model.selection.clear()
        }
        // Validate presentation before changing any panel state.
        if let panel = p.panel {
            if panel == "documents" {
                model.closeTab()
            } else {
                if p.close == true, session.openPanels.contains(panel) {
                    model.closePanel(panel)
                    return ["panel": .string(panel), "closed": true]
                }
                guard let descriptor = app.ui.panels.get(panel) else { throw NibError.notFound("Panel \(panel)") }
                guard descriptor.placement != .sidebarTab else { throw NibError.invalid("This panel requires an open document", path: "$.panel") }
                if p.close == true { model.closePanel(panel) }
                else { model.openPanel(descriptor, params: p.params ?? [:]) }
                let placement = descriptor.placement == .floating ? "sheet" : descriptor.placement.rawValue
                return p.close == true ? ["panel": .string(panel), "closed": true] : ["panel": .string(panel), "placement": .string(placement)]
            }
        }
        if let layout = p.layout { model.layout = layout }
        if let sort = p.sort { model.sort = sort }
        if let filter = p.filter { model.filter = filter }
        if p.layout != nil || p.sort != nil || p.filter != nil {
            app.settings.setJSON(LibraryOrder.viewKey(model.folder), ["layout": .string(model.layout.rawValue), "sort": .string(model.sort.rawValue), "filter": .string(model.filter.rawValue)])
        }
        if let selection = p.selection {
            switch selection {
            case "all": model.selection.selectAll(model.visibleRows.map(\.ref))
            case "clear": model.selection.clear()
            case "begin": model.selection.isSelecting = true
            case "toggle": for ref in p.refs ?? [] { model.selection.toggle(ref) }
            case "replace": model.selection.isSelecting = true; model.selection.refs = Set(p.refs ?? [])
            default: throw NibError.invalid("Unknown selection operation", path: "$.selection")
            }
        }
        if let menu = p.menu { model.menu = menu == "none" ? nil : menu }
        if let rename = p.rename { model.renaming = rename.isEmpty ? nil : rename }
        if p.renameSelected == true, model.selection.refs.count == 1 { model.renaming = model.selection.refs.first }
        if let search = p.search { model.search = search }
        if let sidebar = p.sidebar { model.sidebarVisible = sidebar }
        model.applySort()
        if p.folder != nil { await model.reload() }
        return ["folder": .string(model.folder.map { NodeRef.folder($0).description } ?? "lib"), "layout": .string(model.layout.rawValue),
                "sort": .string(model.sort.rawValue), "filter": .string(model.filter.rawValue)]
    }
}

struct LibraryReorder: NibCommand {
    struct Params: Codable { var refs: [String]; var folder: String?; var after: String?; var before: String?; var recordUndo: Bool? }
    typealias Output = JSONValue
    static let descriptor = CommandDescriptor(id: "library.reorder", title: "Reorder",
        summary: "Order sibling documents or folders after or before another sibling; select Manual sort and return the previous order for replay or Undo.",
        params: .obj(["refs": .arr(.ref), "folder": .str("folder:<id>, omitted for root"), "after": .ref, "before": .ref,
                      "recordUndo": .bool("false when replaying an existing window undo step")], required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC01"], "folder": "folder:FIXTUREFLD01"]], effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        guard let app = ctx.app else { throw NibError.unavailable("Library settings") }
        let folder = try LibraryModels.folder(p.folder)
        let library = try ctx.services.require(ctx.services.library, "the library")
        if let folder, library.node(folder)?.kind != .folder { throw NibError.notFound("Library folder") }
        let children = library.children(of: folder).map(LibraryRow.from)
        let stored = app.settings.json(LibraryOrder.key(folder))?.arrayValue?.compactMap(\.stringValue) ?? []
        let sessionModel = ctx.activeSession.map { LibraryModels.get(app).model($0) }
        let view = app.settings.json(LibraryOrder.viewKey(folder))
        let sort = sessionModel.flatMap { $0.folder == folder ? $0.sort : nil } ?? LibrarySort(rawValue: view?["sort"]?.stringValue ?? "") ?? .modified
        let previous = LibrarySorting.rows(children, sort: sort, manual: stored).map(\.ref)
        let next = try LibraryOrder.inserting(p.refs, into: previous, after: p.after, before: p.before)
        let undo: JSONValue = ["refs": .array(previous.map(JSONValue.string)), "folder": .string(folder.map { NodeRef.folder($0).description } ?? "lib")]
        guard !ctx.dryRun else { return ["previous": .array(previous.map(JSONValue.string)), "undo": undo] }
        app.settings.setJSON(LibraryOrder.key(folder), .array(next.map(JSONValue.string)))
        app.settings.setJSON(LibraryOrder.viewKey(folder), (view ?? [:]).merging(["sort": "manual"]))
        for model in LibraryModels.get(app).models.values where model.folder == folder {
            model.sort = .manual
            model.applySort()
        }
        if p.recordUndo != false, let model = sessionModel {
            model.registerUndo(order: previous, inverse: next, folder: folder)
        }
        ctx.events.emit(NibEventType.libraryChanged, principal: ctx.principal, payload: ["folder": .string(folder?.raw ?? "lib")])
        return ["previous": .array(previous.map(JSONValue.string)), "order": .array(next.map(JSONValue.string)), "undo": undo]
    }
}

@MainActor
private final class LibraryRoutingAdapter {
    let original: CommandHandler
    init(original: @escaping CommandHandler) { self.original = original }
}
