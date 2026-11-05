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
        let h = Harness(features: [FeatStudySessionFeature.self])
        h.session.document = Fixtures.studySetID
        let runtime = try XCTUnwrap(h.app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self))
        runtime.now = { 1_700_000_000 }
        let model = runtime.model(app: h.app, doc: Fixtures.studySetID, session: h.session)
        await model.begin("practice")
        XCTAssertTrue(model.started)
        let card = try XCTUnwrap(model.current?.id)
        let queue = model.queue
        var closes = 0
        var sessionCloses = 0
        var order: [String] = []
        // Both owners are rendered in one window. The top surface must consume
        // the press before the session header is offered it.
        let underlying = StudySessionView(model: model, smartLearn: false, close: {
            order.append("session")
            sessionCloses += 1
        }).snapshotContent
        let content = ZStack {
            underlying
            StudyOptionsPanel(onClose: {
                order.append("options")
                closes += 1
            }) { Text("Options") }
        }
        let host = UIHostingController(rootView: AnyView(content))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
        XCTAssertEqual(order, ["options"])
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(sessionCloses, 0)
        XCTAssertTrue(model.started)
        XCTAssertEqual(model.current?.id, card)
        XCTAssertEqual(model.queue, queue)

        // Model the shell removing the closed surface. The next press must reach
        // the still-registered session owner, proving it was bypassed above.
        host.rootView = AnyView(underlying)
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
        XCTAssertEqual(order, ["options", "session"])
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(sessionCloses, 1)
    }

    func testPracticeScratchSheetPassesModalContextAndEscapePreservesSession() async throws {
        let h = Harness(features: [FeatStudySessionFeature.self])
        h.session.document = Fixtures.studySetID
        let runtime = try XCTUnwrap(h.app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self))
        runtime.now = { 1_700_000_000 }
        let model = runtime.model(app: h.app, doc: Fixtures.studySetID, session: h.session)
        var scratchPresentation: PanelPresentation?
        var scratchCloses = 0
        // The actual scratch view is covered in FeatStudyEditorTests. This stand-in checks the cross-module
        // descriptor boundary without importing a feature or hiding a missing presentation behind a default.
        h.app.ui.panels.register(PanelDescriptor(id: "studyeditor.scratch", title: "Scratch", icon: NibSymbol.quickNote.name,
            placement: .floating, order: 600, owner: "test") { context in
            scratchPresentation = context.presentation
            return AnyView(NibPanelHeader(title: "Scratch", symbol: .quickNote,
                handlesEscape: context.presentation == .sheet, onClose: {
                    scratchCloses += 1
                    context.dismiss()
                }))
        })
        var sessionCloses = 0
        model.onEnd = { sessionCloses += 1 }
        await model.begin("practice")
        XCTAssertTrue(model.started)
        let card = try XCTUnwrap(model.current?.id)
        let queue = model.queue
        try await h.run(StudySessionAction.id, ["doc": .string(model.docRef), "action": "scratch"])
        XCTAssertTrue(model.scratchPresented)
        let session = StudySessionView(model: model, smartLearn: false, close: { sessionCloses += 1 })
        // Mount the exact content used by Practice's sheet, with its real context
        // and dismissal callback, without asking a sceneless window to present it.
        let host = UIHostingController(rootView: session.scratchContent)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(scratchPresentation, .sheet)
        XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
        // context.dismiss enqueues closeScratch through the command bus.
        for _ in 0..<20 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(scratchCloses, 1)
        XCTAssertFalse(model.scratchPresented)
        XCTAssertEqual(sessionCloses, 0)
        XCTAssertTrue(model.started)
        XCTAssertEqual(model.current?.id, card)
        XCTAssertEqual(model.queue, queue)
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), 0)
    }

    func testModalPanelEscapeRunsCloseExactlyOnce() async throws {
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
        let close: @MainActor () -> Void = {
            closes += 1
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
        let size = compact ? CGSize(width: 390, height: 844) : CGSize(width: 1024, height: 768)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        // Hostless package tests have no scene to render a UIKit modal.
        // The panel owns its close action; the shell owns controller dismissal.
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        // This is the view-tree press fallback used by the shell and NibDesign's EscapeRoutingTests.
        XCTAssertEqual(NibEscapeRouting.cancel(in: host.view), modal, "\(id): \(presentation)")
        XCTAssertEqual(closes, modal ? 1 : 0)
    }
}
