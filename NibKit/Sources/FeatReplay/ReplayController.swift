import Foundation
import UIKit
import Combine
import NibContracts

/// Linkage is intentionally temporal, never based on the recording's initial page or item provenance.
enum ReplayLink {
    static func contains(_ t0: Double, clip: AudioClip) -> Bool {
        !clip.deleted && t0.isFinite && clip.start.isFinite && clip.duration.isFinite && clip.duration >= 0
            && t0 >= clip.start && t0 <= clip.start + clip.duration
    }

    static func clip(for t0: Double, in clips: [AudioClip], preferred: String?, doc: DocumentID) -> AudioClip? {
        let linked = clips.filter { contains(t0, clip: $0) }
        if let preferred, case let .audio(d, id)? = NodeRef(preferred), d == doc,
           let current = linked.first(where: { $0.id == id }) { return current }
        return linked.sorted { ($0.start, $0.id.raw) < ($1.start, $1.id.raw) }.first
    }

    static func seekTime(_ t0: Double, clip: AudioClip) -> Double { max(0, t0 - clip.start - 1) }
}

struct ReplayInk: Equatable {
    var ref: String
    var page: PageID
    var t0: Double
    var bounds: Rect
}

/// Queries retain caller permissions. The fallback is only for builds in which F003 has not registered its API.
/// It uses the real workspace, and disappears from the path as soon as query.get/query.find are available.
@MainActor
enum ReplayReader {
    typealias Query = (String, JSONValue) async throws -> JSONValue

    static func clip(_ ref: String, app: NibApp, query: Query) async throws -> AudioClip {
        guard case let .audio(doc, id)? = NodeRef(ref) else { throw NibError.invalid("Expected an audio ref", path: "$.clip") }
        if app.commands.entry(CommandIDs.queryGet) != nil {
            let json = try await query(CommandIDs.queryGet, ["ref": .string(ref)])
            let clip = try (json["audio"] ?? json).decode(AudioClip.self)
            guard !clip.deleted, clip.id == id else { throw NibError.notFound(ref) }
            return clip
        }
        guard let clip = try app.workspace.content(doc).liveAudio.first(where: { $0.id == id }) else {
            throw NibError.notFound(ref)
        }
        return clip
    }

    static func clips(_ doc: DocumentID, app: NibApp, query: Query) async throws -> [AudioClip] {
        if app.commands.entry(CommandIDs.queryGet) != nil {
            var clips: [AudioClip] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params: JSONValue = ["ref": .string(NodeRef.document(doc).description), "depth": 2]
                if let cursor { params = params.merging(["cursor": .string(cursor)]) }
                let json = try await query(CommandIDs.queryGet, params)
                if json["locked"]?.boolValue == true { throw NibError(.locked, "Unlock the note to replay its handwriting") }
                // Document children share a cursor; clips may not occur until after the pages and outline.
                if let audio = json["audio"] { clips += try audio.decode([AudioClip].self).filter { !$0.deleted } }
                cursor = json["cursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw NibError(.invariantViolation, "The audio query repeated its cursor") }
            } while cursor != nil
            return clips
        }
        return try app.workspace.content(doc).liveAudio
    }

    static func kind(_ doc: DocumentID, app: NibApp, query: Query) async throws -> DocumentKind {
        if app.commands.entry(CommandIDs.queryGet) != nil {
            let json = try await query(CommandIDs.queryGet, ["ref": .string(NodeRef.document(doc).description), "depth": 0])
            if let raw = json["documentKind"]?.stringValue ?? json["meta"]?["kind"]?.stringValue,
               let kind = DocumentKind(rawValue: raw) { return kind }
            throw NibError(.unsupported, "The document query did not return its kind")
        }
        return try app.workspace.content(doc).meta.kind
    }

