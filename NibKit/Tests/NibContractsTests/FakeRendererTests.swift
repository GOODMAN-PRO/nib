import XCTest
import NibContracts
import NibTesting

final class FakeRendererTests: XCTestCase {
    func testConcurrentRendersAndInvalidationsPreserveEveryRequest() async throws {
        let renderer = FakeRenderer()
        renderer.marks = ["answer": "A"]
        let count = 128
        let region = Rect(x: 0, y: 0, width: 8, height: 6)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let page = PageID("RENDER\(index)")
                    let result = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: page,
                                                                        region: region, scale: 1, marks: true))
                    XCTAssertEqual(result.image.width, 8)
                    XCTAssertEqual(result.image.height, 6)
                    XCTAssertEqual(result.marks, ["answer": "A"])
                    renderer.invalidate(doc: Fixtures.docID, page: page, rect: region)
                    // Read snapshots while other tasks are still appending.
                    XCTAssertFalse(renderer.requests.isEmpty)
                    XCTAssertFalse(renderer.invalidations.isEmpty)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(renderer.requests.count, count)
        XCTAssertEqual(Set(renderer.requests.map(\.page)).count, count)
        XCTAssertEqual(renderer.invalidations.count, count)
        XCTAssertEqual(Set(renderer.invalidations.map { $0.1 }).count, count)
    }
}
