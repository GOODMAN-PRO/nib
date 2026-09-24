import XCTest
import NibContracts
import FeatReadOnly

@MainActor
final class FeatReadOnlyTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatReadOnlyFeature.id.isEmpty) }
}