    static func ink(_ ref: String, app: NibApp, query: Query) async throws -> ReplayInk? {
        guard case let .item(doc, page, id)? = NodeRef(ref) else { throw NibError.invalid("Expected an item ref", path: "$.ref") }
        if app.commands.entry(CommandIDs.queryGet) != nil {
            let json = try await query(CommandIDs.queryGet, ["ref": .string(ref), "fields": ["kind", "stroke", "t0", "bbox", "deleted"]])
            return decodeInk(json, ref: ref, page: page)
        }
        guard let record = try app.workspace.content(doc).page(page), !record.deleted else { throw NibError.notFound(ref) }
        let item = try app.workspace.item(doc, page: page, id: id)
        guard item.kind == .stroke, let stroke = item.stroke else { return nil }
        return ReplayInk(ref: ref, page: page, t0: stroke.t0, bounds: item.bounds)
    }

    static func inks(_ doc: DocumentID, app: NibApp, query: Query) async throws -> [ReplayInk] {
        if app.commands.entry(CommandIDs.queryFind) != nil {
            var out: [ReplayInk] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params: JSONValue = ["in": .string(NodeRef.document(doc).description), "kinds": ["stroke"], "limit": 200]
                if let cursor { params = params.merging(["cursor": .string(cursor)]) }
                let result = try await query(CommandIDs.queryFind, params)
                for json in result["items"]?.arrayValue ?? result["results"]?.arrayValue ?? result.arrayValue ?? [] {
                    guard let ref = json["ref"]?.stringValue, case let .item(d, page, _)? = NodeRef(ref), d == doc else { continue }
                    if let ink = decodeInk(json, ref: ref, page: page) { out.append(ink) }
                    else if let ink = try await ink(ref, app: app, query: query) { out.append(ink) }
                }
                cursor = result["cursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw NibError(.invariantViolation, "The ink query repeated its cursor") }
            } while cursor != nil
            return out
        }
        var out: [ReplayInk] = []
        for page in try app.workspace.content(doc).livePages {
            for item in try app.workspace.items(doc, page: page.id) where item.kind == .stroke {
                guard let stroke = item.stroke else { continue }
                out.append(ReplayInk(ref: NodeRef.item(doc, page.id, item.id).description, page: page.id,
                                     t0: stroke.t0, bounds: item.bounds))
            }
        }
        return out
    }

    private static func decodeInk(_ json: JSONValue, ref: String, page: PageID) -> ReplayInk? {
        guard json["deleted"]?.boolValue != true, json["kind"]?.stringValue == "stroke",
              let t0 = json["stroke"]?["t0"]?.doubleValue ?? json["t0"]?.doubleValue, t0.isFinite else { return nil }
        let values = json["bbox"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        let bounds = values.count == 4 ? Rect(x: values[0], y: values[1], width: values[2], height: values[3]) : .zero
        return ReplayInk(ref: ref, page: page, t0: t0, bounds: bounds)
    }
}

@MainActor
final class ReplayOptions: ObservableObject {
    @Published var mode: ReplayMode = .spotlight
    @Published var followAlong = false
    @Published var fullScreen = false
    @Published var enabled = true
}

/// Decodes only the pinned status fields, without depending on FeatAudio's internal types.
struct ReplayPlayback: Decodable {
    var clip: String?
    var t: Double
    var playing: Bool
    var speed: Double?
}

@MainActor
final class ReplayController: NSObject {
    static let serviceKey = "replay.controller"
    private weak var app: NibApp?
    private var subscription: EventSubscription?
    private var displayLink: CADisplayLink?
    private let target = ReplayDisplayTarget()
    private var polling = false
    private var eventSequence: UInt64 = 0
    private var sample: AudioPlaybackPayload?
    private var loadedClip: AudioClip?
    private var clipRef: String?
    private var optionsBySession: [NibID: ReplayOptions] = [:]
    private var linkedInk: [ReplayInk] = []
    private var linksDirty = true
    private var clipDirty = true
    private var lastFollowed: [NibID: PageID] = [:]
    private var lastTime: Double?
    private var lastPlaying: Bool?
    private var fullScreens: [NibID: ReplayFullScreenController] = [:]

    init(app: NibApp) { self.app = app; super.init(); target.owner = self }

    deinit { subscription?.cancel(); displayLink?.invalidate() }

