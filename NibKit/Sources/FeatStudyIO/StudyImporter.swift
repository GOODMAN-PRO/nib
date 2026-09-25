import Foundation
import NibContracts

/// One imported card: column A and column B of a row, as plain text.
struct StudyRow: Equatable {
    var front: String
    var back: String

    func card(order: String) -> StudyCard {
        StudyCard(front: CardFace(kind: .text, text: RichText(plain: front)),
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
        let body = String(bodySlice)
        let delimiter = header.separator ?? DelimitedParser.detectDelimiter(body, candidates: format.delimiters)
        var out: [StudyRow] = []
        for fields in DelimitedParser.parse(body, delimiter: delimiter) {
            let columns = fields.indices.filter { !header.metadataColumns.contains($0) }.prefix(2)
                .map { clean(fields[$0], html: header.html) }
            let front = columns.first ?? ""
            let back = columns.count > 1 ? columns[1] : ""
            if front.isEmpty && back.isEmpty { continue }
            out.append(StudyRow(front: front, back: back))
        }
        return out
    }

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

    /// Title for a set imported from a file: its name without extension (and without the "<UUID>-" prefix that
    /// `CommandContext.inputFile` gives https downloads).
    static func title(forFile url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        let uuidPrefix = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-"
        if let r = name.range(of: uuidPrefix, options: .regularExpression) { name.removeSubrange(r) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? defaultTitle : name
    }

    /// `count` increasing card order keys after `last`, chosen by bisection so they stay a few characters long
    /// (`FractionalIndex.sequence` grows one character every ~6 keys: far too long for a large deck).
    static func orderKeys(after last: String?, count: Int) -> [String] {
        var keys: [String] = []
        keys.reserveCapacity(max(0, count))
        func fill(_ lo: String?, _ hi: String?, _ n: Int) {
            guard n > 0 else { return }
            let mid = FractionalIndex.between(lo, hi)
            let left = (n - 1) / 2
            fill(lo, mid, left)
            keys.append(mid)
            fill(mid, hi, n - 1 - left)
        }
        fill(last, nil, count)
        return keys
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
    @MainActor
    @discardableResult
    static func createSet(_ rows: [StudyRow], id: DocumentID, title: String, folder: FolderID?,
                          _ ctx: CommandContext) throws -> DocumentID {
        let library = try ctx.services.require(ctx.services.library, "the library")
        let clock = ctx.workspace.clock
        var meta = DocumentMeta(id: id, kind: .studySet)
        meta.rev = clock.tick()
        let cards = zip(rows, orderKeys(after: nil, count: rows.count)).map { pair -> StudyCard in
            var card = pair.0.card(order: pair.1)
            card.rev = clock.tick()
            return card
        }
        return try library.createDocument(DocumentContent(meta: meta, cards: cards), title: title, in: folder)
    }

    /// Appends the rows to an existing study set as one undo step.
    /// ponytail: each `tx.put` copies the card array, so appending is O(n²); fine for decks of a few thousand cards.
    @MainActor
    static func append(_ rows: [StudyRow], to doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "doc:\(doc) is locked", hint: "unlock it first (doc.unlock)")
        }
        try ctx.mutate(String(localized: "Import Cards")) { tx in
            let last = try tx.content(doc).liveCards.last?.order
            for (row, order) in zip(rows, orderKeys(after: last, count: rows.count)) {
                try tx.put(row.card(order: order), doc: doc)
            }
        }
    }

    /// `import.files` entry point: appends to the target document when it is a study set, else creates a new set named
    /// after the file in the target folder.
    @MainActor
    static func importFile(_ url: URL, format: StudyTextFormat, target: ImportTarget,
                           _ ctx: CommandContext) async throws -> [DocumentID] {
        let rows = try await StudyImport.rows(fromFile: url, format: format)
        guard !rows.isEmpty else {
            throw NibError(.invalidParams, "no cards found in \(url.lastPathComponent)",
                           hint: "one card per line: question, then a tab or comma, then the answer")
        }
        if let doc = target.document, try ctx.workspace.content(doc).meta.kind == .studySet {
            try append(rows, to: doc, ctx)
            return [doc]
        }
        let id = NibID.make()
        if !ctx.dryRun { try createSet(rows, id: id, title: title(forFile: url), folder: target.folder, ctx) }
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
        id: "study.importText", title: "Import Study Set",
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
        if let id = p.id, !NibID.isValid(id) { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let library = try ctx.services.require(ctx.services.library, "the library")
        let folder = try StudyImport.folder(p.folder, library)
        let docID = p.id.map { NibID($0) } ?? NibID.make()
        if library.node(docID) != nil {
            throw NibError(.conflict, "id \(docID) is already used in the library", path: "$.id",
                           hint: "choose another id or leave it out")
        }

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
