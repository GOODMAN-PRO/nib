import Foundation
import NibContracts

// The audio.* commands (ARCHITECTURE §6.5). Every button in the Audio tab, the recording HUD and the playback bar,
// the toolbar accessory, the menus and the shortcuts runs one of these, so plugins, the AI and the bridge can do the
// same things.

@MainActor
enum AudioRefs {
    /// A document from "doc:D", any ref inside it, or a bare id; `not_found` when it does not exist.
    static func document(_ string: String, _ ctx: CommandContext, path: String = "$.doc") throws -> DocumentID {
        let doc = NodeRef.documentID(from: string)
        guard NibID.isValid(doc.raw) else {
            throw NibError(.invalidParams, "expected a document ref like doc:D", path: path)
        }
        _ = try ctx.workspace.content(doc)
        return doc
    }

    /// A live clip from "audio:D/A" (or a bare clip id in the active window's document).
    static func clip(_ string: String, _ ctx: CommandContext, path: String = "$.clip") throws -> (doc: DocumentID, clip: AudioClip) {
        let doc: DocumentID
        let id: NibID
        if case let .audio(d, a)? = NodeRef(string) {
            doc = d
            id = a
        } else if NibID.isValid(string), let d = ctx.activeSession?.document {
            doc = d
            id = NibID(string)
        } else {
            throw NibError(.invalidParams, "expected an audio clip ref like audio:D/A", path: path,
                           hint: "clip refs are audio:<document id>/<clip id>")
        }
        guard let clip = try ctx.workspace.content(doc).audio.first(where: { $0.id == id && !$0.deleted }) else {
            throw NibError(.notFound, "audio clip \(id) not found in document \(doc)", path: path)
        }
        return (doc, clip)
    }

    /// The clip's audio file inside its document package. Only the canonical place, `audio/<clip id>.<ext>`, is
    /// accepted: `AudioClip.file` is data that plugins, the AI, the bridge and folder sync can set, and play, export
    /// and delete must never reach another file of the package (a page, `doc.<dev>.json`, another clip's audio).
    static func fileURL(_ doc: DocumentID, _ clip: AudioClip, _ ctx: CommandContext) throws -> URL {
        guard isCanonical(clip.file, clip: clip.id) else {
            throw NibError(.invariantViolation, "clip \(clip.id) points at a file that is not its own: \(clip.file)",
                           hint: "a clip's file is audio/\(clip.id.raw).<ext>")
        }
        return try ctx.workspace.persistence.fileURL(doc, relativePath: clip.file)
    }

    /// `audio/<clip id>.<ext>`, nothing else (no sub-folders, no other clip's name, no "..").
    static func isCanonical(_ file: String, clip: NibID) -> Bool {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "audio" else { return false }
        let name = parts[1]
        let prefix = clip.raw + "."
        guard name.hasPrefix(prefix), name.count > prefix.count else { return false }
        let ext = name.dropFirst(prefix.count)
        return !ext.contains("/") && !ext.contains("\\") && ext != "." && ext != ".."
    }

    /// Where a recording is written while it runs: `audio/<clip id>.aac` (AAC in ADTS, crash-safe).
    static func liveURL(_ doc: DocumentID, _ clip: NibID, _ ctx: CommandContext) throws -> URL {
        try ctx.workspace.persistence.fileURL(doc, relativePath: "audio/\(clip.raw).aac")
    }

    /// The clip a `MenuLocation.audioClip` menu is for.
    static func menuClip(_ ctx: MenuContext) -> (doc: DocumentID, clip: AudioClip)? {
        guard let ref = ctx.ref, case let .audio(doc, id)? = NodeRef(ref),
              let clip = (try? ctx.app.workspace.content(doc))?.liveAudio.first(where: { $0.id == id }) else { return nil }
        return (doc, clip)
    }
}

// MARK: - audio.record

