import Foundation
import NibContracts

// The "planner.events" paper template (D-036, S-059): a daily or weekly planner page (Monday or Sunday start) that
// draws the events Nib last read from the calendar: an all-day area, a timeline where overlapping events share the
// width in columns, and each event's answer (accepted, maybe, invited, declined). It never calls EventKit: it reads
// `CalendarEventCache` on render threads, and the page's sync button (`calendar.events` for the page's dates) refreshes
// the cache. Everything below is pure and thread-safe.

/// Owner of everything F075 registers, kept outside the main-actor feature type so render closures can use it.
let calendarOwner = "calendar"

// MARK: - Parameters

/// The template's params: `layout` daily | weekly, `weekStart` monday | sunday, the page's date as `year` / `month` /
/// `day` (0 = undated), the timeline's `startHour` / `endHour`, and the usual `paper` / `line` colours.
struct EventPlannerParams: Equatable {
    enum Layout: String, CaseIterable { case daily, weekly }
    enum WeekStart: String, CaseIterable { case monday, sunday }

    var layout: Layout
    var weekStart: WeekStart
    var year: Int
    var month: Int
    var day: Int
    var startHour: Int
    var endHour: Int

    static let defaultStartHour = 7
    static let defaultEndHour = 21

    init(layout: Layout = .daily, weekStart: WeekStart = .monday, year: Int = 0, month: Int = 0, day: Int = 0,
         startHour: Int = EventPlannerParams.defaultStartHour, endHour: Int = EventPlannerParams.defaultEndHour) {
        self.layout = layout
        self.weekStart = weekStart
        self.year = year
        self.month = month
        self.day = day
        let start = min(max(startHour, 0), 23)
        self.startHour = start
        self.endHour = min(max(endHour, start + 1), 24)
    }

    /// Lenient: unknown or out-of-range values fall back to the defaults.
    init(_ params: [String: JSONValue]) {
        func int(_ name: String, _ fallback: Int) -> Int {
            guard let v = params[name]?.doubleValue, v.isFinite else { return fallback }
            return Int(v.rounded())
        }
        self.init(layout: params["layout"]?.stringValue.flatMap(Layout.init(rawValue:)) ?? .daily,
                  weekStart: params["weekStart"]?.stringValue.flatMap(WeekStart.init(rawValue:)) ?? .monday,
                  year: int("year", 0), month: int("month", 0), day: int("day", 0),
                  startHour: int("startHour", Self.defaultStartHour), endHour: int("endHour", Self.defaultEndHour))
    }

    /// A page dated `date` (its day in `calendar`).
    init(date: Date, layout: Layout, weekStart: WeekStart, calendar: Calendar,
         startHour: Int = EventPlannerParams.defaultStartHour, endHour: Int = EventPlannerParams.defaultEndHour) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(layout: layout, weekStart: weekStart, year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                  startHour: startHour, endHour: endHour)
    }

    /// `TemplateRef.params` for this page.
    var json: [String: JSONValue] {
        ["layout": .string(layout.rawValue), "weekStart": .string(weekStart.rawValue), "year": .number(Double(year)),
         "month": .number(Double(month)), "day": .number(Double(day)), "startHour": .number(Double(startHour)),
         "endHour": .number(Double(endHour))]
    }

    /// Gregorian, in this device's time zone and language, with the week starting on `weekStart`.
    func calendar(timeZone: TimeZone = .current, locale: Locale = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = locale
        c.firstWeekday = weekStart == .monday ? 2 : 1
        c.minimumDaysInFirstWeek = weekStart == .monday ? 4 : 1
        return c
    }

    /// The page's date; nil when undated or not a real date.
    func date(in cal: Calendar) -> Date? {
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              let d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: d)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return cal.startOfDay(for: d)
    }

    /// The first day the page shows: the date, or the start of its week.
    func firstDay(in cal: Calendar) -> Date? {
        guard let d = date(in: cal) else { return nil }
        guard layout == .weekly else { return d }
        let weekday = cal.component(.weekday, from: d)
        let back = (weekday - cal.firstWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -back, to: d).map { cal.startOfDay(for: $0) }
    }

    /// The days the page shows (1 or 7), undated or not.
    var dayCount: Int { layout == .daily ? 1 : 7 }

    func days(in cal: Calendar) -> [Date] {
        guard let first = firstDay(in: cal) else { return [] }
        return (0..<dayCount).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }

    /// [first day, the day after the last day).
    func interval(in cal: Calendar) -> DateInterval? {
        guard let first = firstDay(in: cal), let end = cal.date(byAdding: .day, value: dayCount, to: first) else { return nil }
        return DateInterval(start: first, end: end)
    }
}

// MARK: - Layout (pure)

struct PlannerEventBox: Equatable {
    var event: String
    var rect: Rect
    /// Column inside its cluster of overlapping events, and how many columns the cluster has.
    var column: Int
    var columns: Int
}

struct PlannerChip: Equatable {
    var event: String
    var rect: Rect
}

