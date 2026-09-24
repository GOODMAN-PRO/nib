import CoreGraphics

/// Nib's colour data (DESIGN.md §3.4–3.6). UIKit-free, so core modules (NibRender, NibExport) share the one table.
/// Feature UI gets `color` / `uiColor` / `name` from the NibDesign extensions.
public protocol NibHexColour {
    var hex: UInt32 { get }
}

public extension NibHexColour {
    var cgColor: CGColor { NibPalette.cgColor(hex) }
}

public enum NibPalette {
    public static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The 12 default inks. Ink is never themed: the same hex in light and dark mode.
public enum NibInk: String, CaseIterable, Sendable, NibHexColour {
    case carbon, graphite, midnight, cobalt, lagoon, moss, ochre, sienna, vermilion, crimson, plum, chalk

    public var hex: UInt32 {
        switch self {
        case .carbon: return 0x121212
        case .graphite: return 0x5B6068
        case .midnight: return 0x1B2A6B
        case .cobalt: return 0x2156D9
        case .lagoon: return 0x0B8793
        case .moss: return 0x2F7A3C
        case .ochre: return 0xB7791F
        case .sienna: return 0x9A4E2A
        case .vermilion: return 0xD9432B
        case .crimson: return 0xB0173A
        case .plum: return 0x7B3FA0
        case .chalk: return 0xF4F4F1
        }
    }

    /// Inks that vanish against the chrome get a permanent 1 pt ring in pickers: Chalk in light mode,
    /// Carbon and Midnight in dark mode.
    public func needsRing(dark: Bool) -> Bool { dark ? (self == .carbon || self == .midnight) : self == .chalk }
    /// The palette's quick slots on a fresh install.
    public static let quickSlots: [NibInk] = [.carbon, .cobalt, .vermilion]
}

/// Highlighters render beneath ink: multiply at 60 % on light paper, screen at 35 % on dark paper.
public enum NibHighlighter: String, CaseIterable, Sendable, NibHexColour {
    case lemon, apricot, mint, sky, lilac, blush

    public var hex: UInt32 {
        switch self {
        case .lemon: return 0xFFE45C
        case .apricot: return 0xFFBE6B
        case .mint: return 0x86E3AE
        case .sky: return 0x82CCFF
        case .lilac: return 0xC8A8FF
        case .blush: return 0xFFA3C7
        }
    }

    public static let lightPaperOpacity: Double = 0.60
    public static let darkPaperOpacity: Double = 0.35
}

/// Paper colours with their rule and margin-line colours.
public enum NibPaper: String, CaseIterable, Sendable, NibHexColour {
    case white, ivory, legal, grey, slate, night, board

    public var hex: UInt32 {
        switch self {
        case .white: return 0xFFFFFF
        case .ivory: return 0xFBF8F1
        case .legal: return 0xFCF3C8
        case .grey: return 0xF1F1EF
        case .slate: return 0x1E1F22
        case .night: return 0x121212
        case .board: return 0x1F2A24
        }
    }

    public var ruleHex: UInt32 {
        switch self {
        case .white: return 0xCFDBE8
        case .ivory: return 0xD9D3C5
        case .legal: return 0xB9C9DA
        case .grey: return 0xD2D4D8
        case .slate: return 0x34373D
        case .night: return 0x2A2C30
        case .board: return 0x33443A
        }
    }

    public var marginHex: UInt32? {
        switch self {
        case .white: return 0xEDB9B3
        case .ivory: return 0xE9B8A8
        case .legal: return 0xE3A49B
        case .slate: return 0x5A3A38
        case .grey, .night, .board: return nil
        }
    }

    /// Dark papers are not "light paper" for the droplets' backdrop (`nibBackdrop`).
    public var isDark: Bool { self == .slate || self == .night || self == .board }
}

/// Cover cloths: flat colour, a spine at −16 % luminance and an elastic band at −30 %.
public enum NibCoverCloth: String, CaseIterable, Sendable, NibHexColour {
    case moss, carbon, terracotta, sand, navy, oxblood, stone, paper

    public var hex: UInt32 {
        switch self {
        case .moss: return 0x2F4A3E
        case .carbon: return 0x2A2D33
        case .terracotta: return 0xA4553A
        case .sand: return 0xD5C6A8
        case .navy: return 0x23324F
        case .oxblood: return 0x5E1F24
        case .stone: return 0x8C8A84
        case .paper: return 0xF3F1EC
        }
    }

    public var isLight: Bool { self == .sand || self == .paper }
}

/// Collaborator colours; they never collide with ink.
public enum NibPresenceColour {
    public static let hexes: [UInt32] = [0xFF6B5E, 0xFFB547, 0x3DBB7A, 0x3C8DFF, 0x9C6BFF, 0xFF6FAE]
    public static func hex(_ index: Int) -> UInt32 { hexes[((index % hexes.count) + hexes.count) % hexes.count] }
}
