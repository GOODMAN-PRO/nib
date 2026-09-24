import XCTest
import NibContracts
import FeatScan

@MainActor
final class FeatScanTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatScanFeature.id.isEmpty) }
}
