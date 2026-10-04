import XCTest
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Pages-area acceptance tests. Mutations use touch, drag, native pickers or typeKey only.
/// nib.qa.state supplies live identity/counts; read-only package inspection supplements it for
/// order, paper, outline and asset fidelity. Input PDFs/images are external picker documents.
@MainActor
final class PagesUITests: XCTestCase {
    private var ui: NibUI!
    private var fixture: URL!
    private var inputs: URL?
    private var doc = ""
    private let notebook = "Physics — Motion"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The shared runner permits 300 seconds; cold fixture startup is part of each test.
        executionTimeAllowance = 300
        ui = NibUI()
        try ui.launchFixture()
        let fm = FileManager.default
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let roots = try fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil).flatMap {
            (try? fm.contentsOfDirectory(at: $0.appendingPathComponent("tmp"), includingPropertiesForKeys: [.creationDateKey])) ?? []
        }.filter { $0.lastPathComponent.hasPrefix("NibUITests-") }
        fixture = try XCTUnwrap(roots.max {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }, "Cannot locate isolated simulator fixture for read-only assertions")
        try ui.openDocument(notebook)
        doc = try XCTUnwrap(ui.state().document)
        XCTAssertEqual(try ui.state().pageCount, 4)
    }

    override func tearDownWithError() throws {
        if let ui {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Pages-\(name)-screen"; shot.lifetime = .keepAlways; add(shot)
            let state = XCTAttachment(string: "\(ui.probe.value ?? "no probe")\n\(ui.app.debugDescription)")
            state.name = "Pages-\(name)-state-and-accessibility"; state.lifetime = .keepAlways; add(state)
            ui.app.terminate()
        }
        if let inputs { try FileManager.default.removeItem(at: inputs) }
    }

    // sidebar.pages / sidebar.navigate: the ring, page identity and visible paper agree.
    func testSidebarNavigationAndFullWindowMode() throws {
        let original = try ids()
        try ui.tapCommand("sidebar.toggle")
        try ui.waitForState { $0.openPanels.contains("sidebar.pages") }
        try pages()
        XCTAssertTrue(value(thumb(1)).contains("Current page"))
        try navigate(2)
        XCTAssertEqual(try ui.state().page, original[1])
        XCTAssertTrue(value(thumb(2)).contains("Current page"))
        XCTAssertFalse(value(thumb(1)).contains("Current page"))
        try wait("Canvas must reveal page 2") { self.ui.app.otherElements["Page 2 of 4"].exists }
        try tap("Panel Options"); try tap("Show as Window")
        let navigator = try require(label("Document navigation"))
        XCTAssertGreaterThan(navigator.frame.width, ui.app.windows.firstMatch.frame.width * 0.7)
        try navigate(3)
        XCTAssertEqual(try ui.state().page, original[2])
        try tap("Panel Options"); try tap("Show as Sidebar")
        XCTAssertLessThan(try require(label("Sidebar")).frame.width, ui.app.windows.firstMatch.frame.width * 0.5)
        XCTAssertEqual(try ids(), original)
    }

    func testPageHUDOpensNavigator() throws {
        let hud = try require(label("Page 1 of 4"))
        // HUD combines its children for accessibility; tap its leading navigator glyph.
        hud.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        try ui.waitForState { $0.openPanels.contains("sidebar.pages") }
        try navigate(2)
        XCTAssertTrue(value(thumb(2)).contains("Current page"))
    }

    // sidebar.select: individual toggles, Select All, contextual Cmd-A and swipe are real actions.
    func testSelectToggleAllAndBatchBookmarkScope() throws {
        try pages(window: true); try beginSelection()
        try tapThumb(1); try tapThumb(2)
        XCTAssertTrue(thumb(1).isSelected); XCTAssertTrue(thumb(2).isSelected)
        try tapThumb(1)
        XCTAssertFalse(thumb(1).isSelected); XCTAssertTrue(thumb(2).isSelected)
        try selectionAction("Bookmark")
        try wait("Only selected page 2 must be bookmarked") { (try? self.live().map { $0["bookmarked"] as? Bool ?? false }) == [false, true, false, false] }
        try tap("Select All")
        try wait("Select All must check every thumbnail") { self.ui.app.staticTexts["4 Selected"].exists || (1...4).allSatisfy { self.thumb($0).isSelected } }
        try tap("Deselect All")
        XCTAssertFalse(thumb(2).isSelected)
        ui.app.nibTypeKey("a", modifierFlags: .command)
        try selectionAction("Bookmark")
        try wait("Cmd-A batch action must include all four pages") { (try? self.live().allSatisfy { $0["bookmarked"] as? Bool == true }) == true }
    }

    func testSwipeSelectionCopiesExactlyItsCheckedPages() throws {
        try pages(window: true); try beginSelection()
        let first = try require(thumb(1)), second = try require(thumb(2))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0)
        try wait("Swipe must select the crossed thumbnails") { self.thumb(1).isSelected && self.thumb(2).isSelected }
        let selected = (1...4).filter { thumb($0).isSelected }.count
        let before = try ids()
        try selectionAction("Copy"); try tap("Done"); try closeNavigator()
        try more("Paste Pages")
        try count(4 + selected)
        XCTAssertEqual(Set(try ids()).intersection(before).count, 4, "Copy/paste must retain the sources")
    }

    func testAddCurrentTemplateBefore() throws { try addCurrent("Before This Page", index: 1) }
    func testAddCurrentTemplateAfter() throws { try addCurrent("After This Page", index: 2) }
    func testAddCurrentTemplateAtEnd() throws { try addCurrent("As Last Page", index: 4) }

    func testChooseTemplateOptionsCommitAndCancelAddsNothing() throws {
        let before = try ids()
        try more("Choose Template…")
        try chooseGraphOptions()
        try tap("Cancel")
        XCTAssertEqual(try ids(), before)
        try more("Choose Template…"); try chooseGraphOptions(); try tap("Choose Template")
        try count(5)
        let added = try XCTUnwrap(live().first { !before.contains($0["id"] as? String ?? "") })
        try assertGraph(added)
        try ui.tapCommand("edit.undo"); try count(4)
        XCTAssertEqual(try ids(), before)
        try ui.tapCommand("edit.redo"); try count(5)
    }

    func testImportPDFPagesAtChosenPositionWithPDFOutline() throws {
        try makeInputs()
        let before = try ids()
        try more("Before This Page"); try more("Import…"); try pickFile("Pages input")
        try count(6)
        let records = try live()
        XCTAssertEqual(Array(try ids().suffix(4)), before)
        XCTAssertEqual(records.prefix(2).map { background($0)["kind"] as? String }, ["pdf", "pdf"])
        XCTAssertEqual(records.prefix(2).map { background($0)["pdfPage"] as? Int ?? 0 }, [0, 1])
        for record in records.prefix(2) { try assertAssets(record) }
        try pages(); try tab("Outline", id: "outline.tab")
        try require(label("Imported second page")).tap()
        try ui.waitForState { $0.page == records[1]["id"] as? String }
        try ui.tapCommand("edit.undo"); try count(4)
    }

    func testImportImagePageAtEndAndUndo() throws {
        try makeInputs()
        let before = try ids()
        try more("As Last Page"); try more("Import…"); try pickFile("Pages image")
        try count(5)
        XCTAssertEqual(Array(try ids().prefix(4)), before)
        let inserted = try XCTUnwrap(live().last)
        XCTAssertEqual(background(inserted)["kind"] as? String, "image")
        try assertAssets(inserted)
        try ui.tapCommand("edit.undo"); try count(4)
        XCTAssertEqual(try ids(), before)
    }

    func testAddImageFromPhotosPreservesOriginalPages() throws {
        try makeInputs()
        let png = try Data(contentsOf: XCTUnwrap(inputs).appendingPathComponent("Pages image.png"))
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        try ui.selectTool("image"); ui.coordinate(CGPoint(x: 0.65, y: 0.72)).tap(); try tap("Paste")
        try allowPermission()
        try ui.waitForState { $0.itemCountOnPage == 5 }
        try ui.selectTool("lasso"); ui.coordinate(CGPoint(x: 0.65, y: 0.72)).tap()
        try ui.waitForState { $0.selectionCount == 1 }
        let copy = try require(ui.app.buttons["cmd.clipboard.copy"])
        let imageMore = ui.app.buttons.matching(NSPredicate(format: "label == 'More'"))
            .allElementsBoundByIndex.filter { $0.isHittable && $0.identifier != "menu.more" && $0.identifier != "tool.more" && abs($0.frame.midY - copy.frame.midY) < 45 }
        try XCTUnwrap(imageMore.first, "Image selection must expose More").tap()
        try tap("Save to Photos"); try allowPermission()
        ui.coordinate(CGPoint(x: 0.38, y: 0.85)).tap()
        let before = try ids()
        try more("Image")
        // The document also exposes an Image element; only a Photos asset is
        // a selectable picker result (F034 / Add Page > Image).
        let photo = ui.app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        try require(photo, "Add Page > Image must present selectable Photos assets")
        photo.tap()
        // PHPicker's multi-selection confirmation is Done on iPadOS 26.
        // Selecting a thumbnail alone does not import the chosen photo.
        let finish = ui.app.navigationBars["Photos"].buttons
            .matching(NSPredicate(format: "label == 'Done' OR label == 'Add'")).firstMatch
        try require(finish, "Confirm the selected Photos asset").tap()
        try count(5)
        XCTAssertEqual(Set(try ids()).intersection(before).count, 4)
        let newImages = try live().filter { background($0)["kind"] as? String == "image" }
        XCTAssertEqual(newImages.count, 1)
        for page in newImages { try assertAssets(page) }
    }

    func testDuplicatePagePreservesDrawnInkAndAssetsAndUndoRedo() throws {
        try draw()
        let original = try ui.state()
        let source = try XCTUnwrap(live().first), beforeIDs = try ids()
        try more("Duplicate"); try count(5)
        let copy = try XCTUnwrap(live().first { !beforeIDs.contains($0["id"] as? String ?? "") })
        XCTAssertEqual(canonical(background(copy)), canonical(background(source)))
        let copyID = try XCTUnwrap(copy["id"] as? String)
        XCTAssertEqual(try itemKinds(copyID), try itemKinds(try XCTUnwrap(original.page)))
        XCTAssertEqual(try contentSignature(copyID), try contentSignature(try XCTUnwrap(original.page)), "Duplicate must preserve ink data, text, geometry and style")
        try pages(); try navigate(2)
        try ui.waitForState { $0.itemCountOnPage == original.itemCountOnPage && $0.strokeCountOnPage == original.strokeCountOnPage }
        try closeNavigator(); try ui.tapCommand("edit.undo"); try count(4)
        try ui.tapCommand("edit.redo"); try count(5)
    }

    func testCopyAndPastePagesPreserveSourceContentAndAreUndoable() throws { try copyPaste(keyboard: false) }
    func testContextualCommandCCopiesSelectedPages() throws { try copyPaste(keyboard: true) }

    func testMoveSelectedPagesToAnotherDocumentPreservesContent() throws {
        try draw()
        let before = try ids(), kinds = try itemKinds(before[0]), content = try contentSignature(before[0])
        let target = try documentID(titled: "Lecture notes")
        let targetBefore = try live(target).count
        try pages(); try beginSelection(); try tapThumb(1)
        try selectionAction("Move to Another Notebook…")
        try ui.waitForState { $0.openPanels.contains("pages.movePages") }
        try tap("Lecture notes", prefix: true)
        try count(3)
        try wait("Move must append one target page") { (try? self.live(target).count) == targetBefore + 1 }
        XCTAssertFalse(try ids().contains(before[0]))
        let moved = try XCTUnwrap(live(target).last)
        XCTAssertEqual(try itemKinds(try XCTUnwrap(moved["id"] as? String), in: target), kinds)
        XCTAssertEqual(try contentSignature(try XCTUnwrap(moved["id"] as? String), in: target), content, "Move must retain source content and geometry")
        try assertAssets(moved, in: target)
        try ui.tapCommand("edit.undo"); try count(4)
        try wait("Undo Move must restore both documents") { (try? self.live(target).count) == targetBefore }
    }

    func testDragReordersPagesAndUndoRestoresOrder() throws {
        let before = try ids()
        try pages(window: true)
        let source = try require(thumb(1)), target = try require(thumb(3))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)))
        try wait("Dragging thumbnail into a gap must change page order") { (try? self.ids()) != before }
        XCTAssertEqual(Set(try ids()), Set(before))
        try closeNavigator(); try ui.tapCommand("edit.undo")
        try wait("Undo reorder must restore the original numbering") { (try? self.ids()) == before }
        try ui.tapCommand("window.showLibrary"); try ui.openDocument(notebook)
        XCTAssertEqual(try ids(), before)
    }

    func testDuplicateCopyPasteAndMoveImportedPageKeepAssetBytes() throws {
        try makeInputs()
        try more("Before This Page"); try more("Import…"); try pickFile("Pages image"); try count(5)
        try pages(); try navigate(1); try closeNavigator()
        let source = try XCTUnwrap(live().first)
        let originalBytes = try Data(contentsOf: assetFile(source))
        try more("Duplicate"); try count(6)
        XCTAssertEqual(try Data(contentsOf: assetFile(live()[1])), originalBytes)
        try more("Copy"); try more("As Last Page"); try more("Paste Pages"); try count(7)
        XCTAssertEqual(try Data(contentsOf: assetFile(try XCTUnwrap(live().last))), originalBytes)
        let target = try documentID(titled: "Lecture notes")
        try pages(); try beginSelection(); try tapThumb(1); try selectionAction("Move to Another Notebook…")
        try tap("Lecture notes", prefix: true); try count(6)
        try wait("Move imported page must append its background to target") { (try? self.live(target).count) == 2 }
        XCTAssertEqual(try Data(contentsOf: assetFile(try XCTUnwrap(live(target).last), in: target)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: assetFile(try XCTUnwrap(live().last))), originalBytes, "Moving the source must retain pasted asset data")
    }

    func testSelectedThumbnailsDragAsOneStackAndUndoTogether() throws {
        let before = try ids()
        try pages(window: true); try beginSelection(); try tapThumb(1); try tapThumb(2)
        let source = try require(thumb(1)), target = try require(thumb(4))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8,
            thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)))
        try wait("Dragging a selection must reorder its stack") { (try? self.ids()) != before }
        let after = try ids(), first = try XCTUnwrap(try ids().firstIndex(of: before[0]))
        XCTAssertLessThan(first + 1, after.count)
        XCTAssertEqual(after[first + 1], before[1], "Selected pages must retain relative order")
        XCTAssertEqual(Set(after), Set(before))
        try tap("Done"); try closeNavigator(); try ui.tapCommand("edit.undo")
        try wait("One Undo must restore the entire selected stack") { (try? self.ids()) == before }
    }

    func testBatchDuplicateAndTrashCancellationScope() throws {
        let before = try ids()
        try pages(window: true); try beginSelection(); try tapThumb(1); try tapThumb(2)
        try selectionAction("Duplicate"); try count(6)
        XCTAssertEqual(Set(try ids()).intersection(before).count, 4)
        try tap("Done"); try closeNavigator(); try ui.tapCommand("edit.undo"); try count(4)
        try pages(window: true); try beginSelection(); try tapThumb(1); try tapThumb(2)
        try selectionAction("Move to Trash"); try cancelConfirmation("Move 2 pages to the Trash?")
        XCTAssertEqual(try ids(), before)
        try selectionAction("Move to Trash"); try confirm("Move to Trash"); try count(2)
        XCTAssertEqual(try ids(), Array(before.suffix(2)))
        try closeNavigator(); try ui.tapCommand("edit.undo"); try count(4)
        XCTAssertEqual(try ids(), before)
    }

    func testDragThumbnailToCanvasInsertsImageAndRetainsPage() throws {
        let before = try ui.state(), order = try ids()
        try pages()
        let source = try require(thumb(1))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8, thenDragTo: ui.coordinate(CGPoint(x: 0.70, y: 0.60)))
        try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage }
        XCTAssertEqual(try ids(), order)
        try wait("Thumbnail drop must persist an image, not an ink stroke") {
            (try? self.itemKinds(before.page ?? "").contains("image")) == true
        }
        try ui.tapCommand("edit.undo")
        try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage }
    }

    func testDragPagesBetweenWindowsCopiesIntoDestination() throws {
        // Cross-window dragging requires iPadOS Windowed Apps; the shared
        // launch helper deliberately uses Full Screen Apps for single scenes.
        try NibUIMultitasking.activate(ui.app, windowed: true)
        let sourceDoc = doc, before = try ids(), sourceKinds = try itemKinds(try ids()[0])
        let targetDoc = try documentID(titled: "Lecture notes")
        try pages()
        // iPadOS 26 uses Windowed Apps: drag Nib from the Dock to an edge
        // to open another scene beside the source (Apple's native tiling flow).
        let sourceWindow = ui.app.windows.firstMatch
        sourceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
            .press(forDuration: 0.05, thenDragTo: sourceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.84)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        let other = XCUIApplication(bundleIdentifier: "com.apple.springboard").icons["Nib"].firstMatch
        try require(other, "The Dock must offer Nib for a second window")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: sourceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)))
        // F019 shows the current folder's contents. The fixture places Lecture
        // notes inside Semester Notes, so navigate there in the destination.
        let folder = ui.app.buttons.matching(identifier: "cmd.library.setView")
            .matching(NSPredicate(format: "label == 'Semester Notes'")).firstMatch
        // A new scene starts with the native Folders disclosure collapsed.
        // F019 does not require every folder to be permanently expanded.
        if !folder.exists { try tap("Folders") }
        try require(folder, "Open the destination notebook's folder").tap()
        let openTarget = ui.app.buttons.matching(identifier: "cmd.doc.open").matching(NSPredicate(format: "label BEGINSWITH 'Lecture notes'")).firstMatch
        try require(openTarget).tap()
        let toggles = ui.app.buttons.matching(identifier: "cmd.sidebar.toggle").allElementsBoundByIndex.filter { $0.isHittable }
        if let toggle = toggles.last { toggle.tap() }
        let grids = ui.app.collectionViews.matching(NSPredicate(format: "label == 'Page thumbnails'")).allElementsBoundByIndex
        XCTAssertEqual(grids.count, 2, "Both windows must expose their Pages sidebars")
        let source = try XCTUnwrap(grids.first { $0.buttons["Page 2"].exists })
        let destination = try XCTUnwrap(grids.first { !$0.buttons["Page 2"].exists })
        source.buttons["Page 1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8, thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        try wait("Cross-window drop must append a copy") { (try? self.live(targetDoc).count) == 2 }
        XCTAssertEqual(try ids(sourceDoc), before, "Cross-window app.nib.pages drops copy rather than remove their source")
        let inserted = try XCTUnwrap(live(targetDoc).last?["id"] as? String)
        XCTAssertEqual(try itemKinds(inserted, in: targetDoc), sourceKinds)
    }

    func testRotateSelectionAndAllPagesHaveExactScopeAndUndo() throws {
        let before = try rotations()
        try pages(); try beginSelection(); try tapThumb(1); try tapThumb(2)
        try selectionAction("Rotate Clockwise")
        try wait("Only selected pages must rotate 90 degrees") { (try? self.rotations()) == [90, 90, 0, 0] }
        try tap("Done"); try closeNavigator()
        try ui.tapCommand("edit.undo")
        try wait("Undo rotation restores all page orientations") { (try? self.rotations()) == before }
        try more("Rotate All Pages")
        try wait("Rotate All Pages must rotate every page") { (try? self.rotations()) == [90, 90, 90, 90] }
        try count(4)
    }

    func testTrashPageAndRecoverPreservesDrawnContent() throws {
        try draw()
        let before = try ui.state(), order = try ids()
        try more("Move to Trash"); try count(3)
        try openTrash(); try trashMenu("Recover")
        try wait("Recover must return the original page") { (try? self.ids()) == order }
        try tap("Documents"); try ui.openDocument(notebook)
        try pages(); try navigate(1)
        try ui.waitForState { $0.page == before.page && $0.strokeCountOnPage == before.strokeCountOnPage && $0.itemCountOnPage == before.itemCountOnPage }
    }

    func testPurgePageRequiresConfirmationAndCancelRetainsTrash() throws {
        let removed = try ids()[0]
        try more("Move to Trash"); try count(3)
        try openTrash(); try trashMenu("Delete Permanently")
        try cancelConfirmation("Delete permanently?")
        XCTAssertTrue(try allPages().contains { $0["id"] as? String == removed && $0["deleted"] as? Bool == true })
        try trashMenu("Delete Permanently"); try tap("Delete 1 item")
        try wait("Permanently deleted page must no longer be recoverable") {
            guard let pages = try? self.allPages() else { return false }
            return !pages.contains { $0["id"] as? String == removed && $0["trashedAt"] != nil && !($0["trashedAt"] is NSNull) }
        }
        try require(label("Trash is empty"))
        try tap("Documents"); try ui.openDocument(notebook); try count(3)
    }

    func testBookmarkGlyphListNavigationAndUnbookmark() throws {
        let first = try ids()[0]
        try ui.tapCommand("page.setBookmarked")
        try wait("Bookmark must persist on the current page") { (try? self.live()[0]["bookmarked"] as? Bool) == true }
        try pages()
        XCTAssertTrue(value(thumb(1)).contains("Bookmarked"))
        try navigate(2); try tab("Bookmarks", id: "outline.bookmarks")
        try tap("Page 1")
        try ui.waitForState { $0.page == first }
        try ui.tapCommand("page.setBookmarked")
        try require(label("No bookmarks"))
        try wait("Unbookmark must reach the persisted page") {
            guard let page = try? self.live()[0] else { return false }
            return !(page["bookmarked"] as? Bool ?? false)
        }
    }

    func testOutlineAddRenameNavigateAndDeleteRetainsPage() throws {
        let order = try ids()
        try pages(); try navigate(2); try addOutline("Second topic")
        let added = try entry("Second topic")
        XCTAssertEqual(added["page"] as? String, order[1])
        try outlineMenu("Second topic", "Rename")
        try replace(ui.app.alerts.textFields.firstMatch, "Renamed topic"); try tap("Rename")
        try wait("Rename changes the title while retaining the page link") { (try? self.entry("Renamed topic")["page"] as? String) == order[1] }
        try tab("Pages", id: "sidebar.pages"); try navigate(1)
        try tab("Outline", id: "outline.tab"); try require(label("Renamed topic")).tap()
        try ui.waitForState { $0.page == order[1] }
        try outlineMenu("Renamed topic", "Delete")
        try wait("Delete outline entry must remove only the entry") { (try? self.outline().isEmpty) == true }
        XCTAssertEqual(try ids(), order)
        try ui.tapCommand("edit.undo")
        try wait("Undo outline deletion must restore title and page link") { (try? self.entry("Renamed topic")["page"] as? String) == order[1] }
    }

    func testOutlineThumbnailAndMoreAddTargetCorrectPage() throws {
        let order = try ids()
        try more("Add Page to Outline")
        try wait("More outline action must target current page with a nonempty title") {
            (try? self.outline().contains { $0["page"] as? String == order[0] && !($0["title"] as? String ?? "").isEmpty }) == true
        }
        try pages(); try pageMenu(2, "Add to Outline")
        try wait("Thumbnail outline action must target pressed page") {
            (try? self.outline().contains { $0["page"] as? String == order[1] && !($0["title"] as? String ?? "").isEmpty }) == true
        }

    }

    func testOutlineMoveNestOutdentAndThreeLevelLimit() throws {
        try pages()
        for title in ["A", "B", "C", "D"] { try addOutline(title) }
        try outlineMenu("B", "Nest in Previous Entry", move: true)
        try wait("B must nest under A") { (try? self.entry("B")["parent"] as? String) == (try? self.entry("A")["id"] as? String) }
        try outlineMenu("C", "Nest in Previous Entry", move: true)
        try outlineMenu("C", "Nest in Previous Entry", move: true)
        try wait("C must nest under B at level three") { (try? self.entry("C")["parent"] as? String) == (try? self.entry("B")["id"] as? String) }
        try outlineMenu("D", "Nest in Previous Entry", move: true)
        try outlineMenu("D", "Nest in Previous Entry", move: true)
        try require(label("D")).press(forDuration: 0.8); try tap("Move")
        let tooDeep = button("Nest in Previous Entry")
        XCTAssertFalse(tooDeep.exists && tooDeep.isEnabled, "Outline must not offer a fourth nesting level")
        ui.app.nibTypeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        ui.app.nibTypeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        try outlineMenu("C", "Move Out a Level", move: true)
        try wait("Outdent must move C back under A") { (try? self.entry("C")["parent"] as? String) == (try? self.entry("A")["id"] as? String) }
        let parent = try XCTUnwrap(entry("A")["id"] as? String)
        try outlineMenu("C", "Move Up", move: true)
        try wait("Move Up must put C before its sibling B") {
            (try? self.outline().filter { $0["parent"] as? String == parent }.map { $0["title"] as? String }) == ["C", "B"]
        }
        XCTAssertEqual(try ui.state().pageCount, 4)
    }

    func testOutlineSortByCurrentPageNumberAndSwipeDelete() throws {
        try pages(); try navigate(3); try addOutline("Third")
        try tab("Pages", id: "sidebar.pages"); try navigate(1); try addOutline("First")
        try tab("Pages", id: "sidebar.pages"); try navigate(2); try addOutline("Second")
        try tap("Outline Options"); try tap("Sort by Page Number")
        try wait("Sort must follow current page order") { (try? self.outline().map { $0["title"] as? String }) == ["First", "Second", "Third"] }
        // DESIGN §14.4 uses native swipe deletion. A full swipe commits it;
        // there is no second Delete button after the row has been removed.
        try require(label("Second")).swipeLeft()
        try wait("Swipe Delete must remove only Second") { (try? self.outline().map { $0["title"] as? String }) == ["First", "Third"] }
        try count(4)
    }

    func testChangeThisPageTemplateAndUndo() throws { try changeTemplate(scope: "This page", selected: false) }
    func testChangeSelectedPageTemplates() throws { try changeTemplate(scope: "Selected pages", selected: true) }
    func testChangeAllPageTemplates() throws { try changeTemplate(scope: "All pages", selected: false) }

    func testChangeCoverAndRemoveCoverOnlyAffectsFirstPage() throws {
        let before = try live(), order = try ids()
        try pages(); try navigate(2); try closeNavigator()
        try more("Change Cover"); try require(ui.app.buttons.matching(NSPredicate(format: "label == 'Moss'")).allElementsBoundByIndex.last ?? button("Moss")).tap()
        try tap("Apply Template")
        try wait("Change Cover must enable a cover on page 1") { (try? self.head()["meta"] as? [String: Any])?["coverEnabled"] as? Bool == true }
        XCTAssertEqual(try ids(), order)
        XCTAssertNotEqual(canonical(background(try live()[0])), canonical(background(before[0])))
        XCTAssertEqual(canonical(background(try live()[1])), canonical(background(before[1])))
        try more("Change Cover"); try tap("No cover"); try tap("Apply Template")
        try wait("No cover must clear coverEnabled") { (try? self.head()["meta"] as? [String: Any])?["coverEnabled"] as? Bool == false }
        XCTAssertEqual(try ids(), order)
    }

    func testManageTemplatesShortcutAndAppMenuDisplayBuiltinAndCustomEntries() throws {
        try manageTemplates()
        try category("Essentials"); try tap("Blank")
        XCTAssertTrue(button("Blank").isSelected)
        try tap("Done")
        try ui.tapCommand("window.showLibrary")
        try tap("App Menu"); try tap("Manage Templates", prefix: true)
        try ui.waitForState { $0.openPanels.contains("templateui.manage") }
        try require(button("Import Template"))
        try tap("Covers"); try require(button("No cover"))
    }

    func testImportPDFPaperUsesOnlyFirstPDFPage() throws { try importTemplate(kind: "paper", file: "Pages input") }
    func testImportImageCoverIsUsable() throws { try importTemplate(kind: "cover", file: "Pages image") }

    func testTemplateGroupCreateRenameCancelAndDelete() throws {
        try manageTemplates(); try tap("Manage Groups")
        try replace(ui.app.textFields["Group title"], "Research papers"); try tap("New Group")
        try wait("New group must be persisted") { (try? self.groups().contains { $0["title"] as? String == "Research papers" }) == true }
        let id = try XCTUnwrap(groups().first { $0["title"] as? String == "Research papers" }?["id"] as? String)
        try replace(ui.app.textFields["Group title"], "Lab papers"); try tap("Rename Group")
        try wait("Rename must preserve group identity") { (try? self.groups().contains { $0["title"] as? String == "Lab papers" && $0["id"] as? String == id }) == true }
        try tap("Delete Group"); try cancelConfirmation("Delete this group and its templates?")
        XCTAssertTrue(try groups().contains { $0["id"] as? String == id })
        try tap("Delete Group")
        try confirm("Delete Group")
        try wait("Confirmed group deletion must remove it from the live catalogue") { (try? self.groups().contains { $0["id"] as? String == id }) == false }
    }

    func testHideBuiltinRemovesItFromPickerAndRestoreReversesIt() throws {
        try manageTemplates(); try category("Essentials")
        try require(button("Blank")).press(forDuration: 0.8); try tap("Hide Template")
        try wait("Hidden built-in must leave management grid") { !self.button("Blank").exists }
        try tap("Done"); try more("Choose Template…"); try category("Essentials")
        XCTAssertFalse(button("Blank").exists, "Hidden template must also leave paper picker")
        try tap("Cancel"); try manageTemplates(); try require(ui.app.switches["Show hidden"]).tap(); try category("Essentials")
        try require(button("Blank")).press(forDuration: 0.8); try tap("Restore Template")
        try require(ui.app.switches["Show hidden"]).tap(); try require(button("Blank"))
        try tap("Done"); try more("Choose Template…"); try category("Essentials"); try tap("Blank")
        try tap("Choose Template"); try count(5)
    }

    func testCreateTemplateFromDrawnPageFlattensAppearanceAndDeleteOnlyChosenTemplate() throws {
        try draw()
        let source = try ui.state(), order = try ids()
        try pages(); try pageMenu(1, "Create Template from Page")
        try replace(ui.app.textFields["Template title"], "Motion master"); try tap("Create Template")
        try wait("Create Template must persist a named custom template") { (try? self.customTemplates().contains { $0["title"] as? String == "Motion master" }) == true }
        let template = try XCTUnwrap(customTemplates().first { $0["title"] as? String == "Motion master" })
        let url = try templateFile(template)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 1000, "Flattened template must contain the rendered page")
        XCTAssertEqual(try ids(), order)
        try tap("Done"); try closeNavigator()
        try more("Choose Template…"); try category("Custom"); try tap("Motion master"); try tap("Choose Template")
        try count(5)
        let added = try XCTUnwrap(live().first { !order.contains($0["id"] as? String ?? "") })
        XCTAssertEqual(background(added)["kind"] as? String, "pdf")
        try assertAssets(added)
        XCTAssertTrue(try itemKinds(try XCTUnwrap(added["id"] as? String)).isEmpty, "Template artwork must be flattened, not copied editable strokes")
        try pages(); try navigate(1)
        try ui.waitForState { $0.strokeCountOnPage == source.strokeCountOnPage }
        try closeNavigator(); try manageTemplates(); try category("Custom")
        try require(button("Motion master")).press(forDuration: 0.8); try tap("Delete Template"); try confirm("Delete Template")
        try wait("Delete custom template must remove only chosen catalogue entry") { (try? self.customTemplates().contains { $0["title"] as? String == "Motion master" }) == false }
        try category("Essentials"); try require(button("Blank"))
        try assertAssets(added)
        try count(5)
    }

    // MARK: UI helpers
    private func label(_ text: String) -> XCUIElement {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }
    private func button(_ text: String, prefix: Bool = false) -> XCUIElement {
        let query = ui.app.buttons.matching(NSPredicate(format: prefix ? "label BEGINSWITH %@" : "label == %@", text))
        let matches = query.allElementsBoundByIndex
        return matches.first { $0.isHittable } ?? matches.first { $0.frame.width > 0 && $0.frame.height > 0 } ?? query.firstMatch
    }
    @discardableResult private func require(_ element: XCUIElement, _ message: String = "Required page control missing") throws -> XCUIElement {
        guard element.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("\(message): \(element)\n\(ui.app.debugDescription)") }
        return element
    }
    private func wait(_ message: String, timeout: TimeInterval = 20, _ predicate: @escaping () -> Bool) throws {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [exp], timeout: timeout) == .completed else { throw NibUI.Failure.message("\(message)\n\(ui.probe.value ?? "no probe")") }
    }
    private func cancelConfirmation(_ title: String) throws {
        let confirmation = try require(ui.app.sheets[title])
        if button("Cancel").exists && button("Cancel").isHittable {
            try tap("Cancel")
        } else {
            // DESIGN uses native confirmation dialogs. On iPad, cancelling a
            // popover means tapping outside; there is no visible Cancel row.
            let window = ui.app.windows.firstMatch
            let point = CGPoint(x: window.frame.minX + window.frame.width * 0.95,
                                y: window.frame.minY + window.frame.height * 0.15)
            XCTAssertFalse(confirmation.frame.contains(point))
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)).tap()
        }
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    }
    private func tap(_ text: String, prefix: Bool = false) throws {
        try require(button(text, prefix: prefix), "Missing button \(text)")
        var target: XCUIElement?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let candidate = self.button(text, prefix: prefix)
            if candidate.isHittable && candidate.isEnabled { target = candidate; return true }
            return false
        }, object: nil)
        if XCTWaiter.wait(for: [ready], timeout: 5) != .completed {
            let candidate = button(text, prefix: prefix)
            ui.revealFormElement(candidate)
            if candidate.isHittable && candidate.isEnabled { target = candidate }
        }
        guard let target else { throw NibUI.Failure.message("Button cannot be used: \(text)") }
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func more(_ text: String) throws {
        try require(ui.app.buttons["menu.more"]).tap()
        let host = ui.app.scrollViews.matching(NSPredicate(format: "label == 'More'")).firstMatch
        let row = host.buttons.matching(NSPredicate(format: "label == %@", text)).firstMatch
        try require(row, "More menu must offer \(text)")
        for _ in 0..<12 {
            guard let viewport = NibUITestScrollGeometry.viewport(scroll: host.frame, window: ui.app.frame, obstructions: []) else { break }
            if row.isHittable, let point = NibUITestScrollGeometry.tapPoint(control: row.frame, viewport: viewport) {
                let origin = ui.app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: point.x - ui.app.frame.minX, dy: point.y - ui.app.frame.minY)).tap()
                return
            }
            let drag = NibUITestScrollGeometry.drag(in: viewport, toward: row.frame.midY)
            let origin = ui.app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: drag.start.x - ui.app.frame.minX, dy: drag.start.y - ui.app.frame.minY))
                .press(forDuration: 0.01, thenDragTo: origin.withOffset(CGVector(dx: drag.end.x - ui.app.frame.minX, dy: drag.end.y - ui.app.frame.minY)),
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        throw NibUI.Failure.message("More menu control is unreachable: \(text)")
    }
    private func pages(window: Bool = false) throws {
        let navigatorIDs = ["sidebar.pages", "outline.tab", "outline.bookmarks"]
        let state = try ui.state()
        if !state.openPanels.contains(where: navigatorIDs.contains) {
            // Other page tests use the real navigator shortcut so a HUD regression does not mask them.
            // The sidebar button and HUD have their own direct-tap acceptance tests above.
            ui.app.nibTypeKey("s", modifierFlags: [.control, .command])
            try ui.waitForState { $0.openPanels.contains(where: navigatorIDs.contains) }
        }
        if !(try ui.state().openPanels.contains("sidebar.pages")) { try tab("Pages", id: "sidebar.pages") }
        try ui.waitForState { $0.openPanels.contains("sidebar.pages") }
        if window && !label("Document navigation").exists {
            try tap("Panel Options"); try tap("Show as Window")
            try wait("Show as Window must expand the page navigator") { self.label("Document navigation").exists }
        }
    }
    private func tab(_ title: String, id: String) throws {
        try tap(title)
        try ui.waitForState { $0.openPanels.contains(id) }
    }
    private func closeNavigator() throws {
        if try ui.state().openPanels.contains(where: { ["sidebar.pages", "outline.tab", "outline.bookmarks"].contains($0) }) {
            ui.app.nibTypeKey("s", modifierFlags: [.control, .command])
            try ui.waitForState { !$0.openPanels.contains(where: { ["sidebar.pages", "outline.tab", "outline.bookmarks"].contains($0) }) }
        }
    }
    private func thumb(_ number: Int) -> XCUIElement {
        ui.app.collectionViews.matching(NSPredicate(format: "label == 'Page thumbnails'")).buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Page \(number)", "Page \(number),")).firstMatch
    }
    private func tapThumb(_ number: Int) throws {
        let element = thumb(number)
        let grid = ui.app.collectionViews.matching(NSPredicate(format: "label == 'Page thumbnails'")).firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable { break }
            grid.swipeUp()
        }
        try require(element)
        guard let viewport = NibUITestScrollGeometry.viewport(scroll: grid.frame, window: ui.app.frame, obstructions: []),
              let point = NibUITestScrollGeometry.tapPoint(control: element.frame, viewport: viewport) else {
            throw NibUI.Failure.message("Thumbnail \(number) has no visible tap target")
        }
        ui.app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - ui.app.frame.minX, dy: point.y - ui.app.frame.minY)).tap()
    }
    private func navigate(_ number: Int) throws {
        let target = try ids()[number - 1]
        try tapThumb(number)
        try ui.waitForState { $0.page == target }
    }
    private func pageMenu(_ number: Int, _ action: String) throws {
        try require(thumb(number)).press(forDuration: 0.8); try tap(action)
    }
    private func beginSelection() throws {
        try tap("Select")
        try wait("Select must enter page selection mode") { self.button("Done").exists && self.button("Select All").isHittable }
    }
    private func selectionAction(_ title: String) throws {
        if !button(title).isHittable { try tap("More Actions") }
        if title.hasPrefix("Rotate "), !button(title).exists { try tap("Rotate") }
        try tap(title)
    }
    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }
    private func count(_ count: Int) throws {
        try ui.waitForState { $0.pageCount == count }
        try wait("Live persisted page count must equal \(count)") { (try? self.live().count) == count }
    }
    private func replace(_ field: XCUIElement, _ text: String) throws {
        try require(field)
        let previous = field.value as? String ?? ""
        // Enter text through the native editor. XCTest's modifier-key synthesis
        // treats an intentional alert as an interruption and presses Cancel.
        // A trailing-edge tap places the caret after these short form values.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let value = previous == field.placeholderValue ? "" : previous
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + text)
        if !ui.app.alerts.firstMatch.exists, ui.app.keyboards.firstMatch.exists {
            let hide = ui.app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hide keyboard' OR label CONTAINS[c] 'dismiss keyboard'")).firstMatch
            if hide.exists { hide.tap() } else { ui.app.keyboards.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.94)).tap() }
        }
    }
    private func draw() throws {
        try ui.selectTool("pen")
        let before = try ui.state().strokeCountOnPage
        try ui.drawStroke([CGPoint(x: 0.40, y: 0.60), CGPoint(x: 0.58, y: 0.68)])
        let drawn = try ui.waitForState { $0.strokeCountOnPage == before + 1 && $0.undoAvailable }
        try wait("Drawn ink must reach the saved page before content-copy assertions") {
            (try? self.itemKinds(drawn.page ?? "").filter { $0 == "stroke" }.count) == before + 1
        }
    }
    private func addCurrent(_ position: String, index: Int) throws {
        try pages(); try navigate(2); try closeNavigator()
        let before = try ids(), paper = background(try live()[1])
        try more(position); try more("Current Template"); try count(5)
        let after = try ids(), added = after[index]
        XCTAssertFalse(before.contains(added))
        XCTAssertEqual(after.filter { $0 != added }, before)
        XCTAssertEqual(canonical(background(try live()[index])), canonical(paper))
        try ui.tapCommand("edit.undo"); try count(4); XCTAssertEqual(try ids(), before)
        try ui.tapCommand("edit.redo"); try count(5)
    }
    private func copyPaste(keyboard: Bool) throws {
        try draw()
        let before = try ids(), kinds = try itemKinds(try ids()[0]), content = try contentSignature(try ids()[0])
        try pages(); try beginSelection(); try tapThumb(1); try tapThumb(2)
        let revision = try ui.state().clipboardChangeCount ?? 0
        if keyboard { ui.app.nibTypeKey("c", modifierFlags: .command) } else { try selectionAction("Copy") }
        try ui.waitForState { ($0.clipboardChangeCount ?? 0) > revision }
        XCTAssertEqual(try ids(), before)
        XCTAssertEqual(try itemKinds(before[0]), kinds)
        try tap("Done"); try closeNavigator(); try more("As Last Page"); try more("Paste Pages")
        try count(6)
        XCTAssertEqual(Array(try ids().prefix(4)), before)
        XCTAssertEqual(try itemKinds(try ids()[4]), kinds)
        XCTAssertEqual(try contentSignature(try ids()[4]), content, "Paste must retain source content and geometry")
        XCTAssertTrue(try itemKinds(try ids()[5]).isEmpty)
        try ui.tapCommand("edit.undo"); try count(4); XCTAssertEqual(try ids(), before)
        try ui.tapCommand("edit.redo"); try count(6)
    }
    private func addOutline(_ title: String) throws {
        if !(try ui.state().openPanels.contains("outline.tab")) { try tab("Outline", id: "outline.tab") }
        try tap("Add entry"); try replace(ui.app.alerts.textFields.firstMatch, title); try tap("Add")
        try wait("Outline entry \(title) must be created") { (try? self.entry(title)) != nil }
    }
    private func outlineMenu(_ title: String, _ action: String, move: Bool = false) throws {
        try require(label(title)).press(forDuration: 0.8)
        if move { try tap("Move") }
        try tap(action)
    }
    private func openTrash() throws {
        try closeNavigator(); try ui.tapCommand("window.showLibrary"); try tap("Trash")
        try require(label("Page 1", exact: false))
    }
    private func label(_ text: String, exact: Bool) -> XCUIElement {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: exact ? "label == %@" : "label BEGINSWITH %@", text)).firstMatch
    }
    private func trashMenu(_ action: String) throws {
        let row = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1'")).firstMatch
        try require(row).tap(); try tap(action)
    }
    private func confirm(_ title: String) throws {
        let candidates = ui.app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex.filter { $0.isHittable }
        try XCTUnwrap(candidates.last, "Missing confirmation \(title)").tap()
    }
    private func allowPermission() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for application in [ui.app, springboard] {
            let alert = application.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                let allow = alert.buttons.allElementsBoundByIndex.first { $0.label.hasPrefix("Allow") || $0.label == "OK" }
                try XCTUnwrap(allow, "System permission must offer Allow").tap()
            }
        }
    }
    private func category(_ title: String) throws {
        if !button(title).exists { try tap("Template group", prefix: true) }
        if button(title).exists && !button(title).isHittable { try revealTemplateTile(title) }
        try tap(title)
    }
    private func chooseGraphOptions() throws {
        try category("Essentials")
        try tap("Page Size", prefix: true); try tap("Letter"); try tap("Landscape"); try tap("Legal")
        XCTAssertTrue(button("Landscape").isSelected)
        // The compact popover has three columns; Graph Paper is lazily built in row two.
        try revealTemplateTile("Graph Paper")
        try tap("Graph Paper")
        XCTAssertTrue(button("Graph Paper").isSelected, "Picker preview must select the chosen paper")
    }
    private func revealTemplateTile(_ title: String) throws {
        for _ in 0..<8 {
            let target = button(title)
            let hosts = ui.app.scrollViews.allElementsBoundByIndex.filter { scroll in
                guard scroll.identifier != "nib.canvas", scroll.isHittable, scroll.frame.height > 100 else { return false }
                return scroll.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Template group' OR label IN {'Blank', 'Dot Grid', 'Grid', 'Graph Paper', 'No cover'}")).count > 0
                    || scroll.buttons.matching(NSPredicate(format: "label == %@", title)).count > 0
            }
            guard let host = hosts.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let viewport = NibUITestScrollGeometry.viewport(scroll: host.frame, window: ui.app.frame, obstructions: []) else { break }
            if target.exists && target.isHittable && viewport.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) { return }
            let drag = NibUITestScrollGeometry.drag(in: viewport, toward: target.exists ? target.frame.midY : nil)
            let origin = ui.app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: drag.start.x - ui.app.frame.minX, dy: drag.start.y - ui.app.frame.minY))
                .press(forDuration: 0.01, thenDragTo: origin.withOffset(CGVector(dx: drag.end.x - ui.app.frame.minX, dy: drag.end.y - ui.app.frame.minY)), withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        try require(button(title), "Template tile must be reachable: \(title)")
    }
    private func assertGraph(_ page: [String: Any]) throws {
        XCTAssertEqual(template(page), "builtin.graph")
        let size = try XCTUnwrap(page["size"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(size["width"] as? Double), 792, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(size["height"] as? Double), 612, accuracy: 0.5)
        let ref = try XCTUnwrap(background(page)["template"] as? [String: Any])
        let params = try XCTUnwrap(ref["params"] as? [String: Any])
        XCTAssertEqual((params["paper"] as? String)?.uppercased(), "#FCF3C8FF", "Chosen Legal paper colour must persist")
    }
    private func changeTemplate(scope: String, selected: Bool) throws {
        let before = try live(), kinds = try itemKinds(try ids()[0])
        if selected {
            try pages(); try beginSelection(); try tapThumb(1); try tapThumb(2); try selectionAction("Change Template")
        } else { try more("Change Template") }
        try ui.waitForState { $0.openPanels.contains("templateui.change") }
        try chooseGraphOptions(); try tap("Apply to", prefix: true); try tap(scope); try tap("Apply Template")
        let changed = scope == "All pages" ? 4 : selected ? 2 : 1
        try wait("Change Template must apply to exactly \(changed) pages") { (try? self.live().filter { self.template($0) == "builtin.graph" }.count) == changed }
        for (i, page) in try live().enumerated() {
            if i < changed { try assertGraph(page) }
            else { XCTAssertEqual(canonical(background(page)), canonical(background(before[i]))) }
        }
        XCTAssertEqual(try itemKinds(try ids()[0]), kinds)
        try closeNavigator(); try ui.tapCommand("edit.undo")
        try wait("Undo must restore all page backgrounds") { (try? self.live().map { self.canonical(self.background($0)) }) == before.map { self.canonical(self.background($0)) } }
    }
    private func manageTemplates() throws {
        ui.app.nibTypeKey("t", modifierFlags: [.command, .option, .shift])
        try ui.waitForState { $0.openPanels.contains("templateui.manage") }
        try require(button("Import Template"))
    }
    private func importTemplate(kind: String, file: String) throws {
        try makeInputs(); try manageTemplates()
        if kind == "cover" { try tap("Covers") }
        try tap("Import Template"); try pickFile(file)
        try wait("Imported template must appear in catalogue") { (try? self.customTemplates().contains { $0["title"] as? String == file && $0["kind"] as? String == kind }) == true }
        let entry = try XCTUnwrap(customTemplates().first { $0["title"] as? String == file })
        let stored = try templateFile(entry)
        if kind == "paper" { XCTAssertEqual(try XCTUnwrap(PDFDocument(url: stored)).pageCount, 1, "Template import uses the PDF's first page only") }
        try tap("Done")
        try more(kind == "cover" ? "Change Cover" : "Choose Template…")
        try category("Custom"); try tap(file); try tap(kind == "cover" ? "Apply Template" : "Choose Template")
        if kind == "paper" { try count(5) }
        else { try wait("Custom cover must enable cover metadata") { (try? self.head()["meta"] as? [String: Any])?["coverEnabled"] as? Bool == true } }
        let result = try XCTUnwrap(live().first { background($0)["kind"] as? String == (kind == "paper" ? "pdf" : "image") })
        try assertAssets(result)
    }

    // MARK: External media inputs (not app-state injection) and native Files picker
    private func makeInputs() throws {
        let folder = fixture.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Documents/Pages inputs \(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        inputs = folder
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for page in 1...2 {
                context.beginPage()
                ("Imported page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData))
        let root = PDFOutline(), second = PDFOutline()
        second.label = "Imported second page"; second.destination = PDFDestination(page: try XCTUnwrap(pdf.page(at: 1)), at: CGPoint(x: 0, y: 842))
        root.insertChild(second, at: 0); pdf.outlineRoot = root
        XCTAssertTrue(pdf.write(to: folder.appendingPathComponent("Pages input.pdf")))
        let png = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).pngData { context in
            UIColor.yellow.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            UIColor.blue.setFill(); context.fill(CGRect(x: 30, y: 30, width: 100, height: 150))
        }
        try png.write(to: folder.appendingPathComponent("Pages image.png"))
    }
    private func pickFile(_ name: String) throws {
        let browse = button("Browse")
        if browse.exists && browse.isHittable { browse.tap() }
        let local = ui.app.cells["DOC.sidebar.item.On My iPad"]
        guard local.waitForExistence(timeout: 30), local.isHittable else {
            throw NibUI.Failure.message("System Files picker did not expose its On My iPad provider")
        }
        local.tap()
        let nib = ui.app.cells["Nib, Container"]
        if nib.waitForExistence(timeout: 8), nib.isHittable { nib.tap() }
        let folder = ui.app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", try XCTUnwrap(inputs).lastPathComponent)).firstMatch
        try require(folder, "Files must expose external page input folder").tap()
        let file = ui.app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        try require(file, "Files must expose \(name)").tap()
        let open = button("Open")
        if open.waitForExistence(timeout: 2), open.isHittable { open.tap() }
    }

    // MARK: Read-only persisted observables
    private func packages() -> [URL] {
        let e = FileManager.default.enumerator(at: fixture.appendingPathComponent("Library"), includingPropertiesForKeys: nil)
        return e?.compactMap { $0 as? URL }.filter { $0.pathExtension == "nibnote" && !$0.path.contains("/trash/") } ?? []
    }
    private func package(_ id: String? = nil) throws -> URL {
        for url in packages() {
            if let file = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("doc.") && $0.pathExtension == "json" }),
               let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
               (object["meta"] as? [String: Any])?["id"] as? String == (id ?? doc) { return url }
        }
        throw NibUI.Failure.message("Package missing for \(id ?? doc)")
    }
    private func head(_ id: String? = nil) throws -> [String: Any] {
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: package(id), includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("doc.") && $0.pathExtension == "json" })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    private func documentID(titled title: String) throws -> String {
        for url in packages() {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            guard let file = files.first(where: { $0.lastPathComponent.hasPrefix("doc.") && $0.pathExtension == "json" }),
                  let data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], let meta = data["meta"] as? [String: Any] else { continue }
            if url.deletingPathExtension().lastPathComponent == title { return try XCTUnwrap(meta["id"] as? String) }
        }
        throw NibUI.Failure.message("Missing target document \(title)")
    }
    private func allPages(_ id: String? = nil) throws -> [[String: Any]] { try XCTUnwrap(head(id)["pages"] as? [[String: Any]]) }
    private func live(_ id: String? = nil) throws -> [[String: Any]] {
        try allPages(id).filter { $0["deleted"] as? Bool != true }.sorted { ($0["order"] as? String ?? "") < ($1["order"] as? String ?? "") }
    }
    private func ids(_ id: String? = nil) throws -> [String] { try live(id).compactMap { $0["id"] as? String } }
    private func background(_ page: [String: Any]) -> [String: Any] { page["background"] as? [String: Any] ?? [:] }
    private func template(_ page: [String: Any]) -> String? { (background(page)["template"] as? [String: Any])?["id"] as? String }
    private func canonical(_ value: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "" }
    private func rotations() throws -> [Int] { try live().map { $0["rotation"] as? Int ?? 0 } }
    private func items(_ page: String, in id: String? = nil) throws -> [[String: Any]] {
        let folder = try package(id).appendingPathComponent("pages/\(page)")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.pathExtension == "nibpage" }) else { return [] }
        let data = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).filter { $0["deleted"] as? Bool != true }
    }
    private func itemKinds(_ page: String, in id: String? = nil) throws -> [String] {
        try items(page, in: id).compactMap { $0["kind"] as? String }.sorted()
    }
    private func contentSignature(_ page: String, in id: String? = nil) throws -> [String] {
        try items(page, in: id).map { item in
            var copy = item
            // Copies legitimately receive new record IDs, revisions and provenance.
            for key in ["id", "rev", "createdBy"] { copy.removeValue(forKey: key) }
            return canonical(copy)
        }.sorted()
    }
    private func assertAssets(_ page: [String: Any], in id: String? = nil) throws {
        guard background(page)["asset"] != nil else { return }
        XCTAssertGreaterThan(try Data(contentsOf: assetFile(page, in: id)).count, 0)
    }
    private func assetFile(_ page: [String: Any], in id: String? = nil) throws -> URL {
        let name = try XCTUnwrap(background(page)["asset"] as? String, "Page must retain its background asset reference")
        // ARCHITECTURE §4.1: background asset references are names within assets/.
        let file = try package(id).appendingPathComponent("assets", isDirectory: true).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw NibUI.Failure.message("Missing referenced asset: \(name)") }
        return file
    }
    private func outline() throws -> [[String: Any]] {
        try XCTUnwrap(head()["outline"] as? [[String: Any]]).filter { $0["deleted"] as? Bool != true }.sorted { ($0["order"] as? String ?? "") < ($1["order"] as? String ?? "") }
    }
    private func entry(_ title: String) throws -> [String: Any] {
        guard let entry = try outline().first(where: { $0["title"] as? String == title }) else { throw NibUI.Failure.message("Outline entry missing: \(title)") }
        return entry
    }
    private func groups() throws -> [[String: Any]] {
        let files = FileManager.default.enumerator(at: fixture.appendingPathComponent("Library"), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.lastPathComponent.hasPrefix("group.") && $0.pathExtension == "json" }.compactMap {
            try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any]
        }.filter { $0["deleted"] as? Bool != true }
    }
    private func customTemplates() throws -> [[String: Any]] {
        try groups().flatMap { $0["templates"] as? [[String: Any]] ?? [] }.filter { $0["deleted"] as? Bool != true }
    }
    private func templateFile(_ template: [String: Any]) throws -> URL {
        let name = try XCTUnwrap(template["file"] as? String)
        let files = FileManager.default.enumerator(at: fixture.appendingPathComponent("Library"), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try XCTUnwrap(files.first { $0.lastPathComponent == name }, "Imported custom-template file must exist")
    }
}
