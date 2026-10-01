import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatMath

@MainActor
final class FeatMathTests: XCTestCase {
    private let ink = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"
    private let math = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01"

    @discardableResult
    private func registerRenderPage(_ h: Harness) throws -> MathRenderPageDouble {
        let render = MathRenderPageDouble(asset: try h.assets.putTemporary(Fixtures.pngData, ext: "png"))
        h.app.commands.register(CommandDescriptor(id: CommandIDs.renderPage, title: "Render Page", summary: "Test selection render",
            params: .obj(["page": .ref, "region": .rect, "background": .bool(), "layers": .arr(.int(min: 0, max: 4))], required: ["page"]),
            effect: .read)) { params, _ in
            render.requests.append(params)
            return ["asset": .string("tmp:" + render.asset.name), "pxPerPt": 1, "region": params["region"] ?? .null]
        }
        return render
    }

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
        let render = try registerRenderPage(h)
        h.app.services.ai = ai
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
        XCTAssertEqual(ai.requests.first?.messages.first?.images?.first, render.asset)
        XCTAssertEqual(render.requests.count, 1)
        let bounds = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID).bounds
        XCTAssertEqual(render.requests.first?["page"], .string(NodeRef.page(Fixtures.docID, Fixtures.page1).description))
        XCTAssertEqual(render.requests.first?["region"], try JSONValue.from([bounds.x, bounds.y, bounds.width, bounds.height]))
        XCTAssertEqual(render.requests.first?["background"], true)
        XCTAssertEqual(render.requests.first?["layers"], [0])
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testMalformedProviderAnswerFallsBackToTextRecognition() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let ai = FakeAIService(responses: [.init(text: "not JSON")])
        let recognizer = FakeRecognizer([TextRecognition(text: "x² + 1/2", bbox: .zero, source: "ink")])
        try registerRenderPage(h)
        h.app.services.ai = ai; h.app.services.recognizer = recognizer
        let result = try await h.run(CommandIDs.mathRecognize, ["refs": [.string(ink)]])
        XCTAssertEqual(result["source"]?.stringValue, "offline")
        XCTAssertEqual(result["lines"]?.arrayValue?.first?.stringValue, "x^{2} + \\frac{1}{2}")
        XCTAssertNotNil(result["warning"]?.stringValue)
        XCTAssertEqual(recognizer.imageCalls, 1)
    }

    func testConversionWithoutLatexUsesRecognizerAndIsUndoable() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        try registerRenderPage(h)
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"lines":["x+1=2"]}"#)])
        let before = try h.snapshot()
        try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "id": "RECOGMATH01"])
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testMissingRenderCommandIsUnavailableEvenWithRendererService() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let renderer = FakeRenderer()
        let ai = FakeAIService(responses: [.init(text: #"{"lines":["x"]}"#)])
        let recognizer = FakeRecognizer([TextRecognition(text: "x", bbox: .zero, source: "ink")])
        h.app.services.renderer = renderer
        h.app.services.ai = ai
        h.app.services.recognizer = recognizer
        let before = try h.snapshot()
        for command in [CommandIDs.mathRecognize, CommandIDs.mathConvert] {
            do {
                try await h.run(command, ["refs": [.string(ink)]])
                XCTFail("Recognition succeeded without render.page")
            } catch let error as NibError {
                XCTAssertEqual(error.code, .unavailable)
                XCTAssertTrue(error.message.contains(CommandIDs.renderPage))
            }
            XCTAssertEqual(try h.snapshot(), before)
            XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        }
        XCTAssertTrue(renderer.requests.isEmpty)
        XCTAssertTrue(ai.requests.isEmpty)
        XCTAssertEqual(recognizer.imageCalls, 0)
    }

    func testRenderCommandErrorsPropagateWithoutRecognitionOrMutation() async throws {
        for code: NibError.Code in [.permissionDenied, .locked] {
            let h = Harness(features: [FeatMathFeature.self])
            let renderer = FakeRenderer()
            let ai = FakeAIService(responses: [.init(text: #"{"lines":["x"]}"#)])
            let recognizer = FakeRecognizer([TextRecognition(text: "x", bbox: .zero, source: "ink")])
            h.app.services.renderer = renderer
            h.app.services.ai = ai
            h.app.services.recognizer = recognizer
            let expected = NibError(code, "Selection rendering denied")
            var renderCalls = 0
            h.app.commands.register(CommandDescriptor(id: CommandIDs.renderPage, title: "Render Page", summary: "Reject the test render", effect: .read)) { _, _ in
                renderCalls += 1
                throw expected
            }
            let before = try h.snapshot()
            for command in [CommandIDs.mathRecognize, CommandIDs.mathConvert] {
                do {
                    try await h.run(command, ["refs": [.string(ink)]])
                    XCTFail("Recognition ignored a render.page error")
                } catch let error as NibError { XCTAssertEqual(error, expected) }
                XCTAssertEqual(try h.snapshot(), before)
                XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
            }
            XCTAssertEqual(renderCalls, 2)
            XCTAssertTrue(renderer.requests.isEmpty)
            XCTAssertTrue(ai.requests.isEmpty)
            XCTAssertEqual(recognizer.imageCalls, 0)
        }
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

    func testDangerousNestingAndUndrawableLinesNeverMutateOrDraw() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        let before = try h.snapshot()
        let bad = [String(repeating: "\\sqrt ", count: 1300), String(repeating: "\\frac1", count: 300),
                   String(repeating: "x", count: 600),
                   String(repeating: "\\sqrt ", count: NibLimits.maxNesting + 1) + "x",
                   String(repeating: "\\frac1", count: NibLimits.maxNesting + 1) + "x"]
        for latex in bad {
            let attempts: [(String, JSONValue)] = [
                (CommandIDs.mathSetLatex, ["ref": .string(math), "lines": [.string(latex)]]),
                (CommandIDs.mathConvert, ["refs": [.string(ink)], "latex": [.string(latex)]])
            ]
            for (command, params) in attempts {
                do { try await h.run(command, params); XCTFail("Unsafe formula was accepted") }
                catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
                XCTAssertEqual(try h.snapshot(), before)
                XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
            }
            var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID)
            item.math?.latex = [latex]
            XCTAssertNil(MathDrawer().image(try XCTUnwrap(item.math), scale: 16))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { renderer in
                MathDrawer().draw(item, in: DrawContext(cg: renderer.cgContext, scale: 16, doc: Fixtures.docID, page: Fixtures.page1))
            }
            let bytes = try XCTUnwrap(rendered.cgImage?.dataProvider?.data) as Data
            XCTAssertFalse(bytes.contains { $0 != 0 }, "An unsafe stored formula drew pixels")
        }
    }

    func testSetLatexFitsHeightAndUndoRestoresEntireFrame() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        try await h.run(CommandIDs.mathSetLatex, ["ref": .string(math), "lines": ["x"]])
        let before = try h.snapshot()
        let old = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).math).frame
        try await h.run(CommandIDs.mathSetLatex, ["ref": .string(math), "lines": ["\\frac{a+b}{c}"]])
        let frame = try XCTUnwrap(h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.mathID).math).frame
        XCTAssertNotEqual(frame.h, old.h)
        XCTAssertEqual(frame.x, old.x); XCTAssertEqual(frame.y, old.y)
        XCTAssertEqual(frame.w, old.w); XCTAssertEqual(frame.rotation, old.rotation)
        let natural = try MathTypesetter.shared.image(lines: ["\\frac{a+b}{c}"], color: .black, scale: 1).size
        XCTAssertEqual(frame.h / frame.w, natural.height / natural.width, accuracy: 0.0001)
        h.app.bus.undo(Fixtures.docID)
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testDrawerBucketsZoomAndBoundsRasterCost() throws {
        let formula = MathItem(frame: Frame(x: 0, y: 0, w: 20, h: 100), latex: ["x"], color: .black)
        let natural = try MathTypesetter.shared.image(lines: formula.latex, color: formula.color, scale: 1)
        let fit = min(formula.frame.w / natural.size.width, formula.frame.h / natural.size.height)
        let drawer = MathDrawer()
        let first = try XCTUnwrap(drawer.image(formula, scale: 1 / fit))
        let second = try XCTUnwrap(drawer.image(formula, scale: 1.1 / fit))
        XCTAssertTrue(first === second)
        let typesetter = MathTypesetter()
        let lines = Array(repeating: String(repeating: "x", count: 100), count: 10)
        let large = try typesetter.image(lines: lines, color: .black, scale: 16)
        let pixels = try XCTUnwrap(large.cgImage)
        XCTAssertLessThanOrEqual(pixels.width * pixels.height, 4_194_304)
        XCTAssertLessThan(pixels.bytesPerRow * pixels.height, 24 * 1_024 * 1_024)
        XCTAssertTrue(large === (try typesetter.image(lines: lines, color: .black, scale: 16)))
    }

    func testDrawerFitsAtTopLeadingWithoutStretching() throws {
        let natural = try MathTypesetter.shared.image(lines: ["\\frac{a}{b}"], color: .black, scale: 1)
        let formula = MathItem(frame: Frame(x: 0, y: 0, w: 120, h: 40), latex: ["\\frac{a}{b}"], color: .black)
        let item = Item(kind: .math, math: formula)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 40), format: format).image { renderer in
            MathDrawer().draw(item, in: DrawContext(cg: renderer.cgContext, scale: 1, doc: Fixtures.docID, page: Fixtures.page1))
        }
        let cg = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cg.dataProvider?.data) as Data
        let expectedWidth = Int(ceil(min(120 / natural.size.width, 40 / natural.size.height) * natural.size.width))
        XCTAssertLessThan(expectedWidth, 120)
        for y in 0..<cg.height {
            let tail = (y * cg.bytesPerRow + (expectedWidth + 1) * 4)..<(y * cg.bytesPerRow + cg.width * 4)
            XCTAssertFalse(data[tail].contains { $0 != 0 }, "Drawer stretched ink outside its natural aspect ratio")
        }
    }

    func testSelectionLayersCrossPageAndReadOnlyBoundaries() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        var second = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        second.id = NibID("SECONDINK01"); second.layer = 1
        try await h.insert([second])
        let secondRef = NodeRef.item(Fixtures.docID, Fixtures.page1, second.id).description
        let render = try registerRenderPage(h)
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"lines":["x"]}"#)])
        let before = try h.snapshot()
        _ = try await h.run(CommandIDs.mathRecognize, ["refs": [.string(ink), .string(secondRef)]])
        XCTAssertEqual(render.requests.count, 1)
        XCTAssertEqual(render.requests.first?["layers"], [0, 1])
        for refs: [String] in [[ink, secondRef], [ink, "item:FIXTUREDOC01/OTHERPAGE001/SECONDINK01"]] {
            do { try await h.run(CommandIDs.mathConvert, ["refs": .array(refs.map(JSONValue.string)), "latex": ["x"]]); XCTFail("Invalid selection converted") }
            catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
            XCTAssertEqual(try h.snapshot(), before)
        }
        h.app.services.set(NSSet(array: [Fixtures.docID.raw]), for: ServiceKeys.storeReadOnly)
        do { try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "latex": ["x"]]); XCTFail("Read-only document changed") }
        catch let error as NibError { XCTAssertEqual(error.code, .permissionDenied) }
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testRecognisedRevisionsProtectSheetConversion() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        try registerRenderPage(h)
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"lines":["x"]}"#)])
        let recognition = try await h.run(CommandIDs.mathRecognize, ["refs": [.string(ink)]])
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        item.stroke?.points[0].x += 1
        try await h.insert([item])
        let before = try h.snapshot()
        do {
            try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)], "latex": ["x"], "revs": try XCTUnwrap(recognition["revs"])])
            XCTFail("Stale recognised ink converted")
        } catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testInkChangedDuringDelayedRecognitionConflicts() async throws {
        let h = Harness(features: [FeatMathFeature.self])
        try registerRenderPage(h)
        let started = expectation(description: "Provider suspended")
        let ai = DelayedMathAI(fake: FakeAIService(responses: [.init(text: #"{"lines":["x"]}"#)])) { started.fulfill() }
        h.app.services.ai = ai
        let conversion = Task { try await h.run(CommandIDs.mathConvert, ["refs": [.string(ink)]]) }
        await fulfillment(of: [started], timeout: 5)
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.strokeID)
        item.stroke?.points[0].x += 1
        try await h.insert([item])
        let before = try h.snapshot()
        let depth = h.undoDepth(Fixtures.docID)
        ai.resume()
        do { _ = try await conversion.value; XCTFail("Changed handwriting converted") }
        catch let error as NibError { XCTAssertEqual(error.code, .conflict) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), depth)
    }

    func testDocumentTypographyIgnoresDynamicType() throws {
        let normal = try MathTypesetter().image(lines: ["x+1"], color: .black, scale: 1)
        var enlarged: UIImage?
        var failure: Error?
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge).performAsCurrent {
            do { enlarged = try MathTypesetter().image(lines: ["x+1"], color: .black, scale: 1) }
            catch { failure = error }
        }
        XCTAssertNil(failure)
        XCTAssertEqual(normal.size, try XCTUnwrap(enlarged).size)
    }

    func testSmallStackCallerCanDrawAndRejectDangerousStoredFormula() async throws {
        let result: Bool = await withCheckedContinuation { continuation in
            let thread = Thread {
                let formula = MathItem(frame: Frame(x: 0, y: 0, w: 120, h: 40), latex: ["\\frac{a}{b}"], color: .black)
                let safe = MathDrawer().image(formula, scale: 1) != nil
                var dangerous = formula
                dangerous.latex = [String(repeating: "\\sqrt ", count: 1300)]
                let rejected = MathDrawer().image(dangerous, scale: 16) == nil
                continuation.resume(returning: safe && rejected)
            }
            thread.stackSize = 512 * 1_024
            thread.start()
        }
        XCTAssertTrue(result)
    }

    func testRegistrationAndCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatMathFeature.self])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [FeatMathFeature.self])
        XCTAssertNotNil(h.app.content.drawers.get("math"))
        XCTAssertEqual(h.app.ui.panels.get("math.editor")?.providesHeader, true)
        XCTAssertNil(h.app.commands.descriptor("math.transfer"))
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.mathCopy)?.effect, .read)
        XCTAssertEqual(h.app.commands.descriptor(CommandIDs.mathConvert)?.owner, "math")
    }
}