struct AudioRecord: NibCommand {
    enum Action: String, CaseIterable {
        case start, stop, pause, resume, toggle
    }

    struct Params: Codable {
        var doc: String?
        var page: String?
        var action: String
        var id: String?
    }

    struct Output: Codable {
        var ref: String?
        var doc: String?
        /// "recording", "paused" or "stopped".
        var state: String
        var duration: Double
    }

    static let descriptor = CommandDescriptor(
        id: "audio.record", title: "Record Audio",
        summary: "Start, pause, resume or stop the app-wide microphone recording into a document ('toggle' starts or stops); returns the clip ref.",
        params: .obj(["doc": .ref,
                      "page": .str("page:D/P where the recording starts (default: the page on screen)"),
                      "action": .str("start | stop | pause | resume | toggle", choices: Action.allCases.map { $0.rawValue }),
                      "id": .str("your own id for the new clip, [A-Za-z0-9_-]{1,64}")],
                     required: ["doc", "action"]),
        examples: [["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG001", "action": "start"],
                   ["doc": "doc:FIXTUREDOC01", "action": "stop"]],
        effect: .edit, userPresence: true, undoable: false, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let audio = try AudioController.require(ctx.services)
        guard let action = Action(rawValue: p.action.lowercased()) else {
            throw NibError(.invalidParams, "action must be start, stop, pause, resume or toggle", path: "$.action")
        }
        var doc: DocumentID?
        if let raw = p.doc, !raw.isEmpty { doc = try AudioRefs.document(raw, ctx) }
        switch action {
        case .start:
            return try await start(p, doc: doc ?? ctx.activeSession?.document, ctx, audio)
        case .stop:
            return try await stop(doc, ctx, audio)
        case .toggle:
            if let r = audio.recording {
                try requireSame(doc, r)
                return try await stop(r.doc, ctx, audio)
            }
            return try await start(p, doc: doc ?? ctx.activeSession?.document, ctx, audio)
        case .pause:
            guard let r = audio.recording else { throw AudioController.notRecording }
            try requireSame(doc, r)
            if !ctx.dryRun { try audio.pauseRecording() }
            return status(audio)
        case .resume:
            guard let r = audio.recording else { throw AudioController.notRecording }
            try requireSame(doc, r)
            if ctx.dryRun || r.pausedAt == nil { return status(audio) }
            if audio.resumeStartsANewClip {
                // A long break: the clip ends where it was paused and the recording carries on in a new clip that
                // starts now, so Note Replay stays aligned and no silence is encoded for the break.
                _ = try await stop(r.doc, ctx, audio)
                let next = Params(doc: NodeRef.document(r.doc).description,
                                  page: r.page.map { NodeRef.page(r.doc, $0).description }, action: "start", id: nil)
                return try await start(next, doc: r.doc, ctx, audio)
            }
            try audio.resumeRecording()
            return status(audio)
        }
    }

    static func status(_ audio: AudioController) -> Output {
        guard let s = audio.recordingStatus else { return Output(ref: nil, doc: nil, state: "stopped", duration: 0) }
        return Output(ref: s.clip, doc: s.doc, state: s.state, duration: s.duration)
    }

