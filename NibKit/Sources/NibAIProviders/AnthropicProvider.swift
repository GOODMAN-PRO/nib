import Foundation
import NibContracts

// Anthropic Messages adapter (docs/AI.md §2.2): POST {base}/v1/messages with stream: true, `x-api-key` and
// `anthropic-version: 2023-06-01`; system blocks and the last tool carry `cache_control`; GET {base}/v1/models.

final class AnthropicProvider: AIProvider {
    static let apiVersion = "2023-06-01"

    let config: AIProviderConfig
    private let credential: ProviderCredential
    private let http: ProviderHTTP

    init(config: AIProviderConfig, credential: ProviderCredential, http: ProviderHTTP) {
        self.config = config
        self.credential = credential
        self.http = http
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let config = self.config
        let credential = self.credential
        let http = self.http
        let ctx = ProviderCallContext(call: .chat, config: config, timeout: http.idleTimeout(for: config.baseURL))
        return ProviderStreaming.stream(ctx) { emit in
            let key = try credential.key(for: config)
            let body = try JSONWire.encode(try AnthropicWire.body(request, config: config))
            let req = AnthropicProvider.request(config, key: key, path: "messages", method: "POST", body: body,
                                                accept: "text/event-stream", timeout: ctx.timeout)
            let (response, bytes) = try await http.stream(req)
            var decoder = AnthropicStreamDecoder(context: ctx)
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("application/json") {
                // A proxy that ignored `stream: true` sent the whole message at once.
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                guard let message = JSONWire.parse(data) else {
                    throw NibError(.unavailable, "\(config.name) sent an answer Nib could not read.",
                                   hint: ProviderErrors.checkBaseURLHint)
                }
                try decoder.message(message).forEach(emit)
                return
            }
            var sse = SSEParser()
            try await ProviderHTTP.readLines(bytes) { line in
                guard let event = sse.feed(line) else { return true }
                try AnthropicProvider.handle(event, &decoder, emit)
                return !decoder.isFinished
            }
            if !decoder.isFinished, let event = sse.finish() { try AnthropicProvider.handle(event, &decoder, emit) }
            try decoder.finish().forEach(emit)
        }
    }

    private static func handle(_ event: SSEEvent, _ decoder: inout AnthropicStreamDecoder,
                               _ emit: (ChatEvent) -> Void) throws {
        for piece in event.pieces {
            guard let json = JSONWire.parse(piece) else { continue }
            try decoder.handle(json, event: event.event).forEach(emit)
        }
    }

    func listModels() async throws -> [String] {
        let ctx = ProviderCallContext(call: .models, config: config, timeout: http.idleTimeout(for: config.baseURL))
        return try await ProviderStreaming.call(ctx) {
            let key = try credential.key(for: config)
            var ids: [String] = []
            var after: String?
            for _ in 0..<20 {
                var query = [URLQueryItem(name: "limit", value: "1000")]
                if let after = after { query.append(URLQueryItem(name: "after_id", value: after)) }
                let req = AnthropicProvider.request(config, key: key, path: "models", method: "GET", body: nil,
                                                    accept: "application/json", timeout: ctx.timeout, query: query)
                let (data, _) = try await http.data(req)
                guard let page = JSONWire.parse(data) else {
                    throw NibError(.unavailable, "\(config.name) sent a model list Nib could not read.",
                                   hint: ProviderErrors.checkBaseURLHint)
                }
                for model in page["data"]?.arrayValue ?? [] {
                    if let id = model["id"]?.stringValue, !ids.contains(id) { ids.append(id) }
                }
                guard page["has_more"]?.boolValue == true, let last = page["last_id"]?.stringValue, last != after else { break }
                after = last
            }
            return ids
        }
    }

    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] {
        throw NibError(.unsupported, "Anthropic has no audio transcription endpoint.",
                       hint: "add an OpenAI-compatible provider with a transcription model, or transcribe on device")
    }

    func generateImage(prompt: String) async throws -> Data {
        throw NibError(.unsupported, "Anthropic has no image generation endpoint.",
                       hint: "add an OpenAI-compatible provider with an image model, or use Image Playground")
    }

    /// `{base}/v1/<path>`; a base URL that already ends in /v1 is not doubled.
    static func request(_ config: AIProviderConfig, key: String?, path: String, method: String, body: Data?,
                        accept: String, timeout: TimeInterval, query: [URLQueryItem] = []) -> URLRequest {
        let basePath = config.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = basePath.hasSuffix("v1") ? path : "v1/" + path
        let url = ProviderRequests.endpoint(config.baseURL, full, query: query)
        var headers = ["anthropic-version": apiVersion]
        if let key = key { headers["x-api-key"] = key }
        return ProviderRequests.make(url, method: method, body: body, accept: accept, headers: headers, config: config,
                                     timeout: timeout)
    }
}

