import SwiftUI
import UIKit
import NibContracts
import NibDesign

// The calendar UI: the library's Calendar tab (upcoming events, See Other Events, Take Notes / Open Note), the New
// Event Planner sheet, the planner page's sync pill (a chrome overlay) and the Settings page. Content, not chrome:
// opaque surfaces on the library background; the only droplet is the pill, which the document chrome hosts. Every
// action runs a command (`calendar.*`, `panel.open`, `commands.batch`, `doc.open`, `settings.set`).

enum CalendarIDs {
    static let tab = "calendar.tab"
    static let newPlanner = "calendar.newPlanner"
    static let settings = "calendar.settings"
    static let syncPill = "calendar.plannerSync"
    static let syncKey = "calendar.syncPage"
    /// ⇧⌥⌘R: Sync Calendar Events (⌥⌘R is Read Only, ⇧⌘R recording).
    static let syncShortcut = KeyShortcut("r", [.command, .option, .shift])
    static let swiftUISyncShortcut = KeyboardShortcut("r", modifiers: [.command, .option, .shift])
}

// MARK: - Planner pages

/// A dated "planner.events" page open in a window: what its sync button reads.
struct PlannerPage: Equatable {
    var doc: DocumentID
    var page: PageID
    var params: EventPlannerParams
    var interval: DateInterval

    /// `calendar.events` params for the page's dates.
    var syncParams: JSONValue {
        ["from": .string(CalendarDates.iso(interval.start)), "to": .string(CalendarDates.iso(interval.end))]
    }

    /// The window's current page when it is a dated event planner page (only loaded documents are read).
    @MainActor
    static func current(_ app: NibApp, session: EditorSession?) -> PlannerPage? {
        at(app, doc: session?.document, page: session?.page)
    }

    @MainActor
    static func at(_ app: NibApp, doc: DocumentID?, page: PageID?) -> PlannerPage? {
        guard let doc = doc, let page = page, app.workspace.isLoaded(doc),
              let content = try? app.workspace.content(doc), let record = content.page(page), !record.deleted,
              record.background.kind == .template, let template = record.background.template,
              template.id == EventPlannerTemplate.id else { return nil }
        let params = EventPlannerParams(EventPlannerTemplate.defaults.merging(template.params) { _, new in new })
        guard let interval = params.interval(in: params.calendar()) else { return nil }
        return PlannerPage(doc: doc, page: page, params: params, interval: interval)
    }

    /// The next seven days, for the sync key outside planner pages.
    static var upcomingParams: JSONValue {
        let w = CalendarDates.upcomingWindow()
        return ["from": .string(CalendarDates.iso(w.start)), "to": .string(CalendarDates.iso(w.end))]
    }
}

/// The pages of a new event planner and the `commands.batch` that creates it (`doc.create` + `page.add`). Pure.
struct PlannerPlan {
    static let maxDays = 31
    static let maxWeeks = 12

    var pages: [EventPlannerParams]
    var interval: DateInterval

    init(start: Date, layout: EventPlannerParams.Layout, weekStart: EventPlannerParams.WeekStart, count: Int,
         calendar base: Calendar) {
        let n = max(1, min(count, layout == .daily ? Self.maxDays : Self.maxWeeks))
        let probe = EventPlannerParams(date: start, layout: layout, weekStart: weekStart, calendar: base)
        let cal = probe.calendar(timeZone: base.timeZone, locale: base.locale ?? .current)
        let first = probe.firstDay(in: cal) ?? cal.startOfDay(for: start)
        let step = layout == .daily ? 1 : 7
        pages = (0..<n).compactMap { i in
            cal.date(byAdding: .day, value: i * step, to: first).map {
                EventPlannerParams(date: $0, layout: layout, weekStart: weekStart, calendar: cal)
            }
        }
        let end = cal.date(byAdding: .day, value: n * step, to: first) ?? first.addingTimeInterval(Double(n * step) * 86_400)
        interval = DateInterval(start: first, end: end)
    }

