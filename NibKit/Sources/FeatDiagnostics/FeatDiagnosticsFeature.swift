import Foundation
import SwiftUI
import UIKit
import os
import NibContracts
import NibDesign

/// Diagnostics, troubleshooting and safe mode (F076: P-092, P-093, P-100, P-101, N-026).
///
/// - Settings › Advanced › Troubleshooting (`TroubleshootingPage`): export diagnostics through the share sheet, Report
///   an Issue (GitHub and email), the safe-mode banner and switches for features and plugins, Experimental toggles, and
///   the state of Temporary Diagnostic Mode.
/// - `diagnostics.export {includeTitles?}` builds the zip (`DiagnosticsExporter`); it never holds note content.
/// - `diagnostics.setFeatureEnabled {id, enabled}` writes `SafeMode.disabledFeatures` (applied at the next launch by the
///   app shell) or, for "plugin:<id>", turns the plugin off or on through `plugin.enable`.
/// - Temporary Diagnostic Mode: the `nib_temp_diagnostic` switch in the iOS Settings app (Nib/Settings.bundle) makes the
///   next launch zip the raw library into Documents/diagnostics, then turns itself off.
/// - Crash-loop protection (N-026): the shell's `SafeMode` counts launches that never finished; this feature snapshots
///   the result at registration (the shell resets the counter once every feature started) and tells the person.
public enum FeatDiagnosticsFeature: NibFeature {
    public static let id = "diagnostics"

    public static func register(_ app: NibApp) {
        let runtime = DiagnosticsRuntime(safeMode: SystemSafeModeStore())
        app.services.set(runtime, for: DiagnosticsRuntime.serviceKey)
        app.commands.register(DiagnosticsExportCommand.self)
        app.commands.register(DiagnosticsSetFeatureEnabledCommand.self)

        var page = SettingsPageDescriptor(id: DiagnosticsIDs.settingsPage, title: String(localized: "Troubleshooting"),
                                          icon: NibSymbol.diagnostics.name, section: .advanced, order: 10,
                                          owner: id) { app in
            AnyView(TroubleshootingPage(app: app, runtime: DiagnosticsRuntime.resolve(app.services)))
        }
        page.keywords = DiagnosticsIDs.keywords
        app.ui.settingsPages.register(page)
    }

    public static func start(_ app: NibApp) async {
        DiagnosticsRuntime.resolve(app.services).start(app)
    }
}

// MARK: - Names

enum DiagnosticsIDs {
    /// `FeatDiagnosticsFeature.id`, usable off the main actor.
    static let feature = "diagnostics"
    static let settingsPage = "diagnostics.troubleshooting"
    static let exportCommand = "diagnostics.export"
    static let setFeatureEnabledCommand = "diagnostics.setFeatureEnabled"
    /// `diagnostics.setFeatureEnabled {id: "plugin:<plugin id>"}` switches a plugin.
    static let pluginPrefix = "plugin:"
    /// Documents/diagnostics: where Temporary Diagnostic Mode leaves the library copy (visible in the Files app).
    static let libraryCopyFolder = "diagnostics"

