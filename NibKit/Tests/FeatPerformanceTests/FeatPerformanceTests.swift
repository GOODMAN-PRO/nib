import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatPerformance

// MARK: - Test doubles

/// Counts `purgeCaches` calls (NibTesting's FakeRenderer does not).
private final class CountingRenderer: PageRenderer {
    private(set) var purges = 0
    private let fake = FakeRenderer()

    func render(_ request: RenderRequest) async throws -> RenderResult { try await fake.render(request) }
    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        await fake.thumbnail(doc: doc, page: page, maxPixelSize: maxPixelSize)
    }
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {}
    func purgeCaches() { purges += 1 }
}

/// A document editor whose canvas is a FakeCanvasHost (so the coordinator can ask which pages are on screen).
@MainActor
private final class CanvasEditor: DocumentEditing {
    let host: FakeCanvasHost
    init(_ host: FakeCanvasHost) { self.host = host }
    var documentID: DocumentID { host.documentID }
    var session: EditorSession { host.session }
    var canvasHost: CanvasHost? { host }
    func reveal(page: PageID, rect: Rect?, animated: Bool) {}
    func reloadAll() {}
}

private final class CapturingSink: MetricsLogSink {
    private(set) var lines: [MetricLine] = []
    func write(_ line: MetricLine) { lines.append(line) }
    var texts: [String] { lines.map { $0.text } }
}

