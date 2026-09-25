import Foundation
import NibContracts

// The on-device maths engine (F061), part 3: equations. Each equation becomes a fraction of polynomials in its unknowns.
// One unknown up to degree 4 is solved (linear and quadratic exactly, cubic and quartic numerically, with rational
// roots recognised exactly); several unknowns are solved as a linear system by Gauss–Jordan elimination. Anything else
// (sin x = ½, x² + y² = 1 with a line, degree 5) is `unsupported`, pointing to AI Solve.

// MARK: - Polynomials

/// A polynomial in the unknowns: exponent of each unknown → coefficient (zero coefficients are never stored).
struct Polynomial: Equatable {
    private(set) var terms: [[Int]: Scalar]
    let variableCount: Int

    init(variableCount: Int, terms: [[Int]: Scalar] = [:]) {
        self.variableCount = variableCount
        self.terms = terms.filter { !$0.value.isZero }
    }

    static func constant(_ c: Scalar, variableCount n: Int) -> Polynomial {
        Polynomial(variableCount: n, terms: [Array(repeating: 0, count: n): c])
    }

    static func unknown(_ index: Int, variableCount n: Int) -> Polynomial {
        var exponents = Array(repeating: 0, count: n)
        exponents[index] = 1
        return Polynomial(variableCount: n, terms: [exponents: .one])
    }

    var isZero: Bool { terms.isEmpty }

    /// The value when the polynomial has no unknowns.
    var constantValue: Scalar? {
        guard let first = terms.first else { return .zero }
        guard terms.count == 1, first.key.allSatisfy({ $0 == 0 }) else { return nil }
        return first.value
    }

    var totalDegree: Int { terms.keys.map { $0.reduce(0, +) }.max() ?? 0 }

    func adding(_ o: Polynomial) -> Polynomial {
        var t = terms
        for (e, c) in o.terms { t[e] = (t[e] ?? .zero) + c }
        return Polynomial(variableCount: variableCount, terms: t)
    }

    var negated: Polynomial { Polynomial(variableCount: variableCount, terms: terms.mapValues { -$0 }) }

    func scaled(_ c: Scalar) -> Polynomial { Polynomial(variableCount: variableCount, terms: terms.mapValues { $0 * c }) }

    func multiplied(_ o: Polynomial) -> Polynomial {
        var t: [[Int]: Scalar] = [:]
        for (e1, c1) in terms {
            for (e2, c2) in o.terms {
                var e = e1
                for i in 0..<e.count { e[i] += e2[i] }
                t[e] = (t[e] ?? .zero) + c1 * c2
            }
        }
        return Polynomial(variableCount: variableCount, terms: t)
    }

    func power(_ n: Int) -> Polynomial {
        var result = Polynomial.constant(.one, variableCount: variableCount)
        for _ in 0..<max(0, n) { result = result.multiplied(self) }
        return result
    }

    /// Coefficients of a one-unknown polynomial, constant term first.
    var univariateCoefficients: [Scalar] {
        var c = Array(repeating: Scalar.zero, count: totalDegree + 1)
        for (e, value) in terms { c[e.reduce(0, +)] = value }
        return c
    }

    /// Coefficient of each unknown and the constant term, for a polynomial of degree ≤ 1.
    var linearParts: (coefficients: [Scalar], constant: Scalar) {
        var coefficients = Array(repeating: Scalar.zero, count: variableCount)
        var constant = Scalar.zero
        for (e, c) in terms {
            if let i = e.firstIndex(of: 1) {
                coefficients[i] = c
            } else {
                constant = c
            }
        }
        return (coefficients, constant)
    }

    func value(at point: [Double]) -> Double {
        var total = 0.0
        for (e, c) in terms {
            var term = c.doubleValue
            for i in 0..<e.count where e[i] > 0 { term *= pow(point[i], Double(e[i])) }
            total += term
        }
        return total
    }
}

/// numerator / denominator, so equations such as 1/x + 1 = 3 can be cleared of fractions.
struct RationalExpression {
    var numerator: Polynomial
    var denominator: Polynomial

    static func polynomial(_ p: Polynomial) -> RationalExpression {
        RationalExpression(numerator: p, denominator: .constant(.one, variableCount: p.variableCount))
    }

