import Foundation
import NibContracts

/// Links (F029): typed text links to web addresses, pages of any document and audio moments; PDF hyperlinks;
/// following them by tap (read-only) or long-press (edit), with a per-window "Return to page" history.
public enum FeatLinksFeature: NibFeature {
    public static let id = "links"
    /// Key command ids (⌘K opens the link editor for the selected text, ⌘[ returns to the page before a jump).
    static let addLinkKey = "link.add"
    static let returnKey = "link.back"

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
            id: "link.tapAt", owner: id, gesture: .tap, command: LinkTapAt.descriptor.id, order: 300,
            worksInReadOnly: true))
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: "link.tapAt.longPress", owner: id, gesture: .longPress, command: LinkTapAt.descriptor.id, order: 300))

        app.ui.menus.register(MenuItemDescriptor(
            id: "link.textSelection", title: String(localized: "Link"), icon: "link", location: .textSelection,
            order: 300, owner: id, command: LinkSet.descriptor.id,
            params: { ctx in LinkSelection.textSelectionParams(ctx) },
            isVisible: { ctx in LinkSelection.isLinkable(ctx.ref, workspace: ctx.app.workspace) }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "link.objectMenu", title: String(localized: "Add Link"), icon: "link", location: .objectMenu,
            order: 650, owner: id, command: LinkSet.descriptor.id,
            params: { ctx in LinkSelection.objectMenuParams(ctx) },
            isVisible: { ctx in LinkSelection.objectMenuIsVisible(ctx) }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "link.back", title: String(localized: "Return to Page"), icon: "chevron.backward",
            location: .documentMore, order: 150, owner: id, command: LinkBack.descriptor.id,
            isVisible: { ctx in
                guard let session = ctx.session,
                      let navigator = ctx.app.services.get(LinkNavigator.serviceKey, as: LinkNavigator.self) else { return false }
                return navigator.pendingReturn(session) != nil
            }))

        app.content.keyCommands.register(KeyCommandDescriptor(
            id: addLinkKey, title: String(localized: "Add Link"), shortcut: KeyShortcut("k", .command),
            command: LinkSet.descriptor.id, scope: .document, owner: id))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: returnKey, title: String(localized: "Return to Page"), shortcut: KeyShortcut("[", .command),
            command: LinkBack.descriptor.id, scope: .document, owner: id))

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "link.returnToPage", owner: id, order: 900) { _ in
            ReturnToPageAttachment()
        })
    }
}
