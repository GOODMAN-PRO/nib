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

    static func from(_ node: LibraryNode) -> LibraryRow {
        LibraryRow(ref: node.kind == .folder ? NodeRef.folder(node.id).description : NodeRef.document(node.id).description,
                   kind: node.kind == .folder ? "folder" : node.documentKind?.rawValue ?? "document",
                   title: node.title, path: node.path, parent: node.parent.map { NodeRef.folder($0).description },
                   modified: node.modified, created: node.created, favorite: node.favorite, locked: node.locked,
                   sync: node.sync.rawValue, color: node.style?.color?.hex, icon: node.style?.icon, pages: node.pageCount)
    }
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
        case .modified: return String(localized: "Date modified")
        case .modifiedAscending: return String(localized: "Modified, oldest first")
        case .created: return String(localized: "Date created")
        case .createdAscending: return String(localized: "Created, oldest first")
        case .name: return String(localized: "Name, A to Z")
        case .nameDescending: return String(localized: "Name, Z to A")
        case .type: return String(localized: "Type")
        case .manual: return String(localized: "Manual")
        }
    }
}

enum LibrarySorting {
    static func rows(_ input: [LibraryRow], sort: LibrarySort, filter: LibraryFilter = .all,
                     manual: [String] = [], search: String = "") -> [LibraryRow] {
        let ranks = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = input.filter {
            (filter == .all || (filter == .folders ? $0.isFolder : !$0.isFolder)) &&
            (needle.isEmpty || $0.name.localizedStandardContains(needle))
        }
        return rows.sorted { a, b in
            // Folders and notebooks occupy separate sections, including in Manual.
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .manual:
                let x = ranks[a.ref] ?? Int.max, y = ranks[b.ref] ?? Int.max
                if x != y { return x < y }
            case .modified, .modifiedAscending:
                if a.modified != b.modified { return sort == .modified ? (a.modified ?? 0) > (b.modified ?? 0) : (a.modified ?? 0) < (b.modified ?? 0) }
            case .created, .createdAscending:
                if a.created != b.created { return sort == .created ? (a.created ?? 0) > (b.created ?? 0) : (a.created ?? 0) < (b.created ?? 0) }
            case .type:
                if a.kind != b.kind { return a.kind < b.kind }
            case .name, .nameDescending: break
            }
            let comparison = a.name.localizedStandardCompare(b.name)
            if comparison != .orderedSame { return sort == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending }
            return a.ref < b.ref
        }
    }

    static func compactColumns(width: CGFloat) -> Int {
        // The 393 pt design's three 110 pt covers plus two gutters occupy 362 pt;
        // account for the one-point rounding difference in the 361 pt safe content width.
        max(1, min(3, Int((max(width, 0) + NibSpacing.l + NibStroke.thin) / (NibMetrics.coverSizeCompact.width + NibSpacing.l))))
    }
    static func snapshot(_ rows: [LibraryRow]) -> NSDiffableDataSourceSnapshot<Int, String> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0, 1])
        var folders: [String] = [], documents: [String] = []
        var seen = Set<String>()
        for row in rows where seen.insert(row.ref).inserted {
            if row.isFolder { folders.append(row.ref) } else { documents.append(row.ref) }
        }
        snapshot.appendItems(folders, toSection: 0)
        snapshot.appendItems(documents, toSection: 1)
        return snapshot
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
        guard !refs.isEmpty, Set(refs).count == refs.count, Set(refs).isSubset(of: Set(order)) else {
            throw NibError.invalid("refs must be distinct siblings in this folder", path: "$.refs")
        }
        guard after == nil || before == nil else { throw NibError.invalid("provide after or before", path: "$.before") }
        let moving = Set(refs)
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
