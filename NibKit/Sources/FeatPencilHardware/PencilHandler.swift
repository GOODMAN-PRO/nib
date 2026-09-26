import Combine
import NibContracts
import QuartzCore
import UIKit

// MARK: - Gestures, system preferences and bindings

/// The two Pencil gestures a person can bind. The raw values match `PencilActionDescriptor.gestures`.
enum PencilGesture: String, CaseIterable, Codable {
    case doubleTap, squeeze
}

/// `UIPencilPreferredAction` without its per-case availability, so the resolver stays pure and testable.
enum PencilSystemAction: String, CaseIterable, Codable {
    case ignore, switchEraser, switchPrevious, showColorPalette, showInkAttributes, showContextualPalette,
         runSystemShortcut

    init(_ action: UIPencilPreferredAction) {
        switch action {
        case .ignore: self = .ignore
        case .switchEraser: self = .switchEraser
        case .switchPrevious: self = .switchPrevious
        case .showColorPalette: self = .showColorPalette
        default:
            if #available(iOS 17.5, *) {
                self = PencilSystemAction.newer(action)
            } else {
                self = .ignore
            }
        }
    }

    @available(iOS 17.5, *)
    private static func newer(_ action: UIPencilPreferredAction) -> PencilSystemAction {
        switch action {
        case .showInkAttributes: return .showInkAttributes
        case .showContextualPalette: return .showContextualPalette
        case .runSystemShortcut: return .runSystemShortcut
        default: return .ignore
        }
    }

    var title: String {
        switch self {
        case .ignore: return String(localized: "Off")
        case .switchEraser: return String(localized: "Switch between current tool and eraser")
        case .switchPrevious: return String(localized: "Switch between current tool and last used")
        case .showColorPalette: return String(localized: "Show colour palette")
        case .showInkAttributes: return String(localized: "Show colour and thickness")
        case .showContextualPalette: return String(localized: "Show tool palette")
        case .runSystemShortcut: return String(localized: "Run a shortcut (handled by iPadOS)")
        }
    }
}

/// What `pencilhw.doubleTap` / `pencilhw.squeeze` hold: one of these, or the id of a `PencilActionDescriptor`.
enum PencilBuiltin: String, CaseIterable {
    case system, eraser, previous, palette, colours, attributes, off

    var title: String {
        switch self {
        case .system: return String(localized: "Use iPad setting")
        case .eraser: return PencilSystemAction.switchEraser.title
        case .previous: return PencilSystemAction.switchPrevious.title
        case .palette: return PencilSystemAction.showContextualPalette.title
        case .colours: return PencilSystemAction.showColorPalette.title
        case .attributes: return PencilSystemAction.showInkAttributes.title
        case .off: return PencilSystemAction.ignore.title
        }
    }
}

/// What the floating Pencil palette shows.
enum PaletteKind: String, CaseIterable, Codable {
    /// The customised toolbar's tools, undo and redo, colour and thickness (squeeze).
    case tools
    /// Colour only (double-tap "Show colour palette").
    case colours
    /// Colour and thickness ("Show ink attributes").
    case attributes
}

enum PencilCommandIDs {
    static let gesture = "pencil.gesture"
    static let palette = "pencil.palette"
    static let actions = "pencil.actions"
    /// Owner: F008 (not in `CommandIDs`).
    static let presetSelect = "preset.select"
}

/// A command call a Pencil gesture resolves to.
struct PencilInvocation: Equatable {
    var command: String
    var params: JSONValue
}

/// The editor state a gesture is resolved against.
struct PencilActionContext {
    var tool: String
    var previousTool: String?
    var readOnly = false
    var doc: DocumentID?
    var page: PageID?
    /// Where the Pencil is, in page points on `page`.
    var point: Point?
}

/// Maps a gesture and its binding (a built-in, a Pencil action id, or the iPad's own preference) to ONE command.
enum PencilActionResolver {
    static let eraser = "eraser"
    static let fallbackTool = "pen"

