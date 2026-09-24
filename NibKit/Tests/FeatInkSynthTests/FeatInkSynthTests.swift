import XCTest
import NibContracts
import FeatInkSynth

@MainActor
final class FeatInkSynthTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatInkSynthFeature.id.isEmpty) }
}
