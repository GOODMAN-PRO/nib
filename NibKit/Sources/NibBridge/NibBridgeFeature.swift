import Foundation
import UIKit
import NibContracts

/// MCP / HTTP bridge server (F090, docs/AI.md §9): external agents such as Claude Code on a PC drive Nib over the LAN
/// or Tailscale with the same tool catalogue as the in-app AI, as principal `.bridge(<client>)`.
public enum NibBridgeFeature: NibFeature {
    public static let id = "bridge"

    public static func register(_ app: NibApp) {
        BridgeSettings.declare(app.settings, owner: id)
        app.commands.register(BridgeSetEnabled.self)
        app.commands.register(BridgeStatusCommand.self)
        let controller = BridgeController(app: app)
        app.services.set(controller, for: BridgeController.serviceKey)
        controller.installGatewayHooks()
    }

    public static func start(_ app: NibApp) async {
        guard let controller = try? BridgeController.resolve(app.services) else { return }
        controller.startObserving()
        controller.reconcile()
    }
}

/// Owns the listener and the bridge's runtime state. The listener runs only while the bridge is enabled, has a token
/// and the app is in the foreground (iOS suspends sockets in the background); it is recreated on return.
@MainActor
final class BridgeController {
    static let serviceKey = "bridge.controller"
    /// Emitted on the app event bus when the state or the set of clients changes (status pill, settings page).
    static let statusEvent = "bridge.status"

    enum State: String {
        case off, starting, listening, suspended, failed, tokenMissing
    }

    unowned let app: NibApp
    let assets: BridgeAssets
    let mcp: MCPHandler
    let router: BridgeRouter
    let confirmer: BridgeConfirmer
    /// Builds the listener for a port; nil = the real `HTTPServer` (tests install a recorder).
    var makeServer: ((UInt16) -> HTTPServing)?
    private(set) var state: State = .off
    private(set) var lastError: String?
    private(set) var lastCall: BridgeCall?
    private var clients: [String: BridgeStatus.Client] = [:]
    private var server: HTTPServing?
    private var serverPort: Int?
    private var boundPort: Int?
    /// Bumped per listener, so late events from a stopped one are ignored.
    private(set) var generation = 0
    private var retries = 0
    private var inForeground = true
    private var observers: [NSObjectProtocol] = []

    init(app: NibApp) {
        self.app = app
        let assets = BridgeAssets()
        let mcp = MCPHandler(app: app, assets: assets)
        self.assets = assets
        self.mcp = mcp
        router = BridgeRouter(app: app, mcp: mcp, assets: assets)
        confirmer = BridgeConfirmer()
        mcp.onActivity = { [weak self] activity in self?.note(activity) }
    }

    static func resolve(_ services: NibServices) throws -> BridgeController {
        guard let c = services.get(serviceKey, as: BridgeController.self) else { throw NibError.unavailable("the MCP bridge") }
        return c
    }

