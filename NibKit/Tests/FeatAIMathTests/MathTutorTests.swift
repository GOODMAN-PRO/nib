import XCTest
import NibContracts
import NibTesting
@testable import FeatAIMath

@MainActor
final class MathTutorTests: XCTestCase {
    func testStructuredProtocolRejectsEmptyOrWrongTypes() throws {
        let plan = try MathPlan.parse("```json\n{\"hints\":[\"Start with the known values.\"],\"answer\":\"4\"}\n```", mode: .teach)
        XCTAssertEqual(plan.hints.count, 1)
        for text in [#"{"hints":[],"answer":"4"}"#, #"{"hints":[7],"answer":"4"}"#,
                     #"{"hints":[" "],"answer":"4"}"#, #"{"hints":["Hint"],"answer":4}"#,
                     #"{"steps":[{"title":"Step"}],"answer":"4"}"#] {
            XCTAssertThrowsError(try MathPlan.parse(text, mode: text.contains("steps") ? .solve : .teach))
        }
        XCTAssertThrowsError(try MathPlan.parse(String(repeating: "x", count: 131_073), mode: .teach))
    }

    func testProgressionCapsHintsAndKeepsAnswerHiddenUntilReveal() throws {
        let plan = MathPlan(hints: ["First hint", "Second hint"], answer: "4")
        var state = MathSession(mode: .teach, plan: plan)
        state = try MathTutor.transition(.hint, state: state)
        XCTAssertEqual(state.hintCount, 1)
        XCTAssertFalse(state.revealed)
        state = try MathTutor.transition(.skip, state: state)
        XCTAssertEqual(state.hintCount, 2)
        XCTAssertEqual(state.skipped, 1)
        state = try MathTutor.transition(.hint, state: state)
        XCTAssertEqual(state.hintCount, 2)
        XCTAssertFalse(state.revealed)
        XCTAssertTrue(try MathTutor.transition(.reveal, state: state).revealed)
    }

    func testExpansionAndEditResetPresentation() throws {
        var state = MathSession(plan: MathPlan(steps: [.init(title: "Add", detail: "Add terms")], answer: "4"))
        state = try MathTutor.transition(.expand, state: state, index: 0)
        XCTAssertEqual(state.expanded, [0])
        XCTAssertEqual(try MathTutor.transition(.expand, state: state, index: 0).expanded, [])
        XCTAssertThrowsError(try MathTutor.transition(.expand, state: state, index: 1))
        state = try MathTutor.transition(.edit, state: state)
        XCTAssertNil(state.plan)
        XCTAssertEqual(state.expanded, [])
        XCTAssertFalse(state.revealed)
    }

    func testNumericExtractionIsConservative() {
        XCTAssertEqual(MathTutor.numericAnswer("x = 3/2")?.value, 1.5)
        XCTAssertEqual(MathTutor.numericAnswer("\\(x=2\\)")?.variable, "x")
        XCTAssertEqual(MathTutor.numericAnswer("$4$")?.value, 4)
        XCTAssertEqual(MathTutor.numericAnswer("\\frac{1}{2}")?.value, 0.5)
        for text in ["The answer is 4", "4 metres", "x=2 or x=-2", "[1,2]", "NaN", "inf", "1/0"] {
            XCTAssertNil(MathTutor.numericAnswer(text), text)
        }
        XCTAssertNil(MathTutor.scalar(["value": "4"]))
        XCTAssertTrue(MathTutor.close(1.0 / 3, 0.333333333333))
        XCTAssertFalse(MathTutor.close(4, 5))
    }

    func testTutorFollowUpsAndAnswerCheckUseCommandAPI() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService(responses: [
            .init(text: #"{"hints":["Add the values.","Count two more."],"answer":"5"}"#),
            .init(text: #"{"hints":["Use a number line.","Move two places right."],"answer":"4"}"#),
            .init(text: #"{"hints":["Picture two pairs."],"answer":"4"}"#)
        ])
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { _, _ in ["value": 4] }
        var state = try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "teach"])
        XCTAssertEqual(try state.decode(MathSession.self).verification, .mismatch)
        let checked = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "check", "attempt": "4", "state": state])
        XCTAssertEqual(try checked.decode(MathSession.self).feedback, "Your answer checks out on-device.")
        state = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "alternative", "state": state])
        XCTAssertEqual(try state.decode(MathSession.self).verification, .verified)
        XCTAssertTrue(ai.requests[1].messages.contains { $0.text.contains("different valid method") })
        state = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "explain", "state": state])
        XCTAssertTrue(ai.requests[2].messages.contains { $0.text.contains("more clearly") })
        XCTAssertFalse(try state.decode(MathSession.self).revealed)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testTeacherHintsAreReadLocallyWithoutSendingToAI() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService()
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Test answer zone.", effect: .read)) { _, _ in
            return ["custom": ["owner": "teacher", "type": "answerZone", "data": ["hints": ["Consider the units.", "Use the formula."], "revealedHintCount": 1]]]
        }
        let result = try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "teach", "action": "recognize",
                                                          "teacherRef": "item:FIXTUREDOC01/FIXTUREPG001/ZONE01"])
        let state = try result.decode(MathSession.self)
        XCTAssertEqual(state.teacherHints, ["Consider the units.", "Use the formula."])
        XCTAssertEqual(state.hintCount, 1)
        XCTAssertTrue(ai.requests.isEmpty)
        do {
            try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "hint", "state": result])
            XCTFail("Teacher usage must be recorded through F099")
        } catch let error as NibError { XCTAssertEqual(error.code, .unsupported) }
    }

    func testTeacherHintProvenanceAndBounds() throws {
        XCTAssertThrowsError(try MathTutor.teacherHints(["owner": "dev.example.plugin", "type": "answerZone", "data": ["hints": ["A hint"]]]))
        let hints = try MathTutor.teacherHints(["owner": "teacher", "type": "answerZone", "data": ["hints": ["A hint"], "revealedHintCount": 100]])
        XCTAssertEqual(hints.revealed, 1)
    }

    func testSystemsAndMatricesUseOnDeviceVerification() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.services.ai = FakeAIService(responses: [
            .init(text: #"{"steps":[{"title":"Substitute","detail":"Use both equations."}],"answer":"x=2, y=3"}"#),
            .init(text: #"{"steps":[{"title":"Multiply","detail":"Multiply rows by columns."}],"answer":"[[1,2],[3,4]]"}"#)
        ])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { p, _ in
            switch p["expression"]?.stringValue {
            case "x+y", "5":
                XCTAssertEqual(p["variables"]?["x"], .number(2))
                XCTAssertEqual(p["variables"]?["y"], .number(3))
                return ["value": 5]
            case "y-x", "1": return ["value": 1]
            default: return ["value": [[1,2],[3,4]]]
            }
        }
        let system = try await h.run(CommandIDs.mathSolve, ["latex": "x+y=5\ny-x=1", "mode": "solve"])
        XCTAssertEqual(try system.decode(MathSession.self).verification, .verified)
        let matrix = try await h.run(CommandIDs.mathSolve, ["latex": "A*I", "mode": "solve"])
        XCTAssertEqual(try matrix.decode(MathSession.self).verification, .verified)
        XCTAssertNil(MathTutor.assignments("x=2, x=3"))
        XCTAssertFalse(MathTutor.equalValues([[1,2]], [[1],[2]]))
    }
}
