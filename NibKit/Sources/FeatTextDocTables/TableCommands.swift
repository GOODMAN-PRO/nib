import Foundation
import UniformTypeIdentifiers
import NibContracts

// The table commands (ARCHITECTURE §6.5 `table.*`, owner F048) and the CSV exporter. Every change to a table, from the
// table view, a plugin, the AI or the bridge, is one `table.edit`, so undo, sync and collaboration see the same thing.

// MARK: - table.edit

struct TableEdit: NibCommand {
    struct Params: Codable {
        var ref: String
        var op: String
        var row: Int?
        var column: Int?
        var count: Int?
        var text: RichText?
        var color: String?
        var width: Double?
        /// Additive params (§6.1): the last row / column of a merge or background range, a move's destination, and
        /// setBorders' value.
        var toRow: Int?
        var toColumn: Int?
        var to: Int?
        var borders: Bool?

        init(ref: String, op: TableEditOp, row: Int? = nil, column: Int? = nil, count: Int? = nil, text: RichText? = nil,
             color: String? = nil, width: Double? = nil, toRow: Int? = nil, toColumn: Int? = nil, to: Int? = nil,
             borders: Bool? = nil) {
            self.ref = ref
            self.op = op.rawValue
            self.row = row
            self.column = column
            self.count = count
            self.text = text
            self.color = color
            self.width = width
            self.toRow = toRow
            self.toColumn = toColumn
            self.to = to
            self.borders = borders
        }
    }

    struct Output: Codable {
        /// The table's size after the edit.
        var rows: Int
        var columns: Int
        /// The cell the edit ended on: the written or merged cell, the first inserted row or column, where a moved
        /// row or column went (nil for setBorders).
        var row: Int?
        var column: Int?
    }

    static let tableRef = "block:FIXTUREDOC02/FIXTUREBLK03"
    private static let exSetCell: JSONValue = ["ref": .string(tableRef), "op": "setCell", "row": 0, "column": 1, "text": "Total"]
    private static let exInsertRow: JSONValue = ["ref": .string(tableRef), "op": "insertRowAfter", "row": 1]
    private static let exInsertColumn: JSONValue = ["ref": .string(tableRef), "op": "insertColumnBefore", "column": 0]
    private static let exDeleteRow: JSONValue = ["ref": .string(tableRef), "op": "deleteRow", "row": 0]
    private static let exDeleteColumn: JSONValue = ["ref": .string(tableRef), "op": "deleteColumn", "column": 1]
    private static let exMerge: JSONValue = ["ref": .string(tableRef), "op": "merge", "row": 0, "column": 0, "toColumn": 1]
    private static let exBackground: JSONValue = ["ref": .string(tableRef), "op": "setBackground", "row": 0, "color": "#FFE45C80"]
    private static let exBorders: JSONValue = ["ref": .string(tableRef), "op": "setBorders", "borders": false]
    private static let exWidth: JSONValue = ["ref": .string(tableRef), "op": "setColumnWidth", "column": 0, "width": 160]
    private static let exMoveRow: JSONValue = ["ref": .string(tableRef), "op": "moveRow", "row": 1, "to": 0]
    private static let exMoveColumn: JSONValue = ["ref": .string(tableRef), "op": "moveColumn", "column": 0, "to": 1]

