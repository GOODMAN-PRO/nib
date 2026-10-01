import Foundation
import UIKit
import os
import NibContracts

// MARK: - File names

/// The per-device file names of the library folder (ARCHITECTURE §4.1–4.3) as the watcher sees them. Every device
/// writes only its own files (`doc.<dev>.json`, `pages/<p>/<dev>.nibpage`, `.nibfolder.<dev>.json`,
/// `prefs.<dev>.json`, …); anything else with a device prefix is another device's file or a provider conflict copy
/// (`doc.1a2b3c4d 2.json`), which readers merge like any other input. iCloud Drive's legacy placeholder of an evicted
/// item is `.<name>.icloud`.
enum SyncFiles {
    static let headPrefix = "doc."
    static let jsonSuffix = ".json"
    static let pageSuffix = ".nibpage"
    static let folderPrefix = ".nibfolder."
    static let prefsPrefix = "prefs."
    static let placeholderSuffix = ".icloud"
    static let pagesDirectory = "pages"
    static let trashDirectory = "trash"
    /// Package folders whose files are downloaded before a document opens but never merged by the watcher.
    static let payloadDirectories = ["assets", "audio"]
    /// iOS drops files opened from other apps into Documents/Inbox; it is not part of the library.
    static let inboxName = "Inbox"

    /// `<prefix><8 lowercase hex>…<suffix>`: the device hex and whether it is the exact device file (false = a
    /// provider conflict copy). nil when the name is not such a file.
    static func device(of name: String, prefix: String, suffix: String) -> (hex: String, exact: Bool)? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count >= prefix.count + suffix.count + 8 else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(suffix.count)
        let hex = body.prefix(8)
        guard hex.count == 8, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return (String(hex), body.count == 8)
    }

    /// A document head: `doc.<8hex>.json` or a conflict copy of one.
    static func isHead(_ name: String) -> Bool { device(of: name, prefix: headPrefix, suffix: jsonSuffix) != nil }
    /// A page's item file: `<8hex>.nibpage` or a conflict copy of one.
    static func isPage(_ name: String) -> Bool { device(of: name, prefix: "", suffix: pageSuffix) != nil }
    /// A folder's style record: `.nibfolder.<8hex>.json` or a conflict copy of one.
    static func isFolderRecord(_ name: String) -> Bool { device(of: name, prefix: folderPrefix, suffix: jsonSuffix) != nil }
    /// The library's synced settings of one device: `prefs.<8hex>.json` or a conflict copy of one.
    static func isPrefs(_ name: String) -> Bool { device(of: name, prefix: prefsPrefix, suffix: jsonSuffix) != nil }

    /// A file only this device writes (its head, page files, folder records, prefs and every other per-device store
    /// file `<name>.<dev>.json` / `.jsonl`). Changes to them never come from another device, so the watcher ignores them:
    /// that is what keeps this device's own writes from feeding back into a merge.
    static func isOwn(_ name: String, device: String) -> Bool {
        name == device + pageSuffix || name.hasSuffix("." + device + jsonSuffix) || name.hasSuffix("." + device + ".jsonl")
    }

    /// The real name behind an iCloud placeholder `.<name>.icloud`; nil for any other name.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(placeholderSuffix), name.count > 1 + placeholderSuffix.count else { return nil }
        return String(name.dropFirst().dropLast(placeholderSuffix.count))
    }

    /// The placeholder URL iCloud shows for an evicted `url`.
    static func placeholder(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + placeholderSuffix)
    }

    static func isPackageExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return e == NibFormat.packageExtension || e == NibFormat.legacyPackageExtension
    }

    static func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }
}

// MARK: - Scan values

/// What identifies a version of a file for change detection.
struct FileStamp: Equatable, Codable {
    var modified: Double?
    var size: Int?

    init(modified: Double? = nil, size: Int? = nil) {
        self.modified = modified
        self.size = size
    }

    init(_ values: URLResourceValues?) {
        modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate
        size = values?.fileSize
    }
}

/// The iCloud download state of one item, from its resource values.
enum DownloadState: Equatable {
    /// Not an iCloud item, or its latest version is local.
    case local
    /// A local copy exists but a newer version is in iCloud: readable, and downloaded in the background.
    case outdated
    /// Evicted (dataless or a placeholder): reading it would block until it arrives.
    case evicted

    init(_ values: URLResourceValues?) {
        guard let v = values, v.isUbiquitousItem == true, let status = v.ubiquitousItemDownloadingStatus else {
            self = .local
            return
        }
        switch status {
        case .notDownloaded: self = .evicted
        case .downloaded: self = .outdated
        default: self = .local
        }
    }
}

/// One loaded document's package as the watcher last saw it.
struct PackageScan: Equatable {
    /// Other devices' heads and page files (conflict copies included) that are on this device, by package-relative path.
    var files: [String: FileStamp] = [:]
    /// Heads and page files (this device's too) that are evicted: merging waits until they are downloaded.
    var evicted: [String] = []
    /// Assets and audio that are evicted (downloaded in the background; nothing waits for them).
    var evictedPayload: [String] = []
    /// False when the package is gone (moved, renamed, deleted): the library is rescanned.
    var exists = true
}

/// A package folder of the library tree, cached by its directory stamp between scans (an atomic write of any head in
/// it replaces a directory entry, which moves the stamp).
struct PackageListing: Equatable {
    var directory: FileStamp
    /// Other devices' heads (conflict copies included) that are on this device, by name.
    var heads: [String: FileStamp] = [:]
    /// Evicted heads (this device's too), by real name.
    var evicted: [String] = []
    var hasHead = false
}

