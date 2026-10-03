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
    private var heldModifiers = CanvasHeldModifiers()
    private let hardwareInputView = UIView(frame: .zero)

    // Navigation advertises key commands without accepting text insertion.
    // Keep the empty input surface and no-op editing hooks, but do not expose
    // those hooks to UIKit as a UIKeyInput text editor.
    var hasText: Bool { false }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    override var inputView: UIView? { hardwareInputView }

    init() {
        super.init(frame: .zero)
        // UIView drops key events when interaction is disabled, even while it is
        // first responder. Exclude this view from touch hit testing instead.
        isUserInteractionEnabled = true
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    func attach(to host: CanvasHost) {
        self.host = host
        host.canvasView.addSubview(self)
        let bag = NotificationBag()
        observers = bag
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                     UIApplication.willResignActiveNotification, UIScene.didActivateNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardDidHideNotification, .nibChromeNeedsUpdate, .nibRegistryDidChange] {
            bag.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                KeyboardRuntime.onMain {
                    guard let self else { return }
                    self.heldModifiers.focusChanged(note, window: self.window)
                    self.scheduleFocus()
                }
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
        // Undo and chrome hosts can leave focus in a sibling of the page. Scope
        // recovery to this window, still yielding to controls, text and modals.
        guard let host, let window, window.isKeyWindow, !isFirstResponder,
              host.session.document == host.documentID, !host.session.isEditingText,
              !host.session.inking.isInking, !NibHaptics.isInking,
              !CanvasKeyboardFocus.hasModal(window.rootViewController),
              CanvasKeyboardFocus.mayReplace(CanvasKeyboardFocus.firstResponder(in: window),
                                             canvas: window.rootViewController?.viewIfLoaded ?? host.canvasView) else { return }
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
        // The registry has already resolved scope, kind, text focus and conflicts.
        // Requiring an explicit kind here loses document-wide commands such as
        // Sidebar and tab switching at the SwiftUI hosting boundary.
        return KeyCommandRouting.active(host.app.content.keyCommands.all, in: context)
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
        if action == #selector(selectAll(_:)) { return selectAllDescriptor(sender) != nil }
        if action == #selector(delete(_:)) { return deleteDescriptor(sender) != nil }
        guard action == #selector(runCanvasKey(_:)) else { return super.canPerformAction(action, withSender: sender) }
        // UIKit probes the action without a UIKeyCommand while discovering keyboard targets.
        // Rejecting that probe hides every canvas shortcut, even when its descriptor is live.
        // Once UIKit supplies a command, still validate its ID against the current registry/focus.
        guard let command = sender as? UIKeyCommand else { return !descriptors.isEmpty }
        return descriptor(for: command) != nil
    }

    /// UIKit's Edit menu and standard Command-A dispatch use selectAll(_:), not our private
    /// key selector. Both entry points must resolve the same live, window-scoped descriptor.
    /// In particular, never take Select All from a native text input or a presented sheet.
    private func selectAllDescriptor(_ sender: Any?) -> KeyCommandDescriptor? {
        guard !context.isEditingText, !CanvasKeyboardFocus.hasModal(window?.rootViewController),
              let descriptor = descriptors.first(where: { $0.shortcut == KeyShortcut("a", .command) }) else {
            return nil
        }
        if let command = sender as? UIKeyCommand {
            if let id = command.propertyList as? String {
                guard id == descriptor.id else { return nil }
            } else {
                // A system-created Edit command has no registry ID attached.
                guard command.input?.lowercased() == "a", command.modifierFlags == .command else { return nil }
            }
        }
        return descriptor
    }

    override func selectAll(_ sender: Any?) {
        guard let descriptor = selectAllDescriptor(sender) else { return }
        run(descriptor)
    }

    /// Standard editing dispatch (including hardware Delete) can bypass the
    /// UIKeyCommand selector, just like Select All. Resolve the live selection
    /// in this scene and leave native text deletion to its editor.
    private func deleteDescriptor(_ sender: Any?) -> KeyCommandDescriptor? {
        guard !context.isEditingText, host?.session.selection.items.isEmpty == false,
              !CanvasKeyboardFocus.hasModal(window?.rootViewController),
              let descriptor = descriptors.first(where: { $0.shortcut == KeyShortcut("delete") }) else { return nil }
        if let command = sender as? UIKeyCommand {
            if let id = command.propertyList as? String {
                guard id == descriptor.id else { return nil }
            } else {
                guard command.input == UIKeyCommand.inputDelete, command.modifierFlags.isEmpty else { return nil }
            }
        }
        return descriptor
    }

    override func delete(_ sender: Any?) {
        guard let descriptor = deleteDescriptor(sender) else { return }
        run(descriptor)
    }

    @objc private func runCanvasKey(_ command: UIKeyCommand) {
        guard let descriptor = descriptor(for: command) else { return }
        run(descriptor)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { heldModifiers.begin(key.keyCode) } }
        var unhandled = presses
        for press in presses {
            #if DEBUG
            if let key = press.key {
                NSLog("[Canvas keyboard] code=%ld keyFlags=%lu eventFlags=%lu first=%d commands=%ld", key.keyCode.rawValue,
                      key.modifierFlags.rawValue, event?.modifierFlags.rawValue ?? 0, isFirstResponder ? 1 : 0, descriptors.count)
            }
            #endif
            guard let key = press.key,
                  performUnhandledPress(heldModifiers.shortcut(key, event: event)) else { continue }
            unhandled.remove(press)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { heldModifiers.end(key.keyCode) } }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { heldModifiers.end(key.keyCode) } }
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { heldModifiers = CanvasHeldModifiers() }
        return resigned
    }

    /// UIKit delivers only presses that did not invoke a UIKeyCommand here. Handle them
    /// before forwarding through a SwiftUI host, which may consume them before the shell.
    @discardableResult
    func performUnhandledPress(_ shortcut: KeyShortcut) -> Bool {
        guard window?.isKeyWindow == true, !CanvasKeyboardFocus.hasModal(window?.rootViewController),
              let descriptor = KeyCommandRouting.unhandledPress(shortcut, descriptors: descriptors,
                                                                 in: context) else { return false }
        run(descriptor)
        return true
    }

    private func run(_ descriptor: KeyCommandDescriptor) {
        guard let host else { return }
        #if DEBUG
        NSLog("[Canvas keyboard] dispatch %@", descriptor.id)
        #endif
        if window?.isKeyWindow == true,
           let navigator = window?.rootViewController as? SceneNavigator, navigator.session === host.session {
            host.app.ui.activeNavigator = navigator
            host.app.services.sessions.activate(host.session)
        }
        CanvasCommandDispatch.perform(descriptor, app: host.app, session: host.session, window: window)
    }

    static func input(_ key: String) -> String {
        switch key {
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        case "delete": return UIKeyCommand.inputDelete
        case "escape": return UIKeyCommand.inputEscape
        case "tab": return "\t"
        case "return": return "\r"
        case "space": return " "
        default: return key
        }
    }

    static func modifiers(_ flags: KeyModifiers) -> UIKeyModifierFlags {
        var result: UIKeyModifierFlags = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.alternate) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

