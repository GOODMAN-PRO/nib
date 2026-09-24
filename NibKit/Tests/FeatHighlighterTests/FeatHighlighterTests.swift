import XCTest
import NibContracts
import FeatHighlighter

@MainActor
final class FeatHighlighterTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatHighlighterFeature.id.isEmpty) }
}
