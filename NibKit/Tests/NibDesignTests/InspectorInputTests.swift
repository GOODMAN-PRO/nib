import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class InspectorInputTests: XCTestCase {
    private func actions(in view: UIView) -> [NibActionTapRecognizer] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? NibActionTapRecognizer }
            + view.subviews.flatMap { actions(in: $0) }
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
        let controls = actions(in: host.view).filter { $0.view?.window != nil && $0.view?.bounds.isEmpty == false }
        XCTAssertGreaterThanOrEqual(controls.count, 2)
        let ordered = controls.sorted {
            ($0.view?.convert(CGPoint.zero, to: host.view).x ?? 0) < ($1.view?.convert(CGPoint.zero, to: host.view).x ?? 0)
        }
        let rounded = try XCTUnwrap(ordered.last)
        let target = try XCTUnwrap(rounded.view)
        let centre = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: host.view)
        XCTAssertTrue(host.view.hitTest(centre, with: nil)?.isDescendant(of: target) == true)
        rounded.activate()
        XCTAssertTrue(value, "The native touch route must update the shape-style binding")
        try XCTUnwrap(ordered.first).activate()
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
            if enabled { tap.activate() }
        }
        XCTAssertEqual(saves, 2)
    }
}
