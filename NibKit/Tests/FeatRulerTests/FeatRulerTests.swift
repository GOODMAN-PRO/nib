import XCTest
import NibContracts
import FeatRuler

@MainActor
final class FeatRulerTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatRulerFeature.id.isEmpty) }
}
