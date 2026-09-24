import XCTest
import NibContracts
import NibStore

@MainActor
final class NibStoreTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibStoreFeature.id.isEmpty) }
}
