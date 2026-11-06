import XCTest
import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign
import NibTesting
@testable import FeatSearchUI

@MainActor
final class SearchLayoutTests: XCTestCase {
    func testSearchHeightReservesOneRowInWideWindowsAndTwoInSplitView() {
        let landscape = CGSize(width: 1366, height: 1024)
        let split = CGSize(width: 600, height: 1024)
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: true,
            windowSize: landscape), 299)
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: true,
            windowSize: split), 239)
        // Mirror ChromeLayout's documented 900 pt width boundary, not the keyboard's
        // visible aspect ratio or the width of the 560 pt results panel.
        for width: CGFloat in [899, 900] {
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: true,
                windowSize: CGSize(width: width, height: 700)), width < 900 ? 239 : 299)
        }
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: true), 239,
            "An unmeasured window keeps the conservative two-row reserve")
    }

    func testSearchHeightKeepsTheExistingMinimumMaximumAndLibraryClearance() {
        for size in [CGSize(width: 600, height: 1024), CGSize(width: 1366, height: 1024)] {
            for available: CGFloat in [-100, 0, 100, 180, 419, 780, 2000] {
                let height = SearchViewport.resultsHeight(availableHeight: available,
                    reservesNavigation: true, windowSize: size)
                let previous = max(0, min(NibMetrics.searchResultsMaxHeight,
                    available - NibMetrics.barHeight - NibMetrics.minimumRestingGap
                        - SearchViewport.navigationReserve))
                XCTAssertGreaterThanOrEqual(height, previous, "Never reduce the panel's previous minimum")
                XCTAssertGreaterThanOrEqual(height, 0)
                XCTAssertLessThanOrEqual(height, NibMetrics.searchResultsMaxHeight)
                XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: available,
                    reservesNavigation: false, windowSize: size),
                    SearchViewport.resultsHeight(availableHeight: available, reservesNavigation: false),
                    "The library does not reserve document HUD rows")
            }
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 100,
                reservesNavigation: true, windowSize: size), 0)
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 2000,
                reservesNavigation: true, windowSize: size), 600)
        }
    }

    func testFloatingKeyboardOutsidePanelColumnDoesNotChangeViewportOrResultsHeight() {
        let bounds = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        let safe = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0)
        let column = CGRect(x: 16, y: 100, width: 560, height: 924)
        let clear = SearchViewport.measure(windowBounds: bounds, safeArea: safe,
            frame: column, keyboard: nil)
        let floating = SearchViewport.measure(windowBounds: bounds, safeArea: safe,
            frame: column, keyboard: CGRect(x: 900, y: 360, width: 300, height: 300))
        XCTAssertEqual(floating, clear)
        XCTAssertFalse(floating.differs(from: clear, scale: 2))
        XCTAssertEqual(floating.availableHeight, 874)
        // Apply the actual host cap first. No counter position can subtract twelve rows
        // from this 780 pt host, even when the other chrome lifts above the keyboard.
        for viewport in [clear, floating] {
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: min(780, viewport.availableHeight),
                reservesNavigation: true, windowSize: viewport.windowSize), 600)
        }
        let intersecting = SearchViewport.measure(windowBounds: bounds, safeArea: safe,
            frame: column, keyboard: CGRect(x: 500, y: 535, width: 400, height: 300))
        XCTAssertEqual(intersecting.availableHeight, 419)
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: intersecting.availableHeight,
            reservesNavigation: true, windowSize: intersecting.windowSize), 299)
    }

    func testBoundsIgnoreOnePixelNoiseButRetainAccumulatedMovementAndRemoval() {
        let original = CGRect(x: 16, y: 62, width: 358, height: 738)
        var retained: CGRect? = original
        for delta in [CGFloat(0.25), 0.5] {
            let next = original.offsetBy(dx: delta, dy: -delta)
            XCTAssertFalse(SearchLayoutMeasurement.changed(retained, next, scale: 2))
            if SearchLayoutMeasurement.changed(retained, next, scale: 2) { retained = next }
        }
        XCTAssertTrue(SearchLayoutMeasurement.changed(retained, original.offsetBy(dx: 0.75, dy: 0), scale: 2))
        XCTAssertTrue(SearchLayoutMeasurement.changed(retained, nil, scale: 2))
        XCTAssertTrue(SearchLayoutMeasurement.changed(nil, original, scale: 2))
        XCTAssertFalse(SearchLayoutMeasurement.changed(nil, nil, scale: 2))
        for scale in [CGFloat(1), 2, 3] {
            XCTAssertFalse(SearchLayoutMeasurement.changed(original, original.insetBy(dx: 0.1, dy: 0.1), scale: scale))
            XCTAssertTrue(SearchLayoutMeasurement.changed(original, original.insetBy(dx: 1, dy: 1), scale: scale))
        }
    }

    func testViewportRejectsRoundingNoiseAndAcceptsKeyboardAndWindowChanges() {
        let original = SearchViewport(windowSize: CGSize(width: 390, height: 834), availableHeight: 722,
            visibleBounds: CGRect(x: 0, y: 0, width: 390, height: 834))
        var next = original
        next.availableHeight -= 0.5
        next.visibleBounds.origin.y += 0.5
        XCTAssertFalse(next.differs(from: original, scale: 2))
        next.availableHeight -= 0.25
        XCTAssertTrue(next.differs(from: original, scale: 2))
        next = original
        next.windowSize.width = 600
        XCTAssertTrue(next.differs(from: original, scale: 2))
        XCTAssertTrue(original.differs(from: nil, scale: 2))
    }

    func testViewportSensorDoesNotRepublishSubpixelLayoutChanges() async throws {
        executionTimeAllowance = 60
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 834))
        var samples: [SearchViewport] = []
        let sensor = SearchViewportReader.Sensor { samples.append($0) }
        sensor.frame = CGRect(x: 0, y: 62, width: 390, height: 738)
        window.addSubview(sensor)
        defer { sensor.removeFromSuperview() }
        sensor.layoutIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(samples.count, 1)
        let initial = try XCTUnwrap(samples.first)
        sensor.frame.origin.y += 0.1
        sensor.setNeedsLayout()
        sensor.layoutIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(samples, [initial], "Rounding noise must not start another SwiftUI layout pass")
        sensor.frame.origin.y += 2
        sensor.setNeedsLayout()
        sensor.layoutIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(samples.count, 2, "Real movement must still update visible/keyboard bounds")
    }

    func testLibraryBoundsPublisherIsCreatedAndSubscribedOnceAcrossViewUpdates() async {
        executionTimeAllowance = 60
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        state.scope = "lib"
        state.isPresented = true
        state.instant = true
        let subject = CurrentValueSubject<CGRect?, Never>(nil)
        var creations = 0
        var subscriptions = 0
        let factory: @MainActor (EditorSession) -> AnyPublisher<CGRect?, Never> = { _ in
            creations += 1
            return subject.handleEvents(receiveSubscription: { _ in subscriptions += 1 }).eraseToAnyPublisher()
        }
        h.app.services.set(factory as AnyObject, for: "libraryui.searchContentBounds")
        let host = UIHostingController(rootView: SearchBoundsLifetimeFixture(app: h.app, session: h.session, state: state))
        host.safeAreaRegions = []
        let proposal = CGSize(width: 390, height: 834)
        let window = UIWindow(frame: CGRect(origin: .zero, size: proposal))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        for step in 0..<4 {
            state.query = String(repeating: "query ", count: step)
            subject.send(CGRect(x: 0, y: CGFloat(62 + step), width: 390, height: 700))
            XCTAssertEqual(host.sizeThatFits(in: proposal), proposal)
            for _ in 0..<10 { await Task.yield() }
        }
        XCTAssertEqual(creations, 1, "A reconstructed view must retain the StateObject's publisher")
        XCTAssertEqual(subscriptions, 1, "Body evaluation must not replay the upstream initial value")
    }

    func testFallbackBoundsPublisherFollowsSessionIdentity() async throws {
        executionTimeAllowance = 60
        let h = Harness(features: [FeatSearchUIFeature.self])
        let second = EditorSession()
        let subject = CurrentValueSubject<CGRect?, Never>(nil)
        var creations: [ObjectIdentifier] = []
        var cancellations: [ObjectIdentifier] = []
        let factory: @MainActor (EditorSession) -> AnyPublisher<CGRect?, Never> = { session in
            let identity = ObjectIdentifier(session)
            creations.append(identity)
            return subject.handleEvents(receiveCancel: { cancellations.append(identity) }).eraseToAnyPublisher()
        }
        h.app.services.set(factory as AnyObject, for: "libraryui.searchContentBounds")
        let fallback = try XCTUnwrap(h.app.ui.chromeOverlays.get("searchui.libraryFallback"))
        let host = UIHostingController(rootView: fallback.makeView(ChromeContext(app: h.app, session: h.session)))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 834))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        for session in [h.session, h.session, second, second] {
            host.rootView = fallback.makeView(ChromeContext(app: h.app, session: session))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            for _ in 0..<10 { await Task.yield() }
        }
        XCTAssertEqual(creations, [ObjectIdentifier(h.session), ObjectIdentifier(second)],
            "Retain the publisher within a session, and recreate it when the host changes sessions")
        XCTAssertEqual(cancellations, [ObjectIdentifier(h.session)],
            "The old session must stop supplying library bounds")
    }
}

@MainActor
private struct SearchBoundsLifetimeFixture: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState

    var body: some View {
        // Reading the query forces this parent to reconstruct the child after each mutation.
        LibrarySearchFloatingContent(app: app, session: session, state: state)
            .accessibilityValue(state.query)
    }
}
