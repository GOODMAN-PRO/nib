import Foundation
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import NibContracts
import NibDesign

/// The three public command paths share validation, queries and delivery. Dialog edits remain a draft;
/// committing that draft executes one of these paths without altering the document or its undo history.
struct PresentExport: NibCommand {
    struct Params: Codable {
        var docs: [String]?
        var pages: [String]?
        var scope: String?
        var format: String?
        var options: JSONValue?
        var name: String?
        var destination: String?
        var instant: Bool?
    }
    static let descriptor = CommandDescriptor(
        id: "export.present", title: String(localized: "Share & Export"),
        summary: "Open export options for documents, folders or pages; supply format, options and destination (share/files) to export and deliver the draft.",
        params: .obj([
            "docs": .arr(.ref, "documents or folder refs; defaults to the open document"),
            "pages": .arr(.ref, "selected page refs"),
            "scope": .str(choices: ExportPageScope.allCases.map(\.rawValue)),
            "format": .str("registered exporter id"), "options": .anything("export.run options"),
            "name": .str("file name without extension"),
            "destination": .str(choices: ["share", "files"]), "instant": .bool("keyboard presentation")
        ]), examples: [["docs": ["doc:FIXTUREDOC01"]],
                      ["docs": ["doc:FIXTUREDOC04"], "scope": "current"]],
        effect: .read, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        if p.destination == nil, !ctx.dryRun, (p.docs?.count ?? 1) == 1 {
            let ref = p.docs?.first ?? ctx.activeSession?.document.map { NodeRef.document($0).description }
            if let ref, let doc = NodeRef(ref)?.documentID, ctx.services.lock?.isLocked(doc) == true {
                try await ExportPresentation.presenter(ctx).showLocked(doc: doc, retry: Self.descriptor.id,
                                                                      params: JSONValue.from(p), ctx: ctx)
                return ["presented": true, "locked": true]
            }
        }
        let selection = try await ExportSelection.load(docs: p.docs, pages: p.pages, ctx: ctx)
        var draft = ExportDraft(selection: selection)
        if let scope = p.scope { draft.scope = try ExportPageScope.parse(scope) }
        if let format = p.format { draft.format = format }
        if let options = p.options {
            guard options.objectValue != nil else { throw NibError.invalid("options must be an object", path: "$.options") }
            draft.options = options
        }
        if let name = p.name { draft.name = name }
        let params: JSONValue
        if p.destination == nil && draft.scope == .selected && draft.selectedPages.isEmpty {
            params = ["docs": .array(selection.refs.map(JSONValue.string)), "format": .string(draft.format), "scope": "selected"]
        } else { params = try draft.runParams(selection: selection) }
        if ctx.dryRun { return ["params": params] }
        let presenter = try ExportPresentation.presenter(ctx)
        guard let destination = p.destination else {
            try await presenter.show(selection: selection, draft: draft, printing: false, instant: p.instant ?? false, ctx: ctx)
            return ["presented": true, "params": params]
        }
        guard ["share", "files"].contains(destination) else { throw NibError.invalid("unknown destination", path: "$.destination") }
        try selection.requireUnlocked(ctx)
        let result = try await ctx.execute(CommandIDs.exportRun, params)
        try selection.requireUnlocked(ctx)
        let files = try await ExportFiles.materialize(result, ctx: ctx)
        defer { files.remove() }
        try selection.requireUnlocked(ctx)
        let completed = try await presenter.deliver(files.urls, destination: destination, ctx: ctx)
        if completed {
            let count = params["pages"]?.arrayValue?.count ?? selection.documents.reduce(0) { $0 + $1.pages.count }
            ctx.activeSession?.floatingHost?.postToast(count > 0 ? String(localized: "Exported \(count) pages") : String(localized: "Exported \(selection.documents.count) documents"))
        }
        return ["completed": .bool(completed), "files": result["files"] ?? .array([])]
    }
}

