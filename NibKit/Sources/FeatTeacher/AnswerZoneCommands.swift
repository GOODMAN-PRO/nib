import Foundation
import NibContracts

// Answer-zone commands (F099). Every change to an answer zone goes through one of these four commands, so the score
// widget, the inspector, plugins, the assistant and the bridge all do the same thing. Zones are `custom` items owned
// by "nib.answerZone" (`AnswerZone` in AnswerZones.swift); reads go through the query API (`query.get`,
// `query.find {where: {"custom.owner": ...}}`), where the zone record is the item's `custom.data`.

// MARK: - Which zones a ref names

/// One answer zone a command acts on.
struct AnswerZoneTarget {
    let doc: DocumentID
    let page: PageID
    let item: Item
    let zone: AnswerZone

    var ref: String { NodeRef.item(doc, page, item.id).description }
}

/// The answer zones a command's `ref` names: one zone (`item:D/P/I`), every zone of a page (`page:D/P`) or every zone
/// of a document (`doc:D`), in reading order (page order, then top to bottom, then left to right).
@MainActor
enum AnswerZoneScope {
    enum Kind: Equatable {
        case zone, page, document
    }

    struct Resolved {
        let kind: Kind
        let doc: DocumentID
        let targets: [AnswerZoneTarget]
    }

    static func resolve(_ ref: String, _ workspace: Workspace, path: String = "$.ref") throws -> Resolved {
        guard let node = NodeRef(ref) else {
            throw NibError(.invalidParams, "'\(ref)' is not a ref", path: path,
                           hint: "pass an answer zone (item:D/P/I), a page (page:D/P) or a document (doc:D)")
        }
        switch node {
        case let .item(doc, page, id):
            let item = try workspace.item(doc, page: page, id: id)
            guard let zone = AnswerZone.decode(item) else {
                throw NibError(.invalidParams, "\(ref) is not an answer zone", path: path,
                               hint: "answer zones are custom items owned by \(AnswerZone.owner); create one with answerZone.create")
            }
            return Resolved(kind: .zone, doc: doc, targets: [AnswerZoneTarget(doc: doc, page: page, item: item, zone: zone)])
        case let .page(doc, page):
            guard let record = try workspace.content(doc).page(page), !record.deleted else {
                throw NibError.notFound("page \(page.raw)")
            }
            return Resolved(kind: .page, doc: doc, targets: try zones(doc: doc, page: page, workspace))
        case let .document(doc):
            var targets: [AnswerZoneTarget] = []
            for record in try workspace.content(doc).livePages {
                targets += try zones(doc: doc, page: record.id, workspace)
            }
            return Resolved(kind: .document, doc: doc, targets: targets)
        default:
            throw NibError(.invalidParams, "\(ref) cannot hold answer zones", path: path,
                           hint: "pass an answer zone (item:D/P/I), a page (page:D/P) or a document (doc:D)")
        }
    }

    /// The live zones of one page in reading order.
    static func zones(doc: DocumentID, page: PageID, _ workspace: Workspace) throws -> [AnswerZoneTarget] {
        try workspace.items(doc, page: page)
            .compactMap { item in AnswerZone.decode(item).map { AnswerZoneTarget(doc: doc, page: page, item: item, zone: $0) } }
            .sorted { AnswerZoneLayout.readsBefore($0.item.bounds, $1.item.bounds) }
    }
}

// MARK: - Shared validation

enum AnswerZoneRules {
    /// Hints trimmed, empty lines dropped; errors name the offending entry.
    static func hints(_ raw: [String], path: String) throws -> [String] {
        var out: [String] = []
        for (i, hint) in raw.enumerated() {
            let text = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            guard text.count <= AnswerZone.maxHintLength else {
                throw NibError.invalid("hint \(i + 1) is longer than \(AnswerZone.maxHintLength) characters", path: "\(path)[\(i)]")
            }
            out.append(text)
        }
        guard out.count <= AnswerZone.maxHints else {
            throw NibError(.invalidParams, "an answer zone takes at most \(AnswerZone.maxHints) hints", path: path,
                           hint: "merge some hints or split the question into two zones")
        }
        return out
    }

