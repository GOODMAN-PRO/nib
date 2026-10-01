import XCTest
import UIKit
import SwiftUI
import NibDesign
import NibContracts
import NibTesting
@testable import FeatTeacher

@MainActor
final class ClusterEngineTests: XCTestCase {
    private let source: DocumentID = "INSIGHTSOURCE01"
    private let page: PageID = "INSIGHTPAGE01"
    private let zone: ElementID = "INSIGHTZONE01"
    private let copies: [DocumentID] = ["INSIGHTCOPY01", "INSIGHTCOPY02"]
    private var zoneRef: String { NodeRef.item(source, page, zone).description }
    private func member(_ index: Int) -> String { NodeRef.item(copies[index], page, zone).description }

    private func harness() async throws -> (Harness, FakeRenderer) {
        let h = Harness(features: [FeatTeacherFeature.self, FeatTeacherLessonsFeature.self, FeatTeacherInsightsFeature.self])
        let renderer = FakeRenderer()
        h.app.services.renderer = renderer
        // Exercise the public render.page contract without importing F004 into this module.
        h.app.commands.register(CommandDescriptor(id: CommandIDs.renderPage, title: "Render", summary: "Test render.page adapter",
                                                   params: .obj(["page": .ref, "region": .rect, "scale": .num()], required: ["page"]), effect: .read)) { params, ctx in
            guard case .page(let doc, let page)? = NodeRef(try XCTUnwrap(params["page"]?.stringValue)) else { throw NibError.invalid("page") }
            let region = try params["region"]?.decode(NibContracts.Rect.self)
            let result = try await renderer.render(RenderRequest(doc: doc, page: page, region: region, scale: 1))
            let data = try XCTUnwrap(UIImage(cgImage: result.image).pngData())
            let asset = try h.assets.putTemporary(data, ext: "png")
            return ["asset": .string("tmp:" + asset.name), "region": try JSONValue.from(result.region), "pxPerPt": 1]
        }
        let content = DocumentContent(meta: DocumentMeta(id: source, kind: .notebook),
                                      pages: [PageRecord(id: page, order: "V", size: .a4)])
        _ = try h.library.createDocument(content, title: "Motion", in: Fixtures.folderID)
        var item = try AnswerZone(label: "Speed", points: 5).makeItem(frame: Frame(x: 48, y: 240, w: 400, h: 180), layer: 0)
        item.id = zone
        try await h.insert([item], page: page, doc: source)
        try await h.run(CommandIDs.lessonImportRoster, ["folder": "folder:FIXTUREFLD01", "csv": "id,name\nsam,Sam\nlee,Lee"])
        try await h.run(CommandIDs.lessonCreate, ["doc": .string(source.raw), "folder": "folder:FIXTUREFLD01", "ids": try JSONValue.from(copies.map(\.raw))])
        for (index, doc) in copies.enumerated() {
            let answer = Item(id: NibID("ANSWER0\(index)"), kind: .text, z: "k", text: TextBoxItem(
                frame: Frame(x: 60, y: 260, w: 300, h: 100), text: RichText(plain: index == 0 ? "6 m/s" : "120 times 20")))
            try await h.insert([answer], page: page, doc: doc)
        }
        return (h, renderer)
    }

    private func collect(_ h: Harness, renders: Bool = false) async throws -> InsightCollection {
        try await h.run(CommandIDs.lessonCollect, ["doc": .string(source.raw), "zone": .string(zoneRef), "renders": .bool(renders)]).decode(InsightCollection.self)
    }

