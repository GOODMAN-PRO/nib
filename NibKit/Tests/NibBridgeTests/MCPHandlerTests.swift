import XCTest
import NibContracts
import NibTesting
@testable import NibBridge

/// Golden JSON-RPC request/response pairs through the transport-free MCPHandler (docs/AI.md §9.3).
@MainActor
final class MCPHandlerTests: XCTestCase {
    private let base = "http://127.0.0.1:7331"

    private func make() throws -> (Harness, BridgeController) {
        let h = Harness(features: [NibBridgeFeature.self])
        BridgeTestCommands.register(in: h.app)
        return (h, try BridgeController.resolve(h.app.services))
    }

    private func post(_ mcp: MCPHandler, _ body: String, session: String? = nil,
                      headers extra: [String: String] = [:]) async -> HTTPResponse {
        var headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        if let s = session { headers["Mcp-Session-Id"] = s }
        for (k, v) in extra { headers[k] = v }
        return await mcp.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8)), baseURL: base)
    }

    private func json(_ r: HTTPResponse) throws -> JSONValue {
        try JSONValue.parse(String(decoding: r.body, as: UTF8.self))
    }

    private func assertGolden(_ r: HTTPResponse, _ expected: String, status: Int = 200,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, status, file: file, line: line)
        XCTAssertEqual(try json(r), try JSONValue.parse(expected), file: file, line: line)
    }

    /// initialize → session id for "claude-code"; returns the Mcp-Session-Id.
    private func initialize(_ mcp: MCPHandler, client: String = "claude-code") async throws -> String {
        let r = await post(mcp, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"\#(client)","version":"2.0"}}}"#)
        return try XCTUnwrap(r.header("Mcp-Session-Id"))
    }

    /// The text of a tools/call result's first content part, parsed as JSON.
    private func toolText(_ r: HTTPResponse, part: Int = 0) throws -> JSONValue {
        let text = try XCTUnwrap(try json(r)["result"]?["content"]?[part]?["text"]?.stringValue)
        return try JSONValue.parse(text)
    }

    func testInitializeNegotiatesProtocolAndStartsASession() async throws {
        let (_, c) = try make()
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.0"}}}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "application/json")
        let sid = try XCTUnwrap(r.header("Mcp-Session-Id"))
        XCTAssertEqual(c.mcp.sessions[sid]?.client, "claude-code")
        guard case .object(var body) = try json(r), case .object(var result)? = body["result"] else { return XCTFail("no result") }
        let instructions = try XCTUnwrap(result.removeValue(forKey: "instructions")?.stringValue)
        XCTAssertTrue(instructions.hasPrefix("You are the assistant inside Nib"))
        XCTAssertTrue(instructions.contains("- bridge (2): bridge.setEnabled, bridge.status"))
        XCTAssertNotNil(result["serverInfo"]?["version"]?.stringValue)
        result["serverInfo"] = ["name": "nib"]
        body["result"] = .object(result)
        XCTAssertEqual(JSONValue.object(body), try JSONValue.parse(#"""
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18",
             "capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"nib"}}}
            """#))

        let old = await post(c.mcp, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        XCTAssertEqual(try json(old)["result"]?["protocolVersion"], "2024-11-05")
        let future = await post(c.mcp, #"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(try json(future)["result"]?["protocolVersion"], "2025-06-18")
    }

    func testNotificationsAndPing() async throws {
        let (_, c) = try make()
        let sid = try await initialize(c.mcp)
        let note = await post(c.mcp, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: sid)
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)
        try assertGolden(await post(c.mcp, #"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#, session: sid),
                         #"{"jsonrpc":"2.0","id":"p1","result":{}}"#)
    }

    func testToolsListIsTheSharedCatalogueForTheBridgePlusEvents() async throws {
        let (h, c) = try make()
        h.app.commands.register(CommandDescriptor(
            id: "page.add", title: "Add Page", summary: "Test stand-in for page.add.",
            params: .obj(["doc": .ref], required: ["doc"]), examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)) { _, _ in [:] }
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(try json(r)["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        let expected = ToolCatalog.metaTools.map { $0.name } + ["page__add", "nib_events"]
        XCTAssertEqual(names, expected)
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"], "object", "\(t)")
            XCTAssertFalse(t["description"]?.stringValue?.isEmpty ?? true)
        }
        XCTAssertEqual(tools.last?["inputSchema"]?["properties"]?["wait"]?["maximum"], 25)
    }

    func testToolsCallRunsAsTheBridgeClient() async throws {
        let (_, c) = try make()
        let sid = try await initialize(c.mcp)
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.whoami","params":{}}}}"#, session: sid)
        try assertGolden(r, #"""
            {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"principal\":\"bridge:claude-code\"}"}],"isError":false}}
            """#)
        XCTAssertEqual(c.status().lastCall?.command, "test.whoami")
        XCTAssertEqual(c.status().clients.first?.name, "claude-code")
    }

    func testToolsCallErrorIsAnErrorResult() async throws {
        let (_, c) = try make()
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nib_command_schema","arguments":{"id":"nope.missing"}}}"#)
        try assertGolden(r, #"""
            {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text",
             "text":"{\"error\":{\"code\":\"not_found\",\"hint\":\"call commands.list\",\"message\":\"unknown command 'nope.missing'\"}}"}],
             "isError":true}}
            """#)
        XCTAssertEqual(c.status().lastCall?.error, "not_found")
    }

    func testMutationsReportChangesAndAreOneUndoStepOfTheClient() async throws {
        let (h, c) = try make()
        let sid = try await initialize(c.mcp)
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"nib_run","arguments":{"calls":[{"command":"test.rename","params":{"page":"page:FIXTUREDOC01/FIXTUREPG001","title":"A"}},{"command":"test.rename","params":{"page":"page:FIXTUREDOC01/FIXTUREPG002","title":"B"}}]}}}"#, session: sid)
        XCTAssertEqual(try json(r)["result"]?["isError"], false)
        let updated = try toolText(r)["changes"]?["updated"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertEqual(Set(updated), ["page:FIXTUREDOC01/FIXTUREPG001", "page:FIXTUREDOC01/FIXTUREPG002"])
        let entries = h.app.bus.history.entries(Fixtures.docID)
        XCTAssertEqual(entries.count, 1, "a tools/call is one undo group")
        XCTAssertEqual(entries.last?.principal, .bridge("claude-code"))
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.title)
    }

    func testDestructiveCallsAreConfirmedOnTheDeviceAndDenialIsReported() async throws {
        let (h, c) = try make()
        let sid = try await initialize(c.mcp)
        let call = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.wipe","params":{"page":"page:FIXTUREDOC01/FIXTUREPG001"}}}}"#
        h.confirmer.decision = .deny
        let denied = await post(c.mcp, call, session: sid)
        XCTAssertEqual(try json(denied)["result"]?["isError"], true)
        XCTAssertEqual(try toolText(denied)["error"]?["code"], "user_denied")
        XCTAssertEqual(h.confirmer.requests.last?.principal, .bridge("claude-code"))
        XCTAssertEqual(h.confirmer.requests.last?.command.id, "test.wipe")
        h.confirmer.decision = .allow
        let allowed = await post(c.mcp, call, session: sid)
        XCTAssertEqual(try json(allowed)["result"]?["isError"], false)
        XCTAssertEqual(h.confirmer.requests.count, 2)
    }

    func testRenderIsAnImageResultWithAnAssetLink() async throws {
        let (h, c) = try make()
        Keychain.set(Data(BridgeTestCommands.token.utf8), service: BridgeSecrets.service, account: BridgeSecrets.account)
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"nib_render","arguments":{"page":"page:FIXTUREDOC01/FIXTUREPG001"}}}"#)
        let result = try XCTUnwrap(try json(r)["result"])
        XCTAssertEqual(result["isError"], false)
        let image = try XCTUnwrap(result["content"]?[0])
        XCTAssertEqual(image["type"], "image")
        XCTAssertEqual(image["mimeType"], "image/png")
        XCTAssertEqual(image["data"]?.stringValue, Fixtures.pngData.base64EncodedString())
        let mapping = try toolText(r, part: 1)
        XCTAssertEqual(mapping["pxPerPt"], 2)
        XCTAssertEqual(mapping["region"], [0, 0, 595, 842])
        let link = try XCTUnwrap(mapping["asset"]?.stringValue)
        XCTAssertTrue(link.hasPrefix(base + "/api/v1/assets/"), link)

        let path = String(link.dropFirst(base.count))
        let download = await c.router.route(HTTPRequest(method: "GET", path: path,
                                                        headers: ["Authorization": "Bearer " + BridgeTestCommands.token]),
                                            remote: BridgeIP.parse("127.0.0.1"))
        XCTAssertEqual(download.status, 200)
        XCTAssertEqual(download.header("Content-Type"), "image/png")
        XCTAssertEqual(download.body, Fixtures.pngData)
        XCTAssertEqual(h.app.commands.descriptor("render.page")?.effect, .read)
    }

    func testProtocolErrors() async throws {
        let (_, c) = try make()
        try assertGolden(await post(c.mcp, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#),
                         #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found: resources/list"}}"#)
        try assertGolden(await post(c.mcp, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#),
                         #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Batch requests are not supported; send one message per POST"}}"#,
                         status: 400)
        try assertGolden(await post(c.mcp, "not json"),
                         #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: the body is not JSON"}}"#, status: 400)
        try assertGolden(await post(c.mcp, #"{"id":4,"method":"ping"}"#),
                         #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: expected a JSON-RPC 2.0 message"}}"#,
                         status: 400)
        try assertGolden(await post(c.mcp, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nib_nope"}}"#),
                         #"{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Unknown tool: nib_nope"}}"#)
        try assertGolden(await post(c.mcp, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#),
                         #"{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"tools/call needs params.name"}}"#)
    }

    func testSessionLifecycle() async throws {
        let (_, c) = try make()
        let sid = try await initialize(c.mcp)
        try assertGolden(await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, session: "nope"),
                         #"{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Session not found; send initialize again"}}"#,
                         status: 404)
        let badVersion = await post(c.mcp, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, session: sid,
                                    headers: ["MCP-Protocol-Version": "1999-01-01"])
        XCTAssertEqual(badVersion.status, 400)
        let get = await c.mcp.handle(HTTPRequest(method: "GET", path: "/mcp"), baseURL: base)
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.header("Allow"), "POST, DELETE")
        XCTAssertEqual(c.status().clients.first?.sessions, 1)
        let delete = await c.mcp.handle(HTTPRequest(method: "DELETE", path: "/mcp", headers: ["Mcp-Session-Id": sid]), baseURL: base)
        XCTAssertEqual(delete.status, 200)
        XCTAssertNil(c.mcp.sessions[sid])
        XCTAssertEqual(c.status().clients.first?.sessions, 0)
        let ended = await post(c.mcp, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, session: sid)
        XCTAssertEqual(ended.status, 404)
        let again = await c.mcp.handle(HTTPRequest(method: "DELETE", path: "/mcp", headers: ["Mcp-Session-Id": sid]), baseURL: base)
        XCTAssertEqual(again.status, 404)
    }

    func testResultsOver20KBArePagedWithACursor() async throws {
        let (_, c) = try make()
        let r1 = await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.big","params":{}}}}"#)
        let parts1 = try XCTUnwrap(try json(r1)["result"]?["content"]?.arrayValue)
        XCTAssertEqual(parts1.count, 2)
        var text = try XCTUnwrap(parts1[0]["text"]?.stringValue)
        XCTAssertLessThanOrEqual(text.utf8.count, 20_000)
        var more = try JSONValue.parse(try XCTUnwrap(parts1[1]["text"]?.stringValue))
        var pagesRead = 1
        while more["truncated"] == true, let cursor = more["cursor"]?.stringValue {
            let next = await post(c.mcp, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nib_run","arguments":{"cursor":"\#(cursor)"}}}"#)
            let parts = try XCTUnwrap(try json(next)["result"]?["content"]?.arrayValue)
            text += try XCTUnwrap(parts[0]["text"]?.stringValue)
            more = [:]
            if parts.count > 1 { more = try JSONValue.parse(try XCTUnwrap(parts[1]["text"]?.stringValue)) }
            pagesRead += 1
            XCTAssertLessThan(pagesRead, 10)
        }
        XCTAssertEqual(pagesRead, 4, "about 62.5 KB of JSON in pages of at most 20 KB")
        XCTAssertEqual(try JSONValue.parse(text)["text"]?.stringValue, BridgeTestCommands.bigText)
        let expired = await post(c.mcp, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nib_run","arguments":{"cursor":"nibr:NOPE:10"}}}"#)
        XCTAssertEqual(try json(expired)["result"]?["isError"], true)
    }

    func testEventsLongPollSkipsLockedDocumentsAndBridgeStatus() async throws {
        let (h, c) = try make()
        let start = h.app.events.lastSeq
        h.app.gateway.isLocked = { $0 == Fixtures.whiteboardID }
        h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.whiteboardID)
        h.app.events.emit(BridgeController.statusEvent)
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nib_events","arguments":{"since":\#(start),"wait":0}}}"#)
        let body = try toolText(r)
        let events = try XCTUnwrap(body["events"]?.arrayValue)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"]?.stringValue, NibEventType.pageChanged)
        XCTAssertEqual(events.first?["doc"]?.stringValue, Fixtures.docID.raw)
        XCTAssertEqual(body["last"]?.intValue, Int(h.app.events.lastSeq))

        let last = try XCTUnwrap(body["last"]?.intValue)
        let t0 = Date()
        let empty = await post(c.mcp, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nib_events","arguments":{"since":\#(last),"wait":0.3}}}"#)
        XCTAssertEqual(try toolText(empty)["events"], [])
        XCTAssertEqual(try toolText(empty)["last"]?.intValue, last)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.25, "waits for new events")
    }

    func testToolCallTimeoutAndConfirmationDeadline() async throws {
        let (h, c) = try make()
        c.mcp.toolTimeout = 0.2
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.slow","params":{}}}}"#)
        XCTAssertEqual(try toolText(r)["error"]?["code"], "timeout")

        // A confirmation nobody answers is denied after the confirmer's timeout (115 s in the app).
        let silent = SilentPresenter()
        c.confirmer.inner = silent
        c.confirmer.timeout = 0.1
        c.mcp.toolTimeout = 5
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.wipe","params":{"page":"page:FIXTUREDOC01/FIXTUREPG001"}}}}"#
        let unanswered = await post(c.mcp, call)
        XCTAssertEqual(try toolText(unanswered)["error"]?["code"], "user_denied")
        XCTAssertEqual(silent.asked, 1)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "denied: nothing ran")
    }

    func testAnAllowAfterTheToolTimeoutChangesNothing() async throws {
        let (h, c) = try make()
        let late = SilentPresenter()
        late.delay = 0.4
        c.confirmer.inner = late
        c.mcp.toolTimeout = 0.2
        let r = await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.wipe","params":{"page":"page:FIXTUREDOC01/FIXTUREPG001","title":"Late"}}}}"#)
        XCTAssertEqual(try toolText(r)["error"]?["code"], "timeout")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(late.asked, 1)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0, "the agent was told timeout, so the late Allow is a Deny")
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.title)
    }

    func testAssetLinksInResultsRoundTripIntoURLParameters() async throws {
        let (_, c) = try make()
        let upload = await post(c.mcp, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.upload","params":{}}}}"#)
        let uploaded = try toolText(upload)
        let link = try XCTUnwrap(uploaded["ref"]?.stringValue)
        XCTAssertTrue(link.hasPrefix(base + "/api/v1/assets/"), "results carry download links: \(link)")
        let name = try XCTUnwrap(uploaded["name"]?.stringValue)

        let use = await post(c.mcp, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nib_run","arguments":{"command":"test.useFile","params":{"url":"\#(link)"}}}}"#)
        XCTAssertEqual(try json(use)["result"]?["isError"], false, String(decoding: use.body, as: UTF8.self))
        let used = try toolText(use)
        XCTAssertEqual(used["scheme"], "tmp", "the link is the tmp: ref again, which a bridge principal may read")
        XCTAssertEqual(used["name"]?.stringValue, name)
        XCTAssertEqual(used["bytes"]?.intValue, Fixtures.pngData.count)

        let stranger: JSONValue = ["url": "http://x/api/v1/assets/unknown", "n": 1]
        XCTAssertEqual(c.mcp.unrewrite(stranger), stranger, "unknown or expired links stay as they are")
    }

    func testIdleSessionsExpireAndEvictedSessionsLeaveTheStatus() async throws {
        let (_, c) = try make()
        var now = Date()
        c.mcp.now = { now }
        let idle = try await initialize(c.mcp, client: "idle")
        now = now.addingTimeInterval(MCPHandler.sessionIdle + 1)
        let fresh = try await initialize(c.mcp)
        XCTAssertNil(c.mcp.sessions[idle], "a session idle for 30 minutes ends")
        XCTAssertEqual(c.status().clients.first { $0.name == "idle" }?.sessions, 0)

        for _ in 0..<MCPHandler.maxSessions {
            now = now.addingTimeInterval(1)
            _ = try await initialize(c.mcp)
        }
        XCTAssertEqual(c.mcp.sessions.count, MCPHandler.maxSessions)
        XCTAssertNil(c.mcp.sessions[fresh], "the least recently seen session is evicted")
        XCTAssertEqual(c.status().clients.first { $0.name == "claude-code" }?.sessions, MCPHandler.maxSessions)
    }
}

/// A presenter that answers Allow only after `delay` seconds (60 s: nobody at the device).
@MainActor
final class SilentPresenter: ConfirmationPresenter {
    private(set) var asked = 0
    var delay: TimeInterval = 60
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        asked += 1
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return .allow
    }
}

/// JSON-level stand-ins for other features' commands, registered after the feature (owner "builtin").
@MainActor
enum BridgeTestCommands {
    static let token = "nib_" + String(repeating: "A", count: 43)
    static let bigText = String(repeating: "Kinematics — SUVAT ✓ ", count: 2_500)

    static func register(in app: NibApp) {
        app.commands.register(CommandDescriptor(
            id: "test.whoami", title: "Who", summary: "Test: returns the caller's principal.", examples: [[:]],
            effect: .read, target: .app)) { _, ctx in
            ["principal": .string(ctx.principal.description)]
        }
        app.commands.register(CommandDescriptor(
            id: "test.big", title: "Big", summary: "Test: returns about 60 KB of text.", examples: [[:]],
            effect: .read, target: .app)) { _, _ in
            ["text": .string(bigText)]
        }
        app.commands.register(CommandDescriptor(
            id: "test.slow", title: "Slow", summary: "Test: takes two seconds.", examples: [[:]],
            effect: .read, target: .app)) { _, _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [:]
        }
        let pageParams = JSONSchema.obj(["page": .ref, "title": .str()], required: ["page"])
        app.commands.register(CommandDescriptor(
            id: "test.rename", title: "Rename Page", summary: "Test: sets a page title.", params: pageParams,
            examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "title": "T"]], effect: .edit)) { p, ctx in
            try setTitle(p, ctx)
            return [:]
        }
        app.commands.register(CommandDescriptor(
            id: "test.wipe", title: "Wipe Page Title", summary: "Test: a destructive edit.", params: pageParams,
            examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]], effect: .edit, destructive: true)) { p, ctx in
            try setTitle(p, ctx)
            return [:]
        }
        app.commands.register(CommandDescriptor(
            id: "test.upload", title: "Upload", summary: "Test stand-in for asset.upload: stores bytes, returns a tmp: ref.",
            examples: [[:]], effect: .read, target: .app)) { _, ctx in
            let asset = try ctx.services.require(ctx.services.assets, "assets").putTemporary(Fixtures.pngData, ext: "png")
            return ["ref": .string("tmp:" + asset.name), "name": .string(asset.name)]
        }
        app.commands.register(CommandDescriptor(
            id: "test.useFile", title: "Use File", summary: "Test stand-in for image.insert: reads its url with inputFile.",
            params: .obj(["url": .str()], required: ["url"]), examples: [["url": "tmp:x.png"]],
            effect: .read, target: .app)) { p, ctx in
            let url = p["url"]?.stringValue ?? ""
            let data = try Data(contentsOf: try await ctx.inputFile(url))
            return ["scheme": .string(url.hasPrefix("tmp:") ? "tmp" : "other"), "name": .string(String(url.dropFirst(4))),
                    "bytes": .number(Double(data.count))]
        }
        app.commands.register(CommandDescriptor(
            id: "render.page", title: "Render Page", summary: "Test stand-in for F004's render.page.",
            params: .obj(["page": .ref], required: ["page"]), examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]],
            effect: .read)) { _, ctx in
            let asset = try ctx.services.require(ctx.services.assets, "assets").putTemporary(Fixtures.pngData, ext: "png")
            return ["asset": .string("tmp:" + asset.name), "pxPerPt": 2, "region": [0, 0, 595, 842]]
        }
    }

    private static func setTitle(_ p: JSONValue, _ ctx: CommandContext) throws {
        guard case let .page(doc, pid)? = NodeRef(p["page"]?.stringValue ?? "") else {
            throw NibError.invalid("expected a page ref", path: "$.page")
        }
        try ctx.mutate { tx in
            guard var page = try tx.content(doc).page(pid) else { throw NibError.notFound("page \(pid)") }
            page.title = p["title"]?.stringValue
            _ = try tx.put(page, doc: doc)
        }
    }
}
