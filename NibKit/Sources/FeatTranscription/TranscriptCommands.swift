import Foundation
import UIKit
import NibContracts
import NibDesign

@MainActor
struct TranscriptGet: NibCommand {
    struct Params: Codable { var clip: String }
    struct Output: Codable {
        var clip: String
        var name: String
        var segments: [TranscriptSegment]
        var summary: String?
        var error: NibError?
    }
    static let descriptor = CommandDescriptor(id: CommandIDs.transcriptGet, title: "Get Transcript",
        summary: "Read merged transcript lines, summary and live transcription status for an audio clip.",
        params: .obj(["clip": .ref], required: ["clip"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01"]], effect: .read)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let store = try TranscriptStore.of(ctx.services)
        let clip = try store.clip(p.clip, workspace: ctx.workspace)
        let lines = try await store.read(clip)
        let live = ctx.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self)
        let preview = live?.previews[p.clip] ?? []
        // A user's correction wins over the uncommitted Speech hypothesis for the same index.
        let merged = TranscriptFiles.merge([preview, lines])
        let warning = await store.files.warning(base: clip.base)
        return Output(clip: p.clip, name: clip.record.name, segments: merged, summary: clip.record.summary,
                      error: live?.errors[p.clip] ?? warning)
    }
}

@MainActor
struct TranscriptEditSegment: NibCommand {
    struct Params: Codable { var clip: String; var index: Int; var text: String }
    static let descriptor = CommandDescriptor(id: CommandIDs.transcriptEditSegment, title: "Edit Transcript Line",
        summary: "Correct one transcript line in this device's sidecar; the edit is not undoable.",
        params: .obj(["clip": .ref, "index": .int(min: 0), "text": .str()], required: ["clip", "index", "text"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "index": 0, "text": "Welcome to the lecture."]],
        effect: .edit, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> TranscriptSegment {
        let store = try TranscriptStore.of(ctx.services)
        let clip = try store.clip(p.clip, workspace: ctx.workspace)
        let lines = try await TranscriptGet.run(.init(clip: p.clip), ctx).segments
        guard var line = lines.first(where: { $0.index == p.index }) else { throw NibError.notFound("transcript line \(p.index)") }
        if let rev = line.rev { ctx.workspace.clock.observe(rev) }
        line.text = p.text
        line.rev = ctx.workspace.clock.tick()
        try await store.persist([line], clip: clip, ctx: ctx)
        return line
    }
}

@MainActor
struct TranscriptRegenerate: NibCommand {
    struct Params: Codable { var clip: String; var engine: String? }
    static let descriptor = CommandDescriptor(id: CommandIDs.transcriptRegenerate, title: "Regenerate Transcript",
        summary: "Replace a transcript using onDevice Speech or cloud AI, according to Recording Settings; not undoable.",
        params: .obj(["clip": .ref, "engine": .str(choices: ["onDevice", "cloud"])], required: ["clip"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "engine": "onDevice"]],
        effect: .edit, destructive: true, undoable: false, sensitive: true)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> TranscriptGet.Output {
        let store = try TranscriptStore.of(ctx.services)
        let clip = try store.clip(p.clip, workspace: ctx.workspace)
        try TranscriptStore.canWrite(clip.doc, ctx: ctx)
        guard let live = ctx.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self) else {
            throw NibError.unavailable("transcription engine")
        }
        guard !live.regenerating.contains(p.clip) else { throw NibError(.conflict, "This transcript is already being regenerated") }
        guard live.jobs[p.clip] == nil else { throw NibError(.conflict, "Stop live transcription before replacing this transcript") }
        live.regenerating.insert(p.clip)
        defer { live.regenerating.remove(p.clip) }
        let engine = p.engine ?? (ctx.services.settings.get(TranscriptSettings.cloud) ? "cloud" : "onDevice")
        guard ["cloud", "onDevice"].contains(engine) else {
            throw NibError(.invalidParams, "Choose onDevice or cloud", path: "$.engine", hint: "call commands.describe for transcript.regenerate")
        }
        let allocated = try await store.files.read(base: clip.base, includingRetired: true, device: store.device)
        let before = allocated.filter { !TranscriptFiles.isRetired($0) }
        if ctx.dryRun { return try await TranscriptGet.run(.init(clip: p.clip), ctx) }
        live.clearError(for: p.clip)
        let language = clip.record.language ?? ctx.services.settings.get(TranscriptSettings.language)
        var lines: [TranscriptSegment]
        if engine == "cloud" {
            guard ctx.services.settings.get(TranscriptSettings.cloud) else {
                throw NibError(.permissionDenied, "Cloud transcription is disabled", hint: "enable Cloud in Recording Settings first")
            }
            let ai = try ctx.services.require(ctx.services.ai, "AI transcription")
            guard ai.isConfigured else { throw NibError.unavailable("an AI provider with an audio endpoint") }
            let duration = try await TranscriptAudioReader.duration(url: clip.audio)
            lines = try await TranscriptAudioReader.cloud(url: clip.audio, from: 0, through: duration, ai: ai, language: language)
        } else {
            lines = try await live.transcribe(clip, language: language)
        }
        try TranscriptFiles.validate(lines)
        try Task.checkCancellation()
        for line in allocated { if let rev = line.rev { ctx.workspace.clock.observe(rev) } }
        lines = lines.enumerated().map { index, line in
            var line = line; line.index = index; line.rev = ctx.workspace.clock.tick(); return line
        }
        // Empty, zero-duration lines retire obsolete indices in the merge without rewriting other devices' files.
        let indices = Set(lines.map(\.index))
        for old in before where !indices.contains(old.index) {
            lines.append(TranscriptSegment(index: old.index, start: old.start, duration: 0, text: "", rev: ctx.workspace.clock.tick()))
        }
        try await store.persist(lines, clip: clip, ctx: ctx, expected: allocated)
        return try await TranscriptGet.run(.init(clip: p.clip), ctx)
    }
}

/// Live Speech output is a private producer, but its writes still have a schema and normal gateway checks.
@MainActor
struct TranscriptAppend: NibCommand {
    struct Params: Codable { var clip: String; var lines: [TranscriptSegment] }
    static let descriptor = CommandDescriptor(id: "transcript.append", title: "Append Transcript Lines",
        summary: "Store recognised lines without replacing existing lines or manual corrections; not undoable.",
        params: .obj(["clip": .ref, "lines": .arr(.obj(["index": .int(min: 0), "start": .num(min: 0),
            "duration": .num(min: 0), "text": .str()], required: ["index", "start", "duration", "text"]))], required: ["clip", "lines"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "lines": []]], effect: .edit, undoable: false)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try TranscriptFiles.validate(p.lines)
        let store = try TranscriptStore.of(ctx.services)
        let clip = try store.clip(p.clip, workspace: ctx.workspace)
        let current = try await store.files.read(base: clip.base, includingRetired: true, device: store.device)
        let existing = Set(current.map(\.index))
        let lines = p.lines.filter { !existing.contains($0.index) }.map { line -> TranscriptSegment in
            var line = line; line.rev = ctx.workspace.clock.tick(); return line
        }
        if !lines.isEmpty { try await store.persist(lines, clip: clip, ctx: ctx) }
        return NoResult()
    }
}

