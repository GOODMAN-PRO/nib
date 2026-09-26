import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

/// The Audio sidebar tab (S-045, S-047, S-048, S-116; DESIGN.md §14.13 "Recordings list"): a compact row for the
/// app-wide recording (Stop, and Show when it records elsewhere), Record Audio, and the document's clips (date,
/// duration, page; tap to play; Rename, Share, Delete and other features' actions from `MenuLocation.audioClip`). The
/// recording HUD and the playback bar are chrome overlays (RecorderHUD, AudioPlaybackBar), so they stay on screen
/// with the tab closed. It sits inside the sidebar's Deep panel, so it draws no droplets of its own. Every action
/// runs an `audio.*` command.
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
        .sheet(item: $share, onDismiss: removeShareCopies) { item in
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
        if audio.microphoneDenied {
            NibBanner(String(localized: "Microphone access is off for Nib. Turn it on in Settings to record."),
                      symbol: .microphone,
                      action: NibAction(String(localized: "Open Settings"), handler: openSettings))
                .padding(.horizontal, NibSpacing.s)
                .padding(.top, NibSpacing.s)
        }
        if let message = failure ?? audio.lastError {
            NibBanner(message, action: NibAction(String(localized: "Dismiss"), handler: {
                failure = nil
                audio.lastError = nil
            }))
            .padding(.horizontal, NibSpacing.s)
            .padding(.top, NibSpacing.s)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: Recording

    @ViewBuilder
    private var recorder: some View {
        if let r = audio.recording {
            RecordingRow(audio: audio, recording: r, elsewhere: r.doc == model.doc ? nil : title(of: r.doc),
                         show: { execute(CommandIDs.docOpen, ["doc": .string(NodeRef.document(r.doc).description)]) },
                         stop: {
                             execute("audio.record", ["doc": .string(NodeRef.document(r.doc).description), "action": "stop"])
                         })
        } else if model.doc != nil && !model.clips.isEmpty {
            NibButton(String(localized: "Record Audio"), symbol: .record, kind: .primary, expands: true) { startRecording() }
                .padding(.horizontal, NibSpacing.m)
                .padding(.vertical, NibSpacing.s)
        }
    }

    private func title(of doc: DocumentID) -> String {
        app.services.library?.node(doc)?.title ?? String(localized: "another document")
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
        let saving = doc.map { audio.isFinalising($0, clip.id) } ?? false
        let current = audio.playback.map { $0.clip == clip.id && $0.doc == doc } ?? false
        let playing = current && audio.playback?.isPlaying == true
        let items = menuItems(clip)
        return AudioClipRow(clip: clip, subtitle: subtitle(clip, recording: recordingThis, saving: saving),
                            isCurrent: current, isPlaying: playing, isRecording: recordingThis) {
            guard let doc, !recordingThis, !saving else { return }
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
                        Text(item.resolvedTitle(for: menuContext(clip)))
                    } icon: {
                        if let symbol = item.icon.flatMap(NibSymbol.init(systemName:)) { Image(nib: symbol) }
                    }
                }
            }
        }
        .accessibilityActions {
            Button(String(localized: "Rename")) { startRename(clip) }
            ForEach(items, id: \.id) { item in
                Button(item.resolvedTitle(for: menuContext(clip))) { run(item, clip) }
            }
        }
    }

    private func subtitle(_ clip: AudioClip, recording: Bool, saving: Bool) -> String {
        let when = Date(timeIntervalSince1970: clip.start).formatted(date: .abbreviated, time: .shortened)
        var parts = [when]
        if recording {
            parts.append(String(localized: "Recording"))
        } else if saving {
            parts.append(String(localized: "Saving…"))
        } else {
            parts.append(AudioText.clock(clip.duration))
        }
        if let page = clip.page, let number = model.pages[page] { parts.append(String(localized: "Page \(number)")) }
        return parts.joined(separator: " · ")
    }

    private func menuContext(_ clip: AudioClip) -> MenuContext {
        MenuContext(app: app, session: model.session, doc: model.doc, page: clip.page,
                    ref: model.doc.map { NodeRef.audio($0, clip.id).description })
    }

    private func menuItems(_ clip: AudioClip) -> [MenuItemDescriptor] {
        guard model.doc != nil else { return [] }
        return app.ui.menuItems(.audioClip, menuContext(clip))
    }

    // MARK: Actions

    private func startRecording() {
        guard let doc = model.doc else { return }
        execute("audio.record", ["doc": .string(NodeRef.document(doc).description), "action": "start"])
    }

    private func run(_ item: MenuItemDescriptor, _ clip: AudioClip) {
        let params = item.params(menuContext(clip))
        guard item.destructive else {
            execute(item.command, params)
            return
        }
        let deleting = item.command == "audio.delete"
        let title = item.resolvedTitle(for: menuContext(clip))
        confirming = PendingAction(
            title: deleting ? String(localized: "Delete \u{201C}\(clip.name)\u{201D}?") : title,
            button: title, command: item.command, params: params,
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
        model.sharedCopies.append(copy)
    }

    /// The share sheet is gone: its named copies are no longer needed.
    private func removeShareCopies() {
        let copies = model.sharedCopies
        model.sharedCopies = []
        Task.detached(priority: .utility) {
            for url in copies { AudioFiles.removeShareCopy(url) }
        }
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
    /// Share-sheet copies to remove once the sheet is dismissed.
    var sharedCopies: [URL] = []
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

    /// A clip at zero length with nothing recording was cut short by a crash: `audio.record stop` finishes it.
    private func repairIfNeeded() {
        guard let doc, let audio = AudioController.of(app.services), audio.recording == nil,
              clips.contains(where: { $0.duration <= 0 && !audio.isFinalising(doc, $0.id) }) else { return }
        app.perform("audio.record", ["doc": .string(NodeRef.document(doc).description), "action": "stop"],
                    session: session)
    }
}

/// The recording in the tab: the dot, "Recording" or "Paused" with the clock, Show (when it records in another
/// document) and Stop. The HUD at top centre has Pause as well.
private struct RecordingRow: View {
    @ObservedObject var audio: AudioController
    let recording: AudioController.Recording
    /// The other document's title, nil when it records in this one.
    let elsewhere: String?
    let show: () -> Void
    let stop: () -> Void

    var body: some View {
        let paused = recording.pausedAt != nil
        HStack(spacing: NibSpacing.s) {
            if paused {
                Image(nib: .pause)
                    .font(NibFont.caption1Emphasis)
                    .foregroundStyle(NibColor.labelSecondary)
                    .accessibilityHidden(true)
            } else {
                NibStatusDot(.recording)
            }
            VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                TimelineView(.animation(minimumInterval: 0.5, paused: paused)) { _ in
                    Text(paused ? String(localized: "Paused · \(AudioText.clock(audio.elapsed))")
                                : String(localized: "Recording · \(AudioText.clock(audio.elapsed))"))
                        .font(NibFont.headline)
                        .monospacedDigit()
                        .foregroundStyle(NibColor.label)
                }
                if let elsewhere {
                    Text(String(localized: "In \u{201C}\(elsewhere)\u{201D}"))
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if elsewhere != nil {
                NibButton(String(localized: "Show"), kind: .plain, size: .compact, action: show)
            }
            NibIconButton(.stop, label: String(localized: "Stop Recording"), size: .panel, action: stop)
        }
        .padding(.leading, NibSpacing.m)
        .padding(.vertical, NibSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paused ? String(localized: "Recording paused") : String(localized: "Recording"))
        .accessibilityValue(AudioText.spoken(audio.elapsed))
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
                        NibStatusDot(.recording)
                    } else {
                        Image(nib: isPlaying ? .pause : .play)
                            .font(NibFont.glyph(.panel))
                            .foregroundStyle(isCurrent ? NibColor.accent : NibColor.labelSecondary)
                    }
                }
                .frame(width: NibSpacing.xxl)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NibSpacing.xxs) {
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

// MARK: - Chrome overlays

/// Mirrors a window's Pencil-down state (`EditorSession.inking`) into SwiftUI for one overlay: the HUD and the bar stop
/// redrawing their clock, waveform and scrubber while the Pencil is down, so nothing near live ink re-renders (the
/// chrome host recedes them to 22 %). Only the down and up transitions publish, never the stroke's growth.
@MainActor
final class InkingWatcher: ObservableObject {
    @Published private(set) var isInking = false
    private var subscription: EventSubscription?
    private weak var signal: InkingSignal?

    func watch(_ signal: InkingSignal) {
        guard self.signal !== signal || subscription == nil else { return }
        subscription?.cancel()
        self.signal = signal
        isInking = signal.isInking
        subscription = signal.observe { [weak self] s in
            guard let self, self.isInking != s.isInking else { return }
            self.isInking = s.isInking
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        signal = nil
    }
}

/// Runs an `audio.*` command as the user from a chrome overlay; a failure is a toast in that window (or the Audio
/// tab's notice where the window has no floating host).
@MainActor
enum AudioChromeActions {
    static func perform(_ app: NibApp, _ command: String, _ params: JSONValue, session: EditorSession,
                        host: FloatingHosting?, audio: AudioController) {
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(command, params, session: session)
            } catch {
                let message = NibError.wrap(error).message
                if let host {
                    host.postToast(message)
                } else {
                    audio.lastError = message
                }
            }
        }
    }
}

/// The recording HUD (DESIGN.md §14.13): a `destructive` dot, the timer in hud type, the live waveform in
/// `labelSecondary` bars, Pause and Stop. A `.top` `.hud` chrome overlay: the host buds it from the trailing bar to top
/// centre inside the window's droplet container, gives it the Clear 40 pt HUD droplet (NibHUDGroup's surface), and
/// recedes it while the Pencil is down. It shows in every document window, since the recording is app-wide.
struct RecorderHUD: View {
    @ObservedObject var audio: AudioController
    let app: NibApp
    let session: EditorSession
    let host: FloatingHosting?
    @StateObject private var inking = InkingWatcher()

    var body: some View {
        Group {
            if let r = audio.recording {
                content(r)
            }
        }
        .onAppear { inking.watch(session.inking) }
        .onDisappear { inking.stop() }
    }

    private func content(_ r: AudioController.Recording) -> some View {
        let paused = r.pausedAt != nil
        let frozen = paused || inking.isInking
        return HStack(spacing: NibSpacing.xxs) {
            if !paused {
                NibStatusDot(.recording)
                    .padding(.leading, NibSpacing.s)
            }
            TimelineView(.animation(minimumInterval: 0.5, paused: frozen)) { _ in
                NibHUDText(AudioText.clock(audio.elapsed), secondary: paused ? String(localized: "Paused") : nil)
                    .accessibilityLabel(paused ? String(localized: "Recording paused") : String(localized: "Recording"))
                    .accessibilityValue(AudioText.spoken(audio.elapsed))
            }
            TimelineView(.animation(minimumInterval: 0.1, paused: frozen)) { _ in
                NibWaveform(levels: audio.recorder?.meter.recentLevels ?? [])
            }
            NibIconButton(paused ? .recordDot : .pause,
                          label: paused ? String(localized: "Resume Recording") : String(localized: "Pause Recording"),
                          size: .bar) {
                run(r, paused ? "resume" : "pause")
            }
            NibIconButton(.stop, label: String(localized: "Stop Recording"), size: .bar) {
                run(r, "stop")
            }
        }
        .frame(minHeight: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .accessibilityElement(children: .contain)
    }

    private func run(_ r: AudioController.Recording, _ action: String) {
        AudioChromeActions.perform(app, "audio.record",
                                   ["doc": .string(NodeRef.document(r.doc).description), "action": .string(action)],
                                   session: session, host: host, audio: audio)
    }
}

/// The playback bar (DESIGN.md §14.13): play/pause, a bead scrubber over the document's clips laid end to end (a dot
/// where each later clip starts), elapsed/total in hud type, and the speed, which opens the options (speed, ±10 s,
/// skip silence, noise reduction, Close Player). A `.bottom` `.bar` chrome overlay (320 × 44, above the palette on
/// iPhone): the host gives it the Clear bar droplet and recedes it while the Pencil is down.
struct AudioPlaybackBar: View {
    @ObservedObject var audio: AudioController
    let app: NibApp
    let session: EditorSession
    let host: FloatingHosting?
    @StateObject private var inking = InkingWatcher()
    @State private var scrub: Double?
    @State private var commit: Task<Void, Never>?

    /// The document the bar plays: the loaded clip's, else the window's.
    private var doc: DocumentID? { audio.playback?.doc ?? session.document }

    var body: some View {
        let clips = doc.map { audio.playableClips($0) } ?? []
        let loaded = loadedPlayback(clips)
        TimelineView(.animation(minimumInterval: 0.25, paused: loaded?.isPlaying != true || inking.isInking)) { _ in
            content(clips: clips, loaded: loaded)
        }
        .onAppear { inking.watch(session.inking) }
        .onDisappear { inking.stop() }
    }

    private func loadedPlayback(_ clips: [AudioClip]) -> AudioController.Playback? {
        guard let p = audio.playback, clips.contains(where: { $0.id == p.clip }) else { return nil }
        return p
    }

    private func makeTimeline(_ clips: [AudioClip], loaded: AudioController.Playback?) -> AudioTimeline {
        var durations: [NibID: Double] = [:]
        if let p = loaded { durations[p.clip] = p.duration }
        return AudioTimeline(clips: clips, durations: durations)
    }

    private func content(clips: [AudioClip], loaded: AudioController.Playback?) -> some View {
        let timeline = makeTimeline(clips, loaded: loaded)
        let settings = audio.playbackSettings
        let playing = loaded?.isPlaying == true
        let current = scrub ?? now(timeline, loaded: loaded)
        return HStack(spacing: NibSpacing.xxs) {
            NibIconButton(playing ? .pause : .play, label: playing ? String(localized: "Pause") : String(localized: "Play"),
                          size: .bar) {
                toggle(clips, loaded: loaded)
            }
            NibSlider(value: positionBinding(timeline, loaded: loaded), in: 0...max(timeline.total, 0.01),
                      label: String(localized: "Playback position"), detents: timeline.markPositions)
                .overlay { ClipStartMarks(fractions: timeline.marks) }
                .accessibilityValue(String(localized: "\(AudioText.spoken(current)) of \(AudioText.spoken(timeline.total))"))
            NibHUDText(AudioText.clock(current), secondary: "/ " + AudioText.clock(timeline.total))
                .accessibilityHidden(true)
            optionsMenu(settings, timeline: timeline, loaded: loaded)
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(maxWidth: NibMetrics.audioBarWidth, minHeight: NibMetrics.hitTarget)
        .nibChromeTypeCap()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Playback"))
    }

    /// The speed on the bar (1×, 1.5×, 2×…) opens the options: speed, ±10 s, skip silence, noise reduction, Close.
    private func optionsMenu(_ settings: AudioController.PlaybackSettings, timeline: AudioTimeline,
                             loaded: AudioController.Playback?) -> some View {
        Menu {
            Picker(String(localized: "Speed"), selection: Binding(get: { settings.speed }, set: { value in
                perform("audio.setPlayback", ["speed": .number(value)])
            })) {
                ForEach(AudioSettings.speeds, id: \.self) { s in
                    Text(AudioText.speed(s)).tag(s)
                }
            }
            Section {
                Button {
                    skip(-10, timeline, loaded: loaded)
                } label: {
                    Label { Text(String(localized: "Back 10 Seconds")) } icon: { Image(nib: .skipBack10) }
                }
                .disabled(loaded == nil)
                Button {
                    skip(10, timeline, loaded: loaded)
                } label: {
                    Label { Text(String(localized: "Forward 10 Seconds")) } icon: { Image(nib: .skipForward10) }
                }
                .disabled(loaded == nil)
            }
            Section {
                Toggle(String(localized: "Skip Silence"), isOn: Binding(get: { settings.skipSilence }, set: { on in
                    perform("audio.setPlayback", ["skipSilence": .bool(on)])
                }))
                Toggle(String(localized: "Reduce Noise"), isOn: Binding(get: { settings.noiseReduction }, set: { on in
                    perform("audio.setPlayback", ["noiseReduction": .bool(on)])
                }))
            }
            Section {
                Button {
                    perform("audio.pause", ["close": true])
                } label: {
                    Label { Text(String(localized: "Close Player")) } icon: { Image(nib: .xmark) }
                }
                .disabled(loaded == nil)
            }
        } label: {
            Text(AudioText.speed(settings.speed))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
                .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(String(localized: "Playback Options"))
        .accessibilityValue(optionsValue(settings))
    }

    private func optionsValue(_ settings: AudioController.PlaybackSettings) -> String {
        var parts = [AudioText.speed(settings.speed)]
        if settings.skipSilence { parts.append(String(localized: "Skipping silence")) }
        if settings.noiseReduction { parts.append(String(localized: "Reducing noise")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Position

    private func now(_ timeline: AudioTimeline, loaded: AudioController.Playback?) -> Double {
        guard let p = loaded else { return 0 }
        return timeline.position(of: p.clip, at: audio.position) ?? 0
    }

    /// Dragging moves the bead at once and seeks a quarter second after the finger rests.
    private func positionBinding(_ timeline: AudioTimeline, loaded: AudioController.Playback?) -> Binding<Double> {
        Binding(get: { scrub ?? now(timeline, loaded: loaded) }, set: { value in
            scrub = value
            commit?.cancel()
            commit = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                go(to: value, timeline, loaded: loaded)
                scrub = nil
            }
        })
    }

    private func go(to position: Double, _ timeline: AudioTimeline, loaded: AudioController.Playback?) {
        guard let doc, let target = timeline.locate(position) else { return }
        if let p = loaded, p.clip == target.clip {
            perform("audio.seek", ["t": .number(target.t)])
        } else {
            perform("audio.play", ["clip": .string(NodeRef.audio(doc, target.clip).description), "t": .number(target.t)])
        }
    }

    private func skip(_ seconds: Double, _ timeline: AudioTimeline, loaded: AudioController.Playback?) {
        go(to: now(timeline, loaded: loaded) + seconds, timeline, loaded: loaded)
    }

    private func toggle(_ clips: [AudioClip], loaded: AudioController.Playback?) {
        guard let doc else { return }
        if let p = loaded {
            if p.isPlaying {
                perform("audio.pause", [:])
            } else {
                perform("audio.play", ["clip": .string(NodeRef.audio(doc, p.clip).description)])
            }
        } else if let first = clips.first(where: { $0.duration > 0 }) {
            perform("audio.play", ["clip": .string(NodeRef.audio(doc, first.id).description), "t": 0])
        }
    }

    private func perform(_ command: String, _ params: JSONValue) {
        AudioChromeActions.perform(app, command, params, session: session, host: host, audio: audio)
    }
}

/// Dots on the scrubber where the second and later clips begin (display only). NibSlider has no marks API (contract
/// gap), so they are laid over it along its track.
private struct ClipStartMarks: View {
    /// NibSlider's track runs between the centres of its 28 pt bead (NibDesign Components/Controls.swift,
    /// `NibSlider`): keep this in step with it.
    static let trackInset: CGFloat = 14
    let fractions: [Double]

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 2 * Self.trackInset)
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                Circle()
                    .fill(NibColor.label)
                    .frame(width: NibMetrics.statusDot, height: NibMetrics.statusDot)
                    .position(x: Self.trackInset + CGFloat(fraction) * width, y: proxy.size.height / 2 + NibSpacing.s)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
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
