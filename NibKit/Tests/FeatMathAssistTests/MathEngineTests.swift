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

    private func assertError(_ source: String, _ code: NibError.Code, context: [String] = [],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try answer(source, context: context), "input: \(source)", file: file, line: line) { error in
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
        assertAnswers([("x^2 = 2", "x \u{2248} \u{2212}1.414213562, x \u{2248} 1.414213562")], format: .decimal)
    }

    /// With f on the page, "f(x) = 7" asks when f is 7; a right-hand side in the parameter redefines f.
    func testSolvingAPageFunctionForAValue() throws {
        assertAnswers([("f(x) = 7", "x = 3"), ("f(x) + 1 = 8", "x = 3"), ("f(t) = 5", "t = 2")],
                      context: ["f(x) = 2x + 1"])
        assertAnswers([("f(x) = 2x + 1\nf(x) = 7", "x = 3")])
        let redefined = try answer("f(x) = x^3", context: ["f(x) = 2x + 1"])
        XCTAssertEqual(redefined.kind, "definition")
        XCTAssertEqual(try answer("f(2) =", context: ["f(x) = 2x + 1", "f(x) = 7", "f(x) = x^3"]).answer, "8",
                       "an equation line on the page doesn't redefine f; a later definition does")
    }

    /// Repeated roots, exactly (the square-free part and fraction roots come out before anything numeric) and
    /// numerically (a Durand–Kerner cluster merged into one root).
    func testRepeatedRoots() {
        assertAnswers([
            ("(x-1)^3 = 0", "x = 1"),
            ("x^3 - 3x^2 + 3x - 1 = 0", "x = 1"),
            ("x^3 + 3x^2 + 3x + 1 = 0", "x = \u{2212}1"),
            ("(x-2)^4 = 0", "x = 2"),
            ("x^4 - 4x^3 + 6x^2 - 4x + 1 = 0", "x = 1"),
            ("(x - 1/3)^3 = 0", "x = 1/3"),
            ("(2x - 1)^3 = 0", "x = 1/2"),
            ("(x^2+1)^2 = 0", "x = \u{00B1}i"),
            ("(3x + 2)^2 (x - 5) = 0", "x = \u{2212}2/3, x = 5"),
            ("x^3 - x^2 - 2x + 2 = 0", "x = \u{2212}\u{221A}2, x = 1, x = \u{221A}2"),
            ("(x-1)^2 (x^2 - 2) = 0", "x = \u{2212}\u{221A}2, x = 1, x = \u{221A}2"),
            ("(x - 1)^5 = 0", "x = 1"),
            ("(x-\u{03C0})^3 = 0", "x \u{2248} 3.141592654"),
            ("(x-\u{03C0})^4 = 0", "x \u{2248} 3.141592654"),
            ("(x-\u{221A}2)^3 (x+1) = 0", "x \u{2248} \u{2212}1, x \u{2248} 1.414213562"),
            ("(x^2+\u{03C0})^2 = 0", "x \u{2248} 1.772453851i, x \u{2248} \u{2212}1.772453851i"),
            ("(x - \u{03C0})(x - \u{03C0} - 0.00001)(x + 5) = 0",
             "x \u{2248} \u{2212}5, x \u{2248} 3.141592654, x \u{2248} 3.141602654"),
        ])
        XCTAssertEqual(try answer("(x-1)^3 = 0").solutions?.count, 1)
        XCTAssertTrue(try answer("(x-1)^3 = 0").exact)
    }

    /// Coefficients far apart in size are scaled before the numeric methods.
    func testExtremeCoefficients() throws {
        assertAnswers([
            ("x^2 + 10^200 x + 1 = 0", "x \u{2248} \u{2212}1 \u{00D7} 10^200, x \u{2248} \u{2212}1 \u{00D7} 10^-200"),
            ("10^308 x^2 + 10^308 x = 10^308", "x \u{2248} \u{2212}1.618033989, x \u{2248} 0.6180339887"),
            ("x^3 + 10^200 x - 1 = 0", "x \u{2248} 1 \u{00D7} 10^-200"),
            ("10^300 x^3 + x - 1 = 0", "x \u{2248} 1 \u{00D7} 10^-100"),
        ])
        XCTAssertEqual(try answer("x^3 + 10^200 x - 1 = 0").solutions?.count, 3, "and the complex pair near ±10^100 i")
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
            // "Latest wins" is for page values: a name given two values that use unknowns is two equations.
            ("y = 2x + 1; y = 3 - x", "x = 2/3, y = 7/3"),
            ("\\begin{cases} y = 2x + 1 \\\\ y = 3 - x \\end{cases}", "x = 2/3, y = 7/3"),
            ("y = 2x + 1\ny = 5", "x = 2, y = 5"),
            // Definitions that lead back to each other are equations too.
            ("y = 2x + 1\nx = 1 - y", "x = 0, y = 1"),
            ("a = 2\na = 5\nx + a = 7", "x = 2"),
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

    /// Ridders' extrapolation: steps sized to x (never across a singularity or out of the domain), digits the error
    /// supports, and fractions within the error.
    func testNumericDerivatives() {
        assertAnswers([
            ("d/dx(1/x)|_{x=0.001} =", "\u{2212}1000000"),
            ("diff(ln(x), x, 0.001) =", "1000"),
            ("d/dx(sqrt(x))|_{x=0.0001} =", "50"),
            ("\\frac{d^3}{dx^3}(x^4)|_{x=1} =", "24"),
            ("\\frac{d^4}{dx^4}(x^4)|_{x=1} =", "24"),
            ("f(x) = 1/x\nf'(0.01) =", "\u{2212}10000"),
            ("diff(sin(x), x, 1000) =", "0.5623790763"),
            ("\\frac{d^2}{dx^2}(x^2 + x)|_{x=0} =", "2"),
            ("diff(e^x, x, 0) =", "1"),
        ])
        assertError("d/dx(sqrt(x))|_{x=0} =", .invalidParams)   // the slope is infinite there
        assertError("diff(ln(x), x, -1) =", .invalidParams)
    }

    /// ∫∫: each integral takes its own differential, innermost first.
    func testNestedIntegrals() {
        assertAnswers([
            ("\u{222B}_0^1 \u{222B}_0^1 x y dy dx =", "0.25"),
            ("\\int_0^1\\int_0^2 xy\\,dx\\,dy =", "1"),
            ("\\int_0^1 \\int_0^1 \\int_0^1 x y z \\, dx \\, dy \\, dz =", "0.125"),
        ])
    }

    func testScientificNotation() {
        assertAnswers([
            ("1e5 =", "100000"),
            ("1.5e-3 =", "0.0015"),
            ("1E3 + 1 =", "1001"),
            ("[[1e0, 2e1]] =", "[[1, 20]]"),
            ("diff(x^2, x, 1e3) =", "2000"),
            ("2e =", "5.436563657"),     // 2·e: no digit after the e
            ("2e^2 =", "14.7781122"),
            ("2e\u{2212}1 =", "4.436563657"),   // a typeset minus is subtraction: 2e − 1
        ])
    }

    // MARK: Limits: long input throws, never crashes

    /// Every pass over a tree recurses: depth is capped when parsing, evaluation runs on an 8 MB stack, and all of
    /// it holds when the caller is on a 512 KB thread (a dispatch or cooperative-pool thread).
    func testDeepInputThrowsInsteadOfOverflowingTheStack() {
        let sources = [
            Array(repeating: "1", count: 5000).joined(separator: "+") + " =",
            String(repeating: "(", count: 1000) + "1" + String(repeating: ")", count: 1000) + " =",
            String(repeating: "[", count: 1000) + "1" + String(repeating: "]", count: 1000) + " =",
            String(repeating: "-", count: 3000) + "1 =",
            Array(repeating: "x", count: 600).joined(separator: "+") + " = 1",
            Array(repeating: "2", count: 3000).joined(separator: "^") + " =",
            String(repeating: "sin ", count: 2000) + "1 =",
        ]
        final class Outcomes: @unchecked Sendable {
            var codes: [String] = []
        }
        let outcomes = Outcomes()
        let done = expectation(description: "evaluated on a small stack")
        let thread = Thread {
            for source in sources {
                do {
                    _ = try MathEngine().evaluate(source)
                    outcomes.codes.append("answered")
                } catch let error as NibError {
                    outcomes.codes.append(error.code.rawValue)
                } catch {
                    outcomes.codes.append("\(error)")
                }
            }
            done.fulfill()
        }
        thread.stackSize = 512 << 10
        thread.start()
        wait(for: [done], timeout: 60)
        XCTAssertEqual(outcomes.codes, Array(repeating: NibError.Code.unsupported.rawValue, count: sources.count))

        XCTAssertThrowsError(try answer("f(x) = f(x - 1) + 1\nf(3) =")) { error in
            XCTAssertEqual((error as? NibError)?.message, "f calls itself too deeply")
        }
        let chain = (1..<400).map { "a_\($0) = a_\($0 - 1) + 1" } + ["a_0 = 1"]
        assertError("a_399 =", .invalidParams, context: chain)
        XCTAssertEqual(try answer(Array(repeating: "1", count: 140).joined(separator: "+") + " =").answer, "140")
    }

    /// Expanding an equation is bounded (terms per product, degree), and so is matrix work.
    func testLargeWorkIsRefusedQuickly() {
        let start = Date()
        assertError("(a+b+c+d+f+g+h+k+m+n)^24 = 1", .unsupported)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0 * 4)
        assertError("(x+1)^100 = 0", .unsupported)
        assertAnswers([("(x+1)^64 = 0", "x = \u{2212}1")])
        // About 10¹¹ scalar operations if it ran: matrix products are charged to the step budget.
        let cycle = (0..<30).map { i in "[" + (0..<30).map { $0 == (i + 1) % 30 ? "1" : "0" }.joined(separator: ",") + "]" }
        assertError("P = [" + cycle.joined(separator: ",") + "]\nsum(P^10000, i, 1, 99999) =", .unsupported)
    }

    func testCancellationStopsTheWork() {
        let cancellation = MathCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try MathEngine().evaluate("sum(i^2, i, 1, 99999) =", cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try MathEngine().evaluate("sum(i, i, 1, 100) =", cancellation: MathCancellation()).answer, "5050")
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
        XCTAssertNil(try MathEngine(context: ["f(x) = f(x - 1) + 1"]).function("f(x)")(1), "endless recursion is a gap")

        // Graphs may sample several curves at once: every call has its own evaluator.
        let parabola = try MathEngine(context: ["k = 3"]).function("y = k x^2 + x")
        final class Tally: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var wrong = 0
            func record(_ ok: Bool) {
                lock.lock()
                if !ok { wrong += 1 }
                lock.unlock()
            }
        }
        let tally = Tally()
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            let x = Double(i % 50) / 7
            tally.record(abs((parabola(x) ?? .nan) - (3 * x * x + x)) < 1e-9)
        }
        XCTAssertEqual(tally.wrong, 0)
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
