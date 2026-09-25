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
            location: .documentMore, order: 700, owner: id, command: "page.clear",
            params: { ctx in pageParams(ctx) }, isVisible: { ctx in canEdit(ctx) }, destructive: true))
        app.ui.menus.register(MenuItemDescriptor(
            id: "eraser.deleteItems", title: String(localized: "Delete Specific Items…"), icon: NibSymbol.trash.name,
            location: .documentMore, order: 710, owner: id, command: "panel.open",
            params: { _ in ["id": .string(deleteItemsPanel)] }, isVisible: { ctx in canEdit(ctx) }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "eraser.clearPage.thumbnail", title: String(localized: "Clear Page"), icon: NibSymbol.eraser.name,
            location: .sidebarPage, order: 700, owner: id, command: "page.clear",
            params: { ctx in pageParams(ctx) }, isVisible: { ctx in canEdit(ctx) }, destructive: true))

        app.ui.panels.register(PanelDescriptor(
            id: deleteItemsPanel, title: String(localized: "Delete Specific Items"), icon: NibSymbol.trash.name,
            placement: .sheet, order: 900, owner: id, docKinds: [.notebook, .whiteboard],
            makeView: { context in AnyView(DeleteItemsSheet(context: context)) }))
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

/// The eraser's settings (synced, so they follow the library). The UI changes them through `settings.set`, like
/// plugins and the AI can.
enum EraserSettings {
    static let mode = SettingKey("eraser.mode", default: EraserMode.standard, synced: true)
    /// On-screen diameter in points: zooming in erases a smaller area of the page, as in Goodnotes.
    static let size = SettingKey("eraser.size", default: 14.0, synced: true)
    /// Return to the previous tool when the eraser lifts (T-021).
    static let autoDeselect = SettingKey("eraser.autoDeselect", default: false, synced: true)
    /// Size presets (T-093); the slider sets anything in `sizeRange`.
    static let presets: [Double] = [6, 14, 28]
    static let sizeRange: ClosedRange<Double> = 2...60

    /// Erase Filter (T-019): one key per ink tool, all on by default.
    static func filterKey(_ tool: InkTool) -> SettingKey<Bool> {
        SettingKey("eraser.filter." + tool.rawValue, default: true, synced: true)
    }

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(mode, summary: "Eraser mode: precision (cuts at the edge), standard (touched segments) or stroke (whole strokes).",
                  owner: owner, schema: .str(choices: EraserMode.allCases.map { $0.rawValue }))
        s.declare(size, summary: "Eraser diameter in screen points (presets 6, 14 and 28).", owner: owner,
                  schema: .num(min: sizeRange.lowerBound, max: sizeRange.upperBound))
        s.declare(autoDeselect, summary: "Return to the previous tool after each erase.", owner: owner, schema: .bool())
        for tool in InkTool.allCases {
            s.declare(filterKey(tool), summary: "The eraser erases \(tool.rawValue) strokes.", owner: owner, schema: .bool())
        }
    }

    static func filter(_ s: SettingsStore) -> Set<InkTool> {
        Set(InkTool.allCases.filter { s.get(filterKey($0)) })
    }

    static func clamped(_ size: Double) -> Double {
        min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
