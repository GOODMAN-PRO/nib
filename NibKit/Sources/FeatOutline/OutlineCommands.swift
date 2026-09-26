import Foundation
import NibContracts

// Custom outline (D-067, D-128) and page bookmarks (D-066). Every change is a command, so the panel, menus, plugins,
// the AI and the bridge share one path and the document's undo. Each command writes every record at most once
// (undo reverts a record only while it still carries the revision the command wrote).

enum OutlineCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(OutlineAdd.self)
        r.register(OutlineRename.self)
        r.register(OutlineMove.self)
        r.register(OutlineDelete.self)
        r.register(OutlineSortByPage.self)
        r.register(PageSetBookmarked.self)
    }

    static let entryRef = JSONSchema.str("outline entry ref outline:D/O")
    static let hint = "call query.get {\"ref\": \"doc:D\"} for the outline entries and their refs"
}

// MARK: - Tree

/// A position in the custom outline: under `parent` (nil = top level), right after the sibling `after` (nil = first).
struct OutlinePlacement: Equatable {
    var parent: NibID?
    var after: NibID?
}

/// The live custom outline of one document as a tree. Entries whose parent is missing, deleted or part of a parent
/// cycle (hand-written JSON, merges from other devices) sit at the top level, so every live entry stays reachable.
struct OutlineTree {
    /// Levels a custom outline may have: an entry, a sub-entry and a sub-sub-entry.
    static let maxDepth = 3
    /// The commands keep outlines 3 levels deep, but raw writes (node.insert / node.set, merges from other devices)
    /// can chain parents to any depth. An entry that would sit deeper than this starts over at the top level, so
    /// the recursive walks below stay shallow however the records were written.
    static let depthLimit = 16

    struct Row: Equatable {
        var id: NibID
        /// 1 = top level.
        var depth: Int
        var hasChildren: Bool
        var isExpanded: Bool
    }

    private(set) var entries: [NibID: OutlineEntry] = [:]
    private var parentOf: [NibID: NibID] = [:]
    private var childrenOf: [NibID: [NibID]] = [:]
    private var roots: [NibID] = []
    private var depthOf: [NibID: Int] = [:]