enum EventPlannerLayout {
    static func dayEnd(_ day: Date, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    /// Events for the all-day area of `day`: all-day events on it, and timed events that cover the whole day.
    static func allDay(_ events: [CalendarEvent], day: Date, calendar cal: Calendar) -> [CalendarEvent] {
        let end = dayEnd(day, cal)
        return events.filter { e in
            if e.allDay { return CalendarEventCache.overlaps(e, day, end) }
            return e.start <= day && e.end >= end
        }.sorted(by: CalendarEvent.chronological)
    }

    /// Timed events drawn on the timeline of `day` (clipped to it).
    static func timed(_ events: [CalendarEvent], day: Date, calendar cal: Calendar) -> [CalendarEvent] {
        let end = dayEnd(day, cal)
        return events.filter { e in
            !e.allDay && CalendarEventCache.overlaps(e, day, end) && !(e.start <= day && e.end >= end)
        }
    }

    /// Where `day`'s timed events go in `rect`, the timeline from `startHour` to `endHour`. Events outside the hours
    /// are pinned to the nearest edge; every box is at least `minHeight` tall. Boxes that overlap on the page form a
    /// cluster whose width is shared in columns (an event takes the first column that is free when it starts).
    static func boxes(_ events: [CalendarEvent], day: Date, calendar cal: Calendar, startHour: Int, endHour: Int,
                      in rect: Rect, minHeight: Double, gap: Double = 1) -> [PlannerEventBox] {
        let windowStart = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day)
            ?? day.addingTimeInterval(Double(startHour) * 3_600)
        let windowEnd = endHour >= 24 ? dayEnd(day, cal)
            : (cal.date(bySettingHour: endHour, minute: 0, second: 0, of: day) ?? day.addingTimeInterval(Double(endHour) * 3_600))
        let span = max(windowEnd.timeIntervalSince(windowStart), 60)
        func y(_ t: Date) -> Double {
            let f = min(max(t.timeIntervalSince(windowStart) / span, 0), 1)
            return rect.minY + f * rect.height
        }
        let height = min(minHeight, rect.height)
        var spans: [(id: String, y0: Double, y1: Double)] = timed(events, day: day, calendar: cal).map { e in
            var y0 = y(e.start), y1 = y(max(e.end, e.start))
            if y1 - y0 < height { y1 = y0 + height }
            if y1 > rect.maxY {
                y1 = rect.maxY
                y0 = max(rect.minY, y1 - height)
            }
            return (e.id, y0, y1)
        }
        spans.sort { a, b in
            if a.y0 != b.y0 { return a.y0 < b.y0 }
            if (a.y1 - a.y0) != (b.y1 - b.y0) { return (a.y1 - a.y0) > (b.y1 - b.y0) }
            return a.id < b.id
        }
        let epsilon = 0.01
        var out: [PlannerEventBox] = []
        var index = 0
        while index < spans.count {
            // One cluster: spans that overlap, directly or through each other.
            var clusterEnd = spans[index].y1
            var cluster = [spans[index]]
            var next = index + 1
            while next < spans.count && spans[next].y0 < clusterEnd - epsilon {
                cluster.append(spans[next])
                clusterEnd = max(clusterEnd, spans[next].y1)
                next += 1
            }
            var bottoms: [Double] = []
            var columnOf: [Int] = []
            for s in cluster {
                if let free = bottoms.firstIndex(where: { $0 <= s.y0 + epsilon }) {
                    bottoms[free] = s.y1
                    columnOf.append(free)
                } else {
                    bottoms.append(s.y1)
                    columnOf.append(bottoms.count - 1)
                }
            }
            let columns = bottoms.count
            let width = rect.width / Double(columns)
            for (i, s) in cluster.enumerated() {
                let x = rect.minX + Double(columnOf[i]) * width
                let w = max(width - (columns > 1 ? gap : 0), 1)
                out.append(PlannerEventBox(event: s.id, rect: Rect(x: x, y: s.y0, width: w, height: s.y1 - s.y0),
                                           column: columnOf[i], columns: columns))
            }
            index = next
        }
        return out
    }

    /// Estimated width of `text` at `size` points (templates draw on render threads without UIKit measuring).
    /// Generous on purpose: an estimate that is too small makes the text wrap and clip inside its box.
    static func textWidth(_ text: String, size: Double) -> Double { Double(text.count) * size * 0.62 + size * 0.3 }

