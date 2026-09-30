import Foundation
import UniformTypeIdentifiers
import os
import NibContracts

/// Export engine (F066): the `export.run` command and the built-in exporters in `content.exporters`:
/// "pdf" (vector pages through `UIGraphicsPDFRenderer`, editable or flattened, boards as one tall page or tiled A4),
/// "png" / "jpeg" (one image per page at 2× or 3×), "nibnote" (the document package zipped, audio and comments
/// included) and "zip" (documents in their library folder tree). Other features and plugins add exporters of their
/// own ("textdoc.pdf", "study.csv"); `export.run` picks the one that handles each document's kind (`docKinds`).
public enum NibExportFeature: NibFeature {
    public static let id = "export"

    public static func register(_ app: NibApp) {
        app.commands.register(ExportRun.self)
        for exporter in NibExporters.all(owner: id) { app.content.exporters.register(exporter) }
    }
}

// MARK: - Built-in exporters

enum ExportFormat {
    static let pdf = "pdf"
    static let png = "png"
    static let jpeg = "jpeg"
    static let nibnote = "nibnote"
    static let zip = "zip"
    static let builtIn = [pdf, png, jpeg, nibnote, zip]
}

@MainActor
enum NibExporters {
    static func all(owner: String) -> [ExporterDescriptor] {
        var pdf = ExporterDescriptor(id: ExportFormat.pdf, title: String(localized: "PDF"), fileExtension: "pdf",
                                     utType: UTType.pdf.identifier, order: 10, owner: owner) { request, ctx in
            try await PDFExporter.export(request, ctx)
        }
        pdf.docKinds = [.notebook, .whiteboard]
        var png = ExporterDescriptor(id: ExportFormat.png, title: String(localized: "PNG Images"), fileExtension: "png",
                                     utType: UTType.png.identifier, order: 20, owner: owner) { request, ctx in
            try await ImageExporter.export(request, ctx, format: .png)
        }
        png.docKinds = [.notebook, .whiteboard]
        var jpeg = ExporterDescriptor(id: ExportFormat.jpeg, title: String(localized: "JPEG Images"), fileExtension: "jpg",
                                      utType: UTType.jpeg.identifier, order: 30, owner: owner) { request, ctx in
            try await ImageExporter.export(request, ctx, format: .jpeg)
        }
        jpeg.docKinds = [.notebook, .whiteboard]
        var nibnote = ExporterDescriptor(id: ExportFormat.nibnote, title: String(localized: "Nib Document"),
                                         fileExtension: "zip", utType: UTType.zip.identifier, order: 40,
                                         owner: owner) { request, ctx in
            try await PackageExporter.exportPackages(request, ctx)
        }
        nibnote.docKinds = Set(DocumentKind.allCases)
        var zip = ExporterDescriptor(id: ExportFormat.zip, title: String(localized: "Zipped Folder"), fileExtension: "zip",
                                     utType: UTType.zip.identifier, order: 50, owner: owner) { request, ctx in
            try await PackageExporter.exportFolderTree(request, ctx)
        }
        zip.docKinds = Set(DocumentKind.allCases)
        return [pdf, png, jpeg, nibnote, zip]
    }
}

// MARK: - Options

enum PDFMode: String, CaseIterable {
    /// Ink, text boxes, links and comments stay PDF annotations other apps can edit; the source outline is kept.
    case editable
    /// Everything drawn into the page content (plus an optional invisible recognised-text layer); links stay.
    case flattened
}

enum StickyExport: String, CaseIterable {
    /// Each note as it is on the page.
    case asIs
    /// Every note printed open, text included.
    case expanded
    /// Every note printed as its small icon.
    case icon
}

enum BoardLayout: String, CaseIterable {
    /// The board's content bounds as one (often tall) page.
    case single
    /// The content bounds cut into paper-sized tiles at 1:1, row by row.
    case tiled
}

