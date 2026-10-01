import Foundation
import UIKit
import Darwin
import os
import NibContracts

// MARK: - Policy

/// Why the coordinator releases memory, and how hard.
enum ReliefReason: String {
    /// `UIApplication.didReceiveMemoryWarningNotification`: every page nobody can see, plus the renderer's caches.
    case memoryWarning
    /// The app left the foreground: the same trim, so iOS keeps a small suspended app instead of terminating it
    /// (a resume is far cheaper than a relaunch; P-095).
    case background
    /// The process footprint passed the §20 budget: pages nobody can see; rendered tiles stay (re-rendering costs
    /// energy and the tile cache is capped by the renderer itself).
    case footprint

    var purgesRenderer: Bool { self != .footprint }
}

/// What one relief did (logged under "app.nib"/"performance", so diagnostics exports include it).
struct ReliefReport: Equatable {
    var reason: ReliefReason
    var evictedPages = 0
    /// Documents that lost at least one cached page.
    var documents = 0
    var purgedRenderer = false
    var footprintBefore: UInt64?
    var footprintAfter: UInt64?
}

/// Tunables of the memory coordinator. Defaults follow ARCHITECTURE §20 ("resident memory with a 1,000-page PDF open
/// < 400 MB") and the canvas' continuous page scroll (the next page slides in before it is "current").
struct MemoryPolicy: Equatable {
    /// Pages kept on either side of a page someone is looking at.
    var neighbourRadius = 1
    /// A document whose cached pages exceed this is trimmed when the page changes (large PDFs: scrolling through
    /// 1,000 pages would otherwise keep every visited page's items in memory).
    var workingSetLimit = 48
    /// ...down to this many pages (hysteresis, so trimming is rare and each trim flushes once).
    var workingSetTarget = 24
    /// Process footprint above which invisible pages are dropped without waiting for a warning (§20 budget).
    var footprintSoftLimit: UInt64 = 400 << 20
    /// Minimum time between two footprint reliefs.
    var footprintCooldown: TimeInterval = 30
    /// Share of the viewport added above/below and left/right of the canvas when deciding what is on screen.
    var visibleMargin: CGFloat = 0.5
    /// Seconds between a page change and its working-set trim, so the trim (and the flush it implies) never lands in
    /// the page-turn animation. Page changes in the meantime join the same trim.
    var trimDelay: TimeInterval = 1
}

/// Which cached pages survive a trim. Pure, so the rules are unit-tested without a canvas.
enum PageRetention {
    /// Every anchor plus `radius` neighbours on each side in `order`. Anchors missing from `order` (a page trashed
    /// while shown) are kept as they are.
    static func keep(order: [PageID], anchors: Set<PageID>, radius: Int) -> Set<PageID> {
        guard !anchors.isEmpty else { return [] }
        var keep = anchors
        let r = max(0, radius)
        guard r > 0 else { return keep }
        for (i, page) in order.enumerated() where anchors.contains(page) {
            for j in max(0, i - r)...min(order.count - 1, i + r) { keep.insert(order[j]) }
        }
        return keep
    }

    /// Trims a working set of `cached` pages to about `target`: `keep(order:anchors:radius:)` always survives, then the
    /// cached pages nearest (in page order) to an anchor fill the remaining room, earlier pages first on a tie. Pages
    /// that are not in `order` (trashed, deleted) go first. With no anchors the first cached pages in order are kept.
    static func workingSet(order: [PageID], cached: Set<PageID>, anchors: Set<PageID>, radius: Int, target: Int) -> Set<PageID> {
        let pinned = keep(order: order, anchors: anchors, radius: radius).intersection(cached)
        let room = max(0, target - pinned.count)
        guard room > 0 else { return pinned }
        var anchorIndices: [Int] = []
        var candidates: [(distance: Int, index: Int, page: PageID)] = []
        for (i, page) in order.enumerated() {
            if anchors.contains(page) { anchorIndices.append(i) }
        }
        for (i, page) in order.enumerated() where cached.contains(page) && !pinned.contains(page) {
            let d = anchorIndices.isEmpty ? i : nearestDistance(i, in: anchorIndices)
            candidates.append((d, i, page))
        }
        candidates.sort { ($0.distance, $0.index) < ($1.distance, $1.index) }
        return pinned.union(candidates.prefix(room).map { $0.page })
    }

    /// Distance from `i` to the closest value of the sorted, non-empty `sorted`.
    static func nearestDistance(_ i: Int, in sorted: [Int]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < i { lo = mid + 1 } else { hi = mid }
        }
        var best = Int.max
        if lo < sorted.count { best = sorted[lo] - i }
        if lo > 0 { best = min(best, i - sorted[lo - 1]) }
        return best
    }
}

// MARK: - Footprint

/// The process' memory as iOS accounts it for jetsam.
enum MemoryFootprint {
    /// `phys_footprint` from `task_info(TASK_VM_INFO)`: the number Xcode's memory gauge and jetsam use.
    static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Bytes left before the process hits its memory limit (nil where iOS does not report it, e.g. the simulator).
    static func available() -> UInt64? {
        let n = os_proc_available_memory()
        return n > 0 ? UInt64(n) : nil
    }

