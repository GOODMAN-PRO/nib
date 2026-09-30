import XCTest
import NibContracts
import NibTesting

/// contracts-v2.2: the app shell's key-command routing (`KeyCommandDescriptor.isActive(in:)`, `KeyCommandRouting`)
/// and its ⌘Z / ⇧⌘Z fallback to the window's UndoManager (`UndoRoute`).
@MainActor
final class ShellRoutingTests: XCTestCase {
    private let library = KeyCommandContext(docKind: nil)
    private let notebook = KeyCommandContext(docKind: .notebook)
    private let textDocument = KeyCommandContext(docKind: .textDocument)
    private let editingNotebookText = KeyCommandContext(docKind: .notebook, isEditingText: true)

    private func key(_ id: String, _ shortcut: KeyShortcut = KeyShortcut("k", [.command]), scope: KeyScope,
                     order: Int = 0, docKinds: Set<DocumentKind>? = nil) -> KeyCommandDescriptor {
        var d = KeyCommandDescriptor(id: id, title: id, shortcut: shortcut, command: "test." + id, scope: scope,
                                     order: order, owner: "test")
        d.docKinds = docKinds
        return d
    }

    // MARK: Scope and document kinds

    func testScopeAdmitsTheWindow() {
        let global = key("g", scope: .global), lib = key("l", scope: .library)
        let document = key("d", scope: .document), canvas = key("c", scope: .canvas)
        XCTAssertEqual([global, lib, document, canvas].map { $0.isActive(in: library) }, [true, true, false, false])
        XCTAssertEqual([global, lib, document, canvas].map { $0.isActive(in: notebook) }, [true, false, true, true])
        XCTAssertEqual([global, lib, document, canvas].map { $0.isActive(in: editingNotebookText) },
                       [true, false, true, false], "canvas keys stand back while text is edited")
        let unknownKind = KeyCommandContext(inDocument: true, docKind: nil)
        XCTAssertTrue(document.isActive(in: unknownKind))
    }

    func testDocKindsLimitAKeyToTheShownDocument() {
        let textOnly = key("t", scope: .canvas, docKinds: [.textDocument])
        XCTAssertTrue(textOnly.isActive(in: textDocument))
        XCTAssertFalse(textOnly.isActive(in: notebook))
        XCTAssertFalse(textOnly.isActive(in: library))

        let globalStudy = key("s", scope: .global, docKinds: [.studySet])
        XCTAssertTrue(globalStudy.isActive(in: KeyCommandContext(docKind: .studySet)))
        XCTAssertFalse(globalStudy.isActive(in: library), "a key limited to kinds is never live without a document")
        XCTAssertFalse(globalStudy.isActive(in: KeyCommandContext(inDocument: true, docKind: nil)))

        XCTAssertTrue(key("n", scope: .document, docKinds: nil).isActive(in: textDocument), "nil = any kind")
        XCTAssertTrue(key("e", scope: .document, docKinds: []).isActive(in: textDocument), "empty = any kind")
    }

    // MARK: One command per shortcut

    func testTheMostSpecificCommandWinsASharedShortcut() {
        let cmdD = KeyShortcut("d", [.command])
        // F014's item.duplicate (any kind) and F102's block duplicate (text documents only), both .canvas.
        let duplicateItem = key("clipboard.key.duplicate", cmdD, scope: .canvas, order: 304)
        let duplicateBlock = key("textdocedit.key.duplicate", cmdD, scope: .canvas, order: 621, docKinds: [.textDocument])
        let all = [duplicateItem, duplicateBlock]
        XCTAssertEqual(KeyCommandRouting.active(all, in: textDocument).map(\.id), ["textdocedit.key.duplicate"])
        XCTAssertEqual(KeyCommandRouting.active(all, in: notebook).map(\.id), ["clipboard.key.duplicate"])
        XCTAssertEqual(KeyCommandRouting.active(all, in: library).map(\.id), [])

        // A global ⌘K and a document ⌘K: the document one inside a document, the global one in the library.
        let bar = key("commandbar", scope: .global), link = key("link.add", scope: .document, order: 900)
        XCTAssertEqual(KeyCommandRouting.active([bar, link], in: notebook).map(\.id), ["link.add"])
        XCTAssertEqual(KeyCommandRouting.active([bar, link], in: library).map(\.id), ["commandbar"])
    }

