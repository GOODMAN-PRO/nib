import XCTest
import UIKit

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

    /// Waits for a target in its actual form, searching both directions until the visible rows stop changing.
    /// Existing callers pass lazy firstMatch queries; the closure overload also supports fresh section-scoped queries.
    func revealFormElement(_ element: XCUIElement) { revealFormElement { element } }

    /// Reacquires the target after each scroll and stops at a repeated visible range, avoiding stale virtualized indices.
    func revealFormElement(in form: XCUIElement? = nil, target: () -> XCUIElement) {
        let initial = target()
        if initial.exists && initial.isHittable,
           (form?.frame ?? app.windows.firstMatch.frame).contains(CGPoint(x: initial.frame.midX, y: initial.frame.midY)) { return }
        let containers = (app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex).filter {
                $0.identifier != "nib.canvas" && $0.frame.height > 100 && $0.frame.width > 200
                    && app.windows.firstMatch.frame.intersects($0.frame)
                    && ($0.isHittable || [.collectionView, .table].contains($0.elementType))
            }
        let containing = containers.filter { list in
            initial.exists && list.descendants(matching: initial.elementType).matching(NSPredicate(
                format: "identifier == %@ AND label == %@", initial.identifier, initial.label)).count > 0
        }
        guard let list = form ?? containing.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            ?? containers.max(by: { $0.frame.minX < $1.frame.minX }) else { return }
        for down in [false, true] {
            var previous: String?
            for _ in 0..<8 {
                let element = target()
                let obstructions = app.keyboards.allElementsBoundByIndex.map(\.frame)
                    + app.otherElements.matching(identifier: "inputAssistantView").allElementsBoundByIndex.map(\.frame)
                guard let viewport = NibUITestScrollGeometry.viewport(
                    scroll: list.frame, window: app.windows.firstMatch.frame, obstructions: obstructions) else { return }
                if element.exists && element.isHittable && viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
                // One snapshot supplies the visible range; querying every row attribute separately can itself time out.
                guard let snapshot = try? list.snapshot() else { return }
                let signature = formVisibleRange(snapshot, viewport: viewport).joined(separator: "\n")
                if signature == previous { break }
                previous = signature
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let x = viewport.minX + viewport.width * 0.5
                let startY = viewport.minY + viewport.height * (down ? 0.25 : 0.75)
                let endY = viewport.minY + viewport.height * (down ? 0.75 : 0.25)
                origin.withOffset(CGVector(dx: x - app.frame.minX, dy: startY - app.frame.minY))
                    .press(forDuration: 0.01, thenDragTo: origin.withOffset(
                        CGVector(dx: x - app.frame.minX, dy: endY - app.frame.minY)), withVelocity: .slow, thenHoldForDuration: 0)
            }
        }
    }

    /// Reads one immutable snapshot without waiting so progress checks cannot retain stale virtualized element indices.
    private func formVisibleRange(_ snapshot: XCUIElementSnapshot, viewport: CGRect) -> [String] {
        let frame = snapshot.frame
        let own = [.button, .staticText].contains(snapshot.elementType)
            && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            ? ["\(snapshot.identifier)|\(snapshot.label)|\(Int(frame.minY))"] : []
        return own + snapshot.children.flatMap { formVisibleRange($0, viewport: viewport) }
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
        try replaceNativeText(in: field, with: title)
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

    /// Waits for the actual microphone prompt (or an already-authorized Recording HUD), then for system alerts to disappear.
    /// Startup/teardown callers drain outstanding known authorization prompts without accepting unrelated dialogs.
    func handleAuthorizationAlerts(waitForMicrophone: Bool = false) throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = NSPredicate(format: "label CONTAINS[c] 'microphone' OR label CONTAINS[c] 'calendar' OR label CONTAINS[c] 'photos'")
        /// Reads the currently visible authorization without waiting; the outer expectation handles asynchronous presentation.
        func alert(microphoneOnly: Bool = false) -> XCUIElement? {
            let filter = microphoneOnly ? NSPredicate(format: "label CONTAINS[c] 'microphone'") : permission
            let title = system.alerts.matching(filter).firstMatch
            if title.exists { return title }
            let content = system.alerts.containing(filter).firstMatch
            return content.exists ? content : nil
        }
        if waitForMicrophone {
            let recording = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Recording' AND value != nil")).firstMatch
            let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                alert(microphoneOnly: true) != nil || recording.exists
            }, object: nil)
            guard XCTWaiter.wait(for: [requested], timeout: 15) == .completed else {
                throw Failure.message("Quick Record produced neither microphone authorization nor Recording HUD\n\(system.debugDescription)")
            }
        }
        for _ in 0..<3 {
            guard let prompt = alert() else { return }
            let allow = prompt.buttons.matching(NSPredicate(
                format: "label IN {'Allow', 'OK', 'Allow Full Access', 'Allow Access to All Photos'}")).firstMatch
            guard allow.isHittable else { throw Failure.message("Authorization has no observed affirmative action\n\(system.debugDescription)") }
            allow.tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !prompt.exists }, object: nil)
            guard XCTWaiter.wait(for: [gone], timeout: 8) == .completed else {
                throw Failure.message("Authorization alert must disappear before continuing\n\(system.debugDescription)")
            }
        }
        guard alert() == nil else { throw Failure.message("Outstanding authorization survived cleanup") }
    }

    /// The display in screen points, in the current orientation, measured from a screenshot of the device rather
    /// than from the runner's UIScreen (which reports the runner's compatibility size on large iPads). A screenshot
    /// image carries the device scale when XCTest sets it; otherwise its size is in pixels and the runner's scale,
    /// which is the device's, converts it.
    static func displayRect() -> CGRect {
        let image = XCUIScreen.main.screenshot().image
        let scale = image.scale > 1 ? CGFloat(1) : UIScreen.main.scale
        return CGRect(origin: .zero, size: CGSize(width: image.size.width / scale, height: image.size.height / scale))
    }

    /// Waits for the main window to cover the physical display before any orientation assertion.
    /// Fixture data resets do not reset iPadOS window placement left by an earlier gesture.
    func establishFullScreen() throws {
        app.activate()
        // The screenshot is the device's display in its current orientation. The runner's own UIScreen is not:
        // on an iPad Pro 13-inch it reports the runner's 768 x 1024 compatibility bounds while the app window is
        // 1032 x 1376 points, and it keeps portrait bounds after the foreground app rotates.
        let screen = NibUI.displayRect()
        /// Reads current window edges without waiting; the enclosing expectation waits for fullscreen placement.
        func fillsScreen() -> Bool {
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            let f = window.frame
            return abs(f.minX - screen.minX) <= 2 && abs(f.minY - screen.minY) <= 2
                && abs(f.maxX - screen.maxX) <= 2 && abs(f.maxY - screen.maxY) <= 2
        }
        if fillsScreen() { return }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let fullScreen = system.buttons.matching(NSPredicate(format: "label ==[c] 'Full Screen'")).firstMatch
        let controls = system.buttons.matching(NSPredicate(format: "label ==[c] 'Window Controls'")).firstMatch
        if !fullScreen.isHittable && controls.isHittable { controls.tap() }
        if fullScreen.isHittable {
            fullScreen.tap()
        } else {
            // Apple's system Globe-F shortcut; sent only when not already fullscreen.
            // This also recovers a window whose controls have been displaced offscreen.
            app.typeKey("f", modifierFlags: .function)
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fillsScreen() }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed else {
            throw Failure.message("Full-screen recovery failed: display \(screen), window \(app.windows.firstMatch.frame)\n\(system.debugDescription)\n\(app.debugDescription)")
        }
    }

    /// Waits for visible palette anchors, then uses an unobstructed adjacent gap or a verified container edge.
    /// Records the frames for CI and checks that the gesture leaves the app window fixed.
    func dragPalette(to destination: CGPoint) throws {
        let more = app.buttons.matching(identifier: "tool.more").firstMatch
        let colour = app.buttons.matching(identifier: "cmd.preset.select")
            .matching(NSPredicate(format: "label == 'Colour 1'")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            more.isHittable && colour.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            throw Failure.message("Palette separator grip needs visible More tools and Colour 1")
        }
        let before = app.windows.firstMatch.frame
        let a = more.frame, b = colour.frame
        let vertical = abs(a.midY - b.midY) > abs(a.midX - b.midX)
        let gap = vertical ? b.minY - a.maxY : b.minX - a.maxX
        let crossMin = vertical ? max(a.minX, b.minX) : max(a.minY, b.minY)
        let crossMax = vertical ? min(a.maxX, b.maxX) : min(a.maxY, b.maxY)
        let separator = vertical
            ? CGRect(x: crossMin, y: a.maxY, width: max(0, crossMax - crossMin), height: max(0, gap))
            : CGRect(x: a.maxX, y: crossMin, width: max(0, gap), height: max(0, crossMax - crossMin))
        let midpoint = CGPoint(x: separator.midX, y: separator.midY)
        // Structural containers and captions are not hit targets. Include native and custom leaf controls.
        let containers: [XCUIElement.ElementType] = [.application, .window, .other, .scrollView,
            .table, .collectionView, .toolbar, .navigationBar, .tabBar, .staticText]
        let controls = try app.descendants(matching: .any).allElementsBoundByIndex.compactMap { element
            -> (identifier: String, label: String, frame: CGRect)? in
            // One snapshot supplies type/children/identity/frame rather than separate AX round trips for each attribute.
            let snapshot = try element.snapshot()
            guard !containers.contains(snapshot.elementType)
                || (snapshot.elementType == .other && snapshot.children.isEmpty) else { return nil }
            guard element.isHittable else { return nil }
            return (snapshot.identifier, snapshot.label, snapshot.frame)
        }
        let others = controls.filter {
            !($0.identifier == "tool.more" && $0.frame == a)
                && !($0.identifier == "cmd.preset.select" && $0.label == "Colour 1" && $0.frame == b)
        }
        let visible = before.insetBy(dx: 8, dy: 8)
        let adjacent = gap > 2 && crossMax - crossMin > 2 && visible.contains(separator)
            && !others.contains { $0.frame.intersects(separator) || $0.frame.contains(midpoint) }
        var chosen: CGPoint? = adjacent ? midpoint : nil
        var paletteFrame: CGRect?
        if !adjacent {
            // Bind Tools to both live anchors; a stale aggregate frame alone is not evidence of a safe edge.
            let palette = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Tools'"))
                .allElementsBoundByIndex.filter {
                    $0.frame.contains(a) && $0.frame.contains(b)
                        && $0.buttons.matching(identifier: "tool.more").count > 0
                        && $0.buttons.matching(identifier: "cmd.preset.select")
                            .matching(NSPredicate(format: "label == 'Colour 1'")).count > 0
                }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            if let palette {
                let frame = palette.frame
                paletteFrame = frame
                // End-padding is on the long axis; stay inside the rounded body and clear of all live controls.
                let edges = vertical
                    ? [CGPoint(x: frame.midX, y: frame.minY + 2), CGPoint(x: frame.midX, y: frame.maxY - 2)]
                    : [CGPoint(x: frame.minX + 2, y: frame.midY), CGPoint(x: frame.maxX - 2, y: frame.midY)]
                let thickness = vertical ? frame.width : frame.height
                let anchorThickness = vertical ? max(a.width, b.width) : max(a.height, b.height)
                if visible.contains(frame), thickness <= anchorThickness + 8 {
                    chosen = edges.first { point in
                        frame.contains(point) && !controls.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
                    }
                }
            }
        }
        XCTContext.runActivity(named: "Palette drag anchor geometry") { activity in
            let frames = controls.map { "\($0.identifier) | \($0.label): \($0.frame)" }.joined(separator: "\n")
            let attachment = XCTAttachment(string: "More \(a), Colour 1 \(b), window \(before)\n"
                + "gap \(gap), separator \(separator), adjacent \(adjacent), palette \(String(describing: paletteFrame))\n"
                + "chosen \(String(describing: chosen)), destination \(destination)\n\(frames)")
            attachment.name = "palette-drag-frames"; attachment.lifetime = .keepAlways; activity.add(attachment)
        }
        guard let grip = chosen else {
            throw Failure.message("No unobstructed palette separator or container edge: More \(a), colour \(b), window \(before)")
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: grip.x - app.frame.minX, dy: grip.y - app.frame.minY))
            .press(forDuration: 0.15, thenDragTo: app.coordinate(withNormalizedOffset:
                CGVector(dx: destination.x, dy: destination.y)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let after = app.windows.firstMatch.frame
        guard abs(after.minX - before.minX) <= 2, abs(after.minY - before.minY) <= 2,
              abs(after.width - before.width) <= 2, abs(after.height - before.height) <= 2 else {
            throw Failure.message("Palette gesture moved the app window: \(before) -> \(after); grip \(grip)")
        }
    }

    func launchFixture(scenario: FixtureScenario = .standard) throws {
        app.launchArguments = ["-NibUITestFixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-NibUITestScenario", scenario.rawValue]
        app.launch()
        // Cold package creation and service startup share the machine with builds.
        // Keep the readiness assertion, but do not give launch the short deadline
        // used for an already-running command.
        try handleAuthorizationAlerts()
        _ = try waitForState(timeout: 120) { $0.screen == "library" }
        try handleAuthorizationAlerts()
        // Rotate only the running app, not SpringBoard or a previous test's system service. Repeated portrait
        // resets add an unrelated orientation-confirmation race before Nib even launches.
        try establishFullScreen()
        // Device orientation may already say landscape after tearDown rotated
        // SpringBoard. Deliver the request to this scene too.
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            // The application's union frame includes transient system windows.
            // Validate the main app window using one fresh snapshot per poll.
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            return frame.width > frame.height && frame.height > 0
        }, object: nil)
        guard XCTWaiter.wait(for: [landscape], timeout: 30) == .completed else {
            throw Failure.message("Nib's launched scene did not reach landscape")
        }
        try establishFullScreen()
        _ = try waitForState { $0.screen == "library" }
    }

    /// Activates this scene, waits for non-text focus without editing/navigating, and verifies the chord's action.
    /// The activity records requested modifiers beside the shell's existing Key routing / Library key diagnostic logs.
    func chord(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags,
               verifying postcondition: () throws -> Void) throws {
        app.activate()
        let before = try state()
        guard !app.keyboards.firstMatch.exists else {
            throw Failure.message("Dismiss text editing explicitly before delivering a global chord")
        }
        let window = app.windows.firstMatch
        let title = app.buttons.matching(identifier: "menu.title").firstMatch
        // Use an empty part of the header row, never a canvas stroke, tool, or navigation action.
        let sheet = app.sheets.firstMatch
        let focusFrame = sheet.exists ? sheet.frame : window.frame
        let y = sheet.exists ? focusFrame.minY + 24 : title.exists ? title.frame.midY : window.frame.minY + 70
        let occupied = app.buttons.allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame)
            + app.textFields.allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame)
            + app.searchFields.allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame)
            + app.textViews.allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame)
        let points = [CGFloat(0.5), 0.45, 0.55, 0.4, 0.6].map {
            CGPoint(x: focusFrame.minX + focusFrame.width * $0, y: y)
        }
        guard let focus = points.first(where: { point in
            window.frame.contains(point) && !occupied.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
        }) else { throw Failure.message("No inert header focus target for keyboard chord") }
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: focus.x - app.frame.minX, dy: focus.y - app.frame.minY)).tap()
        let focused = try state()
        guard focused.document == before.document, focused.page == before.page,
              focused.strokeCountOnPage == before.strokeCountOnPage,
              focused.itemCountOnPage == before.itemCountOnPage, focused.selectionCount == before.selectionCount,
              focused.undoAvailable == before.undoAvailable, focused.redoAvailable == before.redoAvailable,
              focused.zoom == before.zoom, focused.contentOffset.x == before.contentOffset.x,
              focused.contentOffset.y == before.contentOffset.y, focused.openPanels == before.openPanels,
              !app.keyboards.firstMatch.exists else {
            throw Failure.message("Keyboard focus preparation changed document content or navigation")
        }
        try XCTContext.runActivity(named: "Requested chord \(key), modifiers \(modifiers.rawValue)") { [self] activity in
            let request = XCTAttachment(string: "key=\(key) modifiers=\(modifiers.rawValue) window=\(window.frame)\n\(probe.value ?? "missing")")
            request.lifetime = .keepAlways; activity.add(request)
            defer {
                let result = XCTAttachment(string: "\(probe.value ?? "missing")\n\(app.debugDescription)")
                result.name = "chord-result"; result.lifetime = .keepAlways; activity.add(result)
            }
            // Holding modifiers across the event avoids an unmodified fallback key between down/up events.
            XCUIElement.perform(withKeyModifiers: modifiers) { [self] in app.typeKey(key, modifierFlags: modifiers) }
            try postcondition()
        }
    }

    func state() throws -> QAState {
        if let state = try readState() { return state }
        return try waitForState(timeout: 10) { _ in true }
    }

    /// Waits for this paste's result or the exact native Allow Paste prompt, then for dismissal and completion.
    /// Only the requesting app and SpringBoard are searched; unrelated authorization dialogs are never accepted.
    func waitForPaste(timeout: TimeInterval = 15, result: @escaping () -> Bool) throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func allowButton() -> XCUIElement? {
            for source in [app, system] {
                let prompt = source.alerts.containing(.button, identifier: "Allow Paste").firstMatch
                let button = prompt.buttons["Allow Paste"].firstMatch
                if button.exists { return button }
            }
            return nil
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            allowButton() != nil || result()
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            throw Failure.message("Paste produced neither its expected result nor Allow Paste")
        }
        if let allow = allowButton() {
            allow.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in allowButton() == nil }, object: nil)
            guard XCTWaiter.wait(for: [dismissed], timeout: 8) == .completed else {
                throw Failure.message("Allow Paste must dismiss before observing pasted content")
            }
        }
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in result() }, object: nil)
        guard XCTWaiter.wait(for: [completed], timeout: timeout) == .completed else {
            throw Failure.message("Authorized paste did not produce the expected content\n\(app.debugDescription)")
        }
    }

    /// Waits for a real asset cell in the native Photos grid, excluding the document's background image.
    func photoAsset() throws -> XCUIElement {
        let photos = NSPredicate(format: "label BEGINSWITH[c] 'Photo' OR label BEGINSWITH[c] 'Image'")
        let cells = app.collectionViews.cells
        let labelled = cells.matching(photos).firstMatch
        let containing = cells.containing(photos).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (labelled.exists && labelled.isHittable) || (containing.exists && containing.isHittable)
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed else {
            throw Failure.message("Photos must expose a selectable asset cell\n\(app.debugDescription)")
        }
        return labelled.exists && labelled.isHittable ? labelled : containing
    }

    /// Drags the visible custom track, then waits for the caller's playback-position oracle; native slider endpoints are absent.
    func dragSlider(_ slider: XCUIElement, to fraction: CGFloat, verifying result: () throws -> Void) throws {
        guard slider.exists && slider.isHittable && slider.frame.width > 28 else {
            throw Failure.message("Custom slider needs a visible track: \(slider)")
        }
        // NibSlider reserves 14 points at each end for its bead; map the fraction onto the actual track.
        let targetX = (14 + min(1, max(0, fraction)) * (slider.frame.width - 28)) / slider.frame.width
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.01, thenDragTo: slider.coordinate(withNormalizedOffset:
                CGVector(dx: targetX, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0)
        try result()
    }

    /// Samples the live probe once, without nesting a state wait inside another expectation.
    func matchesState(_ predicate: (QAState) -> Bool) -> Bool {
        guard let current = try? readState() else { return false }
        return predicate(current)
    }

    /// Reads XCTest's native focus diagnostic, allowing input into an already-focused but keyboard-occluded editor.
    func isKeyboardFocused(_ field: XCUIElement) -> Bool {
        field.exists && field.debugDescription.contains("Keyboard Focused")
    }

    /// Waits for the native keyboard's own dismissal before a global action; never taps document content.
    func dismissNativeKeyboard() throws {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.keyboards.buttons.matching(NSPredicate(format: "label IN {'Hide keyboard', 'Dismiss keyboard'}")).firstMatch
        guard hide.exists && hide.isHittable else { throw Failure.message("No native keyboard dismissal control") }
        hide.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in !app.keyboards.firstMatch.exists }, object: nil)
        guard XCTWaiter.wait(for: [gone], timeout: 5) == .completed else { throw Failure.message("Keyboard did not dismiss") }
    }

    /// Waits for native field focus without retapping an existing selection or moving focus to global chrome.
    func focusField(_ field: XCUIElement) throws {
        if isKeyboardFocused(field) { return }
        revealFormElement(field)
        guard field.exists && field.isHittable else { throw Failure.message("Native field cannot receive focus: \(field)") }
        field.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in isKeyboardFocused(field) }, object: nil)
        guard XCTWaiter.wait(for: [focused], timeout: 5) == .completed else {
            throw Failure.message("Native field did not gain keyboard focus: \(field.debugDescription)")
        }
    }

    /// Delivers modifiers while preserving native focus; callers verify the relevant text or formatting result.
    func nativeKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = .command, in field: XCUIElement) throws {
        try focusField(field)
        XCUIElement.perform(withKeyModifiers: modifiers) { field.typeKey(key, modifierFlags: modifiers) }
    }

    /// Waits for exact replacement, including empty fields, so a lost Select All cannot silently append text.
    func replaceNativeText(in field: XCUIElement, with text: String) throws {
        try nativeKey("a", in: field)
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
        try waitForNativeText(in: field, equals: text)
    }

    /// Waits for the native editor's actual text; a placeholder represents an empty value, not user content.
    func waitForNativeText(in field: XCUIElement, equals text: String) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = field.value as? String else { return false }
            return value == text || (text.isEmpty && value == field.placeholderValue)
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            throw Failure.message("Native replacement mismatch: expected \(text.debugDescription), got \(String(describing: field.value))")
        }
    }

    /// Proves a native selection by replacing it with a unique marker and observing the exact full value.
    /// Native Undo restores the original text and selected range before formatting; rich-text assertions still verify the result.
    func verifyNativeSelection(in field: XCUIElement, fullText: String, range: NSRange) throws {
        let marker = "QA-" + UUID().uuidString
        let expected = (fullText as NSString).replacingCharacters(in: range, with: marker)
        field.typeText(marker)
        try waitForNativeText(in: field, equals: expected)
        try nativeKey("z", in: field)
        try waitForNativeText(in: field, equals: fullText)
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
        _ = try waitForState { $0.screen == "library" }
        let document = app.buttons.matching(identifier: "cmd.doc.open")
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        guard document.waitForExistence(timeout: 15) else { throw Failure.message("Document missing: \(title); state: \(String(describing: probe.value))\n\(app.debugDescription)") }
        // The card's decorative accessibility group can also have a button trait.
        // Only the command-bearing outer button owns document navigation.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: document)
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else { throw Failure.message("Document is not hittable: \(title)") }
        // Hittable means that some of the card is visible, not that its centre
        // lies in the library's scroll viewport. A clipped card must receive the
        // same visible tap a person can make, never a tap on chrome below it.
        var visible = app.windows.firstMatch.frame
        for scroll in app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex {
            let cards = scroll.buttons.matching(identifier: "cmd.doc.open")
                .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ","))
            if cards.count > 0 { visible = visible.intersection(scroll.frame) }
        }
        guard let point = NibUITestScrollGeometry.tapPoint(control: document.frame, viewport: visible) else {
            throw Failure.message("Document has no visible tap area: \(title)")
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
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
        var fragment: Data?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = probe.value as? String,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(value.utf8)),
                  snapshot.changeCount > before, let data = snapshot.fragment else { return false }
            fragment = data
            return true
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed, let fragment else {
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
        func menuHost(containing control: XCUIElement? = nil) -> XCUIElement? {
            (app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex)
                .filter { scroll in
                    guard scroll.identifier != "nib.canvas", scroll.isHittable else { return false }
                    let matches = scroll.descendants(matching: .any).matching(identifier: id)
                    if let control { return matches.allElementsBoundByIndex.contains { $0.frame == control.frame } }
                    return matches.count > 0
                }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        func revealInMenu() -> XCUICoordinate? {
            for _ in 0..<16 {
                let control = candidate(id)
                let scroll = menuHost(containing: control)
                let obstructions = app.keyboards.allElementsBoundByIndex.map(\.frame)
                    + app.otherElements.matching(identifier: "inputAssistantView").allElementsBoundByIndex.map(\.frame)
                let viewport = NibUITestScrollGeometry.viewport(
                    scroll: scroll?.frame ?? app.frame, window: app.frame, obstructions: obstructions)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                if let control, let viewport,
                   let point = NibUITestScrollGeometry.tapPoint(control: control.frame, viewport: viewport) {
                    return origin.withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
                }
                // More contains full sections (including Add Page) in a bounded viewport.
                // Scroll its real host; existence alone does not make an offscreen row actionable.
                guard let scroll, let viewport else { return nil }
                let target = scroll.descendants(matching: .any).matching(identifier: id).firstMatch
                let drag = NibUITestScrollGeometry.drag(in: viewport, toward: target.frame.midY)
                origin.withOffset(CGVector(dx: drag.start.x - app.frame.minX, dy: drag.start.y - app.frame.minY))
                    .press(forDuration: 0.01, thenDragTo: origin.withOffset(
                        CGVector(dx: drag.end.x - app.frame.minX, dy: drag.end.y - app.frame.minY)),
                        withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            return nil
        }
        if let control = revealInMenu() { control.tap(); return }
        for identifier in overflow {
            if let menu = candidate(identifier) {
                menu.tap()
                // The bud enters the accessibility tree before its scroll host is actionable.
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    candidate(id) != nil || menuHost() != nil
                }, object: nil)
                _ = XCTWaiter.wait(for: [ready], timeout: 5)
                if let control = revealInMenu() { control.tap(); return }
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
        // iPadOS 26 exposes the toolbar action as add-plus-button / lowercase "add".
        // Prefer its stable identifier; localized display casing is not a command contract.
        func addButton() -> XCUIElement? {
            let identified = calendar.buttons.matching(identifier: "add-plus-button").allElementsBoundByIndex
            let labelled = calendar.buttons.matching(NSPredicate(
                format: "label ==[c] 'Add' OR label IN {'Add Event', 'New Event', 'Create Event', 'Create'}"))
                .allElementsBoundByIndex
            return (identified + labelled).first { $0.isEnabled && $0.isHittable }
        }
        func editorIsReady() -> Bool { title.exists && title.isEnabled && title.isHittable }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editorIsReady() || addButton() != nil
        }, object: nil)
        _ = XCTWaiter.wait(for: [ready], timeout: 15)
        if editorIsReady() { return }
        addButton()?.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editorIsReady() }, object: nil)
        if XCTWaiter.wait(for: [opened], timeout: 10) == .completed { return }

        // Calendar's New Event keyboard command also reaches the native editor when
        // iPadOS omits the visible + symbol's accessibility label. Unlike a screen
        // coordinate this remains valid across orientation and toolbar layouts.
        calendar.typeKey("n", modifierFlags: [.command])
        let shortcutOpened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editorIsReady() }, object: nil)
        guard XCTWaiter.wait(for: [shortcutOpened], timeout: 10) == .completed else {
            throw NibUI.Failure.message("Calendar did not open its New Event editor through Add or Command-N\n"
                                        + calendar.debugDescription)
        }
    }
}
