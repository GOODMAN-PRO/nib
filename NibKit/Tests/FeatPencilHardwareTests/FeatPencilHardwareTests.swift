import XCTest
import NibContracts
import FeatPencilHardware

@MainActor
final class FeatPencilHardwareTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPencilHardwareFeature.id.isEmpty) }
}
