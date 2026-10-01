import XCTest
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
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelOpen, title: "Open panel", summary: "Test panel host.", effect: .session)) { p, _ in
            opened.append(p)
            return [:]
        }
        _ = try await h.run(ChatCommand.open, ["mode": "sidebar"])
        let expected = h.app.settings.get(NibSettings.sidebarOnRight) ? "right" : "left"
        XCTAssertEqual(h.app.settings.json(name)?.stringValue, expected)
        _ = try await h.run(ChatCommand.open, ["mode": "floating"])
        XCTAssertEqual(h.app.settings.json(name)?.stringValue, "floating")
        XCTAssertEqual(opened.map { $0["id"]?.stringValue }, [PanelIDs.assistant, PanelIDs.assistant])
    }

    func testCitationsValidateAndDeduplicateRefs() {
        let text = "See [page:FIXTUREDOC01/FIXTUREPG001] and item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01. Again page:FIXTUREDOC01/FIXTUREPG001. Ignore page:broken."
        XCTAssertEqual(ChatCitations.refs(in: text), ["page:FIXTUREDOC01/FIXTUREPG001", "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"])
    }
}
