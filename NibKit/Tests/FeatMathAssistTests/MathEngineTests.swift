import XCTest
import NibContracts
@testable import FeatMathAssist

/// F061 acceptance: engine cases (at least 60, including matrices, systems and formats). Every table row is one case.
final class MathEngineTests: XCTestCase {
    private func answer(_ source: String, _ format: MathAnswerFormat = .auto,
                        context: [String] = []) throws -> MathAnswer {
        try MathEngine(context: context).evaluate(source, format: format)
    }

    /// Checks the answer text of every (input, expected) row.
    private func assertAnswers(_ cases: [(String, String)], format: MathAnswerFormat = .auto, context: [String] = [],
                               file: StaticString = #filePath, line: UInt = #line) {
        for (source, expected) in cases {
            XCTAssertEqual(try answer(source, format, context: context).answer, expected, "input: \(source)",
                           file: file, line: line)
        }
    }

    private func assertError(_ source: String, _ code: NibError.Code, file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertThrowsError(try answer(source), "input: \(source)", file: file, line: line) { error in
            XCTAssertEqual((error as? NibError)?.code, code, "input: \(source): \(error)", file: file, line: line)
        }
    }

    // MARK: Arithmetic

    func testArithmeticStaysExact() {
        assertAnswers([
            ("2+3=", "5"),
            ("2(3+4)^2 =", "98"),
            ("10 \u{2212} 4 \u{00D7} 2 =", "2"),
            ("7 \u{00F7} 2 =", "7/2"),
            ("1/3 + 1/6 =", "1/2"),
            ("1/7 + 1/13 =", "20/91"),
            ("2^10 =", "1024"),
            ("2^-2 =", "1/4"),
            ("\u{2212}3^2 =", "\u{2212}9"),
            ("5! =", "120"),
            ("200 \u{00D7} 15% =", "30"),
            ("3(2+1)(4) =", "36"),
            ("4\u{00B2} =", "16"),
            ("|\u{2212}5| =", "5"),
            ("sqrt(16) =", "4"),
            ("8^(2/3) =", "4"),
            ("2^70 =", "1.180591621 \u{00D7} 10^21"),
        ])
    }

    func testDecimalsFunctionsAndLatex() {
        assertAnswers([
            ("0.1 + 0.2 =", "0.3"),
            ("\u{221A}2 =", "1.414213562"),
            ("2\u{03C0} =", "6.283185307"),
            ("e^2 =", "7.389056099"),
            ("sin(30\u{00B0}) =", "0.5"),
            ("cos(\u{03C0}) =", "\u{2212}1"),
            ("ln(e) =", "1"),
            ("log(1000) =", "3"),
            ("log_2 8 =", "3"),
            ("\\sqrt{9} + 2^{3} =", "11"),
            ("\\frac{3}{4} + \\frac{1}{4} =", "1"),
            ("2 \\cdot 3 =", "6"),
            ("2 \u{00B1} 3 =", "5, \u{2212}1"),
        ])
        let plusMinus = try? answer("2 \u{00B1} 3 =")
        XCTAssertEqual(plusMinus?.values, [5, -1])
    }

    // MARK: Answer formats

    func testAnswerFormats() throws {
        XCTAssertEqual(try answer("7/2 =", .fraction).answer, "7/2")
        XCTAssertEqual(try answer("7/2 =", .mixed).answer, "3 1/2")
        XCTAssertEqual(try answer("7/2 =", .decimal).answer, "3.5")
        XCTAssertEqual(try answer("\u{2212}7/2 =", .mixed).answer, "\u{2212}3 1/2")
        XCTAssertEqual(try answer("10/4 =", .mixed).answer, "2 1/2")
        XCTAssertEqual(try answer("1/3 =", .decimal).answer, "0.3333333333")
        XCTAssertEqual(try answer("2/3 =", .decimal).answer, "0.6666666667")
        XCTAssertEqual(try answer("0.25 + 0.5 =", .fraction).answer, "3/4")
        XCTAssertEqual(try answer("1.5 =", .mixed).answer, "1 1/2")
        XCTAssertEqual(try answer("sin(30\u{00B0}) =", .fraction).answer, "1/2")
        XCTAssertEqual(try answer("10^20 =").answer, "1 \u{00D7} 10^20")

        XCTAssertEqual(try answer("7/2 =").latex, "\\frac{7}{2}")
        XCTAssertEqual(try answer("7/2 =", .mixed).latex, "3\\frac{1}{2}")
        let third = try answer("1/3 =", .decimal)
        XCTAssertFalse(third.exact, "0.3333333333 is rounded")
        XCTAssertEqual(try XCTUnwrap(third.value), 1.0 / 3, accuracy: 1e-15)
        let quarter = try answer("1/4 =", .decimal)
        XCTAssertTrue(quarter.exact, "0.25 is shown in full")
        XCTAssertEqual(quarter.latex, "0.25")
        XCTAssertFalse(try answer("sin(30\u{00B0}) =", .fraction).exact, "a recognised fraction of a Double is a guess")
    }

