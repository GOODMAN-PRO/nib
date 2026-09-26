import XCTest
import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import NibContracts
import NibTesting
@testable import FeatStudyEditor

@MainActor
final class FeatStudyEditorTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatStudyEditorFeature.self]) }

    private func liveCards(_ h: Harness, _ doc: DocumentID = Fixtures.studySetID) throws -> [StudyCard] {
        try h.app.workspace.content(doc).liveCards
    }

    private func expectError(_ code: NibError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Commands

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatStudyEditorFeature.self], owners: [FeatStudyEditorFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersExactlyTheCardCommandsAndTheStudySetEditor() {
        let h = harness()
        let ids = h.app.commands.all().filter { $0.owner == FeatStudyEditorFeature.id }.map { $0.id }
        XCTAssertEqual(ids, ["card.add", "card.delete", "card.move", "card.moveTo", "card.update"])
        let editor = h.app.ui.editors.get(DocumentKind.studySet.rawValue)
        XCTAssertEqual(editor?.owner, FeatStudyEditorFeature.id)
        XCTAssertTrue(editor?.make(Fixtures.studySetID, h.session, h.app) is DocumentEditing)
        XCTAssertNotNil(h.app.ui.panels.get(ScratchPaper.panelID))
    }

    func testAddBuildsFacesFromStringsAndObjects() async throws {
        let h = harness()
        let r = try await h.run("card.add", try JSONValue.parse(
            #"{"doc": "doc:FIXTUREDOC03", "front": {"ink": [{"fmt": "xy", "pts": [10, 10, 300, 10]}]}, "back": "Line", "id": "INKCARD00001"}"#))
        XCTAssertEqual(r["ref"]?.stringValue, "card:FIXTUREDOC03/INKCARD00001")
        let card = try XCTUnwrap(try liveCards(h).first(where: { $0.id == NibID("INKCARD00001") }))
        XCTAssertEqual(card.front.kind, .ink)
        let stroke = try XCTUnwrap(card.front.ink?.first)
        XCTAssertGreaterThan(stroke.points.count, 2, "AI ink is densified like ink.addStrokes")
        XCTAssertTrue(stroke.points.allSatisfy { $0.width > 0 })
        XCTAssertEqual(card.front.size, CardFaces.canvas)
        XCTAssertEqual(card.back.kind, .text)
        XCTAssertEqual(card.back.text?.plainText, "Line")
        XCTAssertEqual(try liveCards(h).last?.id, card.id, "without after, a card goes to the end")

        try await h.run("card.add", try JSONValue.parse(
            #"{"doc": "FIXTUREDOC03", "front": {"text": "Photo"}, "back": {"asset": "fixture-image.png"}, "after": "FIXTURECRD01", "id": "PHOTOCARD001"}"#))
        XCTAssertEqual(try liveCards(h).map { $0.id.raw }, ["FIXTURECRD01", "PHOTOCARD001", "FIXTURECRD02", "INKCARD00001"])
        XCTAssertEqual(try liveCards(h)[1].back.kind, .image)
        XCTAssertEqual(try liveCards(h)[1].back.asset, Fixtures.pngAsset)
    }

    func testAddRejectsOtherKindsMissingPicturesAndTakenIDs() async throws {
        let h = harness()
        await expectError(.invalidParams) {
            try await h.run("card.add", ["doc": "doc:FIXTUREDOC01", "front": "a", "back": "b"])
        }
        await expectError(.notFound) {
            try await h.run("card.add", try JSONValue.parse(#"{"doc": "doc:FIXTUREDOC03", "front": "a", "back": {"asset": "missing.png"}}"#))
        }
        await expectError(.invalidParams) {
            try await h.run("card.add", try JSONValue.parse(#"{"doc": "doc:FIXTUREDOC03", "front": {"kind": "image"}, "back": "b"}"#))
        }
        await expectError(.invalidParams) {
            try await h.run("card.add", ["doc": "doc:FIXTUREDOC03", "front": "a", "back": "b", "id": "FIXTURECRD01"])
        }
        await expectError(.notFound) {
            try await h.run("card.add", ["doc": "doc:FIXTUREDOC03", "front": "a", "back": "b", "after": "NOSUCHCARD01"])
        }
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), 0)
        XCTAssertEqual(try liveCards(h).count, 2)
    }

    func testUpdateReplacesOnlyTheGivenSideAndUndoes() async throws {
        let h = harness()
        let before = try h.snapshot(Fixtures.studySetID)
        try await h.run("card.update", ["ref": "card:FIXTUREDOC03/FIXTURECRD02", "front": "Pixel"])
        let card = try XCTUnwrap(try liveCards(h).first(where: { $0.id == Fixtures.card2 }))
        XCTAssertEqual(card.front.text?.plainText, "Pixel")
        XCTAssertEqual(card.back.asset, Fixtures.pngAsset, "the other side is untouched")
        XCTAssertNotNil(card.srs, "practice progress is kept")
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try h.snapshot(Fixtures.studySetID), before)
        await expectError(.invalidParams) {
            try await h.run("card.update", ["ref": "card:FIXTUREDOC03/FIXTURECRD02"])
        }
        await expectError(.notFound) {
            try await h.run("card.update", ["ref": "card:FIXTUREDOC03/NOSUCHCARD01", "front": "x"])
        }
    }

    func testReorderAndDeleteUndoStepByStep() async throws {
        let h = harness()
        // Undo reverts a record only while it still carries the revision its entry wrote (ARCHITECTURE.md §6.3), so
        // the stacked steps here each write a different card.
        let before = try h.snapshot(Fixtures.studySetID)
        try await h.run("card.move", ["ref": "card:FIXTUREDOC03/FIXTURECRD02"])
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card2, Fixtures.card1])
        let moved = try h.snapshot(Fixtures.studySetID)
        try await h.run("card.delete", ["refs": ["card:FIXTUREDOC03/FIXTURECRD01", "card:FIXTUREDOC03/FIXTURECRD01"]])
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card2])
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), 2)
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try h.snapshot(Fixtures.studySetID), moved)
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try h.snapshot(Fixtures.studySetID), before)

        try await h.run("card.move", ["ref": "card:FIXTUREDOC03/FIXTURECRD01", "after": "card:FIXTUREDOC03/FIXTURECRD02"])
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card2, Fixtures.card1])
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try h.snapshot(Fixtures.studySetID), before)
        try await h.run("card.move", ["ref": "card:FIXTUREDOC03/FIXTURECRD02", "after": "card:FIXTUREDOC03/FIXTURECRD01"])
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), 0, "a card moved to where it already is writes nothing")
        await expectError(.invalidParams) {
            try await h.run("card.move", ["ref": "card:FIXTUREDOC03/FIXTURECRD01", "after": "FIXTURECRD01"])
        }
    }

    func testMoveRekeysCardsWhoseOrderKeysCannotBracket() async throws {
        let h = harness()
        let set = DocumentID("FLATSET00001")
        let flat = ["A", "B", "C"].map { StudyCard(id: NibID("CARD" + $0), front: CardFace(text: RichText(plain: $0)), back: CardFace()) }
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: set, kind: .studySet), cards: flat),
                                         title: "Flat", in: nil)
        try await h.run("card.move", ["ref": "card:FLATSET00001/CARDC", "after": "card:FLATSET00001/CARDA"])
        XCTAssertEqual(try liveCards(h, set).map { $0.id.raw }, ["CARDA", "CARDC", "CARDB"])
        h.app.bus.undo(set)
        XCTAssertEqual(try liveCards(h, set).map { $0.id.raw }, ["CARDA", "CARDB", "CARDC"])
    }

    func testMoveToAnotherSetCopiesPicturesKeepsProgressAndUndoes() async throws {
        let h = harness()
        let other = DocumentID("SECONDSET001")
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: other, kind: .studySet)), title: "Second", in: nil)
        let before = try h.snapshot(Fixtures.studySetID)
        let r = try await h.run("card.moveTo", ["refs": ["card:FIXTUREDOC03/FIXTURECRD02"], "doc": "doc:SECONDSET001"])
        XCTAssertEqual(r["refs"]?[0]?.stringValue, "card:SECONDSET001/FIXTURECRD02")
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card1])
        let moved = try XCTUnwrap(try liveCards(h, other).first)
        XCTAssertEqual(moved.srs?.reps, 1)
        let asset = try XCTUnwrap(moved.back.asset)
        XCTAssertEqual(try h.assets.data(asset, doc: other), Fixtures.pngData)
        h.app.bus.undo(Fixtures.studySetID)
        h.app.bus.undo(other)
        XCTAssertEqual(try h.snapshot(Fixtures.studySetID), before)
        XCTAssertTrue(try liveCards(h, other).isEmpty)
        await expectError(.invalidParams) {
            try await h.run("card.moveTo", ["refs": ["card:FIXTUREDOC03/FIXTURECRD01"], "doc": "doc:FIXTUREDOC02"])
        }
    }

    func testMoveToTakesGivenIDsKeepsCardsAlreadyThereAndRefusesTakenIDs() async throws {
        let h = harness()
        let other = DocumentID("SECONDSET001")
        let resident = StudyCard(id: NibID("RESIDENT0001"), front: CardFace(text: RichText(plain: "Here")), back: CardFace(),
                                 order: "V")
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: other, kind: .studySet), cards: [resident]),
                                         title: "Second", in: nil)
        // A card already in the set keeps its id and goes to the end; the other takes the id given for it.
        let r = try await h.run("card.moveTo", ["refs": ["card:SECONDSET001/RESIDENT0001", "card:FIXTUREDOC03/FIXTURECRD01"],
                                                "doc": "doc:SECONDSET001", "ids": ["UNUSEDID0001", "MOVEDCARD001"]])
        XCTAssertEqual(r["refs"]?[0]?.stringValue, "card:SECONDSET001/RESIDENT0001")
        XCTAssertEqual(r["refs"]?[1]?.stringValue, "card:SECONDSET001/MOVEDCARD001")
        XCTAssertEqual(try liveCards(h, other).map { $0.id.raw }, ["RESIDENT0001", "MOVEDCARD001"])
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card2])

        // An id the set already uses, or ids that do not match the refs, are refused and nothing moves.
        let before = try h.snapshot(Fixtures.studySetID)
        let destination = try h.snapshot(other)
        await expectError(.invalidParams) {
            try await h.run("card.moveTo", ["refs": ["card:FIXTUREDOC03/FIXTURECRD02"], "doc": "doc:SECONDSET001",
                                            "ids": ["RESIDENT0001"]])
        }
        await expectError(.invalidParams) {
            try await h.run("card.moveTo", ["refs": ["card:FIXTUREDOC03/FIXTURECRD02"], "doc": "doc:SECONDSET001",
                                            "ids": ["ONEID0000001", "TWOID0000001"]])
        }
        XCTAssertEqual(try h.snapshot(Fixtures.studySetID), before)
        XCTAssertEqual(try h.snapshot(other), destination)

        // Without ids, a card whose id the set already uses gets a fresh one.
        try await h.run("card.add", ["doc": "doc:FIXTUREDOC03", "front": "Twin", "back": "b", "id": "RESIDENT0001"])
        let twin = try await h.run("card.moveTo", ["refs": ["card:FIXTUREDOC03/RESIDENT0001"], "doc": "doc:SECONDSET001"])
        let ref = try XCTUnwrap(twin["refs"]?[0]?.stringValue)
        XCTAssertNotEqual(ref, "card:SECONDSET001/RESIDENT0001")
        XCTAssertEqual(try liveCards(h, other).count, 3)
        XCTAssertEqual(Set(try liveCards(h, other).map { $0.id }).count, 3)
    }

    func testMovingCardsFromTheEditorUndoesAndRedoesInBothSets() async throws {
        let h = harness()
        let other = DocumentID("SECONDSET001")
        _ = try h.library.createDocument(DocumentContent(meta: DocumentMeta(id: other, kind: .studySet)), title: "Second", in: nil)
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        await model.moveCards([Fixtures.card2], to: other)
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card1])
        XCTAssertEqual(try liveCards(h, other).map { $0.id }, [Fixtures.card2])

        // Undo in the set being edited takes the copies back out of the other set.
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card1, Fixtures.card2])
        XCTAssertTrue(try liveCards(h, other).isEmpty)
        XCTAssertEqual(h.undoDepth(other), 0)

        // Redo moves them again, in both sets.
        XCTAssertTrue(h.app.bus.redo(Fixtures.studySetID))
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card1])
        XCTAssertEqual(try liveCards(h, other).map { $0.id }, [Fixtures.card2])

        // Undo in the destination brings the cards back to the set they came from.
        XCTAssertTrue(h.app.bus.undo(other))
        XCTAssertTrue(try liveCards(h, other).isEmpty)
        XCTAssertEqual(try liveCards(h).map { $0.id }, [Fixtures.card1, Fixtures.card2])

        // A later edit in the other set stops the mirroring there: its own stack is left alone.
        XCTAssertTrue(h.app.bus.redo(Fixtures.studySetID))
        try await h.run("card.add", ["doc": "doc:SECONDSET001", "front": "New", "back": "b"])
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try liveCards(h, other).count, 2, "the destination's top entry is not the move")
    }

    // MARK: Freeform ink at the trust boundary

    func testFreeformInkFromAnywhereIsBoundedToItsCard() async throws {
        let h = harness()
        // Ink copied from far out on a whiteboard, with no size: the default card, the ink moved onto it.
        try await h.run("card.add", try JSONValue.parse(
            #"{"doc": "doc:FIXTUREDOC03", "front": {"ink": [{"fmt": "xy", "pts": [50000, 50000, 50400, 50100]}]}, "back": "Far", "id": "FARINK000001"}"#))
        // Negative coordinates, and a canvas far over the cap.
        try await h.run("card.add", try JSONValue.parse(
            #"{"doc": "doc:FIXTUREDOC03", "front": {"ink": [{"fmt": "xy", "pts": [-900, -300, -100, -40]}]}, "back": {"ink": [{"fmt": "xy", "pts": [9000, 9000, 9900, 9900]}], "size": {"width": 10000, "height": 10000}}, "id": "NEGINK000001"}"#))
        for id in ["FARINK000001", "NEGINK000001"] {
            let card = try XCTUnwrap(try liveCards(h).first(where: { $0.id == NibID(id) }))
            for face in [card.front, card.back] where face.kind == .ink {
                let size = try XCTUnwrap(face.size)
                XCTAssertLessThanOrEqual(size.width, CardFaces.maxCanvas.width)
                XCTAssertLessThanOrEqual(size.height, CardFaces.maxCanvas.height)
                let b = try XCTUnwrap(CardFaces.pointBounds(face.ink ?? []))
                XCTAssertGreaterThanOrEqual(b.minX, 0, id)
                XCTAssertGreaterThanOrEqual(b.minY, 0, id)
                XCTAssertLessThanOrEqual(b.maxX, size.width, id)
                XCTAssertLessThanOrEqual(b.maxY, size.height, id)
            }
        }
        let far = try XCTUnwrap(try liveCards(h).first(where: { $0.id == NibID("FARINK000001") }))
        XCTAssertEqual(far.front.size, CardFaces.canvas)
        XCTAssertLessThan(far.front.ink?.first?.points.count ?? .max, 1_000, "densified once it is on the card")
        let big = try XCTUnwrap(try liveCards(h).first(where: { $0.id == NibID("NEGINK000001") }))
        XCTAssertEqual(big.back.size?.width ?? 0, 1440, accuracy: 0.01, "10000 × 10000 shrinks, with its ink, to the cap")
        XCTAssertEqual(big.back.size?.height ?? 0, 1440, accuracy: 0.01)

        // One long AI segment is fitted before it is densified.
        try await h.run("card.update", try JSONValue.parse(
            #"{"ref": "card:FIXTUREDOC03/FIXTURECRD01", "back": {"ink": [{"fmt": "xy", "pts": [0, 100, 10000000, 100]}]}}"#))
        XCTAssertLessThan(try liveCards(h).first?.back.ink?.first?.points.count ?? .max, 1_000)
    }

    func testFreeformInkRejectsNonFiniteNumbersAndTooManyPoints() async throws {
        let h = harness()
        // 1e39 is beyond Float: it arrives as infinity.
        await expectError(.invalidParams) {
            try await h.run("card.add", try JSONValue.parse(
                #"{"doc": "doc:FIXTUREDOC03", "front": {"ink": [{"fmt": "xy", "pts": [1e39, 0, 10, 10]}]}, "back": "b"}"#))
        }
        let nan = CardFace(kind: .ink, ink: [Stroke(style: InkStyle(), points: [StrokePoint(x: .nan, y: 0), StrokePoint(x: 1, y: 1)])])
        XCTAssertThrowsError(try CardFaces.normalized(nan, path: "$.front")) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
            XCTAssertEqual((error as? NibError)?.path, "$.front.ink[0]")
        }
        let zeroSize = CardFace(kind: .ink, ink: [], size: PageSize(0, 360))
        XCTAssertThrowsError(try CardFaces.normalized(zeroSize, path: "$.back"))
        // A zig-zag across a large card: far more points than a side holds once densified.
        let zigzag = (0..<400).map { StrokePoint(x: $0 % 2 == 0 ? 0 : 2000, y: Float($0)) }
        let dense = CardFace(kind: .ink, ink: [Stroke(style: InkStyle(), points: zigzag)], size: PageSize(2000, 1400))
        XCTAssertThrowsError(try CardFaces.normalized(dense, path: "$.back")) { error in
            XCTAssertEqual((error as? NibError)?.code, .invalidParams)
        }
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), 0)
    }

    func testFreeformThumbnailsRenderAtABoundedScale() throws {
        let h = harness()
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        XCTAssertEqual(StudySetModel.inkThumbnailScale(canvas: CardFaces.canvas, displayScale: 3), 1)
        let scale = StudySetModel.inkThumbnailScale(canvas: PageSize(50_000, 30_000), displayScale: 3)
        XCTAssertLessThanOrEqual(50_000 * scale, 1_100)
        // A side stored before canvases were capped still renders small.
        let line = Stroke(style: InkStyle(), points: [StrokePoint(x: 100, y: 100, width: 2, height: 2),
                                                      StrokePoint(x: 49_000, y: 29_000, width: 2, height: 2)])
        let huge = CardFace(kind: .ink, ink: [line], size: PageSize(50_000, 30_000))
        let image = try XCTUnwrap(model.inkPicture(huge, key: "huge", displayScale: 3))
        XCTAssertLessThanOrEqual(image.size.width * image.scale, 1_100)
    }

    // MARK: Order keys and list moves

    func testOrderKeysStayStrictlyIncreasing() {
        let middle = CardOrder.place(at: 1, among: ["V", "k"])
        XCTAssertTrue(middle.rekeyed.isEmpty)
        XCTAssertTrue("V" < middle.key && middle.key < "k")
        XCTAssertLessThan(CardOrder.place(at: 0, among: ["V"]).key, "V")
        let flat = CardOrder.place(at: 1, among: ["", "", ""])
        var orders = ["", "", ""]
        for (i, key) in flat.rekeyed { orders[i] = key }
        orders.insert(flat.key, at: 1)
        XCTAssertEqual(orders, orders.sorted())
        XCTAssertEqual(Set(orders).count, 4)
    }

    func testListMoveDestinationBecomesTheCardToFollow() {
        let ids: [NibID] = ["A", "B", "C", "D"]
        XCTAssertNil(StudySetModel.anchor(movingFrom: 2, to: 0, in: ids))
        XCTAssertEqual(StudySetModel.anchor(movingFrom: 0, to: 2, in: ids), NibID("B"))
        XCTAssertEqual(StudySetModel.anchor(movingFrom: 0, to: 4, in: ids), NibID("D"))
        XCTAssertEqual(StudySetModel.anchor(movingFrom: 3, to: 1, in: ids), NibID("A"))
    }

    func testTabWalksTextFieldsAndSkipsPictureSides() {
        let ids: [NibID] = ["A", "B"]
        let isText: (NibID, CardSide) -> Bool = { id, side in !(id == NibID("A") && side == .back) }
        XCTAssertEqual(StudySetModel.neighbour(of: CardField(card: "A", side: .front), in: ids, forward: true, isText: isText),
                       CardField(card: "B", side: .front))
        XCTAssertEqual(StudySetModel.neighbour(of: CardField(card: "B", side: .front), in: ids, forward: false, isText: isText),
                       CardField(card: "A", side: .front))
        XCTAssertNil(StudySetModel.neighbour(of: CardField(card: "B", side: .back), in: ids, forward: true, isText: isText))
        XCTAssertEqual(StudySetModel.neighbour(of: CardField(card: "A", side: .back, inPane: true), in: ids, forward: true,
                                               isText: { _, _ in true }),
                       CardField(card: "B", side: .front, inPane: true))
    }

    // MARK: Editor model

    func testTypingCommitsEachPauseAsOneUndoStep() async throws {
        let h = harness()
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        let field = CardField(card: Fixtures.card1, side: .back)
        model.focus = field
        XCTAssertTrue(h.session.isEditingText)
        model.setText("Def", for: field)
        await model.flush()
        model.setText("Defined", for: field)
        await model.flush()
        XCTAssertEqual(h.undoDepth(Fixtures.studySetID), 2)
        XCTAssertEqual(try liveCards(h).first?.back.text?.plainText, "Defined")
        h.app.bus.undo(Fixtures.studySetID)
        let card = try XCTUnwrap(model.card(Fixtures.card1))
        XCTAssertEqual(card.back.text?.plainText, "Def")
        XCTAssertEqual(model.text(field.key, in: card), "Def", "undo replaces what the field shows")
        model.focus = nil
        XCTAssertFalse(h.session.isEditingText)
    }

    func testAddCardFocusesItsTermAndSwitchingModesWaitsForContent() async throws {
        let h = harness()
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        let added = await model.addCard(after: Fixtures.card1)
        let id = try XCTUnwrap(added)
        XCTAssertEqual(model.cards.map { $0.id }, [Fixtures.card1, id, Fixtures.card2])
        XCTAssertEqual(model.focus, CardField(card: id, side: .front))
        model.setMode(.ink, card: id, side: .back)
        XCTAssertEqual(model.mode(id, .back), .ink)
        XCTAssertEqual(try liveCards(h)[1].back.kind, .text, "a mode alone writes nothing")
        let line = Stroke(style: InkStyle(), points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 200, y: 40)])
        await model.update(id, .back, CardFace(kind: .ink, ink: [line], size: CardFaces.canvas))
        XCTAssertEqual(try liveCards(h)[1].back.kind, .ink)
        XCTAssertEqual(model.mode(id, .back), .ink)
    }

    func testRemovingAPictureKeepsTheSideInImageModeAndReadOnlyBlocksEdits() async throws {
        let h = harness()
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        await model.removePicture(card: Fixtures.card2, side: .back)
        XCTAssertEqual(try liveCards(h)[1].back.kind, .text)
        XCTAssertNil(try liveCards(h)[1].back.asset)
        XCTAssertEqual(model.mode(Fixtures.card2, .back), .image, "the empty side waits for the next picture")
        h.app.bus.undo(Fixtures.studySetID)
        XCTAssertEqual(try liveCards(h)[1].back.asset, Fixtures.pngAsset)
        XCTAssertEqual(model.mode(Fixtures.card2, .back), .image)

        h.session.readOnly = true
        XCTAssertTrue(model.readOnly)
        let added = await model.addCard(after: nil)
        XCTAssertNil(added)
        model.moveFocus(forward: true)
        XCTAssertNil(model.focus)
        XCTAssertEqual(try liveCards(h).count, 2)
    }

    func testEditingTextKeepsItsStyling() async throws {
        let bold = TextAttributes(bold: true)
        let link = TextAttributes(link: TextLink(url: "https://example.com"))
        var text = RichText(paragraphs: [Paragraph(runs: [TextRun("Force", bold), TextRun(" = ma")], align: .center),
                                         Paragraph(runs: [TextRun("see", link)], list: .bullet)])
        text = CardText.edited(text, to: "Force = m·a\nsee")
        XCTAssertEqual(text.paragraphs[0].runs, [TextRun("Force", bold), TextRun(" = m·a")])
        XCTAssertEqual(text.paragraphs[0].align, .center)
        XCTAssertEqual(text.paragraphs[1], Paragraph(runs: [TextRun("see", link)], list: .bullet))
        text = CardText.edited(text, to: "Force = m·a\nsee more")
        XCTAssertEqual(text.paragraphs[1].runs, [TextRun("see", link), TextRun(" more")], "typing after a link does not extend it")
        text = CardText.edited(text, to: "Forces = m·a\nsee more")
        XCTAssertEqual(text.paragraphs[0].runs[0], TextRun("Forces", bold), "typing inside bold text is bold")
        text = CardText.edited(text, to: "Forces\n = m·a\nsee more")
        XCTAssertEqual(text.paragraphs.map { $0.align }, [.center, .center, .natural], "a split paragraph keeps its style")
        XCTAssertEqual(text.paragraphs.map { $0.list }, [.plain, .plain, .bullet])
        XCTAssertEqual(text.plainText, "Forces\n = m·a\nsee more")
        XCTAssertEqual(CardText.edited(RichText(plain: "a"), to: "ab"), RichText(plain: "ab"))
        XCTAssertEqual(CardText.edited(nil, to: "x\ny"), RichText(plain: "x\ny"))

        // Through the editor: a styled side keeps its bold after a typing pause.
        let h = harness()
        try await h.run("card.update", try JSONValue.parse(
            #"{"ref": "card:FIXTUREDOC03/FIXTURECRD01", "front": {"text": {"paragraphs": [{"runs": [{"text": "Force", "attrs": {"bold": true}}, {"text": " = ma"}]}]}}}"#))
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        let field = CardField(card: Fixtures.card1, side: .front)
        model.focus = field
        model.setText("Force = m a", for: field)
        await model.flush()
        let front = try XCTUnwrap(try liveCards(h).first?.front.text)
        XCTAssertEqual(front.plainText, "Force = m a")
        XCTAssertEqual(front.paragraphs[0].runs.first, TextRun("Force", bold))
    }

    func testReadOnlyMenusKeepWhatChangesNothingAndStudyPanelsResolveByID() {
        let h = harness()
        h.app.commands.register(CommandDescriptor(id: "test.speakCard", title: "Speak Card", summary: "Read a card aloud.",
                                                  effect: .read, owner: "test")) { _, _ in [:] }
        h.app.ui.menus.register(MenuItemDescriptor(id: "test.card.speak", title: "Speak", location: .card, order: 50,
                                                   owner: "test", command: "test.speakCard"))
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        let editable = model.menuItems(Fixtures.card1).map { $0.id }
        XCTAssertTrue(editable.contains("test.card.speak"))
        XCTAssertTrue(editable.contains("studyeditor.card.delete"))
        h.session.readOnly = true
        XCTAssertEqual(model.menuItems(Fixtures.card1).map { $0.id }, ["test.card.speak"])

        // Practice and Smart Learn appear once the study sessions feature registers exactly these panel ids.
        XCTAssertNil(model.practicePanel)
        XCTAssertNil(model.smartLearnPanel)
        for id in [StudySetModel.practicePanelID, StudySetModel.smartLearnPanelID] {
            h.app.ui.panels.register(PanelDescriptor(id: id, title: id, icon: "rectangle.on.rectangle", placement: .sheet,
                                                     order: 0, owner: "studysession", docKinds: [.studySet]) { _ in
                AnyView(EmptyView())
            })
        }
        XCTAssertEqual(model.practicePanel?.id, "studysession.practice")
        XCTAssertEqual(model.smartLearnPanel?.id, "studysession.smartLearn")
    }

    // MARK: Paste

    func testPasteFollowsTheSideModeWhenTheContentAllows() {
        let all: Set<CardFaceKind> = [.text, .image, .ink]
        XCTAssertEqual(CardPaste.choose(for: .text, available: all), .text)
        XCTAssertEqual(CardPaste.choose(for: .ink, available: all), .ink)
        XCTAssertEqual(CardPaste.choose(for: .image, available: [.text]), .text)
        XCTAssertEqual(CardPaste.choose(for: .ink, available: [.image, .text]), .image)
        XCTAssertNil(CardPaste.choose(for: .text, available: []))
    }

    func testLassoFragmentBecomesFittedInkTextAndPictures() throws {
        let big = Stroke(style: InkStyle(), points: [StrokePoint(x: 100, y: 500, width: 2, height: 2),
                                                     StrokePoint(x: 1500, y: 900, width: 2, height: 2)])
        let note = Item.makeText(TextBoxItem(frame: Frame(x: 100, y: 400, w: 200, h: 40), text: RichText(plain: "Momentum")))
        let items = try JSONValue.from([Item.makeStroke(big), note])
        let json: JSONValue = ["format": "nib-fragment/1", "items": items, "assets": [:], "bounds": [100, 400, 1400, 500]]
        let fragment = try XCTUnwrap(CardPaste.fragment(from: try JSONEncoder().encode(json)))
        XCTAssertEqual(fragment.items.count, 2)

        let content = PastedContent(fragment: fragment)
        XCTAssertEqual(content.available, [.text, .image, .ink])
        XCTAssertEqual(CardPaste.typedText(fragment.items), ["Momentum"])

        let face = try XCTUnwrap(CardPaste.inkFace(from: fragment.items))
        XCTAssertEqual(face.kind, .ink)
        XCTAssertEqual(face.size, CardFaces.canvas)
        let bounds = try XCTUnwrap(face.ink?.first?.bounds)
        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
        XCTAssertLessThanOrEqual(bounds.maxX, CardFaces.canvas.width)
        XCTAssertLessThanOrEqual(bounds.maxY, CardFaces.canvas.height)
        XCTAssertNotNil(CardPaste.imageData(from: fragment))
        XCTAssertNil(CardPaste.fragment(from: Data("{}".utf8)))
    }

    func testLassoedInkRendersAsABoundedPicture() throws {
        let wide = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0, width: 2, height: 2),
                                                      StrokePoint(x: 50_000, y: 800, width: 2, height: 2)])
        let png = try XCTUnwrap(CardPaste.imageData(from: CardFragment(items: [Item.makeStroke(wide)], assets: [:])))
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), CardImages.maxPixels + 1)
    }

    // MARK: Pictures

    /// A picture `width` × `height` px: grey and opaque, or RGBA with alpha.
    private func picture(width: Int, height: Int, alpha: Bool, type: UTType) throws -> Data {
        let context = try XCTUnwrap(alpha
            ? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            : CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return (width, height)
    }

    func testPicturesAreBoundedAndReencodedByTransparency() throws {
        // Small PNG and JPEG files are kept byte for byte.
        let png = try XCTUnwrap(CardImages.normalized(Fixtures.pngData))
        XCTAssertEqual(png.ext, "png")
        XCTAssertEqual(png.data, Fixtures.pngData)
        let smallJPEG = try picture(width: 64, height: 48, alpha: false, type: .jpeg)
        XCTAssertEqual(CardImages.normalized(smallJPEG)?.ext, "jpg")
        XCTAssertEqual(CardImages.normalized(smallJPEG)?.data, smallJPEG)
        XCTAssertNil(CardImages.normalized(Data("not a picture".utf8)))
        XCTAssertNil(CardImages.normalized(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])), "a JPEG header alone is not a picture")

        // A large opaque picture in another format (a camera photo) becomes a JPEG at most maxPixels wide.
        let tiff = try picture(width: 3000, height: 2000, alpha: false, type: .tiff)
        let photo = try XCTUnwrap(CardImages.normalized(tiff))
        XCTAssertEqual(photo.ext, "jpg")
        XCTAssertEqual([UInt8](photo.data.prefix(3)), [0xFF, 0xD8, 0xFF])
        let size = try pixelSize(photo.data)
        XCTAssertEqual(max(size.width, size.height), CardImages.maxPixels)
        XCTAssertEqual(Double(size.width) / Double(size.height), 1.5, accuracy: 0.01, "the aspect ratio is kept")
        XCTAssertLessThan(photo.data.count, tiff.count)

        // With alpha it stays lossless; a large JPEG shrinks too.
        let clear = try XCTUnwrap(CardImages.normalized(try picture(width: 2500, height: 400, alpha: true, type: .tiff)))
        XCTAssertEqual(clear.ext, "png")
        XCTAssertEqual(try pixelSize(clear.data).width, CardImages.maxPixels)
        let bigJPEG = try XCTUnwrap(CardImages.normalized(try picture(width: 4096, height: 1024, alpha: false, type: .jpeg)))
        XCTAssertEqual(bigJPEG.ext, "jpg")
        XCTAssertEqual(try pixelSize(bigJPEG.data).width, CardImages.maxPixels)
    }

    func testListSlotsDecodeThumbnailsAndSetImageStoresABoundedPhoto() async throws {
        let h = harness()
        let model = StudySetModel(app: h.app, doc: Fixtures.studySetID, session: h.session)
        await model.setImage(try picture(width: 3000, height: 2000, alpha: false, type: .tiff), card: Fixtures.card1, side: .back)
        let back = try XCTUnwrap(try liveCards(h).first?.back)
        XCTAssertEqual(back.kind, .image)
        let asset = try XCTUnwrap(back.asset)
        XCTAssertEqual(asset.ext, "jpg")
        let stored = try pixelSize(try h.assets.data(asset, doc: Fixtures.studySetID))
        XCTAssertEqual(max(stored.width, stored.height), CardImages.maxPixels)

        let small = await model.picture(asset, maxPixels: 300)
        let thumbnail = try XCTUnwrap(small)
        XCTAssertLessThanOrEqual(max(thumbnail.size.width * thumbnail.scale, thumbnail.size.height * thumbnail.scale), 300)
        let large = await model.picture(asset, maxPixels: 1680)
        let full = try XCTUnwrap(large)
        XCTAssertEqual(full.size.width * full.scale, 1680, accuracy: 1)
    }

    // MARK: Menus

    func testCardMenuRunsCommandsBuiltFromTheCard() async throws {
        let h = harness()
        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.studySetID, ref: "card:FIXTUREDOC03/FIXTURECRD01")
        let items = h.app.ui.menuItems(.card, context)
        XCTAssertEqual(Set(items.map { $0.id }), ["studyeditor.card.duplicate", "studyeditor.card.moveDown", "studyeditor.card.delete"])
        let duplicate = try XCTUnwrap(items.first(where: { $0.id == "studyeditor.card.duplicate" }))
        try await h.run(duplicate.command, duplicate.params(context))
        let cards = try liveCards(h)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[1].front, cards[0].front)
        XCTAssertEqual(cards[1].back, cards[0].back)

        let moveDown = try XCTUnwrap(items.first(where: { $0.id == "studyeditor.card.moveDown" }))
        try await h.run(moveDown.command, moveDown.params(context))
        XCTAssertEqual(try liveCards(h).map { $0.id }.last, Fixtures.card2)
        XCTAssertEqual(try liveCards(h)[1].id, Fixtures.card1)

        let newSet = try XCTUnwrap(h.app.ui.menuItems(.libraryNew, MenuContext(app: h.app)).first(where: { $0.id == "studyeditor.new" }))
        let calls = newSet.params(MenuContext(app: h.app, ref: "folder:FIXTUREFLD01"))["calls"]
        XCTAssertEqual(calls?[0]?["command"]?.stringValue, "doc.create")
        XCTAssertEqual(calls?[0]?["params"]?["kind"]?.stringValue, "studySet")
        XCTAssertEqual(calls?[0]?["params"]?["folder"]?.stringValue, "folder:FIXTUREFLD01")
        XCTAssertEqual(calls?[1]?["command"]?.stringValue, "doc.open")
    }
}