/// The library folder's structure as the watcher last saw it.
struct LibraryScan: Equatable {
    /// Package prefixes excluded from metadata while their documents are loaded.
    var loaded: Set<String> = []
    /// Library-relative paths of the live folders and packages (as the library catalog lists them).
    var tree: Set<String> = []
    /// Library-relative paths of everything in the Trash.
    var trash: Set<String> = []
    /// The items directly in the Trash (what `LibraryService.trashedNodes` lists).
    var trashTop: Set<String> = []
    /// Other devices' metadata the catalog reads: heads of packages that are not loaded here, folder records, prefs.
    var meta: [String: FileStamp] = [:]
    /// Evicted packages, heads, folder records and prefs (library-relative paths of the real items).
    var evicted: [String] = []
}

// MARK: - Scanner

/// Reads the library folder off the main actor: it never touches `NibApp`, the workspace or any other main-actor type.
/// Every file that is evicted or outdated in iCloud is asked to download (`startDownloadingUbiquitousItem`).
struct FolderScanner {
    /// This device's 8 lowercase hex characters.
    let device: String
    /// Ask iCloud to download evicted and outdated items while scanning.
    var startsDownloads = true

    static let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
                                         .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    private static let keySet = Set(keys)

    struct Request {
        var docs: [DocumentID: URL] = [:]
        var root: URL?
        var skipInbox = false
        /// Library-relative paths of loaded packages: their heads are merged through `remoteChanges`, not the catalog.
        var loadedPackages: Set<String> = []
        var cache: [String: PackageListing] = [:]
        /// false = list every package again (foreground, Sync Now, every tenth poll) instead of trusting the cache.
        var useCache = true
    }

    struct Result {
        var docs: [DocumentID: PackageScan] = [:]
        var library: LibraryScan?
        var cache: [String: PackageListing] = [:]
    }

    func run(_ request: Request) -> Result {
        var out = Result()
        for (doc, url) in request.docs { out.docs[doc] = scanPackage(url) }
        if let root = request.root {
            let (scan, cache) = scanLibrary(root: root, skipInbox: request.skipInbox, loaded: request.loadedPackages,
                                            cache: request.cache, useCache: request.useCache)
            out.library = scan
            out.cache = cache
        }
        return out
    }

    // MARK: Packages

