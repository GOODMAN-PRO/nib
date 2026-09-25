import SwiftUI
import NibContracts
import NibDesign

/// Whiteboards (F044): New Whiteboard with its options, the Boards sidebar tab, the minimap, the board item limit,
/// eight board templates, Convert to Whiteboard, and the board commands (board.add, board.rename,
/// board.insertTemplate, doc.convertToWhiteboard). Every action runs a command, so plugins, the AI and the bridge can
/// do all of it; the infinite canvas itself is F006's.
public enum FeatWhiteboardFeature: NibFeature {
    public static let id = "whiteboard"

    public static func register(_ app: NibApp) {
        app.commands.register(BoardAdd.self)
        app.commands.register(BoardRename.self)
        app.commands.register(BoardInsertTemplate.self)
        app.commands.register(DocConvertToWhiteboard.self)
        // Commands have no NibApp: they find this app's registries (board and paper templates) here.
        app.services.set(app.content, for: Whiteboard.contentKey)
        app.settings.declare(Whiteboard.minimapVisible, summary: "Show the whiteboard minimap on this device.",
                             owner: id, schema: .bool())

        WhiteboardTemplates.register(app, owner: id)
        app.content.customItemTypes.register(CustomItemTypeDescriptor(
            owner: id, type: Whiteboard.pageCardType, title: String(localized: "Page"), textPath: "title"))

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: MinimapAttachment.id, owner: id, order: 900, docKinds: [.whiteboard]) { _ in MinimapAttachment() })
        app.ui.panels.register(PanelDescriptor(
            id: Whiteboard.boardsPanel, title: String(localized: "Boards"), icon: NibSymbol.pages.name,
            placement: .sidebarTab, order: 100, owner: id, docKinds: [.whiteboard]) { ctx in
                AnyView(BoardsPanel(app: ctx.app, session: ctx.session))
            })
        app.ui.panels.register(PanelDescriptor(
            id: Whiteboard.templatesPanel, title: String(localized: "Templates"), icon: "rectangle.3.group",
            placement: .floating, order: 110, owner: id, docKinds: [.whiteboard]) { ctx in
                guard let session = ctx.session else {
                    return AnyView(NibEmptyState(symbol: .whiteboard, title: String(localized: "No whiteboard open")))
                }
                return AnyView(BoardTemplatesPanel(app: ctx.app, session: session, dismiss: { ctx.dismiss() }))
            })
        WhiteboardCreateSheet.register(app, folder: nil)
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: Whiteboard.templatesPanel, title: String(localized: "Templates"), icon: "rectangle.3.group",
            group: .accessories, order: 700, owner: id, command: CommandIDs.panelOpen,
            params: ["id": .string(Whiteboard.templatesPanel)], docKinds: [.whiteboard]))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: Whiteboard.newWhiteboardKey, title: String(localized: "New Whiteboard"),
            shortcut: KeyShortcut("w", [.command, .shift]), command: CommandIDs.panelOpen,
            params: ["id": .string(Whiteboard.createPanel)], scope: .library, order: 310, owner: id))

        registerMenus(app)
        BoardMenus.register(app, owner: id)
    }

    @MainActor
    private static func registerMenus(_ app: NibApp) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "whiteboard.new", title: String(localized: "Whiteboard"), icon: NibSymbol.whiteboard.name,
            location: .libraryNew, order: 30, owner: id, command: CommandIDs.panelOpen,
            params: { ctx in ["id": .string(WhiteboardCreateSheet.panel(ctx.app, folder: currentFolder(ctx)))] }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.convert", title: String(localized: "Convert to Whiteboard"), icon: NibSymbol.whiteboard.name,
            location: .libraryItem, order: 450, owner: id, command: "doc.convertToWhiteboard",
            params: { ctx in ["doc": convertible(ctx).map { JSONValue.string(NodeRef.document($0.id).description) } ?? .null] },
            isVisible: { ctx in convertible(ctx) != nil }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.addBoard", title: String(localized: "Add Board"), icon: NibSymbol.addPage.name,
            location: .addPage, order: 10, owner: id, command: "board.add",
            params: { ctx in ["doc": ctx.doc.map { JSONValue.string(NodeRef.document($0).description) } ?? .null] },
            isVisible: { ctx in isWhiteboard(ctx) }))
        menus.register(MenuItemDescriptor(
            id: "whiteboard.insertTemplate", title: String(localized: "Insert Template…"), icon: "rectangle.3.group",
            location: .addPage, order: 20, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(Whiteboard.templatesPanel)] },
            isVisible: { ctx in isWhiteboard(ctx) }))
    }

    /// The one notebook a library item menu was opened for.
    @MainActor
    static func convertible(_ ctx: MenuContext) -> LibraryNode? {
        guard ctx.nodes.count == 1, let node = ctx.app.services.library?.node(ctx.nodes[0]),
              node.kind == .document, node.documentKind == .notebook, node.trashedAt == nil else { return nil }
        return node
    }

    /// The folder the New menu was opened in, when the library passes it; nil = the root.
    @MainActor
    static func currentFolder(_ ctx: MenuContext) -> FolderID? {
        ctx.nodes.compactMap { ctx.app.services.library?.node($0) }.first { $0.kind == .folder }?.id
    }

    @MainActor
    static func isWhiteboard(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let content = try? ctx.app.workspace.content(doc) else { return false }
        return content.meta.kind == .whiteboard
    }
}
