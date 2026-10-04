import SwiftUI
import UIKit

enum NibKeyboardViewport {
    static func available(in bounds: CGRect, keyboard: CGRect?) -> CGRect {
        // UIKit can send an absent/invalid frame while moving a floating
        // keyboard between scenes. It must not collapse every open popover.
        guard let keyboard, !keyboard.isNull, !keyboard.isInfinite, !keyboard.isEmpty,
              keyboard.minX.isFinite, keyboard.minY.isFinite,
              keyboard.width.isFinite, keyboard.height.isFinite,
              keyboard.intersects(bounds) else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                      height: max(0, min(bounds.maxY, keyboard.minY) - bounds.minY))
    }
}

/// Keyboard occlusion in the containing view's coordinates, including windowed iPad scenes.
struct NibKeyboardOcclusionReader: UIViewRepresentable {
    @Binding var frame: CGRect?

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = { frame = $0 }
        return probe
    }
    func updateUIView(_ view: Probe, context: Context) { view.changed = { frame = $0 } }

    final class Probe: UIView {
        var changed: ((CGRect?) -> Void)?
        private var screenFrame: CGRect?
        private var reported: CGRect?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(updateKeyboard(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(hideKeyboard(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        @objc private func updateKeyboard(_ notification: Notification) {
            screenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            report()
        }
        @objc private func hideKeyboard(_ notification: Notification) { screenFrame = nil; report() }
        private func report() {
            guard let window else { return }
            let next = screenFrame.map { convert(NibKeyboardGeometry.frame($0, in: window), from: window) }
            guard reported != next else { return }
            reported = next
            DispatchQueue.main.async { [weak self] in self?.changed?(next) }
        }
    }
}

/// Keyboard notifications can already use the fullscreen scene's orientation
/// while UIScreen's coordinate space still describes the physical display.
public enum NibKeyboardGeometry {
    public static func frame(_ screenFrame: CGRect, in window: UIWindow) -> CGRect {
        let bounds = window.bounds
        if abs(screenFrame.minX - bounds.minX) < 1,
           abs(screenFrame.width - bounds.width) < 1,
           abs(screenFrame.maxY - bounds.maxY) < 1 {
            return screenFrame
        }
        return window.convert(screenFrame, from: window.screen.coordinateSpace)
    }
}
