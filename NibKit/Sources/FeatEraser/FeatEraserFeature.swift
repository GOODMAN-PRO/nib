import SwiftUI
import NibContracts
import NibDesign

/// Eraser tool (key E), Clear Page and Delete Specific Items (F010: T-018…T-023, T-093, D-062, S-040).
/// Commands: `ink.erase`, `ink.scribbleErase`, `page.clear`, `page.deleteItems`. The pen's Scribble to Erase gesture
/// (F007) calls `ink.scribbleErase`.
public enum FeatEraserFeature: NibFeature {
    public static let id = "eraser"
    static let toolID = "eraser"
    static let deleteItemsPanel = "eraser.deleteItems"

    public static func register(_ app: NibApp) {
        app.commands.register(InkErase.self)
        app.commands.register(InkScribbleErase.self)
        app.commands.register(PageClear.self)
        app.commands.register(PageDeleteItems.self)
        EraserSettings.declare(app.settings, owner: id)

        let title = String(localized: "Eraser")
        app.ui.canvasTools.register(CanvasToolDescriptor(id: toolID, title: title, order: 300, owner: id,
                                                         make: { EraserTool() }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: toolID, title: title, icon: NibSymbol.eraser.name, group: .tools, order: 300, owner: id,
            toolID: toolID, shortcut: KeyShortcut("e"),
            activeToolMenu: { [weak app] session in
                guard let app = app else { return AnyView(EmptyView()) }
                return AnyView(EraserOptionsBar(app: app))
            },
            settings: { [weak app] session in
                guard let app = app else { return AnyView(EmptyView()) }
                return AnyView(EraserSettingsView(app: app, session: session))
            }))

        app.ui.menus.register(MenuItemDescriptor(
            id: "eraser.clearPage", title: String(localized: "Clear Page"), icon: NibSymbol.eraser.name,
            location: .documentMore, order: 700, owner: id, command: CommandIDs.pageClear,
            params: { ctx in pageParams(ctx) }, isVisible: { ctx in canEdit(ctx) }, destructive: true))
        app.ui.menus.register(MenuItemDescriptor(
            id: "eraser.deleteItems", title: String(localized: "Delete Specific Items…"), icon: NibSymbol.trash.name,
            location: .documentMore, order: 710, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(deleteItemsPanel)] }, isVisible: { ctx in canEdit(ctx) }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "eraser.clearPage.thumbnail", title: String(localized: "Clear Page"), icon: NibSymbol.eraser.name,
            location: .sidebarPage, order: 700, owner: id, command: CommandIDs.pageClear,
            params: { ctx in pageParams(ctx) }, isVisible: { ctx in canEdit(ctx) }, destructive: true))

        var sheet = PanelDescriptor(
            id: deleteItemsPanel, title: String(localized: "Delete Specific Items"), icon: NibSymbol.trash.name,
            placement: .sheet, order: 900, owner: id, docKinds: [.notebook, .whiteboard],
            makeView: { context in AnyView(DeleteItemsSheet(context: context)) })
        // The sheet draws its own NibSheetHeader (Cancel, title, "Delete n Items"), so the chrome adds none.
        sheet.providesHeader = true
        app.ui.panels.register(sheet)
    }

    /// The page a menu acts on: the long-pressed thumbnail, else the window's current page.
    static func pageRef(_ ctx: MenuContext) -> String? {
        guard let doc = ctx.doc ?? ctx.session?.document, let page = ctx.page ?? ctx.session?.page else { return nil }
        return NodeRef.page(doc, page).description
    }

    static func pageParams(_ ctx: MenuContext) -> JSONValue {
        guard let ref = pageRef(ctx) else { return [:] }
        return ["page": .string(ref)]
    }

    static func canEdit(_ ctx: MenuContext) -> Bool {
        pageRef(ctx) != nil && !(ctx.session?.readOnly ?? false)
    }
}

/// The eraser's settings (synced, so they follow the library). Mode, size and the Erase Filter are the shared
/// `NibSettings` keys (contracts-v2 G13), which the Zoom Window (F038) and the Pencil hover preview (F043) read too;
/// F010 owns them and re-declares them under its own id. The UI changes them through `settings.set`, like plugins and
/// the AI can.
enum EraserSettings {
    /// Return to the previous tool when the eraser lifts (T-021). Only the eraser reads it.
    static let autoDeselect = SettingKey("eraser.autoDeselect", default: false, synced: true)
    /// Size presets in screen points (T-093); the slider sets anything in `sizeRange`.
    static let presets: [Double] = [6, 14, 28]
    static let sizeRange: ClosedRange<Double> = 2...60

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(NibSettings.eraserMode,
                  summary: "Eraser mode: precision (cuts at the edge), standard (touched segments) or stroke (whole strokes).",
                  owner: owner, schema: .str(choices: EraserMode.allCases.map { $0.rawValue }))
        s.declare(NibSettings.eraserSize, summary: "Eraser diameter in screen points (presets 6, 14 and 28).", owner: owner,
                  schema: .num(min: sizeRange.lowerBound, max: sizeRange.upperBound))
        s.declare(autoDeselect, summary: "Return to the previous tool after each erase.", owner: owner, schema: .bool())
        for tool in InkTool.allCases {
            s.declare(NibSettings.eraserFilter(tool), summary: "The eraser erases \(tool.rawValue) strokes.", owner: owner,
                      schema: .bool())
        }
    }

    /// The stored mode; an unknown value (a newer app, a hand-edited file) erases like the default.
    static func mode(_ s: SettingsStore) -> EraserMode {
        EraserMode(rawValue: s.get(NibSettings.eraserMode)) ?? .standard
    }

    /// The eraser's on-screen diameter, clamped to what the slider offers.
    static func size(_ s: SettingsStore) -> Double {
        clamped(s.get(NibSettings.eraserSize))
    }

    static func filter(_ s: SettingsStore) -> Set<InkTool> {
        Set(InkTool.allCases.filter { s.get(NibSettings.eraserFilter($0)) })
    }

    static func clamped(_ size: Double) -> Double {
        min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