/// Both native canvas responders share the shell's document-first undo policy.
/// Palette movement belongs to the window manager when document history is empty.
@MainActor
enum CanvasCommandDispatch {
    static func perform(_ descriptor: KeyCommandDescriptor, app: NibApp, session: EditorSession, window: UIWindow?) {
        let params = descriptor.resolvedParams(for: session)
        let manager = window?.undoManager
        switch UndoRoute.forCommand(descriptor.command, params: params, session: session,
                                    history: app.bus.history, window: manager) {
        case .window?:
            guard let manager, manager.groupingLevel <= 1,
                  !manager.isUndoing, !manager.isRedoing else { return }
            if descriptor.command == CommandIDs.redo { manager.redo() } else { manager.undo() }
        case .nothing?:
            return
        case .document?, nil:
            app.perform(descriptor.command, params, session: session)
        }
    }
}

/// Modifier down/up events can be forwarded separately from the printable press.
/// Retain only physical modifiers, never infer a chord from the requested action.
struct CanvasHeldModifiers {
    private(set) var keys: Set<UIKeyboardHIDUsage> = []

    mutating func begin(_ code: UIKeyboardHIDUsage) {
        switch code {
        case .keyboardLeftGUI, .keyboardRightGUI, .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl:
            keys.insert(code)
        default: break
        }
    }

