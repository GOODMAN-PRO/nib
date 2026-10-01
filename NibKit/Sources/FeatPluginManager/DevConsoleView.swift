import Foundation
import SwiftUI
import NibContracts
import NibDesign

@MainActor
struct DevConsoleView: View {
    let app: NibApp
    let initialPlugin: String?
    let close: () -> Void
    @StateObject private var model: PluginManagerModel
    @State private var pluginID = ""
    @State private var javascript = ""
    @State private var result = ""
    @State private var evaluating = false
    @State private var newPlugin = false
    init(app: NibApp, initialPlugin: String? = nil, close: @escaping () -> Void) {
        self.app = app; self.initialPlugin = initialPlugin; self.close = close
        _model = StateObject(wrappedValue: PluginManagerModel(app: app))
    }
    var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: String(localized: "Developer Console"), symbol: .command, onClose: {
                app.perform(CommandIDs.panelClose, ["id": .string(ManagerCommands.consolePanel)]); close()
            })
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    if let error = model.error { ManagerError(message: error) { Task { await model.loadPlugins() } } }
                    Picker(String(localized: "Plugin"), selection: $pluginID) {
                        Text(String(localized: "Choose a plugin")).tag("")
                        ForEach(model.plugins) { Text($0.name).tag($0.id) }
                    }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    if model.plugins.isEmpty {
                        Text(String(localized: "Create a plugin or install one to evaluate JavaScript.")).font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
                    }
                    TextEditor(text: $javascript).font(NibFont.code)
                        .frame(minHeight: NibMetrics.hitTarget * 2)
                        .scrollContentBackground(.hidden).background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.field))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel(String(localized: "JavaScript to evaluate"))
                    NibButton(evaluating ? String(localized: "Evaluating…") : String(localized: "Evaluate JavaScript"), symbol: .play,
                        kind: .primary, shortcut: KeyboardShortcut(.return, modifiers: .command)) { evaluate() }
                        .disabled(pluginID.isEmpty || javascript.isEmpty || evaluating || model.busy)
                    if !result.isEmpty { NibCodeBlock(result).accessibilityLabel(String(localized: "Evaluation result: \(result)")) }
                    if !pluginID.isEmpty { PluginLogView(model: model, pluginID: pluginID).id(pluginID) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: NibSpacing.m) { developerActions }
                        VStack(alignment: .leading, spacing: NibSpacing.s) { developerActions }
                    }
                }.padding(NibSpacing.l)
            }
        }
        .frame(idealWidth: NibMetrics.developerConsoleSize.width, idealHeight: NibMetrics.developerConsoleSize.height)
        // The floating host owns the Deep droplet and its accessibility fallback. Never layer another glass here.
        .nibSheet(isPresented: $newPlugin) { NewPluginSheet(model: model) }
        .task {
            await model.loadPlugins()
            pluginID = initialPlugin.flatMap { id in model.plugins.contains { $0.id == id } ? id : nil } ?? model.plugins.first?.id ?? ""
        }
    }
    @ViewBuilder private var developerActions: some View {
        NibButton(String(localized: "New Plugin"), symbol: .plus) { newPlugin = true }
        NibButton(String(localized: "Export nib.d.ts"), symbol: .share) { model.perform(ManagerCommands.sdkExport, ["share": true], reload: false) }
        if !pluginID.isEmpty {
            NibIconButton(.retry, label: String(localized: "Reload Plugin"), size: .panel) { model.perform(CommandIDs.pluginReload, ["id": .string(pluginID)]) }
        }
    }
    private func evaluate() {
        guard !evaluating else { return }
        evaluating = true
        let id = pluginID, source = javascript
        Task { @MainActor in
            defer { evaluating = false }
            do {
                let output = try await model.call(ManagerCommands.evaluate, ["id": .string(id), "javascript": .string(source)])
                result = output["text"]?.stringValue ?? ""
            } catch { model.error = NibError.wrap(error).message }
        }
    }
}

@MainActor
struct PluginLogView: View {
    @ObservedObject var model: PluginManagerModel
    let pluginID: String
    var monospaced = true
    @State private var lines: [String] = []
    @State private var truncated = false
    @State private var tail = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            NibToggle(String(localized: "Tail Logs"), isOn: $tail)
            if let error { Text(error).font(NibFont.caption1).foregroundStyle(NibColor.destructive) }
            if lines.isEmpty {
                Text(String(localized: "No log output yet")).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
            } else {
                if monospaced {
                    NibCodeBlock(lines.joined(separator: "\n")).accessibilityLabel(String(localized: "Plugin logs"))
                } else {
                    Text(lines.joined(separator: "\n")).font(NibFont.caption1).textSelection(.enabled)
                        .accessibilityLabel(String(localized: "Plugin logs"))
                }
            }
            if truncated { Text(String(localized: "Showing the most recent log lines.")).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary) }
        }.task(id: tail) {
            repeat {
                do {
                    let output = try await model.call(CommandIDs.pluginLogs, ["id": .string(pluginID), "limit": 200])
                    try Task.checkCancellation()
                    lines = output["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    truncated = output["truncated"]?.boolValue ?? false
                    error = nil
                } catch {
                    if Task.isCancelled { return }
                    self.error = NibError.wrap(error).message
                }
                guard tail else { return }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            } while !Task.isCancelled
        }
    }
}

@MainActor
struct NewPluginSheet: View {
    @ObservedObject var model: PluginManagerModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var id = ""
    var body: some View {
        VStack(spacing: NibSpacing.l) {
            NibSheetHeader(String(localized: "New Plugin"), primaryTitle: String(localized: "Review and Create"),
                isPrimaryEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (id.isEmpty || PluginSkeleton.validID(id)),
                onCancel: { dismiss() }) {
                    var params: JSONValue = ["name": .string(name)]
                    if !id.isEmpty { params = params.merging(["id": .string(id)]) }
                    model.perform(ManagerCommands.create, params); dismiss()
                }
            Form {
                NibField(text: $name, prompt: String(localized: "Plugin name"))
                NibField(text: $id, prompt: String(localized: "Reverse-DNS id (optional)"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(String(localized: "Creates manifest.json and main.js in your library’s plugins folder after permission review. Export the plugin to edit it in your preferred editor."))
                    .font(NibFont.callout).foregroundStyle(NibColor.labelSecondary)
            }.scrollContentBackground(.hidden)
        }.background(NibColor.backgroundSecondary)
    }
}
