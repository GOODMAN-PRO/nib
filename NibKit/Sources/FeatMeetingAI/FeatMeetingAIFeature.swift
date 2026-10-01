import SwiftUI
import NibContracts
import NibDesign

public enum FeatMeetingAIFeature: NibFeature {
    public static let id = "meetingai"
    static let panelID = "meetingai.summary"
    static let settingsID = "meetingai.recording"

    public static func register(_ app: NibApp) {
        app.commands.register(MeetingSummarize.self)
        app.commands.register(MeetingGenerateNotes.self)
        app.services.set(LiveSummarizer(app: app), for: LiveSummarizer.serviceKey)
        app.settings.declare(MeetingSettings.live, summary: "Summarize new transcript speech about once per minute while recording.", owner: id, schema: .bool())
        app.settings.declare(MeetingSettings.language, summary: "Language for translated meeting summaries and generated notes.", owner: id, schema: .str())
        app.ui.panels.register(PanelDescriptor(id: panelID, title: String(localized: "Summary"), icon: NibSymbol.listBulleted.name,
            placement: .sidebarTab, order: 360, owner: id, docKinds: [.notebook, .whiteboard, .textDocument]) { AnyView(SummaryPanel(context: $0)) })
        var settings = SettingsPageDescriptor(id: settingsID, title: String(localized: "Meeting AI"),
            icon: NibSymbol.microphone.name, section: .ai, order: 360, owner: id) { AnyView(MeetingRecordingSettings(app: $0)) }
        settings.keywords = ["recording", "meeting", "summary", "cloud", "transcription", "language"]
        app.ui.settingsPages.register(settings)
        app.ui.menus.register(MenuItemDescriptor(id: "meetingai.summary", title: String(localized: "Summary"),
            icon: NibSymbol.listBulleted.name, location: .documentMore, order: 425, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(panelID)] }))
        app.ui.menus.register(MenuItemDescriptor(id: "meetingai.clip.summary", title: String(localized: "Summary"),
            icon: NibSymbol.listBulleted.name, location: .audioClip, order: 330, owner: id, command: CommandIDs.panelOpen,
            params: { ["id": .string(panelID), "clip": .string($0.ref ?? "")] }, isVisible: { $0.ref != nil }))
        for (mode, title, order) in [("generate", String(localized: "Generate Notes"), 340), ("enhance", String(localized: "Enhance Notes"), 350)] {
            app.ui.menus.register(MenuItemDescriptor(id: "meetingai.clip." + mode, title: title, icon: NibSymbol.text.name,
                location: .audioClip, order: order, owner: id, command: CommandIDs.meetingGenerateNotes,
                params: { ["clip": .string($0.ref ?? ""), "mode": .string(mode)] },
                isVisible: { context in
                    guard let ref = context.ref, let runtime = context.app.services.get(LiveSummarizer.serviceKey, as: LiveSummarizer.self) else { return false }
                    return runtime.recordings[ref]?.state != "recording" && runtime.recordings[ref]?.state != "paused" && runtime.transcribing[ref] == false
                }))
        }
        var key = KeyCommandDescriptor(id: panelID, title: String(localized: "Show Summary"),
            shortcut: KeyShortcut("s", [.command, .option]), command: CommandIDs.panelOpen,
            params: ["id": .string(panelID)], scope: .document, owner: id)
        key.docKinds = [.notebook, .whiteboard, .textDocument]
        app.content.keyCommands.register(key)
    }
    public static func start(_ app: NibApp) async {
        app.services.get(LiveSummarizer.serviceKey, as: LiveSummarizer.self)?.start()
    }
}

enum MeetingSettings {
    static let live = SettingKey<Bool>("meetingai.liveSummary", default: false, synced: true)
    static let language = SettingKey<String>("meetingai.summaryLanguage", default: Locale.current.language.languageCode?.identifier ?? "en", synced: true)
    // Declared and owned by F054. Writes go through settings.set, preserving its security scope.
    static let transcription = SettingKey<Bool>("transcription.live", default: false, synced: true)
    static let cloud = SettingKey<Bool>("security.transcription.cloud", default: false, synced: true)
}
