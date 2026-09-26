import Foundation
import Security

/// A typed setting. `synced` settings live in the library (travel with the library folder);
/// the rest are per device (UserDefaults). Names starting with "security." can only be changed by the user.
public struct SettingKey<Value: Codable> {
    public let name: String
    public let defaultValue: Value
    public let synced: Bool

    public init(_ name: String, default defaultValue: Value, synced: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.synced = synced
    }
}

/// Library-level synced settings storage (implemented by the Library Store feature: `.nib-library/prefs.<device>.json`,
/// merged per key by rev). Collections are stored as ONE KEY PER ENTRY ("calendar.notes.<eventId>",
/// "writing.dictionary.<word>", "timer.history.<id>", "text.styles.<name>"; null = removed) so concurrent additions
/// on two devices never overwrite each other.
public protocol SyncedSettingsBackend: AnyObject {
    func value(_ name: String) -> JSONValue?
    func setValue(_ name: String, _ value: JSONValue?)
    /// Every stored name (for prefix enumeration).
    func names() -> [String]
}

/// Metadata of a declared setting: sync routing, `settings.list` / `settings.describe`, validation.
public struct SettingDescriptor {
    /// Full name, or a prefix ending in "." for a family of per-entry keys.
    public let name: String
    public let synced: Bool
    public let summary: String
    public let owner: String
    public let schema: JSONSchema
    public let defaultValue: JSONValue
    /// Only code writes it (e.g. "managed.*"): `settings.set` rejects it for every caller.
    public let readOnly: Bool
    public var isPrefix: Bool { name.hasSuffix(".") }
    /// "security.*": commands may read or change it only as the user.
    public var userOnly: Bool { name.hasPrefix("security.") }
}

/// Thread-safe settings store. Posts `SettingsStore.didChange` with userInfo ["name": String].
/// Every setting is DECLARED at register time (`declare` / `declarePrefix`); `NibApp.init` declares `NibSettings`.
public final class SettingsStore {
    public static let didChange = Notification.Name("NibSettingsDidChange")
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var synced: [String: Bool] = [:]
    private var declared: [String: SettingDescriptor] = [:]
    private var prefixes: [String: SettingDescriptor] = [:]
    private var undeclared = Set<String>()
    public var syncedBackend: SyncedSettingsBackend?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Declarations

    /// Declares a typed setting (call once in `register`). Declared names route to the synced backend even for
    /// untyped callers (AI, plugins, bridge), appear in `settings.list`, and `settings.set` validates against `schema`.
    public func declare<V: Codable>(_ key: SettingKey<V>, summary: String, owner: String,
                                    schema: JSONSchema = .anything(), readOnly: Bool = false) {
        let d = SettingDescriptor(name: key.name, synced: key.synced, summary: summary, owner: owner, schema: schema,
                                  defaultValue: (try? JSONValue.from(key.defaultValue)) ?? .null, readOnly: readOnly)
        lock.lock()
        declared[key.name] = d
        synced[key.name] = key.synced
        lock.unlock()
    }

    /// Declares a family of per-entry keys sharing `prefix` (must end in "."), e.g. "calendar.notes.", "plugin.<id>.".
    public func declarePrefix(_ prefix: String, synced flag: Bool, summary: String, owner: String,
                              schema: JSONSchema = .anything(), readOnly: Bool = false) {
        let d = SettingDescriptor(name: prefix, synced: flag, summary: summary, owner: owner, schema: schema,
                                  defaultValue: .null, readOnly: readOnly)
        lock.lock()
        prefixes[prefix] = d
        lock.unlock()
    }

