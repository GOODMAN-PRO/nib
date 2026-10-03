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

    override func setUpWithError() throws {
        continueAfterFailure = true
        // Four real launches and rotations per test, plus several review captures.
        // Match CI's existing maximum; individual state waits remain bounded.
        executionTimeAllowance = 300
        addUIInterruptionMonitor(withDescription: "First-use keyboard tutorial") { panel in
            guard panel.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Speed up your typing'"))
                .firstMatch.exists, panel.buttons["Continue"].isHittable else { return false }
            panel.buttons["Continue"].tap()
            return true
        }
    }

    override func tearDownWithError() throws {
        ui?.app.terminate()
    }

    private func variants(scenario: NibUI.FixtureScenario = .standard, onboarding: Bool = false, agent: Bool = false,
                          styles: [String] = ["light", "dark"],
                          _ body: () throws -> Void) {
        for style in styles {
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
                        try wait("First-run fixture must finish preparing", timeout: 120) {
                            self.query("Your notes live in a folder you choose.").firstMatch.exists
                        }
                    } else {
                        _ = try ui.waitForState(timeout: 120) { $0.screen == "library" }
                    }
                    ui.app.activate()
                    // Rotate the foreground scene, then await its window geometry before
                    // delivering another orientation. The application's union frame can
                    // contain stale keyboard/system windows after a previous variant.
                    try rotate(to: direction)
                    if !onboarding { try showDocuments() }
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
        let reached: () -> Bool = {
            let window = self.ui.app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            return frame.width > 0 && frame.height > 0 &&
                (direction == "portrait" ? frame.height > frame.width : frame.width > frame.height)
        }
        if XCUIDevice.shared.orientation == target && reached() { return }
        XCUIDevice.shared.orientation = target
        try wait("The scene must reach \(direction)", timeout: 30, reached)
    }

    private func attach(_ attachment: XCTAttachment, name: String) {
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ message: String, timeout: TimeInterval = 12,
                      _ predicate: @escaping () -> Bool) throws {
        if predicate() { return }
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
        guard element.exists || element.waitForExistence(timeout: 12) else {
            throw NibUI.Failure.message("State cannot be reached: missing \(name)")
        }
        return element
    }

    private func tap(_ name: String, scroll: Bool = false) throws {
        try reachable(name, scroll: scroll).tap()
    }

    private func reachable(_ name: String, scroll: Bool = false) throws -> XCUIElement {
        let candidates = query(name)
        for attempt in 0..<(scroll ? 10 : 2) {
            let matches = candidates.allElementsBoundByIndex.filter { self.hasVisibleFrame($0) && $0.isHittable && $0.isEnabled }
            if let target = matches.first(where: { $0.elementType == .button }) ?? matches.first {
                return target
            }
            if attempt == 0 {
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    candidates.allElementsBoundByIndex.contains { self.hasVisibleFrame($0) && $0.isHittable && $0.isEnabled }
                }, object: nil)
                _ = XCTWaiter.wait(for: [ready], timeout: 5)
            }
            if scroll {
                let panels = ui.app.scrollViews.allElementsBoundByIndex + ui.app.collectionViews.allElementsBoundByIndex
                let scroller = panels.first { $0.identifier != "nib.canvas" && self.hasVisibleFrame($0) && $0.isHittable &&
                    $0.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).count > 0
                } ?? panels.filter { $0.identifier != "nib.canvas" && self.hasVisibleFrame($0) && $0.isHittable }
                    .max { $0.frame.intersection(self.ui.app.windows.firstMatch.frame).height <
                           $1.frame.intersection(self.ui.app.windows.firstMatch.frame).height }
                scroller?.swipeUp()
            }
        }
        throw NibUI.Failure.message("State cannot be reached: no actionable \(name)")
    }

    private func hasVisibleFrame(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        return !frame.isEmpty && !frame.isNull && !frame.isInfinite &&
            frame.origin.x.isFinite && frame.origin.y.isFinite
    }

    private func capture(_ number: Int, _ screen: String, state: @escaping (QAState) -> Bool) throws {
        try rotate(to: orientation)
        if try !state(ui.state()) { _ = try ui.waitForState(timeout: 15, state) }
        let stem = String(format: "%03d", number) + "-\(screen)-\(appearance)-\(orientation)"
        // Validate the captured device too: a floating window's aspect alone cannot
        // prove the screen rotated. Never attach an image under the wrong variant.
        let screenshot = XCUIScreen.main.screenshot()
        let size = screenshot.image.size
        guard orientation == "portrait" ? size.height > size.width : size.width > size.height else {
            throw NibUI.Failure.message("Screenshot orientation disagrees with \(orientation): \(size)")
        }
        attach(XCTAttachment(screenshot: screenshot), name: stem)
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
            format: "(elementType == %d OR elementType == %d) AND (label CONTAINS[c] 'Search' OR placeholderValue CONTAINS[c] 'Search' OR label CONTAINS[c] 'Find' OR placeholderValue CONTAINS[c] 'Find')",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.searchField.rawValue)).firstMatch
        guard field.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Search field did not open") }
        return field
    }

    private func focus(_ field: XCUIElement) {
        field.tap()
        for source in [ui.app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            if source.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Speed up your typing'"))
                .firstMatch.exists, source.buttons["Continue"].isHittable {
                source.buttons["Continue"].tap()
                field.tap()
            }
        }
    }

    private func showDocuments() throws {
        let row = ui.app.buttons.matching(identifier: "cmd.library.setView")
            .matching(NSPredicate(format: "label == 'Documents' OR label BEGINSWITH 'Documents,'")).firstMatch
        try wait("Library navigation must finish appearing", timeout: 30) {
            row.isHittable || self.query("New").allElementsBoundByIndex.contains { $0.isHittable }
        }
        if row.exists && row.isHittable { row.tap() }
        _ = try reachable("New")
    }

    private func openDocument(_ title: String) throws {
        try ui.openDocument(title)
    }

    private func openNotebook() throws {
        try openDocument(notebook)
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
            if !self.query("App Menu").firstMatch.isHittable { try self.tap("Show Library") }
            _ = try self.require("App Menu")
            try self.libraryCapture(6, "library-sidebar")
            try self.showDocuments()
            _ = try self.require(self.notebook)
            try self.libraryCapture(7, "library-grid")
            try self.tap("Sort and View")
            _ = try self.require("List")
            try self.libraryCapture(10, "library-sort-view-menu")
            try self.tap("List")
            self.ui.app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.10)).tap()
            _ = try self.require(self.notebook)
            try self.libraryCapture(8, "library-list")
            try self.folder("Semester Notes")
            _ = try self.require("Lecture notes")
            try self.libraryCapture(9, "open-folder")
        }
    }

    func test02LibrarySearch() {
        variants {
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            self.focus(field); field.typeText("Physics")
            _ = try self.require(self.notebook)
            try self.libraryCapture(12, "library-search")
            self.focus(field); field.typeKey("a", modifierFlags: .command); field.typeText("No matching capture notebook")
            try self.wait("Search must show no matching document") {
                self.ui.app.staticTexts.matching(NSPredicate(
                    format: "label BEGINSWITH %@", "No results for “No matching capture notebook”")).firstMatch.exists
            }
            try self.libraryCapture(13, "library-search-empty")
        }
    }

    func test03Creation() {
        variants {
            try self.tap("New")
            _ = try self.require("Notebook")
            try self.libraryCapture(23, "new-menu")
            try self.tap("Notebook")
            _ = try self.require("New Notebook")
            try self.capture(24, "new-notebook") { $0.screen == "library" && !$0.openPanels.isEmpty }
        }
    }

    private func dock(_ edge: String) throws {
        if try ui.state().paletteDock?.edge == edge { return }
        let tools = try require("Tools")
        // Use the bare rim. Never drag a stale/offscreen accessibility union into
        // iPadOS window controls: that resizes the scene for every later test.
        let frame = tools.frame
        guard ui.app.windows.firstMatch.frame.contains(frame) else {
            throw NibUI.Failure.message("Palette left its app window after docking: \(frame)")
        }
        let start = tools.coordinate(withNormalizedOffset: frame.height > frame.width
            ? CGVector(dx: 0.1, dy: 0.5) : CGVector(dx: 0.5, dy: 0.1))
        let destination: CGVector
        switch edge {
        case "left": destination = CGVector(dx: 0.025, dy: 0.5)
        case "top": destination = CGVector(dx: 0.5, dy: 0.12)
        default: destination = CGVector(dx: 0.5, dy: 0.94)
        }
        start.press(forDuration: 0.15, thenDragTo: ui.app.coordinate(withNormalizedOffset: destination),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        _ = try ui.waitForState(timeout: 30) { $0.paletteDock?.edge == edge }
    }

    func test04CanvasPalette() {
        canvasPalette(styles: ["light"])
    }

    func test04CanvasPaletteDark() {
        canvasPalette(styles: ["dark"])
    }

    private func canvasPalette(styles: [String]) {
        variants(styles: styles) {
            try self.openNotebook()
            for (number, edge) in UIDevice.current.userInterfaceIdiom == .pad ? [(30, "left"), (31, "top"), (32, "bottom")] : [(31, "top"), (32, "bottom")] {
                try self.dock(edge)
                try self.wait("Palette controls must be visible at the \(edge) dock") {
                    let frame = self.query("Tools").firstMatch.frame
                    let vertical = edge == "left" || edge == "right"
                    return self.ui.app.windows.firstMatch.frame.contains(frame)
                        && (vertical ? frame.height > frame.width : frame.width > frame.height)
                        && self.query("tool.pen").firstMatch.isHittable
                }
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
            _ = try self.require(title)
            try self.capture(number, id == "shape" ? "shapes-options" : id + "-options") {
                $0.screen == "document" && $0.tool == id
            }
        }
    }

    func test05PenOptions() { toolOptions("pen", title: "Fountain Pen", number: 35) }
    func test06HighlighterOptions() { toolOptions("highlighter", title: "Straight line", number: 37) }
    func test07EraserOptions() { toolOptions("eraser", title: "Whole stroke", number: 38) }
    func test08LassoOptions() { toolOptions("lasso", title: "Lasso type", number: 39) }
    func test09ShapesOptions() { toolOptions("shape", title: "Rectangle", number: 40) }
    func test10TextOptions() { toolOptions("text", title: "Save Style…", number: 41) }

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
            try self.capture(50, "lasso-object-menu") { $0.screen == "document" && $0.selectionCount > 0 }
        }
    }

    func test12PageSidebarAndOutline() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("sidebar.toggle")
            try self.capture(55, "page-sidebar") { $0.openPanels.contains("sidebar.pages") }
            try self.tap("Outline")
            _ = try self.require("No outline yet")
            try self.capture(56, "outline") { $0.openPanels.contains("outline.tab") }
            try self.tap("Bookmarks")
            _ = try self.require("No bookmarks")
            try self.documentCapture(57, "bookmarks-empty")
        }
    }

    func test13DocumentSearch() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            self.focus(field); field.typeText("Motion")
            try self.wait("Document search must contain matches", timeout: 30) {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH 'Search result ' AND label CONTAINS ' of '")).firstMatch.exists
            }
            try self.documentCapture(61, "document-search-matches")
            self.focus(field); field.typeKey("a", modifierFlags: .command); field.typeText("zzzznomatch")
            try self.wait("Document search must clear its matches") {
                self.ui.app.staticTexts.matching(NSPredicate(
                    format: "label BEGINSWITH %@", "No results for “zzzznomatch”")).firstMatch.exists
                    && !self.ui.app.descendants(matching: .any).matching(NSPredicate(
                        format: "label BEGINSWITH 'Search result ' AND label CONTAINS ' of '")).firstMatch.exists
            }
            try self.documentCapture(62, "document-search-empty")
        }
    }

    func test14Assistant() {
        variants {
            try self.openNotebook()
            try self.tap("Assistant")
            try self.capture(65, "ai-assistant") { $0.openPanels.contains("aichat.panel") }
        }
    }

    private func shareMenu() throws {
        if !query("menu.share").allElementsBoundByIndex.contains(where: { $0.isHittable }) {
            try tap("menu.more")
        }
        try tap("Share and Export", scroll: true)
        _ = try require("cmd.export.present")
    }

    private func settings() throws {
        if !query("App Menu").firstMatch.isHittable { try tap("Show Library") }
        try tap("App Menu")
        try ui.tapCommand("settings.open")
        _ = try require("sheet.dismiss")
        _ = try ui.waitForState { $0.screen == "library" }
    }

    func test15PluginManager() {
        variants {
            try self.settings()
            try self.openSettingsPage("Plugins")
            _ = try self.require("Install from…")
            try self.libraryCapture(123, "plugin-manager")
        }
    }

    func test16Settings() {
        variants {
            try self.settings()
            try self.libraryCapture(90, "settings-general")
            try self.openSettingsPage("Document Editing")
            _ = try self.require("Open documents in tabs")
            try self.libraryCapture(101, "settings-editing")
            try self.closeSettings()
            try self.settings()
            try self.openSettingsPage("Stylus & Palm Rejection")
            try self.libraryCapture(109, "settings-stylus")
        }
    }

    func test17Export() {
        variants {
            try self.openNotebook()
            try self.shareMenu()
            // The share menu contains the production export action; open the format sheet.
            try self.ui.tapCommand("export.present")
            _ = try self.require("Save to Files")
            try self.documentCapture(67, "export-sheet")
            if !self.query("Images").allElementsBoundByIndex.contains(where: { self.hasVisibleFrame($0) && $0.isHittable }) {
                try self.tap("PDF")
            }
            try self.tap("Images")
            _ = try self.require("PNG")
            try self.documentCapture(68, "export-images")
            try self.tap("Print…", scroll: true)
            _ = try self.require("Print")
            try self.documentCapture(69, "print-options")
        }
    }

    func test18Whiteboard() {
        variants {
            try self.openDocument("Concept map")
            try self.capture(79, "whiteboard") { $0.screen == "document" && $0.itemCountOnPage == 3 }
        }
    }

    func test19TextDocument() {
        variants {
            try self.openDocument("Lab report")
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
            try self.openDocument("Motion flashcards")
            _ = try self.require("Practice")
            try self.documentCapture(84, "study-set-editor")
            try self.tap("Practice")
            _ = try self.require("Question side")
            try self.capture(85, "study-session-front") { $0.openPanels.contains("studysession.practice") }
            try self.tap("Question side")
            _ = try self.require("Answer side")
            try self.documentCapture(86, "study-session-back")
            for card in 0..<3 {
                if card > 0 {
                    try self.tap("Question side")
                    _ = try self.require("Answer side")
                }
                try self.tap("Good")
            }
            _ = try self.require("Review complete")
            try self.documentCapture(87, "study-session-summary")
        }
    }

    func test21Presentation() {
        variants {
            try self.openNotebook()
            try self.shareMenu()
            if self.query("Presenter Page").firstMatch.exists {
                try self.tap("Presenter Page", scroll: true)
                _ = try self.require("Stop Presenting")
                try self.documentCapture(70, "presentation-mode")
            } else {
                XCTAssertFalse(self.query("Full Page").firstMatch.exists)
                XCTAssertFalse(self.query("Stop Presenting").firstMatch.exists)
                try self.documentCapture(70, "presentation-disconnected-share-menu")
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
                try self.showDocuments()
                try self.openDocument(title)
            }
            try self.wait("Three document tabs must be reachable") {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "value == 'Tab 3 of 3' OR value == '3 open documents'")).firstMatch.exists
            }
            try self.documentCapture(51, "three-document-tabs")
        }
    }

    func test23EmptyFolder() {
        variants {
            try self.tap("New"); try self.tap("New Folder")
            _ = try self.ui.waitForState { $0.openPanels.contains("organize.folder.new") }
            try self.libraryCapture(14, "new-folder")
            let field = self.ui.app.textFields["Folder name"]
            guard field.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Folder name field missing") }
            self.focus(field); field.typeText("Review Inbox")
            try self.tap("Create Folder")
            _ = try self.ui.waitForState { !$0.openPanels.contains("organize.folder.new") }
            try self.folder("Review Inbox")
            try self.wait("The new folder must contain no documents") {
                self.ui.app.descendants(matching: .any).matching(identifier: "cmd.doc.open").count == 0
            }
            try self.libraryCapture(15, "empty-folder")
        }
    }

    func test24RenderError() {
        variants(scenario: .failedRender) {
            try self.openNotebook()
            _ = try self.require("Try Again")
            try self.capture(72, "page-render-error") {
                $0.screen == "document" && $0.fixtureScenario == "failedRender" && $0.renderFailureCount == 1
            }
        }
    }

    private func closeSettings() throws {
        try tap("sheet.dismiss")
        try wait("Settings must dismiss") { !self.query("sheet.dismiss").firstMatch.exists }
    }

    private func openSettingsPage(_ title: String) throws {
        let back = ui.app.navigationBars.buttons["Settings"].firstMatch
        if back.isHittable { back.tap() }
        let field = try searchField()
        self.focus(field); field.typeKey("a", modifierFlags: .command); field.typeText(title)
        try tap(title, scroll: true)
        try wait("Settings must open \(title)") {
            self.ui.app.navigationBars[title].exists
        }
    }

    private func settingsPages(_ pages: [(Int, String, String)]) {
        variants {
            try self.settings()
            for (number, title, stem) in pages {
                try self.openSettingsPage(title)
                try self.libraryCapture(number, "settings-" + stem)
            }
            try self.closeSettings()
        }
    }

    func test25LibraryContextMenu() {
        variants {
            let document = self.ui.app.buttons.matching(identifier: "cmd.doc.open")
                .matching(NSPredicate(format: "label BEGINSWITH %@", self.notebook)).firstMatch
            _ = try self.require(self.notebook)
            document.press(forDuration: 1)
            _ = try self.require("Rename")
            try self.libraryCapture(11, "library-document-context-menu")
        }
    }

    func test26CreationCoversAndPaper() {
        variants {
            try self.tap("New"); try self.tap("Notebook")
            _ = try self.reachable("No cover", scroll: true)
            try self.libraryCapture(25, "new-notebook-covers")
            try self.tap("More Templates…", scroll: true)
            _ = try self.require("Choose Paper")
            try self.libraryCapture(26, "paper-template-library")
        }
    }

    private func creation(_ title: String, heading: String, number: Int, stem: String) {
        variants {
            try self.tap("New")
            if title == "Whiteboard" {
                try self.tap(title)
            } else {
                // The shared New form's type picker supplies the optional title form.
                // The direct Text Document and Study Set shortcuts create immediately.
                try self.tap("Notebook")
                if title == "Text Document" && !self.query(title).firstMatch.isHittable {
                    try self.tap("Text")
                } else { try self.tap(title) }
            }
            _ = try self.require(heading)
            try self.libraryCapture(number, stem)
        }
    }
    func test27CreateWhiteboard() { creation("Whiteboard", heading: "New Whiteboard", number: 27, stem: "new-whiteboard") }
    func test28CreateTextDocument() { creation("Text Document", heading: "New Text Document", number: 28, stem: "new-text-document") }
    func test29CreateStudySet() { creation("Study Set", heading: "New Study Set", number: 29, stem: "new-study-set") }

    func test30StickyNote() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("sticky")
            try self.tap("menu.toolSettings")
            _ = try self.require("Sign notes as")
            try self.documentCapture(43, "sticky-note-options")
            self.ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            try self.wait("Sticky settings must close before inserting a note") {
                !self.query("Sign notes as").firstMatch.exists
            }
            self.ui.coordinate(CGPoint(x: 0.5, y: 0.6)).tap()
            let editor = self.ui.app.textViews["Sticky note"]
            guard editor.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("Sticky editor missing") }
            self.focus(editor); editor.typeText("Review Newton’s second law")
            try self.documentCapture(44, "sticky-note-editor")
        }
    }

    func test31ImageInsertion() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("image")
            self.ui.coordinate(CGPoint(x: 0.5, y: 0.6)).tap()
            _ = try self.require("Files")
            try self.documentCapture(45, "image-source-picker")
        }
    }

    func test32Ruler() {
        variants {
            try self.openNotebook(); try self.ui.tapCommand("ruler.set")
            let ruler = try self.require("Ruler")
            try self.documentCapture(48, "ruler")
            ruler.doubleTap()
            _ = try self.require("Set Angle…")
            try self.documentCapture(49, "ruler-menu")
        }
    }

    func test33ZoomWindowAndScales() {
        variants {
            try self.openNotebook(); try self.ui.tapCommand("zoom.toggle")
            _ = try self.require("Zoom Window writing area")
            try self.documentCapture(52, "zoom-window")
            try self.tap("Close Zoom Window")
            try self.tap("tool.lasso")
            _ = try self.ui.waitForState { $0.tool == "lasso" }
            let initial = try self.ui.state().zoom
            try self.ui.pinchZoom(scale: 1.5)
            let zoomed = try self.ui.waitForState { $0.zoom > initial + 0.05 }
            try self.documentCapture(53, "canvas-zoomed-in")
            try self.ui.pinchZoom(scale: 0.4)
            _ = try self.ui.waitForState { $0.zoom < zoomed.zoom - 0.05 }
            try self.documentCapture(54, "canvas-zoomed-out")
        }
    }

    func test34PageMenu() {
        pageMenu(styles: ["light"])
    }

    func test34PageMenuDark() {
        pageMenu(styles: ["dark"])
    }

    private func pageMenu(styles: [String]) {
        variants(styles: styles) {
            try self.openNotebook(); try self.ui.tapCommand("sidebar.toggle")
            let page = self.ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1'")).firstMatch
            guard page.waitForExistence(timeout: 12) else { throw NibUI.Failure.message("First thumbnail missing") }
            page.press(forDuration: 1)
            _ = try self.require("Duplicate")
            try self.documentCapture(58, "page-context-menu")
        }
    }

    func test35GoToPage() {
        variants {
            try self.openNotebook(); try self.tap("menu.more")
            try self.tap("Go to Page…", scroll: true)
            _ = try self.require("Page number or title")
            try self.documentCapture(59, "go-to-page")
        }
    }

    func test36ClearPageConfirmation() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("eraser")
            try self.tap("menu.toolSettings"); try self.tap("Clear Page", scroll: true)
            _ = try self.require("eraser.clearPage.confirmation")
            try self.documentCapture(60, "clear-page-confirmation")
        }
    }

    func test37AssistantAnswer() {
        variants(agent: true) {
            try self.openNotebook(); try self.tap("Assistant")
            let composer = try self.require("Question or instruction")
            self.focus(composer); composer.typeText("Explain velocity and acceleration")
            try self.tap("Send to assistant")
            try self.wait("The real agent must display the fixture model answer", timeout: 60) {
                self.ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Velocity is displacement per unit time'")).firstMatch.exists
            }
            try self.capture(66, "ai-assistant-answer") { $0.openPanels.contains("aichat.panel") }
        }
    }

    func test38SettingsGeneralPages() {
        settingsPages([(91,"Profile","profile"), (92,"Appearance","appearance"), (93,"Password Protection","password")])
    }
    func test38SettingsGeneralPagesPart2() {
        settingsPages([(94,"Accessibility","accessibility"), (95,"Language","language"), (96,"Recording Settings","recording")])
    }
    func test38SettingsGeneralPagesPart3() {
        settingsPages([(97,"Keyboard and Pointer","keyboard"), (98,"Calendar","calendar"), (99,"Collaboration","collaboration")])
    }
    func test38SettingsGeneralPagesPart4() {
        settingsPages([(100,"Notifications","notifications")])
    }
    func test39SettingsEditingPages() {
        settingsPages([(102,"Tabs","tabs"), (103,"Toolbar","toolbar"), (104,"Undo and Redo","undo")])
    }
    func test39SettingsEditingPagesPart2() {
        settingsPages([(105,"Alignment and snapping","snapping"), (106,"Elements and GIFs","elements"), (107,"Layers","layers")])
    }
    func test40SettingsWritingPages() {
        settingsPages([(108,"Apple Pencil","apple-pencil"), (110,"Smart Ink","smart-ink"), (111,"Handwriting Recognition","recognition")])
    }
    func test40SettingsWritingPagesPart2() {
        settingsPages([(112,"Shape Recognition","shape-recognition"), (113,"Writing Aids","writing-aids")])
    }
    func test41SettingsAIPages() {
        settingsPages([(114,"AI","ai"), (115,"Use my Claude subscription","claude-subscription"), (116,"Use my ChatGPT subscription","chatgpt-subscription")])
    }
    func test41SettingsAIPagesPart2() {
        settingsPages([(117,"Add provider","other-provider"), (118,"Meeting AI","meeting-ai")])
    }
    func test42SettingsSyncPages() {
        settingsPages([(119,"Backup","backup"), (120,"WebDAV","webdav"), (121,"Collaboration Relay","relay")])
    }
    func test42SettingsSyncPagesPart2() {
        settingsPages([(122,"Library Repair","repair"), (124,"Bridge","bridge")])
    }
    func test43SettingsAboutPages() {
        settingsPages([(125,"Troubleshooting","troubleshooting"), (126,"Developer","developer"), (127,"About Nib","about")])
    }
    func test43SettingsAboutPagesPart2() {
        settingsPages([(128,"Privacy & Data","privacy"), (129,"Goodnotes Parity","parity")])
    }

    func test44FirstRun() {
        variants(onboarding: true) {
            try self.capture(1, "onboarding-library") { _ in true }
            // Resume an external library choice when present; otherwise capture the
            // real confirmation for keeping notes in the app's current location.
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


    func test45AdditionalToolOptions() {
        variants {
            try self.openNotebook()
            try self.tap("tool.more")
            _ = try self.require("tool.tape")
            try self.documentCapture(34, "more-tools")
            try self.tap("tool.tape", scroll: true)
            _ = try self.ui.waitForState { $0.tool == "tape" }
            try self.tap("menu.toolSettings")
            _ = try self.require("Pattern")
            try self.documentCapture(42, "tape-options")
            self.ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            try self.ui.selectTool("pencil"); try self.tap("menu.toolSettings")
            _ = try self.require("Pencil")
            try self.documentCapture(36, "pencil-options")
            self.ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            try self.ui.selectTool("laser"); try self.tap("menu.toolSettings")
            _ = try self.require("Laser mode")
            try self.documentCapture(47, "laser-options")
        }
    }

    func test46Elements() {
        variants {
            try self.openNotebook(); try self.ui.selectTool("elements")
            try self.tap("tool.elements")
            _ = try self.require("Search elements")
            try self.documentCapture(46, "elements-library")
        }
    }

    func test47LibraryCollections() {
        variants {
            for (number, title, stem) in [(16,"Favourites","favourites"), (17,"Shared","shared"),
                    (18,"Recents","recents"), (19,"Study Sets","study-sets"), (20,"Gallery","gallery"), (21,"Trash","trash-empty"), (22,"Calendar","calendar")] {
                let row = self.ui.app.buttons.matching(identifier: "cmd.library.setView")
                    .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
                if !self.query("App Menu").firstMatch.isHittable { try self.tap("Show Library") }
                _ = try self.reachable(title, scroll: true)
                guard row.waitForExistence(timeout: 12), row.isHittable else {
                    throw NibUI.Failure.message("Library destination must be reachable: \(title)")
                }
                row.tap()
                let panels = ["Favourites": "organize.favourites", "Shared": "collabpresence.shared",
                              "Gallery": "pluginmanager.gallery", "Trash": "organize.trash", "Calendar": "calendar.tab"]
                if let panel = panels[title] {
                    _ = try self.ui.waitForState { $0.openPanels.contains(panel) }
                } else {
                    _ = try self.require(title)
                    if title == "Study Sets" { _ = try self.require("Motion flashcards") }
                }
                try self.libraryCapture(number, "library-" + stem)
            }
        }
    }

    func test48DocumentMenus() {
        variants {
            try self.openNotebook(); try self.tap("menu.title")
            _ = try self.require("Rename")
            try self.documentCapture(63, "document-title-menu")
            self.ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            try self.tap("menu.more")
            _ = try self.require("Go to Page…")
            try self.documentCapture(64, "document-more-menu")
        }
    }

    func test49ShareLive() {
        variants {
            try self.openNotebook(); try self.tap("menu.title")
            try self.tap("Collaborators", scroll: true)
            _ = try self.require("Share Live")
            try self.documentCapture(71, "collaboration-share-live")
        }
    }

    func test50WhiteboardTemplates() {
        variants {
            try self.openDocument("Concept map")
            try self.tap("tool.more"); try self.tap("Templates", scroll: true)
            try self.capture(80, "whiteboard-templates") { $0.openPanels.contains("whiteboard.templates") }
        }
    }

    func test51StudyOptionsAndSmartLearn() {
        variants {
            try self.openDocument("Motion flashcards"); try self.tap("Practice")
            try self.tap("Study options")
            _ = try self.require("Appearance and reminders")
            try self.documentCapture(88, "study-options")
        }
    }

    func test52SmartLearn() {
        variants {
            try self.openDocument("Motion flashcards"); try self.tap("Smart Learn")
            _ = try self.require("Question side")
            try self.capture(89, "study-smart-learn") { $0.openPanels.contains("studysession.smartLearn") }
        }
    }


    func test53AudioAndTranscriptEmpty() {
        variants {
            try self.openNotebook(); try self.ui.tapCommand("sidebar.toggle")
            try self.tap("Panel Options"); try self.tap("Audio")
            _ = try self.require("No recordings yet")
            try self.capture(73, "audio-empty") { $0.openPanels.contains("audio") }
            try self.tap("menu.more"); try self.tap("Transcript", scroll: true)
            _ = try self.ui.waitForState { $0.openPanels.contains("transcription") }
            _ = try self.require("Transcript")
            _ = try self.require("No recordings yet")
            try self.capture(78, "transcript-empty") { $0.openPanels.contains("transcription") }
        }
    }

    func test54AudioRecordingAndPlayback() {
        let monitor = addUIInterruptionMonitor(withDescription: "Capture microphone permission") { alert in
            guard let allow = alert.buttons.allElementsBoundByIndex.first(where: {
                $0.label.hasPrefix("Allow") || $0.label == "OK"
            }) else { return false }
            allow.tap(); return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        variants {
            try self.openNotebook(); try self.ui.tapCommand("audio.record")
            if !self.query("Pause Recording").firstMatch.isHittable {
                self.ui.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            _ = try self.require("Pause Recording")
            let timer = self.ui.app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Recording' AND value != nil")).firstMatch
            let initial = timer.value as? String
            try self.wait("The real recording timer must advance", timeout: 15) {
                timer.value as? String != initial
            }
            try self.documentCapture(74, "audio-recording")
            try self.tap("Pause Recording")
            _ = try self.require("Resume Recording")
            try self.documentCapture(75, "audio-recording-paused")
            try self.tap("Stop Recording")
            try self.ui.tapCommand("sidebar.toggle"); try self.tap("Panel Options"); try self.tap("Audio")
            let clips = self.ui.app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH 'Recording' AND NOT label CONTAINS 'Settings'"))
            try self.wait("The saved clip must appear in Audio") {
                clips.allElementsBoundByIndex.contains { $0.isHittable }
            }
            try self.capture(76, "audio-recordings") { $0.openPanels.contains("audio") }
            try XCTUnwrap(clips.allElementsBoundByIndex.first { $0.isHittable }).tap()
            _ = try self.require("Playback position")
            try self.documentCapture(77, "audio-playback")
        }
    }


    func test55TextDocumentBlockMenus() {
        variants {
            try self.openDocument("Lab report")
            let paragraph = self.ui.app.textViews.matching(NSPredicate(
                format: "value CONTAINS %@", "Measure distance and time")).firstMatch
            guard paragraph.waitForExistence(timeout: 12) else {
                throw NibUI.Failure.message("The fixture paragraph must be editable")
            }
            self.focus(paragraph); paragraph.typeText(" /")
            _ = try self.require("Blocks")
            try self.documentCapture(82, "text-document-slash-menu")
            self.ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            self.ui.app.typeKey("t", modifierFlags: .command)
            _ = try self.require("Turn Into")
            try self.documentCapture(83, "text-document-turn-into")
        }
    }

}
