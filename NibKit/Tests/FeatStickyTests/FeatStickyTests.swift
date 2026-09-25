import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatSticky

/// A document editor stand-in so `sticky.tapAt` can reach a canvas (`EditorSession.editor` is weak: keep it alive).
@MainActor
private final class FakeEditor: DocumentEditing {
    let documentID: DocumentID
    let session: EditorSession
    let canvasHost: CanvasHost?

    init(_ host: FakeCanvasHost) {
        documentID = host.documentID
        session = host.session
        canvasHost = host
    }

    func reveal(page: PageID, rect: Rect?, animated: Bool) {}
    func reloadAll() {}
}

@MainActor
final class FeatStickyTests: XCTestCase {
    private let pageRef = "page:FIXTUREDOC01/FIXTUREPG001"
    private let stickyRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"

    private func harness() -> Harness { Harness(features: [FeatStickyFeature.self]) }

    private func note(_ h: Harness, _ id: ElementID = Fixtures.stickyID, page: PageID = Fixtures.page1) throws -> StickyItem {
        try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: page, id: id).sticky)
    }

    /// `text.setText` belongs to the text feature; this stand-in writes a sticky note's text the same way.
    private func installTextStandIn(_ h: Harness) {
        let d = CommandDescriptor(id: "text.setText", title: "Set Text", summary: "Test stand-in.",
                                  params: .obj(["ref": .ref, "text": .anything()], required: ["ref", "text"]), effect: .edit)
        h.app.commands.register(d) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            let text = try (json["text"] ?? .null).decode(RichText.self)
            try ctx.mutate { tx -> Item in
                var it = try tx.item(doc, page: page, id: id)
                it.sticky?.text = text
                return try tx.put(it, doc: doc, page: page)
            }
            return [:]
        }
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatStickyFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testCreateSignsWithTheAuthorKeepsTheNoteOnThePageAndUndoes() async throws {
        let h = harness()
        try await h.run("settings.set", ["name": "profile.authorName", "value": "Ada"])
        let r = try await h.run("sticky.create", ["page": .string(pageRef), "at": [590, 20], "color": "#AEDAFF",
                                                  "text": "Call Ben", "id": "MYNOTE01"])
        XCTAssertEqual(r["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/MYNOTE01")
        let s = try note(h, "MYNOTE01")
        XCTAssertEqual(s.author, "Ada")
        XCTAssertEqual(s.color, StickyColour.sky.rgba)
        XCTAssertEqual(s.text.plainText, "Call Ben")
        XCTAssertEqual(s.frame.x, PageSize.a4.width - StickyGeometry.noteSide, accuracy: 0.001)   // clamped onto A4
        XCTAssertEqual(s.frame.y, 20)
        XCTAssertEqual(s.frame.w, StickyGeometry.noteSide)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "MYNOTE01"))
    }

    func testBadColourAndNonNotesAreRefusedWithTheirPath() async {
        let h = harness()
        do {
            try await h.run("sticky.setColor", ["refs": [.string(stickyRef)], "color": "blue"])
            XCTFail("expected invalid_params")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.color")
        } catch {
            XCTFail("\(error)")
        }
        do {
            try await h.run("sticky.setCollapsed", ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"], "collapsed": true])
            XCTFail("expected invalid_params")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
            XCTAssertEqual(e.path, "$.refs[0]")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCollapseResolveAndColourEachUndoAsOneStep() async throws {
        let h = harness()
        try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        try await h.run("sticky.resolve", ["ref": .string(stickyRef), "resolved": true])
        try await h.run("sticky.setColor", ["refs": [.string(stickyRef)], "color": "#B8ECC9"])
        var s = try note(h)
        XCTAssertTrue(s.collapsed)
        XCTAssertTrue(s.resolved)
        XCTAssertEqual(s.color, StickyColour.mint.rgba)
        XCTAssertEqual(s.frame, Frame(x: 400, y: 120, w: 140, h: 140))          // collapsing keeps the size
        let again = try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        XCTAssertEqual(again["changed"]?.intValue, 0)                          // nothing to do, nothing recorded
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 3)
        for _ in 0..<3 { h.app.bus.undo(Fixtures.docID) }
        s = try note(h)
        XCTAssertFalse(s.collapsed)
        XCTAssertFalse(s.resolved)
        XCTAssertEqual(s.color, StickyColour.lemon.rgba)
    }

    func testTapExpandsACollapsedNoteOnlyOnItsIcon() async throws {
        let h = harness()
        try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        // The frame still spans 400…540, but a collapsed note is only its icon at the top-left.
        let miss = try await h.run("sticky.tapAt", ["page": .string(pageRef), "point": [520, 240]])
        XCTAssertEqual(miss["handled"]?.boolValue, false)
        XCTAssertTrue(try note(h).collapsed)
        let hit = try await h.run("sticky.tapAt", ["page": .string(pageRef), "point": [410, 130],
                                                   "ref": .string(stickyRef), "gesture": "tap"])
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        XCTAssertFalse(try note(h).collapsed)
        // An expanded note that is not selected is left to selection.tapAt.
        let pass = try await h.run("sticky.tapAt", ["page": .string(pageRef), "point": [470, 190]])
        XCTAssertEqual(pass["handled"]?.boolValue, false)
    }

    func testTapOnTheSelectedNoteEditsItAndOneUndoRestoresTheText() async throws {
        let h = harness()
        installTextStandIn(h)
        let host = FakeCanvasHost(h)
        let editor = FakeEditor(host)
        h.session.editor = editor
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.stickyID])
        let r = try await h.run("sticky.tapAt", ["page": .string(pageRef), "point": [470, 190],
                                                 "ref": .string(stickyRef), "gesture": "tap"])
        XCTAssertEqual(r["handled"]?.boolValue, true)
        let sticky = StickyEditor.editor(for: host)
        XCTAssertEqual(sticky.editingItem, Fixtures.stickyID)
        XCTAssertTrue(h.session.isEditingText)
        XCTAssertTrue(h.session.selection.isEmpty)                              // handles step aside while typing
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.stickyID])        // the overlay stands in for the note

        // Closing without typing writes nothing.
        sticky.endEditing(save: true)
        XCTAssertFalse(h.session.isEditingText)
        XCTAssertNil(host.hidden[Fixtures.page1])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        // Typing is saved once, when editing ends: one undo step that restores the old text.
        sticky.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        let view = try XCTUnwrap(host.canvasView.subviews.compactMap { $0 as? StickyNoteView }.last)
        view.textView.attributedText = NSAttributedString(string: "Remember the milk",
                                                          attributes: StickyText.typingAttributes(zoom: 1))
        sticky.endEditing(save: true)
        try await waitFor { (try? self.note(h).text.plainText) == "Remember the milk" }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try note(h).text.plainText, "Remember")
        withExtendedLifetime(editor) {}
    }

    func testToolPlacesANoteAndItsTextAsOneUndoStep() async throws {
        let h = harness()
        try await h.run("settings.set", ["name": "sticky.color", "value": "#FFB8CC"])
        try await h.run("settings.set", ["name": "profile.authorName", "value": "Ada"])
        let host = FakeCanvasHost(h)
        let tool = StickyTool()
        XCTAssertFalse(tool.isSticky)
        XCTAssertEqual(tool.inputMode, .taps)
        tool.tap(CanvasSample(page: Fixtures.page2, location: Point(300, 400), isPencil: false), host: host)
        XCTAssertTrue(h.session.isEditingText)                                       // typing starts at once
        let id = try XCTUnwrap(StickyEditor.editor(for: host).editingItem)
        let view = try XCTUnwrap(host.canvasView.subviews.compactMap { $0 as? StickyNoteView }.first)
        XCTAssertEqual(view.note.frame, Frame(x: 220, y: 320, w: 160, h: 160))       // centred under the tap
        XCTAssertEqual(view.note.author, "Ada")

        view.textView.attributedText = NSAttributedString(string: "Buy milk", attributes: StickyText.typingAttributes(zoom: 1))
        StickyEditor.editor(for: host).endEditing(save: true)
        try await waitFor { (try? self.note(h, id, page: Fixtures.page2)) != nil }
        let placed = try note(h, id, page: Fixtures.page2)
        XCTAssertEqual(placed.text.plainText, "Buy milk")
        XCTAssertEqual(placed.frame, Frame(x: 220, y: 320, w: 160, h: 160))
        XCTAssertEqual(placed.color, StickyColour.blush.rgba)
        XCTAssertEqual(placed.author, "Ada")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)                              // placing and typing: one step
        h.app.bus.undo(Fixtures.docID)
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.kind == .sticky })
    }

    func testItemsDroppedOnAnExpandedNoteAttachAndDetach() {
        let note = Item(id: "NOTE", kind: .sticky, z: "V", sticky: StickyItem(frame: Frame(x: 100, y: 100, w: 160, h: 160)))
        let under = Item(id: "UNDER", kind: .shape, z: "G",
                         shape: ShapeItem(shape: .rectangle, frame: Frame(x: 150, y: 150, w: 40, h: 30)))
        var box = Item(id: "BOX", kind: .shape, z: "k", shape: ShapeItem(shape: .rectangle, frame: Frame(x: 150, y: 150, w: 40, h: 30)))
        let ink = Item(id: "INK", kind: .connector, z: "m",
                       connector: ConnectorItem(from: ConnectorEnd(point: Point(160, 160)), to: ConnectorEnd(point: Point(170, 170))))
        typealias Change = StickyAttach.Change

        // Dropped onto the note: attached. Items beneath the note and connectors are not "on" it.
        XCTAssertEqual(StickyAttach.plan(moved: [box, under, ink], created: [], deletedNotes: [], pageItems: [under, note, box, ink]),
                       [Change(item: "BOX", parent: "NOTE")])
        // Moved off it: detached.
        box.attachedTo = "NOTE"
        box.shape?.frame = Frame(x: 400, y: 400, w: 40, h: 30)
        XCTAssertEqual(StickyAttach.plan(moved: [box], created: [], deletedNotes: [], pageItems: [note, box]),
                       [Change(item: "BOX", parent: nil)])
        // Travelling with its note: untouched.
        box.shape?.frame = Frame(x: 150, y: 150, w: 40, h: 30)
        XCTAssertEqual(StickyAttach.plan(moved: [note, box], created: [], deletedNotes: [], pageItems: [note, box]), [])
        // A collapsed note takes nothing new, and keeps a child moved within its frame.
        var collapsed = note
        collapsed.sticky?.collapsed = true
        XCTAssertEqual(StickyAttach.plan(moved: [box], created: [], deletedNotes: [], pageItems: [collapsed, box]), [])
        var loose = box
        loose.attachedTo = nil
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [loose], deletedNotes: [], pageItems: [collapsed, loose]), [])
        // The note deleted: its children are let go so they stay editable.
        var gone = note
        gone.deleted = true
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [], deletedNotes: ["NOTE"], pageItems: [gone, box]),
                       [Change(item: "BOX", parent: nil)])
        // Undo, redo, sync and the follow-up updates never re-attach.
        XCTAssertTrue(StickyAttach.considers(command: "item.transform", principal: .user))
        XCTAssertFalse(StickyAttach.considers(command: CommandIDs.undo, principal: .user))
        XCTAssertFalse(StickyAttach.considers(command: CommandIDs.itemUpdate, principal: .user))
        XCTAssertFalse(StickyAttach.considers(command: "item.transform", principal: .sync("peer")))
    }

    func testDrawerDrawsACollapsedNoteAsItsIcon() throws {
        let h = harness()
        var s = StickyItem(frame: Frame(x: 10, y: 10, w: 160, h: 160), color: StickyColour.sky.rgba)
        XCTAssertTrue(h.app.content.drawer(for: Item.makeSticky(s)) is StickyDrawer)

        let expanded = try render(s)
        XCTAssertTrue(close(expanded(90, 90), StickyColour.sky.rgba))           // the middle of the note
        s.collapsed = true
        let icon = try render(s)
        XCTAssertEqual(icon(90, 90).a, 0)                                       // exports show only the icon…
        XCTAssertTrue(close(icon(14, 34), StickyColour.sky.rgba))               // …at the frame's top-left
    }

    func testHitTestFollowsRotation() {
        let s = StickyItem(frame: Frame(x: 0, y: 0, w: 100, h: 100, rotation: .pi / 4))
        XCTAssertTrue(StickyGeometry.hits(s, Point(50, 50)))
        XCTAssertFalse(StickyGeometry.hits(s, Point(2, 2)))                     // a corner of the unrotated box
        XCTAssertTrue(StickyGeometry.hits(s, Point(50, -15)))                   // the top vertex of the rotated note
    }

    func testEditorTextSurvivesAnyZoomExactly() throws {
        let first = Paragraph(runs: [TextRun("Bold ", TextAttributes(bold: true)), TextRun("small", TextAttributes(size: 11, italic: true))],
                              align: .center, lineSpacing: 3)
        let text = RichText(paragraphs: [first, Paragraph(runs: [TextRun("second")], list: .bullet, indent: 1)])
        let expected = StickyText.normalised(text)
        for zoom: CGFloat in [0.5, 1, 1.37, 2.5, 4] {
            XCTAssertEqual(StickyText.richText(StickyText.attributed(text, zoom: zoom), zoom: zoom), expected, "zoom \(zoom)")
        }
        let font = try XCTUnwrap(StickyText.attributed(text, zoom: 2).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 30, accuracy: 0.001)                     // 15 pt text at 2× zoom
    }

    func testWholeNoteFormatting() {
        let t = RichText(plain: "one\ntwo")
        let bold = StickyFormat.setting(.bold, true, in: t)
        XCTAssertTrue(StickyFormat.isOn(.bold, in: bold))
        XCTAssertFalse(StickyFormat.isOn(.bold, in: StickyFormat.setting(.bold, false, in: bold)))
        XCTAssertFalse(StickyFormat.isOn(.italic, in: bold))
        XCTAssertEqual(StickyFormat.size(of: StickyFormat.resized(t, by: 3)), 18)
        XCTAssertEqual(StickyFormat.size(of: StickyFormat.resized(t, by: -100)), StickyFormat.sizes.lowerBound)
        XCTAssertEqual(StickyFormat.alignment(of: StickyFormat.aligned(t, .center)), .center)
    }

    // MARK: Helpers

    /// Waits (up to 2 s) for the saves an editor starts when it finishes.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private func close(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 2 && abs(Int(a.g) - Int(b.g)) <= 2 && abs(Int(a.b) - Int(b.b)) <= 2 && abs(Int(a.a) - Int(b.a)) <= 2
    }

    /// Paints `s` into a 200 × 200 pt y-down bitmap at 1 px per point and returns a pixel reader.
    private func render(_ s: StickyItem) throws -> (Int, Int) -> RGBA {
        let side = 200
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.translateBy(x: 0, y: CGFloat(side))
        cg.scaleBy(x: 1, y: -1)
        StickyPainter.paint(s, in: cg, pixelsPerPoint: 1)
        let bytes = try XCTUnwrap(cg.data).assumingMemoryBound(to: UInt8.self)
        let copy = Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
        return { x, y in
            let i = (y * side + x) * 4
            return RGBA(copy[i], copy[i + 1], copy[i + 2], copy[i + 3])
        }
    }
}
