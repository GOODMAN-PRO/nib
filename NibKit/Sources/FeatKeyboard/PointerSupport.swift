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
//   it from NibDesign's press style); canvases and text inputs are left alone.

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
    let keyboard = CanvasKeyboardResponder()
    private var secondaryClick: UITapGestureRecognizer?
    private var scrollZoom: UIPanGestureRecognizer?
    private var gesture: ZoomGesture?
    /// The latest zoom asked for while one is in flight, with the gesture it belongs to (its pointer anchor).
    private var pending: (scale: Double, gesture: ZoomGesture?)?
    private var zoomInFlight = false
    private let log = Logger(subsystem: "app.nib", category: "keyboard")

    /// No zoom running or waiting.
    var isZoomIdle: Bool { !zoomInFlight && pending == nil }

    func attach(to host: CanvasHost) {
        self.host = host
        keyboard.attach(to: host)
        HoverEffects.excludeSubtree(host.canvasView)
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

    func canvasDidChange(_ host: CanvasHost) { keyboard.scheduleFocus() }

    func detach(from host: CanvasHost) {
        keyboard.detach()
        if let click = secondaryClick { host.canvasView.removeGestureRecognizer(click) }
        if let scroll = scrollZoom { host.canvasView.removeGestureRecognizer(scroll) }
        HoverEffects.includeSubtree(host.canvasView)
        secondaryClick = nil
        scrollZoom = nil
        gesture = nil
        pending = nil
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
        switch recognizer.state {
        case .began:
            zoomBegan(at: recognizer.location(in: host.canvasView))
        case .changed:
            zoomChanged(scroll: Double(recognizer.translation(in: nil).y))
        default:
            zoomEnded()
        }
    }

    /// A ⌘-scroll starts at `location` (canvas view coordinates): the page point there stays under the pointer.
    func zoomBegan(at location: CGPoint) {
        guard let host else { return }
        let view = host.canvasView
        let pointer = CGPoint(x: location.x - view.bounds.minX, y: location.y - view.bounds.minY)
        let anchor = host.pagePoint(location).map { (page: $0.page, point: $0.point) }
        gesture = ZoomGesture(base: host.zoomScale, pointer: pointer, anchor: anchor)
    }

    /// The scroll has moved `dy` points since it began.
    func zoomChanged(scroll dy: Double) {
        guard let g = gesture else { return }
        request(ScrollZoom.target(base: g.base, scroll: dy))
    }

    func zoomEnded() {
        gesture = nil
    }

    /// One `view.zoom` at a time; scroll events that arrive meanwhile keep only the latest target. Each target keeps
    /// the gesture it was asked for in, so a zoom applied after the gesture ended still corrects towards its pointer.
    private func request(_ scale: Double) {
        if zoomInFlight {
            pending = (scale, gesture)
            return
        }
        apply(scale: scale, snapshot: gesture)
    }

    private func apply(scale: Double, snapshot: ZoomGesture?) {
        guard let host else { return }
        zoomInFlight = true
        let app = host.app
        let session = host.session
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
            if let next = self.pending {
                self.pending = nil
                self.apply(scale: next.scale, snapshot: next.gesture)
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

// MARK: - Canvas keyboard focus

/// The shell is above a SwiftUI hosting boundary and is not always the responder UIKit restores after a panel
/// closes or the canvas is relaid out. Keep the page shortcuts on a responder inside the canvas, and repair focus
/// after those transitions. This is a view, not a text input: it never opens a keyboard or intercepts a touch.
/// Descriptors still come from the registry (including another owner's winning Delete or Go to Page command).
@MainActor
final class CanvasKeyboardResponder: UIView {
    private weak var host: CanvasHost?
    private var observers: NotificationBag?
    private var focusScheduled = false
    private var shortcuts: Set<KeyShortcut> = []

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    func attach(to host: CanvasHost) {
        self.host = host
        shortcuts = Set(GlobalShortcuts.catalog(app: host.app, owner: FeatKeyboardFeature.id)
            .filter { $0.docKinds == ShortcutContext.canvasKinds }
            .map { ShortcutRules.normalized($0.shortcut) })
        host.canvasView.addSubview(self)
        let bag = NotificationBag()
        observers = bag
        for name in [UIWindow.didBecomeKeyNotification, UIScene.didActivateNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardDidHideNotification, .nibChromeNeedsUpdate, .nibRegistryDidChange] {
            bag.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                KeyboardRuntime.onMain { self?.scheduleFocus() }
            })
        }
        bag.add(host.app.events.subscribe { [weak self] event in
            guard [NibEventType.toolChanged, NibEventType.sessionDocument, NibEventType.sessionActivated]
                .contains(event.type) else { return }
            KeyboardRuntime.onMain { self?.scheduleFocus() }
        })
        scheduleFocus()
    }

    func detach() {
        observers = nil
        host = nil
        if isFirstResponder { resignFirstResponder() }
        removeFromSuperview()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleFocus()
    }

    /// Coalesce layout/selection/chrome updates and wait until UIKit has finished moving the old responder.
    func scheduleFocus() {
        guard host != nil, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            self.restoreFocus()
        }
    }

    func restoreFocus() {
        guard let host, let window, window.isKeyWindow, !isFirstResponder,
              host.session.document == host.documentID, !host.session.isEditingText,
              !CanvasKeyboardFocus.hasModal(window.rootViewController),
              CanvasKeyboardFocus.mayReplace(CanvasKeyboardFocus.firstResponder(in: window),
                                             canvas: host.canvasView) else { return }
        var ancestor: UIView? = host.canvasView
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return }
            ancestor = view.superview
        }
        becomeFirstResponder()
    }

    private var context: KeyCommandContext {
        guard let host else { return KeyCommandContext(docKind: nil) }
        let typing = host.session.isEditingText || window.map {
            CanvasKeyboardFocus.isTextInput(CanvasKeyboardFocus.firstResponder(in: $0))
        } == true
        return KeyCommandContext(docKind: ShortcutContext(session: host.session, app: host.app).kind,
                                 isEditingText: typing, hasTabs: true)
    }

    private var descriptors: [KeyCommandDescriptor] {
        guard let host, host.session.document == host.documentID else { return [] }
        return KeyCommandRouting.active(host.app.content.keyCommands.all, in: context).filter {
            if shortcuts.contains(ShortcutRules.normalized($0.shortcut)) { return true }
            // Feature-owned page shortcuts (e.g. the Pencil palette) also need a target below the
            // SwiftUI hosting boundary. Read the live registry so late registrations/replacements
            // work; the keyboard feature's catalog is not the complete set of canvas commands.
            guard $0.scope == .document || $0.scope == .canvas,
                  let kinds = $0.docKinds, !kinds.isEmpty else { return false }
            return kinds.isSubset(of: ShortcutContext.canvasKinds)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let context = context
        return descriptors.map { d in
            let command = UIKeyCommand(title: d.title, action: #selector(runCanvasKey(_:)),
                                       input: Self.input(d.shortcut.key),
                                       modifierFlags: Self.modifiers(d.shortcut.modifiers), propertyList: d.id)
            command.wantsPriorityOverSystemBehavior = KeyCommandRouting.overridesSystemKeys(d, in: context)
            return command.nibCommand(d.command)
        }
    }

    func descriptor(for command: UIKeyCommand) -> KeyCommandDescriptor? {
        guard let id = command.propertyList as? String else { return nil }
        return descriptors.first { $0.id == id }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(runCanvasKey(_:)) else { return super.canPerformAction(action, withSender: sender) }
        // UIKit probes the action without a UIKeyCommand while discovering keyboard targets.
        // Rejecting that probe hides every canvas shortcut, even when its descriptor is live.
        // Once UIKit supplies a command, still validate its ID against the current registry/focus.
        guard let command = sender as? UIKeyCommand else { return !descriptors.isEmpty }
        return descriptor(for: command) != nil
    }

    @objc private func runCanvasKey(_ command: UIKeyCommand) {
        guard let host, let descriptor = descriptor(for: command) else { return }
        if window?.isKeyWindow == true,
           let navigator = window?.rootViewController as? SceneNavigator, navigator.session === host.session {
            host.app.ui.activeNavigator = navigator
            host.app.services.sessions.activate(host.session)
        }
        host.app.perform(descriptor.command, descriptor.resolvedParams(for: host.session), session: host.session)
    }

    private static func input(_ key: String) -> String {
        switch key {
        case "delete": return UIKeyCommand.inputDelete
        case "escape": return UIKeyCommand.inputEscape
        default: return key
        }
    }

    private static func modifiers(_ flags: KeyModifiers) -> UIKeyModifierFlags {
        var result: UIKeyModifierFlags = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.alternate) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

@MainActor
enum CanvasKeyboardFocus {
    /// Search this window only, including view controllers in its responder chain. No process-wide active session.
    static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        if let controller = view.next as? UIViewController, controller.isFirstResponder { return controller }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }

    static func isTextInput(_ responder: UIResponder?) -> Bool {
        if let text = responder as? UITextView { return text.isEditable }
        if let field = responder as? UITextField { return field.isEnabled }
        return responder is UIKeyInput
    }

    static func mayReplace(_ responder: UIResponder?, canvas: UIView) -> Bool {
        guard let responder else { return true }
        guard !isTextInput(responder) else { return false }
        if let view = responder as? UIView {
            return !(view is UIControl) && (view.isDescendant(of: canvas) || canvas.isDescendant(of: view))
        }
        // Only controllers containing this canvas; unrelated panels keep their own keyboard handling.
        guard let view = (responder as? UIViewController)?.viewIfLoaded else { return false }
        return canvas.isDescendant(of: view)
    }

    static func hasModal(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        if controller.presentedViewController != nil { return true }
        return controller.children.contains { hasModal($0) }
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
    /// Bound on the views visited per pass: with the canvases left out, a window's chrome is a few hundred views.
    static let maxViews = 600

    /// Canvas views (`PointerCanvasAttachment` adds them): their page views and live item views are the canvas's own,
    /// so passes never walk into them.
    private static let excluded = NSHashTable<UIView>.weakObjects()

    static func excludeSubtree(_ view: UIView) { excluded.add(view) }

    static func includeSubtree(_ view: UIView) { excluded.remove(view) }

    static func isExcluded(_ view: UIView) -> Bool { excluded.contains(view) }

    /// Gives every UIKit button and custom control in the chrome under `root` the hover highlight, once. System bars
    /// already have it, and SwiftUI content gets it from NibDesign (`NibPressStyle`), so both are skipped, as are
    /// canvases and text inputs (a text field keeps its I-beam). Returns how many views were changed.
    @discardableResult
    static func install(in root: UIView) -> Int {
        var changed = 0
        var visited = 0
        var stack: [UIView] = [root]
        while let view = stack.popLast(), visited < maxViews {
            visited += 1
            if view is UINavigationBar || view is UIToolbar || view is UITabBar { continue }
            if isExcluded(view) || view is UITextInput { continue }
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
