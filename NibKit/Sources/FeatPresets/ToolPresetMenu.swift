import SwiftUI
import UIKit
import Combine
import Observation
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// MARK: - Pure helpers

/// Thickness sliders run on a logarithmic scale, so the fine pen widths get most of the travel.
enum WidthScale {
    static func position(_ width: Double, range: ClosedRange<Double>) -> Double {
        let w = min(max(width, range.lowerBound), range.upperBound)
        return log(w / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    /// The width at a slider position, rounded to 0.01 pt.
    static func width(at position: Double, range: ClosedRange<Double>) -> Double {
        let t = min(max(position, 0), 1)
        let w = range.lowerBound * pow(range.upperBound / range.lowerBound, t)
        return min(max((w * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }
}

enum PresetText {
    static func toolName(_ tool: String) -> String {
        switch tool {
        case "pen": return String(localized: "Pen")
        case "pencil": return String(localized: "Pencil")
        case "highlighter": return String(localized: "Highlighter")
        case "tape": return String(localized: "Tape")
        case "shape": return String(localized: "Shapes")
        case "drawShape": return String(localized: "Draw Shape")
        default: return tool
        }
    }

    static func millimetres(_ points: Double) -> String {
        String(format: String(localized: "%.2f mm"), points * 25.4 / 72)
    }

    static func points(_ points: Double) -> String {
        String(format: String(localized: "%.1f pt"), points)
    }

    static func patternName(_ pattern: StrokePattern) -> String {
        switch pattern {
        case .solid: return String(localized: "Solid")
        case .dashed: return String(localized: "Dashed")
        case .dotted: return String(localized: "Dotted")
        }
    }

    /// VoiceOver value of a thickness: "0.42 millimetres, 1.2 points, dashed".
    static func widthValue(_ points: Double, pattern: StrokePattern) -> String {
        let mm = String(format: String(localized: "%.2f millimetres"), points * 25.4 / 72)
        let pt = String(format: String(localized: "%.1f points"), points)
        return pattern == .solid ? "\(mm), \(pt)" : "\(mm), \(pt), \(patternName(pattern))"
    }
}

/// A line pattern as a stroke style (round caps, so a zero-length dash is a dot).
enum PresetStroke {
    static func style(lineWidth: CGFloat, pattern: StrokePattern) -> StrokeStyle {
        switch pattern {
        case .solid: return StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        case .dashed: return StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [lineWidth + 3, lineWidth + 2.5])
        case .dotted: return StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [0.001, lineWidth + 2.5])
        }
    }
}

// MARK: - Menu state

/// What the options bar buds (contracts-v2 `ToolMenuDescriptor.makePopover`): the palette places it beside the bar,
/// as a full-size child of the window's container, and closes it when the tool changes.
enum PresetPopover: Equatable {
    /// A thickness slot's slider (mm and pt) and, for the pen and pencil, its line pattern.
    case width(Int)
    /// Changing one colour slot, or adding one.
    case colour(ColourTarget)
}

/// The state one window's options bar and its popover share for one tool: the tool's presets (read from
/// `NibSettings.presets(tool)` and following every change to it: this window, another window, a synced device, the
/// AI), which popover is open, and whether the bar is rearranging. Observable, so the bar, the popover and whatever
/// reads the popover's `isPresented` (the palette's bud) follow it. Every change it makes is a `preset.*` command.
@MainActor
@Observable
final class PresetMenuModel {
    let tool: String
    @ObservationIgnored private(set) weak var app: NibApp?
    @ObservationIgnored private(set) weak var session: EditorSession?

    private(set) var presets: ToolPresets
    /// The open popover; nil while closed.
    private(set) var popover: PresetPopover?
    /// What the popover shows and the control it buds from: the open one, or the last one while it retracts.
    private(set) var shown: PresetPopover = .width(1)
    /// Remove and reorder colour slots, restore the defaults (a mode of the bar itself).
    private(set) var arranging = false
    /// The thickness slider (0…1 on the tool's logarithmic scale) of the thickness slot `shown` names.
    private(set) var widthPosition: Double = 0

    @ObservationIgnored private var settingsWatch: AnyCancellable?
    @ObservationIgnored private var pendingWidth: Task<Void, Never>?

    init(app: NibApp, session: EditorSession, tool: String) {
        self.app = app
        self.session = session
        self.tool = tool
        let initial = PresetRules.normalized(app.settings.get(PresetRules.key(tool)), tool: tool)
        presets = initial
        widthPosition = WidthScale.position(initial.widths[1], range: PresetRules.widthRange(tool))
        let name = PresetRules.key(tool).name
        // The store posts on the writing thread (a synced-prefs merge can be off main).
        settingsWatch = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .filter { ($0.userInfo?["name"] as? String) == name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    /// The control the popover buds from carries this `nibBudAnchor` (the one `shown` names), so the source id the
    /// palette holds never goes stale.
    static func anchorID(_ tool: String) -> String { "presets.\(tool).popoverSource" }

    var range: ClosedRange<Double> { PresetRules.widthRange(tool) }

    /// The thickness the slider shows, rounded to 0.01 pt.
    var editedWidth: Double { WidthScale.width(at: widthPosition, range: range) }

    /// The colour slot the colour popover edits; nil when it adds one (or that slot is gone).
    var colourSlot: Int? {
        if case .colour(.slot(let i)) = shown, presets.swatches.indices.contains(i) { return i }
        return nil
    }

    /// The slot being edited, or the selected one when adding (its colour seeds the picker and the patterns).
    var editedSwatch: PresetSwatch { presets.swatches[colourSlot ?? presets.selectedSwatch] }

    /// The edited slot's pattern as a `TapePatternDescriptor.id` (the pinned "<id>.png" ref, or a bare legacy id).
    var editedPatternID: String? { editedSwatch.pattern.map(PresetSwatch.tapePatternID) }

    var isPresented: Binding<Bool> {
        Binding(get: { [weak self] in self?.popover != nil },
                set: { [weak self] presented in if !presented { self?.close() } })
    }

    /// The popover the palette buds beside the bar. Its title is the tool; each editor titles its own section.
    func makePopover() -> ToolMenuPopover {
        ToolMenuPopover(source: Self.anchorID(tool), isPresented: isPresented, title: PresetText.toolName(tool)) {
            PresetPopoverContent(model: self)
        }
    }

    // MARK: State

    func reload() {
        guard let app else { return }
        let fresh = PresetRules.normalized(app.settings.get(PresetRules.key(tool)), tool: tool)
        if fresh != presets { presets = fresh }
        // A slot another window, device or the AI removed closes its editor.
        if case .colour(.slot(let i))? = popover, i >= fresh.swatches.count { close() }
        // The slider follows a thickness changed elsewhere, unless the finger is still on it.
        if case .width(let i) = shown, pendingWidth == nil {
            let position = WidthScale.position(fresh.widths[i], range: range)
            if abs(position - widthPosition) > 1e-9 { widthPosition = position }
        }
    }

    func open(_ next: PresetPopover) {
        commitWidth()
        arranging = false
        shown = next
        if case .width(let i) = next { widthPosition = WidthScale.position(presets.widths[i], range: range) }
        popover = next
        didChangePresentation()
    }

    func close() {
        commitWidth()
        guard popover != nil else { return }
        popover = nil
        didChangePresentation()
    }

    func beginArranging() {
        close()
        arranging = true
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    func endArranging() {
        arranging = false
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// Asks the palette's host to re-read the popover (contracts-v2 `setNeedsChromeUpdate`) and moves VoiceOver.
    private func didChangePresentation() {
        app?.ui.setNeedsChromeUpdate(session)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    // MARK: Bar actions

    /// Tapping the selected thickness toggles its popover; another one selects it.
    func tapWidth(_ i: Int) {
        if i == presets.selectedWidth {
            popover == .width(i) ? close() : open(.width(i))
        } else {
            close()
            run([PresetActions.call("preset.select", tool, ["width": .number(Double(i))])])
        }
    }

    /// Tapping the selected colour toggles its editor; another one selects it.
    func tapSwatch(_ i: Int) {
        if i == presets.selectedSwatch {
            popover == .colour(.slot(i)) ? close() : open(.colour(.slot(i)))
        } else {
            close()
            run([PresetActions.call("preset.select", tool, ["swatch": .number(Double(i))])])
        }
    }

    func addColour() {
        popover == .colour(.add) ? close() : open(.colour(.add))
    }

    func remove(_ i: Int) {
        run([PresetActions.call("preset.removeSwatch", tool, ["index": .number(Double(i))])])
    }

    func move(_ from: Int, _ to: Int) {
        run([PresetActions.call("preset.moveSwatch", tool, ["from": .number(Double(from)), "to": .number(Double(to))])])
    }

    func reset() {
        close()
        arranging = false
        run([PresetActions.call("preset.reset", tool)])
    }

    // MARK: Thickness popover

    /// The slider moved: the thickness commits once it rests for a quarter second, or when the popover closes.
    func setWidthPosition(_ position: Double) {
        widthPosition = min(max(position, 0), 1)
        pendingWidth?.cancel()
        pendingWidth = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.commitWidth()
        }
    }

    @discardableResult
    func commitWidth() -> Task<Bool, Never>? {
        pendingWidth?.cancel()
        pendingWidth = nil
        guard case .width(let i) = shown, presets.widths.indices.contains(i) else { return nil }
        let w = editedWidth
        guard abs(w - presets.widths[i]) >= 0.005 else { return nil }
        return run([PresetActions.call("preset.setWidth", tool, ["index": .number(Double(i)), "width": .number(w)])])
    }

    @discardableResult
    func setPattern(_ pattern: StrokePattern) -> Task<Bool, Never>? {
        guard case .width(let i) = shown else { return nil }
        pendingWidth?.cancel()
        pendingWidth = nil
        return run([PresetActions.call("preset.setWidth", tool, ["index": .number(Double(i)), "width": .number(editedWidth),
                                                                 "pattern": .string(pattern.rawValue)])])
    }

    // MARK: Colour popover

    /// One of the offered colours: sets the edited slot, or adds a slot.
    @discardableResult
    func pick(_ colour: RGBA) -> Task<Bool, Never>? {
        let hex = PresetColour.rgbHex(colour)
        let call = colourSlot.map { slot in
            PresetActions.call("preset.setSwatch", tool, ["index": .number(Double(slot)), "color": .string(hex)])
        } ?? PresetActions.call("preset.addSwatch", tool, ["color": .string(hex)])
        close()
        return run([call])
    }

    /// A tape pattern (nil: plain colour) for the edited slot, or a new slot in the current colour that carries it.
    @discardableResult
    func setTapePattern(_ id: String?) -> Task<Bool, Never>? {
        let calls = ColourEditor.patternCalls(tool: tool, slot: colourSlot, count: presets.swatches.count,
                                              hex: editedSwatch.color.hex, pattern: id)
        close()
        return run(calls)
    }

    /// The system colour picker (grid, spectrum, sliders with hex, the system eyedropper).
    func openPicker() {
        guard let app, let session else { return }
        let tool = self.tool, slot = colourSlot
        let initial = editedSwatch.color
        // Release the menu's modal input catcher before handing input to UIKit. Keep the
        // edited target and initial colour even as the menu's presentation changes.
        close()
        SystemColourPicker.present(title: String(localized: "\(PresetText.toolName(tool)) Colour"),
                                   initial: initial, supportsAlpha: tool != "highlighter",
                                   commitsOnFinishOnly: slot == nil, app: app, session: session) { colour in
            let hex = tool == "highlighter" ? PresetColour.rgbHex(colour) : colour.hex
            let call = slot.map { i in
                PresetActions.call("preset.setSwatch", tool, ["index": .number(Double(i)), "color": .string(hex)])
            } ?? PresetActions.call("preset.addSwatch", tool, ["color": .string(hex)])
            PresetActions.run(app, session: session, [call])
        }
    }

    var canPickFromPage: Bool {
        guard let app, let session else { return false }
        return EyedropperAttachment.canPick(session: session, app: app)
    }

    /// The in-document loupe; lifting sets the edited slot (or adds one).
    func pickFromPage() {
        guard let session else { return }
        EyedropperAttachment.begin(EyedropperAttachment.Request(tool: tool, target: colourSlot.map { .slot($0) } ?? .add),
                                   session: session)
        close()
    }

    func removeEdited() {
        guard let slot = colourSlot else { return }
        close()
        remove(slot)
    }

    @discardableResult
    private func run(_ calls: [PresetActions.Call]) -> Task<Bool, Never> {
        guard let app else { return Task { false } }
        return PresetActions.run(app, session: session, calls)
    }
}

/// Each window's `PresetMenuModel` per tool, so the options bar (`makeView`) and its popover (`makePopover`) of one
/// window share one state. Captured by the `ToolMenuDescriptor`s; a closed window's models go with its session.
@MainActor
final class PresetMenus {
    private struct Entry {
        weak var session: EditorSession?
        let model: PresetMenuModel
    }

    private weak var app: NibApp?
    private var entries: [String: Entry] = [:]

    init(app: NibApp) {
        self.app = app
    }

    func model(_ tool: String, session: EditorSession) -> PresetMenuModel? {
        entries = entries.filter { $0.value.session != nil }
        let key = session.id.raw + " " + tool
        if let entry = entries[key], entry.session === session { return entry.model }
        guard let app else { return nil }
        let model = PresetMenuModel(app: app, session: session, tool: tool)
        entries[key] = Entry(session: session, model: model)
        return model
    }
}

// MARK: - The tool menu

/// The contextual options of the pen, pencil, highlighter, tape, shape and draw-shape tools, rendered by the palette
/// inside its `NibToolOptionsBar`: three thickness slots, the colour slots and +, or while rearranging, removable and
/// draggable slots and Restore Defaults. The thickness slider and the colour editor bud from here as the menu's
/// popover (`PresetMenuModel.makePopover`).
struct ToolPresetMenu: View {
    let model: PresetMenuModel

    @State private var confirmReset = false
    @State private var dragged: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var presets: ToolPresets { model.presets }
    private var tool: String { model.tool }

    var body: some View {
        Group {
            if model.arranging {
                arrangeRow
            } else {
                slotsRow
            }
        }
        .onAppear { model.reload() }
        .onChange(of: model.arranging) { _, _ in dragged = nil }
        .confirmationDialog(String(localized: "Restore the default colours and thicknesses?"),
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button(String(localized: "Restore Defaults"), role: .destructive) { model.reset() }
                .accessibilityIdentifier("cmd.preset.reset")
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Your own \(PresetText.toolName(tool)) colours and thicknesses are replaced."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(PresetText.toolName(tool)) presets"))
    }

    // MARK: Rows

    private var slotsRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<PresetRules.widthSlots, id: \.self) { i in
                let selected = i == presets.selectedWidth
                NibWidthPresetButton(diameter: NibMetrics.widthPresetDot(i), isSelected: selected,
                                     label: String(localized: "Thickness \(i + 1)")) {
                    model.tapWidth(i)
                }
                .accessibilityIdentifier("cmd.preset.select")
                .accessibilityValue(PresetText.widthValue(presets.widths[i], pattern: presets.patterns[i]))
                .accessibilityHint(selected ? String(localized: "Double-tap to adjust.") : "")
                .presetPopoverSource(tool, model.shown == .width(i))
            }
            NibBarSeparator()
            if sizeClass == .compact {
                // Leave room for the host's settings chevron and the capsule's chrome insets. The selected
                // colour opens the existing colour popover, which holds the remaining presets and Add Colour.
                swatchSlot(presets.selectedSwatch, presets.swatches[presets.selectedSwatch], arranging: false)
            } else {
                swatchStrip(arranging: false)
                if presets.swatches.count < ToolPresets.maxSwatches {
                    NibIconButton(.plus, label: String(localized: "Add Colour")) { model.addColour() }
                        .presetPopoverSource(tool, model.shown == .colour(.add))
                }
            }
        }
    }

    private var arrangeRow: some View {
        HStack(spacing: 0) {
            swatchStrip(arranging: true)
            NibBarSeparator()
            NibIconButton(.retry, label: String(localized: "Restore Default Presets")) {
                NibHaptics.play(.warning)
                confirmReset = true
            }
            NibIconButton(.checkmark, label: String(localized: "Done"), shortcut: .cancelAction) { model.endArranging() }
        }
    }

    /// Rearranging on iPhone leaves room for Restore, Done and the host's settings chevron, even at 320 pt.
    /// The normal compact row shows only the selected swatch; iPad shows eight and scrolls.
    private func stripWidth(_ count: Int) -> CGFloat {
        let cap: Double = sizeClass == .compact ? 2.5 : 8
        return CGFloat(min(Double(count), cap)) * NibMetrics.paletteSwatchPitch
    }

    private func swatchStrip(arranging: Bool) -> some View {
        Group {
            if CGFloat(presets.swatches.count) * NibMetrics.paletteSwatchPitch <= stripWidth(presets.swatches.count) {
                // The usual three colours fit. A nested scroll view here delays delivery
                // of the touch to UIButton's long-press recogniser for no scrolling benefit.
                swatchCells(arranging: arranging)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        swatchCells(arranging: arranging)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .onAppear { proxy.scrollTo(presets.selectedSwatch, anchor: .center) }
                    // Keys 1-9/0, the AI or another window can select a slot scrolled out of view.
                    .onChange(of: presets.selectedSwatch) { _, s in proxy.scrollTo(s, anchor: .center) }
                }
            }
        }
        .frame(width: stripWidth(presets.swatches.count), height: NibMetrics.hitTarget)
    }

    private func swatchCells(arranging: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(presets.swatches.enumerated()), id: \.offset) { i, swatch in
                swatchSlot(i, swatch, arranging: arranging).id(i)
            }
        }
    }

