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
        h.app.services.ai = FakeAIService()
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
        XCTAssertTrue(attachment.buttons.isEmpty, "Reading a page must not reveal block handles.")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID])
        attachment.canvasDidChange(host)
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

    func testCanvasHandleRequiresProviderAndSelectionAndTracksFirstLine() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let host = FakeCanvasHost(h)
        let window = UIWindow(frame: host.canvasView.bounds)
        let root = UIViewController()
        root.view = host.canvasView
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let attachment = ChatInlineAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let item = try XCTUnwrap(h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).first { $0.id == Fixtures.textID })
        let layout = try XCTUnwrap(h.app.content.textLayout(for: item))
        let ref = NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description
        XCTAssertTrue(attachment.buttons.isEmpty)
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [item.id])
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "A selection without an AI service must not show a button.")
        let ai = FakeAIService()
        ai.isConfigured = false
        h.app.services.ai = ai
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "An unconfigured provider must not show a button.")

        ai.isConfigured = true
        attachment.canvasDidChange(host)
        XCTAssertEqual(Set(attachment.buttons.keys), [ref])
        let controller = try XCTUnwrap(attachment.buttons[ref])
        let frame = controller.view.frame
        // The fixture has a comment in the trailing margin. The selected item's control must avoid it.
        for occupied in try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1) {
            let bounds = occupied.bounds
            let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
            XCTAssertFalse(rect.insetBy(dx: -NibSpacing.s, dy: -NibSpacing.s).intersects(frame))
        }
        let lineHeight = RichTextBridge.font(item.text?.text.paragraphs.first?.runs.first?.attrs ?? TextAttributes(), base: layout.base).lineHeight
        XCTAssertEqual(frame.midY, CGFloat(layout.container.y) + lineHeight / 2, accuracy: 1)
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.view.layoutIfNeeded()
        func findButton(_ view: UIView) -> UIButton? {
            if let button = view as? UIButton { return button }
            return view.subviews.compactMap(findButton).first
        }
        let button = try XCTUnwrap(findButton(controller.view))
        let foreground = try XCTUnwrap(button.configuration?.baseForegroundColor)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertEqual(foreground.resolvedColor(with: traits), NibUIColor.accent.resolvedColor(with: traits))
        }
        host.zoomScale = 1.5
        attachment.canvasDidChange(host)
        let zoomed = try XCTUnwrap(attachment.buttons[ref]?.view.frame)
        XCTAssertEqual(zoomed.midY, frame.midY * 1.5, accuracy: 0.1)
        XCTAssertEqual(zoomed.height, NibMetrics.hitTarget)
        ai.isConfigured = false
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "Removing provider configuration must remove the tappable view.")
        XCTAssertNil(controller.view.superview)
        ai.isConfigured = true
        h.session.selection = Selection()
        h.session.isEditingText = true
        h.session.editingTextRef = ref
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "Focus alone must not reveal canvas AI marks.")
        let hover = CanvasSample(page: Fixtures.page1, location: Point(item.bounds.midX, item.bounds.midY), isPencil: false)
        attachment.hover(hover, host: host)
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "Hover alone must not reveal canvas AI marks.")
        h.session.isEditingText = false
        h.session.editingTextRef = nil
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page2, items: [item.id])
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "Selection must belong to this page.")
        h.session.selection = Selection(doc: Fixtures.textDocID, page: Fixtures.page1, items: [item.id])
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty, "Selection must belong to this document.")
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [item.id])
        attachment.canvasDidChange(host)
        XCTAssertEqual(Set(attachment.buttons.keys), [ref])
        h.session.selection = Selection()
        attachment.canvasDidChange(host)
        XCTAssertTrue(attachment.buttons.isEmpty)
    }

    func testSelectedCanvasHandlesNeverOverlapAtOrBelow44Points() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        h.app.services.ai = FakeAIService()
        let firstID = NibID.make()
        let secondID = NibID.make()
        let template = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
        h.app.commands.register(CommandDescriptor(id: "test.spaceText", title: "Space text", summary: "Place selected text items.", effect: .edit)) { p, ctx in
            let gap = p["gap"]?.doubleValue ?? 28
            let z = FractionalIndex.sequence(after: nil, count: 2)
            try ctx.mutate { tx in
                for (index, id) in [firstID, secondID].enumerated() {
                    var item = template
                    item.id = id
                    item.z = z[index]
                    item.text?.frame = Frame(x: 72, y: 400 + Double(index) * gap, w: 300, h: 40)
                    try tx.put(item, doc: Fixtures.docID, page: Fixtures.page2)
                }
            }
            return [:]
        }
        let host = FakeCanvasHost(h)
        host.canvasView.frame.size.height = 2400
        let attachment = ChatInlineAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        h.session.selection = Selection(doc: Fixtures.docID, page: Fixtures.page2, items: [firstID, secondID])
        for gap in [28.0, 44.0, 45.0] {
            _ = try await h.run("test.spaceText", ["gap": .number(gap)])
            attachment.canvasDidChange(host)
            XCTAssertEqual(attachment.buttons.count, gap <= 44 ? 1 : 2, "Gap: \(gap)")
            let frames = attachment.buttons.values.map { $0.view.frame }
            for frame in frames {
                XCTAssertEqual(frame.width, NibMetrics.hitTarget)
                XCTAssertEqual(frame.height, NibMetrics.hitTarget)
            }
            if frames.count == 2 {
                XCTAssertFalse(frames[0].intersects(frames[1]))
                XCTAssertGreaterThan(abs(frames[0].midY - frames[1].midY), NibMetrics.hitTarget)
            }
        }
        host.zoomScale = 0.5
        attachment.canvasDidChange(host)
        XCTAssertEqual(attachment.buttons.count, 1, "Spacing must be checked in view points after zoom.")
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

    func testTextDocumentPreviewPreservesEditorWithoutDuplicatingBlockButtons() async throws {
        let h = Harness(features: [FeatAIChatFeature.self])
        let blocks = try h.app.workspace.content(Fixtures.textDocID).liveBlocks
        let refs = blocks.map { NodeRef.block(Fixtures.textDocID, $0.id).description }
        let editor = AccessoryTestEditor(session: h.session, blockCount: blocks.count)
        XCTAssertTrue(h.session.editor === editor)
        h.app.ui.editors.register(DocumentEditorDescriptor(kind: .textDocument, owner: "textdoc") { _, _, _ in editor })
        await FeatAIChatFeature.start(h.app)
        let factory = try XCTUnwrap(h.app.ui.editors.get(DocumentKind.textDocument.rawValue))
        let wrapper = try XCTUnwrap(factory.make(Fixtures.textDocID, h.session, h.app) as? ChatBlockEditor)
        wrapper.loadViewIfNeeded()
        wrapper.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        wrapper.view.layoutIfNeeded()
        editor.collection.frame = CGRect(x: 120, y: 0, width: 680, height: 768)
        editor.collection.reloadData(); editor.collection.layoutIfNeeded()
        wrapper.beginAppearanceTransition(true, animated: false)
        wrapper.endAppearanceTransition()
        XCTAssertTrue(h.session.editor === editor)
        XCTAssertTrue(wrapper.forwardedEditor === editor)
        wrapper.updateAccessories()
        func hasDuplicateAIButton(_ view: UIView) -> Bool {
            if view.accessibilityIdentifier?.hasPrefix("aichat.block.") == true { return true }
            return view.subviews.contains(where: hasDuplicateAIButton)
        }
        for configured in [false, true] {
            let ai = FakeAIService()
            ai.isConfigured = configured
            h.app.services.ai = ai
            for cell in editor.collection.visibleCells {
                let index = try XCTUnwrap(editor.collection.indexPath(for: cell))
                h.session.isEditingText = true
                h.session.editingTextRef = refs[index.item]
                editor.collection.selectItem(at: index, animated: false, scrollPosition: [])
                wrapper.updateAccessories()
                XCTAssertFalse(hasDuplicateAIButton(wrapper.view), "F047 must own the only per-block AI control.")
                XCTAssertEqual(wrapper.children.count, 1, "F085 must not add a button controller per row.")
                editor.collection.deselectItem(at: index, animated: false)
            }
        }
        h.session.isEditingText = false
        h.session.editingTextRef = nil
        wrapper.updateAccessories()
        XCTAssertFalse(hasDuplicateAIButton(wrapper.view))

        let target = NodeRef.block(Fixtures.textDocID, Fixtures.paragraphBlockID).description
        let model = ChatRuntime.get(h.app).model(for: h.session)
        let proposal = ChatProposal(number: 1, command: CommandIDs.blockUpdate, params: ["ref": .string(target), "text": "Preview"],
            title: "Revise block", changes: ChangeSummary(updated: [target]), originals: [:], destructive: false,
            target: target, previewText: "Preview", group: "BLOCKPREVIEW")
        let before = try h.snapshotAll()
        model.proposals = [proposal]
        wrapper.updateAccessories()
        let mark = try XCTUnwrap(wrapper.previews[proposal.id])
        let blockIndex = try XCTUnwrap(refs.firstIndex(of: target))
        let cell = try XCTUnwrap(editor.collection.cellForItem(at: IndexPath(item: blockIndex, section: 0)))
        XCTAssertEqual(mark.view.frame.minY, cell.convert(cell.bounds, to: wrapper.view).maxY, accuracy: 0.1)
        XCTAssertEqual(try h.snapshotAll(), before)
        model.showsProposalsOnPage = false
        wrapper.updateAccessories()
        XCTAssertTrue(wrapper.previews.isEmpty)
        model.showsProposalsOnPage = true
        model.proposals[0].included = false
        wrapper.updateAccessories()
        XCTAssertTrue(wrapper.previews.isEmpty)

        wrapper.reveal(block: Fixtures.paragraphBlockID, animated: false)
        XCTAssertEqual(editor.revealed, Fixtures.paragraphBlockID)
        wrapper.reloadAll()
        XCTAssertEqual(editor.reloads, 1)
        XCTAssertTrue(wrapper.wrapped === editor)
        XCTAssertTrue(h.session.editor === editor)
    }

}