    static func megabytes(_ bytes: UInt64?) -> String {
        guard let b = bytes else { return "?" }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}

// MARK: - Coordinator

/// Releases memory the app can rebuild: cached page items of pages nobody is looking at (`Workspace.evictPages`, which
/// flushes pending writes first) and the renderer's tiles and thumbnails (`PageRenderer.purgeCaches`). Triggered by
/// memory warnings, by entering the background, by a footprint above the §20 budget, and — for large PDFs — by a
/// document's cached pages growing past `MemoryPolicy.workingSetLimit` while the user pages through it.
@MainActor
final class MemoryPressureCoordinator {
    /// `NibServices` key under which the feature keeps its coordinator.
    static let serviceKey = "performance.memory"
    static let reportLimit = 16

    private weak var app: NibApp?
    var policy: MemoryPolicy
    /// Current footprint (injected by tests; nil = unknown, never triggers a footprint relief).
    var footprint: () -> UInt64?
    var now: () -> Date
    /// The latest reliefs, oldest first (at most `reportLimit`).
    private(set) var reports: [ReliefReport] = []
    /// Pages dropped by working-set trims since launch.
    private(set) var trimmedPages = 0
    /// The scheduled working-set trim, if any (tests await it).
    private(set) var pendingTrim: Task<Void, Never>?
    private var trimQueue: [DocumentID] = []
    private var lastFootprintRelief: Date?
    private let observers = ObserverBag()
    private var subscription: EventSubscription?
    private let log = Logger(subsystem: "app.nib", category: "performance")
    private let signposter = OSSignposter(subsystem: "app.nib", category: "performance")

    init(app: NibApp, policy: MemoryPolicy = MemoryPolicy(), footprint: @escaping () -> UInt64? = MemoryFootprint.current,
         now: @escaping () -> Date = Date.init) {
        self.app = app
        self.policy = policy
        self.footprint = footprint
        self.now = now
    }

    var isStarted: Bool { subscription != nil }

