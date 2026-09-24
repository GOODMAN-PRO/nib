import XCTest
import NibContracts
import FeatMathAssist

@MainActor
final class MathAssistWatcherTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatMathAssistOverlayFeature.id.isEmpty) }
}
