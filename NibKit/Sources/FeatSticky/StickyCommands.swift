import Foundation
import NibContracts

// MARK: - Settings

/// Settings owned by the sticky-note feature (declared in `register`).
enum StickySettings {
    /// Colour of notes the sticky tool places ("#RRGGBBAA"), synced so it follows the library.
    static let color = SettingKey("sticky.color", default: StickyColour.lemon.rgba.hex, synced: true)

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(color, summary: "Colour of new sticky notes placed with the sticky tool (#RRGGBB or #RRGGBBAA).",
                  owner: owner, schema: .color)
    }

    static func currentColour(_ s: SettingsStore) -> RGBA {
        RGBA(hex: s.get(color)) ?? StickyColour.lemon.rgba
    }
}

// MARK: - Parameter helpers

enum StickyRefs {
    static let findHint = "use query.find {\"in\": \"page:D/P\", \"kinds\": [\"sticky\"]} to list sticky notes"

    static func page(_ ref: String, path: String) throws -> (doc: DocumentID, page: PageID) {
        guard case let .page(d, p)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path, hint: "query.context gives the current page")
        }
        return (d, p)
    }

    static func item(_ ref: String, path: String) throws -> (doc: DocumentID, page: PageID, id: ElementID) {
        guard case let .item(d, p, i)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: path, hint: findHint)
        }
        return (d, p, i)
    }

    static func colour(_ s: String, path: String) throws -> RGBA {
        guard let c = RGBA(hex: s) else { throw NibError.invalid("expected a colour #RRGGBB or #RRGGBBAA", path: path) }
        return c
    }

    /// The live sticky note an item ref names, read inside a transaction (sees its own writes).
    @MainActor
    static func note(_ tx: DocTransaction, _ ref: String, path: String) throws -> (item: Item, doc: DocumentID, page: PageID) {
        let r = try item(ref, path: path)
        let it = try tx.item(r.doc, page: r.page, id: r.id)
        guard it.kind == .sticky, it.sticky != nil else {
            throw NibError(.invalidParams, "\(ref) is a \(it.kind.rawValue), not a sticky note", path: path, hint: findHint)
        }
        return (it, r.doc, r.page)
    }

    static func nonEmpty(_ refs: [String]) throws {
        if refs.isEmpty { throw NibError.invalid("refs must name at least one sticky note", path: "$.refs") }
    }
}

// MARK: - sticky.create

struct StickyCreate: NibCommand {
    struct Params: Codable {
        var page: String
        var at: Point
        var color: String?
        var text: RichText?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "sticky.create", title: String(localized: "Add Sticky Note"),
        summary: "Place a 160 × 160 pt sticky note with its top-left at a page point; optional colour, text and your own id. Signed with the author name.",
        params: .obj(["page": .ref,
                      "at": .arr(.num(), "[x, y] top-left corner in page points"),
                      "color": .color,
                      "text": .anything("plain string (one paragraph per line) or RichText {paragraphs: [...]}"),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")],
                     required: ["page", "at"]),
        examples: [
            try! JSONValue.parse(##"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [72, 560], "color": "#FFE87C", "text": "Revise SUVAT"}"##),
            try! JSONValue.parse(#"{"page": "page:FIXTUREDOC04/FIXTUREBRD01", "at": [240, 40]}"#)
        ],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try StickyRefs.page(p.page, path: "$.page")
        guard p.at.x.isFinite, p.at.y.isFinite else { throw NibError.invalid("at must be two finite numbers", path: "$.at") }
        if let id = p.id, !NibID.isValid(id) {
            throw NibError.invalid("id must be 1–64 characters of [A-Za-z0-9_-]", path: "$.id")
        }
        let colour = try p.color.map { try StickyRefs.colour($0, path: "$.color") }
            ?? StickySettings.currentColour(ctx.services.settings)
        let author = ctx.services.settings.get(NibSettings.authorName).trimmingCharacters(in: .whitespacesAndNewlines)
        let layer = ctx.activeSession?.activeLayer ?? 0
        let created = try ctx.mutate { tx -> Item in
            guard let record = try tx.content(doc).page(page), !record.deleted else {
                throw NibError(.notFound, "page \(page) not found in document \(doc)", path: "$.page")
            }
            var it = Item.makeSticky(StickyItem(frame: StickyGeometry.frame(topLeft: p.at, pageSize: record.size),
                                                color: colour, text: p.text ?? .empty,
                                                author: author.isEmpty ? nil : author), layer: layer)
            if let id = p.id {
                it.id = NibID(id)
                if (try? tx.item(doc, page: page, id: it.id)) != nil {
                    throw NibError(.conflict, "an item with id \(id) already exists on this page", path: "$.id",
                                   hint: "choose another id")
                }
            }
            return try tx.put(it, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, created.id).description)
    }
}

// MARK: - sticky.setCollapsed

struct StickySetCollapsed: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var collapsed: Bool
    }

