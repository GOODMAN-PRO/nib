import XCTest
import NibContracts
import FeatComments

@MainActor
final class FeatCommentsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatCommentsFeature.id.isEmpty) }
}
