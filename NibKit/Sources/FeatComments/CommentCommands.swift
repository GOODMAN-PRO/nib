import Foundation
import NibContracts

// MARK: - Settings and rules

enum CommentSettings {
    /// Per device, like Goodnotes' "Show Resolved Comments": it is a way of looking at pages, not document state.
    static let showResolved = SettingKey("comments.showResolved", default: false)
}

/// Pure comment logic shared by the commands, the pin drawer and the panels.
enum CommentRules {
    /// The pin is a 22 pt accent number disc (DESIGN.md §14.3); `Item.bounds` gives comments 24 × 24.
    static let pinDiameter = 22.0
    static let maxTextLength = 10_000

    /// Trimmed message text; empty or oversized text is `invalid_params`.
    static func text(_ raw: String, path: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw NibError.invalid("text must not be empty", path: path) }
        guard t.count <= maxTextLength else {
            throw NibError.invalid("text is longer than \(maxTextLength) characters", path: path)
        }
        return t
    }

    static func point(_ v: [Double], path: String) throws -> Point {
        guard v.count == 2, v.allSatisfy({ $0.isFinite }) else {
            throw NibError.invalid("expected [x, y] in page points", path: path)
        }
        return Point(v[0], v[1])
    }

    /// Resolved threads show only while Show Resolved Comments is on.
    static func isVisible(_ comment: CommentItem, showResolved: Bool) -> Bool { showResolved || !comment.resolved }

    /// Tap radius in page points: the pin itself, or a 44 pt view target when zoomed out.
    static func hitRadius(zoom: Double) -> Double { max(pinDiameter / 2, 22 / max(zoom, 0.05)) }

    /// The visible pin nearest to `point` within `radius`; on a tie the topmost (items are in z order, bottom first).
    /// Pins on layers hidden on this device are not drawn, so they cannot be hit.
    static func hit(_ items: [Item], at point: Point, radius: Double, showResolved: Bool,
                    hiddenLayers: Set<Int> = []) -> Item? {
        var best: (item: Item, distance: Double)?
        for it in items where !it.deleted && !hiddenLayers.contains(it.layer) {
            guard let c = it.comment, isVisible(c, showResolved: showResolved) else { continue }
            let d = c.anchor.distance(to: point)
            if d <= radius, d <= (best?.distance ?? .infinity) { best = (it, d) }
        }
        return best?.item
    }

    /// Where a pin sits on an object: its top-right corner.
    static func anchor(onto target: Item) -> Point {
        let b = target.bounds
        return Point(b.maxX, b.minY)
    }

    /// No spot given: the middle of what the user is looking at, else the page's top-right corner.
    static func defaultAnchor(size: PageSize?, visible: Rect?) -> Point {
        if let v = visible, !v.isEmpty { return v.center }
        if let s = size { return Point(max(0, s.width - 36), 36) }
        return Point(0, 0)
    }

    /// Keeps a pin on its page (infinite boards have no size and no edge).
    static func clamp(_ p: Point, to size: PageSize?) -> Point {
        guard let s = size else { return p }
        return Point(min(max(p.x, 0), s.width), min(max(p.y, 0), s.height))
    }

    /// Author stored on a message: the user's profile name, "Assistant" for the AI, else the plugin / client id.
    static func author(for principal: Principal, settings: SettingsStore) -> String {
        switch principal {
        case .user: return settings.get(NibSettings.authorName).trimmingCharacters(in: .whitespacesAndNewlines)
        case .ai: return "Assistant"
        case .plugin(let id), .bridge(let id): return id
        case .sync: return ""
        }
    }
}

/// Where a new thread goes: its page, pin spot, and the object it hangs on (`attachedTo`, so the pin follows it).
struct CommentPlacement: Equatable {
    var doc: DocumentID
    var page: PageID
    var anchor: Point
    var parent: ElementID?
    /// The parent's layer, so hiding that layer hides its comments too.
    var layer: Int?

