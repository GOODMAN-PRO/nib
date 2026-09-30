import XCTest
import UIKit
import NibContracts
import NibTesting
import NibDesign
@testable import FeatKeyboard

/// A document editor stand-in so `session.editor?.canvasHost` finds the fake canvas (its zoom).
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

/// Records the params stand-in commands receive.
@MainActor
private final class Recorder {
    var calls: [(command: String, params: JSONValue)] = []

    func params(_ command: String) -> [JSONValue] { calls.filter { $0.command == command }.map { $0.params } }
}

/// A custom control, as a feature would build one in UIKit.
private final class TestControl: UIControl {}

/// Stands in for the object menu feature's own right-click menu on the canvas.
@MainActor
private final class MenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? { nil }
}

@MainActor
final class FeatKeyboardTests: XCTestCase {
    private let doc = Fixtures.docID

    private func started(_ features: [NibFeature.Type] = [FeatKeyboardFeature.self]) async -> Harness {
        let h = Harness(features: features)
        await FeatKeyboardFeature.start(h.app)
        return h
    }

    private func runtime(_ h: Harness) throws -> KeyboardRuntime {
        try XCTUnwrap(h.app.services.get(KeyboardRuntime.serviceKey, as: KeyboardRuntime.self))
    }

    private func key(_ h: Harness, _ name: String) throws -> KeyCommandDescriptor {
        try XCTUnwrap(h.app.content.keyCommands.get("keyboard." + name), "keyboard.\(name) is not registered")
    }

    private func ids(_ h: Harness) -> Set<String> { Set(h.app.content.keyCommands.all.map { $0.id }) }

