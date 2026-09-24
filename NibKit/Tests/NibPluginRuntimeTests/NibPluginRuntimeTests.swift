import XCTest
import NibContracts
import NibPluginRuntime

@MainActor
final class NibPluginRuntimeTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibPluginRuntimeFeature.id.isEmpty) }
}
