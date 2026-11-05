import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibDesign
import NibTesting
@testable import FeatStudyEditor

@MainActor
final class PanelEscapeTests: XCTestCase {
    func testModalPanelEscapeRunsCloseExactlyOnce() async throws {
        for id in [ScratchPaper.panelID] {
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
        for id in [ScratchPaper.panelID] {
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
        let h = Harness(features: [FeatStudyEditorFeature.self])
        h.session.document = Fixtures.studySetID
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