    init(_ outline: [OutlineEntry]) {
        let live = outline.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) }
        for e in live { entries[e.id] = e }
        for e in live {
            if let p = e.parent, p != e.id, entries[p] != nil { parentOf[e.id] = p }
        }
        // Resolve every depth once (iterative, O(n) overall): walk up to an entry whose depth is known, a root or a
        // repeat, then assign depths top-down. A parent cycle is broken at the link that closes it, and a chain past
        // `depthLimit` is cut there.
        for e in live where depthOf[e.id] == nil {
            var path: [NibID] = []
            var onPath: Set<NibID> = []
            var base = 0
            var current: NibID? = e.id
            while let id = current {
                if let known = depthOf[id] {
                    base = known
                    break
                }
                if onPath.contains(id) {
                    if let top = path.last { parentOf[top] = nil }
                    break
                }
                path.append(id)
                onPath.insert(id)
                current = parentOf[id]
            }
            var depth = base
            for id in path.reversed() {
                if depth >= OutlineTree.depthLimit {
                    parentOf[id] = nil
                    depth = 1
                } else {
                    depth += 1
                }
                depthOf[id] = depth
            }
        }
        for e in live {
            if let p = parentOf[e.id] {
                childrenOf[p, default: []].append(e.id)
            } else {
                roots.append(e.id)
            }
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Children in outline order (nil = the top level).
    func children(of parent: NibID?) -> [NibID] {
        guard let parent = parent else { return roots }
        return childrenOf[parent] ?? []
    }

    /// The effective parent (nil at the top level).
    func parent(of id: NibID) -> NibID? { parentOf[id] }

    /// 1 for a top-level entry.
    func depth(of id: NibID) -> Int { depthOf[id] ?? 1 }

    /// Where an entry sits now: its parent and the sibling right before it.
    func placement(of id: NibID) -> OutlinePlacement {
        let parent = parentOf[id]
        let siblings = children(of: parent)
        let index = siblings.firstIndex(of: id) ?? 0
        return OutlinePlacement(parent: parent, after: index > 0 ? siblings[index - 1] : nil)
    }

    /// Levels in the subtree rooted at `id` (1 for a leaf).
    func height(of id: NibID) -> Int {
        1 + ((childrenOf[id] ?? []).map { height(of: $0) }.max() ?? 0)
    }

    /// Every entry below `id`, in outline order.
    func descendants(of id: NibID) -> [NibID] {
        var out: [NibID] = []
        for child in childrenOf[id] ?? [] {
            out.append(child)
            out += descendants(of: child)
        }
        return out
    }

    func isAncestor(_ ancestor: NibID, of id: NibID) -> Bool {
        var current = id
        while let p = parentOf[current] {
            if p == ancestor { return true }
            current = p
        }
        return false
    }

    /// Why `entry` (with a subtree `height` levels tall) cannot go under `parent`; nil when it can.
    func placementError(_ entry: NibID?, height: Int, under parent: NibID?) -> String? {
        guard let parent = parent else { return nil }
        if let entry = entry, parent == entry || isAncestor(entry, of: parent) {
            return "an outline entry cannot be nested inside itself"
        }
        if depth(of: parent) + height > OutlineTree.maxDepth {
            return "outline entries nest at most \(OutlineTree.maxDepth) levels deep"
        }
        return nil
    }

    /// Visible rows in outline order; the children of collapsed entries are skipped.
    func flatten(isCollapsed: (NibID) -> Bool) -> [Row] {
        var rows: [Row] = []
        func walk(_ ids: [NibID], depth: Int) {
            for id in ids {
                let kids = childrenOf[id] ?? []
                let expanded = !kids.isEmpty && !isCollapsed(id)
                rows.append(Row(id: id, depth: depth, hasChildren: !kids.isEmpty, isExpanded: expanded))
                if expanded { walk(kids, depth: depth + 1) }
            }
        }
        walk(roots, depth: 1)
        return rows
    }

    // MARK: Moves offered by the panel, its menus and VoiceOver

    func moveUp(_ id: NibID) -> OutlinePlacement? {
        let parent = parentOf[id]
        let siblings = children(of: parent)
        guard let i = siblings.firstIndex(of: id), i > 0 else { return nil }
        return OutlinePlacement(parent: parent, after: i >= 2 ? siblings[i - 2] : nil)
    }

    func moveDown(_ id: NibID) -> OutlinePlacement? {
        let parent = parentOf[id]
        let siblings = children(of: parent)
        guard let i = siblings.firstIndex(of: id), i + 1 < siblings.count else { return nil }
        return OutlinePlacement(parent: parent, after: siblings[i + 1])
    }

    /// Nest under the previous sibling, as its last child.
    func indent(_ id: NibID) -> OutlinePlacement? {
        let siblings = children(of: parentOf[id])
        guard let i = siblings.firstIndex(of: id), i > 0 else { return nil }
        let target = siblings[i - 1]
        guard placementError(id, height: height(of: id), under: target) == nil else { return nil }
        return OutlinePlacement(parent: target, after: children(of: target).last)
    }

    /// Move up a level, right after the current parent.
    func outdent(_ id: NibID) -> OutlinePlacement? {
        guard let parent = parentOf[id] else { return nil }
        return OutlinePlacement(parent: parentOf[parent], after: parent)
    }

    /// Dropped onto `target`: becomes its last child.
    func drop(_ id: NibID, into target: NibID) -> OutlinePlacement? {
        guard entries[target] != nil, placementError(id, height: height(of: id), under: target) == nil else { return nil }
        return OutlinePlacement(parent: target, after: children(of: target).last { $0 != id })
    }

    /// Dropped between visible rows, before `rows[index]` (`index == rows.count` = after the last row).
    ///
    /// When the row above is expanded and its children follow, the entry becomes its first child. Otherwise the
    /// gap offers several levels: inside the row above (when it shows nothing of its own below it), next to it, or
    /// next to one of its ancestors, down to the level of the row below. `depth` (from the drag's horizontal
    /// position) picks the closest of those levels; nil keeps the row above's level.
    /// nil = no move (the entry's current place, or nesting too deep).
    func drop(_ id: NibID, at index: Int, in rows: [Row], depth: Int? = nil) -> OutlinePlacement? {
        let moving = Set([id] + descendants(of: id))
        let index = max(0, min(index, rows.count))
        let above = rows[..<index].last { !moving.contains($0.id) }
        let below = rows[index...].first { !moving.contains($0.id) }
        let placement: OutlinePlacement
        if let anchor = above {
            if let below = below, below.depth > anchor.depth {
                placement = OutlinePlacement(parent: anchor.id, after: nil)
            } else {
                // A collapsed row hides its children, so nothing may land inside it unseen.
                let nestable = !(anchor.hasChildren && !anchor.isExpanded)
                let lowest = min(below?.depth ?? 1, anchor.depth)
                let highest = anchor.depth + (nestable ? 1 : 0)
                let wanted = min(max(depth ?? anchor.depth, lowest), highest)
                if wanted > anchor.depth {
                    placement = OutlinePlacement(parent: anchor.id, after: nil)
                } else {
                    var level = anchor.id
                    for _ in 0..<(anchor.depth - wanted) {
                        guard let p = parentOf[level] else { break }
                        level = p
                    }
                    placement = OutlinePlacement(parent: parentOf[level], after: level)
                }
            }
        } else {
            placement = OutlinePlacement(parent: nil, after: nil)
        }
        guard entries[id] != nil, placement != self.placement(of: id) else { return nil }
        return placementError(id, height: height(of: id), under: placement.parent) == nil ? placement : nil
    }
}

