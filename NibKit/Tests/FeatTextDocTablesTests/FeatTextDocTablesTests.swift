import XCTest
import NibContracts
import FeatTextDocTables

@MainActor
final class FeatTextDocTablesTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatTextDocTablesFeature.id.isEmpty) }
}
