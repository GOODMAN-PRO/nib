import UIKit

/// Physical modifier state for responder-chain fallbacks. UIKit may forward a
/// modifier down separately and omit it from the printable key's flags.
public struct HardwareKeyModifiers {
    private var held: Set<UIKeyboardHIDUsage> = []
    public init() {}

    public mutating func began(_ code: UIKeyboardHIDUsage) {
        if Self.flag(for: code) != nil { held.insert(code) }
    }

    public mutating func ended(_ code: UIKeyboardHIDUsage) { held.remove(code) }
    public mutating func reset() { held.removeAll() }

    public var flags: UIKeyModifierFlags {
        held.reduce(into: UIKeyModifierFlags()) { result, code in
            if let flag = Self.flag(for: code) { result.formUnion(flag) }
        }
    }

    private static func flag(for code: UIKeyboardHIDUsage) -> UIKeyModifierFlags? {
        switch code {
        case .keyboardLeftGUI, .keyboardRightGUI: .command
        case .keyboardLeftShift, .keyboardRightShift: .shift
        case .keyboardLeftAlt, .keyboardRightAlt: .alternate
        case .keyboardLeftControl, .keyboardRightControl: .control
        default: nil
        }
    }
}
