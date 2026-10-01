import XCTest
import NibContracts
import NibTesting
import SwiftUI
import UIKit
import NibDesign
@testable import FeatAIMath

@MainActor
final class FeatAIMathTests: XCTestCase {
    func testPanelSnapshotsAtBothWidthsAndLargeText() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        var states = [MathSession(equations: ["2+2"]),
                      MathSession(equations: ["2+2"], plan: MathPlan(steps: [.init(title: "Add the values", detail: "Two pairs make four.")], answer: "4"), revealed: true, expanded: [0], verification: .verified),
                      MathSession(equations: ["2+2"], mode: .teach, plan: MathPlan(hints: ["Start with two, then count two more."], answer: "4"), hintCount: 1)]
        states += [MathSession(equations: ["2+2"], mode: .teach, teacherRef: "item:FIXTUREDOC01/FIXTUREPG001/ZONE01",
                               teacherHints: ["Count the pairs.", "Add the totals."], teacherHintCount: 1),
                   MathSession(equations: ["2+2"], mode: .teach, plan: MathPlan(hints: ["Start with two."], answer: "4"),
                               hintCount: 1, teacherRef: "item:FIXTUREDOC01/FIXTUREPG001/ZONE01",
                               teacherHints: ["Count the pairs.", "Add the totals."], teacherHintCount: 1),
                   MathSession(equations: ["Invalid input"], recognitionWarning: "Double-check on-device recognition.")]
        var captures: [String: [Data]] = [:]
        for state in states {
            for variant in NibSnapshot.Variant.allCases {
                for width in [CGFloat(344), CGFloat(390)] {
                    let view = SolvePanel(context: context, initialState: state, initialError: state.equations == ["Invalid input"] ? "No readable equations were detected." : nil)
                        .environment(\.horizontalSizeClass, width == 344 ? .regular : .compact)
                        .environment(\.colorScheme, variant.colorScheme)
                        .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
                        .background(NibColor.chromeOpaque)
                    // ImageRenderer omits the platform scroll view. A real hosting view captures the lesson too.
                    let host = UIHostingController(rootView: view)
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 780))
                    window.rootViewController = host
                    window.isHidden = false
                    host.view.frame = window.bounds
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 20_000_000)
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { renderer in
                        host.view.layer.render(in: renderer.cgContext)
                    }
                    window.isHidden = true
                    XCTAssertEqual(image.size.width, width)
                    XCTAssertEqual(image.size.height, 780)
                    let pixels = try XCTUnwrap(image.pngData())
                    XCTAssertGreaterThan(pixels.count, 5_000, "The panel must render content, not an empty surface")
                    let key = "\(variant.rawValue)-\(width)"
                    XCTAssertFalse(captures[key, default: []].contains(pixels), "Review, lesson, teacher and error states must render differently")
                    captures[key, default: []].append(pixels)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Maths-\(state.teacherRef == nil ? "ai" : "teacher")-\(state.recognitionWarning == nil ? "normal" : "error")-\(state.mode.rawValue)-\(variant.rawValue)-\(width)-\(state.plan == nil ? "review" : "lesson")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testRegistrationAndConformance() async {
        let h = Harness(features: [FeatAIMathFeature.self])
        let command = h.app.commands.descriptor(CommandIDs.mathSolve)
        XCTAssertEqual(command?.owner, "aimath")
        XCTAssertEqual(command?.effect, .read)
        XCTAssertEqual(command?.exposure, .all)
        XCTAssertTrue(command?.sensitive == true)
        XCTAssertTrue(command?.scopes.contains(.ai) == true)
        XCTAssertEqual(h.app.ui.panels.get(FeatAIMathFeature.panelID)?.providesHeader, true)
        XCTAssertEqual(h.app.content.aiActions.all.count, 2)
        XCTAssertEqual(h.app.content.keyCommands.all.count, 2)
        let errors = await CommandConformance.check(features: [FeatAIMathFeature.self])
        XCTAssertEqual(errors, [])
    }

    func testSolveUsesJSONReadOnlyAIAndVerifiesOriginalProblem() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService(responses: [.init(text: #"{"steps":[{"title":"Add","detail":"Add two and two."}],"answer":"4"}"#)])
        h.app.services.ai = ai
        var expressions: [String] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { p, _ in
            expressions.append(p["expression"]?.stringValue ?? "")
            return mathValue(4)
        }
        let before = h.undoDepths()
        let result = try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "solve"])
        let state = try result.decode(MathSession.self)
        XCTAssertEqual(state.plan?.answer, "4")
        XCTAssertEqual(state.verification, .verified)
        XCTAssertFalse(state.revealed)
        XCTAssertEqual(expressions, ["2+2"])
        XCTAssertEqual(h.undoDepths(), before)
        let request = try XCTUnwrap(ai.requests.first)
        XCTAssertEqual(request.mode, .ask)
        XCTAssertEqual(request.tools, [])
        XCTAssertTrue(request.jsonOutput)
        XCTAssertEqual(request.principal, .user)
    }