    func template(_ p: EventPlannerParams) -> JSONValue {
        ["id": .string(EventPlannerTemplate.id), "params": .object(p.json)]
    }

    /// `commands.batch` params: a coverless notebook with the first page, then the others at the end.
    func batch(doc: DocumentID, title: String) -> JSONValue {
        guard let first = pages.first else { return ["calls": []] }
        let docRef = NodeRef.document(doc).description
        var calls: [JSONValue] = [[
            "command": .string(CommandIDs.docCreate),
            "params": ["kind": "notebook", "title": .string(title), "template": template(first), "cover": false,
                       "pages": 1, "id": .string(doc.raw)]
        ]]
        for p in pages.dropFirst() {
            calls.append(["command": .string(CommandIDs.pageAdd),
                          "params": ["doc": .string(docRef), "position": "end", "template": template(p)]])
        }
        return ["calls": .array(calls), "stopOnError": true]
    }

    static func title(start: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let date = EventNotePaths.sanitize(start.formatted(style), fallback: CalendarDates.day(start, calendar: calendar))
        return String(localized: "Event Planner \(date)")
    }
}

// MARK: - Display text

enum CalendarText {
    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "Maybe", "Invited", "Declined", "Cancelled"; nil for accepted and your own events.
    static func answer(_ e: CalendarEvent) -> String? {
        if e.status == .cancelled { return String(localized: "Cancelled") }
        switch e.rsvp {
        case .tentative: return String(localized: "Maybe")
        case .pending: return String(localized: "Invited")
        case .declined: return String(localized: "Declined")
        case .accepted, .none, .delegated: return nil
        }
    }

    static func people(_ count: Int) -> String {
        count == 1 ? String(localized: "1 person") : String(localized: "\(count) people")
    }

    /// "Room 4 · 5 people · Maybe".
    static func detail(_ e: CalendarEvent) -> String {
        var parts: [String] = []
        if let place = e.location { parts.append(place) }
        if !e.attendees.isEmpty { parts.append(people(e.attendees.count)) }
        if let a = answer(e) { parts.append(a) }
        if parts.isEmpty { parts.append(e.calendar.title) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func accessibilityLabel(_ e: CalendarEvent, hasNote: Bool) -> String {
        var parts = [e.title.isEmpty ? String(localized: "Untitled Event") : e.title]
        parts.append(e.allDay ? String(localized: "All day")
                              : String(localized: "\(time(e.start)) to \(time(e.end))"))
        parts.append(detail(e))
        if hasNote { parts.append(String(localized: "Has a note")) }
        return parts.joined(separator: ", ")
    }

    static func kindTitle(_ k: DocumentKind) -> String {
        switch k {
        case .notebook: return String(localized: "Notebook")
        case .textDocument: return String(localized: "Text Document")
        case .whiteboard: return String(localized: "Whiteboard")
        case .studySet: return String(localized: "Study Set")
        }
    }

    static func kindSymbol(_ k: DocumentKind) -> NibSymbol {
        switch k {
        case .notebook: return .notebook
        case .textDocument: return .textDocument
        case .whiteboard: return .whiteboard
        case .studySet: return .studySets
        }
    }

    static func newNoteTitle(_ k: DocumentKind) -> String {
        switch k {
        case .notebook: return String(localized: "New Notebook Note")
        case .textDocument: return String(localized: "New Text Document Note")
        case .whiteboard: return String(localized: "New Whiteboard Note")
        case .studySet: return String(localized: "New Study Set Note")
        }
    }

    static func reminderTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return String(localized: "Off")
        case 1: return String(localized: "1 minute before")
        default: return String(localized: "\(minutes) minutes before")
        }
    }

    static func synced(_ date: Date?) -> String {
        guard let d = date else { return String(localized: "Not synced") }
        return String(localized: "Synced \(time(d))")
    }
}

/// Upcoming events grouped by day (an event spanning several days shows on each). Pure.
struct CalendarDaySection: Identifiable, Equatable {
    var day: Date
    var events: [CalendarEvent]
    var id: Date { day }

