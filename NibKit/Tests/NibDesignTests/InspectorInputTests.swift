import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class InspectorInputTests: XCTestCase {
    private func actions(in view: UIView) -> [UIButton] {
        let own = (view as? UIButton).map { $0.accessibilityIdentifier == "nib.inspector.touch" ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { actions(in: $0) }
    }

    func testSegmentTouchesReachTheirBoundSelection() async throws {
        var value = false
        let host = UIHostingController(rootView:
            NibSegmentedControl(selection: Binding(get: { value }, set: { value = $0 }), options: [false, true]) {
                $0 ? "Rounded" : "Sharp"
            }.frame(width: 260))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let controls = actions(in: host.view).filter { $0.window != nil && !$0.bounds.isEmpty }
        XCTAssertGreaterThanOrEqual(controls.count, 2)
        let ordered = controls.sorted {
            $0.convert(CGPoint.zero, to: host.view).x < $1.convert(CGPoint.zero, to: host.view).x
        }
        let rounded = try XCTUnwrap(ordered.last)
        let target = rounded
        let centre = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: host.view)
        XCTAssertTrue(host.view.hitTest(centre, with: nil)?.isDescendant(of: target) == true)
        rounded.sendActions(for: .touchUpInside)
        XCTAssertTrue(value, "The native touch route must update the shape-style binding")
        try XCTUnwrap(ordered.first).sendActions(for: .touchUpInside)
        XCTAssertFalse(value)
    }

    func testInspectorHeaderActionReceivesTouchAndHonoursDisabledState() async throws {
        var saves = 0
        func content(_ enabled: Bool) -> some View {
            NibInspectorSection("Style", action: NibAction("Save Style…") { saves += 1 }) {
                Text("Body")
            }.frame(width: 260).disabled(!enabled)
        }
        let host = UIHostingController(rootView: content(true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for enabled in [true, false, true] {
            host.rootView = content(enabled)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let tap = try XCTUnwrap(actions(in: host.view).first)
            XCTAssertEqual(tap.isEnabled, enabled)
            if enabled { tap.sendActions(for: .touchUpInside) }
        }
        XCTAssertEqual(saves, 2)
    }
}
