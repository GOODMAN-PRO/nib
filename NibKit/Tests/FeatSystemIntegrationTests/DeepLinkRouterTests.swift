import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatSystemIntegration

/// Stand-ins for the other features' commands a link runs: each records its params and returns a canned result.
@MainActor
final class CommandStubs {
    private(set) var calls: [(id: String, params: JSONValue, principal: Principal, group: String)] = []

    func stub(_ app: NibApp, _ id: String, effect: Effect = .session, extraScopes: Set<Scope> = [],
              result: JSONValue = [:]) {
        app.commands.register(CommandDescriptor(id: id, title: id, summary: "Test stand-in.", params: .anything(),
                                                examples: [[:]], effect: effect, extraScopes: extraScopes)) { [weak self] json, ctx in
            self?.calls.append((id, json, ctx.principal, ctx.group))
            return result
        }
    }

    func params(_ id: String) -> [JSONValue] { calls.filter { $0.id == id }.map { $0.params } }
    var ids: [String] { calls.map { $0.id } }
}

/// Records what a link would open when no Tabs & Windows feature is installed.
@MainActor
final class FakeNavigator: SceneNavigator {
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    var rootViewController: UIViewController? { nil }
    private(set) var opened: [(DocumentID, PageID?, OpenMode)] = []
    private(set) var presented: [UIViewController] = []

    init(session: EditorSession) { self.session = session }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        opened.append((doc, page, mode))
        activeDocument = doc
    }
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) { presented.append(viewController) }
}

@MainActor
final class FakeConfirmer: LinkConfirming {
    var answer = true
    private(set) var asked: [URL] = []
    func confirmPluginInstall(from url: URL, navigator: SceneNavigator?) async -> Bool {
        asked.append(url)
        return answer
    }
}

@MainActor
final class DeepLinkRouterTests: XCTestCase {

    // MARK: Parsing: every URL form

    func testOpenDocumentAndPage() throws {
        XCTAssertEqual(try DeepLinkParser.parse("nib://open/FIXTUREDOC01"),
                       .open(doc: "FIXTUREDOC01", page: nil, comment: nil))
        XCTAssertEqual(try DeepLinkParser.parse("nib://open/FIXTUREDOC01/FIXTUREPG002"),
                       .open(doc: "FIXTUREDOC01", page: "FIXTUREPG002", comment: nil))
        // Scheme and action are case-insensitive, stray whitespace and a trailing slash are tolerated.
        XCTAssertEqual(try DeepLinkParser.parse("  NIB://Open/FIXTUREDOC01/FIXTUREPG002/ \n"),
                       .open(doc: "FIXTUREDOC01", page: "FIXTUREPG002", comment: nil))
        // nib:open/… without the slashes, and a doc: ref in the path.
        XCTAssertEqual(try DeepLinkParser.parse("nib:open/doc:FIXTUREDOC01"),
                       .open(doc: "FIXTUREDOC01", page: nil, comment: nil))
    }

    func testOpenCommentLink() throws {
        XCTAssertEqual(try DeepLinkParser.parse("nib://open/FIXTUREDOC01/FIXTUREPG001?comment=FIXTURECMT01"),
                       .open(doc: "FIXTUREDOC01", page: "FIXTUREPG001", comment: "FIXTURECMT01"))
        XCTAssertEqual(try DeepLinkParser.parse("nib://open/FIXTUREDOC01/FIXTUREPG001?comment=item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01"),
                       .open(doc: "FIXTUREDOC01", page: "FIXTUREPG001", comment: "FIXTURECMT01"))
        assertInvalid("nib://open/FIXTUREDOC01?comment=FIXTURECMT01")    // a thread needs its page
        assertInvalid("nib://open")
        assertInvalid("nib://open/A/B/C")
        assertInvalid("nib://open/bad%20id")
    }

