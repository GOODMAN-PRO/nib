import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

@MainActor
final class TranscriptPanelModel: ObservableObject {
    let app: NibApp
    let session: EditorSession?
    @Published var clips: [TranscriptList.Row] = []
    @Published var selectedClip = ""
    @Published var transcript: TranscriptGet.Output?
    @Published var error: String?
    @Published var busy = false
    @Published var playback: AudioPlaybackPayload?
    @Published var editIndex: Int?
    @Published var editText = ""
    private var subscription: EventSubscription?
    private var refreshing = false

    init(context: PanelContext) {
        app = context.app; session = context.session
        selectedClip = context.params["clip"]?.stringValue ?? ""
        editIndex = context.params["index"]?.intValue
        subscription = app.events.subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let playback = event.decode(AudioPlaybackPayload.self) { self.playback = playback }
                if event.type == TranscriptStore.changed || event.type == LiveTranscriber.statusEvent || event.type == NibEventType.committed {
                    await self.refresh()
                }
            }
        }
    }

    func reload() async {
        guard let doc = session?.document else { clips = []; transcript = nil; return }
        do {
            let result = try await app.bus.execute(TranscriptList.descriptor.id,
                ["doc": .string(NodeRef.document(doc).description)], session: session)
            clips = try result.decode(TranscriptList.Output.self).clips
            if !clips.contains(where: { $0.id == selectedClip }) { selectedClip = clips.first?.id ?? "" }
            await refresh()
        } catch { self.error = NibError.wrap(error).message }
    }

    func refresh() async {
        guard !refreshing, !selectedClip.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let ref = selectedClip
        do {
            let result = try await app.bus.execute(CommandIDs.transcriptGet, ["clip": .string(ref)], session: session)
            guard ref == selectedClip else { return }
            transcript = try result.decode(TranscriptGet.Output.self)
            if let editIndex, editText.isEmpty { editText = transcript?.segments.first { $0.index == editIndex }?.text ?? "" }
        } catch { self.error = NibError.wrap(error).message }
    }

    func run(_ command: String, _ params: JSONValue) {
        Task { @MainActor in
            busy = true; error = nil
            defer { busy = false }
            do {
                _ = try await app.bus.execute(command, params, session: session)
                if command == CommandIDs.transcriptEditSegment { editIndex = nil; editText = "" }
                await refresh()
            } catch { self.error = NibError.wrap(error).message }
        }
    }

    func menuContext(_ line: TranscriptSegment) -> MenuContext {
        MenuContext(app: app, session: session, doc: session?.document, page: session?.page, ref: selectedClip, index: line.index)
    }

    func perform(_ menu: MenuItemDescriptor, line: TranscriptSegment) {
        if menu.id == "transcription.line.edit" {
            // Selecting an editor is session UI; its eventual write uses transcript.editSegment.
            app.perform(menu.command, menu.params(menuContext(line)), session: session)
            editIndex = line.index; editText = line.text
        } else { run(menu.command, menu.params(menuContext(line))) }
    }

    deinit { subscription?.cancel() }
}

@MainActor
struct TranscriptPanel: View {
    let context: PanelContext
    @StateObject private var model: TranscriptPanelModel
    @State private var search = ""
    @State private var tab = TranscriptTab.transcript
    @State private var settings = false
    @State private var follow = true
    @FocusState private var searchFocused: Bool

    init(context: PanelContext) {
        self.context = context
        _model = StateObject(wrappedValue: TranscriptPanelModel(context: context))
    }

