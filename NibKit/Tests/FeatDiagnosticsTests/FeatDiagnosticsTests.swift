import XCTest
import NibContracts
import FeatDiagnostics

@MainActor
final class FeatDiagnosticsTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatDiagnosticsFeature.id.isEmpty) }
}
