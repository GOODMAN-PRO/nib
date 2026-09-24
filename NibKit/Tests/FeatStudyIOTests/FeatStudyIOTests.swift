import XCTest
import NibContracts
import FeatStudyIO

@MainActor
final class FeatStudyIOTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatStudyIOFeature.id.isEmpty) }
}