    static func resolve(_ gesture: PencilGesture, binding: String, system: PencilSystemAction,
                        actions: [PencilActionDescriptor], context: PencilActionContext) -> PencilInvocation? {
        guard !context.readOnly else { return nil }
        if let builtin = PencilBuiltin(rawValue: binding) {
            switch builtin {
            case .system: return invocation(for: system, context)
            case .eraser: return invocation(for: .switchEraser, context)
            case .previous: return invocation(for: .switchPrevious, context)
            case .palette: return palette(.tools, context)
            case .colours: return palette(.colours, context)
            case .attributes: return palette(.attributes, context)
            case .off: return nil
            }
        }
        // ponytail: a binding whose plugin was removed (or that does not offer this gesture) follows the iPad setting.
        guard let action = actions.first(where: { $0.id == binding }), action.gestures.contains(gesture.rawValue) else {
            return invocation(for: system, context)
        }
        let base = contextParams(gesture, context)
        let params: JSONValue
        if case .object = action.params {
            params = base.merging(action.params)
        } else {
            params = base
        }
        return PencilInvocation(command: action.command, params: params)
    }

    /// The iPad's own preference (UIPencilInteraction.preferredTapAction / preferredSqueezeAction).
    static func invocation(for action: PencilSystemAction, _ context: PencilActionContext) -> PencilInvocation? {
        switch action {
        case .ignore, .runSystemShortcut:
            return nil                                  // iPadOS runs the chosen shortcut itself
        case .switchEraser:
            let back = context.previousTool.flatMap { $0 == eraser ? nil : $0 } ?? fallbackTool
            return select(context.tool == eraser ? back : eraser)
        case .switchPrevious:
            guard let previous = context.previousTool, previous != context.tool else { return nil }
            return select(previous)
        case .showColorPalette: return palette(.colours, context)
        case .showInkAttributes: return palette(.attributes, context)
        case .showContextualPalette: return palette(.tools, context)
        }
    }

    static func select(_ tool: String) -> PencilInvocation {
        PencilInvocation(command: CommandIDs.toolSelect, params: ["tool": .string(tool)])
    }

    static func palette(_ kind: PaletteKind, _ context: PencilActionContext) -> PencilInvocation {
        var params: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let doc = context.doc, let page = context.page, let point = context.point {
            params["page"] = .string(NodeRef.page(doc, page).description)
            params["at"] = .array([.number(point.x), .number(point.y)])
        }
        return PencilInvocation(command: PencilCommandIDs.palette, params: .object(params))
    }

    /// What a bound Pencil action's command receives besides its own params: {gesture, doc?, page?, at?}.
    static func contextParams(_ gesture: PencilGesture, _ context: PencilActionContext) -> JSONValue {
        var params: [String: JSONValue] = ["gesture": .string(gesture.rawValue)]
        if let doc = context.doc {
            params["doc"] = .string(NodeRef.document(doc).description)
            if let page = context.page {
                params["page"] = .string(NodeRef.page(doc, page).description)
                if let point = context.point { params["at"] = .array([.number(point.x), .number(point.y)]) }
            }
        }
        return .object(params)
    }
}

/// One choice in Settings › Apple Pencil and in `pencil.actions`.
struct PencilChoice: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var owner: String
    var gestures: [String]
}

@MainActor
enum PencilChoices {
    /// Built-ins first (the iPad setting leads, with `systemTitle` under it), then Pencil actions from features and
    /// plugins that offer `gesture` (all of them when nil), then Off.
    static func all(for gesture: PencilGesture?, actions: [PencilActionDescriptor],
                    systemTitle: String?) -> [PencilChoice] {
        let both = PencilGesture.allCases.map { $0.rawValue }
        let owner = FeatPencilHardwareFeature.id
        var out = PencilBuiltin.allCases.filter { $0 != .off }.map { b in
            PencilChoice(id: b.rawValue, title: b.title, subtitle: b == .system ? systemTitle : nil, owner: owner,
                         gestures: both)
        }
        for a in actions where gesture.map({ a.gestures.contains($0.rawValue) }) ?? true {
            out.append(PencilChoice(id: a.id, title: a.title, subtitle: nil, owner: a.owner, gestures: a.gestures.sorted()))
        }
        out.append(PencilChoice(id: PencilBuiltin.off.rawValue, title: PencilBuiltin.off.title, subtitle: nil,
                                owner: owner, gestures: both))
        return out
    }
}

