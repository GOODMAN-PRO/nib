import XCTest
import NibContracts
import NibAIProviders

@MainActor
final class NibAIProvidersTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibAIProvidersFeature.id.isEmpty) }
}
