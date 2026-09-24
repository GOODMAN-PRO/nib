import XCTest
import NibContracts
import FeatElements

@MainActor
final class FeatElementsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatElementsFeature.id.isEmpty) }
}
