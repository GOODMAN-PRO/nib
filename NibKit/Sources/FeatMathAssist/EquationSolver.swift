import Foundation
import NibContracts

// The on-device maths engine (F061), part 3: equations. Each equation becomes a fraction of polynomials in its unknowns.
// One unknown is solved exactly as far as fractions allow (repeated factors and fraction roots are divided out, what is
// left of degree ≤ 2 is solved with surds), and a leftover cubic or quartic numerically; several unknowns are solved as
// a linear system by Gauss–Jordan elimination. Anything else (sin x = ½, x² + y² = 1 with a line, x⁵ − x − 1 = 0) is
// `unsupported`, pointing to AI Solve.

// MARK: - Polynomials

/// A polynomial in the unknowns: exponent of each unknown → coefficient (zero coefficients are never stored).
struct Polynomial: Equatable {
    /// Expanding (a + b + … + n)^24 would take minutes and gigabytes: products are refused beyond these sizes.
    static let maxProductTerms = 20_000
    static let maxDegree = 64

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

    func multiplied(_ o: Polynomial) throws -> Polynomial {
        guard terms.count * o.terms.count <= Polynomial.maxProductTerms,
              totalDegree + o.totalDegree <= Polynomial.maxDegree else {
            throw MathFailure.unsupported("equations this large")
        }
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

    /// By repeated squaring.
    func power(_ n: Int) throws -> Polynomial {
        let (degree, overflow) = totalDegree.multipliedReportingOverflow(by: max(0, n))
        guard !overflow, degree <= Polynomial.maxDegree, n <= Polynomial.maxDegree else {
            throw MathFailure.unsupported("equations this large")
        }
        var result = Polynomial.constant(.one, variableCount: variableCount)
        var base = self
        var e = max(0, n)
        while e > 0 {
            if e & 1 == 1 { result = try result.multiplied(base) }
            e >>= 1
            if e > 0 { base = try base.multiplied(base) }
        }
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

    /// Term products an operation with `o` costs (charged to the evaluator's budget).
    func work(with o: RationalExpression) -> Int {
        (numerator.terms.count + denominator.terms.count) * (o.numerator.terms.count + o.denominator.terms.count)
    }

    func adding(_ o: RationalExpression) throws -> RationalExpression {
        if denominator == o.denominator {
            return RationalExpression(numerator: numerator.adding(o.numerator), denominator: denominator)
        }
        return RationalExpression(numerator: try numerator.multiplied(o.denominator)
                                      .adding(o.numerator.multiplied(denominator)),
                                  denominator: try denominator.multiplied(o.denominator)).normalized()
    }

    var negated: RationalExpression { RationalExpression(numerator: numerator.negated, denominator: denominator) }

    func multiplied(_ o: RationalExpression) throws -> RationalExpression {
        RationalExpression(numerator: try numerator.multiplied(o.numerator),
                           denominator: try denominator.multiplied(o.denominator)).normalized()
    }

    func reciprocal() throws -> RationalExpression {
        guard !numerator.isZero else { throw MathFailure.math("Division by zero") }
        return RationalExpression(numerator: denominator, denominator: numerator).normalized()
    }

    func power(_ n: Int) throws -> RationalExpression {
        if n < 0 { return try reciprocal().power(-n) }
        return RationalExpression(numerator: try numerator.power(n), denominator: try denominator.power(n)).normalized()
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
        try read(node, nesting: 0)
    }

    /// `nesting` counts every level of recursion (trees and expansions) so the stack stays bounded; `depth` counts
    /// expansions of page definitions only.
    private func read(_ node: MathNode, nesting: Int) throws -> RationalExpression {
        if isConstant(node) { return try constant(node) }
        guard depth < 64, nesting < 1_000 else { throw MathFailure.math("A definition refers to itself") }
        let next = nesting + 1
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
                return try inner.read(definition, nesting: next)
            }
            throw MathFailure.undefined(name)
        case .negate(let inner):
            return try read(inner, nesting: next).negated
        case .binary(let op, let lhs, let rhs):
            let a = try read(lhs, nesting: next)
            switch op {
            case .add, .subtract, .plusMinus:
                var b = try read(rhs, nesting: next)
                if op == .subtract { b = b.negated }
                if case .plusMinus(let k) = op, signs[k] == true { b = b.negated }
                try evaluator.charge(a.work(with: b))
                return try a.adding(b)
            case .multiply:
                let b = try read(rhs, nesting: next)
                try evaluator.charge(a.work(with: b))
                return try a.multiplied(b)
            case .divide:
                let b = try read(rhs, nesting: next).reciprocal()
                try evaluator.charge(a.work(with: b))
                return try a.multiplied(b)
            case .power:
                guard isConstant(rhs) else { throw MathFailure.unsupported("equations with the unknown in an exponent") }
                guard case .scalar(let e) = try evaluator.evaluate(rhs, signs: signs), let n = e.integerValue else {
                    throw MathFailure.unsupported("equations with fractional powers or roots of the unknown")
                }
                // Refused before expanding: (x + 1)^100 would be a polynomial of degree 100.
                let degree = max(a.numerator.totalDegree, a.denominator.totalDegree)
                guard abs(n) <= Polynomial.maxDegree, degree * abs(n) <= Polynomial.maxDegree else {
                    throw MathFailure.unsupported("equations this large")
                }
                try evaluator.charge(a.work(with: a) * abs(n))
                return try a.power(n)
            }
        case .postfix(.percent, let inner):
            return try read(inner, nesting: next).multiplied(constantExpression(Scalar.one.divided(by: Scalar(100))))
        case .postfix(.degrees, let inner):
            return try read(inner, nesting: next).multiplied(constantExpression(.real(Double.pi / 180)))
        case .postfix(.factorial, _):
            throw MathFailure.unsupported("equations with factorials of the unknown")
        case .call(let name, let args, let primes):
            guard primes == 0 else { throw MathFailure.unsupported("equations with derivatives of the unknown") }
            guard let fn = definitions.functions[name] else {
                if args.count == 1, definitions.variables[name] != nil {
                    return try read(.binary(.multiply, .variable(name), args[0]), nesting: next)
                }
                throw MathFailure.undefinedFunction(name)
            }
            guard fn.parameters.count == args.count else {
                throw MathFailure.math("\(name) takes \(fn.parameters.count) argument\(fn.parameters.count == 1 ? "" : "s")")
            }
            var inner = self
            inner.bindings = [:]
            for (i, parameter) in fn.parameters.enumerated() {
                inner.bindings[parameter] = try read(args[i], nesting: next)
            }
            inner.depth += 1
            return try inner.read(fn.body, nesting: next)
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
    static let maxUnknowns = 100

    static func solve(_ equations: [MathEquation], definitions: MathDefinitions,
                      cancellation: MathCancellation? = nil) throws -> EquationOutcome {
        var names = Set<String>()
        for e in equations {
            names.formUnion(definitions.freeNames(e.lhs))
            names.formUnion(definitions.freeNames(e.rhs))
        }
        let unknowns = names.sorted()
        // Every term carries an exponent for each unknown, so work grows with their square: refuse huge systems early.
        guard unknowns.count <= maxUnknowns, equations.count <= 2 * maxUnknowns else {
            throw MathFailure.unsupported("systems of more than \(maxUnknowns) unknowns")
        }
        let evaluator = MathEvaluator(definitions: definitions, cancellation: cancellation)
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
            let lhs = try reader.read(equation.lhs)
            let rhs = try reader.read(equation.rhs)
            try evaluator.charge(lhs.work(with: rhs))
            let difference = try lhs.adding(rhs.negated)
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
        if c.count > 2, let fractions = ExactPolynomial.fractions(c) {
            // Exactly first: repeated factors ((x − 1)³ is solved as x − 1) and fraction roots are divided out, so
            // only what has neither is left for the numeric method: x³ − x² − 2x + 2 = (x − 1)(x² − 2).
            let reduced = ExactPolynomial.reduce(fractions)
            roots += reduced.roots.map { EquationRoot.value(.exact($0)) }
            c = reduced.rest.map { Scalar.exact($0) }
        }
        switch c.count - 1 {
        case 0:
            break
        case 1:
            roots.append(.value(try (-c[0]).divided(by: c[1])))
        case 2:
            roots += quadraticRoots(c[0], c[1], c[2])
        case 3, 4:
            roots += try numericRoots(c)
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
        // Divided by the largest coefficient first, so b² can't overflow (x² + 10²⁰⁰x + 1 = 0).
        let size = max(abs(a.doubleValue), abs(b.doubleValue), abs(c.doubleValue))
        let x = a.doubleValue / size
        let y = b.doubleValue / size
        let z = c.doubleValue / size
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

    /// Cubic and quartic roots by Durand–Kerner. The unknown is scaled first (x = 2ᵐ·y, so every coefficient of the
    /// monic polynomial in y is at most 1 and every root |y| < 2), which keeps 10²⁰⁰x and 10⁻²⁰⁰ roots in range. A
    /// repeated root comes back as a small cluster (a triple root's copies sit about 10⁻⁵ apart): clusters whose mean
    /// really is a multiple root are merged into it. Real roots are polished with Newton's method and recognised as
    /// fractions when a fraction satisfies the equation exactly.
    static func numericRoots(_ coefficients: [Scalar]) throws -> [EquationRoot] {
        let a = coefficients.map { $0.doubleValue }
        let n = a.count - 1
        guard n >= 1, a.allSatisfy({ $0.isFinite }), a[n] != 0 else {
            throw MathFailure.unsupported("this equation (its coefficients are too large)")
        }
        // 2ᵐ ≥ |aₖ/aₙ|^(1/(n−k)) for every k: then |bₖ| = |aₖ/aₙ|·2^(m(k−n)) ≤ 1.
        var m = Int.min
        for k in 0..<n where a[k] != 0 {
            m = max(m, Int((log2(abs(a[k])) - log2(abs(a[n]))) / Double(n - k)).advanced(by: 1))
        }
        if m == Int.min { m = 0 }
        guard (-1000...1000).contains(m) else {
            throw MathFailure.unsupported("this equation (its coefficients are too far apart)")
        }
        let b: [Double] = (0...n).map { k in
            guard a[k] != 0 else { return 0 }
            let ratio = a[k].significand / a[n].significand
            let exponent = Int(a[k].exponent) - Int(a[n].exponent) + (k - n) * m
            return Double(sign: (a[k] < 0) == (a[n] < 0) ? .plus : .minus, exponent: exponent, significand: ratio)
        }
        guard b.indices.allSatisfy({ (a[$0] == 0) == (b[$0] == 0) }) else {
            throw MathFailure.unsupported("this equation (its coefficients are too far apart)")   // one underflowed
        }
        var z: [ComplexNumber] = []
        for k in 0..<n {
            let angle = 2 * Double.pi * Double(k) / Double(n) + 0.4
            z.append(ComplexNumber(1.5 * cos(angle), 1.5 * sin(angle)))
        }
        for _ in 0..<2000 {
            var largest = 0.0
            for i in 0..<n {
                let value = evaluate(b, at: z[i])
                var product = ComplexNumber(1, 0)
                for j in 0..<n where j != i { product = product * (z[i] - z[j]) }
                guard product.magnitude > 0 else { continue }
                let step = value / product
                z[i] = z[i] - step
                largest = max(largest, step.magnitude / (1 + z[i].magnitude))
            }
            if largest < 1e-15 { break }
        }
        // Every root must satisfy the equation to rounding (a backward error at Double precision); an iteration that
        // never settled would otherwise be reported as roots.
        for root in z where backwardError(b, at: root) > 1e-10 {
            throw MathFailure.unsupported("this equation (the numeric solver didn't converge)")
        }
        let scale = Double(sign: .plus, exponent: m, significand: 1)
        var roots: [EquationRoot] = []
        for cluster in clusters(z, b) {
            var root = cluster.root
            if abs(root.im) <= 1e-7 * root.magnitude || abs(root.im) <= 1e-14 {
                // Newton on the (m−1)-th derivative, which has a simple root where p has an m-fold one.
                let y = polish(derivative(b, cluster.size - 1), root.re)
                let x = y * scale
                if let exact = exactRoot(coefficients, near: x) {
                    roots.append(.value(.exact(exact)))
                } else {
                    roots.append(.value(.real(x)))
                }
            } else {
                if abs(root.re) <= 1e-12 * root.magnitude { root.re = 0 }
                roots.append(.complex(root.re * scale, root.im * scale))
            }
        }
        var unique: [EquationRoot] = []
        for r in roots where !unique.contains(where: { $0.isClose(to: r) }) { unique.append(r) }
        return unique
    }

    /// Groups the Durand–Kerner roots of `b`. Roots near each other form a group, and a group of m becomes one root
    /// when there is an m-fold root there: Newton on p⁽ᵐ⁻¹⁾ from the group's mean (which is only good to about the
    /// group's spread) finds the candidate, and p, p′, …, p⁽ᵐ⁻¹⁾ must all vanish at it. Otherwise the group's members
    /// merge pairwise, closest first, only where each merge passes the same test.
    private static func clusters(_ z: [ComplexNumber], _ b: [Double]) -> [(root: ComplexNumber, size: Int)] {
        func near(_ p: ComplexNumber, _ q: ComplexNumber) -> Bool {
            (p - q).magnitude <= 1e-2 * max(p.magnitude, q.magnitude) + 1e-3
        }
        var label = Array(z.indices)
        for i in z.indices {
            for j in z.indices where j > i && near(z[i], z[j]) && label[i] != label[j] {
                let old = label[j]
                for k in label.indices where label[k] == old { label[k] = label[i] }
            }
        }
        var result: [(root: ComplexNumber, size: Int)] = []
        for group in Set(label).sorted() {
            let members = z.indices.filter { label[$0] == group }.map { z[$0] }
            if members.count > 1, let root = multipleRoot(b, near: members) {
                result.append((root, members.count))
            } else {
                result += mergedPairs(members, b)
            }
        }
        return result
    }

    private static func mergedPairs(_ z: [ComplexNumber], _ b: [Double]) -> [(root: ComplexNumber, size: Int)] {
        var groups = z.map { (members: [$0], root: $0) }
        var rejected = Set<[Int]>()   // pairs of group indices; cleared whenever the groups change
        while true {
            var best: (i: Int, j: Int, distance: Double)? = nil
            for i in groups.indices {
                for j in groups.indices where j > i && !rejected.contains([i, j]) {
                    let distance = (groups[i].root - groups[j].root).magnitude
                    if best.map({ distance < $0.distance }) ?? true { best = (i, j, distance) }
                }
            }
            guard let pair = best else { break }
            let merged = groups[pair.i].members + groups[pair.j].members
            if let root = multipleRoot(b, near: merged) {
                groups[pair.i] = (merged, root)
                groups.remove(at: pair.j)
                rejected = []
            } else {
                rejected.insert([pair.i, pair.j])
            }
        }
        return groups.map { ($0.root, $0.members.count) }
    }

    /// The m-fold root of p near the m roots `members`, if there is one. Two distinct roots closer than about 10⁻⁶ of
    /// their size pass as a double root: Doubles can't tell those apart.
    private static func multipleRoot(_ b: [Double], near members: [ComplexNumber]) -> ComplexNumber? {
        let m = members.count
        let sum = members.reduce(ComplexNumber(0, 0), +)
        let root = newton(derivative(b, m - 1), from: ComplexNumber(sum.re / Double(m), sum.im / Double(m)))
        for k in 0..<m where backwardError(derivative(b, k), at: root) > 1e-13 { return nil }
        return root
    }

    private static func derivative(_ c: [Double], _ order: Int) -> [Double] {
        var out = c
        for _ in 0..<order { out = differentiated(out) }
        return out
    }

    /// Complex Newton steps while |p| keeps falling.
    private static func newton(_ c: [Double], from start: ComplexNumber) -> ComplexNumber {
        let slope = differentiated(c)
        var z = start
        var size = evaluate(c, at: z).magnitude
        for _ in 0..<30 where size > 0 {
            let d = evaluate(slope, at: z)
            guard d.magnitude > 0 else { break }
            let next = z - evaluate(c, at: z) / d
            let nextSize = evaluate(c, at: next).magnitude
            guard nextSize < size else { break }
            z = next
            size = nextSize
        }
        return z
    }

    /// |p(z)| / (max|cₖ| · Σ|z|ᵏ): the relative change of the coefficients that would make z an exact root.
    private static func backwardError(_ c: [Double], at z: ComplexNumber) -> Double {
        let largest = c.map { abs($0) }.max() ?? 0
        guard largest > 0 else { return 0 }
        var powers = 0.0
        var power = 1.0
        for _ in c {
            powers += power
            power *= z.magnitude
        }
        return evaluate(c, at: z).magnitude / (largest * powers)
    }

    private static func differentiated(_ c: [Double]) -> [Double] {
        c.count > 1 ? (1..<c.count).map { Double($0) * c[$0] } : [0]
    }

    private static func evaluate(_ c: [Double], at z: ComplexNumber) -> ComplexNumber {
        var value = ComplexNumber(0, 0)
        for k in stride(from: c.count - 1, through: 0, by: -1) { value = value * z + ComplexNumber(c[k], 0) }
        return value
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
            let lhs = try reader.read(e.lhs)
            let rhs = try reader.read(e.rhs)
            try evaluator.charge(lhs.work(with: rhs))
            let difference = try lhs.adding(rhs.negated)
            guard difference.numerator.totalDegree <= 1 else {
                throw MathFailure.unsupported(equations.count == 1 ? "non-linear equations in several unknowns"
                                                                   : "non-linear systems of equations")
            }
            let parts = difference.numerator.linearParts
            rows.append(parts.coefficients + [-parts.constant])
            denominators.append(difference.denominator)
        }
        let n = unknowns.count
        try evaluator.charge(rows.count * rows.count * (n + 1))
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

// MARK: - Exact polynomial arithmetic

/// One-unknown polynomials with fraction coefficients (constant term first). Every step returns nil as soon as a
/// number stops fitting in 64 bits; callers then carry on with what they have, and the numeric method does the rest.
enum ExactPolynomial {
    /// The fraction coefficients, when every coefficient is one.
    static func fractions(_ c: [Scalar]) -> [Rational]? {
        var out: [Rational] = []
        for s in c {
            guard let r = s.rational else { return nil }
            out.append(r)
        }
        return out
    }

    /// `p`'s fraction roots, and what is left of `p` once they (and every repeated factor) are divided out: the
    /// square-free part p / gcd(p, p′), then each root r = ±(divisor of c₀)/(divisor of cₙ) that the rational root
    /// theorem allows, deflated exactly.
    static func reduce(_ p: [Rational]) -> (roots: [Rational], rest: [Rational]) {
        var rest = trimmed(p)
        if let derivative = derivative(rest), let common = gcd(rest, derivative), common.count > 1,
           let quotient = divide(rest, by: common), quotient.remainder.isEmpty {
            rest = trimmed(quotient.quotient)
        }
        var roots: [Rational] = []
        for candidate in candidates(rest) where rest.count > 1 {
            while rest.count > 1, value(rest, at: candidate)?.numerator == 0,
                  let deflated = divide(rest, by: [candidate.negated, .one]), deflated.remainder.isEmpty {
                if !roots.contains(candidate) { roots.append(candidate) }
                rest = trimmed(deflated.quotient)
            }
        }
        return (roots, rest)
    }

    static func trimmed(_ p: [Rational]) -> [Rational] {
        var q = p
        while let last = q.last, last.numerator == 0 { q.removeLast() }
        return q
    }

    static func derivative(_ p: [Rational]) -> [Rational]? {
        guard p.count > 1 else { return [] }
        var out: [Rational] = []
        for k in 1..<p.count {
            guard let term = p[k].multiplying(Rational(integer: k)) else { return nil }
            out.append(term)
        }
        return trimmed(out)
    }

    /// a = quotient·b + remainder, deg remainder < deg b (b nonzero).
    static func divide(_ a: [Rational], by b: [Rational]) -> (quotient: [Rational], remainder: [Rational])? {
        var r = trimmed(a)
        let d = trimmed(b)
        guard let lead = d.last, let inverse = lead.reciprocal else { return nil }
        guard r.count >= d.count else { return ([], r) }
        var q = Array(repeating: Rational.zero, count: r.count - d.count + 1)
        while r.count >= d.count, let top = r.last {
            guard let factor = top.multiplying(inverse) else { return nil }
            let shift = r.count - d.count
            q[shift] = factor
            for (i, c) in d.enumerated() {
                guard let product = c.multiplying(factor), let difference = r[i + shift].adding(product.negated) else {
                    return nil
                }
                r[i + shift] = difference
            }
            r[r.count - 1] = .zero   // cancelled exactly
            r = trimmed(r)
        }
        return (q, r)
    }

    /// The monic greatest common divisor, by Euclid's algorithm.
    static func gcd(_ a: [Rational], _ b: [Rational]) -> [Rational]? {
        var x = trimmed(a)
        var y = trimmed(b)
        while !y.isEmpty {
            guard let step = divide(x, by: y), let next = monic(step.remainder) else { return nil }
            (x, y) = (y, next)
        }
        return monic(x)
    }

    private static func monic(_ p: [Rational]) -> [Rational]? {
        guard let lead = p.last else { return [] }
        guard let inverse = lead.reciprocal else { return nil }
        var out: [Rational] = []
        for c in p {
            guard let scaled = c.multiplying(inverse) else { return nil }
            out.append(scaled)
        }
        return out
    }

    /// Horner's rule; nil on overflow.
    static func value(_ p: [Rational], at x: Rational) -> Rational? {
        var total = Rational.zero
        for c in p.reversed() {
            guard let product = total.multiplying(x), let sum = product.adding(c) else { return nil }
            total = sum
        }
        return total
    }

    /// ±p/q for p dividing the constant term and q the leading term of `p` cleared of fractions. Empty when the
    /// coefficients are too large to factor quickly or there would be too many candidates to try.
    static func candidates(_ p: [Rational]) -> [Rational] {
        guard p.count > 1, let first = p.first, first.numerator != 0, let last = p.last else { return [] }
        var lcm = 1
        for c in p {
            let (product, overflow) = (lcm / Rational.gcd(lcm, c.denominator)).multipliedReportingOverflow(by: c.denominator)
            guard !overflow else { return [] }
            lcm = product
        }
        guard let constant = first.multiplying(Rational(integer: lcm)),
              let leading = last.multiplying(Rational(integer: lcm)) else { return [] }
        guard let numerators = divisors(constant.numerator), let denominators = divisors(leading.numerator),
              numerators.count * denominators.count <= 2_000 else { return [] }
        var seen = Set<Rational>()
        var out: [Rational] = []
        for n in numerators {
            for d in denominators {
                for sign in [1, -1] {
                    guard let r = Rational(sign * n, d), seen.insert(r).inserted else { continue }
                    out.append(r)
                }
            }
        }
        return out
    }

    /// Positive divisors of |n| by trial division (nil above 10¹², which would take too long).
    private static func divisors(_ n: Int) -> [Int]? {
        let m = n.magnitude
        guard m > 0, m <= 1_000_000_000_000 else { return nil }
        let value = Int(m)
        var small: [Int] = []
        var large: [Int] = []
        var f = 1
        while f * f <= value {
            if value % f == 0 {
                small.append(f)
                if f * f != value { large.append(value / f) }
            }
            f += 1
        }
        return small + large.reversed()
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
