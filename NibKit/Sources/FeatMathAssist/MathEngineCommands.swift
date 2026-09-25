import Foundation
import NibContracts

// The on-device maths engine (F061), part 4: `MathEngine`, the façade the rest of this module uses (the Math Assist
// overlay passes a page's lines as context; graphs sample `function(_:of:)`), answer formatting, and `math.evaluate`.

// MARK: - Answers

enum MathAnswerFormat: String, CaseIterable {
    /// Fractions, or decimals when the input had decimals (1/3 + 1/6 = 1/2, 0.1 + 0.2 = 0.3).
    case auto
    case fraction
    /// Improper fractions as mixed numbers: 7/2 = 3 1/2.
    case mixed
    case decimal
}

/// What `math.evaluate` returns: the overlay writes `answer` as ink; AI Solve checks `value` / `solutions`.
struct MathAnswer: Codable, Equatable {
    /// "value", "matrix", "solutions", "check" or "definition".
    var kind: String
    /// Plain text in the requested format: "7/2", "3 1/2", "x = (3 ± √5)/2", "[[1, 2], [3, 4]]".
    var answer: String
    var latex: String
    /// True when nothing was rounded (fractions and surds; not decimals of irrational numbers or numeric calculus).
    var exact: Bool
    var value: Double?
    /// Every value, when ± gives several.
    var values: [Double]?
    var matrix: [[Double]]?
    var solutions: [Solution]?
    /// "No real solutions", "Defines f(x)", …
    var message: String?

    struct Solution: Codable, Equatable {
        var variable: String
        var answer: String
        var latex: String
        var value: Double
        /// The imaginary part of a complex solution.
        var imaginary: Double?
        var exact: Bool
    }
}

struct MathStyle {
    var format: MathAnswerFormat
    /// Set when the input had decimals: `auto` then answers in decimals.
    var preferDecimal: Bool
}

// MARK: - Statements

/// What a line is for: a question ("2 + 3 ="), a definition (a = 2, f(x) = x^2, A = [[1, 2], [3, 4]]) or an equation.
enum MathStatementRole {
    case question(MathNode)
    case variable(String, MathNode)
    case function(String, [String], MathNode)
    case equation(MathNode, MathNode)

    init(_ statement: MathStatement) {
        guard let rhs = statement.rhs else {
            self = .question(statement.lhs)
            return
        }
        if statement.plusMinusCount == 0 {
            if case .variable(let name) = statement.lhs, name != "π", !rhs.mentions(name) {
                self = .variable(name, rhs)
                return
            }
            if case .call(let name, let args, 0) = statement.lhs, let parameters = MathStatementRole.parameters(args) {
                self = .function(name, parameters, rhs)
                return
            }
        }
        self = .equation(statement.lhs, rhs)
    }

    private static func parameters(_ args: [MathNode]) -> [String]? {
        var names: [String] = []
        for a in args {
            guard case .variable(let name) = a, !names.contains(name) else { return nil }
            names.append(name)
        }
        return names
    }
}

// MARK: - Engine

/// The on-device evaluator: page definitions plus `evaluate`. A value type; build one per page or request.
struct MathEngine {
    private(set) var definitions: MathDefinitions

    init(definitions: MathDefinitions = MathDefinitions()) {
        self.definitions = definitions
    }

    /// A page's context: the definitions among `lines`, in page order, later ones winning. Other lines (questions,
    /// equations) and lines that don't parse are skipped, as a page is full of those.
    init(context lines: [String]) {
        definitions = MathDefinitions()
        for line in lines {
            guard let statements = try? MathParser.statements(line) else { continue }
            for statement in statements { define(statement) }
        }
    }

    /// Records a definition (replacing an earlier one of the same name); false when the statement isn't one.
    @discardableResult
    mutating func define(_ statement: MathStatement) -> Bool {
        switch MathStatementRole(statement) {
        case .variable(let name, let value):
            definitions.variables[name] = value
            definitions.functions[name] = nil
        case .function(let name, let parameters, let body):
            definitions.functions[name] = MathFunctionDefinition(parameters: parameters, body: body)
            definitions.variables[name] = nil
        case .question, .equation:
            return false
        }
        return true
    }

