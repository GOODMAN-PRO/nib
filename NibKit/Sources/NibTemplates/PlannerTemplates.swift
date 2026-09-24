import Foundation
import NibContracts

/// Gregorian calendar maths for the planners (UTC, so no daylight-saving edge; names follow the device locale).
enum PlannerCalendar {
    static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale.current
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        return cal
    }

    /// Weekday names in display order.
    static func weekdays(_ style: WeekdayStyle, startMonday: Bool) -> [String] {
        let cal = calendar()
        var names: [String]
        switch style {
        case .full: names = cal.standaloneWeekdaySymbols
        case .short: names = cal.shortStandaloneWeekdaySymbols
        case .initial: names = cal.veryShortStandaloneWeekdaySymbols
        }
        if startMonday, !names.isEmpty { names.append(names.removeFirst()) }
        return names
    }

    enum WeekdayStyle { case full, short, initial }

    /// Days in the month and the column (0-based) of its first day; nil for an undated month (month 0) or bad input.
    static func layout(month: Int, year: Int, startMonday: Bool) -> (days: Int, offset: Int)? {
        let cal = calendar()
        guard (1...12).contains(month), (1...9999).contains(year),
              let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = cal.range(of: .day, in: .month, for: first) else { return nil }
        let weekday = cal.component(.weekday, from: first)  // 1 = Sunday
        return (range.count, startMonday ? (weekday + 5) % 7 : weekday - 1)
    }

    static func monthName(_ month: Int) -> String {
        let names = calendar().standaloneMonthSymbols
        return names.indices.contains(month - 1) ? names[month - 1] : ""
    }
}

/// Planners and structured notes. Every layout is proportional, so it fits any page size and orientation.
enum PlannerTemplates {
    static let all: [TemplateDefinition] = [meeting, daily, weekly, monthly, habits]

    static let colours: [TemplateParam] = [ParamSpec.paper, ParamSpec.line]

    /// Meeting notes: meeting / date / attendees fields, agenda, notes and action items with owners.
    static let meeting = TemplateFactory.paper("builtin.meeting", "Meeting Notes", category: "Planners", order: 300,
                                               params: colours) { c in
        let m = Layout.margin(c), x0 = m, x1 = c.width - m
        let s = min(24, max(14, c.height / 32))
        c.text(String(localized: "Meeting Notes"), Rect(x: x0, y: m - 6, width: x1 - x0, height: 28), size: 20)
        var y = m + 26
        for label in [String(localized: "Meeting"), String(localized: "Date"), String(localized: "Attendees")] {
            Layout.field(&c, label, x: x0, y: y, to: x1)
            y += s
        }
        y = Layout.section(&c, String(localized: "Agenda"), x: x0, y: y + s * 0.4, width: x1 - x0)
        c.hlines(Rect(x: x0, y: y - s * 0.6, width: x1 - x0, height: s * 4.25), spacing: s)
        y += s * 3.6
        let actionTop = c.height - m - (16 + s * 5.25)
        y = Layout.section(&c, String(localized: "Notes"), x: x0, y: y + s * 0.4, width: x1 - x0)
        c.hlines(Rect(x: x0, y: y - s * 0.6, width: x1 - x0, height: actionTop - s * 0.5 - (y - s * 0.6)), spacing: s)
        let rowsTop = Layout.section(&c, String(localized: "Action items"), x: x0, y: actionTop, width: x1 - x0)
        let ownerX = x1 - (x1 - x0) * 0.25
        c.text(String(localized: "Owner"), Rect(x: ownerX + 6, y: actionTop, width: x1 - ownerX - 6, height: 14), size: 10)
        Layout.checkRows(&c, Rect(x: x0, y: rowsTop - s * 0.4, width: ownerX - x0 - 6, height: s * 5.25), spacing: s)
        c.hlines(Rect(x: ownerX + 6, y: rowsTop - s * 0.4, width: x1 - ownerX - 6, height: s * 5.25), spacing: s)
        c.line(ownerX, actionTop, ownerX, c.height - m, color: c.style.strong)
    }