@MainActor
private final class AccessoryTestEditor: UIViewController, DocumentEditing, UICollectionViewDataSource {
    let documentID = Fixtures.textDocID
    let session: EditorSession
    var canvasHost: CanvasHost? { nil }
    let collection: UICollectionView
    let blockCount: Int
    var revealed: NibID?
    var reloads = 0
    init(session: EditorSession, blockCount: Int) {
        self.session = session
        self.blockCount = blockCount
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 680, height: 80)
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        session.editor = self
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collection)
        collection.dataSource = self
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "block")
    }
    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { blockCount }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "block", for: indexPath)
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        let textView = UITextView(frame: cell.contentView.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.textContainerInset = UIEdgeInsets(top: NibSpacing.s, left: 0, bottom: 0, right: 0)
        let font = indexPath.item == 0 ? NibUIFont.documentHeading(1) : NibUIFont.documentBody
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = indexPath.item == 0 ? NibMetrics.hitTarget : NibMetrics.hitTarget / 2
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        textView.attributedText = NSAttributedString(string: "First line\nSecond line", attributes: [.font: font, .paragraphStyle: paragraph])
        cell.contentView.addSubview(textView)
        return cell
    }
    func reveal(page: PageID, rect: Rect?, animated: Bool) { revealed = page }
    func reveal(block: NibID, animated: Bool) { revealed = block }
    func reloadAll() { reloads += 1 }
}
