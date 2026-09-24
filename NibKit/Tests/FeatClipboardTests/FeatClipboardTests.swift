import XCTest
import NibContracts
import FeatClipboard

@MainActor
final class FeatClipboardTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatClipboardFeature.id.isEmpty) }
}
