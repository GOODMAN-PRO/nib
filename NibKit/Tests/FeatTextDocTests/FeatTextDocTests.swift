import XCTest
import NibContracts
import FeatTextDoc

@MainActor
final class FeatTextDocTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTextDocFeature.id.isEmpty) }
}
