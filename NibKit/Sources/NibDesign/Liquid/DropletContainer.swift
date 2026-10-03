import SwiftUI
import NibContracts

/// The one container per window for everything that floats. iOS 26+: the system's Liquid Glass inside a
/// `GlassEffectContainer` (union and morph are the OS's; Nib adds necks with memory, buds and physics).
/// iOS 17–25: a metaball field per cluster of nearby droplets (Canvas blur, thresholded and shaded in Metal) with
/// frost under Deep droplets.
///
/// The container does not cap Dynamic Type: panels, the assistant, search results and plugin panels scale to AX5.
/// Bars, HUDs, the palette and the proposal chip cap themselves (`nibChromeTypeCap`).
public struct NibDropletContainer<Content: View>: View {
    @State private var field = DropletField()
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.nibLiquidMode) private var mode
    @Environment(\.nibBackdrop) private var backdrop
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    private let inking: NibInkingState?
    private let content: Content

    /// `inking` is the Pencil state the canvas delegate writes; this container is its only reader.
    public init(inking: NibInkingState? = nil, @ViewBuilder content: () -> Content) {
        self.inking = inking
        self.content = content()
    }

    private static var systemGlassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private var usesSystemGlass: Bool { Self.systemGlassAvailable && mode != .off }

    public var body: some View {
        containerBody
            .onAppear { isVisible = true; field.setActive(scenePhase == .active) }
            .onDisappear { isVisible = false; field.setActive(false) }
            .onChange(of: scenePhase) { _, phase in field.setActive(isVisible && phase == .active) }
    }

    private var containerBody: some View {
        ZStack {
            if field.hasOpenBud {
                DismissCatcher(field: field)
            }
            layers
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(NibLiquid.space)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { field.updateBounds(proxy.size) }
                    .onChange(of: proxy.size) { _, size in field.updateBounds(size) }
            }
        }
        .transaction { if NibUITestMode.isEnabled { $0.disablesAnimations = true; $0.animation = nil } }
        .environment(field)
        .environment(\.nibGlassNamespace, glassNamespace)
        .environment(\.nibIsInking, field.isFrozen)
        .environment(\.nibChromeAppearance, NibChromeAppearance(environment))
        .onChange(of: reduceMotion, initial: true) { _, value in field.reduceMotion = value || NibUITestMode.isEnabled; field.wake() }
        .onChange(of: mode, initial: true) { _, value in
            field.mode = value
            field.usesSystemGlass = Self.systemGlassAvailable && value != .off
            NibHaptics.isEnabled = value != .off
            NibMotion.forcesReduced = value == .off
        }
        .onChange(of: inking?.isInking ?? false, initial: true) { _, value in field.setInking(value) }
        .onChange(of: inking?.strokeBounds ?? .null) { _, rect in field.setStroke(rect) }
        .onChange(of: colorScheme) { _, _ in field.wake() }
        .onChange(of: backdrop, initial: true) { _, pages in field.setBackdrop(pages) }
        .onChange(of: sizeClass, initial: true) { _, value in
            field.metrics = value == .compact ? .compact : .regular
        }
    }

    @ViewBuilder private var layers: some View {
        if #available(iOS 26.0, *) {
            if usesSystemGlass {
                ZStack {
                    GlassEffectContainer(spacing: field.metrics.mergeDistance) {
                        ZStack {
                            NeckGlassLayer(field: field)
                            content
                        }
                    }
                    .environment(\.colorScheme, colorScheme)
                    .backgroundPreferenceValue(NibGlassBackdropKey.self) { backdrops in
                        NativeGlassBackdropLayer(backdrops: backdrops)
                            .environment(\.nibChromeAppearance, NibChromeAppearance(environment))
                            .environment(\.colorScheme, colorScheme)
                    }
                    .transformPreference(NibGlassBackdropKey.self) { $0 = [] }
                }
            } else {
                fallback
            }
        } else {
            fallback
        }
    }

    @ViewBuilder private var fallback: some View {
        ZStack {
            if reduceTransparency || mode == .off || field.isThermallyThrottled {
                WaterOpaqueLayer(field: field)
            } else {
                FrostLayer(field: field)
                WaterLayer(field: field)
            }
            content
        }
    }
}