    private func stand(in h: Harness, for commands: [String]) -> Recorder {
        let recorder = Recorder()
        for id in commands {
            h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", effect: .session,
                                                      target: .app, exposure: .ui)) { json, _ in
                recorder.calls.append((id, json))
                return .null
            }
        }
        return recorder
    }

    /// Runs a key command exactly as the app shell does today: the command with the static params, in the window.
    private func press(_ h: Harness, _ name: String) async throws {
        let d = try key(h, name)
        _ = try await h.app.bus.execute(Invocation(command: d.command, params: d.params, session: h.session))
    }

    private func descriptor(_ id: String, _ key: String, _ modifiers: KeyModifiers = [], scope: KeyScope,
                            kinds: Set<DocumentKind>? = nil, owner: String, command: String = "test.run") -> KeyCommandDescriptor {
        var d = KeyCommandDescriptor(id: id, title: id, shortcut: KeyShortcut(key, modifiers), command: command,
                                     scope: scope, owner: owner)
        d.docKinds = kinds
        return d
    }

    // MARK: Acceptance: no shortcut is registered twice

    func testNoShortcutIsRegisteredTwice() async throws {
        let catalog = GlobalShortcuts.catalog(app: nil, owner: FeatKeyboardFeature.id)
        XCTAssertTrue(ShortcutRules.conflicts(in: catalog).isEmpty, "\(ShortcutRules.conflicts(in: catalog))")
        XCTAssertEqual(Set(catalog.map { $0.id }).count, catalog.count)

        let h = await started()
        let all = h.app.content.keyCommands.all
        XCTAssertTrue(ShortcutRules.conflicts(in: all).isEmpty, "\(ShortcutRules.conflicts(in: all))")
        XCTAssertEqual(ids(h), Set(catalog.map { $0.id }), "alone, every shortcut of the feature is registered")
        for d in all {
            XCTAssertEqual(d.owner, FeatKeyboardFeature.id)
            XCTAssertTrue(d.title.isEmpty == (d.id == "keyboard.zoomInEquals"), "\(d.id) needs a discoverability title")
            XCTAssertFalse(ShortcutRules.isSingleKey(d.shortcut), "\(d.id) must not be switched off with single keys")
        }
    }

    func testTheShortcutsMapToTheirCommands() async throws {
        let h = await started()
        func check(_ name: String, _ key: String, _ modifiers: KeyModifiers, _ command: String, scope: KeyScope,
                   _ params: JSONValue? = nil, line: UInt = #line) throws {
            let d = try self.key(h, name)
            XCTAssertEqual(d.shortcut, KeyShortcut(key, modifiers), name, line: line)
            XCTAssertEqual(d.command, command, name, line: line)
            XCTAssertEqual(d.scope, scope, name, line: line)
            if let params { XCTAssertEqual(d.params, params, name, line: line) }
        }
        try check("newWindow", "n", .command, "window.open", scope: .global, [:])
        try check("newNotebook", "n", [.command, .option], "app.openURL", scope: .global, ["url": "nib://new?kind=notebook"])
        try check("quickNote", "n", [.command, .shift], "doc.quickNote", scope: .global, [:])
        try check("newTextDocument", "t", [.command, .shift], "app.openURL", scope: .global,
                  ["url": "nib://new?kind=textDocument"])
        try check("open", "o", .command, "search.open", scope: .global, ["scope": "library"])
        try check("searchLibrary", "f", .command, "search.open", scope: .library, ["scope": "library"])
        try check("rename", "r", .command, "panel.open", scope: .document, ["id": "keyboard.rename"])
        try check("export", "e", [.command, .shift], "export.present", scope: .document)
        try check("print", "p", .command, "print.present", scope: .document)
        try check("share", "s", [.command, .shift], "export.present", scope: .document)
        try check("find", "f", .command, "search.open", scope: .document, ["scope": "document"])
        try check("findNext", "g", .command, "search.step", scope: .document, ["direction": "next"])
        try check("findPrevious", "g", [.command, .shift], "search.step", scope: .document, ["direction": "previous"])
        try check("goToPage", "g", [.command, .option], "commands.batch", scope: .document)
        try check("zoomIn", "+", .command, "commands.batch", scope: .document)
        try check("zoomOut", "-", .command, "commands.batch", scope: .document)
        try check("zoomToFit", "0", .command, "commands.batch", scope: .document)
        try check("actualSize", "0", [.command, .option], "commands.batch", scope: .document)
        try check("sidebar", "s", [.command, .control], "sidebar.toggle", scope: .document, [:])
        for n in 1...9 {
            try check("tab\(n)", String(n), .command, "tab.select", scope: .document,
                      ["index": .number(Double(n == 9 ? -1 : n - 1))])
        }
        try check("deselect", "escape", [], "commands.batch", scope: .canvas)
        try check("delete", "delete", [], "commands.batch", scope: .canvas)
        try check("selectAll", "a", .command, "commands.batch", scope: .canvas)
        XCTAssertFalse(h.app.content.keyCommands.all.contains { $0.shortcut == KeyShortcut("w", [.command, .shift]) },
                       "⇧⌘W is New Whiteboard's (F044)")
        XCTAssertEqual(try key(h, "zoomIn").docKinds, [.notebook, .whiteboard])
        XCTAssertEqual(try key(h, "delete").docKinds, [.notebook, .whiteboard])
        XCTAssertNil(try key(h, "find").docKinds)
    }

    func testOtherOwnersKeepTheirKeysAndNothingIsDuplicated() async throws {
        let h = Harness(features: [])
        let registry = h.app.content.keyCommands
        let canvas: Set<DocumentKind> = [.notebook, .whiteboard]
        // What the document chrome, the object menu, the page manager and the text editor register themselves.
        registry.register(descriptor("chrome.sidebar", "s", [.control, .command], scope: .document, owner: "chrome"))
        registry.register(descriptor("objectmenu.key.delete", "delete", scope: .canvas, kinds: canvas, owner: "objectmenu"))
        registry.register(descriptor("pages.goToPage", "g", [.command, .option], scope: .document, owner: "pages"))
        registry.register(descriptor("textdocedit.selectAll", "A", .command, scope: .canvas, kinds: [.textDocument],
                                     owner: "textdocedit"))
        h.app.register([FeatKeyboardFeature.self])
        await FeatKeyboardFeature.start(h.app)

        let all = registry.all
        XCTAssertTrue(ShortcutRules.conflicts(in: all).isEmpty, "\(ShortcutRules.conflicts(in: all))")
        for kept in ["chrome.sidebar", "objectmenu.key.delete", "pages.goToPage", "textdocedit.selectAll"] {
            XCTAssertNotNil(registry.get(kept), kept)
        }
        XCTAssertNil(registry.get("keyboard.sidebar"))
        XCTAssertNil(registry.get("keyboard.delete"))
        XCTAssertNil(registry.get("keyboard.goToPage"))
        XCTAssertNotNil(registry.get("keyboard.selectAll"), "a text-document ⌘A never fires on a page canvas")
        XCTAssertEqual(try runtime(h).yielded, ["keyboard.sidebar", "keyboard.delete", "keyboard.goToPage"])
    }

    func testArbitrationFollowsOwnersThatComeAndGo() async throws {
        let h = await started()
        let registry = h.app.content.keyCommands
        registry.register(descriptor("dev.plugin.print", "P", .command, scope: .global, owner: "dev.plugin"))
        XCTAssertNil(registry.get("keyboard.print"), "a plugin that maps ⌘P keeps it")
        XCTAssertTrue(ShortcutRules.conflicts(in: registry.all).isEmpty)

        registry.register(descriptor("dev.plugin.other", "p", [.command, .option, .shift], scope: .global, owner: "dev.plugin"))
        registry.unregister(owner: "dev.plugin")
        XCTAssertNotNil(registry.get("keyboard.print"), "⌘P comes back when the plugin goes")
        XCTAssertTrue(try runtime(h).yielded.isEmpty)
    }

    func testClashesBetweenOtherOwnersAreSettled() async throws {
        let h = Harness(features: [])
        let registry = h.app.content.keyCommands
        h.app.commands.register(CommandDescriptor(id: "pencil.palette", title: "Palette", summary: "Test stand-in.",
                                                  effect: .session, target: .app, exposure: .ui, owner: "pencilhw")) { _, _ in .null }
        // The Pencil feature maps ⌥⌘P to its own command; audio maps the same keys to a command it does not own here.
        registry.register(descriptor("pencilhw.palette", "p", [.command, .option], scope: .document, owner: "pencilhw",
                                     command: "pencil.palette"))
        var audio = descriptor("audio.key.play", "p", [.command, .option], scope: .document, owner: "audio",
                               command: "audio.play")
        audio.order = -5
        registry.register(audio)
        h.app.register([FeatKeyboardFeature.self])
        await FeatKeyboardFeature.start(h.app)
        let rt = try runtime(h)

        XCTAssertNotNil(registry.get("pencilhw.palette"), "a key for the owner's own command wins")
        XCTAssertNil(registry.get("audio.key.play"))
        XCTAssertEqual(rt.shadowedDescriptors.map { $0.id }, ["audio.key.play"])
        XCTAssertTrue(ShortcutRules.conflicts(in: registry.all).isEmpty)
        let list = ShortcutDirectory.sections(active: registry.all, taken: rt.shadowedDescriptors, query: "")
        XCTAssertEqual(list.flatMap { $0.entries }.first { $0.id == "audio.key.play" }?.status, .keysTaken)

        registry.unregister(id: "pencilhw.palette")
        XCTAssertNotNil(registry.get("audio.key.play"), "the keys are free again")
        XCTAssertTrue(rt.shadowedDescriptors.isEmpty)
    }

    func testShadowingRanksOwnersThenOrderThenID() {
        var early = descriptor("b.early", "k", .command, scope: .document, owner: "b")
        early.order = 1
        var late = descriptor("a.late", "k", .command, scope: .document, owner: "a")
        late.order = 2
        let owner = descriptor("c.owner", "K", .command, scope: .canvas, kinds: [.notebook], owner: "c")
        let elsewhere = descriptor("d.library", "k", .command, scope: .library, owner: "d")
        let plan = ShortcutArbiter.shadowing(registered: [late, early, elsewhere], shadowed: [owner],
                                             ownsCommand: { $0.owner == "c" })
        XCTAssertEqual(plan, ShadowPlan(shadow: ["b.early", "a.late"], restore: ["c.owner"]))
        let withoutOwner = ShortcutArbiter.shadowing(registered: [late, early, elsewhere], shadowed: [],
                                                     ownsCommand: { _ in false })
        XCTAssertEqual(withoutOwner, ShadowPlan(shadow: ["a.late"], restore: []))
    }

    // MARK: Single-key shortcuts can be switched off (P-054)

    func testSingleKeySwitchWithholdsAndRestoresEveryOwnersSingleKeys() async throws {
        let h = Harness(features: [])
        let registry = h.app.content.keyCommands
        let tools = ["p", "e", "["]
        for k in tools { registry.register(descriptor("toolbar.key." + k, k, scope: .canvas, owner: "toolbar")) }
        registry.register(descriptor("toolbar.key.nextPen", "p", .shift, scope: .canvas, owner: "toolbar"))
        registry.register(descriptor("pencilhw.palette", "p", [.command, .option], scope: .document, owner: "pencilhw"))
        h.app.register([FeatKeyboardFeature.self])
        await FeatKeyboardFeature.start(h.app)
        let rt = try runtime(h)
        XCTAssertEqual(h.app.settings.descriptor(KeyboardSettings.singleKeyShortcuts.name)?.synced, false)

        try await h.run(CommandIDs.settingsSet, ["name": .string(KeyboardSettings.singleKeyShortcuts.name), "value": false])
        for id in ["toolbar.key.p", "toolbar.key.e", "toolbar.key.[", "toolbar.key.nextPen"] {
            XCTAssertNil(registry.get(id), "\(id) is off")
        }
        XCTAssertNotNil(registry.get("pencilhw.palette"), "shortcuts with ⌘, ⌥ or ⌃ stay")
        XCTAssertNotNil(registry.get("keyboard.delete"), "Delete and Escape are not single-key shortcuts")
        XCTAssertNotNil(registry.get("keyboard.deselect"))

        // Registered while off: withheld at once. Dropped by its owner while off: forgotten.
        registry.register(descriptor("toolbar.key.h", "h", scope: .canvas, owner: "toolbar"))
        XCTAssertNil(registry.get("toolbar.key.h"))
        registry.unregister(id: "toolbar.key.e")
        XCTAssertEqual(Set(rt.withheldDescriptors.map { $0.id }),
                       ["toolbar.key.p", "toolbar.key.[", "toolbar.key.nextPen", "toolbar.key.h"])

        try await h.run(CommandIDs.settingsSet, ["name": .string(KeyboardSettings.singleKeyShortcuts.name), "value": true])
        for id in ["toolbar.key.p", "toolbar.key.[", "toolbar.key.nextPen", "toolbar.key.h"] {
            XCTAssertNotNil(registry.get(id), "\(id) is back")
        }
        XCTAssertNil(registry.get("toolbar.key.e"))
        XCTAssertTrue(rt.withheldDescriptors.isEmpty)
        XCTAssertTrue(ShortcutRules.conflicts(in: registry.all).isEmpty)
    }

    func testSingleKeyAndSituationRules() {
        XCTAssertTrue(ShortcutRules.isSingleKey(KeyShortcut("p")))
        XCTAssertTrue(ShortcutRules.isSingleKey(KeyShortcut("P", .shift)))
        XCTAssertTrue(ShortcutRules.isSingleKey(KeyShortcut("]")))
        XCTAssertFalse(ShortcutRules.isSingleKey(KeyShortcut("p", .command)))
        XCTAssertFalse(ShortcutRules.isSingleKey(KeyShortcut("escape")))
        XCTAssertFalse(ShortcutRules.isSingleKey(KeyShortcut("up")))

        let libraryF = descriptor("a", "f", .command, scope: .library, owner: "x")
        let documentF = descriptor("b", "F", .command, scope: .document, owner: "y")
        let canvasA = descriptor("c", "a", .command, scope: .canvas, kinds: [.notebook], owner: "x")
        let textA = descriptor("d", "a", .command, scope: .document, kinds: [.textDocument], owner: "y")
        let notebookA = descriptor("e", "a", .command, scope: .document, kinds: [.notebook], owner: "y")
        let globalKinds = descriptor("f", "f", .command, scope: .global, kinds: [.notebook], owner: "y")
        XCTAssertFalse(ShortcutRules.overlap(libraryF, documentF), "the library and a document never show together")
        XCTAssertFalse(ShortcutRules.overlap(canvasA, textA))
        XCTAssertTrue(ShortcutRules.overlap(canvasA, notebookA), "a document key also fires on the page")
        XCTAssertFalse(ShortcutRules.overlap(libraryF, globalKinds), "a key limited to notebooks never fires in the library")
        XCTAssertTrue(ShortcutRules.overlap(documentF, globalKinds))
        XCTAssertEqual(ShortcutRules.situations(of: canvasA), [.document(.notebook, editingText: false)])
        XCTAssertEqual(ShortcutRules.conflicts(in: [libraryF, documentF, globalKinds]).map { "\($0.0)|\($0.1)" }, ["b|f"])
    }

    // MARK: Shortcuts that read the window

    func testSessionShortcutsResolveTheWindowThroughTheHook() async throws {
        let h = await started()
        let recorder = stand(in: h, for: ["item.delete", "selection.clear", "selection.selectAll", "view.zoom",
                                          "export.present", "print.present", "panel.open"])
        let stroke = NodeRef.item(doc, Fixtures.page1, Fixtures.strokeID).description
        let page = NodeRef.page(doc, Fixtures.page1).description
        h.session.selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID])

        try await press(h, "delete")
        XCTAssertEqual(recorder.params("item.delete"), [["refs": [.string(stroke)]]])
        try await press(h, "deselect")
        XCTAssertEqual(recorder.params("selection.clear").count, 1)
        try await press(h, "selectAll")
        XCTAssertEqual(recorder.params("selection.selectAll"), [["page": .string(page)]])
        try await press(h, "export")
        XCTAssertEqual(recorder.params("export.present").last, ["docs": ["doc:FIXTUREDOC01"]])
        try await press(h, "share")
        XCTAssertEqual(recorder.params("export.present").last, ["docs": ["doc:FIXTUREDOC01"], "pages": [.string(page)]])
        try await press(h, "print")
        XCTAssertEqual(recorder.params("print.present"), [["doc": "doc:FIXTUREDOC01"]])
        try await press(h, "goToPage")
        XCTAssertEqual(recorder.params("panel.open"), [["id": "keyboard.goToPage"]])
        try await press(h, "zoomToFit")
        try await press(h, "actualSize")
        XCTAssertEqual(recorder.params("view.zoom"), [["fit": true], ["actual": true]])

        // Once the shell passes resolvedParams(for:), the same keys resolve the same way (the marker is dropped).
        recorder.calls.removeAll()
        let print = try key(h, "print")
        let resolved = print.resolvedParams(for: h.session)
        _ = try await h.app.bus.execute(Invocation(command: print.command, params: resolved, session: h.session))
        XCTAssertEqual(recorder.params("print.present"), [["doc": "doc:FIXTUREDOC01"]])
        XCTAssertNil(recorder.params("print.present").first?[GlobalShortcuts.marker])
    }

    func testZoomKeysStepFromTheCanvasZoom() async throws {
        let h = await started()
        let recorder = stand(in: h, for: ["view.zoom"])
        h.session.zoom = 1
        try await press(h, "zoomIn")
        try await press(h, "zoomInEquals")
        try await press(h, "zoomOut")
        let host = FakeCanvasHost(h)
        host.zoomScale = 2
        let editor = FakeEditor(host)
        h.session.editor = editor
        try await press(h, "zoomIn")
        XCTAssertEqual(recorder.params("view.zoom"), [["scale": 1.25], ["scale": 1.25], ["scale": 0.75], ["scale": 3]])
        withExtendedLifetime(editor) {}
    }

    func testPageKeysDoNothingWhereTheyDoNotApply() async throws {
        let h = await started()
        let recorder = stand(in: h, for: ["item.delete", "selection.clear", "selection.selectAll", "view.zoom", "panel.open"])
        // Nothing selected.
        try await press(h, "delete")
        try await press(h, "deselect")
        // Read only.
        h.session.selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID])
        h.session.readOnly = true
        try await press(h, "delete")
        // A text document has no page canvas.
        h.session.readOnly = false
        h.session.document = Fixtures.textDocID
        h.session.page = nil
        h.session.selection = Selection()
        for name in ["delete", "deselect", "selectAll", "zoomIn", "zoomOut", "zoomToFit", "actualSize", "goToPage"] {
            try await press(h, name)
        }
        XCTAssertTrue(recorder.calls.isEmpty, "\(recorder.calls)")
    }

    func testShortcutContextAndActions() {
        let c = ShortcutContext(doc: doc, kind: .whiteboard, page: Fixtures.boardID, selection: ["item:A/B/C"], zoom: 0.9)
        XCTAssertTrue(c.isCanvas)
        XCTAssertEqual(ShortcutActions.zoomStep(c, zoomIn: true),
                       ["calls": [["command": "view.zoom", "params": ["scale": 1]]]])
        XCTAssertEqual(ShortcutActions.deleteSelection(c),
                       ["calls": [["command": "item.delete", "params": ["refs": ["item:A/B/C"]]]]])
        let text = ShortcutContext(doc: Fixtures.textDocID, kind: .textDocument, page: nil)
        XCTAssertEqual(ShortcutActions.sharePage(text), ["docs": ["doc:FIXTUREDOC02"]])
        XCTAssertEqual(ShortcutActions.selectAll(text), ShortcutActions.nothing)
        XCTAssertEqual(ShortcutActions.exportDocument(ShortcutContext()), [:])
        XCTAssertNil(GlobalShortcuts.resolveMarker(["docs": []], byID: [:], session: nil), "calls without the marker pass untouched")
        XCTAssertEqual(GlobalShortcuts.resolveMarker(["a": 1, GlobalShortcuts.marker: "keyboard.gone"], byID: [:], session: nil),
                       ["a": 1])
    }

    // MARK: Zoom and pointer math

    func testZoomLadderAndScrollZoom() {
        XCTAssertEqual(ZoomLadder.step(from: 1, zoomIn: true), 1.25)
        XCTAssertEqual(ZoomLadder.step(from: 1.25, zoomIn: false), 1)
        XCTAssertEqual(ZoomLadder.step(from: 0.9, zoomIn: true), 1)
        XCTAssertEqual(ZoomLadder.step(from: 0.9, zoomIn: false), 0.75)
        XCTAssertEqual(ZoomLadder.step(from: 8, zoomIn: true), 8)
        XCTAssertEqual(ZoomLadder.step(from: 0.05, zoomIn: false), 0.05)
        XCTAssertEqual(ZoomLadder.step(from: .nan, zoomIn: true), 1.25)

        XCTAssertEqual(ScrollZoom.factor(forScroll: 0), 1)
        XCTAssertEqual(ScrollZoom.factor(forScroll: ScrollZoom.pointsPerDoubling), 2, accuracy: 1e-9)
        XCTAssertEqual(ScrollZoom.target(base: 1, scroll: -ScrollZoom.pointsPerDoubling), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ScrollZoom.target(base: 6, scroll: 10_000), ScrollZoom.maxScale)
        XCTAssertEqual(ScrollZoom.target(base: 0.1, scroll: -10_000), ScrollZoom.minScale)
        let c = ScrollZoom.anchorCorrection(anchor: CGPoint(x: 300, y: 500), contentOffset: CGPoint(x: 100, y: 200),
                                            pointer: CGPoint(x: 150, y: 250), zoom: 2)
        XCTAssertEqual(c.dx, 25, accuracy: 1e-9)
        XCTAssertEqual(c.dy, 25, accuracy: 1e-9)
    }

    func testRightClickOpensThePageMenuUnlessTheCanvasHasItsOwn() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        XCTAssertEqual(RightClick.menuParams(host: host, location: CGPoint(x: 100, y: 150)),
                       ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [100, 150]])
        let secondPageTop = host.pageFrame(Fixtures.page2)?.minY ?? 0
        XCTAssertEqual(RightClick.menuParams(host: host, location: CGPoint(x: 40, y: secondPageTop + 10)),
                       ["page": "page:FIXTUREDOC01/FIXTUREPG002", "point": [40, 10]])
        XCTAssertNil(RightClick.menuParams(host: host, location: CGPoint(x: 5_000, y: 5)))

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400))
        container.addSubview(host.canvasView)
        XCTAssertFalse(RightClick.hasOwnContextMenu(in: host.canvasView, at: CGPoint(x: 10, y: 10)))
        let delegate = MenuDelegate()
        host.canvasView.addInteraction(UIContextMenuInteraction(delegate: delegate))
        XCTAssertTrue(RightClick.hasOwnContextMenu(in: host.canvasView, at: CGPoint(x: 10, y: 10)))

        let attachment = PointerCanvasAttachment()
        let before = host.canvasView.gestureRecognizers?.count ?? 0
        attachment.attach(to: host)
        let added = (host.canvasView.gestureRecognizers ?? []).dropFirst(before)
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added.compactMap { $0 as? UITapGestureRecognizer }.first?.buttonMaskRequired,
                       UIEvent.ButtonMask.secondary)
        XCTAssertEqual(added.compactMap { $0 as? UIPanGestureRecognizer }.first?.allowedTouchTypes, [])
        attachment.detach(from: host)
        XCTAssertEqual(host.canvasView.gestureRecognizers?.count ?? 0, before)
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(PointerSupport.attachmentID))
    }

    func testHoverEffectsReachUIKitControlsOnce() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let control = TestControl(frame: CGRect(x: 60, y: 0, width: 200, height: 44))
        let bar = UINavigationBar(frame: CGRect(x: 0, y: 100, width: 600, height: 44))
        let barButton = UIButton(type: .system)
        bar.addSubview(barButton)
        for v in [button, control, bar] as [UIView] { root.addSubview(v) }
        let buttonWasEnabled = button.isPointerInteractionEnabled
        let barButtonWasEnabled = barButton.isPointerInteractionEnabled

        XCTAssertEqual(HoverEffects.install(in: root), (buttonWasEnabled ? 0 : 1) + 1)
        XCTAssertTrue(button.isPointerInteractionEnabled)
        XCTAssertTrue(HoverEffects.hasPointerInteraction(control))
        XCTAssertEqual(barButton.isPointerInteractionEnabled, barButtonWasEnabled, "system bars hover by themselves")
        XCTAssertEqual(HoverEffects.install(in: root), 0, "a second pass changes nothing")

        let toggle = UISwitch()
        let interactions = toggle.interactions.count
        HoverEffects.install(in: toggle)
        XCTAssertEqual(toggle.interactions.count, interactions, "UIKit's own controls already hover")

        XCTAssertEqual(PointerShapes.cornerRadius(for: CGSize(width: 44, height: 44), layerRadius: 0), 22)
        XCTAssertEqual(PointerShapes.cornerRadius(for: CGSize(width: 200, height: 44), layerRadius: 0), 22)
        XCTAssertEqual(PointerShapes.cornerRadius(for: CGSize(width: 300, height: 200), layerRadius: 0), NibRadius.field)
        XCTAssertEqual(PointerShapes.cornerRadius(for: CGSize(width: 40, height: 40), layerRadius: 8), 8)
    }

    // MARK: Discoverability, settings and sheets (P-057)

    func testShortcutTextAndTheSearchableList() async throws {
        XCTAssertEqual(ShortcutFormatter.display(KeyShortcut("n", [.command, .option])), "⌥⌘N")
        XCTAssertEqual(ShortcutFormatter.display(KeyShortcut("s", [.command, .control])), "⌃⌘S")
        XCTAssertEqual(ShortcutFormatter.display(KeyShortcut("g", [.command, .shift])), "⇧⌘G")
        XCTAssertEqual(ShortcutFormatter.display(KeyShortcut("-", .command)), "⌘−")
        XCTAssertEqual(ShortcutFormatter.display(KeyShortcut("delete")), "⌫")
        XCTAssertEqual(ShortcutFormatter.display(KeyShortcut("escape")), "⎋")
        XCTAssertEqual(ShortcutFormatter.spoken(KeyShortcut("n", [.command, .option])), "Option Command N")
        XCTAssertEqual(ShortcutFormatter.spoken(KeyShortcut("+", .command)), "Command Plus")

        let h = await started()
        let pen = descriptor("toolbar.key.p", "p", scope: .canvas, owner: "toolbar")
        let sections = ShortcutDirectory.sections(active: h.app.content.keyCommands.all, off: [pen], query: "")
        XCTAssertEqual(sections.map { $0.scope }, [.global, .library, .document, .canvas])
        XCTAssertFalse(sections.flatMap { $0.entries }.contains { $0.id == "keyboard.zoomInEquals" })
        XCTAssertEqual(sections.last?.entries.first { $0.id == "toolbar.key.p" }?.isOff, true)
        let everywhere = try XCTUnwrap(sections.first?.entries.map { $0.title })
        XCTAssertEqual(everywhere, everywhere.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        let zoom = ShortcutDirectory.sections(active: h.app.content.keyCommands.all, off: [], query: "zoom")
        XCTAssertEqual(zoom.map { $0.scope }, [.document])
        XCTAssertEqual(Set(zoom[0].entries.map { $0.id }), ["keyboard.zoomIn", "keyboard.zoomOut", "keyboard.zoomToFit"])
        let byKeys = ShortcutDirectory.sections(active: h.app.content.keyCommands.all, off: [], query: "⌘P")
        XCTAssertEqual(byKeys.flatMap { $0.entries }.map { $0.id }, ["keyboard.print"])
    }

    func testRenameRulesAndPageNumbers() {
        XCTAssertEqual(RenameRules.problem("  ", current: "Physics"), .empty)
        XCTAssertEqual(RenameRules.problem("Physics ", current: "Physics"), .unchanged)
        XCTAssertEqual(RenameRules.problem("a/b", current: nil), .reservedCharacter)
        XCTAssertEqual(RenameRules.problem("a:b", current: nil), .reservedCharacter)
        XCTAssertEqual(RenameRules.problem(".hidden", current: nil), .leadingDot)
        XCTAssertEqual(RenameRules.problem(String(repeating: "x", count: RenameRules.maxLength + 1), current: nil), .tooLong)
        XCTAssertNil(RenameRules.problem("Chemistry\n", current: "Physics"))
        XCTAssertEqual(RenameRules.trimmed("Chemistry\n"), "Chemistry")

        XCTAssertEqual(PageJump.index("3", pageCount: 5), 2)
        XCTAssertEqual(PageJump.index(" 5 ", pageCount: 5), 4)
        XCTAssertNil(PageJump.index("0", pageCount: 5))
        XCTAssertNil(PageJump.index("6", pageCount: 5))
        XCTAssertNil(PageJump.index("two", pageCount: 5))
    }

    func testRegistrationAndConformance() async {
        let h = await started()
        XCTAssertNotNil(h.app.ui.settingsPages.get(KeyboardSettingsPage.id))
        XCTAssertNotNil(h.app.ui.panels.get(KeyboardPanelIDs.rename))
        XCTAssertEqual(h.app.ui.panels.get(KeyboardPanelIDs.goToPage)?.docKinds, [.notebook, .whiteboard])
        let menu = h.app.ui.menus.get("keyboard.appMenu.shortcuts")
        XCTAssertEqual(menu?.command, "settings.open")
        XCTAssertEqual(menu.map { $0.params(MenuContext(app: h.app)) }, ["page": "keyboard.settings"])
        XCTAssertEqual(h.app.bus.hooks.get(GlobalShortcuts.hookID)?.commands.sorted(),
                       ["commands.batch", "export.present", "print.present"])
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == FeatKeyboardFeature.id }.isEmpty,
                      "the feature maps other features' commands and owns none")
        let problems = await CommandConformance.check(features: [FeatKeyboardFeature.self])
        XCTAssertEqual(problems, [])
    }
}
