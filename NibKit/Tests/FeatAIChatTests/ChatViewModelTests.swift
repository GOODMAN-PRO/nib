import XCTest
import NibContracts
import NibTesting
@testable import FeatAIChat

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testStreamBecomesMessagesWithScopeAndOneTurnGroup() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let ai = FakeAIService(responses: [.init(text: "The answer cites page:FIXTUREDOC01/FIXTUREPG001.")])
        h.app.services.ai = ai
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try model.setScope(.page)
        _ = try await model.send(prompt: "Explain this page", principal: .user, group: "FIXTUREGROUP1")
        XCTAssertEqual(model.entries.map(\.role), ["user", "assistant"])
        XCTAssertEqual(model.entries.last?.text, "The answer cites page:FIXTUREDOC01/FIXTUREPG001.")
        XCTAssertEqual(ai.requests.first?.scope?.page, Fixtures.page1)
        XCTAssertEqual(ai.requests.first?.group, "FIXTUREGROUP1")
        XCTAssertEqual(ai.requests.first?.mode, .ask)
        XCTAssertFalse(model.isStreaming)
        XCTAssertNil(model.retryPrompt)
        if case .ai = ai.requests.first?.principal {} else { XCTFail("user turns must execute tools as AI") }
    }

    func testUndoCallsRevertGroupAndKeepsLaterEdits() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: "test.change", title: "Change text", summary: "Change the text item.", effect: .edit)) { p, ctx in
            let name = p["ref"]?.stringValue ?? "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"
            guard case let .item(d, page, id)? = NodeRef(name) else { throw NibError.invalid("item ref") }
            try ctx.mutate { tx in
                var item = try ctx.workspace.item(d, page: page, id: id)
                var fields = item.ext ?? [:]
                fields["test"] = p["value"] ?? "AI"
                item.ext = fields
                try tx.put(item, doc: d, page: page)
            }
            return [:]
        }
        let ai = FakeAIService(responses: [.init(text: "Updated two items", toolCalls: [
            ("test.change", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"]),
            ("test.change", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"])
        ])], bus: h.app.bus)
        h.app.services.ai = ai
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        _ = try await model.send(prompt: "Update", principal: .user, group: "FIXTUREGROUP2")
        let receipt = try XCTUnwrap(model.entries.last)
        XCTAssertEqual(receipt.changes.count, 2)
        _ = try await h.run("test.change", ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "value": "later"])
        var calls = 0
        h.app.bus.hooks.register(CommandHookDescriptor(id: "test.observeUndo", owner: "test", commands: [CommandIDs.revertGroup]) { _, p in
            calls += 1
            XCTAssertEqual(p["group"]?.stringValue, "FIXTUREGROUP2")
            return nil
        })
        let result = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result["reverted"]?.intValue, 1)
        XCTAssertEqual(result["skipped"]?.intValue, 1)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).ext?["test"], "later")
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).ext?["test"])
        XCTAssertTrue(model.entries.last?.reverted == true)
    }

    func testToolTraceUsageFailureAndRetryPreserveThread() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.events = [.text("Partial"), .toolStarted(name: "query.get", arguments: ["ref": "doc:FIXTUREDOC01"]),
                          .toolFinished(name: "query.get", ok: true, changes: nil), .failed(NibError(.unavailable, "offline"))]
        h.app.services.ai = service
        let model = ChatRuntime.get(h.app).model(for: h.session)
        do { _ = try await model.send(prompt: "Read", principal: .user, group: "G1"); XCTFail("expected failure") } catch {}
        XCTAssertEqual(model.entries.last?.text, "Partial")
        XCTAssertEqual(model.entries.last?.tools.first?.succeeded, true)
        XCTAssertNotNil(model.retryPrompt)
        service.events = [.text("Recovered"), .finished(AIResponse(text: "Recovered", usage: AIUsage(input: 12, output: 8)))]
        _ = try await model.send(prompt: "Read", principal: .user, group: "G2", retry: true)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.entries.last?.text, "Recovered")
        XCTAssertEqual(model.tokenCount, 20)
        XCTAssertNil(model.error)
    }

    func testStopDoesNotAcceptLateStreamEvents() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.suspended = true
        h.app.services.ai = service
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let turn = Task { try await model.send(prompt: "Wait", principal: .user, group: "G1") }
        for _ in 0..<20 where !model.isStreaming { await Task.yield() }
        XCTAssertTrue(model.isStreaming)
        model.stop()
        service.continuation?.yield(.finished(AIResponse(text: "Late")))
        service.continuation?.finish()
        do { _ = try await turn.value; XCTFail("cancelled stream") } catch {}
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(service.cancelled, model.chatID)
        XCTAssertNotEqual(model.entries.last?.text, "Late")
    }

    func testStopRetainsCommittedChangesBeforeToolFinishedArrives() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.suspended = true
        h.app.services.ai = service
        h.app.commands.register(CommandDescriptor(id: "test.partialCommit", title: "Update item", summary: "Update a fixture item.", effect: .edit)) { _, ctx in
            var item = try ctx.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            item.ext = ["partial": true]
            try ctx.mutate { tx in try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1) }
            return [:]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let before = try h.snapshotAll()
        let turn = Task { try await model.send(prompt: "Update", principal: .user, group: "PARTIALCOMMIT") }
        for _ in 0..<20 where !model.isStreaming { await Task.yield() }
        let chat = try XCTUnwrap(model.chatID)
        _ = try await h.app.bus.execute(Invocation(command: "test.partialCommit", principal: .ai(chat), session: h.session, group: "PARTIALCOMMIT"))
        model.stop()
        service.continuation?.finish()
        _ = try? await turn.value
        let receipt = try XCTUnwrap(model.entries.last)
        XCTAssertEqual(receipt.changes.count, 1)
        _ = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testCancelledMultiDocumentTurnStaysOneLinkedUndoStep() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.suspended = true
        h.app.services.ai = service
        h.app.commands.register(CommandDescriptor(id: "test.twoDocuments", title: "Update items", summary: "Update two fixture documents.", effect: .edit)) { _, ctx in
            var first = try ctx.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            var second = try ctx.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID)
            first.ext = ["partial": true]
            second.ext = ["partial": true]
            try ctx.mutate { tx in
                try tx.put(first, doc: Fixtures.docID, page: Fixtures.page1)
                try tx.put(second, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
            }
            return [:]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let before = try h.snapshotAll()
        let turn = Task { try await h.run(ChatCommand.send, ["prompt": "Update both documents"]) }
        for _ in 0..<20 where !model.isStreaming { await Task.yield() }
        let group = try XCTUnwrap(service.lastRequest?.group)
        let chat = try XCTUnwrap(model.chatID)
        _ = try await h.app.bus.execute(Invocation(command: "test.twoDocuments", principal: .ai(chat), session: h.session, group: group))
        model.stop()
        service.continuation?.finish()
        let result = try await turn.value
        XCTAssertEqual(result["cancelled"]?.boolValue, true)
        XCTAssertTrue(h.app.bus.history.isLinked(group))
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertNil(model.error)
    }

    func testImageDraftDoesNotMutateNotesAndDiscardIsCommandBacked() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService()
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let before = try h.snapshotAll()
        try await model.generateImage("A diagram")
        XCTAssertNotNil(model.draft?.asset)
        XCTAssertNotNil(model.draft?.image)
        XCTAssertEqual(try h.snapshotAll(), before)
        _ = try await h.run(ChatCommand.draft, ["action": "discard"])
        XCTAssertNil(model.draft)
    }

    func testDraftInsertionKeepsCallerIDAIProvenanceAndUndoReceipt() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.textCreateBox, title: "Insert text", summary: "Insert a text item.", effect: .edit)) { p, ctx in
            guard case let .page(d, page)? = NodeRef(p["page"]?.stringValue ?? "") else { throw NibError.invalid("page") }
            let id = NibID(p["id"]?.stringValue ?? NibID.make().raw)
            let item = Item(id: id, kind: .text, text: TextBoxItem(frame: Frame(x: 72, y: 72, w: 300, h: 80), text: RichText(plain: p["text"]?.stringValue ?? "Draft")))
            try ctx.mutate { tx in try tx.put(item, doc: d, page: page) }
            return ["ref": .string(NodeRef.item(d, page, id).description)]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.draft = ChatDraft(text: "Draft", prompt: "Draft")
        let before = try h.snapshotAll()
        let result = try await h.run("ai.chat.insertDraft", ["id": "FIXTUREDRFT1"])
        XCTAssertEqual(result["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREDRFT1")
        let inserted = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "FIXTUREDRFT1")
        XCTAssertTrue(inserted.createdBy?.hasPrefix("ai:") == true)
        XCTAssertNil(model.draft)
        let receipt = try XCTUnwrap(model.entries.last)
        XCTAssertEqual(receipt.changes.count, 1)
        _ = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testUIConfirmationDryRunDoesNotWriteBeforeAllow() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let shell = AutoConfirm()
        h.app.gateway.presenter = shell
        await FeatAIChatFeature.start(h.app)
        h.app.commands.register(CommandDescriptor(id: "test.confirmedEdit", title: "Update item", summary: "Update a fixture item.", effect: .edit)) { _, ctx in
            var item = try ctx.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            item.ext = ["confirmed": true]
            try ctx.mutate { tx in try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1) }
            return [:]
        }
        h.app.services.ai = FakeAIService(responses: [.init(text: "Done", toolCalls: [("test.confirmedEdit", [:])])], bus: h.app.bus)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        model.isVisible = true
        let before = try h.snapshotAll()
        let turn = Task { try await h.run(ChatCommand.send, ["prompt": "Update this item"]) }
        let deadline = Date().addingTimeInterval(3)
        while model.confirmation == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard let pending = model.confirmation else { model.stop(); _ = try? await turn.value; return XCTFail("missing confirmation") }
        XCTAssertEqual(pending.summary?.count, 1)
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(shell.requests.count, 0)
        _ = try await h.run(ChatCommand.confirm, ["request": .string(pending.id), "decision": "allow"])
        _ = try await turn.value
        XCTAssertNotEqual(try h.snapshotAll(), before)
        XCTAssertNil(model.confirmation)
        XCTAssertFalse(model.isStreaming)
    }

    func testRetryCannotLosePartialEditUndoGroup() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        let changes = ChangeSummary(updated: ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
        service.events = [.toolStarted(name: "text.setText", arguments: [:]), .toolFinished(name: "text.setText", ok: true, changes: changes),
                          .failed(NibError(.unavailable, "interrupted"))]
        h.app.services.ai = service
        let model = ChatRuntime.get(h.app).model(for: h.session)
        do { _ = try await model.send(prompt: "Edit", principal: .user, group: "PARTIALGROUP"); XCTFail("interrupted") } catch {}
        do { _ = try await model.send(prompt: "Edit", principal: .user, group: "RETRYGROUP", retry: true); XCTFail("must undo first") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(model.entries.last?.group, "PARTIALGROUP")
        XCTAssertEqual(model.entries.last?.changes, changes)
        XCTAssertFalse(model.isStreaming)
    }

    func testSelectionAndBlockContextValidationAndWindowIsolation() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let runtime = ChatRuntime.get(h.app)
        let first = runtime.model(for: h.session)
        XCTAssertThrowsError(try first.setScope(.selection))
        try first.setScope(.block, refs: ["block:FIXTUREDOC02/FIXTUREBLK01"])
        XCTAssertEqual(first.scope.doc, Fixtures.textDocID)
        let second = runtime.model(for: EditorSession())
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.scope.kind, .library)
    }
}

@MainActor
private final class ScriptedChatService: AIService {
    var isConfigured = true
    var supportsVision = true
    var events: [AIStreamEvent] = []
    var suspended = false
    var continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation?
    var cancelled: String?
    var lastRequest: AIRequest?
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { c in
            continuation = c
            if !suspended { events.forEach { c.yield($0) }; c.finish() }
        }
    }
    func complete(_ request: AIRequest) async throws -> AIResponse { AIResponse(text: "") }
    func cancel(chatID: String) { cancelled = chatID }
    func chats(doc: DocumentID?) -> [AIChatSummary] { [] }
    func messages(chatID: String) -> [AIMessage] { [] }
    func deleteChat(_ chatID: String) {}
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { throw NibError.unsupported("audio") }
    func generateImage(prompt: String) async throws -> Data { Fixtures.pngData }
}
