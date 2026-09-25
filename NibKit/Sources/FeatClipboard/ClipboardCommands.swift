import Foundation
import UIKit
import UniformTypeIdentifiers
import NibContracts

// MARK: - Pasteboard seam

/// The pasteboard as the commands see it: `UIPasteboard.general` in the app, an in-memory board in tests.
@MainActor
protocol ClipboardBoard: AnyObject {
    /// True when any item offers one of `types` (never shows the system paste prompt).
    func contains(_ types: [String]) -> Bool
    /// True when the board holds text (never shows the system paste prompt).
    var hasStrings: Bool { get }
    /// The `type` data of every item offering it (reading another app's content may show the system paste prompt).
    func data(_ type: String) -> [Data]
    var strings: [String] { get }
    /// Replaces the board with one item offering every representation (type identifier → `Data` or `String`).
    func write(_ representations: [String: Any])
}

final class SystemClipboardBoard: ClipboardBoard {
    private var board: UIPasteboard { UIPasteboard.general }

    func contains(_ types: [String]) -> Bool { board.contains(pasteboardTypes: types) }
    var hasStrings: Bool { board.hasStrings }

    func data(_ type: String) -> [Data] {
        guard let set = board.itemSet(withPasteboardTypes: [type]) else { return [] }
        return board.data(forPasteboardType: type, inItemSet: set) ?? []
    }

    var strings: [String] { board.strings ?? [] }
    func write(_ representations: [String: Any]) { board.setItems([representations], options: [:]) }
}

@MainActor
enum Clipboard {
    /// The pasteboard every clipboard command reads and writes (tests swap in an in-memory board).
    static var board: ClipboardBoard = SystemClipboardBoard()
}

// MARK: - Reading the pasteboard

@MainActor
enum PasteboardReader {
    static let imageTypes: [(id: String, ext: String)] = [
        (UTType.gif.identifier, "gif"), (UTType.png.identifier, "png"), (UTType.jpeg.identifier, "jpg"),
        (UTType.heic.identifier, "heic"), (UTType.tiff.identifier, "tiff"), (UTType.webP.identifier, "webp")]
    static let richTypes = [UTType.flatRTFD.identifier, UTType.rtf.identifier, UTType.html.identifier]

    /// What a paste inserts, and where it came from ("fragment", "image" or "text"); nil when there is nothing.
    /// Paste and Match Style takes the plain text in `style`. Otherwise a Nib fragment wins, then rich text (Word,
    /// Pages and web selections also carry a picture of the text), then images, then plain text.
    static func read(_ board: ClipboardBoard, matchStyle: Bool, style: TextBoxStyle,
                     limits: PasteLimits) throws -> (fragment: Fragment, source: String)? {
        // Only what is needed is read: each read of another app's content can show the system paste prompt.
        func plainText() -> (fragment: Fragment, source: String)? {
            let plain = board.hasStrings ? board.strings.joined(separator: "\n") : ""
            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (ContentFragments.text(RichText(plain: plain), style: style, width: limits.textWidth), "text")
        }
        if matchStyle, let text = plainText() { return text }
        if board.contains([Fragment.typeIdentifier]), let data = board.data(Fragment.typeIdentifier).first {
            let fragment = try Fragment.decode(data)
            return (Fragment(items: fragment.items.filter { $0.isValid }, assets: fragment.assets), "fragment")
        }
        for type in richTypes where board.contains([type]) {
            if let data = board.data(type).first, let rich = ContentFragments.richText(data, type: type),
               !rich.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (ContentFragments.text(rich, style: style, width: limits.textWidth), "text")
            }
        }
        for type in imageTypes where board.contains([type.id]) {
            let list = board.data(type.id)
            guard !list.isEmpty else { continue }
            let fragment = ContentFragments.images(list.map { (data: $0, ext: type.ext) }, maxSize: limits.imageSize)
            if !fragment.items.isEmpty { return (fragment, "image") }
        }
        return plainText()
    }
}

