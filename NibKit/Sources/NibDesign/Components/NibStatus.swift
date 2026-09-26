import SwiftUI

// MARK: - HUDs

/// A HUD droplet with its own content (DESIGN.md §5: every HUD is 40 pt tall): the in-document search "3 of 11" with
/// previous and next, the presenter HUD, the recording HUD (dot, clock, waveform, Pause, Stop), "Following Sam ·
/// Stop", the bridge status pill. Compose `NibHUDText`, `NibIconButton(.bar)`, `NibStatusDot` and `NibWaveform`
/// inside. `NibHUD` is the one-number form. Capped at xxxLarge.
public struct NibHUDGroup<Content: View>: View {
    let id: String
    let content: Content

    public init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: NibSpacing.xxs) {
            content
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .droplet(id, style: .hud)
        .accessibilityElement(children: .contain)
    }
}

/// HUD type on Clear (DESIGN.md §2.4): the primary part and an optional lighter secondary part, both `label`. Digits
/// change with no animation.
public struct NibHUDText: View {
    let primary: String
    let secondary: String?

    public init(_ primary: String, secondary: String? = nil) {
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        HStack(spacing: 3) {
            Text(primary)
            if let secondary {
                Text(secondary).fontWeight(.medium)
            }
        }
        .font(NibFont.hud)
        .foregroundStyle(NibColor.label)
        .lineLimit(1)
        .padding(.horizontal, NibSpacing.s)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dots and beads

/// A 6 pt status dot (DESIGN.md §14.9, §14.13, §14.14): unseen changes on a thumbnail (accent), the bridge's
/// connected client (success), recording (destructive), a warning. Never the only signal: put it beside a label or
/// give the element a value.
public struct NibStatusDot: View {
    public enum Kind: Sendable {
        case unseen, connected, recording, warning
    }

    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    var color: Color {
        switch kind {
        case .unseen: return NibColor.accent
        case .connected: return NibColor.success
        case .recording: return NibColor.destructive
        case .warning: return NibColor.warning
        }
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: NibMetrics.statusDot, height: NibMetrics.statusDot)
            .accessibilityHidden(true)
    }
}

/// Collaborators after the document title (DESIGN.md §14.14): up to three 22 pt initial beads, then "+N"; compact
/// (iPhone) shows one bead and the count. VoiceOver reads the names.
public struct NibPresenceStack: View {
    public struct Person: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let initials: String
        public let colorIndex: Int

        public init(id: String, name: String, initials: String, colorIndex: Int) {
            self.id = id
            self.name = name
            self.initials = initials
            self.colorIndex = colorIndex
        }
    }

    let people: [Person]
    let compact: Bool

    public init(_ people: [Person], compact: Bool = false) {
        self.people = people
        self.compact = compact
    }

    /// How many beads show and how many fold into "+N".
    static func layout(count: Int, compact: Bool) -> (shown: Int, overflow: Int) {
        let limit = compact ? 1 : NibMetrics.presenceMaxShown
        let shown = min(max(count, 0), limit)
        return (shown, max(count, 0) - shown)
    }

