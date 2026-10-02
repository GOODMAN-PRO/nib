import XCTest
import UIKit
import SwiftUI
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

    /// A text layout for sticky notes and shape labels, as F036 and F031 publish them (contracts-v2 G14).
    private func publishStickyAndShapeLayouts(_ h: Harness) {
        h.app.content.textLayouts.register(TextLayoutDescriptor(key: ItemKind.sticky.rawValue, owner: "tests") { item in
            guard let f = item.sticky?.frame else { return nil }
            return TextLayoutInfo(container: Frame(x: f.x + 12, y: f.y + 12, w: f.w - 24, h: f.h - 24))
        })
        h.app.content.textLayouts.register(TextLayoutDescriptor(key: ItemKind.shape.rawValue, owner: "tests") { item in
            guard let f = item.shape?.frame else { return nil }
            return TextLayoutInfo(container: Frame(x: f.x + 8, y: f.y + 8, w: f.w - 16, h: f.h - 16), centredVertically: true)
        })
    }

    /// The middle of the first link rect of an item, in page points.
    private func linkPoint(_ item: Item, _ h: Harness, file: StaticString = #filePath, line: UInt = #line) throws -> Point {
        let rect = try XCTUnwrap(LinkHitTester.regions(of: item, content: h.app.content).first?.rects.first,
                                 file: file, line: line)
        return Point(Double(rect.midX), Double(rect.midY))
    }

    private func fixtureTextPoint(_ h: Harness) throws -> JSONValue {
        let p = try linkPoint(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID), h)
        return [.number(p.x), .number(p.y)]
    }

    /// A stand-in for F052's `audio.play` that records the params it was called with.
    private final class Calls {
        var params: [JSONValue] = []
    }

    private func stubAudioPlay(_ h: Harness) -> Calls {
        let calls = Calls()
        h.app.commands.register(CommandDescriptor(
            id: CommandIDs.audioPlay, title: "Play Recording", summary: "Test stand-in that records its params.",
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
        let menu = h.app.ui.menus.get("link.textSelection")
        XCTAssertEqual(menu?.location, .textSelection)
        XCTAssertEqual(menu?.shortcut, KeyShortcut("k", .command))
        XCTAssertEqual(h.app.ui.menus.get("link.back")?.shortcut, KeyShortcut("[", .command))
        let add = h.app.content.keyCommands.get("link.add")
        XCTAssertEqual(add?.shortcut, KeyShortcut("k", .command))
        XCTAssertNotNil(add?.sessionParams)
        XCTAssertEqual(h.app.content.keyCommands.get("link.back")?.command, "link.back")
        // The Return-to-page pill is a chrome overlay now, not a canvas attachment (contracts-v2 G12).
        XCTAssertNil(h.app.ui.canvasAttachments.get("link.returnToPage"))
        let pill = h.app.ui.chromeOverlays.get(ReturnToPageOverlay.id)
        XCTAssertNotNil(pill)
        XCTAssertEqual(pill?.placement, .bottom)
        XCTAssertEqual(pill?.surface, .pill)
        XCTAssertEqual(pill?.recedesWhileWriting, true)
        XCTAssertEqual(pill?.isInteractive, true)
        XCTAssertNil(pill?.docKinds)
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

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try fixtureText(h), linked)
        let linkedSnapshot = try h.snapshot()

        let removed = try await h.run("link.remove", ["ref": .string(textRef), "range": [7, 0]])
        XCTAssertEqual(removed["removed"]?.intValue, 1)
        XCTAssertEqual(try fixtureText(h), original)
        let removedSnapshot = try h.snapshot()

        // Consecutive undos of the same item stack (contracts-v2 G4 revert rebasing): remove, then set.
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), linkedSnapshot)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try fixtureText(h), linked)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), removedSnapshot)
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
        // A sticky note has text, but until its feature publishes a text layout a link there could not be followed.
        await assertThrows(.invalidParams) {
            _ = try await h.run("link.set", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "range": [0, 1],
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
        // A shape with a label, so it is judged on its layout and not for lacking text.
        try await h.insert([Item(id: "LINKSHAPE001", kind: .shape, z: "V",
                                 shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 500, w: 200, h: 80),
                                                  text: RichText(plain: "Shape text")))], page: Fixtures.page2)
        let onPage1 = "item:FIXTUREDOC01/FIXTUREPG001/"
        let candidates: [(ItemKind, String)] = [
            (.text, onPage1 + "FIXTURETXT01"), (.sticky, onPage1 + "FIXTURESTY01"),
            (.shape, "item:FIXTUREDOC01/FIXTUREPG002/LINKSHAPE001"), (.stroke, onPage1 + "FIXTURESTK01"),
            (.connector, onPage1 + "FIXTURECON01"), (.comment, onPage1 + "FIXTURECMT01"), (.math, onPage1 + "FIXTUREMTH01"),
            (.image, onPage1 + "FIXTUREIMG01"), (.custom, onPage1 + "FIXTURECUS01"),
        ]
        XCTAssertEqual(Set(candidates.map { $0.0 }), Set(ItemKind.allCases))

        /// Links every candidate link.set accepts, then follows each accepted link with a long-press on its glyphs.
        func linkAndFollow(_ round: String) async throws -> [ItemKind] {
            var accepted: [ItemKind] = []
            for (kind, ref) in candidates {
                do {
                    try await h.run("link.set", ["ref": .string(ref), "range": [0, 5],
                                                 "link": .object(["url": .string("https://nib.example/\(round)/" + kind.rawValue)])])
                    accepted.append(kind)
                } catch let error as NibError {
                    XCTAssertEqual(error.code, .invalidParams, kind.rawValue)
                }
            }
            for (kind, ref) in candidates where accepted.contains(kind) {
                guard case let .item(d, p, i)? = NodeRef(ref) else {
                    XCTFail(ref)
                    continue
                }
                let point = try linkPoint(h.app.workspace.item(d, page: p, id: i), h)
                h.session.page = p
                let result = try await h.run("link.tapAt", [
                    "page": .string(NodeRef.page(d, p).description), "point": [.number(point.x), .number(point.y)],
                    "ref": .string(ref), "gesture": "longPress"])
                XCTAssertEqual(result["handled"]?.boolValue, true, kind.rawValue)
                XCTAssertEqual(result["target"]?.stringValue, "https://nib.example/\(round)/" + kind.rawValue)
            }
            return accepted
        }

        // Only text boxes lay out their text without help.
        let alone = try await linkAndFollow("alone")
        XCTAssertEqual(alone, [.text])
        XCTAssertFalse(LinkSelection.isLinkable(onPage1 + "FIXTURESTY01", workspace: h.app.workspace, content: h.app.content))

        // Once the sticky and shape features publish their text layouts, their links work too (the connector has no
        // label, the other kinds no text).
        publishStickyAndShapeLayouts(h)
        XCTAssertTrue(LinkSelection.isLinkable(onPage1 + "FIXTURESTY01", workspace: h.app.workspace, content: h.app.content))
        let published = try await linkAndFollow("published")
        XCTAssertEqual(published, [.text, .sticky, .shape])
        XCTAssertEqual(opened.map { $0.absoluteString },
                       alone.map { "https://nib.example/alone/" + $0.rawValue } + published.map { "https://nib.example/published/" + $0.rawValue })
        let sticky = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        XCTAssertEqual(LinkText.links(in: try XCTUnwrap(sticky.sticky?.text)).first?.link, TextLink(url: "https://nib.example/published/sticky"))

        // Should the layout go away again, the link can still be removed.
        h.app.content.textLayouts.unregister(id: ItemKind.sticky.rawValue)
        let removed = try await h.run("link.remove", ["ref": .string(onPage1 + "FIXTURESTY01"), "range": [0, 8]])
        XCTAssertEqual(removed["removed"]?.intValue, 1)
    }

    func testAutodetectLinksTypedAddressesOnce() async throws {
        let h = harness()
        let text = RichText(plain: "Slides at https://example.com/slides and www.apple.com")
        try await h.insert([Item(id: "LINKAUTOTX01", kind: .text, z: "V",
                                 text: TextBoxItem(frame: Frame(x: 72, y: 100, w: 400, h: 60), text: text))], page: Fixtures.page2)
        let ref: JSONValue = "item:FIXTUREDOC01/FIXTUREPG002/LINKAUTOTX01"
        let first = try await h.run("link.autodetect", ["ref": ref])
        XCTAssertEqual(first["linked"]?.arrayValue?.count, 2)
        let depth = h.undoDepth(Fixtures.docID)
        let second = try await h.run("link.autodetect", ["ref": ref])
        XCTAssertEqual(second["linked"]?.arrayValue?.count, 0)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testWebsiteFieldHasAPersistentAccessibleName() async throws {
        let h = harness()
        let target = try LinkEditorPresenter.makeTarget(ref: textRef, range: nil, editing: nil,
                                                        workspace: h.app.workspace, content: h.app.content)
        let model = LinkEditorModel(app: h.app, session: h.session, target: target)
        let host = UIHostingController(rootView: LinkWebsiteForm(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 540, height: 640))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func fields(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
        }
        host.view.layoutIfNeeded()
        for _ in 0..<100 where fields(host.view).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            host.view.layoutIfNeeded()
        }
        let field = try XCTUnwrap(fields(host.view).first)
        XCTAssertEqual(field.accessibilityLabel, "Website address")
        XCTAssertTrue(field.isEnabled)
        XCTAssertEqual(field.keyboardType, .URL)
        field.text = "https://example.com/lab"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(model.url, "https://example.com/lab")
        XCTAssertEqual(field.accessibilityLabel, "Website address", "The name must survive replacement of the placeholder")
        let saved = expectation(description: "Return saves the address")
        model.dismiss = { saved.fulfill() }
        _ = field.delegate?.textFieldShouldReturn?(field)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertEqual(LinkText.links(in: try fixtureText(h)).first?.link.url, "https://example.com/lab")
        let editTarget = try LinkEditorPresenter.makeTarget(ref: textRef, range: nil, editing: nil,
                                                            workspace: h.app.workspace, content: h.app.content)
        let editModel = LinkEditorModel(app: h.app, session: h.session, target: editTarget)
        let removed = expectation(description: "Remove Link finishes")
        editModel.dismiss = { removed.fulfill() }
        editModel.remove()
        await fulfillment(of: [removed], timeout: 10)
        XCTAssertTrue(LinkText.links(in: try fixtureText(h)).isEmpty)
        XCTAssertEqual(try fixtureText(h).plainText, target.excerpt)
    }

    func testEditorTargetsTheLinkAroundACaretOrTheWholeText() async throws {
        let h = harness()
        try await h.run("link.set", ["ref": .string(textRef), "range": [6, 3], "link": ["url": "https://nib.example"]])
        let workspace = h.app.workspace
        let content = h.app.content
        let caret = try LinkEditorPresenter.makeTarget(ref: textRef, range: [7, 0], editing: nil, workspace: workspace,
                                                       content: content)
        XCTAssertEqual(caret.range, NSRange(location: 6, length: 3))
        XCTAssertEqual(caret.existing, TextLink(url: "https://nib.example"))
        XCTAssertEqual(caret.excerpt, "Nib")
        let whole = try LinkEditorPresenter.makeTarget(ref: "block:FIXTUREDOC02/FIXTUREBLK02", range: nil,
                                                       editing: nil, workspace: workspace, content: content)
        XCTAssertEqual(whole.range, NSRange(location: 0, length: 12))
        XCTAssertEqual(whole.excerpt, "Hello blocks")
        XCTAssertNil(whole.existing)
        // The window's editing range is used while it fits the text; a stale one falls back to the whole text, and a
        // caller's range always wins.
        let typed = try LinkEditorPresenter.makeTarget(ref: textRef, range: nil, editing: [0, 5], workspace: workspace,
                                                       content: content)
        XCTAssertEqual(typed.excerpt, "Hello")
        let stale = try LinkEditorPresenter.makeTarget(ref: textRef, range: nil, editing: [40, 3], workspace: workspace,
                                                       content: content)
        XCTAssertEqual(stale.range, NSRange(location: 0, length: 9))
        let given = try LinkEditorPresenter.makeTarget(ref: textRef, range: [6, 3], editing: [0, 5], workspace: workspace,
                                                       content: content)
        XCTAssertEqual(given.excerpt, "Nib")

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

    func testCommandKAndTheLinkMenuUseTheTextBeingEdited() async throws {
        let h = harness()
        let key = try XCTUnwrap(h.app.content.keyCommands.get("link.add"))
        let menu = try XCTUnwrap(h.app.ui.menus.get("link.textSelection"))
        let stickyRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"
        h.session.selection = Selection()
        // Nothing edited or selected: ⌘K names nothing (link.set then asks the user to select text).
        XCTAssertEqual(key.resolvedParams(for: h.session), [:])

        // Typing in the text box: the ref and range the editor publishes (contracts-v2 editingTextRef / Range).
        h.session.isEditingText = true
        h.session.editingTextRef = textRef
        h.session.editingTextRange = [6, 3]
        let typing: JSONValue = ["ref": .string(textRef), "range": [6, 3]]
        XCTAssertEqual(key.resolvedParams(for: h.session), typing)

        // The text-selection menu: its own range (MenuContext.textRange), else the window's for that same text.
        let withRange = MenuContext(app: h.app, session: h.session, ref: textRef, textRange: [0, 5])
        let withoutRange = MenuContext(app: h.app, session: h.session, ref: textRef)
        XCTAssertTrue(menu.isVisible(withRange))
        let menuRange: JSONValue = ["ref": .string(textRef), "range": [0, 5]]
        XCTAssertEqual(menu.params(withRange), menuRange)
        XCTAssertEqual(menu.params(withoutRange), typing)
        XCTAssertEqual(menu.resolvedTitle(for: withoutRange), "Link")
        try await h.run("link.set", ["ref": .string(textRef), "range": [6, 3], "link": ["url": "https://nib.example"]])
        XCTAssertEqual(menu.resolvedTitle(for: withoutRange), "Edit Link")
        XCTAssertEqual(menu.resolvedTitle(for: withRange), "Link")

        // Typing in text that cannot carry links (a sticky note without a published layout): never the target, so
        // ⌘K falls back to the one selected item, all of its text.
        h.session.editingTextRef = stickyRef
        h.session.editingTextRange = [0, 3]
        XCTAssertFalse(menu.isVisible(MenuContext(app: h.app, session: h.session, ref: stickyRef)))
        XCTAssertEqual(key.resolvedParams(for: h.session), [:])
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        let selected: JSONValue = ["ref": .string(textRef)]
        XCTAssertEqual(key.resolvedParams(for: h.session), selected)
        let object = try XCTUnwrap(h.app.ui.menus.get("link.objectMenu"))
        let objectContext = MenuContext(app: h.app, session: h.session, selection: h.session.selection)
        XCTAssertTrue(object.isVisible(objectContext))
        XCTAssertEqual(object.resolvedTitle(for: objectContext), "Edit Link")

        // Editing ended: the editor's leftover ref no longer counts.
        h.session.isEditingText = false
        h.session.editingTextRef = textRef
        XCTAssertEqual(key.resolvedParams(for: h.session), selected)
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

    func testReturnPillShowsWhileTheWindowHasSomewhereToReturnTo() async throws {
        let h = harness()
        let nav = try navigator(h)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(ReturnToPageOverlay.id))
        let context = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        func showsPill() -> Bool { h.app.ui.visibleChromeOverlays(context).contains { $0.id == overlay.id } }
        XCTAssertFalse(showsPill())

        // A jump asks the chrome to re-evaluate this window's overlays, and the pill appears.
        let sessionID = h.session.id.raw
        let update = expectation(forNotification: .nibChromeNeedsUpdate, object: h.app.ui) { note in
            note.userInfo?["session"] as? String == sessionID
        }
        try await h.run("link.follow", ["page": "page:FIXTUREDOC01/FIXTUREPG002"])
        await fulfillment(of: [update], timeout: 2)
        XCTAssertTrue(showsPill())
        // Also in text documents: the history is per window, whatever the document shows.
        XCTAssertTrue(h.app.ui.visibleChromeOverlays(ChromeContext(app: h.app, session: h.session, kind: .textDocument))
            .contains { $0.id == overlay.id })

        // The pill names the stop and follows the window without being rebuilt.
        let pill = ReturnToPagePill(navigator: nav, session: h.session, app: h.app)
        XCTAssertEqual(pill.title, "Return to page 1")
        h.session.document = Fixtures.textDocID
        h.session.page = nil
        let notebook = h.app.services.library?.node(Fixtures.docID)?.title ?? "the previous document"
        XCTAssertEqual(pill.title, "Return to \(notebook), page 1")
        h.session.document = Fixtures.docID
        h.session.page = Fixtures.page2

        // It renders on the chrome's pill surface in Light, Dark and at AX3, one line tall at readable widths.
        let view = overlay.makeView(context)
        XCTAssertEqual(Set(NibSnapshot.images(view, size: CGSize(width: 320, height: 44)).keys), Set(NibSnapshot.Variant.allCases))
        let fit = NibSnapshot.fittingSize(view, width: 320)
        XCTAssertGreaterThan(fit.width, 0)
        XCTAssertLessThanOrEqual(fit.width, 320)
        XCTAssertLessThan(fit.height, 2 * 44)

        // Returning empties the history and the pill goes.
        try await h.run("link.back")
        XCTAssertEqual(h.session.page, Fixtures.page1)
        XCTAssertFalse(showsPill())
        XCTAssertEqual(pill.title, "")
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
        h.session.readOnly = true
        let tap = try await h.run("link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": try fixtureTextPoint(h),
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
        let tap = try await dryRun(h, "link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": try fixtureTextPoint(h),
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

    func testReadOnlyTapNearLinkedTextNavigatesAndReturns() async throws {
        let h = harness()
        // The UI failure left a saved, single-line link with the finger just below its glyphs.
        // Use its page geometry and zoom, exercising the broad-phase bounds as well as TextKit.
        h.session.zoom = 1.2767101196075796
        let text = RichText(plain: "Visit lab")
        _ = try await h.insert([Item(id: "LINKNEARTXT1", kind: .text, z: "z",
                                    text: TextBoxItem(frame: Frame(x: 216.1, y: 414.5, w: 355.2, h: 28), text: text))])
        try await h.run("link.set", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/LINKNEARTXT1", "range": [0, 9],
                                      "link": ["page": "page:FIXTUREDOC01/FIXTUREPG002"]])
        h.session.readOnly = true
        let tap = try await h.run("link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [254.5, 450.1],
                                                 "gesture": "tap"])
        XCTAssertEqual(tap["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, Fixtures.page2)
        let back = try await h.run("link.back")
        XCTAssertEqual(back["returned"]?.boolValue, true)
        XCTAssertEqual(h.session.page, Fixtures.page1)
        let saved = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "LINKNEARTXT1")
        XCTAssertEqual(saved.text?.text.plainText, "Visit lab")
    }

    func testReadOnlyTapFollowsATextLinkAndEditModeTakesALongPress() async throws {
        let h = harness()
        let text = LinkText.setLink(TextLink(document: Fixtures.docID, page: Fixtures.page1), in: RichText(plain: "See page one"),
                                    range: NSRange(location: 4, length: 8))
        let frame = Frame(x: 72, y: 100, w: 300, h: 40)
        let written = try await h.insert([Item(id: "LINKTAPTXT01", kind: .text, z: "V", text: TextBoxItem(frame: frame, text: text))],
                                         page: Fixtures.page2)
        h.session.page = Fixtures.page2
        let at = try linkPoint(try XCTUnwrap(written.first), h)
        let point: JSONValue = [.number(at.x), .number(at.y)]
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

        let placed = LinkHitTester.onPage(tab, pageA.backgroundTransform(sourceSize: .a4))
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

    func testPDFLinksOnARotatedPageFollowTheTurnedPDFPage() async throws {
        let h = harness()
        let pdf = FakePDFService()          // every PDF page is A4 portrait
        h.app.services.pdf = pdf
        let asset = AssetRef("turned.pdf")
        let doc: DocumentID = "LINKTURNPDF1"
        // A4 turned a quarter clockwise onto a landscape page (contracts-v2 G22 `PageRecord.rotation`).
        let landscape = PageSize(PageSize.a4.height, PageSize.a4.width)
        let pageA = PageRecord(id: "TURNPDFPG001", order: "V", size: landscape, background: .ofPDF(asset, page: 0), rotation: 90)
        let pageB = PageRecord(id: "TURNPDFPG002", order: "k", size: landscape, background: .ofPDF(asset, page: 1), rotation: 90)
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: doc, kind: .notebook), pages: [pageA, pageB]),
                                         title: "Turned", in: nil)
        h.assets.install(Fixtures.pdfData(), as: asset, doc: doc)
        pdf.pages[asset.name] = 2
        let tab = Rect(x: 72, y: 72, width: 160, height: 32)
        pdf.linkMap[asset.name] = [PDFLinkInfo(rect: tab, pageIndex: 1)]
        h.session.document = doc
        h.session.page = pageA.id
        let onPageA: JSONValue = "page:LINKTURNPDF1/TURNPDFPG001"

        // Turned clockwise, the wide tab stands upright along the right edge.
        let placed = LinkHitTester.onPage(tab, pageA.backgroundTransform(sourceSize: .a4))
        XCTAssertEqual(placed.x, PageSize.a4.height - 72 - 32, accuracy: 1e-6)
        XCTAssertEqual(placed.y, 72, accuracy: 1e-6)
        XCTAssertEqual(placed.width, 32, accuracy: 1e-6)
        XCTAssertEqual(placed.height, 160, accuracy: 1e-6)
        // Where the unturned page would show it there is only paper.
        let unturned = try await h.run("link.tapAt", ["page": onPageA, "point": [150, 88], "gesture": "tap"])
        XCTAssertEqual(unturned["handled"]?.boolValue, false)
        let hit = try await h.run("link.tapAt", ["page": onPageA, "point": [.number(placed.x + placed.width / 2),
                                                                           .number(placed.y + placed.height / 2)], "gesture": "tap"])
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, pageB.id)
    }

    func testTapsInADocumentTheStoreKeepsReadOnlyFollowTextLinks() async throws {
        let h = harness()
        try await h.run("link.set", ["ref": .string(textRef), "range": [6, 3], "link": ["page": "page:FIXTUREDOC01/FIXTUREPG002"]])
        let point = try fixtureTextPoint(h)
        let edit = try await h.run("link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": point, "ref": .string(textRef),
                                                  "gesture": "tap"])
        XCTAssertEqual(edit["handled"]?.boolValue, false)
        // contracts-v2 G2: a document the store keeps read-only cannot be typed in, so one tap follows the link.
        let readOnly = NSMutableSet(object: Fixtures.docID.raw)
        h.app.services.set(readOnly, for: ServiceKeys.storeReadOnly)
        XCTAssertTrue(h.app.isReadOnly(Fixtures.docID))
        let tap = try await h.run("link.tapAt", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": point, "ref": .string(textRef),
                                                 "gesture": "tap"])
        XCTAssertEqual(tap["handled"]?.boolValue, true)
        XCTAssertEqual(h.session.page, Fixtures.page2)
    }
}