    /// `variables` of math.evaluate: name → number, expression text or matrix rows ({"a": 2, "f(x)": "x^2",
    /// "A": [[1, 2], [3, 4]]}). Keys are taken in sorted order, so the result never depends on JSON key order.
    mutating func define(variables: [String: JSONValue]) throws {
        for name in variables.keys.sorted() {
            guard let value = variables[name] else { continue }
            do {
                let text: String
                switch value {
                case .number(let d):
                    text = MathEngine.numberText(d)
                case .string(let s):
                    text = s
                case .array(let rows):
                    text = try MathEngine.matrixText(rows)
                default:
                    throw MathFailure.syntax("give a number, an expression such as \"x^2 + 1\" or matrix rows such as [[1, 2], [3, 4]]")
                }
                let statements = try MathParser.statements(name + " = " + text)
                guard statements.count == 1, define(statements[0]) else {
                    throw MathFailure.syntax("define a name (a, x_1, A or f(x)) as a value that doesn't use the name itself")
                }
            } catch let error as NibError {
                throw NibError(.invalidParams, "variables.\(name): \(error.message)", path: "$.variables.\(name)",
                               hint: error.hint)
            }
        }
    }

    /// A JSON number as maths text: integers as they are, others in their shortest decimal form (1e-07 → 1·10^(-07)).
    static func numberText(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        let parts = "\(d)".components(separatedBy: "e")
        return parts.count == 2 ? "(\(parts[0])*10^(\(parts[1])))" : parts[0]
    }

    static func matrixText(_ rows: [JSONValue]) throws -> String {
        var texts: [String] = []
        for row in rows {
            guard case .array(let cells) = row, !cells.isEmpty else {
                throw MathFailure.syntax("a matrix is a list of rows, e.g. [[1, 2], [3, 4]]")
            }
            var entries: [String] = []
            for cell in cells {
                switch cell {
                case .number(let d): entries.append(numberText(d))
                case .string(let s): entries.append("(" + s + ")")
                default: throw MathFailure.syntax("matrix entries must be numbers or expressions")
                }
            }
            texts.append("[" + entries.joined(separator: ", ") + "]")
        }
        guard !texts.isEmpty else { throw MathFailure.syntax("a matrix needs at least one row") }
        return "[" + texts.joined(separator: ", ") + "]"
    }

    /// Works out `source`: one line or several (line breaks, ';', LaTeX '\\', cases). When the last line is an
    /// expression ("… =" or no '=' at all), the lines before it must be definitions. Otherwise the lines are
    /// definitions and equations: the equations are solved together for their unknowns.
    func evaluate(_ source: String, format: MathAnswerFormat = .auto) throws -> MathAnswer {
        let statements = try MathParser.statements(source)
        guard let last = statements.last else { throw MathFailure.syntax("There's nothing to work out") }
        let style = MathStyle(format: format,
                              preferDecimal: source.range(of: "\\.[0-9]", options: .regularExpression) != nil)
        var page = self
        if case .question(let node) = MathStatementRole(last) {
            for index in 0..<(statements.count - 1) {
                guard page.define(statements[index]) else {
                    throw MathFailure.syntax("Line \(index + 1) isn't a definition: only lines like 'a = 2' or 'f(x) = x^2' can come before the one to work out")
                }
            }
            return try page.answer(question: node, plusMinusCount: last.plusMinusCount, style: style)
        }

        var equations: [MathEquation] = []
        var latest: [String: Int] = [:]
        for (index, statement) in statements.enumerated() {
            switch MathStatementRole(statement) {
            case .question:
                throw MathFailure.syntax("Only the last line can be an expression to work out (line \(index + 1) has no '=')")
            case .variable(let name, _):
                page.define(statement)
                latest[name] = index
            case .function:
                page.define(statement)
            case .equation(let lhs, let rhs):
                equations.append(MathEquation(lhs: lhs, rhs: rhs, plusMinusCount: statement.plusMinusCount))
            }
        }
        // A definition that needs an unknown (x = 2y next to x + y = 3) is one of the equations after all.
        var demoted: [String] = []
        var changed = true
        while changed {
            changed = false
            for (name, _) in latest.sorted(by: { $0.value < $1.value }) {
                guard let node = page.definitions.variables[name],
                      !page.definitions.freeNames(.variable(name)).isEmpty else { continue }
                page.definitions.variables[name] = nil
                equations.append(MathEquation(lhs: .variable(name), rhs: node, plusMinusCount: 0))
                demoted.append(name)
                changed = true
            }
        }
        if equations.isEmpty { return try page.answerDefinition(last, style: style) }
        if equations.count == 1, let name = demoted.first {
            // "y = 2x + 1" on its own defines y; it isn't an equation to solve.
            let others = page.definitions.freeNames(equations[0].rhs).subtracting([name]).sorted()
            return MathAnswer(kind: "definition", answer: name, latex: MathFormatter.latexName(name), exact: true,
                              message: "Defines \(name) in terms of \(others.joined(separator: ", "))")
        }
        let outcome = try EquationSolver.solve(equations, definitions: page.definitions)
        return MathFormatter.answer(outcome, style: style)
    }

