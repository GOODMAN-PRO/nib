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
        // Window-level external drops enter import.files without a destination. The
        // browser owns the current folder; preserve explicit picker/canvas destinations.
        if let importer = app.commands.entry(CommandIDs.importFiles) {
            app.commands.register(importer.descriptor) { params, context in
                var routed = params
                if params["folder"] == nil, params["doc"] == nil,
                   let app = context.app, let session = context.activeSession, session.document == nil,
                   let model = LibraryModels.get(app).models[session.id] {
                    routed = params.merging(["folder": model.folderRef])
                }
                return try await importer.handler(routed, context)
            }
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
        app.content.keyCommands.register(KeyCommandDescriptor(id: id + ".openSelection", title: String(localized: "Open"),
            shortcut: KeyShortcut("return"), command: CommandIDs.librarySetView,
            params: ["openSelected": true], scope: .library, owner: id))
        app.ui.panels.register(PanelDescriptor(id: "libraryui.move", title: String(localized: "Move Items"), icon: NibSymbol.folder.name,
            placement: .sheet, order: 0, owner: id) { context in
                AnyMovePicker.make(context)
            })
    }
}

struct LibrarySetView: NibCommand {
    struct Params: Codable {
        var collection: LibraryCollection?
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
        var openSelected: Bool?
        var search: String?
        var sidebar: Bool?
    }
    typealias Output = JSONValue
    static let descriptor = CommandDescriptor(id: "library.setView", title: "Set Library View",
        summary: "Set this window's folder, layout, sort, filter or selection; present or close a registered library panel with params.",
        params: .obj(["collection": .str(choices: LibraryCollection.allCases.map(\.rawValue)),
            "folder": .str("folder:<id>, or lib for root"), "layout": .str(choices: LibraryLayout.allCases.map(\.rawValue)),
            "sort": .str(choices: LibrarySort.allCases.map(\.rawValue)), "filter": .str(choices: LibraryFilter.allCases.map(\.rawValue)),
            "panel": .str("registered panel id, or documents"), "params": .anything("panel parameters"), "close": .bool(),
            "selection": .str(choices: ["all", "clear", "begin", "toggle", "replace"]), "refs": .arr(.ref),
            "menu": .str(choices: ["new", "app", "sort", "none"]), "rename": .ref, "renameSelected": .bool(), "openSelected": .bool(),
            "search": .str(), "sidebar": .bool()]),
        examples: [["layout": "list", "sort": "created"], ["folder": "lib", "filter": "folders"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        guard let app = ctx.app, let session = ctx.activeSession ?? ctx.navigator?.session else { throw NibError.unavailable("A library window is required") }
        let folder = try p.folder.map { try LibraryModels.folder($0) }
        if let id = folder ?? nil, ctx.services.library?.node(id)?.kind != .folder { throw NibError.notFound("Library folder") }
        let descriptor = p.panel.flatMap { app.ui.panels.get($0) }
        if let panel = p.panel, panel != "documents", p.close != true {
            guard let descriptor else { throw NibError.notFound("Panel \(panel)") }
            guard descriptor.placement != .sidebarTab else { throw NibError.invalid("This panel requires an open document", path: "$.panel") }
        }
        if let selection = p.selection, !["all", "clear", "begin", "toggle", "replace"].contains(selection) {
            throw NibError.invalid("Unknown selection operation", path: "$.selection")
        }
        let existing = LibraryModels.get(app).models[session.id]
        let targetFolder = p.folder != nil ? folder ?? nil : p.collection != nil || p.panel == "documents" ? nil : existing?.folder
        let saved = app.settings.json(LibraryOrder.viewKey(targetFolder))
        let navigates = p.folder != nil || p.collection != nil || p.panel == "documents"
        let targetCollection = p.folder != nil || p.panel == "documents" ? LibraryCollection.documents : p.collection ?? existing?.collection ?? .documents
        let targetLayout = p.layout ?? (!navigates ? existing?.layout : nil) ?? LibraryLayout(rawValue: saved?["layout"]?.stringValue ?? "") ?? .grid
        let targetSort = p.sort ?? (!navigates ? existing?.sort : nil) ?? (targetCollection != .documents ? .modified : LibrarySort(rawValue: saved?["sort"]?.stringValue ?? "") ?? .modified)
        let targetFilter = p.filter ?? (!navigates ? existing?.filter : nil) ?? (targetCollection != .documents ? .documents : LibraryFilter(rawValue: saved?["filter"]?.stringValue ?? "") ?? .all)
        let result: JSONValue
        if let panel = p.panel, panel != "documents" {
            if p.close == true {
                let wasOpen = session.openPanels.contains(panel) || existing?.tab?.id == panel || existing?.modal?.id == panel
                result = ["panel": .string(panel), "closed": .bool(wasOpen)]
            } else {
                result = ["panel": .string(panel), "placement": .string(descriptor?.placement == .floating ? "sheet" : descriptor!.placement.rawValue)]
            }
        } else {
            result = ["collection": .string(targetCollection.rawValue), "folder": .string(targetFolder.map { NodeRef.folder($0).description } ?? "lib"),
                      "layout": .string(targetLayout.rawValue), "sort": .string(targetSort.rawValue), "filter": .string(targetFilter.rawValue)]
        }
        guard !ctx.dryRun else { return result }
        let model = existing ?? LibraryModels.get(app).model(session)
        if navigates {
            model.menu = nil
            model.renaming = nil
            model.search = ""
        }
        if let collection = p.collection {
            model.collection = collection; model.folder = nil; model.closeTab()
            model.selection.clear(); model.search = ""
            model.layout = targetLayout; model.sort = targetSort; model.filter = targetFilter
        }
        if p.folder != nil {
            model.collection = .documents
            model.folder = targetFolder; model.restoreView(); model.closeTab(); model.selection.clear()
        }
        if let panel = p.panel {
            if panel == "documents" {
                model.closeTab(); model.collection = .documents
                model.folder = nil; model.selection.clear()
            }
            else {
                if p.close == true { model.closePanel(panel) }
                else if let descriptor {
                    var params = p.params ?? [:]
                    if panel == "organize.folder.new", params["folder"] == nil { params = params.merging(["folder": model.folderRef]) }
                    model.openPanel(descriptor, params: params)
                }
                if navigates { await model.markDirty() }
                return result
            }
        }
        model.layout = targetLayout; model.sort = targetSort; model.filter = targetFilter
        if model.collection == .documents && (p.layout != nil || p.sort != nil || p.filter != nil) {
            app.settings.setJSON(LibraryOrder.viewKey(model.folder), ["layout": .string(model.layout.rawValue), "sort": .string(model.sort.rawValue), "filter": .string(model.filter.rawValue)])
        }
        if let selection = p.selection {
            switch selection {
            case "all": model.selection.selectAll(model.visibleRefs)
            case "clear": model.selection.clear()
            case "begin": model.selection.isSelecting = true
            case "toggle": for ref in p.refs ?? [] { model.selection.toggle(ref) }
            case "replace": model.selection.isSelecting = true; model.selection.refs = Set(p.refs ?? [])
            default: break
            }
        }
        if let menu = p.menu {
            #if DEBUG
            NSLog("%@", "[Library menu diagnostic] \(menu) \(model.menuAnchors)")
            #endif
            model.menu = menu == "none" ? nil : menu
        }
        if let rename = p.rename {
            model.menu = nil
            model.renaming = rename.isEmpty ? nil : rename
        }
        if p.renameSelected == true, model.selection.refs.count == 1 { model.renaming = model.selection.refs.first }
        if p.openSelected == true, model.selection.refs.count == 1, let ref = model.selection.refs.first {
            if case .folder? = NodeRef(ref) {
                return try await ctx.execute(CommandIDs.librarySetView, ["folder": .string(ref), "sidebar": false])
            }
            model.selection.clear()
            return try await ctx.execute(CommandIDs.docOpen, ["doc": .string(ref)])
        }
        if let search = p.search { model.search = search }
        if let sidebar = p.sidebar { model.sidebarVisible = sidebar }
        if p.sort != nil || p.filter != nil || p.search != nil { model.applySort() }
        if navigates { await model.markDirty() }
        return result
    }
}

struct LibraryReorder: NibCommand {
    struct Params: Codable { var refs: [String]; var folder: String?; var after: String?; var before: String?; var recordUndo: Bool?; var previousSort: LibrarySort?; var hadOrder: Bool? }
    typealias Output = JSONValue
    static let descriptor = CommandDescriptor(id: "library.reorder", title: "Reorder",
        summary: "Order sibling documents or folders after or before another sibling; select Manual sort and return the previous order for replay or Undo.",
        params: .obj(["refs": .arr(.ref), "folder": .str("folder:<id>, omitted for root"), "after": .ref, "before": .ref,
                      "recordUndo": .bool("false when replaying an existing window undo step"),
                      "previousSort": .str(choices: LibrarySort.allCases.map(\.rawValue)), "hadOrder": .bool("Restore the previous manual-order key")], required: ["refs"]),
        examples: [["refs": ["doc:FIXTUREDOC01"], "folder": "folder:FIXTUREFLD01"]], effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        guard let app = ctx.app else { throw NibError.unavailable("Library settings") }
        let folder = try LibraryModels.folder(p.folder)
        let library = try ctx.services.require(ctx.services.library, "the library")
        if let folder, library.node(folder)?.kind != .folder { throw NibError.notFound("Library folder") }
        let children = library.children(of: folder).map(LibraryRow.from)
        let savedOrder = app.settings.json(LibraryOrder.key(folder))
        let stored = savedOrder?.arrayValue?.compactMap(\.stringValue) ?? []
        let sessionModel = ctx.activeSession.map { LibraryModels.get(app).model($0) }
        let view = app.settings.json(LibraryOrder.viewKey(folder))
        let sort = sessionModel.flatMap { $0.folder == folder ? $0.sort : nil } ?? LibrarySort(rawValue: view?["sort"]?.stringValue ?? "") ?? .modified
        let previous = LibrarySorting.rows(children, sort: sort, manual: stored).map(\.ref)
        let restoring = p.previousSort != nil
        let current = Set(previous)
        let refs = restoring ? p.refs.filter { current.contains($0) } : p.refs
        let moving = Set(refs)
        let next = restoring ? refs + previous.filter { !moving.contains($0) } : try LibraryOrder.inserting(refs, into: previous, after: p.after, before: p.before)
        let undo: JSONValue = ["refs": .array(previous.map(JSONValue.string)), "folder": .string(folder.map { NodeRef.folder($0).description } ?? "lib"),
                               "previousSort": .string(sort.rawValue), "hadOrder": .bool(savedOrder != nil), "recordUndo": false]
        let nextSort = p.previousSort ?? .manual
        guard !ctx.dryRun else { return ["previous": .array(previous.map(JSONValue.string)), "undo": undo] }
        app.settings.setJSON(LibraryOrder.key(folder), restoring && p.hadOrder == false ? nil : .array(next.map(JSONValue.string)))
        app.settings.setJSON(LibraryOrder.viewKey(folder), (view ?? [:]).merging(["sort": .string(nextSort.rawValue)]))
        for model in LibraryModels.get(app).models.values where model.folder == folder {
            model.sort = nextSort
            model.applySort()
        }
        if p.recordUndo != false, let model = sessionModel {
            let redo: JSONValue = ["refs": .array(next.map(JSONValue.string)), "folder": .string(folder.map { NodeRef.folder($0).description } ?? "lib"),
                                   "previousSort": .string(nextSort.rawValue), "hadOrder": .bool(!(restoring && p.hadOrder == false)), "recordUndo": false]
            model.registerUndo(undo: undo, redo: redo)
        }
        ctx.events.emit(NibEventType.libraryChanged, principal: ctx.principal, payload: ["folder": .string(folder?.raw ?? "lib")])
        return ["previousSort": .string(sort.rawValue), "hadOrder": .bool(savedOrder != nil), "previous": .array(previous.map(JSONValue.string)), "order": .array(next.map(JSONValue.string)), "undo": undo]
    }
}

@MainActor
private final class LibraryRoutingAdapter {
    let original: CommandHandler
    init(original: @escaping CommandHandler) { self.original = original }
}
