import Foundation

/// Describes a command for the UI, plugins, the AI tool catalogue and MCP.
public struct CommandDescriptor {
    /// "namespace.verb" (built-in) or "<pluginId>.<name>" (plugins). Lower camel case segments.
    public var id: String
    /// UI label, e.g. "Add Page".
    public var title: String
    /// ONE line (≤ 200 chars) written for an LLM: what it does and the key params.
    public var summary: String
    public var params: JSONSchema
    /// Example params. Required for every command exposed to AI; they must validate and should use
    /// `Fixtures` ids (FIXTUREDOC01, FIXTUREPG001, …) so the conformance test can run them.
    public var examples: [JSONValue]
    public var effect: Effect
    public var target: CommandTarget
    public var destructive: Bool
    /// Derived from effect/target/destructive plus `extraScopes`.
    public var scopes: Set<Scope>
    public var exposure: Exposure
    /// "builtin" (contracts), the feature id (stamped by `NibApp.register`) or the plugin id.
    public var owner: String
    /// Shows system UI that needs a human (camera, microphone, file picker, Face ID, print).
    public var userPresence: Bool
    /// `.edit` commands that persist through `ctx.mutate(undoable: false)` (tape reveal, study grading, view flags)
    /// set this to false: conformance then asserts the undo stack is unchanged instead of an undo round trip.
    public var undoable: Bool
    /// Sends data off the device or captures it (WebDAV/backup destinations, collaboration, microphone, calendar,
    /// Photos, AI provider endpoints). Non-user principals are ALWAYS confirmed, whatever their policy.
    public var sensitive: Bool
    /// Runs caller-supplied nested calls that are authorized one by one (`commands.batch`, `ai.ask`). Every other
    /// `read` command runs read-only: its nested calls must be `read` and `ctx.mutate` throws.
    public var forwardsCalls: Bool

    public init(id: String, title: String, summary: String, params: JSONSchema = .empty, examples: [JSONValue] = [],
                effect: Effect, target: CommandTarget = .document, destructive: Bool = false,
                extraScopes: Set<Scope> = [], exposure: Exposure = .all, owner: String = "builtin",
                userPresence: Bool = false, undoable: Bool = true, sensitive: Bool = false, forwardsCalls: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.params = params
        self.examples = examples
        self.effect = effect
        self.target = target
        self.destructive = destructive || effect == .irreversible
        self.exposure = exposure
        self.owner = owner
        self.userPresence = userPresence
        self.undoable = undoable
        self.sensitive = sensitive
        self.forwardsCalls = forwardsCalls
        var s = extraScopes
        switch (effect, target) {
        case (.read, .document): s.insert(.documentRead)
        case (.read, .library): s.insert(.libraryRead)
        case (.read, .app), (.session, _): s.insert(.app)
        case (.edit, .document), (.irreversible, .document): s.insert(.documentWrite)
        case (.edit, .library), (.library, _), (.irreversible, .library): s.insert(.libraryWrite)
        case (.edit, .app), (.irreversible, .app): s.insert(.app)
        }
        if self.destructive { s.insert(.destructive) }
        self.scopes = s
    }

    /// Tool name for LLM APIs ([a-zA-Z0-9_-]{1,64}): dots become double underscores.
    public var toolName: String { id.replacingOccurrences(of: ".", with: "__") }

    public var isMutating: Bool { effect == .edit || effect == .library || effect == .irreversible }
}

