import Foundation

/// Commands that live in the contracts layer and are registered by `NibApp.init`.
enum CoreCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(EditUndo.self)
        r.register(EditRedo.self)
        r.register(HistoryList.self)
        r.register(HistoryRevertGroup.self)
        r.register(CommandsList.self)
        r.register(CommandsDescribe.self)
        r.register(CommandsBatch.self)
        r.register(ToolSelect.self)
        r.register(SettingsGet.self)
        r.register(SettingsSet.self)
        r.register(SettingsList.self)
        r.register(SettingsDescribe.self)
        r.register(WindowShowLibrary.self)
    }
}

struct DocParams: Codable {
    /// contracts-v2: optional for the user (key commands, toolbar buttons): nil = the invoking window's document.
    /// The schema still requires it, so the AI, plugins and the bridge always name the document.
    var doc: String?
}

struct EditUndo: NibCommand {
    struct Output: Codable {
        var done: Bool
        var label: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.undo, title: "Undo",
        summary: "Undo the last change in a document (same as the Undo button). A whole AI turn or plugin call undoes as one step.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)

    static func run(_ p: DocParams, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let label = ctx.bus.history.undoLabel(doc)
        return Output(done: ctx.bus.undo(doc), label: label)
    }
}

struct EditRedo: NibCommand {
    struct Output: Codable {
        var done: Bool
        var label: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.redo, title: "Redo",
        summary: "Redo the last undone change in a document.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)

