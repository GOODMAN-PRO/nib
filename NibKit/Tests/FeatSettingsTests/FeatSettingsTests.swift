import XCTest
import Combine
import SwiftUI
import UIKit
import UserNotifications
import NibContracts
import NibTesting
@testable import FeatSettings

@MainActor
final class FeatSettingsTests: XCTestCase {
    func testFeatureID() {
        XCTAssertEqual(FeatSettingsFeature.id, "settings")
    }

    func testCommandsAndSettingsConform() async {
        let problems = await CommandConformance.check(features: [FeatSettingsFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Every value round-trips through SettingsStore

    func testEveryDocumentEditingToggleRoundTripsThroughSettingsStore() async {
        let h = Harness(features: [FeatSettingsFeature.self])
        let model = SettingsModel(app: h.app)
        XCTAssertEqual(DocumentEditingRows.toggles.count, 6)
        for spec in DocumentEditingRows.toggles {
            let flipped = !h.app.settings.get(spec.key)
            let error = await model.set(spec.key, flipped)
            XCTAssertNil(error, spec.key.name)
            XCTAssertEqual(h.app.settings.get(spec.key), flipped, spec.key.name)
            XCTAssertEqual(model.value(spec.key), flipped, spec.key.name)
            await model.set(spec.key, !flipped)
            XCTAssertEqual(h.app.settings.get(spec.key), !flipped, spec.key.name)
        }
    }

    func testChoicesRoundTripThroughSettingsStore() async {
        let h = Harness(features: [FeatSettingsFeature.self])
        let model = SettingsModel(app: h.app)

        await model.set(NibSettings.scrollDirection, .horizontal)
        XCTAssertEqual(h.app.settings.get(NibSettings.scrollDirection), .horizontal)
        await model.set(NibSettings.stylusMode, .anyInput)
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .anyInput)
        await model.set(NibSettings.palmSensitivity, 2)
        XCTAssertEqual(h.app.settings.get(NibSettings.palmSensitivity), 2)
        await model.set(NibSettings.writingPosture, WritingPosture(hand: .left, wrist: .hooked).index)
        XCTAssertEqual(h.app.settings.get(NibSettings.writingPosture), 7)
        await model.set(NibSettings.defaultLanguage, "fr-FR")
        XCTAssertEqual(h.app.settings.get(NibSettings.defaultLanguage), "fr-FR")
        await model.set(NibSettings.authorName, "Ada Lovelace")
        XCTAssertEqual(h.app.settings.get(NibSettings.authorName), "Ada Lovelace")
    }

    func testLeftRightControlsWriteTheStoredBools() async {
        let h = Harness(features: [FeatSettingsFeature.self])
        let model = SettingsModel(app: h.app)
        let side = model.binding(NibSettings.sidebarOnRight, get: { $0 ? SettingsSide.right : .left },
                                 set: { $0 == .right })
        XCTAssertEqual(side.wrappedValue, .left)
        let written = expectation(forNotification: SettingsStore.didChange, object: h.app.settings)
        side.wrappedValue = .right
        XCTAssertEqual(side.wrappedValue, .right, "the control shows the new value before the command lands")
        await fulfillment(of: [written], timeout: 2)
        XCTAssertTrue(h.app.settings.get(NibSettings.sidebarOnRight))
    }

    func testPagesSeeChangesMadeByTheAssistant() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let model = SettingsModel(app: h.app)
        let republished = expectation(description: "open pages redraw")
        republished.assertForOverFulfill = false
        let subscription = model.objectWillChange.sink { republished.fulfill() }
        try await h.run(CommandIDs.settingsSet, ["name": "editing.hideStatusBar", "value": true], as: .ai("chat"))
        await fulfillment(of: [republished], timeout: 2)
        subscription.cancel()
        XCTAssertTrue(model.value(NibSettings.hideStatusBar))
        await assertError(.invalidParams) {
            try await h.run(CommandIDs.settingsSet, ["name": "stylus.posture", "value": 8], as: .ai("chat"))
        }
    }

    // MARK: Sections and search

    func testPagesFromOtherFeaturesAppearInTheirSection() {
        let h = Harness(features: [FeatSettingsFeature.self])
        h.app.ui.settingsPages.register(page("ai.providers", "AI Providers", .ai, owner: "aisettings"))
        h.app.ui.settingsPages.register(page("appearance.main", "Appearance", .general, order: 100, owner: "appearance"))
        h.app.ui.settingsPages.register(page("bridge.pairing", "Bridge", .bridge, owner: "bridgeui"))

        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        XCTAssertEqual(catalog.groups.map(\.section), [.general, .editing, .stylus, .ai, .bridge])
        XCTAssertEqual(catalog.group(.general)?.pages.map(\.id),
                       ["settings.profile", "appearance.main", "settings.language", "settings.notifications"])
        XCTAssertEqual(catalog.group(.editing)?.pages.map(\.id), ["settings.editing"])
        XCTAssertEqual(catalog.group(.stylus)?.pages.map(\.id), ["settings.stylus"])
        XCTAssertEqual(catalog.group(.ai)?.pages.map(\.id), ["ai.providers"])
        XCTAssertNil(catalog.group(.plugins), "empty sections are left out")
    }

    func testSearchFindsPagesByTitleSectionAndKeyword() {
        let h = Harness(features: [FeatSettingsFeature.self])
        XCTAssertTrue(h.app.ui.settingsPages.get(CoreSettingsPages.stylus)?.keywords.contains("palm") == true,
                      "the core pages carry their search words on the descriptor")
        for page in h.app.ui.settingsPages.all {
            XCTAssertFalse(page.keywords.isEmpty, page.id)
            XCTAssertFalse(page.keywords.contains { $0.isEmpty || $0 != $0.trimmingCharacters(in: .whitespaces) }, page.id)
        }
        var backup = page("sync.icloud", "Backup", .sync, owner: "sync")
        backup.keywords = ["iCloud", "WebDAV"]
        h.app.ui.settingsPages.register(backup)
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        XCTAssertEqual(catalog.search("icloud").map(\.id), ["sync.icloud"], "other features' keywords match too")
        XCTAssertEqual(catalog.search("palm").map(\.id), ["settings.stylus"])
        XCTAssertEqual(catalog.search("status bar").map(\.id), ["settings.editing"])
        XCTAssertEqual(catalog.search("LANGUAGE").map(\.id), ["settings.language"])
        XCTAssertEqual(Set(catalog.search("general").map(\.id)),
                       ["settings.profile", "settings.language", "settings.notifications"])
        XCTAssertTrue(catalog.search("   ").isEmpty)
        XCTAssertTrue(catalog.search("quantum").isEmpty)
    }

    func testShowingAPageSelectsItsSectionAndPushesIt() {
        let h = Harness(features: [FeatSettingsFeature.self])
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        let state = SettingsNavigationState()
        state.query = "lang"
        state.show(page: CoreSettingsPages.language, in: catalog)
        XCTAssertEqual(state.section, .general)
        XCTAssertEqual(state.detailPath.count, 1, "General has three pages, so Language is pushed")
        XCTAssertEqual(state.compactPath.count, 1)
        XCTAssertEqual(state.query, "")
        state.show(page: "missing.page", in: catalog)
        XCTAssertEqual(state.section, .general)
        state.select(.editing)
        XCTAssertEqual(state.section, .editing)
        XCTAssertTrue(state.detailPath.isEmpty)
    }

    // MARK: settings.open and the app menu

    func testUnhandledCommandCommaOpensSettingsFromLibraryAndEveryDocumentKind() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        let contexts = [KeyCommandContext(docKind: nil)] + DocumentKind.allCases.map {
            KeyCommandContext(docKind: $0)
        }
        var expectedPresentations = 0
        for var context in contexts {
            for editingText in [false, true] {
                context.isEditingText = editingText
                let key = try XCTUnwrap(KeyCommandRouting.unhandledPress(KeyShortcut(",", [.command]),
                    descriptors: h.app.content.keyCommands.all, in: context))
                XCTAssertEqual(key.command, CommandIDs.settingsOpen)
                let out = try await h.run(key.command, key.resolvedParams(for: h.session))
                expectedPresentations += 1
                XCTAssertEqual(out["opened"]?.stringValue, "settings")
                XCTAssertEqual(navigator.requestedPages.count, expectedPresentations)
                XCTAssertTrue(navigator.presented is SettingsRootViewController)
                XCTAssertNil(KeyCommandRouting.unhandledPress(KeyShortcut(",", []),
                    descriptors: h.app.content.keyCommands.all, in: context), "typing a comma never opens Settings")
            }
        }
    }

