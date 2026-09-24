import XCTest
import NibContracts
import FeatQuery

@MainActor
final class FeatQueryTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatQueryFeature.id.isEmpty) }
}
