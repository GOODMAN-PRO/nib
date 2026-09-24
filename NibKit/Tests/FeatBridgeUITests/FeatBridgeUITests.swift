import XCTest
import NibContracts
import FeatBridgeUI

@MainActor
final class FeatBridgeUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatBridgeUIFeature.id.isEmpty) }
}
