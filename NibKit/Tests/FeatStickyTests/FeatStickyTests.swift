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
    private let imageRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"

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

    /// F003's `item.update` stand-in: encode the item, deep-merge the patch, decode (no key routing), like the real
    /// command; an `attachedTo` item ref becomes its id.
    private func installItemUpdateStandIn(_ h: Harness) {
        let d = CommandDescriptor(id: CommandIDs.itemUpdate, title: "Update Item", summary: "Test stand-in.",
                                  params: .obj(["ref": .ref, "patch": .anything()], required: ["ref", "patch"]), effect: .edit)
        h.app.commands.register(d) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            var patch = json["patch"] ?? [:]
            if case .object(var o) = patch, case let .item(_, _, parent)? = NodeRef(o["attachedTo"]?.stringValue ?? "") {
                o["attachedTo"] = .string(parent.raw)
                patch = .object(o)
            }
            let new = try JSONValue.from(ctx.workspace.item(doc, page: page, id: id)).merging(patch).decode(Item.self)
            try ctx.mutate { tx -> Item in try tx.put(new, doc: doc, page: page) }
            return [:]
        }
    }

    /// F012's `item.transform` stand-in: moves an image by (dx, dy).
    private func installTransformStandIn(_ h: Harness) {
        let d = CommandDescriptor(id: CommandIDs.itemTransform, title: "Transform", summary: "Test stand-in.",
                                  params: .obj(["ref": .ref, "dx": .num(), "dy": .num()], required: ["ref", "dx", "dy"]),
                                  effect: .edit)
        h.app.commands.register(d) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            let dx = json["dx"]?.doubleValue ?? 0, dy = json["dy"]?.doubleValue ?? 0
            try ctx.mutate { tx -> Item in
                var it = try tx.item(doc, page: page, id: id)
                it.image?.frame.x += dx
                it.image?.frame.y += dy
                return try tx.put(it, doc: doc, page: page)
            }
            return [:]
        }
    }

    /// F003's `item.delete` stand-in: tombstones one item.
    private func installDeleteStandIn(_ h: Harness) {
        let d = CommandDescriptor(id: CommandIDs.itemDelete, title: "Delete", summary: "Test stand-in.",
                                  params: .obj(["ref": .ref], required: ["ref"]), effect: .edit)
        h.app.commands.register(d) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            try ctx.mutate { tx in try tx.delete(item: id, doc: doc, page: page) }
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

    // ponytail: each command's undo round trip is checked on its own. `DocTransaction.revert` skips a record whose rev
    // changed since the entry, and an undo re-stamps the record, so a second consecutive undo of the same note is
    // skipped by the core (contract gap, not this feature's code).
    func testCollapseResolveAndColourEachUndoAsOneStep() async throws {
        let h = harness()
        try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        var s = try note(h)
        XCTAssertTrue(s.collapsed)
        XCTAssertEqual(s.frame, Frame(x: 400, y: 120, w: 140, h: 140))          // collapsing keeps the size
        let again = try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        XCTAssertEqual(again["changed"]?.intValue, 0)                          // nothing to do, nothing recorded
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(try note(h).collapsed)

        try await h.run("sticky.resolve", ["ref": .string(stickyRef), "resolved": true])
        XCTAssertTrue(try note(h).resolved)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(try note(h).resolved)

        try await h.run("sticky.setColor", ["refs": [.string(stickyRef)], "color": "#B8ECC9"])
        XCTAssertEqual(try note(h).color, StickyColour.mint.rgba)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
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
        // Polls the workspace directly: `note` uses XCTUnwrap, which records a failure even inside `try?`.
        try await waitFor { (try? h.app.workspace.item(Fixtures.docID, page: Fixtures.page2, id: id)) != nil }
        let placed = try note(h, id, page: Fixtures.page2)
        XCTAssertEqual(placed.text.plainText, "Buy milk")
        XCTAssertEqual(placed.frame, Frame(x: 220, y: 320, w: 160, h: 160))
        XCTAssertEqual(placed.color, StickyColour.blush.rgba)
        XCTAssertEqual(placed.author, "Ada")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)                              // placing and typing: one step
        h.app.bus.undo(Fixtures.docID)
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.kind == .sticky })
    }

    func testDroppingAnItemOnANoteIsUndoneInOneStep() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        installTransformStandIn(h)
        await FeatStickyFeature.start(h.app)
        let before = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        // The image (above the note) is dragged so its centre lands in the middle of the note.
        try await h.run("item.transform", ["ref": .string(imageRef), "dx": 118, "dy": -322])
        try await settle()
        let dropped = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        XCTAssertEqual(dropped.image?.frame.center, Point(470, 190))
        XCTAssertNil(dropped.attachedTo)                                        // no second write of the dropped item
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        let undone = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        XCTAssertEqual(undone.image?.frame, before.image?.frame)                // one undo puts it back…
        XCTAssertEqual(undone.attachedTo, before.attachedTo)                    // …exactly as it was
    }

    func testDeletingANoteLetsGoOfItsChildrenAndOneUndoRestoresBoth() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        installDeleteStandIn(h)
        await FeatStickyFeature.start(h.app)
        // A plugin or the AI attaches the image to the note.
        try await h.run("item.update", ["ref": .string(imageRef), "patch": ["attachedTo": .string(stickyRef)]])
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID).attachedTo,
                       Fixtures.stickyID)

        try await h.run("item.delete", ["ref": .string(stickyRef)])
        try await waitFor {
            (try? h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)).map { $0.attachedTo == nil } ?? false
        }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2)                          // the detach joined the delete's step

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(try note(h).collapsed)                                   // the note is back…
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID).attachedTo,
                       Fixtures.stickyID)                                       // …and so is its child
    }

    func testOnlyChildrenOfADeletedNoteAreLetGo() {
        let frame = Frame(x: 150, y: 150, w: 40, h: 30)
        let child = Item(id: "CHILD", kind: .shape, z: "k", attachedTo: "NOTE", shape: ShapeItem(shape: .rectangle, frame: frame))
        let other = Item(id: "OTHER", kind: .shape, z: "m", attachedTo: "BOX", shape: ShapeItem(shape: .rectangle, frame: frame))
        let loose = Item(id: "LOOSE", kind: .shape, z: "n", shape: ShapeItem(shape: .rectangle, frame: frame))
        var gone = Item(id: "GONE", kind: .shape, z: "p", attachedTo: "NOTE", shape: ShapeItem(shape: .rectangle, frame: frame))
        gone.deleted = true
        let written = Item(id: "WRITTEN", kind: .shape, z: "q", attachedTo: "NOTE", shape: ShapeItem(shape: .rectangle, frame: frame))
        let page = [child, other, loose, gone, written]

        // Records the deleting commit wrote itself are never written again in its undo group.
        XCTAssertEqual(StickyOrphans.plan(deletedNotes: ["NOTE"], written: ["NOTE", "WRITTEN"], pageItems: page), ["CHILD"])
        XCTAssertEqual(StickyOrphans.plan(deletedNotes: [], written: [], pageItems: page), [])
        // Undo, redo, sync and the follow-up updates never add a step of their own.
        XCTAssertTrue(StickyOrphans.considers(command: CommandIDs.itemDelete, principal: .user))
        XCTAssertTrue(StickyOrphans.considers(command: CommandIDs.revertGroup, principal: .user))
        XCTAssertFalse(StickyOrphans.considers(command: CommandIDs.undo, principal: .user))
        XCTAssertFalse(StickyOrphans.considers(command: CommandIDs.redo, principal: .user))
        XCTAssertFalse(StickyOrphans.considers(command: CommandIDs.itemUpdate, principal: .user))
        XCTAssertFalse(StickyOrphans.considers(command: CommandIDs.itemDelete, principal: .sync("peer")))
    }

    func testNoteTextIsSavedWithItemUpdateWhenTextSetTextIsMissing() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        XCTAssertNil(h.app.commands.entry(StickyActions.textSetText))
        let ok = await StickyActions.setText(h.app, ref: stickyRef, text: RichText(plain: "Saved without the text feature"),
                                             session: h.session, group: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(try note(h).text.plainText, "Saved without the text feature")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try note(h).text.plainText, "Remember")
    }

    func testNoteTextIsStillSavedWhenTextSetTextRefusesTheNote() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        let d = CommandDescriptor(id: StickyActions.textSetText, title: "Set Text", summary: "Test stand-in that refuses notes.",
                                  params: .obj(["ref": .ref, "text": .anything()], required: ["ref", "text"]), effect: .edit)
        h.app.commands.register(d) { _, _ in throw NibError(.invalidParams, "not a text box", path: "$.ref") }
        let ok = await StickyActions.setText(h.app, ref: stickyRef, text: RichText(plain: "Kept anyway"),
                                             session: h.session, group: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(try note(h).text.plainText, "Kept anyway")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    func testInspectorFormattingKeepsTextChangedSinceItOpened() async throws {
        let h = harness()
        installTextStandIn(h)
        installItemUpdateStandIn(h)
        let opened = try note(h).text                                           // what the inspector cached
        XCTAssertEqual(opened.plainText, "Remember")
        try await h.run("text.setText", ["ref": .string(stickyRef), "text": "Changed since"])

        let saved = await StickyActions.format(h.app, refs: [stickyRef], session: h.session) {
            StickyFormat.setting(.bold, true, in: $0)
        }
        XCTAssertEqual(saved.count, 1)
        let s = try note(h)
        XCTAssertEqual(s.text.plainText, "Changed since")                       // the newer text is kept…
        XCTAssertTrue(StickyFormat.isOn(.bold, in: s.text))                     // …and made bold

        // A note locked since the inspector opened is left alone.
        try await h.run("item.update", ["ref": .string(stickyRef), "patch": ["locked": true]])
        let none = await StickyActions.format(h.app, refs: [stickyRef], session: h.session) {
            StickyFormat.setting(.italic, true, in: $0)
        }
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(try StickyFormat.isOn(.italic, in: note(h).text))
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

    /// Lets follow-up work started by a commit observer run (0.2 s).
    private func settle() async throws {
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
    }

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
