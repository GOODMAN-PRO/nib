import SwiftUI
import UIKit
import WebKit
import os
import NibContracts
import NibDesign

// MARK: - Navigation policy (pure, tested)

/// Where a panel's frames may go. The main frame never leaves the plugin's own origin; sub-frames may also show
/// in-page `about:`, `data:` and `blob:` documents and pages from the allowed network hosts. A link the user taps to
/// an allowed host opens outside the panel (in the browser); everything else is refused.
enum PanelNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case deny
        case openExternally(URL)
    }

    static func decide(url: URL?, isMainFrame: Bool, userActivated: Bool, pluginID: String,
                       allowedHosts: [String]) -> Decision {
        guard let url = url, let scheme = url.scheme?.lowercased() else { return .deny }
        if PluginPanelURL.isOwn(url, pluginID: pluginID) { return .allow }
        if scheme == "about" || scheme == "data" || scheme == "blob" { return isMainFrame ? .deny : .allow }
        guard scheme == "https" || scheme == "http" else { return .deny }
        let allowed = Set(PanelContentRules.normalizedHosts(allowedHosts))
        guard url.user == nil, url.password == nil, allowed.contains((url.host ?? "").lowercased()) else { return .deny }
        if userActivated && scheme == "https" { return .openExternally(url) }
        return isMainFrame ? .deny : .allow
    }
}

// MARK: - Panel identity (pure, tested)

enum PanelIdentity {
    /// The panel id for `entry`: `makePanel` is given the entry file, not the id. With several panels on one file the
    /// one the window has open wins, else the first declared.
    static func panelID(manifest: PluginManifest, entry: String, openPanels: Set<String>) -> String {
        let panels = manifest.contributes?.panels ?? []
        let target = normalize(entry)
        let matches = panels.filter { normalize($0.entry) == target }
        if matches.count > 1, let open = matches.first(where: { openPanels.contains($0.id) }) { return open.id }
        return matches.first?.id ?? panels.first?.id ?? manifest.id
    }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    /// Floating panels draw `NibPluginPanelChrome` (the 344 pt Deep panel frame, DESIGN.md §14.10); sheets, sidebar
    /// tabs, windows and library tabs take the host's width with the same header.
    static func usesFloatingChrome(presentation: PanelPresentation?, placement: String?) -> Bool {
        if let presentation = presentation { return presentation == .floating }
        return (placement ?? PanelPlacement.floating.rawValue) == PanelPlacement.floating.rawValue
    }
}

// MARK: - Live panel

/// Something that shows one plugin panel and takes main.js's `nib.ui.postToPanel` messages.
@MainActor
protocol PanelMessageSink: AnyObject {
    var pluginID: String { get }
    var panelID: String { get }
    func deliverMessage(_ message: JSONValue)
}

/// Cancels the panel's event subscriptions and observers when the panel goes away.
final class PanelSubscriptionBag {
    private var subscriptions: [EventSubscription] = []
    private var observers: [NSObjectProtocol] = []

    func add(_ subscription: EventSubscription) { subscriptions.append(subscription) }
    func add(observer: NSObjectProtocol) { observers.append(observer) }

    func cancelAll() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    deinit { cancelAll() }
}

/// Runs `body` on the main actor now when already on the main thread (keeping event order), else on the next turn.
enum PanelMainThread {
    static func run(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}

/// One plugin HTML panel: its WKWebView (scheme handler, content rules, injected `window.nib`), the bridge to the bus,
/// messages both ways, Nib's CSS tokens as traits change, and the loading / stopped / failed states.
@MainActor
final class PluginWebPanel: NSObject, ObservableObject, PanelMessageSink {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        /// The web content process ended (a crash or the system reclaimed it).
        case stopped
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    let manifest: PluginManifest
    let panelID: String
    let folder: URL
    let entry: String
    let bridge: PanelBridge
    let container = PanelContainerView()
    let title: String
    let symbol: NibSymbol
    var pluginID: String { manifest.id }