    static func of(_ services: NibServices) -> ReplayController? { services.get(serviceKey, as: ReplayController.self) }

    func options(for session: EditorSession) -> ReplayOptions {
        if let existing = optionsBySession[session.id] { return existing }
        let options = ReplayOptions()
        optionsBySession[session.id] = options
        return options
    }

    func start() {
        guard subscription == nil, let app else { return }
        subscription = app.events.subscribe { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func receive(_ event: NibEvent) {
        if let payload = event.decode(AudioPlaybackPayload.self) {
            guard event.seq > eventSequence, payload.t.isFinite, payload.at.isFinite, payload.rate.isFinite else { return }
            eventSequence = event.seq
            sample = payload
            if clipRef != payload.clip { linksDirty = true; loadedClip = nil; linkedInk = []; lastFollowed = [:] }
            ensureDisplayLink()
        } else if event.type == NibEventType.committed || event.type == NibEventType.docClosed {
            if event.doc == NodeRef(clipRef ?? "")?.documentID { linksDirty = true; clipDirty = true }
        } else if event.type == NibEventType.sessionDocument || event.type == NibEventType.sessionActivated {
            ensureDisplayLink()
        }
    }

    private func ensureDisplayLink() {
        guard displayLink == nil, !NibApp.isHostlessTest else { return }
        let link = CADisplayLink(target: target, selector: #selector(ReplayDisplayTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func tick() {
        guard !polling else { return }
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    /// The player's live status is authoritative, including silence jumps, paused seeks and clip transitions.
    func refresh() async {
        guard !polling, let app, app.commands.entry(CommandIDs.audioSetPlayback) != nil else { return }
        polling = true
        defer { polling = false }
        do {
            let status = try await app.bus.execute(CommandIDs.audioSetPlayback, [:])
            let playback = try status.decode(ReplayPlayback.self)
            try await apply(playback)
        } catch {
            // Use the typed player sample between successful reads; never advance a paused or unloaded clip.
            if let sample, let loadedClip, sample.clip == clipRef {
                let t = sample.t + (sample.playing ? max(0, Date().timeIntervalSince1970 - sample.at) * max(0, sample.rate) : 0)
                update(time: loadedClip.start + min(max(t, 0), loadedClip.duration))
            }
        }
    }

    func apply(_ playback: ReplayPlayback) async throws {
        guard let app else { return }
        guard let ref = playback.clip, case let .audio(doc, _)? = NodeRef(ref), playback.t.isFinite else {
            clipRef = nil; loadedClip = nil; linkedInk = []; sample = nil; lastTime = nil; lastPlaying = nil
            for session in app.services.sessions.sessions { setReplay(nil, session: session) }
            displayLink?.invalidate(); displayLink = nil
            app.ui.setNeedsChromeUpdate()
            return
        }
        let query: ReplayReader.Query = { [weak app] command, params in
            guard let app else { throw NibError(.unavailable, "Replay is no longer available") }
            return try await app.bus.execute(command, params)
        }
        let chromeChanged = ref != clipRef || lastPlaying != playback.playing
        lastPlaying = playback.playing
        if ref != clipRef || clipDirty || loadedClip == nil {
            loadedClip = try await ReplayReader.clip(ref, app: app, query: query)
            if ref != clipRef { lastFollowed = [:]; linkedInk = []; linksDirty = true }
            clipRef = ref
            clipDirty = false
        }
        if linksDirty, app.services.sessions.sessions.contains(where: { $0.document == doc && options(for: $0).followAlong }) {
            linkedInk = try await ReplayReader.inks(doc, app: app, query: query)
                .filter { ink in loadedClip.map { ReplayLink.contains(ink.t0, clip: $0) } ?? false }
                .sorted { ($0.t0, $0.ref) < ($1.t0, $1.ref) }
            linksDirty = false
        }
        guard let clip = loadedClip else { return }
        update(time: clip.start + min(max(playback.t, 0), clip.duration))
        if playback.playing { ensureDisplayLink() }
        else { displayLink?.invalidate(); displayLink = nil }
        if chromeChanged { app.ui.setNeedsChromeUpdate() }
    }

    private func update(time: Double) {
        lastTime = time
        guard let app, let doc = NodeRef(clipRef ?? "")?.documentID else { return }
        for session in app.services.sessions.sessions {
            let options = options(for: session)
            guard session.document == doc, options.enabled else { setReplay(nil, session: session); continue }
            setReplay(ReplayState(time: time, mode: options.mode), session: session)
            guard options.followAlong, let ink = linkedInk.last(where: { $0.t0 <= time }),
                  lastFollowed[session.id] != ink.page else { continue }
            lastFollowed[session.id] = ink.page
            session.page = ink.page
            session.editor?.reveal(page: ink.page, rect: nil, animated: false)
        }
    }

    private func setReplay(_ state: ReplayState?, session: EditorSession) {
        guard session.replay != state else { return }
        // F006 observes this publisher and coalesces dry-tile redraws until the previous render has landed.
        session.replay = state
    }

    func configure(_ session: EditorSession, mode: ReplayMode, enabled: Bool?, followAlong: Bool?) {
        let options = options(for: session)
        options.mode = mode
        if let enabled { options.enabled = enabled }
        if let followAlong { options.followAlong = followAlong; linksDirty = true; lastFollowed[session.id] = nil }
        if !options.enabled { setReplay(nil, session: session) }
        if let lastTime { update(time: lastTime) }
    }

    func setFullScreen(_ on: Bool, for session: EditorSession, query: ReplayReader.Query) async throws {
        guard let app else { throw NibError(.unavailable, "Replay is no longer available") }
        if !on {
            if let controller = fullScreens.removeValue(forKey: session.id) {
                await withCheckedContinuation { continuation in
                    controller.dismiss(animated: false) { continuation.resume() }
                }
            }
            options(for: session).fullScreen = false
            return
        }
        guard fullScreens[session.id] == nil else { return }
        guard let doc = session.document, let editor = session.editor as? UIViewController else {
            throw NibError(.unavailable, "Open a note before entering full-screen replay", hint: "Call doc.open, then replay.setMode")
        }
        var presenter = editor
        while let parent = presenter.parent { presenter = parent }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard presenter.viewIfLoaded?.window != nil else {
            throw NibError(.unavailable, "Show the note window before entering full-screen replay")
        }
        guard !presenter.isBeingPresented, !presenter.isBeingDismissed, presenter.transitionCoordinator == nil else {
            throw NibError(.conflict, "Wait for the panel to finish opening before entering full-screen replay")
        }
        // A fresh registered canvas shares the document but has its own read-only replay session.
        let kind = try await ReplayReader.kind(doc, app: app, query: query)
        guard let descriptor = app.ui.editors.get(kind.rawValue) else { throw NibError(.unavailable, "The note editor is unavailable") }
        let replaySession = EditorSession()
        replaySession.document = doc; replaySession.page = session.page; replaySession.zoom = session.zoom
        replaySession.hiddenLayers = session.hiddenLayers; replaySession.readOnly = true; replaySession.replay = session.replay
        optionsBySession[replaySession.id] = options(for: session)
        app.services.sessions.add(replaySession)
        app.services.sessions.activate(session)
        let canvas = descriptor.make(doc, replaySession, app)
        let controller = ReplayFullScreenController(canvas: canvas, replaySession: replaySession, source: session,
                                                    app: app, options: options(for: session)) { [weak self, weak app, weak session] in
            app?.services.sessions.remove(replaySession)
            self?.optionsBySession[replaySession.id] = nil
            if let session { self?.options(for: session).fullScreen = false; self?.fullScreens[session.id] = nil }
        }
        fullScreens[session.id] = controller
        options(for: session).fullScreen = true
        await withCheckedContinuation { continuation in
            presenter.present(controller, animated: false) { continuation.resume() }
        }
    }
}

@MainActor
private final class ReplayDisplayTarget: NSObject {
    weak var owner: ReplayController?
    @objc func tick() { owner?.tick() }
}
