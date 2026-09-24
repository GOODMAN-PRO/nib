import Foundation

/// A deliberately flat JSON Schema subset (no $ref / oneOf) that small local models can follow.
/// Unknown object keys are allowed; `null` values are treated as absent.
public indirect enum JSONSchema {
    case object([String: JSONSchema], required: [String], description: String?)
    case array(JSONSchema, description: String?)
    case string(description: String?, choices: [String]?)
    case number(description: String?, minimum: Double?, maximum: Double?)
    case integer(description: String?, minimum: Int?, maximum: Int?)
    case boolean(description: String?)
    case anyValue(description: String?)
    /// A schema supplied verbatim (plugin manifests). Only its presence is checked.
    case raw(JSONValue)

    // MARK: Builders

    public static func obj(_ properties: [String: JSONSchema], required: [String] = [], _ description: String? = nil) -> JSONSchema {
        .object(properties, required: required, description: description)
    }
    public static func str(_ description: String? = nil, choices: [String]? = nil) -> JSONSchema {
        .string(description: description, choices: choices)
    }
    public static func num(_ description: String? = nil, min: Double? = nil, max: Double? = nil) -> JSONSchema {
        .number(description: description, minimum: min, maximum: max)
    }
    public static func int(_ description: String? = nil, min: Int? = nil, max: Int? = nil) -> JSONSchema {
        .integer(description: description, minimum: min, maximum: max)
    }
    public static func bool(_ description: String? = nil) -> JSONSchema { .boolean(description: description) }
    public static func arr(_ items: JSONSchema, _ description: String? = nil) -> JSONSchema { .array(items, description: description) }
    public static func anything(_ description: String? = nil) -> JSONSchema { .anyValue(description: description) }

    public static let empty: JSONSchema = .object([:], required: [], description: nil)
    public static let ref: JSONSchema = .string(description: "node ref: doc:D, page:D/P, item:D/P/I, block:D/B, card:D/C, audio:D/A, folder:F", choices: nil)
    public static let color: JSONSchema = .string(description: "#RRGGBB or #RRGGBBAA", choices: nil)
    public static let point: JSONSchema = .array(.number(description: nil, minimum: nil, maximum: nil), description: "[x, y] in page points, origin top-left")
    public static let rect: JSONSchema = .array(.number(description: nil, minimum: nil, maximum: nil), description: "[x, y, width, height] in page points")

    /// Wraps a plugin-supplied JSON Schema.
    public static func fromJSON(_ value: JSONValue) -> JSONSchema { .raw(value) }

    // MARK: Validation

    public func validate(_ value: JSONValue, path: String = "$") -> [NibError] {
        switch self {
        case .anyValue, .raw:
            return []
        case let .object(properties, required, _):
            guard case .object(let o) = value else { return [NibError.invalid("expected an object", path: path)] }
            var errors: [NibError] = []
            for key in required where o[key] == nil || o[key] == .null {
                errors.append(NibError.invalid("missing required field '\(key)'", path: path + "." + key))
            }
            for key in o.keys.sorted() {
                guard let schema = properties[key], let v = o[key], v != .null else { continue }
                errors += schema.validate(v, path: path + "." + key)
            }
            return errors
        case let .array(items, _):
            guard case .array(let a) = value else { return [NibError.invalid("expected an array", path: path)] }
            var errors: [NibError] = []
            for (i, v) in a.enumerated() {
                errors += items.validate(v, path: "\(path)[\(i)]")
                if errors.count > 20 { break }
            }
            return errors
        case let .string(_, choices):
            guard case .string(let s) = value else { return [NibError.invalid("expected a string", path: path)] }
            if let choices = choices, !choices.contains(s) {
                return [NibError.invalid("expected one of: \(choices.joined(separator: ", "))", path: path)]
            }
            return []
        case let .number(_, lo, hi):
            guard case .number(let n) = value else { return [NibError.invalid("expected a number", path: path)] }
            if let lo = lo, n < lo { return [NibError.invalid("must be >= \(lo)", path: path)] }
            if let hi = hi, n > hi { return [NibError.invalid("must be <= \(hi)", path: path)] }
            return []
        case let .integer(_, lo, hi):
            guard case .number(let n) = value, n == n.rounded() else { return [NibError.invalid("expected an integer", path: path)] }
            if let lo = lo, n < Double(lo) { return [NibError.invalid("must be >= \(lo)", path: path)] }
            if let hi = hi, n > Double(hi) { return [NibError.invalid("must be <= \(hi)", path: path)] }
            return []
        case .boolean:
            guard case .bool = value else { return [NibError.invalid("expected true or false", path: path)] }
            return []
        }
    }

    // MARK: Export (tool definitions, MCP, commands.describe)

    public func toJSON() -> JSONValue {
        switch self {
        case .raw(let v):
            return v
        case let .object(properties, required, d):
            var o: [String: JSONValue] = ["type": "object", "properties": .object(properties.mapValues { $0.toJSON() })]
            if !required.isEmpty { o["required"] = .array(required.map { JSONValue.string($0) }) }
            return JSONSchema.described(o, d)
        case let .array(items, d):
            return JSONSchema.described(["type": "array", "items": items.toJSON()], d)
        case let .string(d, choices):
            var o: [String: JSONValue] = ["type": "string"]
            if let c = choices { o["enum"] = .array(c.map { JSONValue.string($0) }) }
            return JSONSchema.described(o, d)
        case let .number(d, lo, hi):
            var o: [String: JSONValue] = ["type": "number"]
            if let lo = lo { o["minimum"] = .number(lo) }
            if let hi = hi { o["maximum"] = .number(hi) }
            return JSONSchema.described(o, d)
        case let .integer(d, lo, hi):
            var o: [String: JSONValue] = ["type": "integer"]
            if let lo = lo { o["minimum"] = .number(Double(lo)) }
            if let hi = hi { o["maximum"] = .number(Double(hi)) }
            return JSONSchema.described(o, d)
        case let .boolean(d):
            return JSONSchema.described(["type": "boolean"], d)
        case let .anyValue(d):
            return JSONSchema.described([:], d)
        }
    }

    private static func described(_ o: [String: JSONValue], _ description: String?) -> JSONValue {
        var o = o
        if let d = description { o["description"] = .string(d) }
        return .object(o)
    }
}
