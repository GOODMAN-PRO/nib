import XCTest
import NibContracts
import FeatTextDoc

@MainActor
final class SlashMenuTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTextDocEditingFeature.id.isEmpty) }
}
