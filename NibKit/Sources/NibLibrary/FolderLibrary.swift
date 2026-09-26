import Foundation
import UIKit
import os
import NibContracts

// MARK: - Coordinated file operations

/// File operations inside the library folder, coordinated with `NSFileCoordinator` so File Providers (iCloud Drive,
/// OneDrive, Dropbox…) and the folder-sync presenters see every move, copy, write and delete.
enum FileOps {
    static func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions = [],
                           _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options,
                                                         error: &coordinationError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordinationError { throw LibraryErrors.map(e, url) }
        if let e = bodyError { throw LibraryErrors.map(e, url) }
    }

    /// Atomic write (the new bytes replace the file in one rename, so readers never see half a file).
    static func write(_ data: Data, to url: URL) throws {
        try coordinate(writing: url, options: .forReplacing) { u in
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u, options: .atomic)
        }
    }

    static func createDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try coordinate(writing: url) { u in
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
    }

    static func remove(_ url: URL) throws {
        try coordinate(writing: url, options: .forDeleting) { u in
            try FileManager.default.removeItem(at: u)
        }
    }

    /// Moves (renames) an item; `destination` must not exist.
    static func move(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                               options: .forReplacing, error: &coordinationError) { from, to in
            do {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                bodyError = error
            }
        }
        if let e = coordinationError { throw LibraryErrors.map(e, source) }
        if let e = bodyError { throw LibraryErrors.map(e, source) }
    }

    /// Copies an item (a whole package or folder); `destination` must not exist.
    static func copy(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], writingItemAt: destination,
                                                         options: .forReplacing, error: &coordinationError) { from, to in
            do {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            } catch {
                bodyError = error
            }
        }
        if let e = coordinationError { throw LibraryErrors.map(e, source) }
        if let e = bodyError { throw LibraryErrors.map(e, source) }
    }
}

enum LibraryErrors {
    /// A Cocoa file error as a `NibError` with a stable code.
    static func map(_ error: Error, _ url: URL) -> NibError {
        if let e = error as? NibError { return e }
        let ns = error as NSError
        let name = url.deletingPathExtension().lastPathComponent
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return NibError(.notFound, "'\(name)' is no longer in the library", hint: "call library.list to see what is there")
            case NSFileWriteOutOfSpaceError:
                return NibError(.unavailable, "there is not enough storage to change '\(name)'")
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return NibError(.permissionDenied, "Nib may not change '\(name)' in this folder",
                                hint: "choose the library folder again (library.chooseFolder)")
            case NSFileWriteFileExistsError:
                return NibError(.conflict, "an item named '\(name)' is already there")
            default:
                break
            }
        }
        return NibError(.internalError, "'\(name)': \(ns.localizedDescription)")
    }
}

// MARK: - File names

enum FileNames {
    /// A title as a file name: no "/" or ":", no control characters, no leading dots, at most 200 UTF-8 bytes.
    /// Empty → `fallback`.
    static func sanitize(_ title: String, fallback: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        s = String(s.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return Character(scalar)
        })
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        var out = ""
        for c in s {
            if out.utf8.count + String(c).utf8.count > 200 { break }
            out.append(c)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? fallback : out
    }

    /// The file name for `base` in `dir` that is free: "Name", "Name 2", "Name 3"… (`ext` appended). An existing item
    /// at `ignoring` does not count (renaming an item to its own name, or changing only the case).
    static func unique(_ base: String, ext: String?, in dir: URL, ignoring: URL? = nil) -> String {
        let fm = FileManager.default
        let ignored = ignoring?.standardizedFileURL.path.lowercased()
        func taken(_ name: String) -> Bool {
            let file = ext.map { name + "." + $0 } ?? name
            let url = dir.appendingPathComponent(file)
            if let i = ignored, url.standardizedFileURL.path.lowercased() == i { return false }
            if fm.fileExists(atPath: url.path) { return true }
            return fm.fileExists(atPath: dir.appendingPathComponent("." + file + LibraryLayout.placeholderSuffix).path)
        }
        if !taken(base) { return base }
        var n = 2
        while taken("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func fileName(_ base: String, ext: String?) -> String { ext.map { base + "." + $0 } ?? base }
}

// MARK: - The library

/// `LibraryService` over a folder the user chose (ARCHITECTURE §4.1). Folders are directories with per-device
/// `.nibfolder.<dev>.json` records, documents are `.nibnote` packages whose id is in their merged head, the Trash is
/// `trash` in the hidden `.nib-library` folder, next to the synced settings `prefs.<dev>.json` (`LibraryPrefs`). The catalog is
/// cached in Application Support and refreshed incrementally; `NibServices.packages` always mirrors it.
@MainActor
final class FolderLibrary: LibraryService {
    /// `NibServices` key of an `NSNumber` (Bool): the library folder is inside the app container (F070 banner, F093).
    static let inContainerKey = "library.inContainer"

    let device: String
    let prefs: LibraryPrefs
    private let clock: HLCClock
    private let events: EventBus
    private let locator: PackageLocator
    private let workspace: Workspace
    private let settings: SettingsStore
    private weak var services: NibServices?
    private let cacheDirectory: URL
    private let defaultRoot: URL
    private let log = Logger(subsystem: "app.nib", category: "library")

    private(set) var rootURL: URL
    /// The root whose security scope this library opened (stopped when switching).
    private var scopedRoot: URL?
    /// The saved bookmark could not be resolved at launch (reinstall, re-signed build): the library fell back to the
    /// app's Documents folder until the user picks the folder again (F025).
    private(set) var rootUnavailable = false
    private let catalog = LibraryCatalog()
    private var loaded = false
    private var started = false
    /// Bumped by every catalog change, so a background scan that raced a change is not applied over it.
    private var generation: UInt64 = 0
    private var scanning = false
    private var rescanRequested = false
    private var saveTask: Task<Void, Never>?
    private var quietChangeTask: Task<Void, Never>?
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []
    private let io = DispatchQueue(label: "app.nib.library.io", qos: .utility)

    /// `bus`: the library keeps catalog nodes in step with committed document heads from the start.
    init(settings: SettingsStore, clock: HLCClock, events: EventBus, locator: PackageLocator, workspace: Workspace,
         bus: CommandBus?, services: NibServices?, cacheDirectory: URL, defaultRoot: URL) {
        self.settings = settings
        self.clock = clock
        self.events = events
        self.locator = locator
        self.workspace = workspace
        self.services = services
        self.cacheDirectory = cacheDirectory
        self.defaultRoot = defaultRoot.standardizedFileURL
        self.device = clock.deviceHex
        let resolved = LibrarySettings.resolveRoot(settings, defaultRoot: defaultRoot.standardizedFileURL)
        rootURL = resolved.url
        scopedRoot = resolved.scoped ? resolved.url : nil
        rootUnavailable = resolved.failed
        prefs = LibraryPrefs(device: clock.deviceHex, clock: clock,
                             directory: resolved.url.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true))
        publishLocation()
        if let bus = bus {
            // A catalog that is not loaded yet has no entries, so commits before the first read cost nothing.
            subscriptions.append(bus.observeCommits { [weak self] cs in self?.didCommit(cs) })
        }
    }

    // MARK: Paths

    var metadataURL: URL { rootURL.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true) }
    var trashURL: URL { metadataURL.appendingPathComponent(LibraryLayout.trashDirectory, isDirectory: true) }

