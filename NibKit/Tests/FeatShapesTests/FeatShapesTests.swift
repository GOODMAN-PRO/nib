import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatShapes

@MainActor
final class FeatShapesTests: XCTestCase {
    private let shapeRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"
    private let page1Ref = "page:FIXTUREDOC01/FIXTUREPG001"
    private let page2Ref = "page:FIXTUREDOC01/FIXTUREPG002"

    // MARK: Commands

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatShapesFeature.self])
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testRegistersToolLibraryInspectorDrawerAndTapHandlers() {
        let h = Harness(features: [FeatShapesFeature.self])
        let item = h.app.ui.toolbar.get(ShapeTool.toolID)
        XCTAssertEqual(item?.toolID, ShapeTool.toolID)
        XCTAssertEqual(item?.shortcut, KeyShortcut("s"))
        XCTAssertNotNil(item?.settings)
        XCTAssertEqual(h.app.ui.canvasTools.get(ShapeTool.toolID)?.make().isSticky, false)
        XCTAssertEqual(h.app.ui.panels.get(ShapeLibraryMenu.panelID)?.placement, .floating)
        XCTAssertEqual(h.app.ui.inspectors.get("shapes.style")?.itemKinds, [.shape])
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(ShapeEditOverlay.descriptorID))
        let shape = Item.makeShape(ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 10, h: 10)))
        XCTAssertTrue(h.app.content.drawer(for: shape) is ShapeDrawer)
        XCTAssertEqual(h.app.content.paintBounds(for: shape), shape.bounds.insetBy(-NibLimits.drawerMargin))
        let taps = h.app.content.tapHandlers.all.filter { $0.command == "shape.tapAt" }
        XCTAssertEqual(Set(taps.map(\.gesture)), [.tap, .doubleTap])
        XCTAssertTrue(taps.allSatisfy { $0.order < 400 && $0.itemKinds == [.shape] })
    }

    func testShapeLabelsPublishTheirTextLayout() throws {
        let h = Harness(features: [FeatShapesFeature.self])
        var s = ShapeItem(shape: .ellipse, frame: Frame(x: 100, y: 100, w: 200, h: 120, rotation: 0.3))
        s.text = RichText(plain: "Idea")
        let layout = try XCTUnwrap(h.app.content.textLayout(for: Item.makeShape(s)))
        XCTAssertEqual(layout.container, ShapeGeometry.textFrame(s))
        XCTAssertEqual(layout.container.rotation, 0.3)
        XCTAssertTrue(layout.centredVertically)
        XCTAssertEqual(layout.base.size, RichTextBridge.defaultFontSize)
        XCTAssertEqual(layout.base.color, s.style.strokeColor?.withAlpha(1))
        // An empty closed shape still takes text; a bare line does not.
        s.text = nil
        XCTAssertNotNil(h.app.content.textLayout(for: Item.makeShape(s)))
        let line = ShapeItem(shape: .line, frame: Frame(x: 0, y: 0, w: 50, h: 0), points: [Point(0, 0), Point(50, 0)])
        XCTAssertNil(h.app.content.textLayout(for: Item.makeShape(line)))
    }

    func testFrameArraysCarryTheRotation() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let value = try await h.run("shape.create", ["page": .string(page2Ref), "shape": "rectangle",
                                                     "frame": [40, 60, 120, 80, 0.5]])
        guard case let .item(_, _, id)? = NodeRef(value["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let s = try XCTUnwrap(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id).shape)
        XCTAssertEqual(s.frame, Frame(x: 40, y: 60, w: 120, h: 80, rotation: 0.5))
        XCTAssertEqual(ShapeJSON.frame(s.frame), [40, 60, 120, 80, 0.5])
        XCTAssertEqual(ShapeJSON.frame(Frame(x: 1, y: 2, w: 3, h: 4)), [1, 2, 3, 4])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "rectangle", "frame": [0, 0, 10]])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "rectangle", "frame": [0, 0, -5, 10]])
    }

    func testEveryKindCreatesAsTheAIAndUndoes() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let before = try h.snapshot()
        for kind in ShapeKind.allCases {
            var params: [String: JSONValue] = ["page": .string(page2Ref), "shape": .string(kind.rawValue)]
            if ShapeGeometry.isBox(kind) {
                params["frame"] = [40, 60, 120, 80]
            } else {
                params["points"] = ShapeJSON.points(Self.samplePoints(kind))
            }
            let value = try await h.run("shape.create", .object(params), as: .ai("chat"))
            XCTAssertNotNil(value["ref"]?.stringValue, "\(kind)")
        }
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(Set(items.compactMap { $0.shape?.shape }), Set(ShapeKind.allCases))
        XCTAssertTrue(items.allSatisfy { $0.createdBy == "ai:chat" })
        while h.app.bus.undo(Fixtures.docID) {}
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testCallerIDIsHonouredAndADuplicateConflicts() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let params: JSONValue = ["page": .string(page2Ref), "shape": "rectangle", "frame": [10, 10, 50, 40], "id": "MYSHAPE"]
        let value = try await h.run("shape.create", params)
        XCTAssertEqual(value["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/MYSHAPE")
        do {
            try await h.run("shape.create", params)
            XCTFail("a duplicate id was accepted")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .conflict)
        }
    }

    func testInvisibleShapesAndBadParamsAreRejected() async {
        let h = Harness(features: [FeatShapesFeature.self])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "rectangle", "frame": [0, 0, 10, 10],
                                                "style": ["strokeColor": .null]])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "line", "points": [[0, 0], [5, 5], [9, 9]]])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "hexagram", "frame": [0, 0, 10, 10]])
        await assertInvalid(h, "shape.setStyle", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"],
                                                  "style": ["fillColor": "#FF0000"]])
        await assertInvalid(h, "shape.setStyle", ["refs": [.string(shapeRef)], "style": ["colour": "#FF0000"]])
        await assertInvalid(h, "shape.setPoints", ["ref": .string(shapeRef), "points": [[1, 1]]])
    }

    func testFillOnlyShapeStaysVisibleWhenItBecomesALine() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        try await h.run("shape.setStyle", ["refs": [.string(shapeRef)], "style": ["strokeColor": .null, "fillColor": "#2156D980"]])
        var s = try shape(h, Fixtures.shapeID)
        XCTAssertNil(s.style.strokeColor)
        XCTAssertEqual(s.style.fillColor, RGBA(hex: "#2156D980"))
        try await h.run("shape.setKind", ["ref": .string(shapeRef), "shape": "line"])
        s = try shape(h, Fixtures.shapeID)
        XCTAssertEqual(s.shape, .line)
        XCTAssertEqual(s.points, [Point(100, 200), Point(260, 290)])
        XCTAssertEqual(s.frame, Frame(x: 100, y: 200, w: 160, h: 90))
        XCTAssertEqual(s.style.strokeColor, RGBA(hex: "#2156D9"))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2)
    }

    func testSetPointsResizesTheBoxAndMovesTheAnchoredConnector() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        try await h.run("shape.setPoints", ["ref": .string(shapeRef), "points": [[100, 200], [300, 320]]])
        let s = try shape(h, Fixtures.shapeID)
        XCTAssertEqual(s.shape, .rectangle)
        XCTAssertEqual(s.frame, Frame(x: 100, y: 200, w: 200, h: 120))
        XCTAssertEqual(try connectorStart(h), Point(300, 260))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try connectorStart(h), Point(260, 245))
        XCTAssertEqual(try shape(h, Fixtures.shapeID).frame, Frame(x: 100, y: 200, w: 160, h: 90))
    }

    // MARK: Geometry

    func testFitFrameKeepsFreeRotation() {
        let angle = 0.6
        let corners = [Point(0, 0), Point(100, 0), Point(100, 50), Point(0, 50)].map {
            ShapeGeometry.rotate($0, by: angle) + Point(300, 200)
        }
        let f = ShapeGeometry.fitFrame(corners, rotation: angle)
        XCTAssertEqual(f.w, 100, accuracy: 1e-6)
        XCTAssertEqual(f.h, 50, accuracy: 1e-6)
        XCTAssertEqual(f.rotation, angle)
        for (c, p) in zip(f.corners, corners) { XCTAssertEqual(c.distance(to: p), 0, accuracy: 1e-6) }
        // Switching a rotated rectangle to a polygon keeps the rotated frame.
        let rect = ShapeItem(shape: .rectangle, frame: f)
        let polygon = ShapeGeometry.setKind(rect, to: .polygon)
        XCTAssertEqual(polygon.points.count, 4)
        XCTAssertEqual(polygon.frame.w, f.w, accuracy: 1e-6)
        XCTAssertEqual(polygon.frame.rotation, angle)
    }

    func testCurvesAndArcsStayInsideTheirPointsBounds() throws {
        let sets: [(ShapeKind, [Point])] = [
            (.curve, [Point(0, 0), Point(50, -80), Point(100, 0)]),
            (.curve, [Point(0, 0), Point(10, -90), Point(90, 90), Point(100, 0)]),
            (.curve, [Point(0, 0), Point(20, -60), Point(40, 40), Point(70, -30), Point(90, 50), Point(120, 0)]),
            (.arc, [Point(0, 0), Point(30, -70), Point(100, 0)])
        ]
        for (kind, pts) in sets {
            let s = try ShapeGeometry.make(kind, frame: nil, points: pts, style: ShapeItemStyle())
            let bounds = try XCTUnwrap(Rect.bounding(pts)).insetBy(-0.01)
            let outline = ShapeGeometry.outline(s)
            XCTAssertGreaterThan(outline.count, 8)
            for p in outline { XCTAssertTrue(bounds.contains(p), "\(kind) leaves its bounds at \(p)") }
            XCTAssertEqual(outline.first?.distance(to: pts[0]) ?? 1, 0, accuracy: 1e-6)
            XCTAssertEqual(outline.last?.distance(to: pts[pts.count - 1]) ?? 1, 0, accuracy: 1e-6)
        }
    }

    func testArcWithAnIsoscelesControlIsCircular() {
        let s = ShapeItem(shape: .arc, frame: Frame(x: 0, y: 0, w: 100, h: 100),
                          points: [Point(100, 0), Point(100, 100), Point(0, 100)])
        for p in ShapeGeometry.outline(s) { XCTAssertEqual(p.distance(to: .zero), 100, accuracy: 0.01) }
    }

    func testCornerRadiusNeverOverlapsNeighbouringArcs() {
        XCTAssertEqual(ShapeGeometry.cornerRadius(Point(0, 0), Point(10, 0), Point(10, 10), 1000), 5, accuracy: 1e-9)
        XCTAssertEqual(ShapeGeometry.cornerRadius(Point(0, 0), Point(100, 0), Point(100, 100), 6), 6, accuracy: 1e-9)
        XCTAssertEqual(ShapeGeometry.cornerRadius(Point(0, 0), Point(50, 0), Point(100, 0), 6), 0)
    }

    func testArrowheadsStayWithinThePaintBounds() {
        let drawer = ShapeDrawer()
        for width in [0.5, 1.5, 4, 12, 40] {
            var style = ShapeItemStyle(strokeWidth: width)
            style.arrowStart = true
            let s = ShapeItem(shape: .arrow, frame: Frame(x: 0, y: 0, w: 200, h: 0), points: [Point(0, 0), Point(200, 0)],
                              style: style)
            let paint = ShapeGeometry.paintBounds(s)
            XCTAssertEqual(drawer.paintBounds(Item.makeShape(s)), paint)
            XCTAssertTrue(paint.contains(Item.makeShape(s).bounds.insetBy(-NibLimits.drawerMargin)))
            let parts = ShapeGeometry.strokeParts(s)
            XCTAssertEqual(parts.heads.count, 2)
            for head in parts.heads {
                // The head's outline stroke (half of width / 2) must fit too.
                let reach = paint.insetBy(max(width * 0.5, 0.5) / 2)
                for p in head.points { XCTAssertTrue(reach.contains(p), "width \(width): \(p) outside \(reach)") }
                XCTAssertGreaterThan(head.left.distance(to: head.right), width, "width \(width): head narrower than the line")
            }
            XCTAssertLessThan(Geo.pathLength(parts.polylines[0]), 200)
        }
    }

    func testOverflowingLabelsAreInsideThePaintBounds() {
        var s = ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 100, w: 60, h: 30))
        s.text = RichText(plain: "A long label that cannot fit inside such a small rectangle at seventeen points")
        let box = ShapeRenderer.textBox(s.text ?? .empty, shape: s)
        XCTAssertGreaterThan(box.h, s.frame.h + 2 * NibLimits.drawerMargin, "the label overflows the margin")
        let paint = ShapeGeometry.paintBounds(s)
        XCTAssertTrue(paint.contains(box.bounds))
        XCTAssertTrue(paint.contains(Item.makeShape(s).bounds.insetBy(-NibLimits.drawerMargin)))
        s.text = nil
        XCTAssertEqual(ShapeGeometry.paintBounds(s), Item.makeShape(s).bounds.insetBy(-NibLimits.drawerMargin))
    }

    func testPlainRangeLeavesListMarkersOut() {
        var text = RichText(plain: "one\ntwo")
        for i in text.paragraphs.indices { text.paragraphs[i].list = .bullet }
        let a = RichTextBridge.attributed(text)
        let two = (a.string as NSString).range(of: "two")
        XCTAssertGreaterThan(two.location, 4, "the bridge adds bullet markers before each paragraph")
        XCTAssertEqual(ShapeTextStyle.plainRange(two, in: a), [4, 3])
        XCTAssertEqual(ShapeTextStyle.plainRange(NSRange(location: 0, length: a.length), in: a), [0, 7])
        XCTAssertEqual(ShapeTextStyle.plainRange(NSRange(location: 2, length: 0), in: NSAttributedString(string: "abc")), [2, 0])
    }

    func testStylePatchParsesNoneAndNullAndRejectsUnknownFields() throws {
        let p = try ShapeStylePatch.parse(["strokeColor": "none", "fillColor": .null, "drawnWith": .null, "pattern": "dotted"],
                                          path: "$.style")
        XCTAssertEqual(p.strokeColor, .set(nil))
        XCTAssertEqual(p.fillColor, .set(nil))
        XCTAssertEqual(p.drawnWith, .set(nil))
        XCTAssertEqual(p.pattern, .set(.dotted))
        XCTAssertEqual(p.radius, .keep)
        XCTAssertThrowsError(try ShapeStylePatch.parse(["fill": "#FFFFFF"], path: "$.style"))
        XCTAssertThrowsError(try ShapeStylePatch.parse(["drawnWith": "tape"], path: "$.style"))
        let full = ShapeStylePatch.full(ShapeItemStyle(strokeColor: nil, fillColor: .white, drawnWith: .pencil, arrowEnd: true))
        XCTAssertEqual(try ShapeStylePatch.parse(full.json, path: "$"), full)
    }

    func testSetKindAndSetPointsConvertBetweenKinds() throws {
        let tri = ShapeItem(shape: .triangle, frame: Frame(x: 0, y: 0, w: 100, h: 80))
        let polygon = try ShapeGeometry.setPoints(tri, [Point(20, -10), Point(100, 80), Point(0, 80)])
        XCTAssertEqual(polygon.shape, .polygon)
        XCTAssertEqual(polygon.frame, Frame(x: 0, y: -10, w: 100, h: 90))
        let resized = try ShapeGeometry.setPoints(tri, [Point(10, 10), Point(60, 40)])
        XCTAssertEqual(resized.shape, .triangle)
        XCTAssertEqual(resized.frame, Frame(x: 10, y: 10, w: 50, h: 30))
        let arc = ShapeGeometry.setKind(ShapeItem(shape: .line, frame: Frame(x: 0, y: 0, w: 100, h: 0),
                                                  points: [Point(0, 0), Point(100, 0)]), to: .arc)
        XCTAssertEqual(arc.points.count, 3)
        let backToBox = ShapeGeometry.setKind(arc, to: .ellipse)
        XCTAssertTrue(backToBox.points.isEmpty)
        XCTAssertGreaterThanOrEqual(min(backToBox.frame.w, backToBox.frame.h), 2)
    }

    // MARK: Drawer

    func testDrawerPaintsEveryKind() throws {
        let drawer = ShapeDrawer()
        for kind in ShapeKind.allCases {
            let s = try ShapeGeometry.make(kind, frame: Frame(x: 20, y: 20, w: 120, h: 80), points: nil,
                                           style: ShapeItemStyle(strokeWidth: 3))
            let pixels = inkedPixels { cg in
                drawer.draw(Item.makeShape(s), in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1))
            }
            XCTAssertGreaterThan(pixels, 60, "\(kind) drew nothing")
        }
    }

    func testDrawerFillsFillOnlyShapesAndDrawsTextAndInk() throws {
        let frame = Frame(x: 10, y: 10, w: 100, h: 60)
        let fill = try XCTUnwrap(RGBA(hex: "#2156D980"))
        let fillOnly = ShapeItem(shape: .rectangle, frame: frame, style: ShapeItemStyle(strokeColor: nil, fillColor: fill))
        XCTAssertGreaterThan(pixels(of: fillOnly), 5_500)
        let plain = ShapeItem(shape: .ellipse, frame: frame)
        var worded = plain
        worded.text = RichText(plain: "Hello")
        XCTAssertGreaterThan(pixels(of: worded), pixels(of: plain))
        var inked = plain
        inked.style.drawnWith = .pencil
        inked.style.pattern = .dashed
        XCTAssertGreaterThan(pixels(of: inked), 40)
    }

    func testTextEditorRoundTripsPageUnits() throws {
        var s = ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 200, h: 100))
        var text = RichText(plain: "Big idea")
        text.paragraphs[0].runs[0].attrs.bold = true
        text.paragraphs[0].runs[0].attrs.size = 24
        s.text = text
        let attributed = ShapeTextStyle.attributed(text, shape: s, darkPaper: false, scale: 2.5)
        let back = ShapeTextStyle.richText(attributed, shape: s, scale: 2.5)
        XCTAssertEqual(back.plainText, "Big idea")
        let run = try XCTUnwrap(back.paragraphs.first?.runs.first)
        XCTAssertEqual(run.attrs.size, 24)
        XCTAssertEqual(run.attrs.bold, true)
        XCTAssertNil(run.attrs.color)
        XCTAssertEqual(back.paragraphs.first?.align, .natural)
    }

    // MARK: Tool

    func testToolDragCreatesTheChosenShapeAndATapPlacesOne() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        h.app.settings.set(ShapeSettings.kind, ShapeLibraryEntry.ellipse.rawValue)
        h.app.settings.set(ShapeSettings.fill, "#2156D9")
        let host = FakeCanvasHost(h)
        let tool = ShapeTool()
        h.session.selectTool("pen")
        h.session.selectTool(ShapeTool.toolID)
        tool.activate(host)
        tool.tap(CanvasSample(page: Fixtures.page2, location: Point(300, 400)), host: host)
        await tool.pendingCreate?.value
        var items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.shape?.frame.center, Point(300, 400))
        XCTAssertEqual(host.renderWaits, [Fixtures.page2], "the preview waits for the tiles")
        XCTAssertEqual(h.session.tool, "pen", "non-sticky: one shape, then back to the previous tool")

        tool.touchesBegan(CanvasSample(page: Fixtures.page2, location: Point(100, 100)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page2, location: Point(220, 180))], host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page2, location: Point(220, 180)), host: host)
        tool.tap(CanvasSample(page: Fixtures.page2, location: Point(220, 180)), host: host)   // the same touch: ignored
        await tool.pendingCreate?.value
        items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(items.count, 2)
        let s = try XCTUnwrap(items.last?.shape)
        XCTAssertEqual(s.shape, .ellipse)
        XCTAssertEqual(s.frame, Frame(x: 100, y: 100, w: 120, h: 80))
        XCTAssertEqual(s.style.fillColor?.sameHue(NibInk.cobalt.rgba), true)
        XCTAssertEqual(s.style.fillColor?.alpha ?? 0, 0.35, accuracy: 0.01)
        tool.deactivate(host)
    }

    func testLibraryEntriesBuildTheirShapes() {
        let style = ShapeItemStyle()
        let star = ShapeLibraryEntry.star.shape(from: .zero, to: Point(100, 80), constrain: false, fromCentre: false, style: style)
        XCTAssertEqual(star.shape, .polygon)
        XCTAssertEqual(star.points.count, 10)
        XCTAssertEqual(star.frame.w, 100, accuracy: 1e-6)
        XCTAssertEqual(star.frame.h, 80, accuracy: 1e-6)
        let square = ShapeLibraryEntry.rectangle.shape(from: Point(10, 10), to: Point(60, 30), constrain: true,
                                                       fromCentre: false, style: style)
        XCTAssertEqual(square.frame, Frame(x: 10, y: 10, w: 50, h: 50))
        let level = ShapeLibraryEntry.line.shape(from: .zero, to: Point(100, 3), constrain: true, fromCentre: false, style: style)
        XCTAssertEqual(level.points[1].y, 0, accuracy: 1e-9)
        let double = ShapeLibraryEntry.doubleArrow.shape(from: .zero, to: Point(100, 0), constrain: false,
                                                         fromCentre: false, style: style)
        XCTAssertEqual(ShapeGeometry.strokeParts(double).heads.count, 2)
        let rounded = ShapeLibraryEntry.roundedRectangle.shape(from: .zero, to: Point(200, 100), constrain: false,
                                                               fromCentre: false, style: style)
        XCTAssertEqual(rounded.style.cornerRadius, 20)
    }

    // MARK: Control points and text

    func testControlPointEditsAreRoundTrips() throws {
        let tri = ShapeItem(shape: .triangle, frame: Frame(x: 0, y: 0, w: 100, h: 80))
        let knobs = ShapeControlPoints.knobs(tri, minInset: 10)
        XCTAssertEqual(knobs.map(\.point), [Point(50, 0), Point(100, 80), Point(0, 80)])
        XCTAssertEqual(ShapeControlPoints.edit(tri, knob: knobs[0], to: Point(20, -10), minInset: 10),
                       .points([Point(20, -10), Point(100, 80), Point(0, 80)]))
        let rect = ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 200, h: 100), style: ShapeItemStyle(cornerRadius: 12))
        let corner = try XCTUnwrap(ShapeControlPoints.knobs(rect, minInset: 10).first)
        XCTAssertEqual(ShapeControlPoints.edit(rect, knob: corner, to: corner.point, minInset: 10), .cornerRadius(12))
        XCTAssertTrue(ShapeControlPoints.knobs(ShapeItem(shape: .ellipse, frame: rect.frame), minInset: 10).isEmpty)
        let curve = ShapeItem(shape: .curve, frame: rect.frame, points: [Point(0, 0), Point(50, -40), Point(100, 0)])
        XCTAssertEqual(ShapeControlPoints.knobs(curve, minInset: 10).map(\.role), [.vertex, .control, .vertex])
    }

    func testDraggingTheCornerKnobRoundsTheRectangle() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let host = FakeCanvasHost(h)
        let overlay = ShapeEditOverlay()
        overlay.attach(to: host)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        overlay.canvasDidChange(host)
        XCTAssertFalse(overlay.hitTest(CGPoint(x: 500, y: 700), host: host))
        let knob = try XCTUnwrap(overlay.knobs.first)
        XCTAssertEqual(overlay.knobs.count, 1)
        XCTAssertTrue(overlay.hitTest(host.viewPoint(knob.point, page: Fixtures.page1), host: host))
        overlay.touchesBegan(CanvasSample(page: Fixtures.page1, location: knob.point), host: host)
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.shapeID])
        let to = Point(knob.point.x + 20, knob.point.y + 20)
        overlay.touchesMoved([CanvasSample(page: Fixtures.page1, location: to)], host: host)
        overlay.touchesEnded(CanvasSample(page: Fixtures.page1, location: to), host: host)
        await overlay.pendingCommit?.value
        XCTAssertEqual(try shape(h, Fixtures.shapeID).style.cornerRadius, 42, accuracy: 0.5)
        XCTAssertNil(host.hidden[Fixtures.page1])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)

        // A tap on a knob is not a reshape: it passes on to the tap handlers (shape.tapAt types into the shape).
        let moved = try XCTUnwrap(overlay.knobs.first)
        XCTAssertTrue(overlay.hitTest(host.viewPoint(moved.point, page: Fixtures.page1), host: host))
        let tapSample = CanvasSample(page: Fixtures.page1, location: moved.point)
        overlay.touchesBegan(tapSample, host: host)
        overlay.touchesEnded(tapSample, host: host)
        XCTAssertFalse(overlay.gesture(.tap, at: tapSample, host: host))
        XCTAssertNil(host.hidden[Fixtures.page1])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        overlay.detach(from: host)
    }

    func testTappingTheSelectedShapeEditsItsText() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerTextStandIn(h.app)
        let host = FakeCanvasHost(h)
        let overlay = ShapeEditOverlay()
        overlay.attach(to: host)
        let tap: JSONValue = ["page": .string(page1Ref), "point": [180, 245], "gesture": "tap"]
        var r = try await h.run("shape.tapAt", tap)
        XCTAssertEqual(r["handled"], .bool(false), "a tap on an unselected shape is selection's")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        r = try await h.run("shape.tapAt", tap)
        XCTAssertEqual(r["handled"], .bool(true))
        let editor = try XCTUnwrap(overlay.text)
        XCTAssertTrue(h.session.isEditingText)
        XCTAssertEqual(h.session.editingTextRef, shapeRef)
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.shapeID])
        editor.textView.attributedText = NSAttributedString(string: "Plan B", attributes: editor.textView.typingAttributes)
        editor.textView.selectedRange = NSRange(location: 5, length: 1)
        overlay.textViewDidChangeSelection(editor.textView)
        XCTAssertEqual(h.session.editingTextRange, [5, 1])
        // A tap inside the text while editing belongs to the editor, never to the tap handlers.
        let inside = editor.textView.convert(CGPoint(x: editor.textView.bounds.midX, y: editor.textView.bounds.midY),
                                             to: host.canvasView)
        let sample = CanvasSample(page: Fixtures.page1, location: Point(180, 245))
        XCTAssertTrue(overlay.hitTest(inside, host: host))
        overlay.touchesEnded(sample, host: host)
        XCTAssertTrue(overlay.gesture(.tap, at: sample, host: host))
        XCTAssertNotNil(overlay.text)
        overlay.endTextEditing(commit: true)
        await overlay.pendingFlush?.value
        XCTAssertEqual(try shape(h, Fixtures.shapeID).text?.plainText, "Plan B")
        XCTAssertFalse(h.session.isEditingText)
        XCTAssertNil(h.session.editingTextRef)
        XCTAssertNil(h.session.editingTextRange)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertNil(try shape(h, Fixtures.shapeID).text)
        overlay.detach(from: host)
    }

    // MARK: Containers

    func testContainerPlanPicksTheSmallestEnclosingShapeAndNeverACycle() {
        let big = Item(id: "BIG", kind: .shape, z: "V",
                       shape: ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 400, h: 400)))
        let small = Item(id: "SMALL", kind: .shape, z: "k",
                         shape: ShapeItem(shape: .ellipse, frame: Frame(x: 100, y: 100, w: 200, h: 200)))
        var ink = Item(id: "INK", kind: .stroke, z: "t",
                       stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: 180, y: 190), StrokePoint(x: 220, y: 210)]))
        XCTAssertEqual(ShapeContainers.plan(moved: ["INK"], items: [big, small, ink]),
                       [ShapeContainers.Change(item: "INK", parent: "SMALL")])

        ink.attachedTo = "SMALL"
        ink.stroke = Stroke(style: .defaultPen, points: [StrokePoint(x: 500, y: 500), StrokePoint(x: 520, y: 510)])
        XCTAssertEqual(ShapeContainers.plan(moved: ["INK"], items: [big, small, ink]),
                       [ShapeContainers.Change(item: "INK", parent: nil)])

        // A shape never moves into something that hangs from it.
        var outer = big
        outer.attachedTo = "SMALLBOX"
        let inner = Item(id: "SMALLBOX", kind: .shape, z: "x",
                         shape: ShapeItem(shape: .rectangle, frame: Frame(x: 150, y: 150, w: 50, h: 50)))
        XCTAssertEqual(ShapeContainers.plan(moved: ["SMALLBOX"], items: [outer, inner]), [])
    }

    func testDroppingAnItemIntoAShapeAttachesItInTheSameUndoStep() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerMoveStandIns(h.app)
        await FeatShapesFeature.start(h.app)
        let watcher = try XCTUnwrap(h.app.services.get(ShapeContainerWatcher.serviceKey, as: ShapeContainerWatcher.self))
        // The maths item (72, 480, 120 × 40) moves inside the fixture rectangle (100, 200, 160 × 90).
        try await h.run("item.transform", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01"], "translate": [48, -260]])
        await watcher.pending?.value
        let math = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID)
        XCTAssertEqual(math.attachedTo, Fixtures.shapeID)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        let restored = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID)
        XCTAssertNil(restored.attachedTo)
        XCTAssertEqual(restored.frame, Frame(x: 72, y: 480, w: 120, h: 40))
    }

    // MARK: Helpers

    static func samplePoints(_ kind: ShapeKind) -> [Point] {
        switch kind {
        case .arc: return [Point(40, 140), Point(100, 40), Point(160, 140)]
        case .curve: return [Point(40, 140), Point(80, 40), Point(120, 160), Point(160, 60)]
        case .polyline: return [Point(40, 140), Point(100, 60), Point(160, 140)]
        case .polygon: return [Point(40, 140), Point(100, 40), Point(160, 140), Point(130, 160)]
        default: return [Point(40, 60), Point(160, 140)]
        }
    }

    private func shape(_ h: Harness, _ id: ElementID) throws -> ShapeItem {
        try XCTUnwrap(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: id).shape)
    }

    private func connectorStart(_ h: Harness) throws -> Point? {
        try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.connectorID).connector?.from.point
    }

    private func assertInvalid(_ h: Harness, _ command: String, _ params: JSONValue,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await h.run(command, params)
            XCTFail("\(command) accepted \(params.jsonString())", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams, e.description, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    private func pixels(of s: ShapeItem) -> Int {
        inkedPixels { cg in ShapeRenderer.draw(s, in: cg, scale: 1, darkPaper: false) }
    }

    /// Pixels with visible alpha after drawing into a transparent 160 × 120 pt bitmap at 1×.
    private func inkedPixels(_ draw: (CGContext) -> Void) -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { draw($0.cgContext) }
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 8 }.count
    }

    /// F026's `text.setText`, reduced to what shapes need.
    static func registerTextStandIn(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "text.setText", title: "Set Text", summary: "Test stand-in.",
                                                params: .obj(["ref": .ref, "text": .anything()], required: ["ref", "text"]),
                                                effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            let text = try (json["text"] ?? .null).decode(RichText.self)
            try ctx.mutate { tx in
                var item = try tx.item(doc, page: page, id: id)
                item.shape?.text = text
                try tx.put(item, doc: doc, page: page)
            }
            return [:]
        }
    }

    /// F012's `item.transform` (translate only) and F003's `item.update`, reduced to what containers need.
    static func registerMoveStandIns(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.itemTransform, title: "Move", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["refs"]?[0]?.stringValue ?? ""),
                  let dx = json["translate"]?[0]?.doubleValue, let dy = json["translate"]?[1]?.doubleValue else {
                throw NibError.invalid("refs / translate")
            }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                try tx.put(item.transformed(by: .translation(dx, dy)), doc: doc, page: page)
            }
            return [:]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.itemUpdate, title: "Update", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                let merged = try JSONValue.from(item).merging(json["patch"] ?? [:]).decode(Item.self)
                try tx.put(merged, doc: doc, page: page)
            }
            return [:]
        }
    }
}
