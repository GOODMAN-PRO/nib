import XCTest
import NibContracts
import FeatPages

@MainActor
final class FeatPagesTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPagesFeature.id.isEmpty) }
}