    /// Lines `text` needs at `size` in `width` (at least 1).
    static func lines(_ text: String, size: Double, width: Double) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((textWidth(text, size: size) / width).rounded(.up)))
    }

    /// All-day chips flowed left to right in rows of `rowHeight` inside `rect`. When they do not all fit, the last row
    /// keeps `overflowWidth` free for "+N" and `hidden` counts the ones left out.
    static func chips(_ events: [CalendarEvent], in rect: Rect, rowHeight: Double, fontSize: Double, padding: Double,
                      gap: Double, overflowWidth: Double) -> (chips: [PlannerChip], hidden: Int) {
        let rows = max(1, Int((rect.height + 0.01) / rowHeight))
        func place(reserve: Double) -> (chips: [PlannerChip], hidden: Int) {
            var chips: [PlannerChip] = []
            var row = 0
            var x = rect.minX
            for (i, e) in events.enumerated() {
                let wanted = min(textWidth(e.title.isEmpty ? " " : e.title, size: fontSize) + 2 * padding, rect.width)
                var limit = rect.maxX - (row == rows - 1 ? reserve : 0)
                if x > rect.minX && x + wanted > limit {
                    row += 1
                    x = rect.minX
                    limit = rect.maxX - (row == rows - 1 ? reserve : 0)
                }
                if row >= rows { return (chips, events.count - i) }
                let width = min(wanted, limit - x)
                if width < min(wanted, 2 * padding + 2 * fontSize) { return (chips, events.count - i) }
                chips.append(PlannerChip(event: e.id, rect: Rect(x: x, y: rect.minY + Double(row) * rowHeight,
                                                                 width: width, height: rowHeight - gap)))
                x += width + gap
            }
            return (chips, 0)
        }
        let first = place(reserve: 0)
        return first.hidden == 0 ? first : place(reserve: overflowWidth)
    }

    /// How many chip rows `events` need in a `width`-wide area (for sizing the all-day band), capped at `maxRows`.
    static func rowsNeeded(_ events: [CalendarEvent], width: Double, fontSize: Double, padding: Double, gap: Double,
                           maxRows: Int) -> Int {
        guard !events.isEmpty else { return 1 }
        var rows = 1
        var x = 0.0
        for e in events {
            let w = min(textWidth(e.title.isEmpty ? " " : e.title, size: fontSize) + 2 * padding, width)
            if x > 0 && x + w > width {
                rows += 1
                x = 0
            }
            x += w + gap
        }
        return min(rows, maxRows)
    }
}

// MARK: - Drawing

/// Paper colours: `paper` / `line` params, else white paper with its rule colour (DESIGN.md §3.6).
struct PlannerStyle {
    let paper: RGBA
    let line: RGBA
    let strong: RGBA
    let label: RGBA
    let ink: RGBA
    let isDark: Bool

    init(_ params: [String: JSONValue]) {
        let paper = params[TemplateParamNames.paper]?.stringValue.flatMap(PlannerStyle.parse) ?? CalendarPalette.rgba(NibPaper.white.hex)
        let preset = NibPaper.allCases.first { p in
            let c = CalendarPalette.rgba(p.hex)
            return c.r == paper.r && c.g == paper.g && c.b == paper.b
        }
        let dark = PlannerStyle.luminance(paper) < 0.45
        let ink = dark ? CalendarPalette.rgba(NibInk.chalk.hex) : CalendarPalette.rgba(NibInk.carbon.hex)
        let line = params[TemplateParamNames.line]?.stringValue.flatMap(PlannerStyle.parse)
            ?? preset.map { CalendarPalette.rgba($0.ruleHex) }
            ?? PlannerStyle.mix(paper, ink, 0.18)
        self.paper = paper
        self.line = line
        self.ink = ink
        self.isDark = dark
        strong = PlannerStyle.mix(line, ink, 0.25)
        label = PlannerStyle.mix(paper, ink, 0.55)
    }

    static func parse(_ s: String) -> RGBA? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let p = NibPaper.allCases.first(where: { $0.rawValue == t }) { return CalendarPalette.rgba(p.hex) }
        return RGBA(hex: t)
    }

    static func luminance(_ c: RGBA) -> Double {
        (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        func ch(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(x) + (Double(y) - Double(x)) * t).rounded())))
        }
        return RGBA(ch(a.r, b.r), ch(a.g, b.g), ch(a.b, b.b), 255)
    }
}

/// Page-coordinate op builder; every op is clipped to the page.
struct PlannerCanvas {
    let width: Double
    let height: Double
    let scale: Double
    let style: PlannerStyle
    private(set) var ops: [DisplayOp] = []

    init(size: PageSize, scale: Double, style: PlannerStyle) {
        width = size.width.isFinite ? max(size.width, 1) : 1
        height = size.height.isFinite ? max(size.height, 1) : 1
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.style = style
    }

    /// Rules are 0.5 pt at zoom 1 and never thicker than 1 px on screen.
    var hairline: Double { min(0.5, 1 / scale) }

    func clip(_ r: Rect) -> Rect? {
        let x0 = max(r.minX, 0), y0 = max(r.minY, 0), x1 = min(r.maxX, width), y1 = min(r.maxY, height)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, color: RGBA? = nil, width w: Double? = nil,
                       dash: [Double]? = nil) {
        let a = Point(min(max(x0, 0), width), min(max(y0, 0), height))
        let b = Point(min(max(x1, 0), width), min(max(y1, 0), height))
        guard a != b else { return }
        ops.append(DisplayOp(op: .line, points: [a, b], stroke: color ?? style.line, width: w ?? hairline, dash: dash))
    }

