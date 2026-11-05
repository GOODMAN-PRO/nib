import XCTest

/// Unit tests in the UI runner because the capture policy belongs to that target, not the shipped app.
/// No app launch, screenshot, simulator interaction or real-time wait is needed by these tests.
final class CaptureReadinessTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 1000)
    private let canvas = CGRect(x: 0, y: 100, width: 800, height: 800)

    private func elements(_ pixels: [UInt8]) -> [CaptureReadiness.Element] {
        [.init(frame: CGRect(x: 20, y: 20, width: 44, height: 44), isAvailable: true, pixels: pixels),
         .init(frame: CGRect(x: 200, y: 300, width: 100, height: 50), isAvailable: true, pixels: pixels)]
    }

    @MainActor
    func testAssistantTimeoutRecordsFailureAndPreservesDiagnostics() {
        var diagnosed = false
        var diagnosedBeforeFailure = false
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { issue in
            diagnosedBeforeFailure = diagnosed
            return issue.compactDescription.contains("Assistant rendering readiness failed:")
                && issue.compactDescription.contains("blank page and palette")
        }
        // Strict matching fails this regression if the caller swallows the timeout again.
        XCTExpectFailure("The assistant caller must fail even when its document-state checks could pass",
                         options: options) {
            CaptureUITests.checkAssistantReadiness(waitUntilRendered: {
                throw NibUI.Failure.message("blank page and palette")
            }, diagnose: { error in
                if let failure = error as? NibUI.Failure, case let .message(message) = failure {
                    diagnosed = message == "blank page and palette"
                }
            })
        }
        XCTAssertTrue(diagnosed)
        XCTAssertTrue(diagnosedBeforeFailure, "Preserve timeout evidence before recording the failure")
    }

    @MainActor
    func testAssistantReadyReturnsWithoutFailureOrTimeoutDiagnostics() {
        var waited = false
        var diagnosed = false
        CaptureUITests.checkAssistantReadiness(waitUntilRendered: {
            waited = true
        }, diagnose: { _ in diagnosed = true })
        XCTAssertTrue(waited)
        XCTAssertFalse(diagnosed)
    }

    func testBlankToRenderedInBothAppearancesRequiresHalfASecond() {
        let appearances: [(UInt8, UInt8)] = [(245, 20), (20, 245)]
        for (paper, ink) in appearances {
            var readiness = CaptureReadiness()
            let blank = elements([paper, paper])
            let rendered = elements([paper, ink])
            XCTAssertFalse(readiness.observe(blank, canvas: canvas, window: window, at: 0))
            XCTAssertFalse(readiness.observe(blank, canvas: canvas, window: window, at: 30))
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 31))
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 31.25))
            XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 31.5))
        }
    }

    func testEachMissingBlankOrInvalidElementResetsStabilization() {
        let rendered = elements([20, 245])
        for index in rendered.indices {
            for fault in 0..<5 {
                var readiness = CaptureReadiness()
                XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0))
                var invalid = rendered
                switch fault {
                case 0: invalid[index].isAvailable = false
                case 1: invalid[index].pixels = [245, 245]
                case 2: invalid[index].pixels = []
                case 3: invalid[index].frame = .zero
                default: invalid[index].frame.origin.x = 900
                }
                XCTAssertFalse(readiness.observe(invalid, canvas: canvas, window: window, at: 0.5))
                XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 1))
                XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 1.25))
                XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 1.5))
            }
        }
    }

    func testElementCanvasAndWindowGeometryChangesRestartStabilization() {
        for changed in 0..<4 {
            var readiness = CaptureReadiness()
            var rendered = elements([20, 245])
            var canvas = self.canvas
            var window = self.window
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0))
            if changed < 2 { rendered[changed].frame.origin.x += 1 }
            else if changed == 2 { canvas.size.height -= 1 }
            else { window.size.height += 1 }
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0.5))
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0.75))
            XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 1))
        }
    }

    func testEmptySnapshotAndContrastBoundaryCannotPass() {
        var readiness = CaptureReadiness()
        XCTAssertFalse(readiness.observe([], canvas: canvas, window: window, at: 0))
        XCTAssertFalse(readiness.observe(elements([20, 245]), canvas: .zero, window: window, at: 1))
        XCTAssertFalse(readiness.observe(elements([20, 245]), canvas: canvas, window: .zero, at: 2))
        XCTAssertFalse(CaptureReadiness.hasRenderedDetail([]))
        XCTAssertFalse(CaptureReadiness.hasRenderedDetail([20, 60]))
        XCTAssertTrue(CaptureReadiness.hasRenderedDetail([20, 61]))
    }
}
