import SwiftUI
import UIKit

private struct NibShowsKeyHintsKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True while ⌘ is held on a hardware keyboard. The app's root hosting controller sets it from
    /// `UIPress.modifierFlags` in `pressesBegan` / `pressesEnded`; every control with a shortcut then shows its `KeyHint`.
    var nibShowsKeyHints: Bool {
        get { self[NibShowsKeyHintsKey.self] }
        set { self[NibShowsKeyHintsKey.self] = newValue }
    }
}

/// Every Nib button: scale 0.96 on `tap`, the system hover highlight in the control's shape, and one focus ring
/// (2 pt accent, 2 pt outside, concentric) in place of the system focus effect.
public struct NibPressStyle: ButtonStyle {
    let shape: AnyShape
    let rectangularHitTarget: Bool

    /// Chips can keep the full rectangular hit target while hover and focus retain the visual shape.
    public init<S: Shape>(shape: S, rectangularHitTarget: Bool = false) {
        self.shape = AnyShape(shape)
        self.rectangularHitTarget = rectangularHitTarget
    }
    public init() { self.init(shape: Capsule()) }

    public func makeBody(configuration: Configuration) -> some View {
        NibPressBody(configuration: configuration, shape: shape, rectangularHitTarget: rectangularHitTarget)
    }
}

struct NibPressBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: AnyShape
    var rectangularHitTarget = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(NibMotion.tap.animation, value: configuration.isPressed)
            .contentShape(.interaction, rectangularHitTarget ? AnyShape(Rectangle()) : shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
            .overlay {
                if isFocused {
                    shape.stroke(NibColor.accent, lineWidth: 2)
                        .padding(-3)                         // the 2 pt ring starts 2 pt outside the control
                        .allowsHitTesting(false)
                }
            }
            .focusEffectDisabled()
    }
}

public extension View {
    /// Registers `shortcut` with the system (it appears in the ⌘-hold overlay) and shows it as a `KeyHint` below the
    /// control after 500 ms of pointer hover and while ⌘ is held. `nil` does nothing.
    func nibShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        modifier(NibShortcutModifier(shortcut: shortcut))
    }
}

struct NibShortcutModifier: ViewModifier {
    let shortcut: KeyboardShortcut?
    @Environment(\.nibShowsKeyHints) private var commandHeld
    @State private var hovered = false
    @State private var hoverWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .keyboardShortcut(shortcut)
            .onHover { inside in
                hoverWork?.cancel()
                guard shortcut != nil else { return }
                if inside {
                    let work = DispatchWorkItem { hovered = true }
                    hoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                } else {
                    hovered = false
                }
            }
            .overlay(alignment: .bottom) {
                if let shortcut, commandHeld || hovered {
                    KeyHint(shortcut)
                        .fixedSize()
                        .alignmentGuide(.bottom) { $0[.top] - NibSpacing.xs }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)             // the shortcut is already announced by the system
                        .transition(.opacity)
                }
            }
            .animation(NibMotion.fade, value: commandHeld || hovered)
    }
}

extension KeyboardShortcut {
    /// "⇧⌘Z", "⌘⏎", "⎋": the glyphs Apple uses in menus.
    var nibDisplay: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .return: s += "⏎"
        case .escape: s += "⎋"
        case .delete: s += "⌫"
        case .tab: s += "⇥"
        case .space: s += String(localized: "Space", bundle: .module)
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .leftArrow: s += "←"
        case .rightArrow: s += "→"
        default: s += String(key.character).uppercased()
        }
        return s
    }
}

/// Native touch ownership for controls embedded in the palette's glass/hosting
/// hierarchy. Accessibility and keyboard activation stay on the SwiftUI button.
struct NibActionTouchTarget: UIViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isOpaque = false
        view.backgroundColor = .clear
        let tap = NibActionTapRecognizer()
        tap.action = action
        tap.addTarget(tap, action: #selector(NibActionTapRecognizer.activate))
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard let tap = view.gestureRecognizers?.first as? NibActionTapRecognizer else { return }
        tap.action = action
        tap.isEnabled = isEnabled
    }
}

final class NibActionTapRecognizer: UITapGestureRecognizer {
    var action: () -> Void = {}
    private var start: CGPoint?
    @objc func activate() { action() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, let point = touches.first?.location(in: view),
           hypot(point.x - start.x, point.y - start.y) >= DropletPhysics.pickupSlop {
            state = .failed
        } else { super.touchesMoved(touches, with: event) }
    }
    override func reset() { super.reset(); start = nil }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
        // Scrolls and deliberate holds win. The hosting touch-down bridge does not.
        if other is UIPanGestureRecognizer || other is UILongPressGestureRecognizer {
            return super.canBePrevented(by: other)
        }
        return false
    }
}

public extension View {
    /// Keep touch delivery on a native surface when a button lives inside a
    /// retained glass popover; the original button retains accessibility/keys.
    func nibNativeAction(_ action: @escaping () -> Void) -> some View {
        modifier(NibNativeActionModifier(action: action))
    }
}

private struct NibNativeActionModifier: ViewModifier {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hasWindow = false

    func body(content: Content) -> some View {
        // ImageRenderer substitutes a placeholder for a UIViewRepresentable,
        // even when its UIView is clear. Changing its backing layer cannot make
        // that placeholder SwiftUI artwork. Only install native input in a window.
        // Until then the original button remains the touch owner; accessibility
        // and keyboard actions always remain on it.
        content.allowsHitTesting(!hasWindow).background {
            if hasWindow {
                NibActionTouchTarget(isEnabled: isEnabled, action: action)
                    .accessibilityHidden(true)
            }
        }
        .background {
            NibActionWindowProbe { attached in
                if hasWindow != attached { hasWindow = attached }
            }
                // The probe itself must contribute no placeholder pixels and
                // must never participate in the control's layout or hit testing.
                .frame(width: 0, height: 0)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct NibActionWindowProbe: UIViewRepresentable {
    let onWindowChange: (Bool) -> Void

    func makeUIView(context: Context) -> WindowView {
        let view = WindowView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onWindowChange = onWindowChange
        return view
    }

    func updateUIView(_ view: WindowView, context: Context) {
        view.onWindowChange = onWindowChange
    }

    final class WindowView: UIView {
        var onWindowChange: (Bool) -> Void = { _ in }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // UIKit can attach during a SwiftUI update. Publish on the next turn
            // and read the current window so a quick detach/reattach cannot send
            // a stale attachment value back into the modifier.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWindowChange(self.window != nil)
            }
        }
    }
}
