import Combine
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// Answer zones (F099, Goodnotes S-096 with S-070's teacher-approved hints and S-031's exam practice substitute).
//
// A zone is a `custom` item owned by "nib.answerZone" whose `custom.data` is an `AnswerZone` record: an optional
// score box (points, score), teacher hints in reveal order, how many of them are showing and a usage log of every hint
// a student opened. On the page it is a dashed box (drawn by `AnswerZoneDrawer`; the item's `display` carries the same
// drawing so it survives this feature being disabled). On the canvas `AnswerZoneAttachment` puts two rigid widgets in
// the zone's top-right corner: the score widget (tap to score, VoiceOver adjustable) and the hint widget (a finger tap
// goes through `content.tapHandlers` to `answerZone.revealHint`, which finds the widget under the point whatever item
// lies there, then emits `teacher.answerZone.hintsShown` for the window's attachment). Editing lives in the object
// menu's Style inspector.

// MARK: - Model

/// The record inside an answer zone's `CustomItem.data`. Decoding is lenient and bounded: plugins, the assistant and
/// older files may leave any field out, and a corrupt or hostile file cannot make a record larger than the commands
/// allow (hints, label, points) or than the inspector can list (usage).
struct AnswerZone: Codable, Equatable {
    static let owner = "nib.answerZone"
    static let type = "zone"
    /// `Item.drawKey` of every answer zone (drawer, custom item type, inspector).
    static let drawKey = "custom." + owner + "." + type
    static let maxHints = 10
    static let maxHintLength = 1000
    static let maxLabelLength = 120
    static let maxPoints: Double = 1000
    /// The usage log keeps the most recent entries (a hint is opened once, so this is only reached by a damaged file).
    static let maxUsage = 500
    /// Principal strings are short ("user", "ai:<chat id>", "plugin:<id>").
    static let maxPrincipalLength = 200
    /// The maximum a score box starts with when it is added from the UI.
    static let defaultPoints: Double = 5

    /// One hint a student opened.
    struct HintUse: Codable, Equatable {
        /// 0-based position of the hint in `hints` when it was opened.
        var hint: Int
        /// The hint as it read when it was opened, so the log stays right after the teacher edits or reorders the
        /// hints (nil in records written before the text was stored).
        var text: String?
        /// Unix seconds.
        var at: Double
        /// Principal string ("user", "ai:<chat>", "plugin:<id>").
        var by: String

        init(hint: Int, text: String? = nil, at: Double, by: String) {
            self.hint = hint
            self.text = text
            self.at = at
            self.by = by
        }

        enum CodingKeys: String, CodingKey { case hint, text, at, by }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hint = min(max(0, (try? c.decodeIfPresent(Int.self, forKey: .hint)) ?? 0), AnswerZone.maxHints)
            text = ((try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil).map { String($0.prefix(AnswerZone.maxHintLength)) }
            let when = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? nil
            at = when.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let principal = (try? c.decodeIfPresent(String.self, forKey: .by)) ?? nil
            by = principal.map { String($0.prefix(AnswerZone.maxPrincipalLength)) } ?? Principal.user.description
        }
    }

    /// Short name ("Question 3"); nil = numbered by reading order on its page.
    var label: String?
    /// Maximum score; nil = no score box.
    var points: Double?
    /// nil = not scored yet.
    var score: Double?
    var scoredAt: Double?
    var scoredBy: String?
    /// Teacher-approved hints in the order they are revealed.
    var hints: [String]
    /// How many hints are showing (the first `revealed` of `hints`).
    var revealed: Int
    var usage: [HintUse]

    init(label: String? = nil, points: Double? = nil, hints: [String] = []) {
        self.label = label
        self.points = points
        self.score = nil
        self.scoredAt = nil
        self.scoredBy = nil
        self.hints = hints
        self.revealed = 0
        self.usage = []
    }

    /// Every key this record owns inside `custom.data`; other keys (a plugin's, the assistant's, a newer build's) are
    /// kept as they are when the record is written.
    enum CodingKeys: String, CodingKey, CaseIterable { case label, points, score, scoredAt, scoredBy, hints, revealed, usage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let text = value(String.self, .label)?.trimmingCharacters(in: .whitespacesAndNewlines)
        label = (text?.isEmpty ?? true) ? nil : text.map { String($0.prefix(Self.maxLabelLength)) }
        let maximum = value(Double.self, .points).flatMap { $0.isFinite && $0 > 0 ? min($0, Self.maxPoints) : nil }
        points = maximum
        score = value(Double.self, .score).flatMap { s in
            guard s.isFinite, s >= 0, let m = maximum else { return nil }
            return min(s, m)
        }
        scoredAt = value(Double.self, .scoredAt).flatMap { $0.isFinite ? $0 : nil }
        scoredBy = value(String.self, .scoredBy).map { String($0.prefix(Self.maxPrincipalLength)) }
        hints = (value([String].self, .hints) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(Self.maxHints)
            .map { String($0.prefix(Self.maxHintLength)) }
        revealed = min(max(0, value(Int.self, .revealed) ?? 0), hints.count)
        usage = Array((value([HintUse].self, .usage) ?? []).suffix(Self.maxUsage))
    }

    var remainingHints: Int { max(0, hints.count - revealed) }
    var revealedHints: [String] { Array(hints.prefix(revealed)) }