    func testSettingsOpenedFromDocumentExposesSelectionPagesInEditingAndProvidersInAI() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        // Stand-ins for the pages registered by F012, F041 and F086.
        h.app.ui.settingsPages.register(page("transform.snapping", "Alignment and snapping", .editing, owner: "transform"))
        h.app.ui.settingsPages.register(page("layers.settings", "Layers", .editing, owner: "layers"))
        h.app.ui.settingsPages.register(page("ai.providers", "AI Providers", .ai, owner: "aisettings"))
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        let key = try XCTUnwrap(KeyCommandRouting.unhandledPress(KeyShortcut(",", [.command]),
            descriptors: h.app.content.keyCommands.all, in: KeyCommandContext(docKind: .notebook)))
        try await h.run(key.command, key.resolvedParams(for: h.session))
        let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        XCTAssertEqual(catalog.selected(root.state.section)?.section, .general)
        root.state.select(.editing)
        XCTAssertEqual(Set(catalog.selected(root.state.section)?.pages.map(\.id) ?? []),
                       ["settings.editing", "transform.snapping", "layers.settings"])
        for id in ["transform.snapping", "layers.settings"] {
            root.show(page: id)
            XCTAssertEqual(root.state.section, .editing)
            XCTAssertEqual(root.state.detailPath.count, 1)
            XCTAssertEqual(root.state.compactPath.count, 1)
        }
        root.state.select(.ai)
        XCTAssertEqual(catalog.selected(root.state.section)?.pages.map(\.id), ["ai.providers"])
    }

    func testSettingsOpenShowsTheRequestedPage() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator

        let out = try await h.run(CommandIDs.settingsOpen, ["page": "settings.stylus"])
        XCTAssertEqual(out["opened"]?.stringValue, "settings")
        XCTAssertEqual(out["page"]?.stringValue, "settings.stylus")
        let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        XCTAssertEqual(root.state.section, .stylus)
        XCTAssertTrue(root.state.detailPath.isEmpty, "a section's only page is its detail")
        XCTAssertEqual(root.state.compactPath.count, 1)

        try await h.run(CommandIDs.settingsOpen)
        XCTAssertEqual(navigator.requestedPages, ["settings.stylus", nil])
        let second = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        XCTAssertNil(second.state.section)

        let place = try await h.run(CommandIDs.settingsOpen, ["place": "settings", "page": "settings.editing"])
        XCTAssertEqual(place["opened"]?.stringValue, "settings")
        XCTAssertEqual(place["page"]?.stringValue, "settings.editing")
        XCTAssertEqual(navigator.requestedPages.last ?? nil, "settings.editing")
        XCTAssertEqual(navigator.libraryShown, 0)
    }

    func testSettingsOpenMovesSettingsAlreadyOnScreen() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        try await h.run(CommandIDs.settingsOpen)
        let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 760, height: 706))
        window.addSubview(root.view)

        let out = try await h.run(CommandIDs.settingsOpen, ["page": "settings.language"])
        XCTAssertEqual(out["page"]?.stringValue, "settings.language")
        XCTAssertEqual(navigator.requestedPages, [nil], "the Settings on screen moves; no second one opens")
        XCTAssertEqual(root.state.section, .general)
        XCTAssertEqual(root.state.detailPath.count, 1)
    }

    func testAppMenuPanelsOpenThroughPanelOpenFromTheLibrary() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        let panelOpen = PanelOpenStandIn(h)
        registerPlacePanels(h)
        h.session.document = nil  // the app menu lives in the library

        for (place, id) in placePanels {
            let out = try await h.run(CommandIDs.settingsOpen, ["place": .string(place)])
            XCTAssertEqual(out["opened"]?.stringValue, "panel", place)
            XCTAssertEqual(out["panel"]?.stringValue, id, place)
            XCTAssertNil(out["page"]?.stringValue, place)
        }
        XCTAssertEqual(panelOpen.calls, placePanels.map { PanelOpenStandIn.Call(id: $0.1, inDocument: false) },
                       "every place goes through panel.open, which hands it to the library")
        XCTAssertNil(navigator.presented, "settings.open presents nothing itself")
        XCTAssertTrue(navigator.requestedPages.isEmpty)
        XCTAssertEqual(navigator.libraryShown, 0)
    }

    func testAppMenuPanelsFromADocumentGoToTheLibraryOnlyForLibraryTabs() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        let panelOpen = PanelOpenStandIn(h)
        registerPlacePanels(h)
        XCTAssertNotNil(h.session.document)

        try await h.run(CommandIDs.settingsOpen, ["place": "templates"], as: .ai("chat"))
        XCTAssertEqual(panelOpen.calls, [.init(id: PanelIDs.templates, inDocument: true)],
                       "a sheet opens over the document")
        XCTAssertEqual(navigator.libraryShown, 0)

        let trash = try await h.run(CommandIDs.settingsOpen, ["place": "trash"])
        XCTAssertEqual(trash["panel"]?.stringValue, PanelIDs.trash)
        XCTAssertEqual(navigator.libraryShown, 1, "Trash is a library tab: the window shows the library first")
        XCTAssertEqual(panelOpen.calls.last, .init(id: PanelIDs.trash, inDocument: false))
        XCTAssertNil(navigator.presented)
    }

    func testAppMenuPanelErrorsComeFromPanelOpen() async {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        registerPlacePanels(h)
        await assertError(.unavailable, "without panel.open (F017 not installed) nothing can show the panel") {
            try await h.run(CommandIDs.settingsOpen, ["place": "about"])
        }
        XCTAssertNil(navigator.presented, "and settings.open does not present it instead")
    }

    func testSettingsOpenRejectsUnknownPagesAndPlaces() async {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        await assertError(.notFound) { try await h.run(CommandIDs.settingsOpen, ["page": "nope.page"]) }
        await assertError(.invalidParams) { try await h.run(CommandIDs.settingsOpen, ["place": "attic"]) }
        await assertError(.invalidParams) { try await h.run(CommandIDs.settingsOpen, ["place": "attic"], as: .ai("chat")) }
        _ = PanelOpenStandIn(h)
        await assertError(.unavailable) { try await h.run(CommandIDs.settingsOpen, ["place": "templates"]) }
        XCTAssertTrue(navigator.requestedPages.isEmpty)

        h.app.ui.activeNavigator = nil
        await assertError(.unavailable) { try await h.run(CommandIDs.settingsOpen) }
    }

    func testAppMenuPlacesOpenTheWellKnownPanels() {
        XCTAssertEqual(AppMenuPlace.settings.target, .settings)
        XCTAssertEqual(AppMenuPlace.systemNotifications.target, .systemNotifications)
        XCTAssertEqual(AppMenuPlace.templates.target, .panel(PanelIDs.templates))
        XCTAssertEqual(AppMenuPlace.cloudBackup.target, .panel(PanelIDs.cloudBackup))
        XCTAssertEqual(AppMenuPlace.trash.target, .panel(PanelIDs.trash))
        XCTAssertEqual(AppMenuPlace.about.target, .panel(PanelIDs.about))

        let h = Harness(features: [FeatSettingsFeature.self])
        registerPlacePanels(h)
        XCTAssertFalse(AppMenuPlace.about.isAvailable(in: h.app), "no panel.open, no way to show it")
        _ = PanelOpenStandIn(h)
        for place in AppMenuPlace.allCases {
            XCTAssertTrue(place.isAvailable(in: h.app), place.rawValue)
        }
        h.app.ui.panels.unregister(id: PanelIDs.about)
        XCTAssertFalse(AppMenuPlace.about.isAvailable(in: h.app))
        XCTAssertTrue(AppMenuPlace.settings.isAvailable(in: h.app))
    }

    func testAppMenuEntriesRunSettingsOpenWithValidParams() throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let items = h.app.ui.menus.all.filter { $0.location == .appMenu }
        XCTAssertEqual(items.map(\.id), ["settings.menu.settings", "settings.menu.templates", "settings.menu.cloudBackup",
                                         "settings.menu.trash", "settings.menu.about"])
        XCTAssertEqual(SettingsOpen.descriptor.id, CommandIDs.settingsOpen)
        let descriptor = try XCTUnwrap(h.app.commands.descriptor(CommandIDs.settingsOpen))
        let context = MenuContext(app: h.app)
        for item in items {
            XCTAssertEqual(item.command, CommandIDs.settingsOpen)
            XCTAssertEqual(descriptor.params.validate(item.params(context)), [], item.id)
        }
        XCTAssertEqual(h.app.ui.menuItems(.appMenu, context).map(\.id), ["settings.menu.settings"],
                       "places whose screens are not installed stay hidden")
        _ = PanelOpenStandIn(h)
        h.app.ui.panels.register(panel(PanelIDs.about, owner: "about", placement: .sheet))
        XCTAssertEqual(h.app.ui.menuItems(.appMenu, context).map(\.id), ["settings.menu.settings", "settings.menu.about"])
        XCTAssertEqual(items.first?.shortcut, KeyShortcut(",", [.command]), "⌘, shows beside Settings")
        let key = try XCTUnwrap(h.app.content.keyCommands.get(CommandIDs.settingsOpen))
        XCTAssertEqual(key.command, CommandIDs.settingsOpen)
        XCTAssertEqual(key.shortcut, KeyShortcut(",", [.command]))
        XCTAssertEqual(key.scope, .global)
    }

    // MARK: Stylus and language

    func testWritingPosturesCoverTheEightStoredValues() throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let posture = try XCTUnwrap(h.app.settings.descriptor(NibSettings.writingPosture.name)).schema
        let sensitivity = try XCTUnwrap(h.app.settings.descriptor(NibSettings.palmSensitivity.name)).schema

        XCTAssertEqual(WritingPosture.all.map(\.index), Array(0...7))
        XCTAssertEqual(Set(WritingPosture.all.map(\.title)).count, 8)
        for p in WritingPosture.all {
            XCTAssertEqual(WritingPosture(index: p.index), p)
            XCTAssertEqual(posture.validate(.number(Double(p.index))), [])
            let mirror = WritingPosture(hand: p.hand == .right ? .left : .right, wrist: p.wrist)
            XCTAssertEqual(p.palmAngle + mirror.palmAngle, 180, accuracy: 0.001, "a left hand mirrors a right hand")
            XCTAssertEqual(cos(p.palmAngle * .pi / 180) > 0, p.hand == .right, "the palm rests on the hand's side: \(p.title)")
        }
        XCTAssertEqual(WritingPosture(index: NibSettings.writingPosture.defaultValue), WritingPosture(hand: .right, wrist: .below))
        XCTAssertEqual(WritingPosture(index: 42).index, 7)
        XCTAssertEqual(WritingPosture(index: -3).index, 0)

        for level in PalmSensitivity.levels {
            XCTAssertEqual(sensitivity.validate(.number(Double(level))), [])
        }
        XCTAssertEqual(Set(PalmSensitivity.levels.map(PalmSensitivity.title)).count, 3)
        XCTAssertEqual(Set(StylusMode.allCases.map(\.title)).count, StylusMode.allCases.count)
    }

    func testProfileSavesTheTrimmedNameOnlyWhenItChanged() {
        XCTAssertEqual(ProfilePage.nameToSave("  Ada Lovelace \n", stored: ""), "Ada Lovelace")
        XCTAssertNil(ProfilePage.nameToSave(" Ada ", stored: "Ada"))
        XCTAssertEqual(ProfilePage.nameToSave("   ", stored: "Ada"), "", "clearing the field clears the name")
    }

    func testNotificationStatusText() async {
        XCTAssertEqual(NotificationsPage.statusText(.authorized), "Allowed")
        XCTAssertEqual(NotificationsPage.statusText(.provisional), "Allowed")
        XCTAssertEqual(NotificationsPage.statusText(.denied), "Off")
        XCTAssertNotNil(NotificationsPage.statusText(.notDetermined))
        XCTAssertNil(NotificationsPage.statusText(nil))
        let status = await SystemNotificationStatus().status()
        XCTAssertNil(status, "hostless tests have no notification centre")
    }

    func testLanguageOptionsKeepTheCurrentValueAndSortByName() {
        let english = Locale(identifier: "en_GB")
        let options = RecognitionLanguages.options(["fr-FR", "en-US", "de-DE", "en-US"], current: "ja-JP", locale: english)
        XCTAssertEqual(options.map(\.id), ["en-US", "fr-FR", "de-DE", "ja-JP"])
        XCTAssertNil(options.first { $0.id == "en-US" }?.nativeName, "English reads the same in English")
        XCTAssertNotNil(options.first { $0.id == "fr-FR" }?.nativeName)
        XCTAssertEqual(RecognitionLanguages.options([], current: "en-US").map(\.id), ["en-US"])
    }

    // MARK: Helpers

    private func assertError(_ code: NibError.Code, _ message: String = "", file: StaticString = #filePath,
                             line: UInt = #line, _ body: () async throws -> JSONValue) async {
        do {
            _ = try await body()
            XCTFail("expected \(code.rawValue) \(message)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, "\(message) \(error.message)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}

private func page(_ id: String, _ title: String, _ section: SettingsSection, order: Int = 10,
                  owner: String) -> SettingsPageDescriptor {
    SettingsPageDescriptor(id: id, title: title, icon: "gearshape", section: section, order: order, owner: owner) { _ in
        AnyView(EmptyView())
    }
}

private func panel(_ id: String, owner: String, placement: PanelPlacement, icon: String = "square",
                   docKinds: Set<DocumentKind>? = nil) -> PanelDescriptor {
    PanelDescriptor(id: id, title: id, icon: icon, placement: placement, order: 10, owner: owner, docKinds: docKinds) { _ in
        AnyView(EmptyView())
    }
}

/// The app menu's places and the panel ids their owners register (contracts-v2 G18).
private let placePanels: [(String, String)] = [("templates", PanelIDs.templates), ("cloudBackup", PanelIDs.cloudBackup),
                                               ("trash", PanelIDs.trash), ("about", PanelIDs.about)]

/// Stand-ins for F045's Manage Templates sheet, F070's Cloud & Backup panel, F020's Trash tab and F098's About page.
@MainActor
private func registerPlacePanels(_ h: Harness) {
    h.app.ui.panels.register(panel(PanelIDs.templates, owner: "templateui", placement: .sheet))
    h.app.ui.panels.register(panel(PanelIDs.cloudBackup, owner: "syncui", placement: .floating))
    h.app.ui.panels.register(panel(PanelIDs.trash, owner: "organize", placement: .libraryTab, icon: "trash"))
    h.app.ui.panels.register(panel(PanelIDs.about, owner: "about", placement: .sheet))
}

/// Stands in for F017's `panel.open`: records which panel was asked for and whether the window showed a document.
@MainActor
private final class PanelOpenStandIn {
    struct Call: Equatable {
        let id: String
        let inDocument: Bool
    }

    private(set) var calls: [Call] = []

    init(_ h: Harness) {
        h.app.commands.register(CommandDescriptor(
            id: CommandIDs.panelOpen, title: "Open Panel", summary: "Stand-in for F017's panel.open.",
            params: .obj(["id": .str()], required: ["id"]), effect: .session, target: .app)) { [weak self] json, ctx in
            let id = json["id"]?.stringValue ?? ""
            self?.calls.append(Call(id: id, inDocument: ctx.activeSession?.document != nil))
            return ["id": .string(id), "placement": "sheet"]
        }
    }
}

/// Stands in for the shell's window: records `showSettings` and builds the screen the way the shell does, and leaves
/// its document for the library on `showLibrary`, as the shell does.
@MainActor
private final class RecordingNavigator: SceneNavigator {
    let app: NibApp
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    var rootViewController: UIViewController? { nil }
    private(set) var requestedPages: [String?] = []
    private(set) var presented: UIViewController?
    private(set) var libraryShown = 0

    init(_ h: Harness) {
        self.app = h.app
        self.session = h.session
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}

    func showLibrary(folder: FolderID?) {
        libraryShown += 1
        session.document = nil
    }

    func showSettings(page: String?) {
        requestedPages.append(page)
        presented = app.ui.screens.settingsRoot?(app, self)
    }

    func presentModal(_ viewController: UIViewController) {
        presented = viewController
    }
}
