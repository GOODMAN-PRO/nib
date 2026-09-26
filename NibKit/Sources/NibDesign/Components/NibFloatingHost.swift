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
                    .onAppear { host.layerOrigin = proxy.frame(in: NibLiquid.space).origin }
                    .onChange(of: proxy.frame(in: NibLiquid.space).origin) { _, origin in host.layerOrigin = origin }
            }
        }
        .onChange(of: host.anchors, initial: true) { _, anchors in
            for (id, rect) in anchors { field?.setWorldAnchor(id, rect) }
        }
    }
}

/// A plain view the size of the layer, the reference UIKit rects are converted through.
struct FloatingReference: UIViewRepresentable {
    let host: NibFloatingHost

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        host.referenceView = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if host.referenceView !== view { host.referenceView = view }
    }
}