/// Drops the second delivery of one physical gesture. The canvas (F101) forwards Pencil events through
/// `PencilEventHandler`, and this feature's own `UIPencilInteraction` sees the same tap; whichever arrives first wins.
struct PencilEventGate {
    var window: TimeInterval
    private var last: [String: TimeInterval] = [:]

    init(window: TimeInterval = 0.25) {
        self.window = window
    }

    mutating func accept(_ kind: String, at time: TimeInterval) -> Bool {
        if let previous = last[kind], time >= previous, time - previous < window { return false }
        last[kind] = time
        return true
    }
}

/// What Settings › Apple Pencil › Supported hardware reports.
enum PencilCapability: String, CaseIterable, Identifiable {
    case pressure, doubleTap, hover, squeeze, roll, haptics

    var id: String { rawValue }

    enum Support: Equatable {
        case available, detected, notDetected, needsUpdate
    }

    /// Squeeze, barrel roll and Pencil haptics need iPadOS 17.5. Haptics can't be observed, so they count as detected
    /// once a squeeze or a roll proves an Apple Pencil Pro is paired.
    func support(seen: Set<PencilCapability>, proSupported: Bool) -> Support {
        switch self {
        case .pressure:
            return .available
        case .doubleTap, .hover:
            return seen.contains(self) ? .detected : .notDetected
        case .squeeze, .roll:
            guard proSupported else { return .needsUpdate }
            return seen.contains(self) ? .detected : .notDetected
        case .haptics:
            guard proSupported else { return .needsUpdate }
            return seen.contains(.squeeze) || seen.contains(.roll) ? .detected : .notDetected
        }
    }
}

// MARK: - The handler (ui.pencilHandler)

/// Apple Pencil hardware: double-tap, squeeze, hover preview and Pencil Pro haptics. Installed as `ui.pencilHandler`
/// (the canvas forwards to it) and reached by this feature's commands through `services`.
@MainActor
final class PencilHandler: PencilEventHandler {
    static let serviceKey = "pencilhw.handler"

    /// How long a Pencil position stays "where the Pencil is" after it was recorded (seconds).
    static let pointLifetime: TimeInterval = 2
    /// How long a gesture `receive` sent waits for `pencil.gesture` to pick it up (seconds).
    static let pendingLifetime: TimeInterval = 1
    /// F030's snap event (T-117), emitted on `app.events` with `doc` and payload {page, shape}.
    /// ponytail: owned by F030 (`ShapeRecognitionEvents.snapped` in FeatShapeRecognition/DrawShapeTool.swift) and not in
    /// `NibEventType`; move to the contract constant when one is added.
    static let shapeSnapped = "shape.snapped"

    private weak var app: NibApp?
    /// The iPad's Apple Pencil preference per gesture; tests replace it.
    var systemPreference: @MainActor (PencilGesture) -> PencilSystemAction
    /// Media time; tests replace it to age Pencil positions.
    var clock: @MainActor () -> TimeInterval = { CACurrentMediaTime() }
    /// How a Pencil gesture reaches `pencil.gesture` (the user's command path); tests record it instead.
    var performCommand: @MainActor (String, JSONValue, EditorSession) -> Void
    let palette = SqueezePalettePresenter()
    private(set) var seen = Set<PencilCapability>()
    private var gate = PencilEventGate()
    private var previews: [ObjectIdentifier: HoverPreview] = [:]
    /// The Pencil's last position over each canvas and when it was recorded.
    private var lastPoint: [ObjectIdentifier: (point: CGPoint, time: TimeInterval)] = [:]
    private weak var lastHost: CanvasHost?
    /// The physical gesture `receive` just sent, until `pencil.gesture` takes it (then its palette may play the haptic).
    private var pendingGesture: (gesture: PencilGesture, time: TimeInterval)?
    /// True while `pencil.gesture` runs the `pencil.palette` a physical Pencil gesture resolved to.
    private var paletteFromPencil = false
    private var styles: [String: HoverStyle] = [:]
    private var generators: [ObjectIdentifier: AnyObject] = [:]
    private var snaps: EventSubscription?
    private var bag = Set<AnyCancellable>()
    /// The last haptic asked for (kind and view point), for tests (which also reset it); the generator itself can't be
    /// observed.
    var lastFeedback: (kind: Feedback, point: CGPoint)?

