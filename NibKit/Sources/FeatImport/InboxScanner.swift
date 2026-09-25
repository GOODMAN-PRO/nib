import Foundation
import UIKit
import UniformTypeIdentifiers
import NibContracts

// MARK: - Locations

/// Where files arrive from outside Nib. Pure and thread-safe.
enum ImportLocations {
    /// Per-import scratch folders (staging, unzip, conversions, drops).
    static var scratch: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NibImport", isDirectory: true)
    }

    /// "On My iPad › Nib": Finder / file-sharing transfers and "Save to Files" land at its top level.
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Copies iOS makes for "Open in Nib" when the file cannot be opened in place.
    static var openInInbox: URL { documents.appendingPathComponent("Inbox", isDirectory: true) }

    /// The share extension's inbox in the App Group container, when the sideloading tool provides a group.
    static var appGroupInbox: URL? {
        AppGroup.containerURL?.appendingPathComponent(ShareHandoff.inboxFolder, isDirectory: true)
    }

    static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let d = canonical(dir)
        return canonical(url).hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    /// Inside this app's own container or its App Group (no import-in-place bookmark for those).
    static func isInsideApp(_ url: URL) -> Bool {
        if isInside(url, URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) { return true }
        if isInside(url, FileManager.default.temporaryDirectory) { return true }
        if let group = AppGroup.containerURL, isInside(url, group) { return true }
        return false
    }

    /// Open In copies and share-extension files: Nib's to delete once imported or declined.
    static func isInConsumableInbox(_ url: URL) -> Bool {
        if isInside(url, openInInbox) { return true }
        if let inbox = appGroupInbox, isInside(url, inbox) { return true }
        return false
    }
}

// MARK: - Share extension hand-off

/// How NibShare (NibShare/ShareViewController.swift, which cannot import NibKit: keep both in step) hands items over.
/// With an App Group it writes files into `<group>/Inbox/` (hidden while being written, then renamed). Without one
/// it puts each item on the pasteboard as a name plus its bytes and opens `nib://import?from=pasteboard`, which F074
/// routes to `import.files`.
enum ShareHandoff {
    static let link = "nib://import?from=pasteboard"
    static let nameType = "app.nib.share.name"
    static let dataType = "app.nib.share.data"
    static let inboxFolder = "Inbox"

    static func isHandoffLink(_ string: String) -> Bool {
        guard let c = URLComponents(string: string), c.scheme?.lowercased() == NibFormat.urlScheme,
              c.host?.lowercased() == "import" else { return false }
        return c.queryItems?.contains { $0.name == "from" && $0.value == "pasteboard" } ?? false
    }

    /// True while NibShare's items wait on the pasteboard (checking types never shows the paste prompt).
    @MainActor
    static var isWaiting: Bool { UIPasteboard.general.contains(pasteboardTypes: [dataType]) }

    /// Writes the waiting items into `dir` and clears them from the pasteboard.
    @MainActor
    static func take(into dir: URL) throws -> [URL] {
        let board = UIPasteboard.general
        guard board.contains(pasteboardTypes: [dataType]) else {
            throw NibError(.notFound, "nothing shared with Nib is waiting on the pasteboard",
                           hint: "share the item to Nib again")
        }
        let urls = try write(board.items, into: dir)
        guard !urls.isEmpty else {
            throw NibError(.userDenied, "Nib couldn't read what was shared",
                           hint: "share it again and allow pasting when iOS asks")
        }
        board.items = []
        return urls
    }

    /// Writes every hand-off item (name + bytes) into `dir`; other pasteboard items are ignored.
    static func write(_ items: [[String: Any]], into dir: URL) throws -> [URL] {
        var out: [URL] = []
        for item in items {
            guard let data = item[dataType] as? Data else { continue }
            let name = (item[nameType] as? Data).map { String(decoding: $0, as: UTF8.self) }
                ?? (item[nameType] as? String) ?? ""
            let url = ImportNaming.unique(ImportNaming.sanitize(name), in: dir)
            try data.write(to: url, options: .atomic)
            out.append(url)
        }
        return out
    }
}

// MARK: - Inbox scan

