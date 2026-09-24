import XCTest
import NibContracts
import FeatSyncUI

@MainActor
final class FeatSyncUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSyncUIFeature.id.isEmpty) }
}
