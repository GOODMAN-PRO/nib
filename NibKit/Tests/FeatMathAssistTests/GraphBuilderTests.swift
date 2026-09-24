import XCTest
import NibContracts
import FeatMathAssist

@MainActor
final class GraphBuilderTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatMathGraphFeature.id.isEmpty) }
}
