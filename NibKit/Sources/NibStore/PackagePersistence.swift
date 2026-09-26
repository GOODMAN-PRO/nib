import Foundation
import os
import NibContracts

/// Documents whose head was saved by a newer Nib (`meta.format > NibFormat.version`, ARCHITECTURE §4.2): they open
/// read-only and nothing is written to them. Thread-safe (the asset store asks off-main). `published` is the flag other
/// features read with `services.get("store.readOnly", as: NSSet.self)`: the raw ids of read-only documents, updated on
/// the main actor whenever a head is loaded.
final class ReadOnlyGate {
    let published = NSMutableSet()
    private var ids = Set<DocumentID>()
    private let lock = NSLock()

    func contains(_ doc: DocumentID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(doc)
    }

    func set(_ doc: DocumentID, readOnly: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if readOnly {
            ids.insert(doc)
            published.add(doc.raw)
        } else {
            ids.remove(doc)
            published.remove(doc.raw)
        }
    }

    static func refusal(_ doc: DocumentID) -> NibError {
        NibError(.unsupported, "document \(doc.raw) was saved by a newer version of Nib and is read-only",
                 hint: "update Nib to edit it")
    }
}

/// `sync.status` payloads posted by the store: {state: "warning" | "error", source: "store", reason, message, files?}.
/// Reasons: newerFormat (opened read-only), futureRevision (a device clock > 24 h ahead), unreadable, writeFailed,
/// walFailed.
enum StoreStatus {
    static func payload(_ state: String, _ reason: String, _ message: String, files: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["state": .string(state), "source": "store", "reason": .string(reason),
                                      "message": .string(message)]
        if !files.isEmpty { o["files"] = .array(files.map { .string($0) }) }
        return .object(o)
    }

    static let newerFormat = payload("warning", "newerFormat",
                                     "Saved by a newer version of Nib, so it opens read-only until Nib is updated.")
}

/// Changes not on disk yet: the latest head and page snapshots, plus merged conflict copies to delete.
struct PendingWrite {
    var head: DocumentContent?
    var pages: [PageID: [Item]] = [:]
    var copies: Set<URL> = []
    let since = Date()

    var isEmpty: Bool { head == nil && pages.isEmpty && copies.isEmpty }

    /// This (older) state with `newer` merged over it last-writer-wins: `newer`'s snapshots, plus any record only this
    /// one holds or holds at a higher rev.
    func merged(with newer: PendingWrite, now: UInt64) -> PendingWrite {
        var out = self
        if let h = newer.head { out.head = head.flatMap { PackageCodec.mergeHeads([h, $0], now: now) } ?? h }
        for (page, items) in newer.pages { out.pages[page] = pages[page].map { LWW.merge(items, $0) } ?? items }
        out.copies.formUnion(newer.copies)
        return out
    }
}

/// What failed package writes left unsaved, per document. Owned by the persistence's serial queue and touched only
/// there. Every later write of the document merges it in before writing, and the write-ahead log is truncated only
/// after such a write succeeds. So a flush that runs between a failed background write and its retry cannot truncate
/// the log while the failed changes exist only in memory.
final class UnsavedWrites {
    private var jobs: [DocumentID: PendingWrite] = [:]

    /// What to write now: the unsaved changes of `doc` with `job` merged over them, or nil when there is nothing.
    func take(_ doc: DocumentID, adding job: PendingWrite, now: UInt64) -> PendingWrite? {
        let all = jobs.removeValue(forKey: doc).map { $0.merged(with: job, now: now) } ?? job
        return all.isEmpty ? nil : all
    }

    /// `job` did not reach the disk: the next write of `doc` takes it along.
    func keep(_ job: PendingWrite, for doc: DocumentID) {
        jobs[doc] = job
    }

    func job(_ doc: DocumentID) -> PendingWrite? {
        jobs[doc]
    }

    var documents: [DocumentID] {
        Array(jobs.keys)
    }
}

