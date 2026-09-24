import XCTest
import NibContracts
import FeatCollab

@MainActor
final class FeatCollabTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCollabFeature.id.isEmpty) }
}
