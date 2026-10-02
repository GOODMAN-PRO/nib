import XCTest

struct QAState: Decodable {
    struct Offset: Decodable { let x: Double; let y: Double }
    struct Dock: Decodable { let edge: String; let along: Double }
    let screen: String
    let document: String?
    let page: String?
    let pageCount: Int
    let tool: String
    let zoom: Double
    let contentOffset: Offset
    let itemCountOnPage: Int
    let strokeCountOnPage: Int
    let selectionCount: Int
    let undoAvailable: Bool
    let redoAvailable: Bool
    let openPanels: [String]
    let paletteDock: Dock?
    let fixtureError: String?
    let fixtureScenario: String?
    let boardReadReceipts: [String: String?]?
    let boardSeenBaseline: String?
    let unseenFixturePages: [String]?
    let renderFailureCount: Int?
    let rendererCachePurgeCount: Int?
    let memoryWarningCount: Int?
    let cachedPageCount: Int?
    let clipboardChangeCount: Int?
}

/// All coordinates are normalized to the real canvas viewport, not the whole device screen.
@MainActor
final class NibUI {
    let app = XCUIApplication()
    var probe: XCUIElement { app.descendants(matching: .any)["nib.qa.state"].firstMatch }
    var canvas: XCUIElement { app.scrollViews["nib.canvas"].firstMatch }

    /// Explicit prerequisites; no test-name detection and no changes to the standard fixture.
    enum FixtureScenario: String { case standard, failedRender, largeDocument, unseenBoards }

