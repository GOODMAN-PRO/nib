import XCTest
import NibContracts
import FeatWebDAV

@MainActor
final class FeatWebDAVTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatWebDAVFeature.id.isEmpty) }
}
