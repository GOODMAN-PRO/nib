import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatRuler

/// Acceptance (F039): strokes that start within 20 pt of an edge are projected onto that edge, at several angles.
@MainActor
final class RulerProjectionTests: XCTestCase {
    private let angles: [Double] = [0, 30, 45, 90, 135, 180, 237.5, 315]

    private func ruler(_ angle: Double) -> RulerGeometry {
        RulerGeometry(center: Point(300, 400), angle: angle, thickness: 64)
    }

    /// A wobbly pass along the ruler, from u = -150 to u = 150, starting at `v` across it.
    private func pass(_ g: RulerGeometry, startingAt v: Double) -> [StrokePoint] {
        (0...15).map { (i: Int) -> StrokePoint in
            let u = -150 + Double(i) * 20
            let wobble = i == 0 ? 0 : (i % 2 == 0 ? 4.0 : -4.0)
            let p = g.point(u: u, v: v + wobble)
            return StrokePoint(x: Float(p.x), y: Float(p.y), t: Float(i) * 0.01, force: 0.4, width: 1.2, height: 1.2)
        }
    }

    private func assertOnLine(_ points: [StrokePoint], of g: RulerGeometry, v: Double, matching original: [StrokePoint],
                              _ message: String, line: UInt = #line) {
        XCTAssertEqual(points.count, original.count, message, line: line)
        for (p, o) in zip(points, original) {
            let got = g.local(p.location), was = g.local(o.location)
            XCTAssertEqual(got.v, v, accuracy: 0.01, "\(message): off the edge", line: line)
            XCTAssertEqual(got.u, was.u, accuracy: 0.01, "\(message): moved along the ruler", line: line)
            XCTAssertEqual(p.t, o.t, message, line: line)
            XCTAssertEqual(p.force, o.force, message, line: line)
            XCTAssertEqual(p.width, o.width, message, line: line)
        }
    }

    func testStrokesStartingOutsideAnEdgeLieAlongItAtEveryAngle() {
        for angle in angles {
            let g = ruler(angle)
            // 8 pt outside the upper edge, then 13 pt outside the lower one.
            for (start, side) in [(-40.0, -1.0), (45.0, 1.0)] {
                let original = pass(g, startingAt: start)
                var points = original
                XCTAssertTrue(g.project(&points, reach: 20, inset: 0.6), "angle \(angle), side \(side)")
                assertOnLine(points, of: g, v: side * (32 + 0.6), matching: original, "angle \(angle), side \(side)")
            }
        }
    }

    func testAStrokeStartingJustInsideTheRulerSnapsToTheNearerEdge() {
        for angle in angles {
            let g = ruler(angle)
            let original = pass(g, startingAt: 20)            // 12 pt inside the lower edge
            var points = original
            XCTAssertTrue(g.project(&points, reach: 20, inset: 0), "angle \(angle)")
            assertOnLine(points, of: g, v: 32, matching: original, "angle \(angle)")
        }
    }

    func testStrokesAwayFromTheEdgesAreLeftAlone() {
        for angle in angles {
            let g = ruler(angle)
            for start in [-60.0, 0.0, 53.0] {                // 28 pt outside, the middle, 21 pt outside
                let original = pass(g, startingAt: start)
                var points = original
                XCTAssertFalse(g.project(&points, reach: 20, inset: 0.6), "angle \(angle), start \(start)")
                XCTAssertEqual(points, original)
            }
            // Next to an edge, but beyond the ruler's end.
            let beyond = g.point(u: RulerMetrics.length / 2 + 10, v: -40)
            var points = [StrokePoint(x: Float(beyond.x), y: Float(beyond.y))]
            XCTAssertFalse(g.project(&points, reach: 20, inset: 0))
        }
    }

    func testTheAngleRunsAnticlockwiseOnScreen() {
        let g = ruler(90)
        XCTAssertEqual(g.axis.x, 0, accuracy: 1e-9)
        XCTAssertEqual(g.axis.y, -1, accuracy: 1e-9, "at 90° the ruler points up the page (y grows downward)")
        let level = ruler(0)
        XCTAssertEqual(level.edge(near: Point(300, 400 + 32 + 5), reach: 20), 1, "+1 is the edge below a level ruler")
    }

    // MARK: The processor

    private func showRuler(_ h: Harness, angle: Double, at position: [Double]) async throws {
        let p: JSONValue = ["visible": true, "angle": .number(angle),
                            "position": .array(position.map { JSONValue.number($0) })]
        try await h.run(RulerSet.id, p)
    }

