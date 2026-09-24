import XCTest
import NibContracts
import FeatAIActions

@MainActor
final class FeatAIActionsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAIActionsFeature.id.isEmpty) }
}
