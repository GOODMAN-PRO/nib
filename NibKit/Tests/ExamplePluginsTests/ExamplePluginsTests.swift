import XCTest
import NibContracts

@MainActor
final class ExamplePluginsTests: XCTestCase {
    func testTargetBuilds() { XCTAssertFalse(NibFormat.packageExtension.isEmpty) }
}