    /// y = f(x) as a function of x for graphs: "x^2", "y = x^2" or "f(x) = x^2", with the page's definitions. Returns
    /// nil where the function is undefined (√x for x < 0, 1/x at 0).
    func function(_ source: String, of variable: String = "x") throws -> (Double) -> Double? {
        let statements = try MathParser.statements(source)
        guard statements.count == 1, let statement = statements.first else {
            throw MathFailure.syntax("Graph one expression per line, like y = x^2")
        }
        guard statement.plusMinusCount == 0 else { throw MathFailure.unsupported("graphs of expressions with ±") }
        let body: MathNode
        if let rhs = statement.rhs {
            switch statement.lhs {
            case .variable("y"):
                body = rhs
            case .call(_, let args, 0) where args == [.variable(variable)]:
                body = rhs
            default:
                throw MathFailure.unsupported("implicit curves such as x^2 + y^2 = 1")
            }
        } else {
            body = statement.lhs
        }
        let evaluator = MathEvaluator(definitions: definitions)
        return { x in
            guard let y = try? evaluator.sample(body, variable: variable, at: x), y.isFinite else { return nil }
            return y
        }
    }

    private func answer(question node: MathNode, plusMinusCount: Int, style: MathStyle) throws -> MathAnswer {
        let evaluator = MathEvaluator(definitions: definitions)
        var values: [MathValue] = []
        for signs in try EquationSolver.signCombinations(plusMinusCount) {
            let v = try evaluator.evaluate(node, signs: signs)
            if !values.contains(where: { MathValue.nearlyEqual($0, v) }) { values.append(v) }
        }
        return MathFormatter.answer(values: values, style: style, approximate: evaluator.approximate)
    }

    private func answerDefinition(_ statement: MathStatement, style: MathStyle) throws -> MathAnswer {
        switch MathStatementRole(statement) {
        case .variable(let name, _):
            let evaluator = MathEvaluator(definitions: definitions)
            let value = try evaluator.evaluate(.variable(name))
            var answer = MathFormatter.answer(values: [value], style: style, approximate: evaluator.approximate)
            answer.kind = "definition"
            answer.answer = "\(name) = \(answer.answer)"
            answer.latex = "\(MathFormatter.latexName(name)) = \(answer.latex)"
            answer.message = "Defines \(name)"
            return answer
        case .function(let name, let parameters, _):
            let head = "\(name)(\(parameters.joined(separator: ", ")))"
            let latexHead = "\(name)(\(parameters.map(MathFormatter.latexName).joined(separator: ", ")))"
            return MathAnswer(kind: "definition", answer: head, latex: latexHead, exact: true, message: "Defines \(head)")
        case .question, .equation:
            throw MathFailure.syntax("There's nothing to work out")
        }
    }
}

// MARK: - Formatting

enum MathFormatter {
    struct Number {
        var text: String
        var latex: String
        var exact: Bool
    }

    static func number(_ s: Scalar, _ style: MathStyle, inMatrix: Bool = false) -> Number {
        switch s {
        case .exact(let r):
            if r.isInteger { return Number(text: minus(String(r.numerator)), latex: String(r.numerator), exact: true) }
            switch style.format {
            case .decimal:
                return decimal(r)
            case .auto where style.preferDecimal || r.denominator > 1_000_000:
                return decimal(r)
            case .mixed where !inMatrix:
                return fraction(r, mixed: true)
            default:
                return fraction(r, mixed: false)
            }
        case .real(let d):
            if style.format == .fraction || style.format == .mixed,
               let r = Rational.approximating(d, maxDenominator: 1000, tolerance: 1e-10 * max(1, abs(d))) {
                var n = number(.exact(r), style, inMatrix: inMatrix)
                n.exact = false
                return n
            }
            return decimal(d)
        }
    }

    static func fraction(_ r: Rational, mixed: Bool) -> Number {
        let sign = r.numerator < 0 ? "\u{2212}" : ""
        let latexSign = r.numerator < 0 ? "-" : ""
        let n = abs(r.numerator)
        let d = r.denominator
        if mixed && n > d {
            return Number(text: "\(sign)\(n / d) \(n % d)/\(d)", latex: "\(latexSign)\(n / d)\\frac{\(n % d)}{\(d)}",
                          exact: true)
        }
        return Number(text: "\(sign)\(n)/\(d)", latex: "\(latexSign)\\frac{\(n)}{\(d)}", exact: true)
    }

