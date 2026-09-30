import Foundation
import UIKit
import os
import NibContracts

/// Managed App Configuration (MDM AppConfig), F097.
///
/// An MDM server pushes an app configuration dictionary into the app's managed defaults domain under
/// `com.apple.configuration.managed`. A sideloaded build never receives one, so there this reader only clears values
/// an earlier enrolment left behind. On an MDM-distributed build it mirrors the dictionary into read-only settings
/// under the "managed." prefix (declared read-only by NibContracts, so `settings.set` refuses every caller).
/// Features, plugins, the AI and the bridge read them with `settings.get` / `settings.list` / `settings.describe`.
/// The mirror refreshes whenever UserDefaults change (the way iOS delivers a new configuration) and when the app
/// returns to the foreground. No UI and no commands: the settings commands in NibContracts are the whole API.
public enum FeatManagedConfigFeature: NibFeature {
    public static let id = "managed"

    public static func register(_ app: NibApp) {
        let reader = ManagedConfigReader(settings: app.settings, events: app.events,
                                         source: UserDefaultsManagedConfigSource(defaults: .standard))
        app.services.set(reader, for: ManagedConfigReader.serviceKey)
        // One defaults read: values are current before any other feature's `start` reads them.
        reader.refresh()
    }

    public static func start(_ app: NibApp) async {
        guard let reader = app.services.get(ManagedConfigReader.serviceKey, as: ManagedConfigReader.self) else { return }
        reader.startObserving()
        reader.refresh()
    }
}

// MARK: - Parsing

/// Flattens a managed configuration dictionary into setting names relative to "managed.".
///
/// Both forms an MDM console produces give the same names:
/// - nested: `{"webdav": {"url": "https://…", "allowUntrusted": false}}`
/// - flat: `{"webdav.url": "https://…", "webdav.allowUntrusted": false}`
///
/// Keys split on "."; each segment is trimmed and empty segments are dropped (" a..b " names "a.b"). Dictionaries are
/// walked into names up to `maxDepth` levels (deeper ones become one JSON object value); every other value is one
/// setting. When two spellings give the same name, the one reached through fewer dictionary levels wins (the flat,
/// explicit spelling), then the first in key order. Values: strings, booleans and numbers map to JSON, arrays to JSON
/// arrays and dictionaries inside them to JSON objects, dates to ISO 8601 strings and data to base64 strings.
/// Other values and non-finite numbers are skipped. At most `maxEntries` names are kept (in key order).
struct ManagedConfigParser {
    static let maxDepth = 8
    static let maxEntries = 512
    /// Nesting budget for one value (arrays and dictionaries inside a setting's value).
    static let valueBudget = 16

    struct Output: Equatable {
        /// Setting names relative to "managed." → values.
        var values: [String: JSONValue] = [:]
        /// Keys (as spelled, joined with ".") that were not converted, lost to another spelling or did not fit.
        var skipped: [String] = []
    }

    private struct Candidate {
        var value: JSONValue
        var level: Int
        var source: String
    }

    static func parse(_ dictionary: [String: Any]) -> Output {
        var candidates: [String: Candidate] = [:]
        var skipped: [String] = []
        walk(dictionary, path: [], spelled: [], level: 0, into: &candidates, skipped: &skipped)
        var out = Output()
        for (name, c) in candidates { out.values[name] = c.value }
        out.skipped = skipped.sorted()
        return out
    }

    private static func walk(_ dictionary: [String: Any], path: [String], spelled: [String], level: Int,
                             into candidates: inout [String: Candidate], skipped: inout [String]) {
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key] else { continue }
            let source = (spelled + [key]).joined(separator: ".")
            let segments = self.segments(key)
            guard !segments.isEmpty else {
                skipped.append(source)
                continue
            }
            let full = path + segments
            if let child = value as? [String: Any], level + 1 < maxDepth {
                walk(child, path: full, spelled: spelled + [key], level: level + 1, into: &candidates, skipped: &skipped)
                continue
            }
            guard let json = convert(value) else {
                skipped.append(source)
                continue
            }
            let name = full.joined(separator: ".")
            if let existing = candidates[name] {
                if existing.level <= level {
                    skipped.append(source)
                    continue
                }
                skipped.append(existing.source)
            } else if candidates.count >= maxEntries {
                skipped.append(source)
                continue
            }
            candidates[name] = Candidate(value: json, level: level, source: source)
        }
    }

    /// Name segments of one key: split on ".", trimmed, empty ones dropped.
    static func segments(_ key: String) -> [String] {
        key.split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Property-list value → JSON; nil when it has no JSON form.
    static func convert(_ value: Any, budget: Int = valueBudget) -> JSONValue? {
        switch value {
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            return d.isFinite ? .number(d) : nil
        case let d as Date:
            return .string(dateFormatter.string(from: d))
        case let d as Data:
            return .string(d.base64EncodedString())
        case let a as [Any]:
            guard budget > 0 else { return nil }
            // Positions matter in a list: an element without a JSON form becomes null instead of shifting the rest.
            return .array(a.map { convert($0, budget: budget - 1) ?? .null })
        case let o as [String: Any]:
            guard budget > 0 else { return nil }
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if let j = convert(v, budget: budget - 1) { out[k] = j }
            }
            return .object(out)
        case is NSNull:
            return .null
        default:
            return nil
        }
    }
}

// MARK: - Source

