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
    func testReturnOpensSelectedFolderAndDocumentThroughCommands() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "replace", "refs": ["folder:FIXTUREFLD01"]], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["openSelected": true], session: h.session)
        XCTAssertEqual(model.folder, Fixtures.folderID)
        XCTAssertFalse(model.selection.isSelecting)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "lib"], session: h.session)
        let ref = try XCTUnwrap(model.documentRefs.first)
        var opened: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docOpen, title: "Open", summary: "Record opening", effect: .session, target: .app)) { params, _ in
            opened = params; return [:]
        }
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "replace", "refs": [.string(ref)]], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["openSelected": true], session: h.session)
        XCTAssertEqual(opened?["doc"], .string(ref))
        XCTAssertFalse(model.selection.isSelecting)
    }

    func testNewFolderPanelDefaultsToVisibleParentButPreservesExplicitParent() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.ui.panels.register(PanelDescriptor(id: "organize.folder.new", title: "New Folder", icon: "folder", placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "organize.folder.new"], session: h.session)
        XCTAssertEqual(model.modal?.params["folder"], "folder:FIXTUREFLD01")
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "organize.folder.new", "params": ["folder": "lib"]], session: h.session)
        XCTAssertEqual(model.modal?.params["folder"], "lib")
    }

    func testAccessibilityReflowStepUsesSameDropAndHonoursBothBoundaries() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        let refs = model.documentRefs
        var drops: [NibReflowDrop<String>] = []
        model.reflow.step(refs[0], by: -1, order: refs) { drops.append($0) }
        model.reflow.step(refs.last!, by: 1, order: refs) { drops.append($0) }
        XCTAssertTrue(drops.isEmpty)
        model.reflow.step(refs[1], by: -1, order: refs) { drops.append($0) }
        XCTAssertEqual(drops, [.reorder(NibReflowMove(id: refs[1], from: 1, to: 0, in: refs))])
    }


    func testExternalImportUsesVisibleFolderAndPreservesExplicitDestination() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.windowShowLibrary, title: "Library", summary: "Show library", effect: .session, target: .app)) { _, _ in [:] }
        var imported: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.importFiles, title: "Import", summary: "Record destination", effect: .library, target: .library)) { params, _ in imported = params; return [:] }
        await FeatLibraryUIFeature.start(h.app)
        model.folder = Fixtures.folderID
        _ = try await h.app.bus.execute(CommandIDs.importFiles, ["urls": ["tmp:fixture.pdf"]], session: h.session)
        XCTAssertEqual(imported?["folder"], "folder:FIXTUREFLD01")
        _ = try await h.app.bus.execute(CommandIDs.importFiles, ["urls": ["tmp:fixture.pdf"], "folder": "lib"], session: h.session)
        XCTAssertEqual(imported?["folder"], "lib")
        _ = try await h.app.bus.execute(CommandIDs.importFiles, ["urls": ["tmp:fixture.pdf"], "doc": "doc:FIXTUREDOC01"], session: h.session)
        XCTAssertNil(imported?["folder"])
        XCTAssertEqual(imported?["doc"], "doc:FIXTUREDOC01")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLibraryUIFeature.self])
        XCTAssertEqual(problems, [])
    }
    func testLibraryChromeLayoutRegistersAndDrawsItsDropletBodies() async throws {
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
                    var registeredAnchors: [String: CGRect] = [:]
                    var registeredStyles: [String: DropletStyle] = [:]
                    var presentations: [String: DropletPresentation] = [:]
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
                                    // Inspect registrations from the production view, not hand-built test droplets.
                                    let entries = Mirror(reflecting: field).children.first { $0.label == "entries" }?.value
                                        as? [String: DropletField.Entry]
                                    registeredStyles = entries?.mapValues(\.style) ?? [:]
                                    for id in ids {
                                        presentations[id] = field.node(id).presentation
                                        registeredFrames[id] = field.visualFrame(id)
                                        if field.node(id).presentation.isDrawn { drawnIDs.insert(id) }
                                    }
                                    registeredAnchors = field.worldAnchors
                                }
                                NibFloatingLayer(host: model.floating)
                            }
                        }
                    }
                    .coordinateSpace(name: "library.chrome")
                    .onPreferenceChange(LibraryChromeFrames.self) { model.updateMenuAnchors(from: $0) }
                    .nibLiquidMode(mode)
                    .environment(\.horizontalSizeClass, compact ? .compact : .regular)
                    let image = try await hostlessLayoutImage(view, size: size, variant: variant)
                    let name = "library-chrome-\(compact ? "iphone" : "ipad")-\(variant.rawValue)-\(mode.rawValue)"
                    if mode == .off {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = name
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }

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

                    let clearStyle = try XCTUnwrap(registeredStyles["library.controls"])
                    let tintedStyle = try XCTUnwrap(registeredStyles["library.new.button"])
                    XCTAssertEqual(clearStyle.material, .clear)
                    XCTAssertEqual(tintedStyle.material, .tinted)
                    XCTAssertTrue(tintedStyle.systemGlassSpec.tintsAccent)
                    for id in ids {
                        let style = try XCTUnwrap(registeredStyles[id])
                        let presentation = try XCTUnwrap(presentations[id])
                        XCTAssertTrue(DropletBodyModifier.drawsBody(style: style, presentation: presentation), id)
                        XCTAssertEqual(presentation.bodySize, presentation.restSize, "Resting bodies must cover their controls")
                    }
                    let traits = UITraitCollection(userInterfaceStyle: variant == .dark ? .dark : .light)
                    let accent = NibGlassBodyTint.resolvedColor(tintedStyle.glassKind, colorScheme: variant.colorScheme)
                    XCTAssertEqual(accent, NibUIColor.accent.resolvedColor(with: traits))
                    XCTAssertEqual(accent.cgColor.alpha, 1, accuracy: 0.001)
                    let clearBody = NibGlassBodyTint.resolvedColor(clearStyle.glassKind, colorScheme: variant.colorScheme)
                    XCTAssertEqual(clearBody, NibUIColor.clearBody.resolvedColor(with: traits))
                    XCTAssertEqual(clearBody.cgColor.alpha, variant == .dark ? 0.62 : 0.46, accuracy: 0.001,
                                   "Clear must retain its specified body opacity over ink/paper")
                    // System glass requires a compositor; the off mode is ordinary hostless-renderable content.
                    if mode == .off {
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
                    }
                    XCTAssertTrue(Set(registeredAnchors.keys).isSuperset(of: anchors), "\(name): bud anchors must follow placement")
                    XCTAssertEqual(try XCTUnwrap(registeredAnchors["library.new"]), tinted,
                                   "\(name): New must anchor to its actual button")
                    if !compact {
                        let sort = try XCTUnwrap(registeredAnchors["library.sort"])
                        XCTAssertEqual(sort.midX, clear.midX, accuracy: 0.5, name)
                        XCTAssertEqual(sort.midY, clear.midY, accuracy: 0.5, name)
                        XCTAssertEqual(sort.width, NibMetrics.hitTarget, accuracy: 0.5, name)
                        XCTAssertEqual(sort.height, NibMetrics.hitTarget, accuracy: 0.5, name)
                    }
                }
            }
        }
    }
    func testLibraryRootMenusRestBesideTheirActualSources() async throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            for variant in [NibSnapshot.Variant.light, .dark] {
                for mode in [NibLiquidMode.full, .off] {
                    for menu in ["new", "sort"] {
                        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
                        model.sidebarVisible = false
                        model.liquidMode = mode
                        // Exercise a request before the first layout as well as the settled presentation.
                        model.menu = menu
                        let source = "library." + menu, popover = "library." + menu + ".menu"
                        var capturedField: DropletField?
                        var anchorFrames: [String: CGRect] = [:]
                        var presentedFrames: [String: CGRect] = [:]
                        var menuIsDrawn = false
                        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
                            id: "test.menuGeometry", owner: "test", placement: .center, surface: .none,
                            isInteractive: false) { _ in
                                AnyView(LibraryChromeFieldProbe(
                                    ids: ["library.controls", "library.new.button", popover],
                                    anchors: ["library.new", "library.sort"]) { capturedField = $0 })
                            })
                        // Full-mode buds advance only in an active scene. A hostless
                        // UIWindow otherwise leaves the display link parked, so it
                        // cannot represent the foreground menu this test measures.
                        _ = try await hostlessLayoutImage(LibraryRootView(model: model, idiom: .pad)
                            .environment(\.scenePhase, .active), size: size,
                                                          variant: variant, settlePasses: mode == .full ? 60 : 10) {
                            guard let field = capturedField else { return }
                            anchorFrames = field.worldAnchors
                            for id in ["library.controls", "library.new.button", popover] {
                                presentedFrames[id] = field.visualFrame(id)
                            }
                            menuIsDrawn = field.node(popover).presentation.isDrawn
                        }
                        let name = "\(menu)-\(size)-\(variant.rawValue)-\(mode.rawValue)"
                        let anchor = try XCTUnwrap(anchorFrames[source], name)
                        let controls = try XCTUnwrap(presentedFrames["library.controls"], name)
                        let newButton = try XCTUnwrap(presentedFrames["library.new.button"], name)
                        XCTAssertEqual(try XCTUnwrap(anchorFrames["library.new"]), newButton, name)
                        let sort = try XCTUnwrap(anchorFrames["library.sort"], name)
                        XCTAssertEqual(sort.midX, controls.midX, accuracy: 0.5, name)
                        XCTAssertEqual(sort.midY, controls.midY, accuracy: 0.5, name)
                        XCTAssertEqual(sort.size.width, NibMetrics.hitTarget, accuracy: 0.5, name)
                        XCTAssertEqual(sort.size.height, NibMetrics.hitTarget, accuracy: 0.5, name)
                        XCTAssertGreaterThan(anchor.minX, size.width / 2, name)
                        XCTAssertLessThan(anchor.maxY, size.height / 2, name)

                        let frame = try XCTUnwrap(presentedFrames[popover], name)
                        XCTAssertTrue(menuIsDrawn, name)
                        XCTAssertEqual(frame.width, NibMetrics.popoverWidth, accuracy: 0.5, name)
                        XCTAssertGreaterThan(frame.height, 0, name)
                        XCTAssertEqual(frame.minY - anchor.maxY, NibMetrics.popoverGap, accuracy: 0.5, name)
                        let inset = NibMetrics.chromeInset
                        let expectedX = min(anchor.midX, size.width - inset - frame.width / 2)
                        XCTAssertEqual(frame.midX, expectedX, accuracy: 0.5, name)
                        XCTAssertGreaterThanOrEqual(frame.minX, inset - 0.5, name)
                        XCTAssertLessThanOrEqual(frame.maxX, size.width - inset + 0.5, name)
                        XCTAssertGreaterThanOrEqual(frame.minY, inset - 0.5, name)
                        XCTAssertLessThanOrEqual(frame.maxY, size.height - inset + 0.5, name)
                    }
                }
            }
        }
    }

    func testLibraryMenuWaitsForUsableSourceGeometry() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        model.menu = "new"
        model.updateMenuAnchors(from: ["anchor.library.new": .zero])
        var capturedField: DropletField?
        let view = NibDropletContainer {
            LibraryBuds(model: model)
            LibraryChromeFieldProbe(ids: [], anchors: []) { capturedField = $0 }
            NibFloatingLayer(host: model.floating)
        }.nibLiquidMode(.off)
        _ = try await hostlessLayoutImage(view, size: CGSize(width: 834, height: 1194), variant: .light)
        let field = try XCTUnwrap(capturedField)
        XCTAssertFalse(field.node("library.new.menu").presentation.isDrawn)
        XCTAssertNil(model.menuAnchors["library.new"])
        XCTAssertNil(model.floating.anchors["library.new"])
        XCTAssertEqual(model.menu, "new", "Keep the request pending until layout publishes its source")

        model.updateMenuAnchors(from: ["anchor.library.new": CGRect(x: 700, y: 16, width: 96, height: 44)])
        XCTAssertNotNil(model.menuAnchors["library.new"])
        XCTAssertNotNil(model.floating.anchors["library.new"])
        model.updateMenuAnchors(from: [:])
        XCTAssertTrue(model.menuAnchors.isEmpty)
        XCTAssertNil(model.floating.anchors["library.new"], "A removed control must not retain a stale source")
    }

    func testClosedLibraryMenusLetTouchesReachDocuments() async throws {
        for mode in [NibLiquidMode.full, .off] {
            let h = harness(), model = LibraryModels.get(h.app).model(h.session)
            for location in [MenuLocation.libraryNew, .appMenu] {
                h.app.ui.menus.register(MenuItemDescriptor(
                    id: "hit-test." + location.rawValue, title: "Menu action", location: location, order: 0,
                    owner: FeatLibraryUIFeature.id, command: CommandIDs.librarySetView,
                    params: { _ in ["menu": "none"] }))
            }
            let document = UIButton(type: .custom)
            let anchor = CGRect(x: 700, y: 24, width: 44, height: 44)
            model.updateMenuAnchors(from: Dictionary(uniqueKeysWithValues:
                ["new", "app", "sort"].map { ("anchor.library." + $0, anchor) }))
            let view = ZStack {
                LibraryHitTestDocument(button: document)
                NibDropletContainer {
                    ForEach(["new", "app", "sort"], id: \.self) { menu in
                        Color.clear.frame(width: anchor.width, height: anchor.height)
                            .nibBudAnchor("library." + menu)
                            .position(x: anchor.midX, y: anchor.midY)
                            .allowsHitTesting(false)
                    }
                    LibraryBuds(model: model)
                    NibFloatingLayer(host: model.floating)
                }
            }.nibLiquidMode(mode)
                .ignoresSafeArea()
            let host = UIHostingController(rootView: view.environment(\.scenePhase, .inactive))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds

            func settle() async throws {
                for _ in 0..<30 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            func assertDocumentsAreHittable(file: StaticString = #filePath, line: UInt = #line) {
                // Cover the full area occupied by each menu's native scroll view,
                // including the card location from the failed canvas test.
                for y in stride(from: 100, through: Int(host.view.bounds.maxY) - 50, by: 100) {
                    for x in stride(from: 100, through: Int(host.view.bounds.maxX) - 50, by: 100) {
                        let hit = host.view.hitTest(CGPoint(x: x, y: y), with: nil)
                        XCTAssertTrue(hit === document || hit?.isDescendant(of: document) == true,
                                      "Closed menus intercepted (\(x), \(y)): \(String(describing: hit))",
                                      file: file, line: line)
                    }
                }
            }

            try await settle()
            assertDocumentsAreHittable()
            host.rootView = view.environment(\.scenePhase, .active)
            try await settle()
            assertDocumentsAreHittable()
            for menu in ["new", "app", "sort"] {
                model.menu = menu
                try await settle()
                let hit = host.view.hitTest(CGPoint(x: anchor.midX, y: anchor.maxY + 110), with: nil)
                XCTAssertNotNil(hit)
                XCTAssertFalse(hit === document || hit?.isDescendant(of: document) == true,
                               "An open \(menu) menu must accept interaction")
                model.menu = nil
                try await settle()
                assertDocumentsAreHittable()
            }
            // A pending request without its source geometry must also pass through.
            model.updateMenuAnchors(from: [:])
            model.menu = "sort"
            try await settle()
            assertDocumentsAreHittable()

            // SelectionUITests opens a notebook after rotating the library. Keep the
            // same menu hosts alive across the resize, including loss/republication
            // of their source geometry, rather than testing a fresh landscape host.
            model.menu = nil
            for size in [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)] {
                window.frame = CGRect(origin: .zero, size: size)
                host.view.frame = window.bounds
                model.updateMenuAnchors(from: [:])
                try await settle()
                assertDocumentsAreHittable()
                model.updateMenuAnchors(from: Dictionary(uniqueKeysWithValues:
                    ["new", "app", "sort"].map { ("anchor.library." + $0, anchor) }))
                try await settle()
                assertDocumentsAreHittable()
            }
            // The centre of Physics — Motion in both reported setup failures.
            let hit = host.view.hitTest(CGPoint(x: 906, y: 549.75), with: nil)
            XCTAssertTrue(hit === document || hit?.isDescendant(of: document) == true,
                          "Hidden library menus must not intercept the notebook-opening tap")

            // Insert setup can show a system permission sheet before opening a
            // document. Its inactive/active cycle must not restore an invisible
            // full-window menu hit surface, even while rotating or losing anchors.
            for phase in [ScenePhase.inactive, .background, .active] {
                host.rootView = view.environment(\.scenePhase, phase)
                model.updateMenuAnchors(from: [:])
                try await settle()
                assertDocumentsAreHittable()
                model.updateMenuAnchors(from: Dictionary(uniqueKeysWithValues:
                    ["new", "app", "sort"].map { ("anchor.library." + $0, anchor) }))
                try await settle()
                assertDocumentsAreHittable()
            }
        }
    }

    func testLibraryRootChromeSnapshots() async throws {
        let h = harness()
        let model = LibraryModels.get(h.app).model(h.session)
        model.sidebarVisible = false
        model.liquidMode = .off
        for compact in [false, true] {
            for variant in [NibSnapshot.Variant.light, .dark] {
                let size = CGSize(width: compact ? 390 : 1024, height: compact ? 844 : 768)
                let image = try await hostlessLayoutImage(
                    LibraryRootView(model: model, idiom: compact ? .phone : .pad), size: size, variant: variant)
                XCTAssertEqual(image.size, size)
                let background = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 2, y: size.height / 2)))
                XCTAssertGreaterThan(background.a, 250, "The root must render an opaque library surface")
                let attachment = XCTAttachment(image: image)
                attachment.name = "library-root-\(compact ? "iphone" : "ipad")-\(variant.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
    func testFolderTitlesFitTheirMeasuredGridCellsWithoutTruncation() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let rows = ["Research", "Semester Notes", "Reference notes", "Reading"].enumerated().map { index, title in
            LibraryRow(ref: "folder:TITLETEST0\(index)", kind: "folder", title: title)
        }
        model.rows = rows
        model.applySort()
        for compact in [false, true] {
            let width: CGFloat = compact ? 358 : 960
            for variant in NibSnapshot.Variant.allCases {
                var frames: [String: CGRect] = [:]
                let view = LibraryGridView(model: model)
                    .environment(\.horizontalSizeClass, compact ? .compact : .regular)
                    .onPreferenceChange(LibraryFrames.self) { frames = $0 }
                _ = try await hostlessLayoutImage(view, size: CGSize(width: width, height: 768), variant: variant)
                var font = NibUIFont.button
                UITraitCollection(preferredContentSizeCategory: variant == .largeText ? .accessibilityExtraLarge : .large)
                    .performAsCurrent { font = NibUIFont.button }
                for row in rows {
                    let frame = try XCTUnwrap(frames[row.ref], "Every folder must be laid out")
                    let textWidth = (row.name as NSString).size(withAttributes: [.font: font]).width
                    let required = ceil(textWidth) + NibMetrics.hitTarget + NibSpacing.m + 2 * NibSpacing.l
                    XCTAssertGreaterThanOrEqual(frame.width, required,
                                                "\(row.name) must fit without an ellipsis (\(variant), compact: \(compact))")
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
                }
            }
        }
    }

    /// No app-supplied UIWindowScene is needed (UIKit may attach an internal legacy scene).
    /// Native glass is checked structurally; off-mode pixels and UIKit navigation/scroll views
    /// can be captured directly from their laid-out layers.
    private func hostlessLayoutImage<V: View>(_ view: V, size: CGSize,
                                             variant: NibSnapshot.Variant, settlePasses: Int = 5,
                                             inspect: () -> Void = {}) async throws -> UIImage {
        let host = UIHostingController(rootView: view.ignoresSafeArea()
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.backgroundColor = .clear
        for _ in 0..<settlePasses {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        inspect()
        host.view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
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
    func testPhonePresentationSurvivesRotationAndShortWindowsStayCompact() {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 932, height: 430)] {
            XCTAssertTrue(LibraryPresentation.isCompact(size: size, idiom: .phone))
            XCTAssertTrue(LibraryPresentation.isCompact(size: size, idiom: .pad))
        }
        XCTAssertFalse(LibraryPresentation.isCompact(size: CGSize(width: 768, height: 1024), idiom: .pad))
        XCTAssertFalse(LibraryPresentation.isCompact(size: CGSize(width: 1194, height: 834), idiom: .pad))
    }

    func testBridgeStatusMovesToNavigationAndLeavesPhoneActionPairSeparate() throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 768, height: 1024)] {
            let compact = size.height < 600 || size.width < 600
            let controlsWidth: CGFloat = compact ? 104 : 252
            let view = LibraryChromeOverlayLayout(inlineSidebar: false, compact: compact, titleBottom: 180) {
                NibInk.cobalt.color.frame(width: controlsWidth, height: 44)
                    .layoutValue(key: LibraryChromeOverlaySlot.self,
                                 value: .init(placement: compact ? .bottomTrailing : .topTrailing, isControls: true))
                NibInk.vermilion.color.frame(width: 60, height: 40)
                    .layoutValue(key: LibraryChromeOverlaySlot.self, value: .init(placement: .topTrailing))
                NibInk.moss.color.frame(width: 44, height: 32)
                    .layoutValue(key: LibraryChromeOverlaySlot.self, value: .init(placement: .topTrailing))
            }.padding(NibSpacing.l).background(NibPaper.white.color)
            let image = try XCTUnwrap(NibSnapshot.image(view, size: size))
            let midY: CGFloat = compact ? size.height - 16 - 22 : 16 + 22
            let status = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: compact ? 16 + 30 : size.width - 16 - 44 - 16 - 30, y: midY)))
            let secondStatus = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: compact ? 16 + 60 + 16 + 22 : size.width - 16 - 22, y: midY)))
            let controls = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: compact ? size.width - 16 - controlsWidth / 2 : size.width - 16 - 44 - 16 - 60 - 16 - controlsWidth / 2, y: midY)))
            XCTAssertGreaterThan(Int(status.r) - Int(status.b), 80, "Status must align with the measured control row")
            XCTAssertGreaterThan(Int(secondStatus.g) - Int(secondStatus.b), 20, "Contributions must sit beside one another")
            XCTAssertGreaterThan(Int(controls.b) - Int(controls.r), 80)
            if compact {
                let searchRegion = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: size.width - 46, y: 202)))
                XCTAssertGreaterThan(searchRegion.r, 240, "Status must leave navigation and pull-down search clear")
            }
        }
    }

    func testPhoneStatusRemainsInNavigationWhileBrowserHasOnlySearchAndNew() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        for (id, placement) in [("test.sync", ChromePlacement.bottomTrailing), ("test.bridge", .topTrailing)] {
            h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
                id: id, owner: "test", placement: placement, surface: .none) { _ in
                    AnyView(Color.red.frame(width: 44, height: 44))
                })
        }
        for sidebar in [true, false] {
            model.sidebarVisible = sidebar
            var frames: [String: CGRect] = [:]
            let view = LibraryRootView(model: model, idiom: .phone)
                .onPreferenceChange(LibraryChromeFrames.self) { frames = $0 }
            _ = try await hostlessLayoutImage(view, size: CGSize(width: 393, height: 852), variant: .light)
            for id in ["test.sync", "test.bridge"] {
                XCTAssertEqual(frames["overlay." + id] != nil, sidebar)
            }
            if sidebar {
                XCTAssertNil(frames["bottom.controls"])
            } else {
                let controls = try XCTUnwrap(frames["bottom.controls"])
                XCTAssertEqual(controls.width, LibraryPresentation.actionPairWidth, accuracy: 0.5)
                XCTAssertEqual(controls.maxX, 393 - NibSpacing.l, accuracy: 0.5)
            }
        }
    }

    func testNewMenuViewportEndsBetweenRowsAndReservesContinuationCue() {
        for height: CGFloat in [220, 310, 415, 520, 800] {
            for rowHeight: CGFloat in [44, 52, 64] {
                let header: CGFloat = 66
                let layout = LibraryMenuViewport(available: height, count: 9, rowHeight: rowHeight, header: header)
                XCTAssertEqual(layout.viewportHeight.truncatingRemainder(dividingBy: rowHeight), 0)
                XCTAssertLessThanOrEqual(layout.height, min(height, NibMetrics.popoverMaxHeight))
                XCTAssertGreaterThanOrEqual(layout.viewportHeight, rowHeight)
                if layout.scrolls {
                    XCTAssertGreaterThanOrEqual(layout.height - header - layout.viewportHeight, NibSpacing.l + NibSpacing.m)
                } else {
                    XCTAssertEqual(layout.viewportHeight, 9 * rowHeight)
                }
            }
        }
        let shortMenu = LibraryMenuViewport(available: 520, count: 3, rowHeight: 44, header: 66)
        XCTAssertFalse(shortMenu.scrolls)
        XCTAssertEqual(shortMenu.viewportHeight, 132)
    }

    func testFolderStyleResolvesSymbolEmojiAndDefaultForBothLayouts() throws {
        var row = LibraryRow(ref: "folder:STYLECHECK01", kind: "folder", title: "Semester Notes", color: "#0066E0", icon: "graduationcap.fill")
        XCTAssertEqual(row.folderGlyph, .symbol(try XCTUnwrap(NibSymbol(systemName: "graduationcap.fill"))))
        XCTAssertEqual(UIColor(row.folderColor), try XCTUnwrap(RGBA(hex: "#0066E0")).uiColor)
        row.icon = "📚"
        XCTAssertEqual(row.folderGlyph, .emoji("📚"))
        row.icon = nil
        XCTAssertEqual(row.folderGlyph, .symbol(.folderFill))
    }

    func testFolderListRowDrawsTheStoredBlueGlyphInBothThemes() throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let row = LibraryRow(ref: "folder:STYLECHECK01", kind: "folder", title: "Semester Notes", color: "#0066E0", icon: "graduationcap.fill")
        for variant in [NibSnapshot.Variant.light, .dark] {
            let image = try XCTUnwrap(NibSnapshot.image(
                LibraryListRow(row: row, model: model).background(NibColor.background),
                size: CGSize(width: 400, height: 80), variant: variant))
            var bluePixels = 0
            for y in 8..<72 {
                for x in 8..<44 {
                    let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                    if Int(pixel.b) - Int(pixel.r) > 80 && Int(pixel.b) - Int(pixel.g) > 40 { bluePixels += 1 }
                }
            }
            XCTAssertGreaterThan(bluePixels, 40, "A generic grey folder must not replace the stored glyph colour")
        }
    }

    func testCompactHeightPresentsFoldersAboveThreeCompleteDocumentColumns() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let folder = LibraryRow(ref: "folder:LANDSCAPE01", kind: "folder", title: "Semester Notes")
        let documents = (0..<3).map {
            LibraryRow(ref: "doc:LANDSCAPE0\($0 + 2)", kind: "notebook", title: "Physics \($0)", pages: 12)
        }
        model.rows = [folder] + documents
        model.applySort()
        for width: CGFloat in [520, 656] {
            for variant in [NibSnapshot.Variant.light, .dark] {
                var frames: [String: CGRect] = [:]
                let view = LibraryGridView(model: model, compactHeight: true)
                    .environment(\.horizontalSizeClass, .compact)
                    .onPreferenceChange(LibraryFrames.self) { frames = $0 }
                _ = try await hostlessLayoutImage(view, size: CGSize(width: width, height: 393), variant: variant)
                let folderFrame = try XCTUnwrap(frames[folder.ref])
                let documentFrames = try documents.map { try XCTUnwrap(frames[$0.ref]) }.sorted { $0.minX < $1.minX }
                for frame in documentFrames {
                    XCTAssertGreaterThanOrEqual(frame.minY, folderFrame.maxY + NibSpacing.s)
                    XCTAssertEqual(frame.minY, documentFrames[0].minY, accuracy: 0.5, "All three covers must share the first document row")
                    XCTAssertEqual(frame.width, NibMetrics.coverSizeCompact.width, accuracy: 0.5)
                    XCTAssertGreaterThan(frame.height, NibMetrics.coverSizeCompact.height, "Keep title and metadata below the complete cover")
                    XCTAssertLessThanOrEqual(frame.maxY, 393, "The cover, title and metadata must fit initially")
                    XCTAssertLessThanOrEqual(frame.maxX, width)
                }
                XCTAssertEqual(documentFrames[0].minX, folderFrame.minX, accuracy: 0.5)
                for index in 1..<documentFrames.count {
                    XCTAssertEqual(documentFrames[index].minX - documentFrames[index - 1].maxX, NibSpacing.l, accuracy: 0.5)
                }
            }
        }
    }

    func testRootHidesBreadcrumbButFolderRetainsAncestorNavigation() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        model.sidebarVisible = false
        await model.appear()
        for folder in [nil, model.allFolders.first?.nodeID] {
            model.folder = folder
            var targets: [String: CGRect] = [:]
            var chrome: [String: CGRect] = [:]
            let view = LibraryRootView(model: model, idiom: .pad)
                .onPreferenceChange(LibraryTargets.self) { targets = $0 }
                .onPreferenceChange(LibraryChromeFrames.self) { chrome = $0 }
            _ = try await hostlessLayoutImage(view, size: CGSize(width: 834, height: 1194), variant: .light)
            XCTAssertEqual(targets["breadcrumb:lib"] != nil, folder != nil)
            if folder != nil {
                let back = try XCTUnwrap(chrome["parent.navigation"])
                let heading = try XCTUnwrap(chrome["title"])
                let metadata = try XCTUnwrap(chrome["metadata"])
                XCTAssertEqual(back.midY, heading.midY, accuracy: 0.5)
                XCTAssertLessThanOrEqual(back.maxX, heading.minX)
                XCTAssertLessThanOrEqual(back.maxY, metadata.minY)
            }
        }
        XCTAssertFalse(model.allFolders.isEmpty, "The ancestor check requires a folder fixture")
    }

    func testNestedFolderBackControlReturnsToImmediateParent() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        model.allFolders = [
            LibraryRow(ref: "folder:PARENTFOLD01", kind: "folder", title: "Semester"),
            LibraryRow(ref: "folder:CHILDFOLD001", kind: "folder", title: "Physics", parent: "folder:PARENTFOLD01")
        ]
        model.folder = NibID("CHILDFOLD001")
        XCTAssertEqual(model.parentNavigation?.title, "Semester")
        XCTAssertEqual(model.parentNavigation?.ref, "folder:PARENTFOLD01")
        model.folder = NibID("PARENTFOLD01")
        XCTAssertEqual(model.parentNavigation?.ref, "lib")
        model.folder = nil
        XCTAssertNil(model.parentNavigation)
    }

    func testCompactStorageNoticeFitsTwoCalloutLinesWithInlineAction() async throws {
        for width: CGFloat in [343, 361, 520] {
            for variant in [NibSnapshot.Variant.light, .dark] {
                var frames: [String: CGRect] = [:]
                let view = LibraryStorageNotice {}.coordinateSpace(name: "library.chrome")
                    .onPreferenceChange(LibraryChromeFrames.self) { frames = $0 }
                _ = try await hostlessLayoutImage(view, size: CGSize(width: width, height: 100), variant: variant)
                let message = try XCTUnwrap(frames["storage.message"])
                let action = try XCTUnwrap(frames["storage.action"])
                XCTAssertLessThanOrEqual(message.height, 2 * NibUIFont.callout.lineHeight + 1)
                XCTAssertGreaterThanOrEqual(action.minX, message.maxX + NibSpacing.s - 0.5)
                XCTAssertEqual(action.midY, message.midY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(action.height, NibMetrics.hitTarget)
                XCTAssertLessThanOrEqual(action.maxX, width)
            }
        }
    }

    func testStorageActionOpensDestinationWithFullWarningAndRecoveryChoices() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.ui.panels.register(PanelDescriptor(id: PanelIDs.cloudBackup, title: "Cloud & Backup", icon: NibSymbol.folder.name,
            placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        model.openStorageDetails()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.modal?.id, PanelIDs.cloudBackup)
        XCTAssertEqual(model.modal?.presentation, .sheet)
        XCTAssertTrue(h.session.openPanels.contains(PanelIDs.cloudBackup))
    }

    func testSidebarDestinationsCountsAndCollectionNavigation() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        for (id, title, symbol) in [(PanelIDs.gallery, "Gallery", NibSymbol.gallery),
                                     (PanelIDs.trash, "Trash", .trash),
                                     ("collabpresence.shared", "Shared", .shared),
                                     (PanelIDs.favourites, "Favourites", .favorites)] {
            h.app.ui.panels.register(PanelDescriptor(id: id, title: title, icon: symbol.name,
                placement: .libraryTab, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        }
        h.app.settings.declarePrefix("searchui.recent.", synced: false, summary: "Test recent documents", owner: "test")
        h.app.settings.setJSON("searchui.recent." + Fixtures.docID.raw, .number(200))
        h.app.settings.setJSON("searchui.recent." + Fixtures.studySetID.raw, .number(100))
        h.app.settings.setJSON("searchui.recent.MISSINGDOC01", .number(300))
        try h.library.move(Fixtures.studySetID, to: Fixtures.folderID)
        await model.appear()
        XCTAssertEqual(model.sidebarPlaces.map(\.id), ["documents", PanelIDs.favourites, "collabpresence.shared", "recents", "studySets", PanelIDs.gallery, PanelIDs.trash])
        XCTAssertEqual(model.sidebarCounts["documents"], h.library.allNodes().filter { $0.kind == .document }.count)
        XCTAssertEqual(model.sidebarCounts["recents"], 2, "Stale recent records must not inflate the count")
        XCTAssertEqual(model.sidebarCounts["studySets"], 1)
        XCTAssertEqual(model.sidebarCounts["folder:" + Fixtures.folderID.raw], h.library.children(of: Fixtures.folderID).count)
        XCTAssertEqual(model.sidebarCounts[PanelIDs.trash], h.library.trashedNodes().count)

        let result = try await h.app.bus.execute(CommandIDs.librarySetView, ["collection": "recents", "sidebar": false], session: h.session)
        XCTAssertEqual(result["collection"], "recents")
        XCTAssertEqual(model.title, "Recents")
        XCTAssertEqual(model.documentRefs, [NodeRef.document(Fixtures.docID).description, NodeRef.document(Fixtures.studySetID).description])
        XCTAssertTrue(model.folderRows.isEmpty)
        XCTAssertFalse(model.sidebarVisible)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["collection": "studySets"], session: h.session)
        XCTAssertEqual(model.documentRefs, [NodeRef.document(Fixtures.studySetID).description], "Study Sets must include nested documents")
        XCTAssertEqual(model.title, "Study Sets")
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": .string("folder:" + Fixtures.folderID.raw)], session: h.session)
        XCTAssertEqual(model.collection, .documents)
        XCTAssertEqual(model.parentNavigation?.ref, "lib")
        XCTAssertEqual(model.sidebarCounts["recents"], 2, "Counts must remain library-wide inside a folder")
        try h.library.trash(Fixtures.studySetID)
        await model.reload()
        XCTAssertEqual(model.sidebarCounts["studySets"], 0)
        XCTAssertEqual(model.sidebarCounts["recents"], 1)
        XCTAssertEqual(model.sidebarCounts[PanelIDs.trash], h.library.trashedNodes().count)
    }

    func testCollectionDryRunDoesNotChangeFolderOrSelection() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": .string("folder:" + Fixtures.folderID.raw)], session: h.session)
        model.selection.isSelecting = true
        model.selection.refs = [NodeRef.document(Fixtures.docID).description]
        let result = try await h.app.bus.execute(Invocation(command: CommandIDs.librarySetView, params: ["collection": "studySets"], session: h.session, dryRun: true))
        XCTAssertEqual(result.value["collection"], "studySets")
        XCTAssertEqual(model.collection, .documents)
        XCTAssertEqual(model.folder, Fixtures.folderID)
        XCTAssertTrue(model.selection.isSelecting)
        XCTAssertEqual(model.selection.refs, [NodeRef.document(Fixtures.docID).description])
    }

    func testFolderColumnsPreserveOrdinaryNamesBeforeAddingColumns() {
        let minimum = LibraryFolderLayout.minimumWidth(names: ["Semester Notes", "Physics 9702"], font: NibUIFont.button)
        let width: CGFloat = 656
        let count = LibraryFolderLayout.columnCount(width: width, minimum: minimum, gutter: NibMetrics.libraryGutter)
        XCTAssertLessThan(count, 4)
        XCTAssertGreaterThanOrEqual((width - CGFloat(count - 1) * NibMetrics.libraryGutter) / CGFloat(count), minimum)
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 180, minimum: minimum, gutter: 16), 1)
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 1400, minimum: minimum, gutter: 24), 4)
        var largeFont = NibUIFont.button
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge).performAsCurrent { largeFont = NibUIFont.button }
        let largeMinimum = LibraryFolderLayout.minimumWidth(names: ["Semester 1", "Physikvorlesungen"], font: largeFont)
        XCTAssertGreaterThan(largeMinimum, minimum)
        XCTAssertLessThanOrEqual(LibraryFolderLayout.columnCount(width: width, minimum: largeMinimum, gutter: 24), count)
    }

    func testMissingAndLockedCoverGlyphsContrastWithWhitePaperInBothThemes() throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        var row = try XCTUnwrap(h.library.node(Fixtures.docID)).mapRow
        row.sync = nil
        for locked in [false, true] {
            row.locked = locked
            for variant in [NibSnapshot.Variant.light, .dark] {
                for size in [NibMetrics.coverSize, CGSize(width: NibMetrics.rowThumbnailWidth, height: NibMetrics.barHeightMax)] {
                    let image = try XCTUnwrap(NibSnapshot.image(LibraryCover(row: row, model: model, loadsThumbnail: false), size: size, variant: variant))
                    let paper = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: size.width - 2, y: size.height - 2)))
                    XCTAssertGreaterThan(paper.r, 250)
                    XCTAssertGreaterThan(paper.g, 250)
                    XCTAssertGreaterThan(paper.b, 250)
                    var darkest = 255
                    for y in stride(from: Int(size.height / 2) - 16, through: Int(size.height / 2) + 16, by: 2) {
                        for x in stride(from: max(2, Int(size.width / 2) - 16), through: min(Int(size.width) - 2, Int(size.width / 2) + 16), by: 2) {
                            let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                            darkest = min(darkest, max(Int(pixel.r), max(Int(pixel.g), Int(pixel.b))))
                        }
                    }
                    XCTAssertLessThan(darkest, 120, "Missing and locked covers need opaque dark ink on white paper in \(variant)")
                }
            }
        }
    }

    func testRenderedThumbnailKeepsItsPaperColourInDarkMode() throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        var row = try XCTUnwrap(h.library.node(Fixtures.docID)).mapRow
        row.locked = false
        row.sync = nil
        let thumbnail = UIGraphicsImageRenderer(size: NibMetrics.coverSize).image { context in
            NibPaper.ivory.uiColor.setFill()
            context.fill(CGRect(origin: .zero, size: NibMetrics.coverSize))
        }
        model.coverCache.images.setObject(thumbnail, forKey: (row.ref + String(row.modified ?? 0)) as NSString)
        var pixels: [RGBA] = []
        for variant in [NibSnapshot.Variant.light, .dark] {
            let image = try XCTUnwrap(NibSnapshot.image(LibraryCover(row: row, model: model, loadsThumbnail: false),
                                                      size: NibMetrics.coverSize, variant: variant))
            pixels.append(try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 70, y: 91))))
        }
        XCTAssertEqual(pixels[0], pixels[1])
        XCTAssertGreaterThan(pixels[1].r, 240)
        XCTAssertLessThan(pixels[1].b, 250, "The rendered ivory paper must not become the white placeholder")
    }

    func testReflowMeasuresOnlyCoverAndHidesSourceUntilLanding() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        var row = try XCTUnwrap(h.library.node(Fixtures.docID)).mapRow
        row.title = "A notebook with a title that wraps onto two lines"
        model.rows = [row]
        for list in [false, true] {
            for compact in [false, true] {
                let expected = list ? CGSize(width: NibMetrics.rowThumbnailWidth, height: NibMetrics.barHeightMax)
                    : compact ? NibMetrics.coverSizeCompact : NibMetrics.coverSize
                model.reflow.frames.removeAll()
                let view = LibraryCell(row: row, model: model, list: list)
                    .frame(width: list ? 320 : expected.width)
                    .nibReflowSpace(model.reflow)
                    .environment(\.horizontalSizeClass, compact ? .compact : .regular)
                let host = UIHostingController(rootView: view)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil }
                host.view.frame = window.bounds
                for _ in 0..<20 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    if model.reflow.frames[row.ref] != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let cover = try XCTUnwrap(model.reflow.frames[row.ref])
                XCTAssertEqual(cover.width, expected.width, accuracy: 0.5)
                XCTAssertEqual(cover.height, expected.height, accuracy: 0.5, "Labels must not enlarge the drag envelope")
                model.reflow.begin(row.ref, order: [row.ref], at: CGPoint(x: cover.midX, y: cover.midY))
                XCTAssertEqual(try XCTUnwrap(model.reflow.carrierFrame).size, cover.size)
                XCTAssertTrue(LibraryCarrierVisibility.hides(row.ref, in: model.reflow))
                XCTAssertFalse(LibraryCarrierVisibility.hides("doc:OTHERDOC01", in: model.reflow))
                _ = model.reflow.end()
                XCTAssertTrue(LibraryCarrierVisibility.hides(row.ref, in: model.reflow), "Keep the source hidden while the carrier lands")
                model.reflow.landed()
                XCTAssertFalse(LibraryCarrierVisibility.hides(row.ref, in: model.reflow))

                let image = try XCTUnwrap(NibSnapshot.image(LibraryStackedCarrier(ref: row.ref, model: model), size: expected))
                let attachment = XCTAttachment(image: image)
                attachment.name = "library-carrier-\(list ? "list" : "grid")-\(compact ? "compact" : "regular")"
                attachment.lifetime = .keepAlways
                add(attachment)
                let bottomPaper = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: expected.width / 2, y: expected.height - 10)))
                XCTAssertGreaterThan(bottomPaper.r, 240, "The bottom of the carrier must contain cover paper, not an empty label region")
                XCTAssertEqual(DropletStyle.card.envelope, 3)
            }
        }
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
        let commandCount = commands.count
        model.drop(.combine(refs[0], into: refs[2]))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(commands.count, commandCount, "Combine must wait for explicit confirmation")
        let confirmation = try XCTUnwrap(model.confirmation)
        XCTAssertEqual(confirmation.title, "Combine")
        _ = try await h.app.bus.execute(confirmation.command, confirmation.params, session: h.session)
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

private struct LibraryHitTestDocument: UIViewRepresentable {
    let button: UIButton
    func makeUIView(context: Context) -> UIButton { button }
    func updateUIView(_ uiView: UIButton, context: Context) {}
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