/// `DocumentPersistence` over `.nibnote` packages in the library folder (ARCHITECTURE §4.2–4.3).
///
/// - Reads merge EVERY device file of the head / a page (conflict copies included) last-writer-wins; merged
///   conflict copies are deleted once this device's file holds their content.
/// - `didChange` snapshots on the main actor, appends the payload to the write-ahead log and schedules a debounced
///   write (1.5 s) on one serial background queue; `flush` writes synchronously. This device writes only its own
///   files, and they hold the full merged state it knows.
/// - A failed write keeps its changes on that queue (`UnsavedWrites`), and every later write of the document merges
///   them in. The log is truncated only after a write that holds everything the log recorded, so every logged change
///   is always either in the package files or still in the log.
/// - `remoteChanges` re-reads other devices' files whose stamp changed and returns the records newer than the copy
///   this device has in memory.
@MainActor
final class PackagePersistence: DocumentPersistence {
    /// What this device has in memory: the merged head and the item revs of pages loaded or written through it.
    private struct Known {
        var head: DocumentContent
        var itemRevs: [PageID: [NibID: Rev]] = [:]
    }

    let files: PackageFiles
    let wal: WriteAheadLog
    let gate: ReadOnlyGate
    private let events: EventBus?
    private let debounce: TimeInterval
    private let maxDelay: TimeInterval
    private let io = DispatchQueue(label: "app.nib.store.io", qos: .utility)
    /// Only touched on `io`.
    private let unsaved = UnsavedWrites()
    private let log = Logger(subsystem: "app.nib", category: "store")
    private var known: [DocumentID: Known] = [:]
    /// Changes not handed to `io` yet.
    private var pending: [DocumentID: PendingWrite] = [:]
    private var timers: [DocumentID: Task<Void, Never>] = [:]
    /// Stamps of other devices' files as last read, keyed by package-relative path.
    private var seen: [DocumentID: [String: PackageFiles.Stamp]] = [:]

    /// `device` is this device's 8 lowercase hex characters (`DeviceIdentity.hex`); package URLs come from `locator`.
    init(device: String, locator: PackageLocator, events: EventBus?, gate: ReadOnlyGate,
         walDirectory: URL = WriteAheadLog.defaultDirectory, debounce: TimeInterval = 1.5, maxDelay: TimeInterval = 10) {
        files = PackageFiles(device: device, locator: locator)
        wal = WriteAheadLog(directory: walDirectory)
        self.gate = gate
        self.events = events
        self.debounce = debounce
        self.maxDelay = maxDelay
    }

    // MARK: Loading

    func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        let pkg = try files.package(doc)
        let now = PackageCodec.ms(Date())
        // Drain queued log appends and writes before reading the files, so a write in flight is in them (it truncates
        // the log it covered). A failed write's head is still in the log, or at least in the unsaved writes (when
        // logging failed too).
        let wal = self.wal, unsaved = self.unsaved
        let (logged, failedHead) = io.sync { (wal.read(doc), unsaved.job(doc)?.head) }
        let sources = try files.headSources(pkg)
        let read = files.read(sources, in: "", decode: PackageCodec.decodeHead) { PackageCodec.hasFutureRev($0, now: now) }
        report(doc, read)
        var candidates = read.values + logged.compactMap { $0.head }
        if let kept = failedHead { candidates.append(kept) }
        if let unwritten = pending[doc]?.head { candidates.append(unwritten) }
        guard var head = PackageCodec.mergeHeads(candidates, now: now) else {
            if read.failures.isEmpty { throw NibError.notFound("document \(doc.raw)") }
            throw NibError(.internalError, "document \(doc.raw) could not be read (\(read.failures.joined(separator: ", ")))")
        }
        head.meta.id = doc

        // Any device file from a newer major format makes the whole document read-only (its records may not survive
        // being rewritten by this build).
        let format = candidates.map { $0.meta.format }.max() ?? NibFormat.version
        let readOnly = format > NibFormat.version
        gate.set(doc, readOnly: readOnly)
        if readOnly {
            log.error("\(doc.raw, privacy: .public) has format \(format) > \(NibFormat.version): read-only")
            emit(doc, StoreStatus.newerFormat)
        }
        known[doc] = Known(head: head)
        seen[doc] = read.stamps

