import Foundation
import NibContracts

// MARK: - Faces

/// Turns a side given to `card.add` / `card.update` into a stored `CardFace`. `CardFace`'s own decoder already accepts
/// a plain string or {text?, asset?, ink?, size?} and infers the kind (ink > image > text); this bounds freeform ink
/// to its card, normalises it the way `ink.addStrokes` does (densify + nib sizes) and checks that an image side
/// carries an asset.
enum CardFaces {
    /// The editor's card (DESIGN.md §14.11, `NibMetrics.studyCardSize`), and the default canvas of a freeform side.
    static let canvas = PageSize(560, 360)
    /// The largest canvas a freeform side keeps: four cards each way. A larger `size` shrinks, with its ink.
    static let maxCanvas = PageSize(canvas.width * 4, canvas.height * 4)
    /// Ink that strays off its card is brought back inside this margin (as lassoed ink is pasted).
    static let margin = 24.0
    /// The most stroke points one side may hold once AI and plugin ink is densified.
    static let maxPoints = 250_000

    static func normalized(_ side: CardFace, path: String) throws -> CardFace {
        var face = side
        switch face.kind {
        case .text:
            break
        case .image:
            guard face.asset != nil else {
                throw NibError(.invalidParams, "an image side needs an 'asset'", path: path + ".asset",
                               hint: "store the picture with asset.put {doc, base64, ext} and pass the returned name")
            }
        case .ink:
            let bounded = try boundedInk(face.ink ?? [], size: face.size, path: path)
            var strokes = bounded.strokes
            for i in strokes.indices { InkModel.prepare(&strokes[i]) }
            face.ink = strokes
            face.size = bounded.size
        }
        return face
    }

    /// A freeform side's strokes and canvas, bounded before anything allocates per point: coordinates must be finite,
    /// a canvas over `maxCanvas` shrinks with its ink, ink off the card (beyond the margin) is moved, and scaled down
    /// if it must be, to sit centred inside it, and the densified ink must stay under `maxPoints`. AI, plugin and
    /// bridge ink can come from anywhere (an infinite whiteboard's coordinates, one long segment).
    static func boundedInk(_ ink: [Stroke], size: PageSize?, path: String) throws -> (strokes: [Stroke], size: PageSize) {
        for (i, stroke) in ink.enumerated() where !stroke.points.allSatisfy(isFiniteSample) {
            throw NibError.invalid("stroke points must be finite numbers", path: path + ".ink[\(i)]")
        }
        var canvas = CardFaces.canvas
        if let s = size {
            guard s.width.isFinite, s.height.isFinite, s.width >= 1, s.height >= 1 else {
                throw NibError.invalid("size must be at least 1 point on each side", path: path + ".size")
            }
            canvas = s
        }
        var strokes = ink
        let shrink = min(1, maxCanvas.width / canvas.width, maxCanvas.height / canvas.height)
        if shrink < 1 {
            canvas = PageSize(canvas.width * shrink, canvas.height * shrink)
            strokes = strokes.map { $0.transformed(by: .scale(shrink, shrink)) }
        }
        if let b = pointBounds(strokes),
           b.minX < -margin || b.minY < -margin || b.maxX > canvas.width + margin || b.maxY > canvas.height + margin {
            strokes = centred(strokes, bounds: b, in: canvas)
        }
        guard densifiedCount(strokes) <= maxPoints else {
            throw NibError(.invalidParams, "a freeform side holds at most \(maxPoints) points", path: path + ".ink",
                           hint: "send fewer or shorter strokes")
        }
        return (strokes, canvas)
    }

    private static func isFiniteSample(_ p: StrokePoint) -> Bool {
        p.x.isFinite && p.y.isFinite && p.t.isFinite && p.force.isFinite && p.azimuth.isFinite && p.altitude.isFinite
            && p.roll.isFinite && p.width.isFinite && p.height.isFinite && p.opacity.isFinite
    }

