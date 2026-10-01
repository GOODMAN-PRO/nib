import SwiftUI
import NibContracts
import NibDesign

@MainActor
final class SummaryPanelModel: ObservableObject {
    struct Clips: Decodable { var clips: [Row] }
    struct Row: Decodable, Identifiable { var id: String; var name: String }
    let context: PanelContext
    @Published var clips: [Row] = []
    @Published var clip = ""
    @Published var transcript: MeetingTranscript?
    @Published var error: String?
    @Published var message: String?
    @Published var busy = false
    @Published var recording = false
    private var subscription: EventSubscription?
    private var loading = false
    init(context: PanelContext) {
        self.context = context
        clip = context.params["clip"]?.stringValue ?? ""
        subscription = context.app.events.subscribe { [weak self] event in
            guard [NibEventType.committed, NibEventType.audioRecording, LiveSummarizer.changed, "transcript.changed"].contains(event.type) else { return }
            Task { @MainActor [weak self] in await self?.reload() }
        }
    }
    deinit { subscription?.cancel() }
    func reload() async {
        guard !loading, let doc = context.session?.document else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await context.app.bus.execute("transcript.list", ["doc": .string(NodeRef.document(doc).description)], session: context.session)
            clips = try result.decode(Clips.self).clips
            if !clips.contains(where: { $0.id == clip }) { clip = clips.last?.id ?? "" }
            guard !clip.isEmpty else { transcript = nil; return }
            let selected = clip
            let value = try await context.app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(selected)], session: context.session)
            guard selected == clip else { return }
            transcript = try value.decode(MeetingTranscript.self)
            let runtime = context.app.services.get(LiveSummarizer.serviceKey, as: LiveSummarizer.self)
            let state = runtime?.recordings[clip]?.state
            recording = state == "recording" || state == "paused"
            error = runtime?.errors[clip] ?? transcript?.error?.message
        } catch { transcript = nil; self.error = NibError.wrap(error).message }
    }
    var working: Bool { busy || context.app.services.get(LiveSummarizer.serviceKey, as: LiveSummarizer.self)?.busy.contains(clip) == true }
    func run(_ command: String, _ params: JSONValue) {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await context.app.bus.execute(command, params, session: context.session)
                await reload()
                if command == CommandIDs.meetingGenerateNotes { message = String(localized: "Meeting notes added to your document.") }
            } catch { self.error = NibError.wrap(error).message }
        }
    }
}

