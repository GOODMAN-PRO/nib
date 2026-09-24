import XCTest
import NibContracts
import FeatSettings

@MainActor
final class FeatSettingsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSettingsFeature.id.isEmpty) }
}
