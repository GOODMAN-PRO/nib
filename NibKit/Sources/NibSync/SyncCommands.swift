import Foundation
import os
import NibContracts

// MARK: - Registration

enum SyncCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(SyncNow.self)
        r.register(LibraryChooseFolder.self)
        r.register(LibraryRelocate.self)
        r.register(LibraryLocationsList.self)
        r.register(LibrarySwitch.self)
    }

    @MainActor
    static func watcher(_ ctx: CommandContext) -> FolderWatcher? {
        ctx.services.get(FolderWatcher.serviceKey, as: FolderWatcher.self)
    }

    @MainActor
    static func library(_ ctx: CommandContext) throws -> LibraryService {
        guard let library = ctx.services.library else { throw NibError.unavailable("the library") }
        return library
    }

    static var now: Double { Date().timeIntervalSince1970 }
}

// MARK: - Known library folders

/// A library folder this device has used, remembered as the device setting `sync.locations.<id>` (one key per folder;
/// device-local, because bookmarks only work on the device that made them).
struct KnownLocation: Codable, Equatable {
    var id: String
    var name: String
    /// Where the folder was last seen (display and matching; the bookmark finds it when it moved).
    var path: String
    /// Base64 bookmark data; "" for the folder inside the app (its path changes with every install).
    var bookmark: String
    var inApp: Bool
    /// Unix seconds.
    var added: Double
    /// Unix seconds this folder was last the library (switched to, or switched away from).
    var lastUsed: Double?

    init(id: String, name: String, path: String, bookmark: String, inApp: Bool, added: Double, lastUsed: Double? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.inApp = inApp
        self.added = added
        self.lastUsed = lastUsed
    }

    enum CodingKeys: String, CodingKey { case id, name, path, bookmark, inApp, added, lastUsed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark) ?? ""
        inApp = try c.decodeIfPresent(Bool.self, forKey: .inApp) ?? false
        added = try c.decodeIfPresent(Double.self, forKey: .added) ?? 0
        lastUsed = try c.decodeIfPresent(Double.self, forKey: .lastUsed)
    }
}

/// The store of known library folders. Written only by this feature's commands (the setting family is read-only for
/// `settings.set`, so no caller can plant a bookmark).
enum KnownLocations {
    static let prefix = "sync.locations."
    /// The id of the folder inside the app (the default library).
    static let appID = "app"

    static func declare(_ settings: SettingsStore, owner: String) {
        let schema: JSONSchema = .obj(["id": .str(), "name": .str(), "path": .str(), "bookmark": .str("base64 bookmark data"),
                                       "inApp": .bool(), "added": .num(), "lastUsed": .num()], required: ["id"])
        settings.declarePrefix(prefix, synced: false,
                               summary: "Library folders this device has used (one entry per folder; switch with library.switch).",
                               owner: owner, schema: schema, readOnly: true)
    }

    static func all(_ settings: SettingsStore) -> [KnownLocation] {
        settings.names(prefix: prefix).compactMap { name -> KnownLocation? in
            guard let json = settings.json(name), json != .null else { return nil }
            return try? json.decode(KnownLocation.self)
        }.sorted { ($0.lastUsed ?? $0.added, $1.name) > ($1.lastUsed ?? $1.added, $0.name) }
    }

    static func save(_ location: KnownLocation, _ settings: SettingsStore) {
        guard let json = try? JSONValue.from(location) else { return }
        settings.setJSON(prefix + location.id, json)
    }

    static func remove(_ id: String, _ settings: SettingsStore) {
        settings.setJSON(prefix + id, nil)
    }

    /// A stable id for a folder first seen at `url`: "app" for the folder inside the app, else 16 hex characters of a
    /// hash of its path.
    static func makeID(for url: URL) -> String {
        if LibraryFolder.isAppDocuments(url) { return appID }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in LibraryFolder.canonicalPath(url).utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", h)
    }

    static func matches(_ location: KnownLocation, _ url: URL) -> Bool {
        if location.inApp { return LibraryFolder.isAppDocuments(url) }
        return !location.path.isEmpty && location.path == LibraryFolder.canonicalPath(url)
    }

