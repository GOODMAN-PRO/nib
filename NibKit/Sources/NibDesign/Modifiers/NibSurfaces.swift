import SwiftUI
import UIKit

/// A capsule when `cornerRadius` is nil, otherwise a continuous rounded rectangle clamped to a capsule.
public struct NibDropletShape: Shape {
    public var cornerRadius: CGFloat?

    public init(cornerRadius: CGFloat? = nil) { self.cornerRadius = cornerRadius }

    public func path(in rect: CGRect) -> Path {
        guard NibGeometry.isUsable(rect) else { return Path() }
        let capsule = min(rect.width, rect.height) / 2
        let r = min(NibGeometry.dimension(cornerRadius ?? capsule), capsule)
        return Path(roundedRect: rect, cornerRadius: max(0, r), style: .continuous)
    }
}

/// Concentric Deep frost mask; body and optical layers retain their original bounds.
struct NibFrostShape: Shape {
    let shape: NibDropletShape

    func path(in rect: CGRect) -> Path {
        let inset = NibOptics.frostInset
        let radius = min(shape.cornerRadius ?? min(rect.width, rect.height) / 2,
                         min(rect.width, rect.height) / 2)
        return NibDropletShape(cornerRadius: max(0, radius - inset))
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }
}

/// The four droplet materials (DESIGN.md §2). Nothing else is glass.
public enum NibGlass: Sendable {
    case clear, deep, tinted, bead
}

/// What Nib asks of the system glass on iOS 26+ (DESIGN.md §2.2). Every droplet is the Regular variant: Apple never
/// mixes Regular and Clear in one interface, and Clear is for media-rich backdrops with a dimming layer beneath, which
/// a page of handwriting is not. Regular already thickens itself for large surfaces (popovers, panels) and adapts its
/// shadow and tint to what is beneath. Deep stays untinted; its dark contrast body is an underlay (§2.3), not a glass
/// tint. Only the Tinted material (the one primary action) has an accent tint. `isInteractive` follows the controls.
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

/// The native material wraps its foreground directly. Kept in one host so a sibling glass shape cannot accidentally
/// lens labels; its returned view structure is also inspectable by hostless tests.
@available(iOS 26.0, *)
struct NibNativeGlass<Foreground: View>: View {
    let effect: Glass
    let shape: NibDropletShape
    @ViewBuilder let foreground: () -> Foreground
    @Environment(\.self) private var environment

    var body: some View {
        // Capture the app's appearance outside the glass host. Native glass can adapt its foreground to white
        // paper, but our dark contrast underlay still needs the app's light label/icon tokens (DESIGN.md §2.4).
        let appearance = environment.nibChromeAppearance ?? NibChromeAppearance(environment)
        material(on: foreground()
            .foregroundStyle(Color(NibColor.label.resolve(in: appearance.environment)))
            .environment(\.nibChromeAppearance, appearance)
            .environment(\.colorScheme, appearance.colorScheme))
            // The material needs the same appearance as its foreground. An environment override only
            // before glassEffect reaches the labels, leaving the native effect free to render light glass.
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.nibChromeAppearance, appearance)
            // The UIKit-backed effect captures traits when its native host is created. Updating only
            // SwiftUI's environment can leave that host in its previous appearance. Recreate this
            // effect/foreground pair together, without replacing the container's field or glass IDs.
            .id(appearance.colorScheme)
    }

    /// Give the compositor a native primitive, not an arbitrary Path whose inferred optical mesh can
    /// facet across a large panel. Underlays still use the matching continuous silhouette.
    @ViewBuilder private func material<V: View>(on foreground: V) -> some View {
        if let radius = shape.cornerRadius {
            foreground.modifier(NibNativeGlassOptics(effect: effect,
                shape: RoundedRectangle(cornerRadius: NibGeometry.dimension(radius), style: .continuous)))
        } else {
            foreground.modifier(NibNativeGlassOptics(effect: effect, shape: Capsule()))
        }
    }
}

/// Preserve the native primitive in the view's type as well as the compositor input. The system glass modifier
/// erases its shape type, so keeping this typed boundary lets hostless checks verify the actual optical geometry.
@available(iOS 26.0, *)
private struct NibNativeGlassOptics<Geometry: Shape>: ViewModifier {
    let effect: Glass
    let shape: Geometry

    func body(content: Content) -> some View {
        content.glassEffect(effect, in: shape)
    }
}

