import XCTest
import NibContracts
import FeatAIChat

@MainActor
final class FeatAIChatTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAIChatFeature.id.isEmpty) }
}
