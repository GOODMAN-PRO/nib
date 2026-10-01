import XCTest
import SwiftUI
import UIKit
import NibContracts
@testable import NibDesign
import NibTesting
@testable import FeatLibraryUI

@MainActor
final class FeatLibraryUITests: XCTestCase {
    private var controllers: [UIViewController] = []
    private func harness() -> Harness {
        let h = Harness(features: [FeatLibraryUIFeature.self])
        h.session.document = nil
        for doc in Fixtures.allDocuments { try? h.library.move(doc, to: nil) }
        installList(h)
        controllers.append(LibraryRootViewController(app: h.app, navigator: LibraryTestNavigator(app: h.app, session: h.session)))
        return h
    }
    private func installList(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryList, title: "List Library", summary: "List the test library.", effect: .read, target: .library)) { params, _ in
            let folder = try LibraryModels.folder(params["folder"]?.stringValue)
            let nodes = params["recursive"]?.boolValue == true ? h.library.allNodes() : h.library.children(of: folder)
            let rows = params["kinds"] == ["folder"] ? nodes.filter { $0.kind == .folder } : nodes
            return ["nodes": try JSONValue.from(rows.map(LibraryRow.from)), "total": .number(Double(rows.count))]
        }
    }
    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLibraryUIFeature.self])
        XCTAssertEqual(problems, [])
    }
    func testLibraryChromeLayoutRegistersAndDrawsItsDropletBodies() async throws {
        try XCTSkipUnless(NibSnapshot.supportsHostedImages, "Liquid Glass compositor snapshots require an app-hosted window scene; validate them in simulator captures.")
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        let root = LibraryRootView(model: model)
        for compact in [false, true] {
            let size = CGSize(width: compact ? 390 : 1024, height: 240)
            for variant in [NibSnapshot.Variant.light, .dark] {
                for mode in [NibLiquidMode.full, .off] {
                    let ids = ["library.controls", "library.new.button"]
                    let anchors = compact ? ["library.new"] : ["library.new", "library.sort"]
                    var registeredFrames: [String: CGRect] = [:]
                    var drawnIDs: Set<String> = []
                    var registeredAnchors: Set<String> = []
                    // Use the production controls and their custom layout, over the worst-case contrast backdrop.
                    let view = ZStack {
                        NibColor.label
                        NibDropletContainer {
                            ZStack {
                                LibraryChromeOverlayLayout(inlineSidebar: !compact, compact: compact, titleBottom: 64) {
                                    root.chrome(compact: compact)
                                        .layoutValue(key: LibraryChromeOverlaySlot.self,
                                                     value: .init(placement: compact ? .bottomTrailing : .topTrailing,
                                                                  isControls: true))
                                }
                                .padding(NibSpacing.l)
                                LibraryChromeFieldProbe(ids: ids, anchors: anchors) { field in
                                    // Copy the state while the live window is attached. hostedImage tears down
                                    // the window on return, which unregisters droplets from their field.
                                    for id in ids {
                                        registeredFrames[id] = field.visualFrame(id)
                                        if field.node(id).presentation.isDrawn { drawnIDs.insert(id) }
                                    }
                                    registeredAnchors = Set(field.worldAnchors.keys)
                                }
                            }
                        }
                    }
                    .nibLiquidMode(mode)
                    .environment(\.horizontalSizeClass, compact ? .compact : .regular)
                    let rendered = try await NibSnapshot.hostedImage(view, size: size, variant: variant)
                    let image = try XCTUnwrap(rendered)
                    let name = "library-chrome-\(compact ? "iphone" : "ipad")-\(variant.rawValue)-\(mode.rawValue)"
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)

                    let clear = try XCTUnwrap(registeredFrames["library.controls"], "\(name): Clear needs a rest frame")
                    let tinted = try XCTUnwrap(registeredFrames["library.new.button"], "\(name): New needs a rest frame")
                    XCTAssertEqual(drawnIDs, Set(ids), name)
                    XCTAssertEqual(clear.width, compact ? 44 : 140, accuracy: 0.5, name)
                    XCTAssertEqual(tinted.width, compact ? 44 : 96, accuracy: 0.5, name)
                    XCTAssertEqual(tinted.height, 44, accuracy: 0.5, name)
                    XCTAssertEqual(tinted.minX - clear.maxX, 16, accuracy: 0.5, name)
                    XCTAssertEqual(tinted.maxX, size.width - NibSpacing.l, accuracy: 0.5, name)
                    XCTAssertEqual(tinted.minY, compact ? size.height - NibSpacing.l - 44 : NibSpacing.l,
                                   accuracy: 0.5, name)

                    var accentPixels = 0
                    let interior = tinted.insetBy(dx: 8, dy: 8)
                    for y in Int(interior.minY)..<Int(interior.maxY) {
                        for x in Int(interior.minX)..<Int(interior.maxX) {
                            let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                            if Int(pixel.b) - Int(pixel.r) > 50 && Int(pixel.b) - Int(pixel.g) > 30 { accentPixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(Double(accentPixels) / Double(interior.width * interior.height), 0.55,
                                         "\(name): onAccent must have a visible accent body")
                    // Sample the core before the Search glyph, beyond the refractive rim band.
                    let bodyPixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: clear.minX + 9, y: clear.midY)))
                    if variant == .light {
                        XCTAssertGreaterThan(bodyPixel.r, 30, "\(name): Clear must draw over black")
                    } else {
                        XCTAssertLessThan(bodyPixel.r, 225, "\(name): Clear must draw over white")
                    }
                    XCTAssertTrue(registeredAnchors.isSuperset(of: anchors), "\(name): bud anchors must follow placement")
                }
            }
        }
    }
    func testLibraryRootChromeSnapshots() async throws {
        try XCTSkipUnless(NibSnapshot.supportsHostedImages, "Library compositor snapshots require an app-hosted window scene; validate them in simulator captures.")
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        model.setView(["sidebar": false])
        for compact in [false, true] {
            for variant in [NibSnapshot.Variant.light, .dark] {
                let rendered = try await NibSnapshot.hostedImage(
                    LibraryRootView(model: model), size: CGSize(width: compact ? 390 : 1024, height: compact ? 844 : 768),
                    variant: variant)
                let image = try XCTUnwrap(rendered)
                let attachment = XCTAttachment(image: image)
                attachment.name = "library-root-\(compact ? "iphone" : "ipad")-\(variant.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
    func testTintedButtonHasAccentBeforeDropletRegistration() throws {
        let field = DropletField()
        let image = try XCTUnwrap(NibSnapshot.image(
            NibDropletButton(id: "new", title: "New", symbol: .plus, kind: .tinted) {}
                .environment(field).background(NibColor.background), size: CGSize(width: 96, height: 44)))
        let attachment = XCTAttachment(image: image)
        attachment.name = "library-new-before-registration"
        attachment.lifetime = .keepAlways
        add(attachment)
        var accentPixels = 0
        for y in 8..<36 {
            for x in 8..<88 {
                let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                if Int(pixel.b) - Int(pixel.r) > 50 && Int(pixel.b) - Int(pixel.g) > 30 { accentPixels += 1 }
            }
        }
        XCTAssertGreaterThan(accentPixels, 800, "The button needs an accent body beneath its white glyphs.")
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
    func testLibraryWindowListsNilKindChromeOverlaysInRegistryOrder() throws {
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        let navigator = LibraryTestNavigator(app: h.app, session: h.session)
        model.navigator = navigator
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.libraryStatus", owner: "test", placement: .topTrailing, surface: .none, order: 20,
            isVisible: { $0.kind == nil && !$0.isCompact }) { _ in AnyView(EmptyView()) })
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.libraryStatusCompact", owner: "test", placement: .bottomTrailing, surface: .pill, order: 20,
            isVisible: { $0.kind == nil && $0.isCompact }) { _ in AnyView(EmptyView()) })
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.containerBanner", owner: "test", placement: .topLeading, surface: .none, order: 10,
            isInteractive: false, isVisible: { $0.kind == nil }) { _ in AnyView(EmptyView()) })
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.documentOnly", owner: "test", placement: .top, docKinds: [.notebook]) { _ in AnyView(EmptyView()) })
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.hidden", owner: "test", placement: .center,
            isVisible: { _ in false }) { _ in AnyView(EmptyView()) })

        let context = model.chromeContext(isCompact: false)
        XCTAssertNil(context.kind)
        XCTAssertTrue(context.app === h.app)
        XCTAssertTrue(context.session === h.session)
        XCTAssertTrue(context.navigator === navigator)
        let overlays = model.visibleChromeOverlays(context)
        XCTAssertEqual(overlays.map(\.id), ["test.containerBanner", "test.libraryStatus"])
        XCTAssertEqual(overlays.map(\.placement), [.topLeading, .topTrailing])
        XCTAssertEqual(overlays.map(\.surface), [.none, .none])
        XCTAssertFalse(try XCTUnwrap(overlays.first).isInteractive)
        XCTAssertEqual(model.visibleChromeOverlays(model.chromeContext(isCompact: true)).map(\.id),
                       ["test.containerBanner", "test.libraryStatusCompact"])
    }
    func testLibraryChromeRefreshesForItsWindowSessionAndRegistryReplacement() async throws {
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        var show = false
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.live", owner: "test", placement: .topLeading,
            isVisible: { $0.kind == nil && (show || $0.session.readOnly) }) { _ in AnyView(EmptyView()) })
        for _ in 0..<30 { await Task.yield() }
        let context = model.chromeContext(isCompact: false)
        XCTAssertTrue(model.visibleChromeOverlays(context).isEmpty)
        let revision = model.registryRevision
        h.app.ui.setNeedsChromeUpdate(EditorSession())
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.registryRevision, revision, "Another window must not invalidate this library")
        show = true
        h.app.ui.setNeedsChromeUpdate(h.session)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertGreaterThan(model.registryRevision, revision)
        XCTAssertEqual(model.visibleChromeOverlays(context).map(\.id), ["test.live"])
        show = false
        let sessionRevision = model.registryRevision
        h.session.readOnly = true
        for _ in 0..<30 { await Task.yield() }
        XCTAssertGreaterThan(model.registryRevision, sessionRevision)
        XCTAssertEqual(model.visibleChromeOverlays(context).map(\.id), ["test.live"])

        let generation = h.app.ui.chromeOverlays.generation
        let registryRevision = model.registryRevision
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.live", owner: "test", placement: .bottomTrailing, surface: .bar,
            isVisible: { $0.kind == nil }) { _ in AnyView(EmptyView()) })
        for _ in 0..<30 { await Task.yield() }
        XCTAssertGreaterThan(h.app.ui.chromeOverlays.generation, generation)
        XCTAssertGreaterThan(model.registryRevision, registryRevision)
        let replacement = try XCTUnwrap(model.visibleChromeOverlays(context).first)
        XCTAssertEqual(replacement.placement, .bottomTrailing)
        XCTAssertEqual(replacement.surface, .bar)
        h.app.ui.chromeOverlays.unregister(id: "test.live")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(model.visibleChromeOverlays(context).isEmpty)
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
        let previousSort = model.sort
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
        XCTAssertNil(h.app.settings.json(LibraryOrder.key(nil)))
        XCTAssertEqual(model.sort, previousSort)
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
        let closed = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.sheet", "close": true], session: h.session)
        XCTAssertEqual(closed["closed"], .bool(true))
        XCTAssertNil(model.modal)
        XCTAssertFalse(h.session.openPanels.contains("test.sheet"))
        XCTAssertTrue(h.session.openPanels.contains(PanelIDs.trash))
    }
    func testClosingRegisteredSheetThatIsNotOpenReturnsFalse() async throws {
        let h = harness()
        h.app.ui.panels.register(PanelDescriptor(id: "test.sheet", title: "Sheet", icon: NibSymbol.folder.name, placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        let result = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.sheet", "close": true], session: h.session)
        XCTAssertEqual(result["panel"], "test.sheet")
        XCTAssertEqual(result["closed"], .bool(false))
        XCTAssertNil(LibraryModels.get(h.app).model(h.session).modal)
        XCTAssertFalse(h.session.openPanels.contains("test.sheet"))
    }
    func testClosingUnregisteredPanelThatIsNotOpenReturnsFalse() async throws {
        let h = harness()
        let result = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.unknown", "close": true], session: h.session)
        XCTAssertEqual(result["panel"], "test.unknown")
        XCTAssertEqual(result["closed"], .bool(false))
        XCTAssertTrue(h.session.openPanels.isEmpty)
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
    func testCoverUsesFirstPageWithoutQueryGetAndSharesCacheAcrossWindows() async throws {
        let h = harness(), renderer = LibraryTestRenderer()
        h.app.services.renderer = renderer
        XCTAssertNil(h.app.commands.descriptor(CommandIDs.queryGet))
        let model = LibraryModels.get(h.app).model(h.session)
        let row = try XCTUnwrap(h.library.node(Fixtures.docID)).mapRow
        let image = await model.coverCache.thumbnail(row, app: h.app)
        XCTAssertNotNil(image)
        XCTAssertEqual(renderer.requests.count, 1)
        XCTAssertEqual(renderer.requests.first?.0, Fixtures.docID)
        XCTAssertEqual(renderer.requests.first?.1, try h.app.workspace.peekContent(Fixtures.docID).pages.first?.id)
        XCTAssertTrue(h.app.workspace.cachedPages(Fixtures.docID).isEmpty)
        let other = EditorSession(); h.app.services.sessions.add(other)
        XCTAssertTrue(LibraryModels.get(h.app).model(other).coverCache === model.coverCache)
    }
    func testDocumentCountsDoNotOpenDocumentsAndInvalidateWithTheirCover() throws {
        let h = harness()
        let cache = LibraryModels.get(h.app).coverCache
        var row = LibraryRow.from(try XCTUnwrap(h.library.node(Fixtures.studySetID)))
        let loaded = h.app.workspace.loadedDocuments
        XCTAssertEqual(cache.subtitle(row, app: h.app), "2 cards")
        XCTAssertEqual(Set(h.app.workspace.loadedDocuments), Set(loaded))
        var content = try h.persistence.loadHead(Fixtures.studySetID)
        content.cards[0].deleted = true
        h.persistence.heads[Fixtures.studySetID] = content
        XCTAssertEqual(cache.subtitle(row, app: h.app), "2 cards")
        cache.invalidate(Fixtures.studySetID)
        XCTAssertEqual(cache.subtitle(row, app: h.app), "1 card")
        row.locked = true
        XCTAssertNil(cache.subtitle(row, app: h.app))
        XCTAssertEqual(Set(h.app.workspace.loadedDocuments), Set(loaded))
    }
    func testSessionModelReleasedAfterControllerAndSessionRemoval() async throws {
        let h = harness(), session = EditorSession()
        h.app.services.sessions.add(session)
        var controller: LibraryRootViewController? = LibraryRootViewController(app: h.app, navigator: LibraryTestNavigator(app: h.app, session: session))
        weak var model = controller?.model
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["layout": "list"], session: session)
        XCTAssertEqual(model?.layout, .list)
        h.app.services.sessions.remove(session)
        controller = nil
        XCTAssertNil(model)
        XCTAssertNil(LibraryModels.get(h.app).models[session.id])
    }
    func testDryRunSetViewValidatesWithoutMutatingOrPresenting() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.ui.panels.register(PanelDescriptor(id: "test.dry", title: "Dry", icon: NibSymbol.folder.name, placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        let before = h.app.settings.json(LibraryOrder.viewKey(Fixtures.folderID))
        let result = try await h.app.bus.execute(Invocation(command: CommandIDs.librarySetView,
            params: ["folder": "folder:FIXTUREFLD01", "layout": "list", "sort": "name", "panel": "test.dry", "params": ["hello": true]], session: h.session, dryRun: true))
        XCTAssertEqual(result.value["placement"], "sheet")
        XCTAssertNil(model.folder); XCTAssertNil(model.modal)
        XCTAssertEqual(model.layout, .grid)
        XCTAssertTrue(h.session.openPanels.isEmpty)
        XCTAssertEqual(h.app.settings.json(LibraryOrder.viewKey(Fixtures.folderID)), before)
    }
    func testFolderNavigationClosesTabInSession() async throws {
        let h = harness()
        h.app.ui.panels.register(PanelDescriptor(id: "test.tab", title: "Tab", icon: NibSymbol.folder.name, placement: .libraryTab, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.tab"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        XCTAssertFalse(h.session.openPanels.contains("test.tab"))
    }
    func testOffscreenChangesAndCommitsDoNotQueryCatalogAndSelectionDoesNotSort() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        var requests: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryList, title: "List", summary: "Record list requests", effect: .read, target: .library)) { params, _ in
            requests.append(params)
            return ["nodes": try JSONValue.from(h.library.children(of: nil).map(LibraryRow.from))]
        }
        await model.reload()
        XCTAssertEqual(requests.last?["kinds"], ["folder"])
        requests = []
        let passes = model.sortPasses
        for _ in 0..<10 {
            h.app.events.emit(NibEventType.committed, doc: Fixtures.docID)
            _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "toggle", "refs": ["doc:FIXTUREDOC01"]], session: h.session)
        }
        h.app.events.emit(NibEventType.libraryChanged)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.sortPasses, passes)
        await model.appear()
        XCTAssertEqual(requests.count, 2)
    }
    func testReorderUndoAfterTrashingSiblingRestoresSortAndAbsentOrder() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.reload()
        let result = try await h.app.bus.execute(CommandIDs.libraryReorder, ["refs": ["doc:FIXTUREDOC01"]], session: h.session)
        let sibling = try XCTUnwrap(model.rows.first { !$0.isFolder && $0.nodeID != Fixtures.docID })
        try h.library.trash(sibling.nodeID)
        _ = try await h.app.bus.execute(CommandIDs.libraryReorder, try XCTUnwrap(result["undo"]), session: h.session)
        XCTAssertEqual(model.sort, .modified)
        XCTAssertNil(h.app.settings.json(LibraryOrder.key(nil)))
        XCTAssertEqual(result["previousSort"], "modified")
        XCTAssertEqual(result["hadOrder"], false)
    }

    func testShowLibraryWithoutInvokingOrRegisteredSessionUsesNavigatorWindow() async throws {
        let h = harness()
        let window = LibraryTestNavigator(app: h.app, session: h.session)
        h.app.ui.activeNavigator = window
        h.app.services.sessions.remove(h.session)
        await FeatLibraryUIFeature.start(h.app)
        _ = try await h.app.bus.execute(CommandIDs.windowShowLibrary, ["folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(LibraryModels.get(h.app).model(h.session).folder, Fixtures.folderID)
    }
    func testDropRoutesFolderRootTrashAndSelectedCombine() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.reload()
        var commands: [(String, JSONValue)] = []
        for id in [CommandIDs.libraryMove, CommandIDs.libraryTrash] {
            h.app.commands.register(CommandDescriptor(id: id, title: "Drop", summary: "Record drop routing", effect: .library, target: .library)) { params, _ in
                commands.append((id, params)); return [:]
            }
        }
        let refs = model.documentRefs
        model.reflow.layout = NibReflowLayout(columns: 3, cell: NibMetrics.coverSize)
        for destination in ["folder:FIXTUREFLD01", "lib", "trash"] {
            model.reflow.begin(refs[0], order: refs, at: .zero)
            model.dropTarget = destination
            model.dropFrame = CGRect(x: 10, y: 10, width: 20, height: 20)
            model.drop(.none)
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(commands.last?.0, destination == "trash" ? CommandIDs.libraryTrash : CommandIDs.libraryMove)
            XCTAssertEqual(commands.last?.1["refs"], .array([.string(refs[0])]))
            XCTAssertEqual(commands.last?.1["folder"], destination == "lib" || destination == "trash" ? nil : .string(destination))
            XCTAssertNil(model.dropTarget); XCTAssertNil(model.dropFrame)
            XCTAssertNotNil(model.floating.toast)
            model.reflow.cancel()
        }
        model.selection.refs = Set(refs.prefix(2))
        model.drop(.combine(refs[0], into: refs[2]))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(commands.last?.1["refs"], .array(refs.prefix(2).map(JSONValue.string)))
        XCTAssertEqual(commands.last?.1["folder"], .string(refs[2]))
    }
    func testDropOptimisticReorderAndFailureReload() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        let refs = model.documentRefs
        let move = NibReflowMove(id: refs[0], from: 0, to: refs.count - 1, in: refs)
        var request: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryReorder, title: "Reorder", summary: "Fail after recording", effect: .library, target: .library)) { params, _ in
            request = params; throw NibError.unavailable("Reorder failed")
        }
        model.drop(.reorder(move))
        XCTAssertEqual(model.documentRefs.last, refs[0])
        for _ in 0..<60 { await Task.yield() }
        XCTAssertEqual(request, LibraryOrder.moveParams(move, folder: nil))
        XCTAssertEqual(model.documentRefs, refs)
        XCTAssertEqual(model.floating.toast?.message, NibError.unavailable("Reorder failed").message)
    }
    func testMovePickerCreateThenMoveIntoNewFolder() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        var commands: [(String, JSONValue)] = []
        for id in [CommandIDs.folderCreate, CommandIDs.libraryMove] {
            h.app.commands.register(CommandDescriptor(id: id, title: "Picker", summary: "Record picker commands", effect: .library, target: .library)) { params, _ in
                commands.append((id, params)); return id == CommandIDs.folderCreate ? ["ref": "folder:NEWFOLDER01"] : [:]
            }
        }
        let result = try await MovePickerActions.createFolder(title: "New folder", destination: "folder:FIXTUREFLD01", model: model)
        XCTAssertEqual(commands.last?.1, ["title": "New folder", "parent": "folder:FIXTUREFLD01"])
        try await MovePickerActions.move(refs: ["doc:FIXTUREDOC01"], destination: try XCTUnwrap(result["ref"]?.stringValue), model: model)
        XCTAssertEqual(commands.last?.1, ["refs": ["doc:FIXTUREDOC01"], "folder": "folder:NEWFOLDER01"])
        try await MovePickerActions.move(refs: ["doc:FIXTUREDOC01"], destination: "lib", model: model)
        XCTAssertNil(commands.last?.1["folder"])
    }

}

@MainActor
private struct LibraryChromeFieldProbe: View {
    @Environment(DropletField.self) private var field: DropletField?
    let ids: [String]
    let anchors: [String]
    let capture: (DropletField) -> Void

    private var ready: Bool {
        guard let field else { return false }
        return ids.allSatisfy { field.node($0).presentation.isDrawn }
            && anchors.allSatisfy { field.worldAnchors[$0] != nil }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: ready, initial: true) { _, ready in
                if ready, let field { capture(field) }
            }
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

private extension LibraryNode { var mapRow: LibraryRow { LibraryRow.from(self) } }

private final class LibraryTestRenderer: PageRenderer {
    var requests: [(DocumentID, PageID, Int)] = []
    func render(_ request: RenderRequest) async throws -> RenderResult { throw NibError.unavailable("Unused in this test") }
    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        requests.append((doc, page, maxPixelSize))
        return CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() {}
}
