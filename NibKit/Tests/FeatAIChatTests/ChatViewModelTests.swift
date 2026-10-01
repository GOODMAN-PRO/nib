import XCTest
import UIKit
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
        h.app.commands.register(CommandDescriptor(id: "test.confirmedEdit", title: "Update item", summary: "Update a fixture item.", effect: .edit, destructive: true)) { _, ctx in
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
    func testDefaultPolicyDoesNotConfirmNonDestructiveEdit() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        // F084 owns this policy; starting the presenter must leave it intact.
        let settings = h.app.settings
        h.app.gateway.setPolicy(forPrincipalKind: "ai") { _ in settings.get(NibSettings.aiConfirmationPolicy) }
        await FeatAIChatFeature.start(h.app)
        var writes = 0
        h.app.commands.register(CommandDescriptor(id: "test.safeEdit", title: "Edit text", summary: "A non-destructive edit.", effect: .edit)) { _, ctx in
            if !ctx.dryRun { writes += 1 }
            return [:]
        }
        h.app.services.ai = FakeAIService(responses: [.init(text: "Done", toolCalls: [("test.safeEdit", [:])])], bus: h.app.bus)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        model.isVisible = true
        _ = try await model.send(prompt: "Edit", principal: .user, group: "SAFE")
        XCTAssertEqual(writes, 1)
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(h.confirmer.requests.isEmpty)
        h.app.settings.set(NibSettings.aiConfirmationPolicy, .never)
        XCTAssertEqual(h.app.gateway.policy(.ai("test")), .never)
    }

    func testStopAndDiscardCancelImageProviderTask() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.imageSuspended = true
        h.app.services.ai = service
        let model = ChatRuntime.get(h.app).model(for: h.session)
        for discard in [false, true] {
            service.imageStarted = false
            service.imageCancelled = false
            let image = Task { _ = try await h.run(ChatCommand.draft, ["action": "image", "prompt": "Diagram"]) }
            while !service.imageStarted { await Task.yield() }
            if discard { _ = try await h.run(ChatCommand.draft, ["action": "discard"]) }
            else { model.stop() }
            do { try await image.value; XCTFail("image request must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
            XCTAssertTrue(service.imageCancelled)
            XCTAssertFalse(model.isGeneratingImage)
            XCTAssertNil(model.draft)
            XCTAssertNil(model.error)
        }
    }

    func testGeneratedJPEGUsesJPEGAsset() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.imageData = try XCTUnwrap(UIImage(data: Fixtures.pngData)?.jpegData(compressionQuality: 0.8))
        h.app.services.ai = service
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try await model.generateImage("Photo")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(model.draft?.asset?.name)).pathExtension, "jpg")
    }

    func testStalePreviewCannotPromptInNextTurn() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.suspended = true
        h.app.services.ai = service
        let runtime = ChatRuntime.get(h.app)
        let model = runtime.model(for: h.session)
        model.isVisible = true
        var preview: CheckedContinuation<Void, Never>?
        let command = CommandDescriptor(id: "test.slowPreview", title: "Edit", summary: "Suspended preview.", effect: .edit)
        h.app.commands.register(command) { _, ctx in
            if ctx.dryRun { await withCheckedContinuation { preview = $0 } }
            return [:]
        }
        let first = Task { try await model.send(prompt: "First", principal: .user, group: "FIRST") }
        while !model.isStreaming { await Task.yield() }
        let request = ConfirmationRequest(principal: .ai(try XCTUnwrap(model.chatID)), command: command, params: [:])
        let confirmation = Task { await runtime.confirm(request) }
        while preview == nil { await Task.yield() }
        model.stop()
        _ = try? await first.value
        let second = Task { try await model.send(prompt: "Second", principal: .user, group: "SECOND") }
        while !model.isStreaming { await Task.yield() }
        preview?.resume()
        if case .deny = await confirmation.value {} else { XCTFail("stale preview must be denied") }
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(model.isStreaming)
        model.stop()
        _ = try? await second.value
    }

    func testNetworkPreviewIsSkippedBeforeConsent() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.suspended = true
        h.app.services.ai = service
        let runtime = ChatRuntime.get(h.app)
        let model = runtime.model(for: h.session)
        model.isVisible = true
        var calls = 0
        let command = CommandDescriptor(id: "test.networkEdit", title: "Upload", summary: "Upload a change.", effect: .edit, extraScopes: [.network])
        h.app.commands.register(command) { _, _ in calls += 1; return [:] }
        let turn = Task { try await model.send(prompt: "Upload", principal: .user, group: "NETWORK") }
        while !model.isStreaming { await Task.yield() }
        let request = ConfirmationRequest(principal: .ai(try XCTUnwrap(model.chatID)), command: command, params: [:])
        let confirmation = Task { await runtime.confirm(request) }
        while model.confirmation == nil { await Task.yield() }
        XCTAssertEqual(calls, 0)
        model.resolveConfirmation(.deny)
        if case .deny = await confirmation.value {} else { XCTFail("deny") }
        model.stop()
        _ = try? await turn.value
    }

    func testConversationLoadsOnlyApplyLatestResultAndBlockSend() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService()
        var loads: [String: CheckedContinuation<Void, Never>] = [:]
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatList, title: "List", summary: "Deferred conversation load.", effect: .read)) { p, _ in
            let id = p["chat"]?.stringValue ?? ""
            await withCheckedContinuation { loads[id] = $0 }
            return ["chats": [], "messages": [["id": .string(id + "MSG"), "role": "assistant", "text": .string(id)]]]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let a = Task { try await model.selectChat("A") }
        while loads["A"] == nil { await Task.yield() }
        do { _ = try await model.send(prompt: "Wait", principal: .user, group: "LOAD"); XCTFail("send must wait for load") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        let b = Task { try await model.selectChat("B") }
        while loads["B"] == nil { await Task.yield() }
        loads["B"]?.resume()
        try await b.value
        loads["A"]?.resume()
        do { try await a.value; XCTFail("stale load") } catch is CancellationError {}
        XCTAssertEqual(model.chatID, "B")
        XCTAssertEqual(model.entries.last?.text, "B")
        XCTAssertTrue(model.entries.last?.isPersisted == true)
        XCTAssertFalse(model.isLoadingChat)
    }

    func testClosedSessionModelsAreStoppedAndPruned() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.suspended = true
        h.app.services.ai = service
        let runtime = ChatRuntime.get(h.app)
        let model = runtime.model(for: h.session)
        let turn = Task { try await model.send(prompt: "Wait", principal: .user, group: "CLOSED") }
        while !model.isStreaming { await Task.yield() }
        h.app.services.sessions.remove(h.session)
        runtime.pruneModels()
        _ = try? await turn.value
        XCTAssertFalse(model.isStreaming)
        XCTAssertFalse(runtime.model(for: h.session) === model)
    }

    func testFailedAnswerCannotSendFeedbackWithLocalID() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let service = ScriptedChatService()
        service.events = [.text("Partial"), .failed(NibError(.unavailable, "offline"))]
        h.app.services.ai = service
        let model = ChatRuntime.get(h.app).model(for: h.session)
        do { _ = try await model.send(prompt: "Read", principal: .user, group: "FAILED"); XCTFail("failure") } catch {}
        XCTAssertFalse(try XCTUnwrap(model.entries.last).isPersisted)
    }

    func testFeedbackIDReconciliationMatchesTheTurnGroup() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: "Answer")])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatList, title: "List", summary: "Persisted messages.", effect: .read)) { _, _ in
            ["chats": [], "messages": [["id": "PERSISTED", "role": "assistant", "text": "Answer", "group": "PERSISTGROUP"],
                                       ["id": "OTHER", "role": "assistant", "text": "Other turn", "group": "OTHERGROUP"]]]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        _ = try await model.send(prompt: "Read", principal: .user, group: "PERSISTGROUP")
        XCTAssertEqual(model.entries.last?.id, "PERSISTED")
        XCTAssertTrue(model.entries.last?.isPersisted == true)
    }

    func testAllowRestOfTurnAndDenyHaveNoUnapprovedWrites() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        await FeatAIChatFeature.start(h.app)
        var writes = 0
        var previews = 0
        h.app.commands.register(CommandDescriptor(id: "test.destructiveEdit", title: "Replace text", summary: "A destructive edit.", effect: .edit, destructive: true)) { _, ctx in
            if ctx.dryRun { previews += 1 } else { writes += 1 }
            return [:]
        }
        h.app.services.ai = FakeAIService(responses: [
            .init(text: "Done", toolCalls: [("test.destructiveEdit", [:]), ("test.destructiveEdit", [:])]),
            .init(text: "Denied", toolCalls: [("test.destructiveEdit", [:])])
        ], bus: h.app.bus)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        model.isVisible = true
        let allowed = Task { try await model.send(prompt: "Replace", principal: .user, group: "ALLOWGROUP") }
        while model.confirmation == nil { await Task.yield() }
        XCTAssertEqual(writes, 0)
        let pending = try XCTUnwrap(model.confirmation)
        _ = try await h.run(ChatCommand.confirm, ["request": .string(pending.id), "decision": "turn"])
        _ = try await allowed.value
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(previews, 1)
        let denied = Task { try await model.send(prompt: "Replace again", principal: .user, group: "DENYGROUP") }
        while model.confirmation == nil { await Task.yield() }
        let denyRequest = try XCTUnwrap(model.confirmation)
        _ = try await h.run(ChatCommand.confirm, ["request": .string(denyRequest.id), "decision": "deny"])
        do { _ = try await denied.value; XCTFail("denied tool") }
        catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
        XCTAssertEqual(writes, 2)
        XCTAssertNil(model.confirmation)
    }

    func testDeleteCurrentConversationResetsThreadAfterCommandSucceeds() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        var deleted: String?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatDelete, title: "Delete", summary: "Delete a conversation.", effect: .session, destructive: true)) { p, _ in
            deleted = p["chat"]?.stringValue
            return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatList, title: "List", summary: "List conversations.", effect: .read)) { _, _ in ["chats": [], "messages": []] }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.chatID = "CURRENTCHAT"
        model.entries = [ChatEntry(id: "OLDMSG", role: "assistant", text: "Old")]
        model.perform(CommandIDs.aiChatDelete, ["chat": "CURRENTCHAT"])
        while model.chatID != nil { await Task.yield() }
        XCTAssertEqual(deleted, "CURRENTCHAT")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testDropAnswerRetainsPositionProvenanceAndUndoReceipt() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.textCreateBox, title: "Insert text", summary: "Insert a text item.", effect: .edit)) { p, ctx in
            XCTAssertEqual(p["at"], [120, 240])
            guard case let .page(d, page)? = NodeRef(p["page"]?.stringValue ?? "") else { throw NibError.invalid("page") }
            let id = NibID(p["id"]?.stringValue ?? NibID.make().raw)
            let item = Item(id: id, kind: .text, text: TextBoxItem(frame: Frame(x: 120, y: 240, w: 300, h: 80), text: RichText(plain: p["text"]?.stringValue ?? "")))
            try ctx.mutate { tx in try tx.put(item, doc: d, page: page) }
            return ["ref": .string(NodeRef.item(d, page, id).description)]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let before = try h.snapshotAll()
        _ = try await h.run(ChatCommand.dropAnswer, ["text": "Answer", "page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [120, 240], "id": "FIXTUREDROP1", "chat": "FIXTURECHAT1"])
        let inserted = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "FIXTUREDROP1")
        XCTAssertTrue(inserted.createdBy?.hasPrefix("ai:") == true)
        let receipt = try XCTUnwrap(model.entries.last)
        XCTAssertTrue(receipt.isReceipt)
        XCTAssertEqual(receipt.changes.count, 1)
        _ = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testShowRevealsOnceAndSelectsChangedItemsTogether() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        var reveals = 0
        var selected: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.viewReveal, title: "Reveal", summary: "Reveal a ref.", effect: .session)) { _, _ in reveals += 1; return [:] }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.selectionSet, title: "Select", summary: "Select changed items.", effect: .session)) { p, _ in selected = p["refs"]?.arrayValue ?? []; return [:] }
        let refs = ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"]
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.entries = [ChatEntry(id: "SHOWMSG", role: "assistant", text: "Edited", changes: ChangeSummary(updated: refs))]
        _ = try await h.run(ChatCommand.show, ["message": "SHOWMSG"])
        XCTAssertEqual(reveals, 1)
        XCTAssertEqual(Set(selected.compactMap(\.stringValue)), Set(refs))
    }

    func testReadOnlyAnswerReconcilesMessageWithoutPersistedGroup() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: "Read answer")])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatList, title: "List", summary: "F084 omits the group when no changes were made.", effect: .read)) { _, _ in
            ["chats": [], "messages": [["id": "READMSG", "role": "assistant", "text": "Read answer"]]]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        _ = try await model.send(prompt: "Read", principal: .user, group: "READGROUP")
        XCTAssertEqual(model.entries.last?.id, "READMSG")
        XCTAssertTrue(model.entries.last?.isPersisted == true)
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
    var imageSuspended = false
    var imageStarted = false
    var imageCancelled = false
    var imageData = Fixtures.pngData
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { c in
            continuation = c
            if !suspended { events.forEach { c.yield($0) }; c.finish() }
        }
    }
    func complete(_ request: AIRequest) async throws -> AIResponse { AIResponse(text: "") }
    func cancel(chatID: String) { cancelled = chatID; continuation?.finish(throwing: CancellationError()) }
    func chats(doc: DocumentID?) -> [AIChatSummary] { [] }
    func messages(chatID: String) -> [AIMessage] { [] }
    func deleteChat(_ chatID: String) {}
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { throw NibError.unsupported("audio") }
    func generateImage(prompt: String) async throws -> Data {
        imageStarted = true
        do {
            if imageSuspended { try await Task.sleep(nanoseconds: 60_000_000_000) }
            try Task.checkCancellation()
            return imageData
        } catch { imageCancelled = true; throw error }
    }
}