/// `ExportRequest.options` as the built-in exporters read them. `ExportOptionKeys` (visibleLayersOnly, visibleLayers,
/// annotations, background) are shared with the Layers hook and the export dialog; the rest are this engine's own.
struct ExportOptions {
    static let mode = "mode"
    static let comments = "comments"
    static let stickyNotes = "stickyNotes"
    static let pageRange = "pageRange"
    static let searchableText = "searchableText"
    static let scale = "scale"
    static let quality = "quality"
    static let board = "board"
    static let paper = "paper"
    static let itemFormat = "itemFormat"
    static let audio = "audio"
    static let outline = "outline"

    var mode: PDFMode = .flattened
    /// Page backgrounds (templates, PDFs, images, colours).
    var background = true
    /// `DrawContext.annotations` and link annotations (link marks).
    var annotations = true
    /// Comment threads as PDF text annotations; also keeps comment items in packages.
    var comments = true
    var stickyNotes: StickyExport = .asIs
    var visibleLayersOnly = false
    /// Visible layers per document (raw document id); a document missing from the map keeps every layer.
    var visibleLayers: [DocumentID: Set<Int>] = [:]
    /// "1-3, 5, 8-": 1-based pages of each document (`pages` wins when it names pages of the document).
    var pageRange: String?
    /// Flattened PDFs: an invisible layer of recognised handwriting and scan text, so the PDF is searchable.
    var searchableText = true
    /// Images: pixels per point (2× or 3×; 1…4 accepted).
    var scale: Double = 2
    /// JPEG compression quality 0.1…1.
    var quality: Double = 0.9
    var board: BoardLayout = .single
    /// Tile size for tiled boards.
    var paper: PageSize = .a4
    /// "zip": the format each document is exported in inside the archive.
    var itemFormat = ExportFormat.pdf
    /// "nibnote": include audio recordings and their transcripts.
    var audio = true
    /// Editable PDFs: keep the source PDF outline and the document's own outline as PDF bookmarks.
    var outline = true
    /// The options exactly as given (inner exporters of "zip" receive them unchanged).
    var raw: JSONValue = [:]

    init() {}

    /// Lenient parsing: absent or null keys keep their defaults; a value of the wrong type is `invalid_params`.
    init(_ json: JSONValue) throws {
        raw = json == .null ? [:] : json
        guard case .object(let o) = raw else {
            throw NibError(.invalidParams, "options must be an object", path: "$.options",
                           hint: "e.g. {\"mode\": \"flattened\", \"background\": true}")
        }
        func value(_ key: String) -> JSONValue? {
            guard let v = o[key], v != .null else { return nil }
            return v
        }
        func bool(_ key: String) throws -> Bool? {
            guard let v = value(key) else { return nil }
            guard let b = v.boolValue else { throw NibError(.invalidParams, "expected true or false", path: "$.options." + key) }
            return b
        }
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let v = value(key) else { return nil }
            guard let n = v.doubleValue, range.contains(n) else {
                throw NibError(.invalidParams, "expected a number from \(range.lowerBound) to \(range.upperBound)",
                               path: "$.options." + key)
            }
            return n
        }
        func choice<E: RawRepresentable & CaseIterable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == String {
            guard let v = value(key) else { return nil }
            guard let s = v.stringValue, let e = E(rawValue: s) else {
                throw NibError(.invalidParams, "expected one of: " + E.allCases.map { $0.rawValue }.joined(separator: ", "),
                               path: "$.options." + key)
            }
            return e
        }
        if let m = try choice(ExportOptions.mode, PDFMode.self) { mode = m }
        if let b = try bool(ExportOptionKeys.background) { background = b }
        if let b = try bool(ExportOptionKeys.annotations) { annotations = b }
        if let b = try bool(ExportOptions.comments) { comments = b }
        if let s = try choice(ExportOptions.stickyNotes, StickyExport.self) { stickyNotes = s }
        if let b = try bool(ExportOptionKeys.visibleLayersOnly) { visibleLayersOnly = b }
        if let v = value(ExportOptionKeys.visibleLayers) {
            guard case .object(let map) = v else {
                throw NibError(.invalidParams, "expected {\"<documentID>\": [layer index]}",
                               path: "$.options." + ExportOptionKeys.visibleLayers)
            }
            for (key, list) in map {
                guard let indices = list.arrayValue?.compactMap({ $0.intValue }), indices.count == list.arrayValue?.count else {
                    throw NibError(.invalidParams, "expected an array of layer indices (0-\(NibLimits.layerCount - 1))",
                                   path: "$.options.\(ExportOptionKeys.visibleLayers).\(key)")
                }
                visibleLayers[NodeRef.documentID(from: key)] = Set(indices)
            }
        }
        if let v = value(ExportOptions.pageRange) {
            guard let s = v.stringValue else {
                throw NibError(.invalidParams, "expected a page range such as \"1-3, 5\"", path: "$.options.pageRange")
            }
            pageRange = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
        if let b = try bool(ExportOptions.searchableText) { searchableText = b }
        if let n = try number(ExportOptions.scale, 1...4) { scale = n }
        if let n = try number(ExportOptions.quality, 0.1...1) { quality = n }
        if let b = try choice(ExportOptions.board, BoardLayout.self) { board = b }
        if let v = value(ExportOptions.paper) {
            switch v.stringValue?.lowercased() {
            case "a4"?: paper = .a4
            case "letter"?: paper = .letter
            default: throw NibError(.invalidParams, "expected one of: a4, letter", path: "$.options.paper")
            }
        }
        if let v = value(ExportOptions.itemFormat) {
            guard let s = v.stringValue, !s.isEmpty, s != ExportFormat.zip else {
                throw NibError(.invalidParams, "expected an exporter id other than zip (pdf, png, jpeg, nibnote, …)",
                               path: "$.options.itemFormat")
            }
            itemFormat = s
        }
        if let b = try bool(ExportOptions.audio) { audio = b }
        if let b = try bool(ExportOptions.outline) { outline = b }
    }

