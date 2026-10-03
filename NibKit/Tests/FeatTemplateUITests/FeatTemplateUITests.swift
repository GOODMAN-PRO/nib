import XCTest
import UIKit
import SwiftUI
import NibDesign
import PDFKit
import NibContracts
import NibTesting
@testable import FeatTemplateUI

@MainActor
final class FeatTemplateUITests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatTemplateUIFeature.self]) }

    func testChangeTemplateMenusDispatchTheRegisteredPanelWithPageTargets() async throws {
        let h = harness()
        let panel = try XCTUnwrap(h.app.ui.panels.get("templateui.change"))
        XCTAssertEqual(panel.placement, .floating)
        XCTAssertEqual(panel.docKinds, [.notebook])
        XCTAssertTrue(panel.providesHeader)

        var presented: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open Panel",
            summary: "Capture the template menu's handoff to the document chrome.", effect: .session)) { params, ctx in
            XCTAssertTrue(ctx.session === h.session)
            XCTAssertNotNil(h.app.ui.panels.get(params["id"]?.stringValue ?? ""))
            presented = params
            return [:]
        }

        let page1 = Fixtures.page1
        let page2 = NibID("FIXTUREPG002")
        for (location, page, selection, expected) in [
            (MenuLocation.documentMore, page1, [NibID](), [page1]),
            (.sidebarPage, page2, [], [page2]),
            (.sidebarSelection, page1, [page1, page2], [page1, page2])
        ] {
            let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID,
                page: page, nodes: selection)
            let action = try XCTUnwrap(h.app.ui.menuItems(location, context)
                .first { $0.id == "templateui.change.\(location.rawValue)" })
            XCTAssertEqual(action.command, CommandIDs.panelOpen)
            presented = nil
            _ = try await h.run(action.command, action.params(context))
            XCTAssertEqual(presented?["id"], "templateui.change")
            XCTAssertEqual(presented?["kind"], "paper")
            XCTAssertEqual(presented?["pages"], .array(expected.map {
                .string(NodeRef.page(Fixtures.docID, $0).description)
            }))
        }

        // More must also work when the canvas has not published its current page yet;
        // the sheet receives an empty selection and resolves the session's page on load.
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID)
        let action = try XCTUnwrap(h.app.ui.menuItems(.documentMore, context)
            .first { $0.id == "templateui.change.documentMore" })
        _ = try await h.run(action.command, action.params(context))
        XCTAssertEqual(presented?["pages"], [])
    }

    private func store(_ h: Harness) -> CustomTemplateStore {
        CustomTemplateStore(root: h.library.metadataURL.appendingPathComponent("templates"), clock: h.app.clock)
    }
    private func image(_ h: Harness) throws -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 612, height: 792)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            UIColor.black.setStroke(); context.cgContext.move(to: CGPoint(x: 20, y: 20)); context.cgContext.addLine(to: CGPoint(x: 100, y: 100)); context.cgContext.strokePath()
        }
        let ref = try h.assets.putTemporary(XCTUnwrap(image.pngData()), ext: "png")
        return "tmp:" + ref.name
    }
    private func registerPaper(_ h: Harness) {
        h.app.content.templates.register(TemplateDefinition(id: TemplateIDs.blank, title: "Blank", category: "Essentials", owner: "templates",
            params: [TemplateParam(name: TemplateParamNames.paper, title: "Paper", kind: "color")], render: { _, _, _ in TemplateRender(paper: .white) }))
    }
    // Stand-ins expose only the contracts needed by F045, keeping feature tests independent of F005/F022.
    private func registerPages(_ h: Harness) {
        registerPaper(h)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.pageSetBackground, title: "Set Background", summary: "Test page-background stand-in.", effect: .edit)) { p, ctx in
            let background = try XCTUnwrap(p["background"]).decode(Background.self)
            try ctx.mutate { tx in
                for value in p["pages"]?.arrayValue ?? [] {
                    guard case let .page(doc, id)? = NodeRef(value.stringValue ?? ""), var page = try tx.content(doc).page(id) else { throw NibError.invalid("Invalid test page") }
                    page.background = background; try tx.put(page, doc: doc)
                }
            }
            return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.pageSetTemplate, title: "Set Template", summary: "Test template stand-in.", effect: .edit)) { p, ctx in
            try ctx.mutate { tx in
                for value in p["pages"]?.arrayValue ?? [] {
                    guard case let .page(doc, id)? = NodeRef(value.stringValue ?? ""), var page = try tx.content(doc).page(id) else { throw NibError.invalid("Invalid test page") }
                    page.background = .ofTemplate(p["template"]?.stringValue ?? TemplateIDs.blank)
                    if let size = p["size"]?.arrayValue?.compactMap(\.doubleValue) { page.size = try TemplateSizing.parse(size) }
                    try tx.put(page, doc: doc)
                }
            }
            return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Read Node", summary: "Test query stand-in.", effect: .read)) { p, ctx in
            let doc = try XCTUnwrap(NodeRef(p["ref"]?.stringValue ?? "")?.documentID)
            let content = try ctx.workspace.content(doc)
            return ["meta": try JSONValue.from(content.meta), "pages": .array(content.livePages.map { ["ref": .string(NodeRef.page(doc, $0.id).description)] })]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.assetPut, title: "Store Asset", summary: "Test asset stand-in.", effect: .edit, undoable: false)) { p, ctx in
            let doc = try XCTUnwrap(NodeRef(p["doc"]?.stringValue ?? "")?.documentID)
            let url = try await ctx.inputFile(XCTUnwrap(p["url"]?.stringValue))
            let ref = try h.assets.put(Data(contentsOf: url), ext: p["ext"]?.stringValue ?? "png", doc: doc)
            return try JSONValue.from(ref)
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.nodeSet, title: "Set Node", summary: "Test node stand-in.", effect: .edit)) { p, ctx in
            let node = try XCTUnwrap(NodeRef(p["ref"]?.stringValue ?? ""))
            let doc = try XCTUnwrap(node.documentID)
            let fields = p["fields"] ?? [:]
            try ctx.mutate { tx in
                let content = try tx.content(doc)
                if let id = node.pageID, var page = content.page(id) {
                    var ext = page.ext ?? [:]
                    let marker = fields["ext"]?[TemplateChange.customCoverKey]
                    ext[TemplateChange.customCoverKey] = marker == .null ? nil : marker
                    page.ext = ext.isEmpty ? nil : ext
                    try tx.put(page, doc: doc)
                } else {
                    var meta = content.meta
                    meta.coverEnabled = fields["meta"]?["coverEnabled"]?.boolValue ?? meta.coverEnabled
                    try tx.putMeta(meta)
                }
            }
            return [:]
        }
    }

    private func apply(_ h: Harness, _ params: JSONValue) async throws -> JSONValue {
        let id = try XCTUnwrap(params["template"]?.stringValue)
        let custom = params["custom"]?.boolValue ?? false
        let kind = custom ? try await store(h).locate(id).1.kind : "paper"
        let model = TemplateBrowserModel(app: h.app, session: h.session, kind: kind)
        let size = try TemplateSizing.parse(params["size"]?.arrayValue?.compactMap(\.doubleValue)) ?? .letter
        let pages = params["pages"]?.arrayValue?.compactMap(\.stringValue) ?? []
        try await TemplateChange.apply(TemplateSelection(id: id, custom: custom, size: size), kind: kind, pages: pages, doc: Fixtures.docID, model: model)
        return ["count": .number(Double(Set(pages).count))]
    }

    func testImportGroupRenameDeleteAndDeviceMerge() async throws {
        let h = harness()
        let root = store(h).root
        let second = CustomTemplateStore(root: root, clock: HLCClock(device: 8))
        _ = try await h.run("template.group.create", ["title": "Papers", "id": "groupA"])
        _ = try await h.run("template.import", ["url": .string(try image(h)), "group": "groupA", "kind": "paper", "id": "paperA"])
        _ = try await second.rename("groupA", title: "Work")
        _ = try await second.importFile(XCTUnwrap(h.assets.temporaryURL(AssetRef(String(try image(h).dropFirst(4))))), group: "groupA", kind: "cover", id: "coverB")
        _ = try await h.run("template.delete", ["id": "paperA"])
        let merged = try await second.group("groupA")
        XCTAssertEqual(merged.title, "Work")
        XCTAssertEqual(merged.liveTemplates.map(\.id), ["coverB"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("groupA").path).filter { $0.hasPrefix("group.") }.count, 2)
        _ = try await h.run("template.group.delete", ["group": "groupA"])
        let live = try await second.groups()
        let all = try await second.groups(includeDeleted: true)
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(all.first?.deleted == true)
        XCTAssertTrue(all.first?.templates.allSatisfy(\.deleted) == true)
    }

    func testCorruptAndFutureMetadataKeepValidEntriesAndBuiltinsAvailable() async throws {
        let h = harness(); registerPaper(h)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.templateList, title: "List Templates", summary: "Test catalogue.", effect: .read)) { _, _ in
            ["templates": [["id": .string(TemplateIDs.blank), "title": "Blank", "category": "Essentials", "isCover": false, "owner": "templates"]]]
        }
        _ = try await h.run(CommandIDs.templateImport, ["url": .string(try image(h)), "kind": "paper", "id": "valid"])
        let customStore = store(h)
        let directory = customStore.root.appendingPathComponent("custom")
        try Data("broken JSON".utf8).write(to: directory.appendingPathComponent("group.corrupt.json"))
        var group = try await customStore.group("custom")
        var unknown = try XCTUnwrap(group.templates.first)
        unknown.id = "future"; unknown.kind = "future-kind"
        group.templates.append(unknown)
        try JSONEncoder().encode(group).write(to: directory.appendingPathComponent("group.future.json"))
        let listed = try await h.run(CommandIDs.templateListCustom)
        XCTAssertEqual(listed["templates"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["valid"])
        let builtinList = try await h.run(CommandIDs.templateList)
        XCTAssertNotNil(builtinList["templates"])
        let model = TemplateBrowserModel(app: h.app, session: h.session)
        await model.load()
        XCTAssertEqual(model.builtins.map(\.id), [TemplateIDs.blank])
        XCTAssertNotNil(model.choice)
    }

    func testDefaultGroupDeletionReusesOneLiveFallback() async throws {
        let h = harness()
        _ = try await h.run(CommandIDs.templateImport, ["url": .string(try image(h)), "kind": "paper", "id": "old"])
        _ = try await h.run(CommandIDs.templateGroupDelete, ["group": "custom"])
        for id in ["newA", "newB"] {
            _ = try await h.run(CommandIDs.templateImport, ["url": .string(try image(h)), "kind": "paper", "id": .string(id)])
        }
        let groups = try await store(h).groups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, String(localized: "Custom"))
        XCTAssertEqual(Set(groups.first?.liveTemplates.map(\.id) ?? []), ["newA", "newB"])
    }

    func testConcurrentSnapshotsDeleteWinsAndMergeIsOrderIndependent() async throws {
        let h = harness()
        let customStore = store(h)
        let directory = customStore.root.appendingPathComponent("conflict")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseRev = Rev(wallMs: 100, counter: 0, device: 1)
        let baseEntry = CustomTemplate(id: "entry", title: "Base", kind: "paper", file: String(repeating: "a", count: 64) + ".png", size: .letter, rev: baseRev)
        let base = TemplateGroup(id: "conflict", title: "Base", rev: baseRev, templates: [baseEntry])
        var renamed = base; renamed.title = "Renamed"; renamed.rev = Rev(wallMs: 300, counter: 0, device: 2)
        renamed.templates[0].title = "New entry"; renamed.templates[0].rev = renamed.rev
        var deleted = base; deleted.deleted = true; deleted.rev = Rev(wallMs: 200, counter: 0, device: 1)
        deleted.templates[0].deleted = true; deleted.templates[0].rev = deleted.rev
        func write(_ first: TemplateGroup, _ second: TemplateGroup) throws {
            try JSONEncoder().encode(first).write(to: directory.appendingPathComponent("group.a.json"))
            try JSONEncoder().encode(second).write(to: directory.appendingPathComponent("group.b.json"))
        }
        try write(renamed, deleted)
        let forward = try await customStore.groups(includeDeleted: true)
        try write(deleted, renamed)
        let reverse = try await customStore.groups(includeDeleted: true)
        XCTAssertEqual(forward, reverse)
        XCTAssertTrue(forward.first?.deleted == true)
        XCTAssertTrue(forward.first?.templates.first?.deleted == true)
        XCTAssertEqual(forward.first?.templates.first?.title, "New entry")
        let live = try await customStore.groups()
        XCTAssertTrue(live.isEmpty)
    }

    func testPDFFirstPageAndAssetCopySurviveLibraryDeletion() async throws {
        let h = harness()
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage(); context.beginPage()
        }
        let ref = try h.assets.putTemporary(data, ext: "pdf")
        _ = try await h.run("template.import", ["url": .string("tmp:" + ref.name), "kind": "paper", "id": "pdf01"])
        let (group, entry) = try await store(h).locate("pdf01")
        XCTAssertEqual(PDFDocument(url: store(h).url(group: group, template: entry))?.pageCount, 1)
        let background = try await store(h).background("pdf01", doc: Fixtures.docID, assets: h.assets)
        XCTAssertEqual(background.kind, .pdf)
        XCTAssertEqual(background.pdfPage, 0)
        let asset = try XCTUnwrap(background.asset)
        _ = try await h.run("template.delete", ["id": "pdf01"])
        XCTAssertEqual(PDFDocument(data: try h.assets.data(asset, doc: Fixtures.docID))?.pageCount, 1)
    }

    func testPickerReturnsPinnedBackgroundSizeAndCancellation() async throws {
        let h = harness(); registerPaper(h)
        let picker = PickerStandIn()
        h.app.services.set(picker, for: TemplatePickerPresenter.serviceKey)
        picker.result = .success(TemplateSelection(id: TemplateIDs.blank, size: .a4.rotated, color: RGBA.paperYellow.hex))
        let result = try await h.run("template.choose", ["kind": "paper", "size": [612, 792], "color": .string(RGBA.paperYellow.hex)])
        XCTAssertEqual(result["size"], [.number(PageSize.a4.height), .number(PageSize.a4.width)])
        XCTAssertEqual(result["background"]?["kind"], "template")
        XCTAssertEqual(result["background"]?["template"]?["params"]?[TemplateParamNames.paper], .string(RGBA.paperYellow.hex))
        XCTAssertEqual(picker.request?.size, .letter)
        picker.result = .failure(NibError(.userDenied, "Cancelled"))
        do { _ = try await h.run("template.choose", ["kind": "paper"]); XCTFail("Expected cancellation") }
        catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
    }

    func testCustomPickerTemporaryOrDocumentAsset() async throws {
        let h = harness()
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "cover", "id": "cover01"])
        let picker = PickerStandIn()
        picker.result = .success(TemplateSelection(id: "cover01", custom: true, size: .letter))
        h.app.services.set(picker, for: TemplatePickerPresenter.serviceKey)
        let temporary = try await h.run("template.choose", ["kind": "cover"])
        XCTAssertTrue(temporary["background"]?["asset"]?.stringValue?.hasPrefix("tmp:") == true)
        XCTAssertNil(temporary["background"]?["template"])
        let stored = try await h.run("template.choose", ["kind": "cover", "doc": .string(NodeRef.document(Fixtures.docID).description)])
        let name = try XCTUnwrap(stored["background"]?["asset"]?.stringValue)
        XCTAssertFalse(name.hasPrefix("tmp:"))
        XCTAssertFalse(try h.assets.data(AssetRef(name), doc: Fixtures.docID).isEmpty)
    }

    func testCustomPickerDryRunOnlyUsesTemporaryAssets() async throws {
        let h = harness()
        _ = try await h.run(CommandIDs.templateImport, ["url": .string(try image(h)), "kind": "cover", "id": "dryCover"])
        let picker = PickerStandIn()
        picker.result = .success(TemplateSelection(id: "dryCover", custom: true, size: .letter))
        h.app.services.set(picker, for: TemplatePickerPresenter.serviceKey)
        let result = try await h.app.bus.execute(Invocation(command: CommandIDs.templateChoose,
            params: ["kind": "cover", "doc": .string(NodeRef.document(Fixtures.docID).description)], session: h.session, dryRun: true)).value
        let temporary = try XCTUnwrap(result["background"]?["asset"]?.stringValue)
        XCTAssertTrue(temporary.hasPrefix("tmp:"))
        XCTAssertThrowsError(try h.assets.data(AssetRef(String(temporary.dropFirst(4))), doc: Fixtures.docID))
    }

    func testNoCoverChoiceReturnsUserDenied() async throws {
        let h = harness(); registerPaper(h)
        let picker = PickerStandIn()
        h.app.services.set(picker, for: TemplatePickerPresenter.serviceKey)
        picker.result = .success(TemplateSelection(id: TemplateIDs.blank, size: .letter, color: RGBA.paperYellow.hex))
        do { _ = try await h.run(CommandIDs.templateChoose, ["kind": "cover"]); XCTFail("Expected no cover") }
        catch let error as NibError { XCTAssertEqual(error.code, .userDenied) }
        XCTAssertNil(h.app.commands.descriptor("template.apply"))
    }

    func testFromPageCallsFlattenedExportAndImportsChosenID() async throws {
        let h = harness()
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { $0.beginPage() }
        let ref = try h.assets.putTemporary(pdf, ext: "pdf")
        var exported: JSONValue?
        h.app.commands.register(CommandDescriptor(id: CommandIDs.exportRun, title: "Export", summary: "Test exporter.", effect: .read)) { params, _ in
            exported = params
            return ["files": [["asset": .string("tmp:" + ref.name)]]]
        }
        let output = try await h.run("template.fromPage", ["page": "page:FIXTUREDOC01/FIXTUREPG002", "title": "Lecture", "id": "lecture"])
        XCTAssertEqual(output["id"], "lecture")
        XCTAssertEqual(exported?["options"]?["mode"], "flattened")
        XCTAssertEqual(exported?["pages"], ["page:FIXTUREDOC01/FIXTUREPG002"])
        let lecture = try await store(h).locate("lecture").1
        XCTAssertEqual(lecture.title, "Lecture")
    }

    func testApplyCustomCoverThenPaperAndUndoRedo() async throws {
        let h = harness(); registerPages(h)
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "cover", "id": "cover01"])
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)
        _ = try await apply(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "cover01", "custom": true, "size": [612, 792]])
        let covered = try h.snapshot()
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.ext?[TemplateChange.customCoverKey], "cover01")
        h.app.bus.undo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), before)
        h.app.bus.redo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), covered)
        _ = try await apply(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": .string(TemplateIDs.blank)])
        XCTAssertFalse(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.ext?[TemplateChange.customCoverKey])
        h.app.bus.undo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), covered)
    }

    func testAllPaperPagesPreserveCoverAndInvalidSizeDoesNotMutate() async throws {
        let h = harness(); registerPages(h)
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "paper", "id": "paper01"])
        let before = try h.snapshot()
        do {
            _ = try await apply(h, ["pages": ["doc:FIXTUREDOC01"], "template": "paper01", "custom": true, "size": [0, 792]])
            XCTFail("Expected invalid size")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(), before)
        let first = try h.app.workspace.content(Fixtures.docID).livePages.first
        _ = try await apply(h, ["pages": ["doc:FIXTUREDOC01"], "template": "paper01", "custom": true])
        let content = try h.app.workspace.content(Fixtures.docID)
        if content.meta.coverEnabled { XCTAssertEqual(content.livePages.first?.background, first?.background) }
        XCTAssertTrue(content.livePages.dropFirst().allSatisfy { $0.background.kind == .image })
        h.app.bus.undo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), before)
    }

    func testDefaultSelectionPluginCoversAndDistinctGroupFilters() async throws {
        let h = harness(); registerPaper(h)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.templateList, title: "List Templates", summary: "Test catalogue.", effect: .read)) { _, _ in
            ["templates": [["id": .string(TemplateIDs.blank), "title": "Blank", "category": "Essentials", "isCover": false, "owner": "templates"],
                           ["id": "plugin.cover", "title": "Plugin Cover", "category": "Art", "isCover": true, "owner": "plugin"]]]
        }
        h.app.content.templates.register(TemplateDefinition(id: "plugin.cover", title: "Plugin Cover", category: "Art", isCover: true, owner: "plugin", render: { _, _, _ in TemplateRender(paper: .white) }))
        _ = try await h.run("template.group.create", ["title": "Papers", "id": "groupA"])
        _ = try await h.run("template.group.create", ["title": "Papers", "id": "groupB"])
        _ = try await h.run("template.import", ["url": .string(try image(h)), "group": "groupA", "kind": "paper", "id": "paperA"])
        _ = try await h.run("template.import", ["url": .string(try image(h)), "group": "groupB", "kind": "paper", "id": "paperB"])
        let model = TemplateBrowserModel(app: h.app, session: h.session)
        await model.load()
        XCTAssertEqual(model.categories.filter { $0.title == "Papers" }.count, 2)
        model.category = "group:groupA"
        XCTAssertEqual(model.customs.map { $0.template.id }, ["paperA"])
        model.category = ""; model.selection = TemplateIDs.blank; model.size = .letter; model.color = RGBA.paperYellow.hex
        model.setDefault()
        while model.busy { await Task.yield() }
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPaper), TemplateRef(TemplateIDs.blank, params: [TemplateParamNames.paper: .string(RGBA.paperYellow.hex)]))
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultPageSize), .letter)
        model.changeKind("cover")
        await model.load()
        XCTAssertEqual(model.builtins.map(\.id), ["plugin.cover"])
        XCTAssertTrue(model.categories.contains { $0.title == "From plugins" })
        model.selection = TemplateIDs.blank
        model.setDefault()
        while model.busy { await Task.yield() }
        XCTAssertFalse(h.app.settings.get(NibSettings.coverByDefault))
    }

    func testHiddenAndDeletedSelectionsRecoverToAvailableTemplates() async throws {
        let h = harness(); registerPaper(h)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.templateList, title: "List Templates", summary: "Test catalogue.", effect: .read)) { _, _ in
            ["templates": [["id": .string(TemplateIDs.blank), "title": "Blank", "category": "Essentials", "isCover": false, "owner": "templates"]]]
        }
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "paper", "id": "paper01"])
        let model = TemplateBrowserModel(app: h.app, session: h.session)
        await model.load(); XCTAssertEqual(model.selection, TemplateIDs.blank)
        _ = try await h.run("template.setHidden", ["id": .string(TemplateIDs.blank), "hidden": true])
        await model.load(); XCTAssertEqual(model.selection, "paper01")
        _ = try await h.run("template.delete", ["id": "paper01"])
        await model.load(); XCTAssertNil(model.choice)
        _ = try await h.run("template.setHidden", ["id": .string(TemplateIDs.blank), "hidden": false])
        await model.load(); XCTAssertEqual(model.selection, TemplateIDs.blank)
    }

    func testSelectedPagesDeduplicateAndRejectCoverOnLaterPage() async throws {
        let h = harness(); registerPages(h)
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "cover", "id": "cover01"])
        let before = try h.snapshot()
        do {
            _ = try await apply(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "cover01", "custom": true])
            XCTFail("A cover must only change page 1")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(), before)
        let output = try await apply(h, ["pages": ["page:FIXTUREDOC01/FIXTUREPG002", "page:FIXTUREDOC01/FIXTUREPG002"], "template": .string(TemplateIDs.blank), "size": [612, 792]])
        XCTAssertEqual(output["count"], 1)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).page(NibID("FIXTUREPG002"))?.size, .letter)
        h.app.bus.undo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), before)
    }

    func testScreenSnapshotsAcrossAppearanceAndAccessibility() async throws {
        let h = harness(); registerPaper(h)
        h.app.commands.register(CommandDescriptor(id: CommandIDs.templateList, title: "List Templates", summary: "Snapshot catalogue.", effect: .read)) { _, ctx in
            let values: [JSONValue] = ctx.content.templates.all.map { definition in
                ["id": .string(definition.id), "title": .string(definition.title), "category": .string(definition.category), "owner": .string(definition.owner), "isCover": .bool(definition.isCover)]
            }
            return ["templates": .array(values)]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Read Node", summary: "Snapshot query stand-in.", effect: .read)) { p, ctx in
            guard let node = NodeRef(p["ref"]?.stringValue ?? ""), let doc = node.documentID else { throw NibError.invalid("Invalid snapshot ref") }
            let content = try ctx.workspace.content(doc)
            if let id = node.pageID, let page = content.page(id) {
                return ["size": page.size.map { [.number($0.width), .number($0.height)] } ?? .null, "background": try JSONValue.from(page.background)]
            }
            return ["pages": .array(content.livePages.map { ["ref": .string(NodeRef.page(doc, $0.id).description)] })]
        }
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        let request = TemplatePickerRequest(kind: "paper", size: .a4, session: h.session)
        let screens: [(String, AnyView)] = [
            ("library", AnyView(TemplateLibraryView(context: context))),
            ("picker", AnyView(TemplatePickerView(app: h.app, request: request, finish: { _ in }))),
            ("change", AnyView(ChangeTemplateSheet(context: context)))
        ]
        for (name, screen) in screens {
            _ = NibSnapshot.image(screen, size: NibMetrics.newDocumentSheetSize, scale: 1)
            await Task.yield()
            for variant in NibSnapshot.Variant.allCases {
                let image = try XCTUnwrap(NibSnapshot.image(screen, size: NibMetrics.newDocumentSheetSize, variant: variant, scale: 1))
                XCTAssertEqual(image.size, NibMetrics.newDocumentSheetSize)
                let cg = try XCTUnwrap(image.cgImage)
                let data = try XCTUnwrap(cg.dataProvider?.data) as Data
                let colors = Set(stride(from: 0, to: data.count - 4, by: max(4, (cg.bytesPerRow / 16 / 4) * 4)).map { Array(data[$0..<$0 + 3]) })
                XCTAssertGreaterThan(colors.count, 8, "\(name) / \(variant.rawValue) must render content, not a blank surface")
                let attachment = XCTAttachment(image: image); attachment.name = name + "-" + variant.rawValue; attachment.lifetime = .keepAlways; add(attachment)
            }
            let reduced = try XCTUnwrap(NibSnapshot.image(screen.nibLiquidMode(.off), size: NibMetrics.newDocumentSheetSize, scale: 1))
            let reducedAttachment = XCTAttachment(image: reduced); reducedAttachment.name = name + "-opaque-liquid-off"; reducedAttachment.lifetime = .keepAlways; add(reducedAttachment)
            let phoneSize = CGSize(width: 390, height: 844)
            let phone = screen.environment(\.horizontalSizeClass, .compact)
            XCTAssertNotNil(NibSnapshot.image(phone, size: phoneSize, variant: .largeText, scale: 1))
        }
    }

    func testTemplateGridReservesSpaceForEveryCoverAtNarrowSheetWidths() {
        // A 600 pt sheet leaves only 324 pt beside the sidebar. Four 88 pt covers
        // used to overlap, making Carbon unreachable even after scrolling.
        let layout = TemplateBrowserLayout(width: 600, compactSizeClass: false,
            accessibilitySize: false, cover: true)
        XCTAssertFalse(layout.compact)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.tileSize, NibMetrics.coverStripSize)
        XCTAssertLessThanOrEqual(CGFloat(layout.columns) * layout.tileSize.width
            + CGFloat(layout.columns - 1) * NibSpacing.m, layout.gridWidth)

        let wide = TemplateBrowserLayout(width: 760, compactSizeClass: false,
            accessibilitySize: false, cover: false)
        XCTAssertEqual(wide.columns, 4)
        XCTAssertEqual(wide.tileSize, NibMetrics.paperTileSize)
    }

    func testTemplateGridFitsPaperCoversAndNoCoverAcrossResizingAndAccessibility() {
        for width: CGFloat in [320, 344, 390, 599, 600, 664, 720, 760, 1024] {
            for compact in [false, true] {
                for accessibility in [false, true] {
                    for cover in [false, true] {
                        let layout = TemplateBrowserLayout(width: width, compactSizeClass: compact,
                            accessibilitySize: accessibility, cover: cover)
                        let base = cover ? NibMetrics.coverStripSize : NibMetrics.paperTileSize
                        let cellWidth = (layout.gridWidth - CGFloat(layout.columns - 1) * NibSpacing.m) / CGFloat(layout.columns)
                        XCTAssertGreaterThanOrEqual(layout.tileSize.width, NibMetrics.hitTarget)
                        XCTAssertLessThanOrEqual(layout.tileSize.width, cellWidth)
                        XCTAssertEqual(layout.tileSize.height / layout.tileSize.width,
                            base.height / base.width, accuracy: 0.0001)
                        XCTAssertLessThanOrEqual(layout.gridWidth + NibSpacing.xl * 2
                            + (layout.compact ? 0 : NibMetrics.settingsSectionListWidth + NibSpacing.l), width)
                        if accessibility { XCTAssertEqual(layout.columns, 1) }
                        else if layout.compact { XCTAssertEqual(layout.columns, 3) }

                        // No cover and every built-in/custom cover share this size. Their full
                        // hit rectangles, including Carbon in column 2, fit without intersecting.
                        let frames = (0..<layout.columns).map { column in
                            CGRect(x: CGFloat(column) * (cellWidth + NibSpacing.m)
                                + (cellWidth - layout.tileSize.width) / 2,
                                y: 0, width: layout.tileSize.width, height: layout.tileSize.height)
                        }
                        for (index, frame) in frames.enumerated() {
                            XCTAssertGreaterThanOrEqual(frame.minX, 0)
                            XCTAssertLessThanOrEqual(frame.maxX, layout.gridWidth + 0.0001)
                            for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
                        }
                    }
                }
            }
        }
    }

    func testInvalidIDsAndHiddenSettingsAndConformance() async throws {
        let h = harness(); registerPaper(h)
        do { _ = try await h.run("template.group.create", ["title": "Bad", "id": "../outside"]); XCTFail("Expected invalid ID") }
        catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        _ = try await h.run("template.setHidden", ["id": .string(TemplateIDs.blank), "hidden": true])
        XCTAssertEqual(h.app.settings.json("templates.hidden." + TemplateIDs.blank), true)
        _ = try await h.run("template.setHidden", ["id": .string(TemplateIDs.blank), "hidden": false])
        XCTAssertEqual(h.app.settings.json("templates.hidden." + TemplateIDs.blank), false)
        XCTAssertNotNil(h.app.ui.panels.get(PanelIDs.templates))
        let problems = await CommandConformance.check(features: [FeatTemplateUIFeature.self])
        XCTAssertEqual(problems, [])
    }
}

@MainActor
private final class PickerStandIn: TemplatePicking {
    var request: TemplatePickerRequest?
    var result: Result<TemplateSelection, Error> = .failure(NibError(.userDenied, "Cancelled"))
    func choose(_ request: TemplatePickerRequest, app: NibApp, navigator: SceneNavigator?) async throws -> TemplateSelection {
        self.request = request
        return try result.get()
    }
}