    @ViewBuilder
    private func swatchSlot(_ i: Int, _ swatch: PresetSwatch, arranging: Bool) -> some View {
        let name = PresetColour.name(swatch.color)
        let removable = presets.swatches.count > 1
        let registry = model.app?.content.tapePatterns
        if arranging {
            SwatchSlot(tool: tool, swatch: swatch, name: removable ? String(localized: "Remove \(name)") : name,
                       isSelected: false, registry: registry) {
                if removable { model.remove(i) }
            }
            .accessibilityIdentifier("cmd.preset.removeSwatch")
            .overlay(alignment: .topTrailing) {
                if removable { RemoveBadge() }
            }
            .onDrag {
                dragged = i
                return NSItemProvider(object: SwatchDropDelegate.payload(i) as NSString)
            }
            .onDrop(of: [UTType.plainText], delegate: SwatchDropDelegate(index: i, dragged: $dragged) { from, to in
                model.move(from, to)
            })
            .accessibilityAction(named: Text(String(localized: "Move Left"))) {
                if i > 0 { model.move(i, i - 1) }
            }
            .accessibilityAction(named: Text(String(localized: "Move Right"))) {
                if i < presets.swatches.count - 1 { model.move(i, i + 1) }
            }
        } else {
            SwatchSlot(tool: tool, swatch: swatch, name: name, isSelected: i == presets.selectedSwatch, registry: registry,
                       menu: PresetSwatchMenu.make(model: model, index: i) { confirmReset = true }) {
                model.tapSwatch(i)
            }
            .accessibilityIdentifier("cmd.preset.select")
            // In compact width the selected swatch remains the source while the popover adds a colour or
            // edits another saved slot: those controls no longer live in the bar.
            .presetPopoverSource(tool, isColourSource(i))
            .accessibilityAction(named: Text(String(localized: "Change Colour"))) { model.open(.colour(.slot(i))) }
            .accessibilityAction(named: Text(String(localized: "Rearrange Colours"))) { model.beginArranging() }
        }
    }

