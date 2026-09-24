import XCTest
import NibContracts
import FeatOutline

@MainActor
final class FeatOutlineTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatOutlineFeature.id.isEmpty) }
}