    /// A constant denominator is folded into the numerator, so polynomials stay polynomials.
    func normalized() -> RationalExpression {
        guard let c = denominator.constantValue, let inverse = try? Scalar.one.divided(by: c) else { return self }
        return .polynomial(numerator.scaled(inverse))
    }

    func adding(_ o: RationalExpression) -> RationalExpression {
        if denominator == o.denominator {
            return RationalExpression(numerator: numerator.adding(o.numerator), denominator: denominator)
        }
        return RationalExpression(numerator: numerator.multiplied(o.denominator).adding(o.numerator.multiplied(denominator)),
                                  denominator: denominator.multiplied(o.denominator)).normalized()
    }

    var negated: RationalExpression { RationalExpression(numerator: numerator.negated, denominator: denominator) }

    func multiplied(_ o: RationalExpression) -> RationalExpression {
        RationalExpression(numerator: numerator.multiplied(o.numerator),
                           denominator: denominator.multiplied(o.denominator)).normalized()
    }

    func reciprocal() throws -> RationalExpression {
        guard !numerator.isZero else { throw MathFailure.math("Division by zero") }
        return RationalExpression(numerator: denominator, denominator: numerator).normalized()
    }

    func power(_ n: Int) throws -> RationalExpression {
        if n < 0 { return try reciprocal().power(-n) }
        return RationalExpression(numerator: numerator.power(n), denominator: denominator.power(n)).normalized()
    }
}

// MARK: - Reading an equation as polynomials

/// Turns one side of an equation into a `RationalExpression` in `unknowns`. Parts without unknowns are evaluated
/// numerically; page variables and functions that involve the unknowns are expanded (f(x) = 2x + 1; f(x) = 7).
struct SymbolicReader {
    let unknowns: [String]
    let definitions: MathDefinitions
    let evaluator: MathEvaluator
    let signs: [Int: Bool]
    /// Parameters of a page function being expanded, bound to the (symbolic) arguments.
    var bindings: [String: RationalExpression] = [:]
    var depth = 0

    init(unknowns: [String], definitions: MathDefinitions, evaluator: MathEvaluator, signs: [Int: Bool]) {
        self.unknowns = unknowns
        self.definitions = definitions
        self.evaluator = evaluator
        self.signs = signs
    }

    func read(_ node: MathNode) throws -> RationalExpression {
        if isConstant(node) { return try constant(node) }
        guard depth < 64 else { throw MathFailure.math("A definition refers to itself") }
        switch node {
        case .variable(let name):
            if let bound = bindings[name] { return bound }
            if let i = unknowns.firstIndex(of: name) {
                return .polynomial(.unknown(i, variableCount: unknowns.count))
            }
            if let definition = definitions.variables[name] {
                var inner = self
                inner.bindings = [:]
                inner.depth += 1
                return try inner.read(definition)
            }
            throw MathFailure.undefined(name)
        case .negate(let inner):
            return try read(inner).negated
        case .binary(let op, let lhs, let rhs):
            let a = try read(lhs)
            switch op {
            case .add:
                return try a.adding(read(rhs))
            case .subtract:
                return try a.adding(read(rhs).negated)
            case .plusMinus(let k):
                let b = try read(rhs)
                return a.adding(signs[k] == true ? b.negated : b)
            case .multiply:
                return try a.multiplied(read(rhs))
            case .divide:
                return try a.multiplied(read(rhs).reciprocal())
            case .power:
                guard isConstant(rhs) else { throw MathFailure.unsupported("equations with the unknown in an exponent") }
                guard case .scalar(let e) = try evaluator.evaluate(rhs, signs: signs), let n = e.integerValue,
                      abs(n) <= 24 else {
                    throw MathFailure.unsupported("equations with fractional powers or roots of the unknown")
                }
                return try a.power(n)
            }
        case .postfix(.percent, let inner):
            return try read(inner).multiplied(constantExpression(Scalar.one.divided(by: Scalar(100))))
        case .postfix(.degrees, let inner):
            return try read(inner).multiplied(constantExpression(.real(Double.pi / 180)))
        case .postfix(.factorial, _):
            throw MathFailure.unsupported("equations with factorials of the unknown")
        case .call(let name, let args, let primes):
            guard primes == 0 else { throw MathFailure.unsupported("equations with derivatives of the unknown") }
            guard let fn = definitions.functions[name] else {
                if args.count == 1, definitions.variables[name] != nil {
                    return try read(.binary(.multiply, .variable(name), args[0]))
                }
                throw MathFailure.undefinedFunction(name)
            }
            guard fn.parameters.count == args.count else {
                throw MathFailure.math("\(name) takes \(fn.parameters.count) argument\(fn.parameters.count == 1 ? "" : "s")")
            }
            var inner = self
            inner.bindings = [:]
            for (i, parameter) in fn.parameters.enumerated() { inner.bindings[parameter] = try read(args[i]) }
            inner.depth += 1
            return try inner.read(fn.body)
        case .function(let f, _):
            throw MathFailure.unsupported(SymbolicReader.describe(f))
        case .matrix:
            throw MathFailure.unsupported("matrix equations")
        case .number, .bigOperator, .integral, .derivative:
            throw MathFailure.unsupported("equations with sums, integrals or derivatives of the unknown")
        }
    }

