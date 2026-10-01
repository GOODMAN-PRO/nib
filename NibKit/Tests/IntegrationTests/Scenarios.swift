import XCTest
import UIKit
import PDFKit
import NibContracts
import NibTesting
import FeatPen
import NibStore
import NibSync
import NibExport
import NibRender
import NibAIAgent
@testable import FeatCanvas
@testable import FeatUndoUI
@testable import FeatScan
@testable import NibIndex
@testable import NibLibrary
@testable import NibPluginRuntime
@testable import NibPluginHost
@testable import FeatPluginInstall
@testable import FeatTemplateUI
import FeatSyncUI

/// Each scenario composes the actual feature registrations; no feature command is replaced with a test handler.
/// Only services requiring hardware or a remote provider are faked. @testable accesses the camera/consent seams
/// and the History view model without widening production API just for an integration target.
@MainActor
enum Scenarios {
    static let doc: JSONValue = .string(NodeRef.document(Fixtures.docID).description)
    static let page: JSONValue = .string(NodeRef.page(Fixtures.docID, Fixtures.page2).description)

    static func stroke(y: Float = 100) -> Stroke {
        Stroke(style: .defaultPen, points: (0..<12).map {
            StrokePoint(x: Float(70 + $0 * 8), y: y + Float($0), t: Float($0) * 0.02)
        }, t0: 1_700_000_500)
    }

    static func inkParams(id: String, y: Float = 100) throws -> JSONValue {
        ["page": page, "strokes": .array([try JSONValue.from(stroke(y: y))]), "ids": [.string(id)]]
    }

    static func items(_ h: Harness, on page: PageID = Fixtures.page2) throws -> [Item] {
        try h.app.workspace.items(Fixtures.docID, page: page)
    }

    /// A bounded condition wait reports failure by throwing, so dependent assertions never run on a timed-out state.
    static func wait(_ description: String, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw NibError(.internalError, "Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func canvas(_ h: Harness) throws -> CanvasViewController {
        h.session.page = Fixtures.page2
        h.session.tool = "pen"
        let editor = try XCTUnwrap(h.app.ui.editors.get(DocumentKind.notebook.rawValue))
        let vc = try XCTUnwrap(editor.make(Fixtures.docID, h.session, h.app) as? CanvasViewController)
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        if !vc.didInitialLayout { vc.viewDidLayoutSubviews() }
        XCTAssertNotNil(vc.host.inputController, "F101 must install on F006's editor")
        return vc
    }

    static func canvasToInk() async throws {
        let savedInput = CanvasInputHooks.install
        defer { CanvasInputHooks.install = savedInput }
        let h = Harness(features: [FeatCanvasFeature.self, FeatCanvasInputFeature.self,
                                   FeatPenFeature.self, FeatUndoUIFeature.self])
        h.app.services.renderer = SerializedCanvasRenderer()
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let before = try h.snapshot()
        let vc = try canvas(h)
        defer { vc.closeCanvas() }
        let tool = try XCTUnwrap(vc.host.activeTool)
        XCTAssertEqual(tool.id, "pen")
        let wet = WetStrokeHandoff()
        var retired = false
        wet.deliver(PKBridge.pkStroke(stroke()), style: .defaultPen, page: Fixtures.page2,
                    tool: tool, host: vc.host) { retired = true }
        try await wait("canvas → ink.addStrokes commit") { h.undoDepth(Fixtures.docID) == 1 }
        let rows = try items(h)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.stroke?.style.tool, .pen)
        XCTAssertEqual(rows.first?.createdBy, "user")
        let committed = try h.snapshot()
        try await h.run(CommandIDs.undo, ["doc": doc])
        XCTAssertEqual(try h.snapshot(), before)
        try await h.run(CommandIDs.redo, ["doc": doc])
        XCTAssertEqual(try h.snapshot(), committed)
        // F006's dry-render fence may settle on the next layout/render pass in a hostless window.
        vc.host.flushAllWaiters()
        XCTAssertTrue(retired)
        XCTAssertTrue(wet.retired)
    }

