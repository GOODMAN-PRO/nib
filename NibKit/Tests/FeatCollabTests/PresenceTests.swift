import XCTest
import NibContracts
import FeatCollab

@MainActor
final class PresenceTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCollabPresenceFeature.id.isEmpty) }
}
