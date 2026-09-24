import XCTest
import NibContracts
import FeatTextBox

@MainActor
final class FeatTextBoxTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTextBoxFeature.id.isEmpty) }
}
