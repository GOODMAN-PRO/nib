import SwiftUI

/// Switch. iOS 26: the system switch (its thumb is already Liquid Glass). iOS 17–25: the thumb squashes
/// 27 → 35 → 27 pt over 0.32 s, the only liquid in Settings.
public struct NibToggle: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    public var body: some View {
        if #available(iOS 26.0, *) {
            Toggle(title, isOn: $isOn)
                .font(NibFont.body)
        } else {
            Toggle(title, isOn: $isOn)
                .font(NibFont.body)
                .toggleStyle(NibSwitchStyle())
        }
    }
}

struct NibSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NibSwitch(configuration: configuration)
    }
}

struct NibSwitch: View {
    let configuration: ToggleStyleConfiguration
    @State private var squash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NibSpacing.s) {
            configuration.label
            Spacer(minLength: NibSpacing.s)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? NibColor.success : NibColor.fill1)
                Capsule()
                    .fill(Color.white)
                    .frame(width: squash ? 35 : 27, height: squash ? 23 : 27)
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                    .padding(2)
            }
            .frame(width: 51, height: 31)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .contentShape(Rectangle())
        .onTapGesture { flip() }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func flip() {
        guard !reduceMotion && !NibMotion.forcesReduced else {
            configuration.isOn.toggle()
            return
        }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)) {
            squash = true
            configuration.isOn.toggle()
        } completion: {
            withAnimation(NibMotion.tap.animation) { squash = false }
        }
    }
}

/// Slider whose thumb is a bead: it stretches a little with drag speed (cap 0.10, `thumb` spring, about the grab
/// side) and settles in one small undershoot. A slider is a precision control: no jelly (DESIGN.md §13.3).
public struct NibSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let detents: [Double]
    @State private var stretch: CGFloat = 0
    /// −1 or 1: the side of the thumb the finger pulls from (the stretch trails behind it).
    @State private var grabSide: CGFloat = 0
    @State private var lastDetent: Double?

    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, label: String, detents: [Double] = []) {
        self._value = value
        self.range = range
        self.label = label
        self.detents = detents
    }

    public var body: some View {
        GeometryReader { proxy in
            let w = max(1, proxy.size.width - 28)
            let span = max(range.upperBound - range.lowerBound, Double.ulpOfOne)
            let fraction = CGFloat((value - range.lowerBound) / span)
            let s = DropletPhysics.clampStretch(stretch, cap: 0.10)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NibColor.fill1)
                    .frame(height: 4)
                Capsule()
                    .fill(NibColor.label)
                    .frame(width: 14 + fraction * w, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .shadow(color: NibColor.beadShadow, radius: 4, x: 0, y: 2)
                    .scaleEffect(x: 1 + s, y: 1 / (1 + s).squareRoot(), anchor: UnitPoint(x: 0.5 + grabSide / 2, y: 0.5))
                    .offset(x: fraction * w)
            }
            .frame(height: 28)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in update(g, width: w, span: span) }
                .onEnded { _ in release() })
        }
        .frame(height: NibMetrics.hitTarget)
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { Text(label) }
        }
    }

    private func update(_ g: DragGesture.Value, width w: CGFloat, span: Double) {
        let f = min(max((g.location.x - 14) / w, 0), 1)
        value = range.lowerBound + Double(f) * span
        if let hit = detents.first(where: { abs($0 - value) < span * 0.01 }), hit != lastDetent {
            lastDetent = hit
            NibHaptics.play(.detent)
        }
        let v = g.velocity.width
        grabSide = v > 0 ? 1 : (v < 0 ? -1 : grabSide)
        withAnimation(NibMotion.thumb.animation) {
            stretch = DropletPhysics.stretchTarget(speed: abs(v), cap: 0.10, vRef: 2600)
        }
    }

    private func release() {
        lastDetent = nil
        withAnimation(NibMotion.thumb.animation) { stretch = 0 }
    }
}

