import SwiftUI
import UIKit
import NibContracts

extension UIColor {
    /// A trait-aware colour from 0xRRGGBB values. `contrastLight` / `contrastDark` replace the alpha under Increase Contrast.
    static func nib(_ light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1,
                    contrastLight: CGFloat? = nil, contrastDark: CGFloat? = nil) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            var alpha = isDark ? darkAlpha : lightAlpha
            if traits.accessibilityContrast == .high, let raised = isDark ? contrastDark : contrastLight {
                alpha = raised
            }
            return UIColor.nibHex(isDark ? dark : light, alpha)
        }
    }

    static func nibHex(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(cgColor: NibPalette.cgColor(hex, alpha: alpha))
    }
}

/// Colour tokens for UIKit (DESIGN.md §3). UI neutrals are Apple's semantic colours; nothing here is a literal in a feature.
public enum NibUIColor {
    // UI neutrals
    public static let label = UIColor.label
    public static let labelSecondary = UIColor.secondaryLabel
    public static let labelTertiary = UIColor.tertiaryLabel
    public static let labelQuaternary = UIColor.quaternaryLabel
    public static let separator = UIColor.separator
    public static let separatorSoft = UIColor.nib(0x3C3C43, 0.12, dark: 0x545458, 0.34)
    public static let fill1 = UIColor.systemFill
    public static let fill2 = UIColor.secondarySystemFill
    public static let fill3 = UIColor.tertiarySystemFill
    public static let fill4 = UIColor.quaternarySystemFill
    public static let background = UIColor.systemBackground
    public static let backgroundSecondary = UIColor.secondarySystemBackground
    public static let backgroundTertiary = UIColor.tertiarySystemBackground
    public static let groupedBackground = UIColor.systemGroupedBackground
    public static let desk = UIColor.nib(0xE7E7EC, dark: 0x121214)
    public static let chromeOpaque = UIColor.nib(0xF4F4F6, dark: 0x2C2C2E)
    public static let scrim = UIColor.nib(0x000000, 0.18, dark: 0x000000, 0.45)

    // Accent (Pool) and semantic
    public static let accent = UIColor.nib(0x0066E0, dark: 0x3D8BFF)
    public static let accentWash = UIColor.nib(0x0066E0, 0.10, dark: 0x3D8BFF, 0.16)
    public static let onAccent = UIColor.white
    public static let destructive = UIColor.systemRed
    public static let success = UIColor.systemGreen
    public static let warning = UIColor.systemOrange

    // Water: what the droplet material is made of (DESIGN.md §3.3). Deep dark body is #1C1C1E @ 86 % (fix 3). On iOS 26
    // the system glass is the material and only the bodies (as the frozen tint while the Pencil is down) are used; the
    // optics tokens below draw Nib's own water on iOS 17–25 (DESIGN.md §10.9).
    public static let clearBody = UIColor.nib(0xFFFFFF, 0.46, dark: 0x161618, 0.62, contrastLight: 0.72, contrastDark: 0.72)
    /// Clear over light paper: dark mode thickens to 80 % so a droplet over white paper is not a grey blob.
    public static let clearBodyOnPaper = UIColor.nib(0xFFFFFF, 0.46, dark: 0x161618, 0.80, contrastLight: 0.72, contrastDark: 0.86)
    public static let deepBody = UIColor.nib(0xF9F9FB, 0.72, dark: 0x1C1C1E, 0.86, contrastLight: 0.90, contrastDark: 0.92)
    public static let waterBody = UIColor.nib(0xFFFFFF, 0.08, dark: 0xFFFFFF, 0.03)
    /// The rim at full strength: a 0.8 pt line lit by the top-left key light, half as bright on the counter side, and
    /// 22 % of it as the sheen inside the lit edge. Never a uniform stroke.
    public static let waterRim = UIColor.nib(0xFFFFFF, 0.85, dark: 0xFFFFFF, 0.50)
    /// A Tinted droplet's only optic (key and counter rim, no sheen).
    public static let tintRim = UIColor.nib(0xFFFFFF, 0.30, dark: 0xFFFFFF, 0.30)
    public static let waterLine = UIColor.nib(0x000000, 0.075, dark: 0xFFFFFF, 0.12, contrastLight: 0.25, contrastDark: 0.40)
    public static let waterLineBud = UIColor.nib(0x000000, 0.12, dark: 0xFFFFFF, 0.16, contrastLight: 0.25, contrastDark: 0.40)
    /// The water's own shadow over a flat backdrop (desk, library, sheets), and over light paper. Light mode: deeper over
    /// paper, where there is ink to separate from (the system glass's shadow grows over text). Dark mode: lighter over
    /// paper, where the dark water already stands off the white page and a deep halo reads as a smudge.
    public static let waterShadow = UIColor.nib(0x000000, 0.08, dark: 0x000000, 0.28)
    public static let waterShadowOnPaper = UIColor.nib(0x000000, 0.13, dark: 0x000000, 0.18)
    public static let beadBody = UIColor.nib(0xFFFFFF, 0.70, dark: 0xFFFFFF, 0.22)
    /// Slider thumbs only; the selection bead has no shadow.
    public static let beadShadow = UIColor.nib(0x000000, 0.16, dark: 0x000000, 0.45)
    public static let swatchHairline = UIColor.nib(0x000000, 0.22, dark: 0xFFFFFF, 0.28)
    /// The permanent 1 pt ring on inks that vanish against the chrome (NibInk.needsRing(dark:)).
    public static let swatchRing = UIColor.nib(0x000000, 0.22, dark: 0xFFFFFF, 0.35)
}

