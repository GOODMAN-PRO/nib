import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting

/// contracts-v2: regression tests for the DocTransaction.revert fixes and coverage of the APIs added in the v2 pass
/// (docs/CONTRACTS.md › contracts-v2 changelog).
@MainActor
final class ContractsV2Tests: XCTestCase {
    private let doc = Fixtures.docID
    private let page1 = Fixtures.page1
    private let mathRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01"

    // MARK: Undo / revert regressions

    /// F031 (FeatShapesTests.testDroppingAnItemIntoAShapeAttachesItInTheSameUndoStep): a commit observer attaches the
    /// moved item with `item.update` in the move's own undo group; one undo must revert BOTH the attach and the move.
    func testAttachAfterMoveInTheSameGroupUndoesTheMoveToo() async throws {
        let h = Harness()
        registerMoveStandIns(h.app)
        var pending: Task<Void, Never>?
        let watcher = h.app.bus.observeCommits { cs in
            guard cs.principal.isUser, cs.command == CommandIDs.itemTransform else { return }
            let app = h.app, session = h.session, group = cs.group, ref = self.mathRef
            pending = Task { @MainActor in
                _ = try? await app.bus.execute(Invocation(command: CommandIDs.itemUpdate,
                                                          params: ["ref": .string(ref), "patch": ["attachedTo": "FIXTURESHP01"]],
                                                          session: session, group: group))
            }
        }
        defer { watcher.cancel() }
        // The maths item (72, 480, 120 × 40) moves inside the fixture rectangle (100, 200, 160 × 90).
        try await h.run(CommandIDs.itemTransform, ["refs": [.string(mathRef)], "translate": [48, -260]])
        await pending?.value
        let math = try h.app.workspace.item(doc, page: page1, id: Fixtures.mathID)
        XCTAssertEqual(math.attachedTo, Fixtures.shapeID)
        XCTAssertEqual(math.frame, Frame(x: 120, y: 220, w: 120, h: 40))
        XCTAssertEqual(h.undoDepth(doc), 1, "move and attach are one undo step")

        XCTAssertTrue(h.app.bus.undo(doc))
        let restored = try h.app.workspace.item(doc, page: page1, id: Fixtures.mathID)
        XCTAssertNil(restored.attachedTo)
        XCTAssertEqual(restored.frame, Frame(x: 72, y: 480, w: 120, h: 40))

        XCTAssertTrue(h.app.bus.redo(doc))
        let again = try h.app.workspace.item(doc, page: page1, id: Fixtures.mathID)
        XCTAssertEqual(again.attachedTo, Fixtures.shapeID)
        XCTAssertEqual(again.frame, Frame(x: 120, y: 220, w: 120, h: 40))
    }