    // MARK: Variables and functions (S-023)

    func testPageVariablesAndFunctions() {
        assertAnswers([("a^2 + b^2 =", "25")], context: ["a = 3", "b = 4"])
        assertAnswers([("a =", "7")], context: ["a = 1", "a = 7"])
        assertAnswers([("c/2 =", "5")], context: ["2 + 2 =", "c = 10", "not maths at all"])
        assertAnswers([("y =", "7")], context: ["y = 2x + 1", "x = 3"])
        assertAnswers([
            ("a = 2\na = 5\n3a =", "15"),
            ("f(x) = x^2 + 1\nf(3) =", "10"),
            ("g(x, y) = x y\ng(3, 4) =", "12"),
            ("F(t) = 2t\nF(F(2)) =", "8"),
            ("x_1 = 4\nx_2 = 6\nx_1 + x_2 =", "10"),
            ("f(x) = x^2\nf'(3) =", "6"),
            ("f(x) = x^3\nf''(1) =", "6"),
            ("b = a + 1\na = 2\nb =", "3"),
            ("h = 3\nh(2) =", "6"),
        ])
    }

    func testDefinitionsOnTheirOwn() throws {
        let value = try answer("a = 2 + 3")
        XCTAssertEqual(value.kind, "definition")
        XCTAssertEqual(value.answer, "a = 5")
        XCTAssertEqual(try answer("f(x) = x^2").answer, "f(x)")
        let lazy = try answer("y = 2x + 1")
        XCTAssertEqual(lazy.kind, "definition")
        XCTAssertEqual(lazy.message, "Defines y in terms of x")
        XCTAssertEqual(try answer("x_1 = 3").latex, "x_{1} = 3")
    }

    // MARK: Equations

    func testEquationsInOneUnknown() {
        assertAnswers([
            ("2x + 3 = 7", "x = 2"),
            ("2(x + 1) = x + 5", "x = 3"),
            ("x/2 + 1 = 4", "x = 6"),
            ("1/x = 4", "x = 1/4"),
            ("x^2 - 5x + 6 = 0", "x = 2, x = 3"),
            ("x^2 - 4x + 4 = 0", "x = 2"),
            ("x^2 = 2", "x = \u{00B1}\u{221A}2"),
            ("x^2 - 2x - 1 = 0", "x = 1 \u{00B1} \u{221A}2"),
            ("x^2 + x - 1 = 0", "x = (\u{2212}1 \u{00B1} \u{221A}5)/2"),
            ("x^2 + 2x + 5 = 0", "x = \u{2212}1 \u{00B1} 2i"),
            ("x^2 + 1 = 0", "x = \u{00B1}i"),
            ("x^3 - 6x^2 + 11x - 6 = 0", "x = 1, x = 2, x = 3"),
            ("x^4 - 5x^2 + 4 = 0", "x = \u{2212}2, x = \u{2212}1, x = 1, x = 2"),
            ("x^3 - 2x = 0", "x = \u{2212}\u{221A}2, x = 0, x = \u{221A}2"),
            ("x^3 = 8", "x = 2"),
            ("x^3 = 2", "x \u{2248} 1.25992105"),
            ("x = 2 \u{00B1} 3", "x = \u{2212}1, x = 5"),
            ("2x + 3 = 2x + 5", "No solution"),
            ("x + 1 = x + 1", "Every value of x"),
            ("2 + 2 = 4", "True"),
            ("2 + 2 = 5", "False"),
        ])
        assertAnswers([("2x + a = 7", "x = 2")], context: ["a = 3"])
        assertAnswers([("f(x) + 1 = 8", "x = 3")], context: ["f(x) = 2x + 1"])   // f(x) = 8 alone would redefine f
        assertAnswers([("x^2 = 2", "x \u{2248} \u{2212}1.414213562, x \u{2248} 1.414213562")], format: .decimal)
    }

