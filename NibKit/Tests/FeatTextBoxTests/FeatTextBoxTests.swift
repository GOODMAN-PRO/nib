import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatTextBox

@MainActor
final class FeatTextBoxTests: XCTestCase {
    private let textRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"

    private func box(_ h: Harness, _ id: ElementID = Fixtures.textID, page: PageID = Fixtures.page1) throws -> TextBoxItem {
        try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: page, id: id).text)
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
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try box(h, id, page: page).text.plainText, "Hello")
        editor.detach(from: host)
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

    func testDrawerRendersTheFixtureTextBox() throws {
        let h = Harness()
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        let size = CGSize(width: 420, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        func render(_ item: Item) -> UIImage {
            UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                TextBoxDrawer().draw(item, in: DrawContext(cg: ctx.cgContext, scale: 1, doc: Fixtures.docID,
                                                           page: Fixtures.page1, assets: h.assets))
            }
        }
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
