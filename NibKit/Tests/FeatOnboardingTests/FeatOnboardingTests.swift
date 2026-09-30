import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatOnboarding

/// A window, recording what it was asked to show.
@MainActor
final class FakeNavigator: SceneNavigator {
    let session = EditorSession()
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID? { nil }
    var rootViewController: UIViewController? { nil }
    private(set) var libraryShows = 0
    private(set) var opened: [DocumentID] = []
    private(set) var settingsPages: [String?] = []

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) { opened.append(doc) }
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) { libraryShows += 1 }
    func showSettings(page: String?) { settingsPages.append(page) }
    func presentModal(_ viewController: UIViewController) {}
}

/// The commands `.nibCommandFailed` named, in order. The model posts on the main actor and the observer runs
/// synchronously there, so the log is only touched from the main thread.
final class FailureLog: @unchecked Sendable {
    var commands: [String] = []
}

/// Params of every call a stand-in command received, in order.
@MainActor
final class CallLog {
    var calls: [(command: String, params: JSONValue)] = []

    func params(_ command: String) -> [JSONValue] { calls.filter { $0.command == command }.map { $0.params } }
    var commands: [String] { calls.map { $0.command } }
}

@MainActor
final class FeatOnboardingTests: XCTestCase {
    // MARK: Helpers