    func testEquationSolutionsCarryValues() throws {
        let quadratic = try answer("x^2 - 5x + 6 = 0")
        XCTAssertEqual(quadratic.kind, "solutions")
        XCTAssertEqual(quadratic.solutions?.map { $0.value }, [2, 3])
        XCTAssertTrue(quadratic.exact)
        let complex = try answer("x^2 + 2x + 5 = 0")
        XCTAssertEqual(complex.message, "No real solutions")
        XCTAssertEqual(complex.solutions?.compactMap { $0.imaginary }, [2, -2])
        let cubic = try answer("x^3 = 8")
        XCTAssertEqual(cubic.solutions?.count, 3, "the complex pair is listed too")
        XCTAssertEqual(try XCTUnwrap(cubic.value), 2, accuracy: 1e-12)
    }

    // MARK: Systems

    func testLinearSystems() {
        assertAnswers([
            ("x + y = 3\nx - y = 1", "x = 2, y = 1"),
            ("2x + 3y = 12; x - y = 1", "x = 3, y = 2"),
            ("x + y + z = 6\n2x - y + z = 3\nx + 2y - z = 2", "x = 1, y = 2, z = 3"),
            ("\\begin{cases} x + y = 10 \\\\ x - y = 2 \\end{cases}", "x = 6, y = 4"),
            ("x + y = 5, x - y = 1", "x = 3, y = 2"),
            ("x/2 + y/3 = 2\nx - y = 1", "x = 14/5, y = 9/5"),
            ("x = 2y\nx + y = 3", "x = 2, y = 1"),
            ("a = 3\n2x + a = 7", "x = 2"),
            ("x + y = 2\n2x + 2y = 4", "Infinitely many solutions"),
            ("x + y = 2\nx + y = 3", "No solution"),
        ])
        assertAnswers([("x + y = 3\nx - y = 1", "x = 2, y = 1")], format: .decimal)
    }

    // MARK: Matrices (S-026)

    func testMatrixOperations() throws {
        assertAnswers([
            ("A = [[1, 2], [3, 4]]\ndet(A) =", "\u{2212}2"),
            ("[[1, 2], [3, 4]] + [[1, 1], [1, 1]] =", "[[2, 3], [4, 5]]"),
            ("[[1, 2], [3, 4]] - [[1, 1], [1, 1]] =", "[[0, 1], [2, 3]]"),
            ("[[1, 2], [3, 4]] * [[5, 6], [7, 8]] =", "[[19, 22], [43, 50]]"),
            ("2[[1, 2], [3, 4]] =", "[[2, 4], [6, 8]]"),
            ("A = [[4, 7], [2, 6]]\nA^-1 =", "[[3/5, \u{2212}7/10], [\u{2212}1/5, 2/5]]"),
            ("inv([[2, 0], [0, 4]]) =", "[[1/2, 0], [0, 1/4]]"),
            ("[[1, 2], [3, 4]]^T =", "[[1, 3], [2, 4]]"),
            ("[[1, 2], [3, 4]]^2 =", "[[7, 10], [15, 22]]"),
            ("[[1, 2], [3, 4]] [[1], [1]] =", "[[3], [7]]"),
            ("det([[2, 0, 1], [1, 3, 2], [1, 1, 2]]) =", "6"),
            ("det([[1, 2], [2, 4]]) =", "0"),
            ("\\begin{vmatrix} 1 & 2 \\\\ 3 & 4 \\end{vmatrix} =", "\u{2212}2"),
            ("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix} \\begin{pmatrix} 1 \\\\ 1 \\end{pmatrix} =", "[[3], [7]]"),
            ("A = [[1, 2], [3, 4]]\nB = A^T\nA + B =", "[[2, 5], [5, 8]]"),
        ])
        XCTAssertEqual(try answer("A = [[1, 2], [3, 4]]\nA^-1 =", .decimal).answer,
                       "[[\u{2212}2, 1], [1.5, \u{2212}0.5]]")
        let product = try answer("[[1, 2], [3, 4]] * [[5, 6], [7, 8]] =")
        XCTAssertEqual(product.kind, "matrix")
        XCTAssertEqual(product.matrix, [[19, 22], [43, 50]])
        XCTAssertEqual(product.latex, "\\begin{pmatrix} 19 & 22 \\\\ 43 & 50 \\end{pmatrix}")
        assertError("[[1, 2]] + [[1, 2], [3, 4]] =", .invalidParams)
        assertError("inv([[1, 2], [2, 4]]) =", .invalidParams)
        assertError("[[1, 2], [3, 4]] * [[1, 2, 3]] =", .invalidParams)
    }

