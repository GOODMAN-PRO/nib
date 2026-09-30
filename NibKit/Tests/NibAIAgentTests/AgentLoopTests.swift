import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import NibAIAgent

// MARK: - Test doubles

/// A provider that replays scripted rounds (fixed events, or built from the request so a round can react to the
/// previous tool result) and records every request.
final class ScriptedProvider: AIProvider {
    typealias Round = (ChatRequest) -> [ChatEvent]

    var config: AIProviderConfig
    var rounds: [Round]
    private(set) var requests: [ChatRequest] = []
    /// Round index → seconds to wait before streaming (cancellation tests).
    var delays: [Int: Double] = [:]

    init(vision: Bool = true, tools: Bool = true, _ rounds: [Round]) {
        config = AIProviderConfig(name: "Scripted", kind: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                                  model: "scripted-1", supportsVision: vision, supportsTools: tools, maxOutputTokens: 1024)
        self.rounds = rounds
    }

    convenience init(vision: Bool = true, tools: Bool = true, events: [[ChatEvent]]) {
        self.init(vision: vision, tools: tools, events.map { round in { _ in round } })
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let index = requests.count
        requests.append(request)
        let events = rounds.isEmpty ? [.textDelta("(end of script)"), .stop(reason: "end_turn")] : rounds.removeFirst()(request)
        let delay = delays[index] ?? 0
        return AsyncThrowingStream { continuation in
            let task = Task {
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
                for e in events { continuation.yield(e) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] { [config.model] }

    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] {
        [TranscriptSegment(index: 0, start: 0, duration: 2, text: "Scripted transcript")]
    }

    func generateImage(prompt: String) async throws -> Data { Fixtures.pngData }

    // Helpers for scripts

    static func call(_ id: String, _ name: String, _ arguments: JSONValue) -> ChatEvent {
        .toolCall(id: id, name: name, arguments: arguments)
    }

    static func answer(_ text: String) -> [ChatEvent] {
        [.textDelta(text), .usage(input: 100, output: 10), .stop(reason: "end_turn")]
    }

    /// The text parts of the tool results in a request's last message.
    static func toolResults(_ request: ChatRequest) -> [(id: String, text: String, isError: Bool, images: Int)] {
        guard let last = request.messages.last else { return [] }
        return last.parts.compactMap { part in
            guard case let .toolResult(id, parts, isError) = part else { return nil }
            var text = ""
            var images = 0
            for p in parts {
                switch p {
                case .text(let s): text += s
                case .image: images += 1
                default: break
                }
            }
            return (id, text, isError, images)
        }
    }
}

@MainActor
final class ScriptedProviderStore: AIProviderStore {
    let scripted: ScriptedProvider
    var configs: [AIProviderConfig] { [scripted.config] }
    var activeID: UUID?

    init(_ scripted: ScriptedProvider) {
        self.scripted = scripted
        activeID = scripted.config.id
    }

    func save(_ config: AIProviderConfig, apiKey: String?) throws {}
    func delete(_ id: UUID) {}
    func provider(_ id: UUID?) -> AIProvider? { activeID == nil ? nil : scripted }
}

@MainActor
enum AgentFixture {
    static let page2Ref = "page:FIXTUREDOC01/FIXTUREPG002"

    /// A Harness with the agent, a scripted provider and the stand-in commands the scripts call.
    static func make(_ provider: ScriptedProvider) -> (Harness, AgentService) {
        let h = Harness(features: [NibAIAgentFeature.self])
        h.app.services.set(ScriptedProviderStore(provider), for: ServiceKeys.aiProviders)
        let agent = h.app.services.ai as! AgentService
        agent.chatStore.scanInterval = 0
        registerStandIns(h)
        return (h, agent)
    }

    static func registerStandIns(_ h: Harness) {
        let addNote = CommandDescriptor(
            id: "test.addNote", title: "Add Note", summary: "Add a text box to a page.",
            params: .obj(["page": .ref, "text": .str(), "id": .str()], required: ["page", "text"]),
            examples: [["page": "page:FIXTUREDOC01/FIXTUREPG002", "text": "Note"]], effect: .edit)
        h.app.commands.register(addNote) { json, ctx in
            guard case let .page(doc, page)? = NodeRef(json["page"]?.stringValue ?? "") else {
                throw NibError.invalid("expected a page ref", path: "$.page")
            }
            let text = json["text"]?.stringValue ?? ""
            let item = try ctx.mutate { tx -> Item in
                var it = Item.makeText(TextBoxItem(frame: Frame(x: 72, y: 72, w: 200, h: 30), text: RichText(plain: text)))
                if let id = json["id"]?.stringValue { it.id = NibID(id) }
                return try tx.put(it, doc: doc, page: page)
            }
            return ["ref": .string(NodeRef.item(doc, page, item.id).description)]
        }
        let wipe = CommandDescriptor(
            id: "test.wipe", title: "Wipe Page", summary: "Delete a page's items.",
            params: .obj(["page": .ref], required: ["page"]), examples: [["page": "page:FIXTUREDOC01/FIXTUREPG002"]],
            effect: .edit, destructive: true)
        h.app.commands.register(wipe) { _, _ in ["wiped": true] }
        let bigList = CommandDescriptor(
            id: "test.bigList", title: "Big List", summary: "A long read result.", params: .obj(["count": .int()]),
            examples: [[:]], effect: .read, target: .app)
        h.app.commands.register(bigList) { json, _ in
            let n = json["count"]?.intValue ?? 400
            let rows: [JSONValue] = (0..<n).map { i in
                ["i": .number(Double(i)), "text": .string(String(repeating: "abcdefghij", count: 8))]
            }
            return ["kind": "rows", "rows": .array(rows)]
        }
        let pageText = CommandDescriptor(
            id: CommandIDs.recognizePageText, title: "Page Text", summary: "Recognised page text.",
            params: .obj(["page": .ref], required: ["page"]), examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]],
            effect: .read)
        h.app.commands.register(pageText) { json, _ in
            ["page": json["page"] ?? .null, "blocks": [["text": "Velocity is displacement over time", "source": "ink"]]]
        }
    }