    static var keywords: [String] {
        String(localized: "diagnostics, logs, safe mode, crash, report, issue, bug, feedback, support, experimental, beta, plugins, features, temporary diagnostic mode")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Safe mode storage

/// The shell's crash-loop state (`SafeMode`), behind a protocol so tests never touch the process's real defaults.
protocol SafeModeStore: AnyObject {
    /// Two launches in a row died before finishing: this launch is in safe mode (plugins are not started).
    var isActive: Bool { get }
    /// Feature ids the shell skips at launch.
    var disabledFeatures: Set<String> { get set }
}

final class SystemSafeModeStore: SafeModeStore {
    var isActive: Bool { SafeMode.isActive }

    var disabledFeatures: Set<String> {
        get { SafeMode.disabledFeatures }
        set { SafeMode.disabledFeatures = newValue }
    }
}

/// The Settings.bundle switch "Temporary Diagnostic Mode" (P-093).
protocol TemporaryDiagnosticSwitch: AnyObject {
    var isOn: Bool { get }
    func turnOff()
}

/// Reads the switch the iOS Settings app writes into the app's own defaults domain. `UserDefaults()` is that domain;
/// SettingsStore cannot read it (it keeps its values under "nib.setting.<name>"), see contract gaps.
final class SettingsBundleSwitch: TemporaryDiagnosticSwitch {
    static let key = "nib_temp_diagnostic"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults()) {
        self.defaults = defaults
    }

    var isOn: Bool { defaults.bool(forKey: SettingsBundleSwitch.key) }

    func turnOff() {
        defaults.set(false, forKey: SettingsBundleSwitch.key)
    }
}

// MARK: - Feature catalogue

/// Every feature entry id (ARCHITECTURE.md §3) with a readable name, so safe mode can list them. Split features name
/// their first half as `parent`: the second half cannot run without it.
struct FeatureInfo: Equatable {
    let id: String
    let title: String
    let parent: String?

    init(_ id: String, _ title: String, parent: String? = nil) {
        self.id = id
        self.title = title
        self.parent = parent
    }
}

enum FeatureCatalog {
    /// Nib needs these to open the library at all (and this one to turn the others back on).
    static let required: Set<String> = [DiagnosticsIDs.feature, "store", "library", "sync"]

