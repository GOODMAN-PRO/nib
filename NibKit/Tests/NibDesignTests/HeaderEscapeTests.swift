import XCTest
import SwiftUI
import UIKit
@testable import NibDesign

@MainActor
final class HeaderEscapeTests: XCTestCase {
    func testSheetEscapeUsesCancelAndRespectsInheritedDisabledState() async throws {
        for enabled in [true, false] {
            for primaryEnabled in [true, false] {
                var cancellations = 0
                let header = NibSheetHeader("Draft", primaryTitle: "Create", isPrimaryEnabled: primaryEnabled,
                    onCancel: { cancellations += 1 }, onPrimary: { XCTFail("Escape must never create") })
                    .disabled(!enabled)
                let host = UIHostingController(rootView: header)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil }
                for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertTrue(NibEscapeRouting.cancel(in: host.view), "Disabled Cancel must still consume Escape")
                XCTAssertEqual(cancellations, enabled ? 1 : 0,
                    "Only Cancel's enabled state matters; an invalid draft may still be cancelled")
            }
        }
    }

    func testOptedInPanelEscapeUsesCloseAndConsumesWhileDisabled() async throws {
        for enabled in [true, false] {
            var closed = 0
            let header = NibPanelHeader(title: "Outline", symbol: .outline, handlesEscape: true,
                                       onClose: { closed += 1 })
                .disabled(!enabled)
            let host = UIHostingController(rootView: header)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(NibEscapeRouting.cancel(in: host.view))
            XCTAssertEqual(closed, enabled ? 1 : 0)
        }
    }

    func testPersistentPanelLeavesEscapeForCanvasSelection() async throws {
        var closed = 0
        // Exercise both initialisers: sidebar/floating hosts pass a placement
        // menu, while some feature-owned headers have only Close.
        let headers = [
            AnyView(NibPanelHeader(title: "Outline", symbol: .outline, onClose: { closed += 1 })),
            AnyView(NibPanelHeader(title: "Outline", symbol: .outline, onClose: { closed += 1 }) {
                EmptyView()
            })
        ]
        for header in headers {
            for enabled in [true, false] {
                var canvasSelected = true
                let host = UIHostingController(rootView: header.disabled(!enabled))
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true; window.rootViewController = nil }
                for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                // The shell runs its canvas command only if the view-tree
                // fallback declines. A persistent header must never consume it.
                let consumed = NibEscapeRouting.cancel(in: host.view)
                if !consumed { canvasSelected = false }
                XCTAssertFalse(consumed)
                XCTAssertFalse(canvasSelected)
                XCTAssertEqual(closed, 0)
            }
        }
    }
}
