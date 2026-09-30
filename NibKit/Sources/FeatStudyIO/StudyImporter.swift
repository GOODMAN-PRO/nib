import Foundation
import NibContracts

/// One imported card: column A and column B of a row, as plain text.
struct StudyRow: Equatable {
    var front: String
    var back: String

    /// Empty `order` = appended by `tx.put(_ cards:doc:)` after the set's last card.
    func card(id: NibID = NibID.make(), order: String = "") -> StudyCard {
        StudyCard(id: id, front: CardFace(kind: .text, text: RichText(plain: front)),
                  back: CardFace(kind: .text, text: RichText(plain: back)), order: order)
    }
}

/// Study-set import: CSV / TSV / TXT (Quizlet exports, Anki "Notes in Plain Text") → cards. Column A = question,
/// column B = answer, no header row, extra columns ignored (Anki metadata columns named in its header are skipped first).
enum StudyImport {
    static let defaultTitle = String(localized: "Imported Study Set")

    // MARK: Text → rows (pure)

    static func rows(from raw: String, format: StudyTextFormat) -> [StudyRow] {
        let (header, bodySlice) = AnkiHeader.split(dropBOM(raw))
        let body = Array(bodySlice.unicodeScalars)
        let delimiter = header.separator ?? DelimitedParser.detectDelimiter(body, candidates: format.delimiters)
        // With no `#html:` header, only a file that carries Anki markup has its markup stripped. A plain Quizlet or Nib
        // file keeps "What does <b> do?" and "&lt;" verbatim.
        let html = header.html ?? (HTMLText.hasAnkiMarkup(bodySlice) ? nil : false)
        var out: [StudyRow] = []
        for fields in DelimitedParser.parse(body, delimiter: delimiter) {
            let columns = fields.indices.filter { !header.metadataColumns.contains($0) }.prefix(2)
                .map { clean(fields[$0], html: html) }
            let front = columns.first ?? ""
            let back = columns.count > 1 ? columns[1] : ""
            if front.isEmpty && back.isEmpty { continue }
            out.append(StudyRow(front: front, back: back))
        }
        return out
    }