    static func make(_ events: [CalendarEvent], window: DateInterval, calendar: Calendar) -> [CalendarDaySection] {
        var out: [CalendarDaySection] = []
        var day = calendar.startOfDay(for: window.start)
        while day < window.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let today = events.filter { CalendarEventCache.overlaps($0, day, next) }.sorted(by: CalendarEvent.chronological)
            if !today.isEmpty { out.append(CalendarDaySection(day: day, events: today)) }
            day = next
        }
        return out
    }
}

// MARK: - Calendar tab (library)

struct CalendarTab: View {
    let context: PanelContext
    @ObservedObject var store: CalendarStore
    @State private var showsOtherEvents = false
    @State private var busy: Set<String> = []
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var gutter: CGFloat { sizeClass == .compact ? NibSpacing.l : NibMetrics.libraryGutter }

    var body: some View {
        ScrollView {
            CalendarTabBody(context: context, store: store, showsOtherEvents: $showsOtherEvents, busy: $busy)
                .frame(maxWidth: NibMetrics.textColumnWidth, alignment: .leading)
                .padding(.horizontal, gutter)
                .padding(.vertical, NibSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NibColor.background)
        .refreshable { await store.loadUpcoming(session: context.session, connect: false) }
        .task { await store.loadUpcoming(session: context.session, connect: false) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            store.refreshAccess()
        }
        .nibSheet(isPresented: $showsOtherEvents) {
            OtherEventsSheet(store: store, session: context.session) { showsOtherEvents = false }
        }
    }
}

/// The Calendar tab's content: the title, the options, and the state for the current calendar access.
struct CalendarTabBody: View {
    let context: PanelContext
    @ObservedObject var store: CalendarStore
    @Binding var showsOtherEvents: Bool
    @Binding var busy: Set<String>

