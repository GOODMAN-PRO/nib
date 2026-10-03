import XCTest
import UIKit

/// Editor chrome inventory. All mutations use touch, menus or typeKey; the QA probe is read-only.
/// Owners: F016 toolbar, F017 chrome/panels, F018 windows, F039 ruler, F040 laser,
/// F041 layers, F042 PDF/read-only, F062 Time Keeper, F063 presentation, F091 bridge UI.
/// Hardware-only: Pencil pressure/tilt/hover/squeeze/double-tap, camera, VoiceOver audio,
/// physical keyboard behaviour beyond typeKey, and AirPlay/cabled external-display output.
/// The standard runner is an iPad lane; compact assertions run when its actual width is <600.
/// Fixture launches deliberately reset storage and suppress cold restoration. Background/foreground
/// restoration is covered here; cold restoration requires a persistent, non-fixture launch harness.
@MainActor
final class ChromeUITests: XCTestCase {
    private var ui: NibUI!
    private let notebook = "Physics — Motion"
    private var imports: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        try ui.launchFixture()
    }

    override func tearDownWithError() throws {
        if let ui {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Chrome-\(name)-screen"
            shot.lifetime = .keepAlways
            add(shot)
            let state = XCTAttachment(string: "\(ui.probe.value ?? "no probe")\n\(ui.app.debugDescription)")
            state.name = "Chrome-\(name)-state-and-accessibility"
            state.lifetime = .keepAlways
            add(state)
            ui.app.terminate()
        }
        if let imports { try FileManager.default.removeItem(at: imports) }
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func query(_ name: String) -> XCUIElementQuery {
        // Native fields can expose their visible name as a placeholder (for example Title).
        ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR placeholderValue == %@", name, name, name))
    }

    @discardableResult
    private func require(_ name: String, timeout: TimeInterval = 8) throws -> XCUIElement {
        let target = query(name).firstMatch
        guard target.waitForExistence(timeout: timeout) else {
            throw NibUI.Failure.message("Missing chrome control: \(name)\n\(ui.app.debugDescription)")
        }
        return target
    }

    private func wait(_ message: String, timeout: TimeInterval = 12, _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw NibUI.Failure.message("\(message)\nState: \(ui.probe.value ?? "missing")\n\(ui.app.debugDescription)")
        }
    }

    /// Scroll the containing sheet/popover, never the document, to reach offscreen controls.
    private func reachable(_ name: String, editing: Bool = false) throws -> XCUIElement {
        let q = editing ? query(name).matching(NSPredicate(format: "elementType IN %@",
            [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.secureTextField.rawValue,
             XCUIElement.ElementType.textView.rawValue])) : query(name)
        if !q.firstMatch.exists { revealNativeFormRow(q.firstMatch, name: name) }
        _ = try require(name)
        for _ in 0..<12 {
            let candidates = q.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
            if let button = candidates.first(where: { $0.elementType == .button && !$0.identifier.hasPrefix("tool.") }) { return button }
            if let target = candidates.first { return target }
            let containers = ui.app.scrollViews.allElementsBoundByIndex + ui.app.collectionViews.allElementsBoundByIndex + ui.app.tables.allElementsBoundByIndex
            guard let scroller = containers.first(where: {
                $0.identifier != "nib.canvas" && $0.isHittable && $0.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", name, name, name)).count > 0
            }) else { break }
            let dy: CGFloat = q.firstMatch.frame.midY < scroller.frame.minY ? 0.65 : -0.65
            let start = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy > 0 ? 0.2 : 0.8))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy * scroller.frame.height)))
        }
        throw NibUI.Failure.message("Chrome control is not actionable: \(name)\n\(ui.app.debugDescription)")
    }

    /// DESIGN §14.3 uses a native, virtualized list. A row above the viewport
    /// need not exist in its accessibility tree; search both ways without
    /// scrolling the document or assuming every saved row remains mounted.
    private func revealNativeFormRow(_ target: XCUIElement, name: String) {
        let forms = ui.app.collectionViews.allElementsBoundByIndex + ui.app.tables.allElementsBoundByIndex
        guard let list = forms.last(where: { $0.isHittable }) else { return }
        let savedLayoutRow = name == "Save Current Layout" || name.hasPrefix("Apply ") || name == "Reset Toolbar"
        for towardTop in savedLayoutRow ? [false, true] : [true, false] {
            for _ in 0..<10 {
                if target.exists { return }
                let first = list.staticTexts.firstMatch
                let marker = first.label + String(describing: first.frame)
                let obstructions = ui.app.keyboards.allElementsBoundByIndex.map(\.frame)
                    + ui.app.otherElements.matching(identifier: "inputAssistantView").allElementsBoundByIndex.map(\.frame)
                guard let viewport = NibUITestScrollGeometry.viewport(
                    scroll: list.frame, window: ui.app.frame, obstructions: obstructions) else { return }
                let origin = ui.app.coordinate(withNormalizedOffset: .zero)
                let appFrame = ui.app.frame
                let x = viewport.minX + viewport.width * 0.8 - appFrame.minX
                let startY = viewport.minY + viewport.height * (towardTop ? 0.12 : 0.88) - appFrame.minY
                let endY = viewport.minY + viewport.height * (towardTop ? 0.88 : 0.12) - appFrame.minY
                origin.withOffset(CGVector(dx: x, dy: startY)).press(forDuration: 0.01,
                    thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY)),
                    withVelocity: .default, thenHoldForDuration: 0.15)
                if target.exists { return }
                if first.label + String(describing: first.frame) == marker { break }
            }
        }
    }

    private func tap(_ name: String) throws { try reachable(name).tap() }
    private func key(_ value: String, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        // Exercise the specified physical chord. CI's one-shot typeKey can
        // deliver a bare letter (Cmd-J arrived as HID 13 with both flags zero).
        XCUIElement.perform(withKeyModifiers: modifiers) {
            ui.app.typeKey(value, modifierFlags: modifiers)
        }
    }
    private func escape() { key(XCUIKeyboardKey.escape.rawValue) }
    private func outside() {
        // Popovers follow their dock. The former fixed right-hand point falls
        // inside right-docked pen settings, so it never performed an outside tap.
        let covered = ui.app.scrollViews.allElementsBoundByIndex
            .filter { $0.identifier != "nib.canvas" && $0.isHittable }.map(\.frame)
        let canvas = ui.canvas.frame
        for point in [CGPoint(x: 0.5, y: 0.86), CGPoint(x: 0.5, y: 0.5),
                      CGPoint(x: 0.12, y: 0.86), CGPoint(x: 0.88, y: 0.86)] {
            let screen = CGPoint(x: canvas.minX + canvas.width * point.x,
                                 y: canvas.minY + canvas.height * point.y)
            if !covered.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(screen) }) {
                ui.coordinate(point).tap()
                return
            }
        }
        XCTFail("No document point outside the presented popover")
    }
    private func open(_ title: String? = nil) throws {
        try ui.openDocument(title ?? notebook)
        XCTAssertTrue(ui.canvas.waitForExistence(timeout: 15))
    }
    private func openMenu(_ id: String) throws {
        // DESIGN §14.2 keeps Add Page in More when it is not in the trailing bar.
        if id == "addPage", !query("menu.addPage").firstMatch.exists {
            try tap("menu.more")
        } else {
            try tap("menu." + id)
        }
    }
    private func menu(_ id: String, _ action: String) throws { try openMenu(id); try tap(action) }
    private func more(_ action: String) throws { try menu("more", action) }
    private func panel(_ id: String, shown: Bool = true) throws {
        _ = try ui.waitForState(timeout: 12) { $0.openPanels.contains(id) == shown }
    }
    private func sameContent(_ before: QAState, history: Bool = true) throws {
        let after = try ui.state()
        XCTAssertEqual(after.document, before.document)
        XCTAssertEqual(after.page, before.page)
        XCTAssertEqual(after.pageCount, before.pageCount)
        XCTAssertEqual(after.itemCountOnPage, before.itemCountOnPage)
        XCTAssertEqual(after.strokeCountOnPage, before.strokeCountOnPage)
        if history {
            XCTAssertEqual(after.undoAvailable, before.undoAvailable)
            XCTAssertEqual(after.redoAvailable, before.redoAvailable)
        }
    }
    private func draw(y: CGFloat = 0.65) throws {
        let before = try ui.state()
        try ui.drawStroke([CGPoint(x: 0.4, y: y), CGPoint(x: 0.6, y: y + 0.03)])
        _ = try ui.waitForState(timeout: 12) { $0.strokeCountOnPage == before.strokeCountOnPage + 1 && $0.undoAvailable }
    }
    private func replace(_ name: String, _ text: String) throws {
        let alertField = ui.app.alerts.textFields.matching(NSPredicate(
            format: "label == %@ OR placeholderValue == %@", name, name)).firstMatch
        // An alert focuses its first field even when the floating number pad
        // obscures its activation point. Other forms must target the editor,
        // never a neighbouring static label with the same accessible name.
        let target = try alertField.exists ? alertField : reachable(name, editing: true)
        if target.isHittable { target.tap() }
        // The field owns editing, including inside native alerts. Targeting
        // the app can make XCTest dismiss that alert as an interruption.
        if let value = target.value as? String, !value.isEmpty, value != target.placeholderValue {
            XCUIElement.perform(withKeyModifiers: .command) {
                target.typeKey("a", modifierFlags: .command)
            }
        }
        target.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }
    private func toggle(_ name: String, to on: Bool) throws {
        let target = ui.app.switches.matching(NSPredicate(format: "label == %@", name)).firstMatch
        _ = try reachable(name)
        XCTAssertTrue(target.exists, "Expected switch \(name)")
        if (target.value as? String == "1") != on {
            // DESIGN §10.13 uses the native iOS 26 switch. Its labelled row can contain
            // a separate switch; the row's centre is not the switch's touch target.
            let control = target.descendants(matching: .switch).firstMatch
            if control.exists { control.tap() } else { target.tap() }
        }
        try wait("\(name) must become \(on)") { (target.value as? String == "1") == on }
    }
    private func settings(_ tool: String) throws {
        try ui.selectTool(tool)
        try tap("menu.toolSettings")
    }
    private func editing(_ page: String) throws {
        try more("Document Editing Settings")
        try panel("chrome.editingSettings")
        try tap(page)
    }
    private func closeEditing() throws { try ui.dismissSheets(); try panel("chrome.editingSettings", shown: false) }

    // window.showLibrary; chrome.title; chrome.menus; chrome.compact
    func testBackToLibraryRetainsDocumentAndNewInk() throws {
        try open(); try ui.selectTool("pen"); try draw()
        let saved = try ui.state()
        try ui.tapCommand("window.showLibrary")
        _ = try ui.waitForState { $0.screen == "library" && $0.document == nil && $0.page == nil }
        try open(); try sameContent(saved, history: false)
    }

    func testTitleRenameChangesLibraryTitleAndKeepsDocumentIdentity() throws {
        try open(); let before = try ui.state()
        try menu("title", "Rename"); try panel("chrome.rename")
        try replace("Title", "Chrome renamed note"); try tap("Rename")
        try panel("chrome.rename", shown: false)
        try wait("Renamed title must appear in chrome") { self.query("menu.title").firstMatch.label.contains("Chrome renamed note") }
        try sameContent(before, history: false)
        try ui.tapCommand("window.showLibrary"); try open("Chrome renamed note")
        XCTAssertEqual(try ui.state().document, before.document)
    }

    func testTitleMoveActuallyMovesNoteAndPreservesContent() throws {
        try open(); let before = try ui.state()
        try menu("title", "Move to Folder"); try panel("chrome.move")
        try tap("Semester Notes")
        try panel("chrome.move", shown: false)
        try sameContent(before, history: false)
        try ui.tapCommand("window.showLibrary"); try tap("Semester Notes")
        try open(); XCTAssertEqual(try ui.state().document, before.document)
    }

    func testTitleRecognitionLanguageAppliesAndReopens() throws {
        try open(); let before = try ui.state()
        try menu("title", "Recognition Language")
        let english = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 10)); let label = english.label; english.tap()
        try wait("Recognition language must save its selection") { english.isSelected }
        try ui.dismissSheets()
        try menu("title", "Recognition Language")
        XCTAssertTrue(ui.app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.isSelected,
                      "Recognition language must retain the chosen English language")
        try ui.dismissSheets(); try sameContent(before, history: false)
    }

    func testTitleCollaboratorsOpensSharePanelAndCloses() throws {
        try open(); let before = try ui.state()
        try menu("title", "Collaborators")
        _ = try ui.waitForState { !$0.openPanels.isEmpty }
        _ = try require("Share Live")
        try ui.dismissSheets()
        _ = try ui.waitForState { $0.openPanels.isEmpty }
        try sameContent(before)
    }

    func testAddPageMenuAddsExactlyOnePageAndUndoRedo() throws {
        try open(); let before = try ui.state()
        try menu("addPage", "Current Template")
        _ = try ui.waitForState { $0.pageCount == before.pageCount + 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.pageCount == before.pageCount }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.pageCount == before.pageCount + 1 }
    }

    func testShareExportOpensCorrectSheetAndCancelIsInert() throws {
        try open(); let before = try ui.state()
        try menu("share", "Export all…")
        _ = try ui.waitForState { !$0.openPanels.isEmpty }
        _ = try require("PDF")
        // DESIGN §14.7 uses an export popover on iPad, with its own close control.
        if query("Close export options").firstMatch.exists { try tap("Close export options") }
        else { try ui.dismissSheets() }
        _ = try ui.waitForState { $0.openPanels.isEmpty }
        try sameContent(before)
    }

    func testMenusOutsideDismissWithoutInkOrHistoryChanges() throws {
        try open(); let before = try ui.state()
        for (id, row) in [("title", "Rename"), ("addPage", "Current Template"), ("share", "Export all…"), ("more", "Document Editing Settings")] {
            try openMenu(id); _ = try reachable(row)
            outside()
            try wait("Outside tap must close \(id)") { !self.query(row).allElementsBoundByIndex.contains { $0.isHittable } }
            try sameContent(before)
        }
    }

    func testMoreActionsStayScopedAcrossNotebookAndWhiteboardAndRotation() throws {
        try open()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            try more("Go to Page…")
            try panel("pages.goToPage"); try ui.dismissSheets()
            try more("Hide Tools")
            try wait("More Hide Tools must retract palette") { !self.query("tool.pen").firstMatch.exists }
            try more("Show Tools"); _ = try reachable("tool.pen")
        }
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        try tap("menu.more")
        XCTAssertFalse(query("Go to Page…").firstMatch.exists, "Page navigation must not leak into whiteboard overflow")
        outside()
        try ui.selectTool("pen"); try draw()
    }

    // chrome.assistant; panel.open/close; chrome.panelPlacement
    func testAssistantDropletToggleAndEscapeRestoreEditorFocus() throws {
        try open(); let before = try ui.state()
        try tap("Assistant"); try panel("aichat.panel")
        // DESIGN §14.9 transfers the droplet into the header, which has its own Close.
        try tap("Close Assistant"); try panel("aichat.panel", shown: false)
        key("j", .command); try panel("aichat.panel")
        escape(); try panel("aichat.panel", shown: false)
        try sameContent(before); key("p"); try draw()
    }

    func testRegisteredSidebarPanelsAndCloseButton() throws {
        try open(); let before = try ui.state()
        try ui.tapCommand("sidebar.toggle")
        for (title, id) in [("Pages", "sidebar.pages"), ("Outline", "outline.tab"), ("Bookmarks", "outline.bookmarks"), ("History", "undo.history")] {
            // DESIGN §14.4 places the three navigator tabs in the header;
            // Panel Options contains additional registered panels.
            if id == "undo.history" { try tap("Panel Options") }
            try tap(title); try panel(id)
            _ = try require(title)
        }
        try tap("cmd.panel.close")
        _ = try ui.waitForState { $0.openPanels.isEmpty }
        try sameContent(before); try ui.selectTool("pen"); try draw()
    }

    func testSheetDismissAndEscapeDoNotRenameDocument() throws {
        try open(); let before = try ui.state()
        try menu("title", "Rename"); try replace("Title", "Discard this draft")
        try tap("sheet.dismiss"); try panel("chrome.rename", shown: false)
        XCTAssertTrue(query("menu.title").firstMatch.label.contains(notebook))
        try menu("title", "Rename"); escape(); try panel("chrome.rename", shown: false)
        try sameContent(before); try ui.selectTool("pen"); try draw()
    }

    func testPanelLeftRightFloatingPlacementPersistsAndCanvasStaysUsable() throws {
        try open(); let before = try ui.state()
        try ui.tapCommand("sidebar.toggle")
        try tap("Panel Options"); try tap("Move to Right Side")
        let right = try require("Sidebar").frame
        XCTAssertGreaterThan(right.midX, ui.app.frame.midX)
        try tap("Panel Options"); try tap("Move to Left Side")
        let left = try require("Sidebar").frame
        XCTAssertLessThan(left.midX, ui.app.frame.midX)
        try tap("Panel Options"); try tap("Float Panel")
        try wait("Floating panel must release sidebar placement") { !self.query("Sidebar").firstMatch.exists }
        try tap("cmd.panel.close")
        try ui.tapCommand("sidebar.toggle")
        XCTAssertFalse(query("Sidebar").firstMatch.exists, "Panel floating placement must persist when reopened")
        try tap("Panel Options"); try tap("Move to Right Side")
        XCTAssertGreaterThan(try require("Sidebar").frame.midX, ui.app.frame.midX)
        try ui.tapCommand("sidebar.toggle"); try sameContent(before)
        try ui.selectTool("pen"); try draw()
    }

    // chrome.options; chrome.moreTools; chrome.scrubTools
    func testToolSettingsSwitchReplacesPopoverAndInkToolsActuallyDraw() throws {
        try open()
        for (tool, option) in [("pen", "Fountain Pen"), ("highlighter", "Straight line"), ("eraser", "Whole stroke")] {
            try settings(tool); _ = try require(option)
            XCTAssertEqual(query("menu.toolSettings").count, 1, "Only the active tool may own the settings trigger")
            outside()
            if tool != "eraser" { try draw(y: tool == "pen" ? 0.62 : 0.72) }
        }
        try settings("pen")
        try tap("tool.highlighter")
        _ = try ui.waitForState { $0.tool == "highlighter" }
        XCTAssertFalse(query("Fountain Pen").firstMatch.exists, "Switching tools must dismiss the old settings popover")
        try tap("menu.toolSettings"); _ = try require("Straight line")
        XCTAssertFalse(query("Fountain Pen").firstMatch.exists)
    }

    func testSelectedToolTapOpensSettingsAndChangesPenType() throws {
        try open(); try ui.selectTool("pen"); try tap("tool.pen")
        // F007 defines Pencil as a separate canvas tool, not a pen.style value.
        // Reopen the selected tool's settings after choosing it in the type grid.
        try tap("Pencil"); _ = try ui.waitForState { $0.tool == "pencil" }
        outside(); try draw()
        try tap("tool.pencil"); XCTAssertTrue(ui.app.buttons.matching(NSPredicate(format: "label == %@ AND NOT identifier BEGINSWITH %@", "Pencil", "tool.")).firstMatch.isSelected)
        outside(); try draw(y: 0.72)
    }

    func testMoreDrawShapePromotesToolAndProducesUndoableContent() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.drawShape")
        _ = try ui.waitForState { $0.tool == "drawShape" }
        // F030 AutoShape replaces a recognised line with a shape on lift.
        // It must create undoable content, not retain the transient ink stroke.
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.68)])
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.undoAvailable }
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage && $0.strokeCountOnPage == before.strokeCountOnPage }
    }

    func testMoreTapeDrawsUndoableItem() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.tape")
        _ = try ui.waitForState { $0.tool == "tape" }
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.64), CGPoint(x: 0.6, y: 0.64)])
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage }
    }

    func testMorePencilDrawsAndUndoRedoRestoresStroke() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.pencil")
        _ = try ui.waitForState { $0.tool == "pencil" }
        try draw()
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    func testEraserOptionsEraseRealInkAndUndoRestoresIt() throws {
        try open(); try ui.selectTool("pen"); try draw()
        let inked = try ui.state()
        try settings("eraser"); try tap("Whole stroke"); outside()
        try ui.drawStroke([CGPoint(x: 0.5, y: 0.62), CGPoint(x: 0.5, y: 0.72)])
        _ = try ui.waitForState { $0.strokeCountOnPage == inked.strokeCountOnPage - 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == inked.strokeCountOnPage }
    }

    func testShapePaletteCreatesUndoableShape() throws {
        try open(); let before = try ui.state()
        try ui.selectTool("shape")
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.6, y: 0.75)])
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage }
    }

    private func insertTextItem(tool: String, editor: String) throws {
        try open(); let before = try ui.state()
        try ui.selectTool(tool)
        ui.coordinate(CGPoint(x: 0.5, y: 0.65)).tap()
        let field = ui.app.textViews[editor]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Selected tool must open its text editor")
        field.typeText("Chrome accessory text")
        escape()
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.undoAvailable }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage }
    }
    func testTextPaletteInsertsEditableUndoableText() throws { try insertTextItem(tool: "text", editor: "Text box") }
    func testMoreStickyInsertsEditableUndoableNote() throws { try insertTextItem(tool: "sticky", editor: "Sticky note") }

    func testMoreEditHandwritingSelectsToolWithoutAddingInk() throws {
        try open(); try ui.selectTool("pen"); try draw(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.smartink.edit")
        _ = try ui.waitForState { $0.tool == "smartink.edit" }
        try sameContent(before)
        try ui.selectTool("pen"); try draw(y: 0.73)
    }

    func testMoreGraphAccessoryInsertsUndoableGraph() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.math.graph.create"); try panel("mathgraph.editor")
        try replace("Graph expressions, one per line", "y = x")
        try tap("Insert Graph"); try panel("mathgraph.editor", shown: false)
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage }
    }

    func testMoreAudioAccessoryStartsAndStopsRecorder() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.audio.record")
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let allow = alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch
            if allow.exists { allow.tap() }
        }
        _ = try reachable("Pause Recording")
        try tap("Stop Recording")
        try wait("Stop Recording must dismiss the active recorder") { !self.query("Pause Recording").firstMatch.exists }
        try sameContent(before, history: false)
    }

    func testMoreBoardTemplatesAccessoryOpensCorrectPanel() throws {
        try open("Concept map"); let before = try ui.state()
        try tap("tool.more"); try tap("Templates"); try panel("whiteboard.templates")
        try tap("cmd.panel.close"); try panel("whiteboard.templates", shown: false)
        try sameContent(before)
    }

    func testMoreImageOpensSourcePickerAndCancelDoesNotInsert() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.image"); ui.coordinate(CGPoint(x: 0.5, y: 0.65)).tap(); try tap("Files")
        // The native iPad Files picker has a locations sidebar rather than the
        // compact Browse tab. Both are the specified system document picker.
        let locations = ui.app.cells["DOC.sidebar.item.On My iPad"]
        try wait("Files must present its native document picker") {
            locations.exists || self.query("Browse").firstMatch.exists
        }
        try tap("Cancel"); try sameContent(before)
    }

    func testMoreElementsOpensRegisteredPanel() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.elements")
        _ = try ui.waitForState { $0.tool == "elements" }
        try tap("tool.elements"); try replace("Search elements", "Heart"); try tap("Heart")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage }
    }

    func testMoreZoomWindowAndPinchChangeBoundedZoomWithoutMarks() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.zoom.toggle")
        _ = try require("Zoom Window writing area")
        try tap("Close Zoom Window")
        try ui.selectTool("lasso")
        try ui.pinchZoom(scale: 1.5)
        let zoomed = try ui.waitForState { $0.zoom > before.zoom + 0.05 }
        XCTAssertGreaterThanOrEqual(zoomed.zoom, 0.5); XCTAssertLessThanOrEqual(zoomed.zoom, 8)
        try ui.pinchZoom(scale: 0.4)
        let reduced = try ui.waitForState { $0.zoom < zoomed.zoom - 0.05 }
        XCTAssertGreaterThanOrEqual(reduced.zoom, 0.5); XCTAssertLessThanOrEqual(reduced.zoom, 8)
        try sameContent(before)
    }

    func testToolBeadScrubSelectsNeighbourWithoutDockingOrInk() throws {
        try open(); try ui.selectTool("pen"); let before = try ui.state()
        let pen = try reachable("tool.pen"), highlighter = try reachable("tool.highlighter")
        pen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: highlighter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        _ = try ui.waitForState { $0.tool == "highlighter" }
        let dock = try ui.state().paletteDock
        XCTAssertEqual(dock?.edge, before.paletteDock?.edge)
        XCTAssertEqual(try XCTUnwrap(dock?.along), try XCTUnwrap(before.paletteDock?.along), accuracy: 0.02)
        try sameContent(before); try draw()
    }

    // toolbar.dock left/right/top/bottom/return/undo
    private func dragPalette(to point: CGPoint) throws {
        let palette = try reachable("Tools")
        let vertical = palette.frame.height > palette.frame.width
        // Bare rim, away from tools: along-axis drags on a selected tool are intentionally scrubbing.
        let start = palette.coordinate(withNormalizedOffset: CGVector(dx: vertical ? 0.1 : 0.5, dy: vertical ? 0.5 : 0.1))
        start.press(forDuration: 0.15, thenDragTo: ui.app.coordinate(withNormalizedOffset: CGVector(dx: point.x, dy: point.y)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
    }
    private func dock(_ edge: String) throws {
        let target: CGPoint
        switch edge {
        case "left": target = CGPoint(x: 0.04, y: 0.55)
        case "right": target = CGPoint(x: 0.96, y: 0.55)
        case "top": target = CGPoint(x: 0.5, y: 0.15)
        default: target = CGPoint(x: 0.5, y: 0.94)
        }
        try dragPalette(to: target)
        _ = try ui.waitForState(timeout: 12) { $0.paletteDock?.edge == edge }
    }
    func testDockLeftKeepsVerticalToolsUsable() throws {
        try open(); try dock("top"); try dock("left")
        let palette = try require("Tools"); XCTAssertGreaterThan(palette.frame.height, palette.frame.width)
        try ui.selectTool("highlighter"); try draw()
    }
    func testDockRightKeepsSettingsInsideWindow() throws {
        try open(); try dock("right"); try settings("pen")
        let option = try reachable("Fountain Pen")
        XCTAssertTrue(ui.app.frame.contains(option.frame), "Right-docked settings must stay onscreen")
        outside(); try draw()
    }
    func testDockTopHasHorizontalOptionsAndUndoableInk() throws {
        try open(); try dock("top")
        let palette = try require("Tools"); XCTAssertGreaterThan(palette.frame.width, palette.frame.height)
        try settings("highlighter"); try tap("Thickness 2"); outside(); try draw()
    }
    func testDockBottomLeavesLastPageScrollableAboveTools() throws {
        try open(); try dock("bottom")
        try more("Go to Page…"); try replace("Page number or title", "4"); try tap("Go")
        let before = try ui.state()
        try ui.twoFingerScroll(from: CGPoint(x: 0.12, y: 0.85), to: CGPoint(x: 0.12, y: 0.3))
        _ = try ui.waitForState { $0.contentOffset.y > before.contentOffset.y + 10 }
        try ui.selectTool("pen"); try draw(y: 0.5)
    }
    func testInvalidMiddleDropReturnsHomeAndCompactRejectsSideDock() throws {
        try open(); let before = try ui.state()
        try dragPalette(to: CGPoint(x: 0.5, y: 0.52))
        _ = try ui.waitForState { $0.paletteDock?.edge == before.paletteDock?.edge }
        XCTAssertEqual(try XCTUnwrap(ui.state().paletteDock?.along), try XCTUnwrap(before.paletteDock?.along), accuracy: 0.02)
        if ui.app.frame.width < 600 {
            try dragPalette(to: CGPoint(x: 0.02, y: 0.5))
            XCTAssertTrue(["top", "bottom"].contains(try XCTUnwrap(ui.state().paletteDock?.edge)))
        }
        try sameContent(before, history: false)
    }
    func testDockKeyboardUndoRedoRestoresEdgeAndAlongWithDocumentPriority() throws {
        try open(); let before = try ui.state(); XCTAssertFalse(before.undoAvailable)
        try dock("right"); let moved = try ui.state()
        key("z", .command)
        _ = try ui.waitForState { $0.paletteDock?.edge == before.paletteDock?.edge }
        XCTAssertEqual(try XCTUnwrap(ui.state().paletteDock?.along), try XCTUnwrap(before.paletteDock?.along), accuracy: 0.02)
        key("z", [.command, .shift])
        _ = try ui.waitForState { $0.paletteDock?.edge == moved.paletteDock?.edge }
        try ui.selectTool("pen"); try draw(); try dock("top")
        key("z", .command)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        XCTAssertEqual(try ui.state().paletteDock?.edge, "top", "Document ink must undo before the window's newer docking step")
        key("z", [.command, .shift])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    // toolbar.setVisible/setLayout/reset/saveLayout/applyLayout/deleteLayout
    func testHideShowToolsThroughMoreKeyboardAndPullDown() throws {
        try open(); let before = try ui.state()
        try more("Hide Tools")
        try wait("Hide Tools must remove tools and options") { !self.query("tool.pen").firstMatch.exists && !self.query("menu.toolSettings").firstMatch.exists }
        key("w"); _ = try reachable("tool.pen")
        key("w"); try wait("W must hide palette") { !self.query("tool.pen").firstMatch.exists }
        try tap("Show Tools"); _ = try reachable("tool.pen")
        try ui.twoFingerScroll(from: CGPoint(x: 0.12, y: 0.35), to: CGPoint(x: 0.12, y: 0.75))
        try more("Hide Tools"); try more("Show Tools"); _ = try reachable("menu.toolSettings")
        try sameContent(before); try ui.selectTool("pen"); try draw()
    }
    func testPageScrollCollapsesOptionsAndChoosingToolRestoresThem() throws {
        try open(); try ui.selectTool("pen"); let before = try ui.state()
        _ = try reachable("menu.toolSettings")
        try ui.twoFingerScroll(from: CGPoint(x: 0.12, y: 0.75), to: CGPoint(x: 0.12, y: 0.45))
        _ = try ui.waitForState { abs($0.contentOffset.y - before.contentOffset.y) > 20 }
        try wait("Page scrolling must collapse the secondary options bar") {
            !self.query("menu.toolSettings").firstMatch.exists
        }
        try ui.selectTool("highlighter"); _ = try reachable("menu.toolSettings")
        try settings("highlighter"); try tap("Thickness 2"); outside(); try draw()
    }
    private func customize() throws { try more("Customise Toolbar"); try panel("toolbar.customize") }
    private func doneCustomizing() throws { try tap("sheet.dismiss"); try panel("toolbar.customize", shown: false) }
    private func saveLayout(_ name: String) throws {
        try tap("Save Current Layout"); try replace("Layout name", name); try tap("cmd.toolbar.saveLayout")
        _ = try reachable("Apply " + name)
    }
    func testCustomizeHideShowAndReorderPersistsWithLassoFixedFirst() throws {
        try open(); try customize()
        XCTAssertFalse(query("Hide Lasso").firstMatch.exists, "Lasso cannot be hidden")
        try tap("Hide Highlighter"); _ = try require("Show Highlighter")
        try doneCustomizing()
        XCTAssertFalse(query("tool.highlighter").firstMatch.exists)
        try tap("tool.more"); try tap("tool.highlighter"); try draw()
        try customize(); try tap("Show Highlighter")
        let handle = ui.app.buttons.matching(NSPredicate(format: "label CONTAINS 'Reorder' AND label CONTAINS 'Highlighter'")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "Customise must expose a real reorder handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: try reachable("Hide Fountain Pen").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2)))
        try doneCustomizing(); try customize()
        XCTAssertFalse(query("Hide Lasso").firstMatch.exists)
        XCTAssertLessThan(try reachable("Hide Highlighter").frame.minY, try reachable("Hide Fountain Pen").frame.minY, "Reordered layout must persist")
    }
    func testSaveLayoutRejectsBlankAndNamedLayoutAppears() throws {
        try open(); try customize(); try tap("Save Current Layout")
        XCTAssertFalse(try require("cmd.toolbar.saveLayout").isEnabled)
        try replace("Layout name", "   "); XCTAssertFalse(query("cmd.toolbar.saveLayout").firstMatch.isEnabled)
        try replace("Layout name", "Chrome layout"); try tap("cmd.toolbar.saveLayout")
        _ = try reachable("Apply Chrome layout")
        try doneCustomizing(); try customize(); _ = try reachable("Apply Chrome layout")
    }
    func testApplySavedLayoutRestoresVisibility() throws {
        try open(); try customize(); try tap("Hide Highlighter"); try saveLayout("Minimal chrome")
        try tap("Show Highlighter"); try tap("Apply Minimal chrome")
        _ = try reachable("Show Highlighter"); XCTAssertFalse(query("Hide Highlighter").firstMatch.exists)
        try doneCustomizing(); XCTAssertFalse(query("tool.highlighter").firstMatch.exists)
        try tap("tool.more"); try tap("tool.highlighter"); try draw()
    }

    func testApplySavedLayoutRestoresReorderedToolsWithLassoFirst() throws {
        try open(); try customize()
        let handle = ui.app.buttons.matching(NSPredicate(format: "label CONTAINS 'Reorder' AND label CONTAINS 'Highlighter'")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        // Native reordering uses the row's insertion boundary. Keep the drag
        // in the handle column, above Pen's centre, rather than dropping on Hide.
        let pen = try reachable("Hide Fountain Pen").frame
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: start.withOffset(
            CGVector(dx: 0, dy: pen.minY - handle.frame.midY)))
        try wait("Reordering must move Highlighter above Pen") {
            self.query("Hide Highlighter").firstMatch.frame.minY < self.query("Hide Fountain Pen").firstMatch.frame.minY
        }
        try saveLayout("Reordered chrome")
        try tap("Reset Toolbar"); try tap("Reset Writing Tools")
        try tap("Apply Reordered chrome")
        XCTAssertLessThan(try reachable("Hide Highlighter").frame.minY, try reachable("Hide Fountain Pen").frame.minY)
        XCTAssertFalse(query("Hide Lasso").firstMatch.exists)
        try doneCustomizing()
        let lasso = try reachable("tool.lasso").frame, highlighter = try reachable("tool.highlighter").frame
        if let edge = try ui.state().paletteDock?.edge, ["left", "right"].contains(edge) {
            XCTAssertLessThan(lasso.midY, highlighter.midY)
        } else { XCTAssertLessThan(lasso.midX, highlighter.midX) }
        try ui.selectTool("highlighter"); try draw()
    }
    func testDeleteSavedLayoutOnlyRemovesChosenName() throws {
        try open(); try customize(); try saveLayout("Keep chrome"); try saveLayout("Delete chrome")
        let row = ui.app.cells.containing(.button, identifier: "Apply Delete chrome").firstMatch
        XCTAssertTrue(row.exists, "Saved layout must expose a deletable row")
        row.swipeLeft(); try tap("Delete")
        try wait("Delete must remove only the chosen saved layout") { !self.query("Apply Delete chrome").firstMatch.exists }
        _ = try reachable("Apply Keep chrome")
        try doneCustomizing(); try customize()
        XCTAssertFalse(query("Apply Delete chrome").firstMatch.exists)
        _ = try reachable("Apply Keep chrome")
    }
    private func reset(_ action: String, tools: Bool, accessories: Bool) throws {
        try open(); try customize()
        try tap("Hide Highlighter"); try tap("Show Ruler"); try saveLayout("Retained reset layout")
        try tap("Reset Toolbar"); try tap(action)
        _ = try reachable(tools ? "Hide Highlighter" : "Show Highlighter")
        _ = try reachable(accessories ? "Show Ruler" : "Hide Ruler")
        _ = try reachable("Apply Retained reset layout")
        XCTAssertFalse(query("Hide Lasso").firstMatch.exists)
    }
    func testResetWritingToolsPreservesAccessoriesAndSavedLayouts() throws { try reset("Reset Writing Tools", tools: true, accessories: false) }
    func testResetAccessoriesPreservesWritingToolsAndSavedLayouts() throws { try reset("Reset Accessories", tools: false, accessories: true) }
    func testResetWholeToolbarRestoresBothGroupsAndKeepsSavedLayouts() throws { try reset("Reset Whole Toolbar", tools: true, accessories: true) }

    // chrome.tabs; tab.select/close/closeOthers; window.open; windows.restore
    private func showTabs(_ on: Bool) throws {
        try editing("Tabs"); try toggle("Show document tabs", to: on); try closeEditing()
    }
    private func newNotebook(_ title: String) throws {
        let old = try ui.state().document
        key("n", [.command, .option])
        try replace("Title", title)
        try tap("No cover"); try ui.tapCommand("doc.create")
        _ = try ui.waitForState { $0.screen == "document" && $0.document != old }
    }
    private func secondTab() throws -> (QAState, QAState) {
        try open(); try showTabs(true); let first = try ui.state()
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        return (first, try ui.state())
    }
    func testTabsOverflowAndKeyboardOneThroughEightAndNineLast() throws {
        try open(); try showTabs(true)
        var documents = [try XCTUnwrap(ui.state().document)]
        for index in 2...9 {
            try newNotebook("Chrome tab \(index)")
            documents.append(try XCTUnwrap(ui.state().document))
        }
        try tap("Tabs"); try tap(notebook)
        _ = try ui.waitForState { $0.document == documents[0] }
        for index in 1...8 {
            key(String(index), .command)
            _ = try ui.waitForState { $0.document == documents[index - 1] }
        }
        key("9", .command); _ = try ui.waitForState { $0.document == documents[8] }
        try showTabs(false)
        XCTAssertFalse(query("Tabs").firstMatch.exists)
        key("1", .command); _ = try ui.waitForState { $0.document == documents[0] }
        try showTabs(true); try tap("Tabs"); try tap("Chrome tab 9")
        _ = try ui.waitForState { $0.document == documents[8] }
    }
    func testSwitchTabRestoresPageZoomToolAndSavedInk() throws {
        try open(); try showTabs(true)
        try more("Go to Page…"); try replace("Page number or title", "2"); try tap("Go")
        try ui.selectTool("pen"); try draw()
        try ui.selectTool("lasso"); try ui.pinchZoom(scale: 1.4)
        let first = try ui.state()
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        try ui.selectTool("highlighter"); let board = try ui.state()
        key("1", .command)
        let restored = try ui.waitForState { $0.document == first.document && $0.page == first.page }
        XCTAssertEqual(restored.strokeCountOnPage, first.strokeCountOnPage)
        XCTAssertEqual(restored.tool, first.tool)
        XCTAssertEqual(restored.zoom, first.zoom, accuracy: 0.05)
        try tap("Tabs"); try tap("Concept map")
        let selected = try ui.waitForState { $0.document == board.document }
        XCTAssertEqual(selected.page, board.page); XCTAssertEqual(selected.tool, board.tool)
    }
    func testCloseTabButtonAndKeyboardCloseAllKeepLibraryDocuments() throws {
        let (first, second) = try secondTab()
        // The strip may have no capsule-sized gap; its overflow remains the real tab route.
        try tap("Tabs")
        try tap("Close Tab")
        _ = try ui.waitForState { $0.document == first.document }
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        XCTAssertEqual(try ui.state().document, second.document)
        key("w", .command); _ = try ui.waitForState { $0.document == first.document }
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        key("w", [.command, .option])
        _ = try ui.waitForState { $0.screen == "library" && $0.document == nil }
        try open(); XCTAssertEqual(try ui.state().document, first.document)
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        XCTAssertEqual(try ui.state().document, second.document)
    }
    func testTitleCloseOtherTabsKeepsChosenDocumentWithoutDeletingOthers() throws {
        let (first, second) = try secondTab()
        try menu("title", "Close Other Tabs")
        XCTAssertEqual(try ui.state().document, second.document)
        key("w", .command)
        _ = try ui.waitForState { $0.screen == "library" && $0.document == nil }
        try open(); XCTAssertEqual(try ui.state().document, first.document)
    }
    func testNewWindowKeyboardOpensIndependentScene() throws {
        try open(); let before = try ui.state()
        key("n", .command)
        try wait("Command-N must open an independent library scene", timeout: 20) {
            self.ui.app.descendants(matching: .any).matching(identifier: "nib.qa.state").allElementsBoundByIndex.contains {
                guard let value = $0.value as? String, let data = value.data(using: .utf8),
                      let state = try? JSONDecoder().decode(QAState.self, from: data) else { return false }
                return state.screen == "library"
            }
        }
        // OS window switching is a real gesture; the document scene must remain in the app switcher.
        XCUIDevice.shared.press(.home); ui.app.activate()
        let probes = ui.app.descendants(matching: .any).matching(identifier: "nib.qa.state").allElementsBoundByIndex
        XCTAssertFalse(probes.isEmpty)
        XCTAssertNotNil(before.document)
    }
    func testLibraryOpenInNewWindowTargetsSelectedDocument() throws {
        try open(); try ui.selectTool("pen"); try draw(); let before = try ui.state()
        try ui.tapCommand("window.showLibrary")
        let item = ui.app.descendants(matching: .any).matching(identifier: "cmd.doc.open")
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", notebook, notebook + ",")).firstMatch
        item.press(forDuration: 0.8); try tap("Open in New Window")
        try wait("New scene must open the selected document with its saved ink", timeout: 20) {
            self.ui.app.descendants(matching: .any).matching(identifier: "nib.qa.state").allElementsBoundByIndex.contains {
                guard let value = $0.value as? String, let state = try? JSONDecoder().decode(QAState.self, from: Data(value.utf8)) else { return false }
                return state.document == before.document && state.strokeCountOnPage == before.strokeCountOnPage
            }
        }
    }
    func testBackgroundReopenRestoresTabsPageAndSavedEdits() throws {
        try open(); try showTabs(true)
        try more("Go to Page…"); try replace("Page number or title", "2"); try tap("Go")
        try ui.selectTool("pen"); try draw(); let saved = try ui.state()
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        let board = try ui.state()
        XCUIDevice.shared.press(.home); ui.app.activate()
        _ = try ui.waitForState { $0.document == board.document && $0.page == board.page }
        key("1", .command)
        _ = try ui.waitForState { $0.document == saved.document && $0.page == saved.page && $0.strokeCountOnPage == saved.strokeCountOnPage }
        key("9", .command); _ = try ui.waitForState { $0.document == board.document }
    }

    // view.setReadOnly
    func testReadOnlyButtonBlocksInkAndTitleEditRestoresTools() throws {
        try open(); try ui.selectTool("pen"); let before = try ui.state()
        try ui.tapCommand("view.setReadOnly")
        try wait("Read-only mode retracts palette") { !self.query("tool.pen").firstMatch.exists }
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.69)])
        try sameContent(before)
        try menu("title", "Edit"); _ = try reachable("tool.pen"); try draw()
    }
    func testReadOnlyKeyboardToggleRestoresEditing() throws {
        try open(); let before = try ui.state()
        key("r", [.command, .option])
        try wait("Option-Command-R must retract editing tools") { !self.query("tool.pen").firstMatch.exists }
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.69)])
        try sameContent(before)
        key("r", [.command, .option]); try ui.selectTool("pen"); try draw()
    }

    // layer.panel/setActive/setVisible/rename
    private func layers() throws {
        try open(); try editing("Layers"); try toggle("Layers", to: true); try closeEditing()
        try more("Layers"); try panel("layers")
    }
    func testLayersSettingMenuAndShortcutReflectFiveLayers() throws {
        try layers()
        for number in 1...5 { _ = try require("Layer \(number)") }
        XCTAssertTrue(try require("Layer 1").isSelected)
        try tap("cmd.panel.close"); try panel("layers", shown: false)
        key("l", [.command, .option]); try panel("layers")
        try tap("cmd.panel.close")
        try editing("Layers"); try toggle("Layers", to: false); try closeEditing()
        try tap("menu.more"); XCTAssertFalse(query("Layers").firstMatch.exists)
    }
    func testActiveLayerRoutesNewInkAndKeyboardChangesSelectionScope() throws {
        try layers(); try tap("Layer 2")
        XCTAssertTrue(try require("Layer 2").isSelected)
        let baseline = try require("Layer 2").value as? String
        try tap("cmd.panel.close"); try ui.selectTool("pen"); try draw()
        key("l", [.command, .option]); try panel("layers")
        XCTAssertNotEqual(try require("Layer 2").value as? String, baseline, "New stroke must belong to chosen layer")
        XCTAssertTrue((query("Layer 2").firstMatch.value as? String ?? "").contains("1 item"))
        try tap("cmd.panel.close"); key("3", [.command, .option]); try draw(y: 0.73)
        key("l", [.command, .option]); XCTAssertTrue(try require("Layer 3").isSelected)
        XCTAssertTrue((query("Layer 3").firstMatch.value as? String ?? "").contains("1 item"))
    }
    func testActiveLayerLimitsLassoSelectionToChosenLayer() throws {
        try layers(); try tap("Layer 2"); try tap("cmd.panel.close")
        try ui.selectTool("pen"); try draw(y: 0.62)
        key("3", [.command, .option]); try draw(y: 0.72)
        try ui.selectTool("lasso")
        let outline = [CGPoint(x: 0.35, y: 0.58), CGPoint(x: 0.65, y: 0.58),
                       CGPoint(x: 0.65, y: 0.78), CGPoint(x: 0.35, y: 0.78), CGPoint(x: 0.35, y: 0.58)]
        try ui.drawStroke(outline)
        _ = try ui.waitForState { $0.selectionCount == 1 }
        key("2", [.command, .option]); try ui.drawStroke(outline)
        _ = try ui.waitForState { $0.selectionCount == 1 }
    }
    func testLayerVisibilityChangesViewerWithoutDeletingContentAndPersists() throws {
        try layers(); try tap("Layer 2"); try tap("cmd.panel.close")
        try ui.selectTool("pen"); try draw(); let before = try ui.state()
        let visible = ui.canvas.screenshot().pngRepresentation
        key("l", [.command, .option]); try tap("Hide Layer 2")
        XCTAssertTrue((try require("Layer 2").value as? String ?? "").contains("Hidden"))
        try tap("cmd.panel.close")
        XCTAssertNotEqual(ui.canvas.screenshot().pngRepresentation, visible, "Hidden-layer ink must disappear from viewer")
        try sameContent(before)
        key("l", [.command, .option]); try tap("Show Layer 2")
        XCTAssertFalse((try require("Layer 2").value as? String ?? "").contains("Hidden"))
        try tap("cmd.panel.close"); try sameContent(before)
    }
    func testRenameLayerKeepsItsContentAndSupportsUndoRedo() throws {
        try layers(); let before = try ui.state()
        let oldValue = try require("Layer 1").value as? String
        try reachable("Layer 1").press(forDuration: 0.8); try tap("Rename…")
        try replace("Layer name", "Chrome annotations"); try tap("Rename")
        XCTAssertEqual(try require("Chrome annotations").value as? String, oldValue)
        try sameContent(before, history: false)
        key("z", .command); _ = try require("Layer 1")
        key("z", [.command, .shift]); _ = try require("Chrome annotations")
    }

    // laser; laser.setMode
    func testLaserPaletteAndKeyboardPointingNeverEditOrAddUndo() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.laser")
        _ = try ui.waitForState { $0.tool == "laser" }
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.7)])
        try sameContent(before)
        key("p"); _ = try ui.waitForState { $0.tool == "pen" }
        key("l"); _ = try ui.waitForState { $0.tool == "laser" }
        ui.coordinate(CGPoint(x: 0.5, y: 0.6)).press(forDuration: 0.4)
        try sameContent(before)
    }
    func testLaserDotTrailColourAndLengthPersistWithoutDocumentItems() throws {
        try open(); let before = try ui.state()
        try settings("laser"); try tap("Trail"); try tap("Long"); try tap("Cobalt")
        XCTAssertTrue(try require("Trail").isSelected); XCTAssertTrue(try require("Long").isSelected)
        outside()
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.6, y: 0.7)])
        try sameContent(before)
        try settings("laser"); XCTAssertTrue(try require("Trail").isSelected)
        XCTAssertTrue(try require("Long").isSelected); XCTAssertTrue(try require("Cobalt").isSelected)
        try tap("Dot"); XCTAssertTrue(try require("Dot").isSelected); outside()
        ui.coordinate(CGPoint(x: 0.5, y: 0.65)).press(forDuration: 0.3)
        try sameContent(before)
    }

    // ruler.set/transform/options
    private var ruler: XCUIElement { ui.app.otherElements.matching(identifier: "Ruler").firstMatch }
    private func showRuler() throws {
        try open(); try tap("tool.more"); try tap("cmd.ruler.set")
        XCTAssertTrue(ruler.waitForExistence(timeout: 8), "Ruler must appear on canvas")
    }
    private func rulerMenu(_ action: String) throws { ruler.doubleTap(); try tap(action) }
    func testRulerPaletteAndKeyboardToggleWithoutDocumentItems() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.ruler.set")
        XCTAssertTrue(ruler.waitForExistence(timeout: 8))
        key("r"); try wait("R must hide ruler and angle HUD") { !self.ruler.exists }
        key("r"); XCTAssertTrue(ruler.waitForExistence(timeout: 8))
        try rulerMenu("Hide Ruler"); try wait("Hide Ruler must remove overlay") { !self.ruler.exists }
        try sameContent(before)
    }
    func testRulerMoveAndAngleControlsSnapToZeroFortyFiveNinety() throws {
        try showRuler(); let before = try ui.state(), old = ruler.frame
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        XCTAssertGreaterThan(ruler.frame.midY, old.midY + 30)
        for angle in [0, 45, 90] {
            try rulerMenu("Set Angle…"); try replace("Angle in degrees", String(angle)); try tap("Set Angle")
            try wait("Ruler angle must be \(angle) degrees") { (self.ruler.value as? String ?? "").hasPrefix("\(angle) degrees") }
        }
        try sameContent(before)
    }

    func testRulerTwoFingerRotationSnapsToFortyFiveWithoutEditing() throws {
        try showRuler(); let before = try ui.state()
        try rulerMenu("Set Angle…"); try replace("Angle in degrees", "0"); try tap("Set Angle")
        let frame = ruler.frame, radius = min(frame.width * 0.3, 90)
        let paths = [CGFloat(-1), CGFloat(1)].map { direction in
            (0...12).map { step -> NSValue in
                let angle = CGFloat(step) / 12 * .pi / 4
                return NSValue(cgPoint: CGPoint(x: frame.midX + direction * radius * cos(angle),
                                               y: frame.midY - direction * radius * sin(angle)))
            }
        }
        let done = XCTestExpectation(description: "Two fingers rotate ruler")
        var failure: Error?
        NibTouchPaths.perform(paths, duration: 0.8) { error in failure = error; done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 16), .completed)
        if let failure { throw failure }
        try wait("Two-finger rotation must snap to 45 degrees") {
            (self.ruler.value as? String ?? "").hasPrefix("45 degrees")
        }
        try sameContent(before)
    }
    func testRulerUnitsDigitsAndPositionChoicesPersist() throws {
        try showRuler(); let before = try ui.state()
        try rulerMenu("Options"); try tap("Inches")
        XCTAssertTrue((ruler.value as? String ?? "").contains("Inches"))
        let withDigits = ui.canvas.screenshot().pngRepresentation
        try rulerMenu("Options"); try tap("Hide Digits")
        XCTAssertNotEqual(ui.canvas.screenshot().pngRepresentation, withDigits, "Hide Digits must change the rendered ruler")
        try rulerMenu("Set Position…")
        try replace("Horizontal position", "4"); try replace("Vertical position", "5"); try tap("Move Ruler")
        try rulerMenu("Set Position…")
        XCTAssertEqual(try require("Horizontal position").value as? String, "4")
        XCTAssertEqual(try require("Vertical position").value as? String, "5")
        try tap("Cancel"); try sameContent(before)
    }
    func testRulerEdgeConstrainsRealInkAndStrokeIsUndoable() throws {
        try showRuler(); try rulerMenu("Set Angle…"); try replace("Angle in degrees", "0"); try tap("Set Angle")
        try ui.selectTool("pen"); let before = try ui.state(), frame = ruler.frame, canvas = ui.canvas.frame
        // Finger just outside the body, within the 20-page-point projection band.
        let y = (frame.maxY + 5 - canvas.minY) / canvas.height
        let x = max(0.4, (frame.minX + 50 - canvas.minX) / canvas.width)
        try ui.drawStroke([CGPoint(x: x, y: y), CGPoint(x: x + 0.16, y: y + 0.006)])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        key("r"); try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    // timer.panel/start/control/modes/history; stopwatch.start/lap
    private func timeKeeper() throws { try more("Time Keeper"); try panel("timekeeper") }
    private var clockValue: XCUIElement {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ' remaining' OR label ENDSWITH ' elapsed'")).firstMatch
    }
    private func timer(_ duration: String = "1:30", name: String = "Chrome countdown") throws {
        try timeKeeper(); try replace("Duration", duration); try replace("Timer name", name)
        // End field editing before a global canvas shortcut can be interpreted as text.
        key(XCUIKeyboardKey.escape.rawValue)
        try tap("Start Timer")
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 2), alert.buttons["Don't Allow"].exists { alert.buttons["Don't Allow"].tap() }
        try wait("Countdown must expose a running clock") { self.clockValue.exists }
    }
    func testTimeKeeperPaletteAndKeyboardToggleRetainActiveCountdown() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.timer.control"); try panel("timekeeper")
        key("k"); try panel("timekeeper", shown: false)
        try timer()
        let first = clockValue.label
        try tap("Hide Time Keeper")
        key("k")
        try wait("Restored timer must still advance") { self.clockValue.exists && self.clockValue.label != first }
        try sameContent(before)
    }
    func testTimerPresetStartsCountdownAndCustomNameAdvances() throws {
        try open(); try timeKeeper(); try tap("5 min")
        XCTAssertTrue(try require("5 min").isSelected)
        try replace("Timer name", "Preset countdown"); try tap("Start Timer")
        try wait("Preset countdown must run") { self.clockValue.exists }
        let before = clockValue.label
        try wait("Countdown must decrease", timeout: 8) { self.clockValue.label != before }
        try tap("Stop and Save")
        try timer("0:45", name: "Custom countdown")
        XCTAssertTrue(clockValue.label.contains("Custom countdown"))
    }
    func testTimerPauseResumeSaveAndDiscardControlTimeAndHistory() throws {
        try open(); try timer()
        try tap("Pause"); _ = try require("Resume")
        let paused = clockValue.label
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clockValue.label != paused }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 2), .timedOut, "Paused countdown must stop advancing")
        key("k", [.command, .shift]); _ = try require("Pause")
        try wait("Resume must advance countdown") { self.clockValue.label != paused }
        try tap("Stop and Save"); try timeKeeper()
        _ = try reachable("Chrome countdown")
        try tap("cmd.panel.close")
        try timer("1:00", name: "Discarded countdown")
        try timeKeeper(); try tap("Discard Session"); try tap("Discard Session")
        _ = try reachable("Start Timer")
        XCTAssertFalse(query("Discarded countdown").firstMatch.exists, "Discarded session must not enter history")
    }
    func testTimerCompletionRestartAndDonePreserveHistory() throws {
        try open(); try timer("0:08", name: "Short countdown")
        _ = try require("Start Again", timeout: 20)
        try tap("Start Again")
        _ = try require("Pause")
        _ = try require("Start Again", timeout: 20)
        try tap("Done"); try timeKeeper()
        _ = try reachable("Short countdown")
        _ = try reachable("Start Timer")
    }
    func testStopwatchAdvancesPauseRetainsElapsedAndLapsDoNotReset() throws {
        try open(); try timeKeeper(); try tap("Stopwatch"); try tap("Start Stopwatch")
        try wait("Stopwatch must expose elapsed clock") { self.clockValue.exists }
        let start = clockValue.label
        try wait("Stopwatch elapsed time must advance") { self.clockValue.label != start }
        try tap("Record Lap"); key("k", [.command, .option])
        try timeKeeper()
        let laps = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Lap ' AND label CONTAINS 'total'"))
        XCTAssertEqual(laps.count, 2, "Tap and Option-Command-K each record one lap")
        try tap("Pause"); let paused = clockValue.label
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clockValue.label != paused }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 2), .timedOut)
        try tap("Resume"); try wait("Stopwatch must resume from elapsed time") { self.clockValue.label != paused }
        XCTAssertEqual(laps.count, 2)
        try tap("Stop and Save")
        _ = try reachable("Stopwatch")
    }
    func testTimerSaveAndDeleteModesPersistAcrossPanelReopen() throws {
        try open(); try timeKeeper(); try replace("Duration", "2:30")
        try replace("New mode name", "Chrome study"); try tap("Save Mode")
        _ = try reachable("Delete Chrome study")
        try tap("cmd.panel.close"); try timeKeeper()
        try tap("Chrome study")
        XCTAssertEqual(try require("Duration").value as? String, "2:30")
        try tap("Delete Chrome study"); try tap("Delete Mode")
        try wait("Delete Mode must remove the saved preset") { !self.query("Delete Chrome study").firstMatch.exists }
        try tap("cmd.panel.close"); try timeKeeper()
        XCTAssertFalse(query("Delete Chrome study").firstMatch.exists)
    }
    func testTimerHistoryShowsDocumentDurationsAndNoDuplicateRows() throws {
        try open()
        for index in 1...6 {
            try timer("1:00", name: "Chrome history \(index)")
            try tap("Stop and Save")
        }
        try timeKeeper(); try tap("Show All")
        for index in 1...6 {
            _ = try reachable("Chrome history \(index)")
            XCTAssertEqual(ui.app.staticTexts.matching(identifier: "Chrome history \(index)").count, 1, "History must contain each session exactly once")
        }
        XCTAssertTrue(ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", notebook)).count >= 6,
                      "Each history record must name its document")
        try tap("Show Less"); try tap("Show All")
        XCTAssertEqual(ui.app.staticTexts.matching(identifier: "Chrome history 6").count, 1)
    }

    // pdf.textActions/markSelection/copyDefineSpeak. An external input PDF is generated in a
    // disposable Files subfolder; importing, selecting and annotating it all use the actual UI.
    // No document package, settings, probe, app command or selection is injected.
    private func importTextPDF() throws {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let fm = FileManager.default
        let roots = try fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil).flatMap { container in
            (try? fm.contentsOfDirectory(at: container.appendingPathComponent("tmp"), includingPropertiesForKeys: [.creationDateKey])) ?? []
        }.filter { $0.lastPathComponent.hasPrefix("NibUITests-") }
        let fixture = try XCTUnwrap(roots.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.first)
        let folderName = "Chrome PDF " + String(UUID().uuidString.prefix(8))
        let folder = fixture.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Documents").appendingPathComponent(folderName)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        imports = folder
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            let text = "Velocity measures displacement over time. Acceleration changes velocity."
            (text as NSString).draw(in: CGRect(x: 72, y: 380, width: 450, height: 110),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.black])
        }
        try data.write(to: folder.appendingPathComponent("Chrome selection.pdf"))
        try tap("New"); try tap("Import Files")
        let local = ui.app.cells["DOC.sidebar.item.On My iPad"]
        if local.waitForExistence(timeout: 5), local.isHittable { local.tap() }
        let nib = ui.app.cells["Nib, Container"]
        if nib.waitForExistence(timeout: 3), nib.isHittable { nib.tap() }
        let directory = ui.app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folderName)).firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 10), "Files must show external PDF input folder")
        directory.tap()
        let pdf = ui.app.cells.matching(NSPredicate(format: "label CONTAINS 'Chrome selection'")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 10)); pdf.tap()
        let pick = ui.app.buttons["Open"]
        if pick.waitForExistence(timeout: 2), pick.isHittable { pick.tap() }
        _ = try ui.waitForState { $0.screen == "document" && $0.pageCount == 1 }
        try ui.selectTool("lasso")
    }
    private func selectPDFText() throws {
        let papers = ui.app.otherElements.matching(NSPredicate(format: "label == 'Page 1 of 1'"))
        let paper = try XCTUnwrap(papers.allElementsBoundByIndex.first { $0.frame.height > 100 }, "Imported PDF must expose its page")
        paper.coordinate(withNormalizedOffset: CGVector(dx: 115.0 / 595, dy: 393.0 / 842)).press(forDuration: 1)
        _ = try require("Highlight")
    }
    private func pdfAction(_ name: String) throws {
        if !query(name).firstMatch.isHittable {
            let next = ui.app.buttons["Show more items"]
            if next.exists { next.tap() }
        }
        try tap(name)
    }
    func testPDFLongPressOffersTextActionsAndOutsideDismissIsInert() throws {
        try importTextPDF(); let before = try ui.state(); try selectPDFText()
        for action in ["Highlight", "Strikethrough", "Define", "Speak", "Copy"] { _ = try require(action) }
        outside(); try sameContent(before)
    }
    private func markPDF(_ action: String) throws {
        try importTextPDF(); let before = try ui.state(); try selectPDFText(); try pdfAction(action)
        let marked = try ui.waitForState { $0.strokeCountOnPage > before.strokeCountOnPage && $0.undoAvailable }
        XCTAssertEqual(marked.itemCountOnPage - before.itemCountOnPage, marked.strokeCountOnPage - before.strokeCountOnPage,
                       "PDF annotation must be erasable ink over the selected range")
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage && $0.itemCountOnPage == before.itemCountOnPage }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.strokeCountOnPage == marked.strokeCountOnPage }
    }
    func testPDFHighlightCreatesUndoableRangeAnnotation() throws { try markPDF("Highlight") }
    func testPDFStrikethroughCreatesUndoableRangeAnnotation() throws { try markPDF("Strikethrough") }
    func testPDFCopyPastesSelectedTextIntoRenameField() throws {
        try importTextPDF(); let before = try ui.state(); try selectPDFText(); try pdfAction("Copy")
        _ = try ui.waitForState { ($0.clipboardChangeCount ?? 0) > (before.clipboardChangeCount ?? 0) }
        try menu("title", "Rename")
        let field = try reachable("Title"); field.tap(); key("a", .command); key("v", .command)
        try wait("PDF Copy must put the selected text on the real pasteboard") { (field.value as? String ?? "").contains("Velocity") }
        try tap("sheet.dismiss"); try sameContent(before)
    }
    func testPDFDefineOpensDictionaryForSelectedText() throws {
        try importTextPDF(); let before = try ui.state(); try selectPDFText(); try pdfAction("Define")
        _ = try require("Done")
        XCTAssertTrue(ui.app.navigationBars.count > 0, "Define must present the system dictionary")
        try tap("Done"); try sameContent(before)
    }
    func testPDFSpeakStartsSpeechAndOffersStopSpeaking() throws {
        try importTextPDF(); let before = try ui.state(); try selectPDFText(); try pdfAction("Speak")
        try selectPDFText(); try pdfAction("Stop Speaking")
        try sameContent(before)
    }

    // present.setMode/controls. The shared lane has no external display. Verify that the
    // disconnected UI is correctly scoped; the full actions below also run if a display is supplied.
    func testPresentationModesAndControlsAreScopedToConnectedDisplay() throws {
        try open(); let before = try ui.state(); try tap("menu.share")
        if query("Mirror Entire Screen").firstMatch.exists {
            for mode in ["Mirror Entire Screen", "Presenter Page", "Full Page"] {
                try tap(mode); try tap("menu.share")
                XCTAssertTrue(try require(mode).isSelected, "Share mode checkmark must follow the selected presentation mode")
            }
            outside(); try tap("Blank Screen"); _ = try require("Show Screen")
            try tap("Show Screen"); _ = try require("Blank Screen")
            try tap("Laser Pointer"); _ = try ui.waitForState { $0.tool == "laser" }
            try ui.drawStroke([CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.6, y: 0.65)])
            try sameContent(before)
            try ui.twoFingerScroll(from: CGPoint(x: 0.12, y: 0.8), to: CGPoint(x: 0.12, y: 0.25))
            try tap("Stop Presenting"); try wait("Stop must dismiss presenter HUD") { !self.query("Blank Screen").firstMatch.exists }
        } else {
            XCTAssertFalse(query("Presenter Page").firstMatch.exists)
            XCTAssertFalse(query("Full Page").firstMatch.exists)
            outside()
            XCTAssertFalse(query("Blank Screen").firstMatch.exists, "No presenter controls without an external display")
            try sameContent(before)
        }
    }

    // chrome.status: details must open from the actual title-adjacent status, including after rotation.
    func testBridgeStatusPillOpensDetailsAndTurnOffHasEffect() throws {
        try tap("App Menu"); try tap("Settings"); try tap("Bridge")
        try toggle("MCP bridge", to: true); try ui.dismissSheets(); try open()
        let before = try ui.state()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let status = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'MCP bridge'")).firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 10), "Enabled bridge must expose title-adjacent status")
            status.tap(); _ = try require("MCP Bridge"); _ = try reachable("Open Bridge Settings")
            outside(); try sameContent(before)
        }
        let status = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'MCP bridge'")).firstMatch
        status.tap(); try tap("Turn Off Bridge")
        try wait("Turn Off Bridge must remove its enabled status pill") { !status.exists }
        try sameContent(before)
    }
    func testPresenceDoesNotInventPeersAndTitleDetailsRetainLiveSession() throws {
        try open(); let before = try ui.state()
        try menu("title", "Collaborators"); try tap("Start Live Session")
        let join = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Join code:'")).firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 20), "Starting a live session must produce a join code")
        try ui.dismissSheets()
        let presence = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Collaborators' OR label BEGINSWITH 'Live session'" )).firstMatch
        // Presence beads represent other participants (DESIGN §14.14), not the lone host.
        XCTAssertFalse(presence.exists, "Hosting alone must not invent collaborator presence")
        try menu("title", "Collaborators")
        XCTAssertTrue(join.waitForExistence(timeout: 8), "Reopened details must retain the live session's join code")
        try sameContent(before)
    }
}
