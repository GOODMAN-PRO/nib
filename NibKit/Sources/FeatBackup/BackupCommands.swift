import Foundation
import UIKit
import UniformTypeIdentifiers
import NibContracts

struct BackupNow: NibCommand {
    typealias Params = NoResult
    typealias Output = BackupStatusInfo
    static let descriptor = CommandDescriptor(id: CommandIDs.backupNow, title: String(localized: "Back Up Now"),
        summary: "Back up pending documents now; a user request queues the whole eligible library. Locked documents are skipped.",
        examples: [[:]], effect: .session, target: .app, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try await BackupEngine.resolve(ctx.services).run(ctx, automatic: BackupExecution.automatic)
    }
}

struct BackupManual: NibCommand {
    typealias Params = NoResult
    typealias Output = JSONValue
    static let descriptor = CommandDescriptor(id: CommandIDs.backupManual, title: String(localized: "Create Library Backup"),
        summary: "ZIP the library without caches or locked documents and save it with Files. Foreground only; interruption requires a fresh run. Restore with import.pick.",
        examples: [[:]], effect: .session, target: .app, extraScopes: [.libraryRead], userPresence: true, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("Manual backup requires a foreground window") }
        guard UIApplication.shared.applicationState == .active else { throw NibError.unavailable("Keep Nib open while creating a manual backup") }
        return try await BackupEngine.resolve(ctx.services).manual(ctx)
    }
}

struct BackupConfigure: NibCommand {
    struct Params: Codable {
        var destination: BackupDestination
        var format: String
        var folder: String?
        var exclusions: [String]?
        var frequent: Bool?
    }
    typealias Output = BackupStatusInfo
    static let descriptor = CommandDescriptor(id: CommandIDs.backupConfigure, title: String(localized: "Configure Backup"),
        summary: "Set destination {kind: folder|webdav|none, folder?}, format nib|pdf|both, relative folder, excluded name substrings and frequent (90 seconds; default 12 hours).",
        params: .obj([
            "destination": .obj(["kind": .str(choices: ["folder", "webdav", "none"]), "folder": .str("relative WebDAV folder")], required: ["kind"]),
            "format": .str(choices: ["nib", "pdf", "both"]), "folder": .str("relative subfolder, default Nib Backups"),
            "exclusions": .arr(.str(), "case-insensitive name substrings"), "frequent": .bool("90 seconds instead of 12 hours")
        ], required: ["destination", "format"]),
        examples: [["destination": ["kind": "none"], "format": "nib"],
                   ["destination": ["kind": "webdav", "folder": "Nib Backups"], "format": "both", "frequent": true]],
        effect: .session, target: .app, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let engine = try BackupEngine.resolve(ctx.services)
        guard ["none", "folder", "webdav"].contains(p.destination.kind) else {
            throw NibError(.invalidParams, "Unknown backup destination", path: "$.destination.kind", hint: "Use folder, webdav or none")
        }
        guard ["nib", "pdf", "both"].contains(p.format) else {
            throw NibError(.invalidParams, "Unknown backup format", path: "$.format", hint: "Use nib, pdf or both")
        }
        let previous = BackupSettings.read(ctx.services.settings)
        let folder = p.folder ?? p.destination.folder ?? previous.folder
        _ = try BackupWriter.components(folder)
        let exclusions = p.exclusions ?? previous.exclusions
        guard exclusions.count <= 256, exclusions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 && !$0.contains("\0") }) else {
            throw NibError(.invalidParams, "Use up to 256 nonempty excluded name substrings of at most 200 characters", path: "$.exclusions",
                                   hint: "Call backup.configure with exclusions such as [\"Private\"]")
        }
        if p.destination.kind == "folder", ctx.services.settings.get(BackupSettings.bookmark) == nil {
            throw NibError.unavailable("Choose a Files-provider folder with backup.chooseFolder first")
        }
        let config = BackupConfiguration(destination: BackupDestination(kind: p.destination.kind, folder: p.destination.kind == "webdav" ? folder : nil),
                                         format: p.format, folder: folder, exclusions: exclusions, frequent: p.frequent ?? previous.frequent)
        if ctx.dryRun { return engine.status() }
        try await engine.ensureLoaded()
        BackupSettings.write(config, to: ctx.services.settings)
        do { try await engine.configurationChanged() }
        catch { BackupSettings.write(previous, to: ctx.services.settings); throw error }
        if !BackupUndo.isReplaying, let app = ctx.app, let manager = ctx.navigator?.rootViewController?.view.window?.undoManager,
           previous != config {
            BackupUndo.record(manager: manager, app: app, from: config, to: previous)
        }
        return engine.status()
    }
}