@MainActor
private final class MathRenderPageDouble {
    let asset: AssetRef
    var requests: [JSONValue] = []
    init(asset: AssetRef) { self.asset = asset }
}

/// A deterministic suspension around the shared FakeAIService, so the test can edit ink mid-request.
@MainActor
private final class DelayedMathAI: AIService {
    let fake: FakeAIService
    let started: () -> Void
    var continuation: CheckedContinuation<Void, Never>?
    var isConfigured: Bool { fake.isConfigured }
    var supportsVision: Bool { fake.supportsVision }
    init(fake: FakeAIService, started: @escaping () -> Void) { self.fake = fake; self.started = started }
    func complete(_ request: AIRequest) async throws -> AIResponse {
        await withCheckedContinuation { continuation = $0; started() }
        return try await fake.complete(request)
    }
    func resume() { continuation?.resume(); continuation = nil }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> { fake.stream(request) }
    func cancel(chatID: String) { fake.cancel(chatID: chatID) }
    func chats(doc: DocumentID?) -> [AIChatSummary] { fake.chats(doc: doc) }
    func messages(chatID: String) -> [AIMessage] { fake.messages(chatID: chatID) }
    func deleteChat(_ chatID: String) { fake.deleteChat(chatID) }
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { try await fake.transcribe(audio: audio, language: language) }
    func generateImage(prompt: String) async throws -> Data { try await fake.generateImage(prompt: prompt) }
}
