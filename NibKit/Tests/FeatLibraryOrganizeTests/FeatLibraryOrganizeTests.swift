import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatLibraryOrganize

/// Stand-in for page.setBookmarked (F046): bookmarks one page through a real transaction, so the page index sees a
/// commit and an undo like it would in the app.
private struct BookmarkStandIn: NibCommand {
    struct Params: Codable { var page: String }
    static let descriptor = CommandDescriptor(id: "test.bookmark", title: "Bookmark", summary: "Test stand-in.",
                                              effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .page(doc, pid)? = NodeRef(p.page) else { throw NibError.invalid("expected a page ref") }
        try ctx.mutate { tx in
            guard var page = try tx.content(doc).page(pid) else { throw NibError.notFound("page \(pid)") }
            page.bookmarked = true
            try tx.put(page, doc: doc)
        }
        return NoResult()
    }
}

/// Records calls to stand-ins for commands other features own (F002 library and trash, F022 pages), so the UI's
/// command traffic is asserted without those features.
@MainActor
private final class Recorder {
    struct Call {
        let command: String
        let params: JSONValue
        let group: String
        let session: NibID?
    }

    var calls: [Call] = []
    var commands: [String] { calls.map { $0.command } }
    var groups: Set<String> { Set(calls.map { $0.group }) }
    func params(_ command: String) -> [JSONValue] { calls.filter { $0.command == command }.map { $0.params } }
}

/// A window's floating host (the library container F019 installs), recording the toasts posted to it.
@MainActor
private final class ToastHost: FloatingHosting {
    var toasts: [String] = []

    func present(_ id: String, content: AnyView) {}
    func dismiss(_ id: String) {}
    func isPresenting(_ id: String) -> Bool { false }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { false }
    func removeAnchor(_ id: String) {}
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { nil }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) { toasts.append(message) }
}

@MainActor
final class FeatLibraryOrganizeTests: XCTestCase {
    private final class MenuAnimator: NSObject, UIContextMenuInteractionAnimating {
        var previewViewController: UIViewController? { nil }
        var completions: [() -> Void] = []
        func addAnimations(_ animations: @escaping () -> Void) { animations() }
        func addCompletion(_ completion: @escaping () -> Void) { completions.append(completion) }
        func finish() {
            let pending = completions
            completions.removeAll()
            pending.forEach { $0() }
        }
    }

