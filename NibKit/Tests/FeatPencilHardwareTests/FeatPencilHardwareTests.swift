import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatPencilHardware

/// A document editor stand-in so `session.editor?.canvasHost` finds the fake canvas.
@MainActor
private final class FakeEditor: DocumentEditing {
    let host: FakeCanvasHost

    init(_ host: FakeCanvasHost) { self.host = host }

    var documentID: DocumentID { host.documentID }
    var session: EditorSession { host.session }
    var canvasHost: CanvasHost? { host }
    func reveal(page: PageID, rect: Rect?, animated: Bool) {}
    func reloadAll() {}
}

@MainActor
final class FeatPencilHardwareTests: XCTestCase {
    private func context(tool: String = "pen", previous: String? = nil, readOnly: Bool = false,
                         point: Point? = nil) -> PencilActionContext {
        PencilActionContext(tool: tool, previousTool: previous, readOnly: readOnly, doc: Fixtures.docID,
                            page: Fixtures.page1, point: point)
    }

    private func tool(_ invocation: PencilInvocation?) -> String? {
        invocation?.params["tool"]?.stringValue
    }

    private func pencilHandler(_ h: Harness) throws -> PencilHandler {
        try XCTUnwrap(h.app.ui.pencilHandler as? PencilHandler)
    }

    // MARK: Resolver (acceptance: every preferredTapAction and bound action maps to the right command)

    func testEverySystemPreferenceMapsToItsCommand() {
        func system(_ action: PencilSystemAction, _ c: PencilActionContext) -> PencilInvocation? {
            PencilActionResolver.resolve(.doubleTap, binding: "system", system: action, actions: [], context: c)
        }
        let pen = context(tool: "pen", previous: "highlighter")
        XCTAssertNil(system(.ignore, pen))
        XCTAssertNil(system(.runSystemShortcut, pen), "iPadOS runs the shortcut itself")
        XCTAssertEqual(system(.switchEraser, pen), PencilInvocation(command: "tool.select", params: ["tool": "eraser"]))
        XCTAssertEqual(tool(system(.switchEraser, context(tool: "eraser", previous: "highlighter"))), "highlighter")
        XCTAssertEqual(tool(system(.switchEraser, context(tool: "eraser", previous: nil))), "pen")
        XCTAssertEqual(tool(system(.switchEraser, context(tool: "eraser", previous: "eraser"))), "pen")
        XCTAssertEqual(tool(system(.switchPrevious, pen)), "highlighter")
        XCTAssertNil(system(.switchPrevious, context(tool: "pen", previous: nil)))
        XCTAssertNil(system(.switchPrevious, context(tool: "pen", previous: "pen")))
        let palettes: [(PencilSystemAction, String)] = [(.showColorPalette, "colours"), (.showInkAttributes, "attributes"),
                                                         (.showContextualPalette, "tools")]
        for (action, kind) in palettes {
            let invocation = system(action, pen)
            XCTAssertEqual(invocation?.command, "pencil.palette")
            XCTAssertEqual(invocation?.params["kind"], .string(kind))
        }
        XCTAssertEqual(PencilSystemAction.allCases.count, 7, "a new system action needs a mapping and a line above")
    }

