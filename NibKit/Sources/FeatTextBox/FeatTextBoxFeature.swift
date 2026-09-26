import SwiftUI
import NibContracts
import NibDesign

/// Text boxes and rich text (F026): the text tool, in-place editing with auto lists and formatting shortcuts, the
/// format inspector and keyboard bar, saved text styles, and the drawer that puts text boxes on the page.
public enum FeatTextBoxFeature: NibFeature {
    public static let id = "text"

    public static func register(_ app: NibApp) {
        app.commands.register(TextCreateBox.self)
        app.commands.register(TextSetText.self)
        app.commands.register(TextFormat.self)
        app.commands.register(TextSetParagraph.self)
        app.commands.register(TextSetBoxStyle.self)
        app.commands.register(TextSaveDefaultStyle.self)
        app.commands.register(TextTapAt.self)
        TextSettings.declare(app.settings, owner: id)

        app.content.drawers.register(ItemDrawerEntry(key: ItemKind.text.rawValue, owner: id, drawer: TextBoxDrawer()))

        // Select a box, then tap it (or double-tap it with any tool) to type; before selection.tapAt (400).
        for gesture in [CanvasGesture.tap, CanvasGesture.doubleTap] {
            app.content.tapHandlers.register(TapHandlerDescriptor(
                id: "text.tapAt." + gesture.rawValue, owner: id, gesture: gesture, command: "text.tapAt",
                order: 350, itemKinds: [.text]))
        }

        let settings = app.settings
        app.ui.canvasTools.register(CanvasToolDescriptor(id: TextTool.toolID, title: String(localized: "Text"), order: 600,
                                                         owner: id) { TextTool(settings: settings) })
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: TextTool.toolID, title: String(localized: "Text"), icon: NibSymbol.text.name, group: .tools, order: 600,
            owner: id, toolID: TextTool.toolID, shortcut: KeyShortcut("t"),
            settings: { [weak app] session in
                guard let app = app else { return AnyView(EmptyView()) }
                return AnyView(TextToolSettingsView(app: app, session: session)
                    .id(TextToolSettingsView.identity(session)))
            }))

        app.ui.inspectors.register(InspectorDescriptor(
            id: "text.format", title: String(localized: "Text"), icon: NibSymbol.text.name, itemKinds: [.text, .sticky],
            order: 100, owner: id) { ctx in
                let ids = ctx.items.filter { $0.kind == .text || $0.kind == .sticky }.map { $0.id }
                if let editing = TextBoxEditor.editor(for: ctx.session)?.editingState, ids.contains(editing.id) {
                    return AnyView(TextFormatInspector(model: editing.model))
                }
                return AnyView(TextItemsInspector(app: ctx.app, session: ctx.session, doc: ctx.doc, page: ctx.page, ids: ids)
                    .id(TextItemsInspector.identity(doc: ctx.doc, page: ctx.page, ids: ids)))
            })

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "text.editor", owner: id, order: -100) { host in
            TextBoxEditor(host: host)
        })

        // The action equivalent of double-tapping a text box (VoiceOver, pointer, keyboard users).
        app.ui.menus.register(MenuItemDescriptor(
            id: "text.edit", title: String(localized: "Edit Text"), icon: NibSymbol.text.name, location: .objectMenu,
            order: 150, owner: id, command: "text.tapAt",
            params: { ctx in
                guard let doc = ctx.selection.doc ?? ctx.doc, let page = ctx.selection.page ?? ctx.page,
                      let item = ctx.selection.items.first else { return [:] }
                let centre = (try? ctx.app.workspace.item(doc, page: page, id: item))?.frame?.center ?? Point(0, 0)
                return ["page": .string(NodeRef.page(doc, page).description),
                        "point": .array([.number(centre.x), .number(centre.y)]),
                        "ref": .string(NodeRef.item(doc, page, item).description),
                        "gesture": .string(CanvasGesture.doubleTap.rawValue)]
            },
            isVisible: { ctx in
                ctx.selection.items.count == 1 && ctx.itemKinds == [.text] && !(ctx.session?.readOnly ?? true)
            }))
    }
}
