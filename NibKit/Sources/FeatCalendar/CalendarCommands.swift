import Foundation
import NibContracts

// The three commands F075 owns (ARCHITECTURE §6.5 `calendar.*`): reading events, creating an event's note in
// 'Calendar Event/{Event}/{Event} {Date}', and opening it. Every calendar action in the UI goes through them, so the
// AI, plugins and the bridge can do the same (reads are `sensitive`: non-user callers are always confirmed).

// MARK: - Wire format

/// A calendar event in command results. Dates are ISO 8601 with this device's offset.
struct EventJSON: Codable, Equatable {
    var id: String
    var title: String
    var start: String
    var end: String
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
    /// The linked note ("doc:D"), when the event has one in the library.
    var note: String?

    init(_ e: CalendarEvent, note: String?) {
        id = e.id
        title = e.title
        start = CalendarDates.iso(e.start)
        end = CalendarDates.iso(e.end)
        allDay = e.allDay
        location = e.location
        notes = e.notes
        url = e.url
        calendar = e.calendar
        attendees = e.attendees
        organizer = e.organizer
        rsvp = e.rsvp
        status = e.status
        recurring = e.recurring
        self.note = note
    }

    /// Back to the model (the UI reads events through the command).
    var event: CalendarEvent? {
        guard let s = CalendarDates.parse(start), let e = CalendarDates.parse(end) else { return nil }
        return CalendarEvent(id: id, title: title, start: s, end: max(e, s), allDay: allDay, location: location,
                             notes: notes, url: url, calendar: calendar, attendees: attendees, organizer: organizer,
                             rsvp: rsvp, status: status, recurring: recurring)
    }
}

// MARK: - calendar.events

struct CalendarEvents: NibCommand {
    static let maxLimit = 500
    /// Results are paged past this many bytes (ARCHITECTURE §6.1: big results carry `truncated` + `cursor`).
    static let pageBytes = 20_000
    static let maxSpan: TimeInterval = 366 * 86_400

    struct Params: Codable {
        var from: String
        var to: String
        var cursor: String?
        var limit: Int?
    }

    struct Output: Codable {
        var events: [EventJSON]
        var from: String
        var to: String
        var truncated: Bool?
        var cursor: String?
    }

    static let descriptor = CommandDescriptor(
        id: "calendar.events", title: "Calendar Events",
        summary: "Events from the device's calendars (iCloud, Google, Outlook via EventKit) in [from, to) with RSVP, attendees and linked note → {events, truncated?, cursor?}.",
        params: .obj([
            "from": .str("start: an ISO 8601 date (2026-09-30 = that day's start on this device) or date-time"),
            "to": .str("end (exclusive), same forms; at most 366 days after from"),
            "cursor": .str("next page: the cursor a truncated result returned"),
            "limit": .int("events per page (default and maximum 500)", min: 1, max: 500)
        ], required: ["from", "to"]),
        examples: [["from": "2026-09-28", "to": "2026-10-05"],
                   ["from": "2026-09-30T09:00:00Z", "to": "2026-09-30T18:00:00Z", "limit": 20]],
        effect: .read, target: .app, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (from, to) = try range(p)
        let limit = p.limit ?? maxLimit
        guard (1...maxLimit).contains(limit) else { throw NibError.invalid("limit must be 1…\(maxLimit)", path: "$.limit") }
        var offset = 0
        if let c = p.cursor {
            guard let n = Int(c), n >= 0 else {
                throw NibError(.invalidParams, "invalid cursor", path: "$.cursor", hint: "pass the cursor exactly as returned")
            }
            offset = n
        }
        let store = try CalendarStore.require(ctx)
        let events: [CalendarEvent]
        if offset > 0, store.access == .granted, store.cache.lastSync(covering: from, to) != nil {
            // A later page of the same read: the cache already holds exactly what the first page read.
            events = store.cache.events(overlapping: from, to)
        } else {
            events = try await store.fetch(from: from, to: to, principal: ctx.principal)
        }
        guard offset <= events.count else {
            throw NibError(.invalidParams, "cursor past the end", path: "$.cursor", hint: "start again without a cursor")
        }
        let encoder = JSONEncoder()
        var page: [EventJSON] = []
        var bytes = 0
        var index = offset
        while index < events.count && page.count < limit {
            let e = events[index]
            let json = EventJSON(e, note: store.liveNote(for: e.id).map { NodeRef.document($0.doc).description })
            let size = (try? encoder.encode(json).count) ?? 0
            if !page.isEmpty && bytes + size > pageBytes { break }
            page.append(json)
            bytes += size
            index += 1
        }
        let more = index < events.count
        return Output(events: page, from: CalendarDates.iso(from), to: CalendarDates.iso(to),
                      truncated: more ? true : nil, cursor: more ? String(index) : nil)
    }

