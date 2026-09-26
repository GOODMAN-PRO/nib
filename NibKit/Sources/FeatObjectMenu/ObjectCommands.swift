import Foundation
import NibContracts

// The generic object commands behind the object menu (T-030, T-031, T-033, T-036): delete, arrange, recolour and
// lock. Every one takes item refs on any page (grouped per page, one undo step), rejects locked items with a hint
// (except item.setLocked), and runs the same for the user, plugins, the AI and the bridge. The planning logic is pure
// (`DeletePlan`, `ArrangePlanner`, `Recolor`, `Locking`) so the tests pin it without a canvas.

// MARK: - Targets

/// One `item:D/P/I` ref of a command's `refs`, with the JSON path an error points at.
struct ItemTarget: Equatable {
    let doc: DocumentID
    let page: PageID
    let id: ElementID
    let path: String

    var ref: String { NodeRef.item(doc, page, id).description }
}

@MainActor
enum ItemTargets {
    static let refHint = "item refs look like item:DOC/PAGE/ITEM (query.find lists a page's items)"
    static let unlockHint = "unlock it first with item.setLocked {refs, locked: false}"

    /// `refs`, or the invoking window's selection when the user leaves them out (key commands and menus run with
    /// static params). nil = the user acted with nothing selected: the command then does nothing. Other callers must
    /// name the items.
    static func resolve(_ refs: [String]?, _ ctx: CommandContext) throws -> [ItemTarget]? {
        let given = refs ?? []
        if given.isEmpty && !ctx.principal.isUser {
            throw NibError(.invalidParams, "refs is empty", path: "$.refs", hint: refHint)
        }
        let list = ctx.refsOrSelection(refs)
        guard !list.isEmpty else { return nil }
        return try parse(list)
    }

    /// Parses item refs (duplicates dropped), keeping each one's JSON path.
    static func parse(_ refs: [String]) throws -> [ItemTarget] {
        var seen = Set<String>()
        var out: [ItemTarget] = []
        for (i, r) in refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(r) else {
                throw NibError(.invalidParams, "'\(r)' is not an item ref", path: "$.refs[\(i)]", hint: refHint)
            }
            if seen.insert(NodeRef.item(doc, page, id).description).inserted {
                out.append(ItemTarget(doc: doc, page: page, id: id, path: "$.refs[\(i)]"))
            }
        }
        return out
    }

    /// Targets grouped by (document, page), in first-seen order.
    static func byPage(_ targets: [ItemTarget]) -> [(doc: DocumentID, page: PageID, targets: [ItemTarget])] {
        var out: [(doc: DocumentID, page: PageID, targets: [ItemTarget])] = []
        for t in targets {
            if let i = out.firstIndex(where: { $0.doc == t.doc && $0.page == t.page }) {
                out[i].targets.append(t)
            } else {
                out.append((doc: t.doc, page: t.page, targets: [t]))
            }
        }
        return out
    }

    /// The page's live items by id, after checking that every target is one of them and (unless `allowLocked`) not
    /// locked.
    static func check(_ targets: [ItemTarget], items: [Item], allowLocked: Bool) throws -> [ElementID: Item] {
        var byID: [ElementID: Item] = [:]
        for it in items { byID[it.id] = it }
        for t in targets {
            guard let it = byID[t.id] else {
                throw NibError(.notFound, "item \(t.id.raw) not found on page \(t.page.raw)", path: t.path,
                               hint: "call query.find to list the page's items")
            }
            if !allowLocked && it.locked {
                throw NibError(.invalidParams, "item \(t.id.raw) is locked", path: t.path, hint: unlockHint)
            }
        }
        return byID
    }

    /// Refuses documents the store will not write (saved by a newer Nib, unreadable files).
    static func ensureWritable(_ groups: [(doc: DocumentID, page: PageID, targets: [ItemTarget])],
                               _ ctx: CommandContext) throws {
        for g in groups where ctx.isReadOnly(g.doc) {
            throw NibError(.unsupported, "document \(g.doc.raw) is read-only", path: g.targets.first?.path,
                           hint: "the document was saved by a newer version of Nib or its files cannot be written")
        }
    }

    /// Links the undo step across documents when the refs span several (one undo restores all of them).
    static func linkIfNeeded(_ groups: [(doc: DocumentID, page: PageID, targets: [ItemTarget])], _ ctx: CommandContext) {
        if Set(groups.map { $0.doc }).count > 1 { ctx.linkUndoAcrossDocuments() }
    }
}