/// A native command. Conforming types are main-actor isolated. Return `NoResult()` when there is nothing to return.
/// The result associated type is `Output` (not `Result`) so `Swift.Result` stays usable inside conformers; name
/// your nested result type `Output` too. Keep `examples` literals small: annotate nested literals
/// (`let ex: JSONValue = […]`) or use `try! JSONValue.parse(#"…"#)` for anything longer than one line.
///
///     struct PageRotate: NibCommand {
///         struct Params: Codable { var page: String; var degrees: Int? }
///         static let descriptor = CommandDescriptor(id: "page.rotate", title: "Rotate Page", summary: "…",
///             params: .obj(["page": .ref, "degrees": .int(min: 90, max: 270)], required: ["page"]),
///             examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]], effect: .edit)
///         static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult { … ctx.mutate { tx in … } … }
///     }
@MainActor
public protocol NibCommand {
    associatedtype Params: Codable
    associatedtype Output: Codable
    static var descriptor: CommandDescriptor { get }
    static func run(_ params: Params, _ ctx: CommandContext) async throws -> Output
}

/// Empty params/result. Named `NoResult` (not `Empty`) so it never clashes with `Combine.Empty`.
public struct NoResult: Codable, Equatable {
    public init() {}
}

public typealias CommandHandler = @MainActor (JSONValue, CommandContext) async throws -> JSONValue

/// All commands: built-in, feature and plugin. The command registry IS the app's API.
@MainActor
public final class CommandRegistry {
    public struct Entry {
        public let descriptor: CommandDescriptor
        public let handler: CommandHandler
    }

    private var entries: [String: Entry] = [:]
    /// Set by `NibApp.register` around each feature's `register`: descriptors that still say "builtin" are
    /// stamped with this owner, so `unregister(owner:)`, conformance filtering and provenance work per feature.
    public var defaultOwner: String?
    /// Ids registered twice while features registered (the later one replaced the earlier). Conformance fails on any.
    public private(set) var duplicateIDs: [String] = []

    public init() {}

    public func register<C: NibCommand>(_ type: C.Type) {
        register(C.descriptor) { json, ctx in
            let params = try CommandRegistry.decode(C.Params.self, from: json)
            let result = try await C.run(params, ctx)
            return try JSONValue.from(result)
        }
    }

    /// Registers a JSON-level command (plugins, generated commands).
    public func register(_ descriptor: CommandDescriptor, handler: @escaping CommandHandler) {
        var d = descriptor
        if d.owner == "builtin", let owner = defaultOwner { d.owner = owner }
        if defaultOwner != nil, entries[d.id] != nil { duplicateIDs.append(d.id) }
        entries[d.id] = Entry(descriptor: d, handler: handler)
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(id: String) {
        entries[id] = nil
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(owner: String) {
        entries = entries.filter { $0.value.descriptor.owner != owner }
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func entry(_ id: String) -> Entry? { entries[id] }
    public func descriptor(_ id: String) -> CommandDescriptor? { entries[id]?.descriptor }

    /// Sorted by id; filtered to commands exposed to `exposure` when given.
    public func all(exposedTo exposure: Exposure? = nil) -> [CommandDescriptor] {
        entries.values.map { $0.descriptor }
            .filter { d in exposure.map { d.exposure.contains($0) } ?? true }
            .sorted { $0.id < $1.id }
    }

    /// Decodes params, turning DecodingError into a readable `invalid_params` NibError with a JSON path.
    public nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: JSONValue) throws -> T {
        let value: JSONValue = json == .null ? [:] : json
        do {
            return try value.decode(T.self)
        } catch let e as DecodingError {
            throw NibError.invalid(describe(e))
        }
    }

    nonisolated static func describe(_ e: DecodingError) -> String {
        func path(_ p: [CodingKey]) -> String {
            "$" + p.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined()
        }
        switch e {
        case .keyNotFound(let k, let c): return "missing '\(k.stringValue)' at \(path(c.codingPath))"
        case .typeMismatch(let t, let c): return "wrong type at \(path(c.codingPath)) (expected \(t))"
        case .valueNotFound(let t, let c): return "missing value at \(path(c.codingPath)) (expected \(t))"
        case .dataCorrupted(let c): return "invalid value at \(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "invalid parameters"
        }
    }
}

public extension Notification.Name {
    /// Posted when any command or UI/content registry changes (UI refreshes toolbars/menus).
    static let nibRegistryDidChange = Notification.Name("NibRegistryDidChange")
}