// MARK: - Exporting a selection

/// The PNG flavour of copied items: only those items, on a transparent background, long edge ≤ 2048 px.
enum ClipboardRender {
    static let maxPixels = 2048.0

    @MainActor
    static func png(_ items: [Item], doc: DocumentID, page: PageID, pageItems: [Item], renderer: PageRenderer?) async -> Data? {
        guard let renderer = renderer, !items.isEmpty else { return nil }
        let chosen = Set(items.map { $0.id })
        let hidden = Set(pageItems.map { $0.id }).subtracting(chosen)
        let region = Fragment.union(items).insetBy(-2)
        guard region.width > 0, region.height > 0 else { return nil }
        let scale = max(0.1, min(2, maxPixels / max(region.width, region.height)))
        let request = RenderRequest(doc: doc, page: page, region: region, scale: scale, background: false, hidden: hidden)
        guard let result = try? await renderer.render(request) else { return nil }
        return UIImage(cgImage: result.image).pngData()
    }
}

/// Everything a copy puts on the pasteboard.
struct ClipboardExport {
    var fragment: Fragment
    var png: Data?
    var text: String

    var representations: [String: Any] {
        var reps: [String: Any] = [:]
        if let data = fragment.encoded() { reps[Fragment.typeIdentifier] = data }
        if let png = png { reps[UTType.png.identifier] = png }
        if !text.isEmpty { reps[UTType.utf8PlainText.identifier] = text }
        return reps
    }

    var types: [String] {
        [Fragment.typeIdentifier] + (png == nil ? [] : [UTType.png.identifier]) + (text.isEmpty ? [] : [UTType.utf8PlainText.identifier])
    }
}

/// Items resolved from refs: one page, the chosen items plus their attached content.
struct ClipSelection {
    let doc: DocumentID
    let page: PageID
    let items: [Item]
    /// Live items of the page when the selection was resolved.
    let pageItems: [Item]
}

// MARK: - Shared command logic

@MainActor
enum ClipboardCore {
    /// Settings the text feature may keep its default style in (TextBoxStyle or TextAttributes JSON).
    static let defaultStyleSettings = ["text.defaultStyle", "text.styles.default"]

