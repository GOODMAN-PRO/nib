import XCTest
import NibContracts
import NibTesting
import FeatMathAssist

/// math.evaluate through the command bus: registration, conformance, JSON params, errors and callers.
@MainActor
final class FeatMathAssistTests: XCTestCase {
    private func harness() -> Harness { Harness(features: [FeatMathAssistFeature.self]) }

    /// The NibError a call throws (nil when it succeeds).
    private func nibError(_ body: () async throws -> Void) async -> NibError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? NibError ?? NibError.wrap(error)
        }
    }

    func testFeatureID() {
        XCTAssertEqual(FeatMathAssistFeature.id, "mathassist")
    }

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatMathAssistFeature.self],
                                                      owners: [FeatMathAssistFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersExactlyItsCommands() {
        let h = harness()
        let ids = Set(h.app.commands.all().filter { $0.owner == FeatMathAssistFeature.id }.map { $0.id })
        XCTAssertEqual(ids, ["math.evaluate"])
        let descriptor = h.app.commands.descriptor("math.evaluate")
        XCTAssertEqual(descriptor?.effect, .read)
        XCTAssertEqual(descriptor?.exposure, .all)
    }

    func testDescriptorExamplesRun() async throws {
        let h = harness()
        let examples = try XCTUnwrap(h.app.commands.descriptor("math.evaluate")).examples
        for example in examples {
            let result = try await h.run("math.evaluate", example, as: .ai("examples"))
            XCTAssertNotNil(result["answer"]?.stringValue, example.jsonString())
        }
        let withVariables = try await h.run("math.evaluate", examples[2])
        XCTAssertEqual(withVariables["answer"]?.stringValue, "11")
    }

    func testSolvesAnEquationThroughTheBus() async throws {
        let h = harness()
        let result = try await h.run("math.evaluate", ["expression": "x^2 - 5x + 6 = 0"])
        XCTAssertEqual(result["kind"]?.stringValue, "solutions")
        XCTAssertEqual(result["answer"]?.stringValue, "x = 2, x = 3")
        XCTAssertEqual(result["latex"]?.stringValue, "x = 2, x = 3")
        let values = result["solutions"]?.arrayValue?.compactMap { $0["value"]?.doubleValue }
        XCTAssertEqual(values, [2, 3])
        XCTAssertEqual(h.undoDepths().values.reduce(0, +), 0, "a read never touches the undo stacks")
    }

    func testVariablesAndFormat() async throws {
        let h = harness()
        let variables: JSONValue = ["a": 0.5, "f(x)": "x^2"]
        let result = try await h.run("math.evaluate",
                                     ["expression": "f(3) + a =", "variables": variables, "format": "mixed"])
        XCTAssertEqual(result["answer"]?.stringValue, "9 1/2")
        XCTAssertEqual(result["value"]?.doubleValue, 9.5)
        XCTAssertEqual(result["exact"]?.boolValue, true)
        XCTAssertEqual(result["kind"]?.stringValue, "value")
    }

    func testMatrixVariable() async throws {
        let h = harness()
        let rows: JSONValue = [[1, 2], [3, 4]]
        let variables: JSONValue = ["A": rows]
        let det = try await h.run("math.evaluate", ["expression": "det(A) =", "variables": variables])
        XCTAssertEqual(det["value"]?.doubleValue, -2)
        let inverse = try await h.run("math.evaluate",
                                      ["expression": "A^{-1} =", "variables": variables, "format": "decimal"])
        XCTAssertEqual(inverse["kind"]?.stringValue, "matrix")
        let expected: JSONValue = [[-2, 1], [1.5, -0.5]]
        XCTAssertEqual(inverse["matrix"], expected)
    }

    /// The hint carries the call as JSON, so quotes and primes in the maths survive being copied into a tool call.
    func testUnsupportedSuggestsAISolveWithTheExpression() async throws {
        let h = harness()
        for expression in ["sin(x) = 1/2", "f'(x) = 1", "\\lim_{x \\to 0} \"x\""] {
            let error = await nibError { _ = try await h.run("math.evaluate", ["expression": .string(expression)]) }
            XCTAssertEqual(error?.code, .unsupported, expression)
            let hint = try XCTUnwrap(error?.hint, expression)
            let prefix = "try AI Solve: call math.solve "
            XCTAssertTrue(hint.hasPrefix(prefix), hint)
            let call = try JSONValue.parse(String(hint.dropFirst(prefix.count)))
            XCTAssertEqual(call["latex"]?.stringValue, expression)
            XCTAssertEqual(call["mode"]?.stringValue, "solve")
        }
    }

    /// Input is bounded before it is parsed: long expressions and variables are invalid_params at their path.
    func testOverlongInputIsRefusedAtItsPath() async {
        let h = harness()
        let long = Array(repeating: "1", count: 2_001).joined(separator: "+") + " ="
        let tooLong = await nibError { _ = try await h.run("math.evaluate", ["expression": .string(long)]) }
        XCTAssertEqual(tooLong?.code, .invalidParams)
        XCTAssertEqual(tooLong?.path, "$.expression")
        let variables: JSONValue = ["a": .string(String(repeating: "1+", count: 1_000) + "1")]
        let longVariable = await nibError {
            _ = try await h.run("math.evaluate", ["expression": "a =", "variables": variables])
        }
        XCTAssertEqual(longVariable?.code, .invalidParams)
        XCTAssertEqual(longVariable?.path, "$.variables.a")
        let deep = await nibError {
            _ = try await h.run("math.evaluate", ["expression": .string(String(repeating: "(", count: 1_000) + "1" +
                                                                       String(repeating: ")", count: 1_000) + " =")])
        }
        XCTAssertEqual(deep?.code, .unsupported, "too deeply nested: refused, never a stack overflow")
    }

    func testBadParametersNameTheirPath() async {
        let h = harness()
        let badFormat = await nibError {
            _ = try await h.run("math.evaluate", ["expression": "1 =", "format": "roman"])
        }
        XCTAssertEqual(badFormat?.code, .invalidParams)
        XCTAssertEqual(badFormat?.path, "$.format")
        let badName: JSONValue = ["2x": 3]
        let badVariable = await nibError {
            _ = try await h.run("math.evaluate", ["expression": "1 =", "variables": badName])
        }
        XCTAssertEqual(badVariable?.code, .invalidParams)
        XCTAssertEqual(badVariable?.path, "$.variables.2x")
        let aiFormat = await nibError {
            _ = try await h.run("math.evaluate", ["expression": "1 =", "format": "roman"], as: .ai("chat"))
        }
        XCTAssertEqual(aiFormat?.code, .invalidParams, "the schema's choices reject it for non-user callers")
    }

    func testAIAndBridgeCanEvaluate() async throws {
        let h = harness()
        let ai = try await h.run("math.evaluate", ["expression": "2+3="], as: .ai("chat"))
        XCTAssertEqual(ai["answer"]?.stringValue, "5")
        let bridge = try await h.run("math.evaluate", ["expression": "x + y = 3; x - y = 1"], as: .bridge("test"))
        XCTAssertEqual(bridge["answer"]?.stringValue, "x = 2, y = 1")
    }
}
