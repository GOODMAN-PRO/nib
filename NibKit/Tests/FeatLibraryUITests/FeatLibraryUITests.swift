import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatLibraryUI

@MainActor
final class FeatLibraryUITests: XCTestCase {
    private func harness() -> Harness {
        let h = Harness(features: [FeatLibraryUIFeature.self])
        h.session.document = nil
        for doc in Fixtures.allDocuments { try? h.library.move(doc, to: nil) }
        installList(h)
        return h
    }
    private func installList(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryList, title: "List Library", summary: "List the test library.", effect: .read, target: .library)) { params, _ in
            let folder = try LibraryModels.folder(params["folder"]?.stringValue)
            let rows = params["recursive"]?.boolValue == true ? h.library.allNodes() : h.library.children(of: folder)
            return ["nodes": try JSONValue.from(rows.map(LibraryRow.from)), "total": .number(Double(rows.count))]
        }
    }
    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLibraryUIFeature.self])
        XCTAssertEqual(problems, [])
    }
    func testPerFolderViewsAndWindowIsolation() async throws {
        let h = harness()
        let other = EditorSession(); h.app.services.sessions.add(other)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["layout": "list", "sort": "createdAscending", "filter": "documents"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01", "sort": "name"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "lib"], session: h.session)
        let model = LibraryModels.get(h.app).model(h.session)
        XCTAssertEqual(model.layout, .list)
        XCTAssertEqual(model.sort, .createdAscending)
        XCTAssertEqual(model.filter, .documents)
        XCTAssertNil(LibraryModels.get(h.app).model(other).folder)
        XCTAssertEqual(LibraryModels.get(h.app).model(other).selection.refs.count, 0)
    }
    func testReorderFromReflowPersistsManualAndReturnedOrderReplaysUndo() async throws {
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        await model.reload()
        let order = model.visibleRows.filter { !$0.isFolder }.map(\.ref)
        XCTAssertGreaterThan(order.count, 1)
        let first = try XCTUnwrap(order.first)
        let move = NibReflowMove(id: first, from: 0, to: order.count - 1, in: order)
        let result = try await h.app.bus.execute(CommandIDs.libraryReorder, LibraryOrder.moveParams(move, folder: nil), session: h.session)
        let previous = result["previous"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(model.sort, .manual)
        let saved = h.app.settings.json(LibraryOrder.key(nil))
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["sort": "name"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["sort": "manual"], session: h.session)
        XCTAssertEqual(h.app.settings.json(LibraryOrder.key(nil)), saved)
        XCTAssertEqual(model.visibleRows.filter { !$0.isFolder }.last?.ref, first)
        _ = try await h.app.bus.execute(CommandIDs.libraryReorder, result["undo"] ?? [:], session: h.session)
        XCTAssertEqual(model.visibleRows.map(\.ref), previous)
    }
    func testReorderUndoManagerRegistersRedoSynchronously() async throws {
        let h = harness(), manager = UndoManager()
        manager.groupsByEvent = false
        let model = LibraryModels.get(h.app).model(h.session)
        model.testUndoManager = manager
        await model.reload()
        let before = model.visibleRows.map(\.ref)
        manager.beginUndoGrouping()
        _ = try await h.app.bus.execute(CommandIDs.libraryReorder, ["refs": ["doc:FIXTUREDOC01"]], session: h.session)
        manager.endUndoGrouping()
        let after = h.app.settings.json(LibraryOrder.key(nil))
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "Reorder")
        manager.undo()
        // Command replay is asynchronous, but the inverse is already on UIKit's redo stack.
        XCTAssertTrue(manager.canRedo)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(h.app.settings.json(LibraryOrder.key(nil))?.arrayValue?.compactMap(\.stringValue), before)
        manager.redo()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(h.app.settings.json(LibraryOrder.key(nil)), after)
    }
    func testPanelsPreserveParamsSelectTabAndClose() async throws {
        let h = harness()
        h.app.ui.panels.register(PanelDescriptor(id: "test.sheet", title: "Sheet", icon: NibSymbol.folder.name, placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        h.app.ui.panels.register(PanelDescriptor(id: PanelIDs.trash, title: "Trash", icon: NibSymbol.trash.name, placement: .libraryTab, order: 1, owner: "test") { _ in AnyView(EmptyView()) })
        let params: JSONValue = ["folder": "folder:FIXTUREFLD01", "nested": ["title": "Keep this", "count": 2]]
        let result = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.sheet", "params": params], session: h.session)
        let model = LibraryModels.get(h.app).model(h.session)
        let modal = try XCTUnwrap(model.modal)
        XCTAssertEqual(result["placement"], "sheet")
        XCTAssertEqual(model.panelContext(modal).params, params)
        XCTAssertEqual(model.panelContext(modal).presentation, .sheet)
        XCTAssertTrue(h.session.openPanels.contains("test.sheet"))
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": .string(PanelIDs.trash), "params": ["test": true]], session: h.session)
        XCTAssertEqual(model.tab?.id, PanelIDs.trash)
        XCTAssertEqual(model.tab?.params, ["test": true])
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.sheet", "close": true], session: h.session)
        XCTAssertNil(model.modal)
        XCTAssertFalse(h.session.openPanels.contains("test.sheet"))
        XCTAssertTrue(h.session.openPanels.contains(PanelIDs.trash))
    }
    func testFloatingAndFullScreenPanelsAndUnregisteredDismissal() async throws {
        let h = harness()
        for (id, placement) in [("test.float", PanelPlacement.floating), ("test.full", .fullScreen)] {
            h.app.ui.panels.register(PanelDescriptor(id: id, title: id, icon: NibSymbol.folder.name, placement: placement, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        }
        let model = LibraryModels.get(h.app).model(h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.float", "params": ["ref": "doc:FIXTUREDOC01"]], session: h.session)
        XCTAssertEqual(model.modal?.presentation, .sheet)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.full"], session: h.session)
        XCTAssertEqual(model.modal?.presentation, .fullScreen)
        XCTAssertFalse(h.session.openPanels.contains("test.float"))
        h.app.ui.panels.unregister(owner: "test")
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.full", "close": true], session: h.session)
        XCTAssertNil(model.modal)
        XCTAssertTrue(h.session.openPanels.isEmpty)
    }
    func testCoreShowLibraryForwardsFolderWithoutReplacingItsOwner() async throws {
        let h = harness()
        let navigator = LibraryTestNavigator(app: h.app, session: h.session)
        h.app.ui.activeNavigator = navigator
        let owner = h.app.commands.descriptor(CommandIDs.windowShowLibrary)?.owner
        await FeatLibraryUIFeature.start(h.app)
        await FeatLibraryUIFeature.start(h.app)
        _ = try await h.app.bus.execute(CommandIDs.windowShowLibrary, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        XCTAssertEqual(LibraryModels.get(h.app).model(h.session).folder, Fixtures.folderID)
        _ = try await h.app.bus.execute(CommandIDs.windowShowLibrary, [:], session: h.session)
        XCTAssertNil(LibraryModels.get(h.app).model(h.session).folder)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.windowShowLibrary)?.owner, owner)
        XCTAssertTrue(h.app.commands.duplicateIDs.isEmpty)
    }
    func testInvalidAndDryRunReordersDoNotWriteSettings() async throws {
        let h = harness()
        let key = LibraryOrder.key(nil)
        let before = h.app.settings.json(key)
        let result = try await h.app.bus.execute(Invocation(command: CommandIDs.libraryReorder, params: ["refs": ["doc:FIXTUREDOC01"]], session: h.session, dryRun: true))
        XCTAssertNotNil(result.value["previous"])
        XCTAssertEqual(h.app.settings.json(key), before)
        do {
            _ = try await h.app.bus.execute(CommandIDs.libraryReorder, ["refs": ["doc:FIXTUREDOC01"], "before": "doc:missing"], session: h.session)
            XCTFail("A missing anchor must be rejected")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(h.app.settings.json(key), before)
    }
    func testSidebarPanelRejectedWithoutPresentationChanges() async throws {
        let h = harness()
        h.app.ui.panels.register(PanelDescriptor(id: "test.sidebar", title: "Pages", icon: NibSymbol.pages.name, placement: .sidebarTab, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        do {
            _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.sidebar"], session: h.session)
            XCTFail("A document sidebar must not open in the library")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertTrue(h.session.openPanels.isEmpty)
    }
    func testMenuContextsCarryFolderAndCreationNodes() async throws {
        let h = harness()
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        let model = LibraryModels.get(h.app).model(h.session)
        for location in [MenuLocation.libraryNew, .libraryItem, .librarySelection, .appMenu] {
            let context = LibraryMenus.context(model, location: location, rows: [])
            XCTAssertEqual(context.folder, Fixtures.folderID)
            XCTAssertEqual(context.nodes, location == .libraryNew ? [Fixtures.folderID] : [])
        }
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "lib"], session: h.session)
        XCTAssertNil(LibraryMenus.context(model, location: .libraryNew, rows: []).folder)
    }
    func testSelectionThroughCommandAndFloatingToast() async throws {
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        await model.reload()
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "all"], session: h.session)
        XCTAssertEqual(model.selection.refs, Set(model.visibleRows.map(\.ref)))
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "clear"], session: h.session)
        XCTAssertFalse(model.selection.isSelecting)
        model.session.floatingHost = model.floatingAdapter
        h.session.floatingHost?.postToast("Moved")
        XCTAssertEqual(model.floating.toast?.message, "Moved")
    }
}

@MainActor
private final class LibraryTestNavigator: SceneNavigator {
    unowned let app: NibApp
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID? { session.document }
    var rootViewController: UIViewController?
    init(app: NibApp, session: EditorSession) { self.app = app; self.session = session }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) { session.document = doc }
    func closeDocument(_ doc: DocumentID) { session.document = nil }
    func showLibrary(folder: FolderID?) {
        // Like the shell: the factory does not receive this argument.
        session.document = nil
        rootViewController = app.ui.screens.libraryRoot?(app, self)
    }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) { rootViewController = viewController }
}
