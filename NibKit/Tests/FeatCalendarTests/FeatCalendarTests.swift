import XCTest
import NibContracts
import FeatCalendar

@MainActor
final class FeatCalendarTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCalendarFeature.id.isEmpty) }
}