    /// Scores and points keep two decimals (half and quarter marks).
    static func rounded(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    @MainActor
    static func checkWritable(_ doc: DocumentID, _ ctx: CommandContext) throws {
        if ctx.isReadOnly(doc) {
            throw NibError(.unsupported, "this document is open read-only (it was saved by a newer Nib)",
                           hint: "update Nib to change it")
        }
    }

    static var now: Double { Date().timeIntervalSince1970 }
}

// MARK: - answerZone.create

struct AnswerZoneCreate: NibCommand {
    struct Params: Codable {
        var page: String?
        var rect: [Double]
        var points: Double?
        var hints: [String]?
        var id: String?
        var label: String?
    }

    struct Output: Codable {
        var ref: String
    }

    static let descriptor = CommandDescriptor(
        id: "answerZone.create", title: String(localized: "Add Answer Zone"),
        summary: "Mark an answer zone on a page: rect [x,y,w,h]; points? adds a score box out of that many; hints? are teacher hints revealed one at a time.",
        params: .obj(["page": .ref,
                      "rect": .rect,
                      "points": .num("maximum score; adds the score box", min: 0.5, max: AnswerZone.maxPoints),
                      "hints": .arr(.str("a teacher-approved hint"), "hints in the order students reveal them (at most 10)"),
                      "id": .str("your own id for the zone, [A-Za-z0-9_-]{1,64}"),
                      "label": .str("short name, e.g. 'Question 3' (read by VoiceOver, search and the assistant)")],
                     required: ["page", "rect"]),
        examples: [try! JSONValue.parse(#"{"page": "page:FIXTUREDOC01/FIXTUREPG002", "rect": [72, 120, 320, 140], "points": 5, "hints": ["Which equation links v, u, a and t?", "Rearrange v = u + at for a."], "label": "Question 1"}"#),
                   ["page": "page:FIXTUREDOC04/FIXTUREBRD01", "rect": [40, 40, 240, 120]]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try ctx.pageOrSession(p.page)
        guard var frame = Frame(array: p.rect), [frame.x, frame.y, frame.w, frame.h, frame.rotation].allSatisfy(\.isFinite) else {
            throw NibError(.invalidParams, "rect must be [x, y, width, height] in page points", path: "$.rect",
                           hint: "for example [72, 120, 320, 140]")
        }
        guard frame.w >= AnswerZoneLayout.minSide, frame.h >= AnswerZoneLayout.minSide else {
            throw NibError.invalid("an answer zone is at least \(Int(AnswerZoneLayout.minSide)) points wide and tall",
                                   path: "$.rect")
        }
        if let id = p.id, !NibID.isValid(id) {
            throw NibError.invalid("id must be 1 to 64 of [A-Za-z0-9_-]", path: "$.id")
        }
        if let points = p.points, !(points.isFinite && points > 0 && points <= AnswerZone.maxPoints) {
            throw NibError.invalid("points must be more than 0 and at most \(Int(AnswerZone.maxPoints))", path: "$.points")
        }
        let hints = try AnswerZoneRules.hints(p.hints ?? [], path: "$.hints")
        let label = p.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, label.count > AnswerZone.maxLabelLength {
            throw NibError.invalid("label is longer than \(AnswerZone.maxLabelLength) characters", path: "$.label")
        }
        try AnswerZoneRules.checkWritable(doc, ctx)
        let layer = ctx.activeSession?.activeLayer ?? 0
        let zone = AnswerZone(label: (label?.isEmpty ?? true) ? nil : label,
                              points: p.points.map(AnswerZoneRules.rounded), hints: hints)
        let item = try ctx.mutate { tx -> Item in
            guard let record = try tx.content(doc).page(page), !record.deleted else {
                throw NibError.notFound("page \(page.raw)")
            }
            if let size = record.size { frame = AnswerZoneLayout.clamp(frame, to: size) }
            var it = try zone.makeItem(frame: frame, layer: layer)
            if let id = p.id {
                it.id = NibID(id)
                if (try? tx.item(doc, page: page, id: it.id)) != nil {
                    throw NibError(.conflict, "an item with id \(id) already exists on this page", path: "$.id",
                                   hint: "choose another id or leave it out")
                }
            }
            // Below everything else on the page: students write over the zone, and a tap on its empty area still
            // reaches it (tap handlers look at the topmost item).
            it.z = try tx.bottomZ(doc, page: page)
            return try tx.put(it, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, item.id).description)
    }
}

// MARK: - answerZone.score

struct AnswerZoneScore: NibCommand {
    struct Params: Codable {
        var ref: String
        var score: Double
        var points: Double?
        var clear: Bool?
    }

    struct Output: Codable {
        /// The zones whose score or score box changed.
        var refs: [String]
        /// Single-zone calls: the zone's score and maximum after the change (nil = unscored / no score box).
        var score: Double?
        var points: Double?
    }

    static let descriptor = CommandDescriptor(
        id: "answerZone.score", title: String(localized: "Score Answer Zone"),
        summary: "Score an answer zone (a page or doc ref scores all its zones, capped at each zone's points); points? sets the maximum (0 removes the score box); clear? unscores.",
        params: .obj(["ref": .ref,
                      "score": .num("points given, 0 or more; ignored with clear", min: 0, max: AnswerZone.maxPoints),
                      "points": .num("new maximum score; 0 removes the score box", min: 0, max: AnswerZone.maxPoints),
                      "clear": .bool("true removes the score (with points: change only the maximum)")],
                     required: ["ref", "score"]),
        examples: [["ref": "page:FIXTUREDOC01/FIXTUREPG001", "score": 2],
                   ["ref": "doc:FIXTUREDOC01", "score": 0, "clear": true]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.score.isFinite, p.score >= 0 else { throw NibError.invalid("score must be 0 or more", path: "$.score") }
        if let points = p.points, !(points.isFinite && points >= 0 && points <= AnswerZone.maxPoints) {
            throw NibError.invalid("points must be between 0 and \(Int(AnswerZone.maxPoints))", path: "$.points")
        }
        let scope = try AnswerZoneScope.resolve(p.ref, ctx.workspace)
        try AnswerZoneRules.checkWritable(scope.doc, ctx)
        let score = AnswerZoneRules.rounded(p.score)
        let newPoints = p.points.map(AnswerZoneRules.rounded)
        let clear = p.clear ?? false
        let by = ctx.principal.description

        // Work out every zone's new record before writing anything, so a bad single-zone call writes nothing.
        var changes: [(AnswerZoneTarget, AnswerZone)] = []
        for target in scope.targets {
            var zone = target.zone
            if let n = newPoints { zone.points = n > 0 ? n : nil }
            guard let maximum = zone.points else {
                if newPoints == 0 {
                    zone.score = nil
                    zone.scoredAt = nil
                    zone.scoredBy = nil
                    if zone != target.zone { changes.append((target, zone)) }
                    continue
                }
                if scope.kind == .zone {
                    throw NibError(.invalidParams, "this answer zone has no score box", path: "$.points",
                                   hint: "pass points to add one, e.g. {\"ref\": \"\(target.ref)\", \"score\": \(AnswerZoneFormat.number(score)), \"points\": 5}")
                }
                continue
            }
            if clear {
                zone.score = nil
                zone.scoredAt = nil
                zone.scoredBy = nil
            } else {
                if score > maximum && scope.kind == .zone {
                    throw NibError(.invalidParams,
                                   "a score of \(AnswerZoneFormat.number(score)) is more than this zone's \(AnswerZoneFormat.number(maximum)) points",
                                   path: "$.score", hint: "give 0 to \(AnswerZoneFormat.number(maximum)), or pass a larger points")
                }
                zone.score = min(score, maximum)
                zone.scoredAt = AnswerZoneRules.now
                zone.scoredBy = by
            }
            if let s = zone.score, s > maximum { zone.score = maximum }
            if zone != target.zone { changes.append((target, zone)) }
        }

        var written: [AnswerZone] = []
        if !changes.isEmpty {
            try ctx.mutate { (tx: DocTransaction) -> Void in
                for (target, zone) in changes {
                    var item = try tx.item(target.doc, page: target.page, id: target.item.id)
                    try zone.write(to: &item)
                    try tx.put(item, doc: target.doc, page: target.page)
                    written.append(zone)
                }
            }
        }
        let single = scope.kind == .zone ? (written.first ?? scope.targets.first?.zone) : nil
        return Output(refs: changes.map { $0.0.ref }, score: single?.score, points: single?.points)
    }
}

// MARK: - answerZone.setHints

struct AnswerZoneSetHints: NibCommand {
    struct Params: Codable {
        var ref: String
        var hints: [String]
        var resetUsage: Bool?
    }

    struct Output: Codable {
        var refs: [String]
        /// Hints each zone now has.
        var hints: Int
    }

    static let descriptor = CommandDescriptor(
        id: "answerZone.setHints", title: String(localized: "Set Answer Zone Hints"),
        summary: "Set the teacher-approved hints of an answer zone (a page or doc ref sets them on all its zones); resetUsage? forgets which hints were shown.",
        params: .obj(["ref": .ref,
                      "hints": .arr(.str("a teacher-approved hint"), "hints in reveal order, at most 10; [] removes them"),
                      "resetUsage": .bool("true also clears the record of hints already shown")],
                     required: ["ref", "hints"]),
        examples: [["ref": "page:FIXTUREDOC01/FIXTUREPG001", "hints": ["Which formula links v, u, a and t?"]],
                   ["ref": "doc:FIXTUREDOC04", "hints": [], "resetUsage": true]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let hints = try AnswerZoneRules.hints(p.hints, path: "$.hints")
        let scope = try AnswerZoneScope.resolve(p.ref, ctx.workspace)
        try AnswerZoneRules.checkWritable(scope.doc, ctx)
        var changes: [(AnswerZoneTarget, AnswerZone)] = []
        for target in scope.targets {
            var zone = target.zone
            zone.hints = hints
            if p.resetUsage == true {
                zone.revealed = 0
                zone.usage = []
            } else {
                // Edited wording keeps what was shown; a shorter list cannot have shown more than it holds.
                zone.revealed = min(zone.revealed, hints.count)
            }
            if zone != target.zone { changes.append((target, zone)) }
        }
        if !changes.isEmpty {
            try ctx.mutate { (tx: DocTransaction) -> Void in
                for (target, zone) in changes {
                    var item = try tx.item(target.doc, page: target.page, id: target.item.id)
                    try zone.write(to: &item)
                    try tx.put(item, doc: target.doc, page: target.page)
                }
            }
        }
        return Output(refs: changes.map { $0.0.ref }, hints: hints.count)
    }
}

// MARK: - answerZone.revealHint

/// Reveals the next hint of a zone and records who opened it when (`AnswerZone.usage`). The record persists without an
/// undo step (`undoable: false`, like tape reveal), so undo never erases the fact that a hint was used.
///
/// Also the canvas tap handler for the hint widget (`content.tapHandlers`): with `point` the call comes from a finger
/// on the canvas, and only a touch on the zone's hint widget counts (`{"handled": false}` otherwise). A tap reveals the
/// next hint; a long-press only shows the hints already revealed. Either way the window shows the hints card.
struct AnswerZoneRevealHint: NibCommand {
    struct Params: Codable {
        var ref: String?
        var page: String?
        var point: Point?
        var gesture: String?
    }

    struct Output: Codable {
        /// False when no zone with hints was addressed (a tap outside the hint widget, a page without hints).
        var handled: Bool
        var ref: String?
        /// The hint revealed by this call (nil when none was left or the call only showed the card).
        var hint: String?
        /// 1-based number of that hint.
        var number: Int?
        var revealed: Int
        var total: Int
    }

    static let descriptor = CommandDescriptor(
        id: "answerZone.revealHint", title: String(localized: "Show Next Hint"),
        summary: "Reveal the next teacher hint of an answer zone (a page or doc ref: its first zone with hints left); usage is recorded and not undoable.",
        params: .obj(["ref": .ref,
                      "page": .ref,
                      "point": .point,
                      "gesture": .str("canvas tap handlers only", choices: CanvasGesture.allCases.map { $0.rawValue })],
                     required: ["ref"]),
        examples: [["ref": "page:FIXTUREDOC01/FIXTUREPG001"],
                   ["ref": "doc:FIXTUREDOC04"]],
        effect: .edit, undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if let point = p.point { return try await tapped(p, point: point, ctx) }
        guard let ref = p.ref, !ref.isEmpty else { throw NibError.invalid("missing 'ref'", path: "$.ref") }
        let scope = try AnswerZoneScope.resolve(ref, ctx.workspace)
        let target: AnswerZoneTarget?
        switch scope.kind {
        case .zone:
            target = scope.targets.first
        case .page, .document:
            target = scope.targets.first { $0.zone.remainingHints > 0 } ?? scope.targets.first { !$0.zone.hints.isEmpty }
        }
        guard let target else { return Output(handled: false, revealed: 0, total: 0) }
        try AnswerZoneRules.checkWritable(target.doc, ctx)
        return try reveal(target, ctx)
    }

    /// The canvas tap-handler path: `ref` is the topmost item under `point` (the router offers only zones).
    private static func tapped(_ p: Params, point: Point, _ ctx: CommandContext) async throws -> Output {
        let notHandled = Output(handled: false, revealed: 0, total: 0)
        guard let ref = p.ref, case let .item(doc, page, id)? = NodeRef(ref),
              let item = try? ctx.workspace.item(doc, page: page, id: id), let zone = AnswerZone.decode(item),
              !zone.hints.isEmpty else { return notHandled }
        let session = ctx.session ?? ctx.activeSession
        if session?.readOnly == true { return notHandled }
        let zoom = session?.zoom ?? 1
        guard let slot = AnswerZoneLayout.slots(zoneBounds: item.bounds, zoom: zoom, hasScore: zone.points != nil,
                                                hasHints: true).hint,
              AnswerZoneLayout.hitRect(slot, zoom: zoom).contains(point) else { return notHandled }
        let target = AnswerZoneTarget(doc: doc, page: page, item: item, zone: zone)
        var out: Output
        if p.gesture == CanvasGesture.longPress.rawValue {
            out = Output(handled: true, ref: target.ref, revealed: zone.revealed, total: zone.hints.count)
        } else {
            try AnswerZoneRules.checkWritable(doc, ctx)
            out = try reveal(target, ctx)
        }
        if !ctx.dryRun {
            AnswerZoneUI.showHints(session: session, doc: doc, page: page, zone: id, announce: out.hint != nil)
        }
        return out
    }

    /// Reveals the next hint of `target` (nothing when every hint is showing).
    static func reveal(_ target: AnswerZoneTarget, _ ctx: CommandContext) throws -> Output {
        var zone = target.zone
        guard zone.remainingHints > 0 else {
            return Output(handled: true, ref: target.ref, revealed: zone.revealed, total: zone.hints.count)
        }
        let by = ctx.principal.description
        var shown: Int?
        try ctx.mutate(undoable: false) { (tx: DocTransaction) -> Void in
            var item = try tx.item(target.doc, page: target.page, id: target.item.id)
            // Read again inside the transaction: the stored record is the one that counts.
            var current = AnswerZone.decode(item) ?? zone
            guard current.remainingHints > 0 else {
                zone = current
                return
            }
            let index = current.revealed
            current.revealed += 1
            current.usage.append(AnswerZone.HintUse(hint: index, at: AnswerZoneRules.now, by: by))
            try current.write(to: &item)
            try tx.put(item, doc: target.doc, page: target.page)
            zone = current
            shown = index
        }
        return Output(handled: true, ref: target.ref, hint: shown.map { zone.hints[$0] }, number: shown.map { $0 + 1 },
                      revealed: zone.revealed, total: zone.hints.count)
    }
}
