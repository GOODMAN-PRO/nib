import Foundation
import UIKit
import NibContracts
import NibDesign

/// The wire format of library.list, independent of the library store implementation.
struct LibraryRow: Codable, Identifiable, Hashable {
    var ref: String
    var kind: String
    var title: String?
    var path: String?
    var parent: String?
    var modified: Double?
    var created: Double?
    var favorite: Bool?
    var locked: Bool?
    var sync: String?
    var color: String?
    var icon: String?
    var items: Int?
    var pages: Int?
    var id: String { ref }
    var isFolder: Bool { kind == "folder" }
    var name: String { title ?? String(localized: "Locked document") }
    var nodeID: NibID { NibID(String(ref.split(separator: ":").last ?? "")) }

    var accessibilityLabel: String { name }
    var accessibilityStatus: String {
        [locked == true ? String(localized: "Locked") : "",
         favorite == true ? String(localized: "Favourite") : "",
         syncStatus]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var accessibilityValue: String { accessibilityValue(subtitle: nil) }
    func accessibilityValue(subtitle: String?) -> String {
        [accessibilityStatus, isFolder ? items.map(Self.itemCount) ?? "" : subtitle ?? self.subtitle()]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var syncStatus: String {
        switch sync.flatMap(SyncBadge.init(rawValue:)) {
        case .localOnly: return String(localized: "Not synced")
        case .syncing: return String(localized: "Syncing")
        case .downloading: return String(localized: "Downloading")
        case .error: return String(localized: "Sync error")
        default: return ""
        }
    }
    var syncSymbol: NibSymbol? {
        switch sync.flatMap(SyncBadge.init(rawValue:)) {
        case .error: return .syncError
        case .syncing, .downloading: return .syncing
        default: return nil
        }
    }
    var typeBadge: NibSymbol? {
        switch kind {
        case "whiteboard": return .whiteboard
        case "textDocument": return .textDocument
        case "studySet": return .studySets
        default: return nil
        }
    }
    func subtitle(content: DocumentContent? = nil) -> String {
        switch kind {
        case "studySet":
            guard let content else { return String(localized: "Study set") }
            let count = content.cards.filter { !$0.deleted }.count
            return count == 1 ? String(localized: "1 card") : String(localized: "\(count) cards")
        case "textDocument":
            guard let content else { return String(localized: "Text document") }
            var count = 0
            func addWords(_ text: String) {
                text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in count += 1 }
            }
            for block in content.blocks where !block.deleted {
                addWords(block.text.plainText)
                if let caption = block.caption { addWords(caption.plainText) }
                for cells in block.table?.rows ?? [] {
                    for cell in cells { addWords(cell.text.plainText) }
                }
            }
            return count == 1 ? String(localized: "1 word") : String(localized: "\(count) words")
        case "whiteboard": return String(localized: "Whiteboard")
        default: return pages.map(Self.pageCount) ?? String(localized: "Notebook")
        }
    }
    static func itemCount(_ count: Int) -> String { count == 1 ? String(localized: "1 item") : String(localized: "\(count) items") }
    static func pageCount(_ count: Int) -> String { count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages") }

    static func from(_ node: LibraryNode) -> LibraryRow {
        LibraryRow(ref: node.kind == .folder ? NodeRef.folder(node.id).description : NodeRef.document(node.id).description,
                   kind: node.kind == .folder ? "folder" : node.documentKind?.rawValue ?? "document",
                   title: node.title, path: node.path, parent: node.parent.map { NodeRef.folder($0).description },
                   modified: node.modified, created: node.created, favorite: node.favorite, locked: node.locked,
                   sync: node.sync.rawValue, color: node.style?.color?.hex, icon: node.style?.icon, pages: node.pageCount)
    }
}

extension JSONValue {
    /// library.list already supplies parsed JSON. Decode its flat rows without
    /// serializing all 5,000 objects to bytes and parsing those bytes again.
    func decode(_ type: [LibraryRow].Type) throws -> [LibraryRow] {
        guard case .array(let values) = self else {
            throw DecodingError.typeMismatch(type, .init(codingPath: [], debugDescription: "Expected library rows"))
        }
        return try values.enumerated().map { index, value in
            let path: [CodingKey] = [LibraryRowKey(index: index)]
            guard case .object(let fields) = value else {
                throw DecodingError.typeMismatch(LibraryRow.self, .init(codingPath: path, debugDescription: "Expected library row"))
            }
            func field<T>(_ key: String, _ extract: (JSONValue) -> T?) throws -> T? {
                guard let value = fields[key], !value.isNull else { return nil }
                guard let result = extract(value) else {
                    throw DecodingError.typeMismatch(T.self, .init(codingPath: path + [LibraryRowKey(key)],
                                                                  debugDescription: "Invalid library row field"))
                }
                return result
            }
            func requiredString(_ key: String) throws -> String {
                if let result = try field(key, { $0.stringValue }) { return result }
                let context = DecodingError.Context(codingPath: path + [LibraryRowKey(key)], debugDescription: "Missing library row field")
                if fields[key] != nil { throw DecodingError.valueNotFound(String.self, context) }
                throw DecodingError.keyNotFound(LibraryRowKey(key), .init(codingPath: path, debugDescription: context.debugDescription))
            }
            func integer(_ value: JSONValue) -> Int? {
                guard let number = value.doubleValue else { return nil }
                return Int(exactly: number)
            }
            func number(_ value: JSONValue) -> Double? {
                guard let number = value.doubleValue, number.isFinite else { return nil }
                return number
            }
            return try LibraryRow(ref: requiredString("ref"), kind: requiredString("kind"),
                title: field("title", { $0.stringValue }), path: field("path", { $0.stringValue }),
                parent: field("parent", { $0.stringValue }), modified: field("modified", number),
                created: field("created", number), favorite: field("favorite", { $0.boolValue }),
                locked: field("locked", { $0.boolValue }), sync: field("sync", { $0.stringValue }),
                color: field("color", { $0.stringValue }), icon: field("icon", { $0.stringValue }),
                items: field("items", integer), pages: field("pages", integer))
        }
    }
}

private struct LibraryRowKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ key: String) { stringValue = key; intValue = nil }
    init(index: Int) { stringValue = "Index \(index)"; intValue = index }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { self.init(index: intValue) }
}

