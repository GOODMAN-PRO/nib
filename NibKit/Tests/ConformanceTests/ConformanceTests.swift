import XCTest
import NibContracts
import NibTesting

/// Runs against EVERY feature module (AllFeatures.swift is generated from docs/forge-spec.json).
@MainActor
final class ConformanceTests: XCTestCase {
    func testEveryCommandConforms() async {
        // One pass over every registered command: about three minutes on CI, and it grows with the catalogue.
        // The package tests otherwise allow two minutes per test (ios.yml); the maximum there is five.
        executionTimeAllowance = 300
        let problems = await CommandConformance.check(features: AllFeatures.list)
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }

    func testFeatureIDsAreUnique() {
        let h = Harness(features: AllFeatures.list)
        XCTAssertEqual(Set(h.app.featureIDs).count, h.app.featureIDs.count)
    }
}
