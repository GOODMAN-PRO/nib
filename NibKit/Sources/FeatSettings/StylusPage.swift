import SwiftUI
import NibContracts
import NibDesign

/// Settings › Stylus › Stylus & Palm Rejection: what draws (T-079, P-026: Apple Pencil only, or any input so fingers
/// draw, Goodnotes' "Disconnect Apple Pencil"), the writing posture (eight illustrations) and palm rejection
/// sensitivity (T-080, P-027). The canvas input feature reads `NibSettings.stylusMode`, `writingPosture` and
/// `palmSensitivity`; every change goes through `settings.set`.
@MainActor
struct StylusPage: View {
    @StateObject private var model: SettingsModel

    init(app: NibApp) {
        _model = StateObject(wrappedValue: SettingsModel(app: app))
    }

    var body: some View {
        let mode = model.value(NibSettings.stylusMode)
        List {
            Section {
                ForEach(StylusMode.allCases, id: \.self) { option in
                    SettingsCheckRow(title: option.title, detail: option.detail, icon: option.symbol,
                                     isSelected: option == mode) {
                        model.change(NibSettings.stylusMode, to: option)
                    }
                }
            } header: {
                SettingsHeader(String(localized: "Draw with"))
            } footer: {
                SettingsFooter(String(localized: "With Any input on, scroll with two fingers."))
            }

            Section {
                PosturePicker(selection: model.binding(NibSettings.writingPosture))
            } header: {
                SettingsHeader(String(localized: "Writing position"))
            } footer: {
                SettingsFooter(String(localized: "Choose the drawing closest to how you hold your hand. Nib ignores touches where your palm rests."))
            }

            Section {
                SettingsChoiceRow(title: String(localized: "Sensitivity"),
                                  selection: model.binding(NibSettings.palmSensitivity),
                                  options: PalmSensitivity.levels, label: PalmSensitivity.title)
            } header: {
                SettingsHeader(String(localized: "Palm rejection"))
            } footer: {
                SettingsFooter(String(localized: "Low suits most people. If your palm still leaves marks, choose Medium or High. Apple Pencil also has its own palm rejection."))
            }
        }
        .listStyle(.insetGrouped)
    }
}

extension StylusMode {
    var title: String {
        switch self {
        case .pencilOnly: return String(localized: "Apple Pencil")
        case .anyInput: return String(localized: "Any input")
        }
    }

    var detail: String {
        switch self {
        case .pencilOnly: return String(localized: "Only Apple Pencil draws. Fingers scroll, zoom and select.")
        case .anyInput: return String(localized: "Fingers, a mouse and other styluses draw too.")
        }
    }

    var symbol: NibSymbol {
        switch self {
        case .pencilOnly: return .pen
        case .anyInput: return .fingerDrawing
        }
    }
}

/// `NibSettings.palmSensitivity`: 0 low (recommended), 1 medium, 2 high.
enum PalmSensitivity {
    static let levels = [0, 1, 2]

    static func title(_ level: Int) -> String {
        switch level {
        case ..<1: return String(localized: "Low")
        case 1: return String(localized: "Medium")
        default: return String(localized: "High")
        }
    }
}

// MARK: - Writing posture

/// One of the eight writing postures stored in `NibSettings.writingPosture` as `hand × 4 + wrist`: right hand 0–3,
/// left hand 4–7, each from the wrist resting below the pen to the wrist hooked above the line. 0, the default, is the
/// most common posture.
struct WritingPosture: Hashable, Identifiable {
    enum Hand: Int, CaseIterable {
        case right, left

        var title: String {
            switch self {
            case .right: return String(localized: "Right hand")
            case .left: return String(localized: "Left hand")
            }
        }
    }

    enum Wrist: Int, CaseIterable {
        case below, angled, level, hooked

        var title: String {
            switch self {
            case .below: return String(localized: "Wrist below the pen")
            case .angled: return String(localized: "Wrist angled below the line")
            case .level: return String(localized: "Wrist level with the line")
            case .hooked: return String(localized: "Wrist hooked above the line")
            }
        }

        /// Where the palm rests from the pen tip for a right hand, in degrees clockwise from "right" (y points down).
        var rightHandPalmAngle: Double {
            switch self {
            case .below: return 80
            case .angled: return 45
            case .level: return 10
            case .hooked: return -35
            }
        }
    }

    static let all: [WritingPosture] = Hand.allCases.flatMap { hand in
        Wrist.allCases.map { WritingPosture(hand: hand, wrist: $0) }
    }

