import Foundation
import NibContracts

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

        // Canvas scope: while a text view is editing, ⌘C / ⌘V belong to the text.
        func key(_ name: String, _ title: String, _ shortcut: KeyShortcut, _ command: String, _ params: JSONValue = [:],
                 order: Int) {
            let keyID = "clipboard.key." + name
            app.content.keyCommands.register(KeyCommandDescriptor(
                id: keyID, title: title, shortcut: shortcut, command: command, params: params,
                scope: .canvas, order: order, owner: id))
        }
        key("cut", String(localized: "Cut"), KeyShortcut("x", [.command]), ClipboardCut.descriptor.id, order: 300)
        key("copy", String(localized: "Copy"), KeyShortcut("c", [.command]), ClipboardCopy.descriptor.id, order: 301)
        key("paste", String(localized: "Paste"), KeyShortcut("v", [.command]), ClipboardPaste.descriptor.id, order: 302)
        key("pasteAndMatchStyle", String(localized: "Paste and Match Style"), KeyShortcut("v", [.command, .option, .shift]),
            ClipboardPaste.descriptor.id, ["matchStyle": true], order: 303)
        key("duplicate", String(localized: "Duplicate"), KeyShortcut("d", [.command]), ItemDuplicate.descriptor.id, order: 304)

        app.ui.menus.register(MenuItemDescriptor(
            id: "clipboard.pasteAndMatchStyle", title: String(localized: "Paste and Match Style"), icon: "doc.on.clipboard",
            location: .pageLongPress, order: 110, owner: id, command: ClipboardPaste.descriptor.id,
            params: { ctx in matchStyleParams(ctx) },
            isVisible: { ctx in
                ctx.doc != nil && ctx.page != nil && ctx.session?.readOnly != true && Clipboard.board.hasStrings
            }))

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "clipboard.dragdrop", owner: id, order: 900) { _ in
            CanvasDragDrop()
        })
    }

    /// Paste and Match Style at the long-pressed point.
    static func matchStyleParams(_ ctx: MenuContext) -> JSONValue {
        var params: [String: JSONValue] = ["matchStyle": true]
        if let doc = ctx.doc, let page = ctx.page { params["page"] = .string(NodeRef.page(doc, page).description) }
        if let point = ctx.point { params["at"] = [.number(point.x), .number(point.y)] }
        return .object(params)
    }
}
