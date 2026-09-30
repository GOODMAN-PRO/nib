import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatAbout

// MARK: - Fakes

/// A throwaway app container: Documents, Library (Caches, Application Support, WebKit, Preferences), tmp and one
/// App Group container, all under a fresh temporary folder.
struct TempContainer {
    let root: URL
    let locations: AppDataLocations

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("about-tests-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        locations = AppDataLocations(
            container: root, documents: root.appendingPathComponent("Documents", isDirectory: true), library: library,
            caches: library.appendingPathComponent("Caches", isDirectory: true),
            applicationSupport: library.appendingPathComponent("Application Support", isDirectory: true),
            temporary: root.appendingPathComponent("tmp", isDirectory: true),
            appGroups: [root.appendingPathComponent("Group", isDirectory: true)], appGroupIDs: ["group.app.nib.tests"])
        for dir in [locations.documents, locations.caches, locations.applicationSupport, locations.temporary] + locations.appGroups {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func write(_ relative: String) {
        write(url(relative))
    }

    func write(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url)
    }

    func makeDirectory(_ relative: String) {
        try? FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
}

@MainActor
final class RecordingWiper: SystemDataWiping {
    private(set) var calls = 0
    private(set) var groups: [[String]] = []

    func wipe(appGroupIDs: [String]) async -> [String] {
        calls += 1
        groups.append(appGroupIDs)
        return []
    }
}

@MainActor
final class ScriptedPrompter: DeletionPrompting {
    var answers: [Bool]
    private(set) var prompts: [DeletionPrompt] = []
    private(set) var finish: DeletionFinish?
    private(set) var close: (@MainActor () async -> Void)?

    init(answers: [Bool]) {
        self.answers = answers
    }

    /// True makes every confirmation fail to show (no window could present it).
    var unshown = false

    func confirm(_ prompt: DeletionPrompt) async -> DeletionAnswer {
        prompts.append(prompt)
        if unshown { return .notShown }
        return (answers.isEmpty ? false : answers.removeFirst()) ? .confirmed : .declined
    }

    func showFinished(_ finish: DeletionFinish, close: @escaping @MainActor () async -> Void) {
        self.finish = finish
        self.close = close
    }
}

final class Flag {
    var value = false
}

final class DictionarySyncedBackend: SyncedSettingsBackend {
    var values: [String: JSONValue] = [:]
    func value(_ name: String) -> JSONValue? { values[name] }
    func setValue(_ name: String, _ value: JSONValue?) { values[name] = value }
    func names() -> [String] { Array(values.keys) }
}

@MainActor
final class FakeProviderStore: AIProviderStore {
    var configs: [AIProviderConfig]
    var activeID: UUID?
    /// What `provider(nil)` resolves when no id is active (a store may fall back to its only provider).
    var fallback: AIProviderConfig?

    init(_ configs: [AIProviderConfig], active: UUID?, fallback: AIProviderConfig? = nil) {
        self.configs = configs
        self.activeID = active
        self.fallback = fallback
    }

    func save(_ config: AIProviderConfig, apiKey: String?) throws {}
    func delete(_ id: UUID) {}
    func provider(_ id: UUID?) -> AIProvider? {
        guard let config = configs.first(where: { $0.id == (id ?? activeID) }) ?? (id == nil ? fallback : nil) else { return nil }
        return SilentProvider(config: config)
    }
}

/// A provider that is never called (the privacy page only reads its config).
final class SilentProvider: AIProvider {
    let config: AIProviderConfig
    init(config: AIProviderConfig) { self.config = config }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func listModels() async throws -> [String] { [] }
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { [] }
    func generateImage(prompt: String) async throws -> Data { throw NibError(.unsupported, "no images") }
}

/// The deletion service of one test: a temporary container, scripted answers, a recording system wiper.
@MainActor
final class DeletionRig {
    let container: TempContainer
    let prompter: ScriptedPrompter?
    let wiper = RecordingWiper()
    let terminated = Flag()

    init(_ h: Harness, answers: [Bool]? = [true, true]) throws {
        container = try TempContainer()
        prompter = answers.map { ScriptedPrompter(answers: $0) }
        let prompter = self.prompter
        let locations = container.locations
        let flag = terminated
        let service = DataDeletionService(locations: { locations }, system: wiper, deviceModel: "iPad",
                                          makePrompter: { _ in prompter }, terminate: { flag.value = true })
        h.app.services.set(service, for: DataDeletionService.key)
    }
}

// MARK: - Tests

@MainActor
final class FeatAboutTests: XCTestCase {

    // MARK: Registration

