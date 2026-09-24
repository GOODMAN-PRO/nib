import Foundation

/// A JSON-level command call (plugins, AI, MCP bridge, key commands, menus).
public struct Invocation {
    public var command: String
    public var params: JSONValue
    public var principal: Principal
    public var session: EditorSession?
    /// Undo group; nil = a fresh group. Pass the same group to make several calls one undo step.
    public var group: String?
    /// Run, collect the change summary, then roll back. Nothing is persisted, recorded or emitted.
    public var dryRun: Bool
    public var depth: Int
    /// Ask mode: this call and everything it calls (nested commands, plugin handlers, batches) must be `read`.
    public var readOnly: Bool
    /// Confirmation policy inherited from an outer non-user caller (e.g. the AI running a plugin command whose
    /// handler calls more commands); the stricter of this and the principal's own policy applies.
    public var inheritedPolicy: ConfirmationPolicy?
    /// Set when running a command hook, so hooks never trigger hooks.
    public var skipHooks: Bool

    public init(command: String, params: JSONValue = [:], principal: Principal = .user, session: EditorSession? = nil,
                group: String? = nil, dryRun: Bool = false, depth: Int = 0, readOnly: Bool = false,
                inheritedPolicy: ConfirmationPolicy? = nil, skipHooks: Bool = false) {
        self.command = command
        self.params = params
        self.principal = principal
        self.session = session
        self.group = group
        self.dryRun = dryRun
        self.depth = depth
        self.readOnly = readOnly
        self.inheritedPolicy = inheritedPolicy
        self.skipHooks = skipHooks
    }
}

/// A before-command hook (plugins' `contributes.commandHooks`, features). The hook command must be `read`; it gets
/// {"command": id, "params": …} and returns {"params": …} to transform the call, `{}` to let it pass, or throws to
/// veto it. Registered in `app.bus.hooks`.
public struct CommandHookDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    /// Exact command ids or namespace wildcards ("page.*").
    public var commands: [String]
    /// The hook command to run.
    public var command: String
    /// Principal the hook runs as (`.plugin(id)` for plugins).
    public var principal: Principal

    public init(id: String, owner: String, commands: [String], command: String, principal: Principal = .user, order: Int = 0) {
        self.id = id
        self.order = order
        self.owner = owner
        self.commands = commands
        self.command = command
        self.principal = principal
    }

    public func matches(_ commandID: String) -> Bool {
        commands.contains { $0 == commandID || ($0.hasSuffix(".*") && commandID.hasPrefix(String($0.dropLast(1)))) }
    }
}

public struct InvocationResult: Codable {
    public var value: JSONValue
    public var changes: ChangeSummary
    public var group: String

    public init(value: JSONValue, changes: ChangeSummary, group: String) {
        self.value = value
        self.changes = changes
        self.group = group
    }
}

/// Handed to every command run. The only source of `DocTransaction`s.
@MainActor
public final class CommandContext {
    public let bus: CommandBus
    public let principal: Principal
    public let group: String
    public let depth: Int
    public let dryRun: Bool
    /// The invoking window's session (nil for bridge/background callers; see `activeSession`).
    public let session: EditorSession?
    public let commandID: String
    public let title: String
    /// True in ask mode and inside `read` commands (unless the descriptor `forwardsCalls`): nested calls must be
    /// `read` and `mutate` throws `permission_denied`. Plugin runtimes copy it into the Invocations they build.
    public let readOnly: Bool
    /// Passed on to nested calls (see `Invocation.inheritedPolicy`).
    public let inheritedPolicy: ConfirmationPolicy?
    public private(set) var summary = ChangeSummary()

    init(bus: CommandBus, principal: Principal, group: String, depth: Int, dryRun: Bool, session: EditorSession?,
         commandID: String, title: String, readOnly: Bool = false, inheritedPolicy: ConfirmationPolicy? = nil) {
        self.bus = bus
        self.principal = principal
        self.group = group
        self.depth = depth
        self.dryRun = dryRun
        self.session = session
        self.commandID = commandID
        self.title = title
        self.readOnly = readOnly
        self.inheritedPolicy = inheritedPolicy
    }

