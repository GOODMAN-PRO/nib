import Foundation
import NibContracts

/// Tabs, windows and session restore (F018): the scene hooks (tab strip, new windows, restoration), `doc.open`,
/// `window.open`, `tab.close`, `tab.closeOthers` and `tab.select`, their menu entries and shortcuts.
public enum FeatWindowsFeature: NibFeature {
    public static let id = "windows"

    public static func register(_ app: NibApp) {
        let scenes = WindowScenes(app: app)
        app.services.set(scenes, for: WindowScenes.serviceKey)
        app.ui.sceneHooks = SceneHooksImpl(app: app, scenes: scenes)

        app.commands.register(DocOpen.self)
        app.commands.register(WindowOpen.self)
        app.commands.register(TabClose.self)
        app.commands.register(TabCloseOthers.self)
        app.commands.register(TabSelect.self)

        app.settings.declare(WindowSettings.lastSession,
                             summary: "Tabs, document and page of the frontmost window when Nib last went to the background; a cold launch reopens that document.",
                             owner: id,
                             schema: .obj(["tabs": .arr(.str("document id")),
                                           "active": .str("document id on screen; absent = the library"),
                                           "page": .str("page id")]))

        WindowMenus.register(app, owner: id)
    }

    public static func start(_ app: NibApp) async {
        WindowScenes.of(app)?.observe(app.events)
        WindowShortcuts.registerMissing(app, owner: id)
    }
}

// MARK: - Menu entries

/// Entries for the tab menu, the document title menu, library items and page thumbnails. Each runs a command.
@MainActor
enum WindowMenus {
    /// There is no "new window" glyph among `NibSymbol`s; menu icons are symbol names by contract.
    static let newWindowIcon = "macwindow.badge.plus"

    static func register(_ app: NibApp, owner: String) {
        let menus = app.ui.menus
        menus.register(MenuItemDescriptor(
            id: "windows.tab.newWindow", title: String(localized: "Open in New Window"), icon: newWindowIcon,
            location: .tab, order: 100, owner: owner, command: "window.open",
            params: { ctx in openParams(ctx) }, isVisible: { ctx in canOpenWindow(ctx) }))
        menus.register(MenuItemDescriptor(
            id: "windows.tab.close", title: String(localized: "Close Tab"), icon: "xmark",
            location: .tab, order: 200, owner: owner, command: "tab.close",
            params: { ctx in docParams(ctx) }, isVisible: { ctx in menuDocument(ctx) != nil }))
        menus.register(MenuItemDescriptor(
            id: "windows.tab.closeOthers", title: String(localized: "Close Other Tabs"), icon: "xmark.square",
            location: .tab, order: 300, owner: owner, command: CommandIDs.batch,
            params: { ctx in closeOthersParams(keeping: ctx.index ?? 0) },
            isVisible: { ctx in ctx.index != nil && tabCount(ctx) > 1 }))
        menus.register(MenuItemDescriptor(
            id: "windows.title.closeOthers", title: String(localized: "Close Other Tabs"), icon: "xmark.square",
            location: .documentTitle, order: 900, owner: owner, command: "tab.closeOthers",
            isVisible: { ctx in tabCount(ctx) > 1 }))
        menus.register(MenuItemDescriptor(
            id: "windows.library.newWindow", title: String(localized: "Open in New Window"), icon: newWindowIcon,
            location: .libraryItem, order: 150, owner: owner, command: "window.open",
            params: { ctx in openParams(ctx) }, isVisible: { ctx in canOpenWindow(ctx) }))
        menus.register(MenuItemDescriptor(
            id: "windows.page.newWindow", title: String(localized: "Open in New Window"), icon: newWindowIcon,
            location: .sidebarPage, order: 900, owner: owner, command: "window.open",
            params: { ctx in openParams(ctx) }, isVisible: { ctx in menuPage(ctx) != nil && canOpenWindow(ctx) }))
    }

