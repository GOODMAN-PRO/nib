import Foundation
import CoreGraphics
import CryptoKit
import EventKit
import UIKit
import UserNotifications
import os
import NibContracts

// The calendar side of F075: the event model, EventKit behind `CalendarProvider`, the device-local event cache the
// planner template draws from, reminder planning and scheduling, and `CalendarStore`, which ties them together for the
// commands and the UI. Nothing here prompts for access on its own: the first prompt comes from a user action
// (`calendar.events` run as the user, which the Calendar tab's "Connect Calendars" button does).

let calendarLog = Logger(subsystem: "app.nib", category: "calendar")

// MARK: - Model

/// Your answer to an invitation (the `EKParticipantStatus` of the attendee that is you). `none`: an event you own or
/// were not invited to.
enum RSVPStatus: String, Codable, CaseIterable {
    case none, accepted, declined, tentative, pending, delegated
}

/// `EKEventStatus`.
enum CalendarEventStatus: String, Codable, CaseIterable {
    case none, confirmed, tentative, cancelled
}

struct CalendarAttendee: Codable, Hashable {
    var name: String
    var email: String?
    var status: RSVPStatus
    /// required | optional | chair | nonParticipant | unknown
    var role: String
    var isCurrentUser: Bool

    var displayName: String { name.isEmpty ? (email ?? "") : name }
}

/// A calendar and the account it belongs to (iCloud, a Google or Outlook account added in iOS Settings, On My iPad).
struct CalendarInfo: Codable, Hashable {
    var id: String
    var title: String
    /// "#RRGGBBAA".
    var color: String
    /// Account name ("iCloud", "Gmail", an Exchange address, "Default").
    var source: String
    /// local | exchange | calDAV | mobileMe | subscribed | birthdays | unknown
    var kind: String
}

/// One occurrence of a calendar event, as a value (EventKit objects never leave `EventKitCalendarProvider`).
struct CalendarEvent: Codable, Equatable, Identifiable {
    /// `CalendarEventID`: stable across devices and launches ("yyyyMMdd-<12 hex>").
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var url: String?
    var calendar: CalendarInfo
    var attendees: [CalendarAttendee]
    var organizer: String?
    var rsvp: RSVPStatus
    var status: CalendarEventStatus
    var recurring: Bool
    /// `CalendarEventID.key`: the same when the event is moved (its `id` changes), so a note stays linked to it.
    var key: String? = nil

    var colour: RGBA { RGBA(hex: calendar.color) ?? CalendarPalette.fallback }
    var isDeclined: Bool { rsvp == .declined || status == .cancelled }

    /// All-day events first, then by start, end, title and id.
    static func chronological(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.allDay != b.allDay { return a.allDay }
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
        return a.id < b.id
    }
}

enum CalendarPalette {
    /// The ink a calendar without a colour is drawn in.
    static var fallback: RGBA { rgba(NibInk.cobalt.hex) }

    static func rgba(_ hex: UInt32, alpha: UInt8 = 255) -> RGBA {
        RGBA(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF), alpha)
    }

    /// A CGColor (any colour space) as "#RRGGBBAA" in sRGB; nil when it cannot be converted.
    static func hex(_ cg: CGColor?) -> String? {
        guard let cg = cg, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cg.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let alpha = c.count >= 4 ? c[3] : 1
        return RGBA(byte(c[0]), byte(c[1]), byte(c[2]), byte(alpha)).hex
    }
}

// MARK: - Event ids

