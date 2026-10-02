import XCTest
import UIKit
import UniformTypeIdentifiers
import Network

/// Selection acceptance tests. All document edits use touches, menus or hardware-key events.
/// UIPasteboard and a loopback HTTP fixture supply external payloads only; nib.qa.state is a read-only oracle.
/// Owners: F011 selection, F012 transforms, F013 menus, F014 clipboard, F041 layers,
/// F057 conversion, F058 Smart Ink, F105 restyle. Failures retain the screen, tree and probe.
@MainActor
final class SelectionUITests: XCTestCase {
    private var ui: NibUI!
    private let region = CGRect(x: 0.36, y: 0.50, width: 0.29, height: 0.28)
    private let stroke = [CGPoint(x: 0.42, y: 0.65), CGPoint(x: 0.46, y: 0.56),
                          CGPoint(x: 0.50, y: 0.68), CGPoint(x: 0.56, y: 0.59), CGPoint(x: 0.60, y: 0.70)]

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        try ui.launchFixture()
        try ui.openDocument("Physics — Motion")
        _ = try ui.waitForState { $0.itemCountOnPage == 4 && $0.strokeCountOnPage == 1 }
    }

    override func tearDownWithError() throws {
        guard let ui else { return }
        for attachment in [XCTAttachment(screenshot: XCUIScreen.main.screenshot()),
                           XCTAttachment(string: String(describing: ui.probe.value)),
                           XCTAttachment(string: ui.app.debugDescription)] .enumerated() {
            attachment.element.name = "Selection-\(name)-\(["screen", "nib.qa.state", "accessibility"][attachment.offset])"
            attachment.element.lifetime = .keepAlways
            add(attachment.element)
        }
        ui.app.terminate()
        self.ui = nil
    }

    private func query(_ name: String, type: XCUIElement.ElementType = .any) -> XCUIElementQuery {
        ui.app.descendants(matching: type).matching(NSPredicate(format: "identifier == %@ OR label == %@", name, name))
    }

    private func wait(_ message: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail(message, file: file, line: line)
            throw NibUI.Failure.message(message)
        }
    }

    private func control(_ name: String, type: XCUIElement.ElementType = .any, scroll: Bool = false) throws -> XCUIElement {
        let q = query(name, type: type)
        for attempt in 0..<(scroll ? 10 : 2) {
            let matches = q.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
            if let found = matches.first(where: { [.button, .switch, .textField, .textView].contains($0.elementType) }) ?? matches.first {
                // SwiftUI menus expose both the row and its label. An index in the mixed-type
                // query can resolve differently when XCTest performs the action. Keep the
                // intended labelled control (icons such as "scribble" are shared by rows).
                let exact = ui.app.descendants(matching: found.elementType).matching(NSPredicate(
                    format: "identifier == %@ AND label == %@", found.identifier, found.label))
                if exact.count == 1 { return exact.firstMatch }
                return found
            }
            if attempt == 0 { _ = q.firstMatch.waitForExistence(timeout: 3) }
            let panels = ui.app.scrollViews.allElementsBoundByIndex
                + ui.app.collectionViews.allElementsBoundByIndex + ui.app.tables.allElementsBoundByIndex
            if scroll, let panel = panels.first(where: {
                $0.identifier != "nib.canvas" && $0.isHittable && $0.frame.width > 200 && $0.frame.height > 150
            }) {
                panel.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.8)).press(forDuration: 0.01,
                    thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.2)))
            }
        }
        throw NibUI.Failure.message("Missing actionable selection control: \(name)\n\(ui.app.debugDescription)")
    }

    private func tap(_ name: String, scroll: Bool = false) throws { try control(name, scroll: scroll).tap() }
    private func key(_ value: String, _ modifiers: XCUIElement.KeyModifierFlags = .command) {
        ui.app.typeKey(value, modifierFlags: modifiers)
    }
    private func outside() { ui.coordinate(CGPoint(x: 0.95, y: 0.85)).tap() }

    private func toggle(_ name: String, to enabled: Bool) throws {
        let target = try control(name, type: .switch, scroll: true)
        if (target.value as? String == "1") != enabled { target.tap() }
        try wait("\(name) must retain its setting") { (target.value as? String == "1") == enabled }
    }

    private func lassoSettings() throws {
        try ui.selectTool("lasso")
        try tap("tool.lasso")
    }

    private func loop(_ rect: CGRect? = nil, count: Int) throws {
        try ui.selectTool("lasso")
        let r = rect ?? region
        try ui.drawStroke([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                           CGPoint(x: r.minX, y: r.minY)], duration: 0.7)
        _ = try ui.waitForState(timeout: 10) { $0.selectionCount == count }
    }

    private func draw(_ path: [CGPoint]? = nil, tool: String = "pen") throws {
        try ui.selectTool(tool)
        let before = try ui.state()
        try ui.drawStroke(path ?? stroke)
        _ = try ui.waitForState(timeout: 15) {
            $0.strokeCountOnPage == before.strokeCountOnPage + 1 && $0.itemCountOnPage == before.itemCountOnPage + 1
        }
    }

    private func selectedInk() throws { try draw(); try loop(count: 1) }

    private func selection() throws -> XCUIElement {
        // F011's item summary exposes the content box. F012's similarly labelled object summary
        // includes the 44-point handle hit areas and rotation stem, so it is not a geometry oracle.
        let q = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Selection' AND (value == '1 item' OR value ENDSWITH ' items')"))
        try wait("Selection must expose its actual content bounds") {
            q.allElementsBoundByIndex.contains { $0.frame.width > 0 && $0.frame.height > 0 }
        }
        return try XCTUnwrap(q.allElementsBoundByIndex.first { $0.frame.width > 0 && $0.frame.height > 0 })
    }
    private func bounds() throws -> CGRect { try selection().frame }
    private func screen(_ point: CGPoint) -> XCUICoordinate {
        ui.app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - ui.app.frame.minX, dy: point.y - ui.app.frame.minY))
    }
    private func drag(_ start: CGPoint, _ end: CGPoint, modifiers: XCUIElement.KeyModifierFlags = []) {
        XCUIElement.perform(withKeyModifiers: modifiers) {
            self.screen(start).press(forDuration: 0.08, thenDragTo: self.screen(end), withVelocity: .slow, thenHoldForDuration: 0)
        }
    }
    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func clear() throws {
        try ui.selectTool("lasso")
        ui.coordinate(CGPoint(x: 0.68, y: 0.82)).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 0 }
    }
    private func selectAll(_ count: Int) throws {
        key("a")
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == count }
    }

    /// The capsule More shares its label with unrelated chrome. Find the one next to Copy.
    private func objectMore() throws {
        let copy = try control("cmd.clipboard.copy")
        let candidates = query("More", type: .button).allElementsBoundByIndex.filter {
            $0.isHittable && abs($0.frame.midY - copy.frame.midY) < 45
                && $0.identifier != "menu.more" && $0.identifier != "tool.more"
        }
        try XCTUnwrap(candidates.min { abs($0.frame.midX - copy.frame.midX) < abs($1.frame.midX - copy.frame.midX) },
                      "F013: selection must offer More extensions").tap()
    }
    private func menu(_ path: String...) throws { try objectMore(); for label in path { try tap(label) } }
    private func pageMenu(at point: CGPoint = CGPoint(x: 0.65, y: 0.82)) throws {
        try ui.selectTool("lasso")
        ui.coordinate(point).press(forDuration: 1.0)
    }

    private func countsEqual(_ before: QAState) throws {
        let after = try ui.state()
        XCTAssertEqual(after.itemCountOnPage, before.itemCountOnPage)
        XCTAssertEqual(after.strokeCountOnPage, before.strokeCountOnPage)
        XCTAssertEqual(after.pageCount, before.pageCount)
    }
    private func undoCounts(_ before: QAState) throws {
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState(timeout: 10) {
            $0.itemCountOnPage == before.itemCountOnPage && $0.strokeCountOnPage == before.strokeCountOnPage && $0.redoAvailable
        }
    }
    private func undoBounds(_ before: CGRect) throws {
        try ui.tapCommand("edit.undo")
        try wait("Undo must restore the selected object's geometry") {
            guard let r = try? self.bounds() else { return false }
            return abs(r.minX - before.minX) < 0.75 && abs(r.minY - before.minY) < 0.75
                && abs(r.width - before.width) < 0.75 && abs(r.height - before.height) < 0.75
        }
        XCTAssertTrue(try ui.state().redoAvailable)
    }

    // MARK: Read-only pixel observations (no app model access)

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        func changed(from other: Pixels) -> Int {
            guard width == other.width && height == other.height else { return Int.max }
            return stride(from: 0, to: bytes.count, by: 4).filter { i in
                (0..<3).contains { abs(Int(bytes[i + $0]) - Int(other.bytes[i + $0])) > 30 }
            }.count
        }
    }
    private func pixels(_ r: CGRect? = nil) throws -> Pixels {
        let f = ui.canvas.frame, n = r ?? region
        let rect = CGRect(x: f.minX + n.minX * f.width, y: f.minY + n.minY * f.height,
                          width: n.width * f.width, height: n.height * f.height)
        let source = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat(); format.scale = source.scale
        let size = ui.app.frame.size
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        let image = try XCTUnwrap(normalized.cgImage)
        let scale = CGFloat(image.width) / size.width
        let crop = try XCTUnwrap(image.cropping(to: rect.applying(CGAffineTransform(scaleX: scale, y: scale))))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            let ctx = try XCTUnwrap(CGContext(data: data.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return Pixels(bytes: bytes, width: crop.width, height: crop.height)
    }
    private func recolour(_ name: String) throws {
        try ui.tapCommand("item.recolor")
        try tap(name)
        outside()
    }

    // MARK: lasso, selection.fromRect, selection.tapAt, selection.clear

    func testFreehandLassoSelectsOnlyEnclosedRealStroke() throws {
        try draw()
        try draw([CGPoint(x: 0.44, y: 0.84), CGPoint(x: 0.58, y: 0.86)])
        let before = try ui.state()
        try loop(count: 1)
        try countsEqual(before)
        let b = try bounds()
        XCTAssertTrue(b.contains(ui.coordinate(stroke[2]).screenPoint), "Lasso must select the enclosed stroke")
        XCTAssertFalse(b.contains(ui.coordinate(CGPoint(x: 0.5, y: 0.85)).screenPoint), "Unrelated stroke must remain outside selection")
    }

    func testRectangleSelectsAnIntersectingStroke() throws {
        try draw()
        try lassoSettings(); try tap("Rectangle"); outside()
        try ui.drawStroke([CGPoint(x: 0.40, y: 0.60), CGPoint(x: 0.48, y: 0.73)])
        _ = try ui.waitForState(timeout: 10) { $0.selectionCount == 1 }
        XCTAssertGreaterThan(try bounds().maxX, ui.coordinate(CGPoint(x: 0.57, y: 0.7)).screenPoint.x,
                             "Intersection selects the entire stroke, not only the portion inside the rectangle")
    }

    func testVShortcutSelectsLassoAndCanEncloseInk() throws {
        try draw(); key("v", [])
        _ = try ui.waitForState(timeout: 8) { $0.tool == "lasso" }
        try loop(count: 1)
    }

    func testQuickTapSelectsTopmostEligibleObject() throws {
        try pasteImage(at: CGPoint(x: 0.46, y: 0.60))
        let first = try bounds()
        try ui.tapCommand("item.duplicate")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == 6 }
        let top = try bounds()
        try clear(); try ui.selectTool("pen")
        let before = try ui.state()
        screen(centre(first.intersection(top))).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 && $0.tool == "lasso" }
        try countsEqual(before)
        XCTAssertEqual(try bounds().minX, top.minX, accuracy: 2, "Quick selection must hit the upper copy and leave no ink dot")
    }

    func testEmptyCanvasTapDeselectsAndRemovesObjectMenu() throws {
        try selectedInk(); try clear()
        XCTAssertFalse(query("cmd.clipboard.copy").allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertFalse(query("Selection").allElementsBoundByIndex.contains { ($0.value as? String)?.contains("object") == true })
    }

    func testEscapeDeselectsAndRemovesHandles() throws {
        try selectedInk(); key(XCUIKeyboardKey.escape.rawValue, [])
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 0 }
        XCTAssertFalse(query("cmd.clipboard.copy").allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertFalse(query("Selection").allElementsBoundByIndex.contains {
            ($0.value as? String)?.contains("object") == true
        }, "Escape must remove transform handles as well as the object menu")
    }

    // MARK: lasso.filters — each category has a nonempty positive control, off and restored-on assertions.

    private func filter(_ label: String, excluded: Int) throws {
        try clear()
        let total = try ui.state().itemCountOnPage
        try selectAll(total)
        let selected = try bounds().insetBy(dx: -12, dy: -12), canvas = ui.canvas.frame
        let all = CGRect(x: (selected.minX - canvas.minX) / canvas.width,
                         y: (selected.minY - canvas.minY) / canvas.height,
                         width: selected.width / canvas.width, height: selected.height / canvas.height)
        try clear(); try loop(all, count: total)
        try lassoSettings(); try toggle(label, to: false); outside()
        try clear(); try loop(all, count: total - excluded)
        try lassoSettings(); try toggle(label, to: true); outside()
        try clear(); try loop(all, count: total)
    }
    func testFilterHandwritingIndependently() throws { try draw(); try filter("Handwriting", excluded: 2) }
    func testFilterHighlighterIndependently() throws { try draw(tool: "highlighter"); try filter("Highlighter", excluded: 1) }
    func testFilterShapesIndependently() throws { try filter("Shapes", excluded: 1) }
    func testFilterTextIndependently() throws { try filter("Text", excluded: 1) }
    func testFilterStickyIndependently() throws { try filter("Sticky notes", excluded: 1) }
    func testFilterTapeIndependently() throws {
        try ui.selectTool("tape"); let before = try ui.state()
        try ui.drawStroke([CGPoint(x: 0.4, y: 0.62), CGPoint(x: 0.6, y: 0.67)])
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        try filter("Tape", excluded: 1)
    }
    func testFilterImagesIndependently() throws { try pasteImage(); try filter("Images", excluded: 1) }
    func testFilterCommentsIndependently() throws {
        try pageMenu(); try tap("Add Comment")
        let field = try control("Add a comment"); field.tap(); field.typeText("Selection filter comment")
        try tap("Send"); try ui.dismissSheets()
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == 5 }
        try filter("Comments", excluded: 1)
    }
    func testFilterMathsIndependently() throws {
        try selectedInk(); try menu("Convert", "Maths")
        let addLine = query("Add line", type: .button).firstMatch
        try wait("Maths recognition must finish before editing its preview", timeout: 30) {
            addLine.exists && addLine.isEnabled && addLine.isHittable
        }
        if !query("LaTeX line 1").firstMatch.exists { addLine.tap() }
        for _ in 0..<64 {
            if !query("Remove line 2").firstMatch.exists { break }
            try tap("Remove line 2", scroll: true)
        }
        XCTAssertFalse(query("Remove line 2").firstMatch.exists)
        let field = try control("LaTeX line 1"); field.tap(); key("a"); field.typeText("x=2")
        try wait("Valid LaTeX must enable Apply") { self.query("Apply", type: .button).firstMatch.isEnabled }
        try tap("Apply"); try tap("Done")
        try filter("Maths", excluded: 1)
    }

    // MARK: selection.objectMenu, menu.showAt, objectmenu.style

    func testObjectMenuQuickActionsAndApplicableExtensions() throws {
        try selectedInk()
        screen(centre(try bounds())).tap()
        for id in ["clipboard.cut", "clipboard.copy", "item.duplicate", "item.recolor"] {
            XCTAssertTrue(try control("cmd." + id).isEnabled)
        }
        try menu("Smart Ink", "Edit Handwriting")
        _ = try ui.waitForState(timeout: 10) { $0.tool == "smartink.edit" }
        XCTAssertTrue(query("Handwriting being edited").firstMatch.waitForExistence(timeout: 8))
    }

    func testBlankPageContextMenuAnchorsAndInsertSpaceActsAtPoint() throws {
        try draw(); try loop(count: 1); let before = try bounds(); try clear()
        let anchor = CGPoint(x: 0.62, y: 0.52)
        try pageMenu(at: anchor)
        let item = try control("Insert Space")
        XCTAssertLessThan(abs(item.frame.midX - ui.coordinate(anchor).screenPoint.x), ui.canvas.frame.width / 2)
        item.tap()
        try loop(CGRect(x: 0.36, y: 0.52, width: 0.29, height: 0.40), count: 1)
        XCTAssertGreaterThan(try bounds().minY, before.minY + 10, "Insert Space must move ink below its page-menu anchor")
        try undoBounds(before)
    }

    func testStyleInspectorOpensForSelectedImage() throws {
        try pasteImage()
        let before = try ui.state()
        try clear(); let original = try pixels()
        try loop(count: 1)
        try menu("Style")
        XCTAssertTrue(query("Crop").firstMatch.waitForExistence(timeout: 8), "objectmenu.style must render the matching image inspector")
        try tap("Flip Horizontally")
        outside(); try clear()
        try wait("Image inspector flip must move the asymmetric image's blue stripe") { ((try? self.pixels().changed(from: original)) ?? 0) > 100 }
        try countsEqual(before)
        try ui.tapCommand("edit.undo")
        try wait("Undo flip must restore the original image") { ((try? self.pixels().changed(from: original)) ?? Int.max) < 30 }
    }

    // MARK: item.transform.move/scale/resize/rotate, selection.nudge

    func testMoveAndShiftMovePreserveGeometryAndUndo() throws {
        try selectedInk(); let original = try bounds(); let before = try ui.state()
        drag(centre(original), CGPoint(x: original.midX + 70, y: original.midY + 45))
        try wait("Dragging must move the selected ink") { ((try? self.bounds().minX) ?? 0) > original.minX + 40 }
        let moved = try bounds()
        XCTAssertEqual(moved.width, original.width, accuracy: 2); XCTAssertEqual(moved.height, original.height, accuracy: 2)
        try countsEqual(before); try undoBounds(original)
        drag(centre(original), CGPoint(x: original.midX + 70, y: original.midY + 20), modifiers: .shift)
        try wait("Shift drag must move along the dominant axis") { ((try? self.bounds().minX) ?? 0) > original.minX + 40 }
        XCTAssertEqual(try bounds().minY, original.minY, accuracy: 2)
        try undoBounds(original)
    }

    func testCornerScalePreservesAspectAndOppositeOrigin() throws {
        try selectedInk(); let b = try bounds()
        drag(CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.maxX + 60, y: b.maxY + 45))
        try wait("Corner bead must enlarge the selection") { ((try? self.bounds().width) ?? 0) > b.width + 20 }
        let a = try bounds()
        XCTAssertEqual(a.width / a.height, b.width / b.height, accuracy: 0.06)
        XCTAssertEqual(a.minX, b.minX, accuracy: 2); XCTAssertEqual(a.minY, b.minY, accuracy: 2)
        try undoBounds(b)
    }

    func testOptionCornerScaleUsesCentreOrigin() throws {
        try selectedInk(); let b = try bounds()
        drag(CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.maxX + 40, y: b.maxY + 30), modifiers: .option)
        try wait("Option corner drag must scale") { ((try? self.bounds().width) ?? 0) > b.width + 20 }
        let a = try bounds()
        XCTAssertEqual(a.midX, b.midX, accuracy: 2); XCTAssertEqual(a.midY, b.midY, accuracy: 2)
        try undoBounds(b)
    }

    func testShiftCornerScalePreservesAspectAndRedoRestoresScaledGeometry() throws {
        try selectedInk(); let original = try bounds(), before = try ui.state()
        drag(CGPoint(x: original.maxX, y: original.maxY),
             CGPoint(x: original.maxX + 65, y: original.maxY + 20), modifiers: .shift)
        try wait("Shift corner drag must enlarge the selected ink") {
            ((try? self.bounds().width) ?? 0) > original.width + 20
        }
        let scaled = try bounds()
        XCTAssertEqual(scaled.width / scaled.height, original.width / original.height, accuracy: 0.06)
        XCTAssertEqual(scaled.minX, original.minX, accuracy: 2)
        XCTAssertEqual(scaled.minY, original.minY, accuracy: 2)
        try countsEqual(before); try undoBounds(original)
        try ui.tapCommand("edit.redo")
        try wait("Redo must restore both dimensions of the scaled ink") {
            guard let actual = try? self.bounds() else { return false }
            return abs(actual.width - scaled.width) < 2 && abs(actual.height - scaled.height) < 2
        }
        try countsEqual(before)
    }

    func testEdgeResizeChangesOnlyWidth() throws {
        try selectedInk(); let b = try bounds()
        drag(CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.maxX + 60, y: b.midY))
        try wait("Edge bead must widen the selection") { ((try? self.bounds().width) ?? 0) > b.width + 20 }
        let a = try bounds()
        XCTAssertEqual(a.height, b.height, accuracy: 2); XCTAssertEqual(a.minX, b.minX, accuracy: 2)
        try undoBounds(b)
    }

    func testOptionEdgeResizeUsesCentreAndKeepsOtherDimension() throws {
        try selectedInk(); let b = try bounds()
        drag(CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.maxX + 40, y: b.midY), modifiers: .option)
        try wait("Option edge drag must widen about the centre") { ((try? self.bounds().width) ?? 0) > b.width + 30 }
        let a = try bounds()
        XCTAssertEqual(a.midX, b.midX, accuracy: 2); XCTAssertEqual(a.midY, b.midY, accuracy: 2)
        XCTAssertEqual(a.height, b.height, accuracy: 2)
        try undoBounds(b)
    }

    func testShiftEdgeResizeKeepsProportions() throws {
        try selectedInk(); let b = try bounds()
        drag(CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.maxX + 60, y: b.midY), modifiers: .shift)
        try wait("Shift edge drag must resize") { ((try? self.bounds().width) ?? 0) > b.width + 20 }
        XCTAssertEqual(try bounds().width / bounds().height, b.width / b.height, accuracy: 0.06)
        try undoBounds(b)
    }

    func testRotationBeadRotatesAndHitTargetFollows() throws {
        try selectedInk(); let b = try bounds()
        drag(CGPoint(x: b.midX, y: b.minY - 24), CGPoint(x: b.maxX + 24, y: b.midY))
        try wait("Rotation bead must exchange the wide/tall extents") { abs(((try? self.bounds().height) ?? b.height) - b.width) < 8 }
        let rotated = try bounds()
        XCTAssertEqual(rotated.midX, b.midX, accuracy: 3); XCTAssertEqual(rotated.midY, b.midY, accuracy: 3)
        drag(centre(rotated), CGPoint(x: rotated.midX + 40, y: rotated.midY))
        try wait("Rotated object's body hit target must follow its content") { ((try? self.bounds().minX) ?? 0) > rotated.minX + 25 }
        try undoBounds(rotated); try undoBounds(b)
    }

    func testArrowAndShiftArrowNudgesAllDirectionsAndUndo() throws {
        try selectedInk()
        for (keyName, dx, dy) in [(XCUIKeyboardKey.rightArrow.rawValue, 1.0, 0.0),
                                  (XCUIKeyboardKey.downArrow.rawValue, 0.0, 1.0),
                                  (XCUIKeyboardKey.leftArrow.rawValue, -1.0, 0.0),
                                  (XCUIKeyboardKey.upArrow.rawValue, 0.0, -1.0)] {
            for large in [false, true] {
                let b = try bounds(), z = try ui.state().zoom, step = large ? 10.0 : 1.0
                key(keyName, large ? .shift : [])
                try wait("Arrow nudge must move by \(step) page points") {
                    guard let a = try? self.bounds() else { return false }
                    return abs(a.minX - b.minX - dx * step * z) < z * 0.25 && abs(a.minY - b.minY - dy * step * z) < z * 0.25
                }
                try undoBounds(b)
            }
        }
    }

    private func shape(_ kind: String, from: CGPoint, to: CGPoint) throws {
        try ui.selectTool("shape")
        if !query(kind, type: .button).allElementsBoundByIndex.contains(where: { $0.isHittable && !$0.identifier.hasPrefix("tool.") }) {
            try tap("tool.shape")
        }
        try tap(kind); outside()
        let before = try ui.state()
        try ui.drawStroke([from, to])
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
        try clear()
    }

    func testMovingContainerMovesAttachedInkInSameUndoStep() throws {
        try shape("Rectangle", from: CGPoint(x: 0.38, y: 0.52), to: CGPoint(x: 0.59, y: 0.73))
        try draw([CGPoint(x: 0.42, y: 0.58), CGPoint(x: 0.47, y: 0.65), CGPoint(x: 0.53, y: 0.59)])
        try lassoSettings(); try toggle("Shapes", to: false); outside(); try loop(count: 1)
        let child = try bounds()
        try clear(); try lassoSettings(); try toggle("Shapes", to: true); outside()
        ui.coordinate(CGPoint(x: 0.38, y: 0.60)).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        let parent = try bounds(), before = try ui.state()
        drag(centre(parent), CGPoint(x: parent.midX + 55, y: parent.midY + 35))
        let moved = try bounds()
        XCTAssertGreaterThan(moved.minX, parent.minX + 30)
        try clear(); try lassoSettings(); try toggle("Shapes", to: false); outside()
        try loop(CGRect(x: 0.36, y: 0.5, width: 0.34, height: 0.34), count: 1)
        let movedChild = try bounds()
        XCTAssertEqual(movedChild.minX - child.minX, moved.minX - parent.minX, accuracy: 2)
        XCTAssertEqual(movedChild.minY - child.minY, moved.minY - parent.minY, accuracy: 2)
        try countsEqual(before)
        try ui.tapCommand("edit.undo")
        try clear(); try loop(count: 1)
        XCTAssertEqual(try bounds().minX, child.minX, accuracy: 2)
        XCTAssertEqual(try bounds().minY, child.minY, accuracy: 2)
    }

    func testMovingShapeUpdatesAttachedConnectorAndUndoRestoresEndpoint() throws {
        try shape("Rectangle", from: CGPoint(x: 0.38, y: 0.55), to: CGPoint(x: 0.48, y: 0.67))
        try shape("Rectangle", from: CGPoint(x: 0.59, y: 0.55), to: CGPoint(x: 0.69, y: 0.67))
        try shape("Connector", from: CGPoint(x: 0.48, y: 0.61), to: CGPoint(x: 0.59, y: 0.61))
        ui.coordinate(CGPoint(x: 0.535, y: 0.61)).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        let connector = try bounds(); try clear()
        ui.coordinate(CGPoint(x: 0.38, y: 0.61)).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        let parent = try bounds(), before = try ui.state()
        drag(centre(parent), CGPoint(x: parent.midX, y: parent.midY + 65))
        try clear()
        // Lasso only the gap between the two shapes to observe the connector's new extent.
        try loop(CGRect(x: 0.50, y: 0.57, width: 0.06, height: 0.19), count: 1)
        XCTAssertGreaterThan(try bounds().height, connector.height + 20, "Connector must follow the moved shape's anchor")
        try countsEqual(before)
        try ui.tapCommand("edit.undo"); try clear()
        ui.coordinate(CGPoint(x: 0.535, y: 0.61)).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        XCTAssertEqual(try bounds().height, connector.height, accuracy: 2)
    }

    // MARK: item.duplicate, clipboard.copy/cut/paste/matchStyle

    func testDuplicateMenuCreatesIndependentOffsetCopyAndUndoRedo() throws {
        try selectedInk(); let before = try ui.state(), b = try bounds()
        try ui.tapCommand("item.duplicate")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        let copy = try bounds()
        XCTAssertGreaterThan(copy.minX, b.minX); XCTAssertGreaterThan(copy.minY, b.minY)
        try ui.tapCommand("item.delete")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage }
        try loop(count: 1)
        XCTAssertEqual(try bounds().minX, b.minX, accuracy: 2, "Deleting the duplicate must leave the original")
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        try ui.tapCommand("edit.redo")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage }
    }
    func testCommandDDuplicatesSelectedInk() throws {
        try selectedInk(); let before = try ui.state(); key("d")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try undoCounts(before)
    }
    func testOptionDragDuplicatesAndLeavesOriginal() throws {
        try selectedInk(); let b = try bounds(), before = try ui.state()
        drag(centre(b), CGPoint(x: b.midX + 90, y: b.midY + 30), modifiers: .option)
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        XCTAssertGreaterThan(try bounds().minX, b.minX + 50)
        try undoCounts(before)
    }
    func testCopyMenuThenPagePastePreservesSourceAndGeometry() throws {
        try selectedInk(); let before = try ui.state(), original = try bounds()
        try ui.tapCommand("clipboard.copy"); try countsEqual(before)
        try clear(); try loop(count: 1)
        XCTAssertEqual(try bounds().minX, original.minX, accuracy: 0.75)
        XCTAssertEqual(try bounds().minY, original.minY, accuracy: 0.75, "Copy must leave source geometry unchanged")
        try clear(); try pageMenu(at: CGPoint(x: 0.46, y: 0.82)); try tap("Paste")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        XCTAssertEqual(try bounds().width, original.width, accuracy: 2)
        try undoCounts(before)
    }
    func testCommandCCopyAndCommandVPaste() throws {
        try selectedInk(); let before = try ui.state(); key("c"); try countsEqual(before); key("v")
        _ = try ui.waitForState(timeout: 10) { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
        try undoCounts(before)
    }
    func testCutMenuRemovesAndPasteRestoresContent() throws {
        try selectedInk(); let before = try ui.state()
        try ui.tapCommand("clipboard.cut")
        _ = try ui.waitForState(timeout: 10) { $0.strokeCountOnPage == before.strokeCountOnPage - 1 && $0.selectionCount == 0 }
        try pageMenu(); try tap("Paste")
        _ = try ui.waitForState(timeout: 10) { $0.strokeCountOnPage == before.strokeCountOnPage && $0.itemCountOnPage == before.itemCountOnPage }
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState(timeout: 10) { $0.strokeCountOnPage == before.strokeCountOnPage - 1 }
        try undoCounts(before)
    }
    func testCommandXCutIsUndoableAndPasteable() throws {
        try selectedInk(); let before = try ui.state(); key("x")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage - 1 }
        try undoCounts(before); key("v")
        _ = try ui.waitForState(timeout: 10) { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
    }

    private func pasteImage(at point: CGPoint = CGPoint(x: 0.46, y: 0.60)) throws {
        // An asymmetric external PNG makes flips and cross-app representation visually testable.
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 140, height: 90)).image { c in
            UIColor.systemRed.setFill(); c.fill(CGRect(x: 0, y: 0, width: 140, height: 90))
            UIColor.systemBlue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 35, height: 90))
        }
        let before = try ui.state()
        try pageMenu(at: point); try tap("Paste")
        let allow = ui.app.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 && $0.selectionCount == 1 }
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
    }
    func testPasteExternalPNGIncreasesItemCountAndUndoRemovesAssetUse() throws {
        let before = try ui.state(); try pasteImage(); try undoCounts(before)
    }
    private func richText() throws {
        let text = NSAttributedString(string: "Selection rich text", attributes: [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.red])
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        UIPasteboard.general.items = [[UTType.rtf.identifier: data, UTType.utf8PlainText.identifier: Data(text.string.utf8)]]
    }
    func testPasteRichTextRetainsContentAndMatchStyleUsesDestinationStyle() throws {
        try richText(); let before = try ui.state()
        try pageMenu(at: CGPoint(x: 0.45, y: 0.56)); try tap("Paste")
        let allow = ui.app.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        let richBounds = try bounds()
        try clear(); try pageMenu(at: CGPoint(x: 0.45, y: 0.78)); try tap("Paste and Match Style")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage + 2 }
        XCTAssertLessThan(try bounds().height, richBounds.height, "Match Style must replace the external 36-point style with the destination text defaults")
        XCTAssertEqual(ui.app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Selection rich text'")).count, 2)
        try ui.tapCommand("edit.undo"); try undoCounts(before)
    }

    // MARK: item.delete/recolor/setLocked, ink.setStyle

    func testDeleteMenuRemovesOnlySelectionAndUndoRedoRestores() throws {
        try selectedInk(); let before = try ui.state()
        try ui.tapCommand("item.delete")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage - 1 && $0.strokeCountOnPage == before.strokeCountOnPage - 1 && $0.selectionCount == 0 }
        try undoCounts(before); try ui.tapCommand("edit.redo")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == before.itemCountOnPage - 1 }
    }
    func testDeleteKeyRemovesSelectionAndUndoRestores() throws {
        try selectedInk(); let before = try ui.state(); key(XCUIKeyboardKey.delete.rawValue, [])
        _ = try ui.waitForState(timeout: 10) { $0.strokeCountOnPage == before.strokeCountOnPage - 1 }
        try undoCounts(before)
    }
    func testRecolourSelectedInkChangesOnlyItsAppearanceAndUndoRestores() throws {
        try draw(); try clear(); let before = try pixels(), state = try ui.state()
        let upper = CGRect(x: 0.34, y: 0.15, width: 0.28, height: 0.18), untouched = try pixels(upper)
        try loop(count: 1); let geometry = try bounds(); try recolour("Crimson"); try clear()
        try wait("Colour must change rendered selected ink") { ((try? self.pixels().changed(from: before)) ?? 0) > 30 }
        XCTAssertLessThan(try pixels(upper).changed(from: untouched), 20, "Unselected fixture content must keep its appearance")
        try countsEqual(state); try loop(count: 1)
        XCTAssertEqual(try bounds().width, geometry.width, accuracy: 1)
        try ui.tapCommand("edit.undo"); try clear()
        try wait("Undo must restore the original stroke colour") { ((try? self.pixels().changed(from: before)) ?? Int.max) < 30 }
    }
    func testExistingStrokeStyleThroughInspectorChangesSelectedInkOnly() throws {
        try draw(); try clear()
        let upper = CGRect(x: 0.34, y: 0.15, width: 0.28, height: 0.18)
        let untouched = try pixels(upper), original = try pixels()
        try loop(count: 1); let before = try ui.state(), geometry = try bounds()
        try menu("Style")
        let slider = try control("Thickness", type: .slider)
        slider.adjust(toNormalizedSliderPosition: 0.85); outside()
        try countsEqual(before)
        XCTAssertTrue(try ui.state().undoAvailable)
        try clear()
        try wait("Changing Thickness must render a wider selected stroke") {
            ((try? self.pixels().changed(from: original)) ?? 0) > 30
        }
        XCTAssertLessThan(try pixels(upper).changed(from: untouched), 20,
                          "Existing stroke style must leave unselected content unchanged")
        try loop(count: 1)
        XCTAssertEqual(try bounds().midX, geometry.midX, accuracy: 2)
        XCTAssertEqual(try bounds().midY, geometry.midY, accuracy: 2)
        try clear(); let wide = try pixels(); try ui.tapCommand("edit.undo")
        try wait("ink.setStyle must visibly change existing selected strokes") { ((try? self.pixels().changed(from: wide)) ?? 0) > 30 }
        try wait("Undo Thickness must restore the original ink appearance") {
            ((try? self.pixels().changed(from: original)) ?? Int.max) < 30
        }
    }
    func testLockPreventsDragUntilUnlocked() throws {
        try selectedInk(); let b = try bounds(), before = try ui.state()
        try menu("Lock")
        XCTAssertTrue(query("cmd.item.setLocked").firstMatch.waitForExistence(timeout: 5))
        drag(centre(b), CGPoint(x: b.midX + 60, y: b.midY + 25))
        XCTAssertEqual(try bounds().minX, b.minX, accuracy: 2)
        XCTAssertEqual(try bounds().minY, b.minY, accuracy: 2)
        try countsEqual(before)
        try tap("Unlock")
        drag(centre(b), CGPoint(x: b.midX + 60, y: b.midY + 25))
        try wait("Unlock must permit transforms again") { ((try? self.bounds().minX) ?? 0) > b.minX + 30 }
        try undoBounds(b)
    }

    // MARK: item.arrange.front/forward/backward/back — hit-testing observes the actual stack.

    private func arrange(_ action: String, toFrontFirst: Bool = false, oneStep: Bool = false) throws {
        try pasteImage(); let first = try bounds()
        try ui.tapCommand("item.duplicate")
        _ = try ui.waitForState(timeout: 8) { $0.itemCountOnPage == 6 }
        let middle = try bounds()
        try ui.tapCommand("item.duplicate")
        _ = try ui.waitForState(timeout: 8) { $0.itemCountOnPage == 7 }
        let last = try bounds()
        if toFrontFirst { try menu("Arrange", "Send to Back") }
        try menu("Arrange", action)
        let overlap = centre(first.intersection(middle).intersection(last))
        try clear(); screen(overlap).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        if action == "Bring to Front" {
            XCTAssertEqual(try bounds().minX, last.minX, accuracy: 2, "Front must make the selected item topmost")
        } else {
            XCTAssertEqual(try bounds().minX, middle.minX, accuracy: 2, "The unselected upper peer must now be topmost")
            try ui.tapCommand("item.delete")
            _ = try ui.waitForState(timeout: 8) { $0.itemCountOnPage == 6 }
            screen(overlap).tap()
            _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
            XCTAssertEqual(try bounds().minX, oneStep ? last.minX : first.minX, accuracy: 2,
                           "One-step arrangement must stop between peers; Back must pass both peers")
            try ui.tapCommand("edit.undo")
        }
        try ui.tapCommand("edit.undo")
        XCTAssertEqual(try ui.state().itemCountOnPage, 7, "Arrange undo must preserve every object")
        try clear(); screen(overlap).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        XCTAssertEqual(try bounds().minX, toFrontFirst ? middle.minX : last.minX, accuracy: 2,
                       "Undo Arrange must restore the previous stacking order")
    }
    func testBringToFrontRendersAboveAllPeers() throws { try arrange("Bring to Front", toFrontFirst: true) }
    func testBringForwardAdvancesExactlyOneStep() throws { try arrange("Bring Forward", toFrontFirst: true, oneStep: true) }
    func testSendBackwardRetreatsExactlyOneStep() throws { try arrange("Send Backward", oneStep: true) }
    func testSendToBackRendersBelowAllPeers() throws { try arrange("Send to Back") }

    // MARK: selection.screenshot — export a real PNG, retaining the document and history.

    private func copyScreenshotAndCheck(_ before: QAState) throws {
        // Copy in UIActivityViewController transfers the generated PNG to the system clipboard.
        // F013 exports through the share sheet. The selection's own Copy button remains
        // visible behind that sheet and copies a fragment instead of the screenshot.
        let activities = ui.app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activities.waitForExistence(timeout: 15), "Take Screenshot must present the system share sheet")
        let copy = activities.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        try wait("The screenshot share sheet must offer Copy") { copy.exists && copy.isHittable && copy.isEnabled }
        copy.tap()
        try wait("Take Screenshot must export a decodable PNG", timeout: 15) {
            guard let data = UIPasteboard.general.data(forPasteboardType: UTType.png.identifier),
                  let image = UIImage(data: data) else { return false }
            return image.size.width > 10 && image.size.height > 10
        }
        let exported = try XCTUnwrap(UIPasteboard.general.image?.cgImage)
        var rgba = [UInt8](repeating: 0, count: exported.width * exported.height * 4)
        try rgba.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: exported.width, height: exported.height,
                bitsPerComponent: 8, bytesPerRow: exported.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(exported, in: CGRect(x: 0, y: 0, width: exported.width, height: exported.height))
        }
        var visibleInk = 0
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let brightness = Int(rgba[index]) + Int(rgba[index + 1]) + Int(rgba[index + 2])
            if rgba[index + 3] > 128 && brightness < 420 { visibleInk += 1 }
        }
        XCTAssertGreaterThan(visibleInk, 25, "Exported PNG must contain the chosen ink, not an empty region")
        try countsEqual(before)
        XCTAssertEqual(try ui.state().undoAvailable, before.undoAvailable, "Screenshot is a read-only action")
    }
    func testSelectionScreenshotExportsPNGWithoutEditingDocument() throws {
        try selectedInk(); let before = try ui.state()
        UIPasteboard.general.items = []
        try menu("Take Screenshot")
        try copyScreenshotAndCheck(before)
    }
    func testPageRegionScreenshotExportsChosenRegion() throws {
        try draw(); try clear(); let before = try ui.state()
        UIPasteboard.general.items = []
        try pageMenu(); try tap("Take Screenshot")
        _ = try ui.waitForState(timeout: 8) { $0.tool == "objectmenu.screenshotTool" }
        try ui.drawStroke([CGPoint(x: 0.38, y: 0.52), CGPoint(x: 0.63, y: 0.76)])
        try copyScreenshotAndCheck(before)
        let image = try XCTUnwrap(UIPasteboard.general.image)
        let expectedRatio = (0.25 * ui.canvas.frame.width) / (0.24 * ui.canvas.frame.height)
        XCTAssertEqual(image.size.width / image.size.height, expectedRatio, accuracy: 0.05,
                       "PNG dimensions must follow the selected region")
    }

    // MARK: smartink.edit, handwriting.reflow/straighten/align/insertSpace/restyle, selection.convert

    private func words() throws {
        // Two non-overlapping word shapes on the first line and a shorter second line.
        for (x, y) in [(0.40, 0.58), (0.53, 0.58), (0.43, 0.71)] {
            try draw([CGPoint(x: x, y: y + 0.03), CGPoint(x: x + 0.02, y: y),
                      CGPoint(x: x + 0.04, y: y + 0.03), CGPoint(x: x + 0.06, y: y)])
        }
        try loop(count: 3)
    }
    private func editWords() throws {
        try words(); try menu("Smart Ink", "Edit Handwriting")
        _ = try ui.waitForState(timeout: 8) { $0.tool == "smartink.edit" }
        XCTAssertTrue(query("Handwriting being edited").firstMatch.waitForExistence(timeout: 8))
    }
    func testEditHandwritingDoubleTapSelectsOneWordWithoutUnrelatedWords() throws {
        try editWords()
        ui.coordinate(CGPoint(x: 0.43, y: 0.595)).doubleTap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        let word = try control("Selected word")
        XCTAssertLessThan(word.frame.maxX, ui.coordinate(CGPoint(x: 0.52, y: 0.595)).screenPoint.x)
        let before = try ui.state()
        try tap("Delete Word")
        _ = try ui.waitForState(timeout: 8) { $0.strokeCountOnPage == before.strokeCountOnPage - 1 }
        try undoCounts(before)
    }
    func testHandwritingReflowNarrowWidthPreservesStrokeCountAndWordShapes() throws {
        try editWords(); let before = try ui.state()
        let block = try control("Handwriting being edited"), original = block.frame
        let right = try control("Right edge")
        drag(centre(right.frame), CGPoint(x: original.minX + original.width * 0.48, y: right.frame.midY))
        try wait("Narrowing the handwriting column must add lines") { block.frame.height > original.height + 10 }
        try countsEqual(before)
        let summary = block.value as? String
        XCTAssertTrue(summary?.contains("3 words") == true, "Reflow must retain all word clusters")
        try ui.tapCommand("edit.undo")
        try wait("Undo reflow restores line layout") { abs(block.frame.height - original.height) < 2 }
    }
    func testStraightenLinesLevelsSelectedBaselines() throws {
        for x in [0.41, 0.48, 0.55] {
            let y = 0.56 + (x - 0.41) * 0.4
            try draw([CGPoint(x: x, y: y), CGPoint(x: x + 0.025, y: y + 0.045), CGPoint(x: x + 0.05, y: y + 0.025)])
        }
        try loop(count: 3); let b = try bounds(), before = try ui.state()
        try menu("Smart Ink", "Straighten Lines")
        try wait("Straighten Lines must reduce the slanted baseline's vertical extent") { ((try? self.bounds().height) ?? b.height) < b.height - 5 }
        try countsEqual(before); try undoBounds(b)
    }
    private func alignWords(_ title: String) throws {
        try editWords(); let before = try ui.state()
        let original = try pixels()
        if query(title, type: .button).allElementsBoundByIndex.contains(where: { $0.isHittable }) { try tap(title) }
        else { try tap("Align"); try tap(title) }
        try wait("\(title) must translate the shorter line") { ((try? self.pixels().changed(from: original)) ?? 0) > 30 }
        try countsEqual(before)
        try ui.tapCommand("edit.undo")
        try wait("Undo alignment must restore the line positions") { ((try? self.pixels().changed(from: original)) ?? Int.max) < 30 }
    }
    func testHandwritingAlignLeft() throws { try alignWords("Align Left") }
    func testHandwritingAlignCentre() throws { try alignWords("Align Centre") }
    func testHandwritingAlignRight() throws { try alignWords("Align Right") }
    func testInsertVerticalSpaceKeepsInkAboveAndMovesInkBelow() throws {
        try draw([CGPoint(x: 0.42, y: 0.56), CGPoint(x: 0.56, y: 0.56)])
        try draw([CGPoint(x: 0.42, y: 0.73), CGPoint(x: 0.56, y: 0.73)])
        try clear()
        let upper = CGRect(x: 0.38, y: 0.52, width: 0.25, height: 0.08), top = try pixels(upper)
        try loop(CGRect(x: 0.38, y: 0.69, width: 0.25, height: 0.08), count: 1)
        let bottom = try bounds(), before = try ui.state(); try clear()
        try pageMenu(at: CGPoint(x: 0.64, y: 0.65)); try tap("Insert Space")
        try loop(CGRect(x: 0.38, y: 0.7, width: 0.25, height: 0.22), count: 1)
        XCTAssertGreaterThan(try bounds().minY, bottom.minY + 10)
        try countsEqual(before); try clear()
        XCTAssertLessThan(try pixels(upper).changed(from: top), 20, "Insert Space must keep all ink above its anchor fixed")
        try ui.tapCommand("edit.undo")
        try loop(CGRect(x: 0.38, y: 0.69, width: 0.25, height: 0.08), count: 1)
        XCTAssertEqual(try bounds().minY, bottom.minY, accuracy: 2)
    }
    func testNeatenHandwritingChangesInkAndUndoRestoresMeaningfulSource() throws {
        // Draw the word HI using four actual pen strokes, readable by on-device recognition.
        for path in [[CGPoint(x: 0.41, y: 0.56), CGPoint(x: 0.41, y: 0.68)],
                     [CGPoint(x: 0.47, y: 0.56), CGPoint(x: 0.47, y: 0.68)],
                     [CGPoint(x: 0.41, y: 0.62), CGPoint(x: 0.47, y: 0.62)],
                     [CGPoint(x: 0.55, y: 0.57), CGPoint(x: 0.558, y: 0.70)]] { try draw(path) }
        try clear(); let source = try pixels(), before = try ui.state()
        try loop(count: 4); try menu("Restyle Handwriting", "Neaten Handwriting")
        try clear()
        try wait("Neaten must produce visibly restyled handwriting", timeout: 30) { ((try? self.pixels().changed(from: source)) ?? 0) > 40 }
        let restyled = try ui.state()
        try loop(count: restyled.strokeCountOnPage - 1)
        try menu("Convert", "Text")
        let recognised = try control("Recognised text")
        try wait("Restyled HI must retain its recognised meaning", timeout: 30) {
            let text = (recognised.value as? String ?? "").uppercased().filter { $0.isLetter }
            return text == "HI"
        }
        try tap("Cancel")
        try ui.tapCommand("edit.undo"); try clear()
        try countsEqual(before)
        try wait("Undo neaten must restore the exact source handwriting") { ((try? self.pixels().changed(from: source)) ?? Int.max) < 30 }
    }
    private func convertCancel(_ kind: String, title: String, cancel: String) throws {
        try selectedInk(); let before = try ui.state(), b = try bounds()
        try menu("Convert", kind)
        XCTAssertTrue(query(title).firstMatch.waitForExistence(timeout: 15), "Convert must open the \(kind) preview")
        try tap(cancel)
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == before.selectionCount }
        try countsEqual(before)
        XCTAssertEqual(try bounds().minX, b.minX, accuracy: 1)
        XCTAssertEqual(try ui.state().undoAvailable, before.undoAvailable)
    }
    func testConvertToTextCancelPreservesSelectionAndContent() throws { try convertCancel("Text", title: "Convert to Text", cancel: "Cancel") }
    func testConvertToMathsDoneWithoutApplyPreservesSelectionAndContent() throws { try convertCancel("Maths", title: "Convert to Maths", cancel: "Done") }

    // MARK: selection.selectAll / layer.moveItems

    private func enableLayers() throws {
        key(",")
        // DESIGN §14.8: iPad Settings shows sections, then their pages.
        try tap("Editing")
        try tap("Layers", scroll: true); try toggle("Layers", to: true)
        try ui.dismissSheets()
    }
    func testSelectAllIncludesOnlyActiveLayer() throws {
        try enableLayers()
        key("2", [.command, .option]); try draw()
        try clear(); try selectAll(1)
        key("1", [.command, .option]); try clear(); try selectAll(4)
    }
    func testMoveObjectsToLayerChangesActiveLayerSelectionAndUndo() throws {
        try enableLayers(); try selectedInk(); let before = try ui.state()
        try menu("Move to Layer", "Layer 2")
        try clear(); try selectAll(4)
        key("2", [.command, .option]); try clear(); try selectAll(1)
        try countsEqual(before)
        try ui.tapCommand("edit.undo")
        try clear(); try selectAll(0)
        key("1", [.command, .option]); try clear(); try selectAll(5)
    }

    // MARK: selection.snap — both exposed options, alignment also controls equal-spacing guides.

    private func snapping(align: Bool, grid: Bool) throws {
        key(","); try tap("Editing"); try tap("Alignment and snapping", scroll: true)
        try toggle("Alignment guides", to: align); try toggle("Snap to grid", to: grid)
        try ui.dismissSheets()
    }
    func testAlignmentSnappingFollowsToggleNearPeer() throws {
        try pasteImage(); let peer = try bounds()
        try ui.tapCommand("item.duplicate")
        _ = try ui.waitForState(timeout: 8) { $0.itemCountOnPage == 6 }
        try snapping(align: true, grid: false)
        var b = try bounds()
        drag(centre(b), CGPoint(x: b.midX + 160, y: peer.midY + 3))
        XCTAssertEqual(try bounds().midY, peer.midY, accuracy: 1.5, "Enabled alignment must snap near the peer centre")
        try ui.tapCommand("edit.undo")
        try snapping(align: false, grid: false); b = try bounds()
        drag(centre(b), CGPoint(x: b.midX + 160, y: peer.midY + 5))
        XCTAssertGreaterThan(abs(try bounds().midY - peer.midY), 2, "Disabled alignment must preserve the unsnapped drop")
    }
    func testEqualSpacingSnapsBetweenPeersAndToggleDisablesIt() throws {
        try snapping(align: false, grid: false)
        try pasteImage(at: CGPoint(x: 0.38, y: 0.65)); let left = try bounds(); try clear()
        try pasteImage(at: CGPoint(x: 0.69, y: 0.65)); let right = try bounds(); try clear()
        try pasteImage(at: CGPoint(x: 0.51, y: 0.80)); let original = try bounds()
        let target = CGPoint(x: (left.maxX + right.minX) / 2 + 3, y: left.midY)
        try snapping(align: true, grid: false)
        drag(centre(original), target)
        let snapped = try bounds()
        XCTAssertEqual(snapped.minX - left.maxX, right.minX - snapped.maxX, accuracy: 1.5,
                       "Smart spacing must make the two gaps equal")
        try undoBounds(original)
        try snapping(align: false, grid: false)
        drag(centre(original), target)
        let free = try bounds()
        XCTAssertGreaterThan(abs((free.minX - left.maxX) - (right.minX - free.maxX)), 3,
                             "Disabling alignment also disables equal-spacing snapping")
    }

    func testGridSnappingFollowsToggle() throws {
        try selectedInk(); try snapping(align: false, grid: false)
        let original = try bounds()
        let destination = CGPoint(x: original.midX + 47, y: original.midY + 33)
        drag(centre(original), destination); let free = try bounds(); try undoBounds(original)
        try snapping(align: false, grid: true)
        drag(centre(original), destination); let snapped = try bounds()
        XCTAssertGreaterThan(hypot(snapped.minX - free.minX, snapped.minY - free.minY), 1,
                             "Enabled grid must quantize the drop to the template grid")
        try undoBounds(original)
    }

    // MARK: item.moveToPage — a real cross-page drag; source and destination checked through page navigation.

    private func goToPage(_ number: Int, original: String? = nil) throws {
        key("g", [.command, .option])
        let field = try control("Page number or title"); field.tap(); field.typeText(String(number)); try tap("Go")
        _ = try ui.waitForState(timeout: 10) { !$0.openPanels.contains("pages.goToPage") && (original == nil || $0.page == original) }
    }
    private func crossPage(copy: Bool) throws {
        try selectedInk(); let source = try ui.state()
        try ui.pinchZoom(scale: 0.5)
        let zoomed = try ui.waitForState(timeout: 10) { $0.zoom < source.zoom }
        XCTAssertGreaterThanOrEqual(zoomed.zoom, 0.499); XCTAssertLessThanOrEqual(zoomed.zoom, 8.001)
        let page2 = ui.app.otherElements.matching(NSPredicate(format: "label == 'Page 2 of 4'")).allElementsBoundByIndex.first { $0.frame.height > 100 }
        let target = try XCTUnwrap(page2, "Cross-page drag needs the adjacent page laid out")
        let visible = target.frame.intersection(ui.canvas.frame)
        XCTAssertGreaterThan(visible.height, 30, "Zoomed adjacent page must expose a real drop target")
        drag(centre(try bounds()), centre(visible), modifiers: copy ? .option : [])
        try goToPage(2)
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == 1 && $0.strokeCountOnPage == 1 }
        try goToPage(1, original: source.page)
        XCTAssertEqual(try ui.state().itemCountOnPage, source.itemCountOnPage - (copy ? 0 : 1))
        try ui.tapCommand("edit.undo")
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == source.itemCountOnPage }
        try goToPage(2)
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == 0 }
    }
    func testMoveAcrossPagesAndLinkedUndo() throws { try crossPage(copy: false) }
    func testCopyDragAcrossPagesKeepsSourceAndLinkedUndo() throws { try crossPage(copy: true) }

    // MARK: clipboard.externalDrag and selection.provenance

    func testExternalDragToSafariTransfersImageAndPreservesSource() throws {
        // The dedicated simulator includes Safari, but not Notes. This local, offline HTML document
        // supplies an external editable drop target; no Nib model or command is injected.
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        defer {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Selection-externalDrag-system-screen"; attachment.lifetime = .keepAlways; add(attachment)
            safari.terminate()
            ui.app.activate()
        }
        safari.launch()
        for label in ["Continue", "Not Now"] {
            let button = safari.buttons[label]
            if button.exists && button.isHittable { button.tap() }
        }
        let address = safari.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'URL' OR label == 'Address' OR label == 'Search or enter website name'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Safari must expose its address field")
        address.tap()
        let html = """
        <html><meta name="viewport" content="width=device-width,initial-scale=1">
        <body><h1>Nib drag test</h1><div contenteditable="true" role="textbox"
        aria-label="External drop target" style="min-height:600px;border:2px solid black">Drop here</div></body></html>
        """
        let url = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        safari.typeKey("a", modifierFlags: .command); safari.typeText(url + "\n")
        let editor = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'External drop target'")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "The external HTML fixture must load before testing drag/drop")
        ui.app.activate()
        try pasteImage(); let source = try ui.state()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let windowPredicate = NSPredicate(format: "label CONTAINS[c] 'Multitasking' OR label == 'Window Controls'")
        let appControls = ui.app.buttons.matching(windowPredicate).firstMatch
        let systemControls = springboard.buttons.matching(windowPredicate).firstMatch
        let windowMenu = appControls.exists ? appControls : systemControls
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 5), "Cross-app drag requires real system multitasking controls")
        windowMenu.tap()
        let split = ui.app.buttons["Split View"].exists ? ui.app.buttons["Split View"] : springboard.buttons["Split View"]
        XCTAssertTrue(split.waitForExistence(timeout: 5), "The simulator must support placing the external drop target beside Nib")
        split.tap()
        let safariIcon = springboard.icons["Safari"]
        XCTAssertTrue(safariIcon.waitForExistence(timeout: 5)); safariIcon.tap()
        try wait("Nib and Safari must both expose live drop targets") { self.ui.canvas.isHittable && editor.isHittable }
        // Re-read after Split View: the canvas and selection have resized.
        screen(centre(try bounds())).press(forDuration: 0.8,
            thenDragTo: editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let transferred = safari.webViews.images.firstMatch
        XCTAssertTrue(transferred.waitForExistence(timeout: 10), "External drop must insert the selection's PNG representation")
        try countsEqual(source)
        transferred.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8,
            thenDragTo: ui.coordinate(CGPoint(x: 0.5, y: 0.8)))
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == source.itemCountOnPage + 1 }
        XCTAssertEqual(try ui.state().strokeCountOnPage, source.strokeCountOnPage)
        try ui.tapCommand("edit.undo")
        try countsEqual(source)
    }

    func testAssistantAttributionAppearsOnlyOnAssistantCreatedItems() throws {
        try selectedInk(); try objectMore()
        XCTAssertFalse(ui.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Made by Assistant'")).firstMatch.exists,
                       "User-drawn strokes must not claim Assistant provenance")
        outside()
        let before = try ui.state()
        let page = "page:\(try XCTUnwrap(before.document))/\(try XCTUnwrap(before.page))"
        let provider = try SelectionProviderFixture(page: page)
        defer { provider.stop() }
        try wait("The local Assistant provider fixture must start") { provider.port != nil }
        key(","); try tap("AI", scroll: true); try tap("Add provider", scroll: true)
        try tap("Preset"); try tap("Custom OpenAI-compatible")
        for (label, value) in [("Name", "Selection fixture"),
                               ("Base URL", "http://127.0.0.1:\(try XCTUnwrap(provider.port))/v1"),
                               ("Chat model", "selection-fixture")] {
            let field = try control(label, type: .textField, scroll: true)
            field.tap(); key("a"); field.typeText(value)
        }
        // Save through the editor's real keyboard shortcut; no settings or commands are injected.
        key("s")
        XCTAssertTrue(query("Provider saved.").firstMatch.waitForExistence(timeout: 10))
        try ui.dismissSheets()
        try menu("Ask AI")
        try tap("Edit")
        let composer = try control("Question or instruction")
        composer.tap(); composer.typeText("Add a text box that says Selection provenance on this page.")
        try tap("Send to assistant")
        _ = try ui.waitForState(timeout: 45) { $0.itemCountOnPage == before.itemCountOnPage + 1 }
        XCTAssertEqual(try ui.state().strokeCountOnPage, before.strokeCountOnPage)
        try ui.dismissSheets(); try clear()
        let created = ui.app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Selection provenance'")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 10)); created.tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        try objectMore()
        XCTAssertTrue(ui.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Made by Assistant'")).firstMatch.waitForExistence(timeout: 8))
    }
}

