import XCTest
import NibContracts
import FeatPluginPanels

@MainActor
final class FeatPluginPanelsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPluginPanelsFeature.id.isEmpty) }
}
