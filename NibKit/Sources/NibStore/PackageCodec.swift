import Foundation
import os
import NibContracts

/// The on-disk format of a `.nibnote` package (ARCHITECTURE §4.2) and the pure merge rules over it (§4.3):
/// `doc.<dev>.json` holds `DocumentContent`, `pages/<pageId>/<dev>.nibpage` holds LZFSE-compressed `[Item]` JSON, both
/// with stroke points in compact form. Every reader merges every device file last-writer-wins.
enum PackageCodec {
    /// Tombstones whose rev is older than this are dropped when this device writes its files.
    static let tombstoneLifetime: TimeInterval = 30 * 86_400
    /// Revs stamped further ahead than this come from a device with a wrong clock (`Rev.effective`).
    static let futureSkewMs: UInt64 = 86_400_000

    // MARK: File names

    /// A package file: the exact file of a device, or a provider conflict copy of one (both carry the device hex).
    enum Role: Equatable {
        case device(String)
        case conflictCopy(String)
    }

    static func headFileName(_ device: String) -> String { "doc.\(device).json" }
    static func pageFileName(_ device: String) -> String { "\(device).nibpage" }
    static func pageDirectory(_ page: PageID) -> String { "pages/\(page.raw)" }

    /// `doc.<8hex>.json` is a device file; any other name matching `^doc\.[0-9a-f]{8}.+\.json$`
    /// (`doc.1a2b3c4d 2.json`, `doc.1a2b3c4d (conflicted copy).json`) is a conflict copy. Anything else is not a head.
    static func headRole(_ name: String) -> Role? {
        role(name, exact: #"^doc\.[0-9a-f]{8}\.json$"#, copy: #"^doc\.[0-9a-f]{8}.+\.json$"#, hexOffset: 4)
    }

    /// `<8hex>.nibpage` is a device file; any other name matching `^[0-9a-f]{8}.+\.nibpage$` is a conflict copy.
    static func pageRole(_ name: String) -> Role? {
        role(name, exact: #"^[0-9a-f]{8}\.nibpage$"#, copy: #"^[0-9a-f]{8}.+\.nibpage$"#, hexOffset: 0)
    }

    private static func role(_ name: String, exact: String, copy: String, hexOffset: Int) -> Role? {
        let hex = String(name.dropFirst(hexOffset).prefix(8))
        if name.range(of: exact, options: .regularExpression) != nil { return .device(hex) }
        if name.range(of: copy, options: .regularExpression) != nil { return .conflictCopy(hex) }
        return nil
    }

    // MARK: Encoding

    /// Package encoder: compact stroke points (lossless base64 Float32) and sorted keys, so unchanged state writes
    /// identical bytes (no spurious uploads by file providers or WebDAV).
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.userInfo[.nibCompactPoints] = true
        return e
    }

    static func encodeHead(_ head: DocumentContent) throws -> Data {
        try encoder().encode(head)
    }

    static func decodeHead(_ data: Data) throws -> DocumentContent {
        try JSONDecoder().decode(DocumentContent.self, from: data)
    }

    static func encodeItems(_ items: [Item]) throws -> Data {
        let json = try encoder().encode(items)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    /// Pages above this many JSON bytes are decoded in parallel chunks.
    static let parallelDecodeMinimum = 64 * 1024

    // ponytail: parallel because `Stroke.init(from:)` unpacks every point float through a string-keyed setter, which
    // dominates decoding a big page. A fullFormat fast path in `Stroke.unpack` (NibContracts) would make one decode
    // fast enough on its own; drop the chunking then.
    static func decodeItems(_ data: Data) throws -> [Item] {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        let chunks = json.withUnsafeBytes { elementChunks($0, count: ProcessInfo.processInfo.activeProcessorCount) }
        guard chunks.count > 1 else { return try JSONDecoder().decode([Item].self, from: json) }
        var parts = [[Item]?](repeating: nil, count: chunks.count)
        parts.withUnsafeMutableBufferPointer { buffer in
            let out = buffer // each iteration writes only its own slot
            DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
                out[i] = try? JSONDecoder().decode([Item].self, from: chunks[i])
            }
        }
        let decoded = parts.compactMap { $0 }
        // A chunk that does not decode on its own: decode the whole page, which reports the real error.
        guard decoded.count == chunks.count else { return try JSONDecoder().decode([Item].self, from: json) }
        return Array(decoded.joined())
    }

    /// Cuts the top-level JSON array in `bytes` into up to `count` arrays of whole elements of about equal size, by
    /// one scan that tracks nesting depth and skips strings (escapes included). Returns no chunks for one core, small
    /// input, or input that does not start with `[`.
    static func elementChunks(_ bytes: UnsafeRawBufferPointer, count: Int) -> [Data] {
        let n = bytes.count
        guard count > 1, n >= parallelDecodeMinimum, let raw = bytes.baseAddress else { return [] }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), comma = UInt8(ascii: ",")
        let openArray = UInt8(ascii: "["), openObject = UInt8(ascii: "{")
        let closeArray = UInt8(ascii: "]"), closeObject = UInt8(ascii: "}")
        guard base[0] == openArray else { return [] }

        var cuts: [Int] = [] // offsets of commas between top-level elements
        var depth = 0
        var i = 0
        while i < n, cuts.count < count - 1 {
            let b = base[i]
            if b == quote {
                // The closing quote is the next one preceded by an even number of backslashes.
                var j = i + 1
                while true {
                    guard let q = memchr(raw + j, Int32(quote), n - j) else { return [] }
                    let k = raw.distance(to: UnsafeRawPointer(q))
                    var slashes = 0
                    while base[k - 1 - slashes] == backslash { slashes += 1 }
                    j = k + 1
                    if slashes % 2 == 0 { break }
                }
                i = j
                continue
            }
            if b == openArray || b == openObject {
                depth += 1
            } else if b == closeArray || b == closeObject {
                depth -= 1
            } else if b == comma, depth == 1, i >= n / count * (cuts.count + 1) {
                cuts.append(i)
            }
            i += 1
        }

        var chunks: [Data] = []
        var start = 1
        for end in cuts + [n] {
            var chunk = Data([openArray])
            chunk.append(base + start, count: end - start)
            if end < n { chunk.append(closeArray) }
            chunks.append(chunk)
            start = end + 1
        }
        return chunks.count > 1 ? chunks : []
    }

