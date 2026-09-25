import SwiftUI
import QuartzCore
import NibContracts
import NibDesign

/// F040 Laser pointer: the "laser" canvas tool (key L, `.samples`, sticky) with Dot and Trail modes drawn in the
/// tool overlay, its settings popover and options bar, a canvas attachment that shows command-driven pointing
/// (`laser.point`), and the `laser.moved` events presentation (F063) and collaboration (F108) draw from. The laser
/// never writes to a document: no command here calls `ctx.mutate`, and the tool never commits a stroke.
public enum FeatLaserFeature: NibFeature {
    public static let id = "laser"

    public static func register(_ app: NibApp) {
        LaserSettings.declare(in: app.settings, owner: id)
        let hub = LaserHub()
        LaserCommands.register(in: app.commands, hub: hub)
        let title = String(localized: "Laser")
        app.ui.canvasTools.register(CanvasToolDescriptor(id: LaserTool.toolID, title: title, order: 110, owner: id,
                                                         make: { LaserTool(hub: hub) }))
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: LaserTool.toolID, title: title, icon: NibSymbol.laser.name, group: .accessories, order: 40, owner: id,
            toolID: LaserTool.toolID, shortcut: KeyShortcut("l"),
            activeToolMenu: { [weak app] session in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(LaserOptionsView(app: app, session: session, layout: .bar))
            },
            settings: { [weak app] session in
                guard let app else { return AnyView(EmptyView()) }
                return AnyView(LaserOptionsView(app: app, session: session, layout: .popover))
            }))
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(
            id: LaserPointerAttachment.attachmentID, owner: id, order: 900,
            make: { _ in LaserPointerAttachment(hub: hub) }))
    }
}

// MARK: - Model

enum LaserMode: String, Codable, CaseIterable {
    /// A dot follows the touch and fades when it lifts.
    case dot
    /// A line follows the touch and fades behind it.
    case trail

    var title: String {
        switch self {
        case .dot: return String(localized: "Dot")
        case .trail: return String(localized: "Trail")
        }
    }
}

enum LaserTrailLength: String, Codable, CaseIterable {
    case short, medium, long

    /// Seconds a trail point stays on screen; the last `LaserStyle.fade` of it is the linear fade.
    var lifetime: TimeInterval {
        switch self {
        case .short: return LaserStyle.fade
        case .medium: return 1
        case .long: return 2
        }
    }

    var title: String {
        switch self {
        case .short: return String(localized: "Short")
        case .medium: return String(localized: "Medium")
        case .long: return String(localized: "Long")
        }
    }
}

/// What the laser looks like: the three laser settings in one value.
struct LaserAppearance: Equatable {
    var mode: LaserMode = .dot
    var color: RGBA = LaserAppearance.defaultColor
    var trailLength: LaserTrailLength = .medium

    /// Vermilion is the default (DESIGN.md §14.3); the popover offers it plus five inks (T-054: colours besides red).
    static let defaultColor = RGBA(ink: .vermilion)
    static let palette: [NibInk] = [.vermilion, .ochre, .moss, .lagoon, .cobalt, .plum]

    /// How long a trail point lives; a dot only needs its fade.
    var lifetime: TimeInterval { mode == .trail ? trailLength.lifetime : LaserStyle.fade }

    var commandParams: JSONValue {
        ["mode": .string(mode.rawValue), "color": .string(color.hex), "trailLength": .string(trailLength.rawValue)]
    }
}

extension LaserAppearance {
    init(settings: SettingsStore) {
        self.init(mode: settings.get(LaserSettings.mode), color: settings.get(LaserSettings.color),
                  trailLength: settings.get(LaserSettings.trailLength))
    }
}

extension RGBA {
    init(ink: NibInk) {
        self.init(UInt8((ink.hex >> 16) & 0xFF), UInt8((ink.hex >> 8) & 0xFF), UInt8(ink.hex & 0xFF))
    }

    /// Same colour ignoring alpha (swatch selection).
    func sameHue(as other: RGBA) -> Bool { r == other.r && g == other.g && b == other.b }
}

/// The laser's look from DESIGN.md §14.12: a 12 pt dot with a 45 % glow 12 pt wide; the trail is a 4 pt line fading
/// linearly over 600 ms (`NibMotion.laserFade`, the only linear motion in Nib). ponytail: the numbers mirror
/// DESIGN.md because NibDesign has no laser metrics and `laserFade` is a SwiftUI Animation whose duration a CALayer
/// cannot read.
enum LaserStyle {
    static let dotDiameter: CGFloat = 12
    static let glowWidth: CGFloat = 12
    static let glowOpacity: Double = 0.45
    static let trailWidth: CGFloat = 4
    static let fade: TimeInterval = 0.6
    /// Above the page tiles and every other canvas overlay.
    static let canvasZ: CGFloat = 1_000
    /// ponytail: the trail's alpha is quantised into 12 layers (≤ 50 ms steps of the fade); one layer per segment
    /// if banding ever shows.
    static let bands = 12

