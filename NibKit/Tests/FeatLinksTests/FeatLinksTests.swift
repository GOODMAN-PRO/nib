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

        let removed = try await h.run("link.remove", ["ref": .string(textRef), "range": [7, 0]])
        XCTAssertEqual(removed["removed"]?.intValue, 1)
        XCTAssertEqual(try fixtureText(h), original)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try fixtureText(h), linked)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try fixtureText(h), linked)
    }

    func testPageAndAudioLinksResolveRefsAndBadInputIsRefused() async throws {
        let h = harness()
        try await h.run("link.set", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "range": [0, 8],
                                     "link": ["page": "FIXTUREPG002"]])
        let sticky = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        XCTAssertEqual(sticky.sticky?.text.paragraphs.first?.runs.first?.attrs.link,
                       TextLink(document: Fixtures.docID, page: Fixtures.page2))

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
        let whole = try LinkEditorPresenter.makeTarget(ref: "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", range: nil,
                                                       editing: nil, workspace: h.app.workspace)
        XCTAssertEqual(whole.range, NSRange(location: 0, length: 8))
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
}
