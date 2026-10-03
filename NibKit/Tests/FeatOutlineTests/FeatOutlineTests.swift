import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibDesign
import NibTesting
@testable import FeatOutline

/// Outline and bookmark commands against the fixture notebook (Harness), the tree logic behind drag and drop, the
/// merged PDF + custom rows and `outline.list`, the menus, the nav-bar item and key, and the panel model's live refresh.
@MainActor
final class FeatOutlineTests: XCTestCase {
    private let doc = Fixtures.docID

    private func harness() -> Harness { Harness(features: [FeatOutlineFeature.self]) }

    private func pageRef(_ id: PageID) -> JSONValue { .string(NodeRef.page(Fixtures.docID, id).description) }

    private func entryRef(_ id: NibID) -> JSONValue { .string(NodeRef.outline(Fixtures.docID, id).description) }

    private func tree(_ h: Harness) throws -> OutlineTree { OutlineTree(try h.app.workspace.content(doc).outline) }

    private func assertFails(_ command: String, _ params: JSONValue, code: NibError.Code, as principal: Principal = .user,
                             in h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await h.run(command, params, as: principal)
            XCTFail("\(command) \(params.jsonString()) should fail", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatOutlineFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersTabsSettingsAndShortcut() {
        let h = harness()
        for id in [OutlinePanels.outline, OutlinePanels.bookmarks] {
            let panel = h.app.ui.panels.get(id)
            XCTAssertEqual(panel?.placement, .sidebarTab)
            XCTAssertEqual(panel?.docKinds, [.notebook])
        }
        for key in [OutlineSettings.showThumbnails, OutlineSettings.showPDFOutline, OutlineSettings.showCustomOutline] {
            XCTAssertNotNil(h.app.settings.descriptor(key.name), key.name)
        }
        XCTAssertEqual(h.app.content.keyCommands.get("outline.bookmarkPage")?.command, CommandIDs.pageSetBookmarked)
        XCTAssertNotNil(h.app.commands.descriptor(CommandIDs.outlineList))
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.outlineList)?.effect, .read)
        // DESIGN.md §14.4: Pages · Outline · Bookmarks, ahead of Audio (300) and the other sidebar tabs.
        XCTAssertEqual(h.app.ui.panels.get(OutlinePanels.outline)?.order, 200)
        XCTAssertEqual(h.app.ui.panels.get(OutlinePanels.bookmarks)?.order, 210)
        XCTAssertEqual(h.app.ui.panels.get(OutlinePanels.outline)?.providesHeader, true,
                       "Outline owns its adaptive heading so chrome accessories cannot compress its title")

        // The nav-bar bookmark button, in notebooks only (the chrome drops its own button for page.setBookmarked).
        let nav = h.app.ui.toolbar.get(OutlinePanels.bookmarkNavItem)
        XCTAssertEqual(nav?.group, .navLeading)
        XCTAssertEqual(nav?.command, CommandIDs.pageSetBookmarked)
        XCTAssertEqual(nav?.docKinds, [.notebook])
        XCTAssertTrue(h.app.ui.toolbarItems(for: .notebook).contains { $0.id == OutlinePanels.bookmarkNavItem })
        XCTAssertFalse(h.app.ui.toolbarItems(for: .whiteboard).contains { $0.id == OutlinePanels.bookmarkNavItem })
    }

    // MARK: Nesting (max 3 levels)

    func testNestingStopsAtThreeLevels() async throws {
        let h = harness()
        let r = try await h.run("outline.add", ["page": pageRef(Fixtures.page2), "title": "Level 2",
                                                "parent": entryRef(Fixtures.outlineID), "id": "LEVEL2"])
        XCTAssertEqual(r["ref"]?.stringValue, "outline:FIXTUREDOC01/LEVEL2")
        try await h.run("outline.add", ["page": pageRef(Fixtures.pdfPage), "title": "Level 3", "parent": entryRef("LEVEL2"),
                                        "id": "LEVEL3"])
        XCTAssertEqual(try tree(h).depth(of: "LEVEL3"), 3)
        await assertFails("outline.add", ["page": pageRef(Fixtures.page1), "title": "Level 4", "parent": entryRef("LEVEL3")],
                          code: .invalidParams, in: h)
        await assertFails("outline.add", ["page": pageRef(Fixtures.page1), "title": "Level 4", "parent": entryRef("LEVEL3")],
                          code: .invalidParams, as: .ai("chat"), in: h)

        try await h.run("outline.add", ["page": pageRef(Fixtures.page1), "title": "Other", "id": "OTHER"])
        try await h.run("outline.add", ["page": pageRef(Fixtures.page1), "title": "Other child", "parent": entryRef("OTHER"),
                                        "id": "OTHERKID"])
        // LEVEL2 carries LEVEL3: under a level-2 entry it would reach level 4.
        await assertFails("outline.move", ["entry": entryRef("LEVEL2"), "parent": entryRef("OTHERKID")],
                          code: .invalidParams, in: h)
        await assertFails("outline.move", ["entry": entryRef(Fixtures.outlineID), "parent": entryRef("LEVEL3")],
                          code: .invalidParams, in: h)
        await assertFails("outline.add", ["page": pageRef(Fixtures.page1), "title": " "], code: .invalidParams, in: h)
        await assertFails("outline.add", ["page": pageRef(Fixtures.page1), "title": "Taken", "id": "OTHER"],
                          code: .invalidParams, in: h)

        try await h.run("outline.move", ["entry": entryRef("LEVEL2"), "parent": entryRef("OTHER"), "after": entryRef("OTHERKID")])
        let t = try tree(h)
        XCTAssertEqual(t.children(of: "OTHER"), ["OTHERKID", "LEVEL2"])
        XCTAssertEqual(t.children(of: "LEVEL2"), ["LEVEL3"])
        XCTAssertEqual(t.depth(of: "LEVEL3"), 3)
    }

    // MARK: Reorder, rename, delete, sort + undo

