import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatAbout

@MainActor
final class AboutEscapeTests: XCTestCase {
    func testRegisteredAboutPanelEscapeCallsItsRealDismissalContext() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let descriptor = try XCTUnwrap(h.app.ui.panels.get(PanelIDs.about))
        var presented = true
        var dismissals = 0
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {
            presented = false
            dismissals += 1
        })
        let before = try h.snapshot()
        let host = UIHostingController(rootView: descriptor.makeView(context))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
        XCTAssertFalse(presented)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(try h.snapshot(), before)
    }
}
