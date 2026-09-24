import XCTest
import NibContracts
import FeatSearchUI

@MainActor
final class FeatSearchUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSearchUIFeature.id.isEmpty) }
}
