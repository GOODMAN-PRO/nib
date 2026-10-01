import SwiftUI
import Combine
import NibContracts
import NibDesign

@MainActor
final class PenOptions: ObservableObject {
    let app: NibApp
    let session: EditorSession
    let tool: String
    @Published private var values: [String: JSONValue] = [:]
    @Published private(set) var writingAids: DocumentMeta?
    @Published private(set) var writingAidsError: String?
    private var settingsObservation: AnyCancellable?
    private var commits: EventSubscription?

    init(app: NibApp, session: EditorSession, pencil: Bool, observesWritingAids: Bool = false) {
        self.app = app; self.session = session; tool = pencil ? "pencil" : "pen"
        settingsObservation = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let name = note.userInfo?["name"] as? String else { return }
                MainActor.assumeIsolated { self?.values.removeValue(forKey: name); self?.objectWillChange.send() }
            }
        if observesWritingAids {
            commits = app.events.subscribe { [weak self] event in
                guard event.type == NibEventType.committed else { return }
                Task { @MainActor in
                    guard let self, event.doc == self.session.document else { return }
                    await self.loadWritingAids()
                }
            }
        }
    }

    func value<V>(_ key: SettingKey<V>) -> V {
        values[key.name].flatMap { try? $0.decode(V.self) } ?? app.settings.get(key)
    }

    func binding<V>(_ key: SettingKey<V>) -> Binding<V> {
        Binding(get: { self.value(key) }, set: { self.set(key, $0) })
    }

    func set<V>(_ key: SettingKey<V>, _ value: V) {
        guard let json = try? JSONValue.from(value) else { return }
        values[key.name] = json
        app.perform(CommandIDs.settingsSet, ["name": .string(key.name), "value": json], session: session)
    }

    var presets: ToolPresets { value(NibSettings.presets(tool)) }
    func changePreset(_ body: (inout ToolPresets) -> Void) {
        var presets = self.presets
        body(&presets)
        set(NibSettings.presets(tool), presets)
    }

    var width: Binding<Double> {
        Binding(get: { self.presets.width * 25.4 / 72 }, set: { millimetres in
            self.changePreset {
                if !$0.widths.indices.contains($0.selectedWidth) { $0.selectedWidth = 0 }
                if $0.widths.isEmpty { $0.widths = ToolPresets.defaults(for: self.tool).widths }
                $0.widths[$0.selectedWidth] = millimetres * 72 / 25.4
            }
        })
    }

    var pattern: Binding<StrokePattern> {
        Binding(get: { self.presets.pattern }, set: { pattern in self.changePreset {
            let index = max(0, min($0.selectedWidth, max(0, $0.widths.count - 1)))
            while $0.patterns.count <= index { $0.patterns.append(.solid) }
            $0.patterns[index] = pattern
        } })
    }

    func chooseColour(_ colour: RGBA) {
        changePreset {
            if let index = $0.swatches.firstIndex(where: { $0.color == colour }) { $0.selectedSwatch = index }
            else if $0.swatches.count < ToolPresets.maxSwatches {
                $0.swatches.append(PresetSwatch(color: colour)); $0.selectedSwatch = $0.swatches.count - 1
            } else {
                let index = max(0, min($0.selectedSwatch, $0.swatches.count - 1))
                $0.swatches[index] = PresetSwatch(color: colour); $0.selectedSwatch = index
            }
        }
    }

    var swatch: Binding<String?> {
        Binding(get: { NibInk.allCases.first(where: { RGBA($0.uiColor) == self.presets.color })?.rawValue },
                set: { name in if let name, let ink = NibInk(rawValue: name) { self.chooseColour(RGBA(ink.uiColor)) } })
    }

    var customColour: Binding<Color> {
        Binding(get: { Color(uiColor: self.presets.color.uiColor) }, set: { self.chooseColour(RGBA(UIColor($0))) })
    }

    var disconnectStylus: Binding<Bool> {
        Binding(get: { self.value(NibSettings.stylusMode) == .anyInput },
                set: { self.set(NibSettings.stylusMode, $0 ? .anyInput : .pencilOnly) })
    }

    func loadWritingAids() async {
        guard let doc = session.document, app.commands.entry(CommandIDs.queryGet) != nil,
              app.commands.entry(CommandIDs.docSetWritingAids) != nil else { return }
        do {
            let result = try await app.bus.execute(CommandIDs.queryGet,
                ["ref": .string(NodeRef.document(doc).description), "fields": .array([.string("meta")])], session: session)
            writingAids = try (result["meta"] ?? result).decode(DocumentMeta.self)
            writingAidsError = nil
        } catch { writingAidsError = NibError.wrap(error).message }
    }

    deinit { commits?.cancel() }

    func writingAid(_ key: String) -> Binding<Bool> {
        Binding(get: { key == "spellcheck" ? self.writingAids?.spellcheck ?? false : self.writingAids?.mathAssist ?? false },
                set: { enabled in
            guard let doc = self.session.document else { return }
            self.app.perform(CommandIDs.docSetWritingAids,
                ["doc": .string(NodeRef.document(doc).description), key: .bool(enabled)], session: self.session)
        })
    }
}

struct PenSettingsView: View {
    @ObservedObject private var session: EditorSession
    @StateObject private var model: PenOptions
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var gesturesExpanded = false