    /// The layers drawn for `doc`; nil = every layer.
    func layers(for doc: DocumentID) -> Set<Int>? {
        guard visibleLayersOnly, let set = visibleLayers[doc] else { return nil }
        return set
    }

    static let schema: JSONSchema = .obj([
        ExportOptions.mode: .str("pdf: editable (PDF annotations, outline kept) or flattened (default)",
                                 choices: PDFMode.allCases.map { $0.rawValue }),
        ExportOptionKeys.background: .bool("page backgrounds: templates, PDFs, images (default true)"),
        ExportOptionKeys.annotations: .bool("link marks and other annotations (default true)"),
        ExportOptions.comments: .bool("comments as PDF text annotations (default true)"),
        ExportOptions.stickyNotes: .str("sticky notes as they are (default), all expanded, or all as icons",
                                        choices: StickyExport.allCases.map { $0.rawValue }),
        ExportOptionKeys.visibleLayersOnly: .bool("leave out layers not listed in visibleLayers"),
        ExportOptionKeys.visibleLayers: .anything("{\"<documentID>\": [layer index]} visible layers per document"),
        ExportOptions.pageRange: .str("1-based pages of each document, e.g. \"1-3, 5, 8-\""),
        ExportOptions.searchableText: .bool("flattened pdf: invisible recognised-text layer (default true)"),
        ExportOptions.scale: .num("png/jpeg pixels per point, 2 or 3 (default 2)", min: 1, max: 4),
        ExportOptions.quality: .num("jpeg quality (default 0.9)", min: 0.1, max: 1),
        ExportOptions.board: .str("whiteboards: content bounds as one page (single) or tiled paper pages",
                                  choices: BoardLayout.allCases.map { $0.rawValue }),
        ExportOptions.paper: .str("tile size for tiled boards", choices: ["a4", "letter"]),
        ExportOptions.itemFormat: .str("zip: format of each document inside the archive (default pdf)"),
        ExportOptions.audio: .bool("nibnote: include audio recordings (default true)"),
        ExportOptions.outline: .bool("editable pdf: keep outlines as PDF bookmarks (default true)"),
    ], required: [], "export options")
}

