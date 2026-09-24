import XCTest
import NibContracts
import FeatCanvas

@MainActor
final class FeatCanvasTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCanvasFeature.id.isEmpty) }
}
