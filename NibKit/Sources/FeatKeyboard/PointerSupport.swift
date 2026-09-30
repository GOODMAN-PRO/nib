import UIKit
import os
import NibContracts
import NibDesign

// Mouse, trackpad and pointer support (P-050):
// - a right-click (secondary click, two-finger click) on a page opens the page menu through `menu.showAt`, unless the
//   canvas already presents its own context menu there (the object menu feature installs one: that menu wins, so a
//   click never opens two menus);
// - scrolling with ⌘ held zooms the canvas towards the pointer through `view.zoom` and `view.scrollBy`;
// - UIKit buttons and controls in the chrome get the system hover highlight in their own shape (SwiftUI controls get
//   it from NibDesign's press style).

// MARK: - Scroll-wheel zoom (pure)

enum ScrollZoom {
    /// Scroll distance (points) that doubles or halves the zoom.
    static let pointsPerDoubling = 160.0
    static let minScale = ZoomLadder.levels[0]
    static let maxScale = ZoomLadder.levels[ZoomLadder.levels.count - 1]

    /// Zoom factor for a scroll translation: scrolling down the content (wheel forward, fingers down) zooms in.
    static func factor(forScroll dy: Double) -> Double {
        guard dy.isFinite else { return 1 }
        return pow(2, dy / pointsPerDoubling)
    }

    /// The zoom a gesture that started at `base` asks for after scrolling `dy`, within the canvas's widest range.
    static func target(base: Double, scroll dy: Double) -> Double {
        let start = base.isFinite && base > 0 ? base : 1
        return min(max(start * factor(forScroll: dy), minScale), maxScale)
    }

    /// The pan (page points, positive = right and down, as `view.scrollBy` takes it) that brings the page point now
    /// at `anchor` (canvas content coordinates) back under the pointer, which sat at `pointer` in the visible area.
    static func anchorCorrection(anchor: CGPoint, contentOffset: CGPoint, pointer: CGPoint, zoom: Double) -> (dx: Double, dy: Double) {
        guard zoom.isFinite, zoom > 0 else { return (0, 0) }
        let onScreen = CGPoint(x: anchor.x - contentOffset.x, y: anchor.y - contentOffset.y)
        return (Double(onScreen.x - pointer.x) / zoom, Double(onScreen.y - pointer.y) / zoom)
    }
}

// MARK: - Right-click

@MainActor
enum RightClick {
    /// `menu.showAt` params for a click at `location` (canvas view coordinates); nil off the pages.
    static func menuParams(host: CanvasHost, location: CGPoint) -> JSONValue? {
        guard let hit = host.pagePoint(location), hit.point.x.isFinite, hit.point.y.isFinite else { return nil }
        return ["page": .string(NodeRef.page(host.documentID, hit.page).description),
                "point": [.number(hit.point.x), .number(hit.point.y)]]
    }

    /// True when the view under the click, or one of its ancestors up to the canvas's container, presents its own
    /// context menu (UIContextMenuInteraction): that menu answers the right-click.
    static func hasOwnContextMenu(in canvas: UIView, at location: CGPoint) -> Bool {
        let stop = canvas.superview
        var view: UIView? = canvas.hitTest(location, with: nil) ?? canvas
        while let v = view {
            if v.interactions.contains(where: { $0 is UIContextMenuInteraction }) { return true }
            if v === stop { break }
            view = v.superview
        }
        return false
    }
}

// MARK: - Canvas attachment

/// Right-click and ⌘-scroll on a notebook or whiteboard canvas. Claims no touches: its two recognisers only see a
/// secondary click and scroll events with ⌘ held, and never cancel another gesture.
@MainActor
final class PointerCanvasAttachment: NSObject, CanvasAttachment, UIGestureRecognizerDelegate {
    private struct ZoomGesture {
        var base: Double
        /// Pointer position in the visible area (canvas coordinates minus the scroll offset).
        var pointer: CGPoint
        var anchor: (page: PageID, point: Point)?
    }

    private weak var host: CanvasHost?
    private var secondaryClick: UITapGestureRecognizer?
    private var scrollZoom: UIPanGestureRecognizer?
    private var gesture: ZoomGesture?
    private var pendingScale: Double?
    private var zoomInFlight = false
    private let log = Logger(subsystem: "app.nib", category: "keyboard")

