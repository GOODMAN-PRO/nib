import Foundation
import UIKit
import BackgroundTasks

/// Every module (feature, engine, plugin host) exposes exactly one public type conforming to this,
/// named `<ModuleName>Feature`, e.g. `FeatPenFeature`. The app shell registers them all at launch.
@MainActor
public protocol NibFeature {
    /// Stable id, e.g. "pen". Used as `owner` of everything the feature registers.
    static var id: String { get }
    /// Register commands, services, drawers, templates, toolbar items, menus, panels, settings pages.
    /// Must be fast and must not resolve services or touch documents.
    static func register(_ app: NibApp)
    /// Called once after every feature registered (start watchers, restore state, load plugins).
    static func start(_ app: NibApp) async
}

@MainActor
public extension NibFeature {
    static func start(_ app: NibApp) async {}
}

/// The composition root: one per process, created by the app shell.
@MainActor
public final class NibApp {
    public private(set) static var shared: NibApp?
    /// True inside package tests (set by `Harness`): no app bundle, Info.plist or entitlements. Features must then
    /// skip system singletons that crash or prompt there — UNUserNotificationCenter, BGTaskScheduler, microphone /
    /// camera / Speech / EventKit / Photos authorization, live WKWebView — and throw `unavailable` instead.
    public static var isHostlessTest = false

    public let events: EventBus
    public let clock: HLCClock
    public let settings: SettingsStore
    public let workspace: Workspace
    public let commands: CommandRegistry
    public let gateway: Gateway
    public let services: NibServices
    public let bus: CommandBus
    public let content: ContentRegistries
    public let ui: UIRegistries
    public private(set) var featureIDs: [String] = []

    public init(persistence: DocumentPersistence? = nil, defaults: UserDefaults = .standard,
                deviceID: UInt32 = DeviceIdentity.current, makeShared: Bool = true) {
        let events = EventBus()
        let clock = HLCClock(device: deviceID)
        let settings = SettingsStore(defaults: defaults)
        // nil = InMemoryPersistence (created here: a main-actor init cannot be a default argument).
        let workspace = Workspace(clock: clock, persistence: persistence ?? InMemoryPersistence(), events: events)
        let commands = CommandRegistry()
        let gateway = Gateway()
        let services = NibServices(settings: settings)
        self.events = events
        self.clock = clock
        self.settings = settings
        self.workspace = workspace
        self.commands = commands
        self.gateway = gateway
        self.services = services
        self.bus = CommandBus(registry: commands, workspace: workspace, gateway: gateway, services: services, events: events)
        self.content = ContentRegistries()
        self.ui = UIRegistries()
        services.sessions.events = events
        CoreCommands.register(commands)
        NibSettings.declareAll(settings)
        if makeShared { NibApp.shared = self }
    }

    /// Registers features in order. Commands a feature registers with owner "builtin" are stamped with its id.
    public func register(_ features: [NibFeature.Type]) {
        for f in features {
            commands.defaultOwner = f.id
            f.register(self)
            commands.defaultOwner = nil
            featureIDs.append(f.id)
        }
    }

    /// Asks iOS to run the registered background task `id` (see `BackgroundTaskDescriptor`) no earlier than
    /// `earliestIn` seconds from now. The ONLY way features schedule BGTaskScheduler work; no-op in hostless tests.
    public func scheduleBackgroundTask(_ id: String, earliestIn: TimeInterval) {
        guard !NibApp.isHostlessTest, let d = content.backgroundTasks.get(id) else { return }
        let request: BGTaskRequest
        switch d.kind {
        case .refresh: request = BGAppRefreshTaskRequest(identifier: id)
        case .processing: request = BGProcessingTaskRequest(identifier: id)
        }
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestIn)
        try? BGTaskScheduler.shared.submit(request)
    }

    public func start(_ features: [NibFeature.Type]) async {
        for f in features { await f.start(self) }
    }

    /// Runs a command as the user from UI code (menus, buttons); errors are reported to the user by the shell.
    public func perform(_ command: String, _ params: JSONValue = [:], session: EditorSession? = nil) {
        Task { @MainActor in
            do {
                try await self.bus.execute(command, params, session: session ?? self.services.sessions.active)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: self,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
        }
    }
}

public extension Notification.Name {
    /// userInfo: ["command": String, "error": NibError]. The shell shows a toast.
    static let nibCommandFailed = Notification.Name("NibCommandFailed")
}

/// Crash-loop protection: if two launches in a row die before `endLaunch`, the next launch is in safe mode
/// (plugins are not started, `SafeMode.disabledFeatures` are skipped).
public enum SafeMode {
    private static let crashKey = "nib.safemode.pendingLaunches"
    private static let disabledKey = "nib.safemode.disabledFeatures"

    public static var isActive: Bool { UserDefaults.standard.integer(forKey: crashKey) >= 2 }

    public static var disabledFeatures: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    public static func beginLaunch() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: crashKey) + 1, forKey: crashKey)
    }

    public static func endLaunch() {
        UserDefaults.standard.set(0, forKey: crashKey)
    }
}
