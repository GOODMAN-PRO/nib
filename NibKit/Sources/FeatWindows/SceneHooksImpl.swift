import UIKit
import Combine
import SwiftUI
import NibContracts

/// `app.ui.sceneHooks`: what a window opens with (a requested document, its restored tabs, or on a cold launch the
/// last document), what it saves for restoration, and its tab strip.
@MainActor
final class SceneHooksImpl: SceneHooks {
    enum Reason {
        /// A new window asked for by `window.open`, `doc.open {mode: newWindow}`, the shell or a dragged-out tab.
        case request
        /// iPadOS restoring the window's scene session.
        case restoration
        /// The first window after a cold launch whose scene session was not kept.
        case coldLaunch
    }

    /// While the library catalog loads at launch a document cannot be opened yet; restoration retries after these
    /// delays (ms), then opens what it can.
    static let retryDelays: [UInt64] = [250, 500, 1_000, 2_000, 4_000]

    private weak var app: NibApp?
    let scenes: WindowScenes
    private var launchHandled = false
    private var tabPresentations: [NibID: TabStripDocumentPresentation] = [:]
    private var tabsSettingsWatch: AnyCancellable?

    init(app: NibApp, scenes: WindowScenes) {
        self.app = app
        self.scenes = scenes
        tabsSettingsWatch = NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard note.userInfo?["name"] as? String == WindowSettings.showTabs.name else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for navigator in self.scenes.all where navigator.session.document != nil {
                        _ = self.makeTabBar(navigator)
                    }
                }
            }
    }

    // MARK: SceneHooks

    func documentTabsMenu(_ context: ChromeContext) -> AnyView? {
        // The switcher is essential on iPhone, where no capsule may fit. Chrome can ask for it before
        // the shell has attached the floating host, so its visibility must not depend on that host.
        guard let app, let navigator = context.navigator, context.session.document != nil,
              TabStripLayout.showsStrip(tabCount: navigator.openDocuments.count,
                                       enabled: app.settings.get(WindowSettings.showTabs)) else { return nil }
        let presentation = tabPresentations[context.session.id]
        let model = presentation?.model ?? TabStripModel(app: app, navigator: navigator, scenes: scenes)
        return AnyView(DocumentTabsMenu(model: model, placement: presentation, compact: context.isCompact))
    }

    func sceneDidConnect(_ scene: UIWindowScene, options: UIScene.ConnectionOptions, navigator: SceneNavigator) {
        let type = WindowState.activityType
        let requested = options.userActivities.first { $0.activityType == type }
        var restored: WindowState?
        if let activity = scene.session.stateRestorationActivity, activity.activityType == type {
            restored = WindowState(userInfo: activity.userInfo ?? [:])
        }
        // A launch that opens a link, a Home Screen quick action or another activity shows that, not the last document.
        let external = !options.urlContexts.isEmpty || options.shortcutItem != nil
            || options.userActivities.contains { $0.activityType != type }
        connect(navigator, requested: requested.map { WindowState(userInfo: $0.userInfo ?? [:]) }, restored: restored,
                external: external)
    }

    func restorationActivity(_ navigator: SceneNavigator) -> NSUserActivity? {
        scenes.add(navigator)
        let state = WindowState.snapshot(of: navigator)
        if scenes.isFrontmost(navigator) { scenes.recordLastSession(state) }
        return state.activity(title: state.active.map { scenes.title(of: $0) })
    }

    func makeTabBar(_ navigator: SceneNavigator) -> UIView? {
        scenes.add(navigator)
        scenes.updateSceneTitle(navigator)
        guard let app else { return nil }
        let visible = TabStripLayout.showsStrip(tabCount: navigator.openDocuments.count,
                                                enabled: app.settings.get(WindowSettings.showTabs))
        // The shell asks after attaching its content controller. Returning nil here stops it from reserving and
        // clipping a separate 36 pt UIKit band; the floating host renders tabs inside the document's one container.
        if navigator.session.document != nil, let host = navigator.floatingHost,
           let root = navigator.rootViewController, let rootView = root.viewIfLoaded,
           let controller = root.children.first(where: { $0.viewIfLoaded?.superview === rootView }) {
            if let old = tabPresentations[navigator.session.id], old.controller !== controller || old.host !== host {
                old.dismiss()
                tabPresentations[navigator.session.id] = nil
            }
            if visible {
                let presentation = tabPresentations[navigator.session.id]
                    ?? TabStripDocumentPresentation(controller: controller, host: host)
                tabPresentations[navigator.session.id] = presentation
                presentation.present(TabStripModel(app: app, navigator: navigator, scenes: scenes))
            } else {
                tabPresentations.removeValue(forKey: navigator.session.id)?.dismiss()
            }
            tabPresentations = tabPresentations.filter { $0.value.controller != nil && $0.value.host != nil }
            app.ui.setNeedsChromeUpdate(navigator.session)
            return nil
        }
        tabPresentations.removeValue(forKey: navigator.session.id)?.dismiss()
        guard visible else { return nil }
        return TabStripHostView(model: TabStripModel(app: app, navigator: navigator, scenes: scenes))
    }

    // MARK: Opening a window

    /// The decision behind `sceneDidConnect`, free of UIKit types so it can be tested.
    func connect(_ navigator: SceneNavigator, requested: WindowState?, restored: WindowState?, external: Bool,
                 allowsRestoration: Bool = !NibUITestMode.isEnabled) {
        scenes.add(navigator)
        let coldLaunch = !launchHandled
        launchHandled = true
        // Fixture launches ignore saved sessions, which may refer to a previous fixture's documents. Explicit
        // new-window requests still use the normal opening path, including their chosen page and lock gate.
        if let state = requested {
            restore(state, into: navigator, reason: .request)
        } else if allowsRestoration, let state = restored {
            restore(state, into: navigator, reason: .restoration)
        } else if allowsRestoration, coldLaunch, !external, let doc = scenes.lastSession.active {
            restore(WindowState(tabs: [doc], active: doc, page: scenes.lastSession.page), into: navigator, reason: .coldLaunch)
        } else {
            scenes.updateSceneTitle(navigator)
        }
    }

    func restore(_ state: WindowState, into navigator: SceneNavigator, reason: Reason, attempt: Int = 0) {
        guard let app else { return }
        var wanted = state.tabs
        if reason != .request {
            // Restoring never asks for a password; a locked document is opened by the person, not by a relaunch.
            let lock = app.services.lock
            wanted.removeAll { lock?.isLocked($0) == true }
        }
        let ready = wanted.filter { scenes.canOpen($0) }
        let target = state.active.flatMap { wanted.contains($0) ? $0 : nil }
        let targetReady = target.map { ready.contains($0) } ?? true
        if (!targetReady || (ready.isEmpty && !wanted.isEmpty)), attempt < SceneHooksImpl.retryDelays.count {
            let delay = SceneHooksImpl.retryDelays[attempt]
            Task { @MainActor [weak self, weak navigator] in
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                // Stop if the window went away or the person already opened something.
                guard let self, let navigator, navigator.openDocuments.isEmpty, navigator.session.document == nil else { return }
                self.restore(state, into: navigator, reason: reason, attempt: attempt + 1)
            }
            return
        }
        let active = target.flatMap { ready.contains($0) ? $0 : nil }
        apply(WindowState(tabs: ready, active: active, page: state.page), to: navigator, reason: reason)
        if reason == .request, let source = state.source, let doc = active,
           let origin = scenes.navigator(sessionID: source), origin !== navigator {
            // A dragged-out tab moves: it leaves its old window once it is on screen here (behind the lock gate that
            // waits for the password; a cancelled prompt leaves the tab where it was).
            scenes.close(doc, in: origin, once: navigator, shows: doc)
        }
        scenes.updateSceneTitle(navigator)
    }

    /// Puts the tabs in the strip in order without building their editors (`SceneNavigator.addTab`), then opens the
    /// active one, or brings the library back over the tabs. A tab that was not on screen opens (through the lock gate)
    /// only when it is selected.
    private func apply(_ state: WindowState, to navigator: SceneNavigator, reason: Reason) {
        // A requested document may ask for its password: it joins this window only once it opens, so a dismissed
        // prompt leaves no tab behind (a dragged-out tab then stays in its old window).
        let joinsOnOpen = reason == .request ? state.active : nil
        for doc in state.tabs where doc != joinsOnOpen {
            navigator.addTab(doc)
        }
        if let active = state.active {
            navigator.openDocument(active, page: state.page, mode: .newTab)
        } else if let last = state.tabs.last {
            // The library was on screen. The shell shows the tab strip once a tab is current, so the last tab opens
            // (the only editor built) and the library comes back over it, queued behind that open. This window, not
            // `window.showLibrary`: that acts on the active window, and windows restore side by side.
            navigator.openDocument(last, page: nil, mode: .newTab)
            Task { @MainActor [weak navigator] in navigator?.showLibrary(folder: nil) }
        }
    }
}