    /// The entry for `url`, updated from `existing` when this device knew the folder already: by its path, or (for a
    /// library picked again after its bookmark stopped working) by its name among entries that no longer open.
    static func entry(for url: URL, bookmark: Data?, existing: [KnownLocation], now: Double) -> KnownLocation {
        let inApp = LibraryFolder.isAppDocuments(url)
        let path = LibraryFolder.canonicalPath(url)
        let name = LibraryFolder.displayName(url)
        let mark = inApp ? "" : (bookmark?.base64EncodedString() ?? "")
        var match = existing.first { matches($0, url) }
        if match == nil, !inApp, LibraryFolder.isLibrary(url) {
            match = existing.first { !$0.inApp && ($0.path as NSString).lastPathComponent == url.lastPathComponent && !reachable($0) }
        }
        if var known = match {
            known.name = name
            known.path = path
            known.inApp = inApp
            if !mark.isEmpty || inApp { known.bookmark = mark }
            return known
        }
        return KnownLocation(id: makeID(for: url), name: name, path: path, bookmark: mark, inApp: inApp, added: now)
    }

    /// A known folder opened for use: its URL (with security scope started when it has one) and, when the bookmark
    /// was stale, a fresh one to save.
    struct Opened {
        var url: URL
        var access: ScopedAccess?
        var freshBookmark: Data?
    }

    static func open(_ location: KnownLocation) throws -> Opened {
        if location.inApp {
            guard let docs = LibraryFolder.appDocuments else { throw NibError.unavailable("the app's Documents folder") }
            return Opened(url: docs, access: nil, freshBookmark: nil)
        }
        let unreachable = NibError(.notFound, "the library folder “\(location.name)” could not be opened: it may have moved, or its provider signed out",
                                   hint: "choose it again with library.chooseFolder")
        guard !location.bookmark.isEmpty, let data = Data(base64Encoded: location.bookmark),
              let resolved = try? Bookmarks.resolve(data) else { throw unreachable }
        let access = ScopedAccess(resolved.url)
        guard LibraryFolder.isDirectory(resolved.url) else {
            access.end()
            throw unreachable
        }
        return Opened(url: resolved.url, access: access, freshBookmark: resolved.stale ? try? Bookmarks.make(resolved.url) : nil)
    }

    /// Whether the folder opens and still holds a Nib library.
    static func reachable(_ location: KnownLocation) -> Bool {
        guard let opened = try? open(location) else { return false }
        defer { opened.access?.end() }
        return LibraryFolder.isLibrary(opened.url)
    }

    /// The library to reopen when the saved folder failed at launch: the folder that was the library last (the most
    /// recently used one overall), when it is outside the app and still opens. Never an older library: that would
    /// silently show other notes.
    static func reopenable(_ settings: SettingsStore) -> [KnownLocation] {
        guard let last = all(settings).first, !last.inApp, reachable(last) else { return [] }
        return [last]
    }

    /// Every known folder plus the current one (listed even before it is remembered), current first.
    @MainActor
    static func listed(_ settings: SettingsStore, library: LibraryService?) -> [KnownLocation] {
        var list = all(settings)
        if let root = library?.rootURL, !list.contains(where: { matches($0, root) }) {
            list.insert(entry(for: root, bookmark: nil, existing: [], now: SyncCommands.now), at: 0)
        }
        if let root = library?.rootURL, let i = list.firstIndex(where: { matches($0, root) }), i > 0 {
            list.insert(list.remove(at: i), at: 0)
        }
        return list
    }
}

/// A library folder as commands report it.
struct LocationInfo: Codable, Equatable {
    var id: String
    var name: String
    var path: String
    /// "app" (inside Nib), "icloud" (iCloud Drive) or "files" (On My iPad or another Files provider).
    var provider: String
    var current: Bool
    var available: Bool
    var isLibrary: Bool
    var inApp: Bool
    var lastUsed: Double?
}

// MARK: - sync.now

struct SyncNow: NibCommand {
    struct Params: Codable {}
    typealias Output = SyncReport

