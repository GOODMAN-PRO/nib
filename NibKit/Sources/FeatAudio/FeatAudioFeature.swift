import SwiftUI
import UIKit
import AVFoundation
import Combine
import os
import NibContracts
import NibDesign

/// Audio recording and playback (F052): one app-wide recording into a document's `audio/<clip>.caf` (AAC in CAF,
/// written continuously), the Audio sidebar tab with the clip list and the playback bar (speed, ±10 s, skip silence,
/// noise reduction), Quick Record, and the recording indicator on the toolbar accessory and the sidebar tab.
/// Every action is an `audio.*` command (AudioCommands.swift).
public enum FeatAudioFeature: NibFeature {
    public static let id = "audio"

    public static func register(_ app: NibApp) {
        let audio = AudioController(app: app)
        app.services.set(audio, for: AudioController.serviceKey)

        app.commands.register(AudioRecord.self)
        app.commands.register(AudioPlay.self)
        app.commands.register(AudioPause.self)
        app.commands.register(AudioSeek.self)
        app.commands.register(AudioSetPlayback.self)
        app.commands.register(AudioRename.self)
        app.commands.register(AudioDelete.self)
        app.commands.register(AudioExport.self)
        app.commands.register(AudioQuickRecord.self)

        app.settings.declare(AudioSettings.speed, summary: "Audio playback speed, 0.5–2×.", owner: id,
                             schema: .num(min: AudioSettings.minimumSpeed, max: AudioSettings.maximumSpeed))
        app.settings.declare(AudioSettings.skipSilence, summary: "Skip silent stretches while audio plays.", owner: id,
                             schema: .bool())
        app.settings.declare(AudioSettings.noiseReduction,
                             summary: "Reduce background noise while audio plays (high-pass filter and noise gate).",
                             owner: id, schema: .bool())

        AudioIndicators.register(app, audio: audio, recording: false)
        registerMenus(app)
        app.content.keyCommands.register(KeyCommandDescriptor(
            id: "audio.record", title: String(localized: "Start or Stop Recording"),
            shortcut: KeyShortcut("r", [.command, .shift]), command: "audio.record",
            params: ["action": "toggle"], scope: .document, owner: id))

        audio.recordingChanged = { [weak app, weak audio] recording in
            guard let app, let audio else { return }
            AudioIndicators.register(app, audio: audio, recording: recording)
        }
    }

    public static func start(_ app: NibApp) async {
        AudioController.of(app.services)?.observeSystem()
    }

    private static func registerMenus(_ app: NibApp) {
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.more.record", title: String(localized: "Record Audio"), icon: NibSymbol.record.name,
            location: .documentMore, order: 400, owner: id, command: "audio.record",
            params: { ctx in
                ["doc": .string(ctx.doc.map { NodeRef.document($0).description } ?? ""), "action": "start"]
            },
            isVisible: { ctx in AudioIndicators.canRecord(ctx) && AudioController.of(ctx.app.services)?.recording == nil }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.more.stop", title: String(localized: "Stop Recording"), icon: NibSymbol.stop.name,
            location: .documentMore, order: 400, owner: id, command: "audio.record",
            params: { _ in ["action": "stop"] },
            isVisible: { ctx in AudioController.of(ctx.app.services)?.recording != nil }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.new.quickRecord", title: String(localized: "Quick Record"), icon: NibSymbol.microphone.name,
            location: .libraryNew, order: 450, owner: id, command: "audio.quickRecord"))

        // Clip rows (the Audio tab builds each row's menu from MenuLocation.audioClip, so other features and
        // plugins add theirs). Rename needs a name, so the row asks for it itself.
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.clip.play", title: String(localized: "Play"), icon: NibSymbol.play.name,
            location: .audioClip, order: 100, owner: id, command: "audio.play",
            params: { ctx in ["clip": .string(ctx.ref ?? "")] },
            isVisible: { ctx in ctx.ref != nil }, quick: true))
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.clip.goToPage", title: String(localized: "Go to Page"), icon: NibSymbol.pages.name,
            location: .audioClip, order: 200, owner: id, command: CommandIDs.viewGoToPage,
            params: { ctx in
                guard let found = AudioRefs.menuClip(ctx), let page = found.clip.page else { return [:] }
                return ["page": .string(NodeRef.page(found.doc, page).description)]
            },
            isVisible: { ctx in
                ctx.app.commands.entry(CommandIDs.viewGoToPage) != nil && AudioRefs.menuClip(ctx)?.clip.page != nil
            }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.clip.export", title: String(localized: "Share Audio File"), icon: NibSymbol.share.name,
            location: .audioClip, order: 300, owner: id, command: "audio.export",
            params: { ctx in ["clip": .string(ctx.ref ?? ""), "format": "m4a"] },
            isVisible: { ctx in ctx.ref != nil }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "audio.clip.delete", title: String(localized: "Delete Recording"), icon: NibSymbol.trash.name,
            location: .audioClip, order: 900, owner: id, command: "audio.delete",
            params: { ctx in ["clip": .string(ctx.ref ?? "")] },
            isVisible: { ctx in ctx.ref != nil }, destructive: true))
    }
}

