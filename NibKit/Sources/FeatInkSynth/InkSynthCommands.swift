import Foundation
import NibContracts

/// Device setting: the handwriting font of synthesised ink. Per device (it is a look, like the pen preset of this
/// iPad); chosen in Settings › Writing Aids (F105) or with `settings.set {name: "inksynth.font"}`.
enum InkSynthSettings {
    static let font = SettingKey("inksynth.font", default: InkSynthFont.noteworthy)

    static func declare(_ settings: SettingsStore, owner: String) {
        settings.declare(font, summary: "Handwriting font of synthesised ink (Noteworthy, Bradley Hand or Marker Felt).",
                         owner: owner, schema: .str(choices: InkSynthFont.allCases.map { $0.rawValue }))
    }
}

/// Parameter checks and the shared write step of both commands.
@MainActor
enum InkSynthParams {
    static let maxCharacters = 5000
    /// Right margin kept free when `ink.writeText` wraps at the page edge by default.
    static let pageMargin = 36.0

    static func page(_ ref: String, path: String) throws -> (DocumentID, PageID) {
        guard case let .page(doc, page)? = NodeRef(ref) else {
            throw NibError(.invalidParams, "expected a page ref like page:D/P", path: path,
                           hint: "get the current page from query.context")
        }
        return (doc, page)
    }

    static func font(_ name: String?, settings: SettingsStore) throws -> InkSynthFont {
        guard let name = name else { return settings.get(InkSynthSettings.font) }
        guard let font = InkSynthFont(name: name) else {
            throw NibError(.invalidParams, "unknown handwriting font '\(name)'", path: "$.font",
                           hint: "use one of: " + InkSynthFont.allCases.map { $0.rawValue }.joined(separator: ", "))
        }
        return font
    }

    /// Validates caller-chosen ids: well formed, unique and not already used on the page (ids of the strokes being
    /// replaced may be reused).
    static func callerIDs(_ ids: [String]?, doc: DocumentID, page: PageID, workspace: Workspace,
                          replacing: Set<ElementID> = []) throws -> [ElementID] {
        guard let ids = ids, !ids.isEmpty else { return [] }
        let live = Set(try workspace.items(doc, page: page).map { $0.id })
        var seen = Set<String>()
        for (k, id) in ids.enumerated() {
            let path = "$.ids[\(k)]"
            guard NibID.isValid(id) else { throw NibError.invalid("id must be 1–64 characters of [A-Za-z0-9_-]", path: path) }
            guard seen.insert(id).inserted else { throw NibError.invalid("id '\(id)' is repeated", path: path) }
            guard !live.contains(NibID(id)) || replacing.contains(NibID(id)) else {
                throw NibError.invalid("an item with id '\(id)' already exists on this page", path: path)
            }
        }
        return ids.map { NibID($0) }
    }

    /// Stores synthesised strokes in writing order, normalised by `InkModel.prepare` (densified, nib sizes derived),
    /// with the caller's ids first.
    static func write(_ strokes: [Stroke], ids: [ElementID], layer: Int, doc: DocumentID, page: PageID,
                      tx: DocTransaction) throws -> [Item] {
        var written: [Item] = []
        written.reserveCapacity(strokes.count)
        for (k, stroke) in strokes.enumerated() {
            var s = stroke
            InkModel.prepare(&s)
            var item = Item.makeStroke(s, layer: layer)
            if k < ids.count { item.id = ids[k] }
            written.append(try tx.put(item, doc: doc, page: page))
        }
        return written
    }

    static func refs(_ items: [Item], doc: DocumentID, page: PageID) -> [String] {
        items.map { NodeRef.item(doc, page, $0.id).description }
    }

    /// Bounds of the written ink, nib included.
    static func bounds(_ items: [Item]) -> Rect? {
        items.reduce(nil as Rect?) { acc, item in acc.map { $0.union(item.bounds) } ?? item.bounds }
    }
}

// MARK: - ink.writeText

/// Writes text as handwriting-style ink (the AI's handwriting tool, Math Assist answers, plugins such as
/// word-complete). One undo step.
struct InkWriteText: NibCommand {
    struct Params: Codable {
        var page: String
        var text: String
        var at: [Double]
        var size: Double?
        var font: String?
        var color: String?
        var width: Double?
        var maxWidth: Double?
        var slant: Double?
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
        /// Bounds of the written ink, nib included ([x, y, w, h]).
        var bounds: Rect?
        var lines: Int
    }

