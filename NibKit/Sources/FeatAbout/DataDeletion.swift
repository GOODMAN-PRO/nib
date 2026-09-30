import Foundation
import SwiftUI
import UIKit
import Security
import WebKit
import CoreSpotlight
import Intents
import UserNotifications
import WidgetKit
import os
import NibContracts
import NibDesign

// "Delete all Nib data" (P-018, P-097: the right-to-erasure substitute for Goodnotes' account deletion) and the
// privacy statement (P-096, S-018). Nib has no account and no server copy, so erasure means this device:
//
// - always: every device-local setting (the defaults domains), every Keychain item (AI keys, WebDAV and relay
//   passwords, the bridge token, plugin grants), Application Support (AI provider configs, indexes), caches and
//   temporary files, plugin panels' web data, cookies and stored credentials, the shared App Group container (widget
//   and share-extension data), Spotlight items, Siri donations, handed-off activities and pending notifications, the
//   Open In inbox and Temporary Diagnostic Mode copies;
// - with `includeLibrary`: every document package, folder marker and `.nib-library` (trash, plugins, templates,
//   synced preferences, AI chats) in the library folder Nib uses, and any earlier library in Nib's own Documents
//   folder. Only what Nib made goes: other files in the folder stay, and folders are removed only when Nib's content
//   was all they held.
//
// Without `includeLibrary` the library folder and the device id's Application Support mirror stay, so the library
// keeps syncing as this device. `app.deleteAllData` itself asks the person twice (it is `userPresence`), whoever
// calls it; the gateway confirms it once more for the assistant, plugins and the bridge (`irreversible`). Afterwards a
// full-screen notice asks the person to close Nib: features still hold state in memory (a running bridge keeps its
// token), so "Close Nib" erases once more and quits, and the next launch starts fresh.

// MARK: - Command

/// `app.deleteAllData {includeLibrary?}` (`CommandIDs.appDeleteAllData`).
struct DeleteAllDataCommand: NibCommand {
    struct Params: Codable {
        var includeLibrary: Bool?
    }

    struct Output: Codable, Equatable {
        /// False for a dry run (nothing was asked or deleted).
        var deleted: Bool
        var dryRun: Bool
        var includeLibrary: Bool
        /// The library folder Nib uses (absolute path); nil without a library service.
        var libraryPath: String?
        /// Documents (trash included) that go with the library; 0 when the library is kept.
        var documents: Int
        /// What is (or would be) erased and what stays, in plain words.
        var erases: [String]
        var keeps: [String]
        /// Files, folders and settings removed.
        var removed: Int
        /// Items that could not be removed ("<name>: <reason>").
        var failures: [String]
        /// Nib must be closed and opened again to start fresh.
        var restartRequired: Bool
    }

    /// The id is spelled out (it equals `CommandIDs.appDeleteAllData`) so Scripts/lint.py sees the owned command.
    static let descriptor = CommandDescriptor(
        id: "app.deleteAllData", title: "Delete All Nib Data",
        summary: "Erase everything Nib keeps on this device (settings, caches, keys, grants); includeLibrary also deletes the library's documents. The person confirms twice.",
        params: .obj(["includeLibrary": .bool("also delete every document, folder, the trash and .nib-library in the library folder Nib uses (default false)")]),
        examples: [[:], ["includeLibrary": true]],
        effect: .irreversible, target: .app, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let service = DataDeletionService.resolve(ctx.services) else {
            throw NibError.unavailable("Data deletion")
        }
        return try await service.run(includeLibrary: p.includeLibrary ?? false, ctx)
    }
}

// MARK: - Service

/// Everything `app.deleteAllData` touches outside the command, behind one object so tests swap in a temporary
/// container, a recording system wiper and scripted confirmations (`services.set(_:for: DataDeletionService.key)`).
@MainActor
final class DataDeletionService {
    static let key = AboutIDs.deletionService

    let locations: () -> AppDataLocations
    let fileManager: FileManager
    /// Library items are removed under `NSFileCoordinator` so Files providers (iCloud Drive, OneDrive…) sync it.
    let coordinatesFiles: Bool
    let system: SystemDataWiping
    /// nil when no person can answer (no window, hostless tests): the command is then `unavailable`.
    let makePrompter: @MainActor (CommandContext) -> DeletionPrompting?
    let terminate: @MainActor () -> Void
    let deviceModel: String

    init(locations: @escaping () -> AppDataLocations, fileManager: FileManager = .default, coordinatesFiles: Bool = true,
         system: SystemDataWiping, deviceModel: String,
         makePrompter: @escaping @MainActor (CommandContext) -> DeletionPrompting?,
         terminate: @escaping @MainActor () -> Void) {
        self.locations = locations
        self.fileManager = fileManager
        self.coordinatesFiles = coordinatesFiles
        self.system = system
        self.deviceModel = deviceModel
        self.makePrompter = makePrompter
        self.terminate = terminate
    }