    /// Items from refs (all on one page), or from the invoking window's selection when `refs` is omitted (keyboard
    /// shortcuts). nil = nothing selected.
    static func selection(_ refs: [String]?, _ ctx: CommandContext) throws -> ClipSelection? {
        let list: [String]
        if let refs = refs {
            guard !refs.isEmpty else {
                throw NibError(.invalidParams, "pass at least one item ref", path: "$.refs",
                               hint: "call query.context for the selection's refs")
            }
            list = refs
        } else {
            list = ctx.activeSession?.selection.refs ?? []
            if list.isEmpty { return nil }
        }
        var doc: DocumentID?
        var page: PageID?
        var ids: [ElementID] = []
        for (i, ref) in list.enumerated() {
            guard case let .item(d, p, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: "$.refs[\(i)]")
            }
            if let d0 = doc, let p0 = page, d0 != d || p0 != p {
                throw NibError(.invalidParams, "all items must be on one page", path: "$.refs[\(i)]")
            }
            doc = d
            page = p
            ids.append(id)
        }
        guard let d = doc, let p = page else { return nil }
        try ensureUnlocked(d, ctx)
        let pageItems = try ctx.workspace.items(d, page: p)
        let live = Set(pageItems.map { $0.id })
        if let i = ids.firstIndex(where: { !live.contains($0) }) {
            throw NibError(.notFound, "item \(ids[i].raw) not found on page \(p.raw)", path: "$.refs[\(i)]",
                           hint: "call query.get on the page for its item refs")
        }
        return ClipSelection(doc: d, page: p, items: Fragment.expand(ids, in: pageItems), pageItems: pageItems)
    }

    /// The page to paste onto: `page`, else the invoking window's current page.
    static func target(_ page: String?, _ ctx: CommandContext) throws -> (doc: DocumentID, page: PageID) {
        if let page = page {
            guard case let .page(d, p)? = NodeRef(page) else {
                throw NibError(.invalidParams, "expected a page ref like page:D/P", path: "$.page")
            }
            return (d, p)
        }
        guard let s = ctx.activeSession, let d = s.document, let p = s.page else {
            throw NibError(.invalidParams, "missing 'page'", path: "$.page",
                           hint: "pass the page ref to paste onto (query.context gives the current page)")
        }
        return (d, p)
    }

    static func livePage(_ doc: DocumentID, _ page: PageID, _ ctx: CommandContext) throws -> PageRecord {
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page.raw) in document \(doc.raw)")
        }
        return record
    }

    static func ensureUnlocked(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "document \(doc.raw) is locked", hint: "ask the user to unlock it (doc.unlock)")
        }
    }

    static func point(_ value: [Double]?, path: String) throws -> Point? {
        guard let v = value else { return nil }
        guard v.count == 2, v.allSatisfy({ $0.isFinite }) else { throw NibError.invalid("expected [x, y] in page points", path: path) }
        return Point(v[0], v[1])
    }

    /// Caller-chosen ids: valid and distinct.
    static func ids(_ raw: [String]?) throws -> [NibID] {
        guard let raw = raw else { return [] }
        var seen = Set<String>()
        for (i, s) in raw.enumerated() {
            guard NibID.isValid(s) else { throw NibError.invalid("id must be 1-64 of [A-Za-z0-9_-]", path: "$.ids[\(i)]") }
            guard seen.insert(s).inserted else { throw NibError.invalid("id '\(s)' is given twice", path: "$.ids[\(i)]") }
        }
        return raw.map { NibID($0) }
    }

    /// The user's default text style (saved by the text feature), or the plain default.
    static func defaultTextStyle(_ settings: SettingsStore) -> TextBoxStyle {
        let boxKeys: Set<String> = ["defaults", "background", "borderColor", "borderWidth", "cornerRadius", "padding",
                                    "shadow", "autoGrow", "fullPage"]
        for name in defaultStyleSettings {
            guard let json = settings.json(name), let object = json.objectValue else { continue }
            var style = TextBoxStyle()
            if !boxKeys.isDisjoint(with: object.keys), let box = try? json.decode(TextBoxStyle.self) {
                style = box
            } else if let attrs = try? json.decode(TextAttributes.self) {
                style.defaults = attrs
            }
            style.fullPage = false
            return style
        }
        return TextBoxStyle()
    }

    /// Fragment (with asset bytes), PNG (`services.renderer`) and plain text (typed text + `recognize.items`).
    static func export(_ sel: ClipSelection, _ ctx: CommandContext) async -> ClipboardExport {
        let store = ctx.services.assets
        let doc = sel.doc
        let fragment = Fragment.make(items: sel.items) { ref in try? store?.data(ref, doc: doc) }
        let png = await ClipboardRender.png(sel.items, doc: doc, page: sel.page, pageItems: sel.pageItems,
                                            renderer: ctx.services.renderer)
        let text = await ClipboardText.text(for: sel.items, doc: doc, page: sel.page) { refs in
            try? await ctx.execute(CommandIDs.recognizeItems, ["refs": .array(refs.map { .string($0) })])
        }
        return ClipboardExport(fragment: fragment, png: png, text: text)
    }

    /// Writes `fragment` onto a page in one undo step and returns the created refs in creation order. Assets are
    /// put into the target document first; `place` gets the page's live items and returns the translation.
    static func insert(_ fragment: Fragment, doc: DocumentID, page: PageID, ids: [NibID], layer: Int?,
                       ctx: CommandContext, place: ([Item]) -> Point) throws -> [String] {
        var assetMap: [String: AssetRef] = [:]
        if !fragment.assets.isEmpty {
            // ponytail: assets are content-addressed and immutable, so a paste that fails later leaves harmless bytes.
            let store = try ctx.services.require(ctx.services.assets, "asset store")
            for (name, data) in fragment.assets {
                let ext = AssetRef(name).ext
                assetMap[name] = try store.put(data, ext: ext.isEmpty ? "bin" : ext, doc: doc)
            }
        }
        let existing = try ctx.workspace.allItems(doc, page: page)
        let live = existing.filter { !$0.deleted }
        let liveIDs = Set(live.map { $0.id })
        for (i, id) in ids.prefix(fragment.items.count).enumerated() where liveIDs.contains(id) {
            throw NibError(.invalidParams, "an item with id \(id.raw) already exists on the page", path: "$.ids[\(i)]")
        }
        let items = fragment.instantiated(translate: place(live), ids: ids, zAfter: existing.last?.z, layer: layer,
                                          assets: assetMap)
        try ctx.mutate { tx in
            for item in items { try tx.put(item, doc: doc, page: page) }
        }
        return items.map { NodeRef.item(doc, page, $0.id).description }
    }

    /// Selects what the user just pasted or duplicated in the window they did it in (selection is the lasso
    /// feature's; skipped quietly when it is not installed).
    static func select(_ refs: [String], doc: DocumentID, ctx: CommandContext) async {
        guard !refs.isEmpty, !ctx.dryRun, ctx.principal.isUser, let s = ctx.session, s.document == doc else { return }
        _ = try? await ctx.execute(CommandIDs.selectionSet, ["refs": .array(refs.map { .string($0) })])
    }

    static func clearSelection(of ids: Set<ElementID>, _ ctx: CommandContext) async {
        guard !ctx.dryRun, ctx.principal.isUser, let s = ctx.session,
              s.selection.items.contains(where: { ids.contains($0) }) else { return }
        _ = try? await ctx.execute("selection.clear")
    }
}

