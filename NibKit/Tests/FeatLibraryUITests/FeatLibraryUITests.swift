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

    func testCardOpeningTapSurvivesHostingTapButYieldsToNavigationAndMenu() {
        let opening = LibraryItemTapRecognizer()
        XCTAssertFalse(opening.canBePrevented(by: UITapGestureRecognizer()))
        XCTAssertFalse(opening.canBePrevented(by: UIGestureRecognizer()))
        XCTAssertTrue(opening.canBePrevented(by: UIPanGestureRecognizer()))
        XCTAssertTrue(opening.canBePrevented(by: UILongPressGestureRecognizer()))
    }

    func testCardTapRejectsAncestorHostingPanAndHoldButKeepsNativeScrollAndMenu() {
        let host = UIView(), card = LibraryItemTouchView()
        host.addSubview(card)
        let opening = LibraryItemTapRecognizer()
        card.addGestureRecognizer(opening)
        for gesture in [UIPanGestureRecognizer(), UILongPressGestureRecognizer()] {
            host.addGestureRecognizer(gesture)
            XCTAssertFalse(opening.canBePrevented(by: gesture))
        }
        let scroll = UIScrollView()
        scroll.addSubview(host)
        XCTAssertTrue(opening.canBePrevented(by: scroll.panGestureRecognizer))
        let menu = UILongPressGestureRecognizer()
        card.addGestureRecognizer(menu)
        XCTAssertTrue(opening.canBePrevented(by: menu))
    }

    func testCardTouchOwnerSurvivesPressFeedbackAndMenuDragAvailabilityChanges() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        let row = try XCTUnwrap(model.documentRows.first)
        let host = UIHostingController(rootView: LibraryCell(row: row, model: model, list: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let card = try XCTUnwrap(descendants(host.view).compactMap { $0 as? LibraryItemTouchView }.first)
        let tap = try XCTUnwrap(card.gestureRecognizers?.compactMap { $0 as? LibraryItemTapRecognizer }.first)
        let frame = card.convert(card.bounds, to: window)
        tap.pressed(true)
        for menu in ["sort", "none", "app", "none"] {
            model.setView(["menu": .string(menu)])
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            XCTAssertEqual(LibraryItemReflow.acceptsDrag(model), menu == "none")
            let current = try XCTUnwrap(descendants(host.view).compactMap { $0 as? LibraryItemTouchView }.first)
            XCTAssertTrue(current === card, "Changing drag availability must not replace a touched card")
            XCTAssertTrue(tap.view === card)
            XCTAssertTrue(card.window === window)
            XCTAssertEqual(card.convert(card.bounds, to: window), frame, "Press feedback must not move the native touch target")
        }
        tap.pressed(false)
    }

    func testCardNativeTapDispatchesOnceAfterReattachmentInGridAndList() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        let row = try XCTUnwrap(model.documentRows.first)
        var opened: [String] = []
        var sessions: [NibID] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docOpen, title: "Open",
            summary: "Record card activation", effect: .session, target: .app)) { params, context in
                opened.append(try XCTUnwrap(params["doc"]?.stringValue))
                sessions.append(try XCTUnwrap(context.session?.id))
                return [:]
        }
        let host = UIHostingController(rootView: LibraryCell(row: row, model: model, list: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for list in [false, true, false] {
            window.rootViewController = nil
            host.rootView = LibraryCell(row: row, model: model, list: list)
            window.rootViewController = host
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let taps = descendants(host.view).flatMap { $0.gestureRecognizers ?? [] }
                .compactMap { $0 as? LibraryItemTapRecognizer }
            XCTAssertEqual(taps.count, 1, "Each card must have exactly one touch-up owner")
            let tap = try XCTUnwrap(taps.first), target = try XCTUnwrap(tap.view)
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: host.view)
            XCTAssertTrue(host.view.hitTest(point, with: nil) === target)
            XCTAssertTrue(target.isAccessibilityElement, "The tappable native card must own its accessibility identity")
            XCTAssertEqual(target.accessibilityIdentifier, "cmd.doc.open")
            XCTAssertEqual(target.accessibilityLabel, row.accessibilityLabel)
            XCTAssertTrue(target.accessibilityTraits.contains(.button))
            XCTAssertEqual(target.accessibilityCustomActions?.count, 2)
            XCTAssertFalse(tap.canBePrevented(by: UIGestureRecognizer()),
                           "A touch-down hosting bridge must not consume the opening tap")
            XCTAssertTrue(tap.canBePrevented(by: UIPanGestureRecognizer()), "Swiping must scroll without opening")
            XCTAssertTrue(tap.canBePrevented(by: UILongPressGestureRecognizer()), "Holding must show the menu without opening")

            let count = opened.count
            // Invoke the actual registered target/action callback. Assigning a
            // terminal recognizer state cannot synthesise a UIKit touch sequence.
            tap.activate()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(opened.count, count + 1)
            XCTAssertEqual(opened.last, row.ref)
            XCTAssertEqual(sessions.last, h.session.id)

            model.selection.isSelecting = true
            tap.activate()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(opened.count, count + 1, "Selecting a card must not open it")
            XCTAssertTrue(model.selection.refs.contains(row.ref))
            model.selection = LibrarySelection()

            model.reflow.layout = NibReflowLayout(columns: 3, cell: NibMetrics.coverSize)
            model.reflow.begin(row.ref, order: model.documentRefs, at: .zero)
            XCTAssertTrue(model.reflow.isCarried(row.ref))
            tap.activate()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(opened.count, count + 1, "Finishing a reorder must not also open the carried card")
            model.reflow.cancel()
            // This isolated cell has no floating carrier to finish its landing.
            model.reflow.landed()
            XCTAssertFalse(model.reflow.isCarried(row.ref))
        }
    }

    func testNewButtonTapPairSurvivesHostingBridgeAndReattachment() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let host = UIHostingController(rootView: LibraryNewButton(model: model, compact: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

        for compact in [false, true, false] {
            window.rootViewController = nil
            host.rootView = LibraryNewButton(model: model, compact: compact)
            window.rootViewController = host
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let taps = descendants(host.view).flatMap { $0.gestureRecognizers ?? [] }
                .compactMap { $0 as? LibraryNewTapRecognizer }
            XCTAssertEqual(taps.count, 2)
            XCTAssertEqual(Set(taps.map(\.numberOfTapsRequired)), [1, 2])
            for tap in taps {
                let nativeView = try XCTUnwrap(tap.view)
                XCTAssertTrue(nativeView.isUserInteractionEnabled)
                XCTAssertTrue(nativeView.hitTest(CGPoint(x: nativeView.bounds.midX, y: nativeView.bounds.midY), with: nil) === nativeView)
                XCTAssertFalse(tap.canBePrevented(by: UIGestureRecognizer()),
                               "The hosting touch bridge must not cancel New before touch-up")
                let otherTap = try XCTUnwrap(taps.first { $0 !== tap })
                XCTAssertTrue(tap.canBePrevented(by: otherTap),
                              "The native single/double tap pair must retain UIKit arbitration")
            }
        }
    }

    func testReflowMeasurementCannotSwallowDocumentTapAfterReattachment() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.isHidden = false
        defer { window.isHidden = true }
        let document = UIButton(frame: window.bounds)
        window.addSubview(document)
        let probe = NibReflowTouchTarget<String>.Probe(frame: window.bounds)
        for _ in 0..<3 {
            window.addSubview(probe)
            // A native host may re-enable its representable when reused. Geometry
            // must stay transparent independently of that mutable UIView flag.
            probe.isUserInteractionEnabled = true
            let point = CGPoint(x: 150, y: 150)
            XCTAssertNil(probe.hitTest(point, with: nil))
            XCTAssertTrue(window.hitTest(point, with: nil) === document)
            probe.removeFromSuperview()
        }
    }

    func testLiftCannotBeCancelledByTouchDownBridgeBeforeIntentIsKnown() {
        let target = NibReflowTouchTarget(id: "cover", reflow: NibReflow<String>(),
                                         order: ["cover"], onDrop: { _ in })
        let coordinator = target.makeCoordinator()
        let lift = coordinator.gesture
        // The SwiftUI bridge is not a pan or a long press. It can recognise at
        // touch-down; the lift must keep receiving samples until it classifies intent.
        let bridge = UIGestureRecognizer()
        let scroll = UIPanGestureRecognizer()
        let menu = UILongPressGestureRecognizer()
        XCTAssertEqual(lift.state, .possible)
        XCTAssertFalse(lift.canBePrevented(by: bridge))
        XCTAssertFalse(lift.canBePrevented(by: scroll))
        XCTAssertFalse(lift.canBePrevented(by: menu))
        // Verify the actual delegate dependencies rather than assigning a terminal
        // state to a recogniser without touches (UIKit immediately resets it).
        XCTAssertTrue(coordinator.gestureRecognizer(lift, shouldBeRequiredToFailBy: menu),
                      "A stationary hold must give the menu its turn when the lift yields")
        XCTAssertTrue(coordinator.gestureRecognizer(lift, shouldBeRequiredToFailBy: scroll),
                      "An early swipe must scroll after the lift fails, without scrolling during pickup")
        XCTAssertFalse(coordinator.gestureRecognizer(lift, shouldBeRequiredToFailBy: bridge),
                       "The SwiftUI touch bridge must keep delivering button and context-menu input")
        XCTAssertTrue(ReflowLiftIntent.yieldsToMenu(distance: 0))
        XCTAssertFalse(ReflowLiftIntent.yieldsToMenu(distance: 6, stationaryFor: 0))
    }

    func testLibraryDragYieldsToOverlappingMenuAndPanelButAllowsSelectionStack() {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        XCTAssertTrue(LibraryItemReflow.acceptsDrag(model))
        model.selection.isSelecting = true
        XCTAssertTrue(LibraryItemReflow.acceptsDrag(model))
        for menu in ["sort", "new", "app"] {
            model.menu = menu
            XCTAssertFalse(LibraryItemReflow.acceptsDrag(model), "An overlaid menu must not start the card underneath it")
        }
        model.menu = nil
        model.modal = LibraryPanel(id: "test.sheet", params: [:], presentation: .sheet)
        XCTAssertFalse(LibraryItemReflow.acceptsDrag(model))
        model.modal = nil
        model.confirmation = LibraryConfirmation(title: "Combine", command: CommandIDs.libraryMove, params: [:])
        XCTAssertFalse(LibraryItemReflow.acceptsDrag(model))
        model.confirmation = nil
        XCTAssertTrue(LibraryItemReflow.acceptsDrag(model))
    }

    func testNativeLibraryResponderDispatchesSelectAllEscapeAndReturn() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let controller = try XCTUnwrap(controllers.last as? LibraryRootViewController)
        await model.appear()
        var opened: String?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docOpen, title: "Open",
            summary: "Record selected document", effect: .session, target: .app)) { params, _ in
                opened = params["doc"]?.stringValue; return [:]
        }
        func send(_ input: String, modifiers: UIKeyModifierFlags = []) throws {
            let command = try XCTUnwrap(controller.keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers })
            XCTAssertTrue(controller.canPerformAction(try XCTUnwrap(command.action), withSender: command))
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            _ = controller.perform(command.action, with: command)
        }
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "begin"], session: h.session)
        try send("a", modifiers: .command)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.selection.refs, Set(model.visibleRefs))
        XCTAssertTrue(model.selection.refs.contains("folder:FIXTUREFLD01"))
        try send(UIKeyCommand.inputEscape)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(model.selection.isSelecting)
        XCTAssertTrue(model.selection.refs.isEmpty)

        let ref = try XCTUnwrap(model.documentRefs.first)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "replace", "refs": [.string(ref)]], session: h.session)
        try send("\r")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(opened, ref)
        XCTAssertTrue(model.selection.refs.isEmpty)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView,
            ["selection": "replace", "refs": ["folder:FIXTUREFLD01"]], session: h.session)
        try send("\r")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.folder, Fixtures.folderID)
        XCTAssertFalse(model.selection.isSelecting)
    }

    func testNativeNewFolderKeyKeepsItsModifiersAndCurrentParent() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let controller = try XCTUnwrap(controllers.last as? LibraryRootViewController)
        h.app.ui.panels.register(PanelDescriptor(id: "organize.folder.new", title: "New Folder", icon: "folder",
            placement: .sheet, order: 0, owner: "organize") { _ in AnyView(EmptyView()) })
        h.app.content.keyCommands.register(KeyCommandDescriptor(id: "organize.newFolder", title: "New Folder",
            shortcut: KeyShortcut("n", [.command, .control]), command: CommandIDs.librarySetView,
            params: ["panel": "organize.folder.new"], scope: .library, owner: "organize"))
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        let command = try XCTUnwrap(controller.keyCommands?.first { $0.input == "n" })
        XCTAssertEqual(command.modifierFlags, [.command, .control])
        XCTAssertTrue(controller.canPerformAction(try XCTUnwrap(command.action), withSender: nil))
        _ = controller.perform(command.action, with: command)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.modal?.id, "organize.folder.new")
        XCTAssertEqual(model.modal?.params["folder"], "folder:FIXTUREFLD01")
        XCTAssertFalse(controller.canPerformAction(try XCTUnwrap(command.action), withSender: command), "Do not replay a stale key behind a sheet")
    }

    func testUnhandledHardwareKeysUseRegistryWinnerAndRespectTextEditing() {
        let h = harness()
        let keys = h.app.content.keyCommands.all
        let library = KeyCommandContext(inDocument: false, docKind: nil)
        for shortcut in [KeyShortcut("a", .command), KeyShortcut("escape"), KeyShortcut("return")] {
            let descriptor = KeyCommandRouting.unhandledPress(shortcut, descriptors: keys, in: library)
            XCTAssertEqual(descriptor?.command, CommandIDs.librarySetView)
            XCTAssertNil(KeyCommandRouting.unhandledPress(shortcut, descriptors: keys,
                in: KeyCommandContext(inDocument: false, docKind: nil, isEditingText: true)))
            XCTAssertNil(KeyCommandRouting.unhandledPress(shortcut, descriptors: keys,
                in: KeyCommandContext(inDocument: true, docKind: .notebook)))
        }
        XCTAssertNil(KeyCommandRouting.unhandledPress(KeyShortcut("a"), descriptors: keys, in: library))
        let folder = KeyCommandDescriptor(id: "organize.newFolder", title: "New Folder",
            shortcut: KeyShortcut("n", [.command, .control]), command: CommandIDs.panelOpen,
            scope: .library, owner: "organize")
        let global = KeyCommandDescriptor(id: "global.new", title: "New",
            shortcut: folder.shortcut, command: CommandIDs.docOpen, scope: .global, owner: "test")
        XCTAssertEqual(KeyCommandRouting.unhandledPress(folder.shortcut, descriptors: [global, folder], in: library)?.id, folder.id)
        XCTAssertNil(KeyCommandRouting.unhandledPress(KeyShortcut("n", .command), descriptors: [folder], in: library))
    }

    func testFocusedLibraryResponderRoutesGlobalSelectionAndWindowUndoKeys() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let controller = try XCTUnwrap(controllers.last as? LibraryRootViewController)
        var searched = false
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchOpen, title: "Search",
            summary: "Record library search", effect: .session, target: .app)) { _, _ in searched = true; return [:] }
        for (id, shortcut, command) in [
            ("test.open", KeyShortcut("o", .command), CommandIDs.searchOpen),
            ("test.undo", KeyShortcut("z", .command), CommandIDs.undo)
        ] {
            h.app.content.keyCommands.register(KeyCommandDescriptor(id: id, title: id,
                shortcut: shortcut, command: command, scope: .global, owner: "test"))
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await model.appear()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let keyboard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? LibraryKeyboardResponder }.first)
        keyboard.resignFirstResponder()
        XCTAssertTrue(controller.becomeFirstResponder(), "The shell's focus request must reach the library's native responder")
        XCTAssertTrue(keyboard.isFirstResponder)
        XCTAssertTrue(keyboard.performShortcut(KeyShortcut("o", .command)))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(searched)
        model.selection.isSelecting = true
        XCTAssertTrue(keyboard.performShortcut(KeyShortcut("a", .command)))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.selection.refs, Set(model.visibleRefs))
        XCTAssertTrue(keyboard.performShortcut(KeyShortcut("escape")))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(model.selection.isSelecting)
        let previous = model.visibleRefs
        let manager = try XCTUnwrap(window.undoManager, "A live library must have a window undo manager")
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let first = try XCTUnwrap(model.documentRefs.first)
        _ = try await h.app.bus.execute(CommandIDs.libraryReorder, ["refs": [.string(first)]], session: h.session)
        manager.endUndoGrouping()
        XCTAssertNotEqual(model.visibleRefs, previous)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "lib"], session: h.session)
        XCTAssertTrue(keyboard.performShortcut(KeyShortcut("z", .command)))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.visibleRefs, previous)
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        controller.view.addSubview(field)
        field.becomeFirstResponder()
        keyboard.restoreFocus()
        XCTAssertTrue(field.isFirstResponder, "The library must not take focus from name or colour editors")
        XCTAssertFalse(keyboard.performShortcut(KeyShortcut("a", .command)))
    }

    func testLibraryHardwarePressPreservesSeparatelyDeliveredModifiersAndNavigationKeys() {
        XCTAssertEqual(LibraryKeyboardResponder.shortcut(code: .keyboardA, characters: "a", flags: [],
            held: [.keyboardLeftGUI]), KeyShortcut("a", .command))
        XCTAssertEqual(LibraryKeyboardResponder.shortcut(code: .keyboardN, characters: "n", flags: .command,
            held: [.keyboardRightControl]), KeyShortcut("n", [.command, .control]))
        XCTAssertEqual(LibraryKeyboardResponder.shortcut(code: .keyboardReturnOrEnter, characters: "", flags: []), KeyShortcut("return"))
        XCTAssertEqual(LibraryKeyboardResponder.shortcut(code: .keyboardEscape, characters: "", flags: []), KeyShortcut("escape"))
    }

    func testExternalImportDestinationUsesHoveredFolderThenCurrentFolderAndRejectsTabs() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        let controller = try XCTUnwrap(controllers.last as? LibraryRootViewController)
        await model.appear()
        let background = CGPoint(x: 700, y: 400)
        XCTAssertEqual(controller.libraryImportDestination(at: background)?.description, "lib")
        model.dropTargets = ["folder:FIXTUREFLD01": CGRect(x: 340, y: 240, width: 180, height: 80)]
        XCTAssertEqual(controller.libraryImportDestination(at: CGPoint(x: 400, y: 280))?.description, "folder:FIXTUREFLD01")
        model.folder = Fixtures.folderID
        model.dropTargets = [:]
        XCTAssertEqual(controller.libraryImportDestination(at: background)?.description, "folder:FIXTUREFLD01")
        model.tab = LibraryPanel(id: "trash", params: [:], presentation: .libraryTab)
        XCTAssertNil(controller.libraryImportDestination(at: background))
        model.tab = nil
        model.isVisible = false
        XCTAssertNil(controller.libraryImportDestination(at: background))
    }

    func testNewMenuNativeScrollStopsInterceptingAfterDismissalAndReattaches() {
        let scroll = UIScrollView()
        let content = UIView()
        let probe = LibraryMenuScrollInteraction.Probe()
        scroll.addSubview(content)
        content.addSubview(probe)
        probe.isPresented = true
        probe.updateScrollView()
        XCTAssertTrue(scroll.isUserInteractionEnabled)
        XCTAssertFalse(scroll.accessibilityElementsHidden)
        probe.isPresented = false
        probe.updateScrollView()
        XCTAssertFalse(scroll.isUserInteractionEnabled)
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        probe.removeFromSuperview()
        content.addSubview(probe)
        XCTAssertFalse(scroll.isUserInteractionEnabled)
        probe.isPresented = true
        probe.updateScrollView()
        XCTAssertTrue(scroll.isUserInteractionEnabled)
    }

    func testSlowHeldDragKeepsPickupIntentWhileStationaryHoldYieldsToContextMenu() {
        XCTAssertTrue(ReflowLiftIntent.yieldsToMenu(distance: 0))
        XCTAssertFalse(ReflowLiftIntent.yieldsToMenu(distance: 3))
        XCTAssertFalse(ReflowLiftIntent.yieldsToMenu(distance: 3, stationaryFor: 0.05))
        XCTAssertTrue(ReflowLiftIntent.yieldsToMenu(distance: 3, stationaryFor: 0.2), "Small drift that stops must still open the context menu")
        XCTAssertFalse(ReflowLiftIntent.protectsLift(elapsed: 0.15, distance: 10), "An immediate swipe must still scroll")
        XCTAssertTrue(ReflowLiftIntent.protectsLift(elapsed: 0.4, distance: 3), "Slow movement must not lose to a context menu before pickup slop")
        XCTAssertTrue(ReflowLiftIntent.protectsLift(elapsed: 0.7, distance: 10))
        XCTAssertFalse(ReflowLiftIntent.protectsLift(elapsed: 0.7, distance: 0))
    }

    func testDropUsesReleasedFingerAndCorrectCarrierEvenBeforeHoverRender() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.reload()
        var moved: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryMove, title: "Move", summary: "Record move", effect: .library, target: .library)) { params, _ in
            moved = params; return [:]
        }
        let ref = try XCTUnwrap(model.documentRefs.first)
        model.reflow.layout = NibReflowLayout(columns: 3, cell: NibMetrics.coverSize)
        model.reflow.begin(ref, order: model.documentRefs, at: .zero)
        let target = CGRect(x: 10, y: -100, width: 180, height: 78)
        model.dropTargets = ["folder:FIXTUREFLD01": target]
        model.reflow.move(to: CGPoint(x: target.midX, y: target.midY))
        model.dropTarget = nil // The SwiftUI monitor has not rendered this final move.
        let drop = model.reflow.end()
        model.drop(drop, from: model.reflow)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(moved?["refs"], [.string(ref)])
        XCTAssertEqual(moved?["folder"], "folder:FIXTUREFLD01")
        XCTAssertNil(model.dropTarget)
        XCTAssertNotNil(model.floating.toast?.action)
    }

    func testDropDestinationExcludesSelfAndChoosesFolderOverSidebar() {
        let targets = ["sidebar": CGRect(x: 0, y: 0, width: 320, height: 700),
                       "sidebarFolder:folder:DESTINATION": CGRect(x: 20, y: 100, width: 260, height: 44),
                       "folder:SOURCE": CGRect(x: 400, y: 100, width: 200, height: 78)]
        XCTAssertEqual(LibraryDropDestination.match(CGPoint(x: 100, y: 120), carried: "folder:SOURCE", targets: targets)?.key, "folder:DESTINATION")
        XCTAssertNil(LibraryDropDestination.match(CGPoint(x: 450, y: 120), carried: "folder:SOURCE", targets: targets))
        XCTAssertNil(LibraryDropDestination.match(CGPoint(x: 100, y: 400), carried: "folder:SOURCE", targets: targets))
    }

    func testSelectionShortcutsFollowSelectionAndYieldToEditorsAndPanels() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        XCTAssertFalse(LibrarySelectionShortcuts.isEnabled(model))
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["selection": "begin"], session: h.session)
        XCTAssertTrue(LibrarySelectionShortcuts.isEnabled(model))
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatLibraryUIFeature.id }
        XCTAssertEqual(Set(keys.map(\.shortcut.key)), ["a", "escape", "return"])
        let selectAll = try XCTUnwrap(keys.first { $0.shortcut.key == "a" })
        _ = try await h.app.bus.execute(selectAll.command, selectAll.resolvedParams(for: h.session), session: h.session)
        XCTAssertEqual(model.selection.refs, Set(model.visibleRefs))
        model.renaming = model.visibleRefs.first
        XCTAssertFalse(LibrarySelectionShortcuts.isEnabled(model))
        model.renaming = nil; model.menu = "app"
        XCTAssertFalse(LibrarySelectionShortcuts.isEnabled(model))
        model.menu = nil; h.session.isEditingText = true
        XCTAssertFalse(LibrarySelectionShortcuts.isEnabled(model))
        h.session.isEditingText = false
        let escape = try XCTUnwrap(keys.first { $0.shortcut.key == "escape" })
        _ = try await h.app.bus.execute(escape.command, escape.resolvedParams(for: h.session), session: h.session)
        XCTAssertTrue(model.selection.refs.isEmpty)
        XCTAssertFalse(LibrarySelectionShortcuts.isEnabled(model))
    }

    func testOutgoingMenuCannotDismissNewerAppMenu() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["menu": "app"], session: h.session)
        model.setMenuPresented(false, menu: "new")
        model.setMenuPresented(false, menu: "sort")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.menu, "app")
        model.setMenuPresented(false, menu: "app")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.menu)
        // Also cover a dismissal already queued before the new menu command runs.
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["menu": "app"], session: h.session)
        _ = try await h.app.bus.execute(CommandIDs.librarySetView,
            ["menu": "none", "menuIfCurrent": "new"], session: h.session)
        XCTAssertEqual(model.menu, "app")
    }

    func testMenuActivationClosesBudBeforeOpeningInlineRename() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        model.menu = "new"
        var menuAtActivation: String?
        var called = false
        h.app.commands.register(CommandDescriptor(id: "test.menuAction", title: "Action", summary: "Record presentation state", effect: .session, target: .app)) { _, _ in
            called = true; menuAtActivation = model.menu
            return [:]
        }
        model.activateMenu(command: "test.menuAction", params: [:])
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(called)
        XCTAssertNil(menuAtActivation)
        model.menu = "app"
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["rename": "doc:FIXTUREDOC01"], session: h.session)
        XCTAssertNil(model.menu)
        XCTAssertEqual(model.renaming, "doc:FIXTUREDOC01")
    }

    func testDocumentsNavigationClearsTabFolderSearchAndStaleEditors() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        h.app.ui.panels.register(PanelDescriptor(id: "test.tab", title: "Trash", icon: "trash", placement: .libraryTab, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
        for destination in [["collection": "documents"], ["panel": "documents"]] as [JSONValue] {
            _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
            _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": "test.tab"], session: h.session)
            model.menu = "app"; model.search = "missing"; model.renaming = "folder:FIXTUREFLD01"
            model.selection.selectAll(["folder:FIXTUREFLD01"])
            let result = try await h.app.bus.execute(CommandIDs.librarySetView, destination, session: h.session)
            XCTAssertEqual(result["folder"], "lib")
            XCTAssertNil(model.tab); XCTAssertNil(model.folder); XCTAssertNil(model.menu); XCTAssertNil(model.renaming)
            XCTAssertEqual(model.search, "")
            XCTAssertFalse(model.selection.isSelecting)
            XCTAssertFalse(h.session.openPanels.contains("test.tab"))
            XCTAssertTrue(model.documentRefs.contains("doc:FIXTUREDOC01"))
        }
    }

    func testPresentingCreationOrStyleSheetClosesUnderlyingMenu() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        for id in ["create.newNotebook", "organize.folder.new", "test.style"] {
            h.app.ui.panels.register(PanelDescriptor(id: id, title: "Create", icon: "folder", placement: .sheet, order: 0, owner: "test") { _ in AnyView(EmptyView()) })
            model.menu = "new"
            _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": .string(id)], session: h.session)
            XCTAssertNil(model.menu)
            XCTAssertEqual(model.modal?.id, id)
            _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["panel": .string(id), "close": true], session: h.session)
            XCTAssertNil(model.modal)
            XCTAssertNil(model.menu, "Dismissing a sheet must leave its source controls available")
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

    func testContributedLibraryShortcutIsRoutedWithoutSelectionAndKeepsWindowParent() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.ui.panels.register(PanelDescriptor(id: "organize.folder.new", title: "New Folder", icon: "folder",
            placement: .sheet, order: 0, owner: "organize") { _ in AnyView(EmptyView()) })
        h.app.content.keyCommands.register(KeyCommandDescriptor(id: "organize.newFolder", title: "New Folder",
            shortcut: KeyShortcut("n", [.command, .control]), command: CommandIDs.panelOpen,
            params: ["id": "organize.folder.new"], scope: .library, owner: "organize"))
        // Stand in for F017's library forwarding; this target owns the browser and its focused host.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open Panel",
            summary: "Forward to the library", effect: .session, target: .app)) { params, context in
            try await context.execute(CommandIDs.librarySetView, ["panel": params["id"] ?? .null])
        }
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["folder": "folder:FIXTUREFLD01"], session: h.session)
        XCTAssertFalse(model.selection.isSelecting)
        let key = try XCTUnwrap(LibrarySelectionShortcuts.descriptors(model).first { $0.id == "organize.newFolder" })
        XCTAssertEqual(key.shortcut, KeyShortcut("n", [.command, .control]))
        model.session.isEditingText = true
        XCTAssertTrue(LibrarySelectionShortcuts.descriptors(model).isEmpty)
        model.session.isEditingText = false
        _ = try await h.app.bus.execute(key.command, key.resolvedParams(for: h.session), session: h.session)
        XCTAssertEqual(model.modal?.id, "organize.folder.new")
        XCTAssertEqual(model.modal?.params["folder"], "folder:FIXTUREFLD01")
        XCTAssertTrue(LibrarySelectionShortcuts.descriptors(model).isEmpty, "The presented sheet owns keyboard input")
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
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                XCTAssertFalse(descendants(host.view).contains { $0 is UIScrollView },
                               "Closed menus must remove their native scroll hosts, not merely hide them",
                               file: file, line: line)
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

    func testPointerMeasurementRemainsTransparentWhenReattachedAndEnabled() throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let document = UIButton(frame: CGRect(x: 40, y: 40, width: 140, height: 224))
        scroll.addSubview(document)
        let measurement = LibraryPointerMarquee.Probe(frame: scroll.bounds)
        let target = LibraryPointerMarquee { _, _, _ in XCTFail("A document tap must not select a range") }
        let coordinator = target.makeCoordinator()
        for _ in 0..<3 {
            scroll.addSubview(measurement)
            coordinator.attach(measurement)
            // A measurement surface must never own the touch, even when a native
            // hosting/reuse update restores UIView's default interaction flag.
            measurement.isUserInteractionEnabled = true
            let point = CGPoint(x: document.frame.midX, y: document.frame.midY)
            XCTAssertTrue(scroll.hitTest(point, with: nil) === document)
            XCTAssertTrue(coordinator.pan.view === scroll)
            XCTAssertEqual((scroll.gestureRecognizers ?? []).filter { $0 === coordinator.pan }.count, 1)
            XCTAssertEqual(coordinator.pan.allowedTouchTypes,
                           [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
            XCTAssertFalse(coordinator.pan.cancelsTouchesInView)
            coordinator.detach()
            measurement.removeFromSuperview()
            XCTAssertNil(coordinator.pan.view)
        }
    }

    func testDocumentCoversRemainHittableAcrossLibraryRotation() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        await model.appear()
        let host = UIHostingController(rootView: LibraryRootView(model: model, idiom: .pad)
            .environment(\.scenePhase, .active))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        for mode in [NibLiquidMode.full, .off] {
            model.liquidMode = mode
            let portrait = CGSize(width: 1032, height: 1376), landscape = CGSize(width: 1376, height: 1032)
            for (layout, size) in [(LibraryLayout.grid, portrait), (.grid, landscape),
                                   (.list, portrait), (.list, landscape), (.grid, landscape)] {
                model.layout = layout
                // Leaving an editor and reopening the library reattaches its
                // native measurement/gesture hosts; cover this as well as rotation.
                window.rootViewController = nil
                window.rootViewController = host
                window.frame = CGRect(origin: .zero, size: size)
                host.view.frame = window.bounds
                for _ in 0..<30 {
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let probes = descendants(host.view).compactMap { $0 as? NibReflowTouchTarget<String>.Probe }
                XCTAssertFalse(probes.isEmpty)
                var checked = 0
                for probe in probes {
                    let point = probe.convert(CGPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: host.view)
                    guard host.view.bounds.contains(point) else { continue }
                    var ancestor = probe.superview
                    while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
                    let scroll = try XCTUnwrap(ancestor as? UIScrollView)
                    let hit = host.view.hitTest(point, with: nil)
                    XCTAssertTrue(hit === scroll || hit?.isDescendant(of: scroll) == true,
                                  "Library cover at \(point) intercepted by \(String(describing: hit)) in \(mode), \(layout), \(size)")
                    // Being inside the scroll view is insufficient: the native
                    // pointer-marquee measurement view spans the whole grid.
                    let measurementViews = descendants(scroll).compactMap { $0 as? LibraryPointerMarquee.Probe }
                    XCTAssertFalse(measurementViews.isEmpty)
                    for measurement in measurementViews {
                        let localPoint = measurement.convert(point, from: host.view)
                        XCTAssertNil(measurement.hitTest(localPoint, with: nil),
                                     "Coordinate measurement must be transparent to UIKit hit testing")
                        XCTAssertFalse(hit === measurement || hit?.isDescendant(of: measurement) == true,
                                       "The marquee probe intercepted the cover at \(point)")
                    }
                    let marqueePans = (scroll.gestureRecognizers ?? []).filter {
                        $0.delegate is LibraryPointerMarquee.Coordinator
                    }
                    XCTAssertEqual(marqueePans.count, 1, "Pointer selection must remain on the scroll view")
                    XCTAssertEqual(marqueePans.first?.allowedTouchTypes,
                                   [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
                    XCTAssertEqual(marqueePans.first?.cancelsTouchesInView, false)
                    XCTAssertTrue(scroll.isUserInteractionEnabled)
                    checked += 1
                }
                XCTAssertGreaterThan(checked, 0)
            }
        }
    }

    func testPortraitSidebarAndMenusReleaseTheRealGridWhenClosed() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.ui.menus.register(MenuItemDescriptor(
            id: "portrait.hit-test", title: "Menu action", location: .libraryNew, order: 0,
            owner: FeatLibraryUIFeature.id, command: CommandIDs.librarySetView,
            params: { _ in ["menu": "none"] }))
        await model.appear()
        let controller = UIHostingController(rootView: LibraryRootView(model: model, idiom: .pad)
            .environment(\.scenePhase, .active))
        model.controller = controller
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async throws {
            for _ in 0..<20 {
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func gridTarget() throws -> (CGPoint, UIScrollView) {
            let probes = descendants(controller.view).compactMap { $0 as? NibReflowTouchTarget<String>.Probe }
            let probe = try XCTUnwrap(probes.last)
            var ancestor = probe.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            return (probe.convert(CGPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: controller.view),
                    try XCTUnwrap(ancestor as? UIScrollView))
        }
        // Opening a menu deliberately removes the cell's drag recognizer. Keep
        // its measured card point and the stable grid scroll host across that change.
        var measuredTarget: (CGPoint, UIScrollView)?
        func assertGridReceivesTouches(_ receives: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
            let (point, scroll) = try XCTUnwrap(measuredTarget, file: file, line: line)
            XCTAssertTrue(controller.view.bounds.contains(point), file: file, line: line)
            let hit = controller.view.hitTest(point, with: nil)
            XCTAssertEqual(hit === scroll || hit?.isDescendant(of: scroll) == true, receives,
                           "Unexpected hit at \(point): \(String(describing: hit))", file: file, line: line)
            if receives {
                XCTAssertTrue(scroll.isUserInteractionEnabled, file: file, line: line)
                XCTAssertFalse(scroll.accessibilityElementsHidden, file: file, line: line)
            }
        }
        controller.view.frame = window.bounds
        try await settle()
        XCTAssertTrue(model.sidebarVisible, "Compact navigation starts at its root list")
        // A window may attach with compact bounds before its first portrait iPad
        // layout. Both layouts have no inline sidebar, but only the latter is an overlay.
        window.frame = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        controller.view.frame = window.bounds
        for mode in [NibLiquidMode.full, .off] {
            model.liquidMode = mode
            try await settle()
            XCTAssertFalse(model.sidebarVisible, "Portrait starts with the sidebar collapsed")
            measuredTarget = try gridTarget()
            try assertGridReceivesTouches(true)
            for _ in 0..<2 {
                _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["sidebar": true], session: h.session)
                try await settle()
                XCTAssertTrue(model.sidebarVisible, "The overlay must remain open until dismissed")
                let sidebarHit = controller.view.hitTest(
                    CGPoint(x: NibMetrics.sidebarWidth / 2, y: controller.view.bounds.midY), with: nil)
                let scroll = try XCTUnwrap(measuredTarget?.1)
                XCTAssertNotNil(sidebarHit)
                XCTAssertFalse(sidebarHit === scroll || sidebarHit?.isDescendant(of: scroll) == true,
                               "The open sidebar must receive interaction within its frame")
                _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["sidebar": false], session: h.session)
                try await settle()
                try assertGridReceivesTouches(true)
            }
            for menu in ["new", "sort"] {
                _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["menu": .string(menu)], session: h.session)
                try await settle()
                XCTAssertEqual(model.menu, menu)
                XCTAssertNotNil(model.menuAnchors["library." + menu])
                let menuProbes = descendants(controller.view).compactMap { $0 as? LibraryMenuScrollInteraction.Probe }
                XCTAssertEqual(menuProbes.count, 1, "Only the requested menu may own a native scroll host")
                let menuProbe = try XCTUnwrap(menuProbes.first)
                XCTAssertTrue(menuProbe.isPresented)
                var ancestor = menuProbe.superview
                while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
                let menuScroll = try XCTUnwrap(ancestor as? UIScrollView)
                // A short menu's padding is not its native scroll viewport.
                // Measure the actual viewport instead of guessing from its source.
                let menuPoint = menuScroll.convert(CGPoint(x: menuScroll.bounds.midX, y: menuScroll.bounds.midY),
                                                   to: controller.view)
                let menuHit = controller.view.hitTest(menuPoint, with: nil)
                XCTAssertTrue(menuHit === menuScroll || menuHit?.isDescendant(of: menuScroll) == true,
                              "The presented menu viewport must receive interaction")
                _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["menu": "none"], session: h.session)
                try await settle()
                try assertGridReceivesTouches(true)
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
    func testFolderTilesUseViewportColumnsWithTailTruncation() async throws {
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
                // DESIGN §5 requires tail truncation, not columns sized to the longest name.
                let count = LibraryFolderLayout.columnCount(width: width, gutter: compact ? NibSpacing.l : NibMetrics.libraryGutter)
                let gutter = compact ? NibSpacing.l : NibMetrics.libraryGutter
                let expectedWidth = variant == .largeText ? width : (width - CGFloat(count - 1) * gutter) / CGFloat(count)
                for row in rows {
                    let frame = try XCTUnwrap(frames[row.ref], "Every folder must be laid out")
                    XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.5)
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
                var viewportWidth: CGFloat = 0
                let view = LibraryGridView(model: model, compactHeight: true)
                    .environment(\.horizontalSizeClass, .compact)
                    .onPreferenceChange(LibraryFrames.self) { frames = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                _ = try await hostlessLayoutImage(view, size: CGSize(width: width, height: 393), variant: variant)
                XCTAssertEqual(viewportWidth, width, accuracy: 0.5, "The grid must receive the available viewport")
                let folderFrame = try XCTUnwrap(frames[folder.ref])
                let documentFrames = try documents.map { try XCTUnwrap(frames[$0.ref]) }.sorted { $0.minX < $1.minX }
                for frame in documentFrames {
                    XCTAssertGreaterThanOrEqual(frame.minY, folderFrame.maxY + NibSpacing.s)
                    XCTAssertEqual(frame.minY, documentFrames[0].minY, accuracy: 0.5, "All three covers must share the first document row; viewport \(viewportWidth), folder \(folderFrame), documents \(documentFrames)")
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
                XCTAssertLessThanOrEqual(message.height, 2 * NibUIFont.callout.lineHeight + 1, "Viewport \(width), message \(message), action \(action)")
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

    func testPortraitSidebarOverlaysEvenOnThirteenInchIPad() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1032, height: 1376), CGSize(width: 1024, height: 1366)] {
            XCTAssertFalse(LibraryPresentation.usesInlineSidebar(size: size, idiom: .pad))
            XCTAssertTrue(LibraryPresentation.usesInlineSidebar(size: CGSize(width: size.height, height: size.width), idiom: .pad))
        }
        XCTAssertFalse(LibraryPresentation.usesInlineSidebar(size: CGSize(width: 899, height: 700), idiom: .pad))
        XCTAssertTrue(LibraryPresentation.usesInlineSidebar(size: CGSize(width: 900, height: 700), idiom: .pad))
        XCTAssertFalse(LibraryPresentation.usesInlineSidebar(size: CGSize(width: 932, height: 430), idiom: .phone))
    }

    func testSyncCompletionDoesNotLeaveSidebarSyncing() async {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        for (state, expected) in [("syncing", "Backup · Backing up"), ("ok", "Backup · Backup complete"),
                                  ("idle", "Backup · No backup in progress")] {
            h.app.events.emit(SyncStatusPayload(state: state, source: "backup"))
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(model.syncText, expected)
        }
        XCTAssertEqual(LibrarySyncPresentation.text(.init(state: "offline", source: "sync")), "Library · Offline")
        XCTAssertEqual(LibrarySyncPresentation.text(.init(state: "warning", source: "webdav", reason: "offline")), "WebDAV · Offline")
        XCTAssertEqual(LibrarySyncPresentation.text(.init(state: "error", source: "store", message: "Couldn't save this notebook.")), "Couldn't save this notebook.")
        XCTAssertTrue(LibrarySyncPresentation.text(.init(state: "error", source: "backup")).contains("Review Cloud & Backup"))
        XCTAssertFalse(LibrarySyncPresentation.text(.init(state: "unknown", source: "sync")).contains("Syncing"))
    }

    func testBulkActionScopeAndConfirmationCopy() {
        var selection = LibrarySelection()
        XCTAssertEqual(selection.statusText, "Select items")
        selection.toggle("doc:A")
        XCTAssertEqual(selection.statusText, "1 selected")
        selection.toggle("doc:B")
        XCTAssertEqual(selection.statusText, "2 selected")
        selection.clear()
        XCTAssertEqual(selection.statusText, "Select items")
        XCTAssertEqual(LibraryConfirmation.trashMessage(names: ["Physics"]), "Move “Physics” to Trash? You can restore them from Trash.")
        XCTAssertTrue(LibraryConfirmation.trashMessage(names: ["A", "B", "C"]).contains("3 items"))
        let combine = LibraryConfirmation.combineMessage(names: ["Physics", "Chemistry"], destination: "Revision")
        for name in ["Physics", "Chemistry", "Revision"] { XCTAssertTrue(combine.contains(name)) }
        XCTAssertTrue(combine.contains("source documents will move to Trash"))
        XCTAssertEqual(LibrarySort.modified.title, "Date modified")
        XCTAssertEqual(LibrarySort.created.title, "Date created")
    }

    func testWrappingTitlesKeepCoverOriginsOnTheSameRowPitch() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        model.rows = (0..<4).map { index in
            LibraryRow(ref: "doc:PITCH0\(index)", kind: "notebook", title: index == 0 ? "A long notebook title that wraps onto two lines" : "Notes", modified: Double(4 - index))
        }
        model.applySort()
        var frames: [String: CGRect] = [:]
        let view = LibraryGridView(model: model)
            .environment(\.horizontalSizeClass, .regular)
            .onPreferenceChange(LibraryFrames.self) { frames = $0 }
        _ = try await hostlessLayoutImage(view, size: CGSize(width: 304, height: 700), variant: .light)
        let first = try XCTUnwrap(frames["doc:PITCH00"])
        let second = try XCTUnwrap(frames["doc:PITCH01"])
        let next = try XCTUnwrap(frames["doc:PITCH02"])
        XCTAssertEqual(first.minY, second.minY, accuracy: 0.5)
        XCTAssertEqual(next.minY - first.minY, 250, accuracy: 0.5)
    }

    func testAccessibilityGridUsesFullWidthRowsWithoutClippingLongLabels() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        model.rows = [LibraryRow(ref: "doc:AXROW", kind: "textDocument", title: "A long document title that needs more than two lines at accessibility sizes")]
        model.applySort()
        var frames: [String: CGRect] = [:]
        let view = LibraryGridView(model: model)
            .environment(\.horizontalSizeClass, .regular)
            .onPreferenceChange(LibraryFrames.self) { frames = $0 }
        _ = try await hostlessLayoutImage(view, size: CGSize(width: 420, height: 900), variant: .largeText)
        let row = try XCTUnwrap(frames["doc:AXROW"])
        XCTAssertEqual(row.width, 420, accuracy: 0.5)
        XCTAssertGreaterThan(row.height, NibMetrics.barHeightMax)
        XCTAssertEqual(model.layout, .grid, "Accessibility changes presentation, not the saved layout preference")
    }

    func testFolderColumnsFollowAvailableWidthRatherThanNames() {
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 180, gutter: 16), 1)
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 361, gutter: 16), 2)
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 656, gutter: 24), 3)
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 826, gutter: 24), 4)
        XCTAssertEqual(LibraryFolderLayout.columnCount(width: 1400, gutter: 24), 4)
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
    func testFolderDropToastUndoRestoresOriginalParentAndMembership() async throws {
        let h = harness(), model = LibraryModels.get(h.app).model(h.session)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryMove, title: "Move",
            summary: "Move through the library service", effect: .library, target: .library)) { params, ctx in
            let parent = try LibraryModels.folder(params["folder"]?.stringValue)
            for ref in params["refs"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard case .document(let id)? = NodeRef(ref) else { throw NibError.invalid("Expected document") }
                try h.library.move(id, to: parent)
            }
            ctx.events.emit(NibEventType.libraryChanged, principal: ctx.principal, payload: [:])
            return [:]
        }
        await model.appear()
        model.moveDrop(refs: ["doc:FIXTUREDOC01"], destination: "folder:FIXTUREFLD01")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(h.library.node(Fixtures.docID)?.parent, Fixtures.folderID)
        XCTAssertFalse(model.documentRefs.contains("doc:FIXTUREDOC01"))
        let undo = try XCTUnwrap(model.floating.toast?.action)
        XCTAssertEqual(undo.title, "Undo")
        undo.handler()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(h.library.node(Fixtures.docID)?.parent)
        XCTAssertTrue(model.documentRefs.contains("doc:FIXTUREDOC01"))
        XCTAssertFalse(h.library.children(of: Fixtures.folderID).contains { $0.id == Fixtures.docID })
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
        var controller: LibraryRootViewController?
        weak var releasedController: LibraryRootViewController?
        weak var model: LibraryViewModel?
        // UIKit construction can leave temporary autoreleased controller references.
        // Establish one explicit owner before testing removal of that owner.
        autoreleasepool {
            let instance = LibraryRootViewController(app: h.app, navigator: LibraryTestNavigator(app: h.app, session: session))
            controller = instance
            releasedController = instance
            model = instance.model
        }
        _ = try await h.app.bus.execute(CommandIDs.librarySetView, ["layout": "list"], session: session)
        XCTAssertEqual(model?.layout, .list)
        h.app.services.sessions.remove(session)
        autoreleasepool { controller = nil }
        XCTAssertNil(releasedController, "Loaded: \(releasedController?.isViewLoaded == true), parent: \(String(describing: releasedController?.parent)), presenter: \(String(describing: releasedController?.presentingViewController))")
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
        let message = try XCTUnwrap(confirmation.message)
        for ref in refs.prefix(3) {
            XCTAssertTrue(message.contains(try XCTUnwrap(model.rows.first { $0.ref == ref }).name))
        }
        XCTAssertTrue(message.contains("Trash"))
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