    private static func decimal(_ r: Rational) -> Number {
        var n = decimal(r.doubleValue)
        var d = r.denominator
        while d % 2 == 0 { d /= 2 }
        while d % 5 == 0 { d /= 5 }
        n.exact = d == 1 && Double(n.latex) == r.doubleValue   // a terminating decimal shown in full
        return n
    }

    /// Ten significant digits, trailing zeros dropped; scientific notation outside 10⁻⁹ … 10¹⁵.
    static func decimal(_ d: Double) -> Number {
        guard d != 0, d.isFinite else { return Number(text: "0", latex: "0", exact: false) }
        let exponent = Int(floor(log10(abs(d))))
        if exponent >= 15 || exponent < -9 {
            let parts = String(format: "%.9e", d).components(separatedBy: "e")
            if parts.count == 2, let power = Int(parts[1]) {
                let mantissa = trimmed(parts[0])
                return Number(text: "\(minus(mantissa)) × 10^\(power)", latex: "\(mantissa) \\times 10^{\(power)}",
                              exact: false)
            }
        }
        let places = min(20, max(0, 9 - exponent))
        let text = trimmed(String(format: "%.\(places)f", d))
        return Number(text: minus(text), latex: text, exact: false)
    }

    private static func trimmed(_ s: String) -> String {
        var t = s
        if t.contains(".") {
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
        }
        return t == "-0" ? "0" : t
    }

    /// Answers use the typographic minus.
    private static func minus(_ s: String) -> String {
        s.hasPrefix("-") ? "\u{2212}" + String(s.dropFirst()) : s
    }

    static func value(_ v: MathValue, _ style: MathStyle) -> Number {
        switch v {
        case .scalar(let s):
            return number(s, style)
        case .matrix(let m):
            var exact = true
            var textRows: [String] = []
            var latexRows: [String] = []
            for row in m.rows {
                let cells = row.map { number($0, style, inMatrix: true) }
                exact = exact && cells.allSatisfy { $0.exact }
                textRows.append("[" + cells.map { $0.text }.joined(separator: ", ") + "]")
                latexRows.append(cells.map { $0.latex }.joined(separator: " & "))
            }
            return Number(text: "[" + textRows.joined(separator: ", ") + "]",
                          latex: "\\begin{pmatrix} " + latexRows.joined(separator: " \\\\ ") + " \\end{pmatrix}",
                          exact: exact)
        }
    }

    static func answer(values: [MathValue], style: MathStyle, approximate: Bool) -> MathAnswer {
        let shown = values.map { value($0, style) }
        let allExact = shown.allSatisfy { $0.exact }
        var result = MathAnswer(kind: "value", answer: shown.map { $0.text }.joined(separator: ", "),
                                latex: shown.map { $0.latex }.joined(separator: ", "), exact: !approximate && allExact)
        if values.count == 1, case .matrix(let m) = values[0] {
            result.kind = "matrix"
            result.matrix = m.rows.map { row in row.map { $0.doubleValue } }
        } else {
            var numbers: [Double] = []
            for v in values {
                if case .scalar(let s) = v { numbers.append(s.doubleValue) }
            }
            result.value = numbers.first
            if values.count > 1 { result.values = numbers }
        }
        return result
    }

