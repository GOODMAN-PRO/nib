import Foundation

/// A typed event payload (contracts-v2). Emit with `events.emit(payload)`; read with `event.decode(P.self)`. Payloads
/// travel as JSON (`NibEvent.payload`), so plugins, the bridge and the AI see the same fields.
public protocol NibEventPayload: Codable {
    /// The `NibEventType` this payload belongs to.
    static var eventType: String { get }
}

public extension EventBus {
    /// Emits `payload` under its `eventType`.
    @discardableResult
    func emit<P: NibEventPayload>(_ payload: P, principal: Principal? = nil, doc: DocumentID? = nil) -> NibEvent {
        emit(P.eventType, principal: principal, doc: doc, payload: try? JSONValue.from(payload))
    }
}

public extension NibEvent {
    /// The payload as `P`, or nil when the event is of another type or its payload does not decode.
    func decode<P: NibEventPayload>(_ type: P.Type) -> P? {
        guard self.type == P.eventType, let p = payload else { return nil }
        return try? p.decode(P.self)
    }
}

/// `sync.status`: storage, folder sync (F025), backup (F068) or WebDAV (F069) state for the Cloud & Backup UI (F070).
/// `state` is "idle" | "syncing" | "ok" | "warning" | "error"; `source` names the emitter ("store", "sync", "backup",
/// "webdav"); `reason` is a stable code (store: "newerFormat", "futureRevision", "unreadable", "writeFailed",
/// "walFailed"). `NibEvent.doc` carries the document when there is one.
public struct SyncStatusPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.syncStatus
    public var state: String
    public var source: String
    public var reason: String?
    public var message: String?
    /// Affected files (package-relative paths).
    public var files: [String]?

    public init(state: String, source: String, reason: String? = nil, message: String? = nil, files: [String]? = nil) {
        self.state = state
        self.source = source
        self.reason = reason
        self.message = message
        self.files = files
    }
}

/// `index.progress` (NibIndex F055): pages indexed so far in the current sweep.
public struct IndexProgressPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.indexProgress
    public var running: Bool
    public var done: Int
    public var total: Int
    public var pending: Int

    public init(running: Bool, done: Int, total: Int, pending: Int? = nil) {
        self.running = running
        self.done = done
        self.total = total
        self.pending = pending ?? max(0, total - done)
    }
}

/// `laser.moved` (F040 → presentation F063, collaboration F108). `page` is a page ref, so the payload can be passed
/// straight back to `laser.point`; no `point` = the laser was lifted.
public struct LaserMovedPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.laserMoved
    public var page: String
    public var point: Point?
    /// "dot" | "trail".
    public var mode: String
    public var color: RGBA?
    /// `EditorSession.id` of the window the laser is in.
    public var session: String?

    public init(page: String, point: Point?, mode: String, color: RGBA? = nil, session: String? = nil) {
        self.page = page
        self.point = point
        self.mode = mode
        self.color = color
        self.session = session
    }
}

/// `audio.playback` (F052 → Note Replay F053): emitted on play, pause, seek and re-plan.
public struct AudioPlaybackPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.audioPlayback
    /// Clip ref "audio:D/A".
    public var clip: String
    /// Position in the clip (seconds).
    public var t: Double
    public var playing: Bool
    /// Playback speed (0 while paused).
    public var rate: Double
    /// Wall clock of the sample (unix seconds), to extrapolate `t` between events.
    public var at: Double

    public init(clip: String, t: Double, playing: Bool, rate: Double, at: Double = Date().timeIntervalSince1970) {
        self.clip = clip
        self.t = t
        self.playing = playing
        self.rate = rate
        self.at = at
    }
}

/// `audio.recording` (F052).
public struct AudioRecordingPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.audioRecording
    public var clip: String
    /// "recording" | "paused" | "stopped".
    public var state: String
    /// Seconds recorded so far.
    public var duration: Double

    public init(clip: String, state: String, duration: Double) {
        self.clip = clip
        self.state = state
        self.duration = duration
    }
}

/// `shape.snapped` (F009, F030): a stroke snapped to a shape while the Pencil was down.
public struct ShapeSnappedPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.shapeSnapped
    /// Page ref "page:D/P".
    public var page: String
    /// `ShapeKind` raw value.
    public var shape: String
    /// Where the snap happened (page points), for the haptic's location.
    public var point: Point?
    public var session: String?

    public init(page: String, shape: String, point: Point? = nil, session: String? = nil) {
        self.page = page
        self.shape = shape
        self.point = point
        self.session = session
    }
}

/// `pencil.haptic`: ask the Pencil Hardware feature (F043) for an Apple Pencil Pro haptic.
public struct PencilHapticPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.pencilHaptic
    /// "alignment" (snapped to a guide, angle or grid) | "levelChange" | "generic".
    public var kind: String
    /// Page ref and page point of the feedback, when known.
    public var page: String?
    public var point: Point?
    public var session: String?

    public init(kind: String = "alignment", page: String? = nil, point: Point? = nil, session: String? = nil) {
        self.kind = kind
        self.page = page
        self.point = point
        self.session = session
    }
}