    /// The union of the stroke points, in Double (spans of Float coordinates can overflow); nil without points.
    static func pointBounds(_ strokes: [Stroke]) -> Rect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for stroke in strokes {
            for p in stroke.points {
                minX = min(minX, Double(p.x))
                minY = min(minY, Double(p.y))
                maxX = max(maxX, Double(p.x))
                maxY = max(maxY, Double(p.y))
            }
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Strokes whose points span `bounds`, centred on a `size` card and scaled down (never up) to fit inside the margin.
    static func centred(_ strokes: [Stroke], bounds b: Rect, in size: PageSize, margin: Double = CardFaces.margin) -> [Stroke] {
        let m = min(margin, size.width / 4, size.height / 4)
        let fit = min(1, (size.width - 2 * m) / max(b.width, 1), (size.height - 2 * m) / max(b.height, 1))
        let t = Affine.translation(-b.minX, -b.minY)
            .concatenating(.scale(fit, fit))
            .concatenating(.translation((size.width - b.width * fit) / 2, (size.height - b.height * fit) / 2))
        return strokes.map { $0.transformed(by: t) }
    }

    /// How many points the strokes hold once `InkModel.prepare` has densified them (1.5 pt spacing, ends tripled).
    static func densifiedCount(_ strokes: [Stroke]) -> Int {
        var total = 0
        for stroke in strokes {
            let pts = stroke.points
            guard pts.count >= 2, pts.allSatisfy({ $0.width <= 0 }) else {
                total += pts.count
                continue
            }
            total += pts.count + 4
            for i in 1..<pts.count {
                let d = hypot(Double(pts[i].x) - Double(pts[i - 1].x), Double(pts[i].y) - Double(pts[i - 1].y))
                guard d.isFinite, d / 1.5 < Double(maxPoints) else { return maxPoints + 1 }
                total += max(0, Int((d / 1.5).rounded(.up)) - 1)
            }
            if total > maxPoints { return total }
        }
        return total
    }

    /// Plain text of a side as the editor shows it ("" for image and freeform sides).
    static func plainText(_ face: CardFace) -> String {
        face.kind == .text ? (face.text?.plainText ?? "") : ""
    }

    /// Every asset a side names must already be in the set's package (asset.put first). Only the file's presence is
    /// checked: reading a photo to prove it exists would block the main actor.
    @MainActor
    static func checkAssets(_ sides: [(face: CardFace, path: String)], doc: DocumentID, services: NibServices) throws {
        guard let store = services.assets else { return }
        for side in sides {
            guard let asset = side.face.asset else { continue }
            guard let url = store.url(asset, doc: doc), FileManager.default.fileExists(atPath: url.path) else {
                throw NibError(.notFound, "asset \(asset.name) is not stored in doc:\(doc.raw)", path: side.path + ".asset",
                               hint: "store the picture with asset.put {doc, base64, ext} and pass the returned name")
            }
        }
    }
}

/// Typed edits to a text side that keep its styling (bold, italics, links and paragraph styles from an import or the
/// AI): characters the edit left alone keep their attributes, typed characters take those of the character before
/// them in their paragraph (else the one after; links and inline images are never extended), and paragraphs keep
/// their alignment, list and spacing. A new paragraph takes the style of the one it was split from, unchecked.
enum CardText {
    static func edited(_ old: RichText?, to plain: String) -> RichText {
        guard let old, !old.paragraphs.isEmpty, !isPlain(old) else { return RichText(plain: plain) }
        let newline: Unicode.Scalar = "\n"
        var was: [Unicode.Scalar] = []
        var attrs: [TextAttributes] = []
        for (i, paragraph) in old.paragraphs.enumerated() {
            if i > 0 {
                was.append(newline)
                attrs.append(TextAttributes())
            }
            for run in paragraph.runs {
                for s in run.text.unicodeScalars {
                    was.append(s)
                    attrs.append(run.attrs)
                }
            }
        }
        let now = Array(plain.unicodeScalars)
        let common = min(was.count, now.count)
        var prefix = 0
        while prefix < common, was[prefix] == now[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix, was[was.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }
        let typedEnd = now.count - suffix
        let shift = was.count - now.count                  // a suffix index in `now` + shift = its index in `was`
        // Paragraph index of each position in the old text.
        var paragraphAt = [Int](repeating: 0, count: was.count + 1)
        for i in was.indices { paragraphAt[i + 1] = paragraphAt[i] + (was[i] == newline ? 1 : 0) }

        var typed = TextAttributes()
        if prefix > 0, was[prefix - 1] != newline {
            typed = attrs[prefix - 1]
        } else if prefix < was.count, was[prefix] != newline {
            typed = attrs[prefix]
        }
        typed.link = nil
        typed.attachment = nil

        func oldStyle(_ index: Int, fresh: Bool) -> Paragraph {
            var p = old.paragraphs[min(index, old.paragraphs.count - 1)]
            p.runs = []
            if fresh { p.checked = false }
            return p
        }
        /// The style of the paragraph that starts after the newline at `j` in the new text.
        func styleAfterNewline(_ j: Int) -> Paragraph {
            if j < prefix { return oldStyle(paragraphAt[j + 1], fresh: false) }
            if j >= typedEnd { return oldStyle(paragraphAt[j + shift + 1], fresh: false) }
            return oldStyle(paragraphAt[prefix], fresh: true)
        }

        var paragraphs: [Paragraph] = []
        var current = oldStyle(0, fresh: false)
        var runText = String.UnicodeScalarView()
        var runAttrs: TextAttributes?
        func endRun() {
            if let a = runAttrs, !runText.isEmpty { current.runs.append(TextRun(String(runText), a)) }
            runText = String.UnicodeScalarView()
            runAttrs = nil
        }
        for j in now.indices {
            if now[j] == newline {
                endRun()
                paragraphs.append(current)
                current = styleAfterNewline(j)
                continue
            }
            let a = j < prefix ? attrs[j] : j >= typedEnd ? attrs[j + shift] : typed
            if a != runAttrs {
                endRun()
                runAttrs = a
            }
            runText.append(now[j])
        }
        endRun()
        paragraphs.append(current)
        return RichText(paragraphs: paragraphs)
    }

    /// Default paragraph styles and character attributes throughout.
    static func isPlain(_ text: RichText) -> Bool {
        text.paragraphs.allSatisfy { p in
            p == Paragraph(runs: p.runs) && p.runs.allSatisfy { $0.attrs == TextAttributes() }
        }
    }
}

enum CardSchema {
    static let side: JSONSchema = .anything(
        "a string (text side) or {text?, asset?: asset name in this set, ink?: Stroke[] ({fmt, pts, style?}), size?: {width, height}}; kind inferred: ink > image > text")

