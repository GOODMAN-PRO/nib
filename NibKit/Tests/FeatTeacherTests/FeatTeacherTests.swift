import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
@testable import FeatTeacher

/// Records what the attachment puts into the window's droplet container.
@MainActor
private final class FakeFloatingHost: FloatingHosting {
    var presented: [String: AnyView] = [:]
    var anchors: [String: CGRect] = [:]

    func present(_ id: String, content: AnyView) { presented[id] = content }
    func dismiss(_ id: String) { presented[id] = nil }
    func isPresenting(_ id: String) -> Bool { presented[id] != nil }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        anchors[id] = rect
        return true
    }
    func removeAnchor(_ id: String) { anchors[id] = nil }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {}
}

@MainActor
final class FeatTeacherTests: XCTestCase {
    private let page2 = "page:FIXTUREDOC01/FIXTUREPG002"
    private let zoneID: ElementID = "ZONE00000001"

    private func harness() -> Harness { Harness(features: [FeatTeacherFeature.self]) }

    private func item(_ h: Harness, _ id: ElementID, page: PageID = Fixtures.page2) throws -> Item {
        try h.app.workspace.item(Fixtures.docID, page: page, id: id)
    }

    private func zone(_ h: Harness, _ id: ElementID, page: PageID = Fixtures.page2) throws -> AnswerZone {
        try XCTUnwrap(AnswerZone.decode(item(h, id, page: page)))
    }

    @discardableResult
    private func create(_ h: Harness, id: String = "ZONE00000001", rect: [Double] = [72, 120, 320, 140],
                        points: Double? = 5, hints: [String] = ["First", "Second"]) async throws -> String {
        var params: [String: JSONValue] = ["page": .string(page2), "rect": .array(rect.map { JSONValue.number($0) }),
                                           "id": .string(id), "hints": .array(hints.map { JSONValue.string($0) })]
        if let points { params["points"] = .number(points) }
        let r = try await h.run(CommandIDs.answerZoneCreate, .object(params))
        return try XCTUnwrap(r["ref"]?.stringValue)
    }

