import SwiftUI
import NibContracts
import NibDesign

/// Calendar (EventKit) & event notes (F075; D-036, S-058, S-059, P-080, P-090).
///
/// - The device's calendars through EventKit (iCloud, and Google, Outlook or Exchange accounts added in iOS Settings
///   appear automatically; no sign-in inside Nib). Access is asked for only on a user action; hostless runs are
///   `unavailable`.
/// - `calendar.events`, `calendar.createNote`, `calendar.openNote`: the library's Calendar tab (upcoming events, See
///   Other Events, Take Notes / Open Note) runs these, so the AI, plugins and the bridge can too.
/// - Event notes live in 'Calendar Event/{Event}/{Event} {Date}' with a title, date and attendees header; the
///   event → note map is one synced setting per event (`calendar.notes.<eventId>`).
/// - Reminders: local notifications N minutes before timed events, with a Take Notes action.
/// - The "planner.events" template (daily or weekly, Monday or Sunday start) draws cached events: RSVP state, an
///   all-day area and overlapping events in columns; each planner page has a sync button.
public enum FeatCalendarFeature: NibFeature {
    public static let id = calendarOwner

    public static func register(_ app: NibApp) {
        let store = CalendarStore(app: app)
        app.services.set(store, for: CalendarStore.serviceKey)
        CalendarSettings.declare(app.settings, owner: id)

        app.commands.register(CalendarEvents.self)
        app.commands.register(CalendarCreateNote.self)
        app.commands.register(CalendarOpenNote.self)

        app.content.templates.register(EventPlannerTemplate.definition(cache: store.cache))

        registerPanels(app, store: store)
        registerMenus(app)
        registerChrome(app, store: store)

        var page = SettingsPageDescriptor(id: CalendarIDs.settings, title: String(localized: "Calendar"),
                                          icon: NibSymbol.calendar.name, section: .general, order: 700, owner: id) { app in
            AnyView(CalendarSettingsPage(app: app, store: store))
        }
        page.keywords = ["calendar", "events", "meeting", "meetings", "reminder", "reminders", "notifications",
                         "Google", "Outlook", "Exchange", "iCloud", "planner", "EventKit"]
        app.ui.settingsPages.register(page)
    }

    /// Observers, the reminder router and a refresh of the next seven days (only when access was already granted).
    public static func start(_ app: NibApp) async {
        CalendarStore.shared(app)?.begin()
    }

    // MARK: Registration

    private static func registerPanels(_ app: NibApp, store: CalendarStore) {
        app.ui.panels.register(PanelDescriptor(
            id: CalendarIDs.tab, title: String(localized: "Calendar"), icon: NibSymbol.calendar.name,
            placement: .libraryTab, order: 450, owner: id) { ctx in
                AnyView(CalendarTab(context: ctx, store: store))
            })
        var planner = PanelDescriptor(
            id: CalendarIDs.newPlanner, title: String(localized: "New Event Planner"), icon: NibSymbol.templates.name,
            placement: .sheet, order: 460, owner: id) { ctx in
                AnyView(NewPlannerSheet(context: ctx, store: store))
            }
        planner.providesHeader = true
        app.ui.panels.register(planner)
    }

    private static func registerMenus(_ app: NibApp) {
        app.ui.menus.register(MenuItemDescriptor(
            id: "calendar.newPlanner.menu", title: String(localized: "Event Planner"), icon: NibSymbol.calendar.name,
            location: .libraryNew, order: 250, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(CalendarIDs.newPlanner)] }))
        for location in [MenuLocation.documentMore, .pageLongPress] {
            app.ui.menus.register(MenuItemDescriptor(
                id: "calendar.syncPage." + location.rawValue, title: String(localized: "Sync Calendar Events"),
                icon: NibSymbol.syncing.name, location: location, order: 640, owner: id,
                command: CalendarEvents.descriptor.id,
                params: { ctx in
                    PlannerPage.at(ctx.app, doc: ctx.doc ?? ctx.session?.document, page: ctx.page ?? ctx.session?.page)?
                        .syncParams ?? PlannerPage.upcomingParams
                },
                isVisible: { ctx in
                    PlannerPage.at(ctx.app, doc: ctx.doc ?? ctx.session?.document, page: ctx.page ?? ctx.session?.page) != nil
                }))
        }
        var key = KeyCommandDescriptor(
            id: CalendarIDs.syncKey, title: String(localized: "Sync Calendar Events"), shortcut: CalendarIDs.syncShortcut,
            command: CalendarEvents.descriptor.id, params: PlannerPage.upcomingParams, scope: .document, order: 640,
            owner: id)
        key.docKinds = [.notebook]
        key.sessionParams = { [weak app] session in
            guard let app = app, let page = PlannerPage.current(app, session: session) else { return PlannerPage.upcomingParams }
            return page.syncParams
        }
        app.content.keyCommands.register(key)
    }

    private static func registerChrome(_ app: NibApp, store: CalendarStore) {
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: CalendarIDs.syncPill, owner: id, placement: .topTrailing, surface: .pill, order: 60,
            recedesWhileWriting: true, isInteractive: true, docKinds: [.notebook],
            isVisible: { ctx in PlannerPage.current(ctx.app, session: ctx.session) != nil },
            makeView: { ctx in AnyView(PlannerSyncPill(store: store, context: ctx)) }))
    }
}
