import XCTest
import NibContracts
import FeatMath

@MainActor
final class FeatMathTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatMathFeature.id.isEmpty) }
}