/// Where the managed configuration comes from (the app's defaults in the app; a scratch suite in tests).
protocol ManagedConfigSource: AnyObject {
    /// The current managed configuration; nil when the device has none (every sideloaded build).
    func managedConfiguration() -> [String: Any]?
}

/// Reads `com.apple.configuration.managed`, which iOS writes into the managed domain of the app's defaults.
final class UserDefaultsManagedConfigSource: ManagedConfigSource {
    static let key = "com.apple.configuration.managed"
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func managedConfiguration() -> [String: Any]? {
        defaults.dictionary(forKey: Self.key)
    }
}

// MARK: - Reader

/// What one refresh changed: full setting names ("managed.…").
struct ManagedConfigChange: Equatable {
    var changed: [String] = []
    var removed: [String] = []
    var isEmpty: Bool { changed.isEmpty && removed.isEmpty }
}

/// Mirrors the managed configuration into the read-only "managed." settings.
@MainActor
final class ManagedConfigReader {
    static let serviceKey = "managed.reader"
    static let prefix = "managed."
    /// Emitted after a refresh that changed anything. Payload {"changed": [name], "removed": [name]}.
    static let changedEvent = "managed.changed"
    static let log = Logger(subsystem: "app.nib", category: "managed")

    let settings: SettingsStore
    let events: EventBus
    let source: ManagedConfigSource
    /// The last parsed configuration (names relative to "managed.").
    private(set) var values: [String: JSONValue] = [:]
    private var lastRaw: NSDictionary?
    private var hasRead = false
    /// Per-key declarations made this session → whether the key is currently configured.
    private var declared: [String: Bool] = [:]
    private var observers: ObserverBag?
    private var refreshPending = false

    init(settings: SettingsStore, events: EventBus, source: ManagedConfigSource) {
        self.settings = settings
        self.events = events
        self.source = source
    }

    var isObserving: Bool { observers != nil }

    /// Re-reads the managed configuration and applies it. Without `force`, an unchanged dictionary costs one
    /// comparison and writes nothing (the settings writes below post UserDefaults changes of their own).
    @discardableResult
    func refresh(force: Bool = false) -> ManagedConfigChange {
        let raw = source.managedConfiguration()
        let snapshot = raw.map { $0 as NSDictionary }
        if !force, hasRead, snapshot == lastRaw { return ManagedConfigChange() }
        hasRead = true
        lastRaw = snapshot
        let parsed = ManagedConfigParser.parse(raw ?? [:])
        if !parsed.skipped.isEmpty {
            Self.log.warning("managed configuration: skipped \(parsed.skipped.count) key(s) without a usable value")
        }
        return apply(parsed.values)
    }

    /// Writes the parsed values and removes names the configuration no longer has. These are the only writes of
    /// "managed." settings: they come from the MDM server, and no caller may change them (the descriptor is
    /// read-only), which is why they are not a command.
    private func apply(_ parsed: [String: JSONValue]) -> ManagedConfigChange {
        var change = ManagedConfigChange()
        var desired: [String: JSONValue] = [:]
        for (key, value) in parsed { desired[Self.prefix + key] = value }
        for (name, value) in desired.sorted(by: { $0.key < $1.key }) {
            declare(name, configured: true)
            if settings.json(name) != value {
                settings.setJSON(name, value)
                change.changed.append(name)
            }
        }
        for name in settings.names(prefix: Self.prefix) where desired[name] == nil && settings.json(name) != nil {
            settings.setJSON(name, nil)
            change.removed.append(name)
        }
        for (name, configured) in declared where configured && desired[name] == nil {
            declare(name, configured: false)
        }
        values = parsed
        if !change.isEmpty {
            Self.log.info("managed configuration: \(change.changed.count) changed, \(change.removed.count) removed")
            events.emit(Self.changedEvent, payload: [
                "changed": .array(change.changed.map { JSONValue.string($0) }),
                "removed": .array(change.removed.map { JSONValue.string($0) })
            ])
        }
        return change
    }

    /// Declares one key on its own so `settings.list {prefix: "managed."}` names it. A key the server stops sending
    /// keeps its declaration (SettingsStore cannot undeclare) with a summary saying so; its value reads as null.
    private func declare(_ name: String, configured: Bool) {
        guard declared[name] != configured else { return }
        declared[name] = configured
        let summary = configured
            ? "Managed App Configuration value set by the device's MDM server (read-only)."
            : "Managed App Configuration value the MDM server no longer sets (read-only; reads as null)."
        settings.declare(SettingKey<JSONValue>(name, default: .null), summary: summary, owner: FeatManagedConfigFeature.id,
                         schema: .anything("value pushed by the MDM server"), readOnly: true)
    }

    /// Refreshes after every UserDefaults change and whenever the app returns to the foreground. Notifications may
    /// arrive on any thread: each one hops to the main actor, and a burst of them schedules a single refresh.
    func startObserving(center: NotificationCenter = .default) {
        guard observers == nil else { return }
        let names = [UserDefaults.didChangeNotification, UIApplication.willEnterForegroundNotification]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.noteChange() }
            }
        }
        observers = ObserverBag(center: center, tokens: tokens)
    }

    func stopObserving() {
        observers = nil
    }

    /// Schedules one refresh behind the notifications already queued on the main actor. The flag is cleared before
    /// reading, so a change made while the refresh runs schedules another one.
    private func noteChange() {
        guard isObserving, !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.refreshPending = false
            // A refresh still queued when observing stopped is dropped.
            guard self.isObserving else { return }
            self.refresh()
        }
    }
}

/// Removes its notification observers when released.
final class ObserverBag {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}
