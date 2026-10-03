import XCTest

/// Black-box coverage for the library inventory. Each launch uses the real isolated library;
/// mutations are exclusively taps, keyboard input and touch gestures, never command injection.
@MainActor
final class LibraryUITests: XCTestCase {
    private var ui: NibUI!
    private var app: XCUIApplication { ui.app }
    private let physics = "Physics — Motion"
    private let folder = "Semester Notes"
    private let rootDocuments = ["Concept map", "Lab report", "Motion flashcards", "Physics — Motion"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        try ui.launchFixture()
        try visible(item(physics), "Seeded library must be ready")
    }

    override func tearDownWithError() throws {
        if let ui {
            let screenshot = XCTAttachment(screenshot: ui.app.screenshot())
            screenshot.name = name + "-library-screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let tree = XCTAttachment(string: ui.app.debugDescription)
            tree.name = name + "-accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let probe = XCTAttachment(string: String(describing: ui.probe.value))
            probe.name = name + "-nib.qa.state"
            probe.lifetime = .keepAlways
            add(probe)
            ui.app.terminate()
        }
    }

    private func matching(_ label: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
    }

    private func item(_ title: String, folder: Bool = false) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: folder ? "cmd.library.setView" : "cmd.doc.open")
            .matching(matching(title)).firstMatch
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(matching(label)).firstMatch
    }

    private func visible(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 12,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail(message, file: file, line: line)
            throw NibUI.Failure.message(message)
        }
    }

    private func eventually(_ message: String, timeout: TimeInterval = 12,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail(message, file: file, line: line)
            throw NibUI.Failure.message(message)
        }
    }

    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let candidates = app.buttons.matching(matching(label))
        if !candidates.firstMatch.isHittable { revealFormElement(candidates.firstMatch) }
        try visible(candidates.firstMatch, "Missing action: \(label)", file: file, line: line)
        let target = candidates.allElementsBoundByIndex.last!
        for _ in 0..<5 where !target.isHittable {
            guard let scroll = app.scrollViews.allElementsBoundByIndex.last(where: {
                $0.buttons.matching(self.matching(label)).count > 0
            }) else { break }
            if target.frame.midY < scroll.frame.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        guard target.isHittable && target.isEnabled else {
            XCTFail("Action is not enabled and hittable: \(label)", file: file, line: line)
            throw NibUI.Failure.message("Cannot activate \(label)")
        }
        let inList = app.collectionViews.allElementsBoundByIndex.contains {
            $0.buttons.matching(self.matching(label)).count > 0
        }
        // A row can be partly clipped by a fitted sheet. XCTest chooses its visible
        // hit point; a normalized centre could fall outside that sheet's scroll viewport.
        if inList { revealFormElement(target); target.tap() }
        else { target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    private func library() throws {
        _ = try ui.waitForState(timeout: 12) { $0.screen == "library" && $0.document == nil }
    }

    private func backFromDocument() throws {
        try ui.tapCommand("window.showLibrary")
        try library()
    }

    private func destination(_ title: String) throws {
        if !button(title).isHittable, button("Show Library").isHittable { try tap("Show Library") }
        try tap(title)
        try library()
    }

    private func openFolder(_ title: String) throws {
        let tile = item(title, folder: true)
        try visible(tile, "Folder missing: \(title)")
        tile.tap()
        try visible(app.staticTexts[title].firstMatch, "Folder title must be \(title)")
        try library()
    }

    private func context(_ title: String, folder: Bool = false) throws {
        let tile = item(title, folder: folder)
        try visible(tile, "Context-menu target missing: \(title)")
        tile.press(forDuration: 1)
        try visible(button("Rename"), "Long press must open the item context menu")
    }

    private func outside() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.10)).tap()
    }

    private func cancelConfirmation() throws {
        // iPad presents confirmationDialog as a popover and may omit its Cancel row.
        // Tapping the inert Library heading is the system cancellation gesture there.
        if button("Cancel").isHittable { try tap("Cancel") }
        else { outside() }
    }

    private func option(_ title: String) throws {
        try tap("Sort and View")
        // Identify the panel by its own accessible title. Manual is the eighth
        // sort row and can lie outside the native scroll view's accessibility viewport.
        let menu = app.scrollViews.matching(matching("Sort and View")).firstMatch
        try visible(menu, "Sort and View must present its options")
        try eventually("Sort and View must be interactive") { menu.isHittable }
        let choice = menu.buttons.matching(matching(title)).firstMatch
        for _ in 0..<5 where !choice.exists || !choice.isHittable { menu.swipeUp() }
        try visible(choice, "Sort and View is missing \(title)")
        XCTAssertTrue(choice.isEnabled, "View option must be enabled: \(title)")
        choice.tap()
    }

    private func layout(_ title: String) throws {
        try option(title)
        outside()
    }

    private func documentOrder() -> [String] {
        let elements = app.descendants(matching: .any).matching(identifier: "cmd.doc.open").allElementsBoundByIndex
        var seen = Set<String>()
        // Read each accessibility property once; sorting must not repeatedly query a changing UI.
        let rows = elements.map { (label: $0.label, frame: $0.frame) }.filter { $0.frame.width > 0 }
        return rows.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 8 { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }.compactMap { row in
            let title = rootDocuments.first { row.label == $0 || row.label.hasPrefix($0 + ",") }
            guard let title, seen.insert(title).inserted else { return nil }
            return title
        }
    }

    private func revealFormElement(_ element: XCUIElement) {
        ui.revealFormElement(element)
    }

    private func replace(_ field: XCUIElement, with text: String) throws {
        revealFormElement(field)
        try visible(field, "Editable text field missing")
        field.tap()
        let value = field.value as? String ?? ""
        if !value.isEmpty && value != field.placeholderValue {
            field.typeKey("a", modifierFlags: .command)
        }
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }

    private func createFolder(_ title: String) throws {
        try tap("New")
        try tap("New Folder")
        _ = try ui.waitForState { $0.openPanels.contains("organize.folder.new") }
        try replace(app.textFields["Folder name"], with: title)
        try tap("Create Folder")
        try eventually("Creation sheet must dismiss before opening its new folder") { !self.app.textFields["Folder name"].exists }
        try visible(item(title, folder: true), "Created folder must appear in its current parent")
    }

    private func trash(_ title: String, folder: Bool = false) throws {
        try context(title, folder: folder)
        try tap("Move to Trash")
        try tap("Move to Trash")
        try eventually("Confirmed trash must remove \(title) from the current folder") {
            !self.item(title, folder: folder).exists
        }
    }

    private func trashRow(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(matching(title)).allElementsBoundByIndex
            .first { $0.isHittable && ($0.elementType == .button || $0.elementType == .cell) }
            ?? app.staticTexts[title].firstMatch
    }

    private func trashContext(_ title: String) throws {
        let row = trashRow(title)
        try visible(row, "Trash context target missing: \(title)")
        try eventually("Trash row must settle before opening its menu") { row.isHittable }
        // Press the labelled leading part of the row, clear of trailing swipe-action space.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 1)
        try visible(button("Recover"), "Trash long press must expose Recover")
    }

    private func assertRootItems() throws {
        for title in rootDocuments { try visible(item(title), "Root document missing: \(title)") }
        try visible(item(folder, folder: true), "Root folder missing")
        XCTAssertFalse(item("Lecture notes").exists, "Descendant must not leak into root")
    }

    // library.documents, library.folderDisclosure
    func testDocumentsFoldersAndBreadcrumbs() throws {
        try destination("Documents")
        try assertRootItems()
        try openFolder(folder)
        try visible(item("Lecture notes"), "Folder must contain its own notebook")
        XCTAssertFalse(item(physics).exists)
        try tap("Back to Documents")
        try assertRootItems()
        try library()
    }

    func testFoldersDisclosureExpandsAndCollapsesWithoutOpeningDocument() throws {
        let before = app.buttons.matching(matching(folder)).count
        try tap("Folders")
        try eventually("Expanding Folders must reveal sidebar folder navigation") {
            self.app.buttons.matching(self.matching(self.folder)).count > before
        }
        try library()
        try tap("Folders")
        try eventually("Collapsing Folders must remove sidebar children") {
            self.app.buttons.matching(self.matching(self.folder)).count == before
        }
        try assertRootItems()
        try library()
    }

    // library.tabs: separate tests prevent one missing destination masking the others.
    func testFavouritesDestinationEmptyState() throws {
        try destination("Favourites")
        try visible(app.staticTexts["No favourites yet"], "Favourites must show its empty state")
    }
    func testSharedDestinationEmptyState() throws {
        try destination("Shared")
        try visible(app.staticTexts["Nothing shared yet"], "Shared must show its empty state")
        XCTAssertFalse(item(physics).exists, "Private fixture notebook must not appear in Shared")
    }
    func testRecentsTracksOpenedDocument() throws {
        try ui.openDocument(physics)
        let id = try XCTUnwrap(ui.state().document)
        try backFromDocument()
        try destination("Recents")
        try ui.openDocument(physics)
        XCTAssertEqual(try ui.state().document, id)
    }
    func testStudySetsDestinationFiltersKinds() throws {
        try destination("Study Sets")
        try visible(item("Motion flashcards"), "Study Sets must include the seeded study set")
        for title in [physics, "Concept map", "Lab report"] { XCTAssertFalse(item(title).exists) }
    }
    func testGalleryDestination() throws {
        try destination("Gallery")
        try visible(app.staticTexts["Gallery"].firstMatch, "Gallery must display its own panel")
        try visible(app.descendants(matching: .any)["Search Gallery"].firstMatch,
                    "Gallery must offer its own plugin and content search")
        XCTAssertFalse(item(physics).exists)
    }
    func testTrashDestinationEmptyState() throws {
        try destination("Trash")
        try visible(app.staticTexts["Trash is empty"], "Fresh fixture Trash must be empty")
        XCTAssertFalse(button("Empty Trash").exists, "Empty Trash has no destructive action")
    }

    // library.layout, library.sort, library.filter
    func testGridAndListPreserveItemsAndRememberLayout() throws {
        try layout("List")
        try assertRootItems()
        XCTAssertEqual(Set(rootDocuments.map { item($0).frame.minX }).count, 1, "List rows must align")
        let listHeight = item(physics).frame.height
        try openFolder(folder)
        try tap("Back to Documents")
        XCTAssertEqual(item(physics).frame.height, listHeight, accuracy: 2, "List layout must persist")
        try layout("Grid")
        try assertRootItems()
        XCTAssertGreaterThan(item(physics).frame.height, listHeight, "Grid must restore covers")
        try openFolder(folder)
        try tap("Back to Documents")
        XCTAssertGreaterThan(item(physics).frame.height, listHeight, "Grid layout must persist")
    }

    private func checkSort(_ sort: String, expected: [String]) throws {
        try layout("List")
        try option(sort)
        try eventually("\(sort) must order the seeded documents by its criterion") { self.documentOrder() == expected }
        try openFolder(folder)
        try option("Name, Z to A")
        try tap("Back to Documents")
        XCTAssertEqual(documentOrder(), expected, "Root sort must survive a different per-folder sort")
        try visible(app.staticTexts["5 items · " + sort], "Sort choice must persist in folder subtitle")
        try openFolder(folder)
        try visible(app.staticTexts["1 item · Name, Z to A"], "Child sort must be remembered independently")
    }
    func testSortModifiedNewest() throws {
        try checkSort("Date modified", expected: ["Motion flashcards", "Lab report", "Concept map", physics])
    }
    func testSortModifiedOldest() throws {
        try checkSort("Modified, oldest first", expected: [physics, "Concept map", "Lab report", "Motion flashcards"])
    }
    func testSortCreatedNewest() throws {
        try checkSort("Date created", expected: ["Motion flashcards", "Lab report", "Concept map", physics])
    }
    func testSortCreatedOldest() throws {
        try checkSort("Created, oldest first", expected: [physics, "Concept map", "Lab report", "Motion flashcards"])
    }
    func testSortNameAscending() throws { try checkSort("Name, A to Z", expected: rootDocuments) }
    func testSortNameDescending() throws { try checkSort("Name, Z to A", expected: Array(rootDocuments.reversed())) }
    func testSortType() throws {
        try checkSort("Type", expected: [physics, "Motion flashcards", "Lab report", "Concept map"])
    }
    func testSortManualRemembersOrderAfterOtherSort() throws {
        try layout("List")
        try option("Manual")
        let manual = documentOrder()
        XCTAssertEqual(Set(manual), Set(rootDocuments))
        try option("Name, Z to A")
        try option("Manual")
        XCTAssertEqual(documentOrder(), manual, "Manual order must survive another sorting choice")
        try openFolder(folder)
        try tap("Back to Documents")
        XCTAssertEqual(documentOrder(), manual)
    }
    func testTypeFiltersAndRestoreAllItems() throws {
        try option("Documents")
        for title in rootDocuments { try visible(item(title), "Documents filter lost \(title)") }
        XCTAssertFalse(item(folder, folder: true).exists)
        try option("Folders")
        try visible(item(folder, folder: true), "Folders filter must retain folders")
        XCTAssertTrue(documentOrder().isEmpty)
        try option("All items")
        try assertRootItems()
    }

    // library.select, library.openSelection, doc.open
    func testSelectionToggleSelectAllAndDone() throws {
        try tap("Select Items")
        item(physics).tap()
        XCTAssertTrue(item(physics).isSelected, "Tapped cover must show selected state")
        XCTAssertTrue(button("Duplicate").isEnabled)
        item(physics).tap()
        XCTAssertFalse(item(physics).isSelected)
        app.typeKey("a", modifierFlags: .command)
        try eventually("Command-A must select all visible documents and the folder") {
            self.rootDocuments.allSatisfy { self.item($0).isSelected } && self.item(self.folder, folder: true).isSelected
        }
        for title in rootDocuments { XCTAssertTrue(item(title).isSelected, "Command-A must select \(title)") }
        XCTAssertTrue(item(folder, folder: true).isSelected)
        try tap("Finish Selecting")
        for title in rootDocuments { XCTAssertFalse(item(title).isSelected) }
        XCTAssertFalse(button("Finish Selecting").exists)
        try tap("Select Items")
        item(physics).tap()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertFalse(item(physics).isSelected, "Escape must clear selection")
        XCTAssertFalse(button("Finish Selecting").exists)
    }
    func testSelectionDoneAndEscapeClearSelection() throws {
        try tap("Select Items")
        item(physics).tap()
        XCTAssertTrue(item(physics).isSelected)
        try tap("Finish Selecting")
        try eventually("Done must exit selection and clear the checked cover") {
            !self.item(self.physics).isSelected && !self.button("Finish Selecting").exists
        }
        try tap("Select Items")
        item(physics).tap()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        try eventually("Escape must exit selection and clear the checked cover") {
            !self.item(self.physics).isSelected && !self.button("Finish Selecting").exists
        }
        try library()
    }
    func testReturnOpensSelectedDocument() throws {
        try ui.openDocument(physics)
        let id = try XCTUnwrap(ui.state().document)
        try backFromDocument()
        try tap("Select Items")
        item(physics).tap()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        _ = try ui.waitForState(timeout: 12) { $0.screen == "document" && $0.document == id }
    }
    func testReturnOpensSelectedFolder() throws {
        try tap("Select Items")
        item(folder, folder: true).tap()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        try visible(item("Lecture notes"), "Return must open the selected folder")
        try library()
    }
    func testOpenEveryDocumentKindAndIdentity() throws {
        var ids = Set<String>()
        for title in rootDocuments {
            try ui.openDocument(title)
            let state = try ui.state()
            let id = try XCTUnwrap(state.document)
            XCTAssertTrue(ids.insert(id).inserted, "Each cover must open a different document")
            if title == physics { XCTAssertEqual(state.pageCount, 4); XCTAssertGreaterThan(state.strokeCountOnPage, 0) }
            try backFromDocument()
            try ui.openDocument(title)
            XCTAssertEqual(try ui.state().document, id, "Reopening \(title) must preserve identity")
            try backFromDocument()
        }
    }

    // library.context, library.rename
    func testDocumentContextMenuActionsAndFolderApplicability() throws {
        try context(physics)
        for label in ["Rename", "Duplicate", "Move", "Move to Trash", "Add to Favourites"] {
            XCTAssertTrue(button(label).isEnabled, "Document action must be enabled: \(label)")
        }
        XCTAssertFalse(button("Customise Folder").exists)
        outside()
        try context(folder, folder: true)
        for label in ["Rename", "Duplicate", "Move", "Move to Trash", "Customise Folder"] {
            XCTAssertTrue(button(label).isEnabled, "Folder action must be enabled: \(label)")
        }
        try tap("Customise Folder")
        revealFormElement(app.textFields["Folder name"])
        try visible(app.textFields["Folder name"], "Folder context action must open its editor")
    }
    private func checkRename(_ original: String, isFolder: Bool) throws {
        try context(original, folder: isFolder)
        try tap("Rename")
        let field = app.textFields["Rename " + original]
        try replace(field, with: "Cancelled title")
        try tap("Cancel Rename")
        try visible(item(original, folder: isFolder), "Cancel must preserve original name")
        XCTAssertFalse(item("Cancelled title", folder: isFolder).exists)
        try context(original, folder: isFolder)
        try tap("Rename")
        try replace(field, with: "")
        try tap("Save Name")
        XCTAssertTrue(field.exists, "Empty names must be rejected")
        try replace(field, with: "Renamed item")
        try tap("Save Name")
        try visible(item("Renamed item", folder: isFolder), "Valid rename must update the visible item")
        XCTAssertFalse(item(original, folder: isFolder).exists)
        try destination("Favourites")
        try destination("Documents")
        try visible(item("Renamed item", folder: isFolder), "Rename must persist after navigation")
    }
    func testRenameDocumentConfirmCancelAndInvalidInput() throws { try checkRename(physics, isFolder: false) }
    func testRenameFolderConfirmCancelAndInvalidInput() throws { try checkRename(folder, isFolder: true) }

    // library.move, library.movePicker
    func testMoveDocumentOnlyRelocatesChosenItem() throws {
        try context(physics)
        try tap("Move")
        try visible(app.staticTexts["Move Items"], "Move must open destination picker")
        try tap(folder)
        try tap("Move Here")
        try eventually("Moved notebook must leave root") { !self.item(self.physics).exists }
        try visible(item("Lab report"), "Unselected sibling must remain in root")
        try openFolder(folder)
        try visible(item(physics), "Moved notebook must arrive at destination")
        try visible(item("Lecture notes"), "Existing destination child must remain")
    }
    func testBatchMoveOnlyRelocatesSelection() throws {
        try tap("Select Items")
        item(physics).tap(); item("Lab report").tap()
        try tap("Move")
        try tap(folder)
        try tap("Move Here")
        try eventually("Batch move must remove both selected documents") {
            !self.item(self.physics).exists && !self.item("Lab report").exists
        }
        try visible(item("Concept map"), "Unselected document must remain")
        if button("Finish Selecting").exists { try tap("Finish Selecting") }
        try openFolder(folder)
        try visible(item(physics), "First batch member missing at destination")
        try visible(item("Lab report"), "Second batch member missing at destination")
    }
    func testMovePickerNewFolderNavigationAndCancel() throws {
        try context(physics); try tap("Move")
        try tap(folder)
        try tap("Library Root")
        try replace(app.textFields["New folder name"], with: "Move destination")
        try tap("Create Folder")
        try visible(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Move destination")).firstMatch,
                    "New folder must become picker destination")
        try tap("Cancel")
        try visible(item(physics), "Cancel must not move the source")
        try visible(item("Move destination", folder: true), "Explicitly created folder must remain after cancelling move")
        try context(physics); try tap("Move"); try tap("Move destination"); try tap("Move Here")
        try openFolder("Move destination")
        try visible(item(physics), "Move Here must use the new folder")
    }
    func testMoveFolderExcludesItselfAndDescendants() throws {
        try openFolder(folder)
        try createFolder("Child")
        try tap("Back to Documents")
        try createFolder("Destination")
        try context(folder, folder: true); try tap("Move")
        XCTAssertFalse(button(folder).isHittable, "Cannot move a folder into itself")
        let allFolders = app.switches["All folders"]
        try visible(allFolders, "Move picker must offer recursive folder browsing")
        allFolders.tap()
        XCTAssertFalse(button("Child").exists, "Cannot move a folder into its own descendant")
        try tap("Destination"); try tap("Move Here")
        try eventually("Moved folder must leave root") { !self.item(self.folder, folder: true).exists }
        try openFolder("Destination"); try openFolder(folder)
        try visible(item("Lecture notes"), "Folder move must retain document descendants")
        try visible(item("Child", folder: true), "Folder move must retain nested folders")
    }

    // library.duplicate: prove identity, content and independence with real ink.
    func testDuplicateNotebookPreservesContentAndIsIndependent() throws {
        try ui.openDocument(physics)
        let original = try ui.state()
        try backFromDocument()
        try context(physics); try tap("Duplicate")
        try ui.openDocument(physics + " copy")
        let copy = try ui.state()
        XCTAssertNotEqual(copy.document, original.document)
        XCTAssertEqual(copy.pageCount, original.pageCount)
        XCTAssertEqual(copy.strokeCountOnPage, original.strokeCountOnPage)
        XCTAssertEqual(copy.itemCountOnPage, original.itemCountOnPage)
        try ui.selectTool("pen")
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.7)])
        _ = try ui.waitForState { $0.strokeCountOnPage == copy.strokeCountOnPage + 1 }
        try backFromDocument()
        try ui.openDocument(physics)
        XCTAssertEqual(try ui.state().strokeCountOnPage, original.strokeCountOnPage, "Copy edits must not change original")
    }
    func testDuplicateFolderPreservesIndependentDescendants() throws {
        try openFolder(folder); try ui.openDocument("Lecture notes")
        let original = try ui.state()
        try backFromDocument(); try destination("Documents")
        try context(folder, folder: true); try tap("Duplicate")
        try openFolder(folder + " copy"); try ui.openDocument("Lecture notes")
        let copy = try ui.state()
        XCTAssertNotEqual(copy.document, original.document)
        XCTAssertEqual(copy.pageCount, original.pageCount)
        try backFromDocument()
        try context("Lecture notes"); try tap("Rename")
        try replace(app.textFields["Rename Lecture notes"], with: "Independent child")
        try tap("Save Name")
        try destination("Documents"); try openFolder(folder)
        try visible(item("Lecture notes"), "Renaming copied descendant must preserve original descendant")
        XCTAssertFalse(item("Independent child").exists)
    }

    // doc.setFavorite, organize.favourites, folder.setStyle, folder.create
    func testFavouriteOpenAndUnstarUpdatesMembership() throws {
        try ui.openDocument(physics)
        let id = try XCTUnwrap(ui.state().document)
        try backFromDocument()
        try context(physics); try tap("Add to Favourites")
        try eventually("Star must be exposed on document") { (self.item(self.physics).value as? String)?.contains("Favourite") == true }
        try destination("Favourites")
        try tap(physics)
        _ = try ui.waitForState { $0.screen == "document" && $0.document == id }
        try backFromDocument(); try destination("Favourites")
        button(physics).press(forDuration: 1)
        try tap("Remove from Favourites")
        try visible(app.staticTexts["No favourites yet"], "Unstar must remove Favourites membership")
        try destination("Documents")
        try visible(item(physics), "Documents must show the unstarred notebook")
        XCTAssertFalse((item(physics).value as? String)?.contains("Favourite") == true)
    }
    func testFolderStyleColourIconAndFavouritePersist() throws {
        try context(folder, folder: true); try tap("Customise Folder")
        try replace(app.textFields["Hex colour"], with: "#FF8800")
        try tap("Emoji")
        try replace(app.textFields["Emoji"], with: "📚")
        let favourite = app.switches["Show in Favourites"]
        revealFormElement(favourite)
        try visible(favourite, "Folder style must offer favourite toggle")
        favourite.tap()
        try tap("Save Changes")
        try eventually("Folder style sheet must dismiss before reopening its context menu") { !self.app.textFields["Folder name"].exists }
        try context(folder, folder: true); try tap("Customise Folder")
        revealFormElement(app.textFields["Hex colour"])
        XCTAssertEqual(app.textFields["Hex colour"].value as? String, "#FF8800")
        revealFormElement(app.textFields["Emoji"])
        XCTAssertEqual(app.textFields["Emoji"].value as? String, "📚")
        revealFormElement(favourite)
        XCTAssertEqual(favourite.value as? String, "1")
        try tap("Cancel")
        try destination("Favourites")
        try tap(folder)
        try visible(item("Lecture notes"), "Favourite folder must open its children")
    }
    func testCreateFolderSubfolderAndCancel() throws {
        try createFolder("New parent")
        try openFolder("New parent")
        try visible(button("Back to Documents"), "Opening the new parent must enter that folder")
        try createFolder("New child")
        try tap("New"); try tap("New Folder")
        try replace(app.textFields["Folder name"], with: "Cancelled folder")
        try tap("Cancel")
        XCTAssertFalse(item("Cancelled folder", folder: true).exists)
        try visible(item("New child", folder: true), "Subfolder must be created in current parent")
        try tap("Back to Documents")
        XCTAssertFalse(item("New child", folder: true).exists)
    }
    func testNewFolderKeyboardShortcutUsesCurrentParent() throws {
        try openFolder(folder)
        app.typeKey("n", modifierFlags: [.control, .command])
        _ = try ui.waitForState { $0.openPanels.contains("organize.folder.new") }
        try replace(app.textFields["Folder name"], with: "Keyboard child")
        try tap("Create Folder")
        try visible(item("Keyboard child", folder: true), "Control-Command-N must create in current folder")
    }

    // library.trash, organize.trash, trash.recover, trash.deletePermanently, trash.empty
    func testTrashCancelAndConfirmDocumentAndFolder() throws {
        try context(physics); try tap("Move to Trash"); try cancelConfirmation()
        try visible(item(physics), "Cancel must preserve document")
        try trash(physics)
        try trash(folder, folder: true)
        try destination("Trash")
        try visible(trashRow(physics), "Trashed document must be listed")
        try visible(trashRow(folder), "Trashed folder must be listed")
        try tap("Select"); trashRow(physics).tap()
        try visible(app.staticTexts["1 selected"], "Trash selection must count selected rows")
        try tap("Select All")
        try visible(app.staticTexts["2 selected"], "Trash Select All must select document and folder")
        try tap("Done")
        XCTAssertFalse(app.staticTexts["2 selected"].exists)
    }
    func testRecoverTrashedDocumentAndFolderToOriginalLocation() throws {
        try trash(physics); try trash(folder, folder: true)
        try destination("Trash")
        try trashContext(folder); try tap("Recover")
        try eventually("Recovered folder must leave Trash") { !self.trashRow(self.folder).exists }
        try trashContext(physics); try tap("Recover")
        try visible(app.staticTexts["Trash is empty"], "Recovered items must leave Trash")
        try destination("Documents"); try assertRootItems()
        try openFolder(folder); try visible(item("Lecture notes"), "Recover folder must restore descendants")
    }
    func testMoveTrashedDocumentToChosenDestination() throws {
        try trash(physics); try destination("Trash")
        try trashContext(physics); try tap("Move")
        try tap(folder); try tap("Move Here")
        try visible(app.staticTexts["Trash is empty"], "Move must remove entry from Trash")
        try destination("Documents")
        XCTAssertFalse(item(physics).exists)
        try openFolder(folder); try visible(item(physics), "Recovered document must use chosen destination")
    }
    func testDeletePermanentlyCancelThenOnlySelectedEntry() throws {
        try trash(physics); try trash("Lab report")
        try destination("Trash")
        try trashContext(physics); try tap("Delete Permanently"); try cancelConfirmation()
        try visible(trashRow(physics), "Cancel permanent delete must preserve entry")
        try trashContext(physics); try tap("Delete Permanently"); try tap("Delete 1 item")
        try eventually("Confirmed permanent deletion must remove selected entry") { !self.trashRow(self.physics).exists }
        try visible(trashRow("Lab report"), "Unselected trash must survive permanent deletion")
        try destination("Documents")
        XCTAssertFalse(item(physics).exists)
        try destination("Trash")
        XCTAssertFalse(trashRow(physics).exists, "Permanently deleted item must stay absent")
    }
    func testEmptyTrashCancelAndConfirm() throws {
        try trash(physics); try trash(folder, folder: true)
        try destination("Trash"); try tap("Empty Trash"); try cancelConfirmation()
        try visible(trashRow(physics), "Cancel Empty Trash must retain document")
        try visible(trashRow(folder), "Cancel Empty Trash must retain folder")
        try tap("Empty Trash"); try tap("Delete 2 items")
        try visible(app.staticTexts["Trash is empty"], "Confirmed Empty Trash must empty all entries")
        try destination("Documents")
        XCTAssertFalse(item(physics).exists); XCTAssertFalse(item(folder, folder: true).exists)
        try visible(item("Lab report"), "Empty Trash must preserve live documents")
    }

    // library.reorder, library.dragFolder, doc.merge
    func testDragReorderPersistsManualOrderAndUndoRestoresIt() throws {
        try option("Name, A to Z")
        let before = documentOrder()
        let source = item(physics).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let gap = item("Concept map").coordinate(withNormalizedOffset: CGVector(dx: -0.07, dy: 0.3))
        source.press(forDuration: 0.4, thenDragTo: gap, withVelocity: .slow, thenHoldForDuration: 0.3)
        let expected = [physics, "Concept map", "Lab report", "Motion flashcards"]
        try eventually("Drag to sibling gap must move last cover to first") { self.documentOrder() == expected }
        try visible(app.staticTexts["5 items · Manual"], "Reorder must choose Manual sort")
        try openFolder(folder); try tap("Back to Documents")
        XCTAssertEqual(documentOrder(), expected, "Drag order must persist")
        app.typeKey("z", modifierFlags: .command)
        try eventually("Undo must restore the complete previous sibling order") { self.documentOrder() == before }
    }
    func testDragDocumentIntoFolderAndToastUndo() throws {
        item(physics).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.4, thenDragTo: item(folder, folder: true).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        try eventually("Folder drop must move document out of root") { !self.item(self.physics).exists }
        try tap("Undo")
        try visible(item(physics), "Toast Undo must restore original parent")
        try openFolder(folder)
        XCTAssertFalse(item(physics).exists, "Undo must remove document from drop destination")
    }
    func testCombineNotebooksRequiresConfirmationAndPreservesPages() throws {
        try context(physics); try tap("Duplicate")
        let copy = physics + " copy"
        try visible(item(copy), "Combine needs a second notebook")
        item(copy).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.4, thenDragTo: item(physics).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.7)
        try tap("Combine")
        try eventually("Combined source must leave library") { !self.item(copy).exists }
        try ui.openDocument(physics)
        XCTAssertEqual(try ui.state().pageCount, 8, "Combining two four-page notebooks must retain all pages")
        try backFromDocument(); try destination("Trash")
        try visible(trashRow(copy), "Combined source must be recoverable in Trash")
    }

    // library.newMenu, library.searchEntry, library.appMenu, library.emptyActions, library.syncBadge
    func testNewMenuDismissOutsideAndCreationEntries() throws {
        try tap("New")
        try eventually("New must reveal its creation entries") {
            self.app.scrollViews.allElementsBoundByIndex.contains {
                $0.buttons.matching(self.matching("Notebook")).count > 0
            }
        }
        let menu = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.first {
            $0.buttons.matching(self.matching("Notebook")).count > 0
        }, "New must open its creation menu")
        for label in ["Notebook", "QuickNote", "Whiteboard", "Text Document", "Study Set", "Import Files", "Scan Document"] {
            let entry = menu.buttons.matching(matching(label)).firstMatch
            for _ in 0..<8 where !entry.isHittable { menu.swipeUp() }
            try visible(entry, "New menu must offer \(label)")
            XCTAssertTrue(entry.isEnabled && entry.isHittable, "New menu entry must be reachable: \(label)")
        }
        outside()
        XCTAssertFalse(button("Import Files").exists, "Outside tap must dismiss New menu")
        try library()
        try tap("New"); try tap("Notebook")
        try eventually("New Notebook must open creation panel") { (try? self.ui.state().openPanels.isEmpty) == false }
    }
    func testQuickNoteMenuCreatesDocumentInCurrentFolder() throws {
        try openFolder(folder); try tap("New"); try tap("QuickNote")
        _ = try ui.waitForState { $0.screen == "document" && $0.document != nil }
        try backFromDocument()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "cmd.doc.open").count, 2,
                       "QuickNote must be created alongside Lecture notes")
    }
    private func searchFocused() throws {
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND label CONTAINS[cd] 'Search'",
            XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textField.rawValue)).firstMatch
        try visible(field, "Library search must present a field")
        // Type without tapping: this verifies initial keyboard focus, not merely field existence.
        app.typeText("Physics")
        try eventually("Search entry must focus its text field") { (field.value as? String)?.contains("Physics") == true }
        try library()
    }
    func testSearchButtonFocusesLibrarySearch() throws { try ui.tapCommand("search.open"); try searchFocused() }
    func testCommandFFocusesLibrarySearch() throws { app.typeKey("f", modifierFlags: .command); try searchFocused() }
    func testCommandOFocusesLibrarySearch() throws { app.typeKey("o", modifierFlags: .command); try searchFocused() }
    private func appMenu(_ title: String, expected: String) throws {
        try tap("App Menu")
        // Trash also exists in the sidebar; command identity disambiguates the app-menu entry.
        let entry = app.buttons.matching(identifier: "cmd.settings.open").matching(matching(title)).firstMatch
        try visible(entry, "App Menu must offer \(title)")
        entry.tap()
        let panels = ["Manage Templates": "templateui.manage", "Cloud & Backup": "syncui.panel", "About Nib": "about.panel"]
        if let panel = panels[title] {
            _ = try ui.waitForState(timeout: 12) { $0.openPanels.contains(panel) }
        }
        if title == "About Nib" {
            let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Nib, Version ")).firstMatch
            revealFormElement(version)
            try visible(version, "About must display Nib's version information")
        } else {
            try visible(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", expected)).firstMatch,
                        "\(title) must open its destination")
        }
        try library()
    }
    func testAppMenuSettings() throws { try appMenu("Settings", expected: "Settings") }
    func testAppMenuTemplates() throws { try appMenu("Manage Templates", expected: "Notebook Templates") }
    func testAppMenuCloudBackup() throws { try appMenu("Cloud & Backup", expected: "Cloud & Backup") }
    func testAppMenuTrash() throws { try appMenu("Trash", expected: "Trash is empty") }
    func testAppMenuAbout() throws { try appMenu("About Nib", expected: "About Nib") }
    func testEmptyFolderNewNotebookAction() throws {
        try openFolder(folder); try trash("Lecture notes")
        try tap("New Notebook")
        try eventually("Empty-state New Notebook must open creation sheet") { (try? self.ui.state().openPanels.isEmpty) == false }
        try visible(app.textFields.firstMatch, "Creation sheet must accept a title")
    }
    func testEmptyFolderImportAction() throws {
        try openFolder(folder); try trash("Lecture notes")
        try tap("Import")
        try visible(app.cells["DOC.sidebar.item.On My iPad"], "Empty-state Import must open system file picker")
        try tap("Cancel")
        try library()
        try visible(app.staticTexts[folder].firstMatch, "Cancelling import must retain current folder")
    }
    func testLibrarySyncBadgeShowsLibraryDetails() throws {
        try tap("Cloud & Backup")
        try visible(app.staticTexts["Cloud & Backup"], "Sync badge must open Cloud & Backup")
        try visible(button("Sync Now"), "Library sync panel must show library actions")
        XCTAssertFalse(app.staticTexts["Document Sync"].exists, "Library status must not claim a selected document")
        try library()
    }
    func testDocumentSyncDetailsMatchSelectedDocument() throws {
        try context(physics)
        let sync = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sync:")).firstMatch
        try visible(sync, "Document menu must offer sync details")
        sync.tap()
        try visible(app.staticTexts["Document Sync"], "Item sync details must include Document Sync")
        try visible(app.staticTexts[physics].firstMatch, "Sync details must identify the selected notebook")
        try library()
    }

    func testTrashPageBrowsingSelectionAndRecovery() throws {
        try ui.openDocument(physics)
        let original = try ui.state()
        try tap("More")
        // The iPad menu renders This Page as a section heading. Scroll to and tap its
        // actual Move to Trash action rather than trying to activate the heading.
        try tap("Move to Trash")
        if button("Move to Trash").isHittable { try tap("Move to Trash") }
        _ = try ui.waitForState { $0.pageCount == original.pageCount - 1 }
        try backFromDocument(); try destination("Trash")
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page 1'")).firstMatch
        try visible(page, "Trash must include deleted pages with their document details")
        try tap("Select"); page.tap()
        try visible(app.staticTexts["1 selected"], "Page selection must have its own action scope")
        try tap("Recover 1 item")
        try visible(app.staticTexts["Trash is empty"], "Recovered page must leave Trash")
        try destination("Documents"); try ui.openDocument(physics)
        XCTAssertEqual(try ui.state().document, original.document)
        XCTAssertEqual(try ui.state().pageCount, original.pageCount)
        // Restoring a page need not change the editor's current page. Navigate to the
        // recovered first page before comparing its content with the pre-trash snapshot.
        if try ui.state().page != original.page {
            try tap("More"); try tap("Go to Page…")
            try replace(app.textFields["Page number or title"], with: "1")
            try tap("Go")
        }
        _ = try ui.waitForState { $0.page == original.page }
        XCTAssertEqual(try ui.state().strokeCountOnPage, original.strokeCountOnPage,
                       "Recovery must preserve page ink")
    }

    // library.reorderAccessible
    func testAccessibleMoveEarlierLaterAndBoundaries() throws {
        try option("Name, A to Z")
        let before = documentOrder()
        // The visible equivalents call NibReflow.step, the exact handler used by the
        // accessibility custom actions. Simulator runtimes do not provide VoiceOver.
        try context(physics); try tap("Move earlier")
        let earlier = ["Concept map", "Lab report", physics, "Motion flashcards"]
        try eventually("Accessibility Move earlier must move exactly one sibling position") { self.documentOrder() == earlier }
        try context(physics); try tap("Move later")
        try eventually("Accessibility Move later must restore the next sibling position") { self.documentOrder() == before }
        try context(physics); try tap("Move later")
        XCTAssertEqual(documentOrder(), before, "Move later on last sibling must preserve valid boundaries")
        try context("Concept map"); try tap("Move earlier")
        XCTAssertEqual(documentOrder(), before, "Move earlier on first sibling must preserve valid boundaries")
    }

    // library.dropImport
    func testExternalFilesDropImportsIntoCurrentFolder() throws {
        // Loose files at Nib's Documents root are intentionally scanned as imports.
        // Save the external fixture in a plain subfolder so it remains an external payload.
        let fixtureFolder = "Library Drop " + String(UUID().uuidString.prefix(8))
        try context(physics); try tap("Export…")
        try tap("Save to Files")
        let localExport = app.cells["DOC.sidebar.item.On My iPad"]
        try visible(localExport, "Save to Files must offer local storage")
        localExport.tap()
        let exportFolder = app.cells["Nib, Container"]
        if exportFolder.waitForExistence(timeout: 3) {
            exportFolder.tap()
        } else {
            // Files can restore its recently used Nib directory directly instead
            // of showing the On My iPad container list.
            try visible(app.buttons["Nib, Actions Menu"],
                        "External-drop fixture must be in Nib's local Files directory")
        }
        if !button("New Folder").isHittable { try tap("More") }
        try tap("New Folder")
        // DESIGN §13 keeps the native Files picker: its editor may be inline,
        // rather than an alert. This changes setup only; the real drop is still required.
        try ui.nameNewFilesFolder(fixtureFolder)
        let directory = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", fixtureFolder)).firstMatch
        try visible(directory, "Files must create the external fixture folder")
        directory.tap()
        try tap("Save")
        try eventually("Save to Files must finish or report an export error", timeout: 20) {
            !self.app.buttons["Save"].exists || self.app.alerts.firstMatch.exists
        }
        XCTAssertFalse(app.alerts.firstMatch.exists,
                       "External-drop fixture export failed: \(app.alerts.firstMatch.exists ? app.alerts.firstMatch.label : "")")
        try ui.dismissSheets()
        try openFolder(folder); try trash("Lecture notes")
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        let browse = files.buttons["Browse"]
        if browse.isHittable { browse.tap() }
        let local = files.cells["DOC.sidebar.item.On My iPad"]
        if local.isHittable { local.tap() }
        let savedFolder = files.cells["Nib, Container"]
        if savedFolder.isHittable { savedFolder.tap() }
        let fixtureDirectory = files.cells.matching(NSPredicate(format: "label BEGINSWITH %@", fixtureFolder)).firstMatch
        if fixtureDirectory.isHittable { fixtureDirectory.tap() }
        let payload = files.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", physics)).firstMatch
        try visible(payload, "Exported PDF must be available as an external Files drag payload")
        // Use iPad multitasking to expose the destination next to Files. Missing system
        // multitasking controls are reported as shared setup limitations, never as import success.
        let multitasking = files.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'multitasking'")).firstMatch
        try visible(multitasking, "External drop setup requires iPad multitasking controls")
        multitasking.tap()
        let split = files.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'Split View'")).firstMatch
        try visible(split, "External drop setup requires Split View")
        split.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let nib = springboard.icons["Nib"]
        try visible(nib, "Split View must allow choosing Nib as the destination")
        nib.tap()
        let target = app.staticTexts[folder].firstMatch
        try visible(target, "Drop destination must remain visible alongside Files")
        payload.press(forDuration: 0.5, thenDragTo: target)
        // ImportReveal opens a single imported document. Verify its content there,
        // then return to the library to check its persisted destination.
        _ = try ui.waitForState(timeout: 30) { $0.screen == "document" && $0.document != nil }
        XCTAssertEqual(try ui.state().pageCount, 4, "Imported PDF must retain all exported pages")
        try backFromDocument(); try destination("Documents")
        try openFolder(folder)
        try visible(item(physics), "External drop destination must persist")
        try ui.openDocument(physics)
        XCTAssertEqual(try ui.state().pageCount, 4, "Reopening the imported PDF must preserve every page")
    }

}
