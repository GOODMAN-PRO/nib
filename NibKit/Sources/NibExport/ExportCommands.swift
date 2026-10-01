import Foundation
import UniformTypeIdentifiers
import NibContracts

// MARK: - export.run

/// `export.run {docs, pages?, format, options?, inline?, name?}` → `{files: [{name, asset: "tmp:<name>", bytes, type,
/// base64?}]}`. Every exported file is handed out as a temporary asset (the bridge serves them as
/// /api/v1/assets/<token>), never as a file URL; `inline: true` adds base64 while the files total at most 20 MB.
struct ExportRun: NibCommand {
    struct Params: Codable {
        /// Document refs (doc:D or bare ids), folder:F (every document inside, keeping the tree for "zip") or lib.
        /// The user may leave it out: the invoking window's document.
        var docs: [String]?
        /// Page refs: only these pages of their documents (documents with none listed export whole).
        var pages: [String]?
        var format: String
        var options: JSONValue?
        var inline: Bool?
        /// File name without extension for a single file (or the zip).
        var name: String?
    }

    struct File: Codable, Equatable {
        var name: String
        var asset: String
        var bytes: Int
        var type: String?
        var base64: String?
    }

    struct Output: Codable {
        var files: [File]
        /// True when `inline` was asked for but the files exceed the inline limit; fetch the tmp: assets instead.
        var inlineOmitted: Bool?
    }

    /// Total size base64 is returned for (`inline: true`).
    static let inlineLimit = 20 * 1_048_576