    static let all: [FeatureInfo] = [
        FeatureInfo("store", String(localized: "Document storage")),
        FeatureInfo("library", String(localized: "Library storage")),
        FeatureInfo("query", String(localized: "Query and node API")),
        FeatureInfo("render", String(localized: "Page rendering")),
        FeatureInfo("templates", String(localized: "Paper templates and covers")),
        FeatureInfo("canvas", String(localized: "Canvas")),
        FeatureInfo("canvasinput", String(localized: "Canvas input and palm rejection"), parent: "canvas"),
        FeatureInfo("pen", String(localized: "Pen and pencil")),
        FeatureInfo("presets", String(localized: "Tool presets and colour picker")),
        FeatureInfo("highlighter", String(localized: "Highlighter")),
        FeatureInfo("eraser", String(localized: "Eraser")),
        FeatureInfo("lasso", String(localized: "Lasso and selection")),
        FeatureInfo("transform", String(localized: "Moving and resizing selections")),
        FeatureInfo("objectmenu", String(localized: "Object menu")),
        FeatureInfo("clipboard", String(localized: "Copy, paste and drag and drop")),
        FeatureInfo("undo", String(localized: "Undo and history")),
        FeatureInfo("toolbar", String(localized: "Toolbar")),
        FeatureInfo("chrome", String(localized: "Document bars and panels")),
        FeatureInfo("windows", String(localized: "Tabs and windows")),
        FeatureInfo("libraryui", String(localized: "Library browser")),
        FeatureInfo("organize", String(localized: "Folders, favourites and trash")),
        FeatureInfo("create", String(localized: "New documents and QuickNote")),
        FeatureInfo("pages", String(localized: "Page management")),
        FeatureInfo("sidebar", String(localized: "Page thumbnails")),
        FeatureInfo("pdf", String(localized: "PDF engine")),
        FeatureInfo("sync", String(localized: "Folder sync and library location")),
        FeatureInfo("text", String(localized: "Text boxes")),
        FeatureInfo("settings", String(localized: "Settings screens")),
        FeatureInfo("pagetext", String(localized: "Full-page typing")),
        FeatureInfo("links", String(localized: "Links")),
        FeatureInfo("shaperec", String(localized: "Shape recognition")),
        FeatureInfo("shapes", String(localized: "Shapes")),
        FeatureInfo("diagrams", String(localized: "Connectors and diagrams")),
        FeatureInfo("tape", String(localized: "Tape")),
        FeatureInfo("images", String(localized: "Images and camera")),
        FeatureInfo("elements", String(localized: "Elements and stickers")),
        FeatureInfo("sticky", String(localized: "Sticky notes")),
        FeatureInfo("comments", String(localized: "Comments")),
        FeatureInfo("zoomwindow", String(localized: "Zoom Window")),
        FeatureInfo("ruler", String(localized: "Ruler")),
        FeatureInfo("laser", String(localized: "Laser pointer")),
        FeatureInfo("layers", String(localized: "Layers")),
        FeatureInfo("readonly", String(localized: "Read-only mode and PDF text")),
        FeatureInfo("pencilhw", String(localized: "Apple Pencil hover, double-tap and squeeze")),
        FeatureInfo("whiteboard", String(localized: "Whiteboards")),
        FeatureInfo("templateui", String(localized: "Template management")),
        FeatureInfo("outline", String(localized: "Outline and bookmarks")),
        FeatureInfo("textdoc", String(localized: "Text documents")),
        FeatureInfo("textdocedit", String(localized: "Text document editing tools"), parent: "textdoc"),
        FeatureInfo("textdocextras", String(localized: "Text document comments and export"), parent: "textdoc"),
        FeatureInfo("tables", String(localized: "Text document tables")),
        FeatureInfo("studyeditor", String(localized: "Study set editor")),
        FeatureInfo("studysession", String(localized: "Practice and Smart Learn")),
        FeatureInfo("studyio", String(localized: "Study set import and export")),
        FeatureInfo("audio", String(localized: "Audio recording and playback")),
        FeatureInfo("replay", String(localized: "Note replay")),
        FeatureInfo("transcription", String(localized: "Transcription")),
        FeatureInfo("index", String(localized: "Search index and handwriting recognition")),
        FeatureInfo("searchui", String(localized: "Search")),
        FeatureInfo("convert", String(localized: "Convert handwriting to text")),
        FeatureInfo("smartink", String(localized: "Edit handwriting")),
        FeatureInfo("inksynth", String(localized: "Handwriting synthesis")),
        FeatureInfo("spellcheck", String(localized: "Handwriting spellcheck"), parent: "inksynth"),
        FeatureInfo("restyle", String(localized: "Handwriting restyle and Writing Aids"), parent: "inksynth"),
        FeatureInfo("math", String(localized: "Maths items and typesetting")),
        FeatureInfo("mathassist", String(localized: "Maths engine")),
        FeatureInfo("mathassistoverlay", String(localized: "Math Assist"), parent: "mathassist"),
        FeatureInfo("mathgraph", String(localized: "Maths graphs"), parent: "mathassist"),
        FeatureInfo("timekeeper", String(localized: "Time Keeper")),
        FeatureInfo("presentation", String(localized: "Presentation mode")),
        FeatureInfo("import", String(localized: "Import")),
        FeatureInfo("scan", String(localized: "Scan documents")),
        FeatureInfo("export", String(localized: "Export engine")),
        FeatureInfo("exportui", String(localized: "Export, share and print")),
        FeatureInfo("backup", String(localized: "Backup")),
        FeatureInfo("webdav", String(localized: "WebDAV sync")),
        FeatureInfo("syncui", String(localized: "Sync status and repair")),
        FeatureInfo("lock", String(localized: "Password lock")),
        FeatureInfo("collab", String(localized: "Collaboration")),
        FeatureInfo("collabpresence", String(localized: "Collaboration presence and Shared tab"), parent: "collab"),
        FeatureInfo("keyboard", String(localized: "Keyboard shortcuts and pointer")),
        FeatureInfo("system", String(localized: "Shortcuts, widgets and deep links")),
        FeatureInfo("calendar", String(localized: "Calendar")),
        FeatureInfo("diagnostics", String(localized: "Diagnostics and safe mode")),
        FeatureInfo("pluginruntime", String(localized: "Plugin runtime")),
        FeatureInfo("pluginhost", String(localized: "Plugin host")),
        FeatureInfo("plugininstall", String(localized: "Plugin install")),
        FeatureInfo("pluginmanager", String(localized: "Plugin manager and gallery")),
        FeatureInfo("pluginpanels", String(localized: "Plugin panels")),
        FeatureInfo("aiproviders", String(localized: "AI providers")),
        FeatureInfo("aiagent", String(localized: "AI agent")),
        FeatureInfo("aichat", String(localized: "Assistant")),
        FeatureInfo("aisettings", String(localized: "AI provider settings")),
        FeatureInfo("aiactions", String(localized: "AI actions")),
        FeatureInfo("aimath", String(localized: "Solve and Teach Me")),
        FeatureInfo("meetingai", String(localized: "Meeting notes")),
        FeatureInfo("bridge", String(localized: "MCP bridge")),
        FeatureInfo("bridgeui", String(localized: "Bridge settings")),
        FeatureInfo("relay", String(localized: "Collaboration relay")),
        FeatureInfo("onboarding", String(localized: "Onboarding")),
        FeatureInfo("appearance", String(localized: "Appearance and app icons")),
        FeatureInfo("a11y", String(localized: "Languages and accessibility")),
        FeatureInfo("managed", String(localized: "Managed configuration")),
        FeatureInfo("about", String(localized: "About and privacy")),
        FeatureInfo("teacher", String(localized: "Answer zones and scoring")),
        FeatureInfo("teacherlessons", String(localized: "Lessons and assignments"), parent: "teacher"),
        FeatureInfo("teacherinsights", String(localized: "Class insights"), parent: "teacher"),
        FeatureInfo("performance", String(localized: "Performance and memory")),
    ]

