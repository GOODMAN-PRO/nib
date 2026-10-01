import Foundation
import NibContracts

/// F002 — Library store. Installs the folder library as `services.library` (folders, `.nibnote` documents, the Trash,
/// a catalog cached in Application Support and kept in `services.packages`), the library prefs as
/// `settings.syncedBackend`, and the library commands (doc.create, doc.setFavorite, doc.merge, folder.*, library.list /
/// rename / move / duplicate / trash, trash.*). `services.get("library.inContainer", as: NSNumber.self)` tells the sync
/// UI (F070) and onboarding (F093) whether the library folder lives inside the app container.
public enum NibLibraryFeature: NibFeature {
    public static let id = "library"

    /// Optional service for callers that only depend on NibContracts. The Bool is true only after a full scan and
    /// successful cache write; false means the active library is not this feature's folder library.
    public typealias CatalogRebuild = @MainActor () async throws -> Bool
    public static let catalogRebuildKey = "library.rebuildCatalog"

    /// Re-reads package heads and folder records, updates package locations, and awaits catalogue persistence.
    /// Package contents and document undo history are preserved. Cache I/O failures propagate to the caller.
    public static func rebuildCatalog(_ app: NibApp) async throws -> Bool {
        guard let library = app.services.library as? FolderLibrary else { return false }
        do { try await library.rebuildCatalog() }
        catch { throw NibError.wrap(error) }
        return true
    }

    public static func register(_ app: NibApp) {
        LibrarySettings.declare(app.settings, owner: id)
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let library = FolderLibrary(settings: app.settings, clock: app.clock, events: app.events,
                                    locator: app.services.packages, workspace: app.workspace, bus: app.bus, services: app.services,
                                    cacheDirectory: support.appendingPathComponent("Nib/library", isDirectory: true),
                                    defaultRoot: documents)
        app.services.library = library
        let rebuild: CatalogRebuild = { [weak app] in
            guard let app else { throw NibError.unavailable("the library") }
            return try await rebuildCatalog(app)
        }
        app.services.set(rebuild as AnyObject, for: catalogRebuildKey)
        app.settings.syncedBackend = library.prefs
        LibraryCommands.register(app.commands)
    }

    public static func start(_ app: NibApp) async {
        guard let library = app.services.library as? FolderLibrary else { return }
        await library.start()
    }
}
