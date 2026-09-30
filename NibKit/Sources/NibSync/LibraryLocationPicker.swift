import Foundation
import UIKit
import UniformTypeIdentifiers
import os
import NibContracts

// MARK: - Folder picker

/// The system folder picker (`UIDocumentPickerViewController` in folder mode, opened in place): the user picks a
/// folder on the device, in iCloud Drive or in any Files provider (OneDrive, Dropbox, Google Drive, Box…), and can
/// create one with New Folder. The URL it returns is security-scoped.
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    enum Outcome: Equatable {
        case picked(URL)
        case cancelled
        /// The picker could not be presented (another presentation was in progress, the window went away).
        case notShown
    }

    /// Keeps the delegate alive while the picker is up (the picker holds its delegate weakly).
    private static var active: FolderPicker?
    private var continuation: CheckedContinuation<Outcome, Never>?

    static func pick(on navigator: SceneNavigator, startingAt directory: URL?) async -> Outcome {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        if let directory = directory { picker.directoryURL = directory }
        let delegate = FolderPicker()
        picker.delegate = delegate
        active = delegate
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            delegate.continuation = continuation
            navigator.presentModal(picker)
            // The shell presents synchronously; nothing on screen means the presentation was refused.
            if picker.presentingViewController == nil { delegate.finish(.notShown) }
        }
        active = nil
        return outcome
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first.map { .picked($0) } ?? .cancelled)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// The window that shows the picker: the one the user works in (`ctx.navigator`), waiting briefly while a window
/// comes up at launch. nil in hostless tests (no UIKit window) and when no window appears.
@MainActor
enum PickerHost {
    static func navigator(_ app: NibApp?, waitingUpTo seconds: Double = 4) async -> SceneNavigator? {
        guard !NibApp.isHostlessTest, let app = app else { return nil }
        let rounds = max(1, Int(seconds * 10))
        for _ in 0..<rounds {
            if let nav = app.ui.activeNavigator, nav.rootViewController?.view.window != nil { return nav }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// Shows the folder picker and returns the chosen folder, or throws `user_denied` (cancelled) / `unavailable`.
    static func pickFolder(_ ctx: CommandContext, startingAt directory: URL?) async throws -> URL {
        guard let navigator = await navigator(ctx.app) else {
            throw NibError(.unavailable, "there is no window to show the folder picker in",
                           hint: "run this from the app while it is in the foreground")
        }
        switch await FolderPicker.pick(on: navigator, startingAt: directory) {
        case .picked(let url): return url
        case .cancelled: throw NibError(.userDenied, "no folder was chosen")
        case .notShown:
            throw NibError(.unavailable, "the folder picker could not be shown", hint: "close other sheets and try again")
        }
    }
}

// MARK: - Security scope and bookmarks

/// One `startAccessingSecurityScopedResource` on a URL object, balanced by exactly one stop (`end()` or deinit).
final class ScopedAccess {
    let url: URL
    private var active: Bool

    init(_ url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    func end() {
        guard active else { return }
        url.stopAccessingSecurityScopedResource()
        active = false
    }

    deinit { end() }
}

/// Folder bookmarks as iOS supports them: `bookmarkData(options: [])` and `URL(resolvingBookmarkData:options: [])`
/// (`.withSecurityScope` does not exist on iOS; a bookmark made from a security-scoped URL keeps its access).
enum Bookmarks {
    static func make(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder a bookmark points at (not yet accessed) and whether the bookmark should be renewed.
    static func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

// MARK: - Library folders

/// What a folder is to Nib. A library is recognised by its `.nib-library` marker folder, so a folder picked again after
/// a reinstall or a re-signed build (its bookmark gone or stale) opens as the same library.
enum LibraryFolder {
    static func isLibrary(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let marker = url.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        return FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Names of the folders directly inside `url` that are Nib libraries themselves.
    static func childLibraries(_ url: URL) -> [String] {
        visibleEntries(url).filter { name in
            let child = url.appendingPathComponent(name, isDirectory: true)
            return isDirectory(child) && !SyncFiles.isPackageExtension(child.pathExtension) && isLibrary(child)
        }.sorted()
    }

    /// Names of the items in `url` that people see in Files (hidden items such as `.DS_Store` are left out).
    static func visibleEntries(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Device ids (8 hex) other than `device` that wrote into the library: its prefs files and document heads.
    static func otherDevices(in root: URL, device: String) -> Set<String> {
        var out = Set<String>()
        func note(_ name: String, prefix: String) {
            let real = SyncFiles.placeholderTarget(name) ?? name
            if let d = SyncFiles.device(of: real, prefix: prefix, suffix: SyncFiles.jsonSuffix), d.hex != device {
                out.insert(d.hex)
            }
        }
        let fm = FileManager.default
        let metadata = root.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: metadata.path)) ?? [] { note(name, prefix: SyncFiles.prefsPrefix) }
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return out }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if SyncFiles.isPackageExtension(url.pathExtension), isDirectory(url) {
                for head in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] { note(head, prefix: SyncFiles.headPrefix) }
                walker.skipDescendants()
            } else if name.hasPrefix(".") {
                note(name, prefix: SyncFiles.folderPrefix)
            }
        }
        return out
    }

    /// A path for comparisons: symlinks resolved (/var ↔ /private/var), standardized, no trailing slash.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func samePlace(_ a: URL, _ b: URL) -> Bool { canonicalPath(a) == canonicalPath(b) }

    /// `child` lies strictly inside `parent`.
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = canonicalPath(child), p = canonicalPath(parent)
        return c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// The app's own Documents folder ("On My iPad › Nib"): the default library, deleted with the app.
    static var appDocuments: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func isAppDocuments(_ url: URL) -> Bool {
        guard let docs = appDocuments else { return false }
        return samePlace(url, docs)
    }

    /// Where the folder lives: "app" (inside Nib), "icloud" (iCloud Drive) or "files" (On My iPad / iPhone or another
    /// Files provider).
    static func provider(_ url: URL) -> String {
        if isAppDocuments(url) || isInside(url, URL(fileURLWithPath: NSHomeDirectory())) { return "app" }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        if values?.isUbiquitousItem == true || url.path.contains("/Mobile Documents/") { return "icloud" }
        return "files"
    }

    static func displayName(_ url: URL) -> String {
        if isAppDocuments(url) { return String(localized: "Nib (inside the app)") }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.lastPathComponent : name
    }
}

// MARK: - Copying a library

/// Copies a library folder to another folder with `NSFileCoordinator` (coordinated reads of the source, coordinated
/// replacing writes of the destination), after asking iCloud for every evicted item, then verifies the copy file by
/// file. Runs off the main actor.
enum LibraryCopier {
    struct Outcome: Equatable {
        var files = 0
        var bytes: Int64 = 0
        /// Top-level item names copied.
        var items: [String] = []
    }

    static let log = Logger(subsystem: "app.nib", category: "sync")

    /// The top-level items that make up the library at `root`: folders, packages, loose files and `.nib-library`
    /// (not Finder/Files litter, not iOS's Inbox of the app's Documents folder).
    static func topLevelItems(of root: URL) -> [URL] {
        let skipInbox = LibraryFolder.isAppDocuments(root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { name in
            if name == ".DS_Store" || name == ".Trash" { return false }
            if skipInbox && name == SyncFiles.inboxName { return false }
            return true
        }.sorted().map { root.appendingPathComponent($0) }
    }

    /// Evicted items below `items` (placeholders and dataless files), each asked to download. Empty = all local.
    static func evicted(in items: [URL]) -> [URL] {
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func visit(_ url: URL) {
            let name = url.lastPathComponent
            if let real = SyncFiles.placeholderTarget(name) {
                let target = url.deletingLastPathComponent().appendingPathComponent(real)
                try? FileManager.default.startDownloadingUbiquitousItem(at: target)
                out.append(target)
                return
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                             options: [])) ?? []
                children.forEach(visit)
            } else if DownloadState(values) == .evicted {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                out.append(url)
            }
        }
        items.forEach(visit)
        return out
    }

    /// Asks for every evicted item and waits up to `timeout` seconds; returns what is still missing.
    static func download(_ items: [URL], timeout: TimeInterval) async -> [URL] {
        var missing = evicted(in: items)
        let deadline = Date().addingTimeInterval(timeout)
        while !missing.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            missing = evicted(in: items)
        }
        return missing
    }