    public var workspace: Workspace { bus.workspace }
    public var services: NibServices { bus.services }
    public var events: EventBus { bus.events }
    /// The invoking session, else the most recently active window's session.
    public var activeSession: EditorSession? { session ?? bus.services.sessions.active }

    /// Runs synchronous writes atomically. Throwing (or an invariant failure) rolls everything back.
    /// All `mutate` calls in one command (and nested commands) share the undo group.
    /// `undoable: false` = persisted but not undoable (tape reveal, study grading, per-document view state).
    @discardableResult
    public func mutate<T>(_ label: String? = nil, undoable: Bool = true, _ body: (DocTransaction) throws -> T) throws -> T {
        if readOnly {
            throw NibError(.permissionDenied, "'\(commandID)' runs read-only and cannot change documents",
                           hint: "switch to Edit mode (AI), or declare the command with a mutating effect")
        }
        let tx = DocTransaction(workspace: bus.workspace, principal: principal, group: group)
        let result: T
        do {
            result = try body(tx)
            try tx.validate()
        } catch {
            tx.rollback()
            throw error
        }
        if dryRun {
            summary.merge(Changeset.summarize(tx.mutations))
            tx.rollback()
        } else if !tx.mutations.isEmpty {
            let cs = bus.commit(tx, label: label ?? title, command: commandID, record: undoable)
            summary.merge(cs.summary)
        }
        return result
    }

    /// Calls another command as the same principal, in the same undo group, inheriting read-only mode and the
    /// confirmation policy. Permission checks apply. An unknown nested command throws `unavailable`.
    public func execute(_ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let inv = Invocation(command: command, params: params, principal: principal, session: session,
                             group: group, dryRun: dryRun, depth: depth + 1, readOnly: readOnly,
                             inheritedPolicy: inheritedPolicy)
        let r = try await bus.execute(inv)
        summary.merge(r.changes)
        return r.value
    }

    /// Typed nested call (goes through the registry like any other call).
    public func execute<C: NibCommand>(_ type: C.Type, _ params: C.Params) async throws -> C.Output {
        let json = try JSONValue.from(params)
        let value = try await execute(C.descriptor.id, json)
        return try CommandRegistry.decode(C.Output.self, from: value)
    }

    /// Resolves a url-typed parameter to a local file this command may read. Accepted:
    /// "tmp:<name>" (from `asset.upload`, renders, exports), "https://…" (downloaded to a temp file), and
    /// "file://…" only for the user principal or inside this app's tmp / Documents/Inbox folders — so the AI,
    /// plugins and the bridge can never read arbitrary sandbox paths (e.g. a locked document's package).
    public func inputFile(_ string: String) async throws -> URL {
        let fm = FileManager.default
        if string.hasPrefix("tmp:") {
            guard let url = services.assets?.temporaryURL(AssetRef(String(string.dropFirst(4)))) else {
                throw NibError.notFound("temporary asset \(string)")
            }
            return url
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            throw NibError.invalid("not a URL: \(string)")
        }
        switch scheme {
        case "https", "http" where principal.isUser:
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NibError(.unavailable, "download failed: \(url.absoluteString)")
            }
            let dest = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        case "file":
            if principal.isUser { return url }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let allowed = [fm.temporaryDirectory,
                           fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")]
                .map { $0.resolvingSymlinksInPath().path + "/" }
            guard allowed.contains(where: { path.hasPrefix($0) }) else {
                throw NibError(.permissionDenied, "file URLs are only accepted from the user",
                               hint: "upload the bytes with asset.upload and pass the returned tmp: ref")
            }
            return url
        default:
            throw NibError.invalid("unsupported URL '\(string)'; use a tmp: ref from asset.upload or an https URL")
        }
    }
}

/// Executes commands, commits transactions, drives undo/redo and merges remote changes.
@MainActor
public final class CommandBus {
    public let registry: CommandRegistry
    public let workspace: Workspace
    public let gateway: Gateway
    public let services: NibServices
    public let events: EventBus
    public let history: UndoHistory
    /// Before-command hooks (plugins' `contributes.commandHooks`, features). Run for every JSON and typed call.
    public let hooks = Registry<CommandHookDescriptor>()
    private var seq: UInt64 = 0
    private var observers: [UUID: (Changeset) -> Void] = [:]

