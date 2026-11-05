import XCTest
import SwiftUI
import UIKit
import NibDesign
import NibTesting
@testable import FeatSettings

@MainActor
final class SettingsEscapeTests: XCTestCase {
    func testEscapeClosesPushedSettingsInCompactAndRegularLayouts() async throws {
        for width in [CGFloat(390), 900] {
            let h = Harness(features: [FeatSettingsFeature.self])
            let root = SettingsRootViewController(app: h.app, initialPage: "settings.stylus")
            let previous = UIViewController()
            let navigation = UINavigationController(rootViewController: previous)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            defer {
                navigation.setViewControllers([previous], animated: false)
                window.isHidden = true
                window.rootViewController = nil
            }
            // Package tests have no UIWindowScene for modal presentation. Exercise
            // Done's supported navigation-pop path with a real hosted Settings screen.
            navigation.pushViewController(root, animated: false)
            for _ in 0..<10 { navigation.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(navigation.topViewController === root)
            XCTAssertTrue(NibEscapeRouting.cancel(in: navigation.view))
            XCTAssertTrue(navigation.topViewController === previous, "Escape must use Done's actual controller close")
            XCTAssertEqual(navigation.viewControllers.count, 1)
        }
    }
}
