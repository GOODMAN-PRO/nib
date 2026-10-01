import Combine
import Foundation
import SwiftUI
import NibContracts
import NibDesign

/// A grouped, opaque settings surface. The shared switch is its only liquid element.
@MainActor
struct WritingAidsPage: View {
    @StateObject private var model: WritingAidsModel
    @State private var word = ""
    @State private var prefix = ""
    @State private var hasStarted = false

    init(app: NibApp) {
        _model = StateObject(wrappedValue: WritingAidsModel(app: app))
    }

    var body: some View {
        Form {
            Section {
                NibRow(String(localized: "Handwriting Spellcheck"), icon: .recognisedText) {
                    NibToggle("", isOn: Binding(get: { model.spellcheck }, set: {
                        model.setSpellcheck($0)
                    }))
                    .accessibilityLabel(String(localized: "Handwriting Spellcheck for New Documents"))
                }
                NibRow(String(localized: "Math Assist"), icon: .math) {
                    NibToggle("", isOn: Binding(get: { model.mathAssist }, set: { model.setMathAssist($0) }))
                        .accessibilityLabel(String(localized: "Math Assist"))
                }
                NibRow(String(localized: "Synthesis Font"), icon: .text) {
                    Picker(String(localized: "Synthesis Font"), selection: Binding(get: { model.font }, set: {
                        model.setFont($0)
                    })) {
                        ForEach(InkSynthFont.allCases, id: \.self) { font in
                            Text(verbatim: font.rawValue).font(NibFont.body).tag(font)
                        }
                    }
                    .labelsHidden()
                    .font(NibFont.body)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .hoverEffect(.highlight)
                }
            } footer: {
                Text(String(localized: "Spellcheck and Math Assist apply to new documents. Change an existing document in its Writing Aids menu. The synthesis font is used for spelling corrections and font restyling on this device."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            .disabled(model.busy || !model.loaded)

            Section {
                TextField(String(localized: "Filter Custom Words"), text: $prefix)
                    .font(NibFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(String(localized: "Filter Custom Words"))
                ForEach(model.words, id: \.self) { entry in
                    NibRow(entry, icon: .dictionary) {
                        NibIconButton(.trash, label: String(localized: "Remove \(entry) from Dictionary"), size: .panel) {
                            model.change(CommandIDs.dictionaryRemove, ["word": .string(entry)])
                        }
                        .hoverEffect(.highlight)
                        .disabled(model.busy)
                    }
                }
                if model.words.isEmpty, model.loaded {
                    Text(prefix.isEmpty ? String(localized: "Add names and specialised words to stop spelling underlines.")
                                        : String(localized: "No custom words match this filter."))
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                if model.cursor != nil {
                    NibButton(String(localized: "Show More Words")) { model.loadMore() }
                        .disabled(model.busy)
                }
                TextField(String(localized: "Custom Word"), text: $word)
                    .font(NibFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .onSubmit(addWord)
                    .accessibilityLabel(String(localized: "Custom Word"))
                NibButton(String(localized: "Add Word"), symbol: .plus, kind: .plain,
                          shortcut: KeyboardShortcut(.return, modifiers: .command), action: addWord)
                    .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            } header: {
                Text(String(localized: "Personal Dictionary")).font(NibFont.footnote).textCase(nil)
            } footer: {
                Text(String(localized: "Custom words ignore case and sync with your library."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            if let error = model.error {
                Section {
                    Text(verbatim: error).font(NibFont.body).foregroundStyle(NibColor.destructive)
                        .accessibilityLabel(String(localized: "Writing Aids: \(error)"))
                    NibButton(String(localized: "Reload Writing Aids"), symbol: .retry) { model.refresh() }
                }
            }
        }
        .font(NibFont.body)
        .foregroundStyle(NibColor.label)
        .scrollContentBackground(.hidden)
        .background(NibColor.groupedBackground)
        .navigationTitle(String(localized: "Writing Aids"))
        .overlay(alignment: .topTrailing) {
            if model.busy {
                ProgressView().padding(NibSpacing.m)
                    .accessibilityLabel(String(localized: "Updating Writing Aids"))
            }
        }
        .task(id: prefix) {
            do {
                if hasStarted { try await Task.sleep(for: .milliseconds(200)) }
                hasStarted = true
                guard !Task.isCancelled else { return }
                model.prefix = prefix
                await model.reload()
            } catch { /* A newer filter replaces this request. */ }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: model.app.settings)
            .filter { WritingAidsModel.isRelevantSetting($0.userInfo?["name"] as? String) }
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in
            model.refresh()
        }
    }

    private func addWord() {
        let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !model.busy else { return }
        model.change(CommandIDs.dictionaryAdd, ["word": .string(value)]) { word = "" }
    }
}

/// UI reads and writes use registered commands, including paged dictionary queries. Nothing writes SettingsStore.
@MainActor
final class WritingAidsModel: ObservableObject {
    let app: NibApp
    @Published var spellcheck = NibSettings.spellcheckNewDocuments.defaultValue
    @Published var mathAssist = NibSettings.mathAssistSuggestions.defaultValue
    @Published var font: InkSynthFont = .noteworthy
    @Published var words: [String] = []
    @Published var cursor: String?
    @Published var busy = false
    @Published var loaded = false
    @Published var error: String?
    var prefix = ""
    private var generation = 0

    init(app: NibApp) { self.app = app }

    nonisolated static func isRelevantSetting(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == NibSettings.spellcheckNewDocuments.name || name == NibSettings.mathAssistSuggestions.name
            || name == InkSynthSettings.font.name || name.hasPrefix(NibSettings.dictionaryPrefix)
    }

    func setSpellcheck(_ value: Bool) {
        guard !busy else { return }
        let old = spellcheck
        spellcheck = value
        change(CommandIDs.settingsSet, ["name": .string(NibSettings.spellcheckNewDocuments.name), "value": .bool(value)],
               failure: { self.spellcheck = old })
    }

    func setMathAssist(_ value: Bool) {
        guard !busy else { return }
        let old = mathAssist
        mathAssist = value
        change(CommandIDs.settingsSet, ["name": .string(NibSettings.mathAssistSuggestions.name), "value": .bool(value)],
               failure: { self.mathAssist = old })
    }

    func setFont(_ value: InkSynthFont) {
        guard !busy else { return }
        let old = font
        font = value
        change(CommandIDs.settingsSet, ["name": .string(InkSynthSettings.font.name), "value": .string(value.rawValue)],
               failure: { self.font = old })
    }

    func refresh() { Task { await reload() } }

    func reload() async {
        generation += 1
        let request = generation
        do {
            let spell = try await read(CommandIDs.settingsGet, ["name": .string(NibSettings.spellcheckNewDocuments.name)])
            let math = try await read(CommandIDs.settingsGet, ["name": .string(NibSettings.mathAssistSuggestions.name)])
            let synthesis = try await read(CommandIDs.settingsGet, ["name": .string(InkSynthSettings.font.name)])
            let dictionary = try await read(CommandIDs.dictionaryList, ["prefix": .string(prefix), "limit": 100])
            guard request == generation, !Task.isCancelled else { return }
            spellcheck = spell["value"]?.boolValue ?? NibSettings.spellcheckNewDocuments.defaultValue
            mathAssist = math["value"]?.boolValue ?? NibSettings.mathAssistSuggestions.defaultValue
            font = synthesis["value"]?.stringValue.flatMap { InkSynthFont(name: $0) } ?? .noteworthy
            words = dictionary["words"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            cursor = dictionary["cursor"]?.stringValue
            loaded = true
            error = nil
        } catch {
            if request == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func change(_ command: String, _ params: JSONValue, failure: @escaping () -> Void = {}, success: @escaping () -> Void = {}) {
        guard !busy else { return }
        generation += 1 // Invalidate reads started before an optimistic control change.
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await read(command, params)
                success()
                await reload()
            } catch {
                failure()
                self.error = error.localizedDescription
            }
        }
    }

    func loadMore() {
        guard !busy, let cursor else { return }
        busy = true
        let request = generation
        Task {
            defer { busy = false }
            do {
                let value = try await read(CommandIDs.dictionaryList,
                                           ["prefix": .string(prefix), "limit": 100, "cursor": .string(cursor)])
                guard request == generation else { return }
                words.append(contentsOf: (value["words"]?.arrayValue ?? []).compactMap { $0.stringValue })
                self.cursor = value["cursor"]?.stringValue
            } catch { self.error = error.localizedDescription }
        }
    }

    private func read(_ command: String, _ params: JSONValue) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params)).value
    }
}
