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
        defer { ui?.app.terminate() }
        try ui?.handleAuthorizationAlerts()
        XCUIDevice.shared.orientation = .portrait
    }

    /// Waits for one explicit appearance/orientation fixture, keeping each capture scenario within its own allowance.
    private func variants(scenario: NibUI.FixtureScenario = .standard,
                          _ body: () throws -> Void) {
        ui = NibUI()
        do {
            ui.app.launchArguments = ["-NibUITestFixture", "-NibUITestScenario", scenario.rawValue,
                                      "-NibUITestAppearance", appearance,
                                      "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            ui.app.launch()
            try ui.handleAuthorizationAlerts()
            _ = try ui.waitForState(timeout: 120) { $0.screen == "library" }
            try ui.handleAuthorizationAlerts()
            try ui.establishFullScreen()
            XCUIDevice.shared.orientation = orientation == "portrait" ? .portrait : .landscapeLeft
            try wait("The scene must reach \(orientation)") {
                let frame = self.ui.app.windows.firstMatch.frame
                return self.orientation == "portrait" ? frame.height > frame.width : frame.width > frame.height
            }
            try ui.establishFullScreen()
            try body()
        } catch {
            let reason = "\(name) / \(appearance) / \(orientation): \(error)"
            attach(XCTAttachment(string: reason + "\n\n" + ui.app.debugDescription), name: "unreachable-\(name)")
            attach(XCTAttachment(screenshot: XCUIScreen.main.screenshot()), name: "diagnostic-\(name)")
            XCTFail(reason)
        }
        ui.app.terminate()
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
            format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", name, name, name + ","))
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

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture01Library() {
        variants {
            _ = try self.require(self.notebook)
            try self.libraryCapture(1, "library-grid")
            try self.tap("Sort and View")
            try self.tap("List")
            self.ui.app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.10)).tap()
            _ = try self.require(self.notebook)
            try self.libraryCapture(2, "library-list")
            try self.folder("Semester Notes")
            _ = try self.require("Lecture notes")
            try self.libraryCapture(3, "open-folder")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture02LibrarySearch() {
        variants {
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            field.tap(); field.typeText("Physics")
            _ = try self.require(self.notebook)
            try self.libraryCapture(4, "library-search")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture03Creation() {
        variants {
            try self.tap("New")
            _ = try self.require("Notebook")
            try self.libraryCapture(5, "new-menu")
            try self.tap("Notebook")
            _ = try self.require("New Notebook")
            try self.capture(6, "new-notebook") { $0.screen == "library" && !$0.openPanels.isEmpty }
        }
    }

    private func dock(_ edge: String) throws {
        if try ui.state().paletteDock?.edge == edge { return }
        let destination: CGVector
        switch edge {
        case "left": destination = CGVector(dx: 0.025, dy: 0.5)
        case "top": destination = CGVector(dx: 0.5, dy: 0.12)
        default: destination = CGVector(dx: 0.5, dy: 0.94)
        }
        try ui.dragPalette(to: CGPoint(x: destination.dx, y: destination.dy))
        _ = try ui.waitForState(timeout: 12) { $0.paletteDock?.edge == edge }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture04CanvasPalette() {
        variants {
            try self.openNotebook()
            for (number, edge) in [(7, "left"), (8, "top"), (9, "bottom")] {
                try self.dock(edge)
                try self.capture(number, "canvas-palette-" + edge) {
                    $0.screen == "document" && $0.paletteDock?.edge == edge
                }
            }
            try self.ui.selectTool("pen")
            _ = try self.require("menu.toolSettings")
            try self.capture(10, "options-bar") { $0.screen == "document" && $0.tool == "pen" }
        }
    }

    private func toolOptions(_ id: String, title: String, number: Int) {
        variants {
            try self.openNotebook()
            try self.ui.selectTool(id)
            try self.tap("menu.toolSettings")
            guard self.ui.app.staticTexts[title].firstMatch.waitForExistence(timeout: 12) else {
                throw NibUI.Failure.message("\(title) options did not open")
            }
            try self.capture(number, id == "shape" ? "shapes-options" : id + "-options") {
                $0.screen == "document" && $0.tool == id
            }
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture05PenOptions() { toolOptions("pen", title: "Pen", number: 11) }
    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture06HighlighterOptions() { toolOptions("highlighter", title: "Highlighter", number: 12) }
    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture07EraserOptions() { toolOptions("eraser", title: "Eraser", number: 13) }
    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture08LassoOptions() { toolOptions("lasso", title: "Lasso", number: 14) }
    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture09ShapesOptions() { toolOptions("shape", title: "Shapes", number: 15) }
    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture10TextOptions() { toolOptions("text", title: "Text", number: 16) }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture11LassoSelection() {
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
            try self.capture(17, "lasso-object-menu") { $0.screen == "document" && $0.selectionCount > 0 }
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture12PageSidebarAndOutline() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("sidebar.toggle")
            try self.capture(18, "page-sidebar") { $0.openPanels.contains("sidebar.pages") }
            try self.tap("Outline")
            _ = try self.require("No outline yet")
            try self.capture(19, "outline") { $0.openPanels.contains("outline.tab") }
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture13DocumentSearch() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            field.tap(); field.typeText("Motion")
            try self.wait("Document search must contain matches", timeout: 30) {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH 'Search result ' AND label CONTAINS ' of '")).firstMatch.exists
            }
            try self.documentCapture(20, "document-search-matches")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture14Assistant() {
        variants {
            try self.openNotebook()
            try self.tap("Assistant")
            try self.capture(21, "ai-assistant") { $0.openPanels.contains("aichat.panel") }
        }
    }

    private func settings() throws {
        ui.app.typeKey(",", modifierFlags: .command)
        _ = try require("Settings")
        _ = try ui.waitForState { $0.screen == "library" }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture15PluginManager() {
        variants {
            try self.settings()
            try self.tap("Plugins", scroll: true)
            _ = try self.require("Install from…")
            try self.libraryCapture(22, "plugin-manager")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture16Settings() {
        variants {
            try self.settings()
            try self.libraryCapture(23, "settings-general")
            try self.tap("Editing", scroll: true)
            try self.tap("Document Editing", scroll: true)
            _ = try self.require("Open documents in tabs")
            try self.libraryCapture(24, "settings-editing")
            try self.tap("Stylus", scroll: true)
            try self.tap("Stylus & Palm Rejection", scroll: true)
            try self.libraryCapture(25, "settings-stylus")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture17Export() {
        variants {
            try self.openNotebook()
            try self.tap("Share and Export")
            // The share menu contains the production export action; open the format sheet.
            try self.ui.tapCommand("export.present")
            _ = try self.require("Save to Files")
            try self.documentCapture(26, "export-sheet")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture18Whiteboard() {
        variants {
            try self.ui.openDocument("Concept map")
            try self.capture(27, "whiteboard") { $0.screen == "document" && $0.itemCountOnPage == 3 }
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture19TextDocument() {
        variants {
            try self.ui.openDocument("Lab report")
            try self.wait("The text document must show its fixture paragraph") {
                self.ui.app.descendants(matching: .any).matching(NSPredicate(
                    format: "value CONTAINS %@ OR label CONTAINS %@", "Measure distance and time", "Measure distance and time"
                )).firstMatch.exists
            }
            try self.documentCapture(28, "text-document")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture20StudySession() {
        variants {
            try self.ui.openDocument("Motion flashcards")
            try self.tap("Practice")
            try self.capture(29, "study-session") { $0.openPanels.contains("studysession.practice") }
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture21Presentation() {
        variants {
            try self.openNotebook()
            try self.tap("Share and Export")
            // Production exposes this only with an external display. Do not simulate one
            // or relabel the ordinary canvas as presentation when a lane lacks a display.
            try self.tap("Presenter Page", scroll: true)
            _ = try self.require("Stop Presenting")
            try self.documentCapture(30, "presentation-mode")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture22ThreeDocumentTabs() {
        variants {
            try self.settings()
            try self.tap("Editing", scroll: true)
            try self.tap("Tabs", scroll: true)
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
            try self.documentCapture(31, "three-document-tabs")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture23EmptyFolder() {
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
            try self.libraryCapture(32, "empty-folder")
        }
    }

    /// Waits for the named capture surface and attaches it after the state predicate succeeds.
    private func capture24RenderError() {
        variants(scenario: .failedRender) {
            try self.openNotebook()
            _ = try self.require("Try Again")
            try self.capture(33, "page-render-error") {
                $0.screen == "document" && $0.fixtureScenario == "failedRender" && $0.renderFailureCount == 1
            }
        }
    }

    // Each original test retains light/portrait coverage; the other variants have independent budgets.
    func test01Library() { appearance = "light"; orientation = "portrait"; capture01Library() }
    func test01LibraryLightLandscape() { appearance = "light"; orientation = "landscape"; capture01Library() }
    func test01LibraryDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture01Library() }
    func test01LibraryDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture01Library() }
    func test02LibrarySearch() { appearance = "light"; orientation = "portrait"; capture02LibrarySearch() }
    func test02LibrarySearchLightLandscape() { appearance = "light"; orientation = "landscape"; capture02LibrarySearch() }
    func test02LibrarySearchDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture02LibrarySearch() }
    func test02LibrarySearchDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture02LibrarySearch() }
    func test03Creation() { appearance = "light"; orientation = "portrait"; capture03Creation() }
    func test03CreationLightLandscape() { appearance = "light"; orientation = "landscape"; capture03Creation() }
    func test03CreationDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture03Creation() }
    func test03CreationDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture03Creation() }
    func test04CanvasPalette() { appearance = "light"; orientation = "portrait"; capture04CanvasPalette() }
    func test04CanvasPaletteLightLandscape() { appearance = "light"; orientation = "landscape"; capture04CanvasPalette() }
    func test04CanvasPaletteDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture04CanvasPalette() }
    func test04CanvasPaletteDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture04CanvasPalette() }
    func test05PenOptions() { appearance = "light"; orientation = "portrait"; capture05PenOptions() }
    func test05PenOptionsLightLandscape() { appearance = "light"; orientation = "landscape"; capture05PenOptions() }
    func test05PenOptionsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture05PenOptions() }
    func test05PenOptionsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture05PenOptions() }
    func test06HighlighterOptions() { appearance = "light"; orientation = "portrait"; capture06HighlighterOptions() }
    func test06HighlighterOptionsLightLandscape() { appearance = "light"; orientation = "landscape"; capture06HighlighterOptions() }
    func test06HighlighterOptionsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture06HighlighterOptions() }
    func test06HighlighterOptionsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture06HighlighterOptions() }
    func test07EraserOptions() { appearance = "light"; orientation = "portrait"; capture07EraserOptions() }
    func test07EraserOptionsLightLandscape() { appearance = "light"; orientation = "landscape"; capture07EraserOptions() }
    func test07EraserOptionsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture07EraserOptions() }
    func test07EraserOptionsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture07EraserOptions() }
    func test08LassoOptions() { appearance = "light"; orientation = "portrait"; capture08LassoOptions() }
    func test08LassoOptionsLightLandscape() { appearance = "light"; orientation = "landscape"; capture08LassoOptions() }
    func test08LassoOptionsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture08LassoOptions() }
    func test08LassoOptionsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture08LassoOptions() }
    func test09ShapesOptions() { appearance = "light"; orientation = "portrait"; capture09ShapesOptions() }
    func test09ShapesOptionsLightLandscape() { appearance = "light"; orientation = "landscape"; capture09ShapesOptions() }
    func test09ShapesOptionsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture09ShapesOptions() }
    func test09ShapesOptionsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture09ShapesOptions() }
    func test10TextOptions() { appearance = "light"; orientation = "portrait"; capture10TextOptions() }
    func test10TextOptionsLightLandscape() { appearance = "light"; orientation = "landscape"; capture10TextOptions() }
    func test10TextOptionsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture10TextOptions() }
    func test10TextOptionsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture10TextOptions() }
    func test11LassoSelection() { appearance = "light"; orientation = "portrait"; capture11LassoSelection() }
    func test11LassoSelectionLightLandscape() { appearance = "light"; orientation = "landscape"; capture11LassoSelection() }
    func test11LassoSelectionDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture11LassoSelection() }
    func test11LassoSelectionDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture11LassoSelection() }
    func test12PageSidebarAndOutline() { appearance = "light"; orientation = "portrait"; capture12PageSidebarAndOutline() }
    func test12PageSidebarAndOutlineLightLandscape() { appearance = "light"; orientation = "landscape"; capture12PageSidebarAndOutline() }
    func test12PageSidebarAndOutlineDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture12PageSidebarAndOutline() }
    func test12PageSidebarAndOutlineDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture12PageSidebarAndOutline() }
    func test13DocumentSearch() { appearance = "light"; orientation = "portrait"; capture13DocumentSearch() }
    func test13DocumentSearchLightLandscape() { appearance = "light"; orientation = "landscape"; capture13DocumentSearch() }
    func test13DocumentSearchDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture13DocumentSearch() }
    func test13DocumentSearchDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture13DocumentSearch() }
    func test14Assistant() { appearance = "light"; orientation = "portrait"; capture14Assistant() }
    func test14AssistantLightLandscape() { appearance = "light"; orientation = "landscape"; capture14Assistant() }
    func test14AssistantDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture14Assistant() }
    func test14AssistantDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture14Assistant() }
    func test15PluginManager() { appearance = "light"; orientation = "portrait"; capture15PluginManager() }
    func test15PluginManagerLightLandscape() { appearance = "light"; orientation = "landscape"; capture15PluginManager() }
    func test15PluginManagerDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture15PluginManager() }
    func test15PluginManagerDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture15PluginManager() }
    func test16Settings() { appearance = "light"; orientation = "portrait"; capture16Settings() }
    func test16SettingsLightLandscape() { appearance = "light"; orientation = "landscape"; capture16Settings() }
    func test16SettingsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture16Settings() }
    func test16SettingsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture16Settings() }
    func test17Export() { appearance = "light"; orientation = "portrait"; capture17Export() }
    func test17ExportLightLandscape() { appearance = "light"; orientation = "landscape"; capture17Export() }
    func test17ExportDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture17Export() }
    func test17ExportDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture17Export() }
    func test18Whiteboard() { appearance = "light"; orientation = "portrait"; capture18Whiteboard() }
    func test18WhiteboardLightLandscape() { appearance = "light"; orientation = "landscape"; capture18Whiteboard() }
    func test18WhiteboardDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture18Whiteboard() }
    func test18WhiteboardDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture18Whiteboard() }
    func test19TextDocument() { appearance = "light"; orientation = "portrait"; capture19TextDocument() }
    func test19TextDocumentLightLandscape() { appearance = "light"; orientation = "landscape"; capture19TextDocument() }
    func test19TextDocumentDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture19TextDocument() }
    func test19TextDocumentDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture19TextDocument() }
    func test20StudySession() { appearance = "light"; orientation = "portrait"; capture20StudySession() }
    func test20StudySessionLightLandscape() { appearance = "light"; orientation = "landscape"; capture20StudySession() }
    func test20StudySessionDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture20StudySession() }
    func test20StudySessionDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture20StudySession() }
    func test21Presentation() { appearance = "light"; orientation = "portrait"; capture21Presentation() }
    func test21PresentationLightLandscape() { appearance = "light"; orientation = "landscape"; capture21Presentation() }
    func test21PresentationDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture21Presentation() }
    func test21PresentationDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture21Presentation() }
    func test22ThreeDocumentTabs() { appearance = "light"; orientation = "portrait"; capture22ThreeDocumentTabs() }
    func test22ThreeDocumentTabsLightLandscape() { appearance = "light"; orientation = "landscape"; capture22ThreeDocumentTabs() }
    func test22ThreeDocumentTabsDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture22ThreeDocumentTabs() }
    func test22ThreeDocumentTabsDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture22ThreeDocumentTabs() }
    func test23EmptyFolder() { appearance = "light"; orientation = "portrait"; capture23EmptyFolder() }
    func test23EmptyFolderLightLandscape() { appearance = "light"; orientation = "landscape"; capture23EmptyFolder() }
    func test23EmptyFolderDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture23EmptyFolder() }
    func test23EmptyFolderDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture23EmptyFolder() }
    func test24RenderError() { appearance = "light"; orientation = "portrait"; capture24RenderError() }
    func test24RenderErrorLightLandscape() { appearance = "light"; orientation = "landscape"; capture24RenderError() }
    func test24RenderErrorDarkPortrait() { appearance = "dark"; orientation = "portrait"; capture24RenderError() }
    func test24RenderErrorDarkLandscape() { appearance = "dark"; orientation = "landscape"; capture24RenderError() }
}
