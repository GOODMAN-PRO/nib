import XCTest
import UIKit

/// Real-app review captures. Reachability is the only assertion: no pixel, colour,
/// spacing or typography expectations. Each group starts with a disposable fixture
/// in every appearance/orientation, and a failed variant does not hide later ones.
@MainActor
final class CaptureUITests: XCTestCase {
    private var ui: NibUI!
    private var appearance = "light"
    private var orientation = "portrait"
    private let notebook = "Physics — Motion"

    override func setUpWithError() throws { continueAfterFailure = true }

    override func tearDownWithError() throws {
        ui?.app.terminate()
    }

    private func variants(scenario: NibUI.FixtureScenario = .standard, onboarding: Bool = false, agent: Bool = false,
                          _ body: () throws -> Void) {
        for style in ["light", "dark"] {
            for direction in ["portrait", "landscape"] {
                appearance = style
                orientation = direction
                ui = NibUI()
                do {
                    // NibUI.launchFixture owns its launch arguments, so compose the same
                    // explicit fixture launch here and use its probe/navigation helpers.
                    ui.app.launchArguments = ["-NibUITestFixture", "-NibUITestScenario", scenario.rawValue,
                                              "-NibUITestAppearance", style,
                                              "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    if onboarding { ui.app.launchArguments.append("-NibUITestOnboarding") }
                    if agent { ui.app.launchArguments.append("-NibUITestAgent") }
                    ui.app.launch()
                    if onboarding {
                        _ = try require("Your notes live in a folder you choose.")
                    } else {
                        _ = try ui.waitForState(timeout: 120) { $0.screen == "library" }
                    }
                    ui.app.activate()
                    // Rotate the foreground scene, then await its window geometry before
                    // delivering another orientation. The application's union frame can
                    // contain stale keyboard/system windows after a previous variant.
                    try rotate(to: direction)
                    try body()
                } catch {
                    let reason = "\(name) / \(style) / \(direction): \(error)"
                    attach(XCTAttachment(string: reason + "\n\n" + ui.app.debugDescription),
                           name: "unreachable-\(name)-\(style)-\(direction)")
                    attach(XCTAttachment(screenshot: XCUIScreen.main.screenshot()),
                           name: "diagnostic-\(name)-\(style)-\(direction)")
                    XCTFail(reason)
                }
                ui.app.terminate()
            }
        }
    }

    private func rotate(to direction: String) throws {
        let target: UIDeviceOrientation = direction == "portrait" ? .portrait : .landscapeLeft
        XCUIDevice.shared.orientation = target
        try wait("The scene must reach \(direction)", timeout: 30) {
            let window = self.ui.app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            return frame.width > 0 && frame.height > 0 &&
                (direction == "portrait" ? frame.height > frame.width : frame.width > frame.height)
        }
    }

    private func attach(_ attachment: XCTAttachment, name: String) {
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ message: String, timeout: TimeInterval = 12,
                      _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw NibUI.Failure.message(message)
        }
    }

    private func query(_ name: String) -> XCUIElementQuery {
        ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label ==[c] %@ OR label BEGINSWITH[c] %@", name, name, name + ","))
    }

    @discardableResult
    private func require(_ name: String) throws -> XCUIElement {
        let element = query(name).firstMatch
        guard element.waitForExistence(timeout: 12) else {
            throw NibUI.Failure.message("State cannot be reached: missing \(name)")
        }
        return element
    }