    static func range(_ p: Params) throws -> (Date, Date) {
        guard let from = CalendarDates.parse(p.from) else {
            throw NibError(.invalidParams, "from is not an ISO 8601 date or date-time", path: "$.from",
                           hint: "for example 2026-09-30 or 2026-09-30T09:00:00Z")
        }
        guard let to = CalendarDates.parse(p.to) else {
            throw NibError(.invalidParams, "to is not an ISO 8601 date or date-time", path: "$.to",
                           hint: "for example 2026-10-07 or 2026-09-30T18:00:00Z")
        }
        guard to > from else { throw NibError.invalid("to must be after from", path: "$.to") }
        guard to.timeIntervalSince(from) <= maxSpan else {
            throw NibError(.invalidParams, "at most 366 days per call", path: "$.to", hint: "split the range into years")
        }
        return (from, to)
    }
}

// MARK: - calendar.createNote

struct CalendarCreateNote: NibCommand {
    struct Params: Codable {
        var event: String
        var kind: String
        var id: String?
    }

    struct Output: Codable {
        var ref: String
        var title: String
        /// The event's folder, "folder:F" (nil in a dry run).
        var folder: String?
        var event: String
        /// False when the event already had a note in the library (that note is returned).
        var created: Bool
        var pages: [String]?
        var blocks: [String]?
    }

    static let descriptor = CommandDescriptor(
        id: "calendar.createNote", title: "Create Event Note",
        summary: "Create a notebook, text document or whiteboard for a calendar event in 'Calendar Event/{Event}/{Event} {Date}' with a title, date and attendees header, linked to the event → {ref, created}.",
        params: .obj([
            "event": .str("event id from calendar.events"),
            "kind": .str("notebook | textDocument | whiteboard", choices: CalendarSettings.noteKinds.map { $0.rawValue }),
            "id": .str("your own document id, [A-Za-z0-9_-]{1,64}")
        ], required: ["event", "kind"]),
        examples: [["event": "20260930-8f3a2c1d9e4b", "kind": "notebook"],
                   ["event": "20260930-8f3a2c1d9e4b", "kind": "textDocument", "id": "MEETINGNOTE1"]],
        effect: .library, target: .library)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard CalendarEventID.isValid(p.event) else {
            throw NibError(.invalidParams, "'\(p.event)' is not a calendar event id", path: "$.event",
                           hint: "use an id returned by calendar.events")
        }
        guard let kind = DocumentKind(rawValue: p.kind), CalendarSettings.noteKinds.contains(kind) else {
            throw NibError.invalid("kind must be notebook, textDocument or whiteboard", path: "$.kind")
        }
        var chosen: DocumentID?
        if let raw = p.id {
            guard NibID.isValid(raw) else { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
            chosen = NibID(raw)
        }
        let store = try CalendarStore.require(ctx)
        let event = try await store.event(id: p.event, principal: ctx.principal)
        let library = try ctx.services.require(ctx.services.library, "the library")
        if let existing = store.liveNote(for: event.id) {
            let node = library.node(existing.doc)
            return Output(ref: NodeRef.document(existing.doc).description, title: node?.title ?? existing.link.title,
                          folder: node?.parent.map { NodeRef.folder($0).description }, event: event.id, created: false,
                          pages: nil, blocks: nil)
        }
        let id = chosen ?? NibID.make()
        if chosen != nil, library.node(id) != nil || ctx.workspace.isLoaded(id) {
            throw NibError(.conflict, "document id \(id.raw) is already in use", path: "$.id",
                           hint: "choose another id or leave it out")
        }
        let calendar = Calendar.current
        let path = EventNotePaths(event: event, calendar: calendar)
        let content = EventNoteBuilder.content(kind: kind, id: id, event: event, settings: ctx.services.settings,
                                               boardTemplate: boardTemplate(ctx), clock: ctx.workspace.clock,
                                               calendar: calendar)
        if ctx.dryRun {
            // A preview (AI, plugin.run) creates nothing.
            return output(content, id: id, title: path.document, folder: nil, event: event.id)
        }
        let root = try folder(named: path.root, in: nil, library)
        let eventFolder = try folder(named: path.event, in: root, library)
        let created = try library.createDocument(content, title: path.document, in: eventFolder)
        if let header = EventNoteBuilder.headerItem(kind: kind, event: event, content: content, calendar: calendar),
           let page = content.livePages.first {
            // Part of creating the document, like its first page: persisted, not an undo step.
            try ctx.mutate("Event Note Header", undoable: false) { tx in
                _ = try tx.put(header, doc: created, page: page.id)
            }
        }
        let title = library.node(created)?.title ?? path.document
        let link = NoteLink(doc: NodeRef.document(created).description, title: title, kind: kind.rawValue,
                            start: CalendarDates.iso(event.start), created: Date().timeIntervalSince1970)
        ctx.services.settings.setJSON(CalendarSettings.noteName(event.id), try JSONValue.from(link))
        return output(content, id: created, title: title, folder: NodeRef.folder(eventFolder).description, event: event.id)
    }