// MARK: - Request body

enum AnthropicWire {
    static let ephemeral: JSONValue = ["type": "ephemeral"]

    static func body(_ request: ChatRequest, config: AIProviderConfig, stream: Bool = true) throws -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(try ProviderRequests.model(request, config)),
            "max_tokens": .number(Double(ProviderRequests.maxTokens(request, config))),
            "messages": .array(messages(request.messages, vision: config.supportsVision)),
            "stream": .bool(stream)
        ]
        let system = systemBlocks(request.system)
        if !system.isEmpty { o["system"] = .array(system) }
        if config.supportsTools && !request.tools.isEmpty { o["tools"] = .array(tools(request.tools)) }
        if let t = request.temperature { o["temperature"] = .number(t) }
        return .object(o)
    }

    /// The static prompt block carries `cache_control`; a per-turn part after U+001E is a plain block after it.
    static func systemBlocks(_ system: String) -> [JSONValue] {
        ProviderRequests.systemParts(system).enumerated().map { i, text in
            var block: [String: JSONValue] = ["type": "text", "text": .string(text)]
            if i == 0 { block["cache_control"] = ephemeral }
            return .object(block)
        }
    }

    /// `{name, description, input_schema}`; the last tool carries `cache_control`, so the tool list is cached.
    static func tools(_ specs: [ToolSpec]) -> [JSONValue] {
        specs.enumerated().map { i, spec in
            var t: [String: JSONValue] = ["name": .string(spec.name), "description": .string(spec.description),
                                          "input_schema": ProviderRequests.objectSchema(spec.schema)]
            if i == specs.count - 1 { t["cache_control"] = ephemeral }
            return .object(t)
        }
    }

    /// Messages with alternating roles: tool results travel in user messages (first in their content), and
    /// consecutive messages of one role are merged. Empty text and empty messages are dropped (the API rejects them).
    static func messages(_ messages: [ChatMessage], vision: Bool) -> [JSONValue] {
        var turns: [(role: String, blocks: [JSONValue])] = []
        for m in messages {
            let role = m.role == .assistant ? "assistant" : "user"
            let blocks = m.parts.flatMap { content($0, vision: vision) }
            guard !blocks.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append((role: role, blocks: blocks))
            }
        }
        return turns.map { turn in
            var blocks = turn.blocks
            if turn.role == "user" {
                let results = blocks.filter { $0["type"]?.stringValue == "tool_result" }
                blocks = results + blocks.filter { $0["type"]?.stringValue != "tool_result" }
            }
            return ["role": .string(turn.role), "content": .array(blocks)]
        }
    }

    static func content(_ part: ChatPart, vision: Bool) -> [JSONValue] {
        switch part {
        case .text(let s):
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [["type": "text", "text": .string(s)]]
        case .image(let data, let mime):
            guard vision else { return [["type": "text", "text": .string(ProviderRequests.imageOmittedNote)]] }
            let img = ImageWire.normalized(data, mime: mime)
            return [["type": "image",
                     "source": ["type": "base64", "media_type": .string(img.mime), "data": .string(img.data.base64EncodedString())]]]
        case .toolCall(let id, let name, let arguments):
            let input: JSONValue
            if case .object = arguments { input = arguments } else { input = .object([:]) }
            return [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]
        case .toolResult(let id, let parts, let isError):
            let inner = parts.flatMap { p -> [JSONValue] in
                switch p {
                case .text, .image: return content(p, vision: vision)
                case .toolCall, .toolResult: return []
                }
            }
            var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id)]
            if !inner.isEmpty { block["content"] = .array(inner) }
            if isError { block["is_error"] = true }
            return [.object(block)]
        }
    }
}

// MARK: - Stream decoder

/// Turns Anthropic stream events into ChatEvents: `content_block_start` opens a text or `tool_use{id,name}` block,
/// `content_block_delta` carries `text_delta` or `input_json_delta.partial_json` (concatenated per block),
/// `content_block_stop` parses the arguments and emits `.toolCall`, `message_delta` carries `stop_reason` and usage,
/// `message_stop` ends the stream with `.usage` then `.stop`. `ping`, thinking and citation deltas are ignored.
struct AnthropicStreamDecoder {
    private struct Block {
        var type: String
        var id = ""
        var name = ""
        var json = ""
        var input: JSONValue?
    }