    private var lines: [TranscriptSegment] {
        (model.transcript?.segments ?? []).filter { search.isEmpty || $0.text.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: String(localized: "Transcript"), subtitle: model.transcript?.name, symbol: .transcript,
                onClose: { context.app.perform(CommandIDs.panelClose, ["id": .string(FeatTranscriptionFeature.panelID)], session: context.session) }) {
                NibIconButton(.settings, label: String(localized: "Recording Settings"), size: .panel) { settings.toggle() }
            }
            if model.clips.count > 1 {
                Picker(String(localized: "Recording"), selection: $model.selectedClip) {
                    ForEach(model.clips) { clip in Text(clip.name).tag(clip.id) }
                }
                .font(NibFont.callout)
                .padding(.horizontal, NibSpacing.l)
                .frame(minHeight: NibMetrics.hitTarget)
            }
            NibSegmentedControl(selection: $tab, options: TranscriptTab.allCases) { $0.title }
                .padding(.horizontal, NibSpacing.l)
                .padding(.bottom, NibSpacing.s)
            NibSearchField(text: $search, prompt: tab == .transcript ? String(localized: "Search transcript") : String(localized: "Search summary"))
                .focused($searchFocused)
                .padding(.horizontal, NibSpacing.l)
                .padding(.bottom, NibSpacing.s)
            if let error = model.error ?? model.transcript?.error?.message {
                Text(error).font(NibFont.footnote).foregroundStyle(NibColor.destructive)
                    .padding(NibSpacing.l).accessibilityLabel(String(localized: "Transcription error: \(error)"))
            }
            if settings {
                ScrollView { TranscriptRecordingSettings(app: context.app) }
            } else if model.selectedClip.isEmpty {
                NibEmptyState(symbol: .transcript, title: String(localized: "No recordings yet"),
                    message: String(localized: "Record audio to keep a transcript beside your notes."))
            } else if let index = model.editIndex {
                editor(index: index)
            } else if tab == .summary {
                summary
            } else {
                transcriptLines
            }
            if !settings && !model.selectedClip.isEmpty {
                footer
            }
        }
        .font(NibFont.body)
        .foregroundStyle(NibColor.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The sidebar host owns the Deep surface and the window's single droplet container.
        .task(id: context.session?.document) { await model.reload() }
        .task(id: model.selectedClip) {
            await model.refresh()
            // File-provider edits from another device need no local event to become visible.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                await model.refresh()
            }
        }
        .background {
            Button(String(localized: "Search transcript")) { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option]).hidden().accessibilityHidden(true)
        }
    }

    private var transcriptLines: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let active = activeIndex(at: timeline.date)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NibSpacing.s) {
                        if lines.isEmpty {
                            NibEmptyState(symbol: .transcript,
                                title: search.isEmpty ? String(localized: "No transcript yet") : String(localized: "No matching lines"),
                                message: search.isEmpty ? String(localized: "Generate a transcript, or enable live transcription in Recording Settings.") : nil)
                        }
                        ForEach(lines, id: \.index) { line in
                            transcriptRow(line, active: line.index == active).id(line.index)
                        }
                    }.padding(NibSpacing.l)
                }
                .onChange(of: active) { _, index in
                    if follow, search.isEmpty, let index { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func transcriptRow(_ line: TranscriptSegment, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.xs) {
            Button {
                model.run(TranscriptSeek.descriptor.id, ["clip": .string(model.selectedClip), "index": .number(Double(line.index))])
            } label: {
                Text(Self.timestamp(line.start)).font(NibFont.hud).foregroundStyle(NibColor.accent)
                    .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget, alignment: .leading)
            }
            .buttonStyle(.plain).hoverEffect(.highlight)
            .accessibilityLabel(String(localized: "Play from \(Self.timestamp(line.start)) and show linked page"))
            if let speaker = line.speaker { Text(speaker).font(NibFont.caption1Emphasis).foregroundStyle(NibColor.labelSecondary) }
            Text(line.text).font(NibFont.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(NibSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? NibColor.accentWash : NibColor.fill3.opacity(0), in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow))
        .accessibilityElement(children: .contain)
        .accessibilityValue(active ? String(localized: "Current transcript line") : "")
        .contextMenu {
            let menuContext = model.menuContext(line)
            ForEach(context.app.ui.menuItems(.transcriptSegment, menuContext), id: \.id) { menu in
                Button(menu.resolvedTitle(for: menuContext)) { model.perform(menu, line: line) }
            }
        }
        .onDrag { TranscriptDragPayload(clip: model.selectedClip, segments: [line.index]).provider(text: line.text) }
    }

    private func activeIndex(at date: Date) -> Int? {
        guard let p = model.playback, p.clip == model.selectedClip else { return nil }
        let elapsed = p.playing ? max(0, date.timeIntervalSince1970 - p.at) * p.rate : 0
        return TranscriptPageLink.activeIndex(model.transcript?.segments ?? [], at: p.t + elapsed)
    }

    private func editor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(String(localized: "Edit transcript line")).font(NibFont.headline)
            Text(String(localized: "Transcript corrections are saved to this device and cannot be undone."))
                .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            NibField(text: $model.editText, prompt: String(localized: "Transcript text"), lines: 3...12)
            ViewThatFits {
                HStack { editButtons(index) }
                VStack { editButtons(index) }
            }
            Spacer(minLength: 0)
        }.padding(NibSpacing.l)
    }

    @ViewBuilder private func editButtons(_ index: Int) -> some View {
        NibButton(String(localized: "Cancel"), shortcut: KeyboardShortcut(.escape, modifiers: [])) { model.editIndex = nil; model.editText = "" }
        NibButton(String(localized: "Save"), kind: .primary, shortcut: KeyboardShortcut(.return, modifiers: .command)) {
            model.run(CommandIDs.transcriptEditSegment, ["clip": .string(model.selectedClip), "index": .number(Double(index)), "text": .string(model.editText)])
        }.disabled(model.busy)
    }

    private var summary: some View {
        ScrollView {
            if let summary = model.transcript?.summary, !summary.isEmpty {
                let paragraphs = summary.components(separatedBy: "\n").filter { search.isEmpty || $0.localizedStandardContains(search) }
                if paragraphs.isEmpty { NibEmptyState(symbol: .search, title: String(localized: "No matching summary text")) }
                VStack(alignment: .leading, spacing: NibSpacing.m) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        if let t = TranscriptSummaryTime.firstTimestamp(in: paragraph) {
                            Button {
                                model.run(TranscriptSeek.descriptor.id, ["clip": .string(model.selectedClip), "t": .number(t)])
                            } label: {
                                Text(paragraph).font(NibFont.body).frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
                            }.buttonStyle(.plain).hoverEffect(.highlight)
                            .accessibilityHint(String(localized: "Play audio at the linked timestamp"))
                        } else {
                            Text(paragraph).font(NibFont.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(NibSpacing.l)
            } else {
                NibEmptyState(symbol: .assistant, title: String(localized: "No summary yet"),
                    message: String(localized: "Summarise this recording with your connected AI provider."))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: NibSpacing.s) {
            if tab == .transcript {
                NibToggle(String(localized: "Follow playback"), isOn: $follow)
                NibButton(String(localized: "Regenerate Transcript"), symbol: .replace, expands: true) {
                    model.run(CommandIDs.transcriptRegenerate, ["clip": .string(model.selectedClip)])
                }.disabled(model.busy)
            }
            if context.app.services.ai?.isConfigured == true && context.app.commands.descriptor(CommandIDs.meetingSummarize) != nil {
                NibButton(tab == .summary ? String(localized: "Regenerate Summary") : String(localized: "Summarise"), symbol: .assistant, expands: true) {
                    model.run(CommandIDs.meetingSummarize, ["clip": .string(model.selectedClip)])
                }.disabled(model.busy)
            }
            if model.busy { ProgressView().accessibilityLabel(String(localized: "Transcribing")) }
        }.padding(NibSpacing.l)
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                             : String(format: "%d:%02d", value / 60, value % 60)
    }
}

private enum TranscriptTab: String, CaseIterable {
    case transcript, summary
    var title: String { self == .transcript ? String(localized: "Transcript") : String(localized: "Summary") }
}

@MainActor
struct TranscriptRecordingSettings: View {
    let app: NibApp
    @State private var live = false
    @State private var cloud = false
    @State private var language = Locale.current.identifier
    @State private var languages: [TranscriptLanguage] = []
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(String(localized: "Recording Settings")).font(NibFont.headline).accessibilityAddTraits(.isHeader)
            NibToggle(String(localized: "Live transcription"), isOn: binding(TranscriptSettings.live, value: $live))
            NibToggle(String(localized: "Cloud transcription"), isOn: binding(TranscriptSettings.cloud, value: $cloud))
            Text(cloud ? String(localized: "Audio is sent to your configured AI provider. Long recordings update every minute and when recording stops.")
                       : String(localized: "On-device transcription keeps audio on this iPad or iPhone."))
                .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            NibButton(String(localized: "Enable Speech Recognition"), symbol: .microphone, expands: true) {
                Task { await authorise() }
            }
            NibSearchField(text: $search, prompt: String(localized: "Search languages"))
            Text(String(localized: "Language")).font(NibFont.headline)
            LazyVStack(spacing: 0) {
                ForEach(languages.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.id.localizedStandardContains(search) }) { item in
                    Button {
                        Task {
                            do {
                                _ = try await app.bus.execute(CommandIDs.settingsSet, ["name": .string(TranscriptSettings.language.name), "value": .string(item.id)])
                                language = item.id
                            } catch { self.error = NibError.wrap(error).message }
                        }
                    } label: {
                        NibRow(item.name, subtitle: item.onDevice ? String(localized: "Available on device") : String(localized: "On-device model unavailable"), icon: .language) {
                            if language == item.id { Image(nib: .checkmark).foregroundStyle(NibColor.accent) }
                        }
                    }.buttonStyle(.plain).hoverEffect(.highlight).accessibilityLabel(item.name)
                    .accessibilityValue(item.onDevice ? String(localized: "Available on device") : String(localized: "On-device model unavailable"))
                    .accessibilityAddTraits(language == item.id ? [.isSelected] : [])
                }
            }
            Text(String(localized: "Apple manages speech models. Add your language in Settings › General › Keyboard › Dictation Languages, connect to Wi-Fi and enable Dictation. Availability varies by device and language; Nib cannot start a model download. Use Cloud if the model remains unavailable."))
                .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            if let error { Text(error).font(NibFont.footnote).foregroundStyle(NibColor.destructive) }
        }
        .font(NibFont.body).foregroundStyle(NibColor.label).padding(NibSpacing.l)
        .task { await load() }
    }

    private func binding(_ key: SettingKey<Bool>, value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { next in
            Task { @MainActor in
                do {
                    _ = try await app.bus.execute(CommandIDs.settingsSet, ["name": .string(key.name), "value": .bool(next)])
                    value.wrappedValue = next
                } catch { self.error = NibError.wrap(error).message }
            }
        })
    }

    private func load() async {
        do {
            live = try await setting(TranscriptSettings.live)
            cloud = try await setting(TranscriptSettings.cloud)
            language = try await setting(TranscriptSettings.language)
            let result = try await app.bus.execute(TranscriptLanguages.descriptor.id)
            languages = try result.decode(TranscriptLanguages.Output.self).languages
        } catch { self.error = NibError.wrap(error).message }
    }

    private func setting<T>(_ key: SettingKey<T>) async throws -> T {
        let result = try await app.bus.execute(CommandIDs.settingsGet, ["name": .string(key.name)])
        guard let value = result["value"], value != .null else { return key.defaultValue }
        return try value.decode(T.self)
    }

    private func authorise() async {
        do { _ = try await app.bus.execute(TranscriptAuthorise.descriptor.id); error = nil; await load() }
        catch { self.error = NibError.wrap(error).message }
    }
}