// MARK: - Order keys

enum OutlineOrder {
    /// The order key for an entry inserted at `index` among `siblings` (in outline order, without the entry itself).
    /// When the neighbours' keys cannot bracket a new key (equal or empty keys from merges or raw inserts), the whole
    /// group gets fresh keys: `rekeyed` lists the siblings that need writing.
    static func insert(at index: Int, among siblings: [(id: NibID, order: String)]) -> (key: String, rekeyed: [(id: NibID, order: String)]) {
        let index = max(0, min(index, siblings.count))
        let prev = index > 0 ? siblings[index - 1].order : nil
        let next = index < siblings.count ? siblings[index].order : nil
        var usable = !(prev?.isEmpty ?? false) && !(next?.isEmpty ?? false)
        if let a = prev, let b = next, a >= b { usable = false }
        if usable { return (key: FractionalIndex.between(prev, next), rekeyed: []) }
        let keys = FractionalIndex.sequence(after: nil, count: siblings.count + 1)
        var rekeyed: [(id: NibID, order: String)] = []
        var k = 0
        for (i, sibling) in siblings.enumerated() {
            if i == index { k += 1 }
            if sibling.order != keys[k] { rekeyed.append((id: sibling.id, order: keys[k])) }
            k += 1
        }
        return (key: keys[index], rekeyed: rekeyed)
    }

    /// `ids` ordered by page number (entries without a live page last), stable otherwise.
    static func byPage(_ ids: [NibID], entries: [NibID: OutlineEntry], pageIndex: [PageID: Int]) -> [NibID] {
        func key(_ id: NibID) -> Int { entries[id]?.page.flatMap { pageIndex[$0] } ?? Int.max }
        return ids.enumerated()
            .sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }
            .map { $0.element }
    }
}

// MARK: - Arguments

@MainActor
enum OutlineArgs {
    static let maxTitleLength = 500

    static func document(_ ref: String, path: String) throws -> DocumentID {
        if let r = NodeRef(ref) {
            guard case let .document(doc) = r else {
                throw NibError(.invalidParams, "expected a document ref like doc:D", path: path)
            }
            return doc
        }
        guard NibID.isValid(ref) else { throw NibError(.invalidParams, "expected a document ref like doc:D", path: path) }
        return NibID(ref)
    }

    /// A live (not trashed) page.
    static func livePage(_ ref: String, path: String, _ ctx: CommandContext) throws -> (DocumentID, PageRecord) {
        guard case let .page(doc, pageID)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path)
        }
        guard let page = try ctx.workspace.content(doc).page(pageID), !page.deleted else {
            throw NibError(.notFound, "page \(pageID.raw) not found in document \(doc.raw) (or it is in the Trash)", path: path)
        }
        return (doc, page)
    }

    /// The document of an outline entry ref.
    static func entryDocument(_ ref: String, path: String) throws -> DocumentID {
        guard case let .outline(doc, _)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected an outline entry ref like outline:D/O", path: path, hint: OutlineCommands.hint)
        }
        return doc
    }

    /// A live entry of `doc`, given as outline:D/O or a bare id.
    static func entry(_ ref: String, doc: DocumentID, tree: OutlineTree, path: String) throws -> NibID {
        let id: NibID
        if case let .outline(d, o)? = NodeRef(ref) {
            guard d == doc else {
                throw NibError(.invalidParams, "entry \(o.raw) belongs to another document", path: path)
            }
            id = o
        } else if NibID.isValid(ref) {
            id = NibID(ref)
        } else {
            throw NibError(.invalidParams, "expected an outline entry ref like outline:D/O", path: path, hint: OutlineCommands.hint)
        }
        guard tree.entries[id] != nil else {
            throw NibError(.notFound, "outline entry \(id.raw) not found in document \(doc.raw)", path: path,
                           hint: OutlineCommands.hint)
        }
        return id
    }

    static func title(_ raw: String, path: String = "$.title") throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NibError(.invalidParams, "title must not be empty", path: path) }
        guard title.count <= maxTitleLength else {
            throw NibError(.invalidParams, "title is longer than \(maxTitleLength) characters", path: path)
        }
        return title
    }

    static func newID(_ raw: String?) throws -> NibID {
        guard let raw = raw else { return NibID.make() }
        guard NibID.isValid(raw) else {
            throw NibError(.invalidParams, "id must be 1-64 characters of A-Z a-z 0-9 _ -", path: "$.id")
        }
        return NibID(raw)
    }

    /// Writes the siblings an insertion had to re-key.
    static func rekey(_ rekeyed: [(id: NibID, order: String)], tree: OutlineTree, doc: DocumentID, _ tx: DocTransaction) throws {
        for r in rekeyed {
            guard var sibling = tree.entries[r.id] else { continue }
            sibling.order = r.order
            try tx.put(sibling, doc: doc)
        }
    }
}

