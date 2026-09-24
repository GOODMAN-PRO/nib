import XCTest
import NibContracts
import FeatTextDoc

@MainActor
final class BlockCommentTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTextDocExtrasFeature.id.isEmpty) }
}
