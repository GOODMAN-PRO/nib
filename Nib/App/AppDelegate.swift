import UIKit
import BackgroundTasks
import NibContracts

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Minimal confirmation UI, so plugins and the bridge work without the AI chat feature (F085 wraps it).
    static let confirmer = ShellConfirmationPresenter()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SafeMode.beginLaunch()
        let app = NibApp()
        app.gateway.presenter = AppDelegate.confirmer
        let disabled = SafeMode.disabledFeatures
        let features = FeatureList.all.filter { !disabled.contains($0.id) }
        app.register(features)
        registerBackgroundTasks(app)   // must run before this method returns
        Task { @MainActor in
            await app.start(features)
            SafeMode.endLaunch()
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
    private var shell: ShellViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let app = NibApp.shared else { return }
        let shell = ShellViewController(app: app)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = shell
        window.makeKeyAndVisible()
        self.window = window
        self.shell = shell
        app.ui.sceneHooks?.sceneDidConnect(windowScene, options: connectionOptions, navigator: shell)
        for context in connectionOptions.urlContexts { shell.handle(url: context.url) }
        if let item = connectionOptions.shortcutItem {
            app.perform(CommandIDs.appQuickAction, ["type": .string(item.type)], session: shell.session)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        NibApp.shared?.perform(CommandIDs.appQuickAction, ["type": .string(shortcutItem.type)], session: shell?.session)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { shell?.handle(url: context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let shell = shell, let app = NibApp.shared else { return }
        app.ui.activeNavigator = shell
        app.services.sessions.activate(shell.session)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let shell = shell else { return }
        NibApp.shared?.services.sessions.remove(shell.session)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let shell = shell else { return nil }
        return NibApp.shared?.ui.sceneHooks?.restorationActivity(shell)
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
            alert.addAction(UIAlertAction(title: String(localized: "Allow Rest of This Turn"), style: .default) { _ in
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
