import Foundation
import NibContracts

// The five handwriting.* commands F058 owns (ARCHITECTURE.md §6.5). Reads go through handwriting.words; every edit
// is one `ctx.mutate`, so undo, sync, plugins, the AI and the bridge all see the same change.

/// Shared plumbing for the commands and Edit Handwriting mode.
@MainActor
enum Handwriting {
    /// The handwriting of one page among a command's refs.
    struct Target {
        let doc: DocumentID
        let page: PageID
        var items: [Item]

        var pageRef: String { NodeRef.page(doc, page).description }
        func ref(_ id: ElementID) -> String { NodeRef.item(doc, page, id).description }
        var glyphs: [InkGlyph] { items.compactMap { InkGlyph(item: $0) } }
    }

    /// Live, unlocked pen and pencil strokes.
    static func isHandwriting(_ item: Item) -> Bool { !item.locked && InkGlyph(item: item) != nil }

    /// Groups item refs by page and keeps their handwriting. Throws for malformed or missing refs, and when no
    /// handwriting is left at all.
    static func targets(_ refs: [String], workspace: Workspace) throws -> [Target] {
        guard !refs.isEmpty else { throw NibError.invalid("refs is empty", path: "$.refs") }
        var order: [NodeRef] = []
        var wanted: [NodeRef: [ElementID]] = [:]
        for (i, ref) in refs.enumerated() {
            guard case let .item(doc, page, id)? = NodeRef(ref) else {
                throw NibError(.invalidParams, "'\(ref)' is not an item ref", path: "$.refs[\(i)]",
                               hint: "pass stroke refs such as item:D/P/I (query.find {in: page, kinds: [\"stroke\"]})")
            }
            let key = NodeRef.page(doc, page)
            if wanted[key] == nil { order.append(key) }
            wanted[key, default: []].append(id)
        }
        var out: [Target] = []
        for key in order {
            guard case let .page(doc, page) = key else { continue }
            guard try workspace.content(doc).page(page) != nil else { throw NibError.notFound("page \(page)") }
            var byID: [ElementID: Item] = [:]
            for item in try workspace.items(doc, page: page) { byID[item.id] = item }
            var seen = Set<ElementID>()
            var items: [Item] = []
            for id in wanted[key] ?? [] where seen.insert(id).inserted {
                guard let item = byID[id] else { throw NibError.notFound("item \(id) on page \(page)") }
                if isHandwriting(item) { items.append(item) }
            }
            if !items.isEmpty { out.append(Target(doc: doc, page: page, items: items)) }
        }
        guard !out.isEmpty else {
            throw NibError(.invalidParams, "refs contain no handwriting (pen or pencil strokes)", path: "$.refs",
                           hint: "select strokes with query.find {in: page, kinds: [\"stroke\"]}")
        }
        return out
    }

    /// Word hints from recognition: `recognize.items` (F055) when installed, else the recognizer service. Never
    /// throws: without recognition the layout falls back to stroke gaps alone.
    static func hints(for target: Target, services: NibServices, workspace: Workspace,
                      recognize: (JSONValue) async throws -> JSONValue) async -> [InkHint] {
        let refs = JSONValue.array(target.items.map { .string(target.ref($0.id)) })
        let glyphs = target.glyphs
        if let value = try? await recognize(["refs": refs]) {
            let hints = InkLayout.hints(fromRecognition: value, glyphs: glyphs)
            if !hints.isEmpty { return hints }
        }
        guard let recognizer = services.recognizer else { return [] }
        let language = (try? workspace.content(target.doc).meta.language) ?? "en-US"
        guard let results = try? await recognizer.recognize(strokes: target.items, language: language) else { return [] }
        return InkLayout.hints(fromRecognizer: results, glyphs: glyphs)
    }

    static func hints(for target: Target, ctx: CommandContext) async -> [InkHint] {
        await hints(for: target, services: ctx.services, workspace: ctx.workspace) { params in
            try await ctx.execute(CommandIDs.recognizeItems, params)
        }
    }

