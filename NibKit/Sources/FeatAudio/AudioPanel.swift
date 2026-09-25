import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

/// The Audio sidebar tab (S-045, S-047, S-048, S-056, S-088, S-116; DESIGN.md §14.13): the recorder (dot, clock, live
/// waveform, Pause and Stop) while recording, the document's clips (tap to play; Rename, Share, Delete and other
/// features' actions from `MenuLocation.audioClip`), and the playback bar (play/pause, ±10 s, the document timeline
/// with a dot where each clip starts, speed, skip silence, noise reduction). It sits inside the sidebar's Deep panel,
/// so it draws no droplets of its own. Every action runs an `audio.*` command.
struct AudioPanelView: View {
    @ObservedObject var audio: AudioController
    @StateObject private var model: AudioPanelModel
    @State private var failure: String?
    @State private var renaming: AudioClip?
    @State private var renameShown = false
    @State private var renameText = ""
    @State private var confirming: PendingAction?
    @State private var share: ShareItem?

    init(context: PanelContext, audio: AudioController) {
        self.audio = audio
        _model = StateObject(wrappedValue: AudioPanelModel(app: context.app,
                                                           session: context.session ?? context.app.services.sessions.active))
    }

    private var app: NibApp { model.app }

    /// Clips that can play: everything but the one being recorded.
    private var playable: [AudioClip] { model.clips.filter { $0.id != audio.recording?.clip } }

