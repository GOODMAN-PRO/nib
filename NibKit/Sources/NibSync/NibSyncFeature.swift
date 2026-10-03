import Foundation
import NibContracts

/// F025 — Folder sync engine & library location.
///
/// - Folder sync (`FolderWatcher`): `NSFilePresenter`s on the library root and on every open package, a 30 s poll and
///   a check on every return to the foreground compare the stamps of OTHER devices' `doc.*.json` / `*.nibpage` files.
///   A changed open document merges `persistence.remoteChanges(doc)` through `bus.applyRemote(_, origin: "folder")`;
///   documents or folders added, moved or restyled elsewhere run `library.refresh()`. This device's own files are never
///   compared, so its writes never feed back. Every state change is a `sync.status` event (`SyncStatusPayload`,
///   source "sync"): checking, idle, downloading, warning (revisions more than 24 h ahead) and error, per document.
/// - iCloud: evicted items are asked to download while scanning, and `doc.open` / `window.open` wait (up to 30 s) until
///   the package is on the device before opening it.
/// - Library location: `library.chooseFolder` (system folder picker; a folder holding a `.nib-library` marker opens as
///   that library), `library.relocate` (coordinated copy, verified, then switch; `copy: false` also removes the old
///   one), `library.locations` / `library.switch` over the folders this device has used (device setting
///   `sync.locations.<id>`). A saved folder that stopped opening at launch (re-signed build, moved folder) is reopened
///   from its remembered bookmark, or the user is asked to pick it again.
public enum NibSyncFeature: NibFeature {
    public static let id = "sync"

    public static func register(_ app: NibApp) {
        KnownLocations.declare(app.settings, owner: id)
        app.services.set(FolderWatcher(app: app), for: FolderWatcher.serviceKey)
        SyncCommands.register(app.commands)
        app.bus.hooks.register(downloadBeforeOpening)
        LibraryMenu.register(app.ui.menus, owner: id)
    }

    public static func start(_ app: NibApp) async {
        guard let watcher = app.services.get(FolderWatcher.serviceKey, as: FolderWatcher.self) else { return }
        watcher.start()
        if !NibUITestMode.isEnabled { LibraryRecovery.begin(app) }
    }

    /// Before a document opens: its evicted iCloud items are downloaded first (the store would block reading them).
    static let downloadBeforeOpening = CommandHookDescriptor.guarding(
        id: "sync.downloadBeforeOpening", owner: id, commands: [CommandIDs.docOpen, CommandIDs.windowOpen], order: -100
    ) { _, params, ctx in
        guard let raw = params["doc"]?.stringValue, !raw.isEmpty,
              let watcher = ctx.services.get(FolderWatcher.serviceKey, as: FolderWatcher.self) else { return nil }
        guard await watcher.ensureDownloaded(NodeRef.documentID(from: raw)) else {
            throw NibError(.unavailable, "this document is still downloading from iCloud",
                           hint: "try again once it has downloaded")
        }
        return nil
    }
}

/// The app menu's "Library Folder" entries: Check for Changes, Choose Library Folder…, Move Library…, Copy Library
/// To… and one entry per known library folder (up to `slots`, checked when current) to switch between them.
enum LibraryMenu {
    static let slots = 8

    @MainActor
    static func register(_ menus: Registry<MenuItemDescriptor>, owner: String) {
        let group = String(localized: "Library Folder")
        menus.register(MenuItemDescriptor(id: "sync.menu.syncNow", title: String(localized: "Check for Changes"),
                                          icon: "arrow.triangle.2.circlepath", location: .appMenu, order: 310,
                                          owner: owner, command: CommandIDs.syncNow, submenu: group))
        menus.register(MenuItemDescriptor(id: "sync.menu.chooseFolder", title: String(localized: "Choose Library Folder…"),
                                          icon: "folder", location: .appMenu, order: 311, owner: owner,
                                          command: CommandIDs.libraryChooseFolder, submenu: group))
        menus.register(MenuItemDescriptor(id: "sync.menu.move", title: String(localized: "Move Library…"),
                                          icon: "folder.badge.gearshape", location: .appMenu, order: 312, owner: owner,
                                          command: CommandIDs.libraryRelocate, params: { _ in ["copy": false] },
                                          submenu: group))
        menus.register(MenuItemDescriptor(id: "sync.menu.copy", title: String(localized: "Copy Library To…"),
                                          icon: "doc.on.doc", location: .appMenu, order: 313, owner: owner,
                                          command: CommandIDs.libraryRelocate, params: { _ in ["copy": true] },
                                          submenu: group))
        let switchGroup = String(localized: "Switch Library")
        for slot in 0..<slots {
            var item = MenuItemDescriptor(
                id: "sync.menu.location.\(slot)", title: String(localized: "Library"), icon: "books.vertical",
                location: .appMenu, order: 320 + slot, owner: owner, command: CommandIDs.librarySwitch,
                params: { ctx in ["location": .string(location(slot, ctx.app)?.id ?? "")] },
                isVisible: { ctx in
                    let all = locations(ctx.app)
                    return all.count > 1 && slot < all.count
                },
                submenu: switchGroup)
            item.contextTitle = { ctx in location(slot, ctx.app)?.name ?? String(localized: "Library") }
            item.isChecked = { ctx in
                guard let root = ctx.app.services.library?.rootURL, let l = location(slot, ctx.app) else { return false }
                return KnownLocations.matches(l, root)
            }
            menus.register(item)
        }
    }

    /// Known library folders in a stable menu order (by name).
    @MainActor
    static func locations(_ app: NibApp) -> [KnownLocation] {
        let cache: LocationMenuCache
        if let stored = app.services.get(LocationMenuCache.serviceKey, as: LocationMenuCache.self) {
            cache = stored
        } else {
            cache = LocationMenuCache(settings: app.settings)
            app.services.set(cache, for: LocationMenuCache.serviceKey)
        }
        return cache.locations(app)
    }

    @MainActor
    static func location(_ slot: Int, _ app: NibApp) -> KnownLocation? {
        let all = locations(app)
        return slot < all.count ? all[slot] : nil
    }
}

/// Menu closures share the decoded, sorted settings until a location setting or the root changes.
@MainActor
final class LocationMenuCache {
    static let serviceKey = "sync.locationMenuCache"
    private var cached: [KnownLocation]?
    private var root: URL?
    private var observer: NSObjectProtocol?

    init(settings: SettingsStore) {
        observer = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: settings,
                                                          queue: .main) { [weak self] notification in
            guard let name = notification.userInfo?["name"] as? String, name.hasPrefix(KnownLocations.prefix) else { return }
            FolderWatcher.onMain { self?.cached = nil }
        }
    }

    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }

    func locations(_ app: NibApp) -> [KnownLocation] {
        if root != app.services.library?.rootURL { cached = nil }
        root = app.services.library?.rootURL
        if let cached = cached { return cached }
        let list = KnownLocations.listed(app.settings, library: app.services.library).sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        cached = list
        return list
    }
}
