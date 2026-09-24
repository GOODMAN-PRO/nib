import XCTest
import NibContracts
import FeatTimeKeeper

@MainActor
final class FeatTimeKeeperTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTimeKeeperFeature.id.isEmpty) }
}
