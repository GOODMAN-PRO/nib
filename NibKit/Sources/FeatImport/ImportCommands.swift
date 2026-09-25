import Foundation
import UIKit
import UniformTypeIdentifiers
import os
import NibContracts

let importLog = Logger(subsystem: "app.nib", category: "import")

// MARK: - Results and destinations

struct ImportFailure: Codable, Equatable {
    var url: String
    var code: String
    var message: String
}

/// Result of `import.files` and `import.pick`.
struct ImportResult: Codable, Equatable {
    /// Documents created, or the document pages were inserted into ("doc:D"), in import order.
    var refs: [String]
    /// Pages inserted into an existing document ("page:D/P"), in page order.
    var pages: [String]?
    /// Files that could not be imported while others were.
    var failed: [ImportFailure]?
    /// The user closed the import dialog or the Files picker.
    var cancelled: Bool?

    static let cancelledResult = ImportResult(refs: [], cancelled: true)
}

/// Where imported files go: new documents in a folder (nil = library root), or pages at a position in a notebook.
struct ImportDestination: Equatable {
    var folder: FolderID?
    var doc: DocumentID?
    var position: PagePosition = .end
    var anchor: PageID?

    static let libraryRoot = ImportDestination()

    var target: ImportTarget { ImportTarget(folder: folder, document: doc, position: position, anchorPage: anchor) }

    /// Parses `import.files` params. nil = the caller chose no destination (the user is asked when there is a window).
    static func parse(folder: String?, doc: String?, position: String?, anchor: String?) throws -> ImportDestination? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        var dest = ImportDestination()
        var chosen = false
        if let f = clean(folder) {
            chosen = true
            if f != "lib" && f != "library" {
                if let ref = NodeRef(f) {
                    guard case .folder(let id) = ref else {
                        throw NibError.invalid("'folder' must be a folder ref such as folder:F, or \"lib\"", path: "$.folder")
                    }
                    dest.folder = id
                } else if NibID.isValid(f) {
                    dest.folder = NibID(f)
                } else {
                    throw NibError.invalid("'folder' must be a folder ref such as folder:F, or \"lib\"", path: "$.folder")
                }
            }
        }
        if let d = clean(doc) {
            chosen = true
            if let ref = NodeRef(d) {
                switch ref {
                case .document(let id):
                    dest.doc = id
                case .page(let id, let page):
                    dest.doc = id
                    dest.anchor = page
                default:
                    throw NibError.invalid("'doc' must be a document ref such as doc:D", path: "$.doc")
                }
            } else if NibID.isValid(d) {
                dest.doc = NibID(d)
            } else {
                throw NibError.invalid("'doc' must be a document ref such as doc:D", path: "$.doc")
            }
        }
        if let a = clean(anchor) {
            if let ref = NodeRef(a) {
                guard case .page(let d, let page) = ref else {
                    throw NibError.invalid("'anchor' must be a page ref such as page:D/P", path: "$.anchor")
                }
                if let doc = dest.doc, doc != d {
                    throw NibError.invalid("'anchor' is a page of another document", path: "$.anchor")
                }
                dest.doc = d
                dest.anchor = page
                chosen = true
            } else if NibID.isValid(a) {
                dest.anchor = NibID(a)
            } else {
                throw NibError.invalid("'anchor' must be a page ref such as page:D/P", path: "$.anchor")
            }
        }
        if let p = clean(position) {
            guard let pos = PagePosition(rawValue: p) else {
                throw NibError.invalid("'position' must be before, after, start or end", path: "$.position")
            }
            dest.position = pos
        } else if dest.anchor != nil {
            dest.position = .after
        }
        if dest.doc == nil, dest.anchor != nil || clean(position) != nil {
            throw NibError(.invalidParams, "'position' and 'anchor' place pages in a document, so they need 'doc'",
                           path: "$.doc", hint: "pass doc:D, or leave out position and anchor to create new documents")
        }
        if dest.doc != nil, dest.folder != nil {
            throw NibError(.invalidParams, "pass either 'folder' (new documents) or 'doc' (pages in a notebook), not both",
                           path: "$.folder")
        }
        return chosen ? dest : nil
    }
}

