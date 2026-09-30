import Foundation

// MARK: - Format constants

public enum NibFormat {
    /// Major on-disk format version. Readers refuse to write packages with a newer major version.
    public static let version = 1
    /// Document package extension. The ONLY place it is spelled (plus project.yml). "nibnote", not "nib":
    /// `.nib` is the system-declared Interface Builder type. Folders named `*.nib` that contain `doc.*.json`
    /// are still accepted as a legacy import (F002, F064).
    public static let packageExtension = "nibnote"
    public static let legacyPackageExtension = "nib"
    public static let packageUTType = "app.nib.document"
    public static let pluginExtension = "nibplugin"
    public static let pluginUTType = "app.nib.plugin"
    /// Hidden folder at the library root holding trash, plugins, elements, templates, prefs, AI chats.
    public static let libraryDirectory = ".nib-library"
    public static let urlScheme = "nib"
}

public enum NibLimits {
    public static let layerCount = 5
    public static let maxNesting = 16
    public static let boardItemLimit = 100_000
    public static let aiToolResultBytes = 20_000
    public static let undoDepth = 200
    /// contracts-v2: largest file `CommandContext.inputFile` downloads (200 MB).
    public static let maxDownloadBytes = 200 * 1_048_576
    /// contracts-v2: how far an `ItemDrawer` may paint outside `Item.bounds` (arrowheads, nib width, connector labels,
    /// text overflow). The renderer pads culling and tile invalidation by it.
    public static let drawerMargin: Double = 12
    /// contracts-v2: most points one `ink.erase` path may carry.
    public static let maxErasePathPoints = 20_000
}

// MARK: - Identifiers

/// Identifier for every persisted record (documents, folders, pages, items, blocks, cards, clips).
/// Generated IDs are 12 Crockford-base32 characters. AI agents and plugins may supply their own
/// IDs (see `isValid`) so they can link records created in one batch.
public struct NibID: Hashable, Comparable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public var description: String { raw }
    public static func < (a: NibID, b: NibID) -> Bool { a.raw < b.raw }

    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    public static func make() -> NibID {
        var rng = SystemRandomNumberGenerator()
        var chars: [Character] = []
        chars.reserveCapacity(12)
        for _ in 0..<12 {
            let v: UInt64 = rng.next()
            chars.append(NibID.alphabet[Int(v % 32)])
        }
        return NibID(String(chars))
    }

    /// 1–64 characters of [A-Za-z0-9_-].
    public static func isValid(_ s: String) -> Bool {
        guard (1...64).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { NibID.allowed.contains($0) }
    }
}

public typealias DocumentID = NibID
public typealias PageID = NibID
public typealias ElementID = NibID
public typealias FolderID = NibID

// MARK: - Revisions (hybrid logical clock)

/// Last-writer-wins revision. Ordered by (wall ms, counter, device); encoded as a sortable hex string.
public struct Rev: Hashable, Comparable, Codable, CustomStringConvertible {
    public var wallMs: UInt64
    public var counter: UInt32
    public var device: UInt32

    public init(wallMs: UInt64, counter: UInt32, device: UInt32) {
        self.wallMs = wallMs
        self.counter = counter
        self.device = device
    }

    public static let zero = Rev(wallMs: 0, counter: 0, device: 0)

    public static func < (a: Rev, b: Rev) -> Bool {
        if a.wallMs != b.wallMs { return a.wallMs < b.wallMs }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device < b.device
    }

    public var description: String { String(format: "%012llx.%08x.%08x", wallMs, counter, device) }

