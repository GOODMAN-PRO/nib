import SwiftUI
import NibContracts
import NibDesign

/// F046 Outline & bookmarks: the custom outline merged with the PDF outline (Outline tab, `outline.list`), page
/// bookmarks (Bookmarks tab, sidebar thumbnail menus, the nav-bar bookmark button, ⌥⌘B) and their commands.
public enum FeatOutlineFeature: NibFeature {
    public static let id = "outline"

    public static func register(_ app: NibApp) {
        OutlineCommands.register(app.commands)
        OutlineSettings.declare(app.settings, owner: id)
        var outlinePanel = PanelDescriptor(
            id: OutlinePanels.outline, title: String(localized: "Outline"), icon: NibSymbol.outline.name,
            placement: .sidebarTab, order: OutlinePanels.outlineOrder, owner: id, docKinds: [.notebook]) { context in
                AnyView(OutlinePanel(context: context))
            }
        // Keep the narrow navigator's title clear of the chrome's placement accessories.
        outlinePanel.providesHeader = true
        app.ui.panels.register(outlinePanel)
        app.ui.panels.register(PanelDescriptor(
            id: OutlinePanels.bookmarks, title: String(localized: "Bookmarks"), icon: NibSymbol.bookmark.name,
            placement: .sidebarTab, order: OutlinePanels.bookmarksOrder, owner: id, docKinds: [.notebook]) { context in
                AnyView(BookmarksPanel(context: context))
            })
        OutlineMenus.register(app.ui.menus, owner: id)
        app.ui.toolbar.register(bookmarkNavItem(workspace: app.workspace))
        app.content.keyCommands.register(bookmarkKey(workspace: app.workspace))
    }

    static let bookmarkShortcut = KeyShortcut("b", [.command, .option])

    /// The nav-bar bookmark button (D-066): toggles the window's current page, drawn filled and on while that page is
    /// bookmarked (contracts-v2 live state, evaluated per window by the chrome). Notebooks only.
    @MainActor
    static func bookmarkNavItem(workspace: Workspace) -> ToolbarItemDescriptor {
        var item = ToolbarItemDescriptor(
            id: OutlinePanels.bookmarkNavItem, title: String(localized: "Bookmark Page"), icon: NibSymbol.bookmark.name,
            group: .navLeading, order: OutlinePanels.bookmarkNavOrder, owner: id, command: CommandIDs.pageSetBookmarked,
            shortcut: bookmarkShortcut, docKinds: [.notebook])
        item.isOn = { BookmarkToggle.isOn($0, in: workspace) }
        item.isEnabled = { BookmarkToggle.currentPage($0, in: workspace) != nil }
        item.sessionParams = { BookmarkToggle.params($0, in: workspace) }
        item.sessionTitle = { session in
            BookmarkToggle.isOn(session, in: workspace) ? String(localized: "Remove Bookmark") : String(localized: "Bookmark Page")
        }
        item.sessionIcon = { session in
            (BookmarkToggle.isOn(session, in: workspace) ? NibSymbol.bookmarkFill : NibSymbol.bookmark).name
        }
        return item
    }

    /// ⌥⌘B: the same toggle for the key window's current page, live only while it shows a notebook.
    @MainActor
    static func bookmarkKey(workspace: Workspace) -> KeyCommandDescriptor {
        var key = KeyCommandDescriptor(
            id: OutlinePanels.bookmarkShortcut, title: String(localized: "Bookmark Page"), shortcut: bookmarkShortcut,
            command: CommandIDs.pageSetBookmarked, scope: .document, owner: id)
        key.docKinds = [.notebook]
        key.sessionParams = { BookmarkToggle.params($0, in: workspace) }
        return key
    }
}

enum OutlinePanels {
    static let outline = "outline.tab"
    static let bookmarks = "outline.bookmarks"
    /// DESIGN.md §14.4 orders the navigator tabs Pages · Outline · Bookmarks: after the Pages tab, before Audio (300),
    /// Comments (450), Layers (500) and History (900).
    static let outlineOrder = 200
    static let bookmarksOrder = 210
    /// Key command id (not a command): ⌥⌘B runs page.setBookmarked for the current page.
    static let bookmarkShortcut = "outline.bookmarkPage"
    /// Nav-bar item id; it takes the place of the chrome's built-in bookmark button (F017 shows one only while no
    /// feature registers an item for page.setBookmarked), in the same slot.
    static let bookmarkNavItem = "outline.nav.bookmark"
    static let bookmarkNavOrder = 500
}

