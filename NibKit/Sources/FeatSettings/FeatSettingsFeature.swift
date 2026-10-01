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
        let router = SettingsRouter()
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
            id: CommandIDs.settingsOpen, title: String(localized: "Settings"), shortcut: AppMenu.settingsShortcut,
            command: CommandIDs.settingsOpen, scope: .global, order: 100, owner: id))
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

    /// Each page carries the extra words settings search matches (`SettingsPageDescriptor.keywords`, contracts-v2),
    /// so a search for "palm" finds Stylus & Palm Rejection the way another feature's "iCloud" finds its page.
    static func descriptors(owner: String) -> [SettingsPageDescriptor] {
        [
            page(profile, String(localized: "Profile"), .profile, .general, order: 10, owner: owner,
                 keywords: String(localized: "author, name")) { AnyView(ProfilePage(app: $0)) },
            page(language, String(localized: "Language"), .language, .general, order: 300, owner: owner,
                 keywords: String(localized: "handwriting, recognition, search, convert")) { AnyView(LanguagePage(app: $0)) },
            page(notifications, String(localized: "Notifications"), .notifications, .general, order: 800, owner: owner,
                 keywords: String(localized: "alerts, reminders, badges")) { AnyView(NotificationsPage(app: $0)) },
            page(editing, String(localized: "Document Editing"), .textDocument, .editing, order: 10, owner: owner,
                 keywords: String(localized: "scroll, scrolling direction, vertical, horizontal, tabs, undo, redo, toolbar, layout, left, right, select, selection, tap, align, alignment, guides, snap, grid, status bar, zoom window, auto advance, sidebar")) {
                AnyView(DocumentEditingPage(app: $0))
            },
            page(stylus, String(localized: "Stylus & Palm Rejection"), .pen, .stylus, order: 10, owner: owner,
                 keywords: String(localized: "Apple Pencil, pencil, stylus, any input, mouse, finger, fingers, finger drawing, palm, palm rejection, posture, writing position, hand, left-handed, right-handed, sensitivity")) {
                AnyView(StylusPage(app: $0))
            },
        ]
    }

    /// Search words from one translated, comma-separated string (one string, so translators see them together).
    static func keywordList(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func page(_ id: String, _ title: String, _ symbol: NibSymbol, _ section: SettingsSection, order: Int,
                             owner: String, keywords: String,
                             view: @escaping @MainActor (NibApp) -> AnyView) -> SettingsPageDescriptor {
        var page = SettingsPageDescriptor(id: id, title: title, icon: symbol.name, section: section, order: order,
                                          owner: owner, makeView: view)
        page.keywords = keywordList(keywords)
        return page
    }
}

// MARK: - settings.open

/// `settings.open {page?, place?}` (`CommandIDs.settingsOpen`): opens Settings (at a page) or one of the app menu's
/// places, so the menu, the ⌘, shortcut, other features' "settings" links, plugins and the AI all take the same path.
enum SettingsOpen {
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

    /// The id is spelled out (it equals `CommandIDs.settingsOpen`) so `Scripts/lint.py` sees the owned command.
    static let descriptor = CommandDescriptor(
        id: "settings.open", title: "Open Settings",
        summary: "Open Settings, optionally at a page id such as 'settings.editing', or an app-menu place: templates, cloudBackup, trash, about (their panels open with panel.open), systemNotifications.",
        params: .obj(["page": .str("settings page id, e.g. 'settings.editing', 'settings.stylus', 'settings.language'"),
                      "place": .str("app-menu place", choices: AppMenuPlace.allCases.map { $0.rawValue })]),
        examples: [[:], ["page": "settings.editing"], ["place": "about"]],
        effect: .session, target: .app)
}

/// One per app: builds the settings root and runs `settings.open`.
@MainActor
final class SettingsRouter {
    /// The page the next root opens at. The shell's `showSettings(page:)` does not hand the page to the
    /// `settingsRoot` factory (still deferred for the shell in contracts-v2.2), so `settings.open` parks it here
    /// for `makeRoot`.
    private var pendingPage: String?
    private weak var visibleRoot: SettingsRootViewController?

    func makeRoot(_ app: NibApp) -> UIViewController {
        let root = SettingsRootViewController(app: app, initialPage: pendingPage)
        pendingPage = nil
        visibleRoot = root
        return root
    }

