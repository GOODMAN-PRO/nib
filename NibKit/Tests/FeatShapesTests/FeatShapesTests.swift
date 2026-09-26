import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibDesign
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
        XCTAssertEqual(back.paragraphs.first?.align, .center, "labels store their centring for link hits and search")
        // On dark paper the editor shows the outline colour as chalk; it is still left implicit.
        let dark = ShapeTextStyle.attributed(text, shape: s, darkPaper: true, scale: 1)
        XCTAssertNil(ShapeTextStyle.richText(dark, shape: s, scale: 1).paragraphs.first?.runs.first?.attrs.color)
    }

    func testShapeCreateCentresLabelsAndKeepsRectanglesSharp() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        for (kind, radius) in [("rectangle", 0.0), ("triangle", 0), ("diamond", 0), ("roundedRectangle", 20)] {
            let value = try await h.run("shape.create", ["page": .string(page2Ref), "shape": .string(kind),
                                                         "frame": [10, 10, 200, 100], "text": "Plan"])
            guard case let .item(_, _, id)? = NodeRef(value["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
            let s = try XCTUnwrap(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id).shape)
            XCTAssertEqual(s.style.cornerRadius, radius, kind)
            XCTAssertEqual(s.text?.paragraphs.first?.align, .center, kind)
        }
        let polygon = try await h.run("shape.create", ["page": .string(page2Ref), "shape": "polygon",
                                                       "points": [[0, 0], [60, 0], [30, 40]]])
        guard case let .item(_, _, pid)? = NodeRef(polygon["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: pid).shape?.style.cornerRadius, 0)
        let asked = try await h.run("shape.create", ["page": .string(page2Ref), "shape": "rectangle",
                                                     "frame": [10, 10, 50, 50], "style": ["cornerRadius": 8]])
        guard case let .item(_, _, aid)? = NodeRef(asked["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: aid).shape?.style.cornerRadius, 8)
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
        // The knob sits cornerInset (22 pt) in at radius 0 and mid short side (45 pt) at the largest radius: from
        // radius 6 (25.07 pt in), 10 pt further in along the diagonal is 35.07 pt, radius 25.5.
        let to = Point(knob.point.x + 10, knob.point.y + 10)
        overlay.touchesMoved([CanvasSample(page: Fixtures.page1, location: to)], host: host)
        overlay.touchesEnded(CanvasSample(page: Fixtures.page1, location: to), host: host)
        await overlay.pendingCommit?.value
        XCTAssertEqual(try shape(h, Fixtures.shapeID).style.cornerRadius, 25.5, accuracy: 0.5)
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
        Self.registerTransformStandIn(h.app)
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

    func testShapeAttachPutsItemsInAShapeInOneTransaction() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let refs: JSONValue = [ref(Fixtures.mathID, page: Fixtures.page1), ref(Fixtures.strokeID, page: Fixtures.page1)]
        try await h.run("shape.attach", ["refs": refs, "container": .string(shapeRef)], as: .ai("chat"))
        for id in [Fixtures.mathID, Fixtures.strokeID] {
            XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: id).attachedTo, Fixtures.shapeID)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        // Never itself, never a cycle, never an open shape, never a connector.
        await assertInvalid(h, "shape.attach", ["refs": [.string(shapeRef)], "container": .string(shapeRef)])
        try await h.run("shape.create", ["page": .string(page1Ref), "shape": "rectangle", "frame": [110, 210, 40, 30],
                                         "id": "INNER"])
        try await h.run("shape.attach", ["refs": [ref("INNER", page: Fixtures.page1)], "container": .string(shapeRef)])
        await assertInvalid(h, "shape.attach", ["refs": [.string(shapeRef)], "container": ref("INNER", page: Fixtures.page1)])
        try await h.run("shape.create", ["page": .string(page1Ref), "shape": "line", "points": [[0, 0], [50, 50]], "id": "LINE"])
        await assertInvalid(h, "shape.attach", ["refs": [ref(Fixtures.mathID, page: Fixtures.page1)],
                                                "container": ref("LINE", page: Fixtures.page1)])
        await assertInvalid(h, "shape.attach", ["refs": [ref(Fixtures.connectorID, page: Fixtures.page1)],
                                                "container": .string(shapeRef)])
        // null releases.
        try await h.run("shape.attach", ["refs": refs, "container": .null])
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).attachedTo)
    }

    func testRotatingAContainerKeepsWhatItCarries() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerTransformStandIn(h.app)
        await FeatShapesFeature.start(h.app)
        let watcher = try XCTUnwrap(h.app.services.get(ShapeContainerWatcher.serviceKey, as: ShapeContainerWatcher.self))
        let box = Item(id: "BOX", kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 100, w: 200, h: 120)))
        let label = Item(id: "LABEL", kind: .text, attachedTo: "BOX",
                         text: TextBoxItem(frame: Frame(x: 130, y: 140, w: 140, h: 40), text: RichText(plain: "Inside")))
        try await h.insert([box, label], page: Fixtures.page2)
        // F012 carries attached children: both turn 45° about the box's centre. The label's bounds now poke out of the
        // turned outline, but its parent moved with it, so it stays attached.
        try await h.run(CommandIDs.itemTransform, ["refs": [ref("BOX"), ref("LABEL")], "rotate": 45, "origin": [200, 160]])
        await watcher.pending?.value
        var moved = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "LABEL")
        XCTAssertEqual(moved.attachedTo, "BOX")
        XCTAssertEqual(moved.frame?.rotation ?? 0, Double.pi / 4, accuracy: 1e-9)
        // Nudged on its own it is tested by its turned frame, which is still inside.
        try await h.run(CommandIDs.itemTransform, ["refs": [ref("LABEL")], "translate": [2, 2]])
        await watcher.pending?.value
        moved = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "LABEL")
        XCTAssertEqual(moved.attachedTo, "BOX")
        // Dragged out, it is released.
        try await h.run(CommandIDs.itemTransform, ["refs": [ref("LABEL")], "translate": [400, 0]])
        await watcher.pending?.value
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: "LABEL").attachedTo)
    }

    func testItemsDroppedOnAStickyNoteAreLeftForTheNote() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerTransformStandIn(h.app)
        await FeatShapesFeature.start(h.app)
        let watcher = try XCTUnwrap(h.app.services.get(ShapeContainerWatcher.serviceKey, as: ShapeContainerWatcher.self))
        // A closed shape around the fixture note (400, 120, 140 × 140, expanded).
        try await h.insert([Item(id: "FRAME", kind: .shape,
                                 shape: ShapeItem(shape: .rectangle, frame: Frame(x: 380, y: 100, w: 200, h: 200)))])
        let math = ref(Fixtures.mathID, page: Fixtures.page1)
        // Without the Sticky Notes feature nothing else claims the maths item (72, 480, 120 × 40) landing on the note:
        // the shape takes it, and lets go when it leaves.
        try await h.run(CommandIDs.itemTransform, ["refs": [math], "translate": [340, -330]])
        await watcher.pending?.value
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).attachedTo, "FRAME")
        try await h.run(CommandIDs.itemTransform, ["refs": [math], "translate": [-340, 330]])
        await watcher.pending?.value
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).attachedTo)
        // With it (F036 attaches drops through item.update), the note takes the item, so the shape leaves it:
        // whichever observer ran last would otherwise win.
        for id in [ShapeContainers.stickyCommand, CommandIDs.itemUpdate] {
            h.app.commands.register(CommandDescriptor(id: id, title: "Stand-in", summary: "Test stand-in.",
                                                      params: .anything(), effect: .edit)) { _, _ in .null }
        }
        try await h.run(CommandIDs.itemTransform, ["refs": [math], "translate": [340, -330]])
        await watcher.pending?.value
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).attachedTo)
        // The note itself goes into the shape when it moves (notes never nest, so no note claims it).
        let note = ref(Fixtures.stickyID, page: Fixtures.page1)
        try await h.run(CommandIDs.itemTransform, ["refs": [note], "translate": [4, 4]])
        await watcher.pending?.value
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).attachedTo, "FRAME")
        // A collapsed note claims nothing: then the shape takes the item.
        var sticky = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        sticky.sticky?.collapsed = true
        try await h.insert([sticky])
        try await h.run(CommandIDs.itemTransform, ["refs": [math], "translate": [2, 2]])
        await watcher.pending?.value
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).attachedTo, "FRAME")
    }

    func testNudgingTwoThousandStrokesIntoABoxIsOneQuickStep() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerTransformStandIn(h.app)
        await FeatShapesFeature.start(h.app)
        let watcher = try XCTUnwrap(h.app.services.get(ShapeContainerWatcher.serviceKey, as: ShapeContainerWatcher.self))
        let box = Item(id: "BOX", kind: .shape, shape: ShapeItem(shape: .rectangle, frame: Frame(x: 40, y: 40, w: 440, h: 440)))
        let strokes = (0..<2_000).map { i -> Item in
            let x = Float(60 + (i % 50) * 8), y = Float(500 + (i / 50) * 7)
            return Item(id: ElementID("S\(i)"), kind: .stroke,
                        stroke: Stroke(style: .defaultPen, points: [StrokePoint(x: x, y: y), StrokePoint(x: x + 4, y: y + 3)]))
        }
        try await h.insert([box] + strokes, page: Fixtures.page2)
        h.app.bus.history.clear(Fixtures.docID)
        // One lasso nudge of all of them into the box, attachments included, on the main actor.
        let budget = 0.75
        let start = Date()
        try await h.run(CommandIDs.itemTransform, ["refs": .array(strokes.map { ref($0.id) }), "translate": [0, -430]])
        await watcher.pending?.value
        let elapsed = Date().timeIntervalSince(start)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(items.filter { $0.attachedTo == "BOX" }.count, 2_000)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "the move and its attachments are one undo step")
        XCTAssertLessThan(elapsed, budget * 4, "2,000 strokes took \(elapsed) s")
        h.app.bus.undo(Fixtures.docID)
        let restored = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertTrue(restored.allSatisfy { $0.attachedTo == nil })
        XCTAssertEqual(restored.first { $0.id == "S0" }?.stroke?.points.first?.y, 500)
    }

    // MARK: Big shapes

    func testClippingKeepsTheDashPhase() throws {
        let line = [Point(0, 0), Point(100, 0)]
        let pieces = ShapeGeometry.clipped(line, to: Rect(x: 25, y: -5, width: 30, height: 10))
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(piece.offset, 25, accuracy: 1e-9)
        XCTAssertEqual(piece.points.first?.x ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(piece.points.last?.x ?? 0, 55, accuracy: 1e-9)
        // Every dash of the cut piece lies on a dash of the whole line.
        let whole = ShapeGeometry.dashed(line, on: 4, off: 6)
        let cut = ShapeGeometry.dashed(piece.points, on: 4, off: 6, phase: piece.offset)
        XCTAssertEqual(cut.count, 3)
        for dash in cut {
            let mid = ((dash.first?.x ?? 0) + (dash.last?.x ?? 0)) / 2
            XCTAssertTrue(whole.contains { ($0.first?.x ?? 0) - 1e-9 <= mid && mid <= ($0.last?.x ?? 0) + 1e-9 }, "\(mid)")
        }
        // Leaving and re-entering makes two pieces, offsets measured along the whole line.
        let hook = [Point(0, 0), Point(50, 0), Point(50, 50), Point(0, 50)]
        let two = ShapeGeometry.clipped(hook, to: Rect(x: -10, y: -10, width: 30, height: 80))
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.last?.offset ?? 0, 130, accuracy: 1e-9)
        XCTAssertTrue(ShapeGeometry.clipped(hook, to: Rect(x: 200, y: 200, width: 10, height: 10)).isEmpty)
    }

    func testHugeInkShapesDrawOnlyWhatShows() throws {
        for pattern in [StrokePattern.dotted, .dashed] {
            let style = ShapeItemStyle(strokeWidth: 2, pattern: pattern, drawnWith: .pencil)
            for kind in [ShapeKind.rectangle, .ellipse] {
                let huge = ShapeItem(shape: kind, frame: Frame(x: 20, y: 20, w: 1_000_000, h: 1_000_000), style: style)
                let parts = ShapeGeometry.strokeParts(huge)
                XCTAssertNil(ShapeRenderer.inkLines(parts, style: style, area: nil), "\(kind) \(pattern): uncut it is vector dashes")
                let area = Rect(x: 0, y: 0, width: 160, height: 120)
                let visible = try XCTUnwrap(ShapeRenderer.inkLines(parts, style: style, area: area))
                XCTAssertLessThan(visible.count, 200, "\(kind) \(pattern): only the dashes near the drawn area become ink")
                let start = Date()
                let drawn = pixels(of: huge)
                XCTAssertLessThan(Date().timeIntervalSince(start), 2, "\(kind) \(pattern)")
                if kind == .rectangle, pattern == .dashed { XCTAssertGreaterThan(drawn, 20, "the top and left edges show") }
            }
        }
        // Normal shapes keep whole outlines (the pencil grain matches across tiles).
        let small = ShapeItem(shape: .rectangle, frame: Frame(x: 10, y: 10, w: 100, h: 60))
        XCTAssertNil(ShapeRenderer.cut(ShapeGeometry.strokeParts(small), area: Rect(x: 0, y: 0, width: 50, height: 50)))
    }

    func testShapesBeyondTheLargestPageAreRejected() async {
        let h = Harness(features: [FeatShapesFeature.self])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "rectangle",
                                                "frame": [0, 0, 5_000_000, 5_000_000], "style": ["drawnWith": "pencil"]])
        await assertInvalid(h, "shape.create", ["page": .string(page2Ref), "shape": "line", "points": [[0, 0], [200_000, 0]]])
        await assertInvalid(h, "shape.setPoints", ["ref": .string(shapeRef), "points": [[-150_000, 0], [10, 10]]])
    }

    // MARK: Inspector

    func testInspectorFollowsTheSelection() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let a = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [a.id])
        let model = ShapeInspectorModel(context: InspectorContext(app: h.app, session: h.session, doc: Fixtures.docID,
                                                                  page: Fixtures.page1, items: [a]))
        model.start()
        try await h.run("shape.create", ["page": .string(page1Ref), "shape": "ellipse", "frame": [300, 600, 120, 80],
                                         "id": "SHAPEB"])
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: ["SHAPEB"])
        XCTAssertEqual(model.items.map(\.id), ["SHAPEB"])
        model.apply(key: "outline") { $0.strokeColor = .set(NibInk.crimson.rgba) }
        await model.pendingRun?.value
        XCTAssertEqual(try shape(h, "SHAPEB").style.strokeColor, NibInk.crimson.rgba)
        XCTAssertEqual(try shape(h, Fixtures.shapeID).style.strokeColor, a.shape?.style.strokeColor)
        model.stop()
    }

    func testArrowEndOffTurnsAnArrowIntoALine() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        let value = try await h.run("shape.create", ["page": .string(page2Ref), "shape": "arrow", "points": [[10, 10], [200, 80]]])
        guard case let .item(_, _, id)? = NodeRef(value["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id)
        let model = ShapeInspectorModel(context: InspectorContext(app: h.app, session: h.session, doc: Fixtures.docID,
                                                                  page: Fixtures.page2, items: [item]))
        model.start()
        model.setArrowEnd(false)
        await model.pendingRun?.value
        var s = try XCTUnwrap(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id).shape)
        XCTAssertEqual(s.shape, .line)
        XCTAssertFalse(s.style.arrowEnd)
        XCTAssertTrue(ShapeGeometry.strokeParts(s).heads.isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2, "the create, then one step for the type and the head")
        model.setArrowEnd(true)
        await model.pendingRun?.value
        s = try XCTUnwrap(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id).shape)
        XCTAssertEqual(s.shape, .line)
        XCTAssertEqual(ShapeGeometry.strokeParts(s).heads.count, 1)
        model.stop()
    }

    func testLibraryAndInspectorFitThePopoverInEveryAppearance() throws {
        let h = Harness(features: [FeatShapesFeature.self])
        h.app.commands.register(CommandDescriptor(id: "preset.select", title: "Preset", summary: "Test stand-in.",
                                                  params: .anything(), effect: .session)) { _, _ in .null }
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        let context = InspectorContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, items: [item])
        let width = NibMetrics.popoverWidth
        let screens: [(String, AnyView)] = [
            ("library", AnyView(ShapeLibraryMenu(app: h.app, session: h.session).padding(NibSpacing.l))),
            ("inspector", AnyView(ShapeStyleInspector(context: context).padding(NibSpacing.l)))
        ]
        for (name, view) in screens {
            let images = NibSnapshot.images(view, size: CGSize(width: width, height: NibMetrics.popoverMaxHeight))
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases), "\(name) renders light, dark and AX3")
            var heights: [NibSnapshot.Variant: CGFloat] = [:]
            for variant in NibSnapshot.Variant.allCases {
                let fitting = NibSnapshot.fittingSize(view, width: width, variant: variant)
                XCTAssertLessThanOrEqual(fitting.width, width + 0.5, "\(name) is wider than the popover in \(variant)")
                heights[variant] = fitting.height
            }
            XCTAssertGreaterThan(heights[.largeText] ?? 0, heights[.light] ?? 0, "\(name) grows with AX3 text, never clips it")
        }
    }

    // MARK: Tool, knobs and text on dark paper

    func testToolStyleNeverDrawsAnInvisibleShape() {
        let h = Harness(features: [FeatShapesFeature.self])
        let presets = h.app.settings.get(NibSettings.presets(ShapeTool.toolID))
        h.app.settings.set(ShapeSettings.outline, false)
        h.app.settings.set(ShapeSettings.fill, "")
        var s = ShapeToolStyle.current(h.app, entry: .rectangle)
        XCTAssertEqual(s.strokeColor, presets.color, "outline off and no fill falls back to an outline")
        XCTAssertNil(s.fillColor)
        h.app.settings.set(ShapeSettings.fill, "#2156D9")
        s = ShapeToolStyle.current(h.app, entry: .rectangle)
        XCTAssertNil(s.strokeColor)
        XCTAssertEqual(s.fillColor?.sameHue(NibInk.cobalt.rgba), true)
        s = ShapeToolStyle.current(h.app, entry: .arrow)
        XCTAssertEqual(s.strokeColor, presets.color, "lines always have an outline and never a fill")
        XCTAssertNil(s.fillColor)
    }

    func testLibraryFollowsTheDesignGridAndConnectsShapes() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        XCTAssertEqual(Array(ShapeLibraryEntry.allCases.prefix(8)),
                       [.line, .arrow, .rectangle, .ellipse, .triangle, .star, .polygon, .connector])
        XCTAssertFalse(ShapeLibraryEntry.available(h.app).contains(.connector), "hidden while connector.create is missing")
        h.app.settings.set(ShapeSettings.kind, ShapeLibraryEntry.connector.rawValue)
        XCTAssertEqual(ShapeLibraryEntry.current(h.app), .arrow)
        var created: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: ShapeLibraryEntry.connectorCommand, title: "Connect",
                                                  summary: "Test stand-in.", params: .anything(), effect: .edit)) { json, _ in
            created.append(json)
            return ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01"]
        }
        XCTAssertTrue(ShapeLibraryEntry.available(h.app).contains(.connector))
        XCTAssertEqual(ShapeLibraryEntry.current(h.app), .connector)
        // A drag from inside the fixture rectangle to bare paper connects the shape to a point.
        let host = FakeCanvasHost(h)
        let tool = ShapeTool()
        h.session.selectTool(ShapeTool.toolID)
        tool.activate(host)
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(180, 245)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(420, 330))], host: host)
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(420, 330)), host: host)
        await tool.pendingCreate?.value
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?["from"]?["item"]?.stringValue, shapeRef)
        XCTAssertEqual(created.first?["to"]?["point"], [420, 330])
        tool.deactivate(host)
    }

    func testKnobsAreHandleBeadsAndThePencilInksBesideThem() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        try await h.run("shape.create", ["page": .string(page1Ref), "shape": "triangle", "frame": [300, 600, 120, 90],
                                         "id": "TRI"])
        try await h.run("shape.create", ["page": .string(page1Ref), "shape": "curve",
                                         "points": [[300, 760], [360, 710], [420, 760]], "id": "CURVE"])
        let host = FakeCanvasHost(h)
        let overlay = ShapeEditOverlay()
        overlay.attach(to: host)
        defer { overlay.detach(from: host) }
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: ["TRI"])
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.knobs.count, 3)
        let beads = overlay.knobViews.filter { !$0.isHidden }
        XCTAssertEqual(beads.map(\.style), [.clear, .clear, .clear])
        XCTAssertTrue(beads.allSatisfy { !$0.isUserInteractionEnabled })
        let apex = host.viewPoint(overlay.knobs[0].point, page: Fixtures.page1)
        XCTAssertEqual(beads[0].center.x, apex.x, accuracy: 0.01)
        XCTAssertEqual(beads[0].center.y, apex.y, accuracy: 0.01)
        h.session.selectTool("pen")
        XCTAssertFalse(overlay.hitTest(apex, isPencil: true, host: host), "a pen stroke next to a vertex inks")
        XCTAssertTrue(overlay.hitTest(apex, isPencil: false, host: host), "a finger reshapes")
        h.session.selectTool("lasso")
        XCTAssertTrue(overlay.hitTest(apex, isPencil: true, host: host))
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: ["CURVE"])
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.knobViews.filter { !$0.isHidden }.map(\.style), [.clear, .tinted, .clear],
                       "control points are tinted beads")
    }

    func testTextOnDarkPaperIsChalkWhileEditing() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerTextStandIn(h.app)
        try await Self.setPaper(h, NibPaper.slate.rgba, page: Fixtures.page1)
        XCTAssertTrue(ShapePaper.isDark(h.app, doc: Fixtures.docID, page: Fixtures.page1))
        XCTAssertFalse(ShapePaper.isDark(h.app, doc: Fixtures.docID, page: Fixtures.page2))
        XCTAssertEqual(ShapePaper.paper("night"), NibPaper.night.rgba)
        let host = FakeCanvasHost(h)
        let overlay = ShapeEditOverlay()
        overlay.attach(to: host)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        let r = try await h.run("shape.tapAt", ["ref": .string(shapeRef), "gesture": "button"])
        XCTAssertEqual(r["handled"], .bool(true))
        let editor = try XCTUnwrap(overlay.text)
        XCTAssertTrue(editor.darkPaper)
        let typing = try XCTUnwrap(editor.textView.typingAttributes[.foregroundColor] as? UIColor)
        XCTAssertEqual(RGBA(typing).rgbHex, NibInk.chalk.rgba.rgbHex, "black text on slate would be invisible")
        editor.textView.attributedText = NSAttributedString(string: "Night shift", attributes: editor.textView.typingAttributes)
        overlay.endTextEditing(commit: true)
        await overlay.pendingFlush?.value
        let stored = try shape(h, Fixtures.shapeID).text
        XCTAssertEqual(stored?.plainText, "Night shift")
        XCTAssertNil(stored?.paragraphs.first?.runs.first?.attrs.color, "chalk is how the page shows the outline colour")
        overlay.detach(from: host)
    }

    func testDoubleTapSelectsAndEditsAnUnselectedShape() async throws {
        let h = Harness(features: [FeatShapesFeature.self])
        Self.registerTextStandIn(h.app)
        let host = FakeCanvasHost(h)
        let overlay = ShapeEditOverlay()
        overlay.attach(to: host)
        defer { overlay.detach(from: host) }
        XCTAssertTrue(h.session.selection.isEmpty)
        let r = try await h.run("shape.tapAt", ["page": .string(page1Ref), "point": [180, 245], "gesture": "doubleTap"])
        XCTAssertEqual(r["handled"], .bool(true))
        XCTAssertEqual(h.session.selection.items, [Fixtures.shapeID])
        XCTAssertNotNil(overlay.text)
        XCTAssertEqual(h.session.editingTextRef, shapeRef)
        overlay.endTextEditing(commit: false)
        // Lines take no text, even on a double-tap.
        try await h.run("shape.create", ["page": .string(page2Ref), "shape": "line", "points": [[0, 20], [100, 20]]])
        let line = try await h.run("shape.tapAt", ["page": .string(page2Ref), "point": [50, 20], "gesture": "doubleTap"])
        XCTAssertEqual(line["handled"], .bool(false))
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

    /// F012's `item.transform` reduced to what containers need: {refs (one page), translate [dx, dy] | rotate
    /// (degrees) + origin [x, y]}, every item in one transaction. Like F012, it does not move attached children by
    /// itself: tests pass them in `refs`, as F012 does when it carries them.
    static func registerTransformStandIn(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.itemTransform, title: "Move", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            let targets = (json["refs"]?.arrayValue ?? []).compactMap { ref -> (DocumentID, PageID, ElementID)? in
                guard case let .item(doc, page, id)? = NodeRef(ref.stringValue ?? "") else { return nil }
                return (doc, page, id)
            }
            guard let first = targets.first else { throw NibError.invalid("refs") }
            var t = Affine.identity
            if let dx = json["translate"]?[0]?.doubleValue, let dy = json["translate"]?[1]?.doubleValue {
                t = .translation(dx, dy)
            } else if let degrees = json["rotate"]?.doubleValue, let ox = json["origin"]?[0]?.doubleValue,
                      let oy = json["origin"]?[1]?.doubleValue {
                t = .rotation(degrees * Double.pi / 180, about: Point(ox, oy))
            } else {
                throw NibError.invalid("translate or rotate + origin")
            }
            try ctx.mutate { tx in
                let byID = try Dictionary(tx.items(first.0, page: first.1).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let items = try targets.map { target -> Item in
                    guard let item = byID[target.2] else { throw NibError.notFound("item \(target.2)") }
                    return item.transformed(by: t)
                }
                try tx.put(items, doc: first.0, page: first.1)
            }
            return [:]
        }
    }

    /// Sets a page's background colour (F005's page.setBackground, reduced).
    static func setPaper(_ h: Harness, _ colour: RGBA, page: PageID) async throws {
        let id = "shapestests.paper"
        h.app.commands.register(CommandDescriptor(id: id, title: "Paper", summary: "Test stand-in.", effect: .edit,
                                                  exposure: .ui)) { _, ctx in
            try ctx.mutate { tx in
                guard var record = try tx.content(Fixtures.docID).page(page) else { throw NibError.invalid("page") }
                record.background = .ofColor(colour)
                _ = try tx.put(record, doc: Fixtures.docID)
            }
            return .null
        }
        try await h.run(id)
    }

    private func ref(_ id: ElementID, page: PageID = Fixtures.page2) -> JSONValue {
        .string(NodeRef.item(Fixtures.docID, page, id).description)
    }
}
