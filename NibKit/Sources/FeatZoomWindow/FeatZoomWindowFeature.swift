import Foundation
import NibContracts
import NibDesign

/// Zoom Window (F038; Goodnotes T-073, T-104, P-029): write large in a pane docked at the bottom while the zoom box on
/// the page shows where the ink lands. Opened from the accessory toolbar item, the page long-press "Zoom", ⌥⌘Z or a
/// Pencil action; auto-advance (`NibSettings.zoomAutoAdvance`) moves the box along as you write.
public enum FeatZoomWindowFeature: NibFeature {
    public static let id = "zoomwindow"

    public static func register(_ app: NibApp) {
        app.services.set(ZoomStore(templates: app.content.templates), for: ZoomStore.key)

        app.commands.register(ZoomToggle.self)
        app.commands.register(ZoomSetBox.self)
        app.commands.register(ZoomNewLine.self)
        app.commands.register(ZoomSetReturnHeight.self)

        let title = String(localized: "Zoom Window")
        let newLine = String(localized: "New Line in Zoom Window")
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "zoomwindow", title: title, icon: NibSymbol.zoomWindow.name, group: .accessories, order: 200, owner: id,
            command: ZoomToggle.descriptor.id, docKinds: [.notebook]))
        app.ui.menus.register(MenuItemDescriptor(
            id: "zoomwindow.here", title: String(localized: "Zoom"), icon: NibSymbol.zoomWindow.name,
            location: .pageLongPress, order: 700, owner: id, command: ZoomToggle.descriptor.id,
            params: { ctx in zoomHereParams(ctx) }, isVisible: { ctx in canZoom(ctx) }))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: "zoomwindow.box", owner: id, order: 300, docKinds: [.notebook]) { host in ZoomBoxOverlay(host: host) })

        // ⌥⌘Z and ⌥⏎ (canvas scope: not while typing), and bindable to Pencil double-tap / squeeze.
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: toggleActionID, title: title, shortcut: KeyShortcut("z", [.command, .option]),
            command: ZoomToggle.descriptor.id, scope: .canvas, owner: id))
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: newLineActionID, title: newLine, shortcut: KeyShortcut("return", [.option]),
            command: ZoomNewLine.descriptor.id, scope: .canvas, owner: id))
        app.content.pencilActions.register(PencilActionDescriptor(
            id: toggleActionID, title: title, owner: id, command: ZoomToggle.descriptor.id))
        app.content.pencilActions.register(PencilActionDescriptor(
            id: newLineActionID, title: newLine, owner: id, command: ZoomNewLine.descriptor.id))
    }

    /// Key command and Pencil action ids (not command ids).
    static let toggleActionID = "zoomwindow.toggle"
    static let newLineActionID = "zoomwindow.newLine"

    /// Page long-press "Zoom": notebooks only, not in read-only mode.
    static func canZoom(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, ctx.page != nil, ctx.session?.readOnly != true else { return false }
        return (try? ctx.app.workspace.content(doc).meta.kind) == .notebook
    }

    /// Opens the Zoom Window with the box centred where the page was pressed.
    static func zoomHereParams(_ ctx: MenuContext) -> JSONValue {
        var p: [String: JSONValue] = ["on": true]
        if let doc = ctx.doc, let page = ctx.page { p["page"] = .string(NodeRef.page(doc, page).description) }
        if let at = ctx.point { p["at"] = .array([.number(at.x), .number(at.y)]) }
        return .object(p)
    }
}
