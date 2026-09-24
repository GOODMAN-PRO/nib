import XCTest
import NibContracts
import FeatCreate

@MainActor
final class FeatCreateTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCreateFeature.id.isEmpty) }
}
