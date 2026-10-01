import Foundation
import NibContracts
import NibDesign

public enum FeatExportUIFeature: NibFeature {
    public static let id = "exportui"
    public static func register(_ app: NibApp) {
        app.commands.register(PresentExport.self)
        app.commands.register(PresentPrint.self)
        app.commands.register(SaveToSource.self)
        for location in [MenuLocation.libraryItem, .librarySelection, .sidebarPage, .sidebarSelection, .board] {
            app.ui.menus.register(MenuItemDescriptor(
                id: "exportui.export." + location.rawValue, title: String(localized: "Export…"), icon: NibSymbol.share.name,
                location: location, order: 100, owner: id, command: CommandIDs.exportPresent,
                params: { context in ExportMenus.params(context, location: location) },
                isVisible: { context in context.doc != nil || !context.nodes.isEmpty || context.ref != nil }))
        }
        for (scope, title, order) in [("current", String(localized: "Export this page…"), 110),
                                      ("selected", String(localized: "Export selected pages…"), 115),
                                      ("all", String(localized: "Export all…"), 120)] {
            var menu = MenuItemDescriptor(id: "exportui." + scope, title: title, icon: NibSymbol.share.name,
                location: .shareExport, order: order, owner: id, command: CommandIDs.exportPresent,
                params: { context in ExportMenus.params(context, location: .shareExport).merging(["scope": .string(scope)]) },
                isVisible: { $0.doc != nil && (scope != "current" || $0.page != nil) })
            if scope == "current" {
                menu.contextTitle = { context in
                    context.doc.flatMap { context.app.services.library?.node($0)?.documentKind } == .whiteboard
                        ? String(localized: "Export this board…") : title
                }
            }
            app.ui.menus.register(menu)
        }
        for location in [MenuLocation.shareExport, .sidebarPage, .sidebarSelection, .libraryItem] {
            app.ui.menus.register(MenuItemDescriptor(id: "exportui.print." + location.rawValue,
                title: String(localized: "Print…"), icon: NibSymbol.print.name, location: location, order: 200,
                owner: id, command: CommandIDs.printPresent,
                params: { context in ExportMenus.printParams(context, location: location) }, isVisible: { $0.doc != nil }))
        }
        var saveSource = MenuItemDescriptor(id: "exportui.saveSource", title: String(localized: "Save changes to source…"),
            icon: NibSymbol.saveToFiles.name, location: .shareExport, order: 300, owner: id,
            command: CommandIDs.exportSaveToSource, params: { context in
                context.doc.map { ["doc": .string(NodeRef.document($0).description)] } ?? [:]
            }, isVisible: { context in
                guard let doc = context.doc, context.app.services.lock?.isLocked(doc) != true else { return false }
                // Only this private capability bypasses query.get, which deliberately removes bookmarks.
                return (try? context.app.workspace.peekContent(doc).meta.sourceBookmark) != nil
            })
        saveSource.contextTitle = { context in
            guard let doc = context.doc,
                  let bookmark = try? context.app.workspace.peekContent(doc).meta.sourceBookmark,
                  let url = try? SourceOverwrite.resolve(bookmark) else { return String(localized: "Save changes to source…") }
            return String(localized: "Save changes to \(url.lastPathComponent)…")
        }
        app.ui.menus.register(saveSource)
        app.content.keyCommands.register(KeyCommandDescriptor(id: id + ".exportKey", title: String(localized: "Share & Export"),
            shortcut: KeyShortcut("e", [.command, .shift]), command: CommandIDs.exportPresent,
            params: ["instant": true], scope: .document, owner: id))
        app.content.keyCommands.register(KeyCommandDescriptor(id: id + ".printKey", title: String(localized: "Print"),
            shortcut: KeyShortcut("p", .command), command: CommandIDs.printPresent,
            params: ["instant": true], scope: .document, owner: id))
    }
}

@MainActor
enum ExportMenus {
    static func params(_ context: MenuContext, location: MenuLocation) -> JSONValue {
        if location == .libraryItem || location == .librarySelection {
            let refs: [String]
            if !context.nodes.isEmpty {
                refs = context.nodes.map { node in
                    context.app.services.library?.node(node)?.kind == .folder
                        ? NodeRef.folder(node).description : NodeRef.document(node).description
                }
            } else if let ref = context.ref { refs = [ref] }
            else if let doc = context.doc { refs = [NodeRef.document(doc).description] }
            else { refs = [] }
            return ["docs": .array(refs.map(JSONValue.string))]
        }
        guard let doc = context.doc else { return [:] }
        var params: JSONValue = ["docs": .array([.string(NodeRef.document(doc).description)])]
        if location == .sidebarSelection, !context.nodes.isEmpty {
            params.set("pages", .array(context.nodes.map { .string(NodeRef.page(doc, $0).description) }))
        } else if [.sidebarPage, .board].contains(location), let page = context.page {
            params.set("pages", .array([.string(NodeRef.page(doc, page).description)]))
        }
        return params
    }
    static func printParams(_ context: MenuContext, location: MenuLocation) -> JSONValue {
        var params: JSONValue = context.doc.map { ["doc": .string(NodeRef.document($0).description)] } ?? [:]
        params.set("pages", Self.params(context, location: location)["pages"])
        if location == .sidebarSelection { params.set("ready", true) }
        return params
    }
}

extension JSONValue {
    /// Local draft builder. JSONValue's contract subscript is read-only.
    mutating func set(_ key: String, _ value: JSONValue?) {
        var object = objectValue ?? [:]
        object[key] = value
        self = .object(object)
    }
}