    static let ids: Set<String> = Set(all.map { $0.id })

    private static let byID: [String: FeatureInfo] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// The readable name; an id this build does not know (a newer feature) shows as itself.
    static func title(_ id: String) -> String { byID[id]?.title ?? id }

    static func parent(of id: String) -> String? { byID[id]?.parent }

    static func children(of id: String) -> [String] { all.filter { $0.parent == id }.map { $0.id } }
}

/// What turning one feature on or off does to the whole set (pure; the command applies it).
enum FeatureToggleRules {
    struct Change: Equatable {
        /// Feature ids off at the next launch.
        var disabled: Set<String>
        /// Other ids switched along with the requested one (a split feature's halves).
        var alsoChanged: [String]
    }

    static func apply(id: String, enabled: Bool, disabled: Set<String>, known: Set<String>) throws -> Change {
        guard known.contains(id) else {
            throw NibError(.notFound, "unknown feature '\(id)'", path: "$.id",
                           hint: "use a feature id such as 'laser' (features.json in diagnostics.export lists them) or 'plugin:<plugin id>'")
        }
        var next = disabled
        var also: [String] = []
        if enabled {
            next.remove(id)
            // The second half of a split feature needs its first half.
            if let parent = FeatureCatalog.parent(of: id), next.remove(parent) != nil { also.append(parent) }
        } else {
            guard !FeatureCatalog.required.contains(id) else {
                throw NibError(.invalidParams, "'\(id)' can't be turned off: Nib needs it to open the library",
                               path: "$.id", hint: "turn off another feature, or report the problem with diagnostics.export")
            }
            next.insert(id)
            for child in FeatureCatalog.children(of: id) {
                if next.insert(child).inserted { also.append(child) }
            }
        }
        return Change(disabled: next, alsoChanged: also)
    }
}

// MARK: - Experimental toggles (P-101)

/// A local feature flag in `NibSettings.experimental` (the substitute for TestFlight builds and remote flags).
struct ExperimentalFlag: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// The feature that reads the flag; nil for a flag this build does not describe.
    let owner: String?
}

enum ExperimentalFlags {
    /// Diagnostics exports keep the whole process log: debug messages and every system framework's messages.
    static let detailedLogs = "diagnostics.detailedLogs"

