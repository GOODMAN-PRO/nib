import XCTest
import NibContracts
import FeatManagedConfig

@MainActor
final class FeatManagedConfigTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatManagedConfigFeature.id.isEmpty) }
}