    private let home = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/1A2B3C4D", isDirectory: true)
    private let appDocuments = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/1A2B3C4D/Documents",
                                   isDirectory: true)
    private let iCloudFolder = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Nib Notes",
                                   isDirectory: true)
    private let onMyIPadFolder = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/9F8E/File Provider Storage/Notes",
                                     isDirectory: true)

    /// A harness with onboarding registered, a window that is the active one, and a model on a movable library root.
    /// The model runs as on iPad unless `idiom` says otherwise.
    private func make(root: URL? = nil, idiom: UIUserInterfaceIdiom = .pad) -> (Harness, FakeNavigator, OnboardingModel, RootBox) {
        let h = Harness(features: [FeatOnboardingFeature.self])
        let nav = FakeNavigator()
        h.app.services.sessions.add(nav.session)
        h.app.ui.activeNavigator = nav
        let box = RootBox(root ?? appDocuments)
        let model = OnboardingModel(app: h.app, navigator: nav, containerHome: home, libraryRoot: { box.url }, idiom: idiom)
        return (h, nav, model, box)
    }

    /// Records the commands the screen reports as failed (`.nibCommandFailed`, as `app.perform` posts them).
    private func watchFailures(_ h: Harness) -> (FailureLog, OnboardingSubscription) {
        let failures = FailureLog()
        let token = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: h.app, queue: nil) { note in
            failures.commands.append(note.userInfo?["command"] as? String ?? "?")
        }
        return (failures, OnboardingSubscription { NotificationCenter.default.removeObserver(token) })
    }

    /// Stand-ins for the sample notebook's commands: a notebook with a cover and two paper pages.
    private func fakeSampleCommands(_ h: Harness, log: CallLog) throws {
        let created = try JSONValue.parse(#"{"ref": "doc:SAMPLEDOC001", "title": "Welcome to Nib", "pages": ["page:SAMPLEDOC001/COVER0000001", "page:SAMPLEDOC001/PAPER0000001", "page:SAMPLEDOC001/PAPER0000002"]}"#)
        fake(h, CommandIDs.docCreate, effect: .library, log: log) { _ in created }
        fake(h, CommandIDs.textCreateBox, effect: .edit, log: log) { _ in ["ref": "item:SAMPLEDOC001/PAPER0000001/T1"] }
        fake(h, CommandIDs.inkWriteText, effect: .edit, log: log) { _ in ["refs": []] }
    }

    final class RootBox {
        var url: URL?
        init(_ url: URL?) { self.url = url }
    }

    /// Registers a stand-in for another feature's command that logs its params and returns `result`.
    private func fake(_ h: Harness, _ id: String, effect: Effect = .session, log: CallLog, userPresence: Bool = false,
                      result: @escaping (JSONValue) throws -> JSONValue = { _ in [:] }) {
        h.app.commands.register(CommandDescriptor(id: id, title: id, summary: "Stand-in for \(id).",
                                                  examples: [[:]], effect: effect, target: .app, owner: "fake",
                                                  userPresence: userPresence)) { params, _ in
            log.calls.append((id, params))
            return try result(params)
        }
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func isDone(_ h: Harness) -> Bool { h.app.settings.get(OnboardingSettings.done) }

    // MARK: Registration

    func testRegistersTheScreenAndADeviceLocalDoneSetting() {
        let h = Harness(features: [FeatOnboardingFeature.self])
        XCTAssertEqual(FeatOnboardingFeature.id, "onboarding")
        XCTAssertNotNil(h.app.ui.screens.onboarding)
        let d = h.app.settings.descriptor("onboarding.done")
        XCTAssertEqual(d?.owner, "onboarding")
        XCTAssertEqual(d?.synced, false, "onboarding belongs to this install, not to the library")
        XCTAssertEqual(d?.defaultValue, .bool(false))
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == "onboarding" }.isEmpty,
                      "every action runs another feature's or the contracts' commands; F093 owns none (ARCHITECTURE §6.5)")
    }

    func testCommandsAndSettingsConform() async {
        let problems = await CommandConformance.check(features: [FeatOnboardingFeature.self])
        XCTAssertEqual(problems, [])
    }

    /// Acceptance: never shown again after completion.
    func testScreenShowsUntilDoneAndNeverAfter() async throws {
        let h = Harness(features: [FeatOnboardingFeature.self])
        let nav = FakeNavigator()
        let factory = try XCTUnwrap(h.app.ui.screens.onboarding)
        XCTAssertTrue(factory(h.app, nav) is OnboardingHostingController)
        try await h.run("settings.set", ["name": "onboarding.done", "value": true])
        XCTAssertNil(factory(h.app, nav))
        XCTAssertNil(factory(h.app, FakeNavigator()), "no window shows it again")
        try await h.run("settings.set", ["name": "onboarding.done", "value": .null])
        XCTAssertNotNil(factory(h.app, nav), "resetting the setting (AI, plugin, bridge) brings it back next launch")
    }

    // MARK: Library location (P-014)

    func testLibraryPlacementTellsTheAppContainerFromOutsideFolders() {
        XCTAssertEqual(LibraryPlacement.classify(root: appDocuments, containerHome: home), .insideApp,
                       "/var and /private/var are the same place")
        XCTAssertEqual(LibraryPlacement.classify(root: home, containerHome: home), .insideApp)
        XCTAssertEqual(LibraryPlacement.classify(root: URL(fileURLWithPath: home.path + "/Documents/../Documents/Nib/"),
                                                 containerHome: home), .insideApp)
        XCTAssertEqual(LibraryPlacement.classify(root: iCloudFolder, containerHome: home),
                       .outside(folder: "Nib Notes", provider: LibraryPlacement.provider(forPath: iCloudFolder.path)))
        XCTAssertNotNil(LibraryPlacement.provider(forPath: iCloudFolder.path))
        XCTAssertEqual(LibraryPlacement.classify(root: onMyIPadFolder, containerHome: home),
                       .outside(folder: "Notes", provider: nil))
        XCTAssertEqual(LibraryPlacement.classify(root: URL(fileURLWithPath: home.path + "Other/Documents"), containerHome: home)
                        .isOutside, true, "a sibling container whose name only starts the same is outside")
        XCTAssertEqual(LibraryPlacement.classify(root: nil, containerHome: home), .unknown)
    }

    func testChooseFolderRunsTheLibraryCommandAndShowsWhereTheLibraryIs() async {
        let (h, _, model, box) = make()
        let log = CallLog()
        let picked = iCloudFolder
        fake(h, CommandIDs.libraryChooseFolder, effect: .library, log: log, userPresence: true) { _ in
            box.url = picked
            return [:]
        }
        XCTAssertEqual(model.placement, .insideApp)
        XCTAssertTrue(model.canChooseFolder)
        await model.chooseFolder()
        XCTAssertEqual(log.commands, [CommandIDs.libraryChooseFolder])
        XCTAssertTrue(model.placement.isOutside)
        XCTAssertEqual(model.step, .library, "the user sees the folder they picked before moving on")
        XCTAssertNil(model.busy)
        XCTAssertNil(model.message)
    }

    func testCancelledFolderPickerIsQuietAndOtherErrorsAreShown() async {
        let (h, _, model, _) = make()
        let log = CallLog()
        var error = NibError(.userDenied, "cancelled")
        fake(h, CommandIDs.libraryChooseFolder, effect: .library, log: log, userPresence: true) { _ in throw error }
        await model.chooseFolder()
        XCTAssertNil(model.message, "cancelling the picker is not an error")
        XCTAssertEqual(model.placement, .insideApp)
        error = NibError(.unavailable, "The folder can't be read")
        await model.chooseFolder()
        XCTAssertEqual(model.message, "The folder can't be read")
    }

    func testPickingAFolderInsideTheAppSaysSo() async {
        let (h, _, model, box) = make()
        let inside = appDocuments.appendingPathComponent("Notes", isDirectory: true)
        fake(h, CommandIDs.libraryChooseFolder, effect: .library, log: CallLog(), userPresence: true) { _ in
            box.url = inside
            return [:]
        }
        await model.chooseFolder()
        XCTAssertEqual(model.placement, .insideApp)
        XCTAssertNotNil(model.message, "a folder inside the container would be deleted with the app")
    }

    /// DESIGN / spec: "keep in app" is a warned opt-out.
    func testKeepingTheLibraryInsideIsWarnedThenMovesOn() async {
        let (h, _, model, _) = make()
        fake(h, CommandIDs.libraryChooseFolder, effect: .library, log: CallLog(), userPresence: true)
        model.keepInApp()
        XCTAssertEqual(model.confirmation, .keepInApp)
        XCTAssertEqual(model.step, .library, "nothing happens before the warning is accepted")
        model.confirmKeepInApp()
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.step, .pencil)
        XCTAssertFalse(isDone(h))
    }

    // MARK: Skip (acceptance: skippable)

    func testSkipWithTheLibraryOutsideFinishesAndShowsTheLibrary() async {
        let (h, nav, model, _) = make(root: iCloudFolder)
        fake(h, CommandIDs.libraryChooseFolder, effect: .library, log: CallLog(), userPresence: true)
        await model.skip()
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1, "window.showLibrary reached this window")
    }

    func testSkipWithTheLibraryInsideAsksFirst() async {
        let (h, nav, model, _) = make()
        fake(h, CommandIDs.libraryChooseFolder, effect: .library, log: CallLog(), userPresence: true)
        await model.skip()
        XCTAssertEqual(model.confirmation, .skipInsideApp)
        XCTAssertFalse(isDone(h))
        await model.confirmSkip()
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1)
    }

    func testSkipWithoutAFolderPickerNeedsNoWarning() async {
        let (h, nav, model, _) = make()
        XCTAssertFalse(model.canChooseFolder, "F025 is not installed in this harness")
        await model.skip()
        XCTAssertNil(model.confirmation)
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1)
    }

    /// `window.showLibrary` acts on the active window, so a window that is not the active one is sent to its library
    /// directly.
    func testLeavingFromAWindowThatIsNotTheActiveOneShowsTheLibraryThere() async {
        let (h, nav, model, _) = make(root: iCloudFolder)
        let other = FakeNavigator()
        h.app.services.sessions.add(other.session)
        h.app.ui.activeNavigator = other
        await model.skip()
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1)
        XCTAssertEqual(other.libraryShows, 0, "the other window keeps what it shows")
        XCTAssertNil(model.busy)
    }

    func testFinishingInAnotherWindowOrByTheAIClosesThisOne() async throws {
        let (h, nav, model, _) = make()
        try await h.run("settings.set", ["name": "onboarding.done", "value": true], as: .ai("chat1"))
        let left = await eventually { nav.libraryShows == 1 }
        XCTAssertTrue(left)
        XCTAssertEqual(model.step, .library, "this window made no choice of its own")
    }

    // MARK: Apple Pencil or finger

    func testStylusModeGoesThroughSettingsSet() async throws {
        let (h, _, model, _) = make()
        XCTAssertEqual(model.stylusMode, .pencilOnly)
        await model.setStylusMode(.anyInput)
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .anyInput)
        XCTAssertEqual(model.stylusMode, .anyInput)
        try await h.run("settings.set", ["name": "stylus.mode", "value": "pencilOnly"], as: .bridge("smoke"))
        let followed = await eventually { model.stylusMode == .pencilOnly }
        XCTAssertTrue(followed, "a change made elsewhere shows at once")
    }

    /// iPhone has no Apple Pencil: unless the user chooses, fingers write there once the Pencil step shows.
    func testIPhoneWritesWithFingersUnlessTheUserChoosesOtherwise() async throws {
        let (h, _, model, _) = make(idiom: .phone)
        XCTAssertFalse(model.isPad)
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .pencilOnly, "the contracts' default")
        model.advance()
        let switched = await eventually { h.app.settings.get(NibSettings.stylusMode) == .anyInput }
        XCTAssertTrue(switched, "the Pencil step on iPhone starts on Any Input")
        XCTAssertEqual(model.stylusMode, .anyInput)
        await model.setStylusMode(.pencilOnly)
        model.goBack()
        model.advance()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .pencilOnly, "the user's choice is never overridden")
        await model.skip()
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .pencilOnly)
    }

    func testSkippingOnIPhoneBeforeThePencilStepStillLetsFingersWrite() async {
        let (h, nav, model, _) = make(root: iCloudFolder, idiom: .phone)
        await model.skip()
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .anyInput)
        XCTAssertEqual(nav.libraryShows, 1)

        let (h2, _, model2, _) = make(root: iCloudFolder, idiom: .phone)
        for _ in 0..<3 { model2.advance() }
        await model2.finish(openQuickNote: false)
        XCTAssertTrue(isDone(h2))
        XCTAssertEqual(h2.app.settings.get(NibSettings.stylusMode), .anyInput, "finishing does the same")
    }

    func testIPadKeepsApplePencilUnlessTheUserChooses() async throws {
        let (h, _, model, _) = make(root: iCloudFolder)
        model.advance()
        try await Task.sleep(nanoseconds: 100_000_000)
        await model.skip()
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .pencilOnly)
    }

    func testPencilBindingsParseFilterAndSave() async throws {
        let json = try JSONValue.parse(#"""
        {"doubleTap": "system", "squeeze": "palette", "system": {"doubleTap": "switchEraser"},
         "choices": [{"id": "system", "title": "Use iPad setting", "gestures": ["doubleTap", "squeeze"]},
                     {"id": "eraser", "title": "Switch to eraser", "gestures": ["doubleTap"]},
                     {"id": "palette", "title": "Show palette", "gestures": ["squeeze"]},
                     {"id": "plugin.stamp", "title": "Stamp", "gestures": []}]}
        """#)
        let bindings = try XCTUnwrap(PencilBindings.parse(json))
        XCTAssertEqual(bindings.choices(for: .doubleTap).map { $0.id }, ["system", "eraser", "plugin.stamp"])
        XCTAssertEqual(bindings.choices(for: .squeeze).map { $0.id }, ["system", "palette", "plugin.stamp"])
        var odd = bindings
        odd.doubleTap = "gone.action"
        XCTAssertEqual(odd.choices(for: .doubleTap).first?.id, "gone.action", "the current value is always offered")
        XCTAssertNil(PencilBindings.parse(["doubleTap": "system"]))

        let (h, _, model, _) = make()
        let log = CallLog()
        let settings = h.app.settings
        fake(h, CommandIDs.pencilActions, effect: .read, log: log) { _ in
            // What F043 answers: the stored bindings and the choices.
            var answer = json.objectValue ?? [:]
            answer["doubleTap"] = settings.json("pencilhw.doubleTap") ?? "system"
            answer["squeeze"] = settings.json("pencilhw.squeeze") ?? "palette"
            return .object(answer)
        }
        h.app.settings.declare(SettingKey("pencilhw.doubleTap", default: "system"), summary: "Double-tap.", owner: "pencilhw",
                               schema: .str())
        h.app.settings.declare(SettingKey("pencilhw.squeeze", default: "system"), summary: "Squeeze.", owner: "pencilhw",
                               schema: .str())
        model.advance()
        let loaded = await eventually { model.pencil != nil }
        XCTAssertTrue(loaded)
        await model.setPencilBinding(.doubleTap, to: "eraser")
        XCTAssertEqual(h.app.settings.json("pencilhw.doubleTap"), .string("eraser"))
        XCTAssertEqual(model.pencil?.doubleTap, "eraser")
    }

    // MARK: AI (optional)

    func testAIStepListsProvidersAndOpensTheAISettingsPage() async throws {
        let (h, _, model, _) = make()
        let log = CallLog()
        XCTAssertNil(model.aiSettingsPage, "no Settings, no page")
        fake(h, CommandIDs.settingsOpen, log: log) { params in ["opened": "settings", "page": params["page"] ?? .null] }
        let providers = try JSONValue.parse(#"[{"id": "p1", "name": "Claude", "kind": "anthropic", "active": true}, {"id": "p2", "name": "Ollama on Mac"}]"#)
        fake(h, CommandIDs.aiProviderList, effect: .read, log: log) { _ in providers }
        h.app.ui.settingsPages.register(SettingsPageDescriptor(id: "settings.editing", title: "Editing", icon: "pencil",
                                                               section: .editing, order: 1, owner: "settings",
                                                               makeView: { _ in AnyView(EmptyView()) }))
        h.app.ui.settingsPages.register(SettingsPageDescriptor(id: "plugin.promptlibrary", title: "Prompts", icon: "text",
                                                               section: .ai, order: 1, owner: "promptlibrary",
                                                               makeView: { _ in AnyView(EmptyView()) }))
        XCTAssertEqual(model.aiSettingsPage, "plugin.promptlibrary", "without F086 the section's first page opens")
        h.app.ui.settingsPages.register(SettingsPageDescriptor(id: "aisettings.providers", title: "AI", icon: "drop",
                                                               section: .ai, order: 10, owner: "aisettings",
                                                               makeView: { _ in AnyView(EmptyView()) }))
        XCTAssertEqual(model.aiSettingsPage, "aisettings.providers", "F086's provider page wins over other AI pages")
        await model.openAISettings()
        XCTAssertEqual(log.params(CommandIDs.settingsOpen), [["page": "aisettings.providers"]])
        await model.loadProviders()
        XCTAssertEqual(model.providers, [ProviderSummary(id: "p1", name: "Claude", kind: "anthropic", isActive: true),
                                         ProviderSummary(id: "p2", name: "Ollama on Mac", kind: nil, isActive: false)])
        XCTAssertEqual(ProviderSummary.parse(["providers": [["id": "x"]], "active": "x"]),
                       [ProviderSummary(id: "x", name: "x", kind: nil, isActive: true)])
    }

    func testProvidersReloadOnlyWhileTheAIStepShows() async throws {
        let (h, _, model, _) = make()
        let log = CallLog()
        var rows: JSONValue = []
        fake(h, CommandIDs.aiProviderList, effect: .read, log: log) { _ in rows }
        h.app.settings.declare(SettingKey("aiprovider.maxSteps", default: 8.0), summary: "Most tool steps in a turn.",
                               owner: "aisettings", schema: .num())
        await model.reloadProvidersIfShown()
        XCTAssertEqual(log.commands, [], "not on the library step")
        XCTAssertFalse(model.presentsSheet, "nothing is presented over the window")
        model.advance()
        model.advance()
        let first = await eventually { log.commands.count == 1 }
        XCTAssertTrue(first, "the AI step loads the providers when it shows")
        rows = try JSONValue.parse(#"[{"id": "p1", "name": "Claude", "active": true}]"#)
        try await h.run("settings.set", ["name": "aiprovider.maxSteps", "value": 12])
        let reloaded = await eventually { model.providers.count == 1 }
        XCTAssertTrue(reloaded, "a setting F086 owns changed")
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: nil)
        let again = await eventually { log.commands.count >= 3 }
        XCTAssertTrue(again, "the app came back to the foreground")
        XCTAssertTrue(model.isAISetting("aiprovider.maxSteps"), "owned by F086")
        XCTAssertTrue(model.isAISetting(NibSettings.aiDirectToolsName))
        XCTAssertFalse(model.isAISetting("stylus.mode"))
    }

    // MARK: Finish: sample notebook and QuickNote

    func testFinishAddsTheSampleNotebookAndOpensAQuickNote() async throws {
        let (h, nav, model, _) = make(root: iCloudFolder)
        let log = CallLog()
        try fakeSampleCommands(h, log: log)
        fake(h, CommandIDs.docQuickNote, effect: .library, log: log) { _ in ["ref": "doc:QUICKNOTE001"] }
        for _ in 0..<3 { model.advance() }
        XCTAssertEqual(model.step, .done)
        XCTAssertTrue(model.addsSampleNotebook, "on by default")
        await model.finish(openQuickNote: true)

        XCTAssertTrue(isDone(h))
        XCTAssertEqual(log.commands, [CommandIDs.docCreate, CommandIDs.textCreateBox, CommandIDs.textCreateBox,
                                      CommandIDs.inkWriteText, CommandIDs.docQuickNote])
        let create = try XCTUnwrap(log.params(CommandIDs.docCreate).first)
        XCTAssertEqual(create["kind"], "notebook")
        XCTAssertEqual(create["pages"], .number(Double(SampleNotebook.pageCount)))
        let boxes = log.params(CommandIDs.textCreateBox)
        XCTAssertEqual(boxes.map { $0["page"] }, [.string("page:SAMPLEDOC001/PAPER0000001"),
                                                  .string("page:SAMPLEDOC001/PAPER0000001")],
                       "the tour goes on the first paper page, after the cover")
        let tour = try XCTUnwrap(boxes.last?["text"]).decode(RichText.self)
        let tips = SampleNotebook.tips(stylusMode: .pencilOnly, libraryOutside: true)
        XCTAssertTrue(tour.plainText.contains(tips[0]))
        XCTAssertTrue(tour.plainText.contains(tips[1]), "the library is outside Nib, so it is safe from reinstalls")
        XCTAssertNil(boxes.first?["style"], "the title keeps F026's style")
        XCTAssertEqual(boxes.last?["style"], ["autoGrow": false], "the tour keeps its frame above the handwriting line")
        XCTAssertEqual(log.params(CommandIDs.inkWriteText).first?["color"],
                       .string(h.app.settings.get(NibSettings.presets("pen")).color.hex))
        XCTAssertEqual(nav.libraryShows, 0, "the QuickNote opens instead of the library")
        XCTAssertNil(model.busy)
    }

    /// P-014: the tour never tells a user whose notes are inside Nib that they survive a reinstall.
    func testSampleNotebookWithTheLibraryInsideWarnsAboutReinstalls() async throws {
        let (h, _, model, _) = make()
        let log = CallLog()
        try fakeSampleCommands(h, log: log)
        XCTAssertTrue(model.placement.isInsideApp)
        model.keepInApp()
        model.confirmKeepInApp()
        for _ in 0..<2 { model.advance() }
        await model.finish(openQuickNote: false)
        let tour = try XCTUnwrap(log.params(CommandIDs.textCreateBox).last?["text"]).decode(RichText.self).plainText
        let safe = SampleNotebook.tips(stylusMode: .pencilOnly, libraryOutside: true)[1]
        let warning = SampleNotebook.tips(stylusMode: .pencilOnly, libraryOutside: false)[1]
        XCTAssertFalse(tour.contains(safe), "notes inside the app are deleted with it")
        XCTAssertFalse(tour.contains("safe when Nib is reinstalled"))
        XCTAssertTrue(tour.contains(warning))
        XCTAssertNotEqual(safe, warning)
    }

    func testAFailedSampleStepIsReportedUnderItsOwnCommand() async throws {
        let (h, nav, model, _) = make(root: iCloudFolder)
        let log = CallLog()
        let created = try JSONValue.parse(#"{"ref": "doc:SAMPLEDOC001", "pages": ["page:SAMPLEDOC001/P1", "page:SAMPLEDOC001/P2"]}"#)
        fake(h, CommandIDs.docCreate, effect: .library, log: log) { _ in created }
        fake(h, CommandIDs.textCreateBox, effect: .edit, log: log) { _ in throw NibError(.invalidParams, "bad frame") }
        let (failures, watch) = watchFailures(h)
        await model.finish(openQuickNote: false)
        XCTAssertEqual(failures.commands, [CommandIDs.textCreateBox], "not doc.create, which worked")
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1, "the library still opens")
        XCTAssertNil(model.busy)
        _ = watch
    }

    func testAFailedQuickNoteFallsBackToTheLibrary() async {
        let (h, nav, model, _) = make(root: iCloudFolder)
        let log = CallLog()
        fake(h, CommandIDs.docQuickNote, effect: .library, log: log) { _ in throw NibError(.unavailable, "No QuickNote") }
        let (failures, watch) = watchFailures(h)
        model.addsSampleNotebook = false
        await model.finish(openQuickNote: true)
        XCTAssertEqual(log.commands, [CommandIDs.docQuickNote])
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1, "the library opens instead")
        XCTAssertEqual(failures.commands, [CommandIDs.docQuickNote])
        XCTAssertNil(model.busy)
        _ = watch
    }

    func testFailingToSaveDoneKeepsTheScreenAndSaysWhy() async {
        let (h, nav, model, _) = make(root: iCloudFolder)
        h.app.bus.hooks.register(CommandHookDescriptor(id: "test.settingsFull", owner: "test",
                                                       commands: [CommandIDs.settingsSet]) { _, params in
            if params["name"]?.stringValue == "onboarding.done" { throw NibError(.unavailable, "Settings can't be saved") }
            return nil
        })
        await model.skip()
        XCTAssertFalse(isDone(h))
        XCTAssertNil(model.busy)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(nav.libraryShows, 0, "onboarding stays up")
        XCTAssertEqual(model.step, .library)

        model.message = nil
        for _ in 0..<3 { model.advance() }
        await model.finish(openQuickNote: true)
        XCTAssertFalse(isDone(h))
        XCTAssertNil(model.busy, "the buttons work again")
        XCTAssertNotNil(model.message)
        XCTAssertEqual(nav.libraryShows, 0)
        XCTAssertEqual(model.step, .done)
    }

    func testFinishWithoutTheSampleOrQuickNoteFeaturesShowsTheLibrary() async {
        let (h, nav, model, _) = make(root: iCloudFolder)
        XCTAssertFalse(model.canOpenQuickNote)
        XCTAssertFalse(model.canCreateSample)
        await model.finish(openQuickNote: true)
        XCTAssertTrue(isDone(h))
        XCTAssertEqual(nav.libraryShows, 1)
    }

    func testSampleNotebookWithoutTextFeaturesIsStillAPlainNotebook() async throws {
        let (h, _, model, _) = make(root: iCloudFolder)
        let log = CallLog()
        let created = try JSONValue.parse(#"{"ref": "doc:SAMPLEDOC001", "pages": ["page:SAMPLEDOC001/P1", "page:SAMPLEDOC001/P2"]}"#)
        fake(h, CommandIDs.docCreate, effect: .library, log: log) { _ in created }
        model.addsSampleNotebook = true
        await model.finish(openQuickNote: false)
        XCTAssertEqual(log.commands, [CommandIDs.docCreate])
        model.addsSampleNotebook = false
        XCTAssertEqual(SampleNotebook.firstPaperPage(["page:D/P1", "page:D/P2"], requested: 2), "page:D/P1")
        XCTAssertEqual(SampleNotebook.firstPaperPage(["page:D/C", "page:D/P1", "page:D/P2"], requested: 2), "page:D/P1")
        XCTAssertNil(SampleNotebook.firstPaperPage([], requested: 2))
    }

    func testSampleNotebookLayoutStaysOnThePage() {
        let cases = [PageSize.a4, PageSize.standard, PageSize(612, 792), PageSize(842, 595), PageSize(300, 400)]
            .flatMap { size in StylusMode.allCases.flatMap { mode in [true, false].map { (size, mode, $0) } } }
        for (size, mode, outside) in cases {
            let tour = SampleNotebook.tourLayout(pageSize: size, stylusMode: mode, libraryOutside: outside)
            XCTAssertLessThanOrEqual(tour.needed, tour.available, "\(size): the estimated tour fits above the handwriting")
            XCTAssertFalse(tour.tips.isEmpty, "\(size)")
            XCTAssertEqual(tour.tips, Array(SampleNotebook.tips(stylusMode: mode, libraryOutside: outside).prefix(tour.tips.count)),
                           "tips go from the end")
            let boxes = SampleNotebook.boxes(pageSize: size, stylusMode: mode, libraryOutside: outside)
            XCTAssertEqual(boxes.count, 2)
            XCTAssertFalse(boxes[1].autoGrow, "the tour box keeps its frame")
            XCTAssertEqual(boxes[1].frame[3], tour.needed)
            for box in boxes {
                let f = box.frame
                XCTAssertGreaterThanOrEqual(f[0], 0)
                XCTAssertGreaterThanOrEqual(f[1], 0)
                XCTAssertLessThanOrEqual(f[0] + f[2], size.width + 0.001, "\(size) \(f)")
                XCTAssertLessThanOrEqual(f[1] + f[3], size.height + 0.001, "\(size) \(f)")
            }
            XCTAssertLessThanOrEqual(boxes[0].frame[1] + boxes[0].frame[3], boxes[1].frame[1], "title above the tour")
            let at = SampleNotebook.handwritingOrigin(pageSize: size, stylusMode: mode, libraryOutside: outside)
            XCTAssertLessThan(at[1] + SampleNotebook.handwritingSize, size.height, "\(size)")
            XCTAssertGreaterThanOrEqual(at[1], boxes[1].frame[1] + boxes[1].frame[3], "\(size): handwriting under the tour")
        }
        let small = SampleNotebook.tourLayout(pageSize: PageSize(300, 400), stylusMode: .pencilOnly, libraryOutside: false)
        XCTAssertEqual(small.fontSize, SampleNotebook.smallestBodySize)
        XCTAssertLessThan(small.tips.count, SampleNotebook.tips(stylusMode: .pencilOnly, libraryOutside: false).count,
                          "a small page drops tips rather than running past the page")
        XCTAssertEqual(SampleNotebook.tourLayout(pageSize: .a4, stylusMode: .pencilOnly, libraryOutside: true).tips.count,
                       SampleNotebook.tips(stylusMode: .pencilOnly, libraryOutside: true).count, "A4 keeps the whole tour")
        for outside in [true, false] {
            let tips = SampleNotebook.tips(stylusMode: .anyInput, libraryOutside: outside).joined(separator: " ")
            XCTAssertFalse(tips.contains("!"), "no exclamation marks in copy")
            XCTAssertFalse(tips.contains("\u{2014}"), "no em dashes in copy")
        }
    }

    // MARK: Steps and layout

    func testStepsRunInTheDesignedOrder() {
        let (_, _, model, _) = make()
        XCTAssertEqual(OnboardingStep.allCases, [.library, .pencil, .assistant, .done])
        model.goBack()
        XCTAssertEqual(model.step, .library)
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .assistant)
        model.goBack()
        XCTAssertEqual(model.step, .pencil)
        model.advance()
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .done, "done is the last step")
    }

    func testCardAndPracticeStripMetrics() {
        XCTAssertEqual(OnboardingLayout.cardWidth(for: 1024), 480, "480 on iPad")
        XCTAssertEqual(OnboardingLayout.cardWidth(for: 390), 358, "the width − 32 on iPhone")
        XCTAssertEqual(OnboardingLayout.cardWidth(for: 20), 0)
        for height in [320.0, 667, 844, 1024, 1366] {
            let pad = OnboardingLayout.stripHeight(for: height, compact: false)
            let phone = OnboardingLayout.stripHeight(for: height, compact: true)
            XCTAssertEqual(pad.truncatingRemainder(dividingBy: 32), 0, "whole rules")
            XCTAssertEqual(phone.truncatingRemainder(dividingBy: 32), 0, "whole rules")
            XCTAssertTrue((128...256).contains(pad), "\(pad)")
            XCTAssertTrue((96...160).contains(phone), "\(phone)")
            XCTAssertLessThanOrEqual(phone, pad)
        }
        XCTAssertEqual(OnboardingLayout.stripHeight(for: 1366, compact: false), 256)
        XCTAssertEqual(OnboardingLayout.stripHeight(for: 844, compact: true), 160)
    }

    /// DESIGN.md §15.7: the screen in Light, Dark and AX3. The practice canvas is UIKit and renders as a placeholder.
    func testEveryStepRendersInLightDarkAndLargeText() {
        let (h, _, model, _) = make(root: iCloudFolder)
        fake(h, CommandIDs.docCreate, effect: .library, log: CallLog())
        for step in OnboardingStep.allCases {
            while model.step != step { model.advance() }
            let images = NibSnapshot.images(OnboardingView(model: model), size: CGSize(width: 820, height: 1180), scale: 1)
            XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases), "\(step)")
            if let dark = images[.dark] {
                XCTAssertEqual(NibSnapshot.pixel(dark, at: CGPoint(x: 4, y: 4)), RGBA(0xFF, 0xFF, 0xFF),
                               "\(step): the paper stays white in dark mode (paper is never inverted)")
            }
            let phone = NibSnapshot.image(OnboardingView(model: model), size: CGSize(width: 390, height: 844),
                                          variant: .largeText, scale: 1)
            XCTAssertNotNil(phone, "\(step) at AX3 on iPhone")
        }
    }
}
