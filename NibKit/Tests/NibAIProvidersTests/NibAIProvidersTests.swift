import XCTest
import NibContracts
import NibTesting
@testable import NibAIProviders

@MainActor
final class NibAIProvidersTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-aiproviders-tests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(ProviderStore.fileName)
    }

    private func anthropicConfig(_ name: String = "Claude") -> AIProviderConfig {
        AIProviderConfig(name: name, kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-sonnet-4-5")
    }

    // MARK: Feature

    func testOpenAIHistoryNormalizesInvalidToolArgumentsWithoutChangingValidObjects() throws {
        let arguments: [JSONValue] = [.string("{bad"), .string("[1]"), .string("null"), .array([1]),
                                      .string("{\"page\":\"page:D/P\"}"), ["page": "page:D/P"]]
        for (index, argument) in arguments.enumerated() {
            let messages = OpenAIWire.messages(system: "", [ChatMessage(role: .assistant, parts: [
                .toolCall(id: "call", name: "nib_get", arguments: argument)
            ])], vision: false)
            let raw = try XCTUnwrap(messages.first?["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue)
            let parsed = try JSONValue.parse(raw)
            XCTAssertEqual(parsed, index < 4 ? .object([:]) : ["page": "page:D/P"])
        }
        XCTAssertEqual(JSONWire.arguments("{bad"), .string("{bad"), "the runner still sees the invalid original input")
    }

    func testFeatureInstallsTheProviderStore() async throws {
        let h = Harness(features: [NibAIProvidersFeature.self])
        XCTAssertEqual(NibAIProvidersFeature.id, "aiproviders")
        let store = try XCTUnwrap(h.app.services.get(ServiceKeys.aiProviders, as: AIProviderStore.self))
        XCTAssertTrue(store.configs.isEmpty)
        XCTAssertNil(store.activeID)

        let config = anthropicConfig()
        try store.save(config, apiKey: "sk-ant-test")
        XCTAssertEqual(store.configs.map(\.id), [config.id])
        XCTAssertEqual(store.activeID, config.id, "the first provider becomes the active one")
        XCTAssertEqual(Keychain.getString(service: AIProviderConfig.keychainService, account: config.keychainAccount), "sk-ant-test")
        let provider = try XCTUnwrap(store.provider(nil))
        XCTAssertTrue(provider is AnthropicProvider)
        XCTAssertEqual(provider.config.id, config.id)

        let issues = await CommandConformance.check(features: [NibAIProvidersFeature.self])
        XCTAssertEqual(issues, [])
    }

    // MARK: Store

    func testFailedKeyMutationRestoresPreviousCredential() throws {
        let secrets = FailingProviderSecrets()
        let store = ProviderStore(fileURL: nil, secrets: secrets)
        let original = anthropicConfig()
        try store.save(original, apiKey: "original-key")
        for replacement in ["replacement-key", ""] {
            secrets.failNext = true
            XCTAssertThrowsError(try store.save(original, apiKey: replacement))
            XCTAssertEqual(secrets.get(service: AIProviderConfig.keychainService, account: original.keychainAccount),
                           Data("original-key".utf8))
            XCTAssertEqual(store.configs, [original])
        }
    }

    func testFailedSaveRestoresExistingKeyForReplacementAndRemoval() throws {
        for replacement in ["replacement-key", ""] {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let secrets = InMemorySecretStore()
            let store = ProviderStore(fileURL: url, secrets: secrets)
            let original = anthropicConfig()
            try store.save(original, apiKey: "original-key")
            let saved = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            var changed = original
            changed.baseURL = URL(string: "https://another.example")!
            XCTAssertThrowsError(try store.save(changed, apiKey: replacement))
            XCTAssertEqual(store.configs, [original])
            XCTAssertEqual(store.activeID, original.id)
            XCTAssertEqual(secrets.get(service: AIProviderConfig.keychainService, account: original.keychainAccount),
                           Data("original-key".utf8))
            try FileManager.default.removeItem(at: url)
            try saved.write(to: url)
            XCTAssertEqual(ProviderStore(fileURL: url, secrets: secrets).configs, [original])
        }
    }

    func testFailedDeletePreservesProviderActiveIDAndKeyAndCanRetry() throws {
        let url = tempFile()
        let secrets = InMemorySecretStore()
        let store = ProviderStore(fileURL: url, secrets: secrets)
        let config = anthropicConfig()
        try store.save(config, apiKey: "keep-this-key")
        let saved = try Data(contentsOf: url)
        // A directory at the file destination makes the atomic write fail deterministically.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.delete(config.id)
        XCTAssertEqual(store.configs.map(\.id), [config.id])
        XCTAssertEqual(store.activeID, config.id)
        XCTAssertEqual(secrets.get(service: AIProviderConfig.keychainService, account: config.keychainAccount), Data("keep-this-key".utf8))
        try FileManager.default.removeItem(at: url)
        try saved.write(to: url)
        XCTAssertEqual(ProviderStore(fileURL: url, secrets: secrets).configs.map(\.id), [config.id])
        store.delete(config.id)
        XCTAssertTrue(store.configs.isEmpty)
        XCTAssertTrue(ProviderStore(fileURL: url, secrets: secrets).configs.isEmpty)
        XCTAssertNil(secrets.get(service: AIProviderConfig.keychainService, account: config.keychainAccount))
    }

    func testStorePersistsConfigsButNeverKeys() throws {
        let url = tempFile()
        let secrets = InMemorySecretStore()
        let store = ProviderStore(fileURL: url, secrets: secrets)
        let claude = anthropicConfig()
        let ollama = AIProviderConfig(name: " Ollama ", kind: .openAICompatible, baseURL: URL(string: "http://192.168.1.20:11434/v1")!,
                                      model: "qwen2.5:7b", supportsVision: false, transcriptionModel: "  ")
        try store.save(claude, apiKey: "  sk-ant-secret-1  ")
        try store.save(ollama, apiKey: nil)
        store.activeID = ollama.id

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("sk-ant-secret-1"), "keys never reach the configs file")
        XCTAssertEqual(secrets.get(service: AIProviderConfig.keychainService, account: claude.keychainAccount),
                       Data("sk-ant-secret-1".utf8), "keys are trimmed and stored in the secret store")

        let reopened = ProviderStore(fileURL: url, secrets: secrets)
        XCTAssertEqual(reopened.configs.map(\.id), [claude.id, ollama.id])
        XCTAssertEqual(reopened.configs[1].name, "Ollama")
        XCTAssertNil(reopened.configs[1].transcriptionModel, "blank optional models are stored as nil")
        XCTAssertEqual(reopened.activeID, ollama.id)
        XCTAssertTrue(reopened.provider(nil) is OpenAICompatibleProvider)
        XCTAssertTrue(reopened.provider(claude.id) is AnthropicProvider)
        XCTAssertNil(reopened.provider(UUID()))
    }

    func testDeleteRemovesKeyAndMovesTheActiveProvider() throws {
        let secrets = InMemorySecretStore()
        let store = ProviderStore(fileURL: tempFile(), secrets: secrets)
        let a = anthropicConfig("A")
        let b = AIProviderConfig(name: "B", kind: .nibHTTP, baseURL: URL(string: "https://agent.example.com/nib")!, model: "")
        try store.save(a, apiKey: "key-a")
        try store.save(b, apiKey: "key-b")
        XCTAssertEqual(store.activeID, a.id)

        store.delete(a.id)
        XCTAssertNil(secrets.get(service: AIProviderConfig.keychainService, account: a.keychainAccount))
        XCTAssertEqual(store.configs.map(\.id), [b.id])
        XCTAssertEqual(store.activeID, b.id)

        try store.save(b, apiKey: "")
        XCTAssertNil(secrets.get(service: AIProviderConfig.keychainService, account: b.keychainAccount), "an empty key deletes it")
        XCTAssertFalse(store.credentialsMissing(b.id), "a deleted key is not a missing one")

        store.activeID = UUID()
        XCTAssertEqual(store.activeID, b.id, "an unknown id is ignored")
    }

    func testKeyLostAfterResigningIsReportedAsMissing() async throws {
        let url = tempFile()
        let config = anthropicConfig()
        try ProviderStore(fileURL: url, secrets: InMemorySecretStore()).save(config, apiKey: "sk-ant-test")

        // A re-signed build reads the same Application Support file but sees another (empty) Keychain group.
        let resigned = ProviderStore(fileURL: url, secrets: InMemorySecretStore())
        XCTAssertTrue(resigned.credentialsMissing(config.id))
        let provider = try XCTUnwrap(resigned.provider(config.id))
        let request = ChatRequest(model: "", system: "", messages: [ChatMessage(role: .user, parts: [.text("hi")])])
        do {
            for try await _ in provider.stream(request) {}
            XCTFail("a missing key must fail the call")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertEqual(error.hint, "re-enter the API key")
        }
        do {
            _ = try await provider.listModels()
            XCTFail("a missing key must fail the call")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertEqual(error.hint, "re-enter the API key")
        }
    }

    func testValidationRejectsBadConfigs() throws {
        let store = ProviderStore(fileURL: tempFile(), secrets: InMemorySecretStore())
        var ftp = anthropicConfig()
        ftp.baseURL = URL(string: "ftp://example.com")!
        XCTAssertThrowsError(try store.save(ftp, apiKey: nil)) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            XCTAssertEqual((error as? NibError)?.path, "$.baseURL")
        }
        var unnamed = anthropicConfig()
        unnamed.name = "   "
        XCTAssertThrowsError(try store.save(unnamed, apiKey: nil)) { error in
            XCTAssertEqual((error as? NibError)?.path, "$.name")
        }
        var leaky = anthropicConfig()
        leaky.extraHeaders = ["Authorization": "Bearer sk-live"]
        XCTAssertThrowsError(try store.save(leaky, apiKey: nil)) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams, "credentials never go into the unencrypted headers")
        }
        var injected = anthropicConfig()
        injected.extraHeaders = ["X-Title": "Nib\r\nX-Evil: 1"]
        XCTAssertThrowsError(try store.save(injected, apiKey: nil))
        XCTAssertThrowsError(try store.save(anthropicConfig(), apiKey: "sk-ant “quoted”")) { error in
            XCTAssertEqual((error as? NibError)?.path, "$.apiKey")
        }
        XCTAssertTrue(store.configs.isEmpty)
    }

    func testCorruptFileIsMovedAsideInsteadOfOverwritten() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = ProviderStore(fileURL: url, secrets: InMemorySecretStore())
        XCTAssertTrue(store.configs.isEmpty)
        let aside = url.deletingLastPathComponent().appendingPathComponent("ai-providers.corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        try store.save(anthropicConfig(), apiKey: nil)
        XCTAssertEqual(ProviderStore(fileURL: url, secrets: InMemorySecretStore()).configs.count, 1)
    }

    // MARK: Line reader and SSE

    func testLineReaderHandlesEveryTerminatorAndSplitCharacters() throws {
        var reader = LineReader()
        let text = "\u{FEFF}one\r\ntwo\rthree\n\nfour — ’"
        var lines: [String] = []
        // Byte by byte, so multi-byte characters arrive split.
        for byte in Data(text.utf8) {
            if let line = try reader.push(byte) { lines.append(line) }
        }
        if let last = reader.finish() { lines.append(last) }
        XCTAssertEqual(lines, ["one", "two", "three", "", "four — ’"])
    }

    func testSSEParserFollowsTheSpec() throws {
        var parser = SSEParser()
        var reader = LineReader()
        let stream = """
        : keep-alive comment\r
        event: content_block_delta\r
        data: {"a":\r
        data:  1}\r
        id: 7\r
        \r
        data:[DONE]
        """
        var events: [SSEEvent] = []
        for line in try reader.push(Data(stream.utf8)) {
            if let e = parser.feed(line) { events.append(e) }
        }
        if let last = reader.finish(), let e = parser.feed(last) { events.append(e) }
        if let e = parser.finish() { events.append(e) }
        XCTAssertEqual(events, [
            SSEEvent(event: "content_block_delta", data: "{\"a\":\n 1}", id: "7"),
            SSEEvent(event: nil, data: "[DONE]", id: "7")
        ])
        XCTAssertEqual(events[0].pieces, ["{\"a\":\n 1}"], "one multi-line JSON document stays whole")
        XCTAssertEqual(SSEEvent(event: nil, data: "{\"x\":1}\n{\"y\":2}", id: nil).pieces, ["{\"x\":1}", "{\"y\":2}"])
    }

    // MARK: Request bodies

    func testAnthropicBodyCachesSystemAndToolsAndShapesContent() throws {
        // PNG signature + 3 bytes; base64 "iVBORw0KGgoBAgM="
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let getArgs: JSONValue = ["ref": "page:D/P"]
        let getSchema = try JSONValue.parse(#"{"type": "object", "properties": {"ref": {"type": "string"}}}"#)
        let request = ChatRequest(
            model: "", system: "You are the assistant inside Nib.\u{1E}Context: page 1",
            messages: [
                ChatMessage(role: .user, parts: [.text("Summarise"), .image(data: png, mime: "image/png"), .text("  ")]),
                ChatMessage(role: .assistant, parts: [.text("Looking."), .toolCall(id: "t1", name: "nib_get", arguments: getArgs)]),
                ChatMessage(role: .tool, parts: [.toolResult(id: "t1", parts: [.text("{\"ok\":true}")], isError: false)]),
                ChatMessage(role: .user, parts: [.text("and?")]),
                ChatMessage(role: .assistant, parts: [.toolCall(id: "t2", name: "nib_run", arguments: .object([:]))]),
                ChatMessage(role: .tool, parts: [.toolResult(id: "t2", parts: [.text("{\"error\":{}}")], isError: true)])
            ],
            tools: [ToolSpec(name: "nib_context", description: "Where the user is.", schema: .object([:])),
                    ToolSpec(name: "nib_get", description: "Any node.", schema: getSchema)],
            maxTokens: 8192, temperature: 0.5)
        let body = try AnthropicWire.body(request, config: AIProviderConfig(
            name: "Claude", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-sonnet-4-5"))

        XCTAssertEqual(body["model"]?.stringValue, "claude-sonnet-4-5")
        XCTAssertEqual(body["max_tokens"]?.intValue, 4096, "capped by maxOutputTokens")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body["temperature"]?.doubleValue, 0.5)
        let system = try JSONValue.parse(#"""
        [ {"type": "text", "text": "You are the assistant inside Nib.", "cache_control": {"type": "ephemeral"}},
          {"type": "text", "text": "Context: page 1"} ]
        """#)
        XCTAssertEqual(body["system"], system)
        let firstTool = try JSONValue.parse(#"""
        {"name": "nib_context", "description": "Where the user is.", "input_schema": {"type": "object", "properties": {}}}
        """#)
        XCTAssertEqual(body["tools"]?[0], firstTool, "only the last tool carries cache_control")
        let ephemeral: JSONValue = ["type": "ephemeral"]
        XCTAssertEqual(body["tools"]?[1]?["cache_control"], ephemeral)
        XCTAssertEqual(body["tools"]?[1]?["input_schema"], getSchema)

        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["user", "assistant", "user", "assistant", "user"])
        let first = try JSONValue.parse(#"""
        [ {"type": "text", "text": "Summarise"},
          {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgoBAgM="}} ]
        """#)
        XCTAssertEqual(messages[0]["content"], first, "blank text blocks are dropped")
        let toolUse = try JSONValue.parse(#"{"type": "tool_use", "id": "t1", "name": "nib_get", "input": {"ref": "page:D/P"}}"#)
        XCTAssertEqual(messages[1]["content"]?[1], toolUse)
        let merged = try JSONValue.parse(#"""
        [ {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "{\"ok\":true}"}]},
          {"type": "text", "text": "and?"} ]
        """#)
        XCTAssertEqual(messages[2]["content"], merged, "a tool result and the next user text merge into one user turn, results first")
        XCTAssertEqual(messages[4]["content"]?[0]?["is_error"]?.boolValue, true)
    }

    func testOpenAIBodyUsesRolesToolCallsAndDataURLs() throws {
        // JPEG signature; base64 "/9j/4AAB"
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 1])
        let renderArgs: JSONValue = ["page": "page:D/P"]
        let request = ChatRequest(
            model: "gpt-4o", system: "Rules.\u{1E}Context.",
            messages: [
                ChatMessage(role: .user, parts: [.text("Look"), .image(data: jpeg, mime: "image/jpg")]),
                ChatMessage(role: .assistant, parts: [.toolCall(id: "c1", name: "nib_render", arguments: renderArgs)]),
                ChatMessage(role: .tool, parts: [.toolResult(id: "c1", parts: [.text("{\"pxPerPt\":2}"), .image(data: jpeg, mime: "image/jpeg")],
                                                             isError: false)]),
                ChatMessage(role: .user, parts: [.text("What is it?")])
            ],
            tools: [ToolSpec(name: "nib_render", description: "Render a page.", schema: ["type": "object"])])
        let openAI = AIProviderConfig(name: "OpenAI", kind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!,
                                      model: "gpt-4o")
        let body = try OpenAIWire.body(request, config: openAI)

        let streamOptions: JSONValue = ["include_usage": true]
        XCTAssertEqual(body["stream_options"], streamOptions)
        XCTAssertEqual(body["max_completion_tokens"]?.intValue, 4096)
        XCTAssertNil(body["max_tokens"])
        let tools = try JSONValue.parse(#"""
        [ {"type": "function", "function": {"name": "nib_render", "description": "Render a page.",
                                            "parameters": {"type": "object", "properties": {}}}} ]
        """#)
        XCTAssertEqual(body["tools"], tools)
        let messages = try JSONValue.parse(#"""
        [ {"role": "system", "content": "Rules.\n\nContext."},
          {"role": "user", "content": [{"type": "text", "text": "Look"},
                                       {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAB"}}]},
          {"role": "assistant", "content": null, "tool_calls": [
              {"id": "c1", "type": "function", "function": {"name": "nib_render", "arguments": "{\"page\":\"page:D/P\"}"}}]},
          {"role": "tool", "tool_call_id": "c1", "content": "{\"pxPerPt\":2}"},
          {"role": "user", "content": [{"type": "text", "text": "Image from tool call c1:"},
                                       {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAB"}},
                                       {"type": "text", "text": "What is it?"}]} ]
        """#)
        XCTAssertEqual(body["messages"], messages)

        var ollama = openAI
        ollama.baseURL = URL(string: "http://localhost:11434/v1")!
        ollama.supportsVision = false
        ollama.supportsTools = false
        let local = try OpenAIWire.body(request, config: ollama, streamOptions: false)
        XCTAssertEqual(local["max_tokens"]?.intValue, 4096)
        XCTAssertNil(local["stream_options"])
        XCTAssertNil(local["tools"], "tools are not sent to a model without tool support")
        XCTAssertEqual(local["messages"]?[1]?["content"]?.stringValue, "Look\n" + ProviderRequests.imageOmittedNote)
    }

    func testNibAgentBodyMatchesTheProtocol() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let request = ChatRequest(
            model: "", system: "…",
            messages: [
                ChatMessage(role: .user, parts: [.text("Summarise this page"), .image(data: png, mime: "image/png")]),
                ChatMessage(role: .assistant, parts: [.toolCall(id: "c1", name: "nib_get", arguments: ["ref": "page:D/P"])]),
                ChatMessage(role: .tool, parts: [.toolResult(id: "c1", parts: [.text("{…json…}")], isError: false)])
            ],
            tools: [ToolSpec(name: "nib_get", description: "…", schema: ["type": "object"])])
        let config = AIProviderConfig(name: "Mine", kind: .nibHTTP, baseURL: URL(string: "https://agent.example.com/nib")!, model: "anything")
        let expected = try JSONValue.parse(#"""
        { "protocol": "nib-agent/1", "model": "anything", "system": "…", "maxTokens": 4096,
          "tools": [ { "name": "nib_get", "description": "…", "schema": { "type": "object" } } ],
          "messages": [
            { "role": "user", "parts": [ { "type": "text", "text": "Summarise this page" },
                                         { "type": "image", "mime": "image/png", "base64": "iVBORw0KGgo=" } ] },
            { "role": "assistant", "parts": [ { "type": "toolCall", "id": "c1", "name": "nib_get", "arguments": { "ref": "page:D/P" } } ] },
            { "role": "tool", "parts": [ { "type": "toolResult", "id": "c1", "isError": false,
                                           "parts": [ { "type": "text", "text": "{…json…}" } ] } ] } ] }
        """#)
        XCTAssertEqual(try NibAgentWire.body(request, config: config), expected)
    }

    func testOpenAIDecoderHandlesServersWithoutIndexOrIDs() throws {
        let config = AIProviderConfig(name: "P", kind: .openAICompatible, baseURL: URL(string: "http://localhost:8000/v1")!, model: "m")
        var decoder = OpenAIStreamDecoder(context: ProviderCallContext(call: .chat, config: config, timeout: 1))
        let chunks = [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"name":"nib_get","arguments":"{\"ref\":"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"name":"nib_get","arguments":"\"doc:D\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"name":"nib_context","arguments":{}}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
        ]
        var events: [ChatEvent] = []
        for chunk in chunks { events += try decoder.handle(try JSONValue.parse(chunk)) }
        events += decoder.finish()
        let getArgs: JSONValue = ["ref": "doc:D"]
        XCTAssertEqual(events, [.toolCall(id: "call_0", name: "nib_get", arguments: getArgs),
                                .toolCall(id: "call_1", name: "nib_context", arguments: .object([:])),
                                .stop(reason: "tool_use")],
                       "a repeated name continues the call; another name after complete arguments starts one; ids are made up")
        XCTAssertEqual(decoder.finish(), [], "finish is idempotent")
    }

    // MARK: Helpers

    func testToolArgumentsAreParsedLeniently() {
        XCTAssertEqual(JSONWire.arguments(""), .object([:]))
        XCTAssertEqual(JSONWire.arguments("null"), .object([:]))
        XCTAssertEqual(JSONWire.arguments(#"{"a":1}"#), ["a": 1])
        XCTAssertEqual(JSONWire.arguments(#""{\"a\":1}""#), ["a": 1], "double-encoded arguments are unwrapped")
        XCTAssertEqual(JSONWire.arguments("{\"a\":"), .string("{\"a\":"), "broken JSON is kept for the agent to report")
        XCTAssertEqual(JSONWire.arguments(JSONValue.string("{\"b\":2}")), ["b": 2])
    }

    func testEndpointsKeepBasePathAndQuery() {
        XCTAssertEqual(ProviderRequests.endpoint(URL(string: "https://openrouter.ai/api/v1/")!, "chat/completions").absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(ProviderRequests.endpoint(URL(string: "https://x.azure.com/openai/deployments/d?api-version=2024-10-21")!,
                                                 "chat/completions").absoluteString,
                       "https://x.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21")
        let anthropic = AIProviderConfig(name: "A", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com/v1")!, model: "m")
        XCTAssertEqual(AnthropicProvider.request(anthropic, key: "k", path: "messages", method: "POST", body: nil,
                                                 accept: "text/event-stream", timeout: 10).url?.absoluteString,
                       "https://api.anthropic.com/v1/messages", "a base URL ending in /v1 is not doubled")
    }

    func testLocalHostsAndStopReasons() {
        for local in ["http://localhost:11434/v1", "http://192.168.1.5:1234/v1", "http://10.0.0.2", "http://100.101.102.103:7331",
                      "http://ipad.tail1234.ts.net", "http://[::1]:8080", "http://studio.local:1234"] {
            XCTAssertTrue(ProviderHTTP.isLocal(URL(string: local)!), local)
        }
        for remote in ["https://api.openai.com/v1", "http://8.8.8.8", "http://172.32.0.1", "https://openrouter.ai/api/v1"] {
            XCTAssertFalse(ProviderHTTP.isLocal(URL(string: remote)!), remote)
        }
        XCTAssertEqual(StopReasons.normalized("tool_calls", sawToolCalls: true), "tool_use")
        XCTAssertEqual(StopReasons.normalized("stop", sawToolCalls: true), "tool_use")
        XCTAssertEqual(StopReasons.normalized("stop", sawToolCalls: false), "end_turn")
        XCTAssertEqual(StopReasons.normalized("length", sawToolCalls: false), "max_tokens")
        XCTAssertEqual(StopReasons.normalized("pause_turn", sawToolCalls: false), "pause_turn")
    }

    func testRecoveryDurationsUseLocaleAndRejectMalformedRetryAfter() {
        let french = Locale(identifier: "fr_FR")
        XCTAssertTrue(ProviderErrors.duration(12, locale: french).contains("secondes"))
        XCTAssertEqual(ProviderErrors.retryDuration("12", locale: french), ProviderErrors.duration(12, locale: french))
        XCTAssertNil(ProviderErrors.retryDuration("12 seconds of server text", locale: french))
        XCTAssertNil(ProviderErrors.retryDuration("nan", locale: french))
        XCTAssertNil(ProviderErrors.retryDuration("-1", locale: french))
    }

    func testHTTPAndTimeoutRecoveryUseFrenchMessagesHintsAndDurations() throws {
        // Exercise the actual error constructors with an isolated language bundle. No global
        // AppleLanguages mutation or dependency on the host application's catalogue is needed.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let language = root.appendingPathComponent("fr.lproj")
        try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let strings = #"""
        "%@ answered HTTP %lld." = "%@ a répondu HTTP %lld.";
        "check the API key in Settings › AI" = "vérifiez la clé API dans Réglages › IA";
        "rate limited — retry later" = "limite atteinte — réessayez plus tard";
        "Retry after %@." = "Réessayez après %@.";
        "%@ did not answer within %@." = "%@ n’a pas répondu dans un délai de %@.";
        "check the network and the base URL, then retry" = "vérifiez le réseau et l’URL de base, puis réessayez";
        "the model may still be loading — retry, or check that the server is running" = "le modèle charge peut-être encore — réessayez ou vérifiez le serveur";
        """#
        try strings.write(to: language.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let info: [String: Any] = ["CFBundleIdentifier": "app.nib.tests.french-errors",
                                   "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "fr",
                                   "CFBundleLocalizations": ["fr"]]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: root.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        let locale = Locale(identifier: "fr_FR")
        let config = AIProviderConfig(name: "P", kind: .openAICompatible,
                                      baseURL: URL(string: "https://api.example.com/v1")!, model: "m")
        let ctx = ProviderCallContext(call: .chat, config: config, timeout: 12)
        let waited = ProviderErrors.duration(12, locale: locale)
        XCTAssertTrue(waited.contains("secondes"))
        let diagnostic = "Server diagnostic: invalid key / quota exhausted"
        let body = Data("{\"error\":{\"message\":\"\(diagnostic)\"}}".utf8)
        let unauthorized = ProviderErrors.http(HTTPStatusError(status: 401, body: body, retryAfter: nil), ctx,
                                                bundle: bundle, locale: locale)
        XCTAssertEqual(unauthorized.code, .permissionDenied)
        XCTAssertEqual(unauthorized.message, "P a répondu HTTP 401.\n" + diagnostic)
        XCTAssertEqual(unauthorized.hint, "vérifiez la clé API dans Réglages › IA")
        let limited = ProviderErrors.http(HTTPStatusError(status: 429, body: body, retryAfter: "12"), ctx,
                                          bundle: bundle, locale: locale)
        XCTAssertEqual(limited.code, .unavailable)
        XCTAssertEqual(limited.message, "P a répondu HTTP 429.\n" + diagnostic + "\nRéessayez après \(waited).")
        XCTAssertEqual(limited.hint, "limite atteinte — réessayez plus tard")
        let timeout = ProviderErrors.transport(URLError(.timedOut), ctx, bundle: bundle, locale: locale)
        XCTAssertEqual(timeout.code, .timeout)
        XCTAssertEqual(timeout.message, "P n’a pas répondu dans un délai de \(waited).")
        XCTAssertEqual(timeout.hint, "vérifiez le réseau et l’URL de base, puis réessayez")
        var localConfig = config
        localConfig.baseURL = URL(string: "http://localhost:11434/v1")!
        let localContext = ProviderCallContext(call: .chat, config: localConfig, timeout: 12)
        let localTimeout = ProviderErrors.transport(URLError(.timedOut), localContext, bundle: bundle, locale: locale)
        XCTAssertEqual(localTimeout.message, timeout.message)
        XCTAssertEqual(localTimeout.hint, "le modèle charge peut-être encore — réessayez ou vérifiez le serveur")
    }

    func testErrorBodiesMapToNibErrorsWithHints() {
        let config = AIProviderConfig(name: "P", kind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m")
        let ctx = ProviderCallContext(call: .chat, config: config, timeout: 120)
        func map(_ status: Int, _ body: String) -> NibError {
            ProviderErrors.http(HTTPStatusError(status: status, body: Data(body.utf8), retryAfter: status == 429 ? "12" : nil), ctx)
        }
        let unauthorized = map(401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#)
        XCTAssertEqual(unauthorized.code, .permissionDenied)
        XCTAssertEqual(unauthorized.hint, "check the API key in Settings › AI")
        XCTAssertTrue(unauthorized.message.contains("Incorrect API key provided"))
        let model = map(404, #"{"error":{"message":"The model `gpt-9` does not exist","code":"model_not_found"}}"#)
        XCTAssertEqual(model.code, .notFound)
        XCTAssertEqual(model.hint, "pick a model from the list")
        XCTAssertEqual(map(404, "404 page not found").hint, "check the base URL in Settings › AI")
        let limited = map(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#)
        XCTAssertEqual(limited.code, .unavailable)
        XCTAssertEqual(limited.hint, "rate limited — retry later")
        XCTAssertTrue(limited.message.contains("slow down"))
        XCTAssertEqual(map(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#).code, .unavailable)
        XCTAssertEqual(map(500, "<html>oops</html>").code, .unavailable)
        XCTAssertEqual(map(400, #"{"error":"model 'x' does not support tools"}"#).code, .invalidParams)
        XCTAssertEqual(ProviderErrors.transport(URLError(.timedOut), ctx).code, .timeout)
        XCTAssertEqual(ProviderErrors.transport(URLError(.cancelled), ctx).code, .userDenied)
        XCTAssertEqual(ProviderErrors.transport(URLError(.cannotConnectToHost), ctx).code, .unavailable)
        XCTAssertEqual(ProviderErrors.map(CancellationError(), ctx).code, .userDenied)
    }
}

private final class FailingProviderSecrets: SecretStore {
    private let memory = InMemorySecretStore()
    var failNext = false

    func set(_ data: Data?, service: String, account: String) -> Bool {
        if failNext {
            failNext = false
            _ = memory.set(nil, service: service, account: account)
            return false
        }
        return memory.set(data, service: service, account: account)
    }

    func get(service: String, account: String) -> Data? { memory.get(service: service, account: account) }
}