    /// What the hover preview needs from settings, cached per tool (hover arrives at 120 Hz).
    struct HoverStyle {
        var presets: ToolPresets?
        var reactsToRoll: Bool
    }

    enum Feedback {
        /// A Pencil palette opening.
        case alignment
        /// A drawn shape snapping into place.
        case path
    }

    init(app: NibApp) {
        self.app = app
        systemPreference = { PencilHandler.readSystemPreference($0) }
        performCommand = { [weak app] command, params, session in app?.perform(command, params, session: session) }
        NotificationCenter.default.publisher(for: SettingsStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.styles.removeAll() }
            .store(in: &bag)
    }

    static func resolve(_ ctx: CommandContext) throws -> PencilHandler {
        guard let handler = ctx.services.get(serviceKey, as: PencilHandler.self) else {
            throw NibError.unavailable("Apple Pencil support")
        }
        return handler
    }

    static func readSystemPreference(_ gesture: PencilGesture) -> PencilSystemAction {
        switch gesture {
        case .doubleTap:
            return PencilSystemAction(UIPencilInteraction.preferredTapAction)
        case .squeeze:
            if #available(iOS 17.5, *) { return PencilSystemAction(UIPencilInteraction.preferredSqueezeAction) }
            return .ignore
        }
    }

    /// The system-wide hover preview choice (iPadOS 17.5+); earlier systems always allow it.
    static var systemShowsHoverPreview: Bool {
        if #available(iOS 17.5, *) { return UIPencilInteraction.prefersHoverToolPreview }
        return true
    }

    /// Squeeze, barrel roll and `UICanvasFeedbackGenerator` exist from iPadOS 17.5.
    static var proSupported: Bool {
        if #available(iOS 17.5, *) { return true }
        return false
    }

    /// Listens for F030's snaps, for the Pencil Pro snap haptic (called from `start`, never from `register`).
    func start() {
        guard let app, snaps == nil else { return }
        snaps = app.events.subscribe { [weak self] event in
            guard event.type == PencilHandler.shapeSnapped else { return }
            self?.didSnap(event)
        }
    }

    // MARK: PencilEventHandler (forwarded by the canvas)

    func pencilDoubleTap(session: EditorSession, host: CanvasHost) {
        receive(.doubleTap, at: nil, session: session, host: host)
    }

    func pencilSqueeze(began: Bool, location: CGPoint?, session: EditorSession, host: CanvasHost) {
        guard !began else {
            // Apple's guidance: act when the squeeze is released, so a squeeze that is cancelled does nothing.
            note(host, location)
            seen.insert(.squeeze)
            prepareFeedback(host)
            return
        }
        receive(.squeeze, at: location, session: session, host: host)
    }

    func pencilHover(_ sample: CanvasSample?, session: EditorSession, host: CanvasHost) {
        guard let sample else {
            hoverEnded(host: host)
            return
        }
        hover(sample, at: host.viewPoint(sample.location, page: sample.page), session: session, host: host)
    }

    // MARK: Gestures

    func receive(_ gesture: PencilGesture, at location: CGPoint?, session: EditorSession, host: CanvasHost) {
        let now = clock()
        guard gate.accept(gesture.rawValue, at: now) else { return }
        seen.insert(gesture == .doubleTap ? .doubleTap : .squeeze)
        note(host, location)
        if palette.isPresented {
            // Any Pencil gesture closes an open palette, like a tap outside it.
            palette.dismiss()
            return
        }
        pendingGesture = (gesture, now)
        performCommand(PencilCommandIDs.gesture, gestureParams(gesture, host: host), session)
    }

