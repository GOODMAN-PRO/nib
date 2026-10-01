import Foundation
import SwiftUI
import UIKit
import os
import NibContracts
import NibDesign

// Settings › Advanced › Troubleshooting (DESIGN.md §14.8: an opaque inset grouped list, `NibRow`s and `NibToggle`s,
// no glass; the safe-mode notice is a `NibBanner`, §14.18). Every change goes through a command: the export
// (`diagnostics.export`), feature and plugin switches (`diagnostics.setFeatureEnabled`) and experiments (`settings.set`).
// Opening GitHub, Mail or the Settings app only leaves Nib.

// MARK: - Model

@MainActor
final class TroubleshootingModel: ObservableObject {
    enum ExportPhase: Equatable {
        case idle
        case running
        case done(bytes: Int, shared: Bool)
        case failed(String)
    }

    struct FeatureRow: Identifiable, Equatable {
        let id: String
        let title: String
        /// On at the next launch.
        let isOn: Bool
        let isRequired: Bool
        /// This launch differs from the next one (the change waits for a relaunch).
        let isPending: Bool
    }

    struct LibraryCopyFile: Equatable {
        var name: String
        var bytes: Int64
    }

    @Published var includeTitles = false
    @Published var filter = ""
    @Published var showsAllFeatures = false
    @Published private(set) var exportPhase: ExportPhase = .idle
    @Published private(set) var features: [FeatureRow] = []
    @Published private(set) var plugins: [DiagnosticsPlugin] = []
    @Published private(set) var pluginsAvailable = false
    @Published private(set) var experiments: [ExperimentalFlag] = []
    @Published private(set) var experimentValues: [String: Bool] = [:]
    /// Switches with a command in flight (feature ids, "plugin:<id>", experiment ids).
    @Published private(set) var busy: Set<String> = []
    /// The last action that failed, in plain words.
    @Published private(set) var problem: String?
    @Published private(set) var reportURL: URL?
    @Published private(set) var mailURL: URL?
    @Published private(set) var latestCopy: LibraryCopyFile?

    let app: NibApp
    let runtime: DiagnosticsRuntime
    private var observers: [NSObjectProtocol] = []
    private var pluginReloadScheduled = false

    init(app: NibApp, runtime: DiagnosticsRuntime) {
        self.app = app
        self.runtime = runtime
    }

    var launchedInSafeMode: Bool { runtime.launchedInSafeMode }
    var isExporting: Bool { exportPhase == .running }
    var hasPendingChanges: Bool { features.contains { $0.isPending } }

    /// Features that are off or waiting for a relaunch; every feature (filtered) once "Show All Features" is on.
    var shownFeatures: [FeatureRow] {
        guard showsAllFeatures else { return features.filter { !$0.isOn || $0.isPending } }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return features }
        return features.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    func isOn(_ flag: ExperimentalFlag) -> Bool { experimentValues[flag.id] ?? false }

    // MARK: Loading