    func testOrderThenIdBreakTiesAndRegistryOrderIsKept() {
        let a = key("a", scope: .document, order: 5), b = key("b", scope: .document, order: 1)
        let c = key("c", scope: .document, order: 1)
        XCTAssertTrue(KeyCommandRouting.precedes(b, a))
        XCTAssertTrue(KeyCommandRouting.precedes(b, c))
        XCTAssertFalse(KeyCommandRouting.precedes(c, b))
        XCTAssertEqual(KeyCommandRouting.active([a, c, b], in: notebook).map(\.id), ["b"])

        let other = key("z", KeyShortcut("z", [.command]), scope: .canvas, order: 9)
        let shiftZ = key("y", KeyShortcut("z", [.command, .shift]), scope: .canvas, order: 1)
        XCTAssertEqual(KeyCommandRouting.active([other, a, shiftZ], in: notebook).map(\.id), ["z", "a", "y"],
                       "different modifiers are different shortcuts; winners keep the registry order")
        XCTAssertEqual(KeyCommandRouting.active([other, a, shiftZ], in: editingNotebookText).map(\.id), ["a"])
    }

    func testPlainKeysLeaveTypingAloneWhileTextHasTheKeyboard() {
        let pen = key("pen", KeyShortcut("p"), scope: .canvas)
        let nudge = key("nudge", KeyShortcut("up", [.shift]), scope: .document)
        let bold = key("bold", KeyShortcut("b", [.command]), scope: .document)
        let option = key("option", KeyShortcut("l", [.option]), scope: .global)
        let control = key("control", KeyShortcut("tab", [.control]), scope: .global)
        let keys = [pen, nudge, bold, option, control]
        XCTAssertEqual(keys.map { KeyCommandRouting.overridesSystemKeys($0, in: notebook) }, [true, true, true, true, true])
        XCTAssertEqual(keys.map { KeyCommandRouting.overridesSystemKeys($0, in: library) }, [true, true, true, true, true])
        let typing = KeyCommandContext(docKind: .textDocument, isEditingText: true)
        XCTAssertEqual(keys.map { KeyCommandRouting.overridesSystemKeys($0, in: typing) }, [false, false, true, true, true],
                       "letters and arrows (with or without shift) go to the text; modified keys still run commands")
        XCTAssertEqual(KeyCommandRouting.active(keys, in: typing).map(\.id), ["nudge", "bold", "option", "control"],
                       "the canvas key is not live at all while typing")
    }

    func testTheLibraryContext() {
        XCTAssertEqual(KeyCommandContext(docKind: nil), KeyCommandContext(inDocument: false, docKind: nil))
        XCTAssertEqual(KeyCommandContext(docKind: .whiteboard, isEditingText: true),
                       KeyCommandContext(inDocument: true, docKind: .whiteboard, isEditingText: true))
        XCTAssertNotEqual(notebook, editingNotebookText)
    }

    func testSessionParamsMergeOverStaticParamsWhenTheKeyRuns() {
        let h = Harness()
        var d = KeyCommandDescriptor(id: "k", title: "K", shortcut: KeyShortcut("b", [.command]), command: CommandIDs.batch,
                                     params: ["calls": [], "label": "Bold"], owner: "test")
        d.sessionParams = { session in ["calls": [["command": "x.y", "params": ["doc": .string(session.document?.raw ?? "")]]]] }
        XCTAssertEqual(d.resolvedParams(for: h.session),
                       ["calls": [["command": "x.y", "params": ["doc": "FIXTUREDOC01"]]], "label": "Bold"])
        XCTAssertEqual(d.resolvedParams(for: nil), ["calls": [], "label": "Bold"])
    }

    // MARK: ⌘Z / ⇧⌘Z fallback