    mutating func end(_ code: UIKeyboardHIDUsage) { keys.remove(code) }

    @MainActor
    mutating func focusChanged(_ notification: Notification, window: UIWindow?) {
        // UIKit can keep a window's first responder while another scene owns
        // the keyboard; its key-up events will no longer reach this responder.
        if notification.name == UIApplication.willResignActiveNotification {
            reset()
        } else if notification.name == UIWindow.didResignKeyNotification,
                  let window, notification.object as? UIWindow === window {
            reset()
        }
    }

    /// Focus can move before UIKit delivers the corresponding key-up events.
    mutating func reset() { keys.removeAll() }

    @MainActor
    func shortcut(_ key: UIKey, event: UIPressesEvent?) -> KeyShortcut {
        CanvasKeyPress.shortcut(key, event: event, heldKeys: Array(keys))
    }
}

/// A forwarded key can carry its chord on the event rather than the individual key.
/// Preserve both, and use HID codes for navigation keys whose characters are private Unicode.
@MainActor
enum CanvasKeyPress {
    static func shortcut(_ key: UIKey, event: UIPressesEvent?, heldKeys: [UIKeyboardHIDUsage] = []) -> KeyShortcut {
        let held = heldKeys + (event?.allPresses.filter { $0.phase != .ended && $0.phase != .cancelled }
            .compactMap { $0.key?.keyCode } ?? [])
        return shortcut(code: key.keyCode, characters: key.charactersIgnoringModifiers,
                        keyFlags: key.modifierFlags, eventFlags: event?.modifierFlags ?? [], heldKeys: held)
    }

    static func shortcut(code: UIKeyboardHIDUsage, characters: String,
                         keyFlags: UIKeyModifierFlags, eventFlags: UIKeyModifierFlags,
                         heldKeys: [UIKeyboardHIDUsage] = []) -> KeyShortcut {
        var input: String
        switch code {
        case .keyboardReturnOrEnter, .keypadEnter: input = "return"
        case .keyboardEscape: input = "escape"
        case .keyboardTab: input = "tab"
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward: input = "delete"
        case .keyboardUpArrow: input = "up"
        case .keyboardDownArrow: input = "down"
        case .keyboardLeftArrow: input = "left"
        case .keyboardRightArrow: input = "right"
        case .keyboardSpacebar: input = "space"
        default: input = characters.lowercased()
        }
        var flags = keyFlags.union(eventFlags)
        for held in heldKeys {
            switch held {
            case .keyboardLeftGUI, .keyboardRightGUI: flags.insert(.command)
            case .keyboardLeftAlt, .keyboardRightAlt: flags.insert(.alternate)
            case .keyboardLeftShift, .keyboardRightShift: flags.insert(.shift)
            case .keyboardLeftControl, .keyboardRightControl: flags.insert(.control)
            default: break
            }
        }
        // '+' is the shifted '=' key on the hardware layout. Preserve the
        // printable shortcut rather than dispatching a different Shift-= action.
        if input == "=", flags.contains(.shift) {
            input = "+"
            flags.remove(.shift)
        }
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return KeyShortcut(input, modifiers)
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
        // Hosting and drawing views can implement UIKeyInput to receive hardware
        // events without editing text. Only a text editor suppresses canvas keys.
        return responder is UITextInput
    }

    static func mayReplace(_ responder: UIResponder?, canvas: UIView) -> Bool {
        guard let responder else { return true }
        guard !isTextInput(responder) else { return false }
        // A focused panel can own contextual keys (Pages: Command-A/Command-C).
        // Root-scoped focus recovery must not turn those into canvas item actions.
        // The window's root controller is only the fallback route, not a panel.
        if responder !== canvas.next, responder !== canvas.window?.rootViewController,
           responder.keyCommands?.isEmpty == false { return false }
        if let view = responder as? UIView {
            return !(view is UIControl) && (view.isDescendant(of: canvas) || canvas.isDescendant(of: view))
        }
        // Apply the same subtree rule to hosting controllers as to their views.
        // Controllers in unrelated panels keep their own keyboard handling.
        guard let view = (responder as? UIViewController)?.viewIfLoaded else { return false }
        return view.isDescendant(of: canvas) || canvas.isDescendant(of: view)
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
