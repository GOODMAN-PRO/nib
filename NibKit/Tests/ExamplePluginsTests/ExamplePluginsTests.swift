import XCTest
import NibContracts
import NibTesting
@testable import NibPluginHost
@testable import NibPluginRuntime
@testable import FeatPluginInstall
import FeatPluginPanels
import FeatQuery
import NibIndex
import FeatTextBox
import NibLibrary
import FeatStudyEditor
import FeatInkSynth
import FeatDocChrome

/// Files remain repository artifacts, rather than copies embedded in the test bundle, so a changed script or
/// manifest is exercised exactly as the gallery ships it. The simulator shares the build machine's filesystem.
private enum ExampleFiles {
    static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("plugins", isDirectory: true)
    }

    static func index() throws -> [JSONValue] {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
        XCTAssertEqual(json["version"]?.intValue, 1)
        return try XCTUnwrap(json["plugins"]?.arrayValue)
    }

    static func entry(_ folder: String) throws -> JSONValue {
        try XCTUnwrap(index().first { $0["base"]?.stringValue == "examples/\(folder)/" })
    }
}

@MainActor
private final class ExampleConsent: PluginConsentPresenting {
    var requests: [PluginConsentRequest] = []
    func requestConsent(_ request: PluginConsentRequest, navigator: SceneNavigator?) async throws -> PluginConsentDecision {
        requests.append(request)
        return .approve(Set(request.manifest.permissions))
    }
}

@MainActor
private final class ExampleUI: PluginUIPresenting {
    var toasts: [String] = []
    var choices: [[String]] = []
    var choice: Int? = 0
    var onChoose: (() async throws -> Void)?

    func toast(_ message: String, from plugin: PluginManifest) -> Bool { toasts.append(message); return true }
    func confirm(_ title: String, message: String?, from plugin: PluginManifest, timeout: TimeInterval) async throws -> Bool { true }
    func prompt(_ title: String, placeholder: String?, initial: String?, from plugin: PluginManifest, timeout: TimeInterval) async throws -> String? { nil }
    func choose(_ title: String, options: [String], from plugin: PluginManifest, timeout: TimeInterval) async throws -> Int? {
        choices.append(options)
        try await onChoose?()
        return choice
    }
}

/// Test-only adapters for the features F082's examples consume. Those feature modules are scaffold stubs in the
/// F078/F079 dependency checkout. These adapters read actual Harness documents, use FakeRecognizer, and write
/// through CommandContext.mutate, so the real bus enforces permissions, provenance, dry runs and undo. No adapter
/// is shipped with the plugins. Ink is a deterministic fixture stroke, not a substitute production typesetter.
@MainActor
private final class ExampleFixtureCommands {
    unowned let h: Harness
    let recognizer = FakeRecognizer()
    var inkCalls: [JSONValue] = []
    var openedPanels: [String] = []
    var getCalls = 0

    init(_ h: Harness) { self.h = h; h.app.services.recognizer = recognizer; register() }

