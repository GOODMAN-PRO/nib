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
        DiagramKeys.register(app, owner: id)
    }
}

// MARK: - What the selection allows

/// The selection as the menus and keys see it: which diagram actions apply to it.
@MainActor
enum DiagramSelection {
    /// The selected items, when the document is editable. Every action here needs one item (a box shape, a connector)
    /// or two (Connect), so a bigger selection (select-all on a dense page) returns at once, before any workspace
    /// lookup: the object menu is rebuilt often and each lookup scans the page.
    static func items(_ app: NibApp, _ selection: Selection, readOnly: Bool) -> [Item] {
        guard selection.items.count <= 2 else { return [] }
        guard !readOnly, let doc = selection.doc, let page = selection.page, !app.isReadOnly(doc) else { return [] }
        return selection.items.compactMap { try? app.workspace.item(doc, page: page, id: $0) }
    }

    /// The one selected box shape (rectangle, rounded rectangle, ellipse, triangle, diamond) that is not locked.
    static func boxShape(_ items: [Item]) -> Item? {
        guard items.count == 1, let item = items.first, !item.locked, let shape = item.shape,
              DiagramSchemas.boxShapes.contains(shape.shape) else { return nil }
        return item
    }

    /// The one selected connector that is not locked.
    static func connector(_ items: [Item]) -> ConnectorItem? {
        guard items.count == 1, let item = items.first, !item.locked else { return nil }
        return item.connector
    }

    /// Two items a connector can join.
    static func connectable(_ items: [Item]) -> Bool {
        items.count == 2 && items.allSatisfy { Anchoring.canAnchor($0) }
    }

    /// `connector.create` params joining the two selected items (facing sides).
    static func connectParams(_ selection: Selection) -> JSONValue {
        let refs = selection.refs
        guard refs.count == 2, let doc = selection.doc, let page = selection.page else { return .object([:]) }
        return .object([
            "page": .string(NodeRef.page(doc, page).description),
            "from": .object(["item": .string(refs[0])]),
            "to": .object(["item": .string(refs[1])]),
        ])
    }
}

// MARK: - Object menu

/// Object-menu entries: the menu equivalents of every drag (connect two items, add a connected shape, switch the
/// route, clear bends), so keyboard, pointer and VoiceOver users reach everything the handles do. Each shows the key
/// that does the same (`DiagramKeys`).
@MainActor
enum DiagramMenus {
    static func register(_ app: NibApp, owner: String) {
        var connect = MenuItemDescriptor(
            id: "diagrams.connect", title: String(localized: "Connect"), icon: NibSymbol.connectors.name,
            location: .objectMenu, order: 700, owner: owner, command: CommandIDs.connectorCreate,
            params: { ctx in DiagramSelection.connectParams(ctx.selection) },
            isVisible: { ctx in DiagramMenus.connectable(ctx) })
        connect.shortcut = DiagramKeys.connect
        app.ui.menus.register(connect)

        let addConnected = String(localized: "Add Connected Shape")
        for side in ConnectorSide.allCases {
            var entry = MenuItemDescriptor(
                id: "diagrams.addConnected." + side.name, title: title(side), location: .objectMenu,
                order: 710 + side.rawValue, owner: owner, command: CommandIDs.diagramAddConnected,
                params: { ctx in .object(["ref": .string(ctx.selection.refs.first ?? ""), "side": .string(side.name)]) },
                isVisible: { ctx in DiagramMenus.boxShape(ctx) != nil },
                submenu: addConnected)
            entry.shortcut = DiagramKeys.addConnected(side)
            app.ui.menus.register(entry)
        }

        // Every route is listed, the current one checked (choosing it again changes nothing).
        let style = String(localized: "Connector Style")
        for route in ConnectorRoute.allCases {
            var entry = MenuItemDescriptor(
                id: "diagrams.route." + route.rawValue, title: title(route), location: .objectMenu,
                order: 720 + DiagramKeys.routeIndex(route), owner: owner, command: CommandIDs.connectorSetPath,
                params: { ctx in .object(["ref": .string(ctx.selection.refs.first ?? ""), "route": .string(route.rawValue)]) },
                isVisible: { ctx in DiagramMenus.connector(ctx) != nil },
                submenu: style)
            entry.isChecked = { ctx in DiagramMenus.connector(ctx)?.route == route }
            entry.shortcut = DiagramKeys.route(route)
            app.ui.menus.register(entry)
        }

        app.ui.menus.register(MenuItemDescriptor(
            id: "diagrams.removeBends", title: String(localized: "Remove Bends"), location: .objectMenu,
            order: 730, owner: owner, command: CommandIDs.connectorSetPath,
            params: { ctx in .object(["ref": .string(ctx.selection.refs.first ?? ""), "bends": .array([])]) },
            isVisible: { ctx in !(DiagramMenus.connector(ctx)?.bends.isEmpty ?? true) },
            submenu: style))
    }

    static func items(_ ctx: MenuContext) -> [Item] {
        DiagramSelection.items(ctx.app, ctx.selection, readOnly: ctx.session?.readOnly ?? false)
    }

    static func boxShape(_ ctx: MenuContext) -> Item? { DiagramSelection.boxShape(items(ctx)) }

    static func connector(_ ctx: MenuContext) -> ConnectorItem? { DiagramSelection.connector(items(ctx)) }

