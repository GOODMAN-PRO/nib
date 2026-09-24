import XCTest
import NibContracts
import NibExport

@MainActor
final class NibExportTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibExportFeature.id.isEmpty) }
}
