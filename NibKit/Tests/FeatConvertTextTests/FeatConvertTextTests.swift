import XCTest
import NibContracts
import FeatConvertText

@MainActor
final class FeatConvertTextTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatConvertTextFeature.id.isEmpty) }
}
