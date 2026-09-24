import XCTest
import NibContracts
import FeatObjectMenu

@MainActor
final class FeatObjectMenuTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatObjectMenuFeature.id.isEmpty) }
}