    /// Exact declaration, else the longest declared prefix.
    public func descriptor(_ name: String) -> SettingDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if let d = declared[name] { return d }
        return prefixes.values.filter { name.hasPrefix($0.name) }.max { $0.name.count < $1.name.count }
    }

    public var declaredSettings: [SettingDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return (Array(declared.values) + Array(prefixes.values)).sorted { $0.name < $1.name }
    }

    /// Typed keys read or written without a declaration (conformance fails on any).
    public var undeclaredNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return undeclared.sorted()
    }

    /// Stored names starting with `prefix` (synced backend and this device).
    public func names(prefix: String) -> [String] {
        var out = Set(syncedBackend?.names().filter { $0.hasPrefix(prefix) } ?? [])
        let device = "nib.setting."
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(device + prefix) {
            out.insert(String(k.dropFirst(device.count)))
        }
        return out.sorted()
    }

    // MARK: Access

    public func get<V: Codable>(_ key: SettingKey<V>) -> V {
        remember(key.name, synced: key.synced)
        guard let json = raw(key.name, synced: key.synced), let v = try? json.decode(V.self) else { return key.defaultValue }
        return v
    }

    public func set<V: Codable>(_ key: SettingKey<V>, _ value: V) {
        remember(key.name, synced: key.synced)
        guard let json = try? JSONValue.from(value) else { return }
        store(key.name, json, synced: key.synced)
    }

    /// Untyped access (settings.get / settings.set commands, plugin settings "plugin.<id>.<key>").
    public func json(_ name: String) -> JSONValue? {
        raw(name, synced: isSynced(name))
    }

    public func setJSON(_ name: String, _ value: JSONValue?) {
        store(name, value, synced: isSynced(name))
    }

    /// Names seen so far (declared or used).
    public var knownNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return synced.keys.sorted()
    }

    private func remember(_ name: String, synced flag: Bool) {
        let isDeclared = descriptor(name) != nil
        lock.lock()
        synced[name] = flag
        if !isDeclared { undeclared.insert(name) }
        lock.unlock()
    }

    private func isSynced(_ name: String) -> Bool {
        if let d = descriptor(name) { return d.synced }
        lock.lock()
        defer { lock.unlock() }
        return synced[name] ?? false
    }

    private func raw(_ name: String, synced flag: Bool) -> JSONValue? {
        if flag, let backend = syncedBackend { return backend.value(name) }
        guard let s = defaults.string(forKey: "nib.setting." + name) else { return nil }
        return try? JSONValue.parse(s)
    }

    private func store(_ name: String, _ value: JSONValue?, synced flag: Bool) {
        if flag, let backend = syncedBackend {
            backend.setValue(name, value)
        } else if let v = value {
            defaults.set(v.jsonString(), forKey: "nib.setting." + name)
        } else {
            defaults.removeObject(forKey: "nib.setting." + name)
        }
        NotificationCenter.default.post(name: SettingsStore.didChange, object: self, userInfo: ["name": name])
    }
}

/// Settings shared by several features. Feature-private settings use "<featureId>.<name>".
public enum NibSettings {
    public static let authorName = SettingKey("profile.authorName", default: "")
    public static let scrollDirection = SettingKey("editing.scrollDirection", default: ScrollDirection.vertical, synced: true)
    public static let openAsTabs = SettingKey("editing.openAsTabs", default: true, synced: true)
    public static let undoButtonsOnRight = SettingKey("editing.undoOnRight", default: false, synced: true)
    public static let objectTapSelection = SettingKey("editing.objectTapSelection", default: true, synced: true)
    public static let alignObjects = SettingKey("editing.alignObjects", default: true, synced: true)
    public static let snapToGrid = SettingKey("editing.snapToGrid", default: false, synced: true)
    public static let hideStatusBar = SettingKey("editing.hideStatusBar", default: false)
    public static let zoomAutoAdvance = SettingKey("editing.zoomAutoAdvance", default: true, synced: true)
    public static let sidebarOnRight = SettingKey("editing.sidebarOnRight", default: false, synced: true)
    public static let stylusMode = SettingKey("stylus.mode", default: StylusMode.pencilOnly)
    /// 0 = low (recommended), 1 = medium, 2 = high.
    public static let palmSensitivity = SettingKey("stylus.palmSensitivity", default: 0)
    /// 0…7: handedness × wrist angle = hand × 4 + wrist (contracts-v2, pinned). Hand: 0 right, 1 left. Wrist: 0 below
    /// the line, 1 angled, 2 level, 3 hooked. 0 (right hand, wrist below) is the default. Palm rejection (F101) and
    /// Settings (F027) share this layout.
    public static let writingPosture = SettingKey("stylus.posture", default: 0)
    public static let reduceLatency = SettingKey("pen.reduceLatency", default: true, synced: true)
    public static let defaultLanguage = SettingKey("language.default", default: "en-US", synced: true)
    public static let indexHandwriting = SettingKey("search.indexHandwriting", default: true)
    public static let spellcheckNewDocuments = SettingKey("writing.spellcheckNewDocuments", default: false, synced: true)
    public static let mathAssistSuggestions = SettingKey("writing.mathAssist", default: false, synced: true)
    /// Personal dictionary: one synced key per word ("writing.dictionary.<word>" = true; null = removed).
    public static let dictionaryPrefix = "writing.dictionary."
    public static func dictionaryWord(_ word: String) -> SettingKey<Bool> {
        SettingKey(dictionaryPrefix + word.lowercased(), default: false, synced: true)
    }
    public static let aiConfirmationPolicy = SettingKey("security.ai.confirmationPolicy", default: ConfirmationPolicy.destructive)
    public static let bridgeConfirmationPolicy = SettingKey("security.bridge.confirmationPolicy", default: ConfirmationPolicy.destructive)
    /// Expose plugin commands that opted out with `ai: false` / `bridge: false` anyway (user only).
    public static let exposeHiddenPluginCommands = SettingKey("security.plugins.exposeHiddenCommands", default: false)
    public static let pluginGalleries = SettingKey("plugins.galleries", default: [String](), synced: true)
    public static let experimental = SettingKey("advanced.experimental", default: [String: Bool]())
    public static let defaultPaper = SettingKey("templates.defaultPaper", default: TemplateRef("builtin.ruled"), synced: true)
    public static let defaultCover = SettingKey("templates.defaultCover", default: TemplateRef("cover.solid"), synced: true)
    public static let defaultPageSize = SettingKey("templates.defaultSize", default: PageSize.a4, synced: true)
    public static let coverByDefault = SettingKey("templates.coverByDefault", default: true, synced: true)

