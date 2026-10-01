import XCTest
import CoreGraphics
import ImageIO
import NibContracts
import NibTesting
@testable import NibAIProviders

/// Serves canned HTTP answers to the provider's URLSession (hand-written fixtures from docs/AI.md §2–§3, so no API
/// keys and no network). Bodies are delivered in small chunks so lines and UTF-8 characters arrive split.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var body = Data()
        var chunkSize = 13
        var failure: URLError?
        /// Sends the headers and body, then never finishes (a server that keeps the connection open).
        var holdOpen = false
    }

    struct Recorded {
        var request: URLRequest
        var body: Data
        var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var recordedRequests: [Recorded] = []
    private static var stops = 0

    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock()
        self.handler = handler
        recordedRequests = []
        stops = 0
        lock.unlock()
    }

    static var recorded: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands protocols the body as a one-shot stream: read it once and give handlers a copy with it.
        var sent = request
        sent.httpBody = StubURLProtocol.readBody(request)
        StubURLProtocol.lock.lock()
        StubURLProtocol.recordedRequests.append(Recorded(request: sent, body: sent.httpBody ?? Data()))
        let handler = StubURLProtocol.handler
        StubURLProtocol.lock.unlock()
        guard let reply = handler?(sent), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        if let response = response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        var offset = 0
        let size = max(1, reply.chunkSize)
        while offset < reply.body.count {
            let end = min(offset + size, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        if !reply.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        StubURLProtocol.lock.lock()
        StubURLProtocol.stops += 1
        StubURLProtocol.lock.unlock()
    }

    static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@MainActor
final class ProviderStreamTests: XCTestCase {
    private var pageAdd: JSONValue {
        let params: JSONValue = ["doc": "doc:FIXTUREDOC01", "position": "end", "id": "NEWPAGE00001"]
        return ["command": "page.add", "params": params]
    }

    private var text: [ChatEvent] { [.textDelta("Adding a "), .textDelta("page — then I’ll check.")] }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
                                "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    private func makeProvider(_ kind: AIProviderKind, baseURL: String, model: String = "test-model", key: String? = "test-key",
                              configure: (inout AIProviderConfig) -> Void = { _ in }) throws -> AIProvider {
        var config = AIProviderConfig(name: "Test \(kind.rawValue)", kind: kind, baseURL: try XCTUnwrap(URL(string: baseURL)), model: model)
        configure(&config)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-aiproviders-tests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(ProviderStore.fileName)
        let store = ProviderStore(fileURL: file, secrets: InMemorySecretStore(), sessionConfiguration: StubURLProtocol.configuration())
        try store.save(config, apiKey: key)
        return try XCTUnwrap(store.provider(config.id))
    }

    private func request(tools: Bool = true) -> ChatRequest {
        ChatRequest(model: "", system: "You are the assistant inside Nib.",
                    messages: [ChatMessage(role: .user, parts: [.text("Add a page at the end.")])],
                    tools: tools ? ToolCatalog.metaTools : [])
    }

    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func expectError(_ stream: AsyncThrowingStream<ChatEvent, Error>, file: StaticString = #filePath,
                             line: UInt = #line) async -> NibError? {
        do {
            _ = try await collect(stream)
            XCTFail("expected the stream to fail", file: file, line: line)
            return nil
        } catch {
            guard let e = error as? NibError else {
                XCTFail("expected a NibError, got \(error)", file: file, line: line)
                return nil
            }
            return e
        }
    }

    // MARK: Fixture replays (docs/AI.md §10)

    func testAnthropicFixtureReplaysIntoChatEvents() async throws {
        let body = try fixture("anthropic_tool.txt")
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: body) }
        let provider = try makeProvider(.anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5")

        let events = try await collect(provider.stream(request()))
        XCTAssertEqual(events, text + [
            .toolCall(id: "toolu_01A", name: "nib_run", arguments: pageAdd),
            .toolCall(id: "toolu_01B", name: "nib_context", arguments: .object([:])),
            .usage(input: 1200, output: 85),
            .stop(reason: "tool_use")
        ])

        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.header("x-api-key"), "test-key")
        XCTAssertEqual(sent.header("anthropic-version"), "2023-06-01")
        XCTAssertNil(sent.header("Authorization"))
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["stream"]?.boolValue, true)
        XCTAssertEqual(json["model"]?.stringValue, "claude-sonnet-4-5")
        XCTAssertEqual(json["system"]?[0]?["cache_control"]?["type"]?.stringValue, "ephemeral")
        let tools = try XCTUnwrap(json["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, ToolCatalog.metaTools.count)
        XCTAssertEqual(tools.last?["cache_control"]?["type"]?.stringValue, "ephemeral")
        XCTAssertEqual(tools.filter { $0["cache_control"] != nil }.count, 1)
    }

    func testOpenAIFixtureAccumulatesToolCallsByIndex() async throws {
        let body = try fixture("openai_tool.txt")
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: body) }
        let provider = try makeProvider(.openAICompatible, baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o") {
            $0.extraHeaders = ["HTTP-Referer": "https://nib.app", "X-Title": "Nib"]
        }

        let events = try await collect(provider.stream(request()))
        XCTAssertEqual(events, text + [
            .toolCall(id: "call_A", name: "nib_run", arguments: pageAdd),
            .toolCall(id: "call_B", name: "nib_context", arguments: .object([:])),
            .usage(input: 1200, output: 85),
            .stop(reason: "tool_use")
        ])

        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(sent.header("Authorization"), "Bearer test-key")
        XCTAssertEqual(sent.header("X-Title"), "Nib")
        XCTAssertEqual(sent.header("HTTP-Referer"), "https://nib.app")
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["stream"]?.boolValue, true)
        XCTAssertEqual(json["stream_options"]?["include_usage"]?.boolValue, true)
        XCTAssertEqual(json["messages"]?[0]?["role"]?.stringValue, "system")
        XCTAssertEqual(json["tools"]?[0]?["type"]?.stringValue, "function")
        XCTAssertEqual(json["tools"]?[0]?["function"]?["name"]?.stringValue, "nib_context")
    }

    func testOllamaFixtureHandlesWholeArgumentDeltas() async throws {
        let body = try fixture("ollama_tool.txt")
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: body, chunkSize: 7) }
        let provider = try makeProvider(.openAICompatible, baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b", key: nil)

        let events = try await collect(provider.stream(request()))
        XCTAssertEqual(events, [
            .toolCall(id: "call_x1", name: "nib_run", arguments: pageAdd),
            .toolCall(id: "call_x2", name: "nib_context", arguments: .object([:])),
            .usage(input: 310, output: 42),
            .stop(reason: "tool_use")
        ], "whole arguments in one delta, index 0 reused for a second call, finish_reason 'stop' after tool calls")

        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertNil(sent.header("Authorization"), "no key, no Authorization header")
        XCTAssertEqual(sent.json?["max_tokens"]?.intValue, 4096)
    }

    func testNibHTTPFixtureReplaysNDJSON() async throws {
        let body = try fixture("nibhttp_tool.ndjson")
        StubURLProtocol.install { _ in StubURLProtocol.Reply(headers: ["Content-Type": "application/x-ndjson"], body: body, chunkSize: 5) }
        let provider = try makeProvider(.nibHTTP, baseURL: "https://agent.example.com/nib", model: "anything")

        let events = try await collect(provider.stream(request()))
        XCTAssertEqual(events, text + [
            .toolCall(id: "c2", name: "nib_run", arguments: pageAdd),
            .toolCall(id: "c3", name: "nib_context", arguments: .object([:])),
            .usage(input: 1200, output: 85),
            .stop(reason: "tool_use")
        ])

        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://agent.example.com/nib")
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.header("Authorization"), "Bearer test-key")
        XCTAssertEqual(sent.header("Content-Type"), "application/json")
        let json = try XCTUnwrap(sent.json)
        XCTAssertEqual(json["protocol"]?.stringValue, "nib-agent/1")
        XCTAssertEqual(json["model"]?.stringValue, "anything")
        XCTAssertEqual(json["messages"]?[0]?["parts"]?[0]?["text"]?.stringValue, "Add a page at the end.")
        XCTAssertEqual(json["tools"]?.arrayValue?.count, ToolCatalog.metaTools.count)
        XCTAssertNotNil(json["tools"]?[0]?["schema"])
    }

    // MARK: Protocol edge cases

    func testStreamOptionsAreDroppedWhenAServerRefusesThem() async throws {
        let body = try fixture("ollama_tool.txt")
        StubURLProtocol.install { request in
            let sent = (try? JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.readBody(request))) ?? .null
            if sent["stream_options"] != nil {
                return StubURLProtocol.Reply(status: 400, headers: ["Content-Type": "application/json"],
                                             body: Data(#"{"error":{"message":"Unrecognized request argument supplied: stream_options"}}"#.utf8))
            }
            return StubURLProtocol.Reply(body: body)
        }
        let provider = try makeProvider(.openAICompatible, baseURL: "http://192.168.1.9:8000/v1", key: nil)
        let events = try await collect(provider.stream(request()))
        XCTAssertEqual(events.last, .stop(reason: "tool_use"))
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertNil(StubURLProtocol.recorded.last?.json?["stream_options"])
    }

    func testNonStreamingCompletionIsAccepted() async throws {
        let completion = #"""
        {"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Done.",
         "tool_calls":[{"id":"call_9","type":"function","function":{"name":"nib_context","arguments":"{}"}}]},
         "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}
        """#
        StubURLProtocol.install { _ in StubURLProtocol.Reply(headers: ["Content-Type": "application/json"], body: Data(completion.utf8)) }
        let provider = try makeProvider(.openAICompatible, baseURL: "http://localhost:1234/v1", key: nil)
        let events = try await collect(provider.stream(request()))
        XCTAssertEqual(events, [.textDelta("Done."), .toolCall(id: "call_9", name: "nib_context", arguments: .object([:])),
                                .usage(input: 10, output: 3), .stop(reason: "tool_use")])
    }

    func testHTTPErrorsBecomeNibErrorsWithHints() async throws {
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 401, headers: ["Content-Type": "application/json"],
                                  body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        let anthropic = try makeProvider(.anthropic, baseURL: "https://api.anthropic.com")
        let denied = await expectError(anthropic.stream(request()))
        XCTAssertEqual(denied?.code, .permissionDenied)
        XCTAssertEqual(denied?.hint, "check the API key in Settings › AI")
        XCTAssertTrue(denied?.message.contains("invalid x-api-key") ?? false)

        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 404, headers: ["Content-Type": "application/json"],
                                  body: Data(#"{"error":{"message":"model \"llama9\" not found, try pulling it first"}}"#.utf8))
        }
        let ollama = try makeProvider(.openAICompatible, baseURL: "http://localhost:11434/v1", key: nil)
        let missing = await expectError(ollama.stream(request()))
        XCTAssertEqual(missing?.code, .notFound)
        XCTAssertEqual(missing?.hint, "pick a model from the list")

        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "20"],
                                  body: Data(#"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#.utf8))
        }
        let openAI = try makeProvider(.openAICompatible, baseURL: "https://api.openai.com/v1")
        let limited = await expectError(openAI.stream(request()))
        XCTAssertEqual(limited?.code, .unavailable)
        XCTAssertEqual(limited?.hint, "rate limited — retry later")

        StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 502, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) }
        let nib = try makeProvider(.nibHTTP, baseURL: "https://agent.example.com/nib")
        let badGateway = await expectError(nib.stream(request()))
        XCTAssertEqual(badGateway?.code, .unavailable)
    }

    func testErrorsInsideAStreamAreReported() async throws {
        let overloaded = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}

        event: error
        data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}


        """
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data(overloaded.utf8)) }
        let anthropic = try makeProvider(.anthropic, baseURL: "https://api.anthropic.com")
        let error = await expectError(anthropic.stream(request()))
        XCTAssertEqual(error?.code, .unavailable)
        XCTAssertTrue(error?.message.contains("Overloaded") ?? false)

        let truncated = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}

        """
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data(truncated.utf8)) }
        let cut = await expectError(anthropic.stream(request()))
        XCTAssertEqual(cut?.code, .unavailable, "a stream that ends before message_stop is an error, not a silent stop")

        let ndjsonError = #"{"type":"textDelta","text":"Hi"}"# + "\n" +
            #"{"type":"error","code":"locked","message":"doc is locked","hint":"unlock it"}"# + "\n"
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(headers: ["Content-Type": "application/x-ndjson"], body: Data(ndjsonError.utf8))
        }
        let nib = try makeProvider(.nibHTTP, baseURL: "https://agent.example.com/nib")
        let nibError = await expectError(nib.stream(request()))
        XCTAssertEqual(nibError?.code, .locked)
        XCTAssertEqual(nibError?.hint, "unlock it")
    }

    func testTimeoutsAndNetworkFailuresMap() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.Reply(failure: URLError(.timedOut)) }
        let local = try makeProvider(.openAICompatible, baseURL: "http://localhost:11434/v1", key: nil)
        let timeout = await expectError(local.stream(request()))
        XCTAssertEqual(timeout?.code, .timeout)
        XCTAssertEqual(timeout?.hint, "the model may still be loading — retry, or check that the server is running")

        StubURLProtocol.install { _ in StubURLProtocol.Reply(failure: URLError(.cannotConnectToHost)) }
        let unreachable = await expectError(local.stream(request()))
        XCTAssertEqual(unreachable?.code, .unavailable)
    }

    func testEndingTheIterationCancelsTheRequest() async throws {
        let firstEvents = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Adding a "}}


        """
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data(firstEvents.utf8), holdOpen: true) }
        let provider = try makeProvider(.anthropic, baseURL: "https://api.anthropic.com")
        var first: ChatEvent?
        for try await event in provider.stream(request()) {
            first = event
            break
        }
        XCTAssertEqual(first, .textDelta("Adding a "))
        let deadline = Date().addingTimeInterval(10)
        while StubURLProtocol.stopCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(StubURLProtocol.stopCount, 1, "the URLSession task is cancelled when the consumer stops")
    }

    // MARK: Models, audio and images

    func testListModels() async throws {
        StubURLProtocol.install { request in
            let page2 = request.url?.query?.contains("after_id=claude-b") ?? false
            let body = page2
                ? #"{"data":[{"type":"model","id":"claude-c"}],"has_more":false,"first_id":"claude-c","last_id":"claude-c"}"#
                : #"{"data":[{"type":"model","id":"claude-a"},{"type":"model","id":"claude-b"}],"has_more":true,"first_id":"claude-a","last_id":"claude-b"}"#
            return StubURLProtocol.Reply(headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        let anthropic = try makeProvider(.anthropic, baseURL: "https://api.anthropic.com")
        let claude = try await anthropic.listModels()
        XCTAssertEqual(claude, ["claude-a", "claude-b", "claude-c"])
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.path, "/v1/models")
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.recorded.first?.header("x-api-key"), "test-key")

        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(headers: ["Content-Type": "application/json"],
                                  body: Data(#"{"object":"list","data":[{"id":"llama3.1:8b","object":"model"},{"id":"qwen2.5:7b","object":"model"}]}"#.utf8))
        }
        let ollama = try makeProvider(.openAICompatible, baseURL: "http://localhost:11434/v1", key: nil)
        let local = try await ollama.listModels()
        XCTAssertEqual(local, ["llama3.1:8b", "qwen2.5:7b"])
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.absoluteString, "http://localhost:11434/v1/models")

        let nib = try makeProvider(.nibHTTP, baseURL: "https://agent.example.com/nib")
        do {
            _ = try await nib.listModels()
            XCTFail("the Nib Agent Protocol has no model list")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
    }

    func testTranscriptionUsesVerboseJSONSegments() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("nib-test-\(UUID().uuidString).m4a")
        try Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: audio)
        let answer = #"""
        {"task":"transcribe","language":"english","duration":9.5,"text":"Velocity is displacement over time. Welcome.",
         "segments":[{"id":0,"seek":0,"start":0.0,"end":4.0,"text":" Velocity is displacement over time."},
                     {"id":1,"seek":0,"start":4.0,"end":9.5,"text":" Welcome."}]}
        """#
        StubURLProtocol.install { _ in StubURLProtocol.Reply(headers: ["Content-Type": "application/json"], body: Data(answer.utf8)) }
        let provider = try makeProvider(.openAICompatible, baseURL: "https://api.openai.com/v1") { $0.transcriptionModel = "whisper-1" }

        let segments = try await provider.transcribe(audio: audio, language: "en-GB")
        XCTAssertEqual(segments, [TranscriptSegment(index: 0, start: 0, duration: 4, text: "Velocity is displacement over time."),
                                  TranscriptSegment(index: 1, start: 4, duration: 5.5, text: "Welcome.")])
        let sent = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertTrue(sent.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let form = String(decoding: sent.body, as: UTF8.self)
        XCTAssertTrue(form.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(form.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(form.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(form.contains("filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: audio/mp4"))

        let withoutModel = try makeProvider(.openAICompatible, baseURL: "https://api.openai.com/v1")
        do {
            _ = try await withoutModel.transcribe(audio: audio, language: nil)
            XCTFail("no transcription model configured")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
    }

    func testImageGenerationReturnsPNG() async throws {
        let png = try XCTUnwrap(ImageWire.pngData(try XCTUnwrap(tinyPNG())))
        let answer = #"{"created":1760000000,"data":[{"b64_json":""# + png.base64EncodedString() + #""}]}"#
        StubURLProtocol.install { _ in StubURLProtocol.Reply(headers: ["Content-Type": "application/json"], body: Data(answer.utf8)) }
        let provider = try makeProvider(.openAICompatible, baseURL: "https://api.openai.com/v1") { $0.imageModel = "gpt-image-1" }

        let image = try await provider.generateImage(prompt: "a droplet")
        XCTAssertEqual(image, png)
        let sent = try XCTUnwrap(StubURLProtocol.recorded.first?.json)
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.path, "/v1/images/generations")
        XCTAssertEqual(sent["model"]?.stringValue, "gpt-image-1")
        XCTAssertEqual(sent["prompt"]?.stringValue, "a droplet")
        XCTAssertEqual(sent["response_format"]?.stringValue, "b64_json")

        let anthropic = try makeProvider(.anthropic, baseURL: "https://api.anthropic.com")
        do {
            _ = try await anthropic.generateImage(prompt: "x")
            XCTFail("Anthropic has no image endpoint")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unsupported)
        }
    }

    /// A 1×1 PNG built with ImageIO (no UIKit needed).
    private func tinyPNG() -> Data? {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
