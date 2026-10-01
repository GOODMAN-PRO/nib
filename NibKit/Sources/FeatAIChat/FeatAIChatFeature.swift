import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

public enum FeatAIChatFeature: NibFeature {
    public static let id = "aichat"

    public static func register(_ app: NibApp) {
        ChatCommands.register(app)
        app.settings.declarePrefix("aichat.tokens.", synced: false, summary: "Observed token usage for each conversation on this device.",
                                   owner: id, schema: .int(min: 0))
        var panel = PanelDescriptor(id: PanelIDs.assistant, title: String(localized: "Assistant"),
                                    icon: NibSymbol.assistant.name, placement: .floating, order: 850, owner: id) { context in
            let model = ChatRuntime.get(context.app).model(for: context.session)
            model.presentation = context.presentation ?? .floating
            return AnyView(ChatPanel(model: model, context: context))
        }
        panel.providesHeader = true
        app.ui.panels.register(panel)
        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "aichat.answerDrop", owner: id, order: 850) { _ in
            ChatAnswerDropAttachment()
        })
        for location in [MenuLocation.objectMenu, .block, .textSelection] {
            app.ui.menus.register(MenuItemDescriptor(id: "aichat.ask.\(location.rawValue)", title: String(localized: "Ask AI"),
                icon: NibSymbol.assistant.name, location: location, order: 850, owner: id, command: ChatCommand.open,
                params: { context in
                    let refs = context.ref.map { [$0] } ?? context.selection.refs
                    let isBlock = refs.first.map { if case .block? = NodeRef($0) { return true }; return false } ?? false
                    return ["scope": .string(isBlock ? "block" : "selection"), "refs": .array(refs.map(JSONValue.string))]
                }, isVisible: { !$0.selection.refs.isEmpty || $0.ref != nil }))
        }
        app.content.keyCommands.register(KeyCommandDescriptor(id: "aichat.open", title: String(localized: "Assistant"),
            shortcut: KeyShortcut("a", [.option, .command]), command: ChatCommand.open, scope: .global, owner: id))
        // F017 owns the navigation-bar Assistant button, which targets PanelIDs.assistant.
    }

    public static func start(_ app: NibApp) async {
        let runtime = ChatRuntime.get(app)
        runtime.fallback = app.gateway.presenter
        if runtime.windowScenes == nil {
            let scenes = ChatWindowScenes(app: app, wrapped: app.ui.sceneHooks)
            runtime.windowScenes = scenes
            app.ui.sceneHooks = scenes
        }
        app.gateway.setPresenter(runtime, forPrincipalKind: "ai")
        app.gateway.setPolicy(forPrincipalKind: "ai") { [weak runtime, weak app] principal in
            if runtime?.hasTurn(for: principal) == true { return .always }
            return app?.settings.get(NibSettings.aiConfirmationPolicy) ?? .destructive
        }
    }
}

/// Additional UI commands are kept local until the shared command catalogue gains F085 entries.
enum ChatCommand {
    static let open = "ai.chat.open"
    static let new = "ai.chat.new"
    static let close = "ai.chat.close"
    static let select = "ai.chat.select"
    static let send = "ai.chat.send"
    static let stop = "ai.chat.stop"
    static let configure = "ai.chat.configure"
    static let inspect = "ai.chat.inspect"
    static let attach = "ai.chat.attach"
    static let pickImage = "ai.chat.pickImage"
    static let draft = "ai.chat.draft"
    static let dropAnswer = "ai.chat.dropAnswer"
    static let undo = "ai.chat.undo"
    static let show = "ai.chat.show"
    static let confirm = "ai.chat.confirm"
}

@MainActor
final class ChatRuntime: ConfirmationPresenter {
    static let serviceKey = "aichat.runtime"
    unowned let app: NibApp
    // Gateway deliberately holds presenters weakly. NibServices retains this runtime and its fallback.
    var fallback: ConfirmationPresenter?
    var windowScenes: ChatWindowScenes?
    private var models: [String: ChatViewModel] = [:]

    init(app: NibApp) { self.app = app }
    static func get(_ app: NibApp) -> ChatRuntime {
        if let runtime = app.services.get(serviceKey, as: ChatRuntime.self) { return runtime }
        let runtime = ChatRuntime(app: app)
        app.services.set(runtime, for: serviceKey)
        return runtime
    }
    func model(for session: EditorSession?) -> ChatViewModel {
        let key = session?.id.raw ?? "library"
        if let model = models[key] { return model }
        let model = ChatViewModel(app: app, session: session)
        models[key] = model
        return model
    }