// MARK: - item.delete

/// What deleting some items does to a page (pure). The targets go, and so does everything attached to them (a
/// container's contents, ink on a sticky note); comment threads pinned to them are unpinned instead (a discussion is
/// not part of the object). Connectors survive a deleted end with that end detached at its last point, and go too
/// when both of their anchored ends go.
struct DeletePlan: Equatable {
    /// Every item to tombstone, targets first.
    var deleted: [ElementID]
    /// Items rewritten so the page stays valid: connectors with a detached end, unpinned comment threads.
    var updated: [Item]

    static func make(targets: [ElementID], items: [Item]) -> DeletePlan {
        let live = items.filter { !$0.deleted }
        var children: [ElementID: [Item]] = [:]
        for it in live {
            if let parent = it.attachedTo { children[parent, default: []].append(it) }
        }
        var gone = Set<ElementID>()
        var order: [ElementID] = []
        var queue: [ElementID] = []
        func add(_ id: ElementID) {
            if gone.insert(id).inserted {
                order.append(id)
                queue.append(id)
            }
        }
        for t in targets { add(t) }
        var unpinned: Set<ElementID> = []
        while true {
            while !queue.isEmpty {
                let id = queue.removeFirst()
                for child in children[id] ?? [] {
                    if child.kind == .comment {
                        unpinned.insert(child.id)
                    } else {
                        add(child.id)
                    }
                }
            }
            var grew = false
            for c in live where c.kind == .connector && !gone.contains(c.id) {
                guard let con = c.connector, let from = con.from.item, let to = con.to.item else { continue }
                if gone.contains(from) && gone.contains(to) {
                    add(c.id)
                    grew = true
                }
            }
            if !grew { break }
        }
        var updated: [Item] = []
        for it in live where !gone.contains(it.id) {
            var copy = it
            var changed = false
            if unpinned.contains(it.id) {
                copy.attachedTo = nil
                changed = true
            }
            if var con = copy.connector {
                if let end = con.from.item, gone.contains(end) {
                    con.from = ConnectorEnd(point: con.from.point)
                    changed = true
                }
                if let end = con.to.item, gone.contains(end) {
                    con.to = ConnectorEnd(point: con.to.point)
                    changed = true
                }
                copy.connector = con
            }
            if changed { updated.append(copy) }
        }
        return DeletePlan(deleted: order, updated: updated)
    }
}

/// `item.delete {refs}`: deletes items (attached contents go too; connectors to them are detached, or deleted when
/// both ends go). One undo step brings everything back.
struct ItemDelete: NibCommand {
    struct Params: Codable {
        var refs: [String]?
    }

    struct Output: Codable {
        /// Every item deleted: the targets and what went with them.
        var deleted: [String]
        /// Items kept but changed: connectors with a detached end, unpinned comment threads.
        var detached: [String]
    }

    static let exampleShape: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"]]
    static let exampleMany: JSONValue = [
        "refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"]
    ]

    static let descriptor = CommandDescriptor(
        id: "item.delete", title: "Delete",
        summary: "Delete items; attached contents go too, connectors to them are detached (or deleted when both ends go).",
        params: .obj(["refs": .arr(.ref, "item refs, e.g. item:D/P/I (any pages; locked items are refused)")],
                     required: ["refs"]),
        examples: [exampleShape, exampleMany],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let targets = try ItemTargets.resolve(p.refs, ctx) else { return Output(deleted: [], detached: []) }
        let groups = ItemTargets.byPage(targets)
        try ItemTargets.ensureWritable(groups, ctx)
        var deleted: [(doc: DocumentID, page: PageID, ids: [ElementID])] = []
        var detached: [String] = []
        try ctx.mutate { tx in
            for g in groups {
                let items = try tx.items(g.doc, page: g.page)
                _ = try ItemTargets.check(g.targets, items: items, allowLocked: false)
                let plan = DeletePlan.make(targets: g.targets.map { $0.id }, items: items)
                try tx.put(plan.updated, doc: g.doc, page: g.page)
                try tx.delete(items: plan.deleted, doc: g.doc, page: g.page)
                deleted.append((doc: g.doc, page: g.page, ids: plan.deleted))
                detached += plan.updated.map { NodeRef.item(g.doc, g.page, $0.id).description }
            }
        }
        ItemTargets.linkIfNeeded(groups, ctx)
        if !ctx.dryRun {
            for d in deleted { SelectionPruning.remove(d.ids, doc: d.doc, page: d.page, ctx) }
        }
        let refs = deleted.flatMap { d in d.ids.map { NodeRef.item(d.doc, d.page, $0).description } }
        return Output(deleted: refs, detached: detached)
    }
}

