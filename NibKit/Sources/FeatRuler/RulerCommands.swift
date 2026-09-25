import Foundation
import NibContracts

extension Notification.Name {
    /// Posted with the session as `object` whenever `ruler.set` changes that session's ruler.
    static let nibRulerDidChange = Notification.Name("NibRulerDidChange")
}

enum RulerUnits: String, Codable, CaseIterable {
    case centimetres = "cm"
    case inches = "in"

    /// Page points per unit.
    var points: Double { self == .inches ? 72 : 72 / 2.54 }
    /// Subdivisions of one unit, coarsest first; each divides the next (half centimetres and millimetres; halves down
    /// to sixteenths of an inch).
    var divisions: [Int] { self == .inches ? [1, 2, 4, 8, 16] : [1, 2, 10] }
    /// The last whole unit that fits on the scale (30 cm, 12 in).
    var maxValue: Int {
        Int(((RulerMetrics.length - 2 * RulerMetrics.endMargin) / points + 1e-9).rounded(.down))
    }

    var title: String {
        self == .inches ? String(localized: "Inches") : String(localized: "Centimetres")
    }

    static var localeDefault: RulerUnits { Locale.current.measurementSystem == .us ? .inches : .centimetres }
}

/// Ruler options that follow the library: units and whether the scale shows its numbers.
enum RulerSettings {
    static let units = SettingKey("ruler.units", default: RulerUnits.localeDefault.rawValue, synced: true)
    static let digits = SettingKey("ruler.digits", default: true, synced: true)

    static func declare(in settings: SettingsStore, owner: String) {
        settings.declare(units, summary: "Ruler scale units: 'cm' (centimetres) or 'in' (inches).", owner: owner,
                         schema: .str(choices: ["cm", "in"]))
        settings.declare(digits, summary: "Show the numbers on the ruler's scale.", owner: owner, schema: .bool())
    }

    static func currentUnits(_ settings: SettingsStore) -> RulerUnits {
        RulerUnits(rawValue: settings.get(units)) ?? .centimetres
    }
}

/// One window's ruler. It is session state (never saved in documents), kept in `EditorSession.toolOptions["ruler"]`
/// so the command, the stroke processor and the canvas attachment read the same value.
struct RulerState: Codable, Equatable {
    var visible = false
    /// Degrees anticlockwise from the page's horizontal, in [0, 360).
    var angle: Double = 0
    /// Centre of the ruler in the coordinates of `page`.
    var position: Point?
    var page: PageID?
    var doc: DocumentID?

    static let optionKey = "ruler"

    @MainActor
    static func load(_ session: EditorSession) -> RulerState {
        guard let json = session.toolOptions[optionKey] else { return RulerState() }
        return (try? json.decode(RulerState.self)) ?? RulerState()
    }

    @MainActor
    func save(to session: EditorSession) {
        session.toolOptions[RulerState.optionKey] = try? JSONValue.from(self)
        NotificationCenter.default.post(name: .nibRulerDidChange, object: session)
    }

    /// The page the ruler sits on: its own while the window still shows that document, otherwise the current page.
    @MainActor
    func anchorPage(in session: EditorSession) -> PageID? {
        (doc == session.document ? page : nil) ?? session.page
    }
}

enum RulerAngle {
    /// Degrees in [0, 360).
    static func normalized(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let n = r < 0 ? r + 360 : r
        return (n >= 360 || n == 0) ? 0 : n
    }

    /// The nearest multiple of 45° when the angle is within `tolerance` of it (DESIGN.md §14.3), else nil.
    static func snap(_ degrees: Double, tolerance: Double = 2.5) -> Double? {
        let k = (degrees / 45).rounded() * 45
        return abs(degrees - k) <= tolerance ? normalized(k) : nil
    }