    /// A loaded document's heads and page files (other devices' stamps; evicted files of any device).
    func scanPackage(_ url: URL) -> PackageScan {
        var scan = PackageScan()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            scan.exists = false
            if FileManager.default.fileExists(atPath: SyncFiles.placeholder(of: url).path) {
                // The whole package was evicted: it comes back as a package once downloaded.
                scan.exists = true
                scan.evicted.append(".")
                download(url)
            }
            return scan
        }
        for entry in list(url) {
            let name = entry.url.lastPathComponent
            if let real = SyncFiles.placeholderTarget(name) {
                if SyncFiles.isHead(real) {
                    scan.evicted.append(real)
                    download(url.appendingPathComponent(real))
                }
                continue
            }
            guard SyncFiles.isHead(name) else { continue }
            record(entry, path: name, into: &scan)
        }
        let pages = url.appendingPathComponent(SyncFiles.pagesDirectory, isDirectory: true)
        for pageDir in list(pages) where pageDir.values?.isDirectory == true {
            let dir = SyncFiles.pagesDirectory + "/" + pageDir.url.lastPathComponent
            for entry in list(pageDir.url) {
                let name = entry.url.lastPathComponent
                if let real = SyncFiles.placeholderTarget(name) {
                    if SyncFiles.isPage(real) {
                        scan.evicted.append(dir + "/" + real)
                        download(pageDir.url.appendingPathComponent(real))
                    }
                    continue
                }
                guard SyncFiles.isPage(name) else { continue }
                record(entry, path: dir + "/" + name, into: &scan)
            }
        }
        for payload in SyncFiles.payloadDirectories {
            scan.evictedPayload += evictedItems(below: url.appendingPathComponent(payload, isDirectory: true),
                                                relative: payload)
        }
        scan.evicted.sort()
        return scan
    }

    private func record(_ entry: Entry, path: String, into scan: inout PackageScan) {
        let name = entry.url.lastPathComponent
        switch DownloadState(entry.values) {
        case .evicted:
            scan.evicted.append(path)
            download(entry.url)
            return
        case .outdated:
            download(entry.url)
        case .local:
            break
        }
        if !SyncFiles.isOwn(name, device: device) { scan.files[path] = FileStamp(entry.values) }
    }

    /// Every evicted item of a package (heads, pages, assets, audio; "." = the whole package), asking each to
    /// download. Empty once the package is fully on this device.
    func evictedItems(inPackage url: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if FileManager.default.fileExists(atPath: SyncFiles.placeholder(of: url).path) {
                download(url)
                return ["."]
            }
            return []
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard values?.isUbiquitousItem == true else { return [] }
        return evictedItems(below: url, relative: "")
    }

    /// Evicted files and placeholders below `dir` (recursively), as paths relative to the package.
    private func evictedItems(below dir: URL, relative: String) -> [String] {
        var out: [String] = []
        for entry in list(dir) {
            let name = entry.url.lastPathComponent
            if let real = SyncFiles.placeholderTarget(name) {
                out.append(SyncFiles.join(relative, real))
                download(dir.appendingPathComponent(real))
                continue
            }
            if entry.values?.isDirectory == true {
                out += evictedItems(below: entry.url, relative: SyncFiles.join(relative, name))
                continue
            }
            switch DownloadState(entry.values) {
            case .evicted:
                out.append(SyncFiles.join(relative, name))
                download(entry.url)
            case .outdated:
                download(entry.url)
            case .local:
                break
            }
        }
        return out
    }

    // MARK: Library

    /// The library tree, the Trash and the metadata the catalog reads. Packages whose directory stamp did not move
    /// reuse their cached listing when `useCache` is set.
    func scanLibrary(root: URL, skipInbox: Bool, loaded: Set<String>, cache: [String: PackageListing],
                     useCache: Bool) -> (LibraryScan, [String: PackageListing]) {
        var scan = LibraryScan()
        scan.loaded = loaded
        var newCache: [String: PackageListing] = [:]
        var walker = Walker(scanner: self, loaded: loaded, cache: cache, useCache: useCache)
        walker.walk(root, relative: "", inTrash: false, trashTop: false, isRoot: true, skipInbox: skipInbox,
                    scan: &scan, cache: &newCache)
        let metadata = root.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        for entry in list(metadata) {
            let name = entry.url.lastPathComponent
            let path = NibFormat.libraryDirectory + "/" + name
            if let real = SyncFiles.placeholderTarget(name) {
                if SyncFiles.isPrefs(real) {
                    scan.evicted.append(NibFormat.libraryDirectory + "/" + real)
                    download(metadata.appendingPathComponent(real))
                }
                continue
            }
            guard SyncFiles.isPrefs(name) else { continue }
            switch DownloadState(entry.values) {
            case .evicted:
                scan.evicted.append(path)
                download(entry.url)
                continue
            case .outdated:
                download(entry.url)
            case .local:
                break
            }
            if !SyncFiles.isOwn(name, device: device) { scan.meta[path] = FileStamp(entry.values) }
        }
        let trash = metadata.appendingPathComponent(SyncFiles.trashDirectory, isDirectory: true)
        walker.walk(trash, relative: NibFormat.libraryDirectory + "/" + SyncFiles.trashDirectory, inTrash: true,
                    trashTop: true, isRoot: false, skipInbox: false, scan: &scan, cache: &newCache)
        scan.evicted.sort()
        return (scan, newCache)
    }

    /// Lists a package folder: other devices' heads and evicted heads.
    func listPackage(_ url: URL, directory: FileStamp) -> PackageListing {
        var listing = PackageListing(directory: directory)
        for entry in list(url) {
            let name = entry.url.lastPathComponent
            if let real = SyncFiles.placeholderTarget(name) {
                if SyncFiles.isHead(real) {
                    listing.hasHead = true
                    listing.evicted.append(real)
                    download(url.appendingPathComponent(real))
                }
                continue
            }
            guard SyncFiles.isHead(name) else { continue }
            listing.hasHead = true
            switch DownloadState(entry.values) {
            case .evicted:
                listing.evicted.append(name)
                download(entry.url)
                continue
            case .outdated:
                download(entry.url)
            case .local:
                break
            }
            if !SyncFiles.isOwn(name, device: device) { listing.heads[name] = FileStamp(entry.values) }
        }
        listing.evicted.sort()
        return listing
    }

    /// Walks folders and packages; kept separate so the cache and the loaded set travel with it.
    private struct Walker {
        let scanner: FolderScanner
        let loaded: Set<String>
        let cache: [String: PackageListing]
        let useCache: Bool

        mutating func walk(_ dir: URL, relative: String, inTrash: Bool, trashTop: Bool, isRoot: Bool, skipInbox: Bool,
                           scan: inout LibraryScan, cache out: inout [String: PackageListing]) {
            for entry in scanner.list(dir) {
                let name = entry.url.lastPathComponent
                let path = SyncFiles.join(relative, name)
                if name.hasPrefix(".") {
                    if let real = SyncFiles.placeholderTarget(name) {
                        let realPath = SyncFiles.join(relative, real)
                        if (real as NSString).pathExtension.lowercased() == NibFormat.packageExtension {
                            // An evicted package: listed by the catalog at its real path, and downloaded.
                            insert(realPath, inTrash: inTrash, trashTop: trashTop, scan: &scan)
                            scan.evicted.append(realPath)
                            scanner.download(dir.appendingPathComponent(real))
                        } else if SyncFiles.isFolderRecord(real) {
                            scan.evicted.append(realPath)
                            scanner.download(dir.appendingPathComponent(real))
                        }
                    } else if SyncFiles.isFolderRecord(name) {
                        switch DownloadState(entry.values) {
                        case .evicted:
                            scan.evicted.append(path)
                            scanner.download(entry.url)
                            continue
                        case .outdated:
                            scanner.download(entry.url)
                        case .local:
                            break
                        }
                        if !SyncFiles.isOwn(name, device: scanner.device) { scan.meta[path] = FileStamp(entry.values) }
                    }
                    continue
                }
                guard entry.values?.isDirectory == true else { continue }
                if isRoot && skipInbox && name == SyncFiles.inboxName { continue }
                let ext = entry.url.pathExtension.lowercased()
                if SyncFiles.isPackageExtension(ext) {
                    let stamp = FileStamp(entry.values)
                    let listing: PackageListing
                    if useCache, stamp.modified != nil, let cached = cache[path], cached.directory == stamp {
                        listing = cached
                    } else {
                        listing = scanner.listPackage(entry.url, directory: stamp)
                    }
                    // A legacy `*.nib` folder without a head is an ordinary folder (ARCHITECTURE §4.2).
                    if ext == NibFormat.packageExtension || listing.hasHead {
                        out[path] = listing
                        insert(path, inTrash: inTrash, trashTop: trashTop, scan: &scan)
                        if !loaded.contains(path) {
                            for (head, stamp) in listing.heads { scan.meta[path + "/" + head] = stamp }
                        }
                        scan.evicted += listing.evicted.map { path + "/" + $0 }
                        continue
                    }
                }
                insert(path, inTrash: inTrash, trashTop: trashTop, scan: &scan)
                walk(entry.url, relative: path, inTrash: inTrash, trashTop: false, isRoot: false, skipInbox: false,
                     scan: &scan, cache: &out)
            }
        }

        private func insert(_ path: String, inTrash: Bool, trashTop: Bool, scan: inout LibraryScan) {
            if inTrash {
                scan.trash.insert(path)
                if trashTop { scan.trashTop.insert(path) }
            } else {
                scan.tree.insert(path)
            }
        }
    }

    // MARK: Helpers

    struct Entry {
        let url: URL
        let values: URLResourceValues?
    }

    /// Directory entries with their resource values prefetched (one bulk read per directory).
    func list(_ dir: URL) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: FolderScanner.keys,
                                                                 options: [])) ?? []
        return urls.map { Entry(url: $0, values: try? $0.resourceValues(forKeys: FolderScanner.keySet)) }
    }

    func download(_ url: URL) {
        guard startsDownloads else { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Not an iCloud item (a local folder or another provider, which downloads on first read): nothing to do.
        }
    }
}