    static func request(_ text: String, mode: AIMode = .edit, chat: String? = "CHATTEST0001",
                        principal: Principal = .ai("CHATTEST0001"), maxSteps: Int = 40) -> AIRequest {
        AIRequest(chatID: chat, messages: [AIMessage(role: "user", text: text)], mode: mode,
                  scope: AIScope(kind: .page, doc: Fixtures.docID, page: Fixtures.page2), principal: principal,
                  maxSteps: maxSteps)
    }

    static func note(_ text: String, id: String) -> JSONValue {
        ["page": .string(page2Ref), "text": .string(text), "id": .string(id)]
    }
}

// MARK: - Agent loop acceptance

@MainActor
final class AgentLoopTests: XCTestCase {
    typealias P = ScriptedProvider

    /// Acceptance: a scripted provider drives a 3-call turn against the Harness; the turn is ONE undo group, its
    /// items carry the chat's provenance, and it ends with `ai.turn.finished`.
    func testThreeCallTurnIsOneUndoGroupWithProvenance() async throws {
        let provider = P(events: [
            [P.call("c1", "nib_run", ["command": "test.addNote", "params": AgentFixture.note("First", id: "AINOTE000001")]),
             .usage(input: 500, output: 20), .stop(reason: "tool_use")],
            [.textDelta("Two more."),
             P.call("c2", "test__addNote", AgentFixture.note("Second", id: "AINOTE000002")),
             P.call("c3", "nib_run", ["calls": [["command": "test.addNote",
                                                  "params": AgentFixture.note("Third", id: "AINOTE000003")]]]),
             .stop(reason: "tool_use")],
            P.answer("Added three notes.")
        ])
        let (h, agent) = AgentFixture.make(provider)
        h.app.settings.set(AgentSettings.directTools, ["test.addNote", "page.add"])
        let before = try h.snapshot(Fixtures.docID)
        let depth = h.undoDepth(Fixtures.docID)
        var finished: [NibEvent] = []
        let sub = h.app.events.subscribe { e in if e.type == NibEventType.aiTurnFinished { finished.append(e) } }
        defer { sub.cancel() }

        var streamed: [String] = []
        var toolEvents: [(String, Bool)] = []
        var response: AIResponse?
        for try await event in agent.stream(AgentFixture.request("Add three notes")) {
            switch event {
            case .text(let t): streamed.append(t)
            case let .toolFinished(name, ok, _): toolEvents.append((name, ok))
            case .finished(let r): response = r
            case .failed(let e): XCTFail("turn failed: \(e)")
            case .toolStarted: break
            }
        }
        let r = try XCTUnwrap(response)
        XCTAssertEqual(r.text, "Two more.\n\nAdded three notes.")
        XCTAssertEqual(streamed.joined(), r.text)
        XCTAssertEqual(toolEvents.map(\.0), ["nib_run", "test__addNote", "nib_run"])
        XCTAssertTrue(toolEvents.allSatisfy(\.1))
        XCTAssertEqual(r.usage, AIUsage(input: 600, output: 30))
        XCTAssertEqual(r.chatID, "CHATTEST0001")
        XCTAssertEqual(Set(r.changes.created), Set(["AINOTE000001", "AINOTE000002", "AINOTE000003"].map {
            "item:FIXTUREDOC01/FIXTUREPG002/\($0)"
        }))

        // One undo group for the whole turn, recorded for the chat's principal.
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        let entry = try XCTUnwrap(h.app.bus.history.entries(Fixtures.docID).last)
        XCTAssertEqual(entry.group, r.group)
        XCTAssertEqual(entry.principal, .ai("CHATTEST0001"))
        // Provenance: everything the turn created says which chat made it.
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.createdBy == "ai:CHATTEST0001" })
        // Undo reverts the whole turn.
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(Fixtures.docID), before)

        // The requests: static + dynamic prompt, the default catalogue, results fed back.
        XCTAssertEqual(provider.requests.count, 3)
        let first = provider.requests[0]
        XCTAssertTrue(first.system.contains("\u{1E}"), "the static prompt is marked for caching")
        XCTAssertTrue(first.system.contains("Mode: Edit"))
        XCTAssertTrue(first.system.contains("Velocity is displacement over time"), "short page text is in the prompt")
        let names = first.tools.map(\.name)
        XCTAssertEqual(Array(names.prefix(9)), ToolCatalog.metaTools.map(\.name))
        XCTAssertTrue(names.contains("test__addNote"))
        XCTAssertFalse(names.contains("page__add"), "direct tools that are not installed are left out")
        let secondResults = P.toolResults(provider.requests[1])
        XCTAssertEqual(secondResults.map(\.id), ["c1"])
        XCTAssertFalse(secondResults[0].isError)
        XCTAssertTrue(secondResults[0].text.contains("\"changes\""))
        XCTAssertEqual(P.toolResults(provider.requests[2]).map(\.id), ["c2", "c3"])

        // ai.turn.finished carries the group and the changes.
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.payload?["group"]?.stringValue, r.group)
        XCTAssertEqual(finished.first?.changes?.created.count, 3)
        XCTAssertEqual(finished.first?.principal, .ai("CHATTEST0001"))

        // The conversation is stored with the document.
        XCTAssertEqual(agent.chats(doc: Fixtures.docID).map(\.id), ["CHATTEST0001"])
        XCTAssertEqual(agent.messages(chatID: "CHATTEST0001").map(\.role), ["user", "assistant"])
    }

    /// Acceptance: an error tool result (NibError JSON with a hint) lets the model correct the call and retry.
    func testErrorResultLetsTheModelRetry() async throws {
        let provider = P(events: [
            [P.call("bad", "nib_run", ["command": "test.addNote", "params": ["page": .string(AgentFixture.page2Ref)]]),
             .stop(reason: "tool_use")],
            [P.call("good", "nib_run", ["command": "test.addNote", "params": AgentFixture.note("Retried", id: "AIRETRY00001")]),
             .stop(reason: "tool_use")],
            P.answer("Done on the second try.")
        ])
        let (h, agent) = AgentFixture.make(provider)
        let r = try await agent.complete(AgentFixture.request("Add a note"))
        XCTAssertEqual(r.text, "Done on the second try.")
        XCTAssertEqual(r.changes.created, ["item:FIXTUREDOC01/FIXTUREPG002/AIRETRY00001"])

        let failed = try XCTUnwrap(P.toolResults(provider.requests[1]).first)
        XCTAssertTrue(failed.isError)
        let error = try JSONValue.parse(failed.text)["error"]
        XCTAssertEqual(error?["code"]?.stringValue, "invalid_params")
        XCTAssertEqual(error?["path"]?.stringValue, "$.text")
        XCTAssertTrue(error?["hint"]?.stringValue?.contains("commands.describe") ?? false)
        XCTAssertFalse(P.toolResults(provider.requests[2]).first?.isError ?? true)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
    }

    /// Ask mode: edit tools are not offered, and the bus refuses writes for direct calls AND inside a batch.
    func testAskModeRefusesWritesIncludingNestedBatch() async throws {
        let provider = P(events: [
            [P.call("a", "nib_run", ["command": "test.addNote", "params": AgentFixture.note("No", id: "ASKNOTE00001")]),
             P.call("b", "nib_run", ["calls": [["command": "test.bigList", "params": ["count": 2]],
                                               ["command": "test.addNote", "params": AgentFixture.note("No", id: "ASKNOTE00002")]]]),
             P.call("c", "test__addNote", AgentFixture.note("No", id: "ASKNOTE00003")),
             .stop(reason: "tool_use")],
            P.answer("I can only read in Ask mode.")
        ])
        let (h, agent) = AgentFixture.make(provider)
        h.app.settings.set(AgentSettings.directTools, ["test.addNote", "test.bigList"])
        let r = try await agent.complete(AgentFixture.request("Add a note", mode: .ask))
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertTrue(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).isEmpty)

        let tools = provider.requests[0].tools.map(\.name)
        XCTAssertTrue(tools.contains("test__bigList"))
        XCTAssertFalse(tools.contains("test__addNote"), "Ask mode offers read tools only")
        XCTAssertTrue(provider.requests[0].system.contains("Mode: Ask"))

        let results = P.toolResults(provider.requests[1])
        XCTAssertEqual(results.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(results[0].isError)
        XCTAssertEqual(try JSONValue.parse(results[0].text)["error"]?["code"]?.stringValue, "permission_denied")
        XCTAssertTrue(results[0].text.contains("Edit mode"))
        // The batch ran its read call and refused the nested write.
        let batch = try JSONValue.parse(results[1].text)["results"]?.arrayValue ?? []
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch[0]["ok"]?.boolValue, true)
        XCTAssertEqual(batch[1]["ok"]?.boolValue, false)
        XCTAssertEqual(batch[1]["error"]?["code"]?.stringValue, "permission_denied")
        XCTAssertTrue(results[2].isError, "a tool that was not offered is refused")
        XCTAssertEqual(try JSONValue.parse(results[2].text)["error"]?["code"]?.stringValue, "not_found")
    }

    /// `ai.ask` declares forwardsCalls: a read-only caller keeps the turn read-only even when it asks for edit mode;
    /// otherwise the turn runs in the caller's undo group, as the AI when the user asks.
    func testAIAskFollowsItsCaller() async throws {
        let provider = P(events: [
            [P.call("w", "nib_run", ["command": "test.addNote", "params": AgentFixture.note("Blocked", id: "ASKRO0000001")]),
             .stop(reason: "tool_use")],
            P.answer("Read-only."),
            [P.call("w2", "nib_run", ["command": "test.addNote", "params": AgentFixture.note("Written", id: "ASKRW0000001")]),
             .stop(reason: "tool_use")],
            P.answer("Written.")
        ])
        let (h, _) = AgentFixture.make(provider)
        let params: JSONValue = ["prompt": "Add a note", "mode": "edit", "scope": .string(AgentFixture.page2Ref)]

        let ro = try await h.app.bus.execute(Invocation(command: "ai.ask", params: params, principal: .ai("OUTERCHAT001"),
                                                        session: h.session, readOnly: true))
        XCTAssertEqual(ro.value["text"]?.stringValue, "Read-only.")
        XCTAssertEqual(ro.changes, ChangeSummary())
        XCTAssertTrue(P.toolResults(provider.requests[1]).first?.isError ?? false)
        XCTAssertTrue(provider.requests[0].system.contains("Mode: Ask"))

        let rw = try await h.app.bus.execute(Invocation(command: "ai.ask", params: params, principal: .user,
                                                        session: h.session, group: "ASKGROUP0001"))
        let response = try rw.value.decode(AIResponse.self)
        XCTAssertEqual(response.text, "Written.")
        XCTAssertEqual(response.group, "ASKGROUP0001")
        let chat = try XCTUnwrap(response.chatID)
        let item = try XCTUnwrap(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2).first)
        XCTAssertEqual(item.createdBy, "ai:\(chat)", "a user's ai.ask runs its tools as the AI, never as the user")
        XCTAssertEqual(h.app.bus.history.entries(Fixtures.docID).last?.group, "ASKGROUP0001")
    }

    /// Results over 20 KB are cut between list elements and paged with a cursor through the same tool.
    func testLargeResultsArePagedWithACursor() async throws {
        var firstPage: JSONValue = .null
        let provider = P([
            { _ in [P.call("l1", "nib_run", ["command": "test.bigList"]), .stop(reason: "tool_use")] },
            { request in
                firstPage = (try? JSONValue.parse(P.toolResults(request).first?.text ?? "")) ?? .null
                let cursor = firstPage["cursor"] ?? .null
                return [P.call("l2", "nib_run", ["command": "test.bigList", "cursor": cursor]), .stop(reason: "tool_use")]
            },
            { _ in P.answer("Read it all.") }
        ])
        let (_, agent) = AgentFixture.make(provider)
        _ = try await agent.complete(AgentFixture.request("List everything", mode: .ask))

        let firstText = P.toolResults(provider.requests[1]).first?.text ?? ""
        XCTAssertLessThanOrEqual(firstText.utf8.count, NibLimits.aiToolResultBytes)
        XCTAssertEqual(firstPage["truncated"]?.boolValue, true)
        XCTAssertEqual(firstPage["kind"]?.stringValue, "rows", "fields next to the list are kept")
        let shown = firstPage["rows"]?.arrayValue ?? []
        XCTAssertGreaterThan(shown.count, 50)
        XCTAssertLessThan(shown.count, 400)
        XCTAssertTrue(firstPage["cursor"]?.stringValue?.hasPrefix(ResultPager.prefix) ?? false)

        let second = try JSONValue.parse(P.toolResults(provider.requests[2]).first?.text ?? "")
        let next = second["rows"]?.arrayValue ?? []
        XCTAssertEqual(next.first?["i"]?.intValue, shown.count, "the next page starts where the first stopped")
        XCTAssertFalse(next.isEmpty)
    }

    /// nib_render: vision models get a PNG (long edge ≤ 1568 px, mapping adjusted); others get the page text.
    func testRenderGivesImagesToVisionModelsAndTextToOthers() async throws {
        for vision in [true, false] {
            let provider = P(vision: vision, events: [
                [P.call("r", "nib_render", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "marks": true]), .stop(reason: "tool_use")],
                P.answer("I see it.")
            ])
            let (h, agent) = AgentFixture.make(provider)
            let big = UIImage(cgImage: FakeRenderer.blank(CGSize(width: 2000, height: 1000))).pngData()!
            let asset = try h.assets.putTemporary(big, ext: "png")
            let render = CommandDescriptor(
                id: CommandIDs.renderPage, title: "Render", summary: "Render a page.",
                params: .obj(["page": .ref, "marks": .bool(), "region": .rect, "scale": .num()], required: ["page"]),
                examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]], effect: .read)
            h.app.commands.register(render) { _, _ in
                ["asset": .string("tmp:" + asset.name), "pxPerPt": 2, "region": [0, 0, 1000, 500],
                 "marks": ["1": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"]]
            }
            _ = try await agent.complete(AgentFixture.request("What is on page 1?", mode: .ask))
            let result = try XCTUnwrap(P.toolResults(provider.requests[1]).first)
            XCTAssertFalse(result.isError)
            let mapping = try JSONValue.parse(result.text)
            if vision {
                XCTAssertEqual(result.images, 1)
                XCTAssertEqual(mapping["imageSize"]?[0]?.intValue, 1568)
                XCTAssertEqual(mapping["pxPerPt"]?.doubleValue ?? 0, 2 * 1568.0 / 2000.0, accuracy: 0.001)
                XCTAssertEqual(mapping["marks"]?["1"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01")
            } else {
                XCTAssertEqual(result.images, 0)
                XCTAssertTrue(result.text.contains("Velocity is displacement over time"))
                XCTAssertTrue(result.text.contains("cannot see images"))
            }
        }
    }

    /// The loop stops after maxSteps tool rounds: the last results tell the model to answer, later calls never run.
    func testStepLimitStopsTheLoop() async throws {
        let loop: ScriptedProvider.Round = { _ in
            [P.call(UUID().uuidString, "nib_run", ["command": "test.bigList", "params": ["count": 1]]), .stop(reason: "tool_use")]
        }
        let provider = P([loop, loop, loop])
        let (_, agent) = AgentFixture.make(provider)
        let r = try await agent.complete(AgentFixture.request("Loop forever", mode: .ask, maxSteps: 2))
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertTrue(r.text.hasSuffix("(Stopped after 2 tool steps.)"))
        let lastMessage = try XCTUnwrap(provider.requests[2].messages.last)
        XCTAssertTrue(lastMessage.parts.contains { part in
            if case .text(let t) = part { return t.contains("limit of 2 tool steps") }
            return false
        })
    }

    /// Cancelling a chat stops the turn; the stream still finishes with what was done so far.
    func testCancelStopsTheTurn() async throws {
        let provider = P(events: [P.answer("Too late.")])
        provider.delays[0] = 10
        let (_, agent) = AgentFixture.make(provider)
        let started = Date()
        let consumer = Task { @MainActor () -> AIResponse? in
            var last: AIResponse?
            for try await event in agent.stream(AgentFixture.request("Slow question", mode: .ask)) {
                if case .finished(let r) = event { last = r }
            }
            return last
        }
        for _ in 0..<100 where provider.requests.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(provider.requests.count, 1)
        agent.cancel(chatID: "CHATTEST0001")
        let response = try await consumer.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(response?.text, "")
        let stored = agent.chatStore.messages("CHATTEST0001")
        XCTAssertEqual(stored.last?.cancelled, true)
    }

    /// Confirmations follow `security.ai.confirmationPolicy` (set with gateway.setPolicy for the "ai" kind); a denied
    /// confirmation reaches the model as user_denied.
    func testConfirmationPolicyAndDenial() async throws {
        let provider = P(events: [
            [P.call("d", "nib_run", ["command": "test.wipe", "params": ["page": .string(AgentFixture.page2Ref)]]),
             .stop(reason: "tool_use")],
            P.answer("You declined, so I stopped.")
        ])
        let (h, agent) = AgentFixture.make(provider)
        XCTAssertEqual(h.app.gateway.policy(.ai("any")), .destructive)
        h.app.settings.set(NibSettings.aiConfirmationPolicy, .always)
        XCTAssertEqual(h.app.gateway.policy(.ai("any")), .always)
        h.app.settings.set(NibSettings.aiConfirmationPolicy, .destructive)

        h.confirmer.decision = .deny
        let r = try await agent.complete(AgentFixture.request("Clear the page"))
        XCTAssertEqual(h.confirmer.requests.map(\.command.id), ["test.wipe"])
        XCTAssertEqual(h.confirmer.requests.first?.principal, .ai("CHATTEST0001"))
        let result = try XCTUnwrap(P.toolResults(provider.requests[1]).first)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try JSONValue.parse(result.text)["error"]?["code"]?.stringValue, "user_denied")
        XCTAssertEqual(r.text, "You declined, so I stopped.")
    }
}
