import XCTest
import NibContracts
import FeatInkSynth

@MainActor
final class RestylerTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatRestyleFeature.id.isEmpty) }
}
