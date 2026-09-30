import Foundation
import ImageIO
import UniformTypeIdentifiers
import NibContracts

/// Settings owned by the agent.
enum AgentSettings {
    /// AI.md §4: the commands offered as their own tools besides the meta-tools (shared with the bridge, which reads
    /// the name untyped). Synced: the choice follows the library.
    static let directTools = SettingKey(NibSettings.aiDirectToolsName, default: NibSettings.defaultAIDirectTools, synced: true)
}

// MARK: - Catalogue

/// The tools one turn offers (AI.md §4), built with NibContracts' `ToolCatalog` so the in-app agent and the bridge
/// describe and map tools the same way.
@MainActor
struct AgentToolbox {
    let tools: [ToolSpec]

    var names: Set<String> { Set(tools.map(\.name)) }
    var isEmpty: Bool { tools.isEmpty }

    /// - `requested` nil: the nine meta-tools plus the direct tools (setting `ai.directTools` + every enabled plugin
    ///   command with `aiDirect: true`). `[]`: no tools. Otherwise exactly the listed meta-tool names and command ids.
    /// - Ask mode (`readOnly`) keeps only `read` direct tools; commands the principal cannot see are left out.
    static func build(registry: CommandRegistry, settings: SettingsStore, pluginHost: PluginHosting?, exposure: Exposure,
                      readOnly: Bool, requested: [String]?, supportsTools: Bool) -> AgentToolbox {
        guard supportsTools else { return AgentToolbox(tools: []) }
        let metaNames = Set(ToolCatalog.metaTools.map(\.name))
        guard let requested = requested else {
            let direct = directCommandIDs(registry: registry, settings: settings, pluginHost: pluginHost)
            return AgentToolbox(tools: unique(ToolCatalog.tools(registry, exposure: exposure, readOnly: readOnly, direct: direct)))
        }
        guard !requested.isEmpty else { return AgentToolbox(tools: []) }
        let metas = ToolCatalog.metaTools.filter { requested.contains($0.name) }
        let ids = requested.filter { !metaNames.contains($0) }.map { commandID(forTool: $0, registry: registry) }
        let direct = ToolCatalog.tools(registry, exposure: exposure, readOnly: readOnly, direct: ids)
            .filter { !metaNames.contains($0.name) }
        return AgentToolbox(tools: unique(metas + direct))
    }

    /// The setting's command ids (unset = the AI.md default) followed by enabled plugins' `aiDirect` commands.
    static func directCommandIDs(registry: CommandRegistry, settings: SettingsStore, pluginHost: PluginHosting?) -> [String] {
        var ids = settings.get(AgentSettings.directTools)
        if let host = pluginHost {
            for info in host.installed where info.enabled && !info.needsReview {
                guard let commands = host.handle(info.id)?.manifest.contributes?.commands else { continue }
                ids += commands.filter { $0.aiDirect == true }.map(\.id)
            }
        }
        var seen = Set<String>()
        return ids.filter { registry.descriptor($0) != nil && seen.insert($0).inserted }
    }

    /// Accepts a tool name ("diagram__create") where a command id is expected.
    static func commandID(forTool name: String, registry: CommandRegistry) -> String {
        if registry.descriptor(name) != nil || !name.contains("__") { return name }
        let id = name.replacingOccurrences(of: "__", with: ".")
        return registry.descriptor(id) != nil ? id : name
    }

    private static func unique(_ tools: [ToolSpec]) -> [ToolSpec] {
        var seen = Set<String>()
        return tools.filter { seen.insert($0.name).inserted }
    }
}

// MARK: - Running tool calls

/// What one tool call gave the model.
struct ToolOutcome {
    var parts: [ChatPart]
    var isError: Bool
    var changes: ChangeSummary
    /// The command the call ran (nil for paging and refused calls).
    var command: String?

    static func error(_ e: NibError, command: String? = nil) -> ToolOutcome {
        ToolOutcome(parts: [.text(e.json.jsonString())], isError: true, changes: ChangeSummary(), command: command)
    }
}

