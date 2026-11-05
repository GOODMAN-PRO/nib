import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatStudySession

@MainActor
final class PanelEscapeTests: XCTestCase {
    func testOptionsPopoverEscapeClosesOnlyThePopover() async throws {
        var closes = 0
        weak var presented: UIViewController?
        let content = StudyOptionsPanel(onClose: {
            closes += 1
            presented?.dismiss(animated: false)
        }) { Text("Options") }
        let host = UIHostingController(rootView: content)
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = root
        window.isHidden = false
        defer { root.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil }
        host.modalPresentationStyle = .popover
        host.popoverPresentationController?.sourceView = root.view
        host.popoverPresentationController?.sourceRect = CGRect(x: 500, y: 40, width: 44, height: 44)
        presented = host
        root.present(host, animated: false)
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(root.presentedViewController === host)
        XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
        for _ in 0..<100 where root.presentedViewController != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(closes, 1)
        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(window.rootViewController === root)
    }

    func testPracticeScratchSheetPassesModalContextAndEscapePreservesSession() async throws {
        let h = Harness(features: [FeatStudySessionFeature.self])
        h.session.document = Fixtures.studySetID
        let runtime = try XCTUnwrap(h.app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self))
        runtime.now = { 1_700_000_000 }
        let model = runtime.model(app: h.app, doc: Fixtures.studySetID, session: h.session)
        var scratchPresentation: PanelPresentation?
        // The actual scratch view is covered in FeatStudyEditorTests. This stand-in checks the cross-module
        // descriptor boundary without importing a feature or hiding a missing presentation behind a default.
        h.app.ui.panels.register(PanelDescriptor(id: "studyeditor.scratch", title: "Scratch", icon: NibSymbol.quickNote.name,
            placement: .floating, order: 600, owner: "test") { context in
            scratchPresentation = context.presentation
            return AnyView(NibPanelHeader(title: "Scratch", symbol: .quickNote,
                handlesEscape: context.presentation == .sheet, onClose: context.dismiss))
        })
        var sessionCloses = 0
        let host = UIHostingController(rootView: PracticeView(model: model, close: { sessionCloses += 1 }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host
        window.isHidden = false
        defer { host.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where !model.started { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.started)
        let card = model.current?.id
        let queue = model.queue
        try await h.run(StudySessionAction.id, ["doc": .string(model.docRef), "action": "scratch"])
        for _ in 0..<100 where host.presentedViewController == nil { try await Task.sleep(for: .milliseconds(10)) }
        let sheet = try XCTUnwrap(host.presentedViewController)
        for _ in 0..<5 { sheet.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(scratchPresentation, .sheet)
        XCTAssertTrue(NibEscapeRouting.cancel(in: sheet.view))
        for _ in 0..<100 where model.scratchPresented || host.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.scratchPresented)
        XCTAssertNil(host.presentedViewController)
        XCTAssertEqual(sessionCloses, 0)
        XCTAssertTrue(model.started)
        XCTAssertEqual(model.current?.id, card)
        XCTAssertEqual(model.queue, queue)
    }

    func testModalPanelEscapeClosesPresentedController() async throws {
        for id in [PanelIDs.studyPractice, PanelIDs.studySmartLearn] {
            for presentation in [PanelPresentation.sheet, .fullScreen] {
                for compact in [true, false] {
                    for scheme in [ColorScheme.light, .dark] {
                        try await check(id: id, presentation: presentation, compact: compact, scheme: scheme, modal: true)
                    }
                }
            }
        }
    }

    func testPersistentPanelLeavesEscapeForCanvas() async throws {
        for id in [PanelIDs.studyPractice, PanelIDs.studySmartLearn] {
            for presentation in [PanelPresentation.floating, .sidebar, .window, .libraryTab] {
                // Explicit non-modal placement wins even in a compact environment.
                for compact in [true, false] {
                    try await check(id: id, presentation: presentation, compact: compact, scheme: .light, modal: false)
                }
            }
        }
    }

    private func check(id: String, presentation: PanelPresentation, compact: Bool,
                       scheme: ColorScheme, modal: Bool) async throws {
        let h = Harness(features: [FeatStudySessionFeature.self])
        h.session.document = Fixtures.studySetID
        let runtime = try XCTUnwrap(h.app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self))
        runtime.now = { 1_700_000_000 }
        var closes = 0
        weak var presented: UIViewController?
        let close: @MainActor () -> Void = {
            closes += 1
            presented?.dismiss(animated: false)
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.panelClose, title: "Close Panel",
                                                  summary: "Test panel host", effect: .session)) { params, _ in
            XCTAssertEqual(params["id"]?.stringValue, id)
            // These panels call context.dismiss themselves after any command.
            return .null
        }
        var context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: close)
        context.presentation = presentation
        let descriptor = try XCTUnwrap(h.app.ui.panels.get(id))
        let content = descriptor.makeView(context)
        let host = UIHostingController(rootView: content
            .environment(\.horizontalSizeClass, compact ? .compact : .regular)
            .environment(\.colorScheme, scheme))
        let root = UIViewController()
        let size = compact ? CGSize(width: 390, height: 844) : CGSize(width: 1024, height: 768)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = modal ? root : host
        window.isHidden = false
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        if modal {
            host.modalPresentationStyle = presentation == .fullScreen ? .fullScreen : .pageSheet
            presented = host
            root.present(host, animated: false)
        }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        if modal { XCTAssertTrue(root.presentedViewController === host) }
        // This is the view-tree press fallback used by the shell and NibDesign's EscapeRoutingTests.
        XCTAssertEqual(NibEscapeRouting.cancel(in: host.view), modal, "\(id): \(presentation)")
        for _ in 0..<100 {
            if !modal || (closes > 0 && root.presentedViewController == nil) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(closes, modal ? 1 : 0)
        if modal { XCTAssertNil(root.presentedViewController) }
    }
}
