import Foundation
import NibContracts

// OpenAI-compatible adapter (docs/AI.md §2.3): POST {base}/chat/completions with stream: true and
// stream_options.include_usage (retried without it when a server refuses the field); tool calls accumulate by
// index; GET {base}/models; POST {base}/audio/transcriptions and {base}/images/generations when the config names
// a transcription or image model. Serves OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Groq and similar servers.

final class OpenAICompatibleProvider: AIProvider {
    let config: AIProviderConfig
    private let credential: ProviderCredential
    private let http: ProviderHTTP

    init(config: AIProviderConfig, credential: ProviderCredential, http: ProviderHTTP) {
        self.config = config
        self.credential = credential
        self.http = http
    }

    // MARK: Chat

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let config = self.config
        let credential = self.credential
        let http = self.http
        let ctx = ProviderCallContext(call: .chat, config: config, timeout: http.idleTimeout(for: config.baseURL))
        return ProviderStreaming.stream(ctx) { emit in
            let key = try credential.key(for: config)
            do {
                try await OpenAICompatibleProvider.run(request, config, key, http, ctx, streamOptions: true, emit)
            } catch let e as HTTPStatusError where (e.status == 400 || e.status == 422) && e.mentions("stream_options") {
                // "ignored if unsupported": a server that rejects the field gets the request without it.
                try await OpenAICompatibleProvider.run(request, config, key, http, ctx, streamOptions: false, emit)
            }
        }
    }

    private static func run(_ request: ChatRequest, _ config: AIProviderConfig, _ key: String?, _ http: ProviderHTTP,
                            _ ctx: ProviderCallContext, streamOptions: Bool, _ emit: @escaping (ChatEvent) -> Void) async throws {
        let body = try JSONWire.encode(try OpenAIWire.body(request, config: config, streamOptions: streamOptions))
        let req = OpenAICompatibleProvider.request(config, key: key, path: "chat/completions", method: "POST", body: body,
                                                   accept: "text/event-stream", timeout: ctx.timeout)
        let (response, bytes) = try await http.stream(req)
        var decoder = OpenAIStreamDecoder(context: ctx)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") {
            // A server that does not stream (or not with tools) sent one whole completion.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard let completion = JSONWire.parse(data) else {
                throw NibError(.unavailable, "\(config.name) sent an answer Nib could not read.",
                               hint: ProviderErrors.checkBaseURLHint)
            }
            try decoder.handle(completion).forEach(emit)
            decoder.finish().forEach(emit)
            return
        }
        var sse = SSEParser()
        func handle(_ event: SSEEvent) throws {
            for piece in event.pieces {
                if piece == "[DONE]" {
                    decoder.finish().forEach(emit)
                    return
                }
                guard let chunk = JSONWire.parse(piece) else { continue }
                try decoder.handle(chunk).forEach(emit)
            }
        }
        try await ProviderHTTP.readLines(bytes) { line in
            guard let event = sse.feed(line) else { return true }
            try handle(event)
            return !decoder.isDone
        }
        if !decoder.isDone, let event = sse.finish() { try handle(event) }
        // "Parsing happens when finish_reason == tool_calls or the stream ends": a server without [DONE] ends here.
        decoder.finish().forEach(emit)
    }

    // MARK: Models

    func listModels() async throws -> [String] {
        let ctx = ProviderCallContext(call: .models, config: config, timeout: http.idleTimeout(for: config.baseURL))
        return try await ProviderStreaming.call(ctx) {
            let key = try credential.key(for: config)
            let req = OpenAICompatibleProvider.request(config, key: key, path: "models", method: "GET", body: nil,
                                                       accept: "application/json", timeout: ctx.timeout)
            let (data, _) = try await http.data(req)
            guard let list = JSONWire.parse(data) else {
                throw NibError(.unavailable, "\(config.name) sent a model list Nib could not read.",
                               hint: ProviderErrors.checkBaseURLHint)
            }
            return OpenAIWire.modelIDs(list)
        }
    }

    // MARK: Audio

    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] {
        guard let model = config.transcriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            throw NibError(.unsupported, "“\(config.name)” has no transcription model.",
                           hint: "set a transcription model (e.g. whisper-1) in Settings › AI, or transcribe on device")
        }
        let ctx = ProviderCallContext(call: .transcription, config: config, timeout: max(http.idleTimeout(for: config.baseURL), 300))
        return try await ProviderStreaming.call(ctx) {
            let key = try credential.key(for: config)
            let audioData: Data
            do {
                audioData = try Data(contentsOf: audio, options: .mappedIfSafe)
            } catch {
                throw NibError(.notFound, "The recording to transcribe could not be read.",
                               hint: "check that the audio clip still exists")
            }
            func send(_ format: String) async throws -> Data {
                var form = MultipartForm()
                form.field("model", model)
                form.field("response_format", format)
                if let code = OpenAIWire.languageCode(language) { form.field("language", code) }
                form.file("file", filename: audio.lastPathComponent.isEmpty ? "audio.m4a" : audio.lastPathComponent,
                          mime: MultipartForm.audioMIME(audio.pathExtension), data: audioData)
                let req = OpenAICompatibleProvider.request(config, key: key, path: "audio/transcriptions", method: "POST",
                                                           body: form.finish(), contentType: form.contentType,
                                                           accept: "application/json", timeout: ctx.timeout)
                return try await http.data(req).0
            }
            let data: Data
            do {
                data = try await send("verbose_json")
            } catch let e as HTTPStatusError where e.status == 400 && (e.mentions("response_format") || e.mentions("verbose_json")) {
                // Newer transcription models only answer plain json (no segment timings).
                data = try await send("json")
            }
            return try OpenAIWire.transcript(data, providerName: config.name)
        }
    }

    // MARK: Images

    func generateImage(prompt: String) async throws -> Data {
        guard let model = config.imageModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            throw NibError(.unsupported, "“\(config.name)” has no image model.",
                           hint: "set an image model (e.g. gpt-image-1) in Settings › AI, or use Image Playground")
        }
        let ctx = ProviderCallContext(call: .images, config: config, timeout: max(http.idleTimeout(for: config.baseURL), 300))
        return try await ProviderStreaming.call(ctx) {
            let key = try credential.key(for: config)
            func send(_ withFormat: Bool) async throws -> Data {
                var body: [String: JSONValue] = ["model": .string(model), "prompt": .string(prompt), "n": 1]
                if withFormat { body["response_format"] = "b64_json" }
                let req = OpenAICompatibleProvider.request(config, key: key, path: "images/generations", method: "POST",
                                                           body: try JSONWire.encode(.object(body)),
                                                           accept: "application/json", timeout: ctx.timeout)
                return try await http.data(req).0
            }
            let data: Data
            do {
                data = try await send(true)
            } catch let e as HTTPStatusError where e.status == 400 && e.mentions("response_format") {
                // gpt-image models always answer base64 and refuse the parameter.
                data = try await send(false)
            }
            let image = try await OpenAIWire.image(from: data, providerName: config.name) { url in
                guard url.scheme?.lowercased() == "https" else {
                    throw NibError(.unsupported, "\(config.name) returned an image link that is not https.")
                }
                let r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: ctx.timeout)
                return try await http.data(r).0
            }
            if ImageWire.isPNG(image) { return image }
            guard let png = ImageWire.pngData(image) else {
                throw NibError(.unavailable, "\(config.name) returned an image Nib could not read.")
            }
            return png
        }
    }

    // MARK: Requests

    /// `{base}/<path>` with `Authorization: Bearer <key>` when a key is set.
    static func request(_ config: AIProviderConfig, key: String?, path: String, method: String, body: Data?,
                        contentType: String = "application/json", accept: String, timeout: TimeInterval) -> URLRequest {
        let url = ProviderRequests.endpoint(config.baseURL, path)
        var headers: [String: String] = [:]
        if let key = key, !key.isEmpty { headers["Authorization"] = "Bearer " + key }
        return ProviderRequests.make(url, method: method, body: body, contentType: contentType, accept: accept,
                                     headers: headers, config: config, timeout: timeout)
    }
}