    static let example: JSONValue = try! JSONValue.parse(
        #"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "text": "Hello Nib", "at": [72, 96]}"#)
    static let styledExample: JSONValue = try! JSONValue.parse(
        ##"{"page": "page:FIXTUREDOC01/FIXTUREPG001", "text": "v = u + at\nx = 12", "at": [72, 560], "size": 24, "font": "Bradley Hand", "color": "#1F5FD1", "width": 1.6, "maxWidth": 220, "slant": 8, "ids": ["SUVATLINE001"]}"##)

    static let descriptor = CommandDescriptor(
        id: "ink.writeText", title: "Write Handwriting",
        summary: "Write text as handwriting-style ink strokes from a top-left point (size = font size in points), wrapping at maxWidth; returns the stroke refs.",
        params: .obj([
            "page": .ref,
            "text": .str("the text; a newline starts a new line"),
            "at": .arr(.num(), "[x, y] top-left of the first line, in page points"),
            "size": .num("font size in points (default 18)", min: 4, max: 400),
            "font": .str("handwriting font (default: the device setting inksynth.font)",
                         choices: InkSynthFont.allCases.map { $0.rawValue }),
            "color": .color,
            "width": .num("pen width in points (default: the pen preset, scaled with size)", min: 0.1, max: 40),
            "maxWidth": .num("wrap width in points (default: to the page's right margin; no wrapping on boards)", min: 1),
            "slant": .num("extra forward lean in degrees (negative leans back)", min: -45, max: 45),
            "ids": .arr(.str("your own id, [A-Za-z0-9_-]{1,64}"), "caller-chosen ids for the created strokes, in writing order")
        ], required: ["page", "text", "at"]),
        examples: [example, styledExample],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try InkSynthParams.page(p.page, path: "$.page")
        guard !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NibError.invalid("text is empty", path: "$.text")
        }
        guard p.text.count <= InkSynthParams.maxCharacters else {
            throw NibError(.invalidParams, "text is longer than \(InkSynthParams.maxCharacters) characters", path: "$.text",
                           hint: "write long text in several calls")
        }
        guard p.at.count == 2, p.at[0].isFinite, p.at[1].isFinite else {
            throw NibError.invalid("at must be [x, y] in page points", path: "$.at")
        }
        let size = p.size ?? 18
        guard (4...400).contains(size) else { throw NibError.invalid("size must be 4–400 points", path: "$.size") }
        if let slant = p.slant, !(-45...45).contains(slant) {
            throw NibError.invalid("slant must be -45–45 degrees", path: "$.slant")
        }
        if let m = p.maxWidth, !(m >= 1 && m.isFinite) {
            throw NibError.invalid("maxWidth must be at least 1 point", path: "$.maxWidth")
        }
        if let w = p.width, !(w >= 0.1 && w <= 40) {
            throw NibError.invalid("width must be 0.1–40 points", path: "$.width")
        }
        let font = try InkSynthParams.font(p.font, settings: ctx.services.settings)
        let pen = ctx.services.settings.get(NibSettings.presets("pen"))
        var color = pen.color
        if let hex = p.color {
            guard let c = RGBA(hex: hex) else { throw NibError.invalid("colour must be #RRGGBB or #RRGGBBAA", path: "$.color") }
            color = c
        }
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
            throw NibError.notFound("page \(page) in document \(doc)")
        }
        let ids = try InkSynthParams.callerIDs(p.ids, doc: doc, page: page, workspace: ctx.workspace)

        let origin = Point(p.at[0], p.at[1])
        let maxWidth = p.maxWidth ?? record.size.flatMap { s -> Double? in
            let room = s.width - origin.x - InkSynthParams.pageMargin
            return room >= size * 4 ? room : nil
        }
        let width = p.width ?? min(max(pen.width * size / 18, 0.3), 20)
        let style = InkStyle(tool: .pen, pen: .fountain, color: color, width: width)
        let options = InkTypesetter.Options(font: font, size: size, shear: tan((p.slant ?? 0) * .pi / 180),
                                            maxWidth: maxWidth, style: style)
        let text = p.text
        let layout = await InkTypesetter.offMain { InkTypesetter.layout(text, at: origin, options: options) }
        guard !layout.strokes.isEmpty else {
            throw NibError(.invalidParams, "the text has no characters that can be written as ink", path: "$.text",
                           hint: "use text.createBox for emoji and symbols")
        }
        let layer = ctx.activeSession?.activeLayer ?? 0
        let written = try ctx.mutate { tx in
            try InkSynthParams.write(layout.strokes, ids: ids, layer: layer, doc: doc, page: page, tx: tx)
        }
        return Output(refs: InkSynthParams.refs(written, doc: doc, page: page), bounds: InkSynthParams.bounds(written),
                      lines: layout.lineCount)
    }
}

// MARK: - handwriting.replaceWord

