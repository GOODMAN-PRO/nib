import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

@MainActor
final class ProviderListModel: ObservableObject {
    let app: NibApp
    @Published var providers: [ProviderRow] = []
    @Published var activeID: UUID?
    @Published var policy = ConfirmationPolicy.destructive
    @Published var directTools = NibSettings.defaultAIDirectTools
    @Published var maxSteps = 40
    @Published var commandIDs: [String] = []
    @Published var busy = false
    @Published var error: String?
    init(app: NibApp) { self.app = app }

    func refresh() async {
        busy = true
        defer { busy = false }
        do {
            var rows: [ProviderRow] = []
            var cursor: Int?
            repeat {
                let params: JSONValue = cursor.map { ["cursor": .number(Double($0))] } ?? [:]
                let result = try await app.bus.execute(CommandIDs.aiProviderList, params)
                let page = try result.decode(ProviderList.Output.self)
                rows += page.providers; activeID = page.activeID; cursor = page.cursor
                try Task.checkCancellation()
            } while cursor != nil
            providers = rows
            policy = try await setting(NibSettings.aiConfirmationPolicy)
            directTools = try await setting(AISettingsKeys.directTools)
            maxSteps = try await setting(AISettingsKeys.maxSteps)
            let result = try await app.bus.execute(CommandIDs.commandsList)
            commandIDs = (result["commands"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted()
            error = nil
        } catch is CancellationError { }
          catch { self.error = NibError.wrap(error).message }
    }
    private func setting<V>(_ key: SettingKey<V>) async throws -> V {
        let result = try await app.bus.execute(CommandIDs.settingsGet, ["name": .string(key.name)])
        guard let value = result["value"], value != .null else { return key.defaultValue }
        return try value.decode(V.self)
    }
    func activate(_ id: UUID) {
        mutate(CommandIDs.aiProviderActivate, ["id": .string(id.uuidString)])
    }
    func set<V>(_ key: SettingKey<V>, value: V) {
        do { mutate(CommandIDs.settingsSet, ["name": .string(key.name), "value": try JSONValue.from(value)]) }
        catch { self.error = NibError.wrap(error).message }
    }
    private func mutate(_ command: String, _ params: JSONValue) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await app.bus.execute(command, params)
                await refresh()
            } catch { self.error = NibError.wrap(error).message }
        }
    }
}

