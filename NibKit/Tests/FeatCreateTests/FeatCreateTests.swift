import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatCreate

/// Records the calls stand-in commands receive.
@MainActor
private final class CallLog {
    var calls: [(command: String, params: JSONValue)] = []

    func params(_ command: String) -> [JSONValue] { calls.filter { $0.command == command }.map(\.params) }
    func count(_ command: String) -> Int { params(command).count }
}

/// A window as the shell and Tabs & Windows run it: tabs in `openDocuments`, the shown one in `session.document`.
/// `showLibrary` keeps the tabs listed (the shell does).
@MainActor
private final class FakeNavigator: SceneNavigator {
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    private(set) var presented: [UIViewController] = []

    init(session: EditorSession, tabs: [DocumentID] = []) {
        self.session = session
        openDocuments = tabs
    }

    var rootViewController: UIViewController? { nil }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if !openDocuments.contains(doc) { openDocuments.append(doc) }
        activeDocument = doc
        session.document = doc
    }

    /// Removes the tab without any event (F018 has already switched to the neighbour).
    func closeDocument(_ doc: DocumentID) { openDocuments.removeAll { $0 == doc } }
    func showLibrary(folder: FolderID?) { session.document = nil }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) { presented.append(viewController) }
}

@MainActor
final class FeatCreateTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatCreateFeature.self]) }

    /// Registers a stand-in for another feature's command.
    private func stub(_ h: Harness, _ id: String, effect: Effect = .library, log: CallLog,
                      _ body: @escaping @MainActor (JSONValue) async throws -> JSONValue = { _ in [:] }) {
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Stand-in.", effect: effect,
                                                  target: .library)) { params, _ in
            log.calls.append((command: id, params: params))
            return try await body(params)
        }
    }

    /// A `doc.create` stand-in that builds the document with the library, as the Library Store does.
    /// `titled` stands for the Library Store's unique names ("Untitled 2").
    private func stubDocCreate(_ h: Harness, log: CallLog, cover: Bool = false,
                               titled: @escaping (String) -> String = { $0 },
                               refuse: @escaping (JSONValue) -> Bool = { _ in false }) {
        stub(h, "doc.create", log: log) { p in
            if refuse(p) { throw NibError(.invalidParams, "cover must be a boolean", path: "$.cover") }
            let id = NibID(p["id"]?.stringValue ?? "MISSING")
            let folder = p["folder"]?.stringValue.flatMap { NodeRef($0) }.flatMap { ref -> FolderID? in
                if case .folder(let f) = ref { return f }
                return nil
            }
            var meta = DocumentMeta(id: id, kind: DocumentKind(rawValue: p["kind"]?.stringValue ?? "") ?? .notebook)
            meta.rev = h.app.clock.tick()
            var pages: [PageRecord] = []
            if cover { pages.append(PageRecord(order: "a", size: .a4, background: .ofTemplate("cover.solid"))) }
            pages.append(PageRecord(order: "b", size: .a4, background: .ofTemplate("builtin.ruled")))
            _ = try h.library.createDocument(DocumentContent(meta: meta, pages: pages),
                                             title: titled(p["title"]?.stringValue ?? ""), in: folder)
            return ["ref": .string(NodeRef.document(id).description)]
        }
    }

    private func expectError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func quickNote(_ h: Harness, _ params: JSONValue = [:]) async throws -> DocumentID {
        let out = try await h.run("doc.quickNote", params)
        let ref = try XCTUnwrap(out["ref"]?.stringValue)
        return NodeRef.documentID(from: ref)
    }

    /// Writes something on the document's last page, straight into persistence (as a saved document has it), so the
    /// document is not opened in the workspace.
    private func addInk(_ h: Harness, to doc: DocumentID) throws {
        let page = try XCTUnwrap(h.persistence.heads[doc]?.livePages.last)
        let item = try XCTUnwrap(h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).first)
        h.persistence.pageItems[doc, default: [:]][page.id] = [item]
    }

    private static func ruled(owner: String = "test") -> TemplateDefinition {
        TemplateDefinition(id: TemplateIDs.ruled, title: "Ruled", category: "Writing", owner: owner,
                           params: [TemplateParam(name: TemplateParamNames.paper, title: "Paper", kind: "color"),
                                    TemplateParam(name: TemplateParamNames.line, title: "Line", kind: "color")]) { p, size, _ in
            let paper = p[TemplateParamNames.paper]?.stringValue.flatMap { RGBA(hex: $0) } ?? .white
            return TemplateRender(paper: paper, display: DisplayList(ops: [
                DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: size.width, height: 1), stroke: .black)]))
        }
    }

    private static func dots() -> TemplateDefinition {
        TemplateDefinition(id: TemplateIDs.dots, title: "Dots", category: "Essentials", owner: "test") { _, _, _ in
            TemplateRender(paper: .white)
        }
    }

    private static func solidCover() -> TemplateDefinition {
        TemplateDefinition(id: "cover.solid", title: "Solid", category: "Covers", isCover: true, owner: "test",
                           params: [TemplateParam(name: TemplateParamNames.color, title: "Colour", kind: "color")]) { _, _, _ in
            TemplateRender(paper: .black)
        }
    }

    // MARK: - doc.quickNote

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatCreateFeature.self])
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    /// Acceptance: the quickNote example creates an untitled notebook with the default paper and page size, no cover, in
    /// the folder of the window's document, and remembers it as a pending QuickNote.
    func testQuickNoteExampleCreatesAnUntitledNotebookWithTheDefaultPaper() async throws {
        let h = harness()
        let example = try XCTUnwrap(DocQuickNote.descriptor.examples.first)
        let out = try await h.run("doc.quickNote", example)
        let id = NodeRef.documentID(from: try XCTUnwrap(out["ref"]?.stringValue))

        let node = try XCTUnwrap(h.library.node(id))
        XCTAssertEqual(node.kind, .document)
        XCTAssertEqual(node.documentKind, .notebook)
        XCTAssertEqual(node.title, NewDocumentKind.notebook.untitled)
        XCTAssertEqual(node.parent, Fixtures.folderID, "the folder of the document the window shows")
        XCTAssertEqual(out["folder"]?.stringValue, "folder:FIXTUREFLD01")
        XCTAssertEqual(out["opened"]?.boolValue, false, "headless: no window and no doc.open")

        let content = try h.app.workspace.content(id)
        XCTAssertEqual(content.meta.kind, .notebook)
        XCTAssertFalse(content.meta.coverEnabled)
        XCTAssertEqual(content.livePages.count, 1, "no cover page")
        let page = try XCTUnwrap(content.livePages.first)
        XCTAssertEqual(page.background.template, h.app.settings.get(NibSettings.defaultPaper))
        XCTAssertEqual(page.size, h.app.settings.get(NibSettings.defaultPageSize))
        XCTAssertEqual(PendingCreations.get(id, h.app.settings)?.kind, .quickNote)
        XCTAssertEqual(PendingCreations.get(id, h.app.settings)?.title, NewDocumentKind.notebook.untitled)
    }

    func testQuickNoteTakesAFolderACallerIDAndTheLibraryRoot() async throws {
        let h = harness()
        let a = try await quickNote(h, ["folder": "folder:FIXTUREFLD01", "id": "QUICKNOTE001"])
        XCTAssertEqual(a, NibID("QUICKNOTE001"))
        XCTAssertEqual(h.library.node(a)?.parent, Fixtures.folderID)
        let b = try await quickNote(h, ["folder": "lib"])
        XCTAssertNotNil(h.library.node(b))
        XCTAssertNil(h.library.node(b)?.parent)
        h.session.document = nil
        let c = try await quickNote(h)
        XCTAssertNil(h.library.node(c)?.parent, "no document open: the library root")
    }

    func testQuickNoteRejectsBadParams() async throws {
        let h = harness()
        await expectError(.notFound) { _ = try await h.run("doc.quickNote", ["folder": "folder:NOSUCHFOLDER"]) }
        await expectError(.notFound) { _ = try await h.run("doc.quickNote", ["folder": "folder:FIXTUREDOC01"]) }
        await expectError(.invalidParams) { _ = try await h.run("doc.quickNote", ["folder": "doc:FIXTUREDOC01"]) }
        await expectError(.invalidParams) { _ = try await h.run("doc.quickNote", ["id": "not a valid id!"]) }
        await expectError(.conflict) { _ = try await h.run("doc.quickNote", ["id": "FIXTUREDOC01"]) }
        XCTAssertEqual(PendingCreations.all(h.app.settings).count, 0)
    }

    func testQuickNoteDryRunCreatesNothing() async throws {
        let h = harness()
        let before = h.library.allNodes().count
        let r = try await h.app.bus.execute(Invocation(command: "doc.quickNote", params: ["id": "DRYRUNNOTE01"],
                                                       session: h.session, dryRun: true))
        XCTAssertEqual(r.value["ref"]?.stringValue, "doc:DRYRUNNOTE01")
        XCTAssertEqual(h.library.allNodes().count, before)
        XCTAssertNil(PendingCreations.get("DRYRUNNOTE01", h.app.settings))
    }

    func testQuickNoteGoesThroughDocCreateAndDocOpenWhenInstalled() async throws {
        let h = harness()
        let log = CallLog()
        stubDocCreate(h, log: log)
        stub(h, "doc.open", effect: .session, log: log)

        let out = try await h.run("doc.quickNote", ["id": "QUICKNOTE002"])

        let create = try XCTUnwrap(log.params("doc.create").first)
        XCTAssertEqual(create["kind"], "notebook")
        XCTAssertEqual(create["title"]?.stringValue, NewDocumentKind.notebook.untitled)
        XCTAssertEqual(create["id"], "QUICKNOTE002")
        XCTAssertEqual(create["folder"], "folder:FIXTUREFLD01")
        XCTAssertEqual(create["template"], try JSONValue.from(h.app.settings.get(NibSettings.defaultPaper)))
        let size = h.app.settings.get(NibSettings.defaultPageSize)
        XCTAssertEqual(create["size"], [.number(size.width), .number(size.height)])
        XCTAssertEqual(create["cover"], false)
        XCTAssertEqual(log.params("doc.open").first?["doc"], "doc:QUICKNOTE002")
        XCTAssertEqual(out["opened"], true)
    }

    /// `doc.create`'s cover param is not pinned: a refusal is retried as a flag, then left out; a cover the Library
    /// Store still adds is removed so the QuickNote opens on paper.
    func testDocCreateCoverShapesAreRetriedAndAnUnwantedCoverIsRemoved() async throws {
        let h = harness()
        let flagLog = CallLog()
        stubDocCreate(h, log: flagLog, refuse: { $0["cover"]?.boolValue == nil && $0["cover"] != nil })
        _ = try await h.run("doc.quickNote", ["id": "QUICKNOTE003"])
        XCTAssertEqual(flagLog.count("doc.create"), 1, "false is already a flag")

        let h2 = harness()
        let log = CallLog()
        stubDocCreate(h2, log: log, cover: true, refuse: { $0["cover"] != nil })
        stub(h2, "node.remove", effect: .edit, log: log)
        h2.app.content.templates.register(Self.solidCover())
        _ = try await h2.run("doc.quickNote", ["id": "QUICKNOTE004"])
        let attempts = log.params("doc.create")
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[0]["cover"], false)
        XCTAssertEqual(attempts[1]["cover"], false)
        XCTAssertNil(attempts[2]["cover"])
        let cover = try XCTUnwrap(h2.app.workspace.content("QUICKNOTE004").livePages.first)
        XCTAssertEqual(log.params("node.remove").first?["ref"]?.stringValue,
                       NodeRef.page("QUICKNOTE004", cover.id).description)
    }

    // MARK: - New Notebook draft

    func testDraftStartsFromTheRememberedDefaultsAndRemembersTheNextChoices() throws {
        let h = harness()
        let templates = h.app.content.templates
        templates.register(Self.ruled())
        templates.register(Self.solidCover())
        let s = h.app.settings
        s.set(NibSettings.defaultPaper, TemplateRef(TemplateIDs.ruled, params: [TemplateParamNames.paper: "#FCF3C8FF",
                                                                                 TemplateParamNames.spacing: 24]))
        s.set(NibSettings.defaultCover, TemplateRef("cover.solid", params: [TemplateParamNames.color: "#23324F"]))
        s.set(NibSettings.defaultPageSize, PageSize.letter.rotated)
        s.set(NibSettings.coverByDefault, false)

        var draft = NotebookDraft.initial(settings: s)
        XCTAssertEqual(draft.paper, TemplateRef(TemplateIDs.ruled, params: [TemplateParamNames.spacing: 24]))
        XCTAssertEqual(draft.paperColour, .legal)
        XCTAssertEqual(draft.cloth, .navy)
        XCTAssertEqual(draft.size.name, "Letter")
        XCTAssertEqual(draft.orientation, .landscape)
        XCTAssertEqual(draft.pageSize, PageSize.letter.rotated)
        XCTAssertFalse(draft.hasCover)

        // The same choices written back reproduce the settings.
        let remembered = Dictionary(uniqueKeysWithValues: draft.rememberedSettings(templates: templates).map { ($0.name, $0.value) })
        let paper = try XCTUnwrap(remembered[NibSettings.defaultPaper.name]?.decode(TemplateRef.self))
        XCTAssertEqual(paper.params[TemplateParamNames.paper], "#FCF3C8FF")
        XCTAssertEqual(paper.params[TemplateParamNames.spacing], 24)
        XCTAssertNotNil(paper.params[TemplateParamNames.line], "the rule colour follows the paper")
        XCTAssertEqual(remembered[NibSettings.defaultCover.name]?["params"]?[TemplateParamNames.color], "#23324FFF")
        XCTAssertEqual(try remembered[NibSettings.defaultPageSize.name]?.decode(PageSize.self), PageSize.letter.rotated)
        XCTAssertEqual(remembered[NibSettings.coverByDefault.name], false)

        draft.kind = .whiteboard
        XCTAssertTrue(draft.rememberedSettings(templates: templates).isEmpty, "only notebook choices become defaults")
        draft.kind = .notebook
        draft.custom = .ofImage(AssetRef("custom.png"))
        XCTAssertNil(draft.rememberedSettings(templates: templates).first { $0.name == NibSettings.defaultPaper.name },
                     "a custom image paper is not a template default")
    }

    func testColourParamsGoOnlyToTemplatesThatTakeThem() {
        var draft = NotebookDraft.initial(settings: harness().app.settings)
        draft.paper = TemplateRef(TemplateIDs.dots)
        draft.paperColour = .slate
        XCTAssertEqual(draft.paperRef(Self.dots()).params, [:], "dots declares no paper param")
        let ruled = draft.paperRef(Self.ruled()).params
        XCTAssertEqual(ruled[TemplateParamNames.paper]?.stringValue, TemplateColours.rgba(NibPaper.slate.hex).hex)
        XCTAssertEqual(ruled[TemplateParamNames.line]?.stringValue, TemplateColours.rgba(NibPaper.slate.ruleHex).hex)
        XCTAssertNotNil(draft.paperRef(nil).params[TemplateParamNames.paper], "unknown templates still get the choice")
        draft.paperColour = nil
        XCTAssertEqual(draft.paperRef(Self.ruled()).params, [:])
    }

    func testDraftRequestForEachKind() {
        let h = harness()
        let templates = h.app.content.templates
        var draft = NotebookDraft.initial(settings: h.app.settings)
        draft.title = "  Physics: Waves/Optics  "
        draft.hasCover = true
        draft.size = PageSizeChoice.matching(.a5).choice
        draft.orientation = .landscape
        var r = draft.request(id: "NEWDOC000001", folder: Fixtures.folderID, templates: templates)
        XCTAssertEqual(r.kind, .notebook)
        XCTAssertEqual(r.title, "Physics- Waves-Optics", "titles are package file names")
        XCTAssertEqual(r.size, PageSize.a5.rotated)
        XCTAssertNotNil(r.cover)
        XCTAssertEqual(r.docCreateParams(.template)["folder"], "folder:FIXTUREFLD01")
        XCTAssertEqual(r.docCreateParams(.flag)["cover"], true)
        XCTAssertNil(r.docCreateParams(.omitted)["cover"])

        draft.kind = .textDocument
        draft.title = ""
        r = draft.request(id: "NEWDOC000002", folder: nil, templates: templates)
        XCTAssertEqual(r.title, NewDocumentKind.textDocument.untitled)
        XCTAssertNil(r.template)
        XCTAssertNil(r.size)
        XCTAssertEqual(r.coverStyles, [.omitted])
        XCTAssertNil(r.docCreateParams(.omitted)["folder"])

        draft.kind = .whiteboard
        draft.paperColour = .board
        r = draft.request(id: "NEWDOC000003", folder: nil, templates: templates)
        XCTAssertEqual(r.template?.id, TemplateIDs.whiteboardDots)
        XCTAssertNotNil(r.template?.params[TemplateParamNames.paper])
        XCTAssertNil(r.size)
    }

    func testPageSizeChoices() {
        let a4 = PageSizeChoice.matching(.a4)
        XCTAssertEqual(a4.choice.name, "A4")
        XCTAssertEqual(a4.orientation, .portrait)
        let landscape = PageSizeChoice.matching(PageSize.a4.rotated)
        XCTAssertEqual(landscape.choice.name, "A4")
        XCTAssertEqual(landscape.orientation, .landscape)
        XCTAssertEqual(landscape.choice.pageSize(.landscape), PageSize.a4.rotated)
        let standard = PageSizeChoice.matching(.standardLandscape)
        XCTAssertEqual(standard.choice.name, PageSizeChoice.standardName)
        XCTAssertEqual(standard.choice.pageSize(.landscape), .standardLandscape)
        XCTAssertEqual(standard.choice.pageSize(.portrait), .standard)
        let custom = PageSizeChoice.matching(PageSize(400, 300))
        XCTAssertTrue(custom.choice.isCustom)
        XCTAssertEqual(custom.choice.size, PageSize(300, 400))
        XCTAssertEqual(custom.orientation, .landscape)
        XCTAssertEqual(PageSizeChoice.points(PageSizeChoice.millimetres(595.28)), 595.28, accuracy: 1e-9)
        XCTAssertEqual(PageSizeChoice.millimetres(PageSize.a4.width), 210, accuracy: 0.01)
    }

    func testBlueprintMirrorsTheLibraryStore() {
        var tick = 0
        let stamp: () -> Rev = {
            tick += 1
            return Rev(wallMs: UInt64(tick), counter: 0, device: 7)
        }
        let paper = TemplateRef(TemplateIDs.ruled)
        let cover = TemplateRef("cover.solid")
        let withCover = DocumentBlueprint.content(
            CreationRequest(id: "BLUEPRINT001", kind: .notebook, title: "A", template: paper, size: .letter, cover: cover),
            stamp: stamp, language: "de-DE", scrollDirection: .horizontal)
        XCTAssertEqual(withCover.livePages.map { $0.background.template }, [cover, paper], "cover first")
        XCTAssertTrue(withCover.meta.coverEnabled)
        XCTAssertEqual(withCover.meta.defaultTemplate, paper)
        XCTAssertEqual(withCover.meta.language, "de-DE")
        XCTAssertEqual(withCover.meta.scrollDirection, .horizontal)
        XCTAssertTrue(withCover.pages.allSatisfy { $0.size == .letter && $0.rev != .zero })

        let custom = Background.ofImage(AssetRef("paper.png"))
        let plain = DocumentBlueprint.content(
            CreationRequest(id: "BLUEPRINT002", kind: .notebook, title: "B", template: paper, size: .a4, background: custom),
            stamp: stamp, language: "en-US", scrollDirection: .vertical)
        XCTAssertEqual(plain.livePages.map(\.background), [custom])
        XCTAssertFalse(plain.meta.coverEnabled)

        let board = DocumentBlueprint.content(CreationRequest(id: "BLUEPRINT003", kind: .whiteboard, title: "C"),
                                              stamp: stamp, language: "en-US", scrollDirection: .vertical)
        XCTAssertEqual(board.livePages.count, 1)
        XCTAssertNil(board.livePages.first?.size, "an infinite board")
        XCTAssertEqual(board.livePages.first?.background.template?.id, TemplateIDs.whiteboardDots)

        let text = DocumentBlueprint.content(CreationRequest(id: "BLUEPRINT004", kind: .textDocument, title: "D"),
                                             stamp: stamp, language: "en-US", scrollDirection: .vertical)
        XCTAssertEqual(text.liveBlocks.map(\.kind), [.heading1])
        let study = DocumentBlueprint.content(CreationRequest(id: "BLUEPRINT005", kind: .studySet, title: "E"),
                                              stamp: stamp, language: "en-US", scrollDirection: .vertical)
        XCTAssertTrue(study.pages.isEmpty && study.cards.isEmpty)
    }

    func testNewNotebookSheetCreatesRemembersAndMarksAnUntitledNotebook() async throws {
        let h = harness()
        h.app.content.templates.register(Self.ruled())
        h.app.content.templates.register(Self.dots())
        h.app.content.templates.register(Self.solidCover())
        let model = NewNotebookModel(app: h.app, folder: Fixtures.folderID, kind: .notebook, session: h.session,
                                     navigator: nil)
        XCTAssertEqual(Set(model.groups), ["Writing", "Essentials"])
        XCTAssertEqual(model.covers.map(\.id), ["cover.solid"])
        let dots = try XCTUnwrap(model.papers.first { $0.id == TemplateIDs.dots })
        model.selectPaper(dots)
        model.selectCover(model.covers.first)
        model.draft.cloth = .oxblood
        model.draft.orientation = .landscape
        model.sizeSelection = "B5"

        let done = await model.create()
        XCTAssertTrue(done)
        XCTAssertNil(model.message)

        let node = try XCTUnwrap(h.library.children(of: Fixtures.folderID).first { $0.title == "Untitled" })
        let content = try h.app.workspace.content(node.id)
        XCTAssertEqual(content.livePages.count, 2)
        XCTAssertEqual(content.livePages.first?.background.template?.id, "cover.solid")
        XCTAssertEqual(content.livePages.last?.background.template?.id, TemplateIDs.dots)
        XCTAssertEqual(content.livePages.last?.size, PageSizeChoice.matching(.b5).choice.pageSize(.landscape))
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPaper).id, TemplateIDs.dots)
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultCover).params[TemplateParamNames.color],
                       TemplateColours.param(NibCoverCloth.oxblood))
        XCTAssertTrue(h.app.settings.get(NibSettings.coverByDefault))
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPageSize), PageSize.b5.rotated)
        XCTAssertEqual(PendingCreations.get(node.id, h.app.settings)?.kind, .untitled)

        // A titled notebook gets no title suggestion later.
        let titled = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        titled.draft.title = "Kinematics"
        let titledDone = await titled.create()
        XCTAssertTrue(titledDone)
        let kinematics = try XCTUnwrap(h.library.children(of: nil).first { $0.title == "Kinematics" })
        XCTAssertNil(PendingCreations.get(kinematics.id, h.app.settings))
    }

    func testTemplateChoiceBecomesThePaper() {
        let h = harness()
        let model = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        model.apply(choice: try! JSONValue.parse(#"{"background": {"kind": "template", "template": {"id": "builtin.grid", "params": {"spacing": 14}}}, "size": [612, 792]}"#))
        XCTAssertEqual(model.draft.paper, TemplateRef(TemplateIDs.grid, params: [TemplateParamNames.spacing: 14]))
        XCTAssertNil(model.draft.custom)
        XCTAssertEqual(model.draft.size.name, "Letter")
        model.apply(choice: try! JSONValue.parse(#"{"background": {"kind": "pdf", "asset": "tmp:planner.pdf", "pdfPage": 0}, "size": [800, 600]}"#))
        XCTAssertEqual(model.draft.custom?.kind, .pdf)
        XCTAssertEqual(model.draft.custom?.asset, AssetRef("tmp:planner.pdf"), "stored once the notebook exists")
        XCTAssertTrue(model.draft.size.isCustom)
        XCTAssertEqual(model.draft.orientation, .landscape)
        XCTAssertEqual(model.draft.pageSize, PageSize(800, 600))
        XCTAssertEqual(TemplateChoice.size(nil), nil)
        XCTAssertEqual(TemplateChoice.size([0, 10]), nil)
    }

    func testTemplateThumbnailDrawsTheTemplateAndItsPaperColour() throws {
        let definition = Self.ruled()
        let tile = CGSize(width: 104, height: 135)                 // NibMetrics.paperTileSize
        let image = TemplateThumbnails.render(definition, params: [TemplateParamNames.paper: "#1E1F22"],
                                              page: .a4, size: tile, scale: 2)
        XCTAssertEqual(image.size, tile)
        let middle = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 50, y: 60)))
        XCTAssertLessThanOrEqual(abs(Int(middle.r) - 0x1E), 2)
        XCTAssertLessThanOrEqual(abs(Int(middle.b) - 0x22), 2)
    }

    // MARK: - Menus, keys, panel

    func testNewMenuEntriesKeysAndPanel() async throws {
        let h = harness()
        let context = MenuContext(app: h.app, folder: Fixtures.folderID)
        let items = h.app.ui.menuItems(.libraryNew, context)
        let notebook = try XCTUnwrap(items.first { $0.id == CreateIDs.notebookMenu })
        let quick = try XCTUnwrap(items.first { $0.id == CreateIDs.quickNoteMenu })
        XCTAssertLessThan(notebook.order, quick.order)
        XCTAssertEqual(notebook.command, CommandIDs.panelOpen)
        let open = notebook.params(context)
        XCTAssertEqual(open["id"]?.stringValue, CreateIDs.newNotebookPanel)
        XCTAssertEqual(open["folder"], "folder:FIXTUREFLD01")
        XCTAssertEqual(open["kind"], "notebook")
        XCTAssertNil(open["params"], "panel.open {id, folder?, kind?}: the keys reach the sheet flat")
        XCTAssertEqual(quick.command, "doc.quickNote")
        XCTAssertEqual(quick.shortcut, KeyShortcut("n", [.command, .shift]))
        XCTAssertEqual(notebook.shortcut, KeyShortcut("n", [.command, .option]))

        // The QuickNote entry runs as it is: in the folder the New menu was opened in, or at the root.
        let inFolder = try await h.run(quick.command, quick.params(context))
        XCTAssertEqual(h.library.node(NodeRef.documentID(from: inFolder["ref"]?.stringValue ?? ""))?.parent,
                       Fixtures.folderID)
        let atRoot = try await h.run(quick.command, quick.params(MenuContext(app: h.app)))
        let rootNode = try XCTUnwrap(h.library.node(NodeRef.documentID(from: atRoot["ref"]?.stringValue ?? "")))
        XCTAssertNil(rootNode.parent, "the New menu at the root makes it at the root, whatever the window shows")

        XCTAssertNil(h.app.content.keyCommands.get(CreateIDs.quickNoteKey), "keys are registered in start")
        await h.app.start([FeatCreateFeature.self])
        QuickNoteTracker.shared(h.app)?.stop()
        let quickKey = try XCTUnwrap(h.app.content.keyCommands.get(CreateIDs.quickNoteKey))
        XCTAssertEqual(quickKey.shortcut, KeyShortcut("n", [.command, .shift]))
        XCTAssertEqual(quickKey.command, "doc.quickNote")
        let newKey = try XCTUnwrap(h.app.content.keyCommands.get(CreateIDs.newNotebookKey))
        XCTAssertEqual(newKey.shortcut, KeyShortcut("n", [.command, .option]))
        XCTAssertEqual(newKey.resolvedParams(for: h.session)["folder"], "folder:FIXTUREFLD01",
                       "from a document, next to it")

        let panel = try XCTUnwrap(h.app.ui.panels.get(CreateIDs.newNotebookPanel))
        XCTAssertEqual(panel.placement, .sheet)
        XCTAssertTrue(panel.providesHeader)
    }

    /// ⌥⌘N and ⇧⌘N are registered in `start` only when no other feature (the keyboard feature) maps them.
    func testKeysStepAsideForAnotherFeaturesMapping() async {
        let h = harness()
        h.app.content.keyCommands.register(KeyCommandDescriptor(
            id: "keyboard.quickNote", title: "New QuickNote", shortcut: KeyShortcut("N", [.shift, .command]),
            command: "doc.quickNote", scope: .global, owner: "keyboard"))
        await h.app.start([FeatCreateFeature.self])
        QuickNoteTracker.shared(h.app)?.stop()
        XCTAssertNil(h.app.content.keyCommands.get(CreateIDs.quickNoteKey))
        XCTAssertNotNil(h.app.content.keyCommands.get(CreateIDs.newNotebookKey))
        let shiftN = h.app.content.keyCommands.all.filter {
            $0.shortcut.key.lowercased() == "n" && $0.shortcut.modifiers == [.command, .shift]
        }
        XCTAssertEqual(shiftN.count, 1, "the shortcut exists once")
        // Starting again (a second window's app never does, but registration must stay idempotent) changes nothing.
        CreateMenus.registerKeys(h.app, owner: FeatCreateFeature.id)
        XCTAssertEqual(h.app.content.keyCommands.all.filter { $0.owner == FeatCreateFeature.id }.count, 1)
    }

    /// `PanelContext.params` is the flat `panel.open` call minus `id` (F017's rule, and F019's from the library).
    func testPanelParamsAreReadFlat() throws {
        let h = harness()
        let flat = NewNotebookSheet.openContext(["folder": "folder:FIXTUREFLD01", "kind": "whiteboard"], app: h.app)
        XCTAssertEqual(flat.0, Fixtures.folderID)
        XCTAssertEqual(flat.1, .whiteboard)
        var sent = try XCTUnwrap(NewNotebookSheet.openParams(folder: Fixtures.folderID, kind: .studySet).objectValue)
        XCTAssertEqual(sent.removeValue(forKey: "id"), .string(CreateIDs.newNotebookPanel))
        let received = NewNotebookSheet.openContext(.object(sent), app: h.app)
        XCTAssertEqual(received.0, Fixtures.folderID)
        XCTAssertEqual(received.1, .studySet)
        let bare = NewNotebookSheet.openContext(["folder": "FIXTUREFLD01"], app: h.app)
        XCTAssertEqual(bare.0, Fixtures.folderID, "a bare folder id")
        XCTAssertEqual(bare.1, .notebook)
        XCTAssertEqual(NewNotebookSheet.openContext([:], app: h.app).1, .notebook)
        let unknown = NewNotebookSheet.openContext(["folder": "folder:GONE", "kind": "nonsense"], app: h.app)
        XCTAssertNil(unknown.0)
        XCTAssertEqual(unknown.1, .notebook)
        XCTAssertNil(NewNotebookSheet.openContext(["folder": "doc:FIXTUREDOC01"], app: h.app).0)
    }

    // MARK: - Titles

    func testTitleSuggesterCleansAndCuts() {
        XCTAssertEqual(TitleSuggester.clean("  \n  Kinematics — SUVAT.  \nsecond line"), "Kinematics — SUVAT")
        XCTAssertEqual(TitleSuggester.clean("• Meeting notes:"), "Meeting notes")
        XCTAssertEqual(TitleSuggester.clean("Ratio 3/4: halves"), "Ratio 3-4- halves")
        XCTAssertEqual(TitleSuggester.clean("...hidden"), "hidden")
        XCTAssertNil(TitleSuggester.clean("  ?? -- !! "))
        XCTAssertNil(TitleSuggester.clean(""))
        let long = Array(repeating: "velocity", count: 20).joined(separator: " ")
        let cut = TitleSuggester.clean(long) ?? ""
        XCTAssertLessThanOrEqual(cut.count, TitleSuggester.maxLength)
        XCTAssertTrue(cut.hasSuffix("velocity"), "cut at a word boundary")
        XCTAssertEqual(TitleSuggester.clean(String(repeating: "x", count: 90))?.count, TitleSuggester.maxLength)
    }

    func testFirstRecognisedLineIsTheTopLeftOne() {
        let blocks = [TextRecognition(text: "right of title", bbox: Rect(x: 300, y: 102, width: 100, height: 20), source: "ink"),
                      TextRecognition(text: "Body text", bbox: Rect(x: 72, y: 300, width: 200, height: 20), source: "ink"),
                      TextRecognition(text: "Waves", bbox: Rect(x: 72, y: 100, width: 100, height: 20), source: "ink"),
                      TextRecognition(text: " ", bbox: Rect(x: 10, y: 10, width: 5, height: 5), source: "ink")]
        XCTAssertEqual(TitleSuggester.firstLine(blocks), "Waves")
        XCTAssertNil(TitleSuggester.firstLine([]))
        XCTAssertEqual(TitleSuggester.parse(["title": "Lenses."]), "Lenses", "doc.suggestTitle → {title}")
        XCTAssertNil(TitleSuggester.parse(["title": .null]), "null when nothing is readable")
        XCTAssertNil(TitleSuggester.parse(["title": "…"]))
        XCTAssertNil(TitleSuggester.parse([:]))
    }

    // MARK: - The QuickNote exit prompt (acceptance: every path)

    private func recognizeStub(_ h: Harness, log: CallLog, text: String) {
        stub(h, "recognize.pageText", effect: .read, log: log) { _ in
            ["blocks": [["text": .string(text), "bbox": [72, 100, 200, 20], "source": "ink"]]]
        }
    }

    private func renameStub(_ h: Harness, log: CallLog) {
        stub(h, CommandIDs.libraryRename, log: log) { p in
            try h.library.rename(NodeRef.documentID(from: p["ref"]?.stringValue ?? ""), to: p["title"]?.stringValue ?? "")
            return [:]
        }
    }

    func testExitPromptSavesWithTheFirstRecognisedLine() async throws {
        let h = harness()
        let log = CallLog()
        recognizeStub(h, log: log, text: "Wave optics\nlecture 3")
        renameStub(h, log: log)
        let id = try await quickNote(h)
        try addInk(h, to: id)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        var finished: [QuickNoteExitModel.Outcome] = []
        model.onFinish = { finished.append($0) }
        XCTAssertEqual(model.saveTitle, String(localized: "Save as Untitled"))
        XCTAssertFalse(model.offersKeep)

        await model.loadSuggestion()
        XCTAssertEqual(model.suggestion, "Wave optics")
        XCTAssertEqual(model.title, "Wave optics", "the suggestion fills the empty field")
        XCTAssertTrue(model.offersKeep)

        await model.save()
        XCTAssertEqual(log.params(CommandIDs.libraryRename).first?["title"], "Wave optics")
        XCTAssertEqual(h.library.node(id)?.title, "Wave optics")
        XCTAssertEqual(model.outcome, .saved("Wave optics"))
        XCTAssertEqual(finished, [.saved("Wave optics")])
        XCTAssertNil(PendingCreations.get(id, h.app.settings), "handled once")
    }

    func testExitPromptPrefersTheAssistantsTitleAndTheUsersOwn() async throws {
        let h = harness()
        let log = CallLog()
        recognizeStub(h, log: log, text: "first line")
        stub(h, "doc.suggestTitle", effect: .read, log: log) { _ in ["title": "Lecture: Optics"] }
        renameStub(h, log: log)
        let id = try await quickNote(h)
        try addInk(h, to: id)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        model.setTitle("My own")
        await model.loadSuggestion()
        XCTAssertEqual(model.suggestion, "Lecture- Optics")
        XCTAssertEqual(log.count("recognize.pageText"), 0, "the assistant's suggestion is enough")
        XCTAssertEqual(model.title, "My own", "a typed title is never replaced")
        model.useSuggestion()
        XCTAssertEqual(model.title, "Lecture- Optics")
        await model.save()
        XCTAssertEqual(h.library.node(id)?.title, "Lecture- Optics")
    }

    /// `doc.suggestTitle` → {title} reads the recognised lines itself: a null title is the answer (no second reading);
    /// only a failing call falls back to `recognize.pageText`.
    func testANullSuggestedTitleIsTheAnswer() async throws {
        let h = harness()
        let log = CallLog()
        recognizeStub(h, log: log, text: "first line")
        stub(h, "doc.suggestTitle", effect: .read, log: log) { _ in ["title": .null] }
        let id = try await quickNote(h)
        try addInk(h, to: id)
        let none = await TitleSuggestion.load(id, runner: .user(h.app, session: h.session), workspace: h.app.workspace)
        XCTAssertNil(none)
        XCTAssertEqual(log.count("doc.suggestTitle"), 1)
        XCTAssertEqual(log.count("recognize.pageText"), 0)

        let h2 = harness()
        let log2 = CallLog()
        recognizeStub(h2, log: log2, text: "Momentum")
        stub(h2, "doc.suggestTitle", effect: .read, log: log2) { _ in throw NibError(.internalError, "provider down") }
        let id2 = try await quickNote(h2)
        try addInk(h2, to: id2)
        let fallback = await TitleSuggestion.load(id2, runner: .user(h2.app, session: h2.session),
                                                  workspace: h2.app.workspace)
        XCTAssertEqual(fallback, "Momentum")
    }

    func testExitPromptSaveAsUntitledKeepsIt() async throws {
        let h = harness()
        let log = CallLog()
        renameStub(h, log: log)
        let id = try await quickNote(h)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        await model.loadSuggestion()
        XCTAssertNil(model.suggestion, "nothing written")
        model.setTitle("Draft")
        model.setTitle("   ")
        await model.save()
        XCTAssertEqual(model.outcome, .kept)
        XCTAssertEqual(log.count(CommandIDs.libraryRename), 0)
        XCTAssertEqual(h.library.node(id)?.title, NewDocumentKind.notebook.untitled)
        XCTAssertNil(PendingCreations.get(id, h.app.settings))
    }

    func testExitPromptCombinesIntoAnotherNotebook() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, "doc.merge", log: log) { p in
            try h.library.trash(NodeRef.documentID(from: p["source"]?.stringValue ?? ""))
            return [:]
        }
        let id = try await quickNote(h)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        XCTAssertTrue(model.canCombine)
        model.showCombine()
        XCTAssertEqual(model.mode, .combine)
        XCTAssertEqual(model.targets.map(\.id), [Fixtures.docID], "notebooks only, never the QuickNote itself")
        model.query = "fixture"
        XCTAssertEqual(model.filteredTargets.count, 1)
        model.query = "nothing like it"
        XCTAssertTrue(model.filteredTargets.isEmpty)
        XCTAssertEqual(model.place(of: try XCTUnwrap(model.targets.first)), "Fixtures")

        await model.combine(into: Fixtures.docID)
        let merge = try XCTUnwrap(log.params("doc.merge").first)
        XCTAssertEqual(merge["source"]?.stringValue, NodeRef.document(id).description)
        XCTAssertEqual(merge["into"], "doc:FIXTUREDOC01")
        XCTAssertEqual(model.outcome, .combined(Fixtures.docID))
        XCTAssertNil(PendingCreations.get(id, h.app.settings))
    }

    func testExitPromptDeletesToTrashAndReportsFailures() async throws {
        let h = harness()
        let log = CallLog()
        let id = try await quickNote(h)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)

        // Without the Library Store's commands nothing happens, the prompt says why, and the mark stays.
        XCTAssertFalse(model.canCombine, "Combine is not offered without doc.merge")
        await model.combine(into: Fixtures.docID)
        XCTAssertNil(model.outcome)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isWorking)
        XCTAssertNotNil(PendingCreations.get(id, h.app.settings))

        stub(h, CreateIDs.libraryTrash, log: log) { p in
            for ref in p["refs"]?.arrayValue ?? [] { try h.library.trash(NodeRef.documentID(from: ref.stringValue ?? "")) }
            return [:]
        }
        await model.delete()
        XCTAssertEqual(log.params(CreateIDs.libraryTrash).first?["refs"], [.string(NodeRef.document(id).description)])
        XCTAssertEqual(model.outcome, .deleted)
        XCTAssertNil(model.message)
        XCTAssertNotNil(h.library.node(id)?.trashedAt)
        XCTAssertNil(PendingCreations.get(id, h.app.settings))

        // A second choice after the first is ignored.
        await model.save()
        XCTAssertEqual(model.outcome, .deleted)
    }

    func testDismissingThePromptKeepsTheQuickNote() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        model.dismissedWithoutChoice()
        await settle { model.outcome != nil }
        XCTAssertEqual(model.outcome, .kept)
        XCTAssertNotNil(h.library.node(id))
        XCTAssertNil(PendingCreations.get(id, h.app.settings))
    }

    // MARK: - Leaving

    private func settle(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testLeaveRule() {
        let node = LibraryNode(id: "RULEDOC00001", kind: .document, title: "Untitled", path: "Untitled")
        var trashed = node
        trashed.trashedAt = 1
        let quick = PendingCreation(kind: .quickNote, title: "Untitled")
        let untitled = PendingCreation(kind: .untitled, title: "Untitled")
        XCTAssertEqual(QuickNoteExitRule.decide(nil, isShown: false, left: true, node: node, busy: false), .none)
        XCTAssertEqual(QuickNoteExitRule.decide(quick, isShown: false, left: true, node: node, busy: false), .prompt)
        XCTAssertEqual(QuickNoteExitRule.decide(quick, isShown: true, left: true, node: node, busy: false), .none)
        XCTAssertEqual(QuickNoteExitRule.decide(quick, isShown: false, left: false, node: node, busy: false), .none,
                       "no window left it (a background tab of another window): nobody is asked")
        XCTAssertEqual(QuickNoteExitRule.decide(quick, isShown: false, left: true, node: node, busy: true), .none)
        XCTAssertEqual(QuickNoteExitRule.decide(quick, isShown: false, left: false, node: trashed, busy: false), .clear)
        XCTAssertEqual(QuickNoteExitRule.decide(quick, isShown: true, left: true, node: nil, busy: false), .clear)
        XCTAssertEqual(QuickNoteExitRule.decide(untitled, isShown: false, left: true, node: node, busy: false), .offerTitle)
        var renamed = node
        renamed.title = "Waves"
        XCTAssertEqual(QuickNoteExitRule.decide(untitled, isShown: false, left: true, node: renamed, busy: false), .clear)
    }

    func testLeavingAQuickNotePromptsOnceAndOnlyWhenNoWindowShowsIt() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var prompts: [(DocumentID, EditorSession?)] = []
        tracker.presentPrompt = { model, session in
            prompts.append((model.doc, session))
            return true
        }
        tracker.start()
        defer { tracker.stop() }

        h.session.document = id
        XCTAssertTrue(prompts.isEmpty)
        // A second window shows it too: leaving the first is not leaving the QuickNote.
        let other = EditorSession()
        h.app.services.sessions.add(other)
        other.document = id
        h.app.services.sessions.activate(h.session)
        h.session.document = Fixtures.docID
        XCTAssertTrue(prompts.isEmpty)
        other.document = nil
        XCTAssertEqual(prompts.map(\.0), [id])
        XCTAssertTrue(prompts.first?.1 === other, "the window that left it last")
        // Moving around again does not prompt twice while the prompt is up.
        other.document = Fixtures.docID
        other.document = nil
        XCTAssertEqual(prompts.count, 1)
    }

    func testAQuickNoteTrashedElsewhereIsForgotten() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var prompts = 0
        tracker.presentPrompt = { _, _ in
            prompts += 1
            return true
        }
        tracker.start()
        defer { tracker.stop() }
        h.session.document = id
        try h.library.trash(id)
        h.session.document = nil
        await settle { PendingCreations.get(id, h.app.settings) == nil }
        XCTAssertEqual(prompts, 0)
        XCTAssertNil(PendingCreations.get(id, h.app.settings))
        XCTAssertFalse(tracker.watched.contains(id))
    }

    func testAPromptThatCannotShowIsTriedAgain() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var canShow = false
        var prompts = 0
        tracker.presentPrompt = { _, _ in
            guard canShow else { return false }
            prompts += 1
            return true
        }
        tracker.start()
        defer { tracker.stop() }
        h.session.document = id
        h.session.document = nil
        XCTAssertEqual(prompts, 0)
        XCTAssertFalse(tracker.busy.contains(id))
        canShow = true
        h.app.services.sessions.activate(h.session)
        tracker.evaluate()
        XCTAssertEqual(prompts, 1)
    }

    func testLeavingAnUntitledNotebookOffersItsFirstLineAsTitle() async throws {
        let h = harness()
        let log = CallLog()
        recognizeStub(h, log: log, text: "Thermodynamics")
        let model = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        let created = await model.create()
        XCTAssertTrue(created)
        let node = try XCTUnwrap(h.library.children(of: nil).first { $0.title == "Untitled" })
        try addInk(h, to: node.id)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var offers: [(DocumentID, String)] = []
        tracker.offerTitle = { doc, title, _ in
            offers.append((doc, title))
            return true
        }
        tracker.start()
        defer { tracker.stop() }
        h.session.document = node.id
        h.session.document = nil
        await settle { !offers.isEmpty && PendingCreations.get(node.id, h.app.settings) == nil }
        XCTAssertEqual(offers.map(\.0), [node.id])
        XCTAssertEqual(offers.first?.1, "Thermodynamics")
        XCTAssertNil(PendingCreations.get(node.id, h.app.settings))
    }

    func testStaleMarksArePrunedAtLaunch() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        await tracker.pruneStale()
        XCTAssertNotNil(PendingCreations.get(id, h.app.settings), "fresh marks stay")
        await tracker.pruneStale(now: Date().timeIntervalSince1970 + QuickNoteTracker.staleAfter + 60)
        XCTAssertNil(PendingCreations.get(id, h.app.settings))
    }

    // MARK: - Leaving in a window with tabs

    /// Starts the tracker with a window (`FakeNavigator`) as the active one; every prompt is recorded.
    private func trackTabs(_ h: Harness, tabs: [DocumentID] = [])
        -> (QuickNoteTracker, FakeNavigator, () -> [(DocumentID, EditorSession?)]) {
        let navigator = FakeNavigator(session: h.session, tabs: tabs)
        h.app.ui.activeNavigator = navigator
        let tracker = QuickNoteTracker.shared(h.app)!
        var prompts: [(DocumentID, EditorSession?)] = []
        tracker.presentPrompt = { model, session in
            prompts.append((model.doc, session))
            return true
        }
        tracker.start()
        return (tracker, navigator, { prompts })
    }

    /// D-119 in the real shell: switching tabs keeps the QuickNote open; showing the library in that window leaves it
    /// (the shell keeps the tab listed behind the library).
    func testSwitchingTabsKeepsAQuickNoteAndShowingTheLibraryLeavesIt() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let (tracker, navigator, prompts) = trackTabs(h, tabs: [Fixtures.docID])
        defer { tracker.stop() }

        navigator.openDocument(id, page: nil, mode: .newTab)
        navigator.openDocument(Fixtures.docID, page: nil, mode: .replace)
        tracker.evaluate()
        await settle(timeout: 0.05) { !prompts().isEmpty }
        XCTAssertTrue(prompts().isEmpty, "a tab switch is not leaving")

        navigator.showLibrary(folder: nil)
        XCTAssertEqual(prompts().map(\.0), [id])
        XCTAssertTrue(prompts().first?.1 === h.session, "the window that left it")
        XCTAssertEqual(navigator.openDocuments, [Fixtures.docID, id], "the tab is still listed")
    }

    func testWithTabsOffSwitchingDocumentsLeavesAQuickNote() async throws {
        let h = harness()
        h.app.settings.set(NibSettings.openAsTabs, false)
        let id = try await quickNote(h)
        let (tracker, navigator, prompts) = trackTabs(h)
        defer { tracker.stop() }
        navigator.openDocument(id, page: nil, mode: .replace)
        navigator.openDocument(Fixtures.docID, page: nil, mode: .replace)
        XCTAssertEqual(prompts().map(\.0), [id], "with tabs off the window's list is invisible")
    }

    /// F018 closes the shown tab by switching to its neighbour first (the QuickNote is still listed then) and removing
    /// it afterwards with no event: the deferred look finds it gone.
    func testClosingTheQuickNotesTabNeighbourFirstPrompts() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let (tracker, navigator, prompts) = trackTabs(h, tabs: [Fixtures.docID])
        defer { tracker.stop() }
        navigator.openDocument(id, page: nil, mode: .newTab)

        navigator.openDocument(Fixtures.docID, page: nil, mode: .replace)
        XCTAssertTrue(prompts().isEmpty, "still listed while the neighbour shows")
        navigator.closeDocument(id)
        await settle { !prompts().isEmpty }
        XCTAssertEqual(prompts().map(\.0), [id])
    }

    /// `tab.closeOthers` (and closing a background tab) emits no window event; the closure hook looks again.
    func testClosingOtherTabsPromptsThroughTheTabHook() async throws {
        let h = harness()
        let log = CallLog()
        let id = try await quickNote(h)
        let hook = try XCTUnwrap(h.app.bus.hooks.get(QuickNoteTracker.tabHookID))
        XCTAssertEqual(Set(hook.commands), [CommandIDs.tabClose, CommandIDs.tabCloseOthers])
        XCTAssertNotNil(hook.handler)

        let (tracker, navigator, prompts) = trackTabs(h, tabs: [Fixtures.docID])
        defer { tracker.stop() }
        stub(h, CommandIDs.tabCloseOthers, effect: .session, log: log) { _ in
            navigator.openDocuments = navigator.session.document.map { [$0] } ?? []
            return [:]
        }
        navigator.openDocument(id, page: nil, mode: .newTab)
        navigator.openDocument(Fixtures.docID, page: nil, mode: .replace)
        tracker.evaluate()
        XCTAssertTrue(prompts().isEmpty)

        try await h.run(CommandIDs.tabCloseOthers)
        XCTAssertEqual(log.count(CommandIDs.tabCloseOthers), 1, "the hook lets the call through")
        await settle { !prompts().isEmpty }
        XCTAssertEqual(prompts().map(\.0), [id])
    }

    /// A QuickNote that stays a background tab of another window is never asked about from the active window (a
    /// Delete there would trash a document that is still open); its own window is asked once it leaves it.
    func testOnlyTheWindowThatLeftAQuickNoteIsAsked() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let (tracker, window, prompts) = trackTabs(h)
        defer { tracker.stop() }
        let other = EditorSession()
        h.app.services.sessions.add(other)
        let otherWindow = FakeNavigator(session: other)
        otherWindow.openDocument(id, page: nil, mode: .newTab)
        otherWindow.openDocument(Fixtures.docID, page: nil, mode: .newTab)
        tracker.evaluate()
        XCTAssertTrue(prompts().isEmpty, "the active window does not list it, but it did not leave it either")

        h.app.ui.activeNavigator = otherWindow
        h.app.services.sessions.activate(other)
        tracker.evaluate()
        XCTAssertTrue(prompts().isEmpty, "still a tab of the window now active")
        otherWindow.showLibrary(folder: nil)
        XCTAssertEqual(prompts().map(\.0), [id])
        XCTAssertTrue(prompts().first?.1 === other)
        withExtendedLifetime(window) {}   // `activeNavigator` is weak
    }

    /// A window closed while it showed the QuickNote left it: the active window asks.
    func testClosingTheWindowThatShowedAQuickNoteAsksTheActiveOne() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var prompts: [(DocumentID, EditorSession?)] = []
        tracker.presentPrompt = { model, session in
            prompts.append((model.doc, session))
            return true
        }
        tracker.start()
        defer { tracker.stop() }
        let other = EditorSession()
        h.app.services.sessions.add(other)
        other.document = id
        XCTAssertTrue(prompts.isEmpty)
        h.app.services.sessions.remove(other)
        tracker.evaluate()
        XCTAssertEqual(prompts.map(\.0), [id])
        XCTAssertTrue(prompts.first?.1 === h.app.services.sessions.active)
    }

    /// A prompt UIKit refused, or one taken down with its window, is asked again; a swiped-down one is kept.
    func testAnAbandonedPromptIsAskedAgainAndASwipedOneIsKept() async throws {
        let h = harness()
        let id = try await quickNote(h)
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var models: [QuickNoteExitModel] = []
        tracker.presentPrompt = { model, _ in
            models.append(model)
            return true
        }
        tracker.start()
        defer { tracker.stop() }
        h.session.document = id
        h.session.document = nil
        XCTAssertEqual(models.count, 1)
        XCTAssertTrue(tracker.busy.contains(id))

        models[0].sheetDisappeared()
        await settle { !tracker.busy.contains(id) }
        XCTAssertFalse(tracker.busy.contains(id), "abandoned without a choice")
        XCTAssertNotNil(PendingCreations.get(id, h.app.settings), "the mark stays")
        XCTAssertTrue(tracker.watched.contains(id))
        tracker.evaluate()
        XCTAssertEqual(models.count, 2, "asked again on the next change")
        models[0].abandon()
        XCTAssertTrue(tracker.busy.contains(id), "an abandoned prompt is reported once")

        models[1].dismissedWithoutChoice()
        models[1].abandon()
        XCTAssertTrue(tracker.busy.contains(id), "a swipe-down keeps it: not abandoned")
        await settle { models[1].outcome != nil && !tracker.busy.contains(id) }
        XCTAssertEqual(models[1].outcome, .kept)
        XCTAssertFalse(tracker.watched.contains(id))
        XCTAssertNil(PendingCreations.get(id, h.app.settings))
    }

    func testDeleteAndCombineCloseTheQuickNotesTabFirst() async throws {
        let h = harness()
        let log = CallLog()
        let navigator = FakeNavigator(session: h.session, tabs: [Fixtures.docID])
        h.app.ui.activeNavigator = navigator
        stub(h, CommandIDs.tabClose, effect: .session, log: log) { p in
            navigator.closeDocument(NodeRef.documentID(from: p["doc"]?.stringValue ?? ""))
            return [:]
        }
        stub(h, CreateIDs.libraryTrash, log: log) { p in
            for ref in p["refs"]?.arrayValue ?? [] { try h.library.trash(NodeRef.documentID(from: ref.stringValue ?? "")) }
            return [:]
        }
        stub(h, "doc.merge", log: log) { p in
            try h.library.trash(NodeRef.documentID(from: p["source"]?.stringValue ?? ""))
            return [:]
        }

        let deleted = try await quickNote(h)
        XCTAssertEqual(navigator.openDocuments, [Fixtures.docID, deleted], "doc.quickNote opens it in the window")
        await QuickNoteExitModel(doc: deleted, app: h.app, session: h.session).delete()
        XCTAssertEqual(log.calls.map(\.command), [CommandIDs.tabClose, CreateIDs.libraryTrash])
        XCTAssertEqual(log.params(CommandIDs.tabClose).first?["doc"]?.stringValue, NodeRef.document(deleted).description)
        XCTAssertEqual(navigator.openDocuments, [Fixtures.docID], "no tab keeps a document in Trash")

        log.calls.removeAll()
        let combined = try await quickNote(h)
        XCTAssertTrue(navigator.openDocuments.contains(combined))
        await QuickNoteExitModel(doc: combined, app: h.app, session: h.session).combine(into: Fixtures.docID)
        XCTAssertEqual(log.calls.map(\.command), [CommandIDs.tabClose, "doc.merge"])
        XCTAssertEqual(navigator.openDocuments, [Fixtures.docID])

        // Not a tab: nothing to close.
        log.calls.removeAll()
        let untabbed = try await quickNote(h)
        navigator.closeDocument(untabbed)
        await QuickNoteExitModel(doc: untabbed, app: h.app, session: h.session).delete()
        XCTAssertEqual(log.calls.map(\.command), [CreateIDs.libraryTrash])
    }

    /// The Library Store makes names unique: the second QuickNote in a folder is "Untitled 2", still untitled.
    func testAUniquelyNamedQuickNoteIsStillSavedAsUntitled() async throws {
        let h = harness()
        let log = CallLog()
        stubDocCreate(h, log: log, titled: { $0 + " 2" })
        let id = try await quickNote(h)
        XCTAssertEqual(h.library.node(id)?.title, "Untitled 2")
        XCTAssertEqual(PendingCreations.get(id, h.app.settings)?.title, "Untitled 2")
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        XCTAssertEqual(model.saveTitle, String(localized: "Save as Untitled"))
        XCTAssertEqual(model.keepTitle, String(localized: "Save as Untitled"))

        try h.library.rename(id, to: "Waves")
        let renamed = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        XCTAssertEqual(renamed.keepTitle, String(localized: "Keep “Waves”"))
    }

    /// One title attempt per leave, and none for an empty notebook: the AI is asked once, and a suggestion no window
    /// could show is kept for the next leave. Nothing is opened in the workspace to find out.
    func testAnUntitledNotebookIsOfferedATitleOncePerLeaveAndOnlyWithContent() async throws {
        let h = harness()
        let log = CallLog()
        stub(h, "doc.suggestTitle", effect: .read, log: log) { _ in ["title": "Thermodynamics"] }
        recognizeStub(h, log: log, text: "never asked")
        let model = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        let created = await model.create()
        XCTAssertTrue(created)
        let node = try XCTUnwrap(h.library.children(of: nil).first { $0.title == "Untitled" })
        let tracker = try XCTUnwrap(QuickNoteTracker.shared(h.app))
        var canShow = false
        var offers: [String] = []
        tracker.offerTitle = { _, title, _ in
            guard canShow else { return false }
            offers.append(title)
            return true
        }
        tracker.start()
        defer { tracker.stop() }

        // Left empty: no call, the mark stays, and it is not watched again until a window shows it.
        h.session.document = node.id
        h.session.document = nil
        await settle { !tracker.busy.contains(node.id) }
        XCTAssertEqual(log.calls.count, 0)
        XCTAssertNotNil(PendingCreations.get(node.id, h.app.settings))
        XCTAssertFalse(tracker.watched.contains(node.id))
        h.session.document = Fixtures.docID
        tracker.evaluate()
        XCTAssertEqual(log.calls.count, 0, "other windows' changes do not ask again")

        // Written in and left: one AI call; no window can show the toast, so the suggestion waits.
        try addInk(h, to: node.id)
        h.session.document = node.id
        h.session.document = nil
        await settle { log.count("doc.suggestTitle") == 1 && !tracker.busy.contains(node.id) }
        XCTAssertEqual(log.count("doc.suggestTitle"), 1)
        XCTAssertEqual(tracker.suggestions[node.id], "Thermodynamics")
        XCTAssertFalse(tracker.watched.contains(node.id), "forgotten after the attempt")
        h.session.document = Fixtures.docID
        tracker.evaluate()
        XCTAssertEqual(log.count("doc.suggestTitle"), 1)

        // Next leave: offered from the kept suggestion, without asking the AI again.
        canShow = true
        h.session.document = node.id
        h.session.document = nil
        await settle { !offers.isEmpty && PendingCreations.get(node.id, h.app.settings) == nil }
        XCTAssertEqual(offers, ["Thermodynamics"])
        XCTAssertEqual(log.count("doc.suggestTitle"), 1)
        XCTAssertEqual(log.count("recognize.pageText"), 0)
        XCTAssertNil(tracker.suggestions[node.id])
        XCTAssertNil(PendingCreations.get(node.id, h.app.settings))
        XCTAssertFalse(h.app.workspace.isLoaded(node.id), "read without opening it")
    }

    // MARK: - New Notebook: custom paper, the template picker, failures, defaults

    func testCustomPaperGoesOnEveryPaperPageAndWarnsWithoutTheTemplatesFeature() async throws {
        let h = harness()
        let log = CallLog()
        stubDocCreate(h, log: log, cover: true)
        stub(h, CreateIDs.pageSetBackground, effect: .edit, log: log)
        h.app.content.templates.register(Self.solidCover())
        let custom = Background.ofImage(AssetRef("planner.png"))
        let request = CreationRequest(id: "CUSTOMPAPER1", kind: .notebook, title: "Planner",
                                      template: TemplateRef(TemplateIDs.ruled), size: .a4,
                                      cover: TemplateRef("cover.solid"), background: custom)
        let warnings = try await DocumentCreator.create(request, runner: .user(h.app, session: h.session),
                                                        templates: h.app.content.templates, library: h.library,
                                                        workspace: h.app.workspace, settings: h.app.settings)
        XCTAssertEqual(warnings, [])
        let call = try XCTUnwrap(log.params(CreateIDs.pageSetBackground).first)
        let pages = try h.app.workspace.content("CUSTOMPAPER1").livePages
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(call["pages"], [.string(NodeRef.page("CUSTOMPAPER1", pages[1].id).description)],
                       "every paper page, never the cover")
        XCTAssertEqual(try call["background"]?.decode(Background.self), custom)

        // Without the Templates feature the notebook still exists, on the default paper, and says why.
        let h2 = harness()
        let log2 = CallLog()
        stubDocCreate(h2, log: log2)
        var plain = request
        plain.id = "CUSTOMPAPER2"
        plain.cover = nil
        let warnings2 = try await DocumentCreator.create(plain, runner: .user(h2.app, session: h2.session),
                                                         templates: h2.app.content.templates, library: h2.library,
                                                         workspace: h2.app.workspace, settings: h2.app.settings)
        XCTAssertEqual(warnings2.count, 1)
        XCTAssertTrue(warnings2.first?.contains("Templates feature") ?? false, warnings2.first ?? "")
        XCTAssertNotNil(h2.library.node("CUSTOMPAPER2"))
    }

    /// Spec pass 2: the picker has no `doc` to store a custom paper in (the notebook does not exist yet), so it names a
    /// `tmp:` asset. The New sheet stores it in the new notebook (`asset.put {doc, url, ext}`) and names the stored
    /// asset in the Background before `page.setBackground`.
    func testATemporaryCustomPaperIsStoredInTheNewNotebookBeforeItIsApplied() async throws {
        let h = harness()
        let log = CallLog()
        stubDocCreate(h, log: log)
        stub(h, CreateIDs.templateChoose, effect: .read, log: log) { _ in
            ["background": ["kind": "pdf", "asset": "tmp:planner.pdf", "pdfPage": 2], "size": [612, 792]]
        }
        stub(h, CreateIDs.assetPut, effect: .edit, log: log) { p in
            ["asset": "3f2a9c.pdf", "doc": p["doc"] ?? .null, "bytes": 2048]
        }
        stub(h, CreateIDs.pageSetBackground, effect: .edit, log: log)
        let paperBefore = h.app.settings.get(NibSettings.defaultPaper)
        let model = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        model.draft.title = "Planner"
        model.draft.hasCover = false
        await model.chooseMore()
        XCTAssertNil(log.params(CreateIDs.templateChoose).first?["doc"], "no notebook to store it in yet")
        XCTAssertEqual(model.draft.custom, .ofPDF(AssetRef("tmp:planner.pdf"), page: 2))

        let done = await model.create()
        XCTAssertTrue(done, model.message ?? "")
        let node = try XCTUnwrap(h.library.children(of: nil).first { $0.title == "Planner" })
        let put = try XCTUnwrap(log.params(CreateIDs.assetPut).first)
        XCTAssertEqual(put["doc"]?.stringValue, NodeRef.document(node.id).description, "stored in the new notebook")
        XCTAssertEqual(put["url"], "tmp:planner.pdf")
        XCTAssertEqual(put["ext"], "pdf")
        let set = try XCTUnwrap(log.params(CreateIDs.pageSetBackground).first)
        XCTAssertEqual(try set["background"]?.decode(Background.self), .ofPDF(AssetRef("3f2a9c.pdf"), page: 2),
                       "the Background names the stored asset, never the temporary one")
        let order = log.calls.map(\.command).filter { $0 == CreateIDs.assetPut || $0 == CreateIDs.pageSetBackground }
        XCTAssertEqual(order, [CreateIDs.assetPut, CreateIDs.pageSetBackground])
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPaper), paperBefore, "a custom paper is never a default")
    }

    /// A temporary paper that cannot be stored is never applied: the notebook stays on its template paper and says why.
    /// Without `doc.create` the first content is made on the template paper and the stored paper applied after.
    func testATemporaryCustomPaperThatCannotBeStoredIsNotApplied() async throws {
        let custom = Background.ofImage(AssetRef("tmp:scan.jpg"))
        func request(_ id: DocumentID) -> CreationRequest {
            CreationRequest(id: id, kind: .notebook, title: "Scan", template: TemplateRef(TemplateIDs.ruled), size: .a4,
                            background: custom)
        }
        func create(_ h: Harness, _ r: CreationRequest) async throws -> [String] {
            try await DocumentCreator.create(r, runner: .user(h.app, session: h.session),
                                             templates: h.app.content.templates, library: h.library,
                                             workspace: h.app.workspace, settings: h.app.settings)
        }

        // No asset store command: nothing is stored or applied.
        let h = harness()
        let log = CallLog()
        stubDocCreate(h, log: log)
        stub(h, CreateIDs.pageSetBackground, effect: .edit, log: log)
        let missing = try await create(h, request("TMPPAPER0001"))
        XCTAssertEqual(missing.count, 1)
        XCTAssertTrue(missing.first?.contains("could not be stored") ?? false, missing.first ?? "")
        XCTAssertEqual(log.count(CreateIDs.pageSetBackground), 0)
        XCTAssertNotNil(h.library.node("TMPPAPER0001"))

        // asset.put fails: the same, with its reason.
        stub(h, CreateIDs.assetPut, effect: .edit, log: log) { _ in throw NibError(.notFound, "tmp:scan.jpg expired") }
        let failed = try await create(h, request("TMPPAPER0002"))
        XCTAssertTrue(failed.first?.contains("tmp:scan.jpg expired") ?? false, failed.first ?? "")
        XCTAssertEqual(log.count(CreateIDs.pageSetBackground), 0)

        // Without doc.create: the library makes it on the template paper, then the stored paper is applied.
        let h2 = harness()
        let log2 = CallLog()
        stub(h2, CreateIDs.assetPut, effect: .edit, log: log2) { _ in ["asset": "9d1e.jpg"] }
        stub(h2, CreateIDs.pageSetBackground, effect: .edit, log: log2)
        let warnings = try await create(h2, request("TMPPAPER0003"))
        XCTAssertEqual(warnings, [])
        let page = try XCTUnwrap(h2.app.workspace.content("TMPPAPER0003").livePages.first)
        XCTAssertEqual(page.background.template?.id, TemplateIDs.ruled, "never a page naming a temporary asset")
        XCTAssertEqual(log2.params(CreateIDs.assetPut).first?["ext"], "jpg")
        XCTAssertEqual(try log2.params(CreateIDs.pageSetBackground).first?["background"]?.decode(Background.self),
                       .ofImage(AssetRef("9d1e.jpg")))

        // A paper already stored (not temporary) goes straight into the library's first content.
        var stored = request("TMPPAPER0004")
        stored.background = .ofImage(AssetRef("9d1e.jpg"))
        _ = try await create(h2, stored)
        XCTAssertEqual(try h2.app.workspace.content("TMPPAPER0004").livePages.first?.background, stored.background)
        XCTAssertEqual(log2.count(CreateIDs.assetPut), 1)
        XCTAssertEqual(log2.count(CreateIDs.pageSetBackground), 1)
    }

    func testMoreTemplatesAsksTheTemplatePickerAndIgnoresACancel() async throws {
        let h = harness()
        let log = CallLog()
        var reply: Result<JSONValue, NibError> = .success(
            ["background": ["kind": "template", "template": ["id": "builtin.grid", "params": [:]]], "size": [612, 792]])
        stub(h, CreateIDs.templateChoose, effect: .read, log: log) { _ in try reply.get() }
        let model = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        XCTAssertTrue(model.canChooseMore)
        model.draft.paperColour = .ivory
        let size = model.draft.pageSize
        await model.chooseMore()
        let params = try XCTUnwrap(log.params(CreateIDs.templateChoose).first)
        XCTAssertEqual(params["kind"], "paper")
        XCTAssertEqual(params["size"], [.number(size.width), .number(size.height)])
        XCTAssertEqual(params["color"], TemplateColours.param(NibPaper.ivory))
        XCTAssertEqual(model.draft.paper.id, TemplateIDs.grid)
        XCTAssertEqual(model.draft.size.name, "Letter")
        XCTAssertNil(model.message)

        reply = .failure(NibError(.userDenied, "cancelled"))
        let before = model.draft
        await model.chooseMore()
        XCTAssertEqual(model.draft, before, "a cancelled picker changes nothing")
        XCTAssertNil(model.message, "and says nothing")

        reply = .failure(NibError(.internalError, "picker broke"))
        await model.chooseMore()
        XCTAssertTrue(model.message?.contains("picker broke") ?? false, model.message ?? "")
        XCTAssertEqual(log.count(CreateIDs.templateChoose), 3)
    }

    /// Remembered defaults are synced: only changed ones are written, and only once the document exists.
    func testNewNotebookDefaultsAreWrittenOnlyWhenChangedAndAfterCreating() async throws {
        func recordSettingsWrites(_ h: Harness) -> () -> [String] {
            var written: [String] = []
            h.app.bus.hooks.register(CommandHookDescriptor(id: "test.settingsWrites", owner: "test",
                                                           commands: [CommandIDs.settingsSet]) { _, p in
                if let name = p["name"]?.stringValue, !name.hasPrefix(PendingCreations.prefix) { written.append(name) }
                return nil
            })
            return { written }
        }
        let h = harness()
        let log = CallLog()
        let written = recordSettingsWrites(h)
        stub(h, "doc.create", log: log) { _ in throw NibError(.internalError, "disk full") }
        let failing = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        failing.draft.orientation = .landscape
        failing.draft.hasCover = false
        let failed = await failing.create()
        XCTAssertFalse(failed, "the sheet stays open")
        XCTAssertFalse(failing.isWorking)
        XCTAssertTrue(failing.message?.contains("disk full") ?? false, failing.message ?? "")
        XCTAssertTrue(failing.message?.contains(NewDocumentKind.notebook.title.lowercased()) ?? false)
        XCTAssertEqual(written(), [], "a failed creation changes no defaults")
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPageSize), .a4)

        let h2 = harness()
        let written2 = recordSettingsWrites(h2)
        let same = NewNotebookModel(app: h2.app, folder: nil, kind: .notebook, session: h2.session, navigator: nil)
        same.draft.title = "Same as before"
        let sameDone = await same.create()
        XCTAssertTrue(sameDone)
        XCTAssertEqual(written2(), [], "unchanged defaults are not written again")
        let changed = NewNotebookModel(app: h2.app, folder: nil, kind: .notebook, session: h2.session, navigator: nil)
        changed.draft.title = "No cover"
        changed.draft.hasCover = false
        let changedDone = await changed.create()
        XCTAssertTrue(changedDone)
        XCTAssertEqual(written2(), [NibSettings.coverByDefault.name])
        XCTAssertFalse(h2.app.settings.get(NibSettings.coverByDefault))
    }

    /// When `doc.create` only takes a notebook without `cover`, the cover choice is written just before that call
    /// (the Library Store follows it), and the rest once the notebook exists.
    func testTheCoverChoiceIsWrittenBeforeACoverlessDocCreate() async throws {
        let h = harness()
        let log = CallLog()
        var coverSettingAtCreate: Bool?
        stubDocCreate(h, log: log, refuse: { p in
            if p["cover"] == nil { coverSettingAtCreate = h.app.settings.get(NibSettings.coverByDefault) }
            return p["cover"] != nil
        })
        let model = NewNotebookModel(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil)
        model.draft.title = "Coverless"
        model.draft.hasCover = false
        model.draft.orientation = .landscape
        let done = await model.create()
        XCTAssertTrue(done, model.message ?? "")
        XCTAssertEqual(log.count("doc.create"), 3)
        XCTAssertEqual(coverSettingAtCreate, false, "written before the call without cover")
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPageSize), PageSize.a4.rotated)
    }

    func testSwitchingKindDropsAColourTheKindDoesNotOffer() {
        var draft = NotebookDraft.initial(settings: harness().app.settings)
        draft.paperColour = .legal
        draft.kind = .whiteboard
        XCTAssertNil(draft.paperColour, "Legal is not a board colour")
        draft.paperColour = .board
        draft.kind = .textDocument
        XCTAssertEqual(draft.paperColour, .board, "no swatches there: nothing contradicts it")
        draft.kind = .notebook
        XCTAssertNil(draft.paperColour, "the board colour is not a notebook paper")
        draft.paperColour = .slate
        draft.kind = .whiteboard
        XCTAssertEqual(draft.paperColour, .slate, "offered by both")
    }

    // MARK: - Screens render (Light, Dark, AX3)

    func testNewNotebookWithCoverColoursFitsA402PointPhone() async throws {
        let h = harness()
        h.app.content.templates.register(Self.ruled())
        h.app.content.templates.register(Self.solidCover())
        h.app.settings.set(NibSettings.coverByDefault, true)
        h.app.settings.set(NibSettings.defaultCover, TemplateRef("cover.solid"))
        let phone = CGSize(width: 402, height: 874)

        for variant in NibSnapshot.Variant.allCases {
            let sheet = NewNotebookSheet(app: h.app, folder: nil, kind: .notebook, session: h.session,
                                         navigator: nil, onDone: {})
                .environment(\.horizontalSizeClass, .compact)
            // Live hosting lets the sheet measure its width and settle into the compact layout.
            let captured = try await NibSnapshot.hostedImage(sheet, size: phone, variant: variant)
            let image = try XCTUnwrap(captured)
            XCTAssertEqual(image.size, phone)
            let attachment = XCTAttachment(image: image)
            attachment.name = "NewNotebook-cover-colours-iPhone-402-\(variant.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)

            // A nine-column swatch grid widens the whole sheet and pushes Cancel into this 16 pt margin.
            let background = try XCTUnwrap(NibSnapshot.pixel(image, at: .zero))
            var occupiedMarginPixels = 0
            for y in 16..<44 {
                for x in 0..<16 {
                    let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                    if pixel != background { occupiedMarginPixels += 1 }
                }
            }
            XCTAssertEqual(occupiedMarginPixels, 0, "Cancel must stay inside the sheet padding (\(variant.rawValue))")
        }
    }

    func testSheetsRenderInEveryVariant() async throws {
        let h = harness()
        h.app.content.templates.register(Self.ruled())
        let sheet = NewNotebookSheet(app: h.app, folder: nil, kind: .notebook, session: h.session, navigator: nil,
                                     onDone: {})
        XCTAssertEqual(NibSnapshot.images(sheet, size: CGSize(width: 720, height: 640)).count, 3)
        let phone = CGSize(width: 393, height: 852)
        for kind in NewDocumentKind.allCases {
            let view = NewNotebookSheet(app: h.app, folder: nil, kind: kind, session: h.session, navigator: nil,
                                        onDone: {})
                .environment(\.horizontalSizeClass, .compact)
            XCTAssertNotNil(NibSnapshot.image(view, size: phone, variant: .largeText), kind.rawValue)
        }
        let id = try await quickNote(h)
        let model = QuickNoteExitModel(doc: id, app: h.app, session: h.session)
        XCTAssertEqual(NibSnapshot.images(QuickNoteExitSheet(model: model), size: phone).count, 3)
        model.showCombine()
        XCTAssertEqual(NibSnapshot.images(QuickNoteExitSheet(model: model), size: phone).count, 3)
    }
}