    static let descriptor = CommandDescriptor(
        id: "sync.now", title: String(localized: "Sync Now"),
        summary: "Check the library folder for changes other devices wrote now → {checked, changed, merged, refreshed, downloading, futureRevisions, errors}.",
        params: .empty, examples: [[:]], effect: .session, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> SyncReport {
        guard let watcher = SyncCommands.watcher(ctx) else { throw NibError.unavailable("folder sync") }
        return await watcher.check(full: true, reconcile: true)
    }
}

// MARK: - library.locations

struct LibraryLocationsList: NibCommand {
    struct Params: Codable {}
    struct Output: Codable, Equatable {
        /// Id of the library in use.
        var current: String?
        var locations: [LocationInfo]
    }

    static let descriptor = CommandDescriptor(
        id: "library.locations", title: String(localized: "Library Folders"),
        summary: "Library folders known on this device, the current one first → {current, locations: [{id, name, path, provider, current, available, isLibrary, inApp}]}.",
        params: .empty, examples: [[:]], effect: .read, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = ctx.services.library
        let root = library?.rootURL
        var out = Output(current: nil, locations: [])
        for location in KnownLocations.listed(ctx.services.settings, library: library) {
            let isCurrent = root.map { KnownLocations.matches(location, $0) } ?? false
            var available = false
            var isLibrary = false
            var provider = location.inApp ? "app" : "files"
            if isCurrent, let root = root {
                available = LibraryFolder.isDirectory(root)
                isLibrary = LibraryFolder.isLibrary(root)
                provider = LibraryFolder.provider(root)
            } else if let opened = try? KnownLocations.open(location) {
                available = true
                isLibrary = LibraryFolder.isLibrary(opened.url)
                provider = LibraryFolder.provider(opened.url)
                opened.access?.end()
            }
            if isCurrent { out.current = location.id }
            out.locations.append(LocationInfo(id: location.id, name: location.name, path: location.path, provider: provider,
                                              current: isCurrent, available: available, isLibrary: isLibrary,
                                              inApp: location.inApp, lastUsed: location.lastUsed))
        }
        return out
    }
}

// MARK: - library.switch

struct LibrarySwitch: NibCommand {
    struct Params: Codable { var location: String }
    struct Output: Codable, Equatable {
        var location: String
        var name: String
        var path: String
        var provider: String
        /// false when it already was the library.
        var switched: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "library.switch", title: String(localized: "Switch Library"),
        summary: "Switch to a known library folder by its id from library.locations (\"app\" = the folder inside Nib); open documents close first.",
        params: .obj(["location": .str("a location id from library.locations; \"app\" is the folder inside Nib")],
                     required: ["location"]),
        examples: [["location": "app"]], effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try SyncCommands.library(ctx)
        let settings = ctx.services.settings
        let known = KnownLocations.all(settings)
        var target = known.first { $0.id == p.location }
        if target == nil, p.location == KnownLocations.appID, let docs = LibraryFolder.appDocuments {
            target = KnownLocations.entry(for: docs, bookmark: nil, existing: known, now: SyncCommands.now)
        }
        guard let location = target else {
            throw NibError(.notFound, "no known library folder '\(p.location)'", path: "$.location",
                           hint: "call library.locations for the ids, or library.chooseFolder to pick a folder")
        }
        let current = library.rootURL
        // The library already is there (a folder that moved while Nib ran is reopened where its bookmark finds it).
        if KnownLocations.matches(location, current) && LibraryFolder.isDirectory(current) {
            return Output(location: location.id, name: location.name, path: location.path,
                          provider: LibraryFolder.provider(current), switched: false)
        }
        let opened = try KnownLocations.open(location)
        defer { opened.access?.end() }
        guard LibraryFolder.isLibrary(opened.url) || location.inApp else {
            throw NibError(.notFound, "“\(location.name)” no longer holds a Nib library",
                           hint: "choose the library's folder with library.chooseFolder")
        }
        // The folder being left is remembered with a bookmark made while it is still open.
        let leaving = KnownLocations.entry(for: current, bookmark: LibraryFolder.isAppDocuments(current) ? nil : try? Bookmarks.make(current),
                                           existing: known, now: SyncCommands.now)
        try library.setRoot(opened.url)
        let now = SyncCommands.now
        var left = leaving
        left.lastUsed = now
        if left.id != location.id { KnownLocations.save(left, settings) }
        var arrived = location
        arrived.lastUsed = now + 0.001
        arrived.path = LibraryFolder.canonicalPath(opened.url)
        if let fresh = opened.freshBookmark { arrived.bookmark = fresh.base64EncodedString() }
        KnownLocations.save(arrived, settings)
        return Output(location: arrived.id, name: arrived.name, path: arrived.path,
                      provider: LibraryFolder.provider(opened.url), switched: true)
    }
}

// MARK: - library.chooseFolder

struct LibraryChooseFolder: NibCommand {
    struct Params: Codable {}
    struct Output: Codable, Equatable {
        var location: String
        var name: String
        var path: String
        var provider: String
        /// The folder already held a Nib library (recognised by its .nib-library marker); false = a new, empty library.
        var existing: Bool
        /// false when the folder already was the library.
        var switched: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "library.chooseFolder", title: String(localized: "Choose Library Folder"),
        summary: "Pick a folder (iCloud Drive, OneDrive, Dropbox, On My iPad…) as the library; a folder holding a Nib library opens as that library.",
        params: .empty, examples: [[:]], effect: .library, target: .library, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try SyncCommands.library(ctx)
        let settings = ctx.services.settings
        let picked = try await PickerHost.pickFolder(ctx, startingAt: nil)
        let access = ScopedAccess(picked)
        defer { access.end() }
        let current = library.rootURL
        let known = KnownLocations.all(settings)
        let chosen = try validate(picked, current: current)
        let bookmark: Data?
        if LibraryFolder.isAppDocuments(picked) {
            bookmark = nil
        } else {
            do {
                bookmark = try Bookmarks.make(picked)
            } catch {
                throw NibError(.unavailable, "Nib cannot remember the folder “\(picked.lastPathComponent)” (\(error.localizedDescription))",
                               hint: "choose another folder")
            }
        }
        if LibraryFolder.samePlace(picked, current) {
            var entry = KnownLocations.entry(for: picked, bookmark: bookmark, existing: known, now: SyncCommands.now)
            entry.lastUsed = SyncCommands.now
            KnownLocations.save(entry, settings)
            return Output(location: entry.id, name: entry.name, path: entry.path, provider: LibraryFolder.provider(picked),
                          existing: true, switched: false)
        }
        let leaving = KnownLocations.entry(for: current, bookmark: LibraryFolder.isAppDocuments(current) ? nil : try? Bookmarks.make(current),
                                           existing: known, now: SyncCommands.now)
        try library.setRoot(picked)
        let now = SyncCommands.now
        var left = leaving
        left.lastUsed = now
        KnownLocations.save(left, settings)
        var entry = KnownLocations.entry(for: picked, bookmark: bookmark, existing: known.filter { $0.id != left.id }, now: now)
        entry.lastUsed = now + 0.001
        KnownLocations.save(entry, settings)
        return Output(location: entry.id, name: entry.name, path: entry.path, provider: LibraryFolder.provider(picked),
                      existing: chosen, switched: true)
    }

