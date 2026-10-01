import XCTest
import UIKit
import SwiftUI
import NibDesign
import NibContracts
import NibTesting
@testable import FeatAIChat

@MainActor
final class FeatAIChatTests: XCTestCase {
    func testRegistrationUsesAssistantPanelAndMenuContexts() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let panel = try XCTUnwrap(h.app.ui.panels.get(PanelIDs.assistant))
        XCTAssertTrue(panel.providesHeader)
        XCTAssertEqual(panel.placement, .floating)
        let item = try XCTUnwrap(h.app.ui.menus.all.first { $0.location == .block })
        let context = MenuContext(app: h.app, session: h.session, ref: "block:FIXTUREDOC02/FIXTUREBLK01")
        XCTAssertEqual(item.params(context)["scope"]?.stringValue, "block")
        XCTAssertEqual(item.params(context)["refs"]?.arrayValue, ["block:FIXTUREDOC02/FIXTUREBLK01"])
        let key = try XCTUnwrap(h.app.content.keyCommands.get("aichat.open"))
        XCTAssertEqual(key.shortcut, KeyShortcut("a", [.option, .command]))
        XCTAssertEqual(h.app.commands.descriptor(ChatCommand.send)?.owner, "aichat")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatAIChatFeature.self], owners: [FeatAIChatFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testPresenterRetainsFallbackAndIsOnlyInstalledForAI() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let shell = AutoConfirm()
        h.app.gateway.presenter = shell
        await FeatAIChatFeature.start(h.app)
        let runtime = try XCTUnwrap(h.app.services.get(ChatRuntime.serviceKey, as: ChatRuntime.self))
        XCTAssertTrue(h.app.gateway.presenter === shell)
        XCTAssertTrue(h.app.gateway.confirmationPresenter(for: .ai("test")) === runtime)
        XCTAssertTrue(h.app.gateway.confirmationPresenter(for: .bridge("test")) === shell)
        let descriptor = CommandDescriptor(id: "test.delete", title: "Delete", summary: "Delete an item.", effect: .edit, destructive: true)
        let decision = await runtime.confirm(ConfirmationRequest(principal: .ai("outside"), command: descriptor, params: [:]))
        if case .allow = decision {} else { XCTFail("outside turns must use the shell") }
        XCTAssertEqual(shell.requests.count, 1)
        XCTAssertTrue(runtime.fallback === shell)
    }

    func testAIPrincipalCannotApproveItsOwnConfirmation() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        do {
            _ = try await h.run(ChatCommand.confirm, ["request": "FIXTURECONF1", "decision": "allow"], as: .ai("test"))
            XCTFail("AI must not self-approve")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
    }

    func testAssistantWindowDoesNotUseSystemSingletonsInHostlessTests() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        await FeatAIChatFeature.start(h.app)
        XCTAssertNotNil(ChatRuntime.get(h.app).windowScenes)
        do {
            _ = try await h.run(ChatCommand.open, ["mode": "window"])
            XCTFail("hostless window activation must be unavailable")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
    }

    func testSidebarAndFloatingUseTheChromePlacementSetting() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let name = "chrome.panelPlacement." + PanelIDs.assistant
        h.app.settings.declarePrefix("chrome.panelPlacement.", synced: false, summary: "Test chrome placement.", owner: "test",
                                     schema: .str(choices: ["left", "right", "floating"]))
        var opened: [JSONValue] = []
        var closed = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelClose, title: "Close panel", summary: "Test panel host.", effect: .session)) { _, _ in
            closed += 1
            return [:]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open panel", summary: "Test panel host.", effect: .session)) { p, _ in
            opened.append(p)
            return [:]
        }
        _ = try await h.run(ChatCommand.open, ["mode": "sidebar"])
        let expected = h.app.settings.get(NibSettings.sidebarOnRight) ? "right" : "left"
        XCTAssertEqual(h.app.settings.json(name)?.stringValue, expected)
        _ = try await h.run(ChatCommand.open, ["mode": "floating"])
        XCTAssertEqual(h.app.settings.json(name)?.stringValue, "floating")
        h.session.openPanels.insert(PanelIDs.assistant)
        _ = try await h.run(ChatCommand.open)
        XCTAssertEqual(h.app.settings.json(name)?.stringValue, "floating")
        XCTAssertEqual(closed, 0)
        XCTAssertEqual(opened.last?["params"]?["scope"]?.stringValue, "document")
        XCTAssertEqual(opened.map { $0["id"]?.stringValue }, [PanelIDs.assistant, PanelIDs.assistant, PanelIDs.assistant])
    }

    func testCitationsValidateAndDeduplicateRefs() {
        let text = "See [page:FIXTUREDOC01/FIXTUREPG001] and item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01. Again page:FIXTUREDOC01/FIXTUREPG001. Ignore page:broken."
        XCTAssertEqual(ChatCitations.refs(in: text), ["page:FIXTUREDOC01/FIXTUREPG001", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
    }
    func testJPEGAttachmentKeepsItsMediaType() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService()
        let jpeg = try XCTUnwrap(UIImage(data: Fixtures.pngData)?.jpegData(compressionQuality: 0.8))
        let result = try await h.run(ChatCommand.attach, ["source": "image", "base64": .string(jpeg.base64EncodedString())])
        let ref = AssetRef(try XCTUnwrap(result["asset"]?.stringValue))
        XCTAssertEqual(URL(fileURLWithPath: ref.name).pathExtension, "jpg")
        let url = try XCTUnwrap(h.assets.temporaryURL(ref))
        XCTAssertEqual(try Data(contentsOf: url), jpeg)
    }

    func testCitationsHaveCachedHumanLabelsAndReadableParagraphs() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: "See page:FIXTUREDOC01/FIXTUREPG001 and item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01.")])
        let model = ChatRuntime.get(h.app).model(for: h.session)
        _ = try await model.send(prompt: "Cite", principal: .user, group: "CITE")
        let entry = try XCTUnwrap(model.entries.last)
        XCTAssertEqual(entry.citationLabels["page:FIXTUREDOC01/FIXTUREPG001"], "Page 1")
        XCTAssertEqual(entry.citationLabels["item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"], "Text on page 1")
        XCTAssertFalse(entry.displayText.contains("FIXTURE"))
        XCTAssertTrue(entry.displayText.contains("Page 1"))
    }

    func testInlineCanvasButtonRoutesExactContextAndPreviewFollowsZoom() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        var params: JSONValue = [:]
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open panel", summary: "Record host context.", effect: .session)) { p, ctx in
            params = p
            ctx.activeSession?.openPanels.insert(PanelIDs.assistant)
            return ["id": .string(PanelIDs.assistant), "placement": "floating"]
        }
        let host = FakeCanvasHost(h)
        let attachment = ChatInlineAttachment()
        attachment.attach(to: host)
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"
        let button = try XCTUnwrap(attachment.buttons[ref])
        XCTAssertGreaterThanOrEqual(button.view.frame.width, NibMetrics.hitTarget)
        XCTAssertGreaterThanOrEqual(button.view.frame.height, NibMetrics.hitTarget)
        _ = try await h.run(ChatCommand.askBlock, ["ref": .string(ref)])
        XCTAssertEqual(params["params"]?["refs"], [.string(ref)])
        XCTAssertEqual(params["params"]?["scope"], "selection")
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let proposal = ChatProposal(number: 1, command: "text.setText", params: ["text": "Preview"], title: "Revise text",
            changes: ChangeSummary(updated: [ref]), originals: [:], destructive: false, target: ref, previewText: "Preview", group: "PREVIEW")
        let before = try h.snapshotAll()
        model.proposals = [proposal]
        attachment.canvasDidChange(host)
        let first = try XCTUnwrap(attachment.marks[proposal.id]?.view.frame)
        host.zoomScale = 1.5
        attachment.canvasDidChange(host)
        let zoomed = try XCTUnwrap(attachment.marks[proposal.id]?.view.frame)
        XCTAssertEqual(zoomed.minX, first.minX * 1.5, accuracy: 0.1)
        XCTAssertEqual(zoomed.minY, first.minY * 1.5, accuracy: 0.1)
        XCTAssertEqual(try h.snapshotAll(), before)
        model.showsProposalsOnPage = false
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.marks.isEmpty)
        attachment.detach(from: host)
        XCTAssertTrue(attachment.buttons.isEmpty)
        XCTAssertTrue(host.overlayLayer.sublayers?.isEmpty ?? true)
    }

    func testPlacementSwitchRetainsConversationContextAndReopensHostOnBothSides() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.settings.declarePrefix("chrome.panelPlacement.", synced: false, summary: "Host placement.", owner: "chrome",
            schema: .str(choices: ["left", "right", "floating"]))
        var placements: [String] = []
        var received: [JSONValue] = []
        var closes = 0
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelClose, title: "Close", summary: "Close the active panel host.", effect: .session)) { _, ctx in
            ctx.activeSession?.openPanels.remove(PanelIDs.assistant); closes += 1; return ["closed": true]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open", summary: "Present the descriptor using chrome placement.", effect: .session)) { p, ctx in
            let placement = h.app.settings.json("chrome.panelPlacement." + PanelIDs.assistant)?.stringValue ?? "floating"
            placements.append(placement); received.append(p["params"] ?? [:])
            ctx.activeSession?.openPanels.insert(PanelIDs.assistant)
            return ["id": .string(PanelIDs.assistant), "placement": .string(placement)]
        }
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.chatID = "PLACEMENTCHAT"
        model.entries = [ChatEntry(id: "PLACEMENTMSG", role: "assistant", text: "Still here")]
        _ = try await h.run(ChatCommand.open, ["scope": "block", "refs": ["block:FIXTUREDOC02/FIXTUREBLK01"]])
        h.app.settings.set(NibSettings.sidebarOnRight, false)
        _ = try await h.run(ChatCommand.open, ["mode": "sidebar"])
        h.app.settings.set(NibSettings.sidebarOnRight, true)
        _ = try await h.run(ChatCommand.open, ["mode": "sidebar"])
        _ = try await h.run(ChatCommand.open, ["mode": "floating"])
        XCTAssertEqual(placements, ["floating", "left", "right", "floating"])
        XCTAssertEqual(closes, 3)
        XCTAssertTrue(received.allSatisfy { $0["scope"] == "block" && $0["refs"] == ["block:FIXTUREDOC02/FIXTUREBLK01"] })
        XCTAssertEqual(model.entries.last?.text, "Still here")
        XCTAssertEqual(model.chatID, "PLACEMENTCHAT")
    }

    func testPanelRendersAtPhoneSidebarFloatingAndWindowSizesInAllTextVariants() throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService()
        let model = ChatRuntime.get(h.app).model(for: h.session)
        model.entries = [ChatEntry(id: "LAYOUTMSG", role: "assistant", text: "Review this paragraph before accepting a change.")]
        let descriptor = try XCTUnwrap(h.app.ui.panels.get(PanelIDs.assistant))
        for (placement, size) in [(PanelPresentation.sheet, CGSize(width: 390, height: 844)),
                                  (.sidebar, CGSize(width: 344, height: 900)), (.floating, CGSize(width: 344, height: 560)),
                                  (.window, CGSize(width: 1024, height: 900))] {
            var context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
            context.presentation = placement
            for variant in NibSnapshot.Variant.allCases {
                let image = try XCTUnwrap(NibSnapshot.image(descriptor.makeView(context), size: size, variant: variant, scale: 1))
                XCTAssertEqual(image.size, size)
            }
        }
    }

    func testTextDocumentAccessoryPreservesEditorAndMapsEachVisibleBlock() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let editor = AccessoryTestEditor(session: h.session)
        h.app.ui.editors.register(DocumentEditorDescriptor(kind: .textDocument, owner: "textdoc") { _, _, _ in editor })
        await FeatAIChatFeature.start(h.app)
        let factory = try XCTUnwrap(h.app.ui.editors.get(DocumentKind.textDocument.rawValue))
        let wrapper = try XCTUnwrap(factory.make(Fixtures.textDocID, h.session, h.app) as? ChatBlockEditor)
        wrapper.loadViewIfNeeded()
        wrapper.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        wrapper.view.layoutIfNeeded()
        editor.table.frame = CGRect(x: 120, y: 0, width: 680, height: 768)
        editor.table.reloadData(); editor.table.layoutIfNeeded()
        wrapper.updateAccessories()
        XCTAssertEqual(wrapper.controls.count, 3)
        XCTAssertNotNil(wrapper.controls["block:FIXTUREDOC02/FIXTUREBLK01"])
        wrapper.reveal(block: Fixtures.paragraphBlockID, animated: false)
        XCTAssertEqual(editor.revealed, Fixtures.paragraphBlockID)
        wrapper.reloadAll()
        XCTAssertEqual(editor.reloads, 1)
        XCTAssertTrue(wrapper.wrapped === editor)
    }

}

@MainActor
private final class AccessoryTestEditor: UIViewController, DocumentEditing, UITableViewDataSource {
    let documentID = Fixtures.textDocID
    let session: EditorSession
    var canvasHost: CanvasHost? { nil }
    let table = UITableView()
    var revealed: NibID?
    var reloads = 0
    init(session: EditorSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() { super.viewDidLoad(); view.addSubview(table); table.dataSource = self; table.rowHeight = 80 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { UITableViewCell() }
    func reveal(page: PageID, rect: Rect?, animated: Bool) { revealed = page }
    func reveal(block: NibID, animated: Bool) { revealed = block }
    func reloadAll() { reloads += 1 }
}
