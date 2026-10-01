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
        let states = [MathSession(equations: ["2+2"]),
                      MathSession(equations: ["2+2"], plan: MathPlan(steps: [.init(title: "Add the values", detail: "Two pairs make four.")], answer: "4"), revealed: true, expanded: [0], verification: .verified),
                      MathSession(equations: ["2+2"], mode: .teach, plan: MathPlan(hints: ["Start with two, then count two more."], answer: "4"), hintCount: 1)]
        for state in states {
            for variant in NibSnapshot.Variant.allCases {
                for width in [CGFloat(344), CGFloat(390)] {
                    let view = SolvePanel(context: context, initialState: state)
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
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Maths-\(state.mode.rawValue)-\(variant.rawValue)-\(width)-\(state.plan == nil ? "review" : "lesson")"
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
            return ["value": 4]
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
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { _, _ in .number(4) }
        let result = try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "solve"])
        XCTAssertEqual(try result.decode(MathSession.self).verification, .mismatch)
    }

    func testRecognitionReviewsWithoutCallingAIAndAcceptsEditedLatex() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService(responses: [.init(text: #"{"steps":[{"title":"Add","detail":"Add the terms."}],"answer":"6"}"#)])
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathRecognize, title: "Recognise", summary: "Test recognition.", effect: .read)) { p, _ in
            XCTAssertEqual(p["refs"]?.arrayValue?.count, 1)
            return ["latex": ["2+2", "x=3"]]
        }
        let reviewed = try await h.run(CommandIDs.mathSolve, ["refs": ["page:FIXTUREDOC01/FIXTUREPG001"], "mode": "solve", "action": "recognize"])
        XCTAssertEqual(try reviewed.decode(MathSession.self).equations, ["2+2", "x=3"])
        XCTAssertTrue(ai.requests.isEmpty)
        let solved = try await h.run(CommandIDs.mathSolve, ["latex": "3+3", "mode": "solve", "state": reviewed])
        XCTAssertEqual(try solved.decode(MathSession.self).equations, ["3+3"])
        XCTAssertTrue(ai.requests[0].messages[0].text.contains("3+3"))
        XCTAssertEqual(try solved.decode(MathSession.self).verification, .unverified)
    }

    func testAssignmentVerificationSubstitutesIntoBothSides() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"hints":["Divide both sides by two."],"answer":"x=3"}"#)])
        var seen: [String] = []
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { p, _ in
            XCTAssertEqual(p["variables"]?["x"], .number(3))
            seen.append(p["expression"]?.stringValue ?? "")
            return ["value": 6]
        }
        let result = try await h.run(CommandIDs.mathSolve, ["latex": "2*x=6", "mode": "teach"])
        XCTAssertEqual(try result.decode(MathSession.self).verification, .verified)
        XCTAssertEqual(seen, ["2*x", "6"])
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
}