    mutating func hlines(_ r: Rect, spacing: Double, color: RGBA? = nil) {
        guard spacing >= 1, let c = clip(r), c.height >= spacing else { return }
        ops.append(DisplayOp(op: .hlines, rect: c, stroke: color ?? style.line, width: hairline, spacing: spacing))
    }

    mutating func box(_ r: Rect, stroke: RGBA? = nil, fill: RGBA? = nil, width w: Double? = nil, radius: Double? = nil,
                      dash: [Double]? = nil) {
        guard stroke != nil || fill != nil, let c = clip(r) else { return }
        ops.append(DisplayOp(op: .rect, rect: c, stroke: stroke, fill: fill, width: w ?? hairline, dash: dash, radius: radius))
    }

    mutating func text(_ s: String, _ r: Rect, size: Double, color: RGBA? = nil, weight: DisplayFontWeight? = nil,
                       align: ParagraphAlignment? = nil) {
        guard !s.isEmpty, size > 0, let c = clip(r) else { return }
        ops.append(DisplayOp(op: .text, rect: c, stroke: color ?? style.label, text: s, fontSize: size, align: align,
                             weight: weight))
    }
}

/// What the renderer needs besides the params: the cached events of the page's days and when they were read.
struct EventPlannerSnapshot {
    var events: [CalendarEvent]
    /// nil = these dates were never read.
    var synced: Date?
}

enum EventPlannerRenderer {
    static let hourLabelSize = 7.0

    static func render(_ raw: [String: JSONValue], size: PageSize, scale: Double, calendar: Calendar? = nil,
                       snapshot: (DateInterval) -> EventPlannerSnapshot) -> TemplateRender {
        let p = EventPlannerParams(raw)
        let cal = calendar ?? p.calendar()
        let style = PlannerStyle(raw)
        var canvas = PlannerCanvas(size: size, scale: scale, style: style)
        let interval = p.interval(in: cal)
        let data = interval.map(snapshot) ?? EventPlannerSnapshot(events: [], synced: nil)
        switch p.layout {
        case .daily: drawDaily(&canvas, p, cal, data, dated: interval != nil)
        case .weekly: drawWeekly(&canvas, p, cal, data, dated: interval != nil)
        }
        return TemplateRender(paper: style.paper, display: DisplayList(ops: canvas.ops))
    }

    static func margin(_ c: PlannerCanvas) -> Double { min(max(min(c.width, c.height) * 0.06, 18), 48) }

    // MARK: Daily

    /// Geometry of a daily page, shared by drawing and tests.
    struct DailyFrame {
        var header: Rect
        var allDay: Rect
        var timeline: Rect
        var events: Rect
        var side: Rect
        var gutter: Double
    }

    static let chipRow = 15.0
    static let chipFont = 7.0
    static let chipPadding = 4.0

    static func dailyFrame(_ c: PlannerCanvas, allDayRows: Int) -> DailyFrame {
        let m = margin(c)
        let x0 = m, x1 = c.width - m
        let header = Rect(x: x0, y: m, width: x1 - x0, height: 46)
        let leftWidth = (x1 - x0) * 0.62
        let gutter = 30.0
        let allDay = Rect(x: x0 + gutter, y: header.maxY + 6, width: leftWidth - gutter, height: Double(allDayRows) * chipRow)
        let top = allDay.maxY + 8
        let bottom = max(c.height - m, top + 1)
        let timeline = Rect(x: x0, y: top, width: leftWidth, height: bottom - top)
        let events = Rect(x: x0 + gutter + 2, y: top, width: leftWidth - gutter - 2, height: bottom - top)
        let sideX = x0 + leftWidth + 14
        let side = Rect(x: sideX, y: header.maxY + 6, width: max(x1 - sideX, 1), height: bottom - header.maxY - 6)
        return DailyFrame(header: header, allDay: allDay, timeline: timeline, events: events, side: side, gutter: gutter)
    }

