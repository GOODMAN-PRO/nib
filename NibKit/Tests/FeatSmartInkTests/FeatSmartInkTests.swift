import XCTest
import NibContracts
import FeatSmartInk

@MainActor
final class FeatSmartInkTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSmartInkFeature.id.isEmpty) }
}
