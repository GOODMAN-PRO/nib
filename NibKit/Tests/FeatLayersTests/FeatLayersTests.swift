import XCTest
import NibContracts
import FeatLayers

@MainActor
final class FeatLayersTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLayersFeature.id.isEmpty) }
}