/// Keeps every window's selection honest after items are deleted: they leave it, and an emptied selection clears (so
/// the object menu and the handles go away).
@MainActor
enum SelectionPruning {
    static func remove(_ ids: [ElementID], doc: DocumentID, page: PageID, _ ctx: CommandContext) {
        let gone = Set(ids)
        guard !gone.isEmpty else { return }
        for s in ctx.services.sessions.sessions where s.selection.doc == doc && s.selection.page == page {
            guard s.selection.items.contains(where: { gone.contains($0) }) else { continue }
            let rest = s.selection.items.filter { !gone.contains($0) }
            if rest.isEmpty {
                s.selection = Selection()
                continue
            }
            let keep = Set(rest)
            let items = ((try? ctx.workspace.items(doc, page: page)) ?? []).filter { keep.contains($0.id) }
            let bounds = items.map { $0.bounds }.reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r }
            s.selection = Selection(doc: doc, page: page, items: rest, bounds: bounds)
        }
    }
}

// MARK: - item.arrange

enum ArrangeOrder: String, Codable, CaseIterable {
    /// Above everything else on the page.
    case front
    /// Below everything else on the page.
    case back
    /// One step up: just above the nearest item above that overlaps the moving items.
    case forward
    /// One step down: just below the nearest item below that overlaps the moving items.
    case backward
}

/// Z-order planning (pure). The moving items keep their order among themselves and travel as one block; the others
/// never change their keys, so an arrange writes only the items that move.
enum ArrangePlanner {
    /// The page's order (bottom first) after moving `moving` (ids in `order`). A step (forward, backward) passes the
    /// nearest other item that overlaps the moving items (`overlaps`), so every step changes what you see; with nothing
    /// overlapping in that direction the order stays as it is.
    static func reorder(_ order: [ElementID], moving: Set<ElementID>, to target: ArrangeOrder,
                        overlaps: (ElementID) -> Bool) -> [ElementID] {
        let block = order.filter { moving.contains($0) }
        guard !block.isEmpty, block.count < order.count else { return order }
        let others = order.filter { !moving.contains($0) }
        switch target {
        case .front:
            return others + block
        case .back:
            return block + others
        case .forward:
            guard let top = order.lastIndex(where: { moving.contains($0) }),
                  let pass = order.indices.first(where: { $0 > top && overlaps(order[$0]) }) else { return order }
            let below = order[...pass].filter { !moving.contains($0) }
            return below + block + Array(order[(pass + 1)...])
        case .backward:
            guard let bottom = order.firstIndex(where: { moving.contains($0) }),
                  let pass = order.indices.last(where: { $0 < bottom && overlaps(order[$0]) }) else { return order }
            let above = order[pass...].filter { !moving.contains($0) }
            return Array(order[..<pass]) + block + above
        }
    }

