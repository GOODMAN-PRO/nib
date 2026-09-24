import Foundation

/// The one error type that crosses every boundary (UI, plugins, AI tools, MCP). Stable `code`s let models self-correct.
/// Wire form: {"error": {"code": "...", "message": "...", "path": "...", "hint": "..."}}.
public struct NibError: Error, Codable, Equatable, CustomStringConvertible, LocalizedError {
    public enum Code: String, Codable, CaseIterable {
        case invalidParams = "invalid_params"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        case userDenied = "user_denied"
        case locked
        case conflict
        case invariantViolation = "invariant_violation"
        case timeout
        case unavailable
        case unsupported
        case internalError = "internal"
    }

    public var code: Code
    public var message: String
    /// JSON path of the offending parameter, e.g. "$.points[3]".
    public var path: String?
    /// What to try next, e.g. "call commands.describe {id: 'ink.addStrokes'}".
    public var hint: String?

    public init(_ code: Code, _ message: String, path: String? = nil, hint: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.hint = hint
    }

    public static func notFound(_ what: String) -> NibError { NibError(.notFound, "\(what) not found") }
    public static func invalid(_ message: String, path: String? = nil) -> NibError { NibError(.invalidParams, message, path: path) }
    public static func unavailable(_ what: String) -> NibError {
        NibError(.unavailable, "\(what) is not available", hint: "the feature that provides it is disabled or not configured")
    }
    public static func unsupported(_ what: String) -> NibError { NibError(.unsupported, "\(what) is not supported") }

    /// Converts any error into a NibError (non-Nib errors become `internal`).
    public static func wrap(_ error: Error) -> NibError {
        if let e = error as? NibError { return e }
        return NibError(.internalError, error.localizedDescription)
    }

    public var description: String {
        var s = "[\(code.rawValue)] \(message)"
        if let p = path { s += " at \(p)" }
        if let h = hint { s += " (hint: \(h))" }
        return s
    }

    public var errorDescription: String? { message }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if let p = path { o["path"] = .string(p) }
        if let h = hint { o["hint"] = .string(h) }
        return ["error": .object(o)]
    }
}