    /// Opens the microphone, then creates the clip record (not undoable: a recording is captured media, and Delete is
    /// the way to remove it). While recording the audio goes to `audio/<clip>.aac`; stop turns it into the record's
    /// file, `audio/<clip>.caf`.
    private static func start(_ p: Params, doc: DocumentID?, _ ctx: CommandContext,
                              _ audio: AudioController) async throws -> Output {
        guard let doc else {
            throw NibError(.invalidParams, "no document to record into", path: "$.doc",
                           hint: "pass {\"doc\": \"doc:D\", \"action\": \"start\"}")
        }
        if let r = audio.recording {
            if r.doc == doc { return status(audio) }
            throw NibError(.conflict, "Nib is already recording in another document", hint: audio.stopHint())
        }
        let content = try ctx.workspace.content(doc)
        guard AudioIndicators.docKinds.contains(content.meta.kind) else {
            throw NibError(.unsupported, "study sets can't hold recordings", path: "$.doc",
                           hint: "record into a notebook, whiteboard or text document")
        }
        let page = try startPage(p.page, doc: doc, content: content, ctx)
        let clipID = try newClipID(p.id, content)
        let file = "audio/\(clipID.raw).caf"
        let ref = NodeRef.audio(doc, clipID).description
        if ctx.dryRun { return Output(ref: ref, doc: NodeRef.document(doc).description, state: "recording", duration: 0) }
        let live = try AudioRefs.liveURL(doc, clipID, ctx)
        let started = try await audio.startRecording(doc: doc, page: page, clip: clipID, url: live)
        let name = String(localized: "Recording \(content.liveAudio.count + 1)")
        do {
            try ctx.mutate(undoable: false) { tx in
                var clip = AudioClip(id: clipID, name: name, file: file, start: started, duration: 0, page: page)
                clip.transcriptFile = "audio/\(clipID.raw).transcript"
                try tx.put(clip, doc: doc)
            }
        } catch {
            await audio.abortRecording()
            throw error
        }
        return status(audio)
    }

    /// Stops, turns the live file into the clip's file (off the main actor) and finalises the clip's duration. With
    /// nothing recording it finishes clips a crash left at zero length.
    private static func stop(_ doc: DocumentID?, _ ctx: CommandContext, _ audio: AudioController) async throws -> Output {
        guard let r = audio.recording else {
            if let doc, !ctx.dryRun { try await recover(doc, ctx, audio) }
            return Output(ref: nil, doc: doc.map { NodeRef.document($0).description }, state: "stopped", duration: 0)
        }
        try requireSame(doc, r)
        let ref = NodeRef.audio(r.doc, r.clip).description
        let docRef = NodeRef.document(r.doc).description
        if ctx.dryRun { return Output(ref: ref, doc: docRef, state: "stopped", duration: audio.elapsed) }
        let live = try AudioRefs.liveURL(r.doc, r.clip, ctx)
        let target = try ctx.workspace.persistence.fileURL(r.doc, relativePath: "audio/\(r.clip.raw).caf")
        guard let finished = await audio.finishRecording() else { throw AudioController.notRecording }
        let duration = finished.result.duration
        let workspace = ctx.workspace
        let saved = await audio.save(r, frames: finished.result.frames, live: live, target: target) {
            (try? workspace.content(r.doc))?.audio.first(where: { $0.id == r.clip })?.deleted ?? false
        }
        if saved { try finalise(r.doc, [(r.clip, duration)], ctx) }
        return Output(ref: ref, doc: docRef, state: "stopped", duration: duration)
    }

    private static func finalise(_ doc: DocumentID, _ lengths: [(NibID, Double)], _ ctx: CommandContext) throws {
        try ctx.mutate(undoable: false) { tx in
            let clips = try tx.content(doc).audio
            for (id, duration) in lengths {
                guard var clip = clips.first(where: { $0.id == id }), !clip.deleted else { continue }
                clip.duration = duration
                try tx.put(clip, doc: doc)
            }
        }
    }

    /// S-057: a crash keeps what was recorded. A clip left at zero length is finished from its live file (or its
    /// length is read back from its file), off the main actor.
    private static func recover(_ doc: DocumentID, _ ctx: CommandContext, _ audio: AudioController) async throws {
        var found: [(NibID, Double)] = []
        for clip in try ctx.workspace.content(doc).liveAudio where clip.duration <= 0 {
            guard !(audio.recording?.doc == doc && audio.recording?.clip == clip.id), !audio.isFinalising(doc, clip.id),
                  let target = try? AudioRefs.fileURL(doc, clip, ctx),
                  let live = try? AudioRefs.liveURL(doc, clip.id, ctx) else { continue }
            let ours = LiveRecordings.contains(doc: doc, clip: clip.id)
            audio.finalising.insert(AudioController.key(doc, clip.id))
            let length = await Task.detached(priority: .utility) {
                AudioFiles.recover(live: live, into: target, ours: ours)
            }.value
            audio.doneFinalising(doc, clip.id)
            if let length, length > 0 {
                found.append((clip.id, length))
                LiveRecordings.remove(doc: doc, clip: clip.id)
            }
        }
        if !found.isEmpty { try finalise(doc, found, ctx) }
    }