    static let addExamples: [JSONValue] = [
        ["doc": "doc:FIXTUREDOC03", "front": "Newton's second law", "back": "F = ma"],
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC03", "front": {"text": "Photo"}, "back": {"asset": "fixture-image.png"}, "after": "card:FIXTUREDOC03/FIXTURECRD01"}"#),
        try! JSONValue.parse(#"{"doc": "doc:FIXTUREDOC03", "front": {"ink": [{"fmt": "xy", "pts": [40, 60, 200, 60, 200, 140]}]}, "back": "A right angle"}"#),
    ]
}

// MARK: - Refs and order

/// One card named by a ref param.
struct CardTarget {
    var doc: DocumentID
    var id: NibID
    var path: String
}

@MainActor
enum CardRefs {
    /// A study set from "doc:D", any ref inside it, or a bare id.
    static func studySet(_ string: String, _ ctx: CommandContext, path: String) throws -> DocumentID {
        let doc = NodeRef.documentID(from: string)
        guard let content = try? ctx.workspace.content(doc) else {
            throw NibError(.notFound, "document \(doc.raw) not found", path: path, hint: "call query.tree to list documents")
        }
        guard content.meta.kind == .studySet else {
            throw NibError.invalid("doc:\(doc.raw) is a \(content.meta.kind.rawValue), not a study set", path: path)
        }
        return doc
    }

    static func card(_ string: String, path: String) throws -> CardTarget {
        guard case let .card(doc, id)? = NodeRef(string) else {
            throw NibError.invalid("expected a card ref like card:<doc>/<card>", path: path)
        }
        return CardTarget(doc: doc, id: id, path: path)
    }

    /// Distinct card refs of a `refs` param, in order, each in a study set.
    static func cards(_ refs: [String], _ ctx: CommandContext) throws -> [CardTarget] {
        guard !refs.isEmpty else { throw NibError.invalid("give at least one card ref", path: "$.refs") }
        var seen = Set<String>()
        var out: [CardTarget] = []
        for (n, ref) in refs.enumerated() {
            let t = try card(ref, path: "$.refs[\(n)]")
            guard seen.insert(t.doc.raw + "/" + t.id.raw).inserted else { continue }
            _ = try studySet(t.doc.raw, ctx, path: t.path)
            out.append(t)
        }
        return out
    }

