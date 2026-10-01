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

/// Uses the production commands and observes their calls without replacing handlers or changing parameters.
/// Script changes install a new recognizer: NibIndex caches recognition by recognizer identity and item revision.
@MainActor
private final class ExampleFixtureServices {
    unowned let h: Harness
    private(set) var recognizer = FakeRecognizer()
    // Keep identities alive while the index can still hold their cached results.
    private var scriptedRecognizers: [FakeRecognizer] = []
    var inkCalls: [JSONValue] = []
    var getCalls = 0
    var pageTextCalls = 0

    init(_ h: Harness) {
        self.h = h
        scriptedRecognizers.append(recognizer)
        h.app.services.recognizer = recognizer
        h.app.bus.hooks.register(CommandHookDescriptor.guarding(
            id: "example-fixtures.observe", owner: "example-fixtures",
            commands: [CommandIDs.queryGet, CommandIDs.recognizePageText, CommandIDs.inkWriteText]
        ) { [weak self] command, params, _ in
            switch command {
            case CommandIDs.queryGet: self?.getCalls += 1
            case CommandIDs.recognizePageText: self?.pageTextCalls += 1
            case CommandIDs.inkWriteText: self?.inkCalls.append(params)
            default: break
            }
            return nil
        })
    }

    func setRecognition(_ script: [TextRecognition]) {
        recognizer = FakeRecognizer(script)
        scriptedRecognizers.append(recognizer)
        h.app.services.recognizer = recognizer
    }

    func partialWord(_ word: String = "hel") {
        var line = TextRecognition(text: "Say \(word)", bbox: Rect(x: 72, y: 120, width: 100, height: 20),
                                   itemIDs: [Fixtures.strokeID], source: "ink")
        line.words = [TextRecognitionWord(text: word, bbox: Rect(x: 110, y: 120, width: 40, height: 20), itemIDs: [Fixtures.strokeID])]
        setRecognition([line])
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
    }
}

@MainActor
private final class ExampleKit {
    let h: Harness
    let api: ExampleFixtureServices
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
        api = ExampleFixtureServices(h)
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
        h.app.bus.hooks.unregister(owner: "example-fixtures")
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
                let toasted = await eventually { kit.ui.toasts.count == 1 }
                XCTAssertTrue(toasted)
            case "flashcards-from-selection":
                kit.h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID])
                kit.api.setRecognition([TextRecognition(text: "Velocity — Displacement over time", bbox: .zero, source: "ink")])
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
        let toasted = await eventually { kit.ui.toasts.count == 1 }
        XCTAssertTrue(toasted)
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
        kit.api.setRecognition([TextRecognition(text: " Velocity — displacement — over time \ninvalid\n — empty\nMass — matter ", bbox: .zero, source: "ink")])
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
        kit.api.setRecognition([TextRecognition(text: "a — b", bbox: .zero, source: "ink")])
        await assertError(.invalidParams) { _ = try await kit.h.run("dev.nib.cards.fromSelection", ["ids": []]) }
        XCTAssertEqual(kit.h.library.allNodes().count, initial)
    }

    func testWordCountPanelMessagesAndCoalescedEventsFollowCurrentPage() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-count")
        kit.api.setRecognition([TextRecognition(text: "  one\n two don't — café  ", bbox: .zero, source: "ink")])
        let count = try await kit.h.run("dev.nib.wordcount.show")
        XCTAssertEqual(count["words"], 9) // Four recognised words plus “Hello Nib”, “Remember” and “Fixture box”.
        XCTAssertEqual(count["pageNumber"], 1)
        XCTAssertEqual(kit.h.session.openPanels, Set(["dev.nib.wordcount.panel"]))
        let shown = await eventually {
            kit.h.app.events.events(since: 0).contains {
                $0.type == NibEventType.pluginMessage && $0.payload?["message"]?["words"] == 9
            }
        }
        XCTAssertTrue(shown)
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
        for text in ["สวัสดี ครับ", "नमस्ते दुनिया", "你好世界"] {
            // Each script describes a separate document snapshot; pageText caches unchanged pages.
            let kit = try ExampleKit()
            defer { kit.close() }
            _ = try await kit.install("word-count")
            kit.api.setRecognition([TextRecognition(text: text, bbox: .zero, source: "ink")])
            let result = try await kit.h.run("dev.nib.wordcount.count")
            XCTAssertEqual(result["words"], 7, text) // Two segmented words plus the five typed fixture words.
        }
    }

    func testWordCountAvoidsRecognitionWhenClosedOrAnotherDocumentCommits() async throws {
        let kit = try ExampleKit()
        defer { kit.close() }
        _ = try await kit.install("word-count")
        kit.h.app.events.emit(NibEventType.committed, doc: Fixtures.docID)
        kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.pageTextCalls, 0)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, 0)
        _ = try await kit.h.run("dev.nib.wordcount.show")
        let shown = await eventually {
            kit.h.app.events.events(since: 0).contains {
                $0.type == NibEventType.pluginMessage && $0.payload?["message"]?["pageNumber"] == 1
            }
        }
        XCTAssertTrue(shown)
        let before = kit.api.pageTextCalls
        let recognitionCalls = kit.api.recognizer.strokeCalls
        kit.h.app.events.emit(NibEventType.committed, doc: "OTHERDOC01")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.pageTextCalls, before)
        let seq = kit.h.app.events.lastSeq
        for _ in 0..<8 { kit.h.app.events.emit(NibEventType.committed, doc: Fixtures.docID) }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(kit.api.pageTextCalls, before)
        let refreshed = await eventually {
            kit.api.pageTextCalls == before + 1 && kit.h.app.events.events(since: seq).contains {
                $0.type == NibEventType.pluginMessage
            }
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, recognitionCalls) // The unchanged page is cached.
        // Headless chrome has no web view to send pagehide; deliver the same closed message as panel.html.
        _ = try await kit.h.run(CommandIDs.panelClose, ["id": "dev.nib.wordcount.panel"])
        XCTAssertFalse(kit.h.session.openPanels.contains("dev.nib.wordcount.panel"))
        kit.host.handle("dev.nib.wordcount")?.postMessage(from: "dev.nib.wordcount.panel", message: ["type": "closed"])
        kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.pageTextCalls, before + 1)
        XCTAssertEqual(kit.api.recognizer.strokeCalls, recognitionCalls)
        kit.host.handle("dev.nib.wordcount")?.postMessage(from: "dev.nib.wordcount.panel", message: ["type": "closed"])
        kit.h.app.events.emit(NibEventType.pageChanged, doc: Fixtures.docID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(kit.api.pageTextCalls, before + 1)
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
        XCTAssertEqual(kit.api.inkCalls.count, 1)
        let inkCall = try XCTUnwrap(kit.api.inkCalls.first)
        XCTAssertEqual(inkCall["page"], "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(inkCall["at"], [150, 120])
        XCTAssertEqual(inkCall["size"], 20)
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