    private static func requireSame(_ doc: DocumentID?, _ r: AudioController.Recording) throws {
        guard let doc, doc != r.doc else { return }
        throw NibError(.conflict, "the recording is in another document", path: "$.doc",
                       hint: "pass \"doc\": \"\(NodeRef.document(r.doc))\"")
    }

    private static func startPage(_ raw: String?, doc: DocumentID, content: DocumentContent,
                                  _ ctx: CommandContext) throws -> PageID? {
        if let raw, !raw.isEmpty {
            let id = NodeRef(raw)?.pageID ?? NibID(raw)
            guard let record = content.page(id), !record.deleted else {
                throw NibError(.notFound, "page \(id) not found in document \(doc)", path: "$.page")
            }
            return record.id
        }
        if let s = ctx.activeSession, s.document == doc, let page = s.page, content.page(page)?.deleted == false {
            return page
        }
        return content.livePages.first?.id
    }

    private static func newClipID(_ raw: String?, _ content: DocumentContent) throws -> NibID {
        guard let raw else { return NibID.make() }
        guard NibID.isValid(raw) else { throw NibError(.invalidParams, "id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        guard !content.audio.contains(where: { $0.id.raw == raw }) else {
            throw NibError(.conflict, "a clip with id \(raw) already exists", path: "$.id")
        }
        return NibID(raw)
    }
}

// MARK: - Playback

struct AudioPlay: NibCommand {
    struct Params: Codable {
        /// Required in the schema; a user call without it plays the loaded clip, else the window's first clip.
        var clip: String?
        var t: Double?
        var toggle: Bool?
    }

    typealias Output = PlaybackStatus

    static let descriptor = CommandDescriptor(
        id: "audio.play", title: "Play Audio",
        summary: "Play an audio clip from t seconds (default: where it was paused); the document's later clips follow. toggle: pause it if it is playing.",
        params: .obj(["clip": .ref, "t": .num("seconds from the clip start", min: 0),
                      "toggle": .bool("pause instead when this clip is already playing")], required: ["clip"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 12]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let audio = try AudioController.require(ctx.services)
        if let t = p.t, !(t >= 0 && t.isFinite) {
            throw NibError(.invalidParams, "t must be 0 or more seconds", path: "$.t")
        }
        let (doc, clip) = try resolve(p.clip, ctx, audio)
        let url = try AudioRefs.fileURL(doc, clip, ctx)
        if audio.recording?.doc == doc && audio.recording?.clip == clip.id {
            throw NibError(.conflict, "this clip is still recording", path: "$.clip", hint: audio.stopHint())
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if audio.isFinalising(doc, clip.id) {
                throw NibError(.conflict, "'\(clip.name)' is still being saved", path: "$.clip",
                               hint: "try again in a moment")
            }
            throw NibError(.notFound, "the audio of '\(clip.name)' is not on this device yet", path: "$.clip",
                           hint: "wait for the library to finish syncing, then try again")
        }
        if p.toggle == true, let loaded = audio.playback, loaded.isPlaying, loaded.doc == doc, loaded.clip == clip.id {
            if !ctx.dryRun { audio.pausePlayback() }
            return audio.status
        }
        if ctx.dryRun { return audio.status }
        try audio.play(doc: doc, clip: clip, url: url, at: p.t)
        return audio.status
    }

    /// The named clip; without one, the loaded clip, else the first clip of the window's document that has audio.
    private static func resolve(_ raw: String?, _ ctx: CommandContext,
                                _ audio: AudioController) throws -> (doc: DocumentID, clip: AudioClip) {
        if let raw, !raw.isEmpty { return try AudioRefs.clip(raw, ctx) }
        if let p = audio.playback, let clip = audio.playableClips(p.doc).first(where: { $0.id == p.clip }) {
            return (p.doc, clip)
        }
        if let doc = ctx.activeSession?.document, let clip = audio.playableClips(doc).first(where: { $0.duration > 0 }) {
            return (doc, clip)
        }
        throw NibError(.invalidParams, "no clip to play", path: "$.clip", hint: "pass a clip ref like audio:D/A")
    }
}

struct AudioPause: NibCommand {
    struct Params: Codable {
        var close: Bool?
    }

