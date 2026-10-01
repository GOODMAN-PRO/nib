import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

// MARK: - Floating panels

/// Where a released floating panel comes to rest (DESIGN.md §10.3, §14.9): the landing point is projected from the
/// release velocity, the panel docks to the nearer side edge of its region and stays inside it vertically. Nothing
/// rests where it lands.
enum FloatingSnap {
    /// Release projection: `p + v · 0.12 s`.
    static let projection: CGFloat = 0.12

    static func rest(centre: CGPoint, velocity: CGVector = .zero, size: CGSize, in region: CGRect) -> CGPoint {
        let landing = CGPoint(x: centre.x + velocity.dx * projection, y: centre.y + velocity.dy * projection)
        let halfWidth = min(size.width, region.width) / 2
        let halfHeight = min(size.height, region.height) / 2
        let x = landing.x < region.midX ? region.minX + halfWidth : region.maxX - halfWidth
        let y = min(max(landing.y, region.minY + halfHeight), region.maxY - halfHeight)
        return CGPoint(x: x, y: y)
    }

    /// A newly opened panel: the trailing edge, top, cascaded 24 pt per panel already floating.
    static func initial(index: Int, size: CGSize, in region: CGRect) -> CGPoint {
        let y = region.minY + size.height / 2 + CGFloat(index) * NibSpacing.xxl
        return rest(centre: CGPoint(x: region.maxX, y: y), size: size, in: region)
    }
}

