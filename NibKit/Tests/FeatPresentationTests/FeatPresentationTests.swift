import XCTest
import NibContracts
import FeatPresentation

@MainActor
final class FeatPresentationTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPresentationFeature.id.isEmpty) }
}
