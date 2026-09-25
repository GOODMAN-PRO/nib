import Foundation
import NibContracts

// Pure Time Keeper logic: the session clock (countdown and stopwatch), history records, saved modes, the duration
// parser behind the typed and handwritten entry, and formatting. No UI, no settings, no system services.

enum TimerKind: String, Codable, CaseIterable, Hashable {
    case timer, stopwatch

    var title: String {
        switch self {
        case .timer: return String(localized: "Timer")
        case .stopwatch: return String(localized: "Stopwatch")
        }
    }
}

enum TimerRunState: String, Codable, CaseIterable {
    case idle, running, paused, finished

    var title: String {
        switch self {
        case .idle: return String(localized: "Ready")
        case .running: return String(localized: "Running")
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Finished")
        }
    }
}

struct TimerLap: Codable, Equatable, Hashable {
    /// 1-based.
    var index: Int
    /// Stopwatch time at the lap, in seconds.
    var total: Double
    /// Time since the previous lap.
    var split: Double
}

/// One Time Keeper session. Time is measured on the wall clock (`accumulated` plus the running segment since
/// `resumedAt`), so a session keeps counting while the app is hidden, suspended or relaunched: nothing has to tick.
/// ponytail: wall clock, so changing the device clock moves the timer; a monotonic clock does not survive a relaunch.
struct TimerEngine: Codable, Equatable {
    static let maxSeconds = 86_400
    /// The progress bar turns red for the last five seconds.
    static let finalCountdown: Double = 5

    var id = ""
    var kind = TimerKind.timer
    var state = TimerRunState.idle
    var label: String?
    /// Countdown length in seconds (0 for a stopwatch).
    var duration: Double = 0
    var startedAt: Date?
    /// Start of the current running segment (nil unless running).
    var resumedAt: Date?
    /// Seconds run before `resumedAt`.
    var accumulated: Double = 0
    var laps: [TimerLap] = []
    /// "doc:<id>" of the document the session was started in.
    var doc: String?
    var docTitle: String?
    /// When a countdown reached zero (its due time, even if that was noticed later).
    var endedAt: Date?

    static let idle = TimerEngine()

    static func timer(seconds: Int, label: String?, at t: Date, id: String, doc: String?, docTitle: String?) -> TimerEngine {
        TimerEngine(id: id, kind: .timer, state: .running, label: label, duration: Double(seconds), startedAt: t,
                    resumedAt: t, doc: doc, docTitle: docTitle)
    }

    static func stopwatch(label: String?, at t: Date, id: String, doc: String?, docTitle: String?) -> TimerEngine {
        TimerEngine(id: id, kind: .stopwatch, state: .running, label: label, startedAt: t, resumedAt: t, doc: doc,
                    docTitle: docTitle)
    }

    var isActive: Bool { state != .idle }

    func elapsed(at t: Date) -> Double {
        var e = accumulated
        if state == .running, let r = resumedAt { e += max(0, t.timeIntervalSince(r)) }
        return kind == .timer ? min(e, duration) : e
    }

    func remaining(at t: Date) -> Double {
        kind == .timer ? max(0, duration - elapsed(at: t)) : 0
    }

    /// 0…1 of a countdown.
    func progress(at t: Date) -> Double {
        kind == .timer && duration > 0 ? elapsed(at: t) / duration : 0
    }

    /// The last five seconds of a countdown, and a finished one.
    func isFinalCountdown(at t: Date) -> Bool {
        guard kind == .timer else { return false }
        return state == .finished || (isActive && remaining(at: t) <= Self.finalCountdown)
    }

    /// When a running countdown reaches zero.
    var endDate: Date? {
        guard kind == .timer, state == .running, let r = resumedAt else { return nil }
        return r.addingTimeInterval(duration - accumulated)
    }

    @discardableResult
    mutating func pause(at t: Date) -> Bool {
        guard state == .running else { return false }
        accumulated = elapsed(at: t)
        resumedAt = nil
        state = .paused
        return true
    }

    @discardableResult
    mutating func resume(at t: Date) -> Bool {
        guard state == .paused else { return false }
        resumedAt = t
        state = .running
        return true
    }

    /// Records a lap of a running stopwatch.
    mutating func lap(at t: Date) -> TimerLap? {
        guard kind == .stopwatch, state == .running else { return nil }
        let total = elapsed(at: t)
        let lap = TimerLap(index: laps.count + 1, total: total, split: total - (laps.last?.total ?? 0))
        laps.append(lap)
        return lap
    }

    /// Moves a running countdown whose time is up to `.finished`. True only on that transition.
    mutating func finishIfDue(at t: Date) -> Bool {
        guard let end = endDate, t >= end else { return false }
        accumulated = duration
        resumedAt = nil
        state = .finished
        endedAt = end
        return true
    }