    typealias Output = PlaybackStatus

    static let descriptor = CommandDescriptor(
        id: "audio.pause", title: "Pause Audio",
        summary: "Pause audio playback; audio.play on the same clip without t carries on from here. close: also unload the clip (hides the playback bar).",
        params: .obj(["close": .bool("also unload the clip, which hides the playback bar")]),
        examples: [[:], ["close": true]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let audio = try AudioController.require(ctx.services)
        if !ctx.dryRun {
            if p.close == true {
                audio.stopPlayback()
            } else {
                audio.pausePlayback()
            }
        }
        return audio.status
    }
}

struct AudioSeek: NibCommand {
    struct Params: Codable {
        var t: Double
    }

    typealias Output = PlaybackStatus

    static let descriptor = CommandDescriptor(
        id: "audio.seek", title: "Seek Audio",
        summary: "Move the loaded clip's playhead to t seconds from its start; it keeps playing if it was.",
        params: .obj(["t": .num("seconds from the clip start", min: 0)], required: ["t"]),
        examples: [["t": 30]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let audio = try AudioController.require(ctx.services)
        guard p.t >= 0, p.t.isFinite else { throw NibError(.invalidParams, "t must be 0 or more seconds", path: "$.t") }
        // Nothing loaded throws not_found with a hint, in a dry run too.
        if audio.playback == nil || !ctx.dryRun { try audio.seek(to: p.t) }
        return audio.status
    }
}

struct AudioSetPlayback: NibCommand {
    struct Params: Codable {
        var speed: Double?
        var skipSilence: Bool?
        var noiseReduction: Bool?
    }

    typealias Output = PlaybackStatus

    static let descriptor = CommandDescriptor(
        id: "audio.setPlayback", title: "Playback Options",
        summary: "Set audio playback speed (0.5–2×), skip silence and noise reduction; with no params it reads the playback state and the recording, if any.",
        params: .obj(["speed": .num("playback rate, 0.5 to 2", min: AudioSettings.minimumSpeed, max: AudioSettings.maximumSpeed),
                      "skipSilence": .bool("skip silent stretches"),
                      "noiseReduction": .bool("high-pass filter and noise gate")]),
        examples: [["speed": 1.5, "skipSilence": true, "noiseReduction": false], [:]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let audio = try AudioController.require(ctx.services)
        if let s = p.speed, !(s.isFinite && (AudioSettings.minimumSpeed...AudioSettings.maximumSpeed).contains(s)) {
            throw NibError(.invalidParams, "speed must be between 0.5 and 2", path: "$.speed")
        }
        if ctx.dryRun { return audio.status }
        let settings = ctx.services.settings
        if let s = p.speed { settings.set(AudioSettings.speed, s) }
        if let v = p.skipSilence { settings.set(AudioSettings.skipSilence, v) }
        if let v = p.noiseReduction { settings.set(AudioSettings.noiseReduction, v) }
        try audio.applyPlaybackSettings()
        return audio.status
    }
}

// MARK: - Clip management

struct AudioRename: NibCommand {
    struct Params: Codable {
        var clip: String
        var name: String
    }