    private func isColourSource(_ index: Int) -> Bool {
        if sizeClass == .compact, case .colour = model.shown {
            return index == presets.selectedSwatch
        }
        return model.shown == .colour(.slot(index))
    }
}

extension View {
    /// The bud source of the tool's popover, on the one control `PresetMenuModel.shown` names. A background, so the
    /// control keeps its identity when the source moves to another one.
    func presetPopoverSource(_ tool: String, _ isSource: Bool) -> some View {
        background {
            if isSource {
                Color.clear.nibBudAnchor(PresetMenuModel.anchorID(tool))
            }
        }
    }
}

// MARK: - The popover

/// The options bar's popover: the thickness editor or the colour editor, whichever `PresetMenuModel.shown` names.
struct PresetPopoverContent: View {
    let model: PresetMenuModel

    var body: some View {
        switch model.shown {
        case .width(let index):
            WidthEditor(model: model, index: index)
        case .colour:
            ColourEditor(model: model)
        }
    }
}

/// One thickness slot: its value in millimetres and points over a bead slider (logarithmic, so the fine pen widths get
/// most of the travel) and, for the pen and pencil, its line pattern. The slider commits once it rests for a quarter
/// second, and when the popover closes.
struct WidthEditor: View {
    let model: PresetMenuModel
    let index: Int

