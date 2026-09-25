import SwiftUI
import UIKit
import NibContracts
import NibDesign

/// Settings screens (F027): the settings root (`ui.screens.settingsRoot`) built from `ui.settingsPages`, the core
/// pages (Profile, Language, Notifications, Document Editing, Stylus & Palm Rejection), the app-menu entries and
/// `settings.open`. Every value is a `NibSettings` key written through the `settings.set` command.
public enum FeatSettingsFeature: NibFeature {
    public static let id = "settings"

    public static func register(_ app: NibApp) {
        let router = SettingsRouter(app: app)
        app.commands.register(SettingsOpen.descriptor) { json, ctx in
            let params = try CommandRegistry.decode(SettingsOpen.Params.self, from: json)
            let output = try await router.open(params, ctx)
            return try JSONValue.from(output)
        }
        app.ui.screens.settingsRoot = { current, _ in router.makeRoot(current) }
        for page in CoreSettingsPages.descriptors(owner: id) {
            app.ui.settingsPages.register(page)
        }
        for item in AppMenu.items(owner: id) {
            app.ui.menus.register(item)
        }
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: "settings.open", title: String(localized: "Settings"), shortcut: KeyShortcut(",", [.command]),
            command: SettingsOpen.id, scope: .global, order: 100, owner: id))
    }
}

// MARK: - Core pages

/// The pages this feature adds to Settings. Other features register theirs in their own `register`.
enum CoreSettingsPages {
    static let profile = "settings.profile"
    static let language = "settings.language"
    static let notifications = "settings.notifications"
    static let editing = "settings.editing"
    static let stylus = "settings.stylus"

    static func descriptors(owner: String) -> [SettingsPageDescriptor] {
        [
            SettingsPageDescriptor(id: profile, title: String(localized: "Profile"), icon: "person.crop.circle",
                                   section: .general, order: 10, owner: owner) { app in
                AnyView(ProfilePage(app: app))
            },
            SettingsPageDescriptor(id: language, title: String(localized: "Language"), icon: "globe",
                                   section: .general, order: 300, owner: owner) { app in
                AnyView(LanguagePage(app: app))
            },
            SettingsPageDescriptor(id: notifications, title: String(localized: "Notifications"), icon: "bell.badge",
                                   section: .general, order: 800, owner: owner) { app in
                AnyView(NotificationsPage(app: app))
            },
            SettingsPageDescriptor(id: editing, title: String(localized: "Document Editing"), icon: "doc.text",
                                   section: .editing, order: 10, owner: owner) { app in
                AnyView(DocumentEditingPage(app: app))
            },
            SettingsPageDescriptor(id: stylus, title: String(localized: "Stylus & Palm Rejection"), icon: "pencil.tip",
                                   section: .stylus, order: 10, owner: owner) { app in
                AnyView(StylusPage(app: app))
            },
        ]
    }