// MARK: - Page selection

enum ExportPages {
    /// The live pages of `content` to export, in document order: the ones in `pages` when it names any of them, else
    /// the 1-based `range`, else all. Throws when nothing is left, except that `skipOutOfRange` (one document of a
    /// multi-document export) returns no pages when the range names none of this document's pages, so the exporter
    /// leaves the document out instead of failing the whole export.
    static func select(_ content: DocumentContent, pages: [PageID]?, range: String?,
                       skipOutOfRange: Bool = false) throws -> [PageRecord] {
        let live = content.livePages
        if let wanted = pages.map(Set.init) {
            let chosen = live.filter { wanted.contains($0.id) }
            if !chosen.isEmpty { return chosen }
        }
        if let range = range {
            let indices = try parseRange(range, count: live.count, allowEmpty: skipOutOfRange)
            return indices.map { live[$0] }
        }
        guard !live.isEmpty else {
            throw NibError(.invalidParams, "doc:\(content.meta.id.raw) has no pages to export", path: "$.docs",
                           hint: "add a page first (page.add), or export another format")
        }
        return live
    }

    /// True when `range` is set, `pages` names none of the document's pages and the range names none of them either:
    /// a multi-document export leaves such a document out. A malformed range throws.
    static func rangeSkips(_ content: DocumentContent, pages: [PageID]?, range: String?) throws -> Bool {
        guard let range = range, !content.livePages.isEmpty else { return false }
        if let wanted = pages.map(Set.init), content.livePages.contains(where: { wanted.contains($0.id) }) { return false }
        return try parseRange(range, count: content.livePages.count, allowEmpty: true).isEmpty
    }

    /// The error of a multi-document export whose page range names no page of any document.
    static func nothingInRange(_ range: String?) -> NibError {
        NibError(.invalidParams, "invalid page range '\(range ?? "")': no page of any document is in it",
                 path: "$.options.pageRange", hint: "use 1-based page numbers such as \"1-3, 5, 8-\"")
    }

    /// "1-3, 5, 8-" → 0-based indices in ascending order (duplicates removed). Numbers are 1-based; "-4" means 1-4 and
    /// "8-" means 8 to the last page; pages past the end are ignored. A range naming no page throws unless
    /// `allowEmpty` (then []).
    static func parseRange(_ text: String, count: Int, allowEmpty: Bool = false) throws -> [Int] {
        func fail(_ why: String) -> NibError {
            NibError(.invalidParams, "invalid page range '\(text)': \(why)", path: "$.options.pageRange",
                     hint: "use 1-based page numbers such as \"1-3, 5, 8-\"")
        }
        var chosen = Set<Int>()
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts where !part.isEmpty {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch bounds.count {
            case 1:
                guard let n = Int(bounds[0]), n >= 1 else { throw fail("'\(part)' is not a page number") }
                if n <= count { chosen.insert(n - 1) }
            case 2:
                let lo = bounds[0].isEmpty ? 1 : Int(bounds[0])
                let hi = bounds[1].isEmpty ? max(count, lo ?? 1) : Int(bounds[1])
                guard let a = lo, let b = hi, a >= 1, b >= a else { throw fail("'\(part)' is not a range") }
                if a <= count { for n in a...min(b, count) { chosen.insert(n - 1) } }
            default:
                throw fail("'\(part)' is not a range")
            }
        }
        guard !chosen.isEmpty || allowEmpty else { throw fail("no page of the document is in it") }
        return chosen.sorted()
    }
}

// MARK: - File names