    /// F005 / F028 / F036 / F044: one undo group that writes the same item, page record and document meta twice
    /// (debounced text commits, a meta change applied in two steps) undoes all the way back and redoes all the way.
    func testRecordWrittenTwiceInOneGroupIsFullyReverted() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let group = "TWICE0000001"
        for text in ["One", "One two"] {
            let ctx = try await probeContext(h, group: group)
            try ctx.mutate { tx in
                var it = try tx.item(self.doc, page: self.page1, id: Fixtures.textID)
                it.text?.text = RichText(plain: text)
                try tx.put(it, doc: self.doc, page: self.page1)
                var page = try XCTUnwrap(try tx.content(self.doc).page(self.page1))
                page.title = text
                try tx.put(page, doc: self.doc)
                var meta = try tx.content(self.doc).meta
                meta.language = text == "One" ? "de-DE" : "fr-FR"
                try tx.putMeta(meta)
            }
        }
        XCTAssertEqual(h.undoDepth(doc), 1)
        let after = try h.snapshot()
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before, "both writes of each record are reverted")
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshot(), after)
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: Fixtures.textID).text?.text.plainText, "One two")
    }

    /// F026 / F029 / F034 / F036 / F049: consecutive undo entries on the SAME item all undo (each revert re-stamps the
    /// item, which used to make the next-older entry look "changed since" and be skipped), then all redo.
    func testConsecutiveUndosOnOneItem() async throws {
        let h = Harness()
        let before = try h.snapshot()
        var states: [JSONValue] = []
        for step in 0..<3 {
            let ctx = try await probeContext(h)
            try ctx.mutate { tx in
                var it = try tx.item(self.doc, page: self.page1, id: Fixtures.stickyID)
                switch step {
                case 0: it.locked = true
                case 1: it.layer = 2
                default: it.sticky?.text = RichText(plain: "edited")
                }
                try tx.put(it, doc: self.doc, page: self.page1)
            }
            states.append(try h.snapshot())
        }
        XCTAssertEqual(h.undoDepth(doc), 3)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), states[1])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), states[0])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshot(), states[1])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), states[0], "undo after redo still lines up")
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshot(), states[2])
    }

    /// F034: insert an image, crop it, flip it, then undo three times: the page is back to where it started.
    func testInsertCropFlipThenThreeUndosRemovesTheImage() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let id: ElementID = "IMGV2TEST001"
        let insert = try await probeContext(h)
        try insert.mutate { tx in
            try tx.put(Item.makeImage(ImageItem(frame: Frame(x: 50, y: 50, w: 100, h: 80), asset: Fixtures.pngAsset)).with(id: id),
                       doc: self.doc, page: self.page1)
        }
        let crop = try await probeContext(h)
        try crop.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: id)
            it.image?.crop = Rect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        let flip = try await probeContext(h)
        try flip.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: id)
            it.image?.flipX = true
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: id).image?.flipX, true)
        for _ in 0..<3 { XCTAssertTrue(h.app.bus.undo(doc)) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertThrowsError(try h.app.workspace.item(doc, page: page1, id: id))
    }

    func testSelectiveRevertStillSkipsRecordsChangedLater() async throws {
        let h = Harness()
        let first = try await probeContext(h)
        try first.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: Fixtures.textID)
            it.locked = true
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        let later = try await probeContext(h)
        try later.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: Fixtures.textID)
            it.layer = 3
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        let r = h.app.bus.revert(group: first.group, doc: doc)
        XCTAssertEqual(r?.skipped, 1)
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: Fixtures.textID).layer, 3)
    }

    func testLinkedUndoAcrossDocuments() async throws {
        let h = Harness()
        let beforeA = try h.snapshot(Fixtures.docID)
        let beforeB = try h.snapshot(Fixtures.whiteboardID)
        let ctx = try await probeContext(h)
        ctx.linkUndoAcrossDocuments()
        try ctx.mutate { tx in
            try tx.delete(item: Fixtures.stickyID, doc: Fixtures.docID, page: Fixtures.page1)
            var board = try tx.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID)
            board.locked = true
            try tx.put(board, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        }
        XCTAssertTrue(h.app.bus.history.isLinked(ctx.group))
        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try h.snapshot(Fixtures.docID), beforeA, "undo in one document undoes the linked step in the other")
        XCTAssertEqual(try h.snapshot(Fixtures.whiteboardID), beforeB)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID))
        XCTAssertTrue(try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID).locked)

        // Unlinked groups keep per-document undo.
        let plain = try await probeContext(h)
        try plain.mutate { tx in
            try tx.delete(item: Fixtures.textID, doc: Fixtures.docID, page: Fixtures.page1)
            try tx.delete(item: Fixtures.boardShapeID, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        }
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID))
    }

    // MARK: Provenance, moves and batch writes

    func testMoveKeepsProvenanceForNonUserPrincipals() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        let r = try await h.run("v2probe.create")
        guard case let .item(_, _, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: id).createdBy, "user")

        try await h.run("v2probe.move", ["id": .string(id.raw)], as: .ai("chat7"))
        let moved = try h.app.workspace.item(doc, page: Fixtures.page2, id: id)
        XCTAssertEqual(moved.createdBy, "user", "the AI moving the user's item keeps it the user's")
        XCTAssertEqual(moved.frame?.x, 30)
        XCTAssertThrowsError(try h.app.workspace.item(doc, page: page1, id: id))

        // A plain put by the AI of a NEW item still stamps the AI.
        let made = try await h.run("v2probe.create", as: .ai("chat7"))
        guard case let .item(_, _, aiID)? = NodeRef(made["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: aiID).createdBy, "ai:chat7")

        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: id).createdBy, "user", "undo puts it back")
    }

    func testBatchPutAndDelete() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let items = (0..<500).map { i in
            Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: Float(i), y: 10), StrokePoint(x: Float(i), y: 20)]))
        }
        let ctx = try await probeContext(h)
        let written = try ctx.mutate { tx in try tx.put(items, doc: self.doc, page: Fixtures.page2) }
        XCTAssertEqual(written.count, 500)
        let onPage = try h.app.workspace.items(doc, page: Fixtures.page2)
        XCTAssertEqual(onPage.map { $0.id }, written.map { $0.id }, "appended in order, on top")
        XCTAssertEqual(Set(onPage.map { $0.z }).count, 500)
        XCTAssertTrue(onPage.allSatisfy { $0.createdBy == "user" })

        let del = try await probeContext(h)
        XCTAssertThrowsError(try del.mutate { tx in
            try tx.delete(items: [written[0].id, "NOTANITEM001"], doc: self.doc, page: Fixtures.page2)
        })
        XCTAssertEqual(try h.app.workspace.items(doc, page: Fixtures.page2).count, 500, "nothing written on failure")
        try del.mutate { tx in try tx.delete(items: written.prefix(200).map { $0.id }, doc: self.doc, page: Fixtures.page2) }
        XCTAssertEqual(try h.app.workspace.items(doc, page: Fixtures.page2).count, 300)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testBatchCardsAppendInOrder() async throws {
        let h = Harness()
        let cards = (0..<50).map { StudyCard(front: CardFace(text: RichText(plain: "Q\($0)")), back: CardFace()) }
        let ctx = try await probeContext(h)
        let written = try ctx.mutate { tx in try tx.put(cards, doc: Fixtures.studySetID) }
        let live = try h.app.workspace.content(Fixtures.studySetID).liveCards
        XCTAssertEqual(live.suffix(50).map { $0.id }, written.map { $0.id })
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.studySetID).liveCards.count, 2)
    }

    func testHarnessInsertIsOneUndoStep() async throws {
        let h = Harness()
        let written = try await h.insert([Item.makeSticky(StickyItem(frame: Frame(x: 1, y: 1, w: 50, h: 50))),
                                          Item.makeSticky(StickyItem(frame: Frame(x: 60, y: 1, w: 50, h: 50)))],
                                         page: Fixtures.page2)
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(h.undoDepth(doc), 1)
        XCTAssertNil(h.app.commands.descriptor("nibtesting.insert"), "the helper command is removed again")
    }

    // MARK: CommandContext

    func testCommandContextReachesTheAppAndSessionDefaults() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        XCTAssertTrue(ctx.app === h.app)
        XCTAssertTrue(ctx.content === h.app.content)
        XCTAssertTrue(ctx.ui === h.app.ui)
        XCTAssertNil(ctx.navigator)
        XCTAssertEqual(try ctx.documentOrSession(nil), doc)
        XCTAssertEqual(try ctx.documentOrSession("doc:FIXTUREDOC02"), Fixtures.textDocID)
        let page = try ctx.pageOrSession(nil)
        XCTAssertEqual(page.doc, doc)
        XCTAssertEqual(page.page, page1)
        XCTAssertThrowsError(try ctx.pageOrSession("doc:FIXTUREDOC01"))
        XCTAssertEqual(ctx.refsOrSelection(nil), [])
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        XCTAssertEqual(ctx.refsOrSelection([]), ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"])

        XCTAssertFalse(ctx.isReadOnly(doc))
        h.app.services.set(NSMutableSet(array: [doc.raw]), for: ServiceKeys.storeReadOnly)
        XCTAssertTrue(ctx.isReadOnly(doc))
        XCTAssertTrue(h.app.isReadOnly(doc))
        XCTAssertFalse(ctx.isReadOnly(Fixtures.textDocID))
        XCTAssertEqual(h.app.deviceHex, "00000007")
    }

    func testUndoFallsBackToTheSessionDocumentForTheUser() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        try ctx.mutate { tx in try tx.delete(item: Fixtures.stickyID, doc: self.doc, page: self.page1) }
        let r = try await h.run(CommandIDs.undo)
        XCTAssertEqual(r["done"], true)
        XCTAssertNoThrow(try h.app.workspace.item(doc, page: page1, id: Fixtures.stickyID))
        do {
            try await h.run(CommandIDs.undo, [:], as: .ai("t"))
            XCTFail("non-user callers must name the document")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testInputFileSecurity() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        let host = FakePluginHost(hosts: ["example.org"])
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        h.app.gateway.grants = { p in
            if case .plugin = p { return [.documentRead, .network] }
            return Gateway.defaultGrants(p)
        }
        func denied(_ url: String, as principal: Principal, _ code: NibError.Code,
                    file: StaticString = #filePath, line: UInt = #line) async {
            do {
                try await h.run("v2probe.fetch", ["url": .string(url)], as: principal)
                XCTFail("\(url) must be refused for \(principal)", file: file, line: line)
            } catch let e as NibError {
                XCTAssertEqual(e.code, code, "\(url) as \(principal): \(e)", file: file, line: line)
            } catch {
                XCTFail("unexpected \(error)", file: file, line: line)
            }
        }
        // The old `case "https", "http" where principal.isUser` let every non-user principal download over https.
        await denied("http://example.org/a.pdf", as: .plugin("dev.test.plugin"), .permissionDenied)
        await denied("https://evil.example.com/a.pdf", as: .plugin("dev.test.plugin"), .permissionDenied)
        await denied("http://example.org/a.pdf", as: .ai("chat"), .permissionDenied)
        h.app.gateway.grants = { p in
            if case .ai = p { return [.documentRead] }
            return Gateway.defaultGrants(p)
        }
        await denied("https://example.org/a.pdf", as: .ai("chat"), .permissionDenied)
        await denied("tmp:../../secret", as: .user, .invalidParams)
        await denied("tmp:.hidden", as: .user, .invalidParams)

        let tmp = try h.assets.putTemporary(Data([1, 2, 3]), ext: "bin")
        let ok = try await h.run("v2probe.fetch", ["url": .string("tmp:" + tmp.name)])
        XCTAssertEqual(ok["size"], 3)
        XCTAssertEqual(NibLimits.maxDownloadBytes, 200 * 1_048_576)
    }

    func testClosureHookTransformsAndVetoes() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        h.app.bus.hooks.register(CommandHookDescriptor(id: "v2.hook", owner: "test", commands: ["v2probe.*"]) { command, params in
            if command == "v2probe.echo", params["veto"] == true { throw NibError(.userDenied, "vetoed") }
            return command == "v2probe.echo" ? params.merging(["hooked": true]) : nil
        })
        let r = try await h.run("v2probe.echo", ["x": 1])
        XCTAssertEqual(r["hooked"], true)
        XCTAssertEqual(r["x"], 1)
        do {
            try await h.run("v2probe.echo", ["veto": true])
            XCTFail("the hook vetoes")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
    }

    func testGatewayPerKindPresenterAndPolicy() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        let bridgeConfirmer = AutoConfirm()
        bridgeConfirmer.decision = .deny
        h.app.gateway.setPresenter(bridgeConfirmer, forPrincipalKind: "bridge")
        h.app.gateway.setPolicy(forPrincipalKind: "bridge") { _ in .always }
        XCTAssertEqual(h.app.gateway.policy(.bridge("c")), .always)
        XCTAssertEqual(h.app.gateway.policy(.ai("c")), .destructive)
        do {
            try await h.run("v2probe.create", as: .bridge("c"))
            XCTFail("the bridge presenter denies")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(bridgeConfirmer.requests.count, 1)
        XCTAssertTrue(h.confirmer.requests.isEmpty, "the app-wide presenter was not asked")
        _ = try await h.run("v2probe.create", as: .ai("c"))
        XCTAssertTrue(h.app.gateway.confirmationPresenter(for: .ai("c")) === h.confirmer)
    }

    // MARK: Session, events and registries

    func testSessionEventsTemporaryToolsAndInking() async throws {
        let h = Harness()
        var types: [String] = []
        let sub = h.app.events.subscribe { types.append($0.type) }
        defer { sub.cancel() }
        let other = EditorSession()
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(h.session)
        XCTAssertEqual(types.filter { $0 == NibEventType.sessionActivated }.count, 2)
        h.session.hiddenLayers = [1]
        h.session.activeLayer = 2
        XCTAssertEqual(types.filter { $0 == NibEventType.layersChanged }.count, 2)

        h.session.tool = "pen"
        try await h.run(CommandIDs.toolSelect, ["tool": "lasso", "temporary": true])
        XCTAssertEqual(h.session.tool, "lasso")
        XCTAssertEqual(h.session.temporaryReturnTool, "pen")
        let canvas = FakeCanvasHost(h)
        canvas.finishToolUse(StickyTestTool())
        XCTAssertEqual(h.session.tool, "pen", "a temporary tool returns after one use")
        XCTAssertNil(h.session.temporaryReturnTool)
        XCTAssertTrue(types.contains(NibEventType.toolFinished))
        try await h.run(CommandIDs.toolSelect, ["tool": "image"])
        canvas.finishToolUse(OneShotTestTool())
        XCTAssertEqual(h.session.tool, "pen", "a non-sticky tool hands back to the previous tool")

        var seen: [Bool] = []
        let watch = h.session.inking.observe { seen.append($0.isInking) }
        h.session.inking.begin(strokeBounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        h.session.inking.update(strokeBounds: CGRect(x: 0, y: 0, width: 20, height: 10))
        h.session.inking.end()
        watch.cancel()
        XCTAssertEqual(seen, [true, true, false])
        XCTAssertNil(h.session.inking.strokeBounds)
    }

    func testTypedEventPayloads() {
        let bus = EventBus()
        var got: SyncStatusPayload?
        let sub = bus.subscribe { got = $0.decode(SyncStatusPayload.self) ?? got }
        defer { sub.cancel() }
        let sent = SyncStatusPayload(state: "warning", source: "store", reason: "newerFormat", message: "read-only")
        let e = bus.emit(sent, doc: Fixtures.docID)
        XCTAssertEqual(e.type, NibEventType.syncStatus)
        XCTAssertEqual(got, sent)
        XCTAssertNil(e.decode(IndexProgressPayload.self))
        let laser = bus.emit(LaserMovedPayload(page: "page:D/P", point: nil, mode: "dot", color: .black))
        XCTAssertNil(laser.payload?["point"], "a lifted laser has no point")
        XCTAssertEqual(laser.decode(LaserMovedPayload.self)?.mode, "dot")
        XCTAssertEqual(IndexProgressPayload(running: true, done: 3, total: 10).pending, 7)
        for type in [AudioPlaybackPayload.eventType, AudioRecordingPayload.eventType, ShapeSnappedPayload.eventType,
                     PencilHapticPayload.eventType] {
            XCTAssertFalse(type.isEmpty)
        }
    }

    func testRegistryChangeNotificationsNameTheIDs() {
        let registry = Registry<TapePatternDescriptor>()
        let box = NoteBox()
        let token = NotificationCenter.default.addObserver(forName: .nibRegistryDidChange, object: registry, queue: nil) {
            box.notes.append($0)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        registry.register(TapePatternDescriptor(id: "tape.a", title: "A", owner: "p") { Data() })
        registry.register(TapePatternDescriptor(id: "tape.a", title: "A2", owner: "p") { Data() })
        registry.register(TapePatternDescriptor(id: "tape.b", title: "B", owner: "p") { Data() })
        registry.unregister(owner: "p")
        let notes = box.notes
        XCTAssertEqual(notes.map { RegistryChange.ids($0) }, [["tape.a"], ["tape.a"], ["tape.b"], ["tape.a", "tape.b"]])
        XCTAssertEqual(notes.map { $0.userInfo?[RegistryChange.kindKey] as? String },
                       [RegistryChange.registered, RegistryChange.replaced, RegistryChange.registered, RegistryChange.unregistered])
        XCTAssertEqual(registry.generation, 4)
    }

    func testChromeOverlayRegistry() {
        let h = Harness()
        var recording = false
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "audio.hud", owner: "audio", placement: .top, surface: .hud, order: 20,
            isVisible: { _ in recording }, makeView: { _ in AnyView(Text("REC")) }))
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "zoom.pane", owner: "zoom", placement: .bottom, surface: .panel, order: 10, recedesWhileWriting: false,
            docKinds: [.notebook], makeView: { _ in AnyView(Text("Zoom")) }))
        let notebook = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(notebook).map { $0.id }, ["zoom.pane"])
        recording = true
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(notebook).map { $0.id }, ["zoom.pane", "audio.hud"], "z-order by order")
        let board = ChromeContext(app: h.app, session: h.session, kind: .whiteboard)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(board).map { $0.id }, ["audio.hud"])
        XCTAssertFalse(h.app.ui.chromeOverlays.get("zoom.pane")?.recedesWhileWriting ?? true)

        let box = NoteBox()
        let token = NotificationCenter.default.addObserver(forName: .nibChromeNeedsUpdate, object: h.app.ui, queue: nil) {
            box.notes.append($0)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        h.app.ui.setNeedsChromeUpdate(h.session)
        XCTAssertEqual(box.notes.first?.userInfo?["session"] as? String, h.session.id.raw)
    }

    func testLiveDescriptorState() {
        let h = Harness()
        var item = ToolbarItemDescriptor(id: "undo", title: "Undo", icon: "arrow.uturn.backward", group: .navTrailing,
                                         order: 0, owner: "t", command: CommandIDs.undo, params: ["x": 1])
        item.sessionParams = { s in ["doc": .string(s.document.map { NodeRef.document($0).description } ?? "")] }
        item.isEnabled = { _ in false }
        item.sessionTitle = { _ in "Undo Add Page" }
        XCTAssertEqual(item.resolvedParams(for: h.session), ["x": 1, "doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(item.resolvedTitle(for: h.session), "Undo Add Page")
        XCTAssertEqual(item.resolvedIcon(for: h.session), "arrow.uturn.backward")
        XCTAssertEqual(item.isEnabled?(h.session), false)

        var key = KeyCommandDescriptor(id: "k", title: "K", shortcut: KeyShortcut("k", .command), command: "x.y", owner: "t")
        key.sessionParams = { s in ["page": .string(s.page?.raw ?? "")] }
        XCTAssertEqual(key.resolvedParams(for: h.session), ["page": "FIXTUREPG001"])
        XCTAssertEqual(key.resolvedParams(for: nil), [:])

        var menu = MenuItemDescriptor(id: "m", title: "Scroll", location: .documentMore, order: 0, owner: "t", command: "x.y")
        menu.isChecked = { _ in true }
        menu.contextTitle = { ctx in ctx.textRange.map { "Range \($0)" } ?? "none" }
        let ctx = MenuContext(app: h.app, folder: Fixtures.folderID, textRange: [2, 3])
        XCTAssertEqual(menu.resolvedTitle(for: ctx), "Range [2, 3]")
        XCTAssertEqual(menu.isChecked?(ctx), true)
    }

    // MARK: Model and geometry

    func testTemplateMetricsAndRegionRendering() {
        var t = TemplateDefinition(id: "t.grid", title: "Grid", category: "Essentials", owner: "t",
                                   defaults: ["spacing": 24, "margin": true]) { _, size, _ in
            TemplateRender(paper: .white, display: DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: size.width, height: size.height))]))
        }
        let m = t.metrics(for: [:], size: .a4)
        XCTAssertEqual(m.spacing, 24)
        XCTAssertEqual(m.repeatPeriod, PageSize(24, 24))
        XCTAssertEqual(m.margins?.left ?? 0, 25 * 72 / 25.4, accuracy: 1e-9)
        XCTAssertEqual(t.metrics(for: ["spacing": 30], size: nil).spacing, 30)
        XCTAssertEqual(t.renderOps([:], size: .a4, scale: 2, region: Rect(x: 0, y: 0, width: 10, height: 10)).display.ops.count, 1)
        t.renderRegion = { _, _, _, region in
            TemplateRender(paper: .white, display: DisplayList(ops: [DisplayOp(op: .dots, rect: region, spacing: 24),
                                                                     DisplayOp(op: .dots, rect: region, spacing: 12)]))
        }
        t.metricsProvider = { _, _ in TemplateMetrics(spacing: 12) }
        XCTAssertEqual(t.renderOps([:], size: .a4, scale: 2, region: Rect(x: 0, y: 0, width: 10, height: 10)).display.ops.count, 2)
        XCTAssertEqual(t.renderOps([:], size: .a4, scale: 2, region: nil).display.ops.count, 1)
        XCTAssertEqual(t.metrics(for: [:], size: .a4).spacing, 12)
    }

    func testDisplayOpTextAlignmentAndWeight() throws {
        let op = DisplayOp(op: .text, rect: Rect(x: 0, y: 0, width: 200, height: 30), fill: .black, text: "Monday",
                           fontSize: 18, align: .center, weight: .semibold)
        let back = try JSONValue.from(op).decode(DisplayOp.self)
        XCTAssertEqual(back, op)
        XCTAssertNil(try JSONValue.parse(#"{"op":"text","text":"x"}"#).decode(DisplayOp.self).align)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 30), format: format).image { ctx in
            DisplayList(ops: [op]).draw(in: ctx.cgContext)
        }
        XCTAssertEqual(image.size.width, 200)
    }

    func testFrameArrayFormAndRotatedNonUniformScale() {
        XCTAssertEqual(Frame(array: [1, 2, 3, 4]), Frame(x: 1, y: 2, w: 3, h: 4))
        XCTAssertEqual(Frame(array: [1, 2, 3, 4, 0.5])?.rotation, 0.5)
        XCTAssertNil(Frame(array: [1, 2, 3]))
        XCTAssertEqual(Frame(x: 1, y: 2, w: 3, h: 4, rotation: 0.25).array, [1, 2, 3, 4, 0.25])

        let plain = Frame(x: 0, y: 0, w: 100, h: 50)
        XCTAssertEqual(plain.applying(.scale(2, 1)), Frame(x: 0, y: 0, w: 200, h: 50), "unrotated frames as before")
        // A frame rotated 90°: its own width runs along the page's y axis, so a page-x stretch changes its HEIGHT.
        let turned = Frame(x: 0, y: 0, w: 100, h: 50, rotation: .pi / 2)
        let stretched = turned.applying(.scale(2, 1, about: turned.center))
        XCTAssertEqual(stretched.w, 100, accuracy: 1e-9)
        XCTAssertEqual(stretched.h, 100, accuracy: 1e-9)
        XCTAssertEqual(stretched.rotation, .pi / 2, accuracy: 1e-9)
        let rotated = turned.applying(.rotation(.pi / 2))
        XCTAssertEqual(rotated.rotation, .pi, accuracy: 1e-12, "similarity transforms keep the old arithmetic")
        XCTAssertEqual(rotated.w, 100, accuracy: 1e-9)

        let t = Affine.rotation(0.3).concatenating(.translation(5, -2)).concatenating(.scale(2, 3))
        let p = Point(7, 11)
        let back = t.inverted.map { $0.apply(t.apply(p)) }
        XCTAssertEqual(back?.x ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(back?.y ?? 0, 11, accuracy: 1e-9)
        XCTAssertNil(Affine.scale(0, 1).inverted)
    }

    func testPageBackgroundTransform() {
        let a4 = PageSize.a4
        XCTAssertEqual(PageRecord.backgroundTransform(sourceSize: a4, rotation: 0, pageSize: a4), .identity)
        // A landscape source turned 90° fits a portrait page exactly.
        let src = PageSize(841.89, 595.28)
        let t = PageRecord.backgroundTransform(sourceSize: src, rotation: 90, pageSize: a4)
        let topLeft = t.apply(.zero), topRight = t.apply(Point(src.width, 0))
        XCTAssertEqual(topLeft.x, a4.width, accuracy: 1e-6, "the source's top-left lands top-right")
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-6)
        XCTAssertEqual(topRight.x, a4.width, accuracy: 1e-6)
        XCTAssertEqual(topRight.y, a4.height, accuracy: 1e-6)
        // Letterboxed: a square source in A4 is centred vertically.
        var page = PageRecord(size: a4)
        page.rotation = 0
        let square = page.backgroundTransform(sourceSize: PageSize(100, 100))
        XCTAssertEqual(square.apply(.zero).y, (a4.height - a4.width) / 2, accuracy: 1e-6)
        XCTAssertEqual(PageRecord.scanTextExtKey, "nib.scanText")
    }

    func testBalancedFractionalKeys() {
        let keys = FractionalIndex.balanced(count: 10_000)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, 10_000)
        XCTAssertLessThanOrEqual(keys.map { $0.count }.max() ?? 0, 4)
        let inside = FractionalIndex.balanced(count: 20, after: "V", before: "W")
        XCTAssertTrue(inside.allSatisfy { $0 > "V" && $0 < "W" })
        XCTAssertEqual(inside, inside.sorted())
    }

    func testFragmentRoundTripAndInstantiate() throws {
        let parent = Item(id: "PARENT000001", kind: .shape, z: "V",
                          shape: ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 100, h: 100)))
        let child = Item(id: "CHILD0000001", kind: .image, z: "k", attachedTo: "PARENT000001",
                         image: ImageItem(frame: Frame(x: 10, y: 10, w: 20, h: 20), asset: Fixtures.pngAsset))
        let fragment = NibFragment.make(items: NibFragment.expand(["PARENT000001"], in: [parent, child])) { ref in
            ref == Fixtures.pngAsset ? Fixtures.pngData : nil
        }
        XCTAssertEqual(fragment.items.count, 2)
        XCTAssertEqual(fragment.assets[Fixtures.pngAsset.name], Fixtures.pngData)
        let data = try XCTUnwrap(fragment.encoded())
        let back = try NibFragment.decode(data)
        XCTAssertEqual(back, fragment)
        XCTAssertEqual(try JSONValue.parse(String(decoding: data, as: UTF8.self))["format"], "nib-fragment/1")
        let placed = back.instantiated(translate: Point(5, 5), ids: ["NEWPARENT001"], zAfter: "z", layer: 1,
                                       assets: [Fixtures.pngAsset.name: AssetRef("copied.png")])
        XCTAssertEqual(placed[0].id, "NEWPARENT001")
        XCTAssertEqual(placed[1].attachedTo, "NEWPARENT001")
        XCTAssertEqual(placed[1].image?.asset, AssetRef("copied.png"))
        XCTAssertEqual(placed[1].image?.frame.x, 15)
        XCTAssertTrue(placed.allSatisfy { $0.layer == 1 && $0.z > "z" })
        XCTAssertThrowsError(try NibFragment.decode(Data(#"{"format":"nib-fragment/9"}"#.utf8)))
    }

    func testModelAdditionsDecodeLeniently() throws {
        let style = try JSONValue.parse(#"{"padding":6,"align":"center","lineSpacing":4}"#).decode(TextBoxStyle.self)
        XCTAssertEqual(style.align, .center)
        XCTAssertEqual(style.lineSpacing, 4)
        XCTAssertNil(try JSONValue.parse(#"{"align":"sideways"}"#).decode(TextBoxStyle.self).align)
        let old = try JSONValue.from(TextBoxStyle())
        XCTAssertNil(old["align"], "unset paragraph defaults are not encoded")

        let image = try JSONValue.parse(#"{"frame":{"x":0,"y":0,"w":1,"h":1},"asset":"a.png","flipX":true}"#).decode(ImageItem.self)
        XCTAssertEqual(image.flipX, true)
        XCTAssertNil(image.flipY)
        XCTAssertNil(try JSONValue.from(ImageItem(frame: Frame(x: 0, y: 0, w: 1, h: 1), asset: AssetRef("a.png")))["flipX"])

        let rec = try JSONValue.parse(#"{"text":"hi","words":[{"text":"hi","bbox":[1,2,3,4]}]}"#).decode(TextRecognition.self)
        XCTAssertEqual(rec.words?.first?.text, "hi")
        XCTAssertEqual(rec.bbox, .zero)

        XCTAssertEqual(ShapeItem.quadraticControl(through: Point(0, 0), Point(50, 50), Point(100, 0)),
                       [Point(0, 0), Point(50, 100), Point(100, 0)])
        XCTAssertEqual(NibLimits.drawerMargin, 12)
        XCTAssertEqual(RGBA.highlighterAlpha, RGBA.highlighterYellow.a)
    }

    func testRichTextBridgeKeepsAModelFontThatIsNotInstalled() {
        var run = TextAttributes()
        run.font = "NoSuchFamilyV2"
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Hello", run)])])
        let back = RichTextBridge.richText(RichTextBridge.attributed(text))
        XCTAssertEqual(back.paragraphs.first?.runs.first?.attrs.font, "NoSuchFamilyV2")
        let plain = RichTextBridge.richText(RichTextBridge.attributed(RichText(plain: "Hello")))
        XCTAssertNil(plain.paragraphs.first?.runs.first?.attrs.font)
    }

    func testTextLayoutAndHitBounds() {
        let content = ContentRegistries()
        let box = Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 20, w: 100, h: 40), text: RichText(plain: "x"),
                                            style: TextBoxStyle(padding: 5)))
        XCTAssertEqual(content.textLayout(for: box)?.container, Frame(x: 15, y: 25, w: 90, h: 30))
        let note = Item.makeSticky(StickyItem(frame: Frame(x: 0, y: 0, w: 100, h: 100)))
        XCTAssertNil(content.textLayout(for: note))
        content.textLayouts.register(TextLayoutDescriptor(key: "sticky", owner: "sticky") { item in
            item.sticky.map { TextLayoutInfo(container: Frame(x: $0.frame.x + 12, y: $0.frame.y + 12, w: 76, h: 60)) }
        })
        XCTAssertEqual(content.textLayout(for: note)?.container.x, 12)
        XCTAssertEqual(TextLayoutInfo.lineFragmentPadding, 0)
        XCTAssertEqual(content.hitBounds(for: note), note.bounds)
        XCTAssertEqual(content.paintBounds(for: note), note.bounds.insetBy(-NibLimits.drawerMargin))
        content.drawers.register(ItemDrawerEntry(key: "sticky", owner: "sticky", drawer: IconOnlyDrawer()))
        XCTAssertEqual(content.hitBounds(for: note), Rect(x: 0, y: 0, width: 28, height: 28))
        XCTAssertEqual(content.paintBounds(for: note), note.bounds.insetBy(-NibLimits.drawerMargin))
    }

    func testWorkspaceCacheAccessors() throws {
        let h = Harness()
        let w = h.app.workspace
        var opened = 0
        let sub = h.app.events.subscribe { if $0.type == NibEventType.docOpened { opened += 1 } }
        defer { sub.cancel() }
        XCTAssertEqual(try w.peekContent(Fixtures.textDocID).meta.kind, .textDocument)
        XCTAssertFalse(w.isLoaded(Fixtures.textDocID), "peeking does not open the document")
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(w.isPageCached(doc, page: Fixtures.page2))
        XCTAssertNil(w.contentRevision(doc, page: Fixtures.page2), "unknown without loading (in-memory persistence)")
        _ = try w.items(doc, page: page1)
        XCTAssertTrue(w.isPageCached(doc, page: page1))
        XCTAssertTrue(w.cachedPages(doc).contains(page1))
        XCTAssertEqual(w.contentRevision(doc, page: page1), Rev(wallMs: 1, counter: 0, device: 0))
        XCTAssertFalse(w.isReadOnly(doc))
    }

    func testWindowShowLibraryUsesTheNavigator() async throws {
        let h = Harness()
        do {
            try await h.run(CommandIDs.windowShowLibrary)
            XCTFail("no window")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        let nav = RecordingNavigator(session: h.session)
        h.app.ui.activeNavigator = nav
        try await h.run(CommandIDs.windowShowLibrary, ["folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(nav.shownFolders, [Fixtures.folderID])
        nav.addTab(Fixtures.textDocID)
        XCTAssertEqual(nav.opened.map { $0.1 }, [.newTab], "default addTab opens a tab")

        var done: Result<ElementID?, NibError>?
        FakeCanvasHost(h).commitStroke(Stroke(style: .defaultPen, points: []), page: page1) { done = $0 }
        if case .success(let id)? = done { XCTAssertNil(id) } else { XCTFail("the default completion reports success") }
    }

    func testNewSettingsAreDeclared() async throws {
        let h = Harness()
        for name in ["appearance.liquid", "text.defaultStyle", "shapes.drawAndHold"] {
            XCTAssertNotNil(h.app.settings.descriptor(name), name)
        }
        try await h.run(CommandIDs.settingsSet, ["name": "appearance.liquid", "value": "calm"], as: .ai("t"))
        XCTAssertEqual(h.app.settings.get(NibSettings.liquidMode), "calm")
        XCTAssertEqual(NibSettings.defaultAIDirectTools.count, 8)
        XCTAssertEqual(BridgeNames.portSetting, "security.bridge.port")
        XCTAssertEqual(PanelIDs.trash, "organize.trash")
    }

    // MARK: Helpers

    private func probeContext(_ h: Harness, group: String? = nil) async throws -> CommandContext {
        var captured: CommandContext?
        let d = CommandDescriptor(id: "test.v2probe", title: "Probe", summary: "test", effect: .edit, exposure: .ui)
        h.app.commands.register(d) { _, ctx in
            captured = ctx
            return .null
        }
        try await h.app.bus.execute(Invocation(command: "test.v2probe", session: h.session, group: group))
        return try XCTUnwrap(captured)
    }

    /// The stand-ins F031's test registers for item.transform (F012) and item.update (F003).
    private func registerMoveStandIns(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.itemTransform, title: "Move", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["refs"]?[0]?.stringValue ?? ""),
                  let dx = json["translate"]?[0]?.doubleValue, let dy = json["translate"]?[1]?.doubleValue else {
                throw NibError.invalid("refs / translate")
            }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                try tx.put(item.transformed(by: .translation(dx, dy)), doc: doc, page: page)
            }
            return [:]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.itemUpdate, title: "Update", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                let merged = try JSONValue.from(item).merging(json["patch"] ?? [:]).decode(Item.self)
                try tx.put(merged, doc: doc, page: page)
            }
            return [:]
        }
    }
}

private extension Item {
    func with(id: ElementID) -> Item {
        var it = self
        it.id = id
        return it
    }
}

/// Commands the v2 tests call as other principals.
enum V2ProbeFeature: NibFeature {
    static let id = "v2probe"

    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "v2probe.create", title: "Create", summary: "Adds a sticky note (test).",
                                                examples: [[:]], effect: .edit)) { _, ctx in
            let item = try ctx.mutate { tx in
                try tx.put(Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 50, h: 50))), doc: Fixtures.docID,
                           page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description)]
        }
        app.commands.register(CommandDescriptor(id: "v2probe.move", title: "Move", summary: "Moves an item to page 2 (test).",
                                                params: .obj(["id": .str()], required: ["id"]),
                                                examples: [["id": "FIXTURESTY01"]], effect: .edit)) { json, ctx in
            let id = NibID(json["id"]?.stringValue ?? "")
            try ctx.mutate { tx in
                try tx.move(item: id, doc: Fixtures.docID, from: Fixtures.page1, to: Fixtures.page2,
                            transform: .translation(20, 0))
            }
            return [:]
        }
        app.commands.register(CommandDescriptor(id: "v2probe.fetch", title: "Fetch", summary: "Resolves a url param (test).",
                                                params: .obj(["url": .str()], required: ["url"]),
                                                examples: [["url": "tmp:x"]], effect: .read)) { json, ctx in
            let url = try await ctx.inputFile(json["url"]?.stringValue ?? "")
            let size = (try? Data(contentsOf: url).count) ?? -1
            return ["size": .number(Double(size))]
        }
        app.commands.register(CommandDescriptor(id: "v2probe.echo", title: "Echo", summary: "Returns its params (test).",
                                                examples: [[:]], effect: .read)) { json, _ in json }
    }
}