@MainActor
struct TranscriptInsert: NibCommand {
    struct Params: Codable { var clip: String; var segments: [Int]; var page: String; var id: String?; var at: Point? }
    struct Output: Codable { var ref: String }
    static let descriptor = CommandDescriptor(id: CommandIDs.transcriptInsert, title: "Insert Transcript",
        summary: "Insert selected transcript line indices as one text box on a page, optionally at a drop point.",
        params: .obj(["clip": .ref, "segments": .arr(.int(min: 0)), "page": .ref, "id": .str("optional caller-chosen item id, 1–64 letters, digits, hyphens or underscores"), "at": .point],
                     required: ["clip", "segments", "page"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "segments": [0, 1], "page": "page:FIXTUREDOC01/FIXTUREPG001"]],
        effect: .edit)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let node = NodeRef(p.page), case let .page(doc, page) = node else {
            throw NibError(.invalidParams, "Choose a page ref", path: "$.page", hint: "call query.get for a document's pages")
        }
        try TranscriptStore.canWrite(doc, ctx: ctx)
        guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else { throw NibError.notFound("page") }
        let store = try TranscriptStore.of(ctx.services)
        let clip = try store.clip(p.clip, workspace: ctx.workspace)
        if ctx.services.lock?.isLocked(clip.doc) == true { throw NibError(.locked, "Unlock the recording before inserting its transcript") }
        let lines = try await TranscriptGet.run(.init(clip: p.clip), ctx).segments
        let requested = Set(p.segments)
        let selected = lines.filter { requested.contains($0.index) }
        guard !selected.isEmpty, selected.count == requested.count else {
            throw NibError(.invalidParams, "Choose existing transcript line indices", path: "$.segments", hint: "call transcript.get")
        }
        if let id = p.id, !NibID.isValid(id) {
            throw NibError(.invalidParams, "Invalid text box id", path: "$.id", hint: "use 1–64 letters, digits, hyphens or underscores")
        }
        let id = p.id.map { NibID($0) } ?? NibID.make()
        if p.id != nil, try ctx.workspace.allItems(doc, page: page).contains(where: { $0.id == id }) {
            throw NibError(.conflict, "An item already uses this id on this page")
        }
        var point = p.at ?? Point(36, 36)
        guard point.x.isFinite, point.y.isFinite else { throw NibError.invalid("Drop point must be finite", path: "$.at") }
        let size = record.size ?? .a4
        let width = size.width * 0.6
        point.x = min(max(0, point.x), size.width - width)
        point.y = min(max(0, point.y), max(0, size.height - 72))
        let box = TextBoxItem(frame: Frame(x: point.x, y: point.y, w: width, h: 72),
                              text: RichText(plain: selected.map(\.text).joined(separator: "\n\n")))
        try ctx.mutate { tx in _ = try tx.put(Item(id: id, kind: .text, layer: ctx.activeSession?.activeLayer ?? 0, text: box), doc: doc, page: page) }
        return Output(ref: NodeRef.item(doc, page, id).description)
    }
}