/// Runs a turn's tool calls through the command bus as the turn's principal, in the turn's undo group, read-only in
/// Ask mode. Every failure becomes a tool result (`{"error": {code, message, path?, hint?}}`, `isError`) so the model
/// can correct itself; results over 20 KB are paged with a cursor.
@MainActor
final class AgentToolRunner {
    struct Setup {
        var principal: Principal
        var group: String
        var readOnly: Bool
        var session: EditorSession?
        var depth: Int
        var inheritedPolicy: ConfirmationPolicy?
        /// The model accepts images (`AIProviderConfig.supportsVision`).
        var vision: Bool
        /// Seconds per tool call, confirmation wait included (AI.md §6).
        var timeout: TimeInterval
    }

    static let maxImageEdge = 1568

    let bus: CommandBus
    let toolbox: AgentToolbox
    let setup: Setup
    let pager: ResultPager

    init(bus: CommandBus, toolbox: AgentToolbox, setup: Setup, pageBytes: Int = NibLimits.aiToolResultBytes) {
        self.bus = bus
        self.toolbox = toolbox
        self.setup = setup
        self.pager = ResultPager(limit: pageBytes)
    }

    func run(name: String, arguments: JSONValue) async -> ToolOutcome {
        guard toolbox.names.contains(name) else {
            let available = toolbox.tools.map(\.name).joined(separator: ", ")
            return .error(NibError(.notFound, "unknown tool '\(name)'",
                                   hint: available.isEmpty ? "no tools are available in this conversation" : "use one of: \(available)"))
        }
        let args: JSONValue
        switch arguments {
        case .null: args = [:]
        case .object: args = arguments
        default:
            return .error(NibError(.invalidParams, "the arguments of '\(name)' must be a JSON object", path: "$",
                                   hint: "send the arguments as an object that matches the tool's schema"))
        }
        if let cursor = args["cursor"]?.stringValue, ResultPager.isCursor(cursor) {
            do {
                let page = try pager.next(cursor)
                return ToolOutcome(parts: [.text(page.jsonString())], isError: false, changes: ChangeSummary())
            } catch {
                return .error(NibError.wrap(error))
            }
        }
        if name == "nib_run", let problem = AgentToolRunner.checkRun(args) { return .error(problem) }
        if name == "nib_render" { return await render(args) }
        guard var inv = ToolCatalog.invocation(tool: name, arguments: args, registry: bus.registry,
                                               principal: setup.principal, group: setup.group,
                                               readOnly: setup.readOnly, session: setup.session) else {
            return .error(NibError(.notFound, "unknown tool '\(name)'"))
        }
        inv.depth = setup.depth
        inv.inheritedPolicy = setup.inheritedPolicy
        do {
            let r = try await execute(inv)
            return ToolOutcome(parts: [.text(format(r, tool: name, dryRun: inv.dryRun).jsonString())],
                               isError: AgentToolRunner.batchFailedEntirely(r, command: inv.command),
                               changes: inv.dryRun ? ChangeSummary() : r.changes, command: inv.command)
        } catch {
            return .error(NibError.wrap(error), command: inv.command)
        }
    }

    // MARK: Execution

    private func execute(_ inv: Invocation) async throws -> InvocationResult {
        let bus = self.bus
        let seconds = setup.timeout
        return try await Deadline.run(seconds: seconds, timeout: {
            NibError(.timeout, "'\(inv.command)' did not finish within \(Int(seconds)) s",
                     hint: "it may still finish; check the result with nib_get before trying again")
        }) {
            try await bus.execute(inv)
        }
    }

    private func invocation(_ command: String, _ params: JSONValue) -> Invocation {
        Invocation(command: command, params: params, principal: setup.principal, session: setup.session,
                   group: setup.group, depth: setup.depth, readOnly: setup.readOnly, inheritedPolicy: setup.inheritedPolicy)
    }

    /// `nib_run` needs a command or a list of calls.
    static func checkRun(_ args: JSONValue) -> NibError? {
        if let calls = args["calls"] {
            guard let list = calls.arrayValue, !list.isEmpty else {
                return NibError(.invalidParams, "'calls' must be a non-empty array of {command, params}", path: "$.calls",
                                hint: #"e.g. {"calls":[{"command":"page.add","params":{"doc":"doc:D","position":"end"}}]}"#)
            }
            for (i, call) in list.enumerated() where (call["command"]?.stringValue ?? "").isEmpty {
                return NibError(.invalidParams, "call \(i) has no 'command'", path: "$.calls[\(i)].command",
                                hint: "every call is {\"command\": id, \"params\": {…}}; list ids with nib_commands")
            }
            return nil
        }
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            return NibError(.invalidParams, "nib_run needs {command, params} or {calls: [{command, params}]}", path: "$.command",
                            hint: "list command ids with nib_commands and read one with nib_command_schema")
        }
        if let p = args["params"], p != .null, p.objectValue == nil {
            return NibError(.invalidParams, "'params' must be an object", path: "$.params",
                            hint: "call nib_command_schema {\"id\": \"\(command)\"} for the schema")
        }
        return nil
    }

