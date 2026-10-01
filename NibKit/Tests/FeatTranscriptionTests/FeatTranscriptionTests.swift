import XCTest
import NibContracts
import FeatTranscription

@MainActor
final class FeatTranscriptionTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTranscriptionFeature.id.isEmpty) }
}
