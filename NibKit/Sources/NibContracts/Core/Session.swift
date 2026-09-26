import Foundation
import Combine
import CoreGraphics

public struct Selection: Equatable {
    public var doc: DocumentID?
    public var page: PageID?
    public var items: [ElementID]
    /// Page-coordinate bounds of the selection (lasso polygon bounds or item union).
    public var bounds: Rect?

    public init(doc: DocumentID? = nil, page: PageID? = nil, items: [ElementID] = [], bounds: Rect? = nil) {
        self.doc = doc
        self.page = page
        self.items = items
        self.bounds = bounds
    }

    public var isEmpty: Bool { items.isEmpty }

    public var refs: [String] {
        guard let d = doc, let p = page else { return [] }
        return items.map { NodeRef.item(d, p, $0).description }
    }
}

public enum ReplayMode: String, Codable, CaseIterable {
    /// Ink ahead of the playhead is faded.
    case spotlight
    /// Ink appears progressively as it was written.
    case reveal
    /// Everything visible, no animation ("Static").
    case showAll = "static"
}

/// Note Replay state: wall-clock time (unix seconds) being played back.
public struct ReplayState: Equatable {
    public var time: Double
    public var mode: ReplayMode
    public init(time: Double, mode: ReplayMode) {
        self.time = time
        self.mode = mode
    }
}

public enum StylusMode: String, Codable, CaseIterable {
    /// Apple Pencil draws, fingers scroll/select.
    case pencilOnly
    /// Fingers, mouse and passive styluses draw ("Disconnect Apple Pencil").
    case anyInput
}

/// Per-window editor state (not persisted in documents). Changed by `.session` commands and editor UI.
@MainActor
public final class EditorSession: ObservableObject {
    /// The event bus of the app this session belongs to (set by `SessionRegistry.add`); changes are emitted there.
    /// Per session, not static, so two `NibApp`s in one process (two-device tests) never cross-talk.
    public weak var events: EventBus?

    public let id: NibID
    @Published public var document: DocumentID? = nil {
        didSet { if oldValue != document { notify(NibEventType.sessionDocument) } }
    }
    @Published public var page: PageID? = nil {
        didSet { if oldValue != page { notify(NibEventType.pageChanged) } }
    }
    /// Active canvas tool id ("pen", "lasso", "eraser", plugin tool ids…).
    @Published public var tool: String = "pen" {
        didSet {
            if oldValue != tool {
                previousTool = oldValue
                notify(NibEventType.toolChanged)
            }
        }
    }
    @Published public var previousTool: String? = nil
    @Published public var selection = Selection() {
        didSet { if oldValue != selection { notify(NibEventType.selectionChanged) } }
    }
    @Published public var zoom: Double = 1
    /// Visible part of the current page in page coordinates.
    @Published public var visibleRect: Rect? = nil
    @Published public var readOnly = false
    @Published public var activeLayer = 0 {
        didSet { if oldValue != activeLayer { notify(NibEventType.layersChanged) } }
    }
    /// Per-device layer visibility.
    @Published public var hiddenLayers: Set<Int> = [] {
        didSet { if oldValue != hiddenLayers { notify(NibEventType.layersChanged) } }
    }
    /// Note Replay in progress (the canvas passes it to the renderer).
    @Published public var replay: ReplayState? = nil
    /// True while a text view (text box, block, card field) is first responder; single-key shortcuts are off.
    public var isEditingText = false
    /// Transient per-tool options (current preset slot, eraser size…), keyed by tool id.
    public var toolOptions: [String: JSONValue] = [:]
    /// The editor view controller showing `document` (set by the editor).
    public weak var editor: DocumentEditing?

    /// contracts-v2: Pencil-down state of this window. The canvas (F006/F101) writes it; the document chrome mirrors it
    /// into its droplet container (recede while writing, DESIGN.md §10.8); attachments, HUDs and palettes observe it.
    /// Deliberately NOT `@Published`: a Pencil down must never re-evaluate SwiftUI bodies that observe the session.
    public let inking: InkingSignal
    /// contracts-v2: ids of the panels open in this window (sidebar tab, floating panels, sheets), kept by the chrome
    /// host (F017) so `query.context` and other features can report and toggle them.
    @Published public var openPanels: Set<String> = []
    /// contracts-v2: the tool to return to after a temporary tool (quick lasso, Circle to Lasso, Edit Handwriting,
    /// eyedropper). Set by `selectTemporarily`; cleared by `endTemporaryTool` and by any regular tool switch.
    @Published public private(set) var temporaryReturnTool: String? = nil

