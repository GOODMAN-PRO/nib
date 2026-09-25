import SwiftUI
import UIKit
import Combine
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

    /// The line weight a thickness slot draws with: 1.5…10 pt along the tool's own scale.
    static func slotLineWidth(_ width: Double, tool: String) -> CGFloat {
        CGFloat(1.5 + 8.5 * position(width, range: PresetRules.widthRange(tool)))
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

/// What the options bar shows. The bar is one Clear droplet: a new row re-lays it out and the water re-forms.
enum PresetBarMode: Equatable {
    /// Three thickness slots, the colour slots and +.
    case slots
    /// A thickness slot's slider (mm and pt) and, for the pen and pencil, its line pattern.
    case width(Int)
    /// Changing one colour slot, or adding one.
    case colour(ColourTarget)
    /// Remove and reorder colour slots, restore the defaults.
    case arrange
}

// MARK: - The tool menu

/// The contextual options of the pen, pencil, highlighter, tape, shape and draw-shape tools, rendered by the palette
/// inside its `NibToolOptionsBar`. Everything it changes goes through `preset.*` commands; it reads
/// `NibSettings.presets(tool)` and follows every change to it (this window, another window, a synced device, the AI).
struct ToolPresetMenu: View {
    let app: NibApp
    let session: EditorSession
    let tool: String

    @State private var presets: ToolPresets
    @State private var mode: PresetBarMode = .slots
    @State private var confirmReset = false
    @State private var dragged: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp, session: EditorSession, tool: String) {
        self.app = app
        self.session = session
        self.tool = tool
        _presets = State(initialValue: PresetRules.normalized(app.settings.get(PresetRules.key(tool)), tool: tool))
    }

    var body: some View {
        Group {
            switch mode {
            case .slots:
                slotsRow
            case .width(let index):
                WidthEditorRow(app: app, session: session, tool: tool, index: index, presets: presets) { setMode(.slots) }
            case .colour(let target):
                ColourEditorRow(app: app, session: session, tool: tool, presets: presets, target: target,
                                stripWidth: stripWidth) { setMode(.slots) }
            case .arrange:
                arrangeRow
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { note in
            if (note.userInfo?["name"] as? String) == PresetRules.key(tool).name { reload() }
        }
        .onAppear(perform: reload)
        .confirmationDialog(String(localized: "Restore the default colours and thicknesses?"),
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button(String(localized: "Restore Defaults"), role: .destructive, action: reset)
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
                LineSampleButton(lineWidth: WidthScale.slotLineWidth(presets.widths[i], tool: tool), pattern: presets.patterns[i],
                                 isSelected: i == presets.selectedWidth, label: String(localized: "Thickness \(i + 1)"),
                                 value: PresetText.widthValue(presets.widths[i], pattern: presets.patterns[i]),
                                 hint: i == presets.selectedWidth ? String(localized: "Double-tap to adjust.") : nil) {
                    tapWidth(i)
                }
            }
            NibBarSeparator()
            swatchStrip(arranging: false)
            if presets.swatches.count < ToolPresets.maxSwatches {
                NibIconButton(.plus, label: String(localized: "Add Colour")) { setMode(.colour(.add)) }
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
            NibIconButton(.checkmark, label: String(localized: "Done"), shortcut: .cancelAction) { setMode(.slots) }
        }
    }

    /// iPhone shows three and a half slots and scrolls; iPad shows eight.
    private func stripWidth(_ count: Int) -> CGFloat {
        let cap: Double = sizeClass == .compact ? 3.5 : 8
        return CGFloat(min(Double(count), cap)) * NibMetrics.paletteSwatchPitch
    }

    private func swatchStrip(arranging: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(presets.swatches.enumerated()), id: \.offset) { i, swatch in
                        swatchSlot(i, swatch, arranging: arranging).id(i)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onAppear { proxy.scrollTo(presets.selectedSwatch, anchor: .center) }
        }
        .frame(width: stripWidth(presets.swatches.count), height: NibMetrics.hitTarget)
    }

    @ViewBuilder
    private func swatchSlot(_ i: Int, _ swatch: PresetSwatch, arranging: Bool) -> some View {
        let name = PresetColour.name(swatch.color)
        let removable = presets.swatches.count > 1
        if arranging {
            SwatchSlot(tool: tool, swatch: swatch, name: removable ? String(localized: "Remove \(name)") : name,
                       isSelected: false, registry: app.content.tapePatterns) {
                if removable { remove(i) }
            }
            .overlay(alignment: .topTrailing) {
                if removable { RemoveBadge() }
            }
            .onDrag {
                dragged = i
                return NSItemProvider(object: String(i) as NSString)
            }
            .onDrop(of: [UTType.plainText], delegate: SwatchDropDelegate(index: i, dragged: $dragged) { from, to in
                move(from, to)
            })
            .accessibilityAction(named: Text(String(localized: "Move Left"))) {
                if i > 0 { move(i, i - 1) }
            }
            .accessibilityAction(named: Text(String(localized: "Move Right"))) {
                if i < presets.swatches.count - 1 { move(i, i + 1) }
            }
        } else {
            SwatchSlot(tool: tool, swatch: swatch, name: name, isSelected: i == presets.selectedSwatch,
                       registry: app.content.tapePatterns) {
                tapSwatch(i)
            }
            .contextMenu {
                Button(String(localized: "Change Colour")) { setMode(.colour(.slot(i))) }
                Button(String(localized: "Rearrange Colours")) { setMode(.arrange) }
                if removable {
                    Button(String(localized: "Remove Colour"), role: .destructive) { remove(i) }
                }
                Button(String(localized: "Restore Default Presets"), role: .destructive) { confirmReset = true }
            }
            .accessibilityAction(named: Text(String(localized: "Change Colour"))) { setMode(.colour(.slot(i))) }
            .accessibilityAction(named: Text(String(localized: "Rearrange Colours"))) { setMode(.arrange) }
        }
    }

    // MARK: Actions (every change is a preset command)

    private func setMode(_ next: PresetBarMode) {
        mode = next
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func reload() {
        let fresh = PresetRules.normalized(app.settings.get(PresetRules.key(tool)), tool: tool)
        if fresh != presets { presets = fresh }
        if case .colour(.slot(let i)) = mode, i >= fresh.swatches.count { mode = .slots }
    }

    private func run(_ calls: [PresetActions.Call]) {
        PresetActions.run(app, session: session, calls)
    }

    private func tapWidth(_ i: Int) {
        if i == presets.selectedWidth {
            setMode(.width(i))
        } else {
            run([PresetActions.call("preset.select", tool, ["width": .number(Double(i))])])
        }
    }

    private func tapSwatch(_ i: Int) {
        if i == presets.selectedSwatch {
            setMode(.colour(.slot(i)))
        } else {
            run([PresetActions.call("preset.select", tool, ["swatch": .number(Double(i))])])
        }
    }

    private func remove(_ i: Int) {
        run([PresetActions.call("preset.removeSwatch", tool, ["index": .number(Double(i))])])
    }

    private func move(_ from: Int, _ to: Int) {
        run([PresetActions.call("preset.moveSwatch", tool, ["from": .number(Double(from)), "to": .number(Double(to))])])
    }

    private func reset() {
        run([PresetActions.call("preset.reset", tool)])
        setMode(.slots)
    }
}

// MARK: - Thickness editor

/// The options bar while one thickness slot is adjusted: back, a bead slider (logarithmic), the value in millimetres
/// and points, and for the pen and pencil the line pattern. The slider commits once it rests for a quarter second.
struct WidthEditorRow: View {
    let app: NibApp
    let session: EditorSession
    let tool: String
    let index: Int
    let presets: ToolPresets
    let onDone: () -> Void

    @State private var position: Double
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: NibApp, session: EditorSession, tool: String, index: Int, presets: ToolPresets, onDone: @escaping () -> Void) {
        self.app = app
        self.session = session
        self.tool = tool
        self.index = index
        self.presets = presets
        self.onDone = onDone
        _position = State(initialValue: WidthScale.position(presets.widths[index], range: PresetRules.widthRange(tool)))
    }

    private var width: Double { WidthScale.width(at: position, range: PresetRules.widthRange(tool)) }
    private var pattern: StrokePattern { presets.patterns[index] }

    var body: some View {
        HStack(spacing: 0) {
            NibIconButton(.back, label: String(localized: "Back to Presets"), shortcut: .cancelAction) {
                commit()
                onDone()
            }
            // iPhone: 44 + 88 + 64 + 13 + 3 × 44 fits the 361 pt the screen leaves the bar.
            NibSlider(value: $position, label: String(localized: "Thickness"))
                .frame(width: sizeClass == .compact ? 88 : 176)
                .accessibilityValue(PresetText.widthValue(width, pattern: pattern))
            VStack(alignment: .leading, spacing: 0) {
                Text(PresetText.millimetres(width)).font(NibFont.hud)
                Text(PresetText.points(width)).font(NibFont.caption2)
            }
            .foregroundStyle(NibColor.label)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: 56, alignment: .leading)
            .padding(.leading, NibSpacing.s)
            .accessibilityHidden(true)
            if PresetRules.patternTools.contains(tool) {
                NibBarSeparator()
                ForEach(StrokePattern.allCases, id: \.self) { p in
                    LineSampleButton(lineWidth: 2.5, pattern: p, isSelected: p == pattern,
                                     label: PresetText.patternName(p), value: nil, hint: nil) {
                        setPattern(p)
                    }
                }
            }
        }
        .task(id: position) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { commit() }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let w = width
        guard presets.widths.indices.contains(index), abs(w - presets.widths[index]) >= 0.005 else { return }
        PresetActions.run(app, session: session, [PresetActions.call("preset.setWidth", tool,
                                                                      ["index": .number(Double(index)), "width": .number(w)])])
    }

    private func setPattern(_ p: StrokePattern) {
        PresetActions.run(app, session: session, [PresetActions.call("preset.setWidth", tool,
                                                                      ["index": .number(Double(index)), "width": .number(width),
                                                                       "pattern": .string(p.rawValue)])])
    }
}

