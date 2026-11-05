import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatAIChat

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testLongStreamParsesEachCompletedTokenOnceAndReusesPageIndex() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let template = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).livePages.first)
        let pages = (0..<500).map { index -> PageRecord in
            PageRecord(id: NibID("CITEPAGE\(index)"), order: String(format: "%04d", index),
                       size: template.size, background: template.background)
        }
        let refs = pages.prefix(40).map { NodeRef.page(Fixtures.docID, $0.id).description }
        let answer = (0..<5).map { _ in refs.joined(separator: " cited. ") + ". " }.joined()
        var stream = ChatCitationStream()
        var cache = ChatPageIndexCache()
        var lookups = 0
        for character in answer {
            stream.append(String(character)) { raw in
                lookups += 1
                guard case let .page(doc, page)? = NodeRef(raw),
                      let index = cache.index(of: page, in: doc, pages: pages) else { return "Page" }
                return "Page \(index + 1)"
            }
        }
        XCTAssertEqual(stream.refs, refs)
        XCTAssertEqual(lookups, refs.count, "repeated references and deltas reuse resolved labels")
        XCTAssertEqual(cache.buildCount, 1, "all 40 page citations share one sort of the 500 pages")
        XCTAssertEqual(stream.parsedUTF16, answer.utf16.count, "completed text is scanned once across all deltas")
        XCTAssertEqual(stream.displayText, ChatCitations.replacingRefs(in: answer, labels: stream.labels))
        var reordered = pages
        reordered[0].order = "9999"
        XCTAssertEqual(cache.index(of: pages[0].id, in: Fixtures.docID, pages: reordered), 499)
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testEntryStreamingHandlesSplitReferencesAndLabelRefresh() {
        var entry = ChatEntry(id: "STREAM", role: "assistant", text: "")
        var lookups = 0
        let label: (String) -> String = { _ in lookups += 1; return "Page 1" }
        for delta in ["See pa", "ge:D/", "PAGE", ". Again page:D/PAGE."] { entry.appendText(delta, label: label) }
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(entry.text, "See page:D/PAGE. Again page:D/PAGE.")
        XCTAssertEqual(entry.displayText, "See Page 1. Again Page 1.")
        entry.resolveCitations { _ in "Page 2" }
        entry.appendText(" More.", label: label)
        XCTAssertEqual(entry.displayText, "See Page 2. Again Page 2. More.")
        XCTAssertEqual(lookups, 1)
        entry.text = "Replaced with doc:D."
        entry.resolveCitations { _ in "Notebook" }
        XCTAssertEqual(entry.displayText, "Replaced with Notebook.")
    }

    func testCitationLabelsRefreshAfterPageReorderAndDocumentRename() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let pageRef = "page:FIXTUREDOC01/FIXTUREPG001"
        let docRef = "doc:FIXTUREDOC01"
        model.entries = [ChatEntry(id: "CITATIONS", role: "assistant", text: "See \(pageRef) in \(docRef).")]
        model.refreshCitations()
        XCTAssertEqual(model.entries[0].citationLabels[pageRef], "Page 1")
        h.app.commands.register(CommandDescriptor(id: "test.reorder", title: "Reorder", summary: "Swap fixture pages.", effect: .edit)) { _, ctx in
            var pages = try ctx.workspace.content(Fixtures.docID).livePages
            let firstOrder = pages[0].order
            pages[0].order = pages[1].order
            pages[1].order = firstOrder
            try ctx.mutate { tx in
                _ = try tx.put(pages[0], doc: Fixtures.docID)
                _ = try tx.put(pages[1], doc: Fixtures.docID)
            }
            return [:]
        }
        _ = try await h.run("test.reorder")
        try h.library.rename(Fixtures.docID, to: "Renamed notebook")
        XCTAssertEqual(model.citationLabel(pageRef), "Page 2")
        model.refreshCitations()
        XCTAssertEqual(model.entries[0].citationLabels[pageRef], "Page 2")
        XCTAssertEqual(model.entries[0].citationLabels[docRef], "Renamed notebook")
        XCTAssertEqual(model.entries[0].displayText, "See Page 2 in Renamed notebook.")
    }

    func testEntryCitationFallbackIsReplacedWhenResolutionBecomesAvailable() {
        var entry = ChatEntry(id: "LATECITE", role: "assistant", text: "See page:D/P.")
        entry.resolveCitations { _ in "Page" }
        entry.resolveCitations { _ in "Page 3" }
        XCTAssertEqual(entry.displayText, "See Page 3.")
    }

    func testRecoverableToolErrorsStayWithAIWhileUserErrorsCanBeDismissed() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        model.chatID = "RETRYCHAT"
        model.isStreaming = true
        let params: JSONValue = ["changes": [["command": "test.missing", "params": [:]]]]
        do {
            _ = try await h.run(ChatCommand.propose, params, as: .ai("RETRYCHAT"))
            XCTFail("Invalid proposal must report a tool error")
        } catch { XCTAssertNil(model.error) }
        do {
            _ = try await h.run(ChatCommand.propose, params)
            XCTFail("Invalid user proposal must fail")
        } catch { XCTAssertNotNil(model.error) }
        _ = try await h.run(ChatCommand.inspect, ["section": "error"])
        XCTAssertNil(model.error)
    }

    func testAnswerDraftUsesReadableCitationLabelsAndUnresolvedFallback() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        var answer = ChatEntry(id: "CITEDANSWER", role: "assistant", text: "See page:FIXTUREDOC01/FIXTUREPG001.")
        answer.resolveCitations(model.citationLabel)
        model.entries = [answer]
        _ = try await h.run("ai.chat.draft", ["action": "answer", "message": .string(answer.id)])
        XCTAssertEqual(model.draft?.text, "See Page 1.")
        XCTAssertEqual(model.draft?.prompt, "See Page 1.")
        model.entries = [ChatEntry(id: "UNRESOLVED", role: "assistant", text: "See page:UNKNOWN/PAGE.")]
        _ = try await h.run("ai.chat.draft", ["action": "answer", "message": "UNRESOLVED"])
        XCTAssertEqual(model.draft?.text, "See Reference.")
    }

    func testArchiveInterleavesReceiptsWithoutReorderingListedMessages() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let messages = [("USER1", "user", 1.0), ("ANSWER1", "assistant", 2.0),
                        ("USER2", "user", 4.0), ("ANSWER2", "assistant", 5.0)].map {
            StoredChatEntry(ChatEntry(id: $0.0, role: $0.1, text: $0.0, at: Date(timeIntervalSince1970: $0.2)))
        }
        let receipts = [("APPLIED", 2.0), ("INSERTED", 3.0)].map {
            StoredChatEntry(ChatEntry(id: $0.0, role: "assistant", text: $0.0, group: $0.0,
                                      at: Date(timeIntervalSince1970: $0.1), isReceipt: true))
        }
        try await ChatArchive.save(chat: "RECEIPTS", device: h.app.deviceHex,
            records: receipts.map { ChatArchive.Record(message: $0, rev: h.app.clock.tick()) },
            metadata: h.library.metadataURL, assets: h.app.services.assets, doc: Fixtures.docID)
        let restored = try await ChatArchive.restore(chat: "RECEIPTS", listed: messages, metadata: h.library.metadataURL)
        XCTAssertEqual(restored.map(\.id), ["USER1", "ANSWER1", "APPLIED", "INSERTED", "USER2", "ANSWER2"])
        XCTAssertEqual(restored.filter { $0.receipt == true }.map(\.group), ["APPLIED", "INSERTED"])
    }

    func testContextAndSendFollowWindowDocumentChanges() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryContext, title: "Context", summary: "Read context.", effect: .read)) { _, _ in
            ["document": ["kind": "textDocument"]]
        }
        let ai = FakeAIService(responses: [.init(text: "Current document")])
        h.app.services.ai = ai
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try model.setScope(.selection, refs: ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
        h.session.document = Fixtures.textDocID
        h.session.page = nil
        _ = try await h.run(ChatCommand.inspect, ["section": "context"])
        XCTAssertEqual(model.scope.kind, .document)
        XCTAssertEqual(model.scope.doc, Fixtures.textDocID)
        XCTAssertTrue(model.scope.refs.isEmpty)
        h.session.document = Fixtures.docID
        h.session.page = Fixtures.page2
        _ = try await model.send(prompt: "Read this", principal: .user, group: "FOLLOWDOC")
        XCTAssertEqual(ai.requests.last?.scope?.doc, Fixtures.docID)
    }

    func testInitialLibraryScopeFollowsDocumentButExplicitLibraryStays() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.session.document = nil
        let model = ChatRuntime.get(h.app).model(for: h.session)
        h.session.document = Fixtures.docID
        model.refreshSessionScope()
        XCTAssertEqual(model.scope.doc, Fixtures.docID)
        try model.setScope(.library)
        h.session.document = Fixtures.textDocID
        model.refreshSessionScope()
        XCTAssertEqual(model.scope.kind, .library)
        XCTAssertNil(model.scope.doc)
    }

    func testContextUndoRestoresExplicitLibraryChoiceAcrossDocumentSwitch() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try model.setScope(.library)
        model.localUndo.beginUndoGrouping()
        model.registerContextUndo()
        try model.setScope(.document)
        model.localUndo.endUndoGrouping()
        model.localUndo.undo()
        h.session.document = Fixtures.textDocID
        model.refreshSessionScope()
        XCTAssertEqual(model.scope.kind, .library)
        XCTAssertNil(model.scope.doc)
    }

    func testPageLabelUsesOneBasedScopedPageEvenWhenCanvasMoves() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryContext, title: "Context", summary: "Read the visible canvas context.", effect: .read)) { _, ctx in
            let index = try ctx.workspace.content(Fixtures.docID).pageIndex(ctx.session?.page ?? Fixtures.page1) ?? 0
            return ["document": ["kind": "notebook"], "page": ["index": .number(Double(index))]]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try model.setScope(.page)
        let title = try XCTUnwrap(h.app.services.library?.node(Fixtures.docID)?.title)
        XCTAssertEqual(model.contextLabel, "\(title) · Page 1")
        h.session.page = Fixtures.page2
        try await model.loadContext()
        XCTAssertEqual(model.contextLabel, "\(title) · Page 1")
        try model.setScope(.page)
        XCTAssertEqual(model.contextLabel, "\(title) · Page 2")
        try model.setScope(.selection, refs: ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
        XCTAssertEqual(model.contextLabel, "\(title) · Page 1 · 1 item selected")
    }

    func testRestoredConversationNamesItsDocumentWithoutNavigating() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatList, title: "List", summary: "List conversations.", effect: .read)) { _, _ in
            ["chats": [["id": "SAVED", "title": "Earlier conversation", "doc": "doc:FIXTUREDOC02", "updated": 0]], "messages": []]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try await model.selectChat("SAVED")
        XCTAssertEqual(model.scope.doc, Fixtures.textDocID)
        XCTAssertEqual(model.contextLabel, h.app.services.library?.node(Fixtures.textDocID)?.title)
        XCTAssertEqual(h.session.document, Fixtures.docID)
    }

    func testProviderSubtitleReflectsCredentialsAndClearsRemovedConfiguration() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let store = ChatTestProviderStore()
        h.app.services.set(store, for: ServiceKeys.aiProviders)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        XCTAssertEqual(model.providerLabel, "No model connected")
        let config = AIProviderConfig(name: "Local server", kind: .openAICompatible,
            baseURL: URL(string: "http://localhost:11434/v1")!, model: "Notes model")
        store.configs = [config]; store.activeID = config.id
        model.refreshProviderLabel()
        XCTAssertEqual(model.providerLabel, "Notes model · Local server · no API key saved")
        Keychain.setString("test-key", service: AIProviderConfig.keychainService, account: config.keychainAccount)
        model.refreshProviderLabel()
        XCTAssertEqual(model.providerLabel, "Notes model · Local server · your API key")
        store.activeID = nil
        model.refreshProviderLabel()
        XCTAssertEqual(model.providerLabel, "No model connected")
    }

    func testAvailabilityMatchesGenerationGuardsAndScopePrerequisites() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService()
        let model = ChatRuntime.get(h.app).model(for: h.session)
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(model.canGenerateImage)
        XCTAssertTrue(model.canUseHistory)
        model.isGeneratingImage = true
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canGenerateImage)
        XCTAssertFalse(model.canChangeConversation)
        XCTAssertEqual(model.progressLabel, "Generating image…")
        model.isGeneratingImage = false
        model.isStreaming = true
        XCTAssertFalse(model.canConfigureContext)
        XCTAssertFalse(model.canUseHistory)
        model.isStreaming = false
        XCTAssertEqual(model.scopeUnavailableReason(.selection), "Select an item first")
        XCTAssertEqual(model.scopeUnavailableReason(.block), "Select a block first")
        var invalidations = 0
        let observation = model.objectWillChange.sink { invalidations += 1 }
        defer { observation.cancel() }
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        XCTAssertGreaterThan(invalidations, 0, "An idle scope menu must update when the canvas selection changes.")
        XCTAssertNil(model.scopeUnavailableReason(.selection))
        XCTAssertNotNil(model.scopeUnavailableReason(.block))
        h.session.document = nil; h.session.page = nil
        XCTAssertEqual(model.scopeUnavailableReason(.document), "Open a document first")
        XCTAssertEqual(model.scopeUnavailableReason(.page), "Open a page first")
        XCTAssertNil(model.scopeUnavailableReason(.library))
    }

    func testFailedHistoryRenameKeepsDraftAndExposesOperationState() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        var finish: CheckedContinuation<Void, Never>?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatRename, title: "Rename", summary: "Rename a conversation.", effect: .session)) { _, _ in
            await withCheckedContinuation { finish = $0 }
            throw NibError.unavailable("Could not save the conversation name.")
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.showsConversations = true
        model.renamingChat = "SAVED"; model.renameTitle = "Keep this draft"
        model.perform(CommandIDs.aiChatRename, ["chat": "SAVED", "title": "Keep this draft"])
        XCTAssertEqual(model.progressLabel, "Saving conversation name…")
        XCTAssertFalse(model.canUseHistory)
        let deadline = Date().addingTimeInterval(5)
        while finish == nil, Date() < deadline { await Task.yield() }
        let continuation = try XCTUnwrap(finish)
        continuation.resume()
        while model.historyOperationLabel != nil, Date() < deadline { await Task.yield() }
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.historyOperationLabel)
        XCTAssertEqual(model.renameTitle, "Keep this draft")
        XCTAssertEqual(model.renamingChat, "SAVED")
        XCTAssertTrue(model.showsConversations)
        XCTAssertTrue(model.canUseHistory)
    }

    func testConfirmationExplainsTargetsCountsAndConsequencesWithoutRawParameters() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"
        let descriptor = CommandDescriptor(id: "test.remove", title: "Delete selected content",
            summary: "Delete refs using raw arrays.", effect: .edit, destructive: true)
        let pending = ChatConfirmation(request: ConfirmationRequest(principal: .ai("TEST"), command: descriptor,
            params: ["refs": [.string(ref)], "headers": ["Authorization": "secret-value"]]))
        pending.summary = ChangeSummary(removed: [ref])
        pending.labels[ref] = model.confirmationTargetLabel(ref)
        XCTAssertEqual(pending.targetRefs, [ref])
        XCTAssertTrue(try XCTUnwrap(pending.labels[ref]).localizedCaseInsensitiveContains("page 1"))
        XCTAssertTrue(try XCTUnwrap(pending.labels[ref]).contains(try XCTUnwrap(h.app.services.library?.node(Fixtures.docID)?.title)))
        XCTAssertTrue(pending.consequences.contains("Remove 1 item."), "Unexpected approval copy: \(pending.consequences)")
        XCTAssertTrue(pending.consequences.contains("This action may delete or replace content."))
        XCTAssertFalse(pending.actionSummary.contains("refs"))
        XCTAssertFalse(pending.parameterSummary.contains("secret-value"))
        let unpreviewed = ChatConfirmation(request: ConfirmationRequest(principal: .ai("TEST"), command: descriptor, params: ["refs": [.string(ref)]]))
        XCTAssertEqual(unpreviewed.targetRefs, [ref], "Nested reference parameters must be named even without a dry run.")
        XCTAssertTrue(unpreviewed.consequences.contains { $0.contains("preview is unavailable") })
    }

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

    func testWhollySkippedUndoShowsReasonAndCanBeRetriedAfterLaterEditIsUndone() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.commands.register(CommandDescriptor(id: "test.editForRevert", title: "Edit", summary: "Edit fixture", effect: .edit)) { p, ctx in
            try ctx.mutate { tx in
                var item = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
                if p["later"]?.boolValue == true { item.layer = 3 }
                else { item.locked = true }
                try tx.put(item, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return [:]
        }
        h.app.services.ai = FakeAIService(responses: [.init(text: "Updated", toolCalls: [("test.editForRevert", [:])])], bus: h.app.bus)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        _ = try await model.send(prompt: "Update", principal: .user, group: "SKIPPEDCHAT")
        let receipt = try XCTUnwrap(model.entries.last)
        try await h.run("test.editForRevert", ["later": true])
        let groups = h.app.bus.history.entries(Fixtures.docID).map(\.group)
        let result = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(result["reverted"]?.intValue, 0)
        XCTAssertEqual(result["skipped"]?.intValue, 1)
        XCTAssertFalse(try XCTUnwrap(model.entries.last).reverted)
        let reason = "These records changed after this step. The history entry was kept; undo the later changes and try again."
        XCTAssertTrue(model.entries.last?.revertNote?.contains(reason) == true)
        XCTAssertTrue(model.error?.message.contains(reason) == true)
        XCTAssertEqual(h.app.bus.history.entries(Fixtures.docID).map(\.group), groups)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        let retried = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(retried["reverted"]?.intValue, 1)
        XCTAssertEqual(retried["skipped"]?.intValue, 0)
        XCTAssertTrue(try XCTUnwrap(model.entries.last).reverted)
        XCTAssertNil(model.error)
        XCTAssertFalse(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).locked)
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

    func testTrailingCitationFinalizesAfterFailureOrUnexpectedClosure() async throws {
        let ref = "page:FIXTUREDOC01/FIXTUREPG001"
        for fails in [true, false] {
            let h = Harness(features: [FeatAIChatFeature.self])
            let service = ScriptedChatService()
            service.events = [.text("See " + ref)]
            if fails { service.events.append(.failed(NibError(.unavailable, "offline"))) }
            h.app.services.ai = service
            let model = ChatRuntime.get(h.app).model(for: h.session)
            do {
                _ = try await model.send(prompt: "Read", principal: .user, group: "G1")
                XCTFail("expected an incomplete stream")
            } catch {}
            XCTAssertEqual(model.entries.last?.text, "See " + ref)
            XCTAssertEqual(model.entries.last?.displayText, "See Page 1")
            XCTAssertEqual(model.entries.last?.citationRefs, [ref], "the navigation chip must survive termination")
            XCTAssertEqual(model.entries.last?.citationLabels[ref], "Page 1")
        }
    }

    func testTrailingCitationFinalizesAfterStopOrTaskCancellation() async throws {
        let ref = "page:FIXTUREDOC01/FIXTUREPG001"
        for stops in [true, false] {
            let h = Harness(features: [FeatAIChatFeature.self])
            let service = ScriptedChatService()
            service.suspended = true
            h.app.services.ai = service
            let model = ChatRuntime.get(h.app).model(for: h.session)
            let ended = expectation(description: "cancelled stream ended")
            let turn = Task {
                do {
                    _ = try await model.send(prompt: "Read", principal: .user, group: "G1")
                    XCTFail("expected cancellation")
                } catch {}
                ended.fulfill()
            }
            defer { turn.cancel(); service.continuation?.finish() }
            for _ in 0..<100 where service.continuation == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNotNil(service.continuation)
            service.continuation?.yield(.text("See " + ref))
            for _ in 0..<100 where model.entries.last?.text != "See " + ref { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(model.entries.last?.text, "See " + ref)
            XCTAssertEqual(model.entries.last?.citationRefs, [], "no delimiter has arrived yet")
            if stops { model.stop() } else { turn.cancel() }
            await fulfillment(of: [ended], timeout: 3)
            XCTAssertEqual(model.entries.last?.displayText, "See Page 1")
            XCTAssertEqual(model.entries.last?.citationRefs, [ref])
            XCTAssertEqual(model.entries.last?.citationLabels[ref], "Page 1")
            XCTAssertFalse(model.isStreaming)
        }
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
        XCTAssertEqual(model.progressLabel, "Loading conversation…")
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canGenerateImage)
        XCTAssertFalse(model.canUseHistory)
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

    private func installProposalEdits(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(id: "test.proposedEdit", title: "Revise text", summary: "Revise a fixture record.",
            params: .obj(["ref": .ref, "text": .str()], required: ["ref", "text"]), effect: .edit)) { p, ctx in
            guard case let .item(d, page, id)? = NodeRef(p["ref"]?.stringValue ?? "") else { throw NibError.invalid("item ref") }
            var item = try ctx.workspace.item(d, page: page, id: id)
            item.ext = ["revision": p["text"] ?? ""]
            try ctx.mutate { tx in try tx.put(item, doc: d, page: page) }
            return [:]
        }
    }

    func testSelectiveProposalsStayDryUntilAcceptedAndUndoTogether() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        installProposalEdits(h)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        let before = try h.snapshotAll()
        let refs = ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"]
        _ = try await h.run(ChatCommand.propose, ["changes": .array(refs.map {
            ["command": "test.proposedEdit", "params": ["ref": .string($0), "text": "Reviewed"], "title": "Revise text"]
        })])
        XCTAssertEqual(try h.snapshotAll(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        let first = try XCTUnwrap(model.proposals.first)
        let second = try XCTUnwrap(model.proposals.last)
        _ = try await h.run(ChatCommand.proposal, ["action": "include", "included": [.string(first.id)]])
        _ = try await h.run(ChatCommand.accept)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).ext?["revision"], "Reviewed")
        XCTAssertNil(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).ext?["revision"])
        XCTAssertEqual(model.proposals.map(\.id), [second.id])
        _ = try await h.run(ChatCommand.accept, ["id": .string(second.id)])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "individual approvals stay one group")
        let receipt = try XCTUnwrap(model.entries.last)
        XCTAssertEqual(receipt.changes.count, 2)
        _ = try await h.run(ChatCommand.undo, ["message": .string(receipt.id)])
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testProposalDiscardInclusionUndoAndStalePreviewProtection() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        installProposalEdits(h)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"
        _ = try await h.run(ChatCommand.propose, ["changes": [["command": "test.proposedEdit", "params": ["ref": .string(ref), "text": "AI"]]]])
        let id = try XCTUnwrap(model.proposals.first?.id)
        model.localUndo.removeAllActions()
        model.localUndo.beginUndoGrouping()
        _ = try await h.run(ChatCommand.proposal, ["action": "discard", "id": .string(id)])
        model.localUndo.endUndoGrouping()
        XCTAssertTrue(model.proposals.isEmpty)
        model.localUndo.undo()
        XCTAssertEqual(model.proposals.first?.id, id)
        _ = try await h.run("test.proposedEdit", ["ref": .string(ref), "text": "Later user edit"])
        do { _ = try await h.run(ChatCommand.accept); XCTFail("stale preview must not overwrite a later edit") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).ext?["revision"], "Later user edit")
        XCTAssertEqual(model.proposals.count, 1)
    }

    func testAIProposalToolStagesDuringStreamAndCannotSelfAccept() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        installProposalEdits(h)
        let changes: JSONValue = ["changes": [["command": "test.proposedEdit", "params": ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "text": "AI"]]]]
        h.app.services.ai = FakeAIService(responses: [.init(text: "Review this change", toolCalls: [(ChatCommand.propose, changes)])], bus: h.app.bus)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit
        let before = try h.snapshotAll()
        _ = try await model.send(prompt: "Proofread", principal: .user, group: "PROPOSALTURN")
        XCTAssertEqual(model.proposals.count, 1)
        XCTAssertEqual(try h.snapshotAll(), before)
        do { _ = try await h.run(ChatCommand.accept, as: .ai(try XCTUnwrap(model.chatID))); XCTFail("AI cannot approve") }
        catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
    }

    func testAskModeCannotStageAndUnsafePreviewNeverRuns() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        installProposalEdits(h)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let params: JSONValue = ["changes": [["command": "test.proposedEdit", "params": ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "text": "AI"]]]]
        do { _ = try await h.run(ChatCommand.propose, params); XCTFail("Ask mode cannot stage edits") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        var calls = 0
        h.app.commands.register(CommandDescriptor(id: "test.unsafeProposal", title: "Upload", summary: "Upload a record.", effect: .edit, sensitive: true)) { _, _ in calls += 1; return [:] }
        model.mode = .edit
        do { _ = try await h.run(ChatCommand.propose, ["changes": [["command": "test.unsafeProposal", "params": [:]]]]); XCTFail("must not preview") }
        catch let error as NibError { XCTAssertEqual(error.code, .unsupported) }
        XCTAssertEqual(calls, 0)
    }

    func testConversationRestoresMergedUsageImagesDetailedAndLegacyTools() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let chat = "RESTORECHAT1"
        let directory = h.library.metadataURL.appendingPathComponent("ai")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let user = ChatEntry(id: "RESTOREUSER1", role: "user", text: "Read this image", images: [try h.assets.putTemporary(Fixtures.pngData, ext: "png")])
        var answer = ChatEntry(id: "RESTOREANS01", role: "assistant", text: "Answer", group: "RESTOREGROUP")
        answer.usage = AIUsage(input: 11, output: 7)
        answer.tools = [ChatToolActivity(id: "RESTORETOOL", name: "query.get", arguments: ["ref": "doc:FIXTUREDOC01"], succeeded: true)]
        var raw = StoredChatEntry(answer)
        raw.tools = nil
        let firstRev = Rev(wallMs: 1000, counter: 0, device: 1)
        let secondRev = Rev(wallMs: 2000, counter: 0, device: 2)
        let original: JSONValue = try JSONValue.from(raw).merging(["type": "message", "rev": .string(firstRev.description), "tools": ["query.get"]])
        var newer = original.merging(["rev": .string(secondRev.description), "usage": ["input": 23, "output": 9]])
        newer = newer.merging(["rating": "up"])
        try (original.jsonString() + "\n" + original.jsonString() + "\n{torn").write(to: directory.appendingPathComponent(chat + ".00000001.jsonl"), atomically: true, encoding: .utf8)
        try (newer.jsonString() + "\n").write(to: directory.appendingPathComponent(chat + ".00000002.jsonl"), atomically: true, encoding: .utf8)
        try await ChatArchive.save(chat: chat, device: "00000001", records: [
            .init(message: StoredChatEntry(user), rev: firstRev), .init(message: StoredChatEntry(answer), rev: firstRev)
        ], metadata: h.library.metadataURL, assets: h.assets, doc: Fixtures.docID)
        let source = try XCTUnwrap(h.assets.temporaryURL(try XCTUnwrap(user.images.first)))
        try FileManager.default.removeItem(at: source)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.aiChatList, title: "List", summary: "Merged canonical conversation.", effect: .read)) { _, _ in
            ["chats": [["id": .string(chat), "title": "Restored", "doc": "doc:FIXTUREDOC01", "updated": 2000]],
             "messages": [["id": .string(user.id), "role": "user", "text": .string(user.text)],
                          ["id": .string(answer.id), "role": "assistant", "text": "Answer", "rating": "up", "group": "RESTOREGROUP"]]]
        }
        h.app.settings.set(ChatViewModel.tokenKey(chat), 999)
        let model = ChatRuntime.get(h.app).model(for: h.session)
        try await model.selectChat(chat)
        XCTAssertEqual(model.tokenCount, 32, "usage merges by id, not device or local settings")
        let restored = try XCTUnwrap(model.entries.last)
        XCTAssertEqual(restored.rating, "up")
        XCTAssertEqual(restored.tools.first?.arguments, ["ref": "doc:FIXTUREDOC01"])
        XCTAssertEqual(restored.tools.first?.succeeded, true)
        let image = try XCTUnwrap(model.entries.first?.images.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.imageURL(image))), Fixtures.pngData)
        try await model.selectChat(chat)
        XCTAssertEqual(model.tokenCount, 32, "reopening never counts usage twice")
        let legacy = try JSONDecoder().decode(StoredChatEntry.self, from: Data(original.jsonString().utf8)).entry
        XCTAssertFalse(try XCTUnwrap(legacy.tools.first).hasArguments)
        XCTAssertNil(legacy.tools.first?.succeeded)
    }

    func testDestructiveProposalNeedsExplicitApprovalAndCreationKeepsProvenance() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.mode = .edit; model.chatID = "APPROVALCHAT"
        h.app.commands.register(CommandDescriptor(id: "test.proposedCreate", title: "Insert text", summary: "Insert a text item.",
            params: .obj(["id": .str(), "page": .ref, "text": .str()], required: ["id", "page", "text"]), effect: .edit)) { p, ctx in
            guard case .page(let doc, let page)? = NodeRef(p["page"]?.stringValue ?? "") else { throw NibError.invalid("page") }
            let item = Item(id: NibID(p["id"]?.stringValue ?? ""), kind: .text,
                text: TextBoxItem(frame: Frame(x: 72, y: 72, w: 300, h: 80), text: RichText(plain: p["text"]?.stringValue ?? "")))
            try ctx.mutate { tx in try tx.put(item, doc: doc, page: page) }
            return ["ref": .string(NodeRef.item(doc, page, item.id).description)]
        }
        h.app.commands.register(CommandDescriptor(id: "test.proposedDelete", title: "Delete item", summary: "Delete a fixture item.",
            params: .obj(["ref": .ref], required: ["ref"]), effect: .edit, destructive: true)) { p, ctx in
            guard case .item(let doc, let page, let id)? = NodeRef(p["ref"]?.stringValue ?? "") else { throw NibError.invalid("item") }
            var item = try ctx.workspace.item(doc, page: page, id: id); item.deleted = true
            try ctx.mutate { tx in try tx.put(item, doc: doc, page: page) }
            return [:]
        }
        let before = try h.snapshotAll()
        _ = try await h.run(ChatCommand.propose, ["changes": [
            ["command": "test.proposedCreate", "params": ["text": "Inserted after approval"]],
            ["command": "test.proposedDelete", "params": ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"]]
        ]])
        let createdID = try XCTUnwrap(model.proposals.first?.params["id"]?.stringValue)
        let deletion = try XCTUnwrap(model.proposals.last?.id)
        XCTAssertEqual(try h.snapshotAll(), before)
        _ = try await h.run(ChatCommand.accept)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: NibID(createdID)).createdBy, "ai:APPROVALCHAT")
        XCTAssertNoThrow(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID))
        XCTAssertEqual(model.proposals.map(\.id), [deletion])
        _ = try await h.run(ChatCommand.accept, ["id": .string(deletion)])
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID))
        _ = try await h.run(ChatCommand.undo, ["message": .string(try XCTUnwrap(model.entries.last?.id))])
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testMultiPageProposalReviewIsRequiredBeforeApplying() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        installProposalEdits(h)
        let model = ChatRuntime.get(h.app).model(for: h.session); model.mode = .edit
        _ = try await h.run(ChatCommand.propose, ["changes": [
            ["command": "test.proposedEdit", "params": ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01", "text": "One"]],
            ["command": "test.proposedEdit", "params": ["ref": "item:FIXTUREDOC04/FIXTUREBRD01/FIXTUREBSH01", "text": "Two"]]
        ]])
        XCTAssertTrue(model.proposalNeedsReview)
        let before = try h.snapshotAll()
        do { _ = try await h.run(ChatCommand.accept); XCTFail("review required") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        let review = Task { try await h.run(ChatCommand.proposal, ["action": "review"]) }
        while model.confirmation == nil { await Task.yield() }
        XCTAssertEqual(try h.snapshotAll(), before)
        _ = try await h.run(ChatCommand.confirm, ["request": .string(try XCTUnwrap(model.confirmation?.id)), "decision": "allow"])
        _ = try await review.value
        XCTAssertFalse(model.proposalNeedsReview)
        let output = try await h.run(ChatCommand.accept)
        let group = try XCTUnwrap(output["group"]?.stringValue)
        XCTAssertTrue(h.app.bus.history.isLinked(group))
        _ = try await h.run(ChatCommand.undo, ["message": .string(try XCTUnwrap(model.entries.last?.id))])
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testObsoletePanelDisappearanceCannotHideTheReplacementPlacement() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        _ = try await h.run(ChatCommand.inspect, ["section": "visibility", "visible": true, "lease": "floating"])
        _ = try await h.run(ChatCommand.inspect, ["section": "visibility", "visible": true, "lease": "sidebar"])
        _ = try await h.run(ChatCommand.inspect, ["section": "visibility", "visible": false, "lease": "floating"])
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.visibilityLease, "sidebar")
        _ = try await h.run(ChatCommand.inspect, ["section": "visibility", "visible": false, "lease": "sidebar"])
        XCTAssertFalse(model.isVisible)
    }

    func testContextAndOnPagePreviewCommandsSupportUndoAndRedo() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let original = model.scope
        model.localUndo.beginUndoGrouping()
        _ = try await h.run(ChatCommand.configure, ["scope": "page", "mode": "edit"])
        model.localUndo.endUndoGrouping()
        XCTAssertEqual(model.scope.kind, .page)
        XCTAssertEqual(model.mode, .edit)
        model.localUndo.undo()
        XCTAssertEqual(model.scope, original)
        XCTAssertEqual(model.mode, .ask)
        model.localUndo.redo()
        XCTAssertEqual(model.scope.kind, .page)
        model.localUndo.removeAllActions()
        model.localUndo.beginUndoGrouping()
        _ = try await h.run(ChatCommand.proposal, ["action": "preview", "visible": false])
        model.localUndo.endUndoGrouping()
        XCTAssertFalse(model.showsProposalsOnPage)
        model.localUndo.undo()
        XCTAssertTrue(model.showsProposalsOnPage)
        model.localUndo.redo()
        XCTAssertFalse(model.showsProposalsOnPage)
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

@MainActor
private final class ChatTestProviderStore: AIProviderStore {
    var configs: [AIProviderConfig] = []
    var activeID: UUID?
    func save(_ config: AIProviderConfig, apiKey: String?) throws {}
    func delete(_ id: UUID) { configs.removeAll { $0.id == id } }
    func provider(_ id: UUID?) -> AIProvider? { nil }
}