// MARK: - Commands

struct ClipboardCopy: NibCommand {
    struct Params: Codable {
        /// nil = the invoking window's selection (keyboard shortcut).
        var refs: [String]?
    }

    struct Output: Codable {
        var count: Int
        var types: [String]
        var text: String?
    }

    static let example: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01",
                                              "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"]]

    static let descriptor = CommandDescriptor(
        id: "clipboard.copy", title: "Copy",
        summary: "Copy items to the clipboard as a Nib fragment plus a PNG and their recognised text (attached content comes along).",
        params: .obj(["refs": .arr(.ref, "items to copy, all on one page")], required: ["refs"]),
        examples: [example],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let sel = try ClipboardCore.selection(p.refs, ctx) else { return Output(count: 0, types: [], text: nil) }
        let export = await ClipboardCore.export(sel, ctx)
        if !ctx.dryRun { Clipboard.board.write(export.representations) }
        return Output(count: sel.items.count, types: export.types, text: export.text.isEmpty ? nil : export.text)
    }
}

struct ClipboardCut: NibCommand {
    struct Params: Codable {
        /// nil = the invoking window's selection (keyboard shortcut).
        var refs: [String]?
    }

    struct Output: Codable {
        var count: Int
        var types: [String]
        var text: String?
        var removed: [String]
    }

    static let example: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"]]