    static func answer(_ outcome: EquationOutcome, style: MathStyle) -> MathAnswer {
        switch outcome {
        case .check(let holds):
            let word = holds ? "True" : "False"
            return MathAnswer(kind: "check", answer: word, latex: "\\text{\(word)}", exact: true)
        case .noSolution:
            return MathAnswer(kind: "solutions", answer: "No solution", latex: "\\text{No solution}", exact: true,
                              solutions: [], message: "No value makes the equation true")
        case .infinitelyMany:
            return MathAnswer(kind: "solutions", answer: "Infinitely many solutions",
                              latex: "\\text{Infinitely many solutions}", exact: true, solutions: [],
                              message: "The equations don't fix one value for each unknown")
        case .identity(let names):
            let list = names.joined(separator: ", ")
            return MathAnswer(kind: "solutions", answer: "Every value of \(list)",
                              latex: "\\text{Every value of } " + names.map(latexName).joined(separator: ", "),
                              exact: true, solutions: [], message: "The equation is true for every value of \(list)")
        case .roots(let variable, let roots):
            let solutions = roots.map { solution(variable, $0, style) }
            let allExact = solutions.allSatisfy { $0.exact }
            let real = roots.filter { $0.isReal }
            let shown = real.isEmpty ? roots : real
            let name = latexName(variable)
            let text: String
            let latex: String
            if let pair = conjugatePair(shown, style) {
                text = "\(variable) = \(pair.text)"
                latex = "\(name) = \(pair.latex)"
            } else {
                let numbers = shown.map { root($0, style) }
                text = numbers.map { "\(variable) \($0.exact ? "=" : "≈") \($0.text)" }.joined(separator: ", ")
                latex = numbers.map { "\(name) \($0.exact ? "=" : "\\approx") \($0.latex)" }.joined(separator: ", ")
            }
            return MathAnswer(kind: "solutions", answer: text, latex: latex, exact: allExact,
                              value: real.count == 1 ? real[0].real : nil, solutions: solutions,
                              message: real.isEmpty ? "No real solutions" : nil)
        case .system(let values):
            var solutions: [MathAnswer.Solution] = []
            for v in values {
                let n = number(v.value, style)
                solutions.append(MathAnswer.Solution(variable: v.name, answer: n.text, latex: n.latex,
                                                     value: v.value.doubleValue, imaginary: nil, exact: n.exact))
            }
            let text = solutions.map { "\($0.variable) \($0.exact ? "=" : "≈") \($0.answer)" }.joined(separator: ", ")
            let latex = solutions.map { "\(latexName($0.variable)) \($0.exact ? "=" : "\\approx") \($0.latex)" }
                .joined(separator: ", ")
            let allExact = solutions.allSatisfy { $0.exact }
            return MathAnswer(kind: "solutions", answer: text, latex: latex, exact: allExact, solutions: solutions)
        }
    }

    private static func solution(_ variable: String, _ r: EquationRoot, _ style: MathStyle) -> MathAnswer.Solution {
        let n = root(r, style)
        return MathAnswer.Solution(variable: variable, answer: n.text, latex: n.latex, value: r.real,
                                   imaginary: r.isReal ? nil : r.imaginary, exact: n.exact)
    }

    /// Two quadratic roots p ± q√r shown once, with ±.
    private static func conjugatePair(_ roots: [EquationRoot], _ style: MathStyle) -> Number? {
        guard style.format != .decimal, roots.count == 2, case .surd(let a) = roots[0], case .surd(let b) = roots[1],
              a.p == b.p, a.r == b.r, a.imaginary == b.imaginary, a.q == b.q.negated else { return nil }
        return surd(a, plusMinus: true)
    }

    static func root(_ r: EquationRoot, _ style: MathStyle) -> Number {
        switch r {
        case .value(let s):
            return number(s, style)
        case .surd(let s):
            if style.format != .decimal, let n = surd(s, plusMinus: false) { return n }
            return complexDecimal(s.realPart, s.imaginaryPart)
        case .complex(let re, let im):
            return complexDecimal(re, im)
        }
    }

    private static func complexDecimal(_ re: Double, _ im: Double) -> Number {
        let realPart = decimal(re)
        if im == 0 { return realPart }
        let size = decimal(abs(im))
        let coefficient = size.latex == "1" ? "" : size.text
        let latexCoefficient = size.latex == "1" ? "" : size.latex
        let sign = im < 0 ? "\u{2212}" : "+"
        let latexSign = im < 0 ? "-" : "+"
        if re == 0 {
            return Number(text: (im < 0 ? sign : "") + coefficient + "i",
                          latex: (im < 0 ? latexSign : "") + latexCoefficient + "i", exact: false)
        }
        return Number(text: "\(realPart.text) \(sign) \(coefficient)i",
                      latex: "\(realPart.latex) \(latexSign) \(latexCoefficient)i", exact: false)
    }