    /// How many of `newHints` still count as shown after the teacher replaces the hints of `old`: the leading new hints
    /// that were shown before, by text, or that reword a shown hint in place (its position was shown and its old
    /// text is no longer in the list). Removing, inserting or reordering hints never marks an unopened hint as shown.
    static func revealedAfterEditing(_ old: AnswerZone, to newHints: [String]) -> Int {
        let shownBefore = Set(old.revealedHints)
        let oldTexts = Set(old.hints)
        let newTexts = Set(newHints)
        var count = 0
        for (i, text) in newHints.enumerated() {
            if shownBefore.contains(text) {
                count += 1
            } else if i < old.revealed, !newTexts.contains(old.hints[i]), !oldTexts.contains(text) {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    static func isZone(_ item: Item) -> Bool {
        item.kind == .custom && item.custom?.owner == owner && item.custom?.type == type
    }

    /// The zone record of `item`; nil when it is not an answer zone.
    static func decode(_ item: Item) -> AnswerZone? {
        guard isZone(item), let custom = item.custom else { return nil }
        return decode(data: custom.data)
    }

    static func decode(data: JSONValue) -> AnswerZone {
        (try? data.decode(AnswerZone.self)) ?? AnswerZone()
    }

    /// A new zone item at `frame`.
    func makeItem(frame: Frame, layer: Int) throws -> Item {
        var item = Item.makeCustom(CustomItem(owner: Self.owner, type: Self.type, frame: frame), layer: layer)
        try write(to: &item)
        return item
    }

    /// Stores this record in `item`, with the matching display list (what prints and exports even where this feature
    /// is not installed). Only this record's keys change: keys it does not know (added with `item.update`, or by a
    /// newer build) are kept, and its own keys that are now unset are removed.
    func write(to item: inout Item) throws {
        guard var custom = item.custom else {
            throw NibError(.invariantViolation, "item \(item.id.raw) is not a custom item")
        }
        var data = custom.data.objectValue ?? [:]
        let own = try JSONValue.from(self).objectValue ?? [:]
        for key in CodingKeys.allCases { data[key.rawValue] = own[key.rawValue] }
        custom.data = .object(data)
        custom.display = AnswerZoneLayout.displayList(self, size: PageSize(custom.frame.w, custom.frame.h), style: .full,
                                                      darkPaper: false)
        item.custom = custom
    }
}

// MARK: - Text

enum AnswerZoneFormat {
    /// 3, 2.5, 0.25 (locale digits, at most two decimals).
    static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// "3/5", or "–/5" before it is scored; nil without a score box.
    static func score(_ zone: AnswerZone) -> String? {
        guard let points = zone.points else { return nil }
        return (zone.score.map(number) ?? "\u{2013}") + "/" + number(points)
    }

    /// The zone's name: its label, else "Answer Zone 2" by reading order on its page.
    static func name(_ zone: AnswerZone, index: Int?) -> String {
        if let label = zone.label { return label }
        if let index { return String(localized: "Answer Zone \(index)") }
        return String(localized: "Answer Zone")
    }

    static func scoreValue(_ zone: AnswerZone) -> String {
        guard let points = zone.points else { return String(localized: "No score box") }
        if let score = zone.score {
            return String(localized: "\(number(score)) of \(number(points)) points")
        }
        return String(localized: "Not scored, out of \(number(points))")
    }

    static func hintsShown(_ zone: AnswerZone) -> String {
        String(localized: "\(zone.revealed) of \(zone.hints.count) shown")
    }

    /// A usage row's title: the hint as it read when it was opened, else its number.
    static func usedHint(_ use: AnswerZone.HintUse) -> String {
        guard let text = use.text, !text.isEmpty else { return String(localized: "Hint \(use.hint + 1)") }
        return String(localized: "Hint \(use.hint + 1): \(text)")
    }
}

// MARK: - Layout (pure, page points; also used off the main thread by the drawer)

enum AnswerZoneLayout {
    enum Style {
        /// The dashed box only: on the canvas, where the attachment's widgets show the score and the hints.
        case outline
        /// The box plus the score box and hint use: prints, exports, thumbnails and the stored display list.
        case full
    }

    /// Where the widgets sit on a zone, in page points.
    struct Slots: Equatable {
        var score: Rect?
        var hint: Rect?
    }

    static let minSide: Double = 24
    /// A zone added at a point (page long-press).
    static let defaultSize = PageSize(280, 120)
    /// The widgets on the canvas, in view points; at 100 % the printed boxes have the same size in page points.
    static let widgetWidth: Double = 72
    static let widgetHeight = Double(NibMetrics.tabCapsuleHeight)
    static let widgetInset = Double(NibSpacing.xs)
    /// Resting droplets are fused or at least 16 pt apart (DESIGN.md §2.4); apart also keeps their 44 pt touch areas
    /// from overlapping.
    static let widgetGap = Double(NibSpacing.l)

    // The page drawing (screen outline, prints, exports, the stored display list) uses only NibDesign tokens.

    /// The zone's dashed outline: the one dash at `thin` (DESIGN.md §5.1).
    static let outlineWidth = Double(NibStroke.thin)
    static let outlineDash = NibStroke.dash.map { Double($0) }
    /// An on-page mark, like search hits washed on the page (DESIGN.md §6).
    static let outlineRadius = Double(NibRadius.pageWash)
    /// The printed score and hint boxes draw the widgets' water line.
    static let boxWidth = Double(NibStroke.outline)
    static let textPadding = Double(NibSpacing.s)
    /// Printed text is fixed at the default (Large) size of the widgets' type roles, because the page does not follow
    /// Dynamic Type: the score in `NibFont.hud` (footnote), the hint count in `NibFont.caption2`. The hud size is
    /// also the widgets' Dynamic Type cap.
    static let scoreTextSize = defaultPointSize(.footnote)
    static let hintTextSize = defaultPointSize(.caption2)

    /// A text style's point size at the default content size category.
    static func defaultPointSize(_ style: UIFont.TextStyle) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        return Double(UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize)
    }

    /// The score widget in the zone's top-right corner and the hint widget under it (beside it when the zone is too
    /// short on screen), sized in view points at `zoom`.
    static func slots(zoneBounds b: Rect, zoom: Double, hasScore: Bool, hasHints: Bool) -> Slots {
        let z = max(zoom, 0.01)
        let w = widgetWidth / z, h = widgetHeight / z, inset = widgetInset / z, gap = widgetGap / z
        let right = b.maxX - inset - w
        var slots = Slots()
        if hasScore { slots.score = Rect(x: right, y: b.minY + inset, width: w, height: h) }
        if hasHints {
            if !hasScore {
                slots.hint = Rect(x: right, y: b.minY + inset, width: w, height: h)
            } else if b.height >= 2 * inset + 2 * h + gap {
                slots.hint = Rect(x: right, y: b.minY + inset + h + gap, width: w, height: h)
            } else {
                slots.hint = Rect(x: right - gap - w, y: b.minY + inset, width: w, height: h)
            }
        }
        return slots
    }

    /// A widget's touch area: at least 44 points on screen in each direction.
    static func hitRect(_ r: Rect, zoom: Double) -> Rect {
        let side = Double(NibMetrics.hitTarget) / max(zoom, 0.01)
        let dx = max(0, (side - r.width) / 2), dy = max(0, (side - r.height) / 2)
        return Rect(x: r.x - dx, y: r.y - dy, width: r.width + 2 * dx, height: r.height + 2 * dy)
    }

    /// Reading order: 16-point bands top to bottom, then left to right (a strict weak order, so sorting is stable).
    static func readsBefore(_ a: Rect, _ b: Rect) -> Bool {
        let bandA = Int((a.minY / 16).rounded(.down)), bandB = Int((b.minY / 16).rounded(.down))
        if bandA != bandB { return bandA < bandB }
        if a.minX != b.minX { return a.minX < b.minX }
        return a.minY < b.minY
    }

    /// `frame` moved (and shrunk when needed) onto a page of `size`; rotated frames are left alone.
    static func clamp(_ frame: Frame, to size: PageSize) -> Frame {
        guard frame.rotation == 0 else { return frame }
        var f = frame
        f.w = min(f.w, size.width)
        f.h = min(f.h, size.height)
        f.x = min(max(f.x, 0), size.width - f.w)
        f.y = min(max(f.y, 0), size.height - f.h)
        return f
    }

    /// The zone's drawing, relative to its frame's top-left.
    static func displayList(_ zone: AnswerZone, size: PageSize, style: Style, darkPaper: Bool) -> DisplayList {
        let ink = AnswerZoneInk(darkPaper: darkPaper)
        let half = outlineWidth / 2
        var ops = [DisplayOp(op: .rect, rect: Rect(x: half, y: half, width: max(0, size.width - outlineWidth),
                                                   height: max(0, size.height - outlineWidth)),
                             stroke: ink.outline, width: outlineWidth, dash: outlineDash, radius: outlineRadius)]
        guard style == .full else { return DisplayList(ops: ops) }
        let local = Rect(x: 0, y: 0, width: size.width, height: size.height)
        let slots = slots(zoneBounds: local, zoom: 1, hasScore: zone.points != nil, hasHints: zone.revealed > 0)
        if let box = slots.score, let points = zone.points {
            ops.append(DisplayOp(op: .rect, rect: box, stroke: ink.box, width: boxWidth, radius: box.height / 2))
            if let score = zone.score {
                ops.append(text(AnswerZoneFormat.number(score) + "/" + AnswerZoneFormat.number(points), in: box,
                                size: scoreTextSize, weight: .bold, align: .center, colour: ink.mark))
            } else {
                // Unscored: room on the left for a handwritten score on a printout.
                ops.append(text("/" + AnswerZoneFormat.number(points), in: box, size: scoreTextSize, weight: .bold,
                                align: .right, colour: ink.text))
            }
        }
        if let box = slots.hint {
            ops.append(DisplayOp(op: .rect, rect: box, stroke: ink.box, width: boxWidth, radius: box.height / 2))
            ops.append(text(String(localized: "Hints \(zone.revealed)/\(zone.hints.count)"), in: box, size: hintTextSize,
                            weight: .semibold, align: .center, colour: ink.text))
        }
        return DisplayList(ops: ops)
    }

    /// One line of text centred on `box`: the line box is the font's size plus the system font's leading.
    private static func text(_ string: String, in box: Rect, size: Double, weight: DisplayFontWeight,
                             align: ParagraphAlignment, colour: RGBA) -> DisplayOp {
        let lineHeight = size * 1.3
        let r = Rect(x: box.x + textPadding, y: box.midY - lineHeight / 2, width: max(0, box.width - 2 * textPadding),
                     height: lineHeight)
        return DisplayOp(op: .text, rect: r, stroke: colour, text: string, fontSize: size, align: align, weight: weight)
    }
}

/// The zone's page colours: from the ink palette (DESIGN.md §3.4), since they are page content, not chrome.
struct AnswerZoneInk {
    let outline: RGBA
    let box: RGBA
    let text: RGBA
    /// The teacher's mark: the score, in the red pen.
    let mark: RGBA

    init(darkPaper: Bool) {
        outline = darkPaper ? Self.rgba(NibInk.chalk, 0.55) : Self.rgba(NibInk.graphite, 0.65)
        box = darkPaper ? Self.rgba(NibInk.chalk, 0.45) : Self.rgba(NibInk.graphite, 0.5)
        text = darkPaper ? Self.rgba(NibInk.chalk) : Self.rgba(NibInk.graphite)
        mark = Self.rgba(NibInk.vermilion)
    }

    static func rgba(_ c: NibHexColour, _ alpha: Double = 1) -> RGBA {
        RGBA(UInt8((c.hex >> 16) & 0xFF), UInt8((c.hex >> 8) & 0xFF), UInt8(c.hex & 0xFF)).withAlpha(alpha)
    }
}

/// Draws answer zones from their record and current frame (so a resized zone lays out again), leaving the score and
/// hint boxes to the canvas widgets on screen. Pure and thread-safe.
final class AnswerZoneDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {
        guard let custom = item.custom else { return }
        let zone = AnswerZone.decode(data: custom.data)
        let style: AnswerZoneLayout.Style = context.purpose == .screen ? .outline : .full
        let list = AnswerZoneLayout.displayList(zone, size: PageSize(custom.frame.w, custom.frame.h), style: style,
                                                darkPaper: context.darkPaper)
        let frame = custom.frame
        let cg = context.cg
        cg.saveGState()
        defer { cg.restoreGState() }
        if frame.rotation != 0 {
            let c = frame.center
            cg.translateBy(x: CGFloat(c.x), y: CGFloat(c.y))
            cg.rotate(by: CGFloat(frame.rotation))
            cg.translateBy(x: CGFloat(-c.x), y: CGFloat(-c.y))
        }
        list.draw(in: cg, origin: Point(frame.x, frame.y), assets: context.assets, doc: context.doc)
    }
}

// MARK: - Window routing

/// The floating host ids of the two popovers.
enum AnswerZoneUI {
    static let scorePopoverID = "teacher.answerZone.score"
    static let scoreSourceID = "teacher.answerZone.score.source"
    static let hintsPopoverID = "teacher.answerZone.hints"
    static let hintsSourceID = "teacher.answerZone.hints.source"
}

/// `teacher.answerZone.hintsShown`: a canvas tap on a zone's hint widget was handled by `answerZone.revealHint`
/// (a hint revealed, or the revealed ones peeked at). The canvas attachment of that window (`session`) shows the
/// hints card; `announce` asks it to read the newly revealed hint to VoiceOver. Never emitted by dry runs.
struct AnswerZoneHintsShownPayload: NibEventPayload, Equatable {
    static let eventType = "teacher.answerZone.hintsShown"
    /// `EditorSession.id` of the window the tap came from.
    var session: String
    /// The zone (item:D/P/I).
    var ref: String
    var announce: Bool
}

// MARK: - Live model (popovers and the inspector)

/// One answer zone as the UI shows it, kept current through commit observation (edits, undo, sync), with its
/// actions as commands.
@MainActor
final class AnswerZoneModel: ObservableObject {
    struct Total: Equatable {
        var score: Double
        var points: Double
    }