    static func output(_ content: DocumentContent, id: DocumentID, title: String, folder: String?, event: String) -> Output {
        let pages = content.livePages.map { NodeRef.page(id, $0.id).description }
        let blocks = content.liveBlocks.map { NodeRef.block(id, $0.id).description }
        return Output(ref: NodeRef.document(id).description, title: title, folder: folder, event: event, created: true,
                      pages: pages.isEmpty ? nil : pages, blocks: blocks.isEmpty ? nil : blocks)
    }

    /// The folder called `title` in `parent` (the oldest when there are several), created when missing.
    static func folder(named title: String, in parent: FolderID?, _ library: LibraryService) throws -> FolderID {
        let existing = library.children(of: parent)
            .filter { $0.kind == .folder && $0.title.compare(title, options: [.caseInsensitive]) == .orderedSame }
            .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
        if let f = existing.first { return f.id }
        return try library.createFolder(title: title, in: parent, style: nil)
    }

    /// A zoom-adaptive whiteboard background when the templates are installed, else the paper, else blank.
    static func boardTemplate(_ ctx: CommandContext) -> TemplateRef {
        let templates = ctx.content.templates
        if templates.get(TemplateIDs.whiteboardDots) != nil { return TemplateRef(TemplateIDs.whiteboardDots) }
        let paper = ctx.services.settings.get(NibSettings.defaultPaper)
        if templates.get(paper.id) != nil { return paper }
        return TemplateRef(TemplateIDs.blank)
    }
}

// MARK: - calendar.openNote

struct CalendarOpenNote: NibCommand {
    struct Params: Codable {
        var event: String
    }

