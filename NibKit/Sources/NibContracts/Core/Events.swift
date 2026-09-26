import Foundation

public enum NibEventType {
    public static let committed = "tx.committed"
    public static let docOpened = "doc.opened"
    public static let docClosed = "doc.closed"
    public static let sessionDocument = "session.document"
    public static let pageChanged = "page.changed"
    public static let toolChanged = "tool.changed"
    public static let selectionChanged = "selection.changed"
    public static let libraryChanged = "library.changed"
    public static let aiTurnFinished = "ai.turn.finished"
    public static let pluginMessage = "plugin.message"
    /// Storage, folder sync or backup trouble or progress. Payload `SyncStatusPayload` (contracts-v2).
    public static let syncStatus = "sync.status"
    /// Laser pointer moved (F040 → presentation F063, collaboration F108). Payload {page, point: [x, y], mode:
    /// "dot" | "trail"}; a payload without `point` means the laser was lifted.
    public static let laserMoved = "laser.moved"
    /// Backup queue or last-run state changed (F068 → Cloud & Backup panel F070); query `backup.status` for details.
    public static let backupStatus = "backup.status"

    // contracts-v2 (payload types in EventPayloads.swift)

    /// `SessionRegistry.active` changed (a window became key). Payload {"session": id}.
    public static let sessionActivated = "session.activated"
    /// A session's `activeLayer` or `hiddenLayers` changed. Payload {"session": id}.
    public static let layersChanged = "session.layers"
    /// A tool finished one use (`EditorSession.finishToolUse`). Payload {"session": id, "tool": id}.
    public static let toolFinished = "tool.finished"
    /// Search indexing progress (NibIndex F055 → search UI F056). Payload `IndexProgressPayload`.
    public static let indexProgress = "index.progress"
    /// Audio playback position or state (F052 → Note Replay F053). Payload `AudioPlaybackPayload`.
    public static let audioPlayback = "audio.playback"
    /// Recording started, paused, resumed or stopped (F052). Payload `AudioRecordingPayload`.
    public static let audioRecording = "audio.recording"
    /// A Draw-and-Hold or Draw Shape stroke snapped to a shape (F009, F030 → Pencil Pro haptic F043). Payload
    /// `ShapeSnappedPayload`.
    public static let shapeSnapped = "shape.snapped"
    /// Any feature asks for an Apple Pencil Pro haptic (ruler snaps F039, alignment guides F012); F043 plays it with
    /// `UICanvasFeedbackGenerator`, the only module allowed to. Payload `PencilHapticPayload`.
    public static let pencilHaptic = "pencil.haptic"
    /// The element library changed (F035: collections, favourites, recents). Payload {"collection"?: id}.
    public static let elementsChanged = "elements.changed"
    /// MCP/HTTP bridge state changed (F090 → Bridge settings F091). Payload {"state": "off" | "starting" | "on" | …}.
    public static let bridgeStatus = "bridge.status"
}

/// Events carry refs, not payloads: subscribers query for details.
public struct NibEvent: Codable {
    public let seq: UInt64
    public let type: String
    /// Unix seconds.
    public let at: Double
    public let principal: Principal?
    public let doc: DocumentID?
    public let changes: ChangeSummary?
    public let payload: JSONValue?
}

public final class EventSubscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// App-wide event bus with a ring buffer (the MCP bridge long-polls it). Handlers run synchronously on the
/// emitting thread (normally main) — keep them cheap and hop queues for heavy work. Thread-safe.
public final class EventBus {
    public let capacity = 5_000
    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var ring: [NibEvent] = []
    private var handlers: [UUID: (NibEvent) -> Void] = [:]

    public init() {}

    @discardableResult
    public func emit(_ type: String, principal: Principal? = nil, doc: DocumentID? = nil,
                     changes: ChangeSummary? = nil, payload: JSONValue? = nil) -> NibEvent {
        lock.lock()
        seq += 1
        let e = NibEvent(seq: seq, type: type, at: Date().timeIntervalSince1970, principal: principal, doc: doc,
                         changes: changes, payload: payload)
        ring.append(e)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let hs = Array(handlers.values)
        lock.unlock()
        for h in hs { h(e) }
        return e
    }

    /// The handler lives until `cancel()` is called on the returned subscription.
    @discardableResult
    public func subscribe(_ handler: @escaping (NibEvent) -> Void) -> EventSubscription {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return EventSubscription { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.handlers[id] = nil
            self.lock.unlock()
        }
    }

    public func stream(where filter: @escaping (NibEvent) -> Bool = { _ in true }) -> AsyncStream<NibEvent> {
        AsyncStream { continuation in
            let sub = self.subscribe { e in
                if filter(e) { continuation.yield(e) }
            }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    public var lastSeq: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return seq
    }

    public func events(since: UInt64, limit: Int = 500) -> [NibEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.filter { $0.seq > since }.prefix(limit))
    }

    /// Long-poll: returns as soon as events newer than `since` exist, or after `timeout` seconds.
    public func poll(since: UInt64, timeout: TimeInterval) async -> [NibEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let e = events(since: since)
            if !e.isEmpty || Date() >= deadline { return e }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