struct TranscriptDragPayload: Codable, Equatable {
    static let typeIdentifier = "app.nib.transcript-lines"
    var clip: String
    var segments: [Int]

    func validated() throws -> Self {
        guard case .audio? = NodeRef(clip), !segments.isEmpty, segments.allSatisfy({ $0 >= 0 }) else {
            throw NibError.invalid("Invalid transcript drop", path: "$.segments")
        }
        return self
    }

    func provider(text: String) -> NSItemProvider {
        let provider = NSItemProvider(object: text as NSString)
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .all) { completion in
                completion(data, nil); return nil
            }
        }
        return provider
    }
}

@MainActor
final class TranscriptDropAttachment: NSObject, CanvasAttachment, UIDropInteractionDelegate {
    weak var host: CanvasHost?
    private var interaction: UIDropInteraction?
    func attach(to host: CanvasHost) {
        self.host = host
        let interaction = UIDropInteraction(delegate: self)
        host.canvasView.addInteraction(interaction)
        self.interaction = interaction
    }
    func detach(from host: CanvasHost) {
        if let interaction { host.canvasView.removeInteraction(interaction) }
        interaction = nil; self.host = nil
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [TranscriptDragPayload.typeIdentifier])
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let host, host.pagePoint(session.location(in: host.canvasView)) != nil else { return UIDropProposal(operation: .forbidden) }
        return UIDropProposal(operation: .copy)
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let host, let location = host.pagePoint(session.location(in: host.canvasView)) else { return }
        let doc = host.documentID
        let app = host.app
        let editorSession = host.session
        for item in session.items where item.itemProvider.hasItemConformingToTypeIdentifier(TranscriptDragPayload.typeIdentifier) {
            item.itemProvider.loadDataRepresentation(forTypeIdentifier: TranscriptDragPayload.typeIdentifier) { [weak self] data, error in
                Task { @MainActor in
                    do {
                        if let error { throw error }
                        guard let data else { throw NibError.invalid("The transcript drop has no data") }
                        let payload = try JSONDecoder().decode(TranscriptDragPayload.self, from: data).validated()
                        _ = try await app.bus.execute(CommandIDs.transcriptInsert,
                            ["clip": .string(payload.clip), "segments": try JSONValue.from(payload.segments),
                             "page": .string(NodeRef.page(doc, location.page).description), "at": try JSONValue.from(location.point)], session: editorSession)
                    } catch { self?.host?.session.floatingHost?.postToast(NibError.wrap(error).message) }
                }
            }
        }
    }
}

/// Summaries owned by F089 remain plain text; timestamp links also work with Markdown timeline rows.
enum TranscriptSummaryTime {
    static func firstTimestamp(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,3}):(\d{2})(?::(\d{2}))?(?!\d)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let firstRange = Range(match.range(at: 1), in: text),
              let secondRange = Range(match.range(at: 2), in: text),
              let first = Double(text[firstRange]), let second = Double(text[secondRange]), second < 60 else { return nil }
        if let thirdRange = Range(match.range(at: 3), in: text), let third = Double(text[thirdRange]), third < 60 {
            return first * 3600 + second * 60 + third
        }
        return first * 60 + second
    }
}