        // Replay: pages logged but not written before the app died, merged over what the device files hold.
        var recovered: [PageID: [Item]] = [:]
        for entry in logged {
            for (raw, items) in entry.pages {
                let page = PageID(raw)
                recovered[page] = LWW.merge(recovered[page] ?? [], items)
            }
        }
        var copies = read.copies
        for (page, items) in recovered where NibID.isValid(page.raw) {
            let disk = mergedPage(doc, pkg, page, now: now)
            recovered[page] = LWW.merge(disk.items, items)
            copies += disk.read.copies
        }
        if !readOnly, !logged.isEmpty || !copies.isEmpty {
            var p = pending[doc] ?? PendingWrite()
            p.head = head
            for (page, items) in recovered { p.pages[page] = LWW.merge(items, p.pages[page] ?? []) }
            p.copies.formUnion(copies)
            pending[doc] = p
            scheduleWrite(doc)
        }
        return head
    }

    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        guard NibID.isValid(page.raw) else { throw NibError.invalid("invalid page id '\(page.raw)'") }
        let pkg = try files.package(doc)
        let disk = mergedPage(doc, pkg, page, now: PackageCodec.ms(Date()))
        let items = disk.items
        seen[doc, default: [:]].merge(disk.read.stamps) { _, new in new }
        known[doc]?.itemRevs[page] = PackageCodec.revs(items)
        if !disk.read.copies.isEmpty, !gate.contains(doc) {
            var p = pending[doc] ?? PendingWrite()
            p.pages[page] = items
            p.copies.formUnion(disk.read.copies)
            pending[doc] = p
            scheduleWrite(doc)
        }
        return items
    }

    /// A page as this device knows it: every device file (and conflict copy) merged, then what is not written yet.
    /// Queued log appends and writes are drained first, so the files hold a write that was in flight. The log and the
    /// unsaved writes hold what a failed write left behind, and pending snapshots hold what is not queued yet.
    /// Unreadable and clock-skewed files are reported.
    private func mergedPage(_ doc: DocumentID, _ pkg: URL, _ page: PageID,
                            now: UInt64) -> (items: [Item], read: PackageFiles.ReadResult<[Item]>) {
        let wal = self.wal, unsaved = self.unsaved
        let (logged, failedItems) = io.sync { (wal.read(doc), unsaved.job(doc)?.pages[page]) }
        let read = files.read(files.pageSources(pkg, page: page), in: PackageCodec.pageDirectory(page),
                              decode: PackageCodec.decodeItems) { PackageCodec.hasFutureRev($0, now: now) }
        report(doc, read)
        var items = PackageCodec.mergeItems(read.values)
        for entry in logged { if let changed = entry.pages[page.raw] { items = LWW.merge(items, changed) } }
        if let kept = failedItems { items = LWW.merge(items, kept) }
        if let unwritten = pending[doc]?.pages[page] { items = LWW.merge(items, unwritten) }
        return (items, read)
    }

    // MARK: Saving

    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        guard head != nil || !pages.isEmpty else { return }
        if let h = head {
            if known[doc] == nil { known[doc] = Known(head: h) } else { known[doc]?.head = h }
        }
        // The log gets only the items that changed since this device last saw the page (loaded, logged or received):
        // replay merges log entries over the files last-writer-wins, and the log is truncated only after the whole
        // pending state reached the disk, so the replayed state is the same as logging whole pages.
        var changed: [String: [Item]] = [:]
        for (page, items) in pages {
            let revs = known[doc]?.itemRevs[page] ?? [:]
            changed[page.raw] = items.filter { revs[$0.id] != $0.rev }
            known[doc]?.itemRevs[page] = PackageCodec.revs(items)
        }
        guard !gate.contains(doc) else {
            log.error("not saving \(doc.raw, privacy: .public): \(ReadOnlyGate.refusal(doc).message, privacy: .public)")
            return
        }
        var p = pending[doc] ?? PendingWrite()
        if let h = head { p.head = h }
        for (page, items) in pages { p.pages[page] = items }
        pending[doc] = p

        let entry = WriteAheadLog.Entry(head: head, pages: changed)
        let wal = self.wal, events = self.events, log = self.log
        io.async {
            do {
                try wal.append(entry, doc: doc)
            } catch {
                log.error("write-ahead log of \(doc.raw, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                let payload = StoreStatus.payload("error", "walFailed",
                                                  "Recent changes could not be logged: \(error.localizedDescription)")
                DispatchQueue.main.async { events?.emit(NibEventType.syncStatus, doc: doc, payload: payload) }
            }
        }
        scheduleWrite(doc)
    }

    func flush(_ doc: DocumentID) {
        write(doc, synchronously: true)
    }

    /// Writes every document with pending or unsaved changes (the app is leaving the foreground).
    func flushAll() {
        let unsaved = self.unsaved
        let unsavedDocs = io.sync { unsaved.documents }
        for doc in Set(pending.keys).union(unsavedDocs) { write(doc, synchronously: true) }
    }

    /// Waits until queued log appends and writes have finished.
    func waitForIO() {
        io.sync {}
    }

    /// Debounced write, bounded: once changes have waited `maxDelay`, later changes stop pushing the running timer
    /// back, so continuous inking still reaches the disk and the write-ahead log stays short.
    private func scheduleWrite(_ doc: DocumentID) {
        if timers[doc] != nil, let since = pending[doc]?.since, Date().timeIntervalSince(since) >= maxDelay { return }
        timers[doc]?.cancel()
        let delay = UInt64(max(0, debounce) * 1_000_000_000)
        timers[doc] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.write(doc, synchronously: false)
        }
    }

    /// Hands the pending changes of `doc` to `io` and writes them there, together with whatever earlier writes left
    /// unsaved; `synchronously` waits for the write. The log is truncated only when that combined write succeeds.
    /// Internal so tests can start a background write the way the debounce timer does.
    func write(_ doc: DocumentID, synchronously: Bool) {
        timers.removeValue(forKey: doc)?.cancel()
        let job = pending.removeValue(forKey: doc) ?? PendingWrite()
        guard !gate.contains(doc) else {
            if !job.isEmpty {
                log.error("not saving \(doc.raw, privacy: .public): \(ReadOnlyGate.refusal(doc).message, privacy: .public)")
            }
            if synchronously { io.sync {} }
            return
        }
        let files = self.files, wal = self.wal, unsaved = self.unsaved
        let run = { () -> Error? in
            // A failed write's retry may not be queued yet, so its changes may exist only here and in the log.
            // They go into this write, so truncating the log below never drops a change that is not on disk.
            guard let all = unsaved.take(doc, adding: job, now: PackageCodec.ms(Date())) else { return nil }
            do {
                try files.write(doc, head: all.head, pages: all.pages, deleting: Array(all.copies), now: Date())
                wal.truncate(doc)
                return nil
            } catch {
                unsaved.keep(all, for: doc)
                return error
            }
        }
        if synchronously {
            if let error = io.sync(execute: run) { failed(doc, error) }
        } else {
            io.async {
                guard let error = run() else { return }
                Task { @MainActor in self.failed(doc, error) }
            }
        }
    }

    /// Reports a failed write. The unsaved writes hold its changes, and so does the log; the next write of `doc`
    /// takes them along. That write is the retry scheduled after the debounce, unless the package is gone. Then the
    /// next change or flush retries, because the package may have moved and the library points the locator at the new
    /// place.
    private func failed(_ doc: DocumentID, _ error: Error) {
        let e = NibError.wrap(error)
        log.error("saving \(doc.raw, privacy: .public) failed: \(e.message, privacy: .public)")
        emit(doc, StoreStatus.payload("error", "writeFailed", "Changes could not be saved: \(e.message)"))
        if e.code != .notFound { scheduleWrite(doc) }
    }

    /// Drops what this device remembers of a closed document (the workspace flushed it before closing).
    func forget(_ doc: DocumentID) {
        known[doc] = nil
        seen[doc] = nil
    }

    // MARK: Package files, remote changes

    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/")
        guard !relativePath.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw NibError.invalid("'\(relativePath)' is not a path inside the document package", path: "$.relativePath")
        }
        let url = try PackageFiles.existingPackage(doc, files.locator).appendingPathComponent(parts.joined(separator: "/"))
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            if gate.contains(doc) { throw ReadOnlyGate.refusal(doc) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return url
    }

    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? {
        guard var k = known[doc] else { return nil }
        let pkg = try files.package(doc)
        let now = PackageCodec.ms(Date())
        var stamps = seen[doc] ?? [:]
        func changed(_ sources: [PackageFiles.Source], in dir: String) -> [PackageFiles.Source] {
            sources.filter { !$0.isOwn && stamps[PackageFiles.key(dir, $0.name)] != $0.stamp }
        }

        var patch = DocumentPatch(doc: doc)
        var headCopies: [URL] = []
        let headSources = try files.headSources(pkg)
        let heads = files.read(changed(headSources, in: ""), in: "", decode: PackageCodec.decodeHead) {
            PackageCodec.hasFutureRev($0, now: now)
        }
        report(doc, heads)
        stamps.merge(heads.stamps) { _, new in new }
        if let remote = PackageCodec.mergeHeads(heads.values, now: now) {
            patch = PackageCodec.patch(doc, remote: remote, known: k.head, now: now)
            if var merged = PackageCodec.mergeHeads([k.head, remote], now: now) {
                merged.meta.id = doc
                k.head = merged
            }
            headCopies = heads.copies
            if heads.values.contains(where: { $0.meta.format > NibFormat.version }), !gate.contains(doc) {
                gate.set(doc, readOnly: true)
                emit(doc, StoreStatus.newerFormat)
            }
        }

        var pageCopies: [PageID: [URL]] = [:]
        for (page, revs) in k.itemRevs {
            let dir = PackageCodec.pageDirectory(page)
            let read = files.read(changed(files.pageSources(pkg, page: page), in: dir), in: dir,
                                  decode: PackageCodec.decodeItems) { PackageCodec.hasFutureRev($0, now: now) }
            report(doc, read)
            stamps.merge(read.stamps) { _, new in new }
            let newer = PackageCodec.newer(PackageCodec.mergeItems(read.values), than: revs, now: now)
            if !newer.isEmpty {
                patch.items[page.raw] = newer
                for item in newer { k.itemRevs[page]?[item.id] = item.rev }
            }
            if !read.copies.isEmpty { pageCopies[page] = read.copies }
        }
        seen[doc] = stamps
        known[doc] = k

        // Merged conflict copies go into this device's files, then they are deleted.
        if !gate.contains(doc), !headCopies.isEmpty || !pageCopies.isEmpty {
            var p = pending[doc] ?? PendingWrite()
            if !headCopies.isEmpty {
                p.head = PackageCodec.mergeHeads([k.head] + (p.head.map { [$0] } ?? []), now: now)
            }
            for (page, urls) in pageCopies {
                p.pages[page] = LWW.merge(mergedPage(doc, pkg, page, now: now).items, p.pages[page] ?? [])
                p.copies.formUnion(urls)
            }
            p.copies.formUnion(headCopies)
            pending[doc] = p
            scheduleWrite(doc)
        }
        return patch.isEmpty ? nil : patch
    }

    // MARK: Status

    private func emit(_ doc: DocumentID, _ payload: JSONValue) {
        events?.emit(NibEventType.syncStatus, doc: doc, payload: payload)
    }

    private func report<T>(_ doc: DocumentID, _ read: PackageFiles.ReadResult<T>) {
        if !read.futureFiles.isEmpty {
            log.warning("\(doc.raw, privacy: .public): revisions more than 24 h ahead in \(read.futureFiles.joined(separator: ", "), privacy: .public)")
            emit(doc, StoreStatus.payload("warning", "futureRevision",
                                          "A device's clock is more than 24 hours ahead: its changes lose to newer edits until the clock is corrected.",
                                          files: read.futureFiles))
        }
        if !read.failures.isEmpty {
            emit(doc, StoreStatus.payload("error", "unreadable", "Some sync files of this document could not be read.",
                                          files: read.failures))
        }
    }
}
