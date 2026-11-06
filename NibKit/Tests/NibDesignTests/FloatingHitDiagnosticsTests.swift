#if DEBUG
import XCTest
import UIKit
@testable import NibDesign

@MainActor
final class FloatingHitDiagnosticsTests: XCTestCase {
    func testWindowHitProbeDoesNotReenterAndResetsAfterEachContact() {
        let window = ReentrantDiagnosticWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let canvas = UIView(frame: CGRect(x: 100, y: 200, width: 400, height: 500))
        window.addSubview(canvas)

        for _ in 0..<2 {
            window.hitCount = 0
            let details = NibFloatingHitDiagnostics.contactDetails(at: CGPoint(x: 20, y: 30), in: canvas, event: nil)
            XCTAssertEqual(window.hitCount, 1, "Probing the window re-enters the canvas diagnostic, not another window hit test")
            XCTAssertEqual(window.lastPoint, CGPoint(x: 120, y: 230), "The logged hit uses window coordinates")
            XCTAssertTrue(window.nestedDetails.contains("windowHit=probe-in-progress"))
            XCTAssertTrue(details.contains("windowHit=\(NSStringFromClass(type(of: window)))"))
            XCTAssertTrue(details.contains("firstTouchWindowPoint=nil"), "Speculative hit testing is not a delivered touch")
        }
    }

    func testDetachedContactDoesNotAttemptAWindowHitTest() {
        let details = NibFloatingHitDiagnostics.contactDetails(at: .zero, in: UIView(), event: nil)
        XCTAssertTrue(details.contains("windowPoint=nil windowHit=nil (no-window)"))
    }
}

@MainActor
private final class ReentrantDiagnosticWindow: UIWindow {
    var hitCount = 0
    var lastPoint = CGPoint.zero
    var nestedDetails = ""

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        hitCount += 1
        lastPoint = point
        // Bound a regression instead of allowing recursive hit testing to hang the test job.
        guard hitCount == 1 else { return nil }
        nestedDetails = NibFloatingHitDiagnostics.contactDetails(at: point, in: self, event: event)
        return self
    }
}
#endif