    var body: some View {
        VStack(spacing: 0) {
            notices
            recorder
            if model.clips.isEmpty {
                ScrollView {
                    NibEmptyState(symbol: .record, title: String(localized: "No recordings yet"),
                                  message: String(localized: "Record a lecture or a meeting while you take notes. Your notes stay linked to the moment you wrote them."),
                                  primary: emptyAction)
                        .frame(maxWidth: .infinity)
                }
            } else {
                clipList
                if let doc = model.doc, !playable.isEmpty {
                    Rectangle()
                        .fill(NibColor.separatorSoft)
                        .frame(height: 0.5)
                    AudioPlaybackBar(audio: audio, doc: doc, clips: playable, perform: execute)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(String(localized: "Rename Recording"), isPresented: $renameShown) {
            TextField(String(localized: "Name"), text: $renameText)
            Button(String(localized: "Rename")) { commitRename() }
            Button(String(localized: "Cancel"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(confirming?.title ?? "", isPresented: confirmBinding, titleVisibility: .visible,
                            presenting: confirming) { pending in
            Button(pending.button, role: .destructive) { execute(pending.command, pending.params) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        .sheet(item: $share) { item in
            ShareSheet(url: item.url)
                .ignoresSafeArea()
        }
    }

    private var emptyAction: NibAction? {
        guard audio.recording == nil, model.doc != nil else { return nil }
        return NibAction(String(localized: "Record Audio"), handler: { startRecording() })
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if let message = failure ?? audio.lastError {
            notice(message) {
                failure = nil
                audio.lastError = nil
            }
        }
        if audio.microphoneDenied {
            HStack(alignment: .top, spacing: NibSpacing.s) {
                Image(nib: .warningTriangle)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                    Text(String(localized: "Microphone access is off for Nib. Turn it on in Settings to record."))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.label)
                    Button(String(localized: "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(NibColor.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NibSpacing.m)
            .padding(.top, NibSpacing.s)
        }
    }

    private func notice(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: NibSpacing.s) {
            Image(nib: .warningTriangle)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            NibIconButton(.xmark, label: String(localized: "Dismiss"), size: .round, action: dismiss)
        }
        .padding(.leading, NibSpacing.m)
        .padding(.top, NibSpacing.xs)
    }

    // MARK: Recorder

    @ViewBuilder
    private var recorder: some View {
        if let r = audio.recording {
            if r.doc == model.doc {
                RecorderView(audio: audio, paused: r.pausedAt != nil,
                             pause: { execute("audio.record", ["action": .string(r.pausedAt == nil ? "pause" : "resume")]) },
                             stop: { execute("audio.record", ["action": "stop"]) })
            } else {
                elsewhere(r)
            }
        } else if model.doc != nil && !model.clips.isEmpty {
            NibButton(String(localized: "Record Audio"), symbol: .record, kind: .primary, expands: true) { startRecording() }
                .padding(.horizontal, NibSpacing.m)
                .padding(.vertical, NibSpacing.s)
        }
    }

    /// One recording app-wide: from another document's tab it can be found and stopped.
    private func elsewhere(_ r: AudioController.Recording) -> some View {
        let title = app.services.library?.node(r.doc)?.title ?? String(localized: "another document")
        return HStack(spacing: NibSpacing.s) {
            Circle()
                .fill(NibColor.destructive)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Recording"))
                    .font(NibFont.headline)
                    .foregroundStyle(NibColor.label)
                Text(String(localized: "In \u{201C}\(title)\u{201D}"))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            NibButton(String(localized: "Show"), kind: .plain, size: .compact) {
                execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(r.doc).description)])
            }
            NibIconButton(.stop, label: String(localized: "Stop Recording"), size: .panel) {
                execute("audio.record", ["action": "stop"])
            }
        }
        .padding(.leading, NibSpacing.m)
        .padding(.vertical, NibSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    // MARK: Clips

    private var clipList: some View {
        ScrollView {
            LazyVStack(spacing: NibSpacing.xxs) {
                ForEach(model.clips, id: \.id) { clip in
                    row(clip)
                }
            }
            .padding(.horizontal, NibSpacing.xs)
            .padding(.vertical, NibSpacing.xs)
        }
    }

    private func row(_ clip: AudioClip) -> some View {
        let doc = model.doc
        let recordingThis = audio.recording?.clip == clip.id && audio.recording?.doc == doc
        let current = audio.playback.map { $0.clip == clip.id && $0.doc == doc } ?? false
        let playing = current && audio.playback?.isPlaying == true
        let items = menuItems(clip)
        return AudioClipRow(clip: clip, subtitle: subtitle(clip, recording: recordingThis), isCurrent: current,
                            isPlaying: playing, isRecording: recordingThis) {
            guard let doc, !recordingThis else { return }
            if playing {
                execute("audio.pause", [:])
            } else {
                execute("audio.play", ["clip": .string(NodeRef.audio(doc, clip.id).description)])
            }
        }
        .contextMenu {
            Button {
                startRename(clip)
            } label: {
                Label { Text(String(localized: "Rename")) } icon: { Image(nib: .pencil) }
            }
            ForEach(items, id: \.id) { item in
                Button(role: item.destructive ? .destructive : nil) {
                    run(item, clip)
                } label: {
                    Label {
                        Text(item.title)
                    } icon: {
                        if let symbol = item.icon.flatMap(NibSymbol.init(systemName:)) { Image(nib: symbol) }
                    }
                }
            }
        }
        .accessibilityActions {
            Button(String(localized: "Rename")) { startRename(clip) }
            ForEach(items, id: \.id) { item in
                Button(item.title) { run(item, clip) }
            }
        }
    }

    private func subtitle(_ clip: AudioClip, recording: Bool) -> String {
        let when = Date(timeIntervalSince1970: clip.start).formatted(date: .abbreviated, time: .shortened)
        var parts = [when]
        parts.append(recording ? String(localized: "Recording") : AudioText.clock(clip.duration))
        if let page = clip.page, let number = model.pages[page] { parts.append(String(localized: "Page \(number)")) }
        return parts.joined(separator: " · ")
    }

    private func menuItems(_ clip: AudioClip) -> [MenuItemDescriptor] {
        guard let doc = model.doc else { return [] }
        let context = MenuContext(app: app, session: model.session, doc: doc, page: clip.page,
                                  ref: NodeRef.audio(doc, clip.id).description)
        return app.ui.menuItems(.audioClip, context)
    }

    // MARK: Actions

    private func startRecording() {
        guard let doc = model.doc else { return }
        execute("audio.record", ["doc": .string(NodeRef.document(doc).description), "action": "start"])
    }

    private func run(_ item: MenuItemDescriptor, _ clip: AudioClip) {
        guard let doc = model.doc else { return }
        let context = MenuContext(app: app, session: model.session, doc: doc, page: clip.page,
                                  ref: NodeRef.audio(doc, clip.id).description)
        let params = item.params(context)
        guard item.destructive else {
            execute(item.command, params)
            return
        }
        let deleting = item.command == "audio.delete"
        confirming = PendingAction(
            title: deleting ? String(localized: "Delete \u{201C}\(clip.name)\u{201D}?") : item.title,
            button: item.title, command: item.command, params: params,
            message: deleting
                ? String(localized: "The recording and its audio file are removed from this document for good. This can't be undone.")
                : String(localized: "This can't be undone."))
    }

    private func startRename(_ clip: AudioClip) {
        renameText = clip.name
        renaming = clip
        renameShown = true
    }

    private func commitRename() {
        guard let clip = renaming, let doc = model.doc else { return }
        renaming = nil
        execute("audio.rename", ["clip": .string(NodeRef.audio(doc, clip.id).description), "name": .string(renameText)])
    }

    /// Runs a command as the user; a `tmp:` url in the result (audio.export) opens the share sheet.
    private func execute(_ command: String, _ params: JSONValue) {
        let session = model.session
        let bus = app.bus
        let assets = app.services.assets
        Task { @MainActor in
            do {
                let value = try await bus.execute(command, params, session: session)
                failure = nil
                if let url = value["url"]?.stringValue, url.hasPrefix("tmp:") {
                    try await presentShare(url, name: value["name"]?.stringValue, ext: value["ext"]?.stringValue,
                                           assets: assets)
                }
            } catch {
                // Microphone off has its own notice with Open Settings; don't repeat it.
                failure = command == "audio.record" && audio.microphoneDenied ? nil : NibError.wrap(error).message
            }
        }
    }

    private func presentShare(_ tmp: String, name: String?, ext: String?, assets: AssetStore?) async throws {
        guard let file = assets?.temporaryURL(AssetRef(String(tmp.dropFirst(4)))) else {
            throw NibError(.notFound, String(localized: "The exported file is no longer available. Try again."))
        }
        let title = name ?? String(localized: "Recording")
        let suffix = ext ?? file.pathExtension
        let copy = try await Task.detached(priority: .userInitiated) {
            try AudioFiles.shareCopy(of: file, name: title, ext: suffix)
        }.value
        share = ShareItem(url: copy)
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }
}

/// The document the tab shows and its clips, refreshed on every commit to that document.
@MainActor
final class AudioPanelModel: ObservableObject {
    let app: NibApp
    let session: EditorSession?
    @Published private(set) var doc: DocumentID?
    @Published private(set) var clips: [AudioClip] = []
    /// Page numbers (1-based) for the clip rows.
    @Published private(set) var pages: [PageID: Int] = [:]
    private var commits: EventSubscription?
    private var cancellables = Set<AnyCancellable>()

    init(app: NibApp, session: EditorSession?) {
        self.app = app
        self.session = session
        doc = session?.document
        reload()
    }

    func start() {
        guard commits == nil else { return }
        commits = app.bus.observeCommits { [weak self] changes in
            guard let self, let doc = self.doc, changes.headChanged(doc) else { return }
            self.reload()
        }
        session?.$document
            .removeDuplicates()
            .sink { [weak self] doc in
                self?.doc = doc
                self?.reload()
            }
            .store(in: &cancellables)
        reload()
        repairIfNeeded()
    }

    func stop() {
        commits?.cancel()
        commits = nil
        cancellables.removeAll()
    }

    func reload() {
        guard let doc, let content = try? app.workspace.content(doc) else {
            clips = []
            pages = [:]
            return
        }
        clips = content.liveAudio
        var numbers: [PageID: Int] = [:]
        for (i, page) in content.livePages.enumerated() { numbers[page.id] = i + 1 }
        pages = numbers
    }

    /// A clip at zero length with nothing recording was cut short by a crash: `audio.record stop` repairs it.
    private func repairIfNeeded() {
        guard let doc, AudioController.of(app.services)?.recording == nil,
              clips.contains(where: { $0.duration <= 0 }) else { return }
        app.perform("audio.record", ["doc": .string(NodeRef.document(doc).description), "action": "stop"],
                    session: session)
    }
}

/// While recording in this document: a `destructive` dot, the clock in HUD type, a live waveform in
/// `labelSecondary` bars (no colour), Pause and Stop.
private struct RecorderView: View {
    @ObservedObject var audio: AudioController
    let paused: Bool
    let pause: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack(spacing: NibSpacing.s) {
                Circle()
                    .fill(paused ? NibColor.labelTertiary : NibColor.destructive)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(paused ? String(localized: "Paused") : String(localized: "Recording"))
                    .font(NibFont.headline)
                    .foregroundStyle(NibColor.label)
                Spacer(minLength: NibSpacing.s)
                TimelineView(.animation(minimumInterval: 0.5, paused: paused)) { _ in
                    Text(AudioText.clock(audio.elapsed))
                        .font(NibFont.hud)
                        .foregroundStyle(NibColor.label)
                        .accessibilityLabel(String(localized: "Recorded time"))
                        .accessibilityValue(AudioText.spoken(audio.elapsed))
                }
            }
            TimelineView(.animation(minimumInterval: 0.1, paused: paused)) { _ in
                LiveWaveform(levels: audio.recorder?.meter.recent ?? [])
            }
            .frame(height: 28)
            HStack(spacing: NibSpacing.s) {
                NibButton(paused ? String(localized: "Resume") : String(localized: "Pause"),
                          symbol: paused ? NibSymbol.microphone : NibSymbol.pause, kind: .secondary, size: .compact, expands: true,
                          action: pause)
                NibButton(String(localized: "Stop"), symbol: .stop, kind: .primary, size: .compact, expands: true,
                          action: stop)
            }
        }
        .padding(NibSpacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paused ? String(localized: "Recording paused") : String(localized: "Recording"))
    }
}

/// Recent input levels as capsule bars, newest on the right. Real input, never an idle animation.
private struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let bar: CGFloat = 2
            let pitch: CGFloat = 4
            let count = max(0, Int(size.width / pitch))
            let shown = Array(levels.suffix(count))
            let start = size.width - CGFloat(shown.count) * pitch
            for (i, level) in shown.enumerated() {
                let h = max(bar, CGFloat(level) * size.height)
                let rect = CGRect(x: start + CGFloat(i) * pitch, y: (size.height - h) / 2, width: bar, height: h)
                context.fill(Capsule().path(in: rect), with: .color(NibColor.labelSecondary))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AudioClipRow: View {
    let clip: AudioClip
    let subtitle: String
    let isCurrent: Bool
    let isPlaying: Bool
    let isRecording: Bool
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NibSpacing.m) {
                Group {
                    if isRecording {
                        Circle()
                            .fill(NibColor.destructive)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(nib: isPlaying ? .pause : .play)
                            .font(NibFont.glyph(.panel))
                            .foregroundStyle(isCurrent ? NibColor.accent : NibColor.labelSecondary)
                    }
                }
                .frame(width: 24)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(isCurrent ? NibFont.bodyEmphasis : NibFont.body)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NibSpacing.s)
            .padding(.vertical, NibSpacing.xs)
            .frame(minHeight: NibMetrics.hitTarget, alignment: .leading)
            .background {
                if isCurrent { shape.fill(NibColor.fill3) }
            }
            .contentShape(shape)
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.name)
        .accessibilityValue(isPlaying ? subtitle + ", " + String(localized: "playing") : subtitle)
        .accessibilityHint(isRecording ? "" : (isPlaying ? String(localized: "Pauses the recording.")
                                                         : String(localized: "Plays the recording.")))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// Play/pause, ±10 s, the document timeline (one bead scrubber over every clip, a dot where each clip starts),
/// elapsed and total, speed, skip silence and noise reduction.
struct AudioPlaybackBar: View {
    @ObservedObject var audio: AudioController
    let doc: DocumentID
    let clips: [AudioClip]
    let perform: (String, JSONValue) -> Void
    @State private var scrub: Double?
    @State private var commit: Task<Void, Never>?

    private var loaded: AudioController.Playback? {
        guard let p = audio.playback, p.doc == doc, clips.contains(where: { $0.id == p.clip }) else { return nil }
        return p
    }

    private var timeline: AudioTimeline {
        var durations: [NibID: Double] = [:]
        if let p = loaded { durations[p.clip] = p.duration }
        return AudioTimeline(clips: clips, durations: durations)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: loaded?.isPlaying != true)) { _ in
            content(timeline)
        }
    }

    private func content(_ timeline: AudioTimeline) -> some View {
        let settings = audio.playbackSettings
        let playing = loaded?.isPlaying == true
        let current = scrub ?? now(timeline)
        return VStack(spacing: NibSpacing.xxs) {
            NibSlider(value: positionBinding(timeline), in: 0...max(timeline.total, 0.01),
                      label: String(localized: "Playback position"))
                .accessibilityValue(String(localized: "\(AudioText.spoken(current)) of \(AudioText.spoken(timeline.total))"))
            marks(timeline)
            HStack {
                Text(AudioText.clock(current))
                Spacer(minLength: NibSpacing.s)
                Text(AudioText.clock(timeline.total))
            }
            .font(NibFont.hud)
            .foregroundStyle(NibColor.labelSecondary)
            .padding(.horizontal, NibSpacing.xs)
            .accessibilityHidden(true)
            HStack(spacing: 0) {
                speedMenu(settings.speed)
                Spacer(minLength: 0)
                NibIconButton(AudioSymbols.back10, label: String(localized: "Back 10 Seconds"), size: .panel,
                              shortcut: KeyboardShortcut(.leftArrow, modifiers: [.command, .option])) {
                    skip(-10, timeline)
                }
                .disabled(loaded == nil)
                NibIconButton(playing ? .pause : .play, label: playing ? String(localized: "Pause") : String(localized: "Play"),
                              size: .bar, shortcut: KeyboardShortcut("p", modifiers: [.command, .option])) {
                    toggle()
                }
                NibIconButton(AudioSymbols.forward10, label: String(localized: "Forward 10 Seconds"), size: .panel,
                              shortcut: KeyboardShortcut(.rightArrow, modifiers: [.command, .option])) {
                    skip(10, timeline)
                }
                .disabled(loaded == nil)
                Spacer(minLength: 0)
                optionsMenu(settings)
            }
            if settings.skipSilence || settings.noiseReduction {
                Text(optionsSummary(settings))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, NibSpacing.s)
        .padding(.vertical, NibSpacing.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Playback"))
    }

    /// Dots under the track where the second and later clips begin, aligned with NibSlider's 14 pt thumb inset.
    private func marks(_ timeline: AudioTimeline) -> some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 28)
            ForEach(Array(timeline.marks.enumerated()), id: \.offset) { _, fraction in
                Circle()
                    .fill(NibColor.labelSecondary)
                    .frame(width: 5, height: 5)
                    .position(x: 14 + CGFloat(fraction) * width, y: proxy.size.height / 2)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func speedMenu(_ speed: Double) -> some View {
        Menu {
            Picker(String(localized: "Speed"), selection: Binding(get: { speed }, set: { value in
                perform("audio.setPlayback", ["speed": .number(value)])
            })) {
                ForEach(AudioSettings.speeds, id: \.self) { s in
                    Text(AudioText.speed(s)).tag(s)
                }
            }
        } label: {
            Text(AudioText.speed(speed))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
                .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Playback Speed"))
        .accessibilityValue(AudioText.speed(speed))
    }

    private func optionsMenu(_ settings: AudioController.PlaybackSettings) -> some View {
        Menu {
            Toggle(String(localized: "Skip Silence"), isOn: Binding(get: { settings.skipSilence }, set: { on in
                perform("audio.setPlayback", ["skipSilence": .bool(on)])
            }))
            Toggle(String(localized: "Reduce Noise"), isOn: Binding(get: { settings.noiseReduction }, set: { on in
                perform("audio.setPlayback", ["noiseReduction": .bool(on)])
            }))
        } label: {
            Image(nib: .moreCircle)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(NibColor.label)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Playback Options"))
    }

    private func optionsSummary(_ settings: AudioController.PlaybackSettings) -> String {
        var parts: [String] = []
        if settings.skipSilence { parts.append(String(localized: "Skipping silence")) }
        if settings.noiseReduction { parts.append(String(localized: "Reducing noise")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Position

    private func now(_ timeline: AudioTimeline) -> Double {
        guard let p = loaded else { return 0 }
        return timeline.position(of: p.clip, at: audio.position) ?? 0
    }

    /// Dragging moves the bead at once and seeks a quarter second after the finger rests.
    private func positionBinding(_ timeline: AudioTimeline) -> Binding<Double> {
        Binding(get: { scrub ?? now(timeline) }, set: { value in
            scrub = value
            commit?.cancel()
            commit = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                go(to: value, timeline)
                scrub = nil
            }
        })
    }

    private func go(to position: Double, _ timeline: AudioTimeline) {
        guard let target = timeline.locate(position) else { return }
        if let p = loaded, p.clip == target.clip {
            perform("audio.seek", ["t": .number(target.t)])
        } else {
            perform("audio.play", ["clip": .string(NodeRef.audio(doc, target.clip).description), "t": .number(target.t)])
        }
    }

    private func skip(_ seconds: Double, _ timeline: AudioTimeline) {
        go(to: now(timeline) + seconds, timeline)
    }

    private func toggle() {
        if let p = loaded {
            if p.isPlaying {
                perform("audio.pause", [:])
            } else {
                perform("audio.play", ["clip": .string(NodeRef.audio(doc, p.clip).description)])
            }
        } else if let first = clips.first {
            perform("audio.play", ["clip": .string(NodeRef.audio(doc, first.id).description), "t": 0])
        }
    }
}

/// Glyphs the playback bar needs that NibSymbol has no token for (validated; they fall back to the chevrons).
enum AudioSymbols {
    static let back10 = NibSymbol(systemName: "gobackward.10") ?? .back
    static let forward10 = NibSymbol(systemName: "goforward.10") ?? .forward
}

enum AudioText {
    /// "4:12" or "1:04:12".
    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        let pattern: Duration.TimeFormatStyle.Pattern = whole >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(whole).formatted(.time(pattern: pattern))
    }

    /// "4 minutes, 12 seconds" for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(Int(max(0, seconds).rounded(.down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// "1.5×".
    static func speed(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "\u{00D7}"
    }
}

private struct PendingAction {
    var title: String
    var button: String
    var command: String
    var params: JSONValue
    var message: String
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet for an exported clip.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