    @MainActor
    static func resolve(page pageRef: String, at: [Double]?, ref: String?, workspace: Workspace,
                        session: EditorSession?) throws -> CommentPlacement {
        guard case let .page(doc, page)? = NodeRef(pageRef) else {
            throw NibError.invalid("expected a page ref page:D/P", path: "$.page")
        }
        guard let content = try? workspace.content(doc) else {
            throw NibError(.notFound, "document \(doc) not found", path: "$.page")
        }
        guard let record = content.page(page), !record.deleted else {
            throw NibError(.notFound, "page \(page) not found in document \(doc)", path: "$.page",
                           hint: "list pages with query.get {\"ref\": \"doc:\(doc.raw)\"}")
        }
        var anchor = try at.map { try CommentRules.point($0, path: "$.at") }
        var parent: ElementID?
        var layer: Int?
        if let ref = ref {
            guard case let .item(refDoc, refPage, id)? = NodeRef(ref), refDoc == doc, refPage == page else {
                throw NibError.invalid("ref must be an item on the same page (item:D/P/I)", path: "$.ref")
            }
            guard let target = try? workspace.item(doc, page: page, id: id) else {
                throw NibError(.notFound, "item \(id) not found on page \(page)", path: "$.ref")
            }
            guard target.kind != .comment else {
                throw NibError(.invalidParams, "a comment cannot be pinned to another comment", path: "$.ref",
                               hint: "answer it with comment.reply {\"ref\": \"\(ref)\", \"text\": …}")
            }
            parent = id
            layer = target.layer
            if anchor == nil { anchor = CommentRules.anchor(onto: target) }
        }
        let visible = session?.page == page ? session?.visibleRect : nil
        let spot = anchor ?? CommentRules.defaultAnchor(size: record.size, visible: visible)
        return CommentPlacement(doc: doc, page: page, anchor: CommentRules.clamp(spot, to: record.size),
                                parent: parent, layer: layer)
    }
}

/// Reads and writes of one thread inside a transaction.
@MainActor
enum CommentThreads {
    struct Loaded {
        var doc: DocumentID
        var page: PageID
        var item: Item
        var comment: CommentItem
        var ref: String { NodeRef.item(doc, page, item.id).description }
    }

    static func load(_ ref: String, _ tx: DocTransaction) throws -> Loaded {
        guard case let .item(doc, page, id)? = NodeRef(ref) else {
            throw NibError.invalid("expected a comment ref item:D/P/I", path: "$.ref")
        }
        guard let item = try? tx.item(doc, page: page, id: id) else {
            throw NibError(.notFound, "comment \(id) not found on page \(page)", path: "$.ref",
                           hint: "find threads with query.find {\"in\": \"doc:\(doc.raw)\", \"kinds\": [\"comment\"]}")
        }
        guard let comment = item.comment else {
            throw NibError.invalid("item \(id) is a \(item.kind.rawValue), not a comment", path: "$.ref")
        }
        return Loaded(doc: doc, page: page, item: item, comment: comment)
    }

    static func messageIndex(_ comment: CommentItem, _ message: String) throws -> Int {
        guard let i = comment.messages.firstIndex(where: { $0.id.raw == message }) else {
            throw NibError(.notFound, "message \(message) not found in this thread", path: "$.message",
                           hint: "message ids are in query.get of the thread's ref")
        }
        return i
    }

    /// Writes the thread back. A thread whose object was deleted stays where its pin is, unpinned, instead of
    /// failing every later edit with "attached to missing item".
    @discardableResult
    static func save(_ thread: Loaded, _ tx: DocTransaction) throws -> Item {
        var it = thread.item
        it.comment = thread.comment
        if let parent = it.attachedTo, (try? tx.item(thread.doc, page: thread.page, id: parent)) == nil {
            it.attachedTo = nil
        }
        return try tx.put(it, doc: thread.doc, page: thread.page)
    }
}

// MARK: - Commands

struct CommentAdd: NibCommand {
    struct Params: Codable {
        var page: String
        var at: [Double]?
        var ref: String?
        var text: String
        var id: String?
    }
    struct Output: Codable {
        var ref: String?
        var message: String?
        /// True when an empty text from the UI opened the composer for a new thread instead of creating one.
        var draft: Bool?
    }

