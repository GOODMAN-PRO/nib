import XCTest
import NibContracts
import NibSync

@MainActor
final class NibSyncTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibSyncFeature.id.isEmpty) }
}
