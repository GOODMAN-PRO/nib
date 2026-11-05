import XCTest
import Combine
import SwiftUI
import UIKit
import UserNotifications
import NibContracts
import NibDesign
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

    func testPageDraftSurvivesWidthAndDynamicTypeBreakpoints() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let probe = SettingsDraftProbe()
        h.app.ui.settingsPages.register(SettingsPageDescriptor(
            id: "test.draft", title: "Draft", icon: "gearshape", section: .sync, order: 0, owner: "test"
        ) { _ in AnyView(SettingsDraftProbeView(probe: probe)) })
        let state = SettingsNavigationState()
        state.show(page: "test.draft", in: SettingsCatalog(pages: h.app.ui.settingsPages.all))
        let root = SettingsRootView(app: h.app, state: state, onDone: {})
        let host = UIHostingController(rootView: root.environment(\.dynamicTypeSize, .large).ignoresSafeArea())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var enteredDraft = false
        for (width, size) in [(CGFloat(900), DynamicTypeSize.large), (390, .large),
                              (900, .large), (900, .accessibility5), (900, .large)] {
            window.frame.size.width = width
            host.view.frame = window.bounds
            host.traitOverrides.horizontalSizeClass = width < 600 ? .compact : .regular
            host.rootView = root.environment(\.dynamicTypeSize, size).ignoresSafeArea()
            for _ in 0..<10 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(probe.models.count, 1, "resizing must not create another page model")
            let draft = try XCTUnwrap(probe.models.last)
            let field = try XCTUnwrap(settingsSubviews(host.view).compactMap { $0 as? UITextField }
                .first { $0.isSecureTextEntry })
            if !enteredDraft {
                field.text = "unsaved password"
                field.sendActions(for: .editingChanged)
                try await Task.sleep(for: .milliseconds(20))
                enteredDraft = true
            }
            XCTAssertEqual(draft.password, "unsaved password")
            XCTAssertEqual(field.text, "unsaved password", "the visible field must retain the draft")
        }
    }

    func testSinglePageContentAfterSidebarSelection() async throws {
        try await assertSinglePageContent(route: .sidebar)
    }

    func testSinglePageContentAfterSettingsOpenPage() async throws {
        try await assertSinglePageContent(route: .commandPage)
    }

    func testSinglePageContentAfterSettingsOpenPlace() async throws {
        try await assertSinglePageContent(route: .commandPlace)
    }

    func testSinglePageContentAfterSearch() async throws {
        try await assertSinglePageContent(route: .search)
        try await assertSinglePageContent(route: .sidebarSearch)
    }

    func testSinglePageContentAfterCommandComma() async throws {
        try await assertSinglePageContent(route: .shortcut)
    }

    func testSinglePageContentAfterRestoringSectionWithoutAPush() async throws {
        try await assertSinglePageContent(route: .restored)
    }

    func testSinglePageContentOnInitialPageAndDefaultSection() async throws {
        try await assertSinglePageContent(route: .initialPage)
        try await assertSinglePageContent(route: .defaultSection)
    }

    func testSinglePageSectionsRenderDirectlyAndCompactIndexRemainsReachable() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let probe = SettingsDraftProbe()
        registerDraftPage(h, probe: probe, id: "test.plugins", section: .plugins)
        registerDraftPage(h, probe: probe, id: "test.bridge", section: .bridge)
        let root = SettingsRootViewController(app: h.app, initialPage: nil)
        let hosted = try HostedSettings(root, width: 900)
        defer { hosted.close() }
        for section in [SettingsSection.plugins, .bridge] {
            root.state.select(section)
            try await hosted.settle()
            try assertSolePageIsVisible(hosted)
            hosted.resize(width: 390)
            try await hosted.settle()
            try assertSolePageIsVisible(hosted)
            root.state.showIndex() // The compact Settings back button's action.
            try await hosted.settle()
            XCTAssertTrue(hosted.draftFields.isEmpty)
            XCTAssertFalse(hosted.lists.isEmpty, "returning to the index must expose the page rows")
            root.show(page: section == .plugins ? "test.plugins" : "test.bridge")
            try await hosted.settle()
            try assertSolePageIsVisible(hosted)
            hosted.resize(width: 900)
            try await hosted.settle()
            try assertSolePageIsVisible(hosted)
        }
    }

    func testMultiPageSectionKeepsItsListAndPushedDraftAcrossSizeClasses() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let probe = SettingsDraftProbe()
        registerDraftPage(h, probe: probe)
        h.app.ui.settingsPages.register(page("test.other", "Other", .plugins, owner: "test"))
        let root = SettingsRootViewController(app: h.app, initialPage: nil)
        root.state.select(.plugins)
        let hosted = try HostedSettings(root, width: 900)
        defer { hosted.close() }
        for width in [CGFloat(900), 390, 900] {
            hosted.resize(width: width)
            try await hosted.settle()
            XCTAssertFalse(hosted.lists.isEmpty, "multiple pages must remain rows")
            XCTAssertTrue(hosted.draftFields.isEmpty, "no page should be open before choosing a row")
        }
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        let draftPage = try XCTUnwrap(catalog.page("test.draft"))
        SettingsPageRow(page: draftPage, catalog: catalog, state: root.state).open()
        try await hosted.settle()
        try await hosted.enterDraft("multi-page draft")
        for width in [CGFloat(390), 900] {
            hosted.resize(width: width)
            try await hosted.settle()
            XCTAssertEqual(probe.models.count, 1)
            XCTAssertEqual(probe.models.first?.password, "multi-page draft")
            XCTAssertEqual(hosted.draftFields.first?.text, "multi-page draft")
        }
        root.state.compactPath = [] // Native Back returns to the section's rows.
        try await hosted.settle()
        XCTAssertFalse(hosted.lists.isEmpty)
        XCTAssertTrue(hosted.draftFields.isEmpty)
    }

    func testHostedSinglePageInSecondWindowDoesNotChangeFirstWindowDraft() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let probe = SettingsDraftProbe()
        registerDraftPage(h, probe: probe)
        registerDraftPage(h, probe: probe, id: "test.bridge", section: .bridge)
        let first = RecordingNavigator(h)
        h.app.ui.activeNavigator = first
        try await h.run(CommandIDs.settingsOpen, ["page": "test.draft"])
        let firstRoot = try XCTUnwrap(first.presented as? SettingsRootViewController)
        first.rootViewController = firstRoot
        let firstHost = try HostedSettings(firstRoot, width: 900)
        defer { firstHost.close() }
        try await firstHost.settle()
        try assertSolePageIsVisible(firstHost)
        try await firstHost.enterDraft("first window draft")

        let second = RecordingNavigator(h)
        h.app.ui.activeNavigator = second
        try await h.run(CommandIDs.settingsOpen, ["page": "test.bridge"])
        let secondRoot = try XCTUnwrap(second.presented as? SettingsRootViewController)
        second.rootViewController = secondRoot
        let secondHost = try HostedSettings(secondRoot, width: 390)
        defer { secondHost.close() }
        try await secondHost.settle()
        try assertSolePageIsVisible(secondHost)
        try await secondHost.enterDraft("second window draft")
        firstHost.resize(width: 390)
        secondHost.resize(width: 900)
        try await firstHost.settle()
        try await secondHost.settle()
        XCTAssertEqual(firstRoot.state.section, .plugins)
        XCTAssertEqual(secondRoot.state.section, .bridge)
        XCTAssertEqual(firstHost.draftFields.first?.text, "first window draft")
        XCTAssertEqual(secondHost.draftFields.first?.text, "second window draft")
        XCTAssertEqual(probe.models.count, 2)
        XCTAssertEqual(first.requestedPages, ["test.draft"])
        XCTAssertEqual(second.requestedPages, ["test.bridge"])
    }

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

    func testStylusPageRowOpensInputSettingsAlongsideHardwarePage() throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        // The full app registers F043's hardware page in this section too. Testing only F027 would
        // show the input page directly and miss the page-row navigation used by real iPad users.
        h.app.ui.settingsPages.register(page("pencilhw.settings", "Apple Pencil", .stylus,
                                            order: 0, owner: "pencilhw"))
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        let state = SettingsNavigationState()
        state.select(.stylus)
        XCTAssertEqual(catalog.group(.stylus)?.pages.count, 2)
        XCTAssertTrue(state.detailPath.isEmpty)

        let inputPage = try XCTUnwrap(catalog.page(CoreSettingsPages.stylus))
        let row = SettingsPageRow(page: inputPage, catalog: catalog, state: state)
        row.open() // The same action bound to the full-width page button.
        XCTAssertEqual(state.section, .stylus)
        XCTAssertEqual(state.detailPath, [SettingsPageLink(id: CoreSettingsPages.stylus)])
        XCTAssertEqual(state.compactPath, [SettingsPageLink(id: CoreSettingsPages.stylus)])

        // Back, then choose the same page again; section changes must not leave stale destinations.
        state.detailPath.removeLast()
        row.open()
        XCTAssertEqual(state.detailPath, [SettingsPageLink(id: CoreSettingsPages.stylus)])
        state.select(.general)
        XCTAssertTrue(state.detailPath.isEmpty)
    }

    func testSearchPageRowOpensStylusPageInCompactLayoutWhenSectionHasOnlyOnePage() throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
        let state = SettingsNavigationState()
        state.query = "palm"
        let result = try XCTUnwrap(catalog.search(state.query).first)
        SettingsPageRow(page: result, catalog: catalog, state: state,
                        subtitle: result.section.title).open()
        XCTAssertEqual(state.section, .stylus)
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.detailPath.isEmpty, "the regular layout already displays the only page")
        XCTAssertTrue(state.compactPath.isEmpty,
                      "a sole page is root content in both layouts, with no intermediate list or push")
    }

    func testPencilOnlySelectionFromAnyInputPersistsThroughSettingsCommand() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        try await h.run(CommandIDs.settingsSet, ["name": .string(NibSettings.stylusMode.name), "value": "anyInput"])
        let model = SettingsModel(app: h.app)
        XCTAssertEqual(model.value(NibSettings.stylusMode), .anyInput)
        let written = expectation(forNotification: SettingsStore.didChange, object: h.app.settings)
        model.change(NibSettings.stylusMode, to: .pencilOnly)
        XCTAssertEqual(model.value(NibSettings.stylusMode), .pencilOnly,
                       "the selected row updates while the command is in flight")
        await fulfillment(of: [written], timeout: 2)
        XCTAssertEqual(h.app.settings.get(NibSettings.stylusMode), .pencilOnly)
        XCTAssertEqual(SettingsModel(app: h.app).value(NibSettings.stylusMode), .pencilOnly,
                       "reopening the page must retain the input choice")
    }

    // MARK: settings.open and the app menu

    func testSettingsShortcutInSwiftUIChromeOpensInvokingSceneFromEveryDocumentKind() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        let overlay = try XCTUnwrap(h.app.ui.chromeOverlays.get(SettingsChromeShortcut.overlayID))
        XCTAssertNil(overlay.docKinds, "Settings must also be reachable from the library and text documents")
        let kinds: [DocumentKind?] = [nil] + DocumentKind.allCases.map { Optional($0) }
        for kind in kinds {
            for editing in [false, true] {
                h.session.document = kind == nil ? nil : Fixtures.docID
                h.session.isEditingText = editing
                let context = ChromeContext(app: h.app, session: h.session, navigator: navigator, kind: kind)
                let descriptor = try XCTUnwrap(SettingsChromeShortcut.descriptor(in: context))
                XCTAssertEqual(descriptor.shortcut, KeyShortcut(",", .command))
                let opened = expectation(description: "Settings opened from SwiftUI chrome")
                navigator.onSettings = { opened.fulfill() }
                h.app.ui.activeNavigator = nil
                SettingsChromeShortcut.perform(in: context)
                await fulfillment(of: [opened], timeout: 2)
                XCTAssertTrue(h.app.ui.activeNavigator === navigator)
                XCTAssertTrue(h.app.services.sessions.active === h.session)
                XCTAssertTrue(navigator.presented is SettingsRootViewController)
            }
        }
    }

    func testSettingsChromeShortcutRevalidatesRegistrySceneAndModal() throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        let context = ChromeContext(app: h.app, session: h.session, navigator: navigator, kind: .notebook)
        let root = SettingsModalStandIn()
        root.modal = UIViewController()
        navigator.rootViewController = root
        h.app.ui.activeNavigator = nil
        SettingsChromeShortcut.perform(in: context)
        XCTAssertNil(h.app.ui.activeNavigator, "A background Settings binding must not act through a modal")
        root.modal = nil

        let other = Harness(features: [FeatSettingsFeature.self])
        SettingsChromeShortcut.perform(in: ChromeContext(app: h.app, session: other.session,
                                                         navigator: navigator, kind: .notebook))
        XCTAssertNil(h.app.ui.activeNavigator, "A stale binding cannot borrow another scene's navigator")

        h.app.content.keyCommands.register(KeyCommandDescriptor(id: "test.comma", title: "Document action",
            shortcut: AppMenu.settingsShortcut, command: "test.action", scope: .document, owner: "test"))
        XCTAssertNil(SettingsChromeShortcut.descriptor(in: context), "The registry's narrower route wins")
        SettingsChromeShortcut.perform(in: context)
        XCTAssertNil(h.app.ui.activeNavigator)
        XCTAssertTrue(navigator.requestedPages.isEmpty)
    }

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
        XCTAssertTrue(root.state.compactPath.isEmpty, "the sole page is also the compact root content")

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

    func testSettingsOpenInAnotherWindowDoesNotChangeTheFirstWindow() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let first = RecordingNavigator(h)
        h.app.ui.activeNavigator = first
        try await h.run(CommandIDs.settingsOpen, ["page": "settings.stylus"])
        let root = try XCTUnwrap(first.presented as? SettingsRootViewController)
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 760, height: 706))
        firstWindow.addSubview(root.view)
        first.rootViewController = root

        let second = RecordingNavigator(h)
        let secondRoot = UIViewController()
        let secondWindow = UIWindow(frame: firstWindow.frame)
        secondWindow.addSubview(secondRoot.view)
        second.rootViewController = secondRoot
        h.app.ui.activeNavigator = second
        let out = try await h.run(CommandIDs.settingsOpen, ["page": "settings.language"])
        XCTAssertEqual(out["opened"]?.stringValue, "settings")
        XCTAssertEqual(second.requestedPages, ["settings.language"])
        XCTAssertEqual(root.state.section, .stylus)
        let shown = try XCTUnwrap(second.presented as? SettingsRootViewController)
        XCTAssertEqual(shown.state.section, .general)
        XCTAssertEqual(shown.state.detailPath.count, 1)
        XCTAssertEqual(first.requestedPages, ["settings.stylus"])
        withExtendedLifetime((firstWindow, secondWindow)) {}
    }

    func testSettingsOpenMovesSettingsAlreadyOnScreen() async throws {
        let h = Harness(features: [FeatSettingsFeature.self])
        let navigator = RecordingNavigator(h)
        h.app.ui.activeNavigator = navigator
        try await h.run(CommandIDs.settingsOpen)
        let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 760, height: 706))
        window.addSubview(root.view)
        navigator.rootViewController = root

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

    func testEveryPostureDrawingFitsInsideItsTile() {
        for size in [CGSize(width: 44, height: 72), CGSize(width: 72, height: 72),
                     CGSize(width: 120, height: 72)] {
            let reach = PostureIllustrationGeometry.reach(in: size)
            let tip = CGPoint(x: size.width / 2, y: size.height / 2)
            let content = CGRect(origin: .zero, size: size).insetBy(dx: NibSpacing.s, dy: NibSpacing.s)
            for posture in WritingPosture.all {
                let palm = posture.palmAngle * .pi / 180
                let lean = posture.penAngle * .pi / 180
                let penEnd = CGPoint(x: tip.x + CGFloat(cos(lean)) * reach * 1.3,
                                     y: tip.y + CGFloat(sin(lean)) * reach * 1.3)
                XCTAssertTrue(content.contains(penEnd), posture.title)
                for degree in stride(from: 0, to: 360, by: 15) {
                    let angle = Double(degree) * .pi / 180
                    let x = reach + reach * 0.55 * CGFloat(cos(angle))
                    let y = reach * 0.4 * CGFloat(sin(angle))
                    let edge = CGPoint(x: tip.x + x * CGFloat(cos(palm)) - y * CGFloat(sin(palm)),
                                       y: tip.y + x * CGFloat(sin(palm)) + y * CGFloat(cos(palm)))
                    XCTAssertTrue(content.contains(edge), posture.title)
                }
            }
        }
        XCTAssertEqual(PostureIllustrationGeometry.reach(in: .zero), 0)
        XCTAssertEqual(PostureIllustrationGeometry.reach(in: CGSize(width: 8, height: 8)), 0)
    }

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

    private enum SinglePageRoute: Equatable {
        case sidebar, commandPage, commandPlace, search, sidebarSearch, shortcut, restored, initialPage, defaultSection
    }

    private func assertSinglePageContent(route: SinglePageRoute) async throws {
        for width in [CGFloat(900), 390] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let h = Harness(features: [FeatSettingsFeature.self])
                let probe = SettingsDraftProbe()
                let usesDefaultSection = route == .shortcut || route == .defaultSection
                if usesDefaultSection {
                    for page in h.app.ui.settingsPages.all where page.section == .general {
                        h.app.ui.settingsPages.unregister(id: page.id)
                    }
                }
                let section: SettingsSection = usesDefaultSection ? .general : .plugins
                registerDraftPage(h, probe: probe, section: section)
                let navigator = RecordingNavigator(h)
                h.app.ui.activeNavigator = navigator
                if route == .shortcut {
                    let key = try XCTUnwrap(KeyCommandRouting.unhandledPress(AppMenu.settingsShortcut,
                        descriptors: h.app.content.keyCommands.all, in: KeyCommandContext(docKind: nil)))
                    try await h.run(key.command, key.resolvedParams(for: h.session))
                } else if route == .initialPage {
                    try await h.run(CommandIDs.settingsOpen, ["page": "test.draft"])
                } else {
                    try await h.run(CommandIDs.settingsOpen)
                }
                let root = try XCTUnwrap(navigator.presented as? SettingsRootViewController)
                navigator.rootViewController = root
                if route == .restored {
                    root.state.section = section // Restored selection, deliberately no navigation push.
                }
                let hosted = try HostedSettings(root, width: width, style: style)
                defer { hosted.close() }
                try await hosted.settle()
                let catalog = SettingsCatalog(pages: h.app.ui.settingsPages.all)
                switch route {
                case .sidebar:
                    root.state.select(section) // The exact action used by SettingsSidebar's section button.
                case .commandPage:
                    try await h.run(CommandIDs.settingsOpen, ["page": "test.draft"])
                case .commandPlace:
                    try await h.run(CommandIDs.settingsOpen, ["place": "settings", "page": "test.draft"])
                case .search, .sidebarSearch:
                    root.state.query = "Draft"
                    let result = try XCTUnwrap(catalog.search(root.state.query).first)
                    if route == .sidebarSearch {
                        root.state.show(page: result.id, in: catalog)
                    } else {
                        SettingsPageRow(page: result, catalog: catalog, state: root.state).open()
                    }
                    XCTAssertTrue(root.state.query.isEmpty)
                case .shortcut, .restored, .initialPage, .defaultSection:
                    break
                }
                try await hosted.settle()
                try assertSolePageIsVisible(hosted)
                XCTAssertEqual(probe.models.count, 1)
                XCTAssertTrue(root.state.compactPath.isEmpty, "content must not depend on a push")
            }
        }
    }

    private func registerDraftPage(_ h: Harness, probe: SettingsDraftProbe, id: String = "test.draft",
                                   section: SettingsSection = .plugins) {
        h.app.ui.settingsPages.register(SettingsPageDescriptor(
            id: id, title: "Draft", icon: "gearshape", section: section, order: 0, owner: "test"
        ) { _ in AnyView(SettingsDraftProbeView(probe: probe)) })
    }

    private func assertSolePageIsVisible(_ hosted: HostedSettings, file: StaticString = #filePath,
                                       line: UInt = #line) throws {
        let field = try XCTUnwrap(hosted.draftFields.first, "the page's own content must be in the hierarchy",
                                  file: file, line: line)
        XCTAssertTrue(field.window === hosted.window, file: file, line: line)
        let frame = field.convert(field.bounds, to: hosted.host.view)
        XCTAssertTrue(hosted.host.view.bounds.intersects(frame), file: file, line: line)
        var ancestor: UIView? = field
        while let view = ancestor {
            XCTAssertFalse(view.isHidden, file: file, line: line)
            ancestor = view.superview
        }
        XCTAssertTrue(hosted.lists.isEmpty, "there must be no intermediate one-row list", file: file, line: line)
    }

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

