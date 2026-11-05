import XCTest
@testable import NibContracts
@testable import FeatQuery
import NibTesting

@MainActor
final class ItemUpdateContextTests: XCTestCase {
    func testNoOpInReadOnlyContextPreservesBaselineChecks() async throws {
        for dryRun in [false, true] {
            let h = Harness(features: [FeatQueryFeature.self])
            let ctx = CommandContext(bus: h.app.bus, principal: .user, group: "noop", depth: 0,
                                     dryRun: dryRun, session: nil, commandID: "item.update",
                                     title: "Update Item", readOnly: true)
            let old = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            let text = try XCTUnwrap(old.text?.text)
            let ref = NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.textID).description
            let patches: [JSONValue] = [[:], ["text": try JSONValue.from(text)]]
            for patch in patches {
                let result = try await ItemUpdate.run(.init(ref: ref, patch: patch, expectedText: text), ctx)
                XCTAssertFalse(result.changed)
                XCTAssertEqual(result.bbox, old.bounds)
            }
            do {
                _ = try await ItemUpdate.run(.init(ref: ref, patch: [:], expectedText: RichText(plain: "stale")), ctx)
                XCTFail("A no-op must still reject a stale baseline")
            } catch let error as NibError {
                XCTAssertEqual(error.code, .conflict)
            }
            do {
                _ = try await ItemUpdate.run(.init(ref: ref, patch: ["text": "changed"], expectedText: text), ctx)
                XCTFail("A real write must still require permission")
            } catch let error as NibError {
                XCTAssertEqual(error.code, .permissionDenied)
            }
            XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID), old)
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        }
    }
}
