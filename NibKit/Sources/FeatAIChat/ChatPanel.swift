import Foundation
import SwiftUI
import UniformTypeIdentifiers
import NibContracts
import NibDesign

struct ChatPanel: View {
    @ObservedObject var model: ChatViewModel
    let context: PanelContext
    @State private var deletingChat: String?
    @State private var visibilityLease = UUID().uuidString
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: String(localized: "Assistant"), subtitle: model.providerLabel, symbol: .assistant,
                           onClose: { model.perform(ChatCommand.close) }) {
                Menu {
                    Button(String(localized: "New conversation")) { model.perform(ChatCommand.new) }
                        .disabled(!model.canUseHistory)
                    Button(String(localized: "Conversations")) { model.perform(ChatCommand.inspect, ["section": "conversations"]) }
                        .disabled(!model.canUseHistory)
                    ForEach(sizeClass == .compact ? [PanelPresentation.floating, .sidebar] : [.floating, .sidebar, .window], id: \.self) { mode in
                        Button(modeTitle(mode)) { model.perform(ChatCommand.open, ["mode": .string(mode.rawValue)]) }
                    }
                    Button(String(localized: "AI settings")) { model.perform(CommandIDs.settingsOpen, ["page": .string(model.settingsPageID)]) }
                    .accessibilityIdentifier("cmd." + CommandIDs.settingsOpen)
                } label: {
                    Image(nib: .more).font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                }
                .accessibilityLabel(String(localized: "Assistant options"))
            }
            if model.showsConversations { conversationList }
            else if !model.isConfigured { connectionBody }
            else { configuredBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Assistant"))
        .nibSheet(isPresented: Binding(get: { model.confirmation != nil }, set: { presented in
            if !presented, let pending = model.confirmation {
                model.perform(ChatCommand.confirm, ["request": .string(pending.id), "decision": "deny"])
            }
        })) {
            if let pending = model.confirmation { ConfirmationSheet(model: model, pending: pending) }
        }
        .confirmationDialog(String(localized: "Delete Conversation"), isPresented: Binding(
            get: { deletingChat != nil }, set: { if !$0 { deletingChat = nil } }
        ), titleVisibility: .visible) {
            Button(String(localized: "Delete Conversation"), role: .destructive) {
                if let id = deletingChat { model.perform(CommandIDs.aiChatDelete, ["chat": .string(id)]) }
                deletingChat = nil
            }
            .accessibilityIdentifier("cmd." + CommandIDs.aiChatDelete)
            Button(String(localized: "Cancel"), role: .cancel) { deletingChat = nil }
        } message: {
            Text(String(localized: "This conversation will be deleted on every device."))
        }
        .fileImporter(isPresented: $model.needsImagePicker, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let encoded = try await Task.detached { () throws -> String in
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
                            guard (attributes.fileSize ?? 0) <= 20_000_000 else { throw NibError.invalid("choose an image smaller than 20 MB", path: "$.image") }
                            return try Data(contentsOf: url).base64EncodedString()
                        }.value
                        model.perform(ChatCommand.attach, ["source": "image", "base64": .string(encoded)])
                    } catch { model.error = NibError.wrap(error) }
                }
            case .failure(let error): model.error = NibError.wrap(error)
            }
        }
        .onDisappear { model.perform(ChatCommand.inspect, ["section": "visibility", "visible": false, "lease": .string(visibilityLease)]) }
        .task {
            // The provider-store contract has no change publisher. Refresh display metadata while visible;
            // this never configures a provider or contacts its endpoint.
            while !Task.isCancelled {
                model.refreshProviderLabel()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task {
            model.windowUndoManager = context.navigator?.rootViewController?.undoManager
            model.perform(ChatCommand.inspect, ["section": "visibility", "visible": true, "lease": .string(visibilityLease)])
            if let scope = context.params["scope"]?.stringValue {
                model.perform(ChatCommand.configure, ["scope": .string(scope), "refs": context.params["refs"] ?? []])
            } else { model.perform(ChatCommand.inspect, ["section": "context"]) }
        }
    }

    private var contextRow: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            NibSegmentedControl(selection: Binding(get: { model.mode }, set: { mode in
                model.perform(ChatCommand.configure, ["mode": .string(mode.rawValue)])
            }), options: AIMode.allCases) { $0 == .ask ? String(localized: "Ask") : String(localized: "Edit") }
            .accessibilityLabel(String(localized: "Create mode"))
            .accessibilityHint(String(localized: "Ask reads notes. Edit can change notes."))
            .disabled(!model.canConfigureContext)
            ScrollView(.horizontal) {
                HStack(spacing: NibSpacing.s) {
                    Menu {
                        ForEach(AIScopeKind.allCases, id: \.self) { scope in
                            let reason = model.scopeUnavailableReason(scope)
                            Button([scopeTitle(scope), reason].compactMap { $0 }.joined(separator: " · ")) {
                                model.perform(ChatCommand.configure, ["scope": .string(scope.rawValue)])
                            }
                            .disabled(reason != nil)
                        }
                    } label: {
                        Label { Text(model.contextLabel) } icon: { Image(nib: .citation) }
                            .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                            .frame(minHeight: NibMetrics.hitTarget)
                    }
                    .accessibilityLabel(String(localized: "Context: \(model.contextLabel)"))
                    .disabled(!model.canConfigureContext)
                    ForEach(model.attachments, id: \.self) { ref in
                        NibChip(String(localized: "Page image"), symbol: .image, onRemove: {
                            model.perform(ChatCommand.attach, ["source": "remove", "asset": .string(ref.name)])
                        })
                        .disabled(!model.canConfigureContext)
                    }
                    Menu {
                        Button(String(localized: "Attach screenshot")) { model.perform(ChatCommand.attach, ["source": "screenshot"]) }
                        Button(String(localized: "Attach image")) { model.perform(ChatCommand.pickImage) }
                    } label: {
                        Image(nib: .plus).font(NibFont.glyph(.panel))
                            .foregroundStyle(NibColor.labelSecondary)
                            .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    }
                    .accessibilityLabel(String(localized: "Add image context"))
                    .disabled(!model.canConfigureContext)
                }
            }
        }
        .padding(.horizontal, NibSpacing.l)
        .padding(.bottom, NibSpacing.s)
    }

    // Setup owns the whole body. Inactive context and composer controls must never squeeze it out of a sheet.
    private var connectionBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                Text(String(localized: "Use your Claude or ChatGPT subscription with Nib Agent on your Mac."))
                    .font(NibFont.callout).foregroundStyle(NibColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ChatViewModel.connectionActions, id: \.self) { provider in
                    NibButton(provider, symbol: .settings, kind: .plain) {
                        model.perform(CommandIDs.settingsOpen, ["page": .string(ChatViewModel.connectionPage(for: provider))])
                    }
                    .accessibilityIdentifier("cmd." + CommandIDs.settingsOpen)
                    .accessibilityHint(String(localized: "Opens setup for this provider."))
                }
                operationFeedback
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NibSpacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var configuredBody: some View {
        ScrollViewReader { proxy in
            ChatThreadLayout(context: contextRow, thread: threadContent, composer: composer)
                .onChange(of: model.entries.last?.id) { _, _ in proxy.scrollTo("aichat.bottom", anchor: .bottom) }
        }
    }

    private var threadContent: some View {
        VStack(alignment: .leading, spacing: NibSpacing.xl) {
            if model.entries.isEmpty {
                Text(String(localized: "Ask about your notes, or switch to Edit to change them."))
                    .font(NibFont.chat).foregroundStyle(NibColor.labelSecondary)
            }
            ForEach(model.entries) { entry in ChatMessageView(model: model, entry: entry).id(entry.id) }
            if model.isStreaming, model.entries.last?.text.isEmpty == true {
                NibTraceRow(String(localized: "Reading your context…"), phase: .running)
            }
            if !model.isStreaming, let progress = model.progressLabel {
                NibTraceRow(progress, phase: .running)
            }
            if !model.proposals.isEmpty { ChatProposalsView(model: model) }
            if let draft = model.draft { ChatDraftView(model: model, draft: draft).id(draft.id) }
            if let error = model.error {
                NibBanner([error.message, error.hint].compactMap { $0 }.joined(separator: "\n"),
                          action: model.retryPrompt != nil && model.canSend ? NibAction(String(localized: "Retry")) {
                    model.perform(ChatCommand.send, ["retry": true])
                } : nil)
            }
            Color.clear.frame(height: NibSpacing.xxs).id("aichat.bottom")
        }
        .padding(NibSpacing.l)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            if !model.quickActions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: NibSpacing.s) {
                        ForEach(model.quickActions, id: \.id) { action in
                            NibChip(action.title, symbol: NibSymbol(systemName: action.icon), action: { model.perform(ChatCommand.send, ["action": .string(action.id)]) })
                        }
                    }
                    .padding(.vertical, NibSpacing.s)
                }
                .disabled(!model.canSend)
            }
            HStack(alignment: .bottom, spacing: NibSpacing.s) {
                NibField(text: $model.composer, prompt: String(localized: "Tell Nib what to change…"), lines: 1...5)
                    .accessibilityLabel(String(localized: "Question or instruction"))
                if model.isStreaming || model.isGeneratingImage {
                    NibIconButton(.stopGenerating, label: String(localized: "Stop generating"), size: .send) { model.perform(ChatCommand.stop) }
                } else if !model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NibIconButton(.send, label: String(localized: "Send to assistant"), size: .send) { model.perform(ChatCommand.send, ["prompt": .string(model.composer)]) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canSend)
                }
            }
            HStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "Generate image"), symbol: .image, kind: .plain, size: .compact) {
                    model.perform(ChatCommand.draft, ["action": "image", "prompt": .string(model.composer)])
                }
                .disabled(!model.canGenerateImage || model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }
            Text(String(localized: "\(model.tokenCount.formatted()) tokens this chat · sent only to your provider"))
                .font(NibFont.caption2).foregroundStyle(NibColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NibSpacing.l)
    }

    private var conversationList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                operationFeedback
                NibButton(String(localized: "New conversation"), symbol: .plus) { model.perform(ChatCommand.new) }
                    .disabled(!model.canUseHistory)
                if model.conversations.isEmpty, model.progressLabel == nil {
                    Text(String(localized: "No conversations yet")).font(NibFont.body).foregroundStyle(NibColor.labelSecondary)
                }
                ForEach(model.conversations) { chat in
                    VStack(alignment: .leading, spacing: NibSpacing.s) {
                        NibButton(chat.title, kind: .plain) { model.perform(ChatCommand.select, ["chat": .string(chat.id)]) }
                        if model.renamingChat == chat.id {
                            NibField(text: $model.renameTitle, prompt: String(localized: "Conversation title"))
                            NibButton(String(localized: "Save name"), kind: .secondary) {
                                model.perform(CommandIDs.aiChatRename, ["chat": .string(chat.id), "title": .string(model.renameTitle)])
                            }
                            .accessibilityIdentifier("cmd." + CommandIDs.aiChatRename)
                            .disabled(model.renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack(spacing: NibSpacing.s) {
                            NibButton(String(localized: "Rename Conversation"), kind: .plain, size: .compact) {
                                model.perform(ChatCommand.inspect, ["section": "rename", "chat": .string(chat.id)])
                            }
                            .disabled(model.renamingChat == chat.id)
                            NibButton(String(localized: "Delete Conversation"), kind: .destructivePlain, size: .compact) {
                                deletingChat = chat.id
                            }
                        }
                    }
                    .disabled(!model.canUseHistory)
                }
                NibButton(String(localized: "Back to thread"), kind: .plain) { model.perform(ChatCommand.inspect, ["section": "conversations"]) }
                    .disabled(!model.canUseHistory)
            }
            .padding(NibSpacing.l)
        }
    }

    private var operationFeedback: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            if let progress = model.progressLabel { NibTraceRow(progress, phase: .running) }
            if let error = model.error {
                NibBanner([error.message, error.hint].compactMap { $0 }.joined(separator: "\n"))
                if model.showsConversations {
                    Text(String(localized: "Try the action again. Any unsaved conversation name stays in its field."))
                        .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                }
            }
        }
    }

    private func scopeTitle(_ scope: AIScopeKind) -> String {
        switch scope {
        case .selection: return String(localized: "Selection")
        case .page: return String(localized: "Page")
        case .document: return String(localized: "Document")
        case .library: return String(localized: "Library")
        case .block: return String(localized: "Block")
        }
    }
    private func modeTitle(_ mode: PanelPresentation) -> String {
        switch mode {
        case .sidebar: return String(localized: "Sidebar")
        case .window: return String(localized: "Window")
        default: return String(localized: "Floating")
        }
    }
}

