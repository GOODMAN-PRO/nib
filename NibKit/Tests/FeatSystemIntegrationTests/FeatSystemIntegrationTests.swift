import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatSystemIntegration

@MainActor
final class FeatSystemIntegrationTests: XCTestCase {

    // MARK: Registration

    func testRegistersExactlyItsCommandsAndPassesConformance() async {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let mine = h.app.commands.all().filter { $0.owner == FeatSystemIntegrationFeature.id }.map { $0.id }
        XCTAssertEqual(mine, [CommandIDs.appOpenURL, CommandIDs.appQuickAction])
        for id in mine {
            let d = try? XCTUnwrap(h.app.commands.descriptor(id))
            XCTAssertEqual(d?.effect, .session, id)
            XCTAssertLessThanOrEqual(d?.summary.count ?? 999, 200, id)
        }
        let problems = await CommandConformance.check(features: [FeatSystemIntegrationFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Quick actions

    func testFavouritesAreTheFourMostRecentlyModifiedDocuments() {
        func node(_ id: String, _ modified: Double, favourite: Bool = true, kind: LibraryNodeKind = .document,
                  trashed: Bool = false) -> LibraryNode {
            LibraryNode(id: NibID(id), kind: kind, title: id.lowercased(), path: id, documentKind: .notebook,
                        modified: modified, favorite: favourite, trashedAt: trashed ? 1 : nil)
        }
        let nodes = [node("OLD", 1), node("NEWEST", 9), node("MID", 5), node("NOTFAV", 10, favourite: false),
                     node("FOLDER", 11, kind: .folder), node("TRASHED", 12, trashed: true), node("NEW", 8),
                     node("TIEB", 5), node("SIXTH", 0)]
        let picked = QuickActions.favourites(nodes, limit: QuickActions.maxFavourites).map { $0.id.raw }
        XCTAssertEqual(picked, ["NEWEST", "NEW", "MID", "TIEB"])
        XCTAssertEqual(QuickActions.favourites(nodes, limit: 0), [])
    }

    func testQuickActionItemsAndTypes() throws {
        var notebook = LibraryNode(id: "DOCA", kind: .document, title: "Kinematics", path: "Physics/Kinematics",
                                   parent: "PHYS", documentKind: .notebook, modified: 3, favorite: true)
        let board = LibraryNode(id: "DOCB", kind: .document, title: "  ", path: "Board", documentKind: .whiteboard,
                                modified: 2, favorite: true)
        let items = QuickActions.items(for: [notebook, board], folderTitle: { $0 == "PHYS" ? "Physics" : nil })
        XCTAssertEqual(items, [
            QuickActionItem(type: "app.nib.open.DOCA", title: "Kinematics", subtitle: "Physics", symbol: .notebook, doc: "DOCA"),
            QuickActionItem(type: "app.nib.open.DOCB", title: "Untitled", subtitle: nil, symbol: .whiteboard, doc: "DOCB"),
        ])
        let shortcut = QuickActions.shortcutItem(items[0])
        XCTAssertEqual(shortcut.type, "app.nib.open.DOCA")
        XCTAssertEqual(shortcut.localizedTitle, "Kinematics")
        XCTAssertEqual(shortcut.localizedSubtitle, "Physics")
        // Every type reads back as the link it stands for; the static QuickNote type matches Info.plist.
        XCTAssertEqual(try QuickActionTypes.link(for: items[0].type), .open(doc: "DOCA", page: nil, comment: nil))
        XCTAssertEqual(try QuickActionTypes.link(for: "app.nib.quicknote"), .quickNote)
        XCTAssertThrowsError(try QuickActionTypes.link(for: "app.nib.open.bad id"))
        XCTAssertThrowsError(try QuickActionTypes.link(for: "com.other.action"))
        notebook.documentKind = .studySet
        XCTAssertEqual(QuickActions.items(for: [notebook], folderTitle: { _ in nil }).first?.symbol, .studySets)
    }

    func testQuickActionCommandRunsQuickNoteAndOpensFavourites() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.docQuickNote, effect: .library, result: ["ref": "doc:QUICKNOTE001"])
        stubs.stub(h.app, CommandIDs.docOpen)
        var r = try await h.run(CommandIDs.appQuickAction, ["type": "app.nib.quicknote"])
        XCTAssertEqual(r["route"], "quicknote")
        XCTAssertEqual(r["ref"], "doc:QUICKNOTE001")
        r = try await h.run(CommandIDs.appQuickAction, ["type": "app.nib.open.FIXTUREDOC03"])
        XCTAssertEqual(r["ref"], "doc:FIXTUREDOC03")
        XCTAssertEqual(stubs.params(CommandIDs.docOpen), [["doc": "doc:FIXTUREDOC03"]])
        do {
            _ = try await h.run(CommandIDs.appQuickAction, ["type": "app.nib.somethingElse"])
            XCTFail("an unknown quick action must fail")
        } catch {
            XCTAssertEqual(NibError.wrap(error).code, .invalidParams)
        }
    }

    func testPublisherSetsShortcutsAndWritesFavouritesFileOnlyWhenChanged() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let publisher = try XCTUnwrap(SystemRuntime.shared(h.app.services)?.quickActions)
        var applied: [[UIApplicationShortcutItem]] = []
        var reloads = 0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-group-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        publisher.applyShortcutItems = { applied.append($0) }
        publisher.containerURL = { dir }
        publisher.reloadWidgets = { reloads += 1 }

        // No favourites yet: the dynamic items are cleared once (the static QuickNote stays in Info.plist) and the
        // widget gets an empty list.
        publisher.refresh()
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.last?.count, 0)
        await drain(publisher)
        let empty = try JSONDecoder().decode(FavouritesFile.Snapshot.self,
                                             from: Data(contentsOf: dir.appendingPathComponent(FavouritesFile.name)))
        XCTAssertEqual(empty.favourites, [])
        XCTAssertEqual(reloads, 1)

