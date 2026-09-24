import XCTest
import NibContracts
import FeatKeyboard

@MainActor
final class FeatKeyboardTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatKeyboardFeature.id.isEmpty) }
}