/// Collects notifications from `@Sendable` observer blocks.
private final class NoteBox {
    var notes: [Notification] = []
}

/// Minimal plugin host exposing one plugin whose manifest allows `hosts`.
@MainActor
private final class FakePluginHost: PluginHosting {
    let plugin: FakePluginHandle

    init(hosts: [String]) {
        var manifest = try! PluginManifest.fixture(id: "dev.test.plugin", permissions: ["document:read", "network"])
        manifest.network = PluginNetwork(hosts: hosts)
        plugin = FakePluginHandle(manifest: manifest)
    }

    var installed: [PluginInfo] { [] }
    func handle(_ id: String) -> PluginRuntimeHandle? { id == plugin.manifest.id ? plugin : nil }
    func folder(_ id: String) -> URL? { nil }
    func load(_ id: String) async throws {}
    func unload(_ id: String) {}
    func setEnabled(_ id: String, _ enabled: Bool) async throws {}
    var aiInstructions: [String] { [] }
}

@MainActor
private final class FakePluginHandle: PluginRuntimeHandle {
    let manifest: PluginManifest
    init(manifest: PluginManifest) { self.manifest = manifest }
    var logs: [String] { [] }
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue { .null }
    func deliver(_ event: NibEvent) {}
    func postMessage(from panel: String, message: JSONValue) {}
    func evaluate(_ javascript: String) async -> String { "" }
    func stop() {}
}

@MainActor
private final class StickyTestTool: CanvasTool {
    let id = "lasso"
    let inputMode = CanvasInputMode.samples
}

@MainActor
private final class OneShotTestTool: CanvasTool {
    let id = "image"
    let inputMode = CanvasInputMode.taps
    var isSticky: Bool { false }
}

/// A drawer whose hit area is only a 28 pt icon (collapsed sticky note).
private final class IconOnlyDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {}
    func hitBounds(_ item: Item) -> Rect? {
        guard let f = item.frame else { return nil }
        return Rect(x: f.x, y: f.y, width: 28, height: 28)
    }
}

@MainActor
private final class RecordingNavigator: SceneNavigator {
    let session: EditorSession
    private(set) var shownFolders: [FolderID?] = []
    private(set) var opened: [(DocumentID, OpenMode)] = []
    init(session: EditorSession) { self.session = session }
    var openDocuments: [DocumentID] { opened.map { $0.0 } }
    var activeDocument: DocumentID? { opened.last?.0 }
    var rootViewController: UIViewController? { nil }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) { opened.append((doc, mode)) }
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) { shownFolders.append(folder) }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}