    func refresh() async {
        reloadFeatures()
        reloadExperiments()
        await reloadPlugins()
        reloadReport()
        reloadLatestCopy()
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                                queue: nil) { [weak self] note in
            guard (note.userInfo?["name"] as? String) == NibSettings.experimental.name else { return }
            Task { @MainActor in self?.reloadExperiments() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .nibRegistryDidChange, object: app.commands,
                                                                queue: nil) { [weak self] _ in
            // A plugin loaded, unloaded or was reinstalled: one reload per burst of registry changes.
            Task { @MainActor in self?.schedulePluginReload() }
        })
    }

    func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    func reloadFeatures() {
        features = TroubleshootingModel.featureRows(running: Set(app.featureIDs), disabled: runtime.safeMode.disabledFeatures,
                                                    disabledAtLaunch: runtime.disabledAtLaunch)
    }

    static func featureRows(running: Set<String>, disabled: Set<String>, disabledAtLaunch: Set<String>) -> [FeatureRow] {
        running.union(disabled).union(disabledAtLaunch).map { id in
            let isOn = !disabled.contains(id)
            let pending = running.contains(id) ? !isOn : (isOn && disabledAtLaunch.contains(id))
            // One that stays on but is off anyway (an older build's choice) keeps its switch, so it can come back.
            return FeatureRow(id: id, title: FeatureCatalog.title(id), isOn: isOn,
                              isRequired: FeatureCatalog.alwaysOn.contains(id) && isOn, isPending: pending)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func reloadExperiments() {
        let values = app.settings.get(NibSettings.experimental)
        experimentValues = values
        experiments = ExperimentalFlags.visible(values: values, running: Set(app.featureIDs))
    }

    func reloadPlugins() async {
        guard app.commands.entry(CommandIDs.pluginList) != nil else {
            pluginsAvailable = false
            plugins = []
            return
        }
        pluginsAvailable = true
        do {
            let value = try await app.bus.execute(CommandIDs.pluginList, [:], principal: .user,
                                                  session: app.services.sessions.active)
            plugins = DiagnosticsPlugin.list(from: value)
        } catch {
            problem = NibError.wrap(error).message
        }
    }

    private func schedulePluginReload() {
        guard !pluginReloadScheduled else { return }
        pluginReloadScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self = self else { return }
            self.pluginReloadScheduled = false
            await self.reloadPlugins()
        }
    }

    /// The Report an Issue links, prefilled with the same summary the export writes (counts only, no titles).
    func reloadReport() {
        let summary = DiagnosticsSummary.text(
            app: DiagnosticsCollector.appInfo(app: app, settings: app.settings, runtime: runtime),
            device: DiagnosticsCollector.deviceInfo(),
            features: DiagnosticsCollector.features(running: app.featureIDs, runtime: runtime,
                                                    experiments: app.settings.get(NibSettings.experimental)),
            plugins: DiagnosticsPluginsReport(available: pluginsAvailable, runningInThisLaunch: !launchedInSafeMode,
                                              plugins: plugins),
            library: DiagnosticsCollector.library(app.services.library, includeTitles: false,
                                                  documents: runtime.documentsDirectory).0,
            generated: Date())
        reportURL = IssueReport.githubURL(summary: summary)
        mailURL = IssueReport.mailURL(summary: summary)
    }

    func reloadLatestCopy() {
        latestCopy = LibraryArchiver.latestCopy(in: runtime.libraryCopyFolder)
            .map { LibraryCopyFile(name: $0.name, bytes: $0.bytes) }
    }

    // MARK: Actions (commands, as the user)

    /// Switch taps: the switch shows its new state at once, and the command's result (or failure) settles it.
    func requestFeature(_ id: String, enabled: Bool) {
        showFeature(id, enabled: enabled)
        Task { await setFeature(id, enabled: enabled) }
    }

    func requestPlugin(_ id: String, enabled: Bool) {
        showPlugin(id, enabled: enabled)
        Task { await setPlugin(id, enabled: enabled) }
    }

    func requestExperiment(_ id: String, on: Bool) {
        experimentValues[id] = on
        Task { await setExperiment(id, on: on) }
    }

    private func showFeature(_ id: String, enabled: Bool) {
        var disabled = runtime.safeMode.disabledFeatures
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        features = TroubleshootingModel.featureRows(running: Set(app.featureIDs), disabled: disabled,
                                                    disabledAtLaunch: runtime.disabledAtLaunch)
    }

    private func showPlugin(_ id: String, enabled: Bool) {
        if let index = plugins.firstIndex(where: { $0.id == id }) { plugins[index].enabled = enabled }
    }

    func export() async {
        guard !isExporting else { return }
        exportPhase = .running
        problem = nil
        do {
            let value = try await app.bus.execute(DiagnosticsIDs.exportCommand, ["includeTitles": .bool(includeTitles)],
                                                  principal: .user, session: app.services.sessions.active)
            let output = try value.decode(DiagnosticsExportCommand.Output.self)
            exportPhase = .done(bytes: output.bytes, shared: output.shared)
            if !NibApp.isHostlessTest { NibHaptics.play(.success) }
        } catch {
            exportPhase = .failed(NibError.wrap(error).message)
            if !NibApp.isHostlessTest { NibHaptics.play(.warning) }
        }
    }

    func setFeature(_ id: String, enabled: Bool) async {
        showFeature(id, enabled: enabled)
        await perform(id) {
            try await self.app.bus.execute(DiagnosticsIDs.setFeatureEnabledCommand,
                                           ["id": .string(id), "enabled": .bool(enabled)], principal: .user,
                                           session: self.app.services.sessions.active)
        }
        reloadFeatures()
        reloadReport()
    }

    func setPlugin(_ id: String, enabled: Bool) async {
        let key = DiagnosticsIDs.pluginPrefix + id
        showPlugin(id, enabled: enabled)
        await perform(key) {
            try await self.app.bus.execute(DiagnosticsIDs.setFeatureEnabledCommand,
                                           ["id": .string(key), "enabled": .bool(enabled)], principal: .user,
                                           session: self.app.services.sessions.active)
        }
        await reloadPlugins()
        reloadReport()
    }

    func setExperiment(_ id: String, on: Bool) async {
        var values = app.settings.get(NibSettings.experimental)
        values[id] = on
        experimentValues[id] = on
        let value = JSONValue.object(values.mapValues { JSONValue.bool($0) })
        await perform(id) {
            try await self.app.bus.execute(CommandIDs.settingsSet,
                                           ["name": .string(NibSettings.experimental.name), "value": value],
                                           principal: .user, session: self.app.services.sessions.active)
        }
        reloadExperiments()
        reloadReport()
    }

    /// Shows a problem the page found itself (a mail app that would not open).
    func report(problem message: String) {
        problem = message
    }

    private func perform(_ key: String, _ body: @escaping () async throws -> JSONValue) async {
        busy.insert(key)
        problem = nil
        do {
            _ = try await body()
        } catch {
            problem = NibError.wrap(error).message
        }
        busy.remove(key)
    }
}

