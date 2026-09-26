import Foundation
import ImageIO
import UniformTypeIdentifiers
import NibContracts

// The four block commands (ARCHITECTURE §6.5 `block.*`, owner F047) plus the pure rules they share with the editor.
// Every change to a text document, from the keyboard, a plugin, the AI or the bridge, ends up in one of these.

// MARK: - block.insert

struct BlockInsert: NibCommand {
    struct Params: Codable {
        var doc: String
        var after: String?
        var kind: BlockKind
        var text: RichText?
        var asset: String?
        var url: String?
        var caption: RichText?
        var custom: CustomBlock?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    private static let ex1: JSONValue = ["doc": "doc:FIXTUREDOC02", "after": "block:FIXTUREDOC02/FIXTUREBLK01",
                                         "kind": "bullet", "text": "Buy milk"]
    private static let ex2: JSONValue = ["doc": "doc:FIXTUREDOC02", "kind": "todo", "text": "Revise chapter 3"]
    private static let ex3: JSONValue = ["doc": "doc:FIXTUREDOC02", "after": "doc:FIXTUREDOC02", "kind": "image",
                                         "asset": "fixture-image.png", "caption": "Figure 1"]
    private static let ex4: JSONValue = ["doc": "doc:FIXTUREDOC02", "kind": "video",
                                         "url": "https://example.com/lecture.mp4", "caption": "Lecture 4"]

    static let descriptor = CommandDescriptor(
        id: "block.insert", title: "Insert Block",
        summary: "Insert a text-document block (paragraph, heading1-3, bullet, numbered, todo, quote, code, divider, table, image, video, custom) after a block, at the top or at the end.",
        params: .obj([
            "doc": .ref,
            "after": .str("block ref to insert after (block:D/B); the document ref doc:D inserts at the top; omitted = at the end"),
            "kind": .str("block kind", choices: BlockKind.allCases.map { $0.rawValue }),
            "text": .anything("rich text: a plain string (one paragraph per line) or {paragraphs: [{runs: [{text, attrs?}]}]}"),
            "asset": .str("image blocks: an image already stored in the document (e.g. from asset.put)"),
            "url": .str("image blocks: a tmp: ref from asset.upload or an https image URL (stored in the document); video blocks: the video's https URL"),
            "caption": .anything("image and video blocks: the caption, a string or rich text"),
            "custom": .obj(["owner": .str("feature or plugin id"), "type": .str("block type"),
                            "height": .num("points", min: BlockRules.customHeight.lowerBound, max: BlockRules.customHeight.upperBound),
                            "data": .anything("owner data"),
                            "display": .anything("DisplayList {ops: [...]} the editor draws")],
                           required: ["owner", "type"], "custom blocks only"),
            "id": .str("your own id for the new block, [A-Za-z0-9_-]{1,64}")
        ], required: ["doc", "kind"]),
        examples: [ex1, ex2, ex3, ex4],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let content = try ctx.workspace.content(doc)
        guard content.meta.kind == .textDocument else {
            throw NibError(.invalidParams, "doc:\(doc.raw) is a \(content.meta.kind.rawValue), not a text document",
                           path: "$.doc", hint: "blocks exist only in text documents (kind textDocument)")
        }
        if let id = p.id, !NibID.isValid(id) {
            throw NibError.invalid("id must be 1-64 characters of [A-Za-z0-9_-]", path: "$.id")
        }
        if let id = p.id, content.blocks.contains(where: { $0.id.raw == id && !$0.deleted }) {
            throw NibError(.invalidParams, "a block with id \(id) already exists", path: "$.id",
                           hint: "choose another id or leave it out")
        }
        if let after = p.after { _ = try BlockRules.anchor(after, doc: doc, path: "$.after") }
        try BlockRules.checkPayload(kind: p.kind, asset: p.asset, url: p.url, caption: p.caption, custom: p.custom,
                                    principal: ctx.principal)
        // Slow work (downloads, hashing) happens before the transaction.
        let media = try await BlockMedia.resolve(kind: p.kind, asset: p.asset, url: p.url, doc: doc, ctx: ctx)
        let block = try ctx.mutate { (tx: DocTransaction) -> TextBlock in
            let live = try tx.content(doc).liveBlocks
            var b = BlockRules.newBlock(id: p.id.map { NibID($0) } ?? NibID.make(), kind: p.kind, text: p.text,
                                        caption: p.caption, custom: p.custom)
            b.asset = media.asset
            b.url = media.videoURL
            b.order = try BlockRules.orderKey(after: p.after, doc: doc, live: live, moving: nil, whenOmitted: .end)
            return try tx.put(b, doc: doc)
        }
        return Output(ref: NodeRef.block(doc, block.id).description)
    }
}

// MARK: - block.update

struct BlockUpdate: NibCommand {
    struct Params: Codable {
        var ref: String
        var text: RichText?
        var kind: BlockKind?
        var checked: Bool?
        var indent: Int?
        var caption: RichText?
        var asset: String?
        var url: String?
    }

