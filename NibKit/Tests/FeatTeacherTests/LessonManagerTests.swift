import XCTest
import NibContracts
import FeatTeacher

@MainActor
final class LessonManagerTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTeacherLessonsFeature.id.isEmpty) }
}
