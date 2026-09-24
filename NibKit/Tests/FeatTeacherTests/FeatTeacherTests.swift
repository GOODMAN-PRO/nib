import XCTest
import NibContracts
import FeatTeacher

@MainActor
final class FeatTeacherTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTeacherFeature.id.isEmpty) }
}
