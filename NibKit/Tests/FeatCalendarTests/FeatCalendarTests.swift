import XCTest
import SwiftUI
import UserNotifications
import NibContracts
import NibTesting
@testable import FeatCalendar

/// In-memory EventKit stand-in: a fixed set of events and a scripted answer to the access prompt.
final class FakeCalendarProvider: CalendarProvider {
    private let lock = NSLock()
    private var current: CalendarAccess
    private let grants: Bool
    private var stored: [CalendarEvent]
    private var prompts = 0
    private var readCount = 0

    init(access: CalendarAccess, events: [CalendarEvent], grantsOnRequest: Bool = true) {
        current = access
        grants = grantsOnRequest
        stored = events
    }

    var access: CalendarAccess {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var promptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return prompts
    }

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    func requestAccess() async -> CalendarAccess { grant() }

    /// The calendar changed (an event was moved, added or deleted in another app).
    func replace(_ events: [CalendarEvent]) {
        lock.lock()
        stored = events
        lock.unlock()
    }

    private func grant() -> CalendarAccess {
        lock.lock()
        defer { lock.unlock() }
        prompts += 1
        current = grants ? .granted : .denied
        return current
    }

    func events(from: Date, to: Date) throws -> [CalendarEvent] {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard current == .granted else { throw NibError.unavailable("calendar access") }
        return stored.filter { CalendarEventCache.overlaps($0, from, to) }.sorted(by: CalendarEvent.chronological)
    }

    func calendars() -> [CalendarInfo] {
        lock.lock()
        defer { lock.unlock() }
        var out: [CalendarInfo] = []
        for e in stored where !out.contains(e.calendar) { out.append(e.calendar) }
        return out
    }

    func observeChanges(_ handler: @escaping () -> Void) -> AnyObject? { nil }
}

/// Records every reminder rebuild; the first authorisation check is slow, so a second rebuild can start meanwhile.
@MainActor
final class FakeNotifier: NotificationScheduling {
    private(set) var replaced: [[String]] = []
    private(set) var authorizationCalls = 0

    func authorization() async -> NotificationAuthorization {
        authorizationCalls += 1
        if authorizationCalls == 1 { try? await Task.sleep(nanoseconds: 200_000_000) }
        return .authorized
    }

    func requestAuthorization() async -> Bool { true }

    func replace(prefix: String, with reminders: [PlannedReminder]) async {
        replaced.append(reminders.map { $0.eventID })
    }
}

@MainActor
final class FeatCalendarTests: XCTestCase {
    // MARK: Helpers