    /// The `after` param: a card ref in `doc`, or a bare card id.
    static func cardID(_ string: String, in doc: DocumentID, path: String) throws -> NibID {
        if let ref = NodeRef(string) {
            guard case let .card(d, id) = ref, d == doc else {
                throw NibError.invalid("expected a card of doc:\(doc.raw)", path: path)
            }
            return id
        }
        guard NibID.isValid(string) else { throw NibError.invalid("expected a card ref or id", path: path) }
        return NibID(string)
    }

    static func index(of id: NibID, in cards: [StudyCard], doc: DocumentID, path: String) throws -> Int {
        guard let i = cards.firstIndex(where: { $0.id == id }) else {
            throw NibError(.notFound, "card \(id.raw) not found in doc:\(doc.raw)", path: path,
                           hint: "call query.get {\"ref\": \"doc:\(doc.raw)\"} to list its cards")
        }
        return i
    }

    /// The live card a target names.
    static func live(_ t: CardTarget, _ tx: DocTransaction) throws -> StudyCard {
        let live = try tx.content(t.doc).liveCards
        let i = try index(of: t.id, in: live, doc: t.doc, path: t.path)
        return live[i]
    }
}

/// Fractional order keys for cards (the same keys pages and blocks use).
enum CardOrder {
    /// The key for a card placed at `index` among `orders` (live cards in display order, without that card), plus new
    /// keys (by index) for existing cards when theirs cannot bracket a new one: empty or out-of-order keys left by raw
    /// inserts or merges. Then every key comes from one fresh increasing sequence.
    static func place(at index: Int, among orders: [String]) -> (key: String, rekeyed: [Int: String]) {
        let i = min(max(index, 0), orders.count)
        let prev = i > 0 ? orders[i - 1] : nil
        let next = i < orders.count ? orders[i] : nil
        var usable = prev?.isEmpty != true && next?.isEmpty != true
        if usable, let p = prev, let n = next { usable = p < n }
        if usable { return (FractionalIndex.between(prev, next), [:]) }
        let keys = FractionalIndex.sequence(after: nil, count: orders.count + 1)
        var rekeyed: [Int: String] = [:]
        for (j, old) in orders.enumerated() {
            let key = keys[j < i ? j : j + 1]
            if key != old { rekeyed[j] = key }
        }
        return (keys[i], rekeyed)
    }

    @MainActor
    static func apply(_ rekeyed: [Int: String], to cards: [StudyCard], doc: DocumentID, tx: DocTransaction) throws {
        for (j, key) in rekeyed.sorted(by: { $0.key < $1.key }) {
            var card = cards[j]
            card.order = key
            try tx.put(card, doc: doc)
        }
    }
}

// MARK: - Commands

struct CardAdd: NibCommand {
    struct Params: Codable {
        var doc: String
        var front: CardFace
        var back: CardFace
        var after: String?
        var id: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "card.add", title: "Add Card",
        summary: "Add a flashcard to a study set; front and back are each a string or {text?, asset?, ink?: Stroke[], size?} (kind inferred: ink > image > text); after? = card to follow.",
        params: .obj(["doc": .ref, "front": CardSchema.side, "back": CardSchema.side,
                      "after": .str("card ref (or id) the new card follows; omitted = at the end"),
                      "id": .str("your own id, [A-Za-z0-9_-]{1,64}")],
                     required: ["doc", "front", "back"]),
        examples: CardSchema.addExamples,
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try CardRefs.studySet(p.doc, ctx, path: "$.doc")
        if let id = p.id, !NibID.isValid(id) {
            throw NibError.invalid("id must be 1 to 64 characters of [A-Za-z0-9_-]", path: "$.id")
        }
        let front = try CardFaces.normalized(p.front, path: "$.front")
        let back = try CardFaces.normalized(p.back, path: "$.back")
        try CardFaces.checkAssets([(front, "$.front"), (back, "$.back")], doc: doc, services: ctx.services)
        let card = try ctx.mutate { tx -> StudyCard in
            let live = try tx.content(doc).liveCards
            var index = live.count
            if let after = p.after {
                let anchor = try CardRefs.cardID(after, in: doc, path: "$.after")
                index = try CardRefs.index(of: anchor, in: live, doc: doc, path: "$.after") + 1
            }
            let id = p.id.map { NibID($0) } ?? NibID.make()
            if live.contains(where: { $0.id == id }) {
                throw NibError(.invalidParams, "card \(id.raw) already exists in doc:\(doc.raw)", path: "$.id",
                               hint: "choose another id, or change the card with card.update")
            }
            let slot = CardOrder.place(at: index, among: live.map { $0.order })
            try CardOrder.apply(slot.rekeyed, to: live, doc: doc, tx: tx)
            return try tx.put(StudyCard(id: id, front: front, back: back, order: slot.key), doc: doc)
        }
        return Output(ref: NodeRef.card(doc, card.id).description)
    }
}

struct CardUpdate: NibCommand {
    struct Params: Codable {
        var ref: String
        var front: CardFace?
        var back: CardFace?
    }