    /// The app's own service: the real container, Keychain and system stores, alerts in the active window.
    static func live() -> DataDeletionService {
        DataDeletionService(
            locations: { AppDataLocations.current() }, system: SystemDataWiper(),
            deviceModel: UIDevice.current.localizedModel,
            makePrompter: { ctx in
                guard !NibApp.isHostlessTest, let navigator = ctx.navigator else { return nil }
                return AlertDeletionPrompter(navigator: navigator)
            },
            terminate: {
                AboutLog.logger.notice("closing Nib after deleting all data")
                exit(0)
            })
    }

    static func resolve(_ services: NibServices) -> DataDeletionService? {
        services.get(key, as: DataDeletionService.self)
    }

    /// What the confirmations describe: the library's place and how many documents it holds (trash included).
    func describe(includeLibrary: Bool, library: LibraryService?) -> DeletionSubject {
        let place = locations()
        let documents = (library.map { $0.allNodes() + $0.trashedNodes() } ?? []).filter { $0.kind == .document }
        return DeletionSubject(
            includeLibrary: includeLibrary, documents: documents.count,
            lockedDocuments: documents.filter { $0.locked }.count,
            libraryName: library.map { LibraryPathFormatter.display($0.rootURL, documents: place.documents,
                                                                    deviceModel: deviceModel) },
            libraryInApp: library.map { AboutPaths.contains(place.container, $0.rootURL) } ?? true,
            deviceModel: deviceModel)
    }

    func run(includeLibrary: Bool, _ ctx: CommandContext) async throws -> DeleteAllDataCommand.Output {
        let library = ctx.services.library
        let place = locations()
        let plan = DeletionPlanner.plan(includeLibrary: includeLibrary, libraryRoot: library?.rootURL, locations: place)
        let subject = describe(includeLibrary: includeLibrary, library: library)
        var output = DeleteAllDataCommand.Output(
            deleted: false, dryRun: ctx.dryRun, includeLibrary: includeLibrary, libraryPath: library?.rootURL.path,
            documents: includeLibrary ? subject.documents : 0, erases: DeletionCopy.erases(includeLibrary: includeLibrary),
            keeps: DeletionCopy.keeps(includeLibrary: includeLibrary), removed: 0, failures: [], restartRequired: false)
        if ctx.dryRun { return output }

        guard let prompter = makePrompter(ctx) else {
            throw NibError(.unavailable, "deleting all Nib data needs a person at an open Nib window",
                           hint: "open Nib on the device and ask again, or use Settings > About > Privacy & Data there")
        }
        for prompt in DeletionCopy.prompts(subject) {
            switch await prompter.confirm(prompt) {
            case .confirmed:
                continue
            case .declined:
                throw NibError(.userDenied, "the person chose to keep their Nib data")
            case .notShown:
                throw NibError(.unavailable, "the confirmation could not be shown, so nothing was deleted",
                               hint: "bring Nib to the front on the device and ask again")
            }
        }
        AboutLog.logger.notice("deleting all Nib data (library: \(includeLibrary ? "yes" : "no", privacy: .public))")

        if includeLibrary { await leaveDocuments(ctx) }
        let settingsRemoved = DeviceSettingsEraser.clear(ctx.services.settings)
        let report = await erase(plan)
        let systemFailures = await system.wipe(appGroupIDs: place.appGroupIDs)
        library?.refresh()

        output.deleted = true
        output.removed = report.removed + settingsRemoved
        output.failures = report.failures + systemFailures
        output.restartRequired = true
        let finish = DeletionFinish(subject: subject, failures: output.failures.count)
        prompter.showFinished(finish) { [weak self] in
            await self?.finalPass(plan, appGroupIDs: place.appGroupIDs)
        }
        return output
    }

    /// File I/O runs off the main actor (Files providers can take a while, and coordination must not block main).
    func erase(_ plan: DeletionPlan) async -> DeletionReport {
        let eraser = DataEraser(fileManager: fileManager, coordinatesFiles: coordinatesFiles)
        return await Task.detached(priority: .userInitiated) { eraser.erase(plan) }.value
    }

    /// "Close Nib": whatever running features wrote since the first pass goes too, then Nib quits.
    func finalPass(_ plan: DeletionPlan, appGroupIDs: [String]) async {
        _ = await erase(plan)
        _ = await system.wipe(appGroupIDs: appGroupIDs)
        terminate()
    }

    /// With the library going, windows go back to the library and documents leave memory first, so nothing saves a
    /// page back into a deleted package.
    private func leaveDocuments(_ ctx: CommandContext) async {
        if ctx.activeSession?.document != nil {
            _ = try? await ctx.execute(CommandIDs.windowShowLibrary)
        }
        for doc in ctx.workspace.loadedDocuments {
            ctx.workspace.close(doc)
        }
    }
}

enum AboutLog {
    static let logger = Logger(subsystem: "app.nib", category: "about")
}

// MARK: - Locations and plan

/// The app's own storage on this device.
struct AppDataLocations: Equatable {
    /// The app container (the parent of Documents and Library).
    var container: URL
    var documents: URL
    var library: URL
    var caches: URL
    var applicationSupport: URL
    var temporary: URL
    /// App Group containers the build uses (Info.plist "ALTAppGroups" and "NibAppGroups") and their ids.
    var appGroups: [URL]
    var appGroupIDs: [String]