// MARK: - Slots

/// A short line drawn with a thickness and a pattern: the thickness slots and the pattern choices.
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
                .frame(width: 20, height: 20)
                .frame(width: 40, height: 40)
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

/// One colour slot: a flat swatch, or for tape the pattern over its colour.
struct SwatchSlot: View {
    let tool: String
    let swatch: PresetSwatch
    let name: String
    let isSelected: Bool
    let registry: Registry<TapePatternDescriptor>
    let action: () -> Void

    var body: some View {
        let colour = PresetColour.display(swatch.color, tool: tool)
        if tool == "tape", let pattern = swatch.pattern {
            PatternSwatch(colour: colour, patternID: pattern.name, registry: registry, name: name, isSelected: isSelected,
                          action: action)
        } else {
            NibPenSwatch(PresetColour.swatch(colour, id: swatch.color.hex, name: name), isSelected: isSelected, size: .palette,
                         action: action)
        }
    }
}

/// The remove mark on a slot while rearranging (the whole 44 pt slot is the button).
struct RemoveBadge: View {
    var body: some View {
        Image(nib: .minus)
            .font(NibFont.caption1Emphasis)
            .foregroundStyle(NibColor.onAccent)
            .frame(width: 16, height: 16)
            .background(NibColor.destructive, in: Circle())
            .padding(NibSpacing.xs)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Drop a dragged slot on another to move it there (one `preset.moveSwatch`).
struct SwatchDropDelegate: DropDelegate {
    let index: Int
    @Binding var dragged: Int?
    let onMove: (Int, Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let from = dragged else { return false }
        dragged = nil
        if from != index { onMove(from, index) }
        return true
    }
}