    static let descriptor = CommandDescriptor(
        id: "card.update", title: "Edit Card",
        summary: "Edit a card: replace its front and/or back (each a string or {text?, asset?, ink?: Stroke[], size?}; kind inferred).",
        params: .obj(["ref": .ref, "front": CardSchema.side, "back": CardSchema.side], required: ["ref"]),
        examples: [["ref": "card:FIXTUREDOC03/FIXTURECRD01", "front": "Term (revised)"],
                   try! JSONValue.parse(#"{"ref": "card:FIXTUREDOC03/FIXTURECRD02", "back": {"text": "A one-pixel picture"}}"#)],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let target = try CardRefs.card(p.ref, path: "$.ref")
        let doc = try CardRefs.studySet(target.doc.raw, ctx, path: "$.ref")
        guard p.front != nil || p.back != nil else {
            throw NibError(.invalidParams, "nothing to change", hint: "pass front and/or back")
        }
        let front = try p.front.map { try CardFaces.normalized($0, path: "$.front") }
        let back = try p.back.map { try CardFaces.normalized($0, path: "$.back") }
        var sides: [(face: CardFace, path: String)] = []
        if let f = front { sides.append((f, "$.front")) }
        if let b = back { sides.append((b, "$.back")) }
        try CardFaces.checkAssets(sides, doc: doc, services: ctx.services)
        try ctx.mutate { tx in
            let current = try CardRefs.live(target, tx)
            var card = current
            if let f = front { card.front = f }
            if let b = back { card.back = b }
            if card != current { try tx.put(card, doc: doc) }
        }
        return NoResult()
    }
}

struct CardDelete: NibCommand {
    struct Params: Codable {
        var refs: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "card.delete", title: "Delete Cards",
        summary: "Delete cards (card refs, from one or several study sets).",
        params: .obj(["refs": .arr(.ref)], required: ["refs"]),
        examples: [["refs": ["card:FIXTUREDOC03/FIXTURECRD02"]]],
        effect: .edit, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let targets = try CardRefs.cards(p.refs, ctx)
        try ctx.mutate { tx in
            for t in targets {
                var card = try CardRefs.live(t, tx)
                card.deleted = true
                try tx.put(card, doc: t.doc)
            }
        }
        return NoResult()
    }
}

struct CardMove: NibCommand {
    struct Params: Codable {
        var ref: String
        var after: String?
    }

    static let descriptor = CommandDescriptor(
        id: "card.move", title: "Reorder Card",
        summary: "Reorder a card within its study set: place it after another card, or first when after is omitted.",
        params: .obj(["ref": .ref, "after": .str("card ref (or id) to follow; omitted = first")], required: ["ref"]),
        examples: [["ref": "card:FIXTUREDOC03/FIXTURECRD02"],
                   ["ref": "card:FIXTUREDOC03/FIXTURECRD01", "after": "card:FIXTUREDOC03/FIXTURECRD02"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let target = try CardRefs.card(p.ref, path: "$.ref")
        let doc = try CardRefs.studySet(target.doc.raw, ctx, path: "$.ref")
        try ctx.mutate { tx in
            let live = try tx.content(doc).liveCards
            let i = try CardRefs.index(of: target.id, in: live, doc: doc, path: "$.ref")
            var rest = live
            var card = rest.remove(at: i)
            var index = 0
            if let after = p.after {
                let anchor = try CardRefs.cardID(after, in: doc, path: "$.after")
                guard anchor != card.id else { throw NibError.invalid("a card cannot follow itself", path: "$.after") }
                index = try CardRefs.index(of: anchor, in: rest, doc: doc, path: "$.after") + 1
            }
            guard index != i else { return }                          // already there
            let slot = CardOrder.place(at: index, among: rest.map { $0.order })
            try CardOrder.apply(slot.rekeyed, to: rest, doc: doc, tx: tx)
            card.order = slot.key
            try tx.put(card, doc: doc)
        }
        return NoResult()
    }
}

struct CardMoveTo: NibCommand {
    struct Params: Codable {
        var refs: [String]
        var doc: String
        var ids: [String]?
    }

    struct Output: Codable {
        var refs: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "card.moveTo", title: "Move Cards to Study Set",
        summary: "Move cards to another study set, appended at its end (images copied, practice progress kept); returns the new card refs.",
        params: .obj(["refs": .arr(.ref), "doc": .ref,
                      "ids": .arr(.str(), "your own ids for the moved cards, one per ref (cards already in the set keep theirs)")],
                     required: ["refs", "doc"]),
        examples: [["refs": ["card:FIXTUREDOC03/FIXTURECRD01"], "doc": "doc:FIXTUREDOC03"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let dest = try CardRefs.studySet(p.doc, ctx, path: "$.doc")
        let targets = try CardRefs.cards(p.refs, ctx)
        if let ids = p.ids {
            guard ids.count == targets.count else { throw NibError.invalid("give one id per distinct ref", path: "$.ids") }
            for (n, id) in ids.enumerated() where !NibID.isValid(id) {
                throw NibError.invalid("ids must be 1 to 64 characters of [A-Za-z0-9_-]", path: "$.ids[\(n)]")
            }
        }
        // Pictures live in each set's package: copy them into the destination before the transaction, off the main
        // actor (reading, hashing and writing photos is slow; AssetStore is thread-safe). Assets are immutable and
        // deduplicated, so a rollback leaves nothing inconsistent.
        var pending: [(src: DocumentID, asset: AssetRef)] = []
        var queued = Set<String>()
        for t in targets where t.doc != dest {
            let live = try ctx.workspace.content(t.doc).liveCards
            let card = live[try CardRefs.index(of: t.id, in: live, doc: t.doc, path: t.path)]
            for asset in [card.front.asset, card.back.asset].compactMap({ $0 }) where queued.insert(t.doc.raw + "/" + asset.name).inserted {
                pending.append((t.doc, asset))
            }
        }
        var copied: [String: AssetRef] = [:]
        if !pending.isEmpty { copied = try await copy(pending, to: dest, ctx) }
        let assets = copied
        func remap(_ face: CardFace, from src: DocumentID) -> CardFace {
            var f = face
            if let a = f.asset, let moved = assets[src.raw + "/" + a.name] { f.asset = moved }
            return f
        }
        let refs = try ctx.mutate { tx -> [String] in
            var last = try tx.content(dest).liveCards.last?.order
            var out: [String] = []
            for (n, t) in targets.enumerated() {
                var card = try CardRefs.live(t, tx)
                let order = FractionalIndex.between(last, nil)
                last = order
                if t.doc == dest {
                    card.order = order
                    try tx.put(card, doc: dest)
                    out.append(NodeRef.card(dest, card.id).description)
                    continue
                }
                var gone = card
                gone.deleted = true
                try tx.put(gone, doc: t.doc)
                let taken = try Set(tx.content(dest).liveCards.map { $0.id })
                var id = card.id
                if let ids = p.ids {
                    id = NibID(ids[n])
                    guard !taken.contains(id) else {
                        throw NibError.invalid("card \(id.raw) already exists in doc:\(dest.raw)", path: "$.ids[\(n)]")
                    }
                } else if taken.contains(id) {
                    id = NibID.make()
                }
                var moved = StudyCard(id: id, front: remap(card.front, from: t.doc), back: remap(card.back, from: t.doc),
                                      order: order)
                moved.srs = card.srs
                try tx.put(moved, doc: dest)
                out.append(NodeRef.card(dest, id).description)
            }
            return out
        }
        return Output(refs: refs)
    }

    /// Copies pictures into `dest`, keyed "<source doc>/<asset name>".
    private static func copy(_ pending: [(src: DocumentID, asset: AssetRef)], to dest: DocumentID,
                             _ ctx: CommandContext) async throws -> [String: AssetRef] {
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        return try await Task.detached(priority: .userInitiated) { () throws -> [String: AssetRef] in
            var out: [String: AssetRef] = [:]
            for item in pending {
                let data = try store.data(item.asset, doc: item.src)
                let ext = item.asset.ext.isEmpty ? "png" : item.asset.ext
                out[item.src.raw + "/" + item.asset.name] = try store.put(data, ext: ext, doc: dest)
            }
            return out
        }.value
    }
}
