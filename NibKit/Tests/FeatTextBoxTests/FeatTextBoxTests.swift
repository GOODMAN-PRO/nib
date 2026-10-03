import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatTextBox

/// Refs `link.autodetect` (F029's) was called with, from a test double.
private final class AutodetectCalls {
    var refs: [String] = []
}

/// Params a test double command was called with.
private final class Calls {
    var params: [JSONValue] = []
}

/// The window's floating host (contracts-v2 `FloatingHosting`) without a window: records what is presented and anchored.
/// `offset` moves every rect into the container, as the window's layout would.
@MainActor
private final class FakeFloatingHost: FloatingHosting {
    var presented: [String] = []
    var anchors: [String: CGRect] = [:]
    var offset: CGFloat = 900

    func present(_ id: String, content: AnyView) { if !presented.contains(id) { presented.append(id) } }
    func dismiss(_ id: String) { presented.removeAll { $0 == id } }
    func isPresenting(_ id: String) -> Bool { presented.contains(id) }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        anchors[id] = rect
        return true
    }
    func removeAnchor(_ id: String) { anchors[id] = nil }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect.offsetBy(dx: 0, dy: offset) }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
}

@MainActor
final class FeatTextBoxTests: XCTestCase {
    private let textRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"

    private func box(_ h: Harness, _ id: ElementID = Fixtures.textID, page: PageID = Fixtures.page1) throws -> TextBoxItem {
        try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: page, id: id).text)
    }

    private func editor(_ h: Harness) -> (FakeCanvasHost, TextBoxEditor) {
        let host = FakeCanvasHost(h)
        let editor = TextBoxEditor(host: host)
        editor.attach(to: host)
        return (host, editor)
    }

    private func editingID(_ editor: TextBoxEditor) throws -> (PageID, ElementID) {
        let ref = try XCTUnwrap(editor.editingRef)
        guard case let .item(_, page, id)? = NodeRef(ref) else {
            XCTFail("not an item ref: \(ref)")
            throw NibError.invalid("not an item ref")
        }
        return (page, id)
    }

    /// Types `s` at the selection the way UIKit does: asks the delegate, and inserts only if it lets the text view.
    @discardableResult
    private func typeText(_ s: String, into tv: UITextView, _ editor: TextBoxEditor) -> Bool {
        let range = tv.selectedRange
        guard editor.textView(tv, shouldChangeTextIn: range, replacementText: s) else { return false }
        tv.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: tv.typingAttributes))
        tv.selectedRange = NSRange(location: range.location + (s as NSString).length, length: 0)
        editor.textViewDidChange(tv)
        return true
    }

    // MARK: Commands

    func testFeatureConformance() async {
        let problems = await CommandConformance.check(features: [FeatTextBoxFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsToolAndDrawer() {
        let h = Harness(features: [FeatTextBoxFeature.self])
        for id in ["text.createBox", "text.setText", "text.format", "text.setParagraph", "text.setBoxStyle",
                   "text.saveDefaultStyle", "text.tapAt"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, "text", id)
        }
        XCTAssertNotNil(h.app.ui.canvasTools.get("text"))
        XCTAssertEqual(h.app.ui.toolbar.get("text")?.shortcut, KeyShortcut("t"))
        XCTAssertNotNil(h.app.content.drawers.get("text"))
        XCTAssertEqual(h.app.content.tapHandlers.all.filter { $0.command == "text.tapAt" }.count, 2)
    }

    func testCreateBoxHonoursIdAndUndoes() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let before = try h.snapshot()
        let out = try await h.run("text.createBox", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [72, 96],
                                                     "text": "Kinematics", "id": "MYTEXTBOX001"])
        XCTAssertEqual(out["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG002/MYTEXTBOX001")
        let created = try box(h, "MYTEXTBOX001", page: Fixtures.page2)
        XCTAssertEqual(created.text.plainText, "Kinematics")
        XCTAssertEqual(created.frame.h, TextLayout.fittedHeight(created), accuracy: 0.001)
        XCTAssertGreaterThan(created.frame.w, 100)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testCreateBoxRejectsATakenId() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        do {
            try await h.run("text.createBox", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [72, 96],
                                               "id": "FIXTURETXT01"])
            XCTFail("expected a conflict")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .conflict)
        }
    }

    func testFormatOnARangeSplitsRunsAndUndoes() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let before = try h.snapshot()
        try await h.run("text.format", ["ref": .string(textRef), "attrs": ["bold": true], "range": [0, 5]])
        let runs = try box(h).text.paragraphs[0].runs
        XCTAssertEqual(runs.map { $0.text }, ["Hello", " Nib"])
        XCTAssertEqual(runs[0].attrs.bold, true)
        XCTAssertNil(runs[1].attrs.bold)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testFormatWithoutARangeBecomesTheBoxDefault() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.format", ["ref": .string(textRef), "attrs": ["bold": true], "range": [0, 5]])
        try await h.run("text.format", ["ref": .string(textRef), "attrs": ["font": "Georgia", "size": 20, "bold": false]])
        let b = try box(h)
        XCTAssertEqual(b.style.defaults.font, "Georgia")
        XCTAssertEqual(b.style.defaults.size, 20)
        XCTAssertTrue(b.text.paragraphs[0].runs.allSatisfy { $0.attrs.bold == nil && $0.attrs.size == nil })
        XCTAssertEqual(b.text.plainText, "Hello Nib")
        XCTAssertEqual(b.frame.h, TextLayout.fittedHeight(b), accuracy: 0.001)
    }

    func testSetTextGrowsTheBoxToFit() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let long = String(repeating: "Velocity is the rate of change of displacement. ", count: 12)
        try await h.run("text.setText", ["ref": .string(textRef), "text": .string(long)])
        let b = try box(h)
        XCTAssertGreaterThan(b.frame.h, 100)
        XCTAssertEqual(b.frame.h, TextLayout.fittedHeight(b), accuracy: 0.001)
    }

    func testSetParagraphTouchesOnlyTheParagraphsInRange() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.setText", ["ref": .string(textRef), "text": "one\ntwo\nthree"])
        try await h.run("text.setParagraph", ["ref": .string(textRef), "list": "number", "range": [4, 1]])
        try await h.run("text.setParagraph", ["ref": .string(textRef), "indentBy": 1, "range": [4, 0]])
        let paragraphs = try box(h).text.paragraphs
        XCTAssertEqual(paragraphs.map { $0.list }, [.plain, .number, .plain])
        XCTAssertEqual(paragraphs.map { $0.indent }, [0, 1, 0])
    }

    func testARefGivenTwiceIsStyledOnceAndUndoesInOneStep() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let before = try h.snapshot()
        try await h.run(CommandIDs.textSetBoxStyle, ["refs": [.string(textRef), .string(textRef)],
                                                     "style": ["padding": 12, "defaults": ["size": 30], "lineSpacing": 6]])
        let b = try box(h)
        XCTAssertEqual(b.style.padding, 12)
        XCTAssertEqual(b.style.defaults.size, 30)
        XCTAssertEqual(b.text.paragraphs[0].lineSpacing, 6)
        XCTAssertNil(b.style.lineSpacing, "paragraph settings live in the paragraphs, not in the box style")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before, "a box written twice in one step reverts all the way")
    }

    func testSetBoxStyleMergesAndClearsFields() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.setBoxStyle", ["refs": [.string(textRef)],
                                             "style": ["cornerRadius": 12, "background": "#FFF3B0FF", "align": "center"]])
        var b = try box(h)
        XCTAssertEqual(b.style.cornerRadius, 12)
        XCTAssertEqual(b.style.padding, 4, "fields left out are unchanged")
        XCTAssertEqual(b.style.background, RGBA(hex: "#FFF3B0FF"))
        XCTAssertEqual(b.text.paragraphs[0].align, .center)
        try await h.run("text.setBoxStyle", ["refs": [.string(textRef)], "style": ["background": .null]])
        b = try box(h)
        XCTAssertNil(b.style.background)
        XCTAssertEqual(b.style.cornerRadius, 12)
    }

    func testTextCommandsNeedAnItemWithText() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.setText", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "text": "Label"])
        let shape = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        XCTAssertEqual(shape.shape?.text?.plainText, "Label", "shapes carry text too")
        do {
            try await h.run("text.setText", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "text": "ink"])
            XCTFail("strokes have no text")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.ref")
        }
    }

    func testSavedStylesApplyToNewBoxes() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.saveDefaultStyle", ["style": ["defaults": ["size": 24], "padding": 10, "align": "right"]])
        let out = try await h.run("text.createBox", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [72, 96],
                                                     "text": "Styled", "id": "STYLEDBOX001"])
        XCTAssertNotNil(out["ref"])
        let styled = try box(h, "STYLEDBOX001", page: Fixtures.page2)
        XCTAssertEqual(styled.style.defaults.size, 24)
        XCTAssertEqual(styled.style.padding, 10)
        XCTAssertEqual(styled.text.paragraphs[0].align, .right)

        try await h.run("text.saveDefaultStyle", ["name": "Definition", "style": ["background": "#FFF3B0FF"]])
        XCTAssertEqual(TextSettings.savedNames(h.app.settings), ["Definition"])
        try await h.run("text.createBox", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [72, 300],
                                           "style": "Definition", "id": "NAMEDBOX0001"])
        XCTAssertEqual(try box(h, "NAMEDBOX0001", page: Fixtures.page2).style.background, RGBA(hex: "#FFF3B0FF"))

        try await h.run("text.createBox", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [72, 500],
                                           "style": "heading", "id": "HEADINGBOX01"])
        let heading = try box(h, "HEADINGBOX01", page: Fixtures.page2)
        XCTAssertEqual(heading.style.defaults.bold, true)
        XCTAssertEqual(heading.style.defaults.size, 22)
        XCTAssertTrue(h.app.settings.undeclaredNames.isEmpty)
    }

    func testTapAtWithoutACanvasIsNotHandled() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let out = try await h.run("text.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [100, 410],
                                                 "gesture": "doubleTap"])
        XCTAssertEqual(out["handled"]?.boolValue, false)
    }

    func testToolIsStickyOnlyWhenPinned() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let tool = TextTool(settings: h.app.settings)
        XCTAssertFalse(tool.isSticky)
        try await h.run(CommandIDs.settingsSet, ["name": "text.pinned", "value": true])
        XCTAssertTrue(tool.isSticky)
        XCTAssertEqual(tool.inputMode, .taps)
    }

    // MARK: Editing overlay

    func testTypingInANewBoxCreatesItOnTheFirstCommit() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let host = FakeCanvasHost(h)
        let editor = TextBoxEditor(host: host)
        editor.attach(to: host)
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        XCTAssertTrue(editor.isEditing)
        let ref = try XCTUnwrap(editor.editingRef)
        guard case let .item(_, page, id)? = NodeRef(ref) else { return XCTFail("not an item ref: \(ref)") }
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: page, id: id), "nothing is created before typing")

        let tv = try XCTUnwrap(editor.editingTextView)
        tv.attributedText = NSAttributedString(string: "Hello", attributes: tv.typingAttributes)
        editor.commitNow()
        await editor.flush()
        XCTAssertEqual(try box(h, id, page: page).text.plainText, "Hello")

        tv.attributedText = NSAttributedString(string: "Hello there", attributes: tv.typingAttributes)
        editor.endEditing()
        await editor.flush()
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(try box(h, id, page: page).text.plainText, "Hello there")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "the editing session is one undo step")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: page, id: id),
                             "one undo removes the new box with everything typed in it")
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try box(h, id, page: page).text.plainText, "Hello there")
        editor.detach(from: host)
    }

    func testAnEditingSessionIsOneUndoStep() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let before = try h.snapshot()
        let (host, editor) = self.editor(h)
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        let tv = try XCTUnwrap(editor.editingTextView)
        tv.attributedText = NSAttributedString(string: "One", attributes: tv.typingAttributes)
        editor.commitNow()
        await editor.flush()
        tv.attributedText = NSAttributedString(string: "One two", attributes: tv.typingAttributes)
        editor.commitNow()
        await editor.flush()
        editor.applyParagraph(align: .center)
        editor.applyBoxStyle(["cornerRadius": 8])
        await editor.flush()
        tv.attributedText = NSAttributedString(string: "One two three", attributes: tv.typingAttributes)
        editor.endEditing()
        await editor.flush()
        XCTAssertEqual(try box(h).text.plainText, "One two three")
        XCTAssertEqual(try box(h).style.cornerRadius, 8)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "every write of the session joins one undo step")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before, "and one undo takes all of it back")
        editor.detach(from: host)
    }

    func testConsecutiveEditsOfOneBoxUndoOneByOne() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run(CommandIDs.textSetText, ["ref": .string(textRef), "text": "first"])
        try await h.run(CommandIDs.textFormat, ["ref": .string(textRef), "attrs": ["bold": true], "range": [0, 5]])
        try await h.run(CommandIDs.textSetText, ["ref": .string(textRef), "text": "second"])
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try box(h).text.plainText, "first")
        XCTAssertEqual(try box(h).text.paragraphs[0].runs.first?.attrs.bold, true)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertNil(try box(h).text.paragraphs[0].runs.first?.attrs.bold, "the older step on the same box undoes too")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try box(h).text.plainText, "Hello Nib")
    }

    func testAnAbandonedNewBoxLeavesNothing() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let host = FakeCanvasHost(h)
        let editor = TextBoxEditor(host: host)
        editor.attach(to: host)
        let before = try h.snapshot()
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        editor.endEditing()
        await editor.flush()
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        editor.detach(from: host)
    }

    func testEditingAnExistingBoxCommitsWithSetText() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let host = FakeCanvasHost(h)
        let editor = TextBoxEditor(host: host)
        editor.attach(to: host)
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: Point(80, 410)))
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.textID], "the page hides the box while the overlay shows it")
        let tv = try XCTUnwrap(editor.editingTextView)
        XCTAssertEqual(tv.text, "Hello Nib")
        editor.applyParagraph(list: .bullet)
        await editor.flush()
        XCTAssertEqual(try box(h).text.paragraphs[0].list, .bullet)
        XCTAssertEqual(tv.text, "\u{2022} Hello Nib")
        editor.endEditing()
        await editor.flush()
        XCTAssertNil(host.hidden[Fixtures.page1])
        editor.detach(from: host)
    }

    func testEmptyingABoxDeletesItOrKeepsItEmpty() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let host = FakeCanvasHost(h)
        let editor = TextBoxEditor(host: host)
        editor.attach(to: host)
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        editor.editingTextView?.attributedText = NSAttributedString(string: "")
        editor.endEditing()
        await editor.flush()
        // item.delete belongs to another feature; without it the box stays, emptied.
        XCTAssertEqual(try box(h).text.plainText, "")
        editor.detach(from: host)
    }

    func testURLDetectionFindsUnlinkedAddresses() {
        XCTAssertTrue(TextBoxEditor.hasUnlinkedURL(RichText(plain: "Notes at https://example.com today")))
        XCTAssertFalse(TextBoxEditor.hasUnlinkedURL(RichText(plain: "No links here")))
        var linked = TextAttributes()
        linked.link = TextLink(url: "https://example.com")
        let done = RichText(paragraphs: [Paragraph(runs: [TextRun("See "), TextRun("https://example.com", linked)])])
        XCTAssertFalse(TextBoxEditor.hasUnlinkedURL(done))
    }

    func testLinksAreDetectedOnlyWhenTheTextChanged() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let calls = AutodetectCalls()
        h.app.commands.register(CommandDescriptor(
            id: "link.autodetect", title: "Detect Links", summary: "Test double for the links feature's detection.",
            params: .obj(["ref": .ref], required: ["ref"]), effect: .edit)) { json, _ in
            calls.refs.append(json["ref"]?.stringValue ?? "")
            return .object([:])
        }
        try await h.run("text.setText", ["ref": .string(textRef), "text": "Notes at https://example.com"])
        let (host, editor) = self.editor(h)
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        editor.endEditing()
        await editor.flush()
        XCTAssertEqual(calls.refs, [], "opening and closing a box keeps a link the user removed removed")

        item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        let tv = try XCTUnwrap(editor.editingTextView)
        tv.textStorage.append(NSAttributedString(string: " today", attributes: tv.typingAttributes))
        editor.endEditing()
        await editor.flush()
        XCTAssertEqual(calls.refs, [textRef], "typed text is checked for URLs")
        editor.detach(from: host)
    }

    // MARK: Saved styles

    func testTheDefaultStyleIsTheSharedTextBoxStyleSetting() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        XCTAssertEqual(h.app.settings.descriptor(NibSettings.defaultTextStyle.name)?.owner, "text")
        let out = try await h.run(CommandIDs.textSaveDefaultStyle,
                                  ["style": ["padding": 10, "align": "right", "lineSpacing": 4, "defaults": ["size": 24]]])
        XCTAssertEqual(out["setting"]?.stringValue, NibSettings.defaultTextStyle.name)
        // Paste and Match Style (F014) and page text (F028) read the typed key.
        let shared = h.app.settings.get(NibSettings.defaultTextStyle)
        XCTAssertEqual(shared.padding, 10)
        XCTAssertEqual(shared.align, .right)
        XCTAssertEqual(shared.lineSpacing, 4)
        XCTAssertEqual(shared.defaults.size, 24)
        XCTAssertEqual(TextStyles.defaultStyle(h.app.settings).align, .right)

        // A style saved before contracts-v2 (explicit nulls, "natural" and 0 for unset) reads back the same way.
        h.app.settings.setJSON(NibSettings.defaultTextStyle.name, try JSONValue.parse(
            #"{"background": null, "borderColor": null, "padding": 6, "align": "natural", "lineSpacing": 0, "defaults": {"font": "Georgia", "size": null}}"#))
        let legacy = TextStyles.defaultStyle(h.app.settings)
        XCTAssertNil(legacy.align)
        XCTAssertNil(legacy.lineSpacing)
        XCTAssertNil(legacy.box.background)
        XCTAssertEqual(legacy.box.padding, 6)
        XCTAssertEqual(legacy.box.defaults.font, "Georgia")
        XCTAssertEqual(try SavedTextStyle(json: legacy.json), legacy)
    }

    func testSavedStylesClearOptionalFields() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.saveDefaultStyle", ["style": ["background": "#FFF3B0FF", "lineSpacing": 4,
                                                            "defaults": ["font": "Georgia"]]])
        XCTAssertNotNil(TextStyles.defaultStyle(h.app.settings).box.background)
        try await h.run("text.saveDefaultStyle", ["style": ["background": .null, "lineSpacing": 0]])
        var s = TextStyles.defaultStyle(h.app.settings)
        XCTAssertNil(s.box.background)
        XCTAssertNil(s.lineSpacing)
        XCTAssertEqual(s.box.defaults.font, "Georgia", "fields left out are kept")

        // A whole style (Set as Default from a box with no fill, Auto spacing and the default font) replaces them all.
        try await h.run("text.saveDefaultStyle", ["style": ["background": "#FFF3B0FF", "lineSpacing": 4]])
        try await h.run("text.saveDefaultStyle", ["style": SavedTextStyle(box: TextBoxStyle()).json])
        s = TextStyles.defaultStyle(h.app.settings)
        XCTAssertNil(s.box.background)
        XCTAssertNil(s.lineSpacing)
        XCTAssertNil(s.box.defaults.font)
        XCTAssertEqual(try SavedTextStyle(json: s.json), s, "the explicit form reads back as the same style")
    }

    func testFormatModelClearsTheDefaultFillAndSavesWholeStyles() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.saveDefaultStyle", ["style": ["background": "#FFF3B0FF", "lineSpacing": 4,
                                                            "defaults": ["font": "Georgia"]]])
        let defaults = TextFormatModel(app: h.app, session: h.session, kind: .defaults)
        defaults.setBox(["background": .null])
        defaults.setLineSpacing(.automatic)
        await defaults.flush()
        var s = TextStyles.defaultStyle(h.app.settings)
        XCTAssertNil(s.box.background, "Remove Fill in the text tool settings sticks")
        XCTAssertNil(s.lineSpacing, "so does Auto line spacing")
        XCTAssertEqual(s.box.defaults.font, "Georgia")

        // Styles saved from a box with no fill, Auto spacing and the default font do not inherit the default's.
        try await h.run("text.saveDefaultStyle", ["style": ["background": "#FFF3B0FF", "lineSpacing": 4]])
        let selected = TextFormatModel(app: h.app, session: h.session,
                                       kind: .items(doc: Fixtures.docID, page: Fixtures.page1, ids: [Fixtures.textID]))
        selected.saveStyle(named: "Plain")
        selected.saveAsDefault()
        await selected.flush()
        let named = try XCTUnwrap(TextStyles.named("Plain", h.app.settings))
        XCTAssertNil(named.box.background)
        XCTAssertNil(named.lineSpacing)
        XCTAssertNil(named.box.defaults.font)
        s = TextStyles.defaultStyle(h.app.settings)
        XCTAssertNil(s.box.background)
        XCTAssertNil(s.lineSpacing)
        XCTAssertNil(s.box.defaults.font)
    }

    func testANewBoxKeepsNoFillPickedBeforeItsFirstCommit() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        try await h.run("text.saveDefaultStyle", ["style": ["background": "#FFF3B0FF"]])
        let (host, editor) = self.editor(h)
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        XCTAssertNotNil(editor.editingState?.box.style.background)
        editor.applyBoxStyle(["background": .null])
        let (page, id) = try editingID(editor)
        let tv = try XCTUnwrap(editor.editingTextView)
        tv.attributedText = NSAttributedString(string: "Plain", attributes: tv.typingAttributes)
        editor.endEditing()
        await editor.flush()
        XCTAssertNil(try box(h, id, page: page).style.background, "the page shows what the overlay showed")
        editor.detach(from: host)
    }

    func testPresetsReachStickyNotesAndMixedSelections() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let before = try h.snapshot()
        let model = TextFormatModel(app: h.app, session: h.session,
                                    kind: .items(doc: Fixtures.docID, page: Fixtures.page1, ids: [Fixtures.stickyID, Fixtures.textID]))
        XCTAssertNotNil(model.state.box, "the Text Box section shows when a text box is among the selection")
        model.applyPreset("heading")
        await model.flush()
        let sticky = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).sticky)
        XCTAssertEqual(sticky.text.plainText, "Remember")
        XCTAssertFalse(sticky.text.paragraphs[0].runs.isEmpty)
        XCTAssertTrue(sticky.text.paragraphs[0].runs.allSatisfy { $0.attrs.size == 22 && $0.attrs.bold == true })
        let b = try box(h)
        XCTAssertEqual(b.style.defaults.size, 22)
        XCTAssertEqual(b.style.defaults.bold, true)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "one undo step for the whole selection")
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)

        // Box-only settings go to the text boxes and leave sticky notes alone (no error).
        model.setBox(["cornerRadius": 8])
        await model.flush()
        XCTAssertEqual(try box(h).style.cornerRadius, 8)
        let stickyOnly = TextFormatModel(app: h.app, session: h.session,
                                         kind: .items(doc: Fixtures.docID, page: Fixtures.page1, ids: [Fixtures.stickyID]))
        XCTAssertNil(stickyOnly.state.box)
    }

    // MARK: Untrusted input

    func testRangesNeverSplitACharacter() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let emoji = "\u{1F600}abc"
        try await h.run("text.setText", ["ref": .string(textRef), "text": .string(emoji)])
        try await h.run("text.format", ["ref": .string(textRef), "attrs": ["bold": true], "range": [1, 1]])
        let runs = try box(h).text.paragraphs[0].runs
        XCTAssertEqual(try box(h).text.plainText, emoji)
        XCTAssertEqual(runs.map { $0.text }, ["\u{1F600}", "abc"])
        XCTAssertEqual(runs.first?.attrs.bold, true)
        try await h.run("text.setParagraph", ["ref": .string(textRef), "align": "center", "range": [1, 0]])
        XCTAssertEqual(try box(h).text.plainText, emoji)
        XCTAssertEqual(try box(h).text.paragraphs[0].align, .center)
    }

    func testSetTextSanitisesUntrustedRichText() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let text: JSONValue = ["paragraphs": [["runs": [["text": "tiny", "attrs": ["size": -5, "baseline": 7,
                                                                                    "link": ["url": "nibasset:x.png"]]]],
                                               "indent": 99, "lineSpacing": -3]]]
        try await h.run("text.setText", ["ref": .string(textRef), "text": text])
        let b = try box(h)
        let p = b.text.paragraphs[0]
        XCTAssertEqual(p.runs[0].attrs.size, 1)
        XCTAssertEqual(p.runs[0].attrs.baseline, 1)
        XCTAssertNil(p.runs[0].attrs.link)
        XCTAssertEqual(p.indent, AutoList.maxIndent)
        XCTAssertNil(p.lineSpacing)
        XCTAssertLessThan(b.frame.h, 100)
    }

    // MARK: Canvas behaviour

    func testTapAtStartsEditingOnALiveCanvas() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        let page = "page:FIXTUREDOC01/FIXTUREPG001"
        var out = try await h.run("text.tapAt", ["page": .string(page), "point": [100, 410]])
        XCTAssertEqual(out["handled"]?.boolValue, false, "a pen tap on an unselected box is left to the pen")
        XCTAssertFalse(editor.isEditing)

        out = try await h.run("text.tapAt", ["page": .string(page), "point": [100, 410], "gesture": "doubleTap"])
        XCTAssertEqual(out["handled"]?.boolValue, true)
        XCTAssertEqual(out["ref"]?.stringValue, textRef)
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.editingRef, textRef)
        XCTAssertTrue(h.session.isEditingText)
        XCTAssertEqual(TextToolSettingsView.identity(h.session), textRef, "the tool settings follow the box being edited")
        editor.endEditing()
        await editor.flush()
        XCTAssertFalse(h.session.isEditingText)
        XCTAssertEqual(TextToolSettingsView.identity(h.session), "defaults")

        h.session.tool = TextTool.toolID
        out = try await h.run("text.tapAt", ["page": .string(page), "point": [100, 410]])
        XCTAssertEqual(out["handled"]?.boolValue, true, "with the text tool a tap on a box edits it")
        editor.endEditing()
        await editor.flush()
        editor.detach(from: host)
    }

    func testTheTextToolGivesThePreviousToolBackUnlessPinned() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        h.session.tool = "highlighter"
        h.session.tool = TextTool.toolID
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        var tv = try XCTUnwrap(editor.editingTextView)
        tv.attributedText = NSAttributedString(string: "Note", attributes: tv.typingAttributes)
        editor.endEditing()
        await editor.flush()
        XCTAssertEqual(h.session.tool, "highlighter", "the text tool is not sticky (T-035)")

        try await h.run(CommandIDs.settingsSet, ["name": "text.pinned", "value": true])
        h.session.tool = TextTool.toolID
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 300))
        tv = try XCTUnwrap(editor.editingTextView)
        tv.attributedText = NSAttributedString(string: "Another", attributes: tv.typingAttributes)
        editor.endEditing()
        await editor.flush()
        XCTAssertEqual(h.session.tool, TextTool.toolID, "Pin Text Tool keeps it selected")
        editor.detach(from: host)
    }

    func testTypingDrivesAutoLists() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        let (page, id) = try editingID(editor)
        let tv = try XCTUnwrap(editor.editingTextView)

        XCTAssertTrue(typeText("1", into: tv, editor))
        XCTAssertTrue(typeText(".", into: tv, editor))
        XCTAssertFalse(typeText(" ", into: tv, editor), "\"1. \" starts a numbered list")
        XCTAssertEqual(tv.text, "1. ")
        XCTAssertEqual(editor.currentRichText().paragraphs.map { $0.list }, [.number])

        XCTAssertTrue(typeText("a", into: tv, editor))
        XCTAssertFalse(typeText("\n", into: tv, editor), "Return continues the list")
        XCTAssertEqual(tv.text, "1. a\n2. ")
        XCTAssertEqual(editor.currentRichText().paragraphs.map { $0.list }, [.number, .number])

        XCTAssertFalse(typeText("\n", into: tv, editor), "Return on an empty item ends the list")
        XCTAssertEqual(tv.text, "1. a\n")
        XCTAssertEqual(editor.currentRichText().paragraphs.map { $0.list }, [.number, .plain])

        tv.selectedRange = NSRange(location: 4, length: 0)
        XCTAssertFalse(typeText("\t", into: tv, editor), "Tab indents a list item")
        XCTAssertEqual(editor.currentRichText().paragraphs.map { $0.indent }, [1, 0])
        XCTAssertEqual(tv.text, "a. a\n", "nested items count a. b. c.")

        XCTAssertFalse(editor.textView(tv, shouldChangeTextIn: NSRange(location: 2, length: 1), replacementText: ""),
                       "Backspace on a marker is handled by the editor")
        let text = editor.currentRichText()
        XCTAssertEqual(text.paragraphs.map { $0.list }, [.plain, .plain])
        XCTAssertEqual(text.paragraphs[0].indent, 1, "the indent stays")
        XCTAssertEqual(tv.text, "a\n")

        editor.endEditing()
        await editor.flush()
        let stored = try box(h, id, page: page).text
        XCTAssertEqual(stored.paragraphs.map { $0.plainText }, ["a", ""])
        XCTAssertEqual(stored.paragraphs[0].indent, 1)
        editor.detach(from: host)
    }

    func testTypingAfterInlineImageDoesNotInheritTheAttachment() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        let tv = try XCTUnwrap(editor.editingTextView)
        let image = NSTextAttachment()
        tv.attributedText = NSAttributedString(attachment: image)
        tv.selectedRange = NSRange(location: 1, length: 0)
        tv.typingAttributes[.attachment] = image
        editor.textViewDidChangeSelection(tv)
        XCTAssertNil(tv.typingAttributes[.attachment])
        typeText(" plain", into: tv, editor)
        XCTAssertEqual(tv.text, "\u{FFFC} plain")
        XCTAssertNotNil(tv.textStorage.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertNil(tv.textStorage.attribute(.attachment, at: 1, effectiveRange: nil))
        editor.detach(from: host)
        await editor.flush()
    }

    func testTypingAfterExitingNestedListRemainsPlain() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        let tv = try XCTUnwrap(editor.editingTextView)
        for character in "- first\n\tnested\n" { typeText(String(character), into: tv, editor) }
        XCTAssertTrue(editor.indent(outdent: true))
        for character in "last\n\nplain" { typeText(String(character), into: tv, editor) }
        let paragraphs = editor.currentRichText().paragraphs
        XCTAssertEqual(paragraphs.map(\.plainText), ["first", "nested", "last", "plain"])
        XCTAssertEqual(paragraphs.map(\.list), [.bullet, .bullet, .bullet, .plain])
        XCTAssertEqual(paragraphs.map(\.indent), [0, 1, 0, 0])
        editor.detach(from: host)
        await editor.flush()
    }

    func testTheSessionFollowsTheTextBeingEdited() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        try await h.run(CommandIDs.textSetParagraph, ["ref": .string(textRef), "list": "bullet"])
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        let tv = try XCTUnwrap(editor.editingTextView)
        XCTAssertEqual(h.session.editingTextRef, textRef)
        XCTAssertEqual(tv.text, "\u{2022} Hello Nib")
        tv.selectedRange = NSRange(location: 2, length: 5)
        editor.textViewDidChangeSelection(tv)
        XCTAssertEqual(h.session.editingTextRange, [0, 5], "plain-text units, list marker excluded")
        editor.endEditing()
        await editor.flush()
        XCTAssertNil(h.session.editingTextRef)
        XCTAssertNil(h.session.editingTextRange)

        // A box started with the tool has no ref to publish until it exists.
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        XCTAssertNil(h.session.editingTextRef)
        let newTV = try XCTUnwrap(editor.editingTextView)
        newTV.attributedText = NSAttributedString(string: "New", attributes: newTV.typingAttributes)
        editor.commitNow()
        await editor.flush()
        XCTAssertEqual(h.session.editingTextRef, editor.editingRef)
        editor.endEditing()
        await editor.flush()
        editor.detach(from: host)
    }

    func testSelectedTextOffersTextSelectionMenuEntries() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let calls = Calls()
        h.app.commands.register(CommandDescriptor(
            id: "test.shout", title: "Shout", summary: "Test double: upper-cases a text box.",
            params: .obj(["ref": .ref, "range": .arr(.int())], required: ["ref"]), effect: .edit)) { json, ctx in
            calls.params.append(json)
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { return .object([:]) }
            try ctx.mutate { tx in
                var it = try tx.item(doc, page: page, id: id)
                guard var text = it.text?.text else { return }
                for i in text.paragraphs.indices {
                    for j in text.paragraphs[i].runs.indices {
                        text.paragraphs[i].runs[j].text = text.paragraphs[i].runs[j].text.uppercased()
                    }
                }
                it.text?.text = text
                _ = try tx.put(it, doc: doc, page: page)
            }
            return .object([:])
        }
        var offered: (ref: String?, range: [Int]?)?
        h.app.ui.menus.register(MenuItemDescriptor(
            id: "test.shout", title: "Shout", location: .textSelection, order: 1, owner: "test", command: "test.shout",
            params: { ctx in
                ["ref": .string(ctx.ref ?? ""), "range": .array((ctx.textRange ?? []).map { .number(Double($0)) })]
            },
            isVisible: { ctx in
                offered = (ctx.ref, ctx.textRange)
                return ctx.itemKinds == [.text] && ctx.textRange != nil
            }))
        try await h.run(CommandIDs.textSetParagraph, ["ref": .string(textRef), "list": "bullet"])
        let (host, editor) = self.editor(h)
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        let tv = try XCTUnwrap(editor.editingTextView)
        XCTAssertNil(editor.textView(tv, editMenuForTextIn: NSRange(location: 4, length: 0), suggestedActions: []),
                     "a caret keeps the system menu")
        let menu = try XCTUnwrap(editor.textView(tv, editMenuForTextIn: NSRange(location: 2, length: 5), suggestedActions: []))
        XCTAssertEqual(menu.children.map { $0.title }, ["Shout"])
        XCTAssertEqual(offered?.ref, textRef)
        XCTAssertEqual(offered?.range, [0, 5], "the selection in plain-text units, list marker excluded")

        // Typing not saved yet is saved before the entry runs; the entry's change shows in the text view.
        tv.textStorage.append(NSAttributedString(string: "!", attributes: tv.typingAttributes))
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1,
                                  itemKinds: [.text], ref: textRef, textRange: [0, 5])
        let entry = try XCTUnwrap(h.app.ui.menus.get("test.shout"))
        editor.runMenuEntry(entry, context)
        await editor.flush()
        XCTAssertEqual(calls.params.first?["ref"]?.stringValue, textRef)
        XCTAssertEqual(calls.params.first?["range"], [0, 5])
        XCTAssertEqual(try box(h).text.plainText, "HELLO NIB!")
        XCTAssertEqual(tv.text, "\u{2022} HELLO NIB!", "the editor follows a change made for it")
        editor.endEditing()
        await editor.flush()
        editor.detach(from: host)
    }

    func testMoreBudsTheInspectorFromTheWindowsFloatingHost() throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let (host, editor) = self.editor(h)
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        let st = try XCTUnwrap(editor.editingState)
        let more = UIButton(frame: CGRect(x: 900, y: 0, width: 44, height: 44))
        editor.presentInspector(from: more)
        XCTAssertEqual(floating.presented, [TextPopoverIDs.popover])
        XCTAssertEqual(floating.anchors[TextPopoverIDs.source], more.bounds)
        XCTAssertTrue(st.popover.isPresented)
        XCTAssertGreaterThanOrEqual(st.popover.contentHeight, TextFormatPopover.minimumHeight)
        XCTAssertLessThan(st.popover.viewportHeight, floating.offset,
                          "The inspector's usable viewport must end above its keyboard accessory anchor")
        st.popover.isPresented = false   // a tap outside
        editor.presentInspector(from: more)
        XCTAssertEqual(floating.presented, [TextPopoverIDs.popover], "the popover is presented once per editing session")
        XCTAssertTrue(st.popover.isPresented)
        editor.endEditing()
        XCTAssertEqual(floating.presented, [], "finishing takes the popover away")
        XCTAssertNil(floating.anchors[TextPopoverIDs.source])

        // No room above the keyboard: the system popover takes over.
        floating.offset = 100
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        editor.presentInspector(from: more)
        XCTAssertEqual(floating.presented, [])
        XCTAssertEqual(editor.editingState?.popover.isPresented, false)
        editor.endEditing()
        editor.detach(from: host)
        withExtendedLifetime(floating) {}
    }

    func testParagraphButtonsOpenAboveKeyboardAndChoicesFormatTheSelection() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let (host, editor) = self.editor(h)
        defer { editor.detach(from: host) }
        try await h.run(CommandIDs.textSetText, ["ref": .string(textRef), "text": "first\nsecond\nuntouched"])
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        XCTAssertTrue(editor.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, item: item, caretAt: nil))
        let tv = try XCTUnwrap(editor.editingTextView)
        tv.selectedRange = NSRange(location: 0, length: 12)
        editor.textViewDidChangeSelection(tv)
        let bar = try XCTUnwrap(tv.inputAccessoryView as? TextKeyboardBar)
        let state = try XCTUnwrap(editor.editingState)
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        for (title, panel, choice) in [
            ("Alignment", TextFormatPanel.alignment, TextParagraphChoice.alignment(.center)),
            ("Line Spacing", .lineSpacing, .spacing(.wide)),
            ("List", .list, .list(.numberParen))
        ] {
            let button = try XCTUnwrap(buttons(bar).first { $0.accessibilityLabel == title })
            XCTAssertFalse(button.showsMenuAsPrimaryAction, "An accessory menu must not open beneath the keyboard")
            button.sendActions(for: .primaryActionTriggered)
            XCTAssertTrue(state.popover.isPresented)
            XCTAssertEqual(state.popover.panel, panel)
            XCTAssertTrue(panel.choices.contains(choice))
            choice.apply(to: state.model)
            XCTAssertTrue(choice.isSelected(in: state.model.state))
            state.popover.isPresented = false
        }
        let styleButton = try XCTUnwrap(buttons(bar).first { $0.accessibilityLabel == "Text Style" })
        XCTAssertFalse(styleButton.showsMenuAsPrimaryAction)
        styleButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(state.popover.isPresented)
        XCTAssertEqual(state.popover.panel, .styles)
        state.popover.isPresented = false
        state.model.indent(1)
        editor.endEditing()
        await editor.flush()
        let paragraphs = try box(h).text.paragraphs
        for paragraph in paragraphs.prefix(2) {
            XCTAssertEqual(paragraph.align, .center)
            XCTAssertEqual(paragraph.list, .numberParen)
            XCTAssertEqual(paragraph.indent, 1)
            XCTAssertGreaterThan(paragraph.lineSpacing ?? 0, 0)
        }
        XCTAssertEqual(paragraphs[2].align, .natural)
        XCTAssertEqual(paragraphs[2].list, .plain)
        XCTAssertEqual(paragraphs[2].indent, 0)
    }

    func testStyleNameAlertHasAPersistentAccessibleName() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let model = TextFormatModel(app: h.app, session: h.session, kind: .defaults)
        let controller = UIHostingController(rootView: TextFormatInspector(model: model, naming: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        func presentedAlert(_ controller: UIViewController) -> UIAlertController? {
            if let alert = controller as? UIAlertController { return alert }
            if let presented = controller.presentedViewController, let alert = presentedAlert(presented) { return alert }
            return controller.children.lazy.compactMap { presentedAlert($0) }.first
        }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where presentedAlert(controller) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let alert = try XCTUnwrap(presentedAlert(controller))
        let field = try XCTUnwrap(alert.textFields?.first)
        let save = try XCTUnwrap(alert.actions.first { $0.title == "Save" })
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(field.accessibilityLabel, "Name")
        XCTAssertEqual(field.accessibilityIdentifier, "text.style.name")
        XCTAssertTrue(field.isEnabled)
        field.text = "Lab Caption"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(field.accessibilityLabel, "Name", "The name remains available after the placeholder disappears")
        XCTAssertTrue(save.isEnabled)
        field.text = "invalid/style"
        field.sendActions(for: .editingChanged)
        XCTAssertFalse(save.isEnabled, "The native prompt keeps the style-name validation")
    }

    func testNamedStyleFromEditingBecomesTheNextBoxesDefault() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let (host, editor) = self.editor(h)
        defer { editor.detach(from: host) }
        editor.beginNewBox(page: Fixtures.page2, at: Point(100, 100))
        let tv = try XCTUnwrap(editor.editingTextView)
        typeText("First", into: tv, editor)
        tv.selectedRange = NSRange(location: 0, length: 5)
        editor.textViewDidChangeSelection(tv)
        let model = try XCTUnwrap(editor.editingState?.model)
        model.stepSize(1)
        let size = model.state.size
        model.saveStyle(named: "Lab Caption")
        await model.flush()
        XCTAssertTrue(model.styleNames.contains("Lab Caption"))
        model.applyNamed("Lab Caption")
        model.saveAsDefault()
        await model.flush()
        editor.endEditing()
        await editor.flush()
        let saved = try XCTUnwrap(TextStyles.named("Lab Caption", h.app.settings))
        XCTAssertEqual(saved.box.defaults.size, size)
        XCTAssertEqual(TextStyles.defaultStyle(h.app.settings), saved)

        editor.beginNewBox(page: Fixtures.page2, at: Point(200, 200))
        let next = try XCTUnwrap(editor.editingTextView)
        typeText("Second", into: next, editor)
        editor.commitNow()
        await editor.flush()
        let (page, id) = try editingID(editor)
        editor.endEditing()
        await editor.flush()
        let created = try box(h, id, page: page)
        XCTAssertEqual(created.text.plainText, "Second")
        XCTAssertEqual(created.style, saved.box)
        XCTAssertEqual(TextLayout.resolved(RichTextEdit.merged(created.style.defaults,
                       created.text.paragraphs[0].runs[0].attrs)).size, size)
    }

    func testFormatPopoverHasOneVerticalScrollOwnerForBoxControls() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        let model = TextFormatModel(app: h.app, session: h.session, kind: .defaults)
        let state = TextPopoverState()
        state.isPresented = true
        let controller = UIHostingController(rootView: TextFormatPopover(state: state, model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<5 {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        func scrolls(_ view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrolls)
        }
        let vertical = scrolls(controller.view).filter { $0.bounds.height > 100 && $0.bounds.width > 200 }
        XCTAssertEqual(vertical.count, 1, "The panel must scroll the whole inspector, including its box controls")
        let scroll = try XCTUnwrap(vertical.first)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        model.saveStyle(named: "Lab Caption")
        await model.flush()
        for _ in 0..<5 {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let styles = try XCTUnwrap(scrolls(controller.view).first {
            $0.bounds.height < 100 && $0.contentSize.width > $0.bounds.width
        })
        XCTAssertGreaterThan(styles.contentOffset.x, 0, "Saving reveals the new style beyond the built-in presets")
        XCTAssertEqual(styles.contentOffset.x + styles.bounds.width, styles.contentSize.width, accuracy: 1)
        let bottom = scroll.contentSize.height - scroll.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
    }

    func testInspectorIdentityFollowsTheSelection() {
        let a = TextItemsInspector.identity(doc: Fixtures.docID, page: Fixtures.page1, ids: [Fixtures.textID])
        let b = TextItemsInspector.identity(doc: Fixtures.docID, page: Fixtures.page1, ids: [Fixtures.stickyID])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, TextItemsInspector.identity(doc: Fixtures.docID, page: Fixtures.page1, ids: [Fixtures.textID]))
    }

    // MARK: Layout and drawing

    func testRichTextSurvivesTheEditorRoundTrip() {
        var bold = TextAttributes()
        bold.bold = true
        var red = TextAttributes()
        red.color = RGBA(nibHex: NibInk.vermilion.hex)
        red.size = 24
        let text = RichText(paragraphs: [
            Paragraph(runs: [TextRun("Plain "), TextRun("bold", bold)]),
            Paragraph(runs: [TextRun("item", red)], list: .number),
            Paragraph(runs: [TextRun("nested")], list: .bullet, indent: 1),
            Paragraph(runs: [TextRun("done")], list: .todo, checked: true),
            Paragraph(runs: [], align: .center)
        ])
        var base = TextAttributes()
        base.font = "Georgia"
        let s = TextLayout.attributed(text, base: base) { _, _ in nil }
        XCTAssertTrue(s.string.contains("1. item"))
        XCTAssertTrue(s.string.contains("\u{25E6} nested"))
        XCTAssertTrue(s.string.contains("\u{2611} done"))
        let back = TextLayout.richText(from: s, base: base) { _ in nil }
        XCTAssertEqual(back, text)
        XCTAssertEqual(TextLayout.modelOffset(s, view: s.length), AutoList.length(text))
    }

    func testFontsAndTraitsTheDeviceCannotShowSurviveEditing() throws {
        var missing = TextAttributes()
        missing.font = "NoSuchFont"
        var missingBold = missing
        missingBold.bold = true
        var noteworthyItalic = TextAttributes()
        noteworthyItalic.font = "Noteworthy"
        noteworthyItalic.italic = true
        let text = RichText(paragraphs: [
            Paragraph(runs: [TextRun("Custom ", missing), TextRun("bold ", missingBold), TextRun("noted", noteworthyItalic)]),
            Paragraph(runs: [TextRun("next", noteworthyItalic)], list: .bullet)
        ])
        let base = TextAttributes()
        let s = TextLayout.attributed(text, base: base) { _, _ in nil }
        XCTAssertEqual(s.attribute(.nibModelFont, at: 0, effectiveRange: nil) as? String, "NoSuchFont",
                       "the model font rides on the bridge's key")
        XCTAssertEqual(TextLayout.richText(from: s, base: base) { _ in nil }, text,
                       "an uninstalled family and a family without italics keep their formatting")

        // Typing in such a run keeps it: the typing attributes carry the model font.
        XCTAssertEqual(TextLayout.relativeAttributes(TextLayout.characterAttributes(noteworthyItalic, base: base), base: base),
                       noteworthyItalic)

        // A face changed outside the model (a system format action) is read from the font.
        var georgia = TextAttributes()
        georgia.font = "Georgia"
        let serif = TextLayout.attributed(RichText(paragraphs: [Paragraph(runs: [TextRun("serif", georgia)])]), base: base) { _, _ in nil }
        let boldFace = try XCTUnwrap(UIFontDescriptor(fontAttributes: [.family: "Georgia"]).withSymbolicTraits(.traitBold))
        serif.addAttribute(.font, value: UIFont(descriptor: boldFace, size: 17), range: NSRange(location: 0, length: serif.length))
        let run = try XCTUnwrap(TextLayout.richText(from: serif, base: base) { _ in nil }.paragraphs.first?.runs.first)
        XCTAssertEqual(run.attrs.font, "Georgia")
        XCTAssertEqual(run.attrs.bold, true)
    }

    func testTextLayoutIsPublishedForLinksAndEditors() throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        XCTAssertEqual(h.app.content.textLayouts.get(ItemKind.text.rawValue)?.owner, "text")
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        item.text?.frame.rotation = 0.5
        let box = try XCTUnwrap(item.text)
        let info = try XCTUnwrap(h.app.content.textLayout(for: item))
        let p = box.style.padding
        XCTAssertEqual(info.container, Frame(x: box.frame.x + p, y: box.frame.y + p, w: box.frame.w - 2 * p,
                                             h: box.frame.h - 2 * p, rotation: 0.5))
        XCTAssertEqual(info.base, box.style.defaults)
        XCTAssertFalse(info.centredVertically)
        XCTAssertEqual(TextLayout.layout(NSAttributedString(string: "x"), width: 100).container.lineFragmentPadding,
                       CGFloat(TextLayoutInfo.lineFragmentPadding))
    }

    func testFullPageTextIsHitOnlyWhereItsTextIs() async throws {
        let h = Harness(features: [FeatTextBoxFeature.self])
        var page = Item.makeText(TextBoxItem(frame: Frame(x: 0, y: 0, w: 595, h: 842), text: RichText(plain: "Title"),
                                             style: TextBoxStyle(padding: 0, autoGrow: false, fullPage: true)))
        page.locked = true
        let inserted = try await h.insert([page], page: Fixtures.page2)
        let item = try XCTUnwrap(inserted.first)
        let hit = try XCTUnwrap(TextBoxDrawer().hitBounds(item))
        XCTAssertLessThan(hit.width, 200)
        XCTAssertLessThan(hit.height, 40)
        XCTAssertEqual(h.app.content.hitBounds(for: item), hit, "the lasso and taps use the laid-out text")
        XCTAssertNil(TextBoxDrawer().hitBounds(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1,
                                                                        id: Fixtures.textID)))
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertNil(TextHitTest.textItem(at: Point(300, 600), in: items), "the rest of the page is page")
        XCTAssertEqual(TextHitTest.textItem(at: Point(10, 10), in: items)?.id, item.id)

        // A double-tap on page text starts page typing (F028) when it is installed; F026 never edits it itself.
        let (host, editor) = self.editor(h)
        let params: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "point": [10, 10], "gesture": "doubleTap"]
        var out = try await h.run(CommandIDs.textTapAt, params)
        XCTAssertEqual(out["handled"]?.boolValue, false)
        XCTAssertFalse(editor.isEditing)
        let calls = Calls()
        h.app.commands.register(CommandDescriptor(
            id: CommandIDs.textStartPageText, title: "Start Typing", summary: "Test double for page text.",
            params: .obj(["page": .ref, "id": .str()]), effect: .edit)) { json, _ in
            calls.params.append(json)
            return .object([:])
        }
        out = try await h.run(CommandIDs.textTapAt, params)
        XCTAssertEqual(out["handled"]?.boolValue, true)
        XCTAssertFalse(editor.isEditing)
        for _ in 0..<100 where calls.params.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.params.first?["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
        editor.detach(from: host)
    }

    func testDrawerRendersTheFixtureTextBox() throws {
        let h = Harness()
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        func render(_ item: Item) -> UIImage { draw(item, h) }
        let plain = render(item)
        XCTAssertGreaterThan(pixels(plain, in: CGRect(x: 72, y: 400, width: 300, height: 40), where: { $0 < 100 && $1 < 100 && $2 < 100 }), 20,
                             "the text is drawn inside the box")
        XCTAssertEqual(pixels(plain, in: CGRect(x: 0, y: 0, width: 60, height: 390), where: { $0 < 250 || $1 < 250 || $2 < 250 }), 0,
                       "nothing is drawn outside it")

        item.text?.style.background = RGBA(nibHex: NibHighlighter.lemon.hex)
        let filled = render(item)
        XCTAssertGreaterThan(pixels(filled, in: CGRect(x: 360, y: 405, width: 8, height: 8), where: { $0 > 200 && $1 > 180 && $2 < 150 }), 40,
                             "the box background fills its frame")
    }

    func testDrawerLightensDefaultInkOnDarkPaperAndClipsFixedBoxes() throws {
        let h = Harness()
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        let inside = CGRect(x: 72, y: 400, width: 300, height: 40)
        let dark = draw(item, h, paper: .black, darkPaper: true)
        XCTAssertGreaterThan(pixels(dark, in: inside, where: { $0 > 180 && $1 > 180 && $2 > 180 }), 20,
                             "default-coloured text is drawn light on dark paper")

        let ink: (UInt8, UInt8, UInt8) -> Bool = { $0 < 100 && $1 < 100 && $2 < 100 }
        let below = CGRect(x: 60, y: 442, width: 330, height: 36)
        item.text?.text = RichText(plain: "one\ntwo\nthree\nfour")
        item.text?.style.autoGrow = false
        let clipped = draw(item, h)
        XCTAssertGreaterThan(pixels(clipped, in: inside, where: ink), 20)
        XCTAssertEqual(pixels(clipped, in: below, where: ink), 0, "a fixed-height box clips its text to its frame")

        item.text?.style.autoGrow = true
        XCTAssertGreaterThan(pixels(draw(item, h), in: below, where: ink), 20, "an auto-growing box shows all of it")
    }

    func testInlineImagesAreDecodedOnce() throws {
        let h = Harness()
        let first = try XCTUnwrap(TextLayout.glyphImage(Fixtures.pngAsset, assets: h.assets, doc: Fixtures.docID))
        XCTAssertTrue(first === TextLayout.glyphImage(Fixtures.pngAsset, assets: h.assets, doc: Fixtures.docID))
        var glyph = TextAttributes()
        glyph.attachment = Fixtures.pngAsset
        let box = TextBoxItem(frame: Frame(x: 0, y: 0, w: 200, h: 0),
                              text: RichText(paragraphs: [Paragraph(runs: [TextRun("\u{FFFC}", glyph)])]))
        XCTAssertEqual(TextLayout.fittedHeight(box, assets: h.assets, doc: Fixtures.docID), TextLayout.fittedHeight(box),
                       accuracy: 0.5, "a square image measures like the square stand-in")
    }

    private func draw(_ item: Item, _ h: Harness, paper: UIColor = .white, darkPaper: Bool = false) -> UIImage {
        let size = CGSize(width: 420, height: 520)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            paper.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            TextBoxDrawer().draw(item, in: DrawContext(cg: ctx.cgContext, scale: 1, doc: Fixtures.docID,
                                                       page: Fixtures.page1, darkPaper: darkPaper, assets: h.assets))
        }
    }

    private func pixels(_ image: UIImage, in rect: CGRect, where test: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var count = 0
        for y in max(0, Int(rect.minY))..<min(h, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(w, Int(rect.maxX)) {
                let i = (y * w + x) * 4
                if test(data[i], data[i + 1], data[i + 2]) { count += 1 }
            }
        }
        return count
    }
}