    // MARK: Merge

    static func ms(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970 * 1000)) }

    /// Last-writer-wins merge of device heads: meta = highest (effective) rev, records merged by id (`LWW.merge`).
    /// The first head wins rev ties, so callers pass this device's own file first.
    static func mergeHeads(_ heads: [DocumentContent], now: UInt64 = PackageCodec.ms(Date())) -> DocumentContent? {
        guard var out = heads.first else { return nil }
        for h in heads.dropFirst() {
            if h.meta.rev.effective(now: now) > out.meta.rev.effective(now: now) { out.meta = h.meta }
            out.pages = LWW.merge(out.pages, h.pages)
            out.outline = LWW.merge(out.outline, h.outline)
            out.blocks = LWW.merge(out.blocks, h.blocks)
            out.cards = LWW.merge(out.cards, h.cards)
            out.audio = LWW.merge(out.audio, h.audio)
        }
        return out
    }

    static func mergeItems(_ lists: [[Item]]) -> [Item] {
        guard let first = lists.first else { return [] }
        return lists.dropFirst().reduce(first) { LWW.merge($0, $1) }
    }

    static func revs<T: LWWRecord>(_ records: [T]) -> [NibID: Rev] {
        Dictionary(records.map { ($0.id, $0.rev) }, uniquingKeysWith: { a, _ in a })
    }

    /// Records of `incoming` that are new or carry a higher (effective) rev than `known`.
    static func newer<T: LWWRecord>(_ incoming: [T], than known: [NibID: Rev], now: UInt64) -> [T] {
        incoming.filter { r in
            guard let k = known[r.id] else { return true }
            return r.rev.effective(now: now) > k.effective(now: now)
        }
    }

    /// The part of `remote` that is newer than `known` (what `remoteChanges` hands to `applyRemote`).
    static func patch(_ doc: DocumentID, remote: DocumentContent, known: DocumentContent, now: UInt64) -> DocumentPatch {
        var p = DocumentPatch(doc: doc)
        if remote.meta.rev.effective(now: now) > known.meta.rev.effective(now: now) {
            var meta = remote.meta
            meta.id = doc
            p.meta = meta
        }
        p.pages = newer(remote.pages, than: revs(known.pages), now: now)
        p.outline = newer(remote.outline, than: revs(known.outline), now: now)
        p.blocks = newer(remote.blocks, than: revs(known.blocks), now: now)
        p.cards = newer(remote.cards, than: revs(known.cards), now: now)
        p.audio = newer(remote.audio, than: revs(known.audio), now: now)
        return p
    }

    // MARK: Clock skew

    static func isFuture(_ rev: Rev, now: UInt64) -> Bool { rev.wallMs > now &+ futureSkewMs }

    static func hasFutureRev(_ head: DocumentContent, now: UInt64) -> Bool {
        if isFuture(head.meta.rev, now: now) { return true }
        if head.pages.contains(where: { isFuture($0.rev, now: now) }) { return true }
        if head.outline.contains(where: { isFuture($0.rev, now: now) }) { return true }
        if head.blocks.contains(where: { isFuture($0.rev, now: now) }) { return true }
        if head.cards.contains(where: { isFuture($0.rev, now: now) }) { return true }
        return head.audio.contains { isFuture($0.rev, now: now) }
    }

    static func hasFutureRev(_ items: [Item], now: UInt64) -> Bool {
        items.contains { isFuture($0.rev, now: now) }
    }

    // MARK: Tombstones

    // ponytail: tombstones older than 30 days are dropped on write, so a device that stays offline (or never rewrites
    // its files) for longer can resurrect a deleted record. Add per-device watermarks if that matters.
    // Trashed pages (deleted + trashedAt) are recoverable, not tombstones, and are always kept.
    static func pruned(_ items: [Item], now: Date) -> [Item] {
        items.filter { !isExpired($0, now: now) }
    }

    static func pruned(_ head: DocumentContent, now: Date) -> DocumentContent {
        var h = head
        h.pages = h.pages.filter { $0.trashedAt != nil || !isExpired($0, now: now) }
        h.outline = h.outline.filter { !isExpired($0, now: now) }
        h.blocks = h.blocks.filter { !isExpired($0, now: now) }
        h.cards = h.cards.filter { !isExpired($0, now: now) }
        h.audio = h.audio.filter { !isExpired($0, now: now) }
        return h
    }

    static func isExpired<T: LWWRecord>(_ record: T, now: Date) -> Bool {
        guard record.deleted else { return false }
        return Double(record.rev.wallMs) < (now.timeIntervalSince1970 - tombstoneLifetime) * 1000
    }
}

