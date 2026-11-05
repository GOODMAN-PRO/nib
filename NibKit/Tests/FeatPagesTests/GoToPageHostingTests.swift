import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatPages

@MainActor
final class GoToPageHostingTests: XCTestCase {
    func testBothJumpControlsCanScrollAboveLandscapeKeyboardWithLongMatch() async throws {
        let h = Harness(features: [FeatPagesFeature.self])
        let doc: DocumentID = "LANDSCAPE"
        let title = "Matching title " + String(repeating: "with a long explanation of the chapter contents ", count: 20)
        let content = DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: [
            PageRecord(id: "FIRST", order: "A", title: title), PageRecord(id: "LAST", order: "V")
        ])
        _ = try h.library.createDocument(content, title: "Landscape", in: nil)
        _ = try h.app.workspace.content(doc)
        h.session.document = doc
        h.session.page = "FIRST"
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        var frames: [String: CGRect] = [:]
        let dialog = GoToPageDialog(context: context, initialInput: "Matching", focusesField: false,
                                    onJumpFrames: { frames = $0 })
        let host = UIHostingController(rootView: dialog.environment(\.dynamicTypeSize, .large))
        host.safeAreaRegions = []
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 667, height: 375))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        // The keyboard occupies the bottom 216 points; give the sheet exactly the remaining viewport.
        host.view.frame = CGRect(x: 0, y: 0, width: 667, height: 159)
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        try await waitUntil {
            host.view.layoutIfNeeded()
            return frames.count == 2 && scrollViews(host.view).contains { $0.contentSize.height > $0.bounds.height }
        }
        let scroll = try XCTUnwrap(scrollViews(host.view).first { $0.contentSize.height > $0.bounds.height })
        let viewport = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertTrue(frames.values.contains { $0.maxY > 159 }, "the matching title must actually overflow")
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        try await waitUntil {
            host.view.layoutIfNeeded()
            return ["first", "last"].allSatisfy { id in
                guard let frame = frames[id] else { return false }
                return viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            }
        }
        for id in ["first", "last"] {
            let frame = try XCTUnwrap(frames[id])
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, 159.5)
            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(id) clears the fixed header too")
            let hit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
            XCTAssertTrue(hit === host.view || hit.isDescendant(of: host.view), "\(id) is hittable above the keyboard")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition() {
            guard Date() < deadline else { XCTFail("hosting layout did not settle within one second"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
