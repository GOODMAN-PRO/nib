import XCTest
import NibContracts
import FeatLibraryOrganize

@MainActor
final class FeatLibraryOrganizeTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatLibraryOrganizeFeature.id.isEmpty) }
}