    /// Analyses off the main actor (a whole page of strokes can take longer than a frame).
    static func layout(_ glyphs: [InkGlyph], hints: [InkHint]) async -> InkLayout {
        await Task.detached(priority: .userInitiated) { InkLayout.analyze(glyphs, hints: hints) }.value
    }

    static func layout(_ target: Target, ctx: CommandContext) async -> InkLayout {
        let hints = await hints(for: target, ctx: ctx)
        return await layout(target.glyphs, hints: hints)
    }

    /// Writes per-stroke transforms in one transaction; returns how many strokes changed.
    @discardableResult
    static func write(_ transforms: [ElementID: Affine], to target: Target, ctx: CommandContext) throws -> Int {
        let changes = target.items.compactMap { item -> (ElementID, Affine)? in
            guard let t = transforms[item.id], !isIdentity(t) else { return nil }
            return (item.id, t)
        }
        guard !changes.isEmpty else { return 0 }
        return try ctx.mutate { tx in
            var n = 0
            for (id, t) in changes {
                guard let current = try? tx.item(target.doc, page: target.page, id: id) else { continue }
                try tx.put(current.transformed(by: t), doc: target.doc, page: target.page)
                n += 1
            }
            return n
        }
    }

    static func translations(_ moves: [ElementID: Point]) -> [ElementID: Affine] {
        moves.mapValues { Affine.translation($0.x, $0.y) }
    }

    static func isIdentity(_ t: Affine) -> Bool {
        abs(t.a - 1) < 1e-9 && abs(t.b) < 1e-9 && abs(t.c) < 1e-9 && abs(t.d - 1) < 1e-9
            && abs(t.tx) < 0.005 && abs(t.ty) < 0.005
    }

    static func rounded(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    static func rounded(_ r: Rect) -> Rect {
        Rect(x: rounded(r.x), y: rounded(r.y), width: rounded(r.width), height: rounded(r.height))
    }
    static func rounded(_ p: Point) -> Point { Point(rounded(p.x), rounded(p.y)) }
}

/// Schema pieces shared by the descriptors (not actor-isolated, so descriptor initialisers can use them).
enum SmartInkSchema {
    static let strokeRef: JSONValue = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"
    static let refs: JSONSchema = .arr(.ref, "stroke item refs (item:D/P/I); other items are ignored")
}

// MARK: - handwriting.words

struct HandwritingWords: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var cursor: String?
    }

    struct Word: Codable {
        var refs: [String]
        var bbox: Rect
        var text: String?
    }

    struct Line: Codable {
        var page: String
        var bbox: Rect
        /// Two page points: the baseline at the line's left and right ends.
        var baseline: [Point]
        /// Degrees, clockwise on screen.
        var angle: Double
        var xHeight: Double
        var paragraphStart: Bool
        var listItem: Bool
        var text: String?
        var words: [Word]
    }

    struct Output: Codable {
        var lines: [Line]
        /// Typical distance between line centres (points).
        var lineSpacing: Double
        var text: String?
        var truncated: Bool?
        var cursor: String?
    }

    static let descriptor = CommandDescriptor(
        id: "handwriting.words", title: "Handwriting Lines and Words",
        summary: "Group handwriting strokes into lines and words: bboxes, baselines, angles, paragraph starts and recognised text when available.",
        params: .obj(["refs": SmartInkSchema.refs,
                      "cursor": .str("from a truncated result: continue from this line")],
                     required: ["refs"]),
        examples: [["refs": [SmartInkSchema.strokeRef]]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let targets = try Handwriting.targets(p.refs, workspace: ctx.workspace)
        var lines: [Line] = []
        var spacing = 0.0
        for target in targets {
            let layout = await Handwriting.layout(target, ctx: ctx)
            if spacing == 0 { spacing = layout.pitch }
            for line in layout.lines {
                let left = layout.toPage(Point(line.box.minX, line.centerY(at: line.box.minX) + line.baselineOffset))
                let right = layout.toPage(Point(line.box.maxX, line.centerY(at: line.box.maxX) + line.baselineOffset))
                let words = line.words.map { w in
                    Word(refs: w.ids.map { target.ref($0) }, bbox: Handwriting.rounded(layout.pageBounds(w.box)), text: w.text)
                }
                let texts = line.words.compactMap { $0.text }
                lines.append(Line(page: target.pageRef, bbox: Handwriting.rounded(layout.pageBounds(line.box)),
                                  baseline: [Handwriting.rounded(left), Handwriting.rounded(right)],
                                  angle: Handwriting.rounded((layout.skew + atan(line.slope)) * 180 / .pi),
                                  xHeight: Handwriting.rounded(line.xHeight), paragraphStart: line.startsParagraph,
                                  listItem: line.isListItem,
                                  text: texts.count == line.words.count ? texts.joined(separator: " ") : nil,
                                  words: words))
            }
        }
        let start = min(max(Int(p.cursor ?? "0") ?? 0, 0), lines.count)
        // Results stay under the 20 KB tool budget; the rest is paged by line.
        var page: [Line] = []
        var bytes = 0
        let encoder = JSONEncoder()
        for line in lines[start...] {
            let size = (try? encoder.encode(line).count) ?? 0
            if !page.isEmpty && bytes + size > NibLimits.aiToolResultBytes - 2_000 { break }
            page.append(line)
            bytes += size
        }
        let end = start + page.count
        let texts = lines.compactMap { $0.text }
        let text: String? = start == 0 && end == lines.count && texts.count == lines.count && !lines.isEmpty
            ? texts.joined(separator: "\n") : nil
        return Output(lines: page, lineSpacing: Handwriting.rounded(spacing), text: text,
                      truncated: end < lines.count ? true : nil, cursor: end < lines.count ? String(end) : nil)
    }
}

