import XCTest
import NibContracts
import FeatCanvas

@MainActor
final class CanvasInputTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCanvasInputFeature.id.isEmpty) }
}