    static func drawDaily(_ c: inout PlannerCanvas, _ p: EventPlannerParams, _ cal: Calendar, _ data: EventPlannerSnapshot,
                          dated: Bool) {
        let day = p.days(in: cal).first
        let allDayEvents = day.map { EventPlannerLayout.allDay(data.events, day: $0, calendar: cal) } ?? []
        let probe = dailyFrame(c, allDayRows: 1)
        let rows = EventPlannerLayout.rowsNeeded(allDayEvents, width: probe.allDay.width, fontSize: chipFont,
                                                 padding: chipPadding, gap: 3, maxRows: 2)
        let f = dailyFrame(c, allDayRows: rows)
        let style = c.style

        // Header: weekday, date, week number and when the events were read.
        if let d = day {
            var weekday = Date.FormatStyle.dateTime.weekday(.wide)
            weekday.calendar = cal
            weekday.timeZone = cal.timeZone
            var long = Date.FormatStyle.dateTime.day().month(.wide).year()
            long.calendar = cal
            long.timeZone = cal.timeZone
            c.text(d.formatted(weekday), Rect(x: f.header.minX, y: f.header.minY, width: f.header.width * 0.6, height: 15),
                   size: 11, weight: .medium)
            c.text(d.formatted(long), Rect(x: f.header.minX, y: f.header.minY + 14, width: f.header.width * 0.64, height: 30),
                   size: 22, color: style.ink, weight: .semibold)
            let week = cal.component(.weekOfYear, from: d)
            c.text(String(localized: "Week \(week)"),
                   Rect(x: f.header.minX + f.header.width * 0.6, y: f.header.minY, width: f.header.width * 0.4, height: 12),
                   size: 9, align: .right)
        } else {
            c.text(String(localized: "Date"), Rect(x: f.header.minX, y: f.header.minY + 18, width: 40, height: 14), size: 11)
            c.line(f.header.minX + 36, f.header.minY + 31, f.header.minX + f.header.width * 0.5, f.header.minY + 31,
                   color: style.strong)
        }
        if dated {
            c.text(syncLine(data.synced),
                   Rect(x: f.header.minX + f.header.width * 0.45, y: f.header.minY + 15, width: f.header.width * 0.55,
                        height: 10),
                   size: 7, align: .right)
        }
        c.line(f.header.minX, f.header.maxY, f.header.maxX, f.header.maxY, color: style.strong)

        // All-day area.
        c.text(String(localized: "All day"), Rect(x: f.timeline.minX, y: f.allDay.minY + 3, width: f.gutter - 2, height: 9),
               size: hourLabelSize)
        drawChips(&c, allDayEvents, in: f.allDay)
        c.line(f.timeline.minX, f.allDay.maxY + 4, f.timeline.maxX, f.allDay.maxY + 4)

        // Timeline.
        drawHours(&c, p, cal, day: day ?? cal.startOfDay(for: Date()), in: f.timeline, gutter: f.gutter, labels: true)
        if let d = day {
            let boxes = EventPlannerLayout.boxes(data.events, day: d, calendar: cal, startHour: p.startHour,
                                                 endHour: p.endHour, in: f.events, minHeight: 11, gap: 1.5)
            drawBoxes(&c, boxes, events: data.events, cal: cal, titleSize: 8, detailSize: 6.5)
        }

        // To do and notes for handwriting.
        var y = f.side.minY
        c.text(String(localized: "To do"), Rect(x: f.side.minX, y: y, width: f.side.width, height: 12), size: 9,
               weight: .semibold)
        y += 18
        let rowSpacing = 22.0
        for _ in 0..<6 {
            c.box(Rect(x: f.side.minX, y: y + 6, width: 8, height: 8), stroke: style.strong, radius: 1.5)
            c.line(f.side.minX + 14, y + rowSpacing - 4, f.side.maxX, y + rowSpacing - 4)
            y += rowSpacing
        }
        y += 8
        c.text(String(localized: "Notes"), Rect(x: f.side.minX, y: y, width: f.side.width, height: 12), size: 9,
               weight: .semibold)
        y += 14
        c.hlines(Rect(x: f.side.minX, y: y, width: f.side.width, height: f.side.maxY - y), spacing: rowSpacing)
    }

    // MARK: Weekly

    struct WeeklyFrame {
        var header: Rect
        var dayHeader: Rect
        var allDay: Rect
        var timeline: Rect
        var gutter: Double
        var columnWidth: Double

        func column(_ i: Int, in r: Rect) -> Rect {
            Rect(x: timeline.minX + gutter + Double(i) * columnWidth, y: r.minY, width: columnWidth, height: r.height)
        }
    }

    static let weekChipRow = 12.0
    static let weekChipFont = 6.0

    static func weeklyFrame(_ c: PlannerCanvas, allDayRows: Int) -> WeeklyFrame {
        let m = margin(c)
        let x0 = m, x1 = c.width - m
        let gutter = 26.0
        let header = Rect(x: x0, y: m, width: x1 - x0, height: 40)
        let dayHeader = Rect(x: x0 + gutter, y: header.maxY + 4, width: x1 - x0 - gutter, height: 26)
        let allDay = Rect(x: x0 + gutter, y: dayHeader.maxY + 2, width: x1 - x0 - gutter,
                          height: Double(allDayRows) * weekChipRow)
        let top = allDay.maxY + 6
        let bottom = max(c.height - m, top + 1)
        return WeeklyFrame(header: header, dayHeader: dayHeader, allDay: allDay,
                           timeline: Rect(x: x0, y: top, width: x1 - x0, height: bottom - top), gutter: gutter,
                           columnWidth: (x1 - x0 - gutter) / 7)
    }