    // MARK: Results

    /// The command's value plus `{"changes": …}` for mutations (and `dryRun: true` for previews), paged over 20 KB.
    func format(_ r: InvocationResult, tool: String, dryRun: Bool) -> JSONValue {
        var value = r.value
        if tool == "nib_commands" && setup.readOnly { value = AgentToolRunner.readOnlyListing(value) }
        var extra: [String: JSONValue] = [:]
        if !r.changes.isEmpty, let changes = try? JSONValue.from(r.changes) { extra["changes"] = changes }
        if dryRun {
            extra["dryRun"] = true
            extra["note"] = "preview only: nothing was changed"
        }
        if !extra.isEmpty {
            if case .object(var o) = value {
                for (k, v) in extra { o[k] = v }
                value = .object(o)
            } else {
                extra["value"] = value
                value = .object(extra)
            }
        }
        return pager.fit(value)
    }

    /// Ask mode lists only what can run: read commands.
    static func readOnlyListing(_ value: JSONValue) -> JSONValue {
        guard case .object(var o) = value, let rows = o["commands"]?.arrayValue else { return value }
        o["commands"] = .array(rows.filter { $0["effect"]?.stringValue == Effect.read.rawValue })
        o["note"] = "Ask mode: only read commands are listed; the user can switch to Edit mode for changes."
        return .object(o)
    }

    /// A batch in which every call failed changed nothing: report it as an error so the model retries.
    static func batchFailedEntirely(_ r: InvocationResult, command: String) -> Bool {
        guard command == CommandIDs.batch, let results = r.value["results"]?.arrayValue, !results.isEmpty else { return false }
        return results.allSatisfy { $0["ok"]?.boolValue == false }
    }

    // MARK: nib_render

    /// `render.page` → an image part (PNG, long edge ≤ 1568 px) plus the pixel ↔ point mapping and marks. Models
    /// without vision, and devices without the renderer, get the page's recognised text instead.
    private func render(_ args: JSONValue) async -> ToolOutcome {
        guard setup.vision else {
            return await pageText(args, note: "This model cannot see images, so here is the page's recognised text instead.")
        }
        guard bus.registry.entry(CommandIDs.renderPage) != nil else {
            return await pageText(args, note: "Rendering is not available here, so here is the page's recognised text instead.")
        }
        guard let inv = ToolCatalog.invocation(tool: "nib_render", arguments: args, registry: bus.registry,
                                               principal: setup.principal, group: setup.group,
                                               readOnly: setup.readOnly, session: setup.session) else {
            return .error(NibError(.notFound, "unknown tool 'nib_render'"))
        }
        var call = inv
        call.depth = setup.depth
        call.inheritedPolicy = setup.inheritedPolicy
        let result: InvocationResult
        do {
            result = try await execute(call)
        } catch let e as NibError where e.code == .unavailable {
            return await pageText(args, note: "Rendering is not available here, so here is the page's recognised text instead.")
        } catch {
            return .error(NibError.wrap(error), command: call.command)
        }
        var mapping = result.value
        guard let asset = result.value["asset"]?.stringValue, asset.hasPrefix("tmp:"),
              let url = bus.services.assets?.temporaryURL(AssetRef(String(asset.dropFirst(4)))) else {
            return ToolOutcome(parts: [.text(mapping.jsonString())], isError: false, changes: ChangeSummary(), command: call.command)
        }
        let maxEdge = AgentToolRunner.maxImageEdge
        let fitted = await Task.detached(priority: .userInitiated) { () -> ImageFit.Result? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageFit.png(data, maxEdge: maxEdge)
        }.value
        guard let image = fitted else {
            return .error(NibError(.internalError, "the rendered image could not be read", hint: "try nib_page_text instead"),
                          command: call.command)
        }
        if case .object(var o) = mapping {
            if image.scale != 1, let px = o["pxPerPt"]?.doubleValue { o["pxPerPt"] = .number(px * image.scale) }
            o["imageSize"] = [.number(Double(image.width)), .number(Double(image.height))]
            o["note"] = "page point = [region[0] + x / pxPerPt, region[1] + y / pxPerPt] for image pixel [x, y]"
            mapping = .object(o)
        }
        return ToolOutcome(parts: [.text(mapping.jsonString()), .image(data: image.data, mime: "image/png")],
                           isError: false, changes: ChangeSummary(), command: call.command)
    }