    /// The document a menu is for: `doc`, a ref inside it, or a single library node that is a document.
    static func menuDocument(_ ctx: MenuContext) -> DocumentID? {
        if let doc = ctx.doc { return doc }
        if let ref = ctx.ref, let doc = NodeRef(ref)?.documentID { return doc }
        guard ctx.nodes.count == 1, ctx.app.services.library?.node(ctx.nodes[0])?.kind == .document else { return nil }
        return ctx.nodes[0]
    }

    static func menuPage(_ ctx: MenuContext) -> PageID? {
        ctx.page ?? ctx.ref.flatMap { NodeRef($0)?.pageID }
    }

    static func canOpenWindow(_ ctx: MenuContext) -> Bool {
        menuDocument(ctx) != nil && (WindowScenes.of(ctx.app)?.supportsMultipleWindows() ?? false)
    }

    static func tabCount(_ ctx: MenuContext) -> Int {
        WindowScenes.of(ctx.app)?.navigator(for: ctx.session)?.openDocuments.count ?? 0
    }

    static func docParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = menuDocument(ctx) else { return [:] }
        return ["doc": .string(NodeRef.document(doc).description)]
    }

    /// The document at the menu's page, else at the page it last showed.
    static func openParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = menuDocument(ctx) else { return [:] }
        var params: [String: JSONValue] = ["doc": .string(NodeRef.document(doc).description)]
        if let page = menuPage(ctx) ?? WindowScenes.of(ctx.app)?.page(of: doc, in: ctx.session) {
            params["page"] = .string(NodeRef.page(doc, page).description)
        }
        return .object(params)
    }

    /// `tab.closeOthers` keeps the current tab, so the menu of another tab makes that one current first.
    static func closeOthersParams(keeping index: Int) -> JSONValue {
        let select: JSONValue = ["command": "tab.select", "params": ["index": .number(Double(index))]]
        let closeOthers: JSONValue = ["command": "tab.closeOthers"]
        return ["calls": [select, closeOthers]]
    }
}

// MARK: - Shortcuts

/// ⌘N new window, ⌘W close tab, ⌥⌘W close all tabs, ⌘1–8 tabs and ⌘9 the last tab. Registered in `start`, after every
/// feature has registered, and only for key combinations nobody else maps (the Keyboard feature also binds ⌘N and
/// ⌘1–9 to these commands), so a combination is never registered twice.
@MainActor
enum WindowShortcuts {
    static let idPrefix = "windows.key."

    static func descriptors(owner: String) -> [KeyCommandDescriptor] {
        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue = [:],
                 scope: KeyScope = .document, order: Int) -> KeyCommandDescriptor {
            KeyCommandDescriptor(id: idPrefix + name, title: title, shortcut: shortcut, command: command, params: params,
                                 scope: scope, order: order, owner: owner)
        }
        let closeAll: JSONValue = ["calls": [["command": "tab.closeOthers"], ["command": "tab.close"]]]
        var list: [KeyCommandDescriptor] = [
            key("newWindow", String(localized: "New Window"), KeyShortcut("n", .command), "window.open",
                scope: .global, order: 100),
            key("closeTab", String(localized: "Close Tab"), KeyShortcut("w", .command), "tab.close", order: 110),
            key("closeAllTabs", String(localized: "Close All Tabs"), KeyShortcut("w", [.command, .option]),
                CommandIDs.batch, closeAll, order: 120),
        ]
        for n in 1...9 {
            let index: JSONValue = ["index": .number(Double(n == 9 ? -1 : n - 1))]
            let title = n == 9 ? String(localized: "Last Tab") : String(localized: "Tab \(n)")
            list.append(key("tab\(n)", title, KeyShortcut(String(n), .command), "tab.select", index, order: 130 + n))
        }
        return list
    }

    static func registerMissing(_ app: NibApp, owner: String) {
        let taken = Set(app.content.keyCommands.all.map { $0.shortcut })
        for descriptor in descriptors(owner: owner) where !taken.contains(descriptor.shortcut) {
            app.content.keyCommands.register(descriptor)
        }
    }
}
