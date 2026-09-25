import NibContracts
import NibDesign

/// Full-page typing (F028): `text.startPageText`, the on-canvas editor, the page long-press entry and ⌥⌘T.
public enum FeatPageTextFeature: NibFeature {
    public static let id = "pagetext"

    public static func register(_ app: NibApp) {
        app.commands.register(StartPageText.self)

        // Asked before the selection handles, so touches inside the box being typed in reach the text view.
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "pagetext.editor", owner: id, order: -100,
                                                                     docKinds: [.notebook]) { _ in PageTextEditor() })

        // One long-press slot: "Start Typing" on a page without typed text, "Edit Text" once it has some.
        app.ui.menus.register(MenuItemDescriptor(
            id: "pagetext.start", title: String(localized: "Start Typing"), icon: NibSymbol.pageTyping.name,
            location: .pageLongPress, order: 150, owner: id, command: StartPageText.descriptor.id,
            params: pageParams, isVisible: { canType($0) && !hasPageText($0) }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "pagetext.edit", title: String(localized: "Edit Text"), icon: NibSymbol.pageTyping.name,
            location: .pageLongPress, order: 150, owner: id, command: StartPageText.descriptor.id,
            params: pageParams, isVisible: { canType($0) && hasPageText($0) }))

        let startKey = "pagetext.start"
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: startKey, title: String(localized: "Start Typing"), shortcut: KeyShortcut("t", [.command, .option]),
            command: StartPageText.descriptor.id, scope: .document, owner: id))
    }

    private static func pageParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = ctx.doc, let page = ctx.page else { return [:] }
        return ["page": .string(NodeRef.page(doc, page).description)]
    }

    /// A fixed-size page (never an infinite board) in an editable window.
    private static func canType(_ ctx: MenuContext) -> Bool {
        guard ctx.session?.readOnly != true, let doc = ctx.doc, let page = ctx.page else { return false }
        return (try? ctx.app.workspace.content(doc))?.page(page)?.size != nil
    }

    private static func hasPageText(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let page = ctx.page else { return false }
        let items = (try? ctx.app.workspace.items(doc, page: page)) ?? []
        return items.contains { PageTextModel.isFullPageBox($0) && !($0.text?.text.isEmpty ?? true) }
    }
}