    static let descriptor = CommandDescriptor(
        id: "comment.add", title: "Add Comment",
        summary: "Start a comment thread at a page spot (at [x,y]) or pinned to an object (ref item:D/P/I, the pin follows it); returns its ref.",
        params: .obj(["page": .ref,
                      "at": .point,
                      "ref": .str("item:D/P/I on the same page to pin the thread to (the pin moves with it)"),
                      "text": .str("first message; the UI passes \"\" to open the composer instead"),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")],
                     required: ["page", "text"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [300, 320], "text": "Check the units here"}"#),
                   try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01", "text": "Label this box"}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if let id = p.id, !NibID.isValid(id) {
            throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id")
        }
        let place = try CommentPlacement.resolve(page: p.page, at: p.at, ref: p.ref, workspace: ctx.workspace,
                                                 session: ctx.activeSession)
        if p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ctx.principal.isUser, let session = ctx.activeSession, let state = CommentsState.of(ctx.services) {
            // Add Comment from a menu: nothing is written until the first message is sent from the composer.
            state.focus(.draft(CommentsState.Draft(doc: place.doc, page: place.page, at: place.anchor,
                                                   parent: place.parent)), in: session)
            _ = try? await ctx.execute("panel.open", ["id": .string(CommentPanels.thread)])
            return Output(draft: true)
        }
        let text = try CommentRules.text(p.text, path: "$.text")
        if let id = p.id {
            // Tombstones count too: reusing a deleted item's id on another page would leave two live items with one
            // id once that deletion is undone. ponytail: loads every page, but only for caller-chosen ids.
            let wanted = NibID(id)
            for page in try ctx.workspace.content(place.doc).pages {
                guard let found = try ctx.workspace.allItems(place.doc, page: page.id).first(where: { $0.id == wanted }),
                      !found.deleted || page.id != place.page else { continue }
                throw NibError(.conflict, "an item with id \(id) already exists", path: "$.id",
                               hint: "choose another id or leave it out")
            }
        }
        let message = CommentMessage(author: CommentRules.author(for: ctx.principal, settings: ctx.services.settings),
                                     text: text)
        let layer = place.layer ?? ctx.activeSession?.activeLayer ?? 0
        let item = try ctx.mutate { (tx: DocTransaction) -> Item in
            var it = Item.makeComment(CommentItem(anchor: place.anchor, messages: [message]), layer: layer)
            it.attachedTo = place.parent
            if let id = p.id { it.id = NibID(id) }
            return try tx.put(it, doc: place.doc, page: place.page)
        }
        return Output(ref: NodeRef.item(place.doc, place.page, item.id).description, message: message.id.raw)
    }
}

struct CommentReply: NibCommand {
    struct Params: Codable {
        var ref: String
        var text: String
    }
    struct Output: Codable {
        var ref: String
        var message: String
    }

