import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatCanvas

@MainActor
final class InkNavigationTests: XCTestCase {
    func testAcceptedStrokeCommitsAfterItsCanvasIsReleased() async throws {
        let harness = Harness(features: [FeatCanvasInputFeature.self])
        defer { try? FileManager.default.removeItem(at: harness.persistence.root) }
        harness.app.commands.register(CommandDescriptor(
            id: CommandIDs.inkAddStrokes, title: "Add Ink", summary: "Commit captured ink.",
            params: .obj(["page": .ref, "strokes": .arr(.anything())], required: ["page", "strokes"]),
            examples: [], effect: .edit)) { params, ctx in
                guard case let .page(doc, page)? = NodeRef(params["page"]?.stringValue ?? "") else {
                    throw NibError.notFound("page")
                }
                let strokes = try XCTUnwrap(params["strokes"]).decode([Stroke].self)
                let items = try ctx.mutate { tx in
                    try tx.put(strokes.map { Item.makeStroke($0) }, doc: doc, page: page)
                }
                return ["refs": .array(items.map { .string(NodeRef.item(doc, page, $0.id).description) })]
            }
        let before = try harness.app.workspace.items(Fixtures.docID, page: Fixtures.page2).count
        var host: CanvasHostImpl? = CanvasHostImpl(app: harness.app, session: harness.session,
            documentID: Fixtures.docID, scrollView: DocumentScrollView(frame: .zero), fixedOverlay: PassThroughView())
        weak var releasedHost = host
        let finished = expectation(description: "Accepted ink reaches the document after navigation")
        // Use exactly representable values within the stroke JSON format's
        // three-decimal precision so the full point-array assertion is exact.
        let stroke = Stroke(style: .defaultPen,
                            points: [StrokePoint(x: 100, y: 200, altitude: 1.5),
                                     StrokePoint(x: 200, y: 200, altitude: 1.5)], t0: 1)
        host?.commitStroke(stroke, page: Fixtures.page2) { outcome in
            if case .failure(let error) = outcome { XCTFail("\(error)") }
            finished.fulfill()
        }
        // No actor suspension between accepting ink and releasing the editor. This
        // reproduces the library transition winning the race with the queued command.
        harness.session.document = nil
        host = nil
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(releasedHost, "The commit must release the detached canvas after completion")
        harness.app.workspace.close(Fixtures.docID)
        harness.session.document = Fixtures.docID
        let reopened = try harness.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(reopened.count, before + 1)
        XCTAssertEqual(reopened.last?.stroke?.points, stroke.points)
        XCTAssertEqual(harness.undoDepth(Fixtures.docID), 1)
    }
}