    /// `DeviceIdentity`'s mirror (Application Support/Nib/device-id): kept with the library so the library's
    /// per-device files stay this device's.
    var deviceIDFile: URL {
        applicationSupport.appendingPathComponent("Nib", isDirectory: true).appendingPathComponent("device-id")
    }

    static func current(fileManager: FileManager = .default, bundle: Bundle = .main) -> AppDataLocations {
        func dir(_ d: FileManager.SearchPathDirectory, _ fallback: String) -> URL {
            fileManager.urls(for: d, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(fallback, isDirectory: true)
        }
        let ids = AppGroupIDs.configured(bundle.infoDictionary ?? [:])
        let groups = ids.compactMap { fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        return AppDataLocations(
            container: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            documents: dir(.documentDirectory, "Documents"), library: dir(.libraryDirectory, "Library"),
            caches: dir(.cachesDirectory, "Library/Caches"),
            applicationSupport: dir(.applicationSupportDirectory, "Library/Application Support"),
            temporary: fileManager.temporaryDirectory, appGroups: groups, appGroupIDs: ids)
    }
}

/// The App Group ids a build may use, as `AppGroup` reads them (sideloading tools rewrite them into "ALTAppGroups").
enum AppGroupIDs {
    static func configured(_ info: [String: Any]) -> [String] {
        var seen = Set<String>()
        return (((info["ALTAppGroups"] as? [String]) ?? []) + ((info["NibAppGroups"] as? [String]) ?? []))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// What one erase pass removes.
struct DeletionPlan: Equatable {
    var includeLibrary: Bool
    /// Directories emptied (the directory itself stays), except anything in `keep`.
    var clear: [URL]
    /// Files or folders removed whole, unless kept.
    var remove: [URL]
    /// Library folders where only Nib's own content goes (packages, folder markers, `.nib-library`).
    var libraryRoots: [URL]
    /// Never removed. An ancestor of a kept path is emptied around it instead of removed.
    var keep: [URL]
    /// Entries whose failure is not reported (system-owned caches such as "com.apple.*").
    var quietPrefixes: [String] = ["com.apple."]
}

enum DeletionPlanner {
    /// Subfolders of the container's Library with web, cookie and restoration data.
    static let librarySubfolders = ["WebKit", "Cookies", "HTTPStorages", "Saved Application State"]
    /// Documents subfolders that are app data, not library: the Open In inbox and Temporary Diagnostic Mode copies.
    static let documentSubfolders = ["Inbox", "diagnostics"]

    static func plan(includeLibrary: Bool, libraryRoot: URL?, locations l: AppDataLocations) -> DeletionPlan {
        let clear = [l.caches, l.applicationSupport, l.temporary]
            + librarySubfolders.map { l.library.appendingPathComponent($0, isDirectory: true) }
            + l.appGroups
        let remove = documentSubfolders.map { l.documents.appendingPathComponent($0, isDirectory: true) }
        var keep: [URL] = []
        if let root = libraryRoot { keep.append(root) }
        if !includeLibrary { keep.append(l.deviceIDFile) }
        var roots: [URL] = []
        if includeLibrary {
            // The library Nib uses, and an earlier one in Nib's own Documents folder. A root inside another is
            // covered by the outer one.
            for candidate in [libraryRoot, l.documents].compactMap({ $0 })
            where !roots.contains(where: { AboutPaths.contains($0, candidate) }) {
                roots.removeAll { AboutPaths.contains(candidate, $0) }
                roots.append(candidate)
            }
        }
        return DeletionPlan(includeLibrary: includeLibrary, clear: clear, remove: remove, libraryRoots: roots, keep: keep)
    }
}

/// Path comparisons that survive "/private/var" vs "/var" and trailing slashes.
enum AboutPaths {
    static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// True when `inner` is `outer` or lies inside it.
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let o = canonical(outer), i = canonical(inner)
        return i == o || i.hasPrefix(o == "/" ? "/" : o + "/")
    }
}

/// Which names in a library folder Nib made (`NibFormat`): document packages, legacy `.nib` packages, folder
/// markers, `.nib-library`, and iCloud placeholders of any of them.
enum NibOwnership {
    enum Kind: Equatable {
        case owned
        /// A `.nib` folder: Nib's only when it holds `doc.*.json` (otherwise it may be Interface Builder's).
        case legacyCandidate
        case other
    }

    static func classify(name: String, isDirectory: Bool) -> Kind {
        if name == NibFormat.libraryDirectory { return .owned }
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory {
            if ext == NibFormat.packageExtension { return .owned }
            if ext == NibFormat.legacyPackageExtension { return .legacyCandidate }
            return .other
        }
        if isFolderMarker(name) { return .owned }
        if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
            let inner = String(name.dropFirst().dropLast(".icloud".count))
            if inner == NibFormat.libraryDirectory || isFolderMarker(inner)
                || (inner as NSString).pathExtension.lowercased() == NibFormat.packageExtension {
                return .owned
            }
        }
        return .other
    }

    /// `.nibfolder.<device>.json`: a library folder's identity and style.
    static func isFolderMarker(_ name: String) -> Bool {
        name.hasPrefix(".nibfolder.") && name.hasSuffix(".json")
    }

    /// `doc.<device>.json`: a document head inside a package.
    static func isDocumentFile(_ name: String) -> Bool {
        name.hasPrefix("doc.") && name.hasSuffix(".json")
    }

    /// Files that do not keep an otherwise emptied folder alive.
    static func isIgnorable(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized"
    }
}

struct DeletionReport: Equatable {
    var removed = 0
    var failures: [String] = []
}

/// Runs a plan. Holds no main-actor state: `DataDeletionService.erase` runs it on a background task.
struct DataEraser {
    let fileManager: FileManager
    let coordinatesFiles: Bool

    func erase(_ plan: DeletionPlan) -> DeletionReport {
        var report = DeletionReport()
        let keep = Set(plan.keep.map(AboutPaths.canonical))
        for dir in plan.clear {
            clearContents(of: dir, keep: keep, quiet: plan.quietPrefixes, report: &report)
        }
        for url in plan.remove where exists(url) {
            let path = AboutPaths.canonical(url)
            if keep.contains(path) { continue }
            if keep.contains(where: { $0.hasPrefix(path + "/") }) {
                clearContents(of: url, keep: keep, quiet: plan.quietPrefixes, report: &report)
            } else {
                remove(url, coordinated: false, quiet: false, report: &report)
            }
        }
        for root in plan.libraryRoots {
            removeNibContent(in: root, keep: keep, report: &report)
        }
        return report
    }

    // MARK: App data

    private func clearContents(of dir: URL, keep: Set<String>, quiet: [String], report: inout DeletionReport) {
        for child in children(of: dir) {
            let path = AboutPaths.canonical(child)
            if keep.contains(path) { continue }
            if keep.contains(where: { $0.hasPrefix(path + "/") }) {
                if isDirectory(child) { clearContents(of: child, keep: keep, quiet: quiet, report: &report) }
                continue
            }
            let name = child.lastPathComponent
            remove(child, coordinated: false, quiet: quiet.contains { name.hasPrefix($0) }, report: &report)
        }
    }

    // MARK: Library

    /// Removes Nib's content below `dir` and returns whether anything was removed; a folder emptied that way goes
    /// too (never `dir` itself when it is a root, and never a kept folder).
    @discardableResult
    private func removeNibContent(in dir: URL, keep: Set<String>, report: inout DeletionReport) -> Bool {
        var removedAny = false
        for child in children(of: dir) {
            let directory = isDirectory(child)
            if keep.contains(AboutPaths.canonical(child)) && !directory { continue }
            switch NibOwnership.classify(name: child.lastPathComponent, isDirectory: directory) {
            case .owned:
                if remove(child, coordinated: true, quiet: false, report: &report) { removedAny = true }
            case .legacyCandidate:
                if children(of: child).contains(where: { NibOwnership.isDocumentFile($0.lastPathComponent) }) {
                    if remove(child, coordinated: true, quiet: false, report: &report) { removedAny = true }
                }
            case .other:
                guard directory, removeNibContent(in: child, keep: keep, report: &report) else { continue }
                removedAny = true
                if !keep.contains(AboutPaths.canonical(child)),
                   children(of: child).allSatisfy({ NibOwnership.isIgnorable($0.lastPathComponent) }) {
                    remove(child, coordinated: true, quiet: false, report: &report)
                }
            }
        }
        return removedAny
    }

    // MARK: File system

    private func children(of dir: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                              options: [])) ?? []
    }

