import XCTest
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibTesting
import NibDesign
@testable import FeatClipboard

/// Exercises the same provider reader as the system board without contacting the simulator's pasteboard.
@MainActor
private final class ProviderClipboardBoard: ClipboardBoard {
    var providers: [NSItemProvider]
    var snapshots = 0

    init(_ providers: [NSItemProvider]) { self.providers = providers }
    func contains(_ types: [String]) -> Bool {
        providers.contains { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0) } }
    }
    var hasStrings: Bool { providers.contains { $0.canLoadObject(ofClass: NSString.self) } }
    func readProviders() -> [NSItemProvider] {
        snapshots += 1
        return providers
    }
    func write(_ representations: [String: Any]) { XCTFail("Paste must not overwrite the source clipboard") }
}

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

    /// A foreign provider can deliver only after the main queue processes another event (including Allow Paste).
    /// No sleeps or real paste permissions: a synchronous wait in the reader cannot make this provider complete.
    private func deferredProvider(_ representations: [String: Data],
                                  onLoad: @escaping @MainActor (String) -> Void) -> NSItemProvider {
        let provider = NSItemProvider()
        for (type, data) in representations {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                DispatchQueue.main.async {
                    onLoad(type)
                    completion(data, nil)
                }
                return nil
            }
        }
        return provider
    }

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
        XCTAssertEqual(owned.sorted(), ["clipboard.copy", "clipboard.copyText", "clipboard.cut", "clipboard.paste", "item.duplicate"])
        XCTAssertEqual(Set(owned), [CommandIDs.clipboardCopy, CommandIDs.clipboardCopyText, CommandIDs.clipboardCut,
                                    CommandIDs.clipboardPaste, CommandIDs.itemDuplicate])
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
        XCTAssertTrue(board.contains([NibFragment.typeIdentifier]))
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
        XCTAssertEqual(NibFragment.union(new).midX, 500, accuracy: 1e-6)
        XCTAssertEqual(NibFragment.union(new).midY, 500, accuracy: 1e-6)

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
        XCTAssertTrue(board.contains([NibFragment.typeIdentifier]))

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

    func testDeferredImagePasteLeavesMainActorResponsiveAndUndoes() async throws {
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let before = try h.snapshot()
        var delivered = false
        let provider = deferredProvider([UTType.png.identifier: Fixtures.pngData]) { type in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(type, UTType.png.identifier)
            XCTAssertEqual(try? h.snapshot(), before, "no mutation before the external bytes arrive")
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
            delivered = true
        }
        let board = ProviderClipboardBoard([provider])
        Clipboard.board = board
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [200, 300]])
        XCTAssertTrue(delivered)
        XCTAssertEqual(board.snapshots, 1)
        XCTAssertEqual(out["source"], "image")
        let pasted = try items(refs(out), in: h)
        XCTAssertEqual(pasted.count, 1)
        let image = try XCTUnwrap(pasted.first?.image)
        XCTAssertEqual(try h.assets.data(image.asset, doc: Fixtures.docID), Fixtures.pngData)
        XCTAssertEqual(pasted[0].bounds.midX, 200, accuracy: 0.001)
        XCTAssertEqual(pasted[0].bounds.midY, 300, accuracy: 0.001)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before, "Undo removes the image and its asset use")
    }

    func testDeferredRichTextAndMatchStyleKeepRepresentationPriority() async throws {
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let before = try h.snapshot()
        let styled = NSAttributedString(string: "Selection rich text", attributes: [.font: UIFont.boldSystemFont(ofSize: 36)])
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        var loaded: [String] = []
        let provider = deferredProvider([UTType.rtf.identifier: rtf,
                                         UTType.utf8PlainText.identifier: Data(styled.string.utf8),
                                         UTType.png.identifier: Fixtures.pngData]) { loaded.append($0) }
        let board = ProviderClipboardBoard([provider])
        Clipboard.board = board
        let rich = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        let richBox = try XCTUnwrap(try items(refs(rich), in: h).first?.text)
        XCTAssertEqual(rich["source"], "text")
        XCTAssertEqual(richBox.text.plainText, styled.string)
        XCTAssertEqual(richBox.text.paragraphs.first?.runs.first?.attrs.bold, true)
        XCTAssertEqual(richBox.text.paragraphs.first?.runs.first?.attrs.size, 36)
        XCTAssertEqual(loaded, [UTType.rtf.identifier], "rich text wins over a preview image; unused flavours stay unread")

        var saved = TextBoxStyle()
        saved.defaults.size = 18
        h.app.settings.set(NibSettings.defaultTextStyle, saved)
        loaded.removeAll()
        // A fresh provider also exercises data-backed UTF-8, as used by external rich-text applications.
        board.providers = [deferredProvider([UTType.rtf.identifier: rtf,
                                            UTType.utf8PlainText.identifier: Data(styled.string.utf8),
                                            UTType.png.identifier: Fixtures.pngData]) { loaded.append($0) }]
        let plain = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "matchStyle": true])
        let plainBox = try XCTUnwrap(try items(refs(plain), in: h).first?.text)
        XCTAssertEqual(plainBox.text.plainText, styled.string)
        XCTAssertNil(plainBox.text.paragraphs.first?.runs.first?.attrs.bold)
        XCTAssertEqual(plainBox.style, saved)
        XCTAssertLessThan(plainBox.frame.h, richBox.frame.h)
        XCTAssertEqual(loaded, [UTType.utf8PlainText.identifier])
        XCTAssertEqual(board.snapshots, 2)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 2)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testUnavailableProviderPastesNothingWithoutUndo() async throws {
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let before = try h.snapshot()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            DispatchQueue.main.async {
                completion(nil, CocoaError(.userCancelled))
            }
            return nil
        }
        Clipboard.board = ProviderClipboardBoard([provider])
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(out["source"], "empty")
        XCTAssertEqual(refs(out), [])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testPasteRechecksReadOnlyModeAfterExternalLoad() async throws {
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let before = try h.snapshot()
        let provider = deferredProvider([UTType.png.identifier: Fixtures.pngData]) { _ in h.session.readOnly = true }
        Clipboard.board = ProviderClipboardBoard([provider])
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(out["source"], "empty")
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testNonUserPasteNeverLoadsExternalProviders() async throws {
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let provider = deferredProvider([UTType.png.identifier: Fixtures.pngData,
                                         UTType.utf8PlainText.identifier: Data("Private".utf8)]) { _ in
            XCTFail("non-user calls must not request foreign content or paste permission")
        }
        let board = ProviderClipboardBoard([provider])
        Clipboard.board = board
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "matchStyle": true], as: .ai("t"))
        XCTAssertEqual(out["source"], "empty")
        XCTAssertEqual(board.snapshots, 0)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testMatchStyleUsesTheSavedDefaultTextStyle() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        var saved = TextBoxStyle()
        saved.defaults.size = 24
        saved.defaults.color = RGBA(hex: "#0066E0")
        saved.align = .center
        saved.fullPage = true                            // a pasted box is never full-page
        h.app.settings.set(NibSettings.defaultTextStyle, saved)
        board.items = [[UTType.utf8PlainText.identifier: "Styled"]]
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "matchStyle": true])
        let box = try XCTUnwrap(try items(refs(out), in: h).first?.text)
        XCTAssertEqual(box.style.defaults.size, 24)
        XCTAssertEqual(box.style.defaults.color, RGBA(hex: "#0066E0"))
        XCTAssertEqual(box.style.align, .center)
        XCTAssertFalse(box.style.fullPage)
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
        let nothingEmpty = try await h.run("clipboard.copy", ["refs": []])
        XCTAssertEqual(nothingCopied["count"], 0)
        XCTAssertEqual(nothingCut["count"], 0)
        XCTAssertEqual(nothingEmpty["count"], 0, "the user's empty refs mean the selection (§6.1 session defaults)")
        do {
            _ = try await h.run("clipboard.copy", ["refs": []], as: .ai("t"))
            XCTFail("callers other than the user must name the items")
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
        XCTAssertEqual(keys.count, 5)
        XCTAssertTrue(keys.allSatisfy { $0.scope == .canvas }, "text fields keep ⌘C / ⌘V while editing")
        XCTAssertTrue(keys.allSatisfy { $0.docKinds == [.notebook, .whiteboard] })

        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2, point: Point(50, 60))
        XCTAssertTrue(h.app.ui.menuItems(.pageLongPress, context).isEmpty, "hidden without text on the clipboard")
        board.items = [[UTType.utf8PlainText.identifier: "Some text"]]
        let entry = h.app.ui.menuItems(.pageLongPress, context).first { $0.id == "clipboard.pasteAndMatchStyle" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.icon, NibSymbol.paste.name)
        XCTAssertEqual(entry?.params(context), ["matchStyle": true, "page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [50, 60]])

        h.app.services.set(NSSet(object: Fixtures.docID.raw), for: ServiceKeys.storeReadOnly)
        XCTAssertTrue(h.app.ui.menuItems(.pageLongPress, context).isEmpty, "hidden in documents Nib will not write")
    }

    /// Shell v2: the keys fill in the key window's selection or page, and only run in notebooks and whiteboards.
    func testKeyCommandsResolveTheSessionAndStayOnCanvasDocuments() {
        let h = Harness(features: [FeatClipboardFeature.self])
        let keys = Dictionary(uniqueKeysWithValues: h.app.content.keyCommands.all
            .filter { $0.owner == FeatClipboardFeature.id }.map { ($0.id, $0) })
        let copy = keys["clipboard.key.copy"]
        let paste = keys["clipboard.key.paste"]
        let matchStyle = keys["clipboard.key.pasteAndMatchStyle"]

        XCTAssertEqual(copy?.resolvedParams(for: h.session), [:], "nothing selected: the command does nothing")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.shapeID, Fixtures.textID])
        XCTAssertEqual(copy?.resolvedParams(for: h.session),
                       ["refs": [.string(page1 + "FIXTURESHP01"), .string(page1 + "FIXTURETXT01")]])
        XCTAssertEqual(keys["clipboard.key.duplicate"]?.resolvedParams(for: h.session)["refs"]?.arrayValue?.count, 2)
        XCTAssertEqual(paste?.resolvedParams(for: h.session), ["page": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(matchStyle?.resolvedParams(for: h.session), ["matchStyle": true, "page": "page:FIXTUREDOC01/FIXTUREPG001"])
        h.session.page = nil
        XCTAssertEqual(paste?.resolvedParams(for: h.session), [:])

        let all = h.app.content.keyCommands.all
        for kind in [DocumentKind.notebook, .whiteboard] {
            let live = KeyCommandRouting.active(all, in: KeyCommandContext(docKind: kind)).filter { $0.owner == FeatClipboardFeature.id }
            XCTAssertEqual(live.count, 5, "\(kind)")
            let editing = KeyCommandContext(docKind: kind, isEditingText: true)
            XCTAssertTrue(KeyCommandRouting.active(all, in: editing).allSatisfy { $0.owner != FeatClipboardFeature.id })
        }
        for kind: DocumentKind? in [.textDocument, .studySet, nil] {
            let live = KeyCommandRouting.active(all, in: KeyCommandContext(docKind: kind))
            XCTAssertTrue(live.allSatisfy { $0.owner != FeatClipboardFeature.id }, "\(String(describing: kind))")
        }

        // F102's block duplicate on ⌘D in text documents never races ours.
        var block = KeyCommandDescriptor(id: "textdoc.key.duplicate", title: "Duplicate", shortcut: KeyShortcut("d", [.command]),
                                         command: "block.duplicate", scope: .canvas, order: 10, owner: "textdoc")
        block.docKinds = [.textDocument]
        let withBlock = all + [block]
        XCTAssertEqual(KeyCommandRouting.active(withBlock, in: KeyCommandContext(docKind: .textDocument))
            .first { $0.shortcut == KeyShortcut("d", [.command]) }?.id, "textdoc.key.duplicate")
        XCTAssertEqual(KeyCommandRouting.active(withBlock, in: KeyCommandContext(docKind: .notebook))
            .first { $0.shortcut == KeyShortcut("d", [.command]) }?.id, "clipboard.key.duplicate")
    }

    /// Documents Nib will not write (saved by a newer Nib): cut, paste and duplicate refuse them for every caller;
    /// copy still works.
    func testReadOnlyDocumentsRefuseEdits() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        h.app.services.set(NSSet(object: Fixtures.docID.raw), for: ServiceKeys.storeReadOnly)
        board.items = [[UTType.utf8PlainText.identifier: "Pasted"]]
        let before = try h.snapshot()
        let shape: JSONValue = ["refs": [.string(page1 + "FIXTURESHP01")]]
        let calls: [(String, JSONValue)] = [("clipboard.cut", shape), ("item.duplicate", shape),
                                            ("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])]
        for (command, params) in calls {
            for principal in [Principal.user, .ai("t")] {
                do {
                    _ = try await h.run(command, params, as: principal)
                    XCTFail("\(command) should refuse a read-only document")
                } catch let e as NibError {
                    XCTAssertEqual(e.code, .unsupported, command)
                }
            }
        }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(board.strings, ["Pasted"], "a refused cut leaves the clipboard alone")

        let copied = try await h.run("clipboard.copy", shape)
        XCTAssertEqual(copied["count"], 1)
        XCTAssertTrue(board.contains([NibFragment.typeIdentifier]))
    }

    /// clipboard.copyText (F037's Copy Text / Copy Link): text, a link, or both, replacing the clipboard.
    func testCopyTextPutsTextAndLinks() async throws {
        let board = useMemoryBoard()
        defer { restoreBoard() }
        let h = Harness(features: [FeatClipboardFeature.self])
        let url = UTType.url.identifier
        let plain = UTType.utf8PlainText.identifier

        let text = try await h.run(CommandIDs.clipboardCopyText, ["text": "Remember the milk"])
        XCTAssertEqual(text["types"], [.string(plain)])
        XCTAssertEqual(board.strings, ["Remember the milk"])
        XCTAssertFalse(board.contains([url]))

        let link = try await h.run(CommandIDs.clipboardCopyText, ["url": "nib://doc/FIXTUREDOC01"])
        XCTAssertEqual(link["types"], [.string(url), .string(plain)])
        XCTAssertEqual(board.items.count, 1, "the clipboard is replaced")
        XCTAssertEqual(board.items.first?[url] as? URL, URL(string: "nib://doc/FIXTUREDOC01"))
        XCTAssertEqual(board.strings, ["nib://doc/FIXTUREDOC01"], "text-only apps get the link")

        _ = try await h.run(CommandIDs.clipboardCopyText, ClipboardCopyText.example, as: .ai("t"))
        XCTAssertEqual(board.items.first?[url] as? URL, URL(string: "https://example.com/notes"))
        XCTAssertEqual(board.strings, ["Remember the milk"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)

        for bad: JSONValue in [[:], ["text": ""], ["url": "not a link"], ["url": ""]] {
            do {
                _ = try await h.run(CommandIDs.clipboardCopyText, bad)
                XCTFail("\(bad) should be refused")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
        XCTAssertEqual(board.strings, ["Remember the milk"], "a refused call leaves the clipboard alone")
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
        board.items = [[NibFragment.typeIdentifier: Data("{not a fragment".utf8), UTType.utf8PlainText.identifier: "Fallback"]]
        let out = try await h.run("clipboard.paste", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(out["source"], "text")
        XCTAssertEqual(try items(refs(out), in: h).first?.text?.text.plainText, "Fallback")

        board.items = [[NibFragment.typeIdentifier: Data("{not a fragment".utf8)]]
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
        let data = try XCTUnwrap(NibFragment(items: [shape]).encoded())
        let fragmentProvider = NSItemProvider()
        DragFlavours.now(fragmentProvider, NibFragment.typeIdentifier, visibility: .all, data: data)
        let imageProvider = NSItemProvider()
        DragFlavours.now(imageProvider, UTType.png.identifier, visibility: .all, data: Fixtures.pngData)
        let textProvider = NSItemProvider(object: "Dropped text" as NSString)

        let payload = await DropReader.load([fragmentProvider, imageProvider, textProvider], style: TextBoxStyle(),
                                            limits: PasteLimits(page: .a4))
        XCTAssertEqual(payload.fragments.map { $0.items.first?.kind }, [.shape, .image, .text])
        XCTAssertTrue(payload.files.isEmpty)
        let combined = try XCTUnwrap(NibFragment.combine(payload.fragments))
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
