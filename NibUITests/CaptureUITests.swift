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
        XCUIDevice.shared.orientation = .portrait
    }

    private func variants(scenario: NibUI.FixtureScenario = .standard,
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
                    XCUIDevice.shared.orientation = .portrait
                    ui.app.launch()
                    _ = try ui.waitForState { $0.screen == "library" }
                    // Publish a populated accessibility layout, as NibUI.launchFixture does.
                    XCUIDevice.shared.orientation = .landscapeLeft
                    if direction == "portrait" { XCUIDevice.shared.orientation = .portrait }
                    try wait("The scene must reach \(direction)") {
                        let frame = self.ui.app.frame
                        return direction == "portrait" ? frame.height > frame.width : frame.width > frame.height
                    }
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

    func test01Library() {
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

    func test02LibrarySearch() {
        variants {
            try self.ui.tapCommand("search.open")
            let field = try self.searchField()
            field.tap(); field.typeText("Physics")
            _ = try self.require(self.notebook)
            try self.libraryCapture(4, "library-search")
        }
    }

    func test03Creation() {
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

    func test05PenOptions() { toolOptions("pen", title: "Pen", number: 11) }
    func test06HighlighterOptions() { toolOptions("highlighter", title: "Highlighter", number: 12) }
    func test07EraserOptions() { toolOptions("eraser", title: "Eraser", number: 13) }
    func test08LassoOptions() { toolOptions("lasso", title: "Lasso", number: 14) }
    func test09ShapesOptions() { toolOptions("shape", title: "Shapes", number: 15) }
    func test10TextOptions() { toolOptions("text", title: "Text", number: 16) }

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
            try self.capture(17, "lasso-object-menu") { $0.screen == "document" && $0.selectionCount > 0 }
        }
    }

    func test12PageSidebarAndOutline() {
        variants {
            try self.openNotebook()
            try self.ui.tapCommand("sidebar.toggle")
            try self.capture(18, "page-sidebar") { $0.openPanels.contains("sidebar.pages") }
            try self.tap("Outline")
            _ = try self.require("No outline yet")
            try self.capture(19, "outline") { $0.openPanels.contains("outline.tab") }
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
            try self.documentCapture(20, "document-search-matches")
        }
    }

    func test14Assistant() {
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

    func test15PluginManager() {
        variants {
            try self.settings()
            try self.tap("Plugins", scroll: true)
            _ = try self.require("Install from…")
            try self.libraryCapture(22, "plugin-manager")
        }
    }

    func test16Settings() {
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

    func test17Export() {
        variants {
            try self.openNotebook()
            try self.tap("Share and Export")
            // The share menu contains the production export action; open the format sheet.
            try self.ui.tapCommand("export.present")
            _ = try self.require("Save to Files")
            try self.documentCapture(26, "export-sheet")
        }
    }

    func test18Whiteboard() {
        variants {
            try self.ui.openDocument("Concept map")
            try self.capture(27, "whiteboard") { $0.screen == "document" && $0.itemCountOnPage == 3 }
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
            try self.documentCapture(28, "text-document")
        }
    }

    func test20StudySession() {
        variants {
            try self.ui.openDocument("Motion flashcards")
            try self.tap("Practice")
            try self.capture(29, "study-session") { $0.openPanels.contains("studysession.practice") }
        }
    }

    func test21Presentation() {
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

    func test22ThreeDocumentTabs() {
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
            try self.libraryCapture(32, "empty-folder")
        }
    }

    func test24RenderError() {
        variants(scenario: .failedRender) {
            try self.openNotebook()
            _ = try self.require("Try Again")
            try self.capture(33, "page-render-error") {
                $0.screen == "document" && $0.fixtureScenario == "failedRender" && $0.renderFailureCount == 1
            }
        }
    }
}
