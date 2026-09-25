import XCTest
import NibContracts
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
    }

    var calls: [Call] = []
    var commands: [String] { calls.map { $0.command } }
    var groups: Set<String> { Set(calls.map { $0.group }) }
    func params(_ command: String) -> [JSONValue] { calls.filter { $0.command == command }.map { $0.params } }
}

@MainActor
final class FeatLibraryOrganizeTests: XCTestCase {
    private func stub(_ h: Harness, _ ids: [String], result: JSONValue = [:]) -> Recorder {
        let recorder = Recorder()
        for id in ids {
            h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", effect: .library,
                                                      target: .library)) { params, ctx in
                recorder.calls.append(Recorder.Call(command: id, params: params, group: ctx.group))
                return result
            }
        }
        return recorder
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatLibraryOrganizeFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersTabsSheetMenusShortcutAndSetting() {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let tabs = h.app.ui.panels.all.filter { $0.placement == .libraryTab }.map { $0.id }
        XCTAssertEqual(tabs, ["organize.favourites", "organize.trash"])
        XCTAssertEqual(h.app.ui.panels.get("organize.folder.new")?.placement, .sheet)
        XCTAssertNotNil(h.app.settings.descriptor("organize.trashSort"))
        let menus = h.app.ui.menus.all.filter { $0.owner == FeatLibraryOrganizeFeature.id }
        XCTAssertTrue(Set(menus.map { $0.id }).isSuperset(of: [
            "organize.newFolder", "organize.customiseFolder", "organize.favourite.libraryItem",
            "organize.unfavourite.libraryItem", "organize.favourite.librarySelection",
            "organize.unfavourite.librarySelection",
        ]))
        // Every entry runs a command, so plugins, the AI and the bridge can do the same.
        for menu in menus { XCTAssertTrue(["panel.open", CommandIDs.batch].contains(menu.command), menu.id) }
        XCTAssertEqual(h.app.content.keyCommands.get("organize.newFolder")?.command, "panel.open")
        XCTAssertEqual(h.app.content.keyCommands.get("organize.newFolder")?.scope, .library)
    }

    func testFolderMenusTargetTheFolderAndRegisterItsSheet() throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let folderMenu = MenuContext(app: h.app, nodes: [Fixtures.folderID])
        let docMenu = MenuContext(app: h.app, nodes: [Fixtures.docID])
        let customise = try XCTUnwrap(h.app.ui.menus.get("organize.customiseFolder"))
        XCTAssertTrue(customise.isVisible(folderMenu))
        XCTAssertFalse(customise.isVisible(docMenu))
        let sheet = try XCTUnwrap(customise.params(folderMenu)["id"]?.stringValue)
        XCTAssertEqual(sheet, "organize.folder.style.FIXTUREFLD01")
        XCTAssertEqual(h.app.ui.panels.get(sheet)?.placement, .sheet)

        let newFolder = try XCTUnwrap(h.app.ui.menus.get("organize.newFolder"))
        XCTAssertEqual(newFolder.params(folderMenu)["id"]?.stringValue, "organize.folder.new.FIXTUREFLD01")
        XCTAssertEqual(newFolder.params(MenuContext(app: h.app))["id"]?.stringValue, "organize.folder.new")

        let add = try XCTUnwrap(h.app.ui.menus.get("organize.favourite.libraryItem"))
        let remove = try XCTUnwrap(h.app.ui.menus.get("organize.unfavourite.libraryItem"))
        XCTAssertTrue(add.isVisible(docMenu))
        XCTAssertFalse(remove.isVisible(docMenu))
        let call = try XCTUnwrap(add.params(docMenu)["calls"]?.arrayValue?.first)
        XCTAssertEqual(call["command"]?.stringValue, "doc.setFavorite")
        XCTAssertEqual(call["params"], ["doc": "doc:FIXTUREDOC01", "favorite": true])
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
        let index = PageIndex.shared(h.app)
        XCTAssertTrue(index.bookmarked.isEmpty)
        try await h.run("test.bookmark", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(index.bookmarked.map { $0.ref }, ["page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertTrue(index.bookmarked.isEmpty)
        XCTAssertTrue(PageIndex.shared(h.app) === index)

        index.update(Fixtures.textDocID, DocumentPages(bookmarked: [
            PageEntry(doc: Fixtures.textDocID, page: "P1", number: 1, title: nil, aspect: nil, trashedAt: nil),
        ]))
        index.prune(keeping: [Fixtures.docID])
        XCTAssertNil(index.documents[Fixtures.textDocID])
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
        let recorder = stub(h, ["trash.recover", "library.move", "trash.deletePermanently", "trash.empty",
                                "page.restore", "page.purge", "page.moveTo"])
        func page(_ ref: String) -> TrashEntry {
            TrashEntry(ref: ref, title: "Page", kind: .page, trashedAt: 2, style: nil, documentTitle: "Kinematics")
        }
        let doc = TrashEntry(ref: "doc:D2", title: "Algebra", kind: .document(.notebook), trashedAt: 1, style: nil,
                             documentTitle: nil)
        let entries = [doc, page("page:D1/P9"), page("page:D1/P8"), page("page:D3/P1")]

        let recovered = await TrashActions.recover(h.app, entries)
        XCTAssertTrue(recovered)
        // No destination: documents return to their folder and pages to their document.
        XCTAssertEqual(recorder.params("trash.recover"), [["refs": ["doc:D2"]]])
        XCTAssertEqual(recorder.params("page.restore"), [["pages": ["page:D1/P9", "page:D1/P8"]],
                                                         ["pages": ["page:D3/P1"]]])
        XCTAssertEqual(recorder.groups.count, 1)

        recorder.calls.removeAll()
        _ = await TrashActions.move(h.app, [doc], toFolder: "F7")
        XCTAssertEqual(recorder.params("trash.recover"), [["refs": ["doc:D2"], "folder": "folder:F7"]])

        recorder.calls.removeAll()
        _ = await TrashActions.move(h.app, [doc], toFolder: nil)
        XCTAssertEqual(recorder.commands, ["trash.recover", "library.move"])
        XCTAssertEqual(recorder.params("library.move"), [["refs": ["doc:D2"]]])

        recorder.calls.removeAll()
        _ = await TrashActions.move(h.app, [page("page:D1/P9")], toDocument: "D4")
        XCTAssertEqual(recorder.commands, ["page.restore", "page.moveTo"])
        XCTAssertEqual(recorder.params("page.moveTo"), [["pages": ["page:D1/P9"], "doc": "doc:D4"]])
        XCTAssertEqual(recorder.groups.count, 1)

        recorder.calls.removeAll()
        _ = await TrashActions.deletePermanently(h.app, entries)
        XCTAssertEqual(recorder.commands, ["trash.deletePermanently", "page.purge", "page.purge"])

        recorder.calls.removeAll()
        let emptied = await TrashActions.empty(h.app, entries)
        XCTAssertTrue(emptied)
        XCTAssertEqual(recorder.commands, ["page.purge", "page.purge", "trash.empty"])
    }

    func testFolderSheetCreatesAndRestylesThroughCommands() async throws {
        let h = Harness(features: [FeatLibraryOrganizeFeature.self])
        let recorder = stub(h, ["folder.create", "folder.setStyle", "library.rename"], result: ["ref": "folder:NEW"])
        let mode = FolderStyleSheet.Mode.create(parent: Fixtures.folderID)
        var draft = FolderStyleSheet.initialDraft(h.app, mode)
        draft.title = "Chemistry"
        draft.icon = "flask.fill"
        draft.favorite = true
        let created = await FolderStyleSheet.commit(h.app, mode: mode, draft: draft, original: draft)
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
        let saved = await FolderStyleSheet.commit(h.app, mode: edit, draft: changed, original: original)
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
