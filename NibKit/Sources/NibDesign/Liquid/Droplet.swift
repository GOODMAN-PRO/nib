import SwiftUI
import QuartzCore

public extension View {
    /// Makes this view a droplet of the enclosing `NibDropletContainer`: water body, velocity stretch, surface-tension
    /// settle, merge and pinch with neighbours, FLIP when its layout changes. Outside a container it is a static glass.
    /// - Parameters:
    ///   - id: unique within the container.
    ///   - dragScale: 0.5 while a library card is over the sidebar (C's condense), otherwise 1.
    ///   - bondsWith: for `bondsOnRequest` styles (library cards), the droplet a neck should reach: the library passes
    ///     the target cover once a combine has armed (DESIGN.md §10.12), nil otherwise.
    ///   - onDrag: drag events in `NibLiquid.space`, for features that need drop targets.
    func droplet(_ id: String, style: DropletStyle = .bar, dragScale: CGFloat = 1, bondsWith: String? = nil,
                 onDrag: ((NibDropletDrag) -> Void)? = nil) -> some View {
        modifier(DropletModifier(id: id, style: style, managesDrag: true, dragScale: dragScale, bondsWith: bondsWith,
                                 onDrag: onDrag))
    }

    /// Presents this droplet by budding it off `sourceID` (a droplet id or a `nibBudAnchor`): it grows out of the
    /// source, its neck pinches, the content is revealed through the droplet. Closing retracts it into the source.
    /// `instant` is for keyboard invocations: nothing that the keyboard triggers animates.
    func budsFrom(_ sourceID: String, isPresented: Binding<Bool>, instant: Bool = false) -> some View {
        environment(\.nibBud, NibBudRequest(source: sourceID, isPresented: isPresented, instant: instant))
    }

    /// Marks a control inside a droplet (for example a bar button) as a bud source.
    func nibBudAnchor(_ id: String) -> some View {
        background(BudAnchorReader(id: id))
    }
}

extension View {
    func droplet(_ id: String, style: DropletStyle, managesDrag: Bool) -> some View {
        modifier(DropletModifier(id: id, style: style, managesDrag: managesDrag, dragScale: 1, bondsWith: nil, onDrag: nil))
    }
}

struct DropletModifier: ViewModifier {
    let id: String
    let style: DropletStyle
    let managesDrag: Bool
    let dragScale: CGFloat
    let bondsWith: String?
    let onDrag: ((NibDropletDrag) -> Void)?
    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.nibGlassNamespace) private var namespace
    @Environment(\.nibBud) private var bud

    func body(content: Content) -> some View {
        if let field {
            AttachedDroplet(content: content, id: id, style: style, managesDrag: managesDrag, dragScale: dragScale,
                            bondsWith: bondsWith, onDrag: onDrag, field: field, node: field.node(id),
                            namespace: namespace, bud: bud)
        } else {
            content.nibGlass(style.glassKind, cornerRadius: style.cornerRadius)
        }
    }
}

/// One droplet in a container. It reads only its own node, so it re-renders only when its own presentation changes.
struct AttachedDroplet<Content: View>: View {
    let content: Content
    let id: String
    let style: DropletStyle
    let managesDrag: Bool
    let dragScale: CGFloat
    let bondsWith: String?
    let onDrag: ((NibDropletDrag) -> Void)?
    let field: DropletField
    let node: DropletNode
    let namespace: Namespace.ID?
    let bud: NibBudRequest?

