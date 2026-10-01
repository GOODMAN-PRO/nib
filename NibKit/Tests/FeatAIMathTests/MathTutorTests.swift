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
            .init(text: #"{"hint":"Picture two pairs."}"#)
        ])
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "Test evaluator.", effect: .read)) { _, _ in mathValue(4) }
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
        XCTAssertEqual(try state.decode(MathSession.self).plan?.hints, ["Picture two pairs.", "Move two places right."])
        XCTAssertEqual(try state.decode(MathSession.self).plan?.answer, "4")
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
    }

    func testTeacherHintsAreReadLocallyWithoutSendingToAI() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService()
        h.app.services.ai = ai
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Test answer zone.", effect: .read)) { _, _ in
            return ["custom": ["owner": "nib.answerZone", "type": "zone", "data": ["hints": ["Consider the units.", "Use the formula."], "revealed": 1]]]
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
        let hints = try MathTutor.teacherHints(["owner": "nib.answerZone", "type": "zone", "data": ["hints": ["A hint"], "revealed": 100]])
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
            case "x+y=5\ny-x=1": return mathSolutions([("x", 2), ("y", 3)])
            default: return ["kind": "matrix", "matrix": [[1,2],[3,4]], "answer": "[[1,2],[3,4]]", "latex": "[[1,2],[3,4]]", "exact": true]
            }
        }
        let system = try await h.run(CommandIDs.mathSolve, ["latex": "x+y=5\ny-x=1", "mode": "solve"])
        XCTAssertEqual(try system.decode(MathSession.self).verification, .verified)
        let matrix = try await h.run(CommandIDs.mathSolve, ["latex": "A*I", "mode": "solve"])
        XCTAssertEqual(try matrix.decode(MathSession.self).verification, .verified)
        XCTAssertNil(MathTutor.assignments("x=2, x=3"))
        XCTAssertFalse(MathTutor.equalValues([[1,2]], [[1],[2]]))
    }

    func testRoundedDecimalsNumericIntegralsAndRootSets() async throws {
        let cases: [(String, String, JSONValue, MathVerification)] = [
            (#"\sqrt{2}"#, "1.414", mathValue(sqrt(2)), .verified),
            ("1/3", "0.333", mathValue(1.0 / 3), .verified),
            ("1/3", "0.334", mathValue(1.0 / 3), .mismatch),
            (#"\int_0^1 x^2 dx"#, "1/3", mathValue(1.0 / 3 + 2e-7, exact: false), .verified),
            ("3*x=1", "x=0.33", mathSolutions([("x", 1.0 / 3)]), .verified),
            ("3*x=1", "x=0.32", mathSolutions([("x", 1.0 / 3)]), .mismatch),
            ("2*x=6", "3", mathSolutions([("x", 3)]), .verified),
            ("x^2-5*x+6=0", "x=3, x=2", mathSolutions([("x", 2), ("x", 3)]), .verified),
            ("x^2-5*x+6=0", "x=2 or x=3", mathSolutions([("x", 2), ("x", 3)]), .verified),
            ("x^2-5*x+6=0", "[3,2]", mathSolutions([("x", 2), ("x", 3)]), .verified),
            ("x^2-5*x+6=0", "x=2", mathSolutions([("x", 2), ("x", 3)]), .mismatch),
            ("x^2-5*x+6=0", "2,3", ["kind": "solutions", "values": [2,3], "answer": "2,3", "latex": "2,3", "exact": true], .verified),
            ("2+2=", "4", mathValue(4), .verified),
            ("2+2=4", "x=999", ["kind": "check", "answer": "True", "latex": #"\text{True}"#, "exact": true], .mismatch),
            ("x+y=5\ny-x=1", "x=2, z=3", mathSolutions([("x", 2), ("y", 3)]), .mismatch)
        ]
        for (problem, answer, evaluated, verdict) in cases {
            let h = Harness(features: [FeatAIMathFeature.self])
            let plan = MathPlan(hints: ["Think about the terms."], answer: answer)
            h.app.services.ai = FakeAIService(responses: [.init(text: try JSONValue.from(plan).jsonString())])
            h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "F061 fixture.", effect: .read)) { p, _ in
                XCTAssertEqual(p["expression"]?.stringValue, problem.hasSuffix("=") ? String(problem.dropLast()) : problem)
                return evaluated
            }
            let result = try await h.run(CommandIDs.mathSolve, ["latex": .string(problem), "mode": "teach"])
            XCTAssertEqual(try result.decode(MathSession.self).verification, verdict, problem + " / " + answer)
            let checked = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "check", "state": result, "attempt": .string(answer)])
            if verdict == .verified { XCTAssertEqual(try checked.decode(MathSession.self).feedback, "Your answer checks out on-device.") }
        }
    }

    func testMatrixPrecisionUsesEachEntryDigits() {
        XCTAssertTrue(MathTutor.equalValues([[.number(sqrt(2)), .number(1.0/3)]], [[1.414,0.333]], candidateText: "[[1.414,0.333]]"))
        XCTAssertFalse(MathTutor.equalValues([[1, 0.333333]], [[1.0,0.334]], candidateText: "[[1.0,0.334]]"))
        XCTAssertEqual(MathTutor.precision("1.414"), 0.0005)
        XCTAssertEqual(MathTutor.precision("1.4e2"), 5)
    }

    func testChangingProblemResetsPlanAndUntrustedVerification() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let old = MathSession(equations: ["2+2"], mode: .teach, plan: MathPlan(hints: ["Add"], answer: "4"),
                              hintCount: 1, revealed: true, expanded: [0], verification: .verified, feedback: "Correct")
        let oldJSON = try JSONValue.from(old)
        let reviewed = try await h.run(CommandIDs.mathSolve, ["latex": "3+3", "mode": "teach", "action": "recognize", "state": oldJSON])
        let next = try reviewed.decode(MathSession.self)
        XCTAssertEqual(next.equations, ["3+3"])
        XCTAssertNil(next.plan)
        XCTAssertEqual(next.verification, .unverified)
        XCTAssertEqual(next.hintCount, 0)
        XCTAssertEqual(next.expanded, [])
        XCTAssertFalse(next.revealed)
        XCTAssertNil(next.feedback)
        do {
            _ = try await h.run(CommandIDs.mathSolve, ["latex": "3+3", "mode": "teach", "action": "reveal", "state": oldJSON])
            XCTFail("A different problem must not reveal the old answer")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
        let revealed = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "reveal", "state": oldJSON])
        XCTAssertEqual(try revealed.decode(MathSession.self).verification, .unverified)
    }

    func testExplainRejectsChangedAnswer() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.services.ai = FakeAIService(responses: [.init(text: #"{"hint":"Try counting","answer":"5"}"#)])
        let state = MathSession(equations: ["2+2"], mode: .teach, plan: MathPlan(hints: ["Count", "Add"], answer: "4"), hintCount: 1)
        do {
            _ = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "explain", "state": try JSONValue.from(state)])
            XCTFail("A replacement hint cannot change the answer")
        } catch let error as NibError { XCTAssertEqual(error.code, .invalidParams) }
    }

    func testTeacherZoneAutoDetectionAndLessonRefreshKeepSeparateCounts() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        var count = 1
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "F099 zone fixture.", effect: .read)) { _, _ in
            ["kind": "custom", "custom": ["owner": "nib.answerZone", "type": "zone", "data": [
                "label": "Question 1", "points": 5, "hints": ["Consider the units.", "Use the formula."],
                "revealed": .number(Double(count)), "usage": []]]]
        }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "F061 fixture.", effect: .read)) { _, _ in mathValue(4) }
        let ref = "item:FIXTUREDOC01/FIXTUREPG001/ZONE01"
        let result = try await h.run(CommandIDs.mathSolve, ["refs": [.string(ref)], "mode": "teach", "action": "recognize"])
        var state = try result.decode(MathSession.self)
        XCTAssertEqual(state.teacherRef, ref)
        XCTAssertEqual(state.teacherHintCount, 1)
        state.equations = ["2+2"]
        state.plan = MathPlan(hints: ["AI hint one", "AI hint two"], answer: "4")
        state.hintCount = 2
        count = 2
        let refreshed = try await h.run(CommandIDs.mathSolve, ["latex": "2+2", "mode": "teach", "action": "recognize",
                                                             "teacherRef": .string(ref), "state": try JSONValue.from(state)])
        let lesson = try refreshed.decode(MathSession.self)
        XCTAssertEqual(lesson.teacherHintCount, 2)
        XCTAssertEqual(lesson.hintCount, 2)
        XCTAssertEqual(lesson.plan, state.plan)
    }

    func testNumericDefinitionsPropagateRoundingIntoResidual() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathEvaluate, title: "Evaluate", summary: "F061 numeric definition fixture.", effect: .read)) { p, _ in
            switch p["expression"]?.stringValue {
            case "y=1/3": return ["kind": "definition", "value": .number(1.0 / 3), "answer": "y=1/3", "latex": #"y=\frac{1}{3}"#, "exact": true, "message": "Defines y"]
            case "y": return mathValue(p["variables"]?["y"]?.doubleValue ?? 0)
            case "1/3": return mathValue(1.0 / 3)
            default: throw NibError.unsupported("Not a fixture expression")
            }
        }
        let state = MathSession(equations: ["y=1/3"], mode: .teach, plan: MathPlan(hints: ["Divide by three."], answer: "y=0.33"))
        let checked = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "check", "state": try JSONValue.from(state), "attempt": "y=0.33"])
        XCTAssertEqual(try checked.decode(MathSession.self).feedback, "Your answer checks out on-device.")
        XCTAssertEqual(try checked.decode(MathSession.self).verification, .verified)
        let wrong = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "check", "state": try JSONValue.from(state), "attempt": "y=0.32"])
        XCTAssertEqual(try wrong.decode(MathSession.self).feedback, "Your answer does not satisfy the problem. Try the next hint.")
        let bare = try await h.run(CommandIDs.mathSolve, ["mode": "teach", "action": "check", "state": try JSONValue.from(state), "attempt": "0.33"])
        XCTAssertEqual(try bare.decode(MathSession.self).feedback, "Your answer checks out on-device.")
    }

    func testCancellationDuringRecognitionDoesNotSendProviderRequest() async throws {
        let h = Harness(features: [FeatAIMathFeature.self])
        let ai = FakeAIService()
        h.app.services.ai = ai
        let started = expectation(description: "Recognition began")
        h.app.commands.register(CommandDescriptor(id: CommandIDs.queryGet, title: "Get", summary: "Stroke fixture.", effect: .read)) { _, _ in ["kind": "stroke"] }
        h.app.commands.register(CommandDescriptor(id: CommandIDs.mathRecognize, title: "Recognize", summary: "Delayed F060 fixture.", effect: .read)) { _, _ in
            started.fulfill()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["lines": ["2+2"], "source": "vision", "warning": "Double-check this recognition."]
        }
        let task = Task { try await h.run(CommandIDs.mathSolve, ["refs": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTR01"], "mode": "solve"]) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertTrue(ai.requests.isEmpty)
    }

}

// F061 MathAnswer JSON, including the fields used by real dependency consumers.
func mathValue(_ value: Double, exact: Bool = true) -> JSONValue {
    ["kind": "value", "value": .number(value), "answer": .string(String(value)), "latex": .string(String(value)), "exact": .bool(exact)]
}

func mathSolutions(_ values: [(String, Double)]) -> JSONValue {
    ["kind": "solutions", "answer": "roots", "latex": "roots", "exact": true,
     "solutions": .array(values.map { name, value in
        ["variable": .string(name), "value": .number(value), "answer": .string(String(value)), "latex": .string(String(value)), "exact": true]
     })]
}