    /// Starts observing (called from the feature's `start`). Idempotent.
    func start() {
        guard !isStarted, let app = app else { return }
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                         queue: nil) { [weak self] _ in
            onMainActor { _ = self?.relieve(.memoryWarning) }
        })
        observers.add(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                         queue: nil) { [weak self] _ in
            onMainActor { _ = self?.relieve(.background) }
        })
        observers.add(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) {
            [weak self] _ in
            onMainActor { self?.logPowerState() }
        })
        observers.add(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                         queue: nil) { [weak self] _ in
            onMainActor { self?.logPowerState() }
        })
        subscription = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.pageChanged || event.type == NibEventType.sessionDocument,
                  let doc = event.doc else { return }
            onMainActor { self?.pageDidChange(doc) }
        }
    }

    func stop() {
        observers.removeAll()
        subscription?.cancel()
        subscription = nil
        pendingTrim?.cancel()
        pendingTrim = nil
        trimQueue = []
    }

    // MARK: Visibility

    /// Pages someone is looking at, per document: each window's current page, selection page and edited item's page,
    /// plus every page its canvas lays out inside the viewport (widened by `visibleMargin`).
    func visiblePages() -> [DocumentID: Set<PageID>] {
        guard let app = app else { return [:] }
        var out: [DocumentID: Set<PageID>] = [:]
        for session in app.services.sessions.sessions {
            guard let doc = session.document else { continue }
            var pages = out[doc] ?? []
            if let page = session.page { pages.insert(page) }
            if session.selection.doc == doc, let page = session.selection.page { pages.insert(page) }
            if let ref = session.editingTextRef, case let .item(d, page, _)? = NodeRef(ref), d == doc { pages.insert(page) }
            if let host = session.editor?.canvasHost, host.documentID == doc {
                pages.formUnion(onScreen(host, doc: doc, workspace: app.workspace))
            }
            out[doc] = pages
        }
        return out
    }

    private func onScreen(_ host: CanvasHost, doc: DocumentID, workspace: Workspace) -> Set<PageID> {
        guard workspace.isLoaded(doc), let content = try? workspace.content(doc) else { return [] }
        let bounds = host.canvasView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let area = bounds.insetBy(dx: -bounds.width * policy.visibleMargin, dy: -bounds.height * policy.visibleMargin)
        var out = Set<PageID>()
        for page in content.livePages {
            if let frame = host.pageFrame(page.id), frame.intersects(area) { out.insert(page.id) }
        }
        return out
    }

    // MARK: Relief

    /// Drops every cached page nobody is looking at (keeping `neighbourRadius` pages around visible ones) in every
    /// loaded document, then purges the renderer's caches for warnings and backgrounding.
    @discardableResult
    func relieve(_ reason: ReliefReason) -> ReliefReport {
        var report = ReliefReport(reason: reason)
        guard let app = app else { return report }
        let interval = signposter.beginInterval("memory.relief", id: signposter.makeSignpostID())
        report.footprintBefore = footprint()
        let workspace = app.workspace
        let visible = visiblePages()
        for doc in workspace.loadedDocuments.sorted(by: { $0.raw < $1.raw }) {
            let cached = workspace.cachedPages(doc)
            guard !cached.isEmpty else { continue }
            var keep = Set<PageID>()
            if let anchors = visible[doc], !anchors.isEmpty, let content = try? workspace.content(doc) {
                keep = PageRetention.keep(order: content.livePages.map { $0.id }, anchors: anchors,
                                          radius: policy.neighbourRadius).intersection(cached)
            }
            let evicted = cached.count - keep.count
            guard evicted > 0 else { continue }
            workspace.evictPages(doc, keeping: keep)
            report.evictedPages += evicted
            report.documents += 1
        }
        if reason.purgesRenderer, let renderer = app.services.renderer {
            renderer.purgeCaches()
            report.purgedRenderer = true
        }
        report.footprintAfter = footprint()
        signposter.endInterval("memory.relief", interval)
        if reason == .footprint { lastFootprintRelief = now() }
        remember(report)
        log.notice("""
            memory relief (\(reason.rawValue, privacy: .public)): evicted \(report.evictedPages, privacy: .public) \
            cached pages in \(report.documents, privacy: .public) documents; renderer caches \
            \(report.purgedRenderer ? "purged" : "kept", privacy: .public); footprint \
            \(MemoryFootprint.megabytes(report.footprintBefore), privacy: .public) -> \
            \(MemoryFootprint.megabytes(report.footprintAfter), privacy: .public); available \
            \(MemoryFootprint.megabytes(MemoryFootprint.available()), privacy: .public)
            """)
        return report
    }

    /// Trims one document's cached pages to `workingSetTarget` when they exceed `workingSetLimit`. Returns the
    /// number of pages dropped.
    @discardableResult
    func trimWorkingSet(_ doc: DocumentID) -> Int {
        guard let app = app, app.workspace.isLoaded(doc) else { return 0 }
        let workspace = app.workspace
        let cached = workspace.cachedPages(doc)
        guard cached.count > policy.workingSetLimit, let content = try? workspace.content(doc) else { return 0 }
        let keep = PageRetention.workingSet(order: content.livePages.map { $0.id }, cached: cached,
                                            anchors: visiblePages()[doc] ?? [], radius: policy.neighbourRadius,
                                            target: policy.workingSetTarget)
        let evicted = cached.count - keep.count
        guard evicted > 0 else { return 0 }
        workspace.evictPages(doc, keeping: keep)
        trimmedPages += evicted
        log.info("""
            working set: dropped \(evicted, privacy: .public) of \(cached.count, privacy: .public) cached pages \
            (limit \(self.policy.workingSetLimit, privacy: .public))
            """)
        return evicted
    }

    /// Footprint check after navigation: relieves once the §20 budget is exceeded, at most once per cooldown.
    @discardableResult
    func checkFootprint() -> ReliefReport? {
        guard let bytes = footprint(), bytes > policy.footprintSoftLimit else { return nil }
        if let last = lastFootprintRelief, now().timeIntervalSince(last) < policy.footprintCooldown { return nil }
        return relieve(.footprint)
    }

    // MARK: Events

    /// A window changed page or document: trim that document's working set and check the footprint `trimDelay`
    /// later (a burst of page changes while scrolling joins one pass).
    func pageDidChange(_ doc: DocumentID) {
        if !trimQueue.contains(doc) { trimQueue.append(doc) }
        guard pendingTrim == nil else { return }
        let delay = policy.trimDelay
        pendingTrim = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            // A cancelled trim (stop) leaves the queue and `pendingTrim` to whatever runs next.
            guard !Task.isCancelled, let self = self else { return }
            self.pendingTrim = nil
            let docs = self.trimQueue
            self.trimQueue = []
            for doc in docs { self.trimWorkingSet(doc) }
            self.checkFootprint()
        }
    }

    private func remember(_ report: ReliefReport) {
        reports.append(report)
        if reports.count > MemoryPressureCoordinator.reportLimit {
            reports.removeFirst(reports.count - MemoryPressureCoordinator.reportLimit)
        }
    }

    /// Low Power Mode and thermal state go to the log, so a diagnostics export shows the conditions the metrics and
    /// reliefs happened under.
    private func logPowerState() {
        let info = ProcessInfo.processInfo
        log.notice("""
            power: low power mode \(info.isLowPowerModeEnabled ? "on" : "off", privacy: .public), thermal state \
            \(PowerState.name(info.thermalState), privacy: .public)
            """)
    }
}

/// Notification observers, removed on `removeAll()` or when the owner (and so the bag) goes away: the coordinator is
/// main-actor isolated, so its own deinit cannot touch them.
final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    func removeAll() {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens = []
    }

    deinit { removeAll() }
}

enum PowerState {
    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Runs `body` on the main actor: inline when already on the main thread (notifications posted there, event bus
/// emits from commands), else on the next main-actor turn.
func onMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}