/// File access to the packages of one device. Thread-agnostic: package URLs come from the thread-safe
/// `PackageLocator`, never from a main-actor type. Reads are plain (writers replace files atomically, so a read
/// always sees a whole file); writes are coordinated (`NSFileCoordinator`) and atomic.
struct PackageFiles {
    /// This device's 8 lowercase hex characters.
    let device: String
    let locator: PackageLocator

    static let log = Logger(subsystem: "app.nib", category: "store")

    /// What identifies a version of a file for change detection (`remoteChanges`).
    struct Stamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    struct Source {
        let name: String
        let url: URL
        let role: PackageCodec.Role
        let isOwn: Bool
        let stamp: Stamp

        var rank: Int {
            if isOwn { return 0 }
            if case .device = role { return 1 }
            return 2
        }
    }

    struct ReadResult<T> {
        var values: [T] = []
        /// Conflict copies that decoded (merged, so they may be deleted once this device's file holds them).
        var copies: [URL] = []
        /// Package-relative paths of files carrying revs more than 24 h in the future.
        var futureFiles: [String] = []
        /// Package-relative paths of files that exist but could not be decoded.
        var failures: [String] = []
        /// Stamps of every non-own file listed (decodable or not), keyed by package-relative path.
        var stamps: [String: Stamp] = [:]
    }