    static func drawWeekly(_ c: inout PlannerCanvas, _ p: EventPlannerParams, _ cal: Calendar, _ data: EventPlannerSnapshot,
                           dated: Bool) {
        let days = p.days(in: cal)
        let probe = weeklyFrame(c, allDayRows: 1)
        let rows = days.map { d in
            EventPlannerLayout.rowsNeeded(EventPlannerLayout.allDay(data.events, day: d, calendar: cal),
                                          width: probe.columnWidth - 3, fontSize: weekChipFont, padding: 3, gap: 2,
                                          maxRows: 2)
        }.max() ?? 1
        let f = weeklyFrame(c, allDayRows: rows)
        let style = c.style

        // Header: week number and date range.
        if let first = days.first, let last = days.last {
            var short = Date.FormatStyle.dateTime.day().month(.wide)
            short.calendar = cal
            short.timeZone = cal.timeZone
            var long = Date.FormatStyle.dateTime.day().month(.wide).year()
            long.calendar = cal
            long.timeZone = cal.timeZone
            let week = cal.component(.weekOfYear, from: first)
            c.text(String(localized: "Week \(week)"), Rect(x: f.header.minX, y: f.header.minY, width: 120, height: 12),
                   size: 9)
            c.text(first.formatted(short) + " – " + last.formatted(long),
                   Rect(x: f.header.minX, y: f.header.minY + 12, width: f.header.width * 0.7, height: 26), size: 18,
                   color: style.ink, weight: .semibold)
        } else {
            c.text(String(localized: "Week of"), Rect(x: f.header.minX, y: f.header.minY + 16, width: 60, height: 14),
                   size: 11)
            c.line(f.header.minX + 56, f.header.minY + 29, f.header.minX + f.header.width * 0.5, f.header.minY + 29,
                   color: style.strong)
        }
        if dated {
            c.text(syncLine(data.synced),
                   Rect(x: f.header.minX + f.header.width * 0.45, y: f.header.minY, width: f.header.width * 0.55,
                        height: 10),
                   size: 7, align: .right)
        }

        // Day headers: weekday and day number, in the week's order.
        var symbols = cal.shortStandaloneWeekdaySymbols
        let shift = (cal.firstWeekday - 1 + 7) % 7
        if symbols.count == 7 { symbols = Array(symbols[shift...] + symbols[..<shift]) }
        for i in 0..<7 {
            let col = f.column(i, in: f.dayHeader)
            let name = symbols.indices.contains(i) ? symbols[i] : ""
            c.text(name, Rect(x: col.minX + 1, y: col.minY, width: col.width - 2, height: 9), size: 7, align: .center)
            if days.indices.contains(i) {
                c.text(String(cal.component(.day, from: days[i])),
                       Rect(x: col.minX + 1, y: col.minY + 9, width: col.width - 2, height: 16), size: 12, color: style.ink,
                       weight: .semibold, align: .center)
            }
        }
        c.line(f.dayHeader.minX, f.dayHeader.maxY, f.dayHeader.maxX, f.dayHeader.maxY, color: style.strong)

        // All-day row.
        c.text(String(localized: "All day"), Rect(x: f.timeline.minX, y: f.allDay.minY + 2, width: f.gutter - 2, height: 8),
               size: 5.5)
        for (i, d) in days.enumerated() {
            let col = f.column(i, in: f.allDay)
            drawChips(&c, EventPlannerLayout.allDay(data.events, day: d, calendar: cal),
                      in: Rect(x: col.minX + 1.5, y: col.minY, width: col.width - 3, height: col.height),
                      rowHeight: weekChipRow, fontSize: weekChipFont, padding: 3, gap: 2)
        }
        c.line(f.timeline.minX, f.allDay.maxY + 3, f.timeline.maxX, f.allDay.maxY + 3)

        // Timeline and columns.
        drawHours(&c, p, cal, day: days.first ?? cal.startOfDay(for: Date()), in: f.timeline, gutter: f.gutter,
                  labels: true)
        for i in 0...7 {
            let x = f.timeline.minX + f.gutter + Double(i) * f.columnWidth
            c.line(x, f.dayHeader.minY, x, f.timeline.maxY, color: i == 0 || i == 7 ? style.strong : style.line)
        }
        for (i, d) in days.enumerated() {
            let col = f.column(i, in: f.timeline)
            let boxes = EventPlannerLayout.boxes(data.events, day: d, calendar: cal, startHour: p.startHour,
                                                 endHour: p.endHour,
                                                 in: Rect(x: col.minX + 1.5, y: col.minY, width: col.width - 3,
                                                          height: col.height),
                                                 minHeight: 9, gap: 1)
            drawBoxes(&c, boxes, events: data.events, cal: cal, titleSize: 6.5, detailSize: 5.5)
        }
    }

    // MARK: Shared pieces

    static func syncLine(_ synced: Date?) -> String {
        guard let s = synced else { return String(localized: "Calendar not synced for these dates") }
        let when = s.formatted(Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute())
        return String(localized: "Calendar synced \(when)")
    }