    func testAudioLinks() throws {
        XCTAssertEqual(try DeepLinkParser.parse("nib://audio/FIXTUREDOC01/FIXTUREAUD01?t=12"),
                       .audio(doc: "FIXTUREDOC01", clip: "FIXTUREAUD01", time: 12))
        XCTAssertEqual(try DeepLinkParser.parse("nib://audio/FIXTUREDOC01/FIXTUREAUD01"),
                       .audio(doc: "FIXTUREDOC01", clip: "FIXTUREAUD01", time: nil))
        XCTAssertEqual(try DeepLinkParser.parse("nib://audio/FIXTUREDOC01/FIXTUREAUD01?t=12.5"),
                       .audio(doc: "FIXTUREDOC01", clip: "FIXTUREAUD01", time: 12.5))
        XCTAssertEqual(DeepLinkParser.seconds("1:15"), 75)
        XCTAssertEqual(DeepLinkParser.seconds("0:01:15"), 75)
        XCTAssertEqual(DeepLinkParser.seconds("75s"), 75)
        XCTAssertNil(DeepLinkParser.seconds("-3"))
        XCTAssertNil(DeepLinkParser.seconds("nan"))
        XCTAssertNil(DeepLinkParser.seconds("1:x"))
        assertInvalid("nib://audio/FIXTUREDOC01/FIXTUREAUD01?t=-4")
        assertInvalid("nib://audio/FIXTUREDOC01")
    }

    func testQuickNoteNewAndSearch() throws {
        XCTAssertEqual(try DeepLinkParser.parse("nib://quicknote"), .quickNote)
        XCTAssertEqual(try DeepLinkParser.parse("nib://QuickNote"), .quickNote)
        XCTAssertEqual(try DeepLinkParser.parse("nib://new"), .new(kind: .notebook))
        for kind in DocumentKind.allCases {
            XCTAssertEqual(try DeepLinkParser.parse("nib://new?kind=\(kind.rawValue)"), .new(kind: kind))
        }
        XCTAssertEqual(try DeepLinkParser.parse("nib://new?kind=TEXTDOCUMENT"), .new(kind: .textDocument))
        assertInvalid("nib://new?kind=spreadsheet")
        XCTAssertEqual(try DeepLinkParser.parse("nib://search?q=simple%20harmonic%20%26%20motion"),
                       .search(query: "simple harmonic & motion"))
        XCTAssertEqual(try DeepLinkParser.parse("nib://search"), .search(query: ""))
    }

    func testPluginInstallAcceptsHTTPSOnly() throws {
        let link = try DeepLinkParser.parse("nib://plugin/install?url=https%3A%2F%2Fexample.com%2Fp%2Fdice.nibplugin")
        XCTAssertEqual(link, .pluginInstall(url: URL(string: "https://example.com/p/dice.nibplugin")!))
        assertInvalid("nib://plugin/install?url=http%3A%2F%2Fexample.com%2Fdice.nibplugin")
        assertInvalid("nib://plugin/install?url=file%3A%2F%2F%2Fprivate%2Fdice.nibplugin")
        assertInvalid("nib://plugin/install")
        assertInvalid("nib://plugin/remove?url=https%3A%2F%2Fexample.com%2Fdice.nibplugin")
    }

    func testPairingLinkWithPort() throws {
        let link = try DeepLinkParser.parse("nib://bridge/pair?host=100.101.102.103&port=8443&token=nib_4qVx9")
        guard case .bridgePair(let p) = link else { return XCTFail("not a pairing link: \(link)") }
        XCTAssertEqual(p.host, "100.101.102.103")
        XCTAssertEqual(p.port, 8443)
        XCTAssertEqual(p.token, "nib_4qVx9")
        // Parameters in any order.
        XCTAssertEqual(try DeepLinkParser.parse("nib://bridge/pair?token=nib_4qVx9&port=8443&host=100.101.102.103"), link)
    }