    struct Output: Codable {
        var ref: String
        /// False when there is no window to open it in (headless callers).
        var opened: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "calendar.openNote", title: "Open Event Note",
        summary: "Open the note linked to a calendar event in the current window (not_found when it has none: call calendar.createNote) → {ref, opened}.",
        params: .obj(["event": .str("event id from calendar.events")], required: ["event"]),
        examples: [["event": "20260930-8f3a2c1d9e4b"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard CalendarEventID.isValid(p.event) else {
            throw NibError(.invalidParams, "'\(p.event)' is not a calendar event id", path: "$.event",
                           hint: "use an id returned by calendar.events")
        }
        let store = try CalendarStore.require(ctx)
        guard store.noteLink(for: p.event) != nil else {
            throw NibError(.notFound, "calendar event \(p.event) has no note",
                           hint: "create one with calendar.createNote {event, kind}")
        }
        guard let live = store.liveNote(for: p.event) else {
            throw NibError(.notFound, "the note of calendar event \(p.event) was deleted or moved to Trash",
                           hint: "create a new one with calendar.createNote {event, kind}")
        }
        let ref = NodeRef.document(live.doc).description
        do {
            _ = try await ctx.execute(CommandIDs.docOpen, ["doc": .string(ref)])
            return Output(ref: ref, opened: true)
        } catch let e as NibError where e.code == .unavailable {
            // Tabs & Windows (doc.open) is not installed: open it in the invoking window directly.
            guard let navigator = ctx.navigator else { return Output(ref: ref, opened: false) }
            navigator.openDocument(live.doc, page: nil, mode: .replace)
            return Output(ref: ref, opened: true)
        }
    }
}

// MARK: - Note paths and content

/// Where an event's note goes: 'Calendar Event/{Event}/{Event} {Date}'. Titles are cleaned for every file provider
/// (no path separators or characters OneDrive and Dropbox reject). Pure, so it is unit-tested.
struct EventNotePaths: Equatable {
    /// The root folder's name. Not translated: every device files notes into the same synced folder.
    static let rootFolder = "Calendar Event"
    static let maxTitleLength = 80

    let root: String
    let event: String
    let document: String

    init(event e: CalendarEvent, calendar: Calendar) {
        root = Self.rootFolder
        event = Self.sanitize(e.title, fallback: String(localized: "Untitled Event"))
        document = event + " " + CalendarDates.day(e.start, calendar: calendar)
    }

    var components: [String] { [root, event, document] }

