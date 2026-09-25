import XCTest
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibTesting
@testable import FeatClipboard

@MainActor
final class FeatClipboardTests: XCTestCase {
    private var page1: String { "item:FIXTUREDOC01/FIXTUREPG001/" }

    /// A fresh in-memory pasteboard for one test (hostless runs never use the simulator's).
    private func useMemoryBoard() -> InMemoryClipboardBoard {
        let board = InMemoryClipboardBoard()
        Clipboard.board = board
        return board
    }

    private func restoreBoard() { Clipboard.board = InMemoryClipboardBoard() }

    func testHostlessRunsUseAnInMemoryBoard() {
        _ = Harness(features: [FeatClipboardFeature.self])
        XCTAssertTrue(Clipboard.board is InMemoryClipboardBoard)
    }

    private func refs(_ value: JSONValue) -> [String] { value["refs"]?.arrayValue?.compactMap { $0.stringValue } ?? [] }

    private func items(_ refs: [String], in h: Harness) throws -> [Item] {
        try refs.map { ref in
            guard case let .item(doc, page, id)? = NodeRef(ref) else { throw NibError.invalid("not an item ref: \(ref)") }
            return try h.app.workspace.item(doc, page: page, id: id)
        }
    }

    func testFeatureID() { XCTAssertEqual(FeatClipboardFeature.id, "clipboard") }

    func testCommandConformance() async {
        _ = useMemoryBoard()
        defer { restoreBoard() }
        let problems = await CommandConformance.check(features: [FeatClipboardFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatClipboardFeature.self])
        let owned = h.app.commands.all().filter { $0.owner == FeatClipboardFeature.id }.map { $0.id }
        XCTAssertEqual(owned, ["clipboard.copy", "clipboard.cut", "clipboard.paste", "item.duplicate"])
    }

    /// Acceptance: copy → paste into another document keeps geometry and styles, mints new ids, remaps the connector
    /// and re-puts the image bytes into the target document.
    func testCopyPasteRoundTripAcrossDocuments() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        h.app.services.renderer = FakeRenderer()
        let source: [JSONValue] = ["FIXTURESHP01", "FIXTURESTY01", "FIXTURECON01", "FIXTUREIMG01"].map { .string(page1 + $0) }