    func testUIKitPreferredActionsMap() {
        XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.ignore), .ignore)
        XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.switchEraser), .switchEraser)
        XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.switchPrevious), .switchPrevious)
        XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.showColorPalette), .showColorPalette)
        if #available(iOS 17.5, *) {
            XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.showInkAttributes), .showInkAttributes)
            XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.showContextualPalette), .showContextualPalette)
            XCTAssertEqual(PencilSystemAction(UIPencilPreferredAction.runSystemShortcut), .runSystemShortcut)
        }
    }

    func testBindingsOverrideTheSystemAndRunPencilActions() {
        let undo = PencilActionDescriptor(id: "pencilhw.undo", title: "Undo", owner: "pencilhw", command: "edit.undo")
        let stamp = PencilActionDescriptor(id: "dev.stamp.go", title: "Stamp", owner: "dev.stamp", command: "dev.stamp.run",
                                           params: ["size": 3, "gesture": "custom"], gestures: ["squeeze"])
        func resolve(_ gesture: PencilGesture, _ binding: String, _ c: PencilActionContext) -> PencilInvocation? {
            PencilActionResolver.resolve(gesture, binding: binding, system: .showColorPalette, actions: [undo, stamp],
                                         context: c)
        }
        let pen = context(tool: "pen", previous: "lasso", point: Point(10, 20))
        XCTAssertEqual(tool(resolve(.doubleTap, "eraser", pen)), "eraser")
        XCTAssertEqual(tool(resolve(.doubleTap, "previous", pen)), "lasso")
        XCTAssertEqual(resolve(.doubleTap, "palette", pen)?.params["kind"], "tools")
        XCTAssertEqual(resolve(.doubleTap, "colours", pen)?.params["kind"], "colours")
        XCTAssertEqual(resolve(.squeeze, "attributes", pen)?.params["kind"], "attributes")
        XCTAssertNil(resolve(.doubleTap, "off", pen))
        XCTAssertEqual(resolve(.doubleTap, "system", pen)?.params["kind"], "colours")

        // The palette opens at the Pencil.
        let palette = resolve(.squeeze, "palette", pen)
        XCTAssertEqual(palette?.params["page"], "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(palette?.params["at"], [10, 20])

        // A Pencil action from content.pencilActions gets {gesture, doc, page, at}; its own params win.
        let undone = resolve(.doubleTap, "pencilhw.undo", pen)
        XCTAssertEqual(undone?.command, "edit.undo")
        XCTAssertEqual(undone?.params["doc"], "doc:FIXTUREDOC01")
        XCTAssertEqual(undone?.params["gesture"], "doubleTap")
        let stamped = resolve(.squeeze, "dev.stamp.go", pen)
        XCTAssertEqual(stamped?.command, "dev.stamp.run")
        XCTAssertEqual(stamped?.params["size"], 3)
        XCTAssertEqual(stamped?.params["gesture"], "custom")
        XCTAssertEqual(stamped?.params["at"], [10, 20])

        // A squeeze-only action on double-tap, or a removed plugin's action, follows the iPad setting.
        XCTAssertEqual(resolve(.doubleTap, "dev.stamp.go", pen)?.params["kind"], "colours")
        XCTAssertEqual(resolve(.doubleTap, "gone.plugin.action", pen)?.params["kind"], "colours")

        // Read-only mode ignores the Pencil.
        XCTAssertNil(resolve(.doubleTap, "eraser", context(readOnly: true)))
        XCTAssertNil(resolve(.squeeze, "pencilhw.undo", context(readOnly: true)))
    }

    func testGateDropsTheSecondDeliveryOfOneGesture() {
        var gate = PencilEventGate()
        XCTAssertTrue(gate.accept("doubleTap", at: 10))
        XCTAssertFalse(gate.accept("doubleTap", at: 10.1), "the canvas and the own interaction saw the same tap")
        XCTAssertTrue(gate.accept("squeeze", at: 10.1), "another gesture passes")
        XCTAssertTrue(gate.accept("doubleTap", at: 10.4), "the next real double-tap passes")
    }

    // MARK: Palette (acceptance: the palette mirrors the current toolbar layout)

    private func item(_ id: String, _ group: ToolbarGroup, order: Int, tool: String? = nil, hideable: Bool = true,
                      owner: String = "builtin") -> ToolbarItemDescriptor {
        ToolbarItemDescriptor(id: id, title: id, icon: "circle", group: group, order: order, owner: owner, toolID: tool,
                              hideable: hideable)
    }

    func testPaletteMirrorsTheCustomisedToolbar() {
        let items = [
            item("lasso", .lasso, order: 0, tool: "lasso", hideable: false),
            item("pen", .tools, order: 10, tool: "pen"),
            item("highlighter", .tools, order: 20, tool: "highlighter"),
            item("eraser", .tools, order: 30, tool: "eraser"),
            item("ruler", .accessories, order: 40),
            item("dev.stamp.tool", .tools, order: 50, tool: "dev.stamp.tool", owner: "dev.stamp"),
            item("tape", .tools, order: 60, tool: "tape"),
        ]
        let plugin: (String) -> Bool = { $0 == "dev.stamp" }
        func mirror(_ items: [ToolbarItemDescriptor], _ layout: JSONValue?) -> [String] {
            PalettePlan.mirror(items, layout: layout, isPlugin: plugin).map { $0.id }
        }

        // F016's defaults (no layout yet): the lasso, the everyday tools and plugin tools; tape waits in More.
        XCTAssertEqual(mirror(items, nil), ["lasso", "pen", "highlighter", "eraser", "dev.stamp.tool"])

        // Customised: saved order, hidden tools out, the lasso first and never hidden. Tape was never placed, so it
        // follows its default (More), like a built-in tool added after the person customised the toolbar.
        let layout: JSONValue = ["order": ["eraser", "dev.stamp.tool", "pen", "lasso"], "hidden": ["highlighter", "lasso"]]
        let expected = ["lasso", "eraser", "dev.stamp.tool", "pen"]
        XCTAssertEqual(mirror(items, layout), expected)

        // Items the layout never mentions keep their defaults and follow the ordered ones in registry order; tape shows
        // once the person has placed it on the toolbar.
        XCTAssertEqual(mirror(items, ["order": ["pen"], "hidden": ["highlighter"]]),
                       ["lasso", "pen", "eraser", "dev.stamp.tool"])
        XCTAssertEqual(mirror(items, ["order": ["tape", "pen"], "hidden": []]),
                       ["lasso", "tape", "pen", "highlighter", "eraser", "dev.stamp.tool"])

        // A lasso left hideable by its descriptor is still never hidden (F016 treats the lasso group as fixed).
        let hideableLasso = [item("lasso", .lasso, order: 0, tool: "lasso", hideable: true)] + items.dropFirst()
        XCTAssertEqual(mirror(hideableLasso, ["order": [], "hidden": ["lasso", "pen"]]),
                       ["lasso", "highlighter", "eraser", "dev.stamp.tool"])

        // Layout ids are descriptor ids only (a tool id does not hide a differently named item), and each tool gets one
        // slot: the first descriptor wins.
        let renamed = [item("lasso", .lasso, order: 0, tool: "lasso", hideable: false),
                       item("tool.pen", .tools, order: 10, tool: "pen"),
                       item("tool.pen.copy", .tools, order: 20, tool: "pen"),
                       item("tool.pen", .tools, order: 30, tool: "pencil")]
        XCTAssertEqual(mirror(renamed, ["order": [], "hidden": ["pen"]]), ["lasso", "tool.pen"])
        XCTAssertEqual(mirror(renamed, ["order": ["tool.pen.copy"], "hidden": []]), ["lasso", "tool.pen.copy"])

        let plan = PalettePlan.make(kind: .tools, toolbar: items, layout: layout, tool: "pen", previousTool: nil,
                                    presets: { ToolPresets.defaults(for: $0) }, canUndo: true, canRedo: false,
                                    isPlugin: { $0 == "dev.stamp" })
        XCTAssertEqual(plan.tools.map { $0.id }, expected)
        XCTAssertEqual(plan.tools.first { $0.id == "dev.stamp.tool" }?.isPlugin, true)
        XCTAssertEqual(plan.tools.first { $0.id == "pen" }?.tint, ToolPresets.defaults(for: "pen").color)
        XCTAssertNil(plan.tools.first { $0.id == "eraser" }?.tint)
        XCTAssertTrue(plan.showsTools)
        XCTAssertTrue(plan.showsHistory)
        XCTAssertTrue(plan.canUndo)
        XCTAssertFalse(plan.canRedo)
        XCTAssertEqual(plan.presetTool, "pen")
        XCTAssertEqual(plan.swatches.count, 3)
        XCTAssertEqual(plan.widths.count, 3)
        XCTAssertEqual(plan.selectedWidth, 1)
    }

    func testColourPalettesFallBackToTheLastWritingTool() {
        var marked = ToolPresets.defaults(for: "highlighter")
        marked.selectedSwatch = 2
        let highlighter = marked
        let presets: (String) -> ToolPresets = { $0 == "highlighter" ? highlighter : ToolPresets.defaults(for: $0) }
        func plan(_ kind: PaletteKind, _ tool: String, _ previous: String?) -> PalettePlan {
            PalettePlan.make(kind: kind, toolbar: [], layout: nil, tool: tool, previousTool: previous, presets: presets,
                             canUndo: false, canRedo: false, isPlugin: { _ in false })
        }
        let colours = plan(.colours, "eraser", "highlighter")
        XCTAssertEqual(colours.presetTool, "highlighter")
        XCTAssertTrue(colours.switchesTool)
        XCTAssertEqual(colours.selectedSwatch, 2)
        XCTAssertTrue(colours.showsColours)
        XCTAssertFalse(colours.showsWidths)
        XCTAssertFalse(colours.showsHistory)
        XCTAssertTrue(colours.tools.isEmpty)

        let attributes = plan(.attributes, "pencil", "eraser")
        XCTAssertEqual(attributes.presetTool, "pencil")
        XCTAssertFalse(attributes.switchesTool)
        XCTAssertTrue(attributes.showsWidths)

        XCTAssertNil(plan(.tools, "eraser", "pen").presetTool, "the full palette shows colours only for the current tool")
        XCTAssertEqual(plan(.colours, "lasso", nil).presetTool, "pen")
    }

    func testPaletteStaysInsideTheSafeArea() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let insets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(PalettePlacement.centre(size: size, anchor: CGPoint(x: 500, y: 400), bounds: bounds, insets: insets),
                       CGPoint(x: 500, y: 400))
        XCTAssertEqual(PalettePlacement.centre(size: size, anchor: CGPoint(x: 5, y: 5), bounds: bounds, insets: insets),
                       CGPoint(x: 116, y: 90))
        XCTAssertEqual(PalettePlacement.centre(size: size, anchor: CGPoint(x: 990, y: 790), bounds: bounds, insets: insets),
                       CGPoint(x: 884, y: 714))
    }

    // MARK: Hover preview

    func testHoverPreviewShowsWhatTheToolWillPutDown() {
        let pen = ToolPresets.defaults(for: "pen")
        let dot = HoverPreviewGeometry.shape(tool: "pen", presets: pen, zoom: 4, azimuth: 0, roll: nil)
        XCTAssertEqual(dot.kind, .dot)
        XCTAssertEqual(dot.size.width, CGFloat(pen.width * 4), accuracy: 0.001)
        XCTAssertEqual(dot.size.height, dot.size.width, accuracy: 0.001)
        XCTAssertEqual(dot.color?.r, pen.color.r)

        let tiny = HoverPreviewGeometry.shape(tool: "pen", presets: pen, zoom: 0.5, azimuth: 0, roll: nil)
        XCTAssertEqual(tiny.size.width, CGFloat(HoverPreviewGeometry.minimumDot), accuracy: 0.001)

        let nib = HoverPreviewGeometry.shape(tool: "pen", presets: pen, zoom: 4, azimuth: 0, roll: 0.5)
        XCTAssertEqual(nib.angle, 0.5, accuracy: 0.001, "a rolling Pencil Pro turns the pen's nib")
        XCTAssertLessThan(nib.size.height, nib.size.width)

        let highlighter = ToolPresets.defaults(for: "highlighter")
        let chisel = HoverPreviewGeometry.shape(tool: "highlighter", presets: highlighter, zoom: 1, azimuth: 0.3, roll: nil)
        XCTAssertEqual(chisel.kind, .chisel)
        XCTAssertEqual(chisel.size.height, CGFloat(highlighter.width), accuracy: 0.001)
        XCTAssertEqual(chisel.angle, 0.3, accuracy: 0.001)
        XCTAssertLessThanOrEqual(chisel.color?.alpha ?? 1, 0.51)

        // The eraser draws its own hover cursor (F010), so there is no second ring under the Pencil.
        XCTAssertEqual(HoverPreviewGeometry.shape(tool: "eraser", presets: nil, zoom: 2, azimuth: 0, roll: nil),
                       HoverPreviewShape.none)
        XCTAssertEqual(HoverPreviewGeometry.shape(tool: "eraser", presets: ToolPresets.defaults(for: "pen"), zoom: 2,
                                                  azimuth: 0, roll: nil), HoverPreviewShape.none)

        XCTAssertEqual(HoverPreviewGeometry.shape(tool: "lasso", presets: nil, zoom: 1, azimuth: 0, roll: nil).kind, .none)
        XCTAssertEqual(HoverPreviewGeometry.shape(tool: "pen", presets: nil, zoom: 1, azimuth: 0, roll: nil).kind, .none)
    }

    func testHoverDrawsThePreviewInTheOverlayAndHidesIt() throws {
        try XCTSkipUnless(PencilHandler.systemShowsHoverPreview, "the simulator's hover preview setting is off")
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        let handler = try pencilHandler(h)
        let host = FakeCanvasHost(h)
        host.zoomScale = 4
        h.session.tool = "pen"
        let sample = CanvasSample(page: Fixtures.page1, location: Point(50, 60))
        handler.pencilHover(sample, session: h.session, host: host)
        let layer = try XCTUnwrap(host.overlayLayer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(layer.position, host.viewPoint(Point(50, 60), page: Fixtures.page1))
        let width = ToolPresets.defaults(for: "pen").width * 4
        XCTAssertEqual(layer.path?.boundingBoxOfPath.width ?? 0, CGFloat(width), accuracy: 0.01)

        handler.pencilHover(nil, session: h.session, host: host)
        XCTAssertTrue(layer.isHidden, "the Pencil left the screen")

        h.session.tool = "lasso"
        handler.pencilHover(sample, session: h.session, host: host)
        XCTAssertTrue(layer.isHidden, "nothing to preview for the lasso")

        h.session.tool = "eraser"
        handler.pencilHover(sample, session: h.session, host: host)
        XCTAssertTrue(layer.isHidden, "the eraser's own hover cursor is the only ring")

        h.session.tool = "pen"
        h.session.readOnly = true
        handler.pencilHover(sample, session: h.session, host: host)
        XCTAssertTrue(layer.isHidden, "no preview in read-only mode")
        XCTAssertTrue(handler.seen.contains(.hover))
    }

    func testHardwareMatrixReportsWhatThisPencilDid() {
        XCTAssertEqual(PencilCapability.pressure.support(seen: [], proSupported: false), .available)
        XCTAssertEqual(PencilCapability.hover.support(seen: [], proSupported: true), .notDetected)
        XCTAssertEqual(PencilCapability.hover.support(seen: [.hover], proSupported: true), .detected)
        XCTAssertEqual(PencilCapability.squeeze.support(seen: [.squeeze], proSupported: false), .needsUpdate)
        XCTAssertEqual(PencilCapability.haptics.support(seen: [.roll], proSupported: true), .detected)
        XCTAssertEqual(PencilCapability.haptics.support(seen: [.doubleTap], proSupported: true), .notDetected)
    }

    // MARK: Gestures, the Pencil position and haptics

    /// Records what `receive` sends to `pencil.gesture` instead of running it.
    private func recordGestures(_ handler: PencilHandler) -> () -> [JSONValue] {
        var sent: [JSONValue] = []
        handler.performCommand = { command, params, _ in
            XCTAssertEqual(command, "pencil.gesture")
            sent.append(params)
        }
        return { sent }
    }

    /// The fake canvas in a window (so the palette can be presented) and in the session's editor.
    private func windowedCanvas(_ h: Harness) -> (host: FakeCanvasHost, editor: FakeEditor, window: UIWindow) {
        let host = FakeCanvasHost(h)
        let window = UIWindow(frame: host.canvasView.frame)
        window.addSubview(host.canvasView)
        let editor = FakeEditor(host)
        h.session.editor = editor
        return (host, editor, window)
    }

    func testAGestureWithoutAHoverPoseNeverReusesAnOldPencilPosition() throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        let handler = try pencilHandler(h)
        var now: TimeInterval = 100
        handler.clock = { now }
        let sent = recordGestures(handler)
        let host = FakeCanvasHost(h)
        let sample = CanvasSample(page: Fixtures.page1, location: Point(50, 60))

        handler.pencilHover(sample, session: h.session, host: host)
        now = 101.5
        handler.receive(.squeeze, at: nil, session: h.session, host: host)
        XCTAssertEqual(sent().last?["page"], "page:FIXTUREDOC01/FIXTUREPG001", "hovered 1.5 s ago: still at the tip")
        XCTAssertEqual(sent().last?["at"], [50, 60])

        // The squeeze had no hover pose, so it did not refresh the 100 s position: 2.5 s later it is stale.
        now = 102.5
        handler.receive(.doubleTap, at: nil, session: h.session, host: host)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent().last?["gesture"], "doubleTap")
        XCTAssertNil(sent().last?["page"])
        XCTAssertNil(sent().last?["at"])

        // A new hover is fresh again; a pose that comes with the gesture counts as a new position.
        handler.pencilHover(sample, session: h.session, host: host)
        now = 103
        handler.receive(.doubleTap, at: nil, session: h.session, host: host)
        XCTAssertEqual(sent().last?["at"], [50, 60])
        now = 110
        handler.receive(.squeeze, at: host.viewPoint(Point(70, 80), page: Fixtures.page1), session: h.session, host: host)
        XCTAssertEqual(sent().last?["at"], [70, 80])
        XCTAssertNil(handler.lastFeedback, "sending pencil.gesture plays nothing by itself")
    }

    func testAPencilGestureWhileThePaletteIsOpenOnlyClosesIt() throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        let handler = try pencilHandler(h)
        let sent = recordGestures(handler)
        let canvas = windowedCanvas(h)
        let shown = try handler.showPalette(.tools, session: h.session, page: nil, at: nil, fromPencil: false)
        XCTAssertTrue(shown.shown)
        XCTAssertTrue(handler.palette.isPresented)
        XCTAssertNil(handler.lastFeedback, "a palette opened without the Pencil plays no Pencil haptic")

        handler.receive(.doubleTap, at: nil, session: h.session, host: canvas.host)
        XCTAssertTrue(sent().isEmpty, "the gesture closes the palette and runs nothing")
        XCTAssertFalse(handler.palette.isPresented)

        handler.receive(.squeeze, at: nil, session: h.session, host: canvas.host)
        XCTAssertEqual(sent().count, 1, "with the palette closed, the next gesture runs its binding")
        withExtendedLifetime(canvas) {}
    }

    func testOnlyAPaletteOpenedByThePencilPlaysTheAlignmentHaptic() async throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        let handler = try pencilHandler(h)
        let sent = recordGestures(handler)
        let canvas = windowedCanvas(h)
        try await h.run("settings.set", ["name": "pencilhw.squeeze", "value": "palette"])

        // A physical squeeze: receive → pencil.gesture → pencil.palette.
        handler.receive(.squeeze, at: nil, session: h.session, host: canvas.host)
        let params = try XCTUnwrap(sent().last)
        let out = try await h.run("pencil.gesture", params)
        XCTAssertEqual(out["command"], "pencil.palette")
        XCTAssertTrue(handler.palette.isPresented)
        XCTAssertEqual(handler.lastFeedback?.kind, .alignment)
        try await h.run("pencil.palette", ["close": true])

        // The same command from AI or a plugin, and the keyboard shortcut's pencil.palette: no Pencil haptic.
        handler.lastFeedback = nil
        try await h.run("pencil.gesture", ["gesture": "squeeze"])
        XCTAssertTrue(handler.palette.isPresented)
        XCTAssertNil(handler.lastFeedback)
        try await h.run("pencil.palette", ["kind": "tools"])
        XCTAssertTrue(handler.palette.isPresented)
        XCTAssertNil(handler.lastFeedback)
        try await h.run("pencil.palette", ["close": true])
        XCTAssertFalse(handler.palette.isPresented)
        withExtendedLifetime(canvas) {}
    }

    func testSnapHapticFollowsTheShapeSnappedEventOnThePencilsCanvas() async throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        let handler = try pencilHandler(h)
        handler.start()
        let host = FakeCanvasHost(h)
        let page: JSONValue = "page:FIXTUREDOC01/FIXTUREPG001"
        func snap(_ doc: DocumentID, _ payload: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "shape": "ellipse"]) {
            h.app.events.emit("shape.snapped", doc: doc, payload: payload)
        }

        snap(Fixtures.docID)
        XCTAssertNil(handler.lastFeedback, "the Pencil has not been used on any canvas")

        handler.pencilHover(CanvasSample(page: Fixtures.page1, location: Point(50, 60)), session: h.session, host: host)
        snap("OTHERDOC0001")
        XCTAssertNil(handler.lastFeedback, "a snap in another document is not this Pencil's")
        h.app.events.emit("shape.created", doc: Fixtures.docID, payload: ["page": page])
        XCTAssertNil(handler.lastFeedback, "only the snap event plays it")

        snap(Fixtures.docID)
        XCTAssertEqual(handler.lastFeedback?.kind, .path)
        XCTAssertEqual(handler.lastFeedback?.point, host.viewPoint(Point(50, 60), page: Fixtures.page1))

        handler.lastFeedback = nil
        snap(Fixtures.docID, ["page": page, "shape": "rectangle", "at": [10, 20]])
        XCTAssertEqual(handler.lastFeedback?.point, host.viewPoint(Point(10, 20), page: Fixtures.page1),
                       "the snap's own point wins")

        handler.lastFeedback = nil
        try await h.run("settings.set", ["name": "pencilhw.haptics", "value": false])
        snap(Fixtures.docID)
        XCTAssertNil(handler.lastFeedback, "Pencil haptics off")
    }

    // MARK: Commands and registration

    func testRegistersHandlerAttachmentSettingsPageAndShortcut() throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        XCTAssertNoThrow(try pencilHandler(h))
        XCTAssertEqual(h.app.ui.settingsPages.get("pencilhw")?.section, .stylus)
        XCTAssertEqual(h.app.content.keyCommands.get("pencilhw.palette")?.command, "pencil.palette")
        XCTAssertEqual(h.app.content.pencilActions.get("pencilhw.undo")?.command, "edit.undo")
        // The descriptors spell their ids out (lint reads them); the constants callers use must match.
        XCTAssertEqual(PencilGestureCommand.descriptor.id, PencilCommandIDs.gesture)
        XCTAssertEqual(PencilPaletteCommand.descriptor.id, PencilCommandIDs.palette)
        XCTAssertEqual(PencilActionsCommand.descriptor.id, PencilCommandIDs.actions)

        let host = FakeCanvasHost(h)
        let attachment = try XCTUnwrap(h.app.ui.canvasAttachments.get("pencilhw.interaction")).make(host)
        attachment.attach(to: host)
        XCTAssertTrue(host.canvasView.interactions.contains { $0 is UIPencilInteraction })
        XCTAssertTrue(host.canvasView.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } ?? false)
        attachment.detach(from: host)
        XCTAssertFalse(host.canvasView.interactions.contains { $0 is UIPencilInteraction })
        XCTAssertFalse(host.canvasView.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } ?? false)
    }

    func testDoubleTapCommandSwitchesToTheEraserAndBack() async throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        try await h.run("settings.set", ["name": "pencilhw.doubleTap", "value": "eraser"])
        h.session.tool = "pen"
        let first = try await h.run("pencil.gesture", ["gesture": "doubleTap"])
        XCTAssertEqual(first["command"], "tool.select")
        XCTAssertEqual(first["binding"], "eraser")
        XCTAssertEqual(h.session.tool, "eraser")
        try await h.run("pencil.gesture", ["gesture": "doubleTap"])
        XCTAssertEqual(h.session.tool, "pen")

        h.session.readOnly = true
        let ignored = try await h.run("pencil.gesture", ["gesture": "doubleTap"])
        XCTAssertNil(ignored["command"])
        XCTAssertEqual(h.session.tool, "pen")
    }

    func testSystemBindingFollowsTheIPadSetting() async throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        try pencilHandler(h).systemPreference = { _ in .switchPrevious }
        h.session.tool = "pen"
        h.session.tool = "highlighter"
        let out = try await h.run("pencil.gesture", ["gesture": "doubleTap"])
        XCTAssertEqual(out["binding"], "system")
        XCTAssertEqual(h.session.tool, "pen")
    }

    func testBoundPencilActionRunsItsCommand() async throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        var received: JSONValue?
        h.app.commands.register(CommandDescriptor(
            id: "test.pencilAction", title: "Test", summary: "Records a Pencil action.", params: .obj(["mode": .str()]),
            examples: [["mode": "a"]], effect: .session, target: .app)) { params, _ in
            received = params
            return [:]
        }
        h.app.content.pencilActions.register(PencilActionDescriptor(
            id: "test.pencil", title: "Test", owner: "test", command: "test.pencilAction", params: ["mode": "b"],
            gestures: ["squeeze"]))
        try await h.run("settings.set", ["name": "pencilhw.squeeze", "value": "test.pencil"])
        let out = try await h.run("pencil.gesture", ["gesture": "squeeze", "page": "page:FIXTUREDOC01/FIXTUREPG001",
                                                     "at": [12, 34]])
        XCTAssertEqual(out["binding"], "test.pencil")
        XCTAssertEqual(out["command"], "test.pencilAction")
        XCTAssertEqual(received?["mode"], "b")
        XCTAssertEqual(received?["gesture"], "squeeze")
        XCTAssertEqual(received?["doc"], "doc:FIXTUREDOC01")
        XCTAssertEqual(received?["at"], [12, 34])

        let listed = try await h.run("pencil.actions")
        let ids = listed["choices"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        XCTAssertEqual(ids.first, "system")
        XCTAssertEqual(ids.last, "off")
        XCTAssertTrue(ids.contains("test.pencil"))
        XCTAssertTrue(ids.contains("pencilhw.undo"))
        XCTAssertEqual(listed["squeeze"], "test.pencil")
    }

    func testPaletteCommandMirrorsTheToolbarAndNeedsACanvas() async throws {
        let h = Harness(features: [FeatPencilHardwareFeature.self])
        for (index, id) in ["lasso", "pen", "highlighter", "eraser"].enumerated() {
            h.app.ui.toolbar.register(item(id, id == "lasso" ? .lasso : .tools, order: index, tool: id,
                                           hideable: id != "lasso"))
        }
        h.app.settings.setJSON("toolbar.layout", ["order": ["eraser", "pen"], "hidden": ["highlighter"]])

        do {
            try await h.run("pencil.palette", ["kind": "tools"])
            XCTFail("the palette needs an open canvas")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .unavailable)
        }

        let host = FakeCanvasHost(h)
        let editor = FakeEditor(host)
        h.session.editor = editor
        let out = try await h.run("pencil.palette", ["kind": "tools"])
        XCTAssertEqual(out["tools"], ["lasso", "eraser", "pen"])
        XCTAssertEqual(out["shown"], false, "the fake canvas is not in a window")
        let closed = try await h.run("pencil.palette", ["close": true])
        XCTAssertEqual(closed["shown"], false)
        withExtendedLifetime(editor) {}
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatPencilHardwareFeature.self])
        XCTAssertEqual(problems, [])
    }
}
