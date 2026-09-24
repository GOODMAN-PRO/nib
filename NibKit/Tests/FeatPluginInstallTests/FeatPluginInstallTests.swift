import XCTest
import NibContracts
import FeatPluginInstall

@MainActor
final class FeatPluginInstallTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPluginInstallFeature.id.isEmpty) }
}