    /// Daily planner: date and weekday strip, an hourly schedule, priorities, to-dos and notes.
    static let daily = TemplateFactory.paper("builtin.plannerDaily", "Daily Planner", category: "Planners", order: 310,
                                             params: colours) { c in
        let m = Layout.margin(c), x0 = m, x1 = c.width - m
        Layout.field(&c, String(localized: "Date"), x: x0, y: m, to: x0 + (x1 - x0) * 0.5, size: 11)
        let initials = PlannerCalendar.weekdays(.initial, startMonday: true)
        let cell = min(18, (x1 - x0) * 0.4 / 7)
        for (i, d) in initials.enumerated() {
            let x = x1 - Double(initials.count - i) * cell
            c.box(Rect(x: x + 1, y: m, width: cell - 2, height: cell - 2), stroke: c.style.line, radius: (cell - 2) / 2)
            c.text(d, Rect(x: x + cell * 0.3, y: m + cell * 0.12, width: cell * 0.6, height: cell * 0.8), size: cell * 0.5)
        }
        let top = m + max(cell, 16) + 14
        let gap = m * 0.6
        let leftW = (x1 - x0 - gap) * 0.55
        let left = Rect(x: x0, y: top, width: leftW, height: c.height - m - top)
        let right = Rect(x: x0 + leftW + gap, y: top, width: x1 - x0 - leftW - gap, height: left.height)

        let scheduleTop = Layout.section(&c, String(localized: "Schedule"), x: left.minX, y: left.minY, width: left.width)
        let hours = Array(6...21)
        let rowH = (left.maxY - scheduleTop) / Double(hours.count)
        if rowH >= 8 {
            for (i, hour) in hours.enumerated() {
                let ry = scheduleTop + Double(i) * rowH
                c.text(String(format: "%02ld:00", hour), Rect(x: left.minX, y: ry + 2, width: 34, height: min(rowH - 2, 12)),
                       size: min(8, rowH * 0.45))
                c.line(left.minX, ry + rowH, left.maxX, ry + rowH)
            }
            c.line(left.minX + 36, scheduleTop, left.minX + 36, left.maxY)
        }

        let s = min(22, max(12, right.height / 24))
        var y = Layout.section(&c, String(localized: "Priorities"), x: right.minX, y: right.minY, width: right.width)
        Layout.checkRows(&c, Rect(x: right.minX, y: y - s * 0.4, width: right.width, height: s * 3.25), spacing: s)
        y += s * 3.2
        y = Layout.section(&c, String(localized: "To do"), x: right.minX, y: y, width: right.width)
        let todoRows = max(0, min(8, Int((right.maxY - y) * 0.5 / s)))
        Layout.checkRows(&c, Rect(x: right.minX, y: y - s * 0.4, width: right.width, height: Double(todoRows) * s + s * 0.25),
                         spacing: s)
        y += Double(todoRows) * s
        y = Layout.section(&c, String(localized: "Notes"), x: right.minX, y: y + 4, width: right.width)
        c.hlines(Rect(x: right.minX, y: y - s * 0.4, width: right.width, height: right.maxY - y + s * 0.4), spacing: s)
    }

    /// Weekly planner: seven day boxes and a notes box (2 × 4 in portrait, 4 × 2 in landscape).
    static let weekly = TemplateFactory.paper("builtin.plannerWeekly", "Weekly Planner", category: "Planners", order: 320,
                                              params: colours + [ParamSpec.startMonday],
                                              defaults: ["startMonday": true]) { c in
        let m = Layout.margin(c)
        Layout.field(&c, String(localized: "Week of"), x: m, y: m, to: c.width * 0.6, size: 11)
        let top = m + 30
        let names = PlannerCalendar.weekdays(.full, startMonday: c.flag("startMonday", true)) + [String(localized: "Notes")]
        let cols = c.isLandscape ? 4 : 2, rows = c.isLandscape ? 2 : 4
        let gap = m * 0.4
        let cellW = (c.width - 2 * m - gap * Double(cols - 1)) / Double(cols)
        let cellH = (c.height - m - top - gap * Double(rows - 1)) / Double(rows)
        guard cellW > 20, cellH > 20 else { return }
        for (i, name) in names.prefix(cols * rows).enumerated() {
            let r = Rect(x: m + Double(i % cols) * (cellW + gap), y: top + Double(i / cols) * (cellH + gap), width: cellW, height: cellH)
            c.box(r, stroke: c.style.strong, radius: 4)
            let fs = min(11, cellH * 0.12)
            c.text(name, Rect(x: r.minX + 6, y: r.minY + 4, width: r.width - 12, height: fs * 1.4), size: fs)
            let linesTop = r.minY + fs * 1.4 + 6
            let s = min(22, max(12, (r.maxY - linesTop) / 6))
            c.hlines(Rect(x: r.minX + 6, y: linesTop, width: r.width - 12, height: r.maxY - linesTop - 4), spacing: s)
        }
    }