    static func run(_ p: DocParams, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let label = ctx.bus.history.redoLabel(doc)
        return Output(done: ctx.bus.redo(doc), label: label)
    }
}

struct HistoryList: NibCommand {
    struct Params: Codable {
        var doc: String
        var limit: Int?
    }
    struct Row: Codable {
        var group: String
        var label: String
        var principal: String
        var changes: Int
        var at: Double
    }
    struct Output: Codable {
        var entries: [Row]
        var canRedo: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.historyList, title: "History",
        summary: "List undoable changes in a document, newest first, with their undo group ids (for history.revertGroup).",
        params: .obj(["doc": .ref, "limit": .int(min: 1, max: 200)], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01", "limit": 10]], effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let rows = ctx.bus.history.entries(doc).reversed().prefix(p.limit ?? 50).map {
            Row(group: $0.group, label: $0.label, principal: $0.principal.description, changes: $0.mutations.count,
                at: $0.at.timeIntervalSince1970)
        }
        return Output(entries: Array(rows), canRedo: ctx.bus.history.canRedo(doc))
    }
}

struct HistoryRevertGroup: NibCommand {
    struct Params: Codable {
        var doc: String
        var group: String
    }
    struct Output: Codable {
        var reverted: Int
        var skipped: Int
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.revertGroup, title: "Revert Changes",
        summary: "Revert one undo group (e.g. everything an AI turn did) even after later edits; records changed since are skipped.",
        params: .obj(["doc": .ref, "group": .str("undo group id from history.list or an AI turn")], required: ["doc", "group"]),
        examples: [["doc": "doc:FIXTUREDOC01", "group": "G0"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        guard let r = ctx.bus.revert(group: p.group, doc: doc, principal: ctx.principal) else {
            throw NibError.notFound("undo group '\(p.group)'")
        }
        return Output(reverted: r.reverted, skipped: r.skipped)
    }
}

struct CommandsList: NibCommand {
    struct Params: Codable {
        var namespace: String?
    }
    struct Row: Codable {
        var id: String
        var title: String
        var summary: String
        var effect: String
        var destructive: Bool
    }
    struct Output: Codable {
        var commands: [Row]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.commandsList, title: "List Commands",
        summary: "List the commands you may call (id, one-line summary, effect). Optional namespace prefix such as 'page' or 'shape'.",
        params: .obj(["namespace": .str("namespace prefix, e.g. 'ink'")]),
        examples: [[:], ["namespace": "edit"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let exposure = ctx.principal.exposure
        let rows = ctx.bus.registry.all().filter { d in
            let visible = ctx.principal.isUser || d.exposure.contains(exposure)
            let inNamespace = p.namespace.map { d.id == $0 || d.id.hasPrefix($0 + ".") } ?? true
            return visible && inNamespace
        }.map { Row(id: $0.id, title: $0.title, summary: $0.summary, effect: $0.effect.rawValue, destructive: $0.destructive) }
        return Output(commands: rows)
    }
}

struct CommandsDescribe: NibCommand {
    struct Params: Codable {
        var id: String
    }
    struct Output: Codable {
        var id: String
        var title: String
        var summary: String
        var params: JSONValue
        var examples: [JSONValue]
        var effect: String
        var destructive: Bool
        var scopes: [String]
        var owner: String
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.commandsDescribe, title: "Describe Command",
        summary: "Full JSON schema, examples, effect and required permissions of one command.",
        params: .obj(["id": .str("command id, e.g. 'ink.addStrokes'")], required: ["id"]),
        examples: [["id": "edit.undo"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let d = ctx.bus.registry.descriptor(p.id),
              ctx.principal.isUser || d.exposure.contains(ctx.principal.exposure) else {
            throw NibError(.notFound, "unknown command '\(p.id)'", hint: "call commands.list")
        }
        return Output(id: d.id, title: d.title, summary: d.summary, params: d.params.toJSON(), examples: d.examples,
                      effect: d.effect.rawValue, destructive: d.destructive, scopes: d.scopes.map { $0.rawValue }.sorted(),
                      owner: d.owner)
    }
}

struct CommandsBatch: NibCommand {
    struct Call: Codable {
        var command: String
        var params: JSONValue?
    }
    struct Params: Codable {
        var calls: [Call]
        var stopOnError: Bool?
    }
    struct Outcome: Codable {
        var ok: Bool
        var value: JSONValue?
        var error: NibError?
    }
    struct Output: Codable {
        var results: [Outcome]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.batch, title: "Batch",
        summary: "Run several commands in order as ONE undo step (each is permission-checked). Give new items your own ids to link them.",
        params: .obj(["calls": .arr(.obj(["command": .str(), "params": .obj([:])], required: ["command"])),
                      "stopOnError": .bool("default true")], required: ["calls"]),
        examples: [["calls": [["command": "commands.list", "params": ["namespace": "edit"]]]]],
        effect: .read, target: .app, forwardsCalls: true)   // effect = the calls' effects: each call is authorized,
                                                            // and in ask mode every call must be `read`

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var out: [Outcome] = []
        for call in p.calls {
            do {
                let v = try await ctx.execute(call.command, call.params ?? [:])
                out.append(Outcome(ok: true, value: v, error: nil))
            } catch {
                out.append(Outcome(ok: false, value: nil, error: NibError.wrap(error)))
                if p.stopOnError ?? true { break }
            }
        }
        return Output(results: out)
    }
}

struct ToolSelect: NibCommand {
    struct Params: Codable {
        var tool: String
        /// contracts-v2: true = until the tool finishes one use or `EditorSession.endTemporaryTool()`, then back.
        var temporary: Bool?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.toolSelect, title: "Select Tool",
        summary: "Activate a canvas tool in the current window: pen, pencil, highlighter, eraser, lasso, shape, text, tape, laser, or a plugin tool id.",
        params: .obj(["tool": .str("tool id"),
                      "temporary": .bool("true = return to the current tool after one use")], required: ["tool"]),
        examples: [["tool": "pen"], ["tool": "lasso", "temporary": true]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        if p.temporary == true {
            session.selectTemporarily(p.tool)
        } else {
            session.selectTool(p.tool)
        }
        return NoResult()
    }
}

/// contracts-v2: shows the library in the invoking window (the document chrome's Back button, the tab strip's Library
/// button, the AI and plugins).
struct WindowShowLibrary: NibCommand {
    struct Params: Codable {
        var folder: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.windowShowLibrary, title: "Show Library",
        summary: "Show the library in the current window, optionally opened at a folder ('folder:F' or a folder id).",
        params: .obj(["folder": .str("folder ref folder:F or folder id; omit for the library root")]),
        examples: [[:], ["folder": "folder:FIXTUREFLD01"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let navigator = ctx.navigator else { throw NibError.unavailable("a window") }
        var folder: FolderID?
        if let f = p.folder, !f.isEmpty, f != "lib" {
            if case let .folder(id)? = NodeRef(f) {
                folder = id
            } else if NibID.isValid(f) {
                folder = NibID(f)
            } else {
                throw NibError.invalid("'folder' must be a folder ref like folder:F", path: "$.folder")
            }
        }
        navigator.showLibrary(folder: folder)
        return NoResult()
    }
}

struct SettingsGet: NibCommand {
    struct Params: Codable {
        var name: String
    }
    struct Output: Codable {
        var name: String
        var value: JSONValue?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsGet, title: "Get Setting",
        summary: "Read a setting by name, e.g. 'editing.scrollDirection' or 'plugin.<id>.<key>' (see settings.list).",
        params: .obj(["name": .str()], required: ["name"]),
        examples: [["name": "editing.scrollDirection"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if p.name.hasPrefix("security.") && !ctx.principal.isUser {
            throw NibError(.permissionDenied, "security settings can only be read by the user")
        }
        return Output(name: p.name, value: ctx.services.settings.json(p.name))
    }
}

struct SettingsSet: NibCommand {
    struct Params: Codable {
        var name: String
        var value: JSONValue?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsSet, title: "Change Setting",
        summary: "Change a declared setting (null resets it); the value is validated. 'security.*' is user-only, 'managed.*' read-only.",
        params: .obj(["name": .str(), "value": .anything("new value; null resets to default")], required: ["name"]),
        examples: [["name": "editing.scrollDirection", "value": "horizontal"]], effect: .edit, target: .app,
        undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let d = ctx.services.settings.descriptor(p.name) else {
            throw NibError(.notFound, "unknown setting '\(p.name)'", hint: "call settings.list to see setting names")
        }
        if d.userOnly && !ctx.principal.isUser {
            throw NibError(.permissionDenied, "security settings can only be changed by the user")
        }
        if d.readOnly { throw NibError(.permissionDenied, "'\(p.name)' is read-only (managed configuration)") }
        if let v = p.value, v != .null, let e = d.schema.validate(v, path: "$.value").first {
            throw NibError(e.code, e.message, path: e.path, hint: "call settings.describe {\"name\": \"\(p.name)\"}")
        }
        ctx.services.settings.setJSON(p.name, p.value)
        return NoResult()
    }
}

struct SettingsList: NibCommand {
    struct Params: Codable {
        var prefix: String?
    }
    struct Row: Codable {
        var name: String
        var summary: String
        var synced: Bool
        var owner: String
    }
    struct Output: Codable {
        var settings: [Row]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsList, title: "List Settings",
        summary: "List declared settings (name, summary, synced, owner), optionally under a name prefix like 'editing.'.",
        params: .obj(["prefix": .str("name prefix, e.g. 'editing.'")]),
        examples: [[:], ["prefix": "editing."]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let rows = ctx.services.settings.declaredSettings
            .filter { p.prefix.map($0.name.hasPrefix) ?? true }
            .filter { ctx.principal.isUser || !$0.userOnly }
            .map { Row(name: $0.name, summary: $0.summary, synced: $0.synced, owner: $0.owner) }
        return Output(settings: rows)
    }
}

struct SettingsDescribe: NibCommand {
    struct Params: Codable {
        var name: String
    }
    struct Output: Codable {
        var name: String
        var summary: String
        var schema: JSONValue
        var defaultValue: JSONValue
        var synced: Bool
        var readOnly: Bool
        var userOnly: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsDescribe, title: "Describe Setting",
        summary: "Schema, default value and flags of one setting (or of the family a per-entry name belongs to).",
        params: .obj(["name": .str()], required: ["name"]),
        examples: [["name": "editing.scrollDirection"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let d = ctx.services.settings.descriptor(p.name) else {
            throw NibError(.notFound, "unknown setting '\(p.name)'", hint: "call settings.list")
        }
        return Output(name: d.name, summary: d.summary, schema: d.schema.toJSON(), defaultValue: d.defaultValue,
                      synced: d.synced, readOnly: d.readOnly, userOnly: d.userOnly)
    }
}
