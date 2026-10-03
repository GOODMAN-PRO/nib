import XCTest
import SwiftUI
import UIKit
import NibContracts
@testable import NibDesign
import NibTesting
@testable import FeatToolbar

/// A canvas tool stand-in: only its stickiness matters here.
@MainActor
final class TestTool: CanvasTool {
    let id: String
    let isSticky: Bool
    var inputMode: CanvasInputMode { .taps }

    init(id: String, isSticky: Bool) {
        self.id = id
        self.isSticky = isSticky
    }
}

/// Adds a text box to the first fixture page: a user change to the open document (a tool's "one use").
struct TestTouch: NibCommand {
    static let descriptor = CommandDescriptor(
        id: "testtools.touch", title: "Touch", summary: "Add a text box to the first fixture page.",
        examples: [[:]], effect: .edit)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in
            try tx.put(Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 10, w: 80, h: 20), text: RichText(plain: "x"))),
                       doc: Fixtures.docID, page: Fixtures.page1)
        }
        return NoResult()
    }
}

/// Stand-in for the presets feature's command: the palette shows quick inks only when it exists.
struct TestPresetSelect: NibCommand {
    static let descriptor = CommandDescriptor(
        id: "preset.select", title: "Select Preset", summary: "Stand-in: select a colour slot of a writing tool.",
        examples: [[:]], effect: .session, target: .app)

    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> NoResult { NoResult() }
}

/// What the dock spy saw: the params of every `toolbar.dock` call, in order.
final class DockLog {
    static let key = "testtools.dockLog"
    var calls: [JSONValue] = []
}

/// Stand-in for a plugin's command hook on `toolbar.dock`: records each call and leaves its params alone.
struct TestDockSpy: NibCommand {
    struct Params: Codable {
        var command: String
        var params: JSONValue
    }

    static let descriptor = CommandDescriptor(
        id: "testtools.dockSpy", title: "Dock Spy", summary: "Stand-in hook: records toolbar.dock calls.",
        params: .obj(["command": .str(), "params": .anything()], required: ["command", "params"]),
        examples: [["command": "toolbar.dock", "params": ["dock": "top"]]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        ctx.services.get(DockLog.key, as: DockLog.self)?.calls.append(p.params)
        return NoResult()
    }
}

/// The library's synced prefs shared by two devices (one key per entry, like the Library Store).
final class SharedPrefs: SyncedSettingsBackend {
    private var values: [String: JSONValue] = [:]
    func value(_ name: String) -> JSONValue? { values[name] }
    func setValue(_ name: String, _ value: JSONValue?) { values[name] = value }
    func names() -> [String] { Array(values.keys) }
}

/// Stand-in for the features that own the tools: lasso, pen (settings; options from `ui.toolMenus`), eraser (its own
/// options bar), a non-sticky text tool and a ruler accessory that also asks for P.
enum TestToolsFeature: NibFeature {
    static let id = "testtools"

    static func register(_ app: NibApp) {
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "lasso.item", title: "Lasso", icon: "lasso", group: .lasso, order: 0, owner: id, toolID: "lasso",
            shortcut: KeyShortcut("l"), hideable: false))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "pen.item", title: "Pen", icon: "pencil.tip", group: .tools, order: 10, owner: id, toolID: "pen",
            shortcut: KeyShortcut("p"), settings: { _ in AnyView(EmptyView()) }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "eraser.item", title: "Eraser", icon: "eraser", group: .tools, order: 20, owner: id, toolID: "eraser",
            shortcut: KeyShortcut("e"), activeToolMenu: { _ in AnyView(EmptyView()) }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "text.item", title: "Text", icon: "textformat", group: .tools, order: 30, owner: id, toolID: "text",
            shortcut: KeyShortcut("t")))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "ruler.item", title: "Ruler", icon: "ruler", group: .accessories, order: 40, owner: id,
            command: "ruler.toggle", shortcut: KeyShortcut("P")))
        app.ui.toolMenus.register(ToolMenuDescriptor(tool: "pen", owner: id) { _ in AnyView(EmptyView()) })
        for (tool, sticky) in [("lasso", true), ("pen", true), ("eraser", true), ("text", false)] {
            app.ui.canvasTools.register(CanvasToolDescriptor(id: tool, title: tool, owner: id) {
                TestTool(id: tool, isSticky: sticky)
            })
        }
        app.commands.register(TestTouch.self)
        app.commands.register(TestPresetSelect.self)
    }
}