    public init(registry: CommandRegistry, workspace: Workspace, gateway: Gateway, services: NibServices, events: EventBus) {
        self.registry = registry
        self.workspace = workspace
        self.gateway = gateway
        self.services = services
        self.events = events
        self.history = UndoHistory()
    }

    // MARK: Execution

    /// Typed fast path for native UI code (no JSON). Non-user principals are still authorized. Commands with
    /// registered hooks go through the JSON path so hooks see (and may transform) the call.
    @discardableResult
    public func run<C: NibCommand>(_ type: C.Type, _ params: C.Params, principal: Principal = .user,
                                   session: EditorSession? = nil, group: String? = nil) async throws -> C.Output {
        let d = C.descriptor
        let g = group ?? NibID.make().raw
        if hooks.all.contains(where: { $0.matches(d.id) }) {
            let r = try await execute(Invocation(command: d.id, params: try JSONValue.from(params), principal: principal,
                                                 session: session, group: g))
            return try CommandRegistry.decode(C.Output.self, from: r.value)
        }
        if !principal.isUser {
            let json = try JSONValue.from(params)
            try await gateway.authorize(d, params: json, principal: principal, group: g)
        }
        let ctx = CommandContext(bus: self, principal: principal, group: g, depth: 0, dryRun: false,
                                 session: session, commandID: d.id, title: d.title,
                                 readOnly: d.effect == .read && !d.forwardsCalls,
                                 inheritedPolicy: principal.isUser ? nil : gateway.policy(principal))
        return try await C.run(params, ctx)
    }

    /// JSON path used by plugins, AI, the bridge, menus and key commands.
    public func execute(_ inv: Invocation) async throws -> InvocationResult {
        guard inv.depth <= NibLimits.maxNesting else {
            throw NibError.invalid("command nesting deeper than \(NibLimits.maxNesting)")
        }
        guard let entry = registry.entry(inv.command) else {
            if inv.depth > 0 {
                // Nested call into a feature that is disabled or still a stub (fan-out): an optional dependency.
                throw NibError(.unavailable, "command '\(inv.command)' is not installed",
                               hint: "the feature that provides it is disabled or not built yet")
            }
            throw NibError(.notFound, "unknown command '\(inv.command)'", hint: "call commands.list to see available commands")
        }
        let d = entry.descriptor
        if inv.readOnly && d.effect != .read {
            throw NibError(.permissionDenied, "'\(d.id)' changes content but this call is read-only",
                           hint: "ask mode and read commands can only run read commands; switch to Edit mode")
        }
        var params: JSONValue = inv.params == .null ? [:] : inv.params
        let group = inv.group ?? NibID.make().raw
        if !inv.skipHooks {
            for hook in hooks.all where hook.matches(d.id) {
                let r = try await execute(Invocation(command: hook.command, params: ["command": .string(d.id), "params": params],
                                                     principal: hook.principal, session: inv.session, group: group,
                                                     dryRun: inv.dryRun, depth: inv.depth + 1, readOnly: true, skipHooks: true))
                if let replaced = r.value["params"], replaced != .null { params = replaced }
            }
        }
        if !inv.principal.isUser, let error = d.params.validate(params).first {
            throw NibError(error.code, error.message, path: error.path,
                           hint: "call commands.describe {\"id\": \"\(inv.command)\"} for the schema and examples")
        }
        try await gateway.authorize(d, params: params, principal: inv.principal, group: group,
                                    inheritedPolicy: inv.inheritedPolicy)
        let inherited = inv.principal.isUser
            ? inv.inheritedPolicy
            : ConfirmationPolicy.stricter(inv.inheritedPolicy, gateway.policy(inv.principal))
        let ctx = CommandContext(bus: self, principal: inv.principal, group: group, depth: inv.depth, dryRun: inv.dryRun,
                                 session: inv.session, commandID: d.id, title: d.title,
                                 readOnly: inv.readOnly || (d.effect == .read && !d.forwardsCalls),
                                 inheritedPolicy: inherited)
        let value = try await entry.handler(params, ctx)
        return InvocationResult(value: value, changes: ctx.summary, group: group)
    }

