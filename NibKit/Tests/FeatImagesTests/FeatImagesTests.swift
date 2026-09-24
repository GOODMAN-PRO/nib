import XCTest
import NibContracts
import FeatImages

@MainActor
final class FeatImagesTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatImagesFeature.id.isEmpty) }
}