    // contracts-v2

    /// Settings › Appearance › Liquid: "full" | "calm" | "off" (NibDesign's `NibLiquidMode` raw values). Every droplet
    /// container reads it (the document chrome, the toolbar palette, the library). Device-local.
    public static let liquidMode = SettingKey("appearance.liquid", default: "full")
    /// Style of new text boxes (F026 "Save as Default"); paste-and-match-style (F014) and page text (F028) use it.
    public static let defaultTextStyle = SettingKey("text.defaultStyle", default: TextBoxStyle(), synced: true)
    /// Draw and Hold: a held pen or pencil stroke snaps to a shape (F007 reads it, F030 owns the behaviour).
    public static let drawAndHold = SettingKey("shapes.drawAndHold", default: true, synced: true)
    /// Name of the AI direct-tools setting (owned and declared by the AI Agent, F084): [command id]. Unset =
    /// `defaultAIDirectTools`. The bridge (F090) reads it untyped.
    public static let aiDirectToolsName = "ai.directTools"
    /// AI.md §4: commands offered to models as their own tools besides the meta-tools.
    public static let defaultAIDirectTools = ["ink.writeText", "ink.setPoints", "text.createBox", "item.update",
                                              "item.delete", "page.add", "shape.create", "diagram.create"]

    /// Eraser settings owned by F010, read by the Zoom Window pane (F038) and the Pencil hover preview (F043).
    /// Mode: "precision" | "standard" | "stroke".
    public static let eraserMode = SettingKey("eraser.mode", default: "standard", synced: true)
    /// Eraser diameter in SCREEN points (2…60).
    public static let eraserSize = SettingKey("eraser.size", default: 14.0, synced: true)
    /// Erase Filter: whether the eraser erases strokes drawn with `tool` (one key per ink tool).
    public static func eraserFilter(_ tool: InkTool) -> SettingKey<Bool> {
        SettingKey("eraser.filter." + tool.rawValue, default: true, synced: true)
    }

    public static let presetTools = ["pen", "pencil", "highlighter", "tape", "shape", "drawShape"]

    /// Color / thickness presets of a writing tool (`presetTools`).
    public static func presets(_ tool: String) -> SettingKey<ToolPresets> {
        SettingKey("presets." + tool, default: ToolPresets.defaults(for: tool), synced: true)
    }

