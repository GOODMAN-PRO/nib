import XCTest
import NibContracts
import NibTesting
@testable import FeatLayers

@MainActor
final class FeatLayersTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatLayersFeature.self]) }

    private func ref(_ id: ElementID) -> String { NodeRef.item(Fixtures.docID, Fixtures.page1, id).description }

    private func item(_ h: Harness, _ id: ElementID) throws -> Item {
        try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: id)
    }

    private func layerName(_ h: Harness, _ layer: Int) throws -> String {
        LayerModel.normalized(try h.app.workspace.content(Fixtures.docID).meta.layers)[layer].name
    }

    private func assertError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration and conformance

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLayersFeature.self], owners: [FeatLayersFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersCommandsHookMenusAndSettings() {
        let h = harness()
        XCTAssertEqual(FeatLayersFeature.id, "layers")
        for id in [CommandIDs.layerSetActive, CommandIDs.layerSetVisible, CommandIDs.layerRename, CommandIDs.layerMoveItems] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatLayersFeature.id, id)
        }
        XCTAssertEqual(h.app.commands.descriptor("layer.setActive")?.effect, .session)
        XCTAssertEqual(h.app.commands.descriptor("layer.setVisible")?.effect, .session)
        XCTAssertEqual(h.app.commands.descriptor("layer.rename")?.effect, .edit)
        XCTAssertEqual(h.app.commands.descriptor("layer.moveItems")?.effect, .edit)
        // The export hook is a contracts-v2 closure guard (G26), not an extra hook command.
        XCTAssertNil(h.app.commands.descriptor(CommandIDs.layerExportOptions))
        let hook = h.app.bus.hooks.all.first { $0.owner == FeatLayersFeature.id }
        XCTAssertEqual(hook?.id, "layers.visibleLayersOnly")
        XCTAssertEqual(hook?.matches(CommandIDs.exportRun), true)
        XCTAssertEqual(hook?.matches(CommandIDs.renderPage), true)
        XCTAssertNotNil(hook?.contextHandler)
        XCTAssertEqual(h.app.settings.descriptor("layers.show")?.synced, true)
        XCTAssertEqual(h.app.settings.descriptor("layers.view.FIXTUREDOC01")?.synced, false)
        XCTAssertNotNil(h.app.ui.menus.get("layers.moveTo.4"))
        let more = h.app.ui.menus.get("layers.panel.more")
        XCTAssertEqual(more?.icon, "square.3.layers.3d")
        XCTAssertEqual(more?.shortcut, KeyShortcut("l", [.command, .option]), "the menu shows the panel's key")
        let page = h.app.ui.settingsPages.get("layers.settings")
        XCTAssertEqual(page?.icon, "square.3.layers.3d")
        XCTAssertFalse(page?.keywords.isEmpty ?? true, "settings search finds the page by its words")
    }

    // MARK: Rename

    func testRenameUndoRedoRoundTrip() async throws {
        let h = harness()
        let before = try h.snapshot()
        let out = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC01", "layer": 1, "name": "  Diagrams "])
        XCTAssertEqual(out["name"]?.stringValue, "Diagrams")
        XCTAssertEqual(try layerName(h, 1), "Diagrams")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try layerName(h, 1), "Layer 2")
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try layerName(h, 1), "Diagrams")

        // An empty name restores the default; renaming to the current name records nothing.
        _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC01", "layer": 1, "name": ""])
        XCTAssertEqual(try layerName(h, 1), "Layer 2")
        let depth = h.undoDepth(Fixtures.docID)
        _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC01", "layer": 1, "name": "Layer 2"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    // MARK: Move items

    func testMoveItemsUndoRoundTripWithAttachedChildren() async throws {
        let h = harness()
        // A label attached to the fixture shape (added before the workspace first loads the page).
        let label = Item(id: "LAYERCHILD01", kind: .text, z: "zz", attachedTo: Fixtures.shapeID,
                         text: TextBoxItem(frame: Frame(x: 110, y: 210, w: 100, h: 30), text: RichText(plain: "Label")))
        h.persistence.pageItems[Fixtures.docID, default: [:]][Fixtures.page1, default: []].append(label)
        let before = try h.snapshot()

        let out = try await h.run("layer.moveItems", ["refs": [.string(ref(Fixtures.shapeID)), .string(ref(Fixtures.strokeID))],
                                                      "layer": 3])
        XCTAssertEqual(out["moved"]?.intValue, 3)
        XCTAssertEqual(try item(h, Fixtures.shapeID).layer, 3)
        XCTAssertEqual(try item(h, "LAYERCHILD01").layer, 3)
        XCTAssertEqual(try item(h, Fixtures.strokeID).layer, 3)
        XCTAssertEqual(try item(h, Fixtures.textID).layer, 0)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try item(h, "LAYERCHILD01").layer, 3)
    }

    func testUserCallersMayOmitRefsAndDocForTheWindowsSelectionAndDocument() async throws {
        let h = harness()
        // Menus and keys run with static params: the user's layer.moveItems takes the window's selection and
        // layer.rename the window's document (§6.1 session defaults).
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        let out = try await h.run("layer.moveItems", ["layer": 2])
        XCTAssertEqual(out["moved"]?.intValue, 1)
        XCTAssertEqual(try item(h, Fixtures.textID).layer, 2)
        XCTAssertEqual(try item(h, Fixtures.strokeID).layer, 0)
        XCTAssertTrue(h.session.selection.isEmpty, "a selection that left the active layer is dropped")

        let renamed = try await h.run("layer.rename", ["layer": 4, "name": "Answers"])
        XCTAssertEqual(renamed["doc"]?.stringValue, "doc:FIXTUREDOC01")
        XCTAssertEqual(try layerName(h, 4), "Answers")

        // Nothing selected: nothing to move. The AI, plugins and the bridge still pass refs and doc.
        await assertError(.invalidParams) { _ = try await h.run("layer.moveItems", ["layer": 1]) }
        await assertError(.invalidParams) { _ = try await h.run("layer.moveItems", ["layer": 1], as: .ai("chat")) }
        await assertError(.invalidParams) {
            _ = try await h.run("layer.rename", ["layer": 1, "name": "Notes"], as: .ai("chat"))
        }
    }

    func testRejectsBadParamsAndDocumentsWithoutLayers() async {
        let h = harness()
        await assertError(.invalidParams) {
            _ = try await h.run("layer.moveItems", ["refs": ["page:FIXTUREDOC01/FIXTUREPG001"], "layer": 1])
        }
        await assertError(.notFound) {
            _ = try await h.run("layer.moveItems", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/MISSING00001"], "layer": 1])
        }
        await assertError(.invalidParams) { _ = try await h.run("layer.moveItems", ["refs": [], "layer": 1]) }
        await assertError(.invalidParams) { _ = try await h.run("layer.setActive", ["layer": 5]) }
        await assertError(.invalidParams) { _ = try await h.run("layer.setActive", ["layer": 7], as: .ai("chat")) }
        await assertError(.invalidParams) {
            _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC01", "layer": 0,
                                                 "name": .string(String(repeating: "x", count: 101))])
        }
        await assertError(.unsupported) {
            _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC02", "layer": 0, "name": "Notes"])
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        h.session.document = Fixtures.textDocID
        await assertError(.unsupported) { _ = try await h.run("layer.setActive", ["layer": 1]) }
        h.session.document = nil
        await assertError(.unavailable) { _ = try await h.run("layer.setVisible", ["layer": 1, "visible": false]) }
    }

    // MARK: Active layer and visibility

    func testActiveLayerShortcutsUpdateTheInvokingWindowAndNotifyCanvasObservers() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        let otherWindow = EditorSession()
        otherWindow.document = Fixtures.whiteboardID
        h.app.services.sessions.add(otherWindow)
        let before = try h.snapshot()

        // The native Layers switch runs this command. Enabling it must make the
        // shortcuts available without reopening the document or restarting the app.
        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": true])
        XCTAssertNotNil(h.app.ui.panels.get("layers"))
        XCTAssertTrue(h.app.services.sessions.active === otherWindow)

        var changes: [NibEvent] = []
        let observer = h.app.events.subscribe { event in
            if event.type == NibEventType.layersChanged { changes.append(event) }
        }
        defer { observer.cancel() }

        // Match the panel's Layer 2 command, then the Option-Command-3 / -2
        // sequence used while drawing and lassoing. The explicit calling window
        // must win over the registry's most recently active window.
        _ = try await h.run(CommandIDs.layerSetActive, ["layer": 1])
        XCTAssertEqual(h.session.activeLayer, 1)
        for layer in [2, 1] {
            let key = try XCTUnwrap(h.app.content.keyCommands.get(LayersChrome.activeKeyID(layer)))
            XCTAssertEqual(key.shortcut, KeyShortcut(String(layer + 1), [.command, .option]))
            _ = try await h.run(key.command, key.params)
            XCTAssertEqual(h.session.activeLayer, layer,
                           "Ink and lasso must see the layer chosen by the registered shortcut")
            XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).active, layer)
        }
        XCTAssertEqual(otherWindow.activeLayer, 0)
        XCTAssertEqual(changes.count, 3)
        XCTAssertTrue(changes.allSatisfy { $0.payload?["session"]?.stringValue == h.session.id.raw })
        XCTAssertEqual(try h.snapshot(), before, "Choosing a layer must not edit document content")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        h.session.document = Fixtures.whiteboardID
        h.session.document = Fixtures.docID
        XCTAssertEqual(h.session.activeLayer, 1, "The chosen layer survives switching documents")
    }

    func testVisibilityIsPerDocumentOnThisDeviceAndLeftOutOfRendering() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        // A stand-in renderer that returns the params it received (after hooks).
        h.app.commands.register(CommandDescriptor(id: CommandIDs.renderPage, title: "Render", summary: "Echo the params.",
                                                  params: .anything("render.page params"), effect: .read)) { params, _ in params }
        let page1: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001"]
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])

        let out = try await h.run("layer.setVisible", ["layer": 0, "visible": false])
        XCTAssertEqual(out["hiddenLayers"]?.arrayValue?.compactMap { $0.intValue }, [0])
        XCTAssertEqual(h.session.hiddenLayers, Set([0]))
        XCTAssertTrue(h.session.selection.isEmpty, "selected items on a hidden layer are deselected")
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).hidden, [0])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "visibility is not a document edit")

        // Back to the default view: the per-document key is removed, not written.
        _ = try await h.run("layer.setVisible", ["layer": 0, "visible": true])
        XCTAssertNil(h.app.settings.json(LayerSettings.viewPrefix + Fixtures.docID.raw))
        _ = try await h.run("layer.setVisible", ["layer": 2, "visible": false])
        let rendered = try await h.run(CommandIDs.renderPage, page1)
        let visible: JSONValue = [0, 1, 3, 4]
        XCTAssertEqual(rendered["layers"], visible, "render.page leaves the hidden layer out")
        let chosen = try await h.run(CommandIDs.renderPage, ["page": "page:FIXTUREDOC01/FIXTUREPG001", "layers": [2]])
        XCTAssertEqual(chosen["layers"], JSONValue.array([2]), "layers chosen by the caller are kept")

        let active = try await h.run("layer.setActive", ["layer": 3])
        XCTAssertEqual(active["activeLayer"]?.intValue, 3)
        XCTAssertEqual(h.session.activeLayer, 3)

        // Another document has its own view; coming back restores this one.
        h.session.document = Fixtures.whiteboardID
        XCTAssertEqual(h.session.hiddenLayers, Set<Int>())
        XCTAssertEqual(h.session.activeLayer, 0)
        h.session.document = Fixtures.docID
        XCTAssertEqual(h.session.hiddenLayers, Set([2]))
        XCTAssertEqual(h.session.activeLayer, 3)

        // A document open in no window still reports its stored view (library exports, AI and bridge renders).
        h.session.document = Fixtures.whiteboardID
        XCTAssertEqual(LayerView.visibleLayers(Fixtures.docID, sessions: h.app.services.sessions,
                                               settings: h.app.settings, preferring: nil), Set([0, 1, 3, 4]))
        let unopened = try await h.run(CommandIDs.renderPage, page1)
        XCTAssertEqual(unopened["layers"], visible)
        let board = try await h.run(CommandIDs.renderPage, ["page": "page:FIXTUREDOC04/FIXTUREBRD01"])
        XCTAssertNil(board["layers"], "nothing hidden on the board: the call is unchanged")
        // The guard hook runs for every principal: an AI or bridge render leaves the hidden layer out too.
        let aiRender = try await h.run(CommandIDs.renderPage, page1, as: .ai("chat"))
        XCTAssertEqual(aiRender["layers"], visible)
    }

    func testTurningLayersOffShowsEveryLayerAndOnRestoresTheView() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.exportRun, title: "Export", summary: "Echo the params.",
                                                  effect: .read)) { params, _ in params }
        let export: JSONValue = ["docs": ["doc:FIXTUREDOC01"], "format": "pdf"]
        XCTAssertFalse(h.app.settings.get(LayerSettings.show))

        _ = try await h.run("layer.setVisible", ["layer": 2, "visible": false])
        XCTAssertTrue(h.app.settings.get(LayerSettings.show), "changing the layer view turns Layers on")
        XCTAssertNotNil(h.app.ui.panels.get("layers"))
        _ = try await h.run("layer.setActive", ["layer": 3])

        // Off: every layer is shown, new content goes to Layer 1, exports are unchanged; the stored view is kept.
        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": false])
        XCTAssertEqual(h.session.hiddenLayers, Set<Int>())
        XCTAssertEqual(h.session.activeLayer, 0)
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)), LayerViewState(hidden: [2], active: 3))
        let echoed = try await h.run(CommandIDs.exportRun, export)
        XCTAssertNil(echoed["options"], "no visibleLayers while Layers is off")
        h.session.document = Fixtures.whiteboardID
        h.session.document = Fixtures.docID
        XCTAssertEqual(h.session.hiddenLayers, Set<Int>(), "switching documents while off keeps every layer shown")
        XCTAssertEqual(h.session.activeLayer, 0)

        // On again: the document's view comes back.
        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": true])
        XCTAssertEqual(h.session.hiddenLayers, Set([2]))
        XCTAssertEqual(h.session.activeLayer, 3)
        let restored = try await h.run(CommandIDs.exportRun, export)
        let expected: JSONValue = [0, 1, 3, 4]
        XCTAssertEqual(restored["options"]?["visibleLayers"]?["FIXTUREDOC01"], expected)

        // The AI (or a plugin) changing the view while Layers is off turns it on, so the change is never invisible.
        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": false])
        let out = try await h.run("layer.setVisible", ["layer": 4, "visible": false], as: .ai("chat"))
        XCTAssertTrue(h.app.settings.get(LayerSettings.show))
        XCTAssertNotNil(h.app.ui.panels.get("layers"))
        XCTAssertEqual(h.session.hiddenLayers, Set([2, 4]))
        XCTAssertEqual(h.session.activeLayer, 3)
        XCTAssertEqual(out["hiddenLayers"]?.arrayValue?.compactMap { $0.intValue }, [2, 4])

        // A dry run (AI preview) changes nothing, not even the setting.
        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": false])
        let preview = try await h.app.bus.execute(Invocation(command: "layer.setActive", params: ["layer": 1],
                                                             principal: .ai("chat"), session: h.session, dryRun: true))
        XCTAssertEqual(preview.value["activeLayer"]?.intValue, 1)
        XCTAssertFalse(h.app.settings.get(LayerSettings.show))
        XCTAssertEqual(h.session.activeLayer, 0)
    }

    func testEditingAHiddenLayerShowsItAgain() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        // Stands in for any editing command (ink, item.update, AI): toggles the fixture stroke's lock on layer 0.
        h.app.commands.register(CommandDescriptor(id: "test.touch", title: "Touch", summary: "Toggle the fixture stroke's lock.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { (tx: DocTransaction) -> Void in
                var stroke = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
                stroke.locked.toggle()
                try tx.put(stroke, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return [:]
        }
        _ = try await h.run("layer.setVisible", ["layer": 0, "visible": false])
        _ = try await h.run("layer.setVisible", ["layer": 4, "visible": false])
        _ = try await h.run("test.touch")
        XCTAssertEqual(h.session.hiddenLayers, Set([4]))
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).hidden, [4])

        // Undo and moving items onto a hidden layer on purpose do not count as editing it.
        _ = try await h.run("layer.setVisible", ["layer": 0, "visible": false])
        _ = try await h.run(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(h.session.hiddenLayers, Set([0, 4]))
        _ = try await h.run("layer.moveItems", ["refs": [.string(ref(Fixtures.textID))], "layer": 4])
        XCTAssertEqual(h.session.hiddenLayers, Set([0, 4]))

        // An edit (AI, plugin, bridge) to a document no window shows updates its stored view instead.
        h.session.document = Fixtures.whiteboardID
        _ = try await h.run("test.touch")
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).hidden, [4])
        h.session.document = Fixtures.docID
        XCTAssertEqual(h.session.hiddenLayers, Set([4]))
    }

    func testCopyingPagesWithItemsOnAHiddenLayerDoesNotShowIt() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        // Stands in for page.duplicate / page.paste / page.moveTo / doc.merge: a new page holding a copy of the
        // fixture stroke, which is on layer 0.
        h.app.commands.register(CommandDescriptor(id: "test.copyPage", title: "Copy Page",
                                                  summary: "Add page LAYERPAGE00<n> holding a copy of the fixture stroke.",
                                                  effect: .edit)) { params, ctx in
            let n = params["n"]?.stringValue ?? "1"
            try ctx.mutate { (tx: DocTransaction) -> Void in
                let page = try tx.put(PageRecord(id: NibID("LAYERPAGE00" + n)), doc: Fixtures.docID)
                var copy = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
                copy.id = NibID("LAYERCOPY00" + n)
                try tx.put(copy, doc: Fixtures.docID, page: page.id)
            }
            return [:]
        }
        _ = try await h.run("layer.setVisible", ["layer": 0, "visible": false])
        _ = try await h.run("test.copyPage", ["n": "1"])
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: "LAYERPAGE001", id: "LAYERCOPY001").layer, 0)
        XCTAssertEqual(h.session.hiddenLayers, Set([0]), "copying a page is not an edit of its layers")
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).hidden, [0])

        // The same for a document no window shows: its stored view keeps the layer hidden.
        h.session.document = Fixtures.whiteboardID
        _ = try await h.run("test.copyPage", ["n": "2"])
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: "LAYERPAGE002", id: "LAYERCOPY002").layer, 0)
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).hidden, [0])
        h.session.document = Fixtures.docID
        XCTAssertEqual(h.session.hiddenLayers, Set([0]))
    }

    // MARK: Export hook

    func testExportsLeaveOutHiddenLayers() async throws {
        let h = harness()
        // A stand-in exporter that returns the params it received (after hooks).
        h.app.commands.register(CommandDescriptor(id: CommandIDs.exportRun, title: "Export", summary: "Echo the params.",
                                                  effect: .read)) { params, _ in params }
        let plain = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf"])
        XCTAssertNil(plain["options"], "nothing hidden: the call is unchanged")

        _ = try await h.run("layer.setVisible", ["layer": 1, "visible": false])
        let echoed = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01", "doc:FIXTUREDOC04"], "format": "pdf"])
        let expected: JSONValue = [0, 2, 3, 4]
        XCTAssertEqual(echoed["options"]?["visibleLayers"]?["FIXTUREDOC01"], expected)
        XCTAssertNil(echoed["options"]?["visibleLayers"]?["FIXTUREDOC04"])
        XCTAssertEqual(echoed["options"]?["visibleLayersOnly"], JSONValue.bool(true))
        XCTAssertEqual(echoed["format"]?.stringValue, "pdf")

        // The caller can still ask for every layer.
        let all = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf",
                                                         "options": ["visibleLayersOnly": false]])
        XCTAssertNil(all["options"]?["visibleLayers"])

        // Layers off: every layer is exported.
        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": false])
        let off = try await h.run(CommandIDs.exportRun, ["docs": ["doc:FIXTUREDOC01"], "format": "pdf"])
        XCTAssertNil(off["options"])
    }

    // MARK: Chrome

    func testLayersShowSettingAddsPanelShortcutsAndMenus() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        XCTAssertNil(h.app.ui.panels.get("layers"))

        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": true])
        let panel = try XCTUnwrap(h.app.ui.panels.get("layers"))
        XCTAssertEqual(panel.placement, .sidebarTab)
        XCTAssertEqual(panel.docKinds, Set([DocumentKind.notebook, .whiteboard]))
        let key = try XCTUnwrap(h.app.content.keyCommands.get("layers.active.2"))
        XCTAssertEqual(key.command, "layer.setActive")
        let panelKey = try XCTUnwrap(h.app.content.keyCommands.get("layers.panel.key"))
        XCTAssertEqual(panelKey.params["id"]?.stringValue, "layers")
        // The keys are live only where layers exist (contracts-v2.2 key routing).
        for k in [key, panelKey] {
            XCTAssertEqual(k.docKinds, Set([DocumentKind.notebook, .whiteboard]))
            XCTAssertTrue(k.isActive(in: KeyCommandContext(inDocument: true, docKind: .whiteboard)))
            XCTAssertFalse(k.isActive(in: KeyCommandContext(inDocument: true, docKind: .textDocument)))
            XCTAssertFalse(k.isActive(in: KeyCommandContext(inDocument: false, docKind: nil, hasTabs: true)))
        }

        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
        let menu = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1,
                               selection: h.session.selection)
        XCTAssertFalse(LayersChrome.canMove(menu, to: 0), "the stroke is already on layer 0")
        XCTAssertTrue(LayersChrome.canMove(menu, to: 3))
        XCTAssertEqual(h.app.ui.menus.get("layers.moveTo.3")?.params(menu)["layer"]?.intValue, 3)

        _ = try await h.run(CommandIDs.settingsSet, ["name": "layers.show", "value": false])
        XCTAssertNil(h.app.ui.panels.get("layers"))
        XCTAssertNil(h.app.content.keyCommands.get("layers.active.2"))
        XCTAssertFalse(LayersChrome.canMove(menu, to: 3))
    }

    func testMoveMenuShowsEachWindowsLayerNames() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        let entry = try XCTUnwrap(h.app.ui.menus.get("layers.moveTo.1"))
        let notebook = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1,
                                   selection: Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID]))
        let board = MenuContext(app: h.app, doc: Fixtures.whiteboardID)
        XCTAssertEqual(entry.title, "Layer 2")
        XCTAssertEqual(entry.resolvedTitle(for: notebook), "Layer 2")

        _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC01", "layer": 1, "name": "Diagrams"])
        _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC04", "layer": 1, "name": "Sketches"])
        // Two windows showing different documents each see their own names, from one registration.
        XCTAssertEqual(entry.resolvedTitle(for: notebook), "Diagrams")
        XCTAssertEqual(entry.resolvedTitle(for: board), "Sketches")
        XCTAssertEqual(h.app.ui.menus.get("layers.moveTo.1")?.resolvedTitle(for: notebook), "Diagrams")
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(entry.resolvedTitle(for: notebook), "Layer 2")
        XCTAssertEqual(entry.resolvedTitle(for: board), "Sketches")
    }

    // MARK: Pure model

    func testModelNormalisesLayersCountsRowsAndFollowsAttachments() throws {
        let layers = LayerModel.normalized([LayerInfo(index: 3, name: "Ink"), LayerInfo(index: 9, name: "Stray"),
                                            LayerInfo(index: 3, name: "Sketch")])
        XCTAssertEqual(layers.map { $0.index }, [0, 1, 2, 3, 4])
        XCTAssertEqual(layers.map { $0.name }, ["Layer 1", "Layer 2", "Layer 3", "Sketch", "Layer 5"])

        let frame = Frame(x: 0, y: 0, w: 10, h: 10)
        let shape = Item.makeShape(ShapeItem(shape: .rectangle, frame: frame), layer: 2)
        var label = Item.makeText(TextBoxItem(frame: frame, text: RichText(plain: "A")), layer: 2)
        label.attachedTo = shape.id
        var note = Item.makeText(TextBoxItem(frame: frame, text: RichText(plain: "B")), layer: 1)
        note.attachedTo = label.id
        var gone = Item.makeShape(ShapeItem(shape: .ellipse, frame: frame), layer: 2)
        gone.deleted = true

        let rows = LayerModel.rows(layers: [], items: [shape, label, note, gone], hidden: [4], active: 2)
        XCTAssertEqual(rows.map { $0.itemCount }, [0, 1, 2, 0, 0])
        XCTAssertTrue(rows[2].isActive)
        XCTAssertTrue(rows[4].isHidden)
        XCTAssertEqual(LayerModel.withAttachedChildren([shape.id], in: [note, label, shape]), [shape.id, label.id, note.id])

        XCTAssertEqual(try LayerModel.cleanName("  ", layer: 2), "Layer 3")
        XCTAssertEqual(try LayerModel.cleanName("A\nB\u{0007}", layer: 0), "A B")
        XCTAssertEqual(try LayerModel.cleanName("\t Two \r\n  words\u{2028}", layer: 0), "Two words")
        XCTAssertEqual(try LayerModel.cleanName("\u{1F469}\u{200D}\u{1F4BB} Code", layer: 0), "\u{1F469}\u{200D}\u{1F4BB} Code",
                       "format characters (emoji ZWJ) are kept")
        XCTAssertThrowsError(try LayerModel.cleanName(String(repeating: "x", count: 101), layer: 0))
        XCTAssertNil(LayerModel.exportParams(["docs": ["doc:A"]], visible: { _ in Set(LayerModel.all) }))

        let render: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "scale": 2]
        let visible: JSONValue = [0, 1, 3, 4]
        XCTAssertEqual(LayerModel.renderParams(render, visible: { _ in [0, 1, 3, 4] })?["layers"], visible)
        XCTAssertEqual(LayerModel.renderParams(render, visible: { _ in [0, 1, 3, 4] })?["scale"], render["scale"])
        XCTAssertNil(LayerModel.renderParams(render, visible: { _ in Set(LayerModel.all) }))
        XCTAssertNil(LayerModel.renderParams(["page": "page:FIXTUREDOC01/FIXTUREPG001", "layers": [1]], visible: { _ in [0] }))
        XCTAssertNil(LayerModel.renderParams(["page": "doc:FIXTUREDOC01"], visible: { _ in [0] }))
    }
}
