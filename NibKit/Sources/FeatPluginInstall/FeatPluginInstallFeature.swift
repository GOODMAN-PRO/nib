import Foundation
import UIKit
import NibContracts

/// Plugin install & trust (F079, docs/PLUGIN_API.md §1, §8, §9). Stages a plugin from a URL, a local file or folder, a
/// gallery entry or inline files (AI authoring); refuses zip-slip paths, symbolic links and bundles over 20 MB;
/// validates the manifest and entry; hashes the package exactly as the plugin host does; checks a gallery's sha256;
/// asks the person on the consent sheet; moves the package into the library's plugins folder; writes the device-local
/// grant and asks the plugin host to start it. Updates show a permission diff and ask again when they need more.
/// Registers the "nibplugin" importer and reminds the person when a plugin waits for review on this device.
/// Commands: plugin.install, plugin.uninstall, plugin.review.
public enum FeatPluginInstallFeature: NibFeature {
    public static let id = "plugininstall"

    public static func register(_ app: NibApp) {
        app.services.set(PluginInstaller(), for: PluginInstaller.serviceKey)
        InstallCommands.register(app)
        app.content.importers.register(InstallCommands.importer(owner: id))
    }

    public static func start(_ app: NibApp) async {
        guard !NibApp.isHostlessTest else { return }
        do {
            try await PluginInstaller.shared(app.services).prepare(app.services)
        } catch {
            installLog.error("plugin transaction cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
        let reminder = ReviewReminder(app: app)
        app.services.set(reminder, for: ReviewReminder.serviceKey)
        reminder.start()
    }
}

/// A plugin that arrived through a synced library, or whose files changed, stays off until the person approves it on
/// this device. This posts one toast per plugin and package version ("“Cards” needs your review before it runs." ·
/// Review) in the active window when that happens, instead of letting it fail quietly.
@MainActor
final class ReviewReminder {
    static let serviceKey = "plugininstall.reviewReminder"

    private weak var app: NibApp?
    private var reminded = Set<String>()
    private var pending: Task<Void, Never>?
    private var subscription: EventSubscription?
    private var observer: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
    }

    func start() {
        guard let app = app else { return }
        subscription = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.libraryChanged else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedule() } }
        }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        schedule()
    }

    /// The plugin host rescans a moment after the library changes: look after it has.
    func schedule() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    func check() {
        guard let app = app, let host = app.services.get(ServiceKeys.pluginHost, as: PluginHosting.self),
              let floating = app.ui.activeNavigator?.floatingHost else { return }
        guard let plugin = host.installed.first(where: { $0.needsReview && !reminded.contains($0.id + "|" + $0.sha256) }) else {
            return
        }
        reminded.insert(plugin.id + "|" + plugin.sha256)
        let id = plugin.id
        floating.postToast(String(localized: "“\(plugin.name)” needs your review before it runs."),
                           actionTitle: String(localized: "Review")) { [weak app] in
            app?.perform(CommandIDs.pluginReview, ["id": .string(id)])
        }
    }
}
