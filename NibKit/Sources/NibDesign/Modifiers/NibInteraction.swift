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

    public init<S: Shape>(shape: S) { self.shape = AnyShape(shape) }
    public init() { self.init(shape: Capsule()) }

    public func makeBody(configuration: Configuration) -> some View {
        NibPressBody(configuration: configuration, shape: shape)
    }
}

struct NibPressBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: AnyShape
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(NibMotion.tap.animation, value: configuration.isPressed)
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
