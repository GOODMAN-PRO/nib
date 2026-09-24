import XCTest
import NibContracts
import FeatPerformance

@MainActor
final class FeatPerformanceTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatPerformanceFeature.id.isEmpty) }
}