    /// Monthly planner: `month` 1–12 with `year` gives a dated calendar; month 0 is an undated grid.
    static let monthly = TemplateFactory.paper("builtin.plannerMonthly", "Monthly Planner", category: "Planners", order: 330,
                                               params: colours + [
                                                   TemplateParam(name: "month", title: "Month (0 = undated)", kind: "number",
                                                                 minimum: 0, maximum: 12),
                                                   TemplateParam(name: "year", title: "Year", kind: "number",
                                                                 minimum: 1900, maximum: 2200),
                                                   ParamSpec.startMonday
                                               ],
                                               defaults: ["startMonday": true]) { c in
        let m = Layout.margin(c)
        let month = Int(c.number("month", 0, in: 0...12).rounded())
        let year = Int(c.number("year", 0, in: 0...9999).rounded())
        let startMonday = c.flag("startMonday", true)
        let layout = PlannerCalendar.layout(month: month, year: year, startMonday: startMonday)
        if layout != nil {
            c.text("\(PlannerCalendar.monthName(month)) \(year)", Rect(x: m, y: m - 6, width: c.width - 2 * m, height: 30), size: 22)
        } else {
            Layout.field(&c, String(localized: "Month"), x: m, y: m, to: c.width * 0.6, size: 14)
        }
        let colW = (c.width - 2 * m) / 7
        let namesTop = m + 32
        for (i, name) in PlannerCalendar.weekdays(.short, startMonday: startMonday).enumerated() {
            c.text(name, Rect(x: m + Double(i) * colW + 4, y: namesTop, width: colW - 8, height: 14), size: 9)
        }
        let gridTop = namesTop + 18
        let notesH = c.height * 0.16
        let rows = layout.map { Int((Double($0.offset + $0.days) / 7).rounded(.up)) } ?? 5
        let rowH = (c.height - m - notesH - gridTop) / Double(rows)
        guard rowH > 8 else { return }
        let gridBottom = gridTop + Double(rows) * rowH
        for i in 0...rows {
            let y = gridTop + Double(i) * rowH
            c.line(m, y, c.width - m, y, color: c.style.strong)
        }
        for j in 0...7 {
            let x = m + Double(j) * colW
            c.line(x, gridTop, x, gridBottom, color: c.style.strong)
        }
        if let l = layout {
            for day in 1...l.days {
                let index = l.offset + day - 1
                c.text("\(day)", Rect(x: m + Double(index % 7) * colW + 4, y: gridTop + Double(index / 7) * rowH + 3,
                                      width: colW - 8, height: 12), size: min(9, rowH * 0.4))
            }
        }
        let notesTop = Layout.section(&c, String(localized: "Notes"), x: m, y: gridBottom + 8, width: c.width - 2 * m)
        c.hlines(Rect(x: m, y: notesTop - 6, width: c.width - 2 * m, height: c.height - m - notesTop + 6), spacing: 20)
    }

    /// Habit tracker: a name column and 31 day columns.
    static let habits = TemplateFactory.paper("builtin.habitTracker", "Habit Tracker", category: "Planners", order: 340,
                                              params: colours) { c in
        let m = Layout.margin(c)
        Layout.field(&c, String(localized: "Habits"), x: m, y: m, to: c.width * 0.5, size: 14)
        Layout.field(&c, String(localized: "Month"), x: c.width * 0.55, y: m + 4, to: c.width - m)
        let top = m + 36
        let nameW = (c.width - 2 * m) * 0.26
        let colW = (c.width - 2 * m - nameW) / 31
        let headH = 14.0
        let rowH = min(24, max(12, (c.height - m - top - headH) / 20))
        let rows = min(20, Int((c.height - m - top - headH) / rowH))
        guard rows > 0, colW > 3 else { return }
        let size = min(7, colW * 0.55)
        for d in 1...31 {
            c.text("\(d)", Rect(x: m + nameW + Double(d - 1) * colW + 1, y: top, width: colW - 1, height: headH), size: size)
        }
        let bottom = top + headH + Double(rows) * rowH
        for i in 0...rows {
            let y = top + headH + Double(i) * rowH
            c.line(m, y, c.width - m, y, color: i == 0 ? c.style.strong : c.style.line)
        }
        c.line(m, top + headH, m, bottom, color: c.style.strong)
        for k in 0...31 {
            let x = m + nameW + Double(k) * colW
            c.line(x, top + headH, x, bottom, color: k == 0 || k == 31 ? c.style.strong : c.style.line)
        }
    }
}