    static let descriptor = CommandDescriptor(
        id: "export.run", title: "Export",
        summary: "Export documents or pages as pdf (editable/flattened), png/jpeg, nibnote or zip → {files: [{name, asset: tmp:…, base64?}]}; inline adds base64 (≤ 20 MB).",
        params: .obj([
            "docs": .arr(.ref, "documents to export (doc:D); folder:F or lib exports every document inside"),
            "pages": .arr(.ref, "only these pages (page:D/P); documents without listed pages export whole"),
            "format": .str("exporter id: pdf, png, jpeg, nibnote, zip, or a registered one such as textdoc.pdf or study.csv"),
            "options": ExportOptions.schema,
            "inline": .bool("also return each file as base64 (20 MB total at most)"),
            "name": .str("file name without extension (single file or the zip)"),
        ], required: ["docs", "format"]),
        examples: [
            try! JSONValue.parse(#"{"docs": ["doc:FIXTUREDOC01"], "format": "pdf"}"#),
            try! JSONValue.parse(#"{"docs": ["doc:FIXTUREDOC01"], "pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "format": "png", "options": {"scale": 2}, "inline": true}"#),
            try! JSONValue.parse(#"{"docs": ["doc:FIXTUREDOC01"], "format": "pdf", "options": {"mode": "editable", "stickyNotes": "icon", "comments": true}}"#),
            try! JSONValue.parse(#"{"docs": ["doc:FIXTUREDOC04"], "format": "pdf", "options": {"board": "tiled"}}"#),
            try! JSONValue.parse(#"{"docs": ["doc:FIXTUREDOC01"], "format": "nibnote"}"#),
        ],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let format = p.format.trimmingCharacters(in: .whitespaces)
        guard !format.isEmpty else {
            throw NibError(.invalidParams, "format must not be empty", path: "$.format", hint: ExportDispatch.formatsHint(ctx))
        }
        let options = try ExportOptions(p.options ?? [:])
        var scope = try ExportScope.resolve(docs: p.docs, pages: p.pages, ctx: ctx)
        if scope.docs.count > 1, options.pageRange != nil {
            scope.docs = try scope.docs.filter {
                try !ExportPages.rangeSkips(ctx.workspace.peekContent($0), pages: scope.pages, range: options.pageRange)
            }
            guard !scope.docs.isEmpty else { throw ExportPages.nothingInRange(options.pageRange) }
        }
        let groups = try ExportDispatch.plan(format: format, scope: scope, ctx: ctx)
        // The built-in exporters close each document they opened as soon as they are done with it; this also closes
        // the ones any other exporter opened and left open.
        let uses = scope.docs.map { ExportDocumentUse($0, ctx: ctx) }
        var urls: [URL] = []
        defer {
            ExportDelivery.discard(urls)
            for use in uses { use.end() }
        }
        for group in groups {
            let request = ExportRequest(documents: group.docs, pages: scope.pages, options: options.raw,
                                        fileName: groups.count == 1 ? p.name : nil)
            let produced = try await group.exporter.handler(request, ctx)
            urls += produced
        }
        guard !urls.isEmpty else { throw NibError(.internalError, "the \(format) exporter produced no file") }
        return try await ExportDelivery.deliver(urls, inline: p.inline ?? false, ctx: ctx)
    }
}

// MARK: - Scope

/// What `docs` and `pages` name: documents in order (folders expanded, duplicates dropped), the page filter, and
/// each document's kind. Documents are checked with `Workspace.peekContent`, so resolving a folder or the whole
/// library opens none of them.
struct ExportScope {
    var docs: [DocumentID]
    var pages: [PageID]?
    var kinds: [DocumentID: DocumentKind] = [:]

    @MainActor
    static func resolve(docs refs: [String]?, pages pageRefs: [String]?, ctx: CommandContext) throws -> ExportScope {
        var docs: [DocumentID] = []
        var seen = Set<DocumentID>()
        func add(_ doc: DocumentID) {
            if seen.insert(doc).inserted { docs.append(doc) }
        }
        func refuseLocked(_ doc: DocumentID, path: String) throws {
            if ctx.services.lock?.isLocked(doc) == true {
                throw NibError(.locked, "doc:\(doc.raw) is locked", path: path, hint: "unlock the document, then export it again")
            }
        }
        var heads: [DocumentID: DocumentContent] = [:]
        func head(_ doc: DocumentID) throws -> DocumentContent {
            if let h = heads[doc] { return h }
            let h = try ctx.workspace.peekContent(doc)
            heads[doc] = h
            return h
        }
        var pageIDs: [PageID]?
        if let pageRefs = pageRefs {
            var ids: [PageID] = []
            for (i, ref) in pageRefs.enumerated() {
                guard case let .page(doc, page)? = NodeRef(ref) else {
                    throw NibError(.invalidParams, "expected a page ref (page:D/P)", path: "$.pages[\(i)]")
                }
                try refuseLocked(doc, path: "$.pages[\(i)]")
                guard let record = try? head(doc).page(page), !record.deleted else {
                    throw NibError(.notFound, "page \(page.raw) not found in doc:\(doc.raw)", path: "$.pages[\(i)]",
                                   hint: "list the pages with query.get {\"ref\": \"doc:\(doc.raw)\"}")
                }
                ids.append(page)
                if refs == nil { add(doc) }
            }
            pageIDs = ids
        }
        if let refs = refs {
            for ref in refs {
                switch NodeRef(ref) {
                case .library?:
                    for node in (ctx.services.library?.allNodes() ?? []) where node.kind == .document { add(node.id) }
                case .folder(let folder)?:
                    for doc in documents(in: folder, ctx: ctx) { add(doc) }
                default:
                    add(NodeRef.documentID(from: ref))
                }
            }
        } else if pageRefs == nil {
            add(try ctx.documentOrSession(nil, field: "docs"))
        }
        guard !docs.isEmpty else {
            throw NibError(.invalidParams, "nothing to export", path: "$.docs", hint: "pass document refs such as doc:D")
        }
        var kinds: [DocumentID: DocumentKind] = [:]
        for (i, doc) in docs.enumerated() {
            try refuseLocked(doc, path: "$.docs[\(i)]")
            do {
                kinds[doc] = try (heads[doc] ?? ctx.workspace.peekContent(doc)).meta.kind
            } catch let e as NibError where e.code == .notFound {
                throw NibError(.notFound, "document \(doc.raw) not found", path: "$.docs[\(i)]",
                               hint: "list documents with query.tree {\"ref\": \"lib\"}")
            }
        }
        return ExportScope(docs: docs, pages: pageIDs, kinds: kinds)
    }

    /// Every document under `folder` (sub-folders included), in library order.
    @MainActor
    static func documents(in folder: FolderID, ctx: CommandContext) -> [DocumentID] {
        guard let library = ctx.services.library else { return [] }
        var out: [DocumentID] = []
        var queue: [FolderID] = [folder]
        var visited = Set<FolderID>()
        while let f = queue.first {
            queue.removeFirst()
            guard visited.insert(f).inserted else { continue }
            for node in library.children(of: f) {
                switch node.kind {
                case .document: out.append(node.id)
                case .folder: queue.append(node.id)
                }
            }
        }
        return out
    }
}

// MARK: - Dispatch

/// Picks, per document kind, the exporter for a format: an exporter whose id is the format and whose `docKinds` take
/// the kind; else one with that file extension for the kind ("pdf" of a text document → "textdoc.pdf").
@MainActor
enum ExportDispatch {
    struct Group {
        var exporter: ExporterDescriptor
        var docs: [DocumentID]
    }

    static func exporter(_ format: String, for kind: DocumentKind, in exporters: [ExporterDescriptor]) -> ExporterDescriptor? {
        let f = format.lowercased()
        func takes(_ e: ExporterDescriptor) -> Bool { e.docKinds.map { $0.contains(kind) } ?? true }
        if let e = exporters.first(where: { $0.id.lowercased() == f && takes($0) }) { return e }
        let byExtension = exporters.filter { $0.fileExtension.lowercased() == f && takes($0) }
        return byExtension.first { $0.docKinds != nil } ?? byExtension.first
    }

    /// Groups documents by the exporter that handles them, in first-appearance order.
    static func plan(format: String, scope: ExportScope, ctx: CommandContext) throws -> [Group] {
        let exporters = ctx.content.exporters.all
        let known = exporters.contains { $0.id.lowercased() == format.lowercased() || $0.fileExtension.lowercased() == format.lowercased() }
        guard known else {
            throw NibError(.invalidParams, "unknown export format '\(format)'", path: "$.format", hint: formatsHint(ctx))
        }
        var groups: [Group] = []
        for doc in scope.docs {
            if ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "doc:\(doc.raw) is locked") }
            let kind = try scope.kinds[doc] ?? ctx.workspace.peekContent(doc).meta.kind
            guard let exporter = exporter(format, for: kind, in: exporters) else {
                let usable = exporters.filter { $0.docKinds.map { $0.contains(kind) } ?? true }.map { $0.id }
                throw NibError(.unsupported, "format '\(format)' cannot export a \(kind.rawValue) (doc:\(doc.raw))",
                               path: "$.format", hint: "formats for a \(kind.rawValue): " + usable.joined(separator: ", "))
            }
            if let i = groups.firstIndex(where: { $0.exporter.id == exporter.id }) {
                groups[i].docs.append(doc)
            } else {
                groups.append(Group(exporter: exporter, docs: [doc]))
            }
        }
        return groups
    }

    static func formatsHint(_ ctx: CommandContext) -> String {
        "available formats: " + ctx.content.exporters.all.map { $0.id }.joined(separator: ", ")
    }
}

// MARK: - Delivery

enum ExportDelivery {
    /// Stores every file as a temporary asset (and base64 when asked and small enough).
    @MainActor
    static func deliver(_ urls: [URL], inline: Bool, ctx: CommandContext) async throws -> ExportRun.Output {
        let assets = try ctx.services.require(ctx.services.assets, "the asset store")
        let limit = ExportRun.inlineLimit
        let stored: [(file: ExportRun.File, data: Data?)] = try await ExportWorker.run {
            var used = Set<String>()
            var total = 0
            var out: [(file: ExportRun.File, data: Data?)] = []
            for url in urls {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                total += data.count
                let ext = url.pathExtension.lowercased()
                let base = url.deletingPathExtension().lastPathComponent
                let name = ExportNames.unique(base, ext: ext, used: &used)
                let ref = try assets.putTemporary(data, ext: ext.isEmpty ? "bin" : ext)
                let type = UTType(filenameExtension: ext)?.identifier
                out.append((ExportRun.File(name: name, asset: "tmp:" + ref.name, bytes: data.count, type: type),
                            inline && total <= limit ? data : nil))
            }
            if inline && total > limit {
                return out.map { ($0.file, nil) }
            }
            return out
        }
        var files: [ExportRun.File] = []
        var omitted = false
        for entry in stored {
            var file = entry.file
            if inline {
                if let data = entry.data { file.base64 = data.base64EncodedString() } else { omitted = true }
            }
            files.append(file)
        }
        return ExportRun.Output(files: files, inlineOmitted: omitted ? true : nil)
    }

    /// Removes the exporters' temporary files (their bytes now live in the asset store) and empty folders they left.
    /// Only files inside the temporary directory are removed: an exporter that hands back an existing file (a document
    /// asset, an imported source) never loses it.
    static func discard(_ urls: [URL]) {
        let fm = FileManager.default
        var folders = Set<URL>()
        for url in urls where isTemporary(url) {
            try? fm.removeItem(at: url)
            folders.insert(url.deletingLastPathComponent())
        }
        // Only an exporter's own (now empty) folder inside the temporary directory, never that directory itself.
        for folder in folders {
            guard isTemporary(folder), (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false else { continue }
            try? fm.removeItem(at: folder)
        }
    }

    /// True when `url` resolves to a path strictly inside the temporary directory.
    static func isTemporary(_ url: URL) -> Bool {
        let temporary = resolved(FileManager.default.temporaryDirectory)
        let path = resolved(url)
        return path.hasPrefix(temporary + "/") && path != temporary
    }

    private static func resolved(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
