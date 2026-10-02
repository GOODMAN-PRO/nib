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

    func launchFixture(scenario: FixtureScenario = .standard) throws {
        app.launchArguments = ["-NibUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-NibUITestScenario", scenario.rawValue]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        _ = try waitForState { $0.screen == "library" }
        // Rotate the launched scene, so SwiftUI publishes its populated landscape accessibility layout.
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func state() throws -> QAState {
        let value = try XCTUnwrap(probe.value as? String, "Missing nib.qa.state; launch with -NibUITestFixture")
        let state = try JSONDecoder().decode(QAState.self, from: Data(value.utf8))
        if let error = state.fixtureError { throw Failure.message("Fixture failed: \(error)") }
        return state
    }

    @discardableResult
    func waitForState(timeout: TimeInterval = 30, _ matches: @escaping (QAState) -> Bool) throws -> QAState {
        guard probe.waitForExistence(timeout: timeout) else { throw Failure.message("QA probe missing\n\(app.debugDescription)") }
        var latest: QAState?
        var error: Error?
        let predicate = NSPredicate { [self] _, _ in
            do { latest = try state(); return matches(latest!) }
            catch let caught { error = caught; return true }
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        if let error { throw error }
        guard result == .completed, let latest else {
            throw Failure.message("State did not converge: \(String(describing: probe.value))\n\(app.debugDescription)")
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
