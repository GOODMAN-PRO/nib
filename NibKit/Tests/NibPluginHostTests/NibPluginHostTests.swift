import XCTest
import NibContracts
import NibPluginHost

@MainActor
final class NibPluginHostTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibPluginHostFeature.id.isEmpty) }
}