    /// The library folder is inside this app's container (Documents, …): a reinstall with another signer deletes it.
    var inContainer: Bool { FolderLibrary.isInside(rootURL.path, home: NSHomeDirectory()) }

    nonisolated static func isInside(_ path: String, home: String) -> Bool {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let h = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        return p == h || p.hasPrefix(h + "/")
    }

    private var cacheURL: URL {
        cacheDirectory.appendingPathComponent("catalog-" + LibraryIDs.key(rootURL.standardizedFileURL.path) + ".json")
    }

    private var isDefaultRoot: Bool {
        rootURL.resolvingSymlinksInPath().standardizedFileURL.path == defaultRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func url(of entry: CatalogEntry) -> URL {
        rootURL.appendingPathComponent(entry.node.path, isDirectory: true)
    }

    private func relativePath(_ url: URL) -> String {
        scanner(previous: [:]).relativePath(url)
    }

    private func scanner(previous: [String: CatalogEntry]) -> CatalogScanner {
        CatalogScanner(root: rootURL, device: device, previous: previous, skipInbox: isDefaultRoot)
    }

    private func publishLocation() {
        services?.set(NSNumber(value: inContainer), for: FolderLibrary.inContainerKey)
    }

    // MARK: Loading

    /// Loads the cached catalog, or scans the folder when there is none (first use before `start`).
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let cached = CatalogCache.load(cacheURL, root: rootURL.standardizedFileURL.path) {
            install(cached)
        } else {
            refresh()
        }
    }

    private func install(_ entries: [CatalogEntry]) {
        catalog.replaceAll(entries)
        locator.replaceAll(catalog.locations(root: rootURL))
    }

