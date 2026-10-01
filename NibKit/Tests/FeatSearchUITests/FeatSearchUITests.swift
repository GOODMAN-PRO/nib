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
                // F003 loads content and emits this event on its first document read.
                h.app.events.emit(NibEventType.docOpened, doc: doc)
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
                let session = ctx.activeSession
                // Match the shell's async openGate path instead of hiding it with a synchronous switch.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    session?.document = p["doc"]?.stringValue.flatMap { NodeRef($0)?.documentID }
                    session?.page = p["page"]?.stringValue.flatMap { NodeRef($0)?.pageID }
                }
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
        let editor = SearchTestEditor(h)
        h.session.editor = editor
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Hello"])
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "match": 0])
        XCTAssertEqual(h.session.document, Fixtures.whiteboardID)
        XCTAssertEqual(h.session.page, Fixtures.boardID)
        XCTAssertEqual(editor.lastPage, Fixtures.boardID)
        XCTAssertEqual(editor.lastRect, result.rect)
        XCTAssertFalse(editor.animated)
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
                XCTAssertEqual(params["limit"]?.intValue, 100)
                if params["cursor"] == nil {
                    return try JSONValue.from(SearchResponse(results: [first], total: 2, truncated: true, cursor: "next"))
                }
                return try JSONValue.from(SearchResponse(results: [first, second], total: 2, truncated: false))
            }
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(state.matches.count, 1)
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "match": 0])
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(state.matches.count, 2)
        XCTAssertEqual(state.selectedID, second.id)
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

    func testRecentsUseCatalogWithoutQueryGetAndIgnoreBackgroundReads() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        // Drain replay first so initial fixture opens cannot overwrite the test's timestamps.
        for _ in 0..<20 { await Task.yield() }
        runtime.recents.record(Fixtures.docID, at: Date().timeIntervalSince1970 + 1)
        runtime.recents.record(Fixtures.textDocID, at: Date().timeIntervalSince1970 + 2)
        runtime.recents.record(Fixtures.whiteboardID, at: Date().timeIntervalSince1970 + 3)
        let before = runtime.recents.documents
        var reads = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Emitting read fake.",
            params: .anything(), effect: .read)) { p, _ in
                reads += 1
                let doc = p["ref"]?.stringValue.flatMap { NodeRef($0)?.documentID }
                h.app.events.emit(NibEventType.docOpened, doc: doc)
                return ["title": "A read"]
            }
        try await h.run(CommandIDs.searchOpen, ["scope": "lib"])
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "refresh": true])
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(runtime.recents.documents, before)
        XCTAssertEqual(runtime.state(h.session).recentRows.map(\.ref), before.map { NodeRef.document($0.doc).description })
        // Actually exercise the emitting fake for a background document read.
        try await h.run(CommandIDs.queryGet, ["ref": "doc:FIXTUREDOC02"])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(runtime.recents.documents, before)
        XCTAssertFalse(runtime.recents.documents.contains { $0.doc == Fixtures.studySetID })
    }

    func testReopeningCachedDocumentMovesItToTop() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        for _ in 0..<20 { await Task.yield() }
        _ = try h.app.workspace.content(Fixtures.docID)
        _ = try h.app.workspace.content(Fixtures.textDocID)
        h.session.document = Fixtures.textDocID
        for _ in 0..<20 { await Task.yield() }
        h.session.document = Fixtures.docID
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(runtime.recents.documents.first?.doc, Fixtures.docID)
        try await h.run(CommandIDs.searchOpen, ["scope": "lib"])
        XCTAssertEqual(runtime.state(h.session).recentRows.first?.ref, "doc:FIXTUREDOC01")
    }

    func testRecentsExcludeTrashedLockedAndMissingCatalogEntries() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        for _ in 0..<20 { await Task.yield() }
        for (index, doc) in Fixtures.allDocuments.enumerated() { runtime.recents.record(doc, at: Double(index)) }
        runtime.recents.record("MISSINGDOC", at: 100)
        runtime.recents.record(Fixtures.folderID, at: 101)
        try h.library.trash(Fixtures.textDocID)
        let lock = FakeLockService()
        lock.locked.insert(Fixtures.studySetID)
        h.app.services.lock = lock
        try await h.run(CommandIDs.searchOpen, ["scope": "lib"])
        XCTAssertEqual(Set(runtime.state(h.session).recentRows.map(\.ref)), ["doc:FIXTUREDOC01", "doc:FIXTUREDOC04"])
    }

    func testDocumentSwitchRescopesKeepsQueryAndStepCannotOpenOldDocument() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit()])
        let runtime = SearchRuntime.from(h.app)
        try await h.run(CommandIDs.searchOpen, ["scope": "page:FIXTUREDOC01/FIXTUREPG001", "query": "Hello"])
        let state = runtime.state(h.session)
        h.session.document = Fixtures.textDocID
        XCTAssertEqual(state.scope, "doc:FIXTUREDOC02")
        XCTAssertEqual(state.query, "Hello")
        XCTAssertTrue(state.matches.isEmpty)
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(h.session.document, Fixtures.textDocID)
        // Even a stale or malformed backend hit must not take Command-G back to A.
        state.matches = [hit()]
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(h.session.document, Fixtures.textDocID)
        h.session.document = nil
        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.matches.isEmpty)
    }

    func testQueryAndMatchInOneCallSelectNewQuery() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let old = hit(text: "old")
        let new = hit(Fixtures.page2, text: "new")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search", summary: "Query-aware fake.",
            params: .anything(), effect: .read)) { p, _ in
                let result = p["query"]?.stringValue == "new" ? new : old
                return try JSONValue.from(SearchResponse(results: [result], total: 1, truncated: false))
            }
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "old"])
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "new", "match": 0])
        XCTAssertEqual(h.session.page, Fixtures.page2)
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(state.selectedID, new.id)
        XCTAssertEqual(state.matches, [new])
    }

    func testCommitsDoNotRefreshAndIndexCompletionCoalescesWhileInking() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        for _ in 0..<20 { await Task.yield() }
        var calls = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search", summary: "Counting index fake.",
            params: .anything(), effect: .read)) { _, _ in
                calls += 1
                return try JSONValue.from(SearchResponse(results: [self.hit()], total: 1, truncated: false))
            }
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        for _ in 0..<30 { h.app.events.emit(NibEventType.committed, doc: Fixtures.docID) }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(calls, 1, "Pen commits must not bypass the indexer's debounce")
        h.session.inking.begin()
        for _ in 0..<10 { h.app.events.emit(IndexProgressPayload(running: false, done: 1, total: 1, pending: 0), doc: Fixtures.docID) }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(calls, 1)
        h.session.inking.end()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(calls, 2)
        h.app.events.emit(IndexProgressPayload(running: false, done: 1, total: 1, pending: 0), doc: Fixtures.textDocID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(calls, 2, "Another document is outside this search scope")
    }

    func testTypingDebouncesAndCloseCancelsPendingWork() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        let state = runtime.state(h.session)
        try await h.run(CommandIDs.searchOpen, ["scope": "document"])
        var queries: [String] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search", summary: "Typing fake.",
            params: .anything(), effect: .read)) { p, _ in
                queries.append(p["query"]?.stringValue ?? "")
                return try JSONValue.from(SearchResponse(results: [], total: 0, truncated: false))
            }
        let binding = searchBinding(app: h.app, session: h.session, state: state)
        for query in ["h", "he", "hel", "hello"] { binding.wrappedValue = query }
        XCTAssertEqual(state.query, "hello")
        XCTAssertTrue(queries.isEmpty)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(queries, ["hello"])
        binding.wrappedValue = "closed"
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "close": true])
        try await Task.sleep(nanoseconds: 250_000_000)
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "refresh": true])
        XCTAssertEqual(queries, ["hello"])
        XCTAssertFalse(state.isPresented)
    }

    func testDistinctRectanglesAreNotDeduplicated() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let first = hit()
        var second = first
        second.rect = Rect(x: 72, y: 240, width: 210, height: 30)
        XCTAssertNotEqual(first.id, second.id)
        installDependencies(h, hits: [first, first, second])
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(state.matches, [first, second])
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(state.selectedID, second.id)
    }

    func testTranscriptResultSeeksAndPlaysMatchedTime() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        var transcript = hit(kind: "transcript")
        transcript.ref = "audio:FIXTUREDOC01/FIXTUREAUD01"
        transcript.time = 42
        installDependencies(h, hits: [transcript])
        var played: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.audioPlay, title: "Play", summary: "Playback fake.",
            params: .anything(), effect: .session)) { p, _ in played = p; return [:] }
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Hello", "match": 0])
        XCTAssertEqual(played?["clip"]?.stringValue, transcript.ref)
        XCTAssertEqual(played?["t"]?.doubleValue, 42)
    }

    func testOutOfOrderEventsAreStillReceived() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        // No stream watcher: deliver the events in reverse sequence explicitly.
        let runtime = SearchRuntime(app: h.app)
        let opened = h.app.events.emit(NibEventType.sessionDocument, doc: Fixtures.textDocID)
        let progress = h.app.events.emit(IndexProgressPayload(running: false, done: 10, total: 10, pending: 0))
        await runtime.receive(progress)
        await runtime.receive(opened)
        XCTAssertEqual(runtime.recents.documents.first?.doc, Fixtures.textDocID)
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
