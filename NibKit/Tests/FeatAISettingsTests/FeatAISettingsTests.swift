import XCTest
import NibContracts
import FeatAISettings

@MainActor
final class FeatAISettingsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAISettingsFeature.id.isEmpty) }
}
