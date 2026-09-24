import XCTest
import NibContracts
import FeatLibraryUI

@MainActor
final class FeatLibraryUITests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLibraryUIFeature.id.isEmpty) }
}