/// The recording indicator (S-048, P-084): while anything records, the toolbar accessory turns into Stop and the
/// Audio sidebar tab carries the record dot in every window. Re-registering an id replaces it, and the toolbar and
/// sidebar hosts redraw on `.nibRegistryDidChange`.
@MainActor
enum AudioIndicators {
    static let panelID = "audio"
    static let toolbarID = "audio.record"
    /// Study sets have no audio (Goodnotes has none on flashcards either).
    static let docKinds: Set<DocumentKind> = [.notebook, .whiteboard, .textDocument]

    static func register(_ app: NibApp, audio: AudioController, recording: Bool) {
        let owner = FeatAudioFeature.id
        app.ui.toolbar.register(ToolbarItemDescriptor(
            id: toolbarID,
            title: recording ? String(localized: "Stop Recording") : String(localized: "Record Audio"),
            icon: recording ? NibSymbol.stop.name : NibSymbol.record.name,
            group: .accessories, order: 300, owner: owner, command: "audio.record", params: ["action": "toggle"],
            docKinds: docKinds))
        app.ui.panels.register(PanelDescriptor(
            id: panelID,
            title: recording ? String(localized: "Recording") : String(localized: "Audio"),
            icon: recording ? recordDot : NibSymbol.record.name,
            placement: .sidebarTab, order: 300, owner: owner, docKinds: docKinds) { context in
                AnyView(AudioPanelView(context: context, audio: audio))
            })
    }

    /// A document menu is for a kind that can hold recordings.
    static func canRecord(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc, let kind = (try? ctx.app.workspace.content(doc))?.meta.kind else { return false }
        return docKinds.contains(kind)
    }

    /// The tab's dot while recording. NibSymbol has no record-dot token (contract gap), so the name is validated
    /// like a descriptor's icon string, falling back to the microphone.
    static let recordDot = (NibSymbol(systemName: "record.circle") ?? .microphone).name
}

/// Playback preferences (device-local; written only by `audio.setPlayback`).
enum AudioSettings {
    static let speed = SettingKey("audio.speed", default: 1.0)
    static let skipSilence = SettingKey("audio.skipSilence", default: false)
    static let noiseReduction = SettingKey("audio.noiseReduction", default: false)
    static let minimumSpeed = 0.5
    static let maximumSpeed = 2.0
    /// The speed menu (D-124 textbook audio, S-088).
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
}

/// App-wide audio state: the one recording and the one playback, shared by the commands and every window's Audio
/// tab (a service, `serviceKey`). Recording lives in Recorder.swift, playback in Player.swift.
@MainActor
final class AudioController: ObservableObject {
    static let serviceKey = "audio.controller"
    static let log = Logger(subsystem: "app.nib", category: FeatAudioFeature.id)

    static func of(_ services: NibServices) -> AudioController? {
        services.get(serviceKey, as: AudioController.self)
    }

    static func require(_ services: NibServices) throws -> AudioController {
        try services.require(of(services), "audio")
    }

    struct Recording: Equatable {
        var doc: DocumentID
        var clip: NibID
        var page: PageID?
        /// Unix seconds of the first sample.
        var startedAt: Double
        /// Unix seconds when paused (nil while capturing).
        var pausedAt: Double?
    }

    struct Playback: Equatable {
        var doc: DocumentID
        var clip: NibID
        var url: URL
        /// Seconds of audio in the file.
        var duration: Double
        var isPlaying: Bool
        /// Clip time while paused, or where the current plan started.
        var position: Double
    }

    private(set) weak var app: NibApp?

    // Injection points: tests feed synthetic PCM (no microphone in hostless tests), a fake output and a fixed clock.
    var makeSource: (() throws -> AudioSampleSource)?
    var makeEngine: (() -> PlaybackEngine)?
    var clock: () -> Double = { Date().timeIntervalSince1970 }

    // Recording (Recorder.swift).
    @Published var recording: Recording?
    @Published var microphoneDenied = false
    /// The last failure the Audio tab shows inline (a full disk, a busy microphone).
    @Published var lastError: String?
    var recorder: Recorder?
    var starting = false
    var resumeAfterInterruption = false
    var recordingChanged: (@MainActor (Bool) -> Void)?

    // Playback (Player.swift).
    @Published var playback: Playback?
    var engine: PlaybackEngine?
    var plan: PlaybackPlan?
    var playGeneration = 0
    var silenceMaps: [String: SilenceMap] = [:]
    var analysing: Set<String> = []

    var cancellables = Set<AnyCancellable>()
    var observing = false

    init(app: NibApp) {
        self.app = app
    }

    /// Interruptions (calls), route changes (headphones out) and termination; never in hostless tests.
    func observeSystem() {
        guard !observing, !NibApp.isHostlessTest else { return }
        observing = true
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.interrupted(note) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.routeChanged(note) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.recorder?.closeFile() }
            .store(in: &cancellables)
    }

    func emit(_ type: String, doc: DocumentID, _ payload: [String: JSONValue]) {
        app?.events.emit(type, principal: .user, doc: doc, payload: .object(payload))
    }
}
