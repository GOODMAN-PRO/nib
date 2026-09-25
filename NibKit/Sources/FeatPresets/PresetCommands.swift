import Foundation
import NibContracts

// MARK: - Rules

/// What `preset.setSwatch` does to a tape slot's pattern: omitted keeps it, "" removes it, an id sets it.
enum PatternChange: Equatable {
    case keep
    case clear
    case set(AssetRef)

    init(_ raw: String?) {
        guard let raw else {
            self = .keep
            return
        }
        let id = raw.trimmingCharacters(in: .whitespaces)
        self = id.isEmpty ? .clear : .set(AssetRef(id))
    }
}

/// The preset rules every `preset.*` command and the tool menu go through, so the bounds live in one place. Pure: the
/// commands read and write `NibSettings.presets(tool)` around these functions.
enum PresetRules {
    static let tools = NibSettings.presetTools
    static let widthSlots = 3
    /// Tools whose thickness slots carry a line pattern (solid, dashed, dotted).
    static let patternTools: Set<String> = ["pen", "pencil"]

    static func key(_ tool: String) -> SettingKey<ToolPresets> { NibSettings.presets(tool) }

    /// Thickness bounds in points (1/72 in) per tool.
    static func widthRange(_ tool: String) -> ClosedRange<Double> {
        switch tool {
        case "highlighter": return 2...40
        case "tape": return 4...60
        case "shape", "drawShape": return 0.25...20
        default: return 0.1...10
        }
    }

    /// Highlighter colours given without alpha take the default highlighter opacity (they render beneath ink).
    static var highlighterAlpha: UInt8 { ToolPresets.defaults(for: "highlighter").swatches.first?.color.a ?? 128 }

    static func toolSchema(allowCurrent: Bool = false) -> JSONSchema {
        let choices = allowCurrent ? tools + ["current"] : tools
        let what = allowCurrent ? "tool with presets, or 'current' for the active tool" : "tool with presets"
        return .str(what, choices: choices)
    }

    static func checkTool(_ tool: String) throws {
        guard tools.contains(tool) else {
            throw NibError(.invalidParams, "'\(tool)' has no presets; tools with presets: \(tools.joined(separator: ", "))",
                           path: "$.tool", hint: "pass one of \(tools.joined(separator: ", "))")
        }
    }

