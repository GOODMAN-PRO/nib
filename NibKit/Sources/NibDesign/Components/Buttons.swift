import SwiftUI

/// A titled action for components that take one (empty states, toasts, inspector links).
public struct NibAction {
    public let title: String
    public let handler: () -> Void

    public init(_ title: String, handler: @escaping () -> Void) {
        self.title = title
        self.handler = handler
    }
}

/// Capsule button. Primary is the one filled action per surface; destructive is `destructive` text on `fill3`,
/// never a red fill, so a card never has two filled buttons competing (DESIGN.md §13.4).
public struct NibButton: View {
    public enum Kind: Sendable {
        case primary, secondary, destructive, plain
        /// v2: `destructive` text with no fill, for a destructive action that is not the surface's button row (the
        /// eraser's "Clear Page", always followed by a system confirmation).
        case destructivePlain
    }

    public enum Size: Sendable {
        case regular, compact
    }

    let title: String
    let symbol: NibSymbol?
    let kind: Kind
    let size: Size
    let expands: Bool
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `expands` fills the proposed width (equal-width button pairs such as Accept / Discard).
    public init(_ title: String, symbol: NibSymbol? = nil, kind: Kind = .secondary, size: Size = .regular,
                expands: Bool = false, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.size = size
        self.expands = expands
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(nib: symbol)
                }
                Text(title)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .font(NibFont.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .compact ? 14 : 18)
            .padding(.vertical, typeSize.isAccessibilitySize ? NibSpacing.s : 0)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: size == .compact ? 38 : 44)
            .background(background, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .nibShortcut(shortcut)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return NibColor.onAccent
        case .secondary: return NibColor.label
        case .destructive, .destructivePlain: return NibColor.destructive
        case .plain: return NibColor.accent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return NibColor.accent
        case .secondary, .destructive: return NibColor.fill3
        case .plain, .destructivePlain: return Color.clear
        }
    }
}

/// Icon-only button: 44 × 44 hit target whatever the glyph size, and the Large Content Viewer past the type cap.
public struct NibIconButton: View {
    public enum Size: Sendable {
        /// 21 pt Regular in a 40 pt visual.
        case bar
        /// 23 pt Medium.
        case palette
        /// 17 pt Regular.
        case panel
        /// A 30 pt `fill3` disc with a 15 pt Semibold `labelSecondary` glyph (Close).
        case round
        /// A 32 pt `fill3` disc with a 16 pt Semibold `label` arrow (the composer's Send and Stop).
        case send
    }

    let symbol: NibSymbol
    let label: String
    let size: Size
    let isOn: Bool
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var barGlyph: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var paletteGlyph: CGFloat = 23
    @ScaledMetric(relativeTo: .body) private var panelGlyph: CGFloat = 17

    public init(_ symbol: NibSymbol, label: String, size: Size = .bar, isOn: Bool = false,
                shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.isOn = isOn
        self.shortcut = shortcut
        self.action = action
    }

    private var glyph: Font {
        switch size {
        case .bar: return NibFont.glyph(.bar, size: min(barGlyph, 26))
        case .palette: return NibFont.glyph(.palette, size: min(paletteGlyph, 28))
        case .panel: return NibFont.glyph(.panel, size: panelGlyph)
        case .round: return NibFont.glyph(.round)
        case .send: return NibFont.glyph(.send)
        }
    }

    private var disc: CGFloat? {
        switch size {
        case .round: return 30
        case .send: return 32
        default: return nil
        }
    }

    private var tint: Color {
        switch size {
        case .round: return NibColor.labelSecondary
        case .send: return NibColor.label
        default: return isOn ? NibColor.accent : NibColor.label
        }
    }

    public var body: some View {
        Button(action: action) {
            Image(nib: symbol)
                .font(glyph)
                .foregroundStyle(tint)
                .frame(width: disc ?? 40, height: disc ?? 40)
                .background {
                    if disc != nil {
                        Circle().fill(NibColor.fill3)
                    }
                }
                .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .nibShortcut(shortcut)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(label) } icon: { Image(nib: symbol) }
        }
    }
}

/// A key-combination hint, shown while ⌘ is held, after 500 ms of hover, in menus and in the command bar.
public struct KeyHint: View {
    let keys: String

    public init(_ keys: String) { self.keys = keys }

    public init(_ shortcut: KeyboardShortcut) { self.keys = shortcut.nibDisplay }

    public var body: some View {
        Text(keys)
            .font(NibFont.caption2)
            .foregroundStyle(NibColor.labelSecondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(NibColor.fill3, in: RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous))
    }
}

public enum NibBadgeKind: Sendable {
    /// Document type on a cover (PDF, whiteboard, study set, text document).
    case type(NibSymbol)
    /// Proofreader number in the margin and on proposal rows.
    case number(Int)
    case destructiveNumber(Int)
    case count(Int)
    /// "Plugin" provenance capsule.
    case plugin
    case presence(initials: String, colorIndex: Int)
    /// v2: who made it ("You", "Assistant", "Plugin", "Bridge", "Collaborator") with its glyph, on a `fill3` capsule.
    case principal(NibPrincipalKind)
    /// v2: a short word on a `fill3` capsule, like "Plugin": "Update" on a plugin row, "Beta".
    case capsule(String)
}

public struct NibBadge: View {
    let kind: NibBadgeKind

    public init(_ kind: NibBadgeKind) { self.kind = kind }

    public var body: some View {
        switch kind {
        case .type(let symbol):
            Image(nib: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemGray))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        case .number(let n):
            numberDisc(n, fill: NibColor.accent)
        case .destructiveNumber(let n):
            numberDisc(n, fill: NibColor.destructive)
        case .count(let n):
            Text("\(n)")
                .font(NibFont.caption2)
                .monospacedDigit()
                .foregroundStyle(NibColor.labelSecondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(NibColor.fill3, in: Capsule())
        case .plugin:
            textCapsule(String(localized: "Plugin", bundle: .module))
        case .capsule(let text):
            textCapsule(text)
        case .principal(let kind):
            HStack(spacing: NibSpacing.xxs) {
                Image(nib: kind.symbol)
                    .foregroundStyle(kind.glyphColor)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            .font(NibFont.caption2)
            .padding(.horizontal, 7)
            .frame(minHeight: 18)
            .background(NibColor.fill3, in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
        case .presence(let initials, let colorIndex):
            Text(initials)
                .font(NibFont.caption2)
                .foregroundStyle(Color.white)
                .frame(minWidth: 22, minHeight: 22)
                .background(NibPresence.color(colorIndex), in: Circle())
        }
    }

    private func textCapsule(_ text: String) -> some View {
        Text(text)
            .font(NibFont.caption2)
            .foregroundStyle(NibColor.labelSecondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 18)
            .background(NibColor.fill3, in: Capsule())
    }

    private func numberDisc(_ n: Int, fill: Color) -> some View {
        Text("\(n)")
            .font(NibFont.badgeNumber)
            .monospacedDigit()
            .foregroundStyle(NibColor.onAccent)
            .frame(width: 22, height: 22)
            .background(fill, in: Circle())
    }
}