/// The actual native host bounds, captured before its outer translation and reciprocal padding. Resolving
/// this anchor outside GlassEffectContainer includes layout, safe-area placement and presentation transforms.
/// Never reconstruct a second silhouette from the physics field: that path uses the fallback affine geometry.
struct NibGlassBackdrop {
    let bounds: Anchor<CGRect>
    let shape: NibDropletShape
    let kind: NibGlass
    var frozen = false
    var recedes = false
}

struct NibGlassBackdropKey: PreferenceKey {
    static let defaultValue: [NibGlassBackdrop] = []
    static func reduce(value: inout [NibGlassBackdrop], nextValue: () -> [NibGlassBackdrop]) {
        value += nextValue()
    }
}

/// Shared by both static nibGlass and physics droplets. Only the container paints this body, below the native
/// effect. The anchor must be attached at the glass boundary, not at the restored rest-layout boundary.
struct NibGlassBackdropModifier: ViewModifier {
    let kind: NibGlass
    let shape: NibDropletShape
    var frozen = false
    var recedes = false

    func body(content: Content) -> some View {
        content.anchorPreference(key: NibGlassBackdropKey.self, value: .bounds) {
            [NibGlassBackdrop(bounds: $0, shape: shape, kind: kind, frozen: frozen, recedes: recedes)]
        }
    }
}

/// One neutral underlay per native host, with no stroke, shader, sheen or shadow. Both its material and its
/// foreground resolve from the container's captured app appearance, even when glass adapts to white paper.
struct NativeGlassBackdropLayer: View {
    let backdrops: [NibGlassBackdrop]
    @Environment(\.self) private var environment
    @Environment(\.nibBackdrop) private var paper