@MainActor
struct ProviderListView: View {
    let app: NibApp
    @StateObject private var model: ProviderListModel
    @State private var addingTool = ""
    @State private var showTools = false
    init(app: NibApp) {
        self.app = app
        _model = StateObject(wrappedValue: ProviderListModel(app: app))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.providers) { row in
                        VStack(alignment: .leading, spacing: NibSpacing.s) {
                            NavigationLink {
                                ProviderEditorView(app: app, row: row)
                            } label: {
                                NibRow(row.config.name, subtitle: row.config.model.isEmpty ? String(localized: "Choose a model") : row.config.model,
                                       icon: .assistant) {
                                    if model.activeID == row.id {
                                        Text(String(localized: "Active")).font(NibFont.caption1).foregroundStyle(NibColor.labelSecondary)
                                    }
                                }
                            }
                            if row.credentialsMissing {
                                Text(String(localized: "credentials missing — re-enter"))
                                    .font(NibFont.footnote).foregroundStyle(NibColor.warning)
                            }
                            if model.activeID != row.id {
                                NibButton(String(localized: "Use this provider"), symbol: .checkmark, kind: .plain) { model.activate(row.id) }
                            }
                        }
                    }
                    if model.providers.isEmpty && !model.busy {
                        NibRow(String(localized: "Connect a model to use the assistant."),
                               subtitle: String(localized: "Choose a hosted provider or a server you control."), icon: .assistant)
                    }
                    NavigationLink {
                        ProviderEditorView(app: app)
                    } label: {
                        NibRow(String(localized: "Add provider"), icon: .plus)
                    }
                } header: { Text(String(localized: "Providers")) }
                Section {
                    Picker(String(localized: "Confirm AI actions"), selection: Binding(get: { model.policy }, set: {
                        model.set(NibSettings.aiConfirmationPolicy, value: $0)
                    })) {
                        Text(String(localized: "Always")).tag(ConfirmationPolicy.always)
                        Text(String(localized: "Destructive actions")).tag(ConfirmationPolicy.destructive)
                        Text(String(localized: "Never")).tag(ConfirmationPolicy.never)
                    }.frame(minHeight: NibMetrics.hitTarget)
                    Stepper(value: Binding(get: { model.maxSteps }, set: { model.set(AISettingsKeys.maxSteps, value: $0) }), in: 1...100) {
                        NibRow(String(localized: "Maximum steps"), subtitle: String(localized: "\(model.maxSteps) tool rounds"))
                    }.frame(minHeight: NibMetrics.hitTarget)
                    DisclosureGroup(String(localized: "Direct tools"), isExpanded: $showTools) {
                        ForEach(model.directTools, id: \.self) { id in
                            NibRow(id) {
                                NibIconButton(.minus, label: String(localized: "Remove \(id) from direct tools")) {
                                    model.set(AISettingsKeys.directTools, value: model.directTools.filter { $0 != id })
                                }
                            }
                        }
                        Picker(String(localized: "Command to add"), selection: $addingTool) {
                            Text(String(localized: "Choose a command")).tag("")
                            ForEach(model.commandIDs.filter { !model.directTools.contains($0) }, id: \.self) { Text($0).tag($0) }
                        }.frame(minHeight: NibMetrics.hitTarget)
                        NibButton(String(localized: "Add direct tool"), symbol: .plus, kind: .plain) {
                            model.set(AISettingsKeys.directTools, value: model.directTools + [addingTool])
                            addingTool = ""
                        }.disabled(addingTool.isEmpty)
                        NibButton(String(localized: "Restore default tools"), symbol: .undo, kind: .plain) {
                            model.set(AISettingsKeys.directTools, value: NibSettings.defaultAIDirectTools)
                        }
                    }.frame(minHeight: NibMetrics.hitTarget)
                } header: { Text(String(localized: "AI actions")) }
                  footer: { VStack(alignment: .leading, spacing: NibSpacing.s) {
                    Text(String(localized: "The current AI agent uses a fixed limit of 40 tool rounds. Your preferred maximum is saved for agents that support it."))
                    Text(String(localized: "Only you can change confirmation policy. Sensitive and irreversible actions still require approval. Direct tools give the model convenient shortcuts; all other commands remain available through the command catalogue."))
                  } }
                Section {
                    Text(String(localized: "Your notes are sent only to the provider you configure. Nib has no AI server. With Ollama or LM Studio, inference can stay on your own devices. Your server’s settings determine whether it forwards any data."))
                        .font(NibFont.body).foregroundStyle(NibColor.label)
                    Text(String(localized: "API keys stay in this device’s Keychain. They are never synced, stored in notes, or exposed through commands. If a re-signed app cannot access a saved key, re-enter it here."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                } header: { Text(String(localized: "Privacy")) }
                if model.busy { ProgressView().accessibilityLabel(String(localized: "Loading AI settings")) }
                if let error = model.error {
                    Section {
                        Text(error).font(NibFont.footnote).foregroundStyle(NibColor.warning)
                        NibButton(String(localized: "Reload settings"), symbol: .retry) { Task { await model.refresh() } }
                    }
                }
            }
            .font(NibFont.body)
            .scrollContentBackground(.hidden)
            .background(NibColor.backgroundSecondary)
            .navigationTitle(String(localized: "AI"))
            .onChange(of: model.error) { _, error in
                if let error, UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: error) }
            }
            .disabled(model.busy)
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { notification in
                guard notification.object as? SettingsStore === app.settings, !model.busy else { return }
                Task { await model.refresh() }
            }
        }
    }
}