    private static let ex1: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "text": "Hello edited blocks"]
    private static let ex2: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "kind": "todo", "checked": true]
    private static let ex3: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK01", "kind": "heading2"]
    private static let ex4: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK02", "kind": "bullet", "indent": 1]

    static let descriptor = CommandDescriptor(
        id: "block.update", title: "Update Block",
        summary: "Change a block: replace its text, turn it into another kind, check a to-do, indent it (0-8), or set an image/video caption, asset or url.",
        params: .obj([
            "ref": .ref,
            "text": .anything("new rich text: a plain string or {paragraphs: [...]} (image/video blocks: sets the caption)"),
            "kind": .str("turn the block into this kind (not custom)", choices: BlockKind.allCases.map { $0.rawValue }),
            "checked": .bool("to-do blocks: done or not"),
            "indent": .int("nesting level", min: 0, max: BlockRules.maxIndent),
            "caption": .anything("image and video blocks: the caption"),
            "asset": .str("image blocks: an image already stored in the document"),
            "url": .str("image blocks: a tmp: ref or https image URL to store; video blocks: the video's https URL")
        ], required: ["ref"]),
        examples: [ex1, ex2, ex3, ex4],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, id) = try BlockRules.blockRef(p.ref, path: "$.ref")
        guard p.text != nil || p.kind != nil || p.checked != nil || p.indent != nil || p.caption != nil
            || p.asset != nil || p.url != nil else {
            throw NibError(.invalidParams, "nothing to update", path: "$",
                           hint: "pass at least one of text, kind, checked, indent, caption, asset, url")
        }
        let current = try BlockRules.liveBlock(id, doc: doc, in: ctx.workspace.content(doc), path: "$.ref")
        let kind = p.kind ?? current.kind
        if p.kind == .custom, current.kind != .custom {
            throw NibError(.invalidParams, "a block cannot be turned into a custom block", path: "$.kind",
                           hint: "insert the custom block with block.insert {kind: \"custom\", custom: {...}}")
        }
        let media = try await BlockMedia.resolve(kind: kind, asset: p.asset, url: p.url, doc: doc, ctx: ctx)
        let change = BlockChange(text: p.text, kind: p.kind, checked: p.checked, indent: p.indent, caption: p.caption,
                                 asset: media.asset, videoURL: media.videoURL,
                                 setsAsset: p.asset != nil || (p.url != nil && kind == .image),
                                 setsURL: p.url != nil && kind == .video)
        try ctx.mutate { (tx: DocTransaction) -> Void in
            var b = try BlockRules.liveBlock(id, doc: doc, in: tx.content(doc), path: "$.ref")
            try BlockRules.apply(change, to: &b)
            try tx.put(b, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - block.delete

struct BlockDelete: NibCommand {
    struct Params: Codable {
        var refs: [String]
    }

    struct Output: Codable {
        var deleted: Int
    }

    private static let ex1: JSONValue = ["refs": ["block:FIXTUREDOC02/FIXTUREBLK02"]]
    private static let ex2: JSONValue = ["refs": ["block:FIXTUREDOC02/FIXTUREBLK01", "block:FIXTUREDOC02/FIXTUREBLK03"]]

    static let descriptor = CommandDescriptor(
        id: "block.delete", title: "Delete Blocks",
        summary: "Delete text-document blocks by ref (block:D/B). Undoable.",
        params: .obj(["refs": .arr(.ref, "block refs")], required: ["refs"]),
        examples: [ex1, ex2],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !p.refs.isEmpty else { throw NibError.invalid("refs is empty", path: "$.refs") }
        var targets: [(doc: DocumentID, id: NibID, path: String)] = []
        var seen = Set<String>()
        for (i, ref) in p.refs.enumerated() {
            let t = try BlockRules.blockRef(ref, path: "$.refs[\(i)]")
            if seen.insert(NodeRef.block(t.0, t.1).description).inserted { targets.append((t.0, t.1, "$.refs[\(i)]")) }
        }
        try ctx.mutate { (tx: DocTransaction) -> Void in
            for t in targets {
                var b = try BlockRules.liveBlock(t.id, doc: t.doc, in: tx.content(t.doc), path: t.path)
                b.deleted = true
                try tx.put(b, doc: t.doc)
            }
        }
        return Output(deleted: targets.count)
    }
}

// MARK: - block.move

struct BlockMove: NibCommand {
    struct Params: Codable {
        var ref: String
        var after: String?
    }

    private static let ex1: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK01", "after": "block:FIXTUREDOC02/FIXTUREBLK03"]
    private static let ex2: JSONValue = ["ref": "block:FIXTUREDOC02/FIXTUREBLK03"]

    static let descriptor = CommandDescriptor(
        id: "block.move", title: "Move Block",
        summary: "Reorder a block: place it right after another block of the same document; omit after (or pass doc:D) to move it to the top.",
        params: .obj(["ref": .ref,
                      "after": .str("block ref to place it after; omitted or the document ref doc:D = the top")],
                     required: ["ref"]),
        examples: [ex1, ex2],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let (doc, id) = try BlockRules.blockRef(p.ref, path: "$.ref")
        if let after = p.after, case .after(let a) = try BlockRules.anchor(after, doc: doc, path: "$.after"), a == id {
            throw NibError.invalid("a block cannot be moved after itself", path: "$.after")
        }
        let content = try ctx.workspace.content(doc)
        _ = try BlockRules.liveBlock(id, doc: doc, in: content, path: "$.ref")
        if try BlockRules.isAlreadyPlaced(id, after: p.after, doc: doc, live: content.liveBlocks) { return NoResult() }
        try ctx.mutate { (tx: DocTransaction) -> Void in
            let now = try tx.content(doc)
            var b = try BlockRules.liveBlock(id, doc: doc, in: now, path: "$.ref")
            b.order = try BlockRules.orderKey(after: p.after, doc: doc, live: now.liveBlocks, moving: id, whenOmitted: .start)
            try tx.put(b, doc: doc)
        }
        return NoResult()
    }
}

// MARK: - Rules (pure, shared with the editor and the tests)

/// One block.update, already validated and with its media resolved.
struct BlockChange {
    var text: RichText?
    var kind: BlockKind?
    var checked: Bool?
    var indent: Int?
    var caption: RichText?
    var asset: AssetRef?
    var videoURL: String?
    var setsAsset = false
    var setsURL = false
}

enum BlockRules {
    static let maxIndent = 8
    static let customHeight: ClosedRange<Double> = 8...4000

    enum Anchor: Equatable {
        case start
        case after(NibID)
    }

    enum DefaultPosition { case start, end }

    // MARK: Kinds

    /// Kinds whose content is typed text in the editor.
    static func isText(_ k: BlockKind) -> Bool {
        switch k {
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .numbered, .todo, .quote, .code: return true
        case .divider, .table, .image, .video, .custom: return false
        }
    }

    static func isList(_ k: BlockKind) -> Bool { k == .bullet || k == .numbered || k == .todo }

    static func isHeading(_ k: BlockKind) -> Bool { k == .heading1 || k == .heading2 || k == .heading3 }

    static func hasCaption(_ k: BlockKind) -> Bool { k == .image || k == .video }

    /// The kind a new block gets when Return is pressed inside a block of kind `k`.
    static func continuation(of k: BlockKind) -> BlockKind {
        switch k {
        case .bullet, .numbered, .todo: return k
        default: return .paragraph
        }
    }

    // MARK: Refs

    static func blockRef(_ s: String, path: String) throws -> (DocumentID, NibID) {
        guard case let .block(doc, id)? = NodeRef(s) else {
            throw NibError(.invalidParams, "'\(s)' is not a block ref", path: path,
                           hint: "block refs look like block:<doc>/<block>; query.get {ref: \"doc:<doc>\"} lists them")
        }
        return (doc, id)
    }

    static func anchor(_ s: String, doc: DocumentID, path: String) throws -> Anchor {
        if let ref = NodeRef(s) {
            switch ref {
            case .document(let d) where d == doc: return .start
            case .block(let d, let b) where d == doc: return .after(b)
            default:
                throw NibError(.invalidParams, "'\(s)' is not a block of doc:\(doc.raw)", path: path,
                               hint: "pass block:\(doc.raw)/<block>, or doc:\(doc.raw) for the top")
            }
        }
        guard NibID.isValid(s) else { throw NibError.invalid("'\(s)' is not a block ref", path: path) }
        return .after(NibID(s))
    }

    static func liveBlock(_ id: NibID, doc: DocumentID, in content: DocumentContent, path: String) throws -> TextBlock {
        guard let b = content.blocks.first(where: { $0.id == id && !$0.deleted }) else {
            throw NibError(.notFound, "block \(id.raw) not found in doc:\(doc.raw)", path: path,
                           hint: "call query.get {ref: \"doc:\(doc.raw)\"} to list the document's blocks")
        }
        return b
    }

    // MARK: Order

    /// Order key for a block placed after `after` among `live` (the sorted live blocks), leaving out `moving`.
    static func orderKey(after: String?, doc: DocumentID, live: [TextBlock], moving: NibID?,
                         whenOmitted: DefaultPosition) throws -> String {
        let list = live.filter { $0.id != moving }
        let target: Anchor
        if let after = after {
            target = try anchor(after, doc: doc, path: "$.after")
        } else if whenOmitted == .start {
            target = .start
        } else {
            return FractionalIndex.between(list.last?.order, nil)
        }
        switch target {
        case .start:
            return FractionalIndex.between(nil, list.first.map { $0.order })
        case .after(let id):
            guard let i = list.firstIndex(where: { $0.id == id }) else {
                throw NibError(.notFound, "block \(id.raw) not found in doc:\(doc.raw)", path: "$.after",
                               hint: "call query.get {ref: \"doc:\(doc.raw)\"} to list the document's blocks")
            }
            let lower = list[i].order
            // Two devices can pick the same key; the next strictly greater key keeps `between` well defined.
            let upper = list[(i + 1)...].first(where: { $0.order > lower })?.order
            return FractionalIndex.between(lower, upper)
        }
    }

    /// True when `id` already sits where block.move would put it (no-op moves create no undo entry).
    static func isAlreadyPlaced(_ id: NibID, after: String?, doc: DocumentID, live: [TextBlock]) throws -> Bool {
        guard let i = live.firstIndex(where: { $0.id == id }) else { return false }
        var target = Anchor.start
        if let after = after { target = try anchor(after, doc: doc, path: "$.after") }
        switch target {
        case .start: return i == 0
        case .after(let a): return i > 0 && live[i - 1].id == a
        }
    }

    // MARK: Payloads

    static func checkPayload(kind: BlockKind, asset: String?, url: String?, caption: RichText?, custom: CustomBlock?,
                             principal: Principal) throws {
        if kind == .custom {
            guard let c = custom else {
                throw NibError(.invalidParams, "custom blocks need the `custom` payload", path: "$.custom",
                               hint: "pass custom: {owner, type, height?, data?, display?}")
            }
            try validateCustom(c, principal: principal)
        } else if custom != nil {
            throw NibError.invalid("`custom` applies to custom blocks only", path: "$.custom")
        }
        if asset != nil, kind != .image {
            throw NibError.invalid("`asset` applies to image blocks only", path: "$.asset")
        }
        if url != nil, kind != .image, kind != .video {
            throw NibError.invalid("`url` applies to image and video blocks only", path: "$.url")
        }
        if asset != nil, url != nil {
            throw NibError.invalid("pass either asset or url, not both", path: "$.url")
        }
        if caption != nil, !hasCaption(kind) {
            throw NibError.invalid("`caption` applies to image and video blocks only", path: "$.caption")
        }
    }

    static func validateCustom(_ c: CustomBlock, principal: Principal) throws {
        guard !c.owner.isEmpty else { throw NibError.invalid("custom.owner is empty", path: "$.custom.owner") }
        guard !c.type.isEmpty else { throw NibError.invalid("custom.type is empty", path: "$.custom.type") }
        guard customHeight.contains(c.height) else {
            throw NibError.invalid("custom.height must be \(Int(customHeight.lowerBound))-\(Int(customHeight.upperBound))",
                                   path: "$.custom.height")
        }
        if case .plugin(let id) = principal, c.owner != id {
            throw NibError(.permissionDenied, "a plugin can only create its own custom blocks (owner \"\(id)\")",
                           path: "$.custom.owner")
        }
    }

    /// A new block with the kind's defaults. Text on image/video blocks becomes the caption; dividers carry no text;
    /// a table starts as 3 × 3 with the text in its first cell.
    static func newBlock(id: NibID, kind: BlockKind, text: RichText?, caption: RichText?, custom: CustomBlock?) -> TextBlock {
        var b = TextBlock(id: id, kind: kind)
        let t = text ?? .empty
        switch kind {
        case .image, .video:
            b.caption = nonEmpty(caption) ?? nonEmpty(t)
        case .divider:
            break
        case .table:
            b.table = defaultTable(firstCell: t)
        case .todo:
            b.text = t
            b.checked = false
        case .custom:
            b.text = t
            b.custom = custom
        default:
            b.text = t
        }
        return b
    }

    static func defaultTable(firstCell: RichText = .empty, rows: Int = 3, columns: Int = 3) -> TableData {
        var grid = Array(repeating: Array(repeating: TableCell(), count: columns), count: rows)
        grid[0][0].text = firstCell
        return TableData(rows: grid)
    }

    /// Applies a validated change: the kind first (with its data transitions), then the other fields.
    static func apply(_ c: BlockChange, to b: inout TextBlock) throws {
        if let k = c.kind, k != b.kind { turn(&b, into: k) }
        if let t = c.text {
            if hasCaption(b.kind) {
                b.caption = nonEmpty(t)
            } else if b.kind == .divider {
                throw NibError.invalid("dividers have no text", path: "$.text")
            } else if b.kind == .table {
                throw NibError(.invalidParams, "table text lives in its cells", path: "$.text",
                               hint: "use table.edit {op: \"setCell\"}")
            } else {
                b.text = t
            }
        }
        if let checked = c.checked {
            guard b.kind == .todo else {
                throw NibError(.invalidParams, "`checked` applies to to-do blocks", path: "$.checked",
                               hint: "turn the block into a to-do with kind: \"todo\" in the same call")
            }
            b.checked = checked
        }
        if let i = c.indent {
            guard (0...maxIndent).contains(i) else { throw NibError.invalid("indent must be 0-\(maxIndent)", path: "$.indent") }
            b.indent = i == 0 ? nil : i
        }
        if let cap = c.caption {
            guard hasCaption(b.kind) else {
                throw NibError.invalid("`caption` applies to image and video blocks only", path: "$.caption")
            }
            b.caption = nonEmpty(cap)
        }
        if c.setsAsset {
            guard b.kind == .image else { throw NibError.invalid("`asset` applies to image blocks only", path: "$.asset") }
            b.asset = c.asset
        }
        if c.setsURL {
            guard b.kind == .video else { throw NibError.invalid("`url` applies to image and video blocks only", path: "$.url") }
            b.url = c.videoURL
        }
    }

    /// Turn Into: moves content between the kind-specific fields so nothing is silently dropped (undo restores the rest).
    static func turn(_ b: inout TextBlock, into k: BlockKind) {
        let from = b.kind
        // Leaving a kind.
        switch from {
        case .table:
            b.text = tableText(b.table)
            b.table = nil
        case .image, .video:
            if isText(k) || k == .custom || k == .table { b.text = b.caption ?? .empty }
            if !hasCaption(k) { b.caption = nil }
            if k != .image { b.asset = nil }
            if k != .video { b.url = nil }
        case .todo:
            b.checked = nil
        case .code:
            b.codeLanguage = nil
        case .custom:
            b.custom = nil
        default:
            break
        }
        // Entering a kind.
        switch k {
        case .todo:
            b.checked = b.checked ?? false
        case .divider:
            b.text = .empty
        case .table:
            if b.table == nil { b.table = defaultTable(firstCell: b.text) }
            b.text = .empty
        case .image, .video:
            if !hasCaption(from) {
                b.caption = b.caption ?? nonEmpty(b.text)
                b.text = .empty
            }
        default:
            break
        }
        b.kind = k
    }

    /// A table's text as tab-separated rows (what Turn Into keeps when a table becomes text).
    static func tableText(_ t: TableData?) -> RichText {
        guard let t = t, !t.rows.isEmpty else { return .empty }
        let lines = t.rows.map { row in
            row.map { $0.text.plainText.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }
        return RichText(plain: lines.joined(separator: "\n"))
    }

    static func nonEmpty(_ t: RichText?) -> RichText? {
        guard let t = t, !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Media (images are stored in the document; video blocks keep their link)

@MainActor
enum BlockMedia {
    struct Resolved {
        var asset: AssetRef?
        var videoURL: String?
    }

    static func resolve(kind: BlockKind, asset: String?, url: String?, doc: DocumentID, ctx: CommandContext) async throws -> Resolved {
        var r = Resolved()
        if let name = asset {
            guard kind == .image else { throw NibError.invalid("`asset` applies to image blocks only", path: "$.asset") }
            r.asset = try existingAsset(name, doc: doc, ctx: ctx)
        }
        if let u = url {
            switch kind {
            case .image: r.asset = try await importImage(u, doc: doc, ctx: ctx)
            case .video: r.videoURL = try videoURL(u)
            default: throw NibError.invalid("`url` applies to image and video blocks only", path: "$.url")
            }
        }
        return r
    }

    /// The largest image a block imports (a picked photo is far below it; an AI or bridge link to a huge file is not).
    static let maxImageBytes = 100 * 1024 * 1024

    /// An asset of the document, checked by its file (never read into memory just to see that it exists).
    static func existingAsset(_ name: String, doc: DocumentID, ctx: CommandContext) throws -> AssetRef {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else {
            throw NibError(.invalidParams, "'\(name)' is not an asset name", path: "$.asset",
                           hint: "pass the name asset.put returned, e.g. 3f2a….png")
        }
        let ref = AssetRef(name)
        if let store = ctx.services.assets, store.url(ref, doc: doc) == nil {
            throw NibError(.notFound, "asset \(name) not found in doc:\(doc.raw)", path: "$.asset",
                           hint: "store the image with asset.put first, or pass url")
        }
        return ref
    }

    /// Reads a tmp:/https/file (user only) image through `ctx.inputFile` and stores it in the document package.
    static func importImage(_ url: String, doc: DocumentID, ctx: CommandContext) async throws -> AssetRef {
        let store = try ctx.services.require(ctx.services.assets, "asset storage")
        let file = try await ctx.inputFile(url)
        // `inputFile` downloads web links to a temporary file of their own: it goes once the image is stored.
        let scheme = URL(string: url)?.scheme?.lowercased()
        let downloaded = scheme == "https" || scheme == "http"
        defer { if downloaded { removeDownload(file) } }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxImageBytes else {
            throw NibError(.invalidParams, "the image is larger than 100 MB", path: "$.url",
                           hint: "downscale it or upload a smaller file")
        }
        // File I/O, decoding and hashing stay off the main actor.
        let stored: AssetRef? = try await Task.detached(priority: .userInitiated) { () throws -> AssetRef? in
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard let ext = BlockMedia.imageExtension(data) else { return nil }
            return try store.put(data, ext: ext, doc: doc)
        }.value
        guard let asset = stored else {
            throw NibError(.invalidParams, "\(url) is not an image", path: "$.url", hint: "pass a PNG, JPEG, HEIC or GIF")
        }
        return asset
    }

    /// Deletes a file `inputFile` downloaded, with the folder of its own it lands in (`<tmp>/nib-downloads/<UUID>/`).
    nonisolated static func removeDownload(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        let target = folder.deletingLastPathComponent().lastPathComponent == "nib-downloads" ? folder : file
        try? FileManager.default.removeItem(at: target)
    }

    /// The file extension of an image ImageIO can read, nil for anything else.
    nonisolated static func imageExtension(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src) else { return nil }
        return UTType(type as String)?.preferredFilenameExtension ?? "png"
    }

    static func videoURL(_ s: String) throws -> String {
        guard let u = webURL(s) else {
            throw NibError(.invalidParams, "a video block needs an http(s) link", path: "$.url",
                           hint: "pass the video's page or file URL, e.g. https://example.com/lecture.mp4")
        }
        return u.absoluteString
    }

    /// An http(s) link with a host, or nil. Stored video links are checked again before they are shown or opened,
    /// because sync, remote patches and generic node edits reach `TextBlock.url` without block.update.
    nonisolated static func webURL(_ s: String) -> URL? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              u.host != nil else { return nil }
        return u
    }
}
