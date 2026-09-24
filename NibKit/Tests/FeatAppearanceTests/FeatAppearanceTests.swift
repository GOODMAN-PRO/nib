import XCTest
import NibContracts
import FeatAppearance

@MainActor
final class FeatAppearanceTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAppearanceFeature.id.isEmpty) }
}
