import XCTest
import NibContracts
import FeatTape

@MainActor
final class FeatTapeTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTapeFeature.id.isEmpty) }
}