    /// Convenience JSON call returning only the value.
    @discardableResult
    public func execute(_ command: String, _ params: JSONValue = [:], principal: Principal = .user,
                        session: EditorSession? = nil) async throws -> JSONValue {
        try await execute(Invocation(command: command, params: params, principal: principal, session: session)).value
    }

    // MARK: Commit + observers

    @discardableResult
    func commit(_ tx: DocTransaction, label: String, command: String, record: Bool) -> Changeset {
        seq += 1
        let cs = Changeset(seq: seq, principal: tx.principal, group: tx.group, label: label, command: command, mutations: tx.mutations)
        if record && !cs.principal.isSync { history.record(cs) }
        finish(cs)
        return cs
    }

    private func finish(_ cs: Changeset) {
        workspace.persist(cs)
        for o in Array(observers.values) { o(cs) }
        for doc in cs.documents {
            events.emit(NibEventType.committed, principal: cs.principal, doc: doc, changes: cs.summary(for: doc))
        }
    }

    /// Synchronous callback for every commit, undo and remote merge (tile invalidation, indexing, collaboration).
    @discardableResult
    public func observeCommits(_ handler: @escaping (Changeset) -> Void) -> EventSubscription {
        let id = UUID()
        observers[id] = handler
        return EventSubscription { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    // MARK: Undo / redo / selective revert

    @discardableResult
    public func undo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popUndo(doc) else { return false }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "undo:" + entry.group)
        _ = tx.revert(entry.mutations)
        history.pushRedo(UndoEntry(group: entry.group, label: entry.label, principal: entry.principal, mutations: tx.mutations), doc: doc)
        finishUnrecorded(tx, label: "Undo " + entry.label, command: CommandIDs.undo)
        return true
    }

    @discardableResult
    public func redo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popRedo(doc) else { return false }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "redo:" + entry.group)
        _ = tx.revert(entry.mutations)
        history.pushUndo(UndoEntry(group: entry.group, label: entry.label, principal: entry.principal, mutations: tx.mutations), doc: doc)
        finishUnrecorded(tx, label: "Redo " + entry.label, command: CommandIDs.redo)
        return true
    }

    /// Reverts one undo group (e.g. an AI turn) even after later edits; records the revert as a new undo step.
    /// Returns nil when the group is not in the history.
    public func revert(group: String, doc: DocumentID, principal: Principal = .user) -> (reverted: Int, skipped: Int)? {
        guard let entry = history.removeEntry(group: group, doc: doc) else { return nil }
        let tx = DocTransaction(workspace: workspace, principal: principal, group: NibID.make().raw)
        let skipped = tx.revert(entry.mutations)
        let n = tx.mutations.count
        if n > 0 { commit(tx, label: "Revert " + entry.label, command: CommandIDs.revertGroup, record: true) }
        return (n, skipped)
    }

    private func finishUnrecorded(_ tx: DocTransaction, label: String, command: String) {
        guard !tx.mutations.isEmpty else { return }
        seq += 1
        finish(Changeset(seq: seq, principal: tx.principal, group: tx.group, label: label, command: command, mutations: tx.mutations))
    }

    // MARK: Remote changes (sync + collaboration only)

    /// Merges records from another device (folder sync) or a collaborator. Not recorded for undo.
    /// The document must be loaded; unloaded documents merge from disk when opened.
    @discardableResult
    public func applyRemote(_ patch: DocumentPatch, origin: String) -> ChangeSummary {
        guard workspace.isLoaded(patch.doc) else { return ChangeSummary() }
        guard let muts = try? workspace.merge(patch), !muts.isEmpty else { return ChangeSummary() }
        seq += 1
        let cs = Changeset(seq: seq, principal: .sync(origin), group: "sync", label: "Sync", command: "sync.merge", mutations: muts)
        finish(cs)
        return cs.summary
    }
}

extension Principal {
    var isSync: Bool {
        if case .sync = self { return true }
        return false
    }
}