    /// Flags this build describes. A flag is listed only while its owner runs, so no switch here does nothing.
    static var known: [ExperimentalFlag] {
        [ExperimentalFlag(id: detailedLogs, title: String(localized: "Detailed diagnostics"),
                          detail: String(localized: "Exports also keep debug messages and what the system frameworks logged. They take longer, get larger and help trace rare problems."),
                          owner: DiagnosticsIDs.feature)]
    }

    /// Known flags whose owner runs, then every other flag stored in the setting (set by a plugin, the assistant or a
    /// newer version), so each one can still be switched off.
    static func visible(values: [String: Bool], running: Set<String>) -> [ExperimentalFlag] {
        let described = known.filter { flag in flag.owner.map { running.contains($0) } ?? true }
        let knownIDs = Set(known.map { $0.id })
        let others = values.keys.filter { !knownIDs.contains($0) }.sorted().map { key in
            ExperimentalFlag(id: key, title: key,
                             detail: String(localized: "This version of Nib doesn't describe this experiment."),
                             owner: nil)
        }
        return described + others
    }
}

// MARK: - Runtime

/// Temporary Diagnostic Mode's library copy.
enum LibraryCopyState: Equatable {
    case idle
    case running
    case done(name: String, bytes: Int64)
    case failed(String)
}

/// One per app (service "diagnostics.runtime"): the safe-mode snapshot taken at launch, the injectable system seams
/// (safe-mode storage, log source, share sheet, Settings.bundle switch) and the library-copy state the page shows.
@MainActor
final class DiagnosticsRuntime: ObservableObject {
    static let serviceKey = "diagnostics.runtime"

    var safeMode: SafeModeStore
    /// Safe mode as the shell saw it when this launch registered its features (the shell resets the counter as soon as
    /// every feature started, so `SafeMode.isActive` is false again by the time anyone looks).
    var launchedInSafeMode: Bool
    /// The feature ids the shell skipped in this launch.
    var disabledAtLaunch: Set<String>
    var logSource: DiagnosticsLogSource = ProcessLogSource()
    var sharing: DiagnosticsSharing = SystemDiagnosticsSharing()
    var diagnosticSwitch: TemporaryDiagnosticSwitch = SettingsBundleSwitch()
    /// Where exports are built (emptied before each one).
    var exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nib-diagnostics", isDirectory: true)
    var documentsDirectory: URL

    @Published private(set) var libraryCopy: LibraryCopyState = .idle
    /// Bumped whenever a safe-mode choice changes, so an open page re-reads them.
    @Published private(set) var revision = 0

    private let log = Logger(subsystem: "app.nib", category: "diagnostics")
    private var notice: SafeModeNotice?

