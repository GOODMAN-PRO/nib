import XCTest
import NibContracts
import FeatPresets

@MainActor
final class FeatPresetsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPresetsFeature.id.isEmpty) }
}