    /// Declares every shared setting (called by `NibApp.init`; owner "builtin").
    public static func declareAll(_ s: SettingsStore) {
        let bool = JSONSchema.bool()
        s.declare(authorName, summary: "Author name shown on sticky notes, comments and collaboration.", owner: "builtin", schema: .str())
        s.declare(scrollDirection, summary: "Default page scrolling for new documents.", owner: "builtin",
                  schema: .str(choices: ScrollDirection.allCases.map { $0.rawValue }))
        s.declare(openAsTabs, summary: "Open documents as tabs instead of replacing the current one.", owner: "builtin", schema: bool)
        s.declare(undoButtonsOnRight, summary: "Show undo/redo on the right of the toolbar.", owner: "builtin", schema: bool)
        s.declare(objectTapSelection, summary: "Finger tap selects objects (quick selection).", owner: "builtin", schema: bool)
        s.declare(alignObjects, summary: "Show alignment guides while moving objects.", owner: "builtin", schema: bool)
        s.declare(snapToGrid, summary: "Snap moved objects to the template grid.", owner: "builtin", schema: bool)
        s.declare(hideStatusBar, summary: "Hide the iOS status bar in documents.", owner: "builtin", schema: bool)
        s.declare(zoomAutoAdvance, summary: "Zoom Window advances automatically.", owner: "builtin", schema: bool)
        s.declare(sidebarOnRight, summary: "Show the document sidebar on the right.", owner: "builtin", schema: bool)
        s.declare(stylusMode, summary: "pencilOnly = fingers scroll; anyInput = fingers draw.", owner: "builtin",
                  schema: .str(choices: StylusMode.allCases.map { $0.rawValue }))
        s.declare(palmSensitivity, summary: "Palm rejection sensitivity 0 low, 1 medium, 2 high.", owner: "builtin", schema: .int(min: 0, max: 2))
        s.declare(writingPosture, summary: "Writing posture 0…7 (handedness × wrist angle).", owner: "builtin", schema: .int(min: 0, max: 7))
        s.declare(reduceLatency, summary: "Use predicted touches for lower ink latency.", owner: "builtin", schema: bool)
        s.declare(defaultLanguage, summary: "Default handwriting recognition language (BCP-47).", owner: "builtin", schema: .str())
        s.declare(indexHandwriting, summary: "Index handwriting for search on this device.", owner: "builtin", schema: bool)
        s.declare(spellcheckNewDocuments, summary: "Turn on handwriting spellcheck for new documents.", owner: "builtin", schema: bool)
        s.declare(mathAssistSuggestions, summary: "Offer Math Assist answers for handwritten equations.", owner: "builtin", schema: bool)
        s.declarePrefix(dictionaryPrefix, synced: true, summary: "Personal dictionary words (true = in dictionary).",
                        owner: "builtin", schema: bool)
        s.declare(aiConfirmationPolicy, summary: "When AI actions need confirmation (user only).", owner: "builtin",
                  schema: .str(choices: ConfirmationPolicy.allCases.map { $0.rawValue }))
        s.declare(bridgeConfirmationPolicy, summary: "When bridge actions need confirmation (user only).", owner: "builtin",
                  schema: .str(choices: ConfirmationPolicy.allCases.map { $0.rawValue }))
        s.declare(exposeHiddenPluginCommands, summary: "Expose plugin commands marked ai:false/bridge:false (user only).",
                  owner: "builtin", schema: bool)
        s.declare(pluginGalleries, summary: "Gallery index URLs for plugins and content packs.", owner: "builtin", schema: .arr(.str()))
        s.declare(experimental, summary: "Experimental feature toggles.", owner: "builtin")
        s.declare(defaultPaper, summary: "Default paper template {id, params}.", owner: "builtin")
        s.declare(defaultCover, summary: "Default cover template {id, params}.", owner: "builtin")
        s.declare(defaultPageSize, summary: "Default page size {width, height} in points.", owner: "builtin")
        s.declare(coverByDefault, summary: "New notebooks get a cover page.", owner: "builtin", schema: bool)
        for tool in presetTools {
            s.declare(presets(tool), summary: "Colour and thickness presets of the \(tool) tool.", owner: "builtin")
        }
        s.declarePrefix("managed.", synced: false, summary: "Managed App Configuration values (read-only).",
                        owner: "builtin", readOnly: true)
        s.declare(liquidMode, summary: "Liquid chrome: full, calm (half stretch, no necks) or off (solid, no motion).",
                  owner: "builtin", schema: .str(choices: ["full", "calm", "off"]))
        s.declare(defaultTextStyle, summary: "Style of new text boxes: TextBoxStyle fields, optionally align and lineSpacing.",
                  owner: "builtin", schema: .anything("TextBoxStyle object"))
        s.declare(drawAndHold, summary: "Hold the pen still at the end of a stroke to snap it to a shape.", owner: "builtin",
                  schema: bool)
        s.declare(eraserMode, summary: "Eraser mode: precision, standard or stroke.", owner: "builtin",
                  schema: .str(choices: ["precision", "standard", "stroke"]))
        s.declare(eraserSize, summary: "Eraser diameter in screen points.", owner: "builtin", schema: .num(min: 2, max: 60))
        for tool in InkTool.allCases {
            s.declare(eraserFilter(tool), summary: "The eraser erases \(tool.rawValue) strokes.", owner: "builtin", schema: bool)
        }
    }
}