@MainActor
final class FeatPerformanceTests: XCTestCase {
    func testFeatureID() { XCTAssertEqual(FeatPerformanceFeature.id, "performance") }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatPerformanceFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegisterInstallsTheCoordinatorAndNoCommands() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == FeatPerformanceFeature.id }.isEmpty,
                      "ARCHITECTURE §6.5 lists no commands for F100")
        let c = try coordinator(h)
        XCTAssertFalse(c.isStarted, "register must not start observers")
        await FeatPerformanceFeature.start(h.app)
        XCTAssertTrue(c.isStarted)
        XCTAssertNil(h.app.services.get(MetricKitSubscriber.serviceKey, as: MetricKitSubscriber.self),
                     "MetricKit stays off in hostless tests")
        await FeatPerformanceFeature.start(h.app)   // idempotent
        c.stop()
        XCTAssertFalse(c.isStarted)
    }

    // MARK: Retention rules

    func testKeepHoldsAnchorsAndTheirNeighbours() {
        let order = pageIDs(10)
        XCTAssertEqual(PageRetention.keep(order: order, anchors: [order[4]], radius: 1), [order[3], order[4], order[5]])
        XCTAssertEqual(PageRetention.keep(order: order, anchors: [order[0], order[9]], radius: 2),
                       [order[0], order[1], order[2], order[7], order[8], order[9]])
        XCTAssertEqual(PageRetention.keep(order: order, anchors: [order[5]], radius: 0), [order[5]])
        XCTAssertEqual(PageRetention.keep(order: order, anchors: [], radius: 3), [])
        // A shown page that is no longer in the order (trashed while open) is still kept.
        XCTAssertEqual(PageRetention.keep(order: order, anchors: ["GONEPAGE0001"], radius: 1), ["GONEPAGE0001"])
    }

    func testWorkingSetKeepsTheNearestPagesAndDropsOrphansFirst() {
        let order = pageIDs(30)
        let cached = Set(order).union(["TRASHEDPAGE1"])
        let keep = PageRetention.workingSet(order: order, cached: cached, anchors: [order[20]], radius: 1, target: 7)
        XCTAssertEqual(keep, Set(order[17...23]), "the anchor, its neighbours, then the closest pages")
        XCTAssertFalse(keep.contains("TRASHEDPAGE1"))

        // Two windows on one document: the room is shared by distance to the nearest anchor, earlier pages first.
        let two = PageRetention.workingSet(order: order, cached: Set(order), anchors: [order[2], order[27]], radius: 0,
                                           target: 6)
        XCTAssertEqual(two, [order[1], order[2], order[3], order[26], order[27], order[28]])

        // No anchor at all: the first cached pages in order survive.
        XCTAssertEqual(PageRetention.workingSet(order: order, cached: Set(order), anchors: [], radius: 1, target: 3),
                       Set(order[0...2]))
        // The pinned set always survives, even above the target.
        XCTAssertEqual(PageRetention.workingSet(order: order, cached: Set(order), anchors: [order[10]], radius: 3,
                                                target: 2).count, 7)
        XCTAssertEqual(PageRetention.nearestDistance(9, in: [2, 7, 15]), 2)
        XCTAssertEqual(PageRetention.nearestDistance(0, in: [4]), 4)
    }

    // MARK: Memory warnings

    func testMemoryWarningEvictsPagesNobodySeesAndPurgesTheRenderer() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let renderer = CountingRenderer()
        h.app.services.renderer = renderer
        let (doc, pages) = installBook(h, pageCount: 12)
        try load(h, doc, pages)
        _ = try h.app.workspace.allItems(Fixtures.whiteboardID, page: Fixtures.boardID)
        h.session.document = doc
        h.session.page = pages[5]
        let c = try coordinator(h)
        c.footprint = { nil }
        await FeatPerformanceFeature.start(h.app)
        defer { c.stop() }

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        XCTAssertEqual(h.app.workspace.cachedPages(doc), [pages[4], pages[5], pages[6]])
        XCTAssertTrue(h.app.workspace.cachedPages(Fixtures.whiteboardID).isEmpty, "a document nobody shows keeps no pages")
        XCTAssertTrue(h.app.workspace.isLoaded(doc), "documents stay open; only their page caches go")
        XCTAssertEqual(renderer.purges, 1)
        let report = try XCTUnwrap(c.reports.last)
        XCTAssertEqual(report.reason, .memoryWarning)
        XCTAssertEqual(report.evictedPages, 10)
        XCTAssertEqual(report.documents, 2)
        XCTAssertTrue(report.purgedRenderer)
    }

    func testVisiblePagesComeFromTheCanvasViewport() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        h.app.services.renderer = CountingRenderer()
        let (doc, pages) = installBook(h, pageCount: 24)
        try load(h, doc, pages)
        let host = FakeCanvasHost(app: h.app, session: h.session, doc: doc, pages: pages)
        let editor = CanvasEditor(host)
        h.session.editor = editor
        h.session.document = doc
        h.session.page = pages[10]
        // Scroll so page 10 sits at the top of a 1366 pt viewport: pages 10 and 11 are on screen, and the half-screen
        // margin reaches pages 9 and 12.
        let pitch = (PageSize.a4.height + host.gap) * host.zoomScale
        host.canvasView.bounds = CGRect(x: 0, y: 10 * pitch, width: 1024, height: 1366)
        let c = try coordinator(h)
        c.footprint = { nil }

        XCTAssertEqual(c.visiblePages()[doc], Set(pages[9...12]))
        c.relieve(.memoryWarning)
        XCTAssertEqual(h.app.workspace.cachedPages(doc), Set(pages[8...13]), "visible pages plus one neighbour each side")
        withExtendedLifetime(editor) {}
    }

    func testSelectionAndEditedTextPagesStayCached() throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let (doc, pages) = installBook(h, pageCount: 10)
        try load(h, doc, pages)
        h.session.document = doc
        h.session.page = pages[0]
        h.session.selection = Selection(doc: doc, page: pages[5], items: ["SELECTED0001"])
        h.session.editingTextRef = NodeRef.item(doc, pages[8], "EDITING00001").description
        let c = try coordinator(h)
        c.footprint = { nil }
        c.policy.neighbourRadius = 0
        c.relieve(.memoryWarning)
        XCTAssertEqual(h.app.workspace.cachedPages(doc), [pages[0], pages[5], pages[8]])
    }

    func testEvictedPagesReloadWithTheirEditsAndUndoStillWorks() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let c = try coordinator(h)
        c.footprint = { nil }
        let stroke = Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 90, y: 40)],
                                            t0: 1_700_000_000))
        let written = try await h.insert([stroke], page: Fixtures.page2)
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID

        let report = c.relieve(.memoryWarning)
        XCTAssertGreaterThan(report.evictedPages, 0)
        XCTAssertFalse(h.app.workspace.isPageCached(Fixtures.docID, page: Fixtures.page2))
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.id == written[0].id },
                      "evictPages flushes first, so the page reloads with the edit")

        h.app.bus.undo(Fixtures.docID)
        XCTAssertFalse(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).contains { $0.id == written[0].id })
    }

    func testEnteringTheBackgroundTrimsLikeAWarning() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let renderer = CountingRenderer()
        h.app.services.renderer = renderer
        let (doc, pages) = installBook(h, pageCount: 6)
        try load(h, doc, pages)
        h.session.document = doc
        h.session.page = pages[0]
        let c = try coordinator(h)
        c.footprint = { nil }
        await FeatPerformanceFeature.start(h.app)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(h.app.workspace.cachedPages(doc), [pages[0], pages[1]])
        XCTAssertEqual(renderer.purges, 1)
        XCTAssertEqual(c.reports.last?.reason, .background)

        // After stop, system notifications no longer reach the coordinator.
        c.stop()
        try load(h, doc, pages)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(h.app.workspace.cachedPages(doc).count, pages.count)
        XCTAssertEqual(renderer.purges, 1)
    }

    // MARK: Large documents (P-091)

    func testPagingThroughALargeDocumentKeepsItsWorkingSetBounded() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let (doc, pages) = installBook(h, pageCount: 60)
        let c = try coordinator(h)
        c.footprint = { nil }
        c.policy.workingSetLimit = 10
        c.policy.workingSetTarget = 6
        c.policy.trimDelay = 0
        await FeatPerformanceFeature.start(h.app)
        defer { c.stop() }
        h.session.document = doc
        for page in pages {
            h.session.page = page                           // page.changed → a trim is scheduled
            _ = try h.app.workspace.allItems(doc, page: page) // the canvas reads the page
            await c.pendingTrim?.value
            XCTAssertLessThanOrEqual(h.app.workspace.cachedPages(doc).count, 10)
        }
        let cached = h.app.workspace.cachedPages(doc)
        XCTAssertTrue(cached.isSuperset(of: [pages[58], pages[59]]), "the current page and its neighbour stay")
        XCTAssertFalse(cached.contains(pages[0]), "the farthest pages go first")
        XCTAssertGreaterThan(c.trimmedPages, 0)
        XCTAssertTrue(c.reports.isEmpty, "working-set trims are not memory reliefs")
    }

    func testTrimWaitsUntilThePageTurnSettlesAndStopCancelsIt() async throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let (doc, pages) = installBook(h, pageCount: 20)
        let c = try coordinator(h)
        c.footprint = { nil }
        c.policy.workingSetLimit = 8
        c.policy.workingSetTarget = 4
        c.policy.trimDelay = 0.05
        await FeatPerformanceFeature.start(h.app)
        h.session.document = doc
        try load(h, doc, pages)
        h.session.page = pages[10]
        h.session.page = pages[11]                          // joins the same pending trim
        let first = try XCTUnwrap(c.pendingTrim)
        XCTAssertEqual(h.app.workspace.cachedPages(doc).count, 20, "nothing happens during the page turn")
        await first.value
        XCTAssertEqual(h.app.workspace.cachedPages(doc), Set(pages[9...12]))
        XCTAssertNil(c.pendingTrim)

        try load(h, doc, pages)
        h.session.page = pages[3]
        let cancelled = try XCTUnwrap(c.pendingTrim)
        c.stop()
        await cancelled.value
        XCTAssertEqual(h.app.workspace.cachedPages(doc).count, 20, "a stopped coordinator trims nothing")
    }

    func testSmallDocumentsAreNeverTrimmed() throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let (doc, pages) = installBook(h, pageCount: 20)
        try load(h, doc, pages)
        let c = try coordinator(h)
        c.footprint = { nil }
        h.session.document = doc
        h.session.page = pages[19]
        XCTAssertEqual(c.trimWorkingSet(doc), 0, "20 cached pages are under the default limit of 48")
        XCTAssertEqual(h.app.workspace.cachedPages(doc).count, 20)
    }

    func testFootprintOverTheBudgetDropsInvisiblePagesOncePerCooldown() throws {
        let h = Harness(features: [FeatPerformanceFeature.self])
        let renderer = CountingRenderer()
        h.app.services.renderer = renderer
        let (doc, pages) = installBook(h, pageCount: 8)
        h.session.document = doc
        h.session.page = pages[3]
        let c = try coordinator(h)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var bytes: UInt64 = 520 << 20
        c.now = { clock }
        c.footprint = { bytes }

        try load(h, doc, pages)
        let first = try XCTUnwrap(c.checkFootprint())
        XCTAssertEqual(first.reason, .footprint)
        XCTAssertFalse(first.purgedRenderer, "rendered tiles stay: the renderer caps its own cache")
        XCTAssertEqual(renderer.purges, 0)
        XCTAssertEqual(h.app.workspace.cachedPages(doc), [pages[2], pages[3], pages[4]])

        try load(h, doc, pages)
        XCTAssertNil(c.checkFootprint(), "cooldown")
        clock.addTimeInterval(31)
        XCTAssertNotNil(c.checkFootprint())
        bytes = 200 << 20
        clock.addTimeInterval(120)
        XCTAssertNil(c.checkFootprint(), "under the §20 budget")
    }

    func testFootprintReaderReportsThisProcess() {
        let bytes = MemoryFootprint.current()
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1 << 20)
        XCTAssertEqual(MemoryFootprint.megabytes(300 << 20), "300 MB")
        XCTAssertEqual(MemoryFootprint.megabytes(nil), "?")
    }

    // MARK: Metrics

    func testHistogramPercentilesInterpolateInsideBuckets() {
        let h = LatencyHistogram(buckets: [.init(start: 200, end: 1000, count: 20), .init(start: 0, end: 100, count: 50),
                                           .init(start: 100, end: 200, count: 30), .init(start: 1000, end: 2000, count: 0)])
        XCTAssertEqual(h.total, 100)
        XCTAssertEqual(h.percentile(0), 0)
        XCTAssertEqual(h.percentile(0.25), 50)
        XCTAssertEqual(h.percentile(0.5), 100)
        XCTAssertEqual(try XCTUnwrap(h.percentile(0.95)), 800, accuracy: 1e-9)
        XCTAssertEqual(h.percentile(1), 1000)
        XCTAssertNil(LatencyHistogram(buckets: []).percentile(0.5))
        XCTAssertNil(LatencyHistogram(buckets: [.init(start: 0, end: 10, count: 0)]).percentile(0.5))
    }

    func testMetricsLinesCoverLaunchHitchesMemoryEnergyAndExits() {
        var d = MetricsDigest(begin: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_086_400),
                              appVersion: "1.4")
        d.osVersion = "iPadOS 26.1"
        d.device = "iPad16,3"
        d.timeToFirstDraw = LatencyHistogram(buckets: [.init(start: 300, end: 400, count: 5), .init(start: 400, end: 1400, count: 5)])
        d.resume = LatencyHistogram(buckets: [.init(start: 0, end: 50, count: 40)])
        d.hangs = LatencyHistogram(buckets: [.init(start: 250, end: 500, count: 3)])
        d.scrollHitchRatio = 2.5
        d.peakMemoryMB = 312
        d.suspendedMemoryMB = 80
        d.cpuSeconds = 120
        d.foregroundSeconds = 3600
        d.backgroundSeconds = 90
        d.diskWritesMB = 42
        d.wifiDownMB = 20
        d.exits = ExitCounts(foregroundNormal: 3)
        d.signposts = [SignpostSummary(name: "memory.relief", category: "performance", count: 2, duration: nil)]

        let lines = MetricsFormatter.lines(d)
        let text = lines.map { $0.text }.joined(separator: "\n")
        XCTAssertTrue(text.contains("2026-09-21 14:13–2026-09-22 14:13 UTC app 1.4, iPadOS 26.1, iPad16,3"), text)
        XCTAssertTrue(text.contains("launch: first draw p50 400 ms, p95 1.3 s (10 launches); resume p50 25 ms"), text)
        XCTAssertTrue(text.contains("hitches: scroll hitch 2.5 ms/s; hangs p50 375 ms"), text)
        XCTAssertTrue(text.contains("memory: peak 312 MB (budget 400 MB); suspended average 80 MB"), text)
        XCTAssertTrue(text.contains("energy: cpu 120 s, foreground 3600 s, background 90 s, disk writes 42 MB, "
                                    + "network up 0.0 MB, down 20 MB (cellular 0.0 MB)"), text)
        XCTAssertTrue(text.contains("exits: foreground 3 normal, 0 memory limit"), text)
        XCTAssertTrue(text.contains("signposts: performance/memory.relief x2"), text)
        XCTAssertTrue(lines.allSatisfy { !$0.isProblem })

        d.peakMemoryMB = 610
        d.exits = ExitCounts(foregroundNormal: 3, foregroundMemoryLimit: 1)
        let bad = MetricsFormatter.lines(d)
        let memory = bad.first { $0.text.contains(": memory:") }
        XCTAssertEqual(memory?.isProblem, true)
        XCTAssertTrue(memory?.text.contains("peak 610 MB (budget 400 MB, OVER)") ?? false)
        XCTAssertTrue(memory?.text.contains("memory exits: 1 foreground limit") ?? false)
        XCTAssertEqual(bad.first { $0.text.contains(": exits:") }?.isProblem, true)

        let empty = MetricsFormatter.lines(MetricsDigest(begin: d.begin, end: d.end, appVersion: "1.4"))
        XCTAssertEqual(empty.count, 1)
        XCTAssertTrue(empty[0].text.hasSuffix("no metrics in this period"))
    }

    func testDiagnosticsLinesNameHangsAndCrashes() {
        var d = DiagnosticsDigest(begin: Date(timeIntervalSince1970: 1_790_000_000),
                                  end: Date(timeIntervalSince1970: 1_790_086_400), appVersion: "1.4")
        XCTAssertEqual(MetricsFormatter.lines(d).map { $0.isProblem }, [false])
        d.hangSeconds = [0.8, 3.4]
        d.crashes = [CrashSummary(exceptionType: 1, signal: 11, reason: nil),
                     CrashSummary(exceptionType: 10, signal: 6, reason: "NSInvalidArgumentException")]
        d.diskWriteExceptionMB = [1100]
        let lines = MetricsFormatter.lines(d)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isProblem)
        XCTAssertTrue(lines[0].text.contains("2 hangs (longest 3.4 s)"), lines[0].text)
        XCTAssertTrue(lines[0].text.contains("1 disk-write exception (1100 MB written)"), lines[0].text)
        XCTAssertTrue(lines[0].text.contains("2 crashes: EXC_BAD_ACCESS SIGSEGV, EXC_CRASH SIGABRT NSInvalidArgumentException"),
                      lines[0].text)
        XCTAssertEqual(MetricsFormatter.crashName(CrashSummary(exceptionType: 99, signal: nil, reason: nil)), "exception 99")
        XCTAssertEqual(MetricsFormatter.duration(412), "412 ms")
        XCTAssertEqual(MetricsFormatter.duration(1234), "1.2 s")
        XCTAssertEqual(MetricsFormatter.megabytes(2.34), "2.3 MB")
    }

    func testRecorderLogsEachPayloadOnceKeepsHistoryAndReplaysIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = CapturingSink()
        let recorder = MetricsRecorder(history: MetricsHistory(directory: dir), sink: sink)
        var d = MetricsDigest(begin: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_086_400),
                              appVersion: "1.4")
        d.peakMemoryMB = 250
        var diag = DiagnosticsDigest(begin: d.begin, end: d.end)
        diag.hangSeconds = [2]

        XCTAssertTrue(recorder.record(.metrics(d)))
        XCTAssertTrue(recorder.record(.diagnostics(diag)))
        XCTAssertFalse(recorder.record(.metrics(d)), "MetricKit re-delivers past payloads; each is logged once")
        XCTAssertEqual(sink.texts.filter { $0.contains("peak 250 MB") }.count, 1)
        XCTAssertTrue(sink.lines.contains { $0.isProblem && $0.text.contains("1 hang") })

        // A later launch: the history file brings both back and replays them as "earlier" lines.
        let laterSink = CapturingSink()
        let later = MetricsRecorder(history: MetricsHistory(directory: dir), sink: laterSink)
        XCTAssertEqual(later.stored, [.metrics(d), .diagnostics(diag)])
        XCTAssertEqual(later.replayHistory(), 2)
        XCTAssertTrue(laterSink.texts.contains { $0.contains("(earlier)") && $0.contains("peak 250 MB") })
        XCTAssertFalse(later.record(.diagnostics(diag)))
    }

    func testHistoryKeepsOnlyTheLatestRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nib-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MetricsRecorder(history: MetricsHistory(directory: dir, limit: 3), sink: CapturingSink())
        let days = (0..<5).map { i -> MetricsDigest in
            let begin = Date(timeIntervalSince1970: 1_790_000_000).addingTimeInterval(Double(i) * 86_400)
            return MetricsDigest(begin: begin, end: begin.addingTimeInterval(86_400), appVersion: "1.\(i)")
        }
        for d in days.reversed() { recorder.record(.metrics(d)) }   // delivered out of order
        let reloaded = MetricsRecorder(history: MetricsHistory(directory: dir, limit: 3), sink: CapturingSink()).stored
        XCTAssertEqual(reloaded, days.suffix(3).map { MetricRecord.metrics($0) }, "oldest dropped, sorted by period end")
        XCTAssertTrue(MetricsRecorder(history: MetricsHistory(directory: nil), sink: CapturingSink()).stored.isEmpty)
    }

    // MARK: Helpers

    private func coordinator(_ h: Harness) throws -> MemoryPressureCoordinator {
        try XCTUnwrap(h.app.services.get(MemoryPressureCoordinator.serviceKey, as: MemoryPressureCoordinator.self))
    }

    private func pageIDs(_ n: Int) -> [PageID] { (0..<n).map { PageID(String(format: "PERFPAGE%04d", $0)) } }

    /// A notebook with `pageCount` pages, one stroke each, installed in the in-memory persistence (not yet loaded).
    private func installBook(_ h: Harness, pageCount: Int, id: DocumentID = "PERFBOOK0001") -> (DocumentID, [PageID]) {
        let ids = pageIDs(pageCount)
        let orders = FractionalIndex.balanced(count: pageCount)
        let records = zip(ids, orders).map { PageRecord(id: $0, order: $1, size: .a4, background: .ofTemplate("builtin.ruled")) }
        h.persistence.heads[id] = DocumentContent(meta: DocumentMeta(id: id, kind: .notebook, createdAt: 1_700_000_000),
                                                  pages: records)
        for (i, page) in ids.enumerated() {
            let stroke = Stroke(style: .defaultPen, points: [StrokePoint(x: 20, y: Float(20 + i)), StrokePoint(x: 200, y: 60)],
                                t0: 1_700_000_000)
            h.persistence.pageItems[id, default: [:]][page] = [Item(id: NibID(String(format: "PERFSTK%05d", i)), kind: .stroke,
                                                                    z: "V", stroke: stroke)]
        }
        return (id, ids)
    }

    /// Reads every page (the canvas scrolling through the document).
    private func load(_ h: Harness, _ doc: DocumentID, _ pages: [PageID]) throws {
        for page in pages { _ = try h.app.workspace.allItems(doc, page: page) }
        XCTAssertEqual(h.app.workspace.cachedPages(doc).count, pages.count)
    }
}