/// Thickness: three preset dots, the value in HUD type, and a bead slider (millimetres, or points for tools measured
/// on screen such as the eraser).
public struct NibStrokeWidthSlider: View {
    /// v2: what the width measures. Pens are in millimetres; the eraser's size and other on-screen sizes in points.
    public enum Unit: Sendable {
        case millimetres, points
    }

    @Binding var width: Double
    let range: ClosedRange<Double>
    let presets: [Double]
    let title: String?
    let unit: Unit

    public init(width: Binding<Double>, range: ClosedRange<Double> = 0.1...3.0, presets: [Double] = [0.3, 0.5, 0.8]) {
        self._width = width
        self.range = range
        self.presets = presets
        self.title = nil
        self.unit = .millimetres
    }

    /// v2: a titled slider in either unit ("Size" in points for the eraser, "Thickness" in millimetres for pens).
    public init(width: Binding<Double>, range: ClosedRange<Double>, presets: [Double], title: String, unit: Unit) {
        self._width = width
        self.range = range
        self.presets = presets
        self.title = title
        self.unit = unit
    }

    /// The value beside the title: "0.50 mm", "12 pt".
    static func valueText(_ width: Double, unit: Unit) -> String {
        switch unit {
        case .millimetres: return String(format: String(localized: "%.2f mm", bundle: .module), width)
        case .points: return String(format: String(localized: "%.0f pt", bundle: .module), width)
        }
    }

    /// A preset dot's VoiceOver label: "0.5 millimetres", "12 points".
    static func presetLabel(_ preset: Double, unit: Unit) -> String {
        switch unit {
        case .millimetres: return String(format: String(localized: "%.1f millimetres", bundle: .module), preset)
        case .points: return String(format: String(localized: "%.0f points", bundle: .module), preset)
        }
    }

    /// Two widths within this of each other are the same preset (a hundredth of a millimetre, half a point).
    static func matches(_ width: Double, _ preset: Double, unit: Unit) -> Bool {
        abs(width - preset) < (unit == .points ? 0.5 : 0.005)
    }

    public var body: some View {
        let heading = title ?? String(localized: "Thickness", bundle: .module)
        NibInspectorSection(heading, value: Self.valueText(width, unit: unit)) {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                HStack(spacing: NibSpacing.s) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                        let selected = Self.matches(width, preset, unit: unit)
                        Button {
                            withAnimation(NibMotion.tap.animation) { width = preset }
                        } label: {
                            Circle()
                                .fill(NibColor.label)
                                .frame(width: CGFloat(5 + index * 3 + (index > 1 ? 1 : 0)),
                                       height: CGFloat(5 + index * 3 + (index > 1 ? 1 : 0)))
                                .frame(width: 44, height: 40)
                                .background(selected ? NibColor.fill3 : Color.clear,
                                            in: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
                                .frame(minHeight: NibMetrics.hitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous)))
                        .accessibilityLabel(Self.presetLabel(preset, unit: unit))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                NibSlider(value: $width, in: range, label: heading, detents: presets)
            }
        }
    }
}

/// Segmented control: fill3 track (radius 9, 2 pt inset, 32 pt visual), knob on backgroundTertiary (radius 7). Each
/// segment's hit area is the full 44 pt height (the track is drawn inside it).
public struct NibSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var knob

    public init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self._selection = selection
        self.options = options
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(NibMotion.tap.animation) { selection = option }
                } label: {
                    Text(title(option))
                        .font(selected ? NibFont.footnoteEmphasis : NibFont.footnote)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                        .padding(.horizontal, NibSpacing.m)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: NibRadius.segmentKnob, style: .continuous)
                                    .fill(NibColor.backgroundTertiary)
                                    .nibElevation(.rest)
                                    .matchedGeometryEffect(id: "knob", in: knob)
                            }
                        }
                        .padding(.vertical, 8)                 // 28 + 16: the 44 pt hit area
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
        .background {
            RoundedRectangle(cornerRadius: NibRadius.segment, style: .continuous)
                .fill(NibColor.fill3)
                .padding(.vertical, 6)                         // the 32 pt visual track inside the 44 pt row
        }
    }
}

