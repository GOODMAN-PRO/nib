import XCTest
import NibContracts
import FeatWindows

@MainActor
final class FeatWindowsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatWindowsFeature.id.isEmpty) }
}
