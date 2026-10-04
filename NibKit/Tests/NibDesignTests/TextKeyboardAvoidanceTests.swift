import XCTest
import UIKit
import SwiftUI
@testable import NibDesign

@MainActor
final class TextKeyboardAvoidanceTests: XCTestCase {
    private final class EditingTextView: UITextView {
        override var isFirstResponder: Bool { true }
    }

    func testEndingEditingRestoresTemporaryKeyboardScroll() {
        checkKeyboardScrollRestoration(userPanned: false)
    }

    func testEndingEditingPreservesTheUsersSubsequentPan() {
        checkKeyboardScrollRestoration(userPanned: true)
    }

    private func checkKeyboardScrollRestoration(userPanned: Bool) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 800, height: 2000)
        scroll.contentInset.bottom = 24
        scroll.contentOffset = CGPoint(x: 0, y: 40)
        controller.view.addSubview(scroll)
        let text = EditingTextView(frame: CGRect(x: 100, y: 750, width: 300, height: 100))
        text.text = "Caret"
        text.selectedRange = NSRange(location: 5, length: 0)
        scroll.addSubview(text)
        text.layoutIfNeeded()
        let original = scroll.contentOffset
        let avoidance = NibTextKeyboardAvoidance(textView: text, scrollView: scroll)
        let keyboard = window.convert(CGRect(x: 0, y: 500, width: 800, height: 500),
                                      to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard)])
        XCTAssertGreaterThan(scroll.contentOffset.y, 0, "Editing must reveal the covered caret")
        if userPanned { scroll.contentOffset.y += 40 }
        let expected = userPanned ? scroll.contentOffset : original
        avoidance.stop()
        XCTAssertEqual(scroll.contentOffset, expected)
        XCTAssertEqual(scroll.contentInset.bottom, 24, "Only the keyboard's added inset is removed")
    }

    func testKeyboardRestorationAllowsPixelRoundingButPreservesUserPan() {
        XCTAssertTrue(NibTextKeyboardAvoidance.canRestore(current: CGPoint(x: -352, y: 137.5),
            adjusted: CGPoint(x: -352, y: 137.499999999)))
        XCTAssertFalse(NibTextKeyboardAvoidance.canRestore(current: CGPoint(x: -352, y: 177.5),
            adjusted: CGPoint(x: -352, y: 137.5)))
        XCTAssertFalse(NibTextKeyboardAvoidance.canRestore(current: .zero, adjusted: nil))
    }

    func testNativeTimelineScrubbingUpdatesBoundValue() {
        var value = 0.0
        let binding = Binding(get: { value }, set: { value = $0 })
        let coordinator = NibTimelineSlider.Coordinator(value: binding)
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 20
        slider.value = 15
        coordinator.changed(slider)
        XCTAssertEqual(value, 15)
    }

    func testFullscreenKeyboardFrameAlreadyInSceneOrientationIsNotRotatedAgain() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        let frame = CGRect(x: 0, y: 535, width: 1376, height: 497)
        XCTAssertEqual(NibKeyboardGeometry.frame(frame, in: window), frame)
    }

    func testToolPopoverViewportEndsAboveKeyboard() {
        let bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let keyboard = CGRect(x: 0, y: 535, width: 1376, height: 497)
        XCTAssertEqual(NibKeyboardViewport.available(in: bounds, keyboard: keyboard),
                       CGRect(x: 0, y: 0, width: 1376, height: 535))
        XCTAssertEqual(NibKeyboardViewport.available(in: bounds, keyboard: nil), bounds)
        XCTAssertEqual(NibKeyboardViewport.available(in: bounds, keyboard: keyboard.offsetBy(dx: 0, dy: 1032)), bounds)
    }

    func testCoveredCaretMovesAboveKeyboardWithPadding() {
        XCTAssertEqual(NibTextKeyboardAvoidance.verticalShift(
            caret: CGRect(x: 640, y: 700, width: 2, height: 24),
            keyboard: CGRect(x: 0, y: 535, width: 1376, height: 497), padding: 16), 205)
    }

    func testFloatingKeyboardDoesNotMoveUncoveredCaret() {
        XCTAssertEqual(NibTextKeyboardAvoidance.verticalShift(
            caret: CGRect(x: 100, y: 700, width: 2, height: 24),
            keyboard: CGRect(x: 600, y: 535, width: 400, height: 300), padding: 16), 0)
    }

    func testHiddenKeyboardAndVisibleCaretLeavePageStill() {
        let caret = CGRect(x: 100, y: 200, width: 2, height: 24)
        XCTAssertEqual(NibTextKeyboardAvoidance.verticalShift(caret: caret, keyboard: .null, padding: 16), 0)
        XCTAssertEqual(NibTextKeyboardAvoidance.verticalShift(caret: caret,
            keyboard: CGRect(x: 0, y: 535, width: 1376, height: 497), padding: 16), 0)
    }
}