    func testTrashMenuWaitsForDismissalBeforeRemovingRowsOrPresentingSheets() throws {
        let button = TrashMenuButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        var outcomes: [String] = []
        button.configure(recover: { outcomes.append("recover") }, move: { outcomes.append("move") },
                         delete: { outcomes.append("delete") })
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
        let actions = try XCTUnwrap(button.menu).children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["Recover", "Move", "Delete Permanently"])
        XCTAssertTrue(actions[2].attributes.contains(.destructive))
        for (index, action) in actions.enumerated() {
            button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
            button.sendAction(action)
            XCTAssertEqual(outcomes.count, index, "The source row must survive menu selection")
            let animator = MenuAnimator()
            button.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            XCTAssertTrue(button.isPresentingMenu)
            XCTAssertEqual(outcomes.count, index, "Wait for UIKit's dismissal, not just its start")
            animator.finish()
            XCTAssertFalse(button.isPresentingMenu)
            XCTAssertEqual(outcomes.count, index + 1)
            animator.finish()
            XCTAssertEqual(outcomes.count, index + 1, "An action must run only once")
        }
        XCTAssertEqual(outcomes, ["recover", "move", "delete"])
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        XCTAssertEqual(outcomes.count, 3, "Cancelling must not replay the preceding action")
    }

    func testRecoverFolderThenDocumentRunsAfterEachMenuDismissesInTheInvokingWindow() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let recorder = stub(h, [CommandIDs.trashRecover])
        let window = OrganizeWindow(app: h.app, session: h.session)
        let entries = [
            TrashEntry(ref: "folder:FIXTUREFLD01", title: "Folder", kind: .folder,
                       trashedAt: 1, style: nil, documentTitle: nil),
            TrashEntry(ref: "doc:FIXTUREDOC01", title: "Document", kind: .document(.notebook),
                       trashedAt: 1, style: nil, documentTitle: nil),
        ]
        for (index, entry) in entries.enumerated() {
            let button = TrashMenuButton(type: .custom)
            button.configure(recover: { Task { await TrashActions.recover(window, [entry]) } },
                             move: {}, delete: {})
            let interaction = try XCTUnwrap(button.contextMenuInteraction)
            let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
            button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
            button.sendAction(try XCTUnwrap(button.menu?.children.first as? UIAction))
            let animator = MenuAnimator()
            button.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            await Task.yield()
            XCTAssertEqual(recorder.calls.count, index)
            animator.finish()
            await eventually { recorder.calls.count == index + 1 }
            XCTAssertEqual(recorder.calls.last?.params, ["refs": [.string(entry.ref)]],
                           "Omit destination so recovery uses the original location")
            XCTAssertEqual(recorder.calls.last?.session, h.session.id)
        }
    }

    private func stub(_ h: Harness, _ ids: [String], result: JSONValue = [:]) -> Recorder {
        let recorder = Recorder()
        for id in ids {
            h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", effect: .library,
                                                      target: .library)) { params, ctx in
                recorder.calls.append(Recorder.Call(command: id, params: params, group: ctx.group,
                                                    session: ctx.session?.id))
                return result
            }
        }
        return recorder
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatLibraryOrganizeFeature.self])
        XCTAssertEqual(problems, [])
    }

    /// Polls (on the main actor) until `condition` holds or about a second has passed.
    private func eventually(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            tries += 1
        }
    }

    func testRegistersTabsSheetMenusShortcutAndSetting() throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let tabs = h.app.ui.panels.all.filter { $0.placement == .libraryTab }.map { $0.id }
        XCTAssertEqual(tabs, [PanelIDs.favourites, PanelIDs.trash])
        // Two fixed sheet panels; the folder they act on comes in PanelContext.params. They draw their own header.
        let sheets = h.app.ui.panels.all.filter { $0.owner == FeatLibraryOrganizeFeature.id && $0.placement == .sheet }
        XCTAssertEqual(Set(sheets.map { $0.id }), ["organize.folder.new", "organize.folder.style"])
        XCTAssertTrue(sheets.allSatisfy { $0.providesHeader })
        let ctx = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        for panel in h.app.ui.panels.all where panel.owner == FeatLibraryOrganizeFeature.id { _ = panel.makeView(ctx) }
        XCTAssertNotNil(h.app.settings.descriptor("organize.trashSort"))
        let menus = h.app.ui.menus.all.filter { $0.owner == FeatLibraryOrganizeFeature.id }
        XCTAssertTrue(Set(menus.map { $0.id }).isSuperset(of: [
            "organize.newFolder", "organize.customiseFolder", "organize.favourite.libraryItem",
            "organize.unfavourite.libraryItem", "organize.favourite.librarySelection",
            "organize.unfavourite.librarySelection",
        ]))
        // Every entry runs a command, so plugins, the AI and the bridge can do the same.
        for menu in menus { XCTAssertTrue([CommandIDs.panelOpen, CommandIDs.batch].contains(menu.command), menu.id) }
        let key = try XCTUnwrap(h.app.content.keyCommands.get("organize.newFolder"))
        XCTAssertEqual(key.command, CommandIDs.panelOpen)
        XCTAssertEqual(key.params, ["id": "organize.folder.new"])
        XCTAssertEqual(key.scope, .library)
        // The New Folder menu entry shows the key's shortcut.
        XCTAssertEqual(h.app.ui.menus.get("organize.newFolder")?.shortcut, key.shortcut)
    }

    func testFolderMenusPassTheFolderAsPanelParams() throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let folderMenu = MenuContext(app: h.app, nodes: [Fixtures.folderID])
        let docMenu = MenuContext(app: h.app, nodes: [Fixtures.docID])
        let customise = try XCTUnwrap(h.app.ui.menus.get("organize.customiseFolder"))
        XCTAssertTrue(customise.isVisible(folderMenu))
        XCTAssertFalse(customise.isVisible(docMenu))
        XCTAssertEqual(customise.params(folderMenu), ["id": "organize.folder.style", "folder": "folder:FIXTUREFLD01"])

        // New Folder goes into the folder the library shows (MenuContext.folder), else the root.
        let newFolder = try XCTUnwrap(h.app.ui.menus.get("organize.newFolder"))
        XCTAssertEqual(newFolder.params(MenuContext(app: h.app, folder: Fixtures.folderID)),
                       ["id": "organize.folder.new", "folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(newFolder.params(MenuContext(app: h.app)), ["id": "organize.folder.new"])
        XCTAssertEqual(newFolder.params(folderMenu), ["id": "organize.folder.new"])
        // No sheet is registered per folder any more.
        XCTAssertEqual(h.app.ui.panels.all.filter { $0.id.hasPrefix("organize.folder") }.count, 2)

        let add = try XCTUnwrap(h.app.ui.menus.get("organize.favourite.libraryItem"))
        let remove = try XCTUnwrap(h.app.ui.menus.get("organize.unfavourite.libraryItem"))
        XCTAssertTrue(add.isVisible(docMenu))
        XCTAssertFalse(remove.isVisible(docMenu))
        let call = try XCTUnwrap(add.params(docMenu)["calls"]?.arrayValue?.first)
        XCTAssertEqual(call["command"]?.stringValue, "doc.setFavorite")
        XCTAssertEqual(call["params"], ["doc": "doc:FIXTUREDOC01", "favorite": true])
    }

    func testSheetModeComesFromPanelParams() throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        func mode(_ panel: String, _ params: JSONValue) -> FolderStyleSheet.Mode {
            FolderStyleSheet.Mode.resolve(panel: panel, params: params, library: h.app.services.library)
        }
        let new = OrganizePanel.newFolder, style = OrganizePanel.folderStyle
        XCTAssertEqual(mode(new, ["folder": "folder:FIXTUREFLD01"]), .create(parent: Fixtures.folderID))
        XCTAssertEqual(mode(new, ["folder": "FIXTUREFLD01"]), .create(parent: Fixtures.folderID))
        XCTAssertEqual(mode(new, [:]), .create(parent: nil))
        XCTAssertEqual(mode(new, ["folder": "lib"]), .create(parent: nil))
        XCTAssertEqual(mode(new, ["folder": "folder:GONE"]), .create(parent: nil))
        XCTAssertEqual(mode(new, ["folder": "doc:FIXTUREDOC01"]), .create(parent: nil))
        XCTAssertEqual(mode(style, ["folder": "folder:FIXTUREFLD01"]), .edit(Fixtures.folderID))
        XCTAssertEqual(mode(style, [:]), .create(parent: nil))
        try h.library.trash(Fixtures.folderID)
        XCTAssertEqual(mode(style, ["folder": "folder:FIXTUREFLD01"]), .create(parent: nil))
        XCTAssertEqual(mode(new, ["folder": "folder:FIXTUREFLD01"]), .create(parent: nil))
    }

    func testFolderGlyphsAndSwatchesComeFromNibDesign() {
        XCTAssertEqual(FolderIcons.glyph("\u{1F4DA}"), .emoji("\u{1F4DA}"))
        XCTAssertEqual(FolderIcons.glyph("atom"), .symbol(FolderIcons.symbol("atom")))
        XCTAssertNotEqual(FolderIcons.symbol("atom"), .folderFill)
        XCTAssertEqual(FolderIcons.glyph(nil), .symbol(.folderFill))
        XCTAssertEqual(FolderIcons.glyph("no.such.symbol.anywhere"), .symbol(.folderFill))
        XCTAssertEqual(FolderColour.swatches.map { $0.id }, NibFolderColor.allCases.map { $0.rawValue })
        XCTAssertEqual(FolderColour.name(FolderColour.rgba(NibFolderColor.moss)), NibFolderColor.moss.name)
        XCTAssertEqual(FolderColour.name(RGBA(1, 2, 3)), "#010203")
    }

    func testFavouriteBatchStarsOnlyWhatChanges() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let recorder = stub(h, ["doc.setFavorite", "folder.setStyle"])
        try h.library.setStyle(FolderStyle(favorite: true), folder: Fixtures.folderID)
        let nodes = try [XCTUnwrap(h.library.node(Fixtures.folderID)), XCTUnwrap(h.library.node(Fixtures.docID))]
        XCTAssertTrue(Favouriting.offers(nodes, favourite: true))
        XCTAssertFalse(Favouriting.offers(nodes, favourite: false))

        try await h.run(CommandIDs.batch, Favouriting.batch(nodes, favourite: true))
        XCTAssertEqual(recorder.commands, ["doc.setFavorite"])
        XCTAssertEqual(recorder.params("doc.setFavorite"), [["doc": "doc:FIXTUREDOC01", "favorite": true]])

        let unstar = Favouriting.calls([nodes[0]], favourite: false)
        XCTAssertEqual(unstar, [["command": "folder.setStyle",
                                 "params": ["folder": "folder:FIXTUREFLD01", "favorite": false]]])
    }

    func testFolderDraftValidatesNamesAndBuildsParams() {
        let cobalt = RGBA(0x21, 0x56, 0xD9)
        func named(_ title: String) -> FolderDraft {
            FolderDraft(title: title, color: cobalt, icon: nil, favorite: false, parent: nil)
        }
        XCTAssertEqual(named("   ").titleProblem, .empty)
        XCTAssertEqual(named("Maths/Pure").titleProblem, .separator)
        XCTAssertEqual(named(".hidden").titleProblem, .leadingDot)
        XCTAssertEqual(named(String(repeating: "x", count: 256)).titleProblem, .tooLong)
        XCTAssertNil(named("Computer Science 9618").titleProblem)

        var draft = FolderDraft(title: "  Physics 9702 ", color: cobalt, icon: nil, favorite: false,
                                parent: Fixtures.folderID)
        XCTAssertEqual(draft.createParams(id: "NEWFOLDER001"),
                       ["title": "Physics 9702", "color": "#2156D9", "id": "NEWFOLDER001", "parent": "folder:FIXTUREFLD01"])

        let original = draft
        XCTAssertNil(draft.styleParams(folder: "F1", since: original))
        draft.icon = "atom"
        draft.favorite = true
        XCTAssertEqual(draft.styleParams(folder: "F1", since: original),
                       ["folder": "folder:F1", "icon": "atom", "favorite": true])
        var reverted = draft
        reverted.icon = nil
        reverted.color = RGBA(0x0B, 0x87, 0x93, 0x80)
        XCTAssertEqual(reverted.styleParams(folder: "F1", since: draft),
                       ["folder": "folder:F1", "icon": "folder.fill", "color": "#0B879380"])
    }

    func testHexAndEmojiParsing() {
        XCTAssertEqual(FolderDraft.parseHex("#2156d9"), RGBA(0x21, 0x56, 0xD9))
        XCTAssertEqual(FolderDraft.parseHex("0b8"), RGBA(0x00, 0xBB, 0x88))
        XCTAssertEqual(FolderDraft.parseHex(" 7B3FA0 "), RGBA(0x7B, 0x3F, 0xA0))
        XCTAssertNil(FolderDraft.parseHex("#12345"))
        XCTAssertNil(FolderDraft.parseHex("zzzzzz"))
        XCTAssertEqual(FolderDraft.hex(RGBA(1, 2, 3)), "#010203")
        XCTAssertEqual(FolderDraft.hex(RGBA(1, 2, 3, 128)), "#01020380")

        XCTAssertTrue(FolderDraft.isSingleEmoji("\u{1F4DA}"))                     // books
        XCTAssertTrue(FolderDraft.isSingleEmoji("\u{1F469}\u{200D}\u{1F52C}"))    // ZWJ sequence
        XCTAssertTrue(FolderDraft.isSingleEmoji("\u{1F1EC}\u{1F1E7}"))            // flag
        XCTAssertTrue(FolderDraft.isSingleEmoji("1\u{FE0F}\u{20E3}"))             // keycap
        XCTAssertTrue(FolderDraft.isSingleEmoji("\u{2764}\u{FE0F}"))              // heart, emoji style
        XCTAssertFalse(FolderDraft.isSingleEmoji("\u{00A9}"))                     // copyright sign, text style
        XCTAssertFalse(FolderDraft.isSingleEmoji("#"))
        XCTAssertFalse(FolderDraft.isSingleEmoji("1"))
        XCTAssertFalse(FolderDraft.isSingleEmoji("A"))
        XCTAssertFalse(FolderDraft.isSingleEmoji(""))
        XCTAssertFalse(FolderDraft.isSingleEmoji("\u{1F4DA}\u{1F4DA}"))
        XCTAssertFalse(FolderDraft.isSingleEmoji("folder.fill"))
    }

    func testHexFieldKeepsSelectAllOnItsNativeTextSelection() throws {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.rootViewController = controller
        let field = FolderHexTextField(frame: CGRect(x: 20, y: 20, width: 240, height: 44))
        controller.view.addSubview(field)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        field.text = "#2156D9"
        XCTAssertTrue(field.becomeFirstResponder())
        let key = try XCTUnwrap(field.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .command })
        XCTAssertTrue(key.wantsPriorityOverSystemBehavior)
        let action = try XCTUnwrap(key.action)
        XCTAssertTrue(field.canPerformAction(action, withSender: key))
        _ = field.perform(action, with: key)
        let selected = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.text(in: selected), "#2156D9")
        field.insertText("#FF8800")
        XCTAssertEqual(field.text, "#FF8800")
        XCTAssertEqual(FolderDraft.parseHex(try XCTUnwrap(field.text)), RGBA(0xFF, 0x88, 0x00))
    }

    func testPageIndexNumbersBookmarkedAndTrashedPages() {
        var (content, _) = Fixtures.sampleContent()
        // Page order is FIXTUREPG001 ("V"), FIXTUREPG002 ("k"), FIXTUREPG003 ("t").
        content.pages[0].deleted = true
        content.pages[0].trashedAt = 1_700_000_500
        content.pages[1].bookmarked = true
        content.pages[2].bookmarked = true
        content.pages[2].rotation = 90
        let pages = PageIndex.pages(of: content)
        XCTAssertEqual(pages.bookmarked.map { $0.page }, [Fixtures.page2, Fixtures.pdfPage])
        XCTAssertEqual(pages.bookmarked.map { $0.number }, [1, 2])
        XCTAssertEqual(pages.trashed.map { $0.page }, [Fixtures.page1])
        XCTAssertEqual(pages.trashed.first?.number, 1)                            // where it comes back
        XCTAssertEqual(pages.trashed.first?.trashedAt, 1_700_000_500)
        let a4 = PageSize.a4
        XCTAssertEqual(pages.bookmarked[0].aspect ?? 0, a4.width / a4.height, accuracy: 1e-9)
        XCTAssertEqual(pages.bookmarked[1].aspect ?? 0, a4.height / a4.width, accuracy: 1e-9)
    }

    func testPageIndexFollowsCommitsAndUndo() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        h.app.commands.register(BookmarkStandIn.self)
        let index = PageIndex(app: h.app)
        index.attach()
        await index.sync()
        XCTAssertTrue(index.bookmarked.isEmpty)
        try await h.run("test.bookmark", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(index.bookmarked.map { $0.ref }, ["page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertTrue(index.bookmarked.isEmpty)
    }

    func testPageIndexReadsDocumentsNeverOpenedAndFollowsTheLibrary() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        var (content, _) = Fixtures.sampleContent()
        let unopened: DocumentID = "UNOPENED0001"
        content.meta.id = unopened
        for i in content.pages.indices {
            if content.pages[i].id == Fixtures.page1 {
                content.pages[i].deleted = true
                content.pages[i].trashedAt = 1_700_000_500
            }
            if content.pages[i].id == Fixtures.page2 { content.pages[i].bookmarked = true }
        }
        let index = PageIndex(app: h.app)
        index.attach()
        await index.sync()
        XCTAssertNil(index.documents[unopened])

        // A document added to the library is read when the library reports the change, without opening it.
        _ = try h.library.createDocument(content, title: "Unopened", in: nil)
        h.app.events.emit(NibEventType.libraryChanged)
        await eventually { index.documents[unopened] != nil }
        XCTAssertEqual(index.documents[unopened]?.bookmarked.map { $0.page }, [Fixtures.page2])
        XCTAssertEqual(index.documents[unopened]?.trashed.map { $0.page }, [Fixtures.page1])
        XCTAssertEqual(index.documents[unopened]?.trashed.first?.number, 1)
        XCTAssertFalse(h.app.workspace.isLoaded(unopened))

        // Trashed with its document: gone from the index; recovered: read again.
        try h.library.trash(unopened)
        await index.sync()
        XCTAssertNil(index.documents[unopened])
        try h.library.restore(unopened, to: nil)
        await index.sync()
        XCTAssertEqual(index.documents[unopened]?.bookmarked.map { $0.page }, [Fixtures.page2])
        try h.library.deletePermanently(unopened)
        await index.sync()
        XCTAssertNil(index.documents[unopened])
    }

    func testToastsAndCommandsGoToTheWindowTheTabIsIn() async {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let recorder = stub(h, ["trash.recover"])
        let host = ToastHost()
        let libraryWindow = EditorSession()
        libraryWindow.floatingHost = host
        let window = OrganizeWindow(PanelContext(app: h.app, session: libraryWindow, navigator: nil, dismiss: {}))
        XCTAssertTrue(window.session === libraryWindow)
        window.toast("Recovered 1 item.")
        XCTAssertEqual(host.toasts, ["Recovered 1 item."])

        let doc = TrashEntry(ref: "doc:D2", title: "Algebra", kind: .document(.notebook), trashedAt: 1, style: nil,
                             documentTitle: nil)
        let recovered = await TrashActions.recover(window, [doc])
        XCTAssertTrue(recovered)
        XCTAssertEqual(recorder.calls.map { $0.session }, [libraryWindow.id])

        // Without a panel session: the active window, which has no floating host here (announced only).
        let fallback = OrganizeWindow(app: h.app)
        XCTAssertTrue(fallback.session === h.app.services.sessions.active)
        fallback.toast("Emptied the Trash.")
        XCTAssertEqual(host.toasts, ["Recovered 1 item."])
    }

    func testFavouritesListStarredItemsAndBookmarksOfLiveDocuments() {
        let starred = LibraryNode(id: "F1", kind: .folder, title: "Physics", path: "Physics",
                                  style: FolderStyle(favorite: true))
        let plain = LibraryNode(id: "F2", kind: .folder, title: "Maths", path: "Maths")
        let later = LibraryNode(id: "D2", kind: .document, title: "b notes", path: "b notes", documentKind: .notebook,
                                favorite: true)
        let first = LibraryNode(id: "D1", kind: .document, title: "A notes", path: "A notes", documentKind: .notebook,
                                favorite: true)
        let trashed = LibraryNode(id: "D3", kind: .document, title: "Old", path: "Old", favorite: true, trashedAt: 1)
        let page = PageEntry(doc: "D1", page: "P1", number: 3, title: nil, aspect: nil, trashedAt: nil)
        let gone = PageEntry(doc: "D9", page: "P1", number: 1, title: nil, aspect: nil, trashedAt: nil)
        let favourites = Favourites.make(nodes: [starred, plain, later, first, trashed],
                                         pages: ["D1": DocumentPages(bookmarked: [page]),
                                                 "D9": DocumentPages(bookmarked: [gone])])
        XCTAssertEqual(favourites.folders.map { $0.id }, ["F1"])
        XCTAssertEqual(favourites.documents.map { $0.id }, ["D1", "D2"])
        XCTAssertEqual(favourites.pages.map { $0.entry.ref }, ["page:D1/P1"])
        XCTAssertEqual(favourites.pages.first?.documentTitle, "A notes")
        XCTAssertEqual(favourites.count, 4)
        XCTAssertTrue(Favourites.make(nodes: [plain, trashed], pages: [:]).isEmpty)
    }

    func testTrashEntriesSortAndPlan() {
        let folder = LibraryNode(id: "F1", kind: .folder, title: "Zoology", path: "Zoology", trashedAt: 300)
        let child = LibraryNode(id: "D5", kind: .document, title: "Inside", path: "Zoology/Inside", parent: "F1",
                                documentKind: .notebook, trashedAt: 300)
        let board = LibraryNode(id: "D2", kind: .document, title: "Algebra", path: "Algebra", documentKind: .whiteboard,
                                trashedAt: 100)
        let live = LibraryNode(id: "D1", kind: .document, title: "Kinematics", path: "Kinematics", documentKind: .notebook)
        let page = PageEntry(doc: "D1", page: "P9", number: 2, title: nil, aspect: nil, trashedAt: 200)
        let orphan = PageEntry(doc: "D8", page: "P1", number: 1, title: nil, aspect: nil, trashedAt: 400)
        let entries = Trash.entries(trashed: [folder, child, board], live: [live],
                                    pages: ["D1": DocumentPages(trashed: [page]), "D8": DocumentPages(trashed: [orphan])])
        XCTAssertEqual(Set(entries.map { $0.ref }), ["folder:F1", "doc:D2", "page:D1/P9"])
        XCTAssertEqual(Trash.sorted(entries, by: .date).map { $0.ref }, ["folder:F1", "page:D1/P9", "doc:D2"])
        XCTAssertEqual(Trash.sorted(entries, by: .name).map { $0.ref }, ["doc:D2", "page:D1/P9", "folder:F1"])
        XCTAssertEqual(Trash.sorted(entries, by: .type).map { $0.ref }, ["folder:F1", "doc:D2", "page:D1/P9"])

        let plan = Trash.plan(entries)
        XCTAssertEqual(Set(plan.nodes), ["folder:F1", "doc:D2"])
        XCTAssertEqual(plan.pages, ["D1": ["page:D1/P9"]])
        XCTAssertNil(Trash.moveTarget(entries))
        XCTAssertEqual(Trash.moveTarget(entries.filter { $0.kind == .page }), .notebooks)
        XCTAssertEqual(Trash.moveTarget(entries.filter { $0.kind != .page }), .folders)
    }

    func testTrashActionsRecoverToTheOriginMoveDeleteAndEmpty() async {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let window = OrganizeWindow(app: h.app)
        let recorder = stub(h, ["trash.recover", "library.move", "trash.deletePermanently", "trash.empty",
                                "page.restore", "page.purge", "page.moveTo"])
        func page(_ ref: String) -> TrashEntry {
            TrashEntry(ref: ref, title: "Page", kind: .page, trashedAt: 2, style: nil, documentTitle: "Kinematics")
        }
        let doc = TrashEntry(ref: "doc:D2", title: "Algebra", kind: .document(.notebook), trashedAt: 1, style: nil,
                             documentTitle: nil)
        let entries = [doc, page("page:D1/P9"), page("page:D1/P8"), page("page:D3/P1")]

        let recovered = await TrashActions.recover(window, entries)
        XCTAssertTrue(recovered)
        // No destination: documents return to their folder and pages to their document.
        XCTAssertEqual(recorder.params("trash.recover"), [["refs": ["doc:D2"]]])
        XCTAssertEqual(recorder.params("page.restore"), [["pages": ["page:D1/P9", "page:D1/P8"]],
                                                         ["pages": ["page:D3/P1"]]])
        XCTAssertEqual(recorder.groups.count, 1)

        recorder.calls.removeAll()
        _ = await TrashActions.move(window, [doc], toFolder: "F7")
        XCTAssertEqual(recorder.params("trash.recover"), [["refs": ["doc:D2"], "folder": "folder:F7"]])

        recorder.calls.removeAll()
        _ = await TrashActions.move(window, [doc], toFolder: nil)
        XCTAssertEqual(recorder.commands, ["trash.recover", "library.move"])
        XCTAssertEqual(recorder.params("library.move"), [["refs": ["doc:D2"]]])

        recorder.calls.removeAll()
        _ = await TrashActions.move(window, [page("page:D1/P9")], toDocument: "D4")
        XCTAssertEqual(recorder.commands, ["page.restore", "page.moveTo"])
        XCTAssertEqual(recorder.params("page.moveTo"), [["pages": ["page:D1/P9"], "doc": "doc:D4"]])
        XCTAssertEqual(recorder.groups.count, 1)

        recorder.calls.removeAll()
        _ = await TrashActions.deletePermanently(window, entries)
        XCTAssertEqual(recorder.commands, ["trash.deletePermanently", "page.purge", "page.purge"])

        recorder.calls.removeAll()
        let emptied = await TrashActions.empty(window, entries)
        XCTAssertTrue(emptied)
        XCTAssertEqual(recorder.commands, ["page.purge", "page.purge", "trash.empty"])
    }

    func testFolderSheetCreatesAndRestylesThroughCommands() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let recorder = stub(h, ["folder.create", "folder.setStyle", "library.rename"], result: ["ref": "folder:NEW"])
        let window = OrganizeWindow(app: h.app)
        let mode = FolderStyleSheet.Mode.create(parent: Fixtures.folderID)
        var draft = FolderStyleSheet.initialDraft(h.app, mode)
        draft.title = "Chemistry"
        draft.icon = "flask.fill"
        draft.favorite = true
        let created = await FolderStyleSheet.commit(window, mode: mode, draft: draft, original: draft)
        XCTAssertTrue(created)
        let create = try XCTUnwrap(recorder.params("folder.create").first)
        XCTAssertEqual(create["title"], "Chemistry")
        XCTAssertEqual(create["parent"], "folder:FIXTUREFLD01")
        XCTAssertEqual(create["icon"], "flask.fill")
        XCTAssertEqual(create["color"], "#2156D9")
        XCTAssertNotNil(create["id"]?.stringValue)
        XCTAssertEqual(recorder.params("folder.setStyle"), [["folder": "folder:NEW", "favorite": true]])
        XCTAssertEqual(recorder.groups.count, 1)

        recorder.calls.removeAll()
        try h.library.setStyle(FolderStyle(color: RGBA(0x2F, 0x7A, 0x3C), icon: "atom"), folder: Fixtures.folderID)
        let edit = FolderStyleSheet.Mode.edit(Fixtures.folderID)
        let original = FolderStyleSheet.initialDraft(h.app, edit)
        XCTAssertEqual(original.title, "Fixtures")
        XCTAssertEqual(original.icon, "atom")
        XCTAssertEqual(original.color, RGBA(0x2F, 0x7A, 0x3C))
        var changed = original
        changed.title = "Lab"
        changed.icon = nil
        let saved = await FolderStyleSheet.commit(window, mode: edit, draft: changed, original: original)
        XCTAssertTrue(saved)
        XCTAssertEqual(recorder.params("library.rename"), [["ref": "folder:FIXTUREFLD01", "title": "Lab"]])
        XCTAssertEqual(recorder.params("folder.setStyle"), [["folder": "folder:FIXTUREFLD01", "icon": "folder.fill"]])
    }

    func testFolderRowsAreDepthFirstUnderTheLibraryRoot() {
        let biology = LibraryNode(id: "A", kind: .folder, title: "Biology", path: "Biology")
        let cells = LibraryNode(id: "A1", kind: .folder, title: "Cells", path: "Biology/Cells", parent: "A")
        let art = LibraryNode(id: "B", kind: .folder, title: "art", path: "art")
        let loose = LibraryNode(id: "C", kind: .folder, title: "Loose", path: "x/Loose", parent: "GONE")
        let doc = LibraryNode(id: "D", kind: .document, title: "Doc", path: "Doc", documentKind: .notebook)
        let rows = DestinationPickerSheet.folderRows([cells, art, doc, biology, loose])
        XCTAssertEqual(rows.map { $0.id }, ["lib", "folder:B", "folder:A", "folder:A1", "folder:C"])
        XCTAssertEqual(rows.map { $0.depth }, [0, 1, 1, 2, 1])
        XCTAssertEqual(DestinationPickerSheet.folder("folder:A1"), FolderID("A1"))
        XCTAssertNil(DestinationPickerSheet.folder(DestinationPickerSheet.root))
        XCTAssertEqual(DestinationPickerSheet.notebookRows([doc, biology], excluding: []).map { $0.id }, ["doc:D"])
    }

    func testTrashSortIsADeclaredSettingChangedByCommand() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        XCTAssertEqual(h.app.settings.get(OrganizeSettings.trashSort), .date)
        try await h.run(CommandIDs.settingsSet, ["name": "organize.trashSort", "value": "type"])
        XCTAssertEqual(h.app.settings.get(OrganizeSettings.trashSort), .type)
        do {
            try await h.run(CommandIDs.settingsSet, ["name": "organize.trashSort", "value": "size"])
            XCTFail("an unknown sort order must be rejected")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .invalidParams)
        }
    }
}
