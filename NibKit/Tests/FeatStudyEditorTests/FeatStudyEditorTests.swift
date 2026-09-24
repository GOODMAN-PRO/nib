import XCTest
import NibContracts
import FeatStudyEditor

@MainActor
final class FeatStudyEditorTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatStudyEditorFeature.id.isEmpty) }
}