    /// `recognize.pageText` for `args.page`, with a note saying why the model gets text.
    private func pageText(_ args: JSONValue, note: String) async -> ToolOutcome {
        let page = args["page"] ?? .null
        do {
            let r = try await execute(invocation(CommandIDs.recognizePageText, ["page": page]))
            var value: JSONValue = ["note": .string(note)]
            if case .object(var o) = r.value {
                o["note"] = .string(note)
                value = .object(o)
            } else {
                value = ["note": .string(note), "blocks": r.value]
            }
            return ToolOutcome(parts: [.text(pager.fit(value).jsonString())], isError: false, changes: ChangeSummary(),
                               command: CommandIDs.recognizePageText)
        } catch {
            return .error(NibError.wrap(error), command: CommandIDs.recognizePageText)
        }
    }
}

// MARK: - Paging results over 20 KB

/// Cuts results over `limit` bytes (AI.md §4). Lists are cut between elements so every page is valid JSON
/// (`{…, "<key>": [first rows], "truncated": true, "cursor": …}`); anything else is cut as text. The model calls the
/// same tool with `{"cursor": …}` for the next page. Pages live as long as the turn.
@MainActor
final class ResultPager {
    static let prefix = "nibagent:"
    static let maxStored = 16

    private enum Stored {
        /// `base` (the object around the list, nil when the result is a bare list), the list's key and its elements.
        case items(base: [String: JSONValue]?, key: String, items: [JSONValue])
        case text(String)
    }

    let limit: Int
    private var stored: [String: Stored] = [:]
    private var order: [String] = []

    init(limit: Int = NibLimits.aiToolResultBytes) {
        self.limit = limit
    }

    static func isCursor(_ s: String) -> Bool { s.hasPrefix(prefix) }

    /// `value` itself when it fits, else its first page.
    func fit(_ value: JSONValue) -> JSONValue {
        if ResultPager.size(value) <= limit { return value }
        let id = NibID.make().raw
        if let (base, key, items) = splittable(value) {
            let entry = Stored.items(base: base, key: key, items: items)
            if let page = itemsPage(id: id, base: base, key: key, items: items, from: 0) {
                remember(id, entry)
                return page
            }
        }
        let text = value.jsonString()
        remember(id, .text(text))
        return textPage(id: id, text: text, from: 0)
    }

    /// The page a cursor points at.
    func next(_ cursor: String) throws -> JSONValue {
        let rest = cursor.dropFirst(ResultPager.prefix.count).split(separator: ":")
        guard rest.count == 2, let entry = stored[String(rest[0])], let offset = Int(rest[1]), offset > 0 else {
            throw NibError(.notFound, "result cursor '\(cursor)' is unknown or expired",
                           hint: "call the tool again without the cursor")
        }
        let id = String(rest[0])
        switch entry {
        case let .items(base, key, items):
            guard offset < items.count,
                  let page = itemsPage(id: id, base: base, key: key, items: items, from: offset, oversizeFirst: true) else {
                throw NibError(.invalidParams, "result cursor '\(cursor)' is out of range", path: "$.cursor")
            }
            return page
        case .text(let text):
            guard offset < text.utf8.count else {
                throw NibError(.invalidParams, "result cursor '\(cursor)' is out of range", path: "$.cursor")
            }
            return textPage(id: id, text: text, from: offset)
        }
    }

    private func remember(_ id: String, _ entry: Stored) {
        stored[id] = entry
        order.append(id)
        while order.count > ResultPager.maxStored { stored[order.removeFirst()] = nil }
    }

    /// The list to page: the value itself, or the largest list in an object whose other fields are small.
    private func splittable(_ value: JSONValue) -> ([String: JSONValue]?, String, [JSONValue])? {
        switch value {
        case .array(let a) where a.count > 1:
            return (nil, "items", a)
        case .object(let o):
            let lists = o.compactMap { k, v -> (String, [JSONValue], Int)? in
                guard case .array(let a) = v, a.count > 1 else { return nil }
                return (k, a, ResultPager.size(v))
            }
            guard let (key, items, _) = lists.max(by: { $0.2 < $1.2 }) else { return nil }
            var base = o
            base[key] = nil
            guard ResultPager.size(.object(base)) < limit / 2 else { return nil }
            return (base, key, items)
        default:
            return nil
        }
    }