    // MARK: Calculus, sums and products

    func testSumsProductsAndNumericCalculus() throws {
        assertAnswers([
            ("\u{222B}_0^1 x^2 dx =", "0.3333333333"),
            ("\\int_{0}^{\\pi} \\sin x \\, dx =", "2"),
            ("int(x^2, x, 0, 3) =", "9"),
            ("\u{222B}_0^1 1/\u{221A}x dx =", "2"),
            ("\\sum_{i=1}^{10} i =", "55"),
            ("sum(i^2, i, 1, 5) =", "55"),
            ("\\prod_{k=1}^{5} k =", "120"),
            ("\\sum_{n=1}^{3} \\frac{1}{n} =", "11/6"),
            ("d/dx(x^3)|_{x=2} =", "12"),
            ("\\frac{d}{dx}(x^2)|_{x=3} =", "6"),
            ("diff(sin(x), x, 0) =", "1"),
        ])
        XCTAssertEqual(try answer("\u{222B}_0^1 x^2 dx =", .fraction).answer, "1/3")
        XCTAssertFalse(try answer("\u{222B}_0^1 x^2 dx =").exact, "numeric calculus is never exact")
        XCTAssertTrue(try answer("\\sum_{i=1}^{10} i =").exact)
    }

    // MARK: Limits (S-024)

    func testUnsupportedInputPointsToAISolve() {
        let sources = ["\\lim_{x \\to 0} \\frac{\\sin x}{x}", "\\int x^2 dx", "x^5 - x - 1 = 0", "sin(x) = 1/2",
                       "x^2 + y^2 = 1\nx + y = 1", "2^x = 8"]
        for source in sources {
            XCTAssertThrowsError(try answer(source), source) { error in
                let e = error as? NibError
                XCTAssertEqual(e?.code, .unsupported, source)
                XCTAssertTrue(e?.hint?.contains("math.solve") ?? false, source)
            }
        }
    }

    func testMistakesAreInvalidParams() {
        assertError("1/0 =", .invalidParams)
        assertError("\u{221A}(\u{2212}4) =", .invalidParams)
        assertError("2 + =", .invalidParams)
        assertError("2y + 1 =", .invalidParams)
        assertError("x + y = 3\n2 + 2 =\nx =", .invalidParams)
        assertError("", .invalidParams)
    }

    // MARK: Graph hook (used by the graphs in this module)

    func testFunctionSamplingForGraphs() throws {
        let f = try MathEngine(context: ["a = 1"]).function("y = x^2 + a")
        XCTAssertEqual(try XCTUnwrap(f(2)), 5, accuracy: 1e-12)
        let root = try MathEngine().function("sqrt(x)")
        XCTAssertNil(root(-1), "undefined points are gaps, not errors")
        XCTAssertEqual(try XCTUnwrap(root(9)), 3, accuracy: 1e-12)
        XCTAssertThrowsError(try MathEngine().function("x^2 + y^2 = 1"))
    }

    // MARK: Building blocks

    func testRationalArithmeticFallsBackToDoublesOnOverflow() throws {
        let big = try XCTUnwrap(Rational(Int.max / 2, 1))
        XCTAssertNil(big.multiplying(Rational(integer: 4)))
        XCTAssertEqual(Scalar.exact(big) * Scalar(4), .real(Double(Int.max / 2) * 4))
        XCTAssertEqual(Rational.approximating(0.49999999999999994, maxDenominator: 1000, tolerance: 1e-10),
                       Rational(1, 2))
        XCTAssertEqual(EquationSolver.squareFactor(72).k, 6)
        XCTAssertEqual(EquationSolver.squareFactor(72).m, 2)
    }
}
