import Foundation
import NibContracts

// Nib Agent Protocol v1 (docs/AI.md §3): POST {baseURL} with the request JSON (optional `Authorization: Bearer`),
// answered with application/x-ndjson, one ChatEvent per line. The endpoint keeps no state: Nib sends the whole
// conversation, tool results included, on every request.

final class NibHTTPProvider: AIProvider {
    static let protocolVersion = "nib-agent/1"

    let config: AIProviderConfig
    private let credential: ProviderCredential
    private let http: ProviderHTTP
    private let bridgeAllowed: Bool

    init(config: AIProviderConfig, credential: ProviderCredential, http: ProviderHTTP, bridgeAllowed: Bool = true) {
        self.bridgeAllowed = bridgeAllowed
        self.config = config
        self.credential = credential
        self.http = http
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let config = self.config
        let credential = self.credential
        let http = self.http
        let bridgeAllowed = self.bridgeAllowed
        let ctx = ProviderCallContext(call: .chat, config: config, timeout: http.idleTimeout(for: config.baseURL))
        return ProviderStreaming.stream(ctx) { emit in
            let key = try credential.key(for: config)
            var payload = try NibAgentWire.body(request, config: config)
            let subscription = config.extraHeaders["X-Nib-Subscription"] == "1"
            if subscription && !bridgeAllowed && !request.tools.isEmpty {
                throw NibError(.permissionDenied, "Nib’s tool bridge is off.", hint: "enable the bridge in Settings › Bridge to use subscription tools")
            }
            let bridge = subscription && config.supportsTools && !request.tools.isEmpty ? try SubscriptionBridge(tools: request.tools) : nil
            defer { bridge?.stop() }
            if let bridge {
                let pairing = try await bridge.start(host: config.extraHeaders["X-Nib-Bridge-Host"])
                payload = payload.merging(["bridge": pairing])
            }
            let body = try JSONWire.encode(payload)
            var headers: [String: String] = [:]
            if let key = key, !key.isEmpty { headers["Authorization"] = "Bearer " + key }
            let req = ProviderRequests.make(config.baseURL, method: "POST", body: body, accept: "application/x-ndjson",
                                            headers: headers, config: config, timeout: ctx.timeout)
            let response: HTTPURLResponse
            let bytes: URLSession.AsyncBytes
            do {
                (response, bytes) = try await http.stream(req)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if subscription, let status = error as? HTTPStatusError, status.status == 401 || status.status == 403 {
                    throw NibError(.permissionDenied, "Nib Agent did not accept this pairing token.",
                                   hint: "paste the current pairing string from your Mac in Settings › AI")
                }
                if subscription {
                    throw NibError(.unavailable, "Could not reach Nib Agent on your Mac.",
                                   hint: "start Nib Agent, keep both devices on the same network, and check the pairing token in Settings › AI")
                }
                throw error
            }
            var decoder = NibAgentStreamDecoder(context: ctx)
            // Proxies sometimes re-frame the lines as Server-Sent Events; both carry the same event objects.
            let isSSE = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") ?? false
            var sse = SSEParser()
            func handle(_ text: String) throws {
                let line = text.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return }
                guard let event = JSONWire.parse(line) else {
                    throw NibError(.unavailable, "\(config.name) sent a line that is not JSON: \(line.prefix(80))",
                                   hint: "the endpoint must answer application/x-ndjson (docs/AI.md §3)")
                }
                try decoder.handle(event).forEach(emit)
            }
            try await ProviderHTTP.readLines(bytes) { line in
                if isSSE {
                    guard let event = sse.feed(line) else { return true }
                    for piece in event.pieces where piece != "[DONE]" { try handle(piece) }
                } else {
                    try handle(line)
                }
                return !decoder.isStopped
            }
            if isSSE, !decoder.isStopped, let event = sse.finish() {
                for piece in event.pieces where piece != "[DONE]" { try handle(piece) }
            }
            decoder.finish().forEach(emit)
        }
    }

    func listModels() async throws -> [String] {
        throw NibError(.unsupported, "A Nib HTTP endpoint has no model list.",
                       hint: "type the model name; the endpoint receives it as-is")
    }

    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] {
        throw NibError(.unsupported, "The Nib Agent Protocol has no transcription endpoint.",
                       hint: "add an OpenAI-compatible provider with a transcription model, or transcribe on device")
    }

    func generateImage(prompt: String) async throws -> Data {
        throw NibError(.unsupported, "The Nib Agent Protocol has no image endpoint.",
                       hint: "add an OpenAI-compatible provider with an image model, or use Image Playground")
    }
}

