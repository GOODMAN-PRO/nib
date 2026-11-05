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

    func testPanelEscapeUsesCloseAndConsumesWhileDisabled() async throws {
        for enabled in [true, false] {
            var closed = 0
            let header = NibPanelHeader(title: "Outline", symbol: .outline, onClose: { closed += 1 })
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
}
