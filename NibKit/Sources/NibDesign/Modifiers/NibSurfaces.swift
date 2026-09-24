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

public extension View {
    /// The droplet material on a single surface that has no physics, such as a floating HUD outside a container.
    /// Inside a `NibDropletContainer` use `.droplet(_:style:)`, which merges, stretches and buds.
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
        content.background { material }
    }

    @ViewBuilder private var material: some View {
        if reduceTransparency || mode == .off {
            opaque
        } else if kind == .bead {
            shape.fill(NibColor.beadBody)              // a bead is body plus rim: no shadow (DESIGN.md §2.2)
                .overlay { NibWaterRimLayer(cornerRadius: shape.cornerRadius, rimOnly: true) }
        } else {
            glass
        }
    }

    @ViewBuilder private var glass: some View {
        if #available(iOS 26.0, *) {
            if frozen {
                shape.fill(tint).glassEffect(.identity, in: shape)
            } else {
                Color.clear.glassEffect(systemGlass, in: shape)
            }
        } else {
            water
        }
    }

    private var tint: Color {
        kind == .deep ? NibColor.deepBody : (kind == .tinted ? NibColor.accent : NibColor.clearBody)
    }

    @available(iOS 26.0, *)
    private var systemGlass: Glass {
        switch kind {
        case .clear, .bead: return Glass.regular.interactive(interactive)
        case .deep: return Glass.regular.tint(NibColor.deepGlassTint)
        case .tinted: return Glass.regular.tint(NibColor.accent).interactive(interactive)
        }
    }

    /// iOS 17–25: body tint (plus frost for Deep, not while inking) and the rim shader. No backdrop refraction.
    /// A lone surface has no page behind it to lens, so it gets the rim and outline only; Tinted gets its 30 % rim.
    private var water: some View {
        ZStack {
            if kind == .deep && !frozen {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(tint)
            NibWaterRimLayer(cornerRadius: shape.cornerRadius, rimOnly: true, tinted: kind == .tinted)
        }
        .nibElevation(.rest)
    }

    private var opaque: some View {
        shape.fill(kind == .deep ? NibColor.backgroundSecondary : (kind == .tinted ? NibColor.accent : NibColor.chromeOpaque))
            .overlay { shape.stroke(NibColor.waterLine, lineWidth: 0.8) }
            .nibElevation(.rest)
    }
}

/// The water optics of one shape, analytic (no field). `rimOnly` drops edge, caustic and specular (a lone surface,
/// a bead, a Tinted droplet); `tinted` uses the Tinted rim.
struct NibWaterRimLayer: View {
    let cornerRadius: CGFloat?
    var rimOnly = false
    var tinted = false

    var body: some View {
        GeometryReader { proxy in
            let r = cornerRadius ?? min(proxy.size.width, proxy.size.height) / 2
            Rectangle()
                .fill(Color.white)
                .padding(-1)                    // 1 pt outset so the anti-aliased edge is not cut
                .colorEffect(NibShaders.waterRim(cornerRadius: r, optics: rimOnly ? 0 : 1, tinted: tinted))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
