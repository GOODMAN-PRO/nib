import Foundation
import NibContracts
import NibDesign

/// Clipboard, duplicate and drag-and-drop: copy / cut / paste as Nib fragments (with PNG and text flavours for other
/// apps), paste of images and rich text from other apps, Paste and Match Style, duplicate, their key commands, and
/// dragging the selection out of / content into the canvas. The object-menu entries for these commands are the
/// object menu feature's; this feature adds Paste and Match Style to the page long-press menu.
public enum FeatClipboardFeature: NibFeature {
    public static let id = "clipboard"

    public static func register(_ app: NibApp) {
        app.commands.register(ClipboardCopy.self)
        app.commands.register(ClipboardCut.self)
        app.commands.register(ClipboardPaste.self)
        app.commands.register(ItemDuplicate.self)
        app.commands.register(ClipboardCopyText.self)

        for key in keyCommands() { app.content.keyCommands.register(key) }

        app.ui.menus.register(MenuItemDescriptor(
            id: "clipboard.pasteAndMatchStyle", title: String(localized: "Paste and Match Style"), icon: NibSymbol.paste.name,
            location: .pageLongPress, order: 110, owner: id, command: ClipboardPaste.descriptor.id,
            params: { ctx in matchStyleParams(ctx) },
            isVisible: { ctx in
                guard let doc = ctx.doc, ctx.page != nil else { return false }
                return ctx.session?.readOnly != true && !ctx.app.isReadOnly(doc) && Clipboard.board.hasStrings
            }))

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "clipboard.dragdrop", owner: id, order: 900) { _ in
            CanvasDragDrop()
        })
    }

    /// The document kinds with a canvas: study sets and text documents keep ⌘X ⌘C ⌘V ⌘D for their own editors
    /// (a text document's ⌘D is F102's block duplicate).
    static let canvasKinds: Set<DocumentKind> = [.notebook, .whiteboard]

    /// ⌘X ⌘C ⌘V ⌥⇧⌘V ⌘D. Canvas scope: while text is being edited they belong to the text. The shell fills in the key
    /// window's selection (copy, cut, duplicate) or current page (paste) through `sessionParams`.
    static func keyCommands() -> [KeyCommandDescriptor] {
        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue = [:],
                 order: Int, session: @escaping @MainActor (EditorSession) -> JSONValue) -> KeyCommandDescriptor {
            let keyID = "clipboard.key." + name
            var d = KeyCommandDescriptor(id: keyID, title: title, shortcut: shortcut, command: command, params: params,
                                         scope: .canvas, order: order, owner: id)
            d.docKinds = canvasKinds
            d.sessionParams = session
            return d
        }
        return [
            key("cut", String(localized: "Cut"), KeyShortcut("x", [.command]), ClipboardCut.descriptor.id,
                order: 300, session: selectionParams),
            key("copy", String(localized: "Copy"), KeyShortcut("c", [.command]), ClipboardCopy.descriptor.id,
                order: 301, session: selectionParams),
            key("paste", String(localized: "Paste"), KeyShortcut("v", [.command]), ClipboardPaste.descriptor.id,
                order: 302, session: pageParams),
            key("pasteAndMatchStyle", String(localized: "Paste and Match Style"), KeyShortcut("v", [.command, .option, .shift]),
                ClipboardPaste.descriptor.id, ["matchStyle": true], order: 303, session: pageParams),
            key("duplicate", String(localized: "Duplicate"), KeyShortcut("d", [.command]), ItemDuplicate.descriptor.id,
                order: 304, session: selectionParams),
        ]
    }

    /// `{refs}` of the window's selection in the document it shows; nothing when nothing is selected there (the
    /// command then does nothing).
    @MainActor
    static func selectionParams(_ session: EditorSession) -> JSONValue {
        let selection = session.selection
        guard !selection.isEmpty, selection.doc == session.document else { return [:] }
        let refs = selection.refs
        return refs.isEmpty ? [:] : ["refs": .array(refs.map { .string($0) })]
    }

    /// `{page}`: the window's current page; nothing when it shows none (the paste then does nothing).
    @MainActor
    static func pageParams(_ session: EditorSession) -> JSONValue {
        guard let doc = session.document, let page = session.page else { return [:] }
        return ["page": .string(NodeRef.page(doc, page).description)]
    }

    /// Paste and Match Style at the long-pressed point.
    static func matchStyleParams(_ ctx: MenuContext) -> JSONValue {
        var params: [String: JSONValue] = ["matchStyle": true]
        if let doc = ctx.doc, let page = ctx.page { params["page"] = .string(NodeRef.page(doc, page).description) }
        if let point = ctx.point { params["at"] = [.number(point.x), .number(point.y)] }
        return .object(params)
    }
}
