import XCTest
import UIKit
import SwiftUI
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
    var onCall: ((String) -> Void)?

    func params(_ command: String) -> [JSONValue] { calls.filter { $0.command == command }.map { $0.params } }
}

/// A window navigator to exercise scene activation through the real UIKit responder chain.
@MainActor
private final class KeyboardWindowController: UIViewController, SceneNavigator {
    let session: EditorSession
    var modal: UIViewController?
    override var presentedViewController: UIViewController? { modal ?? super.presentedViewController }
    init(session: EditorSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    var openDocuments: [DocumentID] { session.document.map { [$0] } ?? [] }
    var activeDocument: DocumentID? { session.document }
    var rootViewController: UIViewController? { self }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) { present(viewController, animated: false) }
}

/// A custom control, as a feature would build one in UIKit.
private final class TestControl: UIControl {}

/// A feature's own text field subclass: it keeps its I-beam pointer.
private final class TestField: UITextField {}

/// Non-text focus left in a sibling chrome host after a toolbar/layout transition.
private final class TestChromeFocusView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

private struct TestChromeFocusContent: UIViewRepresentable {
    let view: TestChromeFocusView
    func makeUIView(context: Context) -> TestChromeFocusView { view }
    func updateUIView(_ uiView: TestChromeFocusView, context: Context) {}
}

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
                recorder.onCall?(id)
                return .null
            }
        }
        return recorder
    }

    /// Runs a key command exactly as the app shell does (contracts-v2.2): the command with `resolvedParams(for:)` of
    /// the window's session.
    private func press(_ h: Harness, _ name: String) async throws {
        let d = try key(h, name)
        _ = try await h.app.bus.execute(Invocation(command: d.command, params: d.resolvedParams(for: h.session),
                                                   session: h.session))
    }

    private func setSingleKeys(_ h: Harness, _ on: Bool) async throws {
        try await h.run(CommandIDs.settingsSet, ["name": .string(KeyboardSettings.singleKeyShortcuts.name), "value": .bool(on)])
    }

    private func descriptor(_ id: String, _ key: String, _ modifiers: KeyModifiers = [], scope: KeyScope,
                            kinds: Set<DocumentKind>? = nil, owner: String, command: String = "test.run") -> KeyCommandDescriptor {
        var d = KeyCommandDescriptor(id: id, title: id, shortcut: KeyShortcut(key, modifiers), command: command,
                                     scope: scope, owner: owner)
        d.docKinds = kinds
        return d
    }

    // MARK: Acceptance: no shortcut is registered twice

    func testHardwareOnlyInputDoesNotSuppressCanvasNavigation() {
        final class HardwareInput: UIView, UIKeyInput {
            var hasText: Bool { false }
            func insertText(_ text: String) {}
            func deleteBackward() {}
        }
        XCTAssertFalse(CanvasKeyboardFocus.isTextInput(HardwareInput()))
        XCTAssertTrue(CanvasKeyboardFocus.isTextInput(UITextField()))
        XCTAssertTrue(CanvasKeyboardFocus.isTextInput(UITextView()))
    }

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
        // As F021 registers ⌥⌘N (+ New › Notebook) and F047 registers ⇧⌘T.
        try check("newNotebook", "n", [.command, .option], "panel.open", scope: .global,
                  ["id": "create.newNotebook", "kind": "notebook"])
        try check("quickNote", "n", [.command, .shift], "doc.quickNote", scope: .global, [:])
        try check("newTextDocument", "t", [.command, .shift], "commands.batch", scope: .library, [:])
        try check("open", "o", .command, "search.open", scope: .global, ["scope": "lib"])
        try check("searchLibrary", "f", .command, "search.open", scope: .library, ["scope": "lib"])
        try check("rename", "r", .command, "panel.open", scope: .document, ["id": "keyboard.rename"])
        try check("export", "e", [.command, .shift], "export.present", scope: .document)
        try check("print", "p", .command, "print.present", scope: .document)
        try check("share", "s", [.command, .shift], "export.present", scope: .document)
        try check("find", "f", .command, "search.open", scope: .document, ["scope": "document"])
        try check("assistant", "j", .command, "ai.chat.open", scope: .document, [:])
        try check("findNext", "g", .command, "search.step", scope: .document, ["direction": "next"])
        try check("findPrevious", "g", [.command, .shift], "search.step", scope: .document, ["direction": "previous"])
        try check("goToPage", "g", [.command, .option], "panel.open", scope: .document, ["id": "keyboard.goToPage"])
        try check("zoomIn", "+", .command, "commands.batch", scope: .document)
        try check("zoomOut", "-", .command, "commands.batch", scope: .document)
        try check("zoomToFit", "0", .command, "view.zoom", scope: .document, ["fit": true])
        try check("actualSize", "0", [.command, .option], "view.zoom", scope: .document, ["actual": true])
        try check("sidebar", "s", [.command, .control], "sidebar.toggle", scope: .document, [:])
        for n in 1...9 {
            try check("tab\(n)", String(n), .command, "tab.select", scope: .document,
                      ["index": .number(Double(n == 9 ? -1 : n - 1))])
            let tab = try key(h, "tab\(n)")
            XCTAssertTrue(tab.whileTabsOpen, "⌘\(n) switches tabs from the library while the strip shows")
            XCTAssertTrue(tab.isActive(in: KeyCommandContext(docKind: nil, hasTabs: true)))
            XCTAssertFalse(tab.isActive(in: KeyCommandContext(docKind: nil, hasTabs: false)))
        }
        try check("deselect", "escape", [], "commands.batch", scope: .canvas)
        try check("delete", "delete", [], "commands.batch", scope: .canvas)
        try check("selectAll", "a", .command, "commands.batch", scope: .canvas)
        XCTAssertFalse(h.app.content.keyCommands.all.contains { $0.shortcut == KeyShortcut("w", [.command, .shift]) },
                       "⇧⌘W is New Whiteboard's (F044)")
        for name in ["zoomIn", "zoomToFit", "actualSize", "goToPage", "delete"] {
            XCTAssertEqual(try key(h, name).docKinds, [.notebook, .whiteboard], name)
        }
        XCTAssertNil(try key(h, "find").docKinds)
        for d in h.app.content.keyCommands.all {
            XCTAssertNil(d.params["keyboardShortcut"], "\(d.id): static params are what plugins and the AI read")
        }
    }

    func testLibraryCreationBridgeRoutesAllFourShortcutsToItsWindow() async throws {
        let h = await started()
        h.session.document = nil
        let root = KeyboardWindowController(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: root)
        // F044 owns this key; F073 must bridge its descriptor without registering a duplicate.
        var board = descriptor("whiteboard.new", "w", [.command, .shift], scope: .library,
                               owner: "whiteboard", command: CommandIDs.panelOpen)
        board.params = ["id": "whiteboard.create"]
        h.app.content.keyCommands.register(board)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(LibraryCreationShortcuts.overlayID))
        XCTAssertTrue(overlay.isVisible(context))
        XCTAssertEqual(overlay.surface, .none)
        let keys = LibraryCreationShortcuts.descriptors(in: context)
        XCTAssertEqual(Set(keys.map(\.shortcut)), LibraryCreationShortcuts.shortcuts)
        XCTAssertTrue(ShortcutRules.conflicts(in: h.app.content.keyCommands.all).isEmpty)
        for key in keys {
            let binding = LibraryCreationShortcuts.shortcut(key.shortcut)
            XCTAssertEqual(binding.key.character, key.shortcut.key.first)
            XCTAssertTrue(binding.modifiers.contains(.command))
            XCTAssertEqual(binding.modifiers.contains(.shift), key.shortcut.modifiers.contains(.shift))
            XCTAssertEqual(binding.modifiers.contains(.option), key.shortcut.modifiers.contains(.option))
        }

        let recorder = stand(in: h, for: [CommandIDs.panelOpen, CommandIDs.docQuickNote,
                                          CommandIDs.docCreate, CommandIDs.docOpen])
        // Each press starts with another window active, as in a multiple-window iPad session.
        let other = EditorSession()
        other.document = Fixtures.docID
        let otherRoot = KeyboardWindowController(session: other)
        h.app.services.sessions.add(other)
        for (id, command) in [("keyboard.newNotebook", CommandIDs.panelOpen),
                              ("keyboard.quickNote", CommandIDs.docQuickNote),
                              ("keyboard.newTextDocument", CommandIDs.docOpen),
                              ("keyboard.newTextDocument", CommandIDs.docOpen),
                              (board.id, CommandIDs.panelOpen)] {
            h.app.ui.activeNavigator = otherRoot
            h.app.services.sessions.activate(other)
            let ran = expectation(description: id)
            recorder.onCall = { if $0 == command { ran.fulfill() } }
            LibraryCreationShortcuts.perform(id, in: context)
            await fulfillment(of: [ran], timeout: 3)
            recorder.onCall = nil
            XCTAssertTrue(h.app.ui.activeNavigator === root)
            XCTAssertTrue(h.app.services.sessions.active === h.session)
        }
        XCTAssertEqual(recorder.params(CommandIDs.panelOpen), [
            ["id": "create.newNotebook", "kind": "notebook"], ["id": "whiteboard.create"]
        ])
        XCTAssertEqual(recorder.params(CommandIDs.docQuickNote), [[:]])
        let created = recorder.params(CommandIDs.docCreate)
        XCTAssertEqual(created.compactMap { $0["kind"]?.stringValue }, ["textDocument", "textDocument"])
        let ids = created.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(Set(ids).count, 2, "Resolve a fresh document ID on every press")
        XCTAssertEqual(recorder.params(CommandIDs.docOpen),
                       ids.map { ["doc": .string(NodeRef.document(NibID($0)).description)] })
    }

    func testLibraryCreationBridgeRevalidatesScopeAndReplacement() async throws {
        let h = await started()
        h.session.document = nil
        let root = KeyboardWindowController(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: root)
        let original = try key(h, "newNotebook")
        var replacement = original
        replacement.id = "plugin.newNotebook"
        replacement.owner = "plugin"
        replacement.scope = .library
        replacement.order = -1
        h.app.content.keyCommands.register(replacement)
        let live = LibraryCreationShortcuts.descriptors(in: context)
        XCTAssertFalse(live.contains { $0.id == original.id })
        XCTAssertTrue(live.contains { $0.id == replacement.id })
        h.app.ui.activeNavigator = nil
        root.modal = UIViewController()
        LibraryCreationShortcuts.perform(replacement.id, in: context)
        XCTAssertNil(h.app.ui.activeNavigator, "Creation must not run behind an existing modal")
        XCTAssertEqual(LibraryCreationShortcuts.descriptors(in: context).map(\.id), live.map(\.id),
                       "Keep bindings installed across modal dismissal; revalidate when pressed")
        root.modal = nil
        LibraryCreationShortcuts.perform(original.id, in: context)
        XCTAssertNil(h.app.ui.activeNavigator, "Stale shortcuts must not dispatch or activate a window")
        h.session.document = Fixtures.docID
        XCTAssertTrue(LibraryCreationShortcuts.descriptors(in: context).isEmpty)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(LibraryCreationShortcuts.overlayID))
        XCTAssertFalse(overlay.isVisible(context), "The bridge belongs only to the library hosting tree")
        h.session.document = nil
        var documentContext = context
        documentContext.kind = .textDocument
        XCTAssertTrue(LibraryCreationShortcuts.descriptors(in: documentContext).isEmpty)
        XCTAssertFalse(overlay.isVisible(documentContext))
    }

    func testHostedLibraryCreationShortcutsHaveNativeTargetsAndDispatchToTheirScene() async throws {
        let h = await started()
        h.session.document = nil
        let root = KeyboardWindowController(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: root)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(LibraryCreationShortcuts.overlayID))
        let host = UIHostingController(rootView: overlay.makeView(context))
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = root.view.bounds
        host.view.layoutIfNeeded()

        func responder(in view: UIView) -> LibraryCreationKeyboardResponder? {
            if let keyboard = view as? LibraryCreationKeyboardResponder { return keyboard }
            return view.subviews.lazy.compactMap { responder(in: $0) }.first
        }
        let keyboard = try XCTUnwrap(responder(in: host.view),
            "The rendered overlay must install a native target, not invisible SwiftUI shortcut buttons")
        keyboard.restoreFocus()
        XCTAssertTrue(CanvasKeyboardFocus.firstResponder(in: window) === keyboard)
        XCTAssertFalse(keyboard is any UIKeyInput, "Library focus must not open a software keyboard")

        let recorder = stand(in: h, for: [CommandIDs.panelOpen, CommandIDs.docQuickNote,
                                          CommandIDs.docCreate, CommandIDs.docOpen])
        let other = EditorSession()
        let otherRoot = KeyboardWindowController(session: other)
        h.app.services.sessions.add(other)
        let cases: [(String, UIKeyModifierFlags, String)] = [
            ("n", [.command, .alternate], CommandIDs.panelOpen),
            ("n", [.command, .shift], CommandIDs.docQuickNote),
            ("t", [.command, .shift], CommandIDs.docOpen),
            ("t", [.command, .shift], CommandIDs.docOpen)
        ]
        for (input, modifiers, expected) in cases {
            h.app.ui.activeNavigator = otherRoot
            h.app.services.sessions.activate(other)
            let command = try XCTUnwrap(keyboard.keyCommands?.first {
                $0.input == input && $0.modifierFlags == modifiers
            })
            let action = try XCTUnwrap(command.action)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertTrue(keyboard.canPerformAction(action, withSender: nil), "UIKit's discovery probe needs a target")
            XCTAssertTrue(keyboard.canPerformAction(action, withSender: command))
            // ARCHITECTURE §15.10: package tests have no application host/scene to
            // route UIApplication's nil-target sendAction. Start at the actual
            // focused responder, as UIKit does when discovering hardware keys.
            let focused = try XCTUnwrap(CanvasKeyboardFocus.firstResponder(in: window))
            let target = try XCTUnwrap(focused.target(forAction: action, withSender: command) as? UIResponder)
            XCTAssertTrue(target === keyboard)
            let ran = expectation(description: expected)
            recorder.onCall = { if $0 == expected { ran.fulfill() } }
            _ = target.perform(action, with: command)
            await fulfillment(of: [ran], timeout: 3)
            recorder.onCall = nil
            XCTAssertTrue(h.app.ui.activeNavigator === root)
            XCTAssertTrue(h.app.services.sessions.active === h.session)
        }
        XCTAssertEqual(recorder.params(CommandIDs.panelOpen), [["id": "create.newNotebook", "kind": "notebook"]])
        XCTAssertEqual(recorder.params(CommandIDs.docQuickNote), [[:]])
        let created = recorder.params(CommandIDs.docCreate)
        XCTAssertEqual(created.compactMap { $0["kind"]?.stringValue }, ["textDocument", "textDocument"])
        let ids = created.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(recorder.params(CommandIDs.docOpen),
                       ids.map { ["doc": .string(NodeRef.document(NibID($0)).description)] })
    }

    func testLibraryCreationNativeResponderRevalidatesAndPreservesTextAndModalFocus() async throws {
        let h = await started()
        h.session.document = nil
        let root = KeyboardWindowController(session: h.session)
        let keyboard = LibraryCreationKeyboardResponder(context: ChromeContext(app: h.app, session: h.session, navigator: root))
        root.view.addSubview(keyboard)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        keyboard.restoreFocus()
        XCTAssertTrue(keyboard.isFirstResponder)
        let original = try key(h, "newNotebook")
        let stale = try XCTUnwrap(keyboard.keyCommands?.first { $0.propertyList as? String == original.id })
        let action = try XCTUnwrap(stale.action)
        var replacement = original
        replacement.id = "plugin.newNotebook"
        replacement.owner = "plugin"
        replacement.scope = .library
        replacement.order = -1
        h.app.content.keyCommands.register(replacement)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: stale))
        XCTAssertTrue(keyboard.keyCommands?.contains { $0.propertyList as? String == replacement.id } == true)
        h.app.ui.activeNavigator = nil
        _ = keyboard.perform(action, with: stale)
        XCTAssertNil(h.app.ui.activeNavigator, "A replaced command must not activate or mutate a scene")

        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        keyboard.restoreFocus()
        XCTAssertTrue(field.isFirstResponder, "Creation shortcuts must not steal text focus")
        field.resignFirstResponder()
        root.modal = UIViewController()
        keyboard.restoreFocus()
        XCTAssertFalse(keyboard.isFirstResponder)
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
        root.modal = nil
        keyboard.restoreFocus()
        XCTAssertTrue(keyboard.isFirstResponder, "Native keys return after dismissing a sheet")

        h.session.document = Fixtures.docID
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true, "A retained library view must not route in a document")
        h.session.document = nil
        let otherWindow = UIWindow(frame: window.bounds)
        otherWindow.rootViewController = UIViewController()
        otherWindow.makeKeyAndVisible()
        defer { otherWindow.isHidden = true }
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true, "An inactive scene must not offer creation commands")
        keyboard.restoreFocus()
        XCTAssertFalse(window.isKeyWindow)
        keyboard.context = nil
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true, "A dismantled overlay must not dispatch")
    }

    func testLibraryCreationForwardedPressKeepsModifiersAndDispatchesOnce() async throws {
        let h = await started()
        h.session.document = nil
        let root = KeyboardWindowController(session: h.session)
        let keyboard = LibraryCreationKeyboardResponder(context: ChromeContext(app: h.app, session: h.session, navigator: root))
        root.view.addSubview(keyboard)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        keyboard.restoreFocus()
        let recorder = stand(in: h, for: [CommandIDs.docQuickNote])
        let shortcut = CanvasKeyPress.shortcut(code: .keyboardN, characters: "N", keyFlags: [],
            eventFlags: [], heldKeys: [.keyboardLeftGUI, .keyboardRightShift])
        XCTAssertEqual(shortcut, KeyShortcut("n", [.command, .shift]))
        let ran = expectation(description: "Forwarded QuickNote chord")
        recorder.onCall = { if $0 == CommandIDs.docQuickNote { ran.fulfill() } }
        XCTAssertTrue(keyboard.performUnhandledPress(shortcut))
        await fulfillment(of: [ran], timeout: 3)
        recorder.onCall = nil
        XCTAssertEqual(recorder.params(CommandIDs.docQuickNote).count, 1)
        XCTAssertFalse(keyboard.performUnhandledPress(KeyShortcut("n")), "Plain typing is not creation")
        root.modal = UIViewController()
        XCTAssertFalse(keyboard.performUnhandledPress(shortcut), "A modal owns hardware input")
        root.modal = nil
        h.session.document = Fixtures.docID
        XCTAssertFalse(keyboard.performUnhandledPress(shortcut), "The retained library must not create in a document")
        XCTAssertEqual(recorder.params(CommandIDs.docQuickNote).count, 1)
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

    func testClashesBetweenOtherOwnersAreLeftToTheShell() async throws {
        let h = Harness(features: [])
        let registry = h.app.content.keyCommands
        // The Pencil feature and audio both map ⌥⌘P at `.document` for every kind; the lower order wins everywhere.
        registry.register(descriptor("pencilhw.palette", "p", [.command, .option], scope: .document, owner: "pencilhw",
                                     command: "pencil.palette"))
        var audio = descriptor("audio.key.play", "p", [.command, .option], scope: .document, owner: "audio",
                               command: "audio.play")
        audio.order = -5
        registry.register(audio)
        // A plugin's ⌘D for every kind and the clipboard's ⌘D on canvases: each wins somewhere.
        registry.register(descriptor("dev.plugin.d", "d", .command, scope: .document, owner: "dev.plugin"))
        registry.register(descriptor("clipboard.duplicate", "d", .command, scope: .document,
                                     kinds: [.notebook, .whiteboard], owner: "clipboard"))
        h.app.register([FeatKeyboardFeature.self])
        await FeatKeyboardFeature.start(h.app)

        for id in ["pencilhw.palette", "audio.key.play", "dev.plugin.d", "clipboard.duplicate"] {
            XCTAssertNotNil(registry.get(id), "\(id): other owners' registrations are left alone")
        }
        let mine = Set(registry.all.filter { $0.owner == FeatKeyboardFeature.id }.map { $0.id })
        XCTAssertTrue(ShortcutRules.conflicts(in: registry.all).allSatisfy { !mine.contains($0.0) && !mine.contains($0.1) },
                      "\(ShortcutRules.conflicts(in: registry.all))")

        // The shell's routing: audio wins ⌥⌘P everywhere; ⌘D is the clipboard's on canvases, the plugin's elsewhere.
        XCTAssertEqual(ShortcutRules.hidden(in: registry.all), ["pencilhw.palette"])
        let list = ShortcutDirectory.sections(active: registry.all, query: "").flatMap { $0.entries }
        XCTAssertEqual(list.first { $0.id == "pencilhw.palette" }?.status, .keysTaken)
        XCTAssertEqual(list.first { $0.id == "audio.key.play" }?.status, .active)
        XCTAssertEqual(list.first { $0.id == "dev.plugin.d" }?.status, .active)

        registry.unregister(id: "audio.key.play")
        XCTAssertTrue(ShortcutRules.hidden(in: registry.all).isEmpty)
    }

    func testHiddenKeysFollowTheShellsRanking() {
        // Fewer document kinds win, then the narrower scope, then the lower order, then the id.
        var early = descriptor("b.early", "k", .command, scope: .document, owner: "b")
        early.order = 1
        var late = descriptor("a.late", "k", .command, scope: .document, owner: "a")
        late.order = 2
        let notebooks = descriptor("c.notebooks", "k", .command, scope: .canvas, kinds: [.notebook], owner: "c")
        let library = descriptor("d.library", "k", .command, scope: .library, owner: "d")
        let global = descriptor("e.global", "k", .command, scope: .global, owner: "e")
        XCTAssertEqual(ShortcutRules.hidden(in: [late, early, notebooks, library, global]), ["a.late", "e.global"])
        XCTAssertEqual(ShortcutRules.hidden(in: [late, early]), ["a.late"])
        XCTAssertTrue(ShortcutRules.hidden(in: [early, library]).isEmpty, "the library and documents never share keys")
    }

    // MARK: Single-key shortcuts can be switched off (P-054)

    func testSingleKeySwitchWithholdsAndRestoresEveryOwnersSingleKeys() async throws {
        let h = Harness(features: [])
        let registry = h.app.content.keyCommands
        let tools = ["p", "e", "["]
        for k in tools {
            registry.register(descriptor("toolbar.key." + k, k, scope: .canvas, kinds: [.notebook, .whiteboard],
                                         owner: "toolbar"))
        }
        registry.register(descriptor("toolbar.key.nextPen", "p", .shift, scope: .canvas, owner: "toolbar"))
        registry.register(descriptor("pencilhw.palette", "p", [.command, .option], scope: .document, owner: "pencilhw"))
        registry.register(descriptor("pencilhw.key.swap", "s", scope: .canvas, owner: "pencilhw"))
        h.app.register([FeatKeyboardFeature.self])
        await FeatKeyboardFeature.start(h.app)
        let rt = try runtime(h)
        XCTAssertEqual(h.app.settings.descriptor(KeyboardSettings.singleKeyShortcuts.name)?.synced, false)
        func isOff(_ id: String) -> Bool {
            guard let d = registry.get(id) else { return false }
            return ShortcutRules.situations(of: d).isEmpty
        }

        try await setSingleKeys(h, false)
        for id in ["toolbar.key.p", "toolbar.key.e", "toolbar.key.[", "toolbar.key.nextPen", "pencilhw.key.swap"] {
            XCTAssertTrue(isOff(id), "\(id) stays registered but no window offers it")
        }
        XCTAssertEqual(registry.all.filter { $0.owner == "toolbar" }.count, 4, "owners still see their keys")
        XCTAssertNotNil(registry.get("pencilhw.palette"))
        XCTAssertFalse(isOff("pencilhw.palette"), "shortcuts with ⌘, ⌥ or ⌃ stay")
        XCTAssertFalse(isOff("keyboard.delete"), "Delete and Escape are not single-key shortcuts")
        XCTAssertFalse(isOff("keyboard.deselect"))
        XCTAssertEqual(rt.withheldDescriptors.first { $0.id == "toolbar.key.p" }?.scope, .canvas,
                       "the list shows where the key works when it is on")

        // Registered while off: switched off at once. Dropped by its owner while off: gone for good. Replaced by its
        // owner while off: switched off in its new form.
        registry.register(descriptor("toolbar.key.h", "h", scope: .canvas, owner: "toolbar"))
        XCTAssertTrue(isOff("toolbar.key.h"))
        registry.unregister(id: "toolbar.key.e")
        registry.register(descriptor("toolbar.key.[", "[", scope: .document, kinds: [.whiteboard], owner: "toolbar"))
        XCTAssertTrue(isOff("toolbar.key.["))
        // An owner that drops its last ⌘ key keeps its switched-off single keys.
        registry.unregister(id: "pencilhw.palette")
        XCTAssertEqual(Set(rt.withheldDescriptors.map { $0.id }),
                       ["toolbar.key.p", "toolbar.key.[", "toolbar.key.nextPen", "toolbar.key.h", "pencilhw.key.swap"])

        try await setSingleKeys(h, true)
        XCTAssertEqual(registry.get("toolbar.key.p")?.scope, .canvas)
        XCTAssertEqual(registry.get("toolbar.key.p")?.docKinds, [.notebook, .whiteboard])
        XCTAssertEqual(registry.get("toolbar.key.[")?.scope, .document, "the owner's latest registration")
        XCTAssertEqual(registry.get("toolbar.key.[")?.docKinds, [.whiteboard])
        for id in ["toolbar.key.p", "toolbar.key.[", "toolbar.key.nextPen", "toolbar.key.h", "pencilhw.key.swap"] {
            XCTAssertFalse(isOff(id), "\(id) is back")
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
        var tabKey = descriptor("g", "1", .command, scope: .document, owner: "y")
        let libraryOne = descriptor("h", "1", .command, scope: .library, owner: "x")
        XCTAssertFalse(ShortcutRules.overlap(tabKey, libraryOne))
        tabKey.whileTabsOpen = true
        XCTAssertTrue(ShortcutRules.situations(of: tabKey).contains(.library(tabs: true)))
        XCTAssertFalse(ShortcutRules.situations(of: tabKey).contains(.library(tabs: false)))
        XCTAssertTrue(ShortcutRules.overlap(tabKey, libraryOne), "a tab key is live in the library while tabs are open")
        XCTAssertEqual(ShortcutRules.conflicts(in: [libraryF, documentF, globalKinds]).map { "\($0.0)|\($0.1)" }, ["b|f"])
    }

    // MARK: Shortcuts that read the window

    func testAssistantKeysRouteThroughCanvasResponderWithoutChangingSelectionOrOtherWindow() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let other = EditorSession()
        other.document = Fixtures.whiteboardID
        other.openPanels = [PanelIDs.assistant]
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        h.session.selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID])
        let selection = h.session.selection
        let content = try h.app.workspace.content(doc)
        let history = h.undoDepths()
        var sessions: [EditorSession?] = []
        var commands: [String] = []
        let opened = expectation(description: "Assistant opened in the canvas window")
        let closed = expectation(description: "Assistant closed in the canvas window")
        for command in ["ai.chat.open", "ai.chat.close"] {
            h.app.commands.register(CommandDescriptor(id: command, title: command, summary: "test double",
                                                      effect: .session, target: .app)) { _, ctx in
                sessions.append(ctx.activeSession)
                commands.append(command)
                if command == "ai.chat.open" {
                    ctx.activeSession?.openPanels.insert(PanelIDs.assistant)
                    opened.fulfill()
                } else {
                    ctx.activeSession?.openPanels.remove(PanelIDs.assistant)
                    closed.fulfill()
                }
                return [:]
            }
        }
        func send(_ input: String, _ modifiers: UIKeyModifierFlags) throws {
            let key = try XCTUnwrap(attachment.keyboard.keyCommands?.first {
                $0.input == input && $0.modifierFlags == modifiers
            })
            let action = try XCTUnwrap(key.action)
            XCTAssertTrue(attachment.keyboard.canPerformAction(action, withSender: key))
            _ = attachment.keyboard.perform(action, with: key)
        }
        try send("j", .command)
        await fulfillment(of: [opened], timeout: 3)
        try send(UIKeyCommand.inputEscape, [])
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertEqual(commands, ["ai.chat.open", "ai.chat.close"])
        XCTAssertTrue(sessions.allSatisfy { $0 === h.session })
        XCTAssertFalse(h.session.openPanels.contains(PanelIDs.assistant))
        XCTAssertEqual(other.openPanels, [PanelIDs.assistant])
        XCTAssertEqual(h.session.selection, selection)
        XCTAssertEqual(try h.app.workspace.content(doc), content)
        XCTAssertEqual(h.undoDepths(), history)
        // Closing restores Escape's ordinary page-selection behavior in this same window.
        let recorder = stand(in: h, for: [CommandIDs.selectionClear])
        try await press(h, "deselect")
        XCTAssertEqual(recorder.params(CommandIDs.selectionClear), [[:]])
        XCTAssertFalse(try key(h, "assistant").isActive(in: KeyCommandContext(docKind: nil)))
    }

    func testSessionShortcutsResolveTheWindow() async throws {
        let h = await started()
        let recorder = stand(in: h, for: ["item.delete", "selection.clear", "selection.selectAll", "view.zoom",
                                          "export.present", "print.present", "panel.open", "doc.create", "doc.open"])
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

        // ⌥⌘N from a document: the New Notebook sheet in the document's folder.
        try await press(h, "newNotebook")
        XCTAssertEqual(recorder.params("panel.open").last,
                       ["id": "create.newNotebook", "kind": "notebook",
                        "folder": .string(NodeRef.folder(Fixtures.folderID).description)])
        // ⇧⌘T: a fresh text document each time, created then opened.
        try await press(h, "newTextDocument")
        try await press(h, "newTextDocument")
        let created = recorder.params("doc.create")
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.compactMap { $0["kind"]?.stringValue }, ["textDocument", "textDocument"])
        let ids = created.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(Set(ids).count, 2, "every press makes a new document")
        XCTAssertEqual(recorder.params("doc.open"), ids.map { ["doc": .string(NodeRef.document(NibID($0)).description)] })
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
        for name in ["delete", "deselect", "selectAll", "zoomIn", "zoomOut"] {
            try await press(h, name)
        }
        XCTAssertTrue(recorder.calls.isEmpty, "\(recorder.calls)")
        // Keys whose call is always the same are never offered there.
        let text = KeyCommandContext(docKind: .textDocument, hasTabs: true)
        for name in ["zoomToFit", "actualSize", "goToPage"] {
            XCTAssertFalse(try key(h, name).isActive(in: text), name)
            XCTAssertTrue(try key(h, name).isActive(in: KeyCommandContext(docKind: .whiteboard, hasTabs: true)), name)
        }
    }

    // Exercise the UIKeyCommand target, rather than invoking descriptors directly as `press` does above.
    func testCanvasResponderRoutesSelectionNavigationAndZoomToItsOwnSession() async throws {
        let h = await started()
        let recorder = stand(in: h, for: ["selection.selectAll", "item.delete", "panel.open", "view.zoom"])
        let host = FakeCanvasHost(h)
        let editor = FakeEditor(host)
        h.session.editor = editor
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }

        // The page owner replaces F073's fallback. The responder must use the actual Go to Page dialog.
        var go = descriptor("pages.goToPage", "g", [.command, .option], scope: .document,
                            kinds: [.notebook], owner: "pages", command: "panel.open")
        go.params = ["id": "pages.goToPage"]
        h.app.content.keyCommands.register(go)
        // Another window is active: this canvas must still target the window that owns its responder.
        let other = EditorSession()
        other.document = Fixtures.textDocID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)

        func send(_ input: String, _ modifiers: UIKeyModifierFlags, expecting id: String) async throws {
            let key = try XCTUnwrap(attachment.keyboard.keyCommands?.first {
                $0.input == input && $0.modifierFlags == modifiers
            })
            let action = try XCTUnwrap(key.action)
            XCTAssertTrue(attachment.keyboard.canPerformAction(action, withSender: key))
            let ran = expectation(description: id)
            recorder.onCall = { if $0 == id { ran.fulfill() } }
            _ = attachment.keyboard.perform(action, with: key)
            await fulfillment(of: [ran], timeout: 3)
            recorder.onCall = nil
        }

        try await send("a", .command, expecting: "selection.selectAll")
        XCTAssertEqual(recorder.params("selection.selectAll").last,
                       ["page": .string(NodeRef.page(doc, Fixtures.page1).description)])
        // Resolve the selection when Delete is pressed, after Select All changed it.
        h.session.selection = Selection(doc: doc, page: Fixtures.page1, items: [Fixtures.strokeID])
        try await send(UIKeyCommand.inputDelete, [], expecting: "item.delete")
        XCTAssertEqual(recorder.params("item.delete").last,
                       ["refs": [.string(NodeRef.item(doc, Fixtures.page1, Fixtures.strokeID).description)]])
        try await send("g", [.command, .alternate], expecting: "panel.open")
        XCTAssertEqual(recorder.params("panel.open").last, ["id": "pages.goToPage"])
        try await send("0", [.command, .alternate], expecting: "view.zoom")
        XCTAssertEqual(recorder.params("view.zoom").last, ["actual": true])
        host.zoomScale = 1
        try await send("=", .command, expecting: "view.zoom")
        XCTAssertEqual(recorder.params("view.zoom").last, ["scale": 1.25])
        host.zoomScale = 1.25
        try await send("+", .command, expecting: "view.zoom")
        XCTAssertEqual(recorder.params("view.zoom").last, ["scale": 1.5])
        host.zoomScale = 1.6798817363257628
        host.canvasView.bounds.size = CGSize(width: 768, height: 1024)
        attachment.canvasDidChange(host)
        try await send("-", .command, expecting: "view.zoom")
        XCTAssertEqual(recorder.params("view.zoom").last, ["scale": 1.5], "Read the canvas zoom after rotation")
        try await send("0", .command, expecting: "view.zoom")
        XCTAssertEqual(recorder.params("view.zoom").last, ["fit": true])
        withExtendedLifetime(editor) {}
    }

    func testCanvasResponderRoutesFeatureOwnedPaletteShortcutAndRevalidatesItsWinner() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let root = KeyboardWindowController(session: h.session)
        root.view.addSubview(host.canvasView)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let keyboard = attachment.keyboard
        keyboard.restoreFocus()
        XCTAssertTrue(CanvasKeyboardFocus.firstResponder(in: window) === keyboard)

        // F043's shortcut is not in GlobalShortcuts.catalog. Register after attachment, as a
        // feature/plugin can, and exercise discovery and dispatch through the actual responder.
        var palette = descriptor("pencilhw.palette", "p", [.control, .command], scope: .document,
                                 kinds: [.notebook, .whiteboard], owner: "pencilhw", command: CommandIDs.pencilPalette)
        palette.params = ["kind": "tools"]
        h.app.content.keyCommands.register(palette)
        var receivedSession: EditorSession?
        var receivedParams: JSONValue?
        let ran = expectation(description: "Pencil palette in the keyboard's window")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.pencilPalette, title: "Palette",
            summary: "Records the palette request.", effect: .session, target: .app)) { params, ctx in
            receivedSession = ctx.activeSession
            receivedParams = params
            ran.fulfill()
            return [:]
        }
        let other = EditorSession()
        other.document = Fixtures.textDocID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        let key = try XCTUnwrap(keyboard.keyCommands?.first { $0.propertyList as? String == palette.id })
        let action = try XCTUnwrap(key.action)
        let target = try XCTUnwrap(keyboard.target(forAction: action, withSender: nil) as? UIResponder)
        XCTAssertTrue(target === keyboard)
        XCTAssertEqual(key.input, "p")
        XCTAssertEqual(key.modifierFlags, [.control, .command])
        XCTAssertTrue(key.wantsPriorityOverSystemBehavior)
        _ = target.perform(action, with: key)
        await fulfillment(of: [ran], timeout: 3)
        XCTAssertTrue(receivedSession === h.session)
        XCTAssertEqual(receivedParams, ["kind": "tools"])

        var replacement = palette
        replacement.id = "plugin.palette"
        replacement.docKinds = [.notebook]
        h.app.content.keyCommands.register(replacement)
        XCTAssertNil(keyboard.descriptor(for: key), "A stale key cannot bypass the current winner")
        XCTAssertEqual(keyboard.keyCommands?.filter {
            $0.input == "p" && $0.modifierFlags == [.control, .command]
        }.map { $0.propertyList as? String }, [replacement.id])
        h.session.document = Fixtures.textDocID
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true, "A closed canvas cannot route its palette key")
    }

    func testCanvasResponderRevalidatesRegistryAndTextFocus() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let keyboard = attachment.keyboard
        let oldDelete = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == UIKeyCommand.inputDelete })
        var replacement = descriptor("objectmenu.key.delete", "delete", scope: .canvas,
                                     kinds: [.notebook, .whiteboard], owner: "objectmenu", command: "item.delete")
        replacement.sessionParams = { [weak session = h.session] _ in
            ["refs": .array((session?.selection.refs ?? []).map(JSONValue.string))]
        }
        h.app.content.keyCommands.register(replacement)
        XCTAssertNil(keyboard.descriptor(for: oldDelete), "Cached keys cannot run an unregistered descriptor")
        let delete = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == UIKeyCommand.inputDelete })
        XCTAssertEqual(keyboard.descriptor(for: delete)?.id, replacement.id)
        let selectAll = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == "a" })
        h.session.isEditingText = true
        XCTAssertNil(keyboard.descriptor(for: delete))
        XCTAssertNil(keyboard.descriptor(for: selectAll), "Text editing keeps native Select All and Delete")
        h.session.isEditingText = false
        XCTAssertNotNil(keyboard.descriptor(for: delete))
        attachment.detach(from: host)
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true)
    }

    func testCanvasActionDiscoveryRoutesSelectAllAndGoToPage() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let root = KeyboardWindowController(session: h.session)
        root.view.addSubview(host.canvasView)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let keyboard = attachment.keyboard
        keyboard.restoreFocus()
        let focused = try XCTUnwrap(CanvasKeyboardFocus.firstResponder(in: window))
        XCTAssertTrue(focused === keyboard)

        // The Pages feature's dialog wins over F073's fallback, as it does in the app.
        var go = descriptor("pages.goToPage", "g", [.command, .option], scope: .document,
                            kinds: [.notebook, .whiteboard], owner: "pages", command: CommandIDs.panelOpen)
        go.params = ["id": "pages.goToPage"]
        h.app.content.keyCommands.register(go)
        let recorder = stand(in: h, for: [CommandIDs.selectionSelectAll, CommandIDs.panelOpen])
        let selectAll = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == "a" })
        let goToPage = try XCTUnwrap(keyboard.keyCommands?.first {
            $0.input == "g" && $0.modifierFlags == [.command, .alternate]
        })
        for (key, command) in [(selectAll, CommandIDs.selectionSelectAll), (goToPage, CommandIDs.panelOpen)] {
            let action = try XCTUnwrap(key.action)
            // Hardware keyboard discovery asks about the selector before providing a concrete key.
            XCTAssertTrue(focused.canPerformAction(action, withSender: nil))
            XCTAssertTrue(focused.canPerformAction(action, withSender: NSObject()))
            let target = try XCTUnwrap(focused.target(forAction: action, withSender: nil) as? UIResponder)
            XCTAssertTrue(target === keyboard)
            XCTAssertTrue(target.canPerformAction(action, withSender: key))
            XCTAssertTrue(key.wantsPriorityOverSystemBehavior)
            let ran = expectation(description: command)
            recorder.onCall = { if $0 == command { ran.fulfill() } }
            _ = target.perform(action, with: key)
            await fulfillment(of: [ran], timeout: 3)
            recorder.onCall = nil
        }
        XCTAssertEqual(recorder.params(CommandIDs.selectionSelectAll),
                       [["page": .string(NodeRef.page(doc, Fixtures.page1).description)]])
        XCTAssertEqual(recorder.params(CommandIDs.panelOpen), [["id": "pages.goToPage"]])
        XCTAssertTrue(h.app.ui.activeNavigator === root)
        XCTAssertTrue(h.app.services.sessions.active === h.session)

        let action = try XCTUnwrap(selectAll.action)
        // A settings/search field need not set session.isEditingText to keep native Select All.
        let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertFalse(h.session.isEditingText)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: selectAll))
        XCTAssertTrue(keyboard.canPerformAction(try XCTUnwrap(goToPage.action), withSender: goToPage),
                      "Go to Page stays enabled; the native Select All action belongs to the text field")
        field.resignFirstResponder()
        field.removeFromSuperview()

        // Accepting discovery must not make a fabricated/stale concrete command executable.
        let stale = UIKeyCommand(title: "Removed", action: action, input: "a",
                                 modifierFlags: .command, propertyList: "removed.shortcut")
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: stale))
        h.session.document = nil
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: NSObject()))
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: selectAll))
        h.session.document = doc
        attachment.detach(from: host)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
    }

    func testNativeSelectAllActionUsesCanvasWindowAndYieldsToTextAndModal() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let root = KeyboardWindowController(session: h.session)
        root.view.addSubview(host.canvasView)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let keyboard = attachment.keyboard
        keyboard.restoreFocus()

        let action = #selector(UIResponderStandardEditActions.selectAll(_:))
        let key = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == "a" })
        XCTAssertTrue(keyboard.canPerformAction(action, withSender: key))
        let focused = try XCTUnwrap(CanvasKeyboardFocus.firstResponder(in: window))
        XCTAssertTrue(focused.canPerformAction(action, withSender: nil))
        let target = try XCTUnwrap(focused.target(forAction: action, withSender: nil) as? UIResponder)
        XCTAssertTrue(target === keyboard)

        let other = EditorSession()
        other.document = Fixtures.textDocID
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        let recorder = stand(in: h, for: [CommandIDs.selectionSelectAll])
        let ran = expectation(description: "Native Select All reaches the invoking page")
        recorder.onCall = { _ in ran.fulfill() }
        _ = target.perform(action, with: nil)
        await fulfillment(of: [ran], timeout: 3)
        XCTAssertEqual(recorder.params(CommandIDs.selectionSelectAll),
                       [["page": .string(NodeRef.page(doc, Fixtures.page1).description)]])
        XCTAssertTrue(h.app.services.sessions.active === h.session)

        let nativeKey = UIKeyCommand(input: "a", modifierFlags: .command, action: action)
        XCTAssertTrue(keyboard.canPerformAction(action, withSender: nativeKey))
        let nativeRan = expectation(description: "System Command-A has no registry propertyList")
        recorder.onCall = { _ in nativeRan.fulfill() }
        _ = target.perform(action, with: nativeKey)
        await fulfillment(of: [nativeRan], timeout: 3)
        XCTAssertEqual(recorder.params(CommandIDs.selectionSelectAll).count, 2)
        let wrongKey = UIKeyCommand(input: "a", modifierFlags: .alternate, action: action)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: wrongKey))

        let text = UITextView(frame: CGRect(x: 20, y: 20, width: 200, height: 80))
        text.text = "Unicode café 日本語"
        root.view.addSubview(text)
        XCTAssertTrue(text.becomeFirstResponder())
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
        text.selectAll(nil)
        XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: (text.text as NSString).length))
        text.resignFirstResponder()
        text.removeFromSuperview()
        keyboard.restoreFocus()
        XCTAssertTrue(keyboard.canPerformAction(action, withSender: nil))
        root.modal = UIViewController()
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
        root.modal = nil
        h.session.isEditingText = true
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
        h.session.isEditingText = false
        attachment.detach(from: host)
        XCTAssertFalse(keyboard.canPerformAction(action, withSender: nil))
    }

    func testForwardedModifierEventsPersistUntilReleaseOrFocusChange() {
        var held = CanvasHeldModifiers()
        held.begin(.keyboardLeftGUI)
        held.begin(.keyboardRightAlt)
        held.begin(.keyboardZ)
        func chord(_ held: CanvasHeldModifiers) -> KeyShortcut {
            CanvasKeyPress.shortcut(code: .keyboardZ, characters: "z", keyFlags: [], eventFlags: [],
                                    heldKeys: Array(held.keys))
        }
        XCTAssertEqual(chord(held), KeyShortcut("z", [.command, .option]))
        XCTAssertEqual(held.keys.count, 2, "Printable keys must not become held modifiers")
        held.end(.keyboardRightAlt)
        XCTAssertEqual(chord(held), KeyShortcut("z", .command))
        held.end(.keyboardLeftGUI)
        XCTAssertEqual(chord(held), KeyShortcut("z"), "Release must restore an unmodified key")
        held.begin(.keyboardRightGUI)
        held = CanvasHeldModifiers()
        XCTAssertEqual(chord(held), KeyShortcut("z"), "A new focus session must not inherit modifiers")
    }

    func testCanvasHardwareInputSessionAndShiftedPlusRetainNavigationChords() {
        let responder = CanvasKeyboardResponder()
        XCTAssertFalse((responder as UIResponder) is UIKeyInput, "Navigation must not establish a text-input session")
        XCTAssertFalse(responder.hasText)
        XCTAssertNotNil(responder.inputView)
        XCTAssertEqual(responder.inputView?.bounds.height, 0)
        XCTAssertFalse(CanvasKeyboardFocus.isTextInput(responder), "Hardware command input is not editable text")
        responder.insertText("ignored")
        responder.deleteBackward()
        XCTAssertFalse(responder.hasText)
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardEqualSign, characters: "=", keyFlags: .command,
                                               eventFlags: .shift), KeyShortcut("+", .command))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardDownArrow, characters: "", keyFlags: [],
                                               eventFlags: [], heldKeys: [.keyboardLeftAlt]), KeyShortcut("down", .option))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardReturnOrEnter, characters: "\r", keyFlags: [],
                                               eventFlags: [], heldKeys: [.keyboardRightAlt]), KeyShortcut("return", .option))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardZ, characters: "z", keyFlags: [], eventFlags: [],
                                               heldKeys: [.keyboardLeftAlt, .keyboardLeftGUI]), KeyShortcut("z", [.command, .option]))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardEqualSign, characters: "=", keyFlags: [],
                                               eventFlags: []), KeyShortcut("="), "Never infer modifiers from the action a key could perform")
    }

    func testCanvasReclaimsSiblingHostingFocusForNavigationKeys() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let root = KeyboardWindowController(session: h.session)
        root.view.addSubview(host.canvasView)
        let sibling = TestChromeFocusView()
        root.view.addSubview(sibling)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        XCTAssertTrue(sibling.becomeFirstResponder())
        h.session.inking.begin()
        attachment.keyboard.restoreFocus()
        XCTAssertTrue(sibling.isFirstResponder, "Focus repair must not interrupt a live stroke")
        h.session.inking.end()
        attachment.keyboard.restoreFocus()
        XCTAssertTrue(attachment.keyboard.isFirstResponder)
        for (input, flags) in [("0", UIKeyModifierFlags([.command, .alternate])), ("=", .command)] {
            XCTAssertTrue(attachment.keyboard.keyCommands?.contains { $0.input == input && $0.modifierFlags == flags } == true)
        }
        let field = UITextField()
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        attachment.keyboard.restoreFocus()
        XCTAssertTrue(field.isFirstResponder)
    }

    func testCanvasFocusRecoveryAfterRemovalAndRotationPreservesTextFields() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let root = KeyboardWindowController(session: h.session)
        root.view.addSubview(host.canvasView)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        attachment.keyboard.restoreFocus()
        XCTAssertTrue(attachment.keyboard.isFirstResponder)

        // A panel's text field takes focus, then disappears from the hierarchy when the panel closes.
        let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        attachment.keyboard.restoreFocus()
        XCTAssertTrue(field.isFirstResponder, "Never steal focus from a search or rename field")
        XCTAssertFalse(CanvasKeyboardFocus.mayReplace(field, canvas: host.canvasView))
        field.resignFirstResponder()
        field.removeFromSuperview()
        attachment.keyboard.restoreFocus()
        XCTAssertTrue(attachment.keyboard.isFirstResponder)

        // UIKit can remove first-responder status during a size transition without reopening the document.
        attachment.keyboard.resignFirstResponder()
        host.canvasView.bounds.size = CGSize(width: 768, height: 1024)
        attachment.canvasDidChange(host)
        let recovered = expectation(description: "Focus repaired after canvas layout")
        DispatchQueue.main.async { recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertTrue(attachment.keyboard.isFirstResponder)
        let recorder = stand(in: h, for: ["view.zoom"])
        let other = EditorSession()
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(other)
        let key = try XCTUnwrap(attachment.keyboard.keyCommands?.first {
            $0.input == "0" && $0.modifierFlags == [.command, .alternate]
        })
        let ran = expectation(description: "Actual Size reaches the focused canvas after rotation")
        recorder.onCall = { _ in ran.fulfill() }
        // Package tests are hostless (ARCHITECTURE §15), with no UIApplication dispatcher. Start at the
        // window's actual first responder, let UIKit resolve the action target, and invoke that target.
        let action = try XCTUnwrap(key.action)
        let focused = try XCTUnwrap(CanvasKeyboardFocus.firstResponder(in: window))
        XCTAssertTrue(focused === attachment.keyboard)
        let target = try XCTUnwrap(focused.target(forAction: action, withSender: key) as? UIResponder)
        XCTAssertTrue(target === attachment.keyboard)
        XCTAssertTrue(target.responds(to: action))
        _ = target.perform(action, with: key)
        await fulfillment(of: [ran], timeout: 3)
        XCTAssertEqual(recorder.params("view.zoom"), [["actual": true]])
        XCTAssertTrue(h.app.ui.activeNavigator === root)
        XCTAssertTrue(h.app.services.sessions.active === h.session)
        XCTAssertEqual(attachment.keyboard.editingInteractionConfiguration, .none)
        // F073 requires hardware keys to reach the canvas. UIView's disabled
        // interaction state drops keys as well as touches; use hit testing instead.
        XCTAssertTrue(attachment.keyboard.isUserInteractionEnabled)
        attachment.keyboard.bounds.size = CGSize(width: 100, height: 100)
        XCTAssertNil(attachment.keyboard.hitTest(CGPoint(x: 50, y: 50), with: nil))
        XCTAssertTrue(attachment.keyboard.accessibilityElementsHidden)

        let button = UIButton()
        host.canvasView.addSubview(button)
        XCTAssertFalse(CanvasKeyboardFocus.mayReplace(button, canvas: host.canvasView))
        XCTAssertFalse(CanvasKeyboardFocus.mayReplace(UITextView(), canvas: host.canvasView))
        XCTAssertFalse(CanvasKeyboardFocus.mayReplace(UIView(), canvas: host.canvasView))
        XCTAssertTrue(CanvasKeyboardFocus.mayReplace(root, canvas: host.canvasView))
    }

    func testCanvasChromeRoutesPageSelectionZoomAndFeatureKeysToInvokingWindow() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let editor = FakeEditor(host)
        h.session.editor = editor
        let root = KeyboardWindowController(session: h.session)
        var context = ChromeContext(app: h.app, session: h.session, navigator: root, kind: .notebook)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(CanvasChromeShortcuts.overlayID))
        XCTAssertEqual(overlay.docKinds, [.notebook, .whiteboard])
        XCTAssertEqual(overlay.surface, .none)
        XCTAssertFalse(overlay.recedesWhileWriting)
        var go = descriptor("pages.goToPage", "g", [.option, .command], scope: .document,
                            kinds: [.notebook, .whiteboard], owner: "pages", command: CommandIDs.panelOpen)
        go.params = ["id": "pages.goToPage"]
        h.app.content.keyCommands.register(go)
        let zoomWindow = descriptor("zoomwindow.toggle", "z", [.option, .command], scope: .document,
                                    kinds: [.notebook], owner: "zoomwindow", command: "zoom.toggle")
        h.app.content.keyCommands.register(zoomWindow)
        let recorder = stand(in: h, for: [CommandIDs.selectionSelectAll, CommandIDs.viewZoom,
                                         CommandIDs.panelOpen, "zoom.toggle"])
        let other = EditorSession()
        h.app.services.sessions.add(other)
        for (id, command) in [("keyboard.actualSize", CommandIDs.viewZoom),
                              ("keyboard.zoomInEquals", CommandIDs.viewZoom),
                              ("keyboard.zoomIn", CommandIDs.viewZoom),
                              ("keyboard.zoomOut", CommandIDs.viewZoom),
                              ("keyboard.zoomToFit", CommandIDs.viewZoom),
                              (go.id, CommandIDs.panelOpen), (zoomWindow.id, "zoom.toggle")] {
            h.app.services.sessions.activate(other)
            h.app.ui.activeNavigator = nil
            let d = try XCTUnwrap(CanvasChromeShortcuts.descriptors(in: context).first { $0.id == id })
            let binding = CanvasChromeShortcuts.shortcut(d.shortcut)
            XCTAssertEqual(binding.key.character, d.shortcut.key.first)
            XCTAssertTrue(binding.modifiers.contains(.command))
            XCTAssertEqual(binding.modifiers.contains(.option), d.shortcut.modifiers.contains(.option))
            // Rotation can leave an arbitrary zoom. Resolve the live canvas, not a rendered snapshot.
            host.zoomScale = 1.6798817363
            let ran = expectation(description: id)
            recorder.onCall = { if $0 == command { ran.fulfill() } }
            CanvasChromeShortcuts.perform(id, in: context)
            await fulfillment(of: [ran], timeout: 3)
            XCTAssertTrue(h.app.services.sessions.active === h.session)
            XCTAssertTrue(h.app.ui.activeNavigator === root)
        }
        XCTAssertEqual(recorder.params(CommandIDs.viewZoom),
                       [["actual": true], ["scale": 2], ["scale": 2], ["scale": 1.5], ["fit": true]])
        XCTAssertEqual(recorder.params(CommandIDs.panelOpen), [["id": "pages.goToPage"]])
        XCTAssertEqual(recorder.params("zoom.toggle"), [[:]])

        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        context.kind = .whiteboard
        XCTAssertFalse(CanvasChromeShortcuts.descriptors(in: context).contains { $0.id == zoomWindow.id })
        let selected = expectation(description: "Select All resolves the current board after framework insertion")
        recorder.onCall = { if $0 == CommandIDs.selectionSelectAll { selected.fulfill() } }
        CanvasChromeShortcuts.perform("keyboard.selectAll", in: context)
        await fulfillment(of: [selected], timeout: 3)
        XCTAssertEqual(recorder.params(CommandIDs.selectionSelectAll),
                       [["page": .string(NodeRef.page(Fixtures.whiteboardID, Fixtures.boardID).description)]])
        XCTAssertTrue(ShortcutRules.conflicts(in: h.app.content.keyCommands.all).isEmpty)
        withExtendedLifetime(editor) {}
    }

    func testHostedCanvasChromeInstallsNativeTargetAndRoutesFrameworkSelectionAndNavigation() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let editor = FakeEditor(host)
        h.session.editor = editor
        let root = KeyboardWindowController(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: root, kind: .notebook)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(CanvasChromeShortcuts.overlayID))
        let chrome = UIHostingController(rootView: overlay.makeView(context))
        root.addChild(chrome)
        root.view.addSubview(chrome.view)
        chrome.view.frame = root.view.bounds
        chrome.didMove(toParent: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        chrome.view.layoutIfNeeded()
        func nativeResponder(in view: UIView) -> CanvasChromeKeyboardResponder? {
            if let responder = view as? CanvasChromeKeyboardResponder { return responder }
            return view.subviews.lazy.compactMap { nativeResponder(in: $0) }.first
        }
        let keyboard = try XCTUnwrap(nativeResponder(in: chrome.view),
                                    "The real overlay must install a native responder, not hidden SwiftUI buttons")
        keyboard.restoreFocus()
        XCTAssertTrue(keyboard.isFirstResponder)
        XCTAssertTrue(keyboard.isUserInteractionEnabled)
        keyboard.bounds.size = CGSize(width: 100, height: 100)
        XCTAssertNil(keyboard.hitTest(CGPoint(x: 50, y: 50), with: nil))
        XCTAssertEqual(keyboard.editingInteractionConfiguration, .none)

        var go = descriptor("pages.goToPage", "g", [.command, .option], scope: .document,
                            kinds: [.notebook, .whiteboard], owner: "pages", command: "panel.open")
        go.params = ["id": "pages.goToPage"]
        h.app.content.keyCommands.register(go)
        let recorder = stand(in: h, for: ["selection.selectAll", "item.delete", "view.zoom", "panel.open", "view.scrollBy"])
        let other = EditorSession()
        h.app.services.sessions.add(other)

        func send(_ input: String, _ flags: UIKeyModifierFlags, command id: String) async throws {
            h.app.services.sessions.activate(other)
            let key = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == input && $0.modifierFlags == flags })
            let action = try XCTUnwrap(key.action)
            let focused = try XCTUnwrap(CanvasKeyboardFocus.firstResponder(in: window))
            let target = try XCTUnwrap(focused.target(forAction: action, withSender: nil) as? UIResponder)
            XCTAssertTrue(target === keyboard)
            XCTAssertTrue(target.canPerformAction(action, withSender: key))
            let ran = expectation(description: id)
            recorder.onCall = { if $0 == id { ran.fulfill() } }
            _ = target.perform(action, with: key)
            await fulfillment(of: [ran], timeout: 3)
            recorder.onCall = nil
            XCTAssertTrue(h.app.services.sessions.active === h.session)
            XCTAssertTrue(h.app.ui.activeNavigator === root)
        }

        try await send("0", [.command, .alternate], command: "view.zoom")
        XCTAssertEqual(recorder.params("view.zoom").last, ["actual": true])
        // Try Again and rotation can retain non-ladder zooms. Read them at key delivery.
        for (zoom, target) in [(1.2767101196, 1.5), (1.6798817363, 2.0)] {
            host.zoomScale = zoom
            try await send("=", .command, command: "view.zoom")
            XCTAssertEqual(recorder.params("view.zoom").last, ["scale": .number(target)])
        }
        try await send("g", [.command, .alternate], command: "panel.open")
        XCTAssertEqual(recorder.params("panel.open").last, go.params)

        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        keyboard.context?.kind = .whiteboard
        try await send("a", .command, command: "selection.selectAll")
        XCTAssertEqual(recorder.params("selection.selectAll").last,
                       ["page": .string(NodeRef.page(Fixtures.whiteboardID, Fixtures.boardID).description)])
        let items = (0..<19).map { NibID("framework-\($0)") }
        h.session.selection = Selection(doc: Fixtures.whiteboardID, page: Fixtures.boardID, items: items)
        try await send(UIKeyCommand.inputDelete, [], command: "item.delete")
        XCTAssertEqual(Set(recorder.params("item.delete").last?["refs"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                       Set(items.map { NodeRef.item(Fixtures.whiteboardID, Fixtures.boardID, $0).description }))

        for (name, input, dx, dy) in [("up", UIKeyCommand.inputUpArrow, 0.0, -0.9),
                                      ("down", UIKeyCommand.inputDownArrow, 0.0, 0.9),
                                      ("left", UIKeyCommand.inputLeftArrow, -0.9, 0.0),
                                      ("right", UIKeyCommand.inputRightArrow, 0.9, 0.0)] {
            var pan = descriptor("canvas.pan." + name, name, .option, scope: .canvas,
                                 kinds: [.notebook, .whiteboard], owner: "canvas", command: "view.scrollBy")
            pan.params = ["dx": .number(dx), "dy": .number(dy), "unit": "window"]
            h.app.content.keyCommands.register(pan)
            try await send(input, .alternate, command: "view.scrollBy")
            XCTAssertEqual(recorder.params("view.scrollBy").last, pan.params)
        }
        withExtendedLifetime(editor) {}
    }

    func testNativeChromeRecoversSiblingFocusAndRejectsTextModalStaleAndInactiveRoutes() async throws {
        let h = await started()
        let root = KeyboardWindowController(session: h.session)
        let keyboard = CanvasChromeKeyboardResponder(context: ChromeContext(app: h.app, session: h.session,
                                                                            navigator: root, kind: .notebook))
        root.view.addSubview(keyboard)
        let siblingFocus = TestChromeFocusView()
        let sibling = UIHostingController(rootView: TestChromeFocusContent(view: siblingFocus))
        root.addChild(sibling)
        root.view.addSubview(sibling.view)
        sibling.view.frame = root.view.bounds
        sibling.didMove(toParent: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sibling.view.layoutIfNeeded()
        keyboard.restoreFocus()
        XCTAssertTrue(keyboard.isFirstResponder)
        // The old canvas attachment's policy excludes siblings. Chrome's root-scoped
        // recovery must admit them after a toolbar interaction or layout transition.
        XCTAssertTrue(CanvasKeyboardFocus.mayReplace(sibling, canvas: root.view))
        XCTAssertFalse(CanvasKeyboardFocus.mayReplace(sibling, canvas: keyboard))
        XCTAssertTrue(siblingFocus.becomeFirstResponder())
        XCTAssertFalse(keyboard.isFirstResponder)
        keyboard.restoreFocus()
        XCTAssertTrue(keyboard.isFirstResponder, "Recover non-text focus from the sibling hosting subtree")
        let old = try XCTUnwrap(keyboard.keyCommands?.first { $0.input == "0" && $0.modifierFlags == [.command, .alternate] })
        var replacement = try key(h, "actualSize")
        replacement.id = "plugin.actualSize"
        replacement.docKinds = [.notebook]
        h.app.content.keyCommands.register(replacement)
        XCTAssertFalse(keyboard.canPerformAction(try XCTUnwrap(old.action), withSender: old))

        let selectAll = #selector(UIResponderStandardEditActions.selectAll(_:))
        XCTAssertTrue(keyboard.canPerformAction(selectAll, withSender: nil))
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        keyboard.restoreFocus()
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertFalse(keyboard.canPerformAction(selectAll, withSender: nil))
        XCTAssertFalse(keyboard.performUnhandledPress(KeyShortcut("delete")))
        XCTAssertFalse(keyboard.performUnhandledPress(KeyShortcut("a", .command)))
        field.resignFirstResponder()
        field.removeFromSuperview()
        root.modal = UIViewController()
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true)
        XCTAssertFalse(keyboard.performUnhandledPress(KeyShortcut("0", [.option, .command])))
        root.modal = nil
        keyboard.scheduleFocus()
        let recovered = expectation(description: "Focus returns after panel dismissal/layout")
        DispatchQueue.main.async { recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertTrue(keyboard.isFirstResponder)
        let otherWindow = UIWindow(frame: window.bounds)
        otherWindow.rootViewController = UIViewController()
        otherWindow.makeKeyAndVisible()
        defer { otherWindow.isHidden = true }
        XCTAssertTrue(keyboard.keyCommands?.isEmpty == true)
        XCTAssertFalse(keyboard.performUnhandledPress(KeyShortcut("=", .command)))
        keyboard.context = nil
        XCTAssertFalse(keyboard.canPerformAction(selectAll, withSender: nil))
    }

    func testUnhandledCanvasPressPreservesEventChordAndDispatchesOnceBeforeHostingBoundary() async throws {
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboard0, characters: "0", keyFlags: [],
                                               eventFlags: [.command, .alternate]), KeyShortcut("0", [.command, .option]))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardG, characters: "G", keyFlags: .alternate,
                                               eventFlags: .command), KeyShortcut("g", [.command, .option]))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardDownArrow, characters: "", keyFlags: [],
                                               eventFlags: .alternate), KeyShortcut("down", .option))
        XCTAssertEqual(CanvasKeyPress.shortcut(code: .keyboardDeleteOrBackspace, characters: "\u{8}",
                                               keyFlags: [], eventFlags: []), KeyShortcut("delete"))
        let h = await started()
        let host = FakeCanvasHost(h)
        let root = KeyboardWindowController(session: h.session)
        root.view.addSubview(host.canvasView)
        let window = UIWindow(frame: host.canvasView.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let chrome = CanvasChromeKeyboardResponder(context: ChromeContext(app: h.app, session: h.session,
                                                                          navigator: root, kind: .notebook))
        root.view.addSubview(chrome)
        let recorder = stand(in: h, for: ["view.zoom"])
        for send in [attachment.keyboard.performUnhandledPress, chrome.performUnhandledPress] {
            let count = recorder.calls.count
            let ran = expectation(description: "Unhandled press dispatched")
            recorder.onCall = { _ in ran.fulfill() }
            XCTAssertTrue(send(KeyShortcut("0", [.command, .option])))
            await fulfillment(of: [ran], timeout: 3)
            XCTAssertEqual(recorder.calls.count, count + 1)
            XCTAssertEqual(recorder.params("view.zoom").last, ["actual": true])
            XCTAssertFalse(send(KeyShortcut("0")), "Do not mistake the chord for a colour key")
            root.modal = UIViewController()
            XCTAssertFalse(send(KeyShortcut("0", [.command, .option])))
            root.modal = nil
        }
    }

    func testCanvasChromeYieldsToTextModalAndRegistryChanges() async throws {
        let h = await started()
        let root = KeyboardWindowController(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: root, kind: .notebook)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertFalse(h.session.isEditingText, "Native dialog fields do not set the editor's text flag")
        XCTAssertFalse(CanvasChromeShortcuts.descriptors(in: context).contains { $0.id == "keyboard.selectAll" })
        h.app.ui.activeNavigator = nil
        CanvasChromeShortcuts.perform("keyboard.selectAll", in: context)
        XCTAssertNil(h.app.ui.activeNavigator)
        field.resignFirstResponder()
        field.removeFromSuperview()
        XCTAssertTrue(CanvasChromeShortcuts.descriptors(in: context).contains { $0.id == "keyboard.selectAll" })
        h.session.isEditingText = true
        XCTAssertFalse(CanvasChromeShortcuts.descriptors(in: context).contains { $0.id == "keyboard.selectAll" })
        h.session.isEditingText = false
        root.modal = UIViewController()
        CanvasChromeShortcuts.perform("keyboard.actualSize", in: context)
        XCTAssertNil(h.app.ui.activeNavigator, "A shortcut cannot run behind a modal")
        root.modal = nil
        var replacement = try key(h, "actualSize")
        replacement.id = "plugin.actualSize"
        replacement.docKinds = [.notebook]
        h.app.content.keyCommands.register(replacement)
        CanvasChromeShortcuts.perform("keyboard.actualSize", in: context)
        XCTAssertNil(h.app.ui.activeNavigator, "A stale rendered binding cannot bypass the new winner")
        XCTAssertEqual(CanvasChromeShortcuts.descriptors(in: context).filter {
            $0.shortcut == replacement.shortcut
        }.map(\.id), [replacement.id])
        h.session.document = nil
        XCTAssertTrue(CanvasChromeShortcuts.descriptors(in: context).isEmpty)
        h.session.document = Fixtures.textDocID
        XCTAssertTrue(CanvasChromeShortcuts.descriptors(in: context).isEmpty, "A stale canvas host must stop routing")
    }

    func testChromeKeyboardFallsBackToWindowUndoAndRedoWhenDocumentHistoryIsEmpty() async throws {
        let h = await started()
        let root = KeyboardWindowController(session: h.session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let manager = try XCTUnwrap(window.undoManager)
        manager.groupsByEvent = false
        let context = ChromeContext(app: h.app, session: h.session, navigator: root, kind: .notebook)
        h.app.content.keyCommands.register(descriptor("chrome.undo", "z", .command,
            scope: .global, owner: "chrome.tests", command: CommandIDs.undo))
        h.app.content.keyCommands.register(descriptor("chrome.redo", "z", [.command, .shift],
            scope: .global, owner: "chrome.tests", command: CommandIDs.redo))
        final class Position: NSObject {
            var value = 0
            func move(_ next: Int, manager: UndoManager) {
                let old = value
                manager.registerUndo(withTarget: self) { $0.move(old, manager: manager) }
                value = next
            }
        }
        let position = Position()
        manager.beginUndoGrouping()
        position.move(1, manager: manager)
        manager.endUndoGrouping()
        XCTAssertFalse(h.app.bus.history.canUndo(Fixtures.docID))
        CanvasChromeShortcuts.perform("chrome.undo", in: context)
        XCTAssertEqual(position.value, 0)
        XCTAssertTrue(manager.canRedo)
        CanvasChromeShortcuts.perform("chrome.redo", in: context)
        XCTAssertEqual(position.value, 1)
        XCTAssertTrue(manager.canUndo)

        _ = try await h.insert([Item.makeSticky(StickyItem(frame: Frame(x: 1, y: 1, w: 50, h: 50)))])
        CanvasChromeShortcuts.perform("chrome.undo", in: context)
        for _ in 0..<100 where h.app.bus.history.canUndo(Fixtures.docID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(h.app.bus.history.canUndo(Fixtures.docID))
        XCTAssertEqual(position.value, 1, "Document edits take priority over window docking history")
        CanvasChromeShortcuts.perform("chrome.redo", in: context)
        for _ in 0..<100 where h.app.bus.history.canRedo(Fixtures.docID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(h.app.bus.history.canRedo(Fixtures.docID))
        XCTAssertEqual(position.value, 1)
    }

    func testNamedCanvasKeysMatchUIKitAndSwiftUIAndPanInAllDirections() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let root = KeyboardWindowController(session: h.session)
        let context = ChromeContext(app: h.app, session: h.session, navigator: root, kind: .notebook)
        let recorder = stand(in: h, for: [CommandIDs.viewScrollBy])
        let keys: [(String, String, KeyEquivalent, Double, Double)] = [
            ("up", UIKeyCommand.inputUpArrow, .upArrow, 0, -0.9),
            ("down", UIKeyCommand.inputDownArrow, .downArrow, 0, 0.9),
            ("left", UIKeyCommand.inputLeftArrow, .leftArrow, -0.9, 0),
            ("right", UIKeyCommand.inputRightArrow, .rightArrow, 0.9, 0)
        ]
        for (name, input, equivalent, dx, dy) in keys {
            var pan = descriptor("canvas.pan." + name, name, .option, scope: .canvas,
                                 kinds: [.notebook, .whiteboard], owner: "canvas", command: CommandIDs.viewScrollBy)
            pan.params = ["dx": .number(dx), "dy": .number(dy), "unit": "window"]
            h.app.content.keyCommands.register(pan)
            let key = try XCTUnwrap(attachment.keyboard.keyCommands?.first { $0.propertyList as? String == pan.id })
            XCTAssertEqual(key.input, input)
            XCTAssertEqual(key.modifierFlags, .alternate)
            let binding = CanvasChromeShortcuts.shortcut(pan.shortcut)
            XCTAssertEqual(binding.key, equivalent)
            XCTAssertEqual(binding.modifiers, .option)
            for swiftUI in [false, true] {
                let ran = expectation(description: name)
                recorder.onCall = { _ in ran.fulfill() }
                if swiftUI {
                    CanvasChromeShortcuts.perform(pan.id, in: context)
                } else {
                    _ = attachment.keyboard.perform(try XCTUnwrap(key.action), with: key)
                }
                await fulfillment(of: [ran], timeout: 3)
                XCTAssertEqual(recorder.params(CommandIDs.viewScrollBy).last, pan.params)
            }
        }
        for (name, equivalent) in [("return", KeyEquivalent.return), ("delete", .delete), ("escape", .escape),
                                   ("tab", .tab), ("space", .space)] {
            XCTAssertEqual(CanvasChromeShortcuts.shortcut(KeyShortcut(name, .option)).key, equivalent)
        }
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
        XCTAssertEqual(ShortcutActions.newNotebookFolder(ShortcutContext()), [:], "from the library: the root")
        XCTAssertEqual(ShortcutActions.newNotebookFolder(ShortcutContext(doc: doc, folder: Fixtures.folderID)),
                       ["folder": .string(NodeRef.folder(Fixtures.folderID).description)])
        let id = NibID("NEWTEXTDOC01")
        XCTAssertEqual(ShortcutActions.newTextDocument(id: id),
                       ["calls": [["command": "doc.create", "params": ["kind": "textDocument", "id": "NEWTEXTDOC01"]],
                                  ["command": "doc.open", "params": ["doc": "doc:NEWTEXTDOC01"]]]])
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

    func testScrollZoomKeepsThePointerAnchorToTheLastStep() async throws {
        let h = await started()
        let host = FakeCanvasHost(h)
        let recorder = Recorder()
        h.app.commands.register(CommandDescriptor(id: "view.zoom", title: "Zoom", summary: "Test stand-in.",
                                                  effect: .session, target: .app, exposure: .ui)) { json, _ in
            recorder.calls.append(("view.zoom", json))
            host.zoomScale = json["scale"]?.doubleValue ?? host.zoomScale
            return .null
        }
        h.app.commands.register(CommandDescriptor(id: "view.scrollBy", title: "Scroll", summary: "Test stand-in.",
                                                  effect: .session, target: .app, exposure: .ui)) { json, _ in
            recorder.calls.append(("view.scrollBy", json))
            return .null
        }
        let attachment = PointerCanvasAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }

        // Several scroll steps arrive while the first zoom runs; the gesture ends before the last one is applied.
        attachment.zoomBegan(at: CGPoint(x: 200, y: 300))
        attachment.zoomChanged(scroll: 40)
        attachment.zoomChanged(scroll: 80)
        attachment.zoomChanged(scroll: ScrollZoom.pointsPerDoubling)
        attachment.zoomEnded()
        for _ in 0..<500 where !attachment.isZoomIdle {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(attachment.isZoomIdle)

        let calls = recorder.calls
        let zooms = calls.filter { $0.command == "view.zoom" }.compactMap { $0.params["scale"]?.doubleValue }
        XCTAssertEqual(zooms.count, 2, "the first step, then only the latest one")
        XCTAssertEqual(zooms.last ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(calls.last?.command, "view.scrollBy", "the last zoom still brings the page back under the pointer")
        XCTAssertEqual(calls.map { $0.command }, ["view.zoom", "view.scrollBy", "view.zoom", "view.scrollBy"])
        // At 2× the page point that was under (200, 300) sits at (400, 600): pan it back by (100, 150) page points.
        XCTAssertEqual(calls.last?.params["dx"]?.doubleValue ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(calls.last?.params["dy"]?.doubleValue ?? 0, 150, accuracy: 1e-9)
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

        // Text inputs keep their I-beam; the canvas's own views are never walked.
        let field = TestField(frame: CGRect(x: 0, y: 200, width: 200, height: 44))
        let canvas = UIView(frame: CGRect(x: 0, y: 250, width: 600, height: 150))
        let pageControl = TestControl(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        canvas.addSubview(pageControl)
        root.addSubview(field)
        root.addSubview(canvas)
        HoverEffects.excludeSubtree(canvas)
        XCTAssertEqual(HoverEffects.install(in: root), 0)
        XCTAssertFalse(HoverEffects.hasPointerInteraction(field))
        XCTAssertFalse(HoverEffects.hasPointerInteraction(pageControl))
        HoverEffects.includeSubtree(canvas)
        XCTAssertEqual(HoverEffects.install(in: root), 1)
        XCTAssertTrue(HoverEffects.hasPointerInteraction(pageControl))

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
        XCTAssertEqual(sections.map { $0.group }, [.scope(.global), .scope(.library), .scope(.document), .scope(.canvas),
                                                   .textEditing])
        XCTAssertFalse(sections.flatMap { $0.entries }.contains { $0.id == "keyboard.zoomInEquals" })
        XCTAssertEqual(sections.first { $0.scope == .canvas }?.entries.first { $0.id == "toolbar.key.p" }?.isOff, true)
        let everywhere = try XCTUnwrap(sections.first?.entries.map { $0.title })
        XCTAssertEqual(everywhere, everywhere.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        // P-055: the text views' own formatting keys are listed, never registered.
        let editing = try XCTUnwrap(sections.last)
        XCTAssertEqual(ShortcutDirectory.title(editing.group), "While Editing Text")
        let formatting = Dictionary(uniqueKeysWithValues: editing.entries.map { ($0.title, $0.keys) })
        XCTAssertEqual(formatting["Bold"], "⌘B")
        XCTAssertEqual(formatting["Italic"], "⌘I")
        XCTAssertEqual(formatting["Underline"], "⌘U")
        XCTAssertEqual(formatting["Strikethrough"], "⇧⌘X")
        XCTAssertTrue(editing.entries.allSatisfy { $0.status == .active })
        for k in ShortcutDirectory.textEditingKeys {
            XCTAssertNil(h.app.content.keyCommands.get(k.id), "\(k.title) belongs to the text view")
            XCTAssertFalse(h.app.content.keyCommands.all.contains { $0.shortcut == k.shortcut && $0.scope == .global },
                           "\(k.title): no key everywhere takes it from the text view")
        }
        let bold = ShortcutDirectory.sections(active: h.app.content.keyCommands.all, query: "bold")
        XCTAssertEqual(bold.map { $0.group }, [.textEditing])

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
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == FeatKeyboardFeature.id }.isEmpty,
                      "the feature maps other features' commands and owns none")
        let problems = await CommandConformance.check(features: [FeatKeyboardFeature.self])
        XCTAssertEqual(problems, [])
    }
}
