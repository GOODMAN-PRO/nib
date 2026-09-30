import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

/// Which touches may count toward an undo/redo tap. Pure, so "never on toolbars" is unit-tested.
@MainActor
enum UndoGestureGate {
    /// Only touches on the canvas or its content: never on a control, text field or bar (even one hosted inside the
    /// canvas), and never outside it (the floating chrome is a sibling layer above the canvas).
    static func accepts(touchIn view: UIView?, canvas: UIView) -> Bool {
        guard let view, view.isDescendant(of: canvas) else { return false }
        var current: UIView? = view
        while let v = current, v !== canvas {
            if isChrome(v) { return false }
            current = v.superview
        }
        return true
    }

    static func isChrome(_ view: UIView) -> Bool {
        view is UIControl || view is UITextInput || view is UIToolbar || view is UINavigationBar
            || view is UITabBar || view is UISearchBar
    }

    /// The setting is on, the document is editable and no text is being edited (a text view keeps the system's own
    /// multi-finger undo while it edits).
    static func isEnabled(setting: Bool, readOnly: Bool, editingText: Bool) -> Bool {
        setting && !readOnly && !editingText
    }
}

/// Turns off the system's three-finger editing gestures (swipe to undo, and its three-finger double-tap undo, which
/// would fight our three-finger redo) while the canvas has focus. UIKit reads `editingInteractionConfiguration` along
/// the first responder's chain. The canvas editor's view controller returns `.none` itself (F006), but the shell, which
/// holds key focus otherwise, is its parent and so outside that chain and does not forward the property
/// (contract-gaps F015). This invisible responder inside the canvas therefore holds focus while the taps are on; its
/// chain runs through the editor's view controller, and key commands still reach the shell further up.
final class UndoFocusResponder: UIView {
    var onWindow: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindow?() }
    }
}

/// Two-finger double-tap = undo, three-finger double-tap = redo on the canvas (T-082, P-041). Direct touches only
/// (the Pencil never triggers it), off when `undo.gestures` is false, in read-only mode or while text is edited.
/// It never claims touches from the canvas, tools or other attachments: the recognizers only watch. The taps do what
/// ⌘Z / ⇧⌘Z do in the same window (`UndoRoute`): the document's step, else the window's ("Move Palette").
@MainActor
final class UndoGestureAttachment: NSObject, CanvasAttachment, UIGestureRecognizerDelegate {
    let undoTap = UITapGestureRecognizer()
    let redoTap = UITapGestureRecognizer()
    let focus = UndoFocusResponder(frame: .zero)
    /// The UndoManager of the canvas's window: where the taps fall back when the document has no step (the one the
    /// shell's ⌘Z falls back to). Replaceable in tests.
    var windowUndo: @MainActor (CanvasHost) -> UndoManager? = { $0.canvasView.window?.undoManager }
    private weak var host: CanvasHost?