    /// New z keys for the moving items so the page sorts as `newOrder` (`z` = every item's current key). Each run of
    /// moving items gets balanced keys between its fixed neighbours. nil when two fixed neighbours share a key (a
    /// merge can leave ties): the caller then re-keys the page with `rekey`.
    static func keys(for newOrder: [ElementID], moving: Set<ElementID>, z: [ElementID: String]) -> [ElementID: String]? {
        var out: [ElementID: String] = [:]
        var run: [ElementID] = []
        var before: String?
        func flush(_ after: String?) -> Bool {
            guard !run.isEmpty else { return true }
            let lo = before.flatMap { $0.isEmpty ? nil : $0 }
            let hi = after.flatMap { $0.isEmpty ? nil : $0 }
            if let a = lo, let b = hi, !(a < b) { return false }
            for (id, key) in zip(run, FractionalIndex.balanced(count: run.count, after: lo, before: hi)) { out[id] = key }
            run = []
            return true
        }
        for id in newOrder {
            if moving.contains(id) {
                run.append(id)
            } else {
                guard flush(z[id]) else { return nil }
                before = z[id]
            }
        }
        guard flush(nil) else { return nil }
        return out
    }

    /// Fresh balanced keys for the whole page in `newOrder`, returning only the keys that change.
    static func rekey(_ newOrder: [ElementID], z: [ElementID: String]) -> [ElementID: String] {
        var out: [ElementID: String] = [:]
        for (id, key) in zip(newOrder, FractionalIndex.balanced(count: newOrder.count)) where z[id] != key { out[id] = key }
        return out
    }

    /// `ids` plus everything attached to them, transitively (a container's contents move with it).
    static func withAttached(_ ids: Set<ElementID>, items: [Item]) -> Set<ElementID> {
        var children: [ElementID: [ElementID]] = [:]
        for it in items {
            if let parent = it.attachedTo { children[parent, default: []].append(it.id) }
        }
        var out = ids
        var queue = Array(ids)
        while let id = queue.popLast() {
            for child in children[id] ?? [] where out.insert(child).inserted { queue.append(child) }
        }
        return out
    }
}

/// `item.arrange {refs, to}`: bring to front, send to back, or one visible step forward or backward.
struct ItemArrange: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var to: ArrangeOrder
    }

    struct Output: Codable {
        /// Items whose place in the stacking order changed.
        var moved: [String]
    }

    static let exampleFront: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], "to": "front"]
    static let exampleForward: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], "to": "forward"]
    static let exampleBack: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01"], "to": "back"]

    static let descriptor = CommandDescriptor(
        id: "item.arrange", title: "Arrange",
        summary: "Bring items to front / send to back, or step them forward / backward past the nearest overlapping item.",
        params: .obj(["refs": .arr(.ref, "item refs, e.g. item:D/P/I"),
                      "to": .str("front | back | forward | backward", choices: ArrangeOrder.allCases.map { $0.rawValue })],
                     required: ["refs", "to"]),
        examples: [exampleFront, exampleForward, exampleBack],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let targets = try ItemTargets.resolve(p.refs, ctx) else { return Output(moved: []) }
        let groups = ItemTargets.byPage(targets)
        try ItemTargets.ensureWritable(groups, ctx)
        let content = ctx.content
        var moved: [String] = []
        try ctx.mutate { tx in
            for g in groups {
                let items = try tx.items(g.doc, page: g.page)
                let byID = try ItemTargets.check(g.targets, items: items, allowLocked: false)
                let chosen = Set(g.targets.map { $0.id })
                let moving = ArrangePlanner.withAttached(chosen, items: items)
                let reach = moving.compactMap { byID[$0] }.map { content.paintBounds(for: $0) }
                    .reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r } ?? .zero
                let order = items.map { $0.id }
                let newOrder = ArrangePlanner.reorder(order, moving: moving, to: p.to) { id in
                    byID[id].map { content.paintBounds(for: $0).intersects(reach) } ?? false
                }
                guard newOrder != order else { continue }
                var z: [ElementID: String] = [:]
                for it in items { z[it.id] = it.z }
                let keys = ArrangePlanner.keys(for: newOrder, moving: moving, z: z) ?? ArrangePlanner.rekey(newOrder, z: z)
                let changed = items.compactMap { it -> Item? in
                    guard let key = keys[it.id], key != it.z else { return nil }
                    var copy = it
                    copy.z = key
                    return copy
                }
                try tx.put(changed, doc: g.doc, page: g.page)
                moved += changed.map { NodeRef.item(g.doc, g.page, $0.id).description }
            }
        }
        ItemTargets.linkIfNeeded(groups, ctx)
        return Output(moved: moved)
    }
}

