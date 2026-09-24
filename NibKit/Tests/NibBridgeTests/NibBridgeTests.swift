import XCTest
import NibContracts
import NibBridge

@MainActor
final class NibBridgeTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibBridgeFeature.id.isEmpty) }
}