enum ExportNames {
    /// A document's title as a file name: no path separators or control characters, at most 120 characters.
    static func sanitize(_ raw: String, fallback: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var s = raw.components(separatedBy: banned).joined(separator: "-")
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 120 { s = String(s.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? fallback : s
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… when the (case-insensitive) name is taken.
    static func unique(_ base: String, ext: String, used: inout Set<String>) -> String {
        let suffix = ext.isEmpty ? "" : "." + ext
        var name = base + suffix
        var n = 2
        while used.contains(name.lowercased()) {
            name = "\(base) \(n)\(suffix)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }

    /// The library title of a document (the package name), else a kind-based fallback.
    @MainActor
    static func title(_ doc: DocumentID, kind: DocumentKind, ctx: CommandContext) -> String {
        let fallback: String
        switch kind {
        case .notebook: fallback = String(localized: "Notebook")
        case .whiteboard: fallback = String(localized: "Whiteboard")
        case .textDocument: fallback = String(localized: "Text Document")
        case .studySet: fallback = String(localized: "Study Set")
        }
        return sanitize(ctx.services.library?.node(doc)?.title ?? "", fallback: fallback)
    }

    /// A fresh folder under the temporary directory for one export's files.
    static func scratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nib-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Workers

/// Runs export work off the main actor on a GCD queue (not the cooperative pool, since a worker may wait for the main
/// actor through `MainPull`).
enum ExportWorker {
    static let log = Logger(subsystem: "app.nib", category: "export")

    static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Drops the pages an export loaded into the workspace again, every few pages and at the end. Only pages the export
/// itself brought into memory are dropped: pages that were cached before it read them (the canvas's pages, including
/// ones the canvas loads while a long export runs) stay.
@MainActor
final class PageCacheGuard {
    static let batch = 8
    private let workspace: Workspace
    private let doc: DocumentID
    private var loadedByExport = Set<PageID>()

    init(_ workspace: Workspace, doc: DocumentID) {
        self.workspace = workspace
        self.doc = doc
    }

    /// Runs `load` (which may read `page` into the workspace) and remembers the page when it was not cached before.
    func track<T>(_ page: PageID, _ load: () throws -> T) rethrows -> T {
        let wasCached = workspace.isPageCached(doc, page: page)
        let value = try load()
        note(page, wasCached: wasCached)
        return value
    }

    func track<T>(_ page: PageID, _ load: () async -> T) async -> T {
        let wasCached = workspace.isPageCached(doc, page: page)
        let value = await load()
        note(page, wasCached: wasCached)
        return value
    }

    private func note(_ page: PageID, wasCached: Bool) {
        guard !wasCached, workspace.isPageCached(doc, page: page) else { return }
        loadedByExport.insert(page)
        if loadedByExport.count >= PageCacheGuard.batch { evict() }
    }

    func evict() {
        guard !loadedByExport.isEmpty else { return }
        workspace.evictPages(doc, keeping: workspace.cachedPages(doc).subtracting(loadedByExport))
        loadedByExport.removeAll()
    }
}

/// A document an export reads: when the export opened it (it was not loaded before), `end()` closes it again, so a
/// folder or library export never leaves hundreds of heads in memory.
@MainActor
final class ExportDocumentUse {
    let doc: DocumentID
    private let workspace: Workspace
    private let wasLoaded: Bool

    init(_ doc: DocumentID, ctx: CommandContext) {
        self.doc = doc
        self.workspace = ctx.workspace
        self.wasLoaded = ctx.workspace.isLoaded(doc)
    }

    func end() {
        guard !wasLoaded, workspace.isLoaded(doc) else { return }
        workspace.close(doc)
    }
}

/// Lets a worker fetch one value at a time from the main actor (page snapshots), so a long export never holds every
/// page in memory and never blocks the main actor for more than one page. The caller awaits the worker, so the main
/// queue is free to answer.
final class MainPull<Value> {
    private final class Box {
        var value: Value?
        var error: Error?
    }

    private let make: @MainActor (Int) throws -> Value

    init(_ make: @escaping @MainActor (Int) throws -> Value) {
        self.make = make
    }

    func callAsFunction(_ index: Int) throws -> Value {
        let box = Box()
        let work = {
            MainActor.assumeIsolated {
                do {
                    box.value = try self.make(index)
                } catch {
                    box.error = error
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        if let error = box.error { throw error }
        guard let value = box.value else { throw NibError(.internalError, "export snapshot \(index) produced nothing") }
        return value
    }
}
