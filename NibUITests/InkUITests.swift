import XCTest
import UIKit

/// Ink acceptance coverage. Actions go through the real UI and Support/NibTouchPaths;
/// the QA probe is read-only. No bridge commands, injected strokes, or model mutations.
/// Owners: F007 pen, F008 presets, F009 highlighter, F010 eraser, F011 lasso,
/// F015 history, F030 recognition, F043 Pencil, F101 input, F006 zoom.
@MainActor
final class InkUITests: XCTestCase {
    private var ui: NibUI!
    private let line = [CGPoint(x: 0.40, y: 0.62), CGPoint(x: 0.60, y: 0.62)]
    private let inkRegion = CGRect(x: 0.36, y: 0.53, width: 0.29, height: 0.23)

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        try ui.launchFixture()
        try ui.openDocument("Physics — Motion")
        _ = try ui.waitForState { $0.pageCount == 4 && $0.strokeCountOnPage == 1 }
        try ui.selectTool("pen")
    }

    override func tearDownWithError() throws {
        if let ui {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(name)-screen"; shot.lifetime = .keepAlways; add(shot)
            let state = XCTAttachment(string: String(describing: ui.probe.value))
            state.name = "\(name)-nib.qa.state"; state.lifetime = .keepAlways; add(state)
            if testRun?.hasSucceeded == false {
                let tree = XCTAttachment(string: ui.app.debugDescription)
                tree.name = "\(name)-accessibility"; tree.lifetime = .keepAlways; add(tree)
            }
            ui.app.terminate()
        }
        ui = nil
    }

    // MARK: UI and observable-ink helpers

    private func wait(_ description: String, timeout: TimeInterval = 8,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail(description, file: file, line: line)
            throw NibUI.Failure.message(description)
        }
    }

    private func control(_ label: String, type: XCUIElement.ElementType = .any,
                         scroll: Bool = false) throws -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", label, label)
        let query = ui.app.descendants(matching: type).matching(predicate)
        for attempt in 0..<(scroll ? 12 : 2) {
            let matches = query.allElementsBoundByIndex.filter {
                ($0.isHittable || !$0.isEnabled) && (label.hasPrefix("tool.") || !$0.identifier.hasPrefix("tool."))
            }
            let interactive = matches.filter { [.button, .switch, .slider, .textField, .segmentedControl].contains($0.elementType) }
            // A settings choice can share its title with the tool behind the popover (Pencil, Highlighter,
            // Fountain Pen). Choose the actual option/filter, not the underlying palette selector.
            if let found = interactive.first(where: { !$0.identifier.hasPrefix("tool.") })
                ?? interactive.first ?? matches.first {
                // Native menus can remove their same-labelled wrapper after the first snapshot.
                // Rebind a unique typed element so an Any-query index does not become stale before tapping.
                let stable = ui.app.descendants(matching: found.elementType).matching(
                    NSPredicate(format: "identifier == %@ AND label == %@", found.identifier, found.label))
                return stable.count == 1 ? stable.firstMatch : found
            }
            if attempt == 0 { _ = query.firstMatch.waitForExistence(timeout: 3) }
            if scroll {
                let panels = scrollPanels
                // Prefer the target's own scroller. Settings has a navigation list alongside its detail list.
                let containing = panels.filter { $0.descendants(matching: type).matching(predicate).count > 0 }
                guard let panel = containing.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                    ?? panels.max(by: { $0.frame.minX < $1.frame.minX }) else { break }
                scrollPanel(panel, down: false)
            }
        }
        throw NibUI.Failure.message("Missing hittable control: \(label)\n\(ui.app.debugDescription)")
    }

    private func tap(_ label: String, scroll: Bool = false) throws {
        let element = try control(label, scroll: scroll)
        XCTAssertTrue(element.isEnabled, "\(label) must be enabled")
        element.tap()
    }

    private func settings(_ tool: String) throws {
        try ui.selectTool(tool)
        // Tapping the active tool opens its settings even when navigation has folded the options bar.
        try tap("tool." + tool)
        // Popover ScrollViews keep their offset when closed. Start at the type/mode grid each time.
        let topLabel: String
        switch tool {
        case "highlighter": topLabel = "Lemon"
        case "eraser": topLabel = "Precision"
        case "drawShape": topLabel = "Draw and Hold"
        default: topLabel = "Fountain Pen"
        }
        for _ in 0..<8 {
            let visible = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", topLabel))
                .allElementsBoundByIndex.contains { $0.isHittable && !$0.identifier.hasPrefix("tool.") && [XCUIElement.ElementType.button, .switch].contains($0.elementType) }
            if visible { return }
            guard let panel = ui.app.scrollViews.allElementsBoundByIndex.first(where: {
                $0.identifier != "nib.canvas" && $0.isHittable && $0.frame.width > 200 && $0.frame.width < 600 && $0.frame.height > 180
            }) else { break }
            scrollPanel(panel, down: true)
        }
    }

    private var scrollPanels: [XCUIElement] {
        (ui.app.scrollViews.allElementsBoundByIndex + ui.app.collectionViews.allElementsBoundByIndex + ui.app.tables.allElementsBoundByIndex).filter { panel in
            guard panel.identifier != "nib.canvas", panel.frame.height > 180, panel.frame.width > 200 else { return false }
            if panel.isHittable { return true }
            // DESIGN §14.8 puts settings in the right-hand inset grouped list. XCTest can
            // mark that container non-hittable while its visible rows accept input; dropping
            // it here makes the fallback repeatedly scroll the 220-point section sidebar.
            return [.collectionView, .table].contains(panel.elementType)
                && panel.buttons.allElementsBoundByIndex.contains { $0.isHittable }
        }
    }

    private func scrollPanel(_ panel: XCUIElement, down: Bool) {
        // The centre of a pen popover contains custom sliders which consume drag gestures.
        // Scroll from the panel's 16-point content padding, clear of every slider and toggle.
        // Native Settings lists inset their cells farther than that padding; their empty margin
        // does not scroll. Use a row's centre for those lists, away from the trailing switches.
        let x: CGFloat = [.collectionView, .table].contains(panel.elementType) ? 0.5 : 0.025
        let start = panel.coordinate(withNormalizedOffset: CGVector(dx: x, dy: down ? 0.2 : 0.8))
        let end = panel.coordinate(withNormalizedOffset: CGVector(dx: x, dy: down ? 0.8 : 0.2))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    }

    private func closePopover() {
        // Outside both paper and the floating palette. The popover's catcher consumes this tap.
        ui.coordinate(CGPoint(x: 0.95, y: 0.85)).tap()
    }

    private func cancelConfirmation() {
        // iPad presents confirmationDialog as a popover and omits its Cancel row; tapping outside cancels.
        if let cancel = ui.app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first(where: { $0.isHittable }) {
            cancel.tap()
        } else {
            closePopover()
        }
    }

    @discardableResult
    private func toggle(_ label: String, to enabled: Bool, scroll: Bool = true) throws -> XCUIElement {
        let element = try control(label, type: .switch, scroll: scroll)
        if (element.value as? String == "1") != enabled {
            // A native iPadOS toggle exposes a labelled row plus an unlabelled UISwitch child.
            // Tap the switch thumb itself; the row's centre can be plain text or clipped at a popover edge.
            let native = element.switches.firstMatch
            let target = native.exists ? native : element
            for _ in 0..<4 where scroll {
                guard let panel = scrollPanels
                    .filter({ $0.switches.matching(NSPredicate(format: "label == %@", label)).count > 0 })
                    .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { break }
                // XCTest marks a partly clipped switch hittable even when its centre is
                // outside the popover. DESIGN §10.6 makes that tap dismiss the popover.
                // Scroll the actual tap point into view before exercising the switch.
                let centre = CGPoint(x: target.frame.midX, y: target.frame.midY)
                if target.isHittable && panel.frame.insetBy(dx: 2, dy: 2).contains(centre) { break }
                scrollPanel(panel, down: centre.y < panel.frame.minY)
            }
            XCTAssertTrue(target.isHittable, "\(label) switch thumb must be visible")
            target.coordinate(withNormalizedOffset: CGVector(dx: native.exists ? 0.5 : 0.92, dy: 0.5)).tap()
        }
        try wait("\(label) must become \(enabled)") { (element.value as? String == "1") == enabled }
        return element
    }

    @discardableResult
    private func slider(_ label: String, to position: CGFloat) throws -> String {
        let element = try control(label, type: .slider, scroll: true)
        XCTAssertTrue(element.isEnabled, "\(label) should accept a drag")
        // These custom bead sliders expose an AX Slider but no UIKit min/max scrubber coordinates.
        // Drag the real track; adjust(toNormalizedSliderPosition:) cannot synthesize these controls.
        let before = String(describing: element.value)
        let fraction = (14 + position * max(1, element.frame.width - 28)) / element.frame.width
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.01,
            thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0)
        try wait("\(label) drag must change its visible value") { String(describing: element.value) != before }
        return String(describing: element.value)
    }

    private func draw(_ path: [CGPoint]? = nil) throws {
        let before = try ui.state()
        try ui.drawStroke(path ?? line)
        _ = try ui.waitForState(timeout: 12) {
            $0.strokeCountOnPage == before.strokeCountOnPage + 1 && $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.undoAvailable
        }
    }

    private func undo(to before: QAState) throws {
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState(timeout: 12) {
            $0.strokeCountOnPage == before.strokeCountOnPage && $0.itemCountOnPage == before.itemCountOnPage && $0.redoAvailable
        }
    }

    private var swatches: [XCUIElement] {
        let tool = (try? ui.state().tool) ?? "pen"
        let names = ["pen": "Pen", "pencil": "Pencil", "highlighter": "Highlighter", "tape": "Tape", "shape": "Shapes", "drawShape": "Draw Shape"]
        // The main palette mirrors quick inks using the same command ID. Count/edit only the slots in
        // the active tool's options bar; the mirrored buttons are not additional stored presets.
        let group = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", (names[tool] ?? tool) + " presets")).firstMatch
        return group.buttons.matching(identifier: "cmd.preset.select").allElementsBoundByIndex
            .filter { !$0.label.hasPrefix("Thickness ") }
    }

    private func width(_ slot: Int, edit: Bool = false) throws {
        let button = try control("Thickness \(slot)", type: .button)
        // Tap the visible cell centre, as Support/NibUI does for command controls. XCTest's
        // inferred hit point can land on the adjacent slot in this tightly packed options bar.
        if !button.isSelected { button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        try wait("Thickness \(slot) must be selected") { button.isSelected }
        if edit { button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    private func swatchMenu(_ action: String, index: Int = 0) throws {
        let button = try XCTUnwrap(swatches.indices.contains(index) ? swatches[index] : nil, "Missing colour slot \(index)")
        button.press(forDuration: 0.7)
        try tap(action)
    }

    private func chooseColour(_ name: String) throws {
        // Use the actual slot editor, avoiding a similarly named quick swatch behind it.
        let candidates = ui.app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != 'cmd.preset.select'", name)).allElementsBoundByIndex
        let option = try XCTUnwrap(candidates.last(where: { $0.isHittable }), "Missing palette colour \(name)")
        option.tap()
    }

    private func closeColourPicker() throws {
        // UIKit labels the colour picker's dismissal Close on current iPadOS, Done on older releases.
        if let close = ui.app.buttons.matching(NSPredicate(format: "label ==[c] 'close' OR label ==[c] 'done'")).allElementsBoundByIndex.last(where: { $0.isHittable }) {
            close.tap()
        } else {
            try tap("Done")
        }
    }

    private func hexField() throws -> XCUIElement {
        let labelled = ui.app.textFields.matching(NSPredicate(format: "label CONTAINS[c] 'hex' OR identifier CONTAINS[c] 'hex'")).firstMatch
        if labelled.exists && labelled.isHittable { return labelled }
        // iPadOS 26 gives the HEX caption an accessibility label, but leaves its adjacent field unlabelled.
        let caption = try control("sRGB Hex Color\u{00a0}#", type: .button)
        if let field = ui.app.textFields.allElementsBoundByIndex.first(where: {
            $0.isHittable && abs($0.frame.midY - caption.frame.midY) < 28 && $0.frame.minX >= caption.frame.maxX - 4
        }) {
            return field
        }
        throw NibUI.Failure.message("System colour picker must expose an editable HEX field beside its caption\n\(ui.app.debugDescription)")
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        @MainActor init(_ screenshot: XCUIScreenshot, screenSize: CGSize, rect: CGRect) throws {
            // Device capture avoids XCUIApplication's incorrectly cropped landscape image on this SDK.
            // UIImage.draw applies the capture's orientation before we address screen-coordinate pixels.
            let source = screenshot.image
            let format = UIGraphicsImageRendererFormat()
            format.scale = source.scale
            let image = UIGraphicsImageRenderer(size: screenSize, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: screenSize))
            }
            guard let cg = image.cgImage else { throw NibUI.Failure.message("Screen capture has no CGImage") }
            let scale = CGFloat(cg.width) / image.size.width
            let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                width: rect.width * scale, height: rect.height * scale)
            guard pixels.width > 0, pixels.height > 0, let crop = cg.cropping(to: pixels) else {
                throw NibUI.Failure.message("Screen/canvas geometry not ready: screen=\(screenSize), crop=\(pixels), image=\(cg.width)x\(cg.height)")
            }
            let pixelWidth = crop.width, pixelHeight = crop.height
            width = pixelWidth; height = pixelHeight
            var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            try buffer.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            }
            bytes = buffer
        }
        func changed(from old: Raster) -> Int {
            guard width == old.width && height == old.height else { return 0 }
            return stride(from: 0, to: bytes.count, by: 4).filter { i in
                (0..<3).map { abs(Int(bytes[i + $0]) - Int(old.bytes[i + $0])) }.max()! > 30
            }.count
        }
        var darkPixels: Int {
            var count = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let red = Int(bytes[i]), green = Int(bytes[i + 1]), blue = Int(bytes[i + 2])
                if red + green + blue < 420 { count += 1 }
            }
            return count
        }
    }

    private func raster(_ region: CGRect? = nil) throws -> Raster {
        let r = region ?? inkRegion, f = ui.canvas.frame
        return try Raster(XCUIScreen.main.screenshot(), screenSize: ui.app.frame.size, rect: CGRect(x: f.minX + r.minX * f.width, y: f.minY + r.minY * f.height,
                                                           width: r.width * f.width, height: r.height * f.height))
    }

    private func visibleInk(after before: Raster, region: CGRect? = nil) throws -> Raster {
        // The AX canvas frame can briefly be empty during the wet-to-committed transition.
        // Retry capture within the same visibility deadline instead of recording an XCTest unwrap failure.
        var result = before
        try wait("A committed stroke must produce visible ink in its drawn region", timeout: 10) {
            if let next = try? self.raster(region) { result = next }
            return result.changed(from: before) > 20
        }
        return result
    }

    private func assertNoNewInk(_ before: QAState) throws {
        // An inverted predicate catches delayed PencilKit commits, unlike an immediate count read.
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let s = try? ui.state() else { return true }
            return s.strokeCountOnPage != before.strokeCountOnPage || s.itemCountOnPage != before.itemCountOnPage
        }, object: nil)
        e.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 1.5), .completed, "Navigation/preview must not persist an item")
    }

    // MARK: Pen, graphite, styles and input settings

    func testBasicPenDrawsVisibleStrokeAndPersistsAfterReopening() throws {
        try ui.selectTool("lasso")
        try ui.selectTool("pen")
        let initial = try ui.state(), blank = try raster()
        try draw()
        let ink = try visibleInk(after: blank)
        try ui.tapCommand("window.showLibrary")
        try ui.openDocument("Physics — Motion")
        _ = try ui.waitForState { $0.strokeCountOnPage == initial.strokeCountOnPage + 1 }
        let reopened = try visibleInk(after: blank)
        XCTAssertLessThan(reopened.changed(from: ink), max(30, ink.changed(from: blank) / 5), "Persisted ink must retain its appearance")
    }

    func testPencilFromTypeGridDrawsGraphiteAndUndoRestoresPage() throws {
        try settings("pen"); try tap("Pencil")
        _ = try ui.waitForState { $0.tool == "pencil" }
        closePopover()
        let before = try ui.state(), blank = try raster()
        try draw(); _ = try visibleInk(after: blank)
        try undo(to: before)
    }

    func testPencilToolButtonDrawsVisibleGraphiteAndRedoRestoresIt() throws {
        try ui.selectTool("pencil")
        let before = try ui.state(), blank = try raster()
        try draw(); _ = try visibleInk(after: blank)
        try undo(to: before)
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState {
            $0.tool == "pencil" && $0.strokeCountOnPage == before.strokeCountOnPage + 1 && !$0.redoAvailable
        }
        _ = try visibleInk(after: blank)
    }

    func testPenStylesSelectFountainBallBrushAndAffectNewStrokes() throws {
        var images: [Raster] = []
        for title in ["Fountain Pen", "Ball Pen", "Brush Pen"] {
            try settings("pen"); try tap(title)
            // Selecting a type runs tool.select, which dismisses the popover. Reopen to inspect its settings.
            try settings("pen")
            let chosen = try control(title, type: .button)
            XCTAssertTrue(chosen.isSelected, "\(title) must be the active style")
            let pressure = try control("Pressure sensitivity", type: .slider, scroll: true)
            XCTAssertEqual(pressure.isEnabled, title != "Ball Pen", "Ball has constant width")
            closePopover()
            let before = try ui.state(), blank = try raster()
            try draw(); images.append(try visibleInk(after: blank)); try undo(to: before)
        }
        XCTAssertGreaterThan(images[0].changed(from: images[1]), 10, "Fountain and Ball must render distinct nibs")
        XCTAssertGreaterThan(images[1].changed(from: images[2]), 10, "Brush and Ball must render distinct nibs")
    }

    func testPressureSliderPersistsAndBallDisablesPressure() throws {
        try settings("pen")
        let value = try slider("Pressure sensitivity", to: 0.85)
        closePopover(); try settings("pen")
        XCTAssertEqual(String(describing: try control("Pressure sensitivity", type: .slider, scroll: true).value), value)
        closePopover(); try settings("pen"); try tap("Ball Pen"); try settings("pen")
        XCTAssertFalse(try control("Pressure sensitivity", type: .slider, scroll: true).isEnabled)
        closePopover()
        let before = try raster(); try draw(); _ = try visibleInk(after: before)
    }

    func testTipSharpnessAndFlatnessChangeNewFountainGeometry() throws {
        var images: [Raster] = []
        for value: CGFloat in [0.05, 0.95] {
            try settings("pen")
            _ = try slider("Tip sharpness", to: value)
            _ = try slider("Tip flatness", to: value)
            closePopover()
            let before = try ui.state(), blank = try raster()
            try draw(); images.append(try visibleInk(after: blank)); try undo(to: before)
        }
        XCTAssertGreaterThan(images[0].changed(from: images[1]), 10, "Tip controls must change the rendered nib, not only settings")
    }

    func testReactToRotationPersistsAndUnsupportedFingerKeepsFixedNib() throws {
        var images: [Raster] = []
        for enabled in [false, true] {
            try settings("pen"); try toggle("React to Pen Rotation", to: enabled)
            closePopover(); try settings("pen")
            XCTAssertEqual(try control("React to Pen Rotation", type: .switch, scroll: true).value as? String, enabled ? "1" : "0")
            closePopover()
            let before = try ui.state(), blank = try raster()
            try draw(); images.append(try visibleInk(after: blank)); try undo(to: before)
        }
        XCTAssertLessThan(images[0].changed(from: images[1]), 150, "Finger input has no barrel roll and must keep a fixed nib")
    }

    func testPenAndPencilStabilisationChangesInkAndKeepsEndpoints() throws {
        let zigzag = (0...12).map { i in CGPoint(x: 0.40 + Double(i) / 60, y: i % 2 == 0 ? 0.61 : 0.64) }
        for tool in ["pen", "pencil"] {
            var images: [Raster] = []
            for value: CGFloat in [0.01, 0.99] {
                try settings(tool); _ = try slider("Stabilisation", to: value); closePopover()
                let before = try ui.state(), blank = try raster()
                try draw(zigzag); images.append(try visibleInk(after: blank))
                for p in [zigzag.first!, zigzag.last!] {
                    let endpoint = CGRect(x: p.x - 0.01, y: p.y - 0.01, width: 0.02, height: 0.02)
                    XCTAssertGreaterThan(try raster(endpoint).darkPixels, 0, "Stabilisation must retain both endpoints")
                }
                try undo(to: before)
            }
            XCTAssertGreaterThan(images[0].changed(from: images[1]), 15, "\(tool) smoothing must affect the actual stroke")
        }
    }

    func testReduceLatencyToggleCommitsExactlyOneStrokePerDrag() throws {
        for enabled in [false, true] {
            try settings("pen"); try toggle("Reduce Latency", to: enabled); closePopover()
            let before = try ui.state(), blank = try raster()
            try draw([line[0], CGPoint(x: 0.5, y: 0.66), line[1]])
            _ = try visibleInk(after: blank)
            let committed = try ui.state(); try assertNoNewInk(committed)
            try undo(to: before)
        }
    }

    func testDisconnectStylusAllowsFingerInkAndReconnectRestoresNavigation() throws {
        try settings("pen"); try toggle("Disconnect Stylus", to: true); closePopover()
        try draw()
        try settings("pen"); try toggle("Disconnect Stylus", to: false); closePopover()
        let before = try ui.state()
        try ui.drawStroke([CGPoint(x: 0.5, y: 0.72), CGPoint(x: 0.5, y: 0.5)])
        _ = try ui.waitForState { abs($0.contentOffset.y - before.contentOffset.y) > 10 }
        try assertNoNewInk(before)
        try settings("pen"); try toggle("Disconnect Stylus", to: true); closePopover()
        try draw()
    }

    func testPinchZoomChangesValueAndClampsAtBothBoundsWithoutInk() throws {
        let initial = try ui.state()
        try ui.pinchZoom(scale: 1.7)
        _ = try ui.waitForState { $0.zoom > initial.zoom + 0.05 }
        // At larger scales paper covers the margin. NibUITests/README documents this SDK's lost
        // PencilKit contact on paper; use lasso for the remaining bounds gestures, preserving the real pinch.
        try ui.selectTool("lasso")
        for _ in 0..<6 { try ui.pinchZoom(scale: 2.5) }
        let upper = try ui.state()
        XCTAssertEqual(upper.zoom, 8, accuracy: 0.02, "Notebook zoom must reach its 800% maximum")
        try ui.pinchZoom(scale: 2.5)
        XCTAssertEqual(try ui.state().zoom, upper.zoom, accuracy: 0.02, "Zoom must saturate at its upper bound")
        for _ in 0..<8 { try ui.pinchZoom(scale: 0.3, velocity: -1) }
        let lower = try ui.state()
        XCTAssertEqual(lower.zoom, min(0.5, initial.zoom), accuracy: 0.02, "Notebook minimum is 50%, including fit if smaller")
        XCTAssertLessThan(lower.zoom, upper.zoom)
        try ui.pinchZoom(scale: 0.3, velocity: -1)
        XCTAssertEqual(try ui.state().zoom, lower.zoom, accuracy: 0.02, "Zoom must saturate at its lower bound")
        // Zooming out changes the active page under the viewport centre. The probe counts are
        // per-page: compare the original page, not an empty neighbouring page now in view.
        if try ui.state().page != initial.page {
            try ui.tapCommand("sidebar.toggle"); try tap("Page 1", scroll: true)
            _ = try ui.waitForState { $0.page == initial.page }
            try ui.tapCommand("sidebar.toggle")
        }
        XCTAssertEqual(try ui.state().undoAvailable, initial.undoAvailable,
                       "Pinching must not create an edit on any page")
        try assertNoNewInk(initial)
    }

    // MARK: Highlighter

    func testHighlighterIsTranslucentAndRemainsBelowPenInk() throws {
        let blank = try raster()
        try draw()
        let pen = try visibleInk(after: blank)
        try ui.selectTool("highlighter")
        try draw([CGPoint(x: 0.50, y: 0.56), CGPoint(x: 0.50, y: 0.70)])
        let highlighted = try visibleInk(after: pen)
        XCTAssertGreaterThan(highlighted.changed(from: blank), pen.changed(from: blank))
        XCTAssertGreaterThanOrEqual(highlighted.darkPixels, Int(Double(pen.darkPixels) * 0.9), "Highlight must not cover opaque pen ink")
        let onlyHighlight = try raster(CGRect(x: 0.49, y: 0.56, width: 0.02, height: 0.035))
        XCTAssertLessThan(onlyHighlight.darkPixels, onlyHighlight.width * onlyHighlight.height / 5, "Highlight must be translucent")
    }

    func testStraightLineHighlightingConvertsCurvedDragAndOffKeepsCurve() throws {
        let curve = [CGPoint(x: 0.4, y: 0.59), CGPoint(x: 0.45, y: 0.66), CGPoint(x: 0.5, y: 0.71), CGPoint(x: 0.55, y: 0.66), CGPoint(x: 0.6, y: 0.59)]
        let bend = CGRect(x: 0.47, y: 0.69, width: 0.06, height: 0.035)
        var changed: [Int] = []
        for enabled in [false, true] {
            try settings("highlighter"); try toggle("Straight line", to: enabled); closePopover()
            let before = try ui.state(), blank = try raster(bend)
            try draw(curve)
            changed.append(try raster(bend).changed(from: blank))
            try undo(to: before)
        }
        XCTAssertGreaterThan(changed[0], 20, "Freehand highlight must follow the bend")
        XCTAssertLessThan(changed[1], changed[0] / 4, "Straight highlight must leave the curved portion clear")
    }

    func testHighlighterWidthsColoursStabilisationAndDrawHoldPersist() throws {
        try ui.selectTool("highlighter")
        var areas: [Int] = []
        for slot in 1...3 {
            try width(slot)
            let before = try ui.state(), blank = try raster()
            try draw(); areas.append(try visibleInk(after: blank).changed(from: blank)); try undo(to: before)
        }
        XCTAssertLessThan(areas[0], areas[1], "8 pt < 14 pt highlight")
        XCTAssertLessThan(areas[1], areas[2], "14 pt < 20 pt highlight")
        for colour in ["Lemon", "Apricot", "Mint", "Sky", "Lilac", "Blush"] {
            try settings("highlighter"); try chooseColour(colour); closePopover()
            let before = try ui.state(), blank = try raster()
            try draw(); _ = try visibleInk(after: blank); try undo(to: before)
            try settings("highlighter")
            XCTAssertTrue(try control(colour, type: .button).isSelected, "\(colour) must persist")
            closePopover()
        }
        try settings("highlighter")
        _ = try slider("Thickness", to: 0.7)
        let smoothing = try slider("Stabilisation", to: 0.8)
        try toggle("Draw and hold", to: false); closePopover()
        try settings("highlighter")
        XCTAssertEqual(String(describing: try control("Stabilisation", type: .slider, scroll: true).value), smoothing)
        XCTAssertEqual(try control("Draw and hold", type: .switch, scroll: true).value as? String, "0")
        closePopover(); try draw()
    }

    func testHighlighterDrawHoldToggleChangesSubsequentHeldStroke() throws {
        for enabled in [false, true] {
            try settings("highlighter")
            try toggle("Draw and hold", to: enabled); closePopover()
            let before = try ui.state(), blank = try raster()
            try heldPath(line)
            _ = try ui.waitForState {
                $0.itemCountOnPage == before.itemCountOnPage + 1 &&
                $0.strokeCountOnPage == before.strokeCountOnPage + (enabled ? 0 : 1)
            }
            _ = try visibleInk(after: blank)
            try undo(to: before)
        }
    }

    func testHighlighterStabilisationAndCustomWidthChangeRenderedInk() throws {
        let zigzag = (0...12).map { i in CGPoint(x: 0.40 + Double(i) / 60, y: i % 2 == 0 ? 0.61 : 0.64) }
        var smoothed: [Raster] = []
        for position: CGFloat in [0.01, 0.99] {
            try settings("highlighter")
            _ = try slider("Stabilisation", to: position); closePopover()
            let before = try ui.state(), blank = try raster()
            try draw(zigzag); smoothed.append(try visibleInk(after: blank)); try undo(to: before)
        }
        XCTAssertGreaterThan(smoothed[0].changed(from: smoothed[1]), 20, "Highlighter smoothing must change the drawn path")
        var areas: [Int] = []
        for position: CGFloat in [0.15, 0.85] {
            try settings("highlighter")
            let widthValue = try slider("Thickness", to: position); closePopover()
            try settings("highlighter")
            XCTAssertEqual(String(describing: try control("Thickness", type: .slider, scroll: true).value), widthValue)
            closePopover()
            let before = try ui.state(), blank = try raster()
            try draw(); areas.append(try visibleInk(after: blank).changed(from: blank)); try undo(to: before)
        }
        XCTAssertGreaterThan(areas[1], areas[0], "Larger custom highlighter width must cover more paper")
    }

    func testHighlighterPresetWidthsMatchEightFourteenTwentyPointDesign() throws {
        // DESIGN §14.3 and the requested controls specify 8/14/20 pt. CONTRACTS' default model
        // currently lists 8/12/18; keep the requested visible-UI contract explicit rather than hiding that conflict.
        try ui.selectTool("highlighter")
        for (index, points) in [8.0, 14.0, 20.0].enumerated() {
            try width(index + 1)
            let before = try ui.state(), blank = try raster()
            try draw(); _ = try visibleInk(after: blank)
            let expected = String(format: "%.2f", points * 25.4 / 72)
            let value = String(describing: try control("Thickness \(index + 1)", type: .button).value)
            XCTAssertTrue(value.contains(expected), "DESIGN §14.3 requires \(points) pt (\(expected) mm), got \(value)")
            try undo(to: before)
        }
    }

    func testHighlighterCustomColourPersistsAndDrawsTranslucentInk() throws {
        try settings("highlighter"); try tap("Custom…")
        try tap("Spectrum")
        // The system colour field is a real two-dimensional control, selected by its accessibility label.
        let spectrum = ui.app.otherElements.matching(NSPredicate(format: "label ==[c] 'Color Spectrum'")).firstMatch
        XCTAssertTrue(spectrum.waitForExistence(timeout: 5) && spectrum.isHittable)
        spectrum.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.35)).tap()
        try closeColourPicker()
        closePopover()
        let selected = try XCTUnwrap(swatches.first(where: \.isSelected)).label
        let blank = try raster(); try draw()
        let ink = try visibleInk(after: blank)
        XCTAssertLessThan(ink.darkPixels, ink.width * ink.height / 5)
        try ui.selectTool("pen"); try ui.selectTool("highlighter")
        XCTAssertEqual(swatches.first(where: \.isSelected)?.label, selected)
    }

    // MARK: Presets

    func testQuickColourSelectionChangesInkAndIsIndependentPerTool() throws {
        let original = swatches.map(\.label)
        XCTAssertGreaterThanOrEqual(original.count, 3)
        var images: [Raster] = []
        for index in [0, 1, 2] {
            let button = swatches[index]
            if !button.isSelected { button.tap() }
            XCTAssertTrue(button.isSelected)
            let before = try ui.state(), blank = try raster()
            try draw(); images.append(try visibleInk(after: blank)); try undo(to: before)
        }
        XCTAssertGreaterThan(images[0].changed(from: images[1]), 15)
        XCTAssertGreaterThan(images[1].changed(from: images[2]), 15)
        let selected = try XCTUnwrap(swatches.first(where: \.isSelected)).label
        try ui.selectTool("highlighter"); swatches[1].tap(); try draw()
        try ui.selectTool("pen")
        XCTAssertEqual(swatches.map(\.label), original)
        XCTAssertEqual(swatches.first(where: \.isSelected)?.label, selected)
    }

    func testThicknessSlotsChangeRenderedWidth() throws {
        var areas: [Int] = []
        for slot in 1...3 {
            try width(slot)
            let before = try ui.state(), blank = try raster()
            try draw(); areas.append(try visibleInk(after: blank).changed(from: blank)); try undo(to: before)
        }
        XCTAssertLessThan(areas[0], areas[1]); XCTAssertLessThan(areas[1], areas[2])
    }

    func testWidthSliderAndSolidDashedDottedPersistAndRender() throws {
        var images: [Raster] = []
        for pattern in ["Solid", "Dashed", "Dotted"] {
            try width(2, edit: true)
            if pattern == "Solid" { _ = try slider("Thickness", to: 0.65) }
            try tap(pattern)
            XCTAssertTrue(try control(pattern, type: .button).isSelected)
            closePopover()
            let value = String(describing: try control("Thickness 2", type: .button).value)
            if pattern != "Solid" { XCTAssertTrue(value.contains(pattern), "Slot must retain \(pattern)") }
            let before = try ui.state(), blank = try raster()
            try draw(); images.append(try visibleInk(after: blank)); try undo(to: before)
            try ui.selectTool("highlighter"); try ui.selectTool("pen")
            XCTAssertEqual(String(describing: try control("Thickness 2", type: .button).value), value)
        }
        XCTAssertGreaterThan(images[0].changed(from: images[1]), 20, "Dashed must differ from solid")
        XCTAssertGreaterThan(images[1].changed(from: images[2]), 20, "Dotted must differ from dashed")
    }

    func testChangeColourPaletteUpdatesExistingSlotAndNextStroke() throws {
        let count = swatches.count
        try swatchMenu("Change Colour")
        try chooseColour("Vermilion"); closePopover()
        XCTAssertEqual(swatches.count, count)
        XCTAssertEqual(swatches[0].label, "Vermilion")
        if !swatches[0].isSelected { swatches[0].tap() }
        let blank = try raster(); try draw(); _ = try visibleInk(after: blank)
        try ui.selectTool("highlighter"); try ui.selectTool("pen")
        XCTAssertEqual(swatches[0].label, "Vermilion")
    }

    func testCustomColourValidHexUpdatesSlotAndInvalidHexIsRejected() throws {
        try swatchMenu("Change Colour"); try tap("Custom Colour")
        try tap("Sliders")
        let hex = try hexField()
        hex.tap(); ui.app.typeKey("a", modifierFlags: .command); hex.typeText("D03080")
        try closeColourPicker()
        closePopover()
        XCTAssertTrue(swatches[0].label.uppercased().contains("D03080"), "Valid HEX must update the edited slot")
        let valid = swatches[0].label
        try swatchMenu("Change Colour"); try tap("Custom Colour"); try tap("Sliders")
        let invalid = try hexField()
        invalid.tap(); ui.app.typeKey("a", modifierFlags: .command); invalid.typeText("ZZZZZZ")
        try closeColourPicker(); closePopover()
        XCTAssertEqual(swatches[0].label, valid, "Invalid HEX must not overwrite a valid colour")
        let blank = try raster(); try draw(); _ = try visibleInk(after: blank)
    }

    func testPageEyedropperSelectsSampleWithoutDrawingAnItem() throws {
        let before = try ui.state()
        // Choose a visibly white paper pixel between the ruled lines, not a presumed template coordinate.
        var paperPoint: CGPoint?
        for offset in 0..<8 {
            let point = CGPoint(x: 0.50, y: 0.68 + Double(offset) * 0.003)
            let pixels = try raster(CGRect(x: point.x, y: point.y, width: 0.001, height: 0.001))
            if pixels.bytes.prefix(3).allSatisfy({ $0 > 250 }) { paperPoint = point; break }
        }
        let sample = try XCTUnwrap(paperPoint, "Fixture must provide a visible white paper sample")
        try swatchMenu("Change Colour"); try tap("Pick Colour from Page")
        try ui.drawStroke([CGPoint(x: sample.x - 0.015, y: sample.y), sample], duration: 0.6)
        try wait("Eyedropper must replace the slot with the sampled paper colour") {
            guard let label = self.swatches.first?.label.uppercased() else { return false }
            if label == "CHALK" || label == "WHITE" { return true }
            guard let hex = label.split(separator: "#").last, hex.count >= 6,
                  let rgb = Int(hex.prefix(6), radix: 16) else { return false }
            return ((rgb >> 16) & 255) >= 245 && ((rgb >> 8) & 255) >= 245 && (rgb & 255) >= 245
        }
        try assertNoNewInk(before)
    }

    func testAddColourPreservesExistingSlotsAndStopsAtTwelve() throws {
        let original = swatches.map(\.label)
        for count in original.count..<12 {
            try tap("Add Colour"); try chooseColour(count % 2 == 0 ? "Vermilion" : "Moss")
            closePopover()
            try wait("Add Colour must append exactly one slot") { self.swatches.count == count + 1 }
            XCTAssertEqual(Array(swatches.prefix(original.count).map(\.label)), original)
        }
        XCTAssertFalse(ui.app.buttons["Add Colour"].isHittable, "A thirteenth slot must not be offered")
        try ui.selectTool("highlighter"); try ui.selectTool("pen")
        XCTAssertEqual(swatches.count, 12)
        // CONTRACTS KeyCommandRouting: notebook-specific preset keys beat the unrestricted pencil key 2.
        for index in 0..<10 {
            ui.app.typeKey(index == 9 ? "0" : String(index + 1), modifierFlags: [])
            try wait("Digit key must select colour slot \(index + 1)") { self.swatches[index].isSelected }
            XCTAssertEqual(try ui.state().tool, "pen", "Preset arbitration must not unexpectedly select pencil")
            let before = try ui.state(), blank = try raster()
            try draw(); _ = try visibleInk(after: blank); try undo(to: before)
        }
    }

    func testRemoveColourRemovesSelectedSlotButKeepsAtLeastOne() throws {
        let original = swatches.map(\.label)
        if !swatches[1].isSelected { swatches[1].tap() }
        try swatchMenu("Remove Colour", index: 1)
        try wait("Remove Colour must remove exactly the selected slot") { self.swatches.count == original.count - 1 }
        XCTAssertEqual(swatches.map(\.label), [original[0]] + Array(original.dropFirst(2)))
        while swatches.count > 1 { try swatchMenu("Remove Colour") }
        swatches[0].press(forDuration: 0.7)
        XCTAssertFalse(ui.app.buttons["Remove Colour"].exists, "The final swatch cannot be removed")
        closePopover()
        XCTAssertEqual(swatches.count, 1)
        try draw()
    }

    func testRearrangeColoursDragPersistsOrderAndActiveColour() throws {
        let original = swatches.map(\.label)
        if !swatches[0].isSelected { swatches[0].tap() }
        try swatchMenu("Rearrange Colours")
        let slots = ui.app.buttons.matching(identifier: "cmd.preset.removeSwatch")
        XCTAssertEqual(slots.count, original.count)
        slots.element(boundBy: 0).press(forDuration: 0.8, thenDragTo: slots.element(boundBy: 2))
        try tap("Done")
        let expected = [original[1], original[2], original[0]] + Array(original.dropFirst(3))
        try wait("Dragging a swatch must reorder the slots") { self.swatches.map(\.label) == expected }
        XCTAssertEqual(swatches.first(where: \.isSelected)?.label, original[0])
        try ui.selectTool("highlighter"); try ui.selectTool("pen")
        XCTAssertEqual(swatches.map(\.label), expected)
        try draw()
    }

    func testRestoreDefaultsCancelPreservesAndConfirmResetsOnlySelectedTool() throws {
        let defaults = swatches.map(\.label)
        let defaultWidth = String(describing: try control("Thickness 2", type: .button).value)
        try width(2, edit: true)
        _ = try slider("Thickness", to: 0.8)
        try tap("Dashed"); closePopover()
        let customWidth = String(describing: try control("Thickness 2", type: .button).value)
        XCTAssertNotEqual(customWidth, defaultWidth)
        try swatchMenu("Change Colour"); try chooseColour("Vermilion"); closePopover()
        let custom = swatches.map(\.label)
        try ui.selectTool("highlighter")
        try swatchMenu("Change Colour"); try chooseColour("Lilac"); closePopover()
        let highlighter = swatches.map(\.label)
        try ui.selectTool("pen")
        try swatchMenu("Restore Default Presets"); cancelConfirmation()
        XCTAssertEqual(swatches.map(\.label), custom)
        XCTAssertEqual(String(describing: try control("Thickness 2", type: .button).value), customWidth,
                       "Cancel must preserve customised width and pattern as well as colours")
        try swatchMenu("Restore Default Presets"); try tap("cmd.preset.reset")
        try wait("Confirmed reset must restore pen defaults") { self.swatches.map(\.label) == defaults }
        XCTAssertEqual(String(describing: try control("Thickness 2", type: .button).value), defaultWidth,
                       "Restore Defaults must restore width and Solid pattern")
        let blank = try raster(); try draw(); _ = try visibleInk(after: blank)
        try ui.selectTool("highlighter")
        XCTAssertEqual(swatches.map(\.label), highlighter, "Reset must not alter another tool")
    }

    // MARK: Erasing and page operations

    private func eraser(_ mode: String) throws {
        try settings("eraser"); try tap(mode); closePopover()
        XCTAssertEqual(try ui.state().tool, "eraser")
    }

    func testEraserSelectionShowsOptionsAndErasesAStroke() throws {
        try draw(); let drawn = try ui.state()
        try eraser("Whole stroke")
        XCTAssertEqual(try control("Eraser mode").value as? String, "Whole stroke")
        try ui.drawStroke([CGPoint(x: 0.5, y: 0.57), CGPoint(x: 0.5, y: 0.67)])
        _ = try ui.waitForState { $0.strokeCountOnPage == drawn.strokeCountOnPage - 1 }
    }

    private func splitErase(_ mode: String) throws {
        let blank = try raster()
        try draw(); let before = try ui.state(), ink = try visibleInk(after: blank)
        try eraser(mode)
        try ui.drawStroke([CGPoint(x: 0.5, y: 0.57), CGPoint(x: 0.5, y: 0.67)])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        let split = try raster()
        XCTAssertGreaterThan(split.changed(from: ink), 10, "Crossed geometry must disappear")
        for x: CGFloat in [0.42, 0.58] {
            XCTAssertGreaterThan(try raster(CGRect(x: x - 0.01, y: 0.61, width: 0.02, height: 0.02)).darkPixels, 0,
                                 "The untouched fragment must remain")
        }
        try undo(to: before)
        XCTAssertLessThan(try raster().changed(from: ink), 30, "One Undo must restore both erased geometry and original stroke")
    }

    func testPrecisionEraserCutsMiddleAndUndoRestoresFragments() throws { try splitErase("Precision") }
    func testStandardEraserSplitsTouchedRunAndPreservesUntouchedContent() throws { try splitErase("Standard") }

    func testWholeStrokeEraserRemovesOnlyTouchedStrokeAndUndoRestoresIt() throws {
        try draw()
        try draw([CGPoint(x: 0.4, y: 0.72), CGPoint(x: 0.6, y: 0.72)])
        let before = try ui.state()
        try eraser("Whole stroke")
        try ui.drawStroke([CGPoint(x: 0.5, y: 0.58), CGPoint(x: 0.5, y: 0.65)])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage - 1 && $0.itemCountOnPage == before.itemCountOnPage - 1 }
        XCTAssertGreaterThan(try raster(CGRect(x: 0.42, y: 0.71, width: 0.16, height: 0.02)).darkPixels, 10)
        try undo(to: before)
    }

    func testEraserSizePresetsAndCustomSliderChangeErasedDiameter() throws {
        try draw()
        let before = try ui.state(), full = try raster()
        try eraser("Precision")
        var removed: [Int] = []
        for label in ["Small eraser, 6 points", "Medium eraser, 14 points", "Large eraser, 28 points"] {
            try tap(label)
            XCTAssertTrue(try control(label, type: .button).isSelected)
            try ui.drawStroke([CGPoint(x: 0.5, y: 0.58), CGPoint(x: 0.5, y: 0.66)])
            _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
            removed.append(try raster().changed(from: full)); try undo(to: before)
        }
        XCTAssertLessThan(removed[0], removed[1]); XCTAssertLessThan(removed[1], removed[2])
        try settings("eraser"); _ = try slider("Size", to: 0.95); closePopover()
        try ui.drawStroke([CGPoint(x: 0.5, y: 0.58), CGPoint(x: 0.5, y: 0.66)])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        XCTAssertGreaterThan(try raster().changed(from: full), removed[2], "Custom diameter must exceed Large's erased area")
    }

    func testEraserFiltersEraseOnlyEnabledPenPencilHighlighterAndTape() throws {
        let kinds = ["pen", "pencil", "highlighter", "tape"]
        let labels = ["Pen", "Pencil", "Highlighter", "Tape"]
        let initial = try ui.state()
        for (i, tool) in kinds.enumerated() {
            try ui.selectTool(tool)
            // Tape is an item rather than a StrokeItem in some renderers; test item counts for the mixed fixture.
            let before = try ui.state()
            try ui.drawStroke([CGPoint(x: 0.4, y: 0.56 + Double(i) * 0.05), CGPoint(x: 0.6, y: 0.56 + Double(i) * 0.05)])
            _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        }
        let mixed = try ui.state()
        XCTAssertEqual(mixed.itemCountOnPage, initial.itemCountOnPage + 4)
        for enabled in labels {
            try settings("eraser"); try tap("Whole stroke")
            // Enable target first, so the last-enabled-filter guard is respected.
            let target = try control(enabled, type: .button, scroll: true)
            if !target.isSelected { target.tap() }
            for label in labels where label != enabled {
                let chip = try control(label, type: .button, scroll: true)
                if chip.isSelected { chip.tap() }
                XCTAssertFalse(chip.isSelected)
            }
            XCTAssertTrue(target.isSelected); closePopover()
            try ui.drawStroke([CGPoint(x: 0.5, y: 0.54), CGPoint(x: 0.5, y: 0.74)])
            _ = try ui.waitForState { $0.itemCountOnPage == mixed.itemCountOnPage - 1 }
            try undo(to: mixed)
        }
    }

    func testAutoDeselectReturnsToPreviousToolOnlyWhenEnabled() throws {
        for enabled in [true, false] {
            try ui.selectTool("pen"); try draw()
            let before = try ui.state()
            try settings("eraser"); try tap("Whole stroke"); try toggle("Auto-deselect", to: enabled); closePopover()
            try ui.drawStroke([CGPoint(x: 0.5, y: 0.58), CGPoint(x: 0.5, y: 0.66)])
            _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage - 1 && $0.tool == (enabled ? "pen" : "eraser") }
        }
    }

    func testClearPageCancelConfirmAndUndoPreservePageIdentity() throws {
        try draw(); let before = try ui.state()
        try settings("eraser"); try tap("Clear Page", scroll: true); cancelConfirmation()
        closePopover()
        try assertNoNewInk(before)
        try settings("eraser"); try tap("Clear Page", scroll: true)
        let confirm = ui.app.buttons.matching(NSPredicate(format: "label == 'Clear Page'"))
        let button = try XCTUnwrap(confirm.allElementsBoundByIndex.last(where: { $0.isHittable }))
        button.tap()
        _ = try ui.waitForState { $0.itemCountOnPage == 0 && $0.strokeCountOnPage == 0 && $0.page == before.page && $0.pageCount == before.pageCount }
        closePopover(); try undo(to: before)
    }

    private func deleteItems(scope: String) throws {
        try tap("menu.more"); try tap("Delete Specific Items…", scroll: true)
        try tap(scope)
        try toggle("Handwriting", to: true)
        let button = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete ' AND label ENDSWITH 'Items' OR label == 'Delete 1 Item'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(button.isEnabled); button.tap()
    }

    func testDeleteSpecificItemsPageScopeKeepsNonInkAndUndoRestores() throws {
        try draw(); let before = try ui.state()
        try deleteItems(scope: "This page")
        _ = try ui.waitForState { $0.strokeCountOnPage == 0 && $0.itemCountOnPage == before.itemCountOnPage - before.strokeCountOnPage && $0.pageCount == 4 }
        try undo(to: before)
    }

    func testDeleteSpecificHighlighterKeepsHandwritingAndUndoRestoresHighlight() throws {
        try draw()
        let penRegion = CGRect(x: 0.42, y: 0.61, width: 0.16, height: 0.02)
        let pen = try raster(penRegion)
        try ui.selectTool("highlighter")
        let highlightRegion = CGRect(x: 0.38, y: 0.69, width: 0.24, height: 0.06)
        let blank = try raster(highlightRegion)
        try draw([CGPoint(x: 0.4, y: 0.72), CGPoint(x: 0.6, y: 0.72)])
        let highlight = try visibleInk(after: blank, region: highlightRegion)
        let before = try ui.state()
        try tap("menu.more"); try tap("Delete Specific Items…", scroll: true)
        try tap("This page")
        try toggle("Handwriting", to: false)
        try toggle("Highlighter", to: true)
        try tap("Delete 1 Item")
        _ = try ui.waitForState {
            $0.strokeCountOnPage == before.strokeCountOnPage - 1 &&
            $0.itemCountOnPage == before.itemCountOnPage - 1 && $0.page == before.page
        }
        XCTAssertLessThan(try raster(penRegion).changed(from: pen), 30,
                          "Deleting only highlights must preserve the unselected handwriting")
        XCTAssertLessThan(try raster(highlightRegion).changed(from: blank), 30,
                          "The selected highlight must disappear")
        try undo(to: before)
        let restored = try visibleInk(after: blank, region: highlightRegion)
        XCTAssertLessThan(restored.changed(from: highlight), 30,
                          "Undo must restore the deleted highlight's appearance")
    }

    func testDeleteSpecificItemsDocumentScopeRemovesInkOnOtherPages() throws {
        try draw()
        let first = try ui.state()
        // Real page navigation, through the thumbnail panel.
        try ui.tapCommand("sidebar.toggle")
        try tap("Page 2", scroll: true)
        _ = try ui.waitForState { $0.page != first.page }
        try ui.tapCommand("sidebar.toggle")
        try draw(); let second = try ui.state()
        try deleteItems(scope: "Whole document")
        _ = try ui.waitForState { $0.strokeCountOnPage == 0 && $0.pageCount == 4 }
        try ui.tapCommand("sidebar.toggle"); try tap("Page 1", scroll: true)
        _ = try ui.waitForState { $0.page == first.page && $0.strokeCountOnPage == 0 && $0.itemCountOnPage == first.itemCountOnPage - first.strokeCountOnPage }
        try ui.tapCommand("sidebar.toggle")
        try undo(to: first)
        try ui.tapCommand("sidebar.toggle"); try tap("Page 2", scroll: true)
        _ = try ui.waitForState { $0.page == second.page && $0.strokeCountOnPage == second.strokeCountOnPage }
    }

    // MARK: Pen gestures and shape recognition

    private func penGesture(_ label: String) throws {
        try settings("pen"); try tap("Pen gestures…", scroll: true)
        try toggle(label, to: false)
        try toggle(label, to: true); closePopover()
    }

    func testScribbleToEraseRemovesCoveredHandwritingAndUndoRestores() throws {
        try penGesture("Scribble to Erase")
        try draw(); let before = try ui.state()
        let scribble = (0...10).map { i in CGPoint(x: i % 2 == 0 ? 0.39 : 0.61, y: 0.59 + Double(i) * 0.006) }
        try ui.drawStroke(scribble, duration: 0.8)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage - 1 }
        try undo(to: before)
    }

    func testCircleToLassoRemovesLoopAndSelectsEnclosedStroke() throws {
        try penGesture("Circle to Lasso")
        try draw(); let before = try ui.state()
        let loop = (0...32).map { i in
            let angle = Double(i) * .pi / 16
            return CGPoint(x: 0.5 + 0.13 * cos(angle), y: 0.62 + 0.06 * sin(angle))
        }
        try ui.drawStroke(loop, duration: 0.6)
        // No screenshot/probe query between loop and hold: the contract allows only three seconds.
        ui.coordinate(CGPoint(x: 0.5, y: 0.62)).press(forDuration: 0.8)
        _ = try ui.waitForState { $0.selectionCount == 1 && $0.strokeCountOnPage == before.strokeCountOnPage }
    }

    /// Uniformly timed samples include a stationary tail to perform a real Draw and Hold.
    /// No tool commands or shape injection. Optional adjustment moves the still-held tip after recognition.
    private func heldPath(_ vertices: [CGPoint], adjust: CGPoint? = nil) throws {
        var points: [CGPoint] = []
        for pair in zip(vertices, vertices.dropFirst()) {
            for step in 0..<5 {
                let t = CGFloat(step) / 5
                points.append(CGPoint(x: pair.0.x + (pair.1.x - pair.0.x) * t,
                                      y: pair.0.y + (pair.1.y - pair.0.y) * t))
            }
        }
        let end = try XCTUnwrap(vertices.last)
        points += Array(repeating: end, count: 22)
        if let adjust { points += [adjust] + Array(repeating: adjust, count: 10) }
        let samples = points.map { NSValue(cgPoint: ui.coordinate($0).screenPoint) }
        let done = XCTestExpectation(description: "Continuous drawn path, hold, and lift")
        var failure: Error?
        let duration = Double(points.count) * 0.06
        NibTouchPaths.perform([samples], duration: duration) { error in failure = error; done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: duration + 15), .completed)
        if let failure { throw failure }
    }

    private func recognise(_ points: [CGPoint]) throws {
        try settings("pen"); try toggle("Draw and Hold", to: true); closePopover()
        let before = try ui.state(), blank = try raster()
        try heldPath(points)
        _ = try ui.waitForState(timeout: 12) {
            $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage && $0.undoAvailable
        }
        _ = try visibleInk(after: blank)
        try undo(to: before)
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage }
    }

    func testDrawHoldLineIsOneUndoableShape() throws { try recognise(line) }
    func testDrawHoldArrowIsOneUndoableShape() throws {
        try recognise([CGPoint(x: 0.4, y: 0.63), CGPoint(x: 0.6, y: 0.63), CGPoint(x: 0.57, y: 0.60), CGPoint(x: 0.6, y: 0.63), CGPoint(x: 0.57, y: 0.66)])
    }
    func testDrawHoldArcIsOneUndoableShape() throws {
        try recognise((0...12).map { i in let a = Double(i) * .pi / 12; return CGPoint(x: 0.5 + 0.1 * cos(a), y: 0.68 - 0.09 * sin(a)) })
    }
    func testDrawHoldCurveIsOneUndoableShape() throws {
        try recognise((0...16).map { i in let t = Double(i) / 16; return CGPoint(x: 0.4 + 0.2 * t, y: 0.57 + 0.12 * t * t) })
    }
    func testDrawHoldRectangleIsOneUndoableShape() throws {
        try recognise([CGPoint(x: 0.41, y: 0.56), CGPoint(x: 0.59, y: 0.56), CGPoint(x: 0.59, y: 0.70), CGPoint(x: 0.41, y: 0.70), CGPoint(x: 0.41, y: 0.56)])
    }
    func testDrawHoldEllipseIsOneUndoableShape() throws {
        try recognise((0...24).map { i in let a = Double(i) * .pi / 12; return CGPoint(x: 0.5 + 0.1 * cos(a), y: 0.63 + 0.06 * sin(a)) })
    }
    func testDrawHoldTriangleIsOneUndoableShape() throws {
        try recognise([CGPoint(x: 0.5, y: 0.55), CGPoint(x: 0.6, y: 0.70), CGPoint(x: 0.4, y: 0.70), CGPoint(x: 0.5, y: 0.55)])
    }
    func testDrawHoldPolygonIsOneUndoableShape() throws {
        try recognise((0...5).map { i in let a = Double(i) * 2 * .pi / 5 - .pi / 2; return CGPoint(x: 0.5 + 0.1 * cos(a), y: 0.64 + 0.08 * sin(a)) })
    }

    func testHeldShapeAdjustmentChangesGeometryAndCommitsOnlyOnLift() throws {
        try settings("pen"); try toggle("Draw and Hold", to: true); closePopover()
        let before = try ui.state(), blank = try raster()
        let endpointRegion = CGRect(x: 0.58, y: 0.68, width: 0.04, height: 0.04)
        let blankEndpoint = try raster(endpointRegion)
        try heldPath(line, adjust: CGPoint(x: 0.60, y: 0.70))
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage }
        _ = try visibleInk(after: blank)
        XCTAssertGreaterThan(try raster(CGRect(x: 0.58, y: 0.68, width: 0.04, height: 0.04)).darkPixels, 0,
                             "Moving the held tip must move the final shape endpoint")
        XCTAssertGreaterThan(try raster(endpointRegion).changed(from: blankEndpoint), 10,
                             "The adjusted endpoint must contain newly drawn geometry")
        try assertNoNewInk(try ui.state())
        try undo(to: before)
    }

    func testDrawShapeRecognisesOnLiftAndKeepsUnrecognisedInk() throws {
        ui.app.typeKey("d", modifierFlags: [])
        _ = try ui.waitForState { $0.tool == "drawShape" }
        try settings("drawShape")
        try toggle("Draw and Hold", to: true); try toggle("Require Hold to Snap", to: false); closePopover()
        let before = try ui.state()
        try ui.drawStroke(line)
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage }
        try undo(to: before)
        try draw([CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.52, y: 0.70), CGPoint(x: 0.43, y: 0.66), CGPoint(x: 0.57, y: 0.55), CGPoint(x: 0.60, y: 0.72), CGPoint(x: 0.48, y: 0.59), CGPoint(x: 0.58, y: 0.64)])
        try undo(to: before)
    }

    func testShapeRecognitionSettingsPersistAndRequireHoldChangesBehavior() throws {
        try settings("drawShape")
        try toggle("Draw and Hold", to: true)
        try toggle("Require Hold to Snap", to: true)
        try toggle("Snap to Other Shapes", to: false)
        closePopover(); try settings("drawShape")
        XCTAssertEqual(try control("Require Hold to Snap", type: .switch).value as? String, "1")
        XCTAssertEqual(try control("Snap to Other Shapes", type: .switch).value as? String, "0")
        closePopover()
        let before = try ui.state(); try draw(); try undo(to: before)
        try heldPath(line)
        _ = try ui.waitForState { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage }
        try undo(to: before)
        try settings("drawShape"); try toggle("Draw and Hold", to: false)
        XCTAssertFalse(try control("Require Hold to Snap", type: .switch).isEnabled)
        closePopover(); try ui.selectTool("pen"); try heldPath(line)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    // MARK: Undo, redo, keyboard and selective history

    func testWritingShapeSettingsSnapJoinsNeighboursAndUndoRestoresThem() throws {
        // The Writing settings page and the tool popover must share the same persisted settings.
        try openPreferences()
        try tap("Writing"); try tap("Shape Recognition", scroll: true)
        try toggle("Draw and Hold", to: true)
        try toggle("Require Hold to Snap", to: false)
        try toggle("Snap to Other Shapes", to: true)
        try closePreferences()
        try settings("drawShape")
        XCTAssertEqual(try control("Snap to Other Shapes", type: .switch).value as? String, "1")
        XCTAssertEqual(try control("Require Hold to Snap", type: .switch).value as? String, "0")
        closePopover()
        let initial = try ui.state()
        try ui.drawStroke([CGPoint(x: 0.40, y: 0.62), CGPoint(x: 0.50, y: 0.62)])
        _ = try ui.waitForState { $0.itemCountOnPage == initial.itemCountOnPage + 1 && $0.strokeCountOnPage == initial.strokeCountOnPage }
        let neighbour = try ui.state(), image = try raster()
        // Start within 12 page points of the neighbour's endpoint; snap should merge, not leave two shapes.
        try ui.drawStroke([CGPoint(x: 0.505, y: 0.62), CGPoint(x: 0.60, y: 0.69)])
        _ = try visibleInk(after: image)
        XCTAssertEqual(try ui.state().itemCountOnPage, neighbour.itemCountOnPage, "Snapping joins the neighbour into one shape")
        XCTAssertEqual(try ui.state().strokeCountOnPage, initial.strokeCountOnPage)
        try undo(to: neighbour)
        XCTAssertLessThan(try raster().changed(from: image), 30, "Undo must restore the neighbour before the join")
        try settings("drawShape"); try toggle("Snap to Other Shapes", to: false); closePopover()
        try ui.drawStroke([CGPoint(x: 0.505, y: 0.62), CGPoint(x: 0.60, y: 0.69)])
        _ = try ui.waitForState { $0.itemCountOnPage == neighbour.itemCountOnPage + 1 }
    }

    func testUndoButtonReversesLastInkAndUpdatesHistoryAvailability() throws {
        let before = try ui.state(); XCTAssertFalse(before.undoAvailable)
        try draw(); try undo(to: before)
        XCTAssertFalse(try ui.state().undoAvailable)
    }

    func testRedoButtonRestoresInkAndUpdatesHistoryAvailability() throws {
        let before = try ui.state(); try draw(); try undo(to: before)
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 && $0.undoAvailable && !$0.redoAvailable }
    }

    func testKeyboardToolWidthColourUndoAndRedoActions() throws {
        try ui.selectTool("lasso")
        ui.app.typeKey("p", modifierFlags: [])
        _ = try ui.waitForState { $0.tool == "pen" }
        let before = try ui.state(); try draw()
        ui.app.typeKey("z", modifierFlags: .command)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage && $0.redoAvailable }
        ui.app.typeKey("z", modifierFlags: [.command, .shift])
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 && !$0.redoAvailable }
        ui.app.typeKey("h", modifierFlags: [])
        _ = try ui.waitForState { $0.tool == "highlighter" }
        try width(1)
        ui.app.typeKey("]", modifierFlags: [])
        XCTAssertTrue(try control("Thickness 2", type: .button).isSelected)
        ui.app.typeKey("[", modifierFlags: [])
        XCTAssertTrue(try control("Thickness 1", type: .button).isSelected)
        ui.app.typeKey("3", modifierFlags: [])
        XCTAssertTrue(swatches[2].isSelected)
        try draw()
        ui.app.typeKey("e", modifierFlags: [])
        _ = try ui.waitForState { $0.tool == "eraser" }
    }

    func testTwoFingerUndoAndThreeFingerRedoDoubleTaps() throws {
        let before = try ui.state(); try draw()
        // Keep the gestures in the canvas desk, away from the palette and page objects.
        // XCUIElement.tap(withNumberOfTaps:numberOfTouches:) sends simultaneous direct fingers.
        // Use the canvas element's centre, clear of the floating palette.
        ui.canvas.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage && $0.redoAvailable }
        ui.canvas.tap(withNumberOfTaps: 2, numberOfTouches: 3)
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 && !$0.redoAvailable }
    }

    func testHistoryRevertRemovesChosenEarlierStrokeAndKeepsLaterInk() throws {
        let before = try ui.state()
        try draw()
        try draw([CGPoint(x: 0.4, y: 0.72), CGPoint(x: 0.6, y: 0.72)])
        try ui.tapCommand("sidebar.toggle"); try tap("Panel Options"); try tap("History")
        _ = try ui.waitForState { $0.openPanels.contains("undo.history") }
        let reverts = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Revert '"))
        try wait("History must offer a Revert action for each stroke") { reverts.count == 2 }
        reverts.element(boundBy: 1).tap() // newest first: choose the older stroke
        _ = try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try ui.tapCommand("sidebar.toggle")
        XCTAssertGreaterThan(try raster(CGRect(x: 0.42, y: 0.71, width: 0.16, height: 0.02)).darkPixels, 10, "Later unrelated stroke must survive selective revert")
        XCTAssertEqual(try raster(CGRect(x: 0.42, y: 0.61, width: 0.16, height: 0.02)).darkPixels, 0, "Chosen earlier stroke must disappear")
    }

    // MARK: Pencil palette and simulator-testable Pencil preferences
    // Device-only: variable Pencil pressure/tilt, Pencil Pro barrel roll, Pencil hover over page/palette,
    // physical double-tap/squeeze dispatch, Pencil Pro haptic output, and concurrent palm/Pencil input.
    // The tests below verify settings and direct-touch behavior, never claim those hardware events.

    func testPencilPaletteKeyboardChoiceAppliesAndDismissesWithoutMarks() throws {
        ui.app.typeKey("p", modifierFlags: [.control, .command])
        let palette = try control("Pencil palette")
        let eraser = palette.buttons["tool.eraser"]
        XCTAssertTrue(eraser.exists); eraser.tap()
        _ = try ui.waitForState { $0.tool == "eraser" }
        try wait("Choosing eraser must dismiss Pencil palette") { !palette.exists }
        try ui.selectTool("pen")
        let before = try ui.state()
        let desired = try XCTUnwrap(swatches.last?.label)
        let paletteColourFallback = "Colour \(swatches.count)"
        ui.app.typeKey("p", modifierFlags: [.control, .command])
        let colours = try control("Pencil palette")
        let thickness = colours.buttons.matching(NSPredicate(format: "label ENDSWITH 'millimetres'")).allElementsBoundByIndex
        let thickest = try XCTUnwrap(thickness.last, "Pencil palette must offer the current tool's thickness attributes")
        thickest.tap()
        XCTAssertTrue(thickest.isSelected, "Choosing a palette thickness must change the active attribute")
        let colour = colours.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", desired, paletteColourFallback)).firstMatch
        XCTAssertTrue(colour.exists); colour.tap()
        try wait("Choosing a palette colour must close it") { !colours.exists }
        XCTAssertEqual(swatches.first(where: \.isSelected)?.label, desired)
        XCTAssertTrue(try control("Thickness 3", type: .button).isSelected)
        try assertNoNewInk(before); try draw()
        ui.app.typeKey("p", modifierFlags: [.control, .command])
        _ = try control("Pencil palette")
        ui.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        try wait("Escape dismisses the Pencil palette") { !self.ui.app.otherElements["Pencil palette"].exists }
    }

    func testSettingsKeyboardShortcutOpensInkPreferences() throws {
        ui.app.typeKey(",", modifierFlags: .command)
        _ = try control("Stylus")
    }

    private func openPreferences() throws {
        try ui.tapCommand("window.showLibrary")
        try tap("App Menu")
        try tap("Settings")
    }

    private func closePreferences() throws {
        try ui.dismissSheets()
        if try ui.state().screen == "library" { try ui.openDocument("Physics — Motion") }
    }

    private func pencilSettings() throws {
        try openPreferences()
        try tap("Stylus"); try tap("Apple Pencil", scroll: true)
    }

    func testPencilHoverSettingPersistsWithoutCreatingMarks() throws {
        let before = try ui.state()
        try pencilSettings()
        try toggle("Show hover preview", to: false)
        try toggle("Show hover preview", to: true)
        try closePreferences()
        try assertNoNewInk(before)
        try pencilSettings()
        XCTAssertEqual(try control("Show hover preview", type: .switch, scroll: true).value as? String, "1")
    }

    func testPencilDoubleTapAndSqueezeBindingChoicesPersist() throws {
        try pencilSettings()
        // Exclude the Use iPad setting row, whose subtitle repeats this action's title.
        let choices = ui.app.buttons.matching(NSPredicate(format: "label == 'Switch between current tool and eraser'"))
        let first = choices.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        XCTAssertTrue(first.isSelected, "Double-tap binding must persist its choice")
        // Both gesture sections offer the same choices. Select the second section's palette binding.
        let squeeze = ui.app.buttons.matching(NSPredicate(format: "label == 'Show tool palette'")).element(boundBy: 1)
        for _ in 0..<12 {
            if squeeze.exists && squeeze.isHittable { break }
            let detail = try XCTUnwrap(scrollPanels.max(by: { $0.frame.minX < $1.frame.minX }))
            scrollPanel(detail, down: false)
        }
        XCTAssertTrue(squeeze.exists && squeeze.isHittable, "Squeeze must offer its own palette binding")
        squeeze.tap()
        XCTAssertTrue(squeeze.isSelected, "Squeeze binding must persist its choice")
        try closePreferences()
        try pencilSettings()
        try wait("Double-tap selection must survive closing Settings") { choices.firstMatch.isSelected }
    }

    func testPencilHapticsPreferencePersistsWithoutMarks() throws {
        let before = try ui.state()
        try pencilSettings()
        try toggle("Pencil haptics", to: false)
        try toggle("Pencil haptics", to: true)
        try closePreferences()
        try assertNoNewInk(before)
        try pencilSettings()
        XCTAssertEqual(try control("Pencil haptics", type: .switch, scroll: true).value as? String, "1")
    }

    func testTwoFingerNavigationThenFingerDrawingCommitsOnce() throws {
        let before = try ui.state()
        try ui.twoFingerScroll(from: CGPoint(x: 0.12, y: 0.7), to: CGPoint(x: 0.12, y: 0.55))
        _ = try ui.waitForState { abs($0.contentOffset.y - before.contentOffset.y) > 10 }
        try assertNoNewInk(before)
        try draw()
        try assertNoNewInk(try ui.state())
    }

    func testPressureAndRotationPreferencesStillAllowFingerInk() throws {
        try settings("pen")
        _ = try slider("Pressure sensitivity", to: 0.9)
        try toggle("React to Pen Rotation", to: true); closePopover()
        let before = try ui.state(), blank = try raster()
        try draw(); _ = try visibleInk(after: blank)
        try undo(to: before)
    }

}