/// A deterministic external provider, reached only after the user taps Send in the Assistant UI.
/// The app's real provider parser, agent, gateway and transaction stamp the item's provenance.
/// This server has no access to app models; the selected page reference comes from the read-only probe.
@MainActor
private final class SelectionProviderFixture {
    private let listener: NWListener
    private let page: String
    private var connections: [NWConnection] = []
    var port: UInt16? { listener.port?.rawValue }

    init(page: String) throws {
        self.page = page
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, accumulated: Data())
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        connections.forEach { $0.cancel() }
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { connection.cancel(); return }
                var received = accumulated
                if let data { received.append(data) }
                guard received.count < 4_000_000 else { connection.cancel(); return }
                if let separator = received.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
                    let length = header.components(separatedBy: "\r\n").first {
                        $0.lowercased().hasPrefix("content-length:")
                    }.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                    let body = Data(received[separator.upperBound...])
                    if body.count >= length {
                        self.respond(connection, body: body)
                        return
                    }
                }
                if complete { connection.cancel() }
                else { self.receive(connection, accumulated: received) }
            }
        }
    }

    private func respond(_ connection: NWConnection, body: Data) {
        do {
            let request = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = request?["messages"] as? [[String: Any]] ?? []
            let hasResult = messages.contains { $0["role"] as? String == "tool" }
            let delta: [String: Any]
            if hasResult {
                delta = ["content": "Added Selection provenance."]
            } else {
                let arguments: [String: Any] = ["command": "text.createBox", "params": [
                    "page": page, "frame": [250, 400, 230, 48], "text": "Selection provenance"
                ]]
                let encoded = try JSONSerialization.data(withJSONObject: arguments)
                delta = ["tool_calls": [["index": 0, "id": "selection_provenance", "type": "function",
                    "function": ["name": "nib_run", "arguments": String(decoding: encoded, as: UTF8.self)]]]]
            }
            let events: [[String: Any]] = [
                ["choices": [["index": 0, "delta": delta]]],
                ["choices": [["index": 0, "delta": [:], "finish_reason": hasResult ? "stop" : "tool_calls"]]]
            ]
            let stream = try events.map {
                "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n"
            }.joined() + "data: [DONE]\n\n"
            let payload = Data(stream.utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        } catch { connection.cancel() }
    }
}