/// Search field. `.filled` on opaque surfaces; `.onDroplet` when it lives inside a Clear droplet (no glass on glass).
public struct NibSearchField: View {
    public enum Style: Sendable {
        case filled, onDroplet
    }

    @Binding var text: String
    let prompt: String
    let style: Style
    let onSubmit: () -> Void

    public init(text: Binding<String>, prompt: String, style: Style = .filled, onSubmit: @escaping () -> Void = {}) {
        self._text = text
        self.prompt = prompt
        self.style = style
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: NibSpacing.s) {
            Image(nib: .search)
                .font(NibFont.body)
                .foregroundStyle(NibColor.labelSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(NibFont.body)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(nib: .clearText)
                        .foregroundStyle(NibColor.labelTertiary)
                        .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                }
                .buttonStyle(NibPressStyle(shape: Circle()))
                .accessibilityLabel(String(localized: "Clear search", bundle: .module))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(minHeight: NibMetrics.hitTarget)
        .background(style == .filled ? NibColor.fill4 : Color.clear, in: Capsule())
    }
}

/// Text field for forms and the assistant composer (grows to `lines`).
public struct NibField: View {
    @Binding var text: String
    let prompt: String
    let lines: ClosedRange<Int>

    public init(text: Binding<String>, prompt: String, lines: ClosedRange<Int> = 1...1) {
        self._text = text
        self.prompt = prompt
        self.lines = lines
    }

    public var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(lines)
            .font(NibFont.chat)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: NibMetrics.hitTarget)
            .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.composer, style: .continuous))
    }
}

/// Chips: context ("Page 3 · Handwriting", removable), citations (accent wash, inline), filters. The visuals stay
/// 28 pt (20 pt for citations); every tappable part reaches 44 pt with padding that does not move the layout.
public struct NibChip: View {
    public enum Style: Sendable {
        case context, citation, filter(isSelected: Bool)
    }

    let title: String
    let symbol: NibSymbol?
    let style: Style
    let action: (() -> Void)?
    let onRemove: (() -> Void)?

    public init(_ title: String, symbol: NibSymbol? = nil, style: Style = .context, action: (() -> Void)? = nil,
                onRemove: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.action = action
        self.onRemove = onRemove
    }

    private var isCitation: Bool {
        if case .citation = style { return true }
        return false
    }

    private var isSelectedFilter: Bool {
        if case .filter(let selected) = style { return selected }
        return false
    }

    public var body: some View {
        HStack(spacing: 4) {
            Button {
                action?()
            } label: {
                HStack(spacing: 4) {
                    if let symbol {
                        Image(nib: symbol).font(NibFont.caption1)
                    }
                    Text(title)
                        .font(isCitation ? NibFont.caption1Emphasis : NibFont.footnote)
                        .lineLimit(1)
                }
                .hitPadding(isCitation ? 12 : 8)
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            if let onRemove {
                Button(action: onRemove) {
                    Image(nib: .xmark).font(.system(size: 10, weight: .bold))
                        .frame(width: 16, height: 16)
                        .padding(.horizontal, 6)                   // 28 pt wide
                        .hitPadding(14)                            // 44 pt tall
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove \(title)", bundle: .module))
            }
        }
        .foregroundStyle(isCitation ? NibColor.accent : (isSelectedFilter ? NibColor.label : NibColor.labelSecondary))
        .padding(.horizontal, isCitation ? 6 : 10)
        .frame(minHeight: isCitation ? 20 : 28)
        .background(isCitation ? NibColor.accentWash : (isSelectedFilter ? NibColor.fill2 : NibColor.fill3),
                    in: RoundedRectangle(cornerRadius: isCitation ? NibRadius.badge : 14, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Grows the hit area vertically by `amount` on each side without changing layout (padding in, padding out).
    func hitPadding(_ amount: CGFloat) -> some View {
        padding(.vertical, amount).contentShape(Rectangle()).padding(.vertical, -amount)
    }
}