    var body: some View {
        let appearance = environment.nibChromeAppearance ?? NibChromeAppearance(environment)
        GeometryReader { proxy in
            let origin = proxy.frame(in: NibLiquid.space).origin
            ForEach(Array(backdrops.enumerated()), id: \.offset) { _, backdrop in
                let rect = proxy[backdrop.bounds]
                if NibGeometry.isUsable(rect) {
                    let worldRect = rect.offsetBy(dx: origin.x, dy: origin.y)
                    let share = DropletField.paperShare(worldRect, in: paper)
                    let tint = backdrop.frozen
                        ? NibGlassBodyTint.color(backdrop.kind, paperShare: share, colorScheme: appearance.colorScheme)
                        : NibGlassBodyTint.systemUnderlay(backdrop.kind, colorScheme: appearance.colorScheme, paperShare: share)
                    backdrop.shape.fill(tint)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(backdrop.recedes ? NibLiquid.recedeOpacity : 1)
                        .animation(backdrop.recedes ? NibMotion.recede : NibMotion.enter, value: backdrop.recedes)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// While a bud is open, a touch anywhere outside the droplets only dismisses it. It never reaches the canvas, not
/// even from the status-bar or home-indicator strips.
struct DismissCatcher: View {
    let field: DropletField

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { _ in field.dismissBuds() })
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Places every cluster's canvas at its own frame; the canvases are Equatable, so a cluster at rest never redraws.
struct ClusterLayer<Cell: View>: View {
    let field: DropletField
    let cell: (WaterCluster) -> Cell

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(field.clusters.filter { NibGeometry.isUsable($0.frame) }) { c in
                cell(c)
                    .frame(width: c.frame.width, height: c.frame.height)
                    .offset(x: c.frame.minX, y: c.frame.minY)
                    .opacity(c.opacity)
                    .animation(field.isInking ? NibMotion.recede : NibMotion.enter, value: c.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// iOS 17–25: frost (material blur) under Deep droplets, inset 1.5 pt so it never pokes past the water outline.
/// Not drawn while the Pencil is down: nothing re-samples the canvas 120 times a second (DESIGN.md §10.8).
struct FrostLayer: View {
    let field: DropletField

    var body: some View {
        let frozen = field.isFrozen
        ClusterLayer(field: field) { c in
            Canvas { context, _ in
                let o = CGAffineTransform(translationX: -c.frame.minX, y: -c.frame.minY)
                for r in c.renders where r.budLine {
                    context.stroke(r.path.applying(o), with: .color(NibColor.waterLineBud), lineWidth: 0.8)
                }
            }
            .background(alignment: .topLeading) {
                if !frozen {
                    ForEach(c.renders.filter { $0.material == .deep }) { r in
                        r.frostPath
                            .applying(CGAffineTransform(translationX: -c.frame.minX, y: -c.frame.minY))
                            .fill(.ultraThinMaterial)
                            .opacity(r.frostOpacity)
                    }
                }
            }
        }
    }
}

/// iOS 17–25: each cluster's droplets and necks as one metaball field in a canvas framed to the cluster. The Canvas
/// blurs the silhouettes (σ 8 pt iPad / 6.5 pt iPhone); the Metal layer effect thresholds it with analytic
/// anti-aliasing and shades body, edge lens, sheen, outline, directional rim and the water's shadow (DESIGN.md §10.9).
/// Material kinds and the paper share travel in the colour channels.
struct WaterLayer: View {
    let field: DropletField

    var body: some View {
        let blur = field.metrics.fieldBlur
        let iso = field.metrics.iso
        ClusterLayer(field: field) { c in
            WaterClusterCanvas(cluster: c, blur: blur, iso: iso).equatable()
        }
    }
}

struct WaterClusterCanvas: View, Equatable {
    let cluster: WaterCluster
    let blur: CGFloat
    let iso: Float

    var body: some View {
        let o = CGAffineTransform(translationX: -cluster.frame.minX, y: -cluster.frame.minY)
        Canvas { context, _ in
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: blur))
                for r in cluster.renders {
                    layer.fill(r.path.applying(o), with: .color(DropletField.FieldColour.of(r.material, paper: r.paper).color))
                }
                for n in cluster.necks {
                    layer.stroke(n.path.applying(o), with: .color(n.colour.color),
                                 style: StrokeStyle(lineWidth: n.thickness, lineCap: .round))
                }
                for s in cluster.satellites {
                    layer.fill(s.path.applying(o), with: .color(DropletField.FieldColour.of(.clear, paper: 0).color))
                }
            }
        }
        .layerEffect(NibShaders.waterField(cluster, iso: iso), maxSampleOffset: CGSize(width: 6, height: 8))
    }
}

/// Reduce Transparency, Liquid Off and thermal throttling: one union path per cluster (`Path.union`, iOS 17), filled
/// once in `chromeOpaque` and stroked with the 0.8 pt water line. No blur, no threshold, no shader, no shadow: this
/// is the cheap path and it costs less than the one it replaces.
struct WaterOpaqueLayer: View {
    let field: DropletField

    var body: some View {
        ClusterLayer(field: field) { c in
            Canvas { context, _ in
                let o = CGAffineTransform(translationX: -c.frame.minX, y: -c.frame.minY)
                var union = Path()
                for r in c.renders { union = union.union(r.path.applying(o)) }
                for n in c.necks {
                    union = union.union(n.path.applying(o).strokedPath(StrokeStyle(lineWidth: n.thickness, lineCap: .round)))
                }
                for s in c.satellites { union = union.union(s.path.applying(o)) }
                context.fill(union, with: .color(NibColor.chromeOpaque))
                context.stroke(union, with: .color(NibColor.waterLine), lineWidth: 0.8)
                for r in c.renders where r.material != .clear {
                    context.fill(r.innerPath.applying(o),
                                 with: .color(r.material == .deep ? NibColor.backgroundSecondary : NibColor.accent))
                }
            }
        }
    }
}

/// iOS 26+: necks and satellites as glass capsules inside the GlassEffectContainer, so the system union gives the
/// bridge its memory (a neck thins and pinches instead of vanishing at the container spacing). While the Pencil is
/// down they are `.identity` over the plain body tint, like every droplet.
@available(iOS 26.0, *)
struct NeckGlassLayer: View {
    let field: DropletField

    var body: some View {
        let glass: Glass = field.isFrozen ? .identity : .regular
        ZStack(alignment: .topLeading) {
            ForEach(field.necks.filter { NibGeometry.isFinite($0.from) && NibGeometry.isFinite($0.to)
                && $0.length.isFinite && $0.thickness.isFinite && $0.thickness > 0 }) { n in
                Capsule()
                    .fill(field.isFrozen ? NibColor.clearBody : Color.clear)
                    .frame(width: max(n.length, 1), height: n.thickness)
                    .glassEffect(glass, in: Capsule())
                    .rotationEffect(.radians(Double(n.angle)))
                    .position(n.midpoint)
            }
            ForEach(field.satellites.filter { NibGeometry.isFinite($0.centre.value) && $0.radius.value.isFinite }) { s in
                Circle()
                    .fill(field.isFrozen ? NibColor.clearBody : Color.clear)
                    .frame(width: max(0, s.radius.value * 2), height: max(0, s.radius.value * 2))
                    .glassEffect(glass, in: Circle())
                    .position(s.centre.value)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
