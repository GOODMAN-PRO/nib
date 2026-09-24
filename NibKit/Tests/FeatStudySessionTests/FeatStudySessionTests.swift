import XCTest
import NibContracts
import FeatStudySession

@MainActor
final class FeatStudySessionTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatStudySessionFeature.id.isEmpty) }
}