// MARK: - handwriting.reflow

struct HandwritingReflow: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var width: Double
        var left: Double?
    }

    struct Output: Codable {
        /// Strokes moved.
        var moved: Int
        /// Lines after the reflow.
        var lines: Int
    }

    static let descriptor = CommandDescriptor(
        id: "handwriting.reflow", title: "Reflow Handwriting",
        summary: "Reflow handwriting into a column of a new width by moving whole words (strokes are only translated; paragraphs, lists and indents are kept).",
        params: .obj(["refs": SmartInkSchema.refs,
                      "width": .num("column width in page points", min: 1, max: 100_000),
                      "left": .num("page x of the column's left edge (default: where it is now)")],
                     required: ["refs", "width"]),
        examples: [["refs": [SmartInkSchema.strokeRef], "width": 240]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.width.isFinite, p.width >= 1 else { throw NibError.invalid("width must be at least 1 point", path: "$.width") }
        if let left = p.left, !left.isFinite { throw NibError.invalid("left must be a number", path: "$.left") }
        var moved = 0
        var lines = 0
        for target in try Handwriting.targets(p.refs, workspace: ctx.workspace) {
            let layout = await Handwriting.layout(target, ctx: ctx)
            let width = max(p.width, layout.widestWord)
            let result = layout.reflow(width: width, left: p.left.map { layout.layoutLeft(fromPage: $0) })
            moved += try Handwriting.write(Handwriting.translations(result.moves), to: target, ctx: ctx)
            lines += result.lineCount
        }
        return Output(moved: moved, lines: lines)
    }
}

// MARK: - handwriting.straighten

struct HandwritingStraighten: NibCommand {
    struct Params: Codable {
        var refs: [String]
        /// Degrees; flatter lines stay as written (default 0.5).
        var minAngle: Double?
    }

    struct Output: Codable {
        /// Lines levelled.
        var straightened: Int
        var lines: Int
    }

