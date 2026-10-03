import UIKit

/// Keeps an in-place canvas editor's caret above the native keyboard. The keyboard
/// notification uses screen coordinates, which must be converted through this window.
@MainActor
public final class NibTextKeyboardAvoidance: NSObject {
    private weak var textView: UITextView?
    private weak var scrollView: UIScrollView?
    private var keyboard: CGRect?
    private var addedInset: CGFloat = 0
    private var originalOffset: CGPoint?
    private var adjustedOffset: CGPoint?
    private var adjustedZoom: CGFloat?

    public init(textView: UITextView, scrollView: UIScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// An explicit completion action for touch-only devices, alongside native text formatting.
    public static func finishAccessory(_ finish: @escaping () -> Void) -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { _ in finish() })
        done.accessibilityLabel = String(localized: "Finish Editing")
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        return bar
    }

    public func stop() {
        NotificationCenter.default.removeObserver(self)
        clearInset()
        keyboard = nil
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        keyboard = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        revealCaret()
    }

    @objc private func keyboardHidden(_ notification: Notification) {
        keyboard = nil
        clearInset()
    }

    public func revealCaret() {
        guard let textView, textView.isFirstResponder, let scrollView,
              let window = textView.window, let keyboard,
              let position = textView.selectedTextRange?.end else { return }
        let covered = window.convert(keyboard, from: window.screen.coordinateSpace).intersection(window.bounds)
        let caret = textView.convert(textView.caretRect(for: position), to: window)
        let shift = Self.verticalShift(caret: caret, keyboard: covered, padding: NibSpacing.l)
        guard shift > 0 else { return }
        let neededInset = covered.height
        let previous = scrollView.contentOffset
        if originalOffset == nil {
            originalOffset = previous
        }
        if neededInset > addedInset {
            scrollView.contentInset.bottom += neededInset - addedInset
            addedInset = neededInset
        }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
                                           y: scrollView.contentOffset.y + shift), animated: false)
        adjustedOffset = scrollView.contentOffset
        adjustedZoom = scrollView.zoomScale
    }

    static func verticalShift(caret: CGRect, keyboard: CGRect, padding: CGFloat) -> CGFloat {
        guard !keyboard.isNull, !keyboard.isEmpty, caret.maxX > keyboard.minX,
              caret.minX < keyboard.maxX, caret.maxY > keyboard.minY,
              caret.minY < keyboard.maxY else { return 0 }
        return max(0, caret.maxY + padding - keyboard.minY)
    }

    /// Layout rounds scroll offsets to the screen pixel grid after an adjustment.
    /// A sub-point rounding difference is not a user's subsequent pan.
    public static func canRestore(current: CGPoint, adjusted: CGPoint?) -> Bool {
        guard let adjusted else { return false }
        return abs(current.x - adjusted.x) < 1 && abs(current.y - adjusted.y) < 1
    }

    private func clearInset() {
        if let scrollView {
            let restore = Self.canRestore(current: scrollView.contentOffset, adjusted: adjustedOffset) && scrollView.zoomScale == adjustedZoom
            if addedInset > 0 { scrollView.contentInset.bottom -= addedInset }
            if restore, let originalOffset { scrollView.setContentOffset(originalOffset, animated: false) }
        }
        addedInset = 0
        originalOffset = nil
        adjustedOffset = nil
        adjustedZoom = nil
    }
}