    struct Output: Codable {
        var changed: Int
    }

    static let descriptor = CommandDescriptor(
        id: "sticky.setCollapsed", title: String(localized: "Collapse or Expand Sticky Notes"),
        summary: "Collapse sticky notes to a small note icon (collapsed: true) or expand them again (false); size and text are kept.",
        params: .obj(["refs": .arr(.ref), "collapsed": .bool()], required: ["refs", "collapsed"]),
        examples: [try! JSONValue.parse(#"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"], "collapsed": true}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try StickyRefs.nonEmpty(p.refs)
        let changed = try ctx.mutate { tx -> Int in
            var n = 0
            for (i, ref) in p.refs.enumerated() {
                let r = try StickyRefs.note(tx, ref, path: "$.refs[\(i)]")
                var it = r.item
                guard var s = it.sticky, s.collapsed != p.collapsed else { continue }
                s.collapsed = p.collapsed
                it.sticky = s
                try tx.put(it, doc: r.doc, page: r.page)
                n += 1
            }
            return n
        }
        return Output(changed: changed)
    }
}

// MARK: - sticky.resolve

struct StickyResolve: NibCommand {
    struct Params: Codable {
        var ref: String
        var resolved: Bool
    }

    struct Output: Codable {
        var changed: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "sticky.resolve", title: String(localized: "Resolve Sticky Note"),
        summary: "Mark a sticky note resolved (drawn faded with a check) or reopen it with resolved: false.",
        params: .obj(["ref": .ref, "resolved": .bool()], required: ["ref", "resolved"]),
        examples: [try! JSONValue.parse(#"{"ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "resolved": true}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let changed = try ctx.mutate { tx -> Bool in
            let r = try StickyRefs.note(tx, p.ref, path: "$.ref")
            var it = r.item
            guard var s = it.sticky, s.resolved != p.resolved else { return false }
            s.resolved = p.resolved
            it.sticky = s
            try tx.put(it, doc: r.doc, page: r.page)
            return true
        }
        return Output(changed: changed)
    }
}

// MARK: - sticky.setColor

struct StickySetColor: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var color: String
    }

    struct Output: Codable {
        var changed: Int
    }

    static let descriptor = CommandDescriptor(
        id: "sticky.setColor", title: String(localized: "Change Note Colour"),
        summary: "Change the paper colour of sticky notes (#RRGGBB or #RRGGBBAA). Locked notes are refused.",
        params: .obj(["refs": .arr(.ref), "color": .color], required: ["refs", "color"]),
        examples: [try! JSONValue.parse(##"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"], "color": "#AEDAFF"}"##)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try StickyRefs.nonEmpty(p.refs)
        let colour = try StickyRefs.colour(p.color, path: "$.color")
        let changed = try ctx.mutate { tx -> Int in
            var n = 0
            for (i, ref) in p.refs.enumerated() {
                let r = try StickyRefs.note(tx, ref, path: "$.refs[\(i)]")
                guard !r.item.locked else {
                    throw NibError(.invalidParams, "\(ref) is locked", path: "$.refs[\(i)]",
                                   hint: "unlock it with item.setLocked first")
                }
                var it = r.item
                guard var s = it.sticky, s.color != colour else { continue }
                s.color = colour
                it.sticky = s
                try tx.put(it, doc: r.doc, page: r.page)
                n += 1
            }
            return n
        }
        return Output(changed: changed)
    }
}

// MARK: - sticky.tapAt

/// Tap handler (`content.tapHandlers`, order 350, before selection): a tap on a collapsed note's icon expands it; a
/// tap on the selected note, a double-tap on a note, or any tap on a note while the sticky tool is active edits its
/// text in place. Anything else falls through to the next handler.
struct StickyTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: Point
        var ref: String?
        var gesture: String?
    }

    struct Output: Codable {
        var handled: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "sticky.tapAt", title: String(localized: "Tap Sticky Note"),
        summary: "Tap handler: expand a collapsed sticky note under a point, or edit the text of the selected (or double-tapped) note.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str(choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [412, 132], "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "gesture": "tap"}"#)],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try StickyRefs.page(p.page, path: "$.page")
        let active = ctx.activeSession
        if active?.readOnly == true { return Output(handled: false) }
        let zoom = max(active?.zoom ?? 1, 0.01)
        let items = try ctx.workspace.items(doc, page: page)
        guard let note = StickyHit.note(at: p.point, ref: p.ref, in: items, minimumSide: 44 / zoom),
              let sticky = note.sticky else { return Output(handled: false) }
        let ref = NodeRef.item(doc, page, note.id).description
        if sticky.collapsed {
            _ = try await ctx.execute(StickySetCollapsed.descriptor.id, ["refs": [.string(ref)], "collapsed": false])
            return Output(handled: true)
        }
        guard let session = active, !note.locked else { return Output(handled: false) }
        let selected = session.selection.doc == doc && session.selection.page == page
            && session.selection.items.contains(note.id)
        guard p.gesture == CanvasGesture.doubleTap.rawValue || selected || session.tool == StickyTool.toolID,
              let host = session.editor?.canvasHost, host.documentID == doc else { return Output(handled: false) }
        StickyEditor.editor(for: host).beginEditing(doc: doc, page: page, id: note.id)
        return Output(handled: true)
    }
}

/// Which note a tap lands on.
enum StickyHit {
    /// The router's `ref` when it names a sticky note under the point; else the topmost note under it. A collapsed
    /// note is hit only on its icon (grown to `minimumSide`).
    static func note(at p: Point, ref: String?, in items: [Item], minimumSide: Double) -> Item? {
        func hit(_ it: Item) -> Bool {
            guard it.kind == .sticky, let s = it.sticky, !it.deleted else { return false }
            return StickyGeometry.hits(s, p, minimumSide: minimumSide)
        }
        if let ref {
            let id: ElementID
            if case let .item(_, _, i)? = NodeRef(ref) { id = i } else { id = NibID(ref) }
            if let it = items.first(where: { $0.id == id }), hit(it) { return it }
        }
        return items.last(where: hit)
    }
}

// MARK: - Dropping items onto notes

/// "Items dropped onto an expanded note get `attachedTo`": after a commit that moved items, or created them by any
/// means but writing ink (paste, duplicate, drag and drop, elements, images…), each such item is attached to the
/// topmost expanded note beneath its centre, or detached from the note it was moved off. Children of a note that
/// was just deleted are detached so they stay editable. Applied as `item.update` in the commit's own undo group.
enum StickyAttach {
    struct Change: Equatable {
        var item: ElementID
        var parent: ElementID?
    }