    public var body: some View {
        let split = Self.layout(count: people.count, compact: compact)
        HStack(spacing: NibSpacing.xs) {
            ForEach(people.prefix(split.shown)) { person in
                NibBadge(.presence(initials: person.initials, colorIndex: person.colorIndex))
            }
            if split.overflow > 0 {
                Text(verbatim: "+\(split.overflow)")
                    .font(NibFont.caption2)
                    .monospacedDigit()
                    .foregroundStyle(NibColor.label)
                    .frame(minWidth: NibMetrics.presenceBead, minHeight: NibMetrics.presenceBead)
                    .background(NibColor.fill1, in: Circle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ListFormatter.localizedString(byJoining: people.map(\.name)))
    }
}

/// A live level meter (DESIGN.md §14.13): 2 pt bars in `labelSecondary`, no colour, nothing animated of its own; each
/// new `levels` array redraws it. Levels are 0…1, newest last; the meter shows the newest `bars` of them.
public struct NibWaveform: View {
    let levels: [Double]
    let bars: Int
    let height: CGFloat

    public init(levels: [Double], bars: Int = 24, height: CGFloat = 20) {
        self.levels = levels
        self.bars = bars
        self.height = height
    }

    /// Bar heights, oldest first: the newest `bars` levels clamped to 0…1, silence padded at the front, at least
    /// 2 pt so a quiet room still shows a line.
    static func heights(_ levels: [Double], bars: Int, maxHeight: CGFloat) -> [CGFloat] {
        let count = max(bars, 0)
        let recent = levels.suffix(count).map { CGFloat(min(max($0.isFinite ? $0 : 0, 0), 1)) }
        let padded = Array(repeating: CGFloat(0), count: count - recent.count) + recent
        return padded.map { max(2, $0 * maxHeight) }
    }

    public var body: some View {
        let pitch = NibStroke.ring * 2
        Canvas { context, size in
            let h = Self.heights(levels, bars: bars, maxHeight: size.height)
            for (i, bar) in h.enumerated() {
                let rect = CGRect(x: CGFloat(i) * pitch, y: (size.height - bar) / 2, width: NibStroke.ring, height: bar)
                context.fill(Path(roundedRect: rect, cornerRadius: NibStroke.ring / 2), with: .color(NibColor.labelSecondary))
            }
        }
        .frame(width: CGFloat(max(bars, 0)) * pitch, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// A notice row (DESIGN.md §14.18): "2 notebooks changed on two devices · Resolve" at the top of the library, a
/// document written by a newer Nib, safe mode, the assistant's inline error with Retry, "You're offline…". A glyph,
/// the message in callout and at most one plain action, on `fill4` with the proposal radius. Never glass, never a toast.
public struct NibBanner: View {
    public enum Style: Sendable {
        case info, warning
    }

    let message: String
    let style: Style
    let symbol: NibSymbol?
    let action: NibAction?

    public init(_ message: String, style: Style = .warning, symbol: NibSymbol? = nil, action: NibAction? = nil) {
        self.message = message
        self.style = style
        self.symbol = symbol
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: NibSpacing.m) {
            Image(nib: symbol ?? (style == .warning ? .warningTriangle : .info))
                .font(NibFont.glyph(.panel))
                .foregroundStyle(style == .warning ? NibColor.warning : NibColor.labelSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(NibFont.callout)
                .foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.handler)
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: NibMetrics.hitTarget)
            }
        }
        .padding(.horizontal, NibSpacing.l)
        .padding(.vertical, NibSpacing.xs)
        .frame(minHeight: NibMetrics.hitTarget)
        .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A tool-trace row in the assistant thread (DESIGN.md §14.9, §14.18): "Read page 3 · 14 handwritten lines
/// recognised" in caption1. Running shows a small activity indicator (never a pulsing bead), done a `success` check,
/// warning a `warning` triangle.
public struct NibTraceRow: View {
    public enum Phase: Sendable {
        case running, done, warning
    }

    let text: String
    let phase: Phase

    public init(_ text: String, phase: Phase) {
        self.text = text
        self.phase = phase
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                switch phase {
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                case .done:
                    Image(nib: .checkmark)
                        .foregroundStyle(NibColor.success)
                case .warning:
                    Image(nib: .warningTriangle)
                        .foregroundStyle(NibColor.warning)
                }
            }
            .font(NibFont.caption1Emphasis)
            .accessibilityHidden(true)
            Text(text)
                .font(NibFont.caption1)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(phase == .running ? String(localized: "In progress", bundle: .module) : "")
    }
}

// MARK: - Droplet buttons

/// A droplet that is itself one button (DESIGN.md §2.2, §14.1, §14.11): the library's Tinted "+ New" (96 × 44; the
/// 44 × 44 icon-only New and search droplets on iPhone), the four Clear grading droplets under a study card (Again ·
/// Hard · Good · Easy with the next interval). Tinted is the one primary action on a screen (§2.4). Place it in the
/// container; give each a unique id. The detail line is caption1 semibold in `label`, the one small type allowed on
/// Clear. Capped at xxxLarge.
public struct NibDropletButton: View {
    public enum Kind: Sendable {
        case clear, tinted
    }

    let id: String
    let title: String?
    let detail: String?
    let symbol: NibSymbol?
    let label: String
    let kind: Kind
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(id: String, title: String, symbol: NibSymbol? = nil, detail: String? = nil, kind: Kind = .clear,
                shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.label = detail.map { String(localized: "\(title), \($0)", bundle: .module) } ?? title
        self.kind = kind
        self.shortcut = shortcut
        self.action = action
    }

    /// Icon only (44 × 44): `label` is what VoiceOver and the Large Content Viewer say.
    public init(id: String, symbol: NibSymbol, label: String, kind: Kind = .clear, shortcut: KeyboardShortcut? = nil,
                action: @escaping () -> Void) {
        self.id = id
        self.title = nil
        self.detail = nil
        self.symbol = symbol
        self.label = label
        self.kind = kind
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(nib: symbol)
                        .font(NibFont.glyph(.bar))
                }
                if let title {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(NibFont.button)
                        if let detail {
                            Text(detail)
                                .font(NibFont.caption1Emphasis)
                        }
                    }
                    .lineLimit(1)
                }
            }
            .foregroundStyle(kind == .tinted ? NibColor.onAccent : NibColor.label)
            .opacity(isEnabled ? 1 : NibOpacity.disabled)
            .padding(.horizontal, title == nil ? 0 : NibSpacing.l)
            .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .nibShortcut(shortcut)
        .nibChromeTypeCap()
        .droplet(id, style: kind == .tinted ? .primary : .bar)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            if let symbol {
                Label { Text(label) } icon: { Image(nib: symbol) }
            } else {
                Text(label)
            }
        }
    }
}