    private func tap(_ name: String, scroll: Bool = false) throws {
        let candidates = query(name)
        for attempt in 0..<(scroll ? 10 : 2) {
            let matches = candidates.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
            if let target = matches.first(where: { $0.elementType == .button }) ?? matches.first {
                target.tap()
                return
            }
            if attempt == 0 { _ = candidates.firstMatch.waitForExistence(timeout: 5) }
            if scroll {
                let panels = ui.app.scrollViews.allElementsBoundByIndex + ui.app.collectionViews.allElementsBoundByIndex
                let scroller = panels.first { $0.identifier != "nib.canvas" && $0.isHittable &&
                    $0.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).count > 0
                } ?? panels.last { $0.identifier != "nib.canvas" && $0.isHittable }
                scroller?.swipeUp()
            }
        }
        throw NibUI.Failure.message("State cannot be reached: no actionable \(name)")
    }

    private func capture(_ number: Int, _ screen: String, state: @escaping (QAState) -> Bool) throws {
        try rotate(to: orientation)
        _ = try ui.waitForState(timeout: 15, state)
        let stem = String(format: "%02d", number) + "-\(screen)-\(appearance)-\(orientation)"
        // XCTest waits for UI idleness before taking the full device screenshot.
        attach(XCTAttachment(screenshot: XCUIScreen.main.screenshot()), name: stem)
        attach(XCTAttachment(string: try XCTUnwrap(ui.probe.value as? String)), name: stem + "-qa-state")
    }

    private func libraryCapture(_ number: Int, _ screen: String) throws {
        try capture(number, screen) { $0.screen == "library" && $0.document == nil }
    }

    private func documentCapture(_ number: Int, _ screen: String) throws {
        try capture(number, screen) { $0.screen == "document" && $0.document != nil }
    }

    private func searchField() throws -> XCUIElement {
        let field = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label CONTAINS[c] 'Search' OR placeholderValue CONTAINS[c] 'Search')",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.searchField.rawValue)).firstMatch
        guard field.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Search field did not open") }
        return field
    }

    private func openNotebook() throws {
        try ui.openDocument(notebook)
        _ = try ui.waitForState { $0.screen == "document" && $0.pageCount == 4 && $0.itemCountOnPage > 0 }
        _ = try require("nib.canvas")
    }

    private func folder(_ title: String) throws {
        let row = ui.app.descendants(matching: .any).matching(identifier: "cmd.library.setView")
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        guard row.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Missing folder \(title)") }
        row.tap()
        _ = try ui.waitForState { $0.screen == "library" }
        _ = try require("Back to Documents")
    }

    func test01Library() {
        variants {
            _ = try self.require(self.notebook)
            try self.libraryCapture(10, "library-grid")
            try self.tap("Sort and View")
            _ = try self.require("List")
            try self.libraryCapture(13, "library-sort-view-menu")
            try self.tap("List")
            self.ui.app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.10)).tap()
            _ = try self.require(self.notebook)
            try self.libraryCapture(11, "library-list")
            try self.folder("Semester Notes")
            _ = try self.require("Lecture notes")
            try self.libraryCapture(12, "open-folder")
        }
    }

    func test02LibrarySearch() {
        variants {
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            field.tap(); field.typeText("Physics")
            _ = try self.require(self.notebook)
            try self.libraryCapture(15, "library-search")
            field.tap(); field.typeKey("a", modifierFlags: .command); field.typeText("No matching capture notebook")
            try self.wait("Search must show no matching document") {
                !self.query(self.notebook).firstMatch.exists
            }
            try self.libraryCapture(16, "library-search-empty")
        }
    }

    func test03Creation() {
        variants {
            try self.tap("New")
            _ = try self.require("Notebook")
            try self.libraryCapture(20, "new-menu")
            try self.tap("Notebook")
            _ = try self.require("New Notebook")
            try self.capture(21, "new-notebook") { $0.screen == "library" && !$0.openPanels.isEmpty }
        }
    }

    private func dock(_ edge: String) throws {
        if try ui.state().paletteDock?.edge == edge { return }
        let tools = try require("Tools")
        // Start in the end padding, away from the selected-tool bead's scrub gesture.
        let frame = tools.frame
        let start = tools.coordinate(withNormalizedOffset: frame.height > frame.width
            ? CGVector(dx: 0.5, dy: 0.01) : CGVector(dx: 0.01, dy: 0.5))
        let destination: CGVector
        switch edge {
        case "left": destination = CGVector(dx: 0.025, dy: 0.5)
        case "top": destination = CGVector(dx: 0.5, dy: 0.12)
        default: destination = CGVector(dx: 0.5, dy: 0.94)
        }
        start.press(forDuration: 0.15, thenDragTo: ui.app.coordinate(withNormalizedOffset: destination),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        _ = try ui.waitForState(timeout: 12) { $0.paletteDock?.edge == edge }
    }

    func test04CanvasPalette() {
        variants {
            try self.openNotebook()
            for (number, edge) in UIDevice.current.userInterfaceIdiom == .pad ? [(30, "left"), (31, "top"), (32, "bottom")] : [(31, "top"), (32, "bottom")] {
                try self.dock(edge)
                try self.capture(number, "canvas-palette-" + edge) {
                    $0.screen == "document" && $0.paletteDock?.edge == edge
                }
            }
            try self.ui.selectTool("pen")
            _ = try self.require("menu.toolSettings")
            try self.capture(33, "options-bar") { $0.screen == "document" && $0.tool == "pen" }
        }
    }

    private func toolOptions(_ id: String, title: String, number: Int) {
        variants {
            try self.openNotebook()
            try self.ui.selectTool(id)
            try self.tap("menu.toolSettings")
            guard self.query(title).firstMatch.waitForExistence(timeout: 12) else {
                throw NibUI.Failure.message("\(title) options did not open")
            }
            try self.capture(number, id == "shape" ? "shapes-options" : id + "-options") {
                $0.screen == "document" && $0.tool == id
            }
        }
    }

    func test05PenOptions() { toolOptions("pen", title: "Fountain Pen", number: 34) }
    func test06HighlighterOptions() { toolOptions("highlighter", title: "Straight line", number: 35) }
    func test07EraserOptions() { toolOptions("eraser", title: "Whole stroke", number: 36) }
    func test08LassoOptions() { toolOptions("lasso", title: "Lasso", number: 37) }
    func test09ShapesOptions() { toolOptions("shape", title: "Shapes", number: 38) }
    func test10TextOptions() { toolOptions("text", title: "Text", number: 39) }

    func test11LassoSelection() {
        variants {
            try self.openNotebook()
            try self.ui.selectTool("pen")
            let before = try self.ui.state().strokeCountOnPage
            try self.ui.drawStroke([CGPoint(x: 0.42, y: 0.62), CGPoint(x: 0.58, y: 0.68)])
            _ = try self.ui.waitForState { $0.strokeCountOnPage > before }
            try self.ui.selectTool("lasso")
            try self.ui.drawStroke([CGPoint(x: 0.36, y: 0.54), CGPoint(x: 0.65, y: 0.54),
                                    CGPoint(x: 0.65, y: 0.74), CGPoint(x: 0.36, y: 0.74),
                                    CGPoint(x: 0.36, y: 0.54)], duration: 0.7)
            _ = try self.ui.waitForState { $0.selectionCount > 0 }
            _ = try self.require("cmd.item.duplicate")
            try self.capture(45, "lasso-object-menu") { $0.screen == "document" && $0.selectionCount > 0 }
        }
    }

    func test12PageSidebarAndOutline() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("sidebar.toggle")
            try self.capture(50, "page-sidebar") { $0.openPanels.contains("sidebar.pages") }
            try self.tap("Outline")
            _ = try self.require("No outline yet")
            try self.capture(51, "outline") { $0.openPanels.contains("outline.tab") }
        }
    }

    func test13DocumentSearch() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            field.tap(); field.typeText("Motion")
            try self.wait("Document search must contain matches", timeout: 30) {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH 'Search result ' AND label CONTAINS ' of '")).firstMatch.exists
            }
            try self.documentCapture(55, "document-search-matches")
            field.tap(); field.typeKey("a", modifierFlags: .command); field.typeText("zzzznomatch")
            try self.wait("Document search must clear its matches") {
                !self.ui.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Search result '")).firstMatch.exists
            }
            try self.documentCapture(56, "document-search-empty")
        }
    }

    func test14Assistant() {
        variants {
            try self.openNotebook()
            try self.tap("Assistant")
            try self.capture(60, "ai-assistant") { $0.openPanels.contains("aichat.panel") }
        }
    }

    private func settings() throws {
        ui.app.typeKey(",", modifierFlags: .command)
        _ = try require("Settings")
        _ = try ui.waitForState { $0.screen == "library" }
    }

    func test15PluginManager() {
        variants {
            try self.settings()
            try self.openSettingsPage("Plugins")
            _ = try self.require("Install from…")
            try self.libraryCapture(140, "plugin-manager")
        }
    }

    func test16Settings() {
        variants {
            try self.settings()
            try self.libraryCapture(100, "settings-general")
            try self.openSettingsPage("Document Editing")
            _ = try self.require("Open documents in tabs")
            try self.libraryCapture(112, "settings-editing")
            try self.closeSettings()
            try self.settings()
            try self.openSettingsPage("Stylus & Palm Rejection")
            try self.libraryCapture(121, "settings-stylus")
        }
    }

    func test17Export() {
        variants {
            try self.openNotebook()
            try self.tap("Share and Export")
            // The share menu contains the production export action; open the format sheet.
            try self.ui.tapCommand("export.present")
            _ = try self.require("Save to Files")
            try self.documentCapture(70, "export-sheet")
        }
    }

    func test18Whiteboard() {
        variants {
            try self.ui.openDocument("Concept map")
            try self.capture(80, "whiteboard") { $0.screen == "document" && $0.itemCountOnPage == 3 }
        }
    }

    func test19TextDocument() {
        variants {
            try self.ui.openDocument("Lab report")
            try self.wait("The text document must show its fixture paragraph") {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "value CONTAINS %@ OR label CONTAINS %@", "Measure distance and time", "Measure distance and time"
                )).firstMatch.exists
            }
            try self.documentCapture(81, "text-document")
        }
    }

    func test20StudySession() {
        variants {
            try self.ui.openDocument("Motion flashcards")
            _ = try self.require("Practice")
            try self.documentCapture(82, "study-set-editor")
            try self.tap("Practice")
            _ = try self.require("Question side")
            try self.capture(83, "study-session-front") { $0.openPanels.contains("studysession.practice") }
            try self.tap("Flip Card")
            _ = try self.require("Answer side")
            try self.documentCapture(84, "study-session-back")
            for _ in 0..<3 { try self.tap("Good") }
            _ = try self.require("Review complete")
            try self.documentCapture(85, "study-session-summary")
        }
    }

    func test21Presentation() {
        variants {
            try self.openNotebook()
            try self.tap("Share and Export")
            if self.query("Presenter Page").firstMatch.exists {
                try self.tap("Presenter Page", scroll: true)
                _ = try self.require("Stop Presenting")
                try self.documentCapture(73, "presentation-mode")
            } else {
                XCTAssertFalse(self.query("Full Page").firstMatch.exists)
                XCTAssertFalse(self.query("Stop Presenting").firstMatch.exists)
                try self.documentCapture(73, "presentation-disconnected-share-menu")
            }
        }
    }

    func test22ThreeDocumentTabs() {
        variants {
            try self.settings()
            try self.openSettingsPage("Tabs")
            let toggle = self.ui.app.switches.matching(NSPredicate(format: "label == 'Show document tabs'")).firstMatch
            guard toggle.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Tab visibility setting missing") }
            if toggle.value as? String != "1" { toggle.tap() }
            try self.ui.dismissSheets()
            // Open through the library, preserving the app's normal tab preference.
            for title in ["Concept map", "Lab report", self.notebook] {
                if try self.ui.state().screen == "document" { try self.ui.tapCommand("window.showLibrary") }
                try self.ui.openDocument(title)
            }
            try self.wait("Three document tabs must be reachable") {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "value == 'Tab 3 of 3' OR value == '3 open documents'")).firstMatch.exists
            }
            try self.documentCapture(46, "three-document-tabs")
        }
    }

    func test23EmptyFolder() {
        variants {
            try self.tap("New"); try self.tap("New Folder")
            _ = try self.ui.waitForState { $0.openPanels.contains("organize.folder.new") }
            let field = self.ui.app.textFields["Folder name"]
            guard field.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Folder name field missing") }
            field.tap(); field.typeText("Review Inbox")
            try self.tap("Create Folder")
            _ = try self.ui.waitForState { !$0.openPanels.contains("organize.folder.new") }
            try self.folder("Review Inbox")
            try self.wait("The new folder must contain no documents") {
                self.ui.app.descendants(matching: .any).matching(identifier: "cmd.doc.open").count == 0
            }
            try self.libraryCapture(17, "empty-folder")
        }
    }

    func test24RenderError() {
        variants(scenario: .failedRender) {
            try self.openNotebook()
            _ = try self.require("Try Again")
            try self.capture(79, "page-render-error") {
                $0.screen == "document" && $0.fixtureScenario == "failedRender" && $0.renderFailureCount == 1
            }
        }
    }

    private func closeSettings() throws {
        try tap("sheet.dismiss")
        try wait("Settings must dismiss") { !self.query("sheet.dismiss").firstMatch.exists }
    }

    private func openSettingsPage(_ title: String) throws {
        let field = try searchField()
        field.tap(); field.typeKey("a", modifierFlags: .command); field.typeText(title)
        try tap(title, scroll: true)
        try wait("Settings must open \(title)") {
            self.ui.app.navigationBars[title].exists
        }
    }

    private func settingsPages(_ pages: [(Int, String, String)]) {
        variants {
            for (number, title, stem) in pages {
                try self.settings()
                try self.openSettingsPage(title)
                try self.libraryCapture(number, "settings-" + stem)
                try self.closeSettings()
            }
        }
    }

    func test25LibraryContextMenu() {
        variants {
            let document = self.ui.app.buttons.matching(identifier: "cmd.doc.open")
                .matching(NSPredicate(format: "label BEGINSWITH %@", self.notebook)).firstMatch
            _ = try self.require(self.notebook)
            document.press(forDuration: 1)
            _ = try self.require("Rename")
            try self.libraryCapture(14, "library-document-context-menu")
        }
    }

    func test26CreationCoversAndPaper() {
        variants {
            try self.tap("New"); try self.tap("Notebook")
            _ = try self.require("No cover")
            try self.libraryCapture(22, "new-notebook-covers")
            try self.tap("More Templates…", scroll: true)
            _ = try self.require("Templates")
            try self.libraryCapture(23, "paper-template-library")
        }
    }

    private func creation(_ title: String, heading: String, number: Int, stem: String) {
        variants {
            try self.tap("New"); try self.tap(title)
            _ = try self.require(heading)
            try self.libraryCapture(number, stem)
        }
    }
    func test27CreateWhiteboard() { creation("Whiteboard", heading: "New Whiteboard", number: 24, stem: "new-whiteboard") }
    func test28CreateTextDocument() { creation("Text Document", heading: "New Text Document", number: 25, stem: "new-text-document") }
    func test29CreateStudySet() { creation("Study Set", heading: "New Study Set", number: 26, stem: "new-study-set") }

    func test30StickyNote() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("sticky")
            try self.documentCapture(40, "sticky-note-tool")
            self.ui.coordinate(CGPoint(x: 0.5, y: 0.6)).tap()
            let editor = self.ui.app.textViews["Sticky note"]
            guard editor.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Sticky editor missing") }
            editor.tap(); editor.typeText("Review Newton’s second law")
            try self.documentCapture(41, "sticky-note-editor")
        }
    }

    func test31ImageInsertion() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("image")
            self.ui.coordinate(CGPoint(x: 0.5, y: 0.6)).tap()
            _ = try self.require("Files")
            try self.documentCapture(42, "image-source-picker")
        }
    }

    func test32Ruler() {
        variants {
            try self.openNotebook(); try self.ui.tapCommand("ruler.set")
            let ruler = try self.require("Ruler")
            try self.documentCapture(43, "ruler")
            ruler.doubleTap()
            _ = try self.require("Set Angle…")
            try self.documentCapture(44, "ruler-menu")
        }
    }

    func test33ZoomWindowAndScales() {
        variants {
            try self.openNotebook(); try self.ui.tapCommand("zoom.toggle")
            _ = try self.require("Zoom Window writing area")
            try self.documentCapture(47, "zoom-window")
            try self.tap("Close Zoom Window")
            try self.ui.selectTool("lasso")
            let initial = try self.ui.state().zoom
            try self.ui.pinchZoom(scale: 1.5)
            let zoomed = try self.ui.waitForState { $0.zoom > initial + 0.05 }
            try self.documentCapture(48, "canvas-zoomed-in")
            try self.ui.pinchZoom(scale: 0.4)
            _ = try self.ui.waitForState { $0.zoom < zoomed.zoom - 0.05 }
            try self.documentCapture(49, "canvas-zoomed-out")
        }
    }

    func test34PageMenu() {
        variants {
            try self.openNotebook(); try self.ui.tapCommand("sidebar.toggle")
            let page = self.ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1'")).firstMatch
            guard page.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("First thumbnail missing") }
            page.press(forDuration: 1)
            _ = try self.require("Duplicate")
            try self.documentCapture(52, "page-context-menu")
        }
    }

    func test35GoToPage() {
        variants {
            try self.openNotebook(); try self.tap("menu.more")
            try self.tap("Go to Page…", scroll: true)
            _ = try self.require("Page number or title")
            try self.documentCapture(53, "go-to-page")
        }
    }

    func test36ClearPageConfirmation() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("eraser")
            try self.tap("menu.toolSettings"); try self.tap("Clear Page", scroll: true)
            _ = try self.require("eraser.clearPage.confirmation")
            try self.documentCapture(54, "clear-page-confirmation")
        }
    }

    func test37AssistantAnswer() {
        variants(agent: true) {
            try self.openNotebook(); try self.tap("Assistant")
            let composer = try self.require("Question or instruction")
            composer.tap(); composer.typeText("Explain velocity and acceleration")
            try self.tap("Send to assistant")
            try self.wait("The real agent must display the fixture model answer", timeout: 60) {
                self.ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Velocity is displacement per unit time'")).firstMatch.exists
            }
            try self.capture(61, "ai-assistant-answer") { $0.openPanels.contains("aichat.panel") }
        }
    }

    func test38SettingsGeneralPages() {
        settingsPages([(101,"Profile","profile"), (102,"Appearance","appearance"),
            (103,"Password Protection","password"), (104,"Accessibility","accessibility"),
            (105,"Language","language"), (106,"Recording Settings","recording"),
            (107,"Keyboard and Pointer","keyboard"), (108,"Calendar","calendar"),
            (109,"Collaboration","collaboration"), (110,"Notifications","notifications")])
    }
    func test39SettingsEditingPages() {
        settingsPages([(113,"Tabs","tabs"), (114,"Toolbar","toolbar"), (115,"Undo and Redo","undo"),
            (116,"Alignment and snapping","snapping"), (117,"Elements and GIFs","elements"), (118,"Layers","layers")])
    }
    func test40SettingsWritingPages() {
        settingsPages([(120,"Apple Pencil","apple-pencil"), (122,"Smart Ink","smart-ink"),
            (123,"Handwriting Recognition","recognition"), (124,"Shape Recognition","shape-recognition"),
            (125,"Writing Aids","writing-aids")])
    }
    func test41SettingsAIPages() {
        settingsPages([(130,"AI","ai"), (131,"Use my Claude subscription","claude-subscription"),
            (132,"Use my ChatGPT subscription","chatgpt-subscription"), (133,"Add provider","other-provider"),
            (134,"Meeting AI","meeting-ai")])
    }
    func test42SettingsSyncPages() {
        settingsPages([(135,"Backup","backup"), (136,"WebDAV","webdav"),
            (137,"Collaboration Relay","relay"), (138,"Library Repair","repair"), (141,"Bridge","bridge")])
    }
    func test43SettingsAboutPages() {
        settingsPages([(142,"Troubleshooting","troubleshooting"), (143,"Developer","developer"),
            (144,"About Nib","about"), (145,"Privacy & Data","privacy"), (146,"Goodnotes Parity","parity")])
    }

    func test44FirstRun() {
        variants(onboarding: true) {
            try self.capture(1, "onboarding-library") { _ in true }
            // The isolated fixture already lives outside the app container; the regular
            // first-run flow therefore offers Continue after validating that location.
            if self.query("Continue").firstMatch.isHittable {
                try self.tap("Continue")
            } else {
                try self.tap("Keep Notes in Nib")
                try self.capture(2, "onboarding-storage-confirmation") { _ in true }
                try self.tap("Keep Notes in Nib")
            }
            _ = try self.require("Practice lines")
            try self.capture(3, "onboarding-pencil") { _ in true }
            try self.tap("Continue")
            _ = try self.require("Set Up AI")
            try self.capture(4, "onboarding-ai") { _ in true }
            try self.tap("Skip")
            _ = try self.require("Start Writing")
            try self.capture(5, "onboarding-ready") { _ in true }
            try self.tap("Open Library")
            _ = try self.ui.waitForState { $0.screen == "library" }
        }
    }

}