    static let descriptor = CommandDescriptor(
        id: "table.edit", title: "Edit Table",
        summary: "Edit a text-document table (rows and columns from 0): set a cell, insert/delete/move rows and columns, merge/split cells, cell background, borders, column width.",
        params: .obj([
            "ref": .str("the table block, block:D/B"),
            "op": .str("setCell | insertRowBefore | insertRowAfter | insertColumnBefore | insertColumnAfter | deleteRow | deleteColumn | merge | split | setBackground | setBorders | setColumnWidth | moveRow | moveColumn",
                       choices: TableEditOp.allCases.map { $0.rawValue }),
            "row": .int("row from 0: the cell's row (setCell, merge, split), the row to insert before/after (default top/end), delete or move; setBackground: first row (omit for whole columns)", min: 0),
            "column": .int("column from 0: the cell's column, the column to insert before/after (default left/end), delete, move or resize; setBackground: first column (omit for whole rows)", min: 0),
            "count": .int("insert/delete: how many rows or columns (default 1)", min: 1, max: TableOps.maxRows),
            "text": .anything("setCell: the cell's text, a plain string (one paragraph per line) or rich text {paragraphs: [...]}; \"\" empties it"),
            "color": .str("setBackground: #RRGGBB or #RRGGBBAA; omit to clear the background"),
            "width": .num("setColumnWidth: points (44-1600); 0 or omitted = automatic", min: 0, max: TableOps.maxColumnWidth),
            "toRow": .int("merge / setBackground: last row of the range (inclusive)", min: 0),
            "toColumn": .int("merge / setBackground: last column of the range (inclusive)", min: 0),
            "to": .int("moveRow / moveColumn: the index it ends up at", min: 0),
            "borders": .bool("setBorders: show cell borders (omit to toggle)")
        ], required: ["ref", "op"]),
        examples: [exSetCell, exInsertRow, exInsertColumn, exDeleteRow, exDeleteColumn, exMerge, exBackground, exBorders,
                   exWidth, exMoveRow, exMoveColumn],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let op = TableEditOp(rawValue: p.op) else {
            throw NibError(.invalidParams, "unknown op '\(p.op)'", path: "$.op",
                           hint: "one of: " + TableEditOp.allCases.map { $0.rawValue }.joined(separator: ", "))
        }
        let (doc, id) = try TableRefs.blockRef(p.ref)
        let request = TableEditing.Request(op, row: p.row, column: p.column, count: p.count, text: p.text, color: p.color,
                                           width: p.width, toRow: p.toRow, toColumn: p.toColumn, to: p.to, borders: p.borders)
        return try ctx.mutate { (tx: DocTransaction) -> Output in
            var block = try TableRefs.liveTable(id, doc: doc, in: tx.content(doc))
            var table = TableOps.normalized(block.table)
            let at = try TableEditing.apply(request, to: &table)
            let out = Output(rows: table.rows.count, columns: TableOps.columnCount(table), row: at?.row, column: at?.column)
            // An edit that changes nothing (the same text again, a move onto itself) writes nothing and adds no undo step.
            guard table != block.table else { return out }
            block.table = table
            try tx.put(block, doc: doc)
            return out
        }
    }
}

// MARK: - table.exportCSV

struct TableExportCSV: NibCommand {
    struct Params: Codable {
        var ref: String
    }

    struct Output: Codable {
        /// Suggested file name, "<document> – Table <n>.csv" ("<document>.csv" for a document's only table).
        var name: String
        /// "tmp:<name>" (UTF-8 with a byte-order mark), usable by any url-taking command.
        var asset: String
        var rows: Int
        var columns: Int
        var csv: String?
        /// True when `csv` was left out to stay under the result size cap; read the asset instead.
        var truncated: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: "table.exportCSV", title: "Export Table as CSV",
        summary: "Export one text-document table as CSV (RFC 4180; a merged cell's text once); returns a tmp: asset plus the CSV text when it fits in the result.",
        params: .obj(["ref": .str("the table block, block:D/B")], required: ["ref"]),
        examples: [["ref": .string(TableEdit.tableRef)]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, id) = try TableRefs.blockRef(p.ref)
        try TableExport.checkUnlocked(doc, ctx)
        let content = try ctx.workspace.content(doc)
        let block = try TableRefs.liveTable(id, doc: doc, in: content)
        let tables = content.liveBlocks.filter { $0.kind == .table }
        let index = tables.firstIndex { $0.id == id } ?? 0
        let table = TableOps.normalized(block.table)
        let csv = TableOps.csv(table)
        let title = ctx.services.library?.node(doc)?.title ?? ""
        let assets = try ctx.services.require(ctx.services.assets, "the asset store")
        let asset = try assets.putTemporary(TableExport.fileData(csv), ext: "csv")
        var out = Output(name: TableExport.fileName(title, index: index, of: tables.count), asset: "tmp:" + asset.name,
                         rows: table.rows.count, columns: TableOps.columnCount(table), csv: csv, truncated: nil)
        if try JSONEncoder().encode(out).count > NibLimits.aiToolResultBytes {
            out.csv = nil
            out.truncated = true
        }
        return out
    }
}

// MARK: - Refs

enum TableRefs {
    static func blockRef(_ s: String, path: String = "$.ref") throws -> (DocumentID, NibID) {
        guard case let .block(doc, id)? = NodeRef(s) else {
            throw NibError(.invalidParams, "'\(s)' is not a block ref", path: path,
                           hint: "tables are text-document blocks: block:<doc>/<block>; query.get {ref: \"doc:<doc>\"} lists them")
        }
        return (doc, id)
    }

