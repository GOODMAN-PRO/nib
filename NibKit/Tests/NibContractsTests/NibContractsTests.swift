import XCTest
import NibContracts
import NibTesting

@MainActor
final class NibContractsTests: XCTestCase {
    func testFractionalIndexOrdering() {
        var keys: [String] = []
        var last: String?
        for _ in 0..<200 {
            let k = FractionalIndex.between(last, nil)
            if let l = last { XCTAssertLessThan(l, k) }
            keys.append(k)
            last = k
        }
        for i in 0..<(keys.count - 1) {
            let m = FractionalIndex.between(keys[i], keys[i + 1])
            XCTAssertLessThan(keys[i], m)
            XCTAssertLessThan(m, keys[i + 1])
            XCTAssertFalse(m.hasSuffix("0"))
        }
        let first = FractionalIndex.between(nil, "1")
        XCTAssertLessThan(first, "1")
    }

    func testRevCodingAndOrder() throws {
        let a = Rev(wallMs: 10, counter: 1, device: 2)
        let b = Rev(wallMs: 10, counter: 2, device: 1)
        XCTAssertLessThan(a, b)
        XCTAssertEqual(Rev(string: a.description), a)
        XCTAssertLessThan(a.description, b.description)
        let data = try JSONEncoder().encode([a])
        XCTAssertEqual(try JSONDecoder().decode([Rev].self, from: data), [a])
    }

    func testStrokeCodecBothForms() throws {
        let s = Stroke(style: InkStyle(), points: [StrokePoint(x: 1, y: 2, t: 0.5, force: 0.7), StrokePoint(x: 3, y: 4)], t0: 100)
        let plain = try JSONValue.from(s)
        XCTAssertEqual(plain["fmt"], "full")
        let back = try plain.decode(Stroke.self)
        XCTAssertEqual(back.points.count, 2)
        XCTAssertEqual(back.points[0].force, 0.7, accuracy: 0.001)

        let encoder = JSONEncoder()
        encoder.userInfo[.nibCompactPoints] = true
        let compact = try JSONDecoder().decode(Stroke.self, from: try encoder.encode(s))
        XCTAssertEqual(compact.points, s.points)

        let aiStroke = try JSONValue.parse(#"{"fmt":"xy","pts":[10,10,20,20,30,15]}"#).decode(Stroke.self)
        XCTAssertEqual(aiStroke.points.count, 3)
        XCTAssertEqual(aiStroke.style.tool, .pen)
    }

    func testItemPayloadValidation() {
        var bad = Item(kind: .shape, stroke: Stroke(style: InkStyle(), points: []))
        XCTAssertFalse(bad.isValid)
        bad.kind = .stroke
        XCTAssertTrue(bad.isValid)
    }

    func testRichTextAcceptsPlainString() throws {
        let rt = try JSONValue.string("a\nb").decode(RichText.self)
        XCTAssertEqual(rt.paragraphs.count, 2)
        XCTAssertEqual(rt.plainText, "a\nb")
    }

    func testMutateCommitsAndUndoRestores() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        try ctx.mutate("Delete") { tx in
            try tx.delete(item: Fixtures.strokeID, doc: Fixtures.docID, page: Fixtures.page1)
        }
        XCTAssertNotEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertNotEqual(try h.snapshot(), before)
    }

