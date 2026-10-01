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
                    page.background = .ofTemplate(p["template"]?.stringValue ?? TemplateIDs.blank); try tx.put(page, doc: doc)
                }
            }
            return [:]
        }
    }

    func testImportGroupRenameDeleteAndDeviceMerge() async throws {
        let h = harness()
        let root = store(h).root
        let second = CustomTemplateStore(root: root, clock: HLCClock(device: 8))
        _ = try await h.run("template.group.create", ["title": "Papers", "id": "groupA"])
        _ = try await h.run("template.import", ["url": .string(try image(h)), "group": "groupA", "kind": "paper", "id": "paperA"])
        _ = try second.rename("groupA", title: "Work")
        _ = try await second.importFile(XCTUnwrap(h.assets.temporaryURL(AssetRef(String(try image(h).dropFirst(4))))), group: "groupA", kind: "cover", id: "coverB")
        _ = try await h.run("template.delete", ["id": "paperA"])
        let merged = try second.group("groupA")
        XCTAssertEqual(merged.title, "Work")
        XCTAssertEqual(merged.liveTemplates.map(\.id), ["coverB"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("groupA").path).filter { $0.hasPrefix("group.") }.count, 2)
        _ = try await h.run("template.group.delete", ["group": "groupA"])
        XCTAssertTrue(try second.groups().isEmpty)
        XCTAssertTrue(try second.groups(includeDeleted: true).first?.deleted == true)
    }

    func testPDFFirstPageAndAssetCopySurviveLibraryDeletion() async throws {
        let h = harness()
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage(); context.beginPage()
        }
        let ref = try h.assets.putTemporary(data, ext: "pdf")
        _ = try await h.run("template.import", ["url": .string("tmp:" + ref.name), "kind": "paper", "id": "pdf01"])
        let (group, entry) = try store(h).locate("pdf01")
        XCTAssertEqual(PDFDocument(url: store(h).url(group: group, template: entry))?.pageCount, 1)
        let background = try store(h).background("pdf01", doc: Fixtures.docID, assets: h.assets)
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
        XCTAssertEqual(temporary["background"]?["template"]?["id"], .string(TemplateApply.customCoverKey))
        XCTAssertEqual(temporary["background"]?["template"]?["params"]?["id"], "cover01")
        let stored = try await h.run("template.choose", ["kind": "cover", "doc": .string(NodeRef.document(Fixtures.docID).description)])
        let name = try XCTUnwrap(stored["background"]?["asset"]?.stringValue)
        XCTAssertFalse(name.hasPrefix("tmp:"))
        XCTAssertFalse(try h.assets.data(AssetRef(name), doc: Fixtures.docID).isEmpty)
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
        XCTAssertEqual(try store(h).locate("lecture").1.title, "Lecture")
    }

    func testApplyCustomCoverThenPaperAndUndoRedo() async throws {
        let h = harness(); registerPages(h)
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "cover", "id": "cover01"])
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)
        _ = try await h.run("template.apply", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "cover01", "custom": true, "size": [612, 792]])
        let covered = try h.snapshot()
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth + 1)
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.ext?[TemplateApply.customCoverKey], true)
        h.app.bus.undo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), before)
        h.app.bus.redo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), covered)
        _ = try await h.run("template.apply", ["pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": .string(TemplateIDs.blank)])
        XCTAssertFalse(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertNil(try h.app.workspace.content(Fixtures.docID).page(Fixtures.page1)?.ext?[TemplateApply.customCoverKey])
        h.app.bus.undo(Fixtures.docID); XCTAssertEqual(try h.snapshot(), covered)
    }

    func testAllPaperPagesPreserveCoverAndInvalidSizeDoesNotMutate() async throws {
        let h = harness(); registerPages(h)
        _ = try await h.run("template.import", ["url": .string(try image(h)), "kind": "paper", "id": "paper01"])
        let before = try h.snapshot()
        do {
            _ = try await h.run("template.apply", ["pages": ["doc:FIXTUREDOC01"], "template": "paper01", "custom": true, "size": [0, 792]])
            XCTFail("Expected invalid size")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(), before)
        let first = try h.app.workspace.content(Fixtures.docID).livePages.first
        _ = try await h.run("template.apply", ["pages": ["doc:FIXTUREDOC01"], "template": "paper01", "custom": true])
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
            _ = try await h.run("template.apply", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "cover01", "custom": true])
            XCTFail("A cover must only change page 1")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(), before)
        let output = try await h.run("template.apply", ["pages": ["page:FIXTUREDOC01/FIXTUREPG002", "page:FIXTUREDOC01/FIXTUREPG002"], "template": .string(TemplateIDs.blank), "size": [612, 792]])
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
                let attachment = XCTAttachment(image: image); attachment.name = name + "-" + variant.rawValue; attachment.lifetime = .keepAlways; add(attachment)
            }
            let reduced = try XCTUnwrap(NibSnapshot.image(screen.nibLiquidMode(.off), size: NibMetrics.newDocumentSheetSize, scale: 1))
            let reducedAttachment = XCTAttachment(image: reduced); reducedAttachment.name = name + "-opaque-liquid-off"; reducedAttachment.lifetime = .keepAlways; add(reducedAttachment)
            let phoneSize = CGSize(width: 390, height: 844)
            let phone = screen.environment(\.horizontalSizeClass, .compact)
            XCTAssertNotNil(NibSnapshot.image(phone, size: phoneSize, variant: .largeText, scale: 1))
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
