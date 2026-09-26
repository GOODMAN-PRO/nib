import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatDiagrams

@MainActor
final class FeatDiagramsTests: XCTestCase {
    // MARK: Helpers

    func connector(_ h: Harness, _ id: ElementID, doc: DocumentID = Fixtures.docID,
                   page: PageID = Fixtures.page1) throws -> ConnectorItem {
        try XCTUnwrap(h.app.workspace.item(doc, page: page, id: id).connector)
    }

    func anchor(_ h: Harness, _ id: ElementID, side: Int, doc: DocumentID = Fixtures.docID,
                page: PageID = Fixtures.page1) throws -> Point? {
        try h.app.workspace.item(doc, page: page, id: id).anchorPoint(side: side, t: 0.5)
    }

    /// Lets tasks started by the canvas attachments finish.
    func settle(until condition: @escaping () -> Bool) async {
        var spins = 0
        while spins < 500, !condition() {
            await Task.yield()
            spins += 1
        }
    }

    // MARK: Registration and conformance

    func testFeatureRegistersCommandsDrawerAndAttachments() {
        let h = Harness(features: [FeatDiagramsFeature.self])
        XCTAssertEqual(FeatDiagramsFeature.id, "diagrams")
        for id in ["connector.create", "connector.setPath", "diagram.addConnected", "diagram.create"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "diagrams", id)
        }
        XCTAssertNotNil(h.app.content.drawers.get("connector"))
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("diagrams.connectorEditor"))
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("diagrams.quickDiagram"))
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatDiagramsFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: connector.create / connector.setPath

    func testCreateAttachesToTheFacingSides() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let params: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "from": ["item": "FIXTURESHP01"],
                                 "to": ["item": "FIXTURESTY01"], "route": "curved", "label": "leads to", "id": "LINK1"]
        let r = try await h.run("connector.create", params)
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/LINK1")
        let c = try connector(h, "LINK1")
        XCTAssertEqual(c.from.item, Fixtures.shapeID)
        XCTAssertEqual(c.from.side, ConnectorSide.right.rawValue)
        XCTAssertEqual(c.to.item, Fixtures.stickyID)
        XCTAssertEqual(c.to.side, ConnectorSide.left.rawValue)
        XCTAssertEqual(c.from.point, try anchor(h, Fixtures.shapeID, side: 1))
        XCTAssertEqual(c.to.point, try anchor(h, Fixtures.stickyID, side: 3))
        XCTAssertEqual(c.route, .curved)
        XCTAssertEqual(c.label?.plainText, "leads to")
        XCTAssertTrue(c.style.arrowEnd)
        XCTAssertFalse(c.style.arrowStart)
    }

    func testCreateRejectsEndsWithoutAFrameAndUsedIDs() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let ink: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "from": ["item": "FIXTURESTK01"], "to": ["point": [10, 10]]]
        do {
            try await h.run("connector.create", ink, as: .ai("chat"))
            XCTFail("a stroke has no frame to attach to")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.from.item")
        }
        let taken: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "from": ["point": [0, 0]], "to": ["point": [10, 10]],
                                "id": "FIXTURESHP01"]
        do {
            try await h.run("connector.create", taken)
            XCTFail("id already used")
        } catch let e as NibError {
            XCTAssertEqual(e.path, "$.id")
        }
    }

    func testSetPathSwitchesSideAndRouteInOneUndoStep() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let params: JSONValue = ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01", "route": "elbow", "from": ["side": "bottom"]]
        try await h.run("connector.setPath", params)
        let c = try connector(h, Fixtures.connectorID)
        XCTAssertEqual(c.route, .elbow)
        XCTAssertEqual(c.from.item, Fixtures.shapeID)
        XCTAssertEqual(c.from.side, ConnectorSide.bottom.rawValue)
        XCTAssertEqual(c.from.point, try anchor(h, Fixtures.shapeID, side: 2))
        XCTAssertEqual(c.to.item, Fixtures.stickyID)
        XCTAssertEqual(c.to.side, ConnectorSide.left.rawValue)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        let back = try connector(h, Fixtures.connectorID)
        XCTAssertEqual(back.route, .straight)
        XCTAssertEqual(back.from.side, ConnectorSide.right.rawValue)
    }

    func testSetPathBendsAndDetaching() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01"
        try await h.run("connector.setPath", ["ref": .string(ref), "bends": [[330, 150], [360, 170]]])
        XCTAssertEqual(try connector(h, Fixtures.connectorID).bends, [Point(330, 150), Point(360, 170)])
        // Changing the route clears bends that belonged to the old route.
        try await h.run("connector.setPath", ["ref": .string(ref), "route": "curved"])
        XCTAssertEqual(try connector(h, Fixtures.connectorID).bends, [])
        // A point frees an end.
        try await h.run("connector.setPath", ["ref": .string(ref), "to": ["point": [500, 500]]])
        let c = try connector(h, Fixtures.connectorID)
        XCTAssertNil(c.to.item)
        XCTAssertEqual(c.to.point, Point(500, 500))
        do {
            try await h.run("connector.setPath", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "route": "elbow"])
            XCTFail("a shape is not a connector")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testSetPathRefusesALockedConnector() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        // Lock the fixture connector in storage, then let the workspace load it afresh.
        h.app.workspace.close(Fixtures.docID)
        var stored = try XCTUnwrap(h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1])
        let i = try XCTUnwrap(stored.firstIndex { $0.id == Fixtures.connectorID })
        stored[i].locked = true
        h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1] = stored
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.connectorID).locked)
        do {
            try await h.run("connector.setPath", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01", "route": "elbow"])
            XCTFail("a locked connector cannot be rerouted")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.ref")
            XCTAssertNotNil(e.hint)
        }
        XCTAssertEqual(try connector(h, Fixtures.connectorID).route, .straight)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testLabelsHaveALengthCap() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let long = JSONValue.string(String(repeating: "a", count: DiagramSchemas.maxLabel + 1))
        let connectorCall: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "from": ["point": [0, 0]],
                                        "to": ["point": [90, 90]], "label": long]
        let nodeCall: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "tree",
                                   "nodes": [["id": "a", "label": long]], "edges": []]
        let edgeCall: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "tree",
                                   "nodes": [["id": "a"], ["id": "b"]], "edges": [["from": "a", "to": "b", "label": long]]]
        let calls: [(String, JSONValue, String)] = [("connector.create", connectorCall, "$.label"),
                                                    ("diagram.create", nodeCall, "$.nodes[0].label"),
                                                    ("diagram.create", edgeCall, "$.edges[0].label")]
        for (command, params, path) in calls {
            do {
                try await h.run(command, params)
                XCTFail("\(path) is too long")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
                XCTAssertEqual(e.path, path)
            }
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    // MARK: diagram.addConnected

    func testAddConnectedCopiesTheShapeBesideIt() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let r = try await h.run("diagram.addConnected", ["ref": "item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01", "side": "right", "id": "NEXT1"])
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC04/FIXTUREBRD01/NEXT1")
        let ws = h.app.workspace
        let shape = try ws.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: "NEXT1")
        XCTAssertEqual(shape.shape?.shape, .ellipse)
        XCTAssertEqual(shape.frame, Frame(x: 200 + DiagramLayout.connectedGap, y: 0, w: 200, h: 120))
        guard case let .item(_, _, connectorID)? = NodeRef(r["connector"]?.stringValue ?? "") else {
            return XCTFail("no connector ref")
        }
        let c = try connector(h, connectorID, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        XCTAssertEqual(c.from.item, Fixtures.boardShapeID)
        XCTAssertEqual(c.from.side, ConnectorSide.right.rawValue)
        XCTAssertEqual(c.to.item, "NEXT1")
        XCTAssertEqual(c.to.side, ConnectorSide.left.rawValue)
        XCTAssertEqual(h.undoDepth(Fixtures.whiteboardID), 1)
        h.app.bus.undo(Fixtures.whiteboardID)
        XCTAssertThrowsError(try ws.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: "NEXT1"))
        XCTAssertThrowsError(try ws.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: connectorID))
    }

    func testAddConnectedSaysWhenASideHasNoRoom() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        // The sticky note is 140 pt tall and 120 pt from the top of the page: no room for its copy above it.
        let before = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).count
        do {
            try await h.run("diagram.addConnected", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "side": "top"])
            XCTFail("no room above")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.side")
            XCTAssertNotNil(e.hint)
        }
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).count, before)
        // Below there is room, and the new shape lands wholly below it.
        let r = try await h.run("diagram.addConnected", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "side": "bottom"])
        guard case let .item(_, _, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no shape ref") }
        let frame = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: id).frame)
        XCTAssertGreaterThanOrEqual(frame.y, 260 + DiagramLayout.minConnectedGap)
    }

    // MARK: diagram.create

    func testDiagramCreateUsesNodeIDsAndUndoesAsOneStep() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let before = try h.snapshotAll()
        let params = try JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "tree", "nodes": [{"id": "root", "label": "Forces"}, {"id": "a", "label": "Weight"}, {"id": "b", "label": "Friction"}], "edges": [{"from": "root", "to": "a"}, {"from": "root", "to": "b", "label": "opposes"}]}"#)
        let r = try await h.run("diagram.create", params)
        XCTAssertEqual(r["refs"]?.arrayValue?.compactMap { $0.stringValue },
                       ["item:FIXTUREDOC01/FIXTUREPG002/root", "item:FIXTUREDOC01/FIXTUREPG002/a", "item:FIXTUREDOC01/FIXTUREPG002/b"])
        XCTAssertEqual(r["connectors"]?.arrayValue?.count, 2)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(items.filter { $0.kind == .shape }.count, 3)
        let connectors = items.compactMap { $0.connector }
        XCTAssertEqual(connectors.count, 2)
        for c in connectors {
            XCTAssertEqual(c.route, .elbow)
            XCTAssertEqual(c.from.item, "root")
            XCTAssertEqual(c.from.side, ConnectorSide.bottom.rawValue)
            XCTAssertEqual(c.to.side, ConnectorSide.top.rawValue)
        }
        XCTAssertEqual(connectors.compactMap { $0.label?.plainText }, ["opposes"])
        let root = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "root")
        XCTAssertEqual(root.shape?.text?.plainText, "Forces")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testDiagramCreateTwiceOnOnePageMintsFreshIDs() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let params = try JSONValue.parse(#"{"page": "page:FIXTUREDOC04/FIXTUREBRD01", "layout": "timeline", "origin": [0, 400], "nodes": [{"id": "t1", "label": "1905"}, {"id": "t2", "label": "1915"}, {"id": "t3", "label": "1927"}], "edges": []}"#)
        let first = try await h.run("diagram.create", params)
        let second = try await h.run("diagram.create", params)
        let a = first["refs"]?.arrayValue ?? [], b = second["refs"]?.arrayValue ?? []
        XCTAssertEqual(a.count, 3)
        XCTAssertTrue(Set(a).isDisjoint(with: Set(b)))
        // A timeline without edges is chained in order.
        XCTAssertEqual(first["connectors"]?.arrayValue?.count, 2)
        let shapes = try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID).filter { $0.kind == .shape }
        XCTAssertEqual(shapes.count, 7)
    }

    func testDiagramCreateFitsAFixedPage() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let nodes = (0...6).map { i -> JSONValue in ["id": .string("n\(i)"), "label": .string(i == 0 ? "Energy" : "Store \(i)")] }
        let edges = (1...6).map { i -> JSONValue in ["from": "n0", "to": .string("n\(i)")] }
        let params: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "tree", "style": "line",
                                 "nodes": .array(nodes), "edges": .array(edges)]
        try await h.run("diagram.create", params)
        let size = PageSize.a4
        for item in try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2) where item.kind == .shape {
            let f = try XCTUnwrap(item.frame)
            XCTAssertGreaterThanOrEqual(f.x, 0)
            XCTAssertGreaterThanOrEqual(f.y, 0)
            XCTAssertLessThanOrEqual(f.x + f.w, size.width)
            XCTAssertLessThanOrEqual(f.y + f.h, size.height)
            XCTAssertNil(item.shape?.style.fillColor, "the line style has no fill")
        }
    }

    func testDiagramCreateWrapsALongTimelineOntoAFixedPage() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let nodes = (1...12).map { i -> JSONValue in
            ["id": .string("e\(i)"), "label": .string("Event \(i): a milestone of the year")]
        }
        let params: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "timeline", "nodes": .array(nodes),
                                 "edges": []]
        let r = try await h.run("diagram.create", params)
        XCTAssertEqual(r["connectors"]?.arrayValue?.count, 11)
        let size = PageSize.a4
        let page = Rect(x: 0, y: 0, width: size.width, height: size.height)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        var rows = Set<Int>()
        for item in items {
            XCTAssertTrue(page.contains(item.bounds), "\(item.id) at \(item.bounds) is off the page")
            if let f = item.frame { rows.insert(Int(f.bounds.midY.rounded())) }
        }
        XCTAssertEqual(items.filter { $0.kind == .shape }.count, 12)
        XCTAssertGreaterThan(rows.count, 1, "the timeline wraps into rows")
    }

    func testDiagramCreateRefusesADiagramThatCannotFitAFixedPage() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        // A root with 5 branches of 4 leaves: 20 leaves side by side, far wider than A4 even at the smallest scale.
        var nodes: [JSONValue] = [["id": "root", "label": "Topic"]]
        var edges: [JSONValue] = []
        for b in 1...5 {
            nodes.append(["id": .string("b\(b)"), "label": .string("Branch \(b)")])
            edges.append(["from": "root", "to": .string("b\(b)")])
            for l in 1...4 {
                nodes.append(["id": .string("b\(b)l\(l)"), "label": .string("Leaf \(b).\(l)")])
                edges.append(["from": .string("b\(b)"), "to": .string("b\(b)l\(l)")])
            }
        }
        let onA4: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "tree", "nodes": .array(nodes),
                               "edges": .array(edges)]
        do {
            try await h.run("diagram.create", onA4, as: .ai("chat"))
            XCTFail("26 nodes this wide do not fit an A4 page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.nodes")
            XCTAssertNotNil(e.hint)
        }
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).isEmpty)
        // A board takes it whole.
        let onBoard: JSONValue = ["page": "page:FIXTUREDOC04/FIXTUREBRD01", "layout": "tree", "nodes": .array(nodes),
                                  "edges": .array(edges)]
        let r = try await h.run("diagram.create", onBoard)
        XCTAssertEqual(r["refs"]?.arrayValue?.count, 26)
        // An explicit origin that would push a diagram off a fixed page is refused too.
        let offPage: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "timeline", "origin": [500, 700],
                                  "nodes": [["id": "a", "label": "One"], ["id": "b", "label": "Two"]], "edges": []]
        do {
            try await h.run("diagram.create", offPage)
            XCTFail("the diagram would run off the page")
        } catch let e as NibError {
            XCTAssertEqual(e.path, "$.origin")
        }
    }

    func testDiagramCreateExplainsBadEdges() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let params = try JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "layout": "flow", "nodes": [{"id": "a", "label": "A"}], "edges": [{"from": "a", "to": "zzz"}]}"#)
        do {
            try await h.run("diagram.create", params, as: .ai("chat"))
            XCTFail("unknown node")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.edges[0].to")
            XCTAssertNotNil(e.hint)
        }
    }

    // MARK: Geometry and drawing

    func testElbowRoutesStayOrthogonalAndLeaveAlongTheirSides() {
        let a = Point(0, 0), b = Point(100, 80)
        let pts = ConnectorRouter.elbow(from: a, side: ConnectorSide.right.rawValue, to: b, side: ConnectorSide.top.rawValue, bends: [])
        XCTAssertEqual(pts.first, a)
        XCTAssertEqual(pts.last, b)
        for i in 1..<pts.count {
            XCTAssertTrue(abs(pts[i].x - pts[i - 1].x) < 1e-9 || abs(pts[i].y - pts[i - 1].y) < 1e-9, "\(pts)")
        }
        XCTAssertEqual(pts[1].y, 0)
        XCTAssertGreaterThan(pts[1].x, 0)
        XCTAssertEqual(pts[pts.count - 2].x, 100)
        XCTAssertLessThan(pts[pts.count - 2].y, 80)
    }

    func testDraggingAnElbowSegmentBecomesBendsTheRouterFollows() {
        let a = Point(0, 0), b = Point(100, 0)
        let frame = ConnectorRouter.elbowFrame(from: a, side: 1, to: b, side: 3, bends: [])
        let bends = ConnectorEditor.movedSegment(frame, index: 0, delta: Point(40, 30))
        XCTAssertEqual(bends, [Point(6, 30), Point(94, 30)])
        let pts = ConnectorRouter.elbow(from: a, side: 1, to: b, side: 3, bends: bends)
        XCTAssertEqual(pts, [a, Point(6, 0), Point(6, 30), Point(94, 30), Point(94, 0), b])
    }

    func testCurvesLeaveAndArriveAlongTheirSides() {
        let c = ConnectorItem(from: ConnectorEnd(point: Point(0, 0), item: "A", side: 1, t: 0.5),
                              to: ConnectorEnd(point: Point(100, 100), item: "B", side: 0, t: 0.5), route: .curved)
        let g = ConnectorRouter.geometry(c)
        XCTAssertEqual(g.segments.count, 1)
        guard case let .cubic(_, c1, _, _)? = g.segments.first else { return XCTFail("expected a curve") }
        XCTAssertGreaterThan(c1.x, 0)
        XCTAssertEqual(c1.y, 0, accuracy: 1e-9)
        XCTAssertEqual(g.endDirection.x, 0, accuracy: 1e-9)
        XCTAssertEqual(g.endDirection.y, 1, accuracy: 1e-9)
    }

    func testDrawerPaintsTheLineAndTheArrowhead() {
        func alpha(_ c: ConnectorItem, _ x: Int, _ y: Int) -> UInt8 {
            let w = 100, h = 100
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            ConnectorDrawer().draw(Item.makeConnector(c), in: DrawContext(cg: ctx, scale: 1, doc: "D", page: "P"))
            guard let data = ctx.data else { return 0 }
            let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            return bytes[(h - 1 - y) * w * 4 + x * 4 + 3]
        }
        let arrow = ConnectorItem(from: ConnectorEnd(point: Point(10, 50)), to: ConnectorEnd(point: Point(90, 50)))
        XCTAssertGreaterThan(alpha(arrow, 50, 50), 0, "the line")
        XCTAssertGreaterThan(alpha(arrow, 83, 51), 0, "the arrowhead")
        XCTAssertEqual(alpha(arrow, 50, 10), 0)
        var plain = arrow
        plain.style.arrowEnd = false
        XCTAssertEqual(alpha(plain, 83, 51), 0)
    }

    func testConnectorsStayInsideTheirBounds() {
        // Tile invalidation (Changeset.dirtyRect) and lasso hit tests use Item.bounds: every route, and the stroke
        // actually drawn (trimmed for arrowheads), must stay inside it.
        var rng = DiagramLayoutTests.SeededGenerator(state: 2024)
        func point() -> Point { Point(Double.random(in: 0...400, using: &rng), Double.random(in: 0...400, using: &rng)) }
        let sides: [Int?] = [nil, 0, 1, 2, 3]
        for route in ConnectorRoute.allCases {
            for sa in sides {
                for sb in sides {
                    for bendCount in [0, 1, 3] {
                        for _ in 0..<5 {
                            let from = ConnectorEnd(point: point(), item: sa == nil ? nil : "A", side: sa, t: 0.5)
                            let to = ConnectorEnd(point: point(), item: sb == nil ? nil : "B", side: sb, t: 0.5)
                            let bends = (0..<bendCount).map { _ in point() }
                            let style = ShapeItemStyle(arrowStart: Bool.random(using: &rng), arrowEnd: true)
                            let c = ConnectorItem(from: from, to: to, route: route, bends: bends, style: style)
                            let bounds = Item.makeConnector(c).bounds.insetBy(-1e-6)
                            let g = ConnectorRouter.geometry(c)
                            let what = "\(route) from side \(String(describing: sa)) to side \(String(describing: sb))"
                            for p in g.flattened() {
                                XCTAssertTrue(bounds.contains(p), "\(what): \(p) outside \(bounds)")
                            }
                            let s = ConnectorPainter.arrowSize(style.strokeWidth) * 0.8
                            let drawn = g.path(trimStart: s, trimEnd: s).boundingBoxOfPath
                            XCTAssertTrue(bounds.cg.insetBy(dx: -1e-6, dy: -1e-6).contains(drawn), "\(what): stroke \(drawn)")
                        }
                    }
                }
            }
        }
        // The reviewer's case: top to top, 300 pt apart, used to arch about 83 pt above both anchors.
        let arch = ConnectorItem(from: ConnectorEnd(point: Point(0, 100), item: "A", side: 0, t: 0.5),
                                 to: ConnectorEnd(point: Point(300, 100), item: "B", side: 0, t: 0.5), route: .curved)
        let top = ConnectorRouter.geometry(arch).flattened().map { $0.y }.min() ?? 0
        XCTAssertGreaterThanOrEqual(top, Item.makeConnector(arch).bounds.minY)
        XCTAssertLessThan(top, 100, "it still leaves upward, along the top sides")
    }

    func testLabelsSitOnTheMiddleOfTheLineOverAKnockout() throws {
        let w = 200, h = 100
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let c = ConnectorItem(from: ConnectorEnd(point: Point(10, 50)), to: ConnectorEnd(point: Point(190, 50)),
                              style: ShapeItemStyle(arrowEnd: false), label: RichText(plain: "Hi"))
        ConnectorDrawer().draw(Item.makeConnector(c), in: DrawContext(cg: ctx, scale: 1, doc: "D", page: "P"))
        let label = ConnectorPainter.layout(RichText(plain: "Hi"), ink: .black, geometry: ConnectorRouter.geometry(c))
        XCTAssertEqual(label.rect.midX, 100, accuracy: 0.5)
        XCTAssertEqual(label.rect.midY, 50, accuracy: 0.5)
        let data = try XCTUnwrap(ctx.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(h - 1 - y) * w * 4 + x * 4 + 3] }
        XCTAssertGreaterThan(alpha(30, 50), 0, "the line away from the label")
        XCTAssertGreaterThan(alpha(170, 50), 0, "the line on the other side")
        let gap = Int((label.rect.minX - 2.5).rounded(.down))
        XCTAssertEqual(alpha(gap, 50), 0, "the line stops short of the label")
        XCTAssertEqual(alpha(Int(label.rect.maxX.rounded(.up)) + 1, 50), 0, "on both sides")
    }

    // MARK: Canvas attachments

    func testQuickDiagramDotTapAddsAndSelectsAConnectedShape() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let host = FakeCanvasHost(h)
        let overlay = QuickDiagramOverlay(host: host)
        overlay.attach(to: host)
        XCTAssertFalse(overlay.hitTest(CGPoint(x: 312, y: 245), host: host), "nothing selected")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        overlay.canvasDidChange(host)
        // The rectangle's right side is at x 260 (zoom 1, page 1 at the origin): its dot sits 52 pt further out.
        let dot = CGPoint(x: 260 + QuickDiagramOverlay.dotOffset, y: 245)
        XCTAssertTrue(overlay.hitTest(dot, host: host))
        XCTAssertFalse(overlay.hitTest(CGPoint(x: 180, y: 245), host: host), "the shape's body is not a dot")
        let before = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).count
        let sample = CanvasSample(page: Fixtures.page1, location: Point(Double(dot.x), Double(dot.y)))
        overlay.touchesBegan(sample, host: host)
        overlay.touchesEnded(sample, host: host)
        await settle { h.session.selection.items.first != Fixtures.shapeID }
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        XCTAssertEqual(items.count, before + 2)
        let added = try XCTUnwrap(h.session.selection.items.first)
        XCTAssertNotEqual(added, Fixtures.shapeID)
        let link = try XCTUnwrap(items.compactMap { $0.connector }.first { $0.to.item == added })
        XCTAssertEqual(link.from.item, Fixtures.shapeID)
        XCTAssertEqual(link.from.side, ConnectorSide.right.rawValue)
    }

    func testConnectorEditorDragsAnEndOntoAnotherItem() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let host = FakeCanvasHost(h)
        let editor = ConnectorEditor(host: host)
        editor.attach(to: host)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.connectorID])
        editor.canvasDidChange(host)
        XCTAssertTrue(editor.hitTest(CGPoint(x: 260, y: 245), host: host), "the start handle")
        XCTAssertFalse(editor.hitTest(CGPoint(x: 100, y: 600), host: host))
        editor.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(400, 190)), host: host)
        editor.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(250, 390))], host: host)
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.connectorID], "the real connector hides while its preview moves")
        editor.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(222, 398)), host: host)
        // Until the edit lands the preview stays and the real connector stays hidden (no flash of the old route),
        // and the handles take no new touches.
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.connectorID])
        XCTAssertFalse(editor.hitTest(CGPoint(x: 260, y: 245), host: host))
        await settle { (try? self.connector(h, Fixtures.connectorID).to.item) == Fixtures.textID }
        let c = try connector(h, Fixtures.connectorID)
        XCTAssertEqual(c.to.item, Fixtures.textID)
        XCTAssertEqual(c.to.side, ConnectorSide.top.rawValue)
        XCTAssertEqual(c.to.t ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        await settle { host.hidden[Fixtures.page1] == nil }
        XCTAssertNil(host.hidden[Fixtures.page1])
        editor.canvasDidChange(host)
        XCTAssertTrue(editor.hitTest(CGPoint(x: 260, y: 245), host: host), "handles take touches again")
    }

    func testQuickDiagramDragOntoAnItemConnectsToIt() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let host = FakeCanvasHost(h)
        let overlay = QuickDiagramOverlay(host: host)
        overlay.attach(to: host)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        overlay.canvasDidChange(host)
        // From the rectangle's right dot into the sticky note (400, 120, 140 × 140).
        let dot = Point(260 + Double(QuickDiagramOverlay.dotOffset), 245)
        overlay.touchesBegan(CanvasSample(page: Fixtures.page1, location: dot), host: host)
        overlay.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(420, 220))], host: host)
        overlay.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(470, 190)), host: host)
        func added() -> [ConnectorItem] {
            ((try? h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)) ?? [])
                .filter { $0.id != Fixtures.connectorID }.compactMap { $0.connector }
        }
        await settle { !added().isEmpty }
        let link = try XCTUnwrap(added().first)
        XCTAssertEqual(link.from.item, Fixtures.shapeID)
        XCTAssertEqual(link.from.side, ConnectorSide.right.rawValue)
        XCTAssertEqual(link.from.point, try anchor(h, Fixtures.shapeID, side: 1))
        XCTAssertEqual(link.to.item, Fixtures.stickyID)
        XCTAssertEqual(link.to.side, ConnectorSide.left.rawValue, "snapped to the side facing the shape")
        XCTAssertEqual(link.to.point, try anchor(h, Fixtures.stickyID, side: 3))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    func testQuickDiagramDragOntoPaperLeavesAFreeEnd() async throws {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let host = FakeCanvasHost(h)
        let overlay = QuickDiagramOverlay(host: host)
        overlay.attach(to: host)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        overlay.canvasDidChange(host)
        // From the rectangle's left dot out onto empty paper.
        let dot = Point(100 - Double(QuickDiagramOverlay.dotOffset), 245)
        let release = Point(20, 300)
        overlay.touchesBegan(CanvasSample(page: Fixtures.page1, location: dot), host: host)
        overlay.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(30, 280))], host: host)
        overlay.touchesEnded(CanvasSample(page: Fixtures.page1, location: release), host: host)
        func added() -> [ConnectorItem] {
            ((try? h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)) ?? [])
                .filter { $0.id != Fixtures.connectorID }.compactMap { $0.connector }
        }
        await settle { !added().isEmpty }
        let link = try XCTUnwrap(added().first)
        XCTAssertEqual(link.from.item, Fixtures.shapeID)
        XCTAssertEqual(link.from.side, ConnectorSide.left.rawValue)
        XCTAssertNil(link.to.item)
        XCTAssertEqual(link.to.point, release)
        // A short wobble onto nothing does nothing.
        let count = added().count
        overlay.touchesBegan(CanvasSample(page: Fixtures.page1, location: dot), host: host)
        overlay.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(dot.x - 10, 245))], host: host)
        overlay.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(dot.x - 12, 245)), host: host)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(added().count, count)
    }

    func testObjectMenuSkipsLookupsForBigSelections() {
        let h = Harness(features: [FeatDiagramsFeature.self])
        let pair = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID, Fixtures.stickyID])
        XCTAssertEqual(DiagramMenus.items(MenuContext(app: h.app, session: h.session, selection: pair)).count, 2)
        XCTAssertTrue(DiagramMenus.connectable(MenuContext(app: h.app, session: h.session, selection: pair)))
        let many = Selection(doc: Fixtures.docID, page: Fixtures.page1,
                             items: [Fixtures.shapeID, Fixtures.stickyID, Fixtures.textID])
        XCTAssertTrue(DiagramMenus.items(MenuContext(app: h.app, session: h.session, selection: many)).isEmpty)
        XCTAssertFalse(DiagramMenus.connectable(MenuContext(app: h.app, session: h.session, selection: many)))
    }

    func testEditorOffersBendHandlesPerRoute() {
        let straight = ConnectorItem(from: ConnectorEnd(point: Point(0, 0)), to: ConnectorEnd(point: Point(200, 0)),
                                     bends: [Point(100, 50)])
        let handles = ConnectorEditor.handles(for: straight).map { $0.handle }
        XCTAssertEqual(handles, [.end(start: true), .end(start: false), .bend(0), .insert(0), .insert(1)])
        var elbow = straight
        elbow.route = .elbow
        elbow.bends = []
        XCTAssertTrue(ConnectorEditor.handles(for: elbow).contains { $0.handle == .segment(0) })
    }
}
