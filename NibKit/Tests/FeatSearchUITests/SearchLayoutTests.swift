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
    func testSearchHeightReservesOneRowForSideBySideHUDsAndTwoForStackedHUDs() {
        // The chrome host places these measured 40 pt HUDs 16 pt apart when their
        // widths collide. Its final placement, including a narrowed sidebar region,
        // is authoritative even when the full window is in landscape.
        let oneRow = SearchViewport.navigationRows(counterAvailableHeight: NibMetrics.hudHeight)
        let twoRows = SearchViewport.navigationRows(counterAvailableHeight:
            2 * NibMetrics.hudHeight + NibMetrics.minimumRestingGap)
        XCTAssertEqual(oneRow, 1)
        XCTAssertEqual(twoRows, 2)
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: true,
            navigationRows: oneRow), 299)
        XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: true,
            navigationRows: twoRows), 239)
        for rows in [oneRow, twoRows] {
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 419, reservesNavigation: false,
                navigationRows: rows), 359, "Library search must not reserve HUD space")
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 100, reservesNavigation: true,
                navigationRows: rows), 0)
            XCTAssertEqual(SearchViewport.resultsHeight(availableHeight: 2000, reservesNavigation: true,
                navigationRows: rows), 600)
        }
    }

    func testGroupHeadingWaitsForItsWholeFirstRowAndReappearsAfterScrolling() {
        let viewport = CGRect(x: 0, y: 0, width: 560, height: 160)
        // Heading at 120, 20 pt high, a 16 pt gap, then a 60 pt first result.
        let group = CGRect(x: 16, y: 120, width: 528, height: 96)
        XCTAssertFalse(SearchGroupHeadingVisibility.isVisible(groupStart: group, viewport: viewport))
        XCTAssertFalse(SearchGroupHeadingVisibility.isVisible(groupStart: group.offsetBy(dx: 0, dy: -55),
            viewport: viewport), "A partially clipped first row must not leave an orphan heading")
        XCTAssertTrue(SearchGroupHeadingVisibility.isVisible(groupStart: group.offsetBy(dx: 0, dy: -56),
            viewport: viewport), "Scrolling the first row fully into view restores its heading")
        XCTAssertTrue(SearchGroupHeadingVisibility.isVisible(groupStart: group,
            viewport: CGRect(x: 0, y: 0, width: 560, height: 216)))
        XCTAssertFalse(SearchGroupHeadingVisibility.isVisible(groupStart: group, viewport: .zero))
    }

    func testNavigationReserveUsesThePanelsKeyboardBoundaryAndWindowCoordinates() {
        let viewport = SearchViewport.measure(windowBounds: CGRect(x: 0, y: 0, width: 1366, height: 1024),
            safeArea: .zero, frame: CGRect(x: 16, y: 100, width: 560, height: 800),
            keyboard: CGRect(x: 500, y: 535, width: 400, height: 300))
        XCTAssertEqual(viewport.columnTop, 100)
        XCTAssertEqual(viewport.availableHeight, 419)
        XCTAssertEqual(viewport.navigationRows(counterTop: nil), 2, "Keep both rows until the host reports its layout")
        XCTAssertEqual(viewport.navigationRows(counterTop: 479), 1)
        XCTAssertEqual(viewport.navigationRows(counterTop: 423), 2,
            "A floating keyboard or sidebar may stack HUDs inside the same landscape window")
    }

    func testCounterReportsTheRowsActuallyPlacedByItsHost() async throws {
        executionTimeAllowance = 60
        let h = Harness(features: [FeatSearchUIFeature.self])
        let state = SearchState()
        let size = CGSize(width: 1000, height: 1000)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let counter = SearchCounter(app: h.app, session: h.session, state: state)
        func view(lift: CGFloat) -> some View {
            counter.position(x: size.width / 2,
                y: size.height - NibMetrics.chromeInset - NibMetrics.hudHeight / 2 - lift)
        }
        let host = UIHostingController(rootView: view(lift: 0))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        for rows in [1, 2, 1] {
            let lift = CGFloat(rows - 1) * (NibMetrics.hudHeight + NibMetrics.minimumRestingGap)
            let expectedTop = size.height - NibMetrics.chromeInset - NibMetrics.hudHeight - lift
            host.rootView = view(lift: lift)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            for _ in 0..<50 {
                if let top = state.navigationCounterTop, abs(top - expectedTop) < 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let top = try XCTUnwrap(state.navigationCounterTop)
            XCTAssertEqual(top, expectedTop, accuracy: 1)
            let viewport = SearchViewport(windowSize: size, availableHeight: size.height - NibMetrics.chromeInset,
                visibleBounds: window.bounds)
            XCTAssertEqual(viewport.navigationRows(counterTop: top), rows,
                "The same wide window may stack HUDs when its usable column narrows")
        }
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
