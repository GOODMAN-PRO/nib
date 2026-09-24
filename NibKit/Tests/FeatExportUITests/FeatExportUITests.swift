import XCTest
import NibContracts
import FeatExportUI

@MainActor
final class FeatExportUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatExportUIFeature.id.isEmpty) }
}
