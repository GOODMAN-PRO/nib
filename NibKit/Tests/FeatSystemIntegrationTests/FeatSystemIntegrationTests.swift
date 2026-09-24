import XCTest
import NibContracts
import FeatSystemIntegration

@MainActor
final class FeatSystemIntegrationTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSystemIntegrationFeature.id.isEmpty) }
}
