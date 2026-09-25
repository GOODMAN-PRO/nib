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
        for id in ["layer.setActive", "layer.setVisible", "layer.rename", "layer.moveItems", "layer.exportOptions"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatLayersFeature.id, id)
        }
        XCTAssertEqual(h.app.commands.descriptor("layer.setActive")?.effect, .session)
        XCTAssertEqual(h.app.commands.descriptor("layer.setVisible")?.effect, .session)
        XCTAssertEqual(h.app.commands.descriptor("layer.rename")?.effect, .edit)
        XCTAssertEqual(h.app.commands.descriptor("layer.moveItems")?.effect, .edit)
        XCTAssertTrue(h.app.bus.hooks.all.contains { $0.matches(CommandIDs.exportRun) && $0.command == "layer.exportOptions" })
        XCTAssertEqual(h.app.settings.descriptor("layers.show")?.synced, true)
        XCTAssertEqual(h.app.settings.descriptor("layers.view.FIXTUREDOC01")?.synced, false)
        XCTAssertNotNil(h.app.ui.menus.get("layers.moveTo.4"))
        XCTAssertNotNil(h.app.ui.menus.get("layers.panel.more"))
        XCTAssertNotNil(h.app.ui.settingsPages.get("layers.settings"))
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

    func testVisibilityIsPerDocumentOnThisDeviceAndLeftOutOfRendering() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])

        let out = try await h.run("layer.setVisible", ["layer": 0, "visible": false])
        XCTAssertEqual(out["hiddenLayers"]?.arrayValue?.compactMap { $0.intValue }, [0])
        XCTAssertEqual(h.session.hiddenLayers, Set([0]))
        XCTAssertTrue(h.session.selection.isEmpty, "selected items on a hidden layer are deselected")
        XCTAssertEqual(h.app.settings.get(LayerSettings.view(Fixtures.docID)).hidden, [0])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "visibility is not a document edit")

        _ = try await h.run("layer.setVisible", ["layer": 0, "visible": true])
        _ = try await h.run("layer.setVisible", ["layer": 2, "visible": false])
        let visible = LayerView.visibleLayers(Fixtures.docID, sessions: h.app.services.sessions, settings: h.app.settings,
                                              preferring: h.session)
        let request = RenderRequest(doc: Fixtures.docID, page: Fixtures.page1, layers: visible)
        XCTAssertEqual(request.layers, Set([0, 1, 3, 4]))

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

        // A document open in no window still reports its stored view (library exports).
        h.session.document = Fixtures.whiteboardID
        XCTAssertEqual(LayerView.visibleLayers(Fixtures.docID, sessions: h.app.services.sessions,
                                               settings: h.app.settings, preferring: nil), Set([0, 1, 3, 4]))
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
        XCTAssertEqual(h.app.content.keyCommands.get("layers.active.2")?.command, "layer.setActive")
        XCTAssertEqual(h.app.content.keyCommands.get("layers.panel.key")?.params["id"]?.stringValue, "layers")

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

    func testMoveMenuShowsTheDocumentsLayerNames() async throws {
        let h = harness()
        await FeatLayersFeature.start(h.app)
        XCTAssertEqual(h.app.ui.menus.get("layers.moveTo.1")?.title, "Layer 2")
        _ = try await h.run("layer.rename", ["doc": "doc:FIXTUREDOC01", "layer": 1, "name": "Diagrams"])
        XCTAssertEqual(h.app.ui.menus.get("layers.moveTo.1")?.title, "Diagrams")
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(h.app.ui.menus.get("layers.moveTo.1")?.title, "Layer 2")
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
        XCTAssertThrowsError(try LayerModel.cleanName(String(repeating: "x", count: 101), layer: 0))
        XCTAssertNil(LayerModel.exportParams(["docs": ["doc:A"]], visible: { _ in Set(LayerModel.all) }))
    }
}
