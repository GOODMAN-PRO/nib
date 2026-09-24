import XCTest
import NibContracts
import FeatLock

@MainActor
final class FeatLockTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLockFeature.id.isEmpty) }
}