    func testPairingLinkWithoutPortDefaultsTo7331() throws {
        let link = try DeepLinkParser.parse("nib://bridge/pair?token=nib_4qVx9&host=ipad.tail1234.ts.net")
        guard case .bridgePair(let p) = link else { return XCTFail("not a pairing link: \(link)") }
        XCTAssertEqual(p.port, 7331)
        XCTAssertEqual(p.port, BridgePairing.defaultPort)
        XCTAssertEqual(p.host, "ipad.tail1234.ts.net")
        XCTAssertEqual(p.mcpURL, "http://ipad.tail1234.ts.net:7331/mcp")
    }

    func testPairingLinkValidation() throws {
        assertInvalid("nib://bridge/pair?host=10.0.0.2&port=0&token=t")
        assertInvalid("nib://bridge/pair?host=10.0.0.2&port=70000&token=t")
        assertInvalid("nib://bridge/pair?host=10.0.0.2&port=abc&token=t")
        assertInvalid("nib://bridge/pair?host=10.0.0.2")
        assertInvalid("nib://bridge/pair?token=t")
        assertInvalid("nib://bridge/pair?host=evil.com%2Fx&token=t")
        assertInvalid("nib://bridge/enable?host=10.0.0.2&token=t")
        // IPv6: bracketed in URLs, and the claude line quotes it (brackets are shell globs).
        guard case .bridgePair(let p) = try DeepLinkParser.parse("nib://bridge/pair?host=fd7a%3A%3A1&token=nib_x") else {
            return XCTFail("IPv6 host not accepted")
        }
        XCTAssertEqual(p.mcpURL, "http://[fd7a::1]:7331/mcp")
        XCTAssertTrue(p.claudeCommand(masked: false).contains("\"http://[fd7a::1]:7331/mcp\""))
    }

    func testImportHandOffAndRejections() throws {
        XCTAssertEqual(try DeepLinkParser.parse("nib://import?from=pasteboard"), .importPasteboard)
        assertInvalid("nib://import?from=files")
        assertInvalid("nib://import")
        assertInvalid("https://example.com/open/FIXTUREDOC01")
        assertInvalid("nib://launch-missiles")
        assertInvalid("")
        assertInvalid("not a link at all")
    }

    /// Every link Nib writes reads back as itself (quick actions, favourites.json and Copy Link rely on it).
    func testCanonicalLinksRoundTrip() throws {
        let links: [DeepLink] = [
            .open(doc: "FIXTUREDOC01", page: nil, comment: nil),
            .open(doc: "FIXTUREDOC01", page: "FIXTUREPG001", comment: "FIXTURECMT01"),
            .audio(doc: "FIXTUREDOC01", clip: "FIXTUREAUD01", time: 12),
            .audio(doc: "FIXTUREDOC01", clip: "FIXTUREAUD01", time: 90.25),
            .audio(doc: "FIXTUREDOC01", clip: "FIXTUREAUD01", time: nil),
            .quickNote,
            .new(kind: .studySet),
            .search(query: "a+b = c & d #1 / ü"),
            .pluginInstall(url: URL(string: "https://example.com/p/dice.nibplugin?v=2&x=1")!),
            .bridgePair(try BridgePairing(host: "fd7a::1", port: "7332", token: "nib_a+b/c=")),
            .importPasteboard,
        ]
        for link in links {
            XCTAssertEqual(try DeepLinkParser.parse(link.string), link, link.string)
        }
        XCTAssertEqual(DeepLink.audio(doc: "D", clip: "A", time: 12).string, "nib://audio/D/A?t=12")
        XCTAssertEqual(DeepLink.open(doc: "D", page: "P", comment: nil).string, "nib://open/D/P")
    }