    static func connectable(_ ctx: MenuContext) -> Bool { DiagramSelection.connectable(items(ctx)) }

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

// MARK: - Keyboard

/// Keyboard equivalents of the handles, on notebook and whiteboard canvases while no text is being edited: ⌥⌘C
/// connects the two selected items, ⌥⌘ + an arrow adds a connected shape on that side and selects it (so the next
/// press carries on from there), ⌃⌘1 / 2 / 3 make the selected connector straight, elbow or curved. Each reads the
/// window's selection when pressed (`KeyCommandDescriptor.sessionParams`) and runs `commands.batch`, whose calls are
/// empty when the selection does not fit: a key that does not apply does nothing instead of reporting an error.
@MainActor
enum DiagramKeys {
    static let docKinds: Set<DocumentKind> = [.notebook, .whiteboard]
    static let connect = KeyShortcut("c", [.command, .option])

    static func addConnected(_ side: ConnectorSide) -> KeyShortcut {
        let key: String
        switch side {
        case .top: key = "up"
        case .right: key = "right"
        case .bottom: key = "down"
        case .left: key = "left"
        }
        return KeyShortcut(key, [.command, .option])
    }

    static func routeIndex(_ route: ConnectorRoute) -> Int { ConnectorRoute.allCases.firstIndex(of: route) ?? 0 }

    static func route(_ route: ConnectorRoute) -> KeyShortcut {
        KeyShortcut(String(routeIndex(route) + 1), [.command, .control])
    }

    static func register(_ app: NibApp, owner: String) {
        func key(_ id: String, _ title: String, _ shortcut: KeyShortcut, order: Int,
                 calls: @escaping @MainActor (NibApp, EditorSession) -> [(String, JSONValue)]) -> KeyCommandDescriptor {
            var d = KeyCommandDescriptor(id: id, title: title, shortcut: shortcut, command: CommandIDs.batch,
                                         params: DiagramKeys.batch([]), scope: .canvas, order: order, owner: owner)
            d.docKinds = DiagramKeys.docKinds
            d.sessionParams = { [weak app] session in
                guard let app = app else { return DiagramKeys.batch([]) }
                return DiagramKeys.batch(calls(app, session))
            }
            return d
        }

        app.content.keyCommands.register(key("diagrams.key.connect", String(localized: "Connect"), connect, order: 700) {
            app, session in DiagramKeys.connectCalls(app, session)
        })
        for side in ConnectorSide.allCases {
            app.content.keyCommands.register(key("diagrams.key.addConnected." + side.name, addConnectedTitle(side),
                                                 addConnected(side), order: 710 + side.rawValue) { app, session in
                DiagramKeys.addConnectedCalls(app, session, side: side)
            })
        }
        for route in ConnectorRoute.allCases {
            app.content.keyCommands.register(key("diagrams.key.route." + route.rawValue, routeTitle(route),
                                                 DiagramKeys.route(route), order: 720 + routeIndex(route)) { app, session in
                DiagramKeys.routeCalls(app, session, route: route)
            })
        }
    }

    /// `commands.batch` params for `calls` (none = the key does nothing).
    static func batch(_ calls: [(String, JSONValue)]) -> JSONValue {
        .object(["calls": .array(calls.map { .object(["command": .string($0.0), "params": $0.1]) })])
    }

    static func selected(_ app: NibApp, _ session: EditorSession) -> [Item] {
        guard session.selection.doc == session.document else { return [] }
        return DiagramSelection.items(app, session.selection, readOnly: session.readOnly)
    }

    static func connectCalls(_ app: NibApp, _ session: EditorSession) -> [(String, JSONValue)] {
        guard DiagramSelection.connectable(selected(app, session)) else { return [] }
        return [(CommandIDs.connectorCreate, DiagramSelection.connectParams(session.selection))]
    }

    /// Adds the shape under a fresh id, then selects it (when the lasso feature, which owns `selection.set`, is here).
    static func addConnectedCalls(_ app: NibApp, _ session: EditorSession, side: ConnectorSide) -> [(String, JSONValue)] {
        let s = session.selection
        guard let source = DiagramSelection.boxShape(selected(app, session)), let doc = s.doc, let page = s.page else {
            return []
        }
        let id = NibID.make()
        var calls: [(String, JSONValue)] = [(CommandIDs.diagramAddConnected, .object([
            "ref": .string(NodeRef.item(doc, page, source.id).description),
            "side": .string(side.name),
            "id": .string(id.raw),
        ]))]
        if app.commands.entry(CommandIDs.selectionSet) != nil {
            calls.append((CommandIDs.selectionSet, .object(["refs": .array([.string(NodeRef.item(doc, page, id).description)])])))
        }
        return calls
    }

    static func routeCalls(_ app: NibApp, _ session: EditorSession, route: ConnectorRoute) -> [(String, JSONValue)] {
        guard let c = DiagramSelection.connector(selected(app, session)), c.route != route,
              let ref = session.selection.refs.first else { return [] }
        return [(CommandIDs.connectorSetPath, .object(["ref": .string(ref), "route": .string(route.rawValue)]))]
    }

    static func addConnectedTitle(_ side: ConnectorSide) -> String {
        switch side {
        case .top: return String(localized: "Add Connected Shape Above")
        case .right: return String(localized: "Add Connected Shape on the Right")
        case .bottom: return String(localized: "Add Connected Shape Below")
        case .left: return String(localized: "Add Connected Shape on the Left")
        }
    }

    static func routeTitle(_ route: ConnectorRoute) -> String {
        switch route {
        case .straight: return String(localized: "Straight Connector")
        case .elbow: return String(localized: "Elbow Connector")
        case .curved: return String(localized: "Curved Connector")
        }
    }
}