    /// Commits that never re-attach: undo and redo, reverts, sync, the follow-up updates themselves, sticky commands.
    static func considers(command: String, principal: Principal) -> Bool {
        if case .sync = principal { return false }
        let skipped: Set<String> = [CommandIDs.undo, CommandIDs.redo, CommandIDs.revertGroup, CommandIDs.itemUpdate, "sync.merge"]
        return !skipped.contains(command) && !command.hasPrefix("sticky.")
    }

    /// Kinds that can sit on a note (connectors follow their anchors, comments their target, notes don't nest).
    static func attachable(_ it: Item) -> Bool {
        it.kind != .sticky && it.kind != .connector && it.kind != .comment
    }

    /// `moved` and `created` are the commit's after-values on one page; `deletedNotes` the notes it deleted there;
    /// `pageItems` the page as it is now (z order, bottom first).
    static func plan(moved: [Item], created: [Item], deletedNotes: Set<ElementID>, pageItems: [Item]) -> [Change] {
        let live = pageItems.filter { !$0.deleted }
        var position: [ElementID: Int] = [:]
        for (i, it) in live.enumerated() { position[it.id] = i }
        let notes = live.filter { $0.kind == .sticky && $0.sticky != nil }
        let movedIDs = Set(moved.map { $0.id })
        let orphans = live.filter { $0.attachedTo.map { deletedNotes.contains($0) } ?? false }
        var seen = Set<ElementID>()
        var out: [Change] = []
        for candidate in moved + created + orphans where seen.insert(candidate.id).inserted {
            guard let pos = position[candidate.id] else { continue }
            let it = live[pos]
            guard attachable(it) else { continue }
            if let parent = it.attachedTo, movedIDs.contains(parent) { continue }     // travelled with its note
            let parentNote = it.attachedTo.flatMap { p in notes.first { $0.id == p } }
            let parentIsNote = parentNote != nil || (it.attachedTo.map { deletedNotes.contains($0) } ?? false)
            if it.attachedTo != nil && !parentIsNote { continue }                     // a shape container's child
            let centre = it.bounds.center
            let target = notes.last { n in
                guard let s = n.sticky, !s.collapsed, let np = position[n.id], np < pos else { return false }
                return Geo.polygonContains(s.frame.corners, centre)
            }
            // A child of a collapsed note moved within the note's frame stays with it.
            if target == nil, let n = parentNote, let s = n.sticky, s.collapsed,
               Geo.polygonContains(s.frame.corners, centre) { continue }
            if target?.id != it.attachedTo { out.append(Change(item: it.id, parent: target?.id)) }
        }
        return out
    }

