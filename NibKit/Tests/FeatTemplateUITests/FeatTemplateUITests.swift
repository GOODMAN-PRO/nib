import XCTest
import NibContracts
import FeatTemplateUI

@MainActor
final class FeatTemplateUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTemplateUIFeature.id.isEmpty) }
}