// MARK: - Change detection

enum SyncDiff {
    /// Keys added, removed or whose stamp changed, sorted.
    static func changed(_ old: [String: FileStamp], _ new: [String: FileStamp]) -> [String] {
        var out = Set<String>()
        for (k, v) in new where old[k] != v { out.insert(k) }
        for k in old.keys where new[k] == nil { out.insert(k) }
        return out.sorted()
    }

    /// Whether the library needs a catalog rescan: another device's metadata changed, or the structure moved in a way
    /// the catalog does not already show (this device's own library commands update the catalog themselves).
    static func needsRefresh(old: LibraryScan?, new: LibraryScan, catalogTree: () -> Set<String>?,
                             catalogTrash: () -> Set<String>?) -> Bool {
        guard let old = old else { return false }
        let loaded = old.loaded.union(new.loaded)
        func unloaded(_ meta: [String: FileStamp]) -> [String: FileStamp] {
            meta.filter { key, _ in !loaded.contains { key.hasPrefix($0 + "/") } }
        }
        if unloaded(old.meta) != unloaded(new.meta) { return true }
        if old.tree != new.tree, let catalog = catalogTree(), catalog != new.tree { return true }
        if old.trash != new.trash, let catalog = catalogTrash(), catalog != new.trashTop { return true }
        return false
    }
}

/// Records of a remote patch stamped more than 24 h in the future (a device with a wrong clock), and the files they
/// came from: the changed files of the devices that stamped them.
enum FutureRevisions {
    static let skewMs: UInt64 = 86_400_000

    static func devices(in patch: DocumentPatch, now: UInt64) -> Set<String> {
        var revs: [Rev] = []
        if let m = patch.meta { revs.append(m.rev) }
        revs += patch.pages.map { $0.rev }
        revs += patch.outline.map { $0.rev }
        revs += patch.blocks.map { $0.rev }
        revs += patch.cards.map { $0.rev }
        revs += patch.audio.map { $0.rev }
        for items in patch.items.values { revs += items.map { $0.rev } }
        return Set(revs.filter { $0.wallMs > now &+ skewMs }.map { String(format: "%08x", $0.device) })
    }

    /// The package-relative files among `changed` written by `devices` (their exact files and conflict copies); when
    /// none matches, one "device <hex>" entry per device.
    static func files(of devices: Set<String>, among changed: [String]) -> [String] {
        guard !devices.isEmpty else { return [] }
        var out: [String] = []
        for path in changed {
            let name = (path as NSString).lastPathComponent
            let hex = SyncFiles.device(of: name, prefix: SyncFiles.headPrefix, suffix: SyncFiles.jsonSuffix)?.hex
                ?? SyncFiles.device(of: name, prefix: "", suffix: SyncFiles.pageSuffix)?.hex
            if let h = hex, devices.contains(h) { out.append(path) }
        }
        return out.isEmpty ? devices.sorted().map { "device " + $0 } : out.sorted()
    }
}

// MARK: - File presenters

/// An `NSFilePresenter` on the library root or an open package. Its `presentedItemOperationQueue` is a background
/// queue, never the main queue: the Document Store flushes with a coordinated write from the main actor, and a
/// presenter on the main queue would deadlock it (contracts-v2 changelog). It only forwards what happened; the watcher
/// decides on the main actor.
final class FolderPresenter: NSObject, NSFilePresenter {
    enum Change {
        /// A file or folder inside was written, created, moved or deleted.
        case subitem(URL)
        /// The presented folder itself moved or went away.
        case moved(URL)
        case deleted
    }

    private let lock = NSLock()
    private var url: URL
    private let queue: OperationQueue
    private let handler: (FolderPresenter, Change) -> Void
    /// The document of an open package; nil for the library root.
    let doc: DocumentID?

