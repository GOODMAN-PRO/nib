import Foundation
import CoreGraphics
import ImageIO
import NibContracts

/// Page thumbnails and previews (library grid, page sidebar): an in-memory `NSCache` in front of PNG files in
/// `Caches/Nib/previews/<doc>/<page>/<rev>_<px>.png`. `rev` is the page's content revision: the newest of the page
/// record's rev and `Workspace.contentRevision` (contracts-v2 G9), so a disk hit never loads the page's items when
/// persistence knows that revision. Ids and revisions only, never Swift `Hasher` values, so a file stays valid across
/// launches. Writing a key removes the page's other files. Next to them, `looks.txt` lists the registry entries the
/// render used (`PageLooks` keys), so a template or drawer change after launch drops exactly the pages it affects.
///
/// A merged record older than the page's newest one does not move the content revision. The renderer drops the
/// page's files when such a merge is committed (see `NibPageRenderer.invalidate(after:)`).
final class ThumbnailCache {
    struct Key {
        let doc: DocumentID
        let page: PageID
        let rev: Rev
        let size: Int

        var pageKey: String { TileCache.pageKey(doc, page) }
        /// "<rev>_": every file of this page content, whatever its size.
        var contentPrefix: String { rev.description + "_" }
        var memoryKey: String { pageKey + "|" + contentPrefix + String(size) }
        var fileName: String { contentPrefix + String(size) + ".png" }
    }

    /// A thumbnail read back from disk, with the registry entries it was drawn with.
    struct DiskHit {
        let image: CGImage
        let looks: Set<String>
    }

    static let looksFileName = "looks.txt"

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

    /// The page's folder; nil when there is no cache folder or an id is not a plain NibID (never a path outside it).
    func folderURL(doc: DocumentID, page: PageID) -> URL? {
        guard let dir = directory, NibID.isValid(doc.raw), NibID.isValid(page.raw) else { return nil }
        return dir.appendingPathComponent(doc.raw, isDirectory: true).appendingPathComponent(page.raw, isDirectory: true)
    }

    func fileURL(_ key: Key) -> URL? {
        folderURL(doc: key.doc, page: key.page)?.appendingPathComponent(key.fileName)
    }

    func memoryImage(_ key: Key) -> CGImage? { memory.object(forKey: key.memoryKey as NSString) }

    func remember(_ image: CGImage, _ key: Key) {
        lock.lock()
        index[key.pageKey, default: []].insert(key.memoryKey)
        lock.unlock()
        memory.setObject(image, forKey: key.memoryKey as NSString, cost: image.bytesPerRow * image.height)
    }

    /// Disk read (render workers only).
    func diskImage(_ key: Key) -> DiskHit? {
        guard let url = fileURL(key), let image = PNGCodec.decode(url: url) else { return nil }
        return DiskHit(image: image, looks: ThumbnailCache.readLooks(url.deletingLastPathComponent()))
    }

    /// Disk write (the renderer's serial disk queue only); older revisions of the page are removed.
    func write(_ image: CGImage, _ key: Key, looks: Set<String>) {
        guard let url = fileURL(key), let png = PNGCodec.encode(image) else { return }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            let list = looks.sorted().joined(separator: "\n")
            try Data(list.utf8).write(to: folder.appendingPathComponent(ThumbnailCache.looksFileName), options: .atomic)
        } catch {
            return
        }
        let current = key.contentPrefix
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where !name.hasPrefix(current) && name != ThumbnailCache.looksFileName {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Deletes every disk thumbnail of a page (the serial disk queue only).
    func removeFiles(doc: DocumentID, page: PageID) {
        guard let folder = folderURL(doc: doc, page: page) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes the disk thumbnails of every page whose `looks.txt` names one of `keys` (the serial disk queue only).
    /// Runs after a template or drawer changes once the app has started: a plugin or content pack, rare.
    func removeFiles(dependingOn keys: Set<String>) {
        guard let dir = directory, !keys.isEmpty else { return }
        let fm = FileManager.default
        for doc in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            for page in (try? fm.contentsOfDirectory(at: doc, includingPropertiesForKeys: nil)) ?? []
            where !ThumbnailCache.readLooks(page).isDisjoint(with: keys) {
                try? fm.removeItem(at: page)
            }
        }
    }

    static func readLooks(_ folder: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(looksFileName)) else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
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

/// The registry entries each page's renders depend on: its background template and the drawers of its items. A
/// template or drawer registered, replaced or removed later (`RegistryChange.ids`, contracts-v2 G11) drops only the
/// pages that use it. Keys are namespaced so a template id never matches a drawer key.
final class PageLooks {
    static func template(_ id: String) -> String { "t:" + id }
    static func drawer(_ key: String) -> String { "d:" + key }

    private struct Entry {
        var generation: TileCache.Generation
        var keys: Set<String>
    }

    private let lock = NSLock()
    private var pages: [String: Entry] = [:]

    /// Adds the keys of a render of `page` made at `generation`. `keys` is evaluated only when the page changed since
    /// the last recorded render, so repeated tile requests do not rescan the page's items.
    func record(_ page: String, generation: TileCache.Generation, _ keys: () -> Set<String>) {
        lock.lock()
        let known = pages[page]
        lock.unlock()
        guard known?.generation != generation else { return }
        let fresh = keys()
        lock.lock()
        let merged = fresh.union(pages[page]?.keys ?? [])
        pages[page] = Entry(generation: generation, keys: merged)
        lock.unlock()
    }

    /// Pages known to use any of `keys`.
    func pages(using keys: Set<String>) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pages.compactMap { $0.value.keys.isDisjoint(with: keys) ? nil : $0.key }
    }

    func removeAll() {
        lock.lock()
        pages.removeAll()
        lock.unlock()
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