    func revealFormElement(_ element: XCUIElement) {
        if !element.exists { _ = app.collectionViews.firstMatch.waitForExistence(timeout: 2) }
        for _ in 0..<24 {
            guard let list = app.collectionViews.allElementsBoundByIndex.last, list.isHittable else { return }
            // Include the shortcuts bar: it is above the Keyboard accessibility frame.
            let obstructions = app.keyboards.allElementsBoundByIndex.map(\.frame)
                + app.otherElements.matching(identifier: "inputAssistantView").allElementsBoundByIndex.map(\.frame)
            guard let viewport = NibUITestScrollGeometry.viewport(
                scroll: list.frame, window: app.frame, obstructions: obstructions) else { return }
            if element.exists && element.isHittable {
                let belongsToList = list.descendants(matching: element.elementType)
                    .matching(NSPredicate(format: "label == %@", element.label)).count > 0
                if !belongsToList || viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            }
            let drag = NibUITestScrollGeometry.drag(in: viewport, toward: element.exists ? element.frame.midY : nil)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: drag.start.x - app.frame.minX, dy: drag.start.y - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: drag.end.x - app.frame.minX, dy: drag.end.y - app.frame.minY))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
    }

    /// Complete Files' New Folder action using the editor supplied by the OS.
    /// iOS 26 uses an inline text view and Done; older pickers use an alert and Create.
    func nameNewFilesFolder(_ title: String) throws {
        let inline = app.textViews["DOC.inlineRenameField"]
        let alertField = app.alerts.textFields.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            inline.isHittable || alertField.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed else {
            throw Failure.message("Files must expose its new-folder name editor")
        }
        let usesInlineEditor = inline.isHittable
        let field = usesInlineEditor ? inline : alertField
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        if usesInlineEditor {
            field.typeText("\n")
        } else {
            let create = app.alerts.buttons["Create"]
            guard create.isHittable && create.isEnabled else { throw Failure.message("Files Create must be available") }
            create.tap()
        }
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !field.exists }, object: nil)
        guard XCTWaiter.wait(for: [finished], timeout: 12) == .completed else {
            throw Failure.message("Files must finish naming the new folder")
        }
    }

    func launchFixture(scenario: FixtureScenario = .standard) throws {
        app.launchArguments = ["-NibUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-NibUITestScenario", scenario.rawValue]
        app.launch()
        _ = try waitForState { $0.screen == "library" }
        // Rotate only the running app, not SpringBoard or a previous test's system service. Repeated portrait
        // resets add an unrelated orientation-confirmation race before Nib even launches.
        if XCUIDevice.shared.orientation != .landscapeLeft { XCUIDevice.shared.orientation = .landscapeLeft }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        guard XCTWaiter.wait(for: [landscape], timeout: 15) == .completed else {
            throw Failure.message("Nib's launched scene did not reach landscape")
        }
        _ = try waitForState { $0.screen == "library" }
    }

    func state() throws -> QAState {
        if let state = try readState() { return state }
        return try waitForState(timeout: 10) { _ in true }
    }

    private func readState() throws -> QAState? {
        guard probe.exists,
              let state = try NibUITestSnapshot.decode(probe.value, as: QAState.self) else { return nil }
        if let failure = state.fixtureError { throw Failure.message("Fixture failed: \(failure)") }
        return state
    }

    @discardableResult
    func waitForState(timeout: TimeInterval = 30, _ matches: @escaping (QAState) -> Bool) throws -> QAState {
        var latest: QAState?
        var error: Error?
        let predicate = NSPredicate { [self] _, _ in
            do {
                // Do not assert inside the polling loop: XCTest can omit an element/value for one snapshot even
                // after waitForExistence succeeded. Decode only fresh values and keep the original deadline.
                guard let state = try readState() else { return false }
                latest = state
                return matches(state)
            }
            catch let caught { error = caught; return true }
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        if let error { throw error }
        guard result == .completed, let latest else {
            throw Failure.message("State did not converge (missing or unmatched nib.qa.state): \(String(describing: latest))\n\(app.debugDescription)")
        }
        return latest
    }

    func openDocument(_ title: String) throws {
        let document = app.descendants(matching: .any).matching(identifier: "cmd.doc.open")
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        guard document.waitForExistence(timeout: 15) else { throw Failure.message("Document missing: \(title); state: \(String(describing: probe.value))\n\(app.debugDescription)") }
        let button = document.buttons.firstMatch
        let target = button.exists ? button : document
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: target)
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else { throw Failure.message("Document is not hittable: \(title)") }
        target.tap()
        _ = try waitForState { $0.screen == "document" && $0.document != nil }
    }

    func tapCommand(_ id: String) throws {
        try tapControl("cmd." + id, overflow: ["menu.more", "tool.more"])
    }

    /// Uses the real Copy control and reads its actual pasteboard output in the writing app. A background runner's
    /// UIPasteboard.data read can be denied or stall indefinitely; clipboard contents are not a session-state proxy.
    func copyFragment() throws -> Data {
        struct Snapshot: Decodable {
            let changeCount: Int
            let fragment: Data?
        }
        let before = try XCTUnwrap(state().clipboardChangeCount, "Missing clipboard revision")
        try tapCommand("clipboard.copy")
        _ = try waitForState(timeout: 8) { ($0.clipboardChangeCount ?? before) > before }
        let probe = app.descendants(matching: .any)["nib.qa.clipboard"].firstMatch
        let value = try XCTUnwrap(probe.value as? String, "Missing copied-fragment probe")
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(value.utf8))
        guard snapshot.changeCount > before, let fragment = snapshot.fragment else {
            throw Failure.message("Copy must export a fresh app.nib.fragment")
        }
        return fragment
    }

    func selectTool(_ id: String) throws {
        // Tapping an already selected tool opens its settings, so select only when needed.
        if try state().tool != id { try tapControl("tool." + id, overflow: ["tool.more"]) }
        _ = try waitForState { $0.tool == id }
    }

    private func tapControl(_ id: String, overflow: [String]) throws {
        func candidate(_ identifier: String) -> XCUIElement? {
            app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
                .first { $0.isHittable && $0.isEnabled }
        }
        if let control = candidate(id) { control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); return }
        for identifier in overflow {
            if let menu = candidate(identifier) {
                menu.tap()
                if let control = candidate(id) { control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); return }
                if menu.isHittable { menu.tap() }
            }
        }
        throw Failure.message("No enabled control \(id)\n\(app.debugDescription)")
    }

    func coordinate(_ point: CGPoint) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: point.x, dy: point.y))
    }

    /// Two points use the public coordinate press-and-drag API. Longer polylines keep one finger down using
    /// XCTest's event synthesizer (test runner only); no commands or app-side gesture injection are used.
    func drawStroke(_ path: [CGPoint], duration: TimeInterval = 0.35) throws {
        guard path.count >= 2 else { throw Failure.message("A stroke needs at least two points") }
        if path.count == 2 {
            let start = coordinate(path[0]), end = coordinate(path[1])
            let distance = hypot(end.screenPoint.x - start.screenPoint.x, end.screenPoint.y - start.screenPoint.y)
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: distance / duration), thenHoldForDuration: 0)
        } else {
            try synthesize([path], duration: duration)
        }
    }

    /// Start on the canvas desk by default, clear of PencilKit and the floating controls.
    /// Pass a paper coordinate to exercise navigation through a particular tool's input surface.
    func pinchZoom(scale: CGFloat, velocity: CGFloat = 1, at centre: CGPoint = CGPoint(x: 0.18, y: 0.65)) throws {
        guard scale > 0, velocity != 0 else { throw Failure.message("Pinch needs a positive scale and nonzero velocity") }
        let radius: CGFloat = min(0.055, 0.055 / scale)
        let duration = min(2, max(0.25, Double(abs(scale - 1) / abs(velocity))))
        let paths = [CGFloat(-1), CGFloat(1)].map { direction in
            [CGPoint(x: centre.x + direction * radius, y: centre.y),
             CGPoint(x: centre.x + direction * radius * scale, y: centre.y)]
        }
        try synthesize(paths, duration: duration)
    }
    func doubleTap(at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) { coordinate(point).doubleTap() }

    func twoFingerScroll(from: CGPoint, to: CGPoint, duration: TimeInterval = 0.4) throws {
        let spacing = min(0.035, 24 / canvas.frame.width)
        try synthesize([[CGPoint(x: from.x - spacing, y: from.y), CGPoint(x: to.x - spacing, y: to.y)],
                        [CGPoint(x: from.x + spacing, y: from.y), CGPoint(x: to.x + spacing, y: to.y)]], duration: duration)
    }

    private func synthesize(_ paths: [[CGPoint]], duration: TimeInterval) throws {
        let points = paths.map { $0.map { NSValue(cgPoint: coordinate($0).screenPoint) } }
        let done = XCTestExpectation(description: "Touch path completed")
        var failure: Error?
        NibTouchPaths.perform(points, duration: duration) { error in failure = error; done.fulfill() }
        guard XCTWaiter.wait(for: [done], timeout: duration + 15) == .completed else { throw Failure.message("Gesture synthesis timed out") }
        if let failure { throw failure }
    }

    func dismissSheets() throws {
        for _ in 0..<8 {
            if let close = ["sheet.dismiss", "cmd.panel.close", "Cancel", "Done", "Close"].compactMap({ id in
                app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
            }).first { close.tap(); continue }
            if let sheet = app.sheets.allElementsBoundByIndex.first {
                sheet.swipeDown(); continue
            }
            return
        }
        throw Failure.message("Sheet did not dismiss\n\(app.debugDescription)")
    }

    enum Failure: Error { case message(String) }
}

/// Drives Calendar's real event editor. EventKit injection would bypass the UI-only
/// fixture contract; an unlabeled toolbar symbol must not prevent ordinary input.
@MainActor
extension NibUI {
    static func openCalendarEvent(in calendar: XCUIApplication) throws {
        let title = calendar.textFields["Title"]
        let add = calendar.buttons.matching(NSPredicate(
            format: "label IN {'Add', 'Add Event', 'New Event', 'Create Event', 'Create'}")).firstMatch
        if add.waitForExistence(timeout: 3), add.isHittable {
            add.tap()
        }
        if title.waitForExistence(timeout: 3) { return }

        // Calendar's New Event keyboard command also reaches the native editor when
        // iPadOS omits the visible + symbol's accessibility label. Unlike a screen
        // coordinate this remains valid across orientation and toolbar layouts.
        calendar.typeKey("n", modifierFlags: [.command])
        guard title.waitForExistence(timeout: 5), title.isHittable else {
            throw NibUI.Failure.message("Calendar did not open its New Event editor through Add or Command-N\n"
                                        + calendar.debugDescription)
        }
    }
}