    private weak var app: NibApp?
    private weak var factory: PluginPanelFactoryService?
    private weak var session: EditorSession?
    private weak var navigator: SceneNavigator?
    private let dismiss: @MainActor () -> Void
    private var webView: WKWebView?
    private var allowedHosts: [String] = []
    private var pageReady = false
    private var outbox: [(String, JSONValue)] = []
    private var started = false
    /// The network rules are compiling; the web view is made when they are ready.
    private var compiling = false
    private let bag = PanelSubscriptionBag()
    private let log = Logger(subsystem: "app.nib", category: "pluginpanels")

    init(app: NibApp, factory: PluginPanelFactoryService?, manifest: PluginManifest, panelID: String, folder: URL,
         entry: String, context: PanelContext) {
        self.app = app
        self.factory = factory
        self.manifest = manifest
        self.panelID = panelID
        self.folder = folder
        self.entry = entry
        self.session = context.session
        self.navigator = context.navigator
        self.dismiss = context.dismiss
        let contribution = manifest.contributes?.panels?.first { $0.id == panelID }
        self.title = contribution?.title ?? manifest.name
        self.symbol = NibSymbol.plugin(contribution?.icon ?? "")
        let sessionRef = WeakSession(context.session)
        let navigatorRef = WeakNavigator(context.navigator)
        self.bridge = PanelBridge(
            app: app, manifest: manifest, panelID: panelID, params: context.params,
            session: { [weak app] in sessionRef.value ?? app?.services.sessions.active },
            dialogs: PanelDialogs(pluginName: manifest.name,
                                  navigator: { [weak app] in navigatorRef.value ?? app?.ui.activeNavigator }))
        super.init()
        bridge.send = { [weak self] kind, payload in self?.send(kind, payload) }
        bridge.onHello = { [weak self] in self?.pageDidStart() }
        container.onTraitsChange = { [weak self] in self?.pushTokens() }
        container.onReloadShortcut = { [weak self] in self?.reload() }
    }

    // MARK: Lifecycle

