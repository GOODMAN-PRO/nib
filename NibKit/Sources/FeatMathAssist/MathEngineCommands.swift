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

    /// `definitions` are the page's so far: with f already defined, "f(x) = 7" asks when f is 7 (an equation),
    /// while "f(x) = x^3", whose right-hand side uses the parameter, redefines f.
    init(_ statement: MathStatement, definitions: MathDefinitions = MathDefinitions()) {
        guard let rhs = statement.rhs else {
            self = .question(statement.lhs)
            return
        }
        if statement.plusMinusCount == 0 {
            if case .variable(let name) = statement.lhs, name != "π", !rhs.mentions(name) {
                self = .variable(name, rhs)
                return
            }
            if case .call(let name, let args, 0) = statement.lhs, let parameters = MathStatementRole.parameters(args),
               definitions.functions[name] == nil || parameters.contains(where: rhs.mentions) {
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
    /// equations) and lines that don't parse are skipped, as a page is full of those. Parsed on `MathStack`.
    init(context lines: [String]) {
        let parsed = try? MathStack.run { () -> MathDefinitions in
            var page = MathEngine()
            for line in lines {
                guard let statements = try? MathParser.statements(line) else { continue }
                for statement in statements { page.define(statement) }
            }
            return page.definitions
        }
        definitions = parsed ?? MathDefinitions()
    }

    /// Records a definition (replacing an earlier one of the same name); false when the statement isn't one.
    @discardableResult
    mutating func define(_ statement: MathStatement) -> Bool {
        define(MathStatementRole(statement, definitions: definitions))
    }

    @discardableResult
    private mutating func define(_ role: MathStatementRole) -> Bool {
        switch role {
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
    /// Parsed on `MathStack`.
    mutating func define(variables: [String: JSONValue]) throws {
        let start = self
        definitions = try MathStack.run { () -> MathDefinitions in
            var page = start
            try page.defineHere(variables: variables)
            return page.definitions
        }
    }

    private mutating func defineHere(variables: [String: JSONValue]) throws {
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
    /// definitions and equations: the equations are solved together for their unknowns. Runs on an 8 MB stack
    /// (`MathStack`, blocking the caller); `cancellation` stops it early with a CancellationError.
    func evaluate(_ source: String, format: MathAnswerFormat = .auto,
                  cancellation: MathCancellation? = nil) throws -> MathAnswer {
        let engine = self
        return try MathStack.run { try engine.work(source, format: format, cancellation: cancellation) }
    }

    /// Decimals (0.5, 1.5e-3) in the input: `auto` answers in decimals.
    static func hasDecimals(_ source: String) -> Bool {
        source.range(of: "\\.[0-9]|[0-9][eE][-+]?[0-9]", options: .regularExpression) != nil
    }

    private func work(_ source: String, format: MathAnswerFormat, cancellation: MathCancellation?) throws -> MathAnswer {
        let statements = try MathParser.statements(source)
        guard let last = statements.last else { throw MathFailure.syntax("There's nothing to work out") }
        let style = MathStyle(format: format, preferDecimal: MathEngine.hasDecimals(source))
        var page = self
        if case .question(let node) = MathStatementRole(last) {
            for index in 0..<(statements.count - 1) {
                guard page.define(statements[index]) else {
                    throw MathFailure.syntax("Line \(index + 1) isn't a definition: only lines like 'a = 2' or 'f(x) = x^2' can come before the one to work out")
                }
            }
            return try page.answer(question: node, plusMinusCount: last.plusMinusCount, style: style,
                                   cancellation: cancellation)
        }

        // Every line is a definition or an equation. Functions are defined as they come; variables are gathered
        // first, as "the latest definition wins" is for page values, not for the equations of one system.
        var equations: [MathEquation] = []
        var assignments: [String: [(index: Int, value: MathNode)]] = [:]
        var lastRole = MathStatementRole(last)
        for (index, statement) in statements.enumerated() {
            let role = MathStatementRole(statement, definitions: page.definitions)
            lastRole = role
            switch role {
            case .question:
                throw MathFailure.syntax("Only the last line can be an expression to work out (line \(index + 1) has no '=')")
            case .variable(let name, let value):
                assignments[name, default: []].append((index, value))
            case .function:
                page.define(role)
            case .equation(let lhs, let rhs):
                equations.append(MathEquation(lhs: lhs, rhs: rhs, plusMinusCount: statement.plusMinusCount))
            }
        }
        // A name given several values keeps the latest only when every value is a plain value given the other lines
        // (a = 2, a = 5). Otherwise each is an equation: y = 2x + 1 and y = 3 − x meet at x = 2/3.
        var repeatedAsEquations = Set<String>()
        var changed = true
        while changed {
            changed = false
            var probe = page
            for (name, values) in assignments where !repeatedAsEquations.contains(name) {
                probe.definitions.variables[name] = values[values.count - 1].value
                probe.definitions.functions[name] = nil
            }
            for name in assignments.keys.sorted() where !repeatedAsEquations.contains(name) {
                guard let values = assignments[name], values.count > 1 else { continue }
                var others = probe
                others.definitions.variables[name] = nil
                if values.contains(where: { !others.definitions.freeNames($0.value).isEmpty }) {
                    repeatedAsEquations.insert(name)
                    changed = true
                }
            }
        }
        var latest: [String: Int] = [:]
        for name in assignments.keys.sorted() {
            guard let values = assignments[name], let newest = values.last else { continue }
            if repeatedAsEquations.contains(name) {
                for v in values { equations.append(MathEquation(lhs: .variable(name), rhs: v.value, plusMinusCount: 0)) }
            } else {
                page.definitions.variables[name] = newest.value
                page.definitions.functions[name] = nil
                latest[name] = newest.index
            }
        }
        // A definition that needs an unknown (x = 2y next to x + y = 3), or that leads back to itself (y = 2x + 1
        // next to x = 1 − y), is one of the equations after all.
        var demoted: [String] = []
        let defined = latest.sorted(by: { $0.value < $1.value }).map { $0.key }
        let unresolved = page.definitions.unresolvedVariables(among: defined)
        for name in defined where unresolved.contains(name) {
            guard let node = page.definitions.variables[name] else { continue }
            equations.append(MathEquation(lhs: .variable(name), rhs: node, plusMinusCount: 0))
            demoted.append(name)
        }
        for name in demoted { page.definitions.variables[name] = nil }
        if equations.isEmpty { return try page.answerDefinition(lastRole, style: style, cancellation: cancellation) }
        if equations.count == 1, let name = demoted.first {
            // "y = 2x + 1" on its own defines y; it isn't an equation to solve.
            let others = page.definitions.freeNames(equations[0].rhs).subtracting([name]).sorted()
            return MathAnswer(kind: "definition", answer: name, latex: MathFormatter.latexName(name), exact: true,
                              message: "Defines \(name) in terms of \(others.joined(separator: ", "))")
        }
        let outcome = try EquationSolver.solve(equations, definitions: page.definitions, cancellation: cancellation)
        return MathFormatter.answer(outcome, style: style)
    }

    /// Nested evaluation allowed in graph samples, which run on the caller's thread (possibly a 512 KB one): an
    /// unoptimised build spends about 3.5 KB of stack per level, so 80 levels stay under 300 KB.
    static let samplerNestingLimit = 80

    /// y = f(x) as a function of x for graphs: "x^2", "y = x^2" or "f(x) = x^2", with the page's definitions. Returns
    /// nil where the function is undefined (√x for x < 0, 1/x at 0). The closure may be called from any thread,
    /// several at once: each call works with its own evaluator.
    func function(_ source: String, of variable: String = "x") throws -> (Double) -> Double? {
        let statements = try MathStack.run { try MathParser.statements(source) }
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
        let definitions = self.definitions
        return { x in
            let evaluator = MathEvaluator(definitions: definitions, nestingLimit: MathEngine.samplerNestingLimit)
            guard let y = try? evaluator.sample(body, variable: variable, at: x), y.isFinite else { return nil }
            return y
        }
    }

    private func answer(question node: MathNode, plusMinusCount: Int, style: MathStyle,
                        cancellation: MathCancellation?) throws -> MathAnswer {
        let evaluator = MathEvaluator(definitions: definitions, cancellation: cancellation)
        var values: [MathValue] = []
        for signs in try EquationSolver.signCombinations(plusMinusCount) {
            let v = try evaluator.evaluate(node, signs: signs)
            if !values.contains(where: { MathValue.nearlyEqual($0, v) }) { values.append(v) }
        }
        return MathFormatter.answer(values: values, style: style, approximate: evaluator.approximate)
    }

    private func answerDefinition(_ role: MathStatementRole, style: MathStyle,
                                  cancellation: MathCancellation?) throws -> MathAnswer {
        switch role {
        case .variable(let name, _):
            let evaluator = MathEvaluator(definitions: definitions, cancellation: cancellation)
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

// MARK: - Stack

/// Runs the engine on a thread with an 8 MB stack. Every pass over a syntax tree recurses (parser, evaluator, the
/// equation reader); their limits (`MathParser.maxDepth`, `MathEvaluator.maxNesting`, the reader's) are sized for
/// this stack, not for the 512 KB of a dispatch or cooperative-pool thread.
enum MathStack {
    static let size = 8 << 20
    private static let marker = "nib.mathassist.largeStack"

    /// True on a thread this type started.
    static var isCurrent: Bool { Thread.current.threadDictionary[marker] != nil }

    /// Blocks the calling thread until `work` has run on a large stack; runs it in place when already on one.
    static func run<T>(_ work: @escaping () throws -> T) throws -> T {
        if isCurrent { return try work() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        start(qualityOfService: Thread.current.qualityOfService) {
            box.result = Result { try work() }
            done.signal()
        }
        done.wait()
        guard let result = box.result else { throw NibError(.internalError, "The maths engine stopped unexpectedly") }
        return try result.get()
    }

    /// Suspends the caller (freeing its actor, e.g. the main actor) while `work` runs on a large stack.
    static func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            start(qualityOfService: .userInitiated) { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func start(qualityOfService: QualityOfService, _ body: @escaping () -> Void) {
        let job = Job(body)   // handed to exactly one thread, which runs it once
        let thread = Thread {
            Thread.current.threadDictionary[marker] = true
            job.body()
        }
        thread.stackSize = size
        thread.qualityOfService = qualityOfService
        thread.name = "Nib maths engine"
        thread.start()
    }

    private final class ResultBox<T> {
        var result: Result<T, Error>?
    }

    private final class Job: @unchecked Sendable {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
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

    /// Input sizes (characters) and counts accepted from callers; longer input is refused before it is parsed.
    static let maxExpressionLength = 4_000
    static let maxVariableLength = 2_000
    static let maxVariableNameLength = 64
    static let maxVariables = 500

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> MathAnswer {
        var chosen = MathAnswerFormat.auto
        if let name = p.format {
            guard let parsed = MathAnswerFormat(rawValue: name) else {
                throw NibError(.invalidParams, "format must be one of: auto, fraction, mixed, decimal", path: "$.format")
            }
            chosen = parsed
        }
        guard p.expression.count <= maxExpressionLength else {
            throw NibError(.invalidParams, "expression is too long: at most \(maxExpressionLength) characters",
                           path: "$.expression")
        }
        let variables = p.variables ?? [:]
        guard variables.count <= maxVariables else {
            throw NibError(.invalidParams, "variables: at most \(maxVariables) definitions", path: "$.variables")
        }
        for (name, value) in variables {
            guard name.count <= maxVariableNameLength else {
                throw NibError(.invalidParams, "variables: a name is longer than \(maxVariableNameLength) characters",
                               path: "$.variables")
            }
            guard value.jsonString().count <= maxVariableLength else {
                throw NibError(.invalidParams, "variables.\(name) is too long: at most \(maxVariableLength) characters",
                               path: "$.variables.\(name)")
            }
        }
        let format = chosen
        let expression = p.expression
        let cancellation = MathCancellation()
        do {
            // On an 8 MB stack (every pass over the tree recurses), off the main actor; cancelling the caller's task
            // stops the work at its next budget check.
            return try await withTaskCancellationHandler {
                try await MathStack.perform {
                    var engine = MathEngine()
                    try engine.define(variables: variables)
                    return try engine.evaluate(expression, format: format, cancellation: cancellation)
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch let error as NibError where error.code == .unsupported {
            var e = error
            e.hint = MathFailure.aiSolveHint(for: String(expression.prefix(300)))
            throw e
        }
    }
}