    private var app: NibApp { context.app }

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.x3) {
            header
            content
        }
    }

    // MARK: Header

    private var subtitle: String {
        switch store.access {
        case .granted:
            if store.isSyncing { return String(localized: "Syncing events") }
            let window = CalendarDates.upcomingWindow()
            let synced = store.cache.lastSync(covering: window.start, window.end)
            return String(localized: "Next 7 days") + " · " + CalendarText.synced(synced)
        case .notDetermined, .denied, .restricted, .writeOnly, .unavailable:
            return String(localized: "Events from the calendars on this device")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NibSpacing.s) {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                Text(String(localized: "Calendar"))
                    .font(NibFont.display)
                    .foregroundStyle(NibColor.label)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            Spacer(minLength: NibSpacing.s)
            if store.access == .granted {
                if store.isSyncing {
                    ProgressView()
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                        .accessibilityLabel(String(localized: "Syncing events"))
                } else {
                    NibIconButton(.retry, label: String(localized: "Sync Calendar Events"), size: .bar,
                                  shortcut: CalendarIDs.swiftUISyncShortcut) {
                        Task { await store.loadUpcoming(session: context.session, connect: false) }
                    }
                }
            }
            optionsMenu
        }
    }

    private var reminderBinding: Binding<Int> {
        Binding(get: { _ = store.revision; return app.settings.get(CalendarSettings.reminderMinutes) },
                set: { minutes in Task { await store.setReminderMinutes(minutes, session: context.session) } })
    }

    private var kindBinding: Binding<String> {
        Binding(get: { _ = store.revision; return app.settings.get(CalendarSettings.noteKind) },
                set: { raw in
                    guard let kind = DocumentKind(rawValue: raw) else { return }
                    Task { await store.setNoteKind(kind, session: context.session) }
                })
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                app.perform(CommandIDs.panelOpen, ["id": .string(CalendarIDs.newPlanner)], session: context.session)
            } label: {
                Label { Text(String(localized: "New Event Planner")) } icon: { Image(nib: .templates) }
            }
            Button {
                showsOtherEvents = true
            } label: {
                Label { Text(String(localized: "See Other Events")) } icon: { Image(nib: .calendar) }
            }
            Picker(selection: reminderBinding) {
                ForEach(CalendarSettings.reminderChoices, id: \.self) { m in Text(CalendarText.reminderTitle(m)).tag(m) }
            } label: {
                Label { Text(String(localized: "Remind Me")) } icon: { Image(nib: .reminder) }
            }
            .pickerStyle(.menu)
            Picker(selection: kindBinding) {
                ForEach(CalendarSettings.noteKinds, id: \.rawValue) { k in
                    Text(CalendarText.kindTitle(k)).tag(k.rawValue)
                }
            } label: {
                Label { Text(String(localized: "Take Notes In")) } icon: { Image(nib: .documentWrite) }
            }
            .pickerStyle(.menu)
        } label: {
            Image(nib: .moreCircle)
                .font(NibFont.glyph(.bar))
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Calendar Options"))
        .nibTooltip(String(localized: "Calendar Options"))
        .hoverEffect(.highlight)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch store.access {
        case .notDetermined:
            NibEmptyState(symbol: .calendar, title: String(localized: "Connect your calendars"),
                          message: String(localized: "See upcoming meetings and take notes for them, including Google and Outlook accounts added in the Settings app."),
                          primary: NibAction(String(localized: "Connect Calendars")) {
                              Task { await store.loadUpcoming(session: context.session, connect: true) }
                          })
                .frame(maxWidth: .infinity)
                .padding(.top, NibSpacing.x5)
        case .denied, .restricted, .writeOnly:
            NibEmptyState(symbol: .calendar, title: String(localized: "Calendar access is off"),
                          message: String(localized: "Allow Nib full access to Calendars in Settings to see your events and take notes for them."),
                          primary: NibAction(String(localized: "Open Settings")) { CalendarSystem.openSettings() })
                .frame(maxWidth: .infinity)
                .padding(.top, NibSpacing.x5)
        case .unavailable:
            NibEmptyState(symbol: .calendar, title: String(localized: "No calendar on this device"),
                          message: String(localized: "Calendar events are not available here."))
                .frame(maxWidth: .infinity)
                .padding(.top, NibSpacing.x5)
        case .granted:
            granted
        }
    }

    @ViewBuilder private var granted: some View {
        if let error = store.lastError {
            NibBanner(error.message, action: NibAction(String(localized: "Try Again")) {
                Task { await store.loadUpcoming(session: context.session, connect: false) }
            })
        }
        let window = CalendarDates.upcomingWindow()
        let sections = CalendarDaySection.make(store.upcoming, window: window, calendar: .current)
        if sections.isEmpty {
            if store.lastError != nil {
                EmptyView()
            } else if !store.upcomingLoaded {
                HStack(spacing: NibSpacing.s) {
                    ProgressView()
                    Text(String(localized: "Loading events"))
                        .font(NibFont.callout)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget)
                .padding(.top, NibSpacing.x5)
                .accessibilityElement(children: .combine)
            } else {
                NibEmptyState(symbol: .calendar, title: String(localized: "Nothing in the next 7 days"),
                              message: String(localized: "Events from your calendars show up here."),
                              primary: NibAction(String(localized: "See Other Events")) { showsOtherEvents = true })
                    .frame(maxWidth: .infinity)
                    .padding(.top, NibSpacing.x5)
            }
        } else {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: NibSpacing.xs) {
                    Text(CalendarText.dayTitle(section.day))
                        .font(NibFont.title3)
                        .foregroundStyle(NibColor.label)
                        .accessibilityAddTraits(.isHeader)
                    CalendarEventList(events: section.events, store: store, busy: $busy, session: context.session)
                }
            }
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                NibButton(String(localized: "See Other Events"), symbol: .calendar, kind: .secondary) {
                    showsOtherEvents = true
                }
                if !store.accounts.isEmpty {
                    Text(String(localized: "From \(ListFormatter.localizedString(byJoining: store.accounts))"))
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
        }
    }
}

