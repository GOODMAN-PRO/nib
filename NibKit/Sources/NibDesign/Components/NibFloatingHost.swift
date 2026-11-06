import SwiftUI
import UIKit
import Observation

/// Lets code outside the window's droplet container put droplets into it (DESIGN.md §1: "Everything floating in a
/// screen lives in that window's one droplet container"): a canvas attachment's popover budded from a point on the
/// page (a comment thread, spelling suggestions, the lasso object menu), a UIKit text editor's formatting popover, a
/// HUD (ruler angle, presenter, recording, Time Keeper), the Zoom Window's `frame` droplet, and toasts.
///
/// The container's owner (the document chrome, the library) makes one per window, places `NibFloatingLayer(host:)` as
/// a full-size child of its `NibDropletContainer`, presents `host.toast` with `.nibToast`, and hands the host to
/// features. Everything presented through it merges, stretches, buds and recedes while the Pencil is down like the
/// chrome itself, because it is in the same container.
@MainActor
@Observable
public final class NibFloatingHost {
    struct Entry: Identifiable {
        let id: String
        let content: AnyView
    }

    private(set) var entries: [Entry] = []
    private(set) var anchors: [String: CGRect] = [:]
    /// The toast to show; the owner binds it with `.nibToast(host.toastBinding)`.
    public var toast: NibToastItem?
    /// The layer's own view and its origin in the container, for converting UIKit rects.
    @ObservationIgnored weak var referenceView: UIView?
    @ObservationIgnored var layerOrigin: CGPoint = .zero
    #if DEBUG
    @ObservationIgnored private var searchLayoutLogCount = 0
    func noteSearchLayout<T>(_ name: String, old: T, new: T) {
        guard searchLayoutLogCount < 40 else { return }
        searchLayoutLogCount += 1
        let message = "[Nib QA search layout] floating \(name) #\(searchLayoutLogCount) old=\(old) new=\(new)"
        NSLog("%@", message)
    }
    #endif

    public init() {}

    /// Shows `content`, or replaces what `id` showed. The content is laid out over the whole container, in its
    /// coordinates: use a component that places itself (`NibBudPopover(source:)`, `NibTether`) or `.position`.
    public func present<Content: View>(_ id: String, @ViewBuilder content: () -> Content) {
        let entry = Entry(id: id, content: AnyView(content()))
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    public func dismiss(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    public func isPresenting(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// The ids shown, oldest first (later ones draw above earlier ones).
    public var presentedIDs: [String] { entries.map(\.id) }

    /// A bud source at `rect` in container coordinates (`NibLiquid.space`), so `NibBudPopover(source: id)` can grow
    /// out of a point on the page or a UIKit control.
    public func setAnchor(_ id: String, rect: CGRect) {
        #if DEBUG
        if anchors[id] != rect { noteSearchLayout("anchor \(id)", old: anchors[id], new: Optional(rect)) }
        #endif
        if anchors[id] != rect { anchors[id] = rect }
    }

    /// The same with `rect` in `view`'s coordinates (a canvas view, a text view). False while the layer is not in the
    /// same window yet: nothing to convert against.
    @discardableResult
    public func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        guard let converted = containerRect(rect, from: view) else { return false }
        setAnchor(id, rect: converted)
        return true
    }

    public func removeAnchor(_ id: String) {
        anchors[id] = nil
    }

    /// `rect` from `view`'s coordinates into the container's, for placing content with `.position`. Nil while the
    /// layer is not on screen in `view`'s window.
    public func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? {
        guard let reference = referenceView, let window = reference.window, view.window === window else { return nil }
        return view.convert(rect, to: reference).offsetBy(dx: layerOrigin.x, dy: layerOrigin.y)
    }

    /// Shows a toast (replacing the one showing), as `.nibToast` presents it.
    public func post(_ toast: NibToastItem) {
        self.toast = toast
    }

    /// The binding the container's owner passes to `.nibToast(_:)`.
    public var toastBinding: Binding<NibToastItem?> {
        Binding(get: { self.toast }, set: { self.toast = $0 })
    }
}

/// Renders a `NibFloatingHost`: a full-size child of the `NibDropletContainer`, above the chrome it should float over.
/// It takes no touches itself; only what it shows does.
public struct NibFloatingLayer: View {
    let host: NibFloatingHost
    @Environment(DropletField.self) private var field: DropletField?

    public init(host: NibFloatingHost) {
        self.host = host
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            FloatingReference(host: host)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ForEach(host.entries) { entry in
                entry.content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        let origin = proxy.frame(in: NibLiquid.space).origin
                        #if DEBUG
                        host.noteSearchLayout("origin", old: host.layerOrigin, new: origin)
                        #endif
                        if NibGeometry.isFinite(origin) { host.layerOrigin = origin }
                    }
                    .onChange(of: proxy.frame(in: NibLiquid.space).origin) { _, origin in
                        #if DEBUG
                        host.noteSearchLayout("origin", old: host.layerOrigin, new: origin)
                        #endif
                        if NibGeometry.isFinite(origin) { host.layerOrigin = origin }
                    }
            }
        }
        .onChange(of: host.anchors, initial: true) { _, anchors in
            #if DEBUG
            host.noteSearchLayout("field anchors", old: field?.worldAnchors, new: Optional(anchors))
            #endif
            for (id, rect) in anchors { field?.setWorldAnchor(id, rect) }
        }
    }
}

/// A plain view the size of the layer, the reference UIKit rects are converted through.
struct FloatingReference: UIViewRepresentable {
    let host: NibFloatingHost
    #if DEBUG
    @Environment(DropletField.self) private var field: DropletField?
    #endif

