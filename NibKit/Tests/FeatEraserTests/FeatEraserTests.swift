import XCTest
import NibContracts
import FeatEraser

@MainActor
final class FeatEraserTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatEraserFeature.id.isEmpty) }
}