    /// Repairs state synced from another device or written with `settings.set`: 1…12 colour slots, exactly three
    /// thickness slots inside the tool's bounds, one line pattern per thickness slot, selections in range.
    static func normalized(_ presets: ToolPresets, tool: String) -> ToolPresets {
        let defaults = ToolPresets.defaults(for: tool)
        var p = presets
        if p.swatches.isEmpty { p.swatches = defaults.swatches }
        if p.swatches.count > ToolPresets.maxSwatches { p.swatches = Array(p.swatches.prefix(ToolPresets.maxSwatches)) }
        let range = widthRange(tool)
        var widths = Array(p.widths.prefix(widthSlots))
        while widths.count < widthSlots { widths.append(defaults.widths[widths.count]) }
        p.widths = widths.enumerated().map { i, w in
            w.isFinite ? min(max(w, range.lowerBound), range.upperBound) : defaults.widths[i]
        }
        var patterns = Array(p.patterns.prefix(widthSlots))
        while patterns.count < widthSlots { patterns.append(.solid) }
        p.patterns = patterns
        p.selectedSwatch = min(max(p.selectedSwatch, 0), p.swatches.count - 1)
        p.selectedWidth = min(max(p.selectedWidth, 0), widthSlots - 1)
        return p
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA". A highlighter colour given without alpha gets the highlighter opacity.
    static func colour(_ hex: String, tool: String, path: String = "$.color") throws -> RGBA {
        guard let c = RGBA(hex: hex) else {
            throw NibError(.invalidParams, "'\(hex)' is not a colour; expected #RRGGBB or #RRGGBBAA", path: path)
        }
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        return tool == "highlighter" && digits.count == 6 ? RGBA(c.r, c.g, c.b, highlighterAlpha) : c
    }

    private static func check(_ index: Int, _ count: Int, _ path: String, _ what: String) throws {
        guard index >= 0 && index < count else {
            throw NibError(.invalidParams, "\(what) \(index) is out of range 0…\(count - 1)", path: path,
                           hint: "call settings.get {\"name\": \"presets.<tool>\"} to see the slots")
        }
    }

    static func select(_ p: ToolPresets, swatch: Int?, width: Int?, widthStep: Int?) throws -> ToolPresets {
        guard swatch != nil || width != nil || widthStep != nil else {
            throw NibError(.invalidParams, "give swatch, width or widthStep", path: "$.swatch")
        }
        var p = p
        if let s = swatch {
            try check(s, p.swatches.count, "$.swatch", "colour slot")
            p.selectedSwatch = s
        }
        if let w = width {
            try check(w, widthSlots, "$.width", "thickness slot")
            p.selectedWidth = w
        }
        if let step = widthStep {
            guard (-1...1).contains(step) else {
                throw NibError(.invalidParams, "widthStep must be -1 or 1", path: "$.widthStep")
            }
            p.selectedWidth = min(max(p.selectedWidth + step, 0), widthSlots - 1)
        }
        return p
    }

    static func setSwatch(_ p: ToolPresets, tool: String, index: Int, color: RGBA, pattern: PatternChange) throws -> ToolPresets {
        try check(index, p.swatches.count, "$.index", "colour slot")
        var p = p
        p.swatches[index].color = color
        switch pattern {
        case .keep:
            break
        case .clear:
            p.swatches[index].pattern = nil
        case .set(let ref):
            guard tool == "tape" else {
                throw NibError(.invalidParams, "patterns apply to tape slots only", path: "$.pattern")
            }
            p.swatches[index].pattern = ref
        }
        return p
    }

    static func addSwatch(_ p: ToolPresets, color: RGBA) throws -> ToolPresets {
        guard p.swatches.count < ToolPresets.maxSwatches else {
            throw NibError(.invalidParams, "a tool has at most \(ToolPresets.maxSwatches) colour slots", path: "$.tool",
                           hint: "remove one first with preset.removeSwatch")
        }
        var p = p
        p.swatches.append(PresetSwatch(color: color))
        p.selectedSwatch = p.swatches.count - 1
        return p
    }

    static func removeSwatch(_ p: ToolPresets, index: Int) throws -> ToolPresets {
        try check(index, p.swatches.count, "$.index", "colour slot")
        guard p.swatches.count > 1 else {
            throw NibError(.invalidParams, "a tool keeps at least one colour slot", path: "$.index",
                           hint: "change its colour with preset.setSwatch instead")
        }
        var p = p
        p.swatches.remove(at: index)
        if index < p.selectedSwatch {
            p.selectedSwatch -= 1
        } else if index == p.selectedSwatch {
            p.selectedSwatch = min(p.selectedSwatch, p.swatches.count - 1)
        }
        return p
    }

    /// Moves a slot; the selection stays on the swatch it was on.
    static func moveSwatch(_ p: ToolPresets, from: Int, to: Int) throws -> ToolPresets {
        try check(from, p.swatches.count, "$.from", "colour slot")
        try check(to, p.swatches.count, "$.to", "colour slot")
        guard from != to else { return p }
        var p = p
        let moved = p.swatches.remove(at: from)
        p.swatches.insert(moved, at: to)
        let s = p.selectedSwatch
        if s == from {
            p.selectedSwatch = to
        } else if from < s && to >= s {
            p.selectedSwatch = s - 1
        } else if from > s && to <= s {
            p.selectedSwatch = s + 1
        }
        return p
    }

    static func setWidth(_ p: ToolPresets, tool: String, index: Int, width: Double, pattern: StrokePattern?) throws -> ToolPresets {
        try check(index, widthSlots, "$.index", "thickness slot")
        let range = widthRange(tool)
        guard width.isFinite, range.contains(width) else {
            throw NibError(.invalidParams, "the \(tool) thickness must be \(range.lowerBound)…\(range.upperBound) pt",
                           path: "$.width")
        }
        if let pattern, pattern != .solid, !patternTools.contains(tool) {
            throw NibError(.invalidParams, "dashed and dotted lines apply to the pen and pencil only", path: "$.pattern")
        }
        var p = p
        p.widths[index] = (width * 100).rounded() / 100
        if let pattern { p.patterns[index] = pattern }
        return p
    }

    /// Reads, changes and writes a tool's presets (normalised on both sides; nothing is written when nothing changed).
    static func update(_ tool: String, in settings: SettingsStore,
                       _ change: (ToolPresets) throws -> ToolPresets) throws -> ToolPresets {
        let setting = PresetRules.key(tool)
        let current = normalized(settings.get(setting), tool: tool)
        let changed = try change(current)
        let next = normalized(changed, tool: tool)
        if next != current { settings.set(setting, next) }
        return next
    }
}

/// What every preset command returns: the tool and its presets after the change. `applied` is false only when
/// `preset.select` targets the active tool and that tool has no presets (a keyboard shortcut over the eraser).
struct PresetOutput: Codable {
    var tool: String
    var applied: Bool
    var presets: ToolPresets?
}

// MARK: - Commands

struct PresetSelect: NibCommand {
    struct Params: Codable {
        var tool: String
        var swatch: Int?
        var width: Int?
        var widthStep: Int?
    }
    static let descriptor = CommandDescriptor(
        id: "preset.select", title: "Select Preset",
        summary: "Choose a tool's active colour slot (swatch, 0-based) and/or thickness slot (width 0-2); tool 'current' means the active tool.",
        params: .obj(["tool": PresetRules.toolSchema(allowCurrent: true),
                      "swatch": .int("colour slot, 0-based", min: 0, max: 11),
                      "width": .int("thickness slot, 0-based", min: 0, max: 2),
                      "widthStep": .int("-1 or 1: the previous or next thickness slot", min: -1, max: 1)],
                     required: ["tool"]),
        examples: [["tool": "pen", "swatch": 1], ["tool": "highlighter", "width": 2]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        var tool = p.tool
        if tool == "current" {
            // Keyboard shortcuts: a key with nothing behind it (the eraser is active, colour 9 of 3) does nothing.
            let active = ctx.activeSession?.tool ?? ""
            guard PresetRules.tools.contains(active) else { return PresetOutput(tool: active, applied: false, presets: nil) }
            tool = active
            let count = PresetRules.normalized(ctx.services.settings.get(PresetRules.key(tool)), tool: tool).swatches.count
            if let s = p.swatch, s >= count { return PresetOutput(tool: tool, applied: false, presets: nil) }
        }
        try PresetRules.checkTool(tool)
        let next = try PresetRules.update(tool, in: ctx.services.settings) {
            try PresetRules.select($0, swatch: p.swatch, width: p.width, widthStep: p.widthStep)
        }
        return PresetOutput(tool: tool, applied: true, presets: next)
    }
}

struct PresetSetSwatch: NibCommand {
    struct Params: Codable {
        var tool: String
        var index: Int
        var color: String
        var pattern: String?
    }
    static let descriptor = CommandDescriptor(
        id: "preset.setSwatch", title: "Change Colour Preset",
        summary: "Change one colour slot of a tool (#RRGGBB[AA]); tape slots also take a pattern id from tape.patterns ('' removes it).",
        params: .obj(["tool": PresetRules.toolSchema(),
                      "index": .int("colour slot, 0-based", min: 0, max: 11),
                      "color": .color,
                      "pattern": .str("tape only: pattern id from tape.patterns; '' removes the pattern; omit to keep it")],
                     required: ["tool", "index", "color"]),
        examples: [["tool": "pen", "index": 0, "color": "#2156D9"], ["tool": "highlighter", "index": 1, "color": "#86E3AE"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        try PresetRules.checkTool(p.tool)
        let colour = try PresetRules.colour(p.color, tool: p.tool)
        let change = PatternChange(p.pattern)
        if case .set(let ref) = change, p.tool == "tape",
           let patterns = NibApp.shared?.content.tapePatterns, patterns.get(ref.name) == nil {
            throw NibError(.notFound, "tape pattern '\(ref.name)' not found", path: "$.pattern",
                           hint: "call tape.patterns for the available pattern ids")
        }
        let next = try PresetRules.update(p.tool, in: ctx.services.settings) {
            try PresetRules.setSwatch($0, tool: p.tool, index: p.index, color: colour, pattern: change)
        }
        return PresetOutput(tool: p.tool, applied: true, presets: next)
    }
}

struct PresetAddSwatch: NibCommand {
    struct Params: Codable {
        var tool: String
        var color: String
    }
    static let descriptor = CommandDescriptor(
        id: "preset.addSwatch", title: "Add Colour Preset",
        summary: "Add a colour slot (#RRGGBB[AA]) to a tool and select it; a tool has at most 12 colour slots.",
        params: .obj(["tool": PresetRules.toolSchema(), "color": .color], required: ["tool", "color"]),
        examples: [["tool": "pen", "color": "#2F7A3C"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        try PresetRules.checkTool(p.tool)
        let colour = try PresetRules.colour(p.color, tool: p.tool)
        let next = try PresetRules.update(p.tool, in: ctx.services.settings) { try PresetRules.addSwatch($0, color: colour) }
        return PresetOutput(tool: p.tool, applied: true, presets: next)
    }
}

struct PresetRemoveSwatch: NibCommand {
    struct Params: Codable {
        var tool: String
        var index: Int
    }
    static let descriptor = CommandDescriptor(
        id: "preset.removeSwatch", title: "Remove Colour Preset",
        summary: "Remove one colour slot (0-based index) from a tool; a tool keeps at least one.",
        params: .obj(["tool": PresetRules.toolSchema(), "index": .int("colour slot, 0-based", min: 0, max: 11)],
                     required: ["tool", "index"]),
        examples: [["tool": "pen", "index": 2]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        try PresetRules.checkTool(p.tool)
        let next = try PresetRules.update(p.tool, in: ctx.services.settings) { try PresetRules.removeSwatch($0, index: p.index) }
        return PresetOutput(tool: p.tool, applied: true, presets: next)
    }
}

struct PresetMoveSwatch: NibCommand {
    struct Params: Codable {
        var tool: String
        var from: Int
        var to: Int
    }
    static let descriptor = CommandDescriptor(
        id: "preset.moveSwatch", title: "Move Colour Preset",
        summary: "Reorder a tool's colour slots: move the slot at index 'from' to index 'to' (0-based); the selection follows it.",
        params: .obj(["tool": PresetRules.toolSchema(),
                      "from": .int("current slot, 0-based", min: 0, max: 11),
                      "to": .int("new slot, 0-based", min: 0, max: 11)],
                     required: ["tool", "from", "to"]),
        examples: [["tool": "pen", "from": 2, "to": 0]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        try PresetRules.checkTool(p.tool)
        let next = try PresetRules.update(p.tool, in: ctx.services.settings) {
            try PresetRules.moveSwatch($0, from: p.from, to: p.to)
        }
        return PresetOutput(tool: p.tool, applied: true, presets: next)
    }
}

struct PresetSetWidth: NibCommand {
    struct Params: Codable {
        var tool: String
        var index: Int
        var width: Double
        var pattern: StrokePattern?
    }
    static let descriptor = CommandDescriptor(
        id: "preset.setWidth", title: "Change Thickness Preset",
        summary: "Set one of a tool's three thickness slots in points (1/72 in) and its line pattern (dashed and dotted: pen and pencil only).",
        params: .obj(["tool": PresetRules.toolSchema(),
                      "index": .int("thickness slot, 0-based", min: 0, max: 2),
                      "width": .num("points: pen and pencil 0.1-10, highlighter 2-40, tape 4-60, shape and drawShape 0.25-20",
                                    min: 0.1, max: 60),
                      "pattern": .str("line pattern", choices: StrokePattern.allCases.map { $0.rawValue })],
                     required: ["tool", "index", "width"]),
        examples: [["tool": "pen", "index": 1, "width": 1.4, "pattern": "dashed"], ["tool": "highlighter", "index": 0, "width": 10]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        try PresetRules.checkTool(p.tool)
        let next = try PresetRules.update(p.tool, in: ctx.services.settings) {
            try PresetRules.setWidth($0, tool: p.tool, index: p.index, width: p.width, pattern: p.pattern)
        }
        return PresetOutput(tool: p.tool, applied: true, presets: next)
    }
}

struct PresetReset: NibCommand {
    struct Params: Codable {
        var tool: String
    }
    static let descriptor = CommandDescriptor(
        id: "preset.reset", title: "Restore Default Presets",
        summary: "Restore a tool's default colour and thickness presets (its custom slots are discarded).",
        params: .obj(["tool": PresetRules.toolSchema()], required: ["tool"]),
        examples: [["tool": "pen"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> PresetOutput {
        try PresetRules.checkTool(p.tool)
        // null removes the stored value (a per-key tombstone in the synced prefs): every device falls back to the default.
        ctx.services.settings.setJSON(PresetRules.key(p.tool).name, nil)
        return PresetOutput(tool: p.tool, applied: true, presets: ToolPresets.defaults(for: p.tool))
    }
}

// MARK: - Calling them from the UI

/// Runs preset commands from UI code as the user, in order and in one undo group. A failure is reported the way
/// `NibApp.perform` reports it (the shell shows a toast).
@MainActor
enum PresetActions {
    typealias Call = (command: String, params: JSONValue)

    static func call(_ command: String, _ tool: String, _ params: [String: JSONValue] = [:]) -> Call {
        var o = params
        o["tool"] = .string(tool)
        return (command, .object(o))
    }

    @discardableResult
    static func run(_ app: NibApp, session: EditorSession?, _ calls: [Call]) -> Task<Void, Never> {
        Task { @MainActor in
            let group = NibID.make().raw
            for c in calls {
                do {
                    _ = try await app.bus.execute(Invocation(command: c.command, params: c.params, session: session, group: group))
                } catch {
                    NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                    userInfo: ["command": c.command, "error": NibError.wrap(error)])
                    return
                }
            }
        }
    }
}