        for doc in [Fixtures.docID, Fixtures.whiteboardID] {
            try h.library.setStyle(FolderStyle(favorite: true), folder: doc)
        }
        publisher.refresh()
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(Set(applied.last?.map { $0.type } ?? []), ["app.nib.open.FIXTUREDOC01", "app.nib.open.FIXTUREDOC04"])
        XCTAssertEqual(applied.last?.first?.localizedSubtitle, "Fixtures")     // their folder

        await drain(publisher)
        let data = try Data(contentsOf: dir.appendingPathComponent(FavouritesFile.name))
        let snapshot = try JSONDecoder().decode(FavouritesFile.Snapshot.self, from: data)
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(Set(snapshot.favourites.map { $0.id }), ["FIXTUREDOC01", "FIXTUREDOC04"])
        let board = try XCTUnwrap(snapshot.favourites.first { $0.id == "FIXTUREDOC04" })
        XCTAssertEqual(board.kind, "whiteboard")
        XCTAssertEqual(board.title, "Fixture Whiteboard")
        XCTAssertEqual(try DeepLinkParser.parse(board.url), .open(doc: Fixtures.whiteboardID, page: nil, comment: nil))
        XCTAssertEqual(reloads, 2)

        // Nothing changed: neither the Home Screen items nor the file are touched again.
        publisher.refresh()
        await drain(publisher)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(reloads, 2)