// MARK: - Page

struct TroubleshootingPage: View {
    @StateObject private var model: TroubleshootingModel
    @ObservedObject private var runtime: DiagnosticsRuntime
    @Environment(\.openURL) private var openURL

    static let exportShortcut = KeyboardShortcut("e", modifiers: .command)

    init(app: NibApp, runtime: DiagnosticsRuntime) {
        _model = StateObject(wrappedValue: TroubleshootingModel(app: app, runtime: runtime))
        _runtime = ObservedObject(wrappedValue: runtime)
    }

    var body: some View {
        List {
            notices
            diagnosticsSection
            reportSection
            pluginsSection
            featuresSection
            experimentalSection
            diagnosticModeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Troubleshooting"))
        .task { await model.refresh() }
        .onAppear { model.startObserving() }
        .onDisappear { model.stopObserving() }
        .onChange(of: runtime.revision) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: runtime.libraryCopy) { _, _ in
            model.reloadLatestCopy()
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if model.launchedInSafeMode {
            Section {
                banner(NibBanner(String(localized: "Nib started in safe mode because it closed unexpectedly while opening. Plugins are paused for now. Turn off anything you suspect below, then close Nib and open it again."),
                                 style: .warning))
            }
        }
        if model.hasPendingChanges {
            Section {
                banner(NibBanner(String(localized: "Close Nib and open it again to apply your feature changes."),
                                 style: .info, symbol: .retry))
            }
        }
        if let problem = model.problem {
            Section {
                banner(NibBanner(problem, style: .warning))
            }
        }
    }

    private func banner(_ banner: NibBanner) -> some View {
        banner
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    // MARK: Diagnostics (P-092)

    private var diagnosticsSection: some View {
        Section {
            NibToggle(String(localized: "Include document titles"), isOn: $model.includeTitles)
                .disabled(model.isExporting)
            NibButton(String(localized: "Export Diagnostics"), symbol: .share, kind: .secondary,
                      shortcut: TroubleshootingPage.exportShortcut) {
                Task { await model.export() }
            }
            .disabled(model.isExporting)
            .background(DiagnosticsShareAnchor(sharing: runtime.sharing))
            .frame(maxWidth: .infinity, alignment: .leading)
            exportStatus
        } header: {
            TroubleshootingHeader(String(localized: "Diagnostics"))
        } footer: {
            TroubleshootingFooter(String(localized: "A zip with what Nib logged since you opened it, this device and Nib's version, the features and plugins you use and how many documents your library holds. It never includes what's in your notes, and titles are left out unless you turn them on."))
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportPhase {
        case .idle:
            EmptyView()
        case .running:
            NibTraceRow(String(localized: "Collecting the log and device details"), phase: .running)
                .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        case .done(let bytes, let shared):
            NibTraceRow(shared
                        ? String(localized: "Diagnostics ready: \(DiagnosticsFormat.bytes(Int64(bytes)))")
                        : String(localized: "Diagnostics built (\(DiagnosticsFormat.bytes(Int64(bytes)))), but the share sheet couldn't open."),
                        phase: shared ? .done : .warning)
                .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        case .failed(let message):
            NibTraceRow(message, phase: .warning)
                .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        }
    }

    // MARK: Report an Issue (P-100)

    private var reportSection: some View {
        Section {
            linkRow(String(localized: "Open an Issue on GitHub"),
                    subtitle: String(localized: "Starts a new issue with a summary of this device"),
                    url: model.reportURL, failure: nil)
            linkRow(String(localized: "Email a Report"),
                    subtitle: String(localized: "Opens your mail app with the same summary"),
                    url: model.mailURL,
                    failure: String(localized: "No mail app could open the report. Set one up, or open an issue on GitHub instead."))
        } header: {
            TroubleshootingHeader(String(localized: "Report an Issue"))
        } footer: {
            TroubleshootingFooter(String(localized: "Both start with Nib's version, this device and the features you've turned off, never your notes. Attach the diagnostics zip so the problem can be traced."))
        }
    }

    private func linkRow(_ title: String, subtitle: String, url: URL?, failure: String?) -> some View {
        Button {
            guard let url = url else { return }
            openURL(url) { accepted in
                guard !accepted, let failure = failure else { return }
                Task { @MainActor in model.report(problem: failure) }
            }
        } label: {
            NibRow(title, subtitle: subtitle, icon: .externalLink)
                .contentShape(Rectangle())
        }
        .disabled(url == nil)
    }

    // MARK: Safe mode (N-026): plugins and features

    @ViewBuilder
    private var pluginsSection: some View {
        if model.pluginsAvailable {
            Section {
                if model.plugins.isEmpty {
                    Text(String(localized: "No plugins installed"))
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
                }
                ForEach(model.plugins) { plugin in
                    SwitchRow(title: plugin.name, detail: pluginDetail(plugin), isOn: plugin.enabled,
                              isBusy: model.busy.contains(DiagnosticsIDs.pluginPrefix + plugin.id)) { on in
                        model.requestPlugin(plugin.id, enabled: on)
                    }
                }
            } header: {
                TroubleshootingHeader(String(localized: "Plugins"))
            } footer: {
                TroubleshootingFooter(model.launchedInSafeMode
                                      ? String(localized: "No plugin runs in safe mode. Turn off the ones you suspect before you open Nib again.")
                                      : String(localized: "Turning a plugin off stops it straight away. A plugin that stops Nib from opening is the most common reason for safe mode."))
            }
        }
    }

    private func pluginDetail(_ plugin: DiagnosticsPlugin) -> String? {
        var parts: [String] = []
        if !plugin.version.isEmpty { parts.append(String(localized: "Version \(plugin.version)")) }
        if plugin.needsReview { parts.append(String(localized: "Needs review")) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private var featuresSection: some View {
        Section {
            if model.showsAllFeatures {
                NibSearchField(text: $model.filter, prompt: String(localized: "Find a feature"))
            }
            let rows = model.shownFeatures
            if rows.isEmpty {
                Text(model.showsAllFeatures ? String(localized: "No feature matches.")
                                            : String(localized: "Every feature is on."))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
            }
            ForEach(rows) { row in
                featureRow(row)
            }
            NibButton(model.showsAllFeatures ? String(localized: "Hide Features That Are On")
                                             : String(localized: "Show All Features"),
                      kind: .plain) {
                model.showsAllFeatures.toggle()
                if !model.showsAllFeatures { model.filter = "" }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            TroubleshootingHeader(String(localized: "Features"))
        } footer: {
            TroubleshootingFooter(String(localized: "Turning a feature off takes effect the next time you open Nib, so you can find the one that stops it from opening. The features Nib needs to open your library, Password lock and managed settings stay on."))
        }
    }

    @ViewBuilder
    private func featureRow(_ row: TroubleshootingModel.FeatureRow) -> some View {
        if row.isRequired {
            NibRow(row.title, subtitle: String(localized: "Always on"))
                .accessibilityElement(children: .combine)
        } else {
            SwitchRow(title: row.title,
                      detail: row.isPending
                          ? (row.isOn ? String(localized: "Turns on when you reopen Nib")
                                      : String(localized: "Turns off when you reopen Nib"))
                          : nil,
                      isOn: row.isOn, isBusy: model.busy.contains(row.id)) { on in
                model.requestFeature(row.id, enabled: on)
            }
        }
    }

    // MARK: Experimental (P-101)

    private var experimentalSection: some View {
        Section {
            if model.experiments.isEmpty {
                Text(String(localized: "No experiments in this version."))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
            }
            ForEach(model.experiments) { flag in
                SwitchRow(title: flag.title, detail: flag.detail, isOn: model.isOn(flag),
                          isBusy: model.busy.contains(flag.id)) { on in
                    model.requestExperiment(flag.id, on: on)
                }
            }
        } header: {
            TroubleshootingHeader(String(localized: "Experimental"))
        } footer: {
            TroubleshootingFooter(String(localized: "Experiments are features still being finished. They stay on this device and may change or go away in a later version."))
        }
    }

    // MARK: Temporary Diagnostic Mode (P-093)

    private var diagnosticModeSection: some View {
        Section {
            Text(String(localized: "Turn on Temporary Diagnostic Mode under Nib in the Settings app. When you come back to Nib, or the next time it opens, it saves a copy of your whole library as a zip in the Files app, in Nib's diagnostics folder, then turns itself off."))
                .font(NibFont.callout)
                .foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, NibSpacing.xs)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button {
                    openURL(url)
                } label: {
                    NibRow(String(localized: "Open Nib in Settings"), icon: .settings)
                        .contentShape(Rectangle())
                }
            }
            libraryCopyRow
        } header: {
            TroubleshootingHeader(String(localized: "Temporary Diagnostic Mode"))
        } footer: {
            TroubleshootingFooter(String(localized: "The copy holds your notes. Share it only with someone you trust, and delete it in Files when you're done."))
        }
    }

    @ViewBuilder
    private var libraryCopyRow: some View {
        switch runtime.libraryCopy {
        case .running:
            NibTraceRow(String(localized: "Copying the library"), phase: .running)
                .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        case .done(let name, let bytes):
            NibTraceRow(String(localized: "Library copied: \(name), \(DiagnosticsFormat.bytes(bytes))"), phase: .done)
                .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        case .failed(let message):
            NibTraceRow(message, phase: .warning)
                .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
        case .idle:
            if let copy = model.latestCopy {
                NibRow(String(localized: "Latest copy"),
                       subtitle: "\(copy.name) \u{00B7} \(DiagnosticsFormat.bytes(copy.bytes))")
                    .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Rows

/// A switch with an optional caption under it (the caption is also the switch's VoiceOver hint).
private struct SwitchRow: View {
    let title: String
    let detail: String?
    let isOn: Bool
    let isBusy: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
            NibToggle(title, isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .disabled(isBusy)
                .accessibilityHint(detail ?? "")
            if let detail = detail {
                Text(detail)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, detail == nil ? 0 : NibSpacing.xxs)
    }
}

private struct TroubleshootingHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct TroubleshootingFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
    }
}

// MARK: - Share sheet

/// Shows the system share sheet for an export (the "user presence" of `diagnostics.export`).
@MainActor
protocol DiagnosticsSharing: AnyObject {
    /// The Export button, so the iPad popover points at it; nil centres it in the window.
    var anchor: UIView? { get set }
    /// Presents the share sheet for `url` in the key window; false when there is no window (hostless tests, background).
    func share(_ url: URL, navigator: SceneNavigator?) -> Bool
}

@MainActor
final class SystemDiagnosticsSharing: DiagnosticsSharing {
    weak var anchor: UIView?
    private let log = Logger(subsystem: "app.nib", category: "diagnostics")

    func share(_ url: URL, navigator: SceneNavigator?) -> Bool {
        guard !NibApp.isHostlessTest else { return false }
        let source = anchor?.window != nil ? anchor : nil
        guard var top = source?.window?.rootViewController ?? navigator?.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let log = self.log
        sheet.completionWithItemsHandler = { activity, completed, _, error in
            if let error = error {
                log.error("Diagnostics share failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.notice("Diagnostics share \(completed ? "completed" : "cancelled", privacy: .public) \(activity?.rawValue ?? "", privacy: .public)")
            }
        }
        if let popover = sheet.popoverPresentationController {
            if let source = source {
                popover.sourceView = source
                popover.sourceRect = source.bounds
            } else {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        top.present(sheet, animated: true)
        return true
    }
}

/// An invisible view behind the Export button that the iPad share popover points at.
private struct DiagnosticsShareAnchor: UIViewRepresentable {
    let sharing: DiagnosticsSharing

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        sharing.anchor = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        sharing.anchor = uiView
    }
}

// MARK: - Safe-mode notice (N-026)

@MainActor
enum TroubleshootingNavigation {
    /// Settings at the Troubleshooting page: F027's `settings.open`, or the shell's settings in a build without it.
    static func open(_ app: NibApp) {
        if app.commands.entry(CommandIDs.settingsOpen) != nil {
            app.perform(CommandIDs.settingsOpen, ["page": .string(DiagnosticsIDs.settingsPage)])
        } else {
            app.ui.activeNavigator?.showSettings(page: DiagnosticsIDs.settingsPage)
        }
    }
}

/// Once per launch, as soon as a window shows: a system alert that offers the Troubleshooting page. In safe mode it
/// says why plugins are paused (the page's banner stays while the launch lasts); when a feature the way back goes
/// through is off (the library browser, Settings or the document bars), it is the way back, since after a relaunch
/// nothing else on screen may lead there.
@MainActor
final class SafeModeNotice {
    let kind: LaunchNoticeKind
    private var observers: [NSObjectProtocol] = []
    private var presented = false

    init(kind: LaunchNoticeKind = .safeMode) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case .safeMode: return String(localized: "Nib started in safe mode")
        case .featuresOff: return String(localized: "Some features are turned off")
        }
    }

    var message: String {
        switch kind {
        case .safeMode:
            return String(localized: "Nib closed unexpectedly while opening, so plugins are paused for now. You can turn off what might be causing it in Troubleshooting.")
        case .featuresOff:
            return String(localized: "You turned off features in Troubleshooting, including ones Nib uses to show your library or Settings. You can turn them back on there.")
        }
    }

    func presentWhenReady(_ app: NibApp) {
        if tryPresent(app) { return }
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak app] _ in
                // A task, so the window finishes appearing before an alert goes over it.
                Task { @MainActor in
                    guard let self = self, let app = app else { return }
                    if self.tryPresent(app) { self.stopObserving() }
                }
            })
        }
    }

    private func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func tryPresent(_ app: NibApp) -> Bool {
        guard !presented else { return true }
        guard let root = app.ui.activeNavigator?.rootViewController, root.viewIfLoaded?.window != nil else { return false }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        presented = true
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        let review = UIAlertAction(title: String(localized: "Open Troubleshooting"), style: .default) { [weak app] _ in
            Task { @MainActor in
                guard let app = app else { return }
                TroubleshootingNavigation.open(app)
            }
        }
        alert.addAction(review)
        alert.preferredAction = review
        top.present(alert, animated: true)
        return true
    }
}