    /// Bridge principals follow `security.bridge.confirmationPolicy`; confirmations they trigger are shown by the
    /// existing presenter and answered with Deny after 115 s, so a request never waits more than 120 s.
    func installGatewayHooks() {
        let settings = app.settings
        let previous = app.gateway.policy
        app.gateway.policy = { principal in
            if case .bridge = principal { return settings.get(NibSettings.bridgeConfirmationPolicy) }
            return previous(principal)
        }
        if let current = app.gateway.presenter {
            confirmer.inner = current
            app.gateway.presenter = confirmer
        }
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        // Launched into the background (background refresh): wait for the foreground before listening.
        if !NibApp.isHostlessTest { inForeground = UIApplication.shared.applicationState != .background }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setForeground(false) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setForeground(true) }
        })
        observers.append(center.addObserver(forName: SettingsStore.didChange, object: app.settings, queue: nil) { [weak self] note in
            let name = note.userInfo?["name"] as? String
            guard name == BridgeSettings.enabled.name || name == BridgeSettings.port.name else { return }
            Task { @MainActor in self?.reconcile() }
        })
    }

    func setForeground(_ foreground: Bool) {
        inForeground = foreground
        retries = 0
        reconcile()
    }

    /// Brings the listener in line with the settings; restarts it when the port changed or it failed.
    func reconcile() {
        let port = app.settings.get(BridgeSettings.port)
        let desired: State
        if !app.settings.get(BridgeSettings.enabled) {
            desired = .off
        } else if BridgeSecrets.token() == nil {
            desired = .tokenMissing
        } else if !inForeground {
            desired = .suspended
        } else {
            desired = .listening
        }
        guard desired == .listening else {
            stopServer()
            setState(desired, error: desired == .tokenMissing
                        ? "credentials missing — re-enter: issue a new token in Settings › Bridge" : nil)
            return
        }
        if server != nil, serverPort == port, state != .failed { return }
        stopServer()
        guard (1...65535).contains(port) else {
            setState(.failed, error: "port \(port) is out of range")
            return
        }
        generation += 1
        let s = makeServer?(UInt16(port)) ?? defaultServer(UInt16(port), generation: generation)
        do {
            try s.start()
            server = s
            serverPort = port
            setState(.starting, error: nil)
        } catch {
            setState(.failed, error: NibError.wrap(error).message)
        }
    }

    /// A new token was issued: every session of the old one ends (its clients get 401 and must re-pair).
    func tokenChanged() {
        mcp.dropSessions()
        clients.removeAll()
        lastCall = nil
        emitStatus()
    }

    func status() -> BridgeStatus {
        let settings = app.settings
        let port = boundPort ?? settings.get(BridgeSettings.port)
        let running = state == .listening
        let networks = BridgeNetworks.parse(settings.get(BridgeSettings.networks))
        let cutoff = Date().timeIntervalSince1970 - 600
        let recent = clients.values.filter { $0.sessions > 0 || $0.lastSeen >= cutoff }.sorted { $0.lastSeen > $1.lastSeen }
        return BridgeStatus(enabled: settings.get(BridgeSettings.enabled), state: state.rawValue, running: running, port: port,
                            urls: running ? LocalAddresses.urls(port: port, networks: networks) : [],
                            bonjour: HTTPServer.serviceType, tokenMissing: BridgeSecrets.token() == nil, error: lastError,
                            clients: recent, lastCall: lastCall)
    }

    // MARK: Private

    private func defaultServer(_ port: UInt16, generation: Int) -> HTTPServing {
        let settings = app.settings
        return HTTPServer(port: port, advertise: !NibApp.isHostlessTest,
                          handler: { [weak self] request, remote in
                              guard let self = self else { return HTTPResponse.failure(503, "the bridge is shutting down") }
                              return await self.router.route(request, remote: remote)
                          },
                          gate: { head, remote in BridgeAuth.refusal(head, remote: remote, settings: settings) },
                          onEvent: { [weak self] event in self?.serverEvent(event, generation: generation) })
    }

    func serverEvent(_ event: HTTPServerEvent, generation: Int) {
        guard generation == self.generation, server != nil else { return }   // a stopped listener's late news
        switch event {
        case .ready(let port):
            boundPort = port
            retries = 0
            setState(.listening, error: nil)
        case .waiting(let message):
            setState(.starting, error: message)
        case .failed(let message):
            stopServer()
            setState(.failed, error: message)
            // ponytail: three quick retries cover a port still held by the previous listener; after that the
            // user toggles the bridge (or changes the port) to try again.
            guard retries < 3 else { return }
            retries += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self?.state == .failed { self?.reconcile() }
            }
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        serverPort = nil
        boundPort = nil
    }

    private func setState(_ s: State, error: String?) {
        let changed = s != state || error != lastError
        state = s
        lastError = error
        if changed { emitStatus() }
    }

    private func emitStatus() {
        app.events.emit(BridgeController.statusEvent, payload: ["state": .string(state.rawValue)])
    }

    private func note(_ activity: BridgeActivity) {
        switch activity {
        case let .session(client, version, started):
            var c = clients[client] ?? BridgeStatus.Client(name: client, version: nil, lastSeen: 0, calls: 0, sessions: 0)
            c.version = version ?? c.version
            c.sessions = max(0, c.sessions + (started ? 1 : -1))
            c.lastSeen = Date().timeIntervalSince1970
            clients[client] = c
            emitStatus()
        case .call(let call):
            var c = clients[call.client] ?? BridgeStatus.Client(name: call.client, version: nil, lastSeen: 0, calls: 0, sessions: 0)
            c.calls += 1
            c.lastSeen = call.at
            clients[call.client] = c
            lastCall = call
        }
    }
}

/// Wraps the app's confirmation presenter: requests from bridge principals are answered with Deny when nobody
/// responds on the device within `timeout` (the sheet may stay up; a late answer is ignored), or once the tool call
/// itself timed out (its work task is cancelled, and this runs inside it), so a late Allow never applies a change the
/// agent was told timed out. Everyone else passes straight through.
@MainActor
final class BridgeConfirmer: ConfirmationPresenter {
    var inner: ConfirmationPresenter?
    var timeout: TimeInterval = 115

    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        guard let inner = inner else { return .deny }
        guard case .bridge = request.principal else { return await inner.confirm(request) }
        guard !Task.isCancelled else { return .deny }
        let decision = try? await Deadline.run(seconds: timeout, timeout: { NibError(.userDenied, "no answer on the device") }) {
            await inner.confirm(request)
        }
        return Task.isCancelled ? .deny : decision ?? .deny
    }
}