/// Files waiting to be imported. Pure apart from reading directories.
enum InboxFiles {
    struct Entry: Equatable {
        var url: URL
        var isDirectory: Bool
        /// From Documents/Inbox or the App Group inbox (shared to Nib), not a loose Documents file.
        var fromInbox: Bool
        /// Path, size and modification date: a declined file is offered again only once it changes.
        var key: String
    }

    /// Everything in the inboxes, plus loose files (never folders: the library may live here) in Documents.
    static func entries(inboxes: [URL], documents: URL) -> [Entry] {
        var out: [Entry] = []
        for inbox in inboxes {
            for e in ArchiveIO.visibleEntries(of: inbox) {
                out.append(Entry(url: e.url, isDirectory: e.isDirectory, fromInbox: true, key: key(e.url)))
            }
        }
        for e in ArchiveIO.visibleEntries(of: documents) where !e.isDirectory {
            out.append(Entry(url: e.url, isDirectory: false, fromInbox: false, key: key(e.url)))
        }
        return out
    }

    static func key(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(Int(modified))"
    }
}

/// On every window activation: offers what arrived while Nib was away ("Import N files?"): Open In copies left in
/// Documents/Inbox, NibShare's App Group inbox or pasteboard hand-off, and files put into "On My iPad › Nib" with
/// Finder, iTunes File Sharing, AirDrop or "Save to Files". The prompt is the import dialog; Cancel means "not now"
/// (a declined loose file is not offered again until it changes or Nib relaunches).
@MainActor
enum InboxScanner {
    private static var observer: NSObjectProtocol?
    private static var busy = false
    private static var declined = Set<String>()

    static func start(_ app: NibApp) {
        guard !NibApp.isHostlessTest, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                          queue: .main) { [weak app] note in
            let scene = note.object as? UIWindowScene
            Task { @MainActor in
                guard let app = app else { return }
                if let scene = scene { ImportDropTarget.install(on: scene, app: app) }
                await scan(app)
            }
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
            where scene.activationState == .foregroundActive {
            ImportDropTarget.install(on: scene, app: app)
        }
        Task { @MainActor in await scan(app) }
    }

    static func scan(_ app: NibApp) async {
        guard !busy, app.services.library != nil, let nav = app.ui.activeNavigator,
              let root = nav.rootViewController, root.view.window != nil, root.presentedViewController == nil else { return }
        busy = true
        defer { busy = false }
        if ShareHandoff.isWaiting {
            await runImport([ShareHandoff.link], app: app, session: nav.session)
            return
        }
        let inboxes = [ImportLocations.openInInbox] + [ImportLocations.appGroupInbox].compactMap { $0 }
        let documents = ImportLocations.documents
        let found = await Task.detached(priority: .utility) { InboxFiles.entries(inboxes: inboxes, documents: documents) }.value
        let offered = found.filter { entry in
            guard !ImportEngine.inFlight.contains(entry.url.standardizedFileURL.path), !declined.contains(entry.key) else {
                return false
            }
            if entry.fromInbox && entry.isDirectory { return true }        // a folder someone shared: its tree is imported
            return ImportEngine.canImport(entry.url, isDirectory: entry.isDirectory, app: app)
        }
        guard !offered.isEmpty else { return }
        let loose = offered.filter { !$0.fromInbox }
        let paths = loose.map { $0.url.standardizedFileURL.path }
        ImportEngine.consumableFiles.formUnion(paths)
        let result = await runImport(offered.map { $0.url.absoluteString }, app: app, session: nav.session)
        if result?["cancelled"]?.boolValue == true || result == nil {
            declined.formUnion(loose.map { $0.key })
        }
        ImportEngine.consumableFiles.subtract(paths)
    }

    @discardableResult
    private static func runImport(_ urls: [String], app: NibApp, session: EditorSession) async -> JSONValue? {
        do {
            let params: JSONValue = ["urls": .array(urls.map { .string($0) })]
            return try await app.bus.execute(Invocation(command: CommandIDs.importFiles, params: params,
                                                        principal: .user, session: session)).value
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": CommandIDs.importFiles, "error": NibError.wrap(error)])
            return nil
        }
    }
}

// MARK: - Drag and drop from other apps

/// How a dropped item is read.
enum DropPlan: Equatable {
    /// A file (or folder) of this type identifier.
    case file(String)
    /// A web address (Safari's address bar, links): imported as the page.
    case webLink
}