    static let descriptor = CommandDescriptor(
        id: "clipboard.cut", title: "Cut",
        summary: "Cut items: copy them to the clipboard (Nib fragment, PNG, recognised text) and delete them; connectors to them keep a free end.",
        params: .obj(["refs": .arr(.ref, "items to cut, all on one page")], required: ["refs"]),
        examples: [example],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let sel = try ClipboardCore.selection(p.refs, ctx) else {
            return Output(count: 0, types: [], text: nil, removed: [])
        }
        if let locked = sel.items.first(where: { $0.locked }) {
            throw NibError(.invalidParams, "item \(locked.id.raw) is locked and cannot be cut", path: "$.refs",
                           hint: "unlock it with item.setLocked, or copy it with clipboard.copy")
        }
        let export = await ClipboardCore.export(sel, ctx)
        if !ctx.dryRun { Clipboard.board.write(export.representations) }
        let cut = Set(sel.items.map { $0.id })
        var removed: [String] = []
        try ctx.mutate { tx in
            for item in try tx.items(sel.doc, page: sel.page) {
                if cut.contains(item.id) {
                    try tx.delete(item: item.id, doc: sel.doc, page: sel.page)
                    removed.append(NodeRef.item(sel.doc, sel.page, item.id).description)
                    continue
                }
                // What stays behind lets go of what left: pins detach, connector ends become free.
                var n = item
                if let parent = n.attachedTo, cut.contains(parent) { n.attachedTo = nil }
                if var c = n.connector {
                    if let target = c.from.item, cut.contains(target) { c.from = ConnectorEnd(point: c.from.point) }
                    if let target = c.to.item, cut.contains(target) { c.to = ConnectorEnd(point: c.to.point) }
                    n.connector = c
                }
                if n != item { try tx.put(n, doc: sel.doc, page: sel.page) }
            }
        }
        await ClipboardCore.clearSelection(of: cut, ctx)
        return Output(count: sel.items.count, types: export.types, text: export.text.isEmpty ? nil : export.text,
                      removed: removed)
    }
}

struct ClipboardPaste: NibCommand {
    struct Params: Codable {
        /// nil = the invoking window's current page.
        var page: String?
        var at: [Double]?
        var matchStyle: Bool?
        var ids: [String]?
        /// Pasted instead of the clipboard (drops, elements, plugins, AI).
        var fragment: Fragment?
    }

    struct Output: Codable {
        var refs: [String]
        /// "fragment", "image", "text", or "empty" when there was nothing to paste.
        var source: String
    }

    static let example: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "at": [200, 300]]
    /// A shape with a text box inside it and a connector anchored to it: pasting remaps both references.
    static let fragmentExample: JSONValue = try! JSONValue.parse(#"{"page":"page:FIXTUREDOC01/FIXTUREPG002","at":[160,200],"fragment":{"format":"nib-fragment/1","items":[{"id":"FRAGSHAPE001","kind":"shape","z":"V","shape":{"shape":"rectangle","frame":{"x":0,"y":0,"w":120,"h":60}}},{"id":"FRAGTEXT0001","kind":"text","z":"k","attachedTo":"FRAGSHAPE001","text":{"frame":{"x":10,"y":10,"w":100,"h":40},"text":"Pasted"}},{"id":"FRAGLINE0001","kind":"connector","z":"t","connector":{"from":{"point":[120,30],"item":"FRAGSHAPE001","side":1,"t":0.5},"to":{"point":[220,30]}}}]}}"#)

    static let descriptor = CommandDescriptor(
        id: "clipboard.paste", title: "Paste",
        summary: "Paste the clipboard (Nib items, images or rich text) onto a page, centred at a point; matchStyle pastes its text in the default text style.",
        params: .obj(["page": .ref,
                      "at": .point,
                      "matchStyle": .bool("paste only the clipboard's text, in the default text style (Paste and Match Style)"),
                      "ids": .arr(.str("your own id, [A-Za-z0-9_-]{1,64}"), "caller-chosen ids for the pasted items, in creation order"),
                      "fragment": .anything("nib-fragment/1 JSON {format, items, assets: {name: base64}, bounds} to paste instead of the clipboard")],
                     required: ["page"]),
        examples: [example, fragmentExample],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try ClipboardCore.target(p.page, ctx)
        try ClipboardCore.ensureUnlocked(doc, ctx)
        let record = try ClipboardCore.livePage(doc, page, ctx)
        let at = try ClipboardCore.point(p.at, path: "$.at")
        let ids = try ClipboardCore.ids(p.ids)
        let fragment: Fragment
        let source: String
        if let given = p.fragment {
            for (i, item) in given.items.enumerated() where !item.isValid {
                throw NibError(.invalidParams, "item must carry exactly the '\(item.kind.rawValue)' payload",
                               path: "$.fragment.items[\(i)]")
            }
            fragment = given
            source = "fragment"
        } else {
            let style = ClipboardCore.defaultTextStyle(ctx.services.settings)
            guard let read = try PasteboardReader.read(Clipboard.board, matchStyle: p.matchStyle ?? false, style: style,
                                                      limits: PasteLimits(page: record.size)) else {
                return Output(refs: [], source: "empty")
            }
            fragment = read.fragment
            source = read.source
        }
        guard !fragment.items.isEmpty else { return Output(refs: [], source: "empty") }
        let session = ctx.activeSession
        let visible = session?.document == doc && session?.page == page ? session?.visibleRect : nil
        let bounds = Fragment.union(fragment.items)
        let refs = try ClipboardCore.insert(fragment, doc: doc, page: page, ids: ids, layer: session?.activeLayer ?? 0,
                                            ctx: ctx) { existing in
            let steps = at == nil
                ? Placement.cascadeSteps(probe: fragment.items.first, existing: existing, step: Placement.step, from: 0) : 0
            let cascade = Point(Placement.step.x * Double(steps), Placement.step.y * Double(steps))
            return Placement.delta(bounds: bounds, at: at, cascade: cascade, visible: visible, page: record.size)
        }
        await ClipboardCore.select(refs, doc: doc, ctx: ctx)
        return Output(refs: refs, source: source)
    }
}