    let app: NibApp
    private(set) weak var session: EditorSession?
    let doc: DocumentID
    let page: PageID
    let id: ElementID
    @Published private(set) var zone: AnswerZone?
    /// 1-based reading-order number on the page.
    @Published private(set) var index: Int?
    /// Sum over the page's scored zones, when it has at least two with a score box.
    @Published private(set) var pageTotal: Total?
    private var subscription: EventSubscription?
    /// A run of Out of taps is one undo step.
    private var pointsGroup = NibID.make().raw

    init(app: NibApp, session: EditorSession?, doc: DocumentID, page: PageID, id: ElementID) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.id = id
        reload()
        subscription = app.bus.observeCommits { [weak self] cs in self?.observe(cs) }
    }

    deinit {
        subscription?.cancel()
    }

    var ref: String { NodeRef.item(doc, page, id).description }

    var title: String {
        zone.map { AnswerZoneFormat.name($0, index: index) } ?? String(localized: "Answer Zone")
    }

    func reload() {
        let zones = (try? AnswerZoneScope.zones(doc: doc, page: page, app.workspace)) ?? []
        let i = zones.firstIndex { $0.item.id == id }
        let current = i.map { zones[$0].zone }
        if current != zone { zone = current }
        let number = i.map { $0 + 1 }
        if number != index { index = number }
        let boxed = zones.compactMap { t -> (Double, Double)? in t.zone.points.map { (t.zone.score ?? 0, $0) } }
        let total = boxed.count >= 2 ? Total(score: boxed.reduce(0) { $0 + $1.0 }, points: boxed.reduce(0) { $0 + $1.1 }) : nil
        if total != pageTotal { pageTotal = total }
    }

    private func observe(_ cs: Changeset) {
        for m in cs.mutations {
            switch m {
            case let .item(d, p, _, _) where d == doc && p == page:
                reload()
                return
            case let .page(d, _, _) where d == doc:
                reload()
                return
            default:
                continue
            }
        }
    }

    // MARK: Actions (commands)

    func setScore(_ value: Double) {
        run(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": .number(value)])
    }

    func clearScore() {
        run(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": 0, "clear": true])
    }

    /// Changes the maximum and keeps the score within it.
    func setPoints(_ points: Double) {
        guard let zone, points > 0 else { return }
        let score = min(zone.score ?? 0, points)
        run(CommandIDs.answerZoneScore,
            ["ref": .string(ref), "score": .number(score), "points": .number(points), "clear": .bool(zone.score == nil)],
            group: pointsGroup)
    }

    func addScoreBox() {
        run(CommandIDs.answerZoneScore,
            ["ref": .string(ref), "score": 0, "points": .number(AnswerZone.defaultPoints), "clear": true])
    }

    func removeScoreBox() {
        run(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": 0, "points": 0])
    }

    func setHints(_ hints: [String]) {
        run(CommandIDs.answerZoneSetHints, ["ref": .string(ref), "hints": .array(hints.map { JSONValue.string($0) })])
    }

    func resetUsage() {
        guard let zone else { return }
        run(CommandIDs.answerZoneSetHints,
            ["ref": .string(ref), "hints": .array(zone.hints.map { JSONValue.string($0) }), "resetUsage": true])
    }

    /// Reveals the next hint; VoiceOver reads it out.
    func revealNext() {
        run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)]) { value in
            guard let hint = value["hint"]?.stringValue, let number = value["number"]?.intValue,
                  let total = value["total"]?.intValue else { return }
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "Hint \(number) of \(total): \(hint)"))
        }
    }

    private func run(_ command: String, _ params: JSONValue, group: String? = nil,
                     completion: (@MainActor (JSONValue) -> Void)? = nil) {
        // Anything but another Out of tap ends the run of taps that shares one undo step.
        if group == nil { pointsGroup = NibID.make().raw }
        let app = self.app
        let invocation = Invocation(command: command, params: params, principal: .user, session: session, group: group)
        Task { @MainActor in
            do {
                let result = try await app.bus.execute(invocation)
                completion?(result.value)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
        }
    }
}

/// Shown state of one budded popover; closing it (a tap outside, a button, Escape) folds it back into its widget.
@MainActor
final class AnswerZonePopoverState: ObservableObject {
    @Published var isPresented = false {
        didSet { if oldValue && !isPresented { onClose?() } }
    }

    var onClose: (() -> Void)?
}

// MARK: - Canvas attachment

/// The live side of answer zones on a canvas: a score widget and a hint widget per laid-out zone, placed in view points
/// over the zone's top-right corner. They are rigid water beads (DESIGN.md §10.15: precision affordances never deform),
/// recede while the Pencil is down, take the pointer's highlight and are VoiceOver elements. Both answer fingers only:
/// the Pencil always writes, over a widget too. A finger on the score widget is claimed here and opens the score
/// popover. A finger tap or long-press on the hint widget reaches `answerZone.revealHint` through
/// `content.tapHandlers`, which records the reveal and emits `teacher.answerZone.hintsShown`; this attachment then
/// shows the hints card. In a read-only window neither widget changes the document: the score is shown, not
/// offered, and the hint widget only shows the hints already revealed.
@MainActor
final class AnswerZoneAttachment: NSObject, CanvasAttachment {
    static let id = "teacher.answerZones"

