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
    var isTape = false
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
        try checkLock(doc, app: app)
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
        try checkLock(doc, app: app)
        return try app.workspace.content(doc).liveAudio
    }

    static func kind(_ doc: DocumentID, app: NibApp, query: Query) async throws -> DocumentKind {
        if app.commands.entry(CommandIDs.queryGet) != nil {
            let json = try await query(CommandIDs.queryGet, ["ref": .string(NodeRef.document(doc).description), "depth": 0])
            if let raw = json["documentKind"]?.stringValue ?? json["meta"]?["kind"]?.stringValue,
               let kind = DocumentKind(rawValue: raw) { return kind }
            throw NibError(.unsupported, "The document query did not return its kind")
        }
        try checkLock(doc, app: app)
        return try app.workspace.content(doc).meta.kind
    }

    static func ink(_ ref: String, app: NibApp, query: Query) async throws -> ReplayInk? {
        guard case let .item(doc, page, id)? = NodeRef(ref) else { throw NibError.invalid("Expected an item ref", path: "$.ref") }
        if app.commands.entry(CommandIDs.queryGet) != nil {
            let json = try await query(CommandIDs.queryGet, ["ref": .string(ref), "fields": ["kind", "stroke", "bbox", "deleted", "tool"]])
            return decodeInk(json, ref: ref, page: page)
        }
        try checkLock(doc, app: app)
        guard let record = try app.workspace.content(doc).page(page), !record.deleted else { throw NibError.notFound(ref) }
        let item = try app.workspace.item(doc, page: page, id: id)
        guard item.kind == .stroke, let stroke = item.stroke else { return nil }
        return ReplayInk(ref: ref, page: page, t0: stroke.t0, bounds: item.bounds, isTape: stroke.style.tool == .tape)
    }

    static func pages(_ doc: DocumentID, app: NibApp, query: Query) async throws -> [PageID] {
        guard app.commands.entry(CommandIDs.queryGet) != nil else {
            try checkLock(doc, app: app)
            return try app.workspace.content(doc).livePages.map(\.id)
        }
        var pages: [PageID] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: JSONValue = ["ref": .string(NodeRef.document(doc).description), "depth": 1]
            if let cursor { params = params.merging(["cursor": .string(cursor)]) }
            let result = try await query(CommandIDs.queryGet, params)
            if result["locked"]?.boolValue == true { throw NibError(.locked, "Unlock the note to replay its handwriting") }
            for row in result["pages"]?.arrayValue ?? [] where row["deleted"]?.boolValue != true {
                if let ref = row["ref"]?.stringValue, case let .page(d, page)? = NodeRef(ref), d == doc { pages.append(page) }
                else if let id = row["id"]?.stringValue { pages.append(NibID(id)) }
            }
            cursor = result["cursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted { throw NibError(.invariantViolation, "The page query repeated its cursor") }
        } while cursor != nil
        return pages
    }

    static func inks(_ doc: DocumentID, page: PageID, app: NibApp, query: Query) async throws -> [ReplayInk] {
        if app.commands.entry(CommandIDs.queryGet) != nil {
            var out: [ReplayInk] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params: JSONValue = ["ref": .string(NodeRef.page(doc, page).description), "depth": 2,
                                         "fields": ["kind", "stroke", "bbox", "deleted"]]
                if let cursor { params = params.merging(["cursor": .string(cursor)]) }
                let result = try await query(CommandIDs.queryGet, params)
                if result["locked"]?.boolValue == true { throw NibError(.locked, "Unlock the note to replay its handwriting") }
                if result["deleted"]?.boolValue == true { return [] }
                for row in result["items"]?.arrayValue ?? [] {
                    guard let ref = row["ref"]?.stringValue, case let .item(d, pg, _)? = NodeRef(ref), d == doc, pg == page else { continue }
                    if let ink = decodeInk(row, ref: ref, page: page) { out.append(ink) }
                }
                cursor = result["cursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw NibError(.invariantViolation, "The ink query repeated its cursor") }
            } while cursor != nil
            return out
        }
        try checkLock(doc, app: app)
        guard let record = try app.workspace.content(doc).page(page), !record.deleted else { return [] }
        return try app.workspace.items(doc, page: page).compactMap { item in
            guard !item.deleted, item.kind == .stroke, let stroke = item.stroke else { return nil }
            return ReplayInk(ref: NodeRef.item(doc, page, item.id).description, page: page,
                             t0: stroke.t0, bounds: item.bounds, isTape: stroke.style.tool == .tape)
        }
    }

    static func inks(_ doc: DocumentID, app: NibApp, query: Query) async throws -> [ReplayInk] {
        var out: [ReplayInk] = []
        for page in try await pages(doc, app: app, query: query) {
            out += try await inks(doc, page: page, app: app, query: query)
        }
        return out
    }

    static func hit(_ doc: DocumentID, page: PageID, point: Point, app: NibApp, query: Query) async throws -> ReplayInk? {
        guard app.commands.entry(CommandIDs.queryFind) != nil else {
            return try await inks(doc, page: page, app: app, query: query).last { $0.bounds.contains(point) }
        }
        var hit: ReplayInk?
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: JSONValue = ["in": .string(NodeRef.page(doc, page).description), "kinds": ["stroke"],
                                     "bbox": [.number(point.x - 0.5), .number(point.y - 0.5), 1, 1], "limit": 200]
            if let cursor { params = params.merging(["cursor": .string(cursor)]) }
            let result = try await query(CommandIDs.queryFind, params)
            for row in result["items"]?.arrayValue ?? [] {
                guard let ref = row["ref"]?.stringValue, case let .item(d, pg, _)? = NodeRef(ref), d == doc, pg == page else { continue }
                // F003 find summaries have no t0. Resolve only spatial hits, never every stroke in the note.
                if let ink = try await ink(ref, app: app, query: query), ink.bounds.contains(point) { hit = ink }
            }
            cursor = result["cursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted { throw NibError(.invariantViolation, "The hit query repeated its cursor") }
        } while cursor != nil
        return hit
    }

    private static func checkLock(_ doc: DocumentID, app: NibApp) throws {
        if app.services.lock?.isLocked(doc) == true { throw NibError(.locked, "Unlock the note to replay its handwriting") }
    }

    private static func decodeInk(_ json: JSONValue, ref: String, page: PageID) -> ReplayInk? {
        guard json["deleted"]?.boolValue != true, json["kind"]?.stringValue == "stroke",
              let t0 = json["stroke"]?["t0"]?.doubleValue ?? json["t0"]?.doubleValue, t0.isFinite else { return nil }
        let values = json["bbox"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        let bounds = values.count == 4 ? Rect(x: values[0], y: values[1], width: values[2], height: values[3]) : .zero
        return ReplayInk(ref: ref, page: page, t0: t0, bounds: bounds,
                         isTape: (json["tool"]?.stringValue ?? json["stroke"]?["style"]?["tool"]?.stringValue) == "tape")
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
final class ReplayController: NSObject, ObservableObject {
    @Published private(set) var playing = false
    static let serviceKey = "replay.controller"
    private weak var app: NibApp?
    private var subscription: EventSubscription?
    private var displayLink: CADisplayLink?
    private let target = ReplayDisplayTarget()
    private var refreshTask: Task<Void, Never>?
    private var eventSequence: UInt64 = 0
    private var sample: AudioPlaybackPayload?
    private var loadedClip: AudioClip?
    private var clipRef: String?
    private var optionsBySession: [NibID: ReplayOptions] = [:]
    private var linkedInk: [ReplayInk] = []
    private var linksDirty = true
    private var dirtyPages = Set<PageID>()
    private var linksTask: Task<Void, Never>?
    private var lastFollowed: [NibID: PageID] = [:]
    private var lastTime: Double?
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

    func start(resync: Bool = true) {
        guard subscription == nil, let app else { return }
        subscription = app.events.subscribe { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
        if resync { Task { @MainActor [weak self] in await self?.refresh() } }
    }

    func receive(_ event: NibEvent) {
        if let payload = event.decode(AudioPlaybackPayload.self) {
            guard event.seq > eventSequence, payload.t.isFinite, payload.at.isFinite, payload.rate.isFinite,
                  case .audio? = NodeRef(payload.clip) else { return }
            eventSequence = event.seq
            sample = payload
            setPlaying(payload.playing)
            if clipRef != payload.clip {
                clipRef = payload.clip; loadedClip = nil; linkedInk = []; linksDirty = true
                dirtyPages = []; lastFollowed = [:]
                linksTask?.cancel(); linksTask = nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.loadSampleClip() } catch { self.stopDisplayLink() }
                    // Resync once on a clip transition. A missing audio feature still permits typed events.
                    await self.refresh()
                }
            }
            tick()
        } else if event.type == NibEventType.committed, event.doc == NodeRef(clipRef ?? "")?.documentID {
            for ref in event.changes?.all ?? [] {
                if let page = NodeRef(ref)?.pageID { dirtyPages.insert(page) }
            }
            scheduleLinks()
        } else if event.type == NibEventType.docClosed, event.doc == NodeRef(clipRef ?? "")?.documentID {
            clear()
        } else if event.type == NibEventType.sessionDocument || event.type == NibEventType.sessionActivated {
            pruneSessions()
            tick()
        }
    }

    private func setPlaying(_ value: Bool) {
        if playing != value { playing = value; app?.ui.setNeedsChromeUpdate() }
        if value { ensureDisplayLink() } else { stopDisplayLink() }
    }

    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }

    private func ensureDisplayLink() {
        guard sample?.playing == true, displayLink == nil, !NibApp.isHostlessTest else { return }
        let link = CADisplayLink(target: target, selector: #selector(ReplayDisplayTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// The frame path never invokes the bus or waits for linkage reads.
    func tick(now: Double = Date().timeIntervalSince1970) {
        pruneSessions()
        guard let sample, let clip = loadedClip, sample.clip == clipRef else { return }
        let elapsed = sample.playing ? max(0, now - sample.at) * sample.rate : 0
        update(time: clip.start + min(max(sample.t + elapsed, 0), clip.duration))
    }

    /// Explicit resync for startup and replay commands, never a per-frame poll.
    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resyncAudio()
        }
        refreshTask = task
        await refreshTask?.value
        refreshTask = nil
    }

    private func resyncAudio() async {
        guard let app else { return }
        guard app.commands.entry(CommandIDs.audioSetPlayback) != nil else { stopDisplayLink(); return }
        let sequence = eventSequence
        do {
            let status = try await app.bus.execute(CommandIDs.audioSetPlayback, [:])
            let playback = try status.decode(ReplayPlayback.self)
            if sequence == eventSequence { try await apply(playback) }
            else { try await loadSampleClip(); tick() }
            if let linksTask { await linksTask.value }
            else { try await rebuildLinks() }
        } catch {
            if sample == nil || sample?.playing == false { stopDisplayLink() }
            tick()
        }
    }

    func apply(_ playback: ReplayPlayback) async throws {
        guard let ref = playback.clip, case .audio? = NodeRef(ref), playback.t.isFinite else { clear(); return }
        if ref != clipRef {
            clipRef = ref; loadedClip = nil; linkedInk = []; lastFollowed = [:]; dirtyPages = []; linksDirty = true
            linksTask?.cancel(); linksTask = nil
        }
        sample = AudioPlaybackPayload(clip: ref, t: playback.t, playing: playback.playing,
                                      rate: playback.playing ? playback.speed ?? 1 : 0)
        setPlaying(playback.playing)
        try await loadSampleClip(update: false)
        if let sample { tick(now: sample.at) }
    }

    private var query: ReplayReader.Query {
        { [weak app] command, params in
            guard let app else { throw NibError(.unavailable, "Replay is no longer available") }
            return try await app.bus.execute(command, params)
        }
    }

    func loadSampleClip(update: Bool = true) async throws {
        guard let app, let ref = sample?.clip else { return }
        if loadedClip == nil {
            let clip = try await ReplayReader.clip(ref, app: app, query: query)
            guard clipRef == ref else { return }
            loadedClip = clip
        }
        if update { tick() }
        scheduleLinks()
    }

    private func scheduleLinks() {
        guard linksTask == nil, linksDirty || !dirtyPages.isEmpty, loadedClip != nil,
              let app, let doc = NodeRef(clipRef ?? "")?.documentID,
              app.services.sessions.sessions.contains(where: { $0.document == doc && options(for: $0).followAlong }) else { return }
        linksTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.rebuildLinks() } catch { /* Preserve the last usable links until a subsequent resync. */ }
            if !Task.isCancelled { self.linksTask = nil }
        }
    }

    private func rebuildLinks() async throws {
        guard let app, let clip = loadedClip, let ref = clipRef, let doc = NodeRef(ref)?.documentID,
              app.services.sessions.sessions.contains(where: { $0.document == doc && options(for: $0).followAlong }) else { return }
        guard linksDirty || !dirtyPages.isEmpty else { return }
        let all = linksDirty
        let pages = dirtyPages
        linksDirty = false; dirtyPages = []
        do {
            var ink: [ReplayInk] = []
            if all {
                for page in try await ReplayReader.pages(doc, app: app, query: query) {
                    ink += try await ReplayReader.inks(doc, page: page, app: app, query: query)
                        .filter { ReplayLink.contains($0.t0, clip: clip) }
                    await Task.yield()
                }
            } else {
                for page in pages {
                    ink += try await ReplayReader.inks(doc, page: page, app: app, query: query)
                        .filter { ReplayLink.contains($0.t0, clip: clip) }
                }
            }
            guard clipRef == ref, !Task.isCancelled else { return }
            if all { linkedInk = ink }
            else { linkedInk.removeAll { pages.contains($0.page) }; linkedInk += ink }
            linkedInk.sort { ($0.t0, $0.ref) < ($1.t0, $1.ref) }
            tick()
            if !dirtyPages.isEmpty { try await rebuildLinks() }
        } catch {
            if clipRef == ref { linksDirty = linksDirty || all; dirtyPages.formUnion(pages) }
            throw error
        }
    }

    private func clear() {
        sample = nil; clipRef = nil; loadedClip = nil; linkedInk = []; lastTime = nil
        linksTask?.cancel(); linksTask = nil; dirtyPages = []; linksDirty = true
        setPlaying(false); stopDisplayLink()
        guard let app else { return }
        pruneSessions()
        for session in app.services.sessions.sessions { setReplay(nil, session: session) }
        app.ui.setNeedsChromeUpdate()
    }

    private func pruneSessions() {
        guard let app else { return }
        let live = Set(app.services.sessions.sessions.map(\.id))
        for id in Array(fullScreens.keys) where !live.contains(id) {
            fullScreens.removeValue(forKey: id)?.closeSource()
        }
        let remaining = Set(app.services.sessions.sessions.map(\.id))
        optionsBySession = optionsBySession.filter { remaining.contains($0.key) }
        lastFollowed = lastFollowed.filter { remaining.contains($0.key) }
    }

    private func update(time: Double) {
        lastTime = time
        pruneSessions()
        guard let app, let doc = NodeRef(clipRef ?? "")?.documentID else { return }
        // Upper bound keeps follow-along logarithmic, and rewinds to the first page before any stroke.
        var low = 0, high = linkedInk.count
        while low < high {
            let middle = (low + high) / 2
            if linkedInk[middle].t0 <= time { low = middle + 1 } else { high = middle }
        }
        let page = linkedInk.isEmpty ? nil : linkedInk[max(0, low - 1)].page
        for session in app.services.sessions.sessions {
            let options = options(for: session)
            guard session.document == doc, options.enabled else { setReplay(nil, session: session); continue }
            setReplay(ReplayState(time: time, mode: options.mode), session: session)
            guard options.followAlong, let page, lastFollowed[session.id] != page else { continue }
            lastFollowed[session.id] = page
            session.page = page
            session.editor?.reveal(page: page, rect: nil, animated: false)
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
        if let followAlong { options.followAlong = followAlong; lastFollowed[session.id] = nil; scheduleLinks() }
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