    /// The commit observer (installed in `start`).
    @MainActor
    static func commitDidHappen(_ cs: Changeset, app: NibApp) {
        guard considers(command: cs.command, principal: cs.principal) else { return }
        let inkCommit = cs.command.hasPrefix("ink.")
        var work: [(ref: String, parent: String?)] = []
        for (doc, pages) in cs.itemPages {
            for page in pages {
                var moved: [Item] = [], created: [Item] = []
                var deletedNotes = Set<ElementID>()
                for m in cs.mutations {
                    guard case let .item(d, p, before, after) = m, d == doc, p == page else { continue }
                    let wasLive = before.map { !$0.deleted } ?? false
                    if after.deleted {
                        if wasLive && after.kind == .sticky { deletedNotes.insert(after.id) }
                    } else if !wasLive {
                        if !inkCommit { created.append(after) }
                    } else if let b = before, b.bounds != after.bounds {
                        moved.append(after)
                    }
                }
                guard !(moved.isEmpty && created.isEmpty && deletedNotes.isEmpty),
                      let items = try? app.workspace.allItems(doc, page: page) else { continue }
                for c in plan(moved: moved, created: created, deletedNotes: deletedNotes, pageItems: items) {
                    work.append((NodeRef.item(doc, page, c.item).description,
                                 c.parent.map { NodeRef.item(doc, page, $0).description }))
                }
            }
        }
        guard !work.isEmpty else { return }
        Task { @MainActor in
            for w in work {
                let parent: JSONValue = w.parent.map { .string($0) } ?? .null
                // ponytail: a failure (item gone, permission, item.update not installed) leaves the item as dropped.
                _ = try? await app.bus.execute(Invocation(command: CommandIDs.itemUpdate,
                                                          params: ["ref": .string(w.ref), "patch": ["attachedTo": parent]],
                                                          principal: cs.principal, group: cs.group))
            }
        }
    }
}