    func testRegistersAboutPanelSettingsPagesAndCommand() {
        let h = Harness(features: [FeatAboutFeature.self])
        XCTAssertEqual(FeatAboutFeature.id, "about")

        let panel = h.app.ui.panels.get(PanelIDs.about)
        XCTAssertNotNil(panel, "the app menu's About Nib opens PanelIDs.about")
        XCTAssertEqual(panel?.placement, .sheet)
        XCTAssertEqual(panel?.providesHeader, true)
        XCTAssertEqual(panel?.owner, "about")

        let pages = h.app.ui.settingsPages.all.filter { $0.owner == "about" }
        XCTAssertEqual(Set(pages.map { $0.id }), [AboutIDs.aboutPage, AboutIDs.privacyPage, AboutIDs.parityPage])
        XCTAssertTrue(pages.allSatisfy { $0.section == .about && !$0.keywords.isEmpty })
        XCTAssertTrue(h.app.ui.settingsPages.get(AboutIDs.privacyPage)?.keywords.contains("delete account") ?? false)

        let d = h.app.commands.descriptor(CommandIDs.appDeleteAllData)
        XCTAssertEqual(d?.id, "app.deleteAllData")
        XCTAssertEqual(d?.effect, .irreversible)
        XCTAssertEqual(d?.userPresence, true)
        XCTAssertEqual(d?.destructive, true)
        XCTAssertEqual(d?.target, .app)
        XCTAssertEqual(d?.owner, "about")
        XCTAssertNotNil(DataDeletionService.resolve(h.app.services))
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatAboutFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: app.deleteAllData

    func testDeleteAllDataAsksTwiceErasesAndClosesNib() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let rig = try DeletionRig(h)
        let c = rig.container
        h.app.settings.set(NibSettings.authorName, "Ada")
        h.app.settings.set(NibSettings.hideStatusBar, true)
        c.write("Library/Application Support/ai-providers.json")
        c.write("Library/Application Support/Nib/device-id")
        c.write("Library/Caches/index.sqlite")

        let value = try await h.run(CommandIDs.appDeleteAllData, ["includeLibrary": false])
        let out = try value.decode(DeleteAllDataCommand.Output.self)

        XCTAssertTrue(out.deleted)
        XCTAssertFalse(out.dryRun)
        XCTAssertTrue(out.restartRequired)
        XCTAssertEqual(out.documents, 0, "the library stays")
        XCTAssertEqual(out.failures, [])
        XCTAssertEqual(rig.prompter?.prompts.map { $0.step }, [.overview, .final])
        XCTAssertEqual(rig.prompter?.prompts.map { $0.isDestructive }, [false, true])
        XCTAssertEqual(h.app.settings.get(NibSettings.authorName), "", "device settings go back to their defaults")
        XCTAssertFalse(h.app.settings.get(NibSettings.hideStatusBar))
        XCTAssertFalse(c.exists("Library/Application Support/ai-providers.json"))
        XCTAssertFalse(c.exists("Library/Caches/index.sqlite"))
        XCTAssertTrue(c.exists("Library/Application Support/Nib/device-id"), "the library keeps syncing as this device")
        XCTAssertEqual(rig.wiper.calls, 1)
        XCTAssertEqual(rig.wiper.groups.first, ["group.app.nib.tests"])

        let finish = try XCTUnwrap(rig.prompter?.finish)
        XCTAssertFalse(finish.subject.includeLibrary)
        XCTAssertNil(finish.failureMessage)
        XCTAssertFalse(rig.terminated.value, "Nib closes only when the person asks")
        c.write("Library/Caches/written-after.bin")
        await rig.prompter?.close?()
        XCTAssertFalse(c.exists("Library/Caches/written-after.bin"), "Close Nib erases once more")
        XCTAssertEqual(rig.wiper.calls, 2)
        XCTAssertTrue(rig.terminated.value)
    }

    func testDecliningEitherStepKeepsEverything() async throws {
        for answers in [[false], [true, false]] {
            let h = Harness(features: [FeatAboutFeature.self])
            let rig = try DeletionRig(h, answers: answers)
            h.app.settings.set(NibSettings.authorName, "Ada")
            rig.container.write("Library/Application Support/ai-providers.json")

            do {
                try await h.run(CommandIDs.appDeleteAllData, [:])
                XCTFail("declining must not delete")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .userDenied)
            }
            XCTAssertEqual(rig.prompter?.prompts.count, answers.count)
            XCTAssertEqual(h.app.settings.get(NibSettings.authorName), "Ada")
            XCTAssertTrue(rig.container.exists("Library/Application Support/ai-providers.json"))
            XCTAssertEqual(rig.wiper.calls, 0)
            XCTAssertNil(rig.prompter?.finish)
        }
    }

    func testAssistantAndBridgeAreConfirmedByTheGatewayAndThenByThePerson() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let rig = try DeletionRig(h)
        try await h.run(CommandIDs.appDeleteAllData, [:], as: .ai("chat-1"))
        XCTAssertEqual(h.confirmer.requests.map { $0.command.id }, ["app.deleteAllData"])
        XCTAssertEqual(rig.prompter?.prompts.count, 2, "the person still confirms twice on the device")

        let denied = Harness(features: [FeatAboutFeature.self])
        let deniedRig = try DeletionRig(denied)
        denied.confirmer.decision = .deny
        do {
            try await denied.run(CommandIDs.appDeleteAllData, ["includeLibrary": true], as: .bridge("claude-code"))
            XCTFail("a denied confirmation must stop the command")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(deniedRig.prompter?.prompts.count, 0)
        XCTAssertEqual(deniedRig.wiper.calls, 0)
    }

