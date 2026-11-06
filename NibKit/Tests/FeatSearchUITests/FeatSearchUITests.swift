import XCTest
import SwiftUI
import UIKit
import NibContracts
@testable import NibDesign
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

    func testTitleMatchesShowOneHighlightedHeadingAndDocumentMetadata() {
        var result = hit(kind: "title", docKind: "studySet")
        result.title = "Café notes: CAFÉ revision"
        result.snippet = result.title
        let heading = result.heading(query: "cafe")
        XCTAssertEqual(String(heading.characters), result.title)
        let highlights = heading.runs.filter { $0.backgroundColor == NibColor.accentWash }
        XCTAssertEqual(highlights.map { String(heading[$0.range].characters) }, ["Café", "CAFÉ"])
        XCTAssertNil(result.detailSnippet, "A title match must not repeat its heading as a snippet")
        XCTAssertEqual(result.documentKindLabel, "Study set")

        result.kind = "typed"
        result.snippet = "Notes from the café"
        XCTAssertEqual(result.detailSnippet, "Notes from the café")
        XCTAssertTrue(result.heading(query: "cafe").runs.allSatisfy { $0.backgroundColor == nil },
            "Content matches highlight the snippet, not the document heading")
    }

    func testTitleIdentityUsesDocumentKindAndSafeUnknownFallback() {
        let cases: [(String, NibSymbol, String, String)] = [
            ("notebook", .notebook, "Untitled notebook", "Notebook"),
            ("whiteboard", .whiteboard, "Untitled whiteboard", "Whiteboard"),
            ("textDocument", .textDocument, "Untitled text document", "Text document"),
            ("studySet", .studySets, "Untitled study set", "Study set"),
            ("unknown", .library, "Untitled document", "Document")
        ]
        for (kind, symbol, fallback, metadata) in cases {
            var result = hit(kind: "title", docKind: kind)
            XCTAssertEqual(result.symbol, symbol)
            XCTAssertEqual(result.documentKindLabel, metadata)
            XCTAssertEqual(result.displayTitle, "Fixture")
            for title in ["", " \n "] {
                result.title = title
                XCTAssertEqual(result.displayTitle, fallback)
                XCTAssertNil(result.detailSnippet)
            }
        }
        XCTAssertEqual(hit(kind: "pdf").symbol, .pdf)
        XCTAssertEqual(hit(kind: "ink").symbol, .pen)
        XCTAssertEqual(hit(kind: "typed", docKind: "textDocument").symbol, .text)
    }

    func testSearchFieldPromptFollowsScope() {
        let state = SearchState()
        for scope in ["lib", "folder:FOLDER01"] {
            state.scope = scope
            XCTAssertEqual(state.searchPrompt, "Search your notes")
        }
        for scope in ["document", NodeRef.document(Fixtures.docID).description,
                      NodeRef.page(Fixtures.docID, Fixtures.page1).description] {
            state.scope = scope
            XCTAssertEqual(state.searchPrompt, "Find in this document")
        }
    }

    func testSearchContinuationExplainsClippedRowsAndDisappearsAtTheEnd() {
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBottom: 400, viewportHeight: 0))
        XCTAssertTrue(SearchScrollContinuation.isVisible(contentBottom: 400, viewportHeight: 160))
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBottom: 160, viewportHeight: 160))
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBottom: 120, viewportHeight: 160))
    }

    func testContinuationUsesContentAndViewportFromTheSameLayout() {
        let content = CGRect(x: 0, y: 40, width: 400, height: 600)
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBounds: content, viewportBounds: .zero))
        // A first viewport measurement must show overflow without any content movement or scroll.
        XCTAssertTrue(SearchScrollContinuation.isVisible(contentBounds: content,
            viewportBounds: CGRect(x: 0, y: 40, width: 400, height: 300)))
        // Resizing alone can remove or restore the cue.
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBounds: content,
            viewportBounds: CGRect(x: 0, y: 40, width: 400, height: 600)))
        XCTAssertTrue(SearchScrollContinuation.isVisible(contentBounds: content,
            viewportBounds: CGRect(x: 0, y: 40, width: 400, height: 200)))
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBounds: content.offsetBy(dx: 0, dy: -400),
            viewportBounds: CGRect(x: 0, y: 40, width: 400, height: 200)))
        XCTAssertFalse(SearchScrollContinuation.isVisible(contentBounds: nil,
            viewportBounds: CGRect(x: 0, y: 40, width: 400, height: 200)))
    }

    func testMatchControlsDisableForEmptyPendingFailedAndFilteredResults() {
        let state = SearchState()
        state.scope = NodeRef.document(Fixtures.docID).description
        XCTAssertFalse(state.canStepMatches)
        state.query = "Hello"
        XCTAssertFalse(state.canStepMatches)
        state.matches = [hit()]
        state.reconcileSelection()
        XCTAssertTrue(state.canStepMatches, "A single result can still be revealed by the existing command")
        state.refreshPending = true
        XCTAssertTrue(state.canStepMatches, "A queued background refresh must not disable existing matches")
        XCTAssertNil(state.emptyPresentation)
        state.loading = true
        XCTAssertFalse(state.canStepMatches)
        state.loading = false
        state.error = "Search unavailable"
        XCTAssertFalse(state.canStepMatches)
        state.error = nil
        state.filter = .pdf
        XCTAssertFalse(state.canStepMatches)
        state.filter = .all
        XCTAssertTrue(state.canStepMatches)
        state.query = " \n "
        XCTAssertFalse(state.canStepMatches)
        state.query = "Hello"
        state.matches.append(hit(Fixtures.page2))
        for result in state.matches {
            state.selectedID = result.id
            XCTAssertTrue(state.canStepMatches, "Navigation wraps at both ends")
        }
    }

    func testCountLabelResolvesInflectionForZeroOneAndMultipleMatches() {
        let state = SearchState()
        for (count, expected) in [(0, "0 matches"), (1, "1 match"), (3, "3 matches")] {
            state.matches = (0..<count).map { hit(text: "Match \($0)") }
            XCTAssertEqual(state.countLabel, expected)
        }
    }

    func testCountLabelUsesFilteredMatchesAndPreservesSelectedPosition() {
        let state = SearchState()
        let first = hit(text: "First typed match")
        let handwriting = hit(kind: "ink")
        let last = hit(text: "Last typed match")
        state.matches = [first, handwriting, last]
        state.selectedID = last.id
        XCTAssertEqual(state.countLabel, "3 of 3")

        state.filter = .typed
        XCTAssertEqual(state.countLabel, "2 of 2")
        state.selectedID = first.id
        XCTAssertEqual(state.countLabel, "1 of 2")
        state.selectedID = nil
        XCTAssertEqual(state.countLabel, "2 matches")

        state.selectedID = handwriting.id
        XCTAssertEqual(state.countLabel, "2 matches", "A filtered-out selection shows the visible count")
        state.filter = .handwriting
        XCTAssertEqual(state.countLabel, "1 of 1")
        state.selectedID = nil
        XCTAssertEqual(state.countLabel, "1 match")
        state.filter = .pdf
        XCTAssertEqual(state.countLabel, "0 matches")
    }

    func testDocumentCounterStartsAtFirstMatchAndTracksNavigationFilterAndRefresh() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let first = hit(text: "First")
        let ink = hit(Fixtures.page2, kind: "ink")
        let last = hit(Fixtures.page2, text: "Last")
        installDependencies(h, hits: [first, ink, last])
        let editor = SearchTestEditor(h)
        h.session.editor = editor
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertEqual(state.selectedID, first.id)
        XCTAssertEqual(state.countLabel, "1 of 3")
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(state.selectedID, ink.id)
        XCTAssertEqual(state.countLabel, "2 of 3")
        XCTAssertEqual(editor.lastPage, Fixtures.page2)
        try await h.run(CommandIDs.searchStep, ["direction": "previous"])
        XCTAssertEqual(state.countLabel, "1 of 3")
        try await h.run(CommandIDs.searchStep, ["direction": "previous"])
        XCTAssertEqual(state.selectedID, last.id)
        XCTAssertEqual(state.countLabel, "3 of 3")
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "refresh": true])
        XCTAssertEqual(state.selectedID, last.id, "Index refresh must preserve the active hit")
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "filter": "handwriting"])
        XCTAssertEqual(state.selectedID, ink.id, "Filtering out the current hit activates the first visible hit")
        XCTAssertEqual(state.countLabel, "1 of 1")
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "filter": "pdf"])
        XCTAssertNil(state.selectedID)
        XCTAssertEqual(state.countLabel, "0 matches")
        try await h.run(CommandIDs.searchOpen, ["scope": "document", "filter": "all"])
        XCTAssertEqual(state.countLabel, "1 of 3")
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Hello"])
        XCTAssertNil(state.selectedID, "Library results must not open or select a document automatically")
        XCTAssertEqual(state.countLabel, "3 matches")
    }

    func testSearchViewportUsesWindowOrientationAndSpecifiedWidths() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1024, height: 1366),
                     CGSize(width: 390, height: 834), CGSize(width: 600, height: 834)] {
            let width = size.width - 2 * NibMetrics.chromeInset
            XCTAssertEqual(SearchViewport.panelWidth(availableWidth: width, windowSize: size), width)
        }
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 1366, height: 1024)] {
            XCTAssertEqual(SearchViewport.panelWidth(availableWidth: size.width - 32, windowSize: size), 560)
            XCTAssertEqual(SearchViewport.panelWidth(availableWidth: 500, windowSize: size), 500)
        }
        // Keyboard visibility must not turn an iPad portrait window into a landscape search layout.
        let portrait = SearchViewport.measure(windowBounds: CGRect(x: 0, y: 0, width: 834, height: 1194),
            safeArea: .zero, frame: CGRect(x: 16, y: 100, width: 802, height: 1094),
            keyboard: CGRect(x: 0, y: 600, width: 834, height: 594))
        XCTAssertEqual(SearchViewport.panelWidth(availableWidth: 802, windowSize: portrait.windowSize), 802)
    }

    func testResultsEndAboveKeyboardAndSeparateNavigationRows() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                     CGSize(width: 390, height: 834)] {
            let bounds = CGRect(origin: .zero, size: size)
            let top: CGFloat = 100
            let keyboard = CGRect(x: 0, y: size.height - 350, width: size.width, height: 350)
            let column = CGRect(x: 16, y: top, width: size.width - 32, height: size.height - top)
            let viewport = SearchViewport.measure(windowBounds: bounds, safeArea: .zero,
                frame: column, keyboard: keyboard)
            let height = SearchViewport.resultsHeight(availableHeight: viewport.availableHeight, reservesNavigation: true)
            let resultsBottom = top + NibMetrics.barHeight + NibMetrics.minimumRestingGap + height
            XCTAssertGreaterThan(height, 0, "Results remain scrollable while the keyboard is shown")
            XCTAssertLessThanOrEqual(height, 600)
            XCTAssertLessThanOrEqual(resultsBottom + 2 * (NibMetrics.hitTarget + NibMetrics.minimumRestingGap),
                keyboard.minY - NibMetrics.minimumRestingGap,
                "Neither the match HUD nor the page HUD may overlap the results panel")
            let dryHeight = SearchViewport.resultsHeight(availableHeight: viewport.availableHeight, reservesNavigation: false)
            XCTAssertGreaterThan(dryHeight, height, "Library search does not reserve document HUD rows")
        }
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 100, reservesNavigation: true), 0)
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 2000, reservesNavigation: true), 600)
    }

    func testSearchWidthClampsOversizedProposalsToWindowMargins() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 600, height: 834),
                     CGSize(width: 390, height: 834), CGSize(width: 500, height: 400)] {
            let expected = size.width - 2 * NibMetrics.chromeInset
            for proposal in [size.width, size.width * 2, CGFloat.greatestFiniteMagnitude] {
                XCTAssertEqual(SearchViewport.panelWidth(availableWidth: proposal, windowSize: size), expected)
            }
            XCTAssertEqual(SearchViewport.panelWidth(availableWidth: 280, windowSize: size), 280,
                "A narrower host must remain authoritative")
        }
        XCTAssertEqual(SearchViewport.panelWidth(availableWidth: 2000,
            windowSize: CGSize(width: 1194, height: 834)), 560)
        XCTAssertEqual(SearchViewport.panelWidth(availableWidth: -10, windowSize: nil), 0)
        XCTAssertEqual(SearchViewport.panelWidth(availableWidth: 500, windowSize: .zero), 0)
    }

    func testLibrarySearchCentresInsideVisibleHostIntersection() {
        let window = CGRect(x: 0, y: 0, width: 834, height: 1194)
        for host in [window, CGRect(x: -200, y: 0, width: 1400, height: 1194),
                     CGRect(x: 100, y: 24, width: 600, height: 1100),
                     CGRect(x: 100, y: 24, width: 1000, height: 1100)] {
            let viewport = SearchViewport.measure(windowBounds: window, safeArea: .zero, frame: host, keyboard: nil)
            let bounds = SearchViewport.hostBounds(proposedSize: host.size, viewport: viewport)
            let visible = host.intersection(window)
            XCTAssertEqual(bounds.offsetBy(dx: host.minX, dy: host.minY), visible)
            let width = SearchViewport.panelWidth(availableWidth: bounds.width - 2 * NibMetrics.chromeInset,
                windowSize: viewport.windowSize)
            let left = host.minX + bounds.midX - width / 2
            XCTAssertEqual(left, visible.minX + NibMetrics.chromeInset)
            XCTAssertEqual(left + width, visible.maxX - NibMetrics.chromeInset)
        }
        XCTAssertEqual(SearchViewport.hostBounds(proposedSize: window.size, viewport: nil), window)
        let outside = SearchViewport.measure(windowBounds: window, safeArea: .zero,
            frame: window.offsetBy(dx: window.width, dy: 0), keyboard: nil)
        XCTAssertEqual(SearchViewport.hostBounds(proposedSize: window.size, viewport: outside), .zero)
    }

    func testLibrarySearchSurfaceStaysInsideMeasuredContentColumn() {
        let host = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let content = CGRect(x: 320, y: 80, width: 874, height: 754)
        let surface = SearchViewport.libraryContentBounds(hostBounds: host, column: content, hostOrigin: .zero)
        XCTAssertEqual(surface, content)
        XCTAssertFalse(surface.contains(CGPoint(x: 160, y: 300)), "sidebar stays usable")
        XCTAssertFalse(surface.contains(CGPoint(x: 900, y: 40)), "toolbar stays usable")
        XCTAssertTrue(surface.contains(CGPoint(x: 340, y: 90)), "banner/title cannot bleed through")
        let resized = CGRect(x: 0, y: 0, width: 834, height: 600)
        XCTAssertEqual(SearchViewport.libraryContentBounds(hostBounds: resized, column: content, hostOrigin: .zero),
            CGRect(x: 320, y: 80, width: 514, height: 520))
        XCTAssertEqual(SearchViewport.libraryContentBounds(hostBounds: host, column: nil, hostOrigin: .zero), host)
    }

    func testLibrarySearchConvertsGlobalColumnIntoInsetFloatingHost() {
        let host = CGRect(x: 0, y: 0, width: 900, height: 600)
        let origin = CGPoint(x: 70, y: 44)
        let globalColumn = CGRect(x: 390, y: 124, width: 800, height: 700)
        let surface = SearchViewport.libraryContentBounds(hostBounds: host, column: globalColumn, hostOrigin: origin)
        XCTAssertEqual(surface, CGRect(x: 320, y: 80, width: 580, height: 520))
        XCTAssertFalse(surface.contains(CGPoint(x: 160, y: 300)), "Inset hosts must still leave the sidebar usable")
        XCTAssertTrue(surface.contains(CGPoint(x: 325, y: 85)), "The leading edge must not reveal library text")
        XCTAssertEqual(SearchViewport.libraryContentBounds(hostBounds: host, column: nil, hostOrigin: origin), host)
    }

    func testLibrarySearchKeepsPortraitWidthWhenKeyboardChangesVisibleHeight() {
        let window = CGRect(x: 0, y: 0, width: 834, height: 1194)
        let keyboard = CGRect(x: 0, y: 600, width: 834, height: 594)
        let top = NibMetrics.barTopGap + NibMetrics.barHeight + NibMetrics.minimumRestingGap
        for keyboardFrame: CGRect? in [nil, keyboard, nil] {
            let viewport = SearchViewport.measure(windowBounds: window, safeArea: .zero,
                frame: window, keyboard: keyboardFrame)
            let bounds = SearchViewport.hostBounds(proposedSize: CGSize(width: 834, height: 700), viewport: viewport)
            XCTAssertEqual(bounds.midX, 417)
            XCTAssertEqual(SearchViewport.panelWidth(availableWidth: bounds.width - 32,
                windowSize: viewport.windowSize), 802)
            let height = SearchViewport.resultsHeight(availableHeight: min(bounds.height, viewport.availableHeight) - top,
                reservesNavigation: false)
            let bottom = top + NibMetrics.barHeight + NibMetrics.minimumRestingGap + height
            XCTAssertLessThanOrEqual(bottom, keyboardFrame.map { $0.minY - NibMetrics.minimumRestingGap } ?? bounds.maxY)
        }
    }

    func testSearchViewportIgnoresKeyboardOutsideItsWindowColumn() {
        let bounds = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let column = CGRect(x: 317, y: 100, width: 560, height: 734)
        let safe = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        let clear = SearchViewport.measure(windowBounds: bounds, safeArea: safe, frame: column, keyboard: nil)
        XCTAssertEqual(clear.availableHeight, 698)
        for keyboard in [CGRect(x: 0, y: 834, width: 1194, height: 350),
                         CGRect(x: 0, y: 400, width: 300, height: 300)] {
            XCTAssertEqual(SearchViewport.measure(windowBounds: bounds, safeArea: safe,
                frame: column, keyboard: keyboard), clear)
        }
        let floating = SearchViewport.measure(windowBounds: bounds, safeArea: safe, frame: column,
            keyboard: CGRect(x: 500, y: 400, width: 300, height: 300))
        XCTAssertEqual(floating.availableHeight, 284)
    }

    func testViewportReaderRespondsToKeyboardFrameAndDismissal() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        var measured: SearchViewport?
        let sensor = SearchViewportReader.Sensor { measured = $0 }
        sensor.frame = CGRect(x: 16, y: 100, width: 1162, height: 700)
        window.addSubview(sensor)
        sensor.layoutIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        let initial = try XCTUnwrap(measured)
        let keyboard = window.convert(CGRect(x: 0, y: 484, width: 1194, height: 350),
            to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard)])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(try XCTUnwrap(measured).availableHeight, 368)
        let hidden = window.convert(CGRect(x: 0, y: 834, width: 1194, height: 350),
            to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: hidden)])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(measured, initial)
        sensor.removeFromSuperview()
    }

    func testViewportReaderRecalculatesVisibleBoundsAfterHostAndWindowResize() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        var measured: SearchViewport?
        let sensor = SearchViewportReader.Sensor { measured = $0 }
        window.addSubview(sensor)
        defer { sensor.removeFromSuperview() }
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                     CGSize(width: 600, height: 834), CGSize(width: 834, height: 1194)] {
            window.frame = CGRect(origin: .zero, size: size)
            // An oversized, offset host must still centre in this window after rotation or Split View resizing.
            sensor.frame = CGRect(x: -100, y: 0, width: size.width + 200, height: size.height)
            sensor.setNeedsLayout()
            sensor.layoutIfNeeded()
            for _ in 0..<10 { await Task.yield() }
            let viewport = try XCTUnwrap(measured)
            XCTAssertEqual(viewport.windowSize, size)
            XCTAssertEqual(viewport.visibleBounds, CGRect(x: 100, y: 0, width: size.width, height: size.height))
            XCTAssertEqual(SearchViewport.panelWidth(availableWidth: sensor.bounds.width, windowSize: viewport.windowSize),
                size.width > size.height ? 560 : size.width - 32)
        }
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
        XCTAssertEqual(state.selectedID, first.id)
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(state.matches.count, 2)
        XCTAssertEqual(state.selectedID, second.id)
    }

    func testMatchPaginationStopsWhenDismissedReplacedOrCancelled() async throws {
        for interruption in ["dismiss", "replace", "cancel"] {
            let h = Harness(features: [FeatSearchUIFeature.self])
            installDependencies(h, hits: [])
            let first = hit()
            var release: CheckedContinuation<Void, Never>?
            var calls = 0
            h.app.commands.register(CommandDescriptor(id: CommandIDs.searchText, title: "Search",
                summary: "Suspend the next result page.", params: .anything(), effect: .read)) { params, _ in
                calls += 1
                if params["cursor"] != nil { await withCheckedContinuation { release = $0 } }
                return try JSONValue.from(SearchResponse(results: [first], total: 501, truncated: true, cursor: "next"))
            }
            try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
            try await h.run(CommandIDs.panelOpen, ["id": .string(SearchOpen.documentPanel)])
            let state = SearchRuntime.from(h.app).state(h.session)
            let pending = Task { try await h.run(CommandIDs.searchOpen, ["scope": "document", "match": 500]) }
            for _ in 0..<100 where release == nil { await Task.yield() }
            guard let release else { XCTFail("Pagination did not suspend"); pending.cancel(); return }
            switch interruption {
            case "dismiss":
                h.session.openPanels.remove(SearchOpen.documentPanel)
                XCTAssertFalse(state.isPresented)
                XCTAssertNotNil(state.cursor, "Exercise dismissal with a retained cursor")
            case "replace":
                // Same scope and text, but a newer search owns the visible results.
                state.generation += 1
                state.loading = false
            default:
                pending.cancel()
            }
            release.resume()
            _ = try await pending.value
            XCTAssertEqual(calls, 2, "The abandoned match must not request another page")
            XCTAssertEqual(state.matches, [first])
            XCTAssertNil(state.flashID, "The abandoned match must not navigate")
        }
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
        XCTAssertEqual(state.emptyPresentation, .searching)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(queries, ["hello"])
        XCTAssertEqual(state.emptyPresentation, .noResults("hello"))
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
        XCTAssertEqual(state.selectedID, first.id)
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(state.selectedID, second.id)
        try await h.run(CommandIDs.searchStep, ["direction": "next"])
        XCTAssertEqual(state.selectedID, first.id)
        try await h.run(CommandIDs.searchStep, ["direction": "previous"])
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
        // Exercise the full-screen phone panel's external-dismiss path on every test device.
        try await h.run(CommandIDs.panelOpen, ["id": .string(SearchOpen.documentPanel)])
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertTrue(state.isPresented)
        h.session.openPanels.remove(SearchOpen.documentPanel)
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.query, "Hello")
    }

    func testExternalLibraryPanelDismissalStopsPendingSearchAndKeepsQuery() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Physics"])
        try await h.run(CommandIDs.panelOpen, ["id": .string(SearchOpen.libraryPanel)])
        let state = SearchRuntime.from(h.app).state(h.session)
        let generation = state.generation
        state.loading = true
        h.session.openPanels.remove(SearchOpen.libraryPanel)
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.loading)
        XCTAssertGreaterThan(state.generation, generation)
        XCTAssertEqual(state.query, "Physics")
    }

    func testDocumentSearchUsesDedicatedSurfaceWithoutNavigatorTabs() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit()])
        let panel = try XCTUnwrap(h.app.ui.panels.get(SearchOpen.documentPanel))
        XCTAssertEqual(panel.placement, .fullScreen)
        XCTAssertTrue(panel.providesHeader)
        XCTAssertFalse(h.app.ui.panels.all.contains { $0.owner == "searchui" && $0.placement == .sidebarTab })
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get("searchui.document"))
        XCTAssertEqual(overlay.placement, .top)
        XCTAssertEqual(overlay.surface, .none)
        let counter = try XCTUnwrap(h.app.ui.chromeOverlays.get("searchui.counter"))
        XCTAssertEqual(counter.placement, .bottom, "Navigation lives outside the top results panel")
        XCTAssertEqual(counter.surface, .none, "The counter supplies its own HUD droplet")
        XCTAssertNil(h.app.ui.chromeOverlays.get("searchui.field"), "The field must not be hosted separately from results")
        let toolbar = try XCTUnwrap(h.app.ui.toolbar.get("searchui.find"))
        XCTAssertEqual(toolbar.isOn?(h.session), false)

        try await h.run(CommandIDs.searchOpen, ["scope": "document", "query": "Hello"])
        XCTAssertEqual(h.session.openPanels.contains(SearchOpen.documentPanel), SearchOpen.usesDocumentSheet)
        XCTAssertEqual(toolbar.isOn?(h.session), true)
        // iPad portrait is regular width; narrow Split View is compact. Both keep one surface.
        for compact in [false, true] {
            let context = ChromeContext(app: h.app, session: h.session, kind: .notebook, isCompact: compact)
            XCTAssertEqual(overlay.isVisible(context), !SearchOpen.usesDocumentSheet)
            XCTAssertEqual(counter.isVisible(context), !SearchOpen.usesDocumentSheet,
                "iPhone system search must not retain a floating match HUD")
        }

        try await h.run(CommandIDs.searchOpen, ["scope": "document", "close": true])
        let state = SearchRuntime.from(h.app).state(h.session)
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.query, "Hello")
        XCTAssertNil(state.flashID)
        XCTAssertFalse(h.session.openPanels.contains(SearchOpen.documentPanel))
        XCTAssertEqual(toolbar.isOn?(h.session), false)
        XCTAssertFalse(overlay.isVisible(ChromeContext(app: h.app, session: h.session)))
    }

    func testLibrarySearchUsesNativePhonePanelEvenWhenFloatingHostExists() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit()])
        let host = SearchTestFloatingHost()
        h.session.floatingHost = host
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Hello"])
        XCTAssertEqual(h.session.openPanels.contains(SearchOpen.libraryPanel), SearchOpen.usesDocumentSheet)
        XCTAssertEqual(host.isPresenting(SearchOpen.libraryOverlay), !SearchOpen.usesDocumentSheet)
        let panel = try XCTUnwrap(h.app.ui.panels.get(SearchOpen.libraryPanel))
        XCTAssertEqual(panel.placement, .fullScreen)
        XCTAssertTrue(panel.providesHeader, "Search owns the native navigation/search field and dismissal")
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "close": true])
        XCTAssertFalse(host.isPresenting(SearchOpen.libraryOverlay))
        XCTAssertFalse(h.session.openPanels.contains(SearchOpen.libraryPanel))
    }

    func testDocumentSearchFieldAndResultsFillPortraitAndSplitViewWidth() {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.scope = NodeRef.document(Fixtures.docID).description
        state.query = "Hello"
        state.matches = [hit()]
        state.isPresented = true
        state.instant = true
        let field = DocumentSearchField(app: h.app, session: h.session, state: state)
        let panel = DocumentSearchPanel(app: h.app, session: h.session, state: state)
        for windowWidth: CGFloat in [390, 600, 834, 1024] {
            let availableWidth = windowWidth - 2 * NibMetrics.chromeInset
            for variant in NibSnapshot.Variant.allCases {
                XCTAssertEqual(NibSnapshot.fittingSize(field, width: availableWidth, variant: variant).width,
                    availableWidth, accuracy: 1, "The field must span the same column as results, even above 560 pt")
                XCTAssertEqual(NibSnapshot.fittingSize(panel, width: availableWidth, variant: variant).width,
                    availableWidth, accuracy: 1, "Search must fit between the host's 16 pt side margins")
            }
        }
        for variant in NibSnapshot.Variant.allCases {
            let portrait = panel.padding(.horizontal, NibMetrics.chromeInset)
            if let image = NibSnapshot.image(portrait, size: CGSize(width: 834, height: 700), variant: variant) {
                let attachment = XCTAttachment(image: image)
                attachment.name = "Portrait document search " + variant.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Portrait document search did not render") }
        }
    }

    func testLibrarySearchForegroundFitsFloatingHostAfterResize() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.scope = "lib"
        state.query = "Hello notes"
        state.matches = [hit()]
        state.isPresented = true
        state.instant = true
        let floating = NibFloatingHost()
        floating.present("searchui.library") {
            LibrarySearchFloatingContent(app: h.app, session: h.session, state: state)
        }
        let content = NibDropletContainer { NibFloatingLayer(host: floating) }
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea(.container)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            ((view as? T).map { [$0] } ?? [])
                + view.subviews.flatMap { descendants(type, in: $0) }
        }

        for size in [CGSize(width: 834, height: 1194), CGSize(width: 600, height: 834),
                     CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194)] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // The viewport and droplet rest frames publish on later main-loop turns.
            try await Task.sleep(nanoseconds: 500_000_000)
            host.view.layoutIfNeeded()
            let input = try XCTUnwrap(descendants(UITextField.self, in: host.view).first { $0.text == state.query })
            let results = try XCTUnwrap(descendants(UIScrollView.self, in: host.view)
                .filter { $0.bounds.height > NibMetrics.barHeight }
                .max { $0.bounds.height < $1.bounds.height })
            // Resizing reflows live droplets. Measure their resting geometry after the real
            // display-link springs settle, rather than assuming a loaded simulator finishes in 0.5 s.
            var previousFrames: [CGRect] = []
            var stableSamples = 0
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                host.view.layoutIfNeeded()
                let frames = [input.convert(input.bounds, to: window), results.convert(results.bounds, to: window)]
                stableSamples = frames == previousFrames ? stableSamples + 1 : 0
                previousFrames = frames
                if stableSamples >= 3 { break }
            }
            XCTAssertGreaterThanOrEqual(stableSamples, 3, "Search geometry must settle after resizing")
            let inputFrame = input.convert(input.bounds, to: window)
            XCTAssertGreaterThan(inputFrame.width, 0)
            XCTAssertGreaterThanOrEqual(inputFrame.minX, NibMetrics.chromeInset)
            XCTAssertLessThanOrEqual(inputFrame.maxX, size.width - NibMetrics.chromeInset - NibMetrics.hitTarget,
                "The query must leave room for the Close search control inside the window")
            let resultsFrame = results.convert(results.bounds, to: window)
            // V2:test01Library#2: follow the grid gutter, including compact widths.
            // The document HUD's separate 560 pt width contract is unchanged.
            let gutter = host.traitCollection.horizontalSizeClass == .compact ? NibSpacing.l : NibMetrics.libraryGutter
            let expectedWidth = size.width - 2 * gutter
            XCTAssertEqual(resultsFrame.width, expectedWidth, accuracy: 1)
            XCTAssertEqual(resultsFrame.minX, gutter, accuracy: 1)
            XCTAssertEqual(resultsFrame.maxX, size.width - gutter, accuracy: 1)
            XCTAssertEqual(resultsFrame.midX, size.width / 2, accuracy: 1)
            XCTAssertGreaterThanOrEqual(resultsFrame.minX, NibMetrics.chromeInset - 1)
            XCTAssertLessThanOrEqual(resultsFrame.maxX, size.width - NibMetrics.chromeInset + 1)
        }
    }

    func testLibrarySearchSizingDependsOnlyOnTheHostProposal() {
        XCTAssertEqual(LibrarySearchViewportLayout.size(for: .unspecified), .zero)
        XCTAssertEqual(LibrarySearchViewportLayout.size(for: .infinity), .zero)
        for width in [CGFloat(390), 600] {
            let proposal = ProposedViewSize(width: width, height: 834)
            XCTAssertEqual(LibrarySearchViewportLayout.size(for: proposal), CGSize(width: width, height: 834))
        }
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.scope = "lib"
        state.isPresented = true
        state.instant = true
        let host = UIHostingController(rootView:
            LibrarySearchFloatingContent(app: h.app, session: h.session, state: state)
                .environment(\.horizontalSizeClass, .compact))
        host.safeAreaRegions = []
        // No explicit frame or floating-layer wrapper: probe the production view itself with
        // different result content and repeated proposals. Its answer must not grow each pass.
        for query in ["", String(repeating: "Long search text ", count: 100)] {
            state.query = query
            state.matches = query.isEmpty ? [] : [hit()]
            for width in [CGFloat(390), 600, 390] {
                let proposal = CGSize(width: width, height: 834)
                XCTAssertEqual(host.sizeThatFits(in: proposal), proposal)
            }
        }
    }

    func testCompactSearchLayout01Content390() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .content, width: 390)
    }

    func testCompactSearchLayout01Content600() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .content, width: 600)
    }

    func testCompactSearchLayout02FloatingLayer390() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .floating, width: 390)
    }

    func testCompactSearchLayout02FloatingLayer600() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .floating, width: 600)
    }

    func testCompactSearchLayout03DropletContainer390() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .container, width: 390)
    }

    func testCompactSearchLayout03DropletContainer600() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .container, width: 600)
    }

    func testCompactSearchLayout04LiquidOff390() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .off, width: 390)
    }

    func testCompactSearchLayout04LiquidOff600() async throws {
        executionTimeAllowance = 60
        try await assertCompactSearchLayout(layer: .off, width: 600)
    }

    private enum CompactSearchLayer: String {
        case content, floating, container, off
    }

    private func assertCompactSearchLayout(layer: CompactSearchLayer, width: CGFloat) async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.scope = "lib"
        state.query = "Hello notes"
        state.matches = [hit()]
        state.isPresented = true
        state.instant = true
        let reduced = NibMotion.forcesReduced
        let haptics = NibHaptics.isEnabled
        defer { NibMotion.forcesReduced = reduced; NibHaptics.isEnabled = haptics }
        // Each width/layer has its own XCTest watchdog. A main-actor deadline cannot stop
        // synchronous layout. Exercise both appearances and both orientations at each rung.
        for scheme in [ColorScheme.light, .dark] {
            for height in [CGFloat(834), 320] {
                let search = LibrarySearchFloatingContent(app: h.app, session: h.session, state: state)
                let floating = NibFloatingHost()
                floating.present("searchui.library") { search }
                let root: AnyView
                switch layer {
                case .content: root = AnyView(search)
                case .floating: root = AnyView(NibFloatingLayer(host: floating))
                case .container: root = AnyView(NibDropletContainer { NibFloatingLayer(host: floating) })
                case .off:
                    root = AnyView(NibDropletContainer { NibFloatingLayer(host: floating) }.nibLiquidMode(.off))
                }
                let view = root
                    .environment(\.horizontalSizeClass, .compact)
                    .environment(\.colorScheme, scheme)
                    .frame(width: width, height: height)
                    .ignoresSafeArea(.container)
                let context = "layer=\(layer.rawValue) width=\(width) height=\(height) scheme=\(scheme)"
                #if DEBUG
                NSLog("%@", "[Nib QA search layout] install " + context)
                #endif
                let host = UIHostingController(rootView: view)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil }
                host.view.frame = window.bounds
                #if DEBUG
                NSLog("%@", "[Nib QA search layout] installed " + context + " safeArea=\(window.safeAreaInsets)")
                #endif
                let deadline = Date().addingTimeInterval(2)
                var frame: CGRect?
                var stableSamples = 0
                while Date() < deadline && stableSamples < 3 {
                    try await Task.sleep(for: .milliseconds(20))
                    let results = searchDescendants(UIScrollView.self, in: host.view)
                        .max { $0.bounds.height < $1.bounds.height }
                    let next = results.map { $0.convert($0.bounds, to: window) }
                    let fits = next.map {
                        $0.height > NibMetrics.barHeight && abs($0.minX - NibSpacing.l) <= 1
                            && abs($0.maxX - (width - NibSpacing.l)) <= 1
                    } ?? false
                    stableSamples = fits && next == frame ? stableSamples + 1 : 0
                    frame = next
                }
                let diagnostic = context + " results=\(String(describing: frame)) stableSamples=\(stableSamples)"
                XCTAssertGreaterThanOrEqual(stableSamples, 3, "Search layout must settle within two seconds; " + diagnostic)
                let measured = try XCTUnwrap(frame, diagnostic)
                // Preserve BOTH grid-gutter assertions on the full stack (and every earlier rung).
                XCTAssertEqual(measured.minX, NibSpacing.l, accuracy: 1, diagnostic)
                XCTAssertEqual(measured.maxX, width - NibSpacing.l, accuracy: 1, diagnostic)
            }
        }
    }

    func testLibraryFieldAlignsContentAndOwnsOnlyThePillSurface() async throws {
        executionTimeAllowance = 60
        let h = Harness(features: [FeatSearchUIFeature.self])
        let reduced = NibMotion.forcesReduced
        let haptics = NibHaptics.isEnabled
        NibMotion.forcesReduced = true
        NibHaptics.isEnabled = false
        defer { NibMotion.forcesReduced = reduced; NibHaptics.isEnabled = haptics }
        for scheme in [ColorScheme.light, .dark] {
            for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
                for mode in [NibLiquidMode.full, .off] {
                    let state = SearchState()
                    state.scope = "lib"
                    state.query = "Hello"
                    state.matches = [hit()]
                    state.isPresented = true
                    state.instant = true
                    var frames: [String: CGRect] = [:]
                    var field: DropletField?
                    let root = NibDropletContainer {
                        ZStack {
                            LibrarySearchFloatingContent(app: h.app, session: h.session, state: state)
                            SearchTestFieldProbe { field = $0 }
                        }
                    }
                    .nibLiquidMode(mode)
                    .environment(\.horizontalSizeClass, .regular)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, .large)
                    .environment(\.accessibilityReduceMotion, true)
                    .environment(\.searchLayoutDiagnostics, true)
                    .onPreferenceChange(SearchLayoutFrames.self) { frames = $0 }
                    let host = UIHostingController(rootView: root)
                    host.safeAreaRegions = []
                    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                    window.rootViewController = host
                    window.isHidden = false
                    defer { window.isHidden = true; window.rootViewController = nil }
                    host.view.frame = window.bounds
                    var previous: [CGRect] = []
                    var stableSamples = 0
                    for _ in 0..<50 {
                        host.view.setNeedsLayout()
                        host.view.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                        let sample = [frames["library.input"], frames["library.close"], frames["filter.all"],
                            frames["heading.typed"], frames["firstRow.typed"],
                            field?.visualFrame("searchui.libraryField"), field?.visualFrame("searchui.libraryResults")]
                            .compactMap { $0 }
                        stableSamples = sample.count == 7 && sample == previous ? stableSamples + 1 : 0
                        previous = sample
                        if stableSamples >= 3 { break }
                    }
                    let context = "\(scheme) \(size) \(mode)"
                    XCTAssertGreaterThanOrEqual(stableSamples, 3, context)
                    let liquid = try XCTUnwrap(field, context)
                    let pill = try XCTUnwrap(liquid.visualFrame("searchui.libraryField"), context)
                    let panel = try XCTUnwrap(liquid.visualFrame("searchui.libraryResults"), context)
                    let input = try XCTUnwrap(frames["library.input"], context)
                    let close = try XCTUnwrap(frames["library.close"], context)
                    XCTAssertEqual(panel.minX, NibMetrics.libraryGutter, accuracy: 1, context)
                    XCTAssertEqual(panel.maxX, size.width - NibMetrics.libraryGutter, accuracy: 1, context)
                    for key in ["filter.all", "heading.typed", "firstRow.typed"] {
                        let content = try XCTUnwrap(frames[key], key + context)
                        XCTAssertEqual(pill.minX, content.minX, accuracy: 1, key + context)
                    }
                    XCTAssertEqual(pill.minX, panel.minX + NibSpacing.l, accuracy: 1, context)
                    XCTAssertEqual(pill.minX, input.minX, accuracy: 1, context)
                    XCTAssertEqual(pill.maxX, input.maxX, accuracy: 1, context)
                    XCTAssertEqual(pill.height, input.height, accuracy: 1, context)
                    XCTAssertLessThan(pill.maxX, close.minX, "Glass must end before the separate close control; " + context)
                    // Inspect the actual registered surfaces, not a test-built facsimile.
                    let entries = Mirror(reflecting: liquid).children.first { $0.label == "entries" }?.value
                        as? [String: DropletField.Entry]
                    XCTAssertEqual(Set(try XCTUnwrap(entries).keys),
                        Set(["searchui.libraryField", "searchui.libraryResults"]), context)
                    XCTAssertEqual(entries?["searchui.libraryField"]?.style, .bar, context)
                    XCTAssertEqual(entries?["searchui.libraryField"]?.bud?.source, "library.controls", context)
                    if mode == .off {
                        // Off mode is compositor-independent. Locate actual painted disc pixels,
                        // rather than equating the 44 pt accessibility target with its visible edge.
                        host.view.layer.displayIfNeeded()
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 1
                        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                            host.view.layer.render(in: renderer.cgContext)
                        }
                        let backdrop = try XCTUnwrap(NibSnapshot.pixel(image,
                            at: CGPoint(x: panel.maxX, y: close.minY - 2)))
                        var disc = CGRect.null
                        for y in Int(ceil(close.minY))..<Int(floor(close.maxY)) {
                            for x in Int(ceil(close.minX))..<Int(floor(close.maxX)) {
                                let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                                let delta = max(abs(Int(pixel.r) - Int(backdrop.r)),
                                    max(abs(Int(pixel.g) - Int(backdrop.g)), abs(Int(pixel.b) - Int(backdrop.b))))
                                if delta > 4 {
                                    disc = disc.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
                                }
                            }
                        }
                        XCTAssertFalse(disc.isNull, context)
                        XCTAssertEqual(disc.width, 30, accuracy: 2, context)
                        XCTAssertEqual(disc.height, 30, accuracy: 2, context)
                        XCTAssertEqual(disc.maxX, panel.maxX, accuracy: 1, context)
                    }
                }
            }
        }
    }

    func testLibraryWithoutFloatingHostKeepsBackdropInsteadOfOpeningCover() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        XCTAssertNil(h.session.floatingHost)
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Physics"])
        let fallback = try XCTUnwrap(h.app.ui.chromeOverlays.get("searchui.libraryFallback"))
        XCTAssertEqual(fallback.surface, .none, "The field and results supply their own Clear and Deep surfaces")
        for compact in [false, true] {
            let context = ChromeContext(app: h.app, session: h.session, isCompact: compact)
            XCTAssertEqual(fallback.isVisible(context), !SearchOpen.usesDocumentSheet)
        }
        XCTAssertEqual(h.session.openPanels.contains(SearchOpen.libraryPanel), SearchOpen.usesDocumentSheet)
        let floating = SearchTestFloatingHost()
        h.session.floatingHost = floating
        try await h.run(CommandIDs.searchOpen, ["scope": "lib"])
        XCTAssertFalse(fallback.isVisible(ChromeContext(app: h.app, session: h.session)),
            "A late-attaching host must not duplicate the field or results")
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "close": true])
        XCTAssertFalse(fallback.isVisible(ChromeContext(app: h.app, session: h.session)))
        XCTAssertEqual(SearchRuntime.from(h.app).state(h.session).query, "Physics")
    }

    func testEmptyQueriesExplainLoadingIndexingAndNoMatchesInEveryScope() {
        let state = SearchState()
        for scope in ["lib", "folder:PHYSICS", NodeRef.document(Fixtures.docID).description] {
            state.scope = scope
            state.query = " Physics "
            state.loading = true
            XCTAssertEqual(state.emptyPresentation, .searching)
            state.loading = false
            XCTAssertEqual(state.emptyPresentation, .noResults("Physics"))
            XCTAssertEqual(state.emptyPresentation?.title, "No results for “Physics”")
            XCTAssertFalse(state.emptyPresentation?.message.isEmpty ?? true)
            state.progress = IndexProgressPayload(running: true, done: 0, total: 12, pending: 12)
            XCTAssertEqual(state.emptyPresentation, .indexing)
            XCTAssertEqual(state.indexingMessage, "Handwriting in 12 pages is still being indexed.")
            state.progress = IndexProgressPayload(running: true, done: 11, total: 12, pending: 1)
            XCTAssertEqual(state.indexingMessage, "Handwriting in 1 page is still being indexed.")
            state.matches = [hit()]
            XCTAssertNil(state.emptyPresentation, "Indexing must not hide available results")
            XCTAssertNotNil(state.indexingMessage)
            state.filter = .handwriting
            XCTAssertEqual(state.emptyPresentation, .indexing)
            state.progress = IndexProgressPayload(running: true, done: 12, total: 12, pending: 0)
            XCTAssertNotNil(state.indexingMessage, "Running with no pending count must still explain indexing")
            state.progress = IndexProgressPayload(running: false, done: 12, total: 12, pending: 0)
            XCTAssertEqual(state.emptyPresentation, .noResults("Physics"), "An empty filter needs the same tip")
            XCTAssertNil(state.indexingMessage)
            state.query = "  "
            XCTAssertNil(state.emptyPresentation)
            state.matches = []
            state.filter = .all
            state.progress = nil
        }
    }

    func testEmptyAdviceDoesNotRecommendTheAlreadySelectedFilterAndIndexingAppearsOnce() {
        let state = SearchState()
        state.query = "Physics"
        for filter in SearchFilter.allCases {
            state.filter = filter
            XCTAssertEqual(state.emptyPresentation?.message, "Try fewer words or check the spelling.")
        }
        state.filter = .all
        state.progress = IndexProgressPayload(running: true, done: 0, total: 5, pending: 5)
        XCTAssertEqual(state.emptyPresentation, .indexing)
        XCTAssertFalse(state.showsIndexingFooter)
        state.matches = [hit()]
        XCTAssertTrue(state.showsIndexingFooter)
        state.progress = nil
        XCTAssertFalse(state.showsIndexingFooter)
    }

    func testIndexCompletionKeepsEmptySearchPendingUntilRefreshedTitlesArrive() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [])
        let runtime = SearchRuntime.from(h.app)
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Physics"])
        let state = runtime.state(h.session)
        XCTAssertEqual(state.emptyPresentation, .noResults("Physics"))
        installDependencies(h, hits: [hit(kind: "title")])
        let completed = h.app.events.emit(IndexProgressPayload(running: false, done: 5, total: 5, pending: 0))
        await runtime.receive(completed)
        XCTAssertEqual(state.emptyPresentation, .searching)
        XCTAssertTrue(state.refreshPending)
        for _ in 0..<100 {
            if !state.refreshPending && !state.loading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(state.matches.count, 1)
        XCTAssertFalse(state.loading)
        XCTAssertFalse(state.refreshPending)
    }

    func testChangingFilterCancelsQueuedRefreshWithoutLeavingSearchLoading() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        installDependencies(h, hits: [hit()])
        let runtime = SearchRuntime.from(h.app)
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Hello"])
        let state = runtime.state(h.session)
        let completed = h.app.events.emit(IndexProgressPayload(running: false, done: 1, total: 1, pending: 0))
        await runtime.receive(completed)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(state.refreshPending)
        XCTAssertTrue(state.canStepMatches, "Keep available matches navigable while a refresh is queued")
        try await h.run(CommandIDs.searchOpen, ["scope": "lib", "filter": "all"])
        XCTAssertFalse(state.refreshPending)
        XCTAssertFalse(state.loading)
        XCTAssertTrue(state.canStepMatches)
    }

    func testQueuedRefreshClearsPendingWhenHiddenOrCommandFailsBeforeLoading() async throws {
        for failsBeforeLoad in [false, true] {
            let h = Harness(features: [FeatSearchUIFeature.self])
            installDependencies(h, hits: [])
            let runtime = SearchRuntime.from(h.app)
            try await h.run(CommandIDs.searchOpen, ["scope": "lib", "query": "Physics"])
            let state = runtime.state(h.session)
            var attempts = 0
            h.app.commands.register(CommandDescriptor(id: CommandIDs.searchOpen, title: "Search",
                summary: "Fail before loading.", params: .anything(), effect: .session)) { _, _ in
                    attempts += 1
                    throw NibError(.unavailable, "Search unavailable")
                }
            // An isolated event bus avoids delivering the same event again via the runtime watcher.
            let completed = EventBus().emit(IndexProgressPayload(running: false, done: 1, total: 1, pending: 0))
            await runtime.receive(completed)
            await runtime.receive(completed)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(state.refreshPending, "The cancelled predecessor must not clear its replacement")
            if !failsBeforeLoad { state.isPresented = false }
            for _ in 0..<100 {
                if !state.refreshPending { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertFalse(state.refreshPending)
            XCTAssertFalse(state.loading)
            XCTAssertEqual(attempts, failsBeforeLoad ? 1 : 0)
        }
    }

    func testNativePhoneFieldHasIndependentClearAndCancelInBothAppearances() async throws {
        var query = "Physics"
        var closed = false
        var submitted = false
        let field = SystemSearchField(text: Binding(get: { query }, set: { query = $0 }),
            prompt: "Search your notes", focusGeneration: 0,
            onSubmit: { submitted = true }, onClose: { closed = true })
        let host = UIHostingController(rootView: field.frame(height: NibMetrics.barHeight))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
                window.frame = CGRect(origin: .zero, size: size)
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
                let bar = try XCTUnwrap(searchDescendants(UISearchBar.self, in: host.view).first)
                XCTAssertEqual(bar.searchBarStyle, .minimal)
                XCTAssertTrue(bar.showsCancelButton)
                XCTAssertEqual(bar.searchTextField.accessibilityLabel, "Search your notes")
                let rect = bar.searchTextField.convert(bar.searchTextField.bounds, to: window)
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThanOrEqual(rect.maxX, size.width)
                bar.delegate?.searchBar?(bar, textDidChange: "")
                XCTAssertEqual(query, "")
                XCTAssertFalse(closed, "Clearing the query must keep search open")
                bar.delegate?.searchBarSearchButtonClicked?(bar)
                XCTAssertTrue(submitted)
            }
        }
        let bar = try XCTUnwrap(searchDescendants(UISearchBar.self, in: host.view).first)
        bar.delegate?.searchBarCancelButtonClicked?(bar)
        XCTAssertTrue(closed, "Cancel dismisses even with an empty query")
    }

    func testDocumentNoHitsAndErrorStayVisibleAfterResizeAndKeyboardDismissal() async throws {
        executionTimeAllowance = 60
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.scope = NodeRef.document(Fixtures.docID).description
        state.query = "Hello"
        state.matches = [hit()]
        state.isPresented = true
        state.instant = true
        var frames: [String: CGRect] = [:]
        let root = DocumentSearchPanel(app: h.app, session: h.session, state: state)
            .frame(width: 560, height: 780)
            .environment(\.searchLayoutDiagnostics, true)
            .onPreferenceChange(SearchLayoutFrames.self) { frames = $0 }
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = CGRect(x: 16, y: 100, width: 560, height: 780)
        host.view.layoutIfNeeded()
        let outsideKeyboard = window.convert(CGRect(x: 900, y: 360, width: 300, height: 300),
            to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: outsideKeyboard)])
        for hasMatches in [true, false, true] {
            state.query = hasMatches ? "Hello" : "Missing"
            state.matches = hasMatches ? [hit()] : []
            let key = hasMatches ? "firstRow.typed" : "results.empty"
            var stableSamples = 0
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(20))
                if let panel = frames["document.results"], abs(panel.height - 600) < 1,
                   let content = frames[key], content.height > 0,
                   panel.insetBy(dx: -1, dy: -1).contains(content) {
                    stableSamples += 1
                } else { stableSamples = 0 }
                if stableSamples >= 3 { break }
            }
            XCTAssertGreaterThanOrEqual(stableSamples, 3,
                "An outside-column floating keyboard must not collapse results as matches disappear or return")
        }
        let keyboard = CGRect(x: 500, y: 535, width: 400, height: 300)
        let screenKeyboard = window.convert(keyboard, to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: screenKeyboard)])
        for _ in 0..<50 {
            if let panel = frames["document.results"], abs(panel.height - 299) < 1,
               frames["firstRow.typed"] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(frames["firstRow.typed"], "Begin with matches")
        XCTAssertEqual(try XCTUnwrap(frames["document.results"]).height, 299, accuracy: 1,
            "The full-width landscape window reserves exactly one HUD row")
        state.query = "Missing"
        state.matches = [] // Production removes the counter overlay at this point.
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 900, height: 1200)] {
            window.frame.size = size
            host.view.frame = CGRect(x: 16, y: 100, width: 560, height: 780)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let hiddenKeyboard = window.convert(CGRect(x: 0, y: size.height, width: size.width, height: 0),
                to: window.screen.coordinateSpace)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: hiddenKeyboard)])
            for message in ["results.empty", "results.error"] {
                state.error = message == "results.error" ? "Search unavailable" : nil
                for _ in 0..<100 {
                    if let panel = frames["document.results"], panel.height >= 599,
                       let content = frames[message], content.height > 0,
                       panel.insetBy(dx: -1, dy: -1).contains(content) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let panel = try XCTUnwrap(frames["document.results"])
                let content = try XCTUnwrap(frames[message])
                let filter = try XCTUnwrap(frames["filter.all"])
                XCTAssertEqual(panel.height, 600, accuracy: 1)
                XCTAssertGreaterThan(content.height, 0)
                XCTAssertTrue(panel.insetBy(dx: -1, dy: -1).contains(content), "Keep the complete message visible")
                XCTAssertTrue(panel.insetBy(dx: -1, dy: -1).contains(filter), "Keep the filter header visible")
                XCTAssertGreaterThanOrEqual(content.minY, filter.maxY)
            }
        }
    }

    func testFilterHeaderStaysInsetWhenResultsScrollInShortKeyboardRegion() async throws {
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.query = "Hello"
        state.matches = (0..<20).map { hit(text: "Hello result \($0)") }
        let results = SearchResults(app: h.app, session: h.session, state: state)
        let host = UIHostingController(rootView: results)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 344, height: 240))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            let scrolls = searchDescendants(UIScrollView.self, in: host.view)
            let header = try XCTUnwrap(scrolls.first { $0.contentSize.width > $0.bounds.width + 1 })
            let list = try XCTUnwrap(scrolls.first { $0.bounds.height > NibMetrics.hitTarget * 2 })
            XCTAssertFalse(header === list)
            let headerFrame = header.convert(header.bounds, to: window)
            let listFrame = list.convert(list.bounds, to: window)
            XCTAssertGreaterThanOrEqual(headerFrame.minY, NibSpacing.s)
            XCTAssertGreaterThanOrEqual(headerFrame.height, NibMetrics.hitTarget + 2 * NibSpacing.s)
            XCTAssertGreaterThanOrEqual(listFrame.minY, headerFrame.maxY)
            XCTAssertLessThanOrEqual(listFrame.maxY, window.bounds.maxY)
            list.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
            host.view.layoutIfNeeded()
            XCTAssertEqual(header.convert(header.bounds, to: window), headerFrame,
                "Result scrolling must never move filters into the panel's clipped rim")
        }
    }

    private func searchDescendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { searchDescendants(type, in: $0) }
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
        state.isPresented = true
        state.instant = true
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
private struct SearchTestFieldProbe: View {
    @Environment(DropletField.self) private var field: DropletField?
    let capture: (DropletField) -> Void

    private var ready: Bool {
        guard let field else { return false }
        return ["searchui.libraryField", "searchui.libraryResults"].allSatisfy {
            field.node($0).presentation.isDrawn
        }
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: ready, initial: true) { _, ready in
                if ready, let field { capture(field) }
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

@MainActor
private final class SearchTestFloatingHost: FloatingHosting {
    private var presented = Set<String>()
    func present(_ id: String, content: AnyView) { presented.insert(id) }
    func dismiss(_ id: String) { presented.remove(id) }
    func isPresenting(_ id: String) -> Bool { presented.contains(id) }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool { false }
    func removeAnchor(_ id: String) {}
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { nil }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
}
