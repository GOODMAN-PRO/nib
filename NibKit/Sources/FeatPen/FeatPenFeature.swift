import SwiftUI
import Combine
import NibContracts
import NibDesign

public enum FeatPenFeature: NibFeature {
    public static let id = "pen"

    public static func register(_ app: NibApp) {
        InkCommands.register(app)
        app.ui.inspectors.register(InspectorDescriptor(
            id: "pen.strokeStyle", title: String(localized: "Ink"), icon: NibSymbol.pen.name,
            itemKinds: [.stroke], order: 100, owner: id) { context in
                AnyView(StrokeStyleInspector(context: context)
                    .id(context.items.map { NodeRef.item(context.doc, context.page, $0.id).description }))
            })
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

/// Edits existing ink, never the active tool's presets. One inspector interaction session is one undo group.
@MainActor
final class StrokeInspectorModel: ObservableObject {
    let context: InspectorContext
    let ids: [ElementID]
    private let group = NibID.make().raw
    @Published private(set) var style: InkStyle
    private(set) var pending: Task<Void, Never>?
    private var observation: EventSubscription?

    init(context: InspectorContext) {
        self.context = context
        ids = context.items.filter { $0.stroke != nil && !$0.locked }.map(\.id)
        style = context.items.compactMap(\.stroke).first?.style ?? .defaultPen
        observation = context.app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.committed else { return }
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { observation?.cancel() }

    private func refresh() {
        guard let id = ids.first,
              let stroke = try? context.app.workspace.item(context.doc, page: context.page, id: id).stroke else { return }
        style = stroke.style
    }

    func change(_ patch: JSONValue) {
        guard !ids.isEmpty, !context.session.readOnly else { return }
        let previous = pending
        pending = Task { @MainActor [self] in
            await previous?.value
            let refs = ids.map { JSONValue.string(NodeRef.item(context.doc, context.page, $0).description) }
            do {
                _ = try await context.app.bus.execute(Invocation(command: CommandIDs.inkSetStyle,
                    params: ["refs": .array(refs), "style": patch], session: context.session, group: group))
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: context.app,
                    userInfo: ["command": CommandIDs.inkSetStyle, "error": NibError.wrap(error)])
            }
            refresh()
        }
    }

    var width: Binding<Double> {
        Binding(get: { self.style.width * 25.4 / 72 },
                set: { self.change(["width": .number($0 * 72 / 25.4)]) })
    }
    var widthRange: ClosedRange<Double> { 0.1...max(3, style.width * 25.4 / 72) }
    var canChangeColour: Bool {
        !ids.contains { id in
            guard let stroke = try? context.app.workspace.item(context.doc, page: context.page, id: id).stroke else { return false }
            return stroke.style.tool == .tape && stroke.style.tapePattern != nil
        }
    }
    var swatch: Binding<String?> {
        Binding(get: { NibInk.allCases.first { RGBA($0.uiColor) == self.style.color }?.rawValue },
                set: { name in
                    if let name, let ink = NibInk(rawValue: name) {
                        self.change(["color": .string(RGBA(ink.uiColor).hex)])
                    }
                })
    }
    var pattern: Binding<StrokePattern> {
        Binding(get: { self.style.pattern }, set: { self.change(["pattern": .string($0.rawValue)]) })
    }
}

struct StrokeStyleInspector: View {
    @StateObject private var model: StrokeInspectorModel
    init(context: InspectorContext) {
        _model = StateObject(wrappedValue: StrokeInspectorModel(context: context))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibStrokeWidthSlider(width: model.width, range: model.widthRange)
            if model.canChangeColour {
                NibInspectorSection(String(localized: "Colour")) {
                    NibSwatchGrid(swatches: NibInk.allCases.map { NibSwatch(ink: $0) }, selection: model.swatch)
                }
            }
            NibInspectorSection(String(localized: "Stroke pattern")) {
                NibSegmentedControl(selection: model.pattern, options: StrokePattern.allCases, title: { $0.title })
            }
        }
        .disabled(model.ids.isEmpty || model.context.session.readOnly)
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
        for session in app.services.sessions.sessions {
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