    init(host: CanvasHost) {
        self.host = host
        super.init()
        let taps: [(UITapGestureRecognizer, Int, Selector)] = [
            (undoTap, 2, #selector(undoTapped(_:))),
            (redoTap, 3, #selector(redoTapped(_:))),
        ]
        for (tap, fingers, action) in taps {
            tap.addTarget(self, action: action)
            tap.numberOfTouchesRequired = fingers
            tap.numberOfTapsRequired = 2
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.delaysTouchesEnded = false
            tap.delegate = self
        }
        focus.isUserInteractionEnabled = false
        focus.isAccessibilityElement = false
        focus.accessibilityElementsHidden = true
        focus.onWindow = { [weak self] in self?.claimFocus() }
    }

    func attach(to host: CanvasHost) {
        self.host = host
        host.canvasView.addGestureRecognizer(undoTap)
        host.canvasView.addGestureRecognizer(redoTap)
        host.canvasView.addSubview(focus)
    }

    func detach(from host: CanvasHost) {
        host.canvasView.removeGestureRecognizer(undoTap)
        host.canvasView.removeGestureRecognizer(redoTap)
        if focus.isFirstResponder { focus.resignFirstResponder() }
        focus.removeFromSuperview()
        self.host = nil
    }

    @objc private func undoTapped(_ tap: UITapGestureRecognizer) { fire(.undo, tap) }
    @objc private func redoTapped(_ tap: UITapGestureRecognizer) { fire(.redo, tap) }

    private func fire(_ action: UndoAction, _ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        Task { await self.perform(action) }
    }

    /// Undoes or redoes where ⌘Z / ⇧⌘Z would in this window: `edit.undo` / `edit.redo` on this canvas's document as the
    /// user while its history has a step, else the window's UndoManager. Instant: nothing animates and no haptic plays
    /// (DESIGN.md §9.3). Returns whether a step was undone or redone.
    @discardableResult
    func perform(_ action: UndoAction) async -> Bool {
        guard let host else { return false }
        let window = windowUndo(host)
        switch action.route(doc: host.documentID, history: host.app.bus.history, window: window) {
        case .nothing:
            return false
        case .window:
            return window.map { UndoWindow.perform(action, on: $0) } ?? false
        case .document:
            break
        }
        do {
            let result = try await host.app.bus.execute(action.command, UndoAction.params(doc: host.documentID),
                                                        session: host.session)
            return result["done"]?.boolValue ?? false
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: host.app,
                                            userInfo: ["command": action.command, "error": NibError.wrap(error)])
            return false
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let host else { return false }
        return UndoGestureGate.accepts(touchIn: touch.view, canvas: host.canvasView)
    }

    /// Only the three-finger system gesture fights ours, so only three fingers down take focus: a scroll, a tap or a
    /// pinch leaves a text field elsewhere (the assistant composer, a search or rename field) focused.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        let fingers = event.allTouches?.filter {
            $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        if fingers >= 3 { claimFocus() }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host else { return false }
        return UndoGestureGate.isEnabled(setting: host.app.settings.get(UndoSettings.gestures),
                                         readOnly: host.session.readOnly, editingText: host.session.isEditingText)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// Takes focus so the system's three-finger gestures stay off, unless our taps are off (setting, read-only) or a
    /// text box or block is being edited.
    private func claimFocus() {
        // ponytail: focus is claimed on appearing and on three-finger touches only. Once the shell forwards
        // `editingInteractionConfiguration` to the shown editor (whose view controller already returns `.none`), this
        // responder can go.
        guard let host, !focus.isFirstResponder, focus.window != nil,
              UndoGestureGate.isEnabled(setting: host.app.settings.get(UndoSettings.gestures),
                                        readOnly: host.session.readOnly, editingText: host.session.isEditingText)
        else { return }
        focus.becomeFirstResponder()
    }
}

/// Settings › Editing › Undo and Redo: turns the multi-finger taps off (P-041). The toggle runs `settings.set`, so the
/// AI, plugins and the bridge can change it the same way. The buttons' side (P-030) is on the Document Editing page.
struct UndoSettingsView: View {
    let app: NibApp
    @State private var gestures: Bool

    init(app: NibApp) {
        self.app = app
        _gestures = State(initialValue: app.settings.get(UndoSettings.gestures))
    }

    var body: some View {
        List {
            Section {
                NibToggle(String(localized: "Double-Tap with Fingers"), isOn: Binding(get: { gestures }, set: { apply($0) }))
            } footer: {
                Text(String(localized: "Double-tap the page with two fingers to undo and with three fingers to redo."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Undo and Redo"))
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: RunLoop.main)) { note in
                guard (note.userInfo?["name"] as? String) == UndoSettings.gestures.name else { return }
                gestures = app.settings.get(UndoSettings.gestures)
            }
    }

    private func apply(_ on: Bool) {
        gestures = on
        app.perform(CommandIDs.settingsSet, ["name": .string(UndoSettings.gestures.name), "value": .bool(on)])
    }
}
