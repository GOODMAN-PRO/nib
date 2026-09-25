import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatLaser

private let pageRef = "page:FIXTUREDOC01/FIXTUREPG001"

@MainActor
final class FeatLaserTests: XCTestCase {
    private func laserEvents(_ h: Harness, since seq: UInt64) -> [NibEvent] {
        h.app.events.events(since: seq).filter { $0.type == NibEventType.laserMoved }
    }

    private func expectError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration and conformance

    func testCommandsPassConformance() async {
        let problems = await CommandConformance.check(features: [FeatLaserFeature.self], owners: [FeatLaserFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersTheStickySamplesToolWithItsShortcutOptionsAndPointer() throws {
        let h = Harness(features: [FeatLaserFeature.self])
        let item = try XCTUnwrap(h.app.ui.toolbar.get("laser"))
        XCTAssertEqual(item.group, .accessories)
        XCTAssertEqual(item.toolID, "laser")
        XCTAssertEqual(item.shortcut, KeyShortcut("l"))
        XCTAssertNotNil(item.settings?(h.session))
        XCTAssertNotNil(item.activeToolMenu?(h.session))

        let tool = try XCTUnwrap(h.app.ui.canvasTools.get("laser")?.make())
        XCTAssertEqual(tool.id, "laser")
        XCTAssertEqual(tool.inputMode, .samples)
        XCTAssertTrue(tool.isSticky)
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(LaserPointerAttachment.attachmentID))

        let owned = h.app.commands.all().filter { $0.owner == FeatLaserFeature.id }
        XCTAssertEqual(Set(owned.map(\.id)), ["laser.setMode", "laser.point"])
        XCTAssertTrue(owned.allSatisfy { $0.effect == .session }, "the laser never edits a document")
    }

    // MARK: laser.setMode

    func testSetModeStoresTheChoiceAndRejectsWhatIsNotAColour() async throws {
        let h = Harness(features: [FeatLaserFeature.self])
        XCTAssertEqual(LaserAppearance(settings: h.app.settings), LaserAppearance(), "Dot, Vermilion, medium trail")

        let out = try await h.run("laser.setMode", ["mode": "trail", "color": "#2156D9", "trailLength": "long"])
        XCTAssertEqual(out["mode"], JSONValue.string("trail"))
        XCTAssertEqual(out["color"], JSONValue.string("#2156D9FF"))
        XCTAssertEqual(LaserAppearance(settings: h.app.settings),
                       LaserAppearance(mode: .trail, color: RGBA(ink: .cobalt), trailLength: .long))

        try await h.run("laser.setMode", ["mode": "dot"])
        XCTAssertEqual(LaserAppearance(settings: h.app.settings),
                       LaserAppearance(mode: .dot, color: RGBA(ink: .cobalt), trailLength: .long),
                       "colour and trail length are kept when left out")

        await expectError(.invalidParams) { _ = try await h.run("laser.setMode", ["mode": "trail", "color": "vermilion"]) }
        await expectError(.invalidParams) { _ = try await h.run("laser.setMode", ["mode": "beam"], as: .ai("chat")) }
        await expectError(.invalidParams) { _ = try await h.run("laser.setMode", ["mode": "beam"]) }
        XCTAssertEqual(h.app.settings.get(LaserSettings.mode), .dot, "a rejected call changes nothing")
    }

    // MARK: laser.point and laser.moved

    func testPointEmitsLaserMovedAtMost30TimesASecondAndNeverWrites() async throws {
        let h = Harness(features: [FeatLaserFeature.self])
        let since = h.app.events.lastSeq
        let depths = h.undoDepths()
        let before = try h.snapshotAll()

        for i in 0..<10 {
            let at: JSONValue = [.number(Double(100 + i)), 50]
            try await h.run("laser.point", ["page": .string(pageRef), "point": at])
        }
        try await h.run("laser.point", ["page": .string(pageRef)])
        try await Task.sleep(nanoseconds: 250_000_000)

        let moved = laserEvents(h, since: since)
        XCTAssertGreaterThanOrEqual(moved.count, 2)
        XCTAssertLessThan(moved.count, 11, "calls closer than 1/30 s are coalesced")
        XCTAssertEqual(moved.first?.doc, Fixtures.docID)
        XCTAssertEqual(moved.first?.payload?["page"], JSONValue.string(pageRef))
        XCTAssertEqual(moved.first?.payload?["point"], JSONValue.array([100, 50]))
        XCTAssertEqual(moved.first?.payload?["mode"], JSONValue.string("dot"))
        XCTAssertEqual(moved.first?.payload?["session"], JSONValue.string(h.session.id.raw))
        XCTAssertNil(moved.last?.payload?["point"], "the last state (hidden) always goes out")
        for (a, b) in zip(moved, moved.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.at - a.at, LaserThrottle.interval - 0.002)
        }

        XCTAssertFalse(h.app.events.events(since: since).contains { $0.type == NibEventType.committed },
                       "no transaction is ever created")
        XCTAssertEqual(h.undoDepths(), depths)
        XCTAssertEqual(try h.snapshotAll(), before)
    }

    func testPointRejectsRefsThatAreNotLivePages() async {
        let h = Harness(features: [FeatLaserFeature.self])
        await expectError(.invalidParams) { _ = try await h.run("laser.point", ["page": "doc:FIXTUREDOC01"]) }
        await expectError(.notFound) { _ = try await h.run("laser.point", ["page": "page:FIXTUREDOC01/NOSUCHPAGE01"]) }
        await expectError(.invalidParams) {
            _ = try await h.run("laser.point", ["page": .string(pageRef), "point": "left"], as: .bridge("pc"))
        }
    }

    func testPointShowsOnTheCanvasesOfThatDocumentOnly() async throws {
        let h = Harness(features: [FeatLaserFeature.self])
        let descriptor = try XCTUnwrap(h.app.ui.canvasAttachments.get(LaserPointerAttachment.attachmentID))
        let notebook = FakeCanvasHost(h)
        let board = FakeCanvasHost(app: h.app, session: h.session, doc: Fixtures.whiteboardID, pages: [Fixtures.boardID])
        let onNotebook = try XCTUnwrap(descriptor.make(notebook) as? LaserPointerAttachment)
        let onBoard = try XCTUnwrap(descriptor.make(board) as? LaserPointerAttachment)
        onNotebook.attach(to: notebook)
        onBoard.attach(to: board)
        XCTAssertFalse(onNotebook.hitTest(CGPoint(x: 120, y: 240), host: notebook), "the pointer never takes a touch")

        try await h.run("laser.point", ["page": .string(pageRef), "point": [120, 240]])
        XCTAssertEqual(onNotebook.renderer?.visibleDot, CGPoint(x: 120, y: 240))
        XCTAssertNil(onBoard.renderer?.visibleDot)

        onNotebook.detach(from: notebook)
        onBoard.detach(from: board)
        XCTAssertNil(onNotebook.renderer)
    }

    // MARK: The tool

    func testToolDrawsInTheOverlayAndSignalsWithoutCommittingAnything() async throws {
        let h = Harness(features: [FeatLaserFeature.self])
        let host = FakeCanvasHost(h)
        let tool = try XCTUnwrap(h.app.ui.canvasTools.get("laser")?.make() as? LaserTool)
        let since = h.app.events.lastSeq
        let depths = h.undoDepths()

        tool.activate(host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count, 1)
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(100, 200)), host: host)
        XCTAssertEqual(tool.renderer?.visibleDot, CGPoint(x: 100, y: 200), "the dot is under the touch at once")
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(110, 210)),
                           CanvasSample(page: Fixtures.page1, location: Point(400, 400), isPredicted: true)], host: host)
        XCTAssertEqual(tool.renderer?.visibleDot, CGPoint(x: 110, y: 210), "predicted touches are not pointed at")
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(120, 220)), host: host)
        try await Task.sleep(nanoseconds: 150_000_000)

        let moved = laserEvents(h, since: since)
        XCTAssertEqual(moved.first?.payload?["point"], JSONValue.array([100, 200]))
        XCTAssertEqual(moved.first?.principal, .user)
        XCTAssertNil(moved.last?.payload?["point"], "lifting sends a payload without a point")
        XCTAssertTrue(host.committed.isEmpty)
        XCTAssertEqual(h.undoDepths(), depths)
        XCTAssertFalse(h.app.events.events(since: since).contains { $0.type == NibEventType.committed })

        tool.deactivate(host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count ?? 0, 0, "the tool clears its overlay")
    }

    // MARK: Pure logic

    func testThrottleKeepsEventsAt30HzAndDeliversTheLastState() {
        var throttle = LaserThrottle()
        var sent: [(at: TimeInterval, signal: LaserSignal)] = []
        func signal(_ i: Int) -> LaserSignal {
            LaserSignal(doc: Fixtures.docID, page: Fixtures.page1, point: Point(Double(i), 0), mode: .trail,
                        color: LaserAppearance.defaultColor, session: "S", principal: .user)
        }
        for i in 0..<240 {                                                  // one second of 240 Hz Pencil samples
            let t = Double(i) / 240
            if let due = throttle.nextFlush, due <= t, let s = throttle.flush(at: due) { sent.append((due, s)) }
            if let s = throttle.offer(signal(i), at: t) { sent.append((t, s)) }
        }
        if let due = throttle.nextFlush, let s = throttle.flush(at: due) { sent.append((due, s)) }

        XCTAssertLessThanOrEqual(sent.count, 31)
        XCTAssertGreaterThanOrEqual(sent.count, 25)
        for (a, b) in zip(sent, sent.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.at - a.at, LaserThrottle.interval - 1e-9)
        }
        XCTAssertEqual(sent.last?.signal.point, Point(239, 0))
        XCTAssertNil(throttle.pending)
    }

    func testTrailFadesLinearlyOverTheLast600Milliseconds() {
        let lifetime = LaserTrailLength.medium.lifetime                      // 1 s: 0.4 s solid, then a 0.6 s fade
        XCTAssertEqual(LaserTrail.alpha(age: 0.2, lifetime: lifetime), 1)
        XCTAssertEqual(LaserTrail.alpha(age: 0.4, lifetime: lifetime), 1, accuracy: 1e-9)
        XCTAssertEqual(LaserTrail.alpha(age: 0.55, lifetime: lifetime), 0.75, accuracy: 1e-9)
        XCTAssertEqual(LaserTrail.alpha(age: 0.7, lifetime: lifetime), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LaserTrail.alpha(age: 1.0, lifetime: lifetime), 0)

        var trail = LaserTrail()
        func at(_ x: Double, _ t: TimeInterval) -> LaserTrail.Sample {
            LaserTrail.Sample(page: Fixtures.page1, point: Point(x, 0), time: t)
        }
        trail.move(at(0, 0), mode: .trail)
        trail.move(at(10, 0.3), mode: .trail)
        trail.move(at(20, 0.6), mode: .trail)
        let alphas = trail.segmentAlphas(now: 0.7, lifetime: lifetime)        // older ends are 0.7 s and 0.4 s old
        XCTAssertEqual(alphas.count, 2)
        XCTAssertEqual(alphas[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(alphas[1], 1, accuracy: 1e-9)

        trail.lift(at: 0.6)
        trail.move(at(100, 0.8), mode: .trail)                              // a new touch never joins the old trail
        XCTAssertEqual(trail.segmentAlphas(now: 0.8, lifetime: lifetime).last, 0)
        XCTAssertEqual(trail.dotAlpha(now: 0.8), 1)

        trail.prune(now: 1.35, lifetime: lifetime)                          // points older than the lifetime go
        XCTAssertEqual(trail.samples.map(\.point.x), [20, 100])
        trail.lift(at: 1.35)
        XCTAssertEqual(trail.dotAlpha(now: 1.65), 0.5, accuracy: 1e-9)      // the dot fades over 0.6 s as well
        trail.prune(now: 2.0, lifetime: lifetime)
        XCTAssertNil(trail.head)
        XCTAssertFalse(trail.isAnimating)
    }

    func testDotModeKeepsNoTrailAndFadingBandsCoverTheRange() {
        var trail = LaserTrail()
        trail.move(LaserTrail.Sample(page: Fixtures.page1, point: Point(1, 1), time: 0), mode: .dot)
        trail.move(LaserTrail.Sample(page: Fixtures.page1, point: Point(5, 5), time: 0.1), mode: .dot)
        XCTAssertTrue(trail.samples.isEmpty)
        XCTAssertEqual(trail.head?.point, Point(5, 5))
        XCTAssertFalse(trail.isAnimating, "a resting dot needs no display link")

        XCTAssertEqual(LaserStyle.band(for: 1), LaserStyle.bands - 1)
        XCTAssertEqual(LaserStyle.band(for: 0.001), 0)
        XCTAssertEqual(LaserStyle.bandOpacity(LaserStyle.bands - 1), 1)
        for alpha in stride(from: 0.01, through: 1, by: 0.01) {
            XCTAssertLessThan(abs(LaserStyle.bandOpacity(LaserStyle.band(for: alpha)) - alpha), 1 / Double(LaserStyle.bands) + 1e-9)
        }
    }
}
