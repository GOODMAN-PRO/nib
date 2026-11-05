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
        ui.logIdleSelectors(for: String(describing: type(of: self)))
        addUIInterruptionMonitor(withDescription: "Log Chrome interruptions without handling app alerts") { [weak self] element in
            self?.ui.logQA("Chrome interruption", self?.ui.elementFacts(element) ?? "test released")
            return false
        }
        let scenario: NibUI.FixtureScenario = name.contains("testTabsOverflowAndKeyboardOneThroughEightAndNineLast")
            ? .tabsOverflow : .standard
        try ui.launchFixture(scenario: scenario)
        ui.logQA("Typed probe estimate", "Chrome toolbar/More rows use buttons; baseline Any probes ~0.99s vs present typed ~0.16s. Potential 50-70s/layout test, unmeasured; modal typed queries may remain slow.")
    }

    override func tearDownWithError() throws {
        if let ui {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Chrome-\(name)-screen"
            shot.lifetime = .keepAlways
            add(shot)
            let tree = (testRun?.totalFailureCount ?? 0) > 0 ? ui.app.debugDescription : ""
            let state = XCTAttachment(string: "\(ui.probe.value ?? "no probe")\n\(tree)")
            state.name = "Chrome-\(name)-state-and-accessibility"
            state.lifetime = .keepAlways
            add(state)
            defer { ui.app.terminate() }
            try ui.handleAuthorizationAlerts()
        }
        if let imports { try FileManager.default.removeItem(at: imports) }
        if XCUIDevice.shared.orientation != .landscapeLeft { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    private func query(_ name: String) -> XCUIElementQuery {
        // Native fields can expose their visible name as a placeholder (for example Title).
        ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR placeholderValue == %@", name, name, name))
    }

    @discardableResult
    private func require(_ name: String, timeout: TimeInterval = 8) throws -> XCUIElement {
        // Preserve existence-only callers, but prefer native controls to their identically labelled captions.
        if let found = ui.findControl(name, actionable: false) { return found }
        let target = query(name).firstMatch
        guard target.exists || target.waitForExistence(timeout: timeout) else {
            throw NibUI.Failure.message("Missing chrome control: \(name)\n\(ui.app.debugDescription)")
        }
        return ui.findControl(name, actionable: false) ?? target
    }

    private func wait(_ message: String, timeout: TimeInterval = 12, _ predicate: @escaping () -> Bool) throws {
        if predicate() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw NibUI.Failure.message("\(message)\nState: \(ui.probe.value ?? "missing")\n\(ui.app.debugDescription)")
        }
    }

    /// Waits for an actionable control in its containing form with bidirectional, progress-bounded scrolling.
    private func reachable(_ name: String, type: XCUIElement.ElementType = .any) throws -> XCUIElement {
        let toolbarButton = ["Hide ", "Show ", "Apply ", "Reset "].contains { name.hasPrefix($0) }
            || name == "Save current layout"
        let kind: XCUIElement.ElementType = type == .any && toolbarButton ? .button : type
        let found = try ui.requireControl(name, type: kind, scroll: true, timeout: 8)
        guard found.isEnabled else { throw NibUI.Failure.message("Chrome control is not enabled: \(name)") }
        return found
    }

    private func tap(_ name: String, type: XCUIElement.ElementType = .any) throws {
        let toolMenu = ui.app.scrollViews["More tools"].firstMatch
        let selectsTool = name != "tool.more" && (name.hasPrefix("tool.") || name.hasPrefix("cmd.") || name == "Templates")
        let closesToolMenu = selectsTool && toolMenu.exists
        try reachable(name, type: type).tap()
        if closesToolMenu { try ui.waitForMenuClosed(toolMenu, named: "More tools after " + name) }
    }
    private func key(_ value: String, _ modifiers: XCUIElement.KeyModifierFlags = []) throws {
        if try ui.state().keyResponderIsText == true {
            let field = ui.app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            try ui.nativeKey(value, modifiers, in: field)
        } else {
            try ui.chord(value, modifiers) { } // The immediately following caller assertion verifies the action.
        }
    }
    private func escape() throws { try key(XCUIKeyboardKey.escape.rawValue) }
    private func outside() {
        guard let snapshot = try? ui.app.snapshot() else { XCTFail("Outside tap needs live geometry"); return }
        let canvas = ui.canvas.frame
        func obstructions(_ node: XCUIElementSnapshot) -> [CGRect] {
            let settings = node.elementType == .scrollView && node.identifier != "nib.canvas"
                && node.frame.height > 80 && node.frame.width < canvas.width * 0.85
            let own = settings || node.elementType == .popover ? [node.frame] : []
            return own + node.children.flatMap { obstructions($0) }
        }
        let frames = obstructions(snapshot)
        let candidates = [CGPoint(x: 0.83, y: 0.82), CGPoint(x: 0.5, y: 0.85), CGPoint(x: 0.5, y: 0.35),
                          CGPoint(x: 0.2, y: 0.85), CGPoint(x: 0.8, y: 0.35)]
        guard let point = candidates.first(where: { normalized in
            let point = ui.interfacePoint(normalized)
            return canvas.contains(point) && !frames.contains { $0.contains(point) }
        }) else { XCTFail("No canvas point outside presented popovers/settings"); return }
        ui.coordinate(point).tap()
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
    private func menu(_ id: String, _ action: String) throws {
        try openMenu(id)
        let menus = ui.app.scrollViews.containing(.button, identifier: action).allElementsBoundByIndex
        let surface = try XCTUnwrap(menus.first { $0.identifier != "nib.canvas" && $0.isHittable },
                                    "The droplet menu must contain its action: " + action)
        try tap(action)
        try ui.waitForMenuClosed(surface, named: id + " after " + action)
    }
    private func more(_ action: String) throws {
        try openMenu("more")
        try selectMoreRow(action)
    }
    private func selectMoreRow(_ action: String) throws {
        let menu = ui.app.scrollViews["More"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "More must expose its own row container")
        let row = try ui.requireControl(action, type: .button, scroll: true, timeout: 8, in: menu)
        ui.logQA("More scoped row", "action=\(action) row=\(row.frame) menu=\(menu.frame)")
        guard row.isEnabled else { throw NibUI.Failure.message("More row disabled: " + action) }
        row.tap()
        try ui.waitForMenuClosed(menu, named: "More after " + action)
    }
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
    private func diagnosedDraw(_ name: String) throws {
        defer { ui.recordDiagnostics(name + " completion", includeHierarchy: false) }
        try wait("Tool settings must be gone before diagnostic stroke") {
            !self.ui.app.scrollViews.matching(NSPredicate(format: "label == 'Fountain Pen'")).allElementsBoundByIndex.contains {
                self.ui.hasVisibleFrame($0) && $0.isHittable
            } && self.ui.app.popovers.count == 0
        }
        try draw(diagnostic: name)
    }
    private func draw(y: CGFloat = 0.65, diagnostic: String? = nil) throws {
        try ui.waitForMenuClosed(ui.app.scrollViews["More"].firstMatch, named: "More before drawing")
        try ui.waitForMenuClosed(ui.app.scrollViews["More tools"].firstMatch, named: "More tools before drawing")
        let before = try ui.state()
        if let diagnostic {
            try ui.diagnoseAction(diagnostic + " stroke", facts: { String(describing: self.ui.probe.value) }) {
                try ui.drawStroke([CGPoint(x: 0.4, y: y), CGPoint(x: 0.6, y: y + 0.03)])
            }
        } else { try ui.drawStroke([CGPoint(x: 0.4, y: y), CGPoint(x: 0.6, y: y + 0.03)]) }
        _ = try ui.waitForState(timeout: 12) { $0.strokeCountOnPage == before.strokeCountOnPage + 1 && $0.undoAvailable }
    }
    private func replace(_ name: String, _ text: String) throws {
        try ui.fillNativeForm([(name, text)])
    }

    private func toggle(_ name: String, to on: Bool) throws {
        let target = ui.app.switches.matching(NSPredicate(format: "label == %@", name)).firstMatch
        _ = try reachable(name)
        XCTAssertTrue(target.exists, "Expected switch \(name)")
        try ui.setSwitch(target, to: on)
        try wait("\(name) must become \(on)") { (target.value as? String == "1") == on }
    }
    private func settings(_ tool: String) throws {
        try ui.openToolSettings(tool)
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
        // ExportPresentation presents exportui.dialog directly, outside the registered panel state.
        _ = try reachable("Share & Export")
        _ = try reachable("PDF")
        XCTAssertTrue(try reachable("All").isSelected, "Export all must select every page")
        try ui.dismissSheets()
        try wait("Export options must close") { self.ui.findControl("Share & Export") == nil }
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
            ui.logQA("Stall boundary", "Rotated More tap orientation=\(orientation.rawValue)")
            do { try tap("menu.more") }
            catch {
                ui.recordDiagnostics("Rotated More failed", facts: ui.elementFacts(ui.app.buttons["menu.more"].firstMatch))
                throw error
            }
            try selectMoreRow("Go to Page…")
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
        try ui.chord("j", .command) { try self.panel("aichat.panel") }
        try escape(); try panel("aichat.panel", shown: false)
        try sameContent(before); try key("p"); try draw()
    }

    func testRegisteredSidebarPanelsAndCloseButton() throws {
        try open(); let before = try ui.state()
        try ui.tapCommand("sidebar.toggle")
        for (title, id) in [("Pages", "sidebar.pages"), ("Outline", "outline.tab"), ("Bookmarks", "outline.bookmarks"), ("History", "undo.history")] {
            try tap("Panel Options"); try tap(title); try panel(id)
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
        try menu("title", "Rename"); try escape(); try panel("chrome.rename", shown: false)
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
    private func assertToolSettings(_ expected: String?, obsolete label: String) throws {
        try wait("Tool settings must match the current presentation") {
            // The attribute, not a snapshot: snapshots truncate the probe's long JSON value.
            guard self.ui.probe.exists, let value = self.ui.probe.value as? String,
                  let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = try? JSONDecoder().decode(QAState.self, from: data) else { return false }
            if object.keys.contains("toolSettingsOpen") { return state.toolSettingsOpen == expected }
            return !self.ui.app.scrollViews.matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.contains { self.ui.hasVisibleFrame($0) && $0.isHittable }
        }
    }

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
        try assertToolSettings(nil, obsolete: "Fountain Pen")
        try tap("menu.toolSettings"); _ = try require("Straight line")
        try assertToolSettings("highlighter", obsolete: "Fountain Pen")
    }

    func testSettingsChevronOpensSettingsAndChangesPenType() throws {
        try open(); try ui.openToolSettings("pen")
        // F007 defines Pencil as a separate canvas tool, not a pen.style value.
        // Reopen the selected tool's settings after choosing it in the type grid.
        try tap("Pencil"); _ = try ui.waitForState { $0.tool == "pencil" }
        outside(); try draw()
        try ui.openToolSettings("pencil"); XCTAssertTrue(ui.app.buttons.matching(NSPredicate(format: "label == %@ AND NOT identifier BEGINSWITH %@", "Pencil", "tool.")).firstMatch.isSelected)
        outside(); try draw(y: 0.72)
    }

    func testMoreDrawShapePromotesToolAndProducesUndoableContent() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.drawShape")
        _ = try ui.waitForState { $0.tool == "drawShape" }
        // Draw Shape recognises this straight path as a vector shape (F030), not an additional ink stroke.
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.68)])
        _ = try ui.waitForState {
            $0.itemCountOnPage == before.itemCountOnPage + 1
                && $0.strokeCountOnPage == before.strokeCountOnPage && $0.undoAvailable
        }
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
        try escape()
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
        filesDiagnostics("image opened")
        defer { filesDiagnostics("image completion") }
        let provider = ui.app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        XCTAssertTrue(provider.exists || provider.waitForExistence(timeout: 8), "Files picker must expose its local provider")
        filesDiagnostics("before Cancel")
        try tap("Cancel"); try sameContent(before)
    }

    func testMoreElementsOpensRegisteredPanel() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.elements")
        _ = try ui.waitForState { $0.tool == "elements" }
        try ui.openToolSettings("elements"); try replace("Search elements", "Heart"); try ui.dismissNativeKeyboard(); try tap("Heart")
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
    /// Waits for the visible separator grip and verifies that only the palette moves.
    private func dragPalette(to point: CGPoint) throws { try ui.dragPalette(to: point) }
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
        outside(); try diagnosedDraw("Dock right")
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
        try ui.chord("z", .command) {
            _ = try self.ui.waitForState { $0.paletteDock?.edge == before.paletteDock?.edge }
        }
        XCTAssertEqual(try XCTUnwrap(ui.state().paletteDock?.along), try XCTUnwrap(before.paletteDock?.along), accuracy: 0.02)
        try ui.chord("z", [.command, .shift]) {
            _ = try self.ui.waitForState { $0.paletteDock?.edge == moved.paletteDock?.edge }
        }
        try ui.selectTool("pen"); try draw(); try dock("top")
        try ui.chord("z", .command) {
            _ = try self.ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        }
        XCTAssertEqual(try ui.state().paletteDock?.edge, "top", "Document ink must undo before the window's newer docking step")
        try ui.chord("z", [.command, .shift]) {
            _ = try self.ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        }
    }

    // toolbar.setVisible/setLayout/reset/saveLayout/applyLayout/deleteLayout
    func testHideShowToolsThroughMoreKeyboardAndPullDown() throws {
        try open(); let before = try ui.state()
        try more("Hide Tools")
        try wait("Hide Tools must remove tools and options") { !self.query("tool.pen").firstMatch.exists && !self.query("menu.toolSettings").firstMatch.exists }
        try key("w"); _ = try reachable("tool.pen")
        try key("w"); try wait("W must hide palette") { !self.query("tool.pen").firstMatch.exists }
        try tap("Show Tools"); _ = try reachable("tool.pen")
        try ui.twoFingerScroll(from: CGPoint(x: 0.12, y: 0.35), to: CGPoint(x: 0.12, y: 0.75))
        try more("Hide Tools"); try more("Show Tools"); _ = try reachable("menu.toolSettings")
        try sameContent(before); try ui.selectTool("pen"); try diagnosedDraw("Hide show tools")
    }
    func testSelectedPenTogglesOptionsAndSwatchPreservesManualFold() throws {
        try open(); try ui.selectTool("pen")
        _ = try reachable("menu.toolSettings")
        try tap("tool.pen")
        try wait("Reselecting Pen must fold its options") {
            !self.query("menu.toolSettings").firstMatch.exists
        }
        let swatch = ui.app.buttons.matching(identifier: "cmd.preset.select")
            .allElementsBoundByIndex.first { $0.isHittable && !$0.isSelected }
        try XCTUnwrap(swatch).tap()
        _ = try ui.waitForState { $0.tool == "pen" }
        XCTAssertFalse(query("menu.toolSettings").firstMatch.exists, "A quick colour must preserve the manual fold")
        try tap("tool.pen")
        try tap("menu.toolSettings")
        _ = try ui.waitForState { $0.toolSettingsOpen == "pen" }
        _ = try require("Fountain Pen")
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
        try settings("highlighter")
        outside()
        try wait("Highlighter settings must close before using the quick strip") {
            !self.ui.app.scrollViews.matching(NSPredicate(format: "label == %@", "Highlighter"))
                .allElementsBoundByIndex.contains { self.ui.hasVisibleFrame($0) && $0.isHittable }
        }
        try ui.diagnoseAction("Thickness 2 after settings", facts: { self.ui.elementFacts(self.query("Thickness 2").firstMatch, includeOverlaps: true) }) {
            try tap("Thickness 2")
        }
        outside()
        try ui.waitForMenuClosed(ui.app.scrollViews["More"].firstMatch, named: "More before page-scroll ink")
        let counted = try ui.state()
        XCTAssertEqual(counted.page, before.page, "This scroll must leave the counted fixture page selected")
        let page = ui.app.otherElements["Page 1 of 4"].firstMatch
        XCTAssertTrue(page.exists)
        let canvas = ui.canvas.frame
        let visible = page.frame.intersection(ui.app.windows.firstMatch.frame).intersection(canvas)
        guard !visible.isNull, visible.width > 80, visible.height > 80 else {
            throw NibUI.Failure.message("Counted page has no safe visible drawing region: \(visible)")
        }
        func normalized(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (visible.minX + visible.width * x - canvas.minX) / canvas.width,
                    y: (visible.minY + visible.height * y - canvas.minY) / canvas.height)
        }
        let points = [normalized(0.35, 0.65), normalized(0.65, 0.70)]
        ui.logQA("Page scroll ink geometry", "page=\(String(describing: counted.page)) pageFrame=\(page.frame) visible=\(visible) points=\(points)")
        ui.logStateStep("Page scroll wet ink before")
        defer { ui.logStateStep("Page scroll wet ink completion") }
        try ui.drawStroke(points)
        _ = try ui.waitForState(timeout: 12) {
            $0.strokeCountOnPage == counted.strokeCountOnPage + 1 && $0.undoAvailable
        }
    }
    private func customize() throws { try more("Customise Toolbar"); try panel("toolbar.customize") }
    private func doneCustomizing() throws { try tap("sheet.dismiss"); try panel("toolbar.customize", shown: false) }
    private func confirmLayoutSave() throws {
        let alert = ui.app.alerts.firstMatch
        let save = try ui.requireControl("cmd.toolbar.saveLayout", type: .button, in: alert)
        guard save.isEnabled else { throw NibUI.Failure.message("Named layout save must be enabled") }
        save.tap()
    }
    private func saveLayout(_ name: String) throws {
        try tap("Save current layout"); try replace("Layout name", name); try confirmLayoutSave()
        _ = try reachable("Apply " + name)
    }
    private func reorderHighlighterAbovePen(_ handle: XCUIElement) throws {
        let list = ui.app.collectionViews.containing(.button, identifier: "cmd.toolbar.setLayout").firstMatch
        var previousFrame: CGRect?
        try wait("Customise list must have stable geometry before reorder") {
            guard list.exists else { previousFrame = nil; return false }
            let frame = list.frame
            defer { previousFrame = frame }
            return frame.width > 0 && frame.height > 0 && previousFrame == frame
        }
        func rows(_ node: XCUIElementSnapshot) -> [String] {
            let own = node.elementType == .button && node.label.hasPrefix("Hide ")
                ? ["\(node.label) frame=\(node.frame)"] : []
            return own + node.children.flatMap { rows($0) }
        }
        func logOrder(_ stage: String) {
            guard let snapshot = try? list.snapshot() else {
                ui.logQA("Toolbar reorder " + stage, "list snapshot unavailable"); return
            }
            ui.logQA("Toolbar reorder " + stage, rows(snapshot).joined(separator: "\n"))
        }
        logOrder("before")
        defer { logOrder("after") }
        let destination = try reachable("Hide Fountain Pen").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: destination, withVelocity: .default, thenHoldForDuration: 0.4)
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
        try reorderHighlighterAbovePen(handle)
        try doneCustomizing(); try customize()
        XCTAssertFalse(query("Hide Lasso").firstMatch.exists)
        XCTAssertLessThan(try reachable("Hide Highlighter").frame.minY, try reachable("Hide Fountain Pen").frame.minY, "Reordered layout must persist")
    }
    func testSaveLayoutRejectsBlankAndNamedLayoutAppears() throws {
        try open(); try customize(); try tap("Save current layout")
        let save = ui.app.alerts.firstMatch.buttons["cmd.toolbar.saveLayout"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertFalse(save.isEnabled)
        try replace("Layout name", "   "); XCTAssertFalse(save.isEnabled)
        try replace("Layout name", "Chrome layout"); try confirmLayoutSave()
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
        let pen = ui.app.buttons.matching(NSPredicate(format: "label CONTAINS 'Reorder' AND label CONTAINS 'Fountain Pen'")).firstMatch
        XCTAssertTrue(pen.exists && pen.isHittable, "Pen reorder handle must define the insertion row")
        let row = ui.app.collectionViews.cells.containing(.button, identifier: pen.label).firstMatch
        XCTAssertTrue(row.exists, "Reorder destination must be the Pen row")
        try reorderHighlighterAbovePen(handle)
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
        let remove = row.images.matching(NSPredicate(format: "label == 'remove'")).firstMatch
        XCTAssertTrue(remove.exists && remove.isHittable, "Saved layout edit-mode minus must be available")
        remove.tap()
        ui.logQA("Saved layout after minus", row.debugDescription)
        try tap("Delete")
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
        try key("n", [.command, .option])
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
        func openFixtureTab(_ title: String) throws {
            let card = ui.app.buttons.matching(identifier: "cmd.doc.open").matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
            if !card.exists || !card.isHittable {
                ui.revealFormElement { card }
                if let failure = ui.formRevealFailure { throw NibUI.Failure.message(failure) }
            }
            try open(title)
        }
        try openFixtureTab(notebook); try showTabs(true)
        var documents = [try XCTUnwrap(ui.state().document)]
        for index in 2...9 {
            try ui.tapCommand("window.showLibrary")
            try openFixtureTab("Chrome tab \(index)")
            documents.append(try XCTUnwrap(ui.state().document))
        }
        try tap("Tabs"); try tap(notebook)
        _ = try ui.waitForState { $0.document == documents[0] }
        for index in 1...8 {
            try key(String(index), .command)
            _ = try ui.waitForState { $0.document == documents[index - 1] }
        }
        try key("9", .command); _ = try ui.waitForState { $0.document == documents[8] }
        try showTabs(false)
        XCTAssertFalse(query("Tabs").firstMatch.exists)
        try key("1", .command); _ = try ui.waitForState { $0.document == documents[0] }
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
        try key("1", .command)
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
        try ui.chord("w", .command) { _ = try self.ui.waitForState { $0.document == first.document } }
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        try ui.chord("w", [.command, .option]) {
            _ = try self.ui.waitForState { $0.screen == "library" && $0.document == nil }
        }
        try open(); XCTAssertEqual(try ui.state().document, first.document)
        try ui.tapCommand("window.showLibrary"); try open("Concept map")
        XCTAssertEqual(try ui.state().document, second.document)
    }
    func testTitleCloseOtherTabsKeepsChosenDocumentWithoutDeletingOthers() throws {
        let (first, second) = try secondTab()
        try menu("title", "Close Other Tabs")
        XCTAssertEqual(try ui.state().document, second.document)
        try key("w", .command)
        _ = try ui.waitForState { $0.screen == "library" && $0.document == nil }
        try open(); XCTAssertEqual(try ui.state().document, first.document)
    }
    func testNewWindowKeyboardOpensIndependentScene() throws {
        try open(); let before = try ui.state()
        try key("n", .command)
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
        try key("1", .command)
        _ = try ui.waitForState { $0.document == saved.document && $0.page == saved.page && $0.strokeCountOnPage == saved.strokeCountOnPage }
        try key("9", .command); _ = try ui.waitForState { $0.document == board.document }
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
        try key("r", [.command, .option])
        try wait("Option-Command-R must retract editing tools") { !self.query("tool.pen").firstMatch.exists }
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.69)])
        try sameContent(before)
        try key("r", [.command, .option]); try ui.selectTool("pen"); try draw()
    }

    // layer.panel/setActive/setVisible/rename
    private func layers(useShortcut: Bool = false) throws {
        try open(); try editing("Layers"); try toggle("Layers", to: true); try closeEditing()
        if useShortcut { try key("l", [.command, .option]) }
        else { try more("Layers") }
        try panel("layers")
    }
    func testLayersSettingMenuAndShortcutReflectFiveLayers() throws {
        try layers()
        for number in 1...5 { _ = try require("Layer \(number)") }
        XCTAssertTrue(try require("Layer 1").isSelected)
        try tap("cmd.panel.close"); try panel("layers", shown: false)
        try key("l", [.command, .option]); try panel("layers")
        try tap("cmd.panel.close")
        try editing("Layers"); try toggle("Layers", to: false); try closeEditing()
        try tap("menu.more"); XCTAssertFalse(query("Layers").firstMatch.exists)
    }
    func testActiveLayerRoutesNewInkAndKeyboardChangesSelectionScope() throws {
        try layers(); try tap("Layer 2")
        XCTAssertTrue(try require("Layer 2").isSelected)
        let baseline = try require("Layer 2").value as? String
        try tap("cmd.panel.close"); try ui.selectTool("pen"); try draw()
        try ui.chord("l", [.command, .option]) { try self.panel("layers") }
        XCTAssertNotEqual(try require("Layer 2").value as? String, baseline, "New stroke must belong to chosen layer")
        XCTAssertTrue((query("Layer 2").firstMatch.value as? String ?? "").contains("1 item"))
        try tap("cmd.panel.close"); try ui.chord("3", [.command, .option]) {
            try self.more("Layers")
            try self.wait("Layer 3 shortcut must select Layer 3") { self.query("Layer 3").firstMatch.isSelected }
            try self.tap("cmd.panel.close")
        }
        try draw(y: 0.73)
        try ui.chord("l", [.command, .option]) { try self.panel("layers") }; XCTAssertTrue(try require("Layer 3").isSelected)
        XCTAssertTrue((query("Layer 3").firstMatch.value as? String ?? "").contains("1 item"))
    }
    func testActiveLayerLimitsLassoSelectionToChosenLayer() throws {
        try layers(); try tap("Layer 2"); try tap("cmd.panel.close")
        try ui.selectTool("pen"); try draw(y: 0.62)
        try key("3", [.command, .option]); try draw(y: 0.72)
        try ui.selectTool("lasso")
        let outline = [CGPoint(x: 0.35, y: 0.58), CGPoint(x: 0.65, y: 0.58),
                       CGPoint(x: 0.65, y: 0.78), CGPoint(x: 0.35, y: 0.78), CGPoint(x: 0.35, y: 0.58)]
        try ui.drawStroke(outline)
        _ = try ui.waitForState { $0.selectionCount == 1 }
        try key("2", [.command, .option]); try ui.drawStroke(outline)
        _ = try ui.waitForState { $0.selectionCount == 1 }
    }
    func testLayerVisibilityChangesViewerWithoutDeletingContentAndPersists() throws {
        try layers(); try tap("Layer 2"); try tap("cmd.panel.close")
        try ui.selectTool("pen"); try draw(); let before = try ui.state()
        let visible = ui.canvas.screenshot().pngRepresentation
        try key("l", [.command, .option]); try tap("Hide Layer 2")
        XCTAssertTrue((try require("Layer 2").value as? String ?? "").contains("Hidden"))
        try tap("cmd.panel.close")
        XCTAssertNotEqual(ui.canvas.screenshot().pngRepresentation, visible, "Hidden-layer ink must disappear from viewer")
        try sameContent(before)
        try key("l", [.command, .option]); try tap("Show Layer 2")
        XCTAssertFalse((try require("Layer 2").value as? String ?? "").contains("Hidden"))
        try tap("cmd.panel.close"); try sameContent(before)
    }
    func testRenameLayerKeepsItsContentAndSupportsUndoRedo() throws {
        try layers(useShortcut: true); let before = try ui.state()
        let oldValue = try require("Layer 1").value as? String
        try reachable("Layer 1").press(forDuration: 0.8); try tap("Rename…")
        try replace("Layer name", "Chrome annotations"); try tap("Rename")
        XCTAssertEqual(try require("Chrome annotations").value as? String, oldValue)
        try sameContent(before, history: false)
        try key("z", .command); _ = try require("Layer 1")
        try key("z", [.command, .shift]); _ = try require("Chrome annotations")
    }

    // laser; laser.setMode
    func testLaserPaletteAndKeyboardPointingNeverEditOrAddUndo() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("tool.laser")
        _ = try ui.waitForState { $0.tool == "laser" }
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.65), CGPoint(x: 0.6, y: 0.7)])
        try sameContent(before)
        try key("p"); _ = try ui.waitForState { $0.tool == "pen" }
        try key("l"); _ = try ui.waitForState { $0.tool == "laser" }
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
    private func confirmRulerAlert(_ title: String) throws {
        try ui.prepareCoveredControl(title)
        let alert = ui.app.alerts.firstMatch
        let button = alert.buttons[title].firstMatch
        var previousFrame: CGRect?
        try wait("Ruler confirmation must be enabled, hittable and stable") {
            guard button.exists, button.isEnabled, button.isHittable else { previousFrame = nil; return false }
            let frame = button.frame
            defer { previousFrame = frame }
            return previousFrame == frame
        }
        ui.logQA("Ruler alert confirm", "action=\(title) " + ui.elementFacts(button))
        button.tap()
        ui.logQA("Ruler alert after tap", "action=\(title) alerts=\(ui.app.alerts.count)")
        try wait("Ruler alert must close before another action") { !alert.exists }
    }

    func testRulerPaletteAndKeyboardToggleWithoutDocumentItems() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.ruler.set")
        XCTAssertTrue(ruler.waitForExistence(timeout: 8))
        try key("r"); try wait("R must hide ruler and angle HUD") { !self.ruler.exists }
        try key("r"); XCTAssertTrue(ruler.waitForExistence(timeout: 8))
        try rulerMenu("Hide Ruler"); try wait("Hide Ruler must remove overlay") { !self.ruler.exists }
        try sameContent(before)
    }
    func testRulerMoveAndAngleControlsSnapToZeroFortyFiveNinety() throws {
        try showRuler(); let before = try ui.state(), old = ruler.frame
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        XCTAssertGreaterThan(ruler.frame.midY, old.midY + 30)
        for angle in [0, 45, 90] {
            try rulerMenu("Set Angle…"); try replace("Angle in degrees", String(angle)); try confirmRulerAlert("Set Angle")
            try wait("Ruler angle must be \(angle) degrees") { (self.ruler.value as? String ?? "").hasPrefix("\(angle) degrees") }
        }
        try sameContent(before)
    }

    func testRulerTwoFingerRotationSnapsToFortyFiveWithoutEditing() throws {
        try showRuler(); let before = try ui.state()
        try rulerMenu("Set Angle…"); try replace("Angle in degrees", "0"); try confirmRulerAlert("Set Angle")
        defer {
            ui.recordDiagnostics("Ruler rotation completion", facts: ui.elementFacts(ruler), includeHierarchy: false)
            ui.logStateStep("Ruler rotation ink invariants; baseline strokes=\(before.strokeCountOnPage)")
        }
        try wait("Set Angle panel must be gone before rotation") { !self.ui.app.textFields["Angle in degrees"].exists }
        ui.recordDiagnostics("Ruler rotation before", facts: ui.elementFacts(ruler), includeHierarchy: false)
        let frame = ruler.frame, radius = min(frame.width * 0.3, 90)
        let paths = [CGFloat(-1), CGFloat(1)].map { direction in
            (0...12).map { step -> CGPoint in
                let angle = CGFloat(step) / 12 * .pi / 4
                return CGPoint(x: frame.midX + direction * radius * cos(angle),
                               y: frame.midY - direction * radius * sin(angle))
            }
        }
        try ui.synthesizeInterfacePaths(paths, duration: 0.8)
        ui.recordDiagnostics("Ruler rotation after", facts: ui.elementFacts(ruler), includeHierarchy: false)
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
        try ui.fillNativeForm([("Horizontal position", "4"), ("Vertical position", "5")])
        try confirmRulerAlert("Move Ruler")
        try rulerMenu("Set Position…")
        XCTAssertEqual(try require("Horizontal position").value as? String, "4")
        XCTAssertEqual(try require("Vertical position").value as? String, "5")
        try tap("Cancel"); try sameContent(before)
    }
    func testRulerEdgeConstrainsRealInkAndStrokeIsUndoable() throws {
        try showRuler(); try rulerMenu("Set Angle…"); try replace("Angle in degrees", "0"); try confirmRulerAlert("Set Angle")
        try ui.selectTool("pen"); let before = try ui.state(), frame = ruler.frame, canvas = ui.canvas.frame
        // Finger just outside the body, within the 20-page-point projection band.
        let y = (frame.maxY + 5 - canvas.minY) / canvas.height
        let x = max(0.4, (frame.minX + 50 - canvas.minX) / canvas.width)
        try ui.drawStroke([CGPoint(x: x, y: y), CGPoint(x: x + 0.16, y: y + 0.006)])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try key("r"); try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    // timer.panel/start/control/modes/history; stopwatch.start/lap
    private func timeKeeper() throws {
        try ui.waitForMenuClosed(ui.app.scrollViews["More"].firstMatch, named: "More before Time Keeper")
        if try !ui.state().openPanels.contains("timekeeper") {
            // K opens the idle panel. During a session K toggles the bar; its clock opens details.
            if clockValue.exists { clockValue.tap() }
            else { try key("k") }
        }
        try panel("timekeeper")
    }
    private var clockValue: XCUIElement {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ' remaining' OR label ENDSWITH ' elapsed'")).firstMatch
    }
    private func timer(_ duration: String = "1:30", name: String = "Chrome countdown") throws {
        try timeKeeper()
        let form = ui.app.scrollViews["Time Keeper"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 8))
        try ui.fillNativeForm([("Duration", duration), ("Timer name", name)], in: form)
        // End field editing before a global canvas shortcut can be interpreted as text.
        try key(XCUIKeyboardKey.escape.rawValue)
        let start = try ui.requireControl("Start Timer", type: .button, scroll: true, in: form)
        guard start.isEnabled else { throw NibUI.Failure.message("Start Timer must be enabled for the entered duration") }
        start.tap()
        try ui.handleAuthorizationAlerts(waitForCountdown: { self.clockValue.exists })
        try wait("Countdown must expose a running clock") { self.clockValue.exists }
        try ui.handleAuthorizationAlerts()
    }
    func testTimeKeeperPaletteAndKeyboardToggleRetainActiveCountdown() throws {
        try open(); let before = try ui.state()
        try tap("tool.more"); try tap("cmd.timer.control"); try panel("timekeeper")
        try key("k"); try panel("timekeeper", shown: false)
        try timer()
        let first = clockValue.label
        try tap("Hide Time Keeper")
        try key("k")
        try wait("Restored timer must still advance") { self.clockValue.exists && self.clockValue.label != first }
        try sameContent(before)
    }
    func testTimerPresetStartsCountdownAndCustomNameAdvances() throws {
        try open(); try timeKeeper(); try tap("5 min")
        let chip = ui.app.buttons["5 min"].firstMatch
        try wait("5 min chip must report Selected", timeout: 2) {
            guard let snapshot = try? chip.snapshot() else { return false }
            self.ui.logQA("Timer preset selection", "type=\(snapshot.elementType) label=\(snapshot.label) selected=\(snapshot.isSelected) value=\(String(describing: snapshot.value))")
            return snapshot.isSelected
        }
        XCTAssertTrue(chip.isSelected)
        try replace("Timer name", "Preset countdown"); try tap("Start Timer")
        try ui.handleAuthorizationAlerts(waitForCountdown: { self.clockValue.exists })
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
        try key("k", [.command, .shift]); _ = try require("Pause")
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
        let start = try ui.requireControl("Start Timer", type: .button, scroll: true)
        XCTAssertFalse(start.isEnabled, "An empty Duration must not start a timer")
        try ui.waitForNativeText(in: ui.app.textFields["Duration"].firstMatch, equals: "")
    }
    func testStopwatchAdvancesPauseRetainsElapsedAndLapsDoNotReset() throws {
        try open(); try timeKeeper(); let modes = ui.app.buttons.matching(NSPredicate(format: "label == 'Timer or stopwatch'"))
        XCTAssertEqual(modes.count, 2, "Native segmented picker must expose Timer and Stopwatch")
        let stopwatch = modes.element(boundBy: 1)
        XCTAssertTrue(stopwatch.isHittable)
        stopwatch.tap(); try tap("Start Stopwatch")
        try wait("Stopwatch must expose elapsed clock") { self.clockValue.exists }
        let start = clockValue.label
        try wait("Stopwatch elapsed time must advance") { self.clockValue.label != start }
        try tap("Record Lap"); try key("k", [.command, .option])
        // Keep the deliberate More re-open coverage; closure is independent of panel state.
        try more("Time Keeper"); try panel("timekeeper")
        let laps = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Lap ' AND label CONTAINS 'total'"))
        XCTAssertEqual(laps.count, 2, "Tap and Option-Command-K each record one lap")
        try tap("Pause"); let paused = clockValue.label
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clockValue.label != paused }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 2), .timedOut)
        try tap("Resume"); try wait("Stopwatch must resume from elapsed time") { self.clockValue.label != paused }
        XCTAssertEqual(laps.count, 2)
        try tap("Stop and Save")
        try wait("Stopwatch mode must remain available after saving") { modes.count == 2 && modes.element(boundBy: 1).isHittable }
    }
    func testTimerSaveAndDeleteModesPersistAcrossPanelReopen() throws {
        try open(); try timeKeeper(); try replace("Duration", "2:30")
        try replace("New mode name", "Chrome study"); try tap("Save Mode")
        _ = try reachable("Delete Chrome study")
        try tap("cmd.panel.close"); try timeKeeper()
        try tap("Chrome study")
        XCTAssertEqual(try require("Duration").value as? String, "02:30")
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
    private func filesDiagnostics(_ stage: String) {
        let includeTrees = ["opened", "before folder", "image opened"].contains(stage)
        ui.recordDiagnostics("Files picker " + stage,
            facts: ui.elementFacts(ui.app.buttons["Cancel"].firstMatch, includeOverlaps: true), includeHierarchy: includeTrees)
        if includeTrees {
            ui.logQA("Files DocumentsApp " + stage, XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp").debugDescription)
            ui.logQA("Files SpringBoard " + stage, XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        }
    }

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
        ui.recordDiagnostics("Files picker before import", includeHierarchy: false)
        try tap("New"); try tap("Import Files")
        filesDiagnostics("opened")
        defer { filesDiagnostics("PDF completion") }
        let local = ui.app.cells["DOC.sidebar.item.On My iPad"]
        if local.waitForExistence(timeout: 5), local.isHittable { local.tap() }
        let nib = ui.app.cells["Nib, Container"]
        if nib.waitForExistence(timeout: 3), nib.isHittable { nib.tap() }
        filesDiagnostics("before folder")
        let directory = ui.app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folderName)).firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 10), "Files must show external PDF input folder")
        directory.tap()
        let pdf = ui.app.cells.matching(NSPredicate(format: "label CONTAINS 'Chrome selection'")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 10)); pdf.tap()
        filesDiagnostics("before Open")
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
        let field = try reachable("Title"); field.tap(); try key("a", .command); try key("v", .command)
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
        do {
            try wait("Turn Off Bridge must remove its enabled status pill") { !status.exists }
        } catch {
            let popover = ui.app.scrollViews["MCP Bridge"].firstMatch
            func evidence(_ stage: String) {
                let facts = "pill: " + ui.elementFacts(status) + "\npopover: " + ui.elementFacts(popover)
                ui.logQA("Bridge after Turn Off " + stage, facts)
                ui.recordDiagnostics("Bridge after Turn Off " + stage, facts: facts, includeHierarchy: false)
            }
            evidence("first")
            // Diagnostic separation only, after failure; never a success-path sleep or retry.
            let firstRead = Date()
            let separated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Date().timeIntervalSince(firstRead) >= 1
            }, object: nil)
            _ = XCTWaiter.wait(for: [separated], timeout: 2)
            evidence("second")
            throw error
        }
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