    /// Checks a picked folder; returns whether it already holds a Nib library.
    static func validate(_ picked: URL, current: URL) throws -> Bool {
        guard LibraryFolder.isDirectory(picked) else {
            throw NibError(.notFound, "the folder “\(picked.lastPathComponent)” is not reachable", hint: "choose another folder")
        }
        if LibraryFolder.samePlace(picked, current) { return true }
        if LibraryFolder.isInside(picked, current) {
            throw NibError(.invalidParams, "“\(picked.lastPathComponent)” is a folder inside the current library",
                           hint: "choose a folder outside the library, or move documents with library.move")
        }
        let isLibrary = LibraryFolder.isLibrary(picked)
        if !isLibrary, let child = LibraryFolder.childLibraries(picked).first {
            throw NibError(.invalidParams, "“\(picked.lastPathComponent)” is not a Nib library, but “\(child)” inside it is: choose “\(child)” itself",
                           hint: "call library.chooseFolder again and pick “\(child)”")
        }
        return isLibrary
    }
}

// MARK: - library.relocate

struct LibraryRelocate: NibCommand {
    struct Params: Codable { var copy: Bool }
    struct Output: Codable, Equatable {
        var location: String
        var name: String
        var path: String
        var provider: String
        var files: Int
        var bytes: Int64
        /// The old folder's library was removed after the copy was verified (`copy: false`).
        var removedOriginal: Bool
    }

