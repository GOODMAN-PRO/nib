import XCTest
@testable import FeatMath

final class MathNormalizerTests: XCTestCase {
    func testUnicodeOperatorsAndDigits() {
        XCTAssertEqual(MathNormalizer.line(" 12 − 3 × 2 ÷ 4 ≤ 9 "), "12 - 3 \\times  2 \\div  4 \\leq  9")
    }

    func testSuperscriptRunsAndAsciiPowers() {
        XCTAssertEqual(MathNormalizer.line("x² + y⁻¹² + z^10"), "x^{2} + y^{-12} + z^{10}")
    }

    func testSimpleAndGroupedFractions() {
        XCTAssertEqual(MathNormalizer.line("a / b"), "\\frac{a}{b}")
        XCTAssertEqual(MathNormalizer.line("(a+1)/(b-2)"), "\\frac{(a+1)}{(b-2)}")
        XCTAssertEqual(MathNormalizer.line("1/2 + 3/4"), "\\frac{1}{2} + \\frac{3}{4}")
    }

    func testDecimalFractionsAndAmbiguousSlashChains() {
        XCTAssertEqual(MathNormalizer.line("1.5/2.5"), "\\frac{1.5}{2.5}")
        XCTAssertEqual(MathNormalizer.line("1/2/3"), "1/2/3")
    }

    func testStackedFractionHeuristicAndMultipleLines() {
        XCTAssertEqual(MathNormalizer.lines(["", "x²+1", "---", "2", "y = 3", " "]), ["\\frac{x^{2}+1}{2}", "y = 3"])
    }

    func testPiFractionsAndSpacedSlashChains() {
        XCTAssertEqual(MathNormalizer.line("π/2"), "\\frac{\\pi}{2}")
        XCTAssertEqual(MathNormalizer.line("2π/3"), "\\frac{2\\pi}{3}")
        XCTAssertEqual(MathNormalizer.line("1 / 2 / 3"), "1 / 2 / 3")
        for bar in ["—", "–"] {
            XCTAssertEqual(MathNormalizer.lines(["x+1", bar, "2"]), ["\\frac{x+1}{2}"])
        }
    }

    func testExistingLatexIsUntouched() {
        XCTAssertEqual(MathNormalizer.line(" \\frac{a}{b} "), "\\frac{a}{b}")
        XCTAssertEqual(MathNormalizer.lines([]), [])
    }
}
