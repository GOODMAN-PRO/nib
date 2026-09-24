import XCTest
import NibContracts
import FeatDocChrome

@MainActor
final class FeatDocChromeTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatDocChromeFeature.id.isEmpty) }
}
