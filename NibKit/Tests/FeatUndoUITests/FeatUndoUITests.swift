import XCTest
import NibContracts
import FeatUndoUI

@MainActor
final class FeatUndoUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatUndoUIFeature.id.isEmpty) }
}