/// Keep a readable thread between fixed controls when they fit. At short detents or large text sizes, scroll
/// the entire body instead, so neither the thread nor the composer is compressed or clipped offscreen.
struct ChatThreadLayout<Context: View, Thread: View, Composer: View>: View {
    let context: Context
    let thread: Thread
    let composer: Composer
    static var minimumThreadHeight: CGFloat { NibMetrics.hitTarget * 3 }

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                context.fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(NibColor.separatorSoft).frame(height: NibStroke.hairline)
                ScrollView { thread }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(minHeight: Self.minimumThreadHeight)
                composer.fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 0) {
                    context
                    Rectangle().fill(NibColor.separatorSoft).frame(height: NibStroke.hairline)
                    thread.frame(minHeight: Self.minimumThreadHeight, alignment: .top)
                    composer
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}


/// The shared scene hook has no panel-scene factory. Compose it for assistant windows and delegate all other scenes.
@MainActor
final class ChatWindowScenes: SceneHooks {
    static let activityType = "app.nib.aiChat"
    unowned let app: NibApp
    let wrapped: SceneHooks?
    private var windows: [String: ChatWindowScene] = [:]

    init(app: NibApp, wrapped: SceneHooks?) { self.app = app; self.wrapped = wrapped }

    private func pruneWindows() { windows = windows.filter { $0.value.scene != nil } }