    /// Builds the web view once the network rules compiled, then loads the entry page. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        guard let app = app else {
            phase = .failed(String(localized: "Nib is not ready to show this panel."))
            return
        }
        factory?.attach(self)
        bag.add(app.events.subscribe { [weak self] event in
            PanelMainThread.run { self?.bridge.offer(event) }
        })
        let prefix = "plugin.\(manifest.id)."
        bag.add(observer: NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                 queue: .main) { [weak self] note in
            let name = note.userInfo?["name"] as? String ?? ""
            guard name.hasPrefix(prefix) else { return }
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.send("settings", self.bridge.currentSettings())
            }
        })
        if NibApp.isHostlessTest {
            // No live WKWebView in hostless tests (NibApp.isHostlessTest): the bridge and messaging still work.
            phase = .failed(String(localized: "Plugin panels open in the app."))
            return
        }
        load(app)
    }

    private func load(_ app: NibApp) {
        guard let url = PluginPanelURL.url(pluginID: pluginID, path: entry) else {
            fail(String(localized: "This panel's page is missing from the plugin."), detail: "bad entry \(entry)")
            return
        }
        if case .failure(let e) = PluginResourceResolver(pluginID: pluginID, folder: folder).resolve(url) {
            fail(String(localized: "This panel's page is missing from the plugin."), detail: e.message)
            return
        }
        phase = .loading
        guard !compiling else { return }
        compiling = true
        allowedHosts = PanelContentRules.allowedHosts(manifest: manifest, granted: app.gateway.grants(bridge.principal))
        let json = PanelContentRules.json(pluginID: pluginID, allowedHosts: allowedHosts)
        let identifier = PanelContentRules.identifier(pluginID: pluginID, json: json)
        let cache = factory?.ruleLists ?? PanelRuleListCache()
        cache.ruleList(identifier: identifier, json: json) { [weak self] result in
            guard let self = self else { return }
            self.compiling = false
            switch result {
            case .success(let rules):
                self.makeWebView(rules: rules)
                self.webView?.load(URLRequest(url: url))
            case .failure(let error):
                // Fail closed: without its network rules a panel never loads.
                self.fail(String(localized: "This panel could not start safely."), detail: error.message)
            }
        }
    }

    private func makeWebView(rules: WKContentRuleList) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(PluginSchemeHandler(resolver: PluginResourceResolver(pluginID: pluginID, folder: folder)),
                                   forURLScheme: PluginPanelURL.scheme)
        config.websiteDataStore = factory?.dataStore(for: pluginID) ?? .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.dataDetectorTypes = []
        let content = config.userContentController
        content.add(rules)
        content.addUserScript(WKUserScript(source: PanelBridgeScript.networkGuard, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        let tokens = NibWebTokens.stylesheet(for: container.traitCollection)
        content.addUserScript(WKUserScript(source: PanelBridgeScript.source(info: bridge.bootInfo(tokens: tokens)),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addScriptMessageHandler(PanelScriptProxy(target: self), contentWorld: .page,
                                        name: PanelBridgeScript.handlerName)

        let web = WKWebView(frame: container.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        // Plugin authors debug their panels with Safari's Web Inspector (a connected Mac with Develop enabled).
        web.isInspectable = true
        web.accessibilityLabel = title
        container.install(web)
        webView = web
    }

    /// Reload from the menu, ⌘R or the stopped / failed states: reload the plugin (`plugin.reload`, so main.js picks
    /// up edits too), then the page.
    func reload() {
        guard let app = app else { return }
        let session = self.session ?? app.services.sessions.active
        let id = pluginID
        Task { @MainActor [weak self] in
            do {
                _ = try await app.bus.execute(Invocation(command: CommandIDs.pluginReload, params: ["id": .string(id)],
                                                         session: session))
            } catch let e as NibError where e.code == .unavailable || e.code == .notFound {
                // No plugin host (a stub build): reloading the page is all there is.
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": CommandIDs.pluginReload, "error": NibError.wrap(error)])
            }
            self?.reloadPage()
        }
    }

    private func reloadPage() {
        guard let app = app else { return }
        pageReady = false
        outbox.removeAll()
        bridge.resetPage()
        if let web = webView, let url = PluginPanelURL.url(pluginID: pluginID, path: entry) {
            phase = .loading
            web.load(URLRequest(url: url))
        } else if !NibApp.isHostlessTest {
            load(app)
        }
    }

    func close() { dismiss() }

    /// Settings › Plugins, where the plugin's permissions are listed (the first Plugins settings page).
    func showPermissions() {
        guard let app = app else { return }
        let pages: [SettingsPageDescriptor] = app.ui.settingsPages.all.filter { $0.section == .plugins }
        var params: [String: JSONValue] = [:]
        if let first = pages.min(by: { $0.order < $1.order }) { params["page"] = .string(first.id) }
        app.perform(CommandIDs.settingsOpen, .object(params), session: session)
    }

    /// The plugin's homepage (where its author takes reports), else Nib's diagnostics export.
    func reportProblem() {
        guard let app = app else { return }
        if let home = manifest.homepage, let url = URL(string: home), url.scheme?.lowercased() == "https" {
            app.perform(CommandIDs.linkFollow, ["url": .string(url.absoluteString)], session: session)
        } else {
            app.perform(CommandIDs.diagnosticsExport, [:], session: session)
        }
    }

    private func fail(_ message: String, detail: String) {
        log.error("\(self.pluginID, privacy: .public) panel \(self.panelID, privacy: .public): \(detail, privacy: .public)")
        phase = .failed(message)
    }

    // MARK: Messages into the page

    func deliverMessage(_ message: JSONValue) {
        send("message", message)
    }

    /// Pushes into the page, or keeps it until the page's script said hello.
    private func send(_ kind: String, _ payload: JSONValue) {
        guard pageReady, let web = webView else {
            if outbox.count >= 256 { outbox.removeFirst() }
            outbox.append((kind, payload))
            return
        }
        web.callAsyncJavaScript(PanelBridgeScript.receiveCall, arguments: ["kind": kind, "json": payload.jsonString()],
                                in: nil, in: .page, completionHandler: nil)
    }

    private func pageDidStart() {
        pageReady = true
        let queued = outbox
        outbox.removeAll()
        // The injected info may be older than this document (a reload): refresh settings and tokens first.
        send("settings", bridge.currentSettings())
        pushTokens()
        for (kind, payload) in queued where kind == "message" { send(kind, payload) }
    }

    private func pushTokens() {
        guard pageReady else { return }
        send("tokens", .string(NibWebTokens.stylesheet(for: container.traitCollection)))
    }

    // MARK: Calls from the page

    func receive(_ message: WKScriptMessage, reply: @escaping @MainActor (Any?, String?) -> Void) {
        // Only the panel's own document may call: sub-frames (an allowed host's iframe) never, and the main frame
        // cannot leave the plugin's origin (PanelNavigationPolicy).
        let url = message.frameInfo.request.url ?? message.webView?.url
        guard message.frameInfo.isMainFrame, PluginPanelURL.isOwn(url, pluginID: pluginID) else {
            reply(nil, PanelBridge.errorText(NibError(.permissionDenied, "only the panel's own page can call Nib")))
            return
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            reply(nil, PanelBridge.errorText(NibError.invalid("expected {method, args}")))
            return
        }
        let args: JSONValue
        do {
            args = try JSONValue.parse(body["args"] as? String ?? "null")
        } catch {
            reply(nil, PanelBridge.errorText(NibError.invalid("the call's arguments are not JSON", path: "$.args")))
            return
        }
        do {
            if let value = try bridge.handleNow(method, args) {
                reply(value.jsonString(), nil)
                return
            }
        } catch {
            reply(nil, PanelBridge.errorText(NibError.wrap(error)))
            return
        }
        let bridge = self.bridge
        Task { @MainActor in
            do {
                reply(try await bridge.handle(method, args).jsonString(), nil)
            } catch {
                reply(nil, PanelBridge.errorText(NibError.wrap(error)))
            }
        }
    }

    private func openExternally(_ url: URL) {
        app?.perform(CommandIDs.linkFollow, ["url": .string(url.absoluteString)], session: session)
    }
}

// MARK: WebKit delegates

extension PluginWebPanel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            return
        }
        let decision = PanelNavigationPolicy.decide(url: navigationAction.request.url,
                                                    isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                                    userActivated: navigationAction.navigationType == .linkActivated,
                                                    pluginID: pluginID, allowedHosts: allowedHosts)
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .deny:
            decisionHandler(.cancel)
        case .openExternally(let url):
            decisionHandler(.cancel)
            openExternally(url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if phase == .loading { phase = .ready }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        bridge.resetPage()
        log.error("\(self.pluginID, privacy: .public) panel \(self.panelID, privacy: .public): web content process ended")
        phase = .stopped
    }

    private func navigationFailed(_ error: Error) {
        let ns = error as NSError
        // A navigation the policy cancelled, or one replaced by the next load, is not a failure of the panel.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        // WebKitErrorFrameLoadInterruptedByPolicyChange.
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        fail(String(localized: "This panel could not open."), detail: ns.localizedDescription)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // No pop-ups. A tapped target=_blank link to an allowed host opens in the browser.
        if case .openExternally(let url) = PanelNavigationPolicy.decide(
            url: navigationAction.request.url, isMainFrame: true,
            userActivated: navigationAction.navigationType == .linkActivated, pluginID: pluginID,
            allowedHosts: allowedHosts) {
            openExternally(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let dialogs = bridge.dialogs
        Task { @MainActor in
            await dialogs.alert(message)
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let dialogs = bridge.dialogs
        let name = manifest.name
        Task { @MainActor in
            completionHandler((try? await dialogs.confirm(name, message: message)) ?? false)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let dialogs = bridge.dialogs
        Task { @MainActor in
            completionHandler((try? await dialogs.prompt(prompt, placeholder: nil, initial: defaultText)) ?? nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // No plugin permission covers the camera or the microphone.
        decisionHandler(.deny)
    }
}

/// The user content controller keeps its message handler strongly; this keeps the panel weakly (no cycle).
@MainActor
final class PanelScriptProxy: NSObject, WKScriptMessageHandlerWithReply {
    private weak var target: PluginWebPanel?

    init(target: PluginWebPanel) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let target = target else {
            replyHandler(nil, PanelBridge.errorText(NibError(.unavailable, "the panel is closing")))
            return
        }
        target.receive(message, reply: replyHandler)
    }
}

private final class WeakSession {
    weak var value: EditorSession?
    init(_ value: EditorSession?) { self.value = value }
}

private final class WeakNavigator {
    weak var value: SceneNavigator?
    init(_ value: SceneNavigator?) { self.value = value }
}

// MARK: - UIKit host view

/// Holds the web view, follows the traits Nib's CSS tokens depend on, and offers ⌘R (Reload Panel) while the panel
/// has keyboard focus.
final class PanelContainerView: UIView {
    var onTraitsChange: (() -> Void)?
    var onReloadShortcut: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let traits: [UITrait] = [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]
        registerForTraitChanges(traits) { (view: PanelContainerView, _: UITraitCollection) in
            view.onTraitsChange?()
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func install(_ web: WKWebView) {
        subviews.forEach { $0.removeFromSuperview() }
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var keyCommands: [UIKeyCommand]? {
        let reload = UIKeyCommand(title: String(localized: "Reload Panel"), action: #selector(reloadShortcut),
                                  input: "r", modifierFlags: .command)
        return [reload]
    }

    @objc private func reloadShortcut() {
        onReloadShortcut?()
    }
}

struct PanelWebViewHost: UIViewRepresentable {
    let panel: PluginWebPanel

    func makeUIView(context: Context) -> PanelContainerView { panel.container }
    func updateUIView(_ uiView: PanelContainerView, context: Context) {}
}

// MARK: - SwiftUI

/// What `PluginPanelFactory.makePanel` returns: Nib's plugin chrome (the "Plugin" badge, More: Reload, Permissions,
/// Report a Problem; Close) around the plugin's page. The page is transparent; Nib draws the droplet behind it and
/// the plugin never draws glass.
struct PluginPanelView: View {
    @StateObject private var panel: PluginWebPanel
    private let floating: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(floating: Bool, make: @escaping () -> PluginWebPanel) {
        self.floating = floating
        _panel = StateObject(wrappedValue: make())
    }

    var body: some View {
        Group {
            if floating && sizeClass != .compact {
                NibPluginPanelChrome(name: panel.title, symbol: panel.symbol,
                                     onReload: { panel.reload() }, onPermissions: { panel.showPermissions() },
                                     onReport: { panel.reportProblem() }, onClose: { panel.close() }) {
                    content
                }
            } else {
                VStack(spacing: 0) {
                    NibPanelHeader(title: panel.title, symbol: panel.symbol, badge: .plugin, onClose: { panel.close() }) {
                        PanelMoreMenu(panel: panel)
                    }
                    Rectangle()
                        .fill(NibColor.separatorSoft)
                        .frame(height: NibStroke.hairline)
                    content
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "\(panel.title) plugin"))
            }
        }
        .onAppear { panel.start() }
    }

    private var content: some View {
        ZStack {
            PanelWebViewHost(panel: panel)
                .opacity(showsPage ? 1 : 0)
                .accessibilityHidden(!showsPage)
            switch panel.phase {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel(String(localized: "Loading \(panel.title)"))
            case .ready:
                EmptyView()
            case .stopped:
                NibEmptyState(symbol: .warningTriangle, title: String(localized: "This plugin stopped."),
                              message: String(localized: "Reload it to try again."),
                              primary: NibAction(String(localized: "Reload")) { panel.reload() })
            case .failed(let message):
                NibEmptyState(symbol: .warningTriangle, title: String(localized: "This panel could not open."),
                              message: message,
                              primary: NibAction(String(localized: "Reload")) { panel.reload() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The page shows from its first load; it hides only behind the stopped and failed states.
    private var showsPage: Bool {
        switch panel.phase {
        case .loading, .ready: return true
        default: return false
        }
    }
}

/// The More menu of the flexible-width header (sheets, sidebar tabs): the same three actions as the floating chrome.
private struct PanelMoreMenu: View {
    @ObservedObject var panel: PluginWebPanel

    var body: some View {
        Menu {
            Button(String(localized: "Reload")) { panel.reload() }
            Button(String(localized: "Permissions")) { panel.showPermissions() }
            Button(String(localized: "Report a Problem")) { panel.reportProblem() }
        } label: {
            Image(nib: .more)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.labelSecondary)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "More"))
    }
}