    private func expectError(_ code: NibError.Code, path: String? = nil, _ body: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, "\(e)", file: file, line: line)
            if let path { XCTAssertEqual(e.path, path, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Registration and conformance

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatTeacherFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsTypeDrawerTapHandlersAttachmentInspectorAndMenus() {
        let h = harness()
        for id in [CommandIDs.answerZoneCreate, CommandIDs.answerZoneScore, CommandIDs.answerZoneSetHints,
                   CommandIDs.answerZoneRevealHint] {
            let d = h.app.commands.descriptor(id)
            XCTAssertEqual(d?.owner, FeatTeacherFeature.id, id)
            XCTAssertEqual(d?.effect, .edit, id)
        }
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.answerZoneRevealHint)?.undoable, false)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.answerZoneScore)?.undoable, true)

        let type = h.app.content.customItemTypes.get("custom.nib.answerZone.zone")
        XCTAssertEqual(type?.textPath, "label")
        XCTAssertEqual(type?.owner, FeatTeacherFeature.id)
        XCTAssertNotNil(h.app.content.drawers.get(AnswerZone.drawKey))

        let taps = h.app.content.tapHandlers.all.filter { $0.command == CommandIDs.answerZoneRevealHint }
        XCTAssertEqual(Set(taps.map(\.gesture)), [.tap, .longPress])
        XCTAssertTrue(taps.allSatisfy { $0.drawKeys == [AnswerZone.drawKey] && $0.owner == FeatTeacherFeature.id })

        XCTAssertEqual(h.app.ui.canvasAttachments.get(AnswerZoneAttachment.id)?.docKinds, [.notebook, .whiteboard])
        XCTAssertEqual(h.app.ui.inspectors.get(TeacherIDs.inspector)?.drawKeys, [AnswerZone.drawKey])
        XCTAssertEqual(h.app.ui.menus.get(TeacherIDs.addMenu)?.location, .pageLongPress)
        XCTAssertEqual(h.app.ui.menus.get(TeacherIDs.selectionMenu)?.location, .objectMenu)
    }

    // MARK: answerZone.create

    func testCreateUndoRoundTrip() async throws {
        let h = harness()
        let before = try h.snapshot()
        let ref = try await create(h)
        XCTAssertEqual(ref, "item:FIXTUREDOC01/FIXTUREPG002/ZONE00000001")
        let it = try item(h, zoneID)
        XCTAssertEqual(it.drawKey, AnswerZone.drawKey)
        XCTAssertEqual(it.custom?.frame, Frame(x: 72, y: 120, w: 320, h: 140))
        XCTAssertEqual(it.createdBy, "user")
        XCTAssertFalse(it.custom?.display.ops.isEmpty ?? true, "the stored drawing survives without this feature")
        let z = try zone(h, zoneID)
        XCTAssertEqual(z.points, 5)
        XCTAssertNil(z.score)
        XCTAssertEqual(z.hints, ["First", "Second"])
        XCTAssertEqual(z.revealed, 0)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try zone(h, zoneID).hints, ["First", "Second"])
    }

    func testCreateSitsBelowEverythingAndIsClampedToThePage() async throws {
        let h = harness()
        let ref = try await h.run(CommandIDs.answerZoneCreate,
                                  ["page": "page:FIXTUREDOC01/FIXTUREPG001", "rect": [500, 800, 300, 100], "label": " Q1 "])
        guard case let .item(_, _, id)? = NodeRef(ref["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1)
        XCTAssertEqual(items.first?.id, id, "a zone is created under the page's other items")
        let frame = try XCTUnwrap(items.first?.custom?.frame)
        XCTAssertEqual(frame.x, PageSize.a4.width - 300, accuracy: 0.001)
        XCTAssertEqual(frame.y, PageSize.a4.height - 100, accuracy: 0.001)
        let z = try zone(h, id, page: Fixtures.page1)
        XCTAssertEqual(z.label, "Q1")
        XCTAssertNil(z.points)
    }

    func testCreateRejectsBadParams() async throws {
        let h = harness()
        await expectError(.invalidParams, path: "$.rect") {
            try await h.run(CommandIDs.answerZoneCreate, ["page": .string(self.page2), "rect": [10, 10, 5, 5]])
        }
        await expectError(.invalidParams, path: "$.rect") {
            try await h.run(CommandIDs.answerZoneCreate, ["page": .string(self.page2), "rect": [10, 10]])
        }
        await expectError(.invalidParams, path: "$.id") {
            try await h.run(CommandIDs.answerZoneCreate, ["page": .string(self.page2), "rect": [10, 10, 100, 100], "id": "not ok!"])
        }
        let tooMany: [JSONValue] = (1...11).map { .string("Hint \($0)") }
        await expectError(.invalidParams, path: "$.hints") {
            try await h.run(CommandIDs.answerZoneCreate, ["page": .string(self.page2), "rect": [10, 10, 100, 100], "hints": .array(tooMany)])
        }
        await expectError(.notFound) {
            try await h.run(CommandIDs.answerZoneCreate, ["page": "page:FIXTUREDOC01/NOSUCHPAGE01", "rect": [10, 10, 100, 100]])
        }
        try await create(h)
        await expectError(.conflict, path: "$.id") { try await self.create(h) }
        // The AI goes through the schema: a missing rect is caught before the command runs.
        await expectError(.invalidParams, path: "$.rect") {
            try await h.run(CommandIDs.answerZoneCreate, ["page": .string(self.page2)], as: .ai("chat1"))
        }
    }

    // MARK: answerZone.score

    func testScoreUndoRoundTrip() async throws {
        let h = harness()
        let ref = try await create(h)
        let before = try h.snapshot()
        let r = try await h.run(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": 3])
        XCTAssertEqual(r["refs"], [.string(ref)])
        XCTAssertEqual(r["score"]?.doubleValue, 3)
        XCTAssertEqual(r["points"]?.doubleValue, 5)
        let z = try zone(h, zoneID)
        XCTAssertEqual(z.score, 3)
        XCTAssertEqual(z.scoredBy, "user")
        XCTAssertNotNil(z.scoredAt)
        let stored = try XCTUnwrap(item(h, zoneID).custom?.display.ops.compactMap(\.text))
        XCTAssertTrue(stored.contains("3/5"), "\(stored)")

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try zone(h, zoneID).score, 3)
    }

    func testScoreRulesForOneZone() async throws {
        let h = harness()
        let ref = try await create(h)
        await expectError(.invalidParams, path: "$.score") {
            try await h.run(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": 6])
        }
        let bare = try await create(h, id: "ZONE00000002", rect: [72, 400, 200, 100], points: nil, hints: [])
        await expectError(.invalidParams, path: "$.points") {
            try await h.run(CommandIDs.answerZoneScore, ["ref": .string(bare), "score": 1])
        }
        await expectError(.invalidParams, path: "$.ref") {
            try await h.run(CommandIDs.answerZoneScore, ["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01", "score": 1])
        }
        // Passing points adds the score box; decimals keep two places.
        try await h.run(CommandIDs.answerZoneScore, ["ref": .string(bare), "score": 1.456, "points": 2], as: .ai("chat1"))
        var b = try zone(h, "ZONE00000002")
        XCTAssertEqual(b.points, 2)
        XCTAssertEqual(b.score, 1.46)
        XCTAssertEqual(b.scoredBy, "ai:chat1")
        // clear + points changes only the maximum; points 0 removes the box.
        try await h.run(CommandIDs.answerZoneScore, ["ref": .string(bare), "score": 0, "points": 10, "clear": true])
        b = try zone(h, "ZONE00000002")
        XCTAssertEqual(b.points, 10)
        XCTAssertNil(b.score)
        try await h.run(CommandIDs.answerZoneScore, ["ref": .string(bare), "score": 0, "points": 0])
        b = try zone(h, "ZONE00000002")
        XCTAssertNil(b.points)
        XCTAssertNil(b.score)
    }

    func testScoringAPageScoresEveryZoneCappedAtItsPointsInOneUndoStep() async throws {
        let h = harness()
        try await create(h, id: "ZONEA0000001", rect: [72, 100, 200, 100], points: 5)
        try await create(h, id: "ZONEB0000001", rect: [72, 300, 200, 100], points: 2)
        try await create(h, id: "ZONEC0000001", rect: [72, 500, 200, 100], points: nil)
        let before = try h.snapshot()
        let r = try await h.run(CommandIDs.answerZoneScore, ["ref": .string(page2), "score": 4])
        XCTAssertEqual(r["refs"]?.arrayValue?.count, 2)
        XCTAssertEqual(try zone(h, "ZONEA0000001").score, 4)
        XCTAssertEqual(try zone(h, "ZONEB0000001").score, 2)
        XCTAssertNil(try zone(h, "ZONEC0000001").score)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        // A document ref reaches every page.
        let all = try await h.run(CommandIDs.answerZoneScore, ["ref": "doc:FIXTUREDOC01", "score": 0, "clear": true])
        XCTAssertEqual(all["refs"]?.arrayValue?.count, 0, "nothing is scored, so nothing changes")
    }

    // MARK: answerZone.setHints

    func testSetHintsUndoRoundTrip() async throws {
        let h = harness()
        let ref = try await create(h)
        let before = try h.snapshot()
        let r = try await h.run(CommandIDs.answerZoneSetHints, ["ref": .string(ref), "hints": ["One", "  ", "Two ", "Three"]])
        XCTAssertEqual(r["hints"]?.intValue, 3)
        XCTAssertEqual(try zone(h, zoneID).hints, ["One", "Two", "Three"])
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(try zone(h, zoneID).hints, ["First", "Second"])
        let tooLong = String(repeating: "x", count: AnswerZone.maxHintLength + 1)
        await expectError(.invalidParams, path: "$.hints[1]") {
            try await h.run(CommandIDs.answerZoneSetHints, ["ref": .string(ref), "hints": ["ok", .string(tooLong)]])
        }
    }

    func testSetHintsKeepsOrResetsTheRecordOfShownHints() async throws {
        let h = harness()
        let ref = try await create(h, hints: ["A", "B", "C"])
        try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)])
        try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)])
        // Fixing wording keeps what was shown; a shorter list cannot show more than it holds.
        try await h.run(CommandIDs.answerZoneSetHints, ["ref": .string(ref), "hints": ["A."]])
        var z = try zone(h, zoneID)
        XCTAssertEqual(z.revealed, 1)
        XCTAssertEqual(z.usage.count, 2)
        try await h.run(CommandIDs.answerZoneSetHints, ["ref": .string(ref), "hints": ["A.", "B."], "resetUsage": true])
        z = try zone(h, zoneID)
        XCTAssertEqual(z.revealed, 0)
        XCTAssertEqual(z.usage, [])
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID), "a reset is an ordinary undoable edit")
        XCTAssertEqual(try zone(h, zoneID).usage.count, 2)
    }

    // MARK: answerZone.revealHint

    func testRevealHintOneAtATimeRecordsUsageThatUndoCannotErase() async throws {
        let h = harness()
        let ref = try await create(h)
        let depth = h.undoDepth(Fixtures.docID)

        let first = try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)])
        XCTAssertEqual(first["handled"]?.boolValue, true)
        XCTAssertEqual(first["hint"]?.stringValue, "First")
        XCTAssertEqual(first["number"]?.intValue, 1)
        XCTAssertEqual(first["revealed"]?.intValue, 1)
        XCTAssertEqual(first["total"]?.intValue, 2)
        let second = try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)], as: .ai("chat1"))
        XCTAssertEqual(second["hint"]?.stringValue, "Second")
        let third = try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)])
        XCTAssertNil(third["hint"]?.stringValue, "nothing left to reveal")
        XCTAssertEqual(third["revealed"]?.intValue, 2)

        let z = try zone(h, zoneID)
        XCTAssertEqual(z.revealed, 2)
        XCTAssertEqual(z.usage.map(\.hint), [0, 1])
        XCTAssertEqual(z.usage.map(\.by), ["user", "ai:chat1"])
        XCTAssertTrue(z.usage.allSatisfy { $0.at > 1_700_000_000 })
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth, "revealing a hint adds no undo step")
        // Undo reaches the step before the reveals, and cannot bring back a record the reveals changed since.
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try zone(h, zoneID).revealed, 2)
        XCTAssertEqual(try zone(h, zoneID).usage.count, 2)
    }

    func testRevealHintOnAPageUsesTheFirstZoneWithHintsLeft() async throws {
        let h = harness()
        try await create(h, id: "ZONEB0000001", rect: [72, 400, 200, 100], hints: ["b1", "b2"])
        try await create(h, id: "ZONEA0000001", rect: [72, 100, 200, 100], hints: ["a1"])
        try await create(h, id: "ZONEC0000001", rect: [300, 100, 200, 100], hints: [])
        var hints: [String?] = []
        for _ in 0..<4 {
            let r = try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(page2)])
            hints.append(r["hint"]?.stringValue)
        }
        XCTAssertEqual(hints, ["a1", "b1", "b2", nil])
        let none = try await h.run(CommandIDs.answerZoneRevealHint, ["ref": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(none["handled"]?.boolValue, false)
    }

    func testTapHandlerRevealsOnlyFromTheHintWidget() async throws {
        let h = harness()
        let ref = try await create(h)
        let it = try item(h, zoneID)
        h.session.zoom = 2
        let slot = try XCTUnwrap(AnswerZoneLayout.slots(zoneBounds: it.bounds, zoom: 2, hasScore: true, hasHints: true).hint)
        let onWidget: JSONValue = [.number(slot.midX), .number(slot.midY)]

        let miss = try await h.run(CommandIDs.answerZoneRevealHint,
                                   ["page": .string(page2), "point": [100, 240], "ref": .string(ref), "gesture": "tap"])
        XCTAssertEqual(miss["handled"]?.boolValue, false)
        let peek = try await h.run(CommandIDs.answerZoneRevealHint,
                                   ["page": .string(page2), "point": onWidget, "ref": .string(ref), "gesture": "longPress"])
        XCTAssertEqual(peek["handled"]?.boolValue, true)
        XCTAssertEqual(try zone(h, zoneID).revealed, 0, "a long-press only shows what is revealed")
        let tap = try await h.run(CommandIDs.answerZoneRevealHint,
                                  ["page": .string(page2), "point": onWidget, "ref": .string(ref), "gesture": "tap"])
        XCTAssertEqual(tap["handled"]?.boolValue, true)
        XCTAssertEqual(tap["hint"]?.stringValue, "First")
        XCTAssertEqual(try zone(h, zoneID).revealed, 1)
        // A 44-point target: a tap just outside the drawn widget still counts.
        let edge: JSONValue = [.number(slot.midX), .number(slot.minY - 2)]
        let near = try await h.run(CommandIDs.answerZoneRevealHint,
                                   ["page": .string(page2), "point": edge, "ref": .string(ref), "gesture": "tap"])
        XCTAssertEqual(near["hint"]?.stringValue, "Second")
        h.session.readOnly = true
        let readOnly = try await h.run(CommandIDs.answerZoneRevealHint,
                                       ["page": .string(page2), "point": onWidget, "ref": .string(ref), "gesture": "tap"])
        XCTAssertEqual(readOnly["handled"]?.boolValue, false)
    }

    // MARK: Model, layout and drawing

    func testLenientDecoding() {
        let z = AnswerZone.decode(data: ["score": 7, "points": 5, "hints": ["a", " ", "b"], "revealed": 9, "label": "  ",
                                         "usage": [["hint": 1], "junk"]])
        XCTAssertEqual(z.points, 5)
        XCTAssertEqual(z.score, 5, "a score never passes the maximum")
        XCTAssertEqual(z.hints, ["a", "b"])
        XCTAssertEqual(z.revealed, 2)
        XCTAssertNil(z.label)
        XCTAssertEqual(AnswerZone.decode(data: "not a zone"), AnswerZone())
        XCTAssertNil(AnswerZone.decode(data: ["score": 3]).score, "no score without a score box")
        let use = AnswerZone.decode(data: ["hints": ["a"], "revealed": 1, "usage": [["hint": 0]]]).usage
        XCTAssertEqual(use, [AnswerZone.HintUse(hint: 0, at: 0, by: "user")])
    }

    func testSlotsHitRectsReadingOrderAndClamp() {
        let tall = AnswerZoneLayout.slots(zoneBounds: Rect(x: 0, y: 0, width: 300, height: 140), zoom: 1,
                                          hasScore: true, hasHints: true)
        XCTAssertEqual(tall.score, Rect(x: 224, y: 4, width: 72, height: 32))
        XCTAssertEqual(tall.hint, Rect(x: 224, y: 40, width: 72, height: 32))
        let short = AnswerZoneLayout.slots(zoneBounds: Rect(x: 0, y: 0, width: 300, height: 50), zoom: 1,
                                           hasScore: true, hasHints: true)
        XCTAssertEqual(short.hint, Rect(x: 148, y: 4, width: 72, height: 32))
        let hintsOnly = AnswerZoneLayout.slots(zoneBounds: Rect(x: 10, y: 10, width: 300, height: 140), zoom: 2,
                                               hasScore: false, hasHints: true)
        XCTAssertNil(hintsOnly.score)
        XCTAssertEqual(hintsOnly.hint, Rect(x: 310 - 2 - 36, y: 12, width: 36, height: 16), "widgets keep their screen size")
        let hit = AnswerZoneLayout.hitRect(Rect(x: 0, y: 0, width: 72, height: 32), zoom: 1)
        XCTAssertEqual(hit, Rect(x: 0, y: -6, width: 72, height: 44))

        let a = Rect(x: 300, y: 100, width: 50, height: 50), b = Rect(x: 50, y: 104, width: 50, height: 50)
        let c = Rect(x: 10, y: 400, width: 50, height: 50)
        XCTAssertEqual([c, a, b].sorted(by: AnswerZoneLayout.readsBefore), [b, a, c])

        let clamped = AnswerZoneLayout.clamp(Frame(x: -20, y: 900, w: 700, h: 100), to: .a4)
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.w, PageSize.a4.width, accuracy: 0.001)
        XCTAssertEqual(clamped.y, PageSize.a4.height - 100, accuracy: 0.001)
    }

    func testDisplayListShowsTheScoreAndHintUseOnlyWherePrinted() {
        var z = AnswerZone(points: 5, hints: ["h1", "h2"])
        z.score = 2.5
        let size = PageSize(300, 140)
        let screen = AnswerZoneLayout.displayList(z, size: size, style: .outline, darkPaper: false)
        XCTAssertEqual(screen.ops.count, 1)
        XCTAssertEqual(screen.ops.first?.dash, AnswerZoneLayout.outlineDash)
        var full = AnswerZoneLayout.displayList(z, size: size, style: .full, darkPaper: false)
        XCTAssertEqual(full.ops.compactMap(\.text), [AnswerZoneFormat.number(2.5) + "/5"])
        XCTAssertEqual(full.ops.last?.stroke, AnswerZoneInk(darkPaper: false).mark)
        z.revealed = 1
        full = AnswerZoneLayout.displayList(z, size: size, style: .full, darkPaper: false)
        XCTAssertEqual(full.ops.compactMap(\.text).count, 2)
        XCTAssertTrue(full.ops.compactMap(\.text).last?.contains("1/2") ?? false)
        z.score = nil
        full = AnswerZoneLayout.displayList(z, size: size, style: .full, darkPaper: false)
        XCTAssertEqual(full.ops.compactMap(\.text).first, "/5", "an unscored box leaves room for a handwritten score")
        let dark = AnswerZoneLayout.displayList(z, size: size, style: .outline, darkPaper: true)
        XCTAssertNotEqual(dark.ops.first?.stroke, screen.ops.first?.stroke)
    }

    func testDrawerDrawsTheBoxOnScreenAndTheScoreInExports() throws {
        var z = AnswerZone(points: 5)
        z.score = 4
        let it = try z.makeItem(frame: Frame(x: 10, y: 10, w: 200, h: 100), layer: 0)
        func inkedPixels(_ purpose: DrawPurpose) -> Int {
            let w = 220, h = 120
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return pixels.withUnsafeMutableBytes { raw -> Int in
                guard let cg = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
                cg.translateBy(x: 0, y: CGFloat(h))
                cg.scaleBy(x: 1, y: -1)
                AnswerZoneDrawer().draw(it, in: DrawContext(cg: cg, scale: 1, doc: Fixtures.docID, page: Fixtures.page1,
                                                            purpose: purpose))
                return stride(from: 3, to: raw.count, by: 4).filter { raw[$0] > 0 }.count
            }
        }
        let screen = inkedPixels(.screen), export = inkedPixels(.export)
        XCTAssertGreaterThan(screen, 0)
        XCTAssertGreaterThan(export, screen, "exports add the score box and its score")
    }

    // MARK: Canvas attachment

    func testAttachmentPlacesWidgetsAndClaimsOnlyTheScoreWidget() async throws {
        let h = harness()
        let ref = try await create(h)
        let host = FakeCanvasHost(h)
        let attachment = AnswerZoneAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }

        let score = try XCTUnwrap(attachment.scoreViews[zoneID])
        let hint = try XCTUnwrap(attachment.hintViews[zoneID])
        XCTAssertTrue(score.superview === host.canvasView)
        XCTAssertEqual(score.text, "\u{2013}/5")
        XCTAssertEqual(hint.text, "0/2")
        XCTAssertEqual(score.bounds.size, CGSize(width: 72, height: 32))
        // The zone's top-right corner on page 2 (stacked under page 1 with a 20 pt gap).
        let pageTop = (PageSize.a4.height + 20)
        XCTAssertEqual(score.restingFrame.maxX, 72 + 320 - 4, accuracy: 0.01)
        XCTAssertEqual(score.restingFrame.minY, pageTop + 120 + 4, accuracy: 0.01)
        XCTAssertEqual(hint.restingFrame.minY, score.restingFrame.maxY + 4, accuracy: 0.01)
        XCTAssertEqual(score.accessibilityLabel, "Score, Answer Zone 1")
        XCTAssertEqual(score.accessibilityValue, "Not scored, out of 5")
        XCTAssertTrue(score.accessibilityTraits.contains(.adjustable))

        let onScore = CGPoint(x: score.center.x, y: score.center.y)
        XCTAssertTrue(attachment.hitTest(onScore, isPencil: false, host: host))
        XCTAssertTrue(attachment.hitTest(CGPoint(x: onScore.x, y: score.restingFrame.minY - 5), isPencil: true, host: host),
                      "44 pt target")
        XCTAssertFalse(attachment.hitTest(CGPoint(x: hint.center.x, y: hint.center.y), isPencil: false, host: host),
                       "hint taps go to content.tapHandlers")
        XCTAssertFalse(attachment.hitTest(CGPoint(x: 10, y: 10), isPencil: false, host: host))

        // Commits (edits, undo) update the widgets.
        try await h.run(CommandIDs.answerZoneScore, ["ref": .string(ref), "score": 4])
        XCTAssertEqual(attachment.scoreViews[zoneID]?.text, "4/5")
        XCTAssertEqual(attachment.scoreViews[zoneID]?.accessibilityValue, "4 of 5 points")
        try await h.run(CommandIDs.answerZoneRevealHint, ["ref": .string(ref)])
        XCTAssertEqual(attachment.hintViews[zoneID]?.text, "1/2")

        // Zooming keeps the widgets' screen size; hiding the zone's layer hides them.
        host.zoomScale = 0.5
        attachment.canvasDidChange(host)
        XCTAssertEqual(attachment.scoreViews[zoneID]?.bounds.size, CGSize(width: 72, height: 32))
        XCTAssertEqual(attachment.scoreViews[zoneID]?.restingFrame.maxX ?? 0, (72 + 320) * 0.5 - 4, accuracy: 0.01)
        host.zoomScale = 1
        h.session.hiddenLayers = [0]
        attachment.canvasDidChange(host)
        XCTAssertNil(attachment.scoreViews[zoneID])
        h.session.hiddenLayers = []
        attachment.canvasDidChange(host)
        XCTAssertNotNil(attachment.scoreViews[zoneID])

        // Read-only windows show the score but do not take the touch.
        h.session.readOnly = true
        XCTAssertFalse(attachment.hitTest(onScore, isPencil: false, host: host))
        h.session.readOnly = false

        // While the Pencil is down the widgets step back.
        h.session.inking.begin()
        XCTAssertEqual(attachment.scoreViews[zoneID]?.alpha ?? 0, CGFloat(0.22), accuracy: 0.001)
        h.session.inking.end()
        XCTAssertEqual(attachment.scoreViews[zoneID]?.alpha, 1)

        // VoiceOver adjust scores one point at a time.
        _ = attachment.scoreViews[zoneID]?.accessibilityIncrement()
        try await waitUntil { (try? self.zone(h, self.zoneID).score) == 5 }
        XCTAssertEqual(try zone(h, zoneID).score, 5)
    }

    func testAttachmentDropsWidgetsWhenTheZoneGoesAndOnDetach() async throws {
        let h = harness()
        try await create(h)
        let host = FakeCanvasHost(h)
        let attachment = AnswerZoneAttachment()
        attachment.attach(to: host)
        XCTAssertEqual(attachment.scoreViews.count, 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertTrue(attachment.scoreViews.isEmpty)
        XCTAssertTrue(attachment.hintViews.isEmpty)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(attachment.hintViews.count, 1)
        let views = Array(attachment.scoreViews.values) + Array(attachment.hintViews.values)
        attachment.detach(from: host)
        XCTAssertTrue(views.allSatisfy { $0.superview == nil })
        XCTAssertNil(AnswerZoneUI.attachment(for: h.session))
    }

    func testWidgetsBudTheScorePopoverAndATappedHintShowsTheHintsCard() async throws {
        let h = harness()
        let ref = try await create(h)
        let host = FakeCanvasHost(h)
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let attachment = AnswerZoneAttachment()
        attachment.attach(to: host)
        defer { attachment.detach(from: host) }
        let score = try XCTUnwrap(attachment.scoreViews[zoneID])
        let hint = try XCTUnwrap(attachment.hintViews[zoneID])

        // A finger tap on the score widget buds the score popover from it (and a second tap folds it away).
        let sample = CanvasSample(page: Fixtures.page2, location: Point(score.center.x, score.center.y - (PageSize.a4.height + 20)),
                                  isPencil: false)
        attachment.touchesBegan(sample, host: host)
        attachment.touchesEnded(sample, host: host)
        XCTAssertTrue(floating.isPresenting(AnswerZoneUI.scorePopoverID))
        XCTAssertEqual(floating.anchors[AnswerZoneUI.scoreSourceID], score.restingFrame)
        XCTAssertTrue(attachment.gesture(.tap, at: sample, host: host), "the widget's taps never reach the page")

        // The canvas routes a tap on the hint widget to answerZone.revealHint, which asks for the hints card.
        let point: JSONValue = [.number(Double(hint.center.x)), .number(Double(hint.center.y) - (PageSize.a4.height + 20))]
        let r = try await h.run(CommandIDs.answerZoneRevealHint,
                                ["page": .string(page2), "point": point, "ref": .string(ref), "gesture": "tap"])
        XCTAssertEqual(r["hint"]?.stringValue, "First")
        XCTAssertTrue(floating.isPresenting(AnswerZoneUI.hintsPopoverID))
        XCTAssertEqual(floating.anchors[AnswerZoneUI.hintsSourceID], hint.restingFrame)
        XCTAssertEqual(attachment.hintViews[zoneID]?.text, "1/2")
    }

    // MARK: Menus

    func testMenusBuildCreateParams() async throws {
        let h = harness()
        let add = try XCTUnwrap(h.app.ui.menus.get(TeacherIDs.addMenu))
        let at = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page2, point: Point(200, 300))
        XCTAssertTrue(add.isVisible(at))
        let params = add.params(at)
        XCTAssertEqual(params["page"]?.stringValue, page2)
        XCTAssertEqual(params["rect"], [60, 240, 280, 120])
        let r = try await h.run(add.command, params)
        XCTAssertNotNil(r["ref"]?.stringValue)
        h.session.readOnly = true
        XCTAssertFalse(add.isVisible(at))
        h.session.readOnly = false

        let make = try XCTUnwrap(h.app.ui.menus.get(TeacherIDs.selectionMenu))
        let selection = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.textID],
                                  bounds: Rect(x: 72, y: 400, width: 300, height: 40))
        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, selection: selection)
        XCTAssertTrue(make.isVisible(ctx))
        XCTAssertEqual(make.params(ctx)["rect"], [64, 392, 316, 56])
        let zoneRef = try await h.run(make.command, make.params(ctx))
        guard case let .item(_, _, id)? = NodeRef(zoneRef["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        let withZone = Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [id], bounds: Rect(x: 64, y: 392, width: 316, height: 56))
        XCTAssertFalse(make.isVisible(MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1,
                                                  selection: withZone)), "a zone is not made from a zone")
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
