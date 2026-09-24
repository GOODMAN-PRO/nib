import XCTest
import NibContracts
import FeatToolbar

@MainActor
final class FeatToolbarTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatToolbarFeature.id.isEmpty) }
}
