import XCTest
import NibContracts
import FeatReplay

@MainActor
final class FeatReplayTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatReplayFeature.id.isEmpty) }
}
