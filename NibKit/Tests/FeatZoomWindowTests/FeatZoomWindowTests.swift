import XCTest
import UIKit
import PencilKit
import NibContracts
import NibTesting
@testable import FeatZoomWindow

@MainActor
final class FeatZoomWindowTests: XCTestCase {
    private let page1 = "page:FIXTUREDOC01/FIXTUREPG001"
    private let page2 = "page:FIXTUREDOC01/FIXTUREPG002"

    private func harness() -> Harness { Harness(features: [FeatZoomWindowFeature.self]) }

    private func state(_ h: Harness) -> ZoomState { ZoomStore.resolve(h.app).state(for: h.session) }

    private func rect(_ v: JSONValue) -> [Double] { v["rect"]?.arrayValue?.compactMap { $0.doubleValue } ?? [] }

    /// A pen stroke across the box's line at y 220…230 (page points).
    private func stroke(_ x0: Float, _ x1: Float) -> Stroke {
        Stroke(style: .defaultPen, points: [StrokePoint(x: x0, y: 220), StrokePoint(x: x1, y: 230)])
    }

    /// An open Zoom Window with its box on page 1 (100, 200, 200 × 50; margins 100…500) and its overlay attached.
    private func openWindow(_ h: Harness) async throws -> (FakeCanvasHost, ZoomBoxOverlay) {
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 200, 200, 50], "margins": [100, 500]])
        try await h.run("zoom.toggle", ["on": true])
        let host = FakeCanvasHost(h)
        let overlay = ZoomBoxOverlay(host: host)
        overlay.attach(to: host)
        return (host, overlay)
    }

    /// Puts strokes on the pane's canvas as wet ink, as writing leaves them there (with the canvas's delegate off, so
    /// the test decides what is committed).
    private func showWet(_ c: ZoomWindowController, _ strokes: [Stroke]) {
        let canvas = c.writingView().canvas
        let delegate = canvas.delegate
        canvas.delegate = nil
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + strokes.map { PKBridge.pkStroke($0) })
        canvas.delegate = delegate
    }

    /// A stand-in `ink.addStrokes` that adds one stroke to page 1 (FakeCanvasHost.commitStroke only records).
    private func registerAddStrokes(_ h: Harness) {
        let descriptor = CommandDescriptor(id: CommandIDs.inkAddStrokes, title: "Add Strokes",
                                           summary: "Test stand-in: adds one stroke to the fixture's first page.", effect: .edit)
        h.app.commands.register(descriptor) { _, ctx in
            try ctx.mutate { (tx: DocTransaction) -> Void in
                let item = Item(kind: .stroke, stroke: Stroke(style: .defaultPen,
                                                               points: [StrokePoint(x: 120, y: 220), StrokePoint(x: 150, y: 230)]))
                _ = try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return [:]
        }
    }

    private func registerRuled(_ h: Harness, returnHeight: Double) {
        h.app.content.templates.register(TemplateDefinition(
            id: "builtin.ruled", title: "Ruled", category: "Writing", owner: "test",
            zoomReturnHeight: returnHeight) { _, _, _ in TemplateRender(paper: .white) })
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatZoomWindowFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersToolbarMenuAttachmentKeysAndCommands() {
        let h = harness()
        for id in ["zoom.toggle", "zoom.setBox", "zoom.newLine", "zoom.setReturnHeight"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatZoomWindowFeature.id, id)
        }
        XCTAssertEqual(h.app.commands.descriptor("zoom.setReturnHeight")?.effect, .edit)
        XCTAssertEqual(h.app.commands.descriptor("zoom.setBox")?.effect, .session)

        let item = h.app.ui.toolbar.get("zoomwindow")
        XCTAssertEqual(item?.group, .accessories)
        XCTAssertEqual(item?.command, "zoom.toggle")
        XCTAssertEqual(item?.docKinds, Set([DocumentKind.notebook]))
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("zoomwindow.box"))
        XCTAssertEqual(h.app.content.keyCommands.get("zoomwindow.newLine")?.command, "zoom.newLine")

        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, point: Point(120, 300))
        let menu = h.app.ui.menuItems(.pageLongPress, ctx).first { $0.id == "zoomwindow.here" }
        XCTAssertEqual(menu?.command, "zoom.toggle")
        let params = menu?.params(ctx)
        XCTAssertEqual(params?["on"], JSONValue.bool(true))
        XCTAssertEqual(params?["page"]?.stringValue, page1)
        XCTAssertEqual(params?["at"], JSONValue.array([120, 300]))
        let board = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        XCTAssertTrue(h.app.ui.menuItems(.pageLongPress, board).allSatisfy { $0.id != "zoomwindow.here" })
    }

    func testToggleOpensADefaultBoxAtTheLeftMarginAndTogglesOff() async throws {
        let h = harness()
        let on = try await h.run("zoom.toggle")
        XCTAssertEqual(on["on"], JSONValue.bool(true))
        XCTAssertEqual(on["page"]?.stringValue, page1)
        let r = rect(on)
        XCTAssertEqual(r.count, 4)
        XCTAssertEqual(r[0], ZoomGeometry.defaultLeftMargin, accuracy: 1e-9)
        // 3× in the pane: box width = pane writing width / 3 (600 before any layout).
        XCTAssertEqual(r[2], 200, accuracy: 1e-9)
        XCTAssertTrue(state(h).isOn)

        let off = try await h.run("zoom.toggle")
        XCTAssertEqual(off["on"], JSONValue.bool(false))
        XCTAssertFalse(state(h).isOn)
        // Reopening keeps the box where it was.
        let again = try await h.run("zoom.toggle", ["on": true])
        XCTAssertEqual(rect(again), r)
    }

    func testToggleAtAPointCentresTheBoxAndRejectsForeignPages() async throws {
        let h = harness()
        let out = try await h.run("zoom.toggle", ["on": true, "page": .string(page1), "at": [300, 400]])
        let r = rect(out)
        XCTAssertEqual(r[0] + r[2] / 2, 300, accuracy: 1e-9)
        XCTAssertEqual(r[1] + r[3] / 2, 400, accuracy: 1e-9)

        do {
            try await h.run("zoom.toggle", ["on": true, "page": "page:FIXTUREDOC04/FIXTUREBRD01"], as: .ai("chat"))
            XCTFail("a page of another document must be refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.page")
        }
    }

    func testSetBoxClampsIntoThePageAndStoresMargins() async throws {
        let h = harness()
        let out = try await h.run("zoom.setBox", ["page": .string(page1), "rect": [560, -20, 100, 40], "margins": [60, 540]])
        XCTAssertEqual(rect(out), [PageSize.a4.width - 100, 0, 100, 40])
        XCTAssertEqual(out["margins"], JSONValue.array([60, 540]))
        XCTAssertEqual(state(h).margins, ZoomMargins(left: 60, right: 540))
        XCTAssertFalse(state(h).isOn, "moving the box does not open the window")

        do {
            try await h.run("zoom.setBox", ["page": .string(page1), "rect": [10, 10, 100, 40], "margins": [500, 100]],
                            as: .bridge("test"))
            XCTFail("margins with left > right must be refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.margins")
        }
    }

    func testNewLineUsesTheTemplateThenThePageOverride() async throws {
        let h = harness()
        registerRuled(h, returnHeight: 24.7)
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [300, 100, 120, 40], "margins": [72, 540]])
        var out = try await h.run("zoom.newLine")
        XCTAssertEqual(rect(out)[0], 72, accuracy: 1e-9)
        XCTAssertEqual(rect(out)[1], 124.7, accuracy: 1e-9)
        XCTAssertEqual(out["returnHeight"]?.doubleValue ?? 0, 24.7, accuracy: 1e-9)

        let depth = h.undoDepth(Fixtures.docID)
        let set = try await h.run("zoom.setReturnHeight", ["page": .string(page1), "height": 40])
        XCTAssertEqual(set["returnHeight"]?.doubleValue, 40)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.zoomReturnHeight, 40)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        out = try await h.run("zoom.newLine")
        XCTAssertEqual(rect(out)[1], 164.7, accuracy: 1e-9)

        // Undo restores the template's default; 0 clears the override too.
        h.app.bus.undo(Fixtures.docID)
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.zoomReturnHeight)
        try await h.run("zoom.setReturnHeight", ["page": .string(page1), "height": 30])
        let cleared = try await h.run("zoom.setReturnHeight", ["page": .string(page1), "height": 0])
        XCTAssertNil(cleared["returnHeight"])
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.zoomReturnHeight)
    }

    func testNewLineWithoutABoxAndReadOnlyAreRefused() async throws {
        let h = harness()
        do {
            try await h.run("zoom.newLine")
            XCTFail("New Line needs a zoom box")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        h.session.readOnly = true
        do {
            try await h.run("zoom.toggle", ["on": true])
            XCTFail("the Zoom Window writes ink, so it is off in read-only mode")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        h.session.document = Fixtures.whiteboardID
        h.session.readOnly = false
        do {
            try await h.run("zoom.toggle", ["on": true])
            XCTFail("whiteboards have no Zoom Window")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
    }

    func testDraggingTheBoxAndItsHandlesRunsSetBox() async throws {
        let h = harness()
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 200, 200, 50]])
        try await h.run("zoom.toggle", ["on": true])
        let host = FakeCanvasHost(h)
        let overlay = ZoomBoxOverlay(host: host)
        overlay.attach(to: host)
        overlay.canvasDidChange(host)
        let s = state(h)

        func drag(from a: Point, to b: Point) async {
            XCTAssertTrue(overlay.hitTest(host.viewPoint(a, page: Fixtures.page1), host: host))
            overlay.touchesBegan(CanvasSample(page: Fixtures.page1, location: a), host: host)
            overlay.touchesMoved([CanvasSample(page: Fixtures.page1, location: b)], host: host)
            overlay.touchesEnded(CanvasSample(page: Fixtures.page1, location: b), host: host)
            await overlay.controller.pending?.value
            overlay.canvasDidChange(host)
        }

        XCTAssertFalse(overlay.hitTest(host.viewPoint(Point(500, 700), page: Fixtures.page1), host: host),
                       "ink elsewhere on the page is untouched")
        await drag(from: Point(150, 225), to: Point(190, 255))
        XCTAssertEqual(s.rect, Rect(x: 140, y: 230, width: 200, height: 50))

        // Corner handle: twice as wide, same aspect ratio.
        await drag(from: Point(340, 280), to: Point(540, 280))
        XCTAssertEqual(s.rect.width, 400, accuracy: 1e-9)
        XCTAssertEqual(s.rect.height, 100, accuracy: 1e-9)

        // Bottom handle: height only.
        await drag(from: Point(340, 330), to: Point(340, 310))
        XCTAssertEqual(s.rect.width, 400, accuracy: 1e-9)
        XCTAssertEqual(s.rect.height, 80, accuracy: 1e-9)

        // The left margin tab sits above the box on the margin line.
        let left = s.effectiveMargins(pageWidth: PageSize.a4.width).left
        await drag(from: Point(left, s.rect.minY - Double(ZoomOverlayView.tabRise)), to: Point(left + 10, s.rect.minY))
        XCTAssertEqual(s.margins?.left ?? 0, left + 10, accuracy: 1e-9)
        overlay.detach(from: host)
    }

    func testPaneStrokesCommitThroughTheHostAndAutoAdvance() async throws {
        let h = harness()
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 200, 200, 50], "margins": [100, 500]])
        try await h.run("zoom.toggle", ["on": true])
        let host = FakeCanvasHost(h)
        let overlay = ZoomBoxOverlay(host: host)
        overlay.attach(to: host)
        let c = overlay.controller

        c.strokeFinished(stroke(120, 230))               // passes the middle (200): armed
        c.strokeFinished(stroke(260, 280))               // in the advance zone (250…300)
        await c.pending?.value
        XCTAssertEqual(host.committed.count, 2)
        XCTAssertEqual(host.committed.first?.page, Fixtures.page1)
        XCTAssertEqual(state(h).rect, Rect(x: 200, y: 200, width: 200, height: 50))

        // Auto-advance off: strokes still commit, the box stays.
        try await h.run("settings.set", ["name": .string(NibSettings.zoomAutoAdvance.name), "value": false])
        c.strokeFinished(stroke(210, 330))
        c.strokeFinished(stroke(360, 390))
        await c.pending?.value
        XCTAssertEqual(host.committed.count, 4)
        XCTAssertEqual(state(h).rect.x, 200)
        overlay.detach(from: host)
    }

    func testMovingTheBoxKeepsWetStrokesAndChangingThePageDropsThem() async throws {
        let h = harness()
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        showWet(c, [stroke(260, 290)])
        XCTAssertEqual(c.wetCount, 1)

        // Auto-advance, New Line, a drag and the zoom slider change only the rect: the stroke that was just written
        // stays on screen until the render that includes its dry ink.
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [200, 200, 200, 50]])
        c.stateChanged()
        XCTAssertEqual(c.wetCount, 1)
        try await h.run("zoom.newLine")
        c.stateChanged()
        XCTAssertEqual(c.wetCount, 1)
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 250, 120, 30]])
        c.stateChanged()
        XCTAssertEqual(c.wetCount, 1)

        // Another page: the wet ink belongs to the old one.
        try await h.run("zoom.setBox", ["page": .string(page2), "rect": [100, 200, 200, 50]])
        c.stateChanged()
        XCTAssertEqual(c.wetCount, 0)
        overlay.detach(from: host)
    }

    func testOnlyThePanesOwnCommitsCountAsLanded() async throws {
        let h = harness()
        registerAddStrokes(h)
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        showWet(c, [stroke(120, 150), stroke(160, 190)])
        XCTAssertTrue(c.strokeFinished(stroke(120, 150)))
        XCTAssertEqual(c.inFlight, 1)

        // The pane's commit lands (as the real host commits it: ink.addStrokes as the user).
        try await h.run(CommandIDs.inkAddStrokes)
        XCTAssertEqual(c.landed, 1)
        XCTAssertEqual(c.inFlight, 0)

        // A stroke written on the main canvas on the same page is not the pane's: the second wet stroke stays wet.
        try await h.run(CommandIDs.inkAddStrokes)
        XCTAssertEqual(c.landed, 1)
        XCTAssertEqual(c.wetCount, 2, "wet strokes leave only with the render that includes their dry ink")
        overlay.detach(from: host)
    }

    func testDeletingTheBoxPageHidesTheWindowAndRefusesItsStrokes() async throws {
        let h = harness()
        let descriptor = CommandDescriptor(id: "test.deletePage", title: "Delete Page",
                                           summary: "Test stand-in: deletes the fixture's first page.", effect: .edit)
        h.app.commands.register(descriptor) { _, ctx in
            try ctx.mutate { (tx: DocTransaction) -> Void in
                guard var page = try tx.content(Fixtures.docID).page(Fixtures.page1) else { return }
                page.deleted = true
                _ = try tx.put(page, doc: Fixtures.docID)
            }
            return [:]
        }
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        overlay.canvasDidChange(host)
        XCTAssertFalse(overlay.view.isHidden)

        try await h.run("test.deletePage")
        overlay.canvasDidChange(host)
        XCTAssertTrue(overlay.view.isHidden, "no box on a page that is gone")
        await c.pending?.value
        XCTAssertFalse(state(h).isOn, "the window closes itself")

        // A stroke that was still being written when the page went is refused, and the user is told.
        let failed = expectation(forNotification: .nibCommandFailed, object: h.app) { note in
            (note.userInfo?["command"] as? String) == CommandIDs.inkAddStrokes
        }
        XCTAssertFalse(c.strokeFinished(stroke(120, 150)))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(host.committed.isEmpty)
        overlay.detach(from: host)
    }

    func testPaneEraserUsesTheEraserToolsSettings() async throws {
        let h = harness()
        final class Recorder { var params: [JSONValue] = [] }
        let erased = Recorder()
        let descriptor = CommandDescriptor(id: CommandIDs.inkErase, title: "Erase",
                                           summary: "Test stand-in: records what the pane erases.", effect: .edit)
        h.app.commands.register(descriptor) { params, _ in
            erased.params.append(params)
            return [:]
        }
        h.app.settings.setJSON("eraser.mode", .string("precision"))
        h.app.settings.setJSON("eraser.size", .number(30))
        h.app.settings.setJSON("eraser.filter.pencil", .bool(false))
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        let m = c.magnification

        c.erase([CGPoint(x: 30, y: 15), CGPoint(x: 60, y: 30)])
        await c.pending?.value
        XCTAssertEqual(erased.params.count, 1, "one ink.erase per gesture")
        let p = try XCTUnwrap(erased.params.first)
        XCTAssertEqual(p["page"]?.stringValue, page1)
        XCTAssertEqual(p["mode"]?.stringValue, "precision")
        XCTAssertEqual(p["radius"]?.doubleValue ?? 0, 15 / m, accuracy: 1e-9)
        XCTAssertEqual(p["filter"], JSONValue.array([.string("pen"), .string("highlighter"), .string("tape")]))
        let path = p["path"]?.arrayValue?.map { $0.arrayValue?.compactMap { $0.doubleValue } ?? [] } ?? []
        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path.first?.first ?? 0, 100 + 30 / m, accuracy: 1e-9)
        XCTAssertEqual(path.first?.last ?? 0, 200 + 15 / m, accuracy: 1e-9)
        XCTAssertEqual(path.last?.first ?? 0, 100 + 60 / m, accuracy: 1e-9)
        XCTAssertEqual(path.last?.last ?? 0, 200 + 30 / m, accuracy: 1e-9)

        // An Erase Filter that lets nothing be erased sends nothing.
        for tool in InkTool.allCases { h.app.settings.setJSON("eraser.filter." + tool.rawValue, .bool(false)) }
        c.erase([CGPoint(x: 30, y: 15)])
        await c.pending?.value
        XCTAssertEqual(erased.params.count, 1)
        overlay.detach(from: host)
    }
}