    let context: ProviderCallContext
    private var blocks: [Int: Block] = [:]
    private var inputTokens = 0
    private var outputTokens = 0
    private var sawUsage = false
    private var stopReason: String?
    private var sawToolCalls = false
    private(set) var isFinished = false

    init(context: ProviderCallContext) { self.context = context }

    mutating func handle(_ payload: JSONValue, event: String?) throws -> [ChatEvent] {
        guard !isFinished else { return [] }
        let type = payload["type"]?.stringValue ?? event ?? ""
        var out: [ChatEvent] = []
        switch type {
        case "message_start":
            if let usage = payload["message"]?["usage"] { absorb(usage) }
        case "content_block_start":
            let index = payload["index"]?.intValue ?? 0
            let cb = payload["content_block"] ?? .null
            var block = Block(type: cb["type"]?.stringValue ?? "")
            switch block.type {
            case "text":
                if let text = cb["text"]?.stringValue, !text.isEmpty { out.append(.textDelta(text)) }
            case "tool_use":
                block.id = cb["id"]?.stringValue ?? ""
                block.name = cb["name"]?.stringValue ?? ""
                if let input = cb["input"], case .object(let o) = input, !o.isEmpty { block.input = input }
            default:
                break
            }
            blocks[index] = block
        case "content_block_delta":
            let index = payload["index"]?.intValue ?? 0
            let delta = payload["delta"] ?? .null
            switch delta["type"]?.stringValue {
            case "text_delta":
                if let text = delta["text"]?.stringValue, !text.isEmpty { out.append(.textDelta(text)) }
            case "input_json_delta":
                if let piece = delta["partial_json"]?.stringValue { blocks[index]?.json += piece }
            default:
                break
            }
        case "content_block_stop":
            let index = payload["index"]?.intValue ?? 0
            if let block = blocks.removeValue(forKey: index), block.type == "tool_use" {
                out.append(toolCall(block))
            }
        case "message_delta":
            if let reason = payload["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let usage = payload["usage"] { absorb(usage) }
        case "message_stop":
            out += end()
        case "error":
            throw ProviderErrors.streamError(payload["error"] ?? payload, context)
        default:
            break
        }
        return out
    }

    /// The stream ended. After `message_delta` carried a stop reason the answer is complete; otherwise the
    /// connection dropped mid-answer.
    mutating func finish() throws -> [ChatEvent] {
        if isFinished { return [] }
        guard stopReason != nil else {
            throw NibError(.unavailable, "The connection to \(context.providerName) closed before the answer finished.",
                           hint: "retry")
        }
        var out: [ChatEvent] = []
        for index in blocks.keys.sorted() {
            if let block = blocks[index], block.type == "tool_use" { out.append(toolCall(block)) }
        }
        blocks.removeAll()
        return out + end()
    }

    /// Events of a whole (non-streamed) Messages response.
    mutating func message(_ message: JSONValue) throws -> [ChatEvent] {
        if message["type"]?.stringValue == "error" {
            throw ProviderErrors.streamError(message["error"] ?? message, context)
        }
        var out: [ChatEvent] = []
        for block in message["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { out.append(.textDelta(text)) }
            case "tool_use":
                sawToolCalls = true
                out.append(.toolCall(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "",
                                     arguments: JSONWire.arguments(block["input"] ?? .null)))
            default:
                break
            }
        }
        if let usage = message["usage"] { absorb(usage) }
        stopReason = message["stop_reason"]?.stringValue
        return out + end()
    }

    private mutating func toolCall(_ block: Block) -> ChatEvent {
        sawToolCalls = true
        let arguments = block.json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (block.input ?? .object([:])) : JSONWire.arguments(block.json)
        return .toolCall(id: block.id, name: block.name, arguments: arguments)
    }

    /// Input counts every prompt token the request was billed for: uncached, written to and read from the cache.
    private mutating func absorb(_ usage: JSONValue) {
        let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0]?.intValue }
        if !parts.isEmpty {
            inputTokens = parts.reduce(0, +)
            sawUsage = true
        }
        if let output = usage["output_tokens"]?.intValue {
            outputTokens = output
            sawUsage = true
        }
    }

    private mutating func end() -> [ChatEvent] {
        isFinished = true
        var out: [ChatEvent] = []
        if sawUsage { out.append(.usage(input: inputTokens, output: outputTokens)) }
        out.append(.stop(reason: StopReasons.normalized(stopReason, sawToolCalls: sawToolCalls)))
        return out
    }
}
