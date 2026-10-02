import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatLasso

@MainActor
final class FeatLassoTests: XCTestCase {
    private var pageRef: String { "page:FIXTUREDOC01/FIXTUREPG001" }

    private func harness() -> Harness { Harness(features: [FeatLassoFeature.self]) }

    private func ref(_ id: ElementID) -> String { NodeRef.item(Fixtures.docID, Fixtures.page1, id).description }

    private func refs(_ value: JSONValue) -> Set<String> {
        Set(value["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
    }

    private func polygon(_ points: [(Double, Double)], include: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["page": .string(pageRef),
                                      "polygon": .array(points.map { JSONValue.array([.number($0.0), .number($0.1)]) })]
        if let include = include { o["include"] = .array(include.map { JSONValue.string($0) }) }
        return .object(o)
    }

    private func sample(_ x: Double, _ y: Double) -> CanvasSample {
        CanvasSample(page: Fixtures.page1, location: Point(x, y))
    }

    /// Replaces fixture items before the workspace first loads the page (the Harness loads pages lazily).
    private func editFixturePage(_ h: Harness, _ edit: (inout [Item]) -> Void) {
        var items = h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1] ?? []
        edit(&items)
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page1] = items
    }

    // MARK: Conformance

    func testFeatureID() {
        XCTAssertEqual(FeatLassoFeature.id, "lasso")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLassoFeature.self], owners: [FeatLassoFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersToolToolbarAttachmentTapHandlerAndSettings() {
        let h = harness()
        XCTAssertNotNil(h.app.ui.canvasTools.get("lasso"))
        let item = h.app.ui.toolbar.get("lasso")
        XCTAssertEqual(item?.group, .lasso)
        XCTAssertEqual(item?.toolID, "lasso")
        XCTAssertEqual(item?.shortcut, KeyShortcut("v"))
        XCTAssertEqual(item?.hideable, false)
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("lasso.selection"))
        let tap = h.app.content.tapHandlers.get("selection.tapAt")
        XCTAssertEqual(tap?.order, 400)
        XCTAssertEqual(tap?.gesture, .tap)
        XCTAssertEqual(tap?.command, "selection.tapAt")
        XCTAssertNotNil(h.app.settings.descriptor("lasso.type"))
        XCTAssertNotNil(h.app.settings.descriptor("lasso.include"))
        for id in ["selection.set", "selection.clear", "selection.fromPolygon", "selection.fromRect", "selection.fromLoop",
                   "selection.selectAll", "selection.tapAt"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "lasso", id)
        }
    }

    // MARK: Polygon selection on the fixture items

    func testPolygonSelectsEveryItemItTouches() async throws {
        let h = harness()
        // A band across the top: it crosses the stroke (y ≈ 120) and the sticky note's top edge, nothing else.
        let band = try await h.run("selection.fromPolygon", polygon([(60, 110), (560, 110), (560, 130), (60, 130)]))
        XCTAssertEqual(refs(band), [ref(Fixtures.strokeID), ref(Fixtures.stickyID)])
        XCTAssertEqual(Set(h.session.selection.items), [Fixtures.strokeID, Fixtures.stickyID])
        XCTAssertEqual(h.session.selection.doc, Fixtures.docID)
        XCTAssertEqual(h.session.selection.page, Fixtures.page1)

        // The whole page touches all ten fixture items (every kind).
        let all = try await h.run("selection.fromPolygon", polygon([(0, 0), (595, 0), (595, 842), (0, 842)]))
        XCTAssertEqual(all["count"]?.intValue, 10)

        // A lasso drawn inside the image still touches it.
        let inside = try await h.run("selection.fromPolygon", polygon([(330, 490), (370, 490), (370, 530), (330, 530)]))
        XCTAssertEqual(refs(inside), [ref(Fixtures.imageID)])
        let bounds = try XCTUnwrap(h.session.selection.bounds)
        XCTAssertEqual(bounds, Rect(x: 320, y: 480, width: 64, height: 64))
    }

    func testIncludedInSelectionFilterParamAndSetting() async throws {
        let h = harness()
        let page = [(0.0, 0.0), (595.0, 0.0), (595.0, 842.0), (0.0, 842.0)]
        let filtered = try await h.run("selection.fromPolygon", polygon(page, include: ["images", "text"]))
        XCTAssertEqual(refs(filtered), [ref(Fixtures.imageID), ref(Fixtures.textID)])

        try await h.run("settings.set", ["name": "lasso.include", "value": ["tape", "comments"]])
        let fromSetting = try await h.run("selection.fromPolygon", polygon(page))
        XCTAssertEqual(refs(fromSetting), [ref(Fixtures.tapeID), ref(Fixtures.commentID)])

        do {
            try await h.run("selection.fromPolygon", polygon(page, include: ["crayons"]))
            XCTFail("an unknown category must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.include[0]")
        }
    }

    func testActiveLayerOnlyAndLockedItemsSelectable() async throws {
        let h = harness()
        editFixturePage(h) { items in
            for i in items.indices where items[i].id == Fixtures.imageID { items[i].locked = true }
            for i in items.indices where items[i].id == Fixtures.mathID { items[i].layer = 2 }
        }
        let area = polygon([(60, 470), (400, 470), (400, 560), (60, 560)])   // covers the maths item and the image
        let onBase = try await h.run("selection.fromPolygon", area)
        XCTAssertEqual(refs(onBase), [ref(Fixtures.imageID)], "the locked image is selectable; maths is on layer 2")

        h.session.activeLayer = 2
        let onTwo = try await h.run("selection.fromPolygon", area)
        XCTAssertEqual(refs(onTwo), [ref(Fixtures.mathID)])
        let all = try await h.run("selection.selectAll", ["page": .string(pageRef)])
        XCTAssertEqual(all["count"]?.intValue, 1)
    }

    func testRectSetSelectAllAndClear() async throws {
        let h = harness()
        let rect = try await h.run("selection.fromRect", ["page": .string(pageRef), "rect": [400, 570, -100, -100]])
        XCTAssertEqual(refs(rect), [ref(Fixtures.imageID)], "a rect dragged up-left is normalised")

        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.shapeID)), .string(ref(Fixtures.textID))]])
        XCTAssertEqual(h.session.selection.items, [Fixtures.shapeID, Fixtures.textID])

        let all = try await h.run("selection.selectAll", ["page": .string(pageRef)])
        XCTAssertEqual(all["count"]?.intValue, 10)

        try await h.run("selection.clear")
        XCTAssertTrue(h.session.selection.isEmpty)

        do {
            try await h.run("selection.set", ["refs": [.string(ref(Fixtures.shapeID)),
                                                       "item:FIXTUREDOC01/FIXTUREPG002/FIXTURESHP01"]])
            XCTFail("items on two pages must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        do {
            try await h.run("selection.set", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/NOSUCHITEM01"]])
            XCTFail("a missing item must be rejected")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    // MARK: Circle to Lasso

    func testFromLoopDeletesTheLoopSelectsWhatItTouchesAndUndoRestoresIt() async throws {
        let h = harness()
        let loopID: ElementID = "LOOPSTROKE01"
        // An ellipse around the maths item and the image, clear of the text box above and the tape below.
        let pts: [StrokePoint] = (0...48).map { (k: Int) -> StrokePoint in
            let a = Double(k) / 48 * 2 * Double.pi
            return StrokePoint(x: Float(228 + 170 * cos(a)), y: Float(512 + 50 * sin(a)))
        }
        editFixturePage(h) { items in
            items.append(Item(id: loopID, kind: .stroke, z: "zz", stroke: Stroke(style: .defaultPen, points: pts)))
        }
        h.session.tool = "pen"
        let before = try h.snapshot()

        let r = try await h.run("selection.fromLoop", ["page": .string(pageRef), "stroke": .string(ref(loopID))])
        XCTAssertEqual(refs(r), [ref(Fixtures.mathID), ref(Fixtures.imageID)])
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).contains { $0.id == loopID })
        XCTAssertEqual(h.session.tool, "lasso")
        XCTAssertEqual(h.session.temporaryReturnTool, "pen", "Circle to Lasso is a temporary lasso")
        let outline = try XCTUnwrap(h.session.selection.outline, "the loop is the selection's outline")
        XCTAssertGreaterThanOrEqual(outline.count, 3)
        XCTAssertEqual(Rect.bounding(outline)?.minX ?? 0, 58, accuracy: 1)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before, "undo restores the loop stroke")

        try await h.run("selection.clear")
        XCTAssertEqual(h.session.tool, "pen", "Circle to Lasso hands back the pen when the selection ends")
    }

    // MARK: Quick selection (tap)

    func testTapSelectsTopObjectSwitchesToLassoAndTapElsewhereReturns() async throws {
        let h = harness()
        h.session.tool = "pen"
        let onImage = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [352, 512], "gesture": "tap"])
        XCTAssertEqual(onImage["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.selection.items, [Fixtures.imageID])
        XCTAssertEqual(h.session.tool, "lasso")
        XCTAssertEqual(h.session.temporaryReturnTool, "pen")
        XCTAssertNil(h.session.selection.outline, "a tap selection has no lasso outline")

        let elsewhere = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [300, 800]])
        XCTAssertEqual(elsewhere["handled"]?.boolValue, true)
        XCTAssertTrue(h.session.selection.isEmpty)
        XCTAssertEqual(h.session.tool, "pen")
        XCTAssertNil(h.session.temporaryReturnTool)

        let empty = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [300, 800]])
        XCTAssertEqual(empty["handled"]?.boolValue, false, "nothing to select or clear: the tool gets the tap")

        let onInk = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [100, 121]])
        XCTAssertEqual(onInk["handled"]?.boolValue, false, "quick selection skips ink")

        try await h.run("settings.set", ["name": "editing.objectTapSelection", "value": false])
        let off = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [352, 512]])
        XCTAssertEqual(off["handled"]?.boolValue, false)
        XCTAssertTrue(h.session.selection.isEmpty)
    }

    func testTapWithTheLassoSelectsInkAndOtherToolsLeaveEditingToTheTapChain() async throws {
        let h = harness()
        h.session.tool = "lasso"
        let onInk = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [100, 121]])
        XCTAssertEqual(onInk["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.selection.items, [Fixtures.strokeID])
        XCTAssertNil(h.session.temporaryReturnTool, "the lasso was already the tool")

        try await h.run("selection.clear")
        XCTAssertEqual(h.session.tool, "lasso", "clearing never switches away from a lasso the person picked")

        // No tool-id special cases: a tool that edits a kind on tap claims it earlier in the chain (text.tapAt is
        // offered text boxes before selection.tapAt), so a tap that reaches order 400 selects.
        h.session.tool = "text"
        let onText = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [200, 420]])
        XCTAssertEqual(onText["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.selection.items, [Fixtures.textID])
    }

    func testSelectAllDefaultsToTheWindowsPageForTheUser() async throws {
        let h = harness()
        let all = try await h.run("selection.selectAll")
        XCTAssertEqual(all["count"]?.intValue, 10)
        XCTAssertEqual(h.session.selection.page, Fixtures.page1)
        do {
            try await h.run("selection.selectAll", [:], as: .ai("test"))
            XCTFail("the AI must name the page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testDrawerHitAreasDecideLassoAndTapHits() async throws {
        let h = harness()
        // A collapsed sticky note answers only at its 24 pt icon in the top-left corner of its frame (400, 120, 140, 140).
        h.app.content.drawers.register(ItemDrawerEntry(key: ItemKind.sticky.rawValue, owner: "test",
                                                       drawer: HitAreaDrawer(Rect(x: 400, y: 120, width: 24, height: 24))))
        let lowerHalf = polygon([(450, 200), (560, 200), (560, 280), (450, 280)], include: ["sticky"])
        let missed = try await h.run("selection.fromPolygon", lowerHalf)
        XCTAssertEqual(missed["count"]?.intValue, 0, "the frame is not the hit area")
        let icon = polygon([(380, 100), (430, 100), (430, 150), (380, 150)], include: ["sticky"])
        let hit = try await h.run("selection.fromPolygon", icon)
        XCTAssertEqual(refs(hit), [ref(Fixtures.stickyID)])

        try await h.run("selection.clear")
        h.session.tool = "pen"
        let offIcon = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [500, 240]])
        XCTAssertEqual(offIcon["handled"]?.boolValue, false)
        let onIcon = try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [410, 130]])
        XCTAssertEqual(onIcon["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.selection.items, [Fixtures.stickyID])
    }

    // MARK: Housekeeping (start)

    func testHousekeepingFollowsMovesClearsDeletionsAndTracksTheToolbarGlyph() async throws {
        let h = harness()
        h.app.commands.register(TestNudge.self)
        h.app.commands.register(TestDelete.self)
        LassoHousekeeping.start(h.app)

        try await h.run("selection.fromPolygon", polygon([(330, 490), (370, 490), (370, 530), (330, 530)]))
        try await h.run("test.nudge", ["id": "FIXTUREIMG01", "dx": 10])
        await LassoHousekeeping.pending?.value
        XCTAssertEqual(h.session.selection.bounds, Rect(x: 330, y: 480, width: 64, height: 64), "bounds follow a move")
        XCTAssertEqual(h.session.selection.outline, [Point(340, 490), Point(380, 490), Point(380, 530), Point(340, 530)],
                       "the outline follows a move that did not carry it along")
        // A mover that carries the selection itself (F012 transforms bounds and outline) is left alone.
        try await h.run("test.nudge", ["id": "FIXTUREIMG01", "dx": 10, "carry": true])
        await LassoHousekeeping.pending?.value
        XCTAssertEqual(h.session.selection.bounds, Rect(x: 340, y: 480, width: 64, height: 64))
        XCTAssertEqual(h.session.selection.outline, [Point(350, 490), Point(390, 490), Point(390, 530), Point(350, 530)])
        try await h.run("test.delete", ["id": "FIXTUREIMG01"])
        await LassoHousekeeping.pending?.value
        XCTAssertTrue(h.session.selection.isEmpty, "a deleted item leaves the selection")

        h.session.tool = "pen"
        try await h.run("selection.tapAt", ["page": .string(pageRef), "point": [122, 725]])   // the custom item
        XCTAssertEqual(h.session.tool, "lasso")
        XCTAssertEqual(h.session.temporaryReturnTool, "pen")
        try await h.run("tool.select", ["tool": "eraser"])
        XCTAssertNil(h.session.temporaryReturnTool, "picking another tool forgets the return tool")
        try await h.run("selection.clear")
        XCTAssertEqual(h.session.tool, "eraser")

        let item = try XCTUnwrap(h.app.ui.toolbar.get("lasso"))
        XCTAssertEqual(item.icon, "lasso")
        XCTAssertEqual(item.resolvedIcon(for: h.session), "lasso")
        let update = expectation(forNotification: .nibChromeNeedsUpdate, object: h.app.ui)
        try await h.run("settings.set", ["name": "lasso.type", "value": "rectangle"])
        await fulfillment(of: [update], timeout: 2)
        XCTAssertEqual(item.resolvedIcon(for: h.session), "rectangle.dashed", "the glyph is live state")
    }

    // MARK: The tool

    func testClosedFingerLassoSelectsEnclosedStrokeAtCanvasZoom() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        host.zoomScale = 1.2767101196075796
        h.session.tool = "lasso"
        let tool = LassoTool()
        tool.activate(host)
        let before = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let loop = [Point(60, 90), Point(300, 90), Point(300, 155), Point(60, 155), Point(60, 90)]
        let samples = loop.enumerated().map { index, point in
            CanvasSample(page: Fixtures.page1, location: point, timestamp: Double(index) * 0.175,
                         isPencil: false, touchID: 1)
        }

        tool.touchesBegan(samples[0], host: host)
        tool.touchesMoved(Array(samples[1...3]), host: host)
        tool.touchesEnded(samples[4], host: host)
        let command = try XCTUnwrap(tool.pending, "A closed finger loop must issue a selection command")
        await command.value

        XCTAssertEqual(h.session.selection.items, [Fixtures.strokeID])
        XCTAssertNotNil(h.session.selection.outline)
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1), before,
                       "Lasso selection must not alter the ink or create an undoable edit")
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true)
    }

    func testFreehandAndRectangleGesturesSelect() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let tool = LassoTool()
        tool.activate(host)

        tool.touchesBegan(sample(90, 190), host: host)
        tool.touchesMoved([sample(270, 190), sample(270, 300), sample(90, 300)], host: host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count, 1, "the marquee is drawn while dragging")
        tool.touchesEnded(sample(90, 195), host: host)
        await tool.pending?.value
        XCTAssertEqual(Set(h.session.selection.items), [Fixtures.shapeID, Fixtures.connectorID])
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true, "the marquee is removed on lift")

        try await h.run("settings.set", ["name": "lasso.type", "value": "rectangle"])
        tool.touchesBegan(sample(300, 470), host: host)
        tool.touchesMoved([sample(350, 520)], host: host)
        tool.touchesEnded(sample(400, 570), host: host)
        await tool.pending?.value
        XCTAssertEqual(h.session.selection.items, [Fixtures.imageID])

        tool.tap(sample(300, 800), host: host)
        await tool.pending?.value
        XCTAssertTrue(h.session.selection.isEmpty, "a tap on empty paper deselects")

        // A lasso that crosses the page gap keeps drawing in its start page's coordinates (CanvasHost.convert).
        host.zoomScale = 2
        let below = tool.pagePoint(CanvasSample(page: Fixtures.page2, location: Point(100, 10)), on: Fixtures.page1,
                                   host: host)
        XCTAssertEqual(below.x, 100, accuracy: 0.001)
        XCTAssertEqual(below.y, host.pageSize.height + host.gap + 10, accuracy: 0.001)
    }

    // MARK: The overlay

    func testLassoSettingsPopoverReopensAndReleasesCanvasTouchesWhenClosed() async throws {
        let h = harness()
        let settings = try XCTUnwrap(FeatLassoFeature.toolbarItem(h.app).settings?(h.session))
        func root(presented: Bool) -> some View {
            NibDropletContainer {
                NibBudPopover(id: "test.lasso.settings", source: "test.lasso",
                              isPresented: .constant(presented), title: "Lasso") { settings }
            }
        }
        let host = UIHostingController(rootView: root(presented: false))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for presented in [false, true, false, true, false] {
            host.rootView = root(presented: presented)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                host.view.layoutIfNeeded()
                let panels = scrollViews(host.view)
                if !panels.isEmpty && panels.allSatisfy({ $0.isUserInteractionEnabled == presented
                    && $0.accessibilityElementsHidden == !presented }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let panels = scrollViews(host.view)
            XCTAssertFalse(panels.isEmpty, "Settings stays mounted while its popover closes")
            for panel in panels {
                XCTAssertEqual(panel.isUserInteractionEnabled, presented)
                XCTAssertEqual(panel.accessibilityElementsHidden, !presented)
                if !presented {
                    XCTAssertNil(panel.hitTest(CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), with: nil),
                                 "Closed Lasso settings must release taps and loops to the canvas")
                }
            }
        }
    }

    func testSelectionOverlayPublishesIncomingBoundsAndClearWithoutQueuedCanvasRefresh() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let overlay = SelectionOverlay()
        overlay.attach(to: host)
        defer { overlay.detach(from: host) }

        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.imageID))]])
        XCTAssertEqual(overlay.view.content?.box, CGRect(x: 320, y: 480, width: 64, height: 64))
        // Change synchronously, as a command does. Reading session.selection from the publisher
        // instead of its incoming value would draw the previous image here.
        let next = Rect(x: 120, y: 240, width: 150, height: 90)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1,
                                        items: [Fixtures.shapeID], bounds: next)
        XCTAssertEqual(overlay.view.content?.box, next.cg)
        XCTAssertEqual(overlay.view.accessibilityValue, "1 item")

        h.session.selection = Selection()
        XCTAssertNil(overlay.view.content)
        XCTAssertFalse(overlay.view.isAccessibilityElement)
        XCTAssertTrue(overlay.view.accessibilityElementsHidden)
        XCTAssertEqual(overlay.view.accessibilityFrame, .zero)
    }

    func testSelectionAccessibilityBoundsFollowAncestorLayoutBeforeCanvasRefresh() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.addSubview(host.canvasView)
        let overlay = SelectionOverlay()
        overlay.attach(to: host)
        defer { overlay.detach(from: host) }
        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.imageID))]])
        overlay.canvasDidChange(host)
        let before = overlay.view.accessibilityFrame

        // A parent layout/scroll happens before the canvas's next notification. The content
        // is already at its new screen location; the VoiceOver target must follow immediately.
        host.canvasView.frame.origin = CGPoint(x: 80, y: 114)
        host.canvasView.bounds.origin = CGPoint(x: -35, y: 60)
        let box = try XCTUnwrap(overlay.view.content?.box)
        let expected = UIAccessibility.convertToScreenCoordinates(box, in: overlay.view)
        XCTAssertNotEqual(before, expected)
        XCTAssertEqual(overlay.view.accessibilityFrame, expected)
        XCTAssertNil(overlay.view.hitTest(CGPoint(x: box.midX, y: box.midY), with: nil),
                     "The accessible outline must never intercept a canvas tap or lasso")

        overlay.detach(from: host)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1,
                                        items: [Fixtures.imageID], bounds: Rect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertNil(overlay.view.content, "A detached overlay stops observing the session")
    }

    func testNarrowLowerStrokeLoopAndEmptyTapPreserveBothLines() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        host.zoomScale = 1.2767101196075796
        h.session.zoom = host.zoomScale
        h.session.tool = "lasso"
        let lowerID: ElementID = "LOWERSTROK01"
        let upperID: ElementID = "UPPERSTROK01"
        // Reproduce the UI test's viewport geometry on the fitted, inset page.
        func point(_ x: Double, _ y: Double) -> Point {
            Point((x * 1376 - 352) / host.zoomScale, (y * 1032 - 124.2) / host.zoomScale)
        }
        editFixturePage(h) { items in
            items = [(upperID, 0.56), (lowerID, 0.73)].map { id, y in
                let pts = [point(0.42, y), point(0.56, y)]
                return Item(id: id, kind: .stroke, z: y == 0.56 ? "a" : "b",
                            stroke: Stroke(style: .defaultPen, points: pts.map {
                                StrokePoint(x: Float($0.x), y: Float($0.y))
                            }))
            }
        }
        let before = try h.snapshot()
        let tool = LassoTool()
        let loop = [point(0.38, 0.69), point(0.63, 0.69), point(0.63, 0.77),
                    point(0.38, 0.77), point(0.38, 0.69)]
        for pass in 0..<2 {
            let samples = loop.enumerated().map { index, p in
                CanvasSample(page: Fixtures.page1, location: p, timestamp: Double(index) * 0.175,
                             isPencil: false, touchID: pass + 1)
            }
            tool.touchesBegan(samples[0], host: host)
            tool.touchesMoved(Array(samples[1...3]), host: host)
            tool.touchesEnded(samples[4], host: host)
            await tool.pending?.value
            XCTAssertEqual(h.session.selection.items, [lowerID])
            let bounds = try XCTUnwrap(h.session.selection.bounds)
            XCTAssertTrue(bounds.contains(point(0.49, 0.73)))
            XCTAssertFalse(bounds.contains(point(0.49, 0.56)))

            let empty = point(0.68, 0.82)
            if pass == 0 {
                // Finger taps run the tap chain; Pencil taps go directly to the active tool.
                let out = try await h.run("selection.tapAt", ["page": .string(pageRef),
                    "point": .array([.number(empty.x), .number(empty.y)]), "gesture": "tap"])
                XCTAssertEqual(out["handled"]?.boolValue, true)
            } else {
                tool.tap(CanvasSample(page: Fixtures.page1, location: empty), host: host)
                await tool.pending?.value
            }
            XCTAssertTrue(h.session.selection.isEmpty)
            XCTAssertEqual(h.session.tool, "lasso")
            XCTAssertEqual(try h.snapshot(), before, "Selection and clearing must preserve source ink and geometry")
        }
    }

    func testOverlayDrawsTheOutlineAndBoundsAndFollowsTheSelection() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let overlay = SelectionOverlay()
        overlay.attach(to: host)
        XCTAssertTrue(overlay.view.superview === host.canvasView)
        XCTAssertNil(overlay.view.content)

        try await h.run("selection.fromPolygon", polygon([(330, 490), (370, 490), (370, 530), (330, 530)]))
        overlay.canvasDidChange(host)
        let drawn = try XCTUnwrap(overlay.view.content)
        XCTAssertEqual(drawn.box, CGRect(x: 320, y: 480, width: 64, height: 64))
        XCTAssertTrue(drawn.drawsBox)
        XCTAssertTrue(overlay.view.isAccessibilityElement)

        host.zoomScale = 2
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.view.content?.box, CGRect(x: 640, y: 960, width: 128, height: 128))

        // The canvas calls canvasDidChange on every selection change and commit.
        try await h.run("selection.set", ["refs": [.string(ref(Fixtures.shapeID))]])
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.view.content?.drawsBox, false, "a by-ref selection draws a dashed box, not a lasso")
        let shape = try XCTUnwrap(h.session.selection.bounds)
        XCTAssertEqual(overlay.view.content?.outline.boundingBoxOfPath,
                       CGRect(x: shape.x * 2, y: shape.y * 2, width: shape.width * 2, height: shape.height * 2)
                           .insetBy(dx: -SelectionStyle.boxPadding, dy: -SelectionStyle.boxPadding))

        // Another feature's outline (F012 rotating the selection) is drawn as given, not re-derived.
        let diamond = [Point(180, 245), Point(260, 200), Point(340, 245), Point(260, 290)]
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID],
                                        bounds: Rect(x: 180, y: 200, width: 160, height: 90), outline: diamond)
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.view.content?.drawsBox, true)
        XCTAssertEqual(overlay.view.content?.outline.boundingBoxOfPath, CGRect(x: 360, y: 400, width: 320, height: 180))

        // A selection written without bounds still gets them (from the items).
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.imageID])
        overlay.canvasDidChange(host)
        XCTAssertEqual(overlay.view.content?.box, CGRect(x: 640, y: 960, width: 128, height: 128))

        try await h.run("selection.clear")
        overlay.canvasDidChange(host)
        XCTAssertNil(overlay.view.content)
        XCTAssertFalse(overlay.view.isAccessibilityElement)
        overlay.detach(from: host)
        XCTAssertNil(overlay.view.superview)
    }

    // MARK: Geometry

    func testLineTouchesAgreesWithGeoPolylineTouchesPolygon() {
        var rng = SeededGenerator(seed: 0x5EED)
        for round in 0..<3000 {
            // Mostly small lassos; every 100th has 300 vertices (more edges than the 256 bands of the edge index).
            let n = round % 100 == 99 ? 300 : Int.random(in: 3...12, using: &rng)
            let cx = Double.random(in: 100...300, using: &rng), cy = Double.random(in: 100...300, using: &rng)
            let poly = (0..<n).map { (k: Int) -> Point in
                let a = Double(k) / Double(n) * 2 * Double.pi
                let r = Double.random(in: 20...120, using: &rng)
                return Point(cx + r * cos(a), cy + r * sin(a))
            }
            let line = (0..<Int.random(in: 1...8, using: &rng)).map { _ in
                Point(Double.random(in: 0...400, using: &rng), Double.random(in: 0...400, using: &rng))
            }
            let prepared = LassoPolygon(poly)
            XCTAssertNotNil(prepared)
            guard let prepared = prepared else { return }
            let expected = Geo.polylineTouchesPolygon(line, poly)
            XCTAssertEqual(LassoGeometry.lineTouches(line, prepared), expected, "line \(line) polygon \(poly)")
            for _ in 0..<8 {
                let q = Point(Double.random(in: 0...400, using: &rng), Double.random(in: 0...400, using: &rng))
                XCTAssertEqual(prepared.contains(q.x, q.y), Geo.polygonContains(poly, q), "point \(q) polygon \(poly)")
            }
            // The stroke fast path answers the same for the same points.
            let points = line.map { StrokePoint(x: Float($0.x), y: Float($0.y)) }
            XCTAssertEqual(LassoGeometry.strokeTouches(points, prepared),
                           Geo.polylineTouchesPolygon(points.map { $0.location }, poly), "stroke \(line) polygon \(poly)")
        }
    }

    func testTapHitTestHonoursRotation() {
        let frame = Frame(x: 100, y: 100, w: 200, h: 20, rotation: Double.pi / 2)   // stands upright about (200, 110)
        XCTAssertTrue(LassoGeometry.frameContains(frame, Point(200, 190), margin: 0))
        XCTAssertFalse(LassoGeometry.frameContains(frame, Point(290, 110), margin: 0))
    }

    func testHitTestOverFiveThousandStrokesStaysInBudget() {
        let items: [Item] = (0..<5000).map { (i: Int) -> Item in
            let x = Double(i % 50) * 11 + 20, y = Double(i / 50) * 8 + 20
            let pts = (0..<20).map { (k: Int) -> StrokePoint in
                StrokePoint(x: Float(x + Double(k) * 0.4), y: Float(y + Double(k % 3)), width: 1.2, height: 1.2)
            }
            return Item.makeStroke(Stroke(style: .defaultPen, points: pts, t0: 0))
        }
        let lasso = (0..<72).map { (k: Int) -> Point in
            let a = Double(k) / 72 * 2 * Double.pi
            return Point(300 + 200 * cos(a), 420 + 200 * sin(a))
        }
        let everything = Set(LassoCategory.allCases)
        // Best of several runs: a shared CI simulator stalls now and then, the fastest run is the code's cost.
        var best = Double.infinity
        var count = 0
        for _ in 0..<8 {
            let start = Date()
            count = SelectionEngine.select(items, polygon: lasso, include: everything, layer: 0).count
            best = min(best, Date().timeIntervalSince(start))
        }
        XCTAssertGreaterThan(count, 500)
        XCTAssertLessThan(count, 5000)
        XCTAssertLessThan(best, 0.016 * 4, "ARCHITECTURE §20: lasso hit test over 5k strokes < 16 ms (×4 in CI)")
    }
}

