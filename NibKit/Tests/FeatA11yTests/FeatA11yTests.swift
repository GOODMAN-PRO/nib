import XCTest
import NibContracts
import FeatA11y

@MainActor
final class FeatA11yTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatA11yFeature.id.isEmpty) }
}