    var body: some View {
        let width = model.editedWidth
        let pattern = model.presets.patterns.indices.contains(index) ? model.presets.patterns[index] : .solid
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            NibInspectorSection(String(localized: "Thickness \(index + 1)"),
                                value: "\(PresetText.millimetres(width)) · \(PresetText.points(width))") {
                NibSlider(value: Binding(get: { model.widthPosition }, set: { model.setWidthPosition($0) }),
                          label: String(localized: "Thickness"))
                    .accessibilityIdentifier("cmd.preset.setWidth")
                    .accessibilityValue(PresetText.widthValue(width, pattern: pattern))
            }
            if PresetRules.patternTools.contains(model.tool) {
                NibInspectorSection(String(localized: "Line")) {
                    HStack(spacing: 0) {
                        ForEach(StrokePattern.allCases, id: \.self) { p in
                            LineSampleButton(lineWidth: NibStroke.thick, pattern: p, isSelected: p == pattern,
                                             label: PresetText.patternName(p), value: nil, hint: nil) {
                                model.setPattern(p)
                            }
                            .accessibilityIdentifier("cmd.preset.setWidth")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Slots

/// A short line for the width editor's pattern choices. Thickness slots use `NibWidthPresetButton`.
struct LineSampleButton: View {
    let lineWidth: CGFloat
    let pattern: StrokePattern
    let isSelected: Bool
    let label: String
    let value: String?
    let hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LineSample()
                .stroke(NibColor.label, style: PresetStroke.style(lineWidth: lineWidth, pattern: pattern))
                .frame(width: NibSpacing.xl, height: NibSpacing.xl)
                .frame(width: NibMetrics.hudHeight, height: NibMetrics.hudHeight)
                .background(isSelected ? NibColor.fill3 : Color.clear, in: Circle())
                .animation(NibMotion.colorChange, value: isSelected)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct LineSample: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// One colour slot: a flat swatch, or for tape the pattern over its colour (NibDesign v2 `NibPenSwatch(_:pattern:)`;
/// the tile is loaded here, `TapePatternCache`).
struct SwatchSlot: View {
    let tool: String
    let swatch: PresetSwatch
    let name: String
    let isSelected: Bool
    let registry: Registry<TapePatternDescriptor>?
    var menu: UIMenu? = nil
    let action: () -> Void
    @State private var pattern: NibSwatchPattern?

    /// The slot's `TapePatternDescriptor.id` (tape only).
    private var patternID: String? { tool == "tape" ? swatch.pattern.map(PresetSwatch.tapePatternID) : nil }

    var body: some View {
        let colour = PresetColour.display(swatch.color, tool: tool)
        let display = PresetColour.swatch(colour, id: swatch.color.hex, name: name, pattern: pattern)
        Group {
            if let menu {
                PresetSwatchControl(swatch: display, isSelected: isSelected, menu: menu, action: action)
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
            } else {
                NibPenSwatch(display, isSelected: isSelected, size: .palette, action: action)
            }
        }
            .task(id: patternID) {
                guard let id = patternID, let registry else {
                    pattern = nil
                    return
                }
                pattern = await TapePatternCache.pattern(id, registry: registry)
            }
    }
}

/// Keep the primary action and the long-press menu on the same native control. A SwiftUI
/// contextMenu around the styled swatch inside the scrolling options bar can lose to its
/// button gesture, opening the selected colour's editor when the user holds for a menu.
struct PresetSwatchControl: UIViewRepresentable {
    let swatch: NibSwatch
    let isSelected: Bool
    let menu: UIMenu
    let action: () -> Void

    func makeUIView(context: Context) -> PresetSwatchNativeButton { PresetSwatchNativeButton() }

    func updateUIView(_ button: PresetSwatchNativeButton, context: Context) {
        button.configure(swatch: swatch, isSelected: isSelected, menu: menu, action: action)
    }
}

final class PresetSwatchNativeButton: UIButton {
    private var tap: (() -> Void)?
    private var menuOwnsInteraction = false

    init() {
        super.init(frame: .zero)
        showsMenuAsPrimaryAction = false
        isPointerInteractionEnabled = true
        // UIButton can forward touchUpInside to its primary action even after a menu
        // long press. Keep that release from toggling the editor behind the menu.
        addAction(UIAction { [weak self] _ in self?.menuOwnsInteraction = true }, for: .menuActionTriggered)
        addAction(UIAction { [weak self] _ in
            guard let self, !self.menuOwnsInteraction else { return }
            self.tap?()
        }, for: .primaryActionTriggered)
        accessibilityIdentifier = "cmd.preset.select"
    }

    required init?(coder: NSCoder) { nil }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        menuOwnsInteraction = false
        return super.beginTracking(touch, with: event)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let finished: () -> Void = { [weak self] in self?.menuOwnsInteraction = false }
        if let animator {
            animator.addCompletion(finished)
        } else {
            // With no animation, the release can still be delivered in this event turn.
            DispatchQueue.main.async(execute: finished)
        }
    }

    func configure(swatch: NibSwatch, isSelected: Bool, menu: UIMenu, action: @escaping () -> Void) {
        tap = action
        self.menu = menu
        self.isSelected = isSelected
        setImage(.nibSwatch(swatch, size: .palette, isSelected: isSelected), for: .normal)
        accessibilityLabel = swatch.pattern?.name.map { "\(swatch.name), \($0)" } ?? swatch.name
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
}

@MainActor
enum PresetSwatchMenu {
    static func make(model: PresetMenuModel, index: Int, restore: @escaping () -> Void) -> UIMenu {
        var actions = [
            UIAction(title: String(localized: "Change Colour")) { _ in model.open(.colour(.slot(index))) },
            UIAction(title: String(localized: "Rearrange Colours")) { _ in model.beginArranging() }
        ]
        if model.presets.swatches.count > 1 {
            actions.append(UIAction(title: String(localized: "Remove Colour"), attributes: .destructive) { _ in model.remove(index) })
        }
        actions.append(UIAction(title: String(localized: "Restore Default Presets"), attributes: .destructive) { _ in restore() })
        return UIMenu(children: actions)
    }
}

/// The remove mark on a slot while rearranging (the whole 44 pt slot is the button).
struct RemoveBadge: View {
    var body: some View {
        Image(nib: .minus)
            .font(NibFont.caption1Emphasis)
            .foregroundStyle(NibColor.onAccent)
            .frame(width: NibSpacing.l, height: NibSpacing.l)
            .background(NibColor.destructive, in: Circle())
            .padding(NibSpacing.xs)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Drop a dragged slot on another to move it there (one `preset.moveSwatch`). The drag carries `payload(from)`, so a
/// cancelled drag's stale index never moves anything when outside text is dropped later.
struct SwatchDropDelegate: DropDelegate {
    let index: Int
    @Binding var dragged: Int?
    let onMove: (Int, Int) -> Void

    static func payload(_ index: Int) -> String { "app.nib.presets.swatch:\(index)" }

    func validateDrop(info: DropInfo) -> Bool { dragged != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let from = dragged, let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        dragged = nil
        let to = index, onMove = onMove, expected = Self.payload(from)
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, text as String == expected, from != to else { return }
            DispatchQueue.main.async { onMove(from, to) }
        }
        return true
    }
}
