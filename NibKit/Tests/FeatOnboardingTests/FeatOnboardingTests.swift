import XCTest
import NibContracts
import FeatOnboarding

@MainActor
final class FeatOnboardingTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatOnboardingFeature.id.isEmpty) }
}
