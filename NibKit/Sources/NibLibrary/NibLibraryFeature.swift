import Foundation
import NibContracts

/// F002 — Library store. Installs the folder library as `services.library` (folders, `.nibnote` documents, the Trash,
/// a catalog cached in Application Support and kept in `services.packages`), the library prefs as
/// `settings.syncedBackend`, and the library commands (doc.create, doc.setFavorite, doc.merge, folder.*, library.list /
/// rename / move / duplicate / trash, trash.*). `services.get("library.inContainer", as: NSNumber.self)` tells the sync
/// UI (F070) and onboarding (F093) whether the library folder lives inside the app container.
public enum NibLibraryFeature: NibFeature {
    public static let id = "library"

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
        app.settings.syncedBackend = library.prefs
        LibraryCommands.register(app.commands)
    }

    public static func start(_ app: NibApp) async {
        guard let library = app.services.library as? FolderLibrary else { return }
        await library.start()
    }
}
