import XCTest
import NibContracts
import FeatMathAssist

@MainActor
final class FeatMathAssistTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatMathAssistFeature.id.isEmpty) }
}