    func testDryRunPreviewsWithoutAskingOrDeleting() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let rig = try DeletionRig(h)
        rig.container.write("Library/Caches/index.sqlite")
        let r = try await h.app.bus.execute(Invocation(command: CommandIDs.appDeleteAllData, params: ["includeLibrary": true],
                                                       session: h.session, dryRun: true))
        let out = try r.value.decode(DeleteAllDataCommand.Output.self)
        XCTAssertFalse(out.deleted)
        XCTAssertTrue(out.dryRun)
        XCTAssertEqual(out.documents, h.library.allNodes().filter { $0.kind == .document }.count)
        XCTAssertTrue(out.erases.contains { $0.contains("library") })
        XCTAssertEqual(out.libraryPath, h.library.rootURL.path)
        XCTAssertEqual(rig.prompter?.prompts.count, 0)
        XCTAssertTrue(rig.container.exists("Library/Caches/index.sqlite"))
        XCTAssertEqual(rig.wiper.calls, 0)
    }

    func testWithoutAPersonAtAWindowTheCommandIsUnavailable() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let rig = try DeletionRig(h, answers: nil)
        rig.container.write("Library/Caches/index.sqlite")
        do {
            try await h.run(CommandIDs.appDeleteAllData, [:])
            XCTFail("expected unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertTrue(rig.container.exists("Library/Caches/index.sqlite"))
    }

    func testAConfirmationThatCannotBeShownDeletesNothing() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let rig = try DeletionRig(h)
        rig.prompter?.unshown = true
        rig.container.write("Library/Caches/index.sqlite")
        do {
            try await h.run(CommandIDs.appDeleteAllData, [:])
            XCTFail("expected unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertTrue(rig.container.exists("Library/Caches/index.sqlite"))
        XCTAssertEqual(rig.wiper.calls, 0)
    }

    func testHostlessLiveServiceNeverDeletes() async throws {
        // The app's own service answers `unavailable` in hostless runs before it looks at any file.
        let h = Harness(features: [FeatAboutFeature.self])
        do {
            try await h.run(CommandIDs.appDeleteAllData, [:])
            XCTFail("expected unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
    }

    func testIncludingTheLibraryClosesDocumentsAndRemovesOnlyNibContent() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let rig = try DeletionRig(h)
        _ = try h.app.workspace.content(Fixtures.docID)
        XCTAssertTrue(h.app.workspace.isLoaded(Fixtures.docID))
        let root = h.library.rootURL
        rig.container.write(root.appendingPathComponent("Fixture.nibnote/doc.00000007.json"))
        rig.container.write(root.appendingPathComponent(".nib-library/prefs.00000007.json"))
        rig.container.write(root.appendingPathComponent("notes.txt"))
        let expected = (h.library.allNodes() + h.library.trashedNodes()).filter { $0.kind == .document }.count

        let out = try await h.run(CommandIDs.appDeleteAllData, ["includeLibrary": true]).decode(DeleteAllDataCommand.Output.self)

        XCTAssertTrue(out.deleted)
        XCTAssertEqual(out.documents, expected)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Fixture.nibnote").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".nib-library").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("notes.txt").path), "files Nib did not make stay")
        XCTAssertFalse(h.app.workspace.isLoaded(Fixtures.docID), "open documents leave memory first")
        XCTAssertEqual(rig.prompter?.prompts.last?.confirmTitle, DeletionCopy.final(rig.prompter!.finish!.subject).confirmTitle)
        XCTAssertTrue(rig.prompter?.finish?.subject.includeLibrary ?? false)
    }

    func testSyncedSettingsStayWithTheLibrary() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        _ = try DeletionRig(h)
        let backend = DictionarySyncedBackend()
        h.app.settings.syncedBackend = backend
        h.app.settings.set(NibSettings.openAsTabs, false)          // synced: lives in the library
        h.app.settings.set(NibSettings.hideStatusBar, true)        // device-local
        XCTAssertNotNil(backend.values[NibSettings.openAsTabs.name])

        let removed = DeviceSettingsEraser.clear(h.app.settings)

        XCTAssertGreaterThanOrEqual(removed, 1)
        XCTAssertFalse(h.app.settings.get(NibSettings.openAsTabs), "a synced setting belongs to the library folder")
        XCTAssertFalse(h.app.settings.get(NibSettings.hideStatusBar))
        XCTAssertNil(h.app.settings.json(NibSettings.hideStatusBar.name))
    }

    // MARK: Plan and eraser

    func testEraseWithoutLibraryKeepsLibraryDeviceIDAndPreferences() throws {
        let c = try TempContainer()
        for file in ["Library/Caches/index.sqlite", "Library/Caches/com.apple.nsurlsessiond/x",
                     "Library/Application Support/Nib/device-id", "Library/Application Support/Nib/providers.json",
                     "Library/Application Support/grants.json", "Library/WebKit/WebsiteData/local.db",
                     "Library/Cookies/Cookies.binarycookies", "Library/Preferences/app.nib.Nib.plist",
                     "tmp/upload.bin", "Documents/Inbox/scan.pdf", "Documents/diagnostics/library-copy.zip",
                     "Documents/Physics.nibnote/doc.00000007.json", "Documents/.nib-library/prefs.00000007.json",
                     "Group/widget-snapshot.json"] {
            c.write(file)
        }
        let plan = DeletionPlanner.plan(includeLibrary: false, libraryRoot: c.locations.documents, locations: c.locations)
        XCTAssertEqual(plan.libraryRoots, [])

        let report = DataEraser(fileManager: .default, coordinatesFiles: true).erase(plan)

        XCTAssertEqual(report.failures, [])
        XCTAssertGreaterThanOrEqual(report.removed, 9)
        for gone in ["Library/Caches/index.sqlite", "Library/Application Support/Nib/providers.json",
                     "Library/Application Support/grants.json", "Library/WebKit/WebsiteData", "Library/Cookies/Cookies.binarycookies",
                     "tmp/upload.bin", "Documents/Inbox", "Documents/diagnostics", "Group/widget-snapshot.json"] {
            XCTAssertFalse(c.exists(gone), gone)
        }
        for kept in ["Library/Application Support/Nib/device-id", "Library/Preferences/app.nib.Nib.plist",
                     "Documents/Physics.nibnote/doc.00000007.json", "Documents/.nib-library/prefs.00000007.json",
                     "Library/Caches", "Library/WebKit", "Group"] {
            XCTAssertTrue(c.exists(kept), kept)
        }
    }

    func testEraseWithLibraryRemovesOnlyWhatNibMade() throws {
        let c = try TempContainer()
        let lib = "iCloud Drive/Nib/"
        for file in ["A.nibnote/doc.00000007.json", "A.nibnote/assets/photo.png", "Physics/.nibfolder.00000007.json",
                     "Physics/B.nibnote/doc.00000007.json", "Physics/syllabus.pdf", "Chemistry/.nibfolder.00000001.json",
                     "Chemistry/C.nibnote/doc.00000001.json", "Chemistry/.DS_Store", ".nib-library/prefs.00000007.json",
                     ".nib-library/trash/D.nibnote/doc.00000007.json", ".E.nibnote.icloud", "Old.nib/doc.00000001.json",
                     "Interface.nib/keyedobjects.nib", "readme.txt"] {
            c.write(lib + file)
        }
        c.makeDirectory(lib + "Empty")
        c.write("Documents/Earlier.nibnote/doc.00000007.json")
        c.write("Documents/user.pdf")
        c.write("Library/Application Support/Nib/device-id")
        let root = c.url(lib)

        let plan = DeletionPlanner.plan(includeLibrary: true, libraryRoot: root, locations: c.locations)
        XCTAssertEqual(plan.libraryRoots.map(AboutPaths.canonical),
                       [root, c.locations.documents].map(AboutPaths.canonical))
        let report = DataEraser(fileManager: .default, coordinatesFiles: true).erase(plan)

        XCTAssertEqual(report.failures, [])
        for gone in ["A.nibnote", "Physics/.nibfolder.00000007.json", "Physics/B.nibnote", "Chemistry", ".nib-library",
                     ".E.nibnote.icloud", "Old.nib"] {
            XCTAssertFalse(c.exists(lib + gone), gone)
        }
        for kept in ["Physics/syllabus.pdf", "Interface.nib/keyedobjects.nib", "readme.txt", "Empty"] {
            XCTAssertTrue(c.exists(lib + kept), kept)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the chosen folder itself stays")
        XCTAssertFalse(c.exists("Documents/Earlier.nibnote"), "an earlier library in Nib's Documents goes too")
        XCTAssertTrue(c.exists("Documents/user.pdf"))
        XCTAssertFalse(c.exists("Library/Application Support/Nib/device-id"), "a fresh start gets a new device id")
    }

    func testPlanCoversALibraryInsideDocumentsOnce() throws {
        let c = try TempContainer()
        let inside = c.locations.documents.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let nested = DeletionPlanner.plan(includeLibrary: true, libraryRoot: inside, locations: c.locations)
        XCTAssertEqual(nested.libraryRoots.map(AboutPaths.canonical), [AboutPaths.canonical(c.locations.documents)])
        XCTAssertTrue(nested.keep.contains(inside), "the chosen folder itself is never removed")

        let same = DeletionPlanner.plan(includeLibrary: true, libraryRoot: c.locations.documents, locations: c.locations)
        XCTAssertEqual(same.libraryRoots.count, 1)
        XCTAssertFalse(same.keep.contains(c.locations.deviceIDFile))

        let kept = DeletionPlanner.plan(includeLibrary: false, libraryRoot: inside, locations: c.locations)
        XCTAssertTrue(kept.keep.contains(c.locations.deviceIDFile))
        XCTAssertTrue(kept.clear.contains(c.locations.library.appendingPathComponent("WebKit", isDirectory: true)))
    }

    func testNibOwnership() {
        XCTAssertEqual(NibOwnership.classify(name: "Physics.nibnote", isDirectory: true), .owned)
        XCTAssertEqual(NibOwnership.classify(name: ".nib-library", isDirectory: true), .owned)
        XCTAssertEqual(NibOwnership.classify(name: ".nibfolder.0a1b2c3d.json", isDirectory: false), .owned)
        XCTAssertEqual(NibOwnership.classify(name: ".Physics.nibnote.icloud", isDirectory: false), .owned)
        XCTAssertEqual(NibOwnership.classify(name: "..nibfolder.0a1b2c3d.json.icloud", isDirectory: false), .owned)
        XCTAssertEqual(NibOwnership.classify(name: "Old.nib", isDirectory: true), .legacyCandidate)
        XCTAssertEqual(NibOwnership.classify(name: "Physics.nibnote", isDirectory: false), .other)
        XCTAssertEqual(NibOwnership.classify(name: ".report.pdf.icloud", isDirectory: false), .other)
        XCTAssertEqual(NibOwnership.classify(name: "Physics", isDirectory: true), .other)
        XCTAssertTrue(NibOwnership.isDocumentFile("doc.00000007.json"))
        XCTAssertFalse(NibOwnership.isDocumentFile("page.json"))
    }

    func testAppGroupIDsAndPaths() {
        XCTAssertEqual(AppGroupIDs.configured(["ALTAppGroups": ["group.alt.nib"], "NibAppGroups": ["group.app.nib.Nib", "group.alt.nib"]]),
                       ["group.alt.nib", "group.app.nib.Nib"])
        XCTAssertEqual(AppGroupIDs.configured([:]), [])
        XCTAssertTrue(AboutPaths.contains(URL(fileURLWithPath: "/var/mobile/A"), URL(fileURLWithPath: "/private/var/mobile/A/b")))
        XCTAssertFalse(AboutPaths.contains(URL(fileURLWithPath: "/var/mobile/A"), URL(fileURLWithPath: "/var/mobile/AB")))
    }

    // MARK: Copy

    func testConfirmationCopy() {
        var s = DeletionSubject(includeLibrary: false, documents: 23, lockedDocuments: 2, libraryName: "iCloud Drive \u{203A} Nib",
                                libraryInApp: false, deviceModel: "iPad")
        let keep = DeletionCopy.prompts(s)
        XCTAssertEqual(keep.map { $0.step }, [.overview, .final])
        XCTAssertTrue(keep[0].message.contains("iCloud Drive \u{203A} Nib"))
        XCTAssertFalse(keep[0].message.contains("23"))
        XCTAssertEqual(keep[1].confirmTitle, "Delete All Data")

        s.includeLibrary = true
        let all = DeletionCopy.prompts(s)
        XCTAssertTrue(all[0].message.contains("23 documents"))
        XCTAssertTrue(all[0].message.contains("2 locked documents"))
        XCTAssertEqual(all[1].confirmTitle, "Delete Library and Data")
        XCTAssertTrue(all[1].isDestructive)
        s.documents = 1
        s.lockedDocuments = 0
        XCTAssertTrue(DeletionCopy.overview(s).message.contains("1 document "))
        XCTAssertFalse(DeletionCopy.overview(s).message.contains("locked"))

        for prompt in keep + all {
            XCTAssertFalse(prompt.message.contains("\u{2014}"), "no em dashes in UI copy")
            XCTAssertFalse(prompt.message.contains("!"))
        }
        let finish = DeletionFinish(subject: s, failures: 3)
        XCTAssertTrue(finish.failureMessage?.contains("3 items") ?? false)
        XCTAssertNil(DeletionFinish(subject: s, failures: 0).failureMessage)
        XCTAssertTrue(DeleteAllDataCommand.descriptor.summary.count <= 200)
    }

    // MARK: Privacy

    func testNetworkLocality() {
        for host in ["localhost", "127.0.0.1", "192.168.1.20", "10.0.0.2", "172.20.4.1", "169.254.3.3", "100.101.2.3",
                     "studio.local", "gpu-box.tail1234.ts.net", "[::1]", "fd12:3456::1", "fe80::1", "nas.home.arpa"] {
            XCTAssertTrue(NetworkLocality.isOwnNetwork(host: host), host)
        }
        for host in ["api.anthropic.com", "openrouter.ai", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:db8::1",
                     "192.168.1", "1.2.3.4.5", ""] {
            XCTAssertFalse(NetworkLocality.isOwnNetwork(host: host), host)
        }
    }

    func testAIPrivacyNamesTheAssistantsProviderAndTheOthers() throws {
        XCTAssertEqual(AIPrivacySummary.from(store: nil), AIPrivacySummary(destination: .none, others: []))
        let ollama = AIProviderConfig(name: "Ollama", kind: .openAICompatible,
                                      baseURL: try XCTUnwrap(URL(string: "http://192.168.1.20:11434/v1")), model: "llama3")
        let claude = AIProviderConfig(name: "Anthropic", kind: .anthropic,
                                      baseURL: try XCTUnwrap(URL(string: "https://api.anthropic.com")), model: "claude")
        XCTAssertEqual(AIPrivacySummary.from(store: FakeProviderStore([], active: nil)).destination, .none)

        let local = AIPrivacySummary.from(store: FakeProviderStore([ollama, claude], active: ollama.id))
        XCTAssertEqual(local.destination, .local(name: "Ollama", host: "192.168.1.20"))
        XCTAssertEqual(local.others, ["Anthropic (api.anthropic.com)"])
        XCTAssertTrue(local.message.contains("own network"))
        XCTAssertTrue(local.message.contains("Anthropic (api.anthropic.com)"), "every provider that can receive data is named")

        let remote = AIPrivacySummary.from(store: FakeProviderStore([ollama, claude], active: claude.id))
        XCTAssertEqual(remote.destination, .remote(name: "Anthropic", host: "api.anthropic.com"))
        XCTAssertEqual(remote.others, ["Ollama (192.168.1.20)"])

        // No active id: the store's own answer for the active provider decides.
        let fallback = AIPrivacySummary.from(store: FakeProviderStore([claude], active: nil, fallback: claude))
        XCTAssertEqual(fallback, AIPrivacySummary(destination: .remote(name: "Anthropic", host: "api.anthropic.com"), others: []))
        XCTAssertEqual(fallback.message, AssistantDestination.remote(name: "Anthropic", host: "api.anthropic.com").message)
        let unchosen = AIPrivacySummary.from(store: FakeProviderStore([ollama, claude], active: nil))
        XCTAssertEqual(unchosen.destination, .unchosen)
        XCTAssertEqual(unchosen.others.count, 2)
        XCTAssertFalse(unchosen.message.contains("No AI provider is set up"))
    }

    func testReportIssueLinkCarriesOnlyTheBuildAndSystem() throws {
        let facts = AboutFacts(version: "1.2.0", build: "45", deviceID: "0a1b2c3d", system: "iPadOS 26.0", model: "iPad",
                               libraryPath: "/var/mobile/Secret Library", libraryDisplay: "On My iPad \u{203A} Nib",
                               documents: 3, folders: 1)
        let url = try XCTUnwrap(ReportIssueLink.url(facts: facts))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/GOODMAN-PRO/nib/issues/new")
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("Nib 1.2.0 (45), iPadOS 26.0, iPad"))
        for secret in ["0a1b2c3d", "Secret Library", "On My iPad"] {
            XCTAssertFalse(body.contains(secret), secret)
        }
    }

    // MARK: About

    func testAboutFactsAndAuthorNameGoThroughSettingsSet() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let facts = AboutFacts.current(app: h.app)
        XCTAssertEqual(facts.deviceID, h.app.deviceHex)
        XCTAssertEqual(facts.documents, h.library.allNodes().filter { $0.kind == .document }.count)
        XCTAssertEqual(facts.folders, 1)
        XCTAssertEqual(facts.libraryPath, h.library.rootURL.path)

        let model = AboutModel(app: h.app)
        model.name = "  Grace Hopper "
        await model.commitName()
        XCTAssertEqual(h.app.settings.get(NibSettings.authorName), "Grace Hopper")
        XCTAssertEqual(model.name, "Grace Hopper")
        XCTAssertNil(model.notice)
    }

    func testKnownLibrariesSwitchThroughLibrarySwitch() async throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let current = h.library.rootURL.path
        var switched: [JSONValue] = []
        let first: JSONValue = ["id": "loc-1", "name": "On My iPad", "path": .string(current)]
        let second: JSONValue = ["id": "loc-2", "path": "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Physics"]
        let locations: JSONValue = ["locations": .array([first, second])]
        h.app.commands.register(CommandDescriptor(id: CommandIDs.libraryLocations, title: "Library Locations",
                                                  summary: "test", effect: .read, target: .library)) { _, _ in
            locations
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.librarySwitch, title: "Switch Library", summary: "test",
                                                  effect: .library, target: .library)) { params, _ in
            switched.append(params)
            return [:]
        }
        let model = AboutModel(app: h.app)
        await model.refresh()
        XCTAssertEqual(model.libraries.map { $0.id }, ["loc-1", "loc-2"])
        XCTAssertEqual(model.libraries.map { $0.isCurrent }, [true, false])
        XCTAssertEqual(model.libraries.last?.name, "Physics")
        await model.switchLibrary(model.libraries[0])
        XCTAssertTrue(switched.isEmpty, "the current library is not switched to again")
        await model.switchLibrary(model.libraries[1])
        XCTAssertEqual(switched, [["location": "loc-2"]])
    }

    func testCopyGoesThroughClipboardCopyText() async {
        let h = Harness(features: [FeatAboutFeature.self])
        var copied: [JSONValue] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.clipboardCopyText, title: "Copy Text", summary: "test",
                                                  effect: .read, target: .app)) { params, _ in
            copied.append(params)
            return [:]
        }
        let model = AboutModel(app: h.app)
        await model.copy("0a1b2c3d")
        XCTAssertEqual(copied, [["text": "0a1b2c3d"]])
        XCTAssertNil(model.copied, "the check mark goes back to the copy glyph")
        XCTAssertNil(model.notice)
    }

    func testSymbolicLinksAreNeverFollowed() throws {
        let c = try TempContainer()
        c.write("Outside/Precious.nibnote/doc.00000007.json")
        c.write("Library/Caches/keep-me-out/file")
        let lib = c.url("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("Shortcut"), withDestinationURL: c.url("Outside"))
        let plan = DeletionPlanner.plan(includeLibrary: true, libraryRoot: lib, locations: c.locations)
        _ = DataEraser(fileManager: .default, coordinatesFiles: true).erase(plan)
        XCTAssertTrue(c.exists("Outside/Precious.nibnote/doc.00000007.json"), "a link inside the library is not walked into")
        XCTAssertFalse(c.exists("Library/Caches/keep-me-out"))
    }

    func testKnownLibraryParserShapes() {
        let strings = KnownLibraryParser.parse(["/a/Nib", "/b/Other", "/a/Nib"], currentPath: "/b/Other")
        XCTAssertEqual(strings.map { $0.name }, ["Nib", "Other"])
        XCTAssertEqual(strings.map { $0.isCurrent }, [false, true])
        let objects = KnownLibraryParser.parse(["libraries": [["location": "x", "title": "Work", "active": true], ["name": "no id"]]],
                                               currentPath: nil)
        XCTAssertEqual(objects, [KnownLibrary(id: "x", name: "Work", detail: nil, isCurrent: true)])
        XCTAssertEqual(KnownLibraryParser.parse(.null, currentPath: nil), [])
    }

    func testLibraryPathFormatter() {
        let docs = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Documents")
        let sep = LibraryPathFormatter.separator
        XCTAssertEqual(LibraryPathFormatter.display(docs, documents: docs, deviceModel: "iPad"), "On My iPad" + sep + "Nib")
        XCTAssertEqual(LibraryPathFormatter.display(docs.appendingPathComponent("School/Notes"), documents: docs, deviceModel: "iPhone"),
                       ["On My iPhone", "Nib", "School", "Notes"].joined(separator: sep))
        let icloud = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Nib Library")
        XCTAssertEqual(LibraryPathFormatter.display(icloud, documents: docs, deviceModel: "iPad"), "iCloud Drive" + sep + "Nib Library")
        let container = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/iCloud~app~nib~Nib/Documents/Lib")
        XCTAssertEqual(LibraryPathFormatter.display(container, documents: docs, deviceModel: "iPad"), "iCloud Drive" + sep + "Lib")
        let provider = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/X/File Provider Storage/OneDrive/Nib")
        XCTAssertEqual(LibraryPathFormatter.display(provider, documents: docs, deviceModel: "iPad"), "OneDrive" + sep + "Nib")
    }

    // MARK: Parity (N-028)

    /// Acceptance: parity.json holds exactly the inventory ids whose status is partial, substitute or n/a (in
    /// document order, with their notes), plus the exceptions table, read here straight from docs/FEATURES.md.
    func testParityJSONMatchesTheFeaturesInventory() throws {
        let catalog = try Self.catalog()
        let inventory = try Self.inventory()

        XCTAssertEqual(catalog.items.map { $0.id }, inventory.listed.map { $0.id })
        for (item, row) in zip(catalog.items, inventory.listed) {
            XCTAssertEqual(Self.raw(item.status), row.status, item.id)
            XCTAssertEqual(item.feature, row.feature, item.id)
            XCTAssertEqual(item.note, row.note, item.id)
            XCTAssertFalse(item.note.isEmpty, item.id)
        }
        XCTAssertEqual(catalog.exceptions.map { $0.name }, inventory.exceptions)
        XCTAssertEqual(catalog.totals.partial, inventory.counts["partial"])
        XCTAssertEqual(catalog.totals.substitute, inventory.counts["substitute"])
        XCTAssertEqual(catalog.totals.notAvailable, inventory.counts["n/a"])
        XCTAssertEqual(catalog.totals.parity, inventory.counts["parity"])
        XCTAssertEqual(catalog.totals.parityPlus, inventory.counts["parity+"])
        XCTAssertEqual(catalog.totals.total, inventory.counts.values.reduce(0, +))
        XCTAssertEqual(catalog.totals.differing, catalog.items.count)
        XCTAssertEqual(catalog.areas.map { $0.prefix }, ["T", "D", "S", "P"])
        // Every F098 inventory item that is not at parity is on the page.
        for id in ["D-022", "D-035", "D-084", "S-015", "S-016", "S-017", "S-018", "S-021", "S-069", "S-085", "P-015",
                   "P-016", "P-017", "P-018", "P-019", "P-020", "P-021", "P-022", "P-023", "P-037", "P-085", "P-086",
                   "P-097", "P-099", "P-102", "P-104", "P-109", "P-111", "D-139"] {
            XCTAssertTrue(catalog.items.contains { $0.id == id }, id)
        }
    }

    func testParityFilterAndSearch() throws {
        let catalog = try Self.catalog()
        let all = catalog.sections(filter: .all, query: "")
        XCTAssertEqual(all.flatMap { $0.items }.count, catalog.items.count)
        XCTAssertEqual(all.map { $0.id }, ["T", "D", "S", "P"])
        XCTAssertEqual(catalog.exceptions(filter: .all, query: "").count, catalog.exceptions.count)

        let na = catalog.sections(filter: .notAvailable, query: "").flatMap { $0.items }
        XCTAssertEqual(na.count, catalog.totals.notAvailable)
        XCTAssertTrue(na.allSatisfy { $0.status == .notAvailable })
        XCTAssertEqual(catalog.count(.substitute), catalog.totals.substitute)
        XCTAssertTrue(catalog.exceptions(filter: .partial, query: "").isEmpty)

        let wolfram = catalog.sections(filter: .all, query: "wolfram|alpha").flatMap { $0.items }
        XCTAssertEqual(wolfram.map { $0.id }, ["S-028"])
        XCTAssertEqual(catalog.sections(filter: .all, query: "p-018").flatMap { $0.items }.map { $0.id }, ["P-018"])
        XCTAssertEqual(catalog.sections(filter: .all, query: "ACCOUNT deletion").flatMap { $0.items }.map { $0.id }, ["P-018"])
        XCTAssertTrue(catalog.sections(filter: .partial, query: "Account deletion").isEmpty)
        XCTAssertEqual(catalog.exceptions(filter: .all, query: "face id").map { $0.name }, ["User presence"])
        XCTAssertTrue(catalog.sections(filter: .all, query: "zzzz-no-such-thing").isEmpty)

        XCTAssertEqual(ParityText.plain("`security` scope (`lock.setup`) **now**"), "security scope (lock.setup) now")
        XCTAssertEqual(ParityFilter.allCases.count, 4)
    }

    func testParityStatusDecodesUnknownStatusesLeniently() throws {
        let json = #"{"totals":{"parity":1,"parity+":0,"partial":1,"substitute":0,"n/a":0,"total":2},"items":[{"id":"T-001","area":"T","feature":"Pen","status":"planned","builtBy":[],"note":"Soon."}]}"#
        let catalog = try ParityCatalog.load(from: Data(json.utf8))
        XCTAssertEqual(catalog.items.first?.status, .other("planned"))
        XCTAssertEqual(catalog.items.first?.status.title, "planned")
        XCTAssertEqual(catalog.exceptions, [])
        XCTAssertEqual(catalog.sections(filter: .all, query: "").first?.title, "T", "an unknown area keeps its prefix")
        XCTAssertNil(ParityCatalog.bundled(Bundle(for: FeatAboutTests.self)), "hostless tests have no app bundle copy")
    }

    // MARK: Screens

    func testScreensRenderInEveryVariant() throws {
        let h = Harness(features: [FeatAboutFeature.self])
        let catalog = try Self.catalog()
        let item = try XCTUnwrap(catalog.items.first { $0.id == "P-018" })
        let row = ParityItemRow(item: item).padding()
        XCTAssertEqual(Set(NibSnapshot.images(row, size: CGSize(width: 390, height: 200)).keys), Set(NibSnapshot.Variant.allCases))
        let large = NibSnapshot.fittingSize(row, width: 390, variant: .largeText)
        XCTAssertGreaterThan(large.height, NibSnapshot.fittingSize(row, width: 390).height, "rows grow with Dynamic Type")
        let exception = try XCTUnwrap(catalog.exceptions.first)
        XCTAssertNotNil(NibSnapshot.image(ParityExceptionRow(exception: exception).padding(), size: CGSize(width: 390, height: 260),
                                          variant: .dark))
        let subject = DeletionSubject(includeLibrary: false, documents: 3, lockedDocuments: 0, libraryName: "On My iPad",
                                      libraryInApp: true, deviceModel: "iPad")
        XCTAssertNotNil(NibSnapshot.image(DeletionFinishedView(finish: DeletionFinish(subject: subject, failures: 1), close: {}),
                                          size: CGSize(width: 390, height: 844), variant: .largeText))
        XCTAssertEqual(Set(NibSnapshot.images(NavigationStack { AboutPage(app: h.app) }, size: CGSize(width: 760, height: 706)).keys),
                       Set(NibSnapshot.Variant.allCases))
        XCTAssertNotNil(NibSnapshot.image(NavigationStack { PrivacyPage(app: h.app) }, size: CGSize(width: 390, height: 844)))
        XCTAssertNotNil(NibSnapshot.image(NavigationStack { ParityPage(catalog: catalog) }, size: CGSize(width: 390, height: 844)))
        XCTAssertNotNil(NibSnapshot.image(NavigationStack { ParityPage(catalog: nil) }, size: CGSize(width: 390, height: 844)))
    }

    // MARK: Repository files

    private static var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FeatAboutTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NibKit
            .deletingLastPathComponent() // repository root
    }

    private static func catalog() throws -> ParityCatalog {
        try ParityCatalog.load(from: Data(contentsOf: repository.appendingPathComponent("Nib/Resources/parity.json")))
    }

    private static func raw(_ status: ParityStatus) -> String {
        switch status {
        case .partial: return "partial"
        case .substitute: return "substitute"
        case .notAvailable: return "n/a"
        case .other(let raw): return raw
        }
    }

    struct Row {
        var id: String
        var feature: String
        var status: String
        var note: String
    }

    /// docs/FEATURES.md read independently of Scripts/gen_parity.py: every T/D/S/P row, the status counts, and the
    /// class column of the exceptions table.
    private static func inventory() throws -> (listed: [Row], exceptions: [String], counts: [String: Int]) {
        let text = try String(contentsOf: repository.appendingPathComponent("docs/FEATURES.md"), encoding: .utf8)
        var listed: [Row] = []
        var exceptions: [String] = []
        var counts: [String: Int] = [:]
        var inExceptions = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                inExceptions = line.hasPrefix("## Exceptions to the modify-anything guarantee")
                continue
            }
            guard line.hasPrefix("| ") else { continue }
            let cells = Self.cells(String(line))
            if inExceptions {
                if cells.count == 4, cells[0] != "Class", !cells[0].hasPrefix("---") { exceptions.append(cells[0]) }
                continue
            }
            guard cells.count == 5, cells[0].range(of: #"^[TDSP]-\d{3}$"#, options: .regularExpression) != nil else { continue }
            counts[cells[2], default: 0] += 1
            if ["partial", "substitute", "n/a"].contains(cells[2]) {
                listed.append(Row(id: cells[0], feature: cells[1], status: cells[2], note: cells[4]))
            }
        }
        return (listed, exceptions, counts)
    }

    /// Cells of a Markdown table row, split on unescaped pipes, with `\|` unescaped.
    private static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for ch in line.trimmingCharacters(in: .whitespaces) {
            if ch == "|" && previous != "\\" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        cells.append(current)
        return Array(cells.dropFirst().dropLast())
            .map { $0.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }
}