    static func canvasReadOnly() async throws {
        let savedInput = CanvasInputHooks.install
        defer { CanvasInputHooks.install = savedInput }
        let h = Harness(features: [FeatCanvasFeature.self, FeatCanvasInputFeature.self, FeatPenFeature.self])
        h.app.services.renderer = SerializedCanvasRenderer()
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let vc = try canvas(h)
        defer { vc.closeCanvas() }
        h.session.readOnly = true
        let result: Result<ElementID?, NibError> = await withCheckedContinuation { continuation in
            vc.host.commitStroke(stroke(), page: Fixtures.page2) { continuation.resume(returning: $0) }
        }
        switch result {
        case .failure(let error): XCTAssertEqual(error.code, .permissionDenied)
        case .success: XCTFail("Read-only canvas accepted a stroke")
        }
        let rows = try items(h)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    static func aiHarness() -> Harness {
        Harness(features: [FeatPenFeature.self, NibAIAgentFeature.self, FeatUndoUIFeature.self])
    }

    static func aiTurnAndHistory() async throws {
        let h = aiHarness()
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let before = try h.snapshot()
        let ai = FakeAIService(responses: [.init(text: "Added two lines", toolCalls: [
            (CommandIDs.inkAddStrokes, try inkParams(id: "AITURNLINE01")),
            (CommandIDs.inkAddStrokes, try inkParams(id: "AITURNLINE02", y: 140))
        ])], bus: h.app.bus)
        h.app.services.ai = ai
        let group = "INTEGRATIONAITURN"
        let response = try await h.app.bus.execute(Invocation(command: CommandIDs.aiAsk,
            params: ["prompt": "Draw two lines", "scope": page, "mode": "edit"],
            principal: .ai("integration"), session: h.session, group: group)).value
        XCTAssertEqual(ai.requests.count, 1)
        XCTAssertNotNil(ai.requests.first?.group)
        XCTAssertEqual(ai.requests.first?.group, group)
        XCTAssertEqual(ai.requests.first?.principal, .ai("integration"))
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertEqual(response["group"]?.stringValue, group)
        let entries = h.app.bus.history.entries(Fixtures.docID).filter { $0.group == group }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.mutations.count, 2)
        let turn = try h.snapshot()
        try await h.run(CommandIDs.undo, ["doc": doc])
        XCTAssertEqual(try h.snapshot(), before)
        try await h.run(CommandIDs.redo, ["doc": doc])
        XCTAssertEqual(try h.snapshot(), turn)
        // A later user's stroke must survive selective revert from the same view model the History panel uses.
        try await h.run(CommandIDs.inkAddStrokes, inkParams(id: "USERLATER01", y: 180))
        let history = HistoryViewModel(app: h.app, session: h.session)
        await history.show(doc: Fixtures.docID)
        XCTAssertFalse(history.loadFailed)
        XCTAssertEqual(history.rows.count, 2)
        let row = try XCTUnwrap(history.rows.first { $0.group == group })
        XCTAssertEqual(row.changes, 2)
        await history.revert(row)
        XCTAssertEqual(history.receipt, .reverted(count: 2, kept: 0))
        let remaining = try items(h)
        XCTAssertEqual(remaining.map { NodeRef.item(Fixtures.docID, Fixtures.page2, $0.id).description },
                       ["item:FIXTUREDOC01/FIXTUREPG002/USERLATER01"])
        try await h.run(CommandIDs.undo, ["doc": doc])
        let restored = try items(h)
        XCTAssertEqual(restored.count, 3, "The History revert itself is undoable")
    }