    /// The band (0 faintest … bands − 1 opaque) drawing a segment of opacity `alpha` (0 < alpha ≤ 1).
    static func band(for alpha: Double) -> Int {
        min(bands - 1, max(0, Int((alpha * Double(bands)).rounded(.up)) - 1))
    }

    static func bandOpacity(_ band: Int) -> Double { Double(band + 1) / Double(bands) }
}

// MARK: - Settings

enum LaserSettings {
    static let prefix = "laser."
    static let mode = SettingKey("laser.mode", default: LaserMode.dot, synced: true)
    static let color = SettingKey("laser.color", default: LaserAppearance.defaultColor, synced: true)
    static let trailLength = SettingKey("laser.trailLength", default: LaserTrailLength.medium, synced: true)

    static func declare(in s: SettingsStore, owner: String) {
        s.declare(mode, summary: "Laser pointer style: dot follows the touch, trail leaves a line that fades.",
                  owner: owner, schema: .str(choices: LaserMode.allCases.map(\.rawValue)))
        s.declare(color, summary: "Laser pointer colour (#RRGGBB or #RRGGBBAA).", owner: owner, schema: .color)
        s.declare(trailLength, summary: "How long the laser trail stays: short 0.6 s, medium 1 s, long 2 s.",
                  owner: owner, schema: .str(choices: LaserTrailLength.allCases.map(\.rawValue)))
    }
}

// MARK: - Commands

/// `laser.setMode` and `laser.point`. Both are `.session` (window state and device preferences): neither creates
/// a transaction, so the laser never touches a document or the undo stack.
@MainActor
enum LaserCommands {
    struct SetModeParams: Codable {
        var mode: LaserMode
        var color: String?
        var trailLength: LaserTrailLength?
    }

    struct SetModeOutput: Codable {
        var mode: LaserMode
        var color: String
        var trailLength: LaserTrailLength
    }

    struct PointParams: Codable {
        var page: String
        var point: Point?
    }

    static let setModeExamples: [JSONValue] = {
        let trail: JSONValue = ["mode": "trail"]
        let blue: JSONValue = ["mode": "dot", "color": "#2156D9"]
        let long: JSONValue = ["mode": "trail", "trailLength": "long"]
        return [trail, blue, long]
    }()

    static let pointExamples: [JSONValue] = {
        let show: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [120, 240]]
        let hide: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001"]
        return [show, hide]
    }()

    static let setMode = CommandDescriptor(id: "laser.setMode", title: "Set Laser Mode",
        summary: "Choose the laser pointer: mode 'dot' (a dot follows the touch) or 'trail' (a line fading after ~1 s), with optional colour and trailLength.",
        params: .obj(["mode": .str("dot or trail", choices: LaserMode.allCases.map(\.rawValue)),
                      "color": .color,
                      "trailLength": .str("how long the trail stays: short 0.6 s, medium 1 s, long 2 s",
                                          choices: LaserTrailLength.allCases.map(\.rawValue))],
                     required: ["mode"]),
        examples: setModeExamples, effect: .session, target: .app)

    static let point = CommandDescriptor(id: "laser.point", title: "Point Laser",
        summary: "Move the laser pointer to a point on a page ([x, y] in page points); omit point to hide it. Presentations and collaborators follow it.",
        params: .obj(["page": .ref, "point": .point], required: ["page"]),
        examples: pointExamples, effect: .session, target: .app)

    static func register(in registry: CommandRegistry, hub: LaserHub) {
        registry.register(setMode) { json, ctx in
            let p = try CommandRegistry.decode(SetModeParams.self, from: json)
            let settings = ctx.services.settings
            var color = settings.get(LaserSettings.color)
            if let hex = p.color {
                guard let parsed = RGBA(hex: hex) else {
                    throw NibError(.invalidParams, "'\(hex)' is not a colour", path: "$.color",
                                   hint: "use #RRGGBB or #RRGGBBAA, for example #D9432B")
                }
                color = parsed
            }
            let trail = p.trailLength ?? settings.get(LaserSettings.trailLength)
            if !ctx.dryRun {
                settings.set(LaserSettings.mode, p.mode)
                settings.set(LaserSettings.color, color)
                settings.set(LaserSettings.trailLength, trail)
            }
            return try JSONValue.from(SetModeOutput(mode: p.mode, color: color.hex, trailLength: trail))
        }

        registry.register(point) { json, ctx in
            let p = try CommandRegistry.decode(PointParams.self, from: json)
            guard case let .page(doc, page)? = NodeRef(p.page) else {
                throw NibError(.invalidParams, "'\(p.page)' is not a page ref", path: "$.page",
                               hint: "pass page:<doc>/<page>, for example the page from query.context")
            }
            guard let record = try ctx.workspace.content(doc).page(page), !record.deleted else {
                throw NibError.notFound("page \(p.page)")
            }
            if let pt = p.point, !(pt.x.isFinite && pt.y.isFinite) {
                throw NibError.invalid("point must be two finite numbers", path: "$.point")
            }
            if !ctx.dryRun {
                hub.point(doc: doc, page: page, at: p.point, appearance: LaserAppearance(settings: ctx.services.settings),
                          session: ctx.activeSession?.id.raw, principal: ctx.principal, events: ctx.events)
            }
            return try JSONValue.from(NoResult())
        }
    }
}