    /// `pencil.gesture`: whether this run comes from the Pencil itself (`receive`), not from AI, a plugin or a script.
    func takePendingGesture(_ gesture: PencilGesture) -> Bool {
        defer { pendingGesture = nil }
        guard let pending = pendingGesture, pending.gesture == gesture else { return false }
        return clock() - pending.time < PencilHandler.pendingLifetime
    }

    /// `pencil.gesture` marks the palette it runs for a physical gesture; `pencil.palette` takes the mark once.
    func markPaletteFromPencil(_ fromPencil: Bool) {
        paletteFromPencil = fromPencil
    }

    func takePaletteFromPencil() -> Bool {
        defer { paletteFromPencil = false }
        return paletteFromPencil
    }

    func binding(_ gesture: PencilGesture) -> String {
        app?.settings.get(PencilSettings.key(gesture)) ?? PencilBuiltin.system.rawValue
    }

    /// `content.pencilActions`: what features and plugins let people bind.
    var actions: [PencilActionDescriptor] { app?.content.pencilActions.all ?? [] }

    func resolve(_ gesture: PencilGesture, binding: String, session: EditorSession, page: PageID?,
                 at point: Point?) -> PencilInvocation? {
        let context = PencilActionContext(tool: session.tool, previousTool: session.previousTool,
                                          readOnly: session.readOnly, doc: session.document,
                                          page: page ?? session.page, point: point)
        return PencilActionResolver.resolve(gesture, binding: binding, system: systemPreference(gesture),
                                            actions: actions, context: context)
    }

    private func gestureParams(_ gesture: PencilGesture, host: CanvasHost) -> JSONValue {
        var params: [String: JSONValue] = ["gesture": .string(gesture.rawValue)]
        if let point = recentPoint(host), let hit = host.pagePoint(point) {
            params["page"] = .string(NodeRef.page(host.documentID, hit.page).description)
            params["at"] = .array([.number(hit.point.x), .number(hit.point.y)])
        }
        return .object(params)
    }

    /// Pencil activity on a canvas. A gesture without a hover pose (nil) only marks the canvas; it never makes an old
    /// position look new.
    private func note(_ host: CanvasHost, _ point: CGPoint?) {
        lastHost = host
        if let point { lastPoint[ObjectIdentifier(host)] = (point, clock()) }
    }

    /// Where the Pencil is over this canvas: its last position, if that was recorded in the last two seconds.
    func recentPoint(_ host: CanvasHost) -> CGPoint? {
        guard lastHost === host, let last = lastPoint[ObjectIdentifier(host)],
              clock() - last.time < PencilHandler.pointLifetime else { return nil }
        return last.point
    }

    // MARK: Hover

    /// A hover sample from the canvas or from this feature's own hover recogniser (same position, so both are fine).
    func hover(_ sample: CanvasSample, at point: CGPoint, session: EditorSession, host: CanvasHost) {
        seen.insert(.hover)
        if sample.roll != 0 { seen.insert(.roll) }
        note(host, point)
        let preview = self.preview(for: host)
        guard let app, !session.readOnly, !palette.isPresented, app.settings.get(PencilSettings.hoverPreview),
              PencilHandler.systemShowsHoverPreview else {
            preview.hide()
            return
        }
        let style = hoverStyle(session.tool)
        let shape = HoverPreviewGeometry.shape(tool: session.tool, presets: style.presets, zoom: host.zoomScale,
                                               azimuth: sample.azimuth,
                                               roll: style.reactsToRoll && sample.roll != 0 ? sample.roll : nil)
        preview.show(shape, at: point)
    }

    func hoverEnded(host: CanvasHost) {
        preview(for: host).hide()
    }

    private func hoverStyle(_ tool: String) -> HoverStyle {
        if let cached = styles[tool] { return cached }
        guard let app else { return HoverStyle(presets: nil, reactsToRoll: false) }
        let presets = NibSettings.presetTools.contains(tool) ? app.settings.get(NibSettings.presets(tool)) : nil
        // F007's Dynamic Ink switch: the pen's nib turns with the barrel only when the pen reacts to roll.
        let roll = app.settings.json(PencilSettings.reactToRoll)
            ?? app.settings.descriptor(PencilSettings.reactToRoll)?.defaultValue
        let style = HoverStyle(presets: presets, reactsToRoll: roll?.boolValue ?? false)
        styles[tool] = style
        return style
    }

