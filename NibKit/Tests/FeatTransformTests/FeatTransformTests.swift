import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatTransform

@MainActor
final class FeatTransformTests: XCTestCase {
    private var doc: DocumentID { Fixtures.docID }
    private var page1: PageID { Fixtures.page1 }
    private var page2: PageID { Fixtures.page2 }

    private func ref(_ id: ElementID, on page: PageID = Fixtures.page1) -> JSONValue {
        .string(NodeRef.item(Fixtures.docID, page, id).description)
    }

    private func item(_ h: Harness, _ id: ElementID, on page: PageID = Fixtures.page1) throws -> Item {
        try h.app.workspace.item(Fixtures.docID, page: page, id: id)
    }

    /// Edits a fixture item before the workspace loads the page.
    private func edit(_ h: Harness, _ id: ElementID, _ change: (inout Item) -> Void) {
        guard var items = h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1],
              let i = items.firstIndex(where: { $0.id == id }) else { return XCTFail("fixture \(id) missing") }
        change(&items[i])
        h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1] = items
    }

    private func makeHandles(_ h: Harness, _ host: FakeCanvasHost) throws -> SelectionHandles {
        let descriptor = try XCTUnwrap(h.app.ui.canvasAttachments.get(SelectionHandles.id))
        let attachment = try XCTUnwrap(descriptor.make(host) as? SelectionHandles)
        attachment.attach(to: host)
        return attachment
    }

    private func sample(_ page: PageID, _ x: Double, _ y: Double, _ modifiers: KeyModifiers = []) -> CanvasSample {
        CanvasSample(page: page, location: Point(x, y), isPencil: false, modifiers: modifiers)
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatTransformFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testArrowKeysNudgeOneAndTenPoints() throws {
        let h = Harness(features: [FeatTransformFeature.self])
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatTransformFeature.id }
        XCTAssertEqual(keys.count, 8)
        let up = try XCTUnwrap(keys.first { $0.shortcut == KeyShortcut("up") })
        XCTAssertEqual(up.command, "item.transform")
        XCTAssertEqual(up.params["translate"], .array([.number(0), .number(-1)]))
        XCTAssertEqual(up.scope, .canvas)
        let far = try XCTUnwrap(keys.first { $0.shortcut == KeyShortcut("right", [.shift]) })
        XCTAssertEqual(far.params["translate"], .array([.number(10), .number(0)]))
    }

    // MARK: item.transform

    func testMovingAShapeRepinsItsAnchoredConnectorInTheSameUndoStep() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        let before = try h.snapshot()
        let depth = h.undoDepth(doc)
        let params: JSONValue = ["refs": .array([ref(Fixtures.shapeID)]), "translate": [10, 0]]
        let out = try await h.run("item.transform", params)
        XCTAssertEqual(out["refs"], .array([ref(Fixtures.shapeID)]))
        XCTAssertEqual(try item(h, Fixtures.shapeID).shape?.frame.x, 110)
        let connector = try XCTUnwrap(try item(h, Fixtures.connectorID).connector)
        XCTAssertEqual(connector.from.point, Point(270, 245))           // right side midpoint of the moved shape
        XCTAssertEqual(connector.to.point, Point(400, 190))             // the sticky did not move
        XCTAssertEqual(h.undoDepth(doc), depth + 1)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testLockedItemsAreRejected() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        edit(h, Fixtures.shapeID) { $0.locked = true }
        let params: JSONValue = ["refs": .array([ref(Fixtures.textID), ref(Fixtures.shapeID)]), "rotate": 90]
        do {
            try await h.run("item.transform", params)
            XCTFail("a locked item moved")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.refs[1]")
        }
        XCTAssertEqual(try item(h, Fixtures.textID).text?.frame.rotation, 0)
    }

    func testAttachedItemsFollowTheirContainer() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        edit(h, Fixtures.textID) { $0.attachedTo = Fixtures.shapeID }
        let params: JSONValue = ["refs": .array([ref(Fixtures.shapeID)]), "translate": [0, 30]]
        try await h.run("item.transform", params)
        XCTAssertEqual(try item(h, Fixtures.textID).text?.frame.y, 430)
    }

    func testRotatedFrameResizesAlongItsOwnAxes() {
        let f = Frame(x: 100, y: 100, w: 80, h: 40, rotation: .pi / 6)
        let c = f.center
        let t = Affine.rotation(-f.rotation, about: c).concatenating(.scale(2, 1, about: c))
            .concatenating(.rotation(f.rotation, about: c))
        let g = TransformMath.frame(f, applying: t)
        XCTAssertEqual(g.w, 160, accuracy: 1e-9)
        XCTAssertEqual(g.h, 40, accuracy: 1e-9)
        XCTAssertEqual(g.rotation, .pi / 6, accuracy: 1e-9)
        XCTAssertEqual(g.center.x, c.x, accuracy: 1e-9)
        XCTAssertEqual(g.center.y, c.y, accuracy: 1e-9)
    }

    func testRefsDefaultToTheSelectionAndNothingSelectedIsANoOp() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        let depth = h.undoDepth(doc)
        let nothing = try await h.run("item.transform", ["translate": [1, 0]])
        XCTAssertEqual(nothing["refs"], .array([]))
        XCTAssertEqual(h.undoDepth(doc), depth)
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.stickyID])
        try await h.run("item.transform", ["translate": [0, -10]])
        XCTAssertEqual(try item(h, Fixtures.stickyID).sticky?.frame.y, 110)
        XCTAssertEqual(h.session.selection.bounds?.y, 110)
    }

    // MARK: item.moveToPage

    func testMoveToPageKeepsIdsAndDetachesConnectorsLeftBehind() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        let before = try h.snapshot()
        let params: JSONValue = ["refs": .array([ref(Fixtures.shapeID)]), "page": "page:FIXTUREDOC01/FIXTUREPG002",
                                 "offset": [0, 40]]
        let out = try await h.run("item.moveToPage", params)
        XCTAssertEqual(out["moved"], .array([ref(Fixtures.shapeID, on: page2)]))
        XCTAssertEqual(try item(h, Fixtures.shapeID, on: page2).shape?.frame.y, 240)
        XCTAssertThrowsError(try item(h, Fixtures.shapeID))
        let connector = try XCTUnwrap(try item(h, Fixtures.connectorID).connector)
        XCTAssertNil(connector.from.item)
        XCTAssertEqual(connector.to.item, Fixtures.stickyID)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testMovingBothEndsCarriesTheConnectorAndFollowsTheSelection() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID, Fixtures.stickyID])
        try await h.run("item.moveToPage", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        let connector = try XCTUnwrap(try item(h, Fixtures.connectorID, on: page2).connector)
        XCTAssertEqual(connector.from.item, Fixtures.shapeID)
        XCTAssertEqual(connector.to.item, Fixtures.stickyID)
        XCTAssertEqual(h.session.selection.page, page2)
        XCTAssertEqual(Set(h.session.selection.items), [Fixtures.shapeID, Fixtures.stickyID])
    }

    // MARK: Handles attachment

    func testHandleLayoutPicksTheNearestHandle() {
        let l = HandleLayout(corners: [CGPoint(x: 100, y: 200), CGPoint(x: 260, y: 200),
                                       CGPoint(x: 260, y: 290), CGPoint(x: 100, y: 290)])
        XCTAssertEqual(l.target(at: CGPoint(x: 102, y: 203)), .corner(0))
        XCTAssertEqual(l.target(at: CGPoint(x: 262, y: 245)), .edge(1))
        XCTAssertEqual(l.target(at: CGPoint(x: 180, y: 290)), .edge(2))
        XCTAssertEqual(l.target(at: CGPoint(x: 180, y: 178)), .rotate)
        XCTAssertEqual(l.target(at: CGPoint(x: 150, y: 240)), .body)
        XCTAssertNil(l.target(at: CGPoint(x: 400, y: 400)))
    }

    func testHandlesClaimTouchesOnHandlesAndBodyOnly() throws {
        let h = Harness(features: [FeatTransformFeature.self])
        let host = FakeCanvasHost(h)
        let handles = try makeHandles(h, host)
        XCTAssertFalse(handles.hitTest(CGPoint(x: 180, y: 245), host: host), "nothing is selected")
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        handles.canvasDidChange(host)
        // The shape's frame is (100, 200, 160, 90); page 1 sits at the view origin at zoom 1.
        XCTAssertTrue(handles.hitTest(CGPoint(x: 180, y: 245), host: host), "body")
        XCTAssertTrue(handles.hitTest(CGPoint(x: 90, y: 190), host: host), "top-left corner")
        XCTAssertTrue(handles.hitTest(CGPoint(x: 180, y: 176), host: host), "rotation bead")
        XCTAssertFalse(handles.hitTest(CGPoint(x: 180, y: 150), host: host), "above the rotation bead")
        XCTAssertFalse(handles.hitTest(CGPoint(x: 500, y: 700), host: host), "elsewhere on the page")
        h.session.readOnly = true
        XCTAssertFalse(handles.hitTest(CGPoint(x: 180, y: 245), host: host), "read-only")
    }

    func testLockedSelectionHasNoHandles() throws {
        let h = Harness(features: [FeatTransformFeature.self])
        edit(h, Fixtures.shapeID) { $0.locked = true }
        let host = FakeCanvasHost(h)
        let handles = try makeHandles(h, host)
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        XCTAssertFalse(handles.hitTest(CGPoint(x: 180, y: 245), host: host))
    }

    func testDraggingTheBodyMovesItsItemsInOneCommand() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        h.app.settings.set(NibSettings.alignObjects, false)
        let host = FakeCanvasHost(h)
        let handles = try makeHandles(h, host)
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        let depth = h.undoDepth(doc)
        XCTAssertTrue(handles.hitTest(CGPoint(x: 180, y: 245), host: host))
        handles.touchesBegan(sample(page1, 180, 245), host: host)
        handles.touchesMoved([sample(page1, 200, 255)], host: host)
        XCTAssertEqual(host.hidden[page1]?.contains(Fixtures.shapeID), true, "originals hide under the drag preview")
        handles.touchesEnded(sample(page1, 220, 275), host: host)
        await handles.pendingCommit?.value
        let frame = try XCTUnwrap(try item(h, Fixtures.shapeID).shape?.frame)
        XCTAssertEqual(frame.x, 140, accuracy: 1e-9)
        XCTAssertEqual(frame.y, 230, accuracy: 1e-9)
        XCTAssertEqual(try item(h, Fixtures.connectorID).connector?.from.point, Point(300, 275))
        XCTAssertNil(host.hidden[page1])
        XCTAssertEqual(h.undoDepth(doc), depth + 1)
    }

    func testDroppingOnAnotherPageMovesTheItemsThere() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        h.app.settings.set(NibSettings.alignObjects, false)
        let host = FakeCanvasHost(h)
        let handles = try makeHandles(h, host)
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        XCTAssertTrue(handles.hitTest(CGPoint(x: 180, y: 245), host: host))
        handles.touchesBegan(sample(page1, 180, 245), host: host)
        handles.touchesMoved([sample(page2, 180, 100)], host: host)
        handles.touchesEnded(sample(page2, 180, 100), host: host)
        await handles.pendingCommit?.value
        // Grabbed 45 pt below the box's top, dropped 100 pt into page 2: the box lands at y = 55.
        let frame = try XCTUnwrap(try item(h, Fixtures.shapeID, on: page2).shape?.frame)
        XCTAssertEqual(frame.x, 100, accuracy: 1e-6)
        XCTAssertEqual(frame.y, 55, accuracy: 1e-6)
        XCTAssertThrowsError(try item(h, Fixtures.shapeID))
        XCTAssertEqual(h.session.selection.page, page2)
    }

    func testCornerDragScalesProportionallyFromTheOppositeCorner() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        h.app.settings.set(NibSettings.alignObjects, false)
        let host = FakeCanvasHost(h)
        let handles = try makeHandles(h, host)
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        XCTAssertTrue(handles.hitTest(CGPoint(x: 260, y: 290), host: host))
        XCTAssertEqual(handles.layout?.target(at: CGPoint(x: 260, y: 290)), .corner(2))
        handles.touchesBegan(sample(page1, 260, 290), host: host)
        handles.touchesMoved([sample(page1, 300, 312.5)], host: host)
        handles.touchesEnded(sample(page1, 340, 335), host: host)
        await handles.pendingCommit?.value
        let frame = try XCTUnwrap(try item(h, Fixtures.shapeID).shape?.frame)
        XCTAssertEqual(frame.x, 100, accuracy: 1e-6)
        XCTAssertEqual(frame.y, 200, accuracy: 1e-6)
        XCTAssertEqual(frame.w, 240, accuracy: 1e-6)
        XCTAssertEqual(frame.h, 135, accuracy: 1e-6)
    }

    func testATapOnTheSelectionChangesNothing() async throws {
        let h = Harness(features: [FeatTransformFeature.self])
        let host = FakeCanvasHost(h)
        let handles = try makeHandles(h, host)
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        let depth = h.undoDepth(doc)
        XCTAssertTrue(handles.hitTest(CGPoint(x: 180, y: 245), host: host))
        handles.touchesBegan(sample(page1, 180, 245), host: host)
        handles.touchesEnded(sample(page1, 181, 246), host: host)
        XCTAssertNil(handles.pendingCommit)
        XCTAssertNil(handles.drag)
        XCTAssertEqual(h.undoDepth(doc), depth)
        XCTAssertNil(host.hidden[page1])
    }
}