    /// A real directory: a symbolic link is never followed (it is removed as a link, never walked into).
    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    @discardableResult
    private func remove(_ url: URL, coordinated: Bool, quiet: Bool, report: inout DeletionReport) -> Bool {
        var failure: Error?
        if coordinated && coordinatesFiles {
            var coordination: NSError?
            let fm = fileManager
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                             error: &coordination) { actual in
                do { try fm.removeItem(at: actual) } catch { failure = error }
            }
            if failure == nil { failure = coordination }
        } else {
            do { try fileManager.removeItem(at: url) } catch { failure = error }
        }
        guard let error = failure else {
            report.removed += 1
            return true
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError { return true }
        if !quiet { report.failures.append(url.lastPathComponent + ": " + ns.localizedDescription) }
        return false
    }
}

/// Device-local settings through the store, so open screens see them go back to their defaults at once. The
/// library's synced settings belong to the library folder: they stay with it, and go when its files do.
enum DeviceSettingsEraser {
    @discardableResult
    static func clear(_ settings: SettingsStore) -> Int {
        let backend = settings.syncedBackend
        let synced = Set(backend?.names() ?? [])
        var cleared = 0
        for name in settings.names(prefix: "") where !synced.contains(name) {
            // A synced name would be written to the library's preferences as removed; the defaults wipe covers it.
            if backend != nil, settings.descriptor(name)?.synced == true { continue }
            guard settings.json(name) != nil else { continue }
            settings.setJSON(name, nil)
            cleared += 1
        }
        return cleared
    }
}

