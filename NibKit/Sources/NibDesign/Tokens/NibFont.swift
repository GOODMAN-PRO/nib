import SwiftUI
import UIKit

/// Type roles (DESIGN.md §4). SF Pro for UI, SF Pro Rounded for numbers that live on water, New York for editorial moments.
/// Text styles carry Apple's tracking tables, so nothing sets tracking or kerning by hand.
public enum NibFont {
    public static let display = Font.largeTitle.weight(.bold)
    public static let displayEditorial = Font.system(.largeTitle, design: .serif).weight(.semibold)
    public static let title1 = Font.title.weight(.bold)
    public static let cardFace = Font.system(.title, design: .serif)
    public static let title2 = Font.title2.weight(.bold)
    public static let title3 = Font.title3.weight(.semibold)
    public static let emptyTitle = Font.system(.title3, design: .serif).weight(.semibold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let bodyEmphasis = Font.body.weight(.semibold)
    public static let callout = Font.callout
    public static let chat = Font.subheadline
    public static let chatEmphasis = Font.subheadline.weight(.medium)
    public static let button = Font.subheadline.weight(.semibold)
    public static let barTitle = Font.subheadline.weight(.semibold)
    public static let footnote = Font.footnote
    public static let footnoteEmphasis = Font.footnote.weight(.semibold)
    public static let caption1 = Font.caption
    /// The only caption allowed on Clear (bar subtitles), and only in `label` (DESIGN.md §2.4).
    public static let caption1Emphasis = Font.caption.weight(.semibold)
    public static let caption2 = Font.caption2.weight(.medium)
    public static let hud = Font.system(.footnote, design: .rounded).weight(.semibold).monospacedDigit()
    public static let hudLarge = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
    public static let math = Font.system(.callout, design: .serif).italic()
    /// Developer console and raw tool calls only. Never used as a decorative metadata style.
    public static let code = Font.system(.footnote, design: .monospaced)
    /// The assistant thread reads at 15/21: subheadline plus 1 pt of leading.
    public static let chatLineSpacing: CGFloat = 1

    // v2 additions (DESIGN.md §4.1)
    /// The proofreader and comment-pin number: SF Rounded bold on a 22 pt disc (`NibBadge(.number)`).
    public static let badgeNumber = Font.system(.footnote, design: .rounded).weight(.bold)
    /// Text documents read in New York 17 (DESIGN.md §14.17): the default body of a text document.
    public static let documentBody = Font.system(.body, design: .serif)

    /// Text-document headings H1–H3 in New York bold (title, title2, title3); other levels read as H3.
    public static func documentHeading(_ level: Int) -> Font {
        switch level {
        case ...1: return Font.system(.title, design: .serif).weight(.bold)
        case 2: return Font.system(.title2, design: .serif).weight(.bold)
        default: return Font.system(.title3, design: .serif).weight(.bold)
        }
    }

    /// SF Symbol sizes and weights (DESIGN.md §8). Where a glyph must grow with Dynamic Type, the component scales
    /// the size with `@ScaledMetric` and caps it (palette 28, bars 26).
    public static func glyph(_ g: NibGlyph, size: CGFloat? = nil) -> Font {
        .system(size: size ?? g.size, weight: g.weight)
    }
}

/// The symbol roles of DESIGN.md §8.
public enum NibGlyph: Sendable {
    /// Palette tools: Medium 23 pt.
    case palette
    /// Bar buttons: Regular 21 pt.
    case bar
    /// Sidebar rows: Regular 22 pt.
    case sidebar
    /// Controls in Deep panels: Regular 17 pt.
    case panel
    /// The glyph in a 30 pt round button: Semibold 15 pt.
    case round
    /// The arrow on the 32 pt send disc: Semibold 16 pt.
    case send

    public var size: CGFloat {
        switch self {
        case .palette: return 23
        case .bar: return 21
        case .sidebar: return 22
        case .panel: return 17
        case .round: return 15
        case .send: return 16
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .palette: return .medium
        case .bar, .sidebar, .panel: return .regular
        case .round, .send: return .semibold
        }
    }

    var uiWeight: UIImage.SymbolWeight {
        switch self {
        case .palette: return .medium
        case .bar, .sidebar, .panel: return .regular
        case .round, .send: return .semibold
        }
    }
}

/// The same roles for UIKit, scaled with Dynamic Type through UIFontMetrics.
public enum NibUIFont {
    private static let largeSizes: [UIFont.TextStyle: CGFloat] = [
        .largeTitle: 34, .title1: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17,
        .callout: 16, .subheadline: 15, .footnote: 13, .caption1: 12, .caption2: 11,
    ]

    public static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular,
                            design: UIFontDescriptor.SystemDesign = .default) -> UIFont {
        let size = largeSizes[style] ?? 17
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if design != .default, let designed = font.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: designed, size: size)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    public static var body: UIFont { font(.body) }
    public static var headline: UIFont { font(.headline, weight: .semibold) }
    public static var chat: UIFont { font(.subheadline) }
    public static var barTitle: UIFont { font(.subheadline, weight: .semibold) }
    public static var footnote: UIFont { font(.footnote) }
    public static var caption1: UIFont { font(.caption1) }
    public static var hud: UIFont { font(.footnote, weight: .semibold, design: .rounded) }

    // v2 additions: the rest of DESIGN.md §4.1 for UIKit surfaces (outline and bookmark rows, keyboard bars, text
    // documents, comment pins). Each scales with Dynamic Type; set `adjustsFontForContentSizeCategory` on the label.
    public static var display: UIFont { font(.largeTitle, weight: .bold) }
    public static var displayEditorial: UIFont { font(.largeTitle, weight: .semibold, design: .serif) }
    public static var title1: UIFont { font(.title1, weight: .bold) }
    public static var cardFace: UIFont { font(.title1, design: .serif) }
    public static var title2: UIFont { font(.title2, weight: .bold) }
    public static var title3: UIFont { font(.title3, weight: .semibold) }
    public static var emptyTitle: UIFont { font(.title3, weight: .semibold, design: .serif) }
    public static var bodyEmphasis: UIFont { font(.body, weight: .semibold) }
    public static var callout: UIFont { font(.callout) }
    public static var chatEmphasis: UIFont { font(.subheadline, weight: .medium) }
    public static var button: UIFont { font(.subheadline, weight: .semibold) }
    public static var footnoteEmphasis: UIFont { font(.footnote, weight: .semibold) }
    public static var caption1Emphasis: UIFont { font(.caption1, weight: .semibold) }
    public static var caption2: UIFont { font(.caption2, weight: .medium) }
    public static var hudLarge: UIFont { font(.title1, weight: .semibold, design: .rounded) }
    public static var badgeNumber: UIFont { font(.footnote, weight: .bold, design: .rounded) }
    /// Developer console and raw tool calls only.
    public static var code: UIFont { font(.footnote, design: .monospaced) }
    public static var documentBody: UIFont { font(.body, design: .serif) }

    /// Text-document headings H1–H3 (`NibFont.documentHeading`).
    public static func documentHeading(_ level: Int) -> UIFont {
        switch level {
        case ...1: return font(.title1, weight: .bold, design: .serif)
        case 2: return font(.title2, weight: .bold, design: .serif)
        default: return font(.title3, weight: .bold, design: .serif)
        }
    }

    /// A symbol configuration for `UIImage(nib:)` in UIKit (`UIImageView.preferredSymbolConfiguration`).
    public static func glyph(_ g: NibGlyph) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: g.size, weight: g.uiWeight)
    }
}
