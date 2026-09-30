import SwiftUI

/// A capsule when `cornerRadius` is nil, otherwise a continuous rounded rectangle clamped to a capsule.
public struct NibDropletShape: Shape {
    public var cornerRadius: CGFloat?

    public init(cornerRadius: CGFloat? = nil) { self.cornerRadius = cornerRadius }

    public func path(in rect: CGRect) -> Path {
        let capsule = min(rect.width, rect.height) / 2
        let r = min(cornerRadius ?? capsule, capsule)
        return Path(roundedRect: rect, cornerRadius: max(0, r), style: .continuous)
    }
}

/// The four droplet materials (DESIGN.md §2). Nothing else is glass.
public enum NibGlass: Sendable {
    case clear, deep, tinted, bead
}

/// What Nib asks of the system glass on iOS 26+ (DESIGN.md §2.2). Every droplet is the Regular variant: Apple never
/// mixes Regular and Clear in one interface, and Clear is for media-rich backdrops with a dimming layer beneath, which
/// a page of handwriting is not. Regular already thickens itself for large surfaces (popovers, panels) and adapts its
/// shadow and tint to what is beneath, so Deep is not tinted either: a tint means prominence, never thickness, and
/// only the Tinted material (the one primary action) has one. `isInteractive` is set wherever the glass takes the touch.
struct NibSystemGlass: Equatable {
    var tintsAccent: Bool
    var isInteractive: Bool

    static func of(_ kind: NibGlass, interactive: Bool) -> NibSystemGlass {
        NibSystemGlass(tintsAccent: kind == .tinted, isInteractive: interactive)
    }

    @available(iOS 26.0, *)
    var glass: Glass {
        (tintsAccent ? Glass.regular.tint(NibColor.accent) : Glass.regular).interactive(isInteractive)
    }
}

/// Which recipe draws the droplet material (DESIGN.md §2.3, §12). The system glass handles Reduce Transparency (it
/// frosts) and Increase Contrast (it borders) itself, so on iOS 26 only Liquid Off replaces it.
enum NibGlassRenderer: Equatable {
    /// System Liquid Glass (iOS 26+).
    case system
    /// Nib's water: body tint, rim, sheen, outline, shadow (iOS 17–25).
    case water
    /// One opaque fill with the 0.8 pt line: Liquid Off everywhere; Reduce Transparency and thermal throttling on 17–25.
    case opaque

    static func select(systemGlass: Bool, mode: NibLiquidMode, reduceTransparency: Bool,
                       throttled: Bool = false) -> NibGlassRenderer {
        if mode == .off { return .opaque }
        if systemGlass { return .system }
        return reduceTransparency || throttled ? .opaque : .water
    }
}

public extension View {
    /// The droplet material on a single surface that has no physics, such as a floating HUD outside a container.
    /// Inside a `NibDropletContainer` use `.droplet(_:style:)`, which merges, stretches and buds. `interactive`: the
    /// surface holds controls, so on iOS 26 the glass answers touches the way system buttons do.
    func nibGlass(_ kind: NibGlass = .clear, cornerRadius: CGFloat? = nil, interactive: Bool = false) -> some View {
        modifier(NibGlassModifier(kind: kind, shape: NibDropletShape(cornerRadius: cornerRadius), interactive: interactive))
    }

    /// An opaque surface: folder tiles, study cards, cells. Never glass.
    func nibCard(_ fill: Color = NibColor.backgroundSecondary, cornerRadius: CGFloat = NibRadius.tile,
                 elevation: NibElevation? = nil) -> some View {
        modifier(NibCardModifier(fill: fill, cornerRadius: cornerRadius, elevation: elevation))
    }

    func nibElevation(_ level: NibElevation) -> some View {
        modifier(NibElevationModifier(level: level))
    }

    /// Chrome stops growing at xxxLarge; beyond it the Large Content Viewer shows the control (DESIGN.md §4.2).
    /// Applied by the bar groups, HUDs, the palette and the proposal chip only. Panels, the assistant, search results
    /// and plugin panels scale to AX5.
    func nibChromeTypeCap() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct NibGlassModifier: ViewModifier {
    let kind: NibGlass
    let shape: NibDropletShape
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.nibLiquidMode) private var mode
    /// While the Pencil is down nothing samples the backdrop (DESIGN.md §10.8).
    @Environment(\.nibIsInking) private var frozen

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The glass is applied to the content itself, as Apple's custom-view guide does: its foreground effects
            // (vibrant labels, the interactive response) reach the controls. One modifier chain in every state, so a
            // Pencil down or a Liquid change never rebuilds the content.
            content
                .background { systemUnderlay }
                .glassEffect(systemGlass, in: shape)
        } else {
            content.background { fallback }
        }
    }

    private var renderer: NibGlassRenderer {
        var hasSystemGlass = false
        if #available(iOS 26.0, *) { hasSystemGlass = true }
        return NibGlassRenderer.select(systemGlass: hasSystemGlass, mode: mode, reduceTransparency: reduceTransparency)
    }

    private var tint: Color {
        kind == .deep ? NibColor.deepBody : (kind == .tinted ? NibColor.accent : NibColor.clearBody)
    }

    /// iOS 26: nothing under system glass, except the plain body tint while frozen (`.identity` above it), the opaque
    /// fill under Liquid Off, and a bead, which is a plain fill because it only ever sits inside glass (never glass on
    /// glass, no rim painted over the system's).
    @available(iOS 26.0, *)
    @ViewBuilder private var systemUnderlay: some View {
        if renderer == .opaque {
            opaque
        } else if kind == .bead {
            shape.fill(NibColor.beadBody)
        } else if frozen {
            shape.fill(tint)
        }
    }

    @available(iOS 26.0, *)
    private var systemGlass: Glass {
        if renderer == .opaque || kind == .bead || frozen { return .identity }
        return NibSystemGlass.of(kind, interactive: interactive).glass
    }

    @ViewBuilder private var fallback: some View {
        if renderer == .opaque {
            opaque
        } else if kind == .bead {
            shape.fill(NibColor.beadBody)              // a bead is body plus its key rim: no shadow (DESIGN.md §2.2)
                .overlay { NibWaterRimLayer(cornerRadius: shape.cornerRadius, bead: true) }
        } else {
            water
        }
    }

    /// iOS 17–25: the water's shadow (outside the body only), frost under Deep (not while inking), the body tint and
    /// the analytic optics. A lone surface has no page behind it, so it gets no edge lens; Tinted gets its rim and the
    /// outline only.
    private var water: some View {
        ZStack {
            NibWaterShadow(shape: shape)
            if kind == .deep && !frozen {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(tint)
            NibWaterRimLayer(cornerRadius: shape.cornerRadius, rimOnly: kind == .tinted, tinted: kind == .tinted)
        }
    }

    private var opaque: some View {
        shape.fill(kind == .deep ? NibColor.backgroundSecondary : (kind == .tinted ? NibColor.accent : NibColor.chromeOpaque))
            .overlay { shape.stroke(NibColor.waterLine, lineWidth: 0.8) }
            .nibElevation(.rest)
    }
}

