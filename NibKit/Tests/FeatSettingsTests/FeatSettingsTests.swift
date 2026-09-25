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
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
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

    func testSettingsOpenShowsTheRequestedPage() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(app: h.app)
        h.app.ui.activeNavigator = navigator

        let out = try await h.run(SettingsOpen.id, ["page": "settings.stylus"])
        XCTAssertEqual(out["opened"]?.stringValue, "settings")
        XCTAssertEqual(out["page"]?.stringValue, "settings.stylus")
        let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        XCTAssertEqual(root.state.section, .stylus)
        XCTAssertTrue(root.state.detailPath.isEmpty, "a section's only page is its detail")
        XCTAssertEqual(root.state.compactPath.count, 1)

        try await h.run(SettingsOpen.id)
        XCTAssertEqual(navigator.requestedPages, ["settings.stylus", nil])
        let second = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        XCTAssertNil(second.state.section)

        h.app.ui.settingsPages.register(page("about.main", "About Nib", .about, owner: "about"))
        let about = try await h.run(SettingsOpen.id, ["place": "about"])
        XCTAssertEqual(about["page"]?.stringValue, "about.main")
        XCTAssertEqual(navigator.requestedPages.last ?? nil, "about.main")
    }

    func testSettingsOpenMovesSettingsAlreadyOnScreen() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(app: h.app)
        h.app.ui.activeNavigator = navigator
        try await h.run(SettingsOpen.id)
        let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        let window = UIWindow(frame: CGRect(origin: .zero, size: SettingsRootViewController.formSheetSize))
        window.addSubview(root.view)

        let out = try await h.run(SettingsOpen.id, ["page": "settings.language"])
        XCTAssertEqual(out["page"]?.stringValue, "settings.language")
        XCTAssertEqual(navigator.requestedPages, [nil], "the Settings on screen moves; no second one opens")
        XCTAssertEqual(root.state.section, .general)
        XCTAssertEqual(root.state.detailPath.count, 1)
    }

    func testAppMenuPanelsOpenAsSheetsFromTheLibrary() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(app: h.app)
        h.app.ui.activeNavigator = navigator
        var built: [String] = []
        let panels: [(String, String, PanelPlacement)] = [("organize.trash", "organize", .libraryTab),
                                                          ("templates.manage", "templateui", .sheet)]
        for (id, owner, placement) in panels {
            h.app.ui.panels.register(PanelDescriptor(id: id, title: id, icon: "square", placement: placement, order: 10,
                                                     owner: owner, docKinds: nil) { ctx in
                built.append(id)
                XCTAssertNotNil(ctx.navigator)
                return AnyView(EmptyView())
            })
        }
        XCTAssertNil(navigator.session.document, "the app menu lives in the library, with no document open")

        for (place, id) in [("trash", "organize.trash"), ("templates", "templates.manage")] {
            let out = try await h.run(SettingsOpen.id, ["place": .string(place)])
            XCTAssertEqual(out["opened"]?.stringValue, "panel", place)
            XCTAssertEqual(out["panel"]?.stringValue, id, place)
            XCTAssertTrue(navigator.presented is UIHostingController<AnyView>, place)
        }
        XCTAssertEqual(built, ["organize.trash", "templates.manage"])
        XCTAssertTrue(navigator.requestedPages.isEmpty)
    }

    func testSettingsOpenRejectsUnknownPagesAndPlaces() async {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(app: h.app)
        h.app.ui.activeNavigator = navigator
        await assertError(.notFound) { try await h.run(SettingsOpen.id, ["page": "nope.page"]) }
        await assertError(.invalidParams) { try await h.run(SettingsOpen.id, ["place": "attic"]) }
        await assertError(.invalidParams) { try await h.run(SettingsOpen.id, ["place": "attic"], as: .ai("chat")) }
        await assertError(.unavailable) { try await h.run(SettingsOpen.id, ["place": "templates"]) }
        XCTAssertTrue(navigator.requestedPages.isEmpty)

        h.app.ui.activeNavigator = nil
        await assertError(.unavailable) { try await h.run(SettingsOpen.id) }
    }

    func testAppMenuPlacesFindTheScreensOfTheirOwners() {
        let panels = [
            panel("templates.change", owner: "templateui", placement: .sheet, docKinds: [.notebook]),
            panel("templates.manage", owner: "templateui", placement: .sheet),
            panel("sync.status", owner: "syncui", placement: .floating),
            panel("library.trash", owner: "organize", placement: .libraryTab, icon: "trash"),
        ]
        let pages = [page("about.main", "About Nib", .about, owner: "about")]
        XCTAssertEqual(AppMenuPlace.settings.resolve(panels: [], pages: []), .settings(nil))
        XCTAssertEqual(AppMenuPlace.systemNotifications.resolve(panels: [], pages: []), .systemNotifications)
        XCTAssertEqual(AppMenuPlace.templates.resolve(panels: panels, pages: pages), .panel("templates.manage"))
        XCTAssertEqual(AppMenuPlace.cloudBackup.resolve(panels: panels, pages: pages), .panel("sync.status"))
        XCTAssertEqual(AppMenuPlace.trash.resolve(panels: panels, pages: pages), .panel("library.trash"))
        XCTAssertEqual(AppMenuPlace.about.resolve(panels: panels, pages: pages), .settings("about.main"))
        XCTAssertEqual(AppMenuPlace.cloudBackup.resolve(panels: [], pages: [page("backup.main", "Backup", .sync, owner: "backup")]),
                       .settings("backup.main"), "without a sync panel, Cloud & Backup opens the Sync section")
        for place in [AppMenuPlace.templates, .cloudBackup, .trash, .about] {
            XCTAssertNil(place.resolve(panels: [], pages: []), place.rawValue)
        }
    }

    func testAppMenuEntriesRunSettingsOpenWithValidParams() throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let items = h.app.ui.menus.all.filter { $0.location == .appMenu }
        XCTAssertEqual(items.map(\.id), ["settings.menu.settings", "settings.menu.templates", "settings.menu.cloudBackup",
                                         "settings.menu.trash", "settings.menu.about"])
        let descriptor = try XCTUnwrap(h.app.commands.descriptor(SettingsOpen.id))
        let context = MenuContext(app: h.app)
        for item in items {
            XCTAssertEqual(item.command, SettingsOpen.id)
            XCTAssertEqual(descriptor.params.validate(item.params(context)), [], item.id)
        }
        XCTAssertEqual(h.app.ui.menuItems(.appMenu, context).map(\.id), ["settings.menu.settings"],
                       "places whose screens are not installed stay hidden")
        h.app.ui.settingsPages.register(page("about.main", "About Nib", .about, owner: "about"))
        XCTAssertEqual(h.app.ui.menuItems(.appMenu, context).map(\.id), ["settings.menu.settings", "settings.menu.about"])
        XCTAssertEqual(h.app.content.keyCommands.get("settings.open")?.command, SettingsOpen.id)
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

    private func assertError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> JSONValue) async {
        do {
            _ = try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let error as NibError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
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

/// Stands in for the shell's window: records `showSettings` and builds the screen the way the shell does.
@MainActor
private final class RecordingNavigator: SceneNavigator {
    let app: NibApp
    let session = EditorSession()
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    var rootViewController: UIViewController? { nil }
    private(set) var requestedPages: [String?] = []
    private(set) var presented: UIViewController?

    init(app: NibApp) {
        self.app = app
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}

    func showSettings(page: String?) {
        requestedPages.append(page)
        presented = app.ui.screens.settingsRoot?(app, self)
    }

    func presentModal(_ viewController: UIViewController) {
        presented = viewController
    }
}