    init(url: URL, doc: DocumentID?, handler: @escaping (FolderPresenter, Change) -> Void) {
        self.url = url
        self.doc = doc
        self.handler = handler
        queue = OperationQueue()
        queue.name = "app.nib.sync.presenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        super.init()
    }

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    var presentedItemOperationQueue: OperationQueue { queue }

    func presentedSubitemDidChange(at url: URL) { handler(self, .subitem(url)) }

    func presentedSubitemDidAppear(at url: URL) { handler(self, .subitem(url)) }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        handler(self, .subitem(oldURL))
        handler(self, .subitem(newURL))
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        handler(self, .subitem(url))
        completionHandler(nil)
    }

    func presentedItemDidChange() {}

    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        url = newURL
        lock.unlock()
        handler(self, .moved(newURL))
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        handler(self, .deleted)
        completionHandler(nil)
    }

    func start() { NSFileCoordinator.addFilePresenter(self) }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }
}

// MARK: - The sync engine

/// The result of one check (`sync.now` returns it).
struct SyncReport: Codable, Equatable {
    /// Loaded documents whose package was checked.
    var checked = 0
    /// Documents that received records from other devices ("doc:<id>").
    var changed: [String] = []
    /// Records merged into loaded documents.
    var merged = 0
    /// The library catalog was rescanned (folders or documents added, moved or changed elsewhere).
    var refreshed = false
    /// Documents ("doc:<id>") and library items waiting for iCloud to download them.
    var downloading: [String] = []
    /// Files carrying revisions more than 24 h in the future ("doc:<id>/<file>").
    var futureRevisions: [String] = []
    var errors: [SyncIssue] = []
}

struct SyncIssue: Codable, Equatable {
    /// "doc:<id>", or nil for the library.
    var doc: String?
    var code: String
    var message: String
}

/// F025's folder sync engine. Keeps loaded documents in step with files other devices write into the library folder:
/// `NSFilePresenter`s on the library root and on every open package, a 30 s poll while the app is in the foreground, and
/// a check on every return to the foreground, all comparing the stamps of OTHER devices' `doc.*.json` / `*.nibpage`
/// files. A changed loaded document is merged with `persistence.remoteChanges(doc)` + `bus.applyRemote(patch, origin:
/// "folder")`; a structural change (documents or folders added, moved or restyled elsewhere, another device's prefs) runs
/// `library.refresh()`. This device's own files are never compared, so its own writes cannot feed back into a merge.
/// Emits `sync.status` (`SyncStatusPayload`, source "sync") per document on every state change: checking, idle,
/// downloading, warning (futureRevision) and error.
@MainActor
final class FolderWatcher {
    static let serviceKey = "sync.watcher"
    static let source = "sync"
    static let origin = "folder"

    private weak var app: NibApp?
    let device: String
    private let log = Logger(subsystem: "app.nib", category: "sync")

    /// Seconds between polls while the app is in the foreground.
    var pollInterval: TimeInterval = 30
    /// Seconds between polls while iCloud downloads files an open document needs.
    var downloadPollInterval: TimeInterval = 3
    /// Seconds to wait for an evicted package before refusing the open.
    var downloadTimeout: TimeInterval = 30
    /// Presenter events are coalesced for this long before a check.
    var presenterDelay: TimeInterval = 0.4

    private(set) var isStarted = false
    /// Other devices' file stamps of each loaded document as last merged.
    private var baselines: [DocumentID: [String: FileStamp]] = [:]
    private var libraryBaseline: LibraryScan?
    private var rootGeneration: UInt64 = 0
    /// Hostless tests can hold a scan across a root change and simulate evicted items.
    var testAfterScan: (() async -> Void)?
    var testEvictedItems: (@Sendable (URL) -> [String])?
    private var packageCache: [String: PackageListing] = [:]
    /// Last `sync.status` sent per document ("" = the library).
    private var statuses: [String: SyncStatusPayload] = [:]
    /// Files with far-future revisions per document (the store's reports and this engine's), for `sync.now`.
    private var futureFiles: [DocumentID: Set<String>] = [:]
    private var rootPresenter: FolderPresenter?
    private var packagePresenters: [DocumentID: FolderPresenter] = [:]
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var pendingSince: Date?
    private var pendingFull = false
    private var running: Task<SyncReport, Never>?
    private var polls = 0
    private var downloadsPending = false
    private var rootRecoveryInFlight = false
    /// Checks run so far (tests and diagnostics).
    private(set) var checks = 0
    private(set) var lastReport: SyncReport?

    init(app: NibApp) {
        self.app = app
        device = app.deviceHex
    }

    // MARK: Lifecycle

    /// Starts the presenters, the poll and the foreground check. Idempotent.
    func start(poll: Bool = true) {
        guard !isStarted, let app = app else { return }
        isStarted = true
        subscriptions.append(app.events.subscribe { [weak self] e in
            FolderWatcher.onMain { self?.handle(e) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(after: 0, full: true) }
        })
        attachRoot()
        for doc in app.workspace.loadedDocuments { attach(doc) }
        if poll { startPolling() }
        scheduleCheck(after: presenterDelay, full: true)
    }