/// Rows of events with hairlines between them.
struct CalendarEventList: View {
    let events: [CalendarEvent]
    @ObservedObject var store: CalendarStore
    @Binding var busy: Set<String>
    let session: EditorSession?
    var onBeforeOpen: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                let live = store.liveNote(for: event.id)
                CalendarEventRow(event: event, noteKind: live.flatMap { DocumentKind(rawValue: $0.link.kind) },
                                 hasNote: live != nil, isBusy: busy.contains(event.id),
                                 onTakeNotes: { kind in run(event.id) { await store.takeNotes(event.id, kind: kind, session: session) } },
                                 onOpenNote: { run(event.id) { await store.takeNotes(event.id, kind: nil, session: session) } })
                if index < events.count - 1 {
                    Rectangle()
                        .fill(NibColor.separator)
                        .frame(height: NibStroke.hairline)
                        .accessibilityHidden(true)
                }
            }
        }
        .id(store.revision)
    }

    private func run(_ id: String, _ work: @escaping () async -> Void) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        onBeforeOpen?()
        Task { @MainActor in
            await work()
            busy.remove(id)
        }
    }
}

struct CalendarEventRow: View {
    let event: CalendarEvent
    let noteKind: DocumentKind?
    let hasNote: Bool
    let isBusy: Bool
    let onTakeNotes: (DocumentKind?) -> Void
    let onOpenNote: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 56

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: NibSpacing.s))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: NibSpacing.m))
        layout {
            summary
            if !stacked { Spacer(minLength: NibSpacing.s) }
            noteButton
        }
        .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        .padding(.vertical, NibSpacing.m)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    private var title: String { event.title.isEmpty ? String(localized: "Untitled Event") : event.title }

    private var summary: some View {
        HStack(alignment: .top, spacing: NibSpacing.m) {
            VStack(alignment: .trailing, spacing: 2) {
                if event.allDay {
                    Text(String(localized: "All day"))
                        .font(NibFont.footnoteEmphasis)
                        .foregroundStyle(NibColor.label)
                } else {
                    Text(CalendarText.time(event.start))
                        .font(NibFont.footnoteEmphasis)
                        .foregroundStyle(NibColor.label)
                    Text(CalendarText.time(event.end))
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
            .monospacedDigit()
            .frame(width: typeSize.isAccessibilitySize ? nil : timeWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NibFont.body)
                    .foregroundStyle(event.isDeclined ? NibColor.labelSecondary : NibColor.label)
                    .strikethrough(event.isDeclined)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text(CalendarText.detail(event))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            .padding(.leading, NibSpacing.m)
            .overlay(alignment: .leading) {
                // The calendar's colour (the person's own colour, like a folder's): a 4 pt bar as tall as the text.
                Capsule()
                    .fill(Color(uiColor: event.colour.withAlpha(1).uiColor))
                    .frame(width: 4)
                    .opacity(event.isDeclined ? NibOpacity.disabled : 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CalendarText.accessibilityLabel(event, hasNote: hasNote))
        .modifier(NoteActions(enabled: !hasNote && !isBusy, take: onTakeNotes))
    }

    @ViewBuilder private var noteButton: some View {
        if isBusy {
            ProgressView()
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .accessibilityLabel(String(localized: "Opening note"))
        } else if hasNote {
            NibButton(String(localized: "Open Note"), symbol: CalendarText.kindSymbol(noteKind ?? .notebook), kind: .plain,
                      size: .compact, action: onOpenNote)
                .accessibilityHint(String(localized: "Opens the note for \(title)"))
        } else {
            NibButton(String(localized: "Take Notes"), symbol: .documentWrite, kind: .secondary, size: .compact) {
                onTakeNotes(nil)
            }
            .accessibilityHint(String(localized: "Creates a note for \(title) and opens it"))
        }
    }

    @ViewBuilder private var menu: some View {
        if hasNote {
            Button(action: onOpenNote) {
                Label { Text(String(localized: "Open Note")) } icon: { Image(nib: CalendarText.kindSymbol(noteKind ?? .notebook)) }
            }
        } else {
            ForEach(CalendarSettings.noteKinds, id: \.rawValue) { kind in
                Button {
                    onTakeNotes(kind)
                } label: {
                    Label { Text(CalendarText.newNoteTitle(kind)) } icon: {
                        Image(nib: CalendarText.kindSymbol(kind))
                    }
                }
            }
        }
    }
}

/// The context menu's "New … Note" choices as VoiceOver actions on an event without a note.
struct NoteActions: ViewModifier {
    let enabled: Bool
    let take: (DocumentKind?) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: Text(CalendarText.newNoteTitle(.notebook))) { take(.notebook) }
                .accessibilityAction(named: Text(CalendarText.newNoteTitle(.textDocument))) { take(.textDocument) }
                .accessibilityAction(named: Text(CalendarText.newNoteTitle(.whiteboard))) { take(.whiteboard) }
        } else {
            content
        }
    }
}