    /// Launch: the cached catalog (decoded off the main actor), the `.nib-library` marker, event and commit
    /// subscriptions, then an incremental rescan in the background.
    func start() async {
        guard !started else { return }
        started = true
        if !loaded {
            let url = cacheURL, root = rootURL.standardizedFileURL.path
            let cached = await Task.detached(priority: .userInitiated) { CatalogCache.load(url, root: root) }.value
            if !loaded, let c = cached {
                loaded = true
                install(c)
            } else if !loaded {
                // No cache for this library yet: scan it once before any feature opens a document (session restore
                // runs after this start), so every package is in `NibServices.packages`.
                let job = scanner(previous: [:])
                let entries = await Task.detached(priority: .userInitiated) { job.scan() }.value
                if !loaded {
                    loaded = true
                    apply(entries)
                }
            }
        }
        try? FileOps.createDirectory(metadataURL)
        if rootUnavailable {
            events.emit(SyncStatusPayload(state: "error", source: "library", reason: "rootUnavailable",
                                          message: String(localized: "The library folder could not be opened. Choose it again.")))
        }
        subscriptions.append(events.subscribe { [weak self] e in
            guard e.type == NibEventType.docOpened, let doc = e.doc else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.migrateLegacy(doc) }
            } else {
                Task { @MainActor in self?.migrateLegacy(doc) }
            }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prefs.flush()
                self?.saveCacheNow()
            }
        })
        refreshInBackground()
    }

    // MARK: LibraryService — reads

    func allNodes() -> [LibraryNode] {
        ensureLoaded()
        return catalog.liveNodes()
    }

    func node(_ id: NibID) -> LibraryNode? {
        ensureLoaded()
        return catalog.entry(id: id)?.node
    }

    func children(of folder: FolderID?) -> [LibraryNode] {
        ensureLoaded()
        return catalog.children(of: folder)
    }

    func packageURL(_ doc: DocumentID) -> URL? {
        ensureLoaded()
        guard let e = catalog.entry(id: doc), e.isDocument else { return nil }
        return url(of: e)
    }

    /// How many live items a folder holds (nil = the library root), without sorting them.
    func childCount(of folder: FolderID?) -> Int {
        ensureLoaded()
        return catalog.childCount(of: folder)
    }

    func trashedNodes() -> [LibraryNode] {
        ensureLoaded()
        return catalog.trashTopNodes()
    }

    /// The catalog entry of a folder or document (trash details, legacy flag).
    func entry(_ id: NibID) -> CatalogEntry? {
        ensureLoaded()
        return catalog.entry(id: id)
    }

    /// Pages in the page Trash of every live document: from the loaded head when the document is open (current), else
    /// from the catalog (as of the last scan).
    func trashedPages() -> [(doc: DocumentID, page: PageID, trashedAt: Double)] {
        ensureLoaded()
        var out: [(doc: DocumentID, page: PageID, trashedAt: Double)] = []
        for e in catalog.entries where e.isDocument && !e.inTrash {
            let doc = e.node.id
            let pages: [TrashedPage]
            if workspace.isLoaded(doc), let head = try? workspace.content(doc) {
                pages = HeadSummary(head).trashedPages
            } else {
                pages = e.trashedPages
            }
            for p in pages { out.append((doc, p.page, p.trashedAt)) }
        }
        return out
    }

    // MARK: LibraryService — creating

    func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID {
        ensureLoaded()
        var content = content
        let id = content.meta.id
        guard NibID.isValid(id.raw) else {
            throw NibError.invalid("document id must be 1–64 of [A-Za-z0-9_-]", path: "$.id")
        }
        guard catalog.entry(id: id) == nil else {
            throw NibError(.conflict, "the library already has an item with id \(id.raw)", hint: "omit id to get a fresh one")
        }
        let dir = try directory(of: folder)
        let base = FileNames.sanitize(title, fallback: String(localized: "Untitled"))
        let name = FileNames.unique(base, ext: NibFormat.packageExtension, in: dir)
        let pkg = dir.appendingPathComponent(FileNames.fileName(name, ext: NibFormat.packageExtension), isDirectory: true)
        if content.meta.rev == .zero { content.meta.rev = clock.tick() }
        let data = try PackageIO.encoder().encode(content)
        let headName = LibraryLayout.headFileName(device)
        try FileOps.coordinate(writing: pkg) { u in
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try data.write(to: u.appendingPathComponent(headName), options: .atomic)
        }
        let path = relativePath(pkg)
        let now = Date().timeIntervalSince1970
        var node = LibraryNode(id: id, kind: .document, title: name, path: path, parent: folder, modified: now, created: now)
        node.sync = UbiquityState(try? pkg.resourceValues(forKeys: Set(UbiquityState.resourceKeys))).badge
        var entry = CatalogEntry(node: node, parentPath: LibraryLayout.parentPath(of: path))
        entry.apply(HeadSummary(content))
        entry.node.parent = folder
        catalog.upsert(entry)
        locator.set(pkg, for: id)
        changed([entry.ref])
        return id
    }

    func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID {
        try createFolder(title: title, in: parent, style: style, id: nil)
    }

    /// Creates a folder with its `.nibfolder.<dev>.json` record; `id` is the caller's (AI batches link records by it).
    func createFolder(title: String, in parent: FolderID?, style: FolderStyle?, id: FolderID?) throws -> FolderID {
        ensureLoaded()
        let fid = id ?? NibID.make()
        guard NibID.isValid(fid.raw) else { throw NibError.invalid("folder id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        guard catalog.entry(id: fid) == nil else {
            throw NibError(.conflict, "the library already has an item with id \(fid.raw)", hint: "omit id to get a fresh one")
        }
        let dir = try directory(of: parent)
        let name = FileNames.unique(FileNames.sanitize(title, fallback: String(localized: "New Folder")), ext: nil, in: dir)
        let url = dir.appendingPathComponent(name, isDirectory: true)
        let record = FolderRecord(id: fid, rev: clock.tick(), style: style ?? FolderStyle())
        let data = try FolderRecords.encode(record)
        let recordName = LibraryLayout.folderFileName(device)
        try FileOps.coordinate(writing: url) { u in
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try data.write(to: u.appendingPathComponent(recordName), options: .atomic)
        }
        let path = relativePath(url)
        let now = Date().timeIntervalSince1970
        let node = LibraryNode(id: fid, kind: .folder, title: name, path: path, parent: parent, modified: now, created: now,
                               favorite: record.favorite, style: record.style,
                               sync: UbiquityState(try? url.resourceValues(forKeys: Set(UbiquityState.resourceKeys))).badge)
        let entry = CatalogEntry(node: node, parentPath: LibraryLayout.parentPath(of: path), hasRecord: true)
        catalog.upsert(entry)
        changed([entry.ref])
        return fid
    }

    // MARK: LibraryService — organising

    func rename(_ id: NibID, to title: String) throws {
        _ = try renameItem(id, to: title)
    }

    /// Renames a document package or folder; returns the name it got (made unique in its folder).
    @discardableResult
    func renameItem(_ id: NibID, to title: String) throws -> String {
        ensureLoaded()
        guard let e = catalog.entry(id: id) else { throw NibError.notFound("library item \(id.raw)") }
        let old = url(of: e)
        let base = FileNames.sanitize(title, fallback: e.node.title)
        let ext: String? = e.isDocument ? NibFormat.packageExtension : nil
        if base == e.node.title && !e.legacy { return base }
        try pinFolderIDs(under: e)
        flushDocuments(under: e)
        let dir = old.deletingLastPathComponent()
        let name = FileNames.unique(base, ext: ext, in: dir, ignoring: old)
        let new = dir.appendingPathComponent(FileNames.fileName(name, ext: ext), isDirectory: true)
        try moveItem(old, to: new)
        relocate(e, to: new, inTrash: e.inTrash, trashTop: e.trashTop, parent: e.node.parent)
        changed([e.ref])
        return name
    }

    func move(_ id: NibID, to folder: FolderID?) throws {
        ensureLoaded()
        guard let e = catalog.entry(id: id) else { throw NibError.notFound("library item \(id.raw)") }
        if e.inTrash {
            guard e.trashTop else {
                throw NibError(.invalidParams, "'\(e.node.title)' is inside a trashed folder",
                               hint: "recover the folder with trash.recover")
            }
            try restore(id, to: folder)
            return
        }
        let destination = try directory(of: folder)
        if e.isFolder, let f = folder, let target = catalog.entry(id: f), LibraryLayout.isWithin(target.node.path, e.node.path) {
            throw NibError(.invalidParams, "a folder cannot be moved into itself or one of its subfolders", path: "$.folder")
        }
        if e.node.parent == folder && !e.legacy { return }
        try pinFolderIDs(under: e)
        flushDocuments(under: e)
        let old = url(of: e)
        let ext: String? = e.isDocument ? NibFormat.packageExtension : nil
        let name = FileNames.unique(e.node.title, ext: ext, in: destination, ignoring: old)
        let new = destination.appendingPathComponent(FileNames.fileName(name, ext: ext), isDirectory: true)
        try moveItem(old, to: new)
        relocate(e, to: new, inTrash: false, trashTop: false, parent: folder)
        changed([e.ref])
    }

    func setStyle(_ style: FolderStyle, folder: FolderID) throws {
        ensureLoaded()
        guard var e = catalog.entry(id: folder), e.isFolder else { throw NibError.notFound("folder \(folder.raw)") }
        let record = try updateFolderRecord(in: url(of: e), id: e.node.id) { r in
            r.color = style.color
            r.icon = style.icon
            r.favorite = style.favorite
        }
        e.node.style = record.style
        e.node.favorite = record.favorite
        e.hasRecord = true
        catalog.upsert(e)
        changed([e.ref])
    }

    // MARK: LibraryService — duplicating

    func duplicate(_ id: NibID) throws -> NibID {
        let job = try prepareDuplicate(id, as: nil)
        try job.run()
        return finishDuplicate(job, top: job.topID ?? id)
    }

    /// Duplicates a document (new id in this device's head, other heads removed) or a folder (new ids for every folder
    /// and document inside), next to the original. The copying runs off the main actor.
    func duplicate(_ id: NibID, as newID: NibID?) async throws -> NibID {
        let job = try prepareDuplicate(id, as: newID)
        try await Task.detached(priority: .userInitiated) { try job.run() }.value
        return finishDuplicate(job, top: job.topID ?? id)
    }

    private func prepareDuplicate(_ id: NibID, as newID: NibID?) throws -> CopyJob {
        ensureLoaded()
        guard let e = catalog.entry(id: id) else { throw NibError.notFound("library item \(id.raw)") }
        guard !e.inTrash else {
            throw NibError(.invalidParams, "'\(e.node.title)' is in the Trash", hint: "recover it first with trash.recover")
        }
        let top = newID ?? NibID.make()
        guard NibID.isValid(top.raw) else { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.ids") }
        guard catalog.entry(id: top) == nil else {
            throw NibError(.conflict, "the library already has an item with id \(top.raw)", hint: "omit ids to get fresh ones")
        }
        flushDocuments(under: e)
        let source = url(of: e)
        let dir = source.deletingLastPathComponent()
        let ext: String? = e.isDocument ? NibFormat.packageExtension : nil
        let base = FileNames.sanitize(String(localized: "\(e.node.title) copy"), fallback: e.node.title)
        let name = FileNames.unique(base, ext: ext, in: dir)
        let destination = dir.appendingPathComponent(FileNames.fileName(name, ext: ext), isDirectory: true)
        return CopyJob(source: source, destination: destination, topID: top, device: device, clock: clock,
                       taken: Set(catalog.entries.map { $0.node.id }), collapseHeads: true)
    }

    private func finishDuplicate(_ job: CopyJob, top fallback: NibID) -> NibID {
        let added = scanner(previous: [:]).scanItem(at: job.destination, inTrash: false, trashTop: false,
                                                    existing: catalog.byPath)
        for entry in added {
            catalog.upsert(entry)
            if entry.isDocument { locator.set(url(of: entry), for: entry.node.id) }
        }
        let top = added.first { $0.node.path == relativePath(job.destination) }
        changed(added.map { $0.ref })
        return top?.node.id ?? fallback
    }

    // MARK: LibraryService — Trash

    func trash(_ id: NibID) throws {
        ensureLoaded()
        guard let e = catalog.entry(id: id) else { throw NibError.notFound("library item \(id.raw)") }
        if e.inTrash { return }
        let now = Date().timeIntervalSince1970
        let from = e.parentPath
        let fromFolder = e.node.parent
        try pinFolderIDs(under: e)
        closeDocuments(under: e)
        try FileOps.createDirectory(trashURL)
        let old = url(of: e)
        let ext: String? = e.isDocument ? NibFormat.packageExtension : nil
        let name = FileNames.unique(e.node.title, ext: ext, in: trashURL)
        let new = trashURL.appendingPathComponent(FileNames.fileName(name, ext: ext), isDirectory: true)
        try moveItem(old, to: new)
        do {
            try recordTrash(e, at: new, from: from, folder: fromFolder, at: now)
        } catch {
            log.error("could not record where \(e.node.title, privacy: .private) came from: \(error.localizedDescription, privacy: .public)")
        }
        relocate(e, to: new, inTrash: true, trashTop: true, parent: fromFolder) { entry in
            entry.trashedFrom = from
            entry.trashedFromFolder = fromFolder
            entry.node.trashedAt = now
        }
        changed([e.ref])
    }

    /// Writes where a trashed item came from into its head (`meta.trashedFrom`) or folder record.
    private func recordTrash(_ e: CatalogEntry, at url: URL, from: String, folder: FolderID?, at time: Double) throws {
        if e.isDocument {
            try PackageIO.updateHead(url, device: device, clock: clock) { head in
                head.meta.trashedFrom = from
                var ext = head.meta.ext ?? [:]
                ext[LibraryLayout.trashedAtKey] = .number(time)
                ext[LibraryLayout.trashedFromFolderKey] = folder.map { .string($0.raw) }
                head.meta.ext = ext
            }
        } else {
            try updateFolderRecord(in: url, id: e.node.id) { r in
                r.trashedFrom = from
                r.trashedFromFolder = folder
                r.trashedAt = time
            }
        }
    }

    /// Clears the trash record of a recovered item.
    private func clearTrash(_ e: CatalogEntry, at url: URL) throws {
        if e.isDocument {
            try PackageIO.updateHead(url, device: device, clock: clock) { head in
                head.meta.trashedFrom = nil
                head.meta.ext?[LibraryLayout.trashedAtKey] = nil
                head.meta.ext?[LibraryLayout.trashedFromFolderKey] = nil
                if head.meta.ext?.isEmpty == true { head.meta.ext = nil }
            }
        } else {
            try updateFolderRecord(in: url, id: e.node.id) { r in
                r.trashedFrom = nil
                r.trashedFromFolder = nil
                r.trashedAt = nil
            }
        }
    }

    func restore(_ id: NibID, to folder: FolderID?) throws {
        ensureLoaded()
        guard let e = catalog.entry(id: id) else { throw NibError.notFound("library item \(id.raw)") }
        guard e.inTrash else {
            if let f = folder, f != e.node.parent { try move(id, to: f) }
            return
        }
        guard e.trashTop else {
            throw NibError(.invalidParams, "'\(e.node.title)' is inside a trashed folder", hint: "recover the folder instead")
        }
        let (destination, parent) = try restoreDestination(e, requested: folder)
        closeDocuments(under: e)
        let old = url(of: e)
        let ext: String? = e.isDocument ? NibFormat.packageExtension : nil
        let name = FileNames.unique(e.node.title, ext: ext, in: destination)
        let new = destination.appendingPathComponent(FileNames.fileName(name, ext: ext), isDirectory: true)
        try moveItem(old, to: new)
        do {
            try clearTrash(e, at: new)
        } catch {
            log.error("could not clear the trash record of \(e.node.title, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
        relocate(e, to: new, inTrash: false, trashTop: false, parent: parent) { entry in
            entry.trashedFrom = nil
            entry.trashedFromFolder = nil
            entry.node.trashedAt = nil
        }
        changed([e.ref])
    }

    /// Where a recovered item goes: the requested folder, else the live folder it was trashed from (by id, so a renamed
    /// or moved folder still gets it back), else the folder at its old path, else the library root.
    private func restoreDestination(_ e: CatalogEntry, requested: FolderID?) throws -> (URL, FolderID?) {
        if let f = requested { return (try directory(of: f), f) }
        if let original = e.trashedFromFolder, let f = catalog.entry(id: original), f.isFolder, !f.inTrash {
            return (url(of: f), f.node.id)
        }
        if let path = e.trashedFrom, !path.isEmpty, let f = catalog.entry(path: path), f.isFolder, !f.inTrash {
            return (url(of: f), f.node.id)
        }
        return (rootURL, nil)
    }

    func deletePermanently(_ id: NibID) throws {
        ensureLoaded()
        guard let e = catalog.entry(id: id) else { throw NibError.notFound("library item \(id.raw)") }
        closeDocuments(under: e)
        let target = url(of: e)
        if FileManager.default.fileExists(atPath: target.path) { try FileOps.remove(target) }
        let removed = catalog.subtree(path: e.node.path)
        catalog.removeSubtree(path: e.node.path)
        for r in removed where r.isDocument { locator.set(nil, for: r.node.id) }
        changed([e.ref])
    }

    /// Deletes everything in the Trash (including files Nib does not know); returns how many items were deleted.
    @discardableResult
    func emptyTrash() throws -> Int {
        ensureLoaded()
        let top = catalog.entries.filter { $0.trashTop }
        for e in top { closeDocuments(under: e) }
        var removed = 0
        var failure: Error?
        let items = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil,
                                                                   options: [])) ?? []
        for item in items {
            do {
                try FileOps.remove(item)
                removed += 1
            } catch {
                failure = failure ?? error
            }
        }
        if let failure = failure {
            refresh()
            throw failure
        }
        let gone = catalog.entries.filter { $0.inTrash }
        catalog.removeSubtree(path: LibraryLayout.trashPath)
        for r in gone where r.isDocument { locator.set(nil, for: r.node.id) }
        changed(top.map { $0.ref })
        return removed
    }

    // MARK: LibraryService — import

    func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID {
        let job = try prepareImport(url, into: folder)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try job.run()
        return try finishImport(job)
    }

    private func prepareImport(_ url: URL, into folder: FolderID?) throws -> CopyJob {
        ensureLoaded()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NibError(.invalidParams, "'\(url.lastPathComponent)' is not a Nib package or a folder",
                           hint: "import files with import.files")
        }
        let dir = try directory(of: folder)
        let ext = url.pathExtension.lowercased()
        let isPackage = ext == NibFormat.packageExtension || (ext == NibFormat.legacyPackageExtension && PackageIO.hasHeadFile(url))
        let base = FileNames.sanitize(url.deletingPathExtension().lastPathComponent, fallback: String(localized: "Imported"))
        let targetExt: String? = isPackage ? NibFormat.packageExtension : nil
        let name = FileNames.unique(base, ext: targetExt, in: dir)
        let destination = dir.appendingPathComponent(FileNames.fileName(name, ext: targetExt), isDirectory: true)
        return CopyJob(source: url, destination: destination, topID: nil, device: device, clock: clock,
                       taken: Set(catalog.entries.map { $0.node.id }), collapseHeads: false)
    }

    private func finishImport(_ job: CopyJob) throws -> DocumentID {
        let added = scanner(previous: [:]).scanItem(at: job.destination, inTrash: false, trashTop: false,
                                                    existing: catalog.byPath)
        for entry in added {
            catalog.upsert(entry)
            if entry.isDocument { locator.set(url(of: entry), for: entry.node.id) }
        }
        changed(added.map { $0.ref })
        guard let first = added.first(where: { $0.isDocument }) else {
            throw NibError(.invalidParams, "'\(job.source.lastPathComponent)' holds no Nib documents",
                           hint: "import PDFs, images and other files with import.files")
        }
        return first.node.id
    }

    // MARK: LibraryService — refresh and root

    func refresh() {
        loaded = true
        let entries = scanner(previous: catalog.byPath).scan()
        apply(entries)
        let changedNames = prefs.reload()
        postSettingsChanges(changedNames)
    }

    /// An incremental rescan off the main actor (launch, foreground). Applied only when no change happened meanwhile.
    func refreshInBackground() {
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        let gen = generation
        let job = scanner(previous: catalog.byPath)
        let prefs = self.prefs
        Task.detached(priority: .utility) { [weak self] in
            let entries = job.scan()
            let changedNames = prefs.reload()
            await self?.finishBackgroundScan(entries, generation: gen, root: job.root, settings: changedNames)
        }
    }

    private func finishBackgroundScan(_ entries: [CatalogEntry], generation gen: UInt64, root: URL, settings names: [String]) {
        scanning = false
        if generation == gen && root == rootURL {
            apply(entries)
        } else {
            rescanRequested = true
        }
        postSettingsChanges(names)
        if rescanRequested {
            rescanRequested = false
            refreshInBackground()
        }
    }

    private func apply(_ entries: [CatalogEntry]) {
        let before = catalog.byPath
        install(entries)
        var refs: [String] = []
        for e in entries where before[e.node.path] != e { refs.append(e.ref) }
        let now = Set(entries.map { $0.node.path })
        for (path, e) in before where !now.contains(path) { refs.append(e.ref) }
        generation &+= 1
        if !refs.isEmpty || before.isEmpty {
            scheduleCacheSave()
            events.emit(NibEventType.libraryChanged, payload: ["refresh": true, "refs": .array(refs.prefix(500).map { .string($0) })])
        }
    }

    func setRoot(_ url: URL) throws {
        let target = url.standardizedFileURL
        let scoped = target.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if scoped { target.stopAccessingSecurityScopedResource() }
            throw NibError(.notFound, "the folder '\(target.lastPathComponent)' is not reachable",
                           hint: "choose the folder again with library.chooseFolder")
        }
        let isDefault = target.resolvingSymlinksInPath().path == defaultRoot.resolvingSymlinksInPath().path
        var bookmark: Data?
        if !isDefault {
            do {
                bookmark = try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                if scoped { target.stopAccessingSecurityScopedResource() }
                throw NibError(.unavailable, "Nib cannot remember the folder '\(target.lastPathComponent)' (\(error.localizedDescription))",
                               hint: "choose another folder")
            }
        }
        // Open documents belong to the old library: write them out and close them before switching.
        for doc in workspace.loadedDocuments { workspace.close(doc) }
        prefs.flush()
        saveCacheNow()
        if let old = scopedRoot, old != target { old.stopAccessingSecurityScopedResource() }
        scopedRoot = scoped ? target : nil
        rootURL = target
        rootUnavailable = false
        LibrarySettings.saveRoot(bookmark, settings)
        try? FileOps.createDirectory(metadataURL)
        catalog.replaceAll(CatalogCache.load(cacheURL, root: rootURL.standardizedFileURL.path) ?? [])
        loaded = true
        generation &+= 1
        postSettingsChanges(prefs.setDirectory(metadataURL))
        refresh()
        publishLocation()
    }

    // MARK: Legacy packages

    /// A legacy `*.nib` package becomes a `.nibnote` package the first time it is opened.
    func migrateLegacy(_ doc: DocumentID) {
        guard let e = catalog.entry(id: doc), e.isDocument, e.legacy else { return }
        let old = url(of: e)
        let dir = old.deletingLastPathComponent()
        let name = FileNames.unique(e.node.title, ext: NibFormat.packageExtension, in: dir)
        let new = dir.appendingPathComponent(FileNames.fileName(name, ext: NibFormat.packageExtension), isDirectory: true)
        do {
            try FileOps.move(old, to: new)
            relocate(e, to: new, inTrash: e.inTrash, trashTop: e.trashTop, parent: e.node.parent)
            changed([e.ref])
        } catch {
            log.error("could not rename the legacy package \(old.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Commits

    private func didCommit(_ cs: Changeset) {
        var refs: [String] = []
        var touched = false
        let now = Date().timeIntervalSince1970
        for doc in cs.documents {
            guard var e = catalog.entry(id: doc), e.isDocument else { continue }
            let before = e
            e.node.modified = now
            if cs.headChanged(doc), let head = try? workspace.content(doc) {
                let trashedAt = e.node.trashedAt
                let headID = e.headID
                e.apply(HeadSummary(head))
                e.node.trashedAt = e.trashTop ? trashedAt : nil
                e.headID = headID
            }
            catalog.upsert(e)
            touched = true
            let visible = before.node.favorite != e.node.favorite || before.node.locked != e.node.locked
                || before.node.documentKind != e.node.documentKind || before.node.pageCount != e.node.pageCount
                || before.trashedPages != e.trashedPages
            if visible { refs.append(e.ref) }
        }
        if !refs.isEmpty {
            changed(refs)
        } else if touched {
            scheduleCacheSave()
            scheduleQuietChange()
        }
    }

    /// Modification times change with every stroke: tell the library at most every few seconds.
    private func scheduleQuietChange() {
        guard quietChangeTask == nil else { return }
        quietChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self = self else { return }
            self.quietChangeTask = nil
            self.events.emit(NibEventType.libraryChanged, payload: ["modified": true])
        }
    }

    // MARK: Helpers

    /// The directory of a live folder (nil = the library root).
    private func directory(of folder: FolderID?) throws -> URL {
        guard let f = folder else { return rootURL }
        guard let e = catalog.entry(id: f), e.isFolder else {
            throw NibError(.notFound, "folder \(f.raw) not found", path: "$.folder", hint: "call library.list to see folders")
        }
        guard !e.inTrash else {
            throw NibError(.invalidParams, "folder '\(e.node.title)' is in the Trash", path: "$.folder",
                           hint: "recover it first with trash.recover")
        }
        return url(of: e)
    }

    /// Moves an item, going through a temporary name when only the case of the name changes.
    private func moveItem(_ old: URL, to new: URL) throws {
        if old.standardizedFileURL.path == new.standardizedFileURL.path { return }
        if old.standardizedFileURL.path.lowercased() == new.standardizedFileURL.path.lowercased() {
            let temp = old.deletingLastPathComponent().appendingPathComponent(".nib-rename-" + UUID().uuidString)
            try FileOps.move(old, to: temp)
            try FileOps.move(temp, to: new)
        } else {
            try FileOps.move(old, to: new)
        }
    }

    /// Updates the catalog (and package locations) after `entry` moved to `new` with everything inside it.
    private func relocate(_ entry: CatalogEntry, to new: URL, inTrash: Bool, trashTop: Bool, parent: FolderID?,
                          _ update: (inout CatalogEntry) -> Void = { _ in }) {
        let oldPath = entry.node.path
        let newPath = relativePath(new)
        let subtree = catalog.subtree(path: oldPath)
        catalog.removeSubtree(path: oldPath)
        for var e in subtree {
            let suffix = String(e.node.path.dropFirst(oldPath.count))
            e.node.path = newPath + suffix
            e.inTrash = inTrash
            if suffix.isEmpty {
                e.parentPath = LibraryLayout.parentPath(of: newPath)
                e.node.parent = parent
                e.trashTop = trashTop
                e.node.title = e.isDocument ? (new.lastPathComponent as NSString).deletingPathExtension : new.lastPathComponent
                if e.isDocument { e.legacy = new.pathExtension.lowercased() != NibFormat.packageExtension }
                e.stamp = nil
                update(&e)
            } else {
                e.parentPath = newPath + String(e.parentPath.dropFirst(oldPath.count))
                e.trashTop = false
            }
            catalog.upsert(e)
            if e.isDocument { locator.set(rootURL.appendingPathComponent(e.node.path, isDirectory: true), for: e.node.id) }
        }
    }

    /// Writes a `.nibfolder` record for every folder at or under `entry` whose id is still derived from its path, so the
    /// id survives the path changing.
    private func pinFolderIDs(under entry: CatalogEntry) throws {
        for var e in catalog.subtree(path: entry.node.path) where e.isFolder && !e.hasRecord {
            let style = e.node.style ?? FolderStyle(favorite: e.node.favorite)
            try updateFolderRecord(in: url(of: e), id: e.node.id) { r in
                r.color = style.color
                r.icon = style.icon
                r.favorite = style.favorite
            }
            e.hasRecord = true
            e.derivedID = false
            catalog.upsert(e)
        }
    }

    /// Rewrites this device's `.nibfolder` record as the merged record with `change` applied, at a revision above every
    /// device's, then removes merged conflict copies.
    @discardableResult
    private func updateFolderRecord(in dir: URL, id: FolderID, _ change: (inout FolderRecord) -> Void) throws -> FolderRecord {
        let files = FolderRecords.files(in: dir, device: device)
        var record = FolderRecord.merged(files.compactMap { FolderRecords.read($0) }) ?? FolderRecord(id: id, rev: .zero)
        clock.observe(record.rev)
        change(&record)
        record.rev = clock.tick()
        try FileOps.write(try FolderRecords.encode(record), to: dir.appendingPathComponent(LibraryLayout.folderFileName(device)))
        for file in files where LibraryLayout.device(of: file.lastPathComponent, prefix: LibraryLayout.folderPrefix)?.exact == false {
            try? FileOps.remove(file)
        }
        return record
    }

    /// Writes pending changes of open documents at or under `entry` (before their package moves).
    private func flushDocuments(under entry: CatalogEntry) {
        for e in catalog.subtree(path: entry.node.path) where e.isDocument && workspace.isLoaded(e.node.id) {
            workspace.persistence.flush(e.node.id)
        }
    }

    /// Writes out and closes open documents at or under `entry` (before they go to or leave the Trash, or are deleted):
    /// their next read comes from the package's new place, with the library's head changes merged in.
    private func closeDocuments(under entry: CatalogEntry) {
        for e in catalog.subtree(path: entry.node.path) where e.isDocument && workspace.isLoaded(e.node.id) {
            workspace.close(e.node.id)
        }
    }

    private func changed(_ refs: [String]) {
        generation &+= 1
        scheduleCacheSave()
        events.emit(NibEventType.libraryChanged, payload: ["refs": .array(refs.prefix(500).map { .string($0) })])
    }

    private func scheduleCacheSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveCacheNow()
        }
    }

    /// Writes the catalog cache (encoded on the library's I/O queue).
    func saveCacheNow() {
        guard loaded else { return }
        let cache = CatalogCache(version: CatalogCache.currentVersion, root: rootURL.standardizedFileURL.path,
                                 entries: catalog.entries)
        let url = cacheURL
        let log = self.log
        io.async {
            do {
                try cache.write(to: url)
            } catch {
                log.error("could not save the library catalog: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits for queued cache writes (tests).
    func waitForIO() {
        io.sync {}
    }

    private func postSettingsChanges(_ names: [String]) {
        for name in names {
            NotificationCenter.default.post(name: SettingsStore.didChange, object: settings, userInfo: ["name": name])
        }
    }
}

// MARK: - Copies (duplicate, import)

/// Copies a package or folder into the library and gives the copy its own identity. Duplicates give every document
/// and folder inside a new id (documents keep only this device's head); imports only re-identify documents and folders
/// whose ids the library already has. Runs off the main actor: file I/O, a thread-safe clock and value state only.
struct CopyJob {
    let source: URL
    let destination: URL
    /// The id of the top item of a duplicate (nil for imports).
    let topID: NibID?
    let device: String
    let clock: HLCClock
    /// Ids the library already uses.
    let taken: Set<NibID>
    /// Duplicates: every document gets a new id and keeps only this device's head.
    let collapseHeads: Bool

    /// Copies, then re-identifies; a copy that cannot get its own identity is removed again.
    func run() throws {
        try FileOps.copy(source, to: destination)
        var used = taken
        do {
            try identify(destination, isTop: true, used: &used)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func identify(_ url: URL, isTop: Bool, used: inout Set<NibID>) throws {
        let ext = url.pathExtension.lowercased()
        let fm = FileManager.default
        if ext == NibFormat.packageExtension || (ext == NibFormat.legacyPackageExtension && PackageIO.hasHeadFile(url)) {
            var target = url
            if ext != NibFormat.packageExtension {
                let dir = url.deletingLastPathComponent()
                let name = FileNames.unique(url.deletingPathExtension().lastPathComponent, ext: NibFormat.packageExtension, in: dir)
                target = dir.appendingPathComponent(FileNames.fileName(name, ext: NibFormat.packageExtension), isDirectory: true)
                try fm.moveItem(at: url, to: target)
            }
            try identifyDocument(target, isTop: isTop, used: &used)
            return
        }
        try identifyFolder(url, isTop: isTop, used: &used)
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for child in children where !child.lastPathComponent.hasPrefix(".") {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            try identify(child, isTop: false, used: &used)
        }
    }

    private func identifyDocument(_ pkg: URL, isTop: Bool, used: inout Set<NibID>) throws {
        let current = PackageIO.readMergedHead(pkg, device: device)?.meta.id
        if !collapseHeads, let id = current, NibID.isValid(id.raw), used.insert(id).inserted { return }
        var fresh = isTop ? (topID ?? NibID.make()) : NibID.make()
        while used.contains(fresh) { fresh = NibID.make() }
        used.insert(fresh)
        let now = Date().timeIntervalSince1970
        let duplicate = collapseHeads
        try PackageIO.updateHead(pkg, device: device, clock: clock, collapse: true) { head in
            head.meta.id = fresh
            if duplicate {
                head.meta.createdAt = now
                head.meta.sourceBookmark = nil
            }
            head.meta.trashedFrom = nil
            head.meta.ext?[LibraryLayout.trashedAtKey] = nil
            head.meta.ext?[LibraryLayout.trashedFromFolderKey] = nil
        }
    }

    private func identifyFolder(_ dir: URL, isTop: Bool, used: inout Set<NibID>) throws {
        let files = FolderRecords.files(in: dir, device: device)
        let merged = FolderRecord.merged(files.compactMap { FolderRecords.read($0) })
        if !collapseHeads, let id = merged?.id, used.insert(id).inserted { return }
        var fresh = isTop ? (topID ?? NibID.make()) : NibID.make()
        while used.contains(fresh) { fresh = NibID.make() }
        used.insert(fresh)
        var record = merged ?? FolderRecord(id: fresh, rev: .zero)
        clock.observe(record.rev)
        record.id = fresh
        record.trashedFrom = nil
        record.trashedFromFolder = nil
        record.trashedAt = nil
        record.rev = clock.tick()
        try FileOps.write(try FolderRecords.encode(record), to: dir.appendingPathComponent(LibraryLayout.folderFileName(device)))
        let own = LibraryLayout.folderFileName(device)
        for file in files where file.lastPathComponent != own { try? FileManager.default.removeItem(at: file) }
    }
}