    static let descriptor = CommandDescriptor(
        id: "comment.reply", title: "Reply to Comment",
        summary: "Add a message to a comment thread (a resolved thread reopens); returns the new message id.",
        params: .obj(["ref": .str("comment thread item:D/P/I"), "text": .str("message text")], required: ["ref", "text"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01", "text": "Fixed, thanks"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let text = try CommentRules.text(p.text, path: "$.text")
        let message = CommentMessage(author: CommentRules.author(for: ctx.principal, settings: ctx.services.settings),
                                     text: text)
        return try ctx.mutate { (tx: DocTransaction) -> Output in
            var thread = try CommentThreads.load(p.ref, tx)
            thread.comment.messages.append(message)
            thread.comment.resolved = false
            try CommentThreads.save(thread, tx)
            return Output(ref: thread.ref, message: message.id.raw)
        }
    }
}

struct CommentEdit: NibCommand {
    struct Params: Codable {
        var ref: String
        var message: String
        var text: String
    }

    static let descriptor = CommandDescriptor(
        id: "comment.edit", title: "Edit Comment",
        summary: "Change the text of one message in a comment thread (it shows as edited).",
        params: .obj(["ref": .str("comment thread item:D/P/I"), "message": .str("message id"), "text": .str("new text")],
                     required: ["ref", "message", "text"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01", "message": "FIXTUREMSG01",
                    "text": "Check this again"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let text = try CommentRules.text(p.text, path: "$.text")
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var thread = try CommentThreads.load(p.ref, tx)
            let i = try CommentThreads.messageIndex(thread.comment, p.message)
            guard thread.comment.messages[i].text != text else { return }
            thread.comment.messages[i].text = text
            thread.comment.messages[i].edited = true
            try CommentThreads.save(thread, tx)
        }
        return NoResult()
    }
}

struct CommentDeleteMessage: NibCommand {
    struct Params: Codable {
        var ref: String
        var message: String
    }
    struct Output: Codable {
        var deletedThread: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "comment.deleteMessage", title: "Delete Comment Message",
        summary: "Delete one message of a comment thread; deleting the last message deletes the whole thread.",
        params: .obj(["ref": .str("comment thread item:D/P/I"), "message": .str("message id")], required: ["ref", "message"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01", "message": "FIXTUREMSG01"]],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        try ctx.mutate { (tx: DocTransaction) -> Output in
            var thread = try CommentThreads.load(p.ref, tx)
            let index = try CommentThreads.messageIndex(thread.comment, p.message)
            thread.comment.messages.remove(at: index)
            if thread.comment.messages.isEmpty {
                try tx.delete(item: thread.item.id, doc: thread.doc, page: thread.page)
                return Output(deletedThread: true)
            }
            try CommentThreads.save(thread, tx)
            return Output(deletedThread: false)
        }
    }
}

struct CommentResolve: NibCommand {
    struct Params: Codable {
        var ref: String
        var resolved: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "comment.resolve", title: "Resolve Comment",
        summary: "Resolve (resolved true) or reopen (false) a comment thread; resolved threads hide unless Show Resolved Comments is on.",
        params: .obj(["ref": .str("comment thread item:D/P/I"), "resolved": .bool()], required: ["ref", "resolved"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01", "resolved": true]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var thread = try CommentThreads.load(p.ref, tx)
            guard thread.comment.resolved != p.resolved else { return }
            thread.comment.resolved = p.resolved
            try CommentThreads.save(thread, tx)
        }
        return NoResult()
    }
}

/// Tap chain (order 200): opens the thread whose pin is under a finger tap in the thread panel.
struct CommentTapAt: NibCommand {
    struct Params: Codable {
        var page: String
        var point: [Double]
        var ref: String?
        var gesture: String?
    }
    struct Output: Codable {
        var handled: Bool
        var ref: String?
    }

    static let descriptor = CommandDescriptor(
        id: "comment.tapAt", title: "Open Comment",
        summary: "Tap chain: open the comment thread whose pin is under a point, or the thread ref given; handled=false when there is none.",
        params: .obj(["page": .ref,
                      "point": .point,
                      "ref": .str("comment item:D/P/I to open directly (opens even while resolved threads are hidden)"),
                      "gesture": .str("set by the canvas tap chain", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["page", "point"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [560, 400]}"#)],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else {
            throw NibError.invalid("expected a page ref page:D/P", path: "$.page")
        }
        let point = try CommentRules.point(p.point, path: "$.point")
        let showResolved = ctx.services.settings.get(CommentSettings.showResolved)
        let hiddenLayers = ctx.activeSession?.hiddenLayers ?? []
        var thread: Item?
        // The canvas passes the topmost item under every tap, so from there only a pin that is drawn may open.
        // Refs from the Comments list and from comment links open what they name.
        if let ref = p.ref, case let .item(refDoc, refPage, id)? = NodeRef(ref), refDoc == doc, refPage == page,
           let it = try? ctx.workspace.item(doc, page: page, id: id), let c = it.comment,
           p.gesture == nil || (CommentRules.isVisible(c, showResolved: showResolved) && !hiddenLayers.contains(it.layer)) {
            thread = it
        }
        if thread == nil {
            let items = (try? ctx.workspace.items(doc, page: page)) ?? []
            thread = CommentRules.hit(items, at: point, radius: CommentRules.hitRadius(zoom: ctx.activeSession?.zoom ?? 1),
                                      showResolved: showResolved, hiddenLayers: hiddenLayers)
        }
        guard let found = thread else { return Output(handled: false, ref: nil) }
        let ref = NodeRef.item(doc, page, found.id).description
        guard let session = ctx.activeSession, let state = CommentsState.of(ctx.services) else {
            return Output(handled: false, ref: ref)
        }
        state.focus(.thread(doc: doc, page: page, id: found.id), in: session)
        do {
            _ = try await ctx.execute("panel.open", ["id": .string(CommentPanels.thread)])
        } catch {
            // No panel host (document chrome disabled): the rest of the tap chain gets the tap.
            return Output(handled: false, ref: ref)
        }
        return Output(handled: true, ref: ref)
    }
}
