import XCTest
import NibContracts
import FeatLasso

@MainActor
final class FeatLassoTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLassoFeature.id.isEmpty) }
}
