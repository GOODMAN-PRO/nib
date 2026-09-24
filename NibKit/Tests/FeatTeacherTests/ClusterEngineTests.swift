import XCTest
import NibContracts
import FeatTeacher

@MainActor
final class ClusterEngineTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTeacherInsightsFeature.id.isEmpty) }
}
