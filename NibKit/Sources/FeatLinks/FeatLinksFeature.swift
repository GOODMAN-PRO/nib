import Foundation
import NibContracts
import NibDesign

/// Links (F029): typed text links to web addresses, pages of any document and audio moments; PDF hyperlinks;
/// following them by tap (read-only) or long-press (edit), with a per-window "Return to page" history.
public enum FeatLinksFeature: NibFeature {
    public static let id = "links"
    /// Key command ids (⌘K opens the link editor for the text being edited or selected, ⌘[ returns to the page
    /// before a jump).
    static let addLinkKey = "link.add"
    static let returnKey = "link.back"
    static let addLinkShortcut = KeyShortcut("k", .command)
    static let returnShortcut = KeyShortcut("[", .command)

    public static func register(_ app: NibApp) {
        app.services.set(LinkNavigator(app: app), for: LinkNavigator.serviceKey)

        app.commands.register(LinkSet.self)
        app.commands.register(LinkRemove.self)
        app.commands.register(LinkFollow.self)
        app.commands.register(LinkBack.self)
        app.commands.register(LinkAutodetect.self)
        app.commands.register(LinkTapAt.self)

        // A finger tap follows links in read-only mode, and PDF links on bare paper in edit mode (planner tabs);
        // in edit mode a tap on typed text edits it, so text links there take a long-press.
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: "link.tapAt", owner: id, gesture: .tap, command: CommandIDs.linkTapAt, order: 300,
            worksInReadOnly: true))
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: "link.tapAt.longPress", owner: id, gesture: .longPress, command: CommandIDs.linkTapAt, order: 300))

        var textSelection = MenuItemDescriptor(
            id: "link.textSelection", title: String(localized: "Link"), icon: NibSymbol.link.name, location: .textSelection,
            order: 300, owner: id, command: CommandIDs.linkSet,
            params: { ctx in LinkSelection.textSelectionParams(ctx) },
            isVisible: { ctx in LinkSelection.textSelectionIsVisible(ctx) })
        textSelection.contextTitle = { ctx in LinkSelection.textSelectionTitle(ctx) }
        textSelection.shortcut = addLinkShortcut
        app.ui.menus.register(textSelection)

        var objectMenu = MenuItemDescriptor(
            id: "link.objectMenu", title: String(localized: "Add Link"), icon: NibSymbol.link.name, location: .objectMenu,
            order: 650, owner: id, command: CommandIDs.linkSet,
            params: { ctx in LinkSelection.objectMenuParams(ctx) },
            isVisible: { ctx in LinkSelection.objectMenuIsVisible(ctx) })
        objectMenu.contextTitle = { ctx in LinkSelection.objectMenuTitle(ctx) }
        app.ui.menus.register(objectMenu)

        var back = MenuItemDescriptor(
            id: "link.back", title: String(localized: "Return to Page"), icon: NibSymbol.back.name,
            location: .documentMore, order: 150, owner: id, command: CommandIDs.linkBack,
            isVisible: { ctx in
                guard let session = ctx.session, let navigator = LinkNavigator.of(ctx.app) else { return false }
                return navigator.pendingReturn(session) != nil
            })
        back.shortcut = returnShortcut
        app.ui.menus.register(back)

        // ⌘K names the text the key window edits (or the selected item) when it is pressed. It stays at `.document`:
        // the clash with the command bar's ⌘K (DESIGN.md §14.16) is open for the spec owner (contract-gaps F029).
        var addLink = KeyCommandDescriptor(
            id: addLinkKey, title: String(localized: "Add Link"), shortcut: addLinkShortcut,
            command: CommandIDs.linkSet, scope: .document, owner: id)
        addLink.sessionParams = { [weak app] session in
            app.map { LinkSelection.keyParams(session, app: $0) } ?? [:]
        }
        app.content.keyCommands.register(addLink)
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: returnKey, title: String(localized: "Return to Page"), shortcut: returnShortcut,
            command: CommandIDs.linkBack, scope: .document, owner: id))

        app.ui.chromeOverlays.register(ReturnToPageOverlay.descriptor(owner: id))
    }
}