enum CalendarSystem {
    /// The app's page in the Settings app (Calendars access, notifications).
    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - See Other Events

struct OtherEventsSheet: View {
    @ObservedObject var store: CalendarStore
    let session: EditorSession?
    let onDone: () -> Void
    @State private var date = Date()
    @State private var events: [CalendarEvent] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Other Events"), cancelTitle: String(localized: "Done"), onCancel: onDone)
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    DatePicker(String(localized: "Date"), selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(NibColor.accent)
                    Text(CalendarText.dayTitle(date))
                        .font(NibFont.title3)
                        .foregroundStyle(NibColor.label)
                        .accessibilityAddTraits(.isHeader)
                    dayContent
                }
                .padding(.horizontal, NibSpacing.xl)
                .padding(.bottom, NibSpacing.xxl)
            }
        }
        .background(NibColor.backgroundSecondary)
        .task(id: CalendarDates.day(date)) { await load() }
    }

    @ViewBuilder private var dayContent: some View {
        if let failure = failure {
            NibBanner(failure, action: NibAction(String(localized: "Try Again")) { Task { await load() } })
        } else if loading && events.isEmpty {
            HStack(spacing: NibSpacing.s) {
                ProgressView()
                Text(String(localized: "Loading events"))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget)
            .accessibilityElement(children: .combine)
        } else if events.isEmpty {
            Text(String(localized: "No events on this day."))
                .font(NibFont.callout)
                .foregroundStyle(NibColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
        } else {
            CalendarEventList(events: events, store: store, busy: $busy, session: session, onBeforeOpen: onDone)
        }
    }

    private func load() async {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        loading = true
        defer { loading = false }
        do {
            let found = try await store.load(from: start, to: end, session: session)
            events = found.filter { CalendarEventCache.overlaps($0, start, end) }.sorted(by: CalendarEvent.chronological)
            failure = nil
        } catch {
            events = []
            failure = NibError.wrap(error).message
        }
    }
}

// MARK: - New Event Planner (sheet panel)