// MARK: - System stores

/// Keychain, defaults domains and the system's stores for this app.
@MainActor
protocol SystemDataWiping: AnyObject {
    /// Returns the failures ("Keychain: …"); an empty list means everything went.
    func wipe(appGroupIDs: [String]) async -> [String]
}

@MainActor
final class SystemDataWiper: SystemDataWiping {
    func wipe(appGroupIDs: [String]) async -> [String] {
        var failures = wipeKeychain()
        wipeDefaults(appGroupIDs: appGroupIDs)
        wipeURLLoading()
        await wipeWebData()
        failures += await wipeSystemIndexes()
        wipeNotifications()
        WidgetCenter.shared.reloadAllTimelines()
        return failures
    }

    /// Every item of every class this app can reach (its access groups), synchronisable ones included.
    private func wipeKeychain() -> [String] {
        let classes: [(CFString, String)] = [
            (kSecClassGenericPassword, "passwords"), (kSecClassInternetPassword, "internet passwords"),
            (kSecClassKey, "keys"), (kSecClassCertificate, "certificates"), (kSecClassIdentity, "identities")
        ]
        var failures: [String] = []
        for (secClass, name) in classes {
            let query: [String: Any] = [kSecClass as String: secClass,
                                        kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                failures.append("Keychain \(name): OSStatus \(status)")
            }
        }
        return failures
    }

    /// The app's defaults domain (settings, safe mode, restoration) and the App Group suites.
    private func wipeDefaults(appGroupIDs: [String]) {
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults().removePersistentDomain(forName: bundleID)
        }
        for id in appGroupIDs {
            UserDefaults(suiteName: id)?.removePersistentDomain(forName: id)
        }
    }

    /// Cookies, cached responses and credentials URLSession kept (WebDAV, relay, gallery downloads).
    private func wipeURLLoading() {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        let credentials = URLCredentialStorage.shared
        for (space, byUser) in credentials.allCredentials {
            for credential in byUser.values {
                credentials.remove(credential, for: space)
            }
        }
    }

    /// Plugin panels' local storage, IndexedDB and caches: the default store and every identified one.
    private func wipeWebData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { done.resume() }
        }
        let ids: [UUID] = await withCheckedContinuation { (done: CheckedContinuation<[UUID], Never>) in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { done.resume(returning: $0) }
        }
        for id in ids {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in done.resume() }
            }
        }
    }

    /// Spotlight items, Siri donations and activities that could still name documents.
    private func wipeSystemIndexes() async -> [String] {
        var failures: [String] = []
        if CSSearchableIndex.isIndexingAvailable() {
            let error: Error? = await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
                CSSearchableIndex.default().deleteAllSearchableItems { done.resume(returning: $0) }
            }
            if let error { failures.append("Spotlight: " + error.localizedDescription) }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            INInteraction.deleteAll { _ in done.resume() }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            NSUserActivity.deleteAllSavedUserActivities { done.resume() }
        }
        return failures
    }

    /// Study reminders, calendar and timer notifications, and the badge. Removing never prompts.
    private func wipeNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0, withCompletionHandler: nil)
    }
}

// MARK: - Confirmation

/// How the person answered one confirmation.
enum DeletionAnswer: Equatable {
    case confirmed
    case declined
    /// No window could show it (another presentation never finished): nothing is deleted.
    case notShown
}

struct DeletionPrompt: Equatable {
    enum Step: Equatable { case overview, final }

    var step: Step
    var title: String
    var message: String
    var confirmTitle: String
    var isDestructive: Bool
}

/// What the confirmations and the closing notice describe.
struct DeletionSubject: Equatable {
    var includeLibrary: Bool
    /// Documents in the library, trash included.
    var documents: Int
    var lockedDocuments: Int
    /// "iCloud Drive › Nib"; nil without a library service.
    var libraryName: String?
    /// The library lives in Nib's own container (it reopens by itself after a restart).
    var libraryInApp: Bool
    /// "iPad" or "iPhone".
    var deviceModel: String
}

struct DeletionFinish: Equatable {
    var subject: DeletionSubject
    var failures: Int

    var title: String { String(localized: "Nib Data Deleted") }

    var message: String {
        let model = subject.deviceModel
        if subject.includeLibrary {
            return String(localized: "Your library and everything Nib kept on this \(model) are gone.")
        }
        let erased = String(localized: "Settings, keys, permissions and caches are gone from this \(model).")
        let library = subject.libraryInApp
            ? String(localized: "Your library was kept and opens again when you restart Nib.")
            : String(localized: "Your library folder was kept: pick it again when Nib asks where your library is.")
        return erased + " " + library
    }

    var failureMessage: String? {
        guard failures > 0 else { return nil }
        let items = failures == 1 ? String(localized: "1 item") : String(localized: "\(failures) items")
        return String(localized: "Nib couldn't delete \(items). Deleting Nib from the Home Screen removes what's left on this device.")
    }

    var closeTitle: String { String(localized: "Close Nib") }

    var closeNote: String {
        String(localized: "Nib closes to finish, so nothing from before can be saved again. Open it to start fresh.")
    }
}