    func hasTurn(for principal: Principal) -> Bool {
        guard case .ai(let chat) = principal else { return false }
        return models.values.contains { $0.isStreaming && $0.isVisible && $0.chatID == chat }
    }

    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        guard case .ai(let chat) = request.principal,
              let model = models.values.first(where: { $0.isStreaming && $0.isVisible && $0.chatID == chat }) else { return await fallback?.confirm(request) ?? .deny }
        let pending = ChatConfirmation(request: request)
        // Never contact a provider, capture media or execute an irreversible action just to preview it.
        if request.command.effect == .edit, !request.command.sensitive, !request.command.userPresence,
           !request.command.forwardsCalls {
            do {
                let preview = try await app.bus.execute(Invocation(command: request.command.id, params: request.params,
                    principal: .user, session: model.session, dryRun: true))
                pending.summary = preview.changes
                pending.previewText = String(localized: "\(preview.changes.count) changes: \(preview.changes.created.count) added, \(preview.changes.updated.count) updated, \(preview.changes.removed.count) removed.")
            } catch {
                pending.previewText = String(localized: "Preview unavailable: \(NibError.wrap(error).message)")
            }
        } else {
            pending.previewText = String(localized: "This action cannot be previewed without running it.")
        }
        guard model.isStreaming else { return .deny }
        return await model.requestConfirmation(pending)
    }
}

@MainActor
enum ChatCommands {
    static let scopeSchema = JSONSchema.str("context the model may read", choices: AIScopeKind.allCases.map(\.rawValue))