    func attach(to host: CanvasHost) {
        self.host = host
        let click = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked(_:)))
        click.buttonMaskRequired = .secondary
        click.cancelsTouchesInView = false
        click.delaysTouchesBegan = false
        click.delaysTouchesEnded = false
        click.delegate = self
        host.canvasView.addGestureRecognizer(click)
        secondaryClick = click

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        host.canvasView.addGestureRecognizer(scroll)
        scrollZoom = scroll
    }

    func detach(from host: CanvasHost) {
        if let click = secondaryClick { host.canvasView.removeGestureRecognizer(click) }
        if let scroll = scrollZoom { host.canvasView.removeGestureRecognizer(scroll) }
        secondaryClick = nil
        scrollZoom = nil
        gesture = nil
        pendingScale = nil
        self.host = nil
    }

    // MARK: Right-click → menu.showAt

    @objc private func secondaryClicked(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let host else { return }
        let location = recognizer.location(in: host.canvasView)
        guard let params = RightClick.menuParams(host: host, location: location) else { return }
        host.app.perform(CommandIDs.menuShowAt, params, session: host.session)
    }

    // MARK: ⌘-scroll → view.zoom towards the pointer

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }
        let view = host.canvasView
        switch recognizer.state {
        case .began:
            let location = recognizer.location(in: view)
            let pointer = CGPoint(x: location.x - view.bounds.minX, y: location.y - view.bounds.minY)
            let anchor = host.pagePoint(location).map { (page: $0.page, point: $0.point) }
            gesture = ZoomGesture(base: host.zoomScale, pointer: pointer, anchor: anchor)
        case .changed:
            guard let g = gesture else { return }
            let dy = Double(recognizer.translation(in: nil).y)
            request(ScrollZoom.target(base: g.base, scroll: dy))
        default:
            gesture = nil
        }
    }

    /// One `view.zoom` at a time; scroll events that arrive meanwhile keep only the latest target.
    private func request(_ scale: Double) {
        if zoomInFlight {
            pendingScale = scale
            return
        }
        apply(scale)
    }

    private func apply(_ scale: Double) {
        guard let host else { return }
        zoomInFlight = true
        let app = host.app
        let session = host.session
        let snapshot = gesture
        Task { @MainActor [weak self] in
            do {
                _ = try await app.bus.execute(CommandIDs.viewZoom, ["scale": .number(scale)], session: session)
                if let self, let host = self.host, let g = snapshot, let anchor = g.anchor,
                   host.pageFrame(anchor.page) != nil {
                    let content = host.viewPoint(anchor.point, page: anchor.page)
                    let c = ScrollZoom.anchorCorrection(anchor: content, contentOffset: host.canvasView.bounds.origin,
                                                        pointer: g.pointer, zoom: host.zoomScale)
                    if abs(c.dx) + abs(c.dy) > 0.01 {
                        _ = try await app.bus.execute(CommandIDs.viewScrollBy, ["dx": .number(c.dx), "dy": .number(c.dy)],
                                                      session: session)
                    }
                }
            } catch {
                // No canvas feature to zoom (or the window closed): the scroll does nothing, as it should.
                self?.log.debug("scroll zoom: \(NibError.wrap(error).message, privacy: .public)")
            }
            guard let self else { return }
            self.zoomInFlight = false
            if let next = self.pendingScale {
                self.pendingScale = nil
                self.apply(next)
            }
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let host, !host.session.inking.isInking else { return false }
        if recognizer === scrollZoom {
            return recognizer.modifierFlags.contains(.command)
        }
        if recognizer === secondaryClick {
            guard host.app.commands.entry(CommandIDs.menuShowAt) != nil else { return false }
            return !RightClick.hasOwnContextMenu(in: host.canvasView, at: recognizer.location(in: host.canvasView))
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        if recognizer === scrollZoom {
            // Plain scrolling never reaches this recogniser, so it never delays the canvas's own scrolling.
            return event.type == .scroll && event.modifierFlags.contains(.command)
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer === secondaryClick
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard recognizer === scrollZoom, let scrollView = host?.canvasView as? UIScrollView else { return false }
        return other === scrollView.panGestureRecognizer
    }
}

// MARK: - Hover effects for UIKit toolbar buttons

enum PointerShapes {
    /// Corner radius of the hover highlight: the view's own rounding, else a circle or capsule for bar-sized controls
    /// (Nib's icon and capsule buttons), else the field radius.
    static func cornerRadius(for size: CGSize, layerRadius: CGFloat) -> CGFloat {
        if layerRadius > 0 { return layerRadius }
        let short = min(size.width, size.height)
        if short <= NibMetrics.barHeightMax { return short / 2 }
        return NibRadius.field
    }

    @MainActor
    static func shape(for view: UIView) -> UIPointerShape {
        .roundedRect(view.bounds, radius: cornerRadius(for: view.bounds.size, layerRadius: view.layer.cornerRadius))
    }
}

/// The system hover highlight for controls a feature built in UIKit.
@MainActor
final class HoverHighlight: NSObject, UIPointerInteractionDelegate {
    static let shared = HoverHighlight()

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let view = interaction.view, view.window != nil, !view.isHidden else { return nil }
        return UIPointerStyle(effect: .highlight(UITargetedPreview(view: view)), shape: PointerShapes.shape(for: view))
    }
}

@MainActor
enum HoverEffects {
    /// Bound on the views visited per pass (a window is a few thousand views).
    static let maxViews = 8_000

    /// Gives every UIKit button and custom control under `root` the hover highlight, once. System bars already have
    /// it, and SwiftUI content gets it from NibDesign (`NibPressStyle`), so both are skipped. Returns how many views
    /// were changed.
    @discardableResult
    static func install(in root: UIView) -> Int {
        var changed = 0
        var visited = 0
        var stack: [UIView] = [root]
        while let view = stack.popLast(), visited < maxViews {
            visited += 1
            if view is UINavigationBar || view is UIToolbar || view is UITabBar { continue }
            if let button = view as? UIButton {
                // UIKit may hand out a private subclass (UIButton(type: .system)); its subviews are its own.
                if enable(button) { changed += 1 }
                continue
            }
            if isPrivateContainer(view) { continue }
            if let control = view as? UIControl, needsInteraction(control) {
                control.addInteraction(UIPointerInteraction(delegate: HoverHighlight.shared))
                changed += 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return changed
    }

    /// Private UIKit and SwiftUI hosting views ("_UIHostingView", "_UIContextMenuContainerView"…): SwiftUI content
    /// hovers through NibDesign, and UIKit's private views look after themselves.
    static func isPrivateContainer(_ view: UIView) -> Bool {
        String(describing: type(of: view)).hasPrefix("_")
    }

    static func hasPointerInteraction(_ view: UIView) -> Bool {
        view.interactions.contains { $0 is UIPointerInteraction }
    }

    /// A UIButton's own pointer interaction draws the system effect in the button's shape.
    private static func enable(_ button: UIButton) -> Bool {
        guard !button.isPointerInteractionEnabled else { return false }
        button.isPointerInteractionEnabled = true
        return true
    }

    /// Controls a feature defined (UIKit's own switches, sliders and segmented controls already hover).
    private static func needsInteraction(_ control: UIControl) -> Bool {
        guard control.isUserInteractionEnabled, !hasPointerInteraction(control) else { return false }
        return Bundle(for: type(of: control)) != Bundle(for: UIControl.self)
    }
}

/// Re-applies `HoverEffects` to the app's windows shortly after the chrome changes (a window becomes key, a scene
/// activates, a document opens, toolbar items or chrome state change). Windows are learnt from those notifications,
/// so nothing here needs `UIApplication.shared`. Off in hostless tests, which have no windows.
@MainActor
final class PointerHoverInstaller {
    static let delay: TimeInterval = 0.3
    private var pending: DispatchWorkItem?
    private let observers = NotificationBag()
    private let windows = NSHashTable<UIWindow>.weakObjects()
    private var isStarted = false
    private(set) var passes = 0

    func start(app: NibApp) {
        guard !NibApp.isHostlessTest, !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? UIWindow
            KeyboardRuntime.onMain { self?.noteWindows(window.map { [$0] } ?? []) }
        })
        observers.add(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] note in
            let scene = note.object as? UIWindowScene
            KeyboardRuntime.onMain { self?.noteWindows(scene?.windows ?? []) }
        })
        let refresh: [(Notification.Name, AnyObject)] = [(.nibChromeNeedsUpdate, app.ui), (.nibRegistryDidChange, app.ui.toolbar)]
        for (name, object) in refresh {
            observers.add(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                KeyboardRuntime.onMain { self?.schedule() }
            })
        }
        observers.add(app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.sessionDocument || event.type == NibEventType.sessionActivated else { return }
            KeyboardRuntime.onMain { self?.schedule() }
        })
    }

    func noteWindows(_ list: [UIWindow]) {
        for window in list { windows.add(window) }
        schedule()
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.installInWindows() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func installInWindows() {
        pending = nil
        passes += 1
        for window in windows.allObjects where !window.isHidden {
            HoverEffects.install(in: window)
        }
    }
}

// MARK: - Registration

@MainActor
enum PointerSupport {
    static let attachmentID = "keyboard.pointer"

    static func register(_ app: NibApp, owner: String) {
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: attachmentID, owner: owner, order: 960) { _ in
            PointerCanvasAttachment()
        })
    }
}