    func testMoveReordersAndUndoRestores() async throws {
        let h = harness()
        for (id, page) in [("ENTRYA", Fixtures.page1), ("ENTRYB", Fixtures.page2), ("ENTRYC", Fixtures.pdfPage)] {
            try await h.run("outline.add", ["page": pageRef(page), "title": .string(id), "id": .string(id)])
        }
        let original: [NibID] = [Fixtures.outlineID, "ENTRYA", "ENTRYB", "ENTRYC"]
        XCTAssertEqual(try tree(h).children(of: nil), original)

        let depth = h.undoDepth(doc)
        try await h.run("outline.move", ["entry": entryRef("ENTRYA"), "after": entryRef(Fixtures.outlineID)])
        XCTAssertEqual(h.undoDepth(doc), depth, "moving into its own place changes nothing")

        try await h.run("outline.move", ["entry": entryRef("ENTRYC")])
        try await h.run("outline.move", ["entry": entryRef(Fixtures.outlineID), "after": entryRef("ENTRYB")])
        XCTAssertEqual(try tree(h).children(of: nil), ["ENTRYC", "ENTRYA", "ENTRYB", Fixtures.outlineID])
        await assertFails("outline.move", ["entry": entryRef("ENTRYA"), "after": entryRef("ENTRYA")], code: .invalidParams, in: h)

        try await h.run("outline.rename", ["entry": entryRef("ENTRYB"), "title": "  Momentum  "])
        XCTAssertEqual(try tree(h).entries["ENTRYB"]?.title, "Momentum")

        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try tree(h).entries["ENTRYB"]?.title, "ENTRYB")
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try tree(h).children(of: nil), original)
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try tree(h).children(of: nil), ["ENTRYC", Fixtures.outlineID, "ENTRYA", "ENTRYB"])
    }

    func testDeleteTakesSubEntriesAndUndoBringsThemBack() async throws {
        let h = harness()
        try await h.run("outline.add", ["page": pageRef(Fixtures.page2), "title": "Child", "parent": entryRef(Fixtures.outlineID),
                                        "id": "CHILD"])
        try await h.run("outline.add", ["page": pageRef(Fixtures.pdfPage), "title": "Grandchild", "parent": entryRef("CHILD"),
                                        "id": "GRANDCHILD"])
        let r = try await h.run("outline.delete", ["entry": entryRef(Fixtures.outlineID)])
        XCTAssertEqual(r["removed"]?.arrayValue?.count, 3)
        XCTAssertTrue(try tree(h).isEmpty)
        XCTAssertEqual(try h.app.workspace.content(doc).livePages.count, 3, "pages stay")

        XCTAssertTrue(h.app.bus.undo(doc))
        let t = try tree(h)
        XCTAssertEqual(t.children(of: nil), [Fixtures.outlineID])
        XCTAssertEqual(t.children(of: Fixtures.outlineID), ["CHILD"])
        XCTAssertEqual(t.children(of: "CHILD"), ["GRANDCHILD"])
        await assertFails("outline.delete", ["entry": "outline:FIXTUREDOC01/NOSUCHENTRY"], code: .notFound, in: h)
    }

    func testSortByPageNumberSortsEveryLevel() async throws {
        let h = harness()
        // Top level: FIXTUREOUT01 (page 1), THIRD (page 3), FIRST (page 1); under THIRD: page 3 then page 2.
        try await h.run("outline.add", ["page": pageRef(Fixtures.pdfPage), "title": "Third", "id": "THIRD"])
        try await h.run("outline.add", ["page": pageRef(Fixtures.page1), "title": "First", "id": "FIRST"])
        try await h.run("outline.add", ["page": pageRef(Fixtures.pdfPage), "title": "3.b", "parent": entryRef("THIRD"),
                                        "id": "KIDTHREE"])
        try await h.run("outline.add", ["page": pageRef(Fixtures.page2), "title": "3.a", "parent": entryRef("THIRD"),
                                        "id": "KIDTWO"])
        try await h.run("outline.sortByPage", ["doc": "doc:FIXTUREDOC01"])
        var t = try tree(h)
        XCTAssertEqual(t.children(of: nil), [Fixtures.outlineID, "FIRST", "THIRD"])
        XCTAssertEqual(t.children(of: "THIRD"), ["KIDTWO", "KIDTHREE"])

        XCTAssertTrue(h.app.bus.undo(doc))
        t = try tree(h)
        XCTAssertEqual(t.children(of: nil), [Fixtures.outlineID, "THIRD", "FIRST"])
        XCTAssertEqual(t.children(of: "THIRD"), ["KIDTHREE", "KIDTWO"])
    }

    // MARK: Bookmarks

    func testBookmarksSetUndoAndToggleTheCurrentPage() async throws {
        let h = harness()
        let r = try await h.run("page.setBookmarked", ["pages": [pageRef(Fixtures.page1), pageRef(Fixtures.pdfPage),
                                                                  pageRef(Fixtures.page1)], "on": true])
        XCTAssertEqual(r["pages"]?.arrayValue?.compactMap { $0.stringValue },
                       ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG003"])
        func bookmarked() throws -> [PageID] { try h.app.workspace.content(doc).livePages.filter { $0.bookmarked }.map { $0.id } }
        XCTAssertEqual(try bookmarked(), [Fixtures.page1, Fixtures.pdfPage])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try bookmarked(), [])

        // ⌥⌘B: the shell passes the key window's params (contracts-v2 sessionParams): its current page, toggled.
        let shortcut = try XCTUnwrap(h.app.content.keyCommands.get("outline.bookmarkPage"))
        XCTAssertEqual(shortcut.resolvedParams(for: h.session),
                       ["pages": [pageRef(Fixtures.page1)], "on": true])
        try await h.run(shortcut.command, shortcut.resolvedParams(for: h.session))
        XCTAssertEqual(try bookmarked(), [Fixtures.page1])
        XCTAssertEqual(shortcut.resolvedParams(for: h.session)["on"], JSONValue.bool(false))
        try await h.run(shortcut.command, shortcut.resolvedParams(for: h.session))
        XCTAssertEqual(try bookmarked(), [])

        // The user principal may omit both (session defaults): the window's current page, toggled.
        try await h.run("page.setBookmarked", [:])
        XCTAssertEqual(try bookmarked(), [Fixtures.page1])
        try await h.run("page.setBookmarked", ["on": false])
        XCTAssertEqual(try bookmarked(), [])

        await assertFails("page.setBookmarked", ["pages": [pageRef(Fixtures.page1)]], code: .invalidParams, as: .ai("chat"), in: h)
        await assertFails("page.setBookmarked", ["pages": ["page:FIXTUREDOC01/NOSUCHPAGE"], "on": true], code: .notFound, in: h)
        await assertFails("page.setBookmarked", ["pages": ["doc:FIXTUREDOC01"], "on": true], code: .invalidParams, in: h)
        await assertFails("page.setBookmarked", ["pages": [], "on": true], code: .invalidParams, in: h)
    }

    func testNavButtonFollowsTheWindowsPage() async throws {
        let h = harness()
        let nav = try XCTUnwrap(h.app.ui.toolbar.get(OutlinePanels.bookmarkNavItem))
        func isOn() -> Bool { nav.isOn?(h.session) ?? false }
        XCTAssertFalse(isOn())
        XCTAssertEqual(nav.resolvedIcon(for: h.session), "bookmark")
        XCTAssertEqual(nav.resolvedTitle(for: h.session), "Bookmark Page")
        XCTAssertEqual(nav.isEnabled?(h.session), true)

        // A tap runs what the chrome resolves for this window.
        let command = try XCTUnwrap(nav.command)
        try await h.run(command, nav.resolvedParams(for: h.session))
        XCTAssertTrue(try h.app.workspace.content(doc).page(Fixtures.page1)?.bookmarked ?? false)
        XCTAssertTrue(isOn())
        XCTAssertEqual(nav.resolvedIcon(for: h.session), "bookmark.fill")
        XCTAssertEqual(nav.resolvedTitle(for: h.session), "Remove Bookmark")

        // Another page of the window: its own state.
        h.session.page = Fixtures.page2
        XCTAssertFalse(isOn())
        XCTAssertEqual(nav.resolvedParams(for: h.session), ["pages": [pageRef(Fixtures.page2)], "on": true])

        // Undo takes the bookmark back and the button with it.
        h.session.page = Fixtures.page1
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertFalse(isOn())

        // No page: greyed out, and nothing to toggle.
        h.session.page = nil
        XCTAssertEqual(nav.isEnabled?(h.session), false)
        XCTAssertEqual(nav.resolvedParams(for: h.session), [:])
    }

    func testBookmarkShortcutIsLiveOnlyInNotebooks() async throws {
        let h = harness()
        let shortcut = try XCTUnwrap(h.app.content.keyCommands.get("outline.bookmarkPage"))
        // contracts-v2.2: the shell offers the key only where it applies, so it never runs in other kinds.
        XCTAssertTrue(shortcut.isActive(in: KeyCommandContext(docKind: .notebook)))
        XCTAssertTrue(shortcut.isActive(in: KeyCommandContext(docKind: .notebook, isEditingText: true)))
        for kind in DocumentKind.allCases where kind != .notebook {
            XCTAssertFalse(shortcut.isActive(in: KeyCommandContext(docKind: kind)), kind.rawValue)
        }
        XCTAssertFalse(shortcut.isActive(in: KeyCommandContext(docKind: nil, hasTabs: true)), "never in the library")

        // A whiteboard board is a page record, but no bookmark UI shows it: the session default leaves it alone.
        let depth = h.undoDepths()
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        XCTAssertEqual(shortcut.resolvedParams(for: h.session), [:])
        await assertFails(shortcut.command, shortcut.resolvedParams(for: h.session), code: .invalidParams, in: h)
        XCTAssertFalse(try h.app.workspace.content(Fixtures.whiteboardID).page(Fixtures.boardID)?.bookmarked ?? false)

        // A text document has no pages; no document at all.
        h.session.document = Fixtures.textDocID
        h.session.page = nil
        await assertFails(shortcut.command, [:], code: .invalidParams, in: h)
        h.session.document = nil
        await assertFails(shortcut.command, [:], code: .invalidParams, in: h)
        XCTAssertEqual(h.undoDepths(), depth, "nothing was recorded")
    }

    // MARK: Tree logic (drag and drop, VoiceOver moves)

    func testTreeBreaksCyclesAndKeepsOrphansReachable() {
        let tree = OutlineTree([
            OutlineEntry(id: "A", title: "A", page: nil, parent: "B", order: "V"),
            OutlineEntry(id: "B", title: "B", page: nil, parent: "A", order: "k"),
            OutlineEntry(id: "O", title: "Orphan", page: nil, parent: "GONE", order: "t")
        ])
        let rows = tree.flatten { _ in false }
        XCTAssertEqual(rows.map { $0.id }, ["B", "A", "O"])
        XCTAssertEqual(rows.map { $0.depth }, [1, 2, 1])
        XCTAssertNil(tree.parent(of: "O"))
        XCTAssertEqual(tree.flatten { $0 == "B" }.map { $0.id }, ["B", "O"], "collapsed rows hide their children")
    }

    func testDropTargetsAndKeyboardMoves() {
        let tree = OutlineTree([
            OutlineEntry(id: "A", title: "A", page: nil, order: "V"),
            OutlineEntry(id: "A1", title: "A1", page: nil, parent: "A", order: "V"),
            OutlineEntry(id: "B", title: "B", page: nil, order: "k"),
            OutlineEntry(id: "C", title: "C", page: nil, order: "t")
        ])
        let rows = tree.flatten { _ in false }
        XCTAssertEqual(rows.map { $0.id }, ["A", "A1", "B", "C"])
        XCTAssertEqual(tree.drop("C", at: 1, in: rows), OutlinePlacement(parent: "A", after: nil), "below an open row: first child")
        XCTAssertNil(tree.drop("C", at: 3, in: rows), "its own slot")
        XCTAssertNil(tree.drop("C", at: 4, in: rows), "its own slot")
        XCTAssertEqual(tree.drop("B", at: 0, in: rows), OutlinePlacement(parent: nil, after: nil))
        XCTAssertEqual(tree.drop("A1", at: 4, in: rows), OutlinePlacement(parent: nil, after: "C"))
        XCTAssertEqual(tree.drop("C", at: 2, in: rows), OutlinePlacement(parent: "A", after: "A1"), "the row above's level")
        // Between rows the drag's level picks among the levels open there.
        XCTAssertEqual(tree.drop("C", at: 2, in: rows, depth: 1), OutlinePlacement(parent: nil, after: "A"),
                       "dragged left below an expanded entry's last child: back to the top level")
        XCTAssertEqual(tree.drop("C", at: 2, in: rows, depth: 3), OutlinePlacement(parent: "A1", after: nil),
                       "dragged right: nested under the leaf above")
        XCTAssertEqual(tree.drop("A1", at: 2, in: rows, depth: 1), OutlinePlacement(parent: nil, after: "A"),
                       "out a level from its own slot")
        XCTAssertNil(tree.drop("A1", at: 2, in: rows, depth: 2), "its own slot and level")
        XCTAssertNil(tree.drop("A1", at: 1, in: rows, depth: 2), "its own slot and level")
        XCTAssertEqual(tree.drop("C", at: 4, in: rows, depth: 2), OutlinePlacement(parent: "B", after: nil),
                       "its own slot, dragged right: nested under the row above")
        XCTAssertEqual(tree.drop("B", at: 1, in: rows, depth: 1), OutlinePlacement(parent: "A", after: nil),
                       "above an expanded entry's first child only the first-child slot is open")
        XCTAssertEqual(tree.drop("C", into: "A"), OutlinePlacement(parent: "A", after: "A1"))
        XCTAssertNil(tree.drop("A", into: "A1"), "never inside itself")
        XCTAssertEqual(tree.indent("B"), OutlinePlacement(parent: "A", after: "A1"))
        XCTAssertEqual(tree.outdent("A1"), OutlinePlacement(parent: nil, after: "A"))
        XCTAssertEqual(tree.moveUp("C"), OutlinePlacement(parent: nil, after: "A"))
        XCTAssertNil(tree.moveDown("C"))

        let deep = OutlineTree([
            OutlineEntry(id: "X", title: "X", page: nil, order: "V"),
            OutlineEntry(id: "Y", title: "Y", page: nil, parent: "X", order: "V"),
            OutlineEntry(id: "Z", title: "Z", page: nil, order: "k"),
            OutlineEntry(id: "Z1", title: "Z1", page: nil, parent: "Z", order: "V"),
            OutlineEntry(id: "Z2", title: "Z2", page: nil, parent: "Z1", order: "V")
        ])
        XCTAssertNil(deep.drop("Z", into: "Y"), "three levels under a level-2 entry is too deep")
        XCTAssertNil(deep.indent("Z"), "Z's subtree is already three levels tall")
        let deepRows = deep.flatten { _ in false }
        XCTAssertEqual(deepRows.map { $0.id }, ["X", "Y", "Z", "Z1", "Z2"])
        XCTAssertNil(deep.drop("Z1", at: 2, in: deepRows, depth: 3), "Z1 carries Z2: under Y it would reach level 4")
    }

    func testRawParentChainsOfAnyDepthStayShallow() {
        // node.insert / node.set or a merge can chain parents far past 3 levels; building and walking the tree
        // must not recurse once per level.
        var chain = [OutlineEntry(id: "E0", title: "0", page: nil, order: "V")]
        for i in 1..<5000 {
            chain.append(OutlineEntry(id: NibID("E\(i)"), title: "\(i)", page: nil, parent: NibID("E\(i - 1)"), order: "V"))
        }
        let tree = OutlineTree(chain)
        XCTAssertEqual(tree.depth(of: "E15"), OutlineTree.depthLimit)
        XCTAssertEqual(tree.depth(of: "E16"), 1, "past the limit an entry starts over at the top level")
        XCTAssertNil(tree.parent(of: "E16"))
        XCTAssertEqual(tree.depth(of: "E17"), 2)
        XCTAssertEqual(tree.height(of: "E0"), OutlineTree.depthLimit)
        let rows = tree.flatten { _ in false }
        XCTAssertEqual(rows.count, 5000, "every entry stays reachable")
        XCTAssertEqual(rows.map { $0.depth }.max(), OutlineTree.depthLimit)
        XCTAssertEqual(tree.descendants(of: "E0").count, OutlineTree.depthLimit - 1)

        // A cycle closed by a long chain is broken once, in linear time.
        var loop = chain
        loop[0].parent = "E4999"
        let looped = OutlineTree(loop)
        XCTAssertEqual(looped.flatten { _ in false }.count, 5000)
    }

    func testOrderKeysRekeyWhenNeighboursCannotBracket() throws {
        let clean = OutlineOrder.insert(at: 1, among: [(id: "A", order: "V"), (id: "B", order: "k")])
        XCTAssertTrue(clean.rekeyed.isEmpty)
        XCTAssertTrue("V" < clean.key && clean.key < "k")

        let clash = OutlineOrder.insert(at: 1, among: [(id: "A", order: "V"), (id: "B", order: "V"), (id: "C", order: "")])
        var keys: [String: String] = ["A": "V", "B": "V", "C": ""]
        for r in clash.rekeyed { keys[r.id.raw] = r.order }
        let a = try XCTUnwrap(keys["A"]), b = try XCTUnwrap(keys["B"]), c = try XCTUnwrap(keys["C"])
        XCTAssertTrue(a < clash.key && clash.key < b && b < c, "\(a) \(clash.key) \(b) \(c)")
    }

    // MARK: Rows: PDF outline merged with yours

    func testRowsMergeThePDFOutlineWithYoursAndHonourToggles() {
        let (content, _) = Fixtures.sampleContent()
        let tree = OutlineTree(content.outline)
        let pdf = [PDFOutlineNode(title: "Chapter 1", pageIndex: 0, children: [PDFOutlineNode(title: "1.1", pageIndex: 0)]),
                   PDFOutlineNode(title: "Appendix", pageIndex: 7)]
        func build(pdf showPDF: Bool = true, custom: Bool = true, collapsed: Set<String> = []) -> [OutlineSection] {
            OutlineRowBuilder.sections(content: content, tree: tree, pdfOutlines: [Fixtures.pdfAsset.name: pdf],
                                       showPDF: showPDF, showCustom: custom, collapsed: collapsed,
                                       currentPage: Fixtures.pdfPage)
        }
        let sections = build()
        XCTAssertEqual(sections.map { $0.kind }, [.pdf, .custom])
        let pdfRows = sections[0].rows
        XCTAssertEqual(pdfRows.map { $0.title }, ["Chapter 1", "1.1", "Appendix"])
        XCTAssertEqual(pdfRows[0].page, Fixtures.pdfPage)
        XCTAssertEqual(pdfRows[0].pageNumber, 3, "the PDF page is the notebook's third page")
        XCTAssertTrue(pdfRows[0].isCurrent)
        XCTAssertEqual(pdfRows[1].depth, 2)
        XCTAssertNil(pdfRows[2].page, "a PDF page the notebook does not show")
        XCTAssertEqual(sections[1].rows.map { $0.entry }, [Fixtures.outlineID])
        XCTAssertEqual(sections[1].rows[0].pageNumber, 1)
        XCTAssertEqual(sections[1].rows[0].kind, .custom)

        XCTAssertEqual(build(collapsed: [pdfRows[0].id])[0].rows.map { $0.title }, ["Chapter 1", "Appendix"])
        XCTAssertEqual(build(pdf: false).map { $0.kind }, [.custom])
        XCTAssertEqual(build(custom: false).map { $0.kind }, [.pdf])
    }

    // MARK: outline.list

    func testOutlineListMergesThePDFOutlineWithYoursInDisplayOrder() async throws {
        let h = harness()
        let pdf = FakePDFService()
        pdf.outlines[Fixtures.pdfAsset.name] = [
            PDFOutlineNode(title: "Chapter 1", pageIndex: 0, children: [PDFOutlineNode(title: "1.1", pageIndex: 0)]),
            PDFOutlineNode(title: "Appendix", pageIndex: 7)
        ]
        h.app.services.pdf = pdf
        try await h.run("outline.add", ["page": pageRef(Fixtures.page2), "title": "Momentum", "parent": entryRef(Fixtures.outlineID),
                                        "id": "KID"])
        let page3: JSONValue = "page:FIXTUREDOC01/FIXTUREPG003"
        let expected: [JSONValue] = [
            ["title": "Chapter 1", "page": page3, "level": 1, "source": "pdf"],
            ["title": "1.1", "page": page3, "level": 2, "source": "pdf"],
            ["title": "Appendix", "level": 1, "source": "pdf"],
            ["title": "Fixture section", "page": pageRef(Fixtures.page1), "level": 1, "source": "custom",
             "ref": entryRef(Fixtures.outlineID)],
            ["title": "Momentum", "page": pageRef(Fixtures.page2), "level": 2, "source": "custom", "ref": entryRef("KID")]
        ]
        for principal in [Principal.user, .ai("chat")] {
            let all = try await h.run("outline.list", ["doc": "doc:FIXTUREDOC01"], as: principal)
            XCTAssertEqual(all["entries"]?.arrayValue, expected)
            XCTAssertNil(all["cursor"])
            XCTAssertNil(all["truncated"])
        }
        let custom = try await h.run("outline.list", ["doc": "doc:FIXTUREDOC01", "source": "custom"])
        XCTAssertEqual(custom["entries"]?.arrayValue, Array(expected[3...]))
        let pdfOnly = try await h.run("outline.list", ["doc": "doc:FIXTUREDOC01", "source": "pdf"])
        XCTAssertEqual(pdfOnly["entries"]?.arrayValue, Array(expected[..<3]))

        // The view options of the Outline tab do not filter it; the user may omit doc (the window's document).
        try await h.run("settings.set", ["name": .string(OutlineSettings.showPDFOutline.name), "value": false])
        let fromSession = try await h.run("outline.list", [:])
        XCTAssertEqual(fromSession["entries"]?.arrayValue, expected)

        // A trashed page is no longer a destination; the entry stays.
        var trashed = try XCTUnwrap(h.app.workspace.content(doc).page(Fixtures.page2))
        trashed.deleted = true
        trashed.rev = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000, counter: 0, device: 99)
        _ = h.app.bus.applyRemote(DocumentPatch(doc: doc, pages: [trashed]), origin: "test")
        let afterTrash = try await h.run("outline.list", ["doc": "doc:FIXTUREDOC01", "source": "custom"])
        XCTAssertEqual(afterTrash["entries"]?.arrayValue?.last,
                       ["title": "Momentum", "level": 2, "source": "custom", "ref": entryRef("KID")])

        await assertFails("outline.list", ["doc": "doc:FIXTUREDOC01", "source": "bookmarks"], code: .invalidParams,
                          as: .ai("chat"), in: h)
        await assertFails("outline.list", ["doc": "doc:FIXTUREDOC01", "source": "bookmarks"], code: .invalidParams, in: h)
        await assertFails("outline.list", ["doc": "doc:FIXTUREDOC01", "cursor": "x"], code: .invalidParams, in: h)
        await assertFails("outline.list", [:], code: .invalidParams, as: .ai("chat"), in: h)
        await assertFails("outline.list", ["doc": "page:FIXTUREDOC01/FIXTUREPG001"], code: .invalidParams, in: h)
    }

    func testOutlineListPagesLongOutlinesWithACursor() async throws {
        let h = harness()
        // 260 entries of about 120 bytes each: more than one 20 KB result.
        var pdfNodes: [PDFOutlineNode] = []
        for i in 0..<260 {
            pdfNodes.append(PDFOutlineNode(title: "Section \(i) " + String(repeating: "x", count: 60), pageIndex: 0))
        }
        let pdf = FakePDFService()
        pdf.outlines[Fixtures.pdfAsset.name] = pdfNodes
        h.app.services.pdf = pdf

        var titles: [String] = []
        var cursor: JSONValue?
        var pages = 0
        repeat {
            var params: [String: JSONValue] = ["doc": "doc:FIXTUREDOC01"]
            if let c = cursor { params["cursor"] = c }
            let r = try await h.run("outline.list", .object(params), as: .ai("chat"))
            XCTAssertLessThanOrEqual(r.jsonString().utf8.count, NibLimits.aiToolResultBytes)
            titles += r["entries"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
            cursor = r["cursor"]
            XCTAssertEqual(r["truncated"]?.boolValue, cursor == nil ? nil : true)
            pages += 1
        } while cursor != nil && pages < 20
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(titles, pdfNodes.map { $0.title } + ["Fixture section"], "every entry once, in order")

        // A page always moves on, even when one entry alone is over the budget.
        let big = OutlineList.Entry(title: String(repeating: "y", count: 300), page: nil, level: 1, source: "pdf", ref: nil)
        let first = OutlineList.page([big, big], from: 0, limit: 200)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.cursor, "1")
        let last = OutlineList.page([big, big], from: 1, limit: 200)
        XCTAssertEqual(last.entries.count, 1)
        XCTAssertNil(last.cursor)
        XCTAssertEqual(OutlineList.page([big], from: 5).entries, [], "a cursor past the end reads nothing")
    }

    // MARK: Menus

    func testMenusRunCommandsForTheirContext() async throws {
        let h = harness()
        let more = MenuContext(app: h.app, session: h.session, doc: doc, page: Fixtures.page2)
        let add = try XCTUnwrap(h.app.ui.menuItems(.documentMore, more).first { $0.id == "outline.more.addPage" })
        let r = try await h.run(add.command, add.params(more))
        guard case let .outline(_, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no entry ref") }
        XCTAssertEqual(try tree(h).entries[id]?.title, "Page 2")

        // sidebarPage menus: `page` is the thumbnail, `nodes` the selection (which may hold other pages).
        let thumbnail = MenuContext(app: h.app, session: h.session, doc: doc, page: Fixtures.page2,
                                    nodes: [Fixtures.page1, Fixtures.page2])
        func sidebarIDs() -> [String] { h.app.ui.menuItems(.sidebarPage, thumbnail).map { $0.id } }
        XCTAssertTrue(sidebarIDs().contains("outline.page.bookmark"))
        XCTAssertFalse(sidebarIDs().contains("outline.page.unbookmark"))
        let bookmark = try XCTUnwrap(h.app.ui.menuItems(.sidebarPage, thumbnail).first { $0.id == "outline.page.bookmark" })
        XCTAssertEqual(bookmark.params(thumbnail), ["pages": [pageRef(Fixtures.page2)], "on": true])
        try await h.run(bookmark.command, bookmark.params(thumbnail))
        XCTAssertTrue(sidebarIDs().contains("outline.page.unbookmark"))
        XCTAssertFalse(sidebarIDs().contains("outline.page.bookmark"))
        let selectionOnly = MenuContext(app: h.app, session: h.session, doc: doc, nodes: [Fixtures.page2])
        XCTAssertFalse(h.app.ui.menuItems(.sidebarPage, selectionOnly).contains { $0.id.hasPrefix("outline.page.") },
                       "no thumbnail page, no thumbnail entries")

        let entry = MenuContext(app: h.app, session: h.session, doc: doc, ref: NodeRef.outline(doc, id).description)
        let entryItems = h.app.ui.menuItems(.outlineEntry, entry).map { $0.id }
        XCTAssertTrue(entryItems.contains("outline.entry.delete"))
        XCTAssertFalse(entryItems.contains("outline.entry.outdent"), "already at the top level")
        let indent = try XCTUnwrap(h.app.ui.menuItems(.outlineEntry, entry).first { $0.id == "outline.entry.indent" })
        try await h.run(indent.command, indent.params(entry))
        XCTAssertEqual(try tree(h).parent(of: id), Fixtures.outlineID)
    }

    // MARK: Panel layout

    func testOutlineCellEmphasizesOnlyTheCurrentPageAndClearsEmphasisOnReuse() throws {
        func titleLabel(in view: UIView, title: String) -> UILabel? {
            if let label = view as? UILabel, label.text == title { return label }
            return view.subviews.lazy.compactMap { titleLabel(in: $0, title: title) }.first
        }

        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let cell = OutlineCell(style: .default, reuseIdentifier: OutlineCell.reuseID)
            cell.overrideUserInterfaceStyle = appearance
            for kind in [OutlineSectionKind.custom, .pdf] {
                var row = OutlineRow(id: "weight-regression", kind: kind, entry: nil,
                                     title: "Outline title", depth: 1, page: Fixtures.pdfPage,
                                     pageNumber: 3, hasChildren: false, isExpanded: false, isCurrent: false)
                // Reconfigure the same cell to catch selection emphasis leaking into a reused row.
                for isCurrent in [false, true, false] {
                    row.isCurrent = isCurrent
                    cell.configure(row, showsThumbnail: false, image: nil, aspect: 1)
                    let label = try XCTUnwrap(titleLabel(in: cell.contentView, title: row.title))
                    XCTAssertEqual(label.font, isCurrent ? NibUIFont.bodyEmphasis : NibUIFont.body,
                                   "Only the current page is emphasized, for both custom and PDF entries")
                    XCTAssertTrue(label.adjustsFontForContentSizeCategory)
                    XCTAssertEqual(cell.backgroundView != nil, isCurrent,
                                   "Title emphasis follows the row's selection highlight")
                }
            }
        }
    }

    func testNavigatorHeadingKeepsItsTitleReadableAndReflowsAccessories() {
        let h = harness()
        let model = OutlinePanelModel(app: h.app, session: h.session)
        for title in ["Outline", "Gliederung"] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let text = UIHostingController(rootView: Text(title).font(NibFont.headline)
                    .fixedSize().environment(\.dynamicTypeSize, typeSize))
                let idealTitle = text.sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
                for width in [NibMetrics.navigatorWidth, NibMetrics.panelWidthAccessibility] {
                    let header = UIHostingController(rootView: OutlinePanelHeader(model: model, dismiss: {}, title: title)
                        .environment(\.dynamicTypeSize, typeSize))
                    let fitted = header.sizeThatFits(in: CGSize(width: width, height: 1_000))
                    let fitsInline = idealTitle.width + NibSpacing.s + 2 * NibMetrics.hitTarget
                        + 2 * NibSpacing.m <= width
                    let expectedHeight = fitsInline
                        ? max(idealTitle.height, NibMetrics.hitTarget) + 2 * NibSpacing.s
                        : idealTitle.height + NibSpacing.xs + NibMetrics.hitTarget + 2 * NibSpacing.s
                    XCTAssertLessThanOrEqual(fitted.width, width + 1, "\(title), \(typeSize)")
                    XCTAssertEqual(fitted.height, expectedHeight, accuracy: 1,
                                   "Keep the full heading on one line; put accessories below when needed")
                }
            }
        }
    }

    /// Capture both Add entry placements at the actual navigator width for the design review, including AX3.
    func testOutlinePanelNarrowLayoutReviewImages() async throws {
        let h = harness()
        for empty in [false, true] {
            if empty { try await h.run("outline.delete", ["entry": entryRef(Fixtures.outlineID)]) }
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                for scheme in [ColorScheme.light, .dark] {
                    let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
                    let host = UIHostingController(rootView: OutlinePanel(context: context)
                        .environment(\.dynamicTypeSize, typeSize)
                        .environment(\.colorScheme, scheme)
                        .background(NibColor.backgroundSecondary)
                        .ignoresSafeArea())
                    let size = CGSize(width: NibMetrics.navigatorWidth, height: 640)
                    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                    window.rootViewController = host
                    window.isHidden = false
                    defer { window.isHidden = true; window.rootViewController = nil }
                    host.view.frame = window.bounds
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(size: size).image { renderer in
                        host.view.layer.render(in: renderer.cgContext)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Outline-\(empty ? "empty" : "entries")-\(typeSize)-\(scheme)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTAssertEqual(host.view.bounds.width, NibMetrics.navigatorWidth)
                }
            }
        }
    }

    // MARK: Panel model

    func testHiddenOutlineActionRestoresBothSourcesWithoutChangingTheDocument() async throws {
        let h = harness()
        let pdf = FakePDFService()
        pdf.outlines[Fixtures.pdfAsset.name] = [PDFOutlineNode(title: "Chapter 1", pageIndex: 0)]
        h.app.services.pdf = pdf
        let model = OutlinePanelModel(app: h.app, session: h.session)
        try await waitUntil { model.sections.map { $0.kind } == [.pdf, .custom] }
        let originalSections = model.sections
        let originalOutline = try h.app.workspace.content(doc).outline
        try await h.run("settings.set", ["name": .string(OutlineSettings.showThumbnails.name), "value": true])
        for key in [OutlineSettings.showPDFOutline, OutlineSettings.showCustomOutline] {
            try await h.run("settings.set", ["name": .string(key.name), "value": false])
        }
        try await waitUntil { !model.showsPDF && !model.showsCustom && model.showsThumbnails }

        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertEqual(model.emptyTitle, "Outline entries hidden")
        XCTAssertEqual(model.emptyMessage, "PDF Outline and Custom Outline are both turned off in the options.")
        let action = try XCTUnwrap(model.emptyAction)
        XCTAssertEqual(action.title, "Show outline")
        action.handler()

        try await waitUntil { model.sections == originalSections }
        XCTAssertTrue(h.app.settings.get(OutlineSettings.showPDFOutline))
        XCTAssertTrue(h.app.settings.get(OutlineSettings.showCustomOutline))
        XCTAssertTrue(model.showsThumbnails)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(try h.app.workspace.content(doc).outline, originalOutline)
    }

    func testHiddenOutlineCanBeShownWithoutACurrentPage() async throws {
        let h = harness()
        h.session.page = nil
        for key in [OutlineSettings.showPDFOutline, OutlineSettings.showCustomOutline] {
            try await h.run("settings.set", ["name": .string(key.name), "value": false])
        }
        let model = OutlinePanelModel(app: h.app, session: h.session)
        XCTAssertFalse(model.canAdd)
        XCTAssertEqual(model.emptyTitle, "Outline entries hidden")
        let action = try XCTUnwrap(model.emptyAction)
        XCTAssertEqual(action.title, "Show outline")
        action.handler()
        try await waitUntil { model.showsPDF && model.showsCustom && !model.sections.isEmpty }
        XCTAssertNil(model.prompt)
        XCTAssertNil(h.session.page)
    }

    func testEmptyOutlineKeepsAddEntryWhenASourceIsVisible() async throws {
        let h = harness()
        try await h.run("outline.delete", ["entry": entryRef(Fixtures.outlineID)])
        let model = OutlinePanelModel(app: h.app, session: h.session)
        for (pdf, custom) in [(true, true), (true, false), (false, true)] {
            try await h.run("settings.set", ["name": .string(OutlineSettings.showPDFOutline.name), "value": .bool(pdf)])
            try await h.run("settings.set", ["name": .string(OutlineSettings.showCustomOutline.name), "value": .bool(custom)])
            try await waitUntil { model.showsPDF == pdf && model.showsCustom == custom }
            XCTAssertTrue(model.sections.isEmpty)
            XCTAssertEqual(model.emptyTitle, "No outline yet")
            XCTAssertEqual(model.emptyMessage, "Entries take you straight back to a page.")
            let action = try XCTUnwrap(model.emptyAction)
            XCTAssertEqual(action.title, "Add entry")
            action.handler()
            XCTAssertEqual(model.prompt, .add(Fixtures.page1))
            model.cancelPrompt()
        }
        h.session.page = nil
        try await waitUntil { !model.canAdd }
        XCTAssertNil(model.emptyAction)
        XCTAssertNil(model.emptyMessage)
    }

    func testPanelModelLoadsThePDFOutlineAndFollowsCommits() async throws {
        let h = harness()
        let pdf = FakePDFService()
        pdf.outlines[Fixtures.pdfAsset.name] = [PDFOutlineNode(title: "Chapter 1", pageIndex: 0)]
        h.app.services.pdf = pdf
        let model = OutlinePanelModel(app: h.app, session: h.session)
        XCTAssertTrue(model.canAdd)
        try await waitUntil { model.sections.map { $0.kind } == [.pdf, .custom] }
        XCTAssertEqual(model.sections[0].rows.first?.title, "Chapter 1")

        model.beginAdd()
        XCTAssertEqual(model.prompt, .add(Fixtures.page1))
        XCTAssertEqual(model.draft, "Page 1")
        model.draft = "Introduction"
        model.commitPrompt()
        XCTAssertNil(model.prompt)
        try await waitUntil { model.sections.last?.rows.count == 2 }
        XCTAssertEqual(model.sections.last?.rows.last?.title, "Introduction")

        try await h.run("settings.set", ["name": .string(OutlineSettings.showPDFOutline.name), "value": false])
        try await waitUntil { model.sections.map { $0.kind } == [.custom] }
    }

    func testBookmarkControlHitTargetCoversPreviewTitleAndWhitespace() throws {
        let control = BookmarkRowControl()
        var activations = 0
        var row = BookmarkRow(page: Fixtures.page1, number: 1, title: nil, isCurrent: false, aspect: 595 / 842)
        control.configure(row: row, image: nil) { activations += 1 }
        for width in [NibMetrics.navigatorWidth, NibMetrics.panelWidthAccessibility] {
            let size = control.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, NibMetrics.hitTarget)
            control.frame = CGRect(origin: .zero, size: size)
            control.layoutIfNeeded()
            // The failing tap was at the row's centre, beyond the short "Page 1" text.
            for x in [NibSpacing.m, width / 2, width - NibSpacing.m] {
                let hit = try XCTUnwrap(control.hitTest(CGPoint(x: x, y: size.height / 2), with: nil))
                XCTAssertTrue(hit === control, "The decorative hosted label must not consume selection")
            }
        }
        control.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(control.accessibilityLabel, "Page 1")
        XCTAssertTrue(control.accessibilityTraits.contains(.button))
        XCTAssertFalse(control.accessibilityTraits.contains(.selected))

        // Reconfiguration (navigation or a new thumbnail) retains one action and updates its destination.
        row.isCurrent = true
        row.title = "Introduction"
        var replacementActivations = 0
        control.configure(row: row, image: nil) { replacementActivations += 1 }
        XCTAssertEqual(control.accessibilityLabel, "Page 1, Introduction")
        XCTAssertEqual(control.accessibilityValue, "Current page")
        XCTAssertTrue(control.accessibilityTraits.contains(.selected))
        XCTAssertTrue(control.accessibilityActivate())
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(replacementActivations, 1)
        control.isEnabled = false
        XCTAssertFalse(control.accessibilityActivate())
        XCTAssertEqual(replacementActivations, 1)
    }

    func testBookmarkActivationNavigatesInvokingSessionThenCanUnbookmark() async throws {
        let h = harness()
        try await h.run("page.setBookmarked", ["pages": [pageRef(Fixtures.page1)], "on": true])
        h.session.page = Fixtures.page2
        let model = BookmarksPanelModel(app: h.app, session: h.session)
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertFalse(row.isCurrent)
        let other = EditorSession()
        other.document = doc
        other.page = Fixtures.pdfPage
        h.app.services.sessions.add(other)
        var calls = 0
        // F006 owns navigation; verify the actual command boundary without importing another feature.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewGoToPage, title: "Go to Page",
            summary: "Test navigation receiver.", effect: .session)) { params, context in
            calls += 1
            XCTAssertTrue(context.session === h.session)
            XCTAssertEqual(params["page"], self.pageRef(Fixtures.page1))
            context.session?.page = Fixtures.page1
            return .null
        }
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        let host = UIHostingController(rootView: BookmarksPanel(context: context)
            .environment(\.horizontalSizeClass, .regular))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: NibMetrics.navigatorWidth, height: 640))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        func controls(in view: UIView) -> [BookmarkRowControl] {
            (view as? BookmarkRowControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        try await waitUntil {
            host.view.layoutIfNeeded()
            return controls(in: host.view).first?.bounds.width ?? 0 > 0
        }
        let control = try XCTUnwrap(controls(in: host.view).first)
        XCTAssertEqual(control.accessibilityLabel, "Page 1")
        XCTAssertGreaterThan(control.bounds.width, NibMetrics.navigatorWidth / 2)
        let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
        XCTAssertTrue(window.hitTest(point, with: nil) === control,
                      "The actual List row must deliver its centre tap to the navigation control")
        control.sendActions(for: .primaryActionTriggered)
        try await waitUntil { model.rows.first?.isCurrent == true }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(other.page, Fixtures.pdfPage)
        model.remove(try XCTUnwrap(model.rows.first))
        try await waitUntil { model.rows.isEmpty }
        XCTAssertFalse(try XCTUnwrap(h.app.workspace.content(doc).page(Fixtures.page1)).bookmarked)
    }

    func testBookmarksPanelFollowsBookmarksTrashAndTheCurrentPage() async throws {
        let h = harness()
        let model = BookmarksPanelModel(app: h.app, session: h.session)
        XCTAssertEqual(model.rows, [])
        try await h.run("page.setBookmarked", ["pages": [pageRef(Fixtures.pdfPage)], "on": true])
        try await h.run("page.setBookmarked", ["pages": [pageRef(Fixtures.page1)], "on": true])
        try await waitUntil { model.rows.map { $0.page } == [Fixtures.page1, Fixtures.pdfPage] }
        XCTAssertEqual(model.rows.map { $0.number }, [1, 3], "page order, with page numbers")
        XCTAssertEqual(model.rows.map { $0.isCurrent }, [true, false])

        h.session.page = Fixtures.pdfPage
        try await waitUntil { model.rows.map { $0.isCurrent } == [false, true] }

        // The page Trash (deleted + trashedAt), arriving as a merge from another device.
        var trashed = try XCTUnwrap(h.app.workspace.content(doc).page(Fixtures.pdfPage))
        trashed.deleted = true
        trashed.trashedAt = Date().timeIntervalSince1970
        trashed.rev = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000, counter: 0, device: 99)
        let merged = h.app.bus.applyRemote(DocumentPatch(doc: doc, pages: [trashed]), origin: "test")
        XCTAssertFalse(merged.updated.isEmpty && merged.removed.isEmpty, "the trashed page merged")
        try await waitUntil { model.rows.map { $0.page } == [Fixtures.page1] }

        try await h.run("page.setBookmarked", ["pages": [pageRef(Fixtures.page1)], "on": false])
        try await waitUntil { model.rows.isEmpty }
    }

    func testThumbnailChangedWhileRenderingRendersAgainWithoutFlashing() async throws {
        let renderer = HeldRenderer()
        let store = ThumbnailStore()
        var loads = 0
        store.onLoad = { loads += 1 }

        store.request(doc: doc, page: Fixtures.page1, renderer: renderer)
        try await waitUntil { renderer.waiting == 1 }
        store.request(doc: doc, page: Fixtures.page1, renderer: renderer)
        XCTAssertEqual(renderer.calls, 1, "one render per page at a time")

        // The page changes (a stroke) while its first render runs: that render is dropped and the page renders again.
        store.invalidate([Fixtures.page1])
        renderer.release()
        try await waitUntil { renderer.calls == 2 && renderer.waiting == 1 }
        XCTAssertNil(store.image(Fixtures.page1), "the out-of-date render never lands")
        XCTAssertEqual(loads, 0)
        renderer.release()
        try await waitUntil { store.image(Fixtures.page1) != nil }
        XCTAssertEqual(loads, 1)
        XCTAssertFalse(store.needsRender(Fixtures.page1))

        // A later change keeps the old image on screen until the new one replaces it.
        let first = try XCTUnwrap(store.image(Fixtures.page1))
        store.invalidate([Fixtures.page1])
        XCTAssertTrue(store.image(Fixtures.page1) === first, "no flash to the placeholder")
        XCTAssertTrue(store.needsRender(Fixtures.page1))
        store.request(doc: doc, page: Fixtures.page1, renderer: renderer)
        try await waitUntil { renderer.waiting == 1 }
        XCTAssertTrue(store.image(Fixtures.page1) === first)
        renderer.release()
        try await waitUntil { loads == 2 }
        XCTAssertFalse(store.image(Fixtures.page1) === first)
        store.request(doc: doc, page: Fixtures.page1, renderer: renderer)
        XCTAssertEqual(renderer.calls, 3, "a current image is not rendered again")
    }
}

/// Holds every thumbnail render until the test releases it (a slow renderer, deterministically).
private final class HeldRenderer: PageRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [CheckedContinuation<CGImage?, Never>] = []
    private var count = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            lock.lock()
            count += 1
            held.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let all = held
        held = []
        lock.unlock()
        for continuation in all { continuation.resume(returning: FakeRenderer.blank(CGSize(width: 8, height: 8))) }
    }

    func render(_ request: RenderRequest) async throws -> RenderResult {
        throw NibError(.unsupported, "thumbnails only")
    }

    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}

    func purgeCaches() {}
}