/// The water optics of one shape, analytic (no field), for iOS 17–25 surfaces with no container field: `nibGlass`,
/// beads, folder films, the zoom-window frame. Always the directional rim (key rim, counter-rim half as bright) and the
/// 0.8 pt outline under it; the sheen unless `rimOnly` (flat library films, frames, Tinted). `tinted` uses the Tinted
/// rim. `bead` is the key rim alone, no counter-rim, sheen or outline, so a bead never reads as a raised button.
/// `strength` is the rim strength (1 at rest, `DropletStyle.liftedRim` held).
struct NibWaterRimLayer: View {
    let cornerRadius: CGFloat?
    var rimOnly = false
    var tinted = false
    var bead = false
    var outline = true
    var strength: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let r = cornerRadius ?? min(proxy.size.width, proxy.size.height) / 2
            Rectangle()
                .fill(Color.white)
                .padding(-1)                    // 1 pt outset so the anti-aliased edge is not cut
                .colorEffect(NibShaders.waterRim(cornerRadius: r, strength: strength, sheen: !(rimOnly || bead),
                                                 counter: !bead, outline: outline && !bead, tinted: tinted))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// iOS 26: a held droplet's brighter rim (DESIGN.md §10.9, Held). Nothing is painted on the system glass at rest. The
/// body of a droplet in a container never takes the touch, so the system cannot light it up; while it is held this
/// adds only the difference, the key and counter rim at (strength − 1) × `waterRim`, plus-lighter onto the system's own
/// rim. No outline, no sheen.
struct NibLiftRim: View {
    let cornerRadius: CGFloat?
    let boost: CGFloat

    var body: some View {
        NibWaterRimLayer(cornerRadius: cornerRadius, rimOnly: true, outline: false, strength: boost)
            .blendMode(.plusLighter)
    }
}

/// The water's shadow on iOS 17–25 for a lone surface (DESIGN.md §10.9): the silhouette blurred at σ 8 pt, 5 pt down,
/// in `waterShadow`, drawn outside the body only so it never shows through the translucent water. Droplets in a
/// container get the same shadow from the field shader.
struct NibWaterShadow: View {
    let shape: NibDropletShape
    /// How far the shadow reaches past the body: 5 pt down plus two blur radii of 8 pt, rounded up.
    static let reach: CGFloat = 24

    var body: some View {
        let reach = Self.reach
        Canvas { context, size in
            let rect = CGRect(x: reach, y: reach, width: max(0, size.width - 2 * reach),
                              height: max(0, size.height - 2 * reach))
            let silhouette = shape.path(in: rect)
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addPath(silhouette)
            context.clip(to: outside, style: FillStyle(eoFill: true))
            context.addFilter(.shadow(color: NibColor.waterShadow, radius: 8, x: 0, y: NibOptics.shadowOffset,
                                      options: .shadowOnly))
            context.fill(silhouette, with: .color(.black))
        }
        .padding(-reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension GraphicsContext {
    /// The selection bead's rim (DESIGN.md §10.7, §10.9). iOS 17–25: the key rim alone, `waterRim` in a crescent
    /// 0.8 pt wide where the edge faces the top-left light and tapering to nothing where it turns away (the bead minus
    /// itself moved 0.8 pt away from the light). No counter-rim, sheen or line: it must not read as a raised button.
    /// Inside iOS 26 system glass the bead is a plain fill and this draws nothing (no rim over the system's glass).
    mutating func drawNibBeadRim(_ bead: Path, systemGlass: Bool) {
        guard !systemGlass else { return }
        drawLayer { layer in
            layer.fill(bead, with: .color(NibColor.waterRim))
            layer.blendMode = .destinationOut
            layer.fill(bead.offsetBy(dx: -NibOptics.light.dx * NibOptics.beadRim, dy: -NibOptics.light.dy * NibOptics.beadRim),
                       with: .color(.black))
        }
    }
}

struct NibCardModifier: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    let elevation: NibElevation?

    func body(content: Content) -> some View {
        let card = content.background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        if let elevation {
            card.nibElevation(elevation)
        } else {
            card
        }
    }
}
