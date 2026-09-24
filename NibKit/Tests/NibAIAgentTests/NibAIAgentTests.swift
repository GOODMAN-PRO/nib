import XCTest
import NibContracts
import NibAIAgent

@MainActor
final class NibAIAgentTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(NibAIAgentFeature.id.isEmpty) }
}
