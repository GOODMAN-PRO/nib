import XCTest
import NibContracts
import FeatMeetingAI

@MainActor
final class FeatMeetingAITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatMeetingAIFeature.id.isEmpty) }
}