    /// (a ± b√r)/l written out: "1 + √2", "(−1 ± √5)/2", "−1 ± 2i", "√3/2".
    static func surd(_ s: QuadraticSurd, plusMinus: Bool) -> Number? {
        let g = Rational.gcd(s.p.denominator, s.q.denominator)
        let (l, o1) = (s.p.denominator / g).multipliedReportingOverflow(by: s.q.denominator)
        guard !o1 else { return nil }
        let (a, o2) = s.p.numerator.multipliedReportingOverflow(by: l / s.p.denominator)
        let (b, o3) = s.q.numerator.multipliedReportingOverflow(by: l / s.q.denominator)
        guard !o2, !o3 else { return nil }
        let coefficient = abs(b) == 1 ? "" : String(abs(b))
        let term = coefficient + (s.imaginary ? "i" : "") + (s.r > 1 ? "\u{221A}\(s.r)" : "")
        let latexTerm = coefficient + (s.imaginary ? "i" : "") + (s.r > 1 ? "\\sqrt{\(s.r)}" : "")
        let numerator: String
        let latexNumerator: String
        if a == 0 {
            numerator = (plusMinus ? "\u{00B1}" : (b < 0 ? "\u{2212}" : "")) + term
            latexNumerator = (plusMinus ? "\\pm " : (b < 0 ? "-" : "")) + latexTerm
        } else {
            let sign = plusMinus ? "\u{00B1}" : (b < 0 ? "\u{2212}" : "+")
            let latexSign = plusMinus ? "\\pm" : (b < 0 ? "-" : "+")
            numerator = "\(minus(String(a))) \(sign) \(term)"
            latexNumerator = "\(a) \(latexSign) \(latexTerm)"
        }
        if l == 1 { return Number(text: numerator, latex: latexNumerator, exact: true) }
        return Number(text: a == 0 ? "\(numerator)/\(l)" : "(\(numerator))/\(l)",
                      latex: "\\frac{\(latexNumerator)}{\(l)}", exact: true)
    }

    /// x_1 → x_{1}, θ → \theta.
    static func latexName(_ name: String) -> String {
        var base = name
        var index: String? = nil
        if let underscore = name.firstIndex(of: "_") {
            base = String(name[..<underscore])
            index = String(name[name.index(after: underscore)...])
        }
        let command = greekCommands[base].map { "\\" + $0 } ?? base
        return index.map { "\(command)_{\($0)}" } ?? command
    }

    private static let greekCommands: [String: String] = {
        var out: [String: String] = ["π": "pi"]
        for (command, symbol) in MathLexer.greek {
            if let existing = out[symbol], existing.count <= command.count { continue }
            out[symbol] = command
        }
        return out
    }()
}

// MARK: - Command

struct MathEvaluate: NibCommand {
    struct Params: Codable {
        var expression: String
        var variables: [String: JSONValue]?
        var format: String?
    }
    typealias Output = MathAnswer

    private static let exampleVariables: JSONValue = ["a": 2, "f(x)": "x^2 + a"]
    private static let examples: [JSONValue] = [
        ["expression": "2(3+4)^2 ="],
        ["expression": "x^2 - 5x + 6 = 0", "format": "fraction"],
        ["expression": "f(3) =", "variables": exampleVariables],
    ]

    static let descriptor = CommandDescriptor(
        id: "math.evaluate", title: "Evaluate Maths",
        summary: "Work out an expression, equation or system on-device (earlier lines may define a = 2, f(x) = x^2); answer as a fraction, mixed number or decimal.",
        params: .obj([
            "expression": .str("maths as text or LaTeX, e.g. '2(3+4)^2 =', 'x^2 - 5x + 6 = 0', 'x + y = 3; x - y = 1', 'a = 2\\n3a ='"),
            "variables": .obj([:], required: [], "page definitions, name → number, expression or matrix rows, e.g. {\"a\": 2, \"f(x)\": \"x^2\", \"A\": [[1, 2], [3, 4]]}"),
            "format": .str("answer format; auto (default) gives fractions, or decimals when the input has decimals",
                           choices: MathAnswerFormat.allCases.map { $0.rawValue }),
        ], required: ["expression"]),
        examples: examples,
        effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> MathAnswer {
        var chosen = MathAnswerFormat.auto
        if let name = p.format {
            guard let parsed = MathAnswerFormat(rawValue: name) else {
                throw NibError(.invalidParams, "format must be one of: auto, fraction, mixed, decimal", path: "$.format")
            }
            chosen = parsed
        }
        var engine = MathEngine()
        try engine.define(variables: p.variables ?? [:])
        let prepared = engine
        let format = chosen
        let expression = p.expression
        do {
            // Integrals and long sums can take a moment: keep them off the main actor.
            return try await Task.detached(priority: .userInitiated) {
                try prepared.evaluate(expression, format: format)
            }.value
        } catch let error as NibError where error.code == .unsupported {
            var e = error
            e.hint = "try AI Solve: call math.solve {latex: '\(expression.prefix(300))', mode: 'solve'}"
            throw e
        }
    }
}
