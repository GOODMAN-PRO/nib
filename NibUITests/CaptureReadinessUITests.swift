import XCTest

/// Unit tests in the UI runner because the capture policy belongs to that target, not the shipped app.
/// No app launch, screenshot, simulator interaction or real-time wait is needed by these tests.
final class CaptureReadinessUITests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 1000)
    private let canvas = CGRect(x: 0, y: 100, width: 800, height: 800)

    private func elements(_ pixels: [UInt8]) -> [CaptureReadiness.Element] {
        [.init(frame: CGRect(x: 20, y: 20, width: 44, height: 44), isAvailable: true, pixels: pixels, name: "palette.pen"),
         .init(frame: CGRect(x: 200, y: 300, width: 100, height: 50), isAvailable: true, pixels: pixels, name: "page.note")]
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
            XCTAssertFalse(readiness.observe(blank, canvas: canvas, window: window, at: 0).isReady)
            XCTAssertFalse(readiness.observe(blank, canvas: canvas, window: window, at: 30).isReady)
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 31).isReady)
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 31.25).isReady)
            XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 31.5).isReady)
        }
    }

    func testEachMissingBlankOrInvalidElementResetsStabilization() {
        let rendered = elements([20, 245])
        for index in rendered.indices {
            for fault in 0..<5 {
                var readiness = CaptureReadiness()
                XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0).isReady)
                var invalid = rendered
                switch fault {
                case 0: invalid[index].isAvailable = false
                case 1: invalid[index].pixels = [245, 245]
                case 2: invalid[index].pixels = []
                case 3: invalid[index].frame = .zero
                default: invalid[index].frame.origin.x = 900
                }
                XCTAssertFalse(readiness.observe(invalid, canvas: canvas, window: window, at: 0.5).isReady)
                XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 1).isReady)
                XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 1.25).isReady)
                XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 1.5).isReady)
            }
        }
    }

    func testElementCanvasAndWindowGeometryChangesRestartStabilization() {
        for changed in 0..<4 {
            var readiness = CaptureReadiness()
            var rendered = elements([20, 245])
            var canvas = self.canvas
            var window = self.window
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0).isReady)
            if changed < 2 { rendered[changed].frame.origin.x += 1 }
            else if changed == 2 { canvas.size.height -= 1 }
            else { window.size.height += 1 }
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0.5).isReady)
            XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 0.75).isReady)
            XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 1).isReady)
        }
    }

    func testEmptySnapshotAndContrastBoundaryCannotPass() {
        var readiness = CaptureReadiness()
        XCTAssertFalse(readiness.observe([], canvas: canvas, window: window, at: 0).isReady)
        XCTAssertFalse(readiness.observe(elements([20, 245]), canvas: .zero, window: window, at: 1).isReady)
        XCTAssertFalse(readiness.observe(elements([20, 245]), canvas: canvas, window: .zero, at: 2).isReady)
        XCTAssertFalse(CaptureReadiness.hasRenderedDetail([]))
        XCTAssertFalse(CaptureReadiness.hasRenderedDetail([20, 60]))
        XCTAssertTrue(CaptureReadiness.hasRenderedDetail([20, 61]))
    }

    func testVerdictNamesEveryFalseConditionAndItsMeasurements() {
        var readiness = CaptureReadiness()
        var sample = elements([20, 60])
        sample[0].isAvailable = false
        sample[0].frame = .zero
        sample[1].frame.origin.x = 900
        let outsideCanvas = CGRect(x: 0, y: 100, width: 900, height: 800)
        let verdict = readiness.observe(sample, canvas: outsideCanvas, window: window, at: 0)
        XCTAssertFalse(verdict.isReady)
        XCTAssertTrue(verdict.failures.contains("palette.pen[0].missing"))
        XCTAssertTrue(verdict.failures.contains("palette.pen[0].frame"))
        XCTAssertTrue(verdict.failures.contains("palette.pen[0].contrast"))
        XCTAssertTrue(verdict.failures.contains("page.note[1].containment"))
        XCTAssertTrue(verdict.failures.contains("page.note[1].contrast"))
        XCTAssertTrue(verdict.failures.contains("canvas.containment"))
        XCTAssertTrue(verdict.diagnosis.contains("contrast=Optional(40) required>40"))
        XCTAssertTrue(verdict.diagnosis.contains("samples=2"))
        XCTAssertTrue(verdict.diagnosis.contains("stability=0 required>=0.5 reset=prerequisite"))
        XCTAssertTrue(verdict.diagnosis.contains("frame="))
    }

    func testStabilityVerdictAndCanvasContainmentResetAreExplicit() {
        var readiness = CaptureReadiness()
        let rendered = elements([20, 245])
        let first = readiness.observe(rendered, canvas: canvas, window: window, at: 0)
        XCTAssertEqual(first.failures, ["stability"])
        let moving = readiness.observe(rendered, canvas: canvas, window: window, at: 0.25)
        XCTAssertEqual(moving.failures, ["stability"])
        XCTAssertTrue(moving.diagnosis.contains("stability=0.25 required>=0.5"))
        XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 0.5).isReady)
        var offscreenCanvas = canvas
        offscreenCanvas.origin.x = -1
        let invalid = readiness.observe(rendered, canvas: offscreenCanvas, window: window, at: 1)
        XCTAssertEqual(invalid.failures, ["canvas.containment"])
        XCTAssertFalse(readiness.observe(rendered, canvas: canvas, window: window, at: 2).isReady)
        XCTAssertTrue(readiness.observe(rendered, canvas: canvas, window: window, at: 2.5).isReady)
    }

    func testFullScreenCropMappingPreservesPortraitAndLandscape() {
        for screen in [CGRect(x: 0, y: 0, width: 1032, height: 1376),
                       CGRect(x: 0, y: 0, width: 1376, height: 1032)] {
            let frame = CGRect(x: 20, y: 180, width: 44, height: 44)
            XCTAssertEqual(CaptureReadiness.cropRect(frame: frame, screen: screen,
                pixelWidth: Int(screen.width * 2), pixelHeight: Int(screen.height * 2)),
                CGRect(x: 40, y: 360, width: 88, height: 88))
        }
        let offsetScreen = CGRect(x: 10, y: 20, width: 800, height: 1000)
        XCTAssertEqual(CaptureReadiness.cropRect(frame: CGRect(x: 30, y: 40, width: 44, height: 44),
            screen: offsetScreen, pixelWidth: 1600, pixelHeight: 2000),
            CGRect(x: 40, y: 40, width: 88, height: 88))
    }

    func testCropRejectsMissingOffscreenAndMisorientedGeometry() {
        for frame in [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: -1, y: 20, width: 44, height: 44)] {
            XCTAssertNil(CaptureReadiness.cropRect(frame: frame, screen: window, pixelWidth: 1600, pixelHeight: 2000))
        }
        XCTAssertNil(CaptureReadiness.cropRect(frame: canvas, screen: .zero, pixelWidth: 1600, pixelHeight: 2000))
        XCTAssertNil(CaptureReadiness.cropRect(frame: canvas, screen: window, pixelWidth: 0, pixelHeight: 2000))
        XCTAssertNil(CaptureReadiness.cropRect(frame: canvas, screen: window, pixelWidth: 2000, pixelHeight: 1600))
    }
}