    func testRollbackOnError() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        XCTAssertThrowsError(try ctx.mutate { tx in
            try tx.delete(item: Fixtures.shapeID, doc: Fixtures.docID, page: Fixtures.page1)
            throw NibError.invalid("boom")
        })
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testSelectiveRevertSkipsLaterEdits() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        try ctx.mutate { tx in
            var it = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            it.locked = true
            try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
        }
        let group = ctx.group
        let later = try await probeContext(h)
        try later.mutate { tx in
            var it = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            it.layer = 2
            try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
        }
        let r = h.app.bus.revert(group: group, doc: Fixtures.docID)
        XCTAssertEqual(r?.skipped, 1)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).layer, 2)
    }

    func testRemoteMergeIsLastWriterWins() throws {
        let h = Harness()
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        // Newer than the fixture rev but not far-future (that would be distrusted, see Rev.effective).
        item.rev = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000), counter: 0, device: 99)
        item.locked = true
        let patch = DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]])
        XCTAssertEqual(h.app.bus.applyRemote(patch, origin: "test").updated.count, 1)
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).locked)
        item.locked = false
        item.rev = Rev(wallMs: 5, counter: 0, device: 99)
        _ = h.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]]), origin: "test")
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).locked)
    }

    func testGatewayPermissions() async throws {
        let h = Harness()
        do {
            try await h.run("settings.set", ["name": "security.ai.confirmationPolicy", "value": "never"], as: .ai("t"))
            XCTFail("AI must not change security settings")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("edit.undo", ["doc": "doc:FIXTUREDOC01"], as: .plugin("x"))
            XCTFail("plugin without grants must be denied")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        let list = try await h.run("commands.list", ["namespace": "edit"], as: .ai("t"))
        XCTAssertEqual(list["commands"]?.arrayValue?.count, 2)
    }

    func testSchemaValidation() {
        let s = JSONSchema.obj(["page": .ref, "n": .int(min: 1)], required: ["page"])
        XCTAssertTrue(s.validate(["page": "page:A/B", "n": 2]).isEmpty)
        XCTAssertEqual(s.validate(["n": 0]).count, 2)
    }

    func testCoreCommandsConform() async {
        let problems = await CommandConformance.check(features: [])
        XCTAssertEqual(problems, [])
    }

    func testMinimalJSONDecodesForEveryRecordAndPayload() throws {
        func ok<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNoThrow(try JSONValue.parse(json).decode(T.self), "\(T.self) from \(json)", file: file, line: line)
        }
        ok(Item.self, #"{"kind":"shape","shape":{"shape":"rectangle","frame":{"x":1,"y":2,"w":3,"h":4}}}"#)
        ok(ShapeItem.self, #"{"shape":"line","points":[[0,0],[10,10]]}"#)
        ok(ConnectorItem.self, #"{"from":{"point":[0,0]},"to":{"item":"FIXTURESHP01","side":1}}"#)
        ok(TextBoxItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(ImageItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10},"asset":"a.png"}"#)
        ok(StickyItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(MathItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(CommentItem.self, #"{"anchor":[5,5]}"#)
        ok(CommentMessage.self, #"{"text":"hi"}"#)
        ok(CustomItem.self, #"{"owner":"p","type":"t","frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(DisplayList.self, #"{}"#)
        ok(PageRecord.self, #"{"size":{"width":595,"height":842}}"#)
        ok(OutlineEntry.self, #"{"title":"x"}"#)
        ok(AudioClip.self, #"{}"#)
        ok(TranscriptSegment.self, #"{"text":"x"}"#)
        ok(TextBlock.self, #"{"text":"plain"}"#)
        ok(CustomBlock.self, #"{"owner":"p","type":"t"}"#)
        ok(TableData.self, #"{}"#)
        ok(TableCell.self, #"{}"#)
        ok(TableMerge.self, #"{"row":0,"column":0}"#)
        ok(BlockComment.self, #"{"text":"x"}"#)
        ok(StudyCard.self, #"{"front":"Term","back":{"text":"Definition"}}"#)
        ok(CardFace.self, #""just text""#)
        ok(SRSState.self, #"{}"#)
        ok(DocumentMeta.self, #"{}"#)
        ok(LayerInfo.self, #"{"index":2}"#)
        ok(DocumentContent.self, #"{"meta":{}}"#)
        let face = try JSONValue.parse(#"{"ink":[{"fmt":"xy","pts":[0,0,5,5]}]}"#).decode(CardFace.self)
        XCTAssertEqual(face.kind, .ink)
    }

    func testDensifyClampsTheSplineEnds() {
        var s = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 0), StrokePoint(x: 10, y: 10)])
        InkModel.prepare(&s)
        XCTAssertEqual(s.points.prefix(3).map { $0.x }, [0, 0, 0])
        XCTAssertEqual(s.points.suffix(3).map { $0.y }, [10, 10, 10])
        XCTAssertTrue(s.points.allSatisfy { $0.width > 0 })
        for (a, b) in zip(s.points, s.points.dropFirst()) { XCTAssertLessThanOrEqual(a.location.distance(to: b.location), 1.5 + 1e-4) }
        let captured = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0, width: 2, height: 2), StrokePoint(x: 50, y: 0, width: 2, height: 2)])
        var copy = captured
        InkModel.prepare(&copy)
        XCTAssertEqual(copy, captured, "PencilKit-captured strokes are untouched")
    }

    func testFeatureCommandsAreOwnedByTheirFeature() {
        let h = Harness(features: [ProbeFeature.self])
        XCTAssertEqual(h.app.commands.descriptor("probe.stamp")?.owner, "probe")
        XCTAssertEqual(h.app.commands.descriptor("edit.undo")?.owner, "builtin")
        h.app.commands.unregister(owner: "probe")
        XCTAssertNil(h.app.commands.descriptor("probe.stamp"))
    }

    func testReadOnlyCallsCannotMutate() async throws {
        let h = Harness(features: [ProbeFeature.self])
        do {
            try await h.app.bus.execute(Invocation(command: "probe.stamp", principal: .ai("t"), readOnly: true))
            XCTFail("ask mode must refuse edit commands")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("probe.sneaky")
            XCTFail("a read command must not mutate")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("probe.nested")
            XCTFail("unknown nested commands are unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
    }

    func testProvenanceCannotBeForged() async throws {
        let h = Harness(features: [ProbeFeature.self])
        let r = try await h.run("probe.stamp", ["createdBy": "user"], as: .ai("chat1"))
        let ref = try XCTUnwrap(r["ref"]?.stringValue)
        guard case let .item(d, p, i)? = NodeRef(ref) else { return XCTFail("bad ref") }
        XCTAssertEqual(try h.app.workspace.item(d, page: p, id: i).createdBy, "ai:chat1")
    }

    func testSettingsAreDeclaredValidatedAndGuarded() async throws {
        let h = Harness()
        try await h.run("settings.set", ["name": "editing.openAsTabs", "value": false], as: .ai("t"))
        XCTAssertFalse(h.app.settings.get(NibSettings.openAsTabs))
        for (name, value, code) in [("nope.nothing", JSONValue.bool(true), NibError.Code.notFound),
                                    ("editing.openAsTabs", JSONValue.string("yes"), .invalidParams),
                                    ("managed.iCloudAllowed", JSONValue.bool(true), .permissionDenied)] {
            do {
                try await h.run("settings.set", ["name": .string(name), "value": value], as: .ai("t"))
                XCTFail("\(name) must be rejected")
            } catch let e as NibError {
                XCTAssertEqual(e.code, code, name)
            }
        }
        do {
            try await h.run("settings.get", ["name": "security.ai.confirmationPolicy"], as: .plugin("p"))
            XCTFail("security settings are user-only")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
    }

    func testFarFutureRevisionsLoseToCorrectlyClockedEdits() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var normal = OutlineEntry(id: "OUTLINEX0001", title: "edited today", page: nil)
        normal.rev = Rev(wallMs: nowMs, counter: 0, device: 1)
        var skewed = normal
        skewed.title = "device clock 30 days ahead"
        skewed.rev = Rev(wallMs: nowMs + 30 * 86_400_000, counter: 0, device: 9)
        XCTAssertEqual(LWW.merge([normal], [skewed]).first?.title, "edited today")
        XCTAssertEqual(LWW.merge([], [skewed]).first?.title, "device clock 30 days ahead")
    }

    func testSharedCanvasAndCollabFakes() async throws {
        let h = Harness()
        let canvas = FakeCanvasHost(h)
        canvas.zoomScale = 2
        let back = try XCTUnwrap(canvas.pagePoint(canvas.viewPoint(Point(10, 20), page: Fixtures.page2)))
        XCTAssertEqual(back.page, Fixtures.page2)
        XCTAssertEqual(back.point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(back.point.y, 20, accuracy: 1e-9)
        XCTAssertNil(canvas.pagePoint(CGPoint(x: -1, y: -1)))

        let hub = InMemoryCollabTransport.Hub()
        let a = InMemoryCollabTransport(hub: hub)
        let b = InMemoryCollabTransport(hub: hub)
        var received: [Data] = []
        b.onMessage = { _, data in received.append(data) }
        try await a.host(code: "ROOM01", displayName: "A")
        try await b.join(code: "ROOM01", displayName: "B")
        try a.send(Data([1]), to: nil)
        XCTAssertEqual(received, [Data([1])])
        XCTAssertEqual(a.peers.map(\.name), ["B"])
        b.leave()
        XCTAssertTrue(a.peers.isEmpty)
    }

    /// A context as a command would receive it (via a throwaway registered command).
    private func probeContext(_ h: Harness) async throws -> CommandContext {
        var captured: CommandContext?
        let d = CommandDescriptor(id: "test.probe", title: "Probe", summary: "test", effect: .edit, exposure: .ui)
        h.app.commands.register(d) { _, ctx in
            captured = ctx
            return .null
        }
        try await h.run("test.probe")
        return try XCTUnwrap(captured)
    }
}

/// A tiny feature used by the contract tests.
enum ProbeFeature: NibFeature {
    static let id = "probe"

    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "probe.stamp", title: "Stamp", summary: "Adds a sticky note (test).",
                                                examples: [[:]], effect: .edit)) { params, ctx in
            let item = try ctx.mutate { tx -> Item in
                var it = Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 50, h: 50)))
                it.createdBy = params["createdBy"]?.stringValue
                return try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description)]
        }
        app.commands.register(CommandDescriptor(id: "probe.sneaky", title: "Sneaky", summary: "A read command that tries to write (test).",
                                                examples: [[:]], effect: .read)) { _, ctx in
            try ctx.mutate { tx in try tx.delete(item: Fixtures.stickyID, doc: Fixtures.docID, page: Fixtures.page1) }
            return .null
        }
        app.commands.register(CommandDescriptor(id: "probe.nested", title: "Nested", summary: "Calls a missing command (test).",
                                                examples: [[:]], effect: .edit)) { _, ctx in
            try await ctx.execute("missing.command")
        }
    }
}
