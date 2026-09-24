import XCTest
import NibContracts
import NibRender

@MainActor
final class NibRenderTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibRenderFeature.id.isEmpty) }
}
