import XCTest
import NibContracts
import FeatZoomWindow

@MainActor
final class FeatZoomWindowTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatZoomWindowFeature.id.isEmpty) }
}
