import XCTest
import NibContracts
import NibTesting

/// Runs against EVERY feature module (AllFeatures.swift is generated from docs/forge-spec.json).
@MainActor
final class ConformanceTests: XCTestCase {
    func testEveryCommandConforms() async {
        let problems = await CommandConformance.check(features: AllFeatures.list)
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }

    func testFeatureIDsAreUnique() {
        let h = Harness(features: AllFeatures.list)
        XCTAssertEqual(Set(h.app.featureIDs).count, h.app.featureIDs.count)
    }
}