    init(safeMode: SafeModeStore) {
        self.safeMode = safeMode
        launchedInSafeMode = safeMode.isActive
        disabledAtLaunch = safeMode.disabledFeatures
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// The app's runtime (installed by `register`; created on demand for a bus built without it).
    static func resolve(_ services: NibServices) -> DiagnosticsRuntime {
        if let runtime = services.get(serviceKey, as: DiagnosticsRuntime.self) { return runtime }
        let runtime = DiagnosticsRuntime(safeMode: SystemSafeModeStore())
        services.set(runtime, for: serviceKey)
        return runtime
    }

    var libraryCopyFolder: URL {
        documentsDirectory.appendingPathComponent(DiagnosticsIDs.libraryCopyFolder, isDirectory: true)
    }

    func start(_ app: NibApp) {
        if launchedInSafeMode {
            log.notice("Launched in safe mode; features off: \(self.disabledAtLaunch.sorted().joined(separator: ","), privacy: .public)")
        }
        if !NibApp.isHostlessTest {
            startTemporaryDiagnosticModeIfRequested(libraryRoot: app.services.library?.rootURL)
            if launchedInSafeMode {
                let notice = SafeModeNotice()
                self.notice = notice
                notice.presentWhenReady(app)
            }
        }
    }

    func noteChoicesChanged() {
        revision += 1
    }

    /// P-093: when the Settings.bundle switch is on, turns it off first (a crash while copying must not repeat on every
    /// launch), then zips the raw library into Documents/diagnostics off the main actor.
    @discardableResult
    func startTemporaryDiagnosticModeIfRequested(libraryRoot: URL?) -> Task<LibraryCopyState, Never>? {
        guard diagnosticSwitch.isOn, libraryCopy != .running else { return nil }
        diagnosticSwitch.turnOff()
        let root = libraryRoot ?? documentsDirectory
        let folder = libraryCopyFolder
        let log = self.log
        libraryCopy = .running
        log.notice("Temporary Diagnostic Mode: copying the library")
        let work = Task.detached(priority: .utility) { () -> LibraryCopyState in
            do {
                let result = try LibraryArchiver.archive(root: root, into: folder, stamp: Date())
                log.notice("Temporary Diagnostic Mode: \(result.files) files, \(result.bytes) bytes copied")
                return .done(name: result.url.lastPathComponent, bytes: result.bytes)
            } catch {
                log.error("Temporary Diagnostic Mode failed: \(String(describing: error), privacy: .public)")
                return .failed(DiagnosticsRuntime.message(for: error))
            }
        }
        return Task { @MainActor in
            let state = await work.value
            self.libraryCopy = state
            return state
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case LibraryArchiver.Failure.notEnoughSpace(let needed, _):
            return String(localized: "There isn't enough free space to copy the library. It needs about \(DiagnosticsFormat.bytes(needed)).")
        case LibraryArchiver.Failure.missingLibrary:
            return String(localized: "Nib couldn't find the library folder to copy.")
        default:
            return String(localized: "Nib couldn't copy the library: \(error.localizedDescription)")
        }
    }
}

// MARK: - Commands

/// `diagnostics.export {includeTitles?}` (P-092).
struct DiagnosticsExportCommand: NibCommand {
    struct Params: Codable {
        var includeTitles: Bool?
    }

    struct Output: Codable, Equatable {
        /// The zip as a temporary asset ("tmp:<name>", one hour); nil when no asset store is installed.
        var file: String?
        var name: String
        var bytes: Int
        /// Files inside the zip.
        var entries: [String]
        var includesTitles: Bool
        var logLines: Int
        /// The share sheet was shown.
        var shared: Bool
        /// Report an Issue links prefilled with the summary.
        var reportURL: String?
        var mailURL: String?
    }

    static let descriptor = CommandDescriptor(
        id: "diagnostics.export", title: "Export Diagnostics",
        summary: "Zip this session's logs, device info, features, plugins and library counts (titles only with includeTitles; never note content) and share it → {file: tmp:, bytes, entries}.",
        params: .obj(["includeTitles": .bool("also list document and folder titles (default false)")]),
        examples: [[:], ["includeTitles": true]],
        effect: .read, target: .app, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let runtime = DiagnosticsRuntime.resolve(ctx.services)
        let includeTitles = p.includeTitles ?? false
        var pluginList: JSONValue?
        if ctx.bus.registry.entry(CommandIDs.pluginList) != nil {
            pluginList = try? await ctx.execute(CommandIDs.pluginList)
        }
        let input = DiagnosticsCollector.collect(app: ctx.app, services: ctx.services, runtime: runtime,
                                                 includeTitles: includeTitles, pluginList: pluginList)
        let directory = runtime.exportDirectory
        let assets = ctx.services.assets
        let built = try await Task.detached(priority: .userInitiated) { () throws -> (DiagnosticsArchive, String?) in
            let archive = try DiagnosticsExporter.build(input, in: directory)
            var file: String?
            if let assets = assets {
                let data = try Data(contentsOf: archive.url, options: .mappedIfSafe)
                file = "tmp:" + (try assets.putTemporary(data, ext: "zip")).name
            }
            return (archive, file)
        }.value
        let archive = built.0
        let shared = runtime.sharing.share(archive.url, navigator: ctx.navigator)
        Logger(subsystem: "app.nib", category: "diagnostics")
            .notice("Diagnostics exported: \(archive.bytes) bytes, \(archive.logLines) log lines, titles \(includeTitles)")
        return Output(file: built.1, name: archive.name, bytes: archive.bytes, entries: archive.entries,
                      includesTitles: includeTitles, logLines: archive.logLines, shared: shared,
                      reportURL: IssueReport.githubURL(summary: input.summary)?.absoluteString,
                      mailURL: IssueReport.mailURL(summary: input.summary)?.absoluteString)
    }
}

/// `diagnostics.setFeatureEnabled {id, enabled}` (N-026).
struct DiagnosticsSetFeatureEnabledCommand: NibCommand {
    struct Params: Codable {
        var id: String
        var enabled: Bool
    }