    static let log = Logger(subsystem: "app.nib", category: "sync")

    static let descriptor = CommandDescriptor(
        id: "library.relocate", title: String(localized: "Move Library"),
        summary: "Copy the library into an empty folder the user picks (e.g. On My iPad → iCloud Drive) and switch to it; copy: false then removes the old one.",
        params: .obj(["copy": .bool("true keeps the old folder's library; false removes it once the copy is verified (refused when other devices use the library)")],
                     required: ["copy"]),
        examples: [["copy": true]], effect: .library, target: .library, destructive: true, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let library = try SyncCommands.library(ctx)
        let settings = ctx.services.settings
        let watcher = SyncCommands.watcher(ctx)
        let device = ctx.workspace.clock.deviceHex
        let source = library.rootURL
        if !p.copy {
            let others = await Task.detached(priority: .userInitiated) { LibraryFolder.otherDevices(in: source, device: device) }.value
            guard others.isEmpty else {
                throw NibError(.invalidParams, "other devices use this library, so it can only be copied: moving it would remove it from them",
                               path: "$.copy", hint: "call library.relocate with copy: true")
            }
        }
        let picked = try await PickerHost.pickFolder(ctx, startingAt: nil)
        let pickedAccess = ScopedAccess(picked)
        defer { pickedAccess.end() }
        try validate(picked, source: source)

        // The old folder stays reachable through the whole move: the library stops its own access when it switches.
        let sourceBookmark = LibraryFolder.isAppDocuments(source) ? nil : try? Bookmarks.make(source)
        let sourceAccess = sourceBookmark.flatMap { try? Bookmarks.resolve($0).url }.map { ScopedAccess($0) }
        defer { sourceAccess?.end() }
        let from = sourceAccess?.url ?? source
        let destinationBookmark: Data?
        if LibraryFolder.isAppDocuments(picked) {
            destinationBookmark = nil
        } else {
            do {
                destinationBookmark = try Bookmarks.make(picked)
            } catch {
                throw NibError(.unavailable, "Nib cannot remember the folder “\(picked.lastPathComponent)” (\(error.localizedDescription))",
                               hint: "choose another folder")
            }
        }

        // Everything open reaches the disk before it is copied.
        for doc in ctx.workspace.loadedDocuments { ctx.workspace.persistence.flush(doc) }
        watcher?.setStatus(nil, state: "checking", reason: "relocating",
                           message: String(localized: "Preparing to copy the library…"))
        let items = LibraryCopier.topLevelItems(of: from)
        let missing = await Task.detached(priority: .userInitiated) { await LibraryCopier.download(items, timeout: 120) }.value
        guard missing.isEmpty else {
            let e = NibError(.unavailable, "\(missing.count) items of the library are still downloading from iCloud",
                             hint: "try again once they have downloaded")
            watcher?.setStatus(nil, state: "error", reason: "relocateFailed", message: e.message)
            throw e
        }
        let outcome: LibraryCopier.Outcome
        do {
            outcome = try await Task.detached(priority: .userInitiated) {
                try LibraryCopier.copy(items, to: picked) { index, count, name in
                    FolderWatcher.onMain {
                        guard index < count else { return }
                        watcher?.setStatus(nil, state: "checking", reason: "relocating",
                                           message: String(localized: "Copying “\(name)” (\(index + 1) of \(count))…"))
                    }
                }
            }.value
        } catch {
            let e = NibError.wrap(error)
            watcher?.setStatus(nil, state: "error", reason: "relocateFailed", message: e.message)
            throw e
        }
        let created = outcome.items.map { picked.appendingPathComponent($0) }
        let problems = await Task.detached(priority: .userInitiated) {
            LibraryCopier.verify(outcome.items, source: from, destination: picked)
        }.value
        guard problems.isEmpty else {
            LibraryCopier.remove(created)
            log.error("library copy differs in \(problems.count) files")
            let e = NibError(.internalError, "the copy is incomplete: \(problems.count) files differ from the library",
                             hint: "try again; the old library is unchanged")
            watcher?.setStatus(nil, state: "error", reason: "relocateFailed", message: e.message, files: Array(problems.prefix(20)))
            throw e
        }

        let known = KnownLocations.all(settings)
        let leaving = KnownLocations.entry(for: source, bookmark: sourceBookmark, existing: known, now: SyncCommands.now)
        do {
            try library.setRoot(picked)
        } catch {
            LibraryCopier.remove(created)
            let e = NibError.wrap(error)
            watcher?.setStatus(nil, state: "error", reason: "relocateFailed", message: e.message)
            throw e
        }
        // Synced settings still waiting to be written went to the old folder while the library switched: bring them.
        carryPrefs(from: from, to: picked)
        library.refresh()

        var removed = false
        let now = SyncCommands.now
        if p.copy {
            var left = leaving
            left.lastUsed = now
            KnownLocations.save(left, settings)
        } else {
            let failed = LibraryCopier.remove(items)
            removed = failed.isEmpty
            if removed {
                KnownLocations.remove(leaving.id, settings)
            } else {
                var left = leaving
                left.lastUsed = now
                KnownLocations.save(left, settings)
                log.error("\(failed.count) items of the old library could not be removed")
            }
        }
        var entry = KnownLocations.entry(for: picked, bookmark: destinationBookmark,
                                         existing: known.filter { $0.id != leaving.id }, now: now)
        entry.lastUsed = now + 0.001
        KnownLocations.save(entry, settings)
        watcher?.setStatus(nil, state: "idle")
        return Output(location: entry.id, name: entry.name, path: entry.path, provider: LibraryFolder.provider(picked),
                      files: outcome.files, bytes: outcome.bytes, removedOriginal: removed)
    }

