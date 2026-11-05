import Foundation
import XCTest
import NibContracts

final class SafeModeTests: XCTestCase {
    func testSafeModeRequiresTwoPreviousFailedLaunchesAndResetsAfterSuccess() {
        let defaults = UserDefaults.standard
        let key = "nib.safemode.pendingLaunches"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        SafeMode.beginLaunch()
        XCTAssertFalse(SafeMode.isActive, "The first launch has not failed")
        SafeMode.beginLaunch()
        XCTAssertFalse(SafeMode.isActive, "Only one previous launch failed")
        SafeMode.beginLaunch()
        XCTAssertTrue(SafeMode.isActive, "Two previous launches failed")
        SafeMode.endLaunch()
        XCTAssertFalse(SafeMode.isActive)
        SafeMode.beginLaunch()
        XCTAssertFalse(SafeMode.isActive, "A successful launch clears the failure streak")
    }
}