/// Replaces a handwritten word with synthesised ink of new text in the same pen, colour, layer, size, baseline and
/// slant (spelling corrections, word completion). One undo step.
struct HandwritingReplaceWord: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var text: String
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
        /// Bounds of the new ink, nib included ([x, y, w, h]).
        var bounds: Rect?
    }

    static let example: JSONValue = try! JSONValue.parse(
        #"{"refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "text": "hello"}"#)

    static let descriptor = CommandDescriptor(
        id: "handwriting.replaceWord", title: "Replace Word",
        summary: "Replace a handwritten word's strokes with synthesised ink of new text matching their size, slant, colour and pen; returns the new stroke refs.",
        params: .obj([
            "refs": .arr(.ref, "the word's pen or pencil strokes (item:D/P/I), all on one page"),
            "text": .str("the replacement word or words"),
            "ids": .arr(.str("your own id, [A-Za-z0-9_-]{1,64}"), "caller-chosen ids for the new strokes, in writing order")
        ], required: ["refs", "text"]),
        examples: [example],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard !p.refs.isEmpty else { throw NibError.invalid("refs is empty", path: "$.refs") }
        var location: (doc: DocumentID, page: PageID)?
        var items: [Item] = []
        for (k, ref) in p.refs.enumerated() {
            let path = "$.refs[\(k)]"
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "expected an item ref like item:D/P/I", path: path,
                               hint: "get a word's stroke refs from handwriting.words or recognize.items")
            }
            if let here = location, here.doc != doc || here.page != page {
                throw NibError.invalid("all strokes of the word must be on one page", path: path)
            }
            location = (doc: doc, page: page)
            let item = try ctx.workspace.item(doc, page: page, id: id)
            guard item.kind == .stroke, let stroke = item.stroke, stroke.style.tool == .pen || stroke.style.tool == .pencil,
                  !stroke.points.isEmpty else {
                throw NibError.invalid("\(ref) is not handwriting (pen or pencil ink)", path: path)
            }
            guard !item.locked else { throw NibError.invalid("\(ref) is locked", path: path) }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        guard let here = location else { throw NibError.invalid("refs is empty", path: "$.refs") }
        let doc = here.doc, page = here.page
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NibError.invalid("text is empty", path: "$.text") }
        guard text.count <= 500 else { throw NibError.invalid("text is longer than 500 characters", path: "$.text") }
        let ids = try InkSynthParams.callerIDs(p.ids, doc: doc, page: page, workspace: ctx.workspace,
                                               replacing: Set(items.map { $0.id }))

        // Match what was written: the first stroke's pen and layer, the word's box and lean, its recognised text.
        let ordered = items.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
        let strokes = ordered.compactMap { $0.stroke }
        let polylines = strokes.map { $0.polyline }
        guard let box = Rect.bounding(polylines.flatMap { $0 }) else { throw NibError.invalid("the word has no ink", path: "$.refs") }
        let lean = InkTypesetter.lean(of: polylines, step: InkTypesetter.leanStep(forHeight: box.height))
        let oldText = await recognisedText(p.refs, ctx)
        let options = InkTypesetter.Options(font: ctx.services.settings.get(InkSynthSettings.font),
                                            style: strokes[0].style,
                                            t0: strokes.map { $0.t0 }.min() ?? Date().timeIntervalSince1970)
        let match = InkTypesetter.WordMatch(box: box, lean: lean, text: oldText)
        let layout = await InkTypesetter.offMain { InkTypesetter.layout(text, matching: match, options: options) }
        guard !layout.strokes.isEmpty else {
            throw NibError(.invalidParams, "the text has no characters that can be written as ink", path: "$.text",
                           hint: "use text.createBox for emoji and symbols")
        }
        let layer = ordered[0].layer
        let written = try ctx.mutate { tx -> [Item] in
            for item in items { try tx.delete(item: item.id, doc: doc, page: page) }
            return try InkSynthParams.write(layout.strokes, ids: ids, layer: layer, doc: doc, page: page, tx: tx)
        }
        return Output(refs: InkSynthParams.refs(written, doc: doc, page: page), bounds: InkSynthParams.bounds(written))
    }

    /// The old word's recognised text gives its ascender/descender profile (so "teh" → "the" keeps the baseline).
    /// Optional: without recognition (feature off, not permitted, nothing recognised) the new text's profile is used.
    private static func recognisedText(_ refs: [String], _ ctx: CommandContext) async -> String? {
        let params: JSONValue = ["refs": .array(refs.map { JSONValue.string($0) })]
        guard let value = try? await ctx.execute(CommandIDs.recognizeItems, params) else { return nil }
        return value["text"]?.stringValue
    }
}