    private func preview(for host: CanvasHost) -> HoverPreview {
        let key = ObjectIdentifier(host)
        if let existing = previews[key], existing.host != nil { return existing }
        previews = previews.filter { $0.value.host != nil }
        let preview = HoverPreview(host: host)
        previews[key] = preview
        return preview
    }

    /// A canvas closed: drop its preview layer, its last Pencil position and a palette shown over it.
    func forget(_ host: CanvasHost) {
        let key = ObjectIdentifier(host)
        previews[key]?.remove()
        previews[key] = nil
        lastPoint[key] = nil
        generators[key] = nil
        if palette.host === host { palette.dismiss() }
    }

    // MARK: Palette

    /// Shows the palette over the session's canvas at a page point, else where the Pencil is, else mid-screen.
    /// `fromPencil`: a double-tap or squeeze opened it, so Apple Pencil Pro taps in the hand (never for the keyboard,
    /// a menu, AI or a plugin; DESIGN.md §11).
    func showPalette(_ kind: PaletteKind, session: EditorSession, page: PageID?, at point: Point?,
                     fromPencil: Bool) throws -> (plan: PalettePlan, shown: Bool) {
        guard let app else { throw NibError.unavailable("Apple Pencil support") }
        guard let host = canvasHost(for: session) else {
            throw NibError(.unavailable, "the Pencil palette needs an open notebook or whiteboard",
                           hint: "open a notebook or whiteboard, then call pencil.palette")
        }
        var anchor = recentPoint(host) ?? CGPoint(x: host.canvasView.bounds.midX, y: host.canvasView.bounds.midY)
        if let point, let page = page ?? session.page { anchor = host.viewPoint(point, page: page) }
        let model = PaletteModel(app: app, session: session, kind: kind)
        let shown = palette.present(model, at: anchor, in: host)
        if shown {
            preview(for: host).hide()                   // the palette covers the canvas; hover stops reaching it
            if fromPencil { feedback(.alignment, host: host, at: anchor) }
        }
        return (model.plan, shown)
    }

    private func canvasHost(for session: EditorSession) -> CanvasHost? {
        if let host = session.editor?.canvasHost { return host }
        if let host = lastHost, host.session === session { return host }
        return nil
    }

    // MARK: Haptics (Apple Pencil Pro, iPadOS 17.5+)

    func feedback(_ kind: Feedback, host: CanvasHost, at point: CGPoint) {
        guard let app, app.settings.get(PencilSettings.haptics) else { return }
        lastFeedback = (kind, point)
        if #available(iOS 17.5, *) {
            let generator = canvasGenerator(host)
            switch kind {
            case .alignment: generator.alignmentOccurred(at: point)
            case .path: generator.pathCompleted(at: point)
            }
        }
    }

    private func prepareFeedback(_ host: CanvasHost) {
        if #available(iOS 17.5, *) { canvasGenerator(host).prepare() }
    }

    @available(iOS 17.5, *)
    private func canvasGenerator(_ host: CanvasHost) -> UICanvasFeedbackGenerator {
        let key = ObjectIdentifier(host)
        if let existing = generators[key] as? UICanvasFeedbackGenerator { return existing }
        let generator = UICanvasFeedbackGenerator(view: host.canvasView)
        generators[key] = generator
        return generator
    }

    /// Snapping haptic (T-117): F030 emits `shape.snapped` the moment a drawn stroke snaps to a shape (on lift, or
    /// while the Pencil is still down with Draw and Hold). It plays on the canvas the Pencil was last used on, and only
    /// when the snap is in that canvas's document; at the snap's own point when the event carries one, else where the
    /// Pencil is, else mid-page. The ruler and alignment guides play their own (F039, F012).
    func didSnap(_ event: NibEvent) {
        guard let host = lastHost, let doc = event.doc, doc == host.documentID else { return }
        var page: PageID?
        if let ref = event.payload?["page"]?.stringValue, let node = NodeRef(ref), case let .page(pageDoc, id) = node,
           pageDoc == doc {
            page = id
        }
        let point: CGPoint
        if let page, let at = event.payload?["at"]?.arrayValue, at.count == 2,
           let x = at[0].doubleValue, let y = at[1].doubleValue {
            point = host.viewPoint(Point(x, y), page: page)
        } else if let pencil = recentPoint(host) {
            point = pencil
        } else if let page, let frame = host.pageFrame(page) {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            point = CGPoint(x: host.canvasView.bounds.midX, y: host.canvasView.bounds.midY)
        }
        feedback(.path, host: host, at: point)
    }
}