// MARK: - Request body

enum OpenAIWire {
    static func body(_ request: ChatRequest, config: AIProviderConfig, streamOptions: Bool = true,
                     stream: Bool = true) throws -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(try ProviderRequests.model(request, config)),
            "messages": .array(messages(system: request.system, request.messages, vision: config.supportsVision)),
            "stream": .bool(stream)
        ]
        if stream && streamOptions { o["stream_options"] = ["include_usage": true] }
        // OpenAI's own API replaced max_tokens with max_completion_tokens (its reasoning models refuse the old
        // name); compatible servers keep max_tokens.
        let budget = JSONValue.number(Double(ProviderRequests.maxTokens(request, config)))
        if config.baseURL.host?.lowercased() == "api.openai.com" { o["max_completion_tokens"] = budget } else { o["max_tokens"] = budget }
        if config.supportsTools && !request.tools.isEmpty { o["tools"] = .array(tools(request.tools)) }
        if let t = request.temperature { o["temperature"] = .number(t) }
        return .object(o)
    }

    static func tools(_ specs: [ToolSpec]) -> [JSONValue] {
        var out: [JSONValue] = []
        for spec in specs {
            let function: JSONValue = ["name": .string(spec.name), "description": .string(spec.description),
                                       "parameters": ProviderRequests.objectSchema(spec.schema)]
            out.append(["type": "function", "function": function])
        }
        return out
    }

    /// Roles system, user, assistant (with `tool_calls`) and tool (with `tool_call_id`). A tool result's images
    /// cannot travel in a tool message, so they follow the tool messages in one user message.
    static func messages(system: String, _ messages: [ChatMessage], vision: Bool) -> [JSONValue] {
        var out: [JSONValue] = []
        let sys = ProviderRequests.plainSystem(system)
        if !sys.isEmpty { out.append(["role": "system", "content": .string(sys)]) }
        var pending: [JSONValue] = []
        func flushPending() {
            guard !pending.isEmpty else { return }
            out.append(userMessage(pending))
            pending = []
        }
        for m in messages {
            switch m.role {
            case .assistant:
                flushPending()
                var text = ""
                var calls: [JSONValue] = []
                for part in m.parts {
                    switch part {
                    case .text(let s): text += s
                    case .toolCall(let id, let name, let arguments):
                        let args: String
                        if case .string(let raw) = arguments { args = raw } else { args = JSONWire.string(arguments) }
                        calls.append(["id": .string(id), "type": "function",
                                      "function": ["name": .string(name), "arguments": .string(args)]])
                    case .image, .toolResult:
                        break
                    }
                }
                guard !text.isEmpty || !calls.isEmpty else { continue }
                var msg: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
                if !calls.isEmpty { msg["tool_calls"] = .array(calls) }
                out.append(.object(msg))
            case .user, .tool:
                var own: [JSONValue] = []
                for part in m.parts {
                    switch part {
                    case .toolResult(let id, let parts, let isError):
                        var text = ""
                        for p in parts {
                            switch p {
                            case .text(let s): text += s
                            case .image(let data, let mime):
                                pending.append(["type": "text", "text": .string("Image from tool call \(id):")])
                                pending += contentParts(.image(data: data, mime: mime), vision: vision)
                            case .toolCall, .toolResult:
                                break
                            }
                        }
                        if text.isEmpty && isError { text = #"{"error":{"code":"internal","message":"the tool failed"}}"# }
                        out.append(["role": "tool", "tool_call_id": .string(id), "content": .string(text)])
                    case .text, .image:
                        own += contentParts(part, vision: vision)
                    case .toolCall:
                        break
                    }
                }
                if m.role == .user {
                    pending += own
                    flushPending()
                } else {
                    pending += own
                }
            }
        }
        flushPending()
        return out
    }

    /// A user message: plain string content when it is only text, else content parts.
    static func userMessage(_ parts: [JSONValue]) -> JSONValue {
        if parts.allSatisfy({ $0["type"]?.stringValue == "text" }) {
            let text = parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            return ["role": "user", "content": .string(text)]
        }
        return ["role": "user", "content": .array(parts)]
    }

    static func contentParts(_ part: ChatPart, vision: Bool) -> [JSONValue] {
        switch part {
        case .text(let s):
            return s.isEmpty ? [] : [["type": "text", "text": .string(s)]]
        case .image(let data, let mime):
            guard vision else { return [["type": "text", "text": .string(ProviderRequests.imageOmittedNote)]] }
            return [["type": "image_url", "image_url": ["url": .string(ImageWire.dataURL(data, mime: mime))]]]
        case .toolCall, .toolResult:
            return []
        }
    }

    /// Ids from `{"data":[{"id"}]}` (OpenAI, OpenRouter, Ollama, LM Studio, vLLM) or `{"models":[{"id"|"name"}]}`.
    static func modelIDs(_ list: JSONValue) -> [String] {
        let entries = list["data"]?.arrayValue ?? list["models"]?.arrayValue ?? list.arrayValue ?? []
        var ids: [String] = []
        for e in entries {
            if let id = e["id"]?.stringValue ?? e["name"]?.stringValue ?? e.stringValue, !id.isEmpty, !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// ISO-639-1 code the transcription endpoint accepts ("en-GB" → "en"); nil lets the server detect it.
    static func languageCode(_ language: String?) -> String? {
        guard let l = language?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return nil }
        let code = l.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        return code.count == 2 || code.count == 3 ? code : nil
    }

    /// `verbose_json` segments → TranscriptSegments; a plain `json` answer becomes one segment.
    static func transcript(_ data: Data, providerName: String) throws -> [TranscriptSegment] {
        guard let json = JSONWire.parse(data) else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptSegment(index: 0, start: 0, duration: 0, text: text)]
        }
        var out: [TranscriptSegment] = []
        for s in json["segments"]?.arrayValue ?? [] {
            let text = (s["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = s["start"]?.doubleValue ?? 0
            let end = s["end"]?.doubleValue ?? start
            out.append(TranscriptSegment(index: out.count, start: start, duration: max(0, end - start), text: text,
                                         speaker: s["speaker"]?.stringValue))
        }
        if out.isEmpty, let text = json["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            out.append(TranscriptSegment(index: 0, start: 0, duration: json["duration"]?.doubleValue ?? 0, text: text))
        }
        if out.isEmpty, json["error"] != nil {
            throw NibError(.unavailable, "\(providerName): \(ProviderErrors.message(from: data) ?? "transcription failed")")
        }
        return out
    }

    /// The first image of `{"data":[{"b64_json"} | {"url"}]}`.
    static func image(from data: Data, providerName: String, download: (URL) async throws -> Data) async throws -> Data {
        let first = JSONWire.parse(data)?["data"]?[0]
        if let b64 = first?["b64_json"]?.stringValue, let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            return bytes
        }
        if let link = first?["url"]?.stringValue, let url = URL(string: link) {
            return try await download(url)
        }
        throw NibError(.unavailable, "\(providerName) returned no image.", hint: "check the image model in Settings › AI")
    }
}