    func open(_ model: ChatViewModel) throws {
        pruneWindows()
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("assistant windows require the app") }
        guard UIApplication.shared.supportsMultipleScenes else {
            throw NibError(.unsupported, "use the assistant sheet on this device")
        }
        let activity = activity(for: model)
        let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity, options: nil)
        UIApplication.shared.activateSceneSession(for: request) { error in
            Task { @MainActor in model.error = NibError.wrap(error) }
        }
    }

    func close(_ session: EditorSession) -> Bool {
        pruneWindows()
        guard let scene = windows[session.id.raw]?.scene else { return false }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                ChatRuntime.get(self.app).model(for: session).error = NibError.wrap(error)
            }
        }
        return true
    }

    func sceneDidConnect(_ scene: UIWindowScene, options: UIScene.ConnectionOptions, navigator: SceneNavigator) {
        pruneWindows()
        let activities = Array(options.userActivities) + (scene.session.stateRestorationActivity.map { [$0] } ?? [])
        guard let activity = activities.first(where: { $0.activityType == Self.activityType }) else {
            wrapped?.sceneDidConnect(scene, options: options, navigator: navigator)
            return
        }
        let model = ChatRuntime.get(app).model(for: navigator.session)
        let savedScope: AIScope
        if let raw = activity.userInfo?["scope"] as? String, let json = try? JSONValue.parse(raw), let scope = try? json.decode(AIScope.self) {
            savedScope = scope
            navigator.session.document = scope.doc
            navigator.session.page = scope.page
        } else { savedScope = AIScope(kind: .library) }
        let chat = activity.userInfo?["chat"] as? String
        windows[navigator.session.id.raw] = ChatWindowScene(scene)
        Task { @MainActor [weak navigator] in
            guard let navigator else { return }
            if let chat, !chat.isEmpty {
                do { try await model.selectChat(chat) }
                catch { model.error = NibError.wrap(error) }
            }
            do { try model.setScope(savedScope.kind, refs: savedScope.refs) }
            catch { model.error = NibError.wrap(error) }
            var context = PanelContext(app: app, session: navigator.session, navigator: navigator, dismiss: { [weak self] in
                _ = self?.close(navigator.session)
            })
            context.presentation = .window
            let controller = UIHostingController(rootView: ChatPanel(model: model, context: context)
                .frame(maxWidth: NibMetrics.textColumnWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NibColor.backgroundSecondary))
            controller.modalPresentationStyle = .fullScreen
            controller.isModalInPresentation = true
            navigator.presentModal(controller)
        }
    }

    func restorationActivity(_ navigator: SceneNavigator) -> NSUserActivity? {
        pruneWindows()
        if windows[navigator.session.id.raw]?.scene != nil {
            return activity(for: ChatRuntime.get(app).model(for: navigator.session))
        }
        return wrapped?.restorationActivity(navigator)
    }

    func makeTabBar(_ navigator: SceneNavigator) -> UIView? {
        pruneWindows()
        return windows[navigator.session.id.raw]?.scene == nil ? wrapped?.makeTabBar(navigator) : nil
    }

    private func activity(for model: ChatViewModel) -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = String(localized: "Assistant")
        activity.userInfo = ["chat": model.chatID ?? "", "scope": (try? JSONValue.from(model.scope).jsonString()) ?? "{}"]
        return activity
    }
}

private final class ChatWindowScene {
    weak var scene: UIWindowScene?
    init(_ scene: UIWindowScene) { self.scene = scene }
}
