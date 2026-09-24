import SwiftUI
import UIKit

/// A top-bar droplet: a Clear capsule of icon buttons (44 pt, up to 52 pt at the Dynamic Type cap).
public struct NibBarGroup<Content: View>: View {
    let id: String
    let content: Content
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 44

    public init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: min(max(scaledHeight, NibMetrics.barHeight), NibMetrics.barHeightMax))
        .nibChromeTypeCap()
        .droplet(id, style: .bar)
        .accessibilityElement(children: .contain)
    }
}

public struct NibToolbarItem: View {
    let symbol: NibSymbol
    let label: String
    let isOn: Bool
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    public init(_ symbol: NibSymbol, label: String, isOn: Bool = false, shortcut: KeyboardShortcut? = nil,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.isOn = isOn
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        NibIconButton(symbol, label: label, size: .bar, isOn: isOn, shortcut: shortcut, action: action)
    }
}

public struct NibBarSeparator: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(NibColor.separator)
            .frame(width: 0.5, height: 22)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

/// Document title in the leading bar droplet: title (barTitle) over the location. The subtitle sits on Clear, so it
/// is caption1 semibold in `label`: `labelSecondary` there is 1.7:1 over black ink (DESIGN.md §2.4).
public struct NibBarTitle: View {
    let title: String
    let subtitle: String?
    let subtitleIsWarning: Bool

    public init(title: String, subtitle: String? = nil, subtitleIsWarning: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsWarning = subtitleIsWarning
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(NibFont.barTitle)
                .foregroundStyle(NibColor.label)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(NibFont.caption1Emphasis)
                    .foregroundStyle(subtitleIsWarning ? NibColor.warning : NibColor.label)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, NibSpacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// A HUD droplet, always 40 pt tall: page counter, zoom, ruler angle, recording clock ("3 / 12", "125%", "04:12").
/// Both parts are `label` (text on Clear, DESIGN.md §2.4); the secondary part is lighter in weight, not in colour.
public struct NibHUD: View {
    let id: String
    let primary: String
    let secondary: String?
    let symbol: NibSymbol?
    let symbolLabel: String?
    let action: (() -> Void)?

    public init(id: String, primary: String, secondary: String? = nil, symbol: NibSymbol? = nil,
                symbolLabel: String? = nil, action: (() -> Void)? = nil) {
        self.id = id
        self.primary = primary
        self.secondary = secondary
        self.symbol = symbol
        self.symbolLabel = symbolLabel
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 2) {
            if let symbol {
                NibIconButton(symbol, label: symbolLabel ?? primary, size: .bar) { action?() }
            }
            HStack(spacing: 3) {
                Text(primary)
                if let secondary {
                    Text(secondary).fontWeight(.medium)
                }
            }
            .font(NibFont.hud)
            .foregroundStyle(NibColor.label)
        }
        .padding(.leading, symbol == nil ? 12 : 0)
        .padding(.trailing, 12)
        .frame(height: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .droplet(id, style: .hud)
        .accessibilityElement(children: .combine)
    }
}

/// The active tool's contextual options (CONTRACTS.md `ToolbarItemDescriptor.activeToolMenu`): a Clear bar droplet
/// that `NibToolPalette(options:)` fuses to the palette's far side, level with the selected tool. Tools never place
/// it themselves.
public struct NibToolOptionsBar<Content: View>: View {
    let id: String
    let content: Content

    public init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, NibSpacing.xs)
            .frame(height: NibMetrics.barHeight)
            .nibChromeTypeCap()
            .droplet(id, style: .bar)
            .accessibilityElement(children: .contain)
    }
}

/// A toast on Deep water: one line of callout and one action (usually Undo). Present it only with `.nibToast($item)`.
public struct NibToast: View {
    let message: String
    let action: NibAction?

    public init(_ message: String, action: NibAction? = nil) {
        self.message = message
        self.action = action
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            Text(message)
                .font(NibFont.callout)
                .foregroundStyle(NibColor.label)
                .lineLimit(2)
            if let action {
                Button(action.title, action: action.handler)
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.accent)
                    .buttonStyle(.plain)
                    .padding(.horizontal, NibSpacing.m)
                    .frame(minHeight: NibMetrics.hitTarget)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, NibSpacing.xs)
        .frame(minHeight: 48)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
    }
}

/// One toast to show. Identity is the toast, not its text: the same message twice is two toasts.
public struct NibToastItem: Identifiable, Equatable {
    public let id = UUID()
    public let message: String
    public let action: NibAction?

    public init(_ message: String, action: NibAction? = nil) {
        self.message = message
        self.action = action
    }

    public static func == (a: NibToastItem, b: NibToastItem) -> Bool { a.id == b.id }
}

public extension View {
    /// Presents toasts (DESIGN.md §13.2): bottom centre, 24 pt above the safe area, budding up from below, one at a
    /// time (a new one replaces the one showing), announced by VoiceOver, dismissed after 6 s. The timer pauses while
    /// VoiceOver is running. Apply it to the content of a `NibDropletContainer`.
    func nibToast(_ item: Binding<NibToastItem?>) -> some View {
        modifier(NibToastPresenter(item: item))
    }
}

struct NibToastPresenter: ViewModifier {
    @Binding var item: NibToastItem?
    @State private var shown: NibToastItem?
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    NibToast(shown?.message ?? "", action: shown?.action)
                        .droplet("nib.toast", style: .toast)
                        .budsFrom("nib.toast.source", isPresented: $presented)
                        .padding(.bottom, NibSpacing.xxl)
                    Color.clear
                        .frame(width: 1, height: 1)
                        .nibBudAnchor("nib.toast.source")          // it buds up from just below its rest
                }
            }
            .task(id: item?.id) {
                guard let next = item else {
                    presented = false
                    return
                }
                shown = next
                presented = true
                AccessibilityNotification.Announcement(next.message).post()
                var remaining = NibMotion.toastDuration
                while remaining > 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }                  // replaced by a newer toast
                    if !UIAccessibility.isVoiceOverRunning { remaining -= 0.25 }
                }
                presented = false
                if item?.id == next.id { item = nil }
            }
    }
}

/// A determinate 3 pt progress bar: export, import, study sessions (DESIGN.md §14.7, §14.11). Never a liquid loader.
public struct NibProgressBar: View {
    let value: Double

    public init(value: Double) { self.value = value }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(NibColor.fill1)
                Capsule()
                    .fill(NibColor.label)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(.updatesFrequently)
    }
}