    func open(_ p: SettingsOpen.Params, _ ctx: CommandContext) async throws -> SettingsOpen.Output {
        guard let ui = ctx.ui else { throw NibError.unavailable("Settings") }
        if let raw = p.place {
            guard let place = AppMenuPlace(rawValue: raw) else {
                throw NibError(.invalidParams, "unknown place '\(raw)'", path: "$.place",
                               hint: "one of: " + AppMenuPlace.allCases.map { $0.rawValue }.joined(separator: ", "))
            }
            switch place.target {
            case .settings:
                break
            case .systemNotifications:
                try openSystemNotificationSettings()
                return SettingsOpen.Output(opened: "systemNotifications", page: nil, panel: nil)
            case .panel(let id):
                guard let panel = ui.panels.get(id) else {
                    throw NibError(.unavailable, "nothing in this build provides '\(raw)'",
                                   hint: "the feature that registers panel '\(id)' is disabled or not installed")
                }
                try await openPanel(panel, ctx)
                return SettingsOpen.Output(opened: "panel", page: nil, panel: id)
            }
        }
        let page = p.page
        if let id = page, ui.settingsPages.get(id) == nil {
            let known = ui.settingsPages.all.map { $0.id }.joined(separator: ", ")
            throw NibError(.notFound, "settings page '\(id)' not found", path: "$.page", hint: "known pages: \(known)")
        }
        if let root = visibleRoot, root.viewIfLoaded?.window != nil {
            if let id = page { root.show(page: id) }
            return SettingsOpen.Output(opened: "settings", page: page, panel: nil)
        }
        guard let navigator = ctx.navigator else { throw NibError.unavailable("an open Nib window") }
        pendingPage = page
        navigator.showSettings(page: page)
        pendingPage = nil
        return SettingsOpen.Output(opened: "settings", page: page, panel: nil)
    }

    /// Spec pass 2: a place's panel opens through `panel.open` (F017), which in a window without a document hands it to
    /// the library (F019 presents it over itself, or selects the Trash tab in its sidebar). Nothing is presented here.
    /// A library tab has no place in a document, so from one the window goes back to the library first.
    private func openPanel(_ panel: PanelDescriptor, _ ctx: CommandContext) async throws {
        if panel.placement == .libraryTab, ctx.activeSession?.document != nil {
            _ = try await ctx.execute(CommandIDs.windowShowLibrary)
        }
        _ = try await ctx.execute(CommandIDs.panelOpen, ["id": .string(panel.id)])
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
    /// Settings itself.
    case settings
    /// A panel another feature registers under a well-known id, opened with `panel.open`.
    case panel(String)
    /// The system Settings app's notification page for Nib.
    case systemNotifications
}

/// The app menu's places. Their screens belong to other features, which register them under the well-known
/// `PanelIDs` (contracts-v2 G18): Manage Templates (F045), Cloud & Backup (F070), Trash (F020) and About (F098).
enum AppMenuPlace: String, CaseIterable {
    case settings, templates, cloudBackup, trash, about, systemNotifications

    var target: SettingsTarget {
        switch self {
        case .settings: return .settings
        case .systemNotifications: return .systemNotifications
        case .templates: return .panel(PanelIDs.templates)
        case .cloudBackup: return .panel(PanelIDs.cloudBackup)
        case .trash: return .panel(PanelIDs.trash)
        case .about: return .panel(PanelIDs.about)
        }
    }

    /// Whether this build can open the place: its owner registered the panel and `panel.open` is installed. A place
    /// whose feature is disabled simply hides its menu entry.
    @MainActor
    func isAvailable(in app: NibApp) -> Bool {
        guard case .panel(let id) = target else { return true }
        return app.ui.panels.get(id) != nil && app.commands.entry(CommandIDs.panelOpen) != nil
    }
}

enum AppMenu {
    /// ⌘, opens Settings (the key command) and is shown beside the menu entry.
    static var settingsShortcut: KeyShortcut { KeyShortcut(",", [.command]) }

    static func items(owner: String) -> [MenuItemDescriptor] {
        var settings = item(.settings, String(localized: "Settings"), symbol: .settings, order: 100, owner: owner)
        settings.shortcut = settingsShortcut
        return [
            settings,
            item(.templates, String(localized: "Manage Templates"), symbol: .templates, order: 200, owner: owner),
            item(.cloudBackup, String(localized: "Cloud & Backup"), symbol: .syncDone, order: 300, owner: owner),
            item(.trash, String(localized: "Trash"), symbol: .trash, order: 400, owner: owner),
            item(.about, String(localized: "About Nib"), symbol: .info, order: 900, owner: owner),
        ]
    }

    private static func item(_ place: AppMenuPlace, _ title: String, symbol: NibSymbol, order: Int,
                             owner: String) -> MenuItemDescriptor {
        MenuItemDescriptor(
            id: "settings.menu." + place.rawValue, title: title, icon: symbol.name, location: .appMenu, order: order,
            owner: owner, command: CommandIDs.settingsOpen,
            params: { _ -> JSONValue in
                if place == .settings { return [:] }
                return ["place": .string(place.rawValue)]
            },
            isVisible: { ctx in place.isAvailable(in: ctx.app) })
    }
}