    /// The live table block `id`, or a clear error for a missing block or one of another kind.
    static func liveTable(_ id: NibID, doc: DocumentID, in content: DocumentContent, path: String = "$.ref") throws -> TextBlock {
        guard let b = content.blocks.first(where: { $0.id == id && !$0.deleted }) else {
            throw NibError(.notFound, "block \(id.raw) not found in doc:\(doc.raw)", path: path,
                           hint: "call query.get {ref: \"doc:\(doc.raw)\"} to list the document's blocks")
        }
        guard b.kind == .table else {
            throw NibError(.invalidParams, "block \(id.raw) is a \(b.kind.rawValue), not a table", path: path,
                           hint: "turn it into a table with block.update {ref, kind: \"table\"}, or add one with block.insert {doc, kind: \"table\"}")
        }
        return b
    }
}

// MARK: - CSV export (Share & Export)

/// The "tables.csv" exporter: one CSV file per table of each text document (`ExporterDescriptor.docKinds`
/// [.textDocument], contracts-v2 G26), with a UTF-8 byte-order mark so Excel and Numbers read non-ASCII text.
enum TableExport {
    static let exporterID = "tables.csv"

    static func exporter(owner: String) -> ExporterDescriptor {
        var d = ExporterDescriptor(id: exporterID, title: String(localized: "CSV"), fileExtension: "csv",
                                   utType: UTType.commaSeparatedText.identifier, order: 600, owner: owner) { request, ctx in
            try TableExport.write(request, ctx)
        }
        d.docKinds = [.textDocument]
        return d
    }

    static func fileData(_ csv: String) -> Data { Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8) }

    /// "<title>.csv" for a document's only table, "<title> – Table 2.csv" when it has several; path separators
    /// become dashes.
    static func fileName(_ title: String, index: Int, of count: Int) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = safe.isEmpty ? String(localized: "Table") : safe
        if base.lowercased().hasSuffix(".csv") { base = String(base.dropLast(4)) }
        if count > 1 { base += " \u{2013} " + String(localized: "Table \(index + 1)") }
        return base + ".csv"
    }

    @MainActor
    static func checkUnlocked(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "doc:\(doc.raw) is locked", hint: "unlock it first")
        }
    }

    /// Every table of a text document as (file name, CSV), in document order.
    @MainActor
    static func files(_ doc: DocumentID, _ ctx: CommandContext, title: String? = nil) throws -> [(name: String, csv: String)] {
        try checkUnlocked(doc, ctx)
        let content = try ctx.workspace.content(doc)
        guard content.meta.kind == .textDocument else {
            throw NibError(.invalidParams, "doc:\(doc.raw) is a \(content.meta.kind.rawValue), not a text document",
                           path: "$.docs", hint: "CSV export of tables is for text documents")
        }
        let tables = content.liveBlocks.filter { $0.kind == .table }
        guard !tables.isEmpty else {
            throw NibError(.notFound, "doc:\(doc.raw) has no tables", path: "$.docs",
                           hint: "add one with block.insert {doc, kind: \"table\"}")
        }
        let name = title ?? ctx.services.library?.node(doc)?.title ?? ""
        return tables.enumerated().map { i, block in
            (fileName(name, index: i, of: tables.count), TableOps.csv(TableOps.normalized(block.table)))
        }
    }

    /// `export.run {format: "tables.csv"}`: the files in a fresh temporary folder, names made unique.
    @MainActor
    static func write(_ request: ExportRequest, _ ctx: CommandContext) throws -> [URL] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tables-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var used = Set<String>()
        var urls: [URL] = []
        for doc in request.documents {
            let title = request.documents.count == 1 ? request.fileName : nil
            for file in try files(doc, ctx, title: title) {
                var name = file.name
                let base = (name as NSString).deletingPathExtension
                var n = 2
                while used.contains(name.lowercased()) {
                    name = "\(base) \(n).csv"
                    n += 1
                }
                used.insert(name.lowercased())
                let url = dir.appendingPathComponent(name)
                try fileData(file.csv).write(to: url, options: .atomic)
                urls.append(url)
            }
        }
        return urls
    }
}