// MARK: - The canvas attachment: UIPencilInteraction and the Pencil hover recogniser

/// Installs a `UIPencilInteraction` and a Pencil-only hover recogniser on every notebook and whiteboard canvas, so
/// double-tap, squeeze and the hover preview work however the canvas forwards events. A second delivery of one
/// gesture is dropped by `PencilEventGate`.
@MainActor
final class PencilInteractionAttachment: NSObject, CanvasAttachment, UIPencilInteractionDelegate,
    UIGestureRecognizerDelegate {
    private weak var handler: PencilHandler?
    private weak var host: CanvasHost?
    private var pencilInteraction: UIPencilInteraction?
    private var hoverRecognizer: UIHoverGestureRecognizer?

    init(handler: PencilHandler) {
        self.handler = handler
        super.init()
    }

    func attach(to host: CanvasHost) {
        self.host = host
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        host.canvasView.addInteraction(interaction)
        pencilInteraction = interaction
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        hover.delegate = self
        host.canvasView.addGestureRecognizer(hover)
        hoverRecognizer = hover
    }

    func detach(from host: CanvasHost) {
        if let pencilInteraction { host.canvasView.removeInteraction(pencilInteraction) }
        if let hoverRecognizer { host.canvasView.removeGestureRecognizer(hoverRecognizer) }
        pencilInteraction = nil
        hoverRecognizer = nil
        handler?.forget(host)
        self.host = nil
    }

    /// Only the key window's canvas reacts (two windows side by side each have a canvas).
    private func target(_ interaction: UIPencilInteraction) -> CanvasHost? {
        guard let host, interaction.view?.window?.isKeyWindow ?? false else { return nil }
        return host
    }

    /// iPadOS 17.0–17.4. From 17.5 UIKit calls `pencilInteraction(_:didReceiveTap:)` instead.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard let host = target(interaction) else { return }
        handler?.receive(.doubleTap, at: nil, session: host.session, host: host)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard let host = target(interaction) else { return }
        handler?.receive(.doubleTap, at: tap.hoverPose?.location, session: host.session, host: host)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard let host = target(interaction) else { return }
        let location = squeeze.hoverPose?.location
        switch squeeze.phase {
        case .began:
            handler?.pencilSqueeze(began: true, location: location, session: host.session, host: host)
        case .ended:
            handler?.pencilSqueeze(began: false, location: location, session: host.session, host: host)
        default:
            break                                           // .changed and .cancelled do nothing
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let host, let handler, let view = recognizer.view else { return }
        switch recognizer.state {
        case .began, .changed:
            let location = recognizer.location(in: view)
            guard let hit = host.pagePoint(location) else {
                handler.hoverEnded(host: host)
                return
            }
            var roll = 0.0
            if #available(iOS 17.5, *) { roll = Double(recognizer.rollAngle) }
            let sample = CanvasSample(page: hit.page, location: hit.point, force: 0,
                                      azimuth: Double(recognizer.azimuthAngle(in: view)),
                                      altitude: Double(recognizer.altitudeAngle), roll: roll,
                                      timestamp: CACurrentMediaTime(), isPencil: true)
            handler.hover(sample, at: location, session: host.session, host: host)
        default:
            handler.hoverEnded(host: host)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