/// One url to import, as the caller gave it.
struct ImportSource: Equatable {
    /// "tmp:<name>", "https://…", "file://…" or the share hand-off link.
    var original: String
    /// File name shown in the dialog and used for staged copies (and so for document titles).
    var name: String
    /// Already-local file in this import's staging folder (share-extension hand-off items).
    var local: URL?

    init(original: String, name: String? = nil, local: URL? = nil) {
        self.original = original
        self.name = name ?? ImportNaming.displayName(of: original)
        self.local = local
    }
}

/// A source copied into this import's staging folder.
struct StagedFile {
    var source: ImportSource
    var url: URL
    var isDirectory: Bool
    /// Bookmark of a file opened in place from outside the app (import-in-place, "Save changes to source").
    var bookmark: Data?
}

enum ImportNaming {
    /// Human file name of a url string: the last path component, percent-decoded, or the host of a bare web address.
    static func displayName(of original: String) -> String {
        if original.hasPrefix("tmp:") { return sanitize(String(original.dropFirst(4))) }
        guard let url = URL(string: original) else { return sanitize(original) }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if last.isEmpty || last == "/" { return sanitize(url.host ?? "") }
        return sanitize(last)
    }

    /// A single safe path component: no separators, no leading dots, at most 200 characters.
    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 200 {
            let ext = (s as NSString).pathExtension
            let base = String((s as NSString).deletingPathExtension.prefix(190))
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s.isEmpty ? String(localized: "Imported") : s
    }

    /// `name` inside `dir`, with " 2", " 3"… before the extension when it is taken.
    static func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Recognises common formats from their first bytes, for downloads and assets that arrive without an extension.
enum ContentSniffer {
    static func sniff(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return sniff((try? handle.read(upToCount: 512)) ?? Data())
    }

    static func sniff(_ head: Data) -> String? {
        let b = [UInt8](head.prefix(512))
        func starts(_ bytes: [UInt8]) -> Bool { b.count >= bytes.count && Array(b[0..<bytes.count]) == bytes }
        if starts([0x25, 0x50, 0x44, 0x46]) { return "pdf" }                        // %PDF
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "gif" }                        // GIF8
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "zip" }                        // PK
        if b.count >= 12, Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70] {            // ftyp
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        let text = String(decoding: b, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .lowercased()
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { return "html" }
        return nil
    }
}

/// Copies sources into the staging folder, off the main actor.
enum StagingIO {
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Moves (downloads Nib owns) or copies `source` into `dir` as `name`. File URLs are read through
    /// `NSFileCoordinator`, so Files providers (iCloud Drive, OneDrive…) download them first. No size limit: files are
    /// copied on disk, never read into memory here. Returns the copy and, when asked, a bookmark of the source.
    static func copy(_ source: URL, to dir: URL, name: String, move: Bool, coordinated: Bool,
                     bookmark wantsBookmark: Bool) throws -> (url: URL, bookmark: Data?) {
        let fm = FileManager.default
        let dest = ImportNaming.unique(name, in: dir)
        func unreadable(_ error: Error) -> NibError {
            NibError(.unavailable, "Nib couldn't read \(source.lastPathComponent): \(error.localizedDescription)",
                     hint: "choose the file again with import.pick (Files picker)")
        }
        if move {
            do { try fm.moveItem(at: source, to: dest) } catch { throw unreadable(error) }
            return (dest, nil)
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let bookmark = wantsBookmark
            ? try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        guard coordinated else {
            guard fm.fileExists(atPath: source.path) else { throw NibError.notFound("file \(source.lastPathComponent)") }
            do { try fm.copyItem(at: source, to: dest) } catch { throw unreadable(error) }
            return (dest, bookmark)
        }
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [.withoutChanges],
                                                         error: &coordinatorError) { readable in
            do { try fm.copyItem(at: readable, to: dest) } catch { copyError = error }
        }
        if let failure = (coordinatorError as Error?) ?? copyError {
            if !fm.fileExists(atPath: source.path) { throw NibError.notFound("file \(source.lastPathComponent)") }
            throw unreadable(failure)
        }
        return (dest, bookmark)
    }
}