@MainActor
struct TranscriptSeek: NibCommand {
    struct Params: Codable { var clip: String; var index: Int?; var t: Double? }
    static let descriptor = CommandDescriptor(id: "transcript.seek", title: "Play Transcript Line",
        summary: "Seek audio to a line's timestamp and reveal the page with the most ink in that time window.",
        params: .obj(["clip": .ref, "index": .int(min: 0), "t": .num(min: 0)], required: ["clip"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "index": 0]], effect: .session)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        let store = try TranscriptStore.of(ctx.services)
        let clip = try store.clip(p.clip, workspace: ctx.workspace)
        let lines = try await TranscriptGet.run(.init(clip: p.clip), ctx).segments
        let line: TranscriptSegment
        if let index = p.index {
            guard let found = lines.first(where: { $0.index == index }) else { throw NibError.notFound("transcript line") }
            line = found
        } else if let t = p.t, t.isFinite, t >= 0, t <= clip.record.duration {
            let end = lines.first { $0.start > t }?.start ?? min(clip.record.duration, t + 10)
            line = TranscriptSegment(start: t, duration: max(0, end - t), text: "")
        } else {
            throw NibError(.invalidParams, "Pass a transcript index or a timestamp in seconds", path: "$.t", hint: "call transcript.get")
        }
        let cached = ctx.workspace.cachedPages(clip.doc)
        var keeping = cached
        defer { ctx.workspace.evictPages(clip.doc, keeping: keeping) }
        let lowerMs = (clip.record.start + line.start) * 1000
        let pages = try ctx.workspace.content(clip.doc).livePages.compactMap { page -> (PageID, [Item])? in
            if let revision = ctx.workspace.contentRevision(clip.doc, page: page.id), Double(revision.wallMs) < lowerMs { return nil }
            return (page.id, try ctx.workspace.items(clip.doc, page: page.id))
        }
        let page = TranscriptPageLink.mostEditedPage(clip: clip.record, segment: line, pages: pages)
        if let page { keeping.insert(page) }
        if !ctx.dryRun {
            _ = try await ctx.execute(CommandIDs.audioPlay, ["clip": .string(p.clip), "t": .number(line.start)])
            if let page {
                let ref = NodeRef.page(clip.doc, page).description
                _ = try await ctx.execute(CommandIDs.viewGoToPage, ["page": .string(ref)])
            }
        }
        return NoResult()
    }
}