struct ItemDuplicate: NibCommand {
    struct Params: Codable {
        /// nil = the invoking window's selection (keyboard shortcut).
        var refs: [String]?
        var offset: [Double]?
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let example: JSONValue = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01",
                                              "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01",
                                              "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECON01"],
                                     "offset": [24, 24]]
    static let boardExample: JSONValue = ["refs": ["item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01"]]

    static let descriptor = CommandDescriptor(
        id: "item.duplicate", title: "Duplicate",
        summary: "Duplicate items on their page with new ids, offset by [dx, dy] (default 20 pt); attached content and connectors between them follow.",
        params: .obj(["refs": .arr(.ref, "items to duplicate, all on one page"),
                      "offset": .arr(.num(), "[dx, dy] in page points; default [20, 20], stepping past earlier copies"),
                      "ids": .arr(.str("your own id, [A-Za-z0-9_-]{1,64}"), "caller-chosen ids for the copies, in creation order")],
                     required: ["refs"]),
        examples: [example, boardExample],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let sel = try ClipboardCore.selection(p.refs, ctx) else { return Output(refs: []) }
        let record = try ClipboardCore.livePage(sel.doc, sel.page, ctx)
        let offset = try ClipboardCore.point(p.offset, path: "$.offset")
        let ids = try ClipboardCore.ids(p.ids)
        let fragment = Fragment.make(items: sel.items) { _ in nil }     // same document: asset refs stay valid
        let bounds = fragment.bounds
        let refs = try ClipboardCore.insert(fragment, doc: sel.doc, page: sel.page, ids: ids, layer: nil, ctx: ctx) { existing in
            if let offset = offset { return offset }
            let k = Placement.cascadeSteps(probe: fragment.items.first, existing: existing, step: Placement.step, from: 1)
            return Placement.delta(bounds: bounds, at: nil,
                                   cascade: Point(Placement.step.x * Double(k), Placement.step.y * Double(k)),
                                   visible: nil, page: record.size)
        }
        await ClipboardCore.select(refs, doc: sel.doc, ctx: ctx)
        return Output(refs: refs)
    }
}