enum DropLoader {
    /// Nib's own drags (clipboard fragments, sidebar pages) belong to the canvas and the page sidebar.
    static let ownTypes: Set<String> = ["app.nib.fragment", "app.nib.pages"]

    @MainActor
    static func plan(for provider: NSItemProvider, app: NibApp) -> DropPlan? {
        let ids = provider.registeredTypeIdentifiers
        if ids.contains(where: { ownTypes.contains($0) }) { return nil }
        for id in ids {
            guard let type = UTType(id) else { continue }
            if type.conforms(to: .directory) { return .file(id) }
            if let ext = type.preferredFilenameExtension, app.content.importer(forExtension: ext) != nil { return .file(id) }
            if ImportEngine.importer(conformingTo: type, app: app) != nil { return .file(id) }
        }
        if ids.contains(UTType.url.identifier), !ids.contains(UTType.fileURL.identifier) { return .webLink }
        return nil
    }

    /// Copies the dropped item into `dir` (the provider deletes its own copy when the handler returns).
    static func load(_ provider: NSItemProvider, plan: DropPlan, into dir: URL) async -> URL? {
        switch plan {
        case .file(let typeID):
            let suggested = provider.suggestedName
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    guard let url = url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let name = fileName(suggested: suggested, fallback: url.lastPathComponent, type: typeID)
                    let dest = ImportNaming.unique(name, in: dir)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        case .webLink:
            let link: URL? = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: (object as? NSURL).map { $0 as URL })
                }
            }
            guard let page = link, let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                return nil
            }
            let title = provider.suggestedName ?? page.host ?? String(localized: "Web page")
            return try? WebLocation.write(page, title: title, in: dir)
        }
    }

    /// The suggested name with an extension (from the delivered file, else the type), made safe for a path.
    static func fileName(suggested: String?, fallback: String, type: String) -> String {
        var name = (suggested?.isEmpty == false ? suggested : nil) ?? fallback
        if (name as NSString).pathExtension.isEmpty {
            let delivered = (fallback as NSString).pathExtension
            let ext = delivered.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "") : delivered
            if !ext.isEmpty { name += "." + ext }
        }
        return ImportNaming.sanitize(name)
    }
}

/// A window-level drop target: files, folders and web links dragged from other apps onto the library or the page
/// sidebar are imported (the dialog asks where). The canvas (F014) and the library's own drops claim theirs first,
/// because UIKit offers a drop to the deepest view that accepts it.
@MainActor
final class ImportDropTarget: NSObject, UIDropInteractionDelegate {
    private static var installed: [ImportDropTarget] = []
    private weak var app: NibApp?
    private weak var window: UIWindow?

    private init(app: NibApp, window: UIWindow) {
        self.app = app
        self.window = window
        super.init()
    }

    static func install(on scene: UIWindowScene, app: NibApp) {
        installed.removeAll { $0.window == nil }
        for window in scene.windows where window.rootViewController is SceneNavigator {
            guard !installed.contains(where: { $0.window === window }) else { continue }
            let target = ImportDropTarget(app: app, window: window)
            window.addInteraction(UIDropInteraction(delegate: target))
            installed.append(target)
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        guard session.localDragSession == nil, let app = app else { return false }
        return session.items.contains { DropLoader.plan(for: $0.itemProvider, app: app) != nil }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let app = app else { return }
        let providers = session.items.map { $0.itemProvider }
        let editor = (window?.rootViewController as? SceneNavigator)?.session ?? app.services.sessions.active
        Task { @MainActor in await ImportDropTarget.importDrop(providers, app: app, session: editor) }
    }

    static func importDrop(_ providers: [NSItemProvider], app: NibApp, session: EditorSession?) async {
        let dir = ImportLocations.scratch.appendingPathComponent("drop-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [JSONValue] = []
        for provider in providers {
            guard let plan = DropLoader.plan(for: provider, app: app),
                  let url = await DropLoader.load(provider, plan: plan, into: dir) else { continue }
            urls.append(.string(url.absoluteString))
        }
        guard !urls.isEmpty else { return }
        do {
            _ = try await app.bus.execute(Invocation(command: CommandIDs.importFiles, params: ["urls": .array(urls)],
                                                     principal: .user, session: session))
        } catch {
            NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                            userInfo: ["command": CommandIDs.importFiles, "error": NibError.wrap(error)])
        }
    }
}
