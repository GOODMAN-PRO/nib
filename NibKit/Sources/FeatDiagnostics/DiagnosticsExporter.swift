import Foundation
import UIKit
import OSLog
import NibContracts

// Diagnostics export (P-092), the Report an Issue summary (P-100) and the raw library copy of Temporary Diagnostic
// Mode (P-093). Everything here is data and file work: the reports are value types collected on the main actor
// (`DiagnosticsCollector`), and the zip is built off the main actor (`DiagnosticsExporter`, `LibraryArchiver`).
//
// Privacy rule (the acceptance line): a diagnostics zip never holds note content. It carries counts, ids, settings
// whose values are switches or fixed choices, feature and plugin lists and this process's log. Document and folder
// titles appear only with `includeTitles`; without it every library title is also masked in the log.

// MARK: - Logs

/// One line of this process's unified log.
struct DiagnosticsLogLine: Equatable {
    var date: Date
    var level: String
    var subsystem: String
    var category: String
    var message: String
}

/// Where the export reads its log (the process's `OSLogStore`; tests inject lines).
protocol DiagnosticsLogSource {
    /// The newest `limit` entries of this process, oldest first. By default Nib's own messages (debug level left out)
    /// and every error or fault of the process; `detailed` keeps everything, debug messages and system frameworks too.
    func lines(detailed: Bool, limit: Int) throws -> [DiagnosticsLogLine]
}

/// `OSLogStore(scope: .currentProcessIdentifier)`: what this process logged since launch. Nib's features log under
/// the "app.nib" subsystem (MetricKit summaries from F100 included). Private arguments stay redacted. The store is
/// filtered by a predicate first: reading every framework message of a long session takes many seconds.
struct ProcessLogSource: DiagnosticsLogSource {
    static let subsystem = "app.nib"

    func lines(detailed: Bool, limit: Int) throws -> [DiagnosticsLogLine] {
        guard limit > 0 else { return [] }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = detailed ? nil : NSPredicate(
            format: "subsystem BEGINSWITH %@ OR messageType == error OR messageType == fault", ProcessLogSource.subsystem)
        let entries: AnySequence<OSLogEntry>
        do {
            entries = try store.getEntries(with: [], at: nil, matching: predicate)
        } catch where predicate != nil {
            // A store that cannot filter: read everything and filter below.
            entries = try store.getEntries()
        }
        var kept: [DiagnosticsLogLine] = []
        for entry in entries {
            guard let log = entry as? OSLogEntryLog, detailed || ProcessLogSource.keeps(log) else { continue }
            kept.append(DiagnosticsLogLine(date: log.date, level: ProcessLogSource.name(of: log.level),
                                           subsystem: log.subsystem, category: log.category,
                                           message: log.composedMessage))
            // Keep the newest `limit` lines without holding the whole log.
            if kept.count >= limit * 2 { kept.removeFirst(kept.count - limit) }
        }
        return Array(kept.suffix(limit))
    }

    static func keeps(_ log: OSLogEntryLog) -> Bool {
        switch log.level {
        case .error, .fault: return true
        case .debug: return false
        default: return log.subsystem.hasPrefix(subsystem)
        }
    }

    static func name(of level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "log"
        @unknown default: return "log"
        }
    }
}

/// Masks library titles in free text (log lines can name a document or a folder in a message or a path).
struct DiagnosticsRedactor {
    static let placeholder = "\u{2039}title\u{203A}"
    /// Titles shorter than this are left alone: masking every "ab" would garble the log without protecting anything.
    static let minimumLength = 3

    /// Longest first, so "Physics 9702" is masked before "Physics".
    let titles: [String]

    init(titles: [String]) {
        let cleaned = Set(titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= DiagnosticsRedactor.minimumLength }
        self.titles = cleaned.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    func redact(_ text: String) -> String {
        guard !titles.isEmpty, !text.isEmpty else { return text }
        let s = NSMutableString(string: text)
        for title in titles {
            s.replaceOccurrences(of: title, with: DiagnosticsRedactor.placeholder, options: [.literal],
                                 range: NSRange(location: 0, length: s.length))
        }
        return s as String
    }
}

// MARK: - Reports

struct DiagnosticsAppInfo: Codable, Equatable {
    var name: String
    var version: String
    var build: String
    var bundleID: String
    /// This install's per-device id (package file names "doc.<hex>.json"); random, not tied to the person.
    var deviceHex: String
    /// "debug" or "release".
    var configuration: String
    var launchedInSafeMode: Bool
    /// Settings › Appearance › Liquid.
    var liquid: String
}

struct DiagnosticsDeviceInfo: Codable, Equatable {
    var system: String
    var systemVersion: String
    /// Hardware identifier such as "iPad14,3" (the simulated model on the simulator).
    var model: String
    var idiom: String
    var locale: String
    var languages: [String]
    var memoryBytes: UInt64
    var processors: Int
    var thermalState: String
    var lowPowerMode: Bool
    var diskFreeBytes: Int64?
    var diskTotalBytes: Int64?
    var contentSize: String
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var voiceOver: Bool
    var boldText: Bool
}

struct DiagnosticsFeaturesReport: Codable, Equatable {
    struct Feature: Codable, Equatable {
        var id: String
        var title: String
        /// Registered in this launch.
        var running: Bool
        /// On at the next launch.
        var enabled: Bool
        var required: Bool
    }

