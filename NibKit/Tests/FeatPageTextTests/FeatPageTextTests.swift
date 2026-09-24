import XCTest
import NibContracts
import FeatPageText

@MainActor
final class FeatPageTextTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPageTextFeature.id.isEmpty) }
}
