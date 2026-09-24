import XCTest
import NibContracts
import NibLibrary

@MainActor
final class NibLibraryTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibLibraryFeature.id.isEmpty) }
}