    /// The destination must be a reachable, empty folder that is neither the library, inside it, around it, nor
    /// another Nib library.
    static func validate(_ picked: URL, source: URL) throws {
        guard LibraryFolder.isDirectory(picked) else {
            throw NibError(.notFound, "the folder “\(picked.lastPathComponent)” is not reachable", hint: "choose another folder")
        }
        if LibraryFolder.samePlace(picked, source) {
            throw NibError(.invalidParams, "“\(picked.lastPathComponent)” already is the library's folder", hint: "choose another, empty folder")
        }
        if LibraryFolder.isInside(picked, source) || LibraryFolder.isInside(source, picked) {
            throw NibError(.invalidParams, "“\(picked.lastPathComponent)” is inside the library or holds it",
                           hint: "choose an empty folder outside the library")
        }
        if LibraryFolder.isLibrary(picked) {
            throw NibError(.invalidParams, "“\(picked.lastPathComponent)” already holds a Nib library",
                           hint: "switch to it with library.chooseFolder, or choose an empty folder")
        }
        if !LibraryFolder.visibleEntries(picked).isEmpty {
            throw NibError(.invalidParams, "“\(picked.lastPathComponent)” is not empty",
                           hint: "choose an empty folder (New Folder in the picker makes one)")
        }
    }

    /// Copies the old folder's synced prefs files over the new folder's (coordinated), so preferences changed while
    /// the library switched are not lost.
    static func carryPrefs(from source: URL, to destination: URL) {
        let fm = FileManager.default
        let old = source.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        let new = destination.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where SyncFiles.isPrefs(name) {
            let a = old.appendingPathComponent(name), b = new.appendingPathComponent(name)
            guard (try? Data(contentsOf: a)) != (try? Data(contentsOf: b)) else { continue }
            do {
                try LibraryCopier.replace(b, with: a)
            } catch {
                log.error("could not carry \(name, privacy: .public) over: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
