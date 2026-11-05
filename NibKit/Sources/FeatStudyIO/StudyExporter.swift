import Foundation
import NibContracts

/// Study-set export: one CSV row per live card, question then answer, RFC 4180 quoting (`field`), CRLF line ends.
/// Files carry a UTF-8 byte-order mark so Excel and Numbers read non-ASCII terms correctly; `StudyImport` reads the
/// file back as-is.
/// Image and ink faces have no text and export as empty fields.
/// ponytail: no spreadsheet-formula escaping (a leading "=" stays), so the file round-trips into Quizlet, Anki and Nib.
enum StudyExport {
    struct File {
        var name: String
        var csv: String
        var cards: Int
    }

    struct Snapshot {
        var content: DocumentContent
        var title: String
    }

    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in row.map { field($0) }.joined(separator: ",") + "\r\n" }.joined()
    }

    /// Quotes a field that holds a delimiter any study importer tries (",", ";", tab), a quote or a line break, or that
    /// starts with "#". A leading quote stops the importer's Anki header scan, so a first card "#tags: …" stays a card.
    static func field(_ s: String) -> String {
        let special: (Character) -> Bool = { $0 == "," || $0 == ";" || $0 == "\t" || $0 == "\"" || $0.isNewline }
        guard s.hasPrefix("#") || s.contains(where: special) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func fileData(_ csv: String) -> Data { Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8) }

    /// "<title>.csv" with path separators replaced.
    static func fileName(_ title: String) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? String(localized: "Study Set") : safe
        return base.lowercased().hasSuffix(".csv") ? base : base + ".csv"
    }

    @MainActor
    static func snapshot(_ doc: DocumentID, _ ctx: CommandContext) throws -> Snapshot {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "doc:\(doc) is locked", hint: "unlock it first (doc.unlock)")
        }
        let content = try ctx.workspace.content(doc)
        guard content.meta.kind == .studySet else {
            throw NibError(.invalidParams, "doc:\(doc) is a \(content.meta.kind.rawValue), not a study set", path: "$.doc",
                           hint: "CSV export is for study sets; list them with library.list {\"kinds\": [\"studySet\"]}")
        }
        return Snapshot(content: content, title: ctx.services.library?.node(doc)?.title ?? "")
    }

    /// Only immutable values enter the worker; sorting and text extraction happen here too.
    static func file(_ snapshot: Snapshot) -> File {
        let cards = snapshot.content.liveCards
        let csv = encode(cards.map { [$0.front.text?.plainText ?? "", $0.back.text?.plainText ?? ""] })
        return File(name: fileName(snapshot.title), csv: csv, cards: cards.count)
    }

    /// `export.run {format: "study.csv"}`: one CSV file per study set in a fresh temporary folder.
    @MainActor
    static func write(_ request: ExportRequest, _ ctx: CommandContext) async throws -> [URL] {
        let snapshots = try request.documents.map { try snapshot($0, ctx) }
        let requestedName = request.fileName
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("studyio-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var used = Set<String>()
            var urls: [URL] = []
            do {
                for snapshot in snapshots {
                    let exported = file(snapshot)
                    var name = snapshots.count == 1 ? requestedName.map { fileName($0) } ?? exported.name : exported.name
                    let base = (name as NSString).deletingPathExtension
                    var n = 2
                    while used.contains(name.lowercased()) {
                        name = "\(base) \(n).csv"
                        n += 1
                    }
                    used.insert(name.lowercased())
                    let url = dir.appendingPathComponent(name)
                    try fileData(exported.csv).write(to: url, options: .atomic)
                    urls.append(url)
                }
                return urls
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
        }.value
    }

    /// Listed by Share & Export for study sets only (`docKinds`); `export.run` with another kind still fails with
    /// invalid_params from `snapshot(_:_:)`.
    @MainActor
    static func exporter(owner: String) -> ExporterDescriptor {
        var exporter = ExporterDescriptor(id: "study.csv", title: String(localized: "CSV"), fileExtension: "csv",
                                          utType: StudyTextFormat.csv.utType, owner: owner) { request, ctx in
            try await StudyExport.write(request, ctx)
        }
        exporter.docKinds = [.studySet]
        return exporter
    }
}

/// `study.exportCSV {doc}`: the set as a temporary CSV asset, plus the CSV text inline when the result stays under the
/// AI tool-result cap.
struct StudyExportCSV: NibCommand {
    struct Params: Codable {
        var doc: String
    }

    struct Output: Codable {
        /// Suggested file name, "<title>.csv".
        var name: String
        /// "tmp:<name>" (with the UTF-8 byte-order mark), usable by any url-taking command.
        var asset: String
        var cards: Int
        var csv: String?
        /// True when `csv` was left out to stay under the result size cap; read the asset instead.
        var truncated: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: CommandIDs.studyExportCSV, title: "Export as CSV",
        summary: "Export a study set as CSV (question, answer per row); returns a tmp: asset plus the CSV text when it "
            + "fits in the result.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC03"]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let snapshot = try StudyExport.snapshot(NodeRef.documentID(from: p.doc), ctx)
        let assets = try ctx.services.require(ctx.services.assets, "the asset store")
        return try await Task.detached(priority: .userInitiated) {
            let file = StudyExport.file(snapshot)
            let ref = try assets.putTemporary(StudyExport.fileData(file.csv), ext: "csv")
            return try output(file, asset: "tmp:" + ref.name)
        }.value
    }

    /// Inspect at most the inline budget plus one byte before considering JSON encoding.
    nonisolated static func inlineCandidate(_ csv: String) -> Bool {
        csv.utf8.prefix(NibLimits.aiToolResultBytes + 1).count <= NibLimits.aiToolResultBytes
    }

    nonisolated static func output(_ file: StudyExport.File, asset: String) throws -> Output {
        var out = Output(name: file.name, asset: asset, cards: file.cards, csv: nil, truncated: true)
        guard inlineCandidate(file.csv) else { return out }
        out.csv = file.csv
        out.truncated = nil
        if try JSONEncoder().encode(out).count > NibLimits.aiToolResultBytes {
            out.csv = nil
            out.truncated = true
        }
        return out
    }
}