    private enum PopoverKind {
        case score, hints

        var popoverID: String { self == .score ? AnswerZoneUI.scorePopoverID : AnswerZoneUI.hintsPopoverID }
        var sourceID: String { self == .score ? AnswerZoneUI.scoreSourceID : AnswerZoneUI.hintsSourceID }
    }

    private struct Shown {
        let zone: ElementID
        let state: AnswerZonePopoverState
        let model: AnswerZoneModel
    }

    private weak var host: CanvasHost?
    /// Live page ids in page order, dropped when a commit touches a page record (layout runs on every scroll frame).
    private var pageIDs: [PageID]?
    /// Zones per page (reading order), dropped when a commit touches a zone on that page.
    private var cache: [PageID: [AnswerZoneTarget]] = [:]
    /// The zones that have widgets now.
    private(set) var placed: [ElementID: AnswerZoneTarget] = [:]
    private(set) var scoreViews: [ElementID: AnswerZoneWidgetView] = [:]
    private(set) var hintViews: [ElementID: AnswerZoneWidgetView] = [:]
    private var subscriptions: [EventSubscription] = []
    private var readOnlyWatch: AnyCancellable?
    private var isReceded = false
    private var press: (zone: ElementID, start: CGPoint)?
    private var lastOpen: TimeInterval = -.infinity
    private var shown: [PopoverKind: Shown] = [:]

    // MARK: Lifecycle