/// Hosts the production controller and its SwiftUI root, including the router's visible-window check.
@MainActor
private final class HostedSettings {
    let root: SettingsRootViewController
    let host: UIHostingController<SettingsRootView>
    let window: UIWindow

    init(_ root: SettingsRootViewController, width: CGFloat,
         style: UIUserInterfaceStyle = .light) throws {
        self.root = root
        root.loadViewIfNeeded()
        let hostingController = try XCTUnwrap(root.children.compactMap { $0 as? UIHostingController<SettingsRootView> }.first)
        hostingController.safeAreaRegions = [] // Ignore the test window's safe area, including at narrow widths.
        host = hostingController
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = root
        window.makeKeyAndVisible()
        resize(width: width)
    }

    var draftFields: [UITextField] {
        settingsSubviews(host.view).compactMap { $0 as? UITextField }.filter { $0.isSecureTextEntry }
    }

    var lists: [UIView] {
        settingsSubviews(host.view).filter { $0 is UICollectionView || $0 is UITableView }
    }

    func resize(width: CGFloat) {
        window.frame.size.width = width
        root.view.frame = window.bounds
        host.view.frame = root.view.bounds
        host.traitOverrides.horizontalSizeClass = width < 600 ? .compact : .regular
        host.view.setNeedsLayout()
    }