/// Every floating panel of the window, back to front. Each is a draggable Deep `floatingPanel` droplet that snaps to
/// an edge when released; tapping one brings it to the front.
struct FloatingPanelsView: View {
    let chrome: ChromeWindow
    @ObservedObject var state: ChromeState
    let region: CGRect
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(state.floating.enumerated()), id: \.element) { index, id in
                if let panel = chrome.app.ui.panels.get(id) {
                    FloatingPanelView(chrome: chrome, panel: panel, size: size, region: region,
                                      centre: centre(of: id, index: index), isFront: id == state.floating.last)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func centre(of id: String, index: Int) -> CGPoint {
        let stored = state.floatingCentres[id] ?? FloatingSnap.initial(index: index, size: size, in: region)
        return FloatingSnap.rest(centre: stored, size: size, in: region)
    }
}

struct FloatingPanelView: View {
    let chrome: ChromeWindow
    let panel: PanelDescriptor
    let size: CGSize
    let region: CGRect
    let centre: CGPoint
    let isFront: Bool
    /// Finger minus panel centre at pickup, so the panel lands where it was let go.
    @State private var grab: CGSize = .zero

    init(chrome: ChromeWindow, panel: PanelDescriptor, size: CGSize, region: CGRect, centre: CGPoint, isFront: Bool) {
        self.chrome = chrome
        self.panel = panel
        self.size = size
        self.region = region
        self.centre = centre
        self.isFront = isFront
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome.drawsHeader(panel) {
                NibPanelHeader(title: panel.title, symbol: NibSymbol(systemName: panel.icon) ?? .puzzle,
                               onClose: { chrome.closePanel(panel.id) }) {
                    PanelPlacementMenu(chrome: chrome, panel: panel, current: .floating)
                }
                Rectangle()
                    .fill(NibColor.separatorSoft)
                    .frame(height: NibStroke.hairline)
            }
            panel.makeView(chrome.panelContext(panel.id, presentation: .floating))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .droplet("chrome.floating." + panel.id, style: .floatingPanel, onDrag: { handle($0) })
        .simultaneousGesture(TapGesture().onEnded { bringToFront() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.title)
        .accessibilityAction(named: Text(String(localized: "Move to Left Edge"))) { dock(.left) }
        .accessibilityAction(named: Text(String(localized: "Move to Right Edge"))) { dock(.right) }
        .position(centre)
    }

    private func handle(_ event: NibDropletDrag) {
        switch event {
        case .began(let location):
            grab = CGSize(width: location.x - centre.x, height: location.y - centre.y)
        case .changed:
            break
        case .ended(let location, let velocity):
            let dropped = CGPoint(x: location.x - grab.width, y: location.y - grab.height)
            let rest = FloatingSnap.rest(centre: dropped, velocity: velocity, size: size, in: region)
            // The height it was let go at stays with the view; the edge (and bringing it to the front) is panel.open.
            chrome.state.floatingCentres[panel.id] = rest
            dock(rest.x < region.midX ? .left : .right)
        }
    }

    /// Through `panel.open`, so the AI, plugins and the bridge can dock a floating panel the same way. The panel keeps
    /// the params it was opened with.
    private func dock(_ edge: SidebarSide) {
        chrome.run(CommandIDs.panelOpen, ["id": .string(panel.id), "edge": .string(edge.rawValue)])
    }

    private func bringToFront() {
        if !isFront { chrome.run(CommandIDs.panelOpen, ["id": .string(panel.id)]) }
    }
}

/// A floating panel in a compact window: a sheet at the medium and large detents (DESIGN.md §14.9, §14.10).
struct PanelSheetView: View {
    let chrome: ChromeWindow
    let panel: PanelDescriptor

    var body: some View {
        VStack(spacing: 0) {
            if chrome.drawsHeader(panel) {
                NibPanelHeader(title: panel.title, symbol: NibSymbol(systemName: panel.icon) ?? .puzzle,
                               onClose: { chrome.closePanel(panel.id) })
                Rectangle()
                    .fill(NibColor.separatorSoft)
                    .frame(height: NibStroke.hairline)
            }
            panel.makeView(chrome.panelContext(panel.id, presentation: .sheet))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Chrome overlays (contracts-v2 G12)

/// Where chrome overlays rest. Pure, so it is unit-tested. Each placement stacks its overlays away from its edge in
/// z-order (the lowest `order` nearest the edge), 16 pt apart (the resting gap, DESIGN.md §10.4): top ones hang
/// below the bars, bottom ones stand on the region's bottom edge, leading, trailing and centre ones are centred
/// vertically. An anchored overlay sits below its anchor, above it when there is no room below, clamped inside the
/// region either way.
enum ChromeOverlayGeometry {
    struct Item: Equatable {
        var id: String
        var placement: ChromePlacement
        var size: CGSize
        /// `.anchored` only: the anchor in container coordinates.
        var anchor: CGRect?
    }

    static func frames(_ items: [Item], in region: CGRect, gap: CGFloat = NibMetrics.minimumRestingGap,
                       anchorGap: CGFloat = NibMetrics.popoverGap) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        var stacks: [ChromePlacement: [(id: String, size: CGSize)]] = [:]
        for item in items {
            let size = CGSize(width: max(0, min(item.size.width, region.width)),
                              height: max(0, min(item.size.height, region.height)))
            if item.placement == .anchored {
                if let anchor = item.anchor {
                    frames[item.id] = anchored(size, beside: anchor, gap: anchorGap, in: region)
                }
            } else {
                stacks[item.placement, default: []].append((item.id, size))
            }
        }
        for (placement, stack) in stacks {
            switch placement {
            case .topLeading, .top, .topTrailing:
                var y = region.minY
                for entry in stack {
                    frames[entry.id] = CGRect(origin: CGPoint(x: x(placement, width: entry.size.width, in: region), y: y),
                                              size: entry.size)
                    y += entry.size.height + gap
                }
            case .bottomLeading, .bottom, .bottomTrailing:
                var y = region.maxY
                for entry in stack {
                    y -= entry.size.height
                    frames[entry.id] = CGRect(origin: CGPoint(x: x(placement, width: entry.size.width, in: region), y: y),
                                              size: entry.size)
                    y -= gap
                }
            case .leading, .trailing, .center:
                let total = stack.reduce(CGFloat(0)) { $0 + $1.size.height } + gap * CGFloat(max(0, stack.count - 1))
                var y = max(region.minY, region.midY - total / 2)
                for entry in stack {
                    frames[entry.id] = CGRect(origin: CGPoint(x: x(placement, width: entry.size.width, in: region), y: y),
                                              size: entry.size)
                    y += entry.size.height + gap
                }
            case .anchored:
                break
            }
        }
        return frames
    }

    private static func x(_ placement: ChromePlacement, width: CGFloat, in region: CGRect) -> CGFloat {
        switch placement {
        case .topLeading, .leading, .bottomLeading: return region.minX
        case .topTrailing, .trailing, .bottomTrailing: return region.maxX - width
        case .top, .center, .bottom, .anchored: return region.midX - width / 2
        }
    }

    static func anchored(_ size: CGSize, beside anchor: CGRect, gap: CGFloat, in region: CGRect) -> CGRect {
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - size.height
        let y: CGFloat
        if below + size.height <= region.maxY {
            y = below
        } else if above >= region.minY {
            y = above
        } else {
            y = min(max(below, region.minY), max(region.minY, region.maxY - size.height))
        }
        let x = min(max(anchor.midX - size.width / 2, region.minX), max(region.minX, region.maxX - size.width))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// How an overlay arrives: it slides 16 pt in from its edge as it fades in (top ones out from under the bars, bottom
/// ones up from the bottom edge); centred and anchored ones only fade. Under Reduce Motion or Liquid Off every overlay
/// only fades (DESIGN.md §12). Leaving is a faster fade (§9.2).
enum ChromeOverlayMotion {
    static func slide(_ placement: ChromePlacement) -> CGSize {
        let distance = NibSpacing.l
        switch placement {
        case .topLeading, .top, .topTrailing: return CGSize(width: 0, height: -distance)
        case .bottomLeading, .bottom, .bottomTrailing: return CGSize(width: 0, height: distance)
        case .leading: return CGSize(width: -distance, height: 0)
        case .trailing: return CGSize(width: distance, height: 0)
        case .center, .anchored: return .zero
        }
    }

    static func transition(_ placement: ChromePlacement, reduced: Bool) -> AnyTransition {
        let slide = reduced ? .zero : self.slide(placement)
        let insertion: AnyTransition = slide == .zero ? .opacity : AnyTransition.offset(slide).combined(with: .opacity)
        return .asymmetric(insertion: insertion.animation(NibMotion.enter),
                           removal: AnyTransition.opacity.animation(NibMotion.exit))
    }
}

/// Which overlays recede while the Pencil is down (contracts-v2 `recedesWhileWriting`). A droplet overlay's water and
/// content recede together in the container (its frame joins the backdrop while the Pencil is down, see
/// `BackdropReader`); an overlay without a surface draws itself, so the chrome fades it.
enum ChromeOverlayRecede {
    /// The frames the container should recede (droplet overlays that recede while writing).
    static func backdropFrames(_ overlays: [ChromeOverlayDescriptor], frames: [String: CGRect]) -> [CGRect] {
        overlays.filter { $0.recedesWhileWriting && $0.surface != ChromeSurface.none }.compactMap { frames[$0.id] }
    }

    /// The opacity the chrome gives an overlay itself: 22 % for a surface-less overlay that recedes, while `receding`.
    static func opacity(_ overlay: ChromeOverlayDescriptor, receding: Bool) -> Double {
        receding && overlay.recedesWhileWriting && overlay.surface == ChromeSurface.none ? NibLiquid.recedeOpacity : 1
    }
}

/// Where the overlay layer last placed each overlay (container coordinates). The layout writes it while it places
/// the overlays, which updates no view; it is read when the Pencil goes down.
final class ChromeOverlayFrames {
    var frames: [String: CGRect] = [:]
}

/// The chrome overlays one window shows now (contracts-v2 `UIRegistries.visibleChromeOverlays`): registered overlays
/// for this document's kind whose `isVisible` holds, bottom-most first, with the anchors of anchored ones resolved in
/// the container's coordinates. Re-evaluated on registry changes, session changes (scrolling moves anchors) and
/// `UIRegistries.setNeedsChromeUpdate`, once per main-actor turn.
@MainActor
final class ChromeOverlayModel: ObservableObject {
    @Published private(set) var overlays: [ChromeOverlayDescriptor] = []
    @Published private(set) var anchors: [String: CGRect] = [:]
    let placed = ChromeOverlayFrames()
    /// The container's view, for window and page anchors (nil: window rects are used as they are).
    weak var containerView: UIView?
    private let chrome: ChromeWindow
    private(set) var kind: DocumentKind?
    private(set) var isCompact = false
    private var signature: [String] = []
    private var pending = false
    private var cancellables = Set<AnyCancellable>()

    init(chrome: ChromeWindow, kind: DocumentKind?) {
        self.chrome = chrome
        self.kind = kind
        observe()
        refresh()
    }

    static func dropletID(_ overlay: String) -> String { "chrome.overlay." + overlay }

    /// What overlays are asked about this window.
    var context: ChromeContext {
        ChromeContext(app: chrome.app, session: chrome.session, navigator: chrome.navigator, kind: kind,
                      isCompact: isCompact)
    }

    func update(kind: DocumentKind) {
        guard kind != self.kind else { return }
        self.kind = kind
        refresh()
    }

    func update(isCompact: Bool) {
        guard isCompact != self.isCompact else { return }
        self.isCompact = isCompact
        refresh()
    }

    func refresh() {
        pending = false
        let context = self.context
        var visible: [ChromeOverlayDescriptor] = []
        var anchors: [String: CGRect] = [:]
        for overlay in chrome.app.ui.visibleChromeOverlays(context) {
            if overlay.placement == .anchored {
                // An anchored overlay with nothing to point at is hidden.
                guard let anchor = overlay.anchor?(context), let rect = containerRect(anchor) else { continue }
                anchors[overlay.id] = rect
            }
            visible.append(overlay)
        }
        // A replaced descriptor keeps its id: the registry's generation tells it apart.
        let signature = visible.map { $0.id } + ["#\(chrome.app.ui.chromeOverlays.generation)"]
        if signature != self.signature {
            self.signature = signature
            overlays = visible
        }
        if anchors != self.anchors { self.anchors = anchors }
    }

    /// Coalesces bursts (a scroll tick changes the session several times) into one refresh on the next main-actor
    /// turn, after the changes have landed (@Published announces before it stores).
    func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            guard let self, self.pending else { return }
            self.refresh()
        }
    }

    /// A `ChromeAnchor` in the container's coordinates: a page rect through the canvas (following scroll and zoom), a
    /// window rect converted from the window. nil while the page is not laid out.
    func containerRect(_ anchor: ChromeAnchor) -> CGRect? {
        switch anchor {
        case .window(let rect):
            guard let view = containerView, view.window != nil else { return rect }
            return view.convert(rect, from: nil)
        case .page(let page, let rect):
            guard let host = chrome.session.editor?.canvasHost, let transform = host.pageTransform(page) else { return nil }
            let inCanvas = rect.cg.applying(transform)
            guard let view = containerView else { return inCanvas }
            return host.canvasView.convert(inCanvas, to: view)
        }
    }

    /// The frames the container recedes while the Pencil is down.
    var recedingFrames: [CGRect] { ChromeOverlayRecede.backdropFrames(overlays, frames: placed.frames) }

    private func observe() {
        let sessionID = chrome.session.id.raw
        let center = NotificationCenter.default
        center.publisher(for: .nibRegistryDidChange)
            .merge(with: center.publisher(for: .nibChromeNeedsUpdate)
                .filter { note in (note.userInfo?["session"] as? String).map { $0 == sessionID } ?? true })
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        chrome.session.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }
}

/// Places the overlays of `ChromeOverlayLayer` (sizes first, then `ChromeOverlayGeometry`).
struct ChromeOverlayStack: Layout {
    let region: CGRect
    let placed: ChromeOverlayFrames

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Readable width at most the region's; natural height.
        let offer = ProposedViewSize(width: region.width, height: nil)
        let items = subviews.map { subview -> ChromeOverlayGeometry.Item in
            let slot = subview[ChromeOverlaySlot.self]
            return ChromeOverlayGeometry.Item(id: slot.id, placement: slot.placement, size: subview.sizeThatFits(offer),
                                              anchor: slot.anchor)
        }
        let frames = ChromeOverlayGeometry.frames(items, in: region)
        placed.frames = frames
        for (item, subview) in zip(items, subviews) {
            let frame = frames[item.id] ?? CGRect(x: region.midX, y: region.midY, width: 0, height: 0)
            subview.place(at: CGPoint(x: bounds.minX + frame.midX, y: bounds.minY + frame.midY), anchor: .center,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

struct ChromeOverlaySlot: LayoutValueKey {
    struct Value: Equatable {
        var id: String
        var placement: ChromePlacement
        var anchor: CGRect?
    }

    static let defaultValue = Value(id: "", placement: .center, anchor: nil)
}

/// Every visible chrome overlay of the window, in z-order, inside the droplet container.
struct ChromeOverlayLayer: View {
    @ObservedObject var model: ChromeOverlayModel
    let inking: ChromeInkingMirror
    let region: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nibLiquidMode) private var liquidMode

    init(model: ChromeOverlayModel, inking: ChromeInkingMirror, region: CGRect) {
        _model = ObservedObject(wrappedValue: model)
        self.inking = inking
        self.region = region
    }

    var body: some View {
        let context = model.context
        let reduced = reduceMotion || liquidMode == .off
        ChromeOverlayStack(region: region, placed: model.placed) {
            ForEach(model.overlays, id: \.id) { overlay in
                ChromeOverlaySurface(overlay: overlay, context: context, inking: inking)
                    .layoutValue(key: ChromeOverlaySlot.self,
                                 value: ChromeOverlaySlot.Value(id: overlay.id, placement: overlay.placement,
                                                                anchor: model.anchors[overlay.id]))
                    .transition(ChromeOverlayMotion.transition(overlay.placement, reduced: reduced))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(NibMotion.enter, value: model.overlays.map { $0.id })
    }
}

/// One overlay on the NibDesign surface its descriptor asks for (contracts-v2 `ChromeSurface`): Clear HUD, bar or
/// pill droplets (40 or 44 pt tall, type capped like all chrome), a Deep panel or popover, or the view as it is.
struct ChromeOverlaySurface: View {
    let overlay: ChromeOverlayDescriptor
    let context: ChromeContext
    let inking: ChromeInkingMirror

    var body: some View {
        surface(overlay.makeView(context))
            .allowsHitTesting(overlay.isInteractive)
    }

    @ViewBuilder
    private func surface(_ content: AnyView) -> some View {
        let id = ChromeOverlayModel.dropletID(overlay.id)
        switch overlay.surface {
        case .hud, .pill:
            content
                .frame(minHeight: NibMetrics.hudHeight)
                .nibChromeTypeCap()
                .droplet(id, style: .hud)
        case .bar:
            content
                .frame(minHeight: NibMetrics.barHeight)
                .nibChromeTypeCap()
                .droplet(id, style: .bar)
        case .panel:
            content.droplet(id, style: .panel)
        case .popover:
            // Not a bud: an overlay stays while its feature shows it, and an open bud would keep every touch from the
            // canvas (budded popovers go through the window's floating host).
            content.droplet(id, style: .popover)
        case .none:
            content.modifier(ChromeHostRecede(inking: inking, overlay: overlay))
        }
    }
}

/// Fades a surface-less overlay with the chrome while the Pencil is down: 22 % in 100 ms, back 450 ms after it lifts
/// (DESIGN.md §10.8). Only this modifier observes the Pencil, never the overlay's own view.
struct ChromeHostRecede: ViewModifier {
    @ObservedObject var inking: ChromeInkingMirror
    let overlay: ChromeOverlayDescriptor

    func body(content: Content) -> some View {
        let opacity = ChromeOverlayRecede.opacity(overlay, receding: inking.recedes)
        content
            .opacity(opacity)
            .animation(opacity < 1 ? NibMotion.recede : NibMotion.enter, value: opacity)
    }
}

// MARK: - The window's floating host

/// The window's floating host (contracts-v2 `FloatingHosting`, published as `EditorSession.floatingHost` and so
/// `SceneNavigator.floatingHost` and `ChromeContext.floatingHost`): NibDesign's `NibFloatingHost`, rendered by the
/// `NibFloatingLayer` at the top of the chrome's droplet container, so the popovers, HUDs and toasts that UIKit code
/// and canvas attachments show merge, bud and recede with the chrome.
@MainActor
final class ChromeFloatingHost: FloatingHosting {
    let host = NibFloatingHost()

    func present(_ id: String, content: AnyView) {
        host.present(id) { content }
    }

    func dismiss(_ id: String) {
        host.dismiss(id)
    }

    func isPresenting(_ id: String) -> Bool {
        host.isPresenting(id)
    }

    @discardableResult
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        host.setAnchor(id, rect: rect, in: view)
    }

    func removeAnchor(_ id: String) {
        host.removeAnchor(id)
    }

    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? {
        host.containerRect(rect, from: view)
    }

    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {
        var button: NibAction?
        if let actionTitle, let action {
            button = NibAction(actionTitle) { action() }
        }
        host.post(NibToastItem(message, action: button))
    }
}
