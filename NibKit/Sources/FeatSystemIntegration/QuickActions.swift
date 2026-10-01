import Foundation
import UIKit
import WidgetKit
import NibContracts
import NibDesign

// MARK: - Types

/// Home Screen quick action types. QuickNote is the static item in Info.plist (`UIApplicationShortcutItems`, so it is
/// there before the first launch); favourites are dynamic items whose type carries the document id, because the shell
/// hands `app.quickAction` only the type.
enum QuickActionTypes {
    static let quickNote = "app.nib.quicknote"
    static let openPrefix = "app.nib.open."

    static func open(_ doc: DocumentID) -> String { openPrefix + doc.raw }

    /// The link a quick action follows.
    static func link(for type: String) throws -> DeepLink {
        let t = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == quickNote { return .quickNote }
        if t.hasPrefix(openPrefix) {
            let id = String(t.dropFirst(openPrefix.count))
            guard NibID.isValid(id) else {
                throw NibError(.invalidParams, "'\(id)' is not a document id", path: "$.type",
                               hint: "use \(openPrefix)<document id> with an id from library.list")
            }
            return .open(doc: NibID(id), page: nil, comment: nil)
        }
        throw NibError(.invalidParams, "unknown quick action '\(String(t.prefix(80)))'", path: "$.type",
                       hint: "quick actions: \(quickNote) or \(openPrefix)<document id>")
    }
}

/// One Home Screen quick action, as plain values (tests compare these; `shortcutItem` builds the UIKit object).
struct QuickActionItem: Equatable {
    var type: String
    var title: String
    var subtitle: String?
    var symbol: NibSymbol
    var doc: DocumentID?
}

enum QuickActions {
    /// Home Screen shows the static QuickNote plus at most this many favourites.
    static let maxFavourites = 4

    /// Favourite documents, most recently modified first (ties by title, then id, so the order is stable).
    static func favourites(_ nodes: [LibraryNode], limit: Int) -> [LibraryNode] {
        let docs = nodes.filter { $0.kind == .document && $0.favorite && $0.trashedAt == nil }
        let sorted = docs.sorted { a, b in
            if a.modified != b.modified { return a.modified > b.modified }
            let order = a.title.localizedStandardCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
            return a.id < b.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// The dynamic items for `favourites`: title, its folder as the subtitle, the kind's glyph.
    static func items(for favourites: [LibraryNode], folderTitle: (FolderID) -> String?) -> [QuickActionItem] {
        favourites.map { node in
            QuickActionItem(type: QuickActionTypes.open(node.id), title: displayTitle(node.title),
                            subtitle: node.parent.flatMap(folderTitle), symbol: symbol(for: node.documentKind),
                            doc: node.id)
        }
    }

    static func symbol(for kind: DocumentKind?) -> NibSymbol {
        switch kind ?? .notebook {
        case .notebook: return .notebook
        case .whiteboard: return .whiteboard
        case .textDocument: return .textDocument
        case .studySet: return .studySets
        }
    }

    static func displayTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Untitled") : t
    }

    static func shortcutItem(_ item: QuickActionItem) -> UIApplicationShortcutItem {
        var info: [String: NSSecureCoding] = [:]
        if let doc = item.doc { info["doc"] = doc.raw as NSString }
        return UIApplicationShortcutItem(type: item.type, localizedTitle: item.title, localizedSubtitle: item.subtitle,
                                         icon: UIApplicationShortcutIcon(systemImageName: item.symbol.name),
                                         userInfo: info.isEmpty ? nil : info)
    }
}

// MARK: - favourites.json (App Group, for the Favourites widget F096)

/// The favourites file the widget reads when the sideloading tool provides an App Group: `<group>/favourites.json`,
/// `{version, updated, favourites: [{id, title, kind, folder?, modified, url}]}`, most recently modified first. `url` is
/// the nib://open link a widget tap opens.
enum FavouritesFile {
    static let name = "favourites.json"
    static let version = 1
    /// More than any widget family shows; a large widget picks the first ones.
    static let limit = 24

    struct Entry: Codable, Equatable {
        var id: String
        var title: String
        var kind: String
        var folder: String?
        var modified: Double
        var url: String

        /// What a widget shows of the entry: everything but `modified`, which changes on every save.
        func sameListing(as other: Entry) -> Bool {
            id == other.id && title == other.title && kind == other.kind && folder == other.folder && url == other.url
        }
    }

    /// True when `new` lists the same favourites as `old` in the same order with the same titles, kinds, folders and
    /// links: saving a favourite (only `modified` moves) is then not worth a write and a widget reload.
    static func sameListing(_ old: [Entry]?, _ new: [Entry]) -> Bool {
        guard let old, old.count == new.count else { return false }
        return zip(old, new).allSatisfy { $0.sameListing(as: $1) }
    }

