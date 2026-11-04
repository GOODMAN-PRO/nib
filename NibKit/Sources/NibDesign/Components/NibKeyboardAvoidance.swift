import UIKit

/// Per-editor keyboard geometry. Convert the notification's screen frame into the owning window before
/// measuring overlap. Only this object's added scroll inset is removed on hide/end; existing insets survive.
/// `viewport` and `fitting` are pure so docked/floating keyboards and small windows can be tested without UIKit layout.
@MainActor
public final class NibKeyboardAvoidance: NSObject {
    private var screenFrame: CGRect?
    private weak var scrollView: UIScrollView?
    private var addedInset: CGFloat = 0
    private var revealing = false
    public var onChange: (() -> Void)?

    public override init() {
        super.init()
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func changed(_ note: Notification) {
        screenFrame = note.name == UIResponder.keyboardWillHideNotification ? nil
            : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        if screenFrame == nil { reset() }
        onChange?()
    }

    /// A horizontal band above an intersecting keyboard, in the same coordinate space as `bounds`.
    public static func viewport(_ bounds: CGRect, keyboard: CGRect?) -> CGRect {
        guard let keyboard, !keyboard.isEmpty, bounds.intersects(keyboard) else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                      height: max(0, min(bounds.maxY, keyboard.minY) - bounds.minY))
    }

    /// Clamp both size and origin; callers put oversized content in a scroll view inside the returned frame.
    public static func fitting(_ proposed: CGRect, in viewport: CGRect, margin: CGFloat = NibSpacing.l) -> CGRect {
        let m = min(margin, max(0, min(viewport.width, viewport.height) / 2))
        let safe = viewport.insetBy(dx: m, dy: m)
        let size = CGSize(width: min(proposed.width, safe.width), height: min(proposed.height, safe.height))
        return CGRect(x: min(max(proposed.minX, safe.minX), safe.maxX - size.width),
                      y: min(max(proposed.minY, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }

    public func keyboard(in window: UIWindow) -> CGRect? {
        screenFrame.map { window.convert($0, from: window.screen.coordinateSpace) }
    }

    /// All returned coordinates belong to `window`, including its safe area.
    public func viewport(in window: UIWindow) -> CGRect {
        Self.viewport(window.bounds.inset(by: window.safeAreaInsets), keyboard: keyboard(in: window))
    }

    /// Reveal an editor or caret by scrolling its canvas. Pass a rect in `view` coordinates; this method
    /// compares it with the keyboard and scroll viewport in window coordinates, then converts the delta back.
    public func reveal(_ rect: CGRect, in view: UIView, scrolling scroll: UIScrollView) {
        guard !revealing, let window = scroll.window, view.window === window else { return }
        revealing = true
        defer { revealing = false }
        if scrollView !== scroll { reset(); scrollView = scroll }
        let bounds = scroll.convert(scroll.bounds, to: window).intersection(window.bounds.inset(by: window.safeAreaInsets))
        guard !bounds.isNull, !bounds.isEmpty else { return }
        let visible = Self.viewport(bounds, keyboard: keyboard(in: window))
        let origin = scroll.convert(CGPoint.zero, from: window)
        let bottom = scroll.convert(CGPoint(x: 0, y: max(0, bounds.maxY - visible.maxY)), from: window)
        let inset = max(0, bottom.y - origin.y)
        scroll.contentInset.bottom += inset - addedInset
        addedInset = inset
        guard inset > 0, visible.height > 2 * NibSpacing.l else { return }
        let target = view.convert(rect, to: window)
        let fitted = Self.fitting(target, in: visible)
        let delta = target.minY - fitted.minY
        guard abs(delta) > 0.5 else { return }
        let offsetOrigin = scroll.convert(CGPoint.zero, from: window)
        let shifted = scroll.convert(CGPoint(x: 0, y: delta), from: window)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + shifted.y - offsetOrigin.y),
                                animated: false)
    }

    public func reset() {
        if let scroll = scrollView { scroll.contentInset.bottom -= addedInset }
        scrollView = nil
        addedInset = 0
    }
}