// MARK: - Stream decoder

/// Accumulates `choices[0].delta`: text in `content`, tool calls in `tool_calls[]` **by index** (`id` and
/// `function.name` once, `function.arguments` in pieces). Calls are parsed when a `finish_reason` arrives or the
/// stream ends. Ollama and some servers send the whole arguments in one delta, sometimes as a JSON object, and
/// some reuse index 0 for every call: a new id (or a new name after complete arguments) on a used index is a new call.
struct OpenAIStreamDecoder {
    private struct Call {
        var index: Int
        var id: String
        var name: String
        var arguments: String
        var argumentsValue: JSONValue?
        var retired = false
        var emitted = false
    }

    let context: ProviderCallContext
    private var calls: [Call] = []
    private var finishReason: String?
    private var usage: (input: Int, output: Int)?
    private var sawToolCalls = false
    private(set) var isDone = false

    init(context: ProviderCallContext) { self.context = context }

    /// One chunk (or a whole non-streamed completion, whose choice has `message` instead of `delta`).
    mutating func handle(_ chunk: JSONValue) throws -> [ChatEvent] {
        guard !isDone else { return [] }
        if let error = chunk["error"], error != .null {
            throw ProviderErrors.streamError(error, context)
        }
        if let u = chunk["usage"], case .object = u {
            usage = (input: u["prompt_tokens"]?.intValue ?? u["input_tokens"]?.intValue ?? 0,
                     output: u["completion_tokens"]?.intValue ?? u["output_tokens"]?.intValue ?? 0)
        }
        var out: [ChatEvent] = []
        for choice in chunk["choices"]?.arrayValue ?? [] {
            if let i = choice["index"]?.intValue, i != 0 { continue }
            let delta = choice["delta"] ?? choice["message"] ?? .null
            if let text = delta["content"]?.stringValue, !text.isEmpty { out.append(.textDelta(text)) }
            for call in delta["tool_calls"]?.arrayValue ?? [] { absorb(call) }
            if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
                finishReason = reason
                out += flushCalls()
            }
        }
        return out
    }

    /// `[DONE]` or the end of the stream: pending calls, usage, then stop.
    mutating func finish() -> [ChatEvent] {
        guard !isDone else { return [] }
        isDone = true
        var out = flushCalls()
        if let u = usage { out.append(.usage(input: u.input, output: u.output)) }
        out.append(.stop(reason: StopReasons.normalized(finishReason, sawToolCalls: sawToolCalls)))
        return out
    }

    private mutating func absorb(_ delta: JSONValue) {
        let index = delta["index"]?.intValue
        let id = delta["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let function = delta["function"] ?? .null
        let name = function["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let args = function["arguments"]

        var slot: Int?
        if let index = index {
            slot = calls.lastIndex { $0.index == index && !$0.retired }
        } else if let id = id {
            slot = calls.lastIndex { $0.id == id && !$0.retired }
        } else {
            slot = calls.indices.last { !calls[$0].retired }
        }
        if let s = slot {
            let existing = calls[s]
            let newID = id != nil && !existing.id.isEmpty && existing.id != id
            // Without ids, a name after complete arguments starts a new call only if it names another function or
            // its arguments open a new object (servers that repeat the name on every delta stay one call).
            let freshArguments = args?.objectValue != nil
                || (args?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ?? false)
            let newName = id == nil && name != nil && !existing.name.isEmpty && isComplete(existing)
                && (name != existing.name || freshArguments)
            if newID || newName || existing.emitted {
                calls[s].retired = true
                slot = nil
            }
        }
        let s: Int
        if let found = slot {
            s = found
        } else {
            calls.append(Call(index: index ?? calls.count, id: "", name: "", arguments: ""))
            s = calls.count - 1
        }
        if let id = id, calls[s].id.isEmpty { calls[s].id = id }
        if let name = name, calls[s].name.isEmpty { calls[s].name = name }
        switch args {
        case .string(let piece)?: calls[s].arguments += piece
        case .object?, .array?: calls[s].argumentsValue = args
        default: break
        }
    }

    private func isComplete(_ call: Call) -> Bool {
        if call.argumentsValue != nil { return true }
        let text = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && JSONWire.parse(text) != nil
    }

    private mutating func flushCalls() -> [ChatEvent] {
        var out: [ChatEvent] = []
        for i in calls.indices where !calls[i].emitted {
            calls[i].emitted = true
            calls[i].retired = true
            let call = calls[i]
            guard !call.name.isEmpty else {
                let provider = context.providerName
                providerLog.error("\(provider, privacy: .public) sent a tool call without a name; dropped")
                continue
            }
            sawToolCalls = true
            let id = call.id.isEmpty ? "call_\(i)" : call.id
            let arguments = call.argumentsValue.map { JSONWire.arguments($0) } ?? JSONWire.arguments(call.arguments)
            out.append(.toolCall(id: id, name: call.name, arguments: arguments))
        }
        return out
    }
}

// MARK: - Multipart

/// `multipart/form-data` for /audio/transcriptions.
struct MultipartForm {
    let boundary = "nib-" + UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        let safe = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safe)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    mutating func finish() -> Data {
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    static func audioMIME(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "mp3", "mpga", "mpeg": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        case "ogg", "oga": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}
