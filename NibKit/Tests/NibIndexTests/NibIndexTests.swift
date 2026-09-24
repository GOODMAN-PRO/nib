import XCTest
import NibContracts
import NibIndex

@MainActor
final class NibIndexTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibIndexFeature.id.isEmpty) }
}