// MARK: - Events

/// One `laser.moved` event: where the laser is (nil = lifted or hidden) and how it looks.
struct LaserSignal: Equatable {
    var doc: DocumentID
    var page: PageID
    var point: Point?
    var mode: LaserMode
    var color: RGBA
    /// The window it comes from (`EditorSession.id`); nil for callers without one (the bridge with no window).
    var session: String?
    var principal: Principal

    /// {page: "page:D/P", point?: [x, y], mode, color, session?}. `page` is a ref, so the payload can be passed
    /// straight back to `laser.point`; a payload without `point` means the laser was lifted.
    var payload: JSONValue {
        var o: [String: JSONValue] = ["page": .string(NodeRef.page(doc, page).description),
                                      "mode": .string(mode.rawValue), "color": .string(color.hex)]
        if let point { o["point"] = .array([.number(point.x), .number(point.y)]) }
        if let session { o["session"] = .string(session) }
        return .object(o)
    }
}

/// Keeps one laser's events at ≤ 30 a second. A signal that comes too soon waits (replacing any older waiting one)
/// and goes out when its interval is up, so the last position, or the lift, is never lost.
struct LaserThrottle {
    static let interval: TimeInterval = 1.0 / 30

    private(set) var lastEmit: TimeInterval = -.infinity
    private(set) var pending: LaserSignal?

    /// When the waiting signal may go out.
    var nextFlush: TimeInterval? { pending == nil ? nil : lastEmit + Self.interval }

    /// The signal to emit now, or nil when it has to wait for `flush`.
    mutating func offer(_ signal: LaserSignal, at t: TimeInterval) -> LaserSignal? {
        if t - lastEmit >= Self.interval {
            lastEmit = t
            pending = nil
            return signal
        }
        pending = signal
        return nil
    }

    /// Releases the waiting signal (called once its interval is up).
    mutating func flush(at t: TimeInterval) -> LaserSignal? {
        guard let p = pending else { return nil }
        lastEmit = max(t, lastEmit + Self.interval)
        pending = nil
        return p
    }
}

/// Per-app laser state shared by the tool, the attachments and the commands: the event throttles (one per window)
/// and the canvases that show `laser.point`.
@MainActor
final class LaserHub {
    /// The touch and display-link timebase.
    var now: () -> TimeInterval = { CACurrentMediaTime() }

    private struct Emitter {
        var throttle = LaserThrottle()
        var flushScheduled = false
    }

    // ponytail: one small entry per window that ever pointed; prune if windows ever number in the thousands.
    private var emitters: [String: Emitter] = [:]
    private let pointers = NSHashTable<LaserPointerAttachment>.weakObjects()

    func add(_ attachment: LaserPointerAttachment) { pointers.add(attachment) }
    func remove(_ attachment: LaserPointerAttachment) { pointers.remove(attachment) }

    /// `laser.point`: shows the pointer on every canvas of `doc` and tells presentation and collaborators.
    func point(doc: DocumentID, page: PageID, at point: Point?, appearance: LaserAppearance, session: String?,
               principal: Principal, events: EventBus) {
        for attachment in pointers.allObjects where attachment.documentID == doc {
            attachment.show(page: page, point: point, appearance: appearance)
        }
        send(LaserSignal(doc: doc, page: page, point: point, mode: appearance.mode, color: appearance.color,
                         session: session, principal: principal), to: events)
    }

    /// Emits `laser.moved`, throttled per window.
    func send(_ signal: LaserSignal, to events: EventBus) {
        let key = signal.session ?? ""
        var e = emitters[key] ?? Emitter()
        if let out = e.throttle.offer(signal, at: now()) { emit(out, events) }
        let schedule = e.throttle.pending != nil && !e.flushScheduled
        if schedule { e.flushScheduled = true }
        emitters[key] = e
        if schedule { scheduleFlush(key, events: events) }
    }

    private func scheduleFlush(_ key: String, events: EventBus) {
        guard let due = emitters[key]?.throttle.nextFlush else { return }
        let delay = max(0, due - now())
        Task { @MainActor [weak self, weak events] in
            // 1 ms past the interval, so a flush never lands inside it.
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 1_000_000)
            guard let self, let events else { return }
            self.flush(key, events: events)
        }
    }

    private func flush(_ key: String, events: EventBus) {
        guard var e = emitters[key] else { return }
        if let due = e.throttle.nextFlush, now() < due {
            // A signal went out directly after this flush was scheduled and moved the window on: wait for it.
            scheduleFlush(key, events: events)
            return
        }
        e.flushScheduled = false
        let out = e.throttle.flush(at: now())
        emitters[key] = e
        if let out { emit(out, events) }
    }

    private func emit(_ s: LaserSignal, _ events: EventBus) {
        events.emit(NibEventType.laserMoved, principal: s.principal, doc: s.doc, payload: s.payload)
    }
}
