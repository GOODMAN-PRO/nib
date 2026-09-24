import XCTest
import NibContracts
import FeatBackup

@MainActor
final class FeatBackupTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatBackupFeature.id.isEmpty) }
}
