import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatLinks

/// Commands through the Harness: undo round trips, navigation history, tap routing, PDF links.
@MainActor
final class FeatLinksTests: XCTestCase {
    private let textRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"

    private func harness() -> Harness { Harness(features: [FeatLinksFeature.self]) }

    private func navigator(_ h: Harness) throws -> LinkNavigator {
        try XCTUnwrap(h.app.services.get(LinkNavigator.serviceKey, as: LinkNavigator.self))
    }

    private func fixtureText(_ h: Harness) throws -> RichText {
        try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).text?.text)
    }

    /// Puts items on a page of the fixture notebook before the workspace first reads that page.
    private func place(_ items: [Item], _ h: Harness, page: PageID = Fixtures.page2) {
        h.persistence.pageItems[Fixtures.docID, default: [:]][page] = items
    }

    /// A stand-in for F052's `audio.play` that records the params it was called with.
    private final class Calls {
        var params: [JSONValue] = []
    }

    private func stubAudioPlay(_ h: Harness) -> Calls {
        let calls = Calls()
        h.app.commands.register(CommandDescriptor(
            id: "audio.play", title: "Play Recording", summary: "Test stand-in that records its params.",
            params: .obj(["clip": .ref, "t": .num(min: 0)], required: ["clip"]), effect: .session, owner: "tests")) { params, _ in
            calls.params.append(params)
            return [:]
        }
        return calls
    }

    /// Runs a command as a dry run (an AI preview): nothing may be persisted, recorded or emitted.
    @discardableResult
    private func dryRun(_ h: Harness, _ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await h.app.bus.execute(Invocation(command: command, params: params, principal: .user, session: h.session,
                                               dryRun: true)).value
    }

    private func assertThrows(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration

    func testRegistersItsCommandsTapHandlersMenusAndShortcuts() {
        let h = harness()
        for id in ["link.set", "link.remove", "link.follow", "link.back", "link.autodetect", "link.tapAt"] {
            XCTAssertEqual(h.app.commands.descriptor(id)?.owner, FeatLinksFeature.id, id)
        }
        let taps = h.app.content.tapHandlers.all.filter { $0.command == "link.tapAt" }
        XCTAssertEqual(Set(taps.map { $0.gesture }), [.tap, .longPress])
        XCTAssertTrue(taps.allSatisfy { $0.order == 300 && $0.itemKinds == nil })
        XCTAssertEqual(taps.first { $0.gesture == .tap }?.worksInReadOnly, true)
        XCTAssertEqual(h.app.ui.menus.get("link.textSelection")?.location, .textSelection)
        XCTAssertEqual(h.app.content.keyCommands.get("link.add")?.shortcut, KeyShortcut("k", .command))
        XCTAssertEqual(h.app.content.keyCommands.get("link.back")?.command, "link.back")
        XCTAssertNotNil(h.app.ui.canvasAttachments.get("link.returnToPage"))
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatLinksFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Editing links

    func testSetThenRemoveRoundTripsAndUndoes() async throws {
        let h = harness()
        let original = try fixtureText(h)
        let before = try h.snapshot()
        let set = try await h.run("link.set", ["ref": .string(textRef), "range": [6, 3], "link": ["url": "https://nib.example"]])
        XCTAssertEqual(set["text"]?.stringValue, "Nib")
        let linked = try fixtureText(h)
        XCTAssertEqual(linked.plainText, "Hello Nib")
        XCTAssertEqual(LinkText.links(in: linked).map { $0.range }, [NSRange(location: 6, length: 3)])
        XCTAssertEqual(LinkText.links(in: linked).first?.link, TextLink(url: "https://nib.example"))

        // Each command gets its own undo round trip. (Bus.undo re-stamps the reverted record's rev, so a second
        // consecutive undo of the same item is skipped by DocTransaction.revert: a NibContracts limit, not ours.)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try fixtureText(h), linked)
        let linkedSnapshot = try h.snapshot()

        let removed = try await h.run("link.remove", ["ref": .string(textRef), "range": [7, 0]])
        XCTAssertEqual(removed["removed"]?.intValue, 1)
        XCTAssertEqual(try fixtureText(h), original)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), linkedSnapshot)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try fixtureText(h), original)
    }

    func testPageAndAudioLinksResolveRefsAndBadInputIsRefused() async throws {
        let h = harness()
        try await h.run("link.set", ["ref": .string(textRef), "range": [0, 5], "link": ["page": "FIXTUREPG002"]])
        XCTAssertEqual(LinkText.links(in: try fixtureText(h)).first?.link, TextLink(document: Fixtures.docID, page: Fixtures.page2))

        try await h.run("link.set", ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "range": [0, 5],
                                     "link": ["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 12]])
        let block = try XCTUnwrap(h.app.workspace.content(Fixtures.textDocID).blocks.first { $0.id == Fixtures.paragraphBlockID })
        XCTAssertEqual(LinkText.links(in: block.text).first?.link,
                       TextLink(document: Fixtures.docID, audioClip: Fixtures.audioID, audioTime: 12))

        let ref = textRef
        await assertThrows(.notFound) {
            _ = try await h.run("link.set", ["ref": .string(ref), "range": [0, 5], "link": ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"]])
        }
        await assertThrows(.invalidParams) {
            _ = try await h.run("link.set", ["ref": .string(ref), "range": [4, 40], "link": ["url": "https://nib.example"]])
        }
        await assertThrows(.invalidParams) {
            _ = try await h.run("link.set", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "range": [0, 1],
                                             "link": ["url": "https://nib.example"]])
        }
        await assertThrows(.permissionDenied) {
            _ = try await h.run("link.set", ["ref": .string(ref), "range": [0, 5], "link": ["url": "javascript:alert(1)"]])
        }
        await assertThrows(.invalidParams) {
            _ = try await h.run("link.set", ["ref": .string(ref), "range": [0, 5]], as: .ai("chat"))
        }
        await assertThrows(.invalidParams) {
            _ = try await h.run("link.set", ["ref": .string(ref), "range": [5_000_000_000, 5_000_000_000],
                                             "link": ["url": "https://nib.example"]], as: .ai("chat"))
        }
    }

    func testOnlyTheUserMayLinkToNibActionsOtherThanOpenAndAudio() async throws {
        let h = harness()
        // Agents and plugins that may edit documents: the refusal below is the link policy, not a missing grant.
        h.app.gateway.grants = { _ in [.documentRead, .documentWrite] }
        let ref: JSONValue = .string(textRef)
        let install: JSONValue = ["url": "nib://plugin/install?url=https://plugins.example/p.zip"]
        await assertThrows(.permissionDenied) {
            _ = try await h.run("link.set", ["ref": ref, "range": [0, 5], "link": install], as: .ai("chat"))
        }
        await assertThrows(.permissionDenied) {
            _ = try await h.run("link.set", ["ref": ref, "range": [0, 5], "link": install], as: .plugin("dev.test.plugin"))
        }
        XCTAssertTrue(LinkText.links(in: try fixtureText(h)).isEmpty)
        // An agent may still use nib://open links: they are stored as page links.
        try await h.run("link.set", ["ref": ref, "range": [0, 5], "link": ["url": "nib://open/FIXTUREDOC01/FIXTUREPG002"]],
                        as: .ai("chat"))
        XCTAssertEqual(LinkText.links(in: try fixtureText(h)).first?.link, TextLink(document: Fixtures.docID, page: Fixtures.page2))
        // The user may link any nib:// action.
        try await h.run("link.set", ["ref": ref, "range": [6, 3], "link": install])
        XCTAssertEqual(LinkText.links(in: try fixtureText(h)).last?.link.url, "nib://plugin/install?url=https://plugins.example/p.zip")
    }

    func testEveryItemKindLinkSetAcceptsIsFollowedByLinkTapAt() async throws {
        let h = harness()
        let nav = try navigator(h)
        var opened: [URL] = []
        nav.openExternal = { opened.append($0) }
        // A shape with text, so the shape is refused for its kind and not for lacking text.
        place([Item(id: "LINKSHAPE001", kind: .shape, z: "V",
                    shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 500, w: 200, h: 80), text: RichText(plain: "Shape text")))], h)
        let onPage1 = "item:FIXTUREDOC01/FIXTUREPG001/"
        let candidates: [(ItemKind, String)] = [
            (.text, onPage1 + "FIXTURETXT01"), (.sticky, onPage1 + "FIXTURESTY01"),
            (.shape, "item:FIXTUREDOC01/FIXTUREPG002/LINKSHAPE001"), (.stroke, onPage1 + "FIXTURESTK01"),
            (.connector, onPage1 + "FIXTURECON01"), (.comment, onPage1 + "FIXTURECMT01"), (.math, onPage1 + "FIXTUREMTH01"),
            (.image, onPage1 + "FIXTUREIMG01"), (.custom, onPage1 + "FIXTURECUS01"),
        ]
        XCTAssertEqual(Set(candidates.map { $0.0 }), Set(ItemKind.allCases))
        var accepted: [ItemKind] = []
        for (kind, ref) in candidates {
            do {
                try await h.run("link.set", ["ref": .string(ref), "range": [0, 5], "link": .object(["url": .string("https://nib.example/" + kind.rawValue)])])
                accepted.append(kind)
            } catch let error as NibError {
                XCTAssertEqual(error.code, .invalidParams, kind.rawValue)
            }
        }
        XCTAssertEqual(accepted, [.text])
        XCTAssertFalse(LinkSelection.isLinkable(onPage1 + "FIXTURESTY01", workspace: h.app.workspace))

        for (kind, ref) in candidates where accepted.contains(kind) {
            guard case let .item(d, p, i)? = NodeRef(ref) else { return XCTFail(ref) }
            let box = try XCTUnwrap(h.app.workspace.item(d, page: p, id: i).text, kind.rawValue)
            let rect = try XCTUnwrap(LinkHitTester.regions(text: box.text, style: box.style,
                                                           size: CGSize(width: box.frame.w, height: box.frame.h)).first?.rects.first)
            h.session.page = p
            let result = try await h.run("link.tapAt", [
                "page": .string(NodeRef.page(d, p).description),
                "point": [.number(box.frame.x + Double(rect.midX)), .number(box.frame.y + Double(rect.midY))],
                "ref": .string(ref), "gesture": "longPress"])
            XCTAssertEqual(result["handled"]?.boolValue, true, kind.rawValue)
            XCTAssertEqual(result["target"]?.stringValue, "https://nib.example/" + kind.rawValue)
        }
        XCTAssertEqual(opened.map { $0.absoluteString }, accepted.map { "https://nib.example/" + $0.rawValue })
    }

    func testAutodetectLinksTypedAddressesOnce() async throws {
        let h = harness()
        let text = RichText(plain: "Slides at https://example.com/slides and www.apple.com")
        place([Item(id: "LINKAUTOTX01", kind: .text, z: "V", text: TextBoxItem(frame: Frame(x: 72, y: 100, w: 400, h: 60), text: text))], h)
        let ref: JSONValue = "item:FIXTUREDOC01/FIXTUREPG002/LINKAUTOTX01"
        let first = try await h.run("link.autodetect", ["ref": ref])
        XCTAssertEqual(first["linked"]?.arrayValue?.count, 2)
        let depth = h.undoDepth(Fixtures.docID)
        let second = try await h.run("link.autodetect", ["ref": ref])
        XCTAssertEqual(second["linked"]?.arrayValue?.count, 0)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testEditorTargetsTheLinkAroundACaretOrTheWholeText() async throws {
        let h = harness()
        try await h.run("link.set", ["ref": .string(textRef), "range": [6, 3], "link": ["url": "https://nib.example"]])
        let caret = try LinkEditorPresenter.makeTarget(ref: textRef, range: [7, 0], editing: nil, workspace: h.app.workspace)
        XCTAssertEqual(caret.range, NSRange(location: 6, length: 3))
        XCTAssertEqual(caret.existing, TextLink(url: "https://nib.example"))
        XCTAssertEqual(caret.excerpt, "Nib")
        let whole = try LinkEditorPresenter.makeTarget(ref: "block:FIXTUREDOC02/FIXTUREBLK02", range: nil,
                                                       editing: nil, workspace: h.app.workspace)
        XCTAssertEqual(whole.range, NSRange(location: 0, length: 12))
        XCTAssertEqual(whole.excerpt, "Hello blocks")
        XCTAssertNil(whole.existing)

        let model = LinkEditorModel(app: h.app, session: h.session, target: caret)
        XCTAssertEqual(model.kind, .website)
        XCTAssertEqual(model.linkTarget, LinkTarget(url: "https://nib.example"))
        model.kind = .audio
        model.clip = Fixtures.audioID
        model.time = 12.34
        XCTAssertEqual(model.linkTarget, LinkTarget(clip: "audio:FIXTUREDOC01/FIXTUREAUD01", t: 12.3))
        model.kind = .document
        model.page = Fixtures.page2
        XCTAssertEqual(model.linkTarget, LinkTarget(page: "page:FIXTUREDOC01/FIXTUREPG002"))
    }

    func testCommandKWhileTypingUsesTheTextTheLinkMenuWasShownFor() {
        let h = harness()
        h.session.selection = Selection()
        h.session.isEditingText = true
        XCTAssertNil(LinkSelection.editingRef(h.session, workspace: h.app.workspace))
        XCTAssertTrue(LinkSelection.textSelectionIsVisible(MenuContext(app: h.app, session: h.session, ref: textRef)))
        XCTAssertEqual(LinkSelection.editingRef(h.session, workspace: h.app.workspace), textRef)
        // Another window, or the same one once typing has ended, does not inherit it.
        let other = EditorSession()
        other.isEditingText = true
        XCTAssertNil(LinkSelection.editingRef(other, workspace: h.app.workspace))
        h.session.isEditingText = false
        XCTAssertNil(LinkSelection.editingRef(h.session, workspace: h.app.workspace))
        // Text that cannot carry links never becomes the target.
        h.session.isEditingText = true
        let sticky = MenuContext(app: h.app, session: h.session, ref: "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01")
        XCTAssertFalse(LinkSelection.textSelectionIsVisible(sticky))
        XCTAssertNil(LinkSelection.editingRef(h.session, workspace: h.app.workspace))
    }

    // MARK: Following links

    func testFollowRecordsHistoryAndBackReturns() async throws {
        let h = harness()
        let nav = try navigator(h)
        let follow = try await h.run("link.follow", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(follow["kind"]?.stringValue, "page")
        XCTAssertEqual(h.session.page, Fixtures.page2)
        let origin = LinkStop(doc: Fixtures.docID, page: Fixtures.page1)
        XCTAssertEqual(nav.history(h.session), [origin])
        XCTAssertEqual(nav.pendingReturn(h.session), origin)
        XCTAssertEqual(nav.returnTitle(origin, session: h.session), "Return to page 1")

        let back = try await h.run("link.back")
        XCTAssertEqual(back["returned"]?.boolValue, true)
        XCTAssertEqual(back["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertNil(nav.pendingReturn(h.session))
        let none = try await h.run("link.back")
        XCTAssertEqual(none["returned"]?.boolValue, false)
    }

    func testHistoryOfClosedWindowsIsDropped() async throws {
        let h = harness()
        let nav = try navigator(h)
        let other = EditorSession()
        other.document = Fixtures.docID
        other.page = Fixtures.page1
        h.app.services.sessions.add(other)
        _ = try await h.app.bus.execute(Invocation(command: "link.follow", params: ["page": "page:FIXTUREDOC01/FIXTUREPG002"],
                                                   session: other))
        XCTAssertEqual(nav.history(other), [LinkStop(doc: Fixtures.docID, page: Fixtures.page1)])
        h.app.services.sessions.remove(other)
        try await h.run("link.follow", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertTrue(nav.history(other).isEmpty)
        XCTAssertEqual(nav.history(h.session), [LinkStop(doc: Fixtures.docID, page: Fixtures.page1)])
    }

    func testAudioLinksPlayTheClipAtTheirTime() async throws {
        let h = harness()
        let calls = stubAudioPlay(h)
        let clip: JSONValue = "audio:FIXTUREDOC01/FIXTUREAUD01"
        let follow = try await h.run("link.follow", ["clip": clip, "t": 30])
        XCTAssertEqual(follow["kind"]?.stringValue, "audio")
        XCTAssertEqual(follow["target"], clip)
        let atThirty: JSONValue = ["clip": clip, "t": 30]
        XCTAssertEqual(calls.params, [atThirty])
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertTrue(try navigator(h).history(h.session).isEmpty)

        // A linked text box: a read-only tap plays from the stored time.
        try await h.run("link.set", ["ref": .string(textRef), "range": [0, 5], "link": ["clip": clip, "t": 12]])
        let box = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).text)
        let rect = try XCTUnwrap(LinkHitTester.regions(text: box.text, style: box.style,
                                                       size: CGSize(width: box.frame.w, height: box.frame.h)).first?.rects.first)
        h.session.readOnly = true
        let tap = try await h.run("link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001",
                                                 "point": [.number(box.frame.x + Double(rect.midX)), .number(box.frame.y + Double(rect.midY))],
                                                 "gesture": "tap"])
        XCTAssertEqual(tap["handled"]?.boolValue, true)
        let fromText: JSONValue = ["clip": clip, "t": 12]
        XCTAssertEqual(calls.params.last, fromText)

        // From another document the window first opens the clip's page, and remembers where it was.
        h.session.document = Fixtures.textDocID
        h.session.page = nil
        try await h.run("link.follow", ["clip": clip])
        let fromStart: JSONValue = ["clip": clip, "t": 0]
        XCTAssertEqual(calls.params.last, fromStart)
        XCTAssertEqual(calls.params.count, 3)
        XCTAssertEqual(h.session.document, Fixtures.docID)
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(try navigator(h).pendingReturn(h.session), LinkStop(doc: Fixtures.textDocID, page: nil))
    }

    func testDryRunsResolveLinksButMoveOpenAndPlayNothing() async throws {
        let h = harness()
        let nav = try navigator(h)
        var opened: [URL] = []
        nav.openExternal = { opened.append($0) }
        let calls = stubAudioPlay(h)

        let page = try await dryRun(h, "link.follow", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(page["kind"]?.stringValue, "page")
        XCTAssertEqual(page["target"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
        let web = try await dryRun(h, "link.follow", ["url": "https://example.com/a"])
        XCTAssertEqual(web["kind"]?.stringValue, "url")
        let audio = try await dryRun(h, "link.follow", ["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 30])
        XCTAssertEqual(audio["kind"]?.stringValue, "audio")
        await assertThrows(.notFound) {
            _ = try await self.dryRun(h, "link.follow", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"])
        }
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertTrue(nav.history(h.session).isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(calls.params.isEmpty)

        // A dry link.tapAt reports the link under the finger and stays put.
        try await h.run("link.set", ["ref": .string(textRef), "range": [6, 3], "link": ["page": "page:FIXTUREDOC01/FIXTUREPG002"]])
        let box = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).text)
        let rect = try XCTUnwrap(LinkHitTester.regions(text: box.text, style: box.style,
                                                       size: CGSize(width: box.frame.w, height: box.frame.h)).first?.rects.first)
        let tap = try await dryRun(h, "link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001",
                                                     "point": [.number(box.frame.x + Double(rect.midX)), .number(box.frame.y + Double(rect.midY))],
                                                     "gesture": "longPress"])
        XCTAssertEqual(tap["handled"]?.boolValue, true)
        XCTAssertEqual(tap["target"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG002")
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertTrue(nav.history(h.session).isEmpty)

        // A dry link.back names the stop without leaving or popping it.
        try await h.run("link.follow", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        let back = try await dryRun(h, "link.back")
        XCTAssertEqual(back["returned"]?.boolValue, true)
        XCTAssertEqual(back["page"]?.stringValue, "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(h.session.page, Fixtures.page2)
        XCTAssertEqual(nav.history(h.session), [LinkStop(doc: Fixtures.docID, page: Fixtures.page1)])
    }

    func testWebLinksOpenOutsideAndAgentsCannotOpenOtherSchemes() async throws {
        let h = harness()
        let nav = try navigator(h)
        var opened: [URL] = []
        nav.openExternal = { opened.append($0) }
        let follow = try await h.run("link.follow", ["url": "https://example.com/a"])
        XCTAssertEqual(follow["kind"]?.stringValue, "url")
        XCTAssertEqual(opened.map { $0.absoluteString }, ["https://example.com/a"])
        XCTAssertTrue(nav.history(h.session).isEmpty)
        await assertThrows(.permissionDenied) {
            _ = try await h.run("link.follow", ["url": "obsidian://open?vault=notes"], as: .ai("chat"))
        }
        XCTAssertEqual(opened.count, 1)
    }

    func testReadOnlyTapFollowsATextLinkAndEditModeTakesALongPress() async throws {
        let h = harness()
        let text = LinkText.setLink(TextLink(document: Fixtures.docID, page: Fixtures.page1), in: RichText(plain: "See page one"),
                                    range: NSRange(location: 4, length: 8))
        let frame = Frame(x: 72, y: 100, w: 300, h: 40)
        place([Item(id: "LINKTAPTXT01", kind: .text, z: "V", text: TextBoxItem(frame: frame, text: text))], h)
        h.session.page = Fixtures.page2
        let rect = try XCTUnwrap(LinkHitTester.regions(text: text, style: TextBoxStyle(), size: CGSize(width: 300, height: 40))
            .first?.rects.first)
        let point: JSONValue = [.number(frame.x + Double(rect.midX)), .number(frame.y + Double(rect.midY))]
        let page: JSONValue = "page:FIXTUREDOC01/FIXTUREPG002"
        let ref: JSONValue = "item:FIXTUREDOC01/FIXTUREPG002/LINKTAPTXT01"

        let editTap = try await h.run("link.tapAt", ["page": page, "point": point, "ref": ref, "gesture": "tap"])
        XCTAssertEqual(editTap["handled"]?.boolValue, false)
        XCTAssertEqual(h.session.page, Fixtures.page2)

        let press = try await h.run("link.tapAt", ["page": page, "point": point, "ref": ref, "gesture": "longPress"])
        XCTAssertEqual(press["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertEqual(try navigator(h).history(h.session), [LinkStop(doc: Fixtures.docID, page: Fixtures.page2)])

        h.session.page = Fixtures.page2
        h.session.readOnly = true
        let readOnlyTap = try await h.run("link.tapAt", ["page": page, "point": point, "ref": ref, "gesture": "tap"])
        XCTAssertEqual(readOnlyTap["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, Fixtures.page1)

        let miss = try await h.run("link.tapAt", ["page": page, "point": [500, 700], "gesture": "tap"])
        XCTAssertEqual(miss["handled"]?.boolValue, false)
    }

    func testTapOnAPDFLinkOfAGeneratedPDFNavigates() async throws {
        let h = harness()
        let pdf = FakePDFService()
        h.app.services.pdf = pdf
        let nav = try navigator(h)
        var opened: [URL] = []
        nav.openExternal = { opened.append($0) }

        // A generated two-page planner: a tab on page 1 jumps to page 2, a footer links to the web.
        let tab = CGRect(x: 72, y: 72, width: 160, height: 32)
        let footer = CGRect(x: 72, y: 760, width: 200, height: 24)
        let web = "https://example.com/planner"
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89)).pdfData { ctx in
            ctx.beginPage()
            ("Notes" as NSString).draw(in: tab, withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
            ctx.setDestinationWithName("notes", for: tab)
            ctx.setURL(URL(string: web)!, for: footer)
            ctx.beginPage()
            ctx.addDestination(withName: "notes", at: .zero)
        }
        let asset = AssetRef("planner.pdf")
        let doc: DocumentID = "LINKPLANNER1"
        let pageA = PageRecord(id: "PLANNERPG001", order: "V", size: .a4, background: .ofPDF(asset, page: 0))
        let pageB = PageRecord(id: "PLANNERPG002", order: "k", size: .a4, background: .ofPDF(asset, page: 1))
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: [pageA, pageB]),
                                         title: "Planner", in: nil)
        h.assets.install(data, as: asset, doc: doc)
        pdf.pages[asset.name] = 2
        pdf.linkMap[asset.name] = [PDFLinkInfo(rect: Rect(tab), pageIndex: 1), PDFLinkInfo(rect: Rect(footer), url: web)]
        h.session.document = doc
        h.session.page = pageA.id
        let onPageA: JSONValue = "page:LINKPLANNER1/PLANNERPG001"

        let jump = try await h.run("link.tapAt", ["page": onPageA, "point": [100, 88], "gesture": "tap"])
        XCTAssertEqual(jump["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, pageB.id)
        XCTAssertEqual(nav.pendingReturn(h.session), LinkStop(doc: doc, page: pageA.id))

        let back = try await h.run("link.back")
        XCTAssertEqual(back["returned"]?.boolValue, true)
        XCTAssertEqual(h.session.page, pageA.id)

        let site = try await h.run("link.tapAt", ["page": onPageA, "point": [150, 770], "gesture": "tap"])
        XCTAssertEqual(site["handled"]?.boolValue, true)
        XCTAssertEqual(opened.map { $0.absoluteString }, [web])

        let blank = try await h.run("link.tapAt", ["page": onPageA, "point": [400, 400], "gesture": "tap"])
        XCTAssertEqual(blank["handled"]?.boolValue, false)
        // In edit mode a tap on an item belongs to the selection, not to the PDF link underneath.
        let onItem = try await h.run("link.tapAt", ["page": onPageA, "point": [100, 88], "ref": "item:LINKPLANNER1/PLANNERPG001/SOMEITEM0001",
                                                    "gesture": "tap"])
        XCTAssertEqual(onItem["handled"]?.boolValue, false)
        XCTAssertEqual(h.session.page, pageA.id)
    }
    func testPDFLinksLandWhereTheCentredPDFPageShowsThem() async throws {
        let h = harness()
        let pdf = FakePDFService()          // every PDF page is A4
        h.app.services.pdf = pdf
        let asset = AssetRef("wide.pdf")
        let doc: DocumentID = "LINKWIDEPDF1"
        // A page twice as wide as the A4 PDF page: the PDF page is drawn at scale 1, centred left to right.
        let wide = PageSize(2 * PageSize.a4.width, PageSize.a4.height)
        let pageA = PageRecord(id: "WIDEPDFPG001", order: "V", size: wide, background: .ofPDF(asset, page: 0))
        let pageB = PageRecord(id: "WIDEPDFPG002", order: "k", size: wide, background: .ofPDF(asset, page: 1))
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: [pageA, pageB]),
                                         title: "Wide", in: nil)
        h.assets.install(Fixtures.pdfData(), as: asset, doc: doc)
        pdf.pages[asset.name] = 2
        let tab = Rect(x: 72, y: 72, width: 160, height: 32)
        pdf.linkMap[asset.name] = [PDFLinkInfo(rect: tab, pageIndex: 1)]
        h.session.document = doc
        h.session.page = pageA.id
        let onPageA: JSONValue = "page:LINKWIDEPDF1/WIDEPDFPG001"

        let placed = LinkHitTester.PDFPlacement(pdfSize: .a4, pageSize: wide).rect(tab)
        XCTAssertEqual(placed.x, PageSize.a4.width / 2 + 72, accuracy: 1e-6)
        XCTAssertEqual(placed.width, 160, accuracy: 1e-6)
        // Where a stretched (non-uniform) mapping would have put the tab, there is only paper.
        let stretched = try await h.run("link.tapAt", ["page": onPageA, "point": [150, 88], "gesture": "tap"])
        XCTAssertEqual(stretched["handled"]?.boolValue, false)
        let hit = try await h.run("link.tapAt", ["page": onPageA, "point": [.number(placed.x + placed.width / 2),
                                                                           .number(placed.y + placed.height / 2)], "gesture": "tap"])
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, pageB.id)
    }
}