    /// "45", "22.5": at most one decimal.
    static func number(_ value: Double) -> String {
        let r = (value * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// The HUD reading, e.g. "45°".
    static func label(_ degrees: Double) -> String {
        number(normalized((normalized(degrees) * 10).rounded() / 10)) + "°"
    }
}

/// `ruler.set`: the one command behind the ruler button, key R, the ruler's own menu and its gestures, so plugins, the
/// AI and the bridge can do everything the ruler does. With no fields it changes nothing and returns the state.
struct RulerSet: NibCommand {
    static let id = "ruler.set"

    struct Params: Codable {
        var visible: Bool?
        var toggle: Bool?
        var angle: Double?
        var position: [Double]?
        var units: String?
        var digits: Bool?
    }

    struct Output: Codable {
        var visible: Bool
        var angle: Double
        var position: [Double]?
        var page: String?
        var units: String
        var digits: Bool
    }

    private static let examples: [JSONValue] = [
        ["visible": true, "angle": 45],
        ["position": [297.6, 420.9], "angle": 0],
        ["units": "in", "digits": false],
        ["toggle": true],
    ]

    static let descriptor = CommandDescriptor(
        id: "ruler.set", title: "Ruler",
        summary: "Show, hide or toggle the ruler and place it: angle (degrees anticlockwise), position [x, y] of its centre on the current page, units cm|in, digits. Returns its state.",
        params: .obj([
            "visible": .bool("show (true) or hide (false) the ruler"),
            "toggle": .bool("true flips visibility (the ruler button and key R)"),
            "angle": .num("degrees anticlockwise from horizontal", min: -360, max: 360),
            "position": .point,
            "units": .str("scale units", choices: ["cm", "in"]),
            "digits": .bool("show the numbers on the scale"),
        ]),
        examples: RulerSet.examples, effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var units: RulerUnits?
        if let raw = p.units {
            guard let u = RulerUnits(rawValue: raw) else {
                throw NibError(.invalidParams, "units must be 'cm' or 'in'", path: "$.units",
                               hint: "call commands.describe {\"id\": \"ruler.set\"}")
            }
            units = u
        }
        if let a = p.angle, !a.isFinite { throw NibError.invalid("angle must be a number of degrees", path: "$.angle") }
        var position: Point?
        if let xy = p.position {
            guard xy.count == 2, xy.allSatisfy({ $0.isFinite }) else {
                throw NibError.invalid("position must be [x, y] in page points", path: "$.position")
            }
            position = Point(xy[0], xy[1])
        }
        let places = p.visible != nil || p.toggle == true || p.angle != nil || position != nil
        let session = ctx.activeSession
        if places && session == nil { throw NibError.unavailable("an open editor window") }

        let settings = ctx.services.settings
        if let units { settings.set(RulerSettings.units, units.rawValue) }
        if let digits = p.digits { settings.set(RulerSettings.digits, digits) }

        var state = session.map { RulerState.load($0) } ?? RulerState()
        if let session, places {
            let wasVisible = state.visible
            if p.toggle == true { state.visible.toggle() }
            if let v = p.visible { state.visible = v }
            if let a = p.angle { state.angle = RulerAngle.normalized(a) }
            if let position {
                state.position = position
                state.page = session.page
                state.doc = session.document
            } else if state.visible && (!wasVisible || state.position == nil) {
                place(&state, session: session, ctx: ctx)
            }
            state.save(to: session)
        }
        return output(state, session: session, settings: settings)
    }

    /// Showing the ruler puts it where the user is looking: the middle of the visible part of the current page (the
    /// page's centre when the window has not reported it), unless it is still in view where it was left.
    @MainActor
    private static func place(_ state: inout RulerState, session: EditorSession, ctx: CommandContext) {
        if let old = state.position, state.anchorPage(in: session) == session.page,
           session.visibleRect.map({ $0.contains(old) }) ?? true {
            state.page = session.page
            state.doc = session.document
            return
        }
        state.page = session.page
        state.doc = session.document
        if let visible = session.visibleRect, !visible.isEmpty {
            state.position = visible.center
        } else if let doc = session.document, let page = session.page,
                  let size = (try? ctx.workspace.content(doc))?.page(page)?.size {
            state.position = Point(size.width / 2, size.height / 2)
        } else {
            state.position = Point(PageSize.a4.width / 2, PageSize.a4.height / 2)
        }
    }

    @MainActor
    private static func output(_ state: RulerState, session: EditorSession?, settings: SettingsStore) -> Output {
        var ref: String?
        if let session, let doc = session.document, let page = state.anchorPage(in: session) {
            ref = NodeRef.page(doc, page).description
        }
        return Output(visible: state.visible, angle: state.angle, position: state.position.map { [$0.x, $0.y] },
                      page: ref, units: RulerSettings.currentUnits(settings).rawValue,
                      digits: settings.get(RulerSettings.digits))
    }
}