/// The same tokens for SwiftUI.
public enum NibColor {
    public static let label = Color(uiColor: NibUIColor.label)
    public static let labelSecondary = Color(uiColor: NibUIColor.labelSecondary)
    public static let labelTertiary = Color(uiColor: NibUIColor.labelTertiary)
    public static let labelQuaternary = Color(uiColor: NibUIColor.labelQuaternary)
    public static let separator = Color(uiColor: NibUIColor.separator)
    public static let separatorSoft = Color(uiColor: NibUIColor.separatorSoft)
    public static let fill1 = Color(uiColor: NibUIColor.fill1)
    public static let fill2 = Color(uiColor: NibUIColor.fill2)
    public static let fill3 = Color(uiColor: NibUIColor.fill3)
    public static let fill4 = Color(uiColor: NibUIColor.fill4)
    public static let background = Color(uiColor: NibUIColor.background)
    public static let backgroundSecondary = Color(uiColor: NibUIColor.backgroundSecondary)
    public static let backgroundTertiary = Color(uiColor: NibUIColor.backgroundTertiary)
    public static let groupedBackground = Color(uiColor: NibUIColor.groupedBackground)
    public static let desk = Color(uiColor: NibUIColor.desk)
    public static let chromeOpaque = Color(uiColor: NibUIColor.chromeOpaque)
    public static let scrim = Color(uiColor: NibUIColor.scrim)
    public static let accent = Color(uiColor: NibUIColor.accent)
    public static let accentWash = Color(uiColor: NibUIColor.accentWash)
    public static let onAccent = Color(uiColor: NibUIColor.onAccent)
    public static let destructive = Color(uiColor: NibUIColor.destructive)
    public static let success = Color(uiColor: NibUIColor.success)
    public static let warning = Color(uiColor: NibUIColor.warning)
    public static let clearBody = Color(uiColor: NibUIColor.clearBody)
    public static let clearBodyOnPaper = Color(uiColor: NibUIColor.clearBodyOnPaper)
    public static let deepBody = Color(uiColor: NibUIColor.deepBody)
    public static let waterBody = Color(uiColor: NibUIColor.waterBody)
    public static let waterRim = Color(uiColor: NibUIColor.waterRim)
    public static let tintRim = Color(uiColor: NibUIColor.tintRim)
    public static let waterLine = Color(uiColor: NibUIColor.waterLine)
    public static let waterLineBud = Color(uiColor: NibUIColor.waterLineBud)
    public static let waterShadow = Color(uiColor: NibUIColor.waterShadow)
    public static let waterShadowOnPaper = Color(uiColor: NibUIColor.waterShadowOnPaper)
    public static let beadBody = Color(uiColor: NibUIColor.beadBody)
    public static let beadShadow = Color(uiColor: NibUIColor.beadShadow)
    public static let swatchHairline = Color(uiColor: NibUIColor.swatchHairline)
    public static let swatchRing = Color(uiColor: NibUIColor.swatchRing)
}

// The colour tables live in NibContracts (§1, item 6) so core modules share them; UI gets colours and names here.

public extension NibHexColour {
    var uiColor: UIColor { UIColor.nibHex(hex) }
    var color: Color { Color(uiColor: uiColor) }
}

public extension NibInk {
    var name: String {
        switch self {
        case .carbon: return String(localized: "Carbon", bundle: .module)
        case .graphite: return String(localized: "Graphite", bundle: .module)
        case .midnight: return String(localized: "Midnight", bundle: .module)
        case .cobalt: return String(localized: "Cobalt", bundle: .module)
        case .lagoon: return String(localized: "Lagoon", bundle: .module)
        case .moss: return String(localized: "Moss", bundle: .module)
        case .ochre: return String(localized: "Ochre", bundle: .module)
        case .sienna: return String(localized: "Sienna", bundle: .module)
        case .vermilion: return String(localized: "Vermilion", bundle: .module)
        case .crimson: return String(localized: "Crimson", bundle: .module)
        case .plum: return String(localized: "Plum", bundle: .module)
        case .chalk: return String(localized: "Chalk", bundle: .module)
        }
    }
}

public extension NibPaper {
    var ruleColor: Color { Color(uiColor: UIColor.nibHex(ruleHex)) }
    var marginColor: Color? { marginHex.map { Color(uiColor: UIColor.nibHex($0)) } }
}

/// Folder colours come from the ink palette, so the library and the page share one hue vocabulary.
public enum NibFolderColor: String, CaseIterable, Sendable {
    case cobalt, moss, graphite, ochre, plum, vermilion, lagoon, sienna

    public var ink: NibInk { NibInk(rawValue: rawValue) ?? .graphite }
    public var color: Color { ink.color }
}

/// Collaborator colours; they never collide with ink.
public enum NibPresence {
    public static func color(_ index: Int) -> Color { Color(uiColor: UIColor.nibHex(NibPresenceColour.hex(index))) }
}