enum LibraryLayout: String, Codable, CaseIterable { case grid, list }
enum LibraryFilter: String, Codable, CaseIterable {
    case all, documents, folders
    var title: String {
        switch self {
        case .all: return String(localized: "All items")
        case .documents: return String(localized: "Documents")
        case .folders: return String(localized: "Folders")
        }
    }
}
enum LibrarySort: String, Codable, CaseIterable {
    case modified, modifiedAscending, created, createdAscending, name, nameDescending, type, manual
    var title: String {
        switch self {
        case .modified: return String(localized: "Modified, newest first")
        case .modifiedAscending: return String(localized: "Modified, oldest first")
        case .created: return String(localized: "Created, newest first")
        case .createdAscending: return String(localized: "Created, oldest first")
        case .name: return String(localized: "Name, A to Z")
        case .nameDescending: return String(localized: "Name, Z to A")
        case .type: return String(localized: "Type")
        case .manual: return String(localized: "Manual")
        }
    }
}

enum LibrarySorting {
    private struct SortRow {
        let row: LibraryRow
        let folder: Bool
        let name: String
        let rank: Int
    }

    static func rows(_ input: [LibraryRow], sort: LibrarySort, filter: LibraryFilter = .all,
                     manual: [String] = [], search: String = "") -> [LibraryRow] {
        var ranks: [String: Int] = [:]
        if sort == .manual {
            ranks.reserveCapacity(manual.count)
            for (index, ref) in manual.enumerated() where ranks[ref] == nil { ranks[ref] = index }
        }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SortRow] = []
        rows.reserveCapacity(input.count)
        for row in input {
            let folder = row.isFolder
            guard filter == .all || (filter == .folders ? folder : !folder) else { continue }
            let name = row.name
            // Literal matches already satisfy the search; reserve locale-aware
            // comparison for case/diacritic variants in large libraries.
            guard needle.isEmpty || name.contains(needle) || name.localizedStandardContains(needle) else { continue }
            rows.append(SortRow(row: row, folder: folder, name: name, rank: ranks[row.ref] ?? Int.max))
        }
        rows.sort { a, b in
            // Folders and notebooks occupy separate sections, including in Manual.
            if a.folder != b.folder { return a.folder }
            switch sort {
            case .manual:
                if a.rank != b.rank { return a.rank < b.rank }
            case .modified, .modifiedAscending:
                let x = a.row.modified ?? 0, y = b.row.modified ?? 0
                if x != y { return sort == .modified ? x > y : x < y }
            case .created, .createdAscending:
                let x = a.row.created ?? 0, y = b.row.created ?? 0
                if x != y { return sort == .created ? x > y : x < y }
            case .type:
                if a.row.kind != b.row.kind { return a.row.kind < b.row.kind }
            case .name, .nameDescending: break
            }
            let comparison = a.name.localizedStandardCompare(b.name)
            if comparison != .orderedSame { return sort == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending }
            return a.row.ref < b.row.ref
        }
        return rows.map(\.row)
    }

    static func compactColumns(width: CGFloat) -> Int {
        // The 393 pt design's three 110 pt covers plus two gutters occupy 362 pt;
        // account for the one-point rounding difference in the 361 pt safe content width.
        max(1, min(3, Int((max(width, 0) + NibSpacing.l + NibStroke.thin) / (NibMetrics.coverSizeCompact.width + NibSpacing.l))))
    }
    static func sections(_ rows: [LibraryRow]) -> (folders: [LibraryRow], documents: [LibraryRow]) {
        var folders: [LibraryRow] = [], documents: [LibraryRow] = []
        for row in rows {
            if row.isFolder { folders.append(row) } else { documents.append(row) }
        }
        return (folders, documents)
    }
}

enum LibraryOrder {
    static func key(_ folder: FolderID?) -> String { "library.order." + (folder?.raw ?? "root") }
    static func viewKey(_ folder: FolderID?) -> String { "libraryui.view." + (folder?.raw ?? "root") }

    static func moveParams(_ move: NibReflowMove<String>, folder: FolderID?) -> JSONValue {
        var result: JSONValue = ["refs": .array([.string(move.id)])]
        if let folder { result = result.merging(["folder": .string(NodeRef.folder(folder).description)]) }
        if let after = move.after { result = result.merging(["after": .string(after)]) }
        else if let before = move.before { result = result.merging(["before": .string(before)]) }
        return result
    }

    static func inserting(_ refs: [String], into order: [String], after: String?, before: String?) throws -> [String] {
        let moving = Set(refs)
        guard !refs.isEmpty, moving.count == refs.count, moving.isSubset(of: Set(order)) else {
            throw NibError.invalid("refs must be distinct siblings in this folder", path: "$.refs")
        }
        guard after == nil || before == nil else { throw NibError.invalid("provide after or before", path: "$.before") }
        var result = order.filter { !moving.contains($0) }
        var index = result.count
        if let anchor = after ?? before {
            guard let i = result.firstIndex(of: anchor) else { throw NibError.invalid("the anchor must be another sibling", path: after == nil ? "$.before" : "$.after") }
            index = i + (after == nil ? 0 : 1)
        }
        result.insert(contentsOf: refs, at: index)
        return result
    }
}
