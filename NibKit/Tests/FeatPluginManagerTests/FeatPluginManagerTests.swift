import XCTest
import NibContracts
import FeatPluginManager

@MainActor
final class FeatPluginManagerTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPluginManagerFeature.id.isEmpty) }
}