    /// Elements from `start` that fit; nil when not even one does, unless `oversizeFirst` (later pages always progress).
    private func itemsPage(id: String, base: [String: JSONValue]?, key: String, items: [JSONValue], from start: Int,
                           oversizeFirst: Bool = false) -> JSONValue? {
        var frame = base ?? [:]
        frame[key] = []
        frame["truncated"] = true
        frame["cursor"] = .string(ResultPager.prefix + id + ":" + String(items.count))
        frame["shown"] = .string("\(items.count)–\(items.count) of \(items.count)")
        frame["hint"] = "call the same tool with this cursor for the next part"
        var budget = limit - ResultPager.size(.object(frame)) - 16
        var end = start
        while end < items.count {
            let s = ResultPager.size(items[end]) + 1
            if s > budget { break }
            budget -= s
            end += 1
        }
        if end == start {
            guard oversizeFirst else { return nil }
            end = start + 1
        }
        var page = base ?? [:]
        page[key] = .array(Array(items[start..<end]))
        page["shown"] = .string("\(start + 1)–\(end) of \(items.count)")
        if end < items.count {
            page["truncated"] = true
            page["cursor"] = .string(ResultPager.prefix + id + ":" + String(end))
            page["hint"] = "call the same tool with this cursor for the next part"
        }
        return .object(page)
    }

    private func textPage(id: String, text: String, from offset: Int) -> JSONValue {
        let bytes = Array(text.utf8)
        var chunk = max(256, (limit - 400) * 2 / 3)
        while true {
            var end = min(bytes.count, offset + chunk)
            while end < bytes.count, end > offset, bytes[end] & 0xC0 == 0x80 { end -= 1 }   // UTF-8 boundary
            var page: [String: JSONValue] = [
                "part": .string(String(decoding: bytes[offset..<end], as: UTF8.self)),
                "offset": .number(Double(offset)), "total": .number(Double(bytes.count)),
                "note": "the result is JSON text split into parts; join the parts in order"
            ]
            if end < bytes.count {
                page["truncated"] = true
                page["cursor"] = .string(ResultPager.prefix + id + ":" + String(end))
                page["hint"] = "call the same tool with this cursor for the next part"
            }
            let value = JSONValue.object(page)
            if ResultPager.size(value) <= limit || chunk <= 256 { return value }
            chunk = chunk * 3 / 4
        }
    }

    static func size(_ value: JSONValue) -> Int { value.jsonString().utf8.count }
}

// MARK: - Time limits

/// Runs `body` with a time limit. On timeout the caller gets `timeout()` at once; the body keeps running to its end
/// (commands cannot be interrupted safely) and its result is dropped.
@MainActor
enum Deadline {
    private final class Race {
        var done = false
        var timer: Task<Void, Never>?
    }

    static func run<T>(seconds: TimeInterval, timeout: @escaping @MainActor () -> NibError,
                       _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let race = Race()
            let work = Task { @MainActor in
                do {
                    let value = try await body()
                    guard !race.done else { return }
                    race.done = true
                    race.timer?.cancel()
                    continuation.resume(returning: value)
                } catch {
                    guard !race.done else { return }
                    race.done = true
                    race.timer?.cancel()
                    continuation.resume(throwing: error)
                }
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled, !race.done else { return }
                race.done = true
                work.cancel()
                continuation.resume(throwing: timeout())
            }
        }
    }
}

// MARK: - Images

/// Re-encodes an image as a PNG whose long edge is at most `maxEdge` pixels (thread-safe; ImageIO only).
enum ImageFit {
    struct Result {
        var data: Data
        var width: Int
        var height: Int
        /// New size / original size (1 = unchanged).
        var scale: Double
    }

    static func png(_ data: Data, maxEdge: Int) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        let longEdge = max(width, height)
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        if longEdge <= maxEdge && isPNG { return Result(data: data, width: width, height: height, scale: 1) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(maxEdge, longEdge)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Result(data: out as Data, width: image.width, height: image.height,
                      scale: Double(max(image.width, image.height)) / Double(longEdge))
    }
}