    private func command(_ id: String, effect: Effect, target: CommandTarget = .document,
                         _ handler: @escaping @MainActor (JSONValue, CommandContext) async throws -> JSONValue) {
        guard h.app.commands.descriptor(id) == nil else { return }
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Harness fixture for \(id).",
                                                  params: .obj([:]), effect: effect, target: target,
                                                  owner: "example-fixtures"), handler: handler)
    }

    private func page(_ value: JSONValue?) throws -> (DocumentID, PageID) {
        guard let raw = value?.stringValue, case let .page(d, p)? = NodeRef(raw) else { throw NibError.invalid("expected page ref") }
        return (d, p)
    }

    private func selected(_ params: JSONValue, _ ctx: CommandContext) throws -> [(DocumentID, PageID, Item)] {
        try (params["refs"]?.arrayValue ?? []).map { value in
            guard let raw = value.stringValue, case let .item(d, p, i)? = NodeRef(raw) else { throw NibError.invalid("expected item ref") }
            return (d, p, try ctx.workspace.item(d, page: p, id: i))
        }
    }

    private func register() {
        command("query.context", effect: .read) { [self] _, ctx in
            let session = ctx.activeSession
            var out: [String: JSONValue] = ["selection": ["refs": .array((session?.selection.refs ?? []).map(JSONValue.string))],
                                           "session": ["openPanels": .array((session?.openPanels.sorted() ?? []).map(JSONValue.string))]]
            if let d = session?.document {
                out["document"] = ["ref": .string(NodeRef.document(d).description), "title": .string(h.library.node(d)?.title ?? "")]
                if let p = session?.page {
                    let pages = try ctx.workspace.content(d).livePages
                    out["page"] = ["ref": .string(NodeRef.page(d, p).description), "index": .number(Double(pages.firstIndex { $0.id == p } ?? 0))]
                }
            }
            return .object(out)
        }
        command("query.get", effect: .read) { [self] params, ctx in
            getCalls += 1
            guard let raw = params["ref"]?.stringValue, case let .item(d, p, i)? = NodeRef(raw) else { throw NibError.invalid("expected item ref") }
            let item = try ctx.workspace.item(d, page: p, id: i)
            // Mirror query.get's summary: points are opt-in and no hidden Item revision is returned.
            var out: [String: JSONValue] = ["ref": .string(raw), "kind": .string(item.kind.rawValue),
                                            "bbox": try JSONValue.from(item.bounds), "layer": .number(Double(item.layer))]
            if let stroke = item.stroke {
                out["tool"] = .string(stroke.style.tool.rawValue)
                out["color"] = try JSONValue.from(stroke.style.color)
                out["width"] = .number(stroke.style.width)
                out["pointCount"] = .number(Double(stroke.points.count))
                if params["points"] == true {
                    out["stroke"] = try JSONValue.from(stroke)
                }
            }
            return .object(out)
        }
        command("recognize.items", effect: .read) { [self] params, ctx in
            let selected = try selected(params, ctx)
            let ink = selected.map { $0.2 }.filter { $0.kind == .stroke }
            let recognized = ink.isEmpty ? [] : try await recognizer.recognize(strokes: ink, language: "en")
            let typed = selected.compactMap { $0.2.text?.text.plainText }
            let lines: [JSONValue] = try recognized.map { line in
                let words: [JSONValue] = try (line.words ?? []).map { word in
                    ["text": .string(word.text), "bbox": try JSONValue.from(word.bbox),
                     "refs": .array(word.itemIDs.map { .string(NodeRef.item(selected[0].0, selected[0].1, $0).description) })]
                }
                return ["text": .string(line.text), "bbox": try JSONValue.from(line.bbox), "words": .array(words)]
            }
            return ["text": .string((recognized.map(\.text) + typed).joined(separator: "\n")), "lines": .array(lines)]
        }
        command("recognize.pageText", effect: .read) { [self] params, ctx in
            let (d, p) = try page(params["page"])
            let items = try ctx.workspace.items(d, page: p)
            let ink = items.filter { $0.kind == .stroke }
            let recognized = ink.isEmpty ? [] : try await recognizer.recognize(strokes: ink, language: "en")
            let texts = recognized.map(\.text) + items.compactMap { $0.text?.text.plainText }
            return ["blocks": .array(texts.map { ["text": .string($0)] })]
        }
        command("text.createBox", effect: .edit) { [self] params, ctx in
            let (d, p) = try page(params["page"])
            let frame = try XCTUnwrap(params["frame"]).decode(Frame.self)
            let item = Item(id: params["id"]?.stringValue.map { NibID($0) } ?? .make(), kind: .text,
                            text: TextBoxItem(frame: frame, text: RichText(plain: params["text"]?.stringValue ?? "")))
            let stored = try ctx.mutate { try $0.put(item, doc: d, page: p) }
            return ["ref": .string(NodeRef.item(d, p, stored.id).description)]
        }
        command("doc.create", effect: .library, target: .library) { params, ctx in
            let id = params["id"]?.stringValue.map { NibID($0) } ?? .make()
            let content = DocumentContent(meta: DocumentMeta(id: id, kind: .studySet))
            _ = try ctx.services.library?.createDocument(content, title: params["title"]?.stringValue ?? "Cards", in: nil)
            return ["ref": .string(NodeRef.document(id).description)]
        }
        command("card.add", effect: .edit) { params, ctx in
            guard let raw = params["doc"]?.stringValue, case let .document(d)? = NodeRef(raw) else { throw NibError.invalid("expected document ref") }
            let content = try ctx.workspace.content(d)
            let card = StudyCard(id: params["id"]?.stringValue.map { NibID($0) } ?? .make(),
                                 front: try XCTUnwrap(params["front"]).decode(CardFace.self),
                                 back: try XCTUnwrap(params["back"]).decode(CardFace.self),
                                 order: FractionalIndex.between(content.liveCards.last?.order, nil))
            let stored = try ctx.mutate { try $0.put(card, doc: d) }
            return ["ref": .string(NodeRef.card(d, stored.id).description)]
        }
        command("ink.writeText", effect: .edit) { [self] params, ctx in
            inkCalls.append(params)
            let (d, p) = try page(params["page"])
            let at = try XCTUnwrap(params["at"]).decode(Point.self)
            let id = params["ids"]?.arrayValue?.first?.stringValue.map { NibID($0) } ?? .make()
            let item = Item(id: id, kind: .stroke, stroke: Stroke(style: .defaultPen, points: [
                StrokePoint(x: Float(at.x), y: Float(at.y)), StrokePoint(x: Float(at.x + 16), y: Float(at.y + 4))]))
            let stored = try ctx.mutate { try $0.put(item, doc: d, page: p) }
            return ["refs": [.string(NodeRef.item(d, p, stored.id).description)]]
        }
        command("panel.open", effect: .session, target: .app) { [self] params, ctx in
            let id = try XCTUnwrap(params["id"]?.stringValue)
            let panel = try XCTUnwrap(ctx.ui?.panels.get(id))
            ctx.activeSession?.openPanels.insert(id)
            openedPanels.append(id)
            return ["id": .string(id), "placement": .string(panel.placement.rawValue)]
        }
    }

    func partialWord(_ word: String = "hel") {
        var line = TextRecognition(text: "Say \(word)", bbox: Rect(x: 72, y: 120, width: 100, height: 20),
                                   itemIDs: [Fixtures.strokeID], source: "ink")
        line.words = [TextRecognitionWord(text: word, bbox: Rect(x: 110, y: 120, width: 40, height: 20), itemIDs: [Fixtures.strokeID])]
        recognizer.script = [line]
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
    }
}

