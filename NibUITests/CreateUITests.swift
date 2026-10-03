import XCTest
import UIKit

/// Creation is driven exclusively through the UI. The probe supplies live editor identity and ink counts.
/// Read-only package inspection supplements the intentionally small probe for paper, size and metadata
/// (ARCHITECTURE §4.2). It never creates fixtures or invokes commands behind the UI.
@MainActor
final class CreateUITests: XCTestCase {
    private var ui: NibUI!
    private var fixture: URL!
    private var originalPackages: Set<String> = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        try ui.launchFixture()
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let fm = FileManager.default
        let roots = try fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil).flatMap { container in
            (try? fm.contentsOfDirectory(at: container.appendingPathComponent("tmp"),
                                         includingPropertiesForKeys: [.creationDateKey])) ?? []
        }.filter { $0.lastPathComponent.hasPrefix("NibUITests-") }
        fixture = try XCTUnwrap(roots.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.first, "Cannot locate this simulator's isolated fixture packages for read-only assertions")
        originalPackages = Set(packages().map(\.path))
        XCTAssertEqual(originalPackages.count, 5, "Fresh fixture must contain exactly five documents")
    }

    override func tearDownWithError() throws {
        if let ui {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Create-\(name)-screen"
            shot.lifetime = .keepAlways
            add(shot)
            let state = XCTAttachment(string: "\(ui.probe.value ?? "no probe")\n\(ui.app.debugDescription)")
            state.name = "Create-\(name)-state-and-accessibility"
            state.lifetime = .keepAlways
            add(state)
            ui.app.terminate()
        }
    }

    // MARK: Entry, title, kind and cancellation

    func testNotebookKeyboardShortcutOpensDraftAndEscapeCancels() throws {
        ui.app.typeKey("n", modifierFlags: [.command, .alternate])
        try require(ui.app.textFields["Title"], "create.newNotebook: Option-Command-N must open the creation sheet")
        XCTAssertNil(try ui.state().document)
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages)
        try replace(ui.app.textFields["Title"], with: "Escape cancelled draft")
        ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        try wait("create.cancel: Escape must dismiss the creation sheet") { !self.ui.app.textFields["Title"].exists }
        try ui.waitForState { $0.screen == "library" && $0.document == nil }
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages)
    }

    func testDismissCreationSheetLeavesNoPackage() throws {
        try notebook("Dismissed draft")
        let header = ui.app.staticTexts["New Notebook"]
        try require(header, "Creation sheet heading missing")
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: ui.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
        try wait("create.cancel: dismissing the sheet must return to the library") { !self.ui.app.textFields["Title"].exists }
        XCTAssertNil(try ui.state().document)
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages)
    }

    func testNewNotebookOpensWithoutCreatingAndCancelLeavesNoPackage() throws {
        try newMenu("Notebook")
        try require(ui.app.textFields["Title"], "create.newNotebook must present the draft")
        XCTAssertEqual(try ui.state().screen, "library")
        XCTAssertNil(try ui.state().document)
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages)
        try replace(ui.app.textFields["Title"], with: "Cancelled draft")
        try tap("Cancel")
        try ui.waitForState { $0.screen == "library" && $0.document == nil }
        try wait("create.cancel must dismiss the draft") { !self.ui.app.textFields["Title"].exists }
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages, "create.cancel must not leave a package")
    }

    func testTypeSwitchRetainsTitleAndChangesFields() throws {
        try notebook("Retained draft")
        for (kind, heading) in [("Whiteboard", "New Whiteboard"), ("Text document", "New Text Document"),
                                ("Study set", "New Study Set"), ("Notebook", "New Notebook")] {
            try tap(kind)
            XCTAssertEqual(ui.app.textFields["Title"].value as? String, "Retained draft", "create.type lost title")
            try require(ui.app.staticTexts[heading], "create.type must change the sheet heading")
            if kind == "Whiteboard" { try require(ui.app.staticTexts["Background"], "Whiteboard options missing") }
            if kind == "Text document" || kind == "Study set" {
                XCTAssertFalse(ui.app.buttons["No cover"].exists, "Non-notebooks must not offer notebook covers")
            }
        }
        try tap("No cover")
        let id = try create()
        try assertDocument(id, kind: "notebook", pages: 1)
        try backAndAssertTitle("Retained draft", id: id)
    }

    func testCreateTitleProducesExactlyOneDocument() throws {
        try notebook("Creation title")
        try tap("No cover")
        let id = try create()
        try assertDocument(id, kind: "notebook", pages: 1)
        XCTAssertEqual(packages().count, originalPackages.count + 1, "doc.create duplicated the document")
        try backAndAssertTitle("Creation title", id: id)
    }

    func testTypeWhiteboardCreatesBoardWithRetainedTitle() throws {
        try createKind("Whiteboard", title: "Typed board draft", kind: "whiteboard", pages: 1)
        XCTAssertNil(try livePages(XCTUnwrap(ui.state().document)).first?["size"] as? [String: Any])
    }

    func testTypeTextDocumentCreatesEditableDocumentWithRetainedTitle() throws {
        try createKind("Text document", title: "Typed text draft", kind: "textDocument", pages: 0)
        let block = ui.app.textViews.firstMatch
        try require(block, "create.type: text document must open an editable first block")
        block.tap()
        ui.app.typeText("Created through Type")
        try wait("First block must accept typing") { (block.value as? String)?.contains("Created through Type") == true }
    }

    func testTypeStudySetCreatesCardEditorWithRetainedTitle() throws {
        try createKind("Study set", title: "Typed study draft", kind: "studySet", pages: 0)
        try require(cardFace("Term"), "create.type: Study set must open the front input")
        try require(cardFace("Definition"), "create.type: Study set must open the back input")
        try replace(cardFace("Term"), with: "Typed front")
        try replace(cardFace("Definition"), with: "Typed back")
        XCTAssertEqual(cardFace("Term").value as? String, "Typed front")
        XCTAssertEqual(cardFace("Definition").value as? String, "Typed back")
    }

    func testSuggestedTitleUseReachesCreatedDocument() throws {
        // DESIGN §14.6 makes AI suggestions conditional on a connected provider. The fixture has none.
        // Exercise F021's local recognised-text suggestion in the QuickNote title form instead.
        let id = try quickNote()
        try ui.selectTool("text")
        ui.coordinate(CGPoint(x: 0.45, y: 0.45)).tap()
        let text = ui.app.textViews.firstMatch
        try require(text, "Text tool must open an editor for suggestion source content")
        text.typeText("Suggested creation title")
        try exitQuickNote()
        let titleField = ui.app.textFields["Title"]
        try wait("QuickNote must suggest a title from typed content") {
            (titleField.value as? String) == "Suggested creation title"
        }
        try replace(titleField, with: "Temporary override")
        try tap("Use “Suggested creation title”")
        XCTAssertEqual(titleField.value as? String, "Suggested creation title")
        try tap("Save as “Suggested creation title”")
        try ui.openDocument("Suggested creation title")
        XCTAssertEqual(try ui.state().document, id)
    }

    // MARK: Covers, paper groups and templates

    func testCoverSelectionAndNoCoverAffectCreatedPages() throws {
        try notebook("Covered notebook")
        try tap("No cover")
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        let paperPreview = try previewPixels()
        try coverTile("Carbon").tap()
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        try wait("create.cover must update the live preview") {
            guard let pixels = try? self.previewPixels() else { return false }
            return pixels != paperPreview
        }
        try assertPreviewColour(0x2A2D33)
        XCTAssertTrue(try coverTile("Carbon").isSelected, "Selected cover must expose the selection ring's state")
        let id = try create()
        try assertDocument(id, kind: "notebook", pages: 2)
        let pages = try livePages(id)
        XCTAssertEqual(template(pages[0]), "cover.band")
        let cover = (pages[0]["background"] as? [String: Any])?["template"] as? [String: Any]
        // An omitted override uses the cover.band template's Carbon default (DESIGN §3.6).
        let coverColour = (cover?["params"] as? [String: Any])?["color"] as? String
        XCTAssertEqual(coverColour?.uppercased() ?? "#2A2D33FF", "#2A2D33FF",
                       "create.cover: persisted cover colour must agree with Carbon preview and selection")
        try ui.tapCommand("window.showLibrary")
        try notebook("Uncovered notebook")
        try tap("No cover")
        XCTAssertTrue(ui.app.buttons["No cover"].isSelected)
        let bare = try create()
        try assertDocument(bare, kind: "notebook", pages: 1)
        XCTAssertFalse(try livePages(bare).contains { template($0)?.hasPrefix("cover.") == true })
    }

    func testBasicPaperGroupFiltersAndApplies() throws { try paperGroup("Basic", tile: "Blank", id: "builtin.blank") }
    func testLinedPaperGroupFiltersAndApplies() throws { try paperGroup("Lined", tile: "College Ruled", id: "builtin.ruled") }
    func testGridPaperGroupFiltersAndApplies() throws { try paperGroup("Grid", tile: "Graph Paper", id: "builtin.graph") }
    func testPlannerPaperGroupFiltersAndApplies() throws { try paperGroup("Planners", tile: "Daily Planner", id: "builtin.plannerDaily") }
    func testMusicPaperGroupFiltersAndApplies() throws { try paperGroup("Music", tile: "Music Staff", id: "builtin.music") }

    func testFromPluginsPaperGroupFiltersTiles() throws {
        try notebook("Plugin paper")
        try scrollTap("From plugins")
        XCTAssertTrue(ui.app.buttons["From plugins"].isSelected, "create.paper must select the plugin group")
        XCTAssertFalse(ui.app.buttons["College Ruled"].isHittable, "Built-in paper must not remain in plugin group")
        // With no template plugin installed, a clear empty state is the expected filtered result.
        let empty = ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'plugin'")).firstMatch
        try require(empty, "Empty plugin group must explain how to add templates")
    }

    // MARK: Dimensions, orientation, colours, defaults and distribution

    func testA4Size() throws { try sizeCase("A4", width: 595.28, height: 841.89) }
    func testLetterSize() throws { try sizeCase("Letter", width: 612, height: 792) }
    func testB5Size() throws { try sizeCase("B5", width: 498.9, height: 708.66) }
    func testLegalSize() throws { try sizeCase("Legal", width: 612, height: 1008) }
    func testSquareSize() throws { try sizeCase("Square", width: 595.28, height: 595.28) }

    func testCustomSize() throws {
        try notebook("Custom dimensions")
        try tap("No cover")
        try chooseSize("Custom")
        try replace(ui.app.textFields["Width in millimetres"], with: "100")
        try replace(ui.app.textFields["Height in millimetres"], with: "150")
        try assertSize(try create(), width: 100 * 72 / 25.4, height: 150 * 72 / 25.4)
    }

    func testInvalidCustomSizePreventsCreation() throws {
        try notebook("Invalid dimensions")
        try chooseSize("Custom")
        try replace(ui.app.textFields["Width in millimetres"], with: "0")
        try replace(ui.app.textFields["Height in millimetres"], with: "0")
        let create = ui.app.buttons["cmd.doc.create"]
        if create.isEnabled { create.tap() }
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? self.ui.state().document) != nil || self.packages().count != self.originalPackages.count
        }, object: nil)
        created.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 3), .completed,
                       "create.size: invalid zero dimensions created a document/package")
        XCTAssertTrue(ui.app.textFields["Width in millimetres"].exists,
                      "create.size: invalid zero dimensions must keep the draft open, not silently clamp and create")
        XCTAssertNil(try ui.state().document)
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages)
    }

    func testOrientationChangesCreatedDimensions() throws {
        try notebook("Landscape notebook")
        try tap("No cover")
        try chooseSize("Letter")
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        let portraitPreview = try previewPixels()
        try scrollTap("Landscape")
        XCTAssertTrue(ui.app.buttons["Landscape"].isSelected)
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        try wait("create.orientation must update the preview") {
            guard let pixels = try? self.previewPixels() else { return false }
            return pixels != portraitPreview
        }
        try assertSize(try create(), width: 792, height: 612)
        try ui.tapCommand("window.showLibrary")
        try notebook("Portrait notebook")
        try scrollTap("Portrait")
        XCTAssertTrue(ui.app.buttons["Portrait"].isSelected)
        try assertSize(try create(), width: 612, height: 792)
    }

    func testPaperColourSwatchIsApplied() throws {
        try notebook("Ivory paper")
        try tap("No cover")
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        let whitePreview = try previewPixels()
        try scrollTap("Ivory")
        XCTAssertTrue(ui.app.buttons["Ivory"].isSelected)
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        try wait("create.paperColor must update the preview") {
            guard let pixels = try? self.previewPixels() else { return false }
            return pixels != whitePreview
        }
        try assertPreviewColour(0xFBF8F1)
        let page = try XCTUnwrap(livePages(try create()).first)
        let params = (page["background"] as? [String: Any])?["template"] as? [String: Any]
        let colour = (params?["params"] as? [String: Any])?["paper"] as? String
        XCTAssertEqual(colour?.uppercased(), "#FBF8F1FF", "create.paperColor must persist Ivory")
    }

    func testCustomPaperColourCanBeChosen() throws {
        try notebook("Custom colour")
        try tap("No cover")
        try scrollTap("More Templates…")
        try scrollTap("Custom Colour")
        let hex = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label CONTAINS[c] 'hex' OR placeholderValue CONTAINS[c] 'hex')",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
        try replace(hex, with: "#CEDFED")
        try tap("Choose Template")
        try scrollTo(ui.app.textFields["Title"], name: "Title")
        try assertPreviewColour(0xCEDFED)
        let page = try XCTUnwrap(livePages(try create()).first)
        let ref = (page["background"] as? [String: Any])?["template"] as? [String: Any]
        XCTAssertEqual(((ref?["params"] as? [String: Any])?["paper"] as? String)?.uppercased(), "#CEDFEDFF")
    }

    func testApplyEveryOtherDistributesPaperAcrossPages() throws { try distribution("Every other") }
    func testApplyAllPagesDistributesPaperAcrossPages() throws { try distribution("All pages") }

    func testSavedDefaultsReopenWithoutChangingExistingNotebook() throws {
        try ui.openDocument("Physics — Motion")
        let oldID = try XCTUnwrap(ui.state().document)
        let oldPages = try livePages(oldID)
        try ui.tapCommand("window.showLibrary")
        try notebook("Saved defaults")
        try coverTile("Carbon").tap()
        try scrollTap("Planners")
        try scrollTap("Daily Planner")
        try chooseSize("B5")
        let created = try create()
        try assertDocument(created, kind: "notebook", pages: 2)
        try ui.tapCommand("window.showLibrary")
        try notebook("Uses saved defaults")
        XCTAssertTrue(try coverTile("Carbon").isSelected, "create.defaults lost cover")
        try scrollTo(ui.app.buttons["Daily Planner"])
        XCTAssertTrue(ui.app.buttons["Daily Planner"].isSelected, "create.defaults lost paper")
        let second = try create()
        try assertSize(second, width: 498.9, height: 708.66)
        XCTAssertEqual(try livePages(second).map(template), ["cover.band", "builtin.plannerDaily"])
        XCTAssertTrue(NSDictionary(dictionary: ["pages": oldPages]).isEqual(to: ["pages": try livePages(oldID)]),
                      "Changing defaults modified an existing notebook")
    }

    func testTemplateSettingsDefaultsReachCreationAndLeaveExistingNotesUnchanged() throws {
        try ui.openDocument("Physics — Motion")
        let oldID = try XCTUnwrap(ui.state().document)
        let oldPages = try livePages(oldID)
        try ui.tapCommand("window.showLibrary")
        try tap("App Menu")
        try tap("Manage Templates", prefix: true)
        try require(ui.app.staticTexts["Notebook Templates"], "Template settings must open management")
        let groups = button("Template group", prefix: true)
        if groups.exists { groups.tap() }
        try scrollTap("Planners")
        try scrollTap("Daily Planner")
        try scrollTap("Page Size", prefix: true)
        try tap("B5")
        try tap("Set as Default")
        try tap("Covers")
        // The first Carbon button is its colour swatch; the second is the actual cover template tile.
        let carbonTile = ui.app.buttons.matching(NSPredicate(format: "label == 'Carbon'")).element(boundBy: 1)
        try scrollTo(carbonTile, name: "Carbon cover template")
        carbonTile.tap()
        try tap("Set as Default")
        try tap("Done")
        try notebook("Template settings defaults")
        try wait("Template settings must select the saved Carbon cover") {
            (try? self.coverTile("Carbon").isSelected) == true
        }
        try scrollTo(ui.app.buttons["Daily Planner"], name: "Daily Planner")
        XCTAssertTrue(ui.app.buttons["Daily Planner"].isSelected)
        let id = try create()
        try assertSize(id, width: 498.9, height: 708.66)
        XCTAssertEqual(try livePages(id).map(template), ["cover.band", "builtin.plannerDaily"])
        XCTAssertTrue(NSDictionary(dictionary: ["pages": oldPages]).isEqual(to: ["pages": try livePages(oldID)]),
                      "Template settings must leave existing notes unchanged")
    }

    // MARK: Other document kinds

    func testWhiteboardOptionsReachNewBoard() throws {
        try newMenu("Whiteboard")
        try replace(ui.app.textFields["Whiteboard name"], with: "Board options")
        try scrollTap("Grid")
        try scrollTap("Ivory")
        try scrollTap("Handwriting language", prefix: true)
        let french = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'French'")).firstMatch
        try require(french, "whiteboard.create must offer recognition language")
        french.tap()
        try tap("Create")
        let state = try ui.waitForState { $0.document != nil && $0.pageCount == 1 }
        let id = try XCTUnwrap(state.document)
        let head = try head(id)
        let meta = try XCTUnwrap(head["meta"] as? [String: Any])
        XCTAssertEqual(meta["kind"] as? String, "whiteboard")
        XCTAssertTrue((meta["language"] as? String)?.hasPrefix("fr") == true)
        let board = try XCTUnwrap(livePages(id).first)
        XCTAssertEqual(template(board), "builtin.whiteboardGrid")
        let background = try XCTUnwrap(board["background"] as? [String: Any])
        let reference = try XCTUnwrap(background["template"] as? [String: Any])
        XCTAssertEqual((reference["params"] as? [String: Any])?["paper"] as? String, "#FBF8F1FF")
        XCTAssertTrue(board["size"] == nil || board["size"] is NSNull, "Whiteboards must have an infinite page")
        try backAndAssertTitle("Board options", id: id)
    }

    func testNewTextDocumentHasEditableFirstBlock() throws {
        try newMenu("Text Document")
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        let text = ui.app.textViews.firstMatch
        try require(text, "create.textDocument must open an editable first block")
        text.tap()
        ui.app.typeText("First block title")
        try wait("Text editor must retain typed first block") { (text.value as? String)?.contains("First block title") == true }
        try ui.tapCommand("window.showLibrary")
        try ui.openDocument("First block title")
        XCTAssertEqual(try ui.state().document, id)
        XCTAssertTrue((ui.app.textViews.firstMatch.value as? String)?.contains("First block title") == true)
        try assertDocument(id, kind: "textDocument", pages: 0)
    }

    func testWhiteboardKeyboardShortcutOpensOptionsWithoutCreating() throws {
        ui.app.typeKey("w", modifierFlags: [.command, .shift])
        try require(ui.app.textFields["Whiteboard name"], "whiteboard.create: Shift-Command-W must open board options")
        XCTAssertNil(try ui.state().document)
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages)
        try replace(ui.app.textFields["Whiteboard name"], with: "Keyboard board")
        try tap("Create")
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try assertDocument(id, kind: "whiteboard", pages: 1)
        try backAndAssertTitle("Keyboard board", id: id)
    }

    func testTextDocumentKeyboardShortcutCreatesEditableFirstBlock() throws {
        ui.app.typeKey("t", modifierFlags: [.command, .shift])
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try assertDocument(id, kind: "textDocument", pages: 0)
        let block = ui.app.textViews.firstMatch
        try require(block, "create.textDocument: Shift-Command-T must open an editable first block")
        block.tap()
        ui.app.typeText("Keyboard text document")
        try wait("Keyboard-created document must accept typing") {
            (block.value as? String)?.contains("Keyboard text document") == true
        }
        XCTAssertEqual(packages().count, originalPackages.count + 1)
    }

    func testNewStudySetSupportsFrontAndBack() throws {
        try newMenu("Study Set")
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try require(cardFace("Term"),
                    "create.studySet must open the card editor with front/back inputs")
        try replace(cardFace("Term"), with: "Question from UI")
        try replace(cardFace("Definition"), with: "Answer from UI")
        try ui.tapCommand("window.showLibrary")
        try wait("create.studySet must persist both faces") {
            guard let data = try? self.head(id), let cards = data["cards"] as? [[String: Any]], let card = cards.first else { return false }
            let json = String(describing: card)
            return json.contains("Question from UI") && json.contains("Answer from UI")
        }
        try ui.openDocument("Untitled Study Set")
        try assertDocument(id, kind: "studySet", pages: 0)
    }

    // MARK: QuickNote lifecycle (real ink, with undo and redo)

    func testQuickNoteOpensUntitledWithDefaultPaper() throws {
        let id = try quickNote()
        try assertDocument(id, kind: "notebook", pages: 1)
        XCTAssertEqual(try livePages(id).map(template), ["builtin.ruled"])
        XCTAssertTrue(ui.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Untitled'")).firstMatch.exists)
    }

    func testQuickNoteDoubleTapNewCreatesOnlyOnce() throws {
        let new = ui.app.buttons["New"]
        try require(new, "+ New button missing")
        new.doubleTap()
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try assertDocument(id, kind: "notebook", pages: 1)
        XCTAssertEqual(packages().count, originalPackages.count + 1)
        XCTAssertEqual(try livePages(id).map(template), ["builtin.ruled"])
    }

    func testQuickNoteUsesSavedPaperDefaults() throws {
        try notebook("Default planner source")
        try tap("No cover")
        try scrollTap("Planners")
        try scrollTap("Daily Planner")
        try chooseSize("Letter")
        let existing = try create()
        let before = try livePages(existing)
        try ui.tapCommand("window.showLibrary")
        let quick = try quickNote()
        XCTAssertNotEqual(quick, existing)
        try assertDocument(quick, kind: "notebook", pages: 1)
        XCTAssertEqual(try livePages(quick).map(template), ["builtin.plannerDaily"],
                       "doc.quickNote must use the saved default paper")
        try assertSize(quick, width: 612, height: 792)
        XCTAssertTrue(NSDictionary(dictionary: ["pages": before]).isEqual(to: ["pages": try livePages(existing)]),
                      "QuickNote creation changed the existing notebook")
    }

    func testQuickNoteKeyboardShortcutCreatesUntitledDefaultPaper() throws {
        ui.app.typeKey("n", modifierFlags: [.command, .shift])
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try assertDocument(id, kind: "notebook", pages: 1)
        XCTAssertEqual(try livePages(id).map(template), ["builtin.ruled"])
        XCTAssertEqual(packages().count, originalPackages.count + 1)
        try exitQuickNote()
        try require(ui.app.textFields["Title"], "QuickNote shortcut must produce a draft with the save-on-exit flow")
    }

    func testQuickNoteSaveRetainsNameAndInk() throws {
        let id = try quickNote()
        try drawAndUndoRedo()
        try exitQuickNote()
        try replace(ui.app.textFields["Title"], with: "Saved QuickNote")
        try tap("Save as “Saved QuickNote”")
        try ui.openDocument("Saved QuickNote")
        XCTAssertEqual(try ui.state().document, id)
        XCTAssertEqual(try ui.state().strokeCountOnPage, 1, "quicknote.save lost ink")
    }

    func testQuickNoteKeepEditingRetainsIdentityAndInk() throws {
        let id = try quickNote()
        try drawAndUndoRedo()
        try exitQuickNote()
        // F021 specifies Save as Untitled / Combine / Delete, not a fourth Keep Editing
        // button. Keep the untitled note through that explicit choice, then resume it.
        try tap("Save as Untitled")
        try wait("Keeping the QuickNote must dismiss the exit prompt") {
            !self.ui.app.staticTexts["Save this QuickNote?"].exists
        }
        try ui.openDocument("Untitled")
        try ui.waitForState { $0.document == id && $0.strokeCountOnPage == 1 }
        try drawAndUndoRedo()
        XCTAssertEqual(try ui.state().strokeCountOnPage, 2, "Keep editing must return to an editable canvas")
    }

    func testQuickNoteCombineAppendsOnceAndPreservesTarget() throws {
        try ui.openDocument("Physics — Motion")
        let target = try ui.state()
        try ui.tapCommand("window.showLibrary")
        let source = try quickNote()
        try drawAndUndoRedo()
        try exitQuickNote()
        try tap("Combine to a Document…")
        try tap("Physics — Motion", prefix: true)
        try ui.openDocument("Physics — Motion")
        let merged = try ui.waitForState { $0.pageCount == target.pageCount + 1 }
        XCTAssertEqual(merged.document, target.document)
        XCTAssertEqual(merged.strokeCountOnPage, target.strokeCountOnPage, "quicknote.combine changed existing ink")
        XCTAssertEqual(merged.itemCountOnPage, target.itemCountOnPage)
        XCTAssertNotEqual(merged.document, source)
        try ui.tapCommand("window.showLibrary")
        try ui.openDocument("Physics — Motion")
        XCTAssertEqual(try ui.state().pageCount, target.pageCount + 1, "Combined twice after reopening")
        let id = try XCTUnwrap(target.document)
        let last = try XCTUnwrap(livePages(id).last?["id"] as? String)
        XCTAssertEqual(try persistedStrokes(id, page: last), 1, "Appended page lost the actual QuickNote stroke")
    }

    func testQuickNoteDeleteRemovesOnlyQuickNote() throws {
        _ = try quickNote()
        try drawAndUndoRedo()
        try exitQuickNote()
        try tap("Delete QuickNote")
        try ui.waitForState { $0.document == nil && $0.screen == "library" }
        XCTAssertEqual(Set(packages().map(\.path)), originalPackages,
                       "quicknote.delete must remove only the QuickNote and preserve every unrelated package")
        try wait("quicknote.delete must remove the Untitled document from the library") {
            !self.ui.app.descendants(matching: .any).matching(identifier: "cmd.doc.open")
                .matching(NSPredicate(format: "label BEGINSWITH 'Untitled'")).firstMatch.exists
        }
        try ui.openDocument("Physics — Motion")
        XCTAssertEqual(try ui.state().pageCount, 4)
        XCTAssertEqual(try ui.state().strokeCountOnPage, 1)
    }

    // MARK: Audio and calendar

    func testQuickRecordCreatesTextDocumentAndAdvancingHUD() throws {
        let monitor = addUIInterruptionMonitor(withDescription: "Microphone access") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        try newMenu("Quick Record")
        // F052 requires the user's microphone permission before recording. The
        // request is asynchronous: an immediate app tap can precede the alert
        // (and open a folder), leaving the interruption monitor untriggered.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowMicrophone = springboard.alerts.buttons["Allow"]
        if allowMicrophone.waitForExistence(timeout: 15) { allowMicrophone.tap() }
        let state = try ui.waitForState { $0.document != nil }
        let id = try XCTUnwrap(state.document)
        try assertDocument(id, kind: "textDocument", pages: 0)
        let hud = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Recording' AND value != nil")).firstMatch
        try require(hud, "audio.quickRecord must display recording HUD")
        let initial = hud.value as? String
        try wait("audio.quickRecord timer must advance", timeout: 15) { (hud.value as? String) != initial }
        try tap("Stop Recording")
        try wait("Stop Recording must end recording") { !self.ui.app.buttons["Stop Recording"].exists }
    }

    func testEventPlannerLayoutAndDateProduceLinkedPages() throws {
        try newMenu("Event Planner")
        try tap("Weekly")
        try scrollTap("Monday")
        let decrement = ui.app.steppers.buttons["Decrement"].firstMatch
        try scrollTo(decrement, name: "Planner count")
        try require(decrement, "Planner count stepper missing")
        decrement.tap()
        try tap("Create Planner")
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try assertDocument(id, kind: "notebook", pages: 3)
        let pages = try livePages(id)
        XCTAssertEqual(pages.map(template), Array(repeating: "planner.events", count: 3))
        for page in pages {
            let ref = (page["background"] as? [String: Any])?["template"] as? [String: Any]
            let params = try XCTUnwrap(ref?["params"] as? [String: Any])
            XCTAssertEqual(params["layout"] as? String, "weekly")
            XCTAssertEqual(params["weekStart"] as? String, "monday")
            XCTAssertGreaterThan(params["year"] as? Int ?? 0, 2020, "calendar.newPlanner must persist page date linkage")
            XCTAssertGreaterThan(params["month"] as? Int ?? 0, 0)
            XCTAssertGreaterThan(params["day"] as? Int ?? 0, 0)
        }
        try require(ui.app.buttons["Sync Calendar Events"], "Linked planner must expose event sync")
    }

    func testEventPlannerChosenStartDateReachesDailyPages() throws {
        try newMenu("Event Planner")
        try tap("Daily")
        let picker = ui.app.datePickers.firstMatch
        try scrollTo(picker, name: "Planner start date")
        let dateRow = picker.frame
        picker.tap()
        // Choose a different day in the displayed month through the native calendar, without setting app state.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.day = components.day == 15 ? 16 : 15
        let chosen = try XCTUnwrap(calendar.date(from: components))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM d"
        let day = ui.app.buttons.matching(NSPredicate(format: "label == %@ OR label CONTAINS %@",
            String(try XCTUnwrap(components.day)), formatter.string(from: chosen))).firstMatch
        try require(day, "Native start-date picker must expose the chosen day")
        day.tap()
        // The native compact date picker can overlap the header while XCTest still reports
        // Create as hittable. Dismiss that system popover before invoking the create action;
        // tapping the covered header instead can open the picker's month/year controls.
        if ui.app.buttons["DatePicker.NextMonth"].exists {
            // Stay inside the creation sheet. An outside-sheet tap cancels the
            // draft on iPad, which contradicts this test's intent to create it.
            ui.app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: dateRow.minX + 12 - ui.app.frame.minX,
                dy: dateRow.midY - ui.app.frame.minY)).tap()
            try wait("Native date picker must dismiss before Create Planner") {
                !self.ui.app.buttons["DatePicker.NextMonth"].exists
            }
        }
        try tap("Create Planner")
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        try assertDocument(id, kind: "notebook", pages: 7)
        for (offset, page) in try livePages(id).enumerated() {
            XCTAssertEqual(template(page), "planner.events")
            let reference = (page["background"] as? [String: Any])?["template"] as? [String: Any]
            let params = try XCTUnwrap(reference?["params"] as? [String: Any])
            let expected = calendar.dateComponents([.year, .month, .day], from:
                try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: chosen)))
            XCTAssertEqual(params["layout"] as? String, "daily")
            XCTAssertEqual(params["year"] as? Int, expected.year)
            XCTAssertEqual(params["month"] as? Int, expected.month)
            XCTAssertEqual(params["day"] as? Int, expected.day, "Chosen planner start date must reach every page")
        }
    }

    func testCalendarCreateNoteFilesLinkedNoteInEventFolder() throws { try eventNote(reopen: false) }
    func testCalendarOpenNoteReusesExistingDocument() throws { try eventNote(reopen: true) }

    // MARK: UI helpers

    private func coverTile(_ title: String) throws -> XCUIElement {
        // DESIGN §14.6 separates the cover strip (led by No cover) from colour swatches.
        // Carbon names both controls; only the tile selects or reports the cover template.
        let strips = ui.app.scrollViews.containing(.button, identifier: "No cover").allElementsBoundByIndex
        let strip = try XCTUnwrap(strips.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height },
                                  "Creation sheet must expose its cover strip")
        return strip.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func previewPixels() throws -> Data {
        let title = ui.app.textFields["Title"].frame
        guard title.width > 0, title.height > 0 else {
            throw NibUI.Failure.message("Preview title has not finished layout")
        }
        // DESIGN §14.6: the 104 × 136 preview immediately precedes the title field, separated by 16 pt.
        let rect = CGRect(x: title.minX - 120, y: title.midY - 68, width: 104, height: 136).insetBy(dx: 8, dy: 8)
        let window = ui.app.windows.firstMatch
        let bounds = window.frame
        let screenshot = window.screenshot().image
        // XCTest can return a portrait pixel buffer with a landscape UIImage orientation.
        // Drawing it first applies that orientation before cropping in accessibility coordinates.
        let upright = UIGraphicsImageRenderer(size: bounds.size).image { _ in
            screenshot.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        guard let image = upright.cgImage else { throw NibUI.Failure.message("Preview screenshot has no pixels") }
        let scale = CGFloat(image.width) / bounds.width
        guard let crop = image.cropping(to: CGRect(x: (rect.minX - bounds.minX) * scale,
                                                   y: (rect.minY - bounds.minY) * scale,
                                                   width: rect.width * scale, height: rect.height * scale)),
              let data = UIImage(cgImage: crop).pngData() else {
            throw NibUI.Failure.message("Preview crop is outside the current screenshot")
        }
        return data
    }

    private func assertPreviewColour(_ expected: UInt32) throws {
        try wait("Live preview must show selected colour #\(String(expected, radix: 16))") {
            guard let data = try? self.previewPixels(), let image = UIImage(data: data)?.cgImage else { return false }
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                              bytesPerRow: 32 * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                return true
            }
            guard rendered else { return false }
            var counts: [UInt32: Int] = [:]
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let rgb = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
                counts[rgb, default: 0] += 1
            }
            guard let dominant = counts.max(by: { $0.value < $1.value })?.key else { return false }
            // The dominant fill ignores rules, the cloth spine, and the elastic band.
            return [0, 8, 16].allSatisfy { shift in
                abs(Int((dominant >> shift) & 255) - Int((expected >> shift) & 255)) <= 3
            }
        }
    }

    private func require(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail(message, file: file, line: line)
            throw NibUI.Failure.message(message)
        }
    }

    private func wait(_ message: String, timeout: TimeInterval = 15, _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail(message)
            throw NibUI.Failure.message(message)
        }
    }

    private func button(_ label: String, prefix: Bool = false) -> XCUIElement {
        ui.app.buttons.matching(NSPredicate(format: prefix ? "label BEGINSWITH %@" : "label == %@", label)).firstMatch
    }

    private func tap(_ label: String, prefix: Bool = false) throws {
        let element = button(label, prefix: prefix)
        try require(element, "Missing control: \(label)")
        element.tap()
    }

    private func scrollTo(_ element: XCUIElement, name: String = "creation control") throws {
        for _ in 0..<12 {
            let exists = element.exists
            if exists && element.elementType != .textField && element.isHittable { return }
            let target = exists ? element.frame : nil
            let candidates = (ui.app.collectionViews.allElementsBoundByIndex + ui.app.scrollViews.allElementsBoundByIndex)
                .filter { $0.isHittable && $0.frame.height > 40 }
            // Scroll the target's own container, not an unrelated card editor or paper grid.
            let containers = exists ? candidates.filter { scroll in
                scroll.descendants(matching: element.elementType).matching(NSPredicate(
                    format: "identifier == %@ AND label == %@", element.identifier, element.label))
                    .allElementsBoundByIndex.contains { $0.frame == target }
            } : []
            let scroll = containers.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                ?? candidates.first { $0.elementType == .collectionView }
                ?? candidates.last { $0.frame.height > 200 }
            guard let scroll else {
                if exists && element.isHittable { return }
                break
            }
            // DESIGN uses the native keyboard. Its covered area cannot receive form gestures,
            // even when accessibility reports a scroll frame extending underneath it.
            let keyboards = ui.app.keyboards.allElementsBoundByIndex.map(\.frame)
            guard let visible = NibUITestScrollGeometry.viewport(
                scroll: scroll.frame, window: ui.app.frame, obstructions: keyboards) else { break }
            if exists && element.isHittable, let target {
                var required = target
                if name == "Title" {
                    required = required.union(CGRect(x: target.minX - 120, y: target.midY - 68, width: 104, height: 136))
                }
                if element.elementType != .textField || visible.contains(required) { return }
            }
            let targetY = name == "Title" ? target.map { $0.midY - 68 } : target?.midY
            let drag = NibUITestScrollGeometry.drag(in: visible, toward: targetY)
            let origin = ui.app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: drag.start.x - ui.app.frame.minX, dy: drag.start.y - ui.app.frame.minY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(
                    dx: drag.end.x - ui.app.frame.minX, dy: drag.end.y - ui.app.frame.minY)),
                    withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 0.3)
        }
        try require(element, "Missing required creation control: \(name)")
        XCTAssertTrue(element.isHittable, "Creation control is unreachable after scrolling")
    }

    private func scrollTap(_ label: String, prefix: Bool = false) throws {
        let element = button(label, prefix: prefix)
        try scrollTo(element, name: label)
        element.tap()
    }

    private func replace(_ field: XCUIElement, with text: String) throws {
        try require(field, "Missing editable field: \(field)")
        try scrollTo(field, name: field.label)
        field.tap()
        field.typeKey("a", modifierFlags: [.command])
        field.typeText(text)
        dismissKeyboard()
    }

    private func dismissKeyboard() {
        let keyboard = ui.app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let hide = keyboard.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'hide keyboard' OR label CONTAINS[c] 'dismiss keyboard'")).firstMatch
        if hide.exists && hide.isHittable {
            hide.tap()
        } else {
            // iPad's system keyboard has a dismissal key at its lower-right corner.
            keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.94)).tap()
        }
    }

    private func newMenu(_ choice: String) throws {
        try tap("New")
        // Menu accessibility labels include the displayed keyboard shortcut after the title.
        // Match a title boundary so “Study Set” cannot tap the library's “Study Sets” sidebar row.
        let item = ui.app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            choice, choice + " ", choice + ",")).firstMatch
        try require(item, "New menu must offer \(choice)")
        try scrollTo(item, name: choice)
        item.tap()
    }

    private func notebook(_ title: String) throws {
        try newMenu("Notebook")
        try replace(ui.app.textFields["Title"], with: title)
        // Resign focus without Return, which is the Create action on this field.
        try tap("Notebook")
    }

    private func cardFace(_ label: String) -> XCUIElement {
        // The study editor names its front/back inputs Term/Definition; multiline fields may be text views.
        ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
    }

    private func createKind(_ type: String, title: String, kind: String, pages: Int) throws {
        try notebook(title)
        try tap(type)
        XCTAssertEqual(ui.app.textFields["Title"].value as? String, title)
        let id = try create()
        try assertDocument(id, kind: kind, pages: pages)
        XCTAssertEqual(packages().count, originalPackages.count + 1, "create.type must create exactly one document")
        try backAndAssertTitle(title, id: id)
    }

    @discardableResult private func create() throws -> String {
        try ui.tapCommand("doc.create")
        let state = try ui.waitForState { $0.screen == "document" && $0.document != nil }
        let id = try XCTUnwrap(state.document)
        try wait("Created document must be persisted") { (try? self.head(id)) != nil }
        try wait("Creation sheet must dismiss after opening the document") {
            !self.ui.app.buttons["cmd.doc.create"].exists
        }
        return id
    }

    private func chooseSize(_ name: String) throws {
        let size = button("Size", prefix: true)
        try scrollTo(size, name: "Size")
        size.tap()
        try tap(name)
    }

    private func backAndAssertTitle(_ title: String, id: String) throws {
        try ui.tapCommand("window.showLibrary")
        try ui.waitForState { $0.document == nil }
        try ui.openDocument(title)
        XCTAssertEqual(try ui.state().document, id, "Title must refer to the document just created")
    }

    private func paperGroup(_ group: String, tile: String, id: String) throws {
        try notebook("\(group) paper")
        try tap("No cover")
        try scrollTap(group)
        XCTAssertTrue(button(group).isSelected, "create.paper group must be selected")
        if group != "Lined" { XCTAssertFalse(button("College Ruled").isHittable, "Group did not filter previous tiles") }
        try scrollTap(tile)
        XCTAssertTrue(button(tile).isSelected, "Paper tile must expose its selection state")
        XCTAssertEqual(try livePages(try create()).map(template), [id], "Selected paper must reach the created page")
    }

    private func sizeCase(_ name: String, width: Double, height: Double) throws {
        try notebook("\(name) size")
        try tap("No cover")
        try chooseSize(name)
        try scrollTap("Portrait")
        try assertSize(try create(), width: width, height: height)
    }

    private func distribution(_ choice: String) throws {
        try notebook("\(choice) distribution")
        try tap("No cover")
        try scrollTap(choice)
        XCTAssertTrue(button(choice).isSelected, "create.applyPattern must select the distribution")
        try scrollTap("Grid")
        try scrollTap("Graph Paper")
        let id = try create()
        for _ in 0..<3 { try ui.tapCommand("page.add") }
        try ui.waitForState { $0.pageCount == 4 }
        let papers = try livePages(id).map(template)
        XCTAssertEqual(papers.count, 4)
        if choice == "All pages" { XCTAssertEqual(papers, Array(repeating: "builtin.graph", count: 4)) }
        else {
            XCTAssertEqual(papers[0], "builtin.graph")
            XCTAssertEqual(papers[0], papers[2])
            XCTAssertEqual(papers[1], papers[3])
            XCTAssertNotEqual(papers[0], papers[1], "Every other must alternate patterned and plain paper")
        }
    }

    private func quickNote() throws -> String {
        try newMenu("QuickNote")
        let state = try ui.waitForState { $0.document != nil && $0.pageCount == 1 }
        return try XCTUnwrap(state.document)
    }

    private func drawAndUndoRedo() throws {
        try ui.selectTool("pen")
        let initial = try ui.state().strokeCountOnPage
        try ui.drawStroke([CGPoint(x: 0.40, y: 0.60), CGPoint(x: 0.60, y: 0.66)])
        try ui.waitForState { $0.strokeCountOnPage == initial + 1 && $0.undoAvailable }
        try ui.tapCommand("edit.undo")
        try ui.waitForState { $0.strokeCountOnPage == initial && $0.redoAvailable }
        try ui.tapCommand("edit.redo")
        try ui.waitForState { $0.strokeCountOnPage == initial + 1 }
    }

    private func exitQuickNote() throws {
        try ui.tapCommand("window.showLibrary")
        try require(ui.app.staticTexts["Save this QuickNote?"], "QuickNote exit must ask what to do with it")
    }

    private func eventNote(reopen: Bool) throws {
        // Calendar is a real system dependency. Create an event through its UI, without injecting app state.
        let eventTitle = "Nib Creation Event " + UUID().uuidString.prefix(8)
        let calendar = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        let monitor = addUIInterruptionMonitor(withDescription: "Calendar first-launch permissions") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        calendar.launch()
        calendar.tap() // Triggers the interruption monitor for first-launch system prompts.
        let continueButton = calendar.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 3) { continueButton.tap(); calendar.tap() }
        try NibUI.openCalendarEvent(in: calendar)
        let title = calendar.textFields["Title"]
        // This editor belongs to Calendar. The creation-form scrolling helper
        // targets Nib's window and would bring the background app forward.
        try require(title, "Calendar must offer its event title field")
        title.tap()
        title.typeKey("a", modifierFlags: [.command])
        title.typeText(eventTitle)
        // EventKit's iOS 26 editor labels this action Done. The system identifier
        // names the save action consistently; the spec requires a saved event,
        // not a particular version of Apple's button copy.
        let saveEvent = calendar.buttons["add-button"]
        try require(saveEvent, "Calendar must offer its save-event action")
        saveEvent.tap()
        ui.app.activate()
        try tap("Calendar")
        let connect = button("Connect Calendars")
        if connect.exists { connect.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Allow Full Access'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        try tapEventAction("Take Notes", eventTitle: eventTitle)
        let id = try XCTUnwrap(ui.waitForState { $0.document != nil }.document)
        let package = try package(id)
        XCTAssertTrue(package.path.contains("Calendar Event"), "calendar.createNote must file the note under Calendar Event")
        XCTAssertTrue(package.path.contains(eventTitle), "Linked note must be in this event's folder")
        let count = packages().count
        XCTAssertEqual(count, originalPackages.count + 1, "calendar.createNote must create exactly one note")
        let meta = try XCTUnwrap(head(id)["meta"] as? [String: Any])
        let event = (meta["ext"] as? [String: Any])?["calendar"] as? [String: Any]
        XCTAssertFalse((event?["event"] as? String ?? "").isEmpty, "Event note must retain event linkage")
        if reopen {
            try ui.tapCommand("window.showLibrary")
            try tap("Calendar")
            try tapEventAction("Open Note", eventTitle: eventTitle)
            try ui.waitForState { $0.document == id }
            XCTAssertEqual(packages().count, count, "calendar.openNote duplicated the event note")
        }
    }

    private func tapEventAction(_ action: String, eventTitle: String) throws {
        let summary = ui.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", eventTitle)).firstMatch
        try scrollTo(summary, name: eventTitle)
        // Scope to the smallest event container so repeated suite runs cannot act on an older event.
        let containers = ui.app.otherElements.containing(NSPredicate(format: "label BEGINSWITH %@", eventTitle))
            .allElementsBoundByIndex.filter { $0.buttons[action].firstMatch.isHittable }
        let row = try XCTUnwrap(containers.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height },
                               "calendar: missing \(action) action for \(eventTitle)")
        row.buttons[action].firstMatch.tap()
    }

    // MARK: Read-only persisted results (simulator fixture only)

    private func packages() -> [URL] {
        guard let fixture, let entries = FileManager.default.enumerator(at: fixture.appendingPathComponent("Library"),
            includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { $0 as? URL }.filter { $0.pathExtension == "nibnote" && !$0.path.contains("/trash/") }
    }

    private func package(_ id: String) throws -> URL {
        for url in packages() {
            for file in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix("doc.") && file.pathExtension == "json" {
                if let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                   let meta = object["meta"] as? [String: Any], meta["id"] as? String == id { return url }
            }
        }
        throw NibUI.Failure.message("Persisted package missing for probe document \(id)")
    }

    private func head(_ id: String) throws -> [String: Any] {
        let files = try FileManager.default.contentsOfDirectory(at: package(id), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("doc.") && $0.pathExtension == "json" })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func livePages(_ id: String) throws -> [[String: Any]] {
        let pages = try XCTUnwrap(head(id)["pages"] as? [[String: Any]])
        return pages.filter { ($0["deleted"] as? Bool) != true }.sorted { ($0["order"] as? String ?? "") < ($1["order"] as? String ?? "") }
    }

    private func template(_ page: [String: Any]) -> String? {
        ((page["background"] as? [String: Any])?["template"] as? [String: Any])?["id"] as? String
    }

    private func assertDocument(_ id: String, kind: String, pages: Int) throws {
        let meta = try XCTUnwrap(head(id)["meta"] as? [String: Any])
        XCTAssertEqual(meta["kind"] as? String, kind)
        XCTAssertEqual(try ui.state().document, id)
        XCTAssertEqual(try ui.state().pageCount, pages)
        XCTAssertEqual(try livePages(id).count, pages)
    }

    private func assertSize(_ id: String, width: Double, height: Double) throws {
        for page in try livePages(id) {
            let size = try XCTUnwrap(page["size"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(size["width"] as? Double), width, accuracy: 0.5, "create.size/orientation width")
            XCTAssertEqual(try XCTUnwrap(size["height"] as? Double), height, accuracy: 0.5, "create.size/orientation height")
        }
    }

    private func persistedStrokes(_ id: String, page: String) throws -> Int {
        let folder = try package(id).appendingPathComponent("pages/\(page)")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "nibpage" })
        let data = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return items.filter { $0["kind"] as? String == "stroke" && $0["deleted"] as? Bool != true }.count
    }
}
