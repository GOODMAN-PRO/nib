import Foundation
import NibContracts

struct StudyTheme: Codable, Equatable {
    var card: String = NibPaper.white.rawValue
    var background: String? = nil
}

enum StudyPreferences {
    static let themeKey = "study.theme"
    static let remindersKey = "study.remindersPaused"
    static func validColour(_ name: String) -> Bool {
        if NibPaper(rawValue: name) != nil { return true }
        return RGBA(hex: name)?.a == 255
    }
    static func theme(_ meta: DocumentMeta) -> StudyTheme {
        guard let value = meta.ext?[themeKey], let theme = try? value.decode(StudyTheme.self) else { return StudyTheme() }
        return theme
    }
    // Reminders are opt-in per set, so editing a fresh study set never requests OS permission.
    static func paused(_ meta: DocumentMeta) -> Bool { meta.ext?[remindersKey]?.boolValue ?? true }
}

@MainActor
enum StudyAccess {
    static func content(_ doc: DocumentID, _ ctx: CommandContext, editing: Bool = false) throws -> DocumentContent {
        let content = try ctx.workspace.content(doc)
        guard content.meta.kind == .studySet else {
            throw NibError(.invalidParams, "Choose a study set.", path: "$.doc", hint: "use a doc: reference whose kind is studySet")
        }
        guard ctx.services.lock?.isLocked(doc) != true else { throw NibError(.permissionDenied, "Unlock this study set first.") }
        if editing, ctx.isReadOnly(doc) || (ctx.activeSession?.document == doc && ctx.activeSession?.readOnly == true) {
            throw NibError(.permissionDenied, "This study set is read-only.")
        }
        return content
    }
    static func runtime(_ ctx: CommandContext) throws -> StudyRuntime {
        guard let runtime = ctx.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self) else {
            throw NibError(.unavailable, "Study sessions are not installed.")
        }
        return runtime
    }
}

struct StudyGrade: NibCommand {
    struct Params: Codable { var card: String; var knewIt: Bool; var rating: StudyRating? }
    struct Output: Codable { var srs: SRSState; var nextReview: Double? }
    static let descriptor = CommandDescriptor(id: CommandIDs.studyGrade, title: String(localized: "Grade Card"),
        summary: "Grade a study card; knewIt grows its SM-2 interval, false shortens it; optional rating refines the grade.",
        params: .obj(["card": .ref, "knewIt": .bool(), "rating": .str(choices: StudyRating.allCases.map(\.rawValue))], required: ["card", "knewIt"]),
        examples: [["card": "card:FIXTUREDOC03/FIXTURECRD01", "knewIt": true]], effect: .edit, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .card(doc, id)? = NodeRef(p.card) else {
            throw NibError(.invalidParams, "Use a card reference.", path: "$.card", hint: "pass card:D/C from query.get")
        }
        var content = try StudyAccess.content(doc, ctx, editing: true)
        guard var card = content.liveCards.first(where: { $0.id == id }) else { throw NibError.notFound("study card " + id.raw) }
        let rating = p.rating ?? (p.knewIt ? .good : .again)
        guard rating.knewIt == p.knewIt else {
            throw NibError(.invalidParams, "rating and knewIt disagree.", path: "$.rating", hint: "again and hard require knewIt:false; good and easy require true")
        }
        let runtime = try StudyAccess.runtime(ctx)
        let state = Scheduler.grade(card.srs, rating: rating, now: runtime.now())
        card.srs = state
        try ctx.mutate(undoable: false) { tx in card = try tx.put(card, doc: doc) }
        content.cards = content.cards.map { $0.id == card.id ? card : $0 }
        if !ctx.dryRun {
            runtime.recordGrade(content: content, card: id, rating: rating)
            runtime.enqueue(content)
        }
        return Output(srs: state, nextReview: Scheduler.nextReview(content.cards, now: runtime.now()))
    }
}