    /// Hour rules (solid) and half-hour rules (dotted) with hour labels in the gutter.
    static func drawHours(_ c: inout PlannerCanvas, _ p: EventPlannerParams, _ cal: Calendar, day: Date, in r: Rect,
                          gutter: Double, labels: Bool) {
        let hours = max(p.endHour - p.startHour, 1)
        let rowHeight = r.height / Double(hours)
        guard rowHeight >= 4 else { return }
        let faint = PlannerStyle.mix(c.style.line, c.style.paper, 0.45)
        var hourStyle = Date.FormatStyle.dateTime.hour()
        hourStyle.calendar = cal
        hourStyle.timeZone = cal.timeZone
        for i in 0...hours {
            let y = r.minY + Double(i) * rowHeight
            c.line(r.minX + gutter, y, r.maxX, y)
            if i < hours && rowHeight >= 14 {
                c.line(r.minX + gutter, y + rowHeight / 2, r.maxX, y + rowHeight / 2, color: faint, dash: [1, 2])
            }
            if labels && i < hours,
               let t = cal.date(bySettingHour: p.startHour + i, minute: 0, second: 0, of: day) {
                c.text(t.formatted(hourStyle), Rect(x: r.minX, y: y + 1, width: gutter - 3, height: 9),
                       size: min(hourLabelSize, rowHeight * 0.6))
            }
        }
    }

    static func drawChips(_ c: inout PlannerCanvas, _ events: [CalendarEvent], in r: Rect, rowHeight: Double = chipRow,
                          fontSize: Double = chipFont, padding: Double = chipPadding, gap: Double = 3) {
        guard !events.isEmpty else { return }
        let overflow = EventPlannerLayout.textWidth("+99", size: fontSize) + 2 * padding
        let placed = EventPlannerLayout.chips(events, in: r, rowHeight: rowHeight, fontSize: fontSize, padding: padding,
                                              gap: gap, overflowWidth: overflow)
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for chip in placed.chips {
            guard let e = byID[chip.event] else { continue }
            let look = EventLook(e, style: c.style)
            c.box(chip.rect, stroke: look.outline, fill: look.fill, width: c.hairline * 1.5,
                  radius: min(3, chip.rect.height / 2), dash: look.dash)
            c.text(e.title.isEmpty ? String(localized: "Untitled Event") : e.title,
                   Rect(x: chip.rect.minX + padding, y: chip.rect.minY + (chip.rect.height - fontSize * 1.25) / 2,
                        width: chip.rect.width - 2 * padding, height: fontSize * 1.3),
                   size: fontSize, color: look.text, weight: .medium)
            if e.isDeclined {
                let w = min(Double(e.title.count) * fontSize * 0.54, chip.rect.width - 2 * padding)
                c.line(chip.rect.minX + padding, chip.rect.midY, chip.rect.minX + padding + w, chip.rect.midY,
                       color: look.text, width: c.hairline * 1.5)
            }
        }
        if placed.hidden > 0, let last = placed.chips.last {
            c.text("+\(placed.hidden)", Rect(x: r.maxX - overflow, y: last.rect.minY + (last.rect.height - fontSize * 1.25) / 2,
                                            width: overflow, height: fontSize * 1.3),
                   size: fontSize, weight: .semibold, align: .right)
        }
    }

    static func drawBoxes(_ c: inout PlannerCanvas, _ boxes: [PlannerEventBox], events: [CalendarEvent], cal: Calendar,
                          titleSize: Double, detailSize: Double) {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = cal
        time.timeZone = cal.timeZone
        for box in boxes {
            guard let e = byID[box.event] else { continue }
            let r = box.rect
            let look = EventLook(e, style: c.style)
            c.box(r, stroke: look.outline, fill: look.fill, width: c.hairline * 1.5, radius: 2, dash: look.dash)
            c.box(Rect(x: r.minX, y: r.minY, width: min(2.5, r.width / 3), height: r.height), fill: look.bar, radius: 1)
            let inner = Rect(x: r.minX + 5, y: r.minY + 1.5, width: max(r.width - 7, 1), height: max(r.height - 2.5, 1))
            let size = min(titleSize, max(5, r.height * 0.55))
            let title = e.title.isEmpty ? String(localized: "Untitled Event") : e.title
            // The title takes the lines it needs (at most two, and only what the box holds); details go below it.
            let lineHeight = size * 1.3
            let room = max(1, Int(inner.height / lineHeight))
            let titleLines = min(EventPlannerLayout.lines(title, size: size, width: inner.width), 2, room)
            c.text(title, Rect(x: inner.minX, y: inner.minY, width: inner.width, height: Double(titleLines) * lineHeight),
                   size: size, color: look.text, weight: .semibold)
            if e.isDeclined {
                let w = min(Double(title.count) * size * 0.54, inner.width)
                c.line(inner.minX, inner.minY + size * 0.65, inner.minX + w, inner.minY + size * 0.65, color: look.text,
                       width: c.hairline * 1.5)
            }
            let detailTop = inner.minY + Double(titleLines) * lineHeight
            if inner.maxY - detailTop >= detailSize * 1.2 {
                var parts = [e.start.formatted(time) + " – " + e.end.formatted(time)]
                if let answer = look.answer { parts.append(answer) }
                if let place = e.location, box.columns == 1 { parts.append(place) }
                c.text(parts.joined(separator: " · "),
                       Rect(x: inner.minX, y: detailTop, width: inner.width, height: inner.maxY - detailTop),
                       size: detailSize, color: look.detail)
            }
        }
    }
}

