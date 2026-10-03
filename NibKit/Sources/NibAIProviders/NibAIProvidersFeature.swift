import Foundation
import ImageIO
import UniformTypeIdentifiers
import os
import NibContracts

/// F083: bring-your-own-model providers. Installs the `AIProviderStore` (`ServiceKeys.aiProviders`) whose providers
/// speak the three wire protocols of docs/AI.md §2–§3: Anthropic Messages, OpenAI-compatible Chat Completions
/// (OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Groq…) and the Nib Agent Protocol over HTTP. Provider management
/// commands (`ai.provider.*`) and the settings page belong to F086; the agent that drives a turn is F084.
public enum NibAIProvidersFeature: NibFeature {
    public static let id = "aiproviders"

    public static func register(_ app: NibApp) {
        // The store loads its file lazily, on first use, so registration stays fast.
        let store = ProviderStore()
        store.bridgeIsEnabled = { [weak app] in app?.settings.get(SettingKey(BridgeNames.enabledSetting, default: false)) ?? false }
        app.services.set(store, for: ServiceKeys.aiProviders)
    }
}

/// os.Logger for the module (category = the feature id). Never logs keys, prompts or answers.
let providerLog = Logger(subsystem: "app.nib", category: "aiproviders")

// MARK: - Streaming

enum ProviderStreaming {
    /// Runs one provider call off the main actor and exposes it as the `AIProvider.stream` result. Ending the
    /// iteration early (or cancelling the consuming task) cancels the call and its URLSession task. Every failure
    /// reaches the consumer as a NibError.
    static func stream(_ ctx: ProviderCallContext,
                       _ body: @escaping (_ emit: @escaping (ChatEvent) -> Void) async throws -> Void)
        -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await body { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    let mapped = ProviderErrors.map(error, ctx)
                    if mapped.code != .userDenied {
                        providerLog.error("\(ctx.providerName, privacy: .public) call failed: \(mapped.description, privacy: .public)")
                    }
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a non-streaming call, mapping every failure to NibError.
    static func call<T>(_ ctx: ProviderCallContext, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let mapped = ProviderErrors.map(error, ctx)
            if mapped.code != .userDenied {
                providerLog.error("\(ctx.providerName, privacy: .public) call failed: \(mapped.description, privacy: .public)")
            }
            throw mapped
        }
    }
}

// MARK: - Requests

enum ProviderRequests {
    /// `base` + `path`, keeping the base's own path and query (e.g. an Azure `?api-version=` or a proxy prefix).
    static func endpoint(_ base: URL, _ path: String, query: [URLQueryItem] = []) -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base.appendingPathComponent(path)
        }
        var p = c.percentEncodedPath
        while p.hasSuffix("/") { p.removeLast() }
        c.percentEncodedPath = p + "/" + path
        if !query.isEmpty { c.queryItems = (c.queryItems ?? []) + query }
        return c.url ?? base.appendingPathComponent(path)
    }

    /// A request with the config's non-secret extra headers first, then the protocol's own headers (which win).
    static func make(_ url: URL, method: String, body: Data? = nil, contentType: String? = "application/json",
                     accept: String, headers: [String: String], config: AIProviderConfig, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        for (name, value) in config.extraHeaders { r.setValue(value, forHTTPHeaderField: name) }
        if let contentType = contentType, body != nil { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        r.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { r.setValue(value, forHTTPHeaderField: name) }
        return r
    }

    /// The model a request runs on: the request's, else the config's. Only the Nib HTTP protocol accepts none.
    static func model(_ request: ChatRequest, _ config: AIProviderConfig, required: Bool = true) throws -> String {
        let m = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = m.isEmpty ? config.model.trimmingCharacters(in: .whitespacesAndNewlines) : m
        if required && model.isEmpty {
            throw NibError(.invalidParams, "No model is selected for “\(config.name)”.", path: "$.model",
                           hint: ProviderErrors.pickModelHint)
        }
        return model
    }

    /// The output token budget: the request's, capped by the provider's `maxOutputTokens`.
    static func maxTokens(_ request: ChatRequest, _ config: AIProviderConfig) -> Int {
        let cap = config.maxOutputTokens > 0 ? config.maxOutputTokens : Int.max
        let asked = request.maxTokens > 0 ? request.maxTokens : cap
        return max(1, min(asked, cap))
    }

    /// Separates the cacheable static system prompt from the per-turn part. `ChatRequest.system` is one string; a
    /// U+001E (record separator) in it marks the end of the static part. Without one, the whole prompt is static.
    static let systemBoundary: Character = "\u{1E}"

    static func systemParts(_ system: String) -> [String] {
        system.split(separator: systemBoundary, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The system prompt as one string for protocols without system blocks.
    static func plainSystem(_ system: String) -> String { systemParts(system).joined(separator: "\n\n") }

    /// A tool's JSON schema as an object schema (the APIs reject anything else).
    static func objectSchema(_ schema: JSONValue) -> JSONValue {
        guard case .object(var o) = schema else { return ["type": "object", "properties": .object([:])] }
        if o["type"] == nil { o["type"] = "object" }
        if o["type"]?.stringValue == "object" && o["properties"] == nil { o["properties"] = .object([:]) }
        return .object(o)
    }

    static let imageOmittedNote = "[An image was omitted: this model does not accept images.]"
}

// MARK: - JSON

enum JSONWire {
    static func encode(_ value: JSONValue) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return try e.encode(value)
    }

    /// Compact JSON text with sorted keys and unescaped slashes (tool-call arguments echoed back to the model).
    static func string(_ value: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? e.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> JSONValue? { try? JSONValue.parse(text) }

    static func parse(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }

    /// Tool-call arguments as the model sent them. Empty → `{}`; a JSON string that itself holds an object (some
    /// local models double-encode) → that object; text that is not JSON stays a string so the agent can report the
    /// schema error back to the model and let it retry.
    static func arguments(_ raw: String) -> JSONValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .object([:]) }
        guard let value = parse(text) else { return .string(raw) }
        switch value {
        case .null: return .object([:])
        case .string(let inner):
            if let nested = parse(inner), case .object = nested { return nested }
            return value
        default: return value
        }
    }

    /// Arguments already delivered as JSON (not as a string).
    static func arguments(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return arguments(s)
        case .null: return .object([:])
        default: return value
        }
    }
}