// MARK: - item.recolor

/// Recolouring rules (pure): ink takes the colour (a highlighter keeps its see-through alpha; patterned tape keeps its
/// pattern), shapes and connectors take it on the outline and the fill (a fill keeps its own transparency; a
/// fill-only shape stays outline-free), text boxes on every run, sticky notes and maths objects on the whole object.
/// Images, comments and custom items have no colour of their own.
enum Recolor {
    static func apply(_ item: Item, color: RGBA) -> Item? {
        var it = item
        switch item.kind {
        case .stroke:
            guard var s = item.stroke else { return nil }
            switch s.style.tool {
            case .pen, .pencil:
                s.style.color = color
            case .highlighter:
                s.style.color = color.a == 255 ? RGBA(color.r, color.g, color.b, RGBA.highlighterAlpha) : color
            case .tape:
                guard s.style.tapePattern == nil else { return nil }
                s.style.color = color
            }
            it.stroke = s
        case .shape:
            guard var s = item.shape else { return nil }
            s.style = outlineAndFill(s.style, color)
            it.shape = s
        case .connector:
            guard var c = item.connector else { return nil }
            c.style = outlineAndFill(c.style, color)
            it.connector = c
        case .text:
            guard var t = item.text else { return nil }
            t.text = recolored(t.text, color)
            t.style.defaults.color = color
            it.text = t
        case .sticky:
            guard var s = item.sticky else { return nil }
            s.color = color
            it.sticky = s
        case .math:
            guard var m = item.math else { return nil }
            m.color = color
            it.math = m
        case .image, .comment, .custom:
            return nil
        }
        return it
    }

    /// True when `item` has a colour `item.recolor` can change.
    static func canRecolor(_ item: Item) -> Bool { apply(item, color: .black) != nil }

    /// The colour an item shows (ink, outline, text, note), for the colour popover's current swatch.
    static func color(of item: Item) -> RGBA? {
        switch item.kind {
        case .stroke: return item.stroke?.style.color
        case .shape: return item.shape.flatMap { $0.style.strokeColor ?? $0.style.fillColor }
        case .connector: return item.connector?.style.strokeColor
        case .text: return item.text.flatMap { $0.text.paragraphs.first?.runs.first?.attrs.color ?? $0.style.defaults.color }
        case .sticky: return item.sticky?.color
        case .math: return item.math?.color
        case .image, .comment, .custom: return nil
        }
    }

    static func outlineAndFill(_ style: ShapeItemStyle, _ color: RGBA) -> ShapeItemStyle {
        var s = style
        if let fill = s.fillColor {
            s.fillColor = RGBA(color.r, color.g, color.b, UInt8((Double(fill.a) * color.alpha).rounded()))
        }
        if s.strokeColor != nil || s.fillColor == nil { s.strokeColor = color }
        return s
    }

    static func recolored(_ text: RichText, _ color: RGBA) -> RichText {
        var t = text
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices { t.paragraphs[p].runs[r].attrs.color = color }
        }
        return t
    }
}

