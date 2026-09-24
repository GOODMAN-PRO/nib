import XCTest
import NibContracts
import FeatAIMath

@MainActor
final class FeatAIMathTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAIMathFeature.id.isEmpty) }
}
