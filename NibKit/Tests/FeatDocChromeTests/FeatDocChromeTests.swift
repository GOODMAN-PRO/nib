import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatDocChrome

@MainActor
final class FeatDocChromeTests: XCTestCase {
    func testFeatureID() {
        XCTAssertEqual(FeatDocChromeFeature.id, "chrome")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatDocChromeFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Layout view model

    func testRegularLandscapeDocksTheSidebarOnEitherSide() {
        let size = CGSize(width: 1194, height: 834)
        let safe = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)

        let left = ChromeLayout(size: size, safeArea: safe, left: 240, right: nil, mode: .sidebar)
        XCTAssertFalse(left.isCompact)
        XCTAssertEqual(left.presentation, .docked)
        XCTAssertEqual(left.bar, CGRect(x: 16, y: 32, width: 1162, height: 44))
        XCTAssertEqual(left.left, CGRect(x: 16, y: 88, width: 240, height: 726))
        XCTAssertNil(left.right)
        XCTAssertEqual(left.editor, CGRect(x: 256, y: 0, width: 938, height: 834))
        // The palette's layer: full height (its dock region keeps it below the bars), beside the sidebar.
        XCTAssertEqual(left.toolbar, CGRect(x: 256, y: 0, width: 938, height: 834))
        XCTAssertEqual(left.toolbarInsets, EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0))
        XCTAssertEqual(left.floatingRegion, CGRect(x: 272, y: 88, width: 906, height: 726))
        XCTAssertEqual(left.overlayRegion, CGRect(x: 272, y: 88, width: 906, height: 710))
        XCTAssertEqual(left.toast, CGRect(x: 256, y: 0, width: 938, height: 814))

        let right = ChromeLayout(size: size, safeArea: safe, left: nil, right: 240, mode: .sidebar)
        XCTAssertEqual(right.presentation, .docked)
        XCTAssertNil(right.left)
        XCTAssertEqual(right.right, CGRect(x: 938, y: 88, width: 240, height: 726))
        XCTAssertEqual(right.editor, CGRect(x: 0, y: 0, width: 938, height: 834))
        // A docked panel on the right moves the palette's right dock to its leading edge.
        XCTAssertEqual(right.toolbar, CGRect(x: 0, y: 0, width: 938, height: 834))
        XCTAssertEqual(right.floatingRegion, CGRect(x: 16, y: 88, width: 906, height: 726))
        XCTAssertEqual(right.overlayRegion, CGRect(x: 16, y: 88, width: 906, height: 710))

