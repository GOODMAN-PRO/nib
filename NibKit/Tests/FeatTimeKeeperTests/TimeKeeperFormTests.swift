import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatTimeKeeper

@MainActor
final class TimeKeeperFormTests: XCTestCase {
    func testSavedModesDoNotPushTimerNameBelowTheInitialPanelViewport() async throws {
        let harness = Harness(features: [FeatTimeKeeperFeature.self])
        for index in 0..<20 {
            try await harness.run("timer.saveMode", ["name": .string("Study \(index)"), "seconds": 300])
        }
        let keeper = try XCTUnwrap(harness.app.services.get(TimeKeeper.serviceKey, as: TimeKeeper.self))
        let context = PanelContext(app: harness.app, session: harness.session, navigator: nil, dismiss: {})
        let host = UIHostingController(rootView: TimeKeeperPanel(keeper: keeper, context: context))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 344, height: 560))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<20 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        func fields(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let editors = fields(host.view)
        let name = try XCTUnwrap(editors.first { $0.placeholder == "Optional, such as Essay plan" })
        let mode = try XCTUnwrap(editors.first { $0.placeholder == "Mode name" })
        let nameFrame = name.convert(name.bounds, to: host.view)
        XCTAssertTrue(host.view.bounds.contains(nameFrame), "Naming the current timer stays visible even with many saved modes")
        XCTAssertLessThan(nameFrame.maxY, mode.convert(mode.bounds, to: host.view).minY)
    }
}
