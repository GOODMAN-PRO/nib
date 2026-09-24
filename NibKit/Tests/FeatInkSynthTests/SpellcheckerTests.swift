import XCTest
import NibContracts
import FeatInkSynth

@MainActor
final class SpellcheckerTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSpellcheckFeature.id.isEmpty) }
}
