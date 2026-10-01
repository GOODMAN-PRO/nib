import SwiftUI
import Combine
import NibContracts
import NibDesign

public enum FeatPenFeature: NibFeature {
    public static let id = "pen"
    private static var observations: [ObjectIdentifier: AnyCancellable] = [:]

    public static func register(_ app: NibApp) {
        InkCommands.register(app)
        PenSettings.declare(app.settings)
        app.content.strokeProcessors.register(StrokeProcessorEntry(id: PenStabilizer.id, order: PenStabilizer.order,
            owner: id, processor: PenStabilizer(settings: app.settings)))
        app.content.strokeProcessors.register(StrokeProcessorEntry(id: PenDynamicsProcessor.id,
            order: PenDynamicsProcessor.order, owner: id, processor: PenDynamicsProcessor()))
        for pencil in [false, true] {
            let tool = pencil ? "pencil" : "pen"
            let title = pencil ? String(localized: "Pencil") : String(localized: "Fountain Pen")
            let key = pencil ? "2" : "p"
            let symbol: NibSymbol = pencil ? .pencil : .pen
            app.ui.canvasTools.register(CanvasToolDescriptor(id: tool, title: title, order: pencil ? 110 : 100,
                owner: id, make: { [settings = app.settings] in PenTool(pencil: pencil, settings: settings) }))
            var item = ToolbarItemDescriptor(id: tool, title: title, icon: symbol.name, group: .tools,
                order: pencil ? 110 : 100, owner: id, toolID: tool, shortcut: KeyShortcut(key),
                activeToolMenu: { [weak app] session in
                    guard let app else { return AnyView(EmptyView()) }
                    return AnyView(PenOptionsBar(app: app, session: session, pencil: pencil))
                }, settings: { [weak app] session in
                    guard let app else { return AnyView(EmptyView()) }
                    return AnyView(PenSettingsView(app: app, session: session, pencil: pencil))
                })
            item.sessionTitle = { [weak app] _ in
                pencil ? String(localized: "Pencil") : PenSettings.penStyle(app?.settings).title
            }
            app.ui.toolbar.register(item)
            app.content.keyCommands.register(KeyCommandDescriptor(id: [id, "select", tool].joined(separator: "."), title: title,
                shortcut: KeyShortcut(key), command: CommandIDs.toolSelect, params: ["tool": .string(tool)],
                scope: .canvas, owner: id))
        }
    }

    public static func start(_ app: NibApp) async {
        observations[ObjectIdentifier(app)] = NotificationCenter.default.publisher(for: SettingsStore.didChange,
            object: app.settings).receive(on: DispatchQueue.main).sink { [weak app] note in
                guard let name = note.userInfo?["name"] as? String,
                      name.hasPrefix("pen.") || name == "presets.pen" || name == "presets.pencil" else { return }
                MainActor.assumeIsolated {
                    guard let app else { return }
                    // The canvas refreshes its PencilKit ink and input mode when its tool descriptor changes.
                    for tool in ["pen", "pencil"] {
                        if let descriptor = app.ui.canvasTools.get(tool) { app.ui.canvasTools.register(descriptor) }
                    }
                    app.ui.setNeedsChromeUpdate()
                }
            }
    }
}

enum PenSettings {
    static let style = SettingKey("pen.style", default: PenStyle.fountain.rawValue, synced: true)
    static let tipSharpness = SettingKey("pen.tipSharpness", default: 0.5, synced: true)
    static let pressure = SettingKey("pen.pressure", default: 0.5, synced: true)
    static let tipFlatness = SettingKey("pen.tipFlatness", default: 0.0, synced: true)
    static let stabilization = SettingKey("pen.stabilization", default: 0.0, synced: true)
    static let scribbleErase = SettingKey("gestures.scribbleErase", default: true, synced: true)
    static let circleLasso = SettingKey("gestures.circleLasso", default: true, synced: true)

    static func declare(_ settings: SettingsStore) {
        settings.declare(style, summary: "Pen style: fountain, ball or brush.", owner: "pen",
                         schema: .str(choices: PenStyle.allCases.map(\.rawValue)))
        for key in [tipSharpness, pressure, tipFlatness, stabilization] {
            settings.declare(key, summary: "Pen nib control, 0…1.", owner: "pen", schema: .num(min: 0, max: 1))
        }
        settings.declare(scribbleErase, summary: "Dense back-and-forth scribbles erase handwriting.", owner: "pen", schema: .bool())
        settings.declare(circleLasso, summary: "Long-press a closed loop within three seconds to select its contents.",
                         owner: "pen", schema: .bool())
    }

    static func penStyle(_ settings: SettingsStore?) -> PenStyle {
        settings.flatMap { PenStyle(rawValue: $0.get(style)) } ?? .fountain
    }

    static func ink(_ settings: SettingsStore, pencil: Bool) -> InkStyle {
        let presets = settings.get(NibSettings.presets(pencil ? "pencil" : "pen"))
        return InkStyle(tool: pencil ? .pencil : .pen, pen: pencil ? nil : penStyle(settings), color: presets.color,
            width: presets.width.isFinite && presets.width > 0 ? min(presets.width, InkLimits.maxWidth) : 1.2,
            pattern: presets.pattern, tipSharpness: settings.get(tipSharpness),
            pressureSensitivity: settings.get(pressure), tipFlatness: settings.get(tipFlatness),
            reactsToRoll: settings.get(NibSettings.penReactsToRoll))
    }
}

extension PenStyle {
    var title: String {
        switch self {
        case .fountain: return String(localized: "Fountain Pen")
        case .ball: return String(localized: "Ball Pen")
        case .brush: return String(localized: "Brush Pen")
        }
    }
}