    var body: some View {
        let p = node.presentation
        let requestedHidden = bud.map { !$0.isPresented.wrappedValue } ?? false
        let hidden = p.hasBud ? p.hidden : requestedHidden
        let isOpenBud = bud != nil && !hidden
        let draggable = managesDrag && style.drag != .fixed
        let recede = p.recedes ? NibLiquid.recedeOpacity : 1
        return content
            .environment(\.nibDropletIsLifted, p.isLifted)
            .opacity(p.revealed ? 1 : 0)
            .blur(radius: p.revealed ? 0 : 3)
            .scaleEffect(p.revealed || !field.reduceMotion ? 1 : 0.96)
            .animation(p.revealed ? NibMotion.enter : NibMotion.exit, value: p.revealed)
            .mask(alignment: .topLeading) {
                // C's rule, exactly: the clip is the body's own geometry (in the content's coordinates, so it rides
                // the transform below and lands on the body). Nothing draws outside the body, not even mid-bud.
                if let mask = p.bodyMask {
                    mask
                } else {
                    Rectangle().padding(-64)
                }
            }
            .opacity(p.contentOpacity * recede)
            .animation(p.recedes ? NibMotion.recede : NibMotion.enter, value: p.recedes)
            .transformEffect(p.contentTransform)
            .overlay {
                if !style.drawsBody && p.isDrawn {
                    FrameRim(style: style, presentation: p).opacity(recede)
                }
            }
            .background {
                SystemBody(id: id, style: style, presentation: p, namespace: namespace, field: field)
                    .opacity(recede)
            }
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            // An open bud is modal for VoiceOver: focus moves into it when its content is revealed, the canvas behind
            // it is not reachable, and a hardware Escape closes it (DESIGN.md §10.6).
            .accessibilityAddTraits(isOpenBud ? .isModal : [])
            .onChange(of: p.revealed && isOpenBud) { _, revealed in
                if revealed { AccessibilityNotification.ScreenChanged().post() }
            }
            .background {
                if isOpenBud {
                    // Registered only while presented: closed buds stay in the view tree, and their shortcuts
                    // would conflict.
                    Button("") { bud?.isPresented.wrappedValue = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .background(RestReader(id: id, style: style, field: field))
            .gesture(dragGesture, including: draggable ? .all : .subviews)
            .onAppear { field.register(id, style: style) }
            .onDisappear { field.unregister(id) }
            .onChange(of: dragScale, initial: true) { _, scale in field.setDragScale(id, scale) }
            .onChange(of: bondsWith, initial: true) { _, target in field.setBondTarget(id, target) }
            .onChange(of: bud?.isPresented.wrappedValue ?? false, initial: true) { _, presented in
                guard let bud else { return }
                field.setBud(id, source: bud.source, presented: presented, instant: bud.instant) {
                    bud.isPresented.wrappedValue = false
                }
            }
            .accessibilityAction(.escape) {
                if let bud { bud.isPresented.wrappedValue = false }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: DropletPhysics.pickupSlop, coordinateSpace: NibLiquid.space)
            .onChanged { value in
                if !field.isDragging(id) {
                    field.beginDrag(id, at: value.startLocation)
                    onDrag?(.began(location: value.startLocation))
                }
                field.drag(id, to: value.location)
                onDrag?(.changed(location: value.location))
            }
            .onEnded { value in
                let v = CGVector(dx: value.velocity.width, dy: value.velocity.height)
                let released = field.endDrag(id, velocity: v)
                onDrag?(.ended(location: value.location, velocity: released))
            }
    }
}

/// A `frame` droplet (the zoom-window target) has no body: rim and outline only, on both OS generations.
struct FrameRim: View {
    let style: DropletStyle
    let presentation: DropletPresentation

    var body: some View {
        let shape = NibDropletShape(cornerRadius: presentation.cornerRadius)
        ZStack {
            shape.stroke(NibColor.waterLine, lineWidth: 0.8)
            NibWaterRimLayer(cornerRadius: presentation.cornerRadius, rimOnly: true)
        }
        .frame(width: max(0, presentation.bodySize.width), height: max(0, presentation.bodySize.height))
        .offset(x: presentation.bodyOffset.x, y: presentation.bodyOffset.y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The droplet's body on iOS 26+: system glass sized and offset by the physics (axis-aligned stretch through the frame,
/// which the glass union definitely honours). On iOS 17–25 the container's field draws the body, so this is empty.
struct SystemBody: View {
    let id: String
    let style: DropletStyle
    let presentation: DropletPresentation
    let namespace: Namespace.ID?
    let field: DropletField

    var body: some View {
        if #available(iOS 26.0, *) {
            if field.usesSystemGlass && presentation.isDrawn && !presentation.hidden && style.drawsBody {
                GlassBody(id: id, style: style, presentation: presentation, namespace: namespace, frozen: field.isFrozen)
            }
        }
    }
}

@available(iOS 26.0, *)
struct GlassBody: View {
    let id: String
    let style: DropletStyle
    let presentation: DropletPresentation
    let namespace: Namespace.ID?
    /// While the Pencil is down the glass does not sample the backdrop: `.identity` over the plain body tint. At 22 %
    /// the swap is invisible, and nothing re-samples the canvas 120 times a second.
    let frozen: Bool

    var body: some View {
        let shape = NibDropletShape(cornerRadius: style.cornerRadius == nil ? nil : presentation.cornerRadius)
        shape
            .fill(frozen ? tint : Color.clear)
            .frame(width: max(0, presentation.bodySize.width), height: max(0, presentation.bodySize.height))
            .glassEffect(frozen ? .identity : style.systemGlass, in: shape)
            .modifier(GlassIDModifier(id: id, namespace: namespace))
            .overlay {
                if presentation.budLine {
                    shape.stroke(NibColor.waterLineBud, lineWidth: 0.8)
                }
            }
            .offset(x: presentation.bodyOffset.x, y: presentation.bodyOffset.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch style.material {
        case .clear: return NibColor.clearBody
        case .deep: return NibColor.deepBody
        case .tinted: return NibColor.accent
        }
    }
}

@available(iOS 26.0, *)
struct GlassIDModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

/// Reports the droplet's laid-out frame (not its rendered transform) to the field.
struct RestReader: View {
    let id: String
    let style: DropletStyle
    let field: DropletField

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { field.setRest(id, proxy.frame(in: NibLiquid.space), style: style) }
                .onChange(of: proxy.frame(in: NibLiquid.space)) { _, frame in field.setRest(id, frame, style: style) }
        }
    }
}

struct BudAnchorReader: View {
    let id: String
    @Environment(DropletField.self) private var field: DropletField?

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { field?.setWorldAnchor(id, proxy.frame(in: NibLiquid.space)) }
                .onChange(of: proxy.frame(in: NibLiquid.space)) { _, frame in field?.setWorldAnchor(id, frame) }
        }
    }
}
