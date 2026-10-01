import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatMath

@MainActor
final class FeatMathTests: XCTestCase {
    private let ink = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"
    private let math = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01"

    func testExplicitConversionPreservesSourceAndUndoRedo() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let before = try h.snapshot()
        let original = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        let result = try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "latex": ["\\frac{a}{b}"], "id": "MYMATH001"])
        XCTAssertEqual(result["ref"]?.stringValue, "item:FIXTUREDOC01/FIXTUREPG001/MYMATH001")
        let item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: NibID("MYMATH001"))
        XCTAssertEqual(item.math?.sourceInk, [try XCTUnwrap(original.stroke)])
        XCTAssertEqual(item.math?.latex, ["\\frac{a}{b}"])
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID))
        let after = try h.snapshot()
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), before)
        h.app.bus.redo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), after)
        let copy = try await h.run(CommandIDs.mathCopy, ["ref": result["ref"] ?? .null, "as": "handwriting"])
        let fragment = try XCTUnwrap(copy["fragment"]).decode(NibFragment.self)
        XCTAssertEqual(try JSONValue.from(fragment.items.first?.stroke), try JSONValue.from(original.stroke))
        XCTAssertEqual(fragment.items.count, 1)
    }

    func testLatexEditUndoAndReadCopyDoesNotMutate() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let before = try h.snapshot()
        try await h.run(CommandIDs.mathSetLatex, ["ref": .string(math), "lines": ["x^{2}", "\\frac{1}{2}"]])
        let depth = h.undoDepth(Fixtures.docID)
        let copy = try await h.run(CommandIDs.mathCopy, ["ref": .string(math), "as": "latex"])
        XCTAssertEqual(copy["latex"]?.stringValue, "x^{2}\n\\frac{1}{2}")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testVisionProviderGetsSelectionImageAndNoTools() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let ai = FakeAIService(responses: [.init(text: #"{"lines":["\\frac{a}{b}","x^{2}"]}"#)])
        let renderer = FakeRenderer()
        h.app.services.ai = ai; h.app.services.renderer = renderer
        let before = try h.snapshot()
        let result = try await h.run(CommandIDs.mathRecognize, ["refs": [.string(ink)]])
        XCTAssertEqual(result["source"]?.stringValue, "ai")
        XCTAssertEqual(result["lines"]?.arrayValue?.count, 2)
        XCTAssertEqual(ai.requests.count, 1)
        XCTAssertEqual(ai.requests.first?.tools, [])
        XCTAssertEqual(ai.requests.first?.mode, .ask)
        XCTAssertEqual(ai.requests.first?.scope?.refs, [ink])
        XCTAssertEqual(ai.requests.first?.messages.first?.images?.count, 1)
        XCTAssertTrue(ai.requests.first?.jsonOutput == true)
        XCTAssertEqual(renderer.requests.count, 1)
        let bounds = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID).bounds
        XCTAssertEqual(renderer.requests.first?.region, bounds)
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testMalformedProviderAnswerFallsBackToTextRecognition() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let ai = FakeAIService(responses: [.init(text: "not JSON")])
        let recognizer = FakeRecognizer([TextRecognition(text: "x² + 1/2", bbox: .zero, source: "ink")])
        h.app.services.ai = ai; h.app.services.renderer = FakeRenderer(); h.app.services.recognizer = recognizer
        let result = try await h.run(CommandIDs.mathRecognize, ["refs": [.string(ink)]])
        XCTAssertEqual(result["source"]?.stringValue, "offline")
        XCTAssertEqual(result["lines"]?.arrayValue?.first?.stringValue, "x^{2} + \\frac{1}{2}")
        XCTAssertNotNil(result["warning"]?.stringValue)
        XCTAssertEqual(recognizer.imageCalls, 1)
    }

    func testConversionWithoutLatexUsesRecognizerAndIsUndoable() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        h.app.services.renderer = FakeRenderer()
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"lines":["x+1=2"]}"#)])
        let before = try h.snapshot()
        try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "id": "RECOGMATH01"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testInvalidLatexAndDuplicateIDsLeaveDocumentUntouched() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let before = try h.snapshot()
        for params: JSONValue in [
            ["refs": [.string(ink)], "latex": []],
            ["refs": [.string(ink)], "latex": ["\\notARealCommand"]],
            ["refs": [.string(ink)], "latex": ["x"], "id": "FIXTUREMTH01"],
            ["refs": [.string(ink), .string(ink)], "latex": ["x"]]
        ] {
            do { try await h.run(CommandIDs.mathConvert, params); XCTFail("Invalid conversion succeeded") }
            catch { XCTAssertTrue(error is NibError) }
            XCTAssertEqual(try h.snapshot(), before)
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        }
    }

    func testLockedStrokeAndDocumentAreProtected() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        var stroke = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        stroke.locked = true
        try await h.insert([stroke])
        let before = try h.snapshot()
        do {
            try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "latex": ["x"]])
            XCTFail("Locked stroke converted")
        } catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        XCTAssertEqual(try h.snapshot(), before)
        let lock = FakeLockService()
        lock.locked.insert(Fixtures.docID)
        h.app.services.lock = lock
        do { try await h.run(CommandIDs.mathCopy, ["ref": .string(math), "as": "latex"]); XCTFail("Locked document exported") }
        catch let error as NibError { XCTAssertEqual(error.code, .locked) }
    }

    func testTypesetterCacheColourScaleAndFractionDrawer() async throws {
        let typesetter = MathTypesetter()
        let first = try typesetter.image(lines: ["\\frac{a}{b}"], color: .black, scale: 1)
        let cached = try typesetter.image(lines: ["\\frac{a}{b}"], color: .black, scale: 1)
        XCTAssertTrue(first === cached)
        XCTAssertGreaterThan(first.size.width, 0)
        XCTAssertGreaterThan(first.size.height, 0)
        let scaled = try typesetter.image(lines: ["\\frac{a}{b}"], color: .black, scale: 2)
        XCTAssertFalse(first === scaled)
        XCTAssertGreaterThan(try XCTUnwrap(scaled.cgImage).width, try XCTUnwrap(first.cgImage).width)
        let h = Harness(features: [FeatMathFeature.self])
        let object = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { renderer in
            renderer.cgContext.translateBy(x: -object.math!.frame.x, y: -object.math!.frame.y)
            MathDrawer().draw(object, in: DrawContext(cg: renderer.cgContext, scale: 1, doc: Fixtures.docID, page: Fixtures.page1))
        }
        let cg = try XCTUnwrap(image.cgImage)
        let bytes = try XCTUnwrap(cg.dataProvider?.data) as Data
        XCTAssertTrue(bytes.contains(where: { $0 != 0 }), "Fraction drawer painted no pixels")
        let exported = try await h.run(CommandIDs.mathCopy, ["ref": .string(math), "as": "image"])
        let name = try XCTUnwrap(exported["asset"]?.stringValue)
        let url = try XCTUnwrap(h.assets.temporaryURL(AssetRef(String(name.dropFirst(4)))))
        XCTAssertNotNil(UIImage(contentsOfFile: url.path))
    }

    func testAttachmentsFollowConvertedInkAndUndoRestoresThem() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        var shape = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID)
        shape.attachedTo = Fixtures.strokeID
        var connector = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.connectorID)
        connector.connector?.from.item = Fixtures.strokeID
        try await h.insert([shape, connector])
        let before = try h.snapshot()
        try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "latex": ["x"], "id": "ATTACHMATH01"])
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.shapeID).attachedTo, NibID("ATTACHMATH01"))
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.connectorID).connector?.from.item, NibID("ATTACHMATH01"))
        XCTAssertEqual(h.session.selection.items, [NibID("ATTACHMATH01")])
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testEmptyAndUnboundedTypesettingInputsAreRejected() {
        let typesetter = MathTypesetter()
        for latex in ["{}", "\\quad", "\\color{red}{}", "\\underline{}", "\\mkern1000000mu", String(repeating: "{", count: 20) + "x" + String(repeating: "}", count: 20)] {
            XCTAssertThrowsError(try typesetter.image(lines: [latex], color: .black))
        }
    }

    func testRegistrationAndCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatMathFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatMathFeature.self])
        XCTAssertNotNil(h.app.content.drawers.get("math"))
        XCTAssertNotNil(h.app.ui.panels.get("math.editor"))
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.mathCopy)?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.mathConvert)?.owner, "math")
    }
}