@MainActor
private final class ExampleKit {
    let h: Harness
    let api: ExampleFixtureCommands
    let host: PluginHost
    let runtime: PluginRuntime
    let installer: PluginInstaller
    let consent = ExampleConsent()
    let ui = ExampleUI()
    let ai = FakeAIService()
    let base: URL

    init() throws {
        h = Harness(features: [NibPluginRuntimeFeature.self, NibPluginHostFeature.self, FeatPluginPanelsFeature.self,
                               FeatPluginInstallFeature.self, FeatQueryFeature.self, NibIndexFeature.self,
                               FeatTextBoxFeature.self, NibLibraryFeature.self, FeatStudyEditorFeature.self,
                               FeatInkSynthFeature.self, FeatDocChromeFeature.self])
        api = ExampleFixtureCommands(h)
        host = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginHost, as: PluginHost.self))
        runtime = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntime.self))
        installer = try XCTUnwrap(h.app.services.get(PluginInstaller.serviceKey, as: PluginInstaller.self))
        base = FileManager.default.temporaryDirectory.appendingPathComponent("nib-examples-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let grants = base.appendingPathComponent("PluginGrants.json")
        installer.grants = PluginGrantFile(url: grants)
        installer.stagingParent = base.appendingPathComponent("staging")
        installer.consent = consent
        host.authority.store = PluginGrantStore(url: grants)
        host.isSafeMode = { false }
        runtime.isSafeMode = { false }
        runtime.ui = ui
        h.app.services.ai = ai
    }

    func install(_ folder: String) async throws -> PluginManifest {
        let entry = try ExampleFiles.entry(folder)
        let source = ExampleFiles.root.appendingPathComponent(try XCTUnwrap(entry["base"]?.stringValue))
        let result = try await h.run("plugin.install", ["path": .string(source.path), "sha256": try XCTUnwrap(entry["sha256"])])
        XCTAssertEqual(result["state"]?.stringValue, "running", result.jsonString())
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        XCTAssertNotNil(host.handle(manifest.id))
        return manifest
    }

    func close() {
        for info in host.installed { host.unload(info.id) }
        h.app.commands.unregister(owner: "example-fixtures")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: h.persistence.root)
    }
}