    /// `html`: true = strip every tag, nil = strip well-known tags, false = keep the text verbatim.
    static func clean(_ field: String, html: Bool?) -> String {
        var s = field.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if html != false { s = HTMLText.strip(s, anyTag: html == true) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dropBOM(_ s: String) -> String {
        s.unicodeScalars.first == "\u{FEFF}" ? String(String.UnicodeScalarView(s.unicodeScalars.dropFirst())) : s
    }

    /// UTF-8 (with or without BOM), UTF-16 with a BOM, else Windows-1252 (older Excel / Quizlet saves). No BOM in the
    /// result.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return dropBOM(s) }
        if let s = String(data: data, encoding: .utf8) { return dropBOM(s) }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return dropBOM(String(decoding: data, as: UTF8.self))
    }

    /// Parsing runs off the main actor (a 10,000-card Anki deck takes longer than a frame).
    static func rows(fromText text: String, format: StudyTextFormat) async -> [StudyRow] {
        await Task.detached(priority: .userInitiated) { StudyImport.rows(from: text, format: format) }.value
    }

    static func rows(fromFile url: URL, format: StudyTextFormat) async throws -> [StudyRow] {
        try await Task.detached(priority: .userInitiated) { () throws -> [StudyRow] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw NibError(.notFound, "cannot read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            return StudyImport.rows(from: StudyImport.decode(data), format: format)
        }.value
    }

    /// Title for a set imported from a file: its name without extension (`CommandContext.inputFile` keeps a download's
    /// original name), else `defaultTitle`.
    static func title(forFile url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? defaultTitle : name
    }

    // MARK: Rows → documents

    /// "folder:F", a bare folder id, "lib" or nil (= library root).
    @MainActor
    static func folder(_ ref: String?, _ library: LibraryService) throws -> FolderID? {
        guard let ref = ref, !ref.isEmpty else { return nil }
        let id: FolderID
        switch NodeRef(ref) {
        case .library?: return nil
        case .folder(let f)?: id = f
        case nil: id = NibID(ref)
        default: throw NibError.invalid("expected a folder ref like folder:F", path: "$.folder")
        }
        guard library.node(id)?.kind == .folder else {
            throw NibError(.notFound, "folder \(id) not found", path: "$.folder", hint: "call library.list to see folders")
        }
        return id
    }

    /// Writes a new study set package holding one card per row (not on the undo stack: recoverable through Trash).
    /// Card order keys are balanced, so a 10,000-card deck gets keys a few characters long.
    @MainActor
    @discardableResult
    static func createSet(_ rows: [StudyRow], id: DocumentID, title: String, folder: FolderID?,
                          _ ctx: CommandContext) throws -> DocumentID {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let clock = ctx.workspace.clock
        var meta = DocumentMeta(id: id, kind: .studySet)
        meta.rev = clock.tick()
        let cards = zip(rows, FractionalIndex.balanced(count: rows.count)).map { pair -> StudyCard in
            var card = pair.0.card(order: pair.1)
            card.rev = clock.tick()
            return card
        }
        return try library.createDocument(DocumentContent(meta: meta, cards: cards), title: title, in: folder)
    }

    /// The id for a new set: the caller's (`study.importText {id}`, `import.files {ids}`), which must be well formed and
    /// unused, else a fresh one.
    @MainActor
    static func newSetID(_ requested: NibID?, path: String, _ library: LibraryService) throws -> DocumentID {
        guard let id = requested else { return NibID.make() }
        guard NibID.isValid(id.raw) else { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: path) }
        if library.node(id) != nil {
            throw NibError(.conflict, "id \(id) is already used in the library", path: path,
                           hint: "choose another id or leave it out")
        }
        return id
    }

    /// Appends the rows to an existing study set as one undo step, in one batch write (`tx.put(_ cards:doc:)` gives the
    /// new cards balanced order keys after the set's last card). `ids` (from `import.files {ids}`) name the new cards
    /// in row order; each must be well formed and not used by a card of the set.
    @MainActor
    static func append(_ rows: [StudyRow], to doc: DocumentID, ids: [NibID]? = nil, _ ctx: CommandContext) throws {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "doc:\(doc) is locked", hint: "unlock it first (doc.unlock)")
        }
        let ids = Array((ids ?? []).prefix(rows.count))
        if !ids.isEmpty {
            let used = Set(try ctx.workspace.content(doc).cards.map(\.id))
            var seen = Set<NibID>()
            for (i, id) in ids.enumerated() {
                guard NibID.isValid(id.raw) else {
                    throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.ids[\(i)]")
                }
                guard !used.contains(id), seen.insert(id).inserted else {
                    throw NibError(.conflict, "card id \(id) is already used in doc:\(doc)", path: "$.ids[\(i)]",
                                   hint: "choose other ids or leave them out")
                }
            }
        }
        let cards = rows.enumerated().map { i, row in i < ids.count ? row.card(id: ids[i]) : row.card() }
        try ctx.mutate(String(localized: "Import Cards")) { tx in
            try tx.put(cards, doc: doc)
        }
    }

    /// `import.files` entry point: appends to the target document when it is a study set, else creates a new set in the
    /// target folder, titled `target.displayName` (the original file name) or after the local file, with id
    /// `target.ids[0]` when given.
    @MainActor
    static func importFile(_ url: URL, format: StudyTextFormat, target: ImportTarget,
                           _ ctx: CommandContext) async throws -> [DocumentID] {
        let rows = try await StudyImport.rows(fromFile: url, format: format)
        guard !rows.isEmpty else {
            throw NibError(.invalidParams, "no cards found in \(target.displayName ?? url.lastPathComponent)",
                           hint: "one card per line: question, then a tab or comma, then the answer")
        }
        if let doc = target.document {
            if try ctx.workspace.content(doc).meta.kind == .studySet {
                try append(rows, to: doc, ids: target.ids, ctx)
                return [doc]
            }
        }
        let library = try ctx.services.require(ctx.services.library, "the library")
        let id = try newSetID(target.ids?.first, path: "$.ids[0]", library)
        let display = target.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = display.isEmpty ? StudyImport.title(forFile: url) : display
        if !ctx.dryRun { try createSet(rows, id: id, title: title, folder: target.folder, ctx) }
        return [id]
    }

    @MainActor
    static func importer(_ format: StudyTextFormat, owner: String) -> ImporterDescriptor {
        let title: String
        switch format {
        case .csv: title = String(localized: "Study Set (CSV)")
        case .tsv: title = String(localized: "Study Set (TSV)")
        case .txt: title = String(localized: "Study Set (Anki or Quizlet text)")
        }
        return ImporterDescriptor(id: "study." + format.rawValue, title: title, fileExtensions: [format.rawValue],
                                  utTypes: [format.utType], owner: owner) { url, target, ctx in
            try await StudyImport.importFile(url, format: format, target: target, ctx)
        }
    }
}