    struct Output: Codable {
        var ref: String
        var name: String
    }

    static let descriptor = CommandDescriptor(
        id: "audio.rename", title: "Rename Recording",
        summary: "Rename an audio clip.",
        params: .obj(["clip": .ref, "name": .str("the new name, 1–200 characters")], required: ["clip", "name"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "name": "Lecture 3: Kinematics"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, clip) = try AudioRefs.clip(p.clip, ctx)
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else {
            throw NibError(.invalidParams, "the name must be 1–200 characters", path: "$.name")
        }
        if name != clip.name {
            try ctx.mutate { tx in
                var renamed = clip
                renamed.name = name
                try tx.put(renamed, doc: doc)
            }
        }
        return Output(ref: NodeRef.audio(doc, clip.id).description, name: name)
    }
}

struct AudioDelete: NibCommand {
    struct Params: Codable {
        var clip: String
    }

    struct Output: Codable {
        var ref: String
        var deleted: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "audio.delete", title: "Delete Recording",
        summary: "Permanently delete an audio clip and its audio file (cannot be undone).",
        params: .obj(["clip": .ref], required: ["clip"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01"]],
        effect: .irreversible)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, clip) = try AudioRefs.clip(p.clip, ctx)
        let audio = AudioController.of(ctx.services)
        // A record whose file is not its own (`audio/<clip id>.<ext>`) is tombstoned and no file is touched.
        let url: URL?
        do {
            url = try AudioRefs.fileURL(doc, clip, ctx)
        } catch let error as NibError where error.code == .invariantViolation {
            url = nil
        }
        if !ctx.dryRun, let audio {
            if audio.recording?.doc == doc && audio.recording?.clip == clip.id {
                _ = await audio.finishRecording()
                audio.doneFinalising(doc, clip.id)
            }
            audio.stopPlayback(doc: doc, clip: clip.id)
        }
        // Not on the undo stack: the file is gone, so an undo could only bring back an empty record.
        try ctx.mutate(undoable: false) { tx in
            var gone = clip
            gone.deleted = true
            try tx.put(gone, doc: doc)
        }
        if !ctx.dryRun {
            if let url { removeFiles(url, clip) }
            LiveRecordings.remove(doc: doc, clip: clip.id)
            audio?.forgetSilence(doc: doc, clip: clip.id)
        }
        return Output(ref: NodeRef.audio(doc, clip.id).description, deleted: true)
    }

    /// The audio file and the clip's side files next to it in `audio/` ("<clip id>.*": the live recording and
    /// transcripts from every device). `url` is the canonical `audio/<clip id>.<ext>`.
    private static func removeFiles(_ url: URL, _ clip: AudioClip) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        let prefix = clip.id.raw + "."
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

struct AudioExport: NibCommand {
    struct Params: Codable {
        var clip: String
        var format: String?
    }

    struct Output: Codable {
        /// "tmp:<name>", accepted by every url-taking command; `asset.get`-style temporary asset (1 h).
        var url: String
        var name: String
        var ext: String
        var bytes: Int
        var duration: Double
    }