    static func register(_ app: NibApp) {
        func register(_ id: String, _ title: String, _ summary: String, schema: JSONSchema = .empty,
                      examples: [JSONValue] = [[:]], effect: Effect = .session, security: Bool = false,
                      sensitive: Bool = false, forwards: Bool = false, userPresence: Bool = false, extraScopes: Set<Scope> = [],
                      handler: @escaping CommandHandler) {
            let descriptor = CommandDescriptor(id: id, title: title, summary: summary, params: schema, examples: examples,
                effect: effect, target: .app, extraScopes: extraScopes.union(security ? [.security] : []), userPresence: userPresence, sensitive: sensitive, forwardsCalls: forwards)
            app.commands.register(descriptor) { params, ctx in
                do { return try await handler(params, ctx) }
                catch {
                    if !ctx.dryRun, let app = ctx.app {
                        ChatRuntime.get(app).model(for: ctx.activeSession).error = NibError.wrap(error)
                    }
                    throw error
                }
            }
        }
        register(ChatCommand.open, "Assistant", "Open the assistant in floating, sidebar or window mode with an optional selection or block context.",
            schema: .obj(["scope": scopeSchema, "refs": .arr(.ref), "mode": .str(choices: ["floating", "sidebar", "window"])]),
            examples: [[:], ["scope": "block", "refs": ["block:FIXTUREDOC02/FIXTUREBLK01"]]]) { p, ctx in
                let model = try model(ctx)
                if ctx.dryRun { return [:] }
                if let scope = p["scope"]?.stringValue {
                    guard !model.isStreaming else { throw NibError(.conflict, "stop this turn before changing its context") }
                    try model.setScope(try kind(scope), refs: try refs(p))
                }
                let mode = p["mode"]?.stringValue ?? "sidebar"
                guard ["floating", "sidebar", "window"].contains(mode) else { throw NibError.invalid("unknown panel mode", path: "$.mode") }
                guard !model.isStreaming, !model.isGeneratingImage else { throw NibError(.conflict, "stop this turn before changing panel mode") }
                model.presentation = PanelPresentation(rawValue: mode) ?? .floating
                if mode == "window" {
                    guard let app = ctx.app, let scenes = ChatRuntime.get(app).windowScenes else { throw NibError.unavailable("assistant window routing") }
                    try scenes.open(model)
                    return ["id": .string(PanelIDs.assistant), "placement": "window"]
                }
                let name = "chrome.panelPlacement." + PanelIDs.assistant
                // The chrome owns and declares the placement setting; do not redeclare a shared key here.
                if ctx.services.settings.descriptor(name) != nil {
                    let placement = mode == "floating" ? "floating" : (ctx.services.settings.get(NibSettings.sidebarOnRight) ? "right" : "left")
                    _ = try await ctx.execute(CommandIDs.settingsSet, ["name": .string(name), "value": .string(placement)])
                }
                if ctx.activeSession?.openPanels.contains(PanelIDs.assistant) == true {
                    _ = try await ctx.execute(CommandIDs.panelClose, ["id": .string(PanelIDs.assistant)])
                }
                return try await ctx.execute(CommandIDs.panelOpen, ["id": .string(PanelIDs.assistant), "params": ["mode": .string(mode)]])
            }
        register(ChatCommand.close, "Close Assistant", "Stop this window's turn, deny pending requests and close the assistant panel.") { _, ctx in
            if ctx.dryRun { return [:] }
            try model(ctx).stop()
            if let app = ctx.app, let session = ctx.activeSession, ChatRuntime.get(app).windowScenes?.close(session) == true {
                return ["closed": true]
            }
            return try await ctx.execute(CommandIDs.panelClose, ["id": .string(PanelIDs.assistant)])
        }
        register(ChatCommand.new, "New Conversation", "Start an empty conversation in this window; it is saved when its first turn is sent.") { _, ctx in
            if !ctx.dryRun { try model(ctx).newChat() }
            return [:]
        }
        register(ChatCommand.select, "Open Conversation", "Load a conversation and its messages through ai.chat.list.",
            schema: .obj(["chat": .str()], required: ["chat"]), examples: [["chat": "FIXTURECHAT1"]]) { p, ctx in
                if !ctx.dryRun { try await model(ctx).selectChat(try string(p, "chat"), principal: ctx.principal) }
                return [:]
            }
        register(ChatCommand.send, "Send to Assistant", "Stream a turn using this window's mode, context and attachments; retry=true retries the failed prompt.",
            schema: .obj(["prompt": .str(), "retry": .bool(), "action": .str("quick-action registry id")]),
            examples: [["prompt": "Summarise this document"]], sensitive: true, forwards: true, extraScopes: [.ai]) { p, ctx in
                let model = try model(ctx)
                if ctx.dryRun { return [:] }
                var prompt = p["prompt"]?.stringValue ?? model.composer
                if let id = p["action"]?.stringValue {
                    guard let action = ctx.content.aiActions.get(id) else { throw NibError.notFound("AI action '\(id)'") }
                    try model.setScope(action.scope)
                    model.mode = action.mode
                    prompt = action.prompt
                }
                let retry = p["retry"]?.boolValue ?? false
                if retry { prompt = model.retryPrompt ?? prompt }
                if !ctx.principal.isUser {
                    return try await ctx.execute(CommandIDs.aiAsk, ["prompt": .string(prompt), "scope": .string(model.scope.kind.rawValue),
                        "refs": .array(model.scope.refs.map(JSONValue.string)), "mode": .string(model.mode.rawValue)])
                }
                let response: AIResponse
                do {
                    response = try await model.send(prompt: prompt, principal: ctx.principal, group: ctx.group, retry: retry,
                                                    linkUndoAcrossDocuments: { ctx.linkUndoAcrossDocuments() })
                } catch is CancellationError {
                    let changes = model.entries.first(where: { $0.group == ctx.group })?.changes ?? ChangeSummary()
                    return ["cancelled": true, "group": .string(ctx.group), "changes": try JSONValue.from(changes)]
                }
                if let chat = response.chatID ?? model.chatID, let app = ctx.app {
                    app.settings.set(ChatViewModel.tokenKey(chat), model.totalTokens)
                }
                if Set(response.changes.all.compactMap { NodeRef($0)?.documentID }).count > 1 { ctx.linkUndoAcrossDocuments() }
                return try JSONValue.from(response)
            }
        register(ChatCommand.stop, "Stop Generating", "Cancel the assistant turn in this window and deny any pending confirmation.") { _, ctx in
            if !ctx.dryRun { try model(ctx).stop() }
            return [:]
        }
        register(ChatCommand.configure, "Assistant Context", "Set Ask or Edit mode and selection, page, document, library or block context.",
            schema: .obj(["mode": .str(choices: AIMode.allCases.map(\.rawValue)), "scope": scopeSchema, "refs": .arr(.ref)]),
            examples: [["mode": "ask", "scope": "document"]]) { p, ctx in
                let model = try model(ctx)
                guard !model.isStreaming else { throw NibError(.conflict, "stop this turn before changing its context") }
                if ctx.dryRun { return [:] }
                if let raw = p["mode"]?.stringValue {
                    guard let mode = AIMode(rawValue: raw) else { throw NibError.invalid("mode must be ask or edit", path: "$.mode") }
                    if let raw = p["scope"]?.stringValue { try model.setScope(try kind(raw), refs: try refs(p)) }
                    model.mode = mode
                } else if let raw = p["scope"]?.stringValue { try model.setScope(try kind(raw), refs: try refs(p)) }
                do { try await model.loadContext(principal: ctx.principal) }
                catch { model.error = NibError.wrap(error) }
                return [:]
            }
        register(ChatCommand.inspect, "Assistant Details", "Show conversations or raw tool calls, refresh context, or clear an inline error.",
            schema: .obj(["section": .str(choices: ["conversations", "tools", "context", "error", "visibility", "rename"]), "visible": .bool(), "chat": .str()], required: ["section"]),
            examples: [["section": "context"]]) { p, ctx in
                let model = try model(ctx)
                if ctx.dryRun { return [:] }
                switch try string(p, "section") {
                case "conversations": try await model.refreshChats(principal: ctx.principal); model.showsConversations.toggle()
                case "tools": model.showsTools.toggle()
                case "context": try await model.loadContext(principal: ctx.principal)
                case "error": model.error = nil
                case "rename":
                    let chat = try string(p, "chat")
                    guard let conversation = model.conversations.first(where: { $0.id == chat }) else { throw NibError.notFound("conversation") }
                    model.renamingChat = chat
                    model.renameTitle = conversation.title
                case "visibility":
                    model.isVisible = p["visible"]?.boolValue ?? false
                    if !model.isVisible { model.stop() }
                default: throw NibError.invalid("unknown section", path: "$.section")
                }
                return [:]
            }
        register(ChatCommand.pickImage, "Choose Image Context", "Open the system image-file picker to attach an image to the next assistant turn.", userPresence: true) { _, ctx in
            if ctx.dryRun { return [:] }
            guard ctx.principal.isUser, !NibApp.isHostlessTest else { throw NibError(.unavailable, "open the image picker in the app") }
            let model = try model(ctx)
            guard !model.isStreaming, ctx.services.ai?.supportsVision == true else { throw NibError(.unavailable, "wait for this turn or choose a model with vision") }
            model.needsImagePicker = true
            return [:]
        }
        register(ChatCommand.attach, "Attach Image", "Attach a screenshot, image asset or base64 image to the next turn, or remove an attachment.",
            schema: .obj(["source": .str(choices: ["screenshot", "image", "remove"]), "asset": .str(), "base64": .str()], required: ["source"]),
            examples: [["source": "image", "asset": "fixture-image.png"]]) { p, ctx in
                let model = try model(ctx)
                guard !model.isStreaming else { throw NibError(.conflict, "wait for this turn before adding context") }
                if ctx.dryRun { return [:] }
                let source = try string(p, "source")
                if source == "remove" {
                    let asset = try string(p, "asset")
                    model.attachments.removeAll { $0.name == asset }
                    return [:]
                }
                guard ctx.services.ai?.supportsVision == true else { throw NibError(.unsupported, "this model cannot read images") }
                guard let assets = ctx.services.assets else { throw NibError.unavailable("asset store") }
                let ref: AssetRef
                if source == "screenshot" {
                    let (d, page) = try ctx.pageOrSession(nil)
                    let rendered = try await ctx.execute(CommandIDs.renderPage, ["page": .string(NodeRef.page(d, page).description)])
                    guard let raw = rendered["asset"]?.stringValue else { throw NibError(.unavailable, "the renderer returned no screenshot") }
                    ref = AssetRef(raw)
                } else if source == "image" {
                    if let base64 = p["base64"]?.stringValue {
                        guard base64.utf8.count <= 28_000_000, let data = Data(base64Encoded: base64) else { throw NibError.invalid("invalid image bytes", path: "$.base64") }
                        ref = try await Task.detached { () throws -> AssetRef in
                            guard UIImage(data: data) != nil else { throw NibError.invalid("unreadable image", path: "$.base64") }
                            return try assets.putTemporary(data, ext: "png")
                        }.value
                    } else {
                        ref = AssetRef(try string(p, "asset"))
                        guard assets.temporaryURL(ref) != nil || model.scope.doc.map({ assets.url(ref, doc: $0) != nil }) == true else {
                            throw NibError.notFound("image asset")
                        }
                    }
                } else { throw NibError.invalid("unknown attachment source", path: "$.source") }
                if !model.attachments.contains(ref) { model.attachments.append(ref) }
                return ["asset": .string(ref.name)]
            }
        register(ChatCommand.draft, "Assistant Draft", "Generate or modify an image, review an answer as a draft, edit its text, or discard it without changing notes.",
            schema: .obj(["action": .str(choices: ["image", "modify", "answer", "text", "discard"]), "prompt": .str(), "message": .str(), "text": .str()], required: ["action"]),
            examples: [["action": "discard"]], sensitive: true, extraScopes: [.ai]) { p, ctx in
                let model = try model(ctx)
                if ctx.dryRun { return [:] }
                let action = try string(p, "action")
                switch action {
                case "image", "modify":
                    let prompt = p["prompt"]?.stringValue ?? model.composer
                    if action == "modify" {
                        guard model.draft?.asset != nil else { throw NibError.notFound("generated image draft") }
                        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NibError.invalid("describe the image revision", path: "$.prompt") }
                    }
                    let prior = action == "modify" ? model.draft?.prompt : nil
                    // AIService exposes generation, not image-to-image editing. Retain the original brief explicitly.
                    let brief = prior.map { $0 + "\n" + String(localized: "Requested revision: ") + prompt } ?? prompt
                    try await model.generateImage(brief)
                case "answer":
                    let id = try string(p, "message")
                    guard let entry = model.entries.first(where: { $0.id == id && $0.role == "assistant" }) else { throw NibError.notFound("answer") }
                    model.draft = ChatDraft(text: entry.text, prompt: entry.text)
                case "text":
                    guard model.draft != nil else { throw NibError.notFound("draft") }
                    model.draft?.text = try string(p, "text")
                case "discard":
                    if model.isGeneratingImage { model.stop() }
                    model.draft = nil
                default: throw NibError.invalid("unknown draft action", path: "$.action")
                }
                return [:]
            }
        register("ai.chat.insertDraft", "Insert Draft", "Insert the reviewed draft through image.insert, block.insert or text.createBox in one undo group; accepts caller-chosen id.",
            schema: .obj(["page": .ref, "doc": .ref, "at": .point, "text": .str(), "id": .str("caller-chosen item or block id")]), examples: [[:]], effect: .edit, forwards: true) { p, ctx in
                let model = try model(ctx)
                guard let draft = model.draft else { throw NibError(.unavailable, "review a draft before inserting it") }
                let id = p["id"]?.stringValue ?? NibID.make().raw
                let draftText = p["text"]?.stringValue ?? draft.text
                var params: JSONValue = ["id": .string(id)]
                let result: JSONValue
                if let asset = draft.asset {
                    let (d, page) = try ctx.pageOrSession(p["page"]?.stringValue)
                    guard let assets = ctx.services.assets, let url = assets.temporaryURL(asset) else { throw NibError.notFound("generated image") }
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    params = params.merging(["page": .string(NodeRef.page(d, page).description), "base64": .string(data.base64EncodedString()), "at": p["at"] ?? [72, 72]])
                    result = try await insertAIContent(CommandIDs.imageInsert, params, context: ctx, chat: model.chatID ?? draft.id)
                } else if model.docKind == .textDocument {
                    let d = try ctx.documentOrSession(p["doc"]?.stringValue)
                    params = params.merging(["doc": .string(NodeRef.document(d).description), "kind": "paragraph", "text": .string(draftText)])
                    result = try await insertAIContent(CommandIDs.blockInsert, params, context: ctx, chat: model.chatID ?? draft.id)
                } else {
                    let (d, page) = try ctx.pageOrSession(p["page"]?.stringValue)
                    params = params.merging(["page": .string(NodeRef.page(d, page).description), "text": .string(draftText), "at": p["at"] ?? [72, 72]])
                    result = try await insertAIContent(CommandIDs.textCreateBox, params, context: ctx, chat: model.chatID ?? draft.id)
                }
                if !ctx.dryRun {
                    model.draft = nil
                    let changes = (try? result["changes"]?.decode(ChangeSummary.self)) ?? ctx.summary
                    model.entries.append(ChatEntry(id: NibID.make().raw, role: "assistant",
                        text: String(localized: "Inserted draft."), changes: changes, group: ctx.group, isReceipt: true))
                }
                return result
            }
        register(ChatCommand.dropAnswer, "Place AI Answer", "Insert a dragged answer as a text box at a page position, with AI provenance and one undo group; accepts caller-chosen id.",
            schema: .obj(["text": .str(), "page": .ref, "at": .point, "chat": .str(), "id": .str()], required: ["text", "page", "at"]),
            examples: [["text": "Answer", "page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [72, 72], "id": "FIXTUREDRFT1"]], effect: .edit) { p, ctx in
                let text = try string(p, "text")
                guard text.utf8.count <= 1_000_000 else { throw NibError.invalid("answer is too large", path: "$.text") }
                let params = p.merging(["id": p["id"] ?? .string(NibID.make().raw)])
                let output = try await insertAIContent(CommandIDs.textCreateBox, params, context: ctx,
                                                      chat: p["chat"]?.stringValue ?? NibID.make().raw)
                if !ctx.dryRun {
                    let changes = (try? output["changes"]?.decode(ChangeSummary.self)) ?? ctx.summary
                    try model(ctx).entries.append(ChatEntry(id: NibID.make().raw, role: "assistant",
                        text: String(localized: "Placed answer on the page."), changes: changes, group: ctx.group, isReceipt: true))
                }
                return output
            }
        register(ChatCommand.undo, "Undo AI Turn", "Selectively revert every document changed by this answer through history.revertGroup, keeping later edits.",
            schema: .obj(["message": .str()], required: ["message"]), examples: [["message": "FIXTUREMSG01"]], effect: .edit) { p, ctx in
                if ctx.dryRun { throw NibError(.unsupported, "selective undo cannot be previewed") }
                return try await model(ctx).undo(try string(p, "message"), context: ctx)
            }
        register(ChatCommand.show, "Show AI Changes", "Reveal the refs changed by an answer, including the parent page of deleted items.",
            schema: .obj(["message": .str()], required: ["message"]), examples: [["message": "FIXTUREMSG01"]]) { p, ctx in
                if !ctx.dryRun { try await model(ctx).showChanges(try string(p, "message"), context: ctx) }
                return [:]
            }
        register(ChatCommand.confirm, "Confirm AI Action", "Allow once, allow for the rest of this turn, or deny a pending AI permission request; user only.",
            schema: .obj(["request": .str(), "decision": .str(choices: ["allow", "turn", "deny"])], required: ["request", "decision"]),
            examples: [["request": "FIXTURECONF1", "decision": "deny"]], security: true) { p, ctx in
                let model = try model(ctx)
                guard model.confirmation?.id == (try string(p, "request")) else { throw NibError.notFound("confirmation request") }
                if ctx.dryRun { return [:] }
                switch try string(p, "decision") {
                case "allow": model.resolveConfirmation(.allow)
                case "turn": model.resolveConfirmation(.allowRestOfGroup)
                case "deny": model.resolveConfirmation(.deny)
                default: throw NibError.invalid("unknown decision", path: "$.decision")
                }
                return [:]
            }
    }

    static func insertAIContent(_ command: String, _ params: JSONValue, context ctx: CommandContext, chat: String) async throws -> JSONValue {
        if !ctx.principal.isUser { return try await ctx.execute(command, params) }
        // The accepted answer is AI content; the gateway still authorises the real insertion command.
        let output = try await ctx.bus.execute(Invocation(command: command, params: params,
            principal: .ai(chat), session: ctx.session, group: ctx.group, dryRun: ctx.dryRun,
            depth: ctx.depth + 1, readOnly: ctx.readOnly, inheritedPolicy: ctx.inheritedPolicy))
        return output.value.merging(["changes": try JSONValue.from(output.changes)])
    }

    static func model(_ ctx: CommandContext) throws -> ChatViewModel {
        guard let app = ctx.app else { throw NibError.unavailable("assistant app") }
        return ChatRuntime.get(app).model(for: ctx.activeSession)
    }
    static func string(_ json: JSONValue, _ key: String) throws -> String {
        guard let value = json[key]?.stringValue, !value.isEmpty else { throw NibError.invalid("missing '\(key)'", path: "$." + key) }
        return value
    }
    static func refs(_ json: JSONValue) throws -> [String] {
        guard let raw = json["refs"] else { return [] }
        guard let array = raw.arrayValue else { throw NibError.invalid("refs must be an array", path: "$.refs") }
        return try array.enumerated().map { index, value in
            guard let ref = value.stringValue, NodeRef(ref) != nil else { throw NibError.invalid("invalid ref", path: "$.refs[\(index)]") }
            return ref
        }
    }
    static func kind(_ raw: String) throws -> AIScopeKind {
        guard let kind = AIScopeKind(rawValue: raw) else { throw NibError.invalid("unknown context", path: "$.scope") }
        return kind
    }
}
