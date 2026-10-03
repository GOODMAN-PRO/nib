import UIKit
import BackgroundTasks
import NibContracts
import NibDesign

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Minimal confirmation UI, so plugins and the bridge work without the AI chat feature (F085 wraps it).
    static let confirmer = ShellConfirmationPresenter()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if !NibUITestMode.isEnabled { SafeMode.beginLaunch() }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try LocalDocumentStorage.prepare(documents: documents)
        } catch {
            NSLog("Could not prepare local document storage: %@", String(describing: error))
        }
        do { try NibUITestMode.prepareStorage() }
        catch { UITestFixture.failure = "Could not prepare fixture storage: \(error)" }
        let app = NibApp(defaults: UITestFixture.defaults())
        app.gateway.presenter = AppDelegate.confirmer
        let disabled = NibUITestMode.isEnabled ? Set<String>() : SafeMode.disabledFeatures
        let features = FeatureList.all.filter { !disabled.contains($0.id) }
        app.register(features)
        UITestFixture.configure(app)
        DesignGallery.registerSettingsPage(in: app)   // Settings › Advanced › Developer (NibDesign is not a feature)
        registerBackgroundTasks(app)   // must run before this method returns
        Task { @MainActor in
            guard UITestFixture.failure == nil else { return }
            await app.start(features)
            if NibUITestMode.isEnabled {
                do {
                    try await UITestFixture.seed(app)
                    UITestFixture.isReady = true
                    if let shell = app.ui.activeNavigator as? ShellViewController {
                        shell.showInitialScreen()
                    } else {
                        app.ui.activeNavigator?.showLibrary(folder: nil)
                    }
                } catch {
                    UITestFixture.failure = String(describing: error)
                }
            } else { SafeMode.endLaunch() }
        }
        return true
    }

    /// Registers every identifier in Info.plist `BGTaskSchedulerPermittedIdentifiers` exactly once, synchronously
    /// (registering after launch throws NSInternalInconsistencyException), and routes each launch to the
    /// `BackgroundTaskDescriptor` with that id; a task without a descriptor (feature disabled) completes at once.
    private func registerBackgroundTasks(_ app: NibApp) {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        for id in ids {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak app] task in
                Task { @MainActor in
                    guard let app = app, let descriptor = app.content.backgroundTasks.get(id) else {
                        task.setTaskCompleted(success: true)
                        return
                    }
                    let work = Task { @MainActor in await descriptor.handler(task) }
                    task.expirationHandler = { work.cancel() }
                    task.setTaskCompleted(success: await work.value)
                }
            }
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        let config = UISceneConfiguration(name: nil, sessionRole: role)
        if role == .windowExternalDisplayNonInteractive {
            if NibApp.shared?.ui.externalDisplay != nil { config.delegateClass = ExternalDisplaySceneDelegate.self }
        } else {
            config.delegateClass = SceneDelegate.self
        }
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var shell: ShellViewController?
    private var keyObserver: NSObjectProtocol?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let app = NibApp.shared else { return }
        let shell = ShellViewController(app: app)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = shell
        self.window = window
        self.shell = shell
        // Commands target the window the user works in: follow the key window across scenes (Split View, Stage
        // Manager, external keyboard focus), not only scene activation, which several windows share.
        keyObserver = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shell?.windowDidBecomeKey() }
        }
        window.makeKeyAndVisible()
        shell.activateWindow()
        app.ui.sceneHooks?.sceneDidConnect(windowScene, options: connectionOptions, navigator: shell)
        for context in connectionOptions.urlContexts { shell.handle(url: context.url) }
        if let item = connectionOptions.shortcutItem {
            app.perform(CommandIDs.appQuickAction, ["type": .string(item.type)], session: shell.session)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        shell?.activateWindow()
        NibApp.shared?.perform(CommandIDs.appQuickAction, ["type": .string(shortcutItem.type)], session: shell?.session)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        shell?.activateWindow()
        for context in URLContexts { shell?.handle(url: context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let shell = shell, let app = NibApp.shared else { return }
        // Several windows become active together; the key one wins, and any active one beats a window that is not key.
        let current = app.ui.activeNavigator
        if shell.isKeyWindow || current == nil || (current as? ShellViewController)?.isKeyWindow != true {
            shell.activateWindow()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let observer = keyObserver { NotificationCenter.default.removeObserver(observer) }
        keyObserver = nil
        guard let shell = shell, let app = NibApp.shared else { return }
        // Hand over before the session goes, so `sessions.remove` never makes the newest session active on its own
        // (with a `session.activated` for a window the user did not pick). A closing window that is not the active one
        // leaves the active window as it is, and re-syncs its session when the two had drifted apart.
        if app.ui.activeNavigator === shell || app.services.sessions.active === shell.session {
            let current = app.ui.activeNavigator as? ShellViewController
            let successor = current.flatMap { $0 === shell ? nil : $0 } ?? SceneDelegate.nextWindow(after: scene)
            if current === shell { app.ui.activeNavigator = nil }
            successor?.activateWindow()
        }
        app.services.sessions.remove(shell.session)
        ShellViewController.windowDidClose(shell)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let shell = shell else { return nil }
        return NibApp.shared?.ui.sceneHooks?.restorationActivity(shell)
    }

    /// The window that takes over when `closed` goes away: the key window, else the foreground window the user
    /// activated most recently, else any foreground window (nil when no other window is in the foreground).
    private static func nextWindow(after closed: UIScene) -> ShellViewController? {
        let shells = UIApplication.shared.connectedScenes
            .filter { $0 !== closed && $0.activationState != .unattached && $0.activationState != .background }
            .compactMap { ($0.delegate as? SceneDelegate)?.shell }
        if let key = shells.first(where: { $0.isKeyWindow }) { return key }
        return ShellViewController.mostRecentlyActivated(among: shells) ?? shells.first
    }
}

/// Alert-based confirmation for non-user principals (plugins, bridge, AI): who asks, which command, the params.
@MainActor
final class ShellConfirmationPresenter: ConfirmationPresenter {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        guard let root = NibApp.shared?.ui.activeNavigator?.rootViewController else { return .deny }
        let details = String(request.params.jsonString(pretty: true).prefix(600))
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: request.command.title,
                                          message: "\(request.principal) wants to run \(request.command.id).\n\n\(details)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Deny"), style: .cancel) { _ in
                continuation.resume(returning: .deny)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Allow rest of this turn"), style: .default) { _ in
                continuation.resume(returning: .allowRestOfGroup)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Allow"), style: .default) { _ in
                continuation.resume(returning: .allow)
            })
            var top = root
            while let presented = top.presentedViewController { top = presented }
            top.present(alert, animated: true)
        }
    }
}

/// External display (AirPlay / HDMI) scene; content comes from the Presentation feature.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let root = NibApp.shared?.ui.externalDisplay?(windowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.isHidden = false
        self.window = window
    }
}