    /// Stops presenters, the poll and pending checks (tests; the app keeps the watcher for its lifetime).
    func stop() {
        isStarted = false
        pollTask?.cancel()
        pollTask = nil
        pendingTask?.cancel()
        pendingTask = nil
        for s in subscriptions { s.cancel() }
        subscriptions = []
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        rootPresenter?.stop()
        rootPresenter = nil
        for p in packagePresenters.values { p.stop() }
        packagePresenters = [:]
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = self.map { $0.downloadsPending ? $0.downloadPollInterval : $0.pollInterval } ?? 30
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, delay) * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { return }
                guard self.isForeground else { continue }
                self.polls += 1
                // Every tenth poll lists every package again, for providers that do not move directory stamps.
                _ = await self.check(full: self.polls % 10 == 0)
            }
        }
    }

    private var isForeground: Bool {
        if NibApp.isHostlessTest { return true }
        return UIApplication.shared.applicationState != .background
    }

    /// Runs `body` on the main actor: at once when already there (events are emitted on main), else on the next turn.
    nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    private func handle(_ e: NibEvent) {
        switch e.type {
        case NibEventType.docOpened:
            if let doc = e.doc {
                attach(doc)
                scheduleCheck(after: presenterDelay)
            }
        case NibEventType.docClosed:
            if let doc = e.doc { detach(doc) }
        case NibEventType.libraryChanged:
            if e.payload?["root"]?.boolValue == true { rootChanged() }
        case NibEventType.syncStatus:
            // The store reports files with far-future revisions as it reads them; `sync.now` lists them too.
            if let doc = e.doc, let p = e.decode(SyncStatusPayload.self), p.source == "store", p.reason == "futureRevision" {
                futureFiles[doc, default: []].formUnion(p.files ?? [])
            }
        default:
            break
        }
    }

    // MARK: Presenters

    private func attachRoot() {
        rootPresenter?.stop()
        rootPresenter = nil
        guard let root = app?.services.library?.rootURL else { return }
        let presenter = FolderPresenter(url: root, doc: nil) { [weak self] p, change in
            FolderWatcher.onMain { self?.presenterChanged(p, change) }
        }
        presenter.start()
        rootPresenter = presenter
    }

    private func attach(_ doc: DocumentID) {
        guard packagePresenters[doc] == nil, let url = app?.services.packages.url(doc) else { return }
        let presenter = FolderPresenter(url: url, doc: doc) { [weak self] p, change in
            FolderWatcher.onMain { self?.presenterChanged(p, change) }
        }
        presenter.start()
        packagePresenters[doc] = presenter
    }

    private func detach(_ doc: DocumentID) {
        packagePresenters.removeValue(forKey: doc)?.stop()
        baselines[doc] = nil
        statuses[doc.raw] = nil
        futureFiles[doc] = nil
    }

    /// The library moved to another folder: everything known about the old one is dropped.
    func rootChanged() {
        rootGeneration &+= 1
        libraryBaseline = nil
        packageCache = [:]
        // A library-level problem (unavailable or moved folder, a failed move) belonged to the folder left behind.
        if let status = statuses[""], status.state != "idle" { setStatus(nil, state: "idle") }
        statuses[""] = nil
        if isStarted {
            attachRoot()
            scheduleCheck(after: presenterDelay, full: true)
        }
    }

    /// Decides whether a presenter event can come from another device, and checks soon when it can.
    func presenterChanged(_ presenter: FolderPresenter, _ change: FolderPresenter.Change) {
        switch change {
        case .moved, .deleted:
            // A package or the library folder moved or went away: the next check rescans the library (and reopens a
            // moved library folder from its bookmark).
            scheduleCheck(after: presenterDelay, full: true)
        case .subitem(let url):
            guard FolderWatcher.isRelevant(url, device: device) else { return }
            if presenter.doc == nil {
                if packagePresenters.values.contains(where: { $0.presentedItemURL.map { FolderWatcher.isWithin(url, $0) } ?? false }) {
                    return  // the package's own presenter reports it
                }
                if let root = presenter.presentedItemURL, !FolderWatcher.isCatalogued(url, root: root) { return }
            }
            scheduleCheck(after: presenterDelay)
        }
    }

    /// Whether a changed item may carry another device's change (this device's own files and temporary files never do).
    nonisolated static func isRelevant(_ url: URL, device: String) -> Bool {
        let name = url.lastPathComponent
        if SyncFiles.isOwn(name, device: device) { return false }
        if name.hasPrefix(".") {
            return SyncFiles.placeholderTarget(name) != nil || SyncFiles.isFolderRecord(name)
        }
        return true
    }

    /// Whether an item under the library root is something the catalog lists: anything outside `.nib-library`, and in
    /// it only the Trash and the synced prefs (plugins, elements, templates, chats and plugin data belong to the
    /// features that read them on demand).
    nonisolated static func isCatalogued(_ url: URL, root: URL) -> Bool {
        let metadata = root.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        guard isWithin(url, metadata) else { return true }
        if isWithin(url, metadata.appendingPathComponent(SyncFiles.trashDirectory, isDirectory: true)) { return true }
        let name = SyncFiles.placeholderTarget(url.lastPathComponent) ?? url.lastPathComponent
        return url.deletingLastPathComponent().standardizedFileURL.path == metadata.standardizedFileURL.path
            && SyncFiles.isPrefs(name)
    }

    nonisolated static func isWithin(_ url: URL, _ dir: URL) -> Bool {
        let p = url.standardizedFileURL.path, d = dir.standardizedFileURL.path
        return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    // MARK: Checks

    /// Coalesces requests: presenter bursts are merged, but never delayed for more than 3 s in total.
    func scheduleCheck(after delay: TimeInterval, full: Bool = false) {
        pendingFull = pendingFull || full
        if pendingTask != nil, let since = pendingSince, Date().timeIntervalSince(since) > 3 { return }
        pendingTask?.cancel()
        if pendingSince == nil { pendingSince = Date() }
        pendingTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self = self, !Task.isCancelled else { return }
            self.pendingTask = nil
            self.pendingSince = nil
            let full = self.pendingFull
            self.pendingFull = false
            _ = await self.check(full: full)
        }
    }

    /// Checks the library now (after any check that is running). `full` lists every package again instead of trusting
    /// the directory stamps; `reconcile` (Sync Now) also rescans the catalog whenever the folder's structure differs from
    /// what the catalog lists.
    @discardableResult
    func check(full: Bool = false, reconcile: Bool = false) async -> SyncReport {
        let previous = running
        let task = Task { @MainActor [weak self] () -> SyncReport in
            _ = await previous?.value
            guard let self = self else { return SyncReport() }
            return await self.runCheck(full: full || reconcile, reconcile: reconcile)
        }
        running = task
        let report = await task.value
        if running == task { running = nil }
        return report
    }

    private func runCheck(full: Bool, reconcile: Bool) async -> SyncReport {
        guard let app = app else { return SyncReport() }
        guard app.services.get(RelocationGate.serviceKey, as: RelocationGate.self)?.relocating != true else { return SyncReport() }
        checks += 1
        var report = SyncReport()
        let workspace = app.workspace
        let library = app.services.library
        let root = library?.rootURL.standardizedFileURL
        let generation = rootGeneration

        var request = FolderScanner.Request()
        for doc in workspace.loadedDocuments {
            if let url = app.services.packages.url(doc) { request.docs[doc] = url.standardizedFileURL }
        }
        let rootMissing = root.map { !LibraryFolder.isDirectory($0) } ?? false
        if let root = root, !rootMissing {
            request.root = root
            request.skipInbox = LibraryFolder.isAppDocuments(root)
            request.loadedPackages = Set(request.docs.values.compactMap { FolderWatcher.relativePath($0, root: root) })
        }
        request.cache = packageCache
        request.useCache = !full
        let scanner = FolderScanner(device: device)
        let result = await Task.detached(priority: .utility) { scanner.run(request) }.value
        if NibApp.isHostlessTest { await testAfterScan?() }
        // No old-root result (documents, cache or status) may be applied after switching libraries.
        guard rootGeneration == generation, library?.rootURL.standardizedFileURL == root,
              app.services.get(RelocationGate.serviceKey, as: RelocationGate.self)?.relocating != true else { return report }

        // Loaded documents: merge what other devices wrote.
        var packageMissing = false
        var waiting = false
        for doc in request.docs.keys.sorted() {
            guard workspace.isLoaded(doc), let scan = result.docs[doc] else { continue }
            report.checked += 1
            let ref = NodeRef.document(doc).description
            if !scan.exists {
                packageMissing = true
                continue
            }
            if !scan.evicted.isEmpty {
                // Reading an evicted file would block until it arrives: merge once iCloud has downloaded it.
                waiting = true
                report.downloading.append(ref)
                setStatus(doc, state: "downloading", reason: "evicted",
                          message: String(localized: "Downloading changes from iCloud…"), files: scan.evicted)
                continue
            }
            let old = baselines[doc]
            let changed = old.map { SyncDiff.changed($0, scan.files) } ?? scan.files.keys.sorted()
            if changed.isEmpty {
                baselines[doc] = scan.files
                if statuses[doc.raw]?.state == "downloading" { setStatus(doc, state: "idle") }
                continue
            }
            // A document seen for the first time is only compared with what the store read when it opened it.
            if old != nil { setStatus(doc, state: "checking", reason: "remoteChanges", files: changed) }
            do {
                var warning: [String] = []
                if let patch = try workspace.persistence.remoteChanges(doc) {
                    let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
                    warning = FutureRevisions.files(of: FutureRevisions.devices(in: patch, now: now), among: changed)
                    let summary = app.bus.applyRemote(patch, origin: FolderWatcher.origin)
                    if !summary.isEmpty {
                        report.changed.append(ref)
                        report.merged += summary.count
                    }
                }
                baselines[doc] = scan.files
                if warning.isEmpty {
                    setStatus(doc, state: "idle")
                } else {
                    futureFiles[doc, default: []].formUnion(warning)
                    setStatus(doc, state: "warning", reason: "futureRevision",
                              message: String(localized: "A device's clock is more than 24 hours ahead, so its changes lose to newer edits until its clock is corrected."),
                              files: warning)
                }
            } catch {
                let e = NibError.wrap(error)
                log.error("merging \(doc.raw, privacy: .public) failed: \(e.message, privacy: .public)")
                report.errors.append(SyncIssue(doc: ref, code: e.code.rawValue, message: e.message))
                setStatus(doc, state: "error", reason: "readFailed",
                          message: String(localized: "Changes from other devices could not be read: \(e.message)"))
            }
        }
        for (doc, files) in futureFiles where workspace.isLoaded(doc) {
            report.futureRevisions += files.sorted().map { NodeRef.document(doc).description + "/" + $0 }
        }

        // The library: structure and other devices' metadata.
        if let scan = result.library {
            packageCache = result.cache
            let catalogTree = { library.map { Set($0.allNodes().map { $0.path }) } }
            let catalogTrash = { library.map { Set($0.trashedNodes().map { $0.path }) } }
            // Reconcile the first scan too: a remote addition may have missed the library's launch scan.
            var refresh = packageMissing || SyncDiff.needsRefresh(old: libraryBaseline, new: scan, catalogTree: catalogTree,
                                                                   catalogTrash: catalogTrash)
            if (reconcile || libraryBaseline == nil) && !refresh {
                refresh = (catalogTree().map { $0 != scan.tree } ?? false) || (catalogTrash().map { $0 != scan.trashTop } ?? false)
            }
            libraryBaseline = scan
            if refresh, let library = library {
                library.refresh()
                report.refreshed = true
                // Packages may have moved: point their presenters at the new places.
                for (doc, presenter) in packagePresenters {
                    if let url = app.services.packages.url(doc), presenter.presentedItemURL?.standardizedFileURL != url.standardizedFileURL {
                        detachPresenterOnly(doc)
                        attach(doc)
                    }
                }
            }
            if scan.evicted.isEmpty {
                if statuses[""]?.state == "downloading" { setStatus(nil, state: "idle") }
            } else {
                report.downloading += scan.evicted.map { "lib:" + $0 }
                setStatus(nil, state: "downloading", reason: "evicted",
                          message: String(localized: "Downloading library items from iCloud…"), files: scan.evicted)
            }
        } else if rootMissing, let root = root {
            // The library folder moved (renamed in Files) or went away: never rescan it as an empty library.
            report.errors.append(SyncIssue(doc: nil, code: NibError.Code.notFound.rawValue,
                                           message: "the library folder \(root.lastPathComponent) is not reachable"))
            setStatus(nil, state: "error", reason: "libraryMoved",
                      message: String(localized: "The library folder moved or can't be reached. Nib reopens it where it is now, or choose it again."))
            reopenMovedRoot(root)
        } else if packageMissing, let library = library {
            library.refresh()
            report.refreshed = true
        }
        downloadsPending = waiting
        lastReport = report
        return report
    }

    /// Follows a library folder that moved while Nib ran: its remembered bookmark finds the new place and
    /// `library.switch` opens it there. Without a remembered folder nothing happens (the next launch resolves the
    /// library's own bookmark, or asks).
    private func reopenMovedRoot(_ root: URL) {
        guard !rootRecoveryInFlight, let app = app,
              let entry = KnownLocations.all(app.settings).first(where: { KnownLocations.matches($0, root) }) else { return }
        rootRecoveryInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.rootRecoveryInFlight = false }
            do {
                try await app.bus.execute(CommandIDs.librarySwitch, ["location": .string(entry.id)])
            } catch {
                self?.log.error("could not reopen the moved library folder: \(NibError.wrap(error).message, privacy: .public)")
            }
        }
    }

    private func detachPresenterOnly(_ doc: DocumentID) {
        packagePresenters.removeValue(forKey: doc)?.stop()
    }

    /// Before a document opens: asks iCloud for every evicted item of its package and waits (up to `downloadTimeout`)
    /// until all of them are on this device, reporting `downloading` meanwhile. Returns true when nothing is missing.
    @discardableResult
    func ensureDownloaded(_ doc: DocumentID) async -> Bool {
        guard let app = app, !app.workspace.isLoaded(doc), let url = app.services.packages.url(doc) else { return true }
        let scanner = FolderScanner(device: device)
        let probe = NibApp.isHostlessTest ? testEvictedItems : nil
        var missing = await Task.detached(priority: .userInitiated) { probe?(url) ?? scanner.evictedItems(inPackage: url) }.value
        guard !missing.isEmpty else { return true }
        setStatus(doc, state: "downloading", reason: "evicted",
                  message: String(localized: "Downloading from iCloud…"), files: missing)
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while !missing.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            missing = await Task.detached(priority: .userInitiated) { probe?(url) ?? scanner.evictedItems(inPackage: url) }.value
        }
        if missing.isEmpty {
            setStatus(doc, state: "idle")
            return true
        }
        log.error("\(doc.raw, privacy: .public): \(missing.count) items still downloading after \(Int(self.downloadTimeout)) s")
        setStatus(doc, state: "error", reason: "downloadTimeout",
                  message: String(localized: "Some of this document is still downloading from iCloud. Check your connection."),
                  files: missing)
        return false
    }

    // MARK: Status

    /// Sends `sync.status` for a document (nil = the library) when its state, reason or files changed.
    func setStatus(_ doc: DocumentID?, state: String, reason: String? = nil, message: String? = nil, files: [String]? = nil) {
        let key = doc?.raw ?? ""
        let payload = SyncStatusPayload(state: state, source: FolderWatcher.source, reason: reason, message: message,
                                        files: files.flatMap { $0.isEmpty ? nil : $0 })
        let previous = statuses[key]
        if let p = previous, p.state == payload.state, p.reason == payload.reason, p.files == payload.files { return }
        // A document nobody has heard about is idle: saying so again is noise.
        if previous == nil && state == "idle" { return }
        statuses[key] = payload
        app?.events.emit(payload, doc: doc)
    }

    /// The last status sent per document ("doc:<id>", "lib" for the library).
    var currentStatuses: [String: SyncStatusPayload] {
        var out: [String: SyncStatusPayload] = [:]
        for (k, v) in statuses { out[k.isEmpty ? "lib" : NodeRef.document(DocumentID(k)).description] = v }
        return out
    }

    // MARK: Paths

    nonisolated static func relativePath(_ url: URL, root: URL) -> String? {
        let base = root.standardizedFileURL.path, full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

}