@MainActor
protocol TranscriptClipboard: AnyObject { func copy(_ text: String) throws }
@MainActor
final class SystemTranscriptClipboard: TranscriptClipboard {
    func copy(_ text: String) throws {
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("clipboard in hostless tests") }
        UIPasteboard.general.string = text
    }
}

@MainActor
struct TranscriptCopy: NibCommand {
    struct Params: Codable { var clip: String; var index: Int }
    static let descriptor = CommandDescriptor(id: "transcript.copy", title: "Copy Transcript Line",
        summary: "Copy one transcript line as plain text to the system clipboard.",
        params: .obj(["clip": .ref, "index": .int(min: 0)], required: ["clip", "index"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "index": 0]], effect: .read)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        if let doc = NodeRef(p.clip)?.documentID, ctx.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the recording before copying its transcript") }
        let transcript = try await ctx.execute(TranscriptGet.self, .init(clip: p.clip))
        guard let line = transcript.segments.first(where: { $0.index == p.index }) else { throw NibError.notFound("transcript line") }
        if !ctx.dryRun {
            guard let clipboard = ctx.services.get("transcription.clipboard", as: TranscriptClipboard.self) else {
                throw NibError.unavailable("clipboard")
            }
            try clipboard.copy(line.text)
        }
        return NoResult()
    }
}

@MainActor
struct TranscriptLanguages: NibCommand {
    struct Output: Codable { var languages: [TranscriptLanguage]; var authorised: Bool }
    static let descriptor = CommandDescriptor(id: "transcript.languages", title: "Transcription Languages",
        summary: "Read Apple Speech language availability and whether each model works on this device.",
        params: .empty, examples: [[:]], effect: .read, target: .app)
    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> Output {
        guard let live = ctx.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self) else { throw NibError.unavailable("Speech") }
        return Output(languages: try live.speech.languages(), authorised: live.speech.authorised)
    }
}

@MainActor
struct TranscriptAuthorise: NibCommand {
    static let descriptor = CommandDescriptor(id: "transcript.authorise", title: "Enable Speech Recognition",
        summary: "Request Apple Speech access on this device; never prompts from hostless tests.",
        params: .empty, examples: [[:]], effect: .session, target: .app, userPresence: true)
    static func run(_ p: NoResult, _ ctx: CommandContext) async throws -> NoResult {
        guard let live = ctx.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self) else { throw NibError.unavailable("Speech") }
        if !ctx.dryRun { try await live.speech.authorise() }
        return NoResult()
    }
}

@MainActor
struct TranscriptList: NibCommand {
    struct Params: Codable { var doc: String }
    struct Row: Codable, Identifiable { var id: String; var name: String }
    struct Output: Codable { var clips: [Row] }
    static let descriptor = CommandDescriptor(id: "transcript.list", title: "List Transcripts",
        summary: "List audio clip refs and names in a document for the transcript panel.",
        params: .obj(["doc": .ref], required: ["doc"]), examples: [["doc": "doc:FIXTUREDOC01"]], effect: .read)
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        return Output(clips: try ctx.workspace.content(doc).liveAudio.map {
            Row(id: NodeRef.audio(doc, $0.id).description, name: $0.name)
        })
    }
}