    func testPairingSnippets() throws {
        let p = try BridgePairing(host: "100.101.102.103", port: nil, token: "nib_4qVx9SECRET")
        XCTAssertEqual(p.claudeCommand(masked: false),
                       "claude mcp add --transport http nib http://100.101.102.103:7331/mcp --header \"Authorization: Bearer nib_4qVx9SECRET\"")
        XCTAssertFalse(p.claudeCommand(masked: true).contains("SECRET"))
        XCTAssertTrue(p.maskedToken.hasPrefix("nib_"))
        let json = try JSONValue.parse(p.jsonConfig(masked: false))
        XCTAssertEqual(json["mcpServers"]?["nib"]?["url"], "http://100.101.102.103:7331/mcp")
        XCTAssertEqual(json["mcpServers"]?["nib"]?["headers"]?["Authorization"], "Bearer nib_4qVx9SECRET")
        XCTAssertFalse(p.jsonConfig(masked: true).contains("SECRET"))
        // The sheet reads its panel params flat or nested (PanelContext.params), with or without a port.
        XCTAssertEqual(BridgePairing(params: ["host": "10.0.0.2", "port": 9000, "token": "t0k"])?.port, 9000)
        XCTAssertEqual(BridgePairing(params: ["params": ["host": "10.0.0.2", "token": "t0k"]])?.port, 7331)
        XCTAssertNil(BridgePairing(params: ["host": "10.0.0.2"]))
    }

    // MARK: Routing

