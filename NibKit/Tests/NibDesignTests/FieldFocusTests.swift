import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class FieldFocusTests: XCTestCase {
    func testSingleLineFormKeepsNativeFocusAndTextAcrossKeyboardResize() async throws {
        var value = ""
        let binding = Binding(get: { value }, set: { value = $0 })
        let host = UIHostingController(rootView: NibField(text: binding, prompt: "Page")
            .keyboardType(.numbersAndPunctuation).submitLabel(.go)
            .padding(20))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 410, height: 368))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let field = try XCTUnwrap(find(UITextField.self, in: host.view),
                                  "One-line entries must use native single-line editing")
        XCTAssertNil(find(UITextView.self, in: host.view))
        XCTAssertEqual(field.returnKeyType, .go)
        XCTAssertTrue(field.becomeFirstResponder())
        // These are hostless package tests (no UIApplicationMain). UIKit cannot
        // dispatch control actions through UIApplication, so deliver the real
        // registered editing-change actions directly to SwiftUI's coordinator.
        field.text = "3"
        var deliveredChange = false
        field.enumerateEventHandlers { action, target, selector, events, _ in
            guard events.contains(.editingChanged) else { return }
            if let action {
                field.sendAction(action)
                deliveredChange = true
            } else if let receiver = target as? NSObject, let selector {
                _ = receiver.perform(selector, with: field)
                deliveredChange = true
            }
        }
        XCTAssertTrue(deliveredChange, "Missing native binding action: \(field.allTargets), events: \(field.allControlEvents)")
        try await settle(host)
        XCTAssertEqual(value, "3")
        for height in [CGFloat(240), CGFloat(368)] {
            host.view.frame.size.height = height
            try await settle(host)
            XCTAssertTrue(find(UITextField.self, in: host.view) === field)
            XCTAssertTrue(field.isFirstResponder, "Keyboard-driven relayout must not replace the focused editor")
            XCTAssertEqual(field.text, "3")
        }
    }

    func testMultilineComposerRetainsNewlineEditing() async throws {
        var value = ""
        let host = UIHostingController(rootView: NibField(
            text: Binding(get: { value }, set: { value = $0 }), prompt: "Message", lines: 1...5))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 410, height: 368))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let field = try XCTUnwrap(find(UITextView.self, in: host.view))
        XCTAssertTrue(field.becomeFirstResponder())
        field.insertText("First\nSecond")
        try await settle(host)
        XCTAssertEqual(value, "First\nSecond", "Growing composers must keep multiline behaviour")
    }

    private func settle(_ host: UIViewController) async throws {
        for _ in 0..<5 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}
