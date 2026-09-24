import SwiftUI

/// Edges a floating palette can dock to.
public enum NibDock: String, CaseIterable, Sendable {
    case leading, trailing, top, bottom

    public var isVertical: Bool { self == .leading || self == .trailing }

    var moveTitle: String {
        switch self {
        case .leading: return String(localized: "Move palette to the left edge", bundle: .module)
        case .trailing: return String(localized: "Move palette to the right edge", bundle: .module)
        case .top: return String(localized: "Move palette to the top", bundle: .module)
        case .bottom: return String(localized: "Move palette to the bottom", bundle: .module)
        }
    }
}

/// How a droplet responds to a drag.
public enum DropletDrag: Equatable, Sendable {
    /// Does not move (bars, HUDs, popovers, handles: their feature moves them).
    case fixed
    /// Follows the finger and returns to its rest, or to a new rest the feature lays out, with the `slot` spring from
    /// the part of the release velocity that points there (cards, thumbnails, floating panels).
    case free
    /// Docks to screen edges with `snap` from the full release velocity (the palette manages this itself).
    case docks([NibDock])
    /// Hangs from an anchor and flows back to its dock on release (the AI proposal chip).
    case tethered
}

/// The droplet materials. (Not `Material`: that would shadow `SwiftUI.Material` inside this module and trip the
/// lint rule for materials in features.)
public enum DropletMaterial: Equatable, Sendable {
    case clear, deep, tinted
}

/// A droplet preset. Feature code only uses the static presets.
public struct DropletStyle: Equatable, Sendable {
    public var material: DropletMaterial
    /// nil = capsule.
    public var cornerRadius: CGFloat?
    public var stretchCap: CGFloat
    public var vRef: CGFloat = 2600
    /// Content follows s × rigidity: icons 0.55, covers 0.70, chip 0.35, popover content 0.15, panels 0.10.
    public var rigidity: CGFloat
    public var lift: CGFloat = 1.035
    /// Stretch-velocity impulse on a press, sized to the droplet's wobble spring: 2.4 is a 2.5 % squash on a 44 pt bar.
    public var poke: CGFloat = 2.4
    var neck: NeckParams?
    public var drag: DropletDrag = .fixed
    /// Water margin that grows around the content while lifted (covers and thumbnails: 3 pt).
    public var envelope: CGFloat = 0
    /// No water at rest: the droplet only exists while it is dragged or settling (covers, thumbnails).
    public var restsDry = false
    /// Necks only on request (`.droplet(bondsWith:)`), never from proximity: library cards bond once a combine arms.
    public var bondsOnRequest = false
    /// Rim and outline only, no body (the zoom-window target frame). Drawn by the droplet itself, outside the union.
    public var drawsBody = true
    /// Page-resident droplets sit on ink and never refract it (the chip, the lasso object menu).
    public var refracts = true
    /// iOS 26 glass responds to touch with the system's own highlight.
    public var isInteractive = true

    public static let bar = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.10, rigidity: 0.5,
                                         neck: NeckParams(join: 11, t0: 26, off: 44))
    public static let hud = bar
    public static let palette = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.09, rigidity: 0.55,
                                             poke: 2.2, neck: NeckParams(join: 11, t0: 26, off: 44),
                                             drag: .docks(NibDock.allCases))
    public static let popover = DropletStyle(material: .deep, cornerRadius: NibRadius.popover, stretchCap: 0.06,
                                             rigidity: 0.15, lift: 1.0, poke: 0.5,
                                             neck: NeckParams(join: 11, t0: 30, off: 21), isInteractive: false)
    public static let panel = DropletStyle(material: .deep, cornerRadius: NibRadius.panel, stretchCap: 0.03,
                                           rigidity: 0.10, lift: 1.0, poke: 0.5,
                                           neck: NeckParams(join: 11, t0: 28, off: 44), isInteractive: false)
    public static let floatingPanel = DropletStyle(material: .deep, cornerRadius: NibRadius.panel, stretchCap: 0.03,
                                                   rigidity: 0.10, lift: 1.02, poke: 0.5,
                                                   neck: NeckParams(join: 11, t0: 28, off: 44), drag: .free,
                                                   isInteractive: false)
    public static let chip = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.16, rigidity: 0.35,
                                          lift: 1.05, neck: NeckParams(join: 14, t0: 24, off: 96), drag: .tethered,
                                          refracts: false)
    public static let anchor = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.20, rigidity: 1,
                                            lift: 1.0, neck: NeckParams(join: 14, t0: 24, off: 96), refracts: false)
    public static let card = DropletStyle(material: .clear, cornerRadius: NibRadius.coverSpine, stretchCap: 0.10,
                                          vRef: 2800, rigidity: 0.70, lift: 1.045, poke: 1.4,
                                          neck: NeckParams(join: 13, t0: 30, off: 46), drag: .free, envelope: 3,
                                          restsDry: true, bondsOnRequest: true)
    public static let thumbnail = DropletStyle(material: .clear, cornerRadius: NibRadius.thumbnail, stretchCap: 0.10,
                                               rigidity: 0.70, lift: 1.045, poke: 1.4, drag: .free, envelope: 3,
                                               restsDry: true)
    public static let toast = DropletStyle(material: .deep, cornerRadius: nil, stretchCap: 0.08, rigidity: 0.2,
                                           lift: 1.0, poke: 1.0, isInteractive: false)
    public static let primary = DropletStyle(material: .tinted, cornerRadius: nil, stretchCap: 0.10, rigidity: 0.5,
                                             neck: NeckParams(join: 11, t0: 26, off: 44))
    /// Precision affordances never deform (DESIGN.md §10.15): lasso and resize handles, the rotation bead.
    public static let handle = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0, rigidity: 1, lift: 1.0,
                                            poke: 0, refracts: false, isInteractive: false)
    /// The zoom-window target: rim and outline only, radius 18, draggable with stretch.
    public static let frame = DropletStyle(material: .clear, cornerRadius: NibRadius.zoomFrame, stretchCap: 0.06,
                                           rigidity: 1, lift: 1.0, poke: 0, drag: .free, drawsBody: false,
                                           refracts: false, isInteractive: false)

    var glassKind: NibGlass {
        switch material {
        case .clear: return .clear
        case .deep: return .deep
        case .tinted: return .tinted
        }
    }
}

@available(iOS 26.0, *)
extension DropletStyle {
    var systemGlass: Glass {
        switch material {
        case .clear: return refracts ? Glass.regular.interactive(isInteractive) : Glass.clear.interactive(isInteractive)
        case .deep: return Glass.regular.tint(NibColor.deepGlassTint)
        case .tinted: return Glass.regular.tint(NibColor.accent).interactive(isInteractive)
        }
    }
}

/// Where the palette rests: an edge plus a 0…1 position along it.
public struct NibPaletteDock: Equatable, Sendable {
    public var edge: NibDock
    public var along: CGFloat

    public init(edge: NibDock, along: CGFloat = 0.5) {
        self.edge = edge
        self.along = along
    }

    public var isVertical: Bool { edge.isVertical }
}

/// Drag events a feature can observe (library drop targets, page reorder), in `NibLiquid.space` coordinates.
public enum NibDropletDrag {
    case began(location: CGPoint)
    case changed(location: CGPoint)
    case ended(location: CGPoint, velocity: CGVector)
}