enum DeletionCopy {
    static func prompts(_ s: DeletionSubject) -> [DeletionPrompt] {
        [overview(s), final(s)]
    }

    static func overview(_ s: DeletionSubject) -> DeletionPrompt {
        let model = s.deviceModel
        let place = s.libraryName ?? String(localized: "your library folder")
        var message: String
        if s.includeLibrary {
            let erased = String(localized: "Nib erases its settings, keys, permissions, caches and search data on this \(model).")
            let library: String
            switch s.documents {
            case 0: library = String(localized: "It also deletes everything Nib keeps in \(place): folders, the trash, plugins and templates.")
            case 1: library = String(localized: "It also deletes 1 document in \(place), with its folders, the trash, plugins and templates.")
            default: library = String(localized: "It also deletes \(s.documents) documents in \(place), with their folders, the trash, plugins and templates.")
            }
            message = erased + " " + library
            if s.lockedDocuments > 0 {
                message += " " + (s.lockedDocuments == 1
                    ? String(localized: "That includes 1 locked document.")
                    : String(localized: "That includes \(s.lockedDocuments) locked documents."))
            }
        } else {
            message = String(localized: "Nib erases its settings, AI keys, WebDAV, relay and bridge credentials, plugin permissions, caches and search data on this \(model).")
                + " " + String(localized: "Your library in \(place) stays where it is.")
        }
        return DeletionPrompt(step: .overview, title: String(localized: "Delete All Nib Data?"), message: message,
                              confirmTitle: String(localized: "Continue"), isDestructive: false)
    }

    static func final(_ s: DeletionSubject) -> DeletionPrompt {
        let message = s.includeLibrary
            ? String(localized: "The documents won't go to Nib's Trash, and if the library folder syncs, your other devices lose them too. Nib closes when it's done.")
            : String(localized: "App data has no Trash. Nib closes when it's done so it can start fresh.")
        return DeletionPrompt(step: .final, title: String(localized: "This Can't Be Undone"), message: message,
                              confirmTitle: s.includeLibrary ? String(localized: "Delete Library and Data")
                                                              : String(localized: "Delete All Data"),
                              isDestructive: true)
    }

    /// For the command's result (read by the assistant, plugins and bridge clients): plain English.
    static func erases(includeLibrary: Bool) -> [String] {
        var list = ["settings on this device", "Keychain items (AI keys, WebDAV, relay and bridge credentials, plugin grants)",
                    "Application Support files (AI provider configs, indexes)", "caches and temporary files",
                    "plugin panels' web data, cookies and stored credentials", "shared widget and share-extension data",
                    "Spotlight items, Siri donations and pending notifications", "the Open In inbox and diagnostic copies"]
        if includeLibrary {
            list.append("the library's documents, folders, trash, plugins, templates and synced preferences")
        }
        return list
    }

    static func keeps(includeLibrary: Bool) -> [String] {
        includeLibrary
            ? ["files in the library folder that Nib did not create"]
            : ["the library folder and everything in it", "this device's id, so the library keeps syncing as this device"]
    }
}

@MainActor
protocol DeletionPrompting: AnyObject {
    func confirm(_ prompt: DeletionPrompt) async -> DeletionAnswer
    /// The closing notice; `close` erases once more and quits.
    func showFinished(_ finish: DeletionFinish, close: @escaping @MainActor () async -> Void)
}

/// System alerts in the active window (DESIGN.md §13.7: alerts are used as they are), then a full-screen notice.
@MainActor
final class AlertDeletionPrompter: DeletionPrompting {
    private weak var navigator: SceneNavigator?

    init(navigator: SceneNavigator) {
        self.navigator = navigator
    }

