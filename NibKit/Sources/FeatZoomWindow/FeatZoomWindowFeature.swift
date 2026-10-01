import Foundation
import SwiftUI
import NibContracts
import NibDesign

/// Zoom Window (F038; Goodnotes T-073, T-104, P-029): write large in a pane docked at the bottom while the zoom box on
/// the page shows where the ink lands. Opened from the accessory toolbar item, the page long-press "Zoom", ⌥⌘Z or a
/// Pencil action; auto-advance (`NibSettings.zoomAutoAdvance`) moves the box along as you write.
public enum FeatZoomWindowFeature: NibFeature {
    public static let id = "zoomwindow"

    public static func register(_ app: NibApp) {
        let store = ZoomStore()
        app.services.set(store, for: ZoomStore.key)

        app.commands.register(ZoomToggle.self)
        app.commands.register(ZoomSetBox.self)
        app.commands.register(ZoomNewLine.self)
        app.commands.register(ZoomSetReturnHeight.self)

        let title = String(localized: "Zoom Window")
        let newLine = String(localized: "New Line in Zoom Window")
        var item = ToolbarItemDescriptor(
            id: "zoomwindow", title: title, icon: NibSymbol.zoomWindow.name, group: .accessories, order: 200, owner: id,
            command: ZoomToggle.descriptor.id, docKinds: [.notebook])
        // Live state (contracts-v2): on while this window's Zoom Window is open; zoom.toggle refuses to open it in
        // read-only mode, so there the item only closes it.
        item.isOn = { session in store.isOn(in: session) }
        item.isEnabled = { session in !session.readOnly || store.isOn(in: session) }
        app.ui.toolbar.register(item)
        app.ui.menus.register(MenuItemDescriptor(
            id: "zoomwindow.here", title: String(localized: "Zoom"), icon: NibSymbol.zoomWindow.name,
            location: .pageLongPress, order: 700, owner: id, command: ZoomToggle.descriptor.id,
            params: { ctx in zoomHereParams(ctx) }, isVisible: { ctx in canZoom(ctx) }))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: "zoomwindow.box", owner: id, order: 300, docKinds: [.notebook]) { host in ZoomBoxOverlay(host: host) })
        // The writing pane: a Deep panel the document chrome docks at the bottom of the window, inside its droplet
        // container (contracts-v2 chrome overlay). Its canvas's zoom box attachment owns it, so it shows while that
        // canvas shows the box's page.
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: paneOverlayID, owner: id, placement: .bottom, surface: .panel, order: 300, docKinds: [.notebook],
            isVisible: { ctx in store.activePane(for: ctx.session) != nil },
            makeView: { ctx in
                guard let pane = store.activePane(for: ctx.session) else { return AnyView(EmptyView()) }
                // A new canvas (another document in this window) brings its own pane: a new view, not an update.
                return AnyView(ZoomPane(controller: pane, state: pane.state, writing: pane.writingView())
                    .id(ObjectIdentifier(pane)))
            }))

        // ⌥⌘Z and ⌥⏎ (canvas scope: not while typing; notebooks only), and bindable to Pencil double-tap / squeeze.
        var toggle = KeyCommandDescriptor(
            id: toggleActionID, title: title, shortcut: KeyShortcut("z", [.command, .option]),
            command: ZoomToggle.descriptor.id, scope: .canvas, owner: id)
        toggle.docKinds = [.notebook]
        app.content.keyCommands.register(toggle)
        var line = KeyCommandDescriptor(
            id: newLineActionID, title: newLine, shortcut: KeyShortcut("return", [.option]),
            command: ZoomNewLine.descriptor.id, scope: .canvas, owner: id)
        line.docKinds = [.notebook]
        app.content.keyCommands.register(line)
        app.content.pencilActions.register(PencilActionDescriptor(
            id: toggleActionID, title: title, owner: id, command: ZoomToggle.descriptor.id))
        app.content.pencilActions.register(PencilActionDescriptor(
            id: newLineActionID, title: newLine, owner: id, command: ZoomNewLine.descriptor.id))
    }

    /// The pane's chrome overlay id.
    static let paneOverlayID = "zoomwindow.pane"
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