/// Event ids that survive relaunches and match across devices (the event→note map is synced with the library):
/// the occurrence's day ("yyyyMMdd", UTC for timed events, the calendar day for all-day ones), a dash, and 12 hex
/// characters of SHA-256 over the calendar item's external identifier and the occurrence. Recurring events get one id
/// per occurrence. Moving an event changes its id; its `key` stays, so the note link follows it.
enum CalendarEventID {
    static func make(externalID: String, occurrence: Date, allDay: Bool, calendar: Calendar) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        let day = (allDay ? calendar : utc).dateComponents([.year, .month, .day], from: occurrence)
        return stamp(day) + "-" + hex12(externalID + "|" + occurrenceKey(occurrence, allDay: allDay, calendar: calendar))
    }

    /// 12 hex characters that survive moving the event: SHA-256 over the external identifier alone for a one-off
    /// event, and over the identifier and the original occurrence (EventKit's `occurrenceDate`, which stays put when
    /// one occurrence is moved) for an occurrence of a recurring event (`recurrence` nil = one-off).
    static func key(externalID: String, recurrence occurrence: Date?, allDay: Bool, calendar: Calendar) -> String {
        guard let o = occurrence else { return hex12("k|" + externalID) }
        return hex12("k|" + externalID + "|" + occurrenceKey(o, allDay: allDay, calendar: calendar))
    }

    private static func occurrenceKey(_ occurrence: Date, allDay: Bool, calendar: Calendar) -> String {
        if allDay { return "d" + stamp(calendar.dateComponents([.year, .month, .day], from: occurrence)) }
        return "t" + String(Int((occurrence.timeIntervalSince1970 / 60).rounded(.down)))
    }

    private static func hex12(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The UTC day the id names (its first 8 characters), as the start of that day in UTC.
    static func day(of id: String) -> Date? {
        guard id.count >= 8 else { return nil }
        let digits = String(id.prefix(8))
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(digits) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        let comps = DateComponents(year: v / 10_000, month: (v / 100) % 100, day: v % 100)
        guard let date = utc.date(from: comps) else { return nil }
        let back = utc.dateComponents([.year, .month, .day], from: date)
        return back.year == comps.year && back.month == comps.month && back.day == comps.day ? date : nil
    }

    /// Ids are safe in settings names and JSON (NibID characters).
    static func isValid(_ id: String) -> Bool { NibID.isValid(id) }

    private static func stamp(_ c: DateComponents) -> String {
        String(format: "%04ld%02ld%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Access and the EventKit provider

enum CalendarAccess: String, Codable, CaseIterable {
    /// Full access to events (iOS 17 `fullAccess`).
    case granted
    case notDetermined
    case denied
    case restricted
    /// Add-only access: Nib cannot read events with it.
    case writeOnly
    /// No calendar service here (package tests, disabled).
    case unavailable
}

/// EventKit behind a small protocol, so tests use an in-memory fake and hostless runs never touch `EKEventStore`.
protocol CalendarProvider: AnyObject {
    /// Current authorisation; cheap and callable from any thread.
    var access: CalendarAccess { get }
    /// Shows the system prompt. Call only for a user action. Returns the access afterwards.
    func requestAccess() async -> CalendarAccess
    /// Occurrences overlapping [from, to). Slow: call off the main actor.
    func events(from: Date, to: Date) throws -> [CalendarEvent]
    /// Calendars that hold events.
    func calendars() -> [CalendarInfo]
    /// Calls `handler` on the main queue when the calendar database changes (a sync, another app). Keep the token.
    func observeChanges(_ handler: @escaping () -> Void) -> AnyObject?
}

/// No calendar here (hostless package tests): every read is `unavailable`.
final class UnavailableCalendarProvider: CalendarProvider {
    var access: CalendarAccess { .unavailable }
    func requestAccess() async -> CalendarAccess { .unavailable }
    func events(from: Date, to: Date) throws -> [CalendarEvent] { throw NibError.unavailable("the calendar (EventKit)") }
    func calendars() -> [CalendarInfo] { [] }
    func observeChanges(_ handler: @escaping () -> Void) -> AnyObject? { nil }
}

/// The device's calendars through EventKit: iCloud, and every Google, Outlook/Exchange or CalDAV account added in iOS
/// Settings › Calendar › Accounts appear here without any sign-in inside Nib.
final class EventKitCalendarProvider: CalendarProvider {
    private let lock = NSLock()
    private var storage: EKEventStore?

    /// Created on first use (initialising an event store is slow), recreated after access is granted so calendars
    /// that appeared with the grant are visible.
    private var store: EKEventStore {
        lock.lock()
        defer { lock.unlock() }
        if let s = storage { return s }
        let s = EKEventStore()
        storage = s
        return s
    }

    var access: CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted { resetStore() }
        } catch {
            calendarLog.error("calendar access request failed: \(error.localizedDescription, privacy: .public)")
        }
        return access
    }

    /// A fresh event store (calendars that came with a new grant show up in it).
    private func resetStore() {
        lock.lock()
        storage = EKEventStore()
        lock.unlock()
    }

    func events(from: Date, to: Date) throws -> [CalendarEvent] {
        guard access == .granted else { throw NibError.unavailable("calendar access") }
        let s = store
        let predicate = s.predicateForEvents(withStart: from, end: to, calendars: nil)
        let calendar = Calendar.current
        var seen = Set<String>()
        var out: [CalendarEvent] = []
        for e in s.events(matching: predicate) {
            guard let event = Self.convert(e, calendar: calendar), seen.insert(event.id).inserted else { continue }
            out.append(event)
        }
        return out.sorted(by: CalendarEvent.chronological)
    }

    func calendars() -> [CalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event).map(Self.info)
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func observeChanges(_ handler: @escaping () -> Void) -> AnyObject? {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in handler() }
    }

    // MARK: Conversion

    static func convert(_ e: EKEvent, calendar: Calendar) -> CalendarEvent? {
        let startDate: Date? = e.startDate
        let endDate: Date? = e.endDate
        guard let start = startDate else { return nil }
        let end = max(endDate ?? start, start)
        let external: String? = e.calendarItemExternalIdentifier
        let local: String? = e.calendarItemIdentifier
        let occurrenceDate: Date? = e.occurrenceDate
        let identifier = (external?.isEmpty == false ? external : nil) ?? local ?? UUID().uuidString
        let occurrence = occurrenceDate ?? start
        let id = CalendarEventID.make(externalID: identifier, occurrence: occurrence, allDay: e.isAllDay,
                                      calendar: calendar)
        let key = CalendarEventID.key(externalID: identifier, recurrence: e.hasRecurrenceRules ? occurrence : nil,
                                      allDay: e.isAllDay, calendar: calendar)
        let people = (e.attendees ?? []).filter { $0.participantType != .room && $0.participantType != .resource }
        let attendees = people.map(attendee)
        let organizer: EKParticipant? = e.organizer
        var rsvp = attendees.first { $0.isCurrentUser }?.status ?? .none
        if organizer?.isCurrentUser == true { rsvp = .none }
        let cal: EKCalendar? = e.calendar
        let rawTitle: String? = e.title
        return CalendarEvent(
            id: id, title: (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: start, end: end, allDay: e.isAllDay,
            location: nonEmpty(e.location), notes: nonEmpty(e.notes).map { String($0.prefix(2_000)) },
            url: e.url?.absoluteString,
            calendar: cal.map(info) ?? CalendarInfo(id: "", title: "", color: CalendarPalette.fallback.hex, source: "",
                                                    kind: "unknown"),
            attendees: attendees, organizer: organizer.map { nonEmpty($0.name) ?? email($0) ?? "" },
            rsvp: rsvp, status: status(e.status), recurring: e.hasRecurrenceRules, key: key)
    }

    static func info(_ c: EKCalendar) -> CalendarInfo {
        let colour: CGColor? = c.cgColor
        let source: EKSource? = c.source
        let title: String? = c.title
        return CalendarInfo(id: c.calendarIdentifier, title: title ?? "",
                            color: CalendarPalette.hex(colour) ?? CalendarPalette.fallback.hex,
                            source: source?.title ?? "", kind: source.map { kind($0.sourceType) } ?? "unknown")
    }

    static func attendee(_ p: EKParticipant) -> CalendarAttendee {
        CalendarAttendee(name: nonEmpty(p.name) ?? "", email: email(p), status: rsvp(p.participantStatus),
                         role: role(p.participantRole), isCurrentUser: p.isCurrentUser)
    }

    static func rsvp(_ s: EKParticipantStatus) -> RSVPStatus {
        switch s {
        case .accepted, .completed: return .accepted
        case .declined: return .declined
        case .tentative, .inProcess: return .tentative
        case .pending: return .pending
        case .delegated: return .delegated
        case .unknown: return .none
        @unknown default: return .none
        }
    }

    static func role(_ r: EKParticipantRole) -> String {
        switch r {
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "nonParticipant"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    static func status(_ s: EKEventStatus) -> CalendarEventStatus {
        switch s {
        case .confirmed: return .confirmed
        case .tentative: return .tentative
        case .canceled: return .cancelled
        case .none: return .none
        @unknown default: return .none
        }
    }

    static func kind(_ t: EKSourceType) -> String {
        switch t {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    static func email(_ p: EKParticipant) -> String? {
        let s = p.url.absoluteString
        guard s.lowercased().hasPrefix("mailto:") else { return nil }
        return nonEmpty(String(s.dropFirst(7)).removingPercentEncoding)
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Event cache (thread-safe)

/// The events Nib last read, per synced date range. The planner template draws from it on render threads (it never
/// calls EventKit), the Calendar tab shows it while a sync runs, and `calendar.createNote` finds events in it.
/// Device-local (Application Support), because each device reads its own calendars; nothing here is synced.
final class CalendarEventCache {
    struct SyncedRange: Codable, Equatable {
        var from: Date
        var to: Date
        var at: Date
    }

    private struct Snapshot: Codable {
        var version: Int
        var events: [CalendarEvent]
        var ranges: [SyncedRange]
    }

    /// How far from now events are kept.
    static let horizon: TimeInterval = 400 * 86_400
    static let maxEvents = 5_000
    static let maxRanges = 64

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/calendar-cache.json")
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "app.nib.calendar.cache", qos: .utility)
    private var byID: [String: CalendarEvent] = [:]
    private var ranges: [SyncedRange] = []
    private var loaded = false
    private var changes: UInt64 = 0

    /// `fileURL` nil = memory only (tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Reads the cache file now (`CalendarStore.begin` calls it off the main actor), so the first read on the main
    /// actor or a render thread never decodes several megabytes while holding the lock.
    func preload() {
        lock.lock()
        loadIfNeeded()
        lock.unlock()
    }

    /// Incremented on every store and clear.
    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    func events(overlapping from: Date, _ to: Date) -> [CalendarEvent] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return byID.values.filter { Self.overlaps($0, from, to) }.sorted(by: CalendarEvent.chronological)
    }

    func event(_ id: String) -> CalendarEvent? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return byID[id]
    }

    /// When [from, to) was last read in full (the oldest of the newest ranges that cover it); nil = not covered.
    func lastSync(covering from: Date, _ to: Date) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return Self.coverage(ranges, from: from, to: to)
    }

    var latestSync: Date? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return ranges.map { $0.at }.max()
    }

    /// Replaces everything cached for [from, to) with `fetched` (all events overlapping the range) and records the
    /// range as read at `at`.
    func store(_ fetched: [CalendarEvent], from: Date, to: Date, at: Date) {
        guard from < to else { return }
        lock.lock()
        loadIfNeeded()
        byID = byID.filter { !Self.overlaps($0.value, from, to) }
        for e in fetched { byID[e.id] = e }
        ranges.removeAll { $0.from >= from && $0.to <= to }
        ranges.append(SyncedRange(from: from, to: to, at: at))
        prune(now: at)
        changes &+= 1
        let snapshot = Snapshot(version: 1, events: Array(byID.values), ranges: ranges)
        lock.unlock()
        persist(snapshot)
    }

    /// Forgets every event (calendar access was turned off).
    func clear() {
        lock.lock()
        loaded = true
        let hadData = !byID.isEmpty || !ranges.isEmpty
        byID = [:]
        ranges = []
        changes &+= 1
        lock.unlock()
        guard hadData, let url = fileURL else { return }
        writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// An event overlaps [from, to) when it starts before `to` and ends after `from`; a zero-length event counts
    /// when it starts inside the range.
    static func overlaps(_ e: CalendarEvent, _ from: Date, _ to: Date) -> Bool {
        if e.end <= e.start { return e.start >= from && e.start < to }
        return e.start < to && e.end > from
    }

    /// Pure: the newest sync time at which [from, to) is covered by `ranges` (newest ranges are used first, so the
    /// answer is the oldest time among the ranges needed); nil when the ranges leave a gap.
    static func coverage(_ ranges: [SyncedRange], from: Date, to: Date) -> Date? {
        guard from < to else { return nil }
        var used: [(Date, Date)] = []
        for r in ranges.sorted(by: { $0.at > $1.at }) {
            let a = max(r.from, from), b = min(r.to, to)
            guard a < b else { continue }
            used.append((a, b))
            if covers(used, from, to) { return r.at }
        }
        return nil
    }

    private static func covers(_ intervals: [(Date, Date)], _ from: Date, _ to: Date) -> Bool {
        var cursor = from
        for (a, b) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if a > cursor { return false }
            if b > cursor { cursor = b }
            if cursor >= to { return true }
        }
        return cursor >= to
    }

    // MARK: Private (call with the lock held)

    /// Drops events more than `horizon` from `now` and clips every synced range to the horizon, so coverage never
    /// claims a span whose events were dropped (a later page of `calendar.events` then reads the calendar again).
    private func prune(now: Date) {
        let oldest = now.addingTimeInterval(-Self.horizon), newest = now.addingTimeInterval(Self.horizon)
        byID = byID.filter { $0.value.end >= oldest && $0.value.start <= newest }
        ranges = ranges.compactMap { r in
            let from = max(r.from, oldest), to = min(r.to, newest)
            return from < to ? SyncedRange(from: from, to: to, at: r.at) : nil
        }
        if byID.count > Self.maxEvents {
            let ranked = byID.values.sorted { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
            let dropped = ranked.dropFirst(Self.maxEvents)
            for e in dropped {
                byID[e.id] = nil
                ranges.removeAll { $0.from < max(e.end, e.start.addingTimeInterval(1)) && $0.to > e.start }
            }
        }
        if ranges.count > Self.maxRanges {
            ranges = Array(ranges.sorted { $0.at > $1.at }.prefix(Self.maxRanges))
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            for e in snapshot.events { byID[e.id] = e }
            ranges = snapshot.ranges
        } catch {
            calendarLog.error("calendar cache unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(_ snapshot: Snapshot) {
        guard let url = fileURL else { return }
        writeQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                calendarLog.error("calendar cache not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Event → note links (settings "calendar.notes.<eventId>")

/// The value of `calendar.notes.<eventId>`: one synced key per event, so notes taken on two devices never overwrite
/// each other's links.
struct NoteLink: Codable, Equatable {
    /// "doc:D".
    var doc: String
    var title: String
    /// notebook | textDocument | whiteboard
    var kind: String
    /// Event start, ISO 8601.
    var start: String
    /// Unix seconds.
    var created: Double
    /// The event's `CalendarEventID.key`: finds this link again after the event moved and its id changed.
    var key: String?

    var documentID: DocumentID { NodeRef.documentID(from: doc) }

    enum CodingKeys: String, CodingKey { case doc, title, kind, start, created, key }

    init(doc: String, title: String, kind: String, start: String, created: Double, key: String? = nil) {
        self.doc = doc
        self.title = title
        self.kind = kind
        self.start = start
        self.created = created
        self.key = key
    }

    /// Lenient: only `doc` is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doc = try c.decode(String.self, forKey: .doc)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? DocumentKind.notebook.rawValue
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        created = try c.decodeIfPresent(Double.self, forKey: .created) ?? 0
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }
}

/// `calendar.notes.*` names by the `key` their link carries (the newest link wins), rebuilt after any of those
/// settings changes. Thread-safe: the settings observer invalidates it on the posting thread.
final class NoteKeyIndex {
    private let lock = NSLock()
    private var names: [String: String]?
    private var generation: UInt64 = 0

    func invalidate() {
        lock.lock()
        names = nil
        generation &+= 1
        lock.unlock()
    }

    /// The setting name whose link has `key`; `build` makes the whole map when it is missing (a map built while a
    /// link changed is used once and not kept).
    func name(for key: String, build: () -> [String: String]) -> String? {
        lock.lock()
        if let map = names {
            lock.unlock()
            return map[key]
        }
        let started = generation
        lock.unlock()
        let map = build()
        lock.lock()
        if generation == started { names = map }
        lock.unlock()
        return map[key]
    }
}

// MARK: - Settings

enum CalendarSettings {
    /// Prefix of the event → note map (one synced key per event).
    static let notesPrefix = "calendar.notes."
    /// Minutes before an event a reminder fires; 0 = off. Per device: reminders fire on the device that scheduled
    /// them, and notification permission is per device.
    static let reminderMinutes = SettingKey("calendar.reminderMinutes", default: 0)
    /// What "Take Notes" creates: notebook | textDocument | whiteboard.
    static let noteKind = SettingKey("calendar.noteKind", default: DocumentKind.notebook.rawValue, synced: true)

    static let reminderChoices = [0, 1, 5, 10, 15, 30]
    static let noteKinds: [DocumentKind] = [.notebook, .textDocument, .whiteboard]

    static func noteName(_ event: String) -> String { notesPrefix + event }

    static func declare(_ s: SettingsStore, owner: String) {
        s.declarePrefix(notesPrefix, synced: true,
                        summary: "Note linked to a calendar event: {doc, title, kind, start, created, key} (written by calendar.createNote).",
                        owner: owner,
                        schema: .obj(["doc": .ref, "title": .str(), "kind": .str(), "start": .str(), "created": .num(),
                                      "key": .str()],
                                     required: ["doc"]))
        s.declare(reminderMinutes, summary: "Remind before calendar events, in minutes, with a Take Notes action (0 = off).",
                  owner: owner, schema: .int(min: 0, max: 120))
        s.declare(noteKind, summary: "Kind of document Take Notes creates for an event: notebook, textDocument or whiteboard.",
                  owner: owner, schema: .str(choices: noteKinds.map { $0.rawValue }))
    }
}

// MARK: - Dates

enum CalendarDates {
    /// "2026-09-30" (the start of that day here) or an ISO 8601 date-time ("2026-09-30T09:00:00Z", fractional
    /// seconds allowed).
    static func parse(_ s: String, calendar: Calendar = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count == 10, t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let parts = t.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = calendar.date(from: comps) else { return nil }
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
            return calendar.startOfDay(for: date)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: t) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: t)
    }

    /// ISO 8601 with the offset of `timeZone` ("2026-09-30T14:00:00+01:00").
    static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// "2026-09-30" in `calendar`'s time zone.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Today and the six days after it.
    static func upcomingWindow(now: Date = Date(), calendar: Calendar = .current, days: Int = 7) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        return DateInterval(start: start, end: end)
    }
}

// MARK: - Reminders

enum CalendarReminderNames {
    static let category = "calendar.event"
    static let takeNotesAction = "calendar.takeNotes"
    static let identifierPrefix = "calendar.reminder."
    static let eventKey = "calendarEvent"
}

struct PlannedReminder: Equatable {
    var identifier: String
    var eventID: String
    var fireDate: Date
    var title: String
    var body: String
}

/// Which reminders to schedule. Pure, so it is unit-tested.
enum CalendarReminderPlanner {
    /// How far ahead reminders are scheduled (they are rebuilt on every sync and launch).
    static let window: TimeInterval = 7 * 86_400
    /// iOS keeps at most 64 pending notifications per app; the rest belong to other features.
    static let limit = 32

    /// Timed events that start within `window` whose reminder is still in the future; declined, cancelled and all-day
    /// events get none. Soonest first, at most `limit`.
    static func plan(_ events: [CalendarEvent], minutesBefore: Int, now: Date,
                     describe: (CalendarEvent, Int) -> String = CalendarReminderPlanner.body) -> [PlannedReminder] {
        guard minutesBefore > 0 else { return [] }
        let lead = TimeInterval(minutesBefore * 60)
        let horizon = now.addingTimeInterval(window)
        var due: [(event: CalendarEvent, fire: Date)] = []
        for e in events where !e.allDay && !e.isDeclined && e.start > now && e.start <= horizon {
            let fire = e.start.addingTimeInterval(-lead)
            if fire > now { due.append((e, fire)) }
        }
        due.sort { a, b in a.fire != b.fire ? a.fire < b.fire : a.event.id < b.event.id }
        var out: [PlannedReminder] = []
        for item in due.prefix(limit) {
            let e = item.event
            let title = e.title.isEmpty ? String(localized: "Event") : e.title
            out.append(PlannedReminder(identifier: CalendarReminderNames.identifierPrefix + e.id, eventID: e.id,
                                       fireDate: item.fire, title: title, body: describe(e, minutesBefore)))
        }
        return out
    }

    static func body(_ e: CalendarEvent, _ minutes: Int) -> String {
        let when = minutes == 1 ? String(localized: "Starts in 1 minute") : String(localized: "Starts in \(minutes) minutes")
        guard let place = e.location else { return when }
        return when + " · " + place
    }
}

enum NotificationAuthorization: String {
    case authorized, denied, notDetermined, unavailable
}

/// Local notifications behind a protocol (hostless tests must never touch `UNUserNotificationCenter`).
protocol NotificationScheduling: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt; call only for a user action.
    func requestAuthorization() async -> Bool
    /// Removes pending notifications whose id starts with `prefix` and schedules `reminders`.
    func replace(prefix: String, with reminders: [PlannedReminder]) async
}

final class NoNotifications: NotificationScheduling {
    func authorization() async -> NotificationAuthorization { .unavailable }
    func requestAuthorization() async -> Bool { false }
    func replace(prefix: String, with reminders: [PlannedReminder]) async {}
}

/// `UNUserNotificationCenter`: reminders carry the "Take Notes" action (category `calendar.event`). Main-actor
/// isolated, so `categoryRegistered` and the remove-then-add in `replace` never run on two threads at once.
@MainActor
final class UserNotificationScheduler: NotificationScheduling {
    private var categoryRegistered = false

    func authorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            calendarLog.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func replace(prefix: String, with reminders: [PlannedReminder]) async {
        let center = UNUserNotificationCenter.current()
        await registerCategory(center)
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map { $0.identifier }.filter { $0.hasPrefix(prefix) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        let calendar = Calendar.current
        for r in reminders {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.categoryIdentifier = CalendarReminderNames.category
            content.threadIdentifier = CalendarReminderNames.category
            content.userInfo = [CalendarReminderNames.eventKey: r.eventID]
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
            let request = UNNotificationRequest(identifier: r.identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            do {
                try await center.add(request)
            } catch {
                calendarLog.error("reminder not scheduled: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Adds the calendar category to the app's categories (other features register theirs too, so it merges).
    private func registerCategory(_ center: UNUserNotificationCenter) async {
        guard !categoryRegistered else { return }
        categoryRegistered = true
        let takeNotes = UNNotificationAction(identifier: CalendarReminderNames.takeNotesAction,
                                             title: String(localized: "Take Notes"), options: [.foreground])
        let category = UNNotificationCategory(identifier: CalendarReminderNames.category, actions: [takeNotes],
                                              intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != CalendarReminderNames.category }
        categories.insert(category)
        center.setNotificationCategories(categories)
    }
}

/// Routes the reminder's "Take Notes" action (and a tap on the reminder) to the event's note, and hands every other
/// notification to the delegate that was installed before it. Installed from `FeatCalendarFeature.register`, inside
/// `didFinishLaunching`, so the response that launched a terminated app reaches it.
final class CalendarNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// What a response to a notification does. Pure, so it is unit-tested.
    enum Route: Equatable {
        /// Open (or create) the note of this event.
        case takeNotes(String)
        /// A calendar reminder dismissed or without a usable event id: nothing to do.
        case ignore
        /// Not a calendar reminder: the previous delegate handles it.
        case forward
    }

    weak var previous: UNUserNotificationCenterDelegate?
    private let onTakeNotes: @MainActor (String) -> Void

    init(previous: UNUserNotificationCenterDelegate?, onTakeNotes: @escaping @MainActor (String) -> Void) {
        self.previous = previous
        self.onTakeNotes = onTakeNotes
    }

    static func route(category: String, action: String, userInfo: [AnyHashable: Any]) -> Route {
        guard category == CalendarReminderNames.category else { return .forward }
        guard action == CalendarReminderNames.takeNotesAction || action == UNNotificationDefaultActionIdentifier,
              let id = userInfo[CalendarReminderNames.eventKey] as? String, CalendarEventID.isValid(id) else { return .ignore }
        return .takeNotes(id)
    }

    /// Handles one response. `forward` hands it to the previous delegate and returns false when there is none (that
    /// delegate then calls the completion handler itself); `completion` runs otherwise, exactly once.
    func receive(category: String, action: String, userInfo: [AnyHashable: Any], forward: () -> Bool,
                 completion: @escaping () -> Void) {
        switch Self.route(category: category, action: action, userInfo: userInfo) {
        case .forward:
            if !forward() { completion() }
        case .ignore:
            completion()
        case .takeNotes(let id):
            let handler = onTakeNotes
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(id) }
            } else {
                Task { @MainActor in handler(id) }
            }
            completion()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.categoryIdentifier == CalendarReminderNames.category {
            completionHandler([.banner, .list, .sound])
            return
        }
        if previous?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil {
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let previous = self.previous
        receive(category: content.categoryIdentifier, action: response.actionIdentifier, userInfo: content.userInfo,
                forward: {
                    previous?.userNotificationCenter?(center, didReceive: response,
                                                      withCompletionHandler: completionHandler) != nil
                },
                completion: completionHandler)
    }
}

// MARK: - The store

/// The calendar state of the app: access, the upcoming events the Calendar tab shows, the event cache, note links and
/// reminders. Commands call `fetch` / `event(id:)`; the UI reads events through `calendar.events` (`load`).
@MainActor
final class CalendarStore: ObservableObject {
    static let serviceKey = "calendar.store"

    static func shared(_ app: NibApp?) -> CalendarStore? { app?.services.get(serviceKey, as: CalendarStore.self) }

    static func require(_ ctx: CommandContext) throws -> CalendarStore {
        guard let store = shared(ctx.app) else { throw NibError.unavailable("the calendar") }
        return store
    }

    weak var app: NibApp?
    let cache: CalendarEventCache

    @Published private(set) var access: CalendarAccess = .notDetermined
    /// Today and the next six days, from the cache after every read that touches them.
    @Published private(set) var upcoming: [CalendarEvent] = []
    @Published private(set) var upcomingLoaded = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: NibError?
    /// Bumps when the cache or an event's note link changes (rows, the planner pill).
    @Published private(set) var revision = 0
    @Published private(set) var notifications: NotificationAuthorization = .notDetermined
    /// Accounts the calendars belong to ("iCloud", "Google"), for the Calendar tab's footnote.
    @Published private(set) var accounts: [String] = []

    /// Reminder "Take Notes" taps that arrived before `begin()` or before any window existed (Nib was launched by
    /// the notification); `begin()` and the next `session.activated` run them.
    private(set) var pendingTakeNotes: [String] = []
    /// `begin()`'s first work (queued Take Notes, then a refresh); tests await it.
    private(set) var startTask: Task<Void, Never>?

    private var providerStorage: CalendarProvider?
    private var notifierStorage: NotificationScheduling?
    private var observers: [NSObjectProtocol] = []
    private var providerToken: AnyObject?
    private var router: CalendarNotificationRouter?
    private var sessionSubscription: EventSubscription?
    private var began = false
    private var lastBackgroundRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    /// The last reminder rebuild: each rebuild waits for the one before it (see `rescheduleReminders`).
    private var reminderTask: Task<Void, Never>?
    /// Links by key (`noteEntry`); `refile` in CalendarCommands.swift invalidates it too.
    let noteKeys = NoteKeyIndex()
    private var noteKeysToken: NSObjectProtocol?

    init(app: NibApp, cache: CalendarEventCache? = nil) {
        self.app = app
        self.cache = cache ?? CalendarEventCache(fileURL: NibApp.isHostlessTest ? nil : CalendarEventCache.defaultURL)
        // Synchronous (queue nil), so a link written by a command is found by key right after it.
        let index = noteKeys
        noteKeysToken = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                               queue: nil) { note in
            let name = note.userInfo?["name"] as? String ?? CalendarSettings.notesPrefix
            if name.hasPrefix(CalendarSettings.notesPrefix) { index.invalidate() }
        }
    }

    /// EventKit in the app; `unavailable` in hostless package tests. Tests assign a fake.
    var provider: CalendarProvider {
        get {
            if let p = providerStorage { return p }
            let p: CalendarProvider = NibApp.isHostlessTest ? UnavailableCalendarProvider() : EventKitCalendarProvider()
            providerStorage = p
            return p
        }
        set {
            providerStorage = newValue
            access = newValue.access
        }
    }

    var notifier: NotificationScheduling {
        get {
            if let n = notifierStorage { return n }
            let n: NotificationScheduling = NibApp.isHostlessTest ? NoNotifications() : UserNotificationScheduler()
            notifierStorage = n
            return n
        }
        set { notifierStorage = newValue }
    }

    // MARK: Start

    /// `FeatCalendarFeature.start`: reads the cache file off the main actor, observes settings, app activation, window
    /// activation and the calendar database, runs Take Notes taps that arrived before it, refreshes the next seven
    /// days (only when access was already granted; never prompts) and reschedules reminders.
    func begin() {
        guard !began, let app = app else { return }
        began = true
        let cache = self.cache
        Task.detached(priority: .utility) { cache.preload() }
        refreshAccess()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: SettingsStore.didChange, object: app.settings, queue: .main) { [weak self] note in
            let name = note.userInfo?["name"] as? String ?? ""
            Task { @MainActor in self?.settingChanged(name) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appBecameActive() }
        })
        sessionSubscription = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.sessionActivated else { return }
            Task { @MainActor in await self?.runPendingTakeNotes() }
        }
        startTask = Task {
            await self.runPendingTakeNotes()
            await self.backgroundRefresh(force: true)
        }
    }

    // MARK: Reminder actions

    /// The router bound to this store's Take Notes queue (`installNotificationRouter` installs it; tests call it).
    func makeNotificationRouter(previous: UNUserNotificationCenterDelegate?) -> CalendarNotificationRouter {
        CalendarNotificationRouter(previous: previous) { [weak self] id in self?.reminderTakeNotes(id) }
    }

    /// `FeatCalendarFeature.register`, inside `didFinishLaunching` (Apple requires the delegate before launch
    /// finishes, else the response that launched the app is dropped). Chains to the delegate installed before it.
    func installNotificationRouter() {
        guard router == nil, !NibApp.isHostlessTest else { return }
        let notifications = UNUserNotificationCenter.current()
        let router = makeNotificationRouter(previous: notifications.delegate)
        notifications.delegate = router
        self.router = router
    }

    /// A reminder's Take Notes: runs now when the feature has started and a window exists, else waits in
    /// `pendingTakeNotes`.
    func reminderTakeNotes(_ event: String) {
        guard began, let session = app?.services.sessions.active else {
            if !pendingTakeNotes.contains(event) { pendingTakeNotes.append(event) }
            return
        }
        Task { await self.takeNotes(event, kind: nil, session: session) }
    }

    /// Runs the queued Take Notes once the feature has started and a window exists.
    func runPendingTakeNotes() async {
        guard began, !pendingTakeNotes.isEmpty, let session = app?.services.sessions.active else { return }
        let events = pendingTakeNotes
        pendingTakeNotes = []
        for event in events { await takeNotes(event, kind: nil, session: session) }
    }

    func refreshAccess() {
        let now = provider.access
        if now != access { access = now }
        if now == .granted {
            watchProvider()
        } else if now == .denied || now == .restricted || now == .writeOnly {
            forgetEvents()
        }
    }

    private func watchProvider() {
        guard providerToken == nil else { return }
        providerToken = provider.observeChanges { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func appBecameActive() {
        refreshAccess()
        Task { await self.backgroundRefresh(force: false) }
    }

    /// Coalesces bursts of `EKEventStoreChanged`.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.backgroundRefresh(force: true)
        }
    }

    /// Re-reads the next seven days when access is granted (at most every five minutes unless forced) and
    /// reschedules reminders. Never prompts. Also asks iOS for the next background refresh (`CalendarIDs.refreshTask`),
    /// so reminders cover meetings added while Nib is not open.
    func backgroundRefresh(force: Bool) async {
        refreshAccess()
        if access == .granted {
            app?.scheduleBackgroundTask(CalendarIDs.refreshTask, earliestIn: CalendarIDs.refreshInterval)
            let now = Date()
            if force || lastBackgroundRefresh.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                lastBackgroundRefresh = now
                let window = CalendarDates.upcomingWindow(now: now)
                do {
                    _ = try await fetch(from: window.start, to: window.end, principal: .user)
                } catch {
                    calendarLog.error("calendar refresh failed: \(NibError.wrap(error).description, privacy: .public)")
                }
            }
        }
        await rescheduleReminders()
    }

    private func settingChanged(_ name: String) {
        if name.hasPrefix(CalendarSettings.notesPrefix) || name == CalendarSettings.noteKind.name {
            revision += 1
        } else if name == CalendarSettings.reminderMinutes.name {
            revision += 1
            Task { await self.rescheduleReminders() }
        }
    }

    // MARK: Reading events (commands)

    /// Reads [from, to) from the calendar for `calendar.events`: asks for access only when `principal` is the user,
    /// updates the cache, the upcoming list, planner pages and reminders.
    func fetch(from: Date, to: Date, principal: Principal) async throws -> [CalendarEvent] {
        var current = provider.access
        if current == .notDetermined {
            guard principal.isUser else {
                throw NibError(.unavailable, "Nib has not been given access to the calendar yet",
                               hint: "ask the user to open the Calendar tab in the library and connect their calendars")
            }
            current = await provider.requestAccess()
        }
        if current != access { access = current }
        switch current {
        case .granted:
            watchProvider()
        case .unavailable, .notDetermined:
            throw NibError.unavailable("the calendar (EventKit)")
        case .denied, .restricted, .writeOnly:
            forgetEvents()
            throw NibError(.unavailable, "Nib does not have full access to Calendars",
                           hint: "turn on Full Access for Nib in Settings › Privacy & Security › Calendars")
        }
        isSyncing = true
        defer { isSyncing = false }
        let source = provider
        let events: [CalendarEvent]
        let calendars: [CalendarInfo]
        do {
            (events, calendars) = try await Task.detached(priority: .userInitiated) {
                (try source.events(from: from, to: to), source.calendars())
            }.value
        } catch {
            let e = NibError.wrap(error)
            lastError = e
            throw e
        }
        lastError = nil
        var names: [String] = []
        for c in calendars where !c.source.isEmpty && !names.contains(c.source) { names.append(c.source) }
        if names != accounts { accounts = names }
        cache.store(events, from: from, to: to, at: Date())
        didUpdateCache(from: from, to: to)
        return events
    }

    /// The event with `id`: the cache first, else the calendar around the day its id names (never prompts). The read
    /// is searched before the cache, because the cache drops events beyond its horizon (a day picked far away).
    func event(id: String, principal: Principal) async throws -> CalendarEvent {
        if let e = cache.event(id) { return e }
        guard provider.access == .granted else {
            if provider.access == .unavailable { throw NibError.unavailable("the calendar (EventKit)") }
            throw NibError(.notFound, "calendar event \(id) not found",
                           hint: "list events with calendar.events first (the user must connect their calendars)")
        }
        guard let day = CalendarEventID.day(of: id) else {
            throw NibError(.invalidParams, "'\(id)' is not a calendar event id", path: "$.event",
                           hint: "use an id returned by calendar.events")
        }
        let read = try await fetch(from: day.addingTimeInterval(-86_400), to: day.addingTimeInterval(2 * 86_400),
                                   principal: principal)
        if let e = read.first(where: { $0.id == id }) { return e }
        guard let e = cache.event(id) else {
            throw NibError(.notFound, "calendar event \(id) not found", hint: "call calendar.events for that day")
        }
        return e
    }

    private func didUpdateCache(from: Date, to: Date) {
        revision += 1
        let window = CalendarDates.upcomingWindow()
        if from < window.end && to > window.start {
            upcoming = cache.events(overlapping: window.start, window.end)
            if cache.lastSync(covering: window.start, window.end) != nil { upcomingLoaded = true }
            Task { await self.rescheduleReminders() }
        }
        refreshPlannerPages()
    }

    /// Calendar access went away: forget every cached event (privacy) and redraw planner pages.
    private func forgetEvents() {
        guard cache.latestSync != nil || !upcoming.isEmpty else { return }
        cache.clear()
        upcoming = []
        upcomingLoaded = false
        revision += 1
        refreshPlannerPages()
    }

    /// Planner pages draw from the cache: re-registering the template tells the renderer to drop tiles of every page
    /// that uses it (registry change signal), and loaded planner pages are invalidated directly as well.
    private func refreshPlannerPages() {
        guard let app = app else { return }
        app.content.templates.register(EventPlannerTemplate.definition(cache: cache))
        if let renderer = app.services.renderer {
            for doc in app.workspace.loadedDocuments {
                guard let content = try? app.workspace.content(doc) else { continue }
                for page in content.livePages where page.background.template?.id == EventPlannerTemplate.id {
                    renderer.invalidate(doc: doc, page: page.id, rect: nil)
                }
            }
        }
        app.ui.setNeedsChromeUpdate()
    }

    // MARK: Reading events (UI, through the command)

    /// Events in [from, to) through `calendar.events` as the user (the first call shows the access prompt).
    func load(from: Date, to: Date, session: EditorSession?) async throws -> [CalendarEvent] {
        guard let app = app else { throw NibError.unavailable("the app") }
        let out = try await app.bus.run(CalendarEvents.self,
                                        .init(from: CalendarDates.iso(from), to: CalendarDates.iso(to), cursor: nil,
                                              limit: CalendarEvents.maxLimit),
                                        session: session)
        var events = out.events.compactMap { $0.event }
        var cursor = out.cursor
        while let next = cursor {
            let page = try await app.bus.run(CalendarEvents.self,
                                             .init(from: CalendarDates.iso(from), to: CalendarDates.iso(to), cursor: next,
                                                   limit: CalendarEvents.maxLimit),
                                             session: session)
            events += page.events.compactMap { $0.event }
            cursor = page.cursor
        }
        return events
    }

    /// The Calendar tab: the next seven days (connects the calendar on first use when `connect` is true).
    func loadUpcoming(session: EditorSession?, connect: Bool) async {
        refreshAccess()
        guard access == .granted || (connect && access == .notDetermined) else { return }
        let window = CalendarDates.upcomingWindow()
        do {
            _ = try await load(from: window.start, to: window.end, session: session)
            upcomingLoaded = true
        } catch {
            lastError = NibError.wrap(error)
            refreshAccess()
        }
    }

    // MARK: Notes

    /// Where the link of `event` is stored: its own `calendar.notes.<id>`, or, when the event was moved (new id, same
    /// key), the entry another id of the same event holds. `key` defaults to the cached event's key.
    func noteEntry(for event: String, key: String? = nil) -> (name: String, link: NoteLink)? {
        guard CalendarEventID.isValid(event), let settings = app?.settings else { return nil }
        let own = CalendarSettings.noteName(event)
        if let link = Self.link(settings.json(own)) { return (own, link) }
        guard let k = key ?? cache.event(event)?.key,
              let name = noteKeys.name(for: k, build: { Self.keyIndex(settings) }), name != own,
              let link = Self.link(settings.json(name)), link.key == k else { return nil }
        return (name, link)
    }

    func noteLink(for event: String, key: String? = nil) -> NoteLink? { noteEntry(for: event, key: key)?.link }

    /// The linked note when its document is still in the library (not trashed).
    func liveNote(for event: String, key: String? = nil) -> (link: NoteLink, doc: DocumentID)? {
        guard let link = noteLink(for: event, key: key), let doc = liveDocument(link) else { return nil }
        return (link, doc)
    }

    /// The link's document when it is still in the library (not trashed).
    func liveDocument(_ link: NoteLink) -> DocumentID? {
        let doc = link.documentID
        guard let library = app?.services.library, let node = library.node(doc), node.trashedAt == nil else { return nil }
        return doc
    }

    private static func link(_ json: JSONValue?) -> NoteLink? {
        guard let json = json, json != .null else { return nil }
        return try? json.decode(NoteLink.self)
    }

    /// Every stored link's key → its setting name (the newest link wins when two carry one key).
    private static func keyIndex(_ settings: SettingsStore) -> [String: String] {
        var best: [String: (name: String, created: Double)] = [:]
        for name in settings.names(prefix: CalendarSettings.notesPrefix) {
            guard let link = link(settings.json(name)), let key = link.key else { continue }
            if let current = best[key], current.created >= link.created { continue }
            best[key] = (name, link.created)
        }
        return best.mapValues { $0.name }
    }

    /// Take Notes (the Calendar tab and the reminder action): opens the event's note, creating it first when there is
    /// none. Runs `calendar.createNote` and `calendar.openNote` as the user.
    func takeNotes(_ event: String, kind: DocumentKind?, session: EditorSession?) async {
        guard let app = app else { return }
        let noteKind = kind?.rawValue ?? app.settings.get(CalendarSettings.noteKind)
        do {
            if liveNote(for: event) == nil {
                _ = try await app.bus.run(CalendarCreateNote.self, .init(event: event, kind: noteKind, id: nil),
                                          session: session)
            }
            _ = try await app.bus.run(CalendarOpenNote.self, .init(event: event), session: session)
        } catch {
            report(error, command: liveNote(for: event) == nil ? CalendarCreateNote.descriptor.id : CalendarOpenNote.descriptor.id)
        }
    }

    /// Hands a failed UI command to the shell's error toast (the `NibApp.perform` path).
    func report(_ error: Error, command: String) {
        let e = NibError.wrap(error)
        calendarLog.error("\(command, privacy: .public) failed: \(e.description, privacy: .public)")
        NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: ["command": command, "error": e])
    }

    // MARK: Reminders

    /// Rebuilds the reminders for the next week from the cache (none when the setting is 0 or access is missing).
    /// Rebuilds run one at a time, in call order: each waits for the previous one before it reads the setting, so a
    /// rebuild that read "10 minutes" can never add its reminders after a later one turned them off.
    func rescheduleReminders() async {
        let previous = reminderTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyReminders()
        }
        reminderTask = task
        await task.value
    }

    private func applyReminders() async {
        guard let app = app else { return }
        let minutes = app.settings.get(CalendarSettings.reminderMinutes)
        let notifier = self.notifier
        let status = await notifier.authorization()
        notifications = status
        guard status == .authorized else { return }
        guard minutes > 0, access == .granted else {
            await notifier.replace(prefix: CalendarReminderNames.identifierPrefix, with: [])
            return
        }
        let now = Date()
        let events = cache.events(overlapping: now, now.addingTimeInterval(CalendarReminderPlanner.window))
        let plan = CalendarReminderPlanner.plan(events, minutesBefore: minutes, now: now)
        await notifier.replace(prefix: CalendarReminderNames.identifierPrefix, with: plan)
    }

    /// Settings and the Calendar tab's "Remind Me" menu: asks for notification permission (a user action) before
    /// turning reminders on, then changes the setting through `settings.set`.
    func setReminderMinutes(_ minutes: Int, session: EditorSession?) async {
        guard let app = app else { return }
        if minutes > 0 {
            if await notifier.authorization() == .notDetermined { _ = await notifier.requestAuthorization() }
            notifications = await notifier.authorization()
        }
        do {
            try await app.bus.execute(CommandIDs.settingsSet,
                                      ["name": .string(CalendarSettings.reminderMinutes.name), "value": .number(Double(minutes))],
                                      session: session)
        } catch {
            report(error, command: CommandIDs.settingsSet)
        }
    }

    func setNoteKind(_ kind: DocumentKind, session: EditorSession?) async {
        guard let app = app else { return }
        do {
            try await app.bus.execute(CommandIDs.settingsSet,
                                      ["name": .string(CalendarSettings.noteKind.name), "value": .string(kind.rawValue)],
                                      session: session)
        } catch {
            report(error, command: CommandIDs.settingsSet)
        }
    }
}
