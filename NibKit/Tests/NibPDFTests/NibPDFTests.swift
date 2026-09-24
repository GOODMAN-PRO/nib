import XCTest
import NibContracts
import NibPDF

@MainActor
final class NibPDFTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibPDFFeature.id.isEmpty) }
}