@MainActor
final class ExamplePluginsTests: XCTestCase {
    func testGalleryListsExactlySevenCompleteHashVerifiedPackages() throws {
        let entries = try ExampleFiles.index()
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(Set(entries.compactMap { $0["id"]?.stringValue }).count, 7)
        for entry in entries {
            let folder = ExampleFiles.root.appendingPathComponent(try XCTUnwrap(entry["base"]?.stringValue))
            let files = try PluginPackageHash.files(folder).map(\.path)
            XCTAssertEqual(entry["files"]?.arrayValue?.compactMap(\.stringValue), files)
            let gallery = try PluginSource.from(url: nil, path: nil, files: entry["files"],
                                                base: entry["base"]?.stringValue,
                                                index: "https://example.com/plugins/index.json",
                                                expectedHash: entry["sha256"]?.stringValue)
            XCTAssertEqual(gallery, .gallery(base: try XCTUnwrap(URL(string: "https://example.com/plugins/examples/" + folder.lastPathComponent + "/", relativeTo: nil)), files: files))
            XCTAssertEqual(entry["sha256"]?.stringValue, try PluginPackageHash.compute(folder))
            XCTAssertEqual(try PluginFolderHash.compute(folder), try PluginPackageHash.compute(folder))
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            XCTAssertEqual(manifest.id, entry["id"]?.stringValue)
            XCTAssertEqual(manifest.permissions, entry["permissions"]?.arrayValue?.compactMap(\.stringValue))
            XCTAssertTrue(ManifestValidator.problems(manifest, folder: folder).isEmpty, manifest.id)
            XCTAssertTrue(ManifestCheck.problems(manifest, root: folder).isEmpty, manifest.id)
            for command in manifest.contributes?.commands ?? [] {
                XCTAssertNotNil(command.params?["properties"])
                XCTAssertFalse(command.examples?.isEmpty ?? true)
                let descriptor = ContributionMapper.descriptor(command, owner: manifest.id, exposeHidden: false)
                for example in command.examples ?? [] { XCTAssertTrue(descriptor.params.validate(example).isEmpty) }
            }
        }
    }