    init(app: NibApp, session: EditorSession, pencil: Bool) {
        _session = ObservedObject(wrappedValue: session)
        _model = StateObject(wrappedValue: PenOptions(app: app, session: session, pencil: pencil, observesWritingAids: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xl) {
            typeGrid
            NibStrokeWidthSlider(width: model.width, range: 0.1...3,
                presets: ToolPresets.defaults(for: model.tool).widths.map { $0 * 25.4 / 72 })
            NibInspectorSection(String(localized: "Colour")) {
                NibSwatchGrid(swatches: NibInk.allCases.map { NibSwatch(ink: $0) }, selection: model.swatch,
                              columns: typeSize.isAccessibilitySize ? 3 : 6)
                ColorPicker(String(localized: "Custom…"), selection: model.customColour, supportsOpacity: false)
                    .font(NibFont.body).foregroundStyle(NibColor.label).frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(String(localized: "Choose custom ink colour"))
            }
            slider(String(localized: "Pressure sensitivity"), key: PenSettings.pressure)
                .disabled(model.tool == "pen" && model.value(PenSettings.style) == PenStyle.ball.rawValue)
            if model.tool == "pen" {
                slider(String(localized: "Tip sharpness"), key: PenSettings.tipSharpness)
                    .disabled(model.value(PenSettings.style) == PenStyle.ball.rawValue)
                if model.value(PenSettings.style) == PenStyle.fountain.rawValue {
                    slider(String(localized: "Tip flatness"), key: PenSettings.tipFlatness)
                    NibToggle(String(localized: "React to Pen Rotation"), isOn: model.binding(NibSettings.penReactsToRoll))
                    Text(String(localized: "Barrel rotation requires Apple Pencil Pro. Other styluses keep a fixed nib."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            slider(String(localized: "Stabilisation"), key: PenSettings.stabilization)
            NibInspectorSection(String(localized: "Stroke pattern")) {
                NibSegmentedControl(selection: model.pattern, options: StrokePattern.allCases, title: { $0.title })
            }
            NibToggle(String(localized: "Draw and Hold"), isOn: model.binding(NibSettings.drawAndHold))
            DisclosureGroup(String(localized: "Pen gestures…"), isExpanded: $gesturesExpanded) {
                VStack(spacing: NibSpacing.s) {
                    NibToggle(String(localized: "Scribble to Erase"), isOn: model.binding(PenSettings.scribbleErase))
                    NibToggle(String(localized: "Circle to Lasso"), isOn: model.binding(PenSettings.circleLasso))
                    Text(String(localized: "Draw a loop, then hold inside it within three seconds to select its contents."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, NibSpacing.s)
            }.font(NibFont.body).foregroundStyle(NibColor.label).frame(minHeight: NibMetrics.hitTarget)
            NibInspectorSection(String(localized: "Writing Aids")) {
                NibToggle(String(localized: "Handwriting spellcheck"), isOn: model.writingAid("spellcheck"))
                NibToggle(String(localized: "Math Assist"), isOn: model.writingAid("mathAssist"))
                if let error = model.writingAidsError {
                    NibBanner(error, action: NibAction(String(localized: "Try Again")) {
                        Task { await model.loadWritingAids() }
                    })
                }
            }.disabled(model.writingAids == nil || session.readOnly)
            NibToggle(String(localized: "Reduce Latency"), isOn: model.binding(NibSettings.reduceLatency))
            NibToggle(String(localized: "Disconnect Stylus"), isOn: model.disconnectStylus)
            Text(String(localized: "Draw with your finger when the stylus is disconnected. Connect it again to let fingers scroll."))
                .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: session.document) { await model.loadWritingAids() }
    }

    private var typeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NibSpacing.xs),
                                 count: typeSize.isAccessibilitySize ? 2 : 4), spacing: NibSpacing.xs) {
            ForEach(PenStyle.allCases, id: \.self) { style in
                NibOptionTile(style.shortTitle, isSelected: session.tool == "pen" && model.value(PenSettings.style) == style.rawValue,
                    action: {
                        model.set(PenSettings.style, style.rawValue)
                        model.app.perform(CommandIDs.toolSelect, ["tool": "pen"], session: session)
                    }) { NibOptionGlyph(.pen) }
                    .accessibilityLabel(style.title)
            }
            NibOptionTile(String(localized: "Pencil"), isSelected: session.tool == "pencil", action: {
                model.app.perform(CommandIDs.toolSelect, ["tool": "pencil"], session: session)
            }) { NibOptionGlyph(.pencil) }
        }
    }

    private func slider(_ title: String, key: SettingKey<Double>) -> some View {
        NibInspectorSection(title, value: model.value(key).formatted(.percent.precision(.fractionLength(0)))) {
            NibSlider(value: model.binding(key), label: title)
        }
    }
}

struct PenOptionsBar: View {
    @StateObject private var model: PenOptions
    init(app: NibApp, session: EditorSession, pencil: Bool) {
        _model = StateObject(wrappedValue: PenOptions(app: app, session: session, pencil: pencil))
    }
    var body: some View {
        HStack(spacing: NibSpacing.s) {
            ForEach(Array(model.presets.widths.prefix(3).enumerated()), id: \.offset) { index, width in
                NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(index),
                    isSelected: model.presets.selectedWidth == index,
                    label: String(localized: "Ink width \((width * 25.4 / 72).formatted(.number.precision(.fractionLength(2)))) millimetres")) {
                    model.changePreset { $0.selectedWidth = index }
                }
            }
        }
    }
}

extension PenStyle {
    var shortTitle: String {
        switch self {
        case .fountain: return String(localized: "Fountain")
        case .ball: return String(localized: "Ball")
        case .brush: return String(localized: "Brush")
        }
    }
}
extension StrokePattern {
    var title: String {
        switch self {
        case .solid: return String(localized: "Solid")
        case .dashed: return String(localized: "Dashed")
        case .dotted: return String(localized: "Dotted")
        }
    }
}
