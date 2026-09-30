import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatSearchUI

@MainActor
final class FeatSearchUITests: XCTestCase {
    private func hit(_ page: PageID = Fixtures.page1, kind: String = "typed", doc: DocumentID = Fixtures.docID,
                     docKind: String = "notebook", text: String = "Hello notes") -> SearchMatch {
        SearchMatch(ref: NodeRef.page(doc, page).description, doc: NodeRef.document(doc).description,
            page: NodeRef.page(doc, page).description, pageIndex: page == Fixtures.page1 ? 0 : 1,
            title: "Fixture", docKind: docKind, kind: kind, text: text, snippet: text,
            rect: Rect(x: 72, y: 120, width: 210, height: 30), itemIDs: [], score: 1)
    }
    private func installDependencies(_ h: Harness, hits: [SearchMatch]) {
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search", summary: "Test index query.",
            params: .obj(["query": .str(), "scope": .str(), "limit": .int(), "cursor": .str()], required: ["query"]), effect: .read)) { _, _ in
                try JSONValue.from(SearchResponse(results: hits, total: hits.count, truncated: false))
            }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Test library query.",
            params: .obj(["ref": .ref], required: ["ref"]), effect: .read)) { p, _ in
                guard let ref = p["ref"]?.stringValue, let doc = NodeRef(ref)?.documentID,
                      let node = h.library.node(doc) else { throw NibError.notFound("document") }
                return ["ref": .string(ref), "title": .string(node.title), "kind": "notebook"]
            }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open Panel", summary: "Test panel host.",
            params: .anything(), effect: .session)) { p, ctx in
                if let id = p["id"]?.stringValue { ctx.activeSession?.openPanels.insert(id) }
                return [:]
            }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelClose, title: "Close Panel", summary: "Test panel host.",
            params: .anything(), effect: .session)) { p, ctx in
                if let id = p["id"]?.stringValue { ctx.activeSession?.openPanels.remove(id) }
                return [:]
            }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.docOpen, title: "Open Document", summary: "Test document navigator.",
            params: .anything(), effect: .session)) { p, ctx in
                ctx.activeSession?.document = p["doc"]?.stringValue.flatMap { NodeRef($0)?.documentID }
                ctx.activeSession?.page = p["page"]?.stringValue.flatMap { NodeRef($0)?.pageID }
                return [:]
            }
    }

    func testRecentsDeduplicateCapAndIgnoreOldOpen() {
        var recents = Recents()
        for n in 0..<25 { recents.record(DocumentID("RECENT\(n)"), at: Double(n)) }
        XCTAssertEqual(recents.documents.count, 20)
        XCTAssertEqual(recents.documents.first?.id, "RECENT24")
        XCTAssertEqual(recents.documents.last?.id, "RECENT5")
        recents.record("RECENT10", at: 40)
        recents.record("RECENT10", at: 2)
        XCTAssertEqual(recents.documents.first?.id, "RECENT10")
        XCTAssertEqual(recents.documents.filter { $0.id == "RECENT10" }.count, 1)
    }

    func testGroupPrecedenceAndEveryRequiredSection() {
        XCTAssertEqual(hit(kind: "title", docKind: "whiteboard").group, .titles)
        XCTAssertEqual(hit(kind: "outline", docKind: "whiteboard").group, .outlines)
        XCTAssertEqual(hit(kind: "transcript", docKind: "textDocument").group, .transcripts)
        XCTAssertEqual(hit(kind: "ink", docKind: "studySet").group, .studySets)
        XCTAssertEqual(hit(docKind: "whiteboard").group, .whiteboards)
        XCTAssertEqual(hit(kind: "pdf").group, .pdfs)
        XCTAssertEqual(hit(kind: "ink").group, .written)
        XCTAssertEqual(hit().group, .typed)
        XCTAssertEqual(SearchGroup.allCases.count, 8)
        XCTAssertTrue(SearchFilter.cards.includes(hit(docKind: "studySet")))
        XCTAssertFalse(SearchFilter.pdf.includes(hit()))
    }

    func testResultNavigatesExactPageRectAndDoesNotCreateUndoSteps() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let hits = [hit(), hit(Fixtures.page2)]
        installDependencies(h, hits: hits)
        let editor = SearchTestEditor(h)
        h.session.editor = editor
        let depths = h.undoDepths()
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        try await h.run(CommandIDs.searchOpen, ["scope": "doc:FIXTUREDOC01", "match": 1])
        XCTAssertEqual(h.session.page, Fixtures.page2)
        XCTAssertEqual(editor.lastPage, Fixtures.page2)
        XCTAssertEqual(editor.lastRect, hits[1].rect)
        XCTAssertFalse(editor.animated)
        XCTAssertEqual(h.undoDepths(), depths)
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(state.selectedIndex, 1)
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(h.session.page, Fixtures.page1)
        try await h.run(CommandIDs.searchStep, ["direction": "previous"])
        XCTAssertEqual(h.session.page, Fixtures.page2)
        XCTAssertEqual(h.undoDepths(), depths)
    }

    func testLibraryResultOpensAnotherDocumentAtItsBoardAndFlashesMatch() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let result = hit(Fixtures.boardID, doc: Fixtures.whiteboardID, docKind: "whiteboard")
        installDependencies(h, hits: [result])
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Hello"])
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "match": 0])
        XCTAssertEqual(h.session.document, Fixtures.whiteboardID)
        XCTAssertEqual(h.session.page, Fixtures.boardID)
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(state.flashID, result.id)
        XCTAssertGreaterThan(try XCTUnwrap(state.flashUntil), Date())
        XCTAssertFalse(state.isPresented)
    }

    func testEmptySearchAndSteppingDoNotOpenDocuments() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "missing"])
        let before = h.session.page
        let result = try await h.run(CommandIDs.searchStep, ["direction": "previous"])
        XCTAssertEqual(result["count"]?.intValue, 0)
        XCTAssertEqual(h.session.page, before)
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "close": true])
        XCTAssertFalse(SearchRuntime.from(h.app).state(h.session).isPresented)
        XCTAssertFalse(h.session.openPanels.contains(SearchOpen.documentPanel))
    }

    func testFiltersAndWindowsStayIndependent() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit(), hit(Fixtures.page2, kind: "ink")])
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello", "filter": "handwriting"])
        let second = EditorSession()
        second.document = Fixtures.textDocID
        h.app.services.sessions.add(second)
        try await h.app.bus.execute(CommandIDs.searchOpen,
            ["scope": "document", "query": "other"], session: second)
        let runtime = SearchRuntime.from(h.app)
        XCTAssertEqual(runtime.state(h.session).query, "Hello")
        XCTAssertEqual(runtime.state(h.session).visibleMatches.count, 1)
        XCTAssertEqual(runtime.state(second).scope, "doc:FIXTUREDOC02")
        XCTAssertEqual(runtime.state(second).filter, .all)
    }

    func testTypedIndexProgressAndRecentEventPersistence() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        let state = runtime.state(h.session)
        let opened = h.app.events.emit(NibEventType.docOpened, doc: Fixtures.docID)
        await runtime.receive(opened)
        XCTAssertEqual(runtime.recents.documents.first?.doc, Fixtures.docID)
        XCTAssertNotNil(h.app.settings.json(SearchRuntime.recentPrefix + Fixtures.docID.raw)?.doubleValue)
        let progress = h.app.events.emit(IndexProgressPayload(running: true, done: 2, total: 30, pending: 28))
        await runtime.receive(progress)
        XCTAssertEqual(state.progress, IndexProgressPayload(running: true, done: 2, total: 30, pending: 28))
        XCTAssertEqual(state.remainingPages, 28)
        let malformed = h.app.events.emit(NibEventType.indexProgress, payload: ["running": "invalid"])
        await runtime.receive(malformed)
        XCTAssertEqual(state.remainingPages, 28)
        await runtime.receive(h.app.events.emit(IndexProgressPayload(running: false, done: 30, total: 30, pending: 0)))
        XCTAssertFalse(state.isIndexing)
        try await h.run(CommandIDs.searchOpen, ["scope": "lib"])
        XCTAssertEqual(state.recentRows.map(\.ref), ["doc:FIXTUREDOC01"])
    }

    func testPaginationAndDeduplication() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let first = hit()
        let second = hit(Fixtures.page2)
        var calls = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search", summary: "Paged index fake.",
            params: .anything(), effect: .read)) { params, _ in
                calls += 1
                if params["cursor"] == nil {
                    return try JSONValue.from(SearchResponse(results: [first], total: 2, truncated: true, cursor: "next"))
                }
                return try JSONValue.from(SearchResponse(results: [first, second], total: 2, truncated: false))
            }
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(SearchRuntime.from(h.app).state(h.session).matches.count, 2)
    }

    func testLateQueryResponseCannotReplaceNewResults() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        var release: CheckedContinuation<Void, Never>?
        let old = hit(text: "old")
        let new = hit(text: "new")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search", summary: "Delayed index fake.",
            params: .anything(), effect: .read)) { params, _ in
                if params["query"]?.stringValue == "old" {
                    await withCheckedContinuation { release = $0 }
                    return try JSONValue.from(SearchResponse(results: [old], total: 1, truncated: false))
                }
                return try JSONValue.from(SearchResponse(results: [new], total: 1, truncated: false))
            }
        let pending = Task { try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "old"]) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let release else { XCTFail("Old query did not suspend"); pending.cancel(); return }
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "new"])
        release.resume()
        _ = try await pending.value
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(state.matches.map(\.text), ["new"])
        XCTAssertFalse(state.loading)
    }

    func testHighlightsTransformAndHideDuringLiveInk() {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let host = FakeCanvasHost(h)
        host.zoomScale = 2
        let state = SearchRuntime.from(h.app).state(h.session)
        state.matches = [hit(Fixtures.page2)]
        state.isPresented = true
        let attachment = SearchHighlights(state: state)
        attachment.attach(to: host)
        let wash = attachment.layer.sublayers?.first as? CAShapeLayer
        XCTAssertEqual(wash?.path?.boundingBox.minX, 144)
        XCTAssertEqual(wash?.path?.boundingBox.width, 420)
        h.session.inking.begin()
        XCTAssertTrue(attachment.layer.sublayers?.isEmpty ?? true)
        h.session.inking.end()
        XCTAssertEqual(attachment.layer.sublayers?.count, 1)
        attachment.detach(from: host)
        XCTAssertNil(attachment.layer.superlayer)
    }

    func testExternalPanelDismissalClearsHighlightsButKeepsQuery() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit()])
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertTrue(state.isPresented)
        h.session.openPanels.remove(SearchOpen.documentPanel)
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.query, "Hello")
    }

    func testInvalidMatchAndScopeAreRejected() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit()])
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        for params: JSONValue in [["scope": "document", "match": 99], ["scope": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"]] {
            do {
                try await h.run(CommandIDs.searchOpen, params)
                XCTFail("Invalid parameters were accepted")
            } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        }
    }

    func testCommandConformanceAndKeyboardRegistrations() async {
        let problems = await CommandConformance.check(features: [FeatSearchUIFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatSearchUIFeature.self])
        let keys = h.app.content.keyCommands.all.filter { $0.owner == "searchui" }
        XCTAssertEqual(keys.count, 4)
        XCTAssertEqual(keys.filter { $0.shortcut.key == "g" }.count, 2)
        XCTAssertEqual(keys.first { $0.scope == .library }?.params["instant"], true)
        XCTAssertEqual(h.app.commands.all().filter { $0.owner == "searchui" }.map(\.id), ["search.open", "search.step"])
    }

    func testResultSnapshotsAcrossThemesAndAccessibility() {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.query = "Hello"
        state.matches = [hit()]
        let row = SearchResultRow(app: h.app, session: h.session, state: state, hit: hit())
        for variant in NibSnapshot.Variant.allCases {
            if let image = NibSnapshot.image(row, size: CGSize(width: 344, height: 240), variant: variant) {
                let attachment = XCTAttachment(image: image)
                attachment.name = "Search result " + variant.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Search result snapshot did not render") }
            let results = SearchResults(app: h.app, session: h.session, state: state)
            if let image = NibSnapshot.image(results, size: CGSize(width: 560, height: 600), variant: variant) {
                let attachment = XCTAttachment(image: image)
                attachment.name = "Library search " + variant.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Search results snapshot did not render") }
            let panel = DocumentSearchPanel(app: h.app, session: h.session, state: state)
            if let image = NibSnapshot.image(panel, size: CGSize(width: 344, height: 600), variant: variant) {
                let attachment = XCTAttachment(image: image)
                attachment.name = "Document search " + variant.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Document search snapshot did not render") }
        }
    }
}

@MainActor
private final class SearchTestEditor: DocumentEditing {
    let session: EditorSession
    var documentID: DocumentID { session.document ?? Fixtures.docID }
    var canvasHost: CanvasHost? { nil }
    var lastPage: PageID?
    var lastRect: Rect?
    var animated = false
    init(_ h: Harness) { session = h.session }
    func reveal(page: PageID, rect: Rect?, animated: Bool) { lastPage = page; lastRect = rect; self.animated = animated }
    func reloadAll() {}
}
