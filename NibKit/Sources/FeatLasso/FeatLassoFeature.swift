import SwiftUI
import NibContracts
import NibDesign

/// Lasso & selection (F011): the "lasso" canvas tool (freehand or rectangular, key V, fixed first toolbar slot), the
/// "Included in Selection" filter, quick selection by finger tap (`selection.tapAt`, tap handler order 400), Circle to
/// Lasso (`selection.fromLoop`, called by the pen), and the persistent selection outline (canvas attachment
/// "lasso.selection"). The object menu that opens on a selection is F013's; handles and moving are F012's.
public enum FeatLassoFeature: NibFeature {
    public static let id = "lasso"

    public static func register(_ app: NibApp) {
        app.commands.register(SelectionSet.self)
        app.commands.register(SelectionClear.self)
        app.commands.register(SelectionFromPolygon.self)
        app.commands.register(SelectionFromRect.self)
        app.commands.register(SelectionFromLoop.self)
        app.commands.register(SelectionSelectAll.self)
        app.commands.register(SelectionTapAt.self)

        app.settings.declare(LassoSettings.type, summary: "Lasso shape: freehand or rectangle.", owner: id,
                             schema: .str(choices: LassoType.allCases.map { $0.rawValue }))
        app.settings.declare(LassoSettings.include,
                             summary: "Kinds the lasso selects (Included in Selection): " + LassoCategory.names.joined(separator: ", ") + ".",
                             owner: id, schema: .arr(.str(choices: LassoCategory.names)))

        app.ui.canvasTools.register(CanvasToolDescriptor(id: SelectionSupport.lassoTool, title: String(localized: "Lasso"),
                                                         owner: id, make: { LassoTool() }))
        app.ui.toolbar.register(toolbarItem(app, type: LassoSettings.type.defaultValue))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "lasso.selection", owner: id, order: 100,
                                                                     make: { _ in SelectionOverlay() }))
        app.content.tapHandlers.register(TapHandlerDescriptor(id: "selection.tapAt", owner: id, gesture: .tap,
                                                              command: "selection.tapAt", order: 400))
    }

    public static func start(_ app: NibApp) async {
        LassoHousekeeping.start(app)
    }

    /// The fixed first toolbar slot. Its glyph follows `lasso.type` (DESIGN.md §8.1: `lasso` / `rectangle.dashed`).
    static func toolbarItem(_ app: NibApp, type: LassoType) -> ToolbarItemDescriptor {
        ToolbarItemDescriptor(
            id: SelectionSupport.lassoTool, title: String(localized: "Lasso"), icon: type.symbol.name, group: .lasso,
            order: 0, owner: id, toolID: SelectionSupport.lassoTool, shortcut: KeyShortcut("v"), hideable: false,
            settings: { session in AnyView(LassoSettingsView(app: app, session: session)) })
    }
}

enum LassoType: String, Codable, CaseIterable {
    case freehand, rectangle

    var symbol: NibSymbol {
        switch self {
        case .freehand: return .lasso
        case .rectangle: return .lassoRectangle
        }
    }
}

enum LassoSettings {
    static let type = SettingKey("lasso.type", default: LassoType.freehand, synced: true)
    /// Category raw values (`LassoCategory`); every category by default.
    static let include = SettingKey("lasso.include", default: LassoCategory.names, synced: true)

    static func included(_ settings: SettingsStore) -> Set<LassoCategory> {
        Set(settings.get(include).compactMap { LassoCategory(rawValue: $0) })
    }
}