    func attach(to host: CanvasHost) {
        self.host = host
        subscriptions.append(host.app.bus.observeCommits { [weak self] cs in self?.committed(cs) })
        subscriptions.append(host.session.inking.observe { [weak self] signal in self?.setReceded(signal.isInking) })
        let sessionID = host.session.id.raw
        subscriptions.append(host.app.events.subscribe { [weak self] event in
            if event.type == NibEventType.layersChanged {
                guard event.payload?["session"]?.stringValue == sessionID else { return }
                self?.layout()
            } else if let shown = event.decode(AnswerZoneHintsShownPayload.self), shown.session == sessionID {
                self?.hintsShown(shown)
            }
        })
        // `@Published` fires before the value changes: lay out (traits, hints) once it has.
        readOnlyWatch = host.session.$readOnly.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.layout()
        }
        layout()
    }

    func detach(from host: CanvasHost) {
        for s in subscriptions { s.cancel() }
        subscriptions = []
        readOnlyWatch = nil
        for kind in [PopoverKind.score, .hints] { dismissNow(kind, host: host) }
        for v in Array(scoreViews.values) + Array(hintViews.values) { v.removeFromSuperview() }
        scoreViews = [:]
        hintViews = [:]
        placed = [:]
        cache = [:]
        pageIDs = nil
        press = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) { layout() }

    private func committed(_ cs: Changeset) {
        guard let host else { return }
        var dirty = false
        for m in cs.mutations where m.document == host.documentID {
            switch m {
            case let .item(_, page, before, after):
                if AnswerZone.isZone(after) || (before.map(AnswerZone.isZone) ?? false) {
                    cache[page] = nil
                    dirty = true
                }
            case .page:
                cache = [:]
                pageIDs = nil
                dirty = true
            default:
                break
            }
        }
        if dirty { layout() }
    }

    private func zones(on page: PageID, host: CanvasHost) -> [AnswerZoneTarget] {
        if let cached = cache[page] { return cached }
        let found = (try? AnswerZoneScope.zones(doc: host.documentID, page: page, host.app.workspace)) ?? []
        cache[page] = found
        return found
    }

    private func livePageIDs(_ host: CanvasHost) -> [PageID] {
        if let ids = pageIDs { return ids }
        let ids = ((try? host.app.workspace.content(host.documentID).livePages) ?? []).map(\.id)
        pageIDs = ids
        return ids
    }

    // MARK: Layout

    /// Places the widgets of every zone on a laid-out page near the visible area; removes the rest.
    func layout() {
        guard let host else { return }
        let visible = host.canvasView.bounds.insetBy(dx: -NibMetrics.hitTarget, dy: -NibMetrics.hitTarget)
        let zoom = host.zoomScale
        let hiddenLayers = host.session.hiddenLayers
        let editable = canEdit(host)
        var nextPlaced: [ElementID: AnswerZoneTarget] = [:]
        var scored = Set<ElementID>(), hinted = Set<ElementID>()
        for page in livePageIDs(host) {
            guard let pageFrame = host.pageFrame(page), pageFrame.intersects(visible) else { continue }
            for (i, target) in zones(on: page, host: host).enumerated() where !hiddenLayers.contains(target.item.layer) {
                let id = target.item.id
                let zone = target.zone
                let slots = AnswerZoneLayout.slots(zoneBounds: target.item.bounds, zoom: zoom,
                                                   hasScore: zone.points != nil, hasHints: !zone.hints.isEmpty)
                let name = AnswerZoneFormat.name(zone, index: i + 1)
                if let slot = slots.score {
                    let rect = viewRect(slot, page: page, host: host)
                    if rect.intersects(visible) {
                        let view = widget(id, in: &scoreViews)
                        place(view, rect: rect)
                        configureScore(view, id: id, zone: zone, name: name, editable: editable)
                        scored.insert(id)
                    }
                }
                if let slot = slots.hint {
                    let rect = viewRect(slot, page: page, host: host)
                    if rect.intersects(visible) {
                        let view = widget(id, in: &hintViews)
                        place(view, rect: rect)
                        configureHint(view, id: id, zone: zone, name: name, editable: editable)
                        hinted.insert(id)
                    }
                }
                if scored.contains(id) || hinted.contains(id) { nextPlaced[id] = target }
            }
        }
        for id in Set(scoreViews.keys).subtracting(scored) { scoreViews.removeValue(forKey: id)?.removeFromSuperview() }
        for id in Set(hintViews.keys).subtracting(hinted) { hintViews.removeValue(forKey: id)?.removeFromSuperview() }
        placed = nextPlaced
        followAnchors(host)
    }

    private func viewRect(_ r: Rect, page: PageID, host: CanvasHost) -> CGRect {
        let a = host.viewPoint(Point(r.minX, r.minY), page: page)
        let b = host.viewPoint(Point(r.maxX, r.maxY), page: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func widget(_ id: ElementID, in views: inout [ElementID: AnswerZoneWidgetView]) -> AnswerZoneWidgetView {
        if let v = views[id] { return v }
        let v = AnswerZoneWidgetView(frame: .zero)
        views[id] = v
        return v
    }

    private func place(_ view: AnswerZoneWidgetView, rect: CGRect) {
        if view.superview == nil { host?.canvasView.addSubview(view) }
        // Widgets keep their screen size at every zoom (page-to-view rounding would make it 31.99…).
        view.bounds = CGRect(x: 0, y: 0, width: AnswerZoneLayout.widgetWidth, height: AnswerZoneLayout.widgetHeight)
        view.center = CGPoint(x: rect.midX, y: rect.midY)
        view.alpha = isReceded ? NibOpacity.recede : 1
    }

    /// Editable: VoiceOver adjusts the score; read-only: the score is read out, nothing more.
    private func configureScore(_ view: AnswerZoneWidgetView, id: ElementID, zone: AnswerZone, name: String,
                                editable: Bool) {
        view.configure(text: AnswerZoneFormat.score(zone) ?? "", symbol: nil,
                       label: String(localized: "Score, \(name)"), value: AnswerZoneFormat.scoreValue(zone),
                       hint: editable ? String(localized: "Opens the score. Swipe up or down to change it.") : nil,
                       tooltip: String(localized: "Score"))
        view.role = editable ? .adjustable : .text
        view.activate = editable ? { [weak self] in self?.presentScore(id) } : nil
        view.increment = editable ? { [weak self] in self?.step(id, by: 1) } : nil
        view.decrement = editable ? { [weak self] in self?.step(id, by: -1) } : nil
        view.actions = editable && zone.score != nil
            ? [(String(localized: "Clear Score"), { [weak self] in self?.clearScore(id) })] : []
    }

    /// Editable: activating reveals the next hint (as a finger tap does); read-only: it shows the revealed ones.
    private func configureHint(_ view: AnswerZoneWidgetView, id: ElementID, zone: AnswerZone, name: String,
                               editable: Bool) {
        let reveals = editable && zone.remainingHints > 0
        view.configure(text: "\(zone.revealed)/\(zone.hints.count)", symbol: .eye,
                       label: String(localized: "Hints, \(name)"), value: AnswerZoneFormat.hintsShown(zone),
                       hint: reveals ? String(localized: "Shows the next hint. Hints you open are recorded.") : nil,
                       tooltip: reveals ? String(localized: "Show Next Hint") : String(localized: "Show Hints"))
        view.role = .button
        view.activate = { [weak self] in self?.activateHint(id) }
        view.increment = nil
        view.decrement = nil
        view.actions = editable && zone.revealed > 0
            ? [(String(localized: "Show Hints"), { [weak self] in self?.peekHints(id) })] : []
    }

    private func setReceded(_ receded: Bool) {
        guard receded != isReceded else { return }
        isReceded = receded
        // Instant: nothing moves or fades while the Pencil is down (DESIGN.md §10.8).
        for v in Array(scoreViews.values) + Array(hintViews.values) { v.alpha = receded ? NibOpacity.recede : 1 }
    }

    // MARK: Touches (the score widget)

    /// False in a read-only window or document: the widgets then never write.
    private func canEdit(_ host: CanvasHost) -> Bool {
        !host.session.readOnly && !host.app.isReadOnly(host.documentID)
    }

    func scoreZone(at viewPoint: CGPoint) -> ElementID? {
        scoreViews.first { !$0.value.isHidden && $0.value.hitFrame.contains(viewPoint) }?.key
    }

    /// Fingers only, like the hint widget (tap handlers are finger taps): a Pencil touch on a widget writes.
    func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool {
        !isPencil && canEdit(host) && scoreZone(at: viewPoint) != nil
    }

    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {
        let p = host.viewPoint(sample.location, page: sample.page)
        guard let id = scoreZone(at: p) else { return }
        press = (id, p)
        scoreViews[id]?.setPressed(true)
    }

    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {
        guard let current = press, let last = samples.last(where: { !$0.isPredicted }) else { return }
        let p = host.viewPoint(last.location, page: last.page)
        if hypot(p.x - current.start.x, p.y - current.start.y) > NibSpacing.s {
            scoreViews[current.zone]?.setPressed(false)
            press = nil
        }
    }

    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {
        guard let current = press else { return }
        press = nil
        scoreViews[current.zone]?.setPressed(false)
        openScoreOnce(current.zone)
    }

    func touchesCancelled(host: CanvasHost) {
        if let current = press { scoreViews[current.zone]?.setPressed(false) }
        press = nil
    }

    /// Taps on the score widget are the widget's: they never reach the tap handlers or the tool below it.
    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool {
        let p = host.viewPoint(sample.location, page: sample.page)
        guard canEdit(host), let id = scoreZone(at: p) else { return false }
        if gesture == .tap { openScoreOnce(id) }
        return true
    }

    /// The canvas may report one tap both as touches and as a gesture: open once.
    private func openScoreOnce(_ id: ElementID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastOpen > NibMotion.budRevealDelay else { return }
        lastOpen = now
        presentScore(id)
    }

    // MARK: Score

    func presentScore(_ id: ElementID) {
        guard let host, canEdit(host), let target = placed[id], let view = scoreViews[id] else { return }
        if let current = shown[.score], current.zone == id, current.state.isPresented {
            current.state.isPresented = false
            return
        }
        dismissNow(.score, host: host)
        close(.hints)
        let model = AnswerZoneModel(app: host.app, session: host.session, doc: target.doc, page: target.page, id: id)
        guard let floating = host.session.floatingHost,
              floating.setAnchor(AnswerZoneUI.scoreSourceID, rect: view.restingFrame, in: host.canvasView) else {
            presentScoreSheet(model, from: view, host: host)
            return
        }
        let state = AnswerZonePopoverState()
        state.onClose = { [weak self, weak state] in
            guard let self, let state else { return }
            self.finishClose(.score, state: state)
        }
        shown[.score] = Shown(zone: id, state: state, model: model)
        floating.present(AnswerZoneUI.scorePopoverID) { AnswerZoneScorePopover(state: state, model: model) }
        state.isPresented = true
    }

    /// No floating host (a window without the document chrome): the system action sheet.
    private func presentScoreSheet(_ model: AnswerZoneModel, from view: AnswerZoneWidgetView, host: CanvasHost) {
        guard let zone = model.zone, let points = zone.points, let presenter = presenter(for: host.canvasView) else { return }
        let sheet = UIAlertController(title: String(localized: "Score"), message: model.title, preferredStyle: .actionSheet)
        let top = points.rounded(.down)
        if top <= 20 {
            for v in stride(from: 0.0, through: top, by: 1) {
                sheet.addAction(UIAlertAction(title: AnswerZoneFormat.number(v), style: .default) { _ in model.setScore(v) })
            }
        } else {
            sheet.addAction(UIAlertAction(title: String(localized: "Full Marks"), style: .default) { _ in model.setScore(points) })
            sheet.addAction(UIAlertAction(title: AnswerZoneFormat.number(0), style: .default) { _ in model.setScore(0) })
        }
        if zone.score != nil {
            sheet.addAction(UIAlertAction(title: String(localized: "Clear Score"), style: .destructive) { _ in model.clearScore() })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = host.canvasView
        sheet.popoverPresentationController?.sourceRect = view.restingFrame
        presenter.present(sheet, animated: true)
    }

    /// VoiceOver adjust: unscored steps to 0, then one point at a time within the box.
    private func step(_ id: ElementID, by delta: Double) {
        guard let host, canEdit(host), let target = placed[id], let points = target.zone.points else { return }
        let next = target.zone.score.map { min(max($0 + delta, 0), points) } ?? 0
        guard next != target.zone.score else { return }
        AnswerZoneModel(app: host.app, session: host.session, doc: target.doc, page: target.page, id: id).setScore(next)
    }

    private func clearScore(_ id: ElementID) {
        guard let host, canEdit(host), let target = placed[id] else { return }
        AnswerZoneModel(app: host.app, session: host.session, doc: target.doc, page: target.page, id: id).clearScore()
    }

    // MARK: Hints

    /// `answerZone.revealHint` handled a finger on this window's hint widget.
    private func hintsShown(_ event: AnswerZoneHintsShownPayload) {
        guard case let .item(doc, page, id)? = NodeRef(event.ref) else { return }
        presentHints(doc: doc, page: page, zone: id, announce: event.announce)
    }

    /// The hints card buds from the widget and shows every hint revealed so far (Show Next Hint only where the
    /// document can change).
    func presentHints(doc: DocumentID, page: PageID, zone id: ElementID, announce: Bool) {
        guard let host, doc == host.documentID else { return }
        cache[page] = nil
        layout()
        let model = AnswerZoneModel(app: host.app, session: host.session, doc: doc, page: page, id: id)
        if announce, let zone = model.zone, zone.revealed > 0 {
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "Hint \(zone.revealed) of \(zone.hints.count): \(zone.hints[zone.revealed - 1])"))
        }
        if let current = shown[.hints], current.zone == id, current.state.isPresented { return }
        guard let view = hintViews[id] else { return }
        dismissNow(.hints, host: host)
        close(.score)
        let canReveal = canEdit(host)
        guard let floating = host.session.floatingHost,
              floating.setAnchor(AnswerZoneUI.hintsSourceID, rect: view.restingFrame, in: host.canvasView) else {
            presentHintsAlert(model, canReveal: canReveal, host: host)
            return
        }
        let state = AnswerZonePopoverState()
        state.onClose = { [weak self, weak state] in
            guard let self, let state else { return }
            self.finishClose(.hints, state: state)
        }
        shown[.hints] = Shown(zone: id, state: state, model: model)
        floating.present(AnswerZoneUI.hintsPopoverID) {
            AnswerZoneHintsCard(state: state, model: model, canReveal: canReveal)
        }
        state.isPresented = true
    }

    private func presentHintsAlert(_ model: AnswerZoneModel, canReveal: Bool, host: CanvasHost) {
        guard let zone = model.zone, let presenter = presenter(for: host.canvasView) else { return }
        let lines = zone.revealedHints.enumerated().map { String(localized: "Hint \($0.offset + 1): \($0.element)") }
        let message = lines.isEmpty ? String(localized: "No hints shown yet.") : lines.joined(separator: "\n\n")
        let alert = UIAlertController(title: String(localized: "Hints"), message: message, preferredStyle: .alert)
        if canReveal && zone.remainingHints > 0 {
            alert.addAction(UIAlertAction(title: String(localized: "Show Next Hint"), style: .default) { [weak self] _ in
                model.revealNext()
                self?.cache[model.page] = nil
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// VoiceOver double-tap on the hint widget: what a finger tap does in this window.
    private func activateHint(_ id: ElementID) {
        guard let host else { return }
        if canEdit(host) { revealFromAccessibility(id) } else { peekHints(id) }
    }

    private func revealFromAccessibility(_ id: ElementID) {
        guard let host, let target = placed[id] else { return }
        let app = host.app, session = host.session
        let invocation = Invocation(command: CommandIDs.answerZoneRevealHint, params: ["ref": .string(target.ref)],
                                    principal: .user, session: session)
        Task { @MainActor [weak self] in
            do {
                let result = try await app.bus.execute(invocation)
                self?.presentHints(doc: target.doc, page: target.page, zone: id, announce: result.value["hint"]?.stringValue != nil)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": CommandIDs.answerZoneRevealHint, "error": NibError.wrap(error)])
            }
        }
    }

    private func peekHints(_ id: ElementID) {
        guard let target = placed[id] else { return }
        presentHints(doc: target.doc, page: target.page, zone: id, announce: false)
    }

    // MARK: Popover bookkeeping

    /// Keeps open popovers budded from their widgets while the page scrolls; a widget that left the screen closes its
    /// popover.
    private func followAnchors(_ host: CanvasHost) {
        guard let floating = host.session.floatingHost else { return }
        for (kind, current) in shown where current.state.isPresented {
            let view = kind == .score ? scoreViews[current.zone] : hintViews[current.zone]
            if let view, floating.setAnchor(kind.sourceID, rect: view.restingFrame, in: host.canvasView) { continue }
            current.state.isPresented = false
        }
    }

    private func close(_ kind: PopoverKind) {
        shown[kind]?.state.isPresented = false
    }

    /// After the fold-back, the popover leaves the floating host (unless a newer one of the same kind replaced it).
    private func finishClose(_ kind: PopoverKind, state: AnswerZonePopoverState) {
        guard let floating = host?.session.floatingHost else { return }
        let delay = UInt64(NibMotion.bud.response * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !state.isPresented, self.shown[kind]?.state === state else { return }
            self.shown[kind] = nil
            floating.dismiss(kind.popoverID)
            floating.removeAnchor(kind.sourceID)
        }
    }

    private func dismissNow(_ kind: PopoverKind, host: CanvasHost) {
        guard let current = shown.removeValue(forKey: kind) else { return }
        current.state.onClose = nil
        current.state.isPresented = false
        host.session.floatingHost?.dismiss(kind.popoverID)
        host.session.floatingHost?.removeAnchor(kind.sourceID)
    }

    private func presenter(for view: UIView) -> UIViewController? {
        var vc = view.window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }
}

// MARK: - Widget view

/// A rigid capsule on the page (score or hints), drawn with the water tokens the way `NibHandleView` draws its beads:
/// the Clear body over paper (chromeOpaque under Reduce Transparency) with the resting elevation, then the water rim
/// and the 0.8 pt water line, which `NibFrameView` draws (its rounded rect is clamped to a capsule at this height). It
/// never stretches or wobbles; a press scales it like every Nib button. The attachment positions it; the view draws,
/// highlights under the pointer and is one VoiceOver element.
///
/// NibDesign has no labelled rigid canvas capsule; this view is a stand-in until one exists (contract request: a
/// `NibHandleView` capsule style with a label and a glyph), and is then swapped for it.
final class AnswerZoneWidgetView: UIView, UIPointerInteractionDelegate {
    enum Role {
        /// Activates (the hint widget).
        case button
        /// Activates and adjusts (the score widget where the document can change).
        case adjustable
        /// Read out only (the score in a read-only window).
        case text
    }

    /// The press scale of every Nib button (`NibPressStyle`, DESIGN.md §10).
    static let pressScale: CGFloat = 0.96

    private let body = CAShapeLayer()
    private let water = NibFrameView(frame: .zero)
    private let label = UILabel()
    private let glyph = UIImageView()
    private let tip = UIToolTipInteraction()
    private var symbol: NibSymbol?

    var activate: (() -> Void)?
    var increment: (() -> Void)?
    var decrement: (() -> Void)?
    /// VoiceOver custom actions (name, handler).
    var actions: [(String, () -> Void)] = [] {
        didSet {
            accessibilityCustomActions = actions.map { entry in
                UIAccessibilityCustomAction(name: entry.0) { _ in
                    entry.1()
                    return true
                }
            }
        }
    }

    var role: Role = .button {
        didSet {
            switch role {
            case .button: accessibilityTraits = [.button]
            case .adjustable: accessibilityTraits = [.button, .adjustable]
            case .text: accessibilityTraits = [.staticText]
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: frame.minX, y: frame.minY, width: AnswerZoneLayout.widgetWidth,
                                 height: AnswerZoneLayout.widgetHeight))
        setUp()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setUp() {
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(body)
        water.isUserInteractionEnabled = false
        addSubview(water)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.isAccessibilityElement = false
        glyph.contentMode = .center
        glyph.isAccessibilityElement = false
        addSubview(glyph)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        addInteraction(UIPointerInteraction(delegate: self))
        addInteraction(tip)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitPreferredContentSizeCategory.self]) { (view: AnswerZoneWidgetView, _: UITraitCollection) in
            view.updateAppearance()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(transparencyChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        updateAppearance()
    }

    func configure(text: String, symbol: NibSymbol?, label a11yLabel: String, value: String, hint: String?, tooltip: String) {
        if label.text != text { label.text = text }
        if self.symbol != symbol {
            self.symbol = symbol
            glyph.image = symbol.flatMap { UIImage(nib: $0) }
        }
        accessibilityLabel = a11yLabel
        accessibilityValue = value
        accessibilityHint = hint
        tip.defaultToolTip = tooltip
        setNeedsLayout()
    }

    /// The label's text (tests).
    var text: String? { label.text }

    /// The frame without the press scale, in the superview's coordinates.
    var restingFrame: CGRect {
        CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2, width: bounds.width, height: bounds.height)
    }

    /// The touch area in the superview's coordinates: at least 44 points each way.
    var hitFrame: CGRect {
        let r = restingFrame
        return r.insetBy(dx: min(0, (r.width - NibMetrics.hitTarget) / 2), dy: min(0, (r.height - NibMetrics.hitTarget) / 2))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: min(0, (bounds.width - NibMetrics.hitTarget) / 2),
                       dy: min(0, (bounds.height - NibMetrics.hitTarget) / 2)).contains(point)
    }

    func setPressed(_ pressed: Bool) {
        NibMotion.animateUIKit(NibMotion.tap, animations: {
            self.transform = pressed ? CGAffineTransform(scaleX: Self.pressScale, y: Self.pressScale) : .identity
        })
    }

    @objc private func transparencyChanged() {
        updateAppearance()
    }

    private func updateAppearance() {
        let traits = traitCollection
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        // Numbers on water use the HUD type (DESIGN.md §2.4 lists HUD numbers among the small-text exceptions). The
        // widget keeps its size over the page, so Dynamic Type stops at the role's default size.
        let font = NibUIFont.hud
        let cap = CGFloat(AnswerZoneLayout.scoreTextSize)
        label.font = font.pointSize > cap ? font.withSize(cap) : font
        label.textColor = NibUIColor.label
        glyph.preferredSymbolConfiguration = NibUIFont.glyph(.bar)
        glyph.tintColor = NibUIColor.label
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.fillColor = (opaque ? NibUIColor.chromeOpaque : NibUIColor.clearBodyOnPaper).resolvedColor(with: traits).cgColor
        CATransaction.commit()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: NibRadius.capsule(bounds.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = shape.cgPath
        body.nibElevation(.rest, path: shape.cgPath, dark: traitCollection.userInterfaceStyle == .dark)
        CATransaction.commit()
        water.frame = bounds
        let content = bounds.insetBy(dx: NibSpacing.s, dy: 0)
        guard glyph.image != nil else {
            glyph.frame = .zero
            label.frame = content
            return
        }
        let g = glyph.intrinsicContentSize
        let gap = NibSpacing.xs
        let textWidth = max(0, min(label.intrinsicContentSize.width, content.width - g.width - gap))
        var x = content.midX - (g.width + gap + textWidth) / 2
        glyph.frame = CGRect(x: x, y: bounds.midY - g.height / 2, width: g.width, height: g.height)
        x += g.width + gap
        label.frame = CGRect(x: x, y: 0, width: textWidth, height: bounds.height)
    }

    override func accessibilityActivate() -> Bool {
        guard let activate else { return role == .text }
        activate()
        return true
    }

    override func accessibilityIncrement() { increment?() }
    override func accessibilityDecrement() { decrement?() }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        UIPointerRegion(rect: bounds)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: NibRadius.capsule(bounds.height))
        return UIPointerStyle(effect: .highlight(UITargetedPreview(view: self, parameters: parameters)))
    }
}

// MARK: - Popovers (SwiftUI, in the window's droplet container)

/// The score popover budded from a zone's score widget.
struct AnswerZoneScorePopover: View {
    @ObservedObject var state: AnswerZonePopoverState
    @ObservedObject var model: AnswerZoneModel

    var body: some View {
        NibBudPopover(id: AnswerZoneUI.scorePopoverID, source: AnswerZoneUI.scoreSourceID, isPresented: $state.isPresented,
                      title: String(localized: "Score"), subtitle: model.title, placement: .below) {
            AnswerZoneScoreEditor(model: model) { state.isPresented = false }
        }
    }
}

/// Score chips 0 to the maximum, the maximum itself, and clearing or removing the score box. Shared by the score
/// popover and the inspector.
struct AnswerZoneScoreEditor: View {
    @ObservedObject var model: AnswerZoneModel
    /// Called after a score was picked (the popover folds away).
    var onScored: (() -> Void)?

    /// Up to this many points the score is a row of chips; above it, a stepper.
    private static let chipLimit: Double = 20

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if let zone = model.zone, let points = zone.points {
                if points <= Self.chipLimit && points == points.rounded() {
                    chips(zone, points: points)
                } else {
                    scoreStepper(zone, points: points)
                }
                pointsRow(points)
                HStack(spacing: NibSpacing.s) {
                    NibButton(String(localized: "Clear Score"), kind: .plain, size: .compact) {
                        model.clearScore()
                        onScored?()
                    }
                    .disabled(zone.score == nil)
                    Spacer(minLength: NibSpacing.s)
                    NibButton(String(localized: "Remove Score Box"), kind: .destructivePlain, size: .compact) {
                        model.removeScoreBox()
                        onScored?()
                    }
                }
                if let total = model.pageTotal {
                    Text(String(localized: "Page total \(AnswerZoneFormat.number(total.score)) of \(AnswerZoneFormat.number(total.points))"))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            } else if model.zone != nil {
                Text(String(localized: "This answer zone has no score box."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                NibButton(String(localized: "Add Score Box"), kind: .secondary, size: .compact) { model.addScoreBox() }
            } else {
                Text(String(localized: "This answer zone is no longer on the page."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
    }

    private func chips(_ zone: AnswerZone, points: Double) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.hitTarget), spacing: NibSpacing.s)],
                  alignment: .leading, spacing: NibSpacing.s) {
            ForEach(0...Int(points), id: \.self) { n in
                let value = Double(n)
                let selected = zone.score == value
                NibChip(AnswerZoneFormat.number(value), style: .filter(isSelected: selected), action: {
                    model.setScore(value)
                    onScored?()
                })
                .accessibilityLabel(String(localized: "\(AnswerZoneFormat.number(value)) points"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func scoreStepper(_ zone: AnswerZone, points: Double) -> some View {
        let score = zone.score ?? 0
        return NibInspectorRow(String(localized: "Score")) {
            HStack(spacing: 0) {
                NibIconButton(.minus, label: String(localized: "Lower Score"), size: .panel) {
                    model.setScore(max(0, score - 1))
                }
                .disabled(zone.score == nil || score <= 0)
                Text(zone.score.map(AnswerZoneFormat.number) ?? "\u{2013}")
                    .font(NibFont.hud)
                    .foregroundStyle(NibColor.label)
                    .frame(minWidth: NibSpacing.x3)
                NibIconButton(.plus, label: String(localized: "Raise Score"), size: .panel) {
                    model.setScore(zone.score == nil ? 0 : min(points, score + 1))
                }
                .disabled(score >= points)
            }
        }
    }

    private func pointsRow(_ points: Double) -> some View {
        NibInspectorRow(String(localized: "Out of")) {
            HStack(spacing: 0) {
                NibIconButton(.minus, label: String(localized: "Fewer Points"), size: .panel) {
                    model.setPoints(max(1, (points - 1).rounded(.up)))
                }
                .disabled(points <= 1)
                Text(AnswerZoneFormat.number(points))
                    .font(NibFont.hud)
                    .foregroundStyle(NibColor.label)
                    .frame(minWidth: NibSpacing.x3)
                    .accessibilityLabel(String(localized: "Out of \(AnswerZoneFormat.number(points)) points"))
                NibIconButton(.plus, label: String(localized: "More Points"), size: .panel) {
                    model.setPoints(min(AnswerZone.maxPoints, (points + 1).rounded(.down)))
                }
                .disabled(points >= AnswerZone.maxPoints)
            }
        }
    }
}

/// The hints card budded from a zone's hint widget: every hint revealed so far, newest last, and the next one on
/// request. It says that opened hints are recorded, so the record is never a surprise. Where the document cannot
/// change (a read-only window or document) it only shows what is revealed.
struct AnswerZoneHintsCard: View {
    @ObservedObject var state: AnswerZonePopoverState
    @ObservedObject var model: AnswerZoneModel
    var canReveal = true

    var body: some View {
        NibBudPopover(id: AnswerZoneUI.hintsPopoverID, source: AnswerZoneUI.hintsSourceID, isPresented: $state.isPresented,
                      title: String(localized: "Hints"), subtitle: model.zone.map(AnswerZoneFormat.hintsShown),
                      placement: .below) {
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                if let zone = model.zone {
                    if zone.revealed == 0 {
                        Text(String(localized: "No hints shown yet."))
                            .font(NibFont.footnote)
                            .foregroundStyle(NibColor.labelSecondary)
                    }
                    ForEach(Array(zone.revealedHints.enumerated()), id: \.offset) { entry in
                        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                            Text(String(localized: "Hint \(entry.offset + 1)"))
                                .font(NibFont.footnoteEmphasis)
                                .foregroundStyle(NibColor.labelSecondary)
                            Text(entry.element)
                                .font(NibFont.body)
                                .foregroundStyle(NibColor.label)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if zone.remainingHints > 0 && canReveal {
                        NibButton(String(localized: "Show Next Hint"), symbol: .eye, kind: .primary, expands: true) {
                            model.revealNext()
                        }
                    } else if zone.remainingHints == 0 && !zone.hints.isEmpty {
                        Text(String(localized: "That was the last hint."))
                            .font(NibFont.footnote)
                            .foregroundStyle(NibColor.labelSecondary)
                    }
                    if canReveal {
                        Text(String(localized: "Each hint you open is recorded for your teacher."))
                            .font(NibFont.caption1)
                            .foregroundStyle(NibColor.labelSecondary)
                    } else {
                        Text(String(localized: "This document is read-only, so no more hints can be opened here."))
                            .font(NibFont.caption1)
                            .foregroundStyle(NibColor.labelSecondary)
                    }
                } else {
                    Text(String(localized: "This answer zone is no longer on the page."))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
        }
    }
}

// MARK: - Inspector (object menu › Style, for selected answer zones)

struct AnswerZoneInspector: View {
    let context: InspectorContext

    var body: some View {
        let zones = context.items.filter(AnswerZone.isZone)
        if zones.count == 1, let item = zones.first {
            AnswerZoneEditor(app: context.app, session: context.session, doc: context.doc, page: context.page, id: item.id)
                .id(item.id)
        } else {
            AnswerZoneBulkEditor(context: context, zones: zones)
        }
    }
}

/// One hint being edited (stable identity, so fields keep focus while others are added or removed).
struct AnswerZoneHintDraft: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// Everything about one zone: the score box, the hints (edited in place, saved when a field loses focus), and the
/// record of hints students opened. Hints a student has not opened yet stay folded behind Edit Hints, so selecting a
/// zone is not a way to read them; resetting the record asks first, inline.
struct AnswerZoneEditor: View {
    @StateObject private var model: AnswerZoneModel
    @State private var drafts: [AnswerZoneHintDraft] = []
    @State private var showsUnopenedHints = false
    @State private var confirmsReset = false
    @FocusState private var focused: UUID?

    /// Usage rows listed (newest first); the rest are counted.
    private static let usageRows = 20

    init(app: NibApp, session: EditorSession, doc: DocumentID, page: PageID, id: ElementID) {
        _model = StateObject(wrappedValue: AnswerZoneModel(app: app, session: session, doc: doc, page: page, id: id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            if let zone = model.zone {
                NibInspectorSection(String(localized: "Score"), value: AnswerZoneFormat.score(zone)) {
                    AnswerZoneScoreEditor(model: model)
                }
                NibInspectorSection(String(localized: "Hints"),
                                    value: zone.hints.isEmpty ? nil : AnswerZoneFormat.hintsShown(zone),
                                    action: drafts.count < AnswerZone.maxHints ? NibAction(String(localized: "Add Hint")) { addHint() } : nil) {
                    hintFields(zone)
                }
                if !zone.usage.isEmpty {
                    NibInspectorSection(String(localized: "Hint Usage"),
                                        action: confirmsReset ? nil : NibAction(String(localized: "Reset Hint Usage")) { confirmsReset = true }) {
                        if confirmsReset { resetConfirmation }
                        usageRows(zone)
                    }
                }
            } else {
                Text(String(localized: "This answer zone is no longer on the page."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .onAppear { drafts = (model.zone?.hints ?? []).map { AnswerZoneHintDraft(text: $0) } }
        .onChange(of: focused) { old, new in
            if old != nil && new != old { commitHints() }
        }
        .onChange(of: model.zone?.hints ?? []) { _, hints in
            // Undo, another window or the assistant changed them: show theirs unless a field is being edited.
            if focused == nil && hints != cleaned(drafts) { drafts = hints.map { AnswerZoneHintDraft(text: $0) } }
        }
        .onDisappear { commitHints() }
    }

    /// The drafts shown: all of them once Edit Hints was chosen, else only the hints students have opened.
    private func visibleDrafts(_ zone: AnswerZone) -> [AnswerZoneHintDraft] {
        showsUnopenedHints ? drafts : Array(drafts.prefix(zone.revealed))
    }

    private func hintFields(_ zone: AnswerZone) -> some View {
        let visible = visibleDrafts(zone)
        let folded = drafts.count - visible.count
        return VStack(alignment: .leading, spacing: NibSpacing.s) {
            if drafts.isEmpty {
                Text(String(localized: "Students open hints one at a time from the hint button on the zone. Each one they open is recorded."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(visible) { draft in
                let number = (drafts.firstIndex { $0.id == draft.id } ?? 0) + 1
                HStack(alignment: .top, spacing: NibSpacing.s) {
                    NibField(text: text(of: draft.id), prompt: String(localized: "Hint \(number)"), lines: 1...4)
                        .focused($focused, equals: draft.id)
                        .accessibilityLabel(String(localized: "Hint \(number)"))
                    NibIconButton(.trash, label: String(localized: "Remove Hint \(number)"), size: .panel) {
                        remove(draft.id)
                    }
                }
            }
            if folded > 0 {
                Text(String(localized: "Hints not opened yet: \(folded)"))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                NibButton(String(localized: "Edit Hints"), kind: .secondary, size: .compact) { showsUnopenedHints = true }
            }
        }
    }

    private var resetConfirmation: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(String(localized: "Forget which hints were opened? The hints stay, and every one of them is hidden again."))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "Reset Hint Usage"), kind: .destructive, size: .compact) {
                    confirmsReset = false
                    model.resetUsage()
                }
                NibButton(String(localized: "Cancel"), kind: .plain, size: .compact) { confirmsReset = false }
            }
        }
    }

    @ViewBuilder
    private func usageRows(_ zone: AnswerZone) -> some View {
        let recent = Array(zone.usage.suffix(Self.usageRows).reversed())
        ForEach(Array(recent.enumerated()), id: \.offset) { entry in
            NibInspectorRow(AnswerZoneFormat.usedHint(entry.element), subtitle: usageLine(entry.element))
        }
        if zone.usage.count > recent.count {
            Text(String(localized: "Earlier openings: \(zone.usage.count - recent.count)"))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
        }
    }

    private func usageLine(_ use: AnswerZone.HintUse) -> String {
        let when = Date(timeIntervalSince1970: use.at).formatted(date: .abbreviated, time: .shortened)
        let who = NibPrincipalKind(Principal(string: use.by)).title
        return String(localized: "Opened \(when) by \(who)")
    }

    private func text(of id: UUID) -> Binding<String> {
        Binding(get: { drafts.first { $0.id == id }?.text ?? "" },
                set: { value in
                    if let i = drafts.firstIndex(where: { $0.id == id }) { drafts[i].text = value }
                })
    }

    private func cleaned(_ drafts: [AnswerZoneHintDraft]) -> [String] {
        drafts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func addHint() {
        let draft = AnswerZoneHintDraft(text: "")
        showsUnopenedHints = true
        drafts.append(draft)
        focused = draft.id
    }

    private func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        if focused == id { focused = nil }
        commitHints()
    }

    private func commitHints() {
        guard let zone = model.zone else { return }
        let hints = cleaned(drafts)
        guard hints != zone.hints else { return }
        model.setHints(hints)
    }
}

/// Several answer zones selected: clear their scores or their hint record in one undo step (`commands.batch`); the
/// reset asks first, inline.
struct AnswerZoneBulkEditor: View {
    let context: InspectorContext
    let zones: [Item]
    @State private var confirmsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            Text(String(localized: "\(zones.count) answer zones selected"))
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
            NibButton(String(localized: "Clear Scores"), kind: .secondary, size: .compact) {
                batch(zones.filter { AnswerZone.decode($0)?.score != nil }.map { item -> JSONValue in
                    ["command": .string(CommandIDs.answerZoneScore),
                     "params": ["ref": .string(ref(item)), "score": 0, "clear": true]]
                })
            }
            .disabled(!zones.contains { AnswerZone.decode($0)?.score != nil })
            if confirmsReset {
                Text(String(localized: "Forget which hints were opened in these zones? The hints stay, and every one of them is hidden again."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: NibSpacing.s) {
                    NibButton(String(localized: "Reset Hint Usage"), kind: .destructive, size: .compact) {
                        confirmsReset = false
                        resetUsage()
                    }
                    NibButton(String(localized: "Cancel"), kind: .plain, size: .compact) { confirmsReset = false }
                }
            } else {
                NibButton(String(localized: "Reset Hint Usage"), kind: .secondary, size: .compact) { confirmsReset = true }
                    .disabled(!zones.contains { AnswerZone.decode($0).map { !$0.usage.isEmpty || $0.revealed > 0 } ?? false })
            }
        }
    }

    private func resetUsage() {
        batch(zones.compactMap { item -> JSONValue? in
            guard let zone = AnswerZone.decode(item), !zone.usage.isEmpty || zone.revealed > 0 else { return nil }
            return ["command": .string(CommandIDs.answerZoneSetHints),
                    "params": ["ref": .string(ref(item)), "hints": .array(zone.hints.map { JSONValue.string($0) }),
                               "resetUsage": true]]
        })
    }

    private func ref(_ item: Item) -> String { NodeRef.item(context.doc, context.page, item.id).description }

    private func batch(_ calls: [JSONValue]) {
        guard !calls.isEmpty else { return }
        context.app.perform(CommandIDs.batch, ["calls": .array(calls)], session: context.session)
    }
}