    /// The history entry for this session if it ended at `t` (a finished countdown ends at its due time).
    /// nil for sessions under a second: an accidental tap is not a study session.
    func record(endingAt t: Date) -> TimerRecord? {
        guard isActive, let start = startedAt else { return nil }
        let run = elapsed(at: t)
        guard run >= 1 else { return nil }
        return TimerRecord(id: id, kind: kind, label: label, doc: doc, docTitle: docTitle,
                           startedAt: start.timeIntervalSince1970, endedAt: (endedAt ?? t).timeIntervalSince1970,
                           duration: kind == .timer ? duration : nil, elapsed: run,
                           completed: kind == .timer && run >= duration, laps: laps)
    }
}

/// A finished session, stored as one synced setting per session ("timer.history.<id>").
struct TimerRecord: Codable, Equatable, Identifiable {
    var id: String
    var kind: TimerKind
    var label: String?
    /// "doc:<id>".
    var doc: String?
    var docTitle: String?
    /// Unix seconds.
    var startedAt: Double
    var endedAt: Double
    /// Planned countdown length (timers only).
    var duration: Double?
    /// Seconds actually run.
    var elapsed: Double
    /// The countdown reached zero.
    var completed: Bool
    var laps: [TimerLap]

    enum CodingKeys: String, CodingKey {
        case id, kind, label, doc, docTitle, startedAt, endedAt, duration, elapsed, completed, laps
    }

    init(id: String, kind: TimerKind, label: String?, doc: String?, docTitle: String?, startedAt: Double,
         endedAt: Double, duration: Double?, elapsed: Double, completed: Bool, laps: [TimerLap]) {
        self.id = id
        self.kind = kind
        self.label = label
        self.doc = doc
        self.docTitle = docTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.elapsed = elapsed
        self.completed = completed
        self.laps = laps
    }

    /// Lenient: settings.set from the AI or a plugin may leave fields out (ARCHITECTURE.md §4.2).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let started = (try? c.decodeIfPresent(Double.self, forKey: .startedAt)) ?? 0
        let ended = (try? c.decodeIfPresent(Double.self, forKey: .endedAt)) ?? started
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        kind = (try? c.decodeIfPresent(TimerKind.self, forKey: .kind)) ?? .timer
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        doc = try? c.decodeIfPresent(String.self, forKey: .doc)
        docTitle = try? c.decodeIfPresent(String.self, forKey: .docTitle)
        startedAt = started
        endedAt = ended
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        elapsed = (try? c.decodeIfPresent(Double.self, forKey: .elapsed)) ?? max(0, ended - started)
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
        laps = (try? c.decodeIfPresent([TimerLap].self, forKey: .laps)) ?? []
    }
}

/// A saved custom timer mode, one synced setting per name ("timer.modes.<name>" = {seconds}).
struct TimerPreset: Codable, Equatable, Hashable, Identifiable {
    var name: String
    var seconds: Int

    var id: String { name }

    /// The built-in preset lengths, in seconds.
    static let builtIn = [300, 600, 900, 1500, 1800, 2700, 3600]

    init(name: String, seconds: Int) {
        self.name = name
        self.seconds = seconds
    }

    /// From a stored setting: `name` is the key suffix, `json` its value.
    init?(key name: String, json: JSONValue) {
        guard !name.isEmpty, let s = json["seconds"]?.doubleValue, s >= 1, s <= Double(TimerEngine.maxSeconds) else {
            return nil
        }
        self.init(name: name, seconds: Int(s.rounded()))
    }

