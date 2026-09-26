import Foundation
import NibContracts
import NibDesign

/// Connectors & diagrams (F032): connector items (straight, elbow, curved; arrowheads; labels) anchored to item sides,
/// the bend/anchor editor and the Quick Diagramming dots on the canvas, and native diagrams generated from nodes and
/// edges (the AI's "Generate Diagram" and whiteboard frameworks use `diagram.create`).
public enum FeatDiagramsFeature: NibFeature {
    public static let id = "diagrams"

    public static func register(_ app: NibApp) {
        app.commands.register(ConnectorCreate.self)
        app.commands.register(ConnectorSetPath.self)
        app.commands.register(DiagramAddConnected.self)
        app.commands.register(DiagramCreate.self)
        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.connector.rawValue, owner: id, drawer: ConnectorDrawer()))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "diagrams.connectorEditor", owner: id, order: 310) { host in
            ConnectorEditor(host: host)
        })
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "diagrams.quickDiagram", owner: id, order: 320) { host in
            QuickDiagramOverlay(host: host)
        })
        DiagramMenus.register(app, owner: id)
    }
}

/// Object-menu entries: the menu equivalents of every drag (connect two items, add a connected shape, switch the
/// route, clear bends), so keyboard, pointer and VoiceOver users reach everything the handles do.
@MainActor
enum DiagramMenus {
    static func register(_ app: NibApp, owner: String) {
        app.ui.menus.register(MenuItemDescriptor(
            id: "diagrams.connect", title: String(localized: "Connect"), icon: NibSymbol.connectors.name,
            location: .objectMenu, order: 700, owner: owner, command: "connector.create",
            params: { ctx in DiagramMenus.connectParams(ctx) },
            isVisible: { ctx in DiagramMenus.connectable(ctx) }))

        let addConnected = String(localized: "Add Connected Shape")
        for side in ConnectorSide.allCases {
            app.ui.menus.register(MenuItemDescriptor(
                id: "diagrams.addConnected." + side.name, title: title(side), location: .objectMenu,
                order: 710 + side.rawValue, owner: owner, command: "diagram.addConnected",
                params: { ctx in .object(["ref": .string(ctx.selection.refs.first ?? ""), "side": .string(side.name)]) },
                isVisible: { ctx in DiagramMenus.boxShape(ctx) != nil },
                submenu: addConnected))
        }

        let style = String(localized: "Connector Style")
        for (i, route) in ConnectorRoute.allCases.enumerated() {
            app.ui.menus.register(MenuItemDescriptor(
                id: "diagrams.route." + route.rawValue, title: title(route), location: .objectMenu,
                order: 720 + i, owner: owner, command: "connector.setPath",
                params: { ctx in .object(["ref": .string(ctx.selection.refs.first ?? ""), "route": .string(route.rawValue)]) },
                isVisible: { ctx in DiagramMenus.connector(ctx).map { $0.route != route } ?? false },
                submenu: style))
        }

        app.ui.menus.register(MenuItemDescriptor(
            id: "diagrams.removeBends", title: String(localized: "Remove Bends"), location: .objectMenu,
            order: 730, owner: owner, command: "connector.setPath",
            params: { ctx in .object(["ref": .string(ctx.selection.refs.first ?? ""), "bends": .array([])]) },
            isVisible: { ctx in !(DiagramMenus.connector(ctx)?.bends.isEmpty ?? true) },
            submenu: style))
    }

    /// The selected items, when the document is editable. Every entry here needs one item (a box shape, a
    /// connector) or two (Connect), so a bigger selection (select-all on a dense page) returns at once, before any
    /// workspace lookup: the object menu is rebuilt often and each lookup scans the page.
    static func items(_ ctx: MenuContext) -> [Item] {
        guard ctx.selection.items.count <= 2 else { return [] }
        guard !(ctx.session?.readOnly ?? false), let doc = ctx.selection.doc, let page = ctx.selection.page else { return [] }
        return ctx.selection.items.compactMap { try? ctx.app.workspace.item(doc, page: page, id: $0) }
    }

    static func boxShape(_ ctx: MenuContext) -> Item? {
        let selected = items(ctx)
        guard selected.count == 1, let item = selected.first, !item.locked, let shape = item.shape,
              DiagramSchemas.boxShapes.contains(shape.shape) else { return nil }
        return item
    }

    static func connector(_ ctx: MenuContext) -> ConnectorItem? {
        let selected = items(ctx)
        guard selected.count == 1, let item = selected.first, !item.locked else { return nil }
        return item.connector
    }

    static func connectable(_ ctx: MenuContext) -> Bool {
        let selected = items(ctx)
        return selected.count == 2 && selected.allSatisfy { Anchoring.canAnchor($0) }
    }

    static func connectParams(_ ctx: MenuContext) -> JSONValue {
        let refs = ctx.selection.refs
        guard refs.count == 2, let doc = ctx.selection.doc, let page = ctx.selection.page else { return .object([:]) }
        return .object([
            "page": .string(NodeRef.page(doc, page).description),
            "from": .object(["item": .string(refs[0])]),
            "to": .object(["item": .string(refs[1])]),
        ])
    }

    static func title(_ side: ConnectorSide) -> String {
        switch side {
        case .top: return String(localized: "Above")
        case .right: return String(localized: "On the Right")
        case .bottom: return String(localized: "Below")
        case .left: return String(localized: "On the Left")
        }
    }

    static func title(_ route: ConnectorRoute) -> String {
        switch route {
        case .straight: return String(localized: "Straight")
        case .elbow: return String(localized: "Elbow")
        case .curved: return String(localized: "Curved")
        }
    }
}