    private func isConstant(_ node: MathNode) -> Bool {
        let symbolic = Set(bindings.keys)
        return definitions.freeNames(node, symbolic: symbolic).isDisjoint(with: symbolic.union(unknowns))
    }

    private func constant(_ node: MathNode) throws -> RationalExpression {
        guard case .scalar(let s) = try evaluator.evaluate(node, signs: signs) else {
            throw MathFailure.unsupported("matrix equations")
        }
        return constantExpression(s)
    }

    private func constantExpression(_ s: Scalar) -> RationalExpression {
        .polynomial(.constant(s, variableCount: unknowns.count))
    }

    static func describe(_ f: MathFunction) -> String {
        switch f {
        case .sin, .cos, .tan, .asin, .acos, .atan: return "trigonometric equations"
        case .ln, .log, .logBase, .exp: return "exponential and logarithmic equations"
        case .sqrt, .root: return "equations with roots of the unknown"
        case .abs: return "equations with absolute values of the unknown"
        case .det, .inv: return "matrix equations"
        }
    }
}

// MARK: - Results

/// p + q·√r (r squarefree), or p + q·i·√r when `imaginary` (r may then be 1): an exact root of a quadratic.
struct QuadraticSurd: Equatable {
    var p: Rational
    var q: Rational
    var r: Int
    var imaginary: Bool

    var realPart: Double { imaginary ? p.doubleValue : p.doubleValue + q.doubleValue * Double(r).squareRoot() }
    var imaginaryPart: Double { imaginary ? q.doubleValue * Double(r).squareRoot() : 0 }
}

enum EquationRoot: Equatable {
    /// An exact fraction, or a Double from a numeric method.
    case value(Scalar)
    case surd(QuadraticSurd)
    /// A numeric complex root: real part, imaginary part.
    case complex(Double, Double)

    var real: Double {
        switch self {
        case .value(let s): return s.doubleValue
        case .surd(let s): return s.realPart
        case .complex(let re, _): return re
        }
    }

    var imaginary: Double {
        switch self {
        case .value: return 0
        case .surd(let s): return s.imaginaryPart
        case .complex(_, let im): return im
        }
    }

    var isReal: Bool { imaginary == 0 }

    func isClose(to o: EquationRoot, tolerance: Double = 1e-9) -> Bool {
        abs(real - o.real) <= tolerance * max(1, abs(real)) && abs(imaginary - o.imaginary) <= tolerance * max(1, abs(imaginary))
    }

    /// Real roots first, in increasing order; then complex ones, positive imaginary part first.
    static func ascending(_ a: EquationRoot, _ b: EquationRoot) -> Bool {
        if a.isReal != b.isReal { return a.isReal }
        if a.real != b.real { return a.real < b.real }
        return a.imaginary > b.imaginary
    }
}

struct SolvedValue {
    var name: String
    var value: Scalar
}

struct MathEquation {
    var lhs: MathNode
    var rhs: MathNode
    /// The statement's ± count: each combination of signs is solved.
    var plusMinusCount: Int
}

enum EquationOutcome {
    /// One unknown: every root (real and complex).
    case roots(variable: String, roots: [EquationRoot])
    /// A linear system with one solution.
    case system([SolvedValue])
    /// True for every value of the unknowns.
    case identity([String])
    case noSolution
    case infinitelyMany
    /// No unknowns: whether the equation holds.
    case check(Bool)
}