    var launchedInSafeMode: Bool
    var features: [Feature]
    /// Off at the next launch (`SafeMode.disabledFeatures`).
    var turnedOff: [String]
    var turnsOffAtNextLaunch: [String]
    var turnsOnAtNextLaunch: [String]
    /// `NibSettings.experimental`.
    var experiments: [String: Bool]
}

/// One installed plugin, read leniently from `plugin.list` (F078), whatever extra fields it carries.
struct DiagnosticsPlugin: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var version: String
    var enabled: Bool
    var needsReview: Bool
    var permissions: [String]
    var source: String?

    init(id: String, name: String, version: String = "", enabled: Bool = true, needsReview: Bool = false,
         permissions: [String] = [], source: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.needsReview = needsReview
        self.permissions = permissions
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, name, version, enabled, needsReview, permissions, source, state }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        let state = (try? c.decodeIfPresent(String.self, forKey: .state))?.lowercased()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled))
            ?? state.map { ["enabled", "running", "loaded", "on"].contains($0) } ?? true
        needsReview = (try? c.decodeIfPresent(Bool.self, forKey: .needsReview)) ?? (state == "needsreview")
        permissions = (try? c.decodeIfPresent([String].self, forKey: .permissions)) ?? []
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(needsReview, forKey: .needsReview)
        try c.encode(permissions, forKey: .permissions)
        try c.encodeIfPresent(source, forKey: .source)
    }

    /// `plugin.list` output: a bare array, or an object holding it under "plugins" or "installed".
    static func list(from value: JSONValue?) -> [DiagnosticsPlugin] {
        guard let value = value else { return [] }
        let items = value.arrayValue ?? value["plugins"]?.arrayValue ?? value["installed"]?.arrayValue ?? []
        return items.compactMap { try? $0.decode(DiagnosticsPlugin.self) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct DiagnosticsPluginsReport: Codable, Equatable {
    /// False when this build has no plugin host (or safe mode turned the plugin features off).
    var available: Bool
    /// Plugins never run in a safe-mode launch.
    var runningInThisLaunch: Bool
    var plugins: [DiagnosticsPlugin]
}

struct DiagnosticsLibraryReport: Codable, Equatable {
    struct Document: Codable, Equatable {
        var id: String
        var title: String
        var kind: String
        var pages: Int?
        var folder: String?
        var modified: String
        var locked: Bool
    }

    struct Folder: Codable, Equatable {
        var id: String
        var title: String
        var path: String
    }

    struct Storage: Codable, Equatable {
        var files: Int
        var bytes: Int64
        var packages: Int
        var packageBytes: Int64
        /// `.nib-library` (trash, plugins, prefs, templates, AI chats).
        var metadataBytes: Int64
        /// The walk stopped at its file limit.
        var truncated: Bool
    }

    var available: Bool
    /// appContainer | iCloudDrive | fileProvider | other | unknown.
    var location: String
    /// Documents per kind (notebook, whiteboard, textDocument, studySet).
    var documents: [String: Int]
    var folders: Int
    var pages: Int
    var favourites: Int
    var locked: Int
    var trashed: Int
    /// Documents per sync badge.
    var sync: [String: Int]
    var storage: Storage?
    var titlesIncluded: Bool
    /// Only with `includeTitles`.
    var documentList: [Document]?
    var folderList: [Folder]?

    var documentCount: Int { documents.values.reduce(0, +) }

    static let unavailable = DiagnosticsLibraryReport(available: false, location: "unknown", documents: [:], folders: 0,
                                                      pages: 0, favourites: 0, locked: 0, trashed: 0, sync: [:],
                                                      storage: nil, titlesIncluded: false, documentList: nil,
                                                      folderList: nil)
}

struct DiagnosticsSettingReport: Codable, Equatable {
    var name: String
    var owner: String
    var synced: Bool
    /// Differs from its default (a family: has entries).
    var customised: Bool
    /// Only for switches, numbers and fixed choices; never `security.*`, `profile.*` or free text.
    var value: JSONValue?
    /// Stored entries of a per-entry family ("writing.dictionary.", "plugin.<id>."), counted, never listed.
    var entries: Int?
}

/// Which setting values a diagnostics export may carry.
enum DiagnosticsSettingsPolicy {
    static func exposesValue(_ d: SettingDescriptor) -> Bool {
        guard !d.isPrefix, !d.name.hasPrefix("security."), !d.name.hasPrefix("profile.") else { return false }
        switch d.schema {
        case .boolean, .integer, .number: return true
        case .string(_, let choices): return choices != nil
        default: return false
        }
    }

    static func report(_ store: SettingsStore) -> [DiagnosticsSettingReport] {
        store.declaredSettings.map { d -> DiagnosticsSettingReport in
            if d.isPrefix {
                let count = store.names(prefix: d.name).count
                return DiagnosticsSettingReport(name: d.name, owner: d.owner, synced: d.synced, customised: count > 0,
                                                value: nil, entries: count)
            }
            let current = store.json(d.name)
            let customised = current.map { $0 != .null && $0 != d.defaultValue } ?? false
            return DiagnosticsSettingReport(name: d.name, owner: d.owner, synced: d.synced, customised: customised,
                                            value: exposesValue(d) ? (current ?? d.defaultValue) : nil, entries: nil)
        }
    }
}

// MARK: - Summary and Report an Issue

/// The plain-text summary used by summary.txt, the GitHub issue and the email (English: it is read by whoever fixes
/// the problem). Counts only, never titles.
enum DiagnosticsSummary {
    static func text(app: DiagnosticsAppInfo, device: DiagnosticsDeviceInfo, features: DiagnosticsFeaturesReport,
                     plugins: DiagnosticsPluginsReport, library: DiagnosticsLibraryReport, generated: Date) -> String {
        var lines: [String] = []
        lines.append("Nib \(app.version) (\(app.build))" + (app.configuration == "debug" ? ", debug build" : ""))
        lines.append("\(device.system) \(device.systemVersion) on \(device.model)")
        lines.append("Safe mode: " + (features.launchedInSafeMode ? "on for this launch" : "off"))
        lines.append("Features turned off: " + list(features.turnedOff))
        if !features.turnsOffAtNextLaunch.isEmpty || !features.turnsOnAtNextLaunch.isEmpty {
            lines.append("Waiting for a relaunch: off " + list(features.turnsOffAtNextLaunch)
                         + "; on " + list(features.turnsOnAtNextLaunch))
        }
        if plugins.available {
            let on = plugins.plugins.filter { $0.enabled }.count
            lines.append("Plugins: \(plugins.plugins.count) installed, \(on) on"
                         + (plugins.runningInThisLaunch ? "" : ", none running in safe mode"))
        } else {
            lines.append("Plugins: not available in this launch")
        }
        let experiments = features.experiments.filter { $0.value }.keys.sorted()
        lines.append("Experiments on: " + list(experiments))
        if library.available {
            let d = library.documents
            lines.append("Library: \(library.documentCount) documents (\(d["notebook"] ?? 0) notebooks, "
                         + "\(d["whiteboard"] ?? 0) whiteboards, \(d["textDocument"] ?? 0) text documents, "
                         + "\(d["studySet"] ?? 0) study sets), \(library.folders) folders, \(library.pages) pages, "
                         + "stored in \(library.location)")
        } else {
            lines.append("Library: not available")
        }
        lines.append("Generated \(DiagnosticsFormat.iso(generated))")
        return lines.joined(separator: "\n")
    }

    private static func list(_ items: [String]) -> String {
        guard !items.isEmpty else { return "none" }
        let shown = items.prefix(40).joined(separator: ", ")
        return items.count > 40 ? shown + " and \(items.count - 40) more" : shown
    }
}

/// Report an Issue (P-100): a new GitHub issue and an email, both prefilled with the summary. Nib has no support
/// server, so the email has no fixed recipient: the person chooses who gets it.
enum IssueReport {
    static let repository = "https://github.com/GOODMAN-PRO/nib"
    static let title = "Problem report"
    /// GitHub refuses very long URLs; the summary is cut well below that.
    static let maxBodyLength = 6_000

    static func body(summary: String) -> String {
        var text = """
        **What happened**


        **Steps to reproduce**
        1.

        **Diagnostics**
        ```
        \(summary)
        ```

        Attach the diagnostics zip from Settings > Advanced > Troubleshooting > Export Diagnostics.
        """
        if text.count > maxBodyLength { text = String(text.prefix(maxBodyLength)) }
        return text
    }

    static func githubURL(summary: String) -> URL? {
        URL(string: repository + "/issues/new?title=" + encode(title) + "&body=" + encode(body(summary: summary)))
    }

    static func mailURL(summary: String) -> URL? {
        let text = body(summary: summary).replacingOccurrences(of: "\n", with: "\r\n")
        return URL(string: "mailto:?subject=" + encode("Nib: " + title) + "&body=" + encode(text))
    }

    /// Percent-encodes everything but the RFC 3986 unreserved set, so "&", "+", "#" and "=" in the text survive.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

// MARK: - Collection (main actor)

/// Everything the export needs, captured on the main actor; the zip is then built off it.
struct DiagnosticsInput {
    var generated: Date
    var includeTitles: Bool
    var detailedLogs: Bool
    var app: DiagnosticsAppInfo
    var device: DiagnosticsDeviceInfo
    var features: DiagnosticsFeaturesReport
    var plugins: DiagnosticsPluginsReport
    var library: DiagnosticsLibraryReport
    var settings: [DiagnosticsSettingReport]
    var summary: String
    /// Library titles masked in the log when titles are left out.
    var titles: [String]
    var libraryRoot: URL?
    var logSource: DiagnosticsLogSource
    var logLimit: Int = 20_000
}

@MainActor
enum DiagnosticsCollector {
    static func collect(app: NibApp?, services: NibServices, runtime: DiagnosticsRuntime, includeTitles: Bool,
                        pluginList: JSONValue?, generated: Date = Date()) -> DiagnosticsInput {
        let settings = services.settings
        let experiments = settings.get(NibSettings.experimental)
        let appInfo = self.appInfo(app: app, settings: settings, runtime: runtime)
        let device = deviceInfo()
        let features = self.features(running: app?.featureIDs ?? [], runtime: runtime, experiments: experiments)
        let plugins = DiagnosticsPluginsReport(available: pluginList != nil,
                                               runningInThisLaunch: !runtime.launchedInSafeMode,
                                               plugins: DiagnosticsPlugin.list(from: pluginList))
        let (library, titles) = self.library(services.library, includeTitles: includeTitles,
                                             documents: runtime.documentsDirectory)
        let summary = DiagnosticsSummary.text(app: appInfo, device: device, features: features, plugins: plugins,
                                              library: library, generated: generated)
        return DiagnosticsInput(generated: generated, includeTitles: includeTitles,
                                detailedLogs: experiments[ExperimentalFlags.detailedLogs] ?? false,
                                app: appInfo, device: device, features: features, plugins: plugins, library: library,
                                settings: DiagnosticsSettingsPolicy.report(settings), summary: summary, titles: titles,
                                libraryRoot: services.library?.rootURL, logSource: runtime.logSource)
    }

    static func appInfo(app: NibApp?, settings: SettingsStore, runtime: DiagnosticsRuntime) -> DiagnosticsAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "Nib"
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return DiagnosticsAppInfo(name: name,
                                  version: (info["CFBundleShortVersionString"] as? String) ?? "unknown",
                                  build: (info["CFBundleVersion"] as? String) ?? "unknown",
                                  bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                                  deviceHex: app?.deviceHex ?? "",
                                  configuration: configuration,
                                  launchedInSafeMode: runtime.launchedInSafeMode,
                                  liquid: settings.get(NibSettings.liquidMode))
    }

    static func deviceInfo() -> DiagnosticsDeviceInfo {
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        let volume = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return DiagnosticsDeviceInfo(system: device.systemName, systemVersion: device.systemVersion,
                                     model: modelIdentifier(), idiom: idiomName(device.userInterfaceIdiom),
                                     locale: Locale.current.identifier, languages: Locale.preferredLanguages,
                                     memoryBytes: process.physicalMemory, processors: process.activeProcessorCount,
                                     thermalState: thermalName(process.thermalState),
                                     lowPowerMode: process.isLowPowerModeEnabled,
                                     diskFreeBytes: volume?.volumeAvailableCapacityForImportantUsage,
                                     diskTotalBytes: volume?.volumeTotalCapacity.map { Int64($0) },
                                     contentSize: UITraitCollection.current.preferredContentSizeCategory.rawValue,
                                     reduceMotion: UIAccessibility.isReduceMotionEnabled,
                                     reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
                                     increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                                     voiceOver: UIAccessibility.isVoiceOverRunning,
                                     boldText: UIAccessibility.isBoldTextEnabled)
    }

    static func features(running: [String], runtime: DiagnosticsRuntime,
                         experiments: [String: Bool]) -> DiagnosticsFeaturesReport {
        let runningSet = Set(running)
        let off = runtime.safeMode.disabledFeatures
        let atLaunch = runtime.disabledAtLaunch
        let ids = runningSet.union(off).union(atLaunch).sorted()
        let features = ids.map { id in
            DiagnosticsFeaturesReport.Feature(id: id, title: FeatureCatalog.title(id), running: runningSet.contains(id),
                                              enabled: !off.contains(id), required: FeatureCatalog.required.contains(id))
        }
        return DiagnosticsFeaturesReport(launchedInSafeMode: runtime.launchedInSafeMode, features: features,
                                         turnedOff: off.sorted(),
                                         turnsOffAtNextLaunch: runningSet.intersection(off).sorted(),
                                         turnsOnAtNextLaunch: atLaunch.subtracting(off).sorted(),
                                         experiments: experiments)
    }

    /// Counts (and, with titles, the document and folder lists), plus every title for masking the log.
    static func library(_ library: LibraryService?, includeTitles: Bool,
                        documents: URL) -> (DiagnosticsLibraryReport, [String]) {
        guard let library = library else { return (.unavailable, []) }
        let nodes = library.allNodes()
        let trashed = library.trashedNodes()
        let docs = nodes.filter { $0.kind == .document }
        let folders = nodes.filter { $0.kind == .folder }
        var byKind: [String: Int] = [:]
        for kind in DocumentKind.allCases { byKind[kind.rawValue] = 0 }
        for d in docs { byKind[(d.documentKind ?? .notebook).rawValue, default: 0] += 1 }
        var sync: [String: Int] = [:]
        for d in docs { sync[d.sync.rawValue, default: 0] += 1 }
        var report = DiagnosticsLibraryReport(
            available: true, location: location(of: library.rootURL, documents: documents), documents: byKind,
            folders: folders.count, pages: docs.compactMap { $0.pageCount }.reduce(0, +),
            favourites: nodes.filter { $0.favorite }.count, locked: docs.filter { $0.locked }.count,
            trashed: trashed.count, sync: sync, storage: nil, titlesIncluded: includeTitles, documentList: nil,
            folderList: nil)
        if includeTitles {
            report.documentList = docs.sorted { $0.path < $1.path }.map { d in
                DiagnosticsLibraryReport.Document(id: d.id.raw, title: d.title,
                                                  kind: (d.documentKind ?? .notebook).rawValue, pages: d.pageCount,
                                                  folder: d.parent.flatMap { library.node($0)?.path },
                                                  modified: DiagnosticsFormat.iso(Date(timeIntervalSince1970: d.modified)),
                                                  locked: d.locked)
            }
            report.folderList = folders.sorted { $0.path < $1.path }.map {
                DiagnosticsLibraryReport.Folder(id: $0.id.raw, title: $0.title, path: $0.path)
            }
        }
        let titles = (nodes + trashed).flatMap { [$0.title] + $0.path.split(separator: "/").map(String.init) }
        return (report, titles)
    }

    /// Where the library lives, without the path (folder names are titles).
    static func location(of root: URL, documents: URL) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let docs = documents.standardizedFileURL.resolvingSymlinksInPath().path
        if path == docs || path.hasPrefix(docs + "/") { return "appContainer" }
        if path.contains("/Mobile Documents/") { return "iCloudDrive" }
        if path.contains("/File Provider Storage/") || path.contains("/CloudStorage/") { return "fileProvider" }
        return "other"
    }

    /// "iPad14,3"; on the simulator, the simulated model.
    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func idiomName(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .pad: return "pad"
        case .phone: return "phone"
        case .mac: return "mac"
        default: return "other"
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Export (off the main actor)

struct DiagnosticsArchive: Equatable {
    var url: URL
    var name: String
    var bytes: Int
    /// File names inside the zip's folder.
    var entries: [String]
    var logLines: Int
}

enum DiagnosticsExporter {
    /// Builds "Nib Diagnostics <stamp>.zip" in `directory` (emptied first: only the latest export is kept).
    static func build(_ input: DiagnosticsInput, in directory: URL) throws -> DiagnosticsArchive {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "Nib Diagnostics " + DiagnosticsFormat.fileStamp(input.generated)
        let url = directory.appendingPathComponent(name + ".zip")

        var library = input.library
        if let root = input.libraryRoot, library.available {
            library.storage = LibraryStorage.measure(root: root)
        }
        let redactor = DiagnosticsRedactor(titles: input.includeTitles ? [] : input.titles)
        var logText: String
        var logLines = 0
        do {
            let lines = try input.logSource.lines(detailed: input.detailedLogs, limit: input.logLimit)
            logLines = lines.count
            logText = redactor.redact(DiagnosticsFormat.logText(lines))
        } catch {
            logText = "The log could not be read: \(error.localizedDescription)\n"
        }

        let files: [(String, Data)] = [
            ("README.txt", Data(readme(input).utf8)),
            ("summary.txt", Data((input.summary + "\n").utf8)),
            ("device.json", try DiagnosticsFormat.json(DeviceFile(generated: DiagnosticsFormat.iso(input.generated),
                                                                   app: input.app, device: input.device))),
            ("features.json", try DiagnosticsFormat.json(input.features)),
            ("plugins.json", try DiagnosticsFormat.json(input.plugins)),
            ("library.json", try DiagnosticsFormat.json(library)),
            ("settings.json", try DiagnosticsFormat.json(input.settings)),
            ("logs.txt", Data(logText.utf8)),
        ]
        let writer = try ZipArchiveWriter(url: url)
        let folder = name + "/"
        try writer.addDirectory(folder, modified: input.generated)
        for (file, data) in files {
            try writer.addData(data, path: folder + file, modified: input.generated)
        }
        try writer.finish()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return DiagnosticsArchive(url: url, name: url.lastPathComponent, bytes: bytes, entries: files.map { $0.0 },
                                  logLines: logLines)
    }

    private struct DeviceFile: Codable {
        var generated: String
        var app: DiagnosticsAppInfo
        var device: DiagnosticsDeviceInfo
    }

    static func readme(_ input: DiagnosticsInput) -> String {
        """
        Nib diagnostics, generated \(DiagnosticsFormat.iso(input.generated)).

        summary.txt    what this report is about, in a few lines
        device.json    Nib version, iOS version, device model, memory, disk space and accessibility settings
        features.json  features running in this launch, the ones turned off for safe mode, experiments
        plugins.json   installed plugins with their versions and permissions
        library.json   how many documents, folders and pages the library has and where it is stored\
        \(input.includeTitles ? ", with document and folder titles" : "")
        settings.json  settings that are switches or fixed choices (free text and security settings are left out)
        logs.txt       what Nib logged since it was opened and any errors of the system frameworks\
        \(input.detailedLogs ? ", plus debug and system messages (Detailed diagnostics)" : "")\
        \(input.includeTitles ? "" : ", with library titles masked")

        Nothing in this archive comes from the contents of your notes.
        """
    }
}

/// Size of the library folder (counts and bytes; names are never recorded).
enum LibraryStorage {
    static func measure(root: URL, limit: Int = 500_000) -> DiagnosticsLibraryReport.Storage? {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return nil }
        let rootCount = root.standardizedFileURL.pathComponents.count
        var storage = DiagnosticsLibraryReport.Storage(files: 0, bytes: 0, packages: 0, packageBytes: 0,
                                                       metadataBytes: 0, truncated: false)
        for case let url as URL in walker {
            if storage.files >= limit {
                storage.truncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.pathExtension == NibFormat.packageExtension { storage.packages += 1 }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootCount)
            storage.files += 1
            storage.bytes += size
            if relative.first == NibFormat.libraryDirectory {
                storage.metadataBytes += size
            } else if relative.contains(where: { $0.hasSuffix("." + NibFormat.packageExtension) }) {
                storage.packageBytes += size
            }
        }
        return storage
    }
}

enum DiagnosticsFormat {
    /// "2026-09-30 14.12.05", safe in a file name.
    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func logText(_ lines: [DiagnosticsLogLine]) -> String {
        guard !lines.isEmpty else { return "No log entries.\n" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = ""
        out.reserveCapacity(lines.count * 96)
        for line in lines {
            let origin = line.subsystem.isEmpty ? line.category : line.subsystem + "/" + line.category
            out += f.string(from: line.date) + "  " + line.level.padding(toLength: 6, withPad: " ", startingAt: 0)
                + " " + origin + "  " + line.message.replacingOccurrences(of: "\n", with: "\n    ") + "\n"
        }
        return out
    }

    static func json<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - Temporary Diagnostic Mode: the raw library copy

enum LibraryArchiver {
    struct Result: Equatable {
        var url: URL
        var bytes: Int64
        var files: Int
    }

    enum Failure: Error, Equatable {
        case missingLibrary
        case notEnoughSpace(needed: Int64, available: Int64)
    }

    static let filePrefix = "Nib Library "
    /// Room left for the zip's own records and the rest of the system.
    static let spaceMargin: Int64 = 64 * 1_048_576

    /// Zips everything under `root` (hidden `.nib-library` included, symbolic links skipped, `excluding` and `folder`
    /// left out) into `folder/Nib Library <stamp>.zip`, through a hidden partial file that is renamed at the end.
    static func archive(root: URL, into folder: URL, stamp: Date, excluding: [URL] = [],
                        availableCapacity: (URL) -> Int64? = LibraryArchiver.availableCapacity) throws -> Result {
        let fm = FileManager.default
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.missingLibrary
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let skipped = (excluding + [folder]).compactMap { relativePath(of: $0, in: root) }

        struct Item {
            var url: URL
            var path: String
            var isDirectory: Bool
            var size: Int64
        }
        var items: [Item] = []
        var needed: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                      errorHandler: { _, _ in true }) {
            for case let url as URL in walker {
                guard let path = relativePath(of: url, in: root) else { continue }
                if skipped.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    walker.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    items.append(Item(url: url, path: path, isDirectory: true, size: 0))
                } else if values?.isRegularFile == true {
                    let size = Int64(values?.fileSize ?? 0)
                    needed += size + 128 + Int64(path.utf8.count) * 2
                    items.append(Item(url: url, path: path, isDirectory: false, size: size))
                }
            }
        }
        if let available = availableCapacity(folder), needed + spaceMargin > available {
            throw Failure.notEnoughSpace(needed: needed, available: available)
        }

        let name = filePrefix + DiagnosticsFormat.fileStamp(stamp) + ".zip"
        let partial = folder.appendingPathComponent("." + name + ".partial")
        let final = folder.appendingPathComponent(name)
        do {
            let writer = try ZipArchiveWriter(url: partial)
            let top = "Nib Library/"
            try writer.addDirectory(top, modified: stamp)
            var files = 0
            for item in items {
                if item.isDirectory {
                    try writer.addDirectory(top + item.path)
                } else {
                    // A file that went away (or cannot be read) since the walk is left out, not fatal.
                    do {
                        try writer.addFile(at: item.url, path: top + item.path)
                        files += 1
                    } catch ZipArchiveError.unreadable {
                        continue
                    }
                }
            }
            try writer.finish()
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            let bytes = Int64((try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return Result(url: final, bytes: bytes, files: files)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// `url` relative to `root` ("Physics/Waves.nibnote/doc.json"); nil when it is not inside it.
    static func relativePath(of url: URL, in root: URL) -> String? {
        func components(_ u: URL) -> [String] { u.standardizedFileURL.pathComponents }
        for (a, b) in [(components(url), components(root)),
                       (components(url.resolvingSymlinksInPath()), components(root.resolvingSymlinksInPath()))] {
            if a.count > b.count, Array(a.prefix(b.count)) == b { return a.dropFirst(b.count).joined(separator: "/") }
        }
        return nil
    }

    static func availableCapacity(_ url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// The newest library copy in `folder`, if any.
    static func latestCopy(in folder: URL) -> (name: String, bytes: Int64, date: Date)? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "zip" }
            .compactMap { url -> (name: String, bytes: Int64, date: Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url.lastPathComponent, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
            }
            .max { $0.date < $1.date }
    }
}

// MARK: - Zip archives

/// Why an archive could not be written.
enum ZipArchiveError: Error, Equatable {
    /// The file to add could not be opened (it went away, or is not readable).
    case unreadable(String)
    /// An entry grew past 4 GiB while it was read, after its header was written without ZIP64.
    case entryTooLarge(String)
    /// `finish()` already ran.
    case finished
}

/// CRC-32 as zip stores it (IEEE 802.3, reflected, polynomial EDB88320).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var register: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var c = register
        let table = CRC32.table
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        register = c
    }

    var checksum: UInt32 { register ^ 0xFFFF_FFFF }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.checksum
    }
}

/// A streaming zip writer: stored or deflated entries with UTF-8 names, Unix permissions, and ZIP64 records wherever
/// an entry, an offset or the entry count passes the classic limits (a library copy can pass 4 GiB). Generated files
/// are deflated with the Compression framework (raw DEFLATE, method 8); files on disk are streamed stored, 1 MiB at a
/// time, so memory stays flat whatever their size (PDFs, images and audio are compressed already).
final class ZipArchiveWriter {
    struct Entry {
        var name: [UInt8]
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var offset: UInt64
        var time: UInt16
        var date: UInt16
        var isDirectory: Bool
    }

    static let chunkSize = 1 << 20
    private static let max32: UInt64 = 0xFFFF_FFFF
    private static let max16 = 0xFFFF

    /// Writes ZIP64 fields for every entry and the end records (tests exercise the large-archive path with it).
    var forcesZip64 = false
    private(set) var entries: [Entry] = []
    private(set) var offset: UInt64 = 0
    private let handle: FileHandle
    private var isFinished = false

    /// Creates (or truncates) the archive at `url`.
    init(url: URL) throws {
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    /// An explicit folder entry, so empty folders survive the round trip.
    func addDirectory(_ path: String, modified: Date = Date()) throws {
        let name = path.hasSuffix("/") ? path : path + "/"
        var entry = makeEntry(name: name, modified: modified, isDirectory: true)
        entry.offset = offset
        try write(localHeader(entry, zip64: usesZip64(entry)))
        entries.append(entry)
    }

    /// A generated file (JSON, text): deflated when that makes it smaller.
    func addData(_ data: Data, path: String, modified: Date = Date()) throws {
        var entry = makeEntry(name: path, modified: modified, isDirectory: false)
        var payload = data
        if data.count > 64, let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
           deflated.count < data.count {
            payload = deflated
            entry.method = 8
        }
        entry.crc = CRC32.checksum(data)
        entry.size = UInt64(data.count)
        entry.compressedSize = UInt64(payload.count)
        entry.offset = offset
        try write(localHeader(entry, zip64: usesZip64(entry)))
        try write(payload)
        entries.append(entry)
    }

    /// A file on disk, streamed stored. The header is written with the size on disk and rewritten once the CRC (and
    /// the real size, if the file changed while it was read) is known. Throws `unreadable` before writing anything
    /// when the file cannot be opened.
    func addFile(at url: URL, path: String) throws {
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipArchiveError.unreadable(path)
        }
        defer { try? reader.close() }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var entry = makeEntry(name: path, modified: values?.contentModificationDate ?? Date(), isDirectory: false)
        entry.size = UInt64(max(values?.fileSize ?? 0, 0))
        entry.compressedSize = entry.size
        entry.offset = offset
        let zip64 = usesZip64(entry)
        try write(localHeader(entry, zip64: zip64))
        var crc = CRC32()
        var written: UInt64 = 0
        while true {
            let chunk = try reader.read(upToCount: ZipArchiveWriter.chunkSize) ?? Data()
            if chunk.isEmpty { break }
            crc.update(chunk)
            try write(chunk)
            written += UInt64(chunk.count)
        }
        if !zip64 && written >= ZipArchiveWriter.max32 { throw ZipArchiveError.entryTooLarge(path) }
        entry.crc = crc.checksum
        entry.size = written
        entry.compressedSize = written
        try handle.seek(toOffset: entry.offset)
        try handle.write(contentsOf: localHeader(entry, zip64: zip64))
        _ = try handle.seekToEnd()
        entries.append(entry)
    }

    /// Writes the central directory and the end records, then closes the file.
    func finish() throws {
        guard !isFinished else { throw ZipArchiveError.finished }
        isFinished = true
        let directoryOffset = offset
        for entry in entries { try write(centralHeader(entry)) }
        let directorySize = offset - directoryOffset
        let count = UInt64(entries.count)
        let needsZip64 = forcesZip64 || entries.count >= ZipArchiveWriter.max16
            || directoryOffset >= ZipArchiveWriter.max32 || directorySize >= ZipArchiveWriter.max32
        var end = Data()
        if needsZip64 {
            let recordOffset = offset
            end.le32(0x0606_4B50)
            end.le64(44)
            end.le16(0x0300 | 45)
            end.le16(45)
            end.le32(0)
            end.le32(0)
            end.le64(count)
            end.le64(count)
            end.le64(directorySize)
            end.le64(directoryOffset)
            end.le32(0x0706_4B50)
            end.le32(0)
            end.le64(recordOffset)
            end.le32(1)
        }
        let shownCount = UInt16(min(entries.count, ZipArchiveWriter.max16))
        end.le32(0x0605_4B50)
        end.le16(0)
        end.le16(0)
        end.le16(shownCount)
        end.le16(shownCount)
        end.le32(UInt32(min(directorySize, ZipArchiveWriter.max32)))
        end.le32(UInt32(min(directoryOffset, ZipArchiveWriter.max32)))
        end.le16(0)
        try write(end)
        try handle.synchronize()
        try handle.close()
    }

    // MARK: Records

    private func makeEntry(name: String, modified: Date, isDirectory: Bool) -> Entry {
        let stamp = ZipArchiveWriter.dosStamp(modified)
        return Entry(name: Array(name.utf8), method: 0, crc: 0, compressedSize: 0, size: 0, offset: 0,
                     time: stamp.time, date: stamp.date, isDirectory: isDirectory)
    }

    private func usesZip64(_ entry: Entry) -> Bool {
        forcesZip64 || entry.size >= ZipArchiveWriter.max32 || entry.compressedSize >= ZipArchiveWriter.max32
    }

    private func localHeader(_ entry: Entry, zip64: Bool) -> Data {
        var d = Data()
        d.le32(0x0403_4B50)
        d.le16(zip64 ? 45 : 20)
        d.le16(0x0800)
        d.le16(entry.method)
        d.le16(entry.time)
        d.le16(entry.date)
        d.le32(entry.crc)
        d.le32(zip64 ? UInt32.max : UInt32(entry.compressedSize))
        d.le32(zip64 ? UInt32.max : UInt32(entry.size))
        d.le16(UInt16(entry.name.count))
        d.le16(zip64 ? 20 : 0)
        d.append(contentsOf: entry.name)
        if zip64 {
            d.le16(0x0001)
            d.le16(16)
            d.le64(entry.size)
            d.le64(entry.compressedSize)
        }
        return d
    }

    private func centralHeader(_ entry: Entry) -> Data {
        let zip64 = usesZip64(entry) || entry.offset >= ZipArchiveWriter.max32
        let version: UInt16 = zip64 ? 45 : 20
        var d = Data()
        d.le32(0x0201_4B50)
        d.le16(0x0300 | version)
        d.le16(version)
        d.le16(0x0800)
        d.le16(entry.method)
        d.le16(entry.time)
        d.le16(entry.date)
        d.le32(entry.crc)
        d.le32(zip64 ? UInt32.max : UInt32(entry.compressedSize))
        d.le32(zip64 ? UInt32.max : UInt32(entry.size))
        d.le16(UInt16(entry.name.count))
        d.le16(zip64 ? 28 : 0)
        d.le16(0)
        d.le16(0)
        d.le16(0)
        // Unix mode in the high half (rw-r--r-- files, rwxr-xr-x folders) plus the MS-DOS folder bit.
        d.le32(entry.isDirectory ? (UInt32(0o040755) << 16) | 0x10 : UInt32(0o100644) << 16)
        d.le32(zip64 ? UInt32.max : UInt32(entry.offset))
        d.append(contentsOf: entry.name)
        if zip64 {
            d.le16(0x0001)
            d.le16(24)
            d.le64(entry.size)
            d.le64(entry.compressedSize)
            d.le64(entry.offset)
        }
        return d
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// MS-DOS date and time (local time, two-second resolution, 1980…2107).
    static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let time = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let day = ((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func le32(_ v: UInt32) {
        le16(UInt16(truncatingIfNeeded: v))
        le16(UInt16(truncatingIfNeeded: v >> 16))
    }

    mutating func le64(_ v: UInt64) {
        le32(UInt32(truncatingIfNeeded: v))
        le32(UInt32(truncatingIfNeeded: v >> 32))
    }
}