    let hand: Hand
    let wrist: Wrist

    init(hand: Hand, wrist: Wrist) {
        self.hand = hand
        self.wrist = wrist
    }

    /// The stored value; out-of-range values (a hand-edited prefs file) fall back to the nearest posture.
    init(index: Int) {
        let clamped = min(max(index, 0), Hand.allCases.count * Wrist.allCases.count - 1)
        hand = Hand(rawValue: clamped / Wrist.allCases.count) ?? .right
        wrist = Wrist(rawValue: clamped % Wrist.allCases.count) ?? .below
    }

    var index: Int { hand.rawValue * Wrist.allCases.count + wrist.rawValue }
    var id: Int { index }

    /// Palm direction from the pen tip (degrees, y down); a left hand mirrors a right hand.
    var palmAngle: Double {
        hand == .right ? wrist.rightHandPalmAngle : 180 - wrist.rightHandPalmAngle
    }

    /// The pen leans from the tip towards the knuckles: 55° up from the palm, on the hand's side.
    var penAngle: Double {
        hand == .right ? palmAngle - 55 : palmAngle + 55
    }

    var title: String { String(localized: "\(hand.title), \(wrist.title)") }
}

/// Two rows of four drawings (right hand, then left hand). The selected one sits on `fill3` with a check.
struct PosturePicker: View {
    /// ponytail: local until NibMetrics has a posture-cell height (contract request).
    static let cellHeight: CGFloat = 56

    @Binding var selection: Int

    private var current: WritingPosture { WritingPosture(index: selection) }
    private var cellShape: RoundedRectangle { RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            ForEach(WritingPosture.Hand.allCases, id: \.self) { hand in
                Text(hand.title)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .accessibilityHidden(true)
                HStack(spacing: NibSpacing.xs) {
                    ForEach(WritingPosture.Wrist.allCases, id: \.self) { wrist in
                        cell(WritingPosture(hand: hand, wrist: wrist))
                    }
                }
            }
            Text(current.title)
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NibSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "Writing position")))
    }

    private func cell(_ posture: WritingPosture) -> some View {
        let isSelected = posture == current
        return Button {
            selection = posture.index
        } label: {
            PostureIllustration(posture: posture, isSelected: isSelected)
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
                .background(isSelected ? NibColor.fill3 : Color.clear, in: cellShape)
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(nib: .checkCircleFill)
                            .font(NibFont.caption1)
                            .foregroundStyle(NibColor.accent)
                            .padding(NibSpacing.xs)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(cellShape)
        }
        .buttonStyle(NibPressStyle(shape: cellShape))
        .accessibilityLabel(Text(posture.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A writing line, the pen on it and the resting palm, drawn from the posture's angles.
struct PostureIllustration: View {
    /// ponytail: illustration strokes, local until the design system has stroke-width tokens (contract request).
    static let hairline: CGFloat = 1
    static let penWidth: CGFloat = 3

    let posture: WritingPosture
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            let tip = CGPoint(x: size.width / 2, y: size.height / 2)
            let reach = min(size.width, size.height) * 0.36

            var line = Path()
            line.move(to: CGPoint(x: NibSpacing.s, y: tip.y))
            line.addLine(to: CGPoint(x: size.width - NibSpacing.s, y: tip.y))
            context.stroke(line, with: .color(NibColor.separator), lineWidth: Self.hairline)

            let palm = posture.palmAngle * .pi / 180
            var hand = context
            hand.translateBy(x: tip.x + CGFloat(cos(palm)) * reach, y: tip.y + CGFloat(sin(palm)) * reach)
            hand.rotate(by: .radians(palm))
            let palmShape = Path(ellipseIn: CGRect(x: -reach * 0.55, y: -reach * 0.4, width: reach * 1.1, height: reach * 0.8))
            hand.fill(palmShape, with: .color(NibColor.fill1))
            hand.stroke(palmShape, with: .color(NibColor.labelSecondary), lineWidth: Self.hairline)

            let lean = posture.penAngle * .pi / 180
            var pen = Path()
            pen.move(to: tip)
            pen.addLine(to: CGPoint(x: tip.x + CGFloat(cos(lean)) * reach * 1.3, y: tip.y + CGFloat(sin(lean)) * reach * 1.3))
            context.stroke(pen, with: .color(isSelected ? NibColor.accent : NibColor.label),
                           style: StrokeStyle(lineWidth: Self.penWidth, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}