/// Window settings undo stays independent of document history, and every undo/redo traverses backup.configure.
@MainActor
enum BackupUndo {
    @TaskLocal static var isReplaying = false
    static func record(manager: UndoManager, app: NibApp, from current: BackupConfiguration, to previous: BackupConfiguration) {
        manager.registerUndo(withTarget: app) { target in
            record(manager: manager, app: target, from: previous, to: current)
            Task { @MainActor in
                do {
                    try await $isReplaying.withValue(true) {
                        try await target.bus.execute(CommandIDs.backupConfigure, try JSONValue.from(BackupConfigure.Params(
                            destination: previous.destination, format: previous.format, folder: previous.folder,
                            exclusions: previous.exclusions, frequent: previous.frequent)))
                    }
                } catch {
                    NotificationCenter.default.post(name: .nibCommandFailed, object: target,
                        userInfo: ["command": CommandIDs.backupConfigure, "error": NibError.wrap(error)])
                }
            }
        }
        manager.setActionName(String(localized: "Configure Backup"))
    }
}

struct BackupChooseFolder: NibCommand {
    typealias Params = NoResult
    struct Output: Codable { var folder: String; var chosen: Bool }
    static let descriptor = CommandDescriptor(id: CommandIDs.backupChooseFolder, title: String(localized: "Choose Backup Folder"),
        summary: "Choose a folder from Files (Google Drive, Dropbox, OneDrive, iCloud Drive or local storage). Store its security-scoped bookmark on this device.",
        examples: [[:]], effect: .session, target: .app, userPresence: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("Folder selection requires a foreground window") }
        guard let navigator = ctx.navigator else { throw NibError.unavailable("Open a window to choose a backup folder") }
        let engine = try BackupEngine.resolve(ctx.services)
        if ctx.dryRun { return Output(folder: ctx.services.settings.get(BackupSettings.folderName), chosen: false) }
        let url = try await engine.userInterface.chooseFolder(navigator: navigator)
        let library = try ctx.services.require(ctx.services.library, "Library")
        guard !BackupWriter.isInside(url, library.rootURL), !BackupWriter.isInside(library.rootURL, url) else {
            throw NibError(.invalidParams, "Choose a backup folder separate from the library", path: "$.destination",
                                   hint: "Call backup.chooseFolder again and choose another folder")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [])
        ctx.services.settings.set(BackupSettings.bookmark, bookmark)
        ctx.services.settings.set(BackupSettings.folderName, url.lastPathComponent)
        if BackupSettings.read(ctx.services.settings).destination.kind == "folder" { try await engine.configurationChanged() }
        engine.emit()
        return Output(folder: url.lastPathComponent, chosen: true)
    }
}

struct BackupStatus: NibCommand {
    typealias Params = NoResult
    typealias Output = BackupStatusInfo
    static let descriptor = CommandDescriptor(id: CommandIDs.backupStatus, title: String(localized: "Backup Status"),
        summary: "Read this device's backup destination, format, queue, progress, skipped locks, errors, last success and next scheduled run.",
        examples: [[:]], effect: .read, target: .app)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let engine = try BackupEngine.resolve(ctx.services)
        // Status remains available even when a damaged queue needs resetting.
        do { try await engine.ensureLoaded() } catch { return engine.status() }
        return engine.status()
    }
}

struct BackupClearQueue: NibCommand {
    typealias Params = NoResult
    typealias Output = BackupStatusInfo
    static let descriptor = CommandDescriptor(id: CommandIDs.backupClearQueue, title: String(localized: "Clear Backup Queue"),
        summary: "Clear only this device's pending automatic backups. Remote backup files stay in place. Also repairs an unreadable queue.",
        examples: [[:]], effect: .session, target: .app, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let engine = try BackupEngine.resolve(ctx.services)
        if !ctx.dryRun { try await engine.clearQueue() }
        return engine.status()
    }
}

@MainActor
protocol BackupUserInterface: AnyObject {
    func chooseFolder(navigator: SceneNavigator) async throws -> URL
    func saveArchive(_ url: URL, navigator: SceneNavigator) async throws
}

@MainActor
final class BackupSystemPicker: NSObject, BackupUserInterface, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var picker: UIDocumentPickerViewController?

    func chooseFolder(navigator: SceneNavigator) async throws -> URL {
        try await show(UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false), navigator: navigator)
    }
    func saveArchive(_ url: URL, navigator: SceneNavigator) async throws {
        _ = try await show(UIDocumentPickerViewController(forExporting: [url], asCopy: true), navigator: navigator)
    }
    private func show(_ picker: UIDocumentPickerViewController, navigator: SceneNavigator) async throws -> URL {
        guard continuation == nil, navigator.rootViewController?.view.window != nil,
              UIApplication.shared.applicationState == .active else { throw NibError.unavailable("Open a foreground window to use Files") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; self.picker = picker
                picker.delegate = self; picker.allowsMultipleSelection = false
                navigator.presentModal(picker)
                picker.presentationController?.delegate = self
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.picker?.dismiss(animated: false)
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation; continuation = nil; picker = nil; pending?.resume(with: result)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { finish(.success(url)) } else { finish(.failure(NibError(.userDenied, "No folder or file was chosen"))) }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.failure(NibError(.userDenied, "Files selection cancelled"))) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(.failure(NibError(.userDenied, "Files selection dismissed"))) }
}
