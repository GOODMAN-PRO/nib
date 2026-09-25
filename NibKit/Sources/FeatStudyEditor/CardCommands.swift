import Foundation
import NibContracts

// MARK: - Faces

/// Turns a side given to `card.add` / `card.update` into a stored `CardFace`. `CardFace`'s own decoder already accepts
/// a plain string or {text?, asset?, ink?, size?} and infers the kind (ink > image > text); this normalises ink the way
/// `ink.addStrokes` does (densify + nib sizes) and checks that an image side carries an asset.
enum CardFaces {
    /// The editor's card (DESIGN.md §14.11), and the default canvas of a freeform side.
    static let canvas = PageSize(560, 360)

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
            var strokes = face.ink ?? []
            for i in strokes.indices { InkModel.prepare(&strokes[i]) }
            face.ink = strokes
            if let s = face.size, !(1.0...10_000.0).contains(s.width) || !(1.0...10_000.0).contains(s.height) {
                throw NibError.invalid("size must be 1 to 10000 points on each side", path: path + ".size")
            }
            face.size = face.size ?? fittedCanvas(strokes)
        }
        return face
    }

    /// The default canvas, grown to hold strokes drawn beyond it (AI and plugin ink can land anywhere).
    static func fittedCanvas(_ strokes: [Stroke]) -> PageSize {
        strokes.reduce(canvas) { size, stroke in
            let b = stroke.bounds
            return PageSize(max(size.width, b.maxX), max(size.height, b.maxY))
        }
    }

    /// Plain text of a side as the editor shows it ("" for image and freeform sides).
    static func plainText(_ face: CardFace) -> String {
        face.kind == .text ? (face.text?.plainText ?? "") : ""
    }

    /// Every asset a side names must already be in the set's package (asset.put first).
    @MainActor
    static func checkAssets(_ sides: [(face: CardFace, path: String)], doc: DocumentID, services: NibServices) throws {
        guard let store = services.assets else { return }
        for side in sides {
            guard let asset = side.face.asset else { continue }
            if (try? store.data(asset, doc: doc)) == nil {
                throw NibError(.notFound, "asset \(asset.name) is not stored in doc:\(doc.raw)", path: side.path + ".asset",
                               hint: "store the picture with asset.put {doc, base64, ext} and pass the returned name")
            }
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
        // Pictures live in each set's package: copy them into the destination before the transaction (slow work
        // stays outside mutate; assets are immutable and deduplicated, so a rollback leaves nothing inconsistent).
        var copied: [String: AssetRef] = [:]
        for t in targets where t.doc != dest {
            let live = try ctx.workspace.content(t.doc).liveCards
            let i = try CardRefs.index(of: t.id, in: live, doc: t.doc, path: t.path)
            let card = live[i]
            for asset in [card.front.asset, card.back.asset].compactMap({ $0 }) where copied[t.doc.raw + "/" + asset.name] == nil {
                let store = try ctx.services.require(ctx.services.assets, "the asset store")
                let data = try store.data(asset, doc: t.doc)
                copied[t.doc.raw + "/" + asset.name] = try store.put(data, ext: asset.ext.isEmpty ? "png" : asset.ext, doc: dest)
            }
        }
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
}
