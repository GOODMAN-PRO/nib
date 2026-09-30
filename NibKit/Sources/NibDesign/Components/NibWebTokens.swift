import SwiftUI
import UIKit

/// Nib's tokens as CSS custom properties for plugin HTML panels (DESIGN.md §14.10): `--nib-label`, `--nib-accent`,
/// `--nib-font-body`, `--nib-space-16`, … resolved for the panel's appearance and contrast, plus the system text
/// styles (`-apple-system-body`) so the page follows Dynamic Type. The panel host injects `stylesheet(for:)` at
/// document start and again when the trait collection changes. The page stays transparent: Nib draws the droplet
/// behind it, and a plugin never draws glass.
public enum NibWebTokens {
    /// Colour tokens by CSS name, in declaration order.
    static let colours: [(String, UIColor)] = [
        ("label", NibUIColor.label), ("label-secondary", NibUIColor.labelSecondary),
        ("label-tertiary", NibUIColor.labelTertiary), ("label-quaternary", NibUIColor.labelQuaternary),
        ("separator", NibUIColor.separator), ("separator-soft", NibUIColor.separatorSoft),
        ("fill-1", NibUIColor.fill1), ("fill-2", NibUIColor.fill2), ("fill-3", NibUIColor.fill3),
        ("fill-4", NibUIColor.fill4), ("background", NibUIColor.background),
        ("background-secondary", NibUIColor.backgroundSecondary),
        ("background-tertiary", NibUIColor.backgroundTertiary), ("grouped-background", NibUIColor.groupedBackground),
        ("accent", NibUIColor.accent), ("accent-wash", NibUIColor.accentWash), ("on-accent", NibUIColor.onAccent),
        ("destructive", NibUIColor.destructive), ("success", NibUIColor.success), ("warning", NibUIColor.warning),
    ]

    static let spacing: [CGFloat] = [NibSpacing.xxs, NibSpacing.xs, NibSpacing.s, NibSpacing.m, NibSpacing.l,
                                     NibSpacing.xl, NibSpacing.xxl, NibSpacing.x3, NibSpacing.x4, NibSpacing.x5,
                                     NibSpacing.x6]

    static let radii: [(String, CGFloat)] = [
        ("popover", NibRadius.popover), ("panel", NibRadius.panel), ("proposal", NibRadius.proposal),
        ("tile", NibRadius.tile), ("field", NibRadius.field), ("badge", NibRadius.badge),
        ("thumbnail", NibRadius.thumbnail),
    ]

    /// Type roles as WebKit system fonts: they scale with Dynamic Type like the native text styles.
    static let fonts: [(String, String)] = [
        ("title1", "-apple-system-title1"), ("title2", "-apple-system-title2"), ("title3", "-apple-system-title3"),
        ("headline", "-apple-system-headline"), ("body", "-apple-system-body"),
        ("subheadline", "-apple-system-subheadline"), ("footnote", "-apple-system-footnote"),
        ("caption1", "-apple-system-caption1"), ("caption2", "-apple-system-caption2"),
    ]

    /// Every variable for `traits`, as (name without the leading `--`, CSS value).
    public static func variables(for traits: UITraitCollection) -> [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        for (name, colour) in colours {
            out.append((name: "nib-" + name, value: css(colour, traits: traits)))
        }
        for value in spacing {
            out.append((name: "nib-space-" + number(value), value: number(value) + "px"))
        }
        for (name, value) in radii {
            out.append((name: "nib-radius-" + name, value: number(value) + "px"))
        }
        for (name, value) in fonts {
            out.append((name: "nib-font-" + name, value: value))
        }
        out.append((name: "nib-font-family", value: "-apple-system, system-ui, sans-serif"))
        out.append((name: "nib-font-family-serif", value: "ui-serif, serif"))
        out.append((name: "nib-font-family-rounded", value: "ui-rounded, -apple-system, sans-serif"))
        out.append((name: "nib-font-family-mono", value: "ui-monospace, monospace"))
        out.append((name: "nib-hit-target", value: number(NibMetrics.hitTarget) + "px"))
        return out
    }

    /// A complete stylesheet: the variables on `:root`, the colour scheme, and body text in `label` at the body style.
    public static func stylesheet(for traits: UITraitCollection) -> String {
        let dark = traits.userInterfaceStyle == .dark
        let lines = variables(for: traits).map { "  --\($0.name): \($0.value);" }.joined(separator: "\n")
        return ":root {\n  color-scheme: \(dark ? "dark" : "light");\n\(lines)\n}\n"
            + "html {\n  font: -apple-system-body;\n  color: var(--nib-label);\n  background: transparent;\n"
            + "  -webkit-text-size-adjust: 100%;\n}\n"
    }

    /// `rgba(r, g, b, a)` of `colour` resolved for `traits` (Increase Contrast included), channels clamped to sRGB.
    static func css(_ colour: UIColor, traits: UITraitCollection) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return "rgba(0, 0, 0, 1)"
        }
        func channel(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return "rgba(\(channel(r)), \(channel(g)), \(channel(b)), \(number(min(max(a, 0), 1), digits: 3)))"
    }

    /// A CSS number: no trailing zeros, "." as the decimal separator whatever the locale.
    static func number(_ v: CGFloat, digits: Int = 2) -> String {
        let scale = pow(10, Double(digits))
        let rounded = (Double(v) * scale).rounded() / scale
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