        let closed = ChromeLayout(size: size, safeArea: safe, left: nil, right: nil, mode: .sidebar)
        XCTAssertEqual(closed.editor, CGRect(x: 0, y: 0, width: 1194, height: 834))
        XCTAssertEqual(closed.toolbar, CGRect(x: 0, y: 0, width: 1194, height: 834))
        XCTAssertEqual(closed.floatingRegion, CGRect(x: 16, y: 88, width: 1162, height: 726))
        XCTAssertEqual(closed.overlayRegion, CGRect(x: 16, y: 88, width: 1162, height: 710))
    }

    func testRegularPortraitFloatsTheSidebarOverThePage() {
        let layout = ChromeLayout(size: CGSize(width: 834, height: 1194),
                                  safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                                  left: nil, right: 240, mode: .sidebar)
        XCTAssertFalse(layout.isCompact)
        XCTAssertEqual(layout.presentation, .overlay)
        XCTAssertEqual(layout.right, CGRect(x: 578, y: 88, width: 240, height: 1086))
        XCTAssertEqual(layout.editor, CGRect(x: 0, y: 0, width: 834, height: 1194))
        XCTAssertEqual(layout.toolbar, CGRect(x: 0, y: 0, width: 578, height: 1194))
        XCTAssertEqual(layout.overlayRegion, CGRect(x: 16, y: 88, width: 546, height: 1070))
    }

    func testCompactWidthPresentsSidebarsAsSheets() {
        for side in [SidebarSide.left, .right] {
            let layout = ChromeLayout(size: CGSize(width: 393, height: 852),
                                      safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                                      left: side == .left ? 240 : nil, right: side == .right ? 240 : nil, mode: .sidebar)
            XCTAssertTrue(layout.isCompact)
            XCTAssertEqual(layout.presentation, .sheet)
            XCTAssertNil(layout.left)
            XCTAssertNil(layout.right)
            XCTAssertEqual(layout.bar, CGRect(x: 16, y: 67, width: 361, height: 44))
            XCTAssertEqual(layout.editor, CGRect(x: 0, y: 0, width: 393, height: 852))
            XCTAssertEqual(layout.toolbar, CGRect(x: 0, y: 0, width: 393, height: 852))
            XCTAssertEqual(layout.toolbarInsets, EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0))
            // Overlays and toasts stay above the iPhone's bottom palette (56 + 8 + 16 above the home indicator).
            XCTAssertEqual(layout.overlayRegion, CGRect(x: 16, y: 123, width: 361, height: 615))
            XCTAssertEqual(layout.toast, CGRect(x: 0, y: 0, width: 393, height: 762))
        }
    }

    func testWindowModeFillsTheWindowBelowTheBars() {
        let layout = ChromeLayout(size: CGSize(width: 1194, height: 834),
                                  safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                                  left: 240, right: nil, mode: .window)
        XCTAssertEqual(layout.window, CGRect(x: 16, y: 88, width: 1162, height: 726))
        XCTAssertNil(layout.left)
        XCTAssertEqual(layout.editor, CGRect(x: 0, y: 0, width: 1194, height: 834))
        XCTAssertEqual(layout.toolbar, CGRect(x: 0, y: 0, width: 1194, height: 834))
    }

    func testFloatingPanelsSnapToTheNearerEdge() {
        let region = CGRect(x: 16, y: 88, width: 1162, height: 726)
        let size = CGSize(width: 344, height: 560)
        XCTAssertEqual(FloatingSnap.rest(centre: CGPoint(x: 300, y: 50), size: size, in: region),
                       CGPoint(x: 188, y: 368))
        // A fling to the right lands on the right edge, clamped inside the region.
        XCTAssertEqual(FloatingSnap.rest(centre: CGPoint(x: 500, y: 600), velocity: CGVector(dx: 3000, dy: 0),
                                         size: size, in: region),
                       CGPoint(x: 1006, y: 534))
        XCTAssertEqual(FloatingSnap.initial(index: 1, size: size, in: region), CGPoint(x: 1006, y: 392))
    }

    // MARK: Chrome overlays

    func testOverlayGeometryPlacesAndStacksEachPlacement() {
        let region = CGRect(x: 16, y: 88, width: 1162, height: 710)
        typealias Item = ChromeOverlayGeometry.Item
        let frames = ChromeOverlayGeometry.frames([
            Item(id: "timer", placement: .bottom, size: CGSize(width: 344, height: 44)),
            Item(id: "audio", placement: .bottom, size: CGSize(width: 320, height: 44)),
            Item(id: "record", placement: .top, size: CGSize(width: 200, height: 40)),
            Item(id: "status", placement: .topTrailing, size: CGSize(width: 120, height: 40)),
            Item(id: "page", placement: .bottomTrailing, size: CGSize(width: 104, height: 40)),
            Item(id: "follow", placement: .topLeading, size: CGSize(width: 160, height: 40)),
            Item(id: "pane", placement: .leading, size: CGSize(width: 240, height: 200)),
            Item(id: "hint", placement: .center, size: CGSize(width: 2000, height: 40)),
        ], in: region)
        // Bottom: the first sits on the region's bottom edge, the next 16 pt above it.
        XCTAssertEqual(frames["timer"], CGRect(x: 425, y: 754, width: 344, height: 44))
        XCTAssertEqual(frames["audio"], CGRect(x: 437, y: 694, width: 320, height: 44))
        // Top: just below the bars, centred; the corners keep to the region's edges.
        XCTAssertEqual(frames["record"], CGRect(x: 497, y: 88, width: 200, height: 40))
        XCTAssertEqual(frames["status"], CGRect(x: 1058, y: 88, width: 120, height: 40))
        XCTAssertEqual(frames["follow"], CGRect(x: 16, y: 88, width: 160, height: 40))
        XCTAssertEqual(frames["page"], CGRect(x: 1074, y: 758, width: 104, height: 40))
        XCTAssertEqual(frames["pane"], CGRect(x: 16, y: 343, width: 240, height: 200))
        // Never wider than the region.
        XCTAssertEqual(frames["hint"], CGRect(x: 16, y: 423, width: 1162, height: 40))
    }

    func testAnchoredOverlaySitsBelowItsAnchorOrAboveIt() {
        let region = CGRect(x: 16, y: 88, width: 1162, height: 710)
        let size = CGSize(width: 312, height: 200)
        typealias Item = ChromeOverlayGeometry.Item
        let frames = ChromeOverlayGeometry.frames([
            Item(id: "below", placement: .anchored, size: size, anchor: CGRect(x: 300, y: 200, width: 40, height: 40)),
            Item(id: "above", placement: .anchored, size: size, anchor: CGRect(x: 300, y: 700, width: 40, height: 40)),
            Item(id: "edge", placement: .anchored, size: size, anchor: CGRect(x: 1150, y: 200, width: 20, height: 20)),
            Item(id: "hidden", placement: .anchored, size: size, anchor: nil),
        ], in: region)
        XCTAssertEqual(frames["below"], CGRect(x: 164, y: 260, width: 312, height: 200))
        XCTAssertEqual(frames["above"], CGRect(x: 164, y: 480, width: 312, height: 200))
        XCTAssertEqual(frames["edge"], CGRect(x: 866, y: 240, width: 312, height: 200), "clamped inside the region")
        XCTAssertNil(frames["hidden"])
    }

    func testOverlaysSlideInFromTheirEdgeAndOnlyFadeUnderReduceMotion() {
        XCTAssertEqual(ChromeOverlayMotion.slide(.bottom), CGSize(width: 0, height: 16))
        XCTAssertEqual(ChromeOverlayMotion.slide(.bottomLeading), CGSize(width: 0, height: 16))
        XCTAssertEqual(ChromeOverlayMotion.slide(.top), CGSize(width: 0, height: -16))
        XCTAssertEqual(ChromeOverlayMotion.slide(.leading), CGSize(width: -16, height: 0))
        XCTAssertEqual(ChromeOverlayMotion.slide(.trailing), CGSize(width: 16, height: 0))
        XCTAssertEqual(ChromeOverlayMotion.slide(.center), .zero)
        XCTAssertEqual(ChromeOverlayMotion.slide(.anchored), .zero)
    }

    func testRegisteredOverlaysAppearInZOrderForTheDocumentKind() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let flag = OverlayFlag()
        h.app.ui.chromeOverlays.register(overlay("test.bar", .bottom, surface: .bar, order: 10))
        h.app.ui.chromeOverlays.register(overlay("test.hud", .top, order: 5))
        h.app.ui.chromeOverlays.register(overlay("test.board", .bottomTrailing, kinds: [.whiteboard]))
        h.app.ui.chromeOverlays.register(overlay("test.flag", .center, order: 7, visible: { _ in flag.on }))
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "test.pointer", owner: "tests", placement: .anchored, surface: .popover, order: 20,
            anchor: { _ in flag.on ? ChromeAnchor.window(CGRect(x: 100, y: 200, width: 30, height: 30)) : nil },
            makeView: { _ in AnyView(Color.clear.frame(width: 200, height: 100)) }))
        let model = ChromeOverlayModel(chrome: try makeWindow(h), kind: .notebook)
        XCTAssertEqual(model.overlays.map { $0.id }, ["test.hud", "test.bar"], "z-order: lowest order first")
        XCTAssertEqual(model.context.kind, .notebook)

        // The visibility predicate is asked again when the owner calls setNeedsChromeUpdate.
        flag.on = true
        h.app.ui.setNeedsChromeUpdate(h.session)
        try await waitUntil { model.overlays.count == 4 }
        XCTAssertEqual(model.overlays.map { $0.id }, ["test.hud", "test.flag", "test.bar", "test.pointer"])
        XCTAssertEqual(model.anchors["test.pointer"], CGRect(x: 100, y: 200, width: 30, height: 30))

        // Another window's update is not this window's business; its own is.
        flag.on = false
        h.app.ui.setNeedsChromeUpdate(EditorSession())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.overlays.count, 4)
        h.app.ui.setNeedsChromeUpdate()
        try await waitUntil { model.overlays.count == 2 }
        XCTAssertNil(model.anchors["test.pointer"], "an anchored overlay with nothing to point at hides")

        // A whiteboard window shows the whiteboard overlay; unregistering removes an overlay.
        model.update(kind: .whiteboard)
        XCTAssertEqual(model.overlays.map { $0.id }, ["test.board", "test.hud", "test.bar"])
        h.app.ui.chromeOverlays.unregister(id: "test.hud")
        try await waitUntil { model.overlays.count == 2 }
        XCTAssertEqual(model.overlays.map { $0.id }, ["test.board", "test.bar"])
    }

    func testOverlayLayerPlacesRegisteredOverlaysInTheRegion() throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.chromeOverlays.register(overlay("test.bar", .bottom, surface: .bar, size: CGSize(width: 200, height: 40)))
        h.app.ui.chromeOverlays.register(overlay("test.hud", .topTrailing, size: CGSize(width: 80, height: 30)))
        h.app.ui.chromeOverlays.register(overlay("test.free", .bottomLeading, surface: .none,
                                                 size: CGSize(width: 60, height: 30)))
        let model = ChromeOverlayModel(chrome: try makeWindow(h), kind: .notebook)
        let region = CGRect(x: 16, y: 88, width: 968, height: 696)
        let layer = ChromeOverlayLayer(model: model, inking: ChromeInkingMirror(session: h.session), region: region)
        _ = NibSnapshot.image(layer, size: CGSize(width: 1000, height: 800))
        // A bar is at least 44 pt tall and a HUD 40; a surface-less overlay keeps its own size.
        XCTAssertEqual(model.placed.frames["test.bar"], CGRect(x: 400, y: 740, width: 200, height: 44))
        XCTAssertEqual(model.placed.frames["test.hud"], CGRect(x: 904, y: 88, width: 80, height: 40))
        XCTAssertEqual(model.placed.frames["test.free"], CGRect(x: 16, y: 754, width: 60, height: 30))
    }

    func testOverlaysRecedeWhileThePencilIsDown() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let mirror = ChromeInkingMirror(session: h.session)
        XCTAssertFalse(mirror.state.isInking)
        XCTAssertFalse(mirror.recedes)

        // The canvas writes the window's InkingSignal; the container's NibInkingState follows it.
        h.session.inking.begin(strokeBounds: CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertTrue(mirror.state.isInking)
        XCTAssertEqual(mirror.state.strokeBounds, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertTrue(mirror.recedes)
        h.session.inking.update(strokeBounds: CGRect(x: 10, y: 20, width: 60, height: 40))
        XCTAssertEqual(mirror.state.strokeBounds, CGRect(x: 10, y: 20, width: 60, height: 40))

        let hud = overlay("test.hud", .top)
        let free = overlay("test.free", .bottom, surface: .none)
        var steady = overlay("test.steady", .bottom, surface: .none)
        steady.recedesWhileWriting = false
        var solid = overlay("test.solid", .top, surface: .bar)
        solid.recedesWhileWriting = false
        // A surface-less overlay is faded by the chrome; one that asked not to recede stays.
        XCTAssertEqual(ChromeOverlayRecede.opacity(free, receding: mirror.recedes), 0.22, accuracy: 0.0001)
        XCTAssertEqual(ChromeOverlayRecede.opacity(steady, receding: mirror.recedes), 1)
        XCTAssertEqual(ChromeOverlayRecede.opacity(free, receding: false), 1)
        // A droplet overlay recedes in the container, water and content together: its frame joins the backdrop.
        XCTAssertEqual(ChromeOverlayRecede.opacity(hud, receding: true), 1)
        let frames: [String: CGRect] = ["test.hud": CGRect(x: 1, y: 2, width: 3, height: 4),
                                        "test.free": CGRect(x: 5, y: 6, width: 7, height: 8),
                                        "test.solid": CGRect(x: 9, y: 9, width: 9, height: 9)]
        XCTAssertEqual(ChromeOverlayRecede.backdropFrames([hud, free, solid], frames: frames),
                       [CGRect(x: 1, y: 2, width: 3, height: 4)])

        // Pencil up: the container returns at once to its own 450 ms timer; the chrome's fade holds as long.
        h.session.inking.end()
        XCTAssertFalse(mirror.state.isInking)
        XCTAssertTrue(mirror.state.strokeBounds.isNull)
        XCTAssertTrue(mirror.recedes)
        try await waitUntil(timeout: 2) { !mirror.recedes }
    }

    // MARK: Placement and state

    func testPlacementFollowsTheSidebarSideAndPerPanelOverride() {
        let tab = panel("pages", .sidebarTab)
        let floating = panel("assistant", .floating)
        XCTAssertEqual(PanelResolver.spot(of: tab, override: nil, sidebarOnRight: false), .left)
        XCTAssertEqual(PanelResolver.spot(of: tab, override: nil, sidebarOnRight: true), .right)
        XCTAssertEqual(PanelResolver.spot(of: tab, override: "floating", sidebarOnRight: false), .floating)
        XCTAssertEqual(PanelResolver.spot(of: floating, override: nil, sidebarOnRight: true), .floating)
        XCTAssertEqual(PanelResolver.spot(of: floating, override: "right", sidebarOnRight: false), .right)
        XCTAssertEqual(PanelResolver.spot(of: floating, override: "sheet", sidebarOnRight: false), .floating)
        XCTAssertEqual(PanelResolver.spot(of: panel("editing", .sheet), override: "left", sidebarOnRight: false), .sheet)
        XCTAssertNil(PanelResolver.spot(of: panel("gallery", .libraryTab), override: nil, sidebarOnRight: false))

        // What the panel is told about how it shows (contracts-v2 PanelContext.presentation).
        XCTAssertEqual(PanelResolver.presentation(.left, mode: .sidebar, compact: false), .sidebar)
        XCTAssertEqual(PanelResolver.presentation(.right, mode: .window, compact: false), .window)
        XCTAssertEqual(PanelResolver.presentation(.left, mode: .sidebar, compact: true), .sheet)
        XCTAssertEqual(PanelResolver.presentation(.floating, mode: .sidebar, compact: false), .floating)
        XCTAssertEqual(PanelResolver.presentation(.floating, mode: .sidebar, compact: true), .sheet)
        XCTAssertEqual(PanelResolver.presentation(.fullScreen, mode: .sidebar, compact: false), .fullScreen)
    }

    func testReconcileMovesOpenPanelsAndDropsUnregisteredOnes() {
        let state = ChromeState()
        state.open("pages", at: .left)
        state.open("gone", at: .floating)
        state.reconcile { $0 == "pages" ? .floating : nil }
        XCTAssertNil(state.tabs[.left])
        XCTAssertEqual(state.floating, ["pages"])
        state.open("chat", at: .floating)
        state.open("pages", at: .floating)
        XCTAssertEqual(state.floating, ["chat", "pages"], "opening a floating panel again brings it to the front")
    }

    func testSidebarToggleActsOnTheSideThatIsShowing() throws {
        // D-136 + D-117: the sidebar belongs on the left, but Outline was moved to the right and is open.
        let state = ChromeState()
        state.open("outline", at: .right)
        let available: (SidebarSide) -> [String] = { $0 == .left ? ["pages"] : ["outline"] }

        XCTAssertEqual(try state.toggleSidebar(mode: .window, preferred: .left, available: available), .right)
        XCTAssertEqual(state.mode, .window)
        XCTAssertEqual(state.tabs[.right], "outline")
        XCTAssertNil(state.tabs[.left], "switching modes never opens the other side")

        XCTAssertNil(try state.toggleSidebar(mode: nil, preferred: .left, available: available))
        XCTAssertTrue(state.tabs.isEmpty, "the side that shows hides")
    }

    func testAContainerClosesPanelsItsDocumentKindDoesNotTake() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab, kinds: [.notebook]))
        h.app.ui.panels.register(panel("test.timer", .floating, kinds: [.notebook]))
        h.app.ui.panels.register(panel("test.chat", .floating))
        let state = try chromeState(h)
        try await h.run("panel.open", ["id": "test.pages"])
        try await h.run("panel.open", ["id": "test.timer"])
        try await h.run("panel.open", ["id": "test.chat"])
        XCTAssertEqual(state.openPanels, ["test.pages", "test.timer", "test.chat"])

        // Back to the library, then a whiteboard in the same window: its chrome state carries over.
        h.session.document = Fixtures.whiteboardID
        _ = DocumentContainerViewController(editor: UIViewController(), document: Fixtures.whiteboardID, app: h.app,
                                            navigator: TestNavigator(session: h.session))
        XCTAssertEqual(state.openPanels, ["test.chat"])
        XCTAssertEqual(h.session.openPanels, ["test.chat"])
    }

    func testOpenPanelsAreKeptOnTheSessionAndOtherFeaturesCanToggleThem() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab))
        h.app.ui.panels.register(panel("test.chat", .floating))
        let state = try chromeState(h)

        // contracts-v2 session.openPanels: what query.context and other features read.
        try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(h.session.openPanels, ["test.pages"])
        try await h.run("panel.open", ["id": "test.chat"])
        XCTAssertEqual(h.session.openPanels, ["test.pages", "test.chat"])
        try await h.run("panel.close", ["id": "test.pages"])
        XCTAssertEqual(h.session.openPanels, ["test.chat"])
        try await h.run("sidebar.toggle")
        XCTAssertEqual(h.session.openPanels, ["test.pages", "test.chat"])

        // A feature that writes the set: what it adds opens where the settings say, what it removes closes, and ids
        // that are no panel are dropped again.
        h.session.openPanels = ["test.pages", "test.missing"]
        try await waitUntil { h.session.openPanels == ["test.pages"] }
        XCTAssertEqual(state.openPanels, ["test.pages"])
        h.session.openPanels.insert("test.chat")
        try await waitUntil { state.floating == ["test.chat"] }
        XCTAssertEqual(h.session.openPanels, ["test.pages", "test.chat"])
    }

    // MARK: Commands

    func testPanelCommandsPlacePanelsWhereTheSettingsSay() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab, kinds: [.notebook]))
        h.app.ui.panels.register(panel("test.chat", .floating))
        h.app.ui.panels.register(panel("test.cards", .sidebarTab, kinds: [.studySet]))
        let state = try chromeState(h)

        var r = try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(r["placement"], "left")
        XCTAssertEqual(state.tabs[.left], "test.pages")

        h.app.settings.set(NibSettings.sidebarOnRight, true)
        r = try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(r["placement"], "right")
        XCTAssertNil(state.tabs[.left])
        XCTAssertEqual(state.tabs[.right], "test.pages")

        // D-136: a per-panel position, set like any setting (so the AI and plugins can too).
        try await h.run("settings.set", ["name": "chrome.panelPlacement.test.pages", "value": "floating"])
        r = try await h.run("panel.open", ["id": "test.pages"])
        XCTAssertEqual(r["placement"], "floating")
        XCTAssertEqual(state.floating, ["test.pages"])
        await assertCode(.invalidParams) {
            try await h.run("settings.set", ["name": "chrome.panelPlacement.test.pages", "value": "top"])
        }

        // The AI can drive the chrome too.
        r = try await h.run("panel.open", ["id": "test.chat"], as: .ai("chat1"))
        XCTAssertEqual(r["placement"], "floating")
        XCTAssertEqual(state.floating, ["test.pages", "test.chat"])

        // Docking to an edge is a command too (dragging and the VoiceOver actions run it).
        try await h.run("panel.open", ["id": "test.chat", "edge": "left"], as: .ai("chat1"))
        let docked = try XCTUnwrap(state.floatingCentres["test.chat"])
        XCTAssertEqual(FloatingSnap.rest(centre: docked, size: CGSize(width: 344, height: 560),
                                         in: CGRect(x: 16, y: 88, width: 1162, height: 726)),
                       CGPoint(x: 188, y: 368))
        XCTAssertEqual(state.floating, ["test.pages", "test.chat"])
        await assertCode(.invalidParams) {
            try await h.run("panel.open", ["id": "chrome.editingSettings", "edge": "left"])
        }

        r = try await h.run("panel.close", ["id": "test.chat"])
        XCTAssertEqual(r["closed"], true)
        r = try await h.run("panel.close", ["id": "test.chat"])
        XCTAssertEqual(r["closed"], false)

        await assertCode(.notFound) { try await h.run("panel.open", ["id": "test.missing"]) }
        await assertCode(.invalidParams) { try await h.run("panel.open", ["id": "test.cards"]) }
    }

    func testPanelOpenParamsReachThePanel() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.thread", .floating))
        let window = try makeWindow(h)

        // contracts-v2: panel.open {id, params} hands params to the panel as PanelContext.params.
        try await h.run("panel.open", ["id": "test.thread", "params": ["thread": "item:A/B/C", "instant": true]])
        var context = window.panelContext("test.thread", presentation: .floating)
        XCTAssertEqual(context.params, ["thread": "item:A/B/C", "instant": true])
        XCTAssertEqual(context.presentation, .floating)

        // Bringing it forward or docking it keeps them; new params replace them.
        try await h.run("panel.open", ["id": "test.thread", "edge": "left"])
        XCTAssertEqual(window.panelContext("test.thread", presentation: .floating).params["thread"], "item:A/B/C")
        try await h.run("panel.open", ["id": "test.thread", "params": ["thread": "item:A/B/D"]], as: .ai("chat1"))
        XCTAssertEqual(window.panelContext("test.thread", presentation: .floating).params, ["thread": "item:A/B/D"])

        // Closed and opened again without params, it starts empty.
        try await h.run("panel.close", ["id": "test.thread"])
        try await h.run("panel.open", ["id": "test.thread"])
        context = window.panelContext("test.thread", presentation: .sheet)
        XCTAssertEqual(context.params, [:])
        XCTAssertEqual(context.presentation, .sheet)

        // Keys beside `id` reach the panel too ({id, block} as well as {id, params: {block}}); `params` wins a tie.
        try await h.run("panel.open", ["id": "test.thread", "block": "block:D/B", "filter": "open",
                                       "params": ["filter": "all"]])
        XCTAssertEqual(window.panelContext("test.thread", presentation: .floating).params,
                       ["block": "block:D/B", "filter": "all"])
        XCTAssertNil(PanelOpen.panelParams(["id": "x", "edge": "left"]))
        XCTAssertEqual(PanelOpen.panelParams(["id": "x", "params": [:]]), [:])

        await assertCode(.invalidParams) { try await h.run("panel.open", ["id": "test.thread", "params": "thread"]) }
    }

    func testPanelsDrawTheirOwnHeaderWhenTheySaySo() throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let window = try makeWindow(h)
        var plugin = panel("test.plugin", .floating)
        plugin.providesHeader = true
        XCTAssertFalse(window.drawsHeader(plugin))
        XCTAssertTrue(window.drawsHeader(panel("test.native", .floating)))
        // The chrome's own sheets draw their NibSheetHeader.
        XCTAssertEqual(h.app.ui.panels.get(ChromePanels.rename)?.providesHeader, true)

        // The assistant is found by its well-known id (PanelIDs.assistant), whoever owns it.
        XCTAssertNil(window.assistantPanel(kind: .notebook))
        h.app.ui.panels.register(panel(PanelIDs.assistant, .floating))
        XCTAssertEqual(window.assistantPanel(kind: .notebook)?.id, PanelIDs.assistant)
    }

    func testSidebarToggleShowsHidesAndSwitchesMode() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        h.app.ui.panels.register(panel("test.pages", .sidebarTab, order: 0))
        h.app.ui.panels.register(panel("test.outline", .sidebarTab, order: 10))
        let state = try chromeState(h)

        var r = try await h.run("sidebar.toggle")
        XCTAssertEqual(r["visible"], true)
        XCTAssertEqual(r["panel"], "test.pages")
        try await h.run("panel.open", ["id": "test.outline"])

        r = try await h.run("sidebar.toggle", ["mode": "window"])
        XCTAssertEqual(r["visible"], true)
        XCTAssertEqual(r["mode"], "window")

        r = try await h.run("sidebar.toggle")
        XCTAssertEqual(r["visible"], false)
        XCTAssertNil(state.tabs[.left])

        r = try await h.run("sidebar.toggle")
        XCTAssertEqual(r["panel"], "test.outline", "the sidebar comes back on the tab it showed")

        await assertCode(.invalidParams) { try await h.run("sidebar.toggle", ["mode": "grid"]) }
    }

    func testScrollDirectionIsAnUndoableNotebookEdit() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        try await h.run("doc.setScrollDirection", ["doc": "doc:FIXTUREDOC01", "direction": "horizontal"])
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.scrollDirection, .horizontal)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.scrollDirection, .vertical)
        await assertCode(.invalidParams) {
            try await h.run("doc.setScrollDirection", ["doc": "doc:FIXTUREDOC04", "direction": "horizontal"])
        }
    }

    // MARK: Registrations

    func testMoreMenuBaseItemsAndShortcutRunCommands() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1)
        let more = h.app.ui.menuItems(.documentMore, context)
        XCTAssertEqual(more.map(\.id), ["chrome.more.scrollVertical", "chrome.more.scrollHorizontal",
                                        "chrome.more.editingSettings"])
        // Scrolling Direction: both directions, the current one ticked (contracts-v2 isChecked).
        XCTAssertEqual(more.map { $0.isChecked?(context) ?? false }, [true, false, false])
        XCTAssertEqual(more[1].params(context)["direction"], "horizontal")
        XCTAssertEqual(more[0].submenu, more[1].submenu)
        for item in more {
            XCTAssertNotNil(h.app.commands.entry(item.command), "\(item.id) runs \(item.command)")
        }
        try await h.run("doc.setScrollDirection", ["doc": "doc:FIXTUREDOC01", "direction": "horizontal"])
        XCTAssertEqual(more.map { $0.isChecked?(context) ?? false }, [false, true, false])

        let whiteboard = MenuContext(app: h.app, session: h.session, doc: Fixtures.whiteboardID)
        XCTAssertEqual(h.app.ui.menuItems(.documentMore, whiteboard).map(\.id), ["chrome.more.editingSettings"])

        let shortcut = h.app.content.keyCommands.get("chrome.toggleSidebar")
        XCTAssertEqual(shortcut?.command, "sidebar.toggle")
        XCTAssertEqual(shortcut?.shortcut, KeyShortcut("s", [.control, .command]))
        XCTAssertEqual(ChromeShortcuts.display(KeyShortcut("s", [.control, .command])), "⌃⌘S")
        XCTAssertEqual(ChromeShortcuts.display(KeyShortcut("z", [.command, .shift])), "⇧⌘Z")
        XCTAssertEqual(ChromeShortcuts.display(KeyShortcut("up", [.option])), "⌥↑")
        XCTAssertNotNil(h.app.ui.screens.documentContainer)
    }

    func testNavBarItemsRunCommandsAndDeferToFeatureItems() {
        var input = NavBarModel.Input(
            doc: Fixtures.docID, kind: .notebook, page: Fixtures.page1, readOnly: false, bookmarked: false, tool: "pen",
            hasSidebar: true, sidebarVisible: false, assistantPanel: "ai.chat", assistantOpen: false, registered: [],
            commandExists: { _ in true }, hasMenu: { _ in true })
        let built = NavBarModel.build(input)
        XCTAssertEqual(built.leading.map(\.id), [NavBarModel.library, NavBarModel.sidebar, NavBarModel.search,
                                                 NavBarModel.assistant, NavBarModel.readOnly, NavBarModel.bookmark])
        XCTAssertEqual(built.trailing.map(\.id), [NavBarModel.addPage, NavBarModel.share, NavBarModel.more])
        for item in built.leading where item.id != NavBarModel.library {
            guard case .command = item.action else { return XCTFail("\(item.id) must run a command") }
        }
        let bookmark = built.leading.first { $0.id == NavBarModel.bookmark }
        XCTAssertEqual(bookmark?.action, .command("page.setBookmarked",
                                                  ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "on": true]))

        // A feature's own read-only button replaces the built-in one; nothing shows twice.
        input.registered = [ToolbarItemDescriptor(id: "readonly.toggle", title: "Read Only", icon: "lock",
                                                  group: .navLeading, order: 400, owner: "readonly",
                                                  command: "view.setReadOnly", params: ["on": true])]
        let replaced = NavBarModel.build(input).leading.map(\.id)
        XCTAssertTrue(replaced.contains("readonly.toggle"))
        XCTAssertFalse(replaced.contains(NavBarModel.readOnly))

        // Compact: Library stays leading; Assistant and More trail; the rest moves into More.
        let compact = NavBarModel.split(NavBarModel.build(input), compact: true)
        XCTAssertEqual(compact.leading.map(\.id), [NavBarModel.library])
        XCTAssertEqual(compact.trailing.map(\.id), [NavBarModel.assistant, NavBarModel.more])
        XCTAssertTrue(compact.overflow.map(\.id).contains(NavBarModel.sidebar))
        XCTAssertTrue(compact.overflow.map(\.id).contains(NavBarModel.addPage))
    }

    func testNavItemsShowTheLiveStateOfFeatureItems() {
        let session = EditorSession()
        session.page = Fixtures.page1
        var bookmark = ToolbarItemDescriptor(id: "outline.bookmark", title: "Bookmark", icon: "bookmark",
                                             group: .navLeading, order: 500, owner: "outline",
                                             command: "page.setBookmarked", params: ["on": true])
        bookmark.isOn = { $0.page == Fixtures.page1 }
        bookmark.sessionParams = { s in ["pages": .array([.string(s.page?.raw ?? "")])] }
        bookmark.sessionTitle = { _ in "Remove Bookmark" }
        bookmark.sessionIcon = { _ in "bookmark.fill" }
        var redo = ToolbarItemDescriptor(id: "undo.redo", title: "Redo", icon: "arrow.uturn.forward",
                                         group: .navTrailing, order: 11, owner: "undo", command: "edit.redo")
        redo.isEnabled = { _ in false }
        redo.showsInCompactWidth = false

        let item = NavBarModel.navItem(for: bookmark, tool: "pen", session: session)
        XCTAssertEqual(item?.title, "Remove Bookmark")
        XCTAssertEqual(item?.symbol.name, "bookmark.fill")
        XCTAssertEqual(item?.isOn, true)
        XCTAssertEqual(item?.action, .command("page.setBookmarked", ["on": true, "pages": [.string(Fixtures.page1.raw)]]))
        // Without a window the static values apply.
        XCTAssertEqual(NavBarModel.navItem(for: bookmark, tool: "pen")?.title, "Bookmark")
        XCTAssertEqual(NavBarModel.navItem(for: redo, tool: "pen", session: session)?.isEnabled, false)

        let input = NavBarModel.Input(
            doc: Fixtures.docID, kind: .notebook, page: Fixtures.page1, readOnly: false, bookmarked: false, tool: "pen",
            hasSidebar: false, sidebarVisible: false, assistantPanel: nil, assistantOpen: false,
            registered: [bookmark, redo], commandExists: { _ in true }, hasMenu: { _ in false }, session: session)
        let regular = NavBarModel.build(input)
        XCTAssertTrue(regular.trailing.map(\.id).contains("undo.redo"))
        XCTAssertFalse(regular.leading.map(\.id).contains(NavBarModel.bookmark), "the feature's bookmark replaces ours")
        let compact = NavBarModel.split(regular, compact: true)
        XCTAssertFalse((compact.trailing + compact.overflow).map(\.id).contains("undo.redo"),
                       "regular-width-only items do not show on compact width")
    }

    func testTitleMenuOffersEditWhileReadOnlyAndCountsThisWindowsTabs() {
        let h = Harness(features: [FeatDocChromeFeature.self])
        for id in ["view.setReadOnly", "tab.closeOthers"] {
            h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "test double", effect: .session,
                                                      target: .app)) { _, _ in .object([:]) }
        }
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID)
        XCTAssertEqual(h.app.ui.menuItems(.documentTitle, context).map(\.id), [])

        h.session.readOnly = true
        let edit = h.app.ui.menuItems(.documentTitle, context).first
        XCTAssertEqual(edit?.id, "chrome.title.edit")
        XCTAssertEqual(edit?.command, "view.setReadOnly")
        XCTAssertEqual(edit?.params(context), ["on": false])

        // Close Other Tabs counts this window's tabs, not those of whichever window was active last.
        let elsewhere = TestNavigator(session: EditorSession())
        elsewhere.openDocuments = [Fixtures.docID, Fixtures.textDocID]
        h.app.ui.activeNavigator = elsewhere
        XCTAssertFalse(h.app.ui.menuItems(.documentTitle, context).map(\.id).contains("chrome.title.closeOthers"))
        let here = TestNavigator(session: h.session)
        here.openDocuments = [Fixtures.docID, Fixtures.textDocID]
        h.app.ui.activeNavigator = here
        XCTAssertTrue(h.app.ui.menuItems(.documentTitle, context).map(\.id).contains("chrome.title.closeOthers"))
    }

    func testSubtitleShowsFolderPageAndReadOnly() {
        var snapshot = ChromeDocumentModel.Snapshot(title: "Kinematics", folder: "Physics 9702", kind: .notebook,
                                                    page: Fixtures.page1, pageIndex: 2, pageCount: 12,
                                                    bookmarked: false, readOnly: false, tool: "pen")
        XCTAssertEqual(NavBarModel.subtitle(snapshot), "Physics 9702 · Page 3 of 12")
        snapshot.readOnly = true
        XCTAssertEqual(NavBarModel.subtitle(snapshot), "Read only")
    }

    // MARK: Container

    func testContainerFollowsTheStatusBarSettingAndBackGoesToTheLibrary() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let navigator = TestNavigator(session: h.session)
        let container = DocumentContainerViewController(editor: UIViewController(), document: Fixtures.docID,
                                                        app: h.app, navigator: navigator)
        XCTAssertFalse(container.prefersStatusBarHidden)
        h.app.settings.set(NibSettings.hideStatusBar, true)
        XCTAssertTrue(container.prefersStatusBarHidden)

        // Back runs window.showLibrary (contracts-v2) in this window, even when another window was active last.
        let other = TestNavigator(session: EditorSession())
        h.app.ui.activeNavigator = other
        let context = ChromeWindow(app: h.app, doc: Fixtures.docID, session: h.session, state: try chromeState(h),
                                   navigator: navigator)
        context.goToLibrary()
        try await waitUntil { navigator.shownLibrary == [Fixtures.folderID] }
        XCTAssertTrue(h.app.ui.activeNavigator === navigator)
    }

    func testBackRunsLibrarySetViewWhenItIsInstalled() async throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let log = CallLog()
        let ran = expectation(description: "library.setView ran")
        h.app.commands.register(CommandDescriptor(id: "library.setView", title: "Library", summary: "test double",
                                                  effect: .session, target: .app)) { params, _ in
            log.params.append(params)
            ran.fulfill()
            return .object([:])
        }
        let navigator = TestNavigator(session: h.session)
        let context = ChromeWindow(app: h.app, doc: Fixtures.docID, session: h.session, state: try chromeState(h),
                                   navigator: navigator)
        context.goToLibrary()
        await fulfillment(of: [ran], timeout: 5)
        XCTAssertEqual(log.params, [["folder": "folder:FIXTUREFLD01"]])
        XCTAssertEqual(navigator.shownLibrary, [Fixtures.folderID], "the library shows first, then its view is set")
    }

    func testTheContainerPublishesTheWindowsFloatingHost() throws {
        let h = Harness(features: [FeatDocChromeFeature.self])
        let navigator = TestNavigator(session: h.session)
        let container = DocumentContainerViewController(editor: UIViewController(), document: Fixtures.docID,
                                                        app: h.app, navigator: navigator)
        XCTAssertNil(h.session.floatingHost)
        container.loadViewIfNeeded()
        let host = try XCTUnwrap(h.session.floatingHost)
        XCTAssertTrue(host === container.floatingHost)
        XCTAssertTrue(navigator.floatingHost === container.floatingHost)
        XCTAssertTrue(ChromeContext(app: h.app, session: h.session).floatingHost === container.floatingHost)

        // Popovers, HUDs and toasts from UIKit code go into the chrome's container through it.
        host.present("test.hud") { Text("3 / 12") }
        XCTAssertTrue(host.isPresenting("test.hud"))
        XCTAssertEqual(container.floatingHost.host.presentedIDs, ["test.hud"])
        host.dismiss("test.hud")
        XCTAssertFalse(host.isPresenting("test.hud"))
        var undone = false
        host.postToast("Moved to Chemistry.", actionTitle: "Undo") { undone = true }
        XCTAssertEqual(container.floatingHost.host.toast?.message, "Moved to Chemistry.")
        XCTAssertEqual(container.floatingHost.host.toast?.action?.title, "Undo")
        container.floatingHost.host.toast?.action?.handler()
        XCTAssertTrue(undone)
        host.postToast("Saved.")
        XCTAssertNil(container.floatingHost.host.toast?.action)

        // The next document's container takes over; this one leaving does not clear the newcomer's host.
        let next = DocumentContainerViewController(editor: UIViewController(), document: Fixtures.docID, app: h.app,
                                                   navigator: navigator)
        next.loadViewIfNeeded()
        XCTAssertTrue(h.session.floatingHost === next.floatingHost)
        container.beginAppearanceTransition(false, animated: false)
        container.endAppearanceTransition()
        XCTAssertTrue(h.session.floatingHost === next.floatingHost)
    }

    // MARK: Helpers

    private func panel(_ id: String, _ placement: PanelPlacement, order: Int = 0,
                       kinds: Set<DocumentKind>? = nil) -> PanelDescriptor {
        PanelDescriptor(id: id, title: id, icon: "square.grid.2x2", placement: placement, order: order, owner: "tests",
                        docKinds: kinds) { _ in AnyView(EmptyView()) }
    }

    private func overlay(_ id: String, _ placement: ChromePlacement, surface: ChromeSurface = .hud, order: Int = 0,
                         kinds: Set<DocumentKind>? = nil, size: CGSize = CGSize(width: 100, height: 40),
                         visible: @escaping @MainActor (ChromeContext) -> Bool = { _ in true }) -> ChromeOverlayDescriptor {
        ChromeOverlayDescriptor(id: id, owner: "tests", placement: placement, surface: surface, order: order,
                                docKinds: kinds, isVisible: visible,
                                makeView: { _ in AnyView(Color.clear.frame(width: size.width, height: size.height)) })
    }

    private func chromeState(_ h: Harness) throws -> ChromeState {
        let store = try XCTUnwrap(h.app.services.get(ChromeStateStore.serviceKey, as: ChromeStateStore.self))
        return store.state(for: h.session)
    }

    private func makeWindow(_ h: Harness) throws -> ChromeWindow {
        ChromeWindow(app: h.app, doc: Fixtures.docID, session: h.session, state: try chromeState(h),
                     navigator: TestNavigator(session: h.session))
    }

    /// Polls (letting queued main-actor work run) until `condition` holds.
    private func waitUntil(timeout: TimeInterval = 1, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func assertCode(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                            _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class CallLog {
    var params: [JSONValue] = []
}

@MainActor
private final class OverlayFlag {
    var on = false
}

@MainActor
private final class TestNavigator: SceneNavigator {
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    var rootViewController: UIViewController? { nil }
    private(set) var shownLibrary: [FolderID?] = []

    init(session: EditorSession) {
        self.session = session
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) { shownLibrary.append(folder) }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}