/// Menu entries (D-128 "Add Page to Outline" from More and the thumbnail menu; bookmarks from the thumbnail and
/// selection menus; the outline entry menu). Every entry runs a command with params computed from its context.
@MainActor
enum OutlineMenus {
    static func register(_ menus: Registry<MenuItemDescriptor>, owner: String) {
        menus.register(MenuItemDescriptor(
            id: "outline.more.addPage", title: String(localized: "Add Page to Outline"), icon: NibSymbol.outline.name,
            location: .documentMore, order: 450, owner: owner, command: CommandIDs.outlineAdd,
            params: { addParams(currentPage($0)) }, isVisible: { currentPage($0) != nil }))

        menus.register(MenuItemDescriptor(
            id: "outline.page.add", title: String(localized: "Add to Outline"), icon: NibSymbol.outline.name,
            location: .sidebarPage, order: 450, owner: owner, command: CommandIDs.outlineAdd,
            params: { addParams(thumbnailPage($0)) }, isVisible: { thumbnailPage($0) != nil }))
        menus.register(MenuItemDescriptor(
            id: "outline.page.bookmark", title: String(localized: "Bookmark"), icon: NibSymbol.bookmark.name,
            location: .sidebarPage, order: 460, owner: owner, command: CommandIDs.pageSetBookmarked,
            params: { bookmarkParams(thumbnailPage($0).map { [$0] } ?? [], on: true) },
            isVisible: { thumbnailPage($0).map { !$0.page.bookmarked } ?? false }))
        menus.register(MenuItemDescriptor(
            id: "outline.page.unbookmark", title: String(localized: "Remove Bookmark"), icon: NibSymbol.bookmarkFill.name,
            location: .sidebarPage, order: 460, owner: owner, command: CommandIDs.pageSetBookmarked,
            params: { bookmarkParams(thumbnailPage($0).map { [$0] } ?? [], on: false) },
            isVisible: { thumbnailPage($0)?.page.bookmarked ?? false }))

        menus.register(MenuItemDescriptor(
            id: "outline.selection.bookmark", title: String(localized: "Bookmark"), icon: NibSymbol.bookmark.name,
            location: .sidebarSelection, order: 460, owner: owner, command: CommandIDs.pageSetBookmarked,
            params: { bookmarkParams(selectedPages($0), on: true) },
            isVisible: { selectedPages($0).contains { !$0.page.bookmarked } }))
        menus.register(MenuItemDescriptor(
            id: "outline.selection.unbookmark", title: String(localized: "Remove Bookmarks"), icon: NibSymbol.bookmarkFill.name,
            location: .sidebarSelection, order: 461, owner: owner, command: CommandIDs.pageSetBookmarked,
            params: { bookmarkParams(selectedPages($0), on: false) },
            isVisible: { selectedPages($0).contains { $0.page.bookmarked } }))

        let moves: [MoveItem] = [
            MoveItem(id: "outline.entry.moveUp", title: String(localized: "Move Up"), order: 100) { $0.moveUp($1) },
            MoveItem(id: "outline.entry.moveDown", title: String(localized: "Move Down"), order: 110) { $0.moveDown($1) },
            MoveItem(id: "outline.entry.indent", title: String(localized: "Nest in Previous Entry"), order: 120) { $0.indent($1) },
            MoveItem(id: "outline.entry.outdent", title: String(localized: "Move Out a Level"), order: 130) { $0.outdent($1) }
        ]
        for move in moves {
            let placement = move.placement
            menus.register(MenuItemDescriptor(
                id: move.id, title: move.title, location: .outlineEntry, order: move.order, owner: owner,
                command: CommandIDs.outlineMove,
                params: { ctx in
                    guard let e = entry(ctx), let p = placement(e.tree, e.id) else { return [:] }
                    return OutlineParams.move(doc: e.doc, entry: e.id, p)
                },
                isVisible: { ctx in entry(ctx).map { placement($0.tree, $0.id) != nil } ?? false },
                submenu: String(localized: "Move")))
        }
        menus.register(MenuItemDescriptor(
            id: "outline.entry.delete", title: String(localized: "Delete"), icon: NibSymbol.trash.name,
            location: .outlineEntry, order: 900, owner: owner, command: CommandIDs.outlineDelete,
            params: { ctx in
                guard let e = entry(ctx) else { return [:] }
                return ["entry": .string(NodeRef.outline(e.doc, e.id).description)]
            },
            isVisible: { entry($0) != nil }, destructive: true))
    }

    struct MoveItem {
        let id: String
        let title: String
        let order: Int
        let placement: (OutlineTree, NibID) -> OutlinePlacement?
    }

    struct PageContext {
        var doc: DocumentID
        var page: PageRecord
        var content: DocumentContent
    }

    struct EntryContext {
        var doc: DocumentID
        var id: NibID
        var tree: OutlineTree
    }

    /// The window's current page of a notebook (More menu).
    static func currentPage(_ ctx: MenuContext) -> PageContext? {
        page(doc: ctx.doc ?? ctx.session?.document, id: ctx.page ?? ctx.session?.page, app: ctx.app)
    }

    /// The thumbnail the sidebar menu is for (`sidebarPage` menus carry it in `page`; `nodes` is the selection).
    static func thumbnailPage(_ ctx: MenuContext) -> PageContext? {
        page(doc: ctx.doc ?? ctx.session?.document, id: ctx.page, app: ctx.app)
    }

    static func selectedPages(_ ctx: MenuContext) -> [PageContext] {
        guard let doc = ctx.doc ?? ctx.session?.document, let content = try? ctx.app.workspace.content(doc) else { return [] }
        return ctx.nodes.compactMap { id in
            guard let page = content.page(id), !page.deleted else { return nil }
            return PageContext(doc: doc, page: page, content: content)
        }
    }

    static func entry(_ ctx: MenuContext) -> EntryContext? {
        guard let ref = ctx.ref, case let .outline(doc, id)? = NodeRef(ref),
              let content = try? ctx.app.workspace.content(doc) else { return nil }
        let tree = OutlineTree(content.outline)
        return tree.entries[id] == nil ? nil : EntryContext(doc: doc, id: id, tree: tree)
    }

    private static func page(doc: DocumentID?, id: PageID?, app: NibApp) -> PageContext? {
        guard let doc = doc, let id = id, let content = try? app.workspace.content(doc), content.meta.kind == .notebook,
              let page = content.page(id), !page.deleted else { return nil }
        return PageContext(doc: doc, page: page, content: content)
    }

    private static func addParams(_ context: PageContext?) -> JSONValue {
        guard let c = context else { return [:] }
        return OutlineParams.add(doc: c.doc, page: c.page, content: c.content)
    }

    private static func bookmarkParams(_ pages: [PageContext], on: Bool) -> JSONValue {
        guard let doc = pages.first?.doc else { return [:] }
        return OutlineParams.bookmark(doc: doc, pages: pages.map { $0.page.id }, on: on)
    }
}