// MARK: - Stop reasons

enum StopReasons {
    /// One vocabulary for every protocol: end_turn, tool_use, max_tokens, stop_sequence, refusal (others pass through).
    static func normalized(_ raw: String?, sawToolCalls: Bool) -> String {
        let r = (raw ?? "").trimmingCharacters(in: .whitespaces)
        switch r.lowercased() {
        case "tool_calls", "tool_use", "function_call": return "tool_use"
        case "length", "max_tokens", "max_output_tokens": return "max_tokens"
        case "", "stop", "end_turn", "eos", "end": return sawToolCalls ? "tool_use" : "end_turn"
        case "stop_sequence": return "stop_sequence"
        case "content_filter", "refusal", "safety": return "refusal"
        default: return r
        }
    }
}

// MARK: - Images

enum ImageWire {
    /// Image types every protocol here accepts as-is; anything else (HEIC, TIFF, BMP…) is converted to PNG.
    static let accepted: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// The image in an accepted type, with its media type.
    static func normalized(_ data: Data, mime: String) -> (data: Data, mime: String) {
        var type = mime.lowercased().trimmingCharacters(in: .whitespaces)
        if type == "image/jpg" || type == "image/pjpeg" { type = "image/jpeg" }
        if !accepted.contains(type), let sniffed = sniff(data) { type = sniffed }
        if accepted.contains(type) { return (data, type) }
        if let png = pngData(data) { return (png, "image/png") }
        return (data, type.isEmpty ? "image/png" : type)
    }

    static func dataURL(_ data: Data, mime: String) -> String {
        let n = normalized(data, mime: mime)
        return "data:\(n.mime);base64,\(n.data.base64EncodedString())"
    }

    /// The media type from the file signature (only the accepted types).
    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 4 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return "image/gif" }
        if b.count >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return "image/webp" }
        return nil
    }

    static func isPNG(_ data: Data) -> Bool { sniff(data) == "image/png" }

    /// Re-encodes any image ImageIO can read as PNG (thread-safe; no UIKit).
    static func pngData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Credentials

/// The API key a provider sends, resolved from the Keychain when the store hands the provider out.
enum ProviderCredential: Equatable {
    case key(String)
    /// No key configured (local servers, keyless proxies): requests go out without one.
    case none
    /// A key was saved for this provider but the Keychain no longer has it (a re-signed build).
    case missing

    /// The key to send, or nil; a missing key fails the call with permission_denied and "re-enter the API key".
    func key(for config: AIProviderConfig) throws -> String? {
        switch self {
        case .key(let k): return k
        case .none: return nil
        case .missing:
            if config.extraHeaders["X-Nib-Subscription"] == "1" {
                throw NibError(.permissionDenied, "The Nib Agent pairing token is missing from this device.",
                               hint: "paste the pairing string from your Mac again in Settings › AI")
            }
            throw ProviderErrors.missingKey(config.name)
        }
    }
}