    func testTheProcessorProjectsPenPencilAndHighlighterButNotTape() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let processor = RulerProcessor()
        var pen = Stroke(style: .defaultPen, points: pass(ruler(30), startingAt: -40), t0: 0)
        XCTAssertTrue(processor.process(&pen, page: Fixtures.page1, session: h.session))
        XCTAssertEqual(pen.points, pass(ruler(30), startingAt: -40), "the ruler is hidden")

        try await showRuler(h, angle: 30, at: [300, 400])
        for style in [InkStyle.defaultPen, .defaultPencil, .defaultHighlighter] {
            let original = pass(ruler(30), startingAt: -40)
            var stroke = Stroke(style: style, points: original, t0: 0)
            XCTAssertTrue(processor.process(&stroke, page: Fixtures.page1, session: h.session))
            assertOnLine(stroke.points, of: ruler(30), v: -(32 + style.width / 2), matching: original, "\(style.tool)")
            XCTAssertEqual(stroke.style, style)
        }
        let original = pass(ruler(30), startingAt: -40)
        var tape = Stroke(style: .defaultTape, points: original, t0: 0)
        XCTAssertTrue(processor.process(&tape, page: Fixtures.page1, session: h.session))
        XCTAssertEqual(tape.points, original)
    }

    func testTheProcessorIsRegisteredAsRulerProjectAtOrder50() {
        let h = Harness(features: [FeatRulerFeature.self])
        let entry = h.app.content.strokeProcessors.get("ruler.project")
        XCTAssertEqual(entry?.order, 50)
        XCTAssertEqual(entry?.owner, "ruler")
        XCTAssertTrue(entry?.processor is RulerProcessor)
    }

    func testAStrokeOnTheNextPageUsesTheCanvasLayout() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        let host = FakeCanvasHost(h)                           // page 2 starts 20 pt below page 1
        let editor = FakeEditor(host)
        h.session.editor = editor
        try await showRuler(h, angle: 0, at: [300, 880])      // hangs off the bottom of page 1
        let page2Top = Double(host.pageFrame(Fixtures.page2)?.minY ?? 0)
        let centreOnPage2 = 880 - page2Top                     // 18.11
        let original = (0...5).map { StrokePoint(x: Float(100 + $0 * 30), y: Float(centreOnPage2 + 32 + 9)) }
        var stroke = Stroke(style: .defaultPen, points: original, t0: 0)
        XCTAssertTrue(RulerProcessor().process(&stroke, page: Fixtures.page2, session: h.session))
        for (p, o) in zip(stroke.points, original) {
            XCTAssertEqual(Double(p.y), centreOnPage2 + 32 + 0.6, accuracy: 0.01)
            XCTAssertEqual(p.x, o.x, accuracy: 0.01)
        }
        withExtendedLifetime(editor) {}
    }

    func testTheRulerKeepsItsScreenThicknessWhenZoomedIn() async throws {
        let h = Harness(features: [FeatRulerFeature.self])
        h.session.zoom = 2                                     // 64 view pt = 32 page pt
        try await showRuler(h, angle: 0, at: [300, 400])
        let original = (0...5).map { StrokePoint(x: Float(100 + $0 * 30), y: Float(400 - 16 - 10)) }
        var stroke = Stroke(style: .defaultPen, points: original, t0: 0)
        XCTAssertTrue(RulerProcessor().process(&stroke, page: Fixtures.page1, session: h.session))
        XCTAssertTrue(stroke.points.allSatisfy { abs(Double($0.y) - (400 - 16 - 0.6)) < 0.01 })
        XCTAssertEqual(RulerMetrics.pageThickness(zoom: 0.5), 64, "below 100 % the ruler shrinks with the page")
        XCTAssertEqual(RulerMetrics.viewThickness(zoom: 0.5), 32)
    }
}

/// The editor a canvas host belongs to (the processor finds page frames through `session.editor?.canvasHost`).
@MainActor
final class FakeEditor: DocumentEditing {
    let documentID: DocumentID
    let session: EditorSession
    let canvasHost: CanvasHost?

    init(_ host: FakeCanvasHost) {
        documentID = host.documentID
        session = host.session
        canvasHost = host
    }

    func reveal(page: PageID, rect: Rect?, animated: Bool) {}
    func reloadAll() {}
}