    public init(id: NibID = NibID.make()) {
        self.id = id
        self.inking = InkingSignal()
    }

    /// contracts-v2: switches to `tool` until `endTemporaryTool()` (or `finishToolUse`), remembering the current tool.
    /// Nested temporary switches keep the first return tool.
    public func selectTemporarily(_ tool: String) {
        let back = temporaryReturnTool ?? self.tool
        self.tool = tool
        temporaryReturnTool = back
    }

    /// contracts-v2: returns from a temporary tool; no-op when none is active.
    public func endTemporaryTool() {
        guard let back = temporaryReturnTool else { return }
        temporaryReturnTool = nil
        tool = back
    }

    /// contracts-v2: a regular tool switch (`tool.select`): drops any pending temporary return.
    public func selectTool(_ tool: String) {
        temporaryReturnTool = nil
        self.tool = tool
    }

    /// contracts-v2: a tool finished one use (an insert, a lasso, an erase). Returns to the temporary return tool when one
    /// is set, else to `previousTool` when the tool is not `sticky`; emits `tool.finished` either way. Canvas tools call
    /// it through `CanvasHost.finishToolUse(_:)`.
    public func finishToolUse(sticky: Bool) {
        let finished = tool
        if temporaryReturnTool != nil {
            endTemporaryTool()
        } else if !sticky, let back = previousTool, back != tool {
            tool = back
        }
        events?.emit(NibEventType.toolFinished, doc: document,
                     payload: ["session": .string(id.raw), "tool": .string(finished)])
    }

    private func notify(_ kind: String) {
        events?.emit(kind, doc: document, payload: ["session": .string(id.raw)])
    }
}

/// contracts-v2: whether the Pencil (or a drawing finger) is down in one window, and the stroke's bounds. Written by the
/// canvas, read by chrome, HUDs and attachments that recede or pause while the user writes. Main actor only.
@MainActor
public final class InkingSignal {
    public private(set) var isInking = false
    /// Bounds of the current stroke in WINDOW coordinates (nil between strokes).
    public private(set) var strokeBounds: CGRect?
    private var observers: [UUID: @MainActor (InkingSignal) -> Void] = [:]

    public init() {}

    /// The stroke started (canvas only).
    public func begin(strokeBounds: CGRect? = nil) {
        isInking = true
        self.strokeBounds = strokeBounds
        notify()
    }

    /// The stroke grew (canvas only). Cheap: observers are called synchronously.
    public func update(strokeBounds: CGRect) {
        guard isInking else { return }
        self.strokeBounds = strokeBounds
        notify()
    }

    /// The stroke ended or was cancelled (canvas only).
    public func end() {
        guard isInking || strokeBounds != nil else { return }
        isInking = false
        strokeBounds = nil
        notify()
    }

    /// Calls `handler` on every change until the subscription is cancelled.
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (InkingSignal) -> Void) -> EventSubscription {
        let id = UUID()
        observers[id] = handler
        return EventSubscription { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    private func notify() {
        for o in Array(observers.values) { o(self) }
    }
}

@MainActor
public final class SessionRegistry {
    public private(set) var sessions: [EditorSession] = []
    public private(set) weak var active: EditorSession?
    /// Set by `NibApp.init`; handed to every added session.
    public weak var events: EventBus?

    public init() {}

    public func add(_ s: EditorSession) {
        if !sessions.contains(where: { $0 === s }) { sessions.append(s) }
        s.events = events
        setActive(s)
    }

    public func remove(_ s: EditorSession) {
        sessions.removeAll { $0 === s }
        if active === s { setActive(sessions.last) }
    }

    /// Makes `s` the active session; emits `session.activated` when it changes (contracts-v2).
    public func activate(_ s: EditorSession) { setActive(s) }

    private func setActive(_ s: EditorSession?) {
        let changed = active !== s
        active = s
        if changed, let s = s {
            events?.emit(NibEventType.sessionActivated, doc: s.document, payload: ["session": .string(s.id.raw)])
        }
    }

    public func session(_ id: NibID) -> EditorSession? { sessions.first { $0.id == id } }
}