@MainActor
struct SummaryPanel: View {
    let context: PanelContext
    @StateObject private var model: SummaryPanelModel
    @State private var translated = true
    @State private var search = ""
    @State private var confirmTranscript = false
    init(context: PanelContext) {
        self.context = context
        _model = StateObject(wrappedValue: SummaryPanelModel(context: context))
    }
    private var summary: MeetingSummary? { MeetingSummary.read(model.transcript?.summary) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                if model.clips.count > 1 {
                    Picker(String(localized: "Recording"), selection: $model.clip) {
                        ForEach(model.clips) { Text($0.name).tag($0.id) }
                    }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                }
                HStack {
                    Text(model.transcript?.name ?? String(localized: "Meeting Summary")).font(NibFont.headline)
                    Spacer(minLength: NibSpacing.s)
                    NibIconButton(.settings, label: String(localized: "Recording Settings"), size: .panel) {
                        model.run(CommandIDs.settingsOpen, ["page": .string(FeatMeetingAIFeature.settingsID)])
                    }
                }
                NibButton(String(localized: "Transcript"), symbol: .transcript, kind: .plain) {
                    model.run(CommandIDs.panelOpen, ["id": "transcription", "clip": .string(model.clip)])
                }
                if let error = model.error { NibBanner(error) }
                if let message = model.message { NibBanner(message, style: .info) }
                if model.working { NibTraceRow(String(localized: "Preparing meeting notes…"), phase: .running) }
                if model.clip.isEmpty {
                    NibEmptyState(symbol: .microphone, title: String(localized: "No recordings yet"),
                        message: String(localized: "Record a meeting and enable Live Summary in Recording Settings."))
                } else {
                    if let summary {
                        NibSearchField(text: $search, prompt: String(localized: "Search summary"))
                        if summary.windows.contains(where: { $0.translation != nil }) {
                            NibToggle(String(localized: "Translated to \(summary.targetLanguage)"), isOn: $translated)
                        }
                        let windows = summary.windows.filter { window in
                            search.isEmpty || (window.content.keyPoints + window.content.decisions + window.content.actionItems.map(\.display)
                                + (window.translation?.keyPoints ?? []) + (window.translation?.decisions ?? [])
                                + (window.translation?.actionItems.map(\.display) ?? [])).contains { $0.localizedStandardContains(search) }
                        }
                        if windows.isEmpty { NibEmptyState(symbol: .search, title: String(localized: "No matching summary text")) }
                        ForEach(windows) { window in timeline(window) }
                    } else if let legacy = model.transcript?.summary, !legacy.isEmpty {
                        Text(legacy).font(NibFont.body).textSelection(.enabled)
                    } else {
                        NibEmptyState(symbol: .transcript, title: String(localized: "No summary yet"),
                            message: String(localized: "Summarise a transcript, or turn on Live Summary to update it while recording."))
                    }
                    NibButton(summary == nil ? String(localized: "Summarise") : String(localized: "Regenerate Summary"),
                        symbol: .assistant, kind: .primary, expands: true) {
                            model.run(CommandIDs.meetingSummarize, ["clip": .string(model.clip)])
                        }.disabled(model.working)
                    if !model.recording {
                        NibButton(String(localized: "Generate Notes"), symbol: .text, expands: true) { notes("generate") }.disabled(model.working)
                        NibButton(String(localized: "Enhance Notes"), symbol: .text, expands: true) { notes("enhance") }.disabled(model.working)
                        if confirmTranscript {
                            NibBanner(String(localized: "Regenerating replaces transcript corrections and cannot be undone."),
                                action: NibAction(String(localized: "Replace Transcript")) {
                                    confirmTranscript = false
                                    model.run(CommandIDs.transcriptRegenerate, ["clip": .string(model.clip)])
                                })
                            NibButton(String(localized: "Cancel"), kind: .plain) { confirmTranscript = false }
                        } else {
                            NibButton(String(localized: "Regenerate Transcript"), symbol: .transcript, kind: .plain, expands: true) {
                                confirmTranscript = true
                            }.disabled(model.working)
                        }
                    }
                }
            }.padding(NibSpacing.l)
        }
        .font(NibFont.body).foregroundStyle(NibColor.label)
        // The document sidebar supplies Deep glass, motion fallbacks and its one droplet container.
        .onChange(of: model.clip) { _, _ in confirmTranscript = false }
        .task { await model.reload() }
        .task(id: model.clip) {
            await model.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                await model.reload()
            }
        }
    }
    private func notes(_ mode: String) {
        model.run(CommandIDs.meetingGenerateNotes, ["clip": .string(model.clip), "mode": .string(mode)])
    }
    private func timeline(_ window: SummaryWindow) -> some View {
        let content = translated ? (window.translation ?? window.content) : window.content
        return VStack(alignment: .leading, spacing: NibSpacing.s) {
            Button {
                model.run("transcript.seek", ["clip": .string(model.clip), "t": .number(window.start)])
            } label: {
                Text(MeetingTime.label(window.start) + " – " + MeetingTime.label(window.end))
                    .font(NibFont.hud).foregroundStyle(NibColor.accent)
                    .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).hoverEffect(.highlight)
                .accessibilityLabel(String(localized: "Play from \(MeetingTime.label(window.start)) and show linked notes"))
            Text(Locale.current.localizedString(forLanguageCode: window.language) ?? window.language)
                .font(NibFont.caption1Emphasis).foregroundStyle(NibColor.labelSecondary)
            ForEach(window.flags, id: \.self) { flag in NibBanner(flag.title) }
            section(String(localized: "Key Points"), lines: content.keyPoints)
            section(String(localized: "Decisions"), lines: content.decisions)
            section(String(localized: "Action Items"), lines: content.actionItems.map(\.display))
            Divider().overlay(NibColor.separator)
        }
    }
    @ViewBuilder private func section(_ title: String, lines: [String]) -> some View {
        if !lines.isEmpty {
            Text(title).font(NibFont.bodyEmphasis).accessibilityAddTraits(.isHeader)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, text in
                Text(text).font(NibFont.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

@MainActor
struct MeetingRecordingSettings: View {
    let app: NibApp
    @State private var live = false
    @State private var transcription = false
    @State private var cloud = false
    @State private var language = MeetingSettings.language.defaultValue
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                NibToggle(String(localized: "Live Summary"), isOn: binding(MeetingSettings.live, value: $live))
                Text(String(localized: "With an AI provider connected, new transcript speech is summarised about once a minute. No recording time limit."))
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                NibToggle(String(localized: "Live transcription"), isOn: binding(MeetingSettings.transcription, value: $transcription))
                NibToggle(String(localized: "Cloud transcription"), isOn: binding(MeetingSettings.cloud, value: $cloud))
                Text(cloud ? String(localized: "Audio is sent to your provider's Whisper-compatible endpoint. Disable Cloud to use Apple Speech.")
                           : String(localized: "Apple Speech runs on device when its language model is available. Language settings show which languages use Apple servers."))
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                Picker(String(localized: "Summary language"), selection: Binding(get: { language }, set: { write(MeetingSettings.language.name, .string($0)) })) {
                    ForEach(languages, id: \.self) { code in Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code) }
                }.font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                NibButton(String(localized: "Transcription Languages and Speech Access"), symbol: .transcript, kind: .plain, expands: true) {
                    app.perform(CommandIDs.settingsOpen, ["page": "transcription.recording"])
                }
                if let error { NibBanner(error) }
            }.padding(NibSpacing.l).disabled(saving)
        }.font(NibFont.body).foregroundStyle(NibColor.label)
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)) { _ in Task { await load() } }
    }
    private var languages: [String] { Array(Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + [language])).sorted {
        (Locale.current.localizedString(forLanguageCode: $0) ?? $0) < (Locale.current.localizedString(forLanguageCode: $1) ?? $1)
    } }
    private func binding(_ key: SettingKey<Bool>, value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { write(key.name, .bool($0)) })
    }
    private func write(_ name: String, _ value: JSONValue) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                if name == MeetingSettings.live.name, value.boolValue == true {
                    let calls: JSONValue = [["command": .string(CommandIDs.settingsSet), "params": ["name": .string(MeetingSettings.transcription.name), "value": true]],
                        ["command": .string(CommandIDs.settingsSet), "params": ["name": .string(name), "value": value]]]
                    _ = try await app.bus.execute(CommandIDs.batch, ["calls": calls])
                } else {
                    _ = try await app.bus.execute(CommandIDs.settingsSet, ["name": .string(name), "value": value])
                }
                error = nil; await load()
            } catch { self.error = NibError.wrap(error).message; await load() }
        }
    }
    private func setting<T>(_ key: SettingKey<T>) async throws -> T {
        let result = try await app.bus.execute(CommandIDs.settingsGet, ["name": .string(key.name)])
        return try result["value"]?.decode(T.self) ?? key.defaultValue
    }
    private func load() async {
        do {
            live = try await setting(MeetingSettings.live)
            transcription = try await setting(MeetingSettings.transcription)
            cloud = try await setting(MeetingSettings.cloud)
            let stored = try await setting(MeetingSettings.language)
            if stored != language { language = stored }
        } catch { self.error = NibError.wrap(error).message }
    }
}
