import XCTest
import NibContracts
import FeatSidebar

@MainActor
final class FeatSidebarTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatSidebarFeature.id.isEmpty) }
}
