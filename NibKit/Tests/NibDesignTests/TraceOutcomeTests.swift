import XCTest
@testable import NibDesign

@MainActor
final class TraceOutcomeTests: XCTestCase {
    func testEveryToolOutcomeHasADistinctAccessibleValue() {
        let values = [NibTraceRow.Phase.running, .done, .warning].map(\.accessibilityValue)
        XCTAssertTrue(values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(values).count, 3, "Failed and completed tools must remain distinguishable without their icons")
    }
}