    struct Snapshot: Codable, Equatable {
        var version: Int
        var updated: Double
        var favourites: [Entry]
    }

    static func entries(_ favourites: [LibraryNode], folderTitle: (FolderID) -> String?) -> [Entry] {
        favourites.map { node in
            Entry(id: node.id.raw, title: QuickActions.displayTitle(node.title),
                  kind: (node.documentKind ?? .notebook).rawValue, folder: node.parent.flatMap(folderTitle),
                  modified: node.modified, url: DeepLink.open(doc: node.id, page: nil, comment: nil).string)
        }
    }

    static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(snapshot)
    }
}

/// Writes favourites.json off the main actor (one serial queue), atomically, finishing in the background if Nib is
/// being suspended.
final class FavouritesWriter {
    private let queue = DispatchQueue(label: "app.nib.system.favourites", qos: .utility)

    @MainActor
    func write(_ data: Data, to url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        let task: UIBackgroundTaskIdentifier = NibApp.isHostlessTest
            ? .invalid : UIApplication.shared.beginBackgroundTask(withName: "app.nib.favourites")
        queue.async {
            var ok = true
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                ok = false
                SystemLog.log.error("favourites.json not written: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                completion(ok)
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    /// Waits for queued writes (tests).
    func flush() { queue.sync {} }
}

// MARK: - Publishing

/// Keeps the Home Screen quick actions and favourites.json in step with the library's favourites: at start, whenever
/// Nib goes to the background (the spec's refresh point: what the Home Screen shows next), and shortly after library
/// changes (so a crash or a kill never leaves stale items for long).
@MainActor
final class QuickActionPublisher {
    private weak var app: NibApp?
    /// Sets `UIApplication.shortcutItems`. Replaced in tests (hostless tests have no UIApplication).
    var applyShortcutItems: @MainActor ([UIApplicationShortcutItem]) -> Void = { items in
        guard !NibApp.isHostlessTest else { return }
        UIApplication.shared.shortcutItems = items
    }
    /// The App Group container (nil without one: the favourites stay quick actions only). Replaced in tests.
    var containerURL: @MainActor () -> URL? = { AppGroup.containerURL }
    /// Asks WidgetKit to reload after favourites.json changed. Replaced in tests.
    var reloadWidgets: @MainActor () -> Void = {
        guard !NibApp.isHostlessTest else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
    let writer = FavouritesWriter()
    /// Debounce for library changes (sync can emit many in a row).
    var debounce: UInt64 = 1_500_000_000

    private(set) var items: [QuickActionItem] = []
    private(set) var entries: [FavouritesFile.Entry]?
    private var applied = false
    private var observers: [NSObjectProtocol] = []
    private var subscription: EventSubscription?
    private var pending: Task<Void, Never>?

    init(app: NibApp) {
        self.app = app
    }

    func start() {
        guard observers.isEmpty, let app else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        subscription = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        subscription?.cancel()
        subscription = nil
        pending?.cancel()
        pending = nil
    }

    func scheduleRefresh() {
        pending?.cancel()
        let delay = debounce
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Recomputes both from the library catalog. Cheap: a filter and a sort over the cached catalog, and UIKit or the
    /// file are only touched when something changed.
    func refresh() {
        guard let app, let library = app.services.library else { return }
        let nodes = library.allNodes()
        let folderTitle: (FolderID) -> String? = { id in
            guard let n = library.node(id), n.kind == .folder else { return nil }
            return n.title
        }
        let newItems = QuickActions.items(for: QuickActions.favourites(nodes, limit: QuickActions.maxFavourites),
                                          folderTitle: folderTitle)
        if !applied || newItems != items {
            items = newItems
            applied = true
            applyShortcutItems(newItems.map(QuickActions.shortcutItem))
        }
        guard let container = containerURL() else { return }
        let newEntries = FavouritesFile.entries(QuickActions.favourites(nodes, limit: FavouritesFile.limit),
                                                folderTitle: folderTitle)
        guard !FavouritesFile.sameListing(entries, newEntries) else { return }
        let snapshot = FavouritesFile.Snapshot(version: FavouritesFile.version, updated: Date().timeIntervalSince1970,
                                               favourites: newEntries)
        guard let data = try? FavouritesFile.encode(snapshot) else { return }
        entries = newEntries
        writer.write(data, to: container.appendingPathComponent(FavouritesFile.name)) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.reloadWidgets()
            } else {
                self.entries = nil     // try again next time
            }
        }
    }
}
