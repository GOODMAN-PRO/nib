import XCTest
import NibContracts
import FeatAudio

@MainActor
final class FeatAudioTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAudioFeature.id.isEmpty) }
}