struct SaveToSource: NibCommand {
    struct Params: Codable { var doc: String? }
    static let descriptor = CommandDescriptor(
        id: "export.saveToSource", title: String(localized: "Save Changes to Source"),
        summary: "Confirm and overwrite an import-in-place document's bookmarked source with its current export; locked documents are refused.",
        params: .obj(["doc": .ref]), examples: [["doc": "doc:FIXTUREDOC01"]],
        effect: .irreversible, undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let doc = try ctx.documentOrSession(p.doc)
        try ExportSelection.requireUnlocked(doc, ctx)
        // query.get intentionally strips sourceBookmark. Read just this private capability inside the handler.
        guard let bookmark = try ctx.workspace.peekContent(doc).meta.sourceBookmark else {
            throw NibError(.unsupported, String(localized: "This document has no source file."), hint: "use export.present to save a copy")
        }
        let source = try await ExportFiles.work { try SourceOverwrite.resolve(bookmark) }
        let selection = try await ExportSelection.load(docs: [NodeRef.document(doc).description], pages: nil, ctx: ctx)
        let ext = source.pathExtension.lowercased()
        let exporters = selection.formats.filter {
            $0.fileExtension.lowercased() == ext || (ext == "jpeg" && $0.fileExtension == "jpg")
        }
        guard let exporter = exporters.first else {
            throw NibError(.unsupported, String(localized: "The source format cannot preserve this document."), hint: "use export.present to save a copy")
        }
        if ctx.dryRun { return ["wouldReplace": .string(source.lastPathComponent)] }
        // Gateway already confirms non-user callers. The user path also needs an explicit overwrite confirmation.
        if ctx.principal.isUser {
            guard let confirmer = ctx.app?.gateway.confirmationPresenter(for: ctx.principal) else {
                throw NibError(.userDenied, String(localized: "Confirm before replacing the source file."))
            }
            var descriptor = Self.descriptor
            descriptor.title = String(localized: "Replace \(source.lastPathComponent)?")
            let request = ConfirmationRequest(principal: ctx.principal, command: descriptor,
                                              params: ["doc": .string(NodeRef.document(doc).description)])
            guard await confirmer.confirm(request) != .deny else { throw NibError(.userDenied, String(localized: "Source file was not replaced.")) }
        }
        try ExportSelection.requireUnlocked(doc, ctx)
        let result = try await ctx.execute(CommandIDs.exportRun, [
            "docs": .array([.string(NodeRef.document(doc).description)]), "format": .string(exporter.id),
            "options": ["mode": "editable", ExportOptionKeys.visibleLayersOnly: false, ExportOptionKeys.background: true, ExportOptionKeys.annotations: true, "audio": true]
        ])
        let files = try await ExportFiles.materialize(result, ctx: ctx)
        defer { files.remove() }
        guard files.urls.count == 1 else {
            throw NibError(.unsupported, String(localized: "This export produces multiple files. Save a copy to Files instead."))
        }
        try ExportSelection.requireUnlocked(doc, ctx)
        let file = files.urls[0]
        try await ExportFiles.work { try SourceOverwrite.replace(source: source, exported: file) }
        ctx.activeSession?.floatingHost?.postToast(String(localized: "Saved changes to \(source.lastPathComponent)"))
        return ["saved": true, "name": .string(source.lastPathComponent)]
    }
}

struct ExportFiles {
    var folder: URL
    var urls: [URL]

    @MainActor
    static func materialize(_ result: JSONValue, ctx: CommandContext) async throws -> ExportFiles {
        guard let rows = result["files"]?.arrayValue, !rows.isEmpty else { throw NibError(.internalError, "The exporter returned no files.") }
        var inputs: [(String, URL)] = []
        for row in rows {
            guard let name = row["name"]?.stringValue, let asset = row["asset"]?.stringValue,
                  asset.hasPrefix("tmp:"), isSafeName(name) else {
                throw NibError(.internalError, "The exporter returned an invalid temporary file.")
            }
            inputs.append((name, try await ctx.inputFile(asset)))
        }
        return try await work {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NibShare-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                var used = Set<String>()
                var urls: [URL] = []
                for (name, source) in inputs {
                    let unique = uniqueName(name, used: &used)
                    let url = folder.appendingPathComponent(unique)
                    try FileManager.default.copyItem(at: source, to: url)
                    urls.append(url)
                }
                return ExportFiles(folder: folder, urls: urls)
            } catch { try? FileManager.default.removeItem(at: folder); throw NibError.wrap(error) }
        }
    }
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = name
        var index = 2
        while !used.insert(candidate.lowercased()).inserted {
            candidate = base + " (\(index))" + (ext.isEmpty ? "" : "." + ext)
            index += 1
        }
        return candidate
    }
    func remove() {
        let folder = folder
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }
    static func work<T>(_ body: @escaping () throws -> T) async throws -> T {
        do { return try await Task.detached(priority: .userInitiated, operation: body).value }
        catch { throw NibError.wrap(error) }
    }
}

