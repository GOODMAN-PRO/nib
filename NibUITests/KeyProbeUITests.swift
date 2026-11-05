import XCTest

/// Observation only. Keep this class independent of the shared keyboard/state helpers under repair.
@MainActor
final class KeyProbeUITests: XCTestCase {
    private var ui: NibUI!
    private let panelID = "pages.goToPage"

    private struct State: Decodable {
        let keyLog: [String]
        let keyLogTotal: Int
        let keyResponder: String?
        let keyResponderIsText: Bool?
        let openPanels: [String]
        let selectionCount: Int
    }

    private enum Route: String, CaseIterable {
        case one = "1", two = "2", three = "3", app = "app.typeKey", field = "field.typeKey"
        static let canvas: [Route] = [.one, .two, .three, .app]
    }

    private enum ProbeError: Error {
        case prerequisite(String)
    }

    func testSpecialKeyRoutes() throws {
        executionTimeAllowance = 300
        // CI also caps each test at 300s. Include fixture launch in these monotonic budgets,
        // reserve text-context time, and leave 60s for an in-flight XCUI call and the assertion.
        let started = ProcessInfo.processInfo.systemUptime
        let canvasDeadline = started + 130
        let matrixDeadline = started + 240
        continueAfterFailure = false
        ui = NibUI()
        try ui.launchFixture()
        try ui.openDocument("Physics — Motion")
        guard waitUntil({ self.ui.canvas.exists }), waitForState({ $0.keyResponderIsText == false }) else {
            throw ProbeError.prerequisite("Fixture canvas did not acquire non-text focus")
        }
        logSelectors()

        let initial = try state()
        let primeError = send(";") // Existing route, plain printable key; the first event loses modifiers.
        let primed = waitForState { $0.keyLogTotal > initial.keyLogTotal }
        log("prime", "error=\(quoted(primeError ?? "nil")) delivered=\(primed) \(delta(initial, try state()))")

        let keys: [(String, [String])] = [
            // Establish the final assertion before an odd special key can move focus or consume the budget.
            ("a", ["a"]),
            ("Escape", [XCUIKeyboardKey.escape.rawValue, "\u{1B}"]),
            ("Delete", [XCUIKeyboardKey.delete.rawValue, "\u{8}", "\u{7F}"]),
            ("ForwardDelete", [XCUIKeyboardKey.forwardDelete.rawValue]),
            ("Return", [XCUIKeyboardKey.return.rawValue, "\r", "\n"]),
            ("Enter", [XCUIKeyboardKey.enter.rawValue, "\u{3}"]),
            ("Tab", [XCUIKeyboardKey.tab.rawValue])
        ]
        var controlDelivered = false
        var firstEscape: (String, Route)?
        canvasMatrix: for (name, candidates) in keys {
            var seen = Set<String>()
            for key in candidates where seen.insert(key).inserted {
                for route in Route.canvas {
                    guard hasBudget(until: canvasDeadline, context: "canvas", reserve: 6) else { break canvasMatrix }
                    guard waitForState({ $0.keyResponderIsText == false && $0.openPanels.isEmpty }, timeout: 1) else {
                        let current = try? state()
                        log("skipped", "context=canvas key=\(name) scalars=\(scalars(key)) route=\(route.rawValue) "
                            + "reason=focus responder=\(quoted(current?.keyResponder ?? "nil")) "
                            + "isText=\(String(describing: current?.keyResponderIsText)) "
                            + "openPanels=\(quoted(current?.openPanels))")
                        continue
                    }
                    let before = try state()
                    let error = send(key, route: route)
                    _ = waitForState({ $0.keyLogTotal > before.keyLogTotal }, timeout: 1)
                    let after = try state()
                    let delivered = after.keyLogTotal > before.keyLogTotal
                    log("result", "context=canvas key=\(name) scalars=\(scalars(key)) route=\(route.rawValue) "
                        + "error=\(quoted(error ?? "nil")) delivered=\(delivered) \(delta(before, after)) "
                        + "textBefore=\(String(describing: before.keyResponderIsText)) responder=\(quoted(before.keyResponder ?? "nil"))")
                    if name == "a", before.keyResponderIsText == false, delivered { controlDelivered = true }
                    if name == "Escape", delivered, firstEscape == nil { firstEscape = (key, route) }
                }
            }
        }

        if hasBudget(until: canvasDeadline + 15, context: "canvas.effect", reserve: 10) {
            let selectError = send("a", modifiers: .command)
            let selected = waitForState { $0.selectionCount > 0 && $0.keyResponderIsText == false }
            let beforeEscape = try state()
            let (escapeKey, escapeRoute): (String, Route) = firstEscape ?? (XCUIKeyboardKey.escape.rawValue, Route.one)
            let escapeError = send(escapeKey, route: escapeRoute)
            let cleared = waitForState { $0.selectionCount == 0 }
            log("effect", "context=canvas key=Escape scalars=\(scalars(escapeKey)) route=\(escapeRoute.rawValue) "
                + "selected=\(selected) selectionBefore=\(beforeEscape.selectionCount) cleared=\(cleared) "
                + "meaningful=\(selected && beforeEscape.selectionCount > 0) selectError=\(quoted(selectError ?? "nil")) "
                + "error=\(quoted(escapeError ?? "nil")) \(delta(beforeEscape, try state()))")
        }

        // Canonical encodings once per route in native input. Return needs a valid page: "12" is out of range
        // in the four-page fixture, so it cannot be used to infer whether submission closes the panel.
        textMatrix: for (name, key) in [("Delete", XCUIKeyboardKey.delete.rawValue),
                            ("Return", XCUIKeyboardKey.return.rawValue),
                            ("Escape", XCUIKeyboardKey.escape.rawValue)] {
            for route in Route.allCases {
                guard hasBudget(until: matrixDeadline, context: "text", reserve: 20) else { break textMatrix }
                let field: XCUIElement
                do {
                    field = try openPageField()
                } catch {
                    log("skipped", "context=text key=\(name) route=\(route.rawValue) reason=\(quoted(String(describing: error)))")
                    continue
                }
                guard hasBudget(until: matrixDeadline, context: "text.prepare", reserve: 15) else { break textMatrix }
                let input = name == "Return" ? "2" : "12"
                // An undelivered key leaves the input prepared for the next route. Avoid repeating
                // public XCUI idle waits in that expected case; reset only when the value differs.
                if fieldValue(field) != input {
                    field.typeKey("a", modifierFlags: .command)
                    guard hasBudget(until: matrixDeadline, context: "text.typeText", reserve: 10) else { break textMatrix }
                    field.typeText(input)
                }
                let prepared = waitUntil({ self.fieldValue(field) == input }, timeout: 1)
                guard hasBudget(until: matrixDeadline, context: "text.send", reserve: 5) else { break textMatrix }
                let beforeValue = fieldValue(field)
                let before = try state()
                let error = send(key, route: route, field: field)
                // Wait for the actual effect even if key logging happened first. A text-input edit can be
                // delivered with no UIPress, and Return/Escape can close the panel with no logged key.
                let effect = waitUntil({
                    guard let current = try? self.state() else { return false }
                    if !current.openPanels.contains(self.panelID) { return true }
                    return name == "Delete" && field.exists && self.fieldValue(field) != beforeValue
                }, timeout: 1)
                let after = try state()
                let closed = !after.openPanels.contains(panelID)
                let afterValue = closed ? "<panel closed>" : fieldValue(field)
                log("result", "context=text key=\(name) scalars=\(scalars(key)) route=\(route.rawValue) "
                    + "error=\(quoted(error ?? "nil")) delivered=\(after.keyLogTotal > before.keyLogTotal) "
                    + "\(delta(before, after)) before=\(quoted(beforeValue)) after=\(quoted(afterValue)) "
                    + "prepared=\(prepared) textBefore=\(String(describing: before.keyResponderIsText)) "
                    + "responder=\(quoted(before.keyResponder ?? "nil")) panelClosed=\(closed) effect=\(effect)")
            }
        }
        XCTAssertTrue(controlDelivered, "No canvas route delivered control key a; inspect Key probe logs")
    }