/// How an event looks on paper for its answer: accepted (and your own) events are washed in the calendar colour,
/// "Maybe" is a lighter wash with a dashed edge, invitations you have not answered are outlined, declined and
/// cancelled events are dashed grey and struck through. The answer is also written out ("Maybe", "Invited"), so it
/// never rests on colour alone.
struct EventLook {
    var fill: RGBA?
    var outline: RGBA?
    var dash: [Double]?
    var bar: RGBA
    var text: RGBA
    var detail: RGBA
    var answer: String?

    init(_ e: CalendarEvent, style: PlannerStyle) {
        let colour = e.colour.withAlpha(1)
        text = style.ink
        detail = style.label
        bar = colour
        if e.status == .cancelled {
            fill = nil
            outline = style.line
            dash = [2, 2]
            bar = style.line
            text = style.label
            answer = String(localized: "Cancelled")
        } else {
            switch e.rsvp {
            case .declined:
                fill = nil
                outline = style.line
                dash = [2, 2]
                bar = style.line
                text = style.label
                answer = String(localized: "Declined")
            case .tentative:
                fill = PlannerStyle.mix(style.paper, colour, 0.10)
                outline = colour
                dash = [2, 1.5]
                answer = String(localized: "Maybe")
            case .pending:
                fill = nil
                outline = colour
                dash = nil
                answer = String(localized: "Invited")
            case .accepted, .none, .delegated:
                fill = PlannerStyle.mix(style.paper, colour, style.isDark ? 0.32 : 0.20)
                outline = nil
                dash = nil
                answer = nil
            }
        }
    }
}

// MARK: - The template

enum EventPlannerTemplate {
    static let id = "planner.events"

    static let params: [TemplateParam] = [
        TemplateParam(name: TemplateParamNames.paper, title: String(localized: "Paper colour"), kind: "color"),
        TemplateParam(name: TemplateParamNames.line, title: String(localized: "Line colour"), kind: "color"),
        TemplateParam(name: "layout", title: String(localized: "Layout"), kind: "choice",
                      choices: EventPlannerParams.Layout.allCases.map { $0.rawValue }),
        TemplateParam(name: "weekStart", title: String(localized: "Week starts on"), kind: "choice",
                      choices: EventPlannerParams.WeekStart.allCases.map { $0.rawValue }),
        TemplateParam(name: "year", title: String(localized: "Year (0 = undated)"), kind: "number", minimum: 0, maximum: 2200),
        TemplateParam(name: "month", title: String(localized: "Month"), kind: "number", minimum: 0, maximum: 12),
        TemplateParam(name: "day", title: String(localized: "Day"), kind: "number", minimum: 0, maximum: 31),
        TemplateParam(name: "startHour", title: String(localized: "First hour"), kind: "number", minimum: 0, maximum: 23),
        TemplateParam(name: "endHour", title: String(localized: "Last hour"), kind: "number", minimum: 1, maximum: 24)
    ]

    static let defaults: [String: JSONValue] = [
        "layout": .string(EventPlannerParams.Layout.daily.rawValue),
        "weekStart": .string(EventPlannerParams.WeekStart.monday.rawValue),
        "startHour": .number(Double(EventPlannerParams.defaultStartHour)),
        "endHour": .number(Double(EventPlannerParams.defaultEndHour))
    ]

    /// The template drawing from `cache`. Re-registered after every sync, which tells the renderer to redraw pages
    /// that use it.
    static func definition(cache: CalendarEventCache) -> TemplateDefinition {
        var d = TemplateDefinition(
            id: id, title: String(localized: "Event Planner"), category: "Planners", order: 350, owner: calendarOwner,
            params: params, defaults: defaults) { raw, size, scale in
                EventPlannerTemplate.render(raw, size: size, scale: scale, cache: cache)
            }
        d.metricsProvider = { _, size in
            guard let size = size else { return TemplateMetrics() }
            let m = min(max(min(size.width, size.height) * 0.06, 18), 48)
            return TemplateMetrics(margins: PageInsets(top: m, left: m, bottom: m, right: m))
        }
        return d
    }

    static func render(_ raw: [String: JSONValue], size: PageSize, scale: Double, cache: CalendarEventCache,
                       calendar: Calendar? = nil) -> TemplateRender {
        let merged = defaults.merging(raw) { _, new in new }
        return EventPlannerRenderer.render(merged, size: size, scale: scale, calendar: calendar) { interval in
            EventPlannerSnapshot(events: cache.events(overlapping: interval.start, interval.end),
                                 synced: cache.lastSync(covering: interval.start, interval.end))
        }
    }
}