enum SourceOverwrite {
    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw NibError.invalid("The source bookmark is not a file URL.") }
        return try validateResolvedURL(url, stale: stale)
    }
    static func validateResolvedURL(_ url: URL, stale: Bool) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NibError(.conflict, String(localized: "The source file is unavailable. Reopen it from Files before saving changes."))
        }
        return url
    }
    static func replace(source: URL, exported: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forReplacing, error: &coordinationError) { target in
            do {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isWritableKey])
                guard values.isRegularFile == true, values.isWritable != false else {
                    throw NibError(.permissionDenied, String(localized: "The source file cannot be replaced."))
                }
                let data = try Data(contentsOf: exported, options: .mappedIfSafe)
                do { try data.write(to: target, options: .atomic) }
                catch {
                    let error = error as NSError
                    guard (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError) ||
                          (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) else { throw error }
                    do { _ = try FileManager.default.replaceItemAt(target, withItemAt: exported) }
                    catch { try data.write(to: target) }
                }
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw NibError.wrap(error) }
    }
}

@MainActor
protocol ExportPresenting: AnyObject {
    func show(selection: ExportSelection, draft: ExportDraft, printing: Bool, instant: Bool, ctx: CommandContext) async throws
    func showLocked(doc: DocumentID, retry: String, params: JSONValue, ctx: CommandContext) async throws
    func deliver(_ urls: [URL], destination: String, ctx: CommandContext) async throws -> Bool
    func printPDF(_ url: URL, title: String, ctx: CommandContext) async throws -> Bool
}

@MainActor
enum ExportPresentation {
    static let serviceKey = "exportui.presenter"
    static func presenter(_ ctx: CommandContext) throws -> ExportPresenting {
        if let presenter = ctx.services.get(serviceKey, as: AnyObject.self) as? ExportPresenting { return presenter }
        guard !NibApp.isHostlessTest, ctx.navigator?.rootViewController != nil else { throw NibError.unavailable("a window for export") }
        return SystemExportPresenter()
    }
    static func topController(_ ctx: CommandContext) throws -> UIViewController {
        guard !NibApp.isHostlessTest, let navigator = ctx.navigator, let root = navigator.rootViewController else {
            throw NibError.unavailable("a window for export")
        }
        if let session = ctx.session, navigator.session !== session {
            throw NibError.unavailable("the invoking window for export")
        }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
    static let anchorID = "exportui.source"
    static func anchorRect(in parent: UIViewController) -> CGRect {
        CGRect(x: parent.view.bounds.maxX - NibMetrics.hitTarget - NibMetrics.chromeInset,
               y: parent.view.safeAreaInsets.top + NibMetrics.barTopGap,
               width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
    }
    static func anchor(_ controller: UIViewController, in parent: UIViewController) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = parent.view
        popover.sourceRect = anchorRect(in: parent)
        popover.permittedArrowDirections = [.up]
    }
}

@MainActor
final class SystemExportPresenter: NSObject, ExportPresenting, UIDocumentPickerDelegate {
    private var fileCompletion: CheckedContinuation<Bool, Error>?