    func testIncorrectNumericAnswerIsFlagged() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"steps":[{"title":"Add","detail":"Add the terms."}],"answer":"5"}"#)])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { _, _ in mathValue(4) }
        let result = try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "solve"])
        XCTAssertEqual(try result.decode(MathSession.self).verification, .mismatch)
    }

    func testRecognitionReviewsWithoutCallingAIAndAcceptsEditedLatex() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService(responses: [.init(text: #"{"steps":[{"title":"Add","detail":"Add the terms."}],"answer":"6"}"#)])
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathRecognize, title: "Recognise", summary: "Test recognition.", effect: .read)) { p, _ in
            XCTAssertEqual(p["refs"]?.arrayValue?.count, 1)
            return ["lines": ["2+2", "x=3"], "source": "vision", "warning": "Double-check on-device recognition."]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Stroke fixture.", effect: .read)) { _, _ in ["kind": "stroke"] }
        let reviewed = try await h.run(CommandIDs.mathSolve, ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTR01"], "mode": "solve", "action": "recognize"])
        XCTAssertEqual(try reviewed.decode(MathSession.self).equations, ["2+2", "x=3"])
        XCTAssertTrue(ai.requests.isEmpty)
        XCTAssertEqual(try reviewed.decode(MathSession.self).recognitionWarning, "Double-check on-device recognition.")
        let solved = try await h.run(CommandIDs.mathSolve, ["latex": "3+3", "mode": "solve", "state": reviewed])
        XCTAssertEqual(try solved.decode(MathSession.self).equations, ["3+3"])
        XCTAssertTrue(ai.requests[0].messages[0].text.contains("3+3"))
        XCTAssertEqual(try solved.decode(MathSession.self).verification, .unverified)
    }

    func testAssignmentVerificationEvaluatesEquation() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"hints":["Divide both sides by two."],"answer":"x=3"}"#)])
        var seen: [String] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { p, _ in
            seen.append(p["expression"]?.stringValue ?? "")
            return mathSolutions([("x", 3)])
        }
        let result = try await h.run(CommandIDs.mathSolve, ["latex": "2*x=6", "mode": "teach"])
        XCTAssertEqual(try result.decode(MathSession.self).verification, .verified)
        XCTAssertEqual(seen, ["2*x=6"])
    }

    func testMissingProviderAndMalformedJSONAreRecoverable() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        do {
            try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "solve"])
            XCTFail("Expected a configuration error")
        } catch let error as NibError { XCTAssertEqual(error.code, .unavailable) }
        h.app.services.ai = FakeAIService(responses: [.init(text: "The answer is four.")])
        do {
            try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "solve"])
            XCTFail("Expected protocol rejection")
        } catch let error as NibError {
            XCTAssertEqual(error.code, .invalidParams)
            XCTAssertEqual(error.path, "$.response")
        }
    }

    func testLockedInputNeverReachesAI() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService()
        h.app.services.ai = ai
        h.app.services.lock = FakeLockService(locked: [Fixtures.docID])
        do {
            try await h.run(CommandIDs.mathSolve, ["refs": ["page:FIXTUREDOC01/FIXTUREPG001"], "mode": "solve"])
            XCTFail("Expected locked document rejection")
        } catch let error as NibError { XCTAssertEqual(error.code, .locked) }
        XCTAssertTrue(ai.requests.isEmpty)
    }

    func testMenuParamsCarryPageFallbackTextRangeAndLassoBounds() throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let page = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: NibID("FIXTUREPG001"))
        let fallback = FeatAIMathFeature.menuParams(page, mode: .solve, location: .pageLongPress)
        XCTAssertEqual(fallback["refs"], ["page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertEqual(FeatAIMathFeature.menuParams(page, mode: .teach, location: .documentMore)["refs"], fallback["refs"])
        let selection = Selection(doc: Fixtures.docID, page: NibID("FIXTUREPG001"), items: [NibID("STROKE01")],
                                  bounds: Rect(x: 10, y: 20, width: 30, height: 40))
        let text = MenuContext(app: h.app, doc: Fixtures.docID, page: NibID("FIXTUREPG001"), selection: selection,
                               itemKinds: [.text], ref: "item:FIXTUREDOC01/FIXTUREPG001/TEXT01", textRange: [3,4])
        let params = FeatAIMathFeature.menuParams(text, mode: .teach, location: .textSelection)
        XCTAssertEqual(params["refs"], ["item:FIXTUREDOC01/FIXTUREPG001/TEXT01"])
        XCTAssertEqual(params["textRange"], [3,4])
        XCTAssertNil(params["bbox"])
        let lasso = FeatAIMathFeature.menuParams(text, mode: .solve, location: .objectMenu)
        XCTAssertEqual(lasso["refs"], ["item:FIXTUREDOC01/FIXTUREPG001/STROKE01"])
        XCTAssertEqual(lasso["bbox"], [10,20,30,40])
        for kind in [ItemKind.image, .shape, .sticky] {
            let unsupported = MenuContext(app: h.app, doc: Fixtures.docID, page: NibID("FIXTUREPG001"), itemKinds: [kind])
            XCTAssertFalse(FeatAIMathFeature.menuVisible(unsupported, mode: .solve, location: .objectMenu))
        }
        XCTAssertTrue(FeatAIMathFeature.menuVisible(text, mode: .teach, location: .textSelection))
        let pdf = MenuContext(app: h.app, doc: Fixtures.docID, page: NibID("FIXTUREPG003"))
        XCTAssertTrue(FeatAIMathFeature.menuVisible(pdf, mode: .solve, location: .pageLongPress))
        XCTAssertFalse(FeatAIMathFeature.menuVisible(page, mode: .solve, location: .pageLongPress))
    }

    func testRecognitionRoutesMathAndRichTextWithoutHandwritingRecognition() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService()
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "F003 typed fixtures.", effect: .read)) { p, _ in
            if p["ref"]?.stringValue?.hasSuffix("MATH01") == true {
                return ["kind": "math", "math": ["latex": ["x^2=4"]]]
            }
            return ["kind": "text", "text": ["text": try JSONValue.from(RichText(plain: "📝 2+2 9+9"))]]
        }
        let math = try await h.run(CommandIDs.mathSolve, ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/MATH01"], "mode": "solve", "action": "recognize"])
        XCTAssertEqual(try math.decode(MathSession.self).equations, ["x^2=4"])
        let text = try await h.run(CommandIDs.mathSolve, ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/TEXT01"], "mode": "solve", "action": "recognize", "textRange": [3,3]])
        XCTAssertEqual(try text.decode(MathSession.self).equations, ["2+2"])
        XCTAssertEqual(try text.decode(MathSession.self).recognitionSource, "typed")
        XCTAssertTrue(ai.requests.isEmpty)
    }

    func testPageRecognitionFiltersSourcesAndLassoBounds() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.recognizePageText, title: "Page Text", summary: "F055 TextRecognition fixture.", effect: .read)) { p, _ in
            XCTAssertEqual(p["page"], "page:FIXTUREDOC01/FIXTUREPG003")
            return ["page": p["page"]!, "language": "en", "truncated": false, "blocks": [
                ["source": "pdf", "text": "2+2", "bbox": [10,10,20,20], "itemIDs": [], "confidence": 1],
                ["source": "pdf", "text": "9+9", "bbox": [100,100,20,20], "itemIDs": [], "confidence": 1],
                ["source": "scan", "text": "3+3", "bbox": [10,10,20,20], "itemIDs": [], "confidence": 1],
                ["source": "typed", "text": "4+4", "bbox": [10,10,20,20], "itemIDs": [], "confidence": 1],
                ["source": "ink", "text": "Ignore", "bbox": [10,10,20,20], "itemIDs": [], "confidence": 1]]]
        }
        let result = try await h.run(CommandIDs.mathSolve, ["refs": ["page:FIXTUREDOC01/FIXTUREPG003"], "mode": "solve", "action": "recognize", "bbox": [0,0,50,50]])
        XCTAssertEqual(try result.decode(MathSession.self).equations, ["2+2", "3+3", "4+4"])
    }

    func testPDFTextFallbackAndSelectedRange() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.pdfText, title: "PDF Text", summary: "F024 fixture.", effect: .read)) { _, _ in
            ["page": "page:FIXTUREDOC01/FIXTUREPG003", "pdfPage": 0, "text": "Question: 2+2"]
        }
        let result = try await h.run(CommandIDs.mathSolve, ["refs": ["page:FIXTUREDOC01/FIXTUREPG003"], "mode": "solve", "action": "recognize", "textRange": [10,3]])
        XCTAssertEqual(try result.decode(MathSession.self).equations, ["2+2"])
    }

    func testReopeningPanelWithNewParamsRecreatesLessonAndSelection() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        var context = PanelContext(app: h.app, session: h.session, navigator: nil, dismiss: {})
        context.params = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/MATH01"], "mode": "solve"]
        let originalID = SolvePanel.contentID(context)
        let original = SolvePanelModel(context)
        original.state.plan = MathPlan(steps: [.init(title: "Add", detail: "Add")], answer: "4")
        context.params = ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/MATH02"], "mode": "teach", "latex": "3+3"]
        XCTAssertNotEqual(SolvePanel.contentID(context), originalID)
        let reopened = SolvePanelModel(context)
        XCTAssertEqual(reopened.refs, ["item:FIXTUREDOC01/FIXTUREPG001/MATH02"])
        XCTAssertEqual(reopened.state.mode, .teach)
        XCTAssertEqual(reopened.latex, "3+3")
        XCTAssertNil(reopened.state.plan)
        XCTAssertFalse(reopened.state.revealed)
        reopened.state = MathSession(equations: ["3+3"], mode: .teach, plan: MathPlan(hints: ["Count", "Add"], answer: "6"), hintCount: 1)
        reopened.run(.hint)
        XCTAssertEqual(reopened.state.hintCount, 2)
        XCTAssertFalse(reopened.busy)
        XCTAssertFalse(MathTutor.spoken(#"\sqrt{2} = \frac{1}{2}"#).contains("\\"))
    }

}