    struct Output: Codable, Equatable {
        var id: String
        var enabled: Bool
        /// Registered in this launch (nil for a plugin).
        var running: Bool?
        /// Close and reopen Nib to apply.
        var pendingRelaunch: Bool
        /// Every feature id off at the next launch.
        var disabled: [String]
        /// The other half of a split feature, switched along with it.
        var alsoChanged: [String]
    }

    static let descriptor = CommandDescriptor(
        id: "diagnostics.setFeatureEnabled", title: "Turn Feature On or Off",
        summary: "Safe mode: turn a feature (id such as 'laser') or 'plugin:<id>' on or off; features change at the next launch → {id, enabled, pendingRelaunch, disabled}.",
        params: .obj(["id": .str("feature id such as 'laser', or 'plugin:<plugin id>'"),
                      "enabled": .bool("false turns it off")], required: ["id", "enabled"]),
        examples: [["id": "laser", "enabled": false]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let runtime = DiagnosticsRuntime.resolve(ctx.services)
        let log = Logger(subsystem: "app.nib", category: "diagnostics")
        let id = p.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw NibError.invalid("missing the feature id", path: "$.id") }

        if id.hasPrefix(DiagnosticsIDs.pluginPrefix) {
            let plugin = String(id.dropFirst(DiagnosticsIDs.pluginPrefix.count))
            guard !plugin.isEmpty else {
                throw NibError.invalid("missing the plugin id after 'plugin:'", path: "$.id")
            }
            _ = try await ctx.execute(CommandIDs.pluginEnable, ["id": .string(plugin), "enabled": .bool(p.enabled)])
            runtime.noteChoicesChanged()
            log.notice("Plugin \(plugin, privacy: .public) turned \(p.enabled ? "on" : "off", privacy: .public)")
            return Output(id: id, enabled: p.enabled, running: nil, pendingRelaunch: false,
                          disabled: runtime.safeMode.disabledFeatures.sorted(), alsoChanged: [])
        }

        let running = Set(ctx.app?.featureIDs ?? [])
        let known = FeatureCatalog.ids.union(running).union(runtime.safeMode.disabledFeatures)
            .union(runtime.disabledAtLaunch)
        let change = try FeatureToggleRules.apply(id: id, enabled: p.enabled, disabled: runtime.safeMode.disabledFeatures,
                                                  known: known)
        runtime.safeMode.disabledFeatures = change.disabled
        runtime.noteChoicesChanged()
        log.notice("Feature \(id, privacy: .public) turned \(p.enabled ? "on" : "off", privacy: .public) for the next launch")
        let isRunning = running.contains(id)
        let pending = isRunning ? !p.enabled : (p.enabled && runtime.disabledAtLaunch.contains(id))
        return Output(id: id, enabled: p.enabled, running: isRunning, pendingRelaunch: pending,
                      disabled: change.disabled.sorted(), alsoChanged: change.alsoChanged)
    }
}