// MARK: - Solving

enum EquationSolver {
    static func solve(_ equations: [MathEquation], definitions: MathDefinitions) throws -> EquationOutcome {
        var names = Set<String>()
        for e in equations {
            names.formUnion(definitions.freeNames(e.lhs))
            names.formUnion(definitions.freeNames(e.rhs))
        }
        let unknowns = names.sorted()
        let evaluator = MathEvaluator(definitions: definitions)
        if unknowns.isEmpty { return .check(try holds(equations, evaluator)) }
        if unknowns.count == 1, equations.count == 1 {
            return try solveOne(equations[0], variable: unknowns[0], definitions: definitions, evaluator: evaluator)
        }
        if equations.contains(where: { $0.plusMinusCount > 0 }) {
            throw MathFailure.unsupported("± in systems or in equations with several unknowns")
        }
        return try solveLinear(equations, unknowns: unknowns, definitions: definitions, evaluator: evaluator)
    }

    /// Every choice of + or − for `count` ± signs (at most 4 of them).
    static func signCombinations(_ count: Int) throws -> [[Int: Bool]] {
        guard count <= 4 else { throw MathFailure.unsupported("more than four ± signs") }
        var result: [[Int: Bool]] = []
        for mask in 0..<(1 << count) {
            var signs: [Int: Bool] = [:]
            for k in 0..<count { signs[k] = mask & (1 << k) != 0 }
            result.append(signs)
        }
        return result
    }

    private static func holds(_ equations: [MathEquation], _ evaluator: MathEvaluator) throws -> Bool {
        for e in equations {
            var any = false
            for signs in try signCombinations(e.plusMinusCount) {
                let a = try evaluator.evaluate(e.lhs, signs: signs)
                let b = try evaluator.evaluate(e.rhs, signs: signs)
                if MathValue.nearlyEqual(a, b) {
                    any = true
                    break
                }
            }
            if !any { return false }
        }
        return true
    }

    private static func solveOne(_ equation: MathEquation, variable: String, definitions: MathDefinitions,
                                 evaluator: MathEvaluator) throws -> EquationOutcome {
        var roots: [EquationRoot] = []
        for signs in try signCombinations(equation.plusMinusCount) {
            let reader = SymbolicReader(unknowns: [variable], definitions: definitions, evaluator: evaluator, signs: signs)
            let difference = try reader.read(equation.lhs).adding(reader.read(equation.rhs).negated)
            switch try polynomialRoots(difference.numerator.univariateCoefficients) {
            case .identity:
                return .identity([variable])
            case .roots(let found):
                for root in found where !roots.contains(where: { $0.isClose(to: root) }) {
                    // A root of the numerator that zeroes the denominator isn't a solution (x/x = 0).
                    if root.isReal, abs(difference.denominator.value(at: [root.real])) < 1e-12 { continue }
                    roots.append(root)
                }
            }
        }
        if roots.isEmpty { return .noSolution }
        return .roots(variable: variable, roots: roots.sorted(by: EquationRoot.ascending))
    }

    enum PolynomialSolution {
        case identity
        /// Empty when there is no solution.
        case roots([EquationRoot])
    }

    /// Roots of c₀ + c₁x + … (constant first).
    static func polynomialRoots(_ coefficients: [Scalar]) throws -> PolynomialSolution {
        var c = coefficients
        let scale = c.map { abs($0.doubleValue) }.max() ?? 0
        while let last = c.last, last.isNegligible(scale: scale) { c.removeLast() }
        if c.isEmpty { return .identity }
        var roots: [EquationRoot] = []
        if c.count > 1, c[0].isNegligible(scale: scale) {
            roots.append(.value(.zero))   // x = 0, then solve what is left after dividing by x
            while c.count > 1, c[0].isNegligible(scale: scale) { c.removeFirst() }
        }
        switch c.count - 1 {
        case 0:
            break
        case 1:
            roots.append(.value(try (-c[0]).divided(by: c[1])))
        case 2:
            roots += quadraticRoots(c[0], c[1], c[2])
        case 3, 4:
            roots += numericRoots(c)
        default:
            throw MathFailure.unsupported("equations of degree \(c.count - 1)")
        }
        return .roots(roots)
    }