/// Params the panel and the menus hand to the commands above.
enum OutlineParams {
    static func move(doc: DocumentID, entry: NibID, _ placement: OutlinePlacement) -> JSONValue {
        var o: [String: JSONValue] = ["entry": .string(NodeRef.outline(doc, entry).description)]
        if let parent = placement.parent { o["parent"] = .string(NodeRef.outline(doc, parent).description) }
        if let after = placement.after { o["after"] = .string(NodeRef.outline(doc, after).description) }
        return .object(o)
    }

    /// Adds `page` with its default title (the page's own title, else "Page N").
    static func add(doc: DocumentID, page: PageRecord, content: DocumentContent) -> JSONValue {
        ["page": .string(NodeRef.page(doc, page.id).description), "title": .string(defaultTitle(page, in: content))]
    }

    static func bookmark(doc: DocumentID, pages: [PageID], on: Bool) -> JSONValue {
        ["pages": .array(pages.map { JSONValue.string(NodeRef.page(doc, $0).description) }), "on": .bool(on)]
    }

    static func defaultTitle(_ page: PageRecord, in content: DocumentContent) -> String {
        if let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let number = (content.pageIndex(page.id) ?? 0) + 1
        return String(localized: "Page \(number)")
    }
}

// MARK: - outline.add

struct OutlineAdd: NibCommand {
    struct Params: Codable {
        var page: String
        var title: String
        var parent: String?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "outline.add", title: "Add to Outline",
        summary: "Add a page to the document's custom outline (table of contents), optionally under a parent entry; outlines nest at most 3 levels. Returns the entry ref.",
        params: .obj([
            "page": .str("page ref page:D/P the entry opens"),
            "title": .str("entry title"),
            "parent": .str("parent entry outline:D/O (omit for the top level); the new entry becomes its last child"),
            "id": .str("caller-chosen id of the new entry")
        ], required: ["page", "title"]),
        examples: [
            ["page": "page:FIXTUREDOC01/FIXTUREPG002", "title": "Chapter 2"],
            ["page": "page:FIXTUREDOC01/FIXTUREPG003", "title": "Worked examples", "parent": "outline:FIXTUREDOC01/FIXTUREOUT01"]
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try OutlineArgs.livePage(p.page, path: "$.page", ctx)
        let title = try OutlineArgs.title(p.title)
        let id = try OutlineArgs.newID(p.id)
        try ctx.mutate { (tx: DocTransaction) throws -> Void in
            let content = try tx.content(doc)
            guard !content.outline.contains(where: { $0.id == id }) else {
                throw NibError(.invalidParams, "outline entry id \(id.raw) is already used", path: "$.id")
            }
            let tree = OutlineTree(content.outline)
            let parent = try p.parent.map { try OutlineArgs.entry($0, doc: doc, tree: tree, path: "$.parent") }
            if let reason = tree.placementError(nil, height: 1, under: parent) {
                throw NibError(.invalidParams, reason, path: "$.parent", hint: "add it under an entry at most 2 levels deep")
            }
            let siblings = tree.children(of: parent).map { (id: $0, order: tree.entries[$0]?.order ?? "") }
            let placed = OutlineOrder.insert(at: siblings.count, among: siblings)
            try OutlineArgs.rekey(placed.rekeyed, tree: tree, doc: doc, tx)
            try tx.put(OutlineEntry(id: id, title: title, page: page.id, parent: parent, order: placed.key), doc: doc)
        }
        return Output(ref: NodeRef.outline(doc, id).description)
    }
}

// MARK: - outline.rename

struct OutlineRename: NibCommand {
    struct Params: Codable {
        var entry: String
        var title: String
    }