// MARK: - Keychain

/// Where `Keychain` keeps secrets. Swappable because hostless package tests have no entitlements (SecItemAdd fails
/// with -34018); `Harness` installs NibTesting's `InMemorySecretStore`.
public protocol SecretStore: AnyObject {
    func set(_ data: Data?, service: String, account: String) -> Bool
    func get(service: String, account: String) -> Data?
}

/// The system Keychain (generic passwords, this device only).
public final class SystemKeychainStore: SecretStore {
    public init() {}

    public func set(_ data: Data?, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = data else { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

/// Secrets (API keys, WebDAV passwords, bridge token). Device-only, never synced, never exposed to plugins or AI.
/// Re-signing with another team changes the Keychain access group: features that find a secret missing show
/// "credentials missing — re-enter" instead of failing silently.
public enum Keychain {
    public static var store: SecretStore = SystemKeychainStore()

    @discardableResult
    public static func set(_ data: Data?, service: String, account: String) -> Bool {
        store.set(data, service: service, account: account)
    }

    public static func get(service: String, account: String) -> Data? {
        store.get(service: service, account: account)
    }

    @discardableResult
    public static func setString(_ value: String?, service: String, account: String) -> Bool {
        set(value.map { Data($0.utf8) }, service: service, account: account)
    }

    public static func getString(service: String, account: String) -> String? {
        get(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Stable random per-install device id (HLC tiebreaker, per-device package files). Mirrored to
/// Application Support/Nib/device-id, which wins over the Keychain: a re-signed build (new Keychain access group)
/// or a failing Keychain keeps the same id instead of starting a new set of per-device files every launch.
public enum DeviceIdentity {
    private static var cached: UInt32?

    static var mirrorURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/device-id")
    }

    public static var current: UInt32 {
        if let c = cached { return c }
        func decode(_ d: Data?) -> UInt32? {
            guard let d = d, d.count == 4 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        let mirrored = decode(mirrorURL.flatMap { try? Data(contentsOf: $0) })
        let stored = decode(Keychain.get(service: "app.nib.device", account: "id"))
        let value = mirrored ?? stored ?? UInt32.random(in: 1...UInt32.max)
        var le = value
        let data = Data(bytes: &le, count: 4)
        if stored != value { Keychain.set(data, service: "app.nib.device", account: "id") }
        if mirrored == nil, let url = mirrorURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        cached = value
        return value
    }

    /// 8 lowercase hex characters, used in package file names ("doc.<hex>.json").
    public static var hex: String { String(format: "%08x", current) }
}

/// Optional App Group container — a progressive enhancement, never required. AltStore/SideStore register app
/// groups even for free Apple IDs and list the rewritten ids in Info.plist "ALTAppGroups"; "NibAppGroups" lists the
/// ids the build asked for. nil when no group is usable: callers fall back (static widgets, pasteboard hand-off).
public enum AppGroup {
    public static var containerURL: URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        let ids = ((info["ALTAppGroups"] as? [String]) ?? []) + ((info["NibAppGroups"] as? [String]) ?? [])
        for id in ids {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        }
        return nil
    }
}
