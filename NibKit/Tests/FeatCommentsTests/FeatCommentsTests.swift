import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatComments

private let pageRef = "page:FIXTUREDOC01/FIXTUREPG001"
private let threadRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01"

/// Stands in for the document chrome's `panel.open` (F017) and records what was opened.
private final class PanelHost {
    var opened: [String] = []
}

private final class FakeEditor: DocumentEditing {
    let documentID: DocumentID = Fixtures.docID
    let session: EditorSession
    let canvasHost: CanvasHost?

    init(session: EditorSession, host: CanvasHost) {
        self.session = session
        canvasHost = host
    }

    func reveal(page: PageID, rect: Rect?, animated: Bool) {}
    func reloadAll() {}
}

@MainActor
final class FeatCommentsTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatCommentsFeature.self]) }

    private func item(_ h: Harness, _ ref: String) throws -> Item {
        guard case let .item(doc, page, id)? = NodeRef(ref) else { throw NibError.invalid("not an item ref") }
        return try h.app.workspace.item(doc, page: page, id: id)
    }

    private func installPanelHost(_ h: Harness) -> PanelHost {
        let host = PanelHost()
        h.app.commands.register(CommandDescriptor(id: "panel.open", title: "Open Panel", summary: "Test panel host.",
                                                  effect: .session, target: .app)) { params, _ in
            host.opened.append(params["id"]?.stringValue ?? "")
            return ["id": params["id"] ?? .null]
        }
        return host
    }

    private func assertError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testFeatureID() {
        XCTAssertEqual(FeatCommentsFeature.id, "comments")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatCommentsFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testAddAtASpotCreatesAThreadThatUndoRemoves() async throws {
        let h = harness()
        h.app.settings.set(NibSettings.authorName, "Ana")
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/MYTHREAD01"
        let r = try await h.run("comment.add", ["page": .string(pageRef), "at": [120, 140], "text": "  Units?  ",
                                                "id": "MYTHREAD01"])
        XCTAssertEqual(r["ref"]?.stringValue, ref)
        let c = try XCTUnwrap(try item(h, ref).comment)
        XCTAssertEqual(c.anchor, Point(120, 140))
        XCTAssertEqual(c.messages.map(\.text), ["Units?"])
        XCTAssertEqual(c.messages.first?.author, "Ana")
        XCTAssertEqual(c.messages.first?.id.raw, r["message"]?.stringValue)
        XCTAssertFalse(c.resolved)
        XCTAssertNil(try item(h, ref).attachedTo)

        await assertError(.conflict) {
            _ = try await h.run("comment.add", ["page": .string(pageRef), "at": [10, 10], "text": "Again", "id": "MYTHREAD01"])
        }
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertThrowsError(try item(h, ref))
    }

    func testAddOnAnObjectPinsTheThreadToItAndSurvivesTheObjectsDeletion() async throws {
        let h = harness()
        let shapeRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"
        let r = try await h.run("comment.add", ["page": .string(pageRef), "ref": .string(shapeRef), "text": "Label this"])
        let ref = try XCTUnwrap(r["ref"]?.stringValue)
        let shape = try item(h, shapeRef)
        XCTAssertEqual(try item(h, ref).attachedTo, Fixtures.shapeID)
        XCTAssertEqual(try item(h, ref).comment?.anchor, Point(shape.bounds.maxX, shape.bounds.minY))
        XCTAssertEqual(try item(h, ref).layer, shape.layer)

        // Deleting the object (item.delete, F013) leaves the thread; later edits unpin it instead of failing.
        h.app.commands.register(CommandDescriptor(id: "test.deleteShape", title: "Delete", summary: "Test.",
                                                  effect: .edit)) { _, ctx in
            try ctx.mutate { tx in try tx.delete(item: Fixtures.shapeID, doc: Fixtures.docID, page: Fixtures.page1) }
            return [:]
        }
        try await h.run("test.deleteShape")
        try await h.run("comment.reply", ["ref": .string(ref), "text": "Box is gone"])
        XCTAssertNil(try item(h, ref).attachedTo)
        XCTAssertEqual(try item(h, ref).comment?.messages.count, 2)

        await assertError(.invalidParams) {
            _ = try await h.run("comment.add", ["page": .string(pageRef), "ref": .string(threadRef), "text": "Nested"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("comment.add", ["page": "page:FIXTUREDOC01/FIXTUREPG002",
                                            "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "text": "Elsewhere"])
        }
        await assertError(.notFound) {
            _ = try await h.run("comment.add", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01", "at": [1, 1], "text": "Lost"])
        }
    }

    func testReplyEditResolveAndDeleteMessagesRoundTrip() async throws {
        let h = harness()
        try await h.run("comment.resolve", ["ref": .string(threadRef), "resolved": true])
        XCTAssertEqual(try item(h, threadRef).comment?.resolved, true)

        let reply = try await h.run("comment.reply", ["ref": .string(threadRef), "text": "Done"])
        let replyID = try XCTUnwrap(reply["message"]?.stringValue)
        var c = try XCTUnwrap(try item(h, threadRef).comment)
        XCTAssertFalse(c.resolved, "a reply reopens the thread")
        XCTAssertEqual(c.messages.map(\.text), ["Check this", "Done"])

        try await h.run("comment.edit", ["ref": .string(threadRef), "message": .string(replyID), "text": "Done, see page 4"])
        c = try XCTUnwrap(try item(h, threadRef).comment)
        XCTAssertEqual(c.messages.last?.text, "Done, see page 4")
        XCTAssertEqual(c.messages.last?.edited, true)
        XCTAssertEqual(c.messages.first?.edited, false)
        await assertError(.notFound) {
            _ = try await h.run("comment.edit", ["ref": .string(threadRef), "message": "NOSUCHMSG", "text": "x"])
        }
        await assertError(.invalidParams) {
            _ = try await h.run("comment.edit", ["ref": .string(threadRef), "message": .string(replyID), "text": "  "])
        }

        let first = try await h.run("comment.deleteMessage", ["ref": .string(threadRef), "message": "FIXTUREMSG01"])
        XCTAssertEqual(first["deletedThread"]?.boolValue, false)
        let last = try await h.run("comment.deleteMessage", ["ref": .string(threadRef), "message": .string(replyID)])
        XCTAssertEqual(last["deletedThread"]?.boolValue, true)
        XCTAssertThrowsError(try item(h, threadRef))

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try item(h, threadRef).comment?.messages.map(\.id.raw), [replyID])
    }

    func testTapOpensThePinUnderTheFingerAndSkipsHiddenResolvedThreads() async throws {
        let h = harness()
        let panels = installPanelHost(h)
        let tap: JSONValue = ["page": .string(pageRef), "point": [566, 404], "gesture": "tap"]

        var r = try await h.run("comment.tapAt", tap)
        XCTAssertEqual(r["handled"]?.boolValue, true)
        XCTAssertEqual(r["ref"]?.stringValue, threadRef)
        XCTAssertEqual(panels.opened, [CommentPanels.thread])
        XCTAssertEqual(CommentsState.of(h.app.services)?.target(for: h.session),
                       .thread(doc: Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID))

        r = try await h.run("comment.tapAt", ["page": .string(pageRef), "point": [300, 300], "gesture": "tap"])
        XCTAssertEqual(r["handled"]?.boolValue, false)

        try await h.run("comment.resolve", ["ref": .string(threadRef), "resolved": true])
        r = try await h.run("comment.tapAt", tap)
        XCTAssertEqual(r["handled"]?.boolValue, false, "a hidden resolved pin cannot be tapped")
        // The Comments list and comment links name the thread, so they open it even while resolved ones are hidden.
        r = try await h.run("comment.tapAt", ["page": .string(pageRef), "point": [0, 0], "ref": .string(threadRef)])
        XCTAssertEqual(r["handled"]?.boolValue, true)

        h.app.settings.set(CommentSettings.showResolved, true)
        r = try await h.run("comment.tapAt", tap)
        XCTAssertEqual(r["handled"]?.boolValue, true)
    }

    func testEmptyTextFromTheUIOpensADraftAndWritesNothing() async throws {
        let h = harness()
        let panels = installPanelHost(h)
        let depth = h.undoDepth(Fixtures.docID)
        let r = try await h.run("comment.add", ["page": .string(pageRef),
                                                "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "text": ""])
        XCTAssertEqual(r["draft"]?.boolValue, true)
        XCTAssertNil(r["ref"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
        XCTAssertEqual(panels.opened, [CommentPanels.thread])
        guard case .draft(let draft)? = CommentsState.of(h.app.services)?.target(for: h.session) else {
            return XCTFail("no draft in the thread panel")
        }
        XCTAssertEqual(draft.parent, Fixtures.textID)
        XCTAssertEqual(draft.at, Point(372, 400))   // the text box's top-right corner

        await assertError(.invalidParams) {
            _ = try await h.run("comment.add", ["page": .string(pageRef), "text": " "], as: .ai("chat1"))
        }
    }

    func testPinDrawerHidesResolvedThreadsUnlessShowResolvedIsOn() throws {
        let h = harness()
        var comment = CommentItem(anchor: Point(16, 16), messages: [CommentMessage(author: "Ana", text: "Why?")])
        let drawer = try XCTUnwrap(h.app.content.drawer(for: Item.makeComment(comment)))
        func paints(_ c: CommentItem) -> Bool {
            let size = 32
            guard let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = cg.data else { return false }
            drawer.draw(Item.makeComment(c), in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1))
            let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
            return (0..<(size * size)).contains { bytes[$0 * 4 + 3] > 0 }
        }
        XCTAssertTrue(paints(comment))
        comment.resolved = true
        XCTAssertFalse(paints(comment))
        h.app.settings.set(CommentSettings.showResolved, true)
        XCTAssertTrue(paints(comment))
    }

    func testShowResolvedToggleRedrawsOpenCanvases() async throws {
        let h = harness()
        let host = FakeCanvasHost(h)
        let editor = FakeEditor(session: h.session, host: host)
        h.session.editor = editor
        await FeatCommentsFeature.start(h.app)

        try await h.run("settings.set", ["name": "comments.showResolved", "value": true])
        for _ in 0..<50 where host.invalidations.isEmpty { await Task.yield() }
        XCTAssertTrue(h.app.settings.get(CommentSettings.showResolved))
        XCTAssertEqual(Set(host.invalidations.map { $0.page }), [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage])
        withExtendedLifetime(editor) {}
    }

    func testCommentsListGroupsThreadsByPageInReadingOrder() async throws {
        let h = harness()
        try await h.run("comment.add", ["page": .string(pageRef), "at": [100, 50], "text": "Top of the page"])
        try await h.run("comment.add", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [10, 10], "text": "Second page"])
        try await h.run("comment.reply", ["ref": .string(threadRef), "text": "Agreed"])
        try await h.run("comment.resolve", ["ref": .string(threadRef), "resolved": true])
        let content = try h.app.workspace.content(Fixtures.docID)
        let items: (PageID) -> [Item] = { (try? h.app.workspace.items(Fixtures.docID, page: $0)) ?? [] }

        let open = CommentsListModel.build(content: content, items: items, showResolved: false)
        XCTAssertEqual(open.hidden, 1)
        XCTAssertEqual(open.sections.map(\.title), ["Page 1", "Page 2"])
        XCTAssertEqual(open.sections.first?.rows.map(\.text), ["Top of the page"])

        let all = CommentsListModel.build(content: content, items: items, showResolved: true)
        XCTAssertEqual(all.hidden, 0)
        XCTAssertEqual(all.sections.first?.rows.map(\.text), ["Top of the page", "Check this"])
        XCTAssertEqual(all.sections.first?.rows.last?.count, 2)
        XCTAssertEqual(all.sections.first?.rows.last?.resolved, true)
    }

    func testMenusPinToTheSelectionAndHideEditsInReadOnly() {
        let h = harness()
        let selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.imageID],
                                  bounds: Rect(x: 320, y: 480, width: 64, height: 64))
        var ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1,
                              selection: selection, itemKinds: [.image])
        XCTAssertTrue(CommentMenus.canAddOnSelection(ctx))
        XCTAssertEqual(CommentMenus.objectParams(ctx)["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01")
        ctx.selection.items.append(Fixtures.textID)
        XCTAssertNil(CommentMenus.objectParams(ctx)["ref"])
        XCTAssertEqual(CommentMenus.objectParams(ctx)["at"], [384, 480])

        let threadMenu = CommentMenus.context(app: h.app, session: h.session, ref: threadRef)
        XCTAssertEqual(h.app.ui.menuItems(.comment, threadMenu).map(\.id),
                       [CommentMenus.resolveID, "comments.thread.reveal", "comments.thread.delete"])
        h.session.readOnly = true
        XCTAssertFalse(CommentMenus.canAddOnSelection(ctx))
        XCTAssertEqual(h.app.ui.menuItems(.comment, threadMenu).map(\.id), ["comments.thread.reveal"])
    }

    func testPanelsRenderInEveryState() throws {
        let h = harness()
        let list = try XCTUnwrap(h.app.ui.panels.get(CommentPanels.list))
        let threadPanel = try XCTUnwrap(h.app.ui.panels.get(CommentPanels.thread))
        XCTAssertEqual(list.placement, .sidebarTab)
        XCTAssertEqual(threadPanel.placement, .floating)
        let state = try XCTUnwrap(CommentsState.of(h.app.services))
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        let targets: [CommentsState.Target?] = [
            nil,
            .thread(doc: Fixtures.docID, page: Fixtures.page1, id: Fixtures.commentID),
            .draft(CommentsState.Draft(doc: Fixtures.docID, page: Fixtures.page1, at: Point(10, 10), parent: nil)),
        ]
        for target in targets {
            state.focus(target, in: h.session)
            for panel in [list, threadPanel] {
                let host = UIHostingController(rootView: panel.makeView(context))
                let size = host.sizeThatFits(in: CGSize(width: 344, height: 560))
                XCTAssertGreaterThan(size.height, 0, panel.id)
            }
        }
    }

    func testCommentLinksRoundTripAndMessageLinksAreDetected() throws {
        let url = try XCTUnwrap(CommentLink.url(doc: Fixtures.docID, page: Fixtures.page1, comment: Fixtures.commentID))
        XCTAssertEqual(url.absoluteString, "nib://open/FIXTUREDOC01/FIXTUREPG001?comment=FIXTURECMT01")
        let parsed = try XCTUnwrap(CommentLink.parse(url))
        XCTAssertEqual(parsed.doc, Fixtures.docID)
        XCTAssertEqual(parsed.page, Fixtures.page1)
        XCTAssertEqual(parsed.comment, Fixtures.commentID)
        XCTAssertNil(CommentLink.parse(try XCTUnwrap(URL(string: "nib://open/FIXTUREDOC01/FIXTUREPG001"))))
        XCTAssertNil(CommentLink.parse(try XCTUnwrap(URL(string: "https://example.com/open/A/B?comment=C"))))

        let text = "See \(url.absoluteString). Also https://example.com/units, thanks"
        XCTAssertEqual(CommentText.links(in: text).map { $0.url.absoluteString },
                       [url.absoluteString, "https://example.com/units"])
        XCTAssertTrue(CommentText.links(in: "no links *here*").isEmpty)
        let attributed = CommentText.attributed("Read https://example.com now")
        XCTAssertEqual(attributed.runs.compactMap { $0.link?.absoluteString }, ["https://example.com"])
    }

    func testHitPrefersTheNearestVisiblePinAndGrowsWhenZoomedOut() {
        let a = Item.makeComment(CommentItem(anchor: Point(100, 100), messages: []))
        let b = Item.makeComment(CommentItem(anchor: Point(112, 100), messages: []))
        let resolved = Item.makeComment(CommentItem(anchor: Point(108, 100), messages: [], resolved: true))
        let items = [a, b, resolved]
        XCTAssertEqual(CommentRules.hit(items, at: Point(109, 100), radius: 22, showResolved: false)?.id, b.id)
        XCTAssertEqual(CommentRules.hit(items, at: Point(109, 100), radius: 22, showResolved: true)?.id, resolved.id)
        XCTAssertNil(CommentRules.hit([a], at: Point(140, 100), radius: CommentRules.hitRadius(zoom: 2), showResolved: false))
        XCTAssertNotNil(CommentRules.hit([a], at: Point(140, 100), radius: CommentRules.hitRadius(zoom: 0.5),
                                         showResolved: false))
        XCTAssertEqual(CommentRules.clamp(Point(-5, 900), to: .a4), Point(0, 841.89))
        XCTAssertEqual(CommentRules.defaultAnchor(size: .a4, visible: nil), Point(595.28 - 36, 36))
        XCTAssertEqual(CommentRules.defaultAnchor(size: .a4, visible: Rect(x: 0, y: 100, width: 200, height: 300)),
                       Point(100, 250))
    }
}