    /// The mode of this name, ignoring case.
    static func named(_ name: String, in modes: [TimerPreset]) -> TimerPreset? {
        modes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The list after saving `name`: a mode of the same name in any case is replaced. Sorted by name.
    static func saving(_ name: String, seconds: Int, into modes: [TimerPreset]) -> [TimerPreset] {
        sorted(modes.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
               + [TimerPreset(name: name, seconds: seconds)])
    }

    static func sorted(_ modes: [TimerPreset]) -> [TimerPreset] {
        modes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Reads a duration a person typed or wrote: "25" (minutes), "25 min", "90s", "1h 15m", "1h15", "2.5 min",
/// "1:30" (minutes:seconds), "1:05:00" (hours:minutes:seconds). Handwriting look-alikes next to digits are fixed
/// ("I5" is 15, "O5:00" is 05:00). Returns whole seconds in 1 s…24 h, or nil.
/// ponytail: unit words match by their English first letter (h, m, s); digits and clock forms work in any language.
enum DurationParser {
    static func seconds(from raw: String) -> Int? {
        let text = normalise(raw)
        guard !text.isEmpty else { return nil }
        guard let value = text.contains(":") ? clock(text) : units(text) else { return nil }
        let s = Int(value.rounded())
        return (1...TimerEngine.maxSeconds).contains(s) ? s : nil
    }

    static func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }

    static func normalise(_ raw: String) -> String {
        let chars = Array(raw.lowercased().replacingOccurrences(of: ",", with: "."))
        var out = ""
        for (i, c) in chars.enumerated() {
            let prev: Character = i > 0 ? chars[i - 1] : " "
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            let nearDigit = isDigit(prev) || isDigit(next) || prev == ":" || next == ":"
            if nearDigit && c == "o" {
                out.append("0")
            } else if nearDigit && (c == "l" || c == "i" || c == "|") {
                out.append("1")
            } else {
                out.append(c)
            }
        }
        var trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    /// "m:ss" or "h:mm:ss".
    static func clock(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) else {
            return nil
        }
        let n = parts.compactMap { Int($0) }
        guard n.count == parts.count else { return nil }
        if n.count == 2 {
            guard n[1] < 60 else { return nil }
            return Double(n[0] * 60 + n[1])
        }
        guard n[1] < 60, n[2] < 60 else { return nil }
        return Double(n[0] * 3600 + n[1] * 60 + n[2])
    }

    /// Number-unit pairs with decreasing units; a bare number is minutes, or the next unit down after a unit.
    static func units(_ text: String) -> Double? {
        let chars = Array(text)
        var i = 0
        var total = 0.0
        var last: Double?
        while i < chars.count {
            if chars[i].isWhitespace {
                i += 1
                continue
            }
            var number = ""
            while i < chars.count, isDigit(chars[i]) || chars[i] == "." {
                number.append(chars[i])
                i += 1
            }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var word = ""
            while i < chars.count, chars[i].isLetter {
                word.append(chars[i])
                i += 1
            }
            let unit: Double
            if word.isEmpty {
                if last == nil || last == 3600 {
                    unit = 60
                } else if last == 60 {
                    unit = 1
                } else {
                    return nil
                }
            } else {
                guard let u = unitValue(word) else { return nil }
                unit = u
            }
            if let l = last, unit >= l { return nil }
            total += value * unit
            last = unit
        }
        return last == nil ? nil : total
    }

    static func unitValue(_ word: String) -> Double? {
        switch word.first {
        case "h": return 3600
        case "m": return word.hasPrefix("ms") ? nil : 60
        case "s": return 1
        default: return nil
        }
    }
}

/// Picks a duration out of handwriting recognition: the lines in reading order joined, then each line and its
/// alternatives; the first candidate that parses wins.
enum TimerRecognition {
    /// Rows top to bottom (a box whose middle lies inside the row's first box joins that row), each left to right,
    /// so "2" and "5" written a little out of level still read as 25.
    static func readingOrder(_ lines: [TextRecognition]) -> [TextRecognition] {
        var rows: [[TextRecognition]] = []
        for box in lines.sorted(by: { $0.bbox.y + $0.bbox.height / 2 < $1.bbox.y + $1.bbox.height / 2 }) {
            let middle = box.bbox.y + box.bbox.height / 2
            if let first = rows.last?.first, middle <= first.bbox.y + first.bbox.height {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.flatMap { row in row.sorted { $0.bbox.x < $1.bbox.x } }
    }

    static func bestDuration(_ lines: [TextRecognition]) -> (text: String, seconds: Int)? {
        let ordered = readingOrder(lines)
        let texts = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var candidates = [texts.joined(), texts.joined(separator: " ")] + texts
        for line in ordered { candidates += line.alternatives }
        for candidate in candidates {
            if let s = DurationParser.seconds(from: candidate) { return (candidate, s) }
        }
        return nil
    }
}

enum TimerFormat {
    private static let shortFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .short
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    private static let fullFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .full
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// "04:12", "1:05:00". Countdowns round up, so a timer shows 25:00 when it starts and 00:01 in its last second.
    static func clock(_ seconds: Double, roundingUp: Bool = false) -> String {
        let total = max(0, Int(roundingUp ? seconds.rounded(.up) : seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(two(m)):\(two(s))"
    }

    /// Lap times with tenths: "01:02.3".
    static func lap(_ seconds: Double) -> String {
        let tenths = max(0, Int((seconds * 10).rounded(.down)))
        return clock(Double(tenths / 10)) + "." + String(tenths % 10)
    }

    /// "25 min", "1 hr, 15 min" (localised).
    static func short(_ seconds: Int) -> String {
        shortFormatter.string(from: TimeInterval(seconds)) ?? clock(Double(seconds))
    }

    /// "25 minutes", for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        fullFormatter.string(from: max(0, seconds)) ?? clock(seconds)
    }

    /// "1 lap", "3 laps".
    static func laps(_ count: Int) -> String {
        count == 1 ? String(localized: "1 lap") : String(localized: "\(count) laps")
    }

    /// What the bar and the panel show: time left on a countdown, time run on a stopwatch.
    static func display(_ e: TimerEngine, at t: Date) -> String {
        e.kind == .timer ? clock(e.remaining(at: t), roundingUp: true) : clock(e.elapsed(at: t))
    }

    static func spokenDisplay(_ e: TimerEngine, at t: Date) -> String {
        if e.kind == .stopwatch { return String(localized: "\(spoken(e.elapsed(at: t).rounded(.down))) elapsed") }
        if e.state == .finished { return String(localized: "Time's up") }
        return String(localized: "\(spoken(e.remaining(at: t).rounded(.up))) remaining")
    }
}
