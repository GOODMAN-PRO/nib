import XCTest
import NibContracts

@MainActor
final class IntegrationTests: XCTestCase {
    func testTargetBuilds() { XCTAssertFalse(NibFormat.packageExtension.isEmpty) }
}
