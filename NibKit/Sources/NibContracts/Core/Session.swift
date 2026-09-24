import Foundation
import Combine

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
    @Published public var activeLayer = 0
    /// Per-device layer visibility.
    @Published public var hiddenLayers: Set<Int> = []
    /// Note Replay in progress (the canvas passes it to the renderer).
    @Published public var replay: ReplayState? = nil
    /// True while a text view (text box, block, card field) is first responder; single-key shortcuts are off.
    public var isEditingText = false
    /// Transient per-tool options (current preset slot, eraser size…), keyed by tool id.
    public var toolOptions: [String: JSONValue] = [:]
    /// The editor view controller showing `document` (set by the editor).
    public weak var editor: DocumentEditing?

    public init(id: NibID = NibID.make()) {
        self.id = id
    }

    private func notify(_ kind: String) {
        events?.emit(kind, doc: document, payload: ["session": .string(id.raw)])
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
        active = s
    }

    public func remove(_ s: EditorSession) {
        sessions.removeAll { $0 === s }
        if active === s { active = sessions.last }
    }

    public func activate(_ s: EditorSession) { active = s }

    public func session(_ id: NibID) -> EditorSession? { sessions.first { $0.id == id } }
}