    func show(selection: ExportSelection, draft: ExportDraft, printing: Bool, instant: Bool, ctx: CommandContext) async throws {
        guard let app = ctx.app else { throw NibError.unavailable("the app") }
        let parent = try ExportPresentation.topController(ctx)
        let session = ctx.activeSession
        let isCompact = parent.traitCollection.horizontalSizeClass == .compact
        if !isCompact, let host = session?.floatingHost ?? ctx.navigator?.floatingHost {
            showPopover(selection: selection, draft: draft, printing: printing, instant: instant,
                        app: app, session: session, host: host, parent: parent)
        } else {
            let controller = UIHostingController(rootView: ExportSheet(selection: selection, draft: draft, printing: printing,
                                                                        app: app, session: session))
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = [.medium(), .large()]
            controller.sheetPresentationController?.prefersGrabberVisible = true
            parent.present(controller, animated: !instant && !UIAccessibility.isReduceMotionEnabled)
        }
    }
    /// Anchor conversion is optional until the floating layer is attached to the window.
    /// Present first; the popover refreshes the anchor on appearance and geometry changes.
    @discardableResult
    func showPopover(selection: ExportSelection, draft: ExportDraft, printing: Bool, instant: Bool,
                     app: NibApp, session: EditorSession?, host: FloatingHosting,
                     parent: UIViewController) -> ExportPopover {
        let anchorID = ExportPresentation.anchorID
        let updateSourceRect: @MainActor () -> CGRect? = { [weak parent, weak host] in
            guard let parent, let host else { return nil }
            let rect = ExportPresentation.anchorRect(in: parent)
            guard let converted = host.containerRect(rect, from: parent.view),
                  host.setAnchor(anchorID, rect: rect, in: parent.view) else { return nil }
            return converted
        }
        let popover = ExportPopover(selection: selection, draft: draft, printing: printing,
            app: app, session: session, host: host,
            source: session?.document != nil ? "chrome.anchor.share" : anchorID,
            sourceRect: updateSourceRect(), updateSourceRect: updateSourceRect, instant: instant)
        host.present("exportui.dialog", content: AnyView(popover))
        return popover
    }
    func showLocked(doc: DocumentID, retry: String, params: JSONValue, ctx: CommandContext) async throws {
        guard let app = ctx.app else { throw NibError.unavailable("the app") }
        let parent = try ExportPresentation.topController(ctx)
        let session = ctx.activeSession
        let controller = UIHostingController(rootView: LockedExportSheet(doc: doc, app: app, session: session,
            onUnlocked: { [weak parent] in
                parent?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) {
                    app.perform(retry, params, session: session)
                }
            }))
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        parent.present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func deliver(_ urls: [URL], destination: String, ctx: CommandContext) async throws -> Bool {
        let parent = try ExportPresentation.topController(ctx)
        if destination == "files" {
            guard parent.viewIfLoaded?.window != nil, !parent.isBeingDismissed,
                  parent.presentedViewController == nil else {
                throw NibError.unavailable("a window ready to export")
            }
            let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
            picker.delegate = self
            ExportPresentation.anchor(picker, in: parent)
            return try await waitForFiles {
                parent.present(picker, animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        ExportPresentation.anchor(activity, in: parent)
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            activity.completionWithItemsHandler = { [weak activity] _, complete, _, error in
                guard !resumed else { return }
                resumed = true
                activity?.completionWithItemsHandler = nil
                if let error { continuation.resume(throwing: NibError.wrap(error)) }
                else { continuation.resume(returning: complete) }
            }
            parent.present(activity, animated: !UIAccessibility.isReduceMotionEnabled) { [weak activity] in
                if activity?.presentingViewController == nil && !resumed {
                    resumed = true
                    activity?.completionWithItemsHandler = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }
    /// Presentation is not delivery: Files reads these URLs later, after the user chooses
    /// a destination. Only the picker delegate may release the command's staging files.
    func waitForFiles(present: () -> Void) async throws -> Bool {
        guard fileCompletion == nil else { throw NibError.unavailable("a free file picker") }
        // UIDocumentPickerViewController.delegate is weak. Keep its owner alive until
        // the delegate completes this operation, including while the task is suspended.
        defer { withExtendedLifetime(self) {} }
        return try await withCheckedThrowingContinuation { continuation in
            fileCompletion = continuation
            present()
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishFiles(false) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finishFiles(!urls.isEmpty) }
    func finishFiles(_ value: Bool) {
        let completion = fileCompletion
        fileCompletion = nil
        completion?.resume(returning: value)
    }
    func printPDF(_ url: URL, title: String, ctx: CommandContext) async throws -> Bool {
        try await PrintController.present(url: url, title: title, ctx: ctx)
    }
}
