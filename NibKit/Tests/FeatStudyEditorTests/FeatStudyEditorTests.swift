import XCTest
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

    func testPicturesKeepTheirFormat() throws {
        let png = try XCTUnwrap(CardImages.normalized(Fixtures.pngData))
        XCTAssertEqual(png.ext, "png")
        XCTAssertEqual(png.data, Fixtures.pngData)
        XCTAssertEqual(CardImages.normalized(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]))?.ext, "jpg")
        XCTAssertNil(CardImages.normalized(Data("not a picture".utf8)))
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