    static let descriptor = CommandDescriptor(
        id: "handwriting.straighten", title: "Straighten Lines",
        summary: "Straighten slanted handwritten lines: each line is sheared (or rotated past 15°) to horizontal about its centre.",
        params: .obj(["refs": SmartInkSchema.refs,
                      "minAngle": .num("degrees: lines flatter than this stay as written (default 0.5)", min: 0, max: 45)],
                     required: ["refs"]),
        examples: [["refs": [SmartInkSchema.strokeRef]]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let minimum = p.minAngle ?? 0.5
        guard minimum.isFinite, minimum >= 0 else { throw NibError.invalid("minAngle must be 0 or more degrees", path: "$.minAngle") }
        var straightened = 0
        var lines = 0
        for target in try Handwriting.targets(p.refs, workspace: ctx.workspace) {
            let layout = await Handwriting.layout(target, ctx: ctx)
            let transforms = layout.straightening(minimumAngle: minimum * .pi / 180)
            straightened += layout.lines.filter { line in line.ids.contains { transforms[$0] != nil } }.count
            lines += layout.lines.count
            try Handwriting.write(transforms, to: target, ctx: ctx)
        }
        return Output(straightened: straightened, lines: lines)
    }
}

// MARK: - handwriting.align

struct HandwritingAlign: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var align: String
    }

    struct Output: Codable {
        var moved: Int
    }

    static let descriptor = CommandDescriptor(
        id: "handwriting.align", title: "Align Handwriting",
        summary: "Align handwritten lines to the left edge, centre or right edge of their block.",
        params: .obj(["refs": SmartInkSchema.refs,
                      "align": .str("left, centre (or center) or right", choices: ["left", "centre", "center", "right"])],
                     required: ["refs", "align"]),
        examples: [["refs": [SmartInkSchema.strokeRef], "align": "centre"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let alignment: InkAlignment
        switch p.align.lowercased() {
        case "left": alignment = .left
        case "centre", "center": alignment = .centre
        case "right": alignment = .right
        default: throw NibError.invalid("align must be left, centre or right", path: "$.align")
        }
        var moved = 0
        for target in try Handwriting.targets(p.refs, workspace: ctx.workspace) {
            let layout = await Handwriting.layout(target, ctx: ctx)
            moved += try Handwriting.write(Handwriting.translations(layout.alignment(alignment)), to: target, ctx: ctx)
        }
        return Output(moved: moved)
    }
}

// MARK: - handwriting.insertSpace

struct HandwritingInsertSpace: NibCommand {
    struct Params: Codable {
        var page: String
        var y: Double
        var height: Double
    }

    struct Output: Codable {
        var moved: Int
    }

    static let descriptor = CommandDescriptor(
        id: "handwriting.insertSpace", title: "Insert Space",
        summary: "Insert vertical space at page y, pushing the ink and items below down by height (a negative height closes space).",
        params: .obj(["page": .ref,
                      "y": .num("page y where the space opens"),
                      "height": .num("points of space; negative closes space", min: -10_000, max: 10_000)],
                     required: ["page", "y", "height"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "y": 300, "height": 40]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else {
            throw NibError(.invalidParams, "'\(p.page)' is not a page ref", path: "$.page", hint: "pass page:D/P")
        }
        guard p.y.isFinite, p.height.isFinite else { throw NibError.invalid("y and height must be numbers", path: "$.height") }
        guard try ctx.workspace.content(doc).page(page) != nil else { throw NibError.notFound("page \(page)") }
        let items = try ctx.workspace.items(doc, page: page)
        let moved = SpaceInsertion.moved(items, y: p.y, height: p.height)
        guard !moved.isEmpty else { return Output(moved: 0) }
        try ctx.mutate { tx in
            for item in moved { try tx.put(item, doc: doc, page: page) }
        }
        return Output(moved: moved.count)
    }
}
