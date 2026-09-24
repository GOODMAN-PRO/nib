import XCTest
import NibContracts
import FeatDiagrams

@MainActor
final class FeatDiagramsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatDiagramsFeature.id.isEmpty) }
}
