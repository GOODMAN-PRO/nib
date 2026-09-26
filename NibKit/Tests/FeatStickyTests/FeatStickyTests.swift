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

    /// The fixture image as it is now (nil when it is gone). No XCTUnwrap, so it can be polled.
    private func image(_ h: Harness) -> Item? {
        try? h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
    }

    /// The plain text of a note as it is now (nil when it is not in the document). No XCTUnwrap, so it can be polled.
    private func text(_ h: Harness, _ id: ElementID = Fixtures.stickyID, page: PageID = Fixtures.page1) -> String? {
        (try? h.app.workspace.item(Fixtures.docID, page: page, id: id))?.sticky?.text.plainText
    }

    /// `text.setText` belongs to the text feature; this stand-in writes a sticky note's text the same way.
    private func installTextStandIn(_ h: Harness) {
        let d = CommandDescriptor(id: CommandIDs.textSetText, title: "Set Text", summary: "Test stand-in.",
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

    func testCollapseResolveAndColourStackAndUndoOneStepAtATime() async throws {
        let h = harness()
        try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        XCTAssertTrue(try note(h).collapsed)
        XCTAssertEqual(try note(h).frame, Frame(x: 400, y: 120, w: 140, h: 140))  // collapsing keeps the size
        let again = try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        XCTAssertEqual(again["changed"]?.intValue, 0)                           // nothing to do, nothing recorded
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        try await h.run("sticky.resolve", ["ref": .string(stickyRef), "resolved": true])
        try await h.run("sticky.setColor", ["refs": [.string(stickyRef)], "color": "#B8ECC9"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 3)
        var s = try note(h)
        XCTAssertTrue(s.collapsed && s.resolved)
        XCTAssertEqual(s.color, StickyColour.mint.rgba)

        // Three undos in a row on the same note each take back their own step.
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        s = try note(h)
        XCTAssertEqual(s.color, StickyColour.lemon.rgba)
        XCTAssertTrue(s.collapsed && s.resolved)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        s = try note(h)
        XCTAssertFalse(s.resolved)
        XCTAssertTrue(s.collapsed)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(try note(h).collapsed)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        for _ in 0..<3 { XCTAssertTrue(h.app.bus.redo(Fixtures.docID)) }
        s = try note(h)
        XCTAssertTrue(s.collapsed && s.resolved)
        XCTAssertEqual(s.color, StickyColour.mint.rgba)
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

    func testACollapsedNoteIsHitAndPaintedOnlyWhereItsIconIs() async throws {
        let h = harness()
        let expanded = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        XCTAssertEqual(h.app.content.hitBounds(for: expanded), expanded.bounds)
        XCTAssertEqual(h.app.content.paintBounds(for: expanded), expanded.bounds.insetBy(-NibLimits.drawerMargin))

        try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        let collapsed = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        XCTAssertEqual(collapsed.bounds, expanded.bounds)                       // the frame keeps its size…
        let icon = Rect(x: 400, y: 120, width: StickyGeometry.iconSide, height: StickyGeometry.iconSide)
        XCTAssertEqual(h.app.content.hitBounds(for: collapsed), icon)           // …but only the icon takes taps and lassos
        XCTAssertEqual(h.app.content.paintBounds(for: collapsed), icon.insetBy(-NibLimits.drawerMargin))

        // Turned a quarter clockwise, the icon sits at the top-right of the note's box.
        var turned = collapsed
        turned.sticky?.frame = Frame(x: 0, y: 0, w: 100, h: 100, rotation: .pi / 2)
        let hit = h.app.content.hitBounds(for: turned)
        XCTAssertEqual(hit.x, 72, accuracy: 1e-9)
        XCTAssertEqual(hit.y, 0, accuracy: 1e-9)
        XCTAssertEqual(hit.width, 28, accuracy: 1e-9)
        XCTAssertEqual(hit.height, 28, accuracy: 1e-9)
        let s = try XCTUnwrap(turned.sticky)
        XCTAssertTrue(StickyGeometry.hits(s, Point(86, 14)))                    // the tap test agrees
        XCTAssertFalse(StickyGeometry.hits(s, Point(14, 14)))
    }

    func testNoteTextLayoutIsPublished() async throws {
        let h = harness()
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        let s = try XCTUnwrap(item.sticky)
        let r = StickyGeometry.textRect(s)
        let layout = try XCTUnwrap(h.app.content.textLayout(for: item))
        XCTAssertEqual(layout.container.x, 400 + r.x, accuracy: 1e-9)
        XCTAssertEqual(layout.container.y, 120 + r.y, accuracy: 1e-9)
        XCTAssertEqual(layout.container.w, r.width, accuracy: 1e-9)
        XCTAssertEqual(layout.container.h, r.height, accuracy: 1e-9)
        XCTAssertEqual(layout.container.rotation, 0)
        XCTAssertEqual(layout.base, StickyGeometry.textBase)
        XCTAssertFalse(layout.centredVertically)

        // A note turned upside down turns its text area about the note's centre.
        var turned = item
        turned.sticky?.frame.rotation = .pi
        let t = try XCTUnwrap(h.app.content.textLayout(for: turned))
        XCTAssertEqual(t.container.center.x, 470 - (r.midX - 70), accuracy: 1e-9)
        XCTAssertEqual(t.container.center.y, 190 - (r.midY - 70), accuracy: 1e-9)
        XCTAssertEqual(t.container.rotation, .pi, accuracy: 1e-12)

        try await h.run("sticky.setCollapsed", ["refs": [.string(stickyRef)], "collapsed": true])
        let collapsed = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        XCTAssertNil(h.app.content.textLayout(for: collapsed))                  // no text shows on the icon
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
        XCTAssertEqual(h.session.editingTextRef, stickyRef)                     // links, spellcheck and the AI see it…
        XCTAssertEqual(h.session.editingTextRange, [8, 0])                      // …with the caret after "Remember"
        XCTAssertTrue(h.session.selection.isEmpty)                              // handles step aside while typing
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.stickyID])        // the overlay stands in for the note

        // Closing without typing writes nothing.
        sticky.endEditing(save: true)
        XCTAssertFalse(h.session.isEditingText)
        XCTAssertNil(h.session.editingTextRef)
        XCTAssertNil(h.session.editingTextRange)
        XCTAssertNil(host.hidden[Fixtures.page1])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        // Typing is saved when editing ends: one undo step that restores the old text.
        sticky.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        let view = try XCTUnwrap(host.canvasView.subviews.compactMap { $0 as? StickyNoteView }.last)
        view.textView.attributedText = NSAttributedString(string: "Remember the milk",
                                                          attributes: StickyText.typingAttributes(zoom: 1))
        sticky.endEditing(save: true)
        try await waitFor { self.text(h) == "Remember the milk" }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try note(h).text.plainText, "Remember")
        withExtendedLifetime(editor) {}
    }

    func testTypingIsAutosavedAndOneUndoTakesBackTheWholeEditingSession() async throws {
        let h = harness()
        installTextStandIn(h)
        let host = FakeCanvasHost(h)
        let sticky = StickyEditor.editor(for: host)
        sticky.beginEditing(doc: Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        let view = try XCTUnwrap(host.canvasView.subviews.compactMap { $0 as? StickyNoteView }.last)
        let attrs = StickyText.typingAttributes(zoom: 1)

        view.textView.attributedText = NSAttributedString(string: "Remember the milk", attributes: attrs)
        sticky.saveTyping()                                                     // what the pause after typing does
        try await waitFor { self.text(h) == "Remember the milk" }
        XCTAssertEqual(sticky.editingItem, Fixtures.stickyID)                   // saved while still typing
        XCTAssertEqual(host.hidden[Fixtures.page1], [Fixtures.stickyID])

        view.textView.attributedText = NSAttributedString(string: "Remember the milk and eggs", attributes: attrs)
        sticky.endEditing(save: true)
        try await waitFor { self.text(h) == "Remember the milk and eggs" }
        try await waitFor { host.hidden[Fixtures.page1] == nil }                 // the overlay goes once it is saved
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)                          // two writes, one editing session

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(text(h), "Remember")                                     // one undo takes both writes back
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(text(h), "Remember the milk and eggs")
    }

    func testToolPlacesANoteAtOnceHandsBackAndTypingJoinsItsUndoStep() async throws {
        let h = harness()
        installTextStandIn(h)
        try await h.run("settings.set", ["name": "sticky.color", "value": "#FFB8CC"])
        try await h.run("settings.set", ["name": "profile.authorName", "value": "Ada"])
        h.session.tool = StickyTool.toolID                                     // chosen after the pen
        let host = FakeCanvasHost(h)
        let tool = StickyTool()
        XCTAssertFalse(tool.isSticky)
        XCTAssertEqual(tool.inputMode, .taps)
        tool.tap(CanvasSample(page: Fixtures.page2, location: Point(300, 400), isPencil: false), host: host)
        XCTAssertEqual(h.session.tool, "pen")                                   // placing was the tool's one use…
        XCTAssertTrue(h.session.isEditingText)                                  // …and typing starts at once
        let editor = StickyEditor.editor(for: host)
        let id = try XCTUnwrap(editor.editingItem)
        let view = try XCTUnwrap(host.canvasView.subviews.compactMap { $0 as? StickyNoteView }.first)
        XCTAssertEqual(view.note.frame, Frame(x: 220, y: 320, w: 160, h: 160))  // centred under the tap
        XCTAssertEqual(view.note.author, "Ada")
        XCTAssertEqual(host.hidden[Fixtures.page2], [id])

        // The note is in the document while it is typed into.
        try await waitFor { self.text(h, id, page: Fixtures.page2) != nil }
        let placed = try note(h, id, page: Fixtures.page2)
        XCTAssertEqual(placed.frame, Frame(x: 220, y: 320, w: 160, h: 160))
        XCTAssertEqual(placed.color, StickyColour.blush.rgba)
        XCTAssertEqual(placed.author, "Ada")
        XCTAssertEqual(editor.editingItem, id)

        let attrs = StickyText.typingAttributes(zoom: 1)
        view.textView.attributedText = NSAttributedString(string: "Buy milk", attributes: attrs)
        editor.saveTyping()
        try await waitFor { self.text(h, id, page: Fixtures.page2) == "Buy milk" }
        view.textView.attributedText = NSAttributedString(string: "Buy milk and eggs", attributes: attrs)
        editor.endEditing(save: true)
        try await waitFor { self.text(h, id, page: Fixtures.page2) == "Buy milk and eggs" }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)                          // placing and typing: one step
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.kind == .sticky })
    }

    func testDroppingAnItemOntoANoteAttachesItAndOneUndoRestoresFrameAndAttachment() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        installTransformStandIn(h)
        await FeatStickyFeature.start(h.app)
        let before = try XCTUnwrap(image(h))
        XCTAssertNil(before.attachedTo)
        // The image (above the note) is dragged so its centre lands in the middle of the note.
        try await h.run("item.transform", ["ref": .string(imageRef), "dx": 118, "dy": -322])
        try await waitFor { self.image(h)?.attachedTo == Fixtures.stickyID }
        let dropped = try XCTUnwrap(image(h))
        XCTAssertEqual(dropped.image?.frame.center, Point(470, 190))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)                          // the drop and the attachment: one step

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        let undone = try XCTUnwrap(image(h))
        XCTAssertEqual(undone.image?.frame, before.image?.frame)                // one undo puts it back…
        XCTAssertNil(undone.attachedTo)                                         // …not attached, as it was
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        let redone = try XCTUnwrap(image(h))
        XCTAssertEqual(redone.image?.frame, dropped.image?.frame)               // one redo drops…
        XCTAssertEqual(redone.attachedTo, Fixtures.stickyID)                    // …and attaches it again
        try await settle()
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)                          // undo and redo start no follow-ups
    }

    func testMovingAnItemOffItsNoteLetsGoAndOneUndoPutsItBackAttached() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        installTransformStandIn(h)
        await FeatStickyFeature.start(h.app)
        try await h.run("item.transform", ["ref": .string(imageRef), "dx": 118, "dy": -322])
        try await waitFor { self.image(h)?.attachedTo == Fixtures.stickyID }

        try await h.run("item.transform", ["ref": .string(imageRef), "dx": 0, "dy": 300])   // off the note
        try await waitFor { self.image(h).map { $0.attachedTo == nil } ?? false }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        let back = try XCTUnwrap(image(h))
        XCTAssertEqual(back.image?.frame.center, Point(470, 190))
        XCTAssertEqual(back.attachedTo, Fixtures.stickyID)
    }

    func testDeletingANoteLetsGoOfItsChildrenAndOneUndoRestoresBoth() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        installDeleteStandIn(h)
        await FeatStickyFeature.start(h.app)
        // A plugin or the AI attaches the image to the note.
        try await h.run("item.update", ["ref": .string(imageRef), "patch": ["attachedTo": .string(stickyRef)]])
        XCTAssertEqual(image(h)?.attachedTo, Fixtures.stickyID)

        try await h.run("item.delete", ["ref": .string(stickyRef)])
        try await waitFor { self.image(h).map { $0.attachedTo == nil } ?? false }
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2)                          // the detach joined the delete's step

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertFalse(try note(h).collapsed)                                   // the note is back…
        XCTAssertEqual(image(h)?.attachedTo, Fixtures.stickyID)                 // …and so is its child
    }

    func testItemsDroppedOnAnExpandedNoteAttachAndDetach() {
        let note = Item(id: "NOTE", kind: .sticky, z: "V", sticky: StickyItem(frame: Frame(x: 100, y: 100, w: 160, h: 160)))
        let under = Item(id: "UNDER", kind: .shape, z: "G",
                         shape: ShapeItem(shape: .rectangle, frame: Frame(x: 150, y: 150, w: 40, h: 30)))
        var box = Item(id: "BOX", kind: .shape, z: "k", shape: ShapeItem(shape: .rectangle, frame: Frame(x: 150, y: 150, w: 40, h: 30)))
        let wire = Item(id: "WIRE", kind: .connector, z: "m",
                        connector: ConnectorItem(from: ConnectorEnd(point: Point(160, 160)), to: ConnectorEnd(point: Point(170, 170))))
        typealias Change = StickyAttach.Change

        // Dropped onto the note: attached. Items beneath the note and connectors are not "on" it.
        XCTAssertEqual(StickyAttach.plan(moved: [box, under, wire], created: [], deletedNotes: [], pageItems: [under, note, box, wire]),
                       [Change(item: "BOX", parent: "NOTE")])
        // Pasted or dropped from elsewhere onto it: attached too.
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [box], deletedNotes: [], pageItems: [note, box]),
                       [Change(item: "BOX", parent: "NOTE")])
        // Moved off it: let go.
        box.attachedTo = "NOTE"
        box.shape?.frame = Frame(x: 400, y: 400, w: 40, h: 30)
        XCTAssertEqual(StickyAttach.plan(moved: [box], created: [], deletedNotes: [], pageItems: [note, box]),
                       [Change(item: "BOX", parent: nil)])
        // Travelling with its note: untouched.
        box.shape?.frame = Frame(x: 150, y: 150, w: 40, h: 30)
        XCTAssertEqual(StickyAttach.plan(moved: [note, box], created: [], deletedNotes: [], pageItems: [note, box]), [])
        // Moved to another page with its note but ahead of it (`DocTransaction.move` dropped the parent, and the note
        // landed above it): attached to it again.
        var arrived = box
        arrived.attachedTo = nil
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [arrived, note], arrivedFrom: ["BOX": "NOTE"], deletedNotes: [],
                                         pageItems: [arrived, note]),
                       [Change(item: "BOX", parent: "NOTE")])
        // A collapsed note takes nothing new, and keeps a child moved within its frame.
        var collapsed = note
        collapsed.sticky?.collapsed = true
        XCTAssertEqual(StickyAttach.plan(moved: [box], created: [], deletedNotes: [], pageItems: [collapsed, box]), [])
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [arrived], deletedNotes: [], pageItems: [collapsed, arrived]), [])
        // Another container's child (a shape's) is left to its owner.
        var contained = box
        contained.attachedTo = "UNDER"
        XCTAssertEqual(StickyAttach.plan(moved: [contained], created: [], deletedNotes: [], pageItems: [under, note, contained]), [])
        // The note deleted: its children are let go so they stay editable…
        var gone = note
        gone.deleted = true
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [], deletedNotes: ["NOTE"], pageItems: [gone, box]),
                       [Change(item: "BOX", parent: nil)])
        // …unless another expanded note beneath them takes them.
        let other = Item(id: "OTHER", kind: .sticky, z: "A", sticky: StickyItem(frame: Frame(x: 120, y: 120, w: 160, h: 160)))
        XCTAssertEqual(StickyAttach.plan(moved: [], created: [], deletedNotes: ["NOTE"], pageItems: [other, gone, box]),
                       [Change(item: "BOX", parent: "OTHER")])
    }

    func testWhichCommitsAttachAndWhichLetGo() {
        typealias A = StickyAttach
        XCTAssertTrue(A.attachesDrops(command: CommandIDs.itemTransform, principal: .user))
        XCTAssertTrue(A.attachesDrops(command: CommandIDs.clipboardPaste, principal: .ai("assistant")))
        // Undo, redo and reverts restore attachments themselves; sync, item.update and sticky commands never attach.
        for command in [CommandIDs.undo, CommandIDs.redo, CommandIDs.revertGroup, CommandIDs.itemUpdate, "sticky.create"] {
            XCTAssertFalse(A.attachesDrops(command: command, principal: .user), command)
        }
        XCTAssertFalse(A.attachesDrops(command: CommandIDs.itemTransform, principal: .sync("peer")))
        // A reverted group that deletes a note still lets go of its children; undo and redo never add a step.
        XCTAssertTrue(A.releasesChildren(command: CommandIDs.itemDelete, principal: .user))
        XCTAssertTrue(A.releasesChildren(command: CommandIDs.revertGroup, principal: .user))
        for command in [CommandIDs.undo, CommandIDs.redo, CommandIDs.itemUpdate] {
            XCTAssertFalse(A.releasesChildren(command: command, principal: .user), command)
        }
        XCTAssertFalse(A.releasesChildren(command: CommandIDs.itemDelete, principal: .sync("peer")))
    }

    func testNoteTextIsSavedWithItemUpdateWhenTextSetTextIsMissing() async throws {
        let h = harness()
        installItemUpdateStandIn(h)
        XCTAssertNil(h.app.commands.entry(CommandIDs.textSetText))
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
        let d = CommandDescriptor(id: CommandIDs.textSetText, title: "Set Text", summary: "Test stand-in that refuses notes.",
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

    func testDrawerDrawsACollapsedNoteAsItsIconOnScreenAndInExports() throws {
        let h = harness()
        var s = StickyItem(frame: Frame(x: 10, y: 10, w: 160, h: 160), color: StickyColour.sky.rgba)
        XCTAssertTrue(h.app.content.drawer(for: Item.makeSticky(s)) is StickyDrawer)

        let expanded = try render(s, purpose: .screen)
        XCTAssertTrue(close(expanded(90, 90), StickyColour.sky.rgba))           // the middle of the note
        s.collapsed = true
        for purpose in [DrawPurpose.screen, .export] {
            let icon = try render(s, purpose: purpose)
            XCTAssertEqual(icon(90, 90).a, 0, purpose.rawValue)                 // only the icon…
            XCTAssertTrue(close(icon(14, 34), StickyColour.sky.rgba), purpose.rawValue)   // …at the frame's top-left
        }
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

    func testEditingRangeCountsPlainTextWithoutListMarkers() {
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("one")], list: .bullet), Paragraph(runs: [TextRun("two")])])
        let s = StickyText.attributed(text, zoom: 1)
        XCTAssertEqual(s.string, "• one\ntwo")
        let two = (s.string as NSString).range(of: "two")
        XCTAssertEqual(StickyText.plainRange(two, in: s), [4, 3])               // "one\n" comes before it
        XCTAssertEqual(StickyText.plainRange(NSRange(location: 0, length: s.length), in: s), [0, 7])
        XCTAssertEqual(StickyText.plainRange(NSRange(location: 0, length: 0), in: s), [0, 0])
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

    /// Waits (up to 2 s) for the saves and follow-ups the code under test starts.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private func close(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 2 && abs(Int(a.g) - Int(b.g)) <= 2 && abs(Int(a.b) - Int(b.b)) <= 2 && abs(Int(a.a) - Int(b.a)) <= 2
    }

    /// Draws `s` with the "sticky" drawer into a 200 × 200 pt y-down bitmap at 1 px per point, for `purpose`, and
    /// returns a pixel reader.
    private func render(_ s: StickyItem, purpose: DrawPurpose) throws -> (Int, Int) -> RGBA {
        let side = 200
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.translateBy(x: 0, y: CGFloat(side))
        cg.scaleBy(x: 1, y: -1)
        StickyDrawer().draw(Item.makeSticky(s), in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1,
                                                                purpose: purpose))
        let bytes = try XCTUnwrap(cg.data).assumingMemoryBound(to: UInt8.self)
        let copy = Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
        return { x, y in
            let i = (y * side + x) * 4
            return RGBA(copy[i], copy[i + 1], copy[i + 2], copy[i + 3])
        }
    }
}