    private func state() throws -> State {
        let probe = ui.app.otherElements["nib.qa.state"].firstMatch
        guard let value = probe.value as? String else {
            throw ProbeError.prerequisite("nib.qa.state has no JSON value")
        }
        return try JSONDecoder().decode(State.self, from: Data(value.utf8))
    }

    private func hasBudget(until deadline: TimeInterval, context: String, reserve: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > reserve else {
            log("budget exhausted", "context=\(context) remaining=\(remaining) reserve=\(reserve); remaining samples skipped")
            return false
        }
        return true
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForState(_ condition: @escaping (State) -> Bool, timeout: TimeInterval = 2) -> Bool {
        waitUntil({
            guard let value = try? self.state() else { return false }
            return condition(value)
        }, timeout: timeout)
    }

    /// nil route uses the unmodified existing helper (priming and setup chords only).
    private func send(_ key: String, route: Route? = nil, modifiers: XCUIElement.KeyModifierFlags = [],
                      field: XCUIElement? = nil) -> String? {
        if route == .app {
            ui.app.typeKey(key, modifierFlags: modifiers)
            return nil
        }
        if route == .field {
            guard let field else { return "field.typeKey has no field" }
            field.typeKey(key, modifierFlags: modifiers)
            return nil
        }
        let done = XCTestExpectation(description: "Key probe synthesis completed")
        var failure: Error?
        if let route, let number = Int(route.rawValue) {
            NibTouchPaths.sendKey(key, modifiers: modifiers.rawValue, route: number) { error in
                failure = error
                done.fulfill()
            }
        } else {
            NibTouchPaths.typeKey(key, modifiers: modifiers.rawValue) { error in
                failure = error
                done.fulfill()
            }
        }
        guard XCTWaiter.wait(for: [done], timeout: 2) == .completed else {
            return "synthesis completion timed out after 2s; late events may contaminate the next sample"
        }
        return failure?.localizedDescription
    }

    private func openPageField() throws -> XCUIElement {
        if !(try state()).openPanels.contains(panelID) {
            let error = send("g", modifiers: [.option, .command])
            guard waitForState({ $0.openPanels.contains(self.panelID) }) else {
                throw ProbeError.prerequisite("Go to Page did not open: \(error ?? "no synthesis error")")
            }
        }
        // NibField can expose a text view when its vertical axis is enabled.
        let textField = ui.app.textFields["Page number or title"].firstMatch
        let textView = ui.app.textViews["Page number or title"].firstMatch
        guard waitUntil({ textField.exists || textView.exists }),
              waitForState({ $0.keyResponderIsText == true && $0.openPanels.contains(self.panelID) }) else {
            throw ProbeError.prerequisite("Go to Page native input did not autofocus")
        }
        return textField.exists ? textField : textView
    }

    private func fieldValue(_ field: XCUIElement) -> String {
        guard field.exists else { return "<missing>" }
        return field.value as? String ?? "<no value>"
    }

    private func delta(_ before: State, _ after: State) -> String {
        let count = max(0, after.keyLogTotal - before.keyLogTotal)
        let entries = Array(after.keyLog.suffix(min(count, after.keyLog.count)).prefix(3))
        return "new=\(quoted(entries)) delta=\(count) total=\(after.keyLogTotal)"
    }

    private func scalars(_ key: String) -> String {
        key.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
    }

    /// JSON escaping keeps control characters and nil-key diagnostics on one NSLog line.
    private func quoted<T: Encodable>(_ value: T) -> String {
        guard let bytes = try? JSONEncoder().encode(value), let text = String(data: bytes, encoding: .utf8) else {
            return "<encoding failed>"
        }
        return text
    }

    private func log(_ kind: String, _ text: String) {
        NSLog("%@", "[Nib QA] Key probe \(kind) \(text)")
    }

    private func logSelectors() {
        var names = ["XCPointerEventPath", "XCSynthesizedEventRecord"]
        let selector = NSSelectorFromString("eventSynthesizer")
        let device = XCUIDevice.shared
        if device.responds(to: selector), let synthesizer = device.perform(selector)?.takeUnretainedValue() {
            names.append(NSStringFromClass(type(of: synthesizer)))
        } else {
            log("selectors", "eventSynthesizer unavailable on XCUIDevice.shared")
        }
        // Exactly one enumeration per class; split even a long individual selector below 1200 characters.
        for name in names {
            var remaining = "class=\(name) " + NibTouchPaths.selectorNames(forClassNamed: name).joined(separator: ", ")
            var chunk = 1
            while !remaining.isEmpty {
                let part = String(remaining.prefix(1000))
                log("selectors", "chunk=\(chunk) \(part)")
                remaining.removeFirst(part.count)
                chunk += 1
            }
        }
    }
}
