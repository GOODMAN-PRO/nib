import Foundation
import CoreGraphics
import ImageIO
import NibContracts

/// Page thumbnails and previews (library grid, page sidebar): an in-memory `NSCache` in front of PNG files in
/// `Caches/Nib/previews/<doc>/<page>/<maxRev>-<digest>-<px>.png`. Keys are made of the ids, the page's highest
/// revision and an FNV-1a digest of every (id, rev) of the page record and its items (tombstones included), never
/// Swift `Hasher` values, so a file stays valid across launches and any change produces a new key — including a
/// merged remote record whose rev is older than the page's newest one. Writing a key removes the page's other files.
final class ThumbnailCache {
    struct Key {
        let doc: DocumentID
        let page: PageID
        let rev: Rev
        let digest: UInt64
        let size: Int

        var pageKey: String { TileCache.pageKey(doc, page) }
        /// "<maxRev>-<digest>-": every file of this page content, whatever its size.
        var contentPrefix: String { rev.description + "-" + String(format: "%016llx", digest) + "-" }
        var memoryKey: String { pageKey + "|" + contentPrefix + String(size) }
        var fileName: String { contentPrefix + String(size) + ".png" }
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
    }

    let directory: URL?
    private let memory = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    /// Page key → memory keys, so `forget` can drop one page's thumbnails.
    private var index: [String: Set<String>] = [:]

    init(directory: URL?) {
        self.directory = directory
        memory.totalCostLimit = 48 << 20
    }

    /// nil when there is no cache folder or an id is not a plain NibID (never a path outside the folder).
    func fileURL(_ key: Key) -> URL? {
        guard let dir = directory, NibID.isValid(key.doc.raw), NibID.isValid(key.page.raw) else { return nil }
        return dir.appendingPathComponent(key.doc.raw, isDirectory: true)
            .appendingPathComponent(key.page.raw, isDirectory: true)
            .appendingPathComponent(key.fileName)
    }

    func memoryImage(_ key: Key) -> CGImage? { memory.object(forKey: key.memoryKey as NSString) }

    func remember(_ image: CGImage, _ key: Key) {
        lock.lock()
        index[key.pageKey, default: []].insert(key.memoryKey)
        lock.unlock()
        memory.setObject(image, forKey: key.memoryKey as NSString, cost: image.bytesPerRow * image.height)
    }

    /// Disk read (render workers only).
    func diskImage(_ key: Key) -> CGImage? {
        fileURL(key).flatMap { PNGCodec.decode(url: $0) }
    }

    /// Disk write (render workers only); older revisions of the page are removed.
    func write(_ image: CGImage, _ key: Key) {
        guard let url = fileURL(key), let png = PNGCodec.encode(image) else { return }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            return
        }
        let current = key.contentPrefix
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(current) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    func forget(pageKey: String) {
        lock.lock()
        let keys = index.removeValue(forKey: pageKey) ?? []
        lock.unlock()
        for k in keys { memory.removeObject(forKey: k as NSString) }
    }

    func purgeMemory() {
        lock.lock()
        index.removeAll()
        lock.unlock()
        memory.removeAllObjects()
    }
}

/// FNV-1a 64: a content digest that is stable across launches and devices (Swift `Hasher` is seeded per process).
struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ byte: UInt8) { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }

    mutating func add(_ s: String) {
        for b in s.utf8 { add(b) }
        add(UInt8(0))
    }

    mutating func add(_ n: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { add(UInt8(truncatingIfNeeded: n >> UInt64(shift))) }
    }

    mutating func add(_ r: Rev) {
        add(r.wallMs)
        add(UInt64(r.counter) << 32 | UInt64(r.device))
    }
}

/// PNG through ImageIO (thread-safe; no UIKit).
enum PNGCodec {
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func decode(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
