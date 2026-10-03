import Foundation
import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

@MainActor
final class PluginManagerModel: ObservableObject {
    let app: NibApp
    @Published var plugins: [InstalledPlugin] = []
    @Published private var consented: [String: [String]] = [:]
    @Published var indexes: [GalleryIndex] = []
    @Published var error: String?
    @Published var busy = false
    @Published private var pluginLoading = false
    @Published private var galleryLoading = false
    private var pluginGeneration = 0
    private var galleryGeneration = 0
    var loading: Bool { pluginLoading || galleryLoading }
    @Published var galleries: [String] = []
    init(app: NibApp) { self.app = app }

    func call(_ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await app.bus.execute(command, params)
    }
    func loadPlugins() async {
        pluginGeneration += 1
        let generation = pluginGeneration
        pluginLoading = true
        defer { if generation == pluginGeneration { pluginLoading = false } }
        do {
            let value = try await call(CommandIDs.pluginList)
            let entries = try (value["plugins"] ?? []).decode([InstalledPlugin].self)
            let store = app.services.get(ManagerGrants.serviceKey, as: ManagerGrants.self)
            let grants = try await Task.detached { try store?.read() ?? [:] }.value
            let setting = try await call(CommandIDs.settingsGet, ["name": .string(NibSettings.pluginGalleries.name)])
            guard generation == pluginGeneration, !Task.isCancelled else { return }
            plugins = entries
            consented = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, ManagerGrants.scopes($0.id, hash: $0.sha256, grants: grants)) })
            galleries = setting["value"]?.arrayValue?.compactMap(\.stringValue) ?? []
            error = nil
        } catch { if generation == pluginGeneration, !Task.isCancelled { self.error = NibError.wrap(error).message } }
    }
    func loadGallery(_ params: JSONValue = [:]) async {
        galleryGeneration += 1
        let generation = galleryGeneration
        galleryLoading = true
        defer { if generation == galleryGeneration { galleryLoading = false } }
        do {
            var result: [GalleryIndex] = []
            var next = params
            var visited = Set<Int>()
            repeat {
                let value = try await call(CommandIDs.galleryList, next)
                try Task.checkCancellation()
                let page = try (value["indexes"] ?? []).decode([GalleryIndex].self)
                for section in page {
                    if let position = result.firstIndex(where: { $0.index == section.index }) {
                        result[position].plugins += section.plugins
                        result[position].error = section.error
                    } else { result.append(section) }
                }
                guard let cursor = value["cursor"]?.intValue else { break }
                guard visited.insert(cursor).inserted else { throw NibError(.unavailable, "The gallery cursor did not advance.") }
                next = params.merging(["cursor": .number(Double(cursor))])
            } while true
            guard generation == galleryGeneration, !Task.isCancelled else { return }
            indexes = result
            error = nil
        } catch { if generation == galleryGeneration, !Task.isCancelled { self.error = NibError.wrap(error).message } }
    }
    func perform(_ command: String, _ params: JSONValue = [:], reload: Bool = true, success: @escaping () -> Void = {}) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await call(command, params)
                if reload { await loadPlugins() }
                success()
                error = nil
            } catch {
                let message = NibError.wrap(error).message
                if reload { await loadPlugins() }
                self.error = message
            }
        }
    }
    func consentedScopes(for plugin: InstalledPlugin) -> [String] { consented[plugin.id] ?? [] }
    func loadUpdates(refresh: Bool = false) async {
        await loadGallery(["ids": .array(plugins.map { .string($0.id) }), "refresh": .bool(refresh)])
    }
    func update(for plugin: InstalledPlugin) -> GalleryEntry? {
        indexes.flatMap(\.plugins).filter { $0.isUpdate(for: plugin) }.max { lhs, rhs in
            guard let a = PluginVersion(lhs.version), let b = PluginVersion(rhs.version) else { return false }; return a < b
        }
    }
}