    static func aiAskIsReadOnly() async throws {
        let h = aiHarness()
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let before = try h.snapshot()
        h.app.services.ai = FakeAIService(responses: [.init(text: "Attempted edit", toolCalls: [
            (CommandIDs.inkAddStrokes, try inkParams(id: "ASKSHOULDFAIL"))
        ])], bus: h.app.bus)
        do {
            try await h.run(CommandIDs.aiAsk, ["prompt": "Inspect this page", "scope": page, "mode": "ask"])
            XCTFail("Ask mode allowed a tool mutation")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    static func scanToSearch() async throws {
        let h = Harness(features: [NibIndexFeature.self, FeatScanFeature.self])
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let camera = ScenarioScanDevice()
        let savedCamera = ScanDevices.current
        ScanDevices.current = camera
        defer { ScanDevices.current = savedCamera }
        let recognizer = FakeRecognizer([TextRecognition(text: "Photosynthesis chlorophyll", bbox: Rect(x: 20, y: 20, width: 160, height: 30), source: "image")])
        h.app.services.recognizer = recognizer
        let indexer = try XCTUnwrap(h.app.services.get(IndexKeys.service, as: Indexer.self))
        indexer.start()
        let result = try await h.run(CommandIDs.scanDocuments, ["doc": doc, "position": "end", "ids": ["SCANNEDPAGE01"]])
        let scanned = try XCTUnwrap(result["refs"]?[0]?.stringValue)
        XCTAssertEqual(camera.captures, 1)
        XCTAssertEqual(recognizer.imageCalls, 1)
        let scannedPage = try XCTUnwrap(NodeRef(scanned)?.pageID)
        let record = try XCTUnwrap(h.app.workspace.content(Fixtures.docID).pages.first { $0.id == scannedPage })
        XCTAssertNotNil(record.ext?[PageRecord.scanTextExtKey])
        let text = try await h.run(CommandIDs.recognizePageText, ["page": .string(scanned)])
        XCTAssertTrue(text["blocks"]?.arrayValue?.contains { $0["text"] == "Photosynthesis chlorophyll" && $0["source"] == "scan" } == true)
        let hits = try await h.run(CommandIDs.searchText, ["query": "chlorophyll", "scope": doc])
        XCTAssertTrue(hits["results"]?.arrayValue?.contains { $0["page"]?.stringValue == scanned && $0["kind"] == "scan" } == true)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        try await h.run(CommandIDs.undo, ["doc": doc])
        let undone = try await h.run(CommandIDs.searchText, ["query": "chlorophyll", "scope": doc])
        XCTAssertEqual(undone["results"]?.arrayValue?.count, 0)
        try await h.run(CommandIDs.redo, ["doc": doc])
        let redone = try await h.run(CommandIDs.searchText, ["query": "chlorophyll", "scope": doc])
        XCTAssertEqual(redone["results"]?.arrayValue?.count, 1)
    }

    static func repairCatalog() async throws {
        let h = Harness(features: [NibStoreFeature.self, NibLibraryFeature.self, NibSyncFeature.self,
                                   FeatSyncUIFeature.self], fixtures: false, keepFeatureServices: true)
        let library = try XCTUnwrap(h.app.services.library as? FolderLibrary)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nib-integration-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try library.setRoot(root)
        defer {
            library.waitForIO()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: library.cacheURL)
            try? FileManager.default.removeItem(at: h.persistence.root)
        }
        let created = try await h.run(CommandIDs.docCreate, ["kind": "notebook", "title": "Repair survivor", "cover": false, "id": "REPAIRDOC01"])
        let ref = try XCTUnwrap(created["ref"]?.stringValue)
        let id = NodeRef.documentID(from: ref)
        h.app.workspace.persistence.flush(id)
        let before = try h.snapshot(id)
        let originalNode = try XCTUnwrap(library.node(id))
        try await wait("creation's catalog write") {
            CatalogCache.load(library.cacheURL, root: root.standardizedFileURL.path) != nil
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        library.waitForIO()
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.cacheURL.path))
        try FileManager.default.removeItem(at: library.cacheURL)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        library.waitForIO()
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.cacheURL.path),
                       "No pending creation save may mask a repair that does not rebuild the catalog")
        let repaired = try await h.run(CommandIDs.libraryRepair)
        // library.repair must report that it rebuilt the deleted catalogue; the catalogue file itself may be
        // written after the command returns, so the persisted state is awaited below.
        XCTAssertEqual(repaired["catalogRebuilt"], true)
        try await wait("repair's catalog write") {
            CatalogCache.load(library.cacheURL, root: root.standardizedFileURL.path) != nil
        }
        library.waitForIO()
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.cacheURL.path))
        let rebuilt = try XCTUnwrap(CatalogCache.load(library.cacheURL, root: root.standardizedFileURL.path))
        let survivors = rebuilt.filter { $0.node.id == id }
        XCTAssertEqual(survivors.count, 1, "Repair must persist the original document exactly once")
        let survivor = try XCTUnwrap(survivors.first)
        XCTAssertEqual(survivor.node.kind, .document)
        XCTAssertEqual(survivor.node.title, originalNode.title)
        XCTAssertEqual(survivor.node.path, originalNode.path)
        XCTAssertFalse(survivor.inTrash)
        XCTAssertEqual(repaired["errors"]?.arrayValue?.count, 0)
        let listed = try await h.run(CommandIDs.libraryList)
        XCTAssertTrue(listed["nodes"]?.arrayValue?.contains { $0["ref"]?.stringValue == ref } == true)
        XCTAssertEqual(try h.snapshot(id), before)
        XCTAssertEqual(h.undoDepth(id), 0)
        h.app.workspace.close(id)
        XCTAssertEqual(try h.snapshot(id), before, "The original package remains readable after rebuilding")
    }

    static func pageToTemplate() async throws {
        let h = Harness(features: [NibRenderFeature.self, NibExportFeature.self, FeatTemplateUIFeature.self])
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        h.app.services.pdf = FakePDFService()
        let before = try h.snapshot()
        let source = JSONValue.string(NodeRef.page(Fixtures.docID, Fixtures.page1).description)
        let output = try await h.run(CommandIDs.templateFromPage, ["page": source, "title": "Lecture paper", "id": "LECTUREPAPER01"])
        XCTAssertEqual(output["id"], "LECTUREPAPER01")
        let catalog = try await h.run(CommandIDs.templateListCustom)
        let entry = try XCTUnwrap(catalog["templates"]?.arrayValue?.first { $0["id"] == "LECTUREPAPER01" })
        XCTAssertEqual(entry["kind"], "paper")
        XCTAssertEqual(entry["title"], "Lecture paper")
        let store = CustomTemplateStore(root: h.library.metadataURL.appendingPathComponent("templates"), clock: h.app.clock)
        let (group, template) = try await store.locate("LECTUREPAPER01")
        let url = store.root.appendingPathComponent(group.id).appendingPathComponent(template.file)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 1)
        let exportedPage = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(exportedPage.bounds(for: .mediaBox).width, PageSize.a4.width, accuracy: 1)
        XCTAssertFalse(exportedPage.annotations.contains { ($0.type ?? "").contains("Ink") || ($0.type ?? "").contains("FreeText") },
                       "template.fromPage must flatten source ink and text, rather than exporting editable annotations")
        XCTAssertTrue(exportedPage.string?.contains("Hello Nib") == true, "The populated source page is exported")
        XCTAssertEqual(try h.snapshot(), before, "Exporting a template must not edit its source")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    static func renderMarks() async throws {
        let h = Harness(features: [NibRenderFeature.self])
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        h.app.services.pdf = FakePDFService()
        let before = try h.snapshot()
        let invocation = try XCTUnwrap(ToolCatalog.invocation(tool: "nib_render",
            arguments: ["page": .string(NodeRef.page(Fixtures.docID, Fixtures.page1).description), "marks": true, "scale": 1],
            registry: h.app.commands, principal: .ai("render-scenario"), group: "RENDERSCENARIO", readOnly: true, session: h.session))
        XCTAssertEqual(invocation.command, CommandIDs.renderPage)
        let output = try await h.app.bus.execute(invocation).value
        let marks = try XCTUnwrap(output["marks"]?.objectValue)
        let rows = try XCTUnwrap(before["items"]?[Fixtures.page1.raw]?.arrayValue)
        let refs = Set(try rows.map { row in
            NodeRef.item(Fixtures.docID, Fixtures.page1, NibID(try XCTUnwrap(row["id"]?.stringValue))).description
        })
        XCTAssertFalse(marks.isEmpty)
        XCTAssertEqual(Set(marks.values.compactMap(\.stringValue)), refs)
        let name = try XCTUnwrap(output["asset"]?.stringValue)
        XCTAssertTrue(name.hasPrefix("tmp:"))
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(name.dropFirst(4)))))
        let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url))?.cgImage)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 1568)
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    static func pluginStorage() async throws {
        let h = Harness(features: [NibPluginRuntimeFeature.self, NibPluginHostFeature.self, FeatPluginInstallFeature.self])
        let host = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginHost, as: PluginHost.self))
        let runtime = try XCTUnwrap(h.app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntime.self))
        let installer = try XCTUnwrap(h.app.services.get(PluginInstaller.serviceKey, as: PluginInstaller.self))
        let grantURL = h.persistence.root.appendingPathComponent("device-grants.json")
        host.authority.store = PluginGrantStore(url: grantURL)
        host.isSafeMode = { false }
        installer.grants = PluginGrantFile(url: grantURL)
        installer.stagingParent = h.persistence.root.appendingPathComponent("staging")
        let consent = ScenarioConsent()
        installer.consent = consent
        let id = "dev.nib.integration.counter"
        defer {
            host.unload(id)
            runtime.storage(for: id)?.flushAndWait()
            h.app.services.get(ServiceKeys.pluginRuntime, as: PluginRuntime.self)?.storage(for: id)?.flushAndWait()
            try? FileManager.default.removeItem(at: h.persistence.root)
        }
        let command = id + ".visit"
        let manifest: JSONValue = ["id": .string(id), "name": "Persistent Counter", "version": "1.0.0", "api": 1,
            "entry": "main.js", "permissions": [], "contributes": ["commands": [[
                "id": .string(command), "title": "Visit", "summary": "Read or increment a persistent visit counter.",
                "effect": "session", "target": "app", "params": ["type": "object", "properties": ["increment": ["type": "boolean"]]],
                "examples": [["increment": true]]
            ]]]]
        let script = """
        nib.commands.register("\(command)", async (params) => {
          const old = (await nib.storage.get("visits")) || 0;
          const visits = params.increment ? old + 1 : old;
          if (params.increment) await nib.storage.set("visits", visits);
          return { visits, keys: await nib.storage.keys() };
        });
        """
        let files: JSONValue = ["files": ["manifest.json": .string(manifest.jsonString()), "main.js": .string(script)]]
        try await h.run(CommandIDs.pluginInstall, files)
        XCTAssertEqual(consent.requests, 1)
        XCTAssertNotNil(h.app.commands.descriptor(command))
        let first = try await h.run(command, ["increment": true])
        XCTAssertEqual(first["visits"], 1)
        runtime.storage(for: id)?.flushAndWait()
        let storageURL = h.library.metadataURL.appendingPathComponent("plugin-data/\(id)/storage.\(h.app.deviceHex).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        let reloaded = try await h.run(CommandIDs.pluginReload, ["id": .string(id)])
        XCTAssertEqual(reloaded["state"], "running")
        let read = try await h.run(command, ["increment": false])
        XCTAssertEqual(read["visits"], 1)
        XCTAssertEqual(read["keys"], ["visits"])
        let second = try await h.run(command, ["increment": true])
        XCTAssertEqual(second["visits"], 2)
        runtime.storage(for: id)?.flushAndWait()
        try await h.run(CommandIDs.pluginUninstall, ["id": .string(id), "removeData": false])
        XCTAssertNil(h.app.commands.descriptor(command))
        // A brand-new runtime has no cached PluginStorage; reinstallation must read the persisted counter.
        let freshRuntime = PluginRuntime(app: h.app)
        freshRuntime.isSafeMode = { false }
        h.app.services.set(freshRuntime, for: ServiceKeys.pluginRuntime)
        try await h.run(CommandIDs.pluginInstall, files)
        let installedAgain = try await h.run(command, ["increment": false])
        XCTAssertEqual(installedAgain["visits"], 2)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }
}