    /// Extra words the settings search matches for the core pages (a page descriptor carries only its title).
    /// ponytail: other features' pages match on title and section only; a `keywords` field on
    /// `SettingsPageDescriptor` would let them join in (contract gap).
    static func keywords(_ id: String) -> [String] {
        let list: String
        switch id {
        case editing:
            list = String(localized: "scroll, scrolling direction, vertical, horizontal, tabs, undo, redo, toolbar, layout, left, right, select, selection, tap, align, alignment, guides, snap, grid, status bar, zoom window, auto advance, sidebar")
        case stylus:
            list = String(localized: "Apple Pencil, pencil, stylus, any input, mouse, finger, fingers, finger drawing, palm, palm rejection, posture, writing position, hand, left-handed, right-handed, sensitivity")
        case language:
            list = String(localized: "handwriting, recognition, search, convert")
        case profile:
            list = String(localized: "author, name")
        case notifications:
            list = String(localized: "alerts, reminders, badges")
        default:
            return []
        }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - settings.open

/// `settings.open {page?, place?}`: opens Settings (at a page) or one of the app menu's places, so the menu, the
/// ⌘, shortcut, other features' "settings" links, plugins and the AI all take the same path.
enum SettingsOpen {
    static let id = "settings.open"

    struct Params: Codable {
        var page: String?
        var place: String?
    }

    struct Output: Codable {
        /// "settings", "panel" or "systemNotifications".
        var opened: String
        var page: String?
        var panel: String?
    }

    static let descriptor = CommandDescriptor(
        id: "settings.open", title: "Open Settings",
        summary: "Open Settings, optionally at a page id such as 'settings.editing', or an app-menu place: templates, cloudBackup, trash, about, systemNotifications.",
        params: .obj(["page": .str("settings page id, e.g. 'settings.editing', 'settings.stylus', 'settings.language'"),
                      "place": .str("app-menu place", choices: AppMenuPlace.allCases.map { $0.rawValue })]),
        examples: [[:], ["page": "settings.editing"], ["place": "about"]],
        effect: .session, target: .app)
}

/// One per app: builds the settings root and runs `settings.open`.
@MainActor
final class SettingsRouter {
    private weak var app: NibApp?
    /// The page the next root opens at. The shell's `showSettings(page:)` does not hand the page to the
    /// `settingsRoot` factory, so `settings.open` parks it here for `makeRoot` (contract gap).
    private var pendingPage: String?
    private weak var visibleRoot: SettingsRootViewController?

    init(app: NibApp) {
        self.app = app
    }

    func makeRoot(_ app: NibApp) -> UIViewController {
        let root = SettingsRootViewController(app: app, initialPage: pendingPage)
        pendingPage = nil
        visibleRoot = root
        return root
    }

    func open(_ p: SettingsOpen.Params, _ ctx: CommandContext) async throws -> SettingsOpen.Output {
        guard let app else { throw NibError.unavailable("Settings") }
        var page = p.page
        if let raw = p.place {
            guard let place = AppMenuPlace(rawValue: raw) else {
                throw NibError(.invalidParams, "unknown place '\(raw)'", path: "$.place",
                               hint: "one of: " + AppMenuPlace.allCases.map { $0.rawValue }.joined(separator: ", "))
            }
            switch place.resolve(panels: app.ui.panels.all, pages: app.ui.settingsPages.all) {
            case .panel(let id)?:
                _ = try await ctx.execute(CommandIDs.panelOpen, ["id": .string(id)])
                return SettingsOpen.Output(opened: "panel", page: nil, panel: id)
            case .systemNotifications?:
                try openSystemNotificationSettings()
                return SettingsOpen.Output(opened: "systemNotifications", page: nil, panel: nil)
            case .settings(let target)?:
                page = page ?? target
            case nil:
                throw NibError(.unavailable, "nothing in this build provides '\(raw)'",
                               hint: "the feature that provides it is disabled or not installed")
            }
        }
        if let id = page, app.ui.settingsPages.get(id) == nil {
            let known = app.ui.settingsPages.all.map { $0.id }.joined(separator: ", ")
            throw NibError(.notFound, "settings page '\(id)' not found", path: "$.page", hint: "known pages: \(known)")
        }
        if let root = visibleRoot, root.viewIfLoaded?.window != nil {
            if let id = page { root.show(page: id) }
            return SettingsOpen.Output(opened: "settings", page: page, panel: nil)
        }
        guard let navigator = app.ui.activeNavigator else { throw NibError.unavailable("an open Nib window") }
        pendingPage = page
        navigator.showSettings(page: page)
        pendingPage = nil
        return SettingsOpen.Output(opened: "settings", page: page, panel: nil)
    }

    private func openSystemNotificationSettings() throws {
        guard !NibApp.isHostlessTest, let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
            throw NibError.unavailable("the Settings app")
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

// MARK: - App menu (P-024)

/// Where `settings.open {place}` goes.
enum SettingsTarget: Equatable {
    /// Settings, at a page when given.
    case settings(String?)
    /// A panel another feature registered, opened with `panel.open`.
    case panel(String)
    /// The system Settings app's notification page for Nib.
    case systemNotifications
}

/// The app menu's places. Their screens belong to other features, found by the stable owner ids of
/// ARCHITECTURE.md §3 when the menu is shown, so a disabled feature simply hides its entry.
enum AppMenuPlace: String, CaseIterable {
    case settings, templates, cloudBackup, trash, about, systemNotifications

    func resolve(panels: [PanelDescriptor], pages: [SettingsPageDescriptor]) -> SettingsTarget? {
        switch self {
        case .settings:
            return .settings(nil)
        case .systemNotifications:
            return .systemNotifications
        case .templates:
            return Self.appPanel(owner: "templateui", panels)
                ?? Self.page(pages, where: { $0.owner == "templateui" })
        case .cloudBackup:
            return Self.appPanel(owner: "syncui", panels)
                ?? Self.page(pages, where: { $0.owner == "syncui" })
                ?? Self.page(pages, where: { $0.section == .sync })
        case .trash:
            let trash = panels.filter { $0.id.localizedCaseInsensitiveContains("trash") || $0.icon.hasPrefix("trash") }
            return (trash.first { $0.owner == "organize" } ?? trash.first).map { .panel($0.id) }
        case .about:
            return Self.page(pages, where: { $0.owner == "about" })
                ?? Self.page(pages, where: { $0.section == .about })
                ?? Self.appPanel(owner: "about", panels)
        }
    }

    /// A panel of `owner` that needs no open document (Change Template, for example, is per document).
    private static func appPanel(owner: String, _ panels: [PanelDescriptor]) -> SettingsTarget? {
        panels.first { $0.owner == owner && $0.docKinds == nil && $0.placement != .sidebarTab }.map { .panel($0.id) }
    }

    private static func page(_ pages: [SettingsPageDescriptor],
                             where match: (SettingsPageDescriptor) -> Bool) -> SettingsTarget? {
        pages.first(where: match).map { .settings($0.id) }
    }
}

enum AppMenu {
    static func items(owner: String) -> [MenuItemDescriptor] {
        [
            item(.settings, String(localized: "Settings"), icon: "gearshape", order: 100, owner: owner),
            item(.templates, String(localized: "Manage Templates"), icon: "doc.on.doc", order: 200, owner: owner),
            item(.cloudBackup, String(localized: "Cloud & Backup"), icon: "checkmark.icloud", order: 300, owner: owner),
            item(.trash, String(localized: "Trash"), icon: "trash", order: 400, owner: owner),
            item(.about, String(localized: "About Nib"), icon: "info.circle", order: 900, owner: owner),
        ]
    }

    private static func item(_ place: AppMenuPlace, _ title: String, icon: String, order: Int,
                             owner: String) -> MenuItemDescriptor {
        MenuItemDescriptor(
            id: "settings.menu." + place.rawValue, title: title, icon: icon, location: .appMenu, order: order,
            owner: owner, command: SettingsOpen.id,
            params: { _ -> JSONValue in
                if place == .settings { return [:] }
                return ["place": .string(place.rawValue)]
            },
            isVisible: { ctx in
                place.resolve(panels: ctx.app.ui.panels.all, pages: ctx.app.ui.settingsPages.all) != nil
            })
    }
}