/// Body colour is shared by frozen glass and the dark-paper contrast exception (DESIGN.md §2.3).
/// It is always beneath the system material; no extra rim, sheen or coloured light is painted over glass.
enum NibGlassBodyTint {
    static func color(_ kind: NibGlass, paperShare: Double = 0, colorScheme: ColorScheme? = nil) -> Color {
        Color(uiColor: resolvedColor(kind, paperShare: paperShare, colorScheme: colorScheme))
    }

    static func resolvedColor(_ kind: NibGlass, paperShare: Double = 0, colorScheme: ColorScheme? = nil) -> UIColor {
        let dynamic: UIColor
        switch kind {
        case .deep: dynamic = NibUIColor.deepBody
        case .tinted: dynamic = NibUIColor.accent
        case .bead: dynamic = NibUIColor.beadBody
        case .clear:
            let share = paperShare.isFinite ? min(max(paperShare, 0), 1) : 0
            dynamic = UIColor { traits in
                let base = NibUIColor.clearBody.resolvedColor(with: traits)
                let paper = NibUIColor.clearBodyOnPaper.resolvedColor(with: traits)
                return base.withAlphaComponent(base.cgColor.alpha + (paper.cgColor.alpha - base.cgColor.alpha) * CGFloat(share))
            }
        }
        guard let colorScheme else { return dynamic }
        return dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }

    static func systemUnderlay(_ kind: NibGlass, colorScheme: ColorScheme, paperShare: Double) -> Color {
        guard colorScheme == .dark else { return .clear }
        if kind == .deep { return color(.deep, colorScheme: colorScheme) }
        if kind == .clear && paperShare > 0.6 { return color(.clear, paperShare: paperShare, colorScheme: colorScheme) }
        return .clear
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nibChromeAppearance) private var chromeAppearance
    @Environment(\.nibBackdrop) private var backdrop
    @Environment(DropletField.self) private var field: DropletField?
    @State private var restFrame = CGRect.zero

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The glass is applied to the content itself, as Apple's custom-view guide does: its foreground effects
            // (vibrant labels, the interactive response) reach the controls. One modifier chain in every state, so a
            // Pencil down or a Liquid change never rebuilds the content.
            NibNativeGlass(effect: systemGlass, shape: shape) {
                content
            }
            .background {
                if !sharesNativeBackdrop { systemUnderlay }
            }
            .anchorPreference(key: NibGlassBackdropKey.self, value: .bounds) { bounds in
                sharesNativeBackdrop
                    ? [NibGlassBackdrop(bounds: bounds, shape: shape, kind: kind, frozen: frozen)]
                    : []
            }
            .background {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: NibLiquid.space) } action: { restFrame = $0 }
            }
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
        NibGlassBodyTint.color(kind, paperShare: paperShare, colorScheme: resolvedScheme)
    }

    private var resolvedScheme: ColorScheme { chromeAppearance?.colorScheme ?? colorScheme }

    private var paperShare: Double { DropletField.paperShare(restFrame, in: backdrop) }

    /// Static nibGlass surfaces can also live inside a container. Hand their neutral body to its backdrop
    /// layer even while frozen, so a Pencil down never changes its placement. Beads and opaque fallbacks stay local.
    private var sharesNativeBackdrop: Bool {
        field != nil && renderer == .system && kind != .bead
    }

    /// The dark-paper contrast body is beneath glass, alongside the frozen, Liquid Off and bead fills.
    @available(iOS 26.0, *)
    @ViewBuilder private var systemUnderlay: some View {
        if renderer == .opaque {
            opaque
        } else if kind == .bead {
            shape.fill(NibColor.beadBody)
        } else if frozen {
            shape.fill(tint)
        } else {
            shape.fill(NibGlassBodyTint.systemUnderlay(kind, colorScheme: resolvedScheme, paperShare: paperShare))
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
                NibFrostShape(shape: shape).fill(.ultraThinMaterial)
            }
            shape.fill(tint)
            NibWaterRimLayer(cornerRadius: shape.cornerRadius, rimOnly: kind == .tinted, tinted: kind == .tinted)
        }
    }

    var opaque: some View {
        shape.fill(kind == .deep ? NibColor.backgroundSecondary : (kind == .tinted ? NibColor.accent : NibColor.chromeOpaque))
            .overlay { shape.stroke(NibColor.waterLine, lineWidth: NibStroke.outline) }
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
/// held state follows Nib's lift spring; while it is held this adds only the difference, the key and counter rim at
/// (strength − 1) × `waterRim`, plus-lighter onto the system's own rim. No outline, no sheen.
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