// MARK: - Request body

enum NibAgentWire {
    /// `{protocol, model, system, maxTokens, tools:[{name, description, schema}], messages:[{role, parts}]}`
    /// (+ `temperature` when the caller set one).
    static func body(_ request: ChatRequest, config: AIProviderConfig) throws -> JSONValue {
        var tools: [JSONValue] = []
        if config.supportsTools {
            for spec in request.tools {
                tools.append(["name": .string(spec.name), "description": .string(spec.description), "schema": spec.schema])
            }
        }
        var o: [String: JSONValue] = [
            "protocol": .string(NibHTTPProvider.protocolVersion),
            "model": .string(try ProviderRequests.model(request, config, required: false)),
            "system": .string(ProviderRequests.plainSystem(request.system)),
            "maxTokens": .number(Double(ProviderRequests.maxTokens(request, config))),
            "tools": .array(tools),
            "messages": .array(request.messages.map { message($0, vision: config.supportsVision) })
        ]
        if let t = request.temperature { o["temperature"] = .number(t) }
        return .object(o)
    }

    static func message(_ m: ChatMessage, vision: Bool) -> JSONValue {
        ["role": .string(m.role.rawValue), "parts": .array(m.parts.map { part($0, vision: vision) })]
    }

    static func part(_ p: ChatPart, vision: Bool) -> JSONValue {
        switch p {
        case .text(let s):
            return ["type": "text", "text": .string(s)]
        case .image(let data, let mime):
            guard vision else { return ["type": "text", "text": .string(ProviderRequests.imageOmittedNote)] }
            let img = ImageWire.normalized(data, mime: mime)
            return ["type": "image", "mime": .string(img.mime), "base64": .string(img.data.base64EncodedString())]
        case .toolCall(let id, let name, let arguments):
            return ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": arguments]
        case .toolResult(let id, let parts, let isError):
            return ["type": "toolResult", "id": .string(id), "isError": .bool(isError),
                    "parts": .array(parts.map { part($0, vision: vision) })]
        }
    }
}

// MARK: - Stream decoder

/// NDJSON events: `textDelta {text}`, `toolCall {id, name, arguments}`, `usage {input, output}`, `stop {reason}`,
/// plus `error {code, message, hint}` (or `{"error": {…}}`) for failures. Unknown types are skipped, so an endpoint
/// may send extra events. A stream that ends without `stop` stops with tool_use / end_turn.
struct NibAgentStreamDecoder {
    let context: ProviderCallContext
    private var sawToolCalls = false
    private var callCount = 0
    private(set) var isStopped = false

    init(context: ProviderCallContext) { self.context = context }

    mutating func handle(_ event: JSONValue) throws -> [ChatEvent] {
        guard !isStopped else { return [] }
        let type = event["type"]?.stringValue ?? (event["error"] != nil ? "error" : "")
        switch type {
        case "textDelta":
            guard let text = event["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "toolCall":
            guard let name = event["name"]?.stringValue, !name.isEmpty else {
                throw NibError(.unavailable, "\(context.providerName) sent a toolCall without a name.",
                               hint: "check the endpoint against the Nib Agent Protocol (docs/AI.md §3)")
            }
            callCount += 1
            sawToolCalls = true
            let id = event["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(callCount)"
            return [.toolCall(id: id, name: name, arguments: JSONWire.arguments(event["arguments"] ?? .null))]
        case "usage":
            return [.usage(input: event["input"]?.intValue ?? 0, output: event["output"]?.intValue ?? 0)]
        case "stop":
            isStopped = true
            return [.stop(reason: StopReasons.normalized(event["reason"]?.stringValue, sawToolCalls: sawToolCalls))]
        case "error":
            let e = event["error"].flatMap { $0.objectValue != nil ? $0 : nil } ?? event
            let code = e["code"]?.stringValue.flatMap(NibError.Code.init(rawValue:)) ?? .unavailable
            let message = e["message"]?.stringValue ?? event["error"]?.stringValue ?? "the endpoint reported an error"
            throw NibError(code, "\(context.providerName): \(message)", path: e["path"]?.stringValue,
                           hint: e["hint"]?.stringValue)
        default:
            return []
        }
    }

    mutating func finish() -> [ChatEvent] {
        guard !isStopped else { return [] }
        isStopped = true
        return [.stop(reason: sawToolCalls ? "tool_use" : "end_turn")]
    }
}