    /// Copies each item into `destination` (same name), coordinated. On failure, what was created is removed again.
    static func copy(_ items: [URL], to destination: URL, progress: (Int, Int, String) -> Void) throws -> Outcome {
        var outcome = Outcome()
        var created: [URL] = []
        let fm = FileManager.default
        for (index, source) in items.enumerated() {
            let name = source.lastPathComponent
            progress(index, items.count, name)
            let target = destination.appendingPathComponent(name)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], writingItemAt: target,
                                                             options: .forReplacing, error: &coordinationError) { from, to in
                do {
                    if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                    try fm.copyItem(at: from, to: to)
                } catch {
                    copyError = error
                }
            }
            if let e = coordinationError ?? copyError {
                log.error("copying \(name, privacy: .private) failed: \(e.localizedDescription, privacy: .public)")
                _ = remove(created)
                throw NibError(.internalError, "“\(name)” could not be copied: \(e.localizedDescription)",
                               hint: "check that the destination has enough space, then try again")
            }
            created.append(target)
            outcome.items.append(name)
            let files = inventory(target)
            outcome.files += files.values.filter { $0 >= 0 }.count
            outcome.bytes += files.values.filter { $0 > 0 }.reduce(Int64(0)) { $0 + Int64($1) }
        }
        progress(items.count, items.count, "")
        return outcome
    }

    /// Relative paths (below each item) that differ between source and destination: missing, or another size.
    static func verify(_ names: [String], source: URL, destination: URL) -> [String] {
        var problems: [String] = []
        for name in names {
            let from = inventory(source.appendingPathComponent(name))
            let to = inventory(destination.appendingPathComponent(name))
            for (path, size) in from where to[path] != size { problems.append(SyncFiles.join(name, path)) }
        }
        return problems.sorted()
    }

    /// Regular files (size) and directories (-1) at and below `url`, by path relative to it ("" = `url` itself).
    static func inventory(_ url: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let rootValues = try? url.resourceValues(forKeys: Set(keys))
        guard rootValues != nil else { return out }
        guard rootValues?.isDirectory == true else {
            out[""] = rootValues?.fileSize ?? 0
            return out
        }
        out[""] = -1
        let base = url.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return out
        }
        for case let item as URL in walker {
            let full = item.standardizedFileURL.path
            let rel = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))
            out[rel] = values?.isDirectory == true ? -1 : (values?.fileSize ?? 0)
        }
        return out
    }

    /// Coordinated deletes; returns the names that could not be removed.
    @discardableResult
    static func remove(_ urls: [URL]) -> [String] {
        var failed: [String] = []
        for url in urls {
            var coordinationError: NSError?
            var removeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                             error: &coordinationError) { target in
                do {
                    try FileManager.default.removeItem(at: target)
                } catch {
                    removeError = error
                }
            }
            if let e = coordinationError ?? removeError {
                log.error("removing \(url.lastPathComponent, privacy: .private) failed: \(e.localizedDescription, privacy: .public)")
                failed.append(url.lastPathComponent)
            }
        }
        return failed
    }

    /// Copies one file over another, coordinated (the synced prefs written while the library switched folders).
    static func replace(_ destination: URL, with source: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        let fm = FileManager.default
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], writingItemAt: destination,
                                                         options: .forReplacing, error: &coordinationError) { from, to in
            do {
                let data = try Data(contentsOf: from)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: to, options: .atomic)
            } catch {
                copyError = error
            }
        }
        if let e = coordinationError ?? copyError { throw e }
    }
}