/// `item.recolor {refs, color}`: recolours ink, shapes (outline and fill), text boxes, sticky notes and maths.
struct ItemRecolor: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var color: String
    }

    struct Output: Codable {
        /// Items whose colour changed.
        var changed: [String]
        /// Items without a colour of their own (images, comments, custom items, patterned tape).
        var skipped: [String]
    }

    static let example: JSONValue = [
        "refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01",
                 "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"],
        "color": "#2156D9"
    ]
    static let exampleBoard: JSONValue = ["refs": ["item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01"], "color": "#D9432BFF"]

    static let descriptor = CommandDescriptor(
        id: "item.recolor", title: "Colour",
        summary: "Recolour ink, shapes (outline and fill), text boxes, sticky notes and maths; images and comments are skipped.",
        params: .obj(["refs": .arr(.ref, "item refs, e.g. item:D/P/I"), "color": .color], required: ["refs", "color"]),
        examples: [example, exampleBoard],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let color = RGBA(hex: p.color) else {
            throw NibError(.invalidParams, "'\(p.color)' is not a colour", path: "$.color", hint: "use #RRGGBB or #RRGGBBAA")
        }
        guard let targets = try ItemTargets.resolve(p.refs, ctx) else { return Output(changed: [], skipped: []) }
        let groups = ItemTargets.byPage(targets)
        try ItemTargets.ensureWritable(groups, ctx)
        var changed: [String] = []
        var skipped: [String] = []
        try ctx.mutate { tx in
            for g in groups {
                let items = try tx.items(g.doc, page: g.page)
                let byID = try ItemTargets.check(g.targets, items: items, allowLocked: false)
                var writes: [Item] = []
                for t in g.targets {
                    guard let item = byID[t.id] else { continue }
                    guard let next = Recolor.apply(item, color: color) else {
                        skipped.append(t.ref)
                        continue
                    }
                    if next != item {
                        writes.append(next)
                        changed.append(t.ref)
                    }
                }
                try tx.put(writes, doc: g.doc, page: g.page)
            }
            if !targets.isEmpty && skipped.count == targets.count {
                throw NibError(.invalidParams, "none of these items has a colour to change", path: "$.refs",
                               hint: "item.recolor changes ink, shapes, text boxes, sticky notes and maths")
            }
        }
        ItemTargets.linkIfNeeded(groups, ctx)
        return Output(changed: changed, skipped: skipped)
    }
}

// MARK: - item.setLocked

/// Which items lock (pure): images, text boxes, shapes and sticky notes. A locked item stays put: the eraser, the
/// lasso, transforms and these commands leave it alone until it is unlocked. Any locked item can be unlocked.
enum Locking {
    static let kinds: Set<ItemKind> = [.image, .text, .shape, .sticky]

    static func canLock(_ item: Item) -> Bool { kinds.contains(item.kind) }
}

/// `item.setLocked {refs, locked}`: locks or unlocks images, text boxes, shapes and sticky notes.
struct ItemSetLocked: NibCommand {
    struct Params: Codable {
        var refs: [String]?
        var locked: Bool
    }

    struct Output: Codable {
        /// Items whose lock changed.
        var changed: [String]
        /// Items that do not lock (ink, connectors, comments, maths, custom items).
        var skipped: [String]
    }

    static let example: JSONValue = [
        "refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTUREIMG01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"],
        "locked": true
    ]
    static let exampleUnlock: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"], "locked": false]

    static let descriptor = CommandDescriptor(
        id: "item.setLocked", title: "Lock",
        summary: "Lock or unlock images, text boxes, shapes and sticky notes (locked items cannot be moved, erased or edited).",
        params: .obj(["refs": .arr(.ref, "item refs, e.g. item:D/P/I"),
                      "locked": .bool("true locks, false unlocks")], required: ["refs", "locked"]),
        examples: [example, exampleUnlock],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let targets = try ItemTargets.resolve(p.refs, ctx) else { return Output(changed: [], skipped: []) }
        let groups = ItemTargets.byPage(targets)
        try ItemTargets.ensureWritable(groups, ctx)
        var changed: [String] = []
        var skipped: [String] = []
        try ctx.mutate { tx in
            for g in groups {
                let items = try tx.items(g.doc, page: g.page)
                let byID = try ItemTargets.check(g.targets, items: items, allowLocked: true)
                var writes: [Item] = []
                for t in g.targets {
                    guard var item = byID[t.id] else { continue }
                    if p.locked && !Locking.canLock(item) {
                        skipped.append(t.ref)
                        continue
                    }
                    guard item.locked != p.locked else { continue }
                    item.locked = p.locked
                    writes.append(item)
                    changed.append(t.ref)
                }
                try tx.put(writes, doc: g.doc, page: g.page)
            }
            if p.locked && !targets.isEmpty && skipped.count == targets.count {
                throw NibError(.invalidParams, "none of these items can be locked", path: "$.refs",
                               hint: "images, text boxes, shapes and sticky notes lock; ink and comments do not")
            }
        }
        ItemTargets.linkIfNeeded(groups, ctx)
        return Output(changed: changed, skipped: skipped)
    }
}