/// Test-only stand-ins for F012's move and F013's delete on the fixture page.
private struct TestNudge: NibCommand {
    struct Params: Codable {
        var id: String
        var dx: Double
        /// Move the window's selection (bounds and outline) along, as F012 does.
        var carry: Bool?
    }

    static let descriptor = CommandDescriptor(id: "test.nudge", title: "Nudge",
                                              summary: "Move a fixture item right (test stand-in).", effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in
            let item = try tx.item(Fixtures.docID, page: Fixtures.page1, id: NibID(p.id))
            try tx.put(item.transformed(by: .translation(p.dx, 0)), doc: Fixtures.docID, page: Fixtures.page1)
        }
        if p.carry == true, let session = ctx.activeSession {
            var next = session.selection
            next.bounds = next.bounds.map { Rect(x: $0.x + p.dx, y: $0.y, width: $0.width, height: $0.height) }
            next.outline = next.outline?.map { Point($0.x + p.dx, $0.y) }
            session.selection = next
        }
        return NoResult()
    }
}

private struct TestDelete: NibCommand {
    struct Params: Codable {
        var id: String
    }

    static let descriptor = CommandDescriptor(id: "test.delete", title: "Delete",
                                              summary: "Delete a fixture item (test stand-in).", effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in try tx.delete(item: NibID(p.id), doc: Fixtures.docID, page: Fixtures.page1) }
        return NoResult()
    }
}

/// A drawer whose items take hits only in `area` (a collapsed sticky note's icon).
private final class HitAreaDrawer: ItemDrawer {
    let area: Rect

    init(_ area: Rect) { self.area = area }

    func draw(_ item: Item, in context: DrawContext) {}

    func hitBounds(_ item: Item) -> Rect? { area }
}

/// Deterministic xorshift generator, so the geometry comparison is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