    func confirm(_ prompt: DeletionPrompt) async -> DeletionAnswer {
        if prompt.isDestructive { NibHaptics.play(.warning) }
        let alert = UIAlertController(title: prompt.title, message: prompt.message, preferredStyle: .alert)
        return await withCheckedContinuation { (answer: CheckedContinuation<DeletionAnswer, Never>) in
            let once = AnswerOnce(answer)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in once.resume(.declined) })
            let confirm = UIAlertAction(title: prompt.confirmTitle, style: prompt.isDestructive ? .destructive : .default) { _ in
                once.resume(.confirmed)
            }
            alert.addAction(confirm)
            // Return confirms the first step only; the irreversible one needs a deliberate tap.
            if !prompt.isDestructive { alert.preferredAction = confirm }
            Task { @MainActor in
                if await !self.present(alert) {
                    AboutLog.logger.error("a deletion confirmation could not be shown")
                    once.resume(.notShown)
                }
            }
        }
    }

    func showFinished(_ finish: DeletionFinish, close: @escaping @MainActor () async -> Void) {
        let host = UIHostingController(rootView: DeletionFinishedView(finish: finish, close: close))
        host.modalPresentationStyle = .fullScreen
        host.isModalInPresentation = true
        host.view.backgroundColor = NibUIColor.groupedBackground
        Task { @MainActor in
            if await !self.present(host) {
                AboutLog.logger.error("the closing notice could not be shown")
            }
        }
    }

    /// Presents over whatever the window shows once no presentation is moving (the gateway's own confirmation or the
    /// previous step may still be animating away), and reports whether it appeared.
    private func present(_ controller: UIViewController) async -> Bool {
        for _ in 0..<40 {
            guard let root = navigator?.rootViewController, root.viewIfLoaded?.window != nil else { return false }
            var top = root
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            if top.transitionCoordinator == nil, !top.isBeingPresented, top.presentedViewController == nil {
                top.present(controller, animated: true)
                if controller.presentingViewController != nil { return true }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

/// Resumes a continuation at most once (a failed presentation and a tap cannot both answer).
@MainActor
private final class AnswerOnce {
    private var continuation: CheckedContinuation<DeletionAnswer, Never>?

    init(_ continuation: CheckedContinuation<DeletionAnswer, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: DeletionAnswer) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The closing notice: an opaque full-screen page (DESIGN.md §14.18 wording: what happened, what to do next).
struct DeletionFinishedView: View {
    let finish: DeletionFinish
    let close: @MainActor () async -> Void
    @State private var closing = false

    var body: some View {
        ScrollView {
            VStack(spacing: NibSpacing.l) {
                NibEmptyState(symbol: .checkCircle, title: finish.title, message: finish.message,
                              primary: NibAction(finish.closeTitle) { start() })
                    .disabled(closing)
                if let failure = finish.failureMessage {
                    NibBanner(failure, style: .warning)
                        .frame(maxWidth: NibMetrics.onboardingCardWidth)
                }
                if closing {
                    ProgressView()
                        .accessibilityLabel(Text(String(localized: "Closing Nib")))
                } else {
                    Text(finish.closeNote)
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: NibMetrics.onboardingCardWidth)
                }
            }
            .padding(NibSpacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(NibColor.groupedBackground.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func start() {
        guard !closing else { return }
        closing = true
        Task { @MainActor in await close() }
    }
}

// MARK: - Privacy page (P-096, S-018, P-097)

/// Where the assistant's requests go (S-018): nowhere, a machine on the person's own network, or a provider.
enum AssistantDestination: Equatable {
    /// No provider is set up.
    case none
    /// Providers are set up, but none is the assistant's.
    case unchosen
    case local(name: String, host: String)
    case remote(name: String, host: String)

    init(_ config: AIProviderConfig) {
        let host = AIPrivacySummary.host(config)
        self = NetworkLocality.isOwnNetwork(host: host) ? .local(name: config.name, host: host)
                                                        : .remote(name: config.name, host: host)
    }

    var message: String {
        switch self {
        case .none:
            return String(localized: "No AI provider is set up, so nothing goes to one. When you add a provider, only that provider receives what the assistant reads.")
        case .unchosen:
            return String(localized: "No provider is chosen for the assistant yet, so nothing goes to one. When you choose one, only that provider receives what the assistant reads.")
        case let .local(name, host):
            return String(localized: "The assistant uses \(name) at \(host), on your own network. What it reads never leaves that network.")
        case let .remote(name, host):
            return String(localized: "The assistant sends what it reads (page text, the pages it looks at and your questions) only to \(name) at \(host), under that provider's terms. Nothing goes to Nib.")
        }
    }
}

/// The "AI goes only to your provider" statement: the assistant's provider (the active one, as
/// `AIProviderStore.provider(nil)` resolves it) and the other providers the person added.
struct AIPrivacySummary: Equatable {
    var destination: AssistantDestination
    /// "Name at host" for every other provider set up; each receives only what the person sends to it.
    var others: [String]

    @MainActor
    static func from(store: AIProviderStore?) -> AIPrivacySummary {
        guard let store, !store.configs.isEmpty else { return AIPrivacySummary(destination: .none, others: []) }
        let configs = store.configs
        let active = configs.first { $0.id == store.activeID } ?? store.provider(nil)?.config
        let others = configs.filter { $0.id != active?.id }.map { $0.name + " (" + host($0) + ")" }
        return AIPrivacySummary(destination: active.map(AssistantDestination.init) ?? .unchosen, others: others)
    }

    static func host(_ config: AIProviderConfig) -> String {
        config.baseURL.host ?? config.baseURL.absoluteString
    }

    var message: String {
        guard !others.isEmpty else { return destination.message }
        let list = ListFormatter.localizedString(byJoining: others)
        return destination.message + " " + String(localized: "You also added \(list): each one receives only the requests you send to it.")
    }
}

/// Hosts that stay on the person's own network or device: loopback, private and link-local ranges, Tailscale
/// (100.64.0.0/10, *.ts.net), unique-local IPv6 and Bonjour names.
enum NetworkLocality {
    static func isOwnNetwork(host raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || host.hasSuffix(".home.arpa") {
            return true
        }
        if host.contains(":") {
            if host == "::1" { return true }
            let first = host.split(separator: ":").first.map(String.init) ?? ""
            guard let group = UInt16(first, radix: 16) else { return false }
            return group & 0xfe00 == 0xfc00 || group & 0xffc0 == 0xfe80
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, host.split(separator: ".", omittingEmptySubsequences: false).count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _): return true
        case (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}

@MainActor
final class PrivacyModel: ObservableObject {
    let app: NibApp
    @Published var includeLibrary = false
    @Published private(set) var isDeleting = false
    @Published private(set) var problem: String?
    @Published private(set) var assistant = AIPrivacySummary(destination: .none, others: [])
    @Published private(set) var libraryName: String?
    @Published private(set) var documents = 0

    init(app: NibApp) {
        self.app = app
        refresh()
    }

    var canDelete: Bool { app.commands.entry(CommandIDs.appDeleteAllData) != nil }

    func refresh() {
        assistant = .from(store: app.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self))
        let subject = DataDeletionService.resolve(app.services)?.describe(includeLibrary: true,
                                                                         library: app.services.library)
        libraryName = subject?.libraryName ?? app.services.library?.rootURL.lastPathComponent
        documents = subject?.documents ?? 0
    }

    /// Runs `app.deleteAllData`, which asks twice itself. Declining is not an error.
    func deleteAll() async {
        guard !isDeleting else { return }
        isDeleting = true
        problem = nil
        defer { isDeleting = false }
        do {
            try await app.bus.execute(CommandIDs.appDeleteAllData, ["includeLibrary": .bool(includeLibrary)],
                                      session: app.services.sessions.active)
        } catch {
            let e = NibError.wrap(error)
            if e.code != .userDenied { problem = e.message }
        }
    }
}

struct PrivacyPage: View {
    @StateObject private var model: PrivacyModel

    init(app: NibApp) {
        _model = StateObject(wrappedValue: PrivacyModel(app: app))
    }

    var body: some View {
        List {
            Section {
                statement(.profile, String(localized: "No account"),
                          String(localized: "Nib has no sign-in and no server. Your name is only a label on this device for sticky notes, comments and collaboration."))
                statement(.eyeSlash, String(localized: "No tracking"),
                          String(localized: "Nib sends no analytics, crash reports, usage data or handwriting samples anywhere, and collects nothing to train models. Diagnostics leave only when you export and share them yourself."))
                statement(.assistant, String(localized: "AI goes only to your provider"), model.assistant.message)
                statement(.folder, String(localized: "Your notes stay in your library"), libraryStatement)
                statement(.key, String(localized: "Secrets stay in the Keychain"),
                          String(localized: "API keys, passwords and the bridge token stay in this device's Keychain. They never sync and plugins and the assistant never see them."))
                statement(.puzzle, String(localized: "Plugins and the bridge ask first"),
                          String(localized: "A plugin reaches the network or your library only with the permissions you granted. The bridge is off until you turn it on, and the assistant, plugins and bridge ask before anything that can't be undone."))
            } header: {
                AboutHeader(String(localized: "How Nib handles your data"))
            } footer: {
                AboutFooter(String(localized: "Nib connects to the internet only for what you set up: your AI provider, a WebDAV server, a collaboration relay, plugin galleries, GIF search with your own key, and links you import from."))
            }
            deleteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Privacy & Data"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refresh() }
    }

    private var libraryStatement: String {
        let place = model.libraryName ?? String(localized: "your library folder")
        return String(localized: "Documents live in \(place). Nib copies them only where you send them: your sync folder, a WebDAV server, backups, collaboration or exports.")
    }

    private func statement(_ symbol: NibSymbol, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            HStack(spacing: NibSpacing.m) {
                Image(nib: symbol)
                    .font(NibFont.glyph(.panel))
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(minWidth: NibSpacing.x3, alignment: .leading)
                    .accessibilityHidden(true)
                Text(title)
                    .font(NibFont.headline)
                    .foregroundStyle(NibColor.label)
            }
            Text(text)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NibSpacing.xs)
        .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var deleteSection: some View {
        if model.canDelete {
            Section {
                if let problem = model.problem {
                    NibBanner(problem, style: .warning)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                NibToggle(String(localized: "Also delete my library"), isOn: $model.includeLibrary)
                    .disabled(model.isDeleting)
                if model.includeLibrary {
                    Text(libraryWarning)
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NibButton(String(localized: "Delete All Nib Data"), symbol: .trash, kind: .destructive) {
                    Task { await model.deleteAll() }
                }
                .disabled(model.isDeleting)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint(Text(String(localized: "Asks twice before deleting anything")))
            } header: {
                AboutHeader(String(localized: "Delete All Nib Data"))
            } footer: {
                AboutFooter(String(localized: "Erases Nib's settings, keys, plugin permissions, caches and search data on this device, then closes Nib. Nib asks twice first. This replaces account deletion: there is no account or server copy to delete."))
            }
        }
    }

    private var libraryWarning: String {
        let place = model.libraryName ?? String(localized: "your library folder")
        switch model.documents {
        case 0: return String(localized: "Everything Nib keeps in \(place) goes too, on every device the folder syncs to.")
        case 1: return String(localized: "1 document in \(place) goes too, on every device the folder syncs to.")
        default: return String(localized: "\(model.documents) documents in \(place) go too, on every device the folder syncs to.")
        }
    }
}