    func testCollectsTwoTempCopiesByPageAndQuestionAndRendersTheMatchingRegion() async throws {
        let (h, renderer) = try await harness()
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.persistence.root.path))
        let question = try await collect(h, renders: true)
        XCTAssertEqual(question.copies.map(\.student), ["Lee", "Sam"])
        XCTAssertEqual(Set(question.entries.map(\.id)), Set([member(0), member(1)]))
        XCTAssertEqual(Set(question.entries.map(\.text)), Set(["6 m/s", "120 times 20"]))
        XCTAssertEqual(renderer.requests.count, 3, "Two copies and the model region")
        XCTAssertTrue(renderer.requests.allSatisfy { $0.region == NibContracts.Rect(x: 48, y: 240, width: 400, height: 180) })
        XCTAssertTrue(question.entries.allSatisfy { $0.asset?.hasPrefix("tmp:") == true })
        XCTAssertEqual(question.questions.first?.id, zoneRef)
        let byPage = try await h.run(CommandIDs.lessonCollect, ["doc": .string(copies[0].raw), "page": .string(NodeRef.page(copies[0], page).description), "renders": false]).decode(InsightCollection.self)
        XCTAssertEqual(byPage.source, NodeRef.document(source).description)
        XCTAssertEqual(byPage.entries.count, 2)
        XCTAssertTrue(byPage.entries.allSatisfy { $0.zone == nil && $0.region.width == PageSize.a4.width })
        XCTAssertNil(byPage.zone)
    }

    func testFakeAIComparisonIsReadOnlyAndReviewedBulkScoresUndoAndRedoTogether() async throws {
        let (h, _) = try await harness()
        let json: JSONValue = ["clusters": [["id": "exact", "label": "Exact", "members": [.string(member(0))]],
                                            ["id": "noMatch", "label": "No match", "members": [.string(member(1))]]]]
        let ai = FakeAIService(responses: [.init(text: "```json\n" + json.jsonString() + "\n```")])
        h.app.services.ai = ai
        let before = try copies.map { try h.snapshot($0) }
        let suggested = try await h.run(CommandIDs.lessonCluster, ["zone": .string(zoneRef), "mode": "modelAnswer", "modelAnswer": "6 m/s"]).decode(LessonCluster.Output.self)
        XCTAssertEqual(suggested.clusters.map(\.id), ClusterEngine.categories)
        XCTAssertEqual(try copies.map { try h.snapshot($0) }, before)
        XCTAssertEqual(ai.requests.first?.mode, .ask)
        XCTAssertEqual(ai.requests.first?.tools, [])
        XCTAssertEqual(ai.requests.first?.messages.first?.images?.count, 2)
        var clusters = suggested.clusters
        clusters[0].score = 5; clusters[3].score = 0
        let sourceBefore = try h.snapshot(source)
        let result = try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": try JSONValue.from(clusters),
                                                                  "revisions": try JSONValue.from(suggested.revisions), "applyScores": true])
        XCTAssertEqual(Set(result["scored"]?.arrayValue?.compactMap(\.stringValue) ?? []), Set([member(0), member(1)]))
        let changed = try copies.map { try h.snapshot($0) }
        XCTAssertTrue(h.app.bus.undo(copies[0]))
        XCTAssertEqual(try copies.map { try h.snapshot($0) }, before)
        XCTAssertEqual(try h.snapshot(source), sourceBefore)
        XCTAssertTrue(h.app.bus.redo(source))
        XCTAssertEqual(try copies.map { try h.snapshot($0) }, changed)
        let recollected = try await collect(h)
        XCTAssertEqual(recollected.clusters, clusters)
    }

    func testUntrustedClusterJSONRejectsUnknownDuplicateAndMissingMembersAndBadScores() async throws {
        let (h, _) = try await harness()
        let entries = try await collect(h).entries
        let valid = InsightCluster(id: "working", label: "Shared working", members: [member(0), member(1)])
        XCTAssertNoThrow(try ClusterEngine.parse(try JSONValue.from(["clusters": [valid]]).jsonString(), entries: entries, mode: .similarity))
        let bad: [[InsightCluster]] = [
            [.init(id: "working", label: "A", members: [member(0), member(0)])],
            [.init(id: "working", label: "A", members: [member(0)])],
            [.init(id: "working", label: "A", members: [member(0), "item:OTHER/P/I"])],
            [.init(id: "working", label: "A", members: [member(0), member(1)], score: 6)],
            [.init(id: "working", label: "A", members: [member(0)]), .init(id: "working", label: "B", members: [member(1)])]
        ]
        for clusters in bad {
            XCTAssertThrowsError(try ClusterEngine.parse(try JSONValue.from(["clusters": clusters]).jsonString(), entries: entries, mode: .similarity))
        }
        XCTAssertThrowsError(try ClusterEngine.parse("not JSON", entries: entries, mode: .similarity))
        XCTAssertThrowsError(try ClusterEngine.parse(try JSONValue.from(["clusters": [valid]]).jsonString(), entries: entries, mode: .modelAnswer))
    }

    func testManualClustersPreserveAnswerZoneDataAndRejectForeignMembers() async throws {
        let (h, _) = try await harness()
        let original = try h.app.workspace.item(source, page: page, id: zone)
        let clusters = [InsightCluster(id: "manual", label: "Discuss units", members: [member(0)])]
        try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": try JSONValue.from(clusters), "modelAnswer": "6 m/s"])
        let saved = try h.app.workspace.item(source, page: page, id: zone)
        XCTAssertEqual(AnswerZone.decode(saved), AnswerZone.decode(original))
        let recollected = try await collect(h)
        XCTAssertEqual(recollected.modelAnswer, "6 m/s")
        XCTAssertTrue(h.app.bus.undo(source))
        XCTAssertNil(try h.app.workspace.item(source, page: page, id: zone).custom?.data[ClusterEngine.recordKey])
        let snapshot = try h.snapshot(source)
        do {
            let foreign = InsightCluster(id: "manual", label: "Foreign", members: [NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.customID).description])
            try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": try JSONValue.from([foreign])])
            XCTFail("Foreign member must fail")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
        XCTAssertEqual(try h.snapshot(source), snapshot)
    }

    func testStalePreviewAndLockedCopyNeverPartiallyGradeTheClass() async throws {
        let (h, _) = try await harness()
        let preview = try await collect(h)
        let groups = [InsightCluster(id: "all", label: "All answers", members: [member(0), member(1)], score: 3)]
        try await h.insert([Item(kind: .text, z: "z", text: TextBoxItem(frame: Frame(x: 60, y: 300, w: 100, h: 20), text: RichText(plain: "Revised")))], page: page, doc: copies[1])
        let before = try copies.map { try h.snapshot($0) }
        do {
            try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": try JSONValue.from(groups),
                                                          "revisions": try JSONValue.from(preview.revisions), "applyScores": true])
            XCTFail("Stale grading must fail")
        } catch { XCTAssertEqual((error as? NibError)?.code, .conflict) }
        h.app.services.lock = FakeLockService(locked: [copies[1]])
        let locked = try await collect(h)
        XCTAssertEqual(locked.missing.count, 1)
        do {
            try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": try JSONValue.from(groups), "applyScores": true])
            XCTFail("Locked grading must fail")
        } catch { XCTAssertEqual((error as? NibError)?.code, .invalidParams) }
        XCTAssertEqual(try copies.map { try h.snapshot($0) }, before)
    }

    func testTextOnlySimilarityNeedsNoVisionAndNavigatorDoesNotWrap() async throws {
        let (h, _) = try await harness()
        let groups = [InsightCluster(id: "units", label: "Units", members: [member(0)]), InsightCluster(id: "method", label: "Method", members: [member(1)])]
        let ai = FakeAIService(responses: [.init(text: try JSONValue.from(["clusters": groups]).jsonString())])
        ai.supportsVision = false; h.app.services.ai = ai
        let result = try await h.run(CommandIDs.lessonCluster, ["zone": .string(zoneRef), "mode": "similarity"]).decode(LessonCluster.Output.self)
        XCTAssertEqual(result.clusters, groups)
        XCTAssertNil(ai.requests.first?.messages.first?.images)
        let copies = try await collect(h).copies
        let first = ClassNavigator(copies: copies, current: copies.first?.id)
        XCTAssertNil(first.previous)
        XCTAssertEqual(first.next?.id, copies.last?.id)
        XCTAssertNil(ClassNavigator(copies: copies, current: copies.last?.id).next)
        XCTAssertNil(ClassNavigator(copies: [], current: nil).next)
    }

    func testSavedModelAnswerAndPerWindowNavigatorIncludingPrivatePresentCopy() async throws {
        let (h, _) = try await harness()
        let groups = [InsightCluster(id: "exact", label: "Exact", members: [member(0), member(1)])]
        try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": [], "modelAnswer": "6 m/s"])
        try await h.run(CommandIDs.lessonSetClusters, ["zone": .string(zoneRef), "clusters": []])
        let retained = try await collect(h)
        XCTAssertEqual(retained.modelAnswer, "6 m/s", "Saving only clusters retains the teacher's model answer")
        let ai = FakeAIService(responses: [.init(text: try JSONValue.from(["clusters": groups]).jsonString())])
        ai.supportsVision = false; h.app.services.ai = ai
        try await h.run(CommandIDs.lessonCluster, ["zone": .string(zoneRef), "mode": "modelAnswer"])
        XCTAssertTrue(ai.requests.first?.messages.first?.text.contains("6 m/s") == true)
        let runtime = try XCTUnwrap(h.app.services.get(InsightRuntime.key, as: InsightRuntime.self))
        h.session.document = copies[0]
        _ = try await collect(h)
        XCTAssertEqual(runtime.navigator(h.session)?.current, NodeRef.document(copies[0]).description)
        let privateDoc: DocumentID = "PRIVATEINSIGHT01"
        runtime.rememberPrivate(NodeRef.document(privateDoc).description, copy: NodeRef.document(copies[0]).description, session: h.session)
        h.session.document = privateDoc
        XCTAssertEqual(runtime.navigator(h.session)?.current, NodeRef.document(copies[0]).description)
        let other = EditorSession()
        other.document = copies[0]
        XCTAssertNil(runtime.navigator(other), "Read results belong to the invoking window")
        let context = ChromeContext(app: h.app, session: h.session, kind: .notebook, isCompact: true)
        XCTAssertTrue(h.app.ui.visibleChromeOverlays(context).contains { $0.id == "teacherinsights.navigator" })
        h.session.document = Fixtures.docID
        XCTAssertNil(runtime.navigator(h.session))
    }

    func testReviewLayoutSnapshotsForLightDarkOpaqueContrastAndAccessibility() async throws {
        let (h, _) = try await harness()
        var collected = try await collect(h)
        collected.modelAnswer = "6 m/s"
        collected.clusters = [InsightCluster(id: "review", label: "Review units", members: [member(0)])]
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        let states: [(String, ColorScheme, DynamicTypeSize, Bool, UIAccessibilityContrast)] = [
            ("Light", .light, .large, false, .normal), ("Dark", .dark, .large, false, .normal),
            ("ReduceTransparency", .light, .large, true, .normal), ("IncreaseContrast", .light, .large, false, .high),
            ("AX3Compact", .light, .accessibility3, true, .high)
        ]
        // Hostless ImageRenderer substitutes native pickers/text fields. These attachments review the shared
        // sheet content's typography, spacing and accessibility reflow; native controls need an app-host capture.
        for (name, scheme, type, opaque, contrast) in states {
            let screen = SmartViewsPanel(context: context, initialCollection: collected, initialView: "question").reviewContent
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, type)
                .nibLiquidMode(opaque ? .off : .full)
                .frame(width: name == "AX3Compact" ? 390 : NibMetrics.settingsSheetSize.width,
                       height: NibMetrics.settingsSheetSize.height, alignment: .top)
                .clipped()
            let renderer = ImageRenderer(content: screen)
            renderer.scale = 1
            var image: UIImage?
            UITraitCollection(accessibilityContrast: contrast).performAsCurrent { image = renderer.uiImage }
            let rendered = try XCTUnwrap(image, name)
            let pixels = try XCTUnwrap(rendered.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 8, "\(name) must contain text and controls, not a blank surface")
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Class Insights \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCommandConformanceAndRegistryUIPaths() async {
        let problems = await CommandConformance.check(features: [FeatTeacherInsightsFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatTeacherInsightsFeature.self])
        XCTAssertNotNil(h.app.ui.panels.get(FeatTeacherInsightsFeature.panelID))
        XCTAssertEqual(Set(h.app.commands.all().filter { $0.owner == "teacherinsights" }.map(\.id)),
                       Set([CommandIDs.lessonCollect, CommandIDs.lessonCluster, CommandIDs.lessonSetClusters]))
    }
}