    static let work = CalendarInfo(id: "work", title: "Work", color: "#3478F6FF", source: "iCloud", kind: "calDAV")

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ cal: Calendar = .current) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func event(_ title: String, _ start: Date, minutes: Int = 60, allDay: Bool = false, rsvp: RSVPStatus = .accepted,
               status: CalendarEventStatus = .confirmed, attendees: [String] = [], location: String? = nil,
               recurring: Bool = false, cal: Calendar = .current) -> CalendarEvent {
        let end = allDay ? cal.date(byAdding: .day, value: max(1, minutes / 1_440), to: start)!.addingTimeInterval(-1)
                         : start.addingTimeInterval(Double(minutes) * 60)
        return CalendarEvent(
            id: CalendarEventID.make(externalID: "ext-" + title, occurrence: start, allDay: allDay, calendar: cal),
            title: title, start: start, end: end, allDay: allDay, location: location, notes: nil, url: nil,
            calendar: Self.work,
            attendees: attendees.map { CalendarAttendee(name: $0, email: nil, status: .accepted, role: "required", isCurrentUser: false) },
            organizer: nil, rsvp: rsvp, status: status, recurring: recurring,
            key: CalendarEventID.key(externalID: "ext-" + title, recurrence: recurring ? start : nil, allDay: allDay,
                                     calendar: cal))
    }

    static let day: TimeInterval = 86_400

    /// `hour`:00 on the day `days` from now (negative = in the past), here.
    func daysFromNow(_ days: Double, hour: Int = 10) -> Date {
        let d = Date().addingTimeInterval(days * Self.day)
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: d) ?? d
    }

    /// Waits (on the main actor) until `condition` holds, for at most `seconds`.
    func eventually(_ seconds: Double = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A harness with the calendar feature and a fake calendar.
    func harness(_ events: [CalendarEvent], access: CalendarAccess = .granted,
                 grants: Bool = true) -> (Harness, CalendarStore, FakeCalendarProvider) {
        let h = Harness(features: [FeatCalendarFeature.self])
        let store = CalendarStore.shared(h.app)!
        let fake = FakeCalendarProvider(access: access, events: events, grantsOnRequest: grants)
        store.provider = fake
        return (h, store, fake)
    }

    func code(_ work: () async throws -> Void) async -> NibError.Code? {
        do {
            try await work()
            return nil
        } catch let e as NibError {
            return e.code
        } catch {
            return .internalError
        }
    }

    // MARK: Registration and conformance

    func testRegistersItsCommandsTemplateTabAndPassesConformance() async {
        let h = Harness(features: [FeatCalendarFeature.self])
        let ids = Set(h.app.commands.all().filter { $0.owner == "calendar" }.map { $0.id })
        XCTAssertEqual(ids, ["calendar.events", "calendar.createNote", "calendar.openNote"])
        XCTAssertEqual(h.app.commands.descriptor("calendar.events")?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor("calendar.events")?.sensitive, true)
        XCTAssertEqual(h.app.commands.descriptor("calendar.createNote")?.effect, .library)
        XCTAssertEqual(h.app.commands.descriptor("calendar.openNote")?.effect, .session)
        XCTAssertNotNil(h.app.content.templates.get("planner.events"))
        XCTAssertEqual(h.app.ui.panels.get(CalendarIDs.tab)?.placement, .libraryTab)
        XCTAssertNotNil(h.app.ui.chromeOverlays.get(CalendarIDs.syncPill))
        XCTAssertNotNil(h.app.settings.descriptor("calendar.notes.20260930-8f3a2c1d9e4b"))
        let problems = await CommandConformance.check(features: [FeatCalendarFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testHostlessCalendarIsUnavailable() async {
        let h = Harness(features: [FeatCalendarFeature.self])
        let c = await code { try await h.run("calendar.events", ["from": "2026-09-28", "to": "2026-10-05"]) }
        XCTAssertEqual(c, .unavailable)
    }

    // MARK: Reading events

    func testOnlyTheUserTriggersTheAccessPromptAndEventsAreCached() async throws {
        let standup = event("Standup", date(2026, 9, 30, 9), minutes: 15, rsvp: .tentative, attendees: ["Ana", "Ben"])
        let (h, store, fake) = harness([standup], access: .notDetermined)

        let ai = await code { try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"], as: .ai("chat")) }
        XCTAssertEqual(ai, .unavailable)
        XCTAssertEqual(fake.promptCount, 0, "a non-user caller never shows the access prompt")

        let r = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"])
        XCTAssertEqual(fake.promptCount, 1)
        XCTAssertEqual(store.access, .granted)
        let events = r["events"]?.arrayValue ?? []
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["title"]?.stringValue, "Standup")
        XCTAssertEqual(events.first?["rsvp"]?.stringValue, "tentative")
        XCTAssertEqual(events.first?["attendees"]?.arrayValue?.count, 2)
        XCTAssertNotNil(store.cache.lastSync(covering: date(2026, 9, 30), date(2026, 10, 1)))
        XCTAssertEqual(store.cache.event(standup.id)?.title, "Standup")

        let bad = await code { try await h.run("calendar.events", ["from": "2026-10-01", "to": "2026-09-30"]) }
        XCTAssertEqual(bad, .invalidParams)
    }

    func testDeniedAccessForgetsCachedEvents() async throws {
        let (h, store, _) = harness([event("Review", date(2026, 9, 30, 14))])
        _ = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"])
        XCTAssertNotNil(store.cache.latestSync)
        store.provider = FakeCalendarProvider(access: .denied, events: [])
        let c = await code { try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"]) }
        XCTAssertEqual(c, .unavailable)
        XCTAssertNil(store.cache.latestSync)
        XCTAssertTrue(store.cache.events(overlapping: date(2026, 9, 1), date(2026, 11, 1)).isEmpty)
    }

    func testLargeResultsArePagedWithACursor() async throws {
        let people = (0..<12).map { "Participant number \($0) with a fairly long display name" }
        let many = (0..<60).map { i in
            event("Meeting \(i)", date(2026, 9, 28, 8).addingTimeInterval(Double(i) * 1_800), minutes: 25, attendees: people)
        }
        let (h, _, fake) = harness(many)
        var cursor: String?
        var seen: [String] = []
        var pages = 0
        repeat {
            var params: [String: JSONValue] = ["from": "2026-09-28", "to": "2026-10-05"]
            if let c = cursor { params["cursor"] = .string(c) }
            let r = try await h.run("calendar.events", .object(params))
            seen += (r["events"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            cursor = r["cursor"]?.stringValue
            if cursor != nil { XCTAssertEqual(r["truncated"]?.boolValue, true) }
            pages += 1
        } while cursor != nil && pages < 20
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen.count, 60)
        XCTAssertEqual(Set(seen).count, 60)
        XCTAssertEqual(fake.reads, 1, "later pages come from the first read's retained snapshot")
    }

    func testPagedCommandKeepsSupersededSnapshotAcrossInsertion() async throws {
        try await assertPagedCommandKeepsSupersededSnapshot(inserting: true)
    }

    func testPagedCommandKeepsSupersededSnapshotAcrossDeletion() async throws {
        try await assertPagedCommandKeepsSupersededSnapshot(inserting: false)
    }

    func testPagedCommandKeepsSnapshotWhenEventIsInsertedBetweenPages() async throws {
        try await assertPagedCommandKeepsSupersededSnapshot(inserting: true, publishBeforeFirstPage: false)
    }

    func testPagedCommandKeepsSnapshotWhenEventIsDeletedBetweenPages() async throws {
        try await assertPagedCommandKeepsSupersededSnapshot(inserting: false, publishBeforeFirstPage: false)
    }

    private func assertPagedCommandKeepsSupersededSnapshot(inserting: Bool, publishBeforeFirstPage: Bool = true) async throws {
        let start = Date().addingTimeInterval(3_600)
        let oldEvents = (0..<3).map { event("Old \($0)", start.addingTimeInterval(Double($0) * 600)) }
        let latest = inserting ? [event("Inserted", start.addingTimeInterval(-600))] + oldEvents : Array(oldEvents.dropFirst())
        let (h, store, _) = harness([])
        let started = expectation(description: "old calendar.events read blocked")
        let provider = BlockingCalendarRead(old: oldEvents, latest: latest, started: started)
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let params: [String: JSONValue] = ["from": .string(CalendarDates.iso(window.start)),
                                         "to": .string(CalendarDates.iso(window.end)), "limit": 1]
        let old = Task { try await h.run("calendar.events", .object(params)) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        if publishBeforeFirstPage {
            // The newer command publishes before the older command can return its first page.
            _ = try await h.run("calendar.events", .object(params))
            XCTAssertEqual(store.cache.events(overlapping: window.start, window.end).map(\.id), latest.map(\.id))
        }
        provider.release()
        var result = try await old.value
        var seen: [String] = []
        for _ in 0..<oldEvents.count {
            seen += (result["events"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            guard let cursor = result["cursor"]?.stringValue else { break }
            // Also publish changes between pages, not just while the first read is suspended.
            _ = try await store.fetch(from: window.start, to: window.end, principal: .user)
            var next = params
            next["cursor"] = .string(cursor)
            result = try await h.run("calendar.events", .object(next))
        }
        XCTAssertEqual(seen, oldEvents.map(\.id), "no duplicates, omissions, or cursor-past-end after a refresh")
        XCTAssertNil(result["cursor"]?.stringValue)
    }

    func testPagingSnapshotBoundsExpiryAndRangeValidation() throws {
        let events = [EventJSON(event("Meeting", date(2026, 9, 30, 9)), note: nil)]
        let from = date(2026, 9, 30), to = date(2026, 10, 1), now = date(2026, 9, 29)
        let pages = CalendarEventPages(maxSnapshots: 1, lifetime: 10)
        let first = try pages.retain(events, from: from, to: to, principal: .user, now: now)
        let second = try pages.retain(events, from: from, to: to, principal: .user, now: now)
        XCTAssertThrowsError(try pages.read(first + ":0", from: from, to: to, principal: .user, now: now))
        XCTAssertEqual(try pages.read(second + ":0", from: from, to: to, principal: .user, now: now).events, events)
        XCTAssertThrowsError(try pages.read(second + ":0", from: from.addingTimeInterval(1), to: to, principal: .user, now: now))
        XCTAssertThrowsError(try pages.read(second + ":0", from: from, to: to, principal: .plugin("other"), now: now))
        XCTAssertThrowsError(try pages.read(second + ":1", from: from, to: to, principal: .user, now: now))
        XCTAssertThrowsError(try pages.read("1", from: from, to: to, principal: .user, now: now))
        XCTAssertThrowsError(try pages.read(second + ":0", from: from, to: to, principal: .user, now: now.addingTimeInterval(10)))
        let bytes = try JSONEncoder().encode(events).count
        let budget = CalendarEventPages(maxBytes: bytes)
        let evicted = try budget.retain(events, from: from, to: to, principal: .user)
        _ = try budget.retain(events, from: from, to: to, principal: .user)
        XCTAssertThrowsError(try budget.read(evicted + ":0", from: from, to: to, principal: .user))
        XCTAssertThrowsError(try budget.retain(events + events, from: from, to: to, principal: .user))
    }

    func testPagingSnapshotIsForgottenWhenCalendarAccessIsLost() async throws {
        let (h, store, _) = harness([event("A", date(2026, 9, 30, 9)), event("B", date(2026, 9, 30, 10))])
        let first = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01", "limit": 1])
        let cursor = try XCTUnwrap(first["cursor"]?.stringValue)
        store.provider = FakeCalendarProvider(access: .denied, events: [])
        let denied = await code {
            _ = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01", "cursor": .string(cursor)])
        }
        XCTAssertEqual(denied, .unavailable)
        store.provider = FakeCalendarProvider(access: .granted, events: [])
        let expired = await code {
            _ = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01", "cursor": .string(cursor)])
        }
        XCTAssertEqual(expired, .invalidParams)
    }

    // MARK: Event notes

    func testCreateNoteFilesIntoCalendarEventFolderWithAHeaderAndLinksTheEvent() async throws {
        let review = event("Design Review", date(2026, 9, 30, 14), attendees: ["Ana Lima", "Ben Ode"], location: "Room 4")
        let (h, store, _) = harness([review])
        _ = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"])

        let r = try await h.run("calendar.createNote", ["event": .string(review.id), "kind": "notebook"])
        XCTAssertEqual(r["created"]?.boolValue, true)
        let ref = try XCTUnwrap(r["ref"]?.stringValue)
        let doc = NodeRef.documentID(from: ref)

        // Calendar Event / Design Review / Design Review 2026-09-30
        let root = h.library.children(of: nil).filter { $0.kind == .folder && $0.title == "Calendar Event" }
        XCTAssertEqual(root.count, 1)
        let eventFolder = h.library.children(of: root[0].id).filter { $0.kind == .folder }
        XCTAssertEqual(eventFolder.map { $0.title }, ["Design Review"])
        let node = try XCTUnwrap(h.library.node(doc))
        XCTAssertEqual(node.parent, eventFolder.first?.id)
        XCTAssertEqual(node.title, "Design Review " + CalendarDates.day(review.start))
        XCTAssertEqual(r["folder"]?.stringValue, NodeRef.folder(eventFolder[0].id).description)

        // The header: title, date, location and attendees in a text box on the first page.
        let content = try h.app.workspace.content(doc)
        XCTAssertEqual(content.meta.kind, .notebook)
        XCTAssertEqual(content.meta.ext?["calendar"]?["event"]?.stringValue, review.id)
        let page = try XCTUnwrap(content.livePages.first)
        let header = try h.app.workspace.items(doc, page: page.id).compactMap { $0.text?.text.plainText }.joined()
        XCTAssertTrue(header.contains("Design Review"))
        XCTAssertTrue(header.contains("Ana Lima"))
        XCTAssertTrue(header.contains("Ben Ode"))
        XCTAssertTrue(header.contains("Room 4"))
        XCTAssertEqual(h.undoDepth(doc), 0, "creating a note is not an undo step")

        // One synced key per event: calendar.notes.<eventId>.
        let link = try XCTUnwrap(h.app.settings.json("calendar.notes." + review.id))
        XCTAssertEqual(link["doc"]?.stringValue, ref)
        XCTAssertEqual(store.liveNote(for: review.id)?.doc, doc)

        // A second request returns the same note.
        let again = try await h.run("calendar.createNote", ["event": .string(review.id), "kind": "textDocument"])
        XCTAssertEqual(again["created"]?.boolValue, false)
        XCTAssertEqual(again["ref"]?.stringValue, ref)
        XCTAssertEqual(h.library.children(of: eventFolder[0].id).count, 1)

        // calendar.events reports the link.
        let listed = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"])
        XCTAssertEqual(listed["events"]?[0]?["note"]?.stringValue, ref)
    }

    func testTextDocumentNoteReusesFoldersAndCleansTitles() async throws {
        // Two occurrences of one weekly series: one note each.
        let first = event("Q3/Q4: Plan *", date(2026, 10, 1, 10), attendees: ["Ana"], recurring: true)
        let second = event("Q3/Q4: Plan *", date(2026, 10, 8, 10), attendees: ["Ana"], recurring: true)
        let (h, _, _) = harness([first, second])
        _ = try await h.run("calendar.events", ["from": "2026-10-01", "to": "2026-10-10"])

        let a = try await h.run("calendar.createNote", ["event": .string(first.id), "kind": "textDocument", "id": "NOTEONE"])
        XCTAssertEqual(a["ref"]?.stringValue, "doc:NOTEONE")
        _ = try await h.run("calendar.createNote", ["event": .string(second.id), "kind": "textDocument"])

        let roots = h.library.children(of: nil).filter { $0.kind == .folder && $0.title == "Calendar Event" }
        XCTAssertEqual(roots.count, 1, "the root folder is reused")
        let folders = h.library.children(of: roots[0].id)
        XCTAssertEqual(folders.map { $0.title }, ["Q3-Q4 Plan"], "one folder per event title")
        XCTAssertEqual(Set(h.library.children(of: folders[0].id).map { $0.title }),
                       ["Q3-Q4 Plan " + CalendarDates.day(first.start), "Q3-Q4 Plan " + CalendarDates.day(second.start)])

        let blocks = try h.app.workspace.content("NOTEONE").liveBlocks
        XCTAssertEqual(blocks.first?.kind, .heading1)
        XCTAssertEqual(blocks.first?.text.plainText, "Q3/Q4: Plan *")
        XCTAssertTrue(blocks.contains { $0.text.plainText.contains("Ana") })

        let clash = await code { try await h.run("calendar.createNote", ["event": .string(second.id), "kind": "notebook", "id": "NOTEONE"]) }
        XCTAssertNil(clash, "an event that already has a note returns it, whatever id was asked for")
        let unknown = await code { try await h.run("calendar.createNote", ["event": "20261231-000000000000", "kind": "notebook"]) }
        XCTAssertEqual(unknown, .notFound)
        let badKind = await code { try await h.run("calendar.createNote", ["event": .string(first.id), "kind": "studySet"]) }
        XCTAssertEqual(badKind, .invalidParams)
    }

    func testOpenNoteNeedsALiveNote() async throws {
        let review = event("Retro", date(2026, 9, 30, 16))
        let (h, _, _) = harness([review])
        _ = try await h.run("calendar.events", ["from": "2026-09-30", "to": "2026-10-01"])

        let missing = await code { try await h.run("calendar.openNote", ["event": .string(review.id)]) }
        XCTAssertEqual(missing, .notFound)

        let created = try await h.run("calendar.createNote", ["event": .string(review.id), "kind": "notebook"])
        let ref = try XCTUnwrap(created["ref"]?.stringValue)
        let opened = try await h.run("calendar.openNote", ["event": .string(review.id)])
        XCTAssertEqual(opened["ref"]?.stringValue, ref)
        XCTAssertEqual(opened["opened"]?.boolValue, false, "no window and no doc.open in a package test")

        try h.library.trash(NodeRef.documentID(from: ref))
        let trashed = await code { try await h.run("calendar.openNote", ["event": .string(review.id)]) }
        XCTAssertEqual(trashed, .notFound)
        let replacement = try await h.run("calendar.createNote", ["event": .string(review.id), "kind": "notebook"])
        XCTAssertEqual(replacement["created"]?.boolValue, true)
        XCTAssertNotEqual(replacement["ref"]?.stringValue, ref)
    }

    func testNotePathsAndTitleCleaning() {
        let e = event("  Sync: Design / Eng \n Weekly ", date(2026, 9, 30, 9))
        let p = EventNotePaths(event: e, calendar: .current)
        XCTAssertEqual(p.components, ["Calendar Event", "Sync Design - Eng Weekly", "Sync Design - Eng Weekly 2026-09-30"])
        XCTAssertEqual(EventNotePaths.sanitize(" ..:?* ", fallback: "Untitled"), "Untitled")
        XCTAssertEqual(EventNotePaths.sanitize(String(repeating: "a", count: 200), fallback: "x").count,
                       EventNotePaths.maxTitleLength)
    }

    // MARK: Ids and dates

    func testEventIDsAreStablePerOccurrence() {
        let t = date(2026, 9, 30, 9)
        let a = CalendarEventID.make(externalID: "abc@google.com", occurrence: t, allDay: false, calendar: .current)
        XCTAssertEqual(a, CalendarEventID.make(externalID: "abc@google.com", occurrence: t, allDay: false, calendar: .current))
        XCTAssertNotEqual(a, CalendarEventID.make(externalID: "abc@google.com", occurrence: t.addingTimeInterval(7 * 86_400),
                                                  allDay: false, calendar: .current))
        XCTAssertNotEqual(a, CalendarEventID.make(externalID: "other", occurrence: t, allDay: false, calendar: .current))
        XCTAssertTrue(CalendarEventID.isValid(a))
        XCTAssertEqual(a.count, 21)
        XCTAssertNotNil(CalendarEventID.day(of: a))
        XCTAssertNil(CalendarEventID.day(of: "20260230-abcdefabcdef"))
    }

    func testDateParameters() {
        XCTAssertEqual(CalendarDates.parse("2026-09-30"), Calendar.current.startOfDay(for: date(2026, 9, 30, 12)))
        XCTAssertNil(CalendarDates.parse("2026-02-30"))
        XCTAssertEqual(CalendarDates.parse("2026-09-30T09:00:00Z")?.timeIntervalSince1970, 1_790_758_800)
        XCTAssertNotNil(CalendarDates.parse("2026-09-30T09:00:00.250+02:00"))
        XCTAssertNil(CalendarDates.parse("next tuesday"))
        let d = date(2026, 9, 30, 9, 30)
        XCTAssertEqual(CalendarDates.parse(CalendarDates.iso(d)), d)
    }

    // MARK: Cache

    func testCoveragePrefersTheNewestRanges() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func r(_ a: Double, _ b: Double, _ at: Double) -> CalendarEventCache.SyncedRange {
            CalendarEventCache.SyncedRange(from: base + a, to: base + b, at: base + at)
        }
        let ranges = [r(0, 100, 10), r(50, 200, 20), r(0, 60, 30)]
        XCTAssertEqual(CalendarEventCache.coverage(ranges, from: base + 10, to: base + 150), base + 20)
        XCTAssertEqual(CalendarEventCache.coverage(ranges, from: base, to: base + 40), base + 30)
        XCTAssertNil(CalendarEventCache.coverage(ranges, from: base + 150, to: base + 250))

        let cache = CalendarEventCache(fileURL: nil)
        let e1 = event("A", date(2026, 9, 30, 9))
        let e2 = event("B", date(2026, 9, 30, 11))
        cache.store([e1, e2], from: date(2026, 9, 30), to: date(2026, 10, 1), at: date(2026, 9, 29))
        cache.store([e2], from: date(2026, 9, 30), to: date(2026, 10, 1), at: date(2026, 9, 29, 1))
        XCTAssertEqual(cache.events(overlapping: date(2026, 9, 30), date(2026, 10, 1)).map { $0.title }, ["B"],
                       "a new read replaces what was cached for its range")
    }

    // MARK: Planner layout

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    func testTimelineShareWidthBetweenOverlappingEventsAndKeepsAllDayApart() {
        let cal = utc
        let day = date(2026, 9, 30, 0, 0, cal)
        let a = event("A", date(2026, 9, 30, 9, 0, cal), minutes: 60, cal: cal)
        let b = event("B", date(2026, 9, 30, 9, 30, cal), minutes: 60, cal: cal)
        let c = event("C", date(2026, 9, 30, 11, 0, cal), minutes: 60, cal: cal)
        let e = event("E", date(2026, 9, 30, 13, 0, cal), minutes: 120, cal: cal)
        let f = event("F", date(2026, 9, 30, 13, 30, cal), minutes: 30, cal: cal)
        let g = event("G", date(2026, 9, 30, 14, 15, cal), minutes: 45, cal: cal)
        let offsite = event("Offsite", day, minutes: 1_440, allDay: true, cal: cal)
        let tomorrow = event("Tomorrow", date(2026, 10, 1, 9, 0, cal), cal: cal)
        let all = [a, b, c, e, f, g, offsite, tomorrow]

        let rect = Rect(x: 0, y: 0, width: 100, height: 1_400)   // 7:00–21:00, 100 pt an hour
        let boxes = EventPlannerLayout.boxes(all, day: day, calendar: cal, startHour: 7, endHour: 21, in: rect,
                                             minHeight: 10, gap: 0)
        let byID = Dictionary(uniqueKeysWithValues: boxes.map { ($0.event, $0) })
        XCTAssertEqual(boxes.count, 6, "all-day events and other days stay off the timeline")
        XCTAssertEqual(byID[a.id]?.rect, Rect(x: 0, y: 200, width: 50, height: 100))
        XCTAssertEqual(byID[b.id]?.rect, Rect(x: 50, y: 250, width: 50, height: 100))
        XCTAssertEqual(byID[c.id]?.rect, Rect(x: 0, y: 400, width: 100, height: 100))
        XCTAssertEqual(byID[e.id]?.columns, 2)
        XCTAssertEqual(byID[f.id]?.column, 1)
        XCTAssertEqual(byID[g.id]?.column, 1, "G takes the column F left free")
        XCTAssertEqual(EventPlannerLayout.allDay(all, day: day, calendar: cal).map { $0.title }, ["Offsite"])

        let early = event("Early", date(2026, 9, 30, 5, 0, cal), minutes: 30, cal: cal)
        let pinned = EventPlannerLayout.boxes([early], day: day, calendar: cal, startHour: 7, endHour: 21, in: rect,
                                              minHeight: 12)
        XCTAssertEqual(pinned.first?.rect.minY, 0)
        XCTAssertEqual(pinned.first?.rect.height, 12)
    }

    func testPlannerParamsAndRenderingSurviveOutOfRangeNumbers() {
        let cache = CalendarEventCache(fileURL: nil)
        for value in [1e19, -1e19, 1e300, -1e300, Double.greatestFiniteMagnitude,
                      Double(Int.max), Double.infinity, -Double.infinity, Double.nan] {
            let raw: [String: JSONValue] = ["year": .number(value), "month": .number(value),
                "day": .number(value), "startHour": .number(value), "endHour": .number(value)]
            let params = EventPlannerParams(raw)
            XCTAssertEqual(params.year, 0)
            XCTAssertEqual(params.month, 0)
            XCTAssertEqual(params.day, 0)
            XCTAssertEqual(params.startHour, EventPlannerParams.defaultStartHour)
            XCTAssertEqual(params.endHour, EventPlannerParams.defaultEndHour)
            XCTAssertNil(params.interval(in: params.calendar()))
            let render = EventPlannerTemplate.render(raw, size: .a4, scale: 1, cache: cache)
            XCTAssertFalse(render.display.ops.isEmpty)
        }
    }

    func testPlannerDatesForDailyAndWeeklyPages() {
        let monday = EventPlannerParams(layout: .weekly, weekStart: .monday, year: 2026, month: 9, day: 30)
        let calM = monday.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(monday.firstDay(in: calM), date(2026, 9, 28, 0, 0, calM))
        XCTAssertEqual(monday.days(in: calM).count, 7)
        let sunday = EventPlannerParams(layout: .weekly, weekStart: .sunday, year: 2026, month: 9, day: 30)
        let calS = sunday.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(sunday.firstDay(in: calS), date(2026, 9, 27, 0, 0, calS))
        let daily = EventPlannerParams(["layout": "daily", "year": 2026, "month": 9, "day": 30, "startHour": 30])
        XCTAssertEqual(daily.interval(in: calM)?.duration, 86_400)
        XCTAssertEqual(daily.startHour, 23)
        XCTAssertEqual(daily.endHour, 24)
        XCTAssertNil(EventPlannerParams([:]).interval(in: calM), "undated")
        XCTAssertNil(EventPlannerParams(["year": 2026, "month": 2, "day": 30]).interval(in: calM))
    }

    func testPlannerTemplateDrawsCachedEventsWithTheirAnswers() {
        let params = EventPlannerParams(layout: .daily, weekStart: .monday, year: 2026, month: 9, day: 30)
        let cal = params.calendar()
        let review = event("Design Review", date(2026, 9, 30, 10, 0, cal), cal: cal)
        let maybe = event("Lunch talk", date(2026, 9, 30, 12, 0, cal), rsvp: .tentative, cal: cal)
        let declined = event("Budget sync", date(2026, 9, 30, 15, 0, cal), rsvp: .declined, cal: cal)
        let offsite = event("Offsite", date(2026, 9, 30, 0, 0, cal), minutes: 1_440, allDay: true, cal: cal)
        let cache = CalendarEventCache(fileURL: nil)
        cache.store([review, maybe, declined, offsite], from: date(2026, 9, 28, 0, 0, cal), to: date(2026, 10, 5, 0, 0, cal),
                    at: Date())

        let render = EventPlannerTemplate.render(params.json, size: .a4, scale: 2, cache: cache)
        let texts = render.display.ops.filter { $0.op == .text }.compactMap { $0.text }
        for title in ["Design Review", "Lunch talk", "Budget sync", "Offsite"] {
            XCTAssertTrue(texts.contains(title), "\(title) is drawn")
        }
        XCTAssertTrue(texts.contains { $0.contains("Maybe") })
        XCTAssertTrue(texts.contains { $0.contains("Declined") })
        XCTAssertTrue(render.display.ops.contains { $0.op == .rect && $0.dash != nil && $0.fill == nil },
                      "declined events are dashed outlines")

        let undated = EventPlannerTemplate.render([:], size: .a4, scale: 2, cache: cache)
        XCTAssertFalse(undated.display.ops.contains { $0.text == "Design Review" }, "undated pages draw no events")

        // Weekly, Monday start: Wednesday is the third column.
        let week = EventPlannerParams(layout: .weekly, weekStart: .monday, year: 2026, month: 9, day: 30)
        let weekly = EventPlannerTemplate.render(week.json, size: .a4, scale: 2, cache: cache)
        let op = try? XCTUnwrap(weekly.display.ops.first { $0.op == .text && $0.text == "Design Review" })
        let canvas = PlannerCanvas(size: .a4, scale: 2, style: PlannerStyle([:]))
        let frame = EventPlannerRenderer.weeklyFrame(canvas, allDayRows: 1)
        let wednesday = frame.column(2, in: frame.timeline)
        XCTAssertNotNil(op)
        if let x = op?.rect?.minX {
            XCTAssertGreaterThanOrEqual(x, wednesday.minX)
            XCTAssertLessThan(x, wednesday.maxX)
        }
        let dayNumbers = weekly.display.ops.compactMap { $0.text }.filter { ["28", "29", "30", "1", "2", "3", "4"].contains($0) }
        XCTAssertEqual(dayNumbers.count, 7)
    }

    func testChipsOverflowIntoACount() {
        let cal = utc
        let many = (0..<8).map { event("All-day item \($0)", date(2026, 9, 30, 0, 0, cal), minutes: 1_440, allDay: true, cal: cal) }
        let placed = EventPlannerLayout.chips(many, in: Rect(x: 0, y: 0, width: 200, height: 30), rowHeight: 15,
                                              fontSize: 7, padding: 4, gap: 3, overflowWidth: 24)
        XCTAssertGreaterThan(placed.hidden, 0)
        XCTAssertEqual(placed.chips.count + placed.hidden, 8)
        XCTAssertTrue(placed.chips.allSatisfy { $0.rect.maxX <= 200 && $0.rect.maxY <= 30 })
    }

    // MARK: Reminders

    func testRemindersFireBeforeUpcomingTimedEventsOnly() {
        let now = date(2026, 9, 30, 9)
        let soon = event("Soon", now.addingTimeInterval(30 * 60))
        let tooSoon = event("Too soon", now.addingTimeInterval(5 * 60))
        let allDay = event("Holiday", date(2026, 10, 1), minutes: 1_440, allDay: true)
        let declined = event("Declined", now.addingTimeInterval(3_600), rsvp: .declined)
        let farAway = event("Far", now.addingTimeInterval(9 * 86_400))
        let plan = CalendarReminderPlanner.plan([farAway, declined, allDay, tooSoon, soon], minutesBefore: 10, now: now)
        XCTAssertEqual(plan.map { $0.eventID }, [soon.id])
        XCTAssertEqual(plan.first?.fireDate, soon.start.addingTimeInterval(-600))
        XCTAssertEqual(plan.first?.identifier, CalendarReminderNames.identifierPrefix + soon.id)
        XCTAssertEqual(plan.first?.title, "Soon")
        XCTAssertTrue(CalendarReminderPlanner.plan([soon], minutesBefore: 0, now: now).isEmpty)
        let lots = (1...50).map { event("E\($0)", now.addingTimeInterval(Double($0) * 3_600)) }
        XCTAssertEqual(CalendarReminderPlanner.plan(lots, minutesBefore: 5, now: now).count, CalendarReminderPlanner.limit)
    }

    // MARK: Planner creation and the tab

    func testNewPlannerBatchCreatesOneDatedPagePerWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let plan = PlannerPlan(start: date(2026, 9, 30, 12, 0, cal), layout: .weekly, weekStart: .monday, count: 3, calendar: cal)
        XCTAssertEqual(plan.pages.map { $0.day }, [28, 5, 12])
        XCTAssertEqual(plan.interval.start, date(2026, 9, 28, 0, 0, cal))
        XCTAssertEqual(plan.interval.duration, 21 * 86_400)
        let batch = plan.batch(doc: "PLANNER00001", title: "Planner")
        let calls = batch["calls"]?.arrayValue ?? []
        XCTAssertEqual(calls.map { $0["command"]?.stringValue }, ["doc.create", "page.add", "page.add"])
        XCTAssertEqual(calls[0]["params"]?["id"]?.stringValue, "PLANNER00001")
        XCTAssertEqual(calls[0]["params"]?["template"]?["id"]?.stringValue, "planner.events")
        XCTAssertEqual(calls[1]["params"]?["doc"]?.stringValue, "doc:PLANNER00001")
        XCTAssertEqual(calls[2]["params"]?["template"]?["params"]?["day"]?.intValue, 12)
        XCTAssertEqual(batch["stopOnError"]?.boolValue, true)
        XCTAssertEqual(PlannerPlan(start: date(2026, 9, 30, 12, 0, cal), layout: .daily, weekStart: .monday, count: 90,
                                   calendar: cal).pages.count, PlannerPlan.maxDays)
    }

    func testSharedCalendarCacheRejectsOlderOverlappingFetch() async throws {
        let oldEvent = event("Old snapshot", Date().addingTimeInterval(3_600))
        let newEvent = event("New snapshot", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "old read blocked")
        let provider = BlockingCalendarRead(old: [oldEvent], latest: [newEvent], started: started)
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let old = Task { try await store.fetch(from: window.start, to: window.end, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        let latest = try await store.fetch(from: window.start, to: window.end, principal: .user)
        let revision = store.revision
        let sync = store.cache.latestSync
        XCTAssertTrue(store.isSyncing, "the older read is still running")
        provider.release()
        let older = try await old.value
        XCTAssertEqual(older, [oldEvent], "superseded callers still receive their own successful read")
        XCTAssertEqual(latest.map(\.id), [newEvent.id])
        XCTAssertEqual(store.upcoming.map(\.id), [newEvent.id])
        XCTAssertEqual(store.cache.events(overlapping: window.start, window.end).map(\.id), [newEvent.id], "planner reads the same protected cache")
        XCTAssertEqual(store.cache.latestSync, sync)
        XCTAssertEqual(store.revision, revision)
        XCTAssertFalse(store.isSyncing)
        XCTAssertNil(store.lastError)
    }

    func testOlderReadPublishesWhenNewerOverlappingReadFails() async throws {
        let oldEvent = event("Successful snapshot", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "older successful read blocked")
        let provider = BlockingCalendarRead(old: [oldEvent], latest: [], started: started,
                                            latestError: NibError.unavailable("newer read failed"))
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let old = Task { try await store.fetch(from: window.start, to: window.end, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        do {
            _ = try await store.fetch(from: window.start, to: window.end, principal: .user)
            XCTFail("newer read should fail")
        } catch { XCTAssertEqual(NibError.wrap(error).code, .unavailable) }
        XCTAssertNotNil(store.lastError)
        provider.release()
        _ = try await old.value
        XCTAssertEqual(store.upcoming, [oldEvent])
        XCTAssertEqual(store.cache.events(overlapping: window.start, window.end), [oldEvent])
        XCTAssertNotNil(store.cache.latestSync)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isSyncing)
    }

    func testOlderReadPublishesWhenNewerOverlappingReadIsCancelled() async throws {
        let oldEvent = event("Successful snapshot", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "older successful read blocked")
        let provider = BlockingCalendarRead(old: [oldEvent], latest: [], started: started)
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let old = Task { try await store.fetch(from: window.start, to: window.end, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.fetch(from: window.start, to: window.end, principal: .user)
        }
        do { _ = try await cancelled.value; XCTFail("newer read should throw cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        provider.release()
        _ = try await old.value
        XCTAssertEqual(store.upcoming, [oldEvent])
        XCTAssertEqual(store.cache.events(overlapping: window.start, window.end), [oldEvent])
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isSyncing)
    }

    func testCancelledUpcomingLoadDoesNotShowAnErrorAndCanRetry() async throws {
        let soon = event("Upcoming", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        let started = expectation(description: "UI read blocked")
        let provider = BlockingCalendarRead(old: [soon], latest: [soon], started: started)
        store.provider = provider
        let read = Task { await store.loadUpcoming(session: h.session, connect: false) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        read.cancel()
        provider.release()
        await read.value
        XCTAssertNil(store.lastError, "leaving the tab must not show a cancellation banner")
        XCTAssertFalse(store.isSyncing)
        XCTAssertFalse(store.upcomingLoaded)
        await store.loadUpcoming(session: h.session, connect: false)
        XCTAssertEqual(store.upcoming, [soon])
        XCTAssertTrue(store.upcomingLoaded)
        XCTAssertNil(store.lastError)
    }

    func testEventLookupReturnsItsOwnReadWhenBackgroundRefreshSupersedesIt() async throws {
        let oldEvent = event("Requested event", Date().addingTimeInterval(3_600))
        let newEvent = event("New snapshot", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "event lookup blocked")
        let provider = BlockingCalendarRead(old: [oldEvent], latest: [newEvent], started: started)
        store.provider = provider
        let lookup = Task { try await store.event(id: oldEvent.id, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        let window = CalendarDates.upcomingWindow()
        _ = try await store.fetch(from: window.start, to: window.end, principal: .user)
        let revision = store.revision
        provider.release()
        let found = try await lookup.value
        XCTAssertEqual(found, oldEvent)
        XCTAssertEqual(store.upcoming, [newEvent])
        XCTAssertEqual(store.cache.events(overlapping: window.start, window.end), [newEvent])
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.lastError)
    }

    func testInFlightReadReturnsEmptyAfterAccessLossEvenIfAccessReturns() async throws {
        let oldEvent = event("Private event", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "private read blocked")
        let provider = BlockingCalendarRead(old: [oldEvent], latest: [], started: started)
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let read = Task { try await store.fetch(from: window.start, to: window.end, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        store.provider = FakeCalendarProvider(access: .denied, events: [])
        store.refreshAccess() // forgetEvents invalidates the in-flight read, even with an empty cache.
        store.provider = FakeCalendarProvider(access: .granted, events: [])
        provider.release()
        let result = try await read.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(store.upcoming.isEmpty)
        XCTAssertNil(store.cache.latestSync)
        XCTAssertNil(store.lastError)
    }

    func testProviderSwapReturnsOldReadWithoutPublishingIt() async throws {
        let oldEvent = event("Old provider", Date().addingTimeInterval(3_600))
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "old provider blocked")
        let provider = BlockingCalendarRead(old: [oldEvent], latest: [], started: started)
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let read = Task { try await store.fetch(from: window.start, to: window.end, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        store.provider = FakeCalendarProvider(access: .granted, events: [])
        provider.release()
        let result = try await read.value
        XCTAssertEqual(result, [oldEvent])
        XCTAssertTrue(store.upcoming.isEmpty)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.cache.latestSync)
        XCTAssertNil(store.lastError)
    }

    func testExplicitlyCancelledCalendarReadStillThrowsCancellation() async throws {
        let (h, store, _) = harness([])
        defer { withExtendedLifetime(h) {} }
        let started = expectation(description: "cancelled read blocked")
        let provider = BlockingCalendarRead(old: [], latest: [], started: started)
        store.provider = provider
        let window = CalendarDates.upcomingWindow()
        let read = Task { try await store.fetch(from: window.start, to: window.end, principal: .user) }
        defer { provider.release() }
        await fulfillment(of: [started], timeout: 2)
        read.cancel()
        provider.release()
        do { _ = try await read.value; XCTFail("explicit cancellation must still throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.cache.latestSync)
        XCTAssertNil(store.lastError)
    }

    func testOtherEventsIgnoresAnOlderSuccessAfterTheNewDayFinishes() async throws {
        let model = OtherEventsModel()
        model.date = date(2026, 9, 29)
        let oldEvent = event("Old day", date(2026, 9, 29, 10))
        let newEvent = event("New day", date(2026, 9, 30, 10))
        var pending: CheckedContinuation<[CalendarEvent], Error>?
        let old = Task { @MainActor in
            await model.load { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        }
        await eventually { pending != nil }
        let continuation = try XCTUnwrap(pending)
        model.date = date(2026, 9, 30)
        await model.load { _, _ in [newEvent] }
        continuation.resume(returning: [oldEvent])
        await old.value
        XCTAssertEqual(model.events.map(\.id), [newEvent.id])
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.loading)
    }

    func testOtherEventsOldFailureCannotClearTheNewDaysLoadingState() async throws {
        let model = OtherEventsModel()
        model.date = date(2026, 9, 29)
        var first: CheckedContinuation<[CalendarEvent], Error>?
        var second: CheckedContinuation<[CalendarEvent], Error>?
        let old = Task { @MainActor in
            await model.load { _, _ in try await withCheckedThrowingContinuation { first = $0 } }
        }
        await eventually { first != nil }
        let firstRead = try XCTUnwrap(first)
        model.date = date(2026, 9, 30)
        let latest = Task { @MainActor in
            await model.load { _, _ in try await withCheckedThrowingContinuation { second = $0 } }
        }
        await eventually { second != nil }
        let latestRead = try XCTUnwrap(second)
        firstRead.resume(throwing: NibError.unavailable("old calendar read"))
        await old.value
        XCTAssertTrue(model.loading)
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.events.isEmpty)
        let current = event("Current day", date(2026, 9, 30, 10))
        latestRead.resume(returning: [current])
        await latest.value
        XCTAssertEqual(model.events.map(\.id), [current.id])
        XCTAssertFalse(model.loading)
        model.date = date(2026, 10, 1)
        XCTAssertTrue(model.events.isEmpty, "the heading must never show the previous day's rows")
    }

    func testOtherEventsCancelledReadCannotPublishResults() async throws {
        let model = OtherEventsModel()
        var pending: CheckedContinuation<[CalendarEvent], Error>?
        let task = Task { @MainActor in
            await model.load { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        }
        await eventually { pending != nil }
        let continuation = try XCTUnwrap(pending)
        task.cancel()
        continuation.resume(throwing: NibError.unavailable("cancelled calendar read"))
        await task.value
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertNil(model.failure)
        await model.load { _, _ in [] }
        XCTAssertFalse(model.loading)
    }

    func testUpcomingEventsGroupByDay() {
        let window = CalendarDates.upcomingWindow(now: date(2026, 9, 30, 8))
        let a = event("A", date(2026, 9, 30, 9))
        let b = event("B", date(2026, 10, 2, 9))
        let trip = event("Trip", date(2026, 10, 1), minutes: 2 * 1_440, allDay: true)
        let sections = CalendarDaySection.make([b, trip, a], window: window, calendar: .current)
        XCTAssertEqual(sections.map { $0.events.map { $0.title } }, [["A"], ["Trip"], ["Trip", "B"]])
    }

    // MARK: Reminder actions

    func testTakeNotesFromAReminderBeforeStartIsQueuedAndRunByBegin() async throws {
        let meeting = event("Planning", date(2026, 9, 30, 11), attendees: ["Ana"])
        let (h, store, _) = harness([meeting])
        let router = store.makeNotificationRouter(previous: nil)
        var completed = 0
        // Nib was launched by the reminder: the response arrives before FeatCalendarFeature.start.
        router.receive(category: CalendarReminderNames.category, action: CalendarReminderNames.takeNotesAction,
                       userInfo: [CalendarReminderNames.eventKey: meeting.id],
                       forward: { XCTFail("a calendar reminder is never forwarded"); return true },
                       completion: { completed += 1 })
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(store.pendingTakeNotes, [meeting.id])
        XCTAssertNil(h.app.settings.json("calendar.notes." + meeting.id))

        store.begin()
        await store.startTask?.value
        XCTAssertEqual(store.pendingTakeNotes, [])
        let link = try XCTUnwrap(h.app.settings.json("calendar.notes." + meeting.id))
        let doc = NodeRef.documentID(from: try XCTUnwrap(link["doc"]?.stringValue))
        XCTAssertNotNil(h.library.node(doc))
        XCTAssertEqual(link["key"]?.stringValue, meeting.key)

        // Once started, a Take Notes with a window runs at once (the note exists, so nothing new is created).
        router.receive(category: CalendarReminderNames.category, action: UNNotificationDefaultActionIdentifier,
                       userInfo: [CalendarReminderNames.eventKey: meeting.id], forward: { true }, completion: {})
        XCTAssertEqual(store.pendingTakeNotes, [])
    }

    func testRouterForwardsOtherNotificationsAndIgnoresDismissals() {
        let (_, store, _) = harness([])
        let router = store.makeNotificationRouter(previous: nil)
        var forwarded = 0
        var completed = 0
        router.receive(category: "chat.reply", action: UNNotificationDefaultActionIdentifier, userInfo: [:],
                       forward: { forwarded += 1; return true }, completion: { completed += 1 })
        XCTAssertEqual(forwarded, 1)
        XCTAssertEqual(completed, 0, "the previous delegate calls the completion handler")
        router.receive(category: "chat.reply", action: UNNotificationDefaultActionIdentifier, userInfo: [:],
                       forward: { false }, completion: { completed += 1 })
        XCTAssertEqual(completed, 1, "no previous delegate: the router completes it")
        router.receive(category: CalendarReminderNames.category, action: UNNotificationDismissActionIdentifier,
                       userInfo: [CalendarReminderNames.eventKey: "20260930-abcdefabcdef"],
                       forward: { XCTFail("never forwarded"); return true }, completion: { completed += 1 })
        XCTAssertEqual(completed, 2)
        XCTAssertTrue(store.pendingTakeNotes.isEmpty)

        let calendar = CalendarReminderNames.category
        XCTAssertEqual(CalendarNotificationRouter.route(category: calendar, action: UNNotificationDefaultActionIdentifier,
                                                        userInfo: [CalendarReminderNames.eventKey: "20260930-abcdefabcdef"]),
                       .takeNotes("20260930-abcdefabcdef"))
        XCTAssertEqual(CalendarNotificationRouter.route(category: calendar, action: CalendarReminderNames.takeNotesAction,
                                                        userInfo: [CalendarReminderNames.eventKey: "../../etc"]), .ignore)
        XCTAssertEqual(CalendarNotificationRouter.route(category: calendar, action: CalendarReminderNames.takeNotesAction,
                                                        userInfo: [:]), .ignore)
        XCTAssertEqual(CalendarNotificationRouter.route(category: "other", action: CalendarReminderNames.takeNotesAction,
                                                        userInfo: [CalendarReminderNames.eventKey: "20260930-abcdefabcdef"]),
                       .forward)
    }

    func testReminderRebuildsRunInOrder() async throws {
        let soon = event("Soon", Date().addingTimeInterval(3 * 3_600))
        let (h, store, _) = harness([soon])
        let notifier = FakeNotifier()
        store.notifier = notifier
        store.cache.store([soon], from: Date().addingTimeInterval(-3_600), to: Date().addingTimeInterval(Self.day),
                          at: Date())
        h.app.settings.set(CalendarSettings.reminderMinutes, 10)

        // A reads "10 minutes" and waits on the (slow) permission check; meanwhile reminders are turned off and B runs.
        let a = Task { await store.rescheduleReminders() }
        await eventually { notifier.authorizationCalls == 1 }
        h.app.settings.set(CalendarSettings.reminderMinutes, 0)
        let b = Task { await store.rescheduleReminders() }
        await a.value
        await b.value
        XCTAssertEqual(notifier.replaced, [[soon.id], []], "the later rebuild (off) lands last")
    }

    func testFailedReminderReplacementPreservesOldRequestAndRetryClearsError() async throws {
        let soon = event("Soon", Date().addingTimeInterval(3 * 3_600))
        let (h, store, _) = harness([soon])
        let requests = FailingCalendarRequests()
        let scheduler = UserNotificationScheduler(requests: requests)
        let plan = CalendarReminderPlanner.plan([soon], minutesBefore: 10, now: Date())
        try await scheduler.replace(prefix: CalendarReminderNames.identifierPrefix, with: plan)
        let id = try XCTUnwrap(plan.first?.identifier)
        let original = try XCTUnwrap(requests.pending[id])
        requests.fail = true
        let notifier = TestCalendarScheduler(scheduler)
        store.notifier = notifier
        store.cache.store([soon], from: Date().addingTimeInterval(-3_600), to: Date().addingTimeInterval(Self.day), at: Date())
        h.app.settings.set(CalendarSettings.reminderMinutes, 30)
        await store.rescheduleReminders()
        XCTAssertNotNil(store.reminderError)
        XCTAssertTrue(requests.pending[id] === original)
        notifier.status = .denied
        await store.rescheduleReminders()
        XCTAssertNil(store.reminderError, "a retry banner is not actionable without notification authorization")
        notifier.status = .authorized
        requests.fail = false
        await store.rescheduleReminders()
        XCTAssertNil(store.reminderError)
        XCTAssertFalse(requests.pending[id] === original)
        XCTAssertEqual(requests.pending.count, 1)
    }

    func testMovingEventPreservesPreviousReminderUntilReplacementSucceeds() async throws {
        var original = event("Meeting", Date().addingTimeInterval(3 * 3_600))
        original.id = CalendarEventID.make(externalID: "meeting", occurrence: original.start, allDay: false, calendar: .current)
        original.key = CalendarEventID.key(externalID: "meeting", recurrence: nil, allDay: false, calendar: .current)
        var moved = original
        moved.start = original.start.addingTimeInterval(3_600)
        moved.end = original.end.addingTimeInterval(3_600)
        moved.id = CalendarEventID.make(externalID: "meeting", occurrence: moved.start, allDay: false, calendar: .current)
        let obsolete = event("Deleted meeting", Date().addingTimeInterval(5 * 3_600))
        let requests = FailingCalendarRequests()
        let scheduler = UserNotificationScheduler(requests: requests)
        let prefix = CalendarReminderNames.identifierPrefix
        let oldPlan = CalendarReminderPlanner.plan([original, obsolete], minutesBefore: 10, now: Date())
        let newPlan = CalendarReminderPlanner.plan([moved], minutesBefore: 10, now: Date())
        let oldID = prefix + original.id
        let newID = prefix + moved.id
        XCTAssertNotEqual(oldID, newID)
        try await scheduler.replace(prefix: prefix, with: oldPlan)
        let previous = try XCTUnwrap(requests.pending[oldID])
        requests.fail = true
        do {
            try await scheduler.replace(prefix: prefix, with: newPlan)
            XCTFail("replacement should fail")
        } catch { XCTAssertEqual(NibError.wrap(error).code, .unavailable) }
        XCTAssertTrue(requests.pending[oldID] === previous)
        XCTAssertNil(requests.pending[newID])
        requests.fail = false
        try await scheduler.replace(prefix: prefix, with: newPlan)
        XCTAssertNil(requests.pending[oldID])
        XCTAssertEqual(Set(requests.pending.keys), [newID])
        XCTAssertEqual(requests.pending[newID]?.content.userInfo[CalendarReminderNames.eventKey] as? String, moved.id)
        try await scheduler.replace(prefix: prefix, with: newPlan)
        XCTAssertEqual(Set(requests.pending.keys), [newID], "retries do not duplicate reminders")
    }

    func testPartialReplacementRollsBackNewRequestsWhenLegacyIdentityIsUnknown() async throws {
        let now = Date()
        var original = event("Legacy meeting", now.addingTimeInterval(3 * 3_600))
        original.id = CalendarEventID.make(externalID: "legacy", occurrence: original.start, allDay: false, calendar: .current)
        var moved = original
        moved.start = original.start.addingTimeInterval(3_600)
        moved.end = original.end.addingTimeInterval(3_600)
        moved.id = CalendarEventID.make(externalID: "legacy", occurrence: moved.start, allDay: false, calendar: .current)
        let other = event("New meeting", now.addingTimeInterval(5 * 3_600))
        let requests = FailingCalendarRequests()
        let scheduler = UserNotificationScheduler(requests: requests)
        let prefix = CalendarReminderNames.identifierPrefix
        var legacyPlan = CalendarReminderPlanner.plan([original], minutesBefore: 10, now: now)
        legacyPlan[0].eventKey = nil
        try await scheduler.replace(prefix: prefix, with: legacyPlan)
        let oldID = prefix + original.id
        let newID = prefix + moved.id
        let previous = try XCTUnwrap(requests.pending[oldID])
        let foreign = UNNotificationRequest(identifier: "study.reminder", content: UNMutableNotificationContent(), trigger: nil)
        requests.pending[foreign.identifier] = foreign
        let plan = CalendarReminderPlanner.plan([moved, other], minutesBefore: 10, now: now)
        requests.failedIdentifiers = [prefix + other.id]
        do {
            try await scheduler.replace(prefix: prefix, with: plan)
            XCTFail("selective addition should fail")
        } catch { XCTAssertEqual(NibError.wrap(error).code, .unavailable) }
        XCTAssertTrue(requests.successfulIdentifiers.contains(newID), "the moved replacement succeeded before the other addition failed")
        XCTAssertTrue(requests.pending[oldID] === previous)
        XCTAssertTrue(requests.pending[foreign.identifier] === foreign)
        XCTAssertEqual(Set(requests.pending.keys), [oldID, foreign.identifier], "rollback preserves the legacy request without a duplicate")
        requests.failedIdentifiers = []
        try await scheduler.replace(prefix: prefix, with: plan)
        XCTAssertEqual(Set(requests.pending.keys), [newID, prefix + other.id, foreign.identifier])
        XCTAssertNil(requests.pending[oldID])
        try await scheduler.replace(prefix: prefix, with: plan)
        XCTAssertEqual(requests.pending.count, 3, "retry remains idempotent")
    }

    // MARK: The cache horizon

    func testSyncedRangesAreClippedToTheHorizon() {
        let now = Date()
        let cache = CalendarEventCache(fileURL: nil)
        let old = event("Old", now.addingTimeInterval(-450 * Self.day))
        let recent = event("Recent", now.addingTimeInterval(-350 * Self.day))
        let from = now.addingTimeInterval(-450 * Self.day), to = now.addingTimeInterval(-300 * Self.day)
        cache.store([old, recent], from: from, to: to, at: now)
        XCTAssertNil(cache.lastSync(covering: from, to), "the part beyond the horizon is no longer covered")
        XCTAssertNil(cache.event(old.id))
        XCTAssertNotNil(cache.lastSync(covering: now.addingTimeInterval(-390 * Self.day), to))
        XCTAssertEqual(cache.event(recent.id)?.title, "Recent")

        cache.store([], from: now.addingTimeInterval(-500 * Self.day), to: now.addingTimeInterval(-420 * Self.day), at: now)
        XCTAssertNil(cache.lastSync(covering: now.addingTimeInterval(-500 * Self.day), now.addingTimeInterval(-420 * Self.day)))
        XCTAssertNotNil(cache.lastSync(covering: now.addingTimeInterval(-390 * Self.day), to), "other ranges stay")
    }

    func testPagingARangeThatStartsBeyondTheHorizonReturnsEveryEvent() async throws {
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-450 * Self.day))
        let people = (0..<12).map { "Participant number \($0) with a fairly long display name" }
        let many = (0..<60).map { i in
            event("Review \(i)", start.addingTimeInterval(Double(i) * 6 * Self.day + 9 * 3_600), minutes: 25,
                  attendees: people)
        }
        let (h, _, fake) = harness(many)
        let to = Calendar.current.date(byAdding: .day, value: 365, to: start) ?? start.addingTimeInterval(365 * Self.day)
        var cursor: String?
        var seen: [String] = []
        var pages = 0
        repeat {
            var params: [String: JSONValue] = ["from": .string(CalendarDates.day(start)), "to": .string(CalendarDates.day(to))]
            if let c = cursor { params["cursor"] = .string(c) }
            let r = try await h.run("calendar.events", .object(params))
            seen += (r["events"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            cursor = r["cursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 30
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen.count, 60)
        XCTAssertEqual(Set(seen), Set(many.map { $0.id }), "every event exactly once, none skipped")
        XCTAssertEqual(fake.reads, 1, "paging retains the complete read even when the shared cache trims its horizon")
    }

    func testCreateNoteForAnEventBeyondTheHorizon() async throws {
        let kickoff = event("Kickoff", daysFromNow(-450), attendees: ["Ana"])
        let (h, store, fake) = harness([kickoff])
        let r = try await h.run("calendar.createNote", ["event": .string(kickoff.id), "kind": "notebook"])
        XCTAssertEqual(r["created"]?.boolValue, true)
        XCTAssertEqual(fake.reads, 1, "a cache miss reads the event's days")
        XCTAssertNil(store.cache.event(kickoff.id), "the cache does not keep events beyond its horizon")
        XCTAssertNotNil(h.app.settings.json("calendar.notes." + kickoff.id))
        let opened = try await h.run("calendar.openNote", ["event": .string(kickoff.id)])
        XCTAssertEqual(opened["ref"]?.stringValue, r["ref"]?.stringValue)
    }

    func testEventByIDReadsTheCalendarOnACacheMiss() async throws {
        let lunch = event("Lunch", daysFromNow(3, hour: 12))
        let (_, store, fake) = harness([lunch])
        XCTAssertNil(store.cache.event(lunch.id))
        let found = try await store.event(id: lunch.id, principal: .user)
        XCTAssertEqual(found.title, "Lunch")
        XCTAssertEqual(fake.reads, 1)
        _ = try await store.event(id: lunch.id, principal: .user)
        XCTAssertEqual(fake.reads, 1, "the second lookup comes from the cache")
    }

    // MARK: Moved events

    func testAMovedEventKeepsItsNote() async throws {
        let original = event("One to one", date(2026, 9, 30, 14))
        let moved = event("One to one", date(2026, 10, 1, 15))
        XCTAssertNotEqual(original.id, moved.id)
        XCTAssertEqual(original.key, moved.key, "the key ignores the start of a one-off event")
        let (h, _, fake) = harness([original])
        let created = try await h.run("calendar.createNote", ["event": .string(original.id), "kind": "notebook"])
        let ref = try XCTUnwrap(created["ref"]?.stringValue)

        fake.replace([moved])
        let opened = try await h.run("calendar.openNote", ["event": .string(moved.id)])
        XCTAssertEqual(opened["ref"]?.stringValue, ref, "the same note opens")
        XCTAssertEqual(h.app.settings.json("calendar.notes." + moved.id)?["doc"]?.stringValue, ref)
        XCTAssertNil(h.app.settings.json("calendar.notes." + original.id), "the link moved to the new id")

        let again = try await h.run("calendar.createNote", ["event": .string(moved.id), "kind": "textDocument"])
        XCTAssertEqual(again["created"]?.boolValue, false)
        XCTAssertEqual(again["ref"]?.stringValue, ref)
        let listed = try await h.run("calendar.events", ["from": "2026-10-01", "to": "2026-10-02"])
        XCTAssertEqual(listed["events"]?[0]?["note"]?.stringValue, ref)

        // Recurring occurrences keep one key per original occurrence.
        let first = CalendarEventID.key(externalID: "series", recurrence: date(2026, 10, 5, 9), allDay: false, calendar: .current)
        XCTAssertEqual(first, CalendarEventID.key(externalID: "series", recurrence: date(2026, 10, 5, 9), allDay: false,
                                                  calendar: .current))
        XCTAssertNotEqual(first, CalendarEventID.key(externalID: "series", recurrence: date(2026, 10, 12, 9), allDay: false,
                                                     calendar: .current))
    }

    // MARK: More note kinds

    func testWhiteboardNoteCarriesTheHeaderOnItsBoard() async throws {
        let review = event("Sprint Review", date(2026, 9, 30, 15), attendees: ["Ana Lima", "Ben Ode"], location: "Room 2")
        let (h, _, _) = harness([review])
        let r = try await h.run("calendar.createNote", ["event": .string(review.id), "kind": "whiteboard"])
        let doc = NodeRef.documentID(from: try XCTUnwrap(r["ref"]?.stringValue))
        let content = try h.app.workspace.content(doc)
        XCTAssertEqual(content.meta.kind, .whiteboard)
        let board = try XCTUnwrap(content.livePages.first)
        let boxes = try h.app.workspace.items(doc, page: board.id).compactMap { $0.text }
        XCTAssertEqual(boxes.count, 1)
        let header = boxes.map { $0.text.plainText }.joined()
        for part in ["Sprint Review", "Ana Lima", "Ben Ode", "Room 2"] {
            XCTAssertTrue(header.contains(part), "\(part) is in the header")
        }
        XCTAssertEqual(boxes.first?.text.paragraphs.first?.runs.first?.attrs.bold, true, "the title is bold")
        XCTAssertEqual(h.undoDepth(doc), 0)
    }

    func testCreateNoteDryRunWritesNothing() async throws {
        let standup = event("Standup", date(2026, 9, 30, 9))
        let (h, _, _) = harness([standup])
        let before = h.library.children(of: nil).map { $0.id }
        let result = try await h.app.bus.execute(Invocation(
            command: "calendar.createNote", params: ["event": .string(standup.id), "kind": "notebook"],
            session: h.session, dryRun: true))
        XCTAssertEqual(result.value["created"]?.boolValue, true)
        XCTAssertNil(result.value["folder"]?.stringValue)
        let ref = try XCTUnwrap(result.value["ref"]?.stringValue)
        XCTAssertNil(h.library.node(NodeRef.documentID(from: ref)), "no document")
        XCTAssertEqual(h.library.children(of: nil).map { $0.id }, before, "no folders")
        XCTAssertNil(h.app.settings.json("calendar.notes." + standup.id), "no link")
    }

    // MARK: Snapshots (DESIGN.md 15.7)

    func testCalendarTabRendersInEveryAccessStateLightDarkAndAX3() async throws {
        let soon = event("Design Review", Date().addingTimeInterval(2 * 3_600), attendees: ["Ana Lima", "Ben Ode"],
                         location: "Room 4")
        let later = event("Retro", Date().addingTimeInterval(Self.day + 3_600), rsvp: .tentative)
        for access in [CalendarAccess.granted, .notDetermined, .denied] {
            let (h, store, _) = harness([soon, later], access: access)
            store.refreshAccess()
            if access == .granted {
                await store.loadUpcoming(session: h.session, connect: false)
                XCTAssertEqual(Set(store.upcoming.map { $0.id }), [soon.id, later.id])
            }
            let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
            let view = CalendarTabBody(context: context, store: store, showsOtherEvents: .constant(false),
                                       busy: .constant(Set<String>()))
            let images = NibSnapshot.images(view, size: CGSize(width: 640, height: 900))
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases), "\(access): light, dark and AX3 render")
            XCTAssertNotNil(NibSnapshot.image(view, size: CGSize(width: 640, height: 1_600), variant: .largeText),
                            "\(access) at AX3")
            XCTAssertGreaterThan(NibSnapshot.fittingSize(view, width: 640, variant: .largeText).height,
                                 NibSnapshot.fittingSize(view, width: 640).height, "\(access): AX3 text grows the tab")
        }
    }
}

@MainActor
private final class FailingCalendarRequests: CalendarNotificationRequests {
    var pending: [String: UNNotificationRequest] = [:]
    var fail = false
    var failedIdentifiers = Set<String>()
    var successfulIdentifiers = Set<String>()
    func pendingRequests() async -> [UNNotificationRequest] { Array(pending.values) }
    func add(_ request: UNNotificationRequest) async throws {
        if fail || failedIdentifiers.contains(request.identifier) { throw NibError.unavailable("test scheduling failure") }
        pending[request.identifier] = request
        successfulIdentifiers.insert(request.identifier)
    }
    func remove(_ identifiers: [String]) { for id in identifiers { pending[id] = nil } }
}

@MainActor
private final class TestCalendarScheduler: NotificationScheduling {
    let scheduler: UserNotificationScheduler
    var status = NotificationAuthorization.authorized
    init(_ scheduler: UserNotificationScheduler) { self.scheduler = scheduler }
    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> Bool { true }
    func replace(prefix: String, with reminders: [PlannedReminder]) async throws {
        try await scheduler.replace(prefix: prefix, with: reminders)
    }
}

private final class BlockingCalendarRead: CalendarProvider {
    let access = CalendarAccess.granted
    let old: [CalendarEvent]
    let latest: [CalendarEvent]
    let started: XCTestExpectation
    let latestError: Error?
    private let lock = NSLock()
    private var reads = 0
    private let gate = DispatchSemaphore(value: 0)
    init(old: [CalendarEvent], latest: [CalendarEvent], started: XCTestExpectation, latestError: Error? = nil) {
        self.old = old; self.latest = latest; self.started = started
        self.latestError = latestError
    }
    func release() { gate.signal() }
    func requestAccess() async -> CalendarAccess { access }
    func events(from: Date, to: Date) throws -> [CalendarEvent] {
        lock.lock(); reads += 1; let first = reads == 1; lock.unlock()
        if first {
            started.fulfill()
            guard gate.wait(timeout: .now() + 3) == .success else { throw NibError.unavailable("calendar gate timed out") }
        }
        if !first, let latestError { throw latestError }
        return first ? old : latest
    }
    func calendars() -> [CalendarInfo] { latest.map(\.calendar) }
    func observeChanges(_ handler: @escaping () -> Void) -> AnyObject? { nil }
}