/// `study.importText {text? | url?, format?, folder?, id?}`: creates a study set, one card per non-blank row.
struct StudyImportText: NibCommand {
    struct Params: Codable {
        var text: String?
        var url: String?
        var format: String?
        var folder: String?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
        var cards: Int
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.studyImportText, title: "Import Study Set",
        summary: "Create a study set from CSV/TSV/TXT text or a file url (column A = question, B = answer; Anki plain-text "
            + "and Quizlet exports work); returns the new doc ref.",
        params: .obj([
            "text": .str("delimited text, one card per line: question, delimiter, answer (extra columns ignored)"),
            "url": .str("file to import instead of text: a tmp: ref from asset.upload or an https URL"),
            "format": .str("csv (comma or semicolon), tsv (tab) or txt (tab, comma or semicolon, detected); "
                + "default: the url's extension, else txt", choices: ["csv", "tsv", "txt"]),
            "folder": .str("destination folder ref (folder:F); default: the library root"),
            "id": .str("your own id for the new study set, [A-Za-z0-9_-]{1,64}")
        ]),
        examples: [["text": "Paris\tCapital of France\nBerlin\tCapital of Germany", "format": "tsv",
                    "folder": "folder:FIXTUREFLD01"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if p.text != nil && p.url != nil {
            throw NibError(.invalidParams, "pass either text or url, not both", path: "$.url")
        }
        guard p.text != nil || p.url != nil else {
            throw NibError(.invalidParams, "pass the cards as text or a file url", path: "$.text",
                           hint: "e.g. {\"text\": \"question\\tanswer\"}")
        }
        var format: StudyTextFormat?
        if let f = p.format {
            guard let parsed = StudyTextFormat(rawValue: f.lowercased()) else {
                throw NibError.invalid("format must be csv, tsv or txt", path: "$.format")
            }
            format = parsed
        }
        let library = try ctx.services.require(ctx.services.library, "the library")
        let docID = try StudyImport.newSetID(p.id.map { NibID($0) }, path: "$.id", library)
        let folder = try StudyImport.folder(p.folder, library)

        let rows: [StudyRow]
        var title = StudyImport.defaultTitle
        if let url = p.url {
            let file = try await ctx.inputFile(url)
            rows = try await StudyImport.rows(fromFile: file, format: format
                ?? StudyTextFormat(rawValue: file.pathExtension.lowercased()) ?? .txt)
            if !url.hasPrefix("tmp:"), let original = URL(string: url) { title = StudyImport.title(forFile: original) }
        } else {
            rows = await StudyImport.rows(fromText: p.text ?? "", format: format ?? .txt)
        }
        guard !rows.isEmpty else {
            throw NibError(.invalidParams, "no cards found (every line was empty)", path: p.url == nil ? "$.text" : "$.url",
                           hint: "one card per line: question, then a tab or comma, then the answer")
        }
        if !ctx.dryRun { try StudyImport.createSet(rows, id: docID, title: title, folder: folder, ctx) }
        return Output(ref: NodeRef.document(docID).description, cards: rows.count)
    }
}