    func settle() async throws {
        for _ in 0..<25 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func enterDraft(_ text: String) async throws {
        let field = try XCTUnwrap(draftFields.first)
        field.text = text
        field.sendActions(for: .editingChanged)
        try await settle()
        XCTAssertEqual(field.text, text)
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func settingsSubviews(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { settingsSubviews($0) }
}

@MainActor
private final class SettingsDraftProbe {
    var models: [SettingsDraftModel] = []
}

@MainActor
private final class SettingsDraftModel: ObservableObject {
    @Published var password = ""
    init(probe: SettingsDraftProbe) { probe.models.append(self) }
}

@MainActor
private struct SettingsDraftProbeView: View {
    @StateObject private var model: SettingsDraftModel
    init(probe: SettingsDraftProbe) {
        _model = StateObject(wrappedValue: SettingsDraftModel(probe: probe))
    }
    var body: some View { SecureField("Password", text: $model.password) }
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
private final class SettingsModalStandIn: UIViewController {
    var modal: UIViewController?
    override var presentedViewController: UIViewController? { modal ?? super.presentedViewController }
}

@MainActor
private final class RecordingNavigator: SceneNavigator {
    let app: NibApp
    let session: EditorSession
    var openDocuments: [DocumentID] = []
    var activeDocument: DocumentID?
    var rootViewController: UIViewController?
    var onSettings: (() -> Void)?
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
        defer { onSettings?() }
        requestedPages.append(page)
        presented = app.ui.screens.settingsRoot?(app, self)
    }

    func presentModal(_ viewController: UIViewController) {
        presented = viewController
    }
}
