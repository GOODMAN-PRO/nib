import XCTest
import CoreGraphics
import NibContracts
import NibTesting

final class CanvasFixtureTests: XCTestCase {
    func testScenariosCannotAffectProductionAndKeepDefaultFixtureStable() {
        for scenario in NibUITestScenario.allCases {
            XCTAssertEqual(NibUITestScenario.parse(["-NibUITestScenario", scenario.rawValue]), .standard)
            XCTAssertEqual(NibUITestScenario.parse(["-NibUITestFixture", "-NibUITestScenario", scenario.rawValue]), scenario)
        }
        XCTAssertEqual(NibUITestScenario.parse(["-NibUITestFixture"]), .standard)
        XCTAssertEqual(NibUITestScenario.parse(["-NibUITestFixture", "-NibUITestScenario"]), .standard)
        XCTAssertEqual(NibUITestScenario.parse(["-NibUITestFixture", "-NibUITestScenario", "unknown"]), .standard)
        XCTAssertEqual(NibUITestScenario.standard.notebookPageCount, 4)
        XCTAssertEqual(NibUITestScenario.largeDocument.notebookPageCount, 300)
    }

    func testUnseenBoardsSurvivePersistenceAndLeaveTwoOffscreenChangesForSelection() throws {
        for localDevice: UInt32 in [0, 1, .max] {
            let content = NibUITestScenario.unseenBoardContent(localDevice: localDevice)
            let loaded = try JSONDecoder().decode(DocumentContent.self, from: JSONEncoder().encode(content))
            XCTAssertEqual(loaded, content)
            XCTAssertEqual(loaded.meta.kind, .whiteboard)
            XCTAssertEqual(Set(loaded.livePages.map(\.id)).count, 3)
            XCTAssertEqual(loaded.livePages.first?.rev, .zero)
            for page in loaded.livePages.dropFirst() {
                XCTAssertNil(page.size)
                XCTAssertNotEqual(page.rev.device, localDevice)
                XCTAssertGreaterThan(page.rev.effective(), Rev.zero)
            }
        }
    }

    func testFailureOnlyAffectsOneTargetScreenTileAndRetryUsesRealRenderer() async throws {
        let base = FakeRenderer()
        let renderer = NibUITestRenderer(base: base, failingPage: (Fixtures.docID, Fixtures.page1))
        let rect = Rect(x: 0, y: 0, width: 8, height: 6)
        let request = RenderRequest(doc: Fixtures.docID, page: Fixtures.page1, region: rect, scale: 1)
        var preview = request
        preview.region = nil
        _ = try await renderer.render(preview)
        for purpose: DrawPurpose in [.thumbnail, .query] {
            var other = request
            other.purpose = purpose
            _ = try await renderer.render(other)
        }
        var otherPage = request
        otherPage.page = PageID("OTHERPAGE001")
        _ = try await renderer.render(otherPage)
        var otherDoc = request
        otherDoc.doc = DocumentID("OTHERDOC0001")
        _ = try await renderer.render(otherDoc)
        XCTAssertEqual(renderer.failureCount, 0)
        let before = base.requests.count
        do {
            _ = try await renderer.render(request)
            XCTFail("The target screen tile must fail")
        } catch { XCTAssertTrue(error is NibError) }
        XCTAssertEqual(base.requests.count, before)
        let recovered = try await renderer.render(request)
        XCTAssertEqual(recovered.image.width, 8)
        XCTAssertEqual(recovered.image.height, 6)
        XCTAssertEqual(renderer.failureCount, 1)
        renderer.invalidate(doc: request.doc, page: request.page, rect: rect)
        XCTAssertEqual(base.invalidations.count, 1)
    }

    func testConcurrentTilesConsumeFailureExactlyOnce() async throws {
        let base = FakeRenderer()
        let renderer = NibUITestRenderer(base: base, failingPage: (Fixtures.docID, Fixtures.page1))
        let failures = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        _ = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page1,
                            region: Rect(x: 0, y: 0, width: 8, height: 8), scale: 1))
                        return 0
                    } catch { return 1 }
                }
            }
            var failures = 0
            for await count in group { failures += count }
            return failures
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(base.requests.count, 31)
        XCTAssertEqual(renderer.failureCount, 1)
    }

    func testMemoryProbeForwardsPurgeAndDoesNotInjectRenderFailures() async throws {
        let base = PurgeRenderer()
        let renderer = NibUITestRenderer(base: base)
        renderer.purgeCaches()
        renderer.purgeCaches()
        XCTAssertEqual(base.purges, 2)
        XCTAssertEqual(renderer.cachePurgeCount, 2)
        _ = try await renderer.render(RenderRequest(doc: Fixtures.docID, page: Fixtures.page1,
            region: Rect(x: 0, y: 0, width: 8, height: 8), scale: 1))
        XCTAssertEqual(renderer.failureCount, 0)
    }
}

private final class PurgeRenderer: PageRenderer {
    private let base = FakeRenderer()
    var purges = 0
    func render(_ request: RenderRequest) async throws -> RenderResult { try await base.render(request) }
    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        await base.thumbnail(doc: doc, page: page, maxPixelSize: maxPixelSize)
    }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) { base.invalidate(doc: doc, page: page, rect: rect) }
    func purgeCaches() { purges += 1 }
}
