import XCTest
import SwiftUI
import NibContracts
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

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatToolbarFeature.self])
        XCTAssertEqual(problems, [])
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

    /// The dock is stored per device and read back; iPhone docks horizontally only.
    func testDockPersistsAndCompactIgnoresVerticalEdges() async throws {
        let h = harness()
        let model = ToolbarModel(app: h.app, session: h.session)
        let landscape = CGSize(width: 1180, height: 820)
        let phone = CGSize(width: 390, height: 844)
        var dock = model.dock(for: landscape, compact: false)
        XCTAssertEqual(dock.edge.rawValue, "leading")
        XCTAssertEqual(model.dock(for: CGSize(width: 820, height: 1180), compact: false).edge.rawValue, "top")
        XCTAssertEqual(model.dock(for: phone, compact: true).edge.rawValue, "bottom")

        dock.edge = .trailing
        dock.along = 0.25
        model.setDock(dock)
        try await waitUntil("the dock is stored") {
            h.app.settings.json(ToolbarSettings.dock.name)?["edge"]?.stringValue == "trailing"
        }
        let fresh = ToolbarModel(app: h.app, session: h.session)
        XCTAssertEqual(fresh.dock(for: landscape, compact: false), dock)
        XCTAssertEqual(fresh.dock(for: phone, compact: true).edge.rawValue, "bottom", "a side dock does not apply on iPhone")
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

    /// Stickiness is asked afresh: a tool may read it from a setting (F026's pinned text tool).
    func testStickinessIsReadEveryTime() throws {
        let h = harness()
        let settings = h.app.settings
        h.app.ui.canvasTools.register(CanvasToolDescriptor(id: "note", title: "note", owner: TestToolsFeature.id) {
            TestTool(id: "note", isSticky: settings.json("testtools.notePinned")?.boolValue ?? false)
        })
        let runtime = try XCTUnwrap(h.app.services.get(ToolbarRuntime.serviceKey, as: ToolbarRuntime.self))
        XCTAssertFalse(runtime.isSticky("note"))
        settings.setJSON("testtools.notePinned", true)
        XCTAssertTrue(runtime.isSticky("note"))
        XCTAssertTrue(runtime.isSticky("unknown"), "an unknown tool counts as sticky")
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

        h.app.ui.toolbar.register(ToolbarItemDescriptor(
            id: "stamps.stamp", title: "Stamp", icon: "seal", group: .tools, order: 50, owner: "com.example.stamps",
            toolID: "com.example.stamps.tool", shortcut: KeyShortcut("k")))
        runtime.syncKeyCommands()
        XCTAssertEqual(h.app.content.keyCommands.get("toolbar.key.stamps.stamp")?.params["tool"]?.stringValue,
                       "com.example.stamps.tool")
        h.app.ui.toolbar.unregister(owner: "com.example.stamps")
        runtime.syncKeyCommands()
        XCTAssertNil(h.app.content.keyCommands.get("toolbar.key.stamps.stamp"))
    }

    func testNonStickyToolHandsBackAndLastToolIsRemembered() async throws {
        let h = harness()
        let model = ToolbarModel(app: h.app, session: h.session)
        h.session.tool = "eraser"
        try await waitUntil("the eraser is remembered") {
            h.app.settings.json("toolbar.lastTool.notebook")?.stringValue == "eraser"
        }

        h.session.tool = "text"
        try await h.run("testtools.touch")
        try await waitUntil("the text tool hands back") { h.session.tool == "eraser" }
        XCTAssertEqual(h.app.settings.json("toolbar.lastTool.notebook")?.stringValue, "eraser",
                       "a non-sticky tool is never the remembered one")

        h.app.settings.setJSON(ToolbarSettings.textPinned, true)
        h.session.tool = "text"
        try await h.run("testtools.touch")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.session.tool, "text", "a pinned text tool stays")

        // Another window opening a notebook starts with the remembered tool.
        let other = EditorSession()
        other.document = Fixtures.docID
        h.app.services.sessions.add(other)
        let otherModel = ToolbarModel(app: h.app, session: other)
        try await waitUntil("the new window restores the eraser") { other.tool == "eraser" }
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
        XCTAssertNotNil(model.options(for: "pen"))

        h.session.visibleRect = Rect(x: 0, y: 0, width: 400, height: 600)
        h.session.visibleRect = Rect(x: 0, y: 10, width: 400, height: 600)
        XCTAssertFalse(model.optionsCollapsed)
        h.session.visibleRect = Rect(x: 0, y: 40, width: 400, height: 600)
        XCTAssertTrue(model.optionsCollapsed)
        XCTAssertNil(model.options(for: "pen"))

        h.session.tool = "eraser"
        XCTAssertFalse(model.optionsCollapsed)
        XCTAssertNotNil(model.options(for: "eraser"))

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
}