    func testOpenLinkOpensThePageAndTheCommentThread() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.docOpen)
        stubs.stub(h.app, CommandIDs.commentTapAt, result: ["handled": true])
        let r = try await h.run(CommandIDs.appOpenURL, ["url": "nib://open/FIXTUREDOC01/FIXTUREPG001?comment=FIXTURECMT01"])
        XCTAssertEqual(r["route"], "open")
        XCTAssertEqual(r["ref"], "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01")
        XCTAssertEqual(stubs.ids, [CommandIDs.docOpen, CommandIDs.commentTapAt])
        XCTAssertEqual(stubs.params(CommandIDs.docOpen).first, ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(stubs.params(CommandIDs.commentTapAt).first,
                       ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [0, 0],
                        "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURECMT01"])
        // Both steps are one undo group, the link's.
        XCTAssertEqual(Set(stubs.calls.map { $0.group }).count, 1)
    }

    func testCommentLinkWithoutTheCommentsFeatureStillOpensThePage() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.docOpen)
        let r = try await h.run(CommandIDs.appOpenURL, ["url": "nib://open/FIXTUREDOC01/FIXTUREPG001?comment=FIXTURECMT01"])
        XCTAssertEqual(r["route"], "open")
        XCTAssertEqual(stubs.ids, [CommandIDs.docOpen])
    }

    func testOpenLinkWithoutTheWindowsFeatureUsesTheNavigator() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let navigator = FakeNavigator(session: h.session)
        h.app.ui.activeNavigator = navigator
        _ = try await h.run(CommandIDs.appOpenURL, ["url": "nib://open/FIXTUREDOC04/FIXTUREBRD01"])
        XCTAssertEqual(navigator.opened.count, 1)
        XCTAssertEqual(navigator.opened.first?.0, Fixtures.whiteboardID)
        XCTAssertEqual(navigator.opened.first?.1, Fixtures.boardID)
    }

    func testLinksToMissingOrTrashedDocumentsAreNotFound() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.docOpen)
        await assertCode(.notFound) { try await h.run(CommandIDs.appOpenURL, ["url": "nib://open/NOSUCHDOC001"]) }
        try h.library.trash(Fixtures.textDocID)
        await assertCode(.notFound) { try await h.run(CommandIDs.appOpenURL, ["url": "nib://open/FIXTUREDOC02"]) }
        await assertCode(.notFound) {
            try await h.run(CommandIDs.appOpenURL, ["url": "nib://audio/FIXTUREDOC01/NOSUCHCLIP01?t=3"])
        }
        await assertCode(.invalidParams) { try await h.run(CommandIDs.appOpenURL, ["url": "https://example.com"]) }
        XCTAssertTrue(stubs.calls.isEmpty)
    }

    func testAudioLinkOpensWhereTheRecordingStartedAndPlaysAtT() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.docOpen)
        stubs.stub(h.app, CommandIDs.audioPlay, result: ["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 42, "playing": true])
        let r = try await h.run(CommandIDs.appOpenURL, ["url": "nib://audio/FIXTUREDOC01/FIXTUREAUD01?t=42"])
        XCTAssertEqual(r["route"], "audio")
        XCTAssertEqual(r["result"]?["playing"], true)
        XCTAssertEqual(stubs.params(CommandIDs.docOpen).first, ["doc": "doc:FIXTUREDOC01", "page": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(stubs.params(CommandIDs.audioPlay).first, ["clip": "audio:FIXTUREDOC01/FIXTUREAUD01", "t": 42])
    }

    func testQuickNoteNewAndSearchLinks() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.docQuickNote, effect: .library, result: ["ref": "doc:QUICKNOTE001"])
        stubs.stub(h.app, CommandIDs.docCreate, effect: .library, result: ["ref": "doc:NEWBOARD0001", "title": "Untitled"])
        stubs.stub(h.app, CommandIDs.docOpen)
        stubs.stub(h.app, CommandIDs.searchOpen)

        var r = try await h.run(CommandIDs.appOpenURL, ["url": "nib://quicknote"])
        XCTAssertEqual(r["ref"], "doc:QUICKNOTE001")

        r = try await h.run(CommandIDs.appOpenURL, ["url": "nib://new?kind=whiteboard"])
        XCTAssertEqual(r["ref"], "doc:NEWBOARD0001")
        XCTAssertEqual(stubs.params(CommandIDs.docCreate).first, ["kind": "whiteboard"])
        XCTAssertEqual(stubs.params(CommandIDs.docOpen).last, ["doc": "doc:NEWBOARD0001"])

        _ = try await h.run(CommandIDs.appOpenURL, ["url": "nib://search?q=%20velocity%20"])
        _ = try await h.run(CommandIDs.appOpenURL, ["url": "nib://search"])
        XCTAssertEqual(stubs.params(CommandIDs.searchOpen), [["scope": "library", "query": "velocity"], ["scope": "library"]])
    }

    func testPluginInstallLinkIsAlwaysConfirmed() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.pluginInstall, effect: .library, extraScopes: [.pluginsManage], result: ["id": "dev.dice"])
        let confirmer = FakeConfirmer()
        try XCTUnwrap(SystemRuntime.shared(h.app.services)).confirmer = confirmer
        let url = "nib://plugin/install?url=https%3A%2F%2Fexample.com%2Fdice.nibplugin"

        // The person declines: nothing is installed.
        confirmer.answer = false
        var r = try await h.run(CommandIDs.appOpenURL, ["url": .string(url)])
        XCTAssertEqual(r["cancelled"], true)
        XCTAssertTrue(stubs.calls.isEmpty)

        // The person agrees: plugin.install runs with the https address.
        confirmer.answer = true
        r = try await h.run(CommandIDs.appOpenURL, ["url": .string(url)])
        XCTAssertEqual(r["ref"], "dev.dice")
        XCTAssertEqual(stubs.params(CommandIDs.pluginInstall), [["url": "https://example.com/dice.nibplugin"]])
        XCTAssertEqual(confirmer.asked.count, 2)

        // The AI or the bridge: the gateway confirms plugin.install (plugins:manage is always confirmed).
        let before = h.confirmer.requests.count
        _ = try await h.run(CommandIDs.appOpenURL, ["url": .string(url)], as: .ai("chat1"))
        XCTAssertEqual(h.confirmer.requests.count, before + 1)
        XCTAssertEqual(h.confirmer.requests.last?.command.id, CommandIDs.pluginInstall)
        h.confirmer.decision = .deny
        await assertCode(.userDenied) { try await h.run(CommandIDs.appOpenURL, ["url": .string(url)], as: .bridge("pc")) }
        XCTAssertEqual(stubs.params(CommandIDs.pluginInstall).count, 2)
    }

    func testPairingLinkShowsTheSheetAndNeverEnablesTheBridge() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.panelOpen, result: ["id": .string(SystemIDs.pairingPanel), "placement": "sheet"])
        stubs.stub(h.app, "bridge.setEnabled")
        let enabledBefore = h.app.settings.json(BridgeNames.enabledSetting)

        _ = try await h.run(CommandIDs.appOpenURL, ["url": "nib://bridge/pair?host=10.0.0.2&token=nib_tok"])
        _ = try await h.run(CommandIDs.appOpenURL, ["url": "nib://bridge/pair?token=nib_tok&port=8080&host=10.0.0.2"])

        XCTAssertEqual(stubs.params(CommandIDs.panelOpen),
                       [["id": .string(SystemIDs.pairingPanel), "host": "10.0.0.2", "port": 7331, "token": "nib_tok"],
                        ["id": .string(SystemIDs.pairingPanel), "host": "10.0.0.2", "port": 8080, "token": "nib_tok"]])
        XCTAssertTrue(stubs.params("bridge.setEnabled").isEmpty)
        XCTAssertEqual(h.app.settings.json(BridgeNames.enabledSetting), enabledBefore)
        // Only the person opens a pairing sheet.
        await assertCode(.permissionDenied) {
            try await h.run(CommandIDs.appOpenURL, ["url": "nib://bridge/pair?host=10.0.0.2&token=nib_tok"], as: .ai("chat"))
        }
        XCTAssertEqual(stubs.params(CommandIDs.panelOpen).count, 2)
        // The sheet is a registered .sheet panel, so the chrome or the library presents it.
        let panel = try XCTUnwrap(h.app.ui.panels.get(SystemIDs.pairingPanel))
        XCTAssertEqual(panel.placement, .sheet)
        XCTAssertEqual(panel.owner, FeatSystemIntegrationFeature.id)
    }

    func testPasteboardHandOffIsTheUsersOnly() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        stubs.stub(h.app, CommandIDs.importFiles, effect: .library, result: ["refs": ["doc:IMPORTED0001"]])
        let r = try await h.run(CommandIDs.appOpenURL, ["url": "nib://import?from=pasteboard"])
        XCTAssertEqual(r["ref"], "doc:IMPORTED0001")
        XCTAssertEqual(stubs.params(CommandIDs.importFiles), [["urls": ["nib://import?from=pasteboard"]]])
        await assertCode(.permissionDenied) {
            try await h.run(CommandIDs.appOpenURL, ["url": "nib://import?from=pasteboard"], as: .bridge("pc"))
        }
        XCTAssertEqual(stubs.params(CommandIDs.importFiles).count, 1)
    }

    /// AI previews (dry runs) check the link but open, install and show nothing.
    func testDryRunChecksWithoutActing() async throws {
        let h = Harness(features: [FeatSystemIntegrationFeature.self])
        let stubs = CommandStubs()
        for id in [CommandIDs.docOpen, CommandIDs.audioPlay, CommandIDs.panelOpen, CommandIDs.searchOpen] { stubs.stub(h.app, id) }
        for url in ["nib://open/FIXTUREDOC01/FIXTUREPG002", "nib://audio/FIXTUREDOC01/FIXTUREAUD01?t=3",
                    "nib://quicknote", "nib://search?q=x"] {
            let r = try await h.app.bus.execute(Invocation(command: CommandIDs.appOpenURL, params: ["url": .string(url)],
                                                           principal: .ai("chat"), session: h.session, dryRun: true))
            XCTAssertNotNil(r.value["route"]?.stringValue, url)
        }
        XCTAssertTrue(stubs.calls.isEmpty)
        await assertCode(.notFound) {
            try await h.app.bus.execute(Invocation(command: CommandIDs.appOpenURL, params: ["url": "nib://open/NOSUCHDOC001"],
                                                   principal: .ai("chat"), session: h.session, dryRun: true))
        }
    }

    // MARK: Helpers

    private func assertInvalid(_ link: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DeepLinkParser.parse(link), link, file: file, line: line) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams, link, file: file, line: line)
        }
    }

    private func assertCode(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                            _ body: () async throws -> Any) async {
        do {
            _ = try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch {
            XCTAssertEqual(NibError.wrap(error).code, code, "\(error)", file: file, line: line)
        }
    }
}