struct StudyResetProgress: NibCommand {
    struct Params: Codable { var doc: String }
    static let descriptor = CommandDescriptor(id: CommandIDs.studyResetProgress, title: String(localized: "Reset Progress"),
        summary: "Clear every live card's Smart Learn schedule in a study set; undo restores the previous progress.",
        params: .obj(["doc": .ref], required: ["doc"]), examples: [["doc": "doc:FIXTUREDOC03"]], effect: .edit, destructive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try ctx.documentOrSession(p.doc)
        var content = try StudyAccess.content(doc, ctx, editing: true)
        let cards = content.liveCards.filter { $0.srs != nil }.map { card -> StudyCard in var card = card; card.srs = nil; return card }
        let cleared = try ctx.mutate { tx in try tx.put(cards, doc: doc) }
        let byID = Dictionary(uniqueKeysWithValues: cleared.map { ($0.id, $0) })
        content.cards = content.cards.map { byID[$0.id] ?? $0 }
        if !ctx.dryRun { try StudyAccess.runtime(ctx).enqueue(content) }
        return NoResult()
    }
}

struct StudySetReminders: NibCommand {
    struct Params: Codable { var doc: String; var paused: Bool }
    static let descriptor = CommandDescriptor(id: CommandIDs.studySetReminders, title: String(localized: "Set Review Reminders"),
        summary: "Pause or resume local review notifications for a study set; resuming requires notification authorisation.",
        params: .obj(["doc": .ref, "paused": .bool()], required: ["doc", "paused"]),
        examples: [["doc": "doc:FIXTUREDOC03", "paused": true]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try ctx.documentOrSession(p.doc)
        var content = try StudyAccess.content(doc, ctx, editing: true)
        let runtime = try StudyAccess.runtime(ctx)
        if !ctx.dryRun {
            // Validate before writing the preference. Hostless tests inject a fake through the same protocol.
            if p.paused { try await runtime.reminders.cancel(doc: doc) }
            else { try await runtime.reminders.checkAuthorization() }
            // Re-read after the permission check, which may yield to another command.
            content = try StudyAccess.content(doc, ctx, editing: true)
        }
        var ext = content.meta.ext ?? [:]
        ext[StudyPreferences.remindersKey] = .bool(p.paused)
        content.meta.ext = ext
        try ctx.mutate { tx in try tx.putMeta(content.meta) }
        if !ctx.dryRun { runtime.enqueue(content) }
        return NoResult()
    }
}

struct StudySetTheme: NibCommand {
    struct Params: Codable { var doc: String; var card: String?; var background: String? }
    static let descriptor = CommandDescriptor(id: CommandIDs.studySetTheme, title: String(localized: "Set Study Appearance"),
        summary: "Set a study set's card and desk paper colours in meta.ext study.theme; omitted fields are preserved.",
        params: .obj(["doc": .ref, "card": .str("opaque #RRGGBB colour or paper palette name"),
                      "background": .str("opaque #RRGGBB colour, paper palette name, or desk")], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC03", "card": "ivory", "background": "grey"]], effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let doc = try ctx.documentOrSession(p.doc)
        var content = try StudyAccess.content(doc, ctx, editing: true)
        var theme = StudyPreferences.theme(content.meta)
        if let card = p.card {
            guard StudyPreferences.validColour(card) else { throw NibError.invalid("Unknown card paper colour.", path: "$.card") }
            theme.card = card
        }
        if let background = p.background {
            guard background == "desk" || StudyPreferences.validColour(background) else { throw NibError.invalid("Unknown background paper colour.", path: "$.background") }
            theme.background = background == "desk" ? nil : background
        }
        var ext = content.meta.ext ?? [:]
        ext[StudyPreferences.themeKey] = try JSONValue.from(theme)
        content.meta.ext = ext
        try ctx.mutate { tx in try tx.putMeta(content.meta) }
        return NoResult()
    }
}

struct StudySessionAction: NibCommand {
    static let id = "study.session"
    struct Params: Codable { var doc: String; var action: String; var mode: String?; var language: String?; var instant: Bool?; var rating: StudyRating? }
    struct Output: Codable { var card: String?; var flipped: Bool; var reviewed: Int; var total: Int; var nextReview: Double? }
    static let descriptor = CommandDescriptor(id: id, title: String(localized: "Control Study Session"),
        summary: "Start practice or due-only Smart Learn, flip, move between practice cards, speak the visible side, set speech language, open scratch paper, or end.",
        params: .obj(["doc": .ref, "action": .str(choices: ["start", "flip", "previous", "next", "speak", "stopSpeech", "language", "grade", "scratch", "closeScratch", "end"]),
                      "mode": .str(choices: ["practice", "smartLearn"]), "language": .str(), "instant": .bool(), "rating": .str(choices: StudyRating.allCases.map(\.rawValue))], required: ["doc", "action"]),
        examples: [["doc": "doc:FIXTUREDOC03", "action": "start", "mode": "practice"]], effect: .session)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let content = try StudyAccess.content(doc, ctx)
        guard let app = ctx.app else { throw NibError(.unavailable, "Study sessions need an app host.") }
        let runtime = try StudyAccess.runtime(ctx)
        guard !ctx.dryRun else {
            return Output(card: nil, flipped: false, reviewed: 0, total: 0, nextReview: nil)
        }
        let model: StudySessionModel
        if p.action == "start" {
            guard p.mode == nil || p.mode == "practice" || p.mode == "smartLearn" else {
                throw NibError.invalid("Choose practice or smartLearn.", path: "$.mode")
            }
            model = runtime.model(app: app, doc: doc, session: ctx.activeSession)
        } else if let existing = runtime.existingModel(doc: doc, session: ctx.activeSession) {
            model = existing
        } else {
            return Output(card: nil, flipped: false, reviewed: 0, total: 0, nextReview: nil)
        }
        if !ctx.dryRun {
            model.accept(content)
            if p.action == "grade" {
                guard let rating = p.rating else { throw NibError.invalid("Choose a grade.", path: "$.rating") }
                if model.flipped, let card = model.current {
                    _ = try await ctx.execute(CommandIDs.studyGrade, ["card": .string(NodeRef.card(doc, card.id).description),
                                                                     "knewIt": .bool(rating.knewIt), "rating": .string(rating.rawValue)])
                }
            } else {
                try model.act(p.action, mode: p.mode, language: p.language, instant: p.instant ?? false)
                if p.action == "end" { try StudyAccess.runtime(ctx).release(doc: doc, session: ctx.activeSession) }
            }
        }
        return Output(card: model.current.map { NodeRef.card(doc, $0.id).description }, flipped: model.flipped,
                      reviewed: model.reviewed.count, total: model.queue.count, nextReview: model.nextReview)
    }
}

/// Explicit system permission flow, separate from the scheduler (which never prompts from a grade or background task).
struct StudyRequestReminders: NibCommand {
    static let id = "study.requestReminders"
    struct Params: Codable { var doc: String }
    static let descriptor = CommandDescriptor(id: id, title: String(localized: "Allow Review Reminders"),
        summary: "Ask for local notification permission, then enable review reminders for this study set.",
        params: .obj(["doc": .ref], required: ["doc"]), examples: [["doc": "doc:FIXTUREDOC03"]],
        effect: .session, userPresence: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        _ = try StudyAccess.content(try ctx.documentOrSession(p.doc), ctx, editing: true)
        guard !ctx.dryRun else { return NoResult() }
        try await StudyAccess.runtime(ctx).reminders.requestAuthorization()
        _ = try await ctx.execute(CommandIDs.studySetReminders, ["doc": .string(p.doc), "paused": false])
        return NoResult()
    }
}