        let copied = try await h.run("clipboard.copy", ["refs": .array(source)])
        XCTAssertEqual(copied["count"], 4)
        XCTAssertTrue(board.contains([Fragment.typeIdentifier]))
        XCTAssertTrue(board.contains([UTType.png.identifier]))
        XCTAssertEqual(board.strings, ["Remember"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "copying changes nothing")

        let pasted = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC04/FIXTUREBRD01", "at": [500, 500]])
        XCTAssertEqual(pasted["source"], "fragment")
        let new = try items(refs(pasted), in: h)
        let old = try items(source.compactMap { $0.stringValue }, in: h)
        XCTAssertEqual(new.count, 4)

        let dx = new[0].bounds.minX - old[0].bounds.minX
        let dy = new[0].bounds.minY - old[0].bounds.minY
        for (a, b) in zip(old, new) {
            XCTAssertNotEqual(a.id, b.id)
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(b.bounds.minX - a.bounds.minX, dx, accuracy: 1e-6)
            XCTAssertEqual(b.bounds.minY - a.bounds.minY, dy, accuracy: 1e-6)
            XCTAssertEqual(b.bounds.width, a.bounds.width, accuracy: 1e-6)
            XCTAssertEqual(b.bounds.height, a.bounds.height, accuracy: 1e-6)
            XCTAssertEqual(b.createdBy, "user")
        }
        XCTAssertEqual(new[0].shape?.style, old[0].shape?.style)
        XCTAssertEqual(new[1].sticky?.color, old[1].sticky?.color)
        XCTAssertEqual(new[1].sticky?.text, old[1].sticky?.text)
        XCTAssertEqual(new[2].connector?.from.item, new[0].id)
        XCTAssertEqual(new[2].connector?.to.item, new[1].id)
        XCTAssertEqual(new[2].connector?.style, old[2].connector?.style)
        let asset = try XCTUnwrap(new[3].image?.asset)
        XCTAssertEqual(try h.assets.data(asset, doc: Fixtures.whiteboardID), Fixtures.pngData)
        XCTAssertEqual(Fragment.union(new).midX, 500, accuracy: 1e-6)
        XCTAssertEqual(Fragment.union(new).midY, 500, accuracy: 1e-6)

        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID).count, 1)
    }

    /// Acceptance: the duplicate example passes the undo round trip.
    func testDuplicateExampleUndoesAndRedoes() async throws {
        let h = Harness(features: [FeatClipboardFeature.self])
        let before = try h.snapshot()
        let out = try await h.run("item.duplicate", ItemDuplicate.example)
        let copies = try items(refs(out), in: h)
        XCTAssertEqual(copies.count, 3)
        XCTAssertEqual(copies[0].shape?.frame.x ?? 0, 124, accuracy: 1e-9)
        XCTAssertEqual(copies[0].shape?.frame.y ?? 0, 224, accuracy: 1e-9)
        XCTAssertEqual(copies[2].connector?.from.item, copies[0].id)
        XCTAssertEqual(copies[2].connector?.to.item, copies[1].id)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).count, 13)
    }

    func testRepeatedDuplicatesStepAwayFromEachOther() async throws {
        let h = Harness(features: [FeatClipboardFeature.self])
        let shape: JSONValue = ["refs": [.string(page1 + "FIXTURESHP01")]]
        let first = try items(refs(try await h.run("item.duplicate", shape)), in: h)
        let second = try items(refs(try await h.run("item.duplicate", shape)), in: h)
        XCTAssertEqual(first.first?.shape?.frame.x ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(second.first?.shape?.frame.x ?? 0, 140, accuracy: 1e-9)
    }

    func testCutRemovesItemsFreesConnectorAndUndoes() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let before = try h.snapshot()

        let out = try await h.run("clipboard.cut", ClipboardCut.example)
        XCTAssertEqual(out["removed"]?.arrayValue?.count, 1)
        let after = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        XCTAssertFalse(after.contains { $0.id == Fixtures.shapeID })
        let connector = after.first { $0.id == Fixtures.connectorID }?.connector
        XCTAssertNil(connector?.from.item)
        XCTAssertEqual(connector?.from.point, Point(260, 245))
        XCTAssertEqual(connector?.to.item, Fixtures.stickyID)
        XCTAssertTrue(board.contains([Fragment.typeIdentifier]))

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)

        // Pasting back onto the page with the original present steps down-right.
        let pasted = try items(refs(try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG001"])), in: h)
        XCTAssertEqual(pasted.count, 1)
        XCTAssertNotEqual(pasted.first?.id, Fixtures.shapeID)
        XCTAssertEqual(pasted.first?.shape?.frame.x ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(pasted.first?.shape?.frame.y ?? 0, 220, accuracy: 1e-9)
    }

    func testCutRefusesLockedItems() async throws {
        _ = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        var locked = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.imageID)
        locked.locked = true
        h.persistence.pageItems[Fixtures.docID]?[Fixtures.page1] = try h.app.workspace.allItems(Fixtures.docID, page: Fixtures.page1)
            .map { $0.id == locked.id ? locked : $0 }
        h.app.workspace.close(Fixtures.docID)
        do {
            _ = try await h.run("clipboard.cut", ["refs": [.string(page1 + "FIXTUREIMG01")]])
            XCTFail("cut of a locked item should fail")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).contains { $0.id == Fixtures.imageID })
    }

    func testPasteImagesRichTextAndMatchStyle() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let target = "page:FIXTUREDOC01/FIXTUREPG002"

        board.items = [[UTType.png.identifier: Fixtures.pngData]]
        let image = try await h.run("clipboard.paste", ["page": .string(target), "at": [100, 100]])
        XCTAssertEqual(image["source"], "image")
        let pastedImage = try XCTUnwrap(try items(refs(image), in: h).first?.image)
        XCTAssertEqual(try h.assets.data(pastedImage.asset, doc: Fixtures.docID), Fixtures.pngData)

        let font = try XCTUnwrap(UIFont(name: "Helvetica-Bold", size: 20))
        let styled = NSAttributedString(string: "Bold", attributes: [.font: font])
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.items = [[UTType.rtf.identifier: rtf, UTType.utf8PlainText.identifier: "Bold"]]

        let rich = try await h.run("clipboard.paste", ["page": .string(target), "at": [200, 400]])
        XCTAssertEqual(rich["source"], "text")
        let richBox = try XCTUnwrap(try items(refs(rich), in: h).first?.text)
        XCTAssertEqual(richBox.text.plainText, "Bold")
        XCTAssertEqual(richBox.text.paragraphs.first?.runs.first?.attrs.bold, true)

        let plain = try await h.run("clipboard.paste", ["page": .string(target), "at": [200, 600], "matchStyle": true])
        let plainBox = try XCTUnwrap(try items(refs(plain), in: h).first?.text)
        XCTAssertEqual(plainBox.text.plainText, "Bold")
        XCTAssertNil(plainBox.text.paragraphs.first?.runs.first?.attrs.bold)
        XCTAssertEqual(plainBox.style, TextBoxStyle())
    }

    func testMatchStyleUsesTheSavedDefaultTextStyle() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        h.app.settings.setJSON("text.styles.default", ["size": 24, "color": "#0066E0"])
        board.items = [[UTType.utf8PlainText.identifier: "Styled"]]
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "matchStyle": true])
        let box = try XCTUnwrap(try items(refs(out), in: h).first?.text)
        XCTAssertEqual(box.style.defaults.size, 24)
        XCTAssertEqual(box.style.defaults.color, RGBA(hex: "#0066E0"))
    }

    func testEmptyClipboardPastesNothing() async throws {
        _ = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(out["source"], "empty")
        XCTAssertTrue(refs(out).isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testCallerChosenIDsAreHonouredAndChecked() async throws {
        let h = Harness(features: [FeatClipboardFeature.self])
        guard case var .object(params) = ClipboardPaste.fragmentExample else { return XCTFail("example is an object") }
        params["ids"] = ["MYSHAPE00001", "MYTEXT000001"]
        let out = try await h.run("clipboard.paste", .object(params))
        let pasted = try items(refs(out), in: h)
        XCTAssertEqual(Array(pasted.map { $0.id }.prefix(2)), ["MYSHAPE00001", "MYTEXT000001"])
        XCTAssertEqual(pasted[1].attachedTo, "MYSHAPE00001")
        XCTAssertEqual(pasted[2].connector?.from.item, "MYSHAPE00001")
        XCTAssertNil(pasted[2].connector?.to.item)

        for bad: JSONValue in [["MYSHAPE00001"], ["not valid!"], ["TWICE", "TWICE"]] {
            params["ids"] = bad
            do {
                _ = try await h.run("clipboard.paste", .object(params))
                XCTFail("ids \(bad) should be refused")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
    }

    func testKeyboardCommandsUseTheSelection() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        let copied = try await h.run("clipboard.copy", [:])
        XCTAssertEqual(copied["count"], 1)
        XCTAssertEqual(board.strings, ["Hello Nib"])

        let duplicated = try await h.run("item.duplicate", [:])
        XCTAssertEqual(refs(duplicated).count, 1)

        h.session.selection = Selection()
        let nothingCopied = try await h.run("clipboard.copy", [:])
        let nothingCut = try await h.run("clipboard.cut", [:])
        XCTAssertEqual(nothingCopied["count"], 0)
        XCTAssertEqual(nothingCut["count"], 0)
        do {
            _ = try await h.run("clipboard.copy", ["refs": []])
            XCTFail("an explicit empty refs list is an error")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testShortcutsAndLongPressEntry() {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let keys = h.app.content.keyCommands.all.filter { $0.owner == FeatClipboardFeature.id }
        let byShortcut = Dictionary(uniqueKeysWithValues: keys.map { ($0.shortcut, $0) })
        XCTAssertEqual(byShortcut[KeyShortcut("x", [.command])]?.command, "clipboard.cut")
        XCTAssertEqual(byShortcut[KeyShortcut("c", [.command])]?.command, "clipboard.copy")
        XCTAssertEqual(byShortcut[KeyShortcut("v", [.command])]?.command, "clipboard.paste")
        XCTAssertEqual(byShortcut[KeyShortcut("d", [.command])]?.command, "item.duplicate")
        let matchStyle = byShortcut[KeyShortcut("v", [.command, .option, .shift])]
        XCTAssertEqual(matchStyle?.command, "clipboard.paste")
        XCTAssertEqual(matchStyle?.params["matchStyle"], true)
        XCTAssertTrue(keys.allSatisfy { $0.scope == .canvas }, "text fields keep ⌘C / ⌘V while editing")

        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2, point: Point(50, 60))
        XCTAssertTrue(h.app.ui.menuItems(.pageLongPress, context).isEmpty, "hidden without text on the clipboard")
        board.items = [[UTType.utf8PlainText.identifier: "Some text"]]
        let entry = try? XCTUnwrap(h.app.ui.menuItems(.pageLongPress, context).first { $0.id == "clipboard.pasteAndMatchStyle" })
        XCTAssertEqual(entry?.params(context), ["matchStyle": true, "page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [50, 60]])
    }

    /// Read-only mode (F042): ⌘X, ⌘V, ⌥⇧⌘V and ⌘D change nothing.
    func testReadOnlyModeBlocksCutPasteAndDuplicate() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        board.items = [[UTType.utf8PlainText.identifier: "Pasted"]]
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        h.session.readOnly = true
        let before = try h.snapshot()

        let cut = try await h.run("clipboard.cut", [:])
        XCTAssertEqual(cut["count"], 0)
        XCTAssertEqual(cut["removed"], [])
        let paste = try await h.run("clipboard.paste", [:])
        XCTAssertEqual(paste["source"], "empty")
        let matchStyle = try await h.run("clipboard.paste", ["matchStyle": true])
        XCTAssertEqual(matchStyle["source"], "empty")
        let duplicate = try await h.run("item.duplicate", [:])
        XCTAssertEqual(refs(duplicate), [])
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertEqual(board.strings, ["Pasted"], "the clipboard is left alone too")

        // Read-only mode is the user's window mode: it never blocks an AI call.
        let out = try await h.run("item.duplicate", ["refs": [.string(page1 + "FIXTURESHP01")]], as: .ai("t"))
        XCTAssertEqual(refs(out).count, 1)
    }

    /// ⌘V in a window without a canvas page (text documents, study sets) is a quiet no-op for the user.
    func testUserPasteWithoutAPageIsQuiet() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        board.items = [[UTType.utf8PlainText.identifier: "Pasted"]]
        h.session.page = nil
        let out = try await h.run("clipboard.paste", [:])
        XCTAssertEqual(out["source"], "empty")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    /// AI, plugins and the bridge pass `page` (schema) and may pass `fragment`; without one they only ever read a Nib
    /// fragment from the pasteboard, never another app's content.
    func testPasteAsANonUserPrincipal() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])

        let result = try await h.app.bus.execute(Invocation(command: "clipboard.paste", params: ClipboardPaste.fragmentExample,
                                                            principal: .ai("t"), session: h.session))
        XCTAssertEqual(result.value["source"], "fragment")
        let pasted = try items(refs(result.value), in: h)
        XCTAssertEqual(pasted.map { $0.kind }, [.shape, .text, .connector])
        XCTAssertEqual(pasted[1].attachedTo, pasted[0].id)
        XCTAssertEqual(pasted[2].connector?.from.item, pasted[0].id)
        XCTAssertTrue(pasted.allSatisfy { $0.createdBy == "ai:t" })

        do {
            _ = try await h.run("clipboard.paste", ["fragment": ClipboardPaste.fragmentExample["fragment"] ?? .null], as: .ai("t"))
            XCTFail("callers other than the user must name the page")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }

        let target: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [100, 100]]
        board.items = [[UTType.utf8PlainText.identifier: "Another app's text"]]
        let foreign = try await h.run("clipboard.paste", target, as: .ai("t"))
        XCTAssertEqual(foreign["source"], "empty")
        guard case var .object(matchStyle) = target else { return XCTFail("target is an object") }
        matchStyle["matchStyle"] = true
        let foreignText = try await h.run("clipboard.paste", .object(matchStyle), as: .ai("t"))
        XCTAssertEqual(foreignText["source"], "empty")

        // The AI's own copy puts a fragment on the board, so its copy then paste still works.
        _ = try await h.run("clipboard.copy", ["refs": [.string(page1 + "FIXTURESHP01")]], as: .ai("t"))
        let own = try await h.run("clipboard.paste", target, as: .ai("t"))
        XCTAssertEqual(own["source"], "fragment")
        XCTAssertEqual(refs(own).count, 1)
    }

    /// Any app can put a broken `app.nib.fragment` on the pasteboard: paste falls through to the other flavours.
    func testMalformedPasteboardFragmentFallsThrough() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        board.items = [[Fragment.typeIdentifier: Data("{not a fragment".utf8), UTType.utf8PlainText.identifier: "Fallback"]]
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(out["source"], "text")
        XCTAssertEqual(try items(refs(out), in: h).first?.text?.text.plainText, "Fallback")

        board.items = [[Fragment.typeIdentifier: Data("{not a fragment".utf8)]]
        let broken = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(broken["source"], "empty")
    }

    /// A drag dropped back on its own canvas moves the selection: same page = item.transform, other page = item.moveToPage.
    func testOwnDragDropRouting() {
        let source = CanvasDragContext(host: ObjectIdentifier(self), doc: Fixtures.docID, page: Fixtures.page1,
                                       start: Point(150, 240), bounds: Rect(x: 100, y: 200, width: 120, height: 90),
                                       refs: [page1 + "FIXTURESHP01"])
        XCTAssertNil(CanvasDragDrop.moveCommand(source, to: Fixtures.page1, point: Point(150, 240)), "dropped where it was lifted")

        let same = CanvasDragDrop.moveCommand(source, to: Fixtures.page1, point: Point(160, 235))
        XCTAssertEqual(same?.command, "item.transform")
        XCTAssertEqual(same?.params, ["refs": [.string(page1 + "FIXTURESHP01")], "translate": [10, -5]])

        let other = CanvasDragDrop.moveCommand(source, to: Fixtures.page2, point: Point(150, 250))
        XCTAssertEqual(other?.command, "item.moveToPage")
        XCTAssertEqual(other?.params, ["refs": [.string(page1 + "FIXTURESHP01")], "page": "page:FIXTUREDOC01/FIXTUREPG002",
                                       "offset": [0, 10]])
    }

    func testDropReaderTurnsProvidersIntoFragments() async throws {
        let shape = try Harness(features: []).app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        let data = try XCTUnwrap(Fragment(items: [shape]).encoded())
        let fragmentProvider = NSItemProvider()
        DragFlavours.now(fragmentProvider, Fragment.typeIdentifier, visibility: .all, data: data)
        let imageProvider = NSItemProvider()
        DragFlavours.now(imageProvider, UTType.png.identifier, visibility: .all, data: Fixtures.pngData)
        let textProvider = NSItemProvider(object: "Dropped text" as NSString)

        let payload = await DropReader.load([fragmentProvider, imageProvider, textProvider], style: TextBoxStyle(),
                                            limits: PasteLimits(page: .a4))
        XCTAssertEqual(payload.fragments.map { $0.items.first?.kind }, [.shape, .image, .text])
        XCTAssertTrue(payload.files.isEmpty)
        let combined = try XCTUnwrap(Fragment.combine(payload.fragments))
        XCTAssertEqual(combined.items.count, 3)
        XCTAssertEqual(combined.assets.count, 1)
    }

    func testDragAndDropAttachment() throws {
        let h = Harness(features: [FeatClipboardFeature.self])
        let host = FakeCanvasHost(h)
        let descriptor = try XCTUnwrap(h.app.ui.canvasAttachments.get("clipboard.dragdrop"))
        let attachment = try XCTUnwrap(descriptor.make(host) as? CanvasDragDrop)
        attachment.attach(to: host)
        XCTAssertTrue(host.canvasView.interactions.contains { $0 is UIDragInteraction })
        XCTAssertTrue(host.canvasView.interactions.contains { $0 is UIDropInteraction })
        XCTAssertFalse(attachment.hitTest(.zero, host: host), "never claims touches; the system interactions do")

        let inside = host.viewPoint(Point(150, 240), page: Fixtures.page1)
        XCTAssertNil(attachment.dragSource(at: inside, host: host), "nothing selected")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID])
        let source = try XCTUnwrap(attachment.dragSource(at: inside, host: host))
        XCTAssertEqual(source.items.map { $0.id }, [Fixtures.shapeID])
        XCTAssertEqual(source.context.refs, [page1 + "FIXTURESHP01"])
        XCTAssertEqual(source.context.start, Point(150, 240))
        XCTAssertNil(attachment.dragSource(at: host.viewPoint(Point(500, 700), page: Fixtures.page1), host: host))
        XCTAssertNil(attachment.dragSource(at: host.viewPoint(Point(150, 240), page: Fixtures.page2), host: host))

        attachment.detach(from: host)
        XCTAssertFalse(host.canvasView.interactions.contains { $0 is UIDragInteraction || $0 is UIDropInteraction })
    }
}