        // Without an App Group only the quick actions are kept.
        publisher.containerURL = { nil }
        try h.library.setStyle(FolderStyle(favorite: false), folder: Fixtures.docID)
        publisher.refresh()
        XCTAssertEqual(applied.last?.map { $0.type }, ["app.nib.open.FIXTUREDOC04"])
    }

    /// Saving a favourite moves only `modified`: favourites.json is not rewritten and widgets are not reloaded for that.
    func testFavouritesListingIgnoresModifiedTimes() {
        let a = FavouritesFile.Entry(id: "DOCA", title: "Kinematics", kind: "notebook", folder: "Physics", modified: 1,
                                     url: "nib://open/DOCA")
        let b = FavouritesFile.Entry(id: "DOCB", title: "Board", kind: "whiteboard", folder: nil, modified: 2,
                                     url: "nib://open/DOCB")
        var saved = a
        saved.modified = 99
        XCTAssertTrue(FavouritesFile.sameListing([a, b], [saved, b]))
        XCTAssertFalse(FavouritesFile.sameListing(nil, [a, b]))
        XCTAssertFalse(FavouritesFile.sameListing([a, b], [b, a]))          // the order changed
        XCTAssertFalse(FavouritesFile.sameListing([a, b], [a]))             // one fewer
        var renamed = a
        renamed.title = "Dynamics"
        XCTAssertFalse(FavouritesFile.sameListing([a, b], [renamed, b]))
    }

    // MARK: Append Text to Note

    func testAppendPlanner() throws {
        let h = Harness(features: [])
        let notebook = try h.app.workspace.content(Fixtures.docID)
        let text = try h.app.workspace.content(Fixtures.textDocID)
        let study = try h.app.workspace.content(Fixtures.studySetID)
        let board = try h.app.workspace.content(Fixtures.whiteboardID)
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        let last = try XCTUnwrap(notebook.livePages.last)
        let size = last.size ?? PageSize.standard
        let x = AppendPlanner.leftMargin(size.width)

        XCTAssertEqual(try AppendPlanner.plan(text, lastPageItems: []), .paragraph(doc: Fixtures.textDocID))
        XCTAssertThrowsError(try AppendPlanner.plan(study, lastPageItems: [])) { error in
            XCTAssertEqual((error as? NibError)?.code, .unsupported)
        }
        // An empty last page: at the top margin.
        XCTAssertEqual(try AppendPlanner.plan(notebook, lastPageItems: []),
                       .textBox(doc: Fixtures.docID, page: last.id, at: Point(x, AppendPlanner.topMargin)))
        // Under the lowest thing on the page (comment pins do not count).
        let low = Item(id: "LOWTEXT00001", kind: .text,
                       text: TextBoxItem(frame: Frame(x: 100, y: 300, w: 200, h: 50), text: RichText(plain: "low")))
        XCTAssertEqual(try AppendPlanner.plan(notebook, lastPageItems: [low] + items.filter { $0.kind == .comment }),
                       .textBox(doc: Fixtures.docID, page: last.id, at: Point(x, 350 + AppendPlanner.gap)))
        // No room left: a new page.
        let full = Item(id: "FULLTEXT0001", kind: .text,
                        text: TextBoxItem(frame: Frame(x: 72, y: 72, w: 300, h: size.height - 100), text: RichText(plain: "full")))
        XCTAssertEqual(try AppendPlanner.plan(notebook, lastPageItems: [full]),
                       .textBoxOnNewPage(doc: Fixtures.docID, at: Point(x, AppendPlanner.topMargin)))
        // A whiteboard: under everything on the last board.
        let shapes = try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID)
        let bounds = try XCTUnwrap(AppendPlanner.union(shapes))
        XCTAssertEqual(try AppendPlanner.plan(board, lastPageItems: shapes),
                       .textBox(doc: Fixtures.whiteboardID, page: Fixtures.boardID,
                                at: Point(bounds.minX, bounds.maxY + AppendPlanner.gap * 2)))
    }

    func testAppendTextRunsOneUndoStepThroughCommands() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.textCreateBox, effect: .edit, result: ["ref": "item:FIXTUREDOC01/FIXTUREPG003/NEWTEXT00001"])
        stubs.stub(h.app, CommandIDs.blockInsert, effect: .edit, result: ["ref": "block:FIXTUREDOC02/NEWBLOCK0001"])
        stubs.stub(h.app, CommandIDs.pageAdd, effect: .edit)

        // Notebook: the fixture's last page (FIXTUREPG003) is empty, so the box goes at the top margin.
        let ref = try await FeatSystemIntegrationFeature.appendText("  Buy milk\nand eggs ", to: Fixtures.docID, app: h.app)
        XCTAssertEqual(ref, "item:FIXTUREDOC01/FIXTUREPG003/NEWTEXT00001")
        let box = try XCTUnwrap(stubs.params(CommandIDs.textCreateBox).first)
        XCTAssertEqual(box["page"], "page:FIXTUREDOC01/FIXTUREPG003")
        XCTAssertEqual(box["text"], "Buy milk\nand eggs")
        XCTAssertEqual(box["at"]?[1], .number(AppendPlanner.topMargin))

        // Text document: a paragraph at the end.
        let block = try await FeatSystemIntegrationFeature.appendText("Summary", to: Fixtures.textDocID, app: h.app)
        XCTAssertEqual(block, "block:FIXTUREDOC02/NEWBLOCK0001")
        XCTAssertEqual(stubs.params(CommandIDs.blockInsert).first, ["doc": "doc:FIXTUREDOC02", "kind": "paragraph", "text": "Summary"])
        XCTAssertTrue(stubs.calls.allSatisfy { $0.principal == .user })

        // A full last page: page.add then the box on the new page, in one undo group.
        let tall = Item(id: "TALLTEXT0001", kind: .text,
                        text: TextBoxItem(frame: Frame(x: 72, y: 72, w: 300, h: 740), text: RichText(plain: "tall")))
        try await h.insert([tall], page: Fixtures.pdfPage)
        let before = stubs.calls.count
        _ = try await FeatSystemIntegrationFeature.appendText("Next", to: Fixtures.docID, app: h.app)
        let steps = Array(stubs.calls.dropFirst(before))
        XCTAssertEqual(steps.map { $0.id }, [CommandIDs.pageAdd, CommandIDs.textCreateBox])
        XCTAssertEqual(Set(steps.map { $0.group }).count, 1)
        let newPage = try XCTUnwrap(steps[0].params["id"]?.stringValue)
        XCTAssertEqual(steps[0].params["position"], "end")
        XCTAssertEqual(steps[1].params["page"], .string("page:FIXTUREDOC01/" + newPage))
    }

    func testAppendTextRefusesLockedTrashedStudySetsAndEmptyText() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.textCreateBox, effect: .edit)
        h.app.services.lock = FakeLockService(locked: [Fixtures.whiteboardID])
        try h.library.trash(Fixtures.textDocID)
        let cases: [(String, DocumentID, NibError.Code)] = [
            ("x", Fixtures.whiteboardID, .locked), ("x", Fixtures.textDocID, .notFound),
            ("x", Fixtures.studySetID, .unsupported), ("   ", Fixtures.docID, .invalidParams),
            ("x", "NOSUCHDOC001", .notFound),
        ]
        for (text, doc, code) in cases {
            do {
                _ = try await FeatSystemIntegrationFeature.appendText(text, to: doc, app: h.app)
                XCTFail("expected \(code.rawValue) for \(doc)")
            } catch {
                XCTAssertEqual(NibError.wrap(error).code, code, "\(doc): \(error)")
            }
        }
        XCTAssertTrue(stubs.calls.isEmpty)
    }

    /// The store learns that a newer Nib saved a document only while loading its head: the check must come after the
    /// load, or Siri reports "Added" for text that is never saved.
    func testAppendTextRefusesADocumentThatTurnsOutReadOnlyWhenLoaded() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.textCreateBox, effect: .edit)
        stubs.stub(h.app, CommandIDs.blockInsert, effect: .edit)
        stubs.stub(h.app, CommandIDs.pageAdd, effect: .edit)
        let store = NewerFormatPersistence(base: h.persistence, newer: [Fixtures.textDocID, Fixtures.whiteboardID])
        h.app.workspace.persistence = store
        for doc in [Fixtures.textDocID, Fixtures.whiteboardID] {
            XCTAssertFalse(h.app.workspace.isLoaded(doc))
            XCTAssertFalse(h.app.isReadOnly(doc))        // unknown until the head is read
            do {
                _ = try await FeatSystemIntegrationFeature.appendText("x", to: doc, app: h.app)
                XCTFail("expected unsupported for \(doc)")
            } catch {
                XCTAssertEqual(NibError.wrap(error).code, .unsupported, "\(doc): \(error)")
            }
            // Loaded only for the intent: unloaded again.
            XCTAssertFalse(h.app.workspace.isLoaded(doc))
        }
        XCTAssertTrue(stubs.calls.isEmpty)
    }

    /// A background intent writes what it added before perform() returns, and unloads a document it loaded only for this.
    func testAppendTextFlushesAndUnloadsADocumentItLoaded() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.blockInsert, effect: .edit, result: ["ref": "block:FIXTUREDOC02/NEWBLOCK0001"])
        stubs.stub(h.app, CommandIDs.textCreateBox, effect: .edit, result: ["ref": "item:FIXTUREDOC04/FIXTUREBRD01/NEWTEXT00001"])
        let store = NewerFormatPersistence(base: h.persistence, newer: [])
        h.app.workspace.persistence = store

        XCTAssertFalse(h.app.workspace.isLoaded(Fixtures.textDocID))
        _ = try await FeatSystemIntegrationFeature.appendText("Summary", to: Fixtures.textDocID, app: h.app)
        XCTAssertTrue(store.flushed.contains(Fixtures.textDocID))
        XCTAssertFalse(h.app.workspace.isLoaded(Fixtures.textDocID))

        // Already open (in memory): flushed, and left loaded.
        _ = try h.app.workspace.content(Fixtures.whiteboardID)
        store.flushed.removeAll()
        _ = try await FeatSystemIntegrationFeature.appendText("Idea", to: Fixtures.whiteboardID, app: h.app)
        XCTAssertEqual(store.flushed.first, Fixtures.whiteboardID)
        XCTAssertTrue(h.app.workspace.isLoaded(Fixtures.whiteboardID))
        XCTAssertEqual(stubs.ids, [CommandIDs.blockInsert, CommandIDs.textCreateBox])
    }

    // MARK: Pairing sheet

    /// DESIGN.md §15.7: Light, Dark and AX3 renders of the new screen, complete and incomplete, and it still lays out
    /// at AX3 on a phone.
    func testPairingSheetRendersInEveryVariantAndFitsAtAX3() throws {
        let complete = BridgePairingSheet(pairing: try BridgePairing(host: "100.101.102.103", port: nil, token: "nib_4qVx9SECRET"),
                                          onDone: {})
        let outside = BridgePairingSheet(pairing: try BridgePairing(host: "attacker.example", port: nil, token: "nib_x"),
                                         onDone: {})
        let incomplete = BridgePairingSheet(pairing: nil, onDone: {})
        let size = CGSize(width: 375, height: 812)
        for (name, images) in [("complete", NibSnapshot.images(complete, size: size, scale: 1)),
                               ("outside", NibSnapshot.images(outside, size: size, scale: 1)),
                               ("incomplete", NibSnapshot.images(incomplete, size: size, scale: 1))] {
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases), name)
            for (variant, image) in images {
                XCTAssertGreaterThan(image.size.width * image.size.height, 0, "\(name) \(variant.rawValue)")
            }
        }
        for (name, fitting) in [("complete", NibSnapshot.fittingSize(complete, width: 375, variant: .largeText)),
                                ("incomplete", NibSnapshot.fittingSize(incomplete, width: 375, variant: .largeText))] {
            XCTAssertTrue(fitting.width.isFinite && fitting.height.isFinite, "\(name): \(fitting)")
            XCTAssertLessThan(fitting.height, CGFloat.greatestFiniteMagnitude / 2, name)
            XCTAssertGreaterThan(fitting.width, 0, name)
            XCTAssertGreaterThan(fitting.height, 0, name)
        }
    }

    // MARK: Library lists for Siri and Shortcuts

    func testLibrarySearchRanking() {
        func doc(_ id: String, _ title: String, _ modified: Double, favourite: Bool = false) -> LibraryNode {
            LibraryNode(id: NibID(id), kind: .document, title: title, path: title, documentKind: .notebook,
                        modified: modified, favorite: favourite)
        }
        let nodes = [doc("A", "Physics Notes", 1), doc("B", "Physics", 2), doc("C", "Applied physics", 9),
                     doc("D", "Astrophysics", 5), doc("E", "Chemistry", 7, favourite: true), doc("F", "Café Menu", 3),
                     LibraryNode(id: "G", kind: .folder, title: "Physics", path: "Physics")]
        XCTAssertEqual(LibrarySearch.rank(nodes, query: "physics", kind: .document, limit: 10).map { $0.id.raw },
                       ["B", "A", "C", "D"])
        XCTAssertEqual(LibrarySearch.rank(nodes, query: "CAFE", kind: .document, limit: 10).map { $0.id.raw }, ["F"])
        XCTAssertEqual(LibrarySearch.rank(nodes, query: nil, kind: .document, limit: 3).map { $0.id.raw }, ["E", "C", "D"])
        XCTAssertEqual(LibrarySearch.rank(nodes, query: "phys", kind: .folder, limit: 10).map { $0.id.raw }, ["G"])
    }

    func testIntentListsCarryTheFolderPath() throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let sub = try h.library.createFolder(title: "Mechanics", in: Fixtures.folderID, style: nil)
        try h.library.move(Fixtures.docID, to: sub)
        let found = FeatSystemIntegrationFeature.intentDocuments(matching: "fixture notebook", app: h.app)
        XCTAssertEqual(found.first?.node.id, Fixtures.docID)
        XCTAssertEqual(found.first?.location, "Fixtures › Mechanics")
        let folders = FeatSystemIntegrationFeature.intentFolders(matching: "mech", app: h.app)
        XCTAssertEqual(folders.map { $0.node.id }, [sub])
        XCTAssertEqual(FeatSystemIntegrationFeature.intentNodes([sub.raw, "bad id", "NOSUCHDOC001"], app: h.app).count, 1)
        XCTAssertEqual(FeatSystemIntegrationFeature.openLink(Fixtures.docID), "nib://open/FIXTUREDOC01")
        XCTAssertEqual(try DeepLinkParser.parse(FeatSystemIntegrationFeature.searchLink("x & y")), .search(query: "x & y"))
    }

    // MARK: Copy Link

    func testCopyLinkEntriesPutNibLinksOnTheClipboard() throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let sidebar = try XCTUnwrap(h.app.ui.menus.get(SystemIDs.copyLinkSidebarPage))
        let library = try XCTUnwrap(h.app.ui.menus.get(SystemIDs.copyLinkLibrary))
        let audio = try XCTUnwrap(h.app.ui.menus.get(SystemIDs.copyLinkAudio))
        let pageContext = MenuContext(app: h.app, doc: Fixtures.docID, page: Fixtures.page2)
        // Hidden until the clipboard feature (clipboard.copyText) is there.
        XCTAssertFalse(sidebar.isVisible(pageContext))
        CommandStubs().stub(h.app, CommandIDs.clipboardCopyText, effect: .read)
        XCTAssertTrue(sidebar.isVisible(pageContext))
        XCTAssertEqual(sidebar.command, CommandIDs.clipboardCopyText)
        XCTAssertEqual(sidebar.params(pageContext)["url"], "nib://open/FIXTUREDOC01/FIXTUREPG002")
        XCTAssertFalse(sidebar.isVisible(MenuContext(app: h.app, doc: Fixtures.docID, page: Fixtures.page2,
                                                     nodes: [Fixtures.page1, Fixtures.page2])))
        let docContext = MenuContext(app: h.app, nodes: [Fixtures.textDocID])
        XCTAssertTrue(library.isVisible(docContext))
        XCTAssertEqual(library.params(docContext)["url"], "nib://open/FIXTUREDOC02")
        XCTAssertFalse(library.isVisible(MenuContext(app: h.app, nodes: [Fixtures.folderID])))
        let clip = MenuContext(app: h.app, ref: "audio:FIXTUREDOC01/FIXTUREAUD01")
        XCTAssertEqual(audio.params(clip)["url"], "nib://audio/FIXTUREDOC01/FIXTUREAUD01")
    }

    // MARK: Helpers

    /// Waits for favourites.json writes and their main-actor completions.
    private func drain(_ publisher: QuickActionPublisher) async {
        publisher.writer.flush()
        for _ in 0..<20 { await Task.yield() }
    }
}

/// A store that, like NibStore, learns a document was saved by a newer Nib only while reading its head (`newer`), and
/// records flushes.
@MainActor
final class NewerFormatPersistence: DocumentPersistence {
    let base: InMemoryPersistence
    let newer: Set<DocumentID>
    private var readOnly: Set<DocumentID> = []
    var flushed: [DocumentID] = []

    init(base: InMemoryPersistence, newer: Set<DocumentID>) {
        self.base = base
        self.newer = newer
    }

    func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        let head = try base.loadHead(doc)
        if newer.contains(doc) { readOnly.insert(doc) }
        return head
    }

    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] { try base.loadItems(doc, page: page) }

    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        guard !readOnly.contains(doc) else { return }
        base.didChange(doc, head: head, pages: pages)
    }

    func flush(_ doc: DocumentID) { flushed.append(doc) }

    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL { try base.fileURL(doc, relativePath: relativePath) }

    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }

    func isReadOnly(_ doc: DocumentID) -> Bool { readOnly.contains(doc) }
}
