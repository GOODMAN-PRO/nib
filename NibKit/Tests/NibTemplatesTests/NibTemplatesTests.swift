import XCTest
import NibContracts
import NibTemplates

@MainActor
final class NibTemplatesTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibTemplatesFeature.id.isEmpty) }
}
