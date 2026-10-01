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

    // ponytail: `JSONDecoder` is slow for big pages, most of all in Debug builds: `Stroke.init(from:)` unpacks every
    // point float through a string-keyed setter and `Item.init(from:)` probes 19 keys per item. `PageReader` builds the
    // stroke items this encoder writes directly and hands everything else to `JSONDecoder`. A fullFormat fast path in
    // `Stroke.unpack` (NibContracts) would make the points part of it unnecessary.
    static func decodeItems(_ data: Data) throws -> [Item] {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        if let page = PageReader.read(json) { return page.items }
        return try JSONDecoder().decode([Item].self, from: json)
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

/// Reads a page file's `[Item]` JSON. Stroke items exactly as `PackageCodec.encodeItems` writes them (sorted keys, no
/// whitespace, plain ASCII strings, points in `ptsB64`) are built straight from the bytes; every other element, and
/// every stroke holding a value this reader is not sure about, goes through `JSONDecoder` (in one batch). So the items
/// are always the ones `JSONDecoder().decode([Item].self, from: json)` returns. `read` returns nil when the JSON is
/// not a plain top-level array or an element does not decode: the caller then decodes the whole page, which also
/// reports the error.
struct PageReader {
    struct Page {
        var items: [Item]
        /// How many elements went through `JSONDecoder`.
        var decodedElements: Int
    }

    static func read(_ json: Data) -> Page? {
        json.withUnsafeBytes { raw -> Page? in
            guard raw.count >= 2, let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: raw.count, alignment: 1)
            defer { scratch.deallocate() }
            var reader = PageReader(p: base, n: raw.count, scratch: scratch)
            return reader.page()
        }
    }

    /// True when `StrokePoint` is ten `Float`s in `fullFormat` order on a little-endian host, i.e. laid out exactly
    /// like `ptsB64` bytes, so points are copied instead of assembled one by one.
    static let pointsAreRawFloats: Bool = {
        let fields: [PartialKeyPath<StrokePoint>] = [\.x, \.y, \.t, \.force, \.azimuth, \.altitude, \.roll, \.width,
                                                     \.height, \.opacity]
        let order = ["x", "y", "t", "force", "azimuth", "altitude", "roll", "width", "height", "opacity"]
        return StrokePoint.fullFormat == order && StrokePoint.fullStride == order.count
            && MemoryLayout<StrokePoint>.size == 40 && MemoryLayout<StrokePoint>.stride == 40 && 1.littleEndian == 1
            && fields.indices.allSatisfy { MemoryLayout<StrokePoint>.offset(of: fields[$0]) == $0 * 4 }
    }()

    /// Exactly what `Stroke.init(from:)` makes of decoded `ptsB64` bytes: little-endian Float32s in
    /// `StrokePoint.fullFormat` order, a trailing partial point dropped.
    static func points(_ data: Data) -> [StrokePoint] {
        let count = data.count / (StrokePoint.fullStride * MemoryLayout<Float>.size)
        guard pointsAreRawFloats else { return assembledPoints(data) }
        return [StrokePoint](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { raw in
                if count > 0, let from = raw.baseAddress, let to = buffer.baseAddress {
                    UnsafeMutableRawPointer(to).copyMemory(from: from, byteCount: count * MemoryLayout<StrokePoint>.stride)
                }
            }
            initialized = count
        }
    }

    /// `points` for a `StrokePoint` layout that does not match the bytes: `Stroke.unpack` over `fullFormat`, spelled out.
    static func assembledPoints(_ data: Data) -> [StrokePoint] {
        let fields = StrokePoint.fullFormat
        let stride = fields.count
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        var out: [StrokePoint] = []
        guard stride > 0 else { return out }
        out.reserveCapacity(floats.count / stride)
        var i = 0
        while i + stride <= floats.count {
            var point = StrokePoint(x: 0, y: 0, t: Float(out.count) * 0.008)
            for (k, field) in fields.enumerated() {
                switch field {
                case "x": point.x = floats[i + k]
                case "y": point.y = floats[i + k]
                case "t": point.t = floats[i + k]
                case "force": point.force = floats[i + k]
                case "azimuth": point.azimuth = floats[i + k]
                case "altitude": point.altitude = floats[i + k]
                case "roll": point.roll = floats[i + k]
                case "width": point.width = floats[i + k]
                case "height": point.height = floats[i + k]
                case "opacity": point.opacity = floats[i + k]
                default: break
                }
            }
            out.append(point)
            i += stride
        }
        return out
    }

    private let p: UnsafePointer<UInt8>
    private let n: Int
    /// Room for the unescaped base64 of one stroke (a page's size is enough for any of its strings).
    private let scratch: UnsafeMutableRawPointer
    /// Style objects decoded on this page so far: where their JSON is, and the style it decodes to. Strokes drawn
    /// with one pen share byte-identical style JSON, so each is decoded once.
    private var styles: [(start: Int, count: Int, style: InkStyle)] = []

    private mutating func page() -> Page? {
        guard p[0] == 0x5B, p[n - 1] == 0x5D else { return nil } // [ … ]
        var items: [Item] = []
        var others: [(index: Int, start: Int, end: Int)] = []
        var i = 1
        while i < n - 1 {
            if let read = stroke(at: i) {
                items.append(read.item)
                i = read.end
            } else {
                guard let end = valueEnd(i) else { return nil }
                others.append((items.count, i, end))
                items.append(Item(id: NibID(""), kind: .stroke)) // replaced by the batch decode below
                i = end
            }
            if i == n - 1 { break }
            guard p[i] == 0x2C, i + 1 < n - 1 else { return nil } // a comma, then another element
            i += 1
        }
        guard !others.isEmpty else { return Page(items: items, decodedElements: 0) }

        var batch = Data([0x5B])
        for (k, other) in others.enumerated() {
            if k > 0 { batch.append(0x2C) }
            batch.append(p + other.start, count: other.end - other.start)
        }
        batch.append(0x5D)
        guard let decoded = try? JSONDecoder().decode([Item].self, from: batch), decoded.count == others.count else {
            return nil
        }
        for (k, other) in others.enumerated() { items[other.index] = decoded[k] }
        return Page(items: items, decodedElements: others.count)
    }

    /// A stroke item in the exact form `encodeItems` writes, built the way `Item.init(from:)` and `Stroke.init(from:)`
    /// would; nil for anything else (other kinds, other keys, escapes, unusual numbers), which `JSONDecoder` reads.
    private mutating func stroke(at start: Int) -> (item: Item, end: Int)? {
        var i = start
        guard lit(&i, "{") else { return nil }
        var attachedTo: String?
        var createdBy: String?
        if lit(&i, #""attachedTo":"#) {
            guard let s = plainString(&i), lit(&i, ",") else { return nil }
            attachedTo = s
        }
        if lit(&i, #""createdBy":"#) {
            guard let s = plainString(&i), lit(&i, ",") else { return nil }
            createdBy = s
        }
        guard lit(&i, #""deleted":"#), let deleted = bool(&i),
              lit(&i, #","id":"#), let id = plainString(&i),
              lit(&i, #","kind":"stroke","layer":"#), let layer = int(&i),
              lit(&i, #","locked":"#), let locked = bool(&i),
              lit(&i, #","rev":"#), let revision = rev(&i),
              lit(&i, #","stroke":{"ptsB64":"#), let samples = points(&i),
              lit(&i, #","style":"#), let inkStyle = style(&i),
              lit(&i, #","t0":"#), let t0 = number(&i) else { return nil }
        var tapeRevealed = false
        if lit(&i, #","tapeRevealed":"#) {
            guard let b = bool(&i) else { return nil }
            tapeRevealed = b
        }
        guard lit(&i, #"},"z":"#), let z = plainString(&i), lit(&i, "}") else { return nil }
        var item = Item(id: NibID(id), kind: .stroke, z: z, layer: layer, locked: locked,
                        attachedTo: attachedTo.map { NibID($0) }, createdBy: createdBy,
                        stroke: Stroke(style: inkStyle, points: samples, t0: t0, tapeRevealed: tapeRevealed))
        item.rev = revision
        item.deleted = deleted
        return (item, i)
    }

    // MARK: Values

    private func lit(_ i: inout Int, _ s: StaticString) -> Bool {
        let count = s.utf8CodeUnitCount
        guard n - i >= count, memcmp(p + i, s.utf8Start, count) == 0 else { return false }
        i += count
        return true
    }

    private func bool(_ i: inout Int) -> Bool? {
        if lit(&i, "true") { return true }
        if lit(&i, "false") { return false }
        return nil
    }

    /// A JSON integer of at most 18 digits. Callers match the `,` or `}` after it, so a fraction or exponent fails.
    private func int(_ i: inout Int) -> Int? {
        var j = i
        let negative = j < n && p[j] == 0x2D // -
        if negative { j += 1 }
        let first = j
        var value = 0
        while j < n, p[j] >= 0x30, p[j] <= 0x39, j - first < 18 {
            value = value * 10 + Int(p[j] - 0x30)
            j += 1
        }
        guard j > first, p[first] != 0x30 || j == first + 1 else { return nil } // JSON has no leading zeros
        i = j
        return negative ? -value : value
    }

    /// A non-negative JSON number without exponent. `Double(String)` and `JSONDecoder` both read the decimal text
    /// with correct rounding (strtod), so they agree. Callers match the `,` or `}` after it, so an exponent fails.
    private func number(_ i: inout Int) -> Double? {
        var j = i
        while j < n, p[j] >= 0x30, p[j] <= 0x39 { j += 1 }
        let digits = j - i
        guard digits > 0, digits <= 20, p[i] != 0x30 || digits == 1 else { return nil }
        if j < n, p[j] == 0x2E { // .
            j += 1
            let fraction = j
            while j < n, p[j] >= 0x30, p[j] <= 0x39 { j += 1 }
            guard j > fraction, j - fraction <= 20 else { return nil }
        }
        guard let value = Double(String(decoding: UnsafeBufferPointer(start: p + i, count: j - i), as: UTF8.self)),
              value.isFinite else { return nil }
        i = j
        return value
    }

    /// A JSON string of printable ASCII without escapes.
    private func plainString(_ i: inout Int) -> String? {
        guard i < n, p[i] == 0x22 else { return nil }
        var j = i + 1
        while j < n, p[j] != 0x22 {
            guard p[j] >= 0x20, p[j] <= 0x7E, p[j] != 0x5C else { return nil }
            j += 1
        }
        guard j < n else { return nil }
        let s = String(decoding: UnsafeBufferPointer(start: p + i + 1, count: j - i - 1), as: UTF8.self)
        i = j + 1
        return s
    }

    /// A revision string in the plain form `Rev(string:)` reads: "<wallMs>.<counter>.<device>" in hex of at most
    /// 16, 8 and 8 digits. Looser spellings `Rev(string:)` also accepts are left to `JSONDecoder`.
    private func rev(_ i: inout Int) -> Rev? {
        guard i < n, p[i] == 0x22,
              let wall = hex(from: i + 1, atMost: 16), p[wall.end] == 0x2E,
              let counter = hex(from: wall.end + 1, atMost: 8), p[counter.end] == 0x2E,
              let device = hex(from: counter.end + 1, atMost: 8), p[device.end] == 0x22 else { return nil }
        i = device.end + 1
        return Rev(wallMs: wall.value, counter: UInt32(truncatingIfNeeded: counter.value),
                   device: UInt32(truncatingIfNeeded: device.value))
    }

    /// A run of 1…`atMost` hex digits at `start`, its value and the offset after it (a byte exists there). strtoull
    /// reads exactly the run: it starts with a digit (no space or sign to skip) and is not "0x"-prefixed.
    private func hex(from start: Int, atMost: Int) -> (value: UInt64, end: Int)? {
        guard start + 1 < n else { return nil }
        let first = p[start]
        guard (first >= 0x30 && first <= 0x39) || (first >= 0x61 && first <= 0x66) || (first >= 0x41 && first <= 0x46),
              (p[start + 1] | 0x20) != 0x78 else { return nil } // x or X
        var stop: UnsafeMutablePointer<CChar>?
        let value = strtoull(UnsafeRawPointer(p + start).assumingMemoryBound(to: CChar.self), &stop, 16)
        guard let stop = stop else { return nil }
        let end = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(stop))
        guard end > start, end - start <= atMost, end < n else { return nil }
        return (value, end)
    }

    /// The `ptsB64` string, whose only escapes may be `\/` (all `JSONEncoder` puts in base64), decoded like
    /// `Stroke.init(from:)` does.
    private func points(_ i: inout Int) -> [StrokePoint]? {
        guard i < n, p[i] == 0x22, let quote = memchr(p + i + 1, 0x22, n - i - 1) else { return nil }
        let end = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(quote))
        var s = i + 1
        var length = 0
        while s < end, let hit = memchr(p + s, 0x5C, end - s) {
            let at = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(hit))
            guard at + 1 < end, p[at + 1] == 0x2F else { return nil } // only \/
            (scratch + length).copyMemory(from: p + s, byteCount: at - s)
            length += at - s
            s = at + 1 // keeps the slash
        }
        (scratch + length).copyMemory(from: p + s, byteCount: end - s)
        length += end - s
        guard let data = Data(base64Encoded: Data(bytesNoCopy: scratch, count: length, deallocator: .none)) else {
            return nil
        }
        i = end + 1
        return PageReader.points(data)
    }

    private mutating func style(_ i: inout Int) -> InkStyle? {
        guard i < n, p[i] == 0x7B else { return nil } // {
        for known in styles where known.count <= n - i && memcmp(p + i, p + known.start, known.count) == 0 {
            i += known.count
            return known.style
        }
        guard let end = valueEnd(i),
              let style = try? JSONDecoder().decode(InkStyle.self, from: Data(bytes: p + i, count: end - i)) else {
            return nil
        }
        if styles.count < 64 { styles.append((i, end - i, style)) }
        i = end
        return style
    }

    // MARK: Structure

    /// Where the JSON value starting at `start` ends (exclusive): strings and containers are skipped whole (escapes and
    /// nesting included), scalars end before the next `,`, `]` or `}`. It does not validate; `JSONDecoder` does.
    private func valueEnd(_ start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < n {
            let b = p[i]
            if b == 0x22 { // "
                guard let close = closingQuote(i + 1) else { return nil }
                i = close + 1
                if depth == 0 { return i }
                continue
            }
            if b == 0x7B || b == 0x5B { // { [
                depth += 1
            } else if b == 0x7D || b == 0x5D { // } ]
                if depth == 0 { return i }
                depth -= 1
                if depth == 0 { return i + 1 }
            } else if b == 0x2C, depth == 0 { // ,
                return i
            }
            i += 1
        }
        return nil
    }

    /// The offset of the quote that closes a JSON string whose body starts at `from`: the next quote preceded by an
    /// even number of backslashes.
    private func closingQuote(_ from: Int) -> Int? {
        var j = from
        while j < n, let q = memchr(p + j, 0x22, n - j) {
            let k = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(q))
            var slashes = 0
            while p[k - 1 - slashes] == 0x5C { slashes += 1 }
            if slashes % 2 == 0 { return k }
            j = k + 1
        }
        return nil
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