struct NewPlannerSheet: View {
    let context: PanelContext
    @ObservedObject var store: CalendarStore
    @State private var layout: EventPlannerParams.Layout = .daily
    @State private var weekStart: EventPlannerParams.WeekStart = Calendar.current.firstWeekday == 1 ? .sunday : .monday
    @State private var start = Date()
    @State private var days = 7
    @State private var weeks = 4
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "New Event Planner"), primaryTitle: String(localized: "Create Planner"),
                           isPrimaryEnabled: !working, onCancel: context.dismiss, onPrimary: create)
            List {
                Section {
                    VStack(alignment: .leading, spacing: NibSpacing.s) {
                        Text(String(localized: "Layout"))
                            .font(NibFont.footnoteEmphasis)
                            .foregroundStyle(NibColor.labelSecondary)
                        NibSegmentedControl(selection: $layout, options: EventPlannerParams.Layout.allCases) {
                            $0 == .daily ? String(localized: "Daily") : String(localized: "Weekly")
                        }
                    }
                    VStack(alignment: .leading, spacing: NibSpacing.s) {
                        Text(String(localized: "Week starts on"))
                            .font(NibFont.footnoteEmphasis)
                            .foregroundStyle(NibColor.labelSecondary)
                        NibSegmentedControl(selection: $weekStart, options: EventPlannerParams.WeekStart.allCases) {
                            $0 == .monday ? String(localized: "Monday") : String(localized: "Sunday")
                        }
                    }
                }
                Section {
                    DatePicker(String(localized: "Starts"), selection: $start, displayedComponents: .date)
                        .tint(NibColor.accent)
                    if layout == .daily {
                        Stepper(value: $days, in: 1...PlannerPlan.maxDays) {
                            Text(days == 1 ? String(localized: "1 day") : String(localized: "\(days) days"))
                        }
                    } else {
                        Stepper(value: $weeks, in: 1...PlannerPlan.maxWeeks) {
                            Text(weeks == 1 ? String(localized: "1 week") : String(localized: "\(weeks) weeks"))
                        }
                    }
                } footer: {
                    Text(String(localized: "Each page shows that day's events from your calendars. Use Sync on a page to update it."))
                }
                if working {
                    NibTraceRow(String(localized: "Creating planner"), phase: .running)
                }
                if let failure = failure {
                    NibBanner(failure)
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(NibColor.groupedBackground)
    }

    private func create() {
        guard !working else { return }
        let app = context.app
        let calendar = Calendar.current
        let plan = PlannerPlan(start: start, layout: layout, weekStart: weekStart, count: layout == .daily ? days : weeks,
                               calendar: calendar)
        let doc = NibID.make()
        let title = PlannerPlan.title(start: plan.interval.start, calendar: calendar)
        working = true
        failure = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let result = try await app.bus.execute(Invocation(command: CommandIDs.batch, params: plan.batch(doc: doc, title: title),
                                                                  session: context.session))
                if let failed = result.value["results"]?.arrayValue?.first(where: { $0["ok"]?.boolValue == false }) {
                    let message = failed["error"]?["message"]?.stringValue ?? String(localized: "The planner could not be created.")
                    failure = message
                    return
                }
                if store.access == .granted {
                    _ = try? await store.load(from: plan.interval.start, to: plan.interval.end, session: context.session)
                }
                context.dismiss()
                app.perform(CommandIDs.docOpen, ["doc": .string(NodeRef.document(doc).description)], session: context.session)
            } catch {
                failure = NibError.wrap(error).message
            }
        }
    }
}

// MARK: - Planner page sync pill (chrome overlay)

/// On a dated event planner page: when its events were read, and the button that reads them again
/// (`calendar.events` for the page's dates). Hosted by the document chrome as a Clear pill at the top trailing edge.
struct PlannerSyncPill: View {
    @ObservedObject var store: CalendarStore
    let context: ChromeContext
    @State private var syncing = false

