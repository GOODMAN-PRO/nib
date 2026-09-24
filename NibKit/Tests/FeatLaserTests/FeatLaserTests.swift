import XCTest
import NibContracts
import FeatLaser

@MainActor
final class FeatLaserTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLaserFeature.id.isEmpty) }
}