// MARK: - Launch recovery

/// A saved library folder that no longer opens (a re-signed build, the folder moved, the provider signed out) makes the
/// Library Store fall back to the app's Documents folder and report `rootUnavailable`. Recovery first switches to a
/// remembered library folder that still opens; otherwise it asks the user to choose the folder again with a system
/// alert. The folder picked is recognised as the same library by its `.nib-library` marker (`library.chooseFolder`).
@MainActor
enum LibraryRecovery {
    private static let log = Logger(subsystem: "app.nib", category: "sync")

    /// Whether the Library Store reported at launch that the saved folder could not be opened.
    static func libraryUnavailable(_ app: NibApp) -> Bool {
        app.events.events(since: 0, limit: app.events.capacity).contains { e in
            guard let p = e.decode(SyncStatusPayload.self) else { return false }
            return p.source == "library" && p.reason == "rootUnavailable"
        }
    }

    static func begin(_ app: NibApp) {
        guard libraryUnavailable(app) else { return }
        Task { @MainActor in await recover(app) }
    }

    static func recover(_ app: NibApp) async {
        for location in KnownLocations.reopenable(app.settings) {
            do {
                try await app.bus.execute(CommandIDs.librarySwitch, ["location": .string(location.id)])
                log.info("switched back to the library folder \(location.name, privacy: .private)")
                return
            } catch {
                log.error("could not reopen \(location.name, privacy: .private): \(NibError.wrap(error).message, privacy: .public)")
            }
        }
        let message = String(localized: "Nib can't open your library folder. Choose it again: Nib recognises it by its hidden .nib-library folder.")
        if let watcher = app.services.get(FolderWatcher.serviceKey, as: FolderWatcher.self) {
            watcher.setStatus(nil, state: "error", reason: "libraryUnavailable", message: message)
        } else {
            app.events.emit(SyncStatusPayload(state: "error", source: FolderWatcher.source, reason: "libraryUnavailable",
                                              message: message))
        }
        guard let navigator = await PickerHost.navigator(app, waitingUpTo: 20) else { return }
        let alert = UIAlertController(
            title: String(localized: "Choose Your Library Folder"),
            message: String(localized: "Nib can't open the folder your notes are in. It may have moved, or Nib was reinstalled. Choose the folder again and everything in it comes back."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Choose Folder…"), style: .default) { [weak app] _ in
            app?.perform(CommandIDs.libraryChooseFolder)
        })
        alert.preferredAction = alert.actions.last
        navigator.presentModal(alert)
    }
}
