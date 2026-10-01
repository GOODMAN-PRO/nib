import XCTest
import UIKit
import PencilKit
import NibContracts
import NibTesting
@testable import FeatCanvas

@MainActor
final class CanvasInputTests: XCTestCase {
    private final class Tool: CanvasTool {
        let id = "test.input"
        var inputMode: CanvasInputMode = .samples
        var taps = 0
        var longPresses = 0
        var beganIDs: [Int] = []
        var moved: [CanvasSample] = []
        var hovers = 0
        var cancelOnFinish = false
        var endedIDs: [Int] = []
        var finished = 0
        var held = 0
        var handlesHold = false
        func touchesEnded(_ sample: CanvasSample, host: CanvasHost) { endedIDs.append(sample.touchID) }
        func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool { held += 1; return handlesHold }
        var style = InkStyle.defaultPen
        func inkStyle(_ host: CanvasHost) -> InkStyle? { inputMode == .pencilKit ? style : nil }
        func touchesBegan(_ sample: CanvasSample, host: CanvasHost) { beganIDs.append(sample.touchID) }
        func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) { moved += samples }
        func tap(_ sample: CanvasSample, host: CanvasHost) { taps += 1 }
        func longPress(_ sample: CanvasSample, host: CanvasHost) { longPresses += 1 }
        func hover(_ sample: CanvasSample?, host: CanvasHost) { hovers += 1 }
        func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost) {
            finished += 1
            if cancelOnFinish { host.cancelWetStroke(); host.cancelWetStroke() }
            else { host.commitStroke(stroke, page: page) }
        }
    }
    private final class Attachment: CanvasAttachment {
        var claim = true
        var consume = true
        var askedPencil: [Bool] = []
        var beganIDs: [Int] = []
        var gestures: [CanvasGesture] = []
        var hovers = 0
        func attach(to host: CanvasHost) {}
        func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool { askedPencil.append(isPencil); return claim }
        func touchesBegan(_ sample: CanvasSample, host: CanvasHost) { beganIDs.append(sample.touchID) }
        func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool { gestures.append(gesture); return consume }
        func hover(_ sample: CanvasSample?, host: CanvasHost) { hovers += 1 }
    }
    private func sample(pencil: Bool = false, id: Int = 9) -> CanvasSample {
        CanvasSample(page: Fixtures.page1, location: Point(140, 220), timestamp: 1, isPencil: pencil, touchID: id)
    }
    private func router(_ host: CanvasHost, tool: Tool, attachments: [Attachment] = [], item: Item? = nil) -> GestureRouter {
        GestureRouter(host: host, attachments: { attachments }, activeTool: { tool },
                      isReadOnly: { host.session.readOnly }, topmostItem: { _ in item })
    }
    private func registerTap(_ harness: Harness, id: String, gesture: CanvasGesture = .tap, order: Int,
                             kinds: Set<ItemKind>? = nil, keys: Set<String>? = nil, readOnly: Bool = false,
                             handler: @escaping CommandHandler) {
        harness.app.commands.register(CommandDescriptor(id: id, title: "Test Tap", summary: "Records a routed test gesture.",
                                                        params: .obj(["page": .ref, "point": .arr(.num()), "ref": .ref,
                                                                      "gesture": .str()], required: ["page", "point", "gesture"]),
                                                        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [140, 220], "gesture": "tap"]],
                                                        effect: .session), handler: handler)
        harness.app.content.tapHandlers.register(TapHandlerDescriptor(id: id, owner: "test", gesture: gesture, command: id,
                                                                      order: order, itemKinds: kinds, drawKeys: keys,
                                                                      worksInReadOnly: readOnly))
    }

    func testAttachmentClaimWinsBeforeHandlersAndToolAndKeepsTouchID() async {
        let harness = Harness()
        let host = FakeCanvasHost(harness)
        let tool = Tool(), first = Attachment(), second = Attachment()
        var commandCalls = 0
        registerTap(harness, id: "test.tap", order: 0) { _, _ in commandCalls += 1; return ["handled": true] }
        let router = router(host, tool: tool, attachments: [first, second])
        let sample = sample(pencil: true, id: 42)
        let route = router.route(at: sample.location.cg, isPencil: true, canDraw: true)
        router.begin(sample, route: route)
        router.move([sample])
        _ = router.end(sample)
        let handled = await router.gesture(.tap, sample: self.sample(), route: route)
        XCTAssertTrue(handled)
        XCTAssertEqual(first.askedPencil, [true])
        XCTAssertTrue(second.askedPencil.isEmpty)
        XCTAssertEqual(first.beganIDs, [42])
        XCTAssertEqual(commandCalls, 0)
        XCTAssertEqual(tool.taps, 0)
        XCTAssertTrue(tool.beganIDs.isEmpty)
    }

    func testFirstHandledCommandWinsInRegistryOrderAndGetsTopmostRef() async throws {
        let harness = Harness()
        let host = FakeCanvasHost(harness), tool = Tool()
        let item = try harness.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        var calls: [String] = []
        var received: JSONValue?
        registerTap(harness, id: "test.later", order: 300) { _, _ in calls.append("later"); return ["handled": true] }
        registerTap(harness, id: "test.decline", order: 100) { _, _ in calls.append("decline"); return ["handled": false] }
        registerTap(harness, id: "test.handle", order: 200) { p, _ in calls.append("handle"); received = p; return ["handled": true] }
        let handled = await router(host, tool: tool, item: item).gesture(.tap, sample: sample())
        XCTAssertTrue(handled)
        XCTAssertEqual(calls, ["decline", "handle"])
        XCTAssertEqual(received?["ref"]?.stringValue, NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.shapeID).description)
        XCTAssertEqual(received?["page"]?.stringValue, NodeRef.page(Fixtures.docID, Fixtures.page1).description)
        XCTAssertEqual(received?["point"], [140, 220])
        XCTAssertEqual(tool.taps, 0)
    }

    func testKindDrawKeyGestureAndReadOnlyFiltersAndToolFallthrough() async throws {
        let harness = Harness()
        let host = FakeCanvasHost(harness), tool = Tool()
        let item = try harness.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.customID)
        var calls: [String] = []
        registerTap(harness, id: "test.kind", order: 0, kinds: [.stroke]) { _, _ in calls.append("kind"); return ["handled": true] }
        registerTap(harness, id: "test.key", order: 1, keys: ["custom.other.box"]) { _, _ in calls.append("key"); return ["handled": true] }
        registerTap(harness, id: "test.write", order: 2) { _, _ in calls.append("write"); return ["handled": false] }
        registerTap(harness, id: "test.read", order: 3, kinds: [.custom], keys: [item.drawKey], readOnly: true) { _, _ in
            calls.append("read"); return ["handled": false]
        }
        let router = router(host, tool: tool, item: item)
        host.session.readOnly = true
        _ = await router.gesture(.tap, sample: sample())
        XCTAssertEqual(calls, ["read"])
        XCTAssertEqual(tool.taps, 0)
        host.session.readOnly = false
        calls.removeAll()
        _ = await router.gesture(.tap, sample: sample())
        XCTAssertEqual(calls, ["write", "read"])
        XCTAssertEqual(tool.taps, 1)
        calls.removeAll()
        _ = await router.gesture(.longPress, sample: sample())
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(tool.longPresses, 1)
    }

    func testAttachmentCanPassGestureToHandlersAndHoverReachesBoth() async {
        let harness = Harness(), tool = Tool(), attachment = Attachment()
        let host = FakeCanvasHost(harness)
        attachment.consume = false
        var calls = 0
        registerTap(harness, id: "test.double", gesture: .doubleTap, order: 100) { _, _ in calls += 1; return ["handled": true] }
        let pencilHandler = PencilHandler()
        harness.app.ui.pencilHandler = pencilHandler
        let router = router(host, tool: tool, attachments: [attachment])
        let handled = await router.gesture(.doubleTap, sample: sample())
        XCTAssertTrue(handled)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(attachment.gestures, [.doubleTap])
        router.hover(sample(pencil: true))
        router.hover(nil)
        XCTAssertEqual(attachment.hovers, 2)
        XCTAssertEqual(tool.hovers, 2)
        XCTAssertEqual(pencilHandler.hovers.count, 2)
        XCTAssertNil(pencilHandler.hovers.last!)
        router.hover(self.sample(pencil: false), isPencil: false)
        router.hover(nil, isPencil: false)
        XCTAssertEqual(pencilHandler.hovers.count, 2, "Pointer hover must not masquerade as Pencil hardware")
        XCTAssertEqual(attachment.hovers, 4)
        XCTAssertEqual(tool.hovers, 4)
    }

    func testPencilSkipsFingerTapHandlersAndRawSamplesKeepPredictionAndIdentity() async {
        let harness = Harness(), tool = Tool()
        let host = FakeCanvasHost(harness)
        var calls = 0
        registerTap(harness, id: "test.finger", order: 0) { _, _ in calls += 1; return ["handled": true] }
        let router = router(host, tool: tool)
        var sample = sample(pencil: true, id: 123)
        let route = router.route(at: sample.location.cg, isPencil: true, canDraw: true)
        router.begin(sample, route: route)
        sample.isPredicted = true
        router.move([sample])
        _ = router.end(sample)
        _ = await router.gesture(.tap, sample: sample, route: route)
        XCTAssertEqual(tool.beganIDs, [123])
        XCTAssertEqual(tool.moved.first?.touchID, 123)
        XCTAssertEqual(tool.moved.first?.isPredicted, true)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(tool.taps, 1)
    }

    private final class FencedHost: CanvasHost {
        let base: FakeCanvasHost
        var app: NibApp { base.app }
        var session: EditorSession { base.session }
        var documentID: DocumentID { base.documentID }
        var zoomScale: Double { base.zoomScale }
        var canvasView: UIView { base.canvasView }
        var overlayLayer: CALayer { base.overlayLayer }
        var fence: (@MainActor () -> Void)?
        var cancellation: (() -> Void)?
        init(_ harness: Harness) { base = FakeCanvasHost(harness) }
        func viewPoint(_ p: Point, page: PageID) -> CGPoint { base.viewPoint(p, page: page) }
        func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? { base.pagePoint(v) }
        func pageFrame(_ page: PageID) -> CGRect? { base.pageFrame(page) }
        func setHidden(_ ids: Set<ElementID>, page: PageID) { base.setHidden(ids, page: page) }
        func invalidate(page: PageID, rect: Rect?) { base.invalidate(page: page, rect: rect) }
        func commitStroke(_ stroke: Stroke, page: PageID) { base.commitStroke(stroke, page: page) }
        func cancelWetStroke() { cancellation?() }
        func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) { base.attachLiveView(view, item: item, page: page) }
        func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void) { fence = body }
    }

    func testWetStrokeRetiresOnlyAfterDryFenceAndConvertsRollAndWorldOrigin() {
        let host = FencedHost(Harness()), tool = Tool(), handoff = WetStrokeHandoff()
        let stroke = Stroke(style: .defaultPen, points: [StrokePoint(x: 10, y: 20), StrokePoint(x: 30, y: 40, t: 0.1)], t0: 10)
        var retires = 0
        handoff.deliver(PKBridge.pkStroke(stroke), style: stroke.style, page: Fixtures.page1, origin: Point(-100, 200),
                        rolls: [(0, 0.7)], tool: tool, host: host) { retires += 1 }
        XCTAssertEqual(retires, 0)
        XCTAssertNotNil(host.fence)
        let committed = host.base.committed.first?.stroke
        XCTAssertEqual(committed?.points.first?.x ?? 0, -90, accuracy: 0.001)
        XCTAssertEqual(committed?.points.first?.y ?? 0, 220, accuracy: 0.001)
        XCTAssertEqual(committed?.points.first?.roll ?? 0, 0.7, accuracy: 0.001)
        host.fence?()
        host.fence?()
        XCTAssertEqual(retires, 1)
    }

    func testCancellationFromStrokeFinishedIsIdempotentAndDiscardsOnlyThatWetStroke() {
        let host = FencedHost(Harness()), tool = Tool(), handoff = WetStrokeHandoff()
        tool.cancelOnFinish = true
        host.cancellation = { handoff.cancel() }
        var retires = 0
        handoff.deliver(PKBridge.pkStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2)], t0: 1)),
                        style: .defaultPen, page: Fixtures.page1, tool: tool, host: host) { retires += 1 }
        XCTAssertTrue(handoff.cancelled)
        XCTAssertTrue(handoff.retired)
        XCTAssertEqual(retires, 1)
        XCTAssertTrue(host.base.committed.isEmpty)
        XCTAssertNil(host.fence)
    }

    private final class Processor: StrokeProcessor {
        var calls = 0
        var drop = false
        func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool {
            calls += 1
            stroke.style.width = 4
            return !drop
        }
    }

    func testProductionCommitUsesInkCommandProcessorsAndUndoRedo() async throws {
        let harness = Harness(features: [FeatCanvasInputFeature.self])
        let processor = Processor()
        harness.app.content.strokeProcessors.register(StrokeProcessorEntry(id: "test.processor", order: 0, owner: "test", processor: processor))
        var commandCalls = 0
        harness.app.commands.register(CommandDescriptor(id: CommandIDs.inkAddStrokes, title: "Add Ink", summary: "Adds test ink strokes.",
                                                        params: .obj(["page": .ref, "strokes": .arr(.anything())], required: ["page", "strokes"]),
                                                        examples: [], effect: .edit)) { p, ctx in
            commandCalls += 1
            guard case let .page(doc, page)? = NodeRef(p["page"]?.stringValue ?? "") else { throw NibError.notFound("page") }
            let strokes = try (p["strokes"] ?? []).decode([Stroke].self)
            var refs: [JSONValue] = []
            try ctx.mutate("Add Ink") { tx in
                for stroke in strokes {
                    let item = try tx.put(Item(id: NibID.make(), kind: .stroke, stroke: stroke), doc: doc, page: page)
                    refs.append(.string(NodeRef.item(doc, page, item.id).description))
                }
            }
            return ["refs": .array(refs)]
        }
        let host = CanvasHostImpl(app: harness.app, session: harness.session, documentID: Fixtures.docID,
                                  scrollView: DocumentScrollView(frame: .zero), fixedOverlay: PassThroughView())
        let before = try harness.snapshot()
        let finished = expectation(description: "ink.addStrokes completed")
        let stroke = Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)], t0: 1)
        var created: ElementID?
        host.commitStroke(stroke, page: Fixtures.page2) { outcome in
            if case .success(let id) = outcome { created = id }
            else { XCTFail("Commit failed: \(outcome)") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(commandCalls, 1)
        XCTAssertEqual(processor.calls, 1)
        let id = try XCTUnwrap(created)
        XCTAssertEqual(try harness.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id).stroke?.style.width, 4)
        let after = try harness.snapshot()
        _ = try await harness.run("edit.undo", ["doc": .string(Fixtures.docID.raw)])
        XCTAssertEqual(try harness.snapshot(), before)
        _ = try await harness.run("edit.redo", ["doc": .string(Fixtures.docID.raw)])
        XCTAssertEqual(try harness.snapshot(), after)
        processor.drop = true
        host.commitStroke(stroke, page: Fixtures.page2) { outcome in
            if case .success(let id) = outcome { XCTAssertNil(id) } else { XCTFail("Dropped stroke failed") }
        }
        XCTAssertEqual(commandCalls, 1)
        harness.session.readOnly = true
        host.commitStroke(stroke, page: Fixtures.page2) { outcome in
            if case .failure(let error) = outcome { XCTAssertEqual(error.code, .permissionDenied) } else { XCTFail("Read-only commit succeeded") }
        }
        XCTAssertEqual(processor.calls, 2)
    }

    private final class PencilHandler: PencilEventHandler {
        var taps = 0
        var hovers: [CanvasSample?] = []
        func pencilDoubleTap(session: EditorSession, host: CanvasHost) { taps += 1 }
        func pencilSqueeze(began: Bool, location: CGPoint?, session: EditorSession, host: CanvasHost) {}
        func pencilHover(_ sample: CanvasSample?, session: EditorSession, host: CanvasHost) { hovers.append(sample) }
    }

    func testInstalledCanvasesTrackZoomStylusPolicyHighlighterAndReadOnlyOnPhoneAndPad() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let harness = Harness(features: [FeatCanvasFeature.self, FeatCanvasInputFeature.self])
            let tool = Tool(), pencilHandler = PencilHandler()
            tool.inputMode = .pencilKit
            harness.app.ui.canvasTools.register(CanvasToolDescriptor(id: tool.id, title: "Test Ink", owner: "test", make: { tool }))
            harness.app.ui.pencilHandler = pencilHandler
            harness.session.tool = tool.id
            let editor = CanvasViewController(documentID: Fixtures.docID, session: harness.session, app: harness.app)
            editor.loadViewIfNeeded()
            editor.view.frame = CGRect(origin: .zero, size: size)
            editor.view.setNeedsLayout()
            editor.view.layoutIfNeeded()
            if !editor.didInitialLayout { editor.viewDidLayoutSubviews() }
            defer { editor.closeCanvas() }
            let input = try XCTUnwrap(editor.host.inputController as? WetInkController)
            func inkViews(_ view: UIView) -> [PKCanvasView] {
                view.subviews.flatMap { child in (child as? PKCanvasView).map { [$0] } ?? inkViews(child) }
            }
            let canvases = inkViews(editor.host.wetInkContainer)
            XCTAssertEqual(canvases.count, 2)
            XCTAssertEqual(canvases.filter(\.isUserInteractionEnabled).count, 1)
            let normal = try XCTUnwrap(canvases.first { $0.layer.compositingFilter == nil })
            let highlighter = try XCTUnwrap(canvases.first { $0.layer.compositingFilter != nil })
            XCTAssertEqual(highlighter.layer.compositingFilter as? String, "multiplyBlendMode")
            XCTAssertFalse(normal.isOpaque)
            XCTAssertTrue(normal.accessibilityElementsHidden)
            XCTAssertEqual(normal.zoomScale, CGFloat(editor.host.zoomScale), accuracy: 0.0001)
            XCTAssertEqual(normal.drawingPolicy, .pencilOnly)
            XCTAssertFalse(editor.host.doubleTapZoomRecognizer.isEnabled)
            XCTAssertEqual(editor.host.canvasView.interactions.filter { $0 is UIPencilInteraction }.count, 1)
            input.pencilInteractionDidTap(UIPencilInteraction())
            XCTAssertEqual(pencilHandler.taps, 1)
            let changed = expectation(description: "Live stylus policy changes")
            _ = try await harness.run(CommandIDs.settingsSet, ["name": .string(NibSettings.stylusMode.name), "value": "anyInput"])
            Task { @MainActor in
                for _ in 0..<100 {
                    if normal.drawingPolicy == .anyInput { changed.fulfill(); return }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            await fulfillment(of: [changed], timeout: 3)
            XCTAssertEqual(normal.drawingPolicy, .anyInput)
            XCTAssertEqual(editor.scrollView.panGestureRecognizer.minimumNumberOfTouches, 2)
            tool.style = .defaultHighlighter
            input.canvasActiveToolDidChange(editor.host)
            XCTAssertFalse(normal.isUserInteractionEnabled)
            XCTAssertTrue(highlighter.isUserInteractionEnabled)
            harness.session.readOnly = true
            input.canvasReadOnlyDidChange(editor.host)
            XCTAssertTrue(canvases.allSatisfy { !$0.isUserInteractionEnabled })
            editor.closeCanvas()
            XCTAssertNil(editor.host.inputController)
            XCTAssertTrue(inkViews(editor.host.wetInkContainer).isEmpty)
            XCTAssertFalse(editor.host.canvasView.interactions.contains { $0 is UIPencilInteraction })
            XCTAssertTrue(editor.host.doubleTapZoomRecognizer.isEnabled)
        }
    }

    private func installed(_ tool: Tool) throws -> (Harness, CanvasViewController, WetInkController) {
        let harness = Harness(features: [FeatCanvasFeature.self, FeatCanvasInputFeature.self])
        harness.app.ui.canvasTools.register(CanvasToolDescriptor(id: tool.id, title: "Test Ink", owner: "test", make: { tool }))
        harness.session.tool = tool.id
        let editor = CanvasViewController(documentID: Fixtures.docID, session: harness.session, app: harness.app)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        if !editor.didInitialLayout { editor.viewDidLayoutSubviews() }
        let input = try XCTUnwrap(editor.host.inputController as? WetInkController)
        return (harness, editor, input)
    }
    private func event(_ host: CanvasHostImpl, id: Int, pencil: Bool = true, point: Point = Point(140, 220),
                       timestamp: Double = ProcessInfo.processInfo.systemUptime) -> CanvasSample {
        CanvasSample(page: host.session.page ?? Fixtures.page1, location: point, timestamp: timestamp, isPencil: pencil, touchID: id)
    }
    private func canvases(_ view: UIView) -> [PKCanvasView] {
        view.subviews.flatMap { ($0 as? PKCanvasView).map { [$0] } ?? canvases($0) }
    }
    private func waitForGesture() async throws { try await Task.sleep(nanoseconds: 380_000_000) }

    func testLedgerMatchesNativeStrokeIdentityAcrossMissingAndOverlappingCaptures() {
        var ledger = WetInkLedger<String, String>()
        let missing = UUID(), first = UUID(), second = UUID()
        let date = Date(timeIntervalSince1970: 100)
        ledger.register(id: missing, startedAt: date, payload: "old red")
        ledger.end(missing)
        ledger.register(id: first, startedAt: date.addingTimeInterval(1), payload: "new blue", nativeStarted: true)
        ledger.register(id: second, startedAt: date.addingTimeInterval(1.1), payload: "green", nativeStarted: true)
        // Native callbacks can deliver out of order; the original queue index is irrelevant.
        ledger.append(identity: date.addingTimeInterval(1.1), ink: "second")
        ledger.end(second)
        ledger.append(identity: date.addingTimeInterval(1), ink: "first")
        ledger.end(first)
        ledger.nativeEnd()
        let deliveries = ledger.takeDeliveries()
        XCTAssertEqual(deliveries.map { $0.capture?.payload }, ["green", "new blue"])
        XCTAssertTrue(ledger.takeDeliveries().isEmpty)
        ledger.discardUnproduced()
        XCTAssertFalse(ledger.retire(), "Must wait for the render fence")
        ledger.markReady(first)
        ledger.markReady(second)
        XCTAssertTrue(ledger.retire())
        XCTAssertTrue(ledger.isEmpty, "An inactive surface is now reusable/prunable")
    }

    func testLedgerLiveCancellationEndedCancellationAndPendingDot() {
        var ledger = WetInkLedger<Int, Int>()
        let live = UUID(), ended = UUID(), dot = UUID(), date = Date()
        ledger.register(id: live, startedAt: date, payload: 1, nativeStarted: true)
        XCTAssertTrue(ledger.cancel(live))
        XCTAssertFalse(ledger.cancel(live))
        ledger.register(id: ended, startedAt: date.addingTimeInterval(1), payload: 2, nativeStarted: true)
        ledger.end(ended)
        XCTAssertTrue(ledger.cancel(ended))
        ledger.append(identity: date.addingTimeInterval(1), ink: 2)
        XCTAssertTrue(ledger.takeDeliveries().isEmpty)
        XCTAssertTrue(ledger.retire())
        ledger.register(id: dot, startedAt: date.addingTimeInterval(2), payload: 3, nativeStarted: true)
        ledger.end(dot, pendingGesture: true)
        ledger.append(identity: date.addingTimeInterval(2), ink: 3)
        XCTAssertTrue(ledger.takeDeliveries().isEmpty)
        ledger.resolveGesture(dot)
        ledger.nativeEnd()
        XCTAssertEqual(ledger.takeDeliveries().count, 1)
        XCTAssertTrue(ledger.cancel(dot))
        XCTAssertFalse(ledger.cancel(dot))
        XCTAssertTrue(ledger.retire())
        XCTAssertTrue(ledger.isEmpty)
    }

    func testLedgerCancellationOfAlreadyAppendedLiveInkAndFinalPressureUpdate() {
        var ledger = WetInkLedger<Int, Int>()
        let live = UUID(), date = Date()
        ledger.register(id: live, startedAt: date, payload: 1, nativeStarted: true)
        ledger.append(identity: date, ink: 1)
        XCTAssertTrue(ledger.cancel(live))
        XCTAssertTrue(ledger.retire(), "Appended live ink must become ended when cancelled")
        let finished = UUID(), next = date.addingTimeInterval(1)
        ledger.register(id: finished, startedAt: next, payload: 2, nativeStarted: true)
        ledger.append(identity: next, ink: 1)
        ledger.end(finished)
        XCTAssertTrue(ledger.takeDeliveries().isEmpty, "Touch lift alone is not native completion")
        ledger.append(identity: next, ink: 2)
        ledger.nativeEnd()
        XCTAssertEqual(ledger.takeDeliveries().first?.ink, 2, "Use the final pressure notification")
    }

    func testControllerOffPaperThenNewStyleCommitsThroughProcessAndRetires() async throws {
        let tool = Tool(); tool.inputMode = .pencilKit
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        var received: [Stroke] = []
        let committed = expectation(description: "process → strokeFinished → ink.addStrokes")
        harness.app.commands.register(CommandDescriptor(id: CommandIDs.inkAddStrokes, title: "Add Ink", summary: "Records committed ink.",
            params: .obj(["page": .ref, "strokes": .arr(.anything())], required: ["page", "strokes"]), examples: [], effect: .edit)) { params, _ in
                received += try (params["strokes"] ?? []).decode([Stroke].self)
                committed.fulfill()
                return ["refs": []]
            }
        let offPage = event(editor.host, id: 100, point: Point(-60, -60))
        let offContact = NSObject()
        XCTAssertNil(input.acceptContact(ObjectIdentifier(offContact), sample: offPage))
        input.begin(offPage, screenPoint: offPage.location, route: .tool(tool), contact: ObjectIdentifier(offContact))
        XCTAssertTrue(harness.session.inking.isInking)
        input.end(offPage)
        XCTAssertFalse(harness.session.inking.isInking)
        XCTAssertTrue(received.isEmpty)
        tool.style.width = 11
        input.canvasActiveToolDidChange(editor.host)
        let real = event(editor.host, id: 101)
        let contact = NSObject()
        let canvas = try XCTUnwrap(input.acceptContact(ObjectIdentifier(contact), sample: real))
        let pk = PKBridge.pkStroke(Stroke(style: .defaultPen,
            points: [StrokePoint(x: 140, y: 220), StrokePoint(x: 150, y: 230, t: 0.1)], t0: Date().timeIntervalSince1970))
        input.begin(real, screenPoint: real.location, route: .tool(tool), contact: ObjectIdentifier(contact), startedAt: pk.path.creationDate)
        input.canvasViewDidBeginUsingTool(canvas)
        input.end(real)
        // A final drawing notification may arrive after touch lift and native end.
        canvas.drawing = PKDrawing(strokes: [pk])
        input.canvasViewDrawingDidChange(canvas)
        input.canvasViewDidEndUsingTool(canvas)
        await fulfillment(of: [committed], timeout: 5)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.style.width, 11)
        XCTAssertFalse(harness.session.inking.isInking)
        for _ in 0..<100 {
            if canvas.drawing.strokes.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        // Navigation reuses the idle pair rather than rebuilding PKCanvasViews.
        let old = Set(canvases(editor.host.wetInkContainer).map(ObjectIdentifier.init))
        harness.session.page = Fixtures.page2
        input.canvasActivePageDidChange(editor.host)
        XCTAssertEqual(Set(canvases(editor.host.wetInkContainer).map(ObjectIdentifier.init)), old)
    }

    func testControllerAcceptedButPreventedContactCannotShiftNextStroke() async throws {
        let tool = Tool(); tool.inputMode = .pencilKit
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        let noStroke = event(editor.host, id: 102)
        let contact = NSObject()
        let canvas = try XCTUnwrap(input.acceptContact(ObjectIdentifier(contact), sample: noStroke))
        input.begin(noStroke, screenPoint: noStroke.location, route: .tool(tool), contact: ObjectIdentifier(contact))
        // No native tool-begin: another recognizer prevented PencilKit.
        input.end(noStroke)
        let nextContact = NSObject(), next = event(editor.host, id: 103)
        XCTAssertTrue(input.acceptContact(ObjectIdentifier(nextContact), sample: next) === canvas)
        XCTAssertFalse(harness.session.inking.isInking)
        // A native begin/end that makes no drawing must also leave no retained capture.
        input.begin(next, screenPoint: next.location, route: .tool(tool), contact: ObjectIdentifier(nextContact))
        input.canvasViewDidBeginUsingTool(canvas)
        input.end(next)
        input.canvasViewDidEndUsingTool(canvas)
        await Task.yield()
        await Task.yield()
        harness.session.page = Fixtures.page2
        input.canvasActivePageDidChange(editor.host)
        XCTAssertEqual(canvases(editor.host.wetInkContainer).count, 2)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
    }

    func testControllerStaggeredSecondFingerCancelsInkAndBalancesInking() throws {
        let tool = Tool(); tool.inputMode = .pencilKit
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        let first = event(editor.host, id: 110, pencil: false, timestamp: 10)
        var second = event(editor.host, id: 111, pencil: false, timestamp: 10.05)
        input.begin(first, screenPoint: first.location, route: .tool(tool))
        XCTAssertTrue(harness.session.inking.isInking)
        input.begin(second, screenPoint: second.location, route: .tool(tool))
        XCTAssertFalse(harness.session.inking.isInking, "Chrome returns as soon as drawing becomes navigation")
        second.location.x += 20
        input.move([second], screenPoint: second.location, id: second.touchID)
        input.end(first)
        input.end(second)
        XCTAssertFalse(harness.session.inking.isInking)
        XCTAssertEqual(tool.taps, 0)
    }

    func testControllerRejectedPalmBeforePencilDoesNotBlockOrCancelWriting() throws {
        let tool = Tool(); tool.inputMode = .pencilKit
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        let palm = event(editor.host, id: 120, pencil: false), pencil = event(editor.host, id: 121)
        input.begin(palm, screenPoint: palm.location, route: .rejected)
        input.begin(pencil, screenPoint: pencil.location, route: .tool(tool))
        XCTAssertTrue(harness.session.inking.isInking)
        input.end(palm)
        XCTAssertTrue(harness.session.inking.isInking)
        input.end(pencil)
        XCTAssertFalse(harness.session.inking.isInking)
    }

    func testControllerSampleTapHandlersRunBeforeToolAndUnhandledTapReplays() async throws {
        let tool = Tool()
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        var handled = true
        registerTap(harness, id: "test.sampletap", order: 0) { _, _ in ["handled": .bool(handled)] }
        let tap = event(editor.host, id: 130, pencil: false)
        input.begin(tap, screenPoint: tap.location, route: .tool(tool))
        input.end(tap)
        XCTAssertTrue(tool.beganIDs.isEmpty)
        try await waitForGesture()
        XCTAssertTrue(tool.beganIDs.isEmpty, "A link tap must not erase or select anything")
        handled = false
        let next = event(editor.host, id: 131, pencil: false, timestamp: tap.timestamp + 1)
        input.begin(next, screenPoint: next.location, route: .tool(tool))
        input.end(next)
        try await waitForGesture()
        XCTAssertEqual(tool.beganIDs, [131])
        XCTAssertEqual(tool.endedIDs, [131])
        XCTAssertEqual(tool.taps, 0, "Sample tools receive the buffered dot, not a second tool tap")
        XCTAssertFalse(harness.session.inking.isInking)
    }

    func testControllerHandledFingerDotIsDiscardedAndDoubleTapUsesScreenThreshold() async throws {
        let tool = Tool(); tool.inputMode = .pencilKit
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        var gestures: [CanvasGesture] = []
        registerTap(harness, id: "test.dot", order: 0) { _, _ in gestures.append(.tap); return ["handled": true] }
        registerTap(harness, id: "test.double.dot", gesture: .doubleTap, order: 0) { _, _ in gestures.append(.doubleTap); return ["handled": true] }
        let contact = NSObject(), first = event(editor.host, id: 140, pencil: false)
        let canvas = try XCTUnwrap(input.acceptContact(ObjectIdentifier(contact), sample: first))
        let pk = PKBridge.pkStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 140, y: 220)], t0: Date().timeIntervalSince1970))
        input.begin(first, screenPoint: first.location, route: .tool(tool), contact: ObjectIdentifier(contact), startedAt: pk.path.creationDate)
        input.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: [pk])
        input.canvasViewDrawingDidChange(canvas)
        input.end(first)
        input.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(tool.finished, 0)
        try await waitForGesture()
        XCTAssertEqual(gestures, [.tap])
        XCTAssertEqual(tool.finished, 0)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        let a = event(editor.host, id: 141, pencil: false, timestamp: first.timestamp + 1)
        let b = event(editor.host, id: 142, pencil: false, point: Point(140 + 23 / editor.host.zoomScale, 220), timestamp: a.timestamp + 0.29)
        for sample in [a, b] { input.begin(sample, screenPoint: sample.location, route: .tool(tool)); input.end(sample) }
        try await waitForGesture()
        XCTAssertEqual(gestures, [.tap, .doubleTap])
        let c = event(editor.host, id: 143, pencil: false, timestamp: a.timestamp + 1)
        let d = event(editor.host, id: 144, pencil: false, point: Point(140 + 25 / editor.host.zoomScale, 220), timestamp: c.timestamp + 0.2)
        for sample in [c, d] { input.begin(sample, screenPoint: sample.location, route: .tool(tool)); input.end(sample) }
        try await waitForGesture()
        XCTAssertEqual(gestures, [.tap, .doubleTap, .tap, .tap])
    }

    func testControllerLifecycleDropsPendingTapAndHandledLongPressEndsInking() async throws {
        let tool = Tool()
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        var calls = 0
        registerTap(harness, id: "test.stale", order: 0) { _, _ in calls += 1; return ["handled": true] }
        for reset in [input.canvasActiveToolDidChange, input.canvasActivePageDidChange, input.canvasReadOnlyDidChange] {
            let tap = event(editor.host, id: 150, pencil: false)
            input.begin(tap, screenPoint: tap.location, route: .tool(tool)); input.end(tap)
            reset(editor.host)
            try await waitForGesture()
        }
        XCTAssertEqual(calls, 0)
        registerTap(harness, id: "test.held", gesture: .longPress, order: 0) { _, _ in ["handled": true] }
        let finger = event(editor.host, id: 151, pencil: false)
        input.begin(finger, screenPoint: finger.location, route: .tool(tool))
        XCTAssertTrue(harness.session.inking.isInking)
        await input.hold(finger.touchID, at: finger.timestamp + 0.5)
        XCTAssertFalse(harness.session.inking.isInking)
        input.end(finger)
        XCTAssertTrue(tool.beganIDs.isEmpty)
    }

    func testControllerHoldHandoffForwardsMovesAndEndAndRepeatedCancelKeepsInking() async throws {
        let tool = Tool(); tool.inputMode = .pencilKit; tool.handlesHold = true
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        let contact = NSObject(), began = event(editor.host, id: 160)
        let canvas = try XCTUnwrap(input.acceptContact(ObjectIdentifier(contact), sample: began))
        input.begin(began, screenPoint: began.location, route: .tool(tool), contact: ObjectIdentifier(contact))
        input.canvasViewDidBeginUsingTool(canvas)
        var moved = began; moved.location.x += 20; moved.timestamp += 0.1
        input.move([moved], screenPoint: moved.location, id: began.touchID)
        await input.hold(began.touchID, at: moved.timestamp + 0.49)
        XCTAssertEqual(tool.held, 0)
        await input.hold(began.touchID, at: moved.timestamp + 0.51)
        await input.hold(began.touchID, at: moved.timestamp + 0.6)
        XCTAssertEqual(tool.held, 1)
        XCTAssertTrue(harness.session.inking.isInking)
        input.canvasCancelWetStroke(editor.host)
        input.canvasCancelWetStroke(editor.host)
        XCTAssertTrue(harness.session.inking.isInking)
        moved.location.x += 10; moved.timestamp += 1
        input.move([moved], screenPoint: moved.location, id: began.touchID)
        input.end(moved)
        XCTAssertEqual(tool.moved.last?.touchID, began.touchID)
        XCTAssertEqual(tool.endedIDs, [began.touchID])
        XCTAssertFalse(harness.session.inking.isInking)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
    }

    func testControllerCancelFromStrokeFinishedIsIdempotent() async throws {
        let tool = Tool(); tool.inputMode = .pencilKit; tool.cancelOnFinish = true
        let (harness, editor, input) = try installed(tool)
        defer { editor.closeCanvas() }
        let contact = NSObject(), sample = event(editor.host, id: 170)
        let canvas = try XCTUnwrap(input.acceptContact(ObjectIdentifier(contact), sample: sample))
        let pk = PKBridge.pkStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2)], t0: Date().timeIntervalSince1970))
        input.begin(sample, screenPoint: sample.location, route: .tool(tool), contact: ObjectIdentifier(contact), startedAt: pk.path.creationDate)
        input.canvasViewDidBeginUsingTool(canvas)
        input.end(sample)
        canvas.drawing = PKDrawing(strokes: [pk]); input.canvasViewDrawingDidChange(canvas)
        input.canvasViewDidEndUsingTool(canvas)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tool.finished, 1)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(harness.session.inking.isInking)
    }

}
