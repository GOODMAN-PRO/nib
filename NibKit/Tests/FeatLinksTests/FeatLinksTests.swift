import XCTest
import NibContracts
import FeatLinks

@MainActor
final class FeatLinksTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLinksFeature.id.isEmpty) }
}