    func package(_ doc: DocumentID) throws -> URL {
        guard let url = locator.url(doc) else { throw NibError.notFound("document \(doc.raw)") }
        return url
    }

    static func key(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }

    static func stamp(_ url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }

    /// Head files of a package: this device's file first, then other devices' files, then conflict copies.
    func headSources(_ pkg: URL) throws -> [Source] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: pkg.path) else {
            throw NibError.notFound("document package \(pkg.lastPathComponent)")
        }
        return sources(names, in: pkg, role: PackageCodec.headRole)
    }

    /// Item files of one page (none when the page has never been written).
    func pageSources(_ pkg: URL, page: PageID) -> [Source] {
        let dir = pkg.appendingPathComponent(PackageCodec.pageDirectory(page), isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return sources(names, in: dir, role: PackageCodec.pageRole)
    }

    private func sources(_ names: [String], in dir: URL, role: (String) -> PackageCodec.Role?) -> [Source] {
        let own = PackageCodec.Role.device(device)
        let list = names.compactMap { name -> Source? in
            guard let r = role(name) else { return nil }
            let url = dir.appendingPathComponent(name)
            return Source(name: name, url: url, role: r, isOwn: r == own, stamp: PackageFiles.stamp(url))
        }
        return list.sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
    }

    /// Decodes `sources` (package-relative directory `dir`). Undecodable files are reported, never fatal: one bad
    /// file from another device must not stop the document from opening.
    func read<T>(_ sources: [Source], in dir: String, decode: (Data) throws -> T,
                 isFuture: (T) -> Bool) -> ReadResult<T> {
        var r = ReadResult<T>()
        for s in sources {
            let key = PackageFiles.key(dir, s.name)
            if !s.isOwn { r.stamps[key] = s.stamp }
            do {
                let value = try decode(Data(contentsOf: s.url))
                r.values.append(value)
                if isFuture(value) { r.futureFiles.append(key) }
                if case .conflictCopy = s.role { r.copies.append(s.url) }
            } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
                continue // removed between listing and reading (a merged conflict copy)
            } catch {
                PackageFiles.log.error("cannot read \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                r.failures.append(key)
            }
        }
        return r
    }

    /// The package folder of `doc`, which must exist: creating packages is the library's job (F002), and a write that
    /// races a move or delete must not leave a ghost package at the old path.
    static func existingPackage(_ doc: DocumentID, _ locator: PackageLocator) throws -> URL {
        guard let url = locator.url(doc) else { throw NibError.notFound("document \(doc.raw)") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NibError.notFound("document package \(url.lastPathComponent)")
        }
        return url
    }

    /// Writes this device's files with the full merged state it knows (expired tombstones dropped), then deletes the
    /// conflict copies whose content that state now holds. Never touches another device's file.
    func write(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]], deleting copies: [URL],
               now: Date) throws {
        let pkg = try PackageFiles.existingPackage(doc, locator)
        let fm = FileManager.default
        if let head = head {
            let data = try PackageCodec.encodeHead(PackageCodec.pruned(head, now: now))
            try PackageFiles.coordinatedWrite(data, to: pkg.appendingPathComponent(PackageCodec.headFileName(device)))
        }
        for (page, items) in pages {
            guard NibID.isValid(page.raw) else {
                PackageFiles.log.error("skipping page with invalid id \(page.raw, privacy: .public)")
                continue
            }
            let dir = pkg.appendingPathComponent(PackageCodec.pageDirectory(page), isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PackageCodec.encodeItems(PackageCodec.pruned(items, now: now))
            try PackageFiles.coordinatedWrite(data, to: dir.appendingPathComponent(PackageCodec.pageFileName(device)))
        }
        for url in copies { PackageFiles.coordinatedDelete(url) }
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let e = coordinationError { throw e }
        if let e = writeError { throw e }
    }

    static func coordinatedDelete(_ url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                         error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                PackageFiles.log.error("cannot delete \(target.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let e = coordinationError {
            PackageFiles.log.error("cannot coordinate deleting \(url.lastPathComponent, privacy: .public): \(e.localizedDescription, privacy: .public)")
        }
    }
}
