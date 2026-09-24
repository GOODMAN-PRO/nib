import XCTest
import NibContracts
import FeatSticky

@MainActor
final class FeatStickyTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatStickyFeature.id.isEmpty) }
}
