import XCTest
import NibContracts
import FeatWhiteboard

@MainActor
final class FeatWhiteboardTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatWhiteboardFeature.id.isEmpty) }
}
