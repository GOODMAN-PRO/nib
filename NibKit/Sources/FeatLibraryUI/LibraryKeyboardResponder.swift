import SwiftUI
import UIKit
import NibContracts

/// Keep the library's keys on its focused native responder. An embedded hosting
/// view can consume a press before it reaches the container controller.
struct LibraryKeyboardHost: UIViewRepresentable {
    let model: LibraryViewModel

    func makeUIView(context: Context) -> LibraryKeyboardResponder {
        LibraryKeyboardResponder(model: model)
    }

    func updateUIView(_ view: LibraryKeyboardResponder, context: Context) {
        view.scheduleFocus()
    }

    static func dismantleUIView(_ view: LibraryKeyboardResponder, coordinator: ()) {
        view.resignFirstResponder()
        view.model = nil
    }
}

@MainActor
final class LibraryKeyboardResponder: UIView {
    weak var model: LibraryViewModel?
    private var focusScheduled = false
    private var held = Set<UIKeyboardHIDUsage>()
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private var lastKeyDiagnostic = ""
    #endif

    init(model: LibraryViewModel) {
        self.model = model
        super.init(frame: .zero)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        for name in [UIWindow.didBecomeKeyNotification, UIScene.didActivateNotification,
                     UIWindow.didResignKeyNotification, UIApplication.willResignActiveNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardDidHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == UIApplication.willResignActiveNotification ||
                        (name == UIWindow.didResignKeyNotification && note.object as? UIWindow === self.window) {
                        self.held.removeAll()
                    }
                    self.scheduleFocus()
                }
            })
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func didMoveToWindow() { super.didMoveToWindow(); scheduleFocus() }

    func scheduleFocus() {
        guard !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            self.restoreFocus()
        }
    }

    private var canRoute: Bool {
        guard let model, model.isVisible, let window, window.isKeyWindow,
              model.controller?.viewIfLoaded?.window === window,
              !Self.hasModal(window.rootViewController),
              LibrarySelectionShortcuts.canRoute(model) else { return false }
        return !Self.hasTextFocus(window)
    }

    func restoreFocus() {
        guard canRoute, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    private static func hasModal(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        return controller.presentedViewController != nil || controller.children.contains { hasModal($0) }
    }

    private static func hasTextFocus(_ view: UIView) -> Bool {
        if view.isFirstResponder && view is UITextInput { return true }
        return view.subviews.contains { hasTextFocus($0) }
    }

    var descriptors: [KeyCommandDescriptor] {
        guard canRoute, let model else { return [] }
        return LibrarySelectionShortcuts.descriptors(model)
    }

    override var keyCommands: [UIKeyCommand]? {
        let live = descriptors
        #if DEBUG
        let diagnostic = "focus \(isFirstResponder) route \(canRoute) visible \(model?.isVisible == true) selection \(model?.selection.isSelecting == true) keys \(live.map(\.id))"
        if diagnostic != lastKeyDiagnostic {
            lastKeyDiagnostic = diagnostic
            NSLog("%@", "[Library native key] \(diagnostic)")
        }
        #endif
        return live.map { LibrarySelectionShortcuts.command($0, action: #selector(runKey(_:))) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if let shortcut = Self.standardShortcut(action) {
            return descriptors.contains { $0.shortcut == shortcut }
        }
        guard action == #selector(runKey(_:)) else { return super.canPerformAction(action, withSender: sender) }
        guard let key = sender as? UIKeyCommand else { return !descriptors.isEmpty }
        guard let descriptor = descriptors.first(where: { $0.id == key.propertyList as? String }) else { return false }
        return route(descriptor) != .nothing
    }

    /// UIKit's Edit/navigation actions can be delivered instead of the custom
    /// selector on a UIKeyCommand. Resolve them through the same live registry.
    private static func standardShortcut(_ action: Selector) -> KeyShortcut? {
        switch action {
        case #selector(selectAll(_:)): return KeyShortcut("a", .command)
        case #selector(cancelOperation(_:)): return KeyShortcut("escape")
        case #selector(insertNewline(_:)): return KeyShortcut("return")
        default: return nil
        }
    }

    override func selectAll(_ sender: Any?) { performShortcut(KeyShortcut("a", .command)) }
    @objc func cancelOperation(_ sender: Any?) { performShortcut(KeyShortcut("escape")) }
    @objc func insertNewline(_ sender: Any?) { performShortcut(KeyShortcut("return")) }

    private func route(_ descriptor: KeyCommandDescriptor) -> UndoRoute? {
        guard let model else { return nil }
        return UndoRoute.forCommand(descriptor.command, params: descriptor.resolvedParams(for: model.session),
            session: model.session, history: model.app.bus.history, window: model.testUndoManager ?? window?.undoManager)
    }

    @objc private func runKey(_ key: UIKeyCommand) {
        #if DEBUG
        NSLog("%@", "[Library native key] action \(String(describing: key.propertyList)) input \(key.input ?? "") flags \(key.modifierFlags.rawValue)")
        #endif
        guard let descriptor = descriptors.first(where: { $0.id == key.propertyList as? String }) else { return }
        perform(descriptor)
    }

    @discardableResult
    func performShortcut(_ shortcut: KeyShortcut) -> Bool {
        guard let descriptor = descriptors.first(where: { $0.shortcut == shortcut }), route(descriptor) != .nothing else { return false }
        perform(descriptor)
        return true
    }

    private func perform(_ descriptor: KeyCommandDescriptor) {
        guard let model else { return }
        #if DEBUG
        NSLog("%@", "[Library native key] perform \(descriptor.id) session \(model.session.id) selection \(model.selection.refs.count)")
        #endif
        if let navigator = model.navigator { model.app.ui.activeNavigator = navigator }
        model.app.services.sessions.activate(model.session)
        switch route(descriptor) {
        case .nothing?: return
        case .window?:
            guard let manager = model.testUndoManager ?? window?.undoManager,
                  manager.groupingLevel <= 1, !manager.isUndoing, !manager.isRedoing else { return }
            if descriptor.command == CommandIDs.redo { manager.redo() }
            else { manager.undo() }
        case .document?, nil:
            model.perform(descriptor.command, descriptor.resolvedParams(for: model.session))
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let code = press.key?.keyCode, Self.modifier(code) != nil { held.insert(code) }
        }
        let unhandled = presses.filter { press in
            guard let key = press.key else { return true }
            #if DEBUG
            NSLog("%@", "[Library native key] press \(key.keyCode.rawValue) flags \(key.modifierFlags.rawValue) event \(event?.modifierFlags.rawValue ?? 0) route \(canRoute) descriptors \(descriptors.map(\.id))")
            #endif
            return !performShortcut(Self.shortcut(code: key.keyCode, characters: key.charactersIgnoringModifiers,
                flags: key.modifierFlags.union(event?.modifierFlags ?? []), held: held))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let code = press.key?.keyCode { held.remove(code) } }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let code = press.key?.keyCode { held.remove(code) } }
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { held.removeAll() }
        return resigned
    }

    private static func modifier(_ code: UIKeyboardHIDUsage) -> UIKeyModifierFlags? {
        switch code {
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        case .keyboardLeftAlt, .keyboardRightAlt: return .alternate
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        case .keyboardLeftControl, .keyboardRightControl: return .control
        default: return nil
        }
    }

    static func shortcut(code: UIKeyboardHIDUsage, characters: String, flags: UIKeyModifierFlags,
                         held: Set<UIKeyboardHIDUsage> = []) -> KeyShortcut {
        let input: String
        switch code {
        case .keyboardReturnOrEnter, .keypadEnter: input = "return"
        case .keyboardEscape: input = "escape"
        case .keyboardTab: input = "tab"
        case .keyboardDeleteOrBackspace: input = "delete"
        case .keyboardUpArrow: input = "up"
        case .keyboardDownArrow: input = "down"
        case .keyboardLeftArrow: input = "left"
        case .keyboardRightArrow: input = "right"
        case .keyboardSpacebar: input = "space"
        default: input = characters.lowercased()
        }
        let flags = held.compactMap(modifier).reduce(flags) { $0.union($1) }
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return KeyShortcut(input, modifiers)
    }
}
