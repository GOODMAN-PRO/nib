import SwiftUI
import NibContracts
import NibDesign

/// F046 Outline & bookmarks: the custom outline merged with the PDF outline (Outline tab), page bookmarks (Bookmarks
/// tab, sidebar thumbnail menus, the nav-bar button the chrome builds for `page.setBookmarked`, ⌥⌘B) and their commands.
public enum FeatOutlineFeature: NibFeature {
    public static let id = "outline"

    public static func register(_ app: NibApp) {
        OutlineCommands.register(app.commands)
        OutlineSettings.declare(app.settings, owner: id)
        app.ui.panels.register(PanelDescriptor(
            id: OutlinePanels.outline, title: String(localized: "Outline"), icon: NibSymbol.outline.name,
            placement: .sidebarTab, order: 10, owner: id, docKinds: [.notebook]) { context in
                AnyView(OutlinePanel(context: context))
            })
        app.ui.panels.register(PanelDescriptor(
            id: OutlinePanels.bookmarks, title: String(localized: "Bookmarks"), icon: NibSymbol.bookmark.name,
            placement: .sidebarTab, order: 20, owner: id, docKinds: [.notebook]) { context in
                AnyView(BookmarksPanel(context: context))
            })
        OutlineMenus.register(app.ui.menus, owner: id)
        // The native bookmark shortcut: `{}` toggles the window's current page (see PageSetBookmarked.Params).
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: OutlinePanels.bookmarkShortcut, title: String(localized: "Bookmark Page"),
            shortcut: KeyShortcut("b", [.command, .option]), command: "page.setBookmarked", scope: .document, owner: id))
    }
}

enum OutlinePanels {
    static let outline = "outline.tab"
    static let bookmarks = "outline.bookmarks"
    /// Key command id (not a command): ⌥⌘B runs page.setBookmarked for the current page.
    static let bookmarkShortcut = "outline.bookmarkPage"
}

/// Menu entries (D-128 "Add Page to Outline" from More and the thumbnail menu; bookmarks from the thumbnail and
/// selection menus; the outline entry menu). Every entry runs a command with params computed from its context.
@MainActor
enum OutlineMenus {
    static func register(_ menus: Registry<MenuItemDescriptor>, owner: String) {
        menus.register(MenuItemDescriptor(
            id: "outline.more.addPage", title: String(localized: "Add Page to Outline"), icon: NibSymbol.outline.name,
            location: .documentMore, order: 450, owner: owner, command: "outline.add",
            params: { addParams(currentPage($0)) }, isVisible: { currentPage($0) != nil }))

        menus.register(MenuItemDescriptor(
            id: "outline.page.add", title: String(localized: "Add to Outline"), icon: NibSymbol.outline.name,
            location: .sidebarPage, order: 450, owner: owner, command: "outline.add",
            params: { addParams(thumbnailPage($0)) }, isVisible: { thumbnailPage($0) != nil }))
        menus.register(MenuItemDescriptor(
            id: "outline.page.bookmark", title: String(localized: "Bookmark"), icon: NibSymbol.bookmark.name,
            location: .sidebarPage, order: 460, owner: owner, command: "page.setBookmarked",
            params: { bookmarkParams(thumbnailPage($0).map { [$0] } ?? [], on: true) },
            isVisible: { thumbnailPage($0).map { !$0.page.bookmarked } ?? false }))
        menus.register(MenuItemDescriptor(
            id: "outline.page.unbookmark", title: String(localized: "Remove Bookmark"), icon: NibSymbol.bookmarkFill.name,
            location: .sidebarPage, order: 460, owner: owner, command: "page.setBookmarked",
            params: { bookmarkParams(thumbnailPage($0).map { [$0] } ?? [], on: false) },
            isVisible: { thumbnailPage($0)?.page.bookmarked ?? false }))

        menus.register(MenuItemDescriptor(
            id: "outline.selection.bookmark", title: String(localized: "Bookmark"), icon: NibSymbol.bookmark.name,
            location: .sidebarSelection, order: 460, owner: owner, command: "page.setBookmarked",
            params: { bookmarkParams(selectedPages($0), on: true) },
            isVisible: { selectedPages($0).contains { !$0.page.bookmarked } }))
        menus.register(MenuItemDescriptor(
            id: "outline.selection.unbookmark", title: String(localized: "Remove Bookmarks"), icon: NibSymbol.bookmarkFill.name,
            location: .sidebarSelection, order: 461, owner: owner, command: "page.setBookmarked",
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
                command: "outline.move",
                params: { ctx in
                    guard let e = entry(ctx), let p = placement(e.tree, e.id) else { return [:] }
                    return OutlineParams.move(doc: e.doc, entry: e.id, p)
                },
                isVisible: { ctx in entry(ctx).map { placement($0.tree, $0.id) != nil } ?? false },
                submenu: String(localized: "Move")))
        }
        menus.register(MenuItemDescriptor(
            id: "outline.entry.delete", title: String(localized: "Delete"), icon: NibSymbol.trash.name,
            location: .outlineEntry, order: 900, owner: owner, command: "outline.delete",
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

    /// The thumbnail the sidebar menu is for.
    static func thumbnailPage(_ ctx: MenuContext) -> PageContext? {
        page(doc: ctx.doc ?? ctx.session?.document, id: ctx.page ?? ctx.nodes.first, app: ctx.app)
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
