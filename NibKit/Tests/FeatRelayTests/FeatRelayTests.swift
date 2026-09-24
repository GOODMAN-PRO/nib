import XCTest
import NibContracts
import FeatRelay

@MainActor
final class FeatRelayTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatRelayFeature.id.isEmpty) }
}
