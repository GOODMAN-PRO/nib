import XCTest
import UIKit
import UniformTypeIdentifiers
import ImageIO
import Network

/// Insert-area acceptance coverage. All mutations go through user input. The QA probe and the
/// documented app.nib.fragment produced by the real Copy button are read-only result oracles.
/// Owners: F026 text, F028 page text, F029 links, F031 shapes, F032 diagrams, F033 tape,
/// F034 images, F035 elements/GIFs, F036 sticky, F037 comments, F052 audio, F053 replay, F054 transcript.
/// Device-only: Pencil Scribble/pressure/tilt/hover/squeeze/double-tap, camera/scan capture,
/// Apple Intelligence Image Playground on supported hardware, audible output/VoiceOver.
@MainActor
final class InsertUITests: XCTestCase {
    private var ui: NibUI!
    private var provider: InsertProviderFixture?
    private var resetMicrophonePermission = false
    private let point = CGPoint(x: 0.46, y: 0.65)
    private let end = CGPoint(x: 0.60, y: 0.75)
    private typealias JSON = [String: Any]

    override func setUpWithError() throws {
        continueAfterFailure = false
        ui = NibUI()
        addUIInterruptionMonitor(withDescription: "System media permission") { alert in
            if let allow = alert.buttons.allElementsBoundByIndex.first(where: { $0.label.hasPrefix("Allow") || $0.label == "OK" }) {
                allow.tap(); return true
            }
            return false
        }
        try ui.launchFixture()
        try allowSystemPermissionIfPresented(timeout: 2)
        // XCTest invokes interruption monitors only on a subsequent interaction. A tap in the
        // library's blank footer also dismisses a late permission sheet left by a terminated test.
        ui.app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.95)).tap()
        try ui.openDocument("Physics — Motion")
        _ = try ui.waitForState { $0.itemCountOnPage == 4 && $0.strokeCountOnPage == 1 }
    }

    override func tearDownWithError() throws {
        guard let ui else { return }
        let attachments = [XCTAttachment(screenshot: XCUIScreen.main.screenshot()),
                           XCTAttachment(string: String(describing: ui.probe.value)),
                           XCTAttachment(string: ui.app.debugDescription)]
        for (index, attachment) in attachments.enumerated() {
            attachment.name = "Insert-\(name)-\(["screen", "nib.qa.state", "accessibility"][index])"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        provider?.stop(); provider = nil
        ui.app.terminate()
        if resetMicrophonePermission { ui.app.resetAuthorizationStatus(for: .microphone) }
        self.ui = nil
    }

    private func permissionAlert(timeout: TimeInterval) -> XCUIElement? {
        // Depending on the simulator OS, the permission sheet is exposed under the requesting app
        // or SpringBoard. Permission requests can arrive after the action's first idle transition.
        let sources = [ui.app, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        var found: XCUIElement?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            found = sources.flatMap { $0.alerts.allElementsBoundByIndex }.first {
                $0.buttons.allElementsBoundByIndex.contains { $0.label.hasPrefix("Allow") || $0.label == "OK" }
            }
            if found == nil {
                // Some system paste sheets expose their buttons without an XCUIElementTypeAlert ancestor.
                found = sources.first {
                    $0.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch.exists
                }
            }
            return found != nil
        }, object: nil)
        _ = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return found
    }
    private func allowSystemPermissionIfPresented(timeout: TimeInterval = 10) throws {
        if let alert = permissionAlert(timeout: timeout) {
            let allow = alert.buttons.allElementsBoundByIndex.first { $0.label.hasPrefix("Allow") || $0.label == "OK" }
            try XCTUnwrap(allow, "Media permission prompt must offer an allow action").tap()
        }
    }
    private func query(_ name: String, _ type: XCUIElement.ElementType = .any) -> XCUIElementQuery {
        ui.app.descendants(matching: type).matching(NSPredicate(format: "identifier == %@ OR label == %@", name, name))
    }
    private func wait(_ message: String, timeout: TimeInterval = 8, _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw NibUI.Failure.message(message + "\nprobe: " + String(describing: ui.probe.value))
        }
    }
    private func control(_ name: String, _ type: XCUIElement.ElementType = .any, scroll: Bool = false) throws -> XCUIElement {
        let q = query(name, type)
        for attempt in 0..<(scroll ? 7 : 2) {
            let candidates = q.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
            if let found = candidates.first(where: { [.button, .textField, .textView, .switch, .slider].contains($0.elementType) }) ?? candidates.first { return found }
            if attempt == 0 { _ = q.firstMatch.waitForExistence(timeout: 3) }
            if scroll, let panel = (ui.app.scrollViews.allElementsBoundByIndex + ui.app.collectionViews.allElementsBoundByIndex + ui.app.tables.allElementsBoundByIndex).first(where: {
                $0.identifier != "nib.canvas" && $0.isHittable && $0.frame.height > 150 && $0.frame.width > 200
            }) {
                panel.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.80)).press(forDuration: 0.01,
                    thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25)))
            }
        }
        throw NibUI.Failure.message("Missing actionable insert control: \(name)\n\(ui.app.debugDescription)")
    }
    private func tap(_ name: String, scroll: Bool = false) throws { try control(name, scroll: scroll).tap() }
    private func visible(_ name: String) -> Bool { query(name).allElementsBoundByIndex.contains { $0.isHittable } }
    private func key(_ value: String, _ modifiers: XCUIElement.KeyModifierFlags = .command) { ui.app.typeKey(value, modifierFlags: modifiers) }
    private func outside() { ui.coordinate(CGPoint(x: 0.93, y: 0.83)).tap() }
    private func finish() throws {
        if visible("Finish Editing") { try tap("Finish Editing") }
        else if visible("Done typing") { try tap("Done typing") }
        else { key(XCUIKeyboardKey.escape.rawValue, []); outside() }
        try wait("Text input must finish") { !self.ui.app.textViews.allElementsBoundByIndex.contains { $0.isHittable } }
    }
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap(); key("a"); field.typeText(text)
    }
    private func toggle(_ name: String, to value: Bool) throws {
        let element = try control(name, .switch, scroll: true)
        if (element.value as? String == "1") != value { element.tap() }
        try wait("\(name) must change to \(value)") { (element.value as? String == "1") == value }
    }
    private func more() throws {
        let copy = try control("cmd.clipboard.copy")
        let buttons = query("More", .button).allElementsBoundByIndex.filter {
            $0.isHittable && $0.identifier != "menu.more" && $0.identifier != "tool.more" && abs($0.frame.midY - copy.frame.midY) < 45
        }
        try XCTUnwrap(buttons.min { abs($0.frame.midX - copy.frame.midX) < abs($1.frame.midX - copy.frame.midX) }, "Object menu must expose More").tap()
    }
    private func menu(_ path: String...) throws { try more(); for name in path { try tap(name) } }
    private func pageMenu() throws { try ui.selectTool("lasso"); ui.coordinate(point).press(forDuration: 1) }
    private func documentMenu(_ name: String) throws { try tap("menu.more"); try tap(name) }
    private func goToSecondPage() throws {
        let original = try ui.state().page
        key("g", [.command, .option])
        replace(try control("Page number or title"), with: "2"); try tap("Go")
        _ = try ui.waitForState(timeout: 10) { $0.page != original && !$0.openPanels.contains("pages.goToPage") }
    }
    private func panel(_ name: String) throws {
        if query(name, .button).allElementsBoundByIndex.contains(where: { $0.isHittable }) { try tap(name); return }
        if !visible("Panel Options") {
            if visible("cmd.panel.close") { try tap("cmd.panel.close") }
            try ui.tapCommand("sidebar.toggle")
        }
        try tap("Panel Options"); try tap(name)
    }
    private func selectedBounds() throws -> CGRect {
        let q = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Selection' AND (value == '1 item' OR value ENDSWITH ' items')"))
        try wait("Selected content must expose bounds") { q.allElementsBoundByIndex.contains { $0.frame.width > 0 } }
        return try XCTUnwrap(q.allElementsBoundByIndex.first { $0.frame.width > 0 }).frame
    }
    private func selectAt(_ p: CGPoint? = nil) throws {
        try ui.selectTool("lasso")
        // Tapping a selected text/sticky starts its editor; clear selection on blank paper first.
        if try ui.state().selectionCount > 0 {
            ui.coordinate(CGPoint(x: 0.36, y: 0.84)).tap()
            _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 0 }
        }
        ui.coordinate(p ?? point).tap()
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
    }
    private func all() throws {
        try ui.selectTool("lasso"); key("a")
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == $0.itemCountOnPage }
    }
    private func fragment() throws -> JSON {
        let data = try ui.copyFragment()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSON)
    }
    private func items() throws -> [JSON] { try XCTUnwrap(fragment()["items"] as? [JSON]) }
    private func item(_ kind: String) throws -> JSON {
        try XCTUnwrap(items().last(where: { $0["kind"] as? String == kind })?[kind] as? JSON, "Copied selection must contain \(kind)")
    }
    private func snapshot(_ kind: String) throws -> JSON { try all(); return try item(kind) }
    private func json(_ value: Any?) -> String {
        guard let value else { return "null" }
        return (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), encoding: .utf8)) ?? "invalid JSON"
    }
    private func paragraphs(_ object: JSON) throws -> [JSON] {
        try XCTUnwrap((object["text"] as? JSON)?["paragraphs"] as? [JSON])
    }
    private func plain(_ object: JSON) throws -> String {
        try paragraphs(object).map { (($0["runs"] as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined() }.joined(separator: "\n")
    }
    private func canvasPixels() throws -> [UInt8] {
        // Sample only the insertion region, excluding the keyboard, recording timer and floating chrome.
        let f = ui.canvas.frame
        let rect = CGRect(x: f.minX + f.width * 0.47, y: f.minY + f.height * 0.66,
                          width: f.width * 0.11, height: f.height * 0.08)
        let screenshot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: ui.app.frame.size, format: format).image { _ in
            screenshot.draw(in: CGRect(origin: .zero, size: ui.app.frame.size))
        }
        let crop = try XCTUnwrap(normalized.cgImage?.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: 80 * 50 * 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 80, height: 50,
                bitsPerComponent: 8, bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 80, height: 50))
        }
        return bytes
    }
    private func changedPixels(_ first: [UInt8], _ second: [UInt8]) -> Int {
        guard first.count == second.count else { return Int.max }
        return stride(from: 0, to: first.count, by: 4).filter { i in
            (0..<3).contains { abs(Int(first[i + $0]) - Int(second[i + $0])) > 30 }
        }.count
    }
    private func counts(_ count: Int, strokes: Int? = nil) throws {
        _ = try ui.waitForState(timeout: 10) { $0.itemCountOnPage == count && (strokes == nil || $0.strokeCountOnPage == strokes) }
    }
    private func undo(_ before: Int, redo after: Int) throws {
        try ui.tapCommand("edit.undo"); try counts(before)
        XCTAssertTrue(try ui.state().redoAvailable)
        try ui.tapCommand("edit.redo"); try counts(after)
    }
    private func beginText(_ text: String) throws {
        try ui.selectTool("text"); ui.coordinate(point).tap()
        let editor = try control("Text box", .textView)
        editor.typeText(text)
        try wait("Typed text must reach the editable text box") { (editor.value as? String)?.contains(text) == true }
    }
    private func shape(_ title: String = "Rectangle") throws {
        let before = try ui.state().itemCountOnPage
        try ui.selectTool("shape"); try tap("tool.shape"); try tap(title, scroll: true); outside()
        try ui.drawStroke([point, end])
        try counts(before + 1)
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
    }
    private func imageData(_ alternate: Bool = false) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).pngData { c in
            (alternate ? UIColor.green : UIColor.red).setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        }
    }
    private func gifData() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for alternate in [false, true] {
            let cg = try XCTUnwrap(UIImage(data: imageData(alternate))?.cgImage)
            CGImageDestinationAddImage(destination, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func image(_ gif: Bool = false) throws {
        let before = try ui.state().itemCountOnPage
        UIPasteboard.general.setData(try gif ? gifData() : imageData(), forPasteboardType: gif ? UTType.gif.identifier : UTType.png.identifier)
        try ui.selectTool("image"); ui.coordinate(point).tap(); try tap("Paste")
        try allowSystemPermissionIfPresented(timeout: 3)
        if try ui.state().itemCountOnPage == before { outside() }
        try counts(before + 1)
        try selectAt()
    }

    // MARK: text, text.setText, text.format, text.setParagraph, text.autoLists

    func testTextInsertCommitEditAndUndo() throws {
        try beginText("Velocity = distance / time"); try finish(); try counts(5, strokes: 1)
        try undo(4, redo: 5)
        try selectAt(); ui.doubleTap(at: point)
        replace(try control("Text box", .textView), with: "Acceleration = change in velocity")
        try finish()
        XCTAssertEqual(try plain(snapshot("text")), "Acceleration = change in velocity")
        try ui.tapCommand("edit.undo")
        XCTAssertEqual(try plain(snapshot("text")), "Velocity = distance / time")
    }
    func testTextSelectedRangeFontEmphasisColourAndHighlight() throws {
        try beginText("plain styled")
        key(XCUIKeyboardKey.leftArrow.rawValue, [.alternate, .shift])
        for title in ["Bold", "Italic", "Underline", "Strikethrough"] { try tap(title) }
        try tap("Font"); try tap("Georgia")
        let previousSize = try control("Larger Text").value as? String
        try tap("Larger Text")
        XCTAssertNotEqual(try control("Larger Text").value as? String, previousSize)
        try tap("Text Colour"); try tap("Crimson")
        try tap("Highlight"); try tap("Lemon")
        try finish()
        let box = try snapshot("text"), runs = try XCTUnwrap(paragraphs(box).first?["runs"] as? [JSON])
        XCTAssertEqual(try plain(box), "plain styled")
        let plainRun = try XCTUnwrap(runs.first(where: { ($0["text"] as? String)?.contains("plain") == true }))
        let styled = try XCTUnwrap(runs.first(where: { ($0["text"] as? String)?.contains("styled") == true })?["attrs"] as? JSON)
        for flag in ["bold", "italic", "underline", "strikethrough"] {
            XCTAssertEqual(styled[flag] as? Bool, true, "Selected range must apply \(flag)")
            XCTAssertNotEqual((plainRun["attrs"] as? JSON)?[flag] as? Bool, true, "Unselected range must retain \(flag)")
        }
        XCTAssertEqual(styled["font"] as? String, "Georgia")
        let untouched = try XCTUnwrap(plainRun["attrs"] as? JSON)
        XCTAssertNotEqual(untouched["font"] as? String, "Georgia")
        XCTAssertNotEqual(json(untouched["color"]), json(styled["color"]))
        XCTAssertNil(untouched["highlight"])
        XCTAssertNotNil(styled["highlight"]); XCTAssertNotNil(styled["color"])
    }
    func testParagraphAlignmentListsIndentAndSpacing() throws {
        try beginText("first\nsecond"); key("a")
        try tap("Alignment"); try tap("Centre")
        try tap("Line Spacing"); try tap("1.5")
        for kind in ["Bullets", "Numbered (1.)", "Checklist", "Numbered (1))"] {
            try tap("List"); try tap(kind)
            XCTAssertEqual(try control("List").value as? String, kind)
        }
        try tap("Increase Indent"); try finish()
        let ps = try paragraphs(snapshot("text"))
        XCTAssertEqual(ps.count, 2)
        for p in ps {
            XCTAssertEqual(p["align"] as? String, "center")
            XCTAssertEqual(p["list"] as? String, "numberParen")
            XCTAssertEqual(p["indent"] as? Int, 1)
            XCTAssertGreaterThan((p["lineSpacing"] as? Double) ?? 0, 0)
        }
    }
    func testAutomaticListsContinueNestOutdentAndExit() throws {
        try beginText("- first\n")
        key(XCUIKeyboardKey.tab.rawValue, [])
        try control("Text box", .textView).typeText("nested\n")
        key(XCUIKeyboardKey.tab.rawValue, .shift)
        try control("Text box", .textView).typeText("last\n\nplain")
        try finish()
        let ps = try paragraphs(snapshot("text"))
        XCTAssertEqual(ps.first?["list"] as? String, "bullet")
        XCTAssertTrue(ps.contains { ($0["indent"] as? Int ?? 0) > 0 }, "Tab nests a list paragraph")
        XCTAssertEqual(ps.last?["list"] as? String, "plain", "Return on an empty item exits the list")
    }
    func testTextBoxStyleAndAutosizePersist() throws {
        try beginText("Styled box"); try tap("More Formatting")
        try tap("Ivory", scroll: true)
        try tap("Thick", scroll: true); try tap("Rounded", scroll: true); try tap("Loose", scroll: true)
        try toggle("Shadow", to: true); try toggle("Fit Height to Text", to: false)
        outside(); try finish()
        let box = try snapshot("text"), style = try XCTUnwrap(box["style"] as? JSON)
        XCTAssertEqual(style["shadow"] as? Bool, true)
        XCTAssertEqual(style["autoGrow"] as? Bool, false)
        XCTAssertNotNil(style["background"])
        XCTAssertGreaterThan((style["padding"] as? Double) ?? 0, 8)
        XCTAssertGreaterThan((style["cornerRadius"] as? Double) ?? 0, 0)
        XCTAssertGreaterThan((style["borderWidth"] as? Double) ?? 0, 0)
        let originalHeight = try XCTUnwrap((box["frame"] as? JSON)?["h"] as? Double)
        try selectAt(); ui.doubleTap(at: point)
        replace(try control("Text box", .textView), with: (1...10).map { "Line \($0)" }.joined(separator: "\n"))
        try finish()
        XCTAssertEqual(try XCTUnwrap((snapshot("text")["frame"] as? JSON)?["h"] as? Double), originalHeight, accuracy: 0.1,
                       "Fixed-height text must clip rather than silently resize its frame")
        try selectAt(); ui.doubleTap(at: point); try tap("More Formatting")
        try toggle("Fit Height to Text", to: true); outside(); try finish()
        XCTAssertGreaterThan(try XCTUnwrap((snapshot("text")["frame"] as? JSON)?["h"] as? Double), originalHeight,
                             "Auto-size must grow the frame to fit retained text")
    }
    func testNamedStyleAndDefaultAffectNewText() throws {
        try beginText("First"); key("a"); try tap("Larger Text"); try tap("More Formatting")
        try tap("Save Style…"); replace(try control("Name", .textField), with: "Lab Caption"); try tap("Save")
        try tap("Lab Caption"); try tap("Set as Default for New Text"); outside(); try finish()
        let first = try snapshot("text")
        outside(); try ui.selectTool("text"); ui.coordinate(CGPoint(x: 0.58, y: 0.82)).tap()
        try control("Text box", .textView).typeText("Second"); try finish()
        let second = try snapshot("text")
        XCTAssertEqual(json(first["style"]), json(second["style"]))
        let firstRuns = try XCTUnwrap(paragraphs(first).first?["runs"] as? [JSON])
        let secondRuns = try XCTUnwrap(paragraphs(second).first?["runs"] as? [JSON])
        let firstSize = try XCTUnwrap((firstRuns.first?["attrs"] as? JSON)?["size"] as? Double)
        XCTAssertEqual((secondRuns.first?["attrs"] as? JSON)?["size"] as? Double, firstSize,
                       "The saved default must carry the selected typography into newly typed text")
        XCTAssertEqual(try plain(second), "Second")
    }
    func testTextStylePresetsApplyTypography() throws {
        try beginText("Preset")
        var sizes = Set<String>()
        for title in ["Title", "Heading", "Body", "Caption"] {
            key("a"); try tap("Text Style"); try tap(title)
            sizes.insert(try control("Larger Text").value as? String ?? "missing")
        }
        XCTAssertEqual(sizes.count, 4, "Each preset must apply distinct typography")
        try finish(); XCTAssertEqual(try plain(snapshot("text")), "Preset")
    }
    func testTextPinRetainsToolAndUnpinReturnsPreviousTool() throws {
        try ui.selectTool("pen"); try ui.selectTool("text"); try tap("tool.text")
        try toggle("Keep Text Tool Selected", to: true); outside()
        try beginText("Pinned"); try finish()
        _ = try ui.waitForState(timeout: 8) { $0.tool == "text" }
        try tap("tool.text"); try toggle("Keep Text Tool Selected", to: false); outside()
        ui.coordinate(CGPoint(x: 0.58, y: 0.80)).tap()
        try control("Text box", .textView).typeText("Unpinned"); try finish()
        _ = try ui.waitForState(timeout: 8) { $0.tool != "text" }
        try counts(6, strokes: 1)
    }
    func testNativeTextInputRetainsUnicodeWithoutCanvasInk() throws {
        try beginText("Force 🧲 → 加速度"); try finish()
        XCTAssertEqual(try plain(snapshot("text")), "Force 🧲 → 加速度")
        try counts(5, strokes: 1)
    }
    func testNativeInlineStickerPasteRetainsAssetWithoutCanvasInk() throws {
        try beginText("Sticker: ")
        // Native attributed input exercises UITextView's inline image-glyph path, also used by
        // system stickers. Scribble and the hardware Pencil input path remain device-only.
        let sticker = NSTextAttachment(image: try XCTUnwrap(UIImage(data: imageData())))
        let rich = NSAttributedString(attachment: sticker)
        let data = try rich.data(from: NSRange(location: 0, length: rich.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        UIPasteboard.general.setData(data, forPasteboardType: UTType.flatRTFD.identifier)
        key("v"); try finish(); try counts(5, strokes: 1)
        let box = try snapshot("text")
        XCTAssertTrue(json(try paragraphs(box)).contains("attachment"), "Native inline sticker must persist as an attachment")
        XCTAssertFalse(try XCTUnwrap(fragment()["assets"] as? JSON).isEmpty, "Copy must carry the retained sticker bytes")
        try ui.tapCommand("window.showLibrary"); try ui.openDocument("Physics — Motion")
        XCTAssertTrue(json(try paragraphs(snapshot("text"))).contains("attachment"))
        try counts(5, strokes: 1)
    }
    func testPageTypingUsesMarginsAndReusesItsBoxWithPresets() throws {
        try pageMenu(); try tap("Start Typing")
        let editor = try control("Page text", .textView)
        editor.typeText("Full page report")
        try tap("Text Style"); try tap("Heading")
        XCTAssertEqual(try control("Text Style").value as? String, "Heading")
        try finish(); try counts(5)
        let original = try snapshot("text"), frame = try XCTUnwrap(original["frame"] as? JSON)
        XCTAssertGreaterThan((frame["x"] as? Double) ?? 0, 0)
        XCTAssertGreaterThan((frame["y"] as? Double) ?? 0, 0)
        XCTAssertLessThan((frame["w"] as? Double) ?? 595, 595)
        outside(); key("t", [.command, .alternate])
        let reopened = try control("Page text", .textView)
        XCTAssertTrue((reopened.value as? String)?.contains("Full page report") == true)
        try tap("Text Style"); try tap("Caption"); try finish(); try counts(5)
        XCTAssertEqual(json(try snapshot("text")["frame"]), json(original["frame"]))
    }

    // MARK: shapes, connectors and diagrams

    private func checkShape(_ title: String, kind: String) throws {
        try shape(title)
        let inserted = try item("shape")
        XCTAssertEqual(inserted["shape"] as? String, kind)
        let frame = try XCTUnwrap(inserted["frame"] as? JSON)
        XCTAssertGreaterThan((frame["w"] as? Double) ?? 0, 0)
        XCTAssertGreaterThan((frame["h"] as? Double) ?? 0, 0)
        try counts(5, strokes: 1); try undo(4, redo: 5)
    }
    func testShapeLine() throws { try checkShape("Line", kind: "line") }
    func testShapeArrow() throws { try checkShape("Arrow", kind: "arrow") }
    func testShapeRectangle() throws { try checkShape("Rectangle", kind: "rectangle") }
    func testShapeRoundedRectangle() throws { try checkShape("Rounded Rectangle", kind: "roundedRectangle") }
    func testShapeEllipse() throws { try checkShape("Ellipse", kind: "ellipse") }
    func testShapeDiamond() throws { try checkShape("Diamond", kind: "diamond") }
    func testShapeTriangle() throws { try checkShape("Triangle", kind: "triangle") }
    func testShapeStar() throws { try checkShape("Star", kind: "polygon") }
    func testShapePolygon() throws { try checkShape("Polygon", kind: "polygon") }
    func testShapeCurve() throws { try checkShape("Curve", kind: "curve") }
    func testShapeChangeKindKeepsFrameAndStylePersists() throws {
        try shape(); let before = try item("shape")
        try menu("Style"); try tap("Ellipse"); try tap("Dashed", scroll: true); outside()
        let after = try item("shape")
        XCTAssertEqual(after["shape"] as? String, "ellipse")
        XCTAssertEqual(json(after["frame"]), json(before["frame"]))
        XCTAssertEqual((after["style"] as? JSON)?["pattern"] as? String, "dashed")
        try ui.tapCommand("edit.undo")
        XCTAssertNotEqual((try item("shape")["style"] as? JSON)?["pattern"] as? String, "dashed")
    }
    func testShapeCornerRoundingAndArrowheadsPersist() throws {
        try shape(); try menu("Style"); try tap("Rounded", scroll: true); outside()
        XCTAssertGreaterThan((try item("shape")["style"] as? JSON)?["cornerRadius"] as? Double ?? 0, 0)
        try ui.tapCommand("edit.undo")
        XCTAssertEqual((try item("shape")["style"] as? JSON)?["cornerRadius"] as? Double, 0)
        try ui.tapCommand("item.delete"); try counts(4)
        try shape("Line"); let original = try item("shape")
        try menu("Style"); try toggle("At start", to: true); try toggle("At end", to: true); outside()
        let changed = try item("shape"), style = try XCTUnwrap(changed["style"] as? JSON)
        XCTAssertEqual(style["arrowStart"] as? Bool, true)
        XCTAssertTrue(changed["shape"] as? String == "arrow" || style["arrowEnd"] as? Bool == true)
        XCTAssertEqual(json(changed["frame"]), json(original["frame"]))
    }
    func testShapePointsGestureChangesGeometryAndUndoRestores() throws {
        try shape("Triangle"); let before = try item("shape")
        let handle = try control("Point 1 of 3")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: handle.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 65, dy: 40)))
        XCTAssertNotEqual(json(try item("shape")["points"]), json(before["points"]))
        try ui.tapCommand("edit.undo")
        XCTAssertEqual(json(try item("shape")["points"]), json(before["points"]))
    }
    func testShapeAttachedLabelDoubleTapPersists() throws {
        try shape(); ui.doubleTap(at: CGPoint(x: 0.53, y: 0.70))
        try control("Text in shape", .textView).typeText("Force vector")
        try finish()
        XCTAssertEqual(try plain(snapshot("shape")), "Force vector")
        try counts(5, strokes: 1)
    }
    func testQuickDiagramEachSideAddsAnchoredObjectsAndGroupedUndo() throws {
        try shape(); let origin = try item("shape")
        for side in ["Above", "On the Right", "Below", "On the Left"] {
            try menu("Add Connected Shape", side); try counts(7)
            let added = try item("shape")
            try all(); let copied = try items()
            XCTAssertEqual(copied.filter { $0["kind"] as? String == "connector" }.count, 1)
            let connector = try XCTUnwrap(copied.first(where: { $0["kind"] as? String == "connector" })?["connector"] as? JSON)
            XCTAssertNotNil((connector["from"] as? JSON)?["item"])
            XCTAssertNotNil((connector["to"] as? JSON)?["item"])
            let shapes = [added]
            let f = try XCTUnwrap(origin["frame"] as? JSON), x = f["x"] as? Double ?? 0, y = f["y"] as? Double ?? 0
            XCTAssertTrue(shapes.contains { shape in
                guard let frame = shape["frame"] as? JSON else { return false }
                switch side {
                case "Above": return (frame["y"] as? Double ?? y) < y
                case "Below": return (frame["y"] as? Double ?? y) > y
                case "On the Left": return (frame["x"] as? Double ?? x) < x
                default: return (frame["x"] as? Double ?? x) > x
                }
            })
            try ui.tapCommand("edit.undo"); try counts(5); try selectAt(CGPoint(x: 0.53, y: 0.70))
        }
    }
    func testConnectSelectedShapesRetainsAnchorsWhenShapeMoves() throws {
        try shape()
        try ui.selectTool("shape")
        try ui.drawStroke([CGPoint(x: 0.65, y: 0.65), CGPoint(x: 0.72, y: 0.75)])
        try counts(6)
        try ui.selectTool("lasso")
        try ui.drawStroke([CGPoint(x: 0.43, y: 0.62), CGPoint(x: 0.75, y: 0.62),
                           CGPoint(x: 0.75, y: 0.78), CGPoint(x: 0.43, y: 0.78), CGPoint(x: 0.43, y: 0.62)])
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 2 }
        try menu("Connect"); try counts(7)
        try all(); let connection = try item("connector")
        let from = try XCTUnwrap((connection["from"] as? JSON)?["item"])
        let to = try XCTUnwrap((connection["to"] as? JSON)?["item"])
        XCTAssertNotEqual(json(from), json(to), "Connect must anchor two distinct selected shapes")
        try selectAt(CGPoint(x: 0.685, y: 0.70))
        let original = try selectedBounds()
        let start = ui.app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: original.midX, dy: original.midY))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -15, dy: 60)))
        let moved = try selectedBounds()
        XCTAssertGreaterThan(moved.midY, original.midY + 30)
        try all(); let connectedAfterMove = try item("connector")
        XCTAssertEqual(json((connectedAfterMove["from"] as? JSON)?["item"]), json(from))
        XCTAssertEqual(json((connectedAfterMove["to"] as? JSON)?["item"]), json(to))
        try ui.tapCommand("edit.undo"); try selectAt(CGPoint(x: 0.685, y: 0.70))
        XCTAssertEqual(try selectedBounds().midY, original.midY, accuracy: 2)
    }
    func testConnectorDragAnchorRoutesBendsAndUndo() throws {
        try shape()
        let dot = try control("Add connected shape on the right")
        dot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: ui.coordinate(CGPoint(x: 0.70, y: 0.80)))
        try counts(6)
        try all(); let connector = try item("connector")
        XCTAssertNotNil((connector["from"] as? JSON)?["item"])
        outside(); try selectAt(CGPoint(x: 0.67, y: 0.78))
        for route in ["Elbow", "Curved", "Straight"] {
            try menu("Connector Style", route)
            XCTAssertEqual(try item("connector")["route"] as? String, route.lowercased())
        }
        let handle = try control("Connector end")
        let previous = try item("connector")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: ui.coordinate(CGPoint(x: 0.68, y: 0.85)))
        XCTAssertNotEqual(json(try item("connector")["to"]), json(previous["to"]))
        try ui.tapCommand("edit.undo"); XCTAssertEqual(json(try item("connector")["to"]), json(previous["to"]))
        let startFrame = try control("Connector start").frame
        let endFrame = try control("Connector end").frame
        let midpoint = ui.app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: (startFrame.midX + endFrame.midX) / 2, dy: (startFrame.midY + endFrame.midY) / 2))
        midpoint.press(forDuration: 0.1, thenDragTo: midpoint.withOffset(CGVector(dx: -45, dy: 35)))
        let bends = try XCTUnwrap(try item("connector")["bends"] as? [JSON])
        XCTAssertEqual(bends.count, 1, "Dragging the midpoint must insert a control bend")
        let bend = try control("Bend 1").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bend.press(forDuration: 0.1, thenDragTo: bend.withOffset(CGVector(dx: 20, dy: 20)))
        XCTAssertNotEqual(json(try item("connector")["bends"]), json(bends))
        try menu("Connector Style", "Remove Bends")
        XCTAssertEqual((try item("connector")["bends"] as? [JSON])?.count, 0)
        try ui.tapCommand("edit.undo")
        XCTAssertEqual((try item("connector")["bends"] as? [JSON])?.count, 1)
    }
    private func configureProvider() throws {
        let state = try ui.state()
        provider = try InsertProviderFixture(page: "page:\(try XCTUnwrap(state.document))/\(try XCTUnwrap(state.page))")
        try wait("External fixture endpoint must start") { self.provider?.port != nil }
        key(","); try tap("AI", scroll: true); try tap("Add provider", scroll: true)
        try tap("Preset"); try tap("Custom OpenAI-compatible")
        for (label, value) in [("Name", "Insert fixture"),
                               ("Base URL", "http://127.0.0.1:\(try XCTUnwrap(provider?.port))/v1"),
                               ("Chat model", "insert-fixture"), ("Transcription model", "insert-transcript")] {
            replace(try control(label, .textField, scroll: true), with: value)
        }
        key("s"); XCTAssertTrue(query("Provider saved.").firstMatch.waitForExistence(timeout: 10))
        try ui.dismissSheets()
    }
    func testNativeDiagramActionCreatesEditableNodesAndGroupedUndo() throws {
        try configureProvider(); try beginText("Make a flow diagram"); try finish(); try selectAt()
        let before = try ui.state().itemCountOnPage
        try menu("Ask AI"); try tap("Edit")
        let composer = try control("Question or instruction")
        composer.tap(); composer.typeText("Insert an editable flow diagram with Motion and Force, one connecting edge, classic style.")
        try tap("Send to assistant")
        try counts(before + 3)
        try ui.dismissSheets(); try all(); let content = try items()
        XCTAssertEqual(content.filter { $0["kind"] as? String == "connector" }.count, 1)
        XCTAssertEqual(content.filter { $0["kind"] as? String == "shape" }.count, 3)
        try ui.tapCommand("edit.undo"); try counts(before)
    }

    // MARK: image, image.pick/insert/crop/flip/replace/saveToPhotos

    func testImageToolPhotosAndFilesCancelInsertNothing() throws {
        for source in ["Photos", "Files"] {
            try ui.selectTool("image"); ui.coordinate(point).tap(); try tap(source)
            try tap("Cancel")
            try counts(4, strokes: 1)
            XCTAssertFalse(try ui.state().undoAvailable)
        }
    }
    func testImagePasteAspectAssetSurvivesReopening() throws {
        try image(); let inserted = try item("image"), frame = try XCTUnwrap(inserted["frame"] as? JSON)
        XCTAssertEqual(try XCTUnwrap(frame["w"] as? Double) / XCTUnwrap(frame["h"] as? Double), 160.0 / 90, accuracy: 0.01)
        let assets = try XCTUnwrap(fragment()["assets"] as? JSON)
        XCTAssertFalse(assets.isEmpty)
        try ui.tapCommand("window.showLibrary"); try ui.openDocument("Physics — Motion"); try counts(5)
        try selectAt(); XCTAssertEqual(json(try item("image")["asset"]), json(inserted["asset"]))
        XCTAssertEqual(json(try fragment()["assets"]), json(assets))
    }
    func testAnimatedGIFPasteRetainsAnimationAndAsset() throws {
        try image(true)
        XCTAssertEqual(try item("image")["animated"] as? Bool, true)
        let assets = try XCTUnwrap(fragment()["assets"] as? [String: String])
        let bytes = try XCTUnwrap(assets.values.first.flatMap { Data(base64Encoded: $0) })
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        try undo(4, redo: 5)
    }
    func testImageRectangleCropCancelCommitUndo() throws {
        try image(); let original = try item("image")
        try ui.tapCommand("image.crop"); try tap("Square"); try tap("Cancel")
        XCTAssertEqual(json(try item("image")), json(original))
        try ui.tapCommand("image.crop"); try tap("Square"); try tap("Crop")
        let cropped = try item("image")
        XCTAssertNotEqual(json(cropped["crop"]), json(original["crop"]))
        try ui.tapCommand("edit.undo"); XCTAssertEqual(json(try item("image")["crop"]), json(original["crop"]))
    }
    func testImageFreehandCropUsesDrawnPath() throws {
        try image(); try ui.tapCommand("image.crop"); try tap("Freehand")
        let area = try control("Freehand crop area")
        let path = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.25), CGPoint(x: 0.75, y: 0.8), CGPoint(x: 0.2, y: 0.2)]
        let points = path.map { NSValue(cgPoint: area.coordinate(withNormalizedOffset: CGVector(dx: $0.x, dy: $0.y)).screenPoint) }
        let done = XCTestExpectation(description: "Freehand crop path")
        var error: Error?
        NibTouchPaths.perform([points], duration: 0.8) { failure in error = failure; done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        if let error { throw error }
        try tap("Crop")
        let mask = try XCTUnwrap(try item("image")["mask"] as? [Any])
        XCTAssertGreaterThan(mask.count, 2)
        try ui.tapCommand("edit.undo"); XCTAssertNil(try item("image")["mask"])
    }
    func testImageMirrorsBothAxesWithoutChangingFrame() throws {
        try image(); let original = try item("image")
        for (title, field) in [("Flip Horizontally", "flipX"), ("Flip Vertically", "flipY")] {
            try menu("Flip", title)
            let flipped = try item("image")
            XCTAssertEqual(flipped[field] as? Bool, true)
            XCTAssertEqual(json(flipped["frame"]), json(original["frame"]))
            try ui.tapCommand("edit.undo"); XCTAssertNotEqual(try item("image")[field] as? Bool, true)
        }
    }
    func testImageReplaceCancelPreservesAssetAndFrame() throws {
        try image(); let before = try item("image")
        try menu("Replace Image"); try tap("Cancel")
        XCTAssertEqual(json(try item("image")), json(before)); try counts(5)
    }
    func testImageReplaceFromPhotosKeepsFrameAndUndoRestoresAsset() throws {
        // Save a blue/red source to the real photo library, then replace a different green image.
        try image(); try menu("Save to Photos"); try allowSystemPermissionIfPresented(); try ui.tapCommand("item.delete"); try counts(4)
        UIPasteboard.general.setData(imageData(true), forPasteboardType: UTType.png.identifier)
        try ui.selectTool("image"); ui.coordinate(point).tap(); try tap("Paste")
        try allowSystemPermissionIfPresented(timeout: 3)
        if try ui.state().itemCountOnPage == 4 { outside() }
        try counts(5); try selectAt()
        let before = try item("image")
        try menu("Replace Image")
        let photo = ui.app.images.matching(NSPredicate(format: "label CONTAINS[c] 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.tap()
        if visible("Add") { try tap("Add") }
        try counts(5)
        let after = try item("image")
        XCTAssertNotEqual(json(after["asset"]), json(before["asset"]), "Replacement must actually change image bytes")
        XCTAssertEqual(json(after["frame"]), json(before["frame"]), "Replacement retains the destination frame")
        try ui.tapCommand("edit.undo")
        XCTAssertEqual(json(try item("image")["asset"]), json(before["asset"]))
    }
    func testImageSaveToPhotosProducesPickerVisibleAsset() throws {
        try image(); try menu("Save to Photos")
        try allowSystemPermissionIfPresented()
        outside(); try ui.selectTool("image"); ui.coordinate(CGPoint(x: 0.63, y: 0.8)).tap(); try tap("Photos")
        let photo = ui.app.images.matching(NSPredicate(format: "label CONTAINS[c] 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "Saved image must be available in Photos, or a useful permission error must be shown")
        try tap("Cancel"); try counts(5)
    }

    // MARK: collections, elements and GIF controls

    private func elements() throws { try ui.selectTool("elements"); try tap("tool.elements") }
    private func collection(_ name: String) throws {
        try tap("New Collection"); replace(try control("Collection name", .textField), with: name); try tap("Create")
        XCTAssertTrue(query(name).firstMatch.waitForExistence(timeout: 8))
    }
    func testElementsSearchMatchingEmptyAndInsertThumbnail() throws {
        try elements()
        let search = try control("Search elements", .textField)
        replace(search, with: "unmatchablezzzz")
        XCTAssertTrue(ui.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No results for'")).firstMatch.waitForExistence(timeout: 8))
        replace(search, with: "Heart")
        try tap("Heart"); try counts(5)
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount == 1 }
        XCTAssertFalse(try XCTUnwrap(fragment()["assets"] as? JSON).isEmpty)
        try undo(4, redo: 5)
    }
    func testElementDragInsertsAtDropPoint() throws {
        try elements()
        let star = try control("Star")
        star.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8, thenDragTo: ui.coordinate(end))
        try counts(5)
        _ = try ui.waitForState(timeout: 8) { $0.selectionCount > 0 }
        XCTAssertTrue(try selectedBounds().insetBy(dx: -20, dy: -20).contains(ui.coordinate(end).screenPoint))
    }
    func testCollectionCreateCancelRenameReorderDeleteConfirm() throws {
        try elements(); try tap("New Collection")
        replace(try control("Collection name", .textField), with: "Cancelled Collection"); try tap("Cancel")
        XCTAssertFalse(query("Cancelled Collection").firstMatch.exists)
        try collection("Lab Collection")
        try tap("Collection Options"); try tap("Rename Collection")
        replace(try control("Collection name", .textField), with: "Renamed Lab"); try tap("Rename")
        XCTAssertTrue(query("Renamed Lab").firstMatch.waitForExistence(timeout: 8))
        let collectionLabels: Set<String> = ["Stickers", "Labels", "Arrows", "Planner", "Renamed Lab"]
        let before = ui.app.buttons.allElementsBoundByIndex.map(\.label).filter { collectionLabels.contains($0) }
        try tap("Collection Options"); try tap("Move Collection Left")
        let after = ui.app.buttons.allElementsBoundByIndex.map(\.label).filter { collectionLabels.contains($0) }
        XCTAssertLessThan(try XCTUnwrap(after.firstIndex(of: "Renamed Lab")), try XCTUnwrap(before.firstIndex(of: "Renamed Lab")))
        try tap("Collection Options"); try tap("Delete Collection"); try tap("Cancel")
        XCTAssertTrue(query("Renamed Lab").firstMatch.exists)
        try tap("Collection Options"); try tap("Delete Collection"); try tap("Delete Collection")
        try wait("Confirmed collection deletion removes only that collection") { !self.query("Renamed Lab").firstMatch.exists }
        XCTAssertTrue(query("Stickers").firstMatch.exists)
    }
    func testCreateElementSourceRemainsRenameDeleteAndReuse() throws {
        try shape(); try elements(); try collection("My Objects")
        try tap("Create Element from Selection")
        let cells = ui.app.buttons.matching(NSPredicate(format: "label == 'Element' OR label == 'Rectangle' OR label == 'Untitled Element' OR label == 'Element 1'"))
        let element = try XCTUnwrap(cells.allElementsBoundByIndex.first { $0.isHittable }, "Created element must expose its title")
        element.press(forDuration: 0.8); try tap("Rename")
        replace(try control("Element name", .textField), with: "Lab Node"); try tap("Rename")
        try tap("Lab Node"); try counts(6)
        try elements(); try tap("My Objects", scroll: true)
        try control("Lab Node").press(forDuration: 0.8); try tap("Delete"); try tap("Cancel")
        XCTAssertTrue(query("Lab Node").firstMatch.exists)
        try control("Lab Node").press(forDuration: 0.8); try tap("Delete"); try tap("Delete Element")
        try wait("Only confirmed element is removed") { !self.query("Lab Node").firstMatch.exists }
        try counts(6)
    }
    func testCollectionExportShowsShareablePackageAndImportCancel() throws {
        try elements(); try tap("Collection Options"); try tap("Export Collection")
        XCTAssertTrue(ui.app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || query("Save to Files").firstMatch.exists,
                      "Export must produce a share sheet for the collection")
        try ui.dismissSheets(); try elements(); try tap("Collection Options"); try tap("Import Collection")
        try tap("Cancel"); try counts(4)
        XCTAssertTrue(query("Stickers").firstMatch.exists)
    }
    func testGIFLinkDownloadsAnimatedAssetExactlyOnce() throws {
        provider = try InsertProviderFixture(page: "", media: gifData())
        try wait("GIF HTTP fixture must start") { self.provider?.port != nil }
        try elements(); try tap("GIFs"); try tap("Add GIF from a Link")
        replace(try control("https://", .textField), with: "http://127.0.0.1:\(try XCTUnwrap(provider?.port))/test.gif")
        try tap("Add GIF"); try counts(5)
        try all(); XCTAssertEqual(try item("image")["animated"] as? Bool, true)
        XCTAssertFalse(try XCTUnwrap(fragment()["assets"] as? JSON).isEmpty)
        try undo(4, redo: 5)
    }
    func testCollectionExportSaveAndReimportRetainsElementsAndAssets() throws {
        try elements(); try tap("Collection Options"); try tap("Export Collection")
        try tap("Save to Files", scroll: true)
        if visible("On My iPad") { try tap("On My iPad") }
        try tap("Save")
        if visible("Replace") { try tap("Replace") }
        try ui.dismissSheets(); try elements(); try tap("Collection Options"); try tap("Import Collection")
        if visible("Recents") { try tap("Recents") }
        let file = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Stickers' AND (elementType == %d OR elementType == %d)", XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Exported Stickers.nibcollection must be selectable in Files")
        file.tap()
        try tap("Heart"); try counts(5)
        try all(); XCTAssertFalse(try XCTUnwrap(fragment()["assets"] as? JSON).isEmpty)
        XCTAssertNotNil(try item("image")["asset"])
    }
    func testGIFLocalInvalidLinkReportsErrorAndFilesCancelInsertsNothing() throws {
        try elements(); try tap("GIFs"); try tap("Add GIF from a Link")
        replace(try control("https://", .textField), with: "not a URL"); try tap("Add GIF")
        let errors = ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'URL' OR label CONTAINS[c] 'address' OR label CONTAINS[c] 'invalid'"))
        XCTAssertTrue(errors.firstMatch.waitForExistence(timeout: 10), "Invalid GIF link must give an actionable error")
        if visible("Cancel") { try tap("Cancel") }
        try tap("Add GIF from Files"); try tap("Cancel"); try counts(4)
    }
    func testGIPHYKeySaveRemoveAndSearchRetryRetainsQuery() throws {
        try elements(); try tap("GIFs"); try tap("Open Settings")
        if visible("Remove Key") { try tap("Remove Key") }
        let field = try control("Paste your GIPHY API key", .secureTextField)
        field.tap(); field.typeText("nib-ui-invalid-test-key")
        try tap("Save Key")
        XCTAssertTrue(query("Remove Key").firstMatch.waitForExistence(timeout: 8))
        try ui.dismissSheets(); try elements(); try tap("GIFs")
        let search = try control("Search GIPHY", .textField)
        search.tap(); search.typeText("physics\n")
        try tap("Try Again", scroll: true)
        XCTAssertEqual(search.value as? String, "physics")
        outside(); key(","); try tap("Elements and GIFs", scroll: true); try tap("Remove Key")
        XCTAssertTrue(query("Paste your GIPHY API key").firstMatch.waitForExistence(timeout: 8))
    }

    // MARK: sticky, sticky.setCollapsed/resolve/setColor

    private func sticky(_ text: String = "Lab reminder") throws {
        try ui.selectTool("sticky"); try tap("tool.sticky")
        replace(try control("Author name on new notes", .textField, scroll: true), with: "UI Author")
        outside(); ui.coordinate(point).tap()
        let editor = try control("Sticky note", .textView)
        editor.typeText(text); try finish(); try counts(5)
        try selectAt()
    }
    func testStickySevenColoursAndSelectedOnlyRecolour() throws {
        try sticky(); let original = try item("sticky")
        var colours = Set<String>()
        for colour in ["Lemon", "Blush", "Apricot", "Mint", "Sky", "Lilac", "Stone"] {
            try menu("Style")
            if query("Sticky Note", .button).allElementsBoundByIndex.contains(where: { $0.isHittable }) { try tap("Sticky Note") }
            try tap(colour); outside()
            let changed = try item("sticky")
            colours.insert(json(changed["color"]))
            XCTAssertEqual(try plain(changed), "Lab reminder")
        }
        XCTAssertEqual(colours.count, 7)
        try all(); let notes = try items().compactMap { $0["sticky"] as? JSON }
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(try plain(try XCTUnwrap(notes.first)), "Remember F = ma")
        XCTAssertEqual(original["author"] as? String, "UI Author", "New sticky must retain its author")
    }
    func testStickyCollapseExpandResolveReopenRetainsText() throws {
        try sticky(); try menu("Collapse Note")
        XCTAssertEqual(try item("sticky")["collapsed"] as? Bool, true)
        try menu("Expand Note")
        XCTAssertEqual(try item("sticky")["collapsed"] as? Bool, false)
        try menu("Resolve")
        XCTAssertEqual(try item("sticky")["resolved"] as? Bool, true)
        try menu("Reopen")
        let reopened = try item("sticky")
        XCTAssertEqual(reopened["resolved"] as? Bool, false)
        XCTAssertEqual(try plain(reopened), "Lab reminder")
    }

    // MARK: tape, settings, reveal, removeAll, patterns and history

    private func drawTape(_ path: [CGPoint]? = nil) throws {
        let before = try ui.state()
        try ui.selectTool("tape"); try ui.drawStroke(path ?? [point, end])
        try counts(before.itemCountOnPage + 1, strokes: before.strokeCountOnPage + 1)
    }
    func testTapeDrawHideRevealDoesNotAddUndoAndRemoveAllRestores() throws {
        try ui.selectTool("pen"); try ui.drawStroke([point, end]); try counts(5, strokes: 2)
        try drawTape(); try counts(6, strokes: 3)
        let masked = try canvasPixels()
        ui.coordinate(CGPoint(x: 0.53, y: 0.70)).tap()
        try wait("Reveal tape must visibly expose underlying pen ink") {
            guard let current = try? self.canvasPixels() else { return false }
            return self.changedPixels(masked, current) > 40
        }
        ui.coordinate(CGPoint(x: 0.53, y: 0.70)).tap()
        try wait("Hide tape restores the opaque strip") {
            guard let current = try? self.canvasPixels() else { return false }
            return self.changedPixels(masked, current) < 20
        }
        try counts(6, strokes: 3)
        try ui.tapCommand("edit.undo"); try counts(5, strokes: 2)
        try ui.tapCommand("edit.redo"); try counts(6, strokes: 3)
        try tap("tool.tape"); try tap("Remove All Tape", scroll: true); try tap("Cancel")
        try counts(6, strokes: 3)
        try tap("Remove All Tape", scroll: true); try tap("Remove All Tape")
        outside(); try counts(5, strokes: 2)
        try ui.tapCommand("edit.undo"); try counts(6, strokes: 3)
    }
    func testTapePatternWidthStraightnessOrientationAndClearHistory() throws {
        try ui.selectTool("tape"); try tap("tool.tape")
        try tap("Colour 2", scroll: true); try tap("9.2 mm", scroll: true)
        // Return to the pattern grid after choosing the width lower in the popover.
        outside(); try tap("tool.tape"); try tap("Stripes")
        try toggle("Straight tape", to: true); try tap("Horizontal", scroll: true); outside()
        let bentPath = [point, CGPoint(x: 0.53, y: 0.60), end]
        try drawTape(bentPath)
        let tape = try snapshot("stroke"), style = try XCTUnwrap(tape["style"] as? JSON)
        XCTAssertEqual(style["tool"] as? String, "tape")
        XCTAssertNotNil(style["tapePattern"])
        XCTAssertEqual(style["tapeFollowsDirection"] as? Bool, false)
        XCTAssertEqual(style["width"] as? Double, 26)
        XCTAssertTrue(json(style["color"]).uppercased().contains("8EC5FF"))
        let points = try XCTUnwrap(tape["pts"] as? [Double])
        XCTAssertEqual(tape["fmt"] as? String, "full")
        XCTAssertGreaterThanOrEqual(points.count, 20)
        let last = points.count - 10
        let dx = points[last] - points[0], dy = points[last + 1] - points[1]
        for index in stride(from: 0, to: points.count, by: 10) {
            let cross = (points[index] - points[0]) * dy - (points[index + 1] - points[1]) * dx
            XCTAssertEqual(cross / max(hypot(dx, dy), 1), 0, accuracy: 0.1, "Straight tape must flatten the bent gesture")
        }
        try ui.selectTool("tape"); try tap("tool.tape"); try tap("History"); try tap("Clear History")
        XCTAssertTrue(query("Tape you use appears here.").firstMatch.waitForExistence(timeout: 8))
        try tap("Patterns"); XCTAssertTrue(query("Stripes").firstMatch.exists)
        try tap("Follow stroke", scroll: true); try toggle("Straight tape", to: false); outside()
        try drawTape(bentPath); try counts(6, strokes: 3)
        let bent = try snapshot("stroke")
        XCTAssertEqual((bent["style"] as? JSON)?["tapeFollowsDirection"] as? Bool, true)
        XCTAssertGreaterThan((bent["pts"] as? [Double])?.count ?? 0, 20, "Free tape must retain the gesture's bend")
    }
    func testTapeImportPatternFilesCancelRetainsBuiltIns() throws {
        try ui.selectTool("tape"); try tap("tool.tape"); try tap("Add a pattern from an image", scroll: true)
        try tap("Files"); try tap("Cancel")
        XCTAssertTrue(query("Stripes").firstMatch.exists)
        XCTAssertFalse(query("Image 1").firstMatch.exists)
        try counts(4, strokes: 1)
    }
    func testTapeImportedPhotoPatternCanBeDrawnAndDeleted() throws {
        try image(); try menu("Save to Photos"); try allowSystemPermissionIfPresented(); outside()
        try ui.selectTool("tape"); try tap("tool.tape"); try tap("Add a pattern from an image", scroll: true); try tap("Photos")
        let photo = ui.app.images.matching(NSPredicate(format: "label CONTAINS[c] 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.tap()
        try tap("Image 1", scroll: true); outside(); try drawTape()
        XCTAssertNotNil((try snapshot("stroke")["style"] as? JSON)?["tapePattern"])
        try ui.selectTool("tape"); try tap("tool.tape")
        try control("Image 1", scroll: true).press(forDuration: 0.8); try tap("Delete Pattern")
        try wait("Deleting a custom pattern removes that tile") { !self.query("Image 1").firstMatch.exists }
        XCTAssertTrue(query("Stripes").firstMatch.exists); try counts(6)
    }

    // MARK: link.set/remove/autodetect/follow/back, clipboard.copyText

    private func linkText() throws { try beginText("Visit lab"); key("a"); key("k") }
    func testURLLinkSaveRemoveKeepsText() throws {
        try linkText(); replace(try control("Website address", .textField), with: "https://example.com/lab")
        try tap("Add Link"); try finish()
        let linked = try snapshot("text")
        XCTAssertTrue(json(linked).contains("https://example.com/lab"))
        try selectAt(); try menu("Edit Link"); try tap("Remove Link")
        let removed = try snapshot("text")
        XCTAssertFalse(json(removed).contains("https://example.com/lab"))
        XCTAssertEqual(try plain(removed), "Visit lab")
    }
    func testAutomaticURLLinkPreservesTypedText() throws {
        try beginText("https://example.com/physics"); try finish()
        let box = try snapshot("text")
        XCTAssertEqual(try plain(box), "https://example.com/physics")
        XCTAssertTrue(json(try paragraphs(box)).contains("\"link\""), "Finished URL text must carry a tappable link")
    }
    func testPageLinkFollowAndReturnRestoresPreviousLocation() throws {
        let original = try ui.state()
        try linkText(); try tap("Document"); try tap("Physics — Motion"); try tap("Page 2")
        try tap("Add Link"); try finish()
        let link = try snapshot("text")
        XCTAssertTrue(json(link).contains("link"))
        try ui.tapCommand("view.setReadOnly"); ui.coordinate(point).tap()
        _ = try ui.waitForState(timeout: 8) { $0.page != original.page && $0.document == original.document }
        try ui.tapCommand("link.back")
        _ = try ui.waitForState(timeout: 8) { $0.page == original.page && $0.document == original.document }
    }
    func testCopyTextUsesActualSelectedText() throws {
        try beginText("Copied rich text"); key("a"); key("c")
        try wait("Copy must put the selected text on the system clipboard") { UIPasteboard.general.string == "Copied rich text" }
        try finish(); try counts(5, strokes: 1)
    }

    // MARK: comments

    private func comment(_ text: String = "Check the units") throws {
        try pageMenu(); try tap("Add Comment")
        let input = try control("Add a comment")
        input.tap(); input.typeText(text); try tap("Send")
        try counts(5)
        XCTAssertTrue(ui.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 8))
    }
    private func message(_ text: String) throws -> XCUIElement {
        let q = ui.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
        return try XCTUnwrap(q.allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 15 }, "Thread must show message \(text)")
    }
    func testCommentAddOpenBadgeReplyAndCopyText() throws {
        try comment(); try tap("cmd.panel.close")
        ui.coordinate(point).tap()
        XCTAssertTrue(try message("Check the units").exists)
        let reply = try control("Reply"); reply.tap(); reply.typeText("Use metres per second"); try tap("Send")
        let posted = try message("Use metres per second")
        XCTAssertTrue(posted.label.contains("Anonymous"), "Reply retains the current author")
        XCTAssertTrue(posted.label.contains(":"), "Reply displays its timestamp")
        posted.press(forDuration: 0.8); try tap("Copy Text")
        try wait("Comment Copy Text returns the chosen reply") { UIPasteboard.general.string == "Use metres per second" }
        try counts(5)
    }
    func testObjectCommentAnchorsSelectedShapeAndCopiesDeepLink() throws {
        try shape(); try menu("Add Comment")
        let input = try control("Add a comment")
        input.tap(); input.typeText("Shape annotation"); try tap("Send"); try counts(6)
        // Thread-level More is beside Resolve; exclude the document and palette menus.
        let resolve = try control("Resolve Thread")
        let more = query("More", .button).allElementsBoundByIndex.first {
            $0.isHittable && $0.identifier != "menu.more" && $0.identifier != "tool.more" && abs($0.frame.midY - resolve.frame.midY) < 30
        }
        try XCTUnwrap(more, "Thread must expose its actions").tap(); try tap("Copy Link")
        let state = try ui.state()
        try wait("Copied comment link must identify the current document and comment") {
            guard let link = UIPasteboard.general.string else { return false }
            return link.hasPrefix("nib:") && link.contains(state.document ?? "missing")
        }
        XCTAssertTrue(try message("Shape annotation").exists)
    }
    func testCommentEditCancelSaveAndDeleteFinalMessageRemovesAnchor() throws {
        try comment(); try message("Check the units").press(forDuration: 0.8); try tap("Edit Message")
        replace(try control("Message"), with: "Cancelled edit"); try tap("Cancel")
        XCTAssertTrue(try message("Check the units").exists)
        try message("Check the units").press(forDuration: 0.8); try tap("Edit Message")
        replace(try control("Message"), with: "Confirmed edit"); try tap("Save")
        try message("Confirmed edit").press(forDuration: 0.8); try tap("Delete Message"); try tap("Cancel")
        XCTAssertTrue(try message("Confirmed edit").exists)
        try message("Confirmed edit").press(forDuration: 0.8); try tap("Delete Message"); try tap("Delete Thread")
        try counts(4); try ui.tapCommand("edit.undo"); try counts(5)
    }
    func testCommentResolveFilterReopenAndShowOnPage() throws {
        try comment(); let original = try ui.state()
        try tap("Resolve Thread"); XCTAssertTrue(query("Reopen Thread").firstMatch.waitForExistence(timeout: 8))
        try tap("cmd.panel.close"); try panel("Comments")
        try toggle("Show Resolved", to: false)
        XCTAssertTrue(query("No open comments").firstMatch.waitForExistence(timeout: 8))
        try toggle("Show Resolved", to: true)
        try message("Check the units").tap(); try tap("Reopen Thread")
        try message("Check the units").press(forDuration: 0.8)
        if visible("Cancel") { try tap("Cancel") }
        try tap("cmd.panel.close"); try goToSecondPage(); try panel("Comments")
        try message("Check the units").press(forDuration: 0.8); try tap("Show on Page")
        _ = try ui.waitForState(timeout: 8) { $0.page == original.page }
        XCTAssertTrue(try message("Check the units").exists)
    }

    // MARK: audio and replay; the microphone records through the production audio engine.

    private func startRecording() throws {
        try ui.tapCommand("audio.record")
        try allowSystemPermissionIfPresented()
        if !visible("Pause Recording") { outside() }
        try wait("Recording must start and expose Pause Recording", timeout: 15) { self.visible("Pause Recording") }
    }
    private func recordClip(draw: Bool = false, minimumSeconds: Int = 4) throws {
        try startRecording()
        let timer = query("Recording").firstMatch
        let first = timer.value as? String
        try wait("Recording clock must advance", timeout: 8) { timer.value as? String != first }
        try wait("Recording must contain enough audio for playback actions", timeout: TimeInterval(minimumSeconds + 10)) {
            Self.seconds(timer.value as? String ?? "") >= Double(minimumSeconds)
        }
        if draw {
            let count = try ui.state().strokeCountOnPage
            try ui.selectTool("pen"); try ui.drawStroke([point, end]); try counts(5, strokes: count + 1)
        }
        try tap("Stop Recording")
        try wait("Stop must leave recording mode") { !self.visible("Pause Recording") }
        try panel("Audio")
    }
    private static func seconds(_ spoken: String) -> Double {
        let tokens = spoken.replacingOccurrences(of: ",", with: " ").split(separator: " ")
        var result = 0.0
        for index in tokens.indices where index + 1 < tokens.count {
            guard let amount = Double(tokens[index]) else { continue }
            let unit = tokens[index + 1]
            if unit.hasPrefix("hour") { result += amount * 3600 }
            else if unit.hasPrefix("minute") { result += amount * 60 }
            else if unit.hasPrefix("second") { result += amount }
        }
        return result
    }
    private func playbackTimes() throws -> (position: Double, duration: Double) {
        let value = try XCTUnwrap(control("Playback position", .slider).value as? String)
        let parts = value.components(separatedBy: " of ")
        guard parts.count == 2 else { throw NibUI.Failure.message("Playback accessibility must report current and total time: " + value) }
        return (Self.seconds(parts[0]), Self.seconds(parts[1]))
    }
    private func clipRow() throws -> XCUIElement {
        let q = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Recording' AND NOT label CONTAINS 'Settings'"))
        try wait("Saved recording must appear in Audio") { q.allElementsBoundByIndex.contains { $0.isHittable } }
        return try XCTUnwrap(q.allElementsBoundByIndex.first { $0.isHittable })
    }
    func testAudioMicrophoneDenialShowsRecoveryAndCreatesNoClip() throws {
        resetMicrophonePermission = true
        ui.app.resetAuthorizationStatus(for: .microphone)
        try ui.launchFixture(); try ui.openDocument("Physics — Motion")
        var denied = false
        let denialMonitor = addUIInterruptionMonitor(withDescription: "Deny this recording's microphone request") { alert in
            guard let button = alert.buttons.allElementsBoundByIndex.first(where: {
                $0.label.contains("Allow") && !$0.label.hasPrefix("Allow")
            }) else { return false }
            button.tap(); denied = true; return true
        }
        defer { removeUIInterruptionMonitor(denialMonitor) }
        try ui.tapCommand("audio.record")
        if let alert = permissionAlert(timeout: 15) {
            let deny = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND NOT label BEGINSWITH 'Allow'")).firstMatch
            XCTAssertTrue(deny.exists, "Microphone prompt must offer Don't Allow"); deny.tap(); denied = true
        } else { outside() }
        try wait("The real microphone permission prompt must be denied") { denied }
        try panel("Audio")
        XCTAssertTrue(query("Microphone access is off for Nib. Turn it on in Settings to record.").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(query("No recordings yet").firstMatch.exists)
        XCTAssertFalse(query("Pause Recording").firstMatch.exists)
        try tap("Open Settings")
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.Preferences").wait(for: .runningForeground, timeout: 10),
                      "Permission recovery must actually open Settings")
        ui.app.activate(); try counts(4, strokes: 1)
    }
    func testAudioRecordPauseResumeStopPersistsClip() throws {
        try startRecording(); try tap("Pause Recording")
        XCTAssertTrue(query("Resume Recording").firstMatch.waitForExistence(timeout: 8))
        let timer = query("Recording paused").firstMatch, paused = timer.value as? String
        try tap("Resume Recording")
        try wait("Resume must advance recording clock", timeout: 8) { self.query("Recording").firstMatch.value as? String != paused }
        try tap("Stop Recording"); try panel("Audio")
        XCTAssertTrue(try clipRow().exists)
        try ui.tapCommand("window.showLibrary"); try ui.openDocument("Physics — Motion"); try panel("Audio")
        XCTAssertTrue(try clipRow().exists)
    }
    func testAudioCrossDocumentAndBackgroundShowReturnsOwner() throws {
        let owner = try ui.state().document
        try startRecording(); try ui.tapCommand("window.showLibrary"); try ui.openDocument("Concept map")
        XCUIDevice.shared.press(.home); ui.app.activate()
        XCTAssertTrue(query("Pause Recording").firstMatch.waitForExistence(timeout: 10))
        try panel("Audio"); try tap("Show")
        _ = try ui.waitForState(timeout: 10) { $0.document == owner }
        try tap("Stop Recording"); try panel("Audio"); XCTAssertTrue(try clipRow().exists)
    }
    func testAudioPlayPauseSeekSkipSettingsAndClose() throws {
        try recordClip(minimumSeconds: 18); try clipRow().tap()
        try wait("Playing clip exposes Pause") { self.visible("Pause") }
        try tap("Pause")
        let position = try control("Playback position", .slider)
        let before = position.value as? String
        position.adjust(toNormalizedSliderPosition: 0.75)
        try wait("Scrub must change bounded playback position") { position.value as? String != before }
        let scrubbed = try playbackTimes()
        XCTAssertEqual(scrubbed.position, scrubbed.duration * 0.75, accuracy: 1.5)
        try tap("Playback Options"); try tap("Back 10 Seconds")
        XCTAssertEqual(try playbackTimes().position, max(0, scrubbed.position - 10), accuracy: 1)
        try tap("Playback Options"); try tap("Back 10 Seconds")
        XCTAssertEqual(try playbackTimes().position, 0, accuracy: 1)
        for _ in 0..<3 { try tap("Playback Options"); try tap("Forward 10 Seconds") }
        let bounded = try playbackTimes()
        XCTAssertEqual(bounded.position, bounded.duration, accuracy: 1)
        position.adjust(toNormalizedSliderPosition: 0.25)
        for speed in ["0.5×", "2×", "1×"] {
            try tap("Playback Options"); try tap("Speed"); try tap(speed)
            XCTAssertTrue((try control("Playback Options").value as? String)?.contains(speed) == true)
        }
        try tap("Playback Options"); try tap("Skip Silence")
        XCTAssertTrue((try control("Playback Options").value as? String)?.contains("Skipping silence") == true)
        try tap("Playback Options"); try tap("Reduce Noise")
        XCTAssertTrue((try control("Playback Options").value as? String)?.contains("Reducing noise") == true)
        try tap("Play"); try tap("Pause")
        try tap("Playback Options"); try tap("Close Player")
        try wait("Close Player unloads playback bar") { !self.query("Playback position").firstMatch.exists }
    }
    func testAudioRenameExportDeleteCancelAndConfirm() throws {
        try recordClip(); try clipRow().press(forDuration: 0.8); try tap("Rename")
        replace(try control("Name", .textField), with: "Motion lecture"); try tap("Rename")
        let row = try control("Motion lecture")
        let duration = row.value as? String
        row.press(forDuration: 0.8); try tap("Share Audio File")
        XCTAssertTrue(query("Save to Files").firstMatch.waitForExistence(timeout: 10), "Share must expose a real audio file")
        try ui.dismissSheets(); try control("Motion lecture").tap(); try tap("Pause")
        try control("Motion lecture").press(forDuration: 0.8); try tap("Delete Recording"); try tap("Cancel")
        XCTAssertTrue(query("Playback position").firstMatch.exists)
        XCTAssertEqual(try control("Motion lecture").value as? String, duration)
        try control("Motion lecture").press(forDuration: 0.8); try tap("Delete Recording"); try tap("Delete Recording")
        try wait("Confirmed delete removes recording and unloads player") {
            !self.query("Motion lecture").firstMatch.exists && !self.query("Playback position").firstMatch.exists
        }
    }
    func testReplayModesAndSeekFromRealTimestampedInk() throws {
        try recordClip(draw: true); try clipRow().tap(); try tap("Pause")
        let slider = try control("Playback position", .slider)
        slider.adjust(toNormalizedSliderPosition: 0)
        let beginning = slider.value as? String
        try tap("cmd.panel.close")
        var rendered: [String: [UInt8]] = [:]
        for mode in ["Spotlight", "Reveal", "Static"] {
            try documentMenu("Replay Options"); try tap(mode)
            XCTAssertTrue(try control(mode).isSelected, "Replay mode must reflect the applied setting")
            try ui.dismissSheets()
            rendered[mode] = try canvasPixels()
        }
        XCTAssertGreaterThan(changedPixels(try XCTUnwrap(rendered["Static"]), try XCTUnwrap(rendered["Reveal"])), 20,
                             "Reveal must hide future timestamped ink while Static keeps it visible")
        XCTAssertGreaterThan(changedPixels(try XCTUnwrap(rendered["Static"]), try XCTUnwrap(rendered["Spotlight"])), 20,
                             "Spotlight must fade future timestamped ink")
        try selectAt(CGPoint(x: 0.53, y: 0.70)); try menu("Replay Handwriting")
        try wait("Replay Handwriting must seek from the stroke timestamp") {
            self.query("Playback position").firstMatch.value as? String != beginning
        }
        XCTAssertEqual(try ui.state().strokeCountOnPage, 2, "Replay must never destroy ink")
        let originalZoom = try ui.state().zoom
        try ui.pinchZoom(scale: 1.5)
        let zoomed = try ui.waitForState(timeout: 8) { $0.zoom > originalZoom + 0.01 }
        XCTAssertGreaterThanOrEqual(zoomed.zoom, min(0.5, originalZoom)); XCTAssertLessThanOrEqual(zoomed.zoom, 8)
    }
    func testAudioTimestampLinkSavesChosenRecordingAndTime() throws {
        try recordClip(); try ui.dismissSheets(); try linkText(); try tap("Audio")
        let row = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Recording'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        try tap("One second later"); try tap("Add Link"); try finish()
        let linked = try snapshot("text")
        XCTAssertTrue(json(linked).contains("audio")); XCTAssertTrue(json(linked).contains("link"))
        XCTAssertEqual(try plain(linked), "Visit lab")
    }

    // MARK: transcript.panel/seek/editSegment/regenerate/insert
    // A local external provider supplies deterministic speech results through the production HTTP parser.
    // No app storage, commands, or services are injected; provider setup and regeneration use real UI.

    private func transcript() throws {
        try configureProvider()
        key(","); try tap("Recording Settings", scroll: true); try toggle("Cloud transcription", to: true)
        try ui.dismissSheets()
        try recordClip(); try documentMenu("Transcript")
        _ = try ui.waitForState(timeout: 8) { $0.openPanels.contains("transcription") }
    }
    func testTranscriptSearchFollowAndRegenerationPreserveRecording() throws {
        try transcript(); try toggle("Follow playback", to: true)
        let search = try control("Search transcript", .textField)
        search.tap(); search.typeText("nonmatching phrase")
        XCTAssertTrue(query("No matching lines").firstMatch.waitForExistence(timeout: 8))
        replace(search, with: ""); key(XCUIKeyboardKey.delete.rawValue, [])
        try tap("Regenerate Transcript", scroll: true)
        if visible("Replace Transcript") { try tap("Replace Transcript") }
        try wait("Regeneration must finish with transcript or useful error", timeout: 30) {
            !self.query("Transcribing").firstMatch.exists &&
            (self.query("No transcript yet").firstMatch.exists || self.ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'speech' OR label CONTAINS[c] 'permission' OR label CONTAINS[c] 'unavailable'")).firstMatch.exists ||
             self.ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play from '")).firstMatch.exists)
        }
        try panel("Audio"); XCTAssertTrue(try clipRow().exists)
    }
    func testTranscriptTimestampCorrectionCopyAndInsert() throws {
        try transcript(); try tap("Regenerate Transcript", scroll: true)
        if visible("Replace Transcript") { try tap("Replace Transcript") }
        let timestamp = ui.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play from ' AND label ENDSWITH 'and show linked page'")).firstMatch
        XCTAssertTrue(timestamp.waitForExistence(timeout: 30), "Cloud regeneration must parse the external provider segment for the recorded clip")
        let recordedPage = try ui.state().page
        try goToSecondPage()
        timestamp.tap(); XCTAssertTrue(query("Playback position").firstMatch.waitForExistence(timeout: 8))
        _ = try ui.waitForState(timeout: 8) { $0.page == recordedPage }
        timestamp.press(forDuration: 0.8); try tap("Edit")
        replace(try control("Transcript text"), with: "Cancelled correction"); try tap("Cancel")
        XCTAssertFalse(query("Cancelled correction").firstMatch.exists)
        timestamp.press(forDuration: 0.8); try tap("Edit")
        replace(try control("Transcript text"), with: "Corrected motion lecture"); try tap("Save")
        let line = try control("Corrected motion lecture")
        XCTAssertTrue(query("Measure distance and time.").firstMatch.exists, "Correcting one segment must retain the other segment")
        line.press(forDuration: 0.8); try tap("Copy")
        try wait("Transcript Copy preserves corrected text") { UIPasteboard.general.string == "Corrected motion lecture" }
        let count = try ui.state().itemCountOnPage
        line.press(forDuration: 0.8); try tap("Insert on Page"); try counts(count + 1)
        XCTAssertTrue(query("Corrected motion lecture").firstMatch.exists, "Inserting text must retain source transcript")
        try ui.tapCommand("edit.undo"); try counts(count)
    }
}


/// External HTTP fixture, configured through Settings like any compatible provider. It never reaches
/// into Nib: the app records/exports audio, makes HTTP requests, parses replies, and commits through its UI.
@MainActor
private final class InsertProviderFixture {
    private let listener: NWListener
    private let page: String
    private let media: Data?
    private var connections: [NWConnection] = []
    var port: UInt16? { listener.port?.rawValue }

    init(page: String, media: Data? = nil) throws {
        self.page = page
        self.media = media
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
    func stop() { connections.forEach { $0.cancel() }; listener.cancel() }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { connection.cancel(); return }
                var received = accumulated
                if let data { received.append(data) }
                guard received.count < 16_000_000 else { connection.cancel(); return }
                if let separator = received.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
                    let length = header.components(separatedBy: "\r\n").first {
                        $0.lowercased().hasPrefix("content-length:")
                    }.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                    let body = Data(received[separator.upperBound...])
                    if body.count >= length { self.respond(connection, header: header, body: body); return }
                }
                if complete { connection.cancel() } else { self.receive(connection, accumulated: received) }
            }
        }
    }
    private func respond(_ connection: NWConnection, header: String, body: Data) {
        do {
            let payload: Data
            let type: String
            if header.contains("/test.gif"), let media {
                payload = media; type = "image/gif"
            } else if header.contains("audio/transcriptions") {
                payload = try JSONSerialization.data(withJSONObject: ["segments": [
                    ["start": 0.0, "end": 0.5, "text": "Motion changes with force."],
                    ["start": 0.5, "end": 1.0, "text": "Measure distance and time."]]])
                type = "application/json"
            } else {
                let request = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let messages = request?["messages"] as? [[String: Any]] ?? []
                let hasResult = messages.contains { $0["role"] as? String == "tool" }
                let delta: [String: Any]
                if hasResult { delta = ["content": "Inserted the editable diagram."] }
                else {
                    let arguments: [String: Any] = ["command": "diagram.create", "params": [
                        "page": page, "layout": "flow", "style": "classic",
                        "nodes": [["id": "motion", "label": "Motion"], ["id": "force", "label": "Force"]],
                        "edges": [["from": "motion", "to": "force"]]]]
                    let encoded = try JSONSerialization.data(withJSONObject: arguments)
                    delta = ["tool_calls": [["index": 0, "id": "insert_diagram", "type": "function",
                        "function": ["name": "nib_run", "arguments": String(decoding: encoded, as: UTF8.self)]]]]
                }
                let events: [[String: Any]] = [
                    ["choices": [["index": 0, "delta": delta]]],
                    ["choices": [["index": 0, "delta": [:], "finish_reason": hasResult ? "stop" : "tool_calls"]]]]
                let stream = try events.map {
                    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n"
                }.joined() + "data: [DONE]\n\n"
                payload = Data(stream.utf8); type = "text/event-stream"
            }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        } catch { connection.cancel() }
    }
}
