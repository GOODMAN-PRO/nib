import XCTest
import NibContracts
import FeatImport

@MainActor
final class FeatImportTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatImportFeature.id.isEmpty) }
}
