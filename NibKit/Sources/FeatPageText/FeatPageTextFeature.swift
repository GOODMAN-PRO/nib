import NibContracts
import NibDesign

/// Full-page typing (F028): `text.startPageText`, the on-canvas editor, the page long-press entry and ⌥⌘T.
public enum FeatPageTextFeature: NibFeature {
    public static let id = "pagetext"
    static let shortcut = KeyShortcut("t", [.command, .option])
    /// Id of the long-press entry and of the ⌥⌘T key.
    static let entryID = "pagetext.start"

    public static func register(_ app: NibApp) {
        app.commands.register(StartPageText.self)

        // Asked before the selection handles, so touches inside the box being typed in reach the text view.
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "pagetext.editor", owner: id, order: -100,
                                                                     docKinds: [.notebook]) { _ in PageTextEditor() })

        // One long-press entry: "Start Typing" on a page without typed text, "Edit Text" once it has some.
        var entry = MenuItemDescriptor(
            id: entryID, title: String(localized: "Start Typing"), icon: NibSymbol.pageTyping.name,
            location: .pageLongPress, order: 150, owner: id, command: CommandIDs.textStartPageText,
            params: pageParams, isVisible: { canType($0) })
        entry.contextTitle = { hasPageText($0) ? String(localized: "Edit Text") : String(localized: "Start Typing") }
        entry.shortcut = shortcut
        app.ui.menus.register(entry)

        // Notebooks only (whiteboard boards are infinite); the key types on the key window's current page.
        var key = KeyCommandDescriptor(id: entryID, title: String(localized: "Start Typing"), shortcut: shortcut,
                                       command: CommandIDs.textStartPageText, scope: .document, owner: id)
        key.docKinds = [.notebook]
        key.sessionParams = { sessionParams($0) }
        app.content.keyCommands.register(key)
    }

    private static func pageParams(_ ctx: MenuContext) -> JSONValue {
        guard let doc = ctx.doc, let page = ctx.page else { return [:] }
        return ["page": .string(NodeRef.page(doc, page).description)]
    }

    private static func sessionParams(_ session: EditorSession) -> JSONValue {
        guard let doc = session.document, let page = session.page else { return [:] }
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
