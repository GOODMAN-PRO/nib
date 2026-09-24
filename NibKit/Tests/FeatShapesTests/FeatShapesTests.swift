import XCTest
import NibContracts
import FeatShapes

@MainActor
final class FeatShapesTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatShapesFeature.id.isEmpty) }
}