    static let descriptor = CommandDescriptor(
        id: "audio.export", title: "Export Audio",
        summary: "Export an audio clip as an audio file (m4a by default, or the original caf); returns a temporary tmp: url.",
        params: .obj(["clip": .ref,
                      "format": .str("m4a (default) or caf", choices: AudioExportFormat.allCases.map { $0.rawValue })],
                     required: ["clip"]),
        examples: [["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "format": "m4a"]],
        effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, clip) = try AudioRefs.clip(p.clip, ctx)
        if ctx.services.lock?.isLocked(doc) == true {
            throw NibError(.locked, "document \(doc) is locked", hint: "unlock it before exporting its audio")
        }
        guard let format = AudioExportFormat(rawValue: (p.format ?? "m4a").lowercased()) else {
            throw NibError(.invalidParams, "format must be m4a or caf", path: "$.format")
        }
        let source = try AudioRefs.fileURL(doc, clip, ctx)
        if let audio = AudioController.of(ctx.services) {
            if audio.recording?.doc == doc && audio.recording?.clip == clip.id {
                throw NibError(.conflict, "this clip is still recording", path: "$.clip", hint: audio.stopHint())
            }
            if audio.isFinalising(doc, clip.id) {
                throw NibError(.conflict, "'\(clip.name)' is still being saved", path: "$.clip", hint: "try again in a moment")
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NibError(.notFound, "the audio of '\(clip.name)' is not on this device yet", path: "$.clip",
                           hint: "wait for the library to finish syncing, then try again")
        }
        let store = try ctx.services.require(ctx.services.assets, "the asset store")
        let known = clip.duration
        // Copying a lecture's packets still reads and writes megabytes: off the main actor (AssetStore is thread-safe).
        let (tmp, bytes, length) = try await Task.detached(priority: .userInitiated) { () throws -> (String, Int, Double) in
            let data = try AudioFiles.exportData(source, format: format)
            let length = known > 0 ? known : (AudioFiles.duration(of: source) ?? 0)
            let ref = try store.putTemporary(data, ext: format.rawValue)
            return (ref.name, data.count, length)
        }.value
        return Output(url: "tmp:" + tmp, name: clip.name, ext: format.rawValue, bytes: bytes, duration: length)
    }
}

// MARK: - Quick Record (D-120)

struct AudioQuickRecord: NibCommand {
    struct Params: Codable {
        var id: String?
    }

    struct Output: Codable {
        /// The new document.
        var ref: String
        /// The clip being recorded (nil in a dry run).
        var clip: String?
    }

    static let descriptor = CommandDescriptor(
        id: "audio.quickRecord", title: "Quick Record",
        summary: "Create a new text document, open it and start recording into it straight away; returns the document ref.",
        params: .obj(["id": .str("your own id for the new document, [A-Za-z0-9_-]{1,64}")]),
        examples: [[:]], effect: .library, target: .library)

    /// The library command that moves a document to the Trash (F002).
    static let libraryTrash = "library.trash"

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if let id = p.id, !NibID.isValid(id) {
            throw NibError(.invalidParams, "id must be 1–64 of [A-Za-z0-9_-]", path: "$.id")
        }
        let audio = try AudioController.require(ctx.services)
        // No empty "Recording …" document when the microphone is off.
        try audio.checkMicrophone()
        let doc = p.id.map { NibID($0) } ?? NibID.make()
        let now = audio.clock()
        _ = try await ctx.execute(CommandIDs.docCreate, ["kind": "textDocument", "title": .string(title(for: now)),
                                                         "id": .string(doc.raw)])
        let ref = NodeRef.document(doc).description
        if ctx.dryRun { return Output(ref: ref, clip: nil) }
        // No window (the bridge, a background caller): record anyway, the document is in the library.
        _ = try? await ctx.execute(CommandIDs.docOpen, ["doc": .string(ref)])
        let recording: JSONValue
        do {
            recording = try await ctx.execute("audio.record", ["doc": .string(ref), "action": "start"])
        } catch {
            // The microphone was busy or refused: the new document goes to the Trash (recoverable) rather than
            // staying in the library empty.
            _ = try? await ctx.execute(libraryTrash, ["refs": [.string(ref)]])
            throw error
        }
        return Output(ref: ref, clip: recording["ref"]?.stringValue)
    }

    /// "Recording 25 Sep 2026 at 10.41": a document title is a file name, so no colon.
    static func title(for time: Double) -> String {
        let date = Date(timeIntervalSince1970: time)
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        let clock = date.formatted(.dateTime.hour().minute()).replacingOccurrences(of: ":", with: ".")
        return String(localized: "Recording \(day) at \(clock)")
    }
}