@MainActor
final class FeatToolbarTests: XCTestCase {
    private func harness() -> Harness {
        Harness(features: [FeatToolbarFeature.self, TestToolsFeature.self])
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func entry(_ id: String, _ group: ToolbarGroup, hideable: Bool = true, plugin: Bool = false) -> ToolbarEntry {
        ToolbarEntry(id: id, title: id, group: group, toolID: id, command: nil, hideable: hideable, isPlugin: plugin)
    }

    func testEraserSelectionAfterCommitAndCommandHandBackReleasePreviousOptions() async throws {
        let h = harness()
        let penPopover = PopoverFlag()
        let eraserPopover = PopoverFlag()
        for (tool, flag) in [("pen", penPopover), ("eraser", eraserPopover)] {
            var menu = ToolMenuDescriptor(tool: tool, owner: TestToolsFeature.id) { _ in AnyView(EmptyView()) }
            menu.makePopover = { _ in
                ToolMenuPopover(source: tool + ".size", isPresented: flag.binding, title: "Size") { EmptyView() }
            }
            h.app.ui.toolMenus.register(menu)
        }
        var eraser = try XCTUnwrap(h.app.ui.toolbar.get("eraser.item"))
        eraser.settings = { _ in AnyView(Text("Eraser settings")) }
        h.app.ui.toolbar.register(eraser)
        let model = ToolbarModel(app: h.app, session: h.session)
        let other = EditorSession()
        other.document = Fixtures.docID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        let host = FakeCanvasHost(h)

        for autoDeselect in [true, false] {
            try await h.run(CommandIDs.toolSelect, ["tool": "pen"])
            try await h.run(TestTouch.descriptor.id)
            model.refresh()
            XCTAssertNotNil(model.toolOptions(for: "pen"))
            let before = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
            let item = try XCTUnwrap(model.shown.first { $0.id == "eraser" })
            XCTAssertEqual(item.accessibilityID, "tool.eraser")
            XCTAssertTrue(item.isEnabled)

            penPopover.isOpen = true
            model.select(item.id)
            XCTAssertFalse(penPopover.isOpen, "The tap releases old options before asynchronous command dispatch")
            try await waitUntil("Eraser is selected in the invoking window") { h.session.tool == "eraser" }
            XCTAssertEqual(model.tool, "eraser")
            XCTAssertEqual(h.session.previousTool, "pen")
            XCTAssertEqual(other.tool, "pen")
            XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1), before)
            model.openSettings()
            XCTAssertTrue(model.settingsOpen, "The newly selected tool can immediately open settings")
            model.settingsOpen = false

            XCTAssertNotNil(model.toolOptions(for: "eraser"))
            eraserPopover.isOpen = true
            host.finishToolUse(TestTool(id: "eraser", isSticky: !autoDeselect))
            XCTAssertEqual(h.session.tool, autoDeselect ? "pen" : "eraser")
            XCTAssertEqual(model.tool, h.session.tool)
            XCTAssertEqual(eraserPopover.isOpen, !autoDeselect,
                           "Hand-back must release the old tool's modal input without a rendered view")
            // A shortcut also bypasses the palette's selection binding.
            try await h.run(CommandIDs.toolSelect, ["tool": "pen"])
            XCTAssertFalse(eraserPopover.isOpen)
        }
        withExtendedLifetime(model) {}
    }

    func testEraserHitTargetSurvivesInkingAndRetainedPopoverLayout() async throws {
        let h = harness()
        var pen = try XCTUnwrap(h.app.ui.toolbar.get("pen.item"))
        pen.settings = { _ in AnyView(Text("Pen settings").frame(height: 700)) }
        h.app.ui.toolbar.register(pen)
        let model = ToolbarModel(app: h.app, session: h.session)
        let inking = NibInkingState()
        var field: DropletField?
        let host = UIHostingController(rootView:
            NibDropletContainer(inking: inking) {
                ToolbarRootView(model: model, size: Self.landscape, compact: false)
                    .background(ToolbarFieldProbe { field = $0 })
            }
            .environment(\.scenePhase, .active))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.landscape))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await waitUntil("Eraser has a laid-out palette slot") {
            host.view.layoutIfNeeded()
            return field?.anchorRect("toolbar.palette.eraser") != nil
        }
        // Keep the settings content mounted, as in the production palette, then draw.
        model.openSettings()
        try await waitUntil("Pen settings accepts input") {
            host.view.layoutIfNeeded()
            return self.scrollViews(in: host.view).contains { $0.bounds.height > 400 && $0.isUserInteractionEnabled }
        }
        model.settingsOpen = false
        inking.isInking = true
        try await h.run(TestTouch.descriptor.id)
        inking.isInking = false
        model.refresh()
        try await waitUntil("Retained popovers release input after inking") {
            host.view.layoutIfNeeded()
            let panels = self.scrollViews(in: host.view).filter { $0.bounds.height > NibMetrics.barHeight + 1 }
            return panels.count >= 2 && panels.allSatisfy { !$0.isUserInteractionEnabled && $0.accessibilityElementsHidden }
        }
        let slot = try XCTUnwrap(field?.anchorRect("toolbar.palette.eraser"))
        let point = host.view.convert(CGPoint(x: slot.midX, y: slot.midY), to: window)
        let hit = try XCTUnwrap(window.hitTest(point, with: nil))
        for scroll in scrollViews(in: host.view) {
            XCTAssertFalse(hit === scroll || hit.isDescendant(of: scroll),
                           "Eraser's visible centre must not route to a retained settings, More or options scroller")
        }
        model.select("eraser")
        try await waitUntil("Eraser selects after the ink commit") { h.session.tool == "eraser" }
        XCTAssertEqual(h.session.previousTool, "pen")
    }

    /// Pencil defaults to More. Retained pen settings must release input when More opens, and selecting
    /// its pencil item must target this window and dismiss the overflow without changing document content.
    func testPencilInMoreAfterPenSettingsRemainsInteractiveAndSelectsItsWindow() async throws {
        let h = harness()
        var pen = try XCTUnwrap(h.app.ui.toolbar.get("pen.item"))
        pen.settings = { _ in AnyView(Text("Pen settings").frame(height: 700)) }
        h.app.ui.toolbar.register(pen)
        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "pencil.item", title: "Pencil", icon: "pencil", group: .tools, order: 11,
            owner: TestToolsFeature.id, toolID: "pencil", settings: { _ in AnyView(Text("Pencil settings")) }))
        h.app.ui.canvasTools.register(CanvasToolDescriptor(id: "pencil", title: "Pencil", owner: TestToolsFeature.id) {
            TestTool(id: "pencil", isSticky: true)
        })
        let model = ToolbarModel(app: h.app, session: h.session)
        let pencil = try XCTUnwrap(model.more.first { $0.id == "pencil" })
        XCTAssertEqual(pencil.accessibilityID, "tool.pencil")
        XCTAssertTrue(pencil.isEnabled)
        XCTAssertFalse(model.shown.contains { $0.id == "pencil" }, "Keep the six-tool default palette")
        let other = EditorSession()
        other.document = Fixtures.docID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)

        let host = UIHostingController(rootView:
            NibDropletContainer {
                ToolbarRootView(model: model, size: Self.landscape, compact: false)
            }
            .environment(\.scenePhase, .active))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.landscape))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        func panels() -> [UIScrollView] {
            scrollViews(in: host.view).filter { $0.bounds.height > NibMetrics.barHeight + 1 }
        }
        model.openSettings()
        try await waitUntil("Pen settings is interactive") {
            host.view.layoutIfNeeded()
            return panels().contains { $0.isUserInteractionEnabled && $0.bounds.height > 400 }
        }
        // A settings edit/ink commit refreshes the retained panels before the next tool switch.
        try await h.run(TestTouch.descriptor.id)
        model.refresh()
        let before = try h.app.workspace.content(Fixtures.docID)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        model.moreOpen = true
        XCTAssertFalse(model.settingsOpen, "More must close settings synchronously, before animation/mirroring")
        try await waitUntil("Only More accepts input") {
            host.view.layoutIfNeeded()
            let visible = panels().filter { $0.isUserInteractionEnabled }
            return visible.count == 1 && visible[0].bounds.height < 400
        }
        let more = try XCTUnwrap(panels().first { $0.isUserInteractionEnabled })
        XCTAssertFalse(more.accessibilityElementsHidden)
        var inputRoute = "No window hit"
        try await waitUntil("A window touch reaches the More grid instead of retained settings") {
            host.view.layoutIfNeeded()
            let point = more.convert(CGPoint(x: more.bounds.midX, y: more.bounds.midY), to: window)
            guard let hit = window.hitTest(point, with: nil) else { return false }
            inputRoute = "Hit \(hit) at \(point), expected a descendant of \(more)"
            return hit === more || hit.isDescendant(of: more)
        }
        let point = more.convert(CGPoint(x: more.bounds.midX, y: more.bounds.midY), to: window)
        let hit = window.hitTest(point, with: nil)
        XCTAssertTrue(hit === more || hit?.isDescendant(of: more) == true, inputRoute)
        for closed in panels() where closed !== more {
            XCTAssertTrue(closed.accessibilityElementsHidden)
            XCTAssertNil(closed.hitTest(CGPoint(x: closed.bounds.midX, y: closed.bounds.midY), with: nil))
        }

        model.select(pencil.id)
        try await waitUntil("Pencil is selected through the command") { h.session.tool == "pencil" }
        XCTAssertEqual(model.tool, "pencil")
        XCTAssertFalse(model.moreOpen)
        XCTAssertFalse(model.settingsOpen)
        XCTAssertEqual(other.tool, "pen")
        XCTAssertNotNil(model.settingsView(for: "pencil"))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID), before)
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1), items)

        model.moreOpen = true
        model.settingsOpen = true
        XCTAssertFalse(model.moreOpen, "Opening settings must also close More")
    }

    func testPencilChosenInPenSettingsCanReopenSettingsAfterDrawing() async throws {
        let h = harness()
        for (id, title) in [("pen", "Fountain Pen"), ("pencil", "Pencil")] {
            h.app.ui.toolbar.register(ToolbarItemDescriptor(
                id: id == "pen" ? "pen.item" : "pencil.item", title: title, icon: "pencil",
                group: .tools, order: id == "pen" ? 10 : 11, owner: TestToolsFeature.id, toolID: id,
                settings: { _ in AnyView(Text(title + " settings").frame(height: 700)) }))
        }
        h.app.ui.canvasTools.register(CanvasToolDescriptor(id: "pencil", title: "Pencil", owner: TestToolsFeature.id) {
            TestTool(id: "pencil", isSticky: true)
        })
        let model = ToolbarModel(app: h.app, session: h.session)
        let inking = NibInkingState()
        var field: DropletField?
        let host = UIHostingController(rootView:
            NibDropletContainer(inking: inking) {
                ToolbarRootView(model: model, size: Self.landscape, compact: false)
                    .background(ToolbarFieldProbe { field = $0 })
            }
            .environment(\.scenePhase, .active))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.landscape))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        func panels() -> [UIScrollView] {
            scrollViews(in: host.view).filter { $0.bounds.height > NibMetrics.barHeight + 1 }
        }
        model.openSettings()
        try await waitUntil("Pen settings opens") {
            host.view.layoutIfNeeded()
            return panels().contains { $0.isUserInteractionEnabled && $0.bounds.height > 400 }
        }
        // The Pencil tile dispatches tool.select directly, without the palette's selection binding.
        try await h.run(CommandIDs.toolSelect, ["tool": "pencil"])
        XCTAssertEqual(model.paletteSelection(compact: false), "pencil")
        XCTAssertFalse(model.settingsOpen)
        inking.isInking = true
        try await h.run(TestTouch.descriptor.id)
        inking.isInking = false
        model.refresh()
        try await waitUntil("both writing tools are reachable after the settings source changes and ink commits") {
            host.view.layoutIfNeeded()
            guard let field, panels().count >= 2,
                  panels().allSatisfy({ !$0.isUserInteractionEnabled && $0.accessibilityElementsHidden }) else { return false }
            return ["pen", "pencil"].allSatisfy { id in
                guard let slot = field.anchorRect("toolbar.palette." + id),
                      let hit = window.hitTest(host.view.convert(CGPoint(x: slot.midX, y: slot.midY), to: window), with: nil)
                else { return false }
                return !panels().contains { hit === $0 || hit.isDescendant(of: $0) }
            }
        }
        // NibToolPalette calls onReselect, then toggles the settings binding.
        model.toolReselected("pencil")
        model.settingsOpen.toggle()
        try await waitUntil("the selected Pencil settings becomes interactive again") {
            host.view.layoutIfNeeded()
            return panels().contains { $0.isUserInteractionEnabled && $0.bounds.height > 400 }
        }
        XCTAssertEqual(h.session.tool, "pencil", "Opening settings must preserve the writing tool")
        XCTAssertEqual(model.shown.first { $0.id == "pen" }?.title, "Fountain Pen")
    }

    /// Closed settings and More remain mounted for their bud animations. Their native scroll views must
    /// release touches, including after ink/commit refreshes, so a visible Lasso button can receive its tap.
    func testPaletteClosedPopoversReleaseHitTargetsAfterDrawingAndSettingsDismissal() async throws {
        let h = harness()
        var pen = try XCTUnwrap(h.app.ui.toolbar.get("pen.item"))
        pen.settings = { _ in AnyView(Text("Pen settings").frame(height: 320)) }
        h.app.ui.toolbar.register(pen)
        let model = ToolbarModel(app: h.app, session: h.session)
        let inking = NibInkingState()
        let size = Self.landscape
        let host = UIHostingController(rootView:
            NibDropletContainer(inking: inking) {
                ToolbarRootView(model: model, size: size, compact: false)
            })
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        func popovers() -> [UIScrollView] {
            // The fused options bar is 44 pt high; these are the settings and More panels.
            scrollViews(in: host.view).filter { $0.bounds.height > NibMetrics.barHeight + 1 }
        }
        func checkClosed() async throws {
            try await waitUntil("closed palette popovers release their native hit targets") {
                host.view.layoutIfNeeded()
                let panels = popovers()
                return panels.count >= 2 && panels.allSatisfy { !$0.isUserInteractionEnabled }
            }
            XCTAssertGreaterThanOrEqual(popovers().count, 2)
            for scroll in popovers() {
                XCTAssertTrue(scroll.accessibilityElementsHidden)
                XCTAssertNil(scroll.hitTest(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), with: nil),
                             "An invisible settings/More panel must not intercept a palette tap")
            }
        }
        try await checkClosed()
        inking.isInking = true
        try await h.run(TestTouch.descriptor.id)
        inking.isInking = false
        model.refresh()
        try await checkClosed()

        model.openSettings()
        try await waitUntil("Pen settings becomes interactive") {
            host.view.layoutIfNeeded()
            return popovers().contains { $0.isUserInteractionEnabled }
        }
        model.settingsOpen = false
        try await checkClosed()
        model.moreOpen = true
        try await waitUntil("More becomes interactive") {
            host.view.layoutIfNeeded()
            return popovers().contains { $0.isUserInteractionEnabled }
        }
        model.moreOpen = false
        try await checkClosed()
    }

    func testLassoPaletteActionAfterCommitSelectsItsWindowAndPreservesContent() async throws {
        let h = harness()
        let model = ToolbarModel(app: h.app, session: h.session)
        let other = EditorSession()
        other.document = Fixtures.docID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        try await h.run(TestTouch.descriptor.id)
        let before = try h.app.workspace.content(Fixtures.docID)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let selection = h.session.selection
        model.refresh()
        XCTAssertEqual(model.shown.first?.id, "lasso")
        XCTAssertEqual(model.shown.first?.accessibilityID, "tool.lasso")
        model.select("lasso")
        try await waitUntil("the palette selects Lasso through tool.select") { h.session.tool == "lasso" }
        XCTAssertEqual(model.tool, "lasso")
        XCTAssertEqual(other.tool, "pen", "The palette targets its own session, even when another window is active")
        XCTAssertEqual(h.session.selection, selection)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID), before)
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1), items)
        try await waitUntil("Lasso is the remembered sticky tool") {
            h.app.settings.json("toolbar.lastTool.notebook")?.stringValue == "lasso"
        }
        try await h.run(TestTouch.descriptor.id)
        model.refresh()
        XCTAssertEqual(h.session.tool, "lasso", "A later commit must not restore Pen")
    }

    /// Insert tools share the palette's input path. Exercise the retained native panels in an active
    /// scene, including the lower rows of More, then dispatch to the owning window.
    func testInsertToolsRemainReachableAfterPopoverRelayoutAndSelectTheirWindow() async throws {
        let h = harness()
        // Keep insert tools in the lower rows, as in the fully registered app's More grid.
        for index in 0..<8 {
            h.app.ui.toolbar.register(ToolbarItemDescriptor(
                id: "extra.\(index)", title: "Accessory \(index)", icon: "ruler", group: .accessories,
                order: 31 + index, owner: TestToolsFeature.id, command: "ruler.toggle"))
        }
        let inserts = ["shape", "image", "sticky", "tape", "elements"]
        for (index, id) in inserts.enumerated() {
            h.app.ui.toolbar.register(ToolbarItemDescriptor(
                id: id + ".item", title: id, icon: "square", group: .tools, order: 40 + index,
                owner: TestToolsFeature.id, toolID: id,
                settings: { _ in AnyView(Text(id + " settings").frame(height: 600)) }))
            h.app.ui.canvasTools.register(CanvasToolDescriptor(id: id, title: id, owner: TestToolsFeature.id) {
                TestTool(id: id, isSticky: false)
            })
        }
        let model = ToolbarModel(app: h.app, session: h.session)
        let other = EditorSession()
        other.document = Fixtures.docID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        let before = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let host = UIHostingController(rootView:
            NibDropletContainer {
                ToolbarRootView(model: model, size: Self.landscape, compact: false)
            }
            .environment(\.scenePhase, .active))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.landscape))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        func panels() -> [UIScrollView] {
            scrollViews(in: host.view).filter { $0.bounds.height > NibMetrics.barHeight + 1 }
        }
        for id in ["text"] + inserts {
            print("Insert palette regression: \(id)")
            let item = try XCTUnwrap((model.shown + model.more).first { $0.id == id })
            XCTAssertEqual(item.accessibilityID, "tool." + id)
            XCTAssertTrue(item.isEnabled)
            if model.more.contains(where: { $0.id == id }) {
                model.openSettings()
                model.moreOpen = true
                model.refresh()
                var inputRoute = "More has not laid out"
                try await waitUntil("More owns its native hit target for \(id)") {
                    host.view.layoutIfNeeded()
                    let open = panels().filter { $0.isUserInteractionEnabled }
                    inputRoute = "\(open.count) enabled panels; More=\(model.moreOpen), settings=\(model.settingsOpen)"
                    guard open.count == 1, let panel = open.first else { return false }
                    // Check both the first and last grid rows; the centre alone can miss an overlap.
                    return [CGFloat(0.25), 0.8].allSatisfy { fraction in
                        let point = panel.convert(CGPoint(x: panel.bounds.midX,
                                                          y: panel.bounds.minY + panel.bounds.height * fraction), to: window)
                        let hit = window.hitTest(point, with: nil)
                        let reachesPanel = hit === panel || hit?.isDescendant(of: panel) == true
                        if !reachesPanel { inputRoute += "; row \(fraction): hit \(String(describing: hit)) at \(point), panel \(panel)" }
                        return reachesPanel
                    }
                }
                print("Insert palette input: \(id): \(inputRoute)")
            }
            model.select(id)
            XCTAssertFalse(model.moreOpen, "Choosing a tool releases More before command execution")
            XCTAssertFalse(model.settingsOpen, "Choosing a tool releases settings before command execution")
            try await waitUntil("\(id) activates in the palette's window") { h.session.tool == id }
            XCTAssertEqual(model.tool, id)
            XCTAssertEqual(other.tool, "pen")
            XCTAssertFalse(model.moreOpen)
            XCTAssertFalse(model.settingsOpen)
            try await waitUntil("\(id)'s closed menus release the next input") {
                host.view.layoutIfNeeded()
                return !panels().isEmpty && panels().allSatisfy {
                    !$0.isUserInteractionEnabled && $0.accessibilityElementsHidden
                }
            }
            XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1), before)
            // Insert tools hand back only when the canvas explicitly finishes their use.
            model.refresh()
            XCTAssertEqual(h.session.tool, id)
            model.select("pen")
            try await waitUntil("return to Pen before the next insert tool") { h.session.tool == "pen" }
        }
    }

    func testMoreGridRoundingNoiseDoesNotRestartLayoutButRealMovementDoes() throws {
        let field = DropletField()
        field.setActive(false)
        field.reduceMotion = true
        let id = "toolbar.palette.more"
        let rest = CGRect(x: 92, y: 433.33333333333337, width: 312, height: 236.33333333333337)
        field.setRest(id, rest, style: .popover)
        field.setBud(id, source: "toolbar.palette.more.source", presented: true, instant: true, dismiss: {})
        let settled = field.node(id).presentation
        let settledFrame = try XCTUnwrap(field.visualFrame(id))
        // Frames captured from the native three-row More grid's layout feedback loop.
        let rounded = CGRect(x: 92, y: 433.5, width: 312, height: 236.33333333333326)
        let roundedHeight = CGRect(x: 92, y: 433.5, width: 312, height: 236)
        for frame in [rounded, rest, roundedHeight, rest, rounded, rest, rest.offsetBy(dx: 0, dy: 0.25)] {
            field.setRest(id, frame, style: .popover)
            XCTAssertEqual(field.node(id).presentation, settled,
                           "Rounding noise must not republish presentation and restart SwiftUI layout")
            XCTAssertEqual(field.visualFrame(id), settledFrame)
        }
        for delta in [CGFloat(0.1), 0.2] {
            field.setRest(id, rest.offsetBy(dx: delta, dy: 0), style: .popover)
            XCTAssertEqual(field.visualFrame(id), settledFrame)
        }
        field.setRest(id, rest.offsetBy(dx: 0.3, dy: 0), style: .popover)
        XCTAssertEqual(try XCTUnwrap(field.visualFrame(id)).minX, rest.minX + 0.3, accuracy: 1e-9,
                       "Small real moves accumulate against the retained frame instead of being lost")
        let moved = rest.offsetBy(dx: 12, dy: 24)
        field.setRest(id, moved, style: .popover)
        let movedFrame = try XCTUnwrap(field.visualFrame(id))
        XCTAssertEqual(movedFrame.minX, moved.minX, accuracy: 1e-9)
        XCTAssertEqual(movedFrame.minY, moved.minY, accuracy: 1e-9,
                       "An actual dock/layout change must still take effect")
        let resized = CGRect(origin: moved.origin, size: CGSize(width: moved.width + 1, height: moved.height + 1))
        field.setRest(id, resized, style: .popover)
        XCTAssertEqual(try XCTUnwrap(field.visualFrame(id)).width, resized.width, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(field.visualFrame(id)).height, resized.height, accuracy: 1e-9)
        field.unregister(id)
    }

    func testMoreOpeningCatchesUpAfterADelayedDisplayFrame() throws {
        let field = DropletField()
        field.setActive(false)
        let id = "toolbar.palette.more"
        let rest = CGRect(x: 92, y: 320, width: 312, height: 236)
        field.setWorldAnchor("more.source", CGRect(x: 16, y: 400, width: 56, height: 56))
        field.setRest(id, rest, style: .popover)
        field.setBud(id, source: "more.source", presented: true, instant: false, dismiss: {})
        var steps: [TimeInterval] = []
        let driver = DisplayLinkDriver { dt in
            steps.append(dt)
            _ = field.tick(dt)
            return true
        }
        driver.start()
        defer { driver.stop(); field.unregister(id) }
        driver.advance(at: 10)
        driver.advance(at: 11)
        XCTAssertEqual(steps.last, 1, "A delayed frame must advance the full elapsed animation time")
        let frame = try XCTUnwrap(field.visualFrame(id))
        XCTAssertEqual(frame.midX, rest.midX, accuracy: 0.5,
                       "More must reach its own hit targets after a stalled frame")
        XCTAssertEqual(frame.midY, rest.midY, accuracy: 0.5)
        XCTAssertEqual(frame.width, rest.width, accuracy: 0.5)
        XCTAssertEqual(frame.height, rest.height, accuracy: 0.5)
        driver.advance(at: 20)
        XCTAssertEqual(steps.last, 1, "Long stalls stay within the spring integrator's safe bound")
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatToolbarFeature.self])
        XCTAssertEqual(problems, [])
    }

    /// Vertical fitting must get a usable form height even when List has no intrinsic content height.
    func testCustomizationSheetHasAnIdealSizeBeforeRowsAreLaidOut() {
        let h = harness()
        for scheme in [ColorScheme.light, .dark] {
            let host = UIHostingController(rootView:
                ToolbarCustomizationView(app: h.app, onDone: {})
                    .environment(\.colorScheme, scheme)
                    .fixedSize())
            let fitted = host.sizeThatFits(in: Self.portrait)
            XCTAssertEqual(fitted.width, NibMetrics.newDocumentSheetSize.width, accuracy: 1)
            XCTAssertEqual(fitted.height, NibMetrics.newDocumentSheetSize.height, accuracy: 1,
                           "Fitted presentation must allocate the form, not just its header")
        }
    }

    /// Exercise the actual List viewport, including short windows and AX3; all the extra rows stay scrollable.
    func testCustomizationSheetBoundsItsListToTheAvailableViewport() async throws {
        let h = harness()
        for index in 0..<30 {
            h.app.ui.toolbar.register(ToolbarItemDescriptor(
                id: "plugin.\(index)", title: "Plugin Tool \(index)", icon: "pencil.tip",
                group: .tools, order: 100 + index, owner: "test.plugin", toolID: "plugin.\(index)"))
        }
        let viewports = [Self.portrait, Self.landscape, Self.phone, CGSize(width: 320, height: 300)]
        for viewport in viewports {
            for type in [DynamicTypeSize.large, .accessibility3] {
                let host = UIHostingController(rootView:
                    ToolbarCustomizationView(app: h.app, onDone: {})
                        .environment(\.dynamicTypeSize, type))
                host.safeAreaRegions = []
                let fitted = host.sizeThatFits(in: viewport)
                XCTAssertLessThanOrEqual(fitted.width, viewport.width)
                XCTAssertLessThanOrEqual(fitted.height, viewport.height)
                XCTAssertGreaterThan(fitted.height, NibMetrics.hitTarget * 4)

                let window = UIWindow(frame: CGRect(origin: .zero, size: fitted))
                window.rootViewController = host
                window.isHidden = false
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                }
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                try await waitUntil("customisation list layout") {
                    self.scrollViews(in: host.view).contains {
                        $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height
                    }
                }
                let list = try XCTUnwrap(scrollViews(in: host.view).first {
                    $0.contentSize.height > $0.bounds.height
                })
                XCTAssertGreaterThan(list.bounds.height, NibMetrics.hitTarget * 2,
                                     "The editable list must have more than a sliver below the header")
                let frame = list.convert(list.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(frame.minY, NibMetrics.hitTarget,
                                            "The header remains above the scrolling list")
                XCTAssertLessThanOrEqual(frame.maxY, host.view.bounds.maxY + 1)
                XCTAssertTrue(list.isScrollEnabled)
                let bottom = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
                list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                XCTAssertEqual(list.contentOffset.y, bottom, accuracy: 1,
                               "Rows beyond the allocated viewport remain reachable")
            }
        }
    }

    func testCustomizationEmbeddedInSettingsUsesTheParentViewport() {
        let h = harness()
        let host = UIHostingController(rootView: ToolbarCustomizationView(app: h.app, onDone: nil))
        let viewport = CGSize(width: 480, height: 800)
        let fitted = host.sizeThatFits(in: viewport)
        XCTAssertEqual(fitted.width, viewport.width, accuracy: 1)
        XCTAssertEqual(fitted.height, viewport.height, accuracy: 1,
                       "Settings must not inherit the standalone sheet's height cap")
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// Defaults, unknown items and precedence rules of the layout, without an app.
    func testArrangeAppliesDefaultsAndTheLayout() throws {
        let entries = [entry("lasso", .lasso, hideable: false), entry("pen", .tools), entry("eraser", .tools),
                       entry("ruler", .accessories), entry("stamp", .tools, plugin: true)]
        let defaults = ToolbarLayoutEngine.arrange(entries, layout: nil)
        XCTAssertEqual(defaults, ToolbarArrangement(shown: ["lasso", "pen", "eraser", "stamp"], more: ["ruler"]))

        // Known ids follow the layout; the lasso stays first and on the palette; an id the layout never saw
        // (a plugin installed afterwards) keeps its default and goes after the ordered ones.
        let layout = ToolbarLayout(order: ["ruler", "eraser", "pen"], hidden: ["pen", "lasso"])
        XCTAssertEqual(ToolbarLayoutEngine.arrange(entries, layout: layout),
                       ToolbarArrangement(shown: ["lasso", "ruler", "eraser", "stamp"], more: ["pen"]))
        XCTAssertEqual(try ToolbarLayoutEngine.sanitized(layout, entries: entries).hidden, ["pen"])

        // Materialising keeps what the old layout said about items that are not registered right now.
        let old = ToolbarLayout(order: ["gone", "pen"], hidden: ["gone"])
        XCTAssertEqual(ToolbarLayoutEngine.materialize(defaults, keeping: old),
                       ToolbarLayout(order: ["lasso", "pen", "eraser", "stamp", "ruler", "gone"], hidden: ["ruler", "gone"]))
    }

    func testResetRestoresOnePartAndKeepsTheOther() {
        let entries = [entry("lasso", .lasso, hideable: false), entry("pen", .tools), entry("eraser", .tools),
                       entry("text", .tools), entry("ruler", .accessories), entry("zoom", .accessories)]
        let layout = ToolbarLayout(order: ["ruler", "zoom", "eraser", "pen"], hidden: ["pen", "zoom"])
        XCTAssertEqual(ToolbarLayoutEngine.reset(layout, part: .tools, entries: entries),
                       ToolbarLayout(order: ["lasso", "pen", "eraser", "text", "ruler", "zoom"], hidden: ["zoom"]))
        XCTAssertEqual(ToolbarLayoutEngine.reset(layout, part: .accessories, entries: entries),
                       ToolbarLayout(order: ["eraser", "pen", "ruler", "zoom"], hidden: ["pen", "ruler", "zoom"]))
        XCTAssertNil(ToolbarLayoutEngine.reset(layout, part: .toolbar, entries: entries))
    }

    /// Acceptance: layout persistence.
    func testLayoutPersistsAndAFreshPaletteReadsItBack() async throws {
        let h = harness()
        let first = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(first.shown.map { $0.id }, ["lasso", "pen", "eraser", "text"])
        XCTAssertEqual(first.more.map { $0.id }, ["ruler.item"])

        // The ruler onto the palette first, text into More; hiding the lasso is refused silently.
        try await h.run("toolbar.setLayout", ["order": ["ruler.item", "pen.item", "eraser.item", "text.item"],
                                              "hidden": ["text.item", "lasso.item"]])
        let stored = try XCTUnwrap(h.app.settings.json("toolbar.layout")).decode(ToolbarLayout.self)
        XCTAssertEqual(stored.hidden, ["text.item"])
        XCTAssertTrue(h.app.settings.descriptor("toolbar.layout")?.synced ?? false)

        let fresh = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(fresh.shown.map { $0.id }, ["lasso", "ruler.item", "pen", "eraser"])
        XCTAssertEqual(fresh.more.map { $0.id }, ["text"])

        try await h.run("toolbar.reset", ["part": "toolbar"])
        XCTAssertNil(h.app.settings.json("toolbar.layout"))
        do {
            try await h.run("toolbar.reset", ["part": "everything"])
            XCTFail("an unknown part is refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    /// Acceptance: plugin toolbar items appear and can be hidden.
    func testPluginItemsAppearAndCanBeHidden() async throws {
        let h = harness()
        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "stamps.stamp", title: "Stamp", icon: "seal", group: .tools, order: 50, owner: "com.example.stamps",
            command: "com.example.stamps.stamp"))
        let model = ToolbarModel(app: h.app, session: h.session)
        let stamp = try XCTUnwrap(model.shown.first { $0.id == "stamps.stamp" })
        XCTAssertTrue(stamp.isPlugin)
        XCTAssertFalse(stamp.isTool)

        // The customisation sheet lists it like a native item, and its − moves it into More.
        let sheet = ToolbarCustomizationModel(app: h.app)
        XCTAssertTrue(sheet.shown.contains { $0.id == "stamps.stamp" && $0.isPlugin })
        sheet.hide("stamps.stamp")
        XCTAssertTrue(sheet.more.contains { $0.id == "stamps.stamp" })
        try await waitUntil("the layout hides the stamp") {
            ToolbarStore.current(h.app.settings)?.hidden.contains("stamps.stamp") == true
        }
        model.refresh()
        XCTAssertFalse(model.shown.contains { $0.id == "stamps.stamp" })
        XCTAssertTrue(model.more.contains { $0.id == "stamps.stamp" })

        // Plugins and the AI see the same state.
        let listed = try await h.run("toolbar.layouts")
        let item = listed["items"]?.arrayValue?.first { $0["id"]?.stringValue == "stamps.stamp" }
        XCTAssertEqual(item?["plugin"]?.boolValue, true)
        XCTAssertEqual(item?["onPalette"]?.boolValue, false)
    }

    func testSavedLayoutsRoundTrip() async throws {
        let h = harness()
        try await h.run("toolbar.setLayout", ["order": ["eraser.item", "pen.item"], "hidden": ["pen.item"]])
        let saved = try await h.run("toolbar.saveLayout", ["name": "  Exam mode "])
        XCTAssertEqual(saved["name"]?.stringValue, "Exam mode")
        XCTAssertNotNil(h.app.settings.json("toolbar.layouts.Exam mode"), "one key per saved layout")

        try await h.run("toolbar.reset", ["part": "toolbar"])
        XCTAssertNil(ToolbarStore.current(h.app.settings))
        try await h.run("toolbar.applyLayout", ["name": "Exam mode"])
        XCTAssertEqual(ToolbarStore.current(h.app.settings)?.hidden, ["pen.item", "ruler.item"])

        let listed = try await h.run("toolbar.layouts")
        XCTAssertEqual(listed["layouts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["Exam mode"])

        try await h.run("toolbar.deleteLayout", ["name": "Exam mode"])
        XCTAssertNil(ToolbarStore.saved("Exam mode", h.app.settings))
        XCTAssertEqual(ToolbarStore.current(h.app.settings)?.hidden, ["pen.item", "ruler.item"], "current layout kept")
        do {
            try await h.run("toolbar.applyLayout", ["name": "Exam mode"])
            XCTFail("a deleted layout cannot be applied")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .notFound)
        }
        do {
            try await h.run("toolbar.saveLayout", ["name": "   "])
            XCTFail("an empty name is refused")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testApplySavedReorderedLayoutRestoresHighlighterBeforeFountainPenAndKeepsLassoFirst() async throws {
        let h = harness()
        var pen = try XCTUnwrap(h.app.ui.toolbar.get("pen.item"))
        pen.title = "Fountain Pen"
        h.app.ui.toolbar.register(pen)
        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "highlighter.item", title: "Highlighter", icon: "highlighter", group: .tools, order: 15,
            owner: TestToolsFeature.id, toolID: "highlighter"))
        let sheet = ToolbarCustomizationModel(app: h.app)
        XCTAssertEqual(sheet.shown.prefix(2).map(\.title), ["Fountain Pen", "Highlighter"])
        XCTAssertEqual(sheet.fixed.map(\.id), ["lasso.item"])
        XCTAssertFalse(try XCTUnwrap(sheet.fixed.first).hideable)

        sheet.move(.palette, from: IndexSet(integer: 1), to: 0)
        try await waitUntil("the reordered rows are stored") {
            ToolbarStore.current(h.app.settings)?.order.prefix(3) == ["lasso.item", "highlighter.item", "pen.item"]
        }
        sheet.save("Reordered chrome")
        try await waitUntil("the saved layout appears") { sheet.savedNames.contains("Reordered chrome") }
        sheet.reset(.tools)
        try await waitUntil("reset restores registry order") {
            sheet.shown.prefix(2).map(\.id) == ["pen.item", "highlighter.item"]
        }
        sheet.apply("Reordered chrome")
        try await waitUntil("apply restores the reordered rows") {
            sheet.shown.prefix(2).map(\.id) == ["highlighter.item", "pen.item"]
        }
        let reopened = ToolbarCustomizationModel(app: h.app)
        XCTAssertEqual(reopened.shown.prefix(2).map(\.title), ["Highlighter", "Fountain Pen"])
        XCTAssertEqual(reopened.fixed.map(\.id), ["lasso.item"])
        XCTAssertFalse(try XCTUnwrap(reopened.fixed.first).hideable)
        let palette = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(palette.shown.prefix(3).map(\.id), ["lasso", "highlighter", "pen"])
        XCTAssertEqual(palette.shown.first { $0.id == "pen" }?.accessibilityID, "tool.pen")
    }

    func testNativePaletteMoveOffsetsIncludeTheFixedLassoPrefix() async throws {
        let h = harness()
        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "highlighter.item", title: "Highlighter", icon: "highlighter", group: .tools, order: 15,
            owner: TestToolsFeature.id, toolID: "highlighter"))
        let model = ToolbarCustomizationModel(app: h.app)
        XCTAssertEqual(model.fixed.map(\.id), ["lasso.item"])
        XCTAssertEqual(model.shown.prefix(2).map(\.id), ["pen.item", "highlighter.item"])
        model.movePaletteRows(from: IndexSet(integer: 2), to: 1)
        try await waitUntil("native move persists above Pen") {
            ToolbarStore.current(h.app.settings)?.order.prefix(3) == ["lasso.item", "highlighter.item", "pen.item"]
        }
        model.movePaletteRows(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.fixed.map(\.id), ["lasso.item"])
        XCTAssertEqual(model.shown.prefix(2).map(\.id), ["highlighter.item", "pen.item"])
        model.movePaletteRows(from: IndexSet(integer: 2), to: 0)
        try await waitUntil("a drop over Lasso clamps to the first movable slot") {
            ToolbarStore.current(h.app.settings)?.order.prefix(3) == ["lasso.item", "pen.item", "highlighter.item"]
        }
    }

    /// Plugins and the AI write the synced layout: over-long lists and ids are refused, never stored or truncated.
    func testLayoutListsAndIdsAreCapped() async throws {
        let h = harness()
        let tooMany = JSONValue.array(Array(repeating: .string("pen.item"), count: ToolbarLayoutEngine.maxIDs + 1))
        let tooLong = JSONValue.string(String(repeating: "x", count: ToolbarLayoutEngine.maxIDLength + 1))
        let cases: [(JSONValue, String)] = [(["order": tooMany, "hidden": []], "$.order"),
                                            (["order": ["pen.item"], "hidden": [tooLong]], "$.hidden[0]")]
        for (params, path) in cases {
            do {
                try await h.run("toolbar.setLayout", params)
                XCTFail("an over-long layout is refused")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
                XCTAssertEqual(e.path, path)
            }
        }
        XCTAssertNil(ToolbarStore.current(h.app.settings), "nothing is stored")
    }

    /// ARCHITECTURE.md §4.3: saved layouts are one synced key per name, so two devices saving never overwrite each other.
    func testSavedLayoutsFromTwoDevicesBothSurvive() async throws {
        let prefs = SharedPrefs()
        let ipad = Harness(features: [FeatToolbarFeature.self, TestToolsFeature.self], deviceID: 7)
        let iphone = Harness(features: [FeatToolbarFeature.self, TestToolsFeature.self], deviceID: 8)
        ipad.app.settings.syncedBackend = prefs
        iphone.app.settings.syncedBackend = prefs

        try await ipad.run("toolbar.setLayout", ["order": ["eraser.item", "pen.item"], "hidden": []])
        try await ipad.run("toolbar.saveLayout", ["name": "Exam"])
        try await iphone.run("toolbar.setLayout", ["order": ["pen.item"], "hidden": ["eraser.item"]])
        try await iphone.run("toolbar.saveLayout", ["name": "Lecture"])

        for h in [ipad, iphone] {
            let listed = try await h.run("toolbar.layouts")
            XCTAssertEqual(listed["layouts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["Exam", "Lecture"])
        }
        XCTAssertEqual(ToolbarStore.saved("Exam", iphone.app.settings)?.hidden.contains("eraser.item"), false)
        XCTAssertEqual(ToolbarStore.saved("Lecture", ipad.app.settings)?.hidden.contains("eraser.item"), true)
    }

    private static let landscape = CGSize(width: 1180, height: 820)
    private static let portrait = CGSize(width: 820, height: 1180)
    private static let phone = CGSize(width: 390, height: 844)

    private func toolbarRuntime(_ h: Harness) throws -> ToolbarRuntime {
        try XCTUnwrap(h.app.services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self))
    }

    /// An iPad window in landscape (compact: an iPhone-width one), as the palette reports it.
    private func window(_ h: Harness, compact: Bool = false) throws -> ToolbarRuntime {
        let runtime = try toolbarRuntime(h)
        runtime.windowDidChange(h.session, size: compact ? Self.phone : Self.landscape, compact: compact)
        return runtime
    }

    private func dock(_ edge: String, _ along: Double = 0.5) throws -> ToolbarDockSetting {
        let setting = ToolbarDockSetting(edge: edge, along: along)
        XCTAssertNotNil(setting.dock, "\(edge) is a dock")
        return setting
    }

    private func expectInvalid(_ h: Harness, _ params: JSONValue, as principal: Principal = .user,
                               path: String? = nil, _ what: String) async {
        do {
            try await h.run("toolbar.dock", params, as: principal)
            XCTFail(what)
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams, what)
            if let path { XCTAssertEqual(e.path, path, what) }
        } catch {
            XCTFail("\(what): \(error)")
        }
    }

    /// The dock rules shared by the command and the palette: defaults, compact validation, `along`, stored names.
    func testDockRules() throws {
        XCTAssertEqual(ToolbarDockRules.defaultDock(size: Self.landscape, compact: false).edge.commandValue, "left")
        XCTAssertEqual(ToolbarDockRules.defaultDock(size: Self.portrait, compact: false).edge.commandValue, "top")
        XCTAssertEqual(ToolbarDockRules.defaultDock(size: Self.phone, compact: true).edge.commandValue, "bottom")

        let right = try XCTUnwrap(try dock("right", 0.2).dock)
        XCTAssertEqual(ToolbarDockSetting(ToolbarDockRules.validated(right, compact: false)), try dock("right", 0.2))
        XCTAssertEqual(ToolbarDockSetting(ToolbarDockRules.validated(right, compact: true)), try dock("bottom"),
                       "a side dock shows at the bottom on a compact width")

        // along: as asked, else kept on the same axis, else the middle.
        XCTAssertEqual(ToolbarDockRules.along(0.9, edge: .leading, current: right), 0.9)
        XCTAssertEqual(ToolbarDockRules.along(nil, edge: .leading, current: right), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ToolbarDockRules.along(nil, edge: .top, current: right), 0.5)

        // Left and right are the leading and trailing edges; an older build's "trailing" still reads.
        XCTAssertEqual(right.edge, .trailing)
        XCTAssertEqual(try dock("left").dock?.edge, .leading)
        XCTAssertEqual(ToolbarDockSetting(edge: "trailing", along: 0.3).dock.map { ToolbarDockSetting($0) },
                       try dock("right", 0.3))
        XCTAssertNil(ToolbarDockSetting(edge: "middle", along: 0.3).dock)
    }

    /// Acceptance: `toolbar.dock`'s schema and example validate, and bad params are refused for every caller.
    func testDockCommandSchema() async throws {
        let h = harness()
        _ = try window(h)
        let d = try XCTUnwrap(h.app.commands.entry("toolbar.dock")).descriptor
        XCTAssertEqual(d.effect, .session)
        XCTAssertEqual(d.examples, [["dock": "right"]])
        for example in d.examples { XCTAssertEqual(d.params.validate(example), [], "the example validates") }
        let good: [JSONValue] = [["dock": "top"], ["dock": "bottom", "along": 0], ["dock": "left", "along": 1]]
        for params in good { XCTAssertEqual(d.params.validate(params), [], "\(params)") }
        let bad: [JSONValue] = [[:], ["dock": "middle"], ["dock": "leading"], ["dock": "top", "along": 1.5],
                                ["dock": "top", "along": "half"], ["along": 0.5]]
        for params in bad { XCTAssertFalse(d.params.validate(params).isEmpty, "\(params) fails the schema") }

        let ai = Principal.ai("chat")
        await expectInvalid(h, ["dock": "middle"], as: ai, path: "$.dock", "an unknown dock is refused")
        await expectInvalid(h, ["dock": "top", "along": 2], as: ai, path: "$.along", "along past 1 is refused")
        await expectInvalid(h, ["dock": "middle"], path: "$.dock", "the user's call checks the dock too")
        await expectInvalid(h, ["dock": "top", "along": -0.1], path: "$.along", "and along")
        XCTAssertNil(ToolbarStore.dock(h.app.settings), "nothing is stored")
    }

    /// Acceptance: it persists `toolbar.dock` per device, maps left and right to the leading and trailing edges, and a
    /// fresh palette reads it back.
    func testDockPersistsPerDeviceAndMapsLeftAndRight() async throws {
        let h = harness()
        _ = try window(h)
        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(ToolbarDockSetting(model.dock(for: Self.landscape, compact: false)), try dock("left"))
        XCTAssertEqual(ToolbarDockSetting(model.dock(for: Self.portrait, compact: false)), try dock("top"))
        XCTAssertEqual(ToolbarDockSetting(model.dock(for: Self.phone, compact: true)), try dock("bottom"))

        let moved = try await h.run("toolbar.dock", ["dock": "right", "along": 0.25])
        XCTAssertEqual(moved["dock"]?.stringValue, "right")
        XCTAssertEqual(moved["along"]?.doubleValue, 0.25)
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("right", 0.25))
        XCTAssertEqual(h.app.settings.json("toolbar.dock")?["edge"]?.stringValue, "right")
        XCTAssertFalse(h.app.settings.descriptor("toolbar.dock")?.synced ?? true, "the dock is per device")

        let fresh = ToolbarModel(app: h.app, session: h.session)
        let shown = fresh.dock(for: Self.landscape, compact: false)
        XCTAssertEqual(shown.edge, .trailing, "right is the trailing edge")
        XCTAssertEqual(ToolbarDockSetting(shown), try dock("right", 0.25))
        XCTAssertEqual(ToolbarDockSetting(fresh.dock(for: Self.phone, compact: true)), try dock("bottom"),
                       "a side dock shows at the bottom on iPhone")

        try await h.run("toolbar.dock", ["dock": "left"])
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("left", 0.25), "same axis: along stays")
        try await h.run("toolbar.dock", ["dock": "bottom"])
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("bottom", 0.5), "new axis: the middle")

        let listed = try await h.run("toolbar.layouts")
        XCTAssertEqual(listed["dock"]?["dock"]?.stringValue, "bottom", "readable through the query API")
        withExtendedLifetime(model) {}
    }

    /// Acceptance: compact widths refuse the side docks.
    func testCompactWidthsRefuseTheSideDocks() async throws {
        let h = harness()
        _ = try window(h, compact: true)
        for edge in ["left", "right"] {
            do {
                try await h.run("toolbar.dock", ["dock": .string(edge)], as: .ai("chat"))
                XCTFail("\(edge) is refused on a compact width")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
                XCTAssertEqual(e.message, ToolbarDock.compactRefusal)
            }
        }
        XCTAssertNil(ToolbarStore.dock(h.app.settings))
        let moved = try await h.run("toolbar.dock", ["dock": "top"], as: .ai("chat"))
        XCTAssertEqual(moved["previous"]?["dock"]?.stringValue, "bottom", "iPhone starts at the bottom")
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("top"))
    }

    /// Acceptance: the result's `previous`, replayed by a caller that is not the user, restores the dock.
    func testDockReturnsPreviousWhoseReplayRestoresIt() async throws {
        let h = harness()
        _ = try window(h)
        let ai = Principal.ai("chat")
        let landscapeDefault: JSONValue = ["dock": "left", "along": 0.5]
        let bottom: JSONValue = ["dock": "bottom", "along": 0.8]
        let right: JSONValue = ["dock": "right", "along": 0.5]
        let first = try await h.run("toolbar.dock", bottom, as: ai)
        XCTAssertEqual(first["previous"], landscapeDefault, "nothing saved: the landscape default")

        let moved = try await h.run("toolbar.dock", ["dock": "right"], as: ai)
        XCTAssertEqual(moved["along"]?.doubleValue, 0.5)
        let previous = try XCTUnwrap(moved["previous"])
        XCTAssertEqual(previous, bottom)

        let undone = try await h.run("toolbar.dock", previous, as: ai)
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("bottom", 0.8))
        XCTAssertEqual(undone["previous"], right, "and that undo can be undone in turn")
    }

    /// Acceptance: a drag's release goes through `toolbar.dock` (command hooks see it), the palette shows the new
    /// dock at once, and a refused move falls back.
    func testADragReleaseDocksThroughTheCommand() async throws {
        let h = harness()
        let runtime = try window(h)
        let log = DockLog()
        h.app.services.set(log, for: DockLog.key)
        h.app.commands.register(TestDockSpy.self)
        h.app.bus.hooks.register(CommandHookDescriptor(id: "testtools.dockSpy", owner: TestToolsFeature.id,
                                                       commands: ["toolbar.dock"], command: TestDockSpy.descriptor.id))
        let model = ToolbarModel(app: h.app, session: h.session)
        let top = try dock("top", 0.25)
        let released = try XCTUnwrap(top.dock)
        let call: JSONValue = ["dock": "top", "along": 0.25]

        model.requestDock(released)
        XCTAssertEqual(ToolbarDockSetting(model.dock(for: Self.landscape, compact: false)), top, "the palette lands at once")
        try await waitUntil("toolbar.dock stores the release") { ToolbarStore.dock(h.app.settings) == top }
        XCTAssertEqual(log.calls, [call])
        try await waitUntil("the move settles") { model.pendingDock == nil }
        XCTAssertEqual(ToolbarDockSetting(model.dock(for: Self.landscape, compact: false)), top)

        // A side dock on a compact width is refused: the palette stays where it was.
        runtime.windowDidChange(h.session, size: Self.phone, compact: true)
        model.requestDock(try XCTUnwrap(try dock("left").dock))
        try await waitUntil("the refused move settles") { model.pendingDock == nil }
        XCTAssertEqual(ToolbarDockSetting(model.dock(for: Self.phone, compact: true)), top)
        XCTAssertEqual(log.calls.count, 2)
    }

    /// Undo and Redo of the window's UndoManager ("Move Palette") replay the dock through the command.
    func testDockUndoAndRedoOnTheWindowsUndoManager() async throws {
        let h = harness()
        let runtime = try window(h)
        let undo = UndoManager()
        undo.groupsByEvent = false
        runtime.setUndoManager(undo, for: h.session)

        try await h.run("toolbar.dock", ["dock": "right", "along": 0.25])
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Move Palette")

        undo.undo()
        try await waitUntil("Undo moves the palette back") { ToolbarStore.dock(h.app.settings)?.edge == "left" }
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("left"))
        XCTAssertTrue(undo.canRedo)
        XCTAssertFalse(undo.canUndo, "the replay registers no second step")

        undo.redo()
        try await waitUntil("Redo moves it again") { ToolbarStore.dock(h.app.settings)?.edge == "right" }
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("right", 0.25))
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)

        // A move to where the palette already is adds no step of its own; a window that goes away takes its steps.
        try await h.run("toolbar.dock", ["dock": "right", "along": 0.25])
        XCTAssertEqual(ToolbarStore.dock(h.app.settings), try dock("right", 0.25))
        undo.undo()
        try await waitUntil("Undo again") { ToolbarStore.dock(h.app.settings)?.edge == "left" }
        runtime.setUndoManager(nil, for: h.session)
        XCTAssertFalse(undo.canRedo)
    }

    /// DESIGN.md §14.2: iPad shows three quick inks, iPhone one, the current ink.
    func testIPhoneShowsOneQuickInkTheCurrentOne() {
        let h = harness()
        var presets = ToolPresets.defaults(for: "pen")
        presets.selectedSwatch = 2
        h.app.settings.set(NibSettings.presets("pen"), presets)
        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(model.quickInks(compact: false).map { $0.index }, [0, 1, 2])
        XCTAssertEqual(model.quickInks(compact: true).map { $0.index }, [2])
    }

    func testCompactInkFollowsSelectionsBeyondTheThreeQuickSlots() async throws {
        let h = harness()
        var presets = ToolPresets.defaults(for: "pen")
        presets.swatches += (3..<ToolPresets.maxSwatches).map {
            PresetSwatch(color: RGBA(UInt8($0 * 20), 80, 160))
        }
        h.app.settings.set(NibSettings.presets("pen"), presets)
        let model = ToolbarModel(app: h.app, session: h.session)
        let regular = model.quickInks(compact: false)

        for index in [3, 11, 1] {
            presets.selectedSwatch = index
            h.app.settings.set(NibSettings.presets("pen"), presets)
            try await waitUntil("the selected ink refreshes") { model.swatchIndex == index }
            XCTAssertEqual(model.quickInks(compact: true),
                           [QuickSwatch(index: index, color: presets.swatches[index].color)])
            XCTAssertEqual(model.quickInks(compact: false), regular)
        }
        // Editing the selected slot also refreshes the compact colour without changing its selection.
        presets.swatches[1].color = RGBA(40, 90, 130)
        h.app.settings.set(NibSettings.presets("pen"), presets)
        try await waitUntil("the edited ink refreshes") {
            model.quickInks(compact: true).first?.color == presets.swatches[1].color
        }
    }

    func testHighlighterSwatchesAreOpaqueWithoutChangingStoredStrokeColours() {
        let h = harness()
        var presets = ToolPresets.defaults(for: "highlighter")
        presets.swatches.append(PresetSwatch(color: RGBA(120, 180, 240, 64)))
        presets.selectedSwatch = 3
        h.app.settings.set(NibSettings.presets("highlighter"), presets)
        h.session.tool = "highlighter"
        let model = ToolbarModel(app: h.app, session: h.session)
        for compact in [false, true] {
            for swatch in model.quickInks(compact: compact) {
                let stored = presets.swatches[swatch.index].color
                XCTAssertEqual(swatch.color, RGBA(stored.r, stored.g, stored.b, 255))
            }
        }
        XCTAssertEqual(model.quickInks(compact: true).map { $0.index }, [3])
        XCTAssertEqual(h.app.settings.get(NibSettings.presets("highlighter")), presets)

        var pen = ToolPresets.defaults(for: "pen")
        pen.swatches[0].color = RGBA(40, 90, 130, 100)
        h.app.settings.set(NibSettings.presets("pen"), pen)
        h.session.tool = "pen"
        XCTAssertEqual(model.quickInks(compact: false).first?.color, pen.swatches[0].color)
    }

    func testToolValueUsesLocalisedMillimetresAndPreservesAccessoryStates() {
        XCTAssertEqual(ToolbarModel.accessibilityValue(colour: "Carbon", width: 1.2, isOn: true,
                                                       isEnabled: false, locale: Locale(identifier: "en_GB")),
                       "Carbon, 0.42 millimetres, On, Unavailable")
        let french = ToolbarModel.accessibilityValue(colour: nil, width: 1.2, isOn: false,
                                                      isEnabled: true, locale: Locale(identifier: "fr_FR"))
        XCTAssertTrue(french?.contains("0,42") == true)
        XCTAssertNil(ToolbarModel.accessibilityValue(colour: nil, isOn: false, isEnabled: true))
    }

    func testToolThicknessValueRefreshesWhenSelectingAndEditingWidths() async throws {
        for tool in ["pen", "pencil", "highlighter"] {
            let h = harness()
            if tool != "pen" {
                h.app.ui.toolbar.register(ToolbarItemDescriptor(
                    id: "\(tool).item", title: tool, icon: "pencil.tip", group: .tools, order: 15,
                    owner: TestToolsFeature.id, toolID: tool))
            }
            h.session.tool = tool
            var presets = ToolPresets.defaults(for: tool)
            presets.widths = [72 / 25.4, 144 / 25.4, 216 / 25.4]
            presets.selectedWidth = 0
            h.app.settings.set(NibSettings.presets(tool), presets)
            let model = ToolbarModel(app: h.app, session: h.session)
            func value() -> String? { (model.shown + model.more).first { $0.id == tool }?.value }
            func expected(_ millimetres: Double) -> String {
                let width = String(format: String(localized: "%.2f millimetres"),
                                   locale: Locale.current, millimetres)
                return "\(ToolbarModel.colourName(presets.color, index: presets.selectedSwatch)), \(width)"
            }
            XCTAssertEqual(value(), expected(1), tool)
            presets.selectedWidth = 2
            h.app.settings.set(NibSettings.presets(tool), presets)
            try await waitUntil("\(tool) announces the selected width") { value() == expected(3) }
            presets.widths[2] = 288 / 25.4
            h.app.settings.set(NibSettings.presets(tool), presets)
            try await waitUntil("\(tool) announces the edited width") { value() == expected(4) }
        }
    }

    /// A shared accessory and quick inks must never create palette chrome over a text document or study set.
    func testPaletteOnlyAppearsInCanvasDocumentsAndFollowsDocumentChanges() {
        let h = harness()
        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "testtools.sharedAccessory", title: "Shared Accessory", icon: "ruler", group: .accessories,
            order: 50, owner: TestToolsFeature.id, command: "ruler.toggle", docKinds: Set(DocumentKind.allCases)))
        let model = ToolbarModel(app: h.app, session: h.session)

        for (document, kind, expected) in [
            (Fixtures.docID, DocumentKind.notebook, true),
            (Fixtures.textDocID, .textDocument, false),
            (Fixtures.whiteboardID, .whiteboard, true),
            (Fixtures.studySetID, .studySet, false),
            (Fixtures.docID, .notebook, true)
        ] {
            h.session.document = document
            XCTAssertEqual(model.kind, kind)
            XCTAssertFalse(model.more.isEmpty, "the shared accessory reproduces the otherwise empty shell")
            XCTAssertFalse(model.quickInks(compact: false).isEmpty)
            XCTAssertFalse(model.quickInks(compact: true).isEmpty)
            XCTAssertEqual(model.isPaletteDocument, expected)
            XCTAssertEqual(model.showsPalette, expected)
        }

        h.session.readOnly = true
        XCTAssertFalse(model.showsPalette)
        h.session.readOnly = false
        h.session.document = nil
        XCTAssertFalse(model.isPaletteDocument)
        XCTAssertFalse(model.showsPalette)
    }

    /// A missing tool has no bead; tools in More are promoted, while compact-width filtering stays authoritative.
    func testPaletteSelectionOnlyMatchesAnAvailableTool() async throws {
        let h = harness()
        var plugin = ToolbarItemDescriptor(
            id: "stamps.stamp", title: "Stamp", icon: "seal", group: .tools, order: 50, owner: "com.example.stamps",
            toolID: "com.example.stamps.tool")
        plugin.showsInCompactWidth = false
        h.app.ui.toolbar.register(plugin)
        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(model.paletteSelection(compact: false), "pen")

        try await h.run("toolbar.setLayout", ["order": [], "hidden": ["text.item"]])
        model.refresh()
        h.session.tool = "text"
        XCTAssertTrue(model.more.contains { $0.id == "text" })
        XCTAssertEqual(model.paletteSelection(compact: false), "text")
        XCTAssertEqual(model.paletteSelection(compact: true), "text")

        h.session.tool = "com.example.stamps.tool"
        XCTAssertEqual(model.paletteSelection(compact: false), "com.example.stamps.tool")
        XCTAssertEqual(model.paletteSelection(compact: true), "")
        XCTAssertEqual(h.session.tool, "com.example.stamps.tool", "filtering never changes the session's tool")
        h.app.ui.toolbar.unregister(owner: "com.example.stamps")
        model.refresh()
        XCTAssertEqual(model.paletteSelection(compact: false), "")

        for tool in ["unknown", "ruler.item"] {
            h.session.tool = tool
            XCTAssertEqual(model.paletteSelection(compact: false), "")
            XCTAssertEqual(model.paletteSelection(compact: true), "")
        }
    }

    /// A tool whose stickiness comes from a setting, like F026's pinned text tool.
    private func registerPinnableNote(_ h: Harness) {
        let settings = h.app.settings
        h.app.ui.canvasTools.register(CanvasToolDescriptor(id: "note", title: "note", owner: TestToolsFeature.id) {
            TestTool(id: "note", isSticky: settings.json("testtools.notePinned")?.boolValue ?? false)
        })
    }

    /// Stickiness is asked afresh: a tool may read it from a setting (F026's pinned text tool).
    func testStickinessIsReadEveryTime() throws {
        let h = harness()
        registerPinnableNote(h)
        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertFalse(model.isSticky("note"))
        h.app.settings.setJSON("testtools.notePinned", true)
        XCTAssertTrue(model.isSticky("note"))
        XCTAssertTrue(model.isSticky("unknown"), "an unknown tool counts as sticky")
    }

    func testVisibilityIsPerWindowAndTogglesWithoutAValue() async throws {
        let h = harness()
        let model = ToolbarModel(app: h.app, session: h.session)
        let other = EditorSession()
        h.app.services.sessions.add(other)
        XCTAssertTrue(model.isVisible)

        let toggled = try await h.run("toolbar.setVisible")
        XCTAssertEqual(toggled["visible"]?.boolValue, false)
        XCTAssertFalse(model.isVisible)
        let runtime = try XCTUnwrap(h.app.services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self))
        XCTAssertTrue(runtime.isVisible(other), "another window keeps its palette")
        let listed = try await h.run("toolbar.layouts")
        XCTAssertEqual(listed["visible"]?.boolValue, false, "readable without toggling it")

        try await h.run("toolbar.setVisible", ["visible": true])
        XCTAssertTrue(model.isVisible)
    }

    func testShortcutsFollowToolbarItems() async throws {
        let h = harness()
        await FeatToolbarFeature.start(h.app)
        let runtime = try XCTUnwrap(h.app.services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self))
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatToolbarFeature.id }
        XCTAssertTrue(keys.allSatisfy { $0.scope == .canvas })
        let pen = try XCTUnwrap(keys.first { $0.id == "toolbar.key.pen.item" })
        XCTAssertEqual(pen.command, CommandIDs.toolSelect)
        XCTAssertEqual(pen.params["tool"]?.stringValue, "pen")
        XCTAssertNotNil(keys.first { $0.shortcut == KeyShortcut("w") && $0.command == "toolbar.setVisible" })
        XCTAssertNil(keys.first { $0.id == "toolbar.key.ruler.item" }, "P already belongs to the pen")
        XCTAssertEqual(Set(keys.map { ToolbarShortcuts.normalized($0.shortcut) }).count, keys.count, "no key twice")

        // The palette shows each key the shell runs as a hint, and registers none of them itself.
        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(model.shown.first { $0.id == "pen" }?.keyHint, KeyShortcut("p"))
        let ruler = try XCTUnwrap(model.more.first { $0.id == "ruler.item" })
        XCTAssertNil(ruler.keyHint, "the ruler's P is the pen's")
        XCTAssertEqual(ToolKeyHint.keyboardShortcut(KeyShortcut("p")), KeyboardShortcut("p", modifiers: []))
        XCTAssertEqual(ToolKeyHint.keyboardShortcut(KeyShortcut("up", [.command, .shift])),
                       KeyboardShortcut(.upArrow, modifiers: [.command, .shift]))
        XCTAssertNil(ToolKeyHint.keyboardShortcut(KeyShortcut("pp")))

        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "stamps.stamp", title: "Stamp", icon: "seal", group: .tools, order: 50, owner: "com.example.stamps",
            toolID: "com.example.stamps.tool", shortcut: KeyShortcut("k")))
        runtime.syncKeyCommands()
        XCTAssertEqual(h.app.content.keyCommands.get("toolbar.key.stamps.stamp")?.params["tool"]?.stringValue,
                       "com.example.stamps.tool")
        h.app.ui.toolbar.unregister(owner: "com.example.stamps")
        runtime.syncKeyCommands()
        XCTAssertNil(h.app.content.keyCommands.get("toolbar.key.stamps.stamp"))

        // contracts-v2: a key works only in the kinds its item shows in, and a command item's `sessionParams` go with
        // its key (the shell passes `resolvedParams(for:)`).
        XCTAssertEqual(pen.docKinds, Set<DocumentKind>([.notebook, .whiteboard]))
        XCTAssertEqual(h.app.content.keyCommands.get("toolbar.key.writingTools")?.docKinds, ToolbarLayoutEngine.paletteKinds)
        var zoom = ToolbarItemDescriptor(
            id: "zoom.item", title: "Zoom Window", icon: "plus.magnifyingglass", group: .accessories, order: 60,
            owner: TestToolsFeature.id, command: "zoom.toggle", params: ["mode": "window"], shortcut: KeyShortcut("z"),
            docKinds: [.notebook])
        zoom.sessionParams = { s in ["session": .string(s.id.raw)] }
        h.app.ui.toolbar.register(zoom)
        runtime.syncKeyCommands()
        let key = try XCTUnwrap(h.app.content.keyCommands.get("toolbar.key.zoom.item"))
        XCTAssertEqual(key.docKinds, Set<DocumentKind>([.notebook]))
        XCTAssertEqual(key.resolvedParams(for: h.session),
                       JSONValue.object(["mode": "window", "session": .string(h.session.id.raw)]))
        XCTAssertNil(pen.sessionParams, "tool keys select the tool")
    }

    /// T-035 with contracts-v2: a non-sticky tool hands back by itself when it finishes one use
    /// (`CanvasHost.finishToolUse`); the palette never switches tools on a commit of its own, and remembers only
    /// sticky tools as the last tool of a document kind.
    func testNonStickyToolHandsBackThroughFinishToolUseAndLastToolIsRemembered() async throws {
        let h = harness()
        registerPinnableNote(h)
        let model = ToolbarModel(app: h.app, session: h.session)
        let host = FakeCanvasHost(h)
        h.session.tool = "eraser"
        try await waitUntil("the eraser is remembered") {
            h.app.settings.json("toolbar.lastTool.notebook")?.stringValue == "eraser"
        }

        // A commit is not the end of a use (the text tool goes on editing the box it placed).
        h.session.tool = "text"
        try await h.run("testtools.touch")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(h.session.tool, "text", "the palette leaves the hand-back to the tool")

        // The tool finishes its use: back to the previous tool, which stays the remembered one.
        host.finishToolUse(TestTool(id: "text", isSticky: model.isSticky("text")))
        XCTAssertEqual(h.session.tool, "eraser")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.app.settings.json("toolbar.lastTool.notebook")?.stringValue, "eraser",
                       "a non-sticky tool is never the remembered one")

        // A pinned tool is sticky: it stays after a use and is remembered.
        h.app.settings.setJSON("testtools.notePinned", true)
        h.session.tool = "note"
        let note = try XCTUnwrap(h.app.ui.canvasTools.get("note")).make()
        host.finishToolUse(note)
        XCTAssertEqual(h.session.tool, "note", "a pinned tool stays")
        try await waitUntil("the pinned tool is remembered") {
            h.app.settings.json("toolbar.lastTool.notebook")?.stringValue == "note"
        }

        // Another window opening a notebook starts with the remembered tool.
        let other = EditorSession()
        other.document = Fixtures.docID
        h.app.services.sessions.add(other)
        let otherModel = ToolbarModel(app: h.app, session: other)
        try await waitUntil("the new window restores the remembered tool") { other.tool == "note" }
        withExtendedLifetime([model, otherModel]) {}
    }

    /// T-109 and the options bar's sources.
    func testScrollingFoldsTheOptionsBarAndAToolBringsItBack() throws {
        let h = harness()
        let model = ToolbarModel(app: h.app, session: h.session)
        let pen = try XCTUnwrap(h.app.ui.toolbar.get("pen.item"))
        let eraser = try XCTUnwrap(h.app.ui.toolbar.get("eraser.item"))
        let text = try XCTUnwrap(h.app.ui.toolbar.get("text.item"))
        XCTAssertEqual(ActiveToolMenuHost.source(for: pen, app: h.app), .toolMenus)
        XCTAssertEqual(ActiveToolMenuHost.source(for: eraser, app: h.app), .descriptor)
        XCTAssertEqual(ActiveToolMenuHost.source(for: text, app: h.app), .absent)
        XCTAssertNotNil(model.toolOptions(for: "pen"))

        h.session.visibleRect = Rect(x: 0, y: 0, width: 400, height: 600)
        h.session.visibleRect = Rect(x: 0, y: 10, width: 400, height: 600)
        XCTAssertFalse(model.optionsCollapsed)
        h.session.visibleRect = Rect(x: 0, y: 40, width: 400, height: 600)
        XCTAssertTrue(model.optionsCollapsed)
        XCTAssertNil(model.toolOptions(for: "pen"))

        h.session.tool = "eraser"
        XCTAssertFalse(model.optionsCollapsed)
        XCTAssertNotNil(model.toolOptions(for: "eraser"))

        // A zoom changes the visible size: not a scroll.
        h.session.visibleRect = Rect(x: 0, y: 40, width: 200, height: 300)
        h.session.visibleRect = Rect(x: 50, y: 90, width: 100, height: 150)
        XCTAssertFalse(model.optionsCollapsed)

        // Acting on the writing tool (a quick ink) brings the folded bar back too.
        h.session.visibleRect = Rect(x: 50, y: 150, width: 100, height: 150)
        XCTAssertTrue(model.optionsCollapsed)
        model.selectSwatch(0)
        XCTAssertFalse(model.optionsCollapsed)
    }

    /// contracts-v2: the palette is a SwiftUI screen the chrome places inside its own droplet container; there is no
    /// UIKit layer with a second container and a touch pass-through any more.
    func testThePaletteIsASwiftUIScreenForTheChromesContainer() {
        let h = harness()
        XCTAssertNotNil(h.app.ui.screens.toolbarView)
        XCTAssertNil(h.app.ui.screens.toolbar, "the superseded UIView slot stays empty")
        XCTAssertNotNil(h.app.ui.screens.toolbarView?(h.session, h.app))
    }

    /// contracts-v2: a tool menu's own popover (`ToolMenuDescriptor.makePopover`) reaches the palette with the options
    /// bar; the palette's own popovers (the tool's settings, More) and folding the bar close it: one at a time.
    func testTheOptionsBarsPopoverReachesThePalette() throws {
        let h = harness()
        let thickness = PopoverFlag()
        var menu = ToolMenuDescriptor(tool: "pen", owner: TestToolsFeature.id) { _ in AnyView(EmptyView()) }
        menu.makePopover = { _ in
            ToolMenuPopover(source: "pen.thickness", isPresented: thickness.binding, title: "Thickness",
                            subtitle: "0.50 mm") { EmptyView() }
        }
        h.app.ui.toolMenus.register(menu)
        let model = ToolbarModel(app: h.app, session: h.session)
        let options = try XCTUnwrap(model.toolOptions(for: "pen"))
        let popover = try XCTUnwrap(options.popover)
        XCTAssertEqual(popover.source, "pen.thickness")
        XCTAssertEqual(popover.title, "Thickness")
        XCTAssertEqual(popover.subtitle, "0.50 mm")
        popover.isPresented.wrappedValue = true
        XCTAssertTrue(thickness.isOpen, "the palette drives the menu's own state")
        XCTAssertNotNil(model.toolOptions(for: "eraser"))
        XCTAssertNil(model.toolOptions(for: "eraser")?.popover, "an item's own activeToolMenu has no popover")

        model.openSettings()
        XCTAssertTrue(model.settingsOpen)
        XCTAssertFalse(thickness.isOpen, "the settings popover closes it")
        model.settingsOpen = false
        thickness.isOpen = true
        model.moreOpen = true
        XCTAssertFalse(thickness.isOpen, "More closes it")
        model.moreOpen = false

        thickness.isOpen = true
        h.session.visibleRect = Rect(x: 0, y: 0, width: 400, height: 600)
        h.session.visibleRect = Rect(x: 0, y: 40, width: 400, height: 600)
        XCTAssertTrue(model.optionsCollapsed)
        XCTAssertFalse(thickness.isOpen, "folding the bar closes it")
        XCTAssertNil(model.toolOptions(for: "pen"))
    }

    /// contracts-v2 live state: the palette shows each item's title, icon, on and enabled state for this window,
    /// re-reads them on commits and `setNeedsChromeUpdate`, taps run the item's command with the window's
    /// `sessionParams`, a disabled item runs nothing, and a regular-width-only item stays off the iPhone palette.
    func testItemsFollowTheirLiveState() async throws {
        let h = harness()
        let log = DockLog()
        h.app.services.set(log, for: DockLog.key)
        h.app.commands.register(TestDockSpy.self)
        let flags = LiveFlags()
        var zoom = ToolbarItemDescriptor(
            id: "zoom.item", title: "Zoom Window", icon: "plus.magnifyingglass", group: .accessories, order: 60,
            owner: TestToolsFeature.id, command: TestDockSpy.descriptor.id, params: ["command": "zoom.toggle"])
        zoom.isOn = { _ in flags.on }
        zoom.isEnabled = { _ in flags.enabled }
        zoom.sessionTitle = { _ in flags.on ? "Close Zoom Window" : "Zoom Window" }
        zoom.sessionIcon = { _ in flags.on ? "plus.magnifyingglass.circle.fill" : "plus.magnifyingglass" }
        zoom.sessionParams = { s in ["params": ["session": .string(s.id.raw)]] }
        zoom.showsInCompactWidth = false
        h.app.ui.toolbar.register(zoom)

        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertTrue(model.hasLiveState)
        func item() -> PaletteItem? { model.more.first { $0.id == "zoom.item" } }
        XCTAssertEqual(item()?.title, "Zoom Window")
        XCTAssertNil(item()?.value)
        XCTAssertTrue(model.items(compact: false).more.contains { $0.id == "zoom.item" })
        XCTAssertFalse(model.items(compact: true).more.contains { $0.id == "zoom.item" }, "regular widths only")

        model.select("zoom.item")
        try await waitUntil("the tap runs the command with the window's params") { log.calls.count == 1 }
        XCTAssertEqual(log.calls.first, JSONValue.object(["session": .string(h.session.id.raw)]))

        flags.on = true
        h.app.ui.setNeedsChromeUpdate(h.session)
        try await waitUntil("setNeedsChromeUpdate re-reads the state") { item()?.title == "Close Zoom Window" }
        XCTAssertEqual(item()?.icon, "plus.magnifyingglass.circle.fill")
        XCTAssertEqual(item()?.value, "On")

        flags.on = false
        flags.enabled = false
        try await h.run("testtools.touch")
        try await waitUntil("a commit re-reads the state") { item()?.isEnabled == false }
        XCTAssertEqual(item()?.value, "Unavailable")
        XCTAssertEqual(item()?.title, "Zoom Window")
        model.select("zoom.item")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(log.calls.count, 1, "a disabled item runs nothing")
    }

    /// contracts-v2: the palette follows Settings › Appearance › Liquid (`NibSettings.liquidMode`).
    func testThePaletteFollowsTheLiquidSetting() async throws {
        let h = harness()
        let model = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(model.liquidMode, .full)
        h.app.settings.set(NibSettings.liquidMode, "calm")
        try await waitUntil("the palette goes calm") { model.liquidMode == .calm }
        h.app.settings.set(NibSettings.liquidMode, "off")
        try await waitUntil("and off") { model.liquidMode == .off }
        h.app.settings.set(NibSettings.liquidMode, "wobbly")
        try await waitUntil("an unknown value is full") { model.liquidMode == .full }
    }
}

/// An options-bar popover's presentation, owned by the tool menu (as F008 owns its thickness popover).
final class PopoverFlag {
    var isOpen = false
    var binding: Binding<Bool> { Binding(get: { self.isOpen }, set: { self.isOpen = $0 }) }
}

private struct ToolbarFieldProbe: View {
    @Environment(DropletField.self) private var field: DropletField?
    let capture: (DropletField?) -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear { capture(field) }
    }
}

/// A toolbar item's live state, owned by the feature that registers it.
final class LiveFlags {
    var on = false
    var enabled = true
}
