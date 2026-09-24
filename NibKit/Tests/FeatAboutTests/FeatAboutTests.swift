import XCTest
import NibContracts
import FeatAbout

@MainActor
final class FeatAboutTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatAboutFeature.id.isEmpty) }
}