    var body: some View {
        let page = PlannerPage.current(context.app, session: context.session)
        let synced = page.flatMap { p in store.cache.lastSync(covering: p.interval.start, p.interval.end) }
        HStack(spacing: NibSpacing.xxs) {
            Image(nib: .calendar)
                .font(NibFont.glyph(.bar))
                .foregroundStyle(NibColor.label)
                .padding(.leading, NibSpacing.s)
                .accessibilityHidden(true)
            if let synced = synced {
                NibHUDText(String(localized: "Synced"), secondary: CalendarText.time(synced))
            } else {
                NibHUDText(String(localized: "Not synced"))
            }
            if syncing || store.isSyncing {
                ProgressView()
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .accessibilityLabel(String(localized: "Syncing events"))
            } else {
                // The document key command (⇧⌥⌘R) already syncs this page: show its hint without registering it twice.
                NibIconButton(.retry, label: String(localized: "Sync Calendar Events"), size: .bar) { sync(page) }
                    .nibShortcutHint(CalendarIDs.swiftUISyncShortcut)
                    .disabled(page == nil)
            }
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .nibChromeTypeCap()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Calendar events on this page"))
        .accessibilityValue(CalendarText.synced(synced))
    }

    private func sync(_ page: PlannerPage?) {
        guard let page = page, !syncing else { return }
        syncing = true
        let app = context.app
        let session = context.session
        let host = context.floatingHost
        Task { @MainActor in
            defer { syncing = false }
            do {
                _ = try await app.bus.execute(Invocation(command: CalendarEvents.descriptor.id, params: page.syncParams,
                                                         session: session))
            } catch {
                let e = NibError.wrap(error)
                if let host = host {
                    host.postToast(e.message)
                } else {
                    store.report(e, command: CalendarEvents.descriptor.id)
                }
            }
        }
    }
}

// MARK: - Settings page

struct CalendarSettingsPage: View {
    let app: NibApp
    @ObservedObject var store: CalendarStore

    var body: some View {
        List {
            Section {
                NibRow(String(localized: "Calendar Access"), subtitle: accessText, icon: .calendar) {
                    accessAction
                }
            } footer: {
                Text(String(localized: "Nib reads the calendars on this device, including Google, Outlook and Exchange accounts added in the Settings app. Events stay on this device."))
            }
            Section {
                Picker(String(localized: "Remind Me"), selection: reminderBinding) {
                    ForEach(CalendarSettings.reminderChoices, id: \.self) { m in Text(CalendarText.reminderTitle(m)).tag(m) }
                }
                if store.notifications == .denied && app.settings.get(CalendarSettings.reminderMinutes) > 0 {
                    NibBanner(String(localized: "Notifications are off for Nib, so reminders cannot appear."),
                              action: NibAction(String(localized: "Open Settings")) { CalendarSystem.openSettings() })
                }
            } header: {
                Text(String(localized: "Reminders"))
            } footer: {
                Text(String(localized: "A notification before each timed event in the next week, with Take Notes to open its note."))
            }
            Section {
                Picker(String(localized: "Take Notes In"), selection: kindBinding) {
                    ForEach(CalendarSettings.noteKinds, id: \.rawValue) { k in Text(CalendarText.kindTitle(k)).tag(k.rawValue) }
                }
            } header: {
                Text(String(localized: "Notes"))
            } footer: {
                Text(String(localized: "Notes are filed in Calendar Event, in a folder for each event."))
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            store.refreshAccess()
            Task { await store.rescheduleReminders() }
        }
    }

    private var accessText: String {
        switch store.access {
        case .granted: return String(localized: "Full access")
        case .notDetermined: return String(localized: "Not connected")
        case .denied, .restricted: return String(localized: "Off")
        case .writeOnly: return String(localized: "Add events only")
        case .unavailable: return String(localized: "Not available")
        }
    }

    @ViewBuilder private var accessAction: some View {
        switch store.access {
        case .notDetermined:
            NibButton(String(localized: "Connect"), kind: .plain, size: .compact) {
                Task { await store.loadUpcoming(session: app.services.sessions.active, connect: true) }
            }
        case .denied, .restricted, .writeOnly:
            NibButton(String(localized: "Open Settings"), kind: .plain, size: .compact) { CalendarSystem.openSettings() }
        case .granted, .unavailable:
            EmptyView()
        }
    }

    private var reminderBinding: Binding<Int> {
        Binding(get: { _ = store.revision; return app.settings.get(CalendarSettings.reminderMinutes) },
                set: { minutes in Task { await store.setReminderMinutes(minutes, session: app.services.sessions.active) } })
    }

    private var kindBinding: Binding<String> {
        Binding(get: { _ = store.revision; return app.settings.get(CalendarSettings.noteKind) },
                set: { raw in
                    guard let kind = DocumentKind(rawValue: raw) else { return }
                    Task { await store.setNoteKind(kind, session: app.services.sessions.active) }
                })
    }
}
