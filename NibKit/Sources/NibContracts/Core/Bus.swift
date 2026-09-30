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
    /// contracts-v2: a native hook (features only) runs this closure instead of a command: it gets the command id and
    /// params and returns replacement params, nil to let the call pass, or throws to veto it. It must not change
    /// documents. Lets a feature hook `export.run` (layers) or item-creating commands (board limit) without
    /// registering an extra command id. `command` is ignored when set.
    public var handler: (@MainActor (_ command: String, _ params: JSONValue) async throws -> JSONValue?)?
    /// contracts-v2: a native guard that also sees the call: a READ-ONLY `CommandContext` with the caller's principal,
    /// session and group (`ctx.pageOrSession(_:)` resolves session defaults, `ctx.app` / `ctx.content` reach the app;
    /// `ctx.mutate` throws). Same contract as `handler` (replacement params, nil, or throw to veto) and preferred over it.
    /// Runs for every principal and for typed `bus.run` calls. Build with `CommandHookDescriptor.guarding(...)`.
    public var contextHandler: (@MainActor (_ command: String, _ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue?)?

    /// contracts-v2: a native guard hook with the call's context (see `contextHandler`), e.g. a board item limit that
    /// vetoes item-creating commands from any principal.
    public static func guarding(id: String, owner: String, commands: [String], order: Int = 0,
                                _ body: @escaping @MainActor (_ command: String, _ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue?)
        -> CommandHookDescriptor {
        var d = CommandHookDescriptor(id: id, owner: owner, commands: commands, command: "", order: order)
        d.contextHandler = body
        return d
    }

    public init(id: String, owner: String, commands: [String], command: String, principal: Principal = .user, order: Int = 0) {
        self.id = id
        self.order = order
        self.owner = owner
        self.commands = commands
        self.command = command
        self.principal = principal
        self.handler = nil
    }

    /// contracts-v2: a native closure hook (see `handler`).
    public init(id: String, owner: String, commands: [String], order: Int = 0,
                handler: @escaping @MainActor (_ command: String, _ params: JSONValue) async throws -> JSONValue?) {
        self.id = id
        self.order = order
        self.owner = owner
        self.commands = commands
        self.command = ""
        self.principal = .user
        self.handler = handler
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

    // MARK: contracts-v2: typed access to the app

    /// The app this command runs in (nil only for a `CommandBus` built outside `NibApp`). Prefer the typed accessors
    /// below; never reach `NibApp.shared` from a command.
    public var app: NibApp? { bus.app }
    /// Non-UI registries: templates, drawers, importers, exporters, tape patterns, custom item types, key commands…
    public var content: ContentRegistries { bus.content }
    /// UI registries (toolbar, menus, panels, chrome overlays, canvas tools…); nil without an app.
    public var ui: UIRegistries? { bus.app?.ui }
    /// Navigator of the most recently active window (open tabs, show library, present modals); nil when headless.
    public var navigator: SceneNavigator? { bus.app?.ui.activeNavigator }

    /// True when the document must not be written: persistence refuses it (`DocumentPersistence.isReadOnly`, e.g. saved
    /// by a newer Nib) or it is listed in the legacy `ServiceKeys.storeReadOnly` set.
    public func isReadOnly(_ doc: DocumentID) -> Bool {
        if workspace.isReadOnly(doc) { return true }
        return services.get(ServiceKeys.storeReadOnly, as: NSSet.self)?.contains(doc.raw) ?? false
    }

    /// Makes this command's undo group ONE step across documents: undoing (or redoing) it in any of the documents it
    /// changed also undoes it in the others, as long as it is still their latest step (`page.moveTo` between
    /// documents, an AI turn that edits two notebooks).
    public func linkUndoAcrossDocuments() {
        bus.history.link(group)
    }

    // MARK: contracts-v2: session defaults (§6.1)

    /// `ref` as a document id; when it is nil or empty, the invoking session's document (key commands, toolbar
    /// buttons and menus run with static params). Throws `invalid_params` with a hint when neither exists.
    public func documentOrSession(_ ref: String?, field: String = "doc") throws -> DocumentID {
        if let r = ref, !r.isEmpty { return NodeRef.documentID(from: r) }
        guard let doc = activeSession?.document else {
            throw NibError.invalid("missing '\(field)' and no document is open", path: "$." + field)
        }
        return doc
    }

    /// `ref` as a page ("page:D/P"); when it is nil or empty, the invoking session's current page.
    public func pageOrSession(_ ref: String?, field: String = "page") throws -> (doc: DocumentID, page: PageID) {
        if let r = ref, !r.isEmpty {
            guard case let .page(d, p)? = NodeRef(r) else {
                throw NibError.invalid("'\(field)' must be a page ref like page:D/P", path: "$." + field)
            }
            return (d, p)
        }
        guard let s = activeSession, let d = s.document, let p = s.page else {
            throw NibError.invalid("missing '\(field)' and no page is open", path: "$." + field)
        }
        return (d, p)
    }

    /// `refs` when given and non-empty, else the invoking session's selection refs ([] when nothing is selected).
    public func refsOrSelection(_ refs: [String]?) -> [String] {
        if let r = refs, !r.isEmpty { return r }
        return activeSession?.selection.refs ?? []
    }

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
    ///
    /// contracts-v2 (security fix): downloads by non-user principals need `https`, the `network` scope, and — for plugins
    /// whose manifest is known — a host listed in `network.hosts`; plain `http` is user-only. Every download is capped
    /// at `NibLimits.maxDownloadBytes` and lands as `<tmp>/nib-downloads/<UUID>/<original file name>`, so importers can
    /// title documents from `lastPathComponent`. `tmp:` names must be plain file names.
    public func inputFile(_ string: String) async throws -> URL {
        let fm = FileManager.default
        if string.hasPrefix("tmp:") {
            let name = String(string.dropFirst(4))
            guard CommandContext.isPlainFileName(name) else {
                throw NibError(.invalidParams, "invalid temporary asset name '\(name)'",
                               hint: "pass the tmp: ref exactly as asset.upload returned it")
            }
            guard let url = services.assets?.temporaryURL(AssetRef(name)) else {
                throw NibError.notFound("temporary asset \(string)")
            }
            return url
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            throw NibError.invalid("not a URL: \(string)")
        }
        switch scheme {
        case "https", "http":
            try authorizeDownload(url, scheme: scheme)
            return try await CommandContext.download(url)
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

    /// Who may download what (see `inputFile`).
    func authorizeDownload(_ url: URL, scheme: String) throws {
        if principal.isUser { return }
        guard scheme == "https" else {
            throw NibError(.permissionDenied, "only https URLs are accepted from \(principal)",
                           hint: "use an https URL, or upload the bytes with asset.upload and pass the tmp: ref")
        }
        guard bus.gateway.grants(principal).contains(.network) else {
            throw NibError(.permissionDenied, "downloading \(url.host ?? "a URL") needs the 'network' permission",
                           hint: "upload the bytes with asset.upload and pass the tmp: ref")
        }
        if case let .plugin(id) = principal,
           let manifest = services.get(ServiceKeys.pluginHost, as: PluginHosting.self)?.handle(id)?.manifest {
            let host = (url.host ?? "").lowercased()
            let hosts = (manifest.network?.hosts ?? []).map { $0.lowercased() }
            guard hosts.contains(host) else {
                throw NibError(.permissionDenied, "'\(host)' is not in the plugin's network.hosts",
                               hint: "add the host to manifest network.hosts")
            }
        }
    }

    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0")
    }

    /// Downloads `url` (60 s timeout, `NibLimits.maxDownloadBytes` cap) into a fresh temporary folder, keeping its name.
    static func download(_ url: URL) async throws -> URL {
        let fm = FileManager.default
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (tmp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? fm.removeItem(at: tmp)
            throw NibError(.unavailable, "download failed: \(url.absoluteString)")
        }
        let limit = Int64(NibLimits.maxDownloadBytes)
        let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard response.expectedContentLength <= limit, size <= limit else {
            try? fm.removeItem(at: tmp)
            throw NibError(.invalidParams, "the file at \(url.absoluteString) is larger than \(limit / 1_048_576) MB")
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("nib-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let dest = folder.appendingPathComponent(isPlainFileName(name) ? name : "download")
        try fm.moveItem(at: tmp, to: dest)
        return dest
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
    /// contracts-v2: the owning app (set by `NibApp.init`; `CommandContext.app`).
    public internal(set) weak var app: NibApp?
    /// contracts-v2: the app's non-UI registries (`CommandContext.content`); an empty set for a bare bus.
    public internal(set) var content = ContentRegistries()
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
                if let guardBody = hook.contextHandler {
                    let hookContext = CommandContext(bus: self, principal: inv.principal, group: group, depth: inv.depth,
                                                     dryRun: inv.dryRun, session: inv.session, commandID: d.id,
                                                     title: d.title, readOnly: true, inheritedPolicy: inv.inheritedPolicy)
                    if let replaced = try await guardBody(d.id, params, hookContext), replaced != .null { params = replaced }
                    continue
                }
                if let handler = hook.handler {
                    if let replaced = try await handler(d.id, params), replaced != .null { params = replaced }
                    continue
                }
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

    /// Undoes the latest step of `doc` (and, for a group linked across documents, the same group's latest step in
    /// every other document where it is still the latest). Returns false when there is nothing to undo.
    @discardableResult
    public func undo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popUndo(doc) else { return false }
        var entries = [(doc, entry)]
        if entry.linked {
            for other in history.linkedDocuments(entry.group, except: doc, redo: false) {
                if let e = history.popUndo(other) { entries.append((other, e)) }
            }
        }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "undo:" + entry.group)
        for (_, e) in entries { _ = tx.revert(e.mutations) }
        history.rebase(tx.rebase)
        for (d, e) in entries {
            var r = UndoEntry(group: e.group, label: e.label, principal: e.principal,
                              mutations: tx.mutations.filter { $0.document == d })
            r.linked = e.linked
            history.pushRedo(r, doc: d)
        }
        finishUnrecorded(tx, label: "Undo " + entry.label, command: CommandIDs.undo)
        return true
    }

    @discardableResult
    public func redo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popRedo(doc) else { return false }
        var entries = [(doc, entry)]
        if entry.linked {
            for other in history.linkedDocuments(entry.group, except: doc, redo: true) {
                if let e = history.popRedo(other) { entries.append((other, e)) }
            }
        }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "redo:" + entry.group)
        for (_, e) in entries { _ = tx.revert(e.mutations) }
        history.rebase(tx.rebase)
        for (d, e) in entries {
            var r = UndoEntry(group: e.group, label: e.label, principal: e.principal,
                              mutations: tx.mutations.filter { $0.document == d })
            r.linked = e.linked
            history.pushUndo(r, doc: d)
        }
        finishUnrecorded(tx, label: "Redo " + entry.label, command: CommandIDs.redo)
        return true
    }

    /// Reverts one undo group (e.g. an AI turn) even after later edits; records the revert as a new undo step.
    /// Returns nil when the group is not in the history.
    public func revert(group: String, doc: DocumentID, principal: Principal = .user) -> (reverted: Int, skipped: Int)? {
        guard let entry = history.removeEntry(group: group, doc: doc) else { return nil }
        let tx = DocTransaction(workspace: workspace, principal: principal, group: NibID.make().raw)
        let skipped = tx.revert(entry.mutations)
        history.rebase(tx.rebase)
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