    static let descriptor = CommandDescriptor(
        id: "outline.rename", title: "Rename Outline Entry",
        summary: "Rename a custom outline entry.",
        params: .obj(["entry": OutlineCommands.entryRef, "title": .str("new title")], required: ["entry", "title"]),
        examples: [["entry": "outline:FIXTUREDOC01/FIXTUREOUT01", "title": "Kinematics"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try OutlineArgs.entryDocument(p.entry, path: "$.entry")
        let title = try OutlineArgs.title(p.title)
        try ctx.mutate { (tx: DocTransaction) throws -> Void in
            let tree = OutlineTree(try tx.content(doc).outline)
            let entryID = try OutlineArgs.entry(p.entry, doc: doc, tree: tree, path: "$.entry")
            guard var entry = tree.entries[entryID], entry.title != title else { return }
            entry.title = title
            try tx.put(entry, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - outline.move

struct OutlineMove: NibCommand {
    struct Params: Codable {
        var entry: String
        var parent: String?
        var after: String?
    }

    static let descriptor = CommandDescriptor(
        id: "outline.move", title: "Move Outline Entry",
        summary: "Reorder or nest a custom outline entry with its sub-entries: under parent (omit = top level), after a sibling (omit = first). Max 3 levels.",
        params: .obj([
            "entry": OutlineCommands.entryRef,
            "parent": .str("new parent entry outline:D/O (omit for the top level)"),
            "after": .str("sibling outline:D/O under the new parent to place it after (omit to place it first)")
        ], required: ["entry"]),
        examples: [["entry": "outline:FIXTUREDOC01/FIXTUREOUT01"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try OutlineArgs.entryDocument(p.entry, path: "$.entry")
        try ctx.mutate { (tx: DocTransaction) throws -> Void in
            let tree = OutlineTree(try tx.content(doc).outline)
            let entryID = try OutlineArgs.entry(p.entry, doc: doc, tree: tree, path: "$.entry")
            guard let entry = tree.entries[entryID] else { return }
            let parent = try p.parent.map { try OutlineArgs.entry($0, doc: doc, tree: tree, path: "$.parent") }
            if let reason = tree.placementError(entryID, height: tree.height(of: entryID), under: parent) {
                throw NibError(.invalidParams, reason, path: "$.parent",
                               hint: "an entry with sub-entries needs a shallower parent; outlines nest at most 3 levels")
            }
            let siblings = tree.children(of: parent).filter { $0 != entryID }
            var index = 0
            if let raw = p.after {
                let after = try OutlineArgs.entry(raw, doc: doc, tree: tree, path: "$.after")
                guard let i = siblings.firstIndex(of: after) else {
                    throw NibError(.invalidParams, "'after' must be another entry under the target parent", path: "$.after",
                                   hint: "omit after to place the entry first under its parent")
                }
                index = i + 1
            }
            let current = tree.children(of: tree.parent(of: entryID))
            if entry.parent == parent, tree.parent(of: entryID) == parent, current.firstIndex(of: entryID) == index { return }
            let placed = OutlineOrder.insert(at: index, among: siblings.map { (id: $0, order: tree.entries[$0]?.order ?? "") })
            try OutlineArgs.rekey(placed.rekeyed, tree: tree, doc: doc, tx)
            var moved = entry
            moved.parent = parent
            moved.order = placed.key
            try tx.put(moved, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - outline.delete

struct OutlineDelete: NibCommand {
    struct Params: Codable {
        var entry: String
    }

    struct Output: Codable {
        /// The entry and its sub-entries.
        var removed: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "outline.delete", title: "Delete Outline Entry",
        summary: "Remove a custom outline entry and its sub-entries (the pages stay).",
        params: .obj(["entry": OutlineCommands.entryRef], required: ["entry"]),
        examples: [["entry": "outline:FIXTUREDOC01/FIXTUREOUT01"]],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try OutlineArgs.entryDocument(p.entry, path: "$.entry")
        let removed = try ctx.mutate { (tx: DocTransaction) throws -> [String] in
            let tree = OutlineTree(try tx.content(doc).outline)
            let entryID = try OutlineArgs.entry(p.entry, doc: doc, tree: tree, path: "$.entry")
            var refs: [String] = []
            for id in [entryID] + tree.descendants(of: entryID) {
                guard var e = tree.entries[id] else { continue }
                e.deleted = true
                try tx.put(e, doc: doc)
                refs.append(NodeRef.outline(doc, id).description)
            }
            return refs
        }
        return Output(removed: removed)
    }
}

// MARK: - outline.sortByPage

struct OutlineSortByPage: NibCommand {
    struct Params: Codable {
        var doc: String
    }

    static let descriptor = CommandDescriptor(
        id: "outline.sortByPage", title: "Sort by Page Number",
        summary: "Sort the custom outline by page number at every level (entries keep their nesting).",
        params: .obj(["doc": .str("document ref doc:D")], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try OutlineArgs.document(p.doc, path: "$.doc")
        try ctx.mutate { (tx: DocTransaction) throws -> Void in
            let content = try tx.content(doc)
            let tree = OutlineTree(content.outline)
            var pageIndex: [PageID: Int] = [:]
            for (i, page) in content.livePages.enumerated() { pageIndex[page.id] = i }
            let parents: [NibID?] = [nil] + tree.entries.keys.sorted().map { Optional($0) }
            for parent in parents {
                let kids = tree.children(of: parent)
                guard kids.count > 1 else { continue }
                let sorted = OutlineOrder.byPage(kids, entries: tree.entries, pageIndex: pageIndex)
                guard sorted != kids else { continue }
                let keys = FractionalIndex.sequence(after: nil, count: sorted.count)
                for (i, id) in sorted.enumerated() {
                    guard var e = tree.entries[id], e.order != keys[i] else { continue }
                    e.order = keys[i]
                    try tx.put(e, doc: doc)
                }
            }
        }
        return NoResult()
    }
}

// MARK: - page.setBookmarked

struct PageSetBookmarked: NibCommand {
    /// Both are required for plugins, the AI and the bridge (schema). The native bookmark shortcut sends `{}`:
    /// the window's current page, toggled.
    struct Params: Codable {
        var pages: [String]?
        var on: Bool?
    }

    struct Output: Codable {
        /// Pages whose bookmark changed.
        var pages: [String]
        var on: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "page.setBookmarked", title: "Bookmark Pages",
        summary: "Bookmark (on: true) or unbookmark pages; bookmarked pages appear in the Bookmarks tab, the page sidebar filter and Favourites.",
        params: .obj([
            "pages": .arr(.ref, "page refs page:D/P"),
            "on": .bool("true = bookmark, false = remove the bookmark")
        ], required: ["pages", "on"]),
        examples: [["pages": ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG003"], "on": true]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let refs: [String]
        if let pages = p.pages {
            guard !pages.isEmpty else {
                throw NibError(.invalidParams, "pages must list at least one page ref", path: "$.pages")
            }
            refs = pages
        } else {
            // The shortcut (⌥⌘B) is document-wide: only a notebook's current page is bookmarkable. Anywhere else
            // (a text document, a whiteboard board, no page) it does nothing rather than raising an error.
            guard let session = ctx.activeSession, let doc = session.document, let page = session.page,
                  (try? ctx.workspace.content(doc))?.meta.kind == .notebook else {
                return Output(pages: [], on: false)
            }
            refs = [NodeRef.page(doc, page).description]
        }
        var targets: [(index: Int, doc: DocumentID, page: PageID)] = []
        var seen = Set<String>()
        for (i, ref) in refs.enumerated() {
            guard case let .page(doc, page)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.pages[\(i)]")
            }
            if seen.insert(NodeRef.page(doc, page).description).inserted { targets.append((index: i, doc: doc, page: page)) }
        }
        let on: Bool
        if let value = p.on {
            on = value
        } else {
            let first = targets[0]
            let current = try ctx.workspace.content(first.doc).page(first.page)
            on = !(current?.bookmarked ?? false)
        }
        let changed = try ctx.mutate { (tx: DocTransaction) throws -> [String] in
            var out: [String] = []
            for t in targets {
                guard var page = try tx.content(t.doc).page(t.page), !page.deleted else {
                    throw NibError(.notFound, "page \(t.page.raw) not found in document \(t.doc.raw) (or it is in the Trash)",
                                   path: "$.pages[\(t.index)]")
                }
                guard page.bookmarked != on else { continue }
                page.bookmarked = on
                try tx.put(page, doc: t.doc)
                out.append(NodeRef.page(t.doc, t.page).description)
            }
            return out
        }
        return Output(pages: changed, on: on)
    }
}
