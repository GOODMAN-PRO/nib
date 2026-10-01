import SwiftUI
import NibContracts
import NibDesign

public enum FeatTranscriptionFeature: NibFeature {
    public static let id = "transcription"
    static let panelID = "transcription"

    public static func register(_ app: NibApp) {
        app.services.set(TranscriptStore(), for: TranscriptStore.serviceKey)
        app.services.set(LiveTranscriber(app: app, speech: AppleTranscriptSpeech()), for: LiveTranscriber.serviceKey)
        app.services.set(SystemTranscriptClipboard(), for: "transcription.clipboard")
        app.commands.register(TranscriptGet.self)
        app.commands.register(TranscriptList.self)
        app.commands.register(TranscriptRegenerate.self)
        app.commands.register(TranscriptEditSegment.self)
        app.commands.register(TranscriptInsert.self)
        app.commands.register(TranscriptAppend.self)
        app.commands.register(TranscriptSeek.self)
        app.commands.register(TranscriptCopy.self)
        app.commands.register(TranscriptLanguages.self)
        app.commands.register(TranscriptAuthorise.self)
        app.settings.declare(TranscriptSettings.live, summary: "Transcribe audio while recording.", owner: id, schema: .bool())
        app.settings.declare(TranscriptSettings.cloud, summary: "Send audio to the configured AI provider for transcription.", owner: id, schema: .bool())
        app.settings.declare(TranscriptSettings.language, summary: "Apple Speech locale for transcription.", owner: id, schema: .str())

        var panel = PanelDescriptor(id: panelID, title: String(localized: "Transcript"), icon: NibSymbol.transcript.name,
            placement: .sidebarTab, order: 350, owner: id, docKinds: [.notebook, .whiteboard, .textDocument]) {
                AnyView(TranscriptPanel(context: $0))
            }
        panel.providesHeader = true
        app.ui.panels.register(panel)
        app.ui.settingsPages.register(SettingsPageDescriptor(id: "transcription.recording", title: String(localized: "Recording Settings"),
            icon: NibSymbol.transcript.name, section: .general, order: 350, owner: id) { app in
                AnyView(TranscriptRecordingSettings(app: app))
            })
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "transcription.drop", owner: id) { _ in TranscriptDropAttachment() })
        app.ui.menus.register(MenuItemDescriptor(id: "transcription.open", title: String(localized: "Transcript"),
            icon: NibSymbol.transcript.name, location: .documentMore, order: 420, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": .string(panelID)] }))
        app.ui.menus.register(MenuItemDescriptor(id: "transcription.clip.open", title: String(localized: "Transcript"),
            icon: NibSymbol.transcript.name, location: .audioClip, order: 320, owner: id, command: CommandIDs.panelOpen,
            params: { ["id": .string(panelID), "clip": .string($0.ref ?? "")] }, isVisible: { $0.ref != nil }))
        app.ui.menus.register(MenuItemDescriptor(id: "transcription.line.copy", title: String(localized: "Copy"),
            icon: NibSymbol.copy.name, location: .transcriptSegment, order: 100, owner: id, command: TranscriptCopy.descriptor.id,
            params: lineParams, isVisible: hasLine))
        app.ui.menus.register(MenuItemDescriptor(id: "transcription.line.insert", title: String(localized: "Insert on Page"),
            icon: NibSymbol.text.name, location: .transcriptSegment, order: 200, owner: id, command: CommandIDs.transcriptInsert,
            params: { ctx in
                ["clip": .string(ctx.ref ?? ""), "segments": .array([.number(Double(ctx.index ?? 0))]),
                 "page": .string(ctx.doc.flatMap { d in ctx.page.map { NodeRef.page(d, $0).description } } ?? "")]
            }, isVisible: { hasLine($0) && $0.page != nil && $0.doc != nil }))
        app.ui.menus.register(MenuItemDescriptor(id: "transcription.line.edit", title: String(localized: "Edit"),
            icon: NibSymbol.pageTyping.name, location: .transcriptSegment, order: 300, owner: id, command: CommandIDs.panelOpen,
            params: { lineParams($0).merging(["id": .string(panelID)]) }, isVisible: hasLine))
        var key = KeyCommandDescriptor(id: "transcription.open", title: String(localized: "Show Transcript"),
            shortcut: KeyShortcut("t", [.command, .option]), command: CommandIDs.panelOpen,
            params: ["id": .string(panelID)], scope: .document, owner: id)
        key.docKinds = [.notebook, .whiteboard, .textDocument]
        app.content.keyCommands.register(key)
    }

    public static func start(_ app: NibApp) async {
        app.services.get(LiveTranscriber.serviceKey, as: LiveTranscriber.self)?.start()
    }

    private static func hasLine(_ ctx: MenuContext) -> Bool { ctx.ref != nil && ctx.index != nil }
    private static func lineParams(_ ctx: MenuContext) -> JSONValue {
        ["clip": .string(ctx.ref ?? ""), "index": .number(Double(ctx.index ?? 0))]
    }
}

enum TranscriptSettings {
    static let live = SettingKey<Bool>("transcription.live", default: false, synced: true)
    static let cloud = SettingKey<Bool>("transcription.cloud", default: false, synced: true)
    static let language = SettingKey<String>("transcription.language", default: Locale.current.identifier, synced: true)
}