    static func sanitize(_ title: String, fallback: String) -> String {
        var s = ""
        for ch in title {
            switch ch {
            case "/", "\\": s.append("-")
            case ":", "*", "?", "\"", "<", ">", "|": continue
            default: s.append(ch.isNewline || ch == "\t" ? " " : ch)
            }
        }
        s = s.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        if s.count > maxTitleLength {
            s = String(s.prefix(maxTitleLength)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        return s.isEmpty ? fallback : s
    }
}

/// The first content of an event's note: the note header (title, date and time, location, attendees) as a text box on
/// a notebook's first page or a whiteboard, or as the opening blocks of a text document.
enum EventNoteBuilder {
    static func dateLine(_ e: CalendarEvent, calendar: Calendar) -> String {
        var long = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        long.calendar = calendar
        long.timeZone = calendar.timeZone
        var short = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        short.calendar = calendar
        short.timeZone = calendar.timeZone
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        if e.allDay {
            let last = calendar.startOfDay(for: max(e.start, e.end.addingTimeInterval(-1)))
            let days = calendar.isDate(e.start, inSameDayAs: last)
                ? e.start.formatted(long)
                : e.start.formatted(short) + " – " + last.formatted(short)
            return String(localized: "\(days), all day")
        }
        if calendar.isDate(e.start, inSameDayAs: e.end) || e.end <= e.start {
            return e.start.formatted(long) + ", " + e.start.formatted(time) + " – " + e.end.formatted(time)
        }
        return e.start.formatted(short) + ", " + e.start.formatted(time) + " – " + e.end.formatted(short) + ", "
            + e.end.formatted(time)
    }

    static let maxListedAttendees = 20

    static func attendeesLine(_ e: CalendarEvent) -> String? {
        let names = e.attendees.map { $0.displayName }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        var shown = names.prefix(maxListedAttendees).joined(separator: ", ")
        if names.count > maxListedAttendees {
            shown += ", " + String(localized: "and \(names.count - maxListedAttendees) more")
        }
        return String(localized: "Attendees: \(shown)")
    }

    static func locationLine(_ e: CalendarEvent) -> String? {
        e.location.map { String(localized: "Location: \($0)") }
    }

    static func title(_ e: CalendarEvent) -> String {
        e.title.isEmpty ? String(localized: "Untitled Event") : e.title
    }

    /// Title (bold), then the date line, location and attendees.
    static func headerText(_ e: CalendarEvent, calendar: Calendar) -> RichText {
        var paragraphs = [Paragraph(runs: [TextRun(title(e), TextAttributes(size: 24, bold: true))])]
        let detail = TextAttributes(size: 14)
        for line in [dateLine(e, calendar: calendar), locationLine(e), attendeesLine(e)].compactMap({ $0 }) {
            paragraphs.append(Paragraph(runs: [TextRun(line, detail)]))
        }
        return RichText(paragraphs: paragraphs)
    }

    static func content(kind: DocumentKind, id: DocumentID, event e: CalendarEvent, settings: SettingsStore,
                        boardTemplate: TemplateRef, clock: HLCClock, calendar: Calendar) -> DocumentContent {
        var meta = DocumentMeta(id: id, kind: kind, createdAt: Date().timeIntervalSince1970,
                                language: settings.get(NibSettings.defaultLanguage),
                                scrollDirection: settings.get(NibSettings.scrollDirection))
        meta.spellcheck = settings.get(NibSettings.spellcheckNewDocuments)
        meta.mathAssist = settings.get(NibSettings.mathAssistSuggestions)
        meta.coverEnabled = false
        meta.ext = ["calendar": ["event": .string(e.id), "title": .string(e.title),
                                 "start": .string(CalendarDates.iso(e.start))]]
        var content = DocumentContent(meta: meta)
        switch kind {
        case .notebook:
            let paper = settings.get(NibSettings.defaultPaper)
            content.meta.defaultTemplate = paper
            var page = PageRecord(order: FractionalIndex.between(nil, nil), size: settings.get(NibSettings.defaultPageSize),
                                  background: Background(kind: .template, template: paper))
            page.rev = clock.tick()
            content.pages = [page]
        case .whiteboard:
            content.meta.defaultTemplate = boardTemplate
            var board = PageRecord(order: FractionalIndex.between(nil, nil), size: nil,
                                   background: Background(kind: .template, template: boardTemplate),
                                   title: String(localized: "Board 1"))
            board.rev = clock.tick()
            content.pages = [board]
        case .textDocument:
            var lines: [(BlockKind, String)] = [(.heading1, title(e)), (.paragraph, dateLine(e, calendar: calendar))]
            if let l = locationLine(e) { lines.append((.paragraph, l)) }
            if let a = attendeesLine(e) { lines.append((.paragraph, a)) }
            lines.append((.paragraph, ""))
            let keys = FractionalIndex.balanced(count: lines.count)
            content.blocks = lines.enumerated().map { i, line in
                var block = TextBlock(kind: line.0, text: line.1.isEmpty ? .empty : RichText(plain: line.1), order: keys[i])
                block.rev = clock.tick()
                return block
            }
        case .studySet:
            break
        }
        content.meta.rev = clock.tick()
        return content
    }

    /// The header text box for notebooks and whiteboards (text documents carry it in their blocks).
    static func headerItem(kind: DocumentKind, event e: CalendarEvent, content: DocumentContent, calendar: Calendar) -> Item? {
        guard kind == .notebook || kind == .whiteboard, let page = content.livePages.first else { return nil }
        let text = headerText(e, calendar: calendar)
        let lines = Double(text.paragraphs.count)
        let height = 24 * 1.3 + (lines - 1) * 14 * 1.4 + 12
        let frame: Frame
        if let size = page.size {
            let margin = max(28, min(size.width, size.height) * 0.08)
            frame = Frame(x: margin, y: margin, w: max(120, size.width - 2 * margin), h: height)
        } else {
            frame = Frame(x: 40, y: 40, w: 560, h: height)
        }
        return Item.makeText(TextBoxItem(frame: frame, text: text, style: TextBoxStyle(autoGrow: true)), layer: 0)
    }
}