    /// a·x² + b·x + c = 0, exactly when the coefficients are fractions.
    static func quadraticRoots(_ c: Scalar, _ b: Scalar, _ a: Scalar) -> [EquationRoot] {
        if let ra = a.rational, let rb = b.rational, let rc = c.rational, let exact = exactQuadratic(ra, rb, rc) {
            return exact
        }
        let x = a.doubleValue
        let y = b.doubleValue
        let z = c.doubleValue
        let d = y * y - 4 * x * z
        if abs(d) <= 1e-12 * max(y * y, abs(4 * x * z)) { return [.value(.real(-y / (2 * x)))] }
        if d > 0 {
            // The numerically stable pair: q = −(b + sign(b)·√D)/2, x₁ = q/a, x₂ = c/q.
            let sign: Double = y < 0 ? -1 : 1
            let q = -(y + sign * d.squareRoot()) / 2
            return [.value(.real(q / x)), .value(.real(z / q))]
        }
        let re = -y / (2 * x)
        let im = (-d).squareRoot() / (2 * abs(x))
        return [.complex(re, im), .complex(re, -im)]
    }

    /// Nil when a step overflows 64 bits (the caller then uses Doubles).
    private static func exactQuadratic(_ a: Rational, _ b: Rational, _ c: Rational) -> [EquationRoot]? {
        guard let b2 = b.multiplying(b), let ac = a.multiplying(c), let ac4 = ac.multiplying(Rational(integer: 4)),
              let discriminant = b2.adding(ac4.negated), let twoA = a.multiplying(Rational(integer: 2)),
              let inverse = twoA.reciprocal, let p = b.negated.multiplying(inverse) else { return nil }
        if discriminant.numerator == 0 { return [.value(.exact(p))] }
        // √D = √(num·den)/den = k·√m/den with m squarefree.
        let (s, overflow) = abs(discriminant.numerator).multipliedReportingOverflow(by: discriminant.denominator)
        guard !overflow, s <= 1_000_000_000_000 else { return nil }
        let (k, m) = squareFactor(s)
        guard let root = Rational(k, discriminant.denominator), let scaled = root.multiplying(inverse) else { return nil }
        let q = scaled.numerator < 0 ? scaled.negated : scaled
        if discriminant.numerator > 0 && m == 1 {
            guard let x1 = p.adding(q), let x2 = p.adding(q.negated) else { return nil }
            return [.value(.exact(x1)), .value(.exact(x2))]
        }
        let imaginary = discriminant.numerator < 0
        return [.surd(QuadraticSurd(p: p, q: q, r: m, imaginary: imaginary)),
                .surd(QuadraticSurd(p: p, q: q.negated, r: m, imaginary: imaginary))]
    }

    /// s = k²·m with m squarefree (trial division; s ≤ 10¹²).
    static func squareFactor(_ s: Int) -> (k: Int, m: Int) {
        var k = 1
        var m = 1
        var rest = s
        var f = 2
        while f * f <= rest {
            var count = 0
            while rest % f == 0 {
                rest /= f
                count += 1
            }
            for _ in 0..<(count / 2) { k *= f }
            if count % 2 == 1 { m *= f }
            f += f == 2 ? 1 : 2
        }
        return (k, m * rest)
    }

    /// Cubic and quartic roots by Durand–Kerner, real ones polished with Newton's method and recognised as fractions
    /// when a fraction satisfies the equation exactly.
    static func numericRoots(_ coefficients: [Scalar]) -> [EquationRoot] {
        let c = coefficients.map { $0.doubleValue }
        let n = c.count - 1
        let monic = c.map { $0 / c[n] }
        var bound = 0.0
        for k in 0..<n { bound = max(bound, abs(monic[k])) }
        let radius = 1 + bound
        var z: [ComplexNumber] = []
        for k in 0..<n {
            let angle = 2 * Double.pi * Double(k) / Double(n) + 0.4
            z.append(ComplexNumber(radius * cos(angle), radius * sin(angle)))
        }
        for _ in 0..<2000 {
            var largest = 0.0
            for i in 0..<n {
                var value = ComplexNumber(1, 0)
                for k in stride(from: n - 1, through: 0, by: -1) { value = value * z[i] + ComplexNumber(monic[k], 0) }
                var product = ComplexNumber(1, 0)
                for j in 0..<n where j != i { product = product * (z[i] - z[j]) }
                guard product.magnitude > 0 else { continue }
                let step = value / product
                z[i] = z[i] - step
                largest = max(largest, step.magnitude / (1 + z[i].magnitude))
            }
            if largest < 1e-15 { break }
        }
        var roots: [EquationRoot] = []
        for root in z {
            if abs(root.im) <= 1e-7 * (1 + abs(root.re)) {
                let x = polish(c, root.re)
                if let exact = exactRoot(coefficients, near: x) {
                    roots.append(.value(.exact(exact)))
                } else {
                    roots.append(.value(.real(x)))
                }
            } else {
                roots.append(.complex(root.re, root.im))
            }
        }
        // A repeated root comes back once per multiplicity, a little apart.
        var unique: [EquationRoot] = []
        for r in roots where !unique.contains(where: { $0.isClose(to: r, tolerance: 1e-6) }) { unique.append(r) }
        return unique
    }

