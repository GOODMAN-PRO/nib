import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class PaperTileInteractionTests: XCTestCase {
    func testPaperTilesRouteIndependentTapsAndYieldToTheirScrollPan() async throws {
        var selections: [String] = []
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: 16) {
                HStack {
                    ForEach(["Daily Planner", "Event Planner"], id: \.self) { name in
                        NibPaperTile(name: name, isSelected: false, action: { selections.append(name) }) {
                            Color.white
                        }
                    }
                }
                Color.clear.frame(height: 600)
            }
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(window)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first)
        let actions = views.flatMap { $0.gestureRecognizers ?? [] }.compactMap { $0 as? NibActionTapRecognizer }
        XCTAssertEqual(actions.count, 2)
        for action in actions {
            let target = try XCTUnwrap(action.view)
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: window)
            let hit = try XCTUnwrap(window.hitTest(point, with: nil))
            XCTAssertTrue(hit.isDescendant(of: target), "Each preview must own its visible tap target")
            XCTAssertTrue(action.canBePrevented(by: scroll.panGestureRecognizer),
                          "Dragging the chooser must cancel a preview tap")
            let count = selections.count
            action.activate()
            XCTAssertEqual(selections.count, count + 1)
        }
        XCTAssertEqual(Set(selections), ["Daily Planner", "Event Planner"])
        scroll.setContentOffset(CGPoint(x: 0, y: 220), animated: false)
        scroll.layoutIfNeeded()
        XCTAssertEqual(selections.count, 2, "Scrolling must preserve the chosen paper")
    }
}
