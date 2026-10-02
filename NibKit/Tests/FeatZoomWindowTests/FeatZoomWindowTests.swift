import XCTest
import UIKit
import SwiftUI
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

    /// A canvas host whose commits finish when the test says (or at once with `outcome`), like the real canvas's
    /// `commitStroke(_:page:completion:)`.
    @MainActor
    private final class ScriptedCanvasHost: CanvasHost {
        let base: FakeCanvasHost
        /// Set: every commit finishes at once with it. nil: commits wait for `finish`.
        var outcome: Result<ElementID?, NibError>?
        private(set) var committed = 0
        private var waiting: [(Result<ElementID?, NibError>) -> Void] = []

        init(_ h: Harness) { base = FakeCanvasHost(h) }

        /// Finishes the oldest waiting commit.
        func finish(_ result: Result<ElementID?, NibError>) {
            guard !waiting.isEmpty else { return XCTFail("no commit is waiting") }
            waiting.removeFirst()(result)
        }

        var app: NibApp { base.app }
        var session: EditorSession { base.session }
        var documentID: DocumentID { base.documentID }
        var zoomScale: Double { base.zoomScale }
        var canvasView: UIView { base.canvasView }
        var overlayLayer: CALayer { base.overlayLayer }
        func viewPoint(_ p: Point, page: PageID) -> CGPoint { base.viewPoint(p, page: page) }
        func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? { base.pagePoint(v) }
        func pageFrame(_ page: PageID) -> CGRect? { base.pageFrame(page) }
        func setHidden(_ ids: Set<ElementID>, page: PageID) { base.setHidden(ids, page: page) }
        func invalidate(page: PageID, rect: Rect?) { base.invalidate(page: page, rect: rect) }
        func commitStroke(_ stroke: Stroke, page: PageID) { committed += 1 }
        func cancelWetStroke() { base.cancelWetStroke() }
        func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) { base.attachLiveView(view, item: item, page: page) }

        func commitStroke(_ stroke: Stroke, page: PageID,
                          completion: @escaping @MainActor (Result<ElementID?, NibError>) -> Void) {
            committed += 1
            if let outcome {
                completion(outcome)
            } else {
                waiting.append(completion)
            }
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
        // Keys live only in notebooks (contracts-v2 docKinds, honoured by the shell).
        XCTAssertEqual(h.app.content.keyCommands.get("zoomwindow.toggle")?.docKinds, Set([DocumentKind.notebook]))
        XCTAssertEqual(h.app.content.keyCommands.get("zoomwindow.newLine")?.docKinds, Set([DocumentKind.notebook]))
        XCTAssertNotNil(item?.isOn)
        XCTAssertNotNil(item?.isEnabled)

        // The pane is a chrome overlay: a Deep panel docked at the bottom, in notebooks.
        let pane = h.app.ui.chromeOverlays.get(FeatZoomWindowFeature.paneOverlayID)
        XCTAssertEqual(pane?.owner, FeatZoomWindowFeature.id)
        XCTAssertEqual(pane?.placement, .bottom)
        XCTAssertEqual(pane?.surface, .panel)
        XCTAssertEqual(pane?.docKinds, Set([DocumentKind.notebook]))
        XCTAssertEqual(pane?.isInteractive, true)

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

    func testDocumentHostingControllerExposesZoomShortcutsWhilePaneIsClosed() async throws {
        let h = harness()
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get("zoomwindow.keyboard"))
        let root = UIHostingController(rootView: overlay.makeView(ChromeContext(app: h.app, session: h.session, kind: .notebook))
            .allowsHitTesting(overlay.isInteractive))
        let container = UIViewController()
        container.addChild(root)
        container.view.addSubview(root.view)
        root.didMove(toParent: container)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        root.view.layoutIfNeeded()
        let laidOut = expectation(description: "Shortcut registration after hosting layout")
        DispatchQueue.main.async { laidOut.fulfill() }
        await fulfillment(of: [laidOut], timeout: 3)
        let commands = root.keyCommands ?? []
        XCTAssertTrue(commands.contains { $0.input == "z" && $0.modifierFlags == [.command, .alternate] })
        XCTAssertTrue(commands.contains { $0.input == "\r" && $0.modifierFlags == [.alternate] })
        XCTAssertFalse(state(h).isOn)
    }

    func testChromeKeyboardOpensClosedPaneAndUsesInvokingWindow() async throws {
        let h = harness()
        registerRuled(h, returnHeight: 24.7)
        let other = EditorSession()
        other.document = Fixtures.docID
        other.page = Fixtures.page1
        let otherState = ZoomStore.resolve(h.app).state(for: other)
        let keyboard = try XCTUnwrap(h.app.ui.chromeOverlays.get("zoomwindow.keyboard"))
        XCTAssertTrue(keyboard.isVisible(ChromeContext(app: h.app, session: other, kind: .notebook)))
        XCTAssertFalse(keyboard.isInteractive)
        XCTAssertFalse(otherState.isOn)
        let depth = h.undoDepth(Fixtures.docID)

        let toggle = try XCTUnwrap(ZoomKeyboardRouting.invocation(FeatZoomWindowFeature.toggleActionID,
                                                                app: h.app, session: other))
        XCTAssertTrue(toggle.session === other)
        _ = try await h.app.bus.execute(toggle)
        XCTAssertTrue(otherState.isOn)
        XCTAssertFalse(state(h).isOn, "the globally active window must not receive the shortcut")
        let before = otherState.rect
        let line = try XCTUnwrap(ZoomKeyboardRouting.invocation(FeatZoomWindowFeature.newLineActionID,
                                                              app: h.app, session: other))
        _ = try await h.app.bus.execute(line)
        XCTAssertEqual(otherState.rect.y - before.y, 24.7, accuracy: 1e-9)
        XCTAssertEqual(otherState.rect.x, otherState.effectiveMargins(pageWidth: PageSize.a4.width).left)
        _ = try await h.app.bus.execute(toggle)
        XCTAssertFalse(otherState.isOn)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testChromeKeyboardRespectsFocusReadOnlyAndRegistry() async throws {
        let h = harness()
        let toggle = FeatZoomWindowFeature.toggleActionID
        let line = FeatZoomWindowFeature.newLineActionID
        XCTAssertNil(ZoomKeyboardRouting.invocation(line, app: h.app, session: h.session))
        XCTAssertNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session, isEditingText: true))
        h.session.isEditingText = true
        XCTAssertNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session))
        h.session.isEditingText = false
        h.session.readOnly = true
        XCTAssertNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session))
        h.session.readOnly = false
        try await h.run("zoom.toggle", ["on": true])
        h.session.readOnly = true
        XCTAssertNotNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session), "closing remains available")
        XCTAssertNil(ZoomKeyboardRouting.invocation(line, app: h.app, session: h.session))
        h.session.readOnly = false
        h.session.document = Fixtures.whiteboardID
        XCTAssertNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session))
        h.session.document = nil
        XCTAssertNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session))
        h.session.document = Fixtures.docID
        h.app.content.keyCommands.unregister(id: toggle)
        XCTAssertNil(ZoomKeyboardRouting.invocation(toggle, app: h.app, session: h.session), "the chrome follows the live registry")
    }

    private final class OptionsHost: FloatingHosting {
        var views: [String: AnyView] = [:]
        func present(_ id: String, content: AnyView) { views[id] = content }
        func dismiss(_ id: String) { views[id] = nil }
        func isPresenting(_ id: String) -> Bool { views[id] != nil }
        func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { true }
        func removeAnchor(_ id: String) {}
        func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }
        func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
    }

    func testOptionsEscapeOwnsFocusThenRestoresCanvasResponder() throws {
        final class CanvasFocus: UIView {
            override var canBecomeFirstResponder: Bool { true }
        }
        let root = UIViewController()
        let canvas = CanvasFocus()
        let options = ZoomOptionsKeyView()
        root.view.addSubview(canvas)
        root.view.addSubview(options)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        XCTAssertTrue(canvas.becomeFirstResponder())
        var dismissals = 0
        options.onDismiss = { dismissals += 1 }
        options.setPresented(true)
        XCTAssertTrue(options.isFirstResponder, "Escape must reach the options before canvas Deselect")
        let escape = try XCTUnwrap(options.keyCommands?.first)
        XCTAssertEqual(escape.input, UIKeyCommand.inputEscape)
        XCTAssertEqual(escape.modifierFlags, [])
        XCTAssertTrue(escape.wantsPriorityOverSystemBehavior)
        options.dismissFromKeyboard(escape)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(canvas.isFirstResponder)
        XCTAssertTrue(options.keyCommands?.isEmpty == true)
        options.dismissFromKeyboard(escape)
        XCTAssertEqual(dismissals, 1, "a stale key cannot dismiss another presentation")
        options.setPresented(true)
        options.setPresented(false) // outside tap or choosing a preset
        XCTAssertTrue(canvas.isFirstResponder)
    }

    func testOptionsDismissalLeavesNewLineAvailableAndDoesNotEdit() async throws {
        let h = harness()
        registerRuled(h, returnHeight: 24.7)
        let floating = OptionsHost()
        h.session.floatingHost = floating
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        let depth = h.undoDepth(Fixtures.docID)
        let before = state(h).rect
        c.toggleOptions()
        XCTAssertTrue(c.optionsPresented)
        XCTAssertTrue(floating.isPresenting(ZoomWindowController.optionsID))
        // The same dismissal used by Escape and the outside-tap binding.
        c.dismissOptions()
        XCTAssertFalse(c.optionsPresented)
        XCTAssertTrue(c.isActive)
        c.newLine()
        await c.pending?.value
        XCTAssertEqual(state(h).rect.y - before.y, 24.7, accuracy: 1e-9)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
        c.toggleOptions()
        XCTAssertTrue(c.optionsPresented, "the options can reopen after Escape")
        c.close()
        XCTAssertFalse(c.optionsPresented)
        await c.pending?.value
        overlay.detach(from: host)
        XCTAssertFalse(floating.isPresenting(ZoomWindowController.optionsID))
    }

    func testOptionsPresetsDismissAndKeepReturnHeightOnItsPage() async throws {
        let h = harness()
        registerRuled(h, returnHeight: 24.7)
        let floating = OptionsHost()
        h.session.floatingHost = floating
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        c.toggleOptions()
        c.chooseOption { c.setReturnHeight(state(h).rect.height) }
        XCTAssertFalse(c.optionsPresented)
        await c.pending?.value
        XCTAssertEqual(c.returnHeight, 50)
        for delta in [2.0, -2.0] {
            c.toggleOptions()
            c.chooseOption { c.adjustReturnHeight(by: delta) }
            XCTAssertFalse(c.optionsPresented)
            await c.pending?.value
            XCTAssertEqual(c.returnHeight, delta > 0 ? 52 : 50)
        }
        try await h.run("zoom.setBox", ["page": .string(page2), "rect": [100, 200, 200, 50]])
        c.stateChanged()
        c.toggleOptions()
        c.chooseOption { c.setReturnHeight(0) }
        await c.pending?.value
        XCTAssertEqual(c.returnHeight, 24.7)
        c.newLine()
        await c.pending?.value
        XCTAssertEqual(state(h).rect.y, 224.7, accuracy: 1e-9)
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 200, 200, 50]])
        c.stateChanged()
        c.newLine()
        await c.pending?.value
        XCTAssertEqual(state(h).rect.y, 250)
        overlay.detach(from: host)
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

    func testCommitOutcomesDecideWhenWetInkLeaves() async throws {
        let h = harness()
        registerAddStrokes(h)
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 200, 200, 50], "margins": [100, 500]])
        try await h.run("zoom.toggle", ["on": true])
        let host = ScriptedCanvasHost(h)
        let overlay = ZoomBoxOverlay(host: host)
        overlay.attach(to: host)
        let c = overlay.controller
        showWet(c, [stroke(120, 150), stroke(160, 190), stroke(200, 230)])

        // Two commits still running: nothing has landed.
        XCTAssertTrue(c.strokeFinished(stroke(120, 150)))
        XCTAssertTrue(c.strokeFinished(stroke(160, 190)))
        XCTAssertEqual(host.committed, 2)
        XCTAssertEqual(c.inFlight, 2)
        XCTAssertEqual(c.landed, 0)

        // The first is saved: it leaves with the next render, which includes its dry ink.
        host.finish(.success(nil))
        XCTAssertEqual(c.inFlight, 1)
        XCTAssertEqual(c.landed, 1)
        XCTAssertEqual(c.wetCount, 3, "wet strokes leave only with the render that includes their dry ink")

        // The second fails: it must not look saved, so it leaves at once, and the user is told.
        let failed = expectation(forNotification: .nibCommandFailed, object: h.app) { note in
            (note.userInfo?["command"] as? String) == CommandIDs.inkAddStrokes
        }
        host.finish(.failure(NibError(.internalError, "the disk is full")))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(c.inFlight, 0)
        XCTAssertEqual(c.landed, 1)
        XCTAssertEqual(c.wetCount, 2)

        // A stroke written on the main canvas on the same page is not the pane's.
        try await h.run(CommandIDs.inkAddStrokes)
        XCTAssertEqual(c.landed, 1)

        // A commit refused at once (read-only) is not saved either: the pane drops it in its stroke callback.
        host.outcome = .failure(NibError(.permissionDenied, "This document is read-only."))
        XCTAssertFalse(c.strokeFinished(stroke(200, 230)))
        XCTAssertEqual(c.inFlight, 0)
        XCTAssertEqual(c.landed, 1)

        // A commit that finishes after the box moved to another page does not count against that page's strokes.
        host.outcome = nil
        XCTAssertTrue(c.strokeFinished(stroke(120, 150)))
        try await h.run("zoom.setBox", ["page": .string(page2), "rect": [100, 200, 200, 50]])
        c.stateChanged()
        XCTAssertEqual(c.wetCount, 0)
        showWet(c, [stroke(120, 150)])
        host.finish(.success(nil))
        XCTAssertEqual(c.landed, 0)
        XCTAssertEqual(c.wetCount, 1)
        overlay.detach(from: host)
    }

    func testTheFakeHostsCommitsLandAtOnce() async throws {
        let h = harness()
        let (host, overlay) = try await openWindow(h)
        let c = overlay.controller
        showWet(c, [stroke(120, 150)])
        XCTAssertTrue(c.strokeFinished(stroke(120, 150)))
        XCTAssertEqual(host.committed.count, 1)
        XCTAssertEqual(c.inFlight, 0)
        XCTAssertEqual(c.landed, 1)
        overlay.detach(from: host)
    }

    func testPaneIsShownWhileTheCanvasShowsALivePage() async throws {
        let h = harness()
        let ctx = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        func shown(_ context: ChromeContext) -> Bool {
            h.app.ui.visibleChromeOverlays(context).contains { $0.id == FeatZoomWindowFeature.paneOverlayID }
        }
        XCTAssertFalse(shown(ctx))
        try await h.run("zoom.setBox", ["page": .string(page1), "rect": [100, 200, 200, 50]])
        try await h.run("zoom.toggle", ["on": true])
        XCTAssertFalse(shown(ctx), "no canvas, no pane")

        let host = FakeCanvasHost(h)
        let overlay = ZoomBoxOverlay(host: host)
        overlay.attach(to: host)
        XCTAssertTrue(shown(ctx))
        XCTAssertFalse(shown(ChromeContext(app: h.app, session: h.session, kind: .whiteboard)))

        h.session.readOnly = true
        XCTAssertFalse(shown(ctx), "the pane writes ink, so it hides in read-only mode")
        h.session.readOnly = false
        XCTAssertTrue(shown(ctx))

        try await h.run("zoom.toggle", ["on": false])
        XCTAssertFalse(shown(ctx))
        try await h.run("zoom.toggle", ["on": true])
        XCTAssertTrue(shown(ctx))
        overlay.detach(from: host)
        XCTAssertFalse(shown(ctx), "its canvas went away")
    }

    func testToolbarItemFollowsTheWindowAndAsksTheChromeToUpdate() async throws {
        let h = harness()
        let item = try XCTUnwrap(h.app.ui.toolbar.get("zoomwindow"))
        XCTAssertEqual(item.isOn?(h.session), false)
        XCTAssertEqual(item.isEnabled?(h.session), true)

        let sessionID = h.session.id.raw
        let update = expectation(forNotification: .nibChromeNeedsUpdate, object: h.app.ui) { note in
            (note.userInfo?["session"] as? String) == sessionID
        }
        try await h.run("zoom.toggle", ["on": true])
        await fulfillment(of: [update], timeout: 1)
        XCTAssertEqual(item.isOn?(h.session), true)

        h.session.readOnly = true
        XCTAssertEqual(item.isEnabled?(h.session), true, "an open window can still be closed")
        try await h.run("zoom.toggle", ["on": false])
        XCTAssertEqual(item.isOn?(h.session), false)
        XCTAssertEqual(item.isEnabled?(h.session), false, "read-only: it cannot open")
        h.session.readOnly = false

        try await h.run("zoom.toggle", ["on": true])
        h.session.document = Fixtures.whiteboardID
        XCTAssertEqual(item.isOn?(h.session), false, "open on another document than the one the window shows")
    }

    func testPaneTakesTheChromesWidthAndSizesItsWritingAreaFromTheBox() async throws {
        let h = harness()
        let (host, overlay) = try await openWindow(h)          // box 200 × 50
        let c = overlay.controller
        // Until the chrome lays it out: the canvas's width less the chrome insets (2 × 16) and the padding (2 × 8).
        XCTAssertEqual(c.writingSize.width, 976, accuracy: 1e-9)
        XCTAssertEqual(c.writingSize.height, 244, accuracy: 1e-9)

        c.paneLaidOut(writingWidth: 784)
        XCTAssertEqual(c.writingSize.width, 784, accuracy: 1e-9)
        XCTAssertEqual(c.writingSize.height, 196, accuracy: 1e-9)
        XCTAssertEqual(c.magnification, 784.0 / 200, accuracy: 1e-9)

        // A new box shows the page at 3× in that width, and the pane is its nominal height.
        let out = try await h.run("zoom.toggle", ["on": true, "page": .string(page1), "at": [300, 400]])
        XCTAssertEqual(rect(out)[2], 784.0 / 3, accuracy: 1e-9)
        c.stateChanged()
        XCTAssertEqual(c.writingSize.height, ZoomWindowController.nominalWritingHeight, accuracy: 1e-6)
        XCTAssertEqual(c.writingSize.height + ZoomWindowController.paneChrome, 240, accuracy: 1e-6)

        // The overlay's view takes the width the chrome offers and is as tall as the row and the writing area.
        let ctx = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        let pane = try XCTUnwrap(h.app.ui.chromeOverlays.get(FeatZoomWindowFeature.paneOverlayID))
        let size = NibSnapshot.fittingSize(pane.makeView(ctx), width: 800)
        XCTAssertEqual(size.width, 800, accuracy: 0.5)
        XCTAssertEqual(size.height, c.writingSize.height + ZoomWindowController.paneChrome, accuracy: 0.5)
        XCTAssertEqual(ZoomWindowController.writingHeight(width: 800, box: Rect(x: 0, y: 0, width: 100, height: 400),
                                                          maxHeight: 300), 300, "never taller than the screen allows")
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
        h.app.settings.set(NibSettings.eraserMode, "precision")
        h.app.settings.set(NibSettings.eraserSize, 30)
        h.app.settings.set(NibSettings.eraserFilter(.pencil), false)
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
        for tool in InkTool.allCases { h.app.settings.set(NibSettings.eraserFilter(tool), false) }
        c.erase([CGPoint(x: 30, y: 15)])
        await c.pending?.value
        XCTAssertEqual(erased.params.count, 1)
        overlay.detach(from: host)
    }
}