    private static func evaluate(_ c: [Double], _ x: Double) -> Double {
        var value = 0.0
        for k in stride(from: c.count - 1, through: 0, by: -1) { value = value * x + c[k] }
        return value
    }

    private static func polish(_ c: [Double], _ start: Double) -> Double {
        var x = start
        var fx = evaluate(c, x)
        for _ in 0..<8 {
            var slope = 0.0
            for k in stride(from: c.count - 1, through: 1, by: -1) { slope = slope * x + Double(k) * c[k] }
            guard slope != 0 else { break }
            let next = x - fx / slope
            let fNext = evaluate(c, next)
            guard abs(fNext) < abs(fx) else { break }
            x = next
            fx = fNext
        }
        return x
    }

    private static func exactRoot(_ coefficients: [Scalar], near x: Double) -> Rational? {
        guard let candidate = Rational.approximating(x, maxDenominator: 1000, tolerance: 1e-6 * (1 + abs(x))) else {
            return nil
        }
        var value = Rational.zero
        for c in coefficients.reversed() {
            guard let r = c.rational, let product = value.multiplying(candidate), let sum = product.adding(r) else {
                return nil
            }
            value = sum
        }
        return value.numerator == 0 ? candidate : nil
    }

    private static func solveLinear(_ equations: [MathEquation], unknowns: [String], definitions: MathDefinitions,
                                    evaluator: MathEvaluator) throws -> EquationOutcome {
        let reader = SymbolicReader(unknowns: unknowns, definitions: definitions, evaluator: evaluator, signs: [:])
        var rows: [[Scalar]] = []
        var denominators: [Polynomial] = []
        for e in equations {
            let difference = try reader.read(e.lhs).adding(reader.read(e.rhs).negated)
            guard difference.numerator.totalDegree <= 1 else {
                throw MathFailure.unsupported(equations.count == 1 ? "non-linear equations in several unknowns"
                                                                   : "non-linear systems of equations")
            }
            let parts = difference.numerator.linearParts
            rows.append(parts.coefficients + [-parts.constant])
            denominators.append(difference.denominator)
        }
        let n = unknowns.count
        let reduced = try Matrix.rowReduce(rows, columns: n)
        var scale = 0.0
        for row in rows {
            for x in row { scale = max(scale, abs(x.doubleValue)) }
        }
        for i in reduced.pivots.count..<reduced.rows.count where !reduced.rows[i][n].isNegligible(scale: scale) {
            return .noSolution
        }
        guard reduced.pivots.count == n else { return .infinitelyMany }
        var values: [SolvedValue] = []
        for (row, column) in reduced.pivots.enumerated() {
            values.append(SolvedValue(name: unknowns[column], value: reduced.rows[row][n]))
        }
        let point = values.map { $0.value.doubleValue }
        for d in denominators where abs(d.value(at: point)) < 1e-12 { return .noSolution }
        return .system(values)
    }
}

private struct ComplexNumber {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double) {
        self.re = re
        self.im = im
    }

    var magnitude: Double { (re * re + im * im).squareRoot() }

    static func + (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber { ComplexNumber(a.re + b.re, a.im + b.im) }
    static func - (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber { ComplexNumber(a.re - b.re, a.im - b.im) }

    static func * (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber {
        ComplexNumber(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }

    static func / (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber {
        let d = b.re * b.re + b.im * b.im
        return ComplexNumber((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
}
