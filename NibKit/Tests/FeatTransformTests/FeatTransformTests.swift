import XCTest
import NibContracts
import FeatTransform

@MainActor
final class FeatTransformTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTransformFeature.id.isEmpty) }
}