@MainActor
struct PluginListView: View {
    let app: NibApp
    var close: (() -> Void)?
    @StateObject private var model: PluginManagerModel
    @State private var selection: String?
    @State private var showURL = false
    @Environment(\.dynamicTypeSize) private var typeSize
    init(app: NibApp, close: (() -> Void)? = nil) {
        self.app = app; self.close = close
        _model = StateObject(wrappedValue: PluginManagerModel(app: app))
    }
    var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: String(localized: "Plugins"), symbol: .puzzle, onClose: {
                app.perform(CommandIDs.panelClose, ["id": .string(ManagerCommands.managerPanel)])
                close?()
            }) {
                Menu {
                    Button(String(localized: "Install from Files")) { app.perform(ManagerCommands.installFile) }
                    Button(String(localized: "Install from URL")) { showURL = true }
                    Button(String(localized: "Browse Gallery")) { app.perform(CommandIDs.panelOpen, ["id": .string(PanelIDs.gallery)]) }
                    .accessibilityIdentifier("cmd." + CommandIDs.panelOpen)
                } label: {
                    Label { Text(String(localized: "Install from…")) } icon: { Image(nib: .importFile) }
                        .font(NibFont.button).frame(minHeight: NibMetrics.hitTarget)
                }
                NibIconButton(.command, label: String(localized: "Open Developer Console"), size: .panel) {
                    app.perform(CommandIDs.panelOpen, ["id": .string(ManagerCommands.consolePanel)])
                }
                .accessibilityIdentifier("cmd." + CommandIDs.panelOpen)
            }
            if let error = model.error { NibBanner(error, style: .warning, action: NibAction(String(localized: "Try Again")) { Task { await refresh() } }) }
            GeometryReader { proxy in
                if proxy.size.width >= NibMetrics.pluginManagerSheetSize.width && !typeSize.isAccessibilitySize {
                    HStack(spacing: 0) {
                        pluginList(compact: false).frame(width: NibMetrics.sidebarWidth)
                        Divider()
                        if let plugin = model.plugins.first(where: { $0.id == selection }) {
                            PluginDetailView(plugin: plugin, model: model)
                                .id(plugin.id)
                        } else {
                            NibEmptyState(symbol: .puzzle, title: String(localized: "Choose a plugin"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    NavigationStack { pluginList(compact: true) }
                }
            }
        }
        .background(NibColor.backgroundSecondary)
        .frame(idealWidth: NibMetrics.pluginManagerSheetSize.width, idealHeight: NibMetrics.pluginManagerSheetSize.height)
        .tint(NibColor.accent)
        .nibSheet(isPresented: $showURL) { PluginURLSheet(model: model) }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange)
            .filter { note in
                if let registry = note.object as? CommandRegistry { return registry === app.commands }
                guard let owner = note.userInfo?[RegistryChange.ownerKey] as? String else { return false }
                return model.plugins.contains { $0.id == owner }
            }
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in Task { await model.loadPlugins() } }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { note in
            guard let name = note.userInfo?["name"] as? String,
                  name == NibSettings.pluginGalleries.name || name.hasPrefix("pluginhost.disabled.") else { return }
            Task { await model.loadPlugins(); if name == NibSettings.pluginGalleries.name { await model.loadUpdates() } }
        }
    }
    private func refresh() async {
        await model.loadPlugins()
        await model.loadUpdates(refresh: true)
    }
    private func pluginList(compact: Bool) -> some View {
        List {
            if model.loading && model.plugins.isEmpty { ProgressView(String(localized: "Loading plugins")) }
            if model.plugins.isEmpty && !model.loading && model.error == nil {
                NibEmptyState(symbol: .puzzle, title: String(localized: "No plugins yet"),
                    message: String(localized: "Plugins add tools, panels and templates."),
                    primary: NibAction(String(localized: "Browse Gallery"), command: CommandIDs.panelOpen) { app.perform(CommandIDs.panelOpen, ["id": .string(PanelIDs.gallery)]) })
            }
            ForEach(model.plugins) { plugin in
                HStack(spacing: NibSpacing.s) {
                    Group {
                        if compact {
                            NavigationLink { PluginDetailView(plugin: plugin, model: model, isPushed: true) } label: { row(plugin) }
                        } else {
                            Button { selection = plugin.id } label: { row(plugin) }
                                .buttonStyle(.plain).accessibilityAddTraits(selection == plugin.id ? .isSelected : [])
                        }
                    }
                    NibToggle(String(localized: "Enable \(plugin.name)"), isOn: Binding(get: { plugin.enabled }, set: { enabled in
                        model.perform(CommandIDs.pluginEnable, ["id": .string(plugin.id), "enabled": .bool(enabled)])
                    })).labelsHidden().disabled(model.busy || plugin.needsReview)
                }.padding(.vertical, NibSpacing.xs)
            }
            Section(String(localized: "Galleries")) {
                GallerySettingsView(model: model)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
    }
    private func row(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            NibRow(plugin.name, subtitle: [plugin.author, plugin.version].compactMap { $0 }.joined(separator: " · "), icon: .puzzle) {
                if model.update(for: plugin) != nil { NibBadge(.capsule(String(localized: "Update"))) }
            }
            Text(plugin.permissions.map { PermissionCopy.short($0) }.joined(separator: " · "))
                .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            if plugin.needsReview { Text(String(localized: "Review required on this device")).font(NibFont.caption1).foregroundStyle(NibColor.warning) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).hoverEffect(.highlight)
    }
}

@MainActor
struct PluginDetailView: View {
    let plugin: InstalledPlugin
    @ObservedObject var model: PluginManagerModel
    var isPushed = false
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: JSONValue = [:]
    @State private var settings: [String: JSONValue] = [:]
    @State private var remove = false
    @State private var showLogs = false
    var current: InstalledPlugin { model.plugins.first { $0.id == plugin.id } ?? plugin }
    var body: some View {
        List {
            Section {
                Text(current.name).font(NibFont.title2)
                if let description = current.description { Text(description).font(NibFont.body) }
                NibRow(String(localized: "Status"), subtitle: current.state, icon: .info)
                if let error = current.error {
                    Text(String(localized: "This plugin stopped.")).font(NibFont.headline)
                    Text(error).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                    NibButton(String(localized: "Reload Plugin"), symbol: .retry) { model.perform(CommandIDs.pluginReload, ["id": .string(current.id)]) }
                    .accessibilityIdentifier("cmd." + CommandIDs.pluginReload)
                }
                if current.needsReview {
                    NibButton(String(localized: "Review Permissions"), kind: .primary) { model.perform(CommandIDs.pluginReview, ["id": .string(current.id)]) }
                    .accessibilityIdentifier("cmd." + CommandIDs.pluginReview)
                } else if let update = model.update(for: current) {
                    NibButton(String(localized: "Review Update to \(update.version)"), kind: .primary) { model.perform(CommandIDs.pluginInstall, update.installParams) }
                    .accessibilityIdentifier("cmd." + CommandIDs.pluginInstall)
                }
            }
            Section(String(localized: "Permissions")) {
                if current.state != "running" {
                    Text(String(localized: "Not running. Consented permissions apply when this plugin runs."))
                        .font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                }
                ForEach(current.permissions, id: \.self) { scope in
                    NibPermissionRow(PermissionCopy.sentence(scope, hosts: current.networkHosts), symbol: PermissionCopy.symbol(scope)) {
                        NibToggle(PermissionCopy.sentence(scope, hosts: current.networkHosts), isOn: Binding(
                            get: { model.consentedScopes(for: current).contains(scope) }, set: { value in
                                model.perform(ManagerCommands.permission, ["id": .string(current.id), "scope": .string(scope), "enabled": .bool(value)])
                            })).labelsHidden().disabled(model.busy || current.needsReview)
                    }
                }
            }
            if let fields = manifest["contributes"]?["settings"]?["properties"]?.objectValue, !fields.isEmpty {
                Section(String(localized: "Plugin Settings")) {
                    ForEach(fields.keys.sorted(), id: \.self) { key in
                        PluginSettingField(key: key, schema: fields[key] ?? [:], value: settings[key] ?? .null) { value in
                            model.perform(CommandIDs.settingsSet, ["name": .string("plugin." + current.id + "." + key), "value": value], reload: false) { settings[key] = value }
                        }
                    }
                }
            }
            Section(String(localized: "Contributions")) {
                ForEach(contributions, id: \.self) { Text($0).font(NibFont.callout) }
                if contributions.isEmpty { Text(String(localized: "No declared contributions")).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary) }
            }
            Section(String(localized: "Package")) {
                NibRow(String(localized: "Version"), subtitle: current.version)
                NibRow(String(localized: "Author"), subtitle: current.author ?? String(localized: "Not specified"))
                NibRow(String(localized: "Source"), subtitle: current.source ?? String(localized: "Local plugin"))
                Text(current.sha256).font(NibFont.caption1).textSelection(.enabled)
                NibButton(String(localized: "Export .nibplugin"), symbol: .share) { model.perform(ManagerCommands.export, ["id": .string(current.id), "share": true], reload: false) }
                NibButton(String(localized: "View Logs"), symbol: .listView) { showLogs.toggle() }
                if showLogs { PluginLogView(model: model, pluginID: current.id, monospaced: false) }
                NibButton(String(localized: "Open Developer Console"), symbol: .command) {
                    model.app.perform(CommandIDs.panelOpen, ["id": .string(ManagerCommands.consolePanel), "plugin": .string(current.id)])
                }
                .accessibilityIdentifier("cmd." + CommandIDs.panelOpen)
                NibButton(current.enabled ? String(localized: "Disable Plugin") : String(localized: "Enable Plugin")) {
                    model.perform(CommandIDs.pluginEnable, ["id": .string(current.id), "enabled": .bool(!current.enabled)])
                }
                .accessibilityIdentifier("cmd." + CommandIDs.pluginEnable).disabled(current.needsReview)
                NibButton(String(localized: "Remove Plugin"), symbol: .trash, kind: .destructivePlain) { remove = true }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(NibColor.backgroundSecondary)
        .navigationTitle(current.name).disabled(model.busy)
        .alert(String(localized: "Remove \(current.name)?"), isPresented: $remove) {
            Button(String(localized: "Keep Plugin"), role: .cancel) {}
            Button(String(localized: "Remove Plugin"), role: .destructive) {
                model.perform(CommandIDs.pluginUninstall, ["id": .string(current.id), "removeData": false]) { if isPushed { dismiss() } }
            }
            .accessibilityIdentifier("cmd." + CommandIDs.pluginUninstall)
        } message: { Text(String(localized: "The plugin will stop. Its saved data is kept for a reinstall.")) }
        .task(id: current.id + "|" + current.sha256) { await loadDetails() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { note in
            if (note.userInfo?["name"] as? String)?.hasPrefix("plugin." + current.id + ".") == true {
                Task { await loadDetails() }
            }
        }
    }
    var contributions: [String] {
        guard let values = manifest["contributes"]?.objectValue else { return [] }
        let titles = ["commands": String(localized: "Commands"), "toolbar": String(localized: "Toolbar tools"),
            "tools": String(localized: "Canvas tools"), "panels": String(localized: "Panels"), "menus": String(localized: "Menus"),
            "aiActions": String(localized: "AI actions"), "templates": String(localized: "Templates and covers"),
            "elements": String(localized: "Sticker collections"), "tapePatterns": String(localized: "Tape patterns"),
            "boardTemplates": String(localized: "Whiteboard templates")]
        return titles.keys.sorted().compactMap { key in
            guard let entries = values[key]?.arrayValue, !entries.isEmpty else { return nil }
            let names = entries.compactMap { $0["title"]?.stringValue ?? $0["name"]?.stringValue ?? $0["id"]?.stringValue }.joined(separator: ", ")
            return (titles[key] ?? key) + ": " + (names.isEmpty ? String(entries.count) : names)
        }
    }
    private func loadDetails() async {
        do {
            var params: JSONValue = ["id": .string(current.id)]
            var data = ""
            var cursors = Set<Int>()
            repeat {
                let page = try await model.call(ManagerCommands.inspect, params)
                guard let text = page["text"]?.stringValue else { throw NibError.unavailable("the plugin manifest") }
                data += text
                guard let cursor = page["cursor"]?.intValue else { break }
                guard cursors.insert(cursor).inserted else { throw NibError(.unavailable, "The manifest cursor did not advance.") }
                params = params.merging(["cursor": .number(Double(cursor))])
            } while true
            manifest = try JSONValue.parse(data)
            for key in manifest["contributes"]?["settings"]?["properties"]?.objectValue?.keys.sorted() ?? [] {
                let result = try await model.call(CommandIDs.settingsGet, ["name": .string("plugin." + current.id + "." + key)])
                settings[key] = result["value"] ?? manifest["contributes"]?["settings"]?["properties"]?[key]?["default"] ?? .null
            }
        } catch { model.error = NibError.wrap(error).message }
    }
}

struct PluginSettingField: View {
    let key: String
    let schema: JSONValue
    let value: JSONValue
    let save: (JSONValue) -> Void
    @State private var draft = ""
    @State private var invalid = false
    var title: String { schema["title"]?.stringValue ?? key }
    var body: some View {
        Group {
            if schema["type"]?.stringValue == "boolean" {
                NibToggle(title, isOn: Binding(get: { value.boolValue ?? false }, set: { save(.bool($0)) }))
            } else if let choices = schema["enum"]?.arrayValue {
                Picker(title, selection: Binding(get: { value }, set: save)) {
                    ForEach(choices, id: \.self) { choice in Text(choice.stringValue ?? choice.jsonString()).tag(choice) }
                }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
            } else {
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    Text(title).font(NibFont.body)
                    NibField(text: $draft, prompt: title, lines: 1...5)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    NibButton(String(localized: "Save Setting"), kind: .plain) {
                        do {
                            let parsed: JSONValue = schema["type"]?.stringValue == "string" ? .string(draft) : try JSONValue.parse(draft)
                            invalid = false; save(parsed)
                        } catch { invalid = true }
                    }
                    if invalid { Text(String(localized: "Enter a valid JSON value.")).font(NibFont.caption1).foregroundStyle(NibColor.destructive) }
                }.task(id: value) { draft = value.stringValue ?? value.jsonString() }
            }
        }
    }
}

enum PermissionCopy {
    static func sentence(_ scope: String, hosts: [String] = []) -> String {
        switch scope {
        case "document:read": return String(localized: "Read every document")
        case "document:write": return String(localized: "Change pages")
        case "library:read": return String(localized: "Read your library")
        case "library:write": return String(localized: "Change your library")
        case "destructive": return String(localized: "Delete content")
        case "ai": return String(localized: "Use your AI provider")
        case "network": return hosts.isEmpty ? String(localized: "Use network access (no hosts allowed)") : String(localized: "Reach the network: \(hosts.joined(separator: ", "))")
        case "app": return String(localized: "Use app commands")
        default: return scope
        }
    }
    static func short(_ scope: String) -> String {
        switch scope {
        case "document:read": return String(localized: "Reads documents")
        case "document:write": return String(localized: "Changes pages")
        case "ai": return String(localized: "Uses your AI")
        case "network": return String(localized: "Uses the network")
        default: return sentence(scope)
        }
    }
    static func symbol(_ scope: String) -> NibSymbol {
        switch scope {
        case "document:read", "library:read": return .pdf
        case "document:write", "library:write": return .documentWrite
        case "ai": return .assistant
        case "network": return .network
        case "destructive": return .trash
        default: return .settings
        }
    }
}

@MainActor
final class PluginFilePicker: UIDocumentPickerViewController, UIDocumentPickerDelegate {
    let app: NibApp
    init(app: NibApp) {
        self.app = app
        super.init(forOpeningContentTypes: [.zip, .folder, UTType(importedAs: NibFormat.pluginUTType)], asCopy: true)
        delegate = self
        allowsMultipleSelection = false
    }
    required init?(coder: NSCoder) { return nil }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        controller.dismiss(animated: true) { [app] in
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { _ = try await app.bus.execute(CommandIDs.pluginInstall, ["path": .string(url.absoluteString)]) }
                catch { NotificationCenter.default.post(name: .nibCommandFailed, object: app, userInfo: ["error": NibError.wrap(error), "command": CommandIDs.pluginInstall]) }
            }
        }
    }
}

@MainActor
struct PluginURLSheet: View {
    @ObservedObject var model: PluginManagerModel
    @State private var url = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(String(localized: "Install from URL"), primaryTitle: String(localized: "Review Plugin"),
                isPrimaryEnabled: (try? GalleryClient.indexURL(url)) != nil, onCancel: { dismiss() }) {
                model.perform(CommandIDs.pluginInstall, ["url": .string(url)]); dismiss()
            }
            NibField(text: $url, prompt: String(localized: "HTTPS .nibplugin URL"))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, NibSpacing.l)
            Spacer()
        }.background(NibColor.backgroundSecondary)
    }
}