    func testAllExamplesInstallRunAndUnloadWithRealJavaScriptRuntime() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        for entry in try ExampleFiles.index() {
            let folder = try XCTUnwrap(entry["base"]?.stringValue).split(separator: "/")[1]
            let manifest = try await kit.install(String(folder))
            try assertContributions(manifest, kit: kit)
            switch String(folder) {
            case "hello-world":
                let toolbarID = try XCTUnwrap(manifest.contributes?.toolbar?.first?.id)
                let toolbar = try XCTUnwrap(kit.h.app.ui.toolbar.get(toolbarID))
                _ = try await kit.h.run(try XCTUnwrap(toolbar.command), ["id": "EXAMPLEHELLO"])
                XCTAssertEqual(kit.ui.toasts.count, 1)
            case "flashcards-from-selection":
                kit.h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
                kit.api.recognizer.script = [TextRecognition(text: "Velocity — Displacement over time", bbox: .zero, source: "ink")]
                let result = try await kit.h.run("dev.nib.cards.fromSelection", ["id": "EXAMPLECARDS"])
                XCTAssertEqual(result["cards"], 1)
            case "word-count":
                let result = try await kit.h.run("dev.nib.wordcount.show")
                XCTAssertNotNil(result["words"])
            case "word-complete":
                kit.api.partialWord()
                kit.ai.responses = [.init(text: "{\"options\":[\"hello\"]}")]
                let result = try await kit.h.run("dev.nib.wordcomplete.suggest", ["ids": ["EXAMPLEINK"]])
                XCTAssertEqual(result["suffix"], "lo")
            default:
                // Content packages have no mutating main command: execute the entry, then render every template.
                XCTAssertTrue(manifest.contributes?.commands?.isEmpty ?? true)
                for template in kit.h.app.content.templates.all where template.owner == manifest.id {
                    XCTAssertFalse(template.render([:], .a4, 1).display.ops.isEmpty)
                }
            }
            let handle = try XCTUnwrap(kit.host.handle(manifest.id))
            XCTAssertFalse(handle.logs.contains { $0.contains("[error]") }, manifest.id)
            kit.host.unload(manifest.id)
            XCTAssertNil(kit.host.handle(manifest.id))
            XCTAssertNil(kit.runtime.handle(manifest.id))
            XCTAssertFalse(kit.h.app.commands.all().contains { $0.owner == manifest.id })
            XCTAssertFalse(kit.h.app.ui.toolbar.all.contains { $0.owner == manifest.id })
            XCTAssertFalse(kit.h.app.ui.menus.all.contains { $0.owner == manifest.id })
            XCTAssertFalse(kit.h.app.ui.panels.all.contains { $0.owner == manifest.id })
            XCTAssertFalse(kit.h.app.content.templates.all.contains { $0.owner == manifest.id })
            XCTAssertFalse(kit.h.app.content.elementCollections.all.contains { $0.owner == manifest.id })
            XCTAssertFalse(kit.h.app.content.boardTemplates.all.contains { $0.owner == manifest.id })
        }
        XCTAssertEqual(kit.consent.requests.count, 7)
    }

    func testHelloUsesCallerIDProvenanceUndoRedoAndDryRun() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("hello-world")
        let before = try kit.h.snapshot()
        let result = try await kit.h.run("dev.nib.hello.stamp", ["id": "HELLOSTAMP01"])
        XCTAssertEqual(result["ref"], "item:FIXTUREDOC01/FIXTUREPG001/HELLOSTAMP01")
        let item = try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "HELLOSTAMP01")
        XCTAssertEqual(item.text?.text.plainText, "Hello from a plugin 👋")
        XCTAssertEqual(item.createdBy, "plugin:dev.nib.hello")
        XCTAssertEqual(kit.h.undoDepth(Fixtures.docID), 1)
        XCTAssertEqual(kit.ui.toasts.count, 1)
        XCTAssertTrue(kit.h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try kit.h.snapshot(), before)
        XCTAssertTrue(kit.h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "HELLOSTAMP01").text?.text.plainText, item.text?.text.plainText)
        let restored = try kit.h.snapshot()
        _ = try await kit.h.app.bus.execute(Invocation(command: "dev.nib.hello.stamp", params: ["id": "DRYSTAMP01"], session: kit.h.session, dryRun: true))
        XCTAssertEqual(try kit.h.snapshot(), restored)
    }

    func testFlashcardsParseFirstSeparatorSkipIncompleteAndGroupUndo() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("flashcards-from-selection")
        kit.h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
        kit.api.recognizer.script = [TextRecognition(text: " Velocity — displacement — over time \ninvalid\n — empty\nMass — matter ", bbox: .zero, source: "ink")]
        let result = try await kit.h.run("dev.nib.cards.fromSelection", ["id": "NEWSTUDY01", "ids": ["NEWCARD01", "NEWCARD02"]])
        XCTAssertEqual(result["set"], "doc:NEWSTUDY01")
        XCTAssertEqual(result["cards"], 2)
        let d: DocumentID = "NEWSTUDY01"
        let cards = try kit.h.app.workspace.content(d).liveCards
        XCTAssertEqual(cards.map(\.id), ["NEWCARD01", "NEWCARD02"])
        XCTAssertEqual(cards[0].back.text?.plainText, "displacement — over time")
        XCTAssertEqual(cards[1].front.text?.plainText, "Mass")
        XCTAssertEqual(kit.h.app.bus.history.entries(d).first?.principal, .plugin("dev.nib.cards"))
        XCTAssertEqual(kit.h.undoDepth(d), 1)
        XCTAssertTrue(kit.h.app.bus.undo(d))
        XCTAssertTrue(try kit.h.app.workspace.content(d).liveCards.isEmpty)
        XCTAssertTrue(kit.h.app.bus.redo(d))
        XCTAssertEqual(try kit.h.app.workspace.content(d).liveCards.count, 2)
        let command = kit.host.handle("dev.nib.cards")?.manifest.contributes?.commands?.first
        XCTAssertEqual(command?.aiDirect, true)
        XCTAssertEqual(kit.h.app.commands.descriptor("dev.nib.cards.fromSelection")?.exposure, .all)
    }

    func testFlashcardsRejectEmptyPairsAndMismatchedIDsBeforeCreatingDocument() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("flashcards-from-selection")
        let initial = kit.h.library.allNodes().count
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.cards.fromSelection") }
        kit.h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.cards.fromSelection", ["separator": ""]) }
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.cards.fromSelection") }
        kit.h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
        kit.api.recognizer.script = [TextRecognition(text: "a — b", bbox: .zero, source: "ink")]
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.cards.fromSelection", ["ids": []]) }
        XCTAssertEqual(kit.h.library.allNodes().count, initial)
    }

    func testWordCountPanelMessagesAndCoalescedEventsFollowCurrentPage() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-count")
        kit.api.recognizer.script = [TextRecognition(text: "  one\n two don't — café  ", bbox: .zero, source: "ink")]
        let count = try await kit.h.run("dev.nib.wordcount.show")
        XCTAssertEqual(count["words"], 6) // Four recognised words plus the fixture's “Hello Nib”.
        XCTAssertEqual(count["pageNumber"], 1)
        XCTAssertEqual(kit.api.openedPanels, ["dev.nib.wordcount.panel"])
        let seq = kit.h.app.events.events(since: 0).last?.seq ?? 0
        for _ in 0..<8 { kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID) }
        kit.h.session.page = Fixtures.page2
        let refreshed = await eventually {
            kit.h.app.events.events(since: seq).contains { $0.type == NibEventType.pluginMessage && $0.payload?["message"]?["pageNumber"] == 2 }
        }
        XCTAssertTrue(refreshed)
        let messages = kit.h.app.events.events(since: seq).filter { $0.type == NibEventType.pluginMessage }
        XCTAssertEqual(messages.last?.payload?["message"]?["words"], 0)
        XCTAssertEqual(messages.count, 1)
        let seq2 = kit.h.app.events.events(since: 0).last?.seq ?? 0
        kit.host.handle("dev.nib.wordcount")?.postMessage(from: "dev.nib.wordcount.panel", message: ["type": "refresh"])
        let initialized = await eventually { kit.h.app.events.events(since: seq2).contains { $0.type == NibEventType.pluginMessage } }
        XCTAssertTrue(initialized)
        kit.h.session.document = nil
        kit.h.session.page = nil
        let empty = try await kit.h.run("dev.nib.wordcount.count")
        XCTAssertEqual(empty["words"], 0)
    }

    func testWordCountSegmentsThaiDevanagariAndCJK() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-count")
        for text in ["สวัสดี ครับ", "नमस्ते दुनिया", "你好世界"] {
            kit.api.recognizer.script = [TextRecognition(text: text, bbox: .zero, source: "ink")]
            let result = try await kit.h.run("dev.nib.wordcount.count")
            XCTAssertEqual(result["words"], 4, text) // Two segmented words plus “Hello Nib”.
        }
    }

    func testWordCountAvoidsRecognitionWhenClosedOrAnotherDocumentCommits() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-count")
        kit.h.app.events.emit(NibEventType.committed, doc: Fixtures.docID)
        kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, 0)
        _ = try await kit.h.run("dev.nib.wordcount.show")
        let before = kit.api.recognizer.strokeCalls
        kit.h.app.events.emit(NibEventType.committed, doc: "OTHERDOC01")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, before)
        for _ in 0..<8 { kit.h.app.events.emit(NibEventType.committed, doc: Fixtures.docID) }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, before)
        let refreshed = await eventually { kit.api.recognizer.strokeCalls == before + 1 }
        XCTAssertTrue(refreshed)
        // The authoritative session state closes the panel even if its web message is lost.
        kit.h.session.openPanels.remove("dev.nib.wordcount.panel")
        kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, before + 1)
        kit.host.handle("dev.nib.wordcount")?.postMessage(from: "dev.nib.wordcount.panel", message: ["type": "closed"])
        kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, before + 1)
    }

    func testWordCompleteAcceptsThaiDevanagariAndCJK() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-complete")
        for (partial, completion) in [("สว", "สวัสดี"), ("नम", "नमस्ते"), ("你", "你好")] {
            kit.api.partialWord(partial)
            kit.ai.responses = [.init(text: try JSONValue.from(["options": [completion]]).jsonString())]
            let result = try await kit.h.run("dev.nib.wordcomplete.suggest")
            XCTAssertEqual(result["completion"]?.stringValue, completion)
        }
        XCTAssertEqual(kit.api.inkCalls.count, 3)
    }

    func testWordCompleteBoundsSelectionBeforeQueryingOrSendingToAI() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-complete")
        let refs = (0..<201).map { JSONValue.string("item:FIXTUREDOC01/FIXTUREPG001/INK\($0)") }
        await assertError(.invalidParams) {
            _ = try await kit.h.run("dev.nib.wordcomplete.suggest", ["selection": .array(refs)])
        }
        XCTAssertEqual(kit.api.getCalls, 0)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, 0)
        XCTAssertTrue(kit.ai.requests.isEmpty)
    }

    func testWordCompleteFiltersAISuggestionsAppendsSuffixAndUndoRedo() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-complete")
        kit.api.partialWord()
        kit.ai.responses = [.init(text: "{\"options\":[\"help\",\"HELP\",\"no\",\"hello world\",42,\"hello\"]}")]
        let before = try kit.h.snapshot()
        let result = try await kit.h.run("dev.nib.wordcomplete.suggest", ["ids": ["COMPLETEINK01"]])
        XCTAssertEqual(result["completion"], "help")
        XCTAssertEqual(result["suffix"], "p")
        XCTAssertEqual(kit.ui.choices, [["help", "hello"]])
        XCTAssertEqual(kit.api.inkCalls[0]["page"], "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(kit.api.inkCalls[0]["at"], [150, 120])
        XCTAssertEqual(kit.api.inkCalls[0]["size"], 20)
        XCTAssertEqual(kit.ai.requests.first?.principal, .plugin("dev.nib.wordcomplete"))
        XCTAssertEqual(kit.ai.requests.first?.tools, [])
        XCTAssertEqual(kit.ai.requests.first?.mode, .ask)
        XCTAssertEqual(try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "COMPLETEINK01").createdBy, "plugin:dev.nib.wordcomplete")
        XCTAssertEqual(kit.h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(kit.h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try kit.h.snapshot(), before)
        XCTAssertTrue(kit.h.app.bus.redo(Fixtures.docID))
        XCTAssertNotNil(try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: "COMPLETEINK01").stroke)
    }

    func testWordCompleteCancelMalformedAIAndChangedInkNeverWrite() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-complete")
        kit.api.partialWord()
        kit.ui.choice = nil
        kit.ai.responses = [.init(text: "{\"options\":[\"hello\"]}")]
        let cancelled = try await kit.h.run("dev.nib.wordcomplete.suggest")
        XCTAssertEqual(cancelled["cancelled"], true)
        kit.ai.responses = [.init(text: "not JSON")]
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.wordcomplete.suggest") }
        kit.ai.responses = [.init(text: "{\"options\":[\"unrelated\"]}")]
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.wordcomplete.suggest") }
        kit.ui.choice = 0
        kit.ui.onChoose = {
            var item = try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
            // Keep bbox, point count and style identical; only an interior point changes.
            let bounds = item.bounds
            let count = item.stroke?.points.count
            item.stroke?.points[1].force = 0.25
            XCTAssertEqual(item.bounds, bounds)
            XCTAssertEqual(item.stroke?.points.count, count)
            try await kit.h.insert([item])
        }
        kit.ai.responses = [.init(text: "{\"options\":[\"hello\"]}")]
        await assertError(.conflict) { _ = try await kit.h.run("dev.nib.wordcomplete.suggest") }
        XCTAssertTrue(kit.api.inkCalls.isEmpty)
        kit.h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.wordcomplete.suggest") }
    }

    func testAskModeAndRevokedAIPermissionCannotModifyHandwriting() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-complete")
        kit.api.partialWord()
        let before = try kit.h.snapshot()
        await assertError(.permissionDenied) {
            _ = try await kit.h.app.bus.execute(Invocation(command: "dev.nib.wordcomplete.suggest", session: kit.h.session, readOnly: true))
        }
        let id = "dev.nib.wordcomplete"
        let grant = try XCTUnwrap(kit.installer.grants.grant(id))
        try kit.installer.grants.set(StoredGrant(sha256: grant.sha256, scopes: ["document:read", "document:write"]), for: id)
        try await kit.host.load(id)
        await assertError(.permissionDenied) { _ = try await kit.h.run("dev.nib.wordcomplete.suggest") }
        XCTAssertEqual(try kit.h.snapshot(), before)
        XCTAssertTrue(kit.ai.requests.isEmpty)
        XCTAssertTrue(kit.api.inkCalls.isEmpty)
    }

    func testParametricTemplatesAndNativeStarterPackContent() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("weekly-planner")
        let planner = try XCTUnwrap(kit.h.app.content.templates.get("dev.nib.planner.weekly"))
        let rendered = planner.render(["accent": "#FF0000FF", "heading": "Weekly plan", "lineSpacing": 24], .a4, 1)
        XCTAssertEqual(rendered.display.ops.first?.text, "Weekly plan")
        XCTAssertEqual(rendered.display.ops.first?.stroke, RGBA(hex: "#FF0000FF"))
        XCTAssertEqual(rendered.display.ops.filter { $0.op == .hlines }.count, 7)
        XCTAssertTrue(rendered.display.ops.filter { $0.op == .hlines }.allSatisfy { $0.spacing == 24 })
        _ = try await kit.install("graph-paper")
        let graph = kit.h.app.content.templates.all.filter { $0.owner == "dev.nib.graph" }
        XCTAssertEqual(graph.count, 3)
        for template in graph {
            let r = template.render(["spacing": 12, "grid": "#00FF00FF"], .a4, 1)
            XCTAssertEqual(r.display.ops.map(\.spacing), [12, 12])
            XCTAssertTrue(r.display.ops.allSatisfy { $0.stroke == RGBA(hex: "#00FF00FF") })
        }
        _ = try await kit.install("starter-pack")
        let templates = kit.h.app.content.templates.all.filter { $0.owner == "dev.nib.starter" }
        XCTAssertEqual(templates.filter(\.isCover).count, 1)
        XCTAssertEqual(templates.filter { !$0.isCover }.count, 2)
        let arrows = try XCTUnwrap(kit.h.app.content.elementCollections.get("dev.nib.starter.arrows")).load()
        XCTAssertEqual(arrows.map(\.id), ["right", "down"])
        for arrow in arrows {
            XCTAssertEqual(arrow.fragment["format"], "nib-fragment/1")
            let item = try XCTUnwrap(arrow.fragment["items"]?.arrayValue?.first).decode(Item.self)
            XCTAssertTrue(item.isValid)
            XCTAssertEqual(item.shape?.style.strokeColor, RGBA(hex: "#267A79FF"))
            XCTAssertEqual(item.shape?.style.strokeWidth, 2)
        }
        let board = try XCTUnwrap(kit.h.app.content.boardTemplates.get("dev.nib.starter.retro"))
        XCTAssertEqual(board.spec["nodes"]?.arrayValue?.count, 3)
        XCTAssertEqual(board.spec["layout"], "flow")
    }

    private func assertContributions(_ manifest: PluginManifest, kit: ExampleKit) throws {
        for command in manifest.contributes?.commands ?? [] {
            XCTAssertEqual(kit.h.app.commands.descriptor(command.id)?.owner, manifest.id)
        }
        for toolbar in manifest.contributes?.toolbar ?? [] {
            let registered = try XCTUnwrap(kit.h.app.ui.toolbar.get(toolbar.id))
            XCTAssertEqual(registered.owner, manifest.id)
            XCTAssertEqual(registered.command, toolbar.command)
        }
        for (index, menu) in (manifest.contributes?.menus ?? []).enumerated() {
            let registered = try XCTUnwrap(kit.h.app.ui.menus.get("\(manifest.id).menu.\(index)"))
            XCTAssertEqual(registered.owner, manifest.id)
            XCTAssertEqual(registered.location.rawValue, menu.location)
            XCTAssertEqual(registered.location, .objectMenu)
            XCTAssertEqual(registered.command, menu.command)
        }
        for panel in manifest.contributes?.panels ?? [] {
            XCTAssertEqual(kit.h.app.ui.panels.get(panel.id)?.owner, manifest.id)
        }
        for template in manifest.contributes?.templates ?? [] {
            XCTAssertEqual(kit.h.app.content.templates.get(template.id)?.owner, manifest.id)
        }
        for elements in manifest.contributes?.elements ?? [] {
            XCTAssertEqual(kit.h.app.content.elementCollections.get(elements.id)?.owner, manifest.id)
        }
        for board in manifest.contributes?.boardTemplates ?? [] {
            XCTAssertEqual(kit.h.app.content.boardTemplates.get(board.id)?.owner, manifest.id)
        }
    }

    private func assertError(_ code: NibError.Code, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as NibError { XCTAssertEqual(error.code, code, error.message, file: file, line: line) }
        catch { XCTFail("Expected NibError, got \(error)", file: file, line: line) }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
