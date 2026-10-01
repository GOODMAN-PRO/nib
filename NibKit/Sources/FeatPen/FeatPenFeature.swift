import SwiftUI
import Combine
import NibContracts
import NibDesign

public enum FeatPenFeature: NibFeature {
    public static let id = "pen"

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
        app.services.set(PenToolObservation(app), for: "pen.toolObservation")
    }

    public static func stop(_ app: NibApp) {
        app.services.set(nil, for: "pen.toolObservation")
    }
}

/// Owned by the app's services, so subscriptions end with the app rather than a static dictionary.
@MainActor
private final class PenToolObservation {
    private weak var app: NibApp?
    private var settings: AnyCancellable?
    private var idle: [EventSubscription] = []
    private var pending = false
    private static let inkKeys: Set<String> = ["pen.style", "pen.tipSharpness", "pen.pressure",
        "pen.tipFlatness", "pen.reactToRoll", "presets.pen", "presets.pencil"]

    init(_ app: NibApp) {
        self.app = app
        settings = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String, Self.inkKeys.contains(name) else { return }
                MainActor.assumeIsolated { self?.requestRefresh() }
            }
    }

    private func requestRefresh() {
        pending = true
        idle.forEach { $0.cancel() }; idle = []
        guard let app else { return }
        for session in app.services.sessions.sessions where session.inking.isInking {
            idle.append(session.inking.observe { [weak self] signal in
                if !signal.isInking { self?.flush() }
            })
        }
        flush()
    }

    private func flush() {
        guard pending, let app, !app.services.sessions.sessions.contains(where: { $0.inking.isInking }) else { return }
        pending = false
        idle.forEach { $0.cancel() }; idle = []
        for tool in ["pen", "pencil"] {
            if let descriptor = app.ui.canvasTools.get(tool) { app.ui.canvasTools.register(descriptor) }
        }
        app.ui.setNeedsChromeUpdate()
    }

    deinit { idle.forEach { $0.cancel() } }
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