    /// Revisions stamped more than 24 h in the future come from a device whose clock is wrong: they compare as if
    /// written at time 0, so every correctly-clocked edit beats them (they still merge when nothing else exists)
    /// until real time catches up. Used by `LWW.merge` and `Workspace.merge`; F025 reports such files in sync.status.
    public func effective(now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> Rev {
        wallMs > now + 86_400_000 ? Rev(wallMs: 0, counter: counter, device: device) : self
    }

    public init?(string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 3,
              let w = UInt64(parts[0], radix: 16),
              let c = UInt32(parts[1], radix: 16),
              let d = UInt32(parts[2], radix: 16) else { return nil }
        self.init(wallMs: w, counter: c, device: d)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let r = Rev(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid rev '\(s)'")
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Hybrid logical clock. One per app process (`NibApp.clock`). Thread-safe.
public final class HLCClock {
    public let device: UInt32
    private var last = Rev.zero
    private let lock = NSLock()

    public init(device: UInt32) { self.device = device }

    /// contracts-v2: `device` as 8 lowercase hex characters (per-device file names).
    public var deviceHex: String { String(format: "%08x", device) }

    public func tick() -> Rev {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now > last.wallMs {
            last = Rev(wallMs: now, counter: 0, device: device)
        } else {
            last = Rev(wallMs: last.wallMs, counter: last.counter &+ 1, device: device)
        }
        return last
    }

    /// Advances the clock past a remote revision (remote wall time is capped at now + 24 h).
    public func observe(_ remote: Rev) {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let wall = min(remote.wallMs, now + 86_400_000)
        if wall > last.wallMs || (wall == last.wallMs && remote.counter > last.counter) {
            last = Rev(wallMs: wall, counter: remote.counter, device: device)
        }
    }
}

// MARK: - Fractional ordering keys

/// Base-62 fractional index used for z-order, page order, block/card/outline order.
/// Keys never end in "0", so a key can always be generated between any two keys.
public enum FractionalIndex {
    private static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static func value(_ c: Character) -> Int { digits.firstIndex(of: c) ?? 0 }

    /// A key strictly between `a` and `b` (nil = unbounded). Precondition: a < b when both are given.
    public static func between(_ a: String?, _ b: String?) -> String {
        String(mid(Array(a ?? ""), b.map { Array($0) }))
    }

    /// contracts-v2: `count` increasing keys strictly between `a` and `b` (nil = unbounded), built by bisection so they
    /// stay short: about log62(count) + 1 characters (10,000 keys ≤ 4 characters), where `sequence` grows by one
    /// character every few keys. For imports and batch inserts. Precondition: a < b when both are given.
    public static func balanced(count: Int, after a: String? = nil, before b: String? = nil) -> [String] {
        guard count > 0 else { return [] }
        var out = [String](repeating: "", count: count)
        func fill(_ lo: Int, _ hi: Int, _ left: String?, _ right: String?) {
            guard lo <= hi else { return }
            let mid = (lo + hi) / 2
            let key = between(left, right)
            out[mid] = key
            fill(lo, mid - 1, left, key)
            fill(mid + 1, hi, key, right)
        }
        fill(0, count - 1, a, b)
        return out
    }

    /// `count` increasing keys after `a`.
    public static func sequence(after a: String?, count: Int) -> [String] {
        var out: [String] = []
        var last = a
        for _ in 0..<max(0, count) {
            let k = between(last, nil)
            out.append(k)
            last = k
        }
        return out
    }

    private static func mid(_ a: [Character], _ b: [Character]?) -> [Character] {
        if let b = b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + mid(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let da = a.isEmpty ? 0 : value(a[0])
        let db = b.map { $0.isEmpty ? 62 : value($0[0]) } ?? 62
        if db - da > 1 { return [digits[(da + db) / 2]] }
        if let b = b, b.count > 1 { return [b[0]] }
        return [digits[da]] + mid(Array(a.dropFirst()), nil)
    }
}

// MARK: - Colors and assets

/// sRGB color with alpha. Encoded as "#RRGGBBAA".
public struct RGBA: Hashable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Accepts "#RRGGBB" or "#RRGGBBAA" (the "#" is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF), 255)
        } else {
            self.init(UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
    }

    public var hex: String { String(format: "#%02X%02X%02X%02X", r, g, b, a) }
    public var description: String { hex }
    public var alpha: Double { Double(a) / 255 }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r, g, b, UInt8(max(0, min(255, (alpha * 255).rounded()))))
    }

    /// contracts-v2: alpha a highlighter colour is stored with (the renderer blends it per paper, see `NibHighlighter`).
    public static let highlighterAlpha: UInt8 = 0x80

    public static let black = RGBA(0x1A, 0x1A, 0x1A)
    public static let white = RGBA(0xFF, 0xFF, 0xFF)
    public static let clear = RGBA(0, 0, 0, 0)
    public static let highlighterYellow = RGBA(0xFF, 0xE0, 0x3D, 0x80)
    public static let paperYellow = RGBA(0xFD, 0xF6, 0xDC)
    public static let paperDark = RGBA(0x24, 0x24, 0x26)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = RGBA(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid color '\(s)', expected #RRGGBB or #RRGGBBAA")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// Content-addressed file inside a document package: "assets/<sha256 hex>.<ext>". Immutable.
public struct AssetRef: Hashable, Codable, CustomStringConvertible {
    public var name: String

    public init(_ name: String) { self.name = name }

    public var ext: String { (name as NSString).pathExtension.lowercased() }
    public var description: String { name }

    public init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