/// Canvas tiles call PageRenderer concurrently. NibTesting's FakeRenderer records into ordinary arrays,
/// so protect every access with a gate that stays held across its nonisolated async methods.
/// Actor isolation alone would allow another request to enter while awaiting fake.render.
private actor SerializedCanvasRenderer: PageRenderer {
    private let fake = FakeRenderer()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    func render(_ request: RenderRequest) async throws -> RenderResult {
        await acquire()
        defer { release() }
        return try await fake.render(request)
    }

    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        await acquire()
        defer { release() }
        return await fake.thumbnail(doc: doc, page: page, maxPixelSize: maxPixelSize)
    }

    nonisolated func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {
        Task { await recordInvalidation(doc: doc, page: page, rect: rect) }
    }

    private func recordInvalidation(doc: DocumentID, page: PageID, rect: Rect?) async {
        await acquire()
        defer { release() }
        fake.invalidate(doc: doc, page: page, rect: rect)
    }

    nonisolated func purgeCaches() {
        Task { await purge() }
    }

    private func purge() async {
        await acquire()
        defer { release() }
        fake.purgeCaches()
    }
}

/// Camera adapter: the scan still runs its real JPEG/OCR/asset/transaction pipeline.
@MainActor
private final class ScenarioScanDevice: ScanDevice, ScanSheets {
    private(set) var captures = 0
    var count: Int { 1 }
    func image(at index: Int) -> UIImage? { index == 0 ? UIImage(cgImage: FakeRenderer.blank(CGSize(width: 300, height: 400))) : nil }
    func captureDocuments(on stage: ScanStage) async throws -> ScanSheets? { captures += 1; return self }
    func readQRCode(on stage: ScanStage) async throws -> String? { nil }
    func open(_ url: URL) async -> Bool { false }
    func copy(_ text: String) {}
}

@MainActor
private final class ScenarioConsent: PluginConsentPresenting {
    private(set) var requests = 0
    func requestConsent(_ request: PluginConsentRequest, navigator: SceneNavigator?) async throws -> PluginConsentDecision {
        requests += 1
        return .approve(request.initialConsent)
    }
}