    func testUndoPrefersTheDocumentThenTheWindowsUndoManager() async throws {
        let h = Harness()
        let history = h.app.bus.history
        let window = UndoManager()
        window.groupsByEvent = false
        let palette = DockStandIn()

        XCTAssertEqual(UndoRoute.resolve(redo: false, doc: nil, history: history, window: nil), .nothing)
        XCTAssertEqual(UndoRoute.resolve(redo: false, doc: Fixtures.docID, history: history, window: window), .nothing)

        palette.move(to: 2, undoManager: window)   // "Move Palette"
        XCTAssertEqual(UndoRoute.resolve(redo: false, doc: nil, history: history, window: window), .window,
                       "no document: the window's step")
        XCTAssertEqual(UndoRoute.resolve(redo: false, doc: Fixtures.docID, history: history, window: window), .window,
                       "the document's history is empty: the window's step")

        _ = try await h.insert([Item.makeSticky(StickyItem(frame: Frame(x: 1, y: 1, w: 50, h: 50)))])
        XCTAssertEqual(UndoRoute.resolve(redo: false, doc: Fixtures.docID, history: history, window: window),
                       .document(Fixtures.docID), "the document's step comes first")
        XCTAssertEqual(UndoRoute.resolve(redo: true, doc: Fixtures.docID, history: history, window: window), .nothing)

        window.undo()
        XCTAssertEqual(palette.dock, 0)
        XCTAssertEqual(UndoRoute.resolve(redo: true, doc: Fixtures.docID, history: history, window: window), .window,
                       "nothing to redo in the document: the window's redo")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(UndoRoute.resolve(redo: true, doc: Fixtures.docID, history: history, window: window),
                       .document(Fixtures.docID))
        XCTAssertEqual(UndoRoute.resolve(redo: false, doc: Fixtures.docID, history: history, window: window), .nothing)
    }

    func testUndoRouteForAKeyCommand() async throws {
        let h = Harness()
        let history = h.app.bus.history
        _ = try await h.insert([Item.makeSticky(StickyItem(frame: Frame(x: 1, y: 1, w: 50, h: 50)))])
        let window = UndoManager()

        XCTAssertNil(UndoRoute.forCommand(CommandIDs.batch, params: [:], session: h.session, history: history, window: window))
        XCTAssertEqual(UndoRoute.forCommand(CommandIDs.undo, params: [:], session: h.session, history: history, window: window),
                       .document(Fixtures.docID), "no doc param: the session's document")
        XCTAssertEqual(UndoRoute.forCommand(CommandIDs.undo, params: ["doc": ""], session: h.session, history: history,
                                            window: window), .document(Fixtures.docID))
        XCTAssertEqual(UndoRoute.forCommand(CommandIDs.undo, params: ["doc": "doc:FIXTUREDOC02"], session: h.session,
                                            history: history, window: window), .nothing,
                       "the named document has no step and the window none")
        XCTAssertEqual(UndoRoute.forCommand(CommandIDs.redo, params: [:], session: h.session, history: history, window: window),
                       .nothing)
        h.session.document = nil
        XCTAssertEqual(UndoRoute.forCommand(CommandIDs.undo, params: [:], session: h.session, history: history, window: window),
                       .nothing, "no document and an empty window")
        XCTAssertEqual(UndoRoute.forCommand(CommandIDs.undo, params: ["doc": "doc:FIXTUREDOC01"], session: nil,
                                            history: history, window: window), .document(Fixtures.docID))
    }
}

/// A window-level undoable setting, registered the way F016 registers "Move Palette" on the window's UndoManager.
private final class DockStandIn: NSObject {
    private(set) var dock = 0

    func move(to next: Int, undoManager: UndoManager) {
        let previous = dock
        dock = next
        // An undo or redo already runs inside the manager's own group (which records the inverse step).
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in target.move(to: previous, undoManager: undoManager) }
        undoManager.setActionName("Move Palette")
        if grouped { undoManager.endUndoGrouping() }
    }
}
