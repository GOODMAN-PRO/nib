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
    var probe: XCUIElement { app.otherElements["nib.qa.state"].firstMatch }
    var canvas: XCUIElement { app.scrollViews["nib.canvas"].firstMatch }

    /// Explicit prerequisites; no test-name detection and no changes to the standard fixture.
    enum FixtureScenario: String { case standard, failedRender, largeDocument, unseenBoards }

    /// Reject hidden SwiftUI menu copies before asking AX for an activation point (zero frames can raise).
    func hasVisibleFrame(_ element: XCUIElement, in viewport: CGRect? = nil) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let visible = frame.intersection(viewport ?? app.windows.firstMatch.frame)
        return !frame.isNull && !frame.isInfinite && !visible.isNull && visible.width > 1 && visible.height > 1
    }

    /// Exact, bounded matches only. Native editors precede their identically labelled captions.
    /// Offscreen matches remain available to revealFormElement so it can find the actual containing form.
    func findControl(_ name: String, type: XCUIElement.ElementType = .any,
                     actionable: Bool = true, in scope: XCUIElement? = nil) -> XCUIElement? {
        let types: [XCUIElement.ElementType] = type == .any
            ? [.textField, .textView, .searchField, .switch, .button, .slider, .cell,
               .segmentedControl, .staticText, .other, .any] : [type]
        let predicate = NSPredicate(format:
            "(identifier == %@ OR label == %@ OR placeholderValue == %@) AND (NOT identifier BEGINSWITH 'tool.' OR identifier == %@)",
            name, name, name, name)
        let roots: [XCUIElement]
        if let scope { roots = [scope] }
        else {
            // UIKit colour editors and native sheets take precedence over retained custom popover trees.
            roots = [app.otherElements["UIColorPicker"].firstMatch, app.sheets.firstMatch,
                     app.descendants(matching: .popover).firstMatch].filter { $0.exists } + [app]
        }
        for root in roots {
            for kind in types {
                let matches = root.descendants(matching: kind).matching(predicate)
                let first = matches.firstMatch
                guard first.exists else { continue }
                if !actionable { return first }
                if hasVisibleFrame(first), !first.isEnabled || first.isHittable { return first }
                // Duplicate command labels occur in retained/hidden menus. Never enumerate the whole tree.
                for index in 1..<max(1, min(matches.count, 8)) {
                    let element = matches.element(boundBy: index)
                    if hasVisibleFrame(element), !element.isEnabled || element.isHittable { return element }
                }
            }
        }
        return nil
    }

    func requireControl(_ name: String, type: XCUIElement.ElementType = .any,
                        scroll: Bool = false, timeout: TimeInterval = 3) throws -> XCUIElement {
        if let found = findControl(name, type: type) { return found }
        if scroll, let target = findControl(name, type: type, actionable: false) {
            revealFormElement(target)
            if let found = findControl(name, type: type) { return found }
        }
        var found: XCUIElement?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            found = findControl(name, type: type)
            return found != nil
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed, let found else {
            throw Failure.message("Missing hittable control: \(name)\n\(app.debugDescription)")
        }
        return found
    }

    /// Waits for a target in its actual form, searching both directions until the visible rows stop changing.
    /// Existing callers pass lazy firstMatch queries; the closure overload also supports fresh section-scoped queries.
    func revealFormElement(_ element: XCUIElement) { revealFormElement { element } }

    /// Reacquires the target after each scroll and stops at a repeated visible range, avoiding stale virtualized indices.
    func revealFormElement(in form: XCUIElement? = nil, target: () -> XCUIElement) {
        let initial = target()
        if form == nil, hasVisibleFrame(initial), initial.isHittable,
           app.windows.firstMatch.frame.contains(CGPoint(x: initial.frame.midX, y: initial.frame.midY)) { return }
        if let form, hasVisibleFrame(initial, in: form.frame) && initial.isHittable,
           form.frame.contains(CGPoint(x: initial.frame.midX, y: initial.frame.midY)) { return }
        let containers = (app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex).filter {
                $0.identifier != "nib.canvas" && $0.frame.height > 100 && $0.frame.width > 200
                    && app.windows.firstMatch.frame.intersects($0.frame)
                    && ($0.isHittable || [.collectionView, .table].contains($0.elementType))
            }
        let initialSnapshot = initial.exists ? (try? initial.snapshot()) : nil
        let containing = containers.filter { list in
            guard let initialSnapshot else { return false }
            return list.descendants(matching: initialSnapshot.elementType).matching(NSPredicate(
                format: "identifier == %@ AND label == %@", initialSnapshot.identifier, initialSnapshot.label)).firstMatch.exists
        }
        guard let list = form ?? containing.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            ?? containers.max(by: { $0.frame.minX < $1.frame.minX }) else { return }
        let firstDown = initial.exists && initial.frame.midY < list.frame.midY
        for down in [firstDown, !firstDown] {
            var visited = Set<String>()
            for _ in 0..<8 {
                let element = target()
                let obstructions = app.keyboards.allElementsBoundByIndex.map(\.frame)
                    + app.otherElements.matching(identifier: "inputAssistantView").allElementsBoundByIndex.map(\.frame)
                guard let viewport = NibUITestScrollGeometry.viewport(
                    scroll: list.frame, window: app.windows.firstMatch.frame, obstructions: obstructions) else { return }
                if hasVisibleFrame(element, in: viewport) && element.isHittable && viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
                // One snapshot supplies the visible range; querying every row attribute separately can itself time out.
                guard let snapshot = try? list.snapshot() else { return }
                let signature = formVisibleRange(snapshot, viewport: viewport).joined(separator: "\n")
                if !visited.insert(signature).inserted { break }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                // Custom pen forms put sliders across the centre. Their 16-point content inset is scrollable;
                // native grouped lists instead need a row touch, away from the trailing switch.
                let x = [.collectionView, .table].contains(list.elementType)
                    ? viewport.midX : viewport.minX + 1
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
    private static var displayRects: [Int: CGRect] = [:]

    static func displayRect() -> CGRect {
        let orientation = XCUIDevice.shared.orientation
        if let cached = displayRects[orientation.rawValue] { return cached }
        let image = XCUIScreen.main.screenshot().image
        let scale = image.scale > 1 ? CGFloat(1) : UIScreen.main.scale
        let rect = CGRect(origin: .zero, size: CGSize(width: image.size.width / scale, height: image.size.height / scale))
        // Never poison the cache with an image captured during an orientation transition or face-up/unknown state.
        if (orientation.isLandscape && rect.width > rect.height) || (orientation.isPortrait && rect.height > rect.width) {
            displayRects[orientation.rawValue] = rect
        }
        return rect
    }

    /// Waits for the main window to cover the physical display before any orientation assertion.
    /// Fixture data resets do not reset iPadOS window placement left by an earlier gesture.
    func establishFullScreen(allowFixtureRelaunch: Bool = false) throws {
        if app.state != .runningForeground { app.activate() }
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
        func waitForPlacement(_ timeout: TimeInterval) -> Bool {
            if fillsScreen() { return true }
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                fillsScreen()
            }, object: nil)], timeout: timeout) == .completed
        }
        func expandWindow() -> Bool {
            let controls = system.buttons.matching(identifier: "window-controls:app.nib.Nib").firstMatch
            let named = system.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Window Controls, Nib'")).firstMatch
            let opener = controls.exists ? controls : named
            if opener.exists && opener.isHittable { opener.tap() }
            let fullScreen = system.buttons.matching(NSPredicate(
                format: "label ==[c] 'Full Screen' OR label ==[c] 'Enter Full Screen'")).firstMatch
            let menuItem = system.menuItems.matching(NSPredicate(
                format: "label ==[c] 'Full Screen' OR label ==[c] 'Enter Full Screen'")).firstMatch
            let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (fullScreen.exists && fullScreen.isHittable) || (menuItem.exists && menuItem.isHittable)
            }, object: nil)
            if XCTWaiter.wait(for: [menuReady], timeout: 3) == .completed {
                if fullScreen.exists && fullScreen.isHittable { fullScreen.tap() } else { menuItem.tap() }
                return waitForPlacement(5)
            }
            return fillsScreen()
        }
        if expandWindow() { return }
        // Only fixture setup may reset the scene. Mid-test orientation/restoration checks must preserve the document.
        if allowFixtureRelaunch && app.launchArguments.contains("-NibUITestFixture") {
            recordDiagnostics("Full-screen recovery needs fixture relaunch", facts: system.debugDescription)
            app.terminate()
            app.launch()
            _ = try waitForState(timeout: 30) { $0.screen == "library" }
            if waitForPlacement(3) || expandWindow() { return }
        }
        throw Failure.message("Full-screen recovery failed: display \(screen), window \(app.windows.firstMatch.frame)\n\(system.debugDescription)\n\(app.debugDescription)")
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
        guard (more.isHittable && colour.isHittable) || XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            throw Failure.message("Palette separator grip needs visible More tools and Colour 1")
        }
        let before = app.windows.firstMatch.frame
        let a = more.frame, b = colour.frame
        let vertical = abs(a.midY - b.midY) > abs(a.midX - b.midX)
        let leading = vertical ? min(a.maxY, b.maxY) : min(a.maxX, b.maxX)
        let trailing = vertical ? max(a.minY, b.minY) : max(a.minX, b.minX)
        let gap = trailing - leading
        let crossMin = vertical ? max(a.minX, b.minX) : max(a.minY, b.minY)
        let crossMax = vertical ? min(a.maxX, b.maxX) : min(a.maxY, b.maxY)
        let separator = vertical
            ? CGRect(x: crossMin, y: leading, width: max(0, crossMax - crossMin), height: max(0, gap))
            : CGRect(x: leading, y: crossMin, width: max(0, gap), height: max(0, crossMax - crossMin))
        let midpoint = CGPoint(x: separator.midX, y: separator.midY)
        // The canvas and decorative leaf Other/Image nodes cover this gap in AX but are not palette controls.
        // Bind the actual Tools container to both anchors, and traverse one immutable subtree snapshot.
        let toolsLabel = NSPredicate(format: "label == 'Tools'")
        let typedPalette = app.otherElements.matching(toolsLabel).firstMatch
        let palette = typedPalette.exists ? typedPalette
            : app.descendants(matching: .any).matching(toolsLabel).firstMatch
        guard palette.exists else { throw Failure.message("Palette Tools container missing") }
        let snapshot = try palette.snapshot()
        let paletteFrame = snapshot.frame
        guard paletteFrame.contains(a), paletteFrame.contains(b) else {
            throw Failure.message("Palette container does not contain both live anchors")
        }
        func targets(_ node: XCUIElementSnapshot) -> [(identifier: String, label: String, frame: CGRect)] {
            let actionable: [XCUIElement.ElementType] = [.button, .switch, .slider, .textField, .cell]
            if actionable.contains(node.elementType)
                || (node.children.isEmpty && (node.identifier.hasPrefix("cmd.") || node.identifier.hasPrefix("tool."))) {
                return [(node.identifier, node.label, node.frame)]
            }
            return node.children.flatMap { targets($0) }
        }
        let controls = targets(snapshot)
        let visible = before.insetBy(dx: 8, dy: 8)
        func clear(_ point: CGPoint) -> Bool {
            visible.contains(point) && paletteFrame.contains(point)
                && !controls.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
        }
        // Test the actual contact, not the entire gap rectangle: adjacent button edges touch that rectangle.
        let adjacent = gap >= 4 && gap <= 40 && crossMax - crossMin >= 8 && clear(midpoint)
        var chosen: CGPoint? = adjacent ? midpoint : nil
        if chosen == nil {
            let edges = vertical
                ? [CGPoint(x: paletteFrame.midX, y: paletteFrame.minY + 6), CGPoint(x: paletteFrame.midX, y: paletteFrame.maxY - 6)]
                : [CGPoint(x: paletteFrame.minX + 6, y: paletteFrame.midY), CGPoint(x: paletteFrame.maxX - 6, y: paletteFrame.midY)]
            let thickness = vertical ? paletteFrame.width : paletteFrame.height
            let anchorThickness = vertical ? max(a.width, b.width) : max(a.height, b.height)
            if thickness <= anchorThickness + 16 { chosen = edges.first(where: clear) }
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
        try establishFullScreen(allowFixtureRelaunch: true)
        // Re-request orientation only if the device or this scene still disagrees; SpringBoard's orientation
        // alone does not prove that the launched scene has rotated.
        if XCUIDevice.shared.orientation != .landscapeLeft || app.windows.firstMatch.frame.width <= app.windows.firstMatch.frame.height {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            // The application's union frame includes transient system windows.
            // Validate the main app window using one fresh snapshot per poll.
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            return frame.width > frame.height && frame.height > 0
        }, object: nil)
        let frame = app.windows.firstMatch.frame
        guard (frame.width > frame.height && frame.height > 0)
            || XCTWaiter.wait(for: [landscape], timeout: 30) == .completed else {
            throw Failure.message("Nib's launched scene did not reach landscape")
        }
        try establishFullScreen(allowFixtureRelaunch: true)
        _ = try waitForState { $0.screen == "library" }
    }

    /// Activates this scene, waits for non-text focus without editing/navigating, and verifies the chord's action.
    /// The activity records requested modifiers beside the shell's existing Key routing / Library key diagnostic logs.
    func chord(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags,
               verifying postcondition: () throws -> Void) throws {
        let before = try state()
        guard !app.keyboards.firstMatch.exists else {
            throw Failure.message("Dismiss text editing explicitly before delivering a global chord")
        }
        let window = app.windows.firstMatch
        let recipient = try globalKeyboardRecipient()
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
            // Type into the verified responder, not a caption or an arbitrary unfocused application.
            recipient.typeKey(key, modifierFlags: modifiers)
            do { try postcondition() }
            catch {
                recordDiagnostics("Chord postcondition failed", facts: "key=\(key) modifiers=\(modifiers.rawValue)")
                throw error
            }
        }
    }

    /// AX exposes keyboard focus separately from hittability. A hidden software keyboard is not proof of focus.
    /// ShellViewController keeps library keys; CanvasKeyboardResponder keeps document keys and forwards shell keys.
    private func globalKeyboardRecipient() throws -> XCUIElement {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        func nonTextFocus() -> Bool {
            guard focused.exists else { return false }
            return ![XCUIElement.ElementType.textField, .textView, .searchField, .secureTextField].contains(focused.elementType)
        }
        if nonTextFocus() { return focused }
        if app.state != .runningForeground { app.activate() }

        func tapInertHeader(in surface: XCUIElement, modal: Bool) throws {
            // One snapshot avoids per-control AX round trips. Conservatively exclude every control frame,
            // including all button frames, so no hittable library button can become the focus target.
            let snapshot = try surface.snapshot()
            let interactive: [XCUIElement.ElementType] = [.button, .cell, .link, .switch, .slider,
                .segmentedControl, .textField, .textView, .searchField, .secureTextField, .picker, .pickerWheel]
            func occupiedFrames(_ node: XCUIElementSnapshot) -> [CGRect] {
                let own = interactive.contains(node.elementType) ? [node.frame] : []
                return own + node.children.flatMap { occupiedFrames($0) }
            }
            let occupied = occupiedFrames(snapshot)
            let visible = snapshot.frame.intersection(app.windows.firstMatch.frame)
            guard !visible.isNull, !visible.isInfinite, visible.width > 16, visible.height > 16 else {
                throw Failure.message("No visible surface for keyboard focus tap")
            }
            let offsets: [CGFloat] = modal ? [24, 40, 56] : [70, 56, 40]
            let fractions: [CGFloat] = [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8]
            let points = offsets.flatMap { offset in
                fractions.map { fraction in
                    CGPoint(x: visible.minX + visible.width * fraction, y: visible.minY + offset)
                }
            }
            guard let point = points.first(where: { point in
                visible.insetBy(dx: 8, dy: 8).contains(point)
                    && !occupied.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
            }) else { throw Failure.message("No inert header focus target inside the presented surface") }
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        }

        // A tap behind a modal can hit its dimming view and dismiss it. Keep focus preparation inside
        // the foremost presented surface; if it has no inert header point, fail without tapping the desk.
        let surface = [app.alerts.firstMatch, app.descendants(matching: .popover).firstMatch,
                       app.sheets.firstMatch].first { hasVisibleFrame($0) }
        if let surface {
            try tapInertHeader(in: surface, modal: true)
        } else if canvas.exists {
            // Reach the real document responder chain outside paper and away from the side palette.
            coordinate(CGPoint(x: 0.18, y: 0.85)).tap()
        } else {
            // The shell's library tap recognizer schedules reclaimKeyFocusIfNeeded after a real window tap.
            try tapInertHeader(in: app.windows.firstMatch, modal: false)
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in nonTextFocus() }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 5) == .completed else {
            throw Failure.message("No non-text keyboard responder after scene focus tap\n\(app.debugDescription)")
        }
        return focused
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
                let button = source.buttons["Allow Paste"].firstMatch
                if button.exists && button.isHittable { return button }
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

    /// Exports the current share sheet to a uniquely named Files directory and waits for the real PNG bytes on disk.
    /// The runner only reads the export; it never reads a background UIPasteboard or generates an expected image.
    func saveSharedPNG() throws -> Data {
        var finished = false
        defer {
            if !finished { recordDiagnostics("Save to Files PNG export failed") }
        }
        let action = app.buttons["Save to Files"].firstMatch
        revealFormElement(action)
        guard action.waitForExistence(timeout: 10), action.isHittable else {
            throw Failure.message("PNG share sheet must offer Save to Files")
        }
        action.tap()
        let local = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        guard local.waitForExistence(timeout: 10), local.isHittable else { throw Failure.message("Files local provider missing") }
        local.tap()
        let nib = app.cells["Nib, Container"].firstMatch
        if nib.waitForExistence(timeout: 3) && nib.isHittable { nib.tap() }
        else {
            guard app.buttons["Nib, Actions Menu"].exists else { throw Failure.message("Export must target Nib Documents") }
        }
        let folder = "QA Screenshot " + UUID().uuidString
        let newFolder = app.buttons["New Folder"].firstMatch
        if !newFolder.isHittable { app.buttons["More"].firstMatch.tap() }
        guard newFolder.waitForExistence(timeout: 5), newFolder.isHittable else { throw Failure.message("Files New Folder missing") }
        newFolder.tap()
        try nameNewFilesFolder(folder)
        let entered = app.buttons[folder + ", Actions Menu"].firstMatch
        let directory = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in entered.exists || directory.exists }, object: nil)
        guard XCTWaiter.wait(for: [created], timeout: 8) == .completed else { throw Failure.message("Files did not create PNG destination") }
        if !entered.exists { directory.tap() }
        guard entered.waitForExistence(timeout: 8) else { throw Failure.message("Files must enter the unique PNG destination") }
        let save = app.buttons["Save"].firstMatch
        guard save.isEnabled && save.isHittable else { throw Failure.message("Files Save unavailable") }
        save.tap()
        // Unverified until simulator CI: Files labels and runner access to sibling app containers.
        // The native picker saves into the app container. The unique directory prevents stale exports matching.
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let destinations = try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Documents").appendingPathComponent(folder) }
        var bytes: Data?
        let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            for destination in destinations {
                let files = (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension.lowercased() == "png" {
                    if let data = try? Data(contentsOf: file), UIImage(data: data) != nil { bytes = data; return true }
                }
            }
            return false
        }, object: nil)
        guard XCTWaiter.wait(for: [exported], timeout: 15) == .completed, let bytes else {
            throw Failure.message("Save to Files must produce a decodable PNG in the unique destination")
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !entered.exists }, object: nil)
        guard XCTWaiter.wait(for: [dismissed], timeout: 8) == .completed else { throw Failure.message("Files must finish exporting") }
        finished = true
        return bytes
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
        guard field.exists else { return false }
        let identifier = field.identifier, label = field.label
        if !identifier.isEmpty || !label.isEmpty {
            let identity = !identifier.isEmpty ? NSPredicate(format: "identifier == %@", identifier)
                : NSPredicate(format: "label == %@", label)
            // Query the AX snapshot, never KVC-evaluate this SDK-dependent key on XCUIElement itself.
            let focused = app.descendants(matching: .any).matching(identity)
                .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            if focused.exists, focused.elementType == field.elementType, focused.frame == field.frame { return true }
        }
        return field.debugDescription.contains("Keyboard Focused")
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

    /// A focused field under a floating keypad can be non-hittable and still be the correct typing target.
    func textEditor(_ name: String, timeout: TimeInterval = 8) throws -> XCUIElement {
        var field: XCUIElement?
        func locate() -> Bool {
            for type in [XCUIElement.ElementType.textField, .textView, .searchField, .secureTextField] {
                if let found = findControl(name, type: type, actionable: false) { field = found; return true }
            }
            return false
        }
        if !locate() {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in locate() }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
                throw Failure.message("Missing native text editor: \(name)")
            }
        }
        guard let field else { throw Failure.message("Missing native text editor: \(name)") }
        try focusField(field)
        return field
    }

    /// Waits for native field focus without retapping an existing selection or moving focus to global chrome.
    func focusField(_ field: XCUIElement) throws {
        if isKeyboardFocused(field) { return }
        revealFormElement(field)
        guard hasVisibleFrame(field) && field.isHittable else { throw Failure.message("Native field cannot receive focus: \(field)") }
        field.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in isKeyboardFocused(field) }, object: nil)
        guard XCTWaiter.wait(for: [focused], timeout: 5) == .completed else {
            throw Failure.message("Native field did not gain keyboard focus: \(field.debugDescription)")
        }
    }

    /// Delivers modifiers while preserving native focus; callers verify the relevant text or formatting result.
    func nativeKey(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = .command, in field: XCUIElement) throws {
        try timedAction("Native key \(key), modifiers \(modifiers.rawValue)") {
            try focusField(field)
            field.typeKey(key, modifierFlags: modifiers)
        }
    }

    /// Waits for exact replacement, including empty fields, so a lost Select All cannot silently append text.
    func replaceNativeText(in field: XCUIElement, with text: String) throws {
        try nativeKey("a", in: field)
        timedAction("Native replacement delivery (\(text.count) characters)") {
            field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
        }
        try waitForNativeText(in: field, equals: text)
    }

    /// Waits for the native editor's actual text; a placeholder represents an empty value, not user content.
    func waitForNativeText(in field: XCUIElement, equals text: String) throws {
        func matches() -> Bool {
            guard let value = field.value as? String else { return false }
            return value == text || (text.isEmpty && value == field.placeholderValue)
        }
        if matches() { return }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in matches() }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            throw Failure.message("Native replacement mismatch: expected \(text.debugDescription), got \(String(describing: field.value))")
        }
    }

    /// Waits for native Cut and Copy availability, which requires a nonempty selection, without editing or undoing.
    /// The callers' rich-text/range assertions verify its extent; this probe preserves text, focus and selection.
    func verifyNativeSelection(in field: XCUIElement, fullText: String) throws {
        // iPad's input assistant exposes these even when a hardware shortcut does not present the edit menu.
        // Never accept cmd.clipboard.*: those controls describe Nib's object selection, not this native field.
        func available(_ title: String, assistant: String) -> Bool {
            let shortcut = app.buttons.matching(identifier: assistant).firstMatch
            if shortcut.exists && shortcut.isEnabled && shortcut.isHittable { return true }
            for type in [XCUIElement.ElementType.menuItem, .button] {
                let action = app.descendants(matching: type).matching(NSPredicate(
                    format: "label ==[c] %@ AND NOT (identifier BEGINSWITH 'cmd.')", title)).firstMatch
                if action.exists && action.isEnabled && action.isHittable { return true }
            }
            return false
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            isKeyboardFocused(field) && field.value as? String == fullText
                && available("Cut", assistant: "assistantCut") && available("Copy", assistant: "assistantCopy")
        }, object: nil)
        guard XCTWaiter.wait(for: [selected], timeout: 8) == .completed else {
            throw Failure.message("Native selection must enable Cut and Copy without changing text\n\(app.debugDescription)")
        }
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
        if let current = try readState(), matches(current) { return current }
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
        guard document.exists || document.waitForExistence(timeout: 15) else { throw Failure.message("Document missing: \(title); state: \(String(describing: probe.value))\n\(app.debugDescription)") }
        // The card's decorative accessibility group can also have a button trait.
        // Only the command-bearing outer button owns document navigation.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: document)
        guard (document.isHittable && document.isEnabled) || XCTWaiter.wait(for: [ready], timeout: 15) == .completed else { throw Failure.message("Document is not hittable: \(title)") }
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
            guard let control = findControl(identifier, type: .button), control.isEnabled else { return nil }
            return control
        }
        func menuHost(containing control: XCUIElement? = nil) -> XCUIElement? {
            (app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex)
                .filter { scroll in
                    guard scroll.identifier != "nib.canvas", scroll.isHittable else { return false }
                    let matches = scroll.buttons.matching(identifier: id)
                    if let control { return matches.allElementsBoundByIndex.contains { $0.frame == control.frame } }
                    return matches.count > 0
                }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        func revealInMenu() -> XCUICoordinate? {
            var visited = Set<String>()
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
                guard let snapshot = try? scroll.snapshot() else { return nil }
                let signature = formVisibleRange(snapshot, viewport: viewport).joined(separator: "\n")
                guard visited.insert(signature).inserted else { return nil }
                let target = scroll.buttons.matching(identifier: id).firstMatch
                let drag = NibUITestScrollGeometry.drag(in: viewport, toward: target.frame.midY)
                origin.withOffset(CGVector(dx: drag.start.x - app.frame.minX, dy: drag.start.y - app.frame.minY))
                    .press(forDuration: 0.01, thenDragTo: origin.withOffset(
                        CGVector(dx: drag.end.x - app.frame.minX, dy: drag.end.y - app.frame.minY)),
                        withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            return nil
        }
        // Common palette/history controls cannot be clipped by an overflow form; avoid discovering every scroll host.
        if id.hasPrefix("tool.") || ["cmd.edit.undo", "cmd.edit.redo", "cmd.window.showLibrary"].contains(id),
           let control = candidate(id) {
            control.tap(); return
        }
        if let control = revealInMenu() { control.tap(); return }
        for identifier in overflow {
            if let menu = candidate(identifier) {
                menu.tap()
                // The bud enters the accessibility tree before its scroll host is actionable.
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    candidate(id) != nil || menuHost() != nil
                }, object: nil)
                if candidate(id) == nil && menuHost() == nil { _ = XCTWaiter.wait(for: [ready], timeout: 5) }
                if let control = revealInMenu() { control.tap(); return }
                if menu.isHittable { menu.tap() }
            }
        }
        throw Failure.message("No enabled control \(id)\n\(app.debugDescription)")
    }

    func coordinate(_ point: CGPoint) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: point.x, dy: point.y))
    }

    /// Captures screen-point geometry at the action boundary so CI can distinguish gesture delivery from AX projection.
    func recordGeometry(_ name: String, touches: [CGPoint], selection: CGRect? = nil) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: "All frames and touches are screen points.\n"
                + "app=\(app.frame) window=\(app.windows.firstMatch.frame) canvas=\(canvas.frame)\n"
                + "touches=\(touches) selection=\(String(describing: selection))\n\(probe.value ?? "missing")")
            attachment.name = name; attachment.lifetime = .keepAlways; activity.add(attachment)
        }
    }

    /// Records monotonic timestamps before and after one UI action, including any XCTest idle wait in that action.
    /// The first attachment is emitted before touching AX so an idle stall still leaves a precise last-started action.
    @discardableResult
    func timedAction<T>(_ name: String, action: () throws -> T) rethrows -> T {
        try XCTContext.runActivity(named: name) { activity in
            let started = ProcessInfo.processInfo.systemUptime
            let start = XCTAttachment(string: "start uptime=\(started) wall=\(Date())")
            start.name = "action-start"; start.lifetime = .keepAlways; activity.add(start)
            defer {
                let end = XCTAttachment(string: "end uptime=\(ProcessInfo.processInfo.systemUptime) elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
                end.name = "action-end"; end.lifetime = .keepAlways; activity.add(end)
            }
            return try action()
        }
    }

    /// Captures the current screen, probe and AX tree at a named transition; no command or document mutation is injected.
    func recordDiagnostics(_ name: String, facts: String = "") {
        XCTContext.runActivity(named: name) { activity in
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = name + "-screen"; screen.lifetime = .keepAlways; activity.add(screen)
            let tree = XCTAttachment(string: "uptime=\(ProcessInfo.processInfo.systemUptime)\n\(facts)\n"
                + "probe=\(probe.value ?? "missing")\n\(app.debugDescription)")
            tree.name = name + "-state-and-tree"; tree.lifetime = .keepAlways; activity.add(tree)
        }
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
        recordGeometry("Pinch focal point and contact paths", touches: [coordinate(centre).screenPoint]
            + paths.flatMap { $0.map { coordinate($0).screenPoint } })
        try synthesize(paths, duration: duration)
    }
    func doubleTap(at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) { coordinate(point).doubleTap() }

    /// Keeps every touch in a small desk patch, never XCTest's automatically chosen window-edge hit points.
    func canvasMultiTap(touches: Int, taps: Int = 2) throws {
        guard (2...3).contains(touches), (1...2).contains(taps) else { throw Failure.message("Unsupported multi-tap") }
        let before = app.windows.firstMatch.frame
        let centre = coordinate(CGPoint(x: 0.18, y: 0.65)).screenPoint
        let points = (0..<touches).map { index in
            CGPoint(x: centre.x + CGFloat(index - 1) * 20, y: centre.y)
        }
        guard points.allSatisfy({ before.insetBy(dx: 60, dy: 60).contains($0) }) else {
            throw Failure.message("Multi-tap must stay clear of system window edges")
        }
        recordGeometry("Stationary multi-tap", touches: points)
        let done = XCTestExpectation(description: "Stationary multi-tap completed")
        var failure: Error?
        NibTouchPaths.tap(at: points.map { NSValue(cgPoint: $0) }, count: UInt(taps)) { error in
            failure = error; done.fulfill()
        }
        guard XCTWaiter.wait(for: [done], timeout: 10) == .completed else { throw Failure.message("Multi-tap timed out") }
        if let failure { throw failure }
        let after = app.windows.firstMatch.frame
        guard abs(after.minX - before.minX) <= 2, abs(after.minY - before.minY) <= 2,
              abs(after.width - before.width) <= 2, abs(after.height - before.height) <= 2 else {
            throw Failure.message("Multi-tap moved the app window: \(before) -> \(after)")
        }
    }

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
            var close: XCUIElement?
            for id in ["sheet.dismiss", "cmd.panel.close", "Cancel", "Done", "Close"] {
                if let found = findControl(id, type: .button), found.isEnabled { close = found; break }
            }
            if let close { close.tap(); continue }
            if let sheet = app.sheets.allElementsBoundByIndex.first(where: { hasVisibleFrame($0) && $0.isHittable }) {
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
