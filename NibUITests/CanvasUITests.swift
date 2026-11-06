import XCTest
import UIKit

/// Real UI coverage for the canvas inventory. No bridge commands or app-side gesture injection.
/// F006 owns navigation, F017 layout, F022 page actions, F038 the writing pane,
/// F044 boards, F073 keyboard routing, and F101 the canvas touch pipeline.
/// Device-only: Pencil pressure/tilt/hover/squeeze/double-tap, VoiceOver audio and
/// physical-keyboard behaviour beyond typeKey. These are not failing placeholder tests.
/// Genuine memory-pressure eviction and OS-managed Split View/Stage Manager resizing
/// need a separate system/device harness; orientation is exercised here.
@MainActor
final class CanvasUITests: XCTestCase {
    private var ui: NibUI!
    private let notebook = "Physics — Motion"
    private let whiteboard = "Concept map"

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        ui.logIdleSelectors(for: String(describing: type(of: self)))
        let scenario: NibUI.FixtureScenario
        if name.contains("testFailedPage") { scenario = .failedRender }
        else if name.contains("testLargeDocumentMemoryRecovery") { scenario = .largeDocument }
        else if name.contains("testBoardMarkSeen") { scenario = .unseenBoards }
        else { scenario = .standard }
        try ui.launchFixture(scenario: scenario)
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: ui.app.screenshot())
        screenshot.name = "Canvas-\(name)-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let state = XCTAttachment(string: String(describing: ui.probe.value))
        state.name = "Canvas-\(name)-qa-state"
        state.lifetime = .keepAlways
        add(state)
        if (testRun?.totalFailureCount ?? 0) > 0 {
            let hierarchy = XCTAttachment(string: ui.app.debugDescription)
            hierarchy.name = "Canvas-\(name)-failure-tree"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        ui.app.terminate()
    }

    private func open(_ title: String? = nil) throws {
        try ui.openDocument(title ?? notebook)
        XCTAssertTrue(ui.canvas.exists || ui.canvas.waitForExistence(timeout: 15), "Document must expose nib.canvas")
    }

    private func element(_ label: String) -> XCUIElement {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
    }

    private func content(_ text: String) throws -> XCUIElement {
        let target = ui.app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", text)).firstMatch
        XCTAssertTrue(target.exists || target.waitForExistence(timeout: 10), "Canvas must expose content: \(text)")
        return target
    }

    @discardableResult
    private func require(_ label: String, timeout: TimeInterval = 8) throws -> XCUIElement {
        let target = element(label)
        guard target.exists || target.waitForExistence(timeout: timeout) else {
            throw NibUI.Failure.message("Missing canvas control: \(label)\n\(ui.app.debugDescription)")
        }
        return target
    }

    /// Records discovery and menu activation separately from later state waits.
    private func tap(_ label: String) throws {
        try ui.timedAction("Canvas tap \(label)") { try self.performTap(label) }
    }
    private func performTap(_ label: String) throws {
        // Zoom options also names a retained ScrollView; only its actual button can toggle the popover.
        let type: XCUIElement.ElementType = label == "Zoom Window options" ? .button : .any
        let target = try ui.requireControl(label, type: type, scroll: true, timeout: 8)
        guard target.isEnabled else {
            throw NibUI.Failure.message("Canvas control is disabled: \(label)")
        }
        target.tap()
    }

    private func openBoardMenu(_ row: XCUIElement) throws {
        try ui.pressWithoutIdle(row, duration: 1)
        let item = try ui.requireControl("cmd.page.duplicate", type: .button, timeout: 8)
        guard item.isHittable else { throw NibUI.Failure.message("Board menu item is not hittable") }
    }

    private func boardMenuTap(_ label: String) throws {
        // Rename can expose its SF Symbol name instead of its title on the native menu.
        let name = label == "Rename" && !ui.app.buttons["Rename"].exists ? "pencil" : label
        let target = try ui.requireControl(name, type: .button, timeout: 8)
        try ui.tapWithoutIdle(target)
        let dismissed: () -> Bool = { [self] in
            !target.exists && !ui.app.buttons["cmd.page.duplicate"].exists
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in dismissed() }, object: nil)
        // The deadline bounds a menu that stays open. One existence query took 8 s while the rename alert and the
        // keyboard came up (run 42163879315), so the only evaluation ended after the deadline: ask once more.
        guard XCTWaiter.wait(for: [gone], timeout: 10) == .completed || dismissed() else {
            throw NibUI.Failure.message("Board context menu did not dismiss after \(label)")
        }
    }

    private func eventually(_ message: String, timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) {
        if predicate() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func unchanged(_ before: QAState, _ after: QAState, page: Bool = true) {
        XCTAssertEqual(after.document, before.document)
        if page {
            XCTAssertEqual(after.page, before.page)
            XCTAssertEqual(after.itemCountOnPage, before.itemCountOnPage, "Navigation must not create or remove items")
            XCTAssertEqual(after.strokeCountOnPage, before.strokeCountOnPage, "Navigation must not ink")
        }
        XCTAssertEqual(after.pageCount, before.pageCount)
        XCTAssertEqual(after.selectionCount, before.selectionCount)
        XCTAssertEqual(after.undoAvailable, before.undoAvailable, "Navigation must not add an edit to history")
    }

    private func bounded(_ state: QAState, board: Bool = false) {
        XCTAssertTrue(state.zoom.isFinite)
        XCTAssertGreaterThanOrEqual(state.zoom, board ? 0.05 - 0.001 : 0.5 - 0.001)
        XCTAssertLessThanOrEqual(state.zoom, board ? 4.001 : 8.001)
    }

    /// Uses the shared non-text focus preparation and waits for the requested canvas action.
    private func key(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = .command,
                     verifying result: () throws -> Void) throws {
        try ui.chord(key, modifiers, verifying: result)
    }

    /// Waits for an actual zoom step (or the already-reached clamp), never an unrelated probe change.
    private func zoomKey(_ key: String) throws {
        let before = try ui.state().zoom
        try ui.chord(key, .command) {
            try self.ui.waitForState {
                key == "-" ? ($0.zoom < before || abs($0.zoom - 0.5) < 0.001)
                    : ($0.zoom > before || abs($0.zoom - 8) < 0.001)
            }
        }
    }

    private func more(_ labels: String...) throws {
        try tap("menu.more")
        for label in labels { try tap(label) }
    }

    private func go(_ number: Int, shortcut: Bool = false) throws {
        let count = try ui.state().pageCount
        if shortcut { try key("g", [.command, .option]) { try self.ui.waitForState { $0.openPanels.contains("pages.goToPage") } } }
        else { try more("Go to Page…") }
        // The native field carries the placeholder "Page"; its accessibility label "Page number or title" sits on the
        // SwiftUI wrapper. Run 42163879315 matched neither with label and placeholder swapped: accept both names
        // in every attribute.
        let names = ["Page number or title", "Page"]
        let field = ui.app.textFields.matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@ OR placeholderValue IN %@", names, names, names)).firstMatch
        guard ui.measuredQuery("Go to Page typed field", { field.waitForExistence(timeout: 8) }) else {
            throw NibUI.Failure.message("Go to Page native field missing")
        }
        let autofocus = ui.isKeyboardFocused(field, allowingAttributeFallback: true, in: ui.app)
        if !autofocus {
            field.tap()
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.ui.isKeyboardFocused(field, allowingAttributeFallback: true, in: self.ui.app)
            }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: 3) == .completed else {
                throw NibUI.Failure.message("Go to Page field did not focus")
            }
        }
        ui.logQA("Go to Page focus", "page=\(number) autofocus=\(autofocus) verifiedOnce=true route=SPI")
        if ui.measuredQuery("Go to Page value", { field.value as? String }) != String(number) {
            try ui.focusedKey("a", .command)
            for digit in String(number) { try ui.focusedKey(String(digit)) }
        }
        try ui.waitForNativeText(in: field, equals: String(number))
        try tap("Go")
        _ = try ui.waitForState { !$0.openPanels.contains("pages.goToPage") }
        eventually("Go must activate page \(number)") {
            self.ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Page \(number) of \(count)"))
                .allElementsBoundByIndex.contains { $0.frame.height <= 60 && $0.frame.width > 0 }
        }
        _ = try page(number, count: count)
    }

    /// The paper accessibility element, excluding the identically labelled 40-point HUD.
    private func page(_ number: Int = 1, count: Int = 4) throws -> XCUIElement {
        let query = ui.app.otherElements.matching(NSPredicate(format: "label == %@", "Page \(number) of \(count)"))
        var found: XCUIElement?
        eventually("Page \(number) must be laid out") {
            found = query.allElementsBoundByIndex.first { $0.exists && $0.frame.height > 100 }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func setDirection(_ direction: String) throws {
        let started = ProcessInfo.processInfo.systemUptime
        defer { ui.logQA("Canvas direction row", "direction=\(direction) seconds=\(ProcessInfo.processInfo.systemUptime - started) edge=bottom; no homing") }
        try tap("menu.more")
        let menu = ui.app.scrollViews["More"].firstMatch
        guard menu.waitForExistence(timeout: 8) else { throw NibUI.Failure.message("More scrolling surface missing") }
        // Both options have the same command identifier. Resolve the actual button by
        // identifier AND label once, retaining the menu's current offset on every open.
        let row = menu.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                                    "cmd.doc.setScrollDirection", direction)).firstMatch
        if !row.isHittable {
            ui.revealFormElement(in: menu, edge: .bottom, named: direction, type: .button) { row }
            if let failure = ui.formRevealFailure { throw NibUI.Failure.message(failure) }
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.exists && row.isHittable && row.isEnabled
        }, object: row)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            throw NibUI.Failure.message("More scroll direction must be reachable and enabled: " + direction)
        }
        row.tap()
        // The action closes More. Reopen for the next choice, preserving any retained
        // list position; never home the list or assume both choices share one presentation.
        try ui.waitForMenuClosed(menu, named: "More direction " + direction)
    }

    private func pencilOnly() throws {
        // Settings is a real user action; the fixture deliberately starts in Any input mode.
        try tap("App Menu")
        try tap("Settings")
        if element("Stylus").waitForExistence(timeout: 5) { try tap("Stylus") }
        try tap("Stylus & Palm Rejection")
        let pencil = ui.app.buttons.matching(identifier: "cmd.settings.set")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Apple Pencil")).firstMatch
        XCTAssertTrue(pencil.waitForExistence(timeout: 8), "Settings must offer Pencil-only input")
        pencil.tap()
        eventually("Pencil-only input must become selected") { pencil.isSelected }
        try ui.dismissSheets()
    }

    private func boards() throws {
        try ui.tapCommand("sidebar.toggle")
        if !element("Add Board").exists { try tap("Boards") }
        _ = try require("Add Board")
    }

    private func boardRow(_ number: Int, count: Int) throws -> XCUIElement {
        let row = ui.app.buttons.matching(NSPredicate(format: "value == %@", "Board \(number) of \(count)")).firstMatch
        XCTAssertTrue(row.exists || row.waitForExistence(timeout: 8), "Boards navigator must expose board \(number) of \(count)")
        return row
    }

    private func zoomWindow() throws {
        try open()
        try showZoomWindow()
    }

    private func showZoomWindow() throws {
        try tap("tool.more")
        try tap("cmd.zoom.toggle")
        _ = try require("Zoom Window writing area")
        _ = try require("Zoom box")
    }

    private func option(_ title: String) throws {
        try tap("Zoom Window options")
        try tap(title)
    }

    private func drag(_ target: XCUIElement, from: CGPoint, to: CGPoint) {
        target.coordinate(withNormalizedOffset: CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.01, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: to.x, dy: to.y)),
                   withVelocity: 220, thenHoldForDuration: 0)
    }

    private func paneStroke(from: CGPoint = CGPoint(x: 0.2, y: 0.45), to: CGPoint = CGPoint(x: 0.45, y: 0.55)) throws {
        drag(try require("Zoom Window writing area"), from: from, to: to)
    }

    /// Box origin in page points, so auto-reveal/scrolling cannot masquerade as a box movement.
    private func boxRect() throws -> CGRect {
        let paper = try page().frame
        let box = try require("Zoom box").frame
        let zoom = try ui.state().zoom
        return CGRect(x: (box.minX - paper.minX) / zoom, y: (box.minY - paper.minY) / zoom,
                      width: box.width / zoom, height: box.height / zoom)
    }

    /// No nested waits: a missing page, box or probe means this outer poll is not ready.
    private func boxRectNow() -> CGRect? {
        let pages = ui.app.otherElements.matching(NSPredicate(format: "label == %@", "Page 1 of 4"))
        guard let paper = pages.allElementsBoundByIndex.first(where: { $0.exists && $0.frame.height > 100 })?.frame,
              let box = try? element("Zoom box").snapshot() else { return nil }
        var zoom: Double?
        _ = ui.matchesState { zoom = $0.zoom; return true }
        guard let zoom, zoom > 0 else { return nil }
        return CGRect(x: (box.frame.minX - paper.minX) / zoom, y: (box.frame.minY - paper.minY) / zoom,
                      width: box.frame.width / zoom, height: box.frame.height / zoom)
    }

    // canvas.scroll; F006/F101
    func testFingerScrollInPencilOnlyModeDoesNotDraw() throws {
        try pencilOnly()
        try open()
        let before = try ui.state()
        drag(ui.canvas, from: CGPoint(x: 0.5, y: 0.7), to: CGPoint(x: 0.5, y: 0.48))
        let after = try ui.waitForState { abs($0.contentOffset.y - before.contentOffset.y) > 30 }
        unchanged(before, after)
    }

    // canvas.pinch; F006
    func testPinchChangesZoomAroundFocalContentAndClamps() throws {
        try open(); try ui.selectTool("lasso")
        let before = try ui.state()
        let paper = try page().frame
        let focal = ui.interfacePoint(CGPoint(x: 0.5, y: 0.5))
        let anchor = CGPoint(x: (focal.x - paper.minX) / before.zoom, y: (focal.y - paper.minY) / before.zoom)
        try ui.pinchZoom(scale: 1.5, at: CGPoint(x: 0.5, y: 0.5))
        let zoomed = try ui.waitForState { $0.zoom > before.zoom + 0.1 }
        let zoomedPaper = try page().frame
        let projected = CGPoint(x: zoomedPaper.minX + anchor.x * zoomed.zoom,
                                y: zoomedPaper.minY + anchor.y * zoomed.zoom)
        // Include the arithmetic in ui.log as well as the attachment: downloaded lanes may omit text attachments.
        let geometry = "paper=\(paper) -> \(zoomedPaper), zoom=\(before.zoom) -> \(zoomed.zoom), "
            + "pageAnchor=\(anchor), focal=\(focal), projected=\(projected), "
            + "offset=\(before.contentOffset) -> \(zoomed.contentOffset)"
        XCTContext.runActivity(named: "Pinch focal oracle: \(geometry)") { _ in
            ui.recordGeometry("Pinch after zoom", touches: [focal, projected], selection: zoomedPaper)
        }
        XCTAssertEqual(zoomedPaper.minX + anchor.x * zoomed.zoom, focal.x, accuracy: 45, "Pinch must retain focal content")
        XCTAssertEqual(zoomedPaper.minY + anchor.y * zoomed.zoom, focal.y, accuracy: 45, "Pinch must retain focal content")
        unchanged(before, zoomed)
        for _ in 0..<3 { try ui.pinchZoom(scale: 4, at: CGPoint(x: 0.5, y: 0.5)); bounded(try ui.state()) }
        for _ in 0..<4 { try ui.pinchZoom(scale: 0.2, velocity: -1, at: CGPoint(x: 0.5, y: 0.5)); bounded(try ui.state()) }
        unchanged(before, try ui.state(), page: false)
        try go(1)
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
    }

    // canvas.doubleTap; F006/F101. Blank paper avoids item handlers and the non-page desk.
    func testDoubleTapTogglesFitAndTwiceFitWithoutItems() throws {
        try open()
        try key("0") { self.eventually("Fit must restore the specified landscape paper width") { abs(((try? self.page().frame.width) ?? 0) - 760) < 3 } }
        let before = try ui.state()
        ui.doubleTap(at: CGPoint(x: 0.75, y: 0.65))
        let twice = try ui.waitForState { $0.zoom > before.zoom + 0.1 }
        XCTAssertEqual(twice.zoom, min(before.zoom * 2, 8), accuracy: 0.05)
        ui.doubleTap(at: CGPoint(x: 0.75, y: 0.65))
        let fit = try ui.waitForState { abs($0.zoom - before.zoom) < 0.05 }
        unchanged(before, fit)
    }

    // view.zoom.in, view.zoom.out, view.zoom.actual, view.zoom.fit; F006/F073
    func testKeyboardZoomInOutFitAndActualSize() throws {
        try open()
        let initial = try ui.state()
        try key("0", [.command, .option]) { try self.ui.waitForState { abs($0.zoom - 1) < 0.001 } }
        _ = try ui.waitForState { abs($0.zoom - 1) < 0.001 }
        try zoomKey("=")
        _ = try ui.waitForState { abs($0.zoom - 1.25) < 0.001 }
        try zoomKey("+")
        _ = try ui.waitForState { abs($0.zoom - 1.5) < 0.001 }
        try zoomKey("-")
        _ = try ui.waitForState { abs($0.zoom - 1.25) < 0.001 }
        try key("0") { self.eventually("Fit must restore the specified landscape paper width") { abs(((try? self.page().frame.width) ?? 0) - 760) < 3 } }
        let fit = try ui.waitForState { abs($0.zoom - initial.zoom) < 0.01 }
        XCTAssertEqual(try page().frame.width, 760, accuracy: 3, "Landscape notebook fit width is 760 pt (DESIGN §14.2)")
        unchanged(initial, fit)
        for _ in 0..<12 { try zoomKey("=") }
        XCTAssertEqual(try ui.state().zoom, 8, accuracy: 0.001)
        for _ in 0..<16 { try zoomKey("-") }
        XCTAssertEqual(try ui.state().zoom, 0.5, accuracy: 0.001)
    }

    // canvas.fitPageGap. Explicit inventory/spec gap: never silently treat one fit mode as two controls.
    func testDistinctFitPageAndFitWidthControls() throws {
        try open()
        try more("Fit Page")
        let fitPage = try ui.state()
        let paper = try page().frame
        XCTAssertTrue(ui.canvas.frame.contains(paper), "Fit Page must fit the whole paper")
        try more("Fit Width")
        let fitWidth = try ui.waitForState { $0.zoom > fitPage.zoom + 0.01 }
        bounded(fitWidth)
        XCTAssertEqual(try page().frame.width, 760, accuracy: 3)
    }

    // view.scrollBy; F006. Board permits all four directions without notebook-edge clamping.
    func testOptionArrowKeysPanWithoutEditing() throws {
        try open(whiteboard)
        let initial = try ui.state()
        for arrow in [XCUIKeyboardKey.downArrow, .upArrow, .rightArrow, .leftArrow] {
            let before = try ui.state()
            try key(arrow.rawValue, .option) {
                try self.ui.waitForState { abs($0.contentOffset.x - before.contentOffset.x) + abs($0.contentOffset.y - before.contentOffset.y) > 20 }
            }
            let after = try ui.waitForState {
                abs($0.contentOffset.x - before.contentOffset.x) + abs($0.contentOffset.y - before.contentOffset.y) > 20
            }
            unchanged(initial, after)
        }
    }

    // doc.setScrollDirection + canvas.singlePage; F017/F006
    func testHorizontalAndVerticalSinglePageLayoutsPersist() throws {
        try open()
        try setDirection("Horizontal")
        try ui.twoFingerScroll(from: CGPoint(x: 0.8, y: 0.5), to: CGPoint(x: 0.2, y: 0.5))
        _ = try page(2)
        XCTAssertLessThanOrEqual(try page(2).frame.width, ui.canvas.frame.width)
        XCTAssertGreaterThanOrEqual(abs(try page(2).frame.midX - page(1).frame.midX), ui.canvas.frame.width - 3,
                                   "Horizontal layout must allocate a full viewport per page, not a spread")
        XCTAssertFalse(element("Two Page Spread").exists, "Only one-page-wide layouts are supported")
        try ui.tapCommand("window.showLibrary")
        try open()
        try go(1)
        let before = try ui.state()
        try ui.twoFingerScroll(from: CGPoint(x: 0.8, y: 0.5), to: CGPoint(x: 0.2, y: 0.5))
        _ = try ui.waitForState { $0.page != before.page }
        _ = try page(2)
    }

    func testVerticalSinglePageLayoutPersistsAfterHorizontal() throws {
        try open()
        // Preserve the original transition; fixture-default Vertical alone would be vacuous.
        try setDirection("Horizontal")
        try setDirection("Vertical")
        try go(1)
        XCTAssertEqual(try page(1).frame.midX, try page(2).frame.midX, accuracy: 2, "Vertical pages must share one column")
        XCTAssertGreaterThan(try page(2).frame.minY, try page(1).frame.maxY, "Continuous pages must have a gap")
        let first = try ui.state()
        try ui.twoFingerScroll(from: CGPoint(x: 0.5, y: 0.8), to: CGPoint(x: 0.5, y: 0.2))
        let scrolled = try ui.waitForState { $0.contentOffset.y > first.contentOffset.y + 100 }
        XCTAssertEqual(scrolled.contentOffset.x, first.contentOffset.x, accuracy: 3)
        try ui.tapCommand("window.showLibrary")
        try open()
        try go(1)
        XCTAssertEqual(try page().frame.width, 760, accuracy: 3)
    }

    // view.goToPage; F022/F006
    func testGoToPageKeyboardShortcutOpensAndNavigates() throws {
        try open()
        let before = try ui.state()
        try go(3, shortcut: true)
        XCTAssertNotEqual(try ui.state().page, before.page)
        XCTAssertEqual(try ui.state().pageCount, before.pageCount)
    }

    func testGoToPageRejectsInvalidNumbersAndNavigatesValidTarget() throws {
        try open()
        let before = try ui.state()
        try more("Go to Page…")
        let field = try require("Page number or title")
        for value in ["0", "5", "-1"] {
            try ui.replaceNativeText(in: field, with: value)
            let goButton = ui.app.buttons.matching(NSPredicate(format: "label == %@", "Go")).firstMatch
            XCTAssertTrue(goButton.waitForExistence(timeout: 5))
            XCTAssertFalse(goButton.isEnabled, "Invalid page \(value) must disable the dialog Go button; field=\(String(describing: field.value))")
            XCTAssertEqual(try ui.state().page, before.page)
        }
        try ui.replaceNativeText(in: field, with: "3")
        try tap("Go")
        _ = try page(3)
        let target = try ui.state()
        XCTAssertNotEqual(target.page, before.page)
        XCTAssertEqual(target.pageCount, 4)
        try go(1)
        unchanged(before, try ui.state())
    }

    // canvas.pageHUD; F006/F017
    func testPageHUDOpensNavigatorAndMatchesCurrentPage() throws {
        try open()
        try go(3)
        let hud = try XCTUnwrap(ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Page 3 of 4"))
            .allElementsBoundByIndex.first { $0.frame.height <= 60 && $0.frame.width > 0 })
        hud.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()
        _ = try ui.waitForState { !$0.openPanels.isEmpty }
        try ui.tapCommand("sidebar.toggle")
        _ = try ui.waitForState { $0.openPanels.isEmpty }
    }

    // canvas.scrub; F006. The physical drag is the same adjustable control used by VoiceOver.
    func testPageHUDScrubbingChangesCurrentPage() throws {
        try open()
        try go(4)
        let before = try ui.state()
        let hud = try XCTUnwrap(ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Page 4 of 4"))
            .allElementsBoundByIndex.first { $0.frame.height <= 60 && $0.frame.width > 0 })
        let start = hud.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
        _ = try ui.waitForState { $0.page != before.page }
        _ = try page(1)
        XCTAssertEqual(try ui.state().pageCount, 4)
    }

    // canvas.scrub: horizontal layout also has a separate right-edge thumb.
    func testHorizontalPageScrubberDragsToLastPageAndBackWithoutInk() throws {
        try open()
        try setDirection("Horizontal")
        try go(1)
        let before = try ui.state()
        let scrubber = try require("Page scrubber")
        XCTAssertEqual(scrubber.value as? String, "Page 1 of 4")
        // Four pages: the first thumb occupies the top quarter of its track.
        drag(scrubber, from: CGPoint(x: 0.5, y: 0.13), to: CGPoint(x: 0.5, y: 0.88))
        _ = try ui.waitForState { $0.page != before.page }
        eventually("Scrubber must reach the last page") { scrubber.value as? String == "Page 4 of 4" }
        _ = try page(4)
        drag(scrubber, from: CGPoint(x: 0.5, y: 0.88), to: CGPoint(x: 0.5, y: 0.13))
        let returned = try ui.waitForState { $0.page == before.page }
        XCTAssertEqual(scrubber.value as? String, "Page 1 of 4")
        unchanged(before, returned)
    }

    // canvas.pullAddPage; F006/F022
    func testPullPastNotebookEndAddsExactlyOneUndoablePage() throws {
        try pencilOnly()
        try open()
        try go(4)
        let before = try ui.state()
        // Reach the last page's bottom, then perform one deliberate overscroll beyond 64 pt.
        let paper = try page(4).frame
        if paper.maxY > ui.canvas.frame.maxY {
            let remaining = min(paper.maxY - ui.canvas.frame.maxY, ui.canvas.frame.height * 0.5)
            let start = ui.coordinate(CGPoint(x: 0.5, y: 0.8))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -remaining)),
                        withVelocity: 120, thenHoldForDuration: 0.2)
            XCTAssertEqual(try ui.state().pageCount, before.pageCount, "Reaching the end must not yet add a page")
        }
        drag(ui.canvas, from: CGPoint(x: 0.5, y: 0.85), to: CGPoint(x: 0.5, y: 0.35))
        _ = try ui.waitForState { $0.pageCount == before.pageCount + 1 && $0.undoAvailable }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.pageCount == before.pageCount && $0.redoAvailable }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.pageCount == before.pageCount + 1 }
    }

    // canvas.deviceRotation; F006
    func testRotationRetainsPageAndInkAndControlsRemainUsable() throws {
        try open()
        try ui.selectTool("pen")
        let before = try ui.state()
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.6, y: 0.65)])
        let inked = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            eventually("Canvas must resize for device orientation") {
                orientation == .portrait ? self.ui.canvas.frame.height > self.ui.canvas.frame.width
                    : self.ui.canvas.frame.width > self.ui.canvas.frame.height
            }
            unchanged(inked, try ui.state())
            let z = try ui.state().zoom
            try zoomKey("=")
            _ = try ui.waitForState { $0.zoom > z }
            try key("0") { try self.ui.waitForState { abs($0.zoom - z) < 0.01 } }
        }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
    }

    // page.rotate.canvas; F022/F006/F101
    func testRotatePageKeepsInkAndDrawingHitTestingAligned() throws {
        try open()
        let before = try ui.state()
        let original = try page().frame
        try more("Rotate Clockwise")
        eventually("Rotate Page must swap paper aspect ratio") {
            let p = self.ui.app.otherElements.matching(NSPredicate(format: "label == %@", "Page 1 of 4"))
                .allElementsBoundByIndex.first { $0.frame.height > 100 }
            return p.map { $0.frame.width > $0.frame.height } ?? false
        }
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
        try ui.selectTool("pen")
        let paper = try page()
        drag(paper, from: CGPoint(x: 0.55, y: 0.55), to: CGPoint(x: 0.65, y: 0.6))
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        try ui.tapCommand("edit.undo")
        XCTAssertEqual(try page().frame.width / page().frame.height, original.width / original.height, accuracy: 0.02)
    }

    func testRotateAllPagesChangesEveryPageAndUndoesTogether() throws {
        executionTimeAllowance = 300
        try open()
        ui.logStateStep("testRotateAllPagesChangesEveryPageAndUndoesTogether opened")
        try more("Rotate All Pages")
        ui.logStateStep("testRotateAllPagesChangesEveryPageAndUndoesTogether rotated")
        ui.recordDiagnostics("Rotate All Pages returned", includeHierarchy: false)
        for number in 1...4 {
            try go(number)
            ui.logStateStep("testRotateAllPagesChangesEveryPageAndUndoesTogether navigated page \(number)")
            let paper = try page(number).frame
            XCTAssertGreaterThan(paper.width, paper.height, "Rotate All Pages must rotate page \(number)")
        }
        try ui.tapCommand("edit.undo")
        ui.logStateStep("testRotateAllPagesChangesEveryPageAndUndoesTogether undone")
        for number in 1...4 {
            try go(number)
            ui.logStateStep("testRotateAllPagesChangesEveryPageAndUndoesTogether navigated page \(number)")
            let paper = try page(number).frame
            XCTAssertLessThan(paper.width, paper.height)
        }
    }

    // whiteboard.world; F006/F044
    func testInfiniteBoardPansBothWaysAndReturnsToAnchoredContent() throws {
        try open(whiteboard)
        let before = try ui.state()
        for end in [CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.5, y: 0.75),
                    CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.25)] {
            let offset = try ui.state().contentOffset
            try ui.twoFingerScroll(from: CGPoint(x: 0.5, y: 0.5), to: end)
            _ = try ui.waitForState { abs($0.contentOffset.x - offset.x) + abs($0.contentOffset.y - offset.y) > 20 }
        }
        try ui.pinchZoom(scale: 0.4, velocity: -1)
        let out = try ui.waitForState { $0.zoom < before.zoom }
        bounded(out, board: true)
        try tap("Fit All Content")
        let fit = try ui.waitForState { abs($0.zoom - out.zoom) > 0.01 }
        unchanged(before, fit)
        XCTAssertTrue(ui.canvas.frame.intersects(try content("Acceleration").frame), "Anchored content must survive world expansion and fit")
    }

    // whiteboard.minimap + view.zoom.in/out/fit; F044
    func testMinimapVisibilityZoomStepsLimitsAndFit() throws {
        try open(whiteboard)
        if element("Show Minimap").exists { try tap("Show Minimap") }
        _ = try require("Board overview")
        let initial = try ui.state()
        try tap("Hide Minimap")
        eventually("Hide Minimap must remove the map") { !self.element("Board overview").exists }
        try tap("Show Minimap")
        _ = try require("Board overview")
        try key("0", [.command, .option]) { try self.ui.waitForState { abs($0.zoom - 1) < 0.001 } }
        _ = try ui.waitForState { abs($0.zoom - 1) < 0.001 }
        try tap("Zoom In")
        _ = try ui.waitForState { abs($0.zoom - 1.25) < 0.001 }
        try tap("Zoom Out")
        _ = try ui.waitForState { abs($0.zoom - 1) < 0.001 }
        // F044's limits disable the visible minimap buttons. The app also exposes
        // zero-size keyboard-command elements with the same labels; those do not
        // represent the controls whose enabled state this test is verifying.
        let controls = try require("Board zoom")
        let zoomIn = controls.buttons.matching(NSPredicate(format: "label == %@", "Zoom In")).firstMatch
        let zoomOut = controls.buttons.matching(NSPredicate(format: "label == %@", "Zoom Out")).firstMatch
        XCTAssertTrue(zoomIn.exists)
        XCTAssertTrue(zoomOut.exists)
        for _ in 0..<12 {
            if !zoomIn.isEnabled { break }
            try tap("Zoom In")
            bounded(try ui.state(), board: true)
        }
        XCTAssertEqual(try ui.state().zoom, 4, accuracy: 0.001)
        XCTAssertFalse(zoomIn.isEnabled)
        for _ in 0..<16 {
            if !zoomOut.isEnabled { break }
            try tap("Zoom Out")
            bounded(try ui.state(), board: true)
        }
        XCTAssertEqual(try ui.state().zoom, 0.05, accuracy: 0.001)
        XCTAssertFalse(zoomOut.isEnabled)
        try tap("Fit All Content")
        let fit = try ui.waitForState { $0.zoom > 0.05 }
        bounded(fit, board: true)
        unchanged(initial, fit)
        for label in ["Acceleration", "Velocity changes over time"] {
            let item = try content(label)
            XCTAssertTrue(ui.canvas.frame.contains(item.frame), "Fit must reveal all of \(label)")
        }
    }

    // whiteboard.minimapNavigate; F044
    func testMinimapTapAndViewportDragPanTheCanvas() throws {
        try open(whiteboard)
        if element("Show Minimap").exists { try tap("Show Minimap") }
        let map = try require("Board overview")
        try tap("Fit All Content")
        let before = try ui.state()
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        let tapped = try ui.waitForState { abs($0.contentOffset.x - before.contentOffset.x) + abs($0.contentOffset.y - before.contentOffset.y) > 10 }
        XCTAssertGreaterThan(tapped.contentOffset.x, before.contentOffset.x, "Tap on the right of the map must move right")
        XCTAssertLessThan(tapped.contentOffset.y, before.contentOffset.y, "Tap above the map centre must move up")
        drag(map, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.25, y: 0.75))
        let dragged = try ui.waitForState { abs($0.contentOffset.x - tapped.contentOffset.x) + abs($0.contentOffset.y - tapped.contentOffset.y) > 10 }
        XCTAssertLessThan(dragged.contentOffset.x, tapped.contentOffset.x, "Viewport must follow the drag left")
        XCTAssertGreaterThan(dragged.contentOffset.y, tapped.contentOffset.y, "Viewport must follow the drag down")
        unchanged(before, dragged)
        map.doubleTap()
        _ = try ui.waitForState { abs($0.contentOffset.x - dragged.contentOffset.x) + abs($0.contentOffset.y - dragged.contentOffset.y) > 10 }
    }

    // board.add; F044 (both entry points)
    func testAddBoardFromMenuAndBoardsPlusActivatesNewBoard() throws {
        try open(whiteboard)
        let before = try ui.state()
        // Add Page can be folded into More at the current toolbar width.
        if element("menu.addPage").exists { try tap("menu.addPage") }
        else { try tap("menu.more") }
        try tap("Add Board")
        let added = try ui.waitForState { $0.pageCount == before.pageCount + 1 && $0.page != before.page }
        XCTAssertEqual(added.itemCountOnPage, 0)
        try boards()
        try tap("Add Board")
        _ = try ui.waitForState { $0.pageCount == added.pageCount + 1 && $0.page != added.page }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.pageCount == added.pageCount }
    }

    // board.rename; F044
    func testBoardRenamePersistsAfterReopeningDocument() throws {
        executionTimeAllowance = 300
        try open(whiteboard)
        try boards()
        let row = try boardRow(1, count: 1)
        try openBoardMenu(row)
        try boardMenuTap("Rename")
        let field = try require("Board name")
        try ui.replaceNativeText(in: field, with: "Canvas navigation board")
        try ui.typeNativeText("\n", in: field)
        _ = try require("Canvas navigation board")
        try ui.tapCommand("window.showLibrary")
        try open(whiteboard)
        if !ui.app.buttons.matching(NSPredicate(format: "value == %@", "Board 1 of 1")).firstMatch.exists {
            try boards()
        }
        let renamed = try boardRow(1, count: 1)
        XCTAssertEqual(renamed.label, "Canvas navigation board")
        renamed.tap()
        XCTAssertEqual(try ui.state().pageCount, 1)
        XCTAssertEqual(try ui.state().itemCountOnPage, 3)
    }

    // board.insertTemplate; F044. Separate tests keep one missing framework from hiding the other seven.
    private func framework(_ title: String) throws {
        try open(whiteboard)
        let before = try ui.state()
        try boards()
        try tap("Templates")
        // performTap reveals the requested row in its live container, including virtualized templates.
        try tap(title)
        let inserted = try ui.waitForState { $0.itemCountOnPage > before.itemCountOnPage && $0.undoAvailable }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage && $0.redoAvailable }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.itemCountOnPage == inserted.itemCountOnPage }
        // Frameworks must remain editable objects, not a flattened preview bitmap.
        try ui.tapCommand("sidebar.toggle")
        try ui.selectTool("lasso")
        try key("a") { try self.ui.waitForState { $0.selectionCount == inserted.itemCountOnPage } }
        _ = try ui.waitForState { $0.selectionCount == inserted.itemCountOnPage }
        try key(XCUIKeyboardKey.delete.rawValue, []) { try self.ui.waitForState { $0.itemCountOnPage == 0 } }
        _ = try ui.waitForState { $0.itemCountOnPage == 0 }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.itemCountOnPage == inserted.itemCountOnPage }
    }

    func testBoardFrameworkBrainstorm() throws { try framework("Brainstorm") }
    func testBoardFrameworkKanban() throws { try framework("Kanban") }
    func testBoardFrameworkSWOT() throws { try framework("SWOT Analysis") }
    func testBoardFrameworkRetrospective() throws { try framework("Retrospective") }
    func testBoardFrameworkMindMap() throws { try framework("Mind Map") }
    func testBoardFrameworkTimeline() throws { try framework("Timeline") }
    func testBoardFrameworkMeeting() throws { try framework("Meeting Notes") }
    func testBoardFrameworkFlowchart() throws { try framework("Flowchart") }

    // doc.convertToWhiteboard; F044
    func testLibraryConversionPreservesNotebookContentOnOneBoard() throws {
        try open()
        let before = try ui.state()
        try ui.tapCommand("window.showLibrary")
        let document = ui.app.descendants(matching: .any).matching(identifier: "cmd.doc.open")
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", notebook, notebook + ",")).firstMatch
        document.press(forDuration: 1)
        try tap("Convert to Whiteboard")
        try open()
        let converted = try ui.waitForState { $0.pageCount == 1 }
        XCTAssertGreaterThanOrEqual(converted.itemCountOnPage, before.itemCountOnPage, "Conversion must preserve page assets and content")
        XCTAssertEqual(converted.strokeCountOnPage, before.strokeCountOnPage)
        try tap("Fit All Content")
        ui.recordDiagnostics("Converted notebook canvas exposure", facts: "Expected preserved text: Motion and forces; inspect label/value and text geometry independently of conversion counts")
        _ = try content("Motion and forces")
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.pageCount == 4 }
    }

    // zoom.toggle; F038 (keyboard, palette, close button, page menu)
    func testZoomWindowToggleDoesNotEditDocument() throws {
        try open()
        let before = try ui.state()
        try key("z", [.command, .option]) { _ = try self.require("Zoom Window writing area") }
        try tap("Close Zoom Window")
        eventually("Close must remove the writing pane") { !self.element("Zoom Window writing area").exists }
        try tap("tool.more")
        try tap("cmd.zoom.toggle")
        _ = try require("Zoom box")
        try key("z", [.command, .option]) { self.eventually("Shortcut closes Zoom box") { !self.element("Zoom box").exists } }
        eventually("Shortcut must close the target box") { !self.element("Zoom box").exists }
        ui.coordinate(CGPoint(x: 0.5, y: 0.6)).press(forDuration: 1)
        try tap("Zoom")
        _ = try require("Zoom Window writing area")
        unchanged(before, try ui.state())
    }

    // zoom.setBox; F038
    func testZoomBoxMoveResizeAndMarginHandles() throws {
        try zoomWindow()
        let initial = try ui.state()
        let box = try require("Zoom box")
        let before = try boxRect()
        let centre = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(CGVector(dx: 55, dy: 20)))
        let moved = try boxRect()
        XCTAssertGreaterThan(moved.minX, before.minX + 10)
        let corner = box.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -35, dy: -12)))
        let resized = try boxRect()
        XCTAssertLessThan(resized.width, moved.width - 5)
        XCTAssertEqual(resized.width / resized.height, moved.width / moved.height, accuracy: 0.1)
        let bottom = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
        bottom.press(forDuration: 0.1, thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: 25)))
        XCTAssertGreaterThan(try boxRect().height, resized.height + 5)
        for label in ["Left margin", "Right margin"] {
            let marker = try require(label)
            let value = marker.value as? String
            let start = marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: label == "Left margin" ? 30 : -30, dy: 0)))
            eventually("\(label) must move") { marker.value as? String != value }
        }
        unchanged(initial, try ui.state())
    }

    // zoom.scale; F038
    func testWritingPaneMagnificationIsIndependentOfDocumentZoom() throws {
        try zoomWindow()
        let before = try ui.state()
        let box = try boxRect()
        let slider = ui.app.sliders.matching(NSPredicate(format: "label == %@", "Zoom")).firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let value = slider.value as? String
        // NibSlider uses an accessibilityRepresentation of Slider; XCTest's native
        // adjust API receives zero scrubber endpoints. Drag the real visible track.
        drag(slider, from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.8, y: 0.5))
        eventually("Pane zoom slider must change magnification") { slider.value as? String != value }
        XCTAssertLessThan(try boxRect().width, box.width)
        XCTAssertEqual(try ui.state().zoom, before.zoom, accuracy: 0.001)
        unchanged(before, try ui.state())
    }

    // zoom.newLine; F038
    func testZoomNewLineButtonAndOptionReturnAdvanceToLeftMargin() throws {
        try zoomWindow()
        let before = try boxRect()
        try tap("New Line")
        let next = try boxRect()
        XCTAssertGreaterThan(next.minY, before.minY)
        XCTAssertEqual(next.minX, before.minX, accuracy: 2)
        try key(XCUIKeyboardKey.return.rawValue, .option) {
            self.eventually("Option-Return advances writing line") { (self.boxRectNow()?.minY ?? next.minY) > next.minY }
        }
        let keyboardNext = try boxRect()
        XCTAssertEqual(keyboardNext.minY - next.minY, next.minY - before.minY, accuracy: 2)
        XCTAssertEqual(keyboardNext.minX, next.minX, accuracy: 2)
        XCTAssertFalse(try ui.state().undoAvailable, "New Line is navigation")
    }

    // zoom.setReturnHeight + zoom.returnPresets; F038
    func testReturnHeightPresetsIncreaseDecreaseAndPageSpecificPersistence() throws {
        executionTimeAllowance = 300
        try zoomWindow()
        try option("Match Zoom Box")
        let before = try boxRect()
        try tap("New Line")
        let first = try boxRect()
        XCTAssertEqual(first.minY - before.minY, before.height, accuracy: 2)
        try option("Increase Return Height")
        try tap("New Line")
        let increased = try boxRect()
        XCTAssertEqual(increased.minY - first.minY, before.height + 2, accuracy: 1)
        try option("Decrease Return Height")
        try tap("New Line")
        XCTAssertEqual(try boxRect().minY - increased.minY, before.height, accuracy: 1)
        try tap("Close Zoom Window")
        try go(2)
        try showZoomWindow()
        try option("Match Template")
        // Read the advertised template height, then check the actual movement in page coordinates.
        try tap("Zoom Window options")
        let heightLabel = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Return height:")).firstMatch
        XCTAssertTrue(heightLabel.waitForExistence(timeout: 5))
        let words = heightLabel.label.split(separator: " ")
        let templateHeight = try XCTUnwrap(words.compactMap { Double($0) }.first)
        try key(XCUIKeyboardKey.escape.rawValue, []) {
            self.eventually("Escape must dismiss the return-height options") { !heightLabel.exists }
        }
        let paper2 = try page(2).frame
        let secondBox = try require("Zoom box").frame
        let scale2 = try ui.state().zoom
        let y2 = (secondBox.minY - paper2.minY) / scale2
        try tap("New Line")
        let newY2 = (try require("Zoom box").frame.minY - page(2).frame.minY) / scale2
        XCTAssertEqual(newY2 - y2, templateHeight, accuracy: 1, "Match Template must use its advertised return height")
        try option("Increase Return Height")
        try option("Increase Return Height")
        try tap("Close Zoom Window")
        try go(1)
        try showZoomWindow()
        let reopened = try boxRect()
        try tap("New Line")
        XCTAssertEqual(try boxRect().minY - reopened.minY, before.height, accuracy: 2, "Return height belongs to its page")
    }

    func testSetLeftRightMarginsAndResetMarginsAffectNewLine() throws {
        try zoomWindow()
        let left = try require("Left margin")
        let right = try require("Right margin")
        let defaultLeft = left.value as? String
        let defaultRight = right.value as? String
        let box = try require("Zoom box")
        let start = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 50, dy: 0)))
        let moved = try boxRect()
        try option("Set Left Margin at Zoom Box")
        XCTAssertNotEqual(left.value as? String, defaultLeft)
        try option("Set Right Margin at Zoom Box")
        XCTAssertNotEqual(right.value as? String, defaultRight)
        try tap("New Line")
        XCTAssertEqual(try boxRect().minX, moved.minX, accuracy: 2)
        try option("Reset Margins")
        XCTAssertEqual(left.value as? String, defaultLeft)
        XCTAssertEqual(right.value as? String, defaultRight)
        try tap("New Line")
        XCTAssertLessThan(try boxRect().minX, moved.minX - 10)
    }

    // zoom.setReturnHeight is a page edit: its effect must also follow undo and redo.
    func testReturnHeightChangeUndoRedoRestoresNewLineDistance() throws {
        try zoomWindow()
        let initial = try ui.state()
        let first = try boxRect()
        try tap("New Line")
        let second = try boxRect()
        let defaultHeight = second.minY - first.minY
        XCTAssertGreaterThan(defaultHeight, 0)
        try option("Increase Return Height")
        _ = try ui.waitForState { $0.undoAvailable }
        try tap("New Line")
        let increased = try boxRect()
        XCTAssertEqual(increased.minY - second.minY, defaultHeight + 2, accuracy: 1)
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.redoAvailable }
        try tap("New Line")
        let undone = try boxRect()
        XCTAssertEqual(undone.minY - increased.minY, defaultHeight, accuracy: 1)
        try ui.tapCommand("edit.redo")
        try tap("New Line")
        XCTAssertEqual(try boxRect().minY - undone.minY, defaultHeight + 2, accuracy: 1)
        XCTAssertEqual(try ui.state().strokeCountOnPage, initial.strokeCountOnPage)
        XCTAssertEqual(try ui.state().itemCountOnPage, initial.itemCountOnPage)
    }

    // zoom.write: verify the page-space mapping, not only a count in the pane.
    func testPaneInkCanBeErasedAtTheCorrespondingMainPagePosition() throws {
        try zoomWindow()
        try ui.selectTool("pen")
        let before = try ui.state()
        let box = try boxRect()
        let pane = try require("Zoom Window writing area").frame
        let magnification = pane.width / box.width
        let start = CGPoint(x: 0.2, y: 0.45)
        let end = CGPoint(x: 0.4, y: 0.45)
        try paneStroke(from: start, to: end)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try tap("Close Zoom Window")
        try ui.selectTool("eraser")
        let paper = try page()
        let scale = try ui.state().zoom
        func mapped(_ point: CGPoint) -> XCUICoordinate {
            paper.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: (box.minX + point.x * pane.width / magnification) * scale,
                dy: (box.minY + point.y * pane.height / magnification) * scale))
        }
        mapped(start).press(forDuration: 0.01, thenDragTo: mapped(end),
                            withVelocity: 180, thenHoldForDuration: 0)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    // zoom.autoAdvance; F038
    func testAutoAdvanceInkMovesThenWrapsTheTarget() throws {
        try zoomWindow()
        try ui.selectTool("pen")
        // Exercise the toggle twice: default fixture setting is enabled.
        try option("Auto-Advance")
        let before = try boxRect()
        let initial = try ui.state()
        try paneStroke(from: CGPoint(x: 0.55, y: 0.45), to: CGPoint(x: 0.9, y: 0.5))
        _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage + 1 }
        XCTAssertEqual(try boxRect().minX, before.minX, accuracy: 1)
        try option("Auto-Advance")
        for index in 0..<4 {
            // F038 arms on a stroke past the middle; a subsequent stroke in the right quarter advances.
            let currentBox = try boxRect()
            try paneStroke(from: CGPoint(x: 0.45, y: 0.4), to: CGPoint(x: 0.6, y: 0.45))
            _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage + 2 + index * 2 }
            XCTAssertEqual(try boxRect().minX, currentBox.minX, accuracy: 1)
            try paneStroke(from: CGPoint(x: 0.8, y: 0.45), to: CGPoint(x: 0.9, y: 0.5))
            _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage + 3 + index * 2 }
            let current = try boxRect()
            if current.minY > before.minY + 1 {
                XCTAssertEqual(current.minX, before.minX, accuracy: 2)
                return
            }
            XCTAssertGreaterThan(current.minX, before.minX, "Advance-zone ink must move the box")
        }
        XCTFail("Auto-advance must wrap at the right margin within four half-box advances")
    }

    // zoom.write; F038/F010. Full eraser crossing removes this entire short stroke in every eraser mode.
    func testWritingAndErasingInZoomPaneChangesMainPageAndUndoes() throws {
        try zoomWindow()
        try ui.selectTool("pen")
        let before = try ui.state()
        try paneStroke()
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 && $0.undoAvailable }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage && $0.redoAvailable }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try ui.selectTool("eraser")
        try paneStroke()
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try tap("Close Zoom Window")
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage + 1)
    }

    // canvas.renderRecovery; shared fixture prerequisite, F006 owns recovery UI.
    func testFailedPageTryAgainReloadsWithoutLosingInk() throws {
        try open()
        let before = try ui.state()
        _ = try require("Try Again")
        XCTAssertEqual(try ui.state().renderFailureCount, 1)
        try tap("Try Again")
        eventually("Try Again must clear the failed-page state") { !self.element("Try Again").exists }
        unchanged(before, try ui.state())
        try zoomKey("=")
        _ = try ui.waitForState { $0.zoom > before.zoom }
    }

    func testFailedPageRestoreOpensBackupFlow() throws {
        try open()
        _ = try require("Restore from Backup")
        XCTAssertEqual(try ui.state().renderFailureCount, 1)
        let before = try ui.state()
        try tap("Restore from Backup")
        _ = try ui.waitForState { $0.openPanels != before.openPanels }
        _ = try require("Cloud & Backup")
        XCTAssertEqual(try ui.state().pageCount, before.pageCount)
    }

    // canvas.largeDocument; F006/F100. Fixture delivers a UIKit memory warning, not OS jetsam.
    func testLargeDocumentMemoryRecoveryRequiresStressFixture() throws {
        try open()
        let before = try ui.state()
        XCTAssertGreaterThanOrEqual(before.pageCount, 300)
        try ui.selectTool("pen")
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.62), CGPoint(x: 0.6, y: 0.67)])
        let inked = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try go(4)
        let away = try ui.state()
        let warnings = try XCTUnwrap(away.memoryWarningCount)
        let purges = try XCTUnwrap(away.rendererCachePurgeCount)
        XCUIDevice.shared.press(.home)
        ui.app.activate()
        _ = try ui.waitForState {
            ($0.memoryWarningCount ?? 0) > warnings && ($0.rendererCachePurgeCount ?? 0) > purges
        }
        try go(1)
        unchanged(inked, try ui.state())
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage && $0.redoAvailable }
    }

    // whiteboard.boardActions; F044
    func testBoardSelectionSelectAllAndCancelPreserveScope() throws {
        try open(whiteboard)
        try boards()
        try tap("Add Board")
        _ = try ui.waitForState { $0.pageCount == 2 }
        let before = try ui.state()
        try tap("Select")
        try tap("Board 1")
        _ = try require("1 board selected")
        try tap("Move to Whiteboard")
        _ = try require("New Whiteboard")
        try tap("Cancel")
        XCTAssertEqual(try ui.state().pageCount, 2)
        try tap("Select All")
        _ = try require("2 boards selected")
        XCTAssertFalse(element("Move to Trash").isEnabled, "The last board cannot be removed")
        try tap("Done")
        unchanged(before, try ui.state())
    }

    func testBoardDuplicateAndTrashOnlyChosenBoard() throws {
        try open(whiteboard)
        let original = try ui.state()
        try boards()
        try openBoardMenu(boardRow(1, count: 1))
        try boardMenuTap("Duplicate")
        _ = try ui.waitForState { $0.pageCount == 2 }
        // Duplicate preserves a board's title, so identify its position rather than inventing a new name.
        try boardRow(2, count: 2).tap()
        XCTAssertEqual(try ui.state().itemCountOnPage, original.itemCountOnPage)
        try openBoardMenu(boardRow(2, count: 2))
        try boardMenuTap("Move to Trash")
        _ = try ui.waitForState { $0.pageCount == 1 }
        XCTAssertEqual(try ui.state().page, original.page)
        XCTAssertEqual(try ui.state().itemCountOnPage, original.itemCountOnPage)
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState { $0.pageCount == 2 }
    }

    func testBoardExportSelectionAndCancelPreserveBoards() throws {
        try open(whiteboard)
        try boards()
        try tap("Add Board")
        _ = try ui.waitForState { $0.pageCount == 2 }
        try tap("Select")
        try tap("Board 1")
        let before = try ui.state()
        try tap("Export")
        let export = ui.app.alerts["Share & Export"].firstMatch
        let close = export.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "xmark", "Close")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 8), "Share & Export must expose its scoped Close control")
        for (title, value) in [("Board 1", "Selected"), ("Board 2", "Not selected")] {
            let choice = ui.app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", title, value)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "Export must honor board scope: \(title) \(value)")
        }
        XCTAssertTrue(close.isEnabled && close.isHittable)
        close.tap()
        // The floating host can retain a dismissed panel's accessibility representation.
        // Cancellation promises dismissal, not deallocation of that representation.
        eventually("Cancel must close export options") {
            !close.exists || !close.isHittable
        }
        unchanged(before, try ui.state())
    }

    func testBoardMoveToNewWhiteboardHonorsSelection() throws {
        try open(whiteboard)
        try boards()
        try tap("Add Board")
        _ = try ui.waitForState { $0.pageCount == 2 }
        try tap("Select")
        try tap("Board 1")
        try tap("Move to Whiteboard")
        try tap("New Whiteboard")
        _ = try ui.waitForState { $0.pageCount == 1 }
        XCTAssertEqual(try ui.state().itemCountOnPage, 0, "Only the selected populated board moves; blank Board 2 remains")
        try ui.tapCommand("window.showLibrary")
        try open("Untitled Whiteboard")
        XCTAssertEqual(try ui.state().itemCountOnPage, 3, "Moved board must retain its three fixture items")
    }

    // Run the scene-creation case last: terminating an iPad app does not discard its OS scene sessions.
    func testZZBoardOpenInNewWindowRetainsChosenBoard() throws {
        try open(whiteboard)
        let before = try ui.state()
        try boards()
        try openBoardMenu(boardRow(1, count: 1))
        try boardMenuTap("Open in New Window")
        eventually("Open in New Window must create a second app window") { self.ui.app.windows.count > 1 }
        // Checking the original window alone would falsely pass when the new scene opens an empty library.
        // F018's SceneHooksImpl currently drops requested activities in NibUITestMode: a fixture-mode limitation.
        eventually("Both window probes must show the chosen board; the fixture must not discard the new scene's requested document/page") {
            let states = self.ui.app.descendants(matching: .any).matching(identifier: "nib.qa.state")
                .allElementsBoundByIndex.compactMap { probe -> QAState? in
                    guard let value = probe.value as? String else { return nil }
                    return try? JSONDecoder().decode(QAState.self, from: Data(value.utf8))
                }
            return states.filter { $0.document == before.document && $0.page == before.page }.count >= 2
        }
    }

    func testBoardMarkSeenPreservesContentAndAcknowledgesAction() throws {
        try open(whiteboard)
        try boards()
        let before = try ui.state()
        let unseen = try XCTUnwrap(before.unseenFixturePages)
        XCTAssertEqual(unseen.count, 2, "Offscreen remote boards must start unseen")
        let receipts = try XCTUnwrap(before.boardReadReceipts)
        try tap("Select")
        try tap("Board 2")
        _ = try require("1 board selected")
        try tap("Mark as Seen")
        let marked = try ui.waitForState { $0.unseenFixturePages?.count == 1 }
        unchanged(before, marked)
        let remaining = try XCTUnwrap(marked.unseenFixturePages?.first)
        XCTAssertEqual(remaining, unseen[1], "Board 3 must remain unseen when only Board 2 is selected")
        let acknowledged = unseen[0]
        XCTAssertNotNil(marked.boardReadReceipts?[acknowledged] ?? nil)
        XCTAssertNotEqual(marked.boardReadReceipts?[acknowledged] ?? nil, receipts[acknowledged] ?? nil)
        XCTAssertEqual(marked.boardReadReceipts?[remaining] ?? nil, receipts[remaining] ?? nil)
        try tap("Select All")
        try tap("Mark as Seen")
        let allSeen = try ui.waitForState { $0.unseenFixturePages?.isEmpty == true }
        unchanged(before, allSeen)
        XCTAssertNotNil(allSeen.boardReadReceipts?[remaining] ?? nil)
        XCTAssertNotEqual(allSeen.boardReadReceipts?[remaining] ?? nil, receipts[remaining] ?? nil)
    }
}