/// This import's scratch folder (tmp/NibImport/<uuid>); removed when the import ends.
final class ImportStaging {
    let root: URL

    init() throws {
        root = ImportLocations.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Resolves the source through `ctx.inputFile` (tmp: refs, https downloads, file:// for the user or the inboxes)
    /// and copies it here under its display name, naming extension-less files after their content.
    @MainActor
    func stage(_ source: ImportSource, index: Int, ctx: CommandContext,
               hasImporter: (URL) -> Bool) async throws -> StagedFile {
        if let local = source.local {
            return StagedFile(source: source, url: local, isDirectory: StagingIO.isDirectory(local))
        }
        let resolved: URL
        do {
            resolved = try await ctx.inputFile(source.original)
        } catch var e as NibError {
            if e.path == nil { e.path = "$.urls[\(index)]" }
            throw e
        }
        let scheme = URL(string: source.original)?.scheme?.lowercased()
        let downloaded = scheme == "https" || scheme == "http"
        let isFile = scheme == "file"
        let external = isFile && !ImportLocations.isInsideApp(resolved)
        let dir = try directory(String(index))
        let name = source.name
        let staged = try await Task.detached(priority: .userInitiated) { () throws -> (url: URL, bookmark: Data?) in
            try StagingIO.copy(resolved, to: dir, name: name, move: downloaded, coordinated: isFile, bookmark: external)
        }.value
        var url = staged.url
        let isDirectory = StagingIO.isDirectory(url)
        if !isDirectory, url.pathExtension.isEmpty || !hasImporter(url), let sniffed = ContentSniffer.sniff(url),
           sniffed != url.pathExtension.lowercased() {
            let renamed = ImportNaming.unique(url.lastPathComponent + "." + sniffed, in: dir)
            try FileManager.default.moveItem(at: url, to: renamed)
            url = renamed
        }
        // A downloaded web page imports from its live address, so its styles and images load.
        if downloaded, ["html", "htm"].contains(url.pathExtension.lowercased()), let page = URL(string: source.original) {
            url = try WebLocation.write(page, title: (url.lastPathComponent as NSString).deletingPathExtension, in: dir)
        }
        return StagedFile(source: source, url: url, isDirectory: isDirectory, bookmark: staged.bookmark)
    }
}

// MARK: - Host lookup

/// Maps a command's bus to its app, so importers can read `app.content` (two apps can exist in tests).
@MainActor
enum ImportHost {
    private final class Box {
        weak var app: NibApp?
        init(_ app: NibApp) { self.app = app }
    }

    private static var apps: [ObjectIdentifier: Box] = [:]

    static func attach(_ app: NibApp) {
        apps = apps.filter { $0.value.app != nil }
        apps[ObjectIdentifier(app.bus)] = Box(app)
    }

    static func app(for ctx: CommandContext) -> NibApp? {
        apps[ObjectIdentifier(ctx.bus)]?.app ?? NibApp.shared
    }
}

// MARK: - Dispatch

/// Files that one importer call handles: a run of images becomes one notebook (or consecutive pages).
struct ImportGroup: Equatable {
    enum Kind: Equatable {
        case images
        /// A plain folder: its tree is recreated as library folders.
        case folderTree
        case single(importerID: String)
        case unsupported
    }

    var kind: Kind
    var indices: [Int]
}

@MainActor
enum ImportEngine {
    /// Paths of file:// inputs being imported right now; the inbox scan leaves them alone.
    static var inFlight = Set<String>()
    /// Loose files the inbox scan offered (Finder / file-sharing transfers into Documents): removed once imported.
    static var consumableFiles = Set<String>()

    /// The registered importer for a file (by extension, then by UTType conformance). Plain folders have none.
    static func importer(for url: URL, isDirectory: Bool, app: NibApp) -> ImporterDescriptor? {
        let ext = url.pathExtension.lowercased()
        if isDirectory && !PackageImporter.packageExtensions.contains(ext) { return nil }
        if !ext.isEmpty, let d = app.content.importer(forExtension: ext) { return d }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return importer(conformingTo: type, app: app)
    }

    /// The first importer (registry order) whose declared types `type` conforms to.
    static func importer(conformingTo type: UTType, app: NibApp) -> ImporterDescriptor? {
        app.content.importers.all.first { d in
            d.utTypes.contains { id in UTType(id).map { type.conforms(to: $0) } ?? false }
        }
    }

    /// True when Nib can import the item by itself (inbox scan): packages and files with an importer.
    static func canImport(_ url: URL, isDirectory: Bool, app: NibApp) -> Bool {
        if isDirectory { return PackageImporter.isPackage(url) }
        return importer(for: url, isDirectory: false, app: app) != nil
    }

    /// Groups files for dispatch: consecutive images handled by Nib's own image importer share one call.
    static func groups(_ files: [(url: URL, isDirectory: Bool)], app: NibApp) -> [ImportGroup] {
        var out: [ImportGroup] = []
        for (i, f) in files.enumerated() {
            let kind: ImportGroup.Kind
            if f.isDirectory && !PackageImporter.isPackage(f.url) {
                kind = .folderTree
            } else if let d = importer(for: f.url, isDirectory: f.isDirectory, app: app) {
                kind = d.id == ImageImporter.id && d.owner == FeatImportFeature.id ? .images : .single(importerID: d.id)
            } else {
                kind = .unsupported
            }
            if kind == .images, var last = out.last, last.kind == .images {
                last.indices.append(i)
                out[out.count - 1] = last
            } else {
                out.append(ImportGroup(kind: kind, indices: [i]))
            }
        }
        return out
    }

    /// Runs one group into `target`. Returns the documents created or changed.
    static func run(_ group: ImportGroup, urls: [URL], target: ImportTarget, ids: inout [String], ctx: CommandContext,
                    app: NibApp) async throws -> [DocumentID] {
        switch group.kind {
        case .images:
            return try await ImageImporter.importImages(urls, target: target, ids: &ids, ctx: ctx).documents
        case .folderTree:
            guard target.document == nil else {
                throw NibError(.unsupported, "a folder can only be imported as new documents",
                               hint: "leave out doc to recreate the folder in the library")
            }
            return try await PackageImporter.importFolder(urls[0], into: target.folder, ctx: ctx)
        case .single(let id):
            guard let d = app.content.importers.get(id) else { throw NibError.unavailable("the \(id) importer") }
            return try await d.handler(urls[0], target, ctx)
        case .unsupported:
            let ext = urls[0].pathExtension.lowercased()
            let known = Set(app.content.importers.all.flatMap { $0.fileExtensions }).sorted().joined(separator: ", ")
            throw NibError(.unsupported, ext.isEmpty ? "Nib can't tell what kind of file \(urls[0].lastPathComponent) is"
                                                     : "Nib can't import .\(ext) files",
                           hint: "supported: \(known), folders and zipped folders")
        }
    }

    /// The whole of `import.files`: expand the share hand-off, ask where (user, no destination), stage, dispatch,
    /// advance the insertion point file by file, keep import-in-place bookmarks and consume inbox copies.
    static func perform(_ sources: [ImportSource], destination: ImportDestination?, ids: [String]?, ctx: CommandContext,
                        dialog: ImportDialogSession? = nil, reveal: Bool = false) async throws -> ImportResult {
        if let ids = ids {
            for (i, s) in ids.enumerated() where !NibID.isValid(s) {
                throw NibError.invalid("ids must be 1-64 characters of A-Z, a-z, 0-9, _ or -", path: "$.ids[\(i)]")
            }
        }
        guard let app = ImportHost.app(for: ctx) else { throw NibError.unavailable("import") }
        let library = try ctx.services.require(ctx.services.library, "the library")
        let staging = try ImportStaging()
        defer { staging.cleanUp() }

        var sources = try expandHandoff(sources, staging: staging, ctx: ctx)
        var destination = destination
        var session = dialog
        if destination == nil, session == nil, ctx.principal.isUser, !ctx.dryRun, let nav = await ImportUI.navigator(app) {
            let ask = ImportDialogSession(app: app, navigator: nav, session: ctx.activeSession, sources: sources, preset: nil)
            guard let choice = await ask.choose() else {
                for s in sources { consumeInboxCopy(s.original) }                  // a declined Open In leaves nothing behind
                return .cancelledResult
            }
            destination = choice.destination
            sources = choice.order.map { sources[$0] }
            session = ask
        }
        defer { session?.close() }
        var dest = destination ?? .libraryRoot
        try validate(&dest, library: library, ctx: ctx)
        if ctx.dryRun { return ImportResult(refs: []) }                           // library writes cannot be rolled back

        let paths = sources.compactMap { URL(string: $0.original) }.filter { $0.isFileURL }.map { $0.standardizedFileURL.path }
        inFlight.formUnion(paths)
        defer { inFlight.subtract(paths) }

        let total = Double(max(sources.count, 1) * 2)
        var failures: [(ImportFailure, NibError)] = []
        var staged: [StagedFile] = []
        for (i, s) in sources.enumerated() where session?.isCancelled != true {
            session?.progress(Double(i) / total, label: ImportUI.progressLabel(s.name, index: i, count: sources.count))
            do {
                staged.append(try await staging.stage(s, index: i, ctx: ctx) { url in
                    importer(for: url, isDirectory: false, app: app) != nil
                })
            } catch {
                failures.append(failure(s.original, error))
            }
        }

        var refs: [String] = []
        var pageRefs: [String] = []
        var created: [DocumentID] = []
        var idQueue = ids ?? []
        var done = 0
        for group in groups(staged.map { (url: $0.url, isDirectory: $0.isDirectory) }, app: app) {
            if session?.isCancelled == true { break }
            let files = group.indices.map { staged[$0] }
            session?.progress((Double(sources.count) + Double(done)) / total,
                              label: ImportUI.progressLabel(files[0].source.name, index: done, count: staged.count))
            let before = dest.doc.flatMap { d in try? ctx.workspace.content(d).livePages.map { $0.id } } ?? []
            do {
                let docs = try await run(group, urls: files.map { $0.url }, target: dest.target, ids: &idQueue, ctx: ctx, app: app)
                for d in docs where !refs.contains(NodeRef.document(d).description) {
                    refs.append(NodeRef.document(d).description)
                }
                if let d = dest.doc {
                    let known = Set(before)
                    let added = ((try? ctx.workspace.content(d).livePages.map { $0.id }) ?? []).filter { !known.contains($0) }
                    pageRefs += added.map { NodeRef.page(d, $0).description }
                    if let last = added.last {                                     // the next file follows this one
                        dest.position = .after
                        dest.anchor = last
                    }
                } else {
                    created += docs
                    rememberSource(files, docs: docs, ctx: ctx)
                }
                for f in files { consumeImported(f.source.original) }
            } catch {
                for f in files { failures.append(failure(f.source.original, error)) }
            }
            done += files.count
        }

        let failed = failures.map { $0.0 }
        if refs.isEmpty, session == nil, let first = failures.first {
            var e = first.1
            if failures.count > 1 { e.message = "none of the \(failures.count) files could be imported; first: " + e.message }
            throw e
        }
        let result = ImportResult(refs: refs, pages: dest.doc == nil ? nil : pageRefs,
                                  failed: failed.isEmpty ? nil : failed)
        if let session = session {
            session.finish(imported: refs.isEmpty ? 0 : max(created.count, pageRefs.count, 1), failures: failed)
        } else if ctx.principal.isUser, !failed.isEmpty {
            ImportUI.reportPartialFailure(failed, app: app)
        }
        if reveal || session != nil {
            await revealResult(result, created: created, destination: dest, ctx: ctx)
        }
        return result
    }

    // MARK: Steps

    /// Replaces the share-extension hand-off link (nib://import?from=pasteboard) by the files on the pasteboard.
    private static func expandHandoff(_ sources: [ImportSource], staging: ImportStaging,
                                      ctx: CommandContext) throws -> [ImportSource] {
        var out: [ImportSource] = []
        for s in sources {
            guard ShareHandoff.isHandoffLink(s.original) else {
                out.append(s)
                continue
            }
            guard ctx.principal.isUser else {
                throw NibError(.permissionDenied, "only the user can import what another app shared through the pasteboard")
            }
            let urls = try ShareHandoff.take(into: try staging.directory("handoff"))
            out += urls.map { ImportSource(original: $0.absoluteString, name: $0.lastPathComponent, local: $0) }
        }
        return out
    }

    private static func validate(_ dest: inout ImportDestination, library: LibraryService, ctx: CommandContext) throws {
        if let f = dest.folder, library.node(f)?.kind != .folder {
            throw NibError(.notFound, "folder \(f.raw) not found", path: "$.folder",
                           hint: "call library.list for folder refs, or pass \"lib\" for the library root")
        }
        guard let d = dest.doc else { return }
        let content: DocumentContent
        do {
            content = try ctx.workspace.content(d)
        } catch {
            throw NibError(.notFound, "document \(d.raw) not found", path: "$.doc", hint: "call library.list for document refs")
        }
        if dest.anchor == nil, dest.position == .before || dest.position == .after,
           let s = ctx.activeSession, s.document == d, let page = s.page {
            dest.anchor = page
        }
        if let a = dest.anchor, content.pageIndex(a) == nil {
            throw NibError(.notFound, "page \(a.raw) not found in document \(d.raw)", path: "$.anchor",
                           hint: "call query.get {\"ref\": \"doc:\(d.raw)\"} for its pages")
        }
    }

    /// Import-in-place: a PDF opened from a Files provider keeps a bookmark to its source, so "Save changes to
    /// source" (export.saveToSource) can write the annotated PDF back.
    private static func rememberSource(_ files: [StagedFile], docs: [DocumentID], ctx: CommandContext) {
        guard files.count == 1, docs.count == 1, let bookmark = files[0].bookmark,
              files[0].url.pathExtension.lowercased() == "pdf" else { return }
        do {
            try ctx.mutate(String(localized: "Link to Source"), undoable: false) { tx in
                var meta = try tx.content(docs[0]).meta
                meta.sourceBookmark = bookmark
                try tx.putMeta(meta)
            }
        } catch {
            importLog.error("could not keep the source bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open In copies (Documents/Inbox) and share-extension files (App Group inbox) belong to Nib once seen.
    static func consumeInboxCopy(_ original: String) {
        guard let url = URL(string: original), url.isFileURL, ImportLocations.isInConsumableInbox(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// After a successful import: inbox copies, plus loose Documents files the inbox scan offered, are removed.
    private static func consumeImported(_ original: String) {
        consumeInboxCopy(original)
        guard let url = URL(string: original), url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        guard consumableFiles.remove(path) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Shows what arrived: goes to the first new page, or opens the one new document.
    private static func revealResult(_ result: ImportResult, created: [DocumentID], destination: ImportDestination,
                                     ctx: CommandContext) async {
        if let doc = destination.doc, let first = result.pages?.first {
            if ctx.activeSession?.document == doc {
                _ = try? await ctx.execute(CommandIDs.viewGoToPage, ["page": .string(first)])
            } else {
                _ = try? await ctx.execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(doc).description),
                                                                "page": .string(first)])
            }
        } else if created.count == 1 {
            _ = try? await ctx.execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(created[0]).description)])
        }
    }

    private static func failure(_ original: String, _ error: Error) -> (ImportFailure, NibError) {
        let e = NibError.wrap(error)
        return (ImportFailure(url: original, code: e.code.rawValue, message: e.message), e)
    }
}

// MARK: - Commands

/// `import.files {urls, folder?, doc?, position?, anchor?, ids?}` (library).
struct ImportFiles: NibCommand {
    struct Params: Codable {
        var urls: [String]
        var folder: String?
        var doc: String?
        var position: String?
        var anchor: String?
        var ids: [String]?
    }

    typealias Output = ImportResult

    static let descriptor: CommandDescriptor = {
        let toFolder: JSONValue = ["urls": ["tmp:lecture.pdf"], "folder": "folder:FIXTUREFLD01"]
        let intoNotebook: JSONValue = ["urls": ["tmp:scan.png", "tmp:notes.png"], "doc": "doc:FIXTUREDOC01",
                                       "position": "after", "anchor": "page:FIXTUREDOC01/FIXTUREPG001"]
        return CommandDescriptor(
            id: "import.files", title: "Import Files",
            summary: "Import files (PDF, images, Word, PowerPoint, web pages, .nibnote, zipped folders, backups, CSV/TXT, plugins) as new documents in a folder, or as pages into a notebook.",
            params: .obj([
                "urls": .arr(.str("tmp:<name> from asset.upload, an https URL, or file:// (user only)")),
                "folder": .str("folder:F (or \"lib\" for the library root) for new documents"),
                "doc": .str("doc:D: insert pages into this notebook instead of creating documents"),
                "position": .str("where the pages go in doc (default end; after when anchor is given)",
                                 choices: PagePosition.allCases.map { $0.rawValue }),
                "anchor": .str("page:D/P that position is relative to (default: the current page)"),
                "ids": .arr(.str(), "caller-chosen ids, in creation order, for new image notebooks or inserted image pages")
            ], required: ["urls"]),
            examples: [toFolder, intoNotebook],
            effect: .library, target: .library)
    }()

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> ImportResult {
        guard !p.urls.isEmpty else { throw NibError.invalid("'urls' must list at least one file", path: "$.urls") }
        let destination = try ImportDestination.parse(folder: p.folder, doc: p.doc, position: p.position, anchor: p.anchor)
        return try await ImportEngine.perform(p.urls.map { ImportSource(original: $0) }, destination: destination,
                                              ids: p.ids, ctx: ctx)
    }
}

/// `import.pick {target?}` (library, user presence): the Files picker, then the same engine as `import.files`.
struct ImportPick: NibCommand {
    struct Params: Codable {
        var target: String?
    }

    typealias Output = ImportResult

    static let descriptor = CommandDescriptor(
        id: "import.pick", title: "Import Files",
        summary: "Show the Files picker and import the chosen files: target folder:F or lib (new documents), doc:D or page:D/P (insert pages); omitted asks where.",
        params: .obj(["target": .str("lib, folder:F, doc:D (pages at the end) or page:D/P (pages after it); omitted = ask")]),
        examples: [["target": "folder:FIXTUREFLD01"]],
        effect: .library, target: .library, userPresence: true)

    static func parseTarget(_ target: String?) throws -> ImportDestination? {
        guard let t = target?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t == "lib" || t == "library" { return .libraryRoot }
        switch NodeRef(t) {
        case .folder(let f)?: return ImportDestination(folder: f)
        case .document(let d)?: return ImportDestination(doc: d, position: .end)
        case .page(let d, let p)?: return ImportDestination(doc: d, position: .after, anchor: p)
        default: throw NibError.invalid("'target' must be lib, folder:F, doc:D or page:D/P", path: "$.target")
        }
    }

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> ImportResult {
        let preset = try parseTarget(p.target)
        guard !NibApp.isHostlessTest, let app = ImportHost.app(for: ctx), let nav = await ImportUI.navigator(app) else {
            throw NibError(.unavailable, "the Files picker needs a window", hint: "call import.files with urls instead")
        }
        let picked = await DocumentPicker.pick(types: ImportUI.pickerTypes(app), navigator: nav)
        guard !picked.isEmpty else { return .cancelledResult }
        // Picked files stay readable while the import runs (the engine opens them again from their paths).
        let access = picked.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (url, granted) in access where granted { url.stopAccessingSecurityScopedResource() } }
        var sources = picked.map { ImportSource(original: $0.absoluteString) }
        var destination = preset
        var dialog: ImportDialogSession?
        if preset == nil || (preset?.doc != nil && picked.count > 1) {
            let ask = ImportDialogSession(app: app, navigator: nav, session: ctx.activeSession, sources: sources, preset: preset)
            guard let choice = await ask.choose() else { return .cancelledResult }
            destination = choice.destination
            sources = choice.order.map { sources[$0] }
            dialog = ask
        }
        return try await ImportEngine.perform(sources, destination: destination ?? .libraryRoot, ids: nil, ctx: ctx,
                                              dialog: dialog, reveal: true)
    }
}