    func makeUIView(context: Context) -> UIView {
        let view = CoordinateReferenceView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        #if DEBUG
        view.host = host
        view.field = field
        NibFloatingHitDiagnostics.registerReference(view)
        host.noteSearchLayout("reference", old: host.referenceView.map { ObjectIdentifier($0) }, new: Optional(ObjectIdentifier(view)))
        #endif
        host.referenceView = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.isUserInteractionEnabled = false
        #if DEBUG
        if let reference = view as? CoordinateReferenceView {
            reference.host = host
            reference.field = field
        }
        if host.referenceView !== view {
            host.noteSearchLayout("reference", old: host.referenceView.map { ObjectIdentifier($0) }, new: Optional(ObjectIdentifier(view)))
        }
        #endif
        if host.referenceView !== view { host.referenceView = view }
    }
}

/// This full-window view measures coordinates; it is never an input surface.
/// Native hosting can restore interaction flags when reattaching representables,
/// so enforce pass-through at UIKit's hit-test boundary as well as in SwiftUI.
private final class CoordinateReferenceView: UIView {
    #if DEBUG
    weak var host: NibFloatingHost?
    weak var field: DropletField?
    #endif
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

#if DEBUG
/// Observes native hit testing without creating a second input region. In particular, the
/// coordinate reference above is deliberately NOT a cached rectangle that admits touches.
@MainActor
public enum NibFloatingHitDiagnostics {
    private static let references = NSHashTable<UIView>.weakObjects()
    private static let surfaces = NSHashTable<UIView>.weakObjects()
    private static var probing = false

    fileprivate static func registerReference(_ view: UIView) { references.add(view) }
    fileprivate static func registerSurface(_ view: UIView) { surfaces.add(view) }

    /// Place inside the surface's scrolling content to observe its actual UIKit viewport.
    public static func surface(_ id: String) -> some View {
        FloatingSurfaceProbe(id: id).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// Called from a canvas hit-test diagnostic, which can itself be reached by window.hitTest.
    /// The re-entry guard is essential: the diagnostic must never recurse into another probe.
    public static func contactDetails(at point: CGPoint, in view: UIView?, event: UIEvent?) -> String {
        guard let view, let window = view.window else { return " windowPoint=nil windowHit=nil (no-window)" }
        let location = view.convert(point, to: window)
        guard !probing else { return " windowPoint=\(location) windowHit=probe-in-progress" }
        probing = true
        defer { probing = false }
        let hit = window.hitTest(location, with: event)
        let hitClass = hit.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        for case let surface as FloatingSurfaceProbe.Probe in surfaces.allObjects where surface.window === window {
            for case let reference as CoordinateReferenceView in references.allObjects where reference.window === window {
                guard let host = reference.host, host.isPresenting(surface.id),
                      let field = reference.field, field === surface.field,
                      let frame = field.visualFrame(surface.id) else { continue }
                let presentation = field.node(surface.id).presentation
                guard presentation.isDrawn, !presentation.hidden else { continue }
                let visibleFrame = reference.convert(frame.offsetBy(dx: -host.layerOrigin.x, dy: -host.layerOrigin.y), to: window)
                let scroll = surface.scrollView
                let scrollFrame = scroll.map { $0.convert($0.bounds, to: window) } ?? .null
                let claimedByScroll = scroll.map { hit?.isDescendant(of: $0) == true } ?? false
                guard visibleFrame.contains(location), !claimedByScroll else { continue }
                let contentFrame = surface.convert(surface.bounds, to: window)
                let geometry = "visibleFrame=\(visibleFrame) scrollFrame=\(scrollFrame) contentFrame=\(contentFrame)"
                // Chrome outside the scroller may legitimately own the hit; this is not proof of fall-through.
                let input = "claimedByScroll=\(claimedByScroll) scrollEnabled=\(scroll?.isUserInteractionEnabled ?? false) windowHit=\(hitClass)"
                let ancestors = surface.ancestorFrames(in: window, at: location)
                NSLog("%@", "[Nib QA format] floating scroll-claim id=\(surface.id) windowPoint=\(location) \(geometry) \(input) ancestors=\(ancestors)")
            }
        }
        let touchPoint = event?.allTouches?.first?.location(in: window)
        return " windowPoint=\(location) windowHit=\(hitClass) firstTouchWindowPoint=\(String(describing: touchPoint))"
    }
}

private struct FloatingSurfaceProbe: UIViewRepresentable {
    let id: String
    @Environment(DropletField.self) private var field: DropletField?

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.id = id
        view.field = field
        NibFloatingHitDiagnostics.registerSurface(view)
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.isUserInteractionEnabled = false
        view.id = id
        view.field = field
    }

    final class Probe: UIView {
        var id = ""
        weak var field: DropletField?
        var scrollView: UIScrollView? {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { return scroll }
                ancestor = view.superview
            }
            return nil
        }
        func ancestorFrames(in window: UIWindow, at point: CGPoint) -> String {
            var frames: [String] = []
            var ancestor = superview
            while let view = ancestor, frames.count < 32 {
                let frame = view.convert(view.bounds, to: window)
                let contains = view.bounds.contains(view.convert(point, from: window))
                let flags = "contains=\(contains) enabled=\(view.isUserInteractionEnabled) hidden=\(view.isHidden)"
                frames.append("\(NSStringFromClass(type(of: view))) frame=\(frame) \(flags)")
                ancestor = view.superview
            }
            return frames.joined(separator: "; ")
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
}
#endif
